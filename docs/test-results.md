# Test Results — Consolidated Findings

Tested May 2026 on AWS EC2 (us-east-1) with real Bedrock API calls through VPC Endpoint.

## Test Environment

| | Linux | Windows |
|---|---|---|
| OS | Amazon Linux 2023 | Windows Server 2022 Datacenter |
| Instance | t3.medium | t3.medium |
| Claude Code | 2.1.150 → 2.1.152 | 2.1.152 |
| Shell | Bash (GNU) | PowerShell 7.4.6 |
| Sandbox | bubblewrap 0.10.0 + socat 1.7.4.2 | Not tested |
| Bedrock | VPC Endpoint (private DNS) | Same VPC Endpoint |
| Git for Windows | N/A | NOT installed |

## Results Summary

### Linux (25 pass / 5 fail)

| # | Test | Result |
|---|---|---|
| 1 | Bedrock connectivity via VPCE | ✅ |
| 2 | `Bash(rm -rf:*)` blocks rm -rf | ✅ |
| 3 | `Bash(curl:*)` blocks curl | ✅ |
| 4 | `Bash(wget:*)` blocks wget | ✅ |
| 5 | `Bash(sudo:*)` blocks sudo | ✅ |
| 6 | `Bash(aws iam:*)` blocks aws iam | ✅ |
| 7 | `Bash(aws sts:*)` blocks aws sts | ✅ |
| 8 | `Bash(git push:*)` blocks all push variants | ✅ |
| 9 | `Bash(git push *)` (space) blocks push | ❌ does not match |
| 10 | `Bash(git remote add *)` blocks git remote add | ❌ does not match |
| 11 | `Bash(git remote add:*)` blocks git remote add | ❌ does not match |
| 12 | `Bash(git reset --hard:*)` blocks git reset --hard | ❌ does not match |
| 13 | PreToolUse hook blocks git remote add | ✅ |
| 14 | PreToolUse hook blocks git remote set-url | ✅ |
| 15 | PreToolUse hook blocks git remote rename | ✅ |
| 16 | PreToolUse hook blocks git remote rm | ✅ |
| 17 | PreToolUse hook blocks git reset --hard | ✅ |
| 18 | PreToolUse hook allows git remote -v | ✅ |
| 19 | PreToolUse hook allows git status | ✅ |
| 20 | `Read(**/.env)` blocks .env read | ✅ |
| 21 | `Read(**/.aws/credentials)` blocks credentials | ✅ |
| 22 | `WebFetch` removed from tool list | ✅ |
| 23 | `DISABLE_UPDATES=1` blocks claude update | ✅ |
| 24 | `disableBypassPermissionsMode` blocks --dangerously-skip-permissions | ❌ flag accepted |
| 25 | Deny rules still win over bypass mode (curl blocked even with flag) | ✅ |
| 26 | Wrapper script blocks 5 bypass flags | ✅ |
| 27 | `chattr +i` blocks claude mcp add | ✅ |
| 28 | `allowManagedPermissionRulesOnly` ignores user deny | ✅ |
| 29 | `allowManagedHooksOnly` silences user hooks | ✅ |
| 30 | `sandbox.failIfUnavailable` refuses start without deps | ✅ |
| 31 | `sandbox.filesystem.denyRead` OS-level block | ✅ |
| 32 | `sandbox.filesystem.allowWrite` cwd-only | ✅ |

### Windows (14 pass / 2 fail / 1 inconclusive)

| # | Test | Result |
|---|---|---|
| 1 | Bedrock connectivity via VPCE | ✅ |
| 2 | `"Bash"` removes Bash from tool list | ✅ |
| 3 | `PowerShell(Remove-Item *)` blocks rm/del/rd | ✅ |
| 4 | `PowerShell(Stop-Computer *)` | ⚠ Claude self-refused (inconclusive) |
| 5 | `PowerShell(Invoke-WebRequest *)` blocks iwr/curl | ✅ |
| 6 | `PowerShell(Invoke-RestMethod *)` blocks irm | ✅ |
| 7 | `PowerShell(Start-Process *)` blocks | ✅ |
| 8 | `PowerShell(Set-ExecutionPolicy *)` blocks | ✅ |
| 9 | `PowerShell(aws iam *)` blocks | ✅ |
| 10 | `PowerShell(git push *)` blocks | ✅ |
| 11 | `PowerShell(git remote add *)` blocks | ✅ |
| 12 | `PowerShell(git reset --hard *)` blocks | ✅ |
| 13 | `Read(**/.env)` blocks .env read | ❌ Claude read the file |
| 14 | `Write(C:/Windows/**)` blocks system write | ✅ |
| 15 | `WebFetch` removed from tool list | ✅ |
| 16 | `DISABLE_UPDATES=1` blocks claude update | ✅ |
| 17 | `disableBypassPermissionsMode` blocks bypass flag | ❌ flag accepted |
| 18 | `allowManagedPermissionRulesOnly` ignores user deny | ✅ |
| 19 | `allowManagedHooksOnly` — managed hook fires | ✅ |
| 20 | `sandbox.failIfUnavailable` refuses start on Windows | ✅ ("windows is not supported") |

