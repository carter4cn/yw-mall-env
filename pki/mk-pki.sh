#!/bin/bash
# 生成 yw-mall-env 需要的 PKI 物料。
# 当前仅生成 MongoDB ReplicaSet 内部鉴权用的 keyFile。
# PG 由 Spilo 镜像在启动时自签 server cert，不在此处生成。
set -euo pipefail

cd "$(dirname "$0")"

KEYFILE="mongo.keyfile"

if [[ ! -f "$KEYFILE" ]]; then
  openssl rand -base64 756 > "$KEYFILE"
  chmod 600 "$KEYFILE"
  echo "generated $KEYFILE"
else
  echo "$KEYFILE already exists, leave it alone"
fi

# 容器内 mongodb uid/gid 是 999。rootless podman 用 userns keep-id 模式时不需要改；
# 如果是 rootful podman / docker，需要 host 上 chown 999:999。
# 这里只确保权限位正确，所有权由用户根据 runtime 自行处理。
ls -l "$KEYFILE"
