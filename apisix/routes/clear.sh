#!/bin/bash
# 清空所有路由 + upstream（不影响 dashboard 用户/插件配置）
set -euo pipefail
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"

echo "=== 清空 routes ==="
ids=$(curl -sS -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/routes" \
  | python3 -c "import json,sys;[print((r.get('value') or r).get('id','')) for r in (json.load(sys.stdin).get('list') or [])]")
for id in $ids; do
  [[ -z "$id" ]] && continue
  curl -sS -X DELETE -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/routes/$id" > /dev/null
  echo "  - deleted route: $id"
done

echo "=== 清空 upstreams ==="
ids=$(curl -sS -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/upstreams" \
  | python3 -c "import json,sys;[print((r.get('value') or r).get('id','')) for r in (json.load(sys.stdin).get('list') or [])]")
for id in $ids; do
  [[ -z "$id" ]] && continue
  curl -sS -X DELETE -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/upstreams/$id" > /dev/null
  echo "  - deleted upstream: $id"
done
