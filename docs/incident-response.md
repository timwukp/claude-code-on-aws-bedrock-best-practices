# Incident Response Playbook — Claude Code Security Events

## Severity Levels

| Level | Trigger | Response Time | Escalation |
|---|---|---|---|
| **P1 Critical** | Confirmed data exfiltration, credential leak to external | 15 min | CISO + Legal + DPO |
| **P2 High** | Bypass attempt detected, unauthorized push succeeded | 1 hour | Security Lead + Team Lead |
| **P3 Medium** | PII guard triggered, deny rule fired | 4 hours | Security team review |
| **P4 Low** | False positive, configuration drift detected | Next business day | IT operations |

## Alert Channels

| Event | Channel | Tool |
|---|---|---|
| PII guard blocks a prompt/tool | SIEM alert + Slack #security-alerts | audit-logger.sh → SIEM webhook |
| git-guard blocks unauthorized push | SIEM alert + email to team lead | audit-logger.sh |
| Wrapper blocks bypass flag | SIEM alert | wrapper script stderr → syslog |
| Multiple P3 events from same user (>5/hour) | Auto-escalate to P2 | SIEM correlation rule |
| managed-settings.json modified | P1 alert (tampering) | ConfigChange hook or file integrity monitor |

## Response Procedures

### P1: Confirmed Data Exfiltration

```
1. CONTAIN (0-15 min)
   - Revoke user's AWS credentials: aws iam delete-access-key
   - Disable user's Claude Code: chattr +i ~/.claude/settings.json (corrupt it)
   - Block user's network access if needed

2. ASSESS (15-60 min)
   - Review audit-logger.sh JSONL for the session
   - Identify what data was exposed (git push target, curl destination)
   - Check git reflog for what was pushed
   - Review Bedrock CloudTrail for API call history

3. REMEDIATE (1-4 hours)
   - Rotate all credentials that may have been exposed
   - If code was pushed externally: DMCA takedown + legal notification
   - If PII was leaked: DPO notification within 72 hours (GDPR/PDPA)

4. RECOVER (1-7 days)
   - Root cause analysis
   - Update hook patterns if bypass method identified
   - Re-test all controls
   - Update this playbook
```

### P2: Bypass Attempt Detected

```
1. CONTAIN (0-1 hour)
   - Review if the bypass succeeded or was blocked
   - If blocked: log and monitor (may be accidental)
   - If succeeded: escalate to P1

2. ASSESS
   - Was it --dangerously-skip-permissions? (wrapper should block)
   - Was it a new bypass method not covered by wrapper?
   - Was it a direct invocation of /opt/claude-code/bin/claude?

3. REMEDIATE
   - If new bypass: update wrapper script immediately
   - If direct binary access: restrict /opt/claude-code/bin/ permissions
   - Brief the user (may be unintentional)
```

### P3: PII Guard / Deny Rule Triggered

```
1. REVIEW (within 4 hours)
   - Check audit log: was it a false positive?
   - If false positive: document and consider pattern adjustment
   - If true positive: verify data did NOT reach the model

2. ACTION
   - If data reached model (UserPromptSubmit hook failed on Windows):
     check Bedrock CloudTrail for the API call content
   - If blocked successfully: no further action, log for metrics

3. TREND ANALYSIS (weekly)
   - Review P3 frequency per user
   - High frequency may indicate: training needed, or patterns too strict
```

## Contact Matrix

| Role | Responsibility | Contact |
|---|---|---|
| Security Lead | Triage P2/P3, coordinate response | [your-security-lead] |
| CISO | P1 decisions, regulatory notification | [your-ciso] |
| DPO | PDPA/GDPR breach notification | [your-dpo] |
| IT Operations | System-level containment | [your-it-ops] |
| Legal | External breach communication | [your-legal] |
| Team Lead | Developer communication | [per-team] |

## Post-Incident Review Template

```markdown
## Incident Report: [ID]
- Date/Time:
- Severity:
- Affected user:
- What happened:
- How it was detected:
- What control failed/succeeded:
- Data impact:
- Root cause:
- Remediation taken:
- Prevention measures added:
- Playbook updates needed:
```

---

## Common Configuration Issues (P3-P4)

### Audit log not rotating / disk filling

**Symptom**: `/var/log/claude-code/audit.jsonl` grows unbounded; disk space alerts.

**Likely causes**:
1. logrotate config syntax error (Issue 10 in known-issues.md)
2. logrotate not handling `chattr +a` (Issue 9)
3. logrotate cron job not running

**Diagnose**:
```bash
sudo logrotate -d /etc/logrotate.d/claude-code     # validate config
sudo lsattr /var/log/claude-code/audit.jsonl       # check chattr state
sudo cat /var/lib/logrotate/logrotate.status | grep claude-code  # last rotation
```

**Fix**: Use the shipped config in `scripts/logrotate-claude-code.conf` (handles chattr correctly).

### Hook fires but writes to wrong log path

**Symptom**: audit log empty despite Claude Code activity. Hook script test
works directly but not via Claude.

**Likely cause**: User-level `~/.claude/settings.json` env block overrides
managed `CLAUDE_AUDIT_LOG` path (Issue 8).

**Diagnose**:
```bash
# Compare user vs managed env keys
diff <(jq -r '.env|keys[]' ~/.claude/settings.json | sort) \
     <(sudo jq -r '.env|keys[]' /etc/claude-code/managed-settings.json | sort)
```

**Fix**: Remove duplicate keys from user settings (see deployment-guide.md Step 8).
