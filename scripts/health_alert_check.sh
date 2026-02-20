#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALERT_ENV_FILE="${ALERT_ENV_FILE:-$ROOT_DIR/infra/.health-alert.env}"
if [ -f "$ALERT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_ENV_FILE"
fi

PROD_BACKEND="portaleco-vps-monitor-backend"
PROD_FRONTEND="portaleco-vps-monitor-frontend"
STG_BACKEND="portaleco-vps-monitor-backend-staging"
STG_FRONTEND="portaleco-vps-monitor-frontend-staging"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"

failures=0
report_lines=()

check_container_health() {
  local container_name="$1"
  local label="$2"
  local running
  local health

  running="$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "missing")"

  if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
    report_lines+=("OK ${label}: running=${running}, health=${health}")
  else
    report_lines+=("FAIL ${label}: running=${running}, health=${health}")
    failures=$((failures + 1))
  fi
}

check_container_health "$PROD_BACKEND" "prod-backend"
check_container_health "$PROD_FRONTEND" "prod-frontend"
check_container_health "$STG_BACKEND" "staging-backend"
check_container_health "$STG_FRONTEND" "staging-frontend"

echo "Health check summary:"
printf '%s\n' "${report_lines[@]}"

if [ "$failures" -gt 0 ]; then
  if [ -n "$ALERT_WEBHOOK_URL" ]; then
    payload="$(printf '%s\n' "${report_lines[@]}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    curl -fsS -X POST "$ALERT_WEBHOOK_URL" \
      -H "content-type: application/json" \
      -d "{\"text\":\"portaleco-vps-monitor healthcheck FAILED\\n${payload}\"}" >/dev/null || true
  fi
  exit 1
fi

exit 0
