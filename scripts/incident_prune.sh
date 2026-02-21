#!/bin/bash
set -euo pipefail

MODE="${1:---apply}" # --apply | --dry-run
INCIDENT_DIR="${INCIDENT_DIR:-/opt/apps/portaleco-vps-monitor/backups/incidents}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

if [ "$MODE" != "--apply" ] && [ "$MODE" != "--dry-run" ]; then
  echo "Uso: $0 [--apply|--dry-run]"
  exit 1
fi

removed=0
failed=0

echo "== Incident prune =="
echo "Diretorio: ${INCIDENT_DIR}"
echo "Retencao: ${RETENTION_DAYS} dias"
echo "Modo: ${MODE}"

if [ ! -d "$INCIDENT_DIR" ]; then
  echo "OK: diretorio inexistente, nada para limpar."
  exit 0
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ "$MODE" = "--dry-run" ]; then
    echo "DRY-RUN remove: $path"
    removed=$((removed + 1))
    continue
  fi

  if [ -d "$path" ]; then
    rm -rf "$path" || failed=$((failed + 1))
  else
    rm -f "$path" || failed=$((failed + 1))
  fi

  if [ "$failed" -eq 0 ]; then
    echo "OK removeu: $path"
    removed=$((removed + 1))
  else
    echo "FAIL ao remover: $path"
  fi
done < <(
  find "$INCIDENT_DIR" -mindepth 1 -maxdepth 1 \
    \( -type d -name 'incident-*' -o -type f -name 'incident-*.tgz' \) \
    -mtime "+$RETENTION_DAYS" 2>/dev/null || true
)

echo "== Resultado incident prune =="
echo "Removidos: $removed"
echo "Falhas: $failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
