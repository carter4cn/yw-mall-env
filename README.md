# yw-mall-env

[yw-mall](https://github.com/carter4cn/yw-mall) 微服务系统的本地一体化基础设施：用 Docker / Podman 一条 `compose.yml` 拉起 Kafka、Pulsar、MySQL（双主双从 + ProxySQL）、**PostgreSQL（Patroni + HAProxy + PgBouncer）**、**MongoDB（3 节点 ReplicaSet + PBM 备份）**、Redis（Sentinel）、Etcd、DTM、MinIO、Bytebase、Grafana / Prometheus、Homer 仪表盘等。

> 推荐目录布局：把本仓库 clone 到 yw-mall **同级**目录，因为 `yw-mall/start.sh` 引用 `../env`：
>
> ```
> workspace/
> ├── yw-mall/        # https://github.com/carter4cn/yw-mall
> └── env/            # 本仓库（clone 时改名为 env：git clone … env）
> ```

## 包含的内容

```
env/
├── compose.yml                    所有基础设施容器编排
├── SERVICES.md                    全量服务清单 / 端口 / 账号密码
├── docs/specs/                    架构 / 变更记录设计文档
├── grafana/provisioning/          Grafana 数据源 / Dashboard 自动配置
├── homer/config.yml               Homer 仪表盘（http://localhost:8888）
├── kafka/server{1,2,3}.properties Kafka KRaft 三节点配置
├── mysql/                         主从复制 + ProxySQL 配置
│   ├── master{1,2}.cnf
│   ├── slave{1,2}.cnf
│   ├── proxysql.cnf
│   ├── init-repl.sql
│   └── setup-replication.sh
├── postgres/                      PG HA（Patroni + HAProxy + PgBouncer）配置
│   ├── spilo-extra.yaml           SPILO_CONFIGURATION 参考（compose 内同步）
│   ├── haproxy.cfg
│   ├── pgbouncer.ini
│   ├── userlist.txt
│   ├── init-users.sql
│   └── post-init.sh
├── mongodb/                       Mongo RS + PBM 配置
│   ├── mongod.conf                参考配置（compose command 同步）
│   ├── init-replset.js
│   ├── pbm-config.yaml
│   └── mongo-express.env
├── pki/                           本地 PKI 生成脚本
│   ├── mk-pki.sh                  生成 mongo.keyfile
│   └── init-minio-buckets.sh      创建 wal-archive + pbm bucket
├── prometheus/prometheus.yml      抓取目标
└── redis/sentinel*.conf           Redis Sentinel 配置
```

> `data/` 目录是容器运行时数据（MySQL data dir、Redis aof 等，约 900 MB），已加入 `.gitignore`。首次 `up` 时会自动重建。

## 快速启动

```bash
# 用 docker 或 podman 都行
docker compose -f compose.yml up -d
# 或
podman compose -f compose.yml up -d
```

启动完成后打开 [Homer](http://localhost:8888) 看一站式入口。

> 在 yw-mall 下用 `./start.sh` 也会自动检查并拉起本仓库的基础设施。

## Compose Profiles（按需启停）

env 默认只起 **yw-mall 必备的 baseline**（约 17 个容器：etcd1、kafka1、mysql 1主1从、redis 1主2从+3 Sentinel、minio、prometheus、grafana、homer、dtm）。其余按 `profiles:` 分组：

### 业务 profile（每个组件一个）

| Profile | 包含 | 单节点内存 |
|---|---|---|
| _baseline_ | etcd1、kafka1、mysql 1主1从、redis 全套、minio、prom+graf、homer、dtm | ~3.5 GB |
| `mq-extras` | kafka-exporter、kafka-ui、etcdkeeper | ~400 MB |
| `pulsar` | pulsar-zk + bookie×3 + broker×2 + manager + init | ~2 GB |
| `search` | es1（默认单节点） | ~530 MB |
| `olap` | doris-fe + be1/2 | ~1.3 GB |
| `db-tools` | bytebase | ~300 MB |
| `pg` | pg1 + haproxy×1 + pgbouncer + pg-init + postgres-exporter | ~700 MB |
| `mongo` | mongo1 + mongo-init + mongo-express + mongodb-exporter | ~800 MB |
| `gateway` | apisix + apisix-dashboard | ~200 MB |

### HA 扩展 profile（在业务 profile 之上叠加，把单节点变集群）

| Profile | 加什么 | 增量内存 |
|---|---|---|
| `etcd-ha` | etcd2、etcd3 | ~60 MB |
| `kafka-ha` | kafka2、kafka3 | ~1.7 GB |
| `mysql-ha` | mysql-master2、mysql-slave2 | ~380 MB |
| `search-ha` | es2、es3 | ~1.1 GB |
| `pg-ha` | pg2、pg3、pg-haproxy2 | ~1.3 GB |
| `mongo-ha` | mongo2、mongo3、pbm-agent×3 | ~3 GB |

### 用法

```bash
# Slim 模式（开发默认，单机 < 16 GB 可用即可）
podman compose -f compose.yml -f compose.lite.yml \
  --profile pg --profile mongo --profile search up -d

# 加 HA 副本（演示完整生产拓扑，需要 ≥ 24 GB 可用内存）
podman compose -f compose.yml \
  --profile pg --profile pg-ha \
  --profile mongo --profile mongo-ha \
  --profile search --profile search-ha \
  --profile kafka-ha --profile mysql-ha --profile etcd-ha \
  up -d

# 用环境变量等价：
COMPOSE_PROFILES=pg,pg-ha,mongo,mongo-ha podman compose up -d

# 停某个 profile（数据卷保留）
podman compose --profile pulsar stop

# 关掉 HA 副本回到 slim
podman compose --profile pg-ha --profile mongo-ha --profile kafka-ha stop
```

### Slim 模式（`compose.lite.yml`）做了什么

针对单机内存 < 16 GB 可用的场景，叠加 `-f compose.lite.yml` 后会：

- **Kafka**：单 broker + heap 256m + topic 复制因子 1
- **ES**：`discovery.type=single-node` + heap 256m
- **PG（Spilo）**：关掉 wal-g 备份、`shared_buffers=64MB`、`synchronous_mode=false`（单节点必须）
- **Mongo**：`wiredTigerCacheSizeGB=0.25`、`oplogSize=512`、单成员 RS
- **mongo-init / mysql-init**：切到 lite 版初始化脚本（只配单节点）

Slim 模式下完整 yw-mall 链路（baseline + pg + mongo + search + mq-extras）总内存约 **5.7 GB**，加桌面 + IDE 跑在 16 GB 机器都顺手。后续要做 failover 演练再叠 HA profile。

### PostgreSQL / MongoDB 首次启动

### PostgreSQL / MongoDB 首次启动

PG / Mongo 集群需要一次性 bootstrap，按下面顺序执行（已有集群可跳过 `mk-pki.sh` 和 bucket 初始化）：

```bash
# 1) 生成 Mongo keyFile（已存在则跳过）
./pki/mk-pki.sh

# 2) baseline + 准备工作（etcd / minio 已经包含在 baseline 里）
podman compose up -d

# 3) 创建备份桶
./pki/init-minio-buckets.sh

# 4) 拉起 PG profile（一次性 pg-init 会自动退出）
podman compose --profile pg up -d

# 5) 拉起 Mongo profile（mongo-init 一次性容器自动退出）
podman compose --profile mongo up -d
podman exec pbm-agent1 pbm config --file=/etc/pbm/pbm-config.yaml   # 首次推送 PBM 配置
```

> 详细架构与决策见 [`docs/specs/2026-05-16-postgres-mongo-prod-design.md`](./docs/specs/2026-05-16-postgres-mongo-prod-design.md)。

## 默认账号 / 密码

仅用于本地开发，详细列表见 [`SERVICES.md`](./SERVICES.md)。常用：

| 组件 | 账号 | 密码 |
|------|------|------|
| MySQL root | `root` | `root123` |
| MySQL ProxySQL 业务账号 | `proxysql` | `proxysql123` |
| MySQL 主从复制账号 | `repl` | `repl123` |
| PostgreSQL postgres | `postgres` | `postgres123` |
| PostgreSQL 业务读写 | `app_rw` | `apprw123` |
| PostgreSQL 业务只读 | `app_ro` | `appro123` |
| MongoDB root | `root` | `root123` |
| MongoDB 业务读写 | `app_rw` | `apprw123` |
| MongoDB 业务只读 | `app_ro` | `appro123` |
| Grafana | `admin` | `admin123` |
| MinIO | `admin` | `admin123` |
| Pulsar Manager | `admin` | `admin123` |
| mongo-express | `admin` | `admin123` |

> 这些都是 dev placeholder，**生产环境必须替换**（建议改用 `.env` 文件 + secrets，不直接改 `compose.yml`）。

## 端口速查

完整列表见 `SERVICES.md`。常用：

| 服务 | 端口 |
|------|------|
| Homer 仪表盘 | 8888 |
| Kafka brokers | 19092 / 19093 / 19094 |
| MySQL ProxySQL | 6033（业务）、6032（admin） |
| PostgreSQL（PgBouncer） | 5432（业务）、5433（直连写）、5434（只读） |
| PG HAProxy stats | 8008（pg-haproxy1）、8009（pg-haproxy2） |
| MongoDB RS | 27017 / 27018 / 27019 |
| mongo-express | 8091 |
| Redis Sentinel | 26379 / 26380 / 26381 |
| Etcd | 2379 |
| DTM | 36789（HTTP）/ 36790（gRPC） |
| MinIO | 9000（S3）/ 9001（控制台） |
| Grafana | 3000 |
| Prometheus | 9090 |
| Bytebase | 8090 |
