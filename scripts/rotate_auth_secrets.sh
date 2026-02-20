#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
APPLY=false
TARGET="${1:-both}"

if [ "${2:-}" = "--apply" ] || [ "${1:-}" = "--apply" ]; then
  APPLY=true
fi

if [ "$TARGET" = "--apply" ]; then
  TARGET="both"
fi

case "$TARGET" in
  prod|staging|both) ;;
  *)
    echo "Uso: $0 [prod|staging|both] [--apply]"
    exit 1
    ;;
esac

mask() {
  local value="$1"
  local len="${#value}"
  if [ "$len" -le 8 ]; then
    printf '%s***' "${value:0:2}"
  else
    printf '%s***%s' "${value:0:4}" "${value:len-4:4}"
  fi
}

env_get() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit}' "$file" 2>/dev/null || true
}

env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  if rg -n "^${key}=" "$file" >/dev/null; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

rotate_env() {
  local env_name="$1"
  local env_file="$2"
  local backend_container="$3"
  local deploy_arg="$4"

  if [ ! -f "$env_file" ]; then
    echo "FAIL: arquivo ausente para ${env_name}: $env_file"
    return 1
  fi

  local username old_password new_password new_secret
  username="$(env_get "$env_file" "AUTH_USERNAME")"
  old_password="$(env_get "$env_file" "AUTH_PASSWORD")"
  new_password="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AB' | cut -c1-24)"
  new_secret="$(openssl rand -hex 32)"

  echo "== ${env_name} =="
  echo "usuario: ${username}"
  echo "senha (nova): $(mask "$new_password")"
  echo "token secret (novo): $(mask "$new_secret")"

  if [ "$APPLY" != "true" ]; then
    echo "DRY-RUN: nenhuma alteracao aplicada em ${env_name}."
    return 0
  fi

  env_set "$env_file" "AUTH_PASSWORD" "$new_password"
  env_set "$env_file" "AUTH_TOKEN_SECRET" "$new_secret"
  env_set "$env_file" "AUTH_FAIL_ON_INSECURE_DEFAULTS" "true"

  echo "Aplicando deploy ${env_name}..."
  (cd "$ROOT_DIR" && ./deploy.sh "$deploy_arg")

  echo "Aplicando troca efetiva de senha via API (${env_name})..."
  docker exec "$backend_container" node -e "(async()=>{const username=process.argv[1];const oldPass=process.argv[2];const newPass=process.argv[3];const login=await fetch('http://127.0.0.1:4000/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username,password:oldPass})});if(!login.ok){console.log('LOGIN_OLD_FAIL='+login.status);process.exit(2);}const lj=await login.json();const ch=await fetch('http://127.0.0.1:4000/api/auth/change-password',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+lj.token},body:JSON.stringify({current_password:oldPass,new_password:newPass})});if(!ch.ok){console.log('CHANGE_FAIL='+ch.status);process.exit(3);}const relog=await fetch('http://127.0.0.1:4000/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username,password:newPass})});if(!relog.ok){console.log('LOGIN_NEW_FAIL='+relog.status);process.exit(4);}console.log('ROTATION_OK');})().catch(e=>{console.error(String(e));process.exit(1);});" "$username" "$old_password" "$new_password"

  echo "OK: rotacao aplicada em ${env_name}."
}

if [ "$TARGET" = "prod" ] || [ "$TARGET" = "both" ]; then
  rotate_env "prod" "$INFRA_DIR/.env" "portaleco-vps-monitor-backend" "prod"
fi

if [ "$TARGET" = "staging" ] || [ "$TARGET" = "both" ]; then
  rotate_env "staging" "$INFRA_DIR/.env.staging" "portaleco-vps-monitor-backend-staging" "staging"
fi

if [ "$APPLY" = "true" ]; then
  echo "Rotacao concluida."
else
  echo "Dry-run concluido. Para aplicar: $0 ${TARGET} --apply"
fi
