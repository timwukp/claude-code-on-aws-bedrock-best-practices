# Disaster Recovery — Claude Code on AWS Bedrock

Defines fallback procedures when components of the Claude Code stack fail.
Aligns with MAS TRM 8.4 (BCP/DR for technology services).

## Failure Modes & Response

| Failure | Detection | RTO | Response |
|---|---|---|---|
| **Bedrock API outage (regional)** | Claude returns API errors / timeout | 0 (immediate) | Fail-closed: developers cannot use Claude. Switch to alternate region (see below). |
| **VPC Endpoint failure** | DNS resolves but connection times out | 1 hour | Verify VPCE health; rebuild VPCE if needed; temporarily route via public endpoint with HTTPS_PROXY |
| **IAM role replaced (e.g., SSM Quick Setup)** | Bedrock returns AccessDeniedException | 15 min | Re-attach `claude-code-test-profile` (see operations-runbook.md); investigate why replacement happened |
| **Hook script corruption / missing** | Claude Code error on every tool call | 30 min | Restore from version control; verify file ownership and permissions |
| **managed-settings.json corruption** | `claude --print` silently runs without controls | 1 hour | Run integrity check; restore from version control; force all sessions to restart |
| **Bedrock Guardrails service outage** | No PII filter on output | 0 | Document in audit log; rely on sandbox + hooks; consider temporarily restricting Claude usage |
| **Wrapper script binary missing** | `claude: command not found` | 30 min | Restore wrapper from version control; verify symlink/PATH |
| **Audit log volume full** | Disk space alert | 4 hours | logrotate should auto-handle; if disk full, rotate manually + investigate volume |
| **Anthropic API key/auth issue** | Bedrock returns 401/403 | 1 hour | Switch IAM role; if Anthropic-managed, contact Anthropic |
| **Single developer machine compromise** | Suspicious audit log entries | 1 hour | See incident-response.md P1/P2 procedures |

## Multi-Region Failover

### Pre-configured backup region

```jsonc
// In managed-settings.json env block, define backup region
"AWS_REGION": "us-east-1",                          // primary
"AWS_REGION_FALLBACK": "us-west-2",                 // backup
"ANTHROPIC_BEDROCK_BASE_URL": "https://bedrock-runtime.us-east-1.amazonaws.com"
```

### Manual failover script

```bash
#!/bin/bash
# /usr/local/etc/claude-code/scripts/failover-region.sh
# Run when primary region is down

set -euo pipefail
NEW_REGION="${1:-us-west-2}"

# Update managed settings
sudo jq --arg r "$NEW_REGION" \
  '.env.AWS_REGION = $r | .env.ANTHROPIC_BEDROCK_BASE_URL = "https://bedrock-runtime." + $r + ".amazonaws.com"' \
  /etc/claude-code/managed-settings.json > /tmp/managed-new.json

sudo mv /tmp/managed-new.json /etc/claude-code/managed-settings.json

echo "Failed over to $NEW_REGION. Notify users to restart Claude Code."
```

## Backup & Restore

### What to back up (in version control)

- `docs/managed-settings.jsonc` — the source of truth
- `hooks/*.sh` and `hooks/*.ps1` — all enforcement scripts
- `scripts/wrapper-*.sh|cmd` — wrapper scripts

### Daily backup of audit logs

```bash
# /etc/cron.daily/claude-audit-backup
#!/bin/bash
DEST="s3://yourcompany-audit-archive/claude-code/$(date +%Y/%m/%d)/"
aws s3 cp /var/log/claude-code/ "$DEST" --recursive --include "*.jsonl*"
```

### Restore procedure

```bash
# 1. Restore managed settings from git
sudo cp /opt/claude-code-config/managed-settings.json /etc/claude-code/managed-settings.json
sudo chmod 0644 /etc/claude-code/managed-settings.json
sudo chown root:root /etc/claude-code/managed-settings.json

# 2. Restore hooks
sudo cp /opt/claude-code-config/hooks/*.sh /usr/local/etc/claude-code/hooks/
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# 3. Restore wrapper
sudo cp /opt/claude-code-config/wrapper-linux.sh /usr/local/bin/claude
sudo chmod 0755 /usr/local/bin/claude

# 4. Verify
claude -p "say PONG"
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied
```

## Business Impact & Tier Classification

| Component | Tier | Justification |
|---|---|---|
| Claude Code (developer productivity tool) | Tier 3 (degraded mode acceptable) | Developers can fall back to manual coding |
| audit-logger.sh + audit log retention | Tier 2 (regulatory requirement) | SOX/MAS require audit trail; cannot lose retention |
| Bedrock Guardrails | Tier 2 | Compensating control for Windows UserPromptSubmit limitation |
| pii-guard.sh + git-guard.sh | Tier 2 | Critical preventive controls |
| managed-settings.json + wrapper | Tier 1 (critical) | Without these, all controls advisory-only |

## RTO/RPO Targets

| Component | RTO | RPO |
|---|---|---|
| Hook scripts / wrapper / managed-settings | 30 min | 0 (always in version control) |
| Audit log accessibility | 4 hours | 24 hours (daily S3 backup) |
| Bedrock connectivity (with failover) | 1 hour | N/A (stateless) |
| Full Claude Code service | 4 hours | N/A (no state to lose) |

## Test Frequency

DR procedures must be exercised:
- **Quarterly**: tabletop exercise (walkthrough of each scenario)
- **Semi-annually**: actual failover test in staging environment
- **Annually**: full DR drill including audit log restore from S3

## Escalation Matrix

| Scenario | Decision authority |
|---|---|
| Region failover (planned maintenance) | IT Ops Lead |
| Region failover (incident) | CISO + IT Ops Lead |
| Emergency disable Claude Code | CISO |
| Restore from backup after corruption | Security Lead |
| Extending retention beyond policy | DPO + CISO |
