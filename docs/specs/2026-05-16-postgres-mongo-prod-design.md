# 2026-05-16 / yw-mall-env：PostgreSQL + MongoDB 生产级拓扑接入

> 变更记录 / 设计文档。和实际容器配置一同入库，作为后续运维与回滚依据。

## 1. 背景与目标

`yw-mall-env` 目前提供 MySQL（双主双从 + ProxySQL）、Redis（1M2S + 3 Sentinel）、Kafka KRaft 3 节点、Pulsar、Elasticsearch、etcd 3 节点、Doris 等基础设施，全部以单机 compose 形式提供「生产级拓扑」。

本次新增 **PostgreSQL** 与 **MongoDB** 两套数据库。要求：

- 拓扑就是生产架构（HA、自动 failover、备份与 PITR、监控、鉴权），不是 dev 单实例
- 仍以一份 `compose.yml` 一次拉起，部署到生产环境只需调参（密码、资源、备份桶）
- 复用现有 **etcd 集群**（PG Patroni 的 DCS）、**MinIO**（备份 S3 后端）、**Prometheus + Grafana**（指标）

## 2. 决策摘要

| 维度 | 选择 |
|---|---|
| PG HA 栈 | Patroni（容器内）+ 现有 etcd + HAProxy（双副本）+ PgBouncer |
| PG 镜像 | `ghcr.io/zalando/spilo-17:4.0-p2`（PG17 + Patroni + wal-g） |
| Mongo 拓扑 | 3 节点 ReplicaSet（PSS，全 data-bearing，majority writeConcern 成立） |
| Mongo 镜像 | `mongo:8.0`（社区版） |
| 鉴权 / 加密 | 鉴权强制开启 + 集群内部 TLS（PG）/ keyFile（Mongo），客户端不强制 TLS |
| 备份 | PG: wal-g → MinIO；Mongo: PBM → MinIO。均支持 PITR |
| Web UI | Bytebase 接管 PG；Mongo 加 mongo-express |
| 资源限制 | 全部新增容器加 `deploy.resources.limits`，保守值 |

## 3. 整体架构

```
   应用 (yw-mall)
      │
      ▼ :5432 (主写) / :5434 (只读)
   ┌──────────┐
   │PgBouncer │  pool_mode=transaction
   └────┬─────┘
        ▼ :5433 (写) / :5434 (读)
   ┌──────────────┐
   │pg-haproxy1/2 │  通过 Patroni REST /master /replica 探活
   └────┬─────────┘
        ▼
   ┌────┬────┬────┐
   │pg1 │pg2 │pg3 │  Spilo (PG17 + Patroni + wal-g)
   └────┴────┴────┘
        │
        ▼
   etcd1/2/3 (DCS, 复用)

   应用 ──▶ mongo1:27017 (driver 自带 RS 发现)
                mongo2:27018
                mongo3:27019  PSS RS，keyFile 内部鉴权

   备份:
     wal-g (Spilo 内置) ──▶ MinIO bucket: wal-archive
     pbm-agent (每 Mongo 节点 sidecar) ──▶ MinIO bucket: pbm

   监控:
     postgres-exporter ──▶ Prometheus
     mongodb-exporter  ──▶ Prometheus
     HAProxy stats     ──▶ Prometheus（prometheus-exporter 内置）
```

## 4. 容器清单（新增 17 个：PG 8 + Mongo 9）

### PG 层（8 个）

| 容器 | 镜像 | 角色 | IP（infra 网络） |
|---|---|---|---|
| `pg1` | `ghcr.io/zalando/spilo-17:4.0-p2` | Patroni 候选 primary / sync standby | 10.89.0.60 |
| `pg2` | 同上 | 候选 sync / async standby | 10.89.0.61 |
| `pg3` | 同上 | 候选 async standby | 10.89.0.62 |
| `pg-haproxy1` | `haproxy:3.0-alpine` | 读写路由（暴露 5433/5434） | 10.89.0.63 |
| `pg-haproxy2` | `haproxy:3.0-alpine` | 读写路由副本（仅探活，对外不暴露） | 10.89.0.64 |
| `pgbouncer` | `bitnami/pgbouncer:1.23.1` | transaction-level 连接池 | 10.89.0.65 |
| `pg-init` | `bitnami/postgresql:17` | 一次性容器：初始化业务用户、扩展 | — |
| `postgres-exporter` | `prometheuscommunity/postgres-exporter:v0.16.0` | Prometheus metrics | 10.89.0.66 |

