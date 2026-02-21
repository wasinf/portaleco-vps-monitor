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

echo "== Auth repair from env (${TARGET}) =="

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "FAIL: container nao encontrado: ${CONTAINER}"
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" != "true" ]; then
  echo "FAIL: container nao esta em execucao: ${CONTAINER}"
  exit 1
fi

docker exec "$CONTAINER" node -e "
const crypto=require('crypto');
const Database=require('better-sqlite3');
const {openAuthStore}=require('/app/src/auth-store');

const username=String(process.env.AUTH_USERNAME||'').trim();
const password=String(process.env.AUTH_PASSWORD||'');
const dbPath=process.env.AUTH_DB_PATH||'/data/auth.db';

if (!username || !password) {
  console.error('FAIL: AUTH_USERNAME/AUTH_PASSWORD ausentes no container.');
  process.exit(1);
}

const db=new Database(dbPath);
db.exec(\`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'admin',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  )
\`);

const row=db.prepare('SELECT username, role FROM users WHERE username=? LIMIT 1').get(username);
const salt=crypto.randomBytes(16).toString('hex');
const hash=crypto.scryptSync(password,salt,64).toString('hex');
const passwordHash='scrypt:'+salt+':'+hash;

if (!row) {
  db.prepare('INSERT INTO users (username,password_hash,role,active,created_at,updated_at) VALUES (?,?,\\'admin\\',1,datetime(\\'now\\'),datetime(\\'now\\'))')
    .run(username,passwordHash);
  console.log('OK: usuario criado e senha aplicada a partir do .env: '+username);
} else {
  db.prepare('UPDATE users SET password_hash=?, active=1, updated_at=datetime(\\'now\\') WHERE username=?')
    .run(passwordHash,username);
  console.log('OK: senha/active sincronizados para usuario '+username+' (role='+row.role+').');
}

const store=openAuthStore(dbPath);
const valid=store.validateCredentials(username,password);
if (!valid) {
  console.error('FAIL: credencial ainda invalida apos reparo para '+username+'.');
  process.exit(2);
}
console.log('OK: validacao final concluida para '+username+'.');
"
