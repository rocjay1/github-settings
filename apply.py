#!/usr/bin/env python3
"""Apply the repo settings baseline to your personal GitHub repos.

Dry run by default; pass --apply to write changes, or --check to exit 1 when anything
differs (scheduled drift check, drift.yml). Assumes GitHub Pro (rulesets enforced on
private repos).
"""

import json

from common import api, current_user, list_repos, parse_args, print_diff, run

# Desired settings (GitHub REST field names for PATCH /repos/{owner}/{repo}).
BASELINE = {
    "allow_merge_commit": False,
    "allow_squash_merge": True,
    "allow_rebase_merge": False,
    "delete_branch_on_merge": True,
    "allow_update_branch": True,
    "allow_auto_merge": False,
    "has_wiki": False,
    "has_projects": False,
}

# Secret scanning + push protection: free on public repos; private repos need GitHub
# Secret Protection (not part of Pro), so they're skipped.
PUBLIC_SECURITY = {"secret_scanning": "enabled", "secret_scanning_push_protection": "enabled"}

# Default-branch ruleset (Pro: enforced on private repos too). Required status checks are
# per repo: taken from REQUIRED_CHECKS below if listed, else kept from the repo's existing
# ruleset, else from classic branch protection (which is then removed in favour of the ruleset).
RULESET_NAME = "default-branch-standards"
ACTIONS_APP_ID = 15368  # GitHub Actions

PULL_REQUEST_PARAMS = {
    "allowed_merge_methods": ["squash"],
    "dismiss_stale_reviews_on_push": False,
    "require_code_owner_review": False,
    "require_last_push_approval": False,
    "required_approving_review_count": 0,
    "required_review_thread_resolution": True,
}

# Required checks for repos that had no protection to inherit them from.
# "secrets / secrets" and "workflows / workflows" come from the shared callers that
# workflows.py manages (it imports required_checks); a repo's shared.yml must be on its
# default branch before these apply.
SHARED_CHECKS = ["secrets / secrets", "workflows / workflows"]
REQUIRED_CHECKS = {
    "mac-config": ["test", "lint", *SHARED_CHECKS],
    "applebridge": ["test", *SHARED_CHECKS],
    "rocjay1.github.io": ["build", *SHARED_CHECKS],
    "copilot-config": ["offline (macos-latest)", "offline (windows-latest)", *SHARED_CHECKS],
    "core-infra": ["terraform / terraform", "docs / docs", *SHARED_CHECKS],
    "simplifi-cli": ["test (3.10)", "test (3.13)", "test (3.14)", "package", *SHARED_CHECKS],
}


def required_checks(repo):
    return list(REQUIRED_CHECKS.get(repo, []))


def show(value):
    """A setting value as jq would interpolate it: strings bare, the rest as JSON."""
    return value if isinstance(value, str) else json.dumps(value)