### Mongo 层（9 个）

| 容器 | 镜像 | 角色 | IP |
|---|---|---|---|
| `mongo1` | `mongo:8.0` | RS 成员 0（候选 primary） | 10.89.0.70 |
| `mongo2` | `mongo:8.0` | RS 成员 1 | 10.89.0.71 |
| `mongo3` | `mongo:8.0` | RS 成员 2 | 10.89.0.72 |
| `mongo-init` | `mongo:8.0` | 一次性容器：`rs.initiate()` + 初始化用户 | — |
| `pbm-agent1` | `percona/percona-backup-mongodb:2.5.0` | PBM agent，绑定 mongo1 | — |
| `pbm-agent2` | 同上，绑定 mongo2 | — |
| `pbm-agent3` | 同上，绑定 mongo3 | — |
| `mongo-express` | `mongo-express:1.0.2-20-alpine3.19` | Web UI | 10.89.0.73 |
| `mongodb-exporter` | `percona/mongodb_exporter:0.43` | Prometheus metrics | 10.89.0.74 |

> PBM 没有独立的 controller 容器：3 个 pbm-agent 共享 RS 中保存的状态，任一节点执行 `pbm config / pbm backup` 即可。详见 §9.2。

## 5. 端口规划（host）

| 端口 | 服务 | 说明 |
|---|---|---|
| **5432** | PgBouncer | 业务推荐入口；写到 primary，读由后端 HAProxy 决定 |
| **5433** | pg-haproxy1 写口 | 跳过 PgBouncer 直连 primary，用于运维 |
| **5434** | pg-haproxy1 读口 | 只读副本负载均衡 |
| **8008** | pg-haproxy1 stats / Prometheus metrics | http://localhost:8008/metrics |
| **8009** | pg-haproxy2 stats / Prometheus metrics | http://localhost:8009/metrics |
| **27017** | mongo1 | RS 节点直连（driver 自动发现其余成员） |
| **27018** | mongo2 | |
| **27019** | mongo3 | |
| **8091** | mongo-express | http://localhost:8091 |
| **9187** | postgres-exporter | /metrics |
| **9216** | mongodb-exporter | /metrics |

Patroni REST（8008 内部）、PBM agent（无对外端口）保留为容器内部。

## 6. PG 集群细节

### 6.1 Patroni 配置注入

Spilo 通过 `SPILO_CONFIGURATION` 环境变量注入 Patroni YAML。三个 PG 容器共用一段配置（差异仅 `PATRONI_NAME` / 容器名）。关键参数见 `postgres/post-init.sh` 和 compose env：

- `scope`: `mall-pg`
- `etcd3.hosts`: `etcd1:2379,etcd2:2379,etcd3:2379`
- `postgresql.parameters`:
  - `max_connections=200`
  - `shared_buffers=256MB`
  - `effective_cache_size=1GB`
  - `wal_level=replica`
  - `max_wal_senders=10` / `max_replication_slots=10`
  - `hot_standby=on`
  - `archive_mode=on` / `archive_timeout=60s`
  - `ssl=on`（Spilo 自动生成自签证书）
- `postgresql.pg_hba`：
  - `hostssl replication standby all scram-sha-256`
  - `host all all 0.0.0.0/0 scram-sha-256`
- `synchronous_mode=true`，但 `synchronous_mode_strict=false`（avail > durab）

### 6.2 HAProxy 路由

- **写端口（5433）**：backend `pg_write`，三个 PG 节点都列上，但 health-check 用 `GET /master` 探 Patroni REST。返回 200 才进池 → 永远只有一个节点在池里
- **读端口（5434）**：backend `pg_read`，health-check `GET /replica` → 只有 standby 进池
- 故障切换：Patroni 自动晋升 → REST 答复变化 → HAProxy 10 秒内重路由
- HAProxy 自带 Prometheus exporter（`/metrics` on stats port），无须 sidecar

