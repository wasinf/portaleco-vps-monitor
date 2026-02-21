#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-48}"
HOST_SURFACE_STRICT_ADMIN="${HOST_SURFACE_STRICT_ADMIN:-false}"
SCOPE="${1:-both}"

if [ "$SCOPE" != "prod" ] && [ "$SCOPE" != "staging" ] && [ "$SCOPE" != "both" ]; then
  echo "Uso: $0 [prod|staging|both]"
  exit 1
fi

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

should_check() {
  local label="$1"
  [ "$SCOPE" = "both" ] || [ "$SCOPE" = "$label" ]
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
  local label="$1"
  if [ -x "$ROOT_DIR/scripts/security_check.sh" ]; then
    if "$ROOT_DIR/scripts/security_check.sh" "$label"; then
      ok "security_check ${label}: concluido"
    else
      fail "security_check ${label}: falhou"
    fi
  else
    warn "security_check.sh ausente/sem permissao de execucao"
  fi
}

check_auth_consistency() {
  local label="$1"
  if [ -x "$ROOT_DIR/scripts/auth_consistency_check.sh" ]; then
    if "$ROOT_DIR/scripts/auth_consistency_check.sh" "$label"; then
      ok "auth_consistency_check ${label}: concluido"
    else
      fail "auth_consistency_check ${label}: falhou"
    fi
  else
    warn "auth_consistency_check.sh ausente/sem permissao de execucao"
  fi
}

check_auth_login_probe() {
  local label="$1"
  if [ -x "$ROOT_DIR/scripts/auth_login_probe.sh" ]; then
    if "$ROOT_DIR/scripts/auth_login_probe.sh" "$label"; then
      ok "auth_login_probe ${label}: concluido"
    else
      fail "auth_login_probe ${label}: falhou"
    fi
  else
    warn "auth_login_probe.sh ausente/sem permissao de execucao"
  fi
}

check_host_surface() {
  if [ -x "$ROOT_DIR/scripts/host_surface_check.sh" ]; then
    if HOST_SURFACE_STRICT_ADMIN="$HOST_SURFACE_STRICT_ADMIN" "$ROOT_DIR/scripts/host_surface_check.sh"; then
      ok "host_surface_check: concluido"
    else
      fail "host_surface_check: falhou"
    fi
  else
    warn "host_surface_check.sh ausente/sem permissao de execucao"
  fi
}

echo "== Preflight portaleco-vps-monitor =="
echo "Escopo: ${SCOPE}"

if should_check prod; then
  check_env_file "$INFRA_DIR/.env" "prod"
  check_container "portaleco-vps-monitor-backend"
  check_container "portaleco-vps-monitor-frontend"
  check_auth_consistency "prod"
  check_auth_login_probe "prod"
  check_security "prod"
fi

if should_check staging; then
  check_env_file "$INFRA_DIR/.env.staging" "staging"
  check_container "portaleco-vps-monitor-backend-staging"
  check_container "portaleco-vps-monitor-frontend-staging"
  check_auth_consistency "staging"
  check_auth_login_probe "staging"
  check_security "staging"
fi

check_cron_entry "./scripts/backup_create.sh" "backup_create"
check_cron_entry "./scripts/health_alert_check.sh" "health_alert_check"

check_recent_backup
check_host_surface

echo "== Resultado =="
echo "Erros: $errors"
echo "Avisos: $warnings"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
