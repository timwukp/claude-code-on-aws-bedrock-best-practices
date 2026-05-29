# Threat Model — Claude Code on AWS Bedrock (STRIDE)

Structured threat analysis using Microsoft's STRIDE framework, mapped to controls in this kit.

## System Boundary

```
┌─ Trust Boundary 1: Developer Workstation ──────────────────┐
│                                                            │
│   ┌─ Claude Code CLI (wrapper) ─┐                          │
│   │   ↓                         │                          │
│   │   Hooks (git/pii/audit) ────┼─→ /var/log/claude-code/  │
│   │   ↓                         │                          │
│   │   Sandbox (bubblewrap)      │                          │
│   │   ↓                         │                          │
│   │   Bash/PowerShell ←─tool calls                         │
│   └─────────────────────────────┘                          │
│                                                            │
│   Files: ~/.claude/settings.json (R/W) — locked            │
│          /etc/claude-code/managed-settings.json (R only)   │
└──────────────────────────┬─────────────────────────────────┘
                           │ HTTPS via VPC Endpoint
                           ↓
┌─ Trust Boundary 2: AWS VPC ───────────────────────────────┐
│   Bedrock Runtime API + Guardrails                        │
│   CloudTrail (API audit)                                  │
└────────────────────────────────────────────────────────────┘
```

## STRIDE Analysis

### S — Spoofing

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| User impersonates another user | Audit log entries | Modify `whoami` output | audit-logger.sh records hostname + reads from kernel |
| Attacker spoofs Bedrock API | Model responses | DNS poisoning to send to attacker server | VPC Endpoint + private DNS + TLS cert validation |
| Malicious npm package impersonates Claude Code | Claude binary | Typosquatting | npm package signing + version pinning |
| Spoofed managed-settings.json | All controls | Replace with permissive config | File ownership root:root + chattr +i / file integrity monitoring |

### T — Tampering

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| User modifies hook script | Enforcement | Edit `/usr/local/etc/claude-code/hooks/*.sh` | Hooks are root-owned 0755; allowManagedHooksOnly: true |
| User modifies managed-settings | All policy | Edit `/etc/claude-code/managed-settings.json` | File is root-owned 0644; drift-check.sh detects changes |
| User clears audit log | Forensic trail | `> /var/log/claude-code/audit.jsonl` | chattr +a (append-only); logrotate also append-aware; remote SIEM ship |
| User replaces wrapper with no-op | Bypass blocking | `cp echo /usr/local/bin/claude` | Wrapper is root-owned 0755 |
| User adds rogue MCP server | Code execution | `claude mcp add evil --scope user -- ...` | chattr +i ~/.claude.json + allowManagedMcpServersOnly |
| User edits CLAUDE.md to bypass policy | Agent behavior | Plant injection in repo | allowManagedPermissionRulesOnly + managed hooks (always run) |

### R — Repudiation

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| User denies running a destructive command | Accountability | "It wasn't me" | audit-logger.sh records user, hostname, timestamp, command — append-only |
| User denies pushing code externally | Audit trail | Claims of false log | git-guard.sh + audit-logger logs every push attempt with remote URL |
| Audit log not non-repudiable | Court admissibility | Logs editable in transit | Stream to SIEM (write-once); use kernel audit (auditd) for chattr changes |

### I — Information Disclosure

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| Secrets in prompts sent to Bedrock | API logs, model context | User pastes credentials | pii-guard.sh (UserPromptSubmit) blocks 15 pattern types |
| Secrets in tool inputs (file content) | Bedrock API | Claude reads .env then shows in tool input | pii-guard.sh (PreToolUse) blocks |
| Source code pushed to attacker remote | Code repos | git remote add evil + push | git-guard.sh allowlist |
| Credentials read from disk | .aws/, .ssh/, .env | Read tool exfil | Read deny rules + sandbox.denyRead |
| Model output contains training-data PII | API response | Anthropic data leakage | Bedrock Guardrails server-side filter |
| Audit log contains sensitive content | Stored logs | Logs accessible to wrong user | Log directory 0750 root:siem-readers; encrypted at rest |
| Network exfiltration via curl/wget | Internet | curl secrets to attacker.com | deny rules + sandbox.network.allowedDomains |

### D — Denial of Service

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| Token cost explosion | AWS bill | Infinite loop or massive prompts | BASH_MAX_TIMEOUT_MS + AWS Bedrock budget alerts |
| Audit log fills disk | Disk space | Verbose flood | logrotate with 100MB cap + S3 archival |
| Hook script slow → slow Claude | Productivity | grep on 1GB file | timeout in hook config + simple regex only |
| Bedrock rate limit | Service availability | Burst usage | AWS quota + per-user IAM quotas |
| Sandbox dependency missing | Service unavailable | bubblewrap absent | failIfUnavailable=true blocks startup (preferred over silent degradation) |

### E — Elevation of Privilege

