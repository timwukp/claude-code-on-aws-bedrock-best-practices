# Known Issues — Claude Code Permission Matcher Bugs & Workarounds

Tested on claude-code 2.1.150 and 2.1.152 (May 2026).

## Issue 1: Bash Matcher Does Not Enforce 3-Token Subcommands

**Affected platform:** Linux / macOS (Bash tool only)
**NOT affected:** Windows (PowerShell tool)

### Symptom

Any deny pattern with 3+ tokens in the command prefix is silently ignored:

```
Bash(git remote add *)     → ❌ does not block
Bash(git remote add:*)     → ❌ does not block
Bash(git remote:*)         → ❌ does not block
Bash(git reset --hard *)   → ❌ does not block
Bash(git reset --hard:*)   → ❌ does not block
```

Only the over-broad `Bash(git:*)` blocks them — but it also blocks `git status`,
`git log`, `git diff`, etc., making it unusable.

### Root Cause

The Bash permission matcher appears to only parse the first two tokens of a command
for pattern matching. The third token onwards is not considered.

### Workaround

Use a **PreToolUse hook** (`hooks/git-guard.sh` in this repo) that receives the
full command string as JSON and applies ERE regex matching. The hook correctly
handles:
- `git -C <dir> remote add ...` (intervening flags)
- `git --git-dir=<path> remote set-url ...`
- `cd <dir> && git remote rename ...` (chained commands)

### Status

- Reported behavior persists across 2.1.150 → 2.1.152 (not fixed by upgrade)
- PowerShell matcher does NOT have this bug (all patterns work with space-asterisk)

---

## Issue 2: `Bash(git push *)` (Space-Asterisk) Does Not Match

**Affected platform:** Linux / macOS
**NOT affected:** Windows (PowerShell)

### Symptom

```
Bash(git push *)           → ❌ does not block `git push origin main`
Bash(git push:*)           → ✅ blocks all push variants
```

### Workaround

Always use colon-asterisk syntax for two-token Bash commands: `Bash(git push:*)`

### Note

The official documentation states `Bash(npm *)` should match "any command starting
with npm" and that `:*` is "an equivalent way to write a trailing wildcard." In
practice, for the Bash tool, only the `:*` form works reliably for two-token commands.

---

## Issue 3: `disableBypassPermissionsMode` Not Enforced in `--print` Mode

**Affected platform:** Both Linux and Windows
**Affected scope:** Both user-level `settings.json` AND managed `managed-settings.json`

### Symptom

```bash
# With disableBypassPermissionsMode: "disable" set:
claude -p "say hi" --dangerously-skip-permissions
# → Accepted. Claude responds normally.

claude -p "say hi" --permission-mode auto
# → Accepted. Claude responds normally.
```

### Important Nuance

Deny rules STILL WIN over bypass mode. Even with `--dangerously-skip-permissions`,
a `Bash(curl:*)` deny rule still blocks curl. The bypass flag only skips the
interactive approval prompt — it does not override deny rules.

### Workaround

Deploy the wrapper script (`scripts/wrapper-linux.sh` or `scripts/wrapper-windows.cmd`)
that rejects these flags before the real binary is invoked.

---

## Issue 4: `Read(**/.env)` Does Not Block on Windows

**Affected platform:** Windows only
**Works correctly on:** Linux / macOS

### Symptom

Claude reads and displays `.env` file contents despite the deny rule.

### Probable Cause

Windows uses backslash paths (`C:\temp\proj\.env`) but the gitignore-style
pattern uses forward slashes (`**/.env`). Path normalization may not convert
correctly before matching.

### Workaround

Use `sandbox.filesystem.denyRead` in managed-settings.json for OS-level
enforcement that works regardless of path format.

---

## Issue 5: `minimumVersion` Does Not Gate Execution

**Affected platform:** Both
**Tested values:** 2.1.150, 2.1.151, 3.0.0, 999.0.0

### Symptom

Setting `minimumVersion` to any value (even far above the current version)
does not prevent claude-code from starting. The key is parsed without error
but has no observable effect in `--print` mode.

### Recommendation

Do not rely on this as a security control. Use `DISABLE_UPDATES=1` to pin
versions and deploy specific versions via your package management system.

---

## Issue 6: `disableSkillShellExecution` Does Not Block Shell in Skills

**Affected platform:** Linux (tested)
**Tested:** A skill at `~/.claude/skills/test/SKILL.md` that asks Claude to
run `id` via Bash succeeded BOTH with and without the setting.

### Recommendation

Do not rely on this key. Use deny rules and hooks to block dangerous commands
regardless of whether they originate from a skill or direct user request.

---

## Issue 7: `allowManagedMcpServersOnly` — Runtime Filter Only

**Affected platform:** Both

### Symptom

`claude mcp add fakemcp --scope user -- echo hi` still writes to `~/.claude.json`
even with `allowManagedMcpServersOnly: true`. However, the LLM session does NOT
see the disallowed server (runtime filter works).

### Workaround

Combine with `chattr +i ~/.claude.json` (Linux) or Windows ACL to prevent the
file write entirely.

---

## Issue 8: User-Level Settings Env Vars Override Managed Settings

**Affected platform:** Linux / macOS / Windows
**Discovered:** 2026-05-28 during e2e testing

