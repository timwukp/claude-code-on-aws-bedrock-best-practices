# Test Report — fail-closed-security-hooks

**Last run:** 2026-08-13 · **Result: 108 passed / 0 failed (108 total)** · plugin v1.1.0 (pii-guard v2.0.1, git-guard v1.1.0, gh-guard v1.1.0, mcp-repo-guard v1.0.0)

Run on Amazon Linux 2023 (bash 5.2.15, jq 1.8.1) as well as macOS — see
[`docs/test-evidence.md`](../../docs/test-evidence.md) §7b for why the Linux run
is not optional.

The hooks under `plugin/hooks/` that are meant to be byte-identical to their
`hooks/` originals (`git-guard.sh`, `gh-guard.sh`, `mcp-repo-guard.sh`) are now
asserted identical by `tests/test_git_guard.sh` and `tests/test_gh_guard.sh` in
the repository root suite. A copy left a version behind is invisible to the
suites in this directory, which is how it happened once
([`docs/test-evidence.md`](../../docs/test-evidence.md) §7c).

Reproducible — regenerate any time:

```bash
bash tests/run-tests.sh        # → RESULT: 108 passed, 0 failed
```

## Official validation (pre-submission)

Before submitting to the Claude Code community marketplace, the plugin was
checked with Anthropic's own tooling (the review pipeline runs the same
`claude plugin validate`). Verified on Claude Code v2.1.159:

| Check | Command | Result |
|---|---|---|
| Manifest validation | `claude plugin validate plugin/` | ✔ Validation passed (exit 0) |
| Strict validation (review-pipeline level) | `claude plugin validate --strict plugin/` | ✔ Validation passed (exit 0) |
| Real plugin load | `claude --plugin-dir plugin/ -p …` | Loaded, `hooks.json` parsed, no plugin load error |
| Functional suite | `bash plugin/tests/run-tests.sh` | 108 passed / 0 failed |

`--strict` treats warnings (unrecognized fields, missing metadata) as errors, so
a clean strict pass means the manifest meets the bar the automated review applies.

## Method

- **Isolation.** Each run uses a throwaway `HOME` (`mktemp -d`); audit log, dev
  HMAC key, telemetry, and budget state write to a sandbox and are deleted after.
  Never touches a real `~/.claude`.
- **Two assertion styles.**
  - `assert_exit <code>` — drives a hook with one JSON stdin event, checks the
    exit code (`0` allow / `2` block, per the hook contract).
  - `assert_label <label>` — for pii-guard, additionally asserts the **correct
    pattern name** appears in stderr (not just that *something* blocked). This is
    stricter than exit-code-only and is what caught the UUID bug (see below).
- **No network / no root.** CloudWatch & SIEM dual-write are off by default and
  not exercised here.
- **Dependencies.** `bash`, `jq`, `openssl`. JSON checks skip if `jq` absent.

## Coverage by group (108 assertions)

