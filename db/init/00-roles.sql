-- Runs once as superuser when the container is first created.
CREATE ROLE axel_owner LOGIN PASSWORD 'owner_pw';
CREATE ROLE axel_app   LOGIN PASSWORD 'app_pw' NOBYPASSRLS;
CREATE DATABASE axel OWNER axel_owner;
\connect axel
CREATE EXTENSION IF NOT EXISTS citext;
GRANT CONNECT ON DATABASE axel TO axel_app;
GRANT USAGE ON SCHEMA public TO axel_app;
ALTER DEFAULT PRIVILEGES FOR ROLE axel_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO axel_app;
ALTER DEFAULT PRIVILEGES FOR ROLE axel_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO axel_app;
