#!/bin/bash
set -euo pipefail

TARGET="${1:-prod}"
AUTH_SELFHEAL_PUBLIC="${AUTH_SELFHEAL_PUBLIC:-true}"
AUTH_SELFHEAL_SOFT_FAIL_PUBLIC="${AUTH_SELFHEAL_SOFT_FAIL_PUBLIC:-false}"

case "$TARGET" in
  prod|staging) ;;
  *)
    echo "Uso: $0 [prod|staging]"
    exit 1
    ;;
esac

echo "== Auth self-heal (${TARGET}) =="

echo "[1/3] Checando consistencia atual..."
if ./scripts/auth_consistency_check.sh "$TARGET"; then
  echo "OK: consistencia ja estava valida."
else
  echo "WARN: consistencia falhou; iniciando reparo..."
  echo "[2/3] Reparando auth a partir do .env..."
  ./scripts/auth_repair_from_env.sh "$TARGET"
  echo "[2/3] Revalidando consistencia..."
  ./scripts/auth_consistency_check.sh "$TARGET"
fi

echo "[3/3] Validando login/sessao..."
if [ "$AUTH_SELFHEAL_PUBLIC" = "true" ]; then
  AUTH_LOGIN_PROBE_PUBLIC=true \
  AUTH_LOGIN_PROBE_SOFT_FAIL="$AUTH_SELFHEAL_SOFT_FAIL_PUBLIC" \
  ./scripts/auth_login_probe.sh "$TARGET"
else
  AUTH_LOGIN_PROBE_PUBLIC=false ./scripts/auth_login_probe.sh "$TARGET"
fi

echo "OK: self-heal de auth concluido (${TARGET})."
