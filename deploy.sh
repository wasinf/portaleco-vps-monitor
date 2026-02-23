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

cd infra || exit

if [ ! -f "$ENV_FILE" ]; then
  if [ "$ENVIRONMENT" = "prod" ]; then
    cp --update=none .env.example "$ENV_FILE"
    echo "Arquivo $ENV_FILE criado a partir de .env.example."
    echo "Falha: deploy de producao abortado para evitar uso acidental de credenciais/defaults."
    echo "Revise $ENV_FILE e execute novamente o deploy."
    exit 1
  else
    cp --update=none .env.staging.example "$ENV_FILE"
    echo "Arquivo $ENV_FILE criado. Revise credenciais antes do uso em producao."
  fi
fi

cd .. || exit

if [ "$RUN_DEPLOY_PRECHECK" = "true" ] && [ -x "./scripts/deploy_precheck.sh" ]; then
  echo "Executando precheck de deploy (${ENVIRONMENT})..."
  ./scripts/deploy_precheck.sh "$ENVIRONMENT"
else
  echo "Precheck de deploy ignorado (RUN_DEPLOY_PRECHECK=${RUN_DEPLOY_PRECHECK})."
fi

cd infra || exit

if ! docker network inspect npm-network >/dev/null 2>&1; then
  echo "Falha: rede Docker externa 'npm-network' nao encontrada."
  echo "Crie/recupere a rede antes do deploy (usada pelo Nginx Proxy Manager)."
  exit 1
fi

echo "Rebuildando containers em $ENVIRONMENT..."
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

if [ "${RUN_RELEASE_SMOKE:-true}" = "true" ] && [ -x "../scripts/release_smoke.sh" ]; then
  echo "Executando smoke pos-deploy (${ENVIRONMENT})..."
  ../scripts/release_smoke.sh "$ENVIRONMENT"
else
  echo "Smoke pos-deploy ignorado (RUN_RELEASE_SMOKE=${RUN_RELEASE_SMOKE:-true})."
fi

if [ "${RUN_POST_DEPLOY_PREFLIGHT:-true}" = "true" ] && [ -x "../scripts/release_preflight.sh" ]; then
  echo "Executando preflight pos-deploy (${ENVIRONMENT})..."
  ../scripts/release_preflight.sh "$ENVIRONMENT"
else
  echo "Preflight pos-deploy ignorado (RUN_POST_DEPLOY_PREFLIGHT=${RUN_POST_DEPLOY_PREFLIGHT:-true})."
fi

echo "Deploy finalizado com sucesso!"
