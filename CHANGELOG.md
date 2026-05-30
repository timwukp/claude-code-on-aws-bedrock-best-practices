# Changelog

This CHANGELOG documents notable changes to the kit. For full commit history
see [git log](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/commits/main).

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
