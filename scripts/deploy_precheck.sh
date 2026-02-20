#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENVIRONMENT="${1:-prod}"

if [ "$ENVIRONMENT" = "prod" ]; then
  ENV_FILE="$INFRA_DIR/.env"
  COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
elif [ "$ENVIRONMENT" = "staging" ]; then
  ENV_FILE="$INFRA_DIR/.env.staging"
  COMPOSE_FILE="$INFRA_DIR/docker-compose.staging.yml"
else
  echo "Uso: $0 [prod|staging]"
  exit 1
fi

errors=0
ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

env_get() {
  local key="$1"
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit}' "$ENV_FILE" 2>/dev/null || true
}

if [ ! -f "$ENV_FILE" ]; then
  fail "arquivo de ambiente ausente: $ENV_FILE"
else
  ok "arquivo de ambiente encontrado: $ENV_FILE"

  auth_fail="$(env_get AUTH_FAIL_ON_INSECURE_DEFAULTS)"
  allowed_origins="$(env_get ALLOWED_ORIGINS)"
  token_secret="$(env_get AUTH_TOKEN_SECRET)"
  auth_password="$(env_get AUTH_PASSWORD)"

  if [ "$auth_fail" = "true" ]; then
    ok "AUTH_FAIL_ON_INSECURE_DEFAULTS=true"
  else
    fail "AUTH_FAIL_ON_INSECURE_DEFAULTS precisa ser true"
  fi

  if [ -n "$allowed_origins" ] && printf '%s' "$allowed_origins" | rg -q 'https://'; then
    ok "ALLOWED_ORIGINS definido com https"
  else
    fail "ALLOWED_ORIGINS vazio ou invalido"
  fi

  if [ -n "$token_secret" ] && [ "$token_secret" != "change-this-token-secret" ] && [ "${#token_secret}" -ge 32 ]; then
    ok "AUTH_TOKEN_SECRET valido"
  else
    fail "AUTH_TOKEN_SECRET invalido/fraco"
  fi

  if [ -n "$auth_password" ] && [ "$auth_password" != "change-me" ] && [ "${#auth_password}" -ge 8 ]; then
    ok "AUTH_PASSWORD valido"
  else
    fail "AUTH_PASSWORD invalido/fraco"
  fi
fi

if [ -f "$COMPOSE_FILE" ]; then
  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null; then
    ok "docker compose config valido"
  else
    fail "docker compose config invalido"
  fi
else
  fail "compose file ausente: $COMPOSE_FILE"
fi

if [ "$errors" -gt 0 ]; then
  echo "Precheck falhou com ${errors} erro(s)."
  exit 1
fi

echo "Precheck de deploy (${ENVIRONMENT}) concluido com sucesso."
