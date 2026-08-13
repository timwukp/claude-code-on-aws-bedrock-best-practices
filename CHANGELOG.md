# Changelog

This CHANGELOG documents notable changes to the kit. For full commit history
see [git log](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/commits/main).

## 2026-08-13 — `git-guard.sh` v1.1.0 + `gh-guard.sh` v1.1.0: a newline is not a command boundary

Both Bash guards mis-handled a command that spans lines, in opposite directions.
Neither bug needed an adversary: agents write multi-step commands and write files
with heredocs, so both fired on ordinary work.

### Fixed

- **`gh-guard.sh` false positive → `hooks/gh-guard.sh` v1.1.0.** Segment
  splitting treated every newline as a separator, so each line of a heredoc body
  arrived as its own command segment: `cat > policy.md <<'EOF' … EOF` whose prose
  mentioned `gh pr merge` was denied as an attempt to merge a pull request. In a
  docs-heavy repository the guard was densest where it was least wanted, which is
  how a guard ends up switched off. Bodies are now separated from command text
  before any check runs — except a body a shell consumes (`bash <<EOF`,
  `cat <<EOF | bash`), which is a script and is still scanned.
- **`git-guard.sh` fail-open → `hooks/git-guard.sh` v1.1.0.** The push checks
  extracted the remote and branch with `echo "$norm" | awk '{print $1}'`, which
  reads a field *per line*. On a two-line command the branch name became
  `"/repo\nmain"` and matched no protected pattern:

  ```bash
  cd /repo && git push origin main   # blocked
  cd /repo
  git push origin main               # allowed, before this release
  ```

  Extraction is now scoped to the segment that holds the push. The destructive
  checks (`reset --hard`, `clean -f`) were never affected — they are pure regexes
  with no field parsing — so verb coverage in the suite said nothing about
  argument coverage.
- **`git-guard.sh`, three smaller holes found while writing the suite:**
  `git push origin refs/heads/main` was not recognised as a push to `main`;
  `-f` as the final word of a command was not read as a force push; and an `-f`
  belonging to a *different* command in the same line (`git push origin feat &&
  rm -f /tmp/x`) was. Also removes a `grep: warning: stray \ before -` that
  v1.0.0 emitted onto the hook's stderr, where the agent reads block reasons.
- **Heredoc lookalikes.** `<<` is also a left shift. Mistaking
  `echo $((1<<SHIFT))` for an opener starts a phantom body that swallows every
  following line — a silent, unbounded bypass — so a delimiter must be a whole
  shell word starting like an identifier, and `<<<` is excluded.

### Added

- **[`tests/test_git_guard.sh`](tests/test_git_guard.sh)** — 83 assertions, the
  first suite this hook has had; registered as step 10 in `tests/run_all.sh`.
  Both bugs above existed because it did not. Its pairs assert that the same
  operation written on one line and across two reaches the same verdict.
- **Plugin copy parity assertions** in both guard suites. `plugin/hooks/` ships
  its own copies of these hooks; `plugin/hooks/gh-guard.sh` sat a version behind
  during this work while every suite reported green, because nothing compared
  them. (`audit-logger.sh`, `hook-wrapper.sh`, `pii-guard.sh` and
  `token-budget-guard.sh` differ between the trees by design and are excluded.)

### Verification

Ephemeral t3.micro, Amazon Linux 2023.12, bash 5.2.15(1), jq 1.8.1, over SSM.
Every case was run against an unmodified v1.0.0 `git archive` **and** the patched
tree on the same host with the same file, so each verdict change is attributable:
[`docs/test-evidence.md`](docs/test-evidence.md) §7c. Results:
`test_git_guard.sh` 83/83, `test_gh_guard.sh` 92/92, `test_mcp_repo_guard.sh`
43/43, `bypass-attempts.sh` 60/60, `plugin/tests/run-tests.sh` 108/108. The
pre-existing `test_audit_chain.sh` Linux failure in `audit-logger.sh` is
unchanged and reproduces identically on an unmodified checkout.

The port also reintroduced the `local s="$1" n=${#s}` fail-open documented in
[`hook-hardening-lessons.md`](docs/hook-hardening-lessons.md) §9(a) — under
`set -u` on bash 5.2 the helper aborts, its caller reads an empty string and
concludes that nothing runs a shell. Four BLOCK assertions caught it on Linux;
macOS bash 3.2 passes the same code. Lesson §10 is new and covers this class.

### Known, still open

