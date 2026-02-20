#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Uso: $0 [prod|staging] /caminho/para/auth-<env>-<timestamp>.tgz"
  exit 1
fi

TARGET_ENV="$1"
BACKUP_FILE="$2"

case "$TARGET_ENV" in
  prod)
    VOLUME_NAME="portaleco-vps-monitor_portaleco_monitor_auth_data"
    ;;
  staging)
    VOLUME_NAME="portaleco-vps-monitor-staging_portaleco_monitor_auth_data_staging"
    ;;
  *)
    echo "Ambiente invalido: $TARGET_ENV (use prod ou staging)"
    exit 1
    ;;
esac

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Arquivo de backup nao encontrado: $BACKUP_FILE"
  exit 1
fi

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  echo "Volume nao encontrado: $VOLUME_NAME"
  exit 1
fi

BACKUP_DIR="$(cd "$(dirname "$BACKUP_FILE")" && pwd)"
BACKUP_NAME="$(basename "$BACKUP_FILE")"

if [ -f "${BACKUP_FILE}.sha256" ]; then
  (cd "$BACKUP_DIR" && sha256sum -c "${BACKUP_NAME}.sha256")
fi

docker run --rm \
  -v "${VOLUME_NAME}:/dst" \
  -v "${BACKUP_DIR}:/backup:ro" \
  alpine:3.20 \
  sh -lc "rm -rf /dst/* /dst/.[!.]* /dst/..?* && tar xzf \"/backup/${BACKUP_NAME}\" -C /dst"

echo "Restore concluido para ${TARGET_ENV} no volume ${VOLUME_NAME}"
echo "Recomendado: redeploy no ambiente para garantir estado consistente."
