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

docker exec "$CONTAINER" node -e "
const crypto=require('crypto');
const Database=require('better-sqlite3');

const username=process.env.AUTH_USERNAME||'admin';
const password=process.env.AUTH_PASSWORD||'';
const dbPath=process.env.AUTH_DB_PATH||'/data/auth.db';

if (!password) {
  console.error('FAIL: AUTH_PASSWORD vazio no ambiente.');
  process.exit(1);
}

const hashPassword = (plain) => {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(plain, salt, 64).toString('hex');
  return 'scrypt:' + salt + ':' + hash;
};

const verifyPassword = (plain, encoded) => {
  const parts = String(encoded || '').split(':');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;
  const salt = parts[1];
  const expected = parts[2];
  const actual = crypto.scryptSync(plain, salt, 64).toString('hex');
  if (expected.length !== actual.length) return false;
  return crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));
};

const db = new Database(dbPath);
const user = db.prepare('SELECT username, password_hash FROM users WHERE username = ? LIMIT 1').get(username);
if (!user) {
  console.error('FAIL: usuario nao encontrado no banco: ' + username);
  process.exit(2);
}

if (verifyPassword(password, user.password_hash)) {
  console.log('OK: senha ja sincronizada para usuario ' + username + '.');
  process.exit(0);
}

db.prepare('UPDATE users SET password_hash = ?, updated_at = datetime(\\'now\\') WHERE username = ?')
  .run(hashPassword(password), username);
console.log('OK: senha sincronizada a partir do .env para usuario ' + username + '.');
"
