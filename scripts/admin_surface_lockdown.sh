#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_ENV_FILE="$ROOT_DIR/infra/admin-surface.env"
if [ -f "$DEFAULT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_ENV_FILE"
fi

MODE="${1:---check}"
ACCESS_MODE="${ADMIN_ACCESS_MODE:-lan_whitelist}"
PORTS_CSV="${ADMIN_SURFACE_PORTS:-8088,9443}"
WHITELIST_CIDRS="${ADMIN_SURFACE_WHITELIST:-127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
IFACE="${ADMIN_SURFACE_IFACE:-}"
CHAIN="${ADMIN_SURFACE_CHAIN:-DOCKER-USER}"
RULE_TAG="${ADMIN_SURFACE_TAG:-portaleco-admin}"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--apply" ] && [ "$MODE" != "--remove" ]; then
  echo "Uso: $0 [--check|--apply|--remove]"
  exit 1
fi

if [ "$ACCESS_MODE" != "lan_whitelist" ] && [ "$ACCESS_MODE" != "tunnel_only" ]; then
  echo "FAIL: ADMIN_ACCESS_MODE invalido: $ACCESS_MODE (use: lan_whitelist|tunnel_only)"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "FAIL: este script requer root para consultar/aplicar regras iptables."
  echo "Use: sudo $0 $MODE"
  exit 1
fi

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; }

has_chain() {
  iptables -S "$CHAIN" >/dev/null 2>&1
}

cidr_tag() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/_/g'
}

deny_comment() {
  local port="$1"
  printf '%s-deny-%s' "$RULE_TAG" "$port"
}

allow_comment() {
  local port="$1"
  local cidr="$2"
  printf '%s-allow-%s-%s' "$RULE_TAG" "$port" "$(cidr_tag "$cidr")"
}

rule_args_base() {
  if [ -n "$IFACE" ]; then
    printf -- '-i %s ' "$IFACE"
  fi
}

rule_exists_deny() {
  local port="$1"
  # shellcheck disable=SC2046
  iptables -C "$CHAIN" $(rule_args_base) -p tcp --dport "$port" -m comment --comment "$(deny_comment "$port")" -j REJECT >/dev/null 2>&1
}

rule_exists_allow() {
  local port="$1"
  local cidr="$2"
  # shellcheck disable=SC2046
  iptables -C "$CHAIN" $(rule_args_base) -s "$cidr" -p tcp --dport "$port" -m comment --comment "$(allow_comment "$port" "$cidr")" -j ACCEPT >/dev/null 2>&1
}

add_deny_rule() {
  local port="$1"
  if rule_exists_deny "$port"; then
    ok "deny ja existe na porta ${port}"
    return 0
  fi
  # shellcheck disable=SC2046
  iptables -I "$CHAIN" 1 $(rule_args_base) -p tcp --dport "$port" -m comment --comment "$(deny_comment "$port")" -j REJECT
  ok "deny aplicado na porta ${port}"
}

add_allow_rule() {
  local port="$1"
  local cidr="$2"
  if rule_exists_allow "$port" "$cidr"; then
    ok "allow ja existe na porta ${port} para ${cidr}"
    return 0
  fi
  # shellcheck disable=SC2046
  iptables -I "$CHAIN" 1 $(rule_args_base) -s "$cidr" -p tcp --dport "$port" -m comment --comment "$(allow_comment "$port" "$cidr")" -j ACCEPT
  ok "allow aplicado na porta ${port} para ${cidr}"
}

remove_rule_deny() {
  local port="$1"
  while rule_exists_deny "$port"; do
    # shellcheck disable=SC2046
    iptables -D "$CHAIN" $(rule_args_base) -p tcp --dport "$port" -m comment --comment "$(deny_comment "$port")" -j REJECT
    ok "deny removido da porta ${port}"
  done
}

remove_rule_allow() {
  local port="$1"
  local cidr="$2"
  while rule_exists_allow "$port" "$cidr"; do
    # shellcheck disable=SC2046
    iptables -D "$CHAIN" $(rule_args_base) -s "$cidr" -p tcp --dport "$port" -m comment --comment "$(allow_comment "$port" "$cidr")" -j ACCEPT
    ok "allow removido da porta ${port} para ${cidr}"
  done
}

if ! has_chain; then
  fail "chain ${CHAIN} nao encontrada. Docker pode nao estar ativo."
  exit 1
fi

IFS=',' read -r -a ports <<< "$PORTS_CSV"
IFS=',' read -r -a whitelist <<< "$WHITELIST_CIDRS"
errors=0

echo "== Admin surface lockdown (${MODE}) =="
echo "Modo de acesso admin: ${ACCESS_MODE}"
echo "Portas monitoradas: ${PORTS_CSV}"
echo "Whitelist CIDRs: ${WHITELIST_CIDRS}"
[ -n "$IFACE" ] && echo "Interface filtrada: ${IFACE}"
echo "Chain: ${CHAIN}"

for raw in "${ports[@]}"; do
  port="$(echo "$raw" | tr -d '[:space:]')"
  [ -n "$port" ] || continue
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    warn "porta invalida ignorada: ${raw}"
    continue
  fi

  if [ "$MODE" = "--remove" ]; then
    remove_rule_deny "$port"
    for cidr_raw in "${whitelist[@]}"; do
      cidr="$(echo "$cidr_raw" | tr -d '[:space:]')"
      [ -n "$cidr" ] || continue
      remove_rule_allow "$port" "$cidr"
    done
    continue
  fi

  if [ "$ACCESS_MODE" = "lan_whitelist" ]; then
    if [ "$MODE" = "--check" ]; then
      for cidr_raw in "${whitelist[@]}"; do
        cidr="$(echo "$cidr_raw" | tr -d '[:space:]')"
        [ -n "$cidr" ] || continue
        if rule_exists_allow "$port" "$cidr"; then
          ok "allow ativo na porta ${port} para ${cidr}"
        else
          fail "allow ausente na porta ${port} para ${cidr}"
          errors=$((errors + 1))
        fi
      done
      if rule_exists_deny "$port"; then
        ok "deny ativo na porta ${port}"
      else
        fail "deny ausente na porta ${port}"
        errors=$((errors + 1))
      fi
    else
      add_deny_rule "$port" || errors=$((errors + 1))
      for cidr_raw in "${whitelist[@]}"; do
        cidr="$(echo "$cidr_raw" | tr -d '[:space:]')"
        [ -n "$cidr" ] || continue
        add_allow_rule "$port" "$cidr" || errors=$((errors + 1))
      done
    fi
    continue
  fi

  # tunnel_only
  if [ "$MODE" = "--check" ]; then
    if rule_exists_deny "$port"; then
      ok "deny ativo na porta ${port}"
    else
      fail "deny ausente na porta ${port}"
      errors=$((errors + 1))
    fi
  else
    add_deny_rule "$port" || errors=$((errors + 1))
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
