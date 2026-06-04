-- Создаёт БД для сервисов. Выполняется entrypoint Postgres только при пустом каталоге данных.
CREATE DATABASE messager_users;
CREATE DATABASE messager_messages;
GRANT ALL PRIVILEGES ON DATABASE messager_users TO messager;
GRANT ALL PRIVILEGES ON DATABASE messager_messages TO messager;