def want_ruleset(checks):
    rules = [
        {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
        {"type": "pull_request", "parameters": PULL_REQUEST_PARAMS},
    ]
    if checks:
        rules.append({"type": "required_status_checks", "parameters": {
            "do_not_enforce_on_create": False,
            "strict_required_status_checks_policy": True,
            "required_status_checks": [{"context": c, "integration_id": ACTIONS_APP_ID}
                                       for c in checks],
        }})
    return {
        "name": RULESET_NAME, "target": "branch", "enforcement": "active", "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": rules,
    }


def comparable(ruleset):
    """Canonical form for comparing rulesets: core fields, rules sorted by type, checks
    sorted. GitHub fills in defaults for pull_request params we don't set, so only the
    keys PULL_REQUEST_PARAMS sets are kept."""
    def rule(r):
        if r["type"] == "pull_request":
            params = {k: v for k, v in r["parameters"].items() if k in PULL_REQUEST_PARAMS}
            r = {**r, "parameters": params}
        elif r["type"] == "required_status_checks":
            checks = sorted(r["parameters"]["required_status_checks"], key=lambda c: c["context"])
            r = {**r, "parameters": {**r["parameters"], "required_status_checks": checks}}
        return r

    return {
        "enforcement": ruleset.get("enforcement"),
        "target": ruleset.get("target"),
        "conditions": ruleset.get("conditions"),
        "bypass_actors": ruleset.get("bypass_actors"),
        "rules": sorted(map(rule, ruleset["rules"]), key=lambda r: r["type"]),
    }


def ensure_ruleset(owner, repo, default_branch, apply):
    """Report (and with apply, fix) the default-branch ruleset; return the change count."""
    base = f"repos/{owner}/{repo}"
    changes = 0
    ids = [rs["id"] for rs in api(f"{base}/rulesets", fresh=True) if rs["name"] == RULESET_NAME]
    have = api(f"{base}/rulesets/{ids[0]}", fresh=True) if ids else None
    classic = api(f"{base}/branches/{default_branch}/protection", missing_ok=True)

    checks = required_checks(repo)
    if not checks and have:
        checks = [c["context"] for r in have["rules"] if r["type"] == "required_status_checks"
                  for c in r["parameters"]["required_status_checks"]]
    if not checks and classic:
        checks = [c["context"] for c in
                  (classic.get("required_status_checks") or {}).get("checks") or []]

    want = want_ruleset(checks)
    summary = f"(checks: {', '.join(checks) if checks else 'none'})"
    if have is None:
        changes += 1
        print(f"{repo}: create ruleset {RULESET_NAME} {summary}")
        if apply:
            api(f"{base}/rulesets", "POST", want)
    elif comparable(have) != comparable(want):
        changes += 1
        print(f"{repo}: update ruleset {RULESET_NAME} {summary}")
        print_diff(repo, json.dumps(comparable(have), indent=2, sort_keys=True),
                   json.dumps(comparable(want), indent=2, sort_keys=True))
        if apply:
            api(f"{base}/rulesets/{ids[0]}", "PUT", want)
    else:
        print(f"{repo}: ruleset ok")

    if classic:
        changes += 1
        print(f"{repo}: remove classic branch protection on {default_branch} (replaced by ruleset)")
        if apply:
            api(f"{base}/branches/{default_branch}/protection", "DELETE")
    return changes


def main():
    args = parse_args(__doc__)
    owner = current_user()
    changed = 0
    for repo in list_repos(owner):
        base = f"repos/{owner}/{repo}"
        current = api(base, fresh=True)

        # Keep only baseline keys whose current value differs.
        diff = {k: v for k, v in BASELINE.items() if current.get(k) != v}
        if not diff:
            print(f"{repo}: settings ok")
        else:
            changed += 1
            for k, v in diff.items():
                print(f"{repo}: {k} {show(current.get(k))} -> {show(v)}")
            if args.apply:
                api(base, "PATCH", diff)
                print(f"{repo}: applied")

        if current["visibility"] == "public":
            analysis = current.get("security_and_analysis") or {}
            status = {k: (analysis.get(k) or {}).get("status") or "disabled"
                      for k in PUBLIC_SECURITY}
            sec = {k: v for k, v in PUBLIC_SECURITY.items() if status[k] != v}
            if not sec:
                print(f"{repo}: security ok")
            else:
                changed += 1
                for k, v in sec.items():
                    print(f"{repo}: {k} {status[k]} -> {v}")
                if args.apply:
                    api(base, "PATCH", {"security_and_analysis":
                                        {k: {"status": v} for k, v in sec.items()}})
                    print(f"{repo}: applied")

        # Immutable releases: a published release's tag can't be moved or deleted. Only
        # covers releases published after it's enabled. Callers of github-settings' reusable
        # workflows pin to these tags. GitHub answers 404 when it's off.
        immutable = api(f"{base}/immutable-releases", fresh=True, missing_ok=True)
        if immutable and immutable.get("enabled"):
            print(f"{repo}: immutable releases ok")
        else:
            changed += 1
            print(f"{repo}: immutable releases false -> true")
            if args.apply:
                api(f"{base}/immutable-releases", "PUT")
                print(f"{repo}: applied")

        changed += ensure_ruleset(owner, repo, current["default_branch"], args.apply)

    if not args.apply and changed:
        print(f"\nDry run: {changed} change(s) pending. Re-run with --apply to write.")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    run(main)