`git-guard.sh` does not see `bash -c "git push origin main"`, and does not
inspect a bare `git push` with no refspec — [`docs/known-issues.md`](docs/known-issues.md)
Issue 14, with workarounds and the reason both are scoped out. `gh-guard.sh` is
not affected by the wrapper case.

---

## 2026-08-13 — Close the two uncovered write paths: `gh-guard.sh` + `mcp-repo-guard.sh`

PR #13 documented that every hook in this kit fired on the `Bash` matcher and
inspected `git` subcommands only, which left two ways for an agent to write to
the same remote unguarded ([`docs/known-issues.md`](docs/known-issues.md)
Issue 13). This release ships the guards instead of describing them.

### New hooks

- **[`hooks/gh-guard.sh`](hooks/gh-guard.sh)** (`Bash` matcher) — `gh pr merge`,
  `gh api` writes to `contents/`, `git/refs`, branch protection, collaborators
  and Actions secrets, `gh repo delete|sync|archive|rename|transfer`,
  `gh release delete`, `gh secret|variable|alias set`, plus `curl`/`wget`
  straight to `api.github.com` or a GitHub Enterprise `/api/v3/` host. One
  shared endpoint-policy function serves both the `gh api` and the raw-HTTP
  path so the two cannot drift apart.
- **[`hooks/mcp-repo-guard.sh`](hooks/mcp-repo-guard.sh)** (`mcp__.*` matcher) —
  `push_files`, `create_or_update_file`, `delete_file`, `merge_pull_request`,
  `delete_branch`, `update_ref`, release/repo deletion, repo transfer, secret
  writes. Policy keys on the tool-name *suffix*, because the `mcp__<server>__`
  segment differs per machine.

Both leave the sanctioned flow intact — create a feature branch, commit to it,
open a pull request — and deny only the steps a human should own. An absent
`branch` field is treated as a protected-branch write (the GitHub API commits to
the default branch), and a request body the hook cannot read
(`--input file`, `curl -d @body.json`) is denied rather than guessed at.
Content scanning is *not* duplicated: `pii-guard.sh` already scans `tool_input`
for every tool, MCP calls included.

### Verification

Tested on an ephemeral Amazon Linux 2023 EC2 instance (bash 5.2.15, jq 1.8.1,
x86_64) over SSM, not on a developer laptop:

| Suite | Result |
|---|---|
| `tests/test_gh_guard.sh` | 77 assertions, 0 failed |
| `tests/test_mcp_repo_guard.sh` | 43 assertions, 0 failed |
| `tests/bypass-attempts.sh` | 60/60 blocked as expected (7 categories; 28 new `gh`/`mcp` rows) |
| `plugin/tests/run-tests.sh` | 108 assertions, 0 failed |
| Latency | 39–51 ms per call, well inside the <200 ms p95 hook budget |

