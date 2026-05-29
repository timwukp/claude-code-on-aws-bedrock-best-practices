# Maintenance Schedule — Claude Code Security Controls

## Version Upgrade Testing

### Trigger: Anthropic releases a new Claude Code version

| Step | Action | Owner | SLA |
|---|---|---|---|
| 1 | Monitor release notes (https://code.claude.com/docs/en/whats-new) | IT Ops | Within 24h of release |
| 2 | Deploy new version to **staging** EC2 (not production) | IT Ops | Within 48h |
| 3 | Run automated test suite (see below) | Security team | Within 72h |
| 4 | Review results — any control regressions? | Security Lead | Within 96h |
| 5 | If pass: approve for production rollout | CISO | Within 1 week |
| 6 | If fail: document regression, hold on current version | Security Lead | Immediate |

### Automated test suite (run on each version upgrade)

```bash
# test-controls.sh — run on staging EC2 after version upgrade
set -e

echo "=== 1. Deny rules still work ==="
echo '{"tool_name":"Bash","tool_input":{"command":"curl http://example.com"}}' | \
  /usr/local/etc/claude-code/hooks/git-guard.sh 2>/dev/null
# Should exit 0 (git-guard doesn't care about curl; deny rule handles it)

echo "=== 2. git-guard blocks unauthorized push ==="
echo '{"tool_name":"Bash","tool_input":{"command":"git remote add evil https://evil.com/repo"}}' | \
  GIT_GUARD_ALLOWED_DOMAINS="gitlab.company.com" /usr/local/etc/claude-code/hooks/git-guard.sh 2>/dev/null
[[ $? -eq 2 ]] && echo "PASS" || echo "FAIL: git-guard not blocking"

echo "=== 3. pii-guard blocks credit card ==="
echo '{"hook_event_name":"UserPromptSubmit","prompt":"card 4111-1111-1111-1111"}' | \
  /usr/local/etc/claude-code/hooks/pii-guard.sh 2>/dev/null
[[ $? -eq 2 ]] && echo "PASS" || echo "FAIL: pii-guard not blocking"

echo "=== 4. Wrapper blocks bypass flag ==="
result=$(claude -p "hi" --dangerously-skip-permissions 2>&1)
echo "$result" | grep -q "Refused" && echo "PASS" || echo "FAIL: wrapper not blocking"

echo "=== 5. DISABLE_UPDATES works ==="
result=$(claude update 2>&1)
echo "$result" | grep -q "disabled" && echo "PASS" || echo "FAIL: updates not disabled"

echo "=== 6. Bedrock connectivity ==="
result=$(claude -p "say PONG" 2>&1)
echo "$result" | grep -q "PONG" && echo "PASS" || echo "FAIL: Bedrock unreachable"

echo "=== All tests complete ==="
```

## Periodic Reviews

| Frequency | What to review | Owner |
|---|---|---|
| **Weekly** | Audit log volume + P3 event count | Security analyst |
| **Monthly** | False positive rate from pii-guard | Security team + dev leads |
| **Monthly** | New Claude Code features that may need new controls | Security Lead |
| **Quarterly** | Full control effectiveness re-test (run test suite) | Security team |
| **Quarterly** | Credential rotation | IT Ops |
| **Semi-annually** | Red team exercise against Claude Code controls | External pen test team |
| **Annually** | Full risk assessment update | CISO |

## Pattern Update Process

### When to update hook patterns (pii-guard, git-guard)

- New PII type identified (e.g., new national ID format)
- New credential format (e.g., new cloud provider key pattern)
- False positive rate exceeds 5% (pattern too broad)
- New git hosting service added to enterprise (update allowlist)

### Change process

```
1. Developer/security team identifies need for pattern change
2. Create PR with:
   - Updated pattern in hook script
   - Unit test proving the new pattern works
   - Unit test proving no regression on existing patterns
3. Security Lead reviews and approves
4. Deploy to staging, run full test suite
5. Deploy to production via MDM/config management
6. Monitor false positive rate for 1 week
```

## Responsibility Matrix (RACI)

| Activity | Security Lead | IT Ops | Dev Lead | CISO |
|---|---|---|---|---|
| Version upgrade testing | R | A | C | I |
| Hook pattern updates | R | A | C | I |
| Incident response (P1) | R | A | C | A |
| Incident response (P2/P3) | A | R | I | I |
| Quarterly re-test | R | A | I | I |
| Annual risk assessment | A | C | C | R |
| Developer onboarding | I | R | A | I |
| Emergency disable | A | R | I | A |

R=Responsible, A=Accountable, C=Consulted, I=Informed
