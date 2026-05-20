#!/bin/bash
# 列出所有 APISIX 路由
set -euo pipefail
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"

curl -sS -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/routes" | python3 -m json.tool
