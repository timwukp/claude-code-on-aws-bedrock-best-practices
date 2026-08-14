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

---

## Issue 12: Minimum Version Requirements for Features in This Kit

**Affected platform:** All
**Discovered:** 2026-05-30

### Background

Several features and settings used in this kit were introduced in specific
Claude Code versions. Deploying the managed-settings.json from this kit on
an older Claude Code version may result in those settings being **silently
ignored** without any error or warning.

### Feature / Version Matrix

| Feature / Setting | Minimum Version | Impact if Missing |
|---|---|---|
| macOS plist managed settings | v2.1.51+ | macOS managed settings not read |
| `managed-settings.d/` directory | v2.1.83+ | Directory-based config not merged |
| `sandbox.failIfUnavailable` CVE fix | v2.1.78+ | Sandbox may be silently disabled |
| `sandbox.network.deniedDomains` | v2.1.113+ | Denied domains list ignored |
| `DISABLE_AUTOUPDATER` env var | v2.1.118+ | Background updates still run |
| `ANTHROPIC_BEDROCK_SERVICE_TIER` | v2.1.122+ | Service tier setting ignored |
| Plugin marketplace controls | v2.1.130+ | Plugin restrictions not enforced |
| `awsAuthRefresh` | v2.1.141+ | Credential refresh not available |
| Opus 4.8 model support | v2.1.154+ | Model alias may fail |

### Recommendation

1. **Pin minimum version:** Enforce v2.1.118+ as a floor via your package
   management system. This covers the most critical security features.
2. **Version check on deploy:** Add `claude --version` to your golden image
   validation script and fail if below the required minimum.
3. **Do not rely on `minimumVersion` setting:** As documented in Issue 5,
   this setting has no observable enforcement effect.

---

## Issue 13: MCP Tool Calls Bypass All Bash-Matcher Hooks

**Affected platform:** All
**Discovered:** 2026-08-13 during production hardening (macOS, Bedrock)

### Symptom

With `git-guard.sh` and `pii-guard.sh` fully registered and verified firing on
Bash commands, a GitHub MCP server (official `github` server, Docker MCP
Toolkit gateway, etc.) can still:

```
mcp__github__push_files            (branch: "main")   → ✅ writes straight to main
mcp__github__create_or_update_file (branch: "main")   → ✅ writes straight to main
mcp__github__merge_pull_request                       → ✅ agent merges its own PR
```

with **zero hook invocations**. Secrets in the `content` / `files[].content`
fields leave the machine unscanned.

### Root Cause

Not a bug — matcher semantics. The hooks in this kit register with
`"matcher": "Bash"` and inspect `tool_input.command`. MCP tools arrive as
`tool_name: "mcp__<server>__<tool>"` with structured `tool_input` and no
`command` field, so no Bash-matcher hook (nor `Bash(...)` permission rule)
ever sees them. `git-guard.sh` additionally exits 0 for any non-Bash
`tool_name` by design.

### Fix (shipped in this kit)

Two hooks now cover the two uncovered write paths:

| Hook | Matcher | Covers |
|---|---|---|
| [`hooks/mcp-repo-guard.sh`](../hooks/mcp-repo-guard.sh) | `mcp__.*` | `push_files`, `create_or_update_file`, `delete_file`, `merge_pull_request`, `delete_branch`, `update_ref`, repo/release deletion, transfer, secret writes |
| [`hooks/gh-guard.sh`](../hooks/gh-guard.sh) | `Bash` | `gh pr merge`, `gh api` contents/refs/protection/secret writes, `gh repo delete\|sync\|archive\|transfer`, and `curl`/`wget` straight to `api.github.com` or a `/api/v3/` Enterprise host |

Registration (both go through the fail-closed telemetry shim in a real
deployment — see [`plugin/hooks/hooks.json`](../plugin/hooks/hooks.json)):

```jsonc
"PreToolUse": [
  { "matcher": "Bash",    "hooks": [ /* pii-guard, git-guard, gh-guard */ ] },
  { "matcher": "mcp__.*", "hooks": [ { "type": "command",
      "command": "/usr/local/etc/claude-code/hooks/mcp-repo-guard.sh" } ] }
]
```

Three implementation notes that the tests pin down, because each one is a way
to write a guard that looks correct and enforces nothing:

1. **Match on the tool-name *suffix*** (`push_files`, `merge_pull_request`, …),
   never the full name — the `<server>` segment differs per machine
   (`mcp__github__`, `mcp__MCP_DOCKER__`, `mcp__gh-enterprise__`). Covered by
   the server-name-independence cases in
   [`tests/test_mcp_repo_guard.sh`](../tests/test_mcp_repo_guard.sh).
2. **An absent `branch` is not a safe default** — the contents API and every
   MCP write tool commit to the repository *default* branch when `branch` is
   omitted, so "no branch specified" must deny, not allow. A body the hook
   cannot read (`--input <file>`, `curl -d @body.json`) is treated the same way.