| Threat | Asset | Attack | Mitigation |
|---|---|---|---|
| User uses Claude to run sudo | Root access | Bash command via Claude | Bash(sudo:*) deny + sandbox + hook |
| User uses --dangerously-skip-permissions to bypass | All controls | Add flag | wrapper script rejects flag |
| Claude reads then writes to /etc/sudoers | System privilege | Subtle escalation | sandbox.filesystem.denyRead + Write deny rules |
| MCP server with elevated privileges | Code execution | claude mcp add server with sudo capability | chattr +i + allowManagedMcpServersOnly |
| Bedrock IAM role over-privileged | AWS resources | Role has `*:*` permissions | Least privilege: only InvokeModel + InvokeModelWithResponseStream |
| Sandbox escape via bubblewrap CVE | OS root | Known bwrap exploit | Patch promptly; isolate Claude Code to dedicated VMs/containers if high risk |
| Remote Control API exploitation | Session control | External process sends commands to Claude Code via Remote Control API | `disableRemoteControl: true` in managed settings (set in this kit) |
| Auto Mode bypasses interactive approval | All tool controls | Auto Mode executes tools without per-tool user confirmation, allowing rapid chained attacks | `disableAutoMode: "disable"` in managed settings permissions block |
| Malicious plugin/marketplace install | Code execution | Plugin from untrusted marketplace executes arbitrary code in session context | `blockedMarketplaces: ["*"]` + `strictKnownMarketplaces: true` + `allowManagedMcpServersOnly` |

## Attack Trees (high-priority threats)

### "Exfiltrate source code to attacker"

```
GOAL: Push proprietary code to attacker.com
├── 1. git push to evil remote
│   ├── 1a. git remote add evil http://...
│   │   └── BLOCKED by git-guard.sh (allowlist) ✓
│   ├── 1b. git remote set-url origin http://...
│   │   └── BLOCKED by git-guard.sh ✓
│   └── 1c. git push http://... main (direct URL)
│       └── BLOCKED by git-guard.sh (URL extracted from push args) ✓
├── 2. curl POST file content to attacker
│   ├── 2a. curl -X POST -d @file
│   │   └── BLOCKED by Bash(curl:*) deny rule ✓
│   ├── 2b. wget --post-file
│   │   └── BLOCKED by Bash(wget:*) ✓
│   └── 2c. nc (netcat)
│       └── BLOCKED by Bash(Start-Process *) on Win; sandbox.network on Linux ✓
└── 3. Trick Claude to write code to /tmp/exfil and let user transfer manually
    └── PARTIAL: hook can't stop legitimate file writes, but sandbox.allowWrite=cwd helps
```

### "Bypass all controls"

```
GOAL: Use Claude Code without enforcement
├── 1. --dangerously-skip-permissions
│   └── BLOCKED by wrapper script ✓
├── 2. Edit ~/.claude/settings.json to remove deny rules
│   └── BLOCKED by allowManagedPermissionRulesOnly + chattr +i ✓
├── 3. Edit hook scripts to no-op
│   └── BLOCKED by file ownership root:root ✓
├── 4. Edit managed-settings.json
│   └── BLOCKED by file ownership; drift-check.sh detects ✓
├── 5. Run /opt/claude-code/bin/claude directly (bypass wrapper)
│   └── PARTIAL: deny rules still enforced; managed-settings still loaded
│   └── REMEDIATION: restrict /opt/claude-code/bin/ to mode 0700 root:root + sudo wrapper
├── 6. Install own copy of Claude Code in user home
│   └── PARTIAL: own settings.json is read but managed settings still merged (highest priority)
│   └── REMEDIATION: MDM/endpoint detection of unauthorized installs
├── 7. Use Remote Control API to inject commands
│   └── BLOCKED by disableRemoteControl: true ✓
├── 8. Enable Auto Mode for unsupervised execution
│   └── BLOCKED by disableAutoMode: "disable" ✓
└── 9. Install malicious plugin from marketplace
    └── BLOCKED by blockedMarketplaces + strictKnownMarketplaces (requires uncommenting in managed-settings.jsonc) ✓
```

## Residual Risks

| Risk | Likelihood | Impact | Acceptance |
|---|---|---|---|
| Insider with root access bypasses everything | Low | High | Accepted: separation of duties + PAM |
| Sandbox kernel CVE (bubblewrap zero-day) | Low | Medium | Accepted: rapid patching SLA |
| Bedrock service compromise (Anthropic) | Very Low | High | Accepted: vendor risk assessment + monitoring |
| Supply chain (npm package compromise) | Low | High | Accepted: package signing + version pinning |
| Model generates insecure code | High | Medium | Accepted: mandatory code review + SAST/DAST |
| Subtle prompt injection bypassing pii-guard regex | Medium | Medium | Accepted: defense-in-depth via Bedrock Guardrails |

## Threat Model Review Cycle

| Trigger | Action | Owner |
|---|---|---|
| Quarterly | Review attack trees, update for new attacks | Security Lead |
| Annually | Full STRIDE re-analysis | CISO |
| New Claude Code feature | STRIDE delta analysis | Security team |
| Post-incident | Add incident attack tree to model | Security Lead |
