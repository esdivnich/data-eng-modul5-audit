-- ============================================================
-- Модуль 5. Аудит изменений пользователей и ночная выгрузка в CSV
-- Автор: Дивнич Елена Сергеевна
-- Стек: PostgreSQL 17 + pg_cron, контейнер audit_db (docker compose)
-- Порядок: расширение -> таблицы -> триггер -> функция выгрузки -> cron-задача
-- Запуск: целиком в базе app (psql -f script.sql или DBeaver)
-- ============================================================


CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name TEXT,
    email TEXT,
    role TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE users_audit (
    id SERIAL PRIMARY KEY,
    user_id INTEGER,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    changed_by TEXT,
    field_changed TEXT,
    old_value TEXT,
    new_value TEXT
);

-- Создаем или заменяем функцию, если она уже есть. Она будет срабатывать при изменении таблицы users
-- Изменения будут фиксироваться в таблице users_audit
CREATE OR REPLACE FUNCTION log_users_changes()
-- функция вызывается базой при изменении строки
-- (сообщает базе, что делать дальше с операцией после того, как сработал триггер)
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Проверяем, какая операция произошла (обновление, вставка или удаление)
    -- Если было обновление — сравниваем каждое из полей (name, email, role) со старым значением
    IF TG_OP = 'UPDATE' THEN

        -- Сравниваем новое и старое имя
        IF NEW.name IS DISTINCT FROM OLD.name THEN
            INSERT INTO users_audit (user_id, changed_by, field_changed, old_value, new_value)
            VALUES (OLD.id, current_user, 'name', OLD.name, NEW.name);
        END IF;

        -- Сравниваем почту
        IF NEW.email IS DISTINCT FROM OLD.email THEN
            INSERT INTO users_audit (user_id, changed_by, field_changed, old_value, new_value)
            VALUES (OLD.id, current_user, 'email', OLD.email, NEW.email);
        END IF;

        -- Сравниваем роль
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            INSERT INTO users_audit (user_id, changed_by, field_changed, old_value, new_value)
            VALUES (OLD.id, current_user, 'role', OLD.role, NEW.role);
        END IF;

        RETURN NEW;

    -- Если было добавление строки, то вносим данные в аудит
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO users_audit (user_id, changed_by, field_changed, old_value, new_value)
        VALUES (NEW.id, current_user, 'INSERT', NULL, NEW.role);
        RETURN NEW;

    -- Если строку удалили — также вносим данные в аудит
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO users_audit (user_id, changed_by, field_changed, old_value, new_value)
        VALUES (OLD.id, current_user, 'DELETE', OLD.role, NULL);
        -- возвращаем старое значение, которое удалили
        RETURN OLD;
    END IF;
    -- если вдруг ни одна ветка не сработает, чтобы база не выдала ошибку
    RETURN NULL;
END;
$$;


-- Удаляем старый триггер, если он уже есть (чтобы не было ошибки при повторном запуске)
DROP TRIGGER IF EXISTS trigger_users_audit ON users;
-- Создаем триггер с названием trigger_users_audit
CREATE TRIGGER trigger_users_audit
-- который срабатывает после добавления, обновления и удаления строк в users
AFTER INSERT OR UPDATE OR DELETE ON users
-- для каждой измененной строки отдельно (если один UPDATE поменяет 2 строки, функция вызовется 2 раза)
FOR EACH ROW
-- запусти функцию log_users_changes() при изменении
EXECUTE FUNCTION log_users_changes();

-- Вставляет данные в таблицу users
INSERT INTO users (name, email, role) VALUES
    ('Светлана Иванова',   'svivanova@something.ru',   'Кредитный аналитик'),
    ('Иван Петров',   'irpetrov@something.ru',   'Операционист'),
    ('Петр Александров',  'pealexandrov@something.ru',  'Кредитный контролёр'),
    ('Александра Николаева',   'avnikolaeva@something.ru', 'Менеджер'),
    ('Николай Максимов',   'npmaximov@something.ru',  'Управляющий');

-- Обновляем (заменяем) роль в таблице users у сотрудника с ID №3
UPDATE users
SET role = 'Кредитный специалист'
WHERE id = 3;

-- Вставляем новую строку (новый сотрудник)
INSERT INTO users (name, email, role)
VALUES ('Ольга Сидорова', 'onsidorova@something.ru', 'Кассир');

-- Удаляем строку (сотрудник уволился)
DELETE FROM users
WHERE id = 2 AND name = 'Иван Петров';

-- Выводим результирующую таблицу изменений
SELECT id, user_id, changed_at, field_changed, old_value, new_value
FROM users_audit
ORDER BY id;

-- Проверка, что pg_cron загружен
-- SHOW shared_preload_libraries;

-- Включить расширение в базе app, если еще не установлено
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Функция выгрузки аудита в CSV.
-- По умолчанию берёт ВЧЕРАШНИЙ день (CURRENT_DATE - 1)
CREATE OR REPLACE FUNCTION export_users_audit(p_date DATE DEFAULT CURRENT_DATE - 1)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    -- Путь к файлу: /tmp/users_audit_export_2026-11-23.csv
    v_path TEXT := '/tmp/users_audit_export_' || to_char(p_date, 'YYYY-MM-DD') || '.csv';
BEGIN
    EXECUTE format(
        $q$COPY (
            SELECT id, user_id, changed_at, changed_by, field_changed, old_value, new_value
            FROM users_audit
            WHERE changed_at >= %L::timestamp
              AND changed_at < %L::timestamp + INTERVAL '1 day'
            ORDER BY id
        ) TO %L WITH (FORMAT csv, HEADER true)$q$,
        p_date, p_date, v_path
    );
    RETURN v_path;
END;
$$;
-- ============================================================
-- Тестовая ежеминутная задача использовалась при отладке.
-- В финальной версии не выполняется — оставлена для истории.
-- ============================================================
-- Протестировать работу ежеминутно
-- SELECT cron.schedule(
--     'export_audit_every_minute',
--     '* * * * *',
--     $$SELECT export_users_audit()$$
-- );

-- за последние 5 минут (точнее 5 выгрузок)
-- SELECT jobid, status, return_message, start_time
-- FROM cron.job_run_details
-- ORDER BY start_time DESC
-- LIMIT 5;

-- Устанавливаем согласно заданию: ежедневно в 3:00 ночи выгружаются изменения за вчерашний день
SELECT cron.schedule(
     'export_audit_3am', '0 3 * * *',
    $$SELECT export_users_audit()$$
);

-- Проверяем, что задача встала
SELECT jobid, jobname, schedule, command, database, active
FROM cron.job;

--Проверка запуска на следующий день
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details;
