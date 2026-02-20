#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-prod}"

if [ "$ENVIRONMENT" != "prod" ] && [ "$ENVIRONMENT" != "staging" ]; then
  echo "Uso: $0 [prod|staging]"
  exit 1
fi

STRICT_ADMIN_SURFACE="${RELEASE_GATE_STRICT_ADMIN_SURFACE:-false}"
SMOKE_PUBLIC="${RELEASE_GATE_SMOKE_PUBLIC:-true}"

steps=(
  "Precheck de deploy|$ROOT_DIR/scripts/deploy_precheck.sh $ENVIRONMENT"
  "Smoke pos-deploy|RELEASE_SMOKE_PUBLIC=$SMOKE_PUBLIC $ROOT_DIR/scripts/release_smoke.sh $ENVIRONMENT"
  "Preflight final|SECURITY_STRICT_ADMIN_SURFACE=$STRICT_ADMIN_SURFACE $ROOT_DIR/scripts/release_preflight.sh"
)

fails=0
index=0

echo "======================================="
echo "PortalEco Release Gate (${ENVIRONMENT})"
echo "======================================="
echo "Smoke publico: ${SMOKE_PUBLIC}"
echo "Modo estrito superficie admin: ${STRICT_ADMIN_SURFACE}"

for entry in "${steps[@]}"; do
  index=$((index + 1))
  label="${entry%%|*}"
  cmd="${entry#*|}"

  echo ""
  echo "[$index/${#steps[@]}] ${label}"
  start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "Inicio: ${start_ts}"

  if bash -lc "$cmd"; then
    end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "Resultado: OK (${end_ts})"
  else
    end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "Resultado: FAIL (${end_ts})"
    fails=$((fails + 1))
  fi
done

echo ""
echo "========== Resultado Gate =========="
echo "Ambiente: ${ENVIRONMENT}"
echo "Falhas: ${fails}"

if [ "$fails" -gt 0 ]; then
  exit 1
fi
