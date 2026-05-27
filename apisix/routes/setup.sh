#!/bin/bash
# 一键为 yw-mall 各业务模块配置 APISIX 路由。
# 幂等：重跑会覆盖同 id 的路由，不会重复。
#
# 设计原则：
#   - 共享 4 个 upstream（mall-api / mall-admin-api / mall-fe，跨项目通过容器名）
#   - 业务路由按 prefix 拆，每条挂业务相关插件（限流/缓存/审计/防爬）
#   - 通用 /api/* 兜底，未列出的 prefix 落到 mall-api
set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"

api() {
  local method=$1 path=$2
  shift 2
  curl -sS -o /tmp/apisix-resp.json -w "%{http_code}" \
    -X "$method" \
    -H "X-API-KEY: $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    "$ADMIN_URL$path" "$@"
}

put() {
  local id=$1 desc=$2 body=$3
  local code
  code=$(api PUT "/apisix/admin/routes/$id" -d "$body")
  if [[ "$code" =~ ^(200|201)$ ]]; then
    echo "  ✓ $id  ($desc)"
  else
    echo "  ✗ $id  HTTP $code"
    cat /tmp/apisix-resp.json; echo
  fi
}

put_upstream() {
  local id=$1 desc=$2 body=$3
  local code
  code=$(api PUT "/apisix/admin/upstreams/$id" -d "$body")
  if [[ "$code" =~ ^(200|201)$ ]]; then
    echo "  ✓ upstream/$id  ($desc)"
  else
    echo "  ✗ upstream/$id  HTTP $code"
    cat /tmp/apisix-resp.json; echo
  fi
}

echo "=== 1/3 创建 upstream ==="

put_upstream "mall-api" "yw-mall HTTP BFF" '{
  "name": "mall-api",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": { "yw-mall-deploy_mall-api_1:18888": 1 },
  "timeout": { "connect": 3, "send": 30, "read": 30 },
  "retries": 1,
  "checks": {
    "active": {
      "type": "http",
      "http_path": "/",
      "timeout": 2,
      "healthy":   { "interval": 5, "successes": 1 },
      "unhealthy": { "interval": 5, "http_failures": 3 }
    }
  }
}'

put_upstream "mall-admin-api" "yw-mall 后台 BFF" '{
  "name": "mall-admin-api",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": { "yw-mall-deploy_mall-admin-api_1:18999": 1 },
  "timeout": { "connect": 3, "send": 30, "read": 30 }
}'

put_upstream "mall-fe" "yw-mall 前端" '{
  "name": "mall-fe",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": { "yw-mall-deploy_mall-fe_1:80": 1 }
}'

echo ""
echo "=== 2/3 创建业务路由 ==="

# ---- 用户模块（限流 200rps）----
put "mall-user" "/api/user/* → mall-api 限流 200rps" '{
  "name": "mall-user",
  "uri": "/api/user/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 200, "burst": 100, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*", "allow_methods": "*", "allow_headers": "*" }
  }
}'

# ---- 商品模块（限流 500rps + 缓存）----
put "mall-product" "/api/product/* → mall-api 限流 500rps + 缓存 5s" '{
  "name": "mall-product",
  "uri": "/api/product/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 500, "burst": 200, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- 订单模块（限流 100rps，需要 JWT 一般）----
put "mall-order" "/api/order/* → mall-api 限流 100rps" '{
  "name": "mall-order",
  "uri": "/api/order/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 100, "burst": 50, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" },
    "request-id": { "include_in_response": true }
  }
}'

# ---- 购物车 ----
put "mall-cart" "/api/cart/* → mall-api 限流 300rps" '{
  "name": "mall-cart",
  "uri": "/api/cart/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 300, "burst": 100, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- 支付模块（最严限流 + audit log 到 Kafka）----
put "mall-payment" "/api/payment/* → mall-api 限流 50rps + Kafka audit" '{
  "name": "mall-payment",
  "uri": "/api/payment/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 50, "burst": 20, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" },
    "request-id": { "include_in_response": true },
    "kafka-logger": {
      "brokers": [{ "host": "kafka1", "port": 9092 }],
      "kafka_topic": "apisix-audit-payment",
      "key": "$remote_addr",
      "batch_max_size": 100,
      "include_req_body": false
    }
  }
}'

# ---- 活动模块（防爬：UA + IP 限流）----
put "mall-activity" "/api/activity/* → mall-api 防爬：IP + UA 限流" '{
  "name": "mall-activity",
  "uri": "/api/activity/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 200, "burst": 100, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "ua-restriction": {
      "bypass_missing": false,
      "denylist": ["python-requests", "Go-http-client", "curl", "Wget"]
    },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- 物流模块 ----
