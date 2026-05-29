# Secure Claude Code on AWS Bedrock — Enterprise Deployment Kit

> Production-tested security configurations, hooks, and operational documentation
> for deploying [Claude Code](https://code.claude.com) on
> [Amazon Bedrock](https://aws.amazon.com/bedrock/) in regulated enterprise environments
> (banking, healthcare, government).

[繁體中文版](README.zh-TW.md)

---

## Contents

- [Why This Kit Exists](#why-this-kit-exists)
- [Defense-in-Depth Architecture](#defense-in-depth-architecture)
- [Settings Hierarchy](#settings-hierarchy)
- [Quick Start (5 minutes)](#quick-start-linuxmacos-5-minutes)
- [What Gets Blocked](#what-gets-blocked)
- [Platform Differences](#platform-differences)
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

In a regulated environment, this is unacceptable.
This kit provides **tested controls** that lock down Claude Code without
breaking developer productivity.

## Defense-in-Depth Architecture

Five enforcement layers, all tested on real AWS infrastructure:

| Layer | Mechanism | Stops | Where to read |
|---|---|---|---|
| 1 | **Permission deny rules** | Single-token dangerous commands | [`docs/security-rationale.md`](docs/security-rationale.md) |
| 2 | **`pii-guard.sh`** hook | Sensitive data in prompts and tool inputs | [`docs/pii-guard.md`](docs/pii-guard.md) |
| 3 | **`git-guard.sh`** hook | Unauthorized git push, branch violations, force-push | [hook source](hooks/git-guard.sh) |
| 4 | **`audit-logger.sh`** hook | Audit evasion (detective control) | [hook source](hooks/audit-logger.sh) |
| 5 | **Wrapper script + filesystem ACL** | `--dangerously-skip-permissions`, `claude mcp add` | [wrapper-linux.sh](scripts/wrapper-linux.sh) |

Plus **OS sandbox** (bubblewrap) and **network isolation** (VPC Endpoint).
See [`docs/threat-model.md`](docs/threat-model.md) for a STRIDE-based attack tree analysis.

## Settings Hierarchy

Claude Code merges settings from four levels. Higher levels win, and managed-level
deny rules cannot be removed by lower levels:

| Level | Path | Owner | Tested |
|---|---|---|---|
| 1. Enterprise Managed (highest) | `/etc/claude-code/managed-settings.json` (Linux)<br>`C:\ProgramData\ClaudeCode\managed-settings.json` (Win) | root / Administrators | ✅ |
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

## Quick Start (Linux/macOS, 5 minutes)

```bash
# 1. Install dependencies
sudo dnf install -y bubblewrap socat jq    # or: apt install ...

# 2. Deploy hooks (root-owned, executable)
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/git-guard.sh hooks/pii-guard.sh hooks/audit-logger.sh \
        /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/*.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# 3. Deploy managed settings (root-owned)
sudo mkdir -p /etc/claude-code
# Strip JSONC comments and deploy:
python3 -c "import re,json;c=open('docs/managed-settings.jsonc').read();c=re.sub(r'(?<!:)//[^\n]*','',c);c=re.sub(r'/\*.*?\*/','',c,flags=re.S);c=re.sub(r',(\s*[}\]])',r'\1',c);json.dump(json.loads(c),open('/tmp/m.json','w'),indent=2)"
sudo mv /tmp/m.json /etc/claude-code/managed-settings.json
sudo chown root:root /etc/claude-code/managed-settings.json

# 4. Deploy wrapper (replaces user-facing claude)
sudo mkdir -p /opt/claude-code/bin
sudo mv $(which claude) /opt/claude-code/bin/claude
sudo cp scripts/wrapper-linux.sh /usr/local/bin/claude
sudo chown root:root /usr/local/bin/claude
sudo chmod 0755 /usr/local/bin/claude

# 5. Lock MCP config (prevents `claude mcp add`)
touch ~/.claude.json
sudo chattr +i ~/.claude.json

# 6. Set up audit log + rotation
sudo mkdir -p /var/log/claude-code
sudo touch /var/log/claude-code/audit.jsonl
sudo chmod 0666 /var/log/claude-code/audit.jsonl
sudo chattr +a /var/log/claude-code/audit.jsonl
sudo cp scripts/logrotate-claude-code.conf /etc/logrotate.d/claude-code

# 7. Verify
claude -p "say PONG"                                # → PONG (works)
claude -p "My card is 4111-1111-1111-1111"          # → blocked (PII guard)
claude -p "hi" --dangerously-skip-permissions       # → Refused (wrapper)
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied
```

For full deployment (incl. user settings, drift detection, golden image), see
[`docs/deployment-guide.md`](docs/deployment-guide.md).

## What Gets Blocked

### PII & Secrets (never sent to the model)

| Data type | Example | Result |
|---|---|---|
| Credit cards | `4111-1111-1111-1111` | ✅ Blocked |
| AWS keys | `AKIAIOSFODNN7EXAMPLE` | ✅ Blocked |
| Private keys | `-----BEGIN RSA PRIVATE KEY-----` | ✅ Blocked |
| JWT tokens | `eyJhbG...` (3-segment base64url) | ✅ Blocked |
| Passwords | `password=SuperSecret123!` | ✅ Blocked |
| Singapore NRIC | `S1234567D` | ✅ Blocked |
| Phone numbers, passport numbers, emails | various | ✅ Blocked |
| GitHub/GitLab/Slack tokens | `ghp_...`, `xoxb-...` | ✅ Blocked |
| DB connection strings | `postgres://user:pass@host/db` | ✅ Blocked |
| Normal prompts | `"Write a sort function"` | ✅ Passes through |

Full list and customization: [`docs/pii-guard.md`](docs/pii-guard.md).

### Dangerous commands (denied by rules or hooks)

| Command | Linux | Windows |
|---|---|---|
| `rm -rf *` / `Remove-Item -Recurse` | ✅ Denied | ✅ Denied |
| `git push` to unauthorized remote | ✅ Hook blocks | ✅ Denied |
| `git push` to feature branch (allowed remote) | ✅ **Allowed** | ✅ **Allowed** |
| `git push` to protected branch (main/master) | ✅ Hook blocks | ✅ Denied |
| `git push --force` | ✅ Hook blocks | ✅ Denied |
| `git remote add` (unauthorized domain) | ✅ Hook blocks | ✅ Denied |
| `git remote add` (allowed domain) | ✅ **Allowed** | ✅ **Allowed** |
| `git reset --hard` / `git clean -fd` | ✅ Hook blocks | ✅ Denied |
| `curl` / `wget` / `Invoke-WebRequest` | ✅ Denied | ✅ Denied |
| `sudo` / `Set-ExecutionPolicy` | ✅ Denied | ✅ Denied |
| `aws iam` / `aws sts` / `aws secretsmanager` | ✅ Denied | ✅ Denied |
| Read `.env` / `.aws/credentials` / `.ssh/` | ✅ Denied | ☑️ Use sandbox.denyRead |
| Write to `C:\Windows\` | N/A | ✅ Denied |

### Bypass attempts (stopped by wrapper)

| Bypass | Result |
|---|---|
| `--dangerously-skip-permissions` | ✅ Refused by wrapper |
| `--allow-dangerously-skip-permissions` | ✅ Refused |
| `--permission-mode auto` / `bypassPermissions` | ✅ Refused |
| `--bare` (skips hooks) | ✅ Refused |
| `claude mcp add --scope user` | ✅ EPERM (chattr +i) |

## Platform Differences

| Behavior | Linux/macOS (Bash) | Windows (PowerShell) |
|---|---|---|
| `<tool>(git push *)` deny | ☑️ Use `:*` syntax (Bash matcher bug) | ✅ Works as-is |
| `<tool>(git remote add *)` deny | ☑️ Use git-guard.sh hook | ✅ Works as-is |
| `Read(**/.env)` deny | ✅ Works | ☑️ Use sandbox.denyRead |
| OS sandbox (bubblewrap) | ✅ Supported | ❌ Not supported natively |
| PII guard scope | ✅ UserPromptSubmit + PreToolUse | ☑️ PreToolUse only (UserPromptSubmit does not fire in `--print` mode on Windows; use Bedrock Guardrails to cover prompt-level PII) |
| `chattr +i` for MCP lock | ✅ ext4/xfs | ☑️ Use `icacls` (Windows) or **`sudo chflags schg`** (macOS — note: `chflags uchg` is user-removable, use `schg` + non-root user. See known-issues Issue 11) |

Full platform compatibility matrix: [`docs/known-issues.md`](docs/known-issues.md).

## Documentation Index

Documents are grouped by audience and use case:

### For Developers / IT Operations (deploy and run)
- [`docs/deployment-guide.md`](docs/deployment-guide.md) — Step-by-step golden image checklist
- [`docs/operations-runbook.md`](docs/operations-runbook.md) — Onboarding, offboarding, emergency disable, credential rotation
- [`docs/known-issues.md`](docs/known-issues.md) — Matcher bugs, platform quirks, and verified workarounds
- [`docs/test-results.md`](docs/test-results.md) — Full test evidence (Linux + Windows e2e)

### For Security Team (review, monitor, respond)
- [`docs/threat-model.md`](docs/threat-model.md) — STRIDE analysis with attack trees
- [`docs/security-rationale.md`](docs/security-rationale.md) — Threat → control mapping
- [`docs/pii-guard.md`](docs/pii-guard.md) — PII guard hook details and customization
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

## Repository Structure

```
claude-code-enterprise-bedrock/
├── README.md                              ← this file
├── README.zh-TW.md                        ← 繁體中文版
├── LICENSE                                ← Apache 2.0
├── docs/                                  ← 14 markdown + 3 JSONC config files
│   ├── deployment-guide.md
│   ├── operations-runbook.md
│   ├── maintenance-schedule.md
│   ├── disaster-recovery.md
│   ├── incident-response.md
│   ├── metrics-and-kpi.md
│   ├── security-rationale.md
│   ├── threat-model.md
│   ├── data-classification.md
│   ├── third-party-risk.md
│   ├── sbom.md
│   ├── pii-guard.md
│   ├── known-issues.md
│   ├── test-results.md
│   ├── managed-settings.jsonc             ← Level 1 config (IT-deployed)
│   ├── settings-linux-macos.jsonc         ← Level 2 config (user)
│   └── settings-windows.jsonc             ← Level 2 config (user, Windows)
├── hooks/                                 ← all tested ✅
│   ├── git-guard.sh                       ← enterprise git policy
│   ├── pii-guard.sh                       ← PII/secrets scanner (Linux/macOS)
│   ├── pii-guard.ps1                      ← PII/secrets scanner (Windows)
│   └── audit-logger.sh                    ← append-only audit log
└── scripts/
    ├── wrapper-linux.sh                   ← bypass-flag rejection (Linux/macOS) ✅
    ├── wrapper-windows.cmd                ← bypass-flag rejection (Windows) ✅
    └── logrotate-claude-code.conf         ← audit log rotation (handles chattr +a)
```

## Tested On

| Component | Version |
|---|---|
| Claude Code | 2.1.150, 2.1.152 |
| Linux | Amazon Linux 2023 (EC2 t3.medium) |
| Windows | Windows Server 2022 (EC2 t3.medium) |
| Node.js | 20.18.0, 20.20.2 LTS |
| PowerShell | 7.4.6 (Windows) |
| AWS Bedrock | us-east-1 via VPC Endpoint (private DNS) |
| Sandbox | bubblewrap 0.10.0 + socat 1.7.4.2 (Linux) |
| Models | `us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

## License & Contributing

Released under [Apache 2.0](LICENSE) — use freely in your enterprise deployment.

**Contributions welcome:**
- New PII patterns (e.g., country-specific national IDs)
- Platform-specific tests (macOS, NFS home dirs, btrfs)
- Additional hook scripts (e.g., custom MCP server validation)
- Translations of README

When opening a PR, include test evidence (shell logs from EC2 or local VM).
