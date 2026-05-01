#!/bin/bash
# 等待所有 MySQL 实例就绪
wait_mysql() {
  local host=$1
  echo "Waiting for $host..."
  until mysql -h"$host" -uroot -proot123 -e "SELECT 1" &>/dev/null; do
    sleep 2
  done
  echo "$host is ready"
}

wait_mysql mysql-master1
wait_mysql mysql-master2
wait_mysql mysql-slave1
wait_mysql mysql-slave2

echo "=== Setting up Master1 -> Master2 replication ==="
mysql -hmysql-master2 -uroot -proot123 -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='mysql-master1',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='repl123',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
"

echo "=== Setting up Master2 -> Master1 replication ==="
mysql -hmysql-master1 -uroot -proot123 -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='mysql-master2',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='repl123',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
"

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

echo "=== Setting up Master2 -> Slave2 replication ==="
mysql -hmysql-slave2 -uroot -proot123 -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='mysql-master2',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='repl123',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
"

echo "=== Checking replication status ==="
echo "--- Master1 replica status ---"
mysql -hmysql-master1 -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E "Source_Host|Replica_IO_Running|Replica_SQL_Running"
echo "--- Master2 replica status ---"
mysql -hmysql-master2 -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E "Source_Host|Replica_IO_Running|Replica_SQL_Running"
echo "--- Slave1 replica status ---"
mysql -hmysql-slave1 -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E "Source_Host|Replica_IO_Running|Replica_SQL_Running"
echo "--- Slave2 replica status ---"
mysql -hmysql-slave2 -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E "Source_Host|Replica_IO_Running|Replica_SQL_Running"

echo "=== Replication setup complete ==="
