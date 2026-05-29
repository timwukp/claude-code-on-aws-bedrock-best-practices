# Platform Compensating Controls

This kit's defaults assume Linux on local ext4/xfs. Other platforms have known
gaps. Each section gives a tested compensating control with verification steps.

---

## NFS home directories

**Gap.** `chattr +i` and `chattr +a` are no-ops on NFS-mounted filesystems, so
`~/.claude.json` cannot be made immutable to block `claude mcp add`, and the
audit log fallback under `~/.claude/audit-fallback.jsonl` cannot be made
append-only.

**Compensation — push config from SSM, not user-writable home.**

1. Store the canonical `~/.claude.json` content in SSM Parameter Store:
   `/claude-code/user-claude-json`.
2. At each session start, the wrapper sources `/etc/claude-code/refresh-user-config.sh`
   which fetches the parameter and writes `~/.claude.json` as `0444` owned by
   root via a setuid helper. NFS clients honour the mode bits.
3. Audit fallback path moves to a local-disk tmpfs: set
   `CLAUDE_AUDIT_LOG=/var/log/claude-code/audit.jsonl` (always local) and rely
   on the **fail-closed** behaviour of the rewritten `audit-logger.sh` (v2.0.0).
   If the local disk is unwritable AND CloudWatch is unreachable, the hook
   exits 2 — the user gets blocked rather than silently logging to a tampered
   path.

**Verify.**
```bash
# After deploy:
[[ ! -w ~/.claude.json ]] && echo "config not user-writable" || echo "FAIL"
mount | grep $HOME | grep -q nfs && echo "NFS detected — using SSM fallback"
```

---

## Windows `--print` mode

**Gap.** The `UserPromptSubmit` hook does not fire when claude is invoked with
`--print` on Windows (verified, README:183). PII can reach the model on that
path before any local hook gets a chance to inspect it.

**Compensation — Bedrock Guardrails as required server-side filter.**

1. Create a Bedrock Guardrail with PII filtering for the same data classes the
   local PII guard catches (CC, AWS keys, JWT, NRIC, …).
2. Reference the Guardrail ARN in `managed-settings.json`:
   ```jsonc
   "env": {
     "AWS_BEDROCK_GUARDRAIL_ID": "abc12345",
     "AWS_BEDROCK_GUARDRAIL_VERSION": "DRAFT"
   }
   ```
3. Add a startup self-check (run as part of the wrapper) that calls
   `bedrock:GetGuardrail` and refuses to launch claude if the Guardrail is
   missing, in DRAFT-only mode, or has fewer than the expected filter classes.
4. Add a CloudWatch alarm on `BedrockGuardrails:Intervened` count — sustained
   non-zero means the local PII guard is missing patterns.

**Verify.**
```powershell
# Confirm guardrail is active before allowing claude to run:
aws bedrock get-guardrail --guardrail-identifier $env:AWS_BEDROCK_GUARDRAIL_ID `
  --query 'status' --output text  # must be READY
```

---

## macOS

**Gap 1.** `chflags uchg` is removable by the owning user; only `chflags schg`
(system immutable) plus the user not being a sudoer prevents removal.

**Gap 2.** Most corporate Macs leave the developer with sudo, defeating
`schg`-only protection.

**Compensation — MDM-enforced non-sudoer + schg.**

1. Use Jamf / Intune / Mosyle to ensure `claude-code-users` group members are
   **not** in `admin`, `wheel`, or `everyone`-passwordless sudoers entries.
   The MDM policy must apply at every logon (drift recovery).
2. Apply `schg`:
   ```bash
   sudo chflags schg ~/.claude.json
   sudo chflags schg /etc/claude-code/managed-settings.json
   ```
3. Drift watcher (this kit's `drift-watcher.sh`) detects `chflags noschg`
   attempts via `fswatch` and alerts within ~60ms (verified, see
   `tests/results/`).

**Verify.**
```bash
ls -lO ~/.claude.json | grep -q 'schg' && echo "schg ok" || echo "FAIL: missing schg"
groups $(whoami) | grep -qE '\b(admin|wheel)\b' && echo "FAIL: user is admin" || echo "non-admin ok"
```

---

## Containerised / Kubernetes deployments

**Gap.** No persistent home for `chattr +i`; ephemeral pods churn drift state
and audit chain on every restart.

**Compensation — config from ConfigMap (read-only mount), audit chain
externalised, drift watcher omitted.**

1. Mount `managed-settings.json` from a ConfigMap as `readOnly: true`. The
   pod cannot write to it regardless of in-container UID.
2. Mount the hook scripts from a ConfigMap (or build into the image) at a
   non-writable path.
3. The audit chain state (`/var/lib/claude-code/audit-state/last-hmac`) is
   externalised to DynamoDB via a small wrapper around `audit-logger.sh`. Each
   pod reads the cluster-global last hash before computing its event so the
   chain spans pods.
4. Skip drift-watcher (no on-disk drift to detect — config is RO via the
   mount). Replace with a Kubernetes admission webhook that rejects pods whose
   ConfigMap content hash does not match the approved baseline.

This pattern is sketched in `terraform/k8s-baseline/` (left as a follow-up).

---

## Summary matrix

| Platform / setup            | Default control     | Compensating control                  | Verified |
|---|---|---|---|
| Linux ext4/xfs, local home  | chattr +i, +a       | (none needed)                         | ✅ |
| Linux NFS home              | none (chattr no-op) | SSM-pushed RO config + fail-closed    | ☑ design |
| macOS, sudoer user          | chflags uchg        | MDM non-sudoer + schg + drift watcher | ☑ design |
| macOS, non-sudoer           | chflags schg        | (matches default Linux behaviour)     | ✅ |
| Windows native              | UserPromptSubmit gap| Bedrock Guardrails (mandatory)        | ☑ design |
| Kubernetes pod              | n/a (ephemeral)     | ConfigMap RO + DynamoDB chain state   | ☑ design |
