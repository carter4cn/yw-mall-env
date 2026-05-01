# yw-mall-env

[yw-mall](https://github.com/carter4cn/yw-mall) 微服务系统的本地一体化基础设施：用 Docker / Podman 一条 `compose.yml` 拉起 Kafka、Pulsar、MySQL（一主多从 + ProxySQL）、Redis（Sentinel）、Etcd、DTM、MinIO、Bytebase、Grafana / Prometheus、Homer 仪表盘等。

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
├── grafana/provisioning/          Grafana 数据源 / Dashboard 自动配置
├── homer/config.yml               Homer 仪表盘（http://localhost:8888）
├── kafka/server{1,2,3}.properties Kafka KRaft 三节点配置
├── mysql/                         主从复制 + ProxySQL 配置
│   ├── master{1,2}.cnf
│   ├── slave{1,2}.cnf
│   ├── proxysql.cnf
│   ├── init-repl.sql
│   └── setup-replication.sh
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

## 默认账号 / 密码

仅用于本地开发，详细列表见 [`SERVICES.md`](./SERVICES.md)。常用：

| 组件 | 账号 | 密码 |
|------|------|------|
| MySQL root | `root` | `root123` |
| MySQL ProxySQL 业务账号 | `proxysql` | `proxysql123` |
| MySQL 主从复制账号 | `repl` | `repl123` |
| Grafana | `admin` | `admin123` |
| MinIO | `admin` | `admin123` |
| Pulsar Manager | `admin` | `admin123` |

> 这些都是 dev placeholder，**生产环境必须替换**。

## 端口速查

完整列表见 `SERVICES.md`。常用：

| 服务 | 端口 |
|------|------|
| Homer 仪表盘 | 8888 |
| Kafka brokers | 19092 / 19093 / 19094 |
| MySQL ProxySQL | 6033（业务）、6032（admin） |
| Redis Sentinel | 26379 / 26380 / 26381 |
| Etcd | 2379 |
| DTM | 36789（HTTP）/ 36790（gRPC） |
| MinIO | 9000（S3）/ 9001（控制台） |
| Grafana | 3000 |
| Prometheus | 9090 |
| Bytebase | 8090 |
