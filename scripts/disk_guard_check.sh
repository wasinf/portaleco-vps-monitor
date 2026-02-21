#!/bin/bash
set -euo pipefail

WARN_THRESHOLD="${DISK_WARN_THRESHOLD:-85}"
FAIL_THRESHOLD="${DISK_FAIL_THRESHOLD:-92}"
DISK_PATHS="${DISK_PATHS:-/,/var/lib/docker,/opt/apps}"

if ! [[ "$WARN_THRESHOLD" =~ ^[0-9]+$ ]] || ! [[ "$FAIL_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "FAIL: thresholds invalidos (use inteiros)."
  exit 1
fi

if [ "$WARN_THRESHOLD" -ge "$FAIL_THRESHOLD" ]; then
  echo "FAIL: DISK_WARN_THRESHOLD deve ser menor que DISK_FAIL_THRESHOLD."
  exit 1
fi

errors=0
warnings=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

echo "== Disk guard check =="
echo "Warn: ${WARN_THRESHOLD}%"
echo "Fail: ${FAIL_THRESHOLD}%"

IFS=',' read -r -a paths <<<"$DISK_PATHS"
for path in "${paths[@]}"; do
  path="$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$path" ] || continue

  if [ ! -e "$path" ]; then
    warn "path ausente: $path"
    continue
  fi

  usage="$(df -P "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
  avail="$(df -hP "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  mountp="$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $6}')"

  if [ -z "$usage" ] || ! [[ "$usage" =~ ^[0-9]+$ ]]; then
    warn "nao foi possivel ler uso de disco para $path"
    continue
  fi

  if [ "$usage" -ge "$FAIL_THRESHOLD" ]; then
    fail "disco critico em $path (mount ${mountp}): ${usage}% usado, livre ${avail}"
  elif [ "$usage" -ge "$WARN_THRESHOLD" ]; then
    warn "disco alto em $path (mount ${mountp}): ${usage}% usado, livre ${avail}"
  else
    ok "disco saudavel em $path (mount ${mountp}): ${usage}% usado, livre ${avail}"
  fi
done

echo "== Resultado disk guard =="
echo "Erros: $errors"
echo "Avisos: $warnings"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