### 6.3 PgBouncer

- `pool_mode=transaction`（业务推荐）
- `auth_type=scram-sha-256`，`auth_query` 直接查 PG 的 `pg_shadow`（通过 `auth_user=pgbouncer`）
- `default_pool_size=20`、`max_client_conn=400`
- `userlist.txt` 只放 `pgbouncer` auth user 的明文（其余用户走 auth_query）

### 6.4 用户与权限

| 用户 | 用途 | 密码（dev placeholder） |
|---|---|---|
| `postgres` | superuser | `postgres123` |
| `replicator` | 复制账号 | `replicator123` |
| `app_rw` | 业务读写 | `apprw123` |
| `app_ro` | 业务只读 | `appro123` |
| `pgbouncer` | PgBouncer auth_user | `pgbouncer123` |
| `backup` | wal-g 在线备份 | `backup123` |
| `exporter` | postgres-exporter | `exporter123` |
| `bytebase` | Bytebase 接入用 | `bytebase123` |

`pg-init` 一次性容器在集群 leader 起来后通过 PgBouncer 跑 `init-users.sql`，幂等。

### 6.5 关于 pgBackRest → wal-g 的实施替换

原始决策选择 pgBackRest。Spilo 镜像内置 wal-g 而非 pgBackRest；要在 Spilo 容器里再跑 pgBackRest 需要 fork 镜像并在容器内部启动 pgBackRest TLS server 作为常驻进程，复杂度和镜像维护成本上升。

**wal-g 与 pgBackRest 在本场景下功能等价**：
- 增量 WAL 归档：wal-g `wal-push`；pgBackRest `archive-push`
- 基础备份 + 增量：wal-g `backup-push` 支持 delta backup
- PITR：wal-g `backup-fetch` + WAL 重放
- S3 后端：两者都原生支持（→ MinIO）
- Retention 策略：两者都支持
- 监控/告警：通过 `postgres_exporter` 的 `pg_stat_archiver` 即可

替换的代价：CLI 命令名不同（`wal-g backup-list` vs `pgbackrest info`）。运维手册中标注即可，不影响架构 SLA。

如果后续团队坚持要 pgBackRest，可以在不动 PG 节点的前提下，新增一个 `pgbackrest` 容器以 TLS server mode 运行，把数据卷 read-only 挂进去 —— 单独的演进任务。

## 7. Mongo 集群细节

### 7.1 RS 启动

`mongo1/2/3` 均以 `--replSet rs0 --keyFile /etc/mongo/keyfile --auth` 启动。容器健康后由 `mongo-init` 一次性容器跑 `init-replset.js`：

```javascript
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
});
// wait 选举…
db.createUser({ user: "root", pwd: "root123", roles: [{ role: "root", db: "admin" }] });
// app_rw / app_ro / backup / exporter ...
```

脚本幂等（`rs.initiate` 失败时 catch 后继续创建用户）。

### 7.2 keyFile 与用户

| 用户 | DB | 角色 |
|---|---|---|
| `root` | admin | root |
| `app_rw` | admin | readWriteAnyDatabase |
| `app_ro` | admin | readAnyDatabase |
| `backup` | admin | backup + restore + clusterMonitor（PBM 需要） |
| `exporter` | admin | clusterMonitor + read on local |
| `pbm` | admin | PBM 专用，roles: `pbmAnyAction@admin` 等 |

keyFile 是 1024 字节随机数据，`./pki/mk-pki.sh` 生成，权限 `0600`，UID/GID = 999（容器 mongodb 用户）。

### 7.3 资源与存储

- `wiredTiger.engineConfig.cacheSizeGB=1`（保守，按主机内存调整）
- `oplogSize=2048MB`
- `journalCompressor=snappy`，`directoryForIndexes=true`
- 数据卷：`./data/mongo/{1,2,3}`

## 8. 鉴权与 TLS

- **PG**：
  - Spilo `ssl=on`：自签 server cert，自动颁发，开机即生效
  - `pg_hba` 中 replication 行用 `hostssl`，强制 TLS
  - 客户端连接行用普通 `host`，密码 SCRAM，但允许明文 TLS
