"""Shared helpers for apply.py, dependabot.py and workflows.py: gh API calls, repo
listing, the dry-run/--apply/--check flags, diff output, and the branch + PR flow that
dependabot.py and workflows.py use to write their managed files.

Standard library only; every GitHub call goes through the gh CLI, so it uses gh's auth.
"""

import argparse
import base64
import difflib
import json
import subprocess
import sys


class GhError(Exception):
    def __init__(self, args, stderr):
        super().__init__(f"gh {' '.join(args)}: {stderr}")
        self.stderr = stderr


def gh(*args, input=None):
    """Run gh and return its stdout; raise GhError when it fails."""
    proc = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    if proc.returncode:
        raise GhError(args, proc.stderr.strip())
    return proc.stdout


def api(path, method="GET", body=None, fresh=False, missing_ok=False):
    """Call the REST API and return the parsed JSON (None for an empty response).
    fresh bypasses GitHub's response cache; missing_ok returns None on a 404 instead of
    raising, so other failures are never mistaken for "not there"."""
    args = ["api", "-X", method, path]
    if fresh:
        args += ["-H", "Cache-Control: no-cache"]
    if body is not None:
        args += ["--input", "-"]
    try:
        out = gh(*args, input=None if body is None else json.dumps(body))
    except GhError as e:
        if missing_ok and "(HTTP 404)" in e.stderr:
            return None
        raise
    return json.loads(out) if out.strip() else None


def fetch(owner, repo, path, ref=None):
    """A file's text and blob sha, or (None, None) when it doesn't exist."""
    query = f"?ref={ref}" if ref else ""
    data = api(f"repos/{owner}/{repo}/contents/{path}{query}", fresh=True, missing_ok=True)
    if data is None:
        return None, None
    return base64.b64decode(data["content"]).decode(), data["sha"]


def parse_args(doc, repos=False):
    parser = argparse.ArgumentParser(
        description=doc, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write changes")
    mode.add_argument("--check", action="store_true",
                      help="exit 1 when anything differs (drift.yml)")
    if repos:
        parser.add_argument("repos", nargs="*", help="limit the run to these repos")
    return parser.parse_args()


def current_user():
    return api("user")["login"]


def list_repos(owner, only=()):
    """Non-archived, non-fork repos of owner, optionally limited to the names in only."""
    out = gh("repo", "list", owner, "--limit", "500", "--no-archived", "--source",
             "--json", "name")
    return [r["name"] for r in json.loads(out) if not only or r["name"] in only]


def print_diff(repo, have, want):
    """Print want with "> " markers when have is empty, else a unified diff."""
    if not have:
        for line in want.splitlines():
            print(f"{repo}:   > {line}")
        return
    for line in difflib.unified_diff(have.splitlines(), want.splitlines(),
                                     "current", "wanted", lineterm=""):
        print(f"{repo}:   {line}")


def open_pr(owner, repo, path, branch, content, title, commit_note, body, draft=False):
    """Put content at path on branch and open a PR if none is open. With a PR open, commit
    on top of its branch (resetting it would empty the PR and GitHub would close it);
    otherwise start the branch afresh from the default branch head."""
    base = f"repos/{owner}/{repo}"
    default_branch = api(base)["default_branch"]
    prs = api(f"{base}/pulls?state=open&head={owner}:{branch}")
    pr = prs[0]["html_url"] if prs else None
    if not pr:
        head = api(f"{base}/git/ref/heads/{default_branch}")["object"]["sha"]
        if api(f"{base}/git/ref/heads/{branch}", missing_ok=True):
            api(f"{base}/git/refs/heads/{branch}", "PATCH", {"sha": head, "force": True})
        else:
            api(f"{base}/git/refs", "POST", {"ref": f"refs/heads/{branch}", "sha": head})
    on_branch, file_sha = fetch(owner, repo, path, ref=branch)
    if pr and on_branch == content:
        print(f"{repo}: {pr} already up to date")
        return

    put = {
        "message": f"{title}\n\n{commit_note}\n\n"
                   "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>",
        "branch": branch,
        "content": base64.b64encode(content.encode()).decode(),
    }
    if file_sha:
        put["sha"] = file_sha
    api(f"{base}/contents/{path}", "PUT", put)

    if pr:
        print(f"{repo}: updated {pr}")
        return
    pr = api(f"{base}/pulls", "POST", {"title": title, "head": branch, "base": default_branch,
                                       "body": body, "draft": draft})["html_url"]
    print(f"{repo}: opened {'draft ' if draft else ''}{pr}")


def run(main):
    """Exit with main()'s status; report a failed gh call without a traceback."""
    try:
        sys.exit(main())
    except GhError as e:
        print(e, file=sys.stderr)
        sys.exit(1)
