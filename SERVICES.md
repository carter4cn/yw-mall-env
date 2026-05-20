# Dev Infrastructure Services

> Dashboard: **http://localhost:8888** (Homer)

---

## Message Queue

| Component | Version | Architecture | Port (Host) | Remarks |
|-----------|---------|-------------|-------------|---------|
| Kafka | 4.2.0 (apache/kafka) | 3 nodes KRaft | 19092 / 19093 / 19094 | Cluster ID: q1Sh-9_ISia_zwGINzRvyQ |
| Kafka Exporter | latest | - | 9308 | Prometheus metrics |
| Pulsar Broker | 4.2.0 | 1ZK + 3BK + 2Broker | 6650, 8080 (Broker1) / 6651, 8081 (Broker2) | Cluster: pulsar-cluster |

### Management UIs

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| Kafka UI | http://localhost:8888:8088 | - | - |
| Pulsar Manager | http://localhost:8888:9527 | admin | admin123 |

> Pulsar Manager admin user needs to be recreated after container restart:
> ```bash
> podman exec pulsar-manager bash -c 'CSRF_TOKEN=$(curl -s http://127.0.0.1:7750/pulsar-manager/csrf-token) && curl -s -H "Content-Type: application/json" -H "X-XSRF-TOKEN: $CSRF_TOKEN" -H "Cookie: XSRF-TOKEN=$CSRF_TOKEN" -X PUT http://127.0.0.1:7750/pulsar-manager/users/superuser -d "{\"name\":\"admin\",\"password\":\"admin123\",\"description\":\"Admin\",\"email\":\"admin@126.com\"}"'
> ```

---

## Database

### MySQL Cluster (Dual-Master Dual-Slave + ProxySQL)

| Component | Version | Role | Port (Host) |
|-----------|---------|------|-------------|
| mysql-master1 | 9.6.0 | Master (offset=1) | internal |
| mysql-master2 | 9.6.0 | Master (offset=2) | internal |
| mysql-slave1 | 9.6.0 | Slave (from master1) | internal |
| mysql-slave2 | 9.6.0 | Slave (from master2) | internal |
| ProxySQL | 3.0.7 | Middleware (R/W split) | **6033** (SQL) / **6032** (Admin) |

**Application connection (via ProxySQL):**
```
Host: localhost  Port: 6033  User: proxysql  Password: proxysql123
```

**ProxySQL admin:**
```
mysql -h localhost -P 6032 -u admin -padmin123
```

**Direct root access:**
```
User: root  Password: root123  Database: dev
```

**Replication users:**
| User | Password | Purpose |
|------|----------|---------|
| repl | repl123 | Replication |
| monitor | monitor123 | ProxySQL monitor |
| proxysql | proxysql123 | Application access |

## API Gateway

### APISIX (Apache, etcd-backed)

| Component | Version | Role | Port (Host) | IP |
|-----------|---------|------|-------------|----|
| apisix | 3.10.0-debian | 数据面 + Admin | **9080** (HTTP) / **9443** (HTTPS) / **9091** (Prom) / **9180** (Admin) | 10.89.0.80 |
| apisix-dashboard | 3.0.1-alpine | Web UI | **9085** | 10.89.0.81 |

**控制面**：复用 `etcd1:2379`，prefix `/apisix`。

**Admin API（创建路由示例）：**
```
curl -X PUT \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/routes/my-route \
  -d '{
    "uri": "/api/v1/*",
    "upstream": { "type": "roundrobin", "nodes": { "my-service:8080": 1 } }
  }'
```

**Dashboard：** http://localhost:9085 — admin / admin123

**Prometheus metrics：** http://localhost:9091/apisix/prometheus/metrics（已接入 Grafana 数据源）

**Admin API Keys（dev placeholder，生产改）：**
| 角色 | Key |
|------|-----|
| admin | edd1c9f034335f136f87ad84b625c8f1 |
| viewer | 4054f7cf07e344346cd3f287985e76a2 |

---

### PostgreSQL HA (Patroni + etcd + HAProxy + PgBouncer)

| Component | Version | Role | Port (Host) | IP |
|-----------|---------|------|-------------|----|
| pg1 | Spilo 17 (4.0-p2) | Patroni candidate primary | internal | 10.89.0.60 |
| pg2 | Spilo 17 (4.0-p2) | Patroni standby | internal | 10.89.0.61 |
| pg3 | Spilo 17 (4.0-p2) | Patroni standby | internal | 10.89.0.62 |
| pg-haproxy1 | haproxy:3.0-alpine | R/W router (active) | **5433** (write) / **5434** (read) / **8008** (stats+metrics) | 10.89.0.63 |
| pg-haproxy2 | haproxy:3.0-alpine | R/W router (HA replica) | **8009** (stats+metrics) | 10.89.0.64 |
| pgbouncer | edoburu/pgbouncer:1.23.1 | Transaction pooler | **5432** | 10.89.0.65 |
| pg-init | bitnami/postgresql:17 | One-shot bootstrap | — | — |
| postgres-exporter | postgres_exporter:0.16.0 | Prometheus metrics | **9187** | 10.89.0.66 |