Two defects appeared **only** on Linux, both causing a silent fail-*open* while
every ALLOW assertion still passed: `local s="$1" n=${#s}` aborts under `set -u`
on bash 5.2 (bash expands all of `local`'s arguments before assigning any), and
a `*gh*` prefilter never matches `github` — the letters are g-i-t-h-u-b. Written
up as [`docs/hook-hardening-lessons.md`](docs/hook-hardening-lessons.md) §9,
with regression tests for both.

### Documentation

- Defense-in-depth table: **7 layers → 9** (both READMEs); the "coverage caveat"
  admonition is replaced by what is now covered plus the residual limits (an
  unknown MCP write verb, writes from a subprocess the hook never inspects, and
  the `*_DISABLED` escape hatches that `allowManagedHooksOnly` should neutralise)
- `docs/known-issues.md` Issue 13: "Workaround" → "Fix (shipped in this kit)",
  status **Closed**, with the three implementation traps the tests pin down
- `docs/hook-hardening-lessons.md`: §1/§2 now point at the reference
  implementations; new §9 on platform-specific fail-open bugs; the §8 prefilter
  example corrected (it contained the `*gh*` bug this release found)
- New "What Gets Blocked" table covering the `gh`/REST/MCP paths, including the
  allowed rows, in both READMEs
- Plugin: hooks registered in `plugin/hooks/hooks.json` (including the second
  `mcp__.*` entry), and `terraform/ec2-baseline/ssm-deploy.yaml.tpl` installs
  both new hooks

### Known unrelated failure

`tests/test_audit_chain.sh` fails one case on Linux — "fail-closed when no log
destination (expected 2 got 0)" in `audit-logger.sh`, a file this change does
not touch. Reproduced from a pristine checkout of `892000b` on the same
instance, so it is pre-existing and left for a separate fix.

## 2026-05-30 — README refresh (commit `f74a160`)

**Direct push to main** (no PR — see
[PR #3](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/pulls)
for the retroactive record).

### What changed

Both `README.md` and `README.zh-TW.md` were brought into sync with the actual
repo contents on main. Earlier README versions only described the original
ops-layer starter kit and were missing several major additions that had
landed since:

- **Hooks** (now 6 documented): added `hook-wrapper.sh`, `token-budget-guard.sh`
- **Scripts** (now 6 documented): added `chain-verify.sh`, `drift-watcher.sh`,
  `sudoers-claude-code`
- **Terraform**: `ec2-baseline/` + `managed-settings-ssm/` modules
- **Observability**: `cloudwatch-dashboard.tf` with dashboard + 4 alarms
- **Docs** (now 21): added `bedrock-guardrails-test-evidence.md`,
  `hook-contract.md`, `platform-compensations.md`, `runbooks/on-call.md`,
  `test-evidence.md`
- **Tests**: full 7-suite harness with 75+ assertions, plus
  `tests/aws-guardrails/` for live AWS verification

### New README sections

- **"What's Inside"** — high-level inventory of the operational kit
- **"Test Suite & Reproducible Evidence"** — `bash tests/run_all.sh` output
  with documented bug-finds (5 PII regex defects, 1 wrapper bypass, 1 silent
  audit-loss bug) all surfaced and fixed by the harness
- **"Bedrock Guardrails (server-side, live-verified)"** — per-policy status
  table including the corrections from PR #2 live verification
- **"Infrastructure as Code"** — Terraform modules
- **Repository Structure** — completely rewritten to match actual main

### Defense-in-Depth table

Updated from 5 layers to **7 layers**:
- Layer 5 added: `token-budget-guard.sh` (agent-loop circuit breaker)
- Layer 7 added: Bedrock Guardrails (server-side, from PR #2)
- Telemetry shim and drift watcher documented as cross-cutting controls
  under the table

### Quick Start updated

- Mentions Terraform module as the production path
- Adds installation of `inotify-tools` + `openssl` (drift watcher + HMAC chain)
- Hardened wrapper deploy (0750 root:claude-users + sudoers)
- HMAC-chain audit log directory + state dir
- Real-time drift watcher
- 9th step: `bash tests/run_all.sh`

### Tested On table

Added macOS, AWS CLI versions per platform, boto3/botocore, inference
profiles, Terraform.

### Verification

- All 36 internal links validated against main using a Python lint script
- Both languages stay structurally aligned for parallel review
- 463 lines (English) / 455 lines (Chinese)

---

## 2026-05-29 — Bedrock Guardrails integration (PR #2)

Merged 2026-05-30. See
[PR #2](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/pull/2)
for full details.

### Highlights

- New `docs/bedrock-guardrails.md` integration guide (524 lines)
- New `docs/bedrock-guardrails-test-evidence.md` with live AWS verification
- New `tests/aws-guardrails/` reproducible test suite (10 scripts)
- Three corrections from live testing:
  1. **Prompt Attack filter works today** via `contentPolicyConfig` filter
     type — contradicts earlier draft and likely makes #63637 stale
  2. **`InvocationsBlocked` metric does not exist** — use
     `InvocationsIntervened` instead
  3. **Streaming intervention does NOT raise an error** — returns
     `BLOCKED_INPUT_BY_GUARDRAIL` text as a normal stream delta
- Verified on macOS, Linux EC2 (Amazon Linux 2023), Windows EC2 (Server 2022)
- Total spend: ~$0.35 USD

---

## 2026-05-29 — Comprehensive audit fixes (PR #1)

Merged 2026-05-29. See
[PR #1](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/pull/1)
for full details.

### Highlights

- Replaced deprecated `npm install` with official installer methods
- Fixed Windows managed settings path to `C:\Program Files\ClaudeCode\`
  (v2.1.75 breaking change)
- Added model alias env vars and version-gated feature documentation
- 18 audit findings addressed across 9 files

---

## Initial release — ops-layer starter kit

First public release with:
- 4 hooks: `audit-logger.sh`, `git-guard.sh`, `pii-guard.sh`, `pii-guard.ps1`
- Wrapper scripts (Linux/macOS + Windows) with bypass-flag rejection
- 17 docs covering threat model, deployment, operations, incident response
- Apache 2.0 license
