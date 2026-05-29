# Security Rationale — Enterprise Risk Control Framework

Every control in this repository mitigates a specific enterprise risk.
This document maps threats to controls for CISO, IT Security, Compliance, and auditors.

## Threat / Impact Matrix

| Category | Threat | Attack Scenario | Business Impact | Control in This Kit |
|---|---|---|---|---|
| **Data exfiltration (code)** | Push to unauthorized remote | AI agent pushes proprietary source code to attacker-controlled repo | IP theft, regulatory breach | git-guard.sh (domain allowlist) |
| **Data exfiltration (network)** | HTTP/CLI data transfer | Agent sends secrets to external endpoint via curl/wget/WebFetch | Credential/PII leak | deny rules + sandbox.network |
| **Data exfiltration (process)** | Arbitrary process launch | Agent spawns nc/scp/custom binary bypassing deny rules | Bypass all network controls | deny `Start-Process *` |
| **Data leakage (to model)** | PII/secrets in prompts | Sensitive data sent to Bedrock API, stored in logs | Regulatory breach (GDPR, PDPA) | pii-guard.sh (UserPromptSubmit + PreToolUse) |
| **Data leakage (from model)** | Model echoes secrets | Model includes credentials in response (visible in terminal/logs) | Credential exposure | Bedrock Guardrails + sandbox.denyRead |
| **Prompt injection** | Malicious repo files | Attacker plants instructions in CLAUDE.md that override security intent | Agent acts against policy | `allowManagedPermissionRulesOnly` + managed hooks |
| **Destructive (filesystem)** | Mass file deletion | Agent runs `rm -rf` or `Remove-Item -Recurse` | Productivity loss, outage | deny rules |
| **Destructive (system)** | Disk format / shutdown | Agent runs `dd`, `mkfs`, `shutdown` | Data loss, disruption | deny rules |
| **Destructive (git)** | History destruction | `git reset --hard`, `git clean -fd` | Lost development work | git-guard.sh |
| **Branch policy violation** | Direct push to main | Untested code pushed to production branch | Broken builds, SOX violation | git-guard.sh (branch protection) |
| **Force-push** | History rewrite | `git push --force` rewrites shared history | Team-wide disruption | git-guard.sh |
| **Privilege escalation** | Root access | `sudo`, `su`, `Set-ExecutionPolicy` | Complete system compromise | deny rules |
| **Credential theft (file)** | Read secrets from disk | Agent reads .env, .aws/credentials, SSH keys | Lateral movement | deny rules + sandbox.denyRead |
| **Credential theft (AWS)** | IAM manipulation | Agent creates users, assumes roles, retrieves secrets | Persistent cloud backdoor | deny `aws iam/sts/secretsmanager` |
| **System tampering** | Modify system files | Write to C:\Windows, /usr/bin | Persistent compromise | deny Write rules |
| **Supply chain** | Package publish | Agent publishes modified package to npm | Downstream compromise | git-guard.sh + deny rules |
| **Security bypass (flags)** | Disable permissions | `--dangerously-skip-permissions`, `--bare` | All controls advisory-only | wrapper script |
| **Security bypass (MCP)** | Add rogue MCP server | `claude mcp add` with arbitrary code execution | Arbitrary code execution | `chattr +i` + wrapper |
| **Security bypass (hooks)** | Override managed hooks | User replaces policy hook with no-op | All hook controls disabled | `allowManagedHooksOnly` |
| **Security bypass (settings)** | Override managed deny | User adds allow rules | Blocked commands unblocked | `allowManagedPermissionRulesOnly` |
| **Audit evasion** | No forensic trail | No record of what agent did | Cannot investigate incidents | audit-logger.sh |
| **Audit evasion (config)** | Silent settings failure | `--print` ignores invalid settings | Controls silently disabled | deploy-time validation |
| **Version drift** | Uncontrolled upgrade | User upgrades to untested version | Unpredictable security | `DISABLE_UPDATES=1` |
| **Network escape** | Internet access | Subprocess reaches any endpoint | Exfiltration, malware | VPC Endpoint + sandbox.network |
| **Sandbox escape** | Missing runtime | bubblewrap absent → unsandboxed | OS controls bypassed | `sandbox.failIfUnavailable` |
| **Cost explosion** | Infinite loop | Agent processes massive files or loops | Unexpected Bedrock bill | `BASH_MAX_TIMEOUT_MS` + AWS budgets |
| **Shadow AI** | Unauthorized install | Developer installs Claude Code without IT | No controls applied | MDM + managed settings |

## Defense-in-Depth Layers

| Layer | Mechanism | What it stops | Bypass-proof? |
|---|---|---|---|
| 1 | Permission deny rules | Dangerous commands | No (Bash 3-token bug) |
| 2 | git-guard.sh | Unauthorized push, branch violation, destructive git | Yes (if root-owned) |
| 3 | pii-guard.sh | Secrets/PII reaching the model | Yes (if root-owned) |
| 4 | audit-logger.sh | Audit evasion (detective control) | Yes (if root-owned) |
| 5 | OS Sandbox (bubblewrap) | File/network access at kernel level | Yes |
| 6 | Wrapper script | Bypass flags | Yes (if only `claude` on PATH) |
| 7 | Filesystem ACL (`chattr +i`) | MCP server additions | Yes (requires root) |
| 8 | Managed settings (root-owned) | User overrides | Yes |
| 9 | VPC Endpoint + no internet | Network exfiltration | Yes |
| 10 | Bedrock Guardrails | Model output filtering | Yes (server-side) |
| 11 | AWS IAM (least privilege) | Cloud resource abuse | Yes |
| 12 | MDM/endpoint management | Shadow AI installations | Yes |

## Residual Risks (not fully mitigated by this kit)

| Risk | Why it's residual | Recommended additional control |
|---|---|---|
| Model generates insecure code | AI hallucination — no tool can prevent this | Mandatory code review + SAST/DAST in CI pipeline |
| Model output contains PII from training data | Server-side issue | Bedrock Guardrails content filter |
| Sophisticated prompt injection via multi-step manipulation | Hook can't understand semantic intent | Security awareness training + limit Claude's autonomy (use `defaultMode: "default"`) |
| Insider threat (developer with root access) | Root can disable all controls | Separation of duties + privileged access management (PAM) |
| Zero-day in Claude Code binary | Unknown vulnerability | Version pinning + rapid patching process + network isolation |
| Token cost abuse (within timeout limits) | Timeout limits cost but don't eliminate it | AWS Bedrock budget alerts + per-user quotas via IAM |

## Compliance Mapping

| Regulation / Standard | Relevant controls in this kit |
|---|---|
| MAS TRM (Singapore) | Data exfiltration prevention, audit trail, access control |
| PDPA (Singapore) | PII guard hook, sandbox.denyRead |
| SOX (US) | Branch protection (change management), audit trail |
| GDPR (EU) | PII guard, data minimization (sandbox.denyRead) |
| ISO 27001 | All layers (defense-in-depth), audit logging |
| PCI DSS | Credential protection, network isolation, access control |
| NIST CSF | Identify (rationale), Protect (controls), Detect (audit), Respond (alerts) |
