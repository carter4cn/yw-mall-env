-- 在 pg-init 一次性容器中通过 PgBouncer (host=pgbouncer port=5432) 以 postgres 身份执行
-- 幂等：所有创建用 DO 块 + EXCEPTION 处理，所有 GRANT 重复执行也无副作用

-- 应用业务库
SELECT 'CREATE DATABASE mall ENCODING UTF8 LC_COLLATE ''en_US.UTF-8'' LC_CTYPE ''en_US.UTF-8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mall')\gexec

-- 业务读写
DO $$ BEGIN
  CREATE ROLE app_rw LOGIN PASSWORD 'apprw123';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE app_rw WITH PASSWORD 'apprw123';
END $$;

-- 业务只读
DO $$ BEGIN
  CREATE ROLE app_ro LOGIN PASSWORD 'appro123';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE app_ro WITH PASSWORD 'appro123';
END $$;

-- PgBouncer auth_user（需要 SELECT pg_shadow 权限 + 一般是 secadmin 或 superuser 的 SECURITY DEFINER 函数）
-- 这里用 superuser 直接给最简实现：让 pgbouncer 用户拥有读 pg_shadow 的权限
DO $$ BEGIN
  CREATE ROLE pgbouncer LOGIN PASSWORD 'pgbouncer123';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE pgbouncer WITH PASSWORD 'pgbouncer123';
END $$;

CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS $$
BEGIN
  SELECT usename, passwd FROM pg_catalog.pg_shadow
  WHERE usename = i_username INTO uname, phash;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 兜底：直接给读 pg_shadow（不太严谨但 dev placeholder 简便）
GRANT pg_read_all_settings TO pgbouncer;
GRANT SELECT ON pg_catalog.pg_shadow TO pgbouncer;
GRANT SELECT ON pg_catalog.pg_authid TO pgbouncer;

-- 备份用户（wal-g 用）— Spilo 已经默认创建 standby/postgres，这里 backup 留作业务侧备份触发
DO $$ BEGIN
  CREATE ROLE backup REPLICATION LOGIN PASSWORD 'backup123';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE backup WITH REPLICATION PASSWORD 'backup123';
END $$;

-- Prometheus exporter 用户（监控）
DO $$ BEGIN
  CREATE ROLE exporter LOGIN PASSWORD 'exporter123';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE exporter WITH PASSWORD 'exporter123';
END $$;
GRANT pg_monitor TO exporter;

-- Bytebase 平台用户
DO $$ BEGIN
  CREATE ROLE bytebase LOGIN PASSWORD 'bytebase123' SUPERUSER;
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE bytebase WITH PASSWORD 'bytebase123' SUPERUSER;
END $$;

-- 业务库授权
-- pgbouncer 用户必须能 CONNECT 业务库才能完成 auth_query（PgBouncer 1.21+ 强制 auth_dbname 后，
-- pgbouncer 用 auth_dbname 连业务库的目标 db 去查 pg_shadow，没 CONNECT 权限会报 "bouncer config error"）
GRANT CONNECT ON DATABASE mall TO app_rw, app_ro, pgbouncer;
\c mall
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

GRANT USAGE ON SCHEMA public TO app_rw, app_ro;
GRANT ALL ON SCHEMA public TO app_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO app_ro;
