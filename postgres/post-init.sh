#!/bin/bash
# pg-init 一次性容器入口
# 等待 PgBouncer 可用 → 等待 Patroni leader 选出 → 跑 init-users.sql
set -euo pipefail

PGHOST="${PGHOST:-pgbouncer}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres123}"
export PGPASSWORD

echo "[pg-init] waiting for PgBouncer @ $PGHOST:$PGPORT ..."
for i in $(seq 1 60); do
  if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -t 2 >/dev/null 2>&1; then
    echo "[pg-init] PgBouncer reachable"
    break
  fi
  sleep 2
done

# 再确认 leader 真的能跑 DDL
echo "[pg-init] waiting for PG leader to accept writes ..."
for i in $(seq 1 60); do
  if psql "host=$PGHOST port=$PGPORT user=$PGUSER dbname=postgres" -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q ' f'; then
    echo "[pg-init] leader ready (not in recovery)"
    break
  fi
  sleep 2
done

echo "[pg-init] running init-users.sql ..."
psql -v ON_ERROR_STOP=0 \
     -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
     -f /init/init-users.sql

echo "[pg-init] done"
