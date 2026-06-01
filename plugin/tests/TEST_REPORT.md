# Test Report — claude-code-bedrock-security

**Last run:** 2026-06-01 · **Result: 76 passed / 0 failed (76 total)** · plugin v1.0.0 (pii-guard v2.0.1)

Reproducible — regenerate any time:

```bash
bash tests/run-tests.sh        # → RESULT: 76 passed, 0 failed
```

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

## Coverage by group (76 assertions)

| # | Group | Assertions | What it proves |
|---|---|---:|---|
| 1 | Syntax | 6 | All 5 hooks + chain-verify parse under `bash -n`. |
| 2 | pii-guard / secrets | 15 | **Every** secret & credential pattern fires with the correct label: AWS key/secret, generic API key, private key, JWT, DB string, password, GitHub/Slack token, hex secret, both card types, email, phone, passport. |
| 3 | pii-guard / national IDs | 10 | All 7 jurisdictions, each with the correct label: US SSN+ITIN, UK NINO+NHS, JP My Number, KR RRN, SG NRIC, EU IBAN, AU TFN+Medicare. |
| 4 | pii-guard / false positives | 6 | Plain sentence, decimals/years, version string, short number, **UUID**, sub-8-char text all allowed. |
| 5 | pii-guard / PreToolUse | 4 | Scans `tool_input` (commands + file writes), not just prompts; ignores unrelated events. |
| 6 | git-guard | 16 | All 8 checks (remote allowlist add/rename/rm, force-push ×2, branch protection, reset --hard, clean -fd, checkout --force) plus read-only allows, non-git/non-Bash pass-through, CI-mode relax, emergency disable. |
| 7 | token-budget-guard | 5 | Call-budget breaker (1,2 pass / 3 blocks) **and** token-budget breaker (PostToolUse records usage → PreToolUse blocks; fresh session unaffected). |
| 8 | hook-wrapper | 6 | Full exit matrix: pass→0, block→2, crash→2, timeout→2, missing-hook→2; telemetry line emitted. |
| 9 | audit-logger | 2 | 4 events logged across UserPromptSubmit + PostToolUse; every entry carries `prev_hash` + `hmac`. |
| 10 | chain-verify | 4 | Intact chain → 0; **three tamper modes** (edit, deletion, reorder) each → 1. |
| 11 | JSON validity | 2 | `plugin.json` and `hooks/hooks.json` valid. |

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
