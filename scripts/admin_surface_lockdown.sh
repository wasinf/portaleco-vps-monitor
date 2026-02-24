#!/bin/bash
set -euo pipefail

MODE="${1:---check}"
PORTS_CSV="${ADMIN_SURFACE_PORTS:-8088,9443}"
IFACE="${ADMIN_SURFACE_IFACE:-}"
CHAIN="DOCKER-USER"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--apply" ]; then
  echo "Uso: $0 [--check|--apply]"
  exit 1
fi

if [ "$MODE" = "--apply" ] && [ "$(id -u)" -ne 0 ]; then
  echo "FAIL: --apply requer root (use sudo)."
  exit 1
fi

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; }

has_chain() {
  iptables -S "$CHAIN" >/dev/null 2>&1
}

rule_exists() {
  local port="$1"
  if [ -n "$IFACE" ]; then
    iptables -C "$CHAIN" -i "$IFACE" -p tcp --dport "$port" -j REJECT >/dev/null 2>&1
  else
    iptables -C "$CHAIN" -p tcp --dport "$port" -j REJECT >/dev/null 2>&1
  fi
}

apply_rule() {
  local port="$1"
  if rule_exists "$port"; then
    ok "regra ja existe para porta ${port}"
    return 0
  fi
  if [ -n "$IFACE" ]; then
    iptables -I "$CHAIN" 1 -i "$IFACE" -p tcp --dport "$port" -j REJECT
  else
    iptables -I "$CHAIN" 1 -p tcp --dport "$port" -j REJECT
  fi
  ok "regra adicionada para bloquear porta publica ${port}"
}

if ! has_chain; then
  fail "chain ${CHAIN} nao encontrada. Docker pode nao estar ativo."
  exit 1
fi

IFS=',' read -r -a ports <<< "$PORTS_CSV"
errors=0

echo "== Admin surface lockdown (${MODE}) =="
echo "Portas monitoradas: ${PORTS_CSV}"
[ -n "$IFACE" ] && echo "Interface filtrada: ${IFACE}"

for raw in "${ports[@]}"; do
  port="$(echo "$raw" | tr -d '[:space:]')"
  [ -n "$port" ] || continue
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    warn "porta invalida ignorada: ${raw}"
    continue
  fi

  if [ "$MODE" = "--check" ]; then
    if rule_exists "$port"; then
      ok "bloqueio ativo na porta ${port}"
    else
      fail "bloqueio ausente na porta ${port}"
      errors=$((errors + 1))
    fi
  else
    apply_rule "$port" || errors=$((errors + 1))
  fi
done

if [ "$MODE" = "--apply" ]; then
  echo "Dica: para persistir regras apos reboot, salve com iptables-persistent."
fi

echo "== Resultado =="
echo "Erros: ${errors}"
if [ "$errors" -gt 0 ]; then
  exit 1
fi
