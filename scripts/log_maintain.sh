#!/bin/bash
set -euo pipefail

LOG_GLOB="${LOG_GLOB:-/var/log/portaleco-*.log}"
MAX_BYTES="${MAX_BYTES:-5242880}" # 5 MiB
RETENTION_DAYS="${RETENTION_DAYS:-14}"

rotated=0
removed=0
errors=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

rotate_file() {
  local file="$1"
  local size suffix target

  if [ ! -f "$file" ]; then
    return 0
  fi

  size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$MAX_BYTES" ]; then
    ok "mantido: $file (${size} bytes)"
    return 0
  fi

  suffix="$(date +%Y%m%d%H%M%S)"
  target="${file}.${suffix}"

  if mv "$file" "$target"; then
    : > "$file"
    if gzip -f "$target"; then
      rotated=$((rotated + 1))
      ok "rotacionado: $file -> ${target}.gz (${size} bytes)"
      return 0
    fi
    fail "falha ao compactar arquivo rotacionado: $target"
    return 1
  fi

  fail "falha ao rotacionar: $file"
  return 1
}

echo "== Log maintain =="
echo "Glob: ${LOG_GLOB}"
echo "Max bytes: ${MAX_BYTES}"
echo "Retention days: ${RETENTION_DAYS}"

files="$(ls $LOG_GLOB 2>/dev/null || true)"
if [ -z "${files:-}" ]; then
  warn "nenhum log encontrado para o padrao informado."
else
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rotate_file "$file"
  done <<<"$files"
fi

while IFS= read -r old; do
  [ -n "$old" ] || continue
  if rm -f "$old"; then
    removed=$((removed + 1))
    ok "removido por retencao: $old"
  else
    fail "falha ao remover por retencao: $old"
  fi
done < <(find /var/log -maxdepth 1 -type f -name 'portaleco-*.log.*' -mtime "+$RETENTION_DAYS" 2>/dev/null || true)

echo "== Resultado log maintain =="
echo "Rotacionados: $rotated"
echo "Removidos: $removed"
echo "Erros: $errors"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