- **Mongo**：
  - `keyFile` 提供 RS 成员间认证
  - `--auth` 强制客户端用户密码登录（SCRAM-SHA-256）
  - 不启用 `--tlsMode requireTLS`（按决策）
- **PKI**：仅生成 Mongo keyFile（PG 走 Spilo 自动签名）
- **密码管理**：本次仍写死在 compose env，与现有 dev placeholder 风格一致。生产部署时必须通过 `.env` 文件或 secrets 管理替换（参见 README）

## 9. 备份

### 9.1 wal-g（PG）

Spilo 内置。通过 env 变量启用：

```
USE_WALG_BACKUP=true
USE_WALG_RESTORE=true
WAL_S3_BUCKET=wal-archive
WALE_S3_PREFIX=s3://wal-archive
AWS_ACCESS_KEY_ID=admin
AWS_SECRET_ACCESS_KEY=admin123
AWS_ENDPOINT=http://minio:9000
AWS_S3_FORCE_PATH_STYLE=true
WALG_DISABLE_S3_SSE=true
BACKUP_SCHEDULE="0 2 * * *"
BACKUP_NUM_TO_RETAIN=7
```

- WAL 实时归档（`archive_command` 由 Spilo 自动写入 `wal-g wal-push`）
- 每天 02:00 一次 base backup（delta），保留 7 份
- 恢复：`docker exec pg1 wal-g backup-fetch /home/postgres/pgdata/pgroot/data LATEST`

### 9.2 PBM（Mongo）

Percona Backup for MongoDB。3 个 pbm-agent sidecar，分别绑定 mongo1/2/3：

```yaml
storage:
  type: s3
  s3:
    endpointUrl: http://minio:9000
    bucket: pbm
    region: us-east-1
    credentials:
      access-key-id: admin
      secret-access-key: admin123
    insecureSkipTLSVerify: true
pitr:
  enabled: true
  oplogSpanMin: 10
backup:
  compression: s2
```

- `pbm-agent` 长期运行；备份命令由其中一个 agent 内置的循环触发（或人工 `pbm backup`）
- PITR 默认开启
- 第一次启动后需要：`docker exec pbm-agent1 pbm config --file=/etc/pbm/pbm-config.yaml`

### 9.3 MinIO bucket

需要预创建两个 bucket：`wal-archive`、`pbm`。提供脚本 `./pki/init-minio-buckets.sh`，README 也会提示。

## 10. 监控

新增 Prometheus job：

| Job | Target | Metrics |
|---|---|---|
| `postgres` | `postgres-exporter:9187` | pg_stat_*、replication lag、archiver |
| `mongodb` | `mongodb-exporter:9216` | mongodb_ss_*、replSet lag、connections |
| `haproxy_pg` | `pg-haproxy1:8008`、`pg-haproxy2:8009` | HAProxy 自带 Prometheus exporter |

postgres-exporter 通过 PgBouncer → primary 抓取。后续 dashboard 由 Grafana provisioning 加载（不在本变更范围内，Grafana 已经在跑）。

## 11. UI 集成

### 11.1 Bytebase 接 PG

Bytebase 已存在。首次启动后人工在 UI 添加 instance：

```
Engine: PostgreSQL
Host:   pgbouncer
Port:   5432
User:   bytebase
Pass:   bytebase123
DB:     postgres
```

### 11.2 mongo-express

http://localhost:8091。env 配置：

```
ME_CONFIG_MONGODB_URL=mongodb://root:root123@mongo1:27017,mongo2:27017,mongo3:27017/?replicaSet=rs0&authSource=admin
ME_CONFIG_BASICAUTH_USERNAME=admin
ME_CONFIG_BASICAUTH_PASSWORD=admin123
```

## 12. 资源限制

| 容器组 | CPU limits | Memory limits |
|---|---|---|
| `pg1/2/3` | 1.0 | 2GB |
| `pg-haproxy1/2`、`pgbouncer` | 0.5 | 256MB |
| `pg-init` | 0.5 | 256MB |
| `postgres-exporter` | 0.2 | 128MB |
| `mongo1/2/3` | 1.0 | 2GB |
| `mongo-init` | 0.5 | 256MB |
| `pbm-agent1/2/3` | 0.3 | 256MB |
| `mongo-express` | 0.3 | 256MB |
| `mongodb-exporter` | 0.2 | 128MB |

