#!/usr/bin/env bash
# Check each repo's callers of the shared workflows in this repo (secret-scan.yml,
# workflow-lint.yml) against the per-repo table below, and render the managed caller file.
# Reports callers that are missing or not pinned to an exact release tag, zizmor configs
# that would reject the tag pin, inline jobs the callers replace, and required checks that
# don't match the check names the callers produce. Rulesets are never changed here (see
# apply.sh required_checks).
# Dry run by default; pass --apply to open a draft PR in each repo whose managed file
# differs. Further arguments limit the run to those repos: ./workflows.sh --apply core-infra
set -euo pipefail

apply=false
[[ "${1:-}" == "--apply" ]] && { apply=true; shift; }
only=("$@")

path=".github/workflows/shared.yml"
branch="sync-shared-workflows"
header="# Managed by rocjay1/github-settings (workflows.sh). Edit it there; changes here get overwritten."
here=$(cd "$(dirname "$0")" && pwd)

# Shared jobs per repo, one "job [zizmor-config]" per line. Job ids are fixed so the
# checks report as "<job> / <job>". A repo with no entry is flagged; an entry with no lines
# opts the repo out.
jobs_for() {
  case "$1" in
    applebridge|copilot-config|core-infra|mac-config|rocjay1.github.io|simplifi-cli)
                       printf '%s\n' secrets workflows ;;
    github-settings)   ;;  # calls its own workflows by local path (ci.yml)
    cop-rehearsal)     ;;  # throwaway repo
    *) return 1 ;;
  esac
}

workflow_file() {
  case "$1" in
    secrets)   echo secret-scan.yml ;;
    workflows) echo workflow-lint.yml ;;
  esac
}

# Job-level permissions each shared workflow needs from its caller.
job_permissions() {
  case "$1" in
    secrets)   printf '%s\n' "contents: read" "pull-requests: read" ;;
    workflows) printf '%s\n' "contents: read" ;;
  esac
}

# Exact release tags only: vX.Y.Z. Branches, SHAs and floating majors are rejected.
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
uses_prefix="rocjay1/github-settings/.github/workflows/"

# shellcheck disable=SC2016  # ${{ }} is GitHub Actions syntax, not shell
render() {
  local spec=$1 tag=$2 job cfg
  printf '%s\n' "$header" "name: Shared checks" "" "on:" "  pull_request:" "  push:" \
    "    branches: [main]" "  schedule:" '    - cron: "23 6 * * 1"' "" "permissions: {}" "" \
    "concurrency:" '  group: shared-${{ github.ref }}' \
    "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "" \
    "# Shared checks from rocjay1/github-settings, each reporting as \"<job> / <job>\"." \
    "# Pinned to immutable release tags; Dependabot bumps them." "jobs:"
  local first=true
  while read -r job cfg; do
    $first || echo
    first=false
    echo "  $job:"
    echo "    permissions:"
    job_permissions "$job" | sed 's/^/      /'
    echo "    uses: $uses_prefix$(workflow_file "$job")@$tag"
    if [[ -n "$cfg" ]]; then
      printf '%s\n' "    with:" "      zizmor-config: $cfg"
    fi
  done <<<"$spec"
}