## Key Insight: Bash vs PowerShell Matcher

| Pattern | Bash | PowerShell |
|---|---|---|
| `<tool>(git push *)` | ❌ | ✅ |
| `<tool>(git remote add *)` | ❌ | ✅ |
| `<tool>(git reset --hard *)` | ❌ | ✅ |
| `<tool>(curl *)` | ✅ | ✅ |

This is a **Bash-specific matcher bug**, not a version issue. Persists across
2.1.150 and 2.1.152. PowerShell matcher works correctly for all token counts.

---

## Supplemental Tests (2026-05-28) — Full managed-settings.json e2e

Tested deployment of complete managed-settings.json with all 3 hooks
(git-guard, pii-guard, audit-logger) and 29 deny rules.

### managed-settings.json deployment

| # | Test | Result |
|---|---|---|
| 1 | JSONC syntax validates | ✅ |
| 2 | Deployed at `/etc/claude-code/managed-settings.json` (root:root 0644) | ✅ |
| 3 | claude reads file (verified via strace) | ✅ |
| 4 | 29 deny rules registered as `policySettings` (verified via --debug-file) | ✅ |
| 5 | 3 hook events registered (UserPromptSubmit, PreToolUse, PostToolUse) | ✅ |
| 6 | Env vars from managed available to subprocess | ✅ |

### End-to-end with managed-settings only

| # | Test | Result |
|---|---|---|
| 1 | Bedrock baseline (`claude -p "say PONG"`) | ✅ PONG |
| 2 | Managed deny `Bash(curl:*)` blocks curl | ✅ |
| 3 | pii-guard.sh blocks credit card in prompt | ✅ |
| 4 | git-guard.sh blocks unauthorized git remote add | ✅ |
| 5 | Normal command (`echo`) passes through | ✅ |
| 6 | audit-logger.sh writes to `/var/log/claude-code/audit.jsonl` | ✅ |

### test-controls.sh (from maintenance-schedule.md)

| # | Test | Result |
|---|---|---|
| 1 | git-guard blocks unauthorized remote | ✅ |
| 2 | pii-guard blocks credit card | ✅ |
| 3 | pii-guard blocks AWS key | ✅ |
| 4 | pii-guard allows clean prompt | ✅ |
| 5 | audit-logger writes 1 entry | ✅ |
| 6 | DISABLE_UPDATES blocks `claude update` | ✅ |
| 7 | Bedrock connectivity | ✅ |

**RESULT: 7/7 PASS**

### drift-check.sh (from operations-runbook.md)

| # | Test | Result |
|---|---|---|
| 1 | Passes when no change | ✅ |
| 2 | Detects managed file modification | ✅ |
| 3 | Detects hook ownership change | ✅ |

### logrotate config

| # | Test | Result |
|---|---|---|
| 1 | logrotate -d validates config | ✅ (after fixing same-line comments — Issue 10) |
| 2 | Manual rotation (chattr -a → copy → truncate → chattr +a) | ✅ |
| 3 | append-only enforced after rotation | ✅ (user `> file` blocked) |
| 4 | audit hook continues writing post-rotation | ✅ |

### Bugs found and fixed during testing

| Bug | File | Fix |
|---|---|---|
| logrotate same-line comments break parser | logrotate-claude-code.conf | Move comments to own line |
| chattr +a blocks logrotate rename and truncate | logrotate-claude-code.conf | Add prerotate/postrotate to toggle chattr |
| User settings env override managed | (process gap) | Document in deployment-guide + known-issues |

---

## macOS Tests (2026-05-28) — local Mac (macOS 26.5 + APFS)

Tested on a real macOS machine with claude-code 2.1.154 installed.

### chflags MCP lock test

| # | Test | Result |
|---|---|---|
| 1 | `chflags uchg test.json` blocks overwrite (`> file`) | ✅ |
| 2 | `chflags uchg` blocks append (`>> file`) | ✅ |
| 3 | `chflags uchg` blocks `rm` | ✅ |
| 4 | `chflags uchg` blocks `mv -f` overwrite | ✅ |
| 5 | `chflags uchg` does NOT affect sibling files in same dir | ✅ |
| 6 | **`chflags uchg ~/.claude.json` blocks `claude mcp add`** (EPERM) | ✅ |
| 7 | `chflags uchg` blocks `jq + mv` write-back pattern | ✅ |
| 8 | `chflags uchg` blocks `python json.dump` | ✅ |
| 9 | `chflags uchg` blocks `sed -i ''` | ✅ |
| 10 | `chflags uchg` blocks `tee` | ✅ |
| 11 | `chflags uchg` removable by user without sudo | ⚠ Yes (limitation) |
| 12 | `sudo chflags schg` blocks `chflags noschg` from non-root user | ✅ |
| 13 | Original `~/.claude.json` content unchanged after all tests | ✅ |

**Conclusion**: `chflags schg` (system immutable) is the correct macOS equivalent
of Linux `chattr +i` for enterprise deployment, NOT `chflags uchg`.

The kit's deployment guide updated to use `sudo chflags schg` on macOS.
