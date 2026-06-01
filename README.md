# Secure Claude Code on AWS Bedrock — Enterprise Deployment Kit

> Production-tested security configurations, hooks, IaC modules, observability,
> and reproducible verification for deploying [Claude Code](https://code.claude.com)
> on [Amazon Bedrock](https://aws.amazon.com/bedrock/) in regulated enterprise
> environments (banking, healthcare, government).

[繁體中文版](README.zh-TW.md)

---

## Contents

- [Why This Kit Exists](#why-this-kit-exists)
- [What's Inside](#whats-inside)
- [Defense-in-Depth Architecture](#defense-in-depth-architecture)
- [Settings Hierarchy](#settings-hierarchy)
- [Quick Start (5 minutes)](#quick-start-linuxmacos-5-minutes)
- [What Gets Blocked](#what-gets-blocked)
- [Platform Differences](#platform-differences)
- [Test Suite & Reproducible Evidence](#test-suite--reproducible-evidence)
- [Documentation Index](#documentation-index)
- [Repository Structure](#repository-structure)
- [Tested On](#tested-on)
- [License & Contributing](#license--contributing)

---

## Why This Kit Exists

Claude Code is powerful, but out of the box it can:
- Read your `.env` files, AWS credentials, and SSH keys
- Push code to any git remote
- Run `curl` / `wget` to exfiltrate data to external servers
- Execute destructive commands (`rm -rf`, `git reset --hard`)
- Be tricked into bypassing permission controls
- Run runaway agent loops that burn through Bedrock token budget

In a regulated environment, this is unacceptable. This kit provides **tested
controls** — with reproducible evidence — that lock down Claude Code without
breaking developer productivity.

## What's Inside

This kit is more than configuration files. It's a complete operational kit:

| Layer | What you get |
|---|---|
| **Hardened hooks** | 6 production hooks — PII guard, git guard, audit logger (HMAC-chained), token budget circuit breaker, hook telemetry shim, PowerShell PII guard for Windows |
| **Wrappers** | Bypass-flag rejection, sudoers-based privilege isolation, audit-log rotation |
| **Real-time drift detection** | inotify/fswatch watcher with sub-100ms detection, configurable per-host watchlist |
| **Infrastructure as Code** | Terraform modules for EC2 baseline (IAM + SSM + CloudWatch) and SSM Parameter Store-backed MCP allowlist |
| **Observability** | CloudWatch dashboard + alarms (hook crash rate, latency p99, drift events) |
| **Verification suite** | 75+ assertions across 7 test suites: PII corpus FNR/FPR, audit chain tamper detection, bypass red-team (32 attempts), latency benchmarks, Bedrock Guardrails live verification |
| **Operational docs** | Threat model (STRIDE), incident response, on-call runbook, hook contract, platform compensations, test evidence, deployment guide |
| **Installable plugin** | `plugin/` — opt-in Claude Code plugin packaging 5 hooks for the official marketplace; user-friendly defaults; 76-assertion test suite |

## Defense-in-Depth Architecture

Seven enforcement layers, all tested on real AWS infrastructure:

| Layer | Mechanism | Stops | Where to read |
|---|---|---|---|
| 1 | **Permission deny rules** | Single-token dangerous commands | [`docs/security-rationale.md`](docs/security-rationale.md) |
| 2 | **`pii-guard.sh`** hook | Sensitive data in prompts and tool inputs | [`docs/pii-guard.md`](docs/pii-guard.md) |
| 3 | **`git-guard.sh`** hook | Unauthorized git push, branch violations, force-push | [hook source](hooks/git-guard.sh) |
| 4 | **`audit-logger.sh`** hook (HMAC-chained, fail-closed) | Audit evasion, tampered audit log | [hook source](hooks/audit-logger.sh) |
| 5 | **`token-budget-guard.sh`** hook | Token cost explosion, runaway agent sessions | [hook source](hooks/token-budget-guard.sh) |
| 6 | **Wrapper script + filesystem ACL + sudoers** | `--dangerously-skip-permissions`, `--permission-mode=…`, `claude mcp add` | [wrapper-linux.sh](scripts/wrapper-linux.sh) |
| 7 | **Bedrock Guardrails** (server-side) | Harmful content, PII, prompt-attack jailbreaks | [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) |

Plus **OS sandbox** (bubblewrap), **network isolation** (VPC Endpoint),
**telemetry shim** ([`hooks/hook-wrapper.sh`](hooks/hook-wrapper.sh)) that converts
hook crashes/timeouts to fail-closed denials, and a **real-time drift watcher**
([`scripts/drift-watcher.sh`](scripts/drift-watcher.sh)) that alarms within
~60ms of any change to managed config or hook files.

See [`docs/threat-model.md`](docs/threat-model.md) for STRIDE attack-tree
analysis and [`docs/test-evidence.md`](docs/test-evidence.md) for the verified
performance and security numbers.

## Settings Hierarchy

Claude Code merges settings from four levels. Higher levels win, and managed-level
deny rules cannot be removed by lower levels:

| Level | Path | Owner | Tested |
|---|---|---|---|
| 1. Enterprise Managed (highest) | `/etc/claude-code/managed-settings.json` (Linux)<br>`C:\Program Files\ClaudeCode\managed-settings.json` (Win) | root / Administrators | ✅ |
| 2. User Settings | `~/.claude/settings.json` | the developer | ✅ |
| 3. Project Settings (shareable) | `.claude/settings.json` (in repo) | the team | (same format as L2) |
| 4. Local Project Overrides | `.claude/settings.local.json` (gitignored) | the developer | (same format) |

**Verified managed-only enforcement:**
- `allowManagedPermissionRulesOnly: true` — user-level deny rules ignored ✅
- `allowManagedHooksOnly: true` — only managed hooks fire ✅
- `allowManagedMcpServersOnly: true` — runtime filter for MCP servers ✅

> ⚠ **Gotcha**: env vars in user settings DO override managed env vars (this is by design,
> but a stale user-level `CLAUDE_AUDIT_LOG` can silently break audit logging).
> Pre-deployment check is documented in [`docs/deployment-guide.md`](docs/deployment-guide.md#step-8).

This kit ships configs for Levels 1 and 2:
- [`docs/managed-settings.jsonc`](docs/managed-settings.jsonc) → Level 1
- [`docs/settings-linux-macos.jsonc`](docs/settings-linux-macos.jsonc) / [`docs/settings-windows.jsonc`](docs/settings-windows.jsonc) → Level 2

## Try It as a Plugin (opt-in, 1 command)

Want to evaluate these controls without the full IaC deployment? The hooks are
also packaged as an installable Claude Code plugin with **user-friendly
defaults** (no root required — state goes to `~/.claude/claude-code-security/`):

```
/plugin install claude-code-bedrock-security@claude-plugins-official
```

The plugin bundles 5 of the hooks (PII guard · git guard · HMAC-chained audit
logger · token-budget breaker · fail-closed telemetry shim), recognises PII
across 7 jurisdictions, and ships **76 reproducible test assertions**
(`plugin/tests/run-tests.sh`). See [`plugin/README.md`](plugin/README.md).

> **Plugin vs. enterprise enforcement.** The plugin is the opt-in,
> user-removable on-ramp for individuals and evaluation. For **un-removable,
> fleet-wide enforcement** — root-owned paths, fail-closed audit, SIEM
> integration — deploy the same hooks via `managed-settings.json` + the
> Terraform modules below. Same hooks, different trust boundary.

## Quick Start (Linux/macOS, 5 minutes)

For a one-shot manual install, follow steps below. **For production use, prefer
the Terraform module** in [`terraform/ec2-baseline/`](terraform/ec2-baseline/)
which makes the deployment idempotent and SSM-driven.

```bash
# 0. Install Claude Code
curl -fsSL https://claude.ai/install.sh | bash          # macOS / Linux
# Alternatives: brew install --cask claude-code | irm https://claude.ai/install.ps1 | iex (Windows)

# 1. Install dependencies
sudo dnf install -y bubblewrap socat jq inotify-tools openssl    # or: apt install ...

# 2. Deploy hooks (root-owned, executable)
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/*.sh /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/*.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# 3. Deploy managed settings (root-owned)
sudo mkdir -p /etc/claude-code
python3 -c "import re,json;c=open('docs/managed-settings.jsonc').read();c=re.sub(r'(?<!:)//[^\n]*','',c);c=re.sub(r'/\*.*?\*/','',c,flags=re.S);c=re.sub(r',(\s*[}\]])',r'\1',c);json.dump(json.loads(c),open('/tmp/m.json','w'),indent=2)"
sudo mv /tmp/m.json /etc/claude-code/managed-settings.json

# 4. Deploy hardened wrapper + sudoers (real binary 0750 root:claude-users)
sudo groupadd claude-users 2>/dev/null || true
sudo mkdir -p /opt/claude-code/bin
sudo install -m 0750 -o root -g claude-users $(which claude) /opt/claude-code/bin/claude
sudo install -m 0755 -o root -g root scripts/wrapper-linux.sh /usr/local/bin/claude
sudo install -m 0440 -o root -g root scripts/sudoers-claude-code /etc/sudoers.d/claude-code
sudo visudo -cf /etc/sudoers.d/claude-code

# 5. Lock MCP config (prevents `claude mcp add`)
touch ~/.claude.json && sudo chattr +i ~/.claude.json

# 6. Audit log + rotation (HMAC chain enabled by default)
sudo mkdir -p /var/log/claude-code /var/lib/claude-code/audit-state
sudo touch /var/log/claude-code/audit.jsonl /var/log/claude-code/hooks.jsonl /var/log/claude-code/drift.jsonl
sudo chattr +a /var/log/claude-code/audit.jsonl
sudo cp scripts/logrotate-claude-code.conf /etc/logrotate.d/claude-code

# 7. Real-time drift watcher (systemd unit)
sudo install -m 0755 scripts/drift-watcher.sh /usr/local/bin/claude-drift-watcher
# (See terraform/ec2-baseline/ssm-deploy.yaml.tpl for the matching systemd unit)

# 8. Verify
claude -p "say PONG"                                # → PONG (works)
claude -p "My card is 4111-1111-1111-1111"          # → blocked (PII guard)
claude -p "hi" --dangerously-skip-permissions       # → Refused (wrapper)
claude -p "x" --permission-mode=bypassPermissions   # → Refused (wrapper, equals form)
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied

# 9. Run the local test suite (75+ assertions, ~3 min on macOS)
bash tests/run_all.sh    # → "7 suites passed, 0 failed"
```

For full deployment (incl. Terraform, golden image, multi-region), see
[`docs/deployment-guide.md`](docs/deployment-guide.md).

## What Gets Blocked

### PII & Secrets — local hook (corpus-verified)

108-case PII corpus → **FNR 0%, FPR 0%, p95 ≤ 484ms** (see
[`docs/test-evidence.md`](docs/test-evidence.md)).

| Data type | Example | Result |
|---|---|---|
| Credit cards (16-digit + Amex 4-6-5) | `4111-1111-1111-1111`, `3782 822463 10005` | ✅ Blocked |
| AWS keys | `AKIAIOSFODNN7EXAMPLE` | ✅ Blocked |
| Private keys | `-----BEGIN RSA PRIVATE KEY-----` | ✅ Blocked |
| JWT tokens | `eyJhbG...` (3-segment base64url) | ✅ Blocked |
| Passwords | `password=SuperSecret123!` | ✅ Blocked |
| Singapore NRIC | `S1234567D` | ✅ Blocked |
| Phone (intl, multi-separator), passport, email | various | ✅ Blocked |
| GitHub/GitLab/Slack tokens | `ghp_...`, `xoxb-...` | ✅ Blocked |
| DB connection strings | `postgres://user:pass@host/db` | ✅ Blocked |
| Generic API key assignments | `api_key=...`, `access_token=...` | ✅ Blocked |
| Hex secrets (32+ hex with letter) | `e3b0c44298fc1c149afbf4c8996fb924...` | ✅ Blocked |
| Normal prompts | `"Write a sort function"` | ✅ Passes through |

Full list and customization: [`docs/pii-guard.md`](docs/pii-guard.md).

### Dangerous commands (denied by rules or hooks)

| Command | Linux | Windows |
|---|---|---|
| `rm -rf *` / `Remove-Item -Recurse` | ✅ Denied | ✅ Denied |
| `git push` to unauthorized remote | ✅ Hook blocks | ✅ Denied |
| `git push` to feature branch (allowed remote) | ✅ **Allowed** | ✅ **Allowed** |
| `git push` to protected branch (main/master) | ✅ Hook blocks | ✅ Denied |
| `git push --force` / `--force-with-lease` | ✅ Hook blocks | ✅ Denied |
| `git remote add` (unauthorized domain) | ✅ Hook blocks | ✅ Denied |
| `git remote add` (allowed domain) | ✅ **Allowed** | ✅ **Allowed** |
| `git reset --hard` / `git clean -fd` | ✅ Hook blocks | ✅ Denied |
| `curl` / `wget` / `Invoke-WebRequest` | ✅ Denied | ✅ Denied |
| `sudo` / `Set-ExecutionPolicy` | ✅ Denied | ✅ Denied |
| `aws iam` / `aws sts` / `aws secretsmanager` | ✅ Denied | ✅ Denied |
| Read `.env` / `.aws/credentials` / `.ssh/` | ✅ Denied | ☑️ Use sandbox.denyRead |
| Write to `C:\Windows\` | N/A | ✅ Denied |

### Bypass attempts (red-team verified — 32/32 blocked)

| Bypass | Result |
|---|---|
| `--dangerously-skip-permissions` | ✅ Refused by wrapper |
| `--allow-dangerously-skip-permissions` | ✅ Refused |
| `--permission-mode auto` / `bypassPermissions` | ✅ Refused |
| `--permission-mode=bypassPermissions` (equals form) | ✅ Refused |
| `--bare` (skips hooks) | ✅ Refused |
| `claude mcp add --scope user` | ✅ EPERM (chattr +i) |
| Force-push hidden after `&&` (compound shell) | ✅ git-guard catches it |
| Hook crash → silent pass-through | ✅ Telemetry shim converts to fail-closed |
| `CLAUDE_AUDIT_LOG=/dev/null` (audit silencing) | ✅ Managed env wins; fail-closed if log unwritable |

Full bypass test harness: [`tests/bypass-attempts.sh`](tests/bypass-attempts.sh).

### Token cost explosion (circuit breaker)

`token-budget-guard.sh` enforces per-session token + tool-call budgets.
When a session hits `CLAUDE_TOKEN_BUDGET` (default 1M tokens) or
`CLAUDE_CALL_BUDGET` (default 500 calls), the next `PreToolUse` returns
exit 2 and the user is told to start a fresh session.

### Bedrock Guardrails (server-side, live-verified)

| Policy | Status | Notes |
|---|---|---|
| Content Filters (Hate/Insults/Sexual/Violence/Misconduct) | ✅ Works | Input + Output |
| **`PROMPT_ATTACK` filter** | ✅ Works (5/5 jailbreaks blocked) | Verified contradiction of #63637's "doesn't work" claim |
| Denied Topics | ✅ Works | 100% recall, 16.7% FPR — calibrate definitions |
| Word Filters | ✅ Works | Custom + AWS-managed profanity |
| Sensitive Information Filters | ⚠️ US-centric | Local pii-guard.sh complements (NRIC, intl phone, etc.) |
| Contextual Grounding | ⚠️ Conditional | **Errors any request without `grounding_source`** — DO NOT enable for general code-gen |
| Streaming intervention UX | ⚠️ Gotcha | Returns `blockedInputMessaging` (default `BLOCKED_INPUT_BY_GUARDRAIL`) as a normal text delta — Claude Code renders it as model output. **Customise** to a non-model prefix (max 500 chars, verified verbatim, see [`docs/bedrock-guardrails.md#streaming-ux-gotcha-read-this`](docs/bedrock-guardrails.md#streaming-ux-gotcha-read-this)) |

Reproducible tests: [`tests/aws-guardrails/`](tests/aws-guardrails/).
Full evidence: [`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md).

## Platform Differences

| Behavior | Linux/macOS (Bash) | Windows (PowerShell) |
|---|---|---|
| `<tool>(git push *)` deny | ☑️ Use `:*` syntax (Bash matcher bug) | ✅ Works as-is |
| `<tool>(git remote add *)` deny | ☑️ Use git-guard.sh hook | ✅ Works as-is |
| `Read(**/.env)` deny | ✅ Works | ☑️ Use sandbox.denyRead |
| OS sandbox (bubblewrap) | ✅ Supported | ❌ Not supported natively |
| PII guard scope | ✅ UserPromptSubmit + PreToolUse | ☑️ PreToolUse only (`UserPromptSubmit` does not fire in `--print` mode on Windows; use Bedrock Guardrails to cover prompt-level PII) |
| `chattr +i` for MCP lock | ✅ ext4/xfs | ☑️ Use `icacls` (Windows) or **`sudo chflags schg`** (macOS — note: `chflags uchg` is user-removable, use `schg` + non-root user. See known-issues Issue 11) |
| NFS home directories | ❌ `chattr` is no-op — see compensations | ❌ Same |

Compensating controls per platform: [`docs/platform-compensations.md`](docs/platform-compensations.md).
Full platform compatibility matrix: [`docs/known-issues.md`](docs/known-issues.md).

## Test Suite & Reproducible Evidence

This kit ships with a 7-suite, 75+ assertion test harness. Every claim in the
docs is backed by a reproducible test.

```bash
bash tests/run_all.sh
# === 1. PII corpus (FNR/FPR) ===            FNR=0.00%  FPR=0.00%  p95=484ms
# === 2. Hook telemetry shim ===             passed=12 failed=0
# === 3. Audit HMAC chain ===                passed=13 failed=0
# === 4. Token budget guard ===              passed=9  failed=0
# === 5. Drift watcher self-test ===         drift detected in 47ms
# === 6. Bypass red-team harness ===         passed=32 failed=0   (5 categories, 32/32 blocked)
# === 7. Hook latency micro-bench ===        all hooks p99 ≤ 490ms (macOS dev)
# RUN-ALL: 7 suites passed, 0 failed
```

For Bedrock Guardrails verification (requires AWS account, ~$0.35 spend):

```bash
bash   tests/aws-guardrails/01_create_guardrail.sh        # creates test guardrail
python3 tests/aws-guardrails/02_streaming.py              # streaming + non-streaming
python3 tests/aws-guardrails/03_pii_detection.py          # PII corpus vs Bedrock
python3 tests/aws-guardrails/04_cross_region.py           # us.* and global.* profiles
python3 tests/aws-guardrails/06_denied_topics.py          # FPR measurement
python3 tests/aws-guardrails/08_latency.py                # 30-iter latency bench
python3 tests/aws-guardrails/09_grounding.py              # Contextual Grounding
python3 tests/aws-guardrails/10_prompt_attack.py          # PROMPT_ATTACK with/without tags
aws bedrock delete-guardrail --guardrail-identifier <id>  # cleanup
```

Bugs surfaced by the harness (then fixed):
- 5 PII regex defects in `pii-guard.sh` (Amex CC, intl phone, generic API
  keys, hex secret false positive, passport false positive)
- 1 wrapper bypass (`--permission-mode=bypassPermissions` equals form)
- 1 silent audit-loss bug (`exit 0` on failure — now fail-closed with HMAC chain)

See [`docs/test-evidence.md`](docs/test-evidence.md) and
[`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md)
for full numbers and audit trail of value-add.

## Documentation Index

Documents are grouped by audience and use case.

### For Developers / IT Operations (deploy and run)
- [`docs/deployment-guide.md`](docs/deployment-guide.md) — Step-by-step golden image checklist
- [`docs/operations-runbook.md`](docs/operations-runbook.md) — Onboarding, offboarding, emergency disable, credential rotation
- [`docs/runbooks/on-call.md`](docs/runbooks/on-call.md) — Alarm-by-alarm response procedures (matches CloudWatch alarms in `observability/`)
- [`docs/known-issues.md`](docs/known-issues.md) — Matcher bugs, platform quirks, and verified workarounds
- [`docs/platform-compensations.md`](docs/platform-compensations.md) — NFS / Windows `--print` / macOS / Kubernetes compensating controls
- [`docs/hook-contract.md`](docs/hook-contract.md) — Hook input/output schema, exit-code semantics, telemetry schema, audit log schema
- [`docs/test-results.md`](docs/test-results.md) — Original Linux + Windows e2e test evidence
- [`docs/test-evidence.md`](docs/test-evidence.md) — Local test suite results (PII, hooks, audit chain, bypass, latency)

### For Security Team (review, monitor, respond)
- [`docs/threat-model.md`](docs/threat-model.md) — STRIDE analysis with attack trees
- [`docs/security-rationale.md`](docs/security-rationale.md) — Threat → control mapping
- [`docs/pii-guard.md`](docs/pii-guard.md) — PII guard hook details and customization
- [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) — AWS Bedrock Guardrails integration guide (7 protection policies, configuration, verified behaviour)
- [`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md) — Live verification: streaming behaviour, CloudWatch metrics, PII per type, latency, prompt attack
- [`docs/incident-response.md`](docs/incident-response.md) — P1-P4 playbook with severity, SLA, escalation
- [`docs/metrics-and-kpi.md`](docs/metrics-and-kpi.md) — Leading and lagging indicators, dashboard layout
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) — Multi-region failover, RTO/RPO

### For CISO / Risk / Audit / Compliance
- [`docs/data-classification.md`](docs/data-classification.md) — What classes of data Claude Code may process
- [`docs/third-party-risk.md`](docs/third-party-risk.md) — Anthropic / AWS / npm vendor risk assessment
- [`docs/sbom.md`](docs/sbom.md) — Software Bill of Materials (EO 14028, EU CRA)
- [`docs/maintenance-schedule.md`](docs/maintenance-schedule.md) — Version upgrade testing, RACI matrix

### Configuration files (drop-in)
- [`docs/managed-settings.jsonc`](docs/managed-settings.jsonc) — Enterprise managed-settings.json (Level 1)
- [`docs/settings-linux-macos.jsonc`](docs/settings-linux-macos.jsonc) — User settings.json (Linux/macOS)
- [`docs/settings-windows.jsonc`](docs/settings-windows.jsonc) — User settings.json (Windows)

### Infrastructure as Code
- [`terraform/ec2-baseline/`](terraform/ec2-baseline/) — EC2 + IAM + SSM Document + CloudWatch baseline (idempotent deploy)
- [`terraform/managed-settings-ssm/`](terraform/managed-settings-ssm/) — SSM Parameter Store-backed approved MCP server list
- [`observability/cloudwatch-dashboard.tf`](observability/cloudwatch-dashboard.tf) — Dashboard + 4 alarms (hook crash rate, p99 latency, drift events, intervention rate)

## Repository Structure

```
claude-code-on-aws-bedrock-best-practices/
├── README.md                              ← this file
├── README.zh-TW.md                        ← 繁體中文版
├── LICENSE                                ← Apache 2.0
├── docs/                                  ← 21 markdown + 3 JSONC config files
│   ├── bedrock-guardrails.md              ← Bedrock Guardrails integration guide
│   ├── bedrock-guardrails-test-evidence.md ← live AWS verification of guardrails
│   ├── data-classification.md
│   ├── deployment-guide.md
│   ├── disaster-recovery.md
│   ├── hook-contract.md                   ← hook API spec (input/output/exit codes)
│   ├── incident-response.md
│   ├── known-issues.md
│   ├── maintenance-schedule.md
│   ├── managed-settings.jsonc             ← Level 1 config (IT-deployed)
│   ├── metrics-and-kpi.md
│   ├── operations-runbook.md
│   ├── pii-guard.md
│   ├── platform-compensations.md          ← NFS / Windows / macOS / k8s
│   ├── runbooks/
│   │   └── on-call.md                     ← per-alarm response procedures
│   ├── sbom.md
│   ├── security-rationale.md
│   ├── settings-linux-macos.jsonc         ← Level 2 config (user)
│   ├── settings-windows.jsonc             ← Level 2 config (user, Windows)
│   ├── test-evidence.md                   ← local test-suite results + bug audit trail
│   ├── test-results.md                    ← original e2e Linux + Windows evidence
│   ├── third-party-risk.md
│   └── threat-model.md
├── hooks/                                 ← all tested ✅
│   ├── audit-logger.sh                    ← HMAC-chained, fail-closed, CloudWatch dual-write
│   ├── git-guard.sh                       ← enterprise git policy
│   ├── hook-wrapper.sh                    ← telemetry + fail-closed shim for any hook
│   ├── pii-guard.ps1                      ← PII/secrets scanner (Windows)
│   ├── pii-guard.sh                       ← PII/secrets scanner (Linux/macOS)
│   └── token-budget-guard.sh              ← agent-loop circuit breaker
├── scripts/
│   ├── chain-verify.sh                    ← verify HMAC chain integrity in audit log
│   ├── drift-watcher.sh                   ← real-time tamper detection (inotify/fswatch)
│   ├── logrotate-claude-code.conf         ← audit log rotation (handles chattr +a)
│   ├── sudoers-claude-code                ← drop-in sudoers for hardened wrapper
│   ├── wrapper-linux.sh                   ← bypass-flag rejection (Linux/macOS)
│   └── wrapper-windows.cmd                ← bypass-flag rejection (Windows)
├── terraform/
│   ├── ec2-baseline/                      ← EC2 + IAM + SSM + CloudWatch (idempotent)
│   │   ├── main.tf
│   │   ├── ssm-deploy.yaml.tpl
│   │   └── user-data.sh.tpl
│   └── managed-settings-ssm/              ← SSM Parameter Store for MCP allowlist
│       └── main.tf
├── observability/
│   └── cloudwatch-dashboard.tf            ← dashboard + 4 alarms
└── tests/
    ├── aws-guardrails/                    ← Bedrock Guardrails verification (10 scripts)
    │   ├── 01_create_guardrail.sh
    │   ├── 02_streaming.py
    │   ├── 03_pii_detection.py
    │   ├── 04_cross_region.py
    │   ├── 06_denied_topics.py
    │   ├── 08_latency.py
    │   ├── 09_grounding.py
    │   ├── 10_prompt_attack.py
    │   └── lib/invoke.py
    ├── lib/harness.sh                     ← shared test helpers
    ├── pii-corpus/                        ← 108 labelled PII test cases
    │   ├── negative/
    │   └── positive/
    ├── bench_hook_latency.sh              ← 200-iter latency micro-bench
    ├── bypass-attempts.sh                 ← 32-attempt red-team harness
    ├── run_all.sh                         ← master runner (7 suites)
    ├── run_pii_corpus.sh                  ← 108-case PII verification
    ├── test_audit_chain.sh                ← HMAC chain tamper detection
    ├── test_hook_wrapper.sh               ← telemetry + fail-closed semantics
    └── test_token_budget.sh               ← per-session circuit breaker
```

## Tested On

| Component | Version |
|---|---|
| Claude Code | 2.1.150, 2.1.152, 2.1.156 |
| Linux | Amazon Linux 2023 (EC2 t3.medium) |
| Windows | Windows Server 2022 (EC2 t3.medium) |
| macOS | Darwin 25.5 (arm64, dev) |
| Node.js | 20.18.0, 20.20.2 LTS |
| PowerShell | 7.4.6 (Windows) |
| AWS CLI | v2.31.23 (macOS), v2.33.15 (Linux EC2), v2.34.56 (Windows EC2) |
| boto3 / botocore | 1.42.79 |
| AWS Bedrock | us-east-1 via VPC Endpoint (private DNS) |
| Sandbox | bubblewrap 0.10.0 + socat 1.7.4.2 (Linux) |
| Models | `us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-haiku-4-5-20251001-v1:0`, `global.*` profiles |
| Inference profiles | `us.*` and `global.*` cross-region — both verified with guardrails |
| Terraform | ≥ 1.5.0 (HCL2 parser-validated) |

### Minimum Version Requirements

Some features in this kit require specific Claude Code versions:

| Feature | Minimum Version |
|---|---|
| `sandbox.network.deniedDomains` | v2.1.113+ |
| `managed-settings.d/` directory support | v2.1.83+ |
| `DISABLE_AUTOUPDATER` env var | v2.1.118+ |
| `ANTHROPIC_BEDROCK_SERVICE_TIER` | v2.1.122+ |

## Disclaimer

This is an **independent, personal open-source project — not affiliated with,
endorsed by, or supported by Anthropic or AWS.** "Claude", "Bedrock", and
related names are trademarks of their respective owners, used here for
descriptive purposes only.

The security controls are provided **"AS IS", without warranty of any kind**.
They are best-effort and do not guarantee detection of all sensitive data or
compliance with any law or standard, and do **not** constitute legal,
regulatory, or professional security advice. You are responsible for validating
them in your own environment. See [DISCLAIMER.md](DISCLAIMER.md) and the
[LICENSE](LICENSE). **Use at your own risk.**

## License & Contributing

Released under [Apache 2.0](LICENSE) — use freely in your enterprise deployment.

**Contributions welcome:**
- New PII patterns (e.g., country-specific national IDs) — add a corpus row in `tests/pii-corpus/positive/` and re-run `bash tests/run_pii_corpus.sh` to prove FNR
- Platform-specific tests (macOS, NFS home dirs, btrfs)
- Additional hook scripts (e.g., custom MCP server validation)
- Translations of README

When opening a PR, include test evidence:
- For hook/regex changes: `bash tests/run_all.sh` output
- For Bedrock-related changes: `tests/aws-guardrails/` output (with redacted account IDs)
- For deployment changes: shell logs from EC2 or local VM
