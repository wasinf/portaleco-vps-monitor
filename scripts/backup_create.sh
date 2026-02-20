#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

PROD_VOLUME="portaleco-vps-monitor_portaleco_monitor_auth_data"
STAGING_VOLUME="portaleco-vps-monitor-staging_portaleco_monitor_auth_data_staging"

mkdir -p "$BACKUP_DIR"

backup_volume() {
  local volume_name="$1"
  local env_name="$2"
  local archive_name="auth-${env_name}-${TIMESTAMP}.tgz"
  local archive_path="$BACKUP_DIR/$archive_name"

  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    echo "WARN: volume nao encontrado ($volume_name), pulando ${env_name}."
    return 0
  fi

  docker run --rm \
    -v "${volume_name}:/src:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine:3.20 \
    sh -lc "cd /src && tar czf \"/backup/${archive_name}\" ."

  (cd "$BACKUP_DIR" && sha256sum "$archive_name" > "${archive_name}.sha256")
  echo "OK: backup ${env_name} -> ${archive_path}"
}

backup_volume "$PROD_VOLUME" "prod"
backup_volume "$STAGING_VOLUME" "staging"

find "$BACKUP_DIR" -type f \( -name "auth-*.tgz" -o -name "auth-*.tgz.sha256" \) -mtime +"$RETENTION_DAYS" -delete

echo "Backups finalizados em: $BACKUP_DIR"
