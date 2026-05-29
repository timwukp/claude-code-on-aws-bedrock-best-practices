#!/usr/bin/env bash
# Verify hook-wrapper telemetry, fail-closed, timeout behaviour.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/hooks/hook-wrapper.sh"
chmod +x "$WRAPPER"

TMP=$(mktemp -d)
TELEMETRY="$TMP/hooks.jsonl"
export CLAUDE_HOOK_TELEMETRY="$TELEMETRY"

PASS=0; FAIL=0
check() { local d="$1" e="$2" a="$3"
  if [[ "$e" == "$a" ]]; then PASS=$((PASS+1)); echo "  ✓ $d"
  else FAIL=$((FAIL+1)); echo "  ✗ $d (expected $e, got $a)"; fi
}

# 1. ok: wrap a hook that exits 0
ok_hook="$TMP/ok.sh"; printf '#!/bin/sh\nexit 0\n' > "$ok_hook"; chmod +x "$ok_hook"
echo '{"hook_event_name":"PreToolUse","session_id":"s1"}' | "$WRAPPER" "$ok_hook" >/dev/null 2>&1
check "ok hook exits 0"          0 $?

# 2. blocked: wrap a hook that exits 2
blk_hook="$TMP/blk.sh"; printf '#!/bin/sh\nexit 2\n' > "$blk_hook"; chmod +x "$blk_hook"
echo '{"hook_event_name":"PreToolUse","session_id":"s2"}' | "$WRAPPER" "$blk_hook" >/dev/null 2>&1
check "blocked hook exits 2"     2 $?

# 3. crashed: wrap a hook that exits 1 → fail-closed → wrapper exits 2
crash_hook="$TMP/crash.sh"; printf '#!/bin/sh\nexit 1\n' > "$crash_hook"; chmod +x "$crash_hook"
echo '{"hook_event_name":"PreToolUse","session_id":"s3"}' | "$WRAPPER" "$crash_hook" >/dev/null 2>&1
check "crashed hook → fail-closed exits 2" 2 $?

# 4. timeout: wrap a sleep
slow_hook="$TMP/slow.sh"; printf '#!/bin/sh\nsleep 5\n' > "$slow_hook"; chmod +x "$slow_hook"
CLAUDE_HOOK_TIMEOUT_MS=300 echo '{"hook_event_name":"PreToolUse","session_id":"s4"}' | env CLAUDE_HOOK_TIMEOUT_MS=300 "$WRAPPER" "$slow_hook" >/dev/null 2>&1
check "timeout hook exits 2"     2 $?

# 5. telemetry contents
sleep 0.1
lines=$(wc -l < "$TELEMETRY"); check "4 telemetry lines emitted" 4 $lines

# 6. each line has required fields
fields_ok=$(jq -s 'all(has("ts") and has("hook") and has("duration_ms") and has("exit_code") and has("status"))' "$TELEMETRY")
check "telemetry fields complete" "true" "$fields_ok"

# 7. statuses recorded correctly
ok_count=$(jq -s '[.[]|select(.status=="ok")]|length' "$TELEMETRY")
blk_count=$(jq -s '[.[]|select(.status=="blocked")]|length' "$TELEMETRY")
crash_count=$(jq -s '[.[]|select(.status=="crashed")]|length' "$TELEMETRY")
to_count=$(jq -s '[.[]|select(.status=="timeout")]|length' "$TELEMETRY")
check "status=ok recorded"       1 "$ok_count"
check "status=blocked recorded"  1 "$blk_count"
check "status=crashed recorded"  1 "$crash_count"
check "status=timeout recorded"  1 "$to_count"

# 8. duration_ms is plausible for ok hook (< 1000)
ok_dur=$(jq -s '[.[]|select(.status=="ok")][0].duration_ms' "$TELEMETRY")
[[ "$ok_dur" -lt 1000 ]] && PASS=$((PASS+1)) && echo "  ✓ ok hook duration <1000ms ($ok_dur)" || { FAIL=$((FAIL+1)); echo "  ✗ ok hook duration ${ok_dur}ms"; }

# 9. timeout hook duration ~ 300ms
to_dur=$(jq -s '[.[]|select(.status=="timeout")][0].duration_ms' "$TELEMETRY")
if [[ "$to_dur" -ge 250 && "$to_dur" -le 1500 ]]; then PASS=$((PASS+1)); echo "  ✓ timeout duration ~300ms ($to_dur)"
else FAIL=$((FAIL+1)); echo "  ✗ timeout duration ${to_dur}ms"; fi

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
