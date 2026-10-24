# github-settings

Baseline settings and shared checks for rocjay1's personal repos, plus notes on the
security tooling each repo runs.

## Scripts

Each script is a dry run by default. Pass `--apply` to write changes, or `--check` to exit 1
when anything differs. The weekly [drift check](.github/workflows/drift.yml) runs all three
with `--check` and never writes.

| Script | What it manages |
|---|---|
| [`apply.py`](apply.py) | Repo settings, the `default-branch-standards` ruleset, immutable releases, and the public-repo security baseline below. |
| [`dependabot.py`](dependabot.py) | Each repo's `.github/dependabot.yml`. Opens a PR per repo with `--apply`. |
| [`workflows.py`](workflows.py) | Each repo's `.github/workflows/shared.yml`, which calls the reusable `secret-scan.yml` and `workflow-lint.yml` workflows (checks `secrets / secrets` and `workflows / workflows`). |
| [`audit.sh`](audit.sh) | Read-only table of every repo's settings. |
| [`hooks/install.sh`](hooks/install.sh) | Installs a `pre-push` hook that blocks direct pushes to `main`. |

## Default-branch ruleset

`apply.py` gives every repo a `default-branch-standards` ruleset on its default branch. It
blocks deletion and force pushes, requires linear history, and requires a pull request
(squash merge only, no approvals, conversations resolved) whose required status checks pass.
The checks are listed per repo in `REQUIRED_CHECKS`.

**Exception: copilot-config** (listed in `DIRECT_PUSH`). Its ruleset has no pull request
rule and no required status checks, so the owner can push straight to `main`. The work
laptop reaches GitHub over SSH on port 443 but can't use `gh`, so it can't open PRs.
Required checks would block a direct push too, because a newly pushed commit has no passing
checks yet. Deletion, force pushes and non-linear history are still blocked, and CI still
runs on every push to `main`, so failures stay visible. A bypass actor wasn't used because
it skips every rule in the ruleset. Don't install the `pre-push` hook in copilot-config.

## Security scanning

Public and private repos are scanned differently. On a public repo, issues and Actions logs
are visible to everyone, so an AI review there would publish its findings before they were
fixed.

### Public repos: GitHub's free tooling

`apply.py` enforces these on every public repo (github-settings, rocjay1.github.io), and
the drift check fails if one is turned off (copilot-config has been private since
2026-10-24):

- Secret scanning and push protection.
- CodeQL code scanning with the default setup. Languages are detected automatically; the
  `actions` language covers workflows at minimum.
- Private vulnerability reporting.

Findings and reports from all three stay private to the repo owner.

### Private repos: monthly AI security review