| # | Group | Assertions | What it proves |
|---|---|---:|---|
| 1 | Syntax | 6 | All hooks + chain-verify parse under `bash -n`. |
| 2 | pii-guard / secrets | 15 | **Every** secret & credential pattern fires with the correct label: AWS key/secret, generic API key, private key, JWT, DB string, password, GitHub/Slack token, hex secret, both card types, email, phone, passport. |
| 3 | pii-guard / national IDs | 10 | All 7 jurisdictions, each with the correct label: US SSN+ITIN, UK NINO+NHS, JP My Number, KR RRN, SG NRIC, EU IBAN, AU TFN+Medicare. |
| 4 | pii-guard / false positives | 6 | Plain sentence, decimals/years, version string, short number, **UUID**, sub-8-char text all allowed. |
| 5 | pii-guard / PreToolUse | 4 | Scans `tool_input` (commands + file writes), not just prompts; ignores unrelated events. |
| 6 | git-guard | 16 | All 8 checks (remote allowlist add/rename/rm, force-push ×2, branch protection, reset --hard, clean -fd, checkout --force) plus read-only allows, non-git/non-Bash pass-through, CI-mode relax, emergency disable. |
| 7 | token-budget-guard | 5 | Call-budget breaker (1,2 pass / 3 blocks) **and** token-budget breaker (PostToolUse records usage → PreToolUse blocks; fresh session unaffected). |
| 8 | hook-wrapper | 6 | Full exit matrix: pass→0, block→2, crash→2, timeout→2, missing-hook→2; telemetry line emitted. |
| 9 | audit-logger | 2 | 4 events logged across UserPromptSubmit + PostToolUse; every entry carries `prev_hash` + `hmac`. |
| 10 | chain-verify | 4 | Intact chain → 0; **three tamper modes** (edit, deletion, reorder) each → 1. |
| 11 | gh-guard | 15 | The write path that never runs `git`: `gh pr merge`, contents PUT with no `branch` field and to `main`, `git/refs` force-update, `repo delete`, `secret set`, verb hidden after `&&` and inside `bash -c`, plus allows for `gh pr create`, feature-branch writes, GETs, an `echo` that merely names a blocked verb, a non-Bash tool, and the emergency disable. |
| 12 | mcp-repo-guard | 15 | The write path no `Bash` matcher sees: `push_files` with no branch and to `main`, `refs/heads/main` spelling, `merge_pull_request`, a different `mcp__<server>__` segment, `create_repository`, protected-branch deletion, owner outside the allowlist, plus allows for `create_branch`, feature-branch writes, `create_pull_request`, reads, a non-repo server's `delete_file`, a `Bash` call, and the emergency disable. |
| 13 | JSON validity | 2 | `plugin.json` and `hooks/hooks.json` valid — including the second `mcp__.*` matcher entry. |

## Bug found & fixed by this suite (v2.0.0 → v2.0.1)

- **Symptom.** The new false-positive test `uuid not card/mynumber` failed: a
  standard UUID (`12345678-1234-1234-1234-123456789012`) was **blocked**.
- **Root cause.** A UUID's `8-4-4-4-12` shape contains the substring
  `5678-1234-1234-1234` (matches credit-card `4-4-4-4`) and `1234-1234-1234`
  (matches My Number `4-4-4`). The boundary checks allowed `-` on either side,
  so hyphen-separated UUID groups slipped through.
- **Fix.** `CREDIT_CARD_16`, `CREDIT_CARD_AMEX`, and `JP_MYNUMBER` boundaries now
  exclude `-` (`[^0-9-]`), so a digit group fenced by hyphens inside a UUID no
  longer false-matches. Genuine cards/My Numbers (space- or hyphen-grouped at a
  word boundary) still match — verified by groups 2 and 3.
- **Lesson.** Exit-code-only testing missed this for two prior rounds; asserting
  the *specific* label and adding a UUID case surfaced it. Hence the stricter
  `assert_label` style.

## Known scope limits (honest notes)

- **Format-only PII matching.** Patterns validate digit count / grouping, not
  government check-digit algorithms (several are not officially published — see
  README "Scope honesty"). Group 4 bounds the over-match risk.
- **Overlapping matches expected.** Some inputs trip multiple patterns; this does
  not change the block decision, only enriches the reported label list.
- **CloudWatch / SIEM dual-write not exercised** (require AWS; off by default).
- **Source-link currency not asserted.** The README's official-source URLs are
  not network-checked here; verify in a browser before audit reliance.
- **Repo-write policy is keyed on known verbs.** `gh-guard` and `mcp-repo-guard`
  enforce policy on recognised subcommands, endpoint shapes and MCP tool names.
  An unrecognised write verb from a new MCP server is denied only when its
  `owner`/`repo` fields are present or its server name matches
  `MCP_GUARD_REPO_SERVER_PATTERN`; and no `PreToolUse` hook can see a write made
  inside a subprocess it never inspects (a Python script using `requests`, a
  compiled binary). Groups 11–12 bound the policy, not the universe of paths.
