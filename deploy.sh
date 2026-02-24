#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR" || exit

LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
if [ "${DEPLOY_LOG_DISABLE:-false}" != "true" ] && [ -z "${DEPLOY_LOG_ACTIVE:-}" ]; then
  export DEPLOY_LOG_ACTIVE=1
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo "===================================="
echo "PortalEco VPS Monitor - Deploy Script"
echo "===================================="
echo "Log de deploy: $LOG_FILE"

ENVIRONMENT="${1:-prod}"
DEPLOY_REF="${2:-main}"
RUN_DEPLOY_PRECHECK="${RUN_DEPLOY_PRECHECK:-true}"
DEPLOY_STRICT_ADMIN_SURFACE="${DEPLOY_STRICT_ADMIN_SURFACE:-false}"

if [ "$ENVIRONMENT" = "prod" ]; then
  COMPOSE_FILE="docker-compose.yml"
  ENV_FILE=".env"
  BACKEND_SERVICE="portaleco-vps-monitor-backend"
  FRONTEND_SERVICE="portaleco-vps-monitor-frontend"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend"
elif [ "$ENVIRONMENT" = "staging" ]; then
  COMPOSE_FILE="docker-compose.staging.yml"
  ENV_FILE=".env.staging"
  BACKEND_SERVICE="portaleco-vps-monitor-backend-staging"
  FRONTEND_SERVICE="portaleco-vps-monitor-frontend-staging"
  BACKEND_CONTAINER="portaleco-vps-monitor-backend-staging"
  FRONTEND_CONTAINER="portaleco-vps-monitor-frontend-staging"
else
  echo "Uso: ./deploy.sh [prod|staging] [branch|tag]"
  exit 1
fi

echo "Ambiente: $ENVIRONMENT"
echo "Ref de deploy: $DEPLOY_REF"
echo "Modo estrito superficie admin no deploy: $DEPLOY_STRICT_ADMIN_SURFACE"

wait_container_ready() {
  local container_name="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local running
    local health
    running="$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "missing")"

    if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
      return 0
    fi
    if [ "$health" = "unhealthy" ] || [ "$health" = "missing" ]; then
      echo "Falha: container $container_name em estado invalido (running=$running, health=$health)."
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "Falha: timeout aguardando $container_name ficar pronto."
  return 1
}

retry_cmd() {
  local max_attempts="$1"
  local sleep_seconds="$2"
  shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    echo "Tentativa ${attempt}/${max_attempts} falhou: $*"
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done
}

echo "Atualizando codigo..."
if ! retry_cmd 3 3 git fetch --prune --tags origin; then
  echo "Falha: nao foi possivel atualizar refs do Git apos 3 tentativas."
  echo "Verifique DNS/conectividade do host com github.com e tente novamente."
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$DEPLOY_REF"; then
  git checkout "$DEPLOY_REF"
  if git show-ref --verify --quiet "refs/remotes/origin/$DEPLOY_REF"; then
    git merge --ff-only "origin/$DEPLOY_REF"
  fi
elif git show-ref --verify --quiet "refs/remotes/origin/$DEPLOY_REF"; then
  git checkout -B "$DEPLOY_REF" "origin/$DEPLOY_REF"
elif git rev-parse -q --verify "refs/tags/$DEPLOY_REF" >/dev/null 2>&1; then
  git checkout --detach "tags/$DEPLOY_REF"
else
  echo "Falha: branch/tag '$DEPLOY_REF' nao encontrada no repositorio."
  exit 1
fi

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
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build "$BACKEND_SERVICE" "$FRONTEND_SERVICE"

echo "Atualizando backend primeiro (menor impacto no frontend)..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --no-deps "$BACKEND_SERVICE"
wait_container_ready "$BACKEND_CONTAINER" 180

echo "Atualizando frontend..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --no-deps "$FRONTEND_SERVICE"
wait_container_ready "$FRONTEND_CONTAINER" 120

echo "Validando saude dos servicos..."
for i in $(seq 1 60); do
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
  if [ "$ENVIRONMENT" = "prod" ] && [ "$DEPLOY_STRICT_ADMIN_SURFACE" = "true" ]; then
    SECURITY_STRICT_ADMIN_SURFACE=true HOST_SURFACE_STRICT_ADMIN=true ../scripts/release_preflight.sh "$ENVIRONMENT"
  else
    ../scripts/release_preflight.sh "$ENVIRONMENT"
  fi
else
  echo "Preflight pos-deploy ignorado (RUN_POST_DEPLOY_PREFLIGHT=${RUN_POST_DEPLOY_PREFLIGHT:-true})."
fi

echo "Deploy finalizado com sucesso!"
