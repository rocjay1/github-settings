#!/usr/bin/env bash
# Apply the repo settings baseline to your personal GitHub repos.
# Dry run by default; pass --apply to write changes. Only touches settings that work on GitHub Free.
set -euo pipefail

apply=false
[[ "${1:-}" == "--apply" ]] && apply=true

# Desired settings (GitHub REST field names for PATCH /repos/{owner}/{repo}).
baseline='{
  "allow_merge_commit": false,
  "allow_squash_merge": true,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "allow_update_branch": true,
  "allow_auto_merge": false,
  "has_wiki": false,
  "has_projects": false
}'

owner=$(gh api user --jq .login)
changed=0
for r in $(gh repo list "$owner" --limit 500 --no-archived --source --json name --jq '.[].name'); do
  current=$(gh api "repos/$owner/$r")
  # Keep only baseline keys whose current value differs.
  diff=$(jq -n --argjson want "$baseline" --argjson have "$current" \
    '$want | with_entries(select($have[.key] != .value))')
  [[ "$diff" == "{}" ]] && { echo "$r: ok"; continue; }
  changed=$((changed + 1))
  jq -r --arg r "$r" --argjson have "$current" \
    'to_entries[] | "\($r): \(.key) \($have[.key]) -> \(.value)"' <<<"$diff"
  if $apply; then
    gh api -X PATCH "repos/$owner/$r" --input - <<<"$diff" >/dev/null
    echo "$r: applied"
  fi
done

if ! $apply && (( changed > 0 )); then
  echo; echo "Dry run: $changed repo(s) would change. Re-run with --apply to write."
fi
