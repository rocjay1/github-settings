#!/usr/bin/env bash
# Install the pre-push hook into one or more local repos: install.sh ~/Code/core-infra [...]
# Writes to the repo's own .git/hooks and pins core.hooksPath there in the repo's local config,
# so a global core.hooksPath doesn't hide it.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)/pre-push"
for repo in "$@"; do
  hooks="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/hooks"
  dest="$hooks/pre-push"
  if [[ -e "$dest" ]] && ! cmp -s "$src" "$dest"; then
    echo "$repo: existing pre-push hook left alone ($dest)" >&2; continue
  fi
  mkdir -p "$hooks"
  install -m 0755 "$src" "$dest"
  git -C "$repo" config --local core.hooksPath "$hooks"
  echo "$repo: installed $dest"
done