**Application connection (via PgBouncer):**
```
psql "host=localhost port=5432 user=app_rw password=apprw123 dbname=mall"
```

**Direct primary (运维 / 迁移):**
```
psql -h localhost -p 5433 -U postgres -d postgres   # password postgres123
```

**Read-only fan-out:**
```
psql -h localhost -p 5434 -U app_ro -d mall   # password appro123
```

**Patroni cluster status:**
```
podman exec pg1 patronictl list
```

**Users (dev placeholder):**
| User | Password | Purpose |
|------|----------|---------|
| postgres | postgres123 | Superuser |
| standby | replicator123 | Streaming replication |
| admin | admin123 | DBA |
| app_rw | apprw123 | Application read-write |
| app_ro | appro123 | Application read-only |
| pgbouncer | pgbouncer123 | PgBouncer auth_user |
| backup | backup123 | wal-g backups |
| exporter | exporter123 | postgres-exporter |
| bytebase | bytebase123 | Bytebase access |

### MongoDB ReplicaSet (PSS + PBM)

| Component | Version | Role | Port (Host) | IP |
|-----------|---------|------|-------------|----|
| mongo1 | 8.0 | RS primary candidate (priority=2) | **27017** | 10.89.0.70 |
| mongo2 | 8.0 | RS secondary | **27018** | 10.89.0.71 |
| mongo3 | 8.0 | RS secondary | **27019** | 10.89.0.72 |
| mongo-init | 8.0 | One-shot rs.initiate + users | — | — |
| pbm-agent1/2/3 | percona-backup-mongodb:2.5.0 | PBM agents (per-node sidecar) | — | — |
| mongo-express | 1.0.2 | Web UI | **8091** | 10.89.0.73 |
| mongodb-exporter | percona/mongodb_exporter:0.43 | Prometheus metrics | **9216** | 10.89.0.74 |

**Application connection (driver-side RS discovery):**
```
mongodb://app_rw:apprw123@localhost:27017,localhost:27018,localhost:27019/?replicaSet=rs0&authSource=admin
```

**RS status:**
```
podman exec mongo1 mongosh -u root -p root123 --authenticationDatabase admin --eval "rs.status()"
```

**Users (dev placeholder):**
| User | Password | Roles |
|------|----------|-------|
| root | root123 | root |
| app_rw | apprw123 | readWriteAnyDatabase |
| app_ro | appro123 | readAnyDatabase |
| backup | backup123 | backup + restore + clusterMonitor |
| exporter | exporter123 | clusterMonitor + read on local |
| pbm | pbm123 | PBM agent |

**Management UI:**
| Service | URL | Username | Password |
|---------|-----|----------|----------|
| mongo-express | http://localhost:8091 | admin | admin123 |

### Doris (OLAP)

| Component | Version | Role | Port (Host) | IP |
|-----------|---------|------|-------------|----|
| doris-fe | fe-4.1.0-slim | Frontend | **8030** (Web UI) / **9030** (MySQL) | 10.89.0.30 |
| doris-be1 | be-4.1.0-slim | Backend | internal | 10.89.0.31 |
| doris-be2 | be-4.1.0-slim | Backend | internal | 10.89.0.32 |

**Doris connection:**
```
mysql -h localhost -P 9030 -u root
```

### Management UI

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| Bytebase | http://localhost:8888:8090 | (first-time setup) | - |
| Doris Web UI | http://localhost:8888:8030 | root | (empty) |

---

## Key-Value Store

### etcd Cluster

| Component | Version | Port (Host) |
|-----------|---------|-------------|
| etcd1 (Leader) | v3.5.11 | **2379** |
| etcd2 | v3.5.11 | internal |
| etcd3 | v3.5.11 | internal |

**Connection:**
```
etcdctl --endpoints=http://localhost:8888:2379 put /key value
etcdctl --endpoints=http://localhost:8888:2379 get /key
```

| Management UI | URL | Remarks |
|---------------|-----|---------|
| EtcdKeeper | http://localhost:8888:8089 | Enter `http://etcd1:2379` in the page |

### Redis Sentinel Cluster

| Component | Version | Role | Port (Host) | IP |
|-----------|---------|------|-------------|----|
| redis-master | 8.0.3 | Master | **6379** | 10.89.0.40 |
| redis-slave1 | 8.0.3 | Slave | internal | 10.89.0.41 |
| redis-slave2 | 8.0.3 | Slave | internal | 10.89.0.42 |
| redis-sentinel1 | 8.0.3 | Sentinel | **26379** | - |
| redis-sentinel2 | 8.0.3 | Sentinel | **26380** | - |
| redis-sentinel3 | 8.0.3 | Sentinel | **26381** | - |

**Connection:**
```
redis-cli -h localhost -p 6379
```

**Sentinel connection:**
```
redis-cli -h localhost -p 26379 SENTINEL masters
```

---

## Storage & Search

