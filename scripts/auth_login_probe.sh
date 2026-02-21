#!/bin/bash
set -euo pipefail

TARGET="${1:-prod}"

case "$TARGET" in
  prod)
    ENV_FILE="infra/.env"
    ;;
  staging)
    ENV_FILE="infra/.env.staging"
    ;;
  *)
    echo "Uso: $0 [prod|staging]"
    exit 1
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "FAIL: arquivo de ambiente ausente: $ENV_FILE"
  exit 1
fi

env_get() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit}' "$file" 2>/dev/null || true
}

first_origin() {
  local raw="$1"
  printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed -n '1p'
}

username="$(env_get "$ENV_FILE" "AUTH_USERNAME")"
password="$(env_get "$ENV_FILE" "AUTH_PASSWORD")"
origin="$(first_origin "$(env_get "$ENV_FILE" "ALLOWED_ORIGINS")")"

if [ -z "$username" ] || [ -z "$password" ]; then
  echo "FAIL: AUTH_USERNAME/AUTH_PASSWORD ausentes em $ENV_FILE"
  exit 1
fi

if [ -z "$origin" ]; then
  echo "FAIL: ALLOWED_ORIGINS ausente em $ENV_FILE"
  exit 1
fi

cookie_file="$(mktemp)"
trap 'rm -f "$cookie_file"' EXIT

login_code="$(
  curl -ksS -o /tmp/auth_login_probe_body.$$ -w '%{http_code}' \
    -H 'content-type: application/json' \
    -c "$cookie_file" \
    --data "{\"username\":\"$username\",\"password\":\"$password\"}" \
    --max-time 12 \
    "$origin/api/auth/login" || true
)"
rm -f /tmp/auth_login_probe_body.$$ 2>/dev/null || true

if [ "$login_code" != "200" ]; then
  echo "FAIL: login retornou HTTP ${login_code:-000} em $origin/api/auth/login"
  exit 1
fi

if ! grep -q "portaleco_vps_monitor_auth" "$cookie_file"; then
  echo "FAIL: login nao retornou cookie de sessao."
  exit 1
fi

me_code="$(
  curl -ksS -o /tmp/auth_me_probe_body.$$ -w '%{http_code}' \
    -b "$cookie_file" \
    --max-time 12 \
    "$origin/api/auth/me" || true
)"
rm -f /tmp/auth_me_probe_body.$$ 2>/dev/null || true

if [ "$me_code" != "200" ]; then
  echo "FAIL: /api/auth/me retornou HTTP ${me_code:-000} com cookie."
  exit 1
fi

echo "OK: login e sessao validos em ${TARGET} (${origin})."
