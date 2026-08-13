# Hook Hardening Lessons — Empirically Verified

Lessons from hardening a production PreToolUse hook set (macOS, Claude Code on
Bedrock). Every finding below was demonstrated with a crafted payload or a live
session before it was fixed, and each fix is regression-tested. Where a lesson
overlaps a control already in this kit, the section says so and only adds the
delta.

**The one-line summary: a guard is only as good as the paths it covers and the
proof that it actually fires.** Most of what follows is about ways a hook set
that passes all its unit tests still fails to protect anything.

---

## 1. Bash-matcher hooks do not see MCP tool calls (highest impact)

`git-guard.sh` and `pii-guard.sh` fire on `matcher: "Bash"` (git-guard
additionally exits 0 for any other `tool_name`). That is correct for shell
commands — and completely blind to MCP servers.

A GitHub MCP server (e.g. the official `github` server, or Docker MCP Toolkit's
gateway) exposes `create_or_update_file`, `push_files`, `create_branch`,
`merge_pull_request`, `delete_file`. **None of these go through the Bash tool.**
An agent with such a server configured can:

- write any file directly to `main` (`push_files` with `branch: "main"`),
- merge its own PR (`merge_pull_request`),
- upload secrets in the `content` field of the tool input,

and every Bash-matcher control in this kit will report a clean day. Verified
live: with both Bash guards registered and firing, MCP GitHub writes produced
zero hook invocations.

### Fix: a second hook on an `mcp__.*` matcher

Reference implementation: [`hooks/mcp-repo-guard.sh`](../hooks/mcp-repo-guard.sh)
(policy) and [`tests/test_mcp_repo_guard.sh`](../tests/test_mcp_repo_guard.sh)
(43 assertions, including server-name independence).

```jsonc
"PreToolUse": [
  { "matcher": "Bash",    "hooks": [ /* existing guards */ ] },
  { "matcher": "mcp__.*", "hooks": [ { "type": "command",
      "command": "/usr/local/etc/claude-code/hooks/mcp-repo-guard.sh" } ] }
]
```

The MCP payload differs from Bash: there is no `command` string to parse.
`tool_name` is `mcp__<server>__<tool>` (the server segment varies per machine —
match on the tool suffix, not the full name) and `tool_input` carries structured
fields (`owner`, `repo`, `branch`, `content`, `files[]`). That makes the guard
*simpler* than the Bash one: no quoting, no segmentation — read the JSON fields
and apply the same policy:

- block writes where `branch` is protected (see §5 on resolving the default
  branch),
- block `merge_pull_request`,
- run the same secret/PII patterns over every `content` / `files[].content`
  field before it leaves the machine.

### Share one pattern list

The moment the MCP guard exists there are two consumers of the redaction
patterns. Import a single module (`redaction_patterns.py` or a sourced shell
fragment) from both hooks. A copy-pasted list scans MCP content with whatever
the list looked like the day it was copied.

The same blindness applies to `WebFetch`/`WebSearch`-style tools and any other
non-Bash tool that can carry data out. Enumerate your session's tools and ask,
for each: *can this write to the repo or exfiltrate content, and which hook sees
it?*

---

## 2. `gh` CLI and raw REST writes bypass git-only guards

`git-guard.sh` matches `git` subcommands only. But a repo write does not need
`git`:

| Path | Example | Seen by a git-only guard? |
|---|---|---|
| gh high-level | `gh pr merge 5 --squash` | ❌ |
| gh REST | `gh api -X PUT repos/o/r/contents/f.md -f content=…` (no `branch=` ⇒ writes the **default branch**) | ❌ |
| gh REST | `gh api -X POST repos/o/r/merges` (merge without a PR) | ❌ |
| gh REST | `gh api -X DELETE repos/o/r/git/refs/heads/main` | ❌ |
| gh sync | `gh repo sync` (fast-forwards a branch, no PR) | ❌ |
| raw | `curl -X PUT https://api.github.com/repos/…/contents/…` | ❌ |

If the box has an authenticated `gh` (or a `GITHUB_TOKEN` usable by `curl`),
the guard must cover these forms, or an agent that is blocked on `git push`
will discover — or be told by its error output — that `gh api` works.

Reference implementation: [`hooks/gh-guard.sh`](../hooks/gh-guard.sh) and
[`tests/test_gh_guard.sh`](../tests/test_gh_guard.sh) (77 assertions). It shares
one endpoint-policy function between the `gh api` and `curl`/`wget` paths, so the
two cannot drift apart.