3. **Content scanning is not duplicated here.** `pii-guard.sh` already scans
   `tool_input` for every tool, MCP included; these two hooks implement *write
   policy* only.

Verification caveat: piping test payloads into the guard proves its logic but
not its registration. Confirm liveness against a *real* MCP call in a live
session (any read-only tool) — see
[`docs/hook-hardening-lessons.md`](hook-hardening-lessons.md) §3.
`mcp-repo-guard.sh` writes `MCP_GUARD_LIVENESS_FILE` *before* it checks
`MCP_GUARD_DISABLED`, so the liveness record survives even when policy is
switched off.

### Status

- **Closed in this kit** (hooks above; 120 assertions across
  `tests/test_gh_guard.sh` and `tests/test_mcp_repo_guard.sh`, plus 28
  red-team rows in `tests/bypass-attempts.sh`)
- Matcher semantics themselves are unchanged upstream — present in all versions
  tested (2.1.150–2.1.15x). A kit that registers only `"matcher": "Bash"` still
  has the gap.
- The `gh` CLI / `gh api` / `curl` half of the same gap
  ([`docs/hook-hardening-lessons.md`](hook-hardening-lessons.md) §2) is covered
  by `gh-guard.sh`. Residual: writes from a subprocess the hook never inspects
  (a Python script using `requests`, a compiled binary) remain out of reach for
  any PreToolUse hook.

---

## Issue 14: `git-guard.sh` Does Not See Commands Wrapped in a Shell

**Status:** **fixed in `git-guard.sh` v1.2.0** · **Applies to:** `hooks/git-guard.sh` ≤ v1.1.0

Left here rather than deleted, because the shape of the bug is the reusable part:
one cause (deciding policy on command *text*) produced a fail-open and a false
positive at the same time, in opposite directions. What changed, and the residual
limit that remains, is at the end of this entry.

### Symptom

`git-guard.sh` matches command text with anchored regexes. A `git` command that
is not lexically a command — because it sits inside a quoted argument to an
interpreter — is not seen:

```bash
git push origin main               # blocked
bash -c "git push origin main"     # ALLOWED (exit 0)
sh -c 'git reset --hard HEAD~1'    # ALLOWED (exit 0)
eval "git push origin main"        # ALLOWED (exit 0)
```

A related gap: a push with no arguments is not inspected at all, because the
branch cannot be read from the command line.

```bash
git push                           # ALLOWED even when HEAD is main
```

### Root cause

Two different things, both scoped deliberately out of the v1.1.0 fix:

1. **No recursion into quoted arguments.** v1.1.0 separates heredoc bodies from
   command text and re-scans a body that a shell consumes (`bash <<EOF`), which
   is the same class of problem — but it does not recurse into the quoted
   argument of `bash -c`. Doing that safely needs the tokenizer and segment
   splitter that `gh-guard.sh` carries, plus a depth cap, and it must recurse
   *only* for interpreters and wrappers: recursing into every quoted string
   turns `echo "git push origin main"` into a denial.
2. **`git push` with no refspec** requires resolving the current branch
   (`git -C "$cwd" rev-parse --abbrev-ref HEAD`), so the check depends on
   repository state rather than on the command string.

`gh-guard.sh` is **not** affected by (1): it tokenizes, splits segments
quote-aware, and recurses into interpreter arguments, so
`bash -c "gh pr merge 1"` is blocked (regression test in
`tests/test_gh_guard.sh`).

### Workarounds

- **Deny the wrappers in policy** rather than parsing them. A `permissions.deny`
  entry for `Bash(bash -c:*)` / `Bash(sh -c:*)` / `Bash(eval:*)` removes the
  wrapper class without touching the hook; see
  [`docs/managed-settings.jsonc`](managed-settings.jsonc). Note the cost: agents
  legitimately use `bash -c` for quoting, so expect friction.
- **Server-side branch protection is the control that does not depend on
  parsing.** Every bypass in this class ends in a push to a protected branch, and
  a required-review rule refuses it regardless of how the command was spelled.
  The hook is the fast, local, explanatory layer — not the last one.
- `gh-guard.sh` already covers the same operations performed through `gh` or the
  REST API, including inside `bash -c`.

### Why it was deferred out of v1.1.0

v1.1.0 closed the fail-opens that a *newline* caused, because those fired on
ordinary multi-step commands that agents write constantly
([`hook-hardening-lessons.md`](hook-hardening-lessons.md) §10). Wrapper
recursion is a larger change to this hook's parsing front end — it is the point
at which the two guards should share one parser instead of carrying two copies —
and it deserved its own review and its own platform run rather than riding along
with a fix that had different evidence behind it.

### How v1.2.0 fixes it

