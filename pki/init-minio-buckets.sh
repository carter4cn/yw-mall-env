#!/bin/bash
# 创建 PG / Mongo 备份所需的 MinIO bucket。
# 依赖 mc（MinIO Client）容器或本地安装。这里用一次性容器避免污染主机。
set -euo pipefail

MINIO_HOST="${MINIO_HOST:-http://minio:9000}"
MINIO_USER="${MINIO_USER:-admin}"
MINIO_PASS="${MINIO_PASS:-admin123}"

# 通过 podman / docker run 一次性 mc 镜像
RUNTIME="${RUNTIME:-podman}"

# 网络名：compose 项目会给基础网络加项目前缀（默认 <projectname>_infra）。
# 优先读 NETWORK 环境变量，否则从已经在跑的 minio 容器里探测出来。
NETWORK="${NETWORK:-$($RUNTIME inspect minio --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || echo)}"
if [[ -z "$NETWORK" ]]; then
  echo "ERROR: 无法自动探测到 minio 容器所在网络，请先 'compose up -d minio' 或显式传 NETWORK=env_infra ./pki/init-minio-buckets.sh" >&2
  exit 1
fi
echo "using network: $NETWORK"

$RUNTIME run --rm --network "$NETWORK" --entrypoint /bin/sh docker.io/minio/mc:latest -c "
  mc alias set local $MINIO_HOST $MINIO_USER $MINIO_PASS &&
  mc mb --ignore-existing local/wal-archive &&
  mc mb --ignore-existing local/pbm &&
  mc ls local/
"

echo "buckets ready: wal-archive, pbm"
