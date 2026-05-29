#!/usr/bin/env bash
# Measure hook latency over 200 invocations each. Output p50/p95/p99 to TSV.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tests/results/hook-latency.tsv"
mkdir -p "$ROOT/tests/results"
printf 'hook\tn\tp50_ms\tp95_ms\tp99_ms\tmax_ms\n' > "$OUT"

bench() {
  local name="$1" payload="$2" hook="$3" n="$4"
  local times=()
  local i
  for i in $(seq 1 "$n"); do
    local t0 t1
    t0=$(python3 -c 'import time;print(int(time.time()*1000))')
    printf '%s' "$payload" | "$hook" >/dev/null 2>&1 || true
    t1=$(python3 -c 'import time;print(int(time.time()*1000))')
    times+=( $((t1 - t0)) )
  done
  python3 - "$name" "$n" "$OUT" <<PY "${times[@]}"
import sys, math
name, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
xs = sorted(int(x) for x in sys.argv[4:])
def p(q): return xs[max(0,min(len(xs)-1, int(round(q/100*(len(xs)-1)))))]
with open(out,'a') as f:
  f.write(f"{name}\t{n}\t{p(50)}\t{p(95)}\t{p(99)}\t{p(100)}\n")
print(f"{name}: p50={p(50)}ms p95={p(95)}ms p99={p(99)}ms max={p(100)}ms")
PY
}

PII_CLEAN=$(jq -nc --arg p "Write a sort function" '{hook_event_name:"UserPromptSubmit",session_id:"x",cwd:"/tmp",prompt:$p}')
PII_DIRTY=$(jq -nc --arg p "card 4111-1111-1111-1111" '{hook_event_name:"UserPromptSubmit",session_id:"x",cwd:"/tmp",prompt:$p}')
GIT_CLEAN=$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la"}}')
GIT_BLOCK=$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"git push --force origin main"}}')
AUDIT=$(jq -nc '{hook_event_name:"PostToolUse",session_id:"bench",tool_name:"Bash",tool_input:{command:"ls"}}')

TMP=$(mktemp -d)
export AUDIT_HMAC_KEY=benchkey
export CLAUDE_AUDIT_LOG="$TMP/audit.jsonl"
export CLAUDE_AUDIT_STATE="$TMP/state"
export CLAUDE_HOOK_TELEMETRY="$TMP/hooks.jsonl"
mkdir -p "$CLAUDE_AUDIT_STATE"

bench pii-guard-clean "$PII_CLEAN"  hooks/pii-guard.sh    200
bench pii-guard-dirty "$PII_DIRTY"  hooks/pii-guard.sh    200
bench git-guard-clean "$GIT_CLEAN"  hooks/git-guard.sh    200
bench git-guard-block "$GIT_BLOCK"  hooks/git-guard.sh    200
bench audit-logger    "$AUDIT"      hooks/audit-logger.sh 200

echo
column -t -s$'\t' "$OUT"
