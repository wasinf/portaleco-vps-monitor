#!/bin/bash
set -euo pipefail

echo "===================================="
echo "PortalEco VPS Monitor - Deploy Script"
echo "===================================="

cd /opt/apps/portaleco-vps-monitor || exit

ENVIRONMENT="${1:-prod}"

if [ "$ENVIRONMENT" = "prod" ]; then
  COMPOSE_FILE="docker-compose.yml"
  ENV_FILE=".env"
elif [ "$ENVIRONMENT" = "staging" ]; then
  COMPOSE_FILE="docker-compose.staging.yml"
  ENV_FILE=".env.staging"
else
  echo "Uso: ./deploy.sh [prod|staging]"
  exit 1
fi

echo "Ambiente: $ENVIRONMENT"
echo "Atualizando branch main..."
git checkout main
git pull --ff-only

cd infra || exit

if [ ! -f "$ENV_FILE" ]; then
  if [ "$ENVIRONMENT" = "prod" ]; then
    cp --update=none .env.example "$ENV_FILE"
  else
    cp --update=none .env.staging.example "$ENV_FILE"
  fi
  echo "Arquivo $ENV_FILE criado. Revise credenciais antes do uso em producao."
fi

echo "Rebuildando containers em $ENVIRONMENT..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --build

echo "Deploy finalizado com sucesso!"