Details that matter when you implement it (each one was a working bypass until
fixed):

- A contents-API write **without** `branch=` targets the default branch. Treat
  "no branch field" as a protected-branch write, not as unknown.
- `-f branch=refs/heads/main` must compare equal to `main` — strip the
  `refs/heads/` prefix before comparison.
- `--input body.json` carries the branch as JSON (`"branch": "feat"`), which a
  literal `branch=` regex never sees. Parse the file; if you can't read it,
  block with instructions rather than guessing.
- `gh` infers POST when `-X` is absent but body fields (`-f`/`-F`) are present.
  Deriving the method only from `-X` misclassifies those writes as GET.

---

## 3. Test registration and liveness, not just logic

Every test in this kit's suite (and ours) pipes a payload into the hook script
directly. That proves the **logic**. It proves nothing about **registration** —
and a registration failure is invisible by construction:

| Failure | Observable |
|---|---|
| Hook path mistyped in settings | nothing blocked, no error |
| Matcher regex never matches (e.g. `mcp_.*` vs `mcp__.*`) | nothing blocked, no error |
| Session started before the hook was added (hooks snapshot at startup) | nothing blocked, no error |
| Hook works | nothing blocked |

Four indistinguishable states, one of which is the goal. Two cheap mechanisms
close the gap:

**Liveness stamp.** The hook's first action (before any filtering) writes a
one-line stamp — timestamp + `tool_name` — to a known file. To verify a matcher
is live in a real session, trigger any *harmless* matching call (a read-only
MCP tool, `git status`) and check the stamp moved. Caveat learned the hard way:
your own test harness also writes the stamp when it pipes payloads in — only a
stamp produced by a real session tool call proves registration.

**Live trip test.** Once per deploy (and after any settings change), run one
command that *must* block — `git push origin main` in a scratch repo — from
inside a real session, and confirm the deny plus a non-empty reason. This kit's
telemetry shim gives a third signal for fleets: a host whose `hooks.jsonl`
shows zero `PreToolUse` lines for an active session is a host where
registration is broken — worth a CloudWatch alarm alongside the existing
crash/latency ones.

Also note the snapshot behaviour: hooks are captured at session startup, so a
fix rolled out mid-day protects **new** sessions only. Long-lived agent
sessions keep running the old set until restarted.

---

## 4. Write the block message for the agent, and put it on stderr

The hook contract already says stderr-on-block. Two production additions:

**On exit 2, stdout is discarded entirely.** Our original guards printed the
block reason to stdout; the agent saw literally `No stderr output` and retried
blind variants. One `print(..., file=sys.stderr)` turned every block into
self-correction. If your hook has ever produced a "blocked but no reason"
report, check for this first.

**The audience is the agent, not the user.** The agent reads the stderr text
and acts on it. A bare `denied by policy` produces retry loops; a message that
states the sanctioned alternative produces compliance on the next tool call:

```
BLOCKED: `git push` is not allowed.
POLICY: All repo changes go through a PR.
  1. gh api -X POST repos/O/R/git/refs -f ref=refs/heads/<feature> -f sha=$BASE
  2. gh api -X PUT repos/O/R/contents/<path> -f branch=<feature> …
  3. gh api repos/O/R/pulls -f head=<feature> …  then STOP for user review.
```

And make sure the redirection you print is one your guards actually allow —
a block message recommending a flow that another hook blocks (or that trips a
false positive, §6) creates an unrecoverable loop.

---

## 5. Command parsing: the bypasses we found in our own guard

Our Bash git guard was reviewed and each finding reproduced with a payload
before fixing. The classes generalize to any command-string guard, including
`git-guard.sh`:

**Quote-aware AND escape-aware segmentation.** Splitting a compound command on
`;`/`&&`/`|` must ignore separators inside quotes — otherwise
`git commit -m "a; git push"` false-positives. But quote-tracking without
backslash handling is its own bypass: in
`-f message=Bob\'s && gh api … (write to main)`, the escaped quote opens a
quote state that never closes, the `&&` is swallowed, and the second command
inherits the first one's clean verdict. Track `\` outside single quotes.

**Evaluate each segment independently.** One segment's `branch=feature` must
not whitelist a sibling segment writing to `main`.

