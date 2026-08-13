#!/usr/bin/env bash
# =============================================================================
# test_shared_parser.sh — the shared parser region must not drift
# =============================================================================
# git-guard.sh and gh-guard.sh both need the same shell-command front end
# (heredoc stripping, segment splitting, tokenizing). They used to carry two
# hand-maintained copies of it, and the copies diverged: gh-guard grew a
# TOKENS-based `opener_runs_shell` while git-guard kept an earlier version whose
# helper declared `local s="$1" n=${#s}` — fatal under `set -u` on bash 5.2, and
# fatal in the fail-open direction (docs/known-issues.md §9(a)). The plugin's
# copy of one hook also sat a version behind while both suites reported green.
#
# The parser therefore has one canonical home, hooks/lib/shell-parse.sh, and
# scripts/sync-parser.sh copies its marked region into each hook at edit time.
# Copying only works if something notices when a copy stops matching, so this
# file is that something. It checks three things, in order of how quietly they
# would fail:
#
#   1. no copy has drifted (scripts/sync-parser.sh --check)
#   2. the drift detector actually detects drift — a --check that cannot fail is
#      worse than no check, because it reads as evidence
#   3. the hooks stay standalone: no runtime `source` of the lib, since a failed
#      source has no safe branch (continue → enforce nothing; exit 2 → block
#      every command → the hook gets removed)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$ROOT/tests/lib/harness.sh"
TEST_NAME="shared-parser"

LIB="hooks/lib/shell-parse.sh"
CARRIERS="hooks/git-guard.sh hooks/gh-guard.sh"
PLUGIN_COPIES="git-guard.sh gh-guard.sh mcp-repo-guard.sh"
# Every function the generated region is expected to provide. A hook that calls
# one of these and a region that stopped defining it is a fail-open, so the list
# is asserted rather than inferred.
REGION_FUNCS="list_match normalize_branch strip_heredocs split_segments \
tokenize command_word cmd_arg_start nested_candidates opener_runs_shell"

BEGIN_RE='^# >>> SHARED PARSER'
END_RE='^# <<< SHARED PARSER'

pass() { TEST_PASS=$((TEST_PASS + 1)); _green "  ✓"; printf ' %s\n' "$1"; }
fail() {
  TEST_FAIL=$((TEST_FAIL + 1)); _red "  ✗"; printf ' %s\n' "$1"
  [[ -n "${2:-}" ]] && { _dim "    $2"; printf '\n'; }
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - $1"
}
check() { if [[ "$1" == 0 ]]; then pass "$2"; else fail "$2" "${3:-}"; fi; }

