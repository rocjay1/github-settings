#!/usr/bin/env python3
"""Check each repo's callers of the shared workflows in this repo (secret-scan.yml,
workflow-lint.yml) against the per-repo table below, and render the managed caller file.

Reports callers that are missing or not pinned to an exact release tag, zizmor configs
that would reject the tag pin, inline jobs the callers replace, and required checks that
don't match the check names the callers produce (skipped for apply.py DIRECT_PUSH repos,
which require none). Rulesets are never changed here (see apply.py REQUIRED_CHECKS).

Dry run by default; pass --apply to open a draft PR in each repo whose managed file
differs, or --check to exit 1 when any file differs or any finding remains (scheduled
drift check, drift.yml). Further arguments limit the run to those repos:
./workflows.py --apply core-infra
"""

import re
import sys

from apply import DIRECT_PUSH, required_checks
from common import api, current_user, fetch, list_repos, open_pr, parse_args, print_diff, run

PATH = ".github/workflows/shared.yml"
BRANCH = "sync-shared-workflows"
HEADER = ("# Managed by rocjay1/github-settings (workflows.py). "
          "Edit it there; changes here get overwritten.")

# Shared jobs per repo as (job, zizmor-config or None). Job ids are fixed so the checks
# report as "<job> / <job>". A repo with no entry is flagged; an empty list opts it out.
_BOTH = [("secrets", None), ("workflows", None)]
JOBS = {
    "applebridge": _BOTH, "copilot-config": _BOTH, "core-infra": _BOTH,
    "mac-config": _BOTH, "rocjay1.github.io": _BOTH, "simplifi-cli": _BOTH,
    "github-settings": [],  # calls its own workflows by local path (ci.yml)
    "cop-rehearsal": [],    # throwaway repo
}

WORKFLOW_FILE = {"secrets": "secret-scan.yml", "workflows": "workflow-lint.yml"}

# Job-level permissions each shared workflow needs from its caller.
JOB_PERMISSIONS = {
    "secrets": ["contents: read", "pull-requests: read"],
    "workflows": ["contents: read"],
}

# Exact release tags only: vX.Y.Z. Branches, SHAs and floating majors are rejected.
TAG_RE = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
USES_PREFIX = "rocjay1/github-settings/.github/workflows/"
ZIZMOR_CONFIGS = [".github/zizmor.yml", ".github/zizmor.yaml", "zizmor.yml", "zizmor.yaml"]


def render(spec, tag):
    lines = [HEADER, "name: Shared checks", "", "on:", "  pull_request:", "  push:",
             "    branches: [main]", "  schedule:", '    - cron: "23 6 * * 1"', "",
             "permissions: {}", "", "concurrency:", "  group: shared-${{ github.ref }}",
             "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}", "",
             '# Shared checks from rocjay1/github-settings, each reporting as "<job> / <job>".',
             "# Pinned to immutable release tags; Dependabot bumps them.", "jobs:"]
    for i, (job, cfg) in enumerate(spec):
        if i:
            lines.append("")
        lines += [f"  {job}:", "    permissions:",
                  *(f"      {p}" for p in JOB_PERMISSIONS[job]),
                  f"    uses: {USES_PREFIX}{WORKFLOW_FILE[job]}@{tag}"]
        if cfg:
            lines += ["    with:", f"      zizmor-config: {cfg}"]
    return "\n".join(lines) + "\n"


def _value(line):
    """The value of a "key: value" line, without a trailing comment or surrounding quotes."""
    value = re.sub(r"[ \t]+#.*$", "", line.split(":", 1)[1].strip())
    return re.sub(r"""^["']|["']$""", "", value)


