#!/usr/bin/env bash
# Read-only audit of repo settings across your personal GitHub repos.
set -euo pipefail
owner=$(gh api user --jq .login)
printf "repo\tvis\tdefault\tmerge(c/s/r)\tdel_branch\tauto_merge\tupdate_branch\tissues\twiki\tprojects\tsecret_scan\tpush_prot\tdependabot_sec\tvuln_alerts\tprotection\trulesets\n"
for r in $(gh repo list "$owner" --limit 500 --no-archived --source --json name --jq '.[].name'); do
  j=$(gh api -H "Cache-Control: no-cache" "repos/$owner/$r")
  base=$(jq -r '[.name,.visibility,.default_branch,
    "\(.allow_merge_commit|tostring|.[0:1])/\(.allow_squash_merge|tostring|.[0:1])/\(.allow_rebase_merge|tostring|.[0:1])",
    .delete_branch_on_merge,.allow_auto_merge,.allow_update_branch,.has_issues,.has_wiki,.has_projects,
    (.security_and_analysis.secret_scanning.status // "-"),
    (.security_and_analysis.secret_scanning_push_protection.status // "-"),
    (.security_and_analysis.dependabot_security_updates.status // "-")] | @tsv' <<<"$j")
  vuln=$(gh api "repos/$owner/$r/vulnerability-alerts" --silent 2>/dev/null && echo on || echo off)
  def=$(jq -r .default_branch <<<"$j")
  prot=$(gh api "repos/$owner/$r/branches/$def/protection" --silent 2>/dev/null && echo yes || echo no)
  rs=$(gh api "repos/$owner/$r/rulesets" --jq 'map(.name)|join(",")' 2>/dev/null || echo "?")
  printf "%s\t%s\t%s\t%s\t%s\n" "$base" "$vuln" "$prot" "${rs:--}"
done