**Anchor field matching to flags, not substrings.**
`-f message="use branch=feat"` contains `branch=` but carries no branch field.
Tokenize (shlex) and read values only from `-f`/`-F`/`--field` positions; a
raw substring check is satisfiable from inside any quoted string.

**Cover subcommand variants.** `git subtree push` pushes to a remote branch
but does not match a `git … push` regex anchored to the flag group. Same
family: `gh repo sync`.

**Resolve the default branch; don't hardcode.** `main|master` (or a static
env list) leaves a `develop`- or `trunk`-defaulted repo fully writable. Ask
once — `gh api repos/O/R --jq .default_branch` — and cache with a TTL (cache
failures too, briefly, or an unresolvable repo costs a network round-trip on
every command). This kit's `GIT_GUARD_PROTECTED_BRANCHES` env var covers known
repos; resolution covers the repo nobody told the security team about.

**Test the API-resolved path with a primed cache.** Our test suite stayed
green after we deleted the resolution logic entirely — every test repo
defaulted to `main`, so the local shortcut answered everything. Seed the cache
with a synthetic `develop`-defaulted repo so the resolved path has a test that
can fail.

---

## 6. False positives are security failures too

A 12-digit-run pattern for AWS account IDs fires on hex digests
(`ab…12-digits…cd` was blocked as an account ID in our corpus), phone numbers,
order IDs, and numeric test fixtures. On a *blocking* hook every false
positive teaches the operator to disable the guard — and combined with §4 it
can wedge the agent in a loop.

Two mitigations that took our FP rate to zero without missing the positive
corpus:

- **Context anchor:** require an AWS-ish token (`account`, `arn:`, `:iam::`,
  `aws`) on the same line before blocking a bare digit run.
- **Token boundary:** reject matches embedded in a longer alphanumeric token
  (lookarounds on `[0-9A-Za-z_]`, not just `[0-9]`), which kills the
  hex-digest class.

This kit's PII corpus (`tests/pii-corpus/negative/false_positive_traps.jsonl`)
is the right harness for this — if you add an account-ID pattern to
`pii-guard.sh`, add the digest/phone/order-ID traps with it.

---

## 7. Deliver the payload on stdin; never via env or argv

Claude Code hands the payload on stdin. Keep it there. Our original wrapper
did `PAYLOAD=$(cat); export PAYLOAD` so an inner interpreter could read it —
which put the payload on the exec environment, bounded by ARG_MAX (~1 MB on
macOS/Linux). A 1.2 MB tool call (one big file upload) made every exec fail
with `Argument list too long`: the redaction hook crashed and the git guard
**allowed `git push` through**, silently, only for oversized commands.
`printf '%s' "$payload" | hook.py` (printf is a builtin — no exec, no limit)
restored enforcement at every size. This kit's `hook-wrapper.sh` already pipes
stdin correctly; the trap is any custom hook that round-trips the payload
through the environment.

Related fail-open trap: propagating the interpreter's raw exit code
(`exit $?`) turns a crash (126/127) into a harness-level "hook error" whose
behaviour you did not choose. Decide explicitly, per hook, what non-0/2 means.
This kit's wrapper converts crashes to exit 2 (fail-closed) — right for an
audit logger. For a guard whose *check* depends on the network (comparing a PR
diff via the API), a hard fail-closed can make all PRs impossible during a
GitHub outage; if you choose fail-open there, **log every fail-open with the
reason** to an audit file. A silent fail-open reads as "scanned, clean" —
ours hid a scan that skipped files for weeks.

---

## 8. Performance: prefilter before the interpreter starts

PreToolUse hooks run on **every** tool call of their matcher. Measured on
Apple silicon: two guards, each `bash` + `python3` startup, added ~263 ms to
every `ls`. Three changes cut the non-matching path to ~40 ms combined:

1. **Pure-shell prefilter in the wrapper** — before any interpreter starts:

   ```bash
   IFS= read -r -d '' PAYLOAD          # builtin read; $(cat) forks per call
   case "$PAYLOAD" in
     *git*|*gh*|*github*|*api/v3*) ;;  # possibly relevant → run the real guard
     *) exit 0 ;;
   esac
   ```

   A substring gate is deliberately over-broad (it also matches "weigh") —
   that's fine: false *continues* cost milliseconds; the anchored check lives
   in the real guard. What matters is that `ls`, `npm test`, etc. never pay
   interpreter startup. (An in-interpreter gate saves nothing — startup is the
   cost.)

   `*github*` is not redundant with `*gh*`: **"github" does not contain the
   substring "gh"** — the letters are g-i-t-h-u-b. A prefilter of `*git*|*gh*`
   happens to catch `api.github.com` through `*git*`, but drop the `git` pattern
   (as a gh-only guard reasonably would) and every `curl` to the REST API
   silently skips the guard while the whole suite still looks green. See §9.

