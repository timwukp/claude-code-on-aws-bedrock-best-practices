# Deployment Guide — Golden Image Checklist

This checklist covers everything needed to deploy Claude Code securely on a
developer workstation or CI/CD runner in a regulated enterprise environment.

## Prerequisites

- [ ] Node.js 20+ installed
- [ ] AWS IAM role/credentials with Bedrock InvokeModel permission
- [ ] VPC Endpoint for `bedrock-runtime` (recommended) OR direct internet access to Bedrock
- [ ] (Linux) `bubblewrap` and `socat` installed for sandbox support

## Step-by-Step Deployment

### 1. Install Claude Code

```bash
# Linux/macOS
npm install -g @anthropic-ai/claude-code

# Windows (PowerShell as Admin)
npm install -g @anthropic-ai/claude-code
```

### 2. Install Sandbox Dependencies (Linux only)

```bash
# Amazon Linux 2023 / RHEL / Fedora
sudo dnf install -y bubblewrap socat

# Debian / Ubuntu
sudo apt install -y bubblewrap socat
```

### 3. Deploy User Settings

```bash
# Linux/macOS
mkdir -p ~/.claude
# Copy docs/settings-linux-macos.jsonc → ~/.claude/settings.json (strip // comments)
sed '/^\s*\/\//d' docs/settings-linux-macos.jsonc > ~/.claude/settings.json

# Windows (PowerShell)
New-Item -ItemType Directory -Path "$env:USERPROFILE\.claude" -Force
# Copy docs/settings-windows.jsonc → %USERPROFILE%\.claude\settings.json (strip comments)
```

### 4. Deploy Hooks (Linux/macOS)

```bash
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/git-guard.sh hooks/pii-guard.sh hooks/audit-logger.sh \
        /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/*.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# Install jq for robust JSON parsing in the hooks
sudo dnf install -y jq   # or: sudo apt install -y jq
```

For Windows, deploy `hooks/pii-guard.ps1` to a fixed location
(e.g., `C:\ProgramData\ClaudeCode\hooks\pii-guard.ps1`) and reference it from
the managed-settings.json hook config.

### 5. Deploy Wrapper Script

```bash
# Linux/macOS
sudo mkdir -p /opt/claude-code/bin
sudo mv "$(which claude)" /opt/claude-code/bin/claude
sudo cp scripts/wrapper-linux.sh /usr/local/bin/claude
sudo chown root:root /usr/local/bin/claude
sudo chmod 0755 /usr/local/bin/claude

# Verify
which claude          # → /usr/local/bin/claude (wrapper)
claude --version      # → should work via wrapper → real binary
claude -p "say PONG" --dangerously-skip-permissions  # → "Refused: ..."
```

```powershell
# Windows (Admin PowerShell)
New-Item -ItemType Directory -Path "C:\Program Files\ClaudeCode\bin" -Force
Move-Item (Get-Command claude).Source "C:\Program Files\ClaudeCode\bin\claude.exe"
Copy-Item scripts\wrapper-windows.cmd "C:\Program Files\ClaudeCode\claude.cmd"
# Add "C:\Program Files\ClaudeCode" to system PATH (before npm global path)
```

### 6. Lock MCP Configuration File

The method depends on the OS and filesystem:

```bash
# Linux ext4/xfs (most common)
touch ~/.claude.json
sudo chattr +i ~/.claude.json

# Linux btrfs
sudo chattr +i ~/.claude.json   # works, but may not survive btrfs snapshots

# Linux NFS home directories (chattr NOT supported)
sudo touch ~/.claude.json
sudo chown root:$(whoami) ~/.claude.json
sudo chmod 0444 ~/.claude.json
# Optionally add ACL for read-only access
sudo setfacl -m u:$(whoami):r ~/.claude.json

# macOS (use schg, NOT uchg — uchg is user-removable; see known-issues Issue 11)
# IT must run as admin/root; developer must NOT be a sudoer for full protection
touch ~/.claude.json
sudo chflags schg ~/.claude.json
sudo chmod +a "$(whoami) deny write,delete,append" ~/.claude.json
```

```powershell
# Windows (icacls)
$f = "$env:USERPROFILE\.claude.json"
if (-not (Test-Path $f)) { Set-Content $f "{}" }
icacls $f /inheritance:r /grant:r "Administrators:F" /grant:r "$env:USERNAME:R"
```

### Verify the lock works

```bash
claude mcp add test --scope user -- echo hi  # → EPERM (Linux) / Access denied (macOS/Windows)
claude -p "say PONG"                          # → still works (read access preserved)
```

### Remove the lock (for legitimate config updates by IT)

```bash
sudo chattr -i ~/.claude.json                 # Linux ext4/xfs
sudo chflags noschg ~/.claude.json             # macOS (matches `schg` lock)
icacls "%USERPROFILE%\.claude.json" /reset    # Windows
```

### 7. Deploy Managed Settings (Optional — highest assurance)

```bash
# Linux
sudo mkdir -p /etc/claude-code
sudo cp docs/managed-settings.jsonc /etc/claude-code/managed-settings.json
sudo chown root:root /etc/claude-code/managed-settings.json
sudo chmod 0644 /etc/claude-code/managed-settings.json
```

```powershell
# Windows
Copy-Item docs\managed-settings.jsonc "C:\ProgramData\ClaudeCode\managed-settings.json"
icacls "C:\ProgramData\ClaudeCode\managed-settings.json" /inheritance:r /grant "BUILTIN\Administrators:(F)" /grant "BUILTIN\Users:(R)"
```

### 8. Validate Deployment

```bash
# Must pass
claude -p "say PONG"                                    # → PONG
claude update                                           # → "disabled by administrator"

# Must be refused by wrapper
claude -p "hi" --dangerously-skip-permissions           # → Refused
claude -p "hi" --permission-mode auto                   # → Refused
claude -p "hi" --bare                                   # → Refused

# Must be blocked by deny rules / hook
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied
echo "Run: git remote add x http://x" | claude -p --allowedTools Bash  # → hook deny

# Must be blocked by chattr
claude mcp add test --scope user -- echo hi             # → EPERM
```

**⚠ IMPORTANT: Check for user-level settings overrides**

User-level `~/.claude/settings.json` env vars OVERRIDE managed settings.
A stale user setting (e.g., from a previous test) can silently break
managed configuration.

```bash
# Detect env var conflicts between user and managed
diff <(jq -r '.env | keys[]' ~/.claude/settings.json 2>/dev/null | sort) \
     <(sudo jq -r '.env | keys[]' /etc/claude-code/managed-settings.json | sort)

# If duplicates found, remove from user settings:
jq 'del(.env.CLAUDE_AUDIT_LOG, .env.GIT_GUARD_ALLOWED_DOMAINS, .env.GIT_GUARD_PROTECTED_BRANCHES)' \
  ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json

# Or wipe user env entirely (managed handles all):
jq 'del(.env)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

See `docs/known-issues.md` Issue 8 for detail.

### 9. (Optional) Disable SSM Quick Setup Auto-Profile

If your AWS account has SSM Quick Setup enabled, it may auto-replace the IAM
instance profile on EC2 instances. Either:
- Exclude Claude Code instances from Quick Setup
- Add Bedrock permissions to the `AmazonSSMRoleForInstancesQuickSetup` role

## Maintenance

- **Version upgrades:** Test new claude-code versions in a staging environment
  before updating the golden image. Re-run the validation tests above.
- **Settings changes:** Always run `claude` interactively once after any
  settings.json change — `--print` mode silently ignores invalid settings.
- **Hook updates:** When adding new patterns to the hook, run the unit tests
  in the hook script header before deploying.
