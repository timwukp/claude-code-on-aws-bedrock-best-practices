# On-Call Runbook

When the pager fires for `claude-code-*`, work through the matching section.
Each alarm in `observability/cloudwatch-dashboard.tf` maps to one section here.

---

## `claude-hook-crash-rate` — any crash in 5 min

**What it means.** A hook (pii-guard, git-guard, audit-logger, token-budget)
exited with a non-zero, non-2 code. The wrapper converted it to a block, so
**users are seeing tool calls denied with no policy reason.**

**Investigate.**
1. Pull the offending lines:
   ```
   aws logs filter-log-events --log-group-name /claude-code/hooks \
     --filter-pattern '{ $.status = "crashed" }' \
     --start-time $(date -v-1H +%s)000
   ```
2. The `stderr` field contains the first 300 chars of the failure. Common
   causes:
   - `jq: parse error` — malformed input from a new claude-code version. Pin
     the hook to the new schema or roll back claude-code.
   - `openssl dgst: command not found` — image regression. Reinstall openssl.
   - `permission denied: /var/log/claude-code/audit.jsonl` — disk full or
     someone removed `chattr +a` and changed mode. See drift alarm.

**Mitigate.**
- Set `CLAUDE_AUDIT_FAIL_OPEN=1` in managed-settings as a temporary unblock,
  understanding it disables fail-closed. Page the security lead before doing
  this.

**Resolve.** Fix the underlying issue, push via Terraform, watch the alarm
return to OK.

---

## `claude-hook-timeout-rate` — > 5 timeouts in 5 min

**What it means.** A hook took longer than `CLAUDE_HOOK_TIMEOUT_MS` (default
5000ms). Likely causes: regex catastrophic backtracking on huge input, slow
disk, or a hook accidentally doing network I/O.

**Investigate.**
1. Find the worst-case input from telemetry:
   ```
   aws logs filter-log-events --log-group-name /claude-code/hooks \
     --filter-pattern '{ $.status = "timeout" }'
   ```
2. Look at `event` and `session_id` in the result; the corresponding audit
   line shows the actual command/prompt that triggered it.

**Mitigate.** If a single hook is consistently timing out, raise its specific
timeout via env (`CLAUDE_HOOK_TIMEOUT_MS=10000`) — but only as a holding
action while you fix the regex.

---

## `claude-hook-p99-latency-slo` — p99 > 500ms for 15 min

**SLO defined.** p50 < 100ms, p95 < 200ms, p99 < 500ms.

**Investigate.** Same metric source. Check whether one specific hook is
dragging the percentile up:
```
aws logs insights query --log-group-name /claude-code/hooks \
  --query-string 'fields hook | stats avg(duration_ms), pct(duration_ms, 99) by hook'
```

**Common causes.**
- pii-guard scanning very large prompts. Mitigation: cap prompt size at
  parse time (`head -c 100000`).
- audit-logger doing CloudWatch writes synchronously when `aws` CLI is slow.
  Switch to async fire-and-forget when latency matters more than guaranteed
  delivery (CloudWatch agent picks them up from disk anyway).

---

## `claude-drift-detected` — file changed outside the deploy pipeline

**What it means.** Someone (or some process) modified one of the watched
paths: `/etc/claude-code/managed-settings.json`, the hook directory, or
`/usr/local/bin/claude`.

**Severity.** Treat as **P1** until proven benign.

**Investigate.**
1. Read the drift event:
   ```
   aws logs tail /claude-code/drift --since 10m --format short
   ```
2. The event includes `sha256_before` and `sha256_after`. Recover the new
   content:
   ```
   ssh ${host} 'sudo cat /etc/claude-code/managed-settings.json'
   ```
3. Cross-check against the last Terraform apply. If the new SHA matches a
   recent CI run, this is a legitimate deploy and the alarm is noise (mute
   for 10 min).
4. If no recent deploy explains it, **assume tamper**:
   - Take a forensic copy of the box.
   - Roll back from Terraform (`terraform apply -refresh-only && terraform apply`).
   - Open an incident.

---

## Audit chain broken (manual check from `chain-verify.sh`)

**What it means.** Either:
- A line was edited / deleted / inserted, or
- The HMAC key rotated without the chain being re-anchored, or
- Disk corruption.

**Investigate.**
1. Run `chain-verify.sh` against an offline copy: it prints the line number
   of the first mismatch.
2. If the mismatch is at the line written immediately after a key rotation,
   the rotation procedure was missed; document and re-anchor. Otherwise
   treat as tamper.

**Mitigate.** Audit logs from this host are no longer non-repudiable from the
break point onward. If the host serves a regulated workload, isolate it.

---

## Token budget exhaustion (informational)

**What it means.** A user's session hit the token or call budget configured
by `CLAUDE_TOKEN_BUDGET` / `CLAUDE_CALL_BUDGET`. The hook blocks; user must
start a new session.

**This is not a page** — it's a metric. If a single user trips it >5x/day,
investigate for runaway agent loops. Raise budget via SSM Parameter override
if the workload genuinely needs it.

---

## Bedrock Guardrails intervened (Windows compensation)

**What it means.** A Windows user's `--print` prompt got past the local PII
guard (which doesn't fire in `--print` mode there) and Bedrock Guardrails
caught it server-side. The data didn't reach the model, but it implies our
local hook missed something it should have caught.

**Action.**
1. Pull the redacted Guardrails finding from CloudWatch.
2. Add a corpus row under `tests/pii-corpus/positive/` capturing the pattern.
3. Run `tests/run_pii_corpus.sh` — the new row should fail.
4. Update `hooks/pii-guard.sh` regex; rerun until the corpus passes.
5. Deploy via Terraform.

---

## Wrapper bypass attempted (informational)

If `audit.jsonl` shows a `claude --dangerously-skip-permissions` invocation
that returned exit 1, the wrapper did its job and the user got a refusal.
Look for repeats from the same user — an attempt indicates either user
education needed or possible insider threat.
