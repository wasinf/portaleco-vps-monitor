#!/bin/bash
set -euo pipefail

echo "===================================="
echo "PortalEco VPS Monitor - Deploy Script"
echo "===================================="

cd /opt/apps/portaleco-vps-monitor || exit

ENVIRONMENT="${1:-prod}"
RUN_DEPLOY_PRECHECK="${RUN_DEPLOY_PRECHECK:-true}"

if [ "$ENVIRONMENT" = "prod" ]; then
  COMPOSE_FILE="docker-compose.yml"
  ENV_FILE=".env"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend"
elif [ "$ENVIRONMENT" = "staging" ]; then
  COMPOSE_FILE="docker-compose.staging.yml"
  ENV_FILE=".env.staging"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend-staging"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend-staging"
else
  echo "Uso: ./deploy.sh [prod|staging]"
  exit 1
fi

echo "Ambiente: $ENVIRONMENT"
echo "Atualizando branch main..."
git checkout main
git pull --ff-only origin main

if [ "$RUN_DEPLOY_PRECHECK" = "true" ] && [ -x "./scripts/deploy_precheck.sh" ]; then
  echo "Executando precheck de deploy (${ENVIRONMENT})..."
  ./scripts/deploy_precheck.sh "$ENVIRONMENT"
else
  echo "Precheck de deploy ignorado (RUN_DEPLOY_PRECHECK=${RUN_DEPLOY_PRECHECK})."
fi

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
  backend_running="$(docker inspect -f '{{.State.Running}}' "$BACKEND_CONTAINER" 2>/dev/null || echo "false")"
  frontend_running="$(docker inspect -f '{{.State.Running}}' "$FRONTEND_CONTAINER" 2>/dev/null || echo "false")"
  backend_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$BACKEND_CONTAINER" 2>/dev/null || echo "missing")"
  frontend_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$FRONTEND_CONTAINER" 2>/dev/null || echo "missing")"

  if [ "$backend_running" = "true" ] && [ "$frontend_running" = "true" ] && \
     { [ "$backend_health" = "healthy" ] || [ "$backend_health" = "none" ]; } && \
     { [ "$frontend_health" = "healthy" ] || [ "$frontend_health" = "none" ]; }; then
    echo "Servicos OK (${ENVIRONMENT})"
    break
  fi

  if [ "$i" -eq 30 ]; then
    echo "Falha: servicos nao ficaram saudaveis apos deploy."
    echo "backend: running=${backend_running}, health=${backend_health}"
    echo "frontend: running=${frontend_running}, health=${frontend_health}"
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
    exit 1
  fi
  sleep 2
done

echo "Deploy finalizado com sucesso!"
