#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENVIRONMENT="${1:-prod}"

if [ "$ENVIRONMENT" = "prod" ]; then
  ENV_FILE="$INFRA_DIR/.env"
  LOCAL_FRONTEND_URL="${LOCAL_FRONTEND_URL:-http://127.0.0.1:4001/}"
elif [ "$ENVIRONMENT" = "staging" ]; then
  ENV_FILE="$INFRA_DIR/.env.staging"
  LOCAL_FRONTEND_URL="${LOCAL_FRONTEND_URL:-http://127.0.0.1:4101/}"
else
  echo "Uso: $0 [prod|staging]"
  exit 1
fi

errors=0
warnings=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }
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

check_headers() {
  local url="$1"
  local label="$2"
  local headers

  if ! headers="$(curl -fsS -I --max-time 10 "$url" 2>/dev/null)"; then
    warn "${label}: indisponivel (${url})"
    return
  fi

  echo "$headers" | grep -qi '^strict-transport-security:' && ok "${label}: HSTS presente" || warn "${label}: HSTS ausente"
  echo "$headers" | grep -qi '^content-security-policy:' && ok "${label}: CSP presente" || warn "${label}: CSP ausente"
  echo "$headers" | grep -qi '^x-content-type-options:[[:space:]]*nosniff' && ok "${label}: X-Content-Type-Options=nosniff" || warn "${label}: X-Content-Type-Options ausente/invalido"
  echo "$headers" | grep -qi '^referrer-policy:' && ok "${label}: Referrer-Policy presente" || warn "${label}: Referrer-Policy ausente"
}

check_public_ports() {
  local exposed
  exposed="$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0:' || true)"
  if [ -z "$exposed" ]; then
    ok "nenhum container com bind publico em 0.0.0.0"
    return
  fi

  local flagged=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s' "$line" | awk '{print $1}')"
    case "$name" in
      nginx-proxy-manager|cloudflared-portal-eco|portaleco-panel|portainer)
        warn "bind publico permitido/revisar: $line"
        ;;
      *)
        fail "bind publico inesperado: $line"
        flagged=1
        ;;
    esac
  done <<<"$exposed"

  if [ "$flagged" -eq 0 ]; then
    ok "binds publicos apenas em servicos esperados"
  fi
}

echo "== Security check (${ENVIRONMENT}) =="

check_headers "$LOCAL_FRONTEND_URL" "frontend local"

if [ -f "$ENV_FILE" ]; then
  origin="$(first_origin "$(env_get "$ENV_FILE" "ALLOWED_ORIGINS")")"
  if [ -n "$origin" ]; then
    check_headers "$origin/" "frontend publico"
  else
    warn "ALLOWED_ORIGINS vazio em $(basename "$ENV_FILE")"
  fi
else
  warn "arquivo de ambiente ausente: $ENV_FILE"
fi

check_public_ports

echo "== Resultado security check =="
echo "Erros: $errors"
echo "Avisos: $warnings"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
