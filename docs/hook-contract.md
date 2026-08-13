# Hook Contract

Defines the input format, output expectations, exit-code semantics, and
telemetry schema for every hook in this kit. Anything you write that gets
plugged into `managed-settings.json` MUST honour this contract; the telemetry
shim (`hooks/hook-wrapper.sh`) assumes it.

---

## Input

A single JSON object on **stdin**. Common fields:

| field | type | when set | example |
|---|---|---|---|
| `hook_event_name` | string | always | `PreToolUse`, `PostToolUse`, `UserPromptSubmit` |
| `session_id` | string | always | `1f2c…` |
| `cwd` | string | usually | `/home/dev/myrepo` |
| `tool_name` | string | tool events | `Bash`, `Read`, `Edit` |
| `tool_input` | object | tool events | `{ "command": "git push" }` |
| `tool_response` | object | PostToolUse | `{ "exit_code": 0, "usage": { "input_tokens": 1234 } }` |
| `prompt` | string | UserPromptSubmit | the user's message |

The hook MUST be tolerant of missing optional fields (use `// empty` in jq).

Keep the payload on **stdin end-to-end**. Never round-trip it through the
environment (`export PAYLOAD`) or argv: both are bounded by ARG_MAX (~1 MB),
so a single oversized tool call makes every downstream `exec` fail with
`Argument list too long` and the hook stops enforcing — silently, and only for
the largest (most interesting) payloads. Pass it to inner interpreters with a
builtin: `printf '%s' "$payload" | python3 inner.py`. Test with a ≥1.2 MB
payload.

MCP tool events have **no `tool_input.command`** — `tool_name` is
`mcp__<server>__<tool>` and `tool_input` carries structured fields. A
`"matcher": "Bash"` hook never fires for them; write-capable MCP servers need
their own `"matcher": "mcp__.*"` entry (see
[`known-issues.md`](known-issues.md) Issue 13).

## Output

- **stdout** is ignored by the harness for all events except `UserPromptSubmit`,
  where any stdout is echoed back to the user (used for advisory messages).
- **stderr** is shown to the user if the hook blocks (exit 2). Keep it short
  and actionable.
- On exit 2, stdout is **discarded** — a block reason printed to stdout
  surfaces as "blocked, no reason given" and the agent retries blind variants.
  Verified in production: this exact bug made every block message invisible.
- Write the stderr text **for the agent**, which reads it and acts on it:
  state the sanctioned alternative ("use a feature branch + PR via …"), not
  just the denial. A good block message converts a hard failure into
  self-correction on the next tool call — and make sure the alternative you
  recommend is one your other hooks actually allow.

## Exit codes

| code | meaning | downstream effect |
|---|---|---|
| 0 | allow | tool proceeds |
| 2 | block | tool is denied; stderr shown to user |
| any other | crash / failure | telemetry shim converts to exit 2 (fail-closed) |

**Rule of thumb:** never `exit 0` on errors. Either fix the error and exit 0,
or surface it via exit 2. The original `audit-logger.sh:101` was `exit 0` even
on write failures — that bug masked silent audit loss for months.

## Timing

- Hooks should complete in **< 200ms p95**. The default timeout (set by
  `hook-wrapper.sh`) is **5000ms**; over that the wrapper returns 124 → 2.
- Avoid network calls in hot-path hooks. If a hook needs network (e.g.
  CloudWatch), do it asynchronously (`& disown`) so latency doesn't add to the
  user-visible tool call. If the result gates a decision (e.g. resolving a
  repo's default branch), cache it with a TTL — and cache failures briefly
  too, or one unresolvable repo re-pays the round trip on every call.
- The cheapest way to meet the budget is to not run at all: a pure-shell
  prefilter (`case "$payload" in *git*|*gh*) ;; *) exit 0 ;; esac`) before any
  interpreter starts. Measured: two python-based guards went from ~263ms to
  ~40ms combined on non-matching calls, which are the vast majority. An
  in-interpreter early-exit saves nothing — interpreter startup is the cost.

## Telemetry schema (`/var/log/claude-code/hooks.jsonl`)

Each line emitted by `hook-wrapper.sh`:

```json
{
  "ts":           "2026-05-29T03:47:06.302Z",
  "host":         "ip-10-0-1-23",
  "user":         "alice",
  "hook":         "pii-guard.sh",
  "event":        "PreToolUse",
  "session_id":   "abc123",
  "duration_ms":  47,
  "exit_code":    0,
  "status":       "ok | blocked | crashed | timeout",
  "stderr":       "first 300 chars of stderr if any"
}
```

CloudWatch metric filters in `observability/cloudwatch-dashboard.tf` derive:
- `ClaudeCode/Hooks::HookBlocked` (count)
- `ClaudeCode/Hooks::HookCrashed` (count) — alarms at threshold > 0
- `ClaudeCode/Hooks::HookTimeout` (count)
- `ClaudeCode/Hooks::HookDurationMs` (statistic, p50/p95/p99)

## Audit log schema (`/var/log/claude-code/audit.jsonl`)

```json
{
  "ts":          "2026-05-29T03:47:06.302Z",
  "user":        "alice",
  "host":        "ip-10-0-1-23",
  "event":       "PostToolUse",
  "session_id":  "abc123",
  "cwd":         "/home/alice/repo",
  "tool":        "Bash",
  "action":      "git status",
  "prev_hash":   "GENESIS or hex sha256 of prior hmac",
  "hmac":        "hex sha256 hmac over (key || prev_hash || body)"
}
```

Verifying:
```bash
scripts/chain-verify.sh /var/log/claude-code/audit.jsonl
# exit 0  → chain intact
# exit 1  → chain broken; investigate
```

## Drift schema (`/var/log/claude-code/drift.jsonl`)

```json
{
  "ts":             "...",
  "host":           "...",
  "path":           "/etc/claude-code/managed-settings.json",
  "kind":           "modified | created | deleted | moved",
  "sha256_before":  "...",
  "sha256_after":   "..."
}
```

## Adding a new hook

1. Read this contract.
2. Implement the hook to satisfy: input parsing, exit codes, latency budget.
3. Add a unit test under `tests/test_<name>.sh` modelled on existing tests.
   Note what unit tests CANNOT prove: registration. A mistyped path, a matcher
   that never fires, and a working hook are observationally identical (nothing
   blocked). After wiring, trip the hook once from a real session and confirm
   the deny + non-empty stderr; for ongoing assurance, alarm on an active
   session producing zero `hooks.jsonl` lines
   ([`hook-hardening-lessons.md`](hook-hardening-lessons.md) §3).
4. Wire it through `hook-wrapper.sh` in `managed-settings.json`:
   ```jsonc
   "command": "/usr/local/etc/claude-code/hooks/hook-wrapper.sh /usr/local/etc/claude-code/hooks/<your-hook>.sh"
   ```
5. Add an entry to the on-call runbook describing what its block messages
   mean and what action they require.

## Versioning

Each hook header MUST include a `Hook version: x.y.z` line. Bump:
- patch on bugfix-only changes that preserve input/output behaviour
- minor on additive features (new patterns, new env knobs)
- major on contract changes (different exit semantics, new required fields)

The wrapper logs the hook filename, not version, so SREs verify drift via the
drift watcher hash, not the version string.