`git-guard.sh` no longer decides anything from the command text. Every segment is
tokenized and policy runs on tokens, which makes the guard quote-aware in both
directions at once: a quoted span is a single token, so `bash -c "git push origin
main"` has a `git` that the scan can find *inside that token* by re-scanning it,
while `echo "x; git push origin main"` has no `git` token at all and is allowed.

- The parsing front end now has one canonical home,
  [`hooks/lib/shell-parse.sh`](../hooks/lib/shell-parse.sh), copied into both
  guards by `scripts/sync-parser.sh` and checked for drift by
  `tests/test_shared_parser.sh`.
- Recursion into quoted arguments happens **only** for interpreters and wrappers
  (`bash -c`, `sh -c`, `eval`, `xargs`, `timeout`, …), with a depth cap of 3.
- Wrappers that carry their own arguments are followed (`timeout 5 git push`,
  `nohup`, `env VAR=1`, `sudo`), which was the same fail-open one step further
  out. The identical gap in `gh-guard.sh` (`timeout 5 gh pr merge 1`) closed with
  it.
- Pushes whose target is not on the command line are resolved instead of skipped:
  a bare `git push` asks `git -C <dir> rev-parse --abbrev-ref HEAD`, `--all` and
  `--mirror` are refused outright.
- Every refspec is checked rather than only the first, and `+ref:dst` counts as a
  force push.

**Residual limit.** A wrapper option that takes a non-flag value stops the walk,
so `sudo -u bob git push origin main` is not recognised as a push. Skipping
arbitrary words instead would let `xargs -I{} echo git push` read as a push, and
a false positive on `echo` costs more than this case is worth. The two workarounds
above (deny the wrapper class in policy; server-side branch protection) still
cover it.

### Tested on

Amazon Linux 2023.12, bash 5.2.15(1), jq 1.8.1, git 2.50.1, via SSM. Each case
above was run against an unmodified `git archive` of the pre-fix commit and
against the patched tree **on the same host, from the same test file**, so every
changed verdict is attributable. Full matrix in
[`test-evidence.md`](test-evidence.md) §7d.

---

## Issue 15: Two Hooks Shipped Without the Execute Bit (exit 126 = no enforcement)

**Status:** **fixed** · **Applies to:** `hooks/gh-guard.sh`, `hooks/mcp-repo-guard.sh`
and their `plugin/hooks/` copies, up to and including the commit before this one

### Symptom

`settings.json` names a hook by path. If the file is not executable, the exec
fails and the wrapper reports **126** — which is neither `0` (allow) nor `2`
(block), so Claude Code surfaces a hook error and **the tool call proceeds**. The
guard is not bypassed so much as absent:

```
$ ls -l hooks/gh-guard.sh
-rw-rw-r--. 1 ... hooks/gh-guard.sh          # committed as mode 100644
$ printf '%s' "$payload" | hooks/gh-guard.sh
bash: hooks/gh-guard.sh: Permission denied   # rc=126, the write is allowed
```

28 of the 60 rows in `tests/bypass-attempts.sh` were failing this way on a clean
checkout: every `gh` row and every MCP row, including the ones that assert a
*block*.

### Root cause

Two things, and the second is why it survived three releases:

1. **The GitHub contents API creates files as `100644`.** These hooks were added
   to the repository through `PUT /repos/{o}/{r}/contents/{path}`, which has no
   mode parameter. `git-guard.sh` predated that path and kept its `100755`, which
   is exactly why the defect looked like it could not exist.
2. **Every unit suite `chmod +x`es its own hook** before the first assertion
   (`chmod +x "$HOOK"` at the top of `tests/test_gh_guard.sh` and friends). So the
   suites tested a file whose mode they had just repaired, and reported green.
   `tests/bypass-attempts.sh` does not chmod, and its 126s are how this surfaced.

A test that fixes the artefact before measuring it is not a test of what ships.

### Fix

- Both hooks and both plugin copies are `100755` again.
- `tests/test_shared_parser.sh` asserts that every file in `hooks/` and
  `plugin/hooks/` is executable, so the mode is a property of the repository
  rather than something a suite repairs at runtime.
- `scripts/sync-parser.sh` sets the execute bit on every file it writes, and
  `--check` reports a plugin copy that has lost it.

### If you have already installed these hooks

```bash
chmod +x ~/.claude/hooks/*.sh
```

Then confirm the guard actually runs — a hook that is not being executed looks
exactly like a hook that allows everything:

```bash
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1"}}' \
  | ~/.claude/hooks/gh-guard.sh; echo "rc=$?"   # expect rc=2
```

### Tested on

Amazon Linux 2023.12, bash 5.2.15(1). `tests/run_all.sh` on a pristine
`git archive` of the previous commit: 2 suites failing, 29 assertions, 28 of them
`126`. Same command on the fixed tree: `tests/bypass-attempts.sh` 60/60, and the
only remaining failure is the pre-existing `audit-logger.sh` one already recorded
in [`test-evidence.md`](test-evidence.md) §7b.
