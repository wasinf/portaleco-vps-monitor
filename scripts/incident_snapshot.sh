#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/backups/incidents}"
TS="$(date +%Y%m%dT%H%M%S%z | sed 's/+//')"
SNAP_DIR="$OUT_DIR/incident-$TS"
ARCHIVE="$OUT_DIR/incident-$TS.tgz"

mkdir -p "$SNAP_DIR"

run_capture() {
  local name="$1"
  shift
  {
    echo "## command: $*"
    echo "## ts: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
    "$@"
  } >"$SNAP_DIR/$name.txt" 2>&1 || true
}

run_capture_sh() {
  local name="$1"
  local cmd="$2"
  {
    echo "## command: $cmd"
    echo "## ts: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
    bash -lc "$cmd"
  } >"$SNAP_DIR/$name.txt" 2>&1 || true
}

echo "Coletando snapshot em: $SNAP_DIR"

run_capture_sh git_status "cd '$ROOT_DIR' && git status -sb && echo && git log --oneline -n 20"
run_capture_sh system_uptime "date; echo; uptime; echo; whoami; hostname"
run_capture docker_ps docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
run_capture_sh docker_compose_ps "cd '$ROOT_DIR/infra' && docker compose --env-file .env -f docker-compose.yml ps && echo && docker compose --env-file .env.staging -f docker-compose.staging.yml ps"
run_capture_sh portaleco_logs_backend "docker logs --tail 300 portaleco-vps-monitor-backend"
run_capture_sh portaleco_logs_frontend "docker logs --tail 200 portaleco-vps-monitor-frontend"
run_capture_sh portaleco_logs_backend_staging "docker logs --tail 200 portaleco-vps-monitor-backend-staging"
run_capture_sh portaleco_logs_frontend_staging "docker logs --tail 200 portaleco-vps-monitor-frontend-staging"
run_capture_sh preflight_prod "cd '$ROOT_DIR' && ./scripts/release_preflight.sh prod"
run_capture_sh ops_status "cd '$ROOT_DIR' && npm run -s status:ops"
run_capture_sh health_alert_check "cd '$ROOT_DIR' && ./scripts/health_alert_check.sh"
run_capture_sh auth_probe_prod "cd '$ROOT_DIR' && ./scripts/auth_login_probe.sh prod"
run_capture_sh host_surface "cd '$ROOT_DIR' && ./scripts/host_surface_check.sh"
run_capture_sh cron_list "crontab -l 2>/dev/null || true"
run_capture_sh headers_prod "curl -ksSI --max-time 12 https://monitor.portalecomdo.com.br/"

cat >"$SNAP_DIR/README.txt" <<EOF
PortalEco incident snapshot
timestamp: $TS
root_dir: $ROOT_DIR

Arquivos:
- git_status.txt
- system_uptime.txt
- docker_ps.txt
- docker_compose_ps.txt
- portaleco_logs_*.txt
- preflight_prod.txt
- ops_status.txt
- health_alert_check.txt
- auth_probe_prod.txt
- host_surface.txt
- cron_list.txt
- headers_prod.txt

Observacao:
- este pacote nao inclui o conteúdo de arquivos .env.
EOF

tar -czf "$ARCHIVE" -C "$OUT_DIR" "$(basename "$SNAP_DIR")"
echo "OK: snapshot criado em $ARCHIVE"