def list_jobs(text):
    """Jobs in a workflow file as (id, name, uses), read by indentation (no YAML parser
    here). Assumes block-style YAML with job keys and their properties on their own lines."""
    jobs, job = [], None
    in_jobs, job_indent, prop_indent = False, -1, -1
    for line in text.splitlines():
        if re.match(r"jobs:[ \t]*$", line):
            in_jobs, job_indent = True, -1
            continue
        if in_jobs and re.match(r"[^ \t#]", line):
            in_jobs = False
        if not in_jobs or re.match(r"[ \t]*(#.*)?$", line):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if job_indent < 0:
            job_indent = indent
        if indent == job_indent:
            job = {"id": line[indent:].split(":", 1)[0], "name": "", "uses": ""}
            jobs.append(job)
            prop_indent = -1
            continue
        if prop_indent < 0:
            prop_indent = indent
        if indent == prop_indent and re.match(r" *(name|uses):", line):
            job[line.split(":", 1)[0].strip()] = _value(line)
    return [(j["id"], j["name"], j["uses"]) for j in jobs]


def zizmor_allows(config):
    return re.search(r"""^[^\S\n]+["']rocjay1/github-settings/\*["'][^\S\n]*:[^\S\n]*ref-pin""",
                     config, re.M) is not None


def check_repo(owner, repo, spec, latest, apply):
    """Report one repo's findings and managed-file diff; return (changed, findings)."""
    findings = []

    def flag(message):
        findings.append(message)
        print(f"{repo}: {message}")

    # All jobs across the repo's workflows as (file, id, name, uses); every uses: as
    # (file, ref).
    all_jobs, all_uses, have = [], set(), None
    listing = api(f"repos/{owner}/{repo}/contents/.github/workflows", fresh=True,
                  missing_ok=True) or []
    for entry in listing:
        f = entry["name"]
        if not re.search(r"\.ya?ml$", f):
            continue
        content, _ = fetch(owner, repo, f".github/workflows/{f}")
        if content is None:
            continue
        if f".github/workflows/{f}" == PATH:
            have = content
        all_jobs += [(f, *job) for job in list_jobs(content)]
        for line in content.splitlines():
            m = re.match(r"""\s*(- )?uses:\s*['"]?([^'" ]+)""", line)
            if m:
                all_uses.add((f, m[2]))

    # Keep the tag already pinned in the managed file (Dependabot moves it); else the latest.
    m = re.search(re.escape(USES_PREFIX) + r"[a-z-]+\.yml@(\S+)", have or "")
    tag = m[1] if m and TAG_RE.fullmatch(m[1]) else latest
    want = render(spec, tag)

    # Required contexts: apply.py's list, else the live ruleset's. DIRECT_PUSH repos require
    # none, so their callers' checks aren't compared.
    direct_push = repo in DIRECT_PUSH
    required = required_checks(repo)
    if not required and not direct_push:
        default_branch = api(f"repos/{owner}/{repo}")["default_branch"]
        required = [c["context"] for r in
                    api(f"repos/{owner}/{repo}/rules/branches/{default_branch}", fresh=True)
                    if r["type"] == "required_status_checks"
                    for c in r["parameters"]["required_status_checks"]]

    checked_configs = set()
    for job, cfg in spec:
        wf = WORKFLOW_FILE[job]
        check = f"{job} / {job}"
        # Callers of this shared workflow anywhere in the repo, the managed file included.
        good = 0
        for f, job_id, _, uses in all_jobs:
            if not uses.startswith(f"{USES_PREFIX}{wf}@"):
                continue
            ref = uses.rsplit("@", 1)[1]
            if not TAG_RE.fullmatch(ref):
                flag(f"{f} job {job_id} pins {wf}@{ref}; use an exact release tag (vX.Y.Z)")
            elif job_id != job:
                flag(f"{f} job {job_id} calls {wf}; the job id must be {job}")
            else:
                good += 1
            if f".github/workflows/{f}" != PATH:
                flag(f"{f} job {job_id} also calls {wf}; remove it once {PATH} lands")
        if not good:
            flag(f"no job {job} calls {wf}@vX.Y.Z yet")
        # Inline jobs that produce the same check name or stand in for the shared job.
        for f, job_id, name, uses in all_jobs:
            if uses.startswith(USES_PREFIX) or uses.startswith("./"):
                continue
            if name == check:
                flag(f'{f} inline job {job_id} is named "{check}"; remove it once {PATH} lands')
            elif job_id == job and not uses:
                flag(f"{f} inline job {job_id} duplicates the shared {job} job; "
                     f"remove it once {PATH} lands")

        if job == "workflows":
            zcfg = cfg or ".github/zizmor.yml"
            checked_configs.add(zcfg)
            config, _ = fetch(owner, repo, zcfg)
            if config is not None:
                if not zizmor_allows(config):
                    flag(f'{zcfg} lacks "rocjay1/github-settings/*": ref-pin '
                         "under unpinned-uses policies")
            elif cfg:
                flag(f"zizmor-config {cfg} does not exist")
            else:
                # The built-in config hash-pins everything but this repo's workflows.
                for f, ref in sorted(all_uses):
                    if ref.startswith(("./", "docker://", USES_PREFIX)):
                        continue
                    if not re.fullmatch(r"[0-9a-f]{40}", ref.rsplit("@", 1)[-1]):
                        flag(f"{f} uses {ref}; the built-in zizmor config needs a commit hash pin")

        if not direct_push and check not in required:
            flag(f'required checks lack "{check}"; update apply.py REQUIRED_CHECKS')
        if job in required:
            flag(f'required check "{job}" will be replaced by "{check}"; '
                 "update apply.py REQUIRED_CHECKS")

    # Any zizmor config in the repo must allow the tag pin once a shared caller exists.
    for zcfg in ZIZMOR_CONFIGS:
        if zcfg in checked_configs:
            continue
        config, _ = fetch(owner, repo, zcfg)
        if config is not None and not zizmor_allows(config):
            flag(f'{zcfg} lacks "rocjay1/github-settings/*": ref-pin under unpinned-uses policies')

    changed = have != want
    if not changed:
        print(f"{repo}: {PATH} ok")
    else:
        verb = "Sync" if have else "Add"
        print(f"{repo}: {'update' if have else 'create'} {PATH} (@{tag})")
        print_diff(repo, have, want)
        if apply:
            listed = "\n".join(f"- {f}" for f in findings) or "- none"
            open_pr(owner, repo, PATH, BRANCH, want, draft=True,
                    title=f"{verb} shared workflow callers from github-settings",
                    commit_note="Generated by rocjay1/github-settings workflows.py; edit it there.",
                    body=f"Renders `{PATH}` from the per-repo table in "
                         f"[rocjay1/github-settings](https://github.com/{owner}/github-settings) "
                         "(`workflows.py`). Change the callers there, not here.\n\n"
                         "Findings from the run that opened this PR (fix by hand on this branch):"
                         f"\n\n{listed}\n\n"
                         "🤖 Generated with [Claude Code](https://claude.com/claude-code)")
    if tag != latest:
        print(f"{repo}: note: pinned {tag}, latest release is {latest} (Dependabot bumps it)")
    return changed, findings


def main():
    args = parse_args(__doc__, repos=True)
    owner = current_user()
    latest = api(f"repos/{owner}/github-settings/releases/latest")["tag_name"]
    if not TAG_RE.fullmatch(latest):
        print(f"latest github-settings release {latest} is not vX.Y.Z", file=sys.stderr)
        return 1
    changed = issues = 0
    for repo in list_repos(owner, args.repos):
        spec = JOBS.get(repo)
        if spec is None:
            issues += 1
            print(f"{repo}: no entry in workflows.py; skipped")
            continue
        if not spec:
            print(f"{repo}: opted out")
            continue
        repo_changed, findings = check_repo(owner, repo, spec, latest, args.apply)
        changed += repo_changed
        issues += len(findings)

    print()
    if issues:
        print(f"{issues} finding(s) to fix by hand; this script only writes {PATH}.")
    if not args.apply and changed:
        print(f"Dry run: {changed} repo(s) differ. Re-run with --apply to open draft PRs.")
    return 1 if args.check and changed + issues else 0


if __name__ == "__main__":
    run(main)