# Jobs in a workflow file as "id|name|uses", read by indentation (no YAML parser
# here). Assumes block-style YAML with job keys and their properties on their own lines.
list_jobs() {
  awk '
    function flush() { if (id != "") printf "%s|%s|%s\n", id, name, uses; id = name = uses = "" }
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/^["'\'']|["'\'']$/, "", s); return s }
    /^jobs:[ \t]*$/ { injobs = 1; jind = -1; next }
    injobs && /^[^ \t#]/ { flush(); injobs = 0 }
    !injobs || /^[ \t]*(#.*)?$/ { next }
    {
      match($0, /^ */); ind = RLENGTH
      if (jind < 0) jind = ind
      if (ind == jind) { flush(); id = substr($0, ind + 1); sub(/:.*/, "", id); pind = -1; next }
      if (pind < 0) pind = ind
      if (ind == pind && $0 ~ /^ *name:/) name = val($0)
      if (ind == pind && $0 ~ /^ *uses:/) uses = val($0)
    }
    END { flush() }'
}

fetch() {  # repo path -> content on stdout; fails if missing
  local b64
  b64=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$1/contents/$2" --jq .content 2>/dev/null) || return 1
  base64 -d <<<"$b64"
}

# Put the rendered file on $branch and open a draft PR if none is open. Same flow as
# dependabot.sh: commit on top of an open PR's branch, else reset the branch to the base.
open_pr() {
  local r=$1 content=$2 verb=$3 base head file_sha="" pr msg on_branch="" b64
  base=$(gh api "repos/$owner/$r" --jq .default_branch)
  pr=$(gh api "repos/$owner/$r/pulls?state=open&head=$owner:$branch" --jq '.[0].html_url // empty')
  if [[ -z "$pr" ]]; then
    head=$(gh api "repos/$owner/$r/git/ref/heads/$base" --jq .object.sha)
    if gh api "repos/$owner/$r/git/ref/heads/$branch" --silent 2>/dev/null; then
      gh api -X PATCH "repos/$owner/$r/git/refs/heads/$branch" -f sha="$head" -F force=true --silent
    else
      gh api -X POST "repos/$owner/$r/git/refs" -f ref="refs/heads/$branch" -f sha="$head" --silent
    fi
  fi
  if b64=$(gh api "repos/$owner/$r/contents/$path?ref=$branch" 2>/dev/null); then
    file_sha=$(jq -r .sha <<<"$b64")
    on_branch=$(jq -r .content <<<"$b64" | base64 -d)
  fi
  if [[ -n "$pr" && "$on_branch" == "$content" ]]; then
    echo "$r: $pr already up to date"
    return 0
  fi

  msg=$(printf '%s\n' "$verb shared workflow callers from github-settings" "" \
    "Generated by rocjay1/github-settings workflows.sh; edit it there." "" \
    "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
  jq -n --arg message "$msg" --arg branch "$branch" --arg sha "$file_sha" \
    --arg content "$(printf '%s\n' "$content" | base64 | tr -d '\n')" \
    '{message: $message, branch: $branch, content: $content} + (if $sha == "" then {} else {sha: $sha} end)' \
    | gh api -X PUT "repos/$owner/$r/contents/$path" --input - --silent

  if [[ -z "$pr" ]]; then
    pr=$(jq -n --arg title "$verb shared workflow callers from github-settings" --arg head "$branch" --arg base "$base" \
      --arg body "$(printf '%s\n' \
        "Renders \`$path\` from the per-repo table in [rocjay1/github-settings](https://github.com/$owner/github-settings) (\`workflows.sh\`). Change the callers there, not here." \
        "" "Findings from the run that opened this PR (fix by hand on this branch):" "" \
        "$(if [[ -n "$findings" ]]; then sed 's/^/- /' <<<"$findings"; else echo "- none"; fi)" \
        "" "🤖 Generated with [Claude Code](https://claude.com/claude-code)")" \
      '{title: $title, head: $head, base: $base, body: $body, draft: true}' \
      | gh api -X POST "repos/$owner/$r/pulls" --input - --jq .html_url)
    echo "$r: opened draft $pr"
  else
    echo "$r: updated $pr"
  fi
}

flag() { findings+="${findings:+$'\n'}$1"; echo "$r: $1"; }

zizmor_allows() { grep -Eq "^[[:space:]]+[\"']rocjay1/github-settings/\*[\"'][[:space:]]*:[[:space:]]*ref-pin"; }

# required_checks from apply.sh, the source of truth for rulesets.
eval "$(sed -n '/^required_checks() {/,/^}/p' "$here/apply.sh")"  # source <(...) is a no-op in macOS bash 3.2

owner=$(gh api user --jq .login)
latest=$(gh api "repos/$owner/github-settings/releases/latest" --jq .tag_name)
[[ "$latest" =~ $tag_re ]] || { echo "latest github-settings release $latest is not vX.Y.Z" >&2; exit 1; }
changed=0
issues=0
for r in $(gh repo list "$owner" --limit 500 --no-archived --source --json name --jq '.[].name'); do
  if (( ${#only[@]} )) && [[ " ${only[*]} " != *" $r "* ]]; then continue; fi
  if ! spec=$(jobs_for "$r"); then
    issues=$((issues + 1)); echo "$r: no entry in workflows.sh; skipped"; continue
  fi
  if [[ -z "$spec" ]]; then echo "$r: opted out"; continue; fi
  findings=""

  # All jobs across the repo's workflows: "file|id|name|uses"; every uses: as "file|ref".
  all_jobs=""
  all_uses=""
  have=""
  files=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r/contents/.github/workflows" \
    --jq '.[] | select(.name | test("\\.ya?ml$")) | .name' 2>/dev/null) || files=""
  for f in $files; do
    content=$(fetch "$r" ".github/workflows/$f") || continue
    if [[ ".github/workflows/$f" == "$path" ]]; then have=$content; fi
    all_jobs+=$(list_jobs <<<"$content" | sed "s#^#$f|#")$'\n'
    all_uses+=$(sed -nE "s#^[[:space:]]*(- )?uses:[[:space:]]*['\"]?([^'\" ]+).*#$f|\2#p" <<<"$content")$'\n'
  done

  # Keep the tag already pinned in the managed file (Dependabot moves it); else the latest.
  tag=$(grep -Eo "${uses_prefix//./\\.}[a-z-]+\.yml@[^ ]+" <<<"$have" | head -1 | sed 's/.*@//') || true
  [[ "$tag" =~ $tag_re ]] || tag=$latest
  want=$(render "$spec" "$tag")

  # Required contexts: apply.sh's list, else the live ruleset's.
  required=$(required_checks "$r")
  if [[ -z "$required" ]]; then
    required=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r/rules/branches/$(gh api "repos/$owner/$r" --jq .default_branch)" \
      --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
  fi

  while read -r job cfg; do
    wf=$(workflow_file "$job")
    check="$job / $job"
    # Callers of this shared workflow anywhere in the repo, the managed file included.
    good=0
    while IFS='|' read -r f id name uses; do
      if [[ -z "$f" || "$uses" != "$uses_prefix$wf@"* ]]; then continue; fi
      ref=${uses##*@}
      if [[ ! "$ref" =~ $tag_re ]]; then
        flag "$f job $id pins $wf@$ref; use an exact release tag (vX.Y.Z)"
      elif [[ "$id" != "$job" ]]; then
        flag "$f job $id calls $wf; the job id must be $job"
      else
        good=$((good + 1))
      fi
      if [[ ".github/workflows/$f" != "$path" ]]; then
        flag "$f job $id also calls $wf; remove it once $path lands"
      fi
    done <<<"$all_jobs"
    if (( good == 0 )); then flag "no job $job calls $wf@vX.Y.Z yet"; fi
    # Inline jobs that produce the same check name or stand in for the shared job.
    while IFS='|' read -r f id name uses; do
      if [[ -z "$f" || "$uses" == "$uses_prefix"* || "$uses" == ./* ]]; then continue; fi
      if [[ "$name" == "$check" ]]; then
        flag "$f inline job $id is named \"$check\"; remove it once $path lands"
      elif [[ "$id" == "$job" && -z "$uses" ]]; then
        flag "$f inline job $id duplicates the shared $job job; remove it once $path lands"
      fi
    done <<<"$all_jobs"

    if [[ "$job" == workflows ]]; then
      zcfg=${cfg:-.github/zizmor.yml}
      if zc=$(fetch "$r" "$zcfg"); then
        zizmor_allows <<<"$zc" || flag "$zcfg lacks \"rocjay1/github-settings/*\": ref-pin under unpinned-uses policies"
      elif [[ -n "$cfg" ]]; then
        flag "zizmor-config $cfg does not exist"
      else
        # The built-in config hash-pins everything but this repo's workflows.
        while IFS='|' read -r f ref; do
          case "$ref" in ""|./*|docker://*|"$uses_prefix"*) continue ;; esac
          [[ "${ref##*@}" =~ ^[0-9a-f]{40}$ ]] || flag "$f uses $ref; the built-in zizmor config needs a commit hash pin"
        done <<<"$(sort -u <<<"$all_uses")"
      fi
    fi

    if ! grep -Fxq "$check" <<<"$required"; then
      flag "required checks lack \"$check\"; update apply.sh required_checks"
    fi
    if grep -Fxq "$job" <<<"$required"; then
      flag "required check \"$job\" will be replaced by \"$check\"; update apply.sh required_checks"
    fi
  done <<<"$spec"

  # Any zizmor config in the repo must allow the tag pin once a shared caller exists.
  for zcfg in .github/zizmor.yml .github/zizmor.yaml zizmor.yml zizmor.yaml; do
    if [[ "$zcfg" == .github/zizmor.yml ]] && grep -q "^workflows" <<<"$spec"; then continue; fi  # checked above
    zc=$(fetch "$r" "$zcfg") || continue
    zizmor_allows <<<"$zc" || flag "$zcfg lacks \"rocjay1/github-settings/*\": ref-pin under unpinned-uses policies"
  done

  if [[ -n "$findings" ]]; then issues=$((issues + $(wc -l <<<"$findings"))); fi
  if [[ "$have" == "$want" ]]; then
    echo "$r: $path ok"
  else
    changed=$((changed + 1))
    if [[ -z "$have" ]]; then verb="Add"; echo "$r: create $path (@$tag)"
    else verb="Sync"; echo "$r: update $path (@$tag)"; fi
    if [[ -z "$have" ]]; then
      printf '%s\n' "$want" | sed "s/^/$r:   > /"
    else
      diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") | sed "s/^/$r:   /" || true
    fi
    if $apply; then open_pr "$r" "$want" "$verb"; fi
  fi
  if [[ "$tag" != "$latest" ]]; then echo "$r: note: pinned $tag, latest release is $latest (Dependabot bumps it)"; fi
done

echo
if (( issues > 0 )); then echo "$issues finding(s) to fix by hand; this script only writes $path."; fi
if ! $apply && (( changed > 0 )); then
  echo "Dry run: $changed repo(s) differ. Re-run with --apply to open draft PRs."
fi
