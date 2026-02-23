#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-prod}"
AUTH_LOGIN_PROBE_PUBLIC="${AUTH_LOGIN_PROBE_PUBLIC:-true}"
AUTH_LOGIN_PROBE_SOFT_FAIL="${AUTH_LOGIN_PROBE_SOFT_FAIL:-false}"

case "$TARGET" in
  prod)
    ENV_FILE="$ROOT_DIR/infra/.env"
    CONTAINER="portaleco-vps-monitor-backend"
    ;;
  staging)
    ENV_FILE="$ROOT_DIR/infra/.env.staging"
    CONTAINER="portaleco-vps-monitor-backend-staging"
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

probe_internal() {
  docker exec "$CONTAINER" node -e "
const http=require('http');

const username=String(process.env.AUTH_USERNAME||'');
const password=String(process.env.AUTH_PASSWORD||'');

if(!username||!password){
  console.error('FAIL: AUTH_USERNAME/AUTH_PASSWORD ausentes no container.');
  process.exit(1);
}

const body=JSON.stringify({username,password});
const loginReq=http.request({
  host:'127.0.0.1',
  port:4000,
  path:'/api/auth/login',
  method:'POST',
  headers:{'content-type':'application/json','content-length':Buffer.byteLength(body)}
},(loginRes)=>{
  const loginCode=Number(loginRes.statusCode||0);
  const cookies=loginRes.headers['set-cookie']||[];
  if(loginCode!==200){
    console.error('FAIL: login interno retornou HTTP '+loginCode+'.');
    process.exit(2);
    return;
  }
  if(!Array.isArray(cookies)||cookies.length===0){
    console.error('FAIL: login interno sem cookie de sessao.');
    process.exit(3);
    return;
  }

  const meReq=http.request({
    host:'127.0.0.1',
    port:4000,
    path:'/api/auth/me',
    method:'GET',
    headers:{'cookie':cookies.map((c)=>String(c).split(';')[0]).join('; ')}
  },(meRes)=>{
    const meCode=Number(meRes.statusCode||0);
    if(meCode!==200){
      console.error('FAIL: /api/auth/me interno retornou HTTP '+meCode+'.');
      process.exit(4);
      return;
    }
    console.log('OK: login/sessao internos validos no container.');
    process.exit(0);
  });

  meReq.on('error',(e)=>{
    console.error('FAIL: erro no /api/auth/me interno: '+e.message);
    process.exit(5);
  });
  meReq.end();
});

loginReq.on('error',(e)=>{
  console.error('FAIL: erro no login interno: '+e.message);
  process.exit(6);
});
loginReq.write(body);
loginReq.end();
"
}

probe_public() {
  local username="$1"
  local password="$2"
  local origin="$3"

  local cookie_file
  cookie_file="$(mktemp)"
  trap 'rm -f "$cookie_file"' RETURN

  local login_code
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
    echo "FAIL: login publico retornou HTTP ${login_code:-000} em $origin/api/auth/login"
    return 1
  fi

  if ! grep -q "portaleco_vps_monitor_auth" "$cookie_file"; then
    echo "FAIL: login publico nao retornou cookie de sessao."
    return 1
  fi

  local me_code
  me_code="$(
    curl -ksS -o /tmp/auth_me_probe_body.$$ -w '%{http_code}' \
      -b "$cookie_file" \
      --max-time 12 \
      "$origin/api/auth/me" || true
  )"
  rm -f /tmp/auth_me_probe_body.$$ 2>/dev/null || true

  if [ "$me_code" != "200" ]; then
    echo "FAIL: /api/auth/me publico retornou HTTP ${me_code:-000} com cookie."
    return 1
  fi

  echo "OK: login/sessao publicos validos em ${origin}."
  return 0
}

echo "== Auth login probe (${TARGET}) =="

echo "- probe interno no container"
probe_internal

if [ "$AUTH_LOGIN_PROBE_PUBLIC" != "true" ]; then
  echo "WARN: probe publico desativado (AUTH_LOGIN_PROBE_PUBLIC=${AUTH_LOGIN_PROBE_PUBLIC})."
  exit 0
fi

username="$(env_get "$ENV_FILE" "AUTH_USERNAME")"
password="$(env_get "$ENV_FILE" "AUTH_PASSWORD")"
origin="$(first_origin "$(env_get "$ENV_FILE" "ALLOWED_ORIGINS")")"

if [ -z "$username" ] || [ -z "$password" ] || [ -z "$origin" ]; then
  msg="FAIL: AUTH_USERNAME/AUTH_PASSWORD/ALLOWED_ORIGINS ausentes em $ENV_FILE"
  if [ "$AUTH_LOGIN_PROBE_SOFT_FAIL" = "true" ]; then
    echo "WARN: ${msg}"
    exit 0
  fi
  echo "$msg"
  exit 1
fi

echo "- probe publico via dominio"
if ! probe_public "$username" "$password" "$origin"; then
  if [ "$AUTH_LOGIN_PROBE_SOFT_FAIL" = "true" ]; then
    echo "WARN: falha no probe publico (modo soft-fail ativo)."
    exit 0
  fi
  exit 1
fi

exit 0
