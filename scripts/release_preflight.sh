#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-48}"

errors=0
warnings=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

env_get() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit}' "$file" 2>/dev/null || true
}

check_env_file() {
  local env_file="$1"
  local label="$2"
  if [ ! -f "$env_file" ]; then
    fail "${label}: arquivo ausente ($env_file)"
    return
  fi

  local auth_fail origins token_secret
  auth_fail="$(env_get "$env_file" "AUTH_FAIL_ON_INSECURE_DEFAULTS")"
  origins="$(env_get "$env_file" "ALLOWED_ORIGINS")"
  token_secret="$(env_get "$env_file" "AUTH_TOKEN_SECRET")"

  if [ "$auth_fail" = "true" ]; then
    ok "${label}: AUTH_FAIL_ON_INSECURE_DEFAULTS=true"
  else
    fail "${label}: AUTH_FAIL_ON_INSECURE_DEFAULTS diferente de true"
  fi

  if [ -n "$origins" ]; then
    if printf '%s' "$origins" | rg -q 'https://'; then
      ok "${label}: ALLOWED_ORIGINS definido"
    else
      fail "${label}: ALLOWED_ORIGINS sem https://"
    fi
  else
    fail "${label}: ALLOWED_ORIGINS vazio"
  fi

  if [ -n "$token_secret" ] && [ "$token_secret" != "change-this-token-secret" ] && [ "${#token_secret}" -ge 32 ]; then
    ok "${label}: AUTH_TOKEN_SECRET configurado"
  else
    fail "${label}: AUTH_TOKEN_SECRET fraco/invalido"
  fi
}

check_container() {
  local name="$1"
  local running health
  running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)"
  if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
    ok "container ${name}: running=${running}, health=${health}"
  else
    fail "container ${name}: running=${running}, health=${health}"
  fi
}

check_cron_entry() {
  local pattern="$1"
  local label="$2"
  if crontab -l 2>/dev/null | rg -F "$pattern" >/dev/null; then
    ok "cron ${label}: presente"
  else
    warn "cron ${label}: ausente"
  fi
}

check_recent_backup() {
  if [ ! -d "$BACKUP_DIR" ]; then
    warn "diretorio de backup ausente ($BACKUP_DIR)"
    return
  fi

  local latest
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'auth-*.tgz' -printf '%T@ %p\n' | sort -nr | head -n1 | awk '{print $2}')"
  if [ -z "${latest:-}" ]; then
    warn "nenhum arquivo auth-*.tgz em $BACKUP_DIR"
    return
  fi

  local now epoch age_hours
  now="$(date +%s)"
  epoch="$(stat -c %Y "$latest")"
  age_hours="$(( (now - epoch) / 3600 ))"

  if [ "$age_hours" -le "$MAX_BACKUP_AGE_HOURS" ]; then
    ok "backup recente: $(basename "$latest") (${age_hours}h)"
  else
    warn "backup antigo: $(basename "$latest") (${age_hours}h)"
  fi
}

check_security() {
  if [ -x "$ROOT_DIR/scripts/security_check.sh" ]; then
    if "$ROOT_DIR/scripts/security_check.sh" prod; then
      ok "security_check prod: concluido"
    else
      fail "security_check prod: falhou"
    fi

    if "$ROOT_DIR/scripts/security_check.sh" staging; then
      ok "security_check staging: concluido"
    else
      fail "security_check staging: falhou"
    fi
  else
    warn "security_check.sh ausente/sem permissao de execucao"
  fi
}

echo "== Preflight portaleco-vps-monitor =="

check_env_file "$INFRA_DIR/.env" "prod"
check_env_file "$INFRA_DIR/.env.staging" "staging"

check_container "portaleco-vps-monitor-backend"
check_container "portaleco-vps-monitor-frontend"
check_container "portaleco-vps-monitor-backend-staging"
check_container "portaleco-vps-monitor-frontend-staging"

check_cron_entry "./scripts/backup_create.sh" "backup_create"
check_cron_entry "./scripts/health_alert_check.sh" "health_alert_check"

check_recent_backup
check_security

echo "== Resultado =="
echo "Erros: $errors"
echo "Avisos: $warnings"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
