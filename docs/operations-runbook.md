# Operations Runbook — Claude Code Lifecycle Management

## Developer Onboarding

### New developer joins the team

```bash
# 1. IT provisions the workstation with golden image (includes all hooks + wrapper)
# 2. Verify installation
claude --version                    # confirm correct version
claude -p "say PONG"               # confirm Bedrock connectivity
claude -p "hi" --dangerously-skip-permissions  # confirm wrapper blocks

# 3. Lock MCP config
sudo chattr +i /home/<user>/.claude.json

# 4. Developer signs AI Usage Policy (mandatory before first use)
# Policy covers: no PII in prompts, no credential pasting, report false positives
```

### Checklist
- [ ] Workstation has managed-settings.json deployed
- [ ] Wrapper script is the only `claude` on PATH
- [ ] Hooks (git-guard, pii-guard, audit-logger) deployed and root-owned
- [ ] ~/.claude.json locked with chattr +i
- [ ] bubblewrap + socat + jq installed (Linux)
- [ ] Developer signed AI Usage Policy
- [ ] Developer added to SIEM monitoring group
- [ ] VPN/network configured to route Bedrock traffic through VPC Endpoint

## Developer Offboarding

### When a developer leaves

```bash
# 1. Revoke AWS credentials (if any personal credentials exist)
aws iam delete-access-key --user-name <user> --access-key-id <key>

# 2. Review last 30 days of audit logs for the user
grep '"user":"<username>"' /var/log/claude-code/audit.jsonl | tail -100

# 3. Check for any unauthorized remotes added (if chattr was somehow bypassed)
find /home/<user> -name ".git" -exec git -C {} remote -v \;

# 4. Remove user's Claude Code session data
rm -rf /home/<user>/.claude/

# 5. Remove from SIEM monitoring group
# 6. Archive audit logs for retention period (7 years for banking)
```

## Emergency Disable

### Kill switch — disable Claude Code for ALL users immediately

```bash
# Option A: Managed settings — make sandbox fail (blocks startup)
sudo tee /etc/claude-code/managed-settings.json <<'EOF'
{"sandbox": {"enabled": true, "failIfUnavailable": true}}
EOF
# On Linux without bubblewrap, this prevents Claude from starting

# Option B: Wrapper — reject everything
sudo tee /usr/local/bin/claude <<'EOF'
#!/bin/bash
echo "Claude Code is temporarily disabled by IT Security. Contact helpdesk." >&2
exit 1
EOF
sudo chmod 755 /usr/local/bin/claude

# Option C: Network — block Bedrock endpoint
# Add to VPC security group or network ACL:
# Deny outbound TCP 443 to bedrock-runtime.*.amazonaws.com
```

### Re-enable after emergency

```bash
# 1. Root cause resolved
# 2. Controls verified
# 3. Restore original managed-settings.json from version control
# 4. Restore original wrapper script
# 5. Notify developers
```

## Credential Rotation

### Scheduled (quarterly)

- [ ] Rotate Bedrock IAM role credentials (if using access keys, not instance profile)
- [ ] Review and rotate any API keys in Guardrail configurations
- [ ] Verify VPC Endpoint is still correctly configured
- [ ] Confirm managed-settings.json hasn't drifted from version control

### Emergency (after incident)

```bash
# 1. Identify exposed credentials from audit log
# 2. Rotate immediately:
aws iam create-access-key --user-name <user>    # create new
aws iam delete-access-key --user-name <user> --access-key-id <old-key>  # delete old

# 3. If IAM role was compromised:
aws iam update-assume-role-policy  # restrict trust policy
# 4. Force all active sessions to re-authenticate
```

## Configuration Drift Detection

### Weekly automated check

```bash
#!/bin/bash
# drift-check.sh — run via cron weekly
EXPECTED_HASH="<sha256 of golden managed-settings.json>"
ACTUAL_HASH=$(sha256sum /etc/claude-code/managed-settings.json | awk '{print $1}')

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
  echo "ALERT: managed-settings.json has drifted from golden image" | \
    mail -s "Claude Code Config Drift" security-team@company.com
fi

# Check hooks are still root-owned and executable
for hook in /usr/local/etc/claude-code/hooks/*.sh; do
  owner=$(stat -c '%U' "$hook")
  if [[ "$owner" != "root" ]]; then
    echo "ALERT: Hook $hook owned by $owner (should be root)"
  fi
done
```