# The region body without its sentinel lines — the same extraction sync-parser
# does, repeated here so a bug in that awk cannot hide behind itself.
region_of() {
  awk -v b="$BEGIN_RE" -v e="$END_RE" '
    $0 ~ b { inside=1; next }
    $0 ~ e { inside=0; next }
    inside { print }
  ' "$1"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== the canonical parser =="
if [[ -f "$ROOT/$LIB" ]]; then
  pass "$LIB exists"
else
  fail "$LIB is missing" "nothing to sync from"
  summary
fi
region_of "$ROOT/$LIB" > "$TMP/canonical"
check "$([[ -s "$TMP/canonical" ]] && echo 0 || echo 1)" \
  "the sentinel region is not empty"
for fn in $REGION_FUNCS; do
  n=$(grep -c "^${fn}() {" "$TMP/canonical" || true)
  check "$([[ "$n" == 1 ]] && echo 0 || echo 1)" \
    "region defines ${fn}() exactly once" "found $n definitions"
done
# Shared code that reaches for a hook's variable would work in one hook and
# silently do nothing in the other.
n=$(grep -c 'GIT_GUARD_\|GH_GUARD_\|PROTECTED_BRANCHES\|ALLOWED_DOMAINS\|CI_MODE' "$TMP/canonical" || true)
check "$([[ "$n" == 0 ]] && echo 0 || echo 1)" \
  "region references no hook-specific configuration" "$n reference(s)"

echo "== every carrier holds the canonical region, byte for byte =="
for rel in $CARRIERS; do
  f="$ROOT/$rel"
  if [[ ! -f "$f" ]]; then fail "$rel is missing"; continue; fi
  b=$(grep -c "$BEGIN_RE" "$f" || true)
  e=$(grep -c "$END_RE" "$f" || true)
  check "$([[ "$b" == 1 && "$e" == 1 ]] && echo 0 || echo 1)" \
    "$rel has exactly one sentinel pair" "begin=$b end=$e"
  region_of "$f" > "$TMP/copy"
  if cmp -s "$TMP/canonical" "$TMP/copy"; then
    pass "$rel carries the canonical region unchanged"
  else
    fail "$rel has drifted from $LIB" \
      "$(cmp "$TMP/canonical" "$TMP/copy" 2>&1 | head -c 160)"
  fi
  # A second definition outside the region would shadow the shared one, which is
  # exactly the divergence this arrangement exists to prevent.
  for fn in $REGION_FUNCS; do
    n=$(grep -c "^${fn}() {" "$f" || true)
    check "$([[ "$n" == 1 ]] && echo 0 || echo 1)" \
      "$rel defines ${fn}() once, not twice" "found $n definitions"
  done
done

echo "== the hooks stay standalone =="
for rel in $CARRIERS; do
  f="$ROOT/$rel"
  [[ -f "$f" ]] || continue
  if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+.*shell-parse' "$f"; then
    fail "$rel sources the lib at runtime" \
      "a hook must not depend on a second file; see the lib header"
  else
    pass "$rel does not source $LIB at runtime"
  fi
done
# The lib is code, not a hook: it has no stdin contract and must never be wired
# into settings as one.
if grep -q 'shell-parse' "$ROOT/plugin/hooks/hooks.json" 2>/dev/null; then
  fail "plugin/hooks/hooks.json registers the lib as a hook"
else
  pass "the lib is not registered as a hook"
fi

echo "== syntax =="
for rel in $LIB $CARRIERS; do
  it "bash -n $rel" 0 bash -n "$ROOT/$rel"
done
for name in $PLUGIN_COPIES; do
  it "bash -n plugin/hooks/$name" 0 bash -n "$ROOT/plugin/hooks/$name"
done

echo "== plugin copies are identical to hooks/ =="
for name in $PLUGIN_COPIES; do
  if cmp -s "$ROOT/hooks/$name" "$ROOT/plugin/hooks/$name"; then
    pass "plugin/hooks/$name matches hooks/$name"
  else
    fail "plugin/hooks/$name has drifted from hooks/$name"
  fi
done

# A hook is invoked by path from settings.json. Without the execute bit the
# invocation fails with 126 — which is neither 0 nor 2, so Claude Code reports a
# hook error and the tool call proceeds: the guard is simply absent. Nothing
# noticed for three releases because every suite `chmod +x`es its own hook before
# the first assertion; tests/bypass-attempts.sh does not, and its 126s are how
# this surfaced. The mode belongs to the repository, so it is asserted here
# rather than fixed at test time.
echo "== every shipped hook is executable =="
for f in "$ROOT"/hooks/*.sh "$ROOT"/plugin/hooks/*.sh; do
  rel="${f#$ROOT/}"
  case "$rel" in hooks/lib/*) continue ;; esac
  if [[ -x "$f" ]]; then
    pass "$rel is executable"
  else
    fail "$rel is not executable" "invoking it by path yields 126, not 0 or 2"
  fi
done

echo "== the drift detector =="
out=$(bash "$ROOT/scripts/sync-parser.sh" --check 2>&1); rc=$?
check "$rc" "sync-parser.sh --check reports everything current" "$out"

# A --check that always exits 0 is not evidence of anything. Tamper with a copy
# in a throwaway tree and require the failure.
FAKE="$TMP/tree"
mkdir -p "$FAKE/hooks/lib" "$FAKE/plugin/hooks" "$FAKE/scripts"
cp "$ROOT/scripts/sync-parser.sh" "$FAKE/scripts/"
cp "$ROOT/$LIB" "$FAKE/hooks/lib/"
for name in $PLUGIN_COPIES; do
  cp "$ROOT/hooks/$name" "$FAKE/hooks/$name"
  cp "$ROOT/plugin/hooks/$name" "$FAKE/plugin/hooks/$name"
done
out=$(bash "$FAKE/scripts/sync-parser.sh" --check 2>&1); rc=$?
check "$rc" "the throwaway copy of the tree starts clean" "$out"

# One character inside the region: `tokenize` stops collapsing quoted spans.
sed 's/^tokenize() {$/tokenize() { : tampered/' "$FAKE/hooks/git-guard.sh" > "$TMP/t" \
  && cat "$TMP/t" > "$FAKE/hooks/git-guard.sh"
out=$(bash "$FAKE/scripts/sync-parser.sh" --check 2>&1); rc=$?
if [[ "$rc" == 1 && "$out" == *"STALE: hooks/git-guard.sh"* ]]; then
  pass "an edit inside a generated region fails --check"
else
  fail "an edit inside a generated region was not detected" "rc=$rc out=$out"
fi

# Regenerating must repair it, or the failure above would be a dead end.
out=$(bash "$FAKE/scripts/sync-parser.sh" 2>&1); rc=$?
check "$rc" "sync-parser.sh rewrites the tampered copy" "$out"
out=$(bash "$FAKE/scripts/sync-parser.sh" --check 2>&1); rc=$?
check "$rc" "--check passes again after regeneration" "$out"
if cmp -s "$ROOT/hooks/git-guard.sh" "$FAKE/hooks/git-guard.sh"; then
  pass "the regenerated file is identical to the committed one"
else
  fail "regeneration did not reproduce the committed file" \
    "sync-parser is not idempotent, or the committed file was hand-edited"
fi

# Drift in the other direction: the plugin copy left behind.
printf '# stray line\n' >> "$FAKE/plugin/hooks/gh-guard.sh"
out=$(bash "$FAKE/scripts/sync-parser.sh" --check 2>&1); rc=$?
if [[ "$rc" == 1 && "$out" == *"STALE: plugin/hooks/gh-guard.sh"* ]]; then
  pass "a stale plugin copy fails --check"
else
  fail "a stale plugin copy was not detected" "rc=$rc out=$out"
fi

# A hook that loses its sentinels would otherwise be skipped silently and never
# receive another parser fix.
sed "/$BEGIN_RE/d" "$FAKE/hooks/gh-guard.sh" > "$TMP/t2" \
  && cat "$TMP/t2" > "$FAKE/hooks/gh-guard.sh"
out=$(bash "$FAKE/scripts/sync-parser.sh" --check 2>&1); rc=$?
if [[ "$rc" != 0 && "$out" == *"sentinel"* ]]; then
  pass "a carrier with no sentinels is an error, not a skip"
else
  fail "a carrier with no sentinels was skipped silently" "rc=$rc out=$out"
fi

summary