### MinIO (Object Storage)

| Component | Version | Port (Host) |
|-----------|---------|-------------|
| minio | latest (RELEASE.2025-09-07) | **9000** (API) / **9001** (Console) |

| Management UI | URL | Username | Password |
|---------------|-----|----------|----------|
| MinIO Console | http://localhost:8888:9001 | admin | admin123 |

### Elasticsearch Cluster

| Component | Version | Port (Host) |
|-----------|---------|-------------|
| es1 (Master) | 9.3.3 | **9200** |
| es2 | 9.3.3 | internal |
| es3 | 9.3.3 | internal |

**Connection:**
```
curl http://localhost:8888:9200
curl http://localhost:8888:9200/_cluster/health?pretty
```

---

## Monitoring

| Component | Version | Port (Host) |
|-----------|---------|-------------|
| Prometheus | latest | **9090** |
| Grafana | 13.0.1 | **3000** |
| Kafka Exporter | latest | **9308** |

| Management UI | URL | Username | Password |
|---------------|-----|----------|----------|
| Grafana | http://localhost:8888:3000 | admin | admin123 |
| Prometheus | http://localhost:8888:9090 | - | - |

**Grafana pre-configured datasources:**
- Elasticsearch: http://es1:9200
- Prometheus: http://prometheus:9090

---

## Dashboard

| Service | URL | Remarks |
|---------|-----|---------|
| Homer | http://localhost:8888 | Service navigation portal |

---

## Port Summary

| Port | Service |
|------|---------|
| 8888 | Homer (Dashboard) |
| 9080 | APISIX 业务入口 (HTTP) |
| 9085 | APISIX Dashboard |
| 9091 | APISIX Prometheus metrics |
| 9180 | APISIX Admin API |
| 9443 | APISIX 业务入口 (HTTPS) |
| 2379 | etcd |
| 3000 | Grafana |
| 5432 | PgBouncer (PostgreSQL entry) |
| 5433 | pg-haproxy1 write port (→ primary) |
| 5434 | pg-haproxy1 read port (→ replicas) |
| 6032 | ProxySQL Admin |
| 6033 | ProxySQL (MySQL) |
| 6379 | Redis |
| 6650 | Pulsar Broker1 |
| 6651 | Pulsar Broker2 |
| 7750 | Pulsar Manager API |
| 8008 | pg-haproxy1 stats + Prometheus metrics |
| 8009 | pg-haproxy2 stats + Prometheus metrics |
| 8030 | Doris FE Web UI |
| 8080 | Pulsar Broker1 HTTP |
| 8081 | Pulsar Broker2 HTTP |
| 8088 | Kafka UI |
| 8089 | EtcdKeeper |
| 8090 | Bytebase |
| 8091 | mongo-express |
| 9000 | MinIO API |
| 9001 | MinIO Console |
| 9030 | Doris MySQL Protocol |
| 9090 | Prometheus |
| 9187 | postgres-exporter |
| 9200 | Elasticsearch |
| 9216 | mongodb-exporter |
| 9308 | Kafka Exporter |
| 9527 | Pulsar Manager UI |
| 19092 | Kafka Broker1 |
| 19093 | Kafka Broker2 |
| 19094 | Kafka Broker3 |
| 26379 | Redis Sentinel1 |
| 26380 | Redis Sentinel2 |
| 26381 | Redis Sentinel3 |
| 27017 | MongoDB rs0 node 1 |
| 27018 | MongoDB rs0 node 2 |
| 27019 | MongoDB rs0 node 3 |

---

## Data Directories

```
data/
  etcd/{1,2,3}/
  kafka/{1,2,3}/
  pulsar/{zk,bk1,bk2,bk3}/
  minio/
  es/{1,2,3}/
  redis/{master,slave1,slave2}/
  mysql/{master1,master2,slave1,slave2}/
  doris/{fe,be1,be2}/
  bytebase/
  pg/{1,2,3}/
  mongo/{1,2,3}/
```

## Quick Commands

```bash
# Start all
podman compose up -d

# Stop all
podman compose down

# View logs
podman logs -f <container_name>

# MySQL replication setup (after fresh start)
podman compose up mysql-init

# PG / Mongo first-time setup (after fresh start)
./pki/mk-pki.sh                                     # generate Mongo keyFile
podman compose up -d etcd1 etcd2 etcd3 minio        # ensure DCS + S3 ready
./pki/init-minio-buckets.sh                         # create wal-archive + pbm buckets
podman compose up -d pg1 pg2 pg3                    # Patroni elects leader
podman compose up -d pg-haproxy1 pg-haproxy2 pgbouncer
podman compose up pg-init                           # one-shot user/DB bootstrap
podman compose up -d mongo1 mongo2 mongo3
podman compose up mongo-init                        # rs.initiate + users
podman compose up -d pbm-agent1 pbm-agent2 pbm-agent3
podman exec pbm-agent1 pbm config --file=/etc/pbm/pbm-config.yaml
podman compose up -d                                # bring everything else up
```
