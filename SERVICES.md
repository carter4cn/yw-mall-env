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
| 2379 | etcd |
| 3000 | Grafana |
| 6032 | ProxySQL Admin |
| 6033 | ProxySQL (MySQL) |
| 6379 | Redis |
| 6650 | Pulsar Broker1 |
| 6651 | Pulsar Broker2 |
| 7750 | Pulsar Manager API |
| 8030 | Doris FE Web UI |
| 8080 | Pulsar Broker1 HTTP |
| 8081 | Pulsar Broker2 HTTP |
| 8088 | Kafka UI |
| 8089 | EtcdKeeper |
| 8090 | Bytebase |
| 9000 | MinIO API |
| 9001 | MinIO Console |
| 9030 | Doris MySQL Protocol |
| 9090 | Prometheus |
| 9200 | Elasticsearch |
| 9308 | Kafka Exporter |
| 9527 | Pulsar Manager UI |
| 19092 | Kafka Broker1 |
| 19093 | Kafka Broker2 |
| 19094 | Kafka Broker3 |
| 26379 | Redis Sentinel1 |
| 26380 | Redis Sentinel2 |
| 26381 | Redis Sentinel3 |

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
```