### Symptom

A user-level `~/.claude/settings.json` containing env vars like
`CLAUDE_AUDIT_LOG: "/tmp/old/path.jsonl"` will OVERRIDE the managed setting,
even when `allowManagedPermissionRulesOnly: true` is set. This is because
the `allowManaged*` flags only restrict permission rules, hooks, and MCP
servers — NOT environment variables.

In testing, a stale user-level `CLAUDE_AUDIT_LOG` from an earlier test caused
the audit-logger.sh to write to the wrong path. The hook was firing correctly
but writing to a location IT couldn't monitor.

### Workaround

1. **Pre-deployment check**: scan all developer machines for user-level
   settings that conflict with managed settings:
   ```bash
   # Find env vars in user settings that are also in managed
   diff <(jq -r '.env | keys[]' ~/.claude/settings.json | sort) \
        <(sudo jq -r '.env | keys[]' /etc/claude-code/managed-settings.json | sort)
   ```

2. **Onboarding script**: clear user-level env block during golden image deploy:
   ```bash
   jq 'del(.env)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
   ```

3. **Drift detection**: extend `drift-check.sh` to verify user settings
   don't contain conflicting env vars.

---

## Issue 9: logrotate Conflicts with `chattr +a` (Append-Only)

**Affected platform:** Linux ext4/xfs
**Discovered:** 2026-05-28 during logrotate testing

### Symptom

logrotate cannot rotate a file that has `chattr +a` set, because rotation
requires either renaming (blocked by `+a`) or truncating (blocked by `+a`).
Without correct config, the audit log silently fails to rotate, eventually
filling the disk.

Default logrotate output:
```
copying /var/log/claude-code/audit.jsonl to /var/log/claude-code/audit.jsonl.1
error: error opening /var/log/claude-code/audit.jsonl: Operation not permitted
```

### Solution

Use `copytruncate` mode + `prerotate` script that temporarily removes
`chattr -a`, then `postrotate` re-applies it. This is the configuration
shipped in `scripts/logrotate-claude-code.conf`.

```
prerotate
    /usr/bin/chattr -a /var/log/claude-code/audit.jsonl 2>/dev/null || true
endscript
postrotate
    /usr/bin/chattr +a /var/log/claude-code/audit.jsonl 2>/dev/null || true
endscript
```

### Trade-off

There is a brief window (during prerotate → copytruncate → postrotate)
where the log file is NOT append-only. A privileged attacker with timing
could theoretically tamper during this window. Acceptable for most
enterprise deployments; for higher-assurance environments, consider:
- Streaming logs to a remote SIEM in real-time (no local log to tamper)
- Using `auditd` with kernel-level immutable logging instead

---

## Issue 10: logrotate Config Comments on Same Line

**Affected platform:** all
**Discovered:** 2026-05-28

### Symptom

logrotate parser fails on:
```
rotate 52              # keep 52 weeks (1 year) — adjust per retention
```
Error: `bad rotation count '52              # keep 52 weeks ...'`

### Solution

Put comments on their own line, not after directive values:
```
# keep 52 weeks (1 year) — adjust per retention
rotate 52
```

This is fixed in the shipped `scripts/logrotate-claude-code.conf`.

---

## Issue 11: macOS `chflags uchg` is User-Removable (use `schg` for enterprise)

**Affected platform:** macOS (APFS / HFS+)
**Discovered:** 2026-05-28 during macOS 26.5 testing

### Symptom

Documentation in many places suggests `chflags uchg ~/.claude.json` as the
macOS equivalent of `chattr +i` for locking the MCP config. While this DOES
prevent `claude mcp add` (verified — returns `EPERM: operation not permitted`),
the `uchg` flag has a critical limitation:

**`uchg` can be removed by the file owner without sudo.**

```bash
chflags uchg ~/.claude.json     # lock
chflags nouchg ~/.claude.json   # ← unlock works without sudo
```

This is fundamentally different from Linux `chattr +i`, which requires `CAP_LINUX_IMMUTABLE`
(root by default).

### Workaround for enterprise

Use `schg` (system immutable) + non-root developer accounts:

```bash
sudo chflags schg ~/.claude.json     # IT-controlled lock; user can't remove
```

Verified: a non-root user gets `Operation not permitted` when trying
`chflags noschg`. Even `sudo chflags noschg` only works in multi-user mode
when SIP is configured to permit it; truly immutable across reboots requires
single-user mode.

For a banking developer machine where the user is NOT a sudoer, `schg` provides
equivalent protection to Linux `chattr +i`.

### Tested on macOS 26.5 + APFS (claude-code 2.1.154)

| Test | Result |
|---|---|
| `chflags uchg` blocks `claude mcp add` | ✅ EPERM |
| `chflags uchg` blocks `jq + mv` write-back | ✅ EPERM |
| `chflags uchg` blocks `python json.dump` | ✅ PermissionError |
| `chflags uchg` blocks `sed -i ''` | ✅ |
| `chflags uchg` blocks `tee` | ✅ |
| `chflags uchg` removable by user without sudo | ⚠ Yes (use `schg` instead) |
| `sudo chflags schg` blocks user `chflags noschg` | ✅ |
