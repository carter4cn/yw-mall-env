#!/bin/bash
# Slim 模式下的 MySQL 复制初始化：只配 master1 → slave1。
# master2 / slave2 不在 baseline 里（移到了 mysql-ha profile），
# 这里不去 wait 它们，避免一次性容器卡死。
wait_mysql() {
  local host=$1
  echo "Waiting for $host..."
  until mysql -h"$host" -uroot -proot123 -e "SELECT 1" &>/dev/null; do
    sleep 2
  done
  echo "$host is ready"
}

wait_mysql mysql-master1
wait_mysql mysql-slave1

echo "=== Setting up Master1 -> Slave1 replication ==="
mysql -hmysql-slave1 -uroot -proot123 -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='mysql-master1',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='repl123',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
"

echo "=== Checking replication status ==="
echo "--- Slave1 replica status ---"
mysql -hmysql-slave1 -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E "Source_Host|Replica_IO_Running|Replica_SQL_Running"

echo "=== Replication setup complete (slim mode: master1 only) ==="