Each private repo runs a [GitHub Agentic Workflows](https://github.github.io/gh-aw/) (gh-aw)
review on the Copilot engine. A read-only agent reads the in-scope code and files one issue
per finding, titled `[security-review] …` (at most 5 per run). If it finds nothing it records
a noop, and every output ends with a **Coverage** section listing what it read. The prompt
asks for findings with a concrete exploit path only, not style or best-practice nits.

| Repo | Workflow | Paths | Schedule (UTC) |
|---|---|---|---|
| core-infra | `security-review` | whole repo | 1st, 09:17 |
| simplifi-cli | `security-review-client` | `simplifi/client/` and the core modules (`auth.py`, `_http.py`, `_util.py`, `models.py`, `errors.py`, `exporters.py`, `__init__.py`) | 8th, 09:17 |
| simplifi-cli | `security-review-cli` | `simplifi/cli/`, `bin/`, `tools/`, `.github/`, `pyproject.toml`, root dotfiles | 8th, 10:17 |
| applebridge | `security-review-server` | `Sources/AppleBridge/`, `Sources/Backends/`, `shortcuts/src/`, `Package.swift`, `Info.plist` | 15th, 09:17 |
| applebridge | `security-review-tools` | `Sources/Tools/`, `scripts/`, `.github/`, root dotfiles | 15th, 10:17 |
| mac-config | `security-review` | whole repo | 22nd, 09:17 |

Every review excludes tests, prose docs (`README*`, `CHANGELOG*`, `LICENSE*`, `docs/`),
generated files and lock files. simplifi-cli and applebridge are split into two runs because
a single run over about 215 KB read only part of the code.

**This repo doesn't manage these files.** Each private repo has its own copy, which
`workflows.py` and the drift check don't sync or check:

- `.github/workflows/security-review*.md`: the prompt and frontmatter (schedule, engine,
  outputs). This is the file you edit.
- `.github/workflows/security-review*.lock.yml`: the compiled workflow. Never edit it by hand.
- `.github/aw/actions-lock.json` and `.gitattributes`: written by `gh aw compile`.
- Lint ignores for the lock files in `.github/zizmor.yml` (`secrets-outside-env`) and
  `.github/actionlint.yaml` (`concurrency.queue`, which the shared actionlint 1.7.12 doesn't
  know yet). Without them, the shared `workflows / workflows` check fails.

A run costs about 17–30 AI credits (AIC), roughly $0.17–0.30, plus 4–10 Actions minutes.
All six runs together come to about 137 AIC, roughly $1.40, a month.

#### The Copilot token

The Copilot engine needs a `COPILOT_GITHUB_TOKEN` secret in every private repo that runs a
review. On a personal account it has to be a fine-grained PAT. The secret-free
`copilot-requests` option needs an org with central Copilot billing.

- **Permissions:** Account permissions → Copilot Requests: Read. Set repository access to
  public repositories only, read-only, with nothing else; the token needs no repo access.
- **Billing:** runs draw on the PAT owner's Copilot plan (Copilot Pro).

To rotate it, create a new token at
<https://github.com/settings/personal-access-tokens/new>, then set it in each repo. Each
command prompts for the value, so the token stays out of your shell history:

```bash
gh secret set COPILOT_GITHUB_TOKEN -R rocjay1/core-infra
gh secret set COPILOT_GITHUB_TOKEN -R rocjay1/simplifi-cli
gh secret set COPILOT_GITHUB_TOKEN -R rocjay1/applebridge
gh secret set COPILOT_GITHUB_TOKEN -R rocjay1/mac-config
```

If the token expires, every review fails until the secret is replaced.

#### Changing the prompt

The six copies are identical except for the frontmatter `description` and `schedule`. The
four split workflows also differ in the paragraph that names their paths and the
`git ls-files -- …` command. To change the shared wording:

1. Install the extension once: `gh extension install github/gh-aw`.
2. In each repo, edit every `security-review*.md` the same way, then recompile:

   ```bash
   gh aw compile --zizmor --actionlint
   ```

3. Commit the `.md` and `.lock.yml` together and open a PR. `gh aw compile --models` and
   `gh aw audit` write logs under `.github/aw/logs/`, so don't commit those.
4. After merging, run the review once and read its Coverage section:

   ```bash
   gh workflow run security-review.lock.yml -R rocjay1/core-infra
   ```

   Replace the file name with `security-review-<half>.lock.yml` for a split repo.
   `gh aw audit <run-id>`, run in the local checkout, downloads the agent's output and session.

The friendly `schedule:` format has no monthly option, so use a plain cron string.

To add a repo, copy `security-review.md` from one that has it, choose an unused day of the
month, add both lint ignores, compile, and set the token secret.

#### Known limits

- **Coverage depends on the model.** The default model (`auto`, currently
  claude-sonnet-5.5) sometimes greps files instead of reading them and still records a
  noop, even though the prompt says to use `report_incomplete` when it doesn't read
  everything. Check the Coverage section rather than trusting a noop. applebridge's server
  half still only greps the 5 shortcut plists and `Models.swift`, `Protocols.swift` and
  `NotesModels.swift`.
- **Opus isn't available.** Copilot Pro rejects `claude-opus-5.5` with
  `model_not_supported_error`, even though `gh aw models` lists it and
  `gh aw compile --models` doesn't warn.
- **Line numbers in issues can be wrong.** In testing, the agent cited lines past the end of
  short files. The file and the description were right.
- **An incomplete result counts as a failed run.** When the agent calls `report_incomplete`,
  or the engine fails, gh-aw marks the run failed and opens an `[aw] …` issue in that repo.
  These are about the workflow, not about a vulnerability.
- **gh-aw is a technical preview.** It was at v0.92.0 when this was set up. Recompile after
  upgrading the extension (`gh extension upgrade gh-aw`).