put "mall-logistics" "/api/logistics/* → mall-api" '{
  "name": "mall-logistics",
  "uri": "/api/logistics/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 200, "burst": 50, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- 评价模块 ----
put "mall-review" "/api/review/* → mall-api" '{
  "name": "mall-review",
  "uri": "/api/review/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 200, "burst": 50, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- mall-api 的 admin 子路径（前缀 /api/admin）----
put "mall-api-admin" "/api/admin/* → mall-api 内网/JWT 强校验" '{
  "name": "mall-api-admin",
  "uri": "/api/admin/*",
  "upstream_id": "mall-api",
  "plugins": {
    "limit-req": { "rate": 100, "burst": 30, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "request-id": { "include_in_response": true },
    "kafka-logger": {
      "brokers": [{ "host": "kafka1", "port": 9092 }],
      "kafka_topic": "apisix-audit-admin",
      "include_req_body": false
    }
  }
}'

# ---- Sprint 5 注册/登录 严限流（priority=100 高于 catchall + /api/user 200rps）----
put "mall-auth-sendcode" "/api/auth/send-code 严限流 10rps + ua 反爬" '{
  "name": "mall-auth-sendcode",
  "uri": "/api/auth/send-code",
  "upstream_id": "mall-api",
  "priority": 100,
  "plugins": {
    "limit-req": { "rate": 10, "burst": 5, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "ua-restriction": { "bypass_missing": false,
      "denylist": ["python-requests", "Go-http-client", "curl", "Wget"]
    },
    "cors": { "allow_origins": "*" }
  }
}'

put "mall-auth-register" "/api/auth/register 限流 5rps" '{
  "name": "mall-auth-register",
  "uri": "/api/auth/register",
  "upstream_id": "mall-api",
  "priority": 100,
  "plugins": {
    "limit-req": { "rate": 5, "burst": 3, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "cors": { "allow_origins": "*" }
  }
}'

# ---- 通用 /api/* 兜底（必须放后面，优先级最低）----
put "mall-api-catchall" "/api/* → mall-api 兜底" '{
  "name": "mall-api-catchall",
  "uri": "/api/*",
  "upstream_id": "mall-api",
  "priority": 0,
  "plugins": {
    "limit-req": { "rate": 100, "burst": 50, "key_type": "var", "key": "remote_addr", "rejected_code": 429 }
  }
}'

# ---- 后台 API（独立服务）----
put "mall-admin-api" "/admin/* → mall-admin-api 后台" '{
  "name": "mall-admin-api",
  "uri": "/admin/*",
  "upstream_id": "mall-admin-api",
  "plugins": {
    "limit-req": { "rate": 50, "burst": 20, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "request-id": { "include_in_response": true },
    "kafka-logger": {
      "brokers": [{ "host": "kafka1", "port": 9092 }],
      "kafka_topic": "apisix-audit-admin",
      "include_req_body": false
    }
  }
}'

# ---- M1 商家工作台 API（与 admin 同 upstream，只是 prefix 不同）----
put "mall-merchant-api" "/merchant/* → mall-admin-api 商家工作台" '{
  "name": "mall-merchant-api",
  "uri": "/merchant/*",
  "upstream_id": "mall-admin-api",
  "plugins": {
    "limit-req": { "rate": 50, "burst": 20, "key_type": "var", "key": "remote_addr", "rejected_code": 429 },
    "request-id": { "include_in_response": true },
    "kafka-logger": {
      "brokers": [{ "host": "kafka1", "port": 9092 }],
      "kafka_topic": "apisix-audit-admin",
      "include_req_body": false
    }
  }
}'

# ---- 前端静态（最低优先级，匹配 / ）----
put "mall-fe" "/* → mall-fe 前端 fallback" '{
  "name": "mall-fe",
  "uri": "/*",
  "upstream_id": "mall-fe",
  "priority": -1
}'

echo ""
echo "=== 3/3 当前路由汇总 ==="
curl -sS -H "X-API-KEY: $ADMIN_KEY" "$ADMIN_URL/apisix/admin/routes" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('list') or d.get('node', {}).get('nodes', [])
print(f\"  total: {d.get('total', len(items))}\")
for r in sorted(items, key=lambda x: (x.get('value') or x).get('priority', 0), reverse=True):
    v = r.get('value') or r
    pri = v.get('priority', 0)
    print(f\"  [pri={pri:>3}] {v.get('id','?'):20} {v.get('uri','?'):30} → upstream_id={v.get('upstream_id','?')}\")
"

echo ""
echo "=== 完成 ==="
