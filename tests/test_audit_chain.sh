#!/usr/bin/env bash
# Verifies HMAC chain detects: edit, deletion, reorder, insertion. And fail-closed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/audit-logger.sh"
VERIFY="$ROOT/scripts/chain-verify.sh"
chmod +x "$HOOK" "$VERIFY"

TMP=$(mktemp -d)
LOG="$TMP/audit.jsonl"
STATE="$TMP/state"
KEY="$TMP/key"
mkdir -p "$STATE"
openssl rand -hex 32 > "$KEY"

export CLAUDE_AUDIT_LOG="$LOG"
export CLAUDE_AUDIT_STATE="$STATE"
export AUDIT_HMAC_KEY=$(cat "$KEY")
export CLAUDE_AUDIT_SIEM_REQUIRED=0

PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { PASS=$((PASS+1)); echo "  ✓ $1"; } || { FAIL=$((FAIL+1)); echo "  ✗ $1 (expected $2 got $3)"; }; }

emit() {
  local ev="$1" tool="$2" cmd="$3"
  echo "{\"hook_event_name\":\"$ev\",\"session_id\":\"sess-1\",\"cwd\":\"/tmp\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$cmd\"}}" \
    | "$HOOK" >/dev/null 2>&1
  return $?
}

# --- 1. Emit 5 events, chain should be intact ---
emit PostToolUse Bash "echo a"; check "emit 1 ok" 0 $?
emit PostToolUse Bash "echo b"; check "emit 2 ok" 0 $?
emit PostToolUse Bash "echo c"; check "emit 3 ok" 0 $?
emit PostToolUse Bash "echo d"; check "emit 4 ok" 0 $?
emit PostToolUse Bash "echo e"; check "emit 5 ok" 0 $?

lines=$(awk 'END{print NR}' "$LOG"); check "5 log lines" 5 "$lines"

bash "$VERIFY" "$LOG" >/dev/null 2>&1; check "intact chain verifies" 0 $?

# --- 2. Tamper: edit middle line ---
cp "$LOG" "$TMP/audit.edited"
sed -i.bak '3s/echo c/echo TAMPER/' "$TMP/audit.edited"
bash "$VERIFY" "$TMP/audit.edited" >/dev/null 2>&1; check "edited line detected" 1 $?

# --- 3. Tamper: delete a line ---
cp "$LOG" "$TMP/audit.del"
sed -i.bak '3d' "$TMP/audit.del"
bash "$VERIFY" "$TMP/audit.del" >/dev/null 2>&1; check "deleted line detected" 1 $?

# --- 4. Tamper: reorder ---
cp "$LOG" "$TMP/audit.reorder"
{ sed -n '1p' "$LOG"; sed -n '3p' "$LOG"; sed -n '2p' "$LOG"; sed -n '4,5p' "$LOG"; } > "$TMP/audit.reorder"
bash "$VERIFY" "$TMP/audit.reorder" >/dev/null 2>&1; check "reordered lines detected" 1 $?

# --- 5. Tamper: insert forged line ---
cp "$LOG" "$TMP/audit.insert"
forged='{"ts":"2026-05-29T00:00:00Z","user":"attacker","host":"x","event":"PostToolUse","session_id":"forged","cwd":"/tmp","tool":"Bash","action":"rm -rf /","prev_hash":"GENESIS","hmac":"deadbeef"}'
{ echo "$forged"; cat "$LOG"; } > "$TMP/audit.insert"
bash "$VERIFY" "$TMP/audit.insert" >/dev/null 2>&1; check "inserted line detected" 1 $?

# --- 6. Fail-closed: unwritable log dir + no aws ---
unset CLAUDE_AUDIT_CLOUDWATCH_GROUP
RO_DIR="$TMP/readonly"; mkdir "$RO_DIR"; chmod 0500 "$RO_DIR"
unset HOME  # block fallback ~/.claude/
HOME="$RO_DIR" CLAUDE_AUDIT_LOG="$RO_DIR/x.jsonl" CLAUDE_AUDIT_STATE="$RO_DIR/state" \
  bash -c 'echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"x\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | '"$HOOK"' >/dev/null 2>&1'
rc=$?
check "fail-closed when no log destination" 2 "$rc"

# --- 7. Fail-open override works ---
HOME="$RO_DIR" CLAUDE_AUDIT_LOG="$RO_DIR/x.jsonl" CLAUDE_AUDIT_STATE="$RO_DIR/state" CLAUDE_AUDIT_FAIL_OPEN=1 \
  bash -c 'echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"x\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | '"$HOOK"' >/dev/null 2>&1'
rc=$?
check "fail-open allows when set" 0 "$rc"

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