2. **`python3 -I`** (isolated mode) — skips `site`/user-site and ignores
   `PYTHON*` env vars: ~20 ms faster startup, and a broken `PYTHONPATH` or
   sitecustomize can no longer break (or tamper with) the guard.

3. **Cache network lookups, including failures** (§5) — an uncached
   default-branch query was ~800 ms per gh command; a TTL'd cache with
   negative entries makes it one query per repo per week.

This complements the contract's <200 ms p95 budget: the budget is met not by
making the guard fast but by not running it at all for irrelevant calls.

---

## 9. The reference implementation broke twice — both only on Linux

The two guards this document describes now ship in the kit
([`hooks/gh-guard.sh`](../hooks/gh-guard.sh),
[`hooks/mcp-repo-guard.sh`](../hooks/mcp-repo-guard.sh)). Both were written and
unit-tested on macOS, then run on Amazon Linux 2023 (bash 5.2.15, jq 1.8.1)
before being trusted. Two defects surfaced only there, and both had the same
shape: **the guard exits 0 and every ALLOW test still passes**, so a suite that
only counts failures reports success.

**(a) `local a="$1" b=${#a}` is fatal under `set -u`.** Bash expands *all*
arguments to `local` before assigning any of them, so `${#a}` reads `a` while it
is still unset:

```bash
tokenize() {
  local s="$1" n=${#s}     # ✗ "s: unbound variable" — the function aborts
}
tokenize() {
  local s="$1"             # ✓ two statements
  local n=${#s} i=0
}
```

bash 3.2 (the macOS default) tolerates this; bash 5.2 under `set -u` kills the
function. The parser aborted on its first call, the hook fell through to
`exit 0`, and it fail-*opened* on every command — 5 of 56 cases passing, but
the visible symptom was ALLOW tests failing, not writes being permitted.

**(b) The prefilter did not match its own primary target.** The guard's cheap
gate was `case "$command_str" in *gh*|*api/v3*)`, with a comment asserting that
`*gh*` "also covers github in a URL". It does not (§8). Every
`curl … https://api.github.com/…` case returned exit 0 without the guard ever
parsing anything. The only reason this was caught is that the suite contained
one GitHub Enterprise case whose host matched `*api/v3*` and blocked correctly —
a single passing sibling next to seven failures is what pointed at the gate
rather than at the policy.

Three practices come out of this:

- **Run the suite on the platform you deploy to, not the one you write on.**
  Both bugs are invisible on macOS. An ephemeral instance plus a remote runner
  (SSM `RunShellScript`, no inbound access, terminated after) is enough.
- **Test that ALLOW cases are allowed for the right reason.** A hook that
  crashes early passes every ALLOW assertion. Pair each one with a BLOCK case
  that shares its code path, and assert on the *stderr text* — not just the
  exit code — so a fail-open cannot masquerade as a pass.
- **A pattern in a comment is a claim; check it.** `bash -x` over one failing
  payload located both bugs in under a minute, after code review had missed
  them twice.

---

## 10. A command that spans lines is still one command

Agents write multi-step commands, and they write files with heredocs. Both
guards in this kit mis-handled a newline, in opposite directions, and the two
mistakes are the same mistake: **a line is not a command, and a command is not a
line.**

**A heredoc body is data, not a command list.** `gh-guard.sh` split on newlines
to find command segments, so every line of a body arrived as its own segment.
Writing documentation with `cat > policy.md <<'EOF' … EOF` whose prose mentioned
`gh pr merge` was denied as an attempt to merge a pull request. Nothing was
being merged. In a docs-heavy repository the guard was densest exactly where it
was least wanted, which is how a guard ends up switched off (§6).

**Field extraction that runs per line fails open.** `git-guard.sh` matched
correctly but read its fields with a pipeline:

```bash
push_args=$(echo "$norm" | sed -E 's/.*git .*push *//')
remote_name=$(echo "$push_args" | awk '{print $1}')   # ✗ one field PER LINE
branch_name=$(echo "$push_args" | awk '{print $2}')
```

