#!/bin/bash
set -euo pipefail

TARGET="${1:-prod}"

case "$TARGET" in
  prod)
    CONTAINER="portaleco-vps-monitor-backend"
    ;;
  staging)
    CONTAINER="portaleco-vps-monitor-backend-staging"
    ;;
  *)
    echo "Uso: $0 [prod|staging]"
    exit 1
    ;;
esac

echo "== Auth consistency check (${TARGET}) =="

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "FAIL: container nao encontrado: ${CONTAINER}"
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]; then
  echo "FAIL: container nao esta em execucao: ${CONTAINER}"
  exit 1
fi

docker exec "$CONTAINER" node -e "
const {openAuthStore}=require('/app/src/auth-store');

const username=String(process.env.AUTH_USERNAME||'').trim();
const password=String(process.env.AUTH_PASSWORD||'');
const dbPath=process.env.AUTH_DB_PATH||'/data/auth.db';

if (!username || !password) {
  console.error('FAIL: AUTH_USERNAME/AUTH_PASSWORD ausentes no container.');
  process.exit(1);
}

const store=openAuthStore(dbPath);
const user=store.validateCredentials(username,password);
if (!user) {
  console.error('FAIL: credencial do ambiente nao valida no auth.db para usuario '+username+'.');
  process.exit(2);
}

if (Number(user.active)!==1) {
  console.error('FAIL: usuario '+username+' esta inativo no auth.db.');
  process.exit(3);
}

console.log('OK: credencial valida e usuario ativo no auth.db para '+username+'.');
"
