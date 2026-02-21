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
HEALTH_CHECK_AUTH_PROBE="${HEALTH_CHECK_AUTH_PROBE:-true}"
HEALTH_CHECK_AUTH_PROBE_STAGING="${HEALTH_CHECK_AUTH_PROBE_STAGING:-true}"
HEALTH_CHECK_AUTH_PROBE_STAGING_SOFT_FAIL="${HEALTH_CHECK_AUTH_PROBE_STAGING_SOFT_FAIL:-true}"
HEALTH_CHECK_DISK_GUARD="${HEALTH_CHECK_DISK_GUARD:-true}"

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

if [ "$HEALTH_CHECK_AUTH_PROBE" = "true" ]; then
  if "$ROOT_DIR/scripts/auth_login_probe.sh" prod >/tmp/health_auth_prod.out 2>&1; then
    report_lines+=("OK prod-auth-probe: login/sessao validos")
  else
    report_lines+=("FAIL prod-auth-probe: $(tail -n 1 /tmp/health_auth_prod.out 2>/dev/null || echo 'erro no probe')")
    failures=$((failures + 1))
  fi
  rm -f /tmp/health_auth_prod.out 2>/dev/null || true
fi

if [ "$HEALTH_CHECK_AUTH_PROBE_STAGING" = "true" ]; then
  if AUTH_LOGIN_PROBE_SOFT_FAIL="$HEALTH_CHECK_AUTH_PROBE_STAGING_SOFT_FAIL" "$ROOT_DIR/scripts/auth_login_probe.sh" staging >/tmp/health_auth_stg.out 2>&1; then
    report_lines+=("OK staging-auth-probe: probe concluido")
  else
    report_lines+=("FAIL staging-auth-probe: $(tail -n 1 /tmp/health_auth_stg.out 2>/dev/null || echo 'erro no probe')")
    failures=$((failures + 1))
  fi
  rm -f /tmp/health_auth_stg.out 2>/dev/null || true
fi

if [ "$HEALTH_CHECK_DISK_GUARD" = "true" ]; then
  if "$ROOT_DIR/scripts/disk_guard_check.sh" >/tmp/health_disk_guard.out 2>&1; then
    report_lines+=("OK disk-guard: uso de disco dentro dos limites")
  else
    report_lines+=("FAIL disk-guard: $(tail -n 1 /tmp/health_disk_guard.out 2>/dev/null || echo 'erro no disk guard')")
    failures=$((failures + 1))
  fi
  rm -f /tmp/health_disk_guard.out 2>/dev/null || true
fi

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
