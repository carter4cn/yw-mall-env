#!/bin/bash
# 创建 PG / Mongo 备份所需的 MinIO bucket。
# 依赖 mc（MinIO Client）容器或本地安装。这里用一次性容器避免污染主机。
set -euo pipefail

MINIO_HOST="${MINIO_HOST:-http://minio:9000}"
MINIO_USER="${MINIO_USER:-admin}"
MINIO_PASS="${MINIO_PASS:-admin123}"

# 通过 podman / docker run 一次性 mc 镜像
RUNTIME="${RUNTIME:-podman}"

$RUNTIME run --rm --network infra docker.io/minio/mc:latest sh -c "
  mc alias set local $MINIO_HOST $MINIO_USER $MINIO_PASS &&
  mc mb --ignore-existing local/wal-archive &&
  mc mb --ignore-existing local/pbm &&
  mc ls local/
"

echo "buckets ready: wal-archive, pbm"
