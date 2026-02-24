#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

retry_cmd() {
  local max_attempts="$1"
  local sleep_seconds="$2"
  shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    echo "Tentativa ${attempt}/${max_attempts} falhou: $*"
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done
}

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" = "HEAD" ]; then
  echo "FAIL: repositorio em estado detached HEAD."
  exit 1
fi

if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
  echo "FAIL: nao e permitido usar git:auto em ${current_branch}."
  echo "Use branch de trabalho (fix/..., feat/..., chore/...)."
  exit 1
fi

git add -A

if git diff --cached --quiet; then
  echo "Nada para commitar. Workspace limpo."
  exit 0
fi

type_part="${current_branch%%/*}"
slug_part="${current_branch#*/}"

if [ "$type_part" = "$current_branch" ]; then
  type_part="chore"
  slug_part="$current_branch"
fi

case "$type_part" in
  feat|fix|chore|docs|refactor|perf|test) ;;
  *)
    type_part="chore"
    ;;
esac

scope="$(printf '%s' "$slug_part" | cut -d'-' -f1 | tr -cd '[:alnum:]_-')"
[ -n "$scope" ] || scope="geral"

desc_default="$(printf '%s' "$slug_part" | tr '-' ' ')"
[ -n "$desc_default" ] || desc_default="atualizar implementacao"

commit_desc="${GIT_AUTO_DESC:-$desc_default}"
commit_msg="${type_part}(${scope}): ${commit_desc}"

echo "Commit: $commit_msg"
git commit -m "$commit_msg"

if git rev-parse --verify "@{upstream}" >/dev/null 2>&1; then
  push_cmd=(git push)
else
  push_cmd=(git push -u origin "$current_branch")
fi

if ! retry_cmd 3 3 "${push_cmd[@]}"; then
  echo "FAIL: push nao concluido apos 3 tentativas."
  echo "Verifique DNS/conectividade com github.com e tente novamente."
  exit 1
fi

echo "Push concluido em: $current_branch"