Podman/Docker compose v2 都支持 `deploy.resources.limits`（无须 swarm mode）。

## 13. 新增文件清单

```
env/
├── docs/specs/2026-05-16-postgres-mongo-prod-design.md   # 本文档
├── postgres/
│   ├── spilo-extra.yaml          # SPILO_CONFIGURATION 注入内容（参考用，compose 里展开）
│   ├── haproxy.cfg
│   ├── pgbouncer.ini
│   ├── userlist.txt
│   ├── init-users.sql
│   └── post-init.sh              # pg-init 容器入口
├── mongodb/
│   ├── init-replset.js
│   ├── pbm-config.yaml
│   └── mongo-express.env
├── pki/
│   ├── mk-pki.sh                 # 生成 mongo.keyfile（PG 走 Spilo 自签）
│   └── init-minio-buckets.sh     # mc mb minio/wal-archive minio/pbm
└── compose.yml                   # 加入 15 个新服务
```

变更涉及的已有文件：

- `compose.yml`：追加新服务（不动现有）
- `prometheus/prometheus.yml`：新增 3 个 scrape job
- `homer/config.yml`：新增 PG / Mongo / mongo-express 入口
- `SERVICES.md`：补全清单
- `README.md`：补启动顺序与备份说明
- `.gitignore`：忽略 `pki/*.key`、`pki/*.keyfile`、`pki/*.crt`

## 14. 部署 / 启动顺序

新机器从零起步：

```bash
# 1. 生成 Mongo keyFile
./pki/mk-pki.sh

# 2. 拉起基础依赖（etcd + MinIO 必须先 ready）
podman compose up -d etcd1 etcd2 etcd3 minio

# 3. 创建备份 bucket
./pki/init-minio-buckets.sh

# 4. 启动 PG 主集群（Patroni 自动选主）
podman compose up -d pg1 pg2 pg3
# 等待 ~30s 直到 patronictl 看到 leader
podman exec pg1 patronictl list

# 5. 启动 HAProxy + PgBouncer
podman compose up -d pg-haproxy1 pg-haproxy2 pgbouncer

# 6. 初始化业务用户
podman compose up pg-init   # 一次性，自动退出

# 7. 启动 Mongo RS
podman compose up -d mongo1 mongo2 mongo3
podman compose up mongo-init   # 一次性，rs.initiate + users

# 8. 启动 PBM agents（mongo-init 完成后）
podman compose up -d pbm-agent1 pbm-agent2 pbm-agent3
podman exec pbm-agent1 pbm config --file=/etc/pbm/pbm-config.yaml

# 9. 启动其他周边
podman compose up -d postgres-exporter mongodb-exporter mongo-express

# 10. 完整启动剩余 env 服务
podman compose up -d
```

## 15. 回滚

```bash
podman compose down \
  pg1 pg2 pg3 pg-haproxy1 pg-haproxy2 pgbouncer pg-init postgres-exporter \
  mongo1 mongo2 mongo3 mongo-init pbm-agent1 pbm-agent2 pbm-agent3 \
  mongo-express mongodb-exporter

rm -rf data/pg data/mongo
git revert <this commit hash>
podman compose up -d   # 原有服务不受影响
```

旧 env 中没有任何服务依赖 PG/Mongo（Bytebase 默认使用其内置 sqlite，etcd / Kafka / MinIO 也独立运行），所以回滚不影响现有功能。

## 16. 已知遗留 / 后续

- TLS 客户端强制验证（mTLS）作为后续选项，需要扩 PKI 与 pg_hba
- Grafana dashboard 模板暂未捆绑：可后续 provisioning `postgres-overview`、`mongodb-replset` 两份 community dashboard
- PG 主从延迟告警规则：等 dashboard 同步推
- PBM 首启需手动 `pbm config --file`：可后续做成 pbm-init 一次性容器
- 密码全部为 dev placeholder：生产部署前必须用 `.env`/secrets 替换（README 已注明）