`echo` of a multi-line string feeds `awk` several lines, and `awk` prints `$1`
for each of them. On a two-line command `branch_name` became `"/repo\nmain"`,
which matches no protected pattern:

```bash
git push origin main            # blocked
cd /repo && git push origin main # blocked
cd /repo
git push origin main            # allowed — same push, one newline
```

The destructive checks (`reset --hard`, `clean -f`) survived because they are
pure regexes with no field extraction. Only the checks that parsed arguments
were affected, so the suite's coverage of *verbs* said nothing about the
coverage of *arguments*. Reduce to the matching segment first, then parse.

**The two failures share a root, so fix them together.** Closing the fail-open
alone re-created the false positive: with per-segment extraction, a heredoc body
line reading `git push origin main` becomes a segment and gets blocked. A guard
needs to know where command text ends and data begins *before* any check runs —
and the exception matters too, because a body a shell consumes (`bash <<EOF`,
`cat <<EOF | bash`) really is a command list. v1.0.0 caught those by accident,
via the very bug that produced the false positives, so dropping bodies without
re-scanning shell-consumed ones would have traded a false positive for a
regression.

**Resolve heredoc ambiguity toward "not a heredoc".** `<<` is also a left
shift. Treating `echo $((1<<SHIFT))` as an opener starts a phantom body that
swallows every following line, including a real `git push` — silent and
unbounded. Guessing the other way costs one visible false positive. So a
delimiter must be a whole shell word starting like an identifier:

```bash
echo $((1<<SHIFT))     # not an opener: ')' is not a word boundary
echo $((1<<4))         # not an opener: a delimiter cannot start with a digit
echo "sample: cat <<EOF"  # not an opener: it is inside quotes
```

**Quote-awareness has to extend to pipe detection.** Deciding whether a body is
consumed by a shell means looking for `| bash` — but `send.sh "build | bash"
<<EOF` pipes nothing. Match on text whose quoted spans have been blanked, or on
tokens (a tokenizer collapses a quoted span into one token, which makes any
token-based scan quote-aware for free). The first version of this fix scanned
raw text and recursed into an argument that merely *described* a pipeline.

**§9(a) came back.** The `local s="$1" n=${#s}` bug reappeared in a new helper
written months after §9 documented it, and it fails open exactly as before: the
helper aborted, its caller saw an empty string, concluded that nothing ran a
shell, and skipped the body. Four BLOCK assertions caught it on Linux; on
macOS bash 3.2 the same code passes. A lesson written down is not a lesson
enforced — only the suite on the deployment platform is.

---

## Checklist

- [ ] Every tool that can write to a repo or carry content out has a hook whose
      matcher provably fires on it (Bash **and** `mcp__.*` at minimum).
- [ ] Guards cover `git`, `gh` (CLI + `api` + `repo sync`), and raw REST forms.
- [ ] One shared pattern module for all content-scanning hooks.
- [ ] A liveness signal distinguishes "hook allowed everything" from "hook
      never ran"; verified against a real session call after each deploy.
- [ ] Block messages: stderr, and they state the sanctioned alternative.
- [ ] Payload: stdin end-to-end; oversized-payload test (≥1.2 MB) in the suite.
- [ ] Segment splitting is quote- and escape-aware; fields parsed from flag
      positions; `refs/heads/` normalized; default branch resolved + cached
      (and the resolved path has a test that can fail).
- [ ] Ambiguous numeric patterns need context anchors + token boundaries, with
      false-positive traps in the corpus.
- [ ] Every fail-open is logged with a reason; non-0/2 exit behaviour is an
      explicit per-hook decision.
- [ ] Non-matching tool calls exit before any interpreter starts.
- [ ] The suite runs on the deployment platform (Linux bash 5.x under `set -u`),
      not only on the author's machine — see §9 for two fail-open bugs that
      exist nowhere else.
- [ ] Prefilter patterns are verified against a real payload for each covered
      path (`*gh*` does **not** match `github`).
- [ ] Heredoc bodies are separated from command text before any check runs, with
      the exception re-scanned (a body fed to `bash` is a script) — see §10.
- [ ] No check extracts fields with `echo "$multiline" | awk`; the matching
      segment is isolated first, and the suite asserts that the same operation
      written on one line and across two reaches the same verdict.
- [ ] Every hook that the plugin also ships has a test asserting the two copies
      are byte-identical; nothing else notices when one is left a version behind.
