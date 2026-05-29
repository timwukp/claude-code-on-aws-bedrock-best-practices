#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/token-budget-guard.sh"
chmod +x "$HOOK"

TMP=$(mktemp -d)
export CLAUDE_TOKEN_STATE="$TMP/sessions"
export CLAUDE_TOKEN_BUDGET=1000
export CLAUDE_CALL_BUDGET=10

PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { PASS=$((PASS+1)); echo "  ✓ $1"; } || { FAIL=$((FAIL+1)); echo "  ✗ $1 (exp $2 got $3)"; }; }

pre()  { echo "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo\"}}" | "$HOOK" >/dev/null 2>&1; echo $?; }
post() { echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$1\",\"tool_response\":{\"usage\":{\"input_tokens\":$2,\"output_tokens\":$3}}}" | "$HOOK" >/dev/null 2>&1; echo $?; }

# Fresh session: first call passes
rc=$(pre "sess-A"); check "first PreToolUse allows" 0 "$rc"

# Record 600 tokens via PostToolUse
rc=$(post "sess-A" 300 300); check "PostToolUse records 600" 0 "$rc"
total=$(cat "$CLAUDE_TOKEN_STATE/sess-A.tokens"); check "token total 600" 600 "$total"

# Still under budget
rc=$(pre "sess-A"); check "still under budget" 0 "$rc"

# Cross the budget
rc=$(post "sess-A" 200 300); check "cross budget post" 0 "$rc"
total=$(cat "$CLAUDE_TOKEN_STATE/sess-A.tokens"); check "token total 1100" 1100 "$total"

# Now PreToolUse should block
rc=$(pre "sess-A"); check "blocked when over budget" 2 "$rc"

# Different session not affected
rc=$(pre "sess-B"); check "fresh session allowed" 0 "$rc"

# Call budget: spam 11 PreToolUse on sess-C
for i in $(seq 1 10); do pre "sess-C" >/dev/null; done
rc=$(pre "sess-C"); check "11th call blocked by call budget" 2 "$rc"

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
