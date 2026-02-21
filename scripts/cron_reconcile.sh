#!/bin/bash
set -euo pipefail

MODE="${1:---check}"
ROOT_DIR="${ROOT_DIR:-/opt/apps/portaleco-vps-monitor}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/portaleco-backup.log}"
HEALTH_LOG="${HEALTH_LOG:-/var/log/portaleco-health.log}"
STATUS_LOG="${STATUS_LOG:-/var/log/portaleco-ops-status.log}"
SELFHEAL_LOG="${SELFHEAL_LOG:-/var/log/portaleco-auth-selfheal.log}"
LOG_MAINTAIN_LOG="${LOG_MAINTAIN_LOG:-/var/log/portaleco-log-maintain.log}"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--apply" ]; then
  echo "Uso: $0 [--check|--apply]"
  exit 1
fi

BEGIN_MARK="# >>> portaleco-vps-monitor managed cron >>>"
END_MARK="# <<< portaleco-vps-monitor managed cron <<<"

managed_block() {
  cat <<EOF
$BEGIN_MARK
0 2 * * * cd $ROOT_DIR && ./scripts/backup_create.sh >$BACKUP_LOG 2>&1
*/5 * * * * cd $ROOT_DIR && ./scripts/health_alert_check.sh >$HEALTH_LOG 2>&1
15 * * * * cd $ROOT_DIR && npm run -s status:ops >$STATUS_LOG 2>&1
35 * * * * cd $ROOT_DIR && AUTH_SELFHEAL_SOFT_FAIL_PUBLIC=true npm run -s auth:selfheal:prod >$SELFHEAL_LOG 2>&1
20 3 * * * cd $ROOT_DIR && ./scripts/log_maintain.sh >$LOG_MAINTAIN_LOG 2>&1
$END_MARK
EOF
}

current_cron="$(crontab -l 2>/dev/null || true)"
tmp_current="$(mktemp)"
tmp_clean="$(mktemp)"
tmp_dedup="$(mktemp)"
tmp_base="$(mktemp)"
tmp_target="$(mktemp)"
trap 'rm -f "$tmp_current" "$tmp_clean" "$tmp_dedup" "$tmp_base" "$tmp_target"' EXIT

printf '%s\n' "$current_cron" >"$tmp_current"

awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
  $0==begin {skip=1; next}
  $0==end {skip=0; next}
  !skip {print}
' "$tmp_current" >"$tmp_clean"

cp "$tmp_clean" "$tmp_dedup"
while IFS= read -r managed_line; do
  [ -n "$managed_line" ] || continue
  case "$managed_line" in
    "$BEGIN_MARK"|"$END_MARK")
      continue
      ;;
  esac
  grep -Fvx "$managed_line" "$tmp_dedup" >"$tmp_dedup.next" || true
  mv "$tmp_dedup.next" "$tmp_dedup"
done < <(managed_block)

# Remove linhas em branco no fim do arquivo base para gerar diff estavel.
awk '
  { lines[NR]=$0 }
  END {
    last=NR
    while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
    for (i=1; i<=last; i++) print lines[i]
  }
' "$tmp_dedup" >"$tmp_base"

{
  cat "$tmp_base"
  # Add a blank separator only when there is pre-existing content.
  if [ -s "$tmp_base" ]; then
    printf '\n'
  fi
  managed_block
} >"$tmp_target"

if [ "$MODE" = "--check" ]; then
  if diff -u "$tmp_current" "$tmp_target" >/dev/null 2>&1; then
    echo "OK: crontab ja esta reconciliada."
    exit 0
  fi
  echo "WARN: crontab divergente do padrao gerenciado."
  diff -u "$tmp_current" "$tmp_target" || true
  exit 1
fi

crontab "$tmp_target"
echo "OK: crontab reconciliada com bloco gerenciado do portaleco-vps-monitor."
