#!/bin/bash
set -euo pipefail

STRICT_ADMIN="${HOST_SURFACE_STRICT_ADMIN:-false}"
ALLOW_PUBLIC_PORTS="${ALLOW_PUBLIC_PORTS:-22,80,443}"
WARN_PUBLIC_PORTS="${WARN_PUBLIC_PORTS:-25}"
ADMIN_PUBLIC_PORTS="${ADMIN_PUBLIC_PORTS:-8088,9000,9443}"

errors=0
warnings=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

csv_has() {
  local csv="$1"
  local value="$2"
  printf '%s' "$csv" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | rg -Fx "$value" >/dev/null 2>&1
}

collect_public_ports() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}'
  else
    return 127
  fi | awk -F: '
    {
      addr=$0
      port=$NF
      gsub(/^\[/, "", addr)
      gsub(/\]$/, "", addr)
      if (addr ~ /^0\.0\.0\.0:/ || addr ~ /^\[::\]:/ || addr ~ /^\*:/ || addr ~ /^:::/) {
        print port
      }
    }
  ' | sed 's/[^0-9]//g' | rg '^[0-9]+$' | sort -u
}

is_expected_port_81_bind() {
  if ! command -v docker >/dev/null 2>&1; then
    return 2
  fi

  local rows
  if ! rows="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)"; then
    return 2
  fi

  if printf '%s\n' "$rows" | awk -F'\t' '
    $1=="nginx-proxy-manager" && ($2 ~ /0\.0\.0\.0:80-81->80-81/ || $2 ~ /0\.0\.0\.0:81->/) { found=1 }
    END { exit(found ? 0 : 1) }
  '; then
    return 0
  fi
  return 1
}

echo "== Host surface check =="
echo "Modo estrito admin: ${STRICT_ADMIN}"
echo "Portas publicas permitidas: ${ALLOW_PUBLIC_PORTS}"
echo "Portas publicas de aviso: ${WARN_PUBLIC_PORTS}"
echo "Portas admin monitoradas: ${ADMIN_PUBLIC_PORTS}"

if ! public_ports="$(collect_public_ports)"; then
  fail "nao foi possivel listar portas (ss/netstat ausentes)"
  echo "== Resultado host surface =="
  echo "Erros: $errors"
  echo "Avisos: $warnings"
  exit 1
fi

if [ -z "${public_ports:-}" ]; then
  warn "nenhuma porta publica detectada"
else
  while IFS= read -r port; do
    [ -n "$port" ] || continue

    if [ "$port" = "81" ]; then
      if is_expected_port_81_bind; then
        ok "porta publica esperada (Nginx Proxy Manager): 81"
      else
        case $? in
          1) fail "porta 81 publica inesperada (nao vinculada ao nginx-proxy-manager)" ;;
          2) warn "porta 81 publica detectada, mas sem acesso ao Docker para validar ownership" ;;
          *) fail "falha ao validar ownership da porta 81" ;;
        esac
      fi
      continue
    fi

    if csv_has "$ALLOW_PUBLIC_PORTS" "$port"; then
      ok "porta publica permitida: ${port}"
      continue
    fi

    if csv_has "$WARN_PUBLIC_PORTS" "$port"; then
      warn "porta publica em observacao: ${port}"
      continue
    fi

    if csv_has "$ADMIN_PUBLIC_PORTS" "$port"; then
      if [ "$STRICT_ADMIN" = "true" ]; then
        fail "porta admin publica bloqueada (modo estrito): ${port}"
      else
        warn "porta admin publica detectada: ${port}"
      fi
      continue
    fi

    fail "porta publica inesperada: ${port}"
  done <<<"$public_ports"
fi

echo "== Resultado host surface =="
echo "Erros: $errors"
echo "Avisos: $warnings"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
