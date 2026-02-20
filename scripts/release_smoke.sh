#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENVIRONMENT="${1:-prod}"

if [ "$ENVIRONMENT" = "prod" ]; then
  ENV_FILE="$INFRA_DIR/.env"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend"
elif [ "$ENVIRONMENT" = "staging" ]; then
  ENV_FILE="$INFRA_DIR/.env.staging"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend-staging"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend-staging"
else
  echo "Uso: $0 [prod|staging]"
  exit 1
fi

errors=0
SMOKE_PUBLIC="${RELEASE_SMOKE_PUBLIC:-true}"
ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

env_get() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit}' "$file" 2>/dev/null || true
}

first_origin() {
  local raw="$1"
  printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed -n '1p'
}

echo "== Smoke release (${ENVIRONMENT}) =="

if docker exec "$BACKEND_CONTAINER" node -e "const http=require('http');const req=http.get('http://127.0.0.1:4000/health',res=>process.exit(res.statusCode===200?0:1));req.on('error',()=>process.exit(1));"; then
  ok "backend /health via loopback do container"
else
  fail "backend /health via loopback do container"
fi

if docker exec "$FRONTEND_CONTAINER" sh -lc "wget -q -O - http://127.0.0.1/ >/dev/null 2>&1"; then
  ok "frontend / via loopback do container"
else
  fail "frontend / via loopback do container"
fi

if [ "$SMOKE_PUBLIC" = "true" ]; then
  origin="${RELEASE_SMOKE_ORIGIN:-}"
  if [ -z "$origin" ] && [ -f "$ENV_FILE" ]; then
    origin="$(first_origin "$(env_get "$ENV_FILE" "ALLOWED_ORIGINS")")"
  fi

  if [ -n "$origin" ]; then
    if curl -fsS -o /dev/null --max-time 10 "$origin/"; then
      ok "frontend publico acessivel em ${origin}/"
    else
      fail "frontend publico indisponivel em ${origin}/"
    fi

    auth_status="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "$origin/api/auth/me" || true)"
    if [ "$auth_status" = "200" ] || [ "$auth_status" = "401" ] || [ "$auth_status" = "403" ]; then
      ok "backend publico respondeu em /api/auth/me (HTTP ${auth_status})"
    else
      fail "backend publico retornou HTTP ${auth_status:-000} em /api/auth/me"
    fi
  else
    echo "WARN: smoke publico ignorado (RELEASE_SMOKE_ORIGIN/ALLOWED_ORIGINS ausente)."
  fi
else
  echo "WARN: smoke publico desativado (RELEASE_SMOKE_PUBLIC=${SMOKE_PUBLIC})."
fi

echo "== Resultado smoke =="
echo "Erros: $errors"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
