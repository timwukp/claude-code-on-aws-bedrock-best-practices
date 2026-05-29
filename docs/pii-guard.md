# PII & Secrets Guard Hook

Prevents sensitive data (PII, credentials, secrets) from being sent to the AI model
by scanning prompts and tool inputs **before** they reach Bedrock/Claude.

## Architecture

```
User types prompt ──→ [UserPromptSubmit hook] ──→ BLOCK if PII detected
                                                  │
                                                  ↓ (clean)
Claude generates tool call ──→ [PreToolUse hook] ──→ BLOCK if secrets in tool input
                                                     │
                                                     ↓ (clean)
                                              Tool executes normally
```

Two hook events work together:
- **`UserPromptSubmit`** — fires when user submits a prompt, BEFORE Claude sees it
- **`PreToolUse`** (matcher `*`) — fires before ANY tool executes, scans tool_input

## What It Detects

| Pattern | Examples |
|---|---|
| Credit cards | `4111-1111-1111-1111`, `5500 0000 0000 0004` |
| AWS Access Keys | `AKIAIOSFODNN7EXAMPLE` |
| AWS Secret Keys | 40-char base64 strings in quotes |
| API key assignments | `api_key=sk-...`, `auth_token: "..."` |
| Private keys | `-----BEGIN RSA PRIVATE KEY-----` |
| JWT tokens | `eyJhbG...` (3-segment base64url) |
| Database connection strings | `postgres://user:pass@host/db` |
| Password assignments | `password=...`, `pwd: "..."` |
| Singapore NRIC/FIN | `S1234567D`, `T0123456A` |
| Email addresses | `user@example.com` |
| International phone numbers | `+65 9123 4567` |
| Passport numbers | `E12345678` |
| GitHub/GitLab tokens | `ghp_...`, `glpat-...` |
| Slack tokens | `xoxb-...` |
| Hex secrets (32+ chars) | `a1b2c3d4e5f6...` |

## Installation

### Linux / macOS

```bash
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/pii-guard.sh /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/pii-guard.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/pii-guard.sh
```

### Windows

```powershell
Copy-Item hooks\pii-guard.ps1 "C:\Program Files\ClaudeCode\hooks\"
```

### Register in settings.json

```jsonc
{
  "hooks": {
    "UserPromptSubmit": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "/usr/local/etc/claude-code/hooks/pii-guard.sh"
      }]
    }],
    "PreToolUse": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "/usr/local/etc/claude-code/hooks/pii-guard.sh"
      }]
    }]
  }
}
```

For Windows, use `"shell": "powershell"` and point to the `.ps1` file.

## Test Results (2026-05-28, Linux EC2, claude-code 2.1.152)

### Unit tests: 9/9 pass

| # | Input | Expected | Actual |
|---|---|---|---|
| 1 | Credit card in prompt | exit 2 (BLOCK) | exit 2 ✅ |
| 2 | AWS key in tool input | exit 2 | exit 2 ✅ |
| 3 | Private key in file write | exit 2 | exit 2 ✅ |
| 4 | JWT token in prompt | exit 2 | exit 2 ✅ |
| 5 | Password assignment in file | exit 2 | exit 2 ✅ |
| 6 | SG NRIC in prompt | exit 2 | exit 2 ✅ |
| 7 | Normal code prompt | exit 0 (ALLOW) | exit 0 ✅ |
| 8 | Normal `npm test` command | exit 0 | exit 0 ✅ |
| 9 | DB connection string | exit 2 | exit 2 ✅ |

### End-to-end tests: 3/3 pass

| # | Test | Result |
|---|---|---|
| 1 | `claude -p "My card is 4532-1234-5678-9012"` | Empty output (blocked before model) ✅ |
| 2 | `claude -p "Use AKIAIOSFODNN7EXAMPLE"` | Empty output (blocked) ✅ |
| 3 | `claude -p "say only PONG-CLEAN"` | `PONG-CLEAN` (passed through) ✅ |

## Customization

Add or remove patterns in the `patterns=()` array. Each entry format:
```
"LABEL:::EXTENDED_REGEX"
```

Use POSIX ERE syntax (no `\s` — use `[ ]` or `[[:space:]]` instead).

## False Positive Handling

The hook may flag legitimate content (e.g., test credit card numbers in unit tests,
example emails in documentation). Options:

1. **Allowlist specific files** — add path checks before scanning
2. **Reduce pattern sensitivity** — remove patterns like `EMAIL_ADDRESS` if too noisy
3. **Environment variable bypass** — check `$CLAUDE_PII_GUARD_DISABLED=1` for dev environments
