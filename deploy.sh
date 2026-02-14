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
  API_PORT="4000"
  FRONTEND_PORT="4001"
elif [ "$ENVIRONMENT" = "staging" ]; then
  COMPOSE_FILE="docker-compose.staging.yml"
  ENV_FILE=".env.staging"
  API_PORT="4100"
  FRONTEND_PORT="4101"
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

echo "Validando saude dos servicos..."
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1 && \
     curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null 2>&1; then
    echo "Servicos OK (${ENVIRONMENT})"
    break
  fi

  if [ "$i" -eq 30 ]; then
    echo "Falha: servicos nao ficaram saudaveis apos deploy."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
    exit 1
  fi
  sleep 2
done

echo "Deploy finalizado com sucesso!"
