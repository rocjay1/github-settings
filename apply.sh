#!/usr/bin/env bash
# Apply the repo settings baseline to your personal GitHub repos.
# Dry run by default; pass --apply to write changes. Assumes GitHub Pro (rulesets enforced on private repos).
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

# Secret scanning + push protection: free on public repos; private repos need GitHub
# Secret Protection (not part of Pro), so they're skipped.
public_security='{"secret_scanning": "enabled", "secret_scanning_push_protection": "enabled"}'

# Default-branch ruleset (Pro: enforced on private repos too). Required status checks are
# per repo: taken from required_checks below if listed, else kept from the repo's existing
# ruleset, else from classic branch protection (which is then removed in favour of the ruleset).
ruleset_name="default-branch-standards"
actions_app_id=15368  # GitHub Actions

# Required checks for repos that had no protection to inherit them from. One context per line.
required_checks() {
  case "$1" in
    mac-config)     printf '%s\n' test lint secrets ;;
    applebridge)    printf '%s\n' test ;;
    rocjay1.github.io) printf '%s\n' build "secrets / secrets" ;;
    copilot-config) printf '%s\n' "offline (macos-latest)" "offline (windows-latest)" ;;
  esac
}

# Canonical form for comparing rulesets: core fields, rules sorted by type, checks sorted.
normalize='{enforcement, target, conditions, bypass_actors,
  rules: (.rules | map(if .type == "required_status_checks"
    then .parameters.required_status_checks |= sort_by(.context) else . end) | sort_by(.type))}'

ensure_ruleset() {
  local r=$1 rs_id="" have="null" classic="" checks
  rs_id=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r/rulesets" \
    --jq "map(select(.name == \"$ruleset_name\"))[0].id // empty")
  [[ -n "$rs_id" ]] && have=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r/rulesets/$rs_id")
  # gh prints the 404 body on stdout, so only keep output when the call succeeds.
  classic=$(gh api "repos/$owner/$r/branches/$default_branch/protection" 2>/dev/null) || classic=""

  checks=$(required_checks "$r" | jq -R . | jq -s .)
  if [[ "$checks" == "[]" && "$have" != "null" ]]; then
    checks=$(jq '[.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks[].context]' <<<"$have")
  fi
  if [[ "$checks" == "[]" && -n "$classic" ]]; then
    checks=$(jq '[.required_status_checks.checks[]?.context]' <<<"$classic")
  fi

  local want
  want=$(jq -n --arg name "$ruleset_name" --argjson checks "$checks" --argjson app "$actions_app_id" '{
    name: $name, target: "branch", enforcement: "active", bypass_actors: [],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: ([
      {type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        allowed_merge_methods: ["squash"], dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false, require_last_push_approval: false,
        required_approving_review_count: 0, required_review_thread_resolution: true}}
    ] + (if $checks == [] then [] else [{type: "required_status_checks", parameters: {
        do_not_enforce_on_create: false, strict_required_status_checks_policy: true,
        required_status_checks: ($checks | map({context: ., integration_id: $app}))}}] end))}')

  # GitHub fills in defaults for pull_request params we don't set; compare only the keys we set.
  local have_cmp
  have_cmp=$(jq --argjson want "$want" '
    if . == null then null else
    .rules |= map(if .type == "pull_request"
      then .parameters |= with_entries(select(.key as $k
        | $want.rules[] | select(.type == "pull_request") | .parameters | has($k)))
      else . end) end' <<<"$have")

  if [[ "$(jq -S "$normalize" <<<"$want")" != "$(jq -S "if . == null then null else $normalize end" <<<"$have_cmp")" ]]; then
    changed=$((changed + 1))
    if [[ "$have" == "null" ]]; then
      echo "$r: create ruleset $ruleset_name (checks: $(jq -r 'if . == [] then "none" else join(", ") end' <<<"$checks"))"
      $apply && gh api -X POST "repos/$owner/$r/rulesets" --input - <<<"$want" >/dev/null
    else
      echo "$r: update ruleset $ruleset_name (checks: $(jq -r 'if . == [] then "none" else join(", ") end' <<<"$checks"))"
      diff <(jq -S "$normalize" <<<"$have_cmp") <(jq -S "$normalize" <<<"$want") | sed "s/^/$r:   /" || true
      $apply && gh api -X PUT "repos/$owner/$r/rulesets/$rs_id" --input - <<<"$want" >/dev/null
    fi
  else
    echo "$r: ruleset ok"
  fi

  if [[ -n "$classic" ]]; then
    changed=$((changed + 1))
    echo "$r: remove classic branch protection on $default_branch (replaced by ruleset)"
    $apply && gh api -X DELETE "repos/$owner/$r/branches/$default_branch/protection" >/dev/null
  fi
  return 0
}

owner=$(gh api user --jq .login)
changed=0
for r in $(gh repo list "$owner" --limit 500 --no-archived --source --json name --jq '.[].name'); do
  current=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r")
  default_branch=$(jq -r .default_branch <<<"$current")
  # Keep only baseline keys whose current value differs.
  diff=$(jq -n --argjson want "$baseline" --argjson have "$current" \
    '$want | with_entries(select($have[.key] != .value))')
  if [[ "$diff" == "{}" ]]; then
    echo "$r: settings ok"
  else
    changed=$((changed + 1))
    jq -r --arg r "$r" --argjson have "$current" \
      'to_entries[] | "\($r): \(.key) \($have[.key]) -> \(.value)"' <<<"$diff"
    if $apply; then
      gh api -X PATCH "repos/$owner/$r" --input - <<<"$diff" >/dev/null
      echo "$r: applied"
    fi
  fi
  if [[ "$(jq -r .visibility <<<"$current")" == "public" ]]; then
    sec=$(jq -n --argjson want "$public_security" --argjson have "$current" \
      '$want | with_entries(select(($have.security_and_analysis[.key].status // "disabled") != .value))')
    if [[ "$sec" == "{}" ]]; then
      echo "$r: security ok"
    else
      changed=$((changed + 1))
      jq -r --arg r "$r" --argjson have "$current" \
        'to_entries[] | "\($r): \(.key) \($have.security_and_analysis[.key].status // "disabled") -> \(.value)"' <<<"$sec"
      if $apply; then
        jq '{security_and_analysis: map_values({status: .})}' <<<"$sec" \
          | gh api -X PATCH "repos/$owner/$r" --input - >/dev/null
        echo "$r: applied"
      fi
    fi
  fi
  # Immutable releases: a published release's tag can't be moved or deleted. Only covers
  # releases published after it's enabled. Callers of github-settings' reusable workflows
  # pin to these tags.
  if [[ "$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r/immutable-releases" --jq .enabled)" == "true" ]]; then
    echo "$r: immutable releases ok"
  else
    changed=$((changed + 1))
    echo "$r: immutable releases false -> true"
    if $apply; then
      gh api -X PUT "repos/$owner/$r/immutable-releases" >/dev/null
      echo "$r: applied"
    fi
  fi
  ensure_ruleset "$r"
done

if ! $apply && (( changed > 0 )); then
  echo; echo "Dry run: $changed change(s) pending. Re-run with --apply to write."
fi
