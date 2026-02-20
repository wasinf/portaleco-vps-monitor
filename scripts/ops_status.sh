#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
PROD_ORIGIN="${PROD_ORIGIN:-https://monitor.portalecomdo.com.br}"
STAGING_ORIGIN="${STAGING_ORIGIN:-https://staging.monitor.portalecomdo.com.br}"

line() { printf '%s\n' "----------------------------------------"; }

status_container() {
  local name="$1"
  local running health
  running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)"
  printf '%s: running=%s health=%s\n' "$name" "$running" "$health"
}

status_http() {
  local label="$1"
  local url="$2"
  local code
  code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  [ -n "$code" ] || code="000"
  printf '%s: HTTP %s (%s)\n' "$label" "$code" "$url"
}

backup_status() {
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup: diretorio ausente ($BACKUP_DIR)"
    return
  fi
  local latest epoch now age_h
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'auth-*.tgz' -printf '%T@ %p\n' | sort -nr | head -n1 | awk '{print $2}')"
  if [ -z "${latest:-}" ]; then
    echo "Backup: nenhum arquivo auth-*.tgz"
    return
  fi
  epoch="$(stat -c %Y "$latest")"
  now="$(date +%s)"
  age_h="$(( (now - epoch) / 3600 ))"
  echo "Backup: $(basename "$latest") (${age_h}h)"
}

echo "== Ops Status portaleco-vps-monitor =="
echo "Data: $(date '+%Y-%m-%d %H:%M:%S %z')"
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
status_http "prod root" "${PROD_ORIGIN}/"
status_http "prod auth/me" "${PROD_ORIGIN}/api/auth/me"
status_http "staging root" "${STAGING_ORIGIN}/"
status_http "staging auth/me" "${STAGING_ORIGIN}/api/auth/me"
line
echo "Cron"
if crontab -l 2>/dev/null | rg -F "./scripts/backup_create.sh" >/dev/null; then
  echo "backup_create: presente"
else
  echo "backup_create: ausente"
fi
if crontab -l 2>/dev/null | rg -F "./scripts/health_alert_check.sh" >/dev/null; then
  echo "health_alert_check: presente"
else
  echo "health_alert_check: ausente"
fi
line
backup_status
