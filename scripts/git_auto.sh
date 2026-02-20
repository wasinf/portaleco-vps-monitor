#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" = "HEAD" ]; then
  echo "FAIL: repositorio em estado detached HEAD."
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
  git push
else
  git push -u origin "$current_branch"
fi

echo "Push concluido em: $current_branch"
