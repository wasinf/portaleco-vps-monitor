#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_FILE="$ROOT_DIR/.gitmessage-ptbr.txt"

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Template nao encontrado: $TEMPLATE_FILE"
  exit 1
fi

git -C "$ROOT_DIR" config commit.template "$TEMPLATE_FILE"

echo "Configuracao aplicada no repositorio:"
echo "- commit.template = $TEMPLATE_FILE"
echo
echo "Dica: ao rodar 'git commit' sem -m, o editor abrirá com o template PT-BR."
