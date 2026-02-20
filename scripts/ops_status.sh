#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-48}"
PROD_ORIGIN="${PROD_ORIGIN:-https://monitor.portalecomdo.com.br}"
STAGING_ORIGIN="${STAGING_ORIGIN:-https://staging.monitor.portalecomdo.com.br}"
STRICT="${OPS_STATUS_STRICT:-false}"
FAIL_ON_WARN="${OPS_STATUS_FAIL_ON_WARN:-false}"

critical_count=0
warning_count=0

line() { printf '%s\n' "----------------------------------------"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { warning_count=$((warning_count + 1)); printf 'WARN: %s\n' "$*"; }
fail() { critical_count=$((critical_count + 1)); printf 'FAIL: %s\n' "$*"; }

status_container() {
  local name="$1"
  local running health
  running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)"

  if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
    ok "${name}: running=${running} health=${health}"
  else
    fail "${name}: running=${running} health=${health}"
  fi
}

status_http() {
  local label="$1"
  local url="$2"
  local expected="$3"
  local code
  code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  [ -n "$code" ] || code="000"

  if printf '%s' "$expected" | tr ',' '\n' | rg -Fx "$code" >/dev/null 2>&1; then
    ok "${label}: HTTP ${code} (${url})"
  else
    if [ "$code" = "000" ] && printf '%s' "$label" | rg -q '^staging '; then
      warn "${label}: HTTP ${code} (${url})"
    else
      fail "${label}: HTTP ${code} (${url})"
    fi
  fi
}

backup_status() {
  if [ ! -d "$BACKUP_DIR" ]; then
    warn "backup: diretorio ausente ($BACKUP_DIR)"
    return
  fi

  local latest epoch now age_h
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'auth-*.tgz' -printf '%T@ %p\n' | sort -nr | head -n1 | awk '{print $2}')"
  if [ -z "${latest:-}" ]; then
    warn "backup: nenhum arquivo auth-*.tgz"
    return
  fi

  epoch="$(stat -c %Y "$latest")"
  now="$(date +%s)"
  age_h="$(( (now - epoch) / 3600 ))"

  if [ "$age_h" -le "$BACKUP_MAX_AGE_HOURS" ]; then
    ok "backup: $(basename "$latest") (${age_h}h)"
  else
    warn "backup: antigo $(basename "$latest") (${age_h}h)"
  fi
}

cron_status() {
  if crontab -l 2>/dev/null | rg -F "./scripts/backup_create.sh" >/dev/null; then
    ok "cron backup_create: presente"
  else
    warn "cron backup_create: ausente"
  fi

  if crontab -l 2>/dev/null | rg -F "./scripts/health_alert_check.sh" >/dev/null; then
    ok "cron health_alert_check: presente"
  else
    warn "cron health_alert_check: ausente"
  fi
}

echo "== Ops Status portaleco-vps-monitor =="
echo "Data: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "Modo estrito: ${STRICT}"
echo "Falhar com warning: ${FAIL_ON_WARN}"
line
echo "Git"
git -C "$ROOT_DIR" status -sb | sed -n '1p'
echo "HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)"
line
echo "Containers"
status_container "portaleco-vps-monitor-backend"
status_container "portaleco-vps-monitor-frontend"
status_container "portaleco-vps-monitor-backend-staging"
status_container "portaleco-vps-monitor-frontend-staging"
line
echo "HTTP"
status_http "prod root" "${PROD_ORIGIN}/" "200"
status_http "prod auth/me" "${PROD_ORIGIN}/api/auth/me" "200,401,403"
status_http "staging root" "${STAGING_ORIGIN}/" "200"
status_http "staging auth/me" "${STAGING_ORIGIN}/api/auth/me" "200,401,403"
line
echo "Cron"
cron_status
line
echo "Backup"
backup_status
line
echo "Resumo"
echo "Criticos: ${critical_count}"
echo "Avisos: ${warning_count}"

if [ "$STRICT" = "true" ] && [ "$critical_count" -gt 0 ]; then
  exit 1
fi

if [ "$FAIL_ON_WARN" = "true" ] && [ "$warning_count" -gt 0 ]; then
  exit 1
fi
