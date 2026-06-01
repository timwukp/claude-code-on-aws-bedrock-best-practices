#!/usr/bin/env bash
# =============================================================================
# Test suite for claude-code-bedrock-security plugin
# =============================================================================
# Comprehensive, reproducible assertion suite covering all 5 hooks, the chain
# verifier, every PII pattern, all git-guard checks, both budget dimensions,
# the wrapper's full exit-code matrix, and chain tamper modes.
#
# Usage:   bash tests/run-tests.sh
# Exit:    0 if all assertions pass, 1 otherwise.
# Isolation: runs in a temp HOME so nothing touches your real ~/.claude.
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOKS="$ROOT/hooks"
SCRIPTS="$ROOT/scripts"
PII="$HOOKS/pii-guard.sh"
GIT="$HOOKS/git-guard.sh"
WRAP="$HOOKS/hook-wrapper.sh"
AUDIT="$HOOKS/audit-logger.sh"
TOKEN="$HOOKS/token-budget-guard.sh"
VERIFY="$SCRIPTS/chain-verify.sh"

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
mkdir -p "$HOME/.claude"

PASS=0; FAIL=0
FAILED_NAMES=()

# assert_exit <expected_code> <name> <input-json> <hook> [extra args...]
assert_exit() {
  local want="$1" name="$2" input="$3" hook="$4"; shift 4
  local got
  printf '%s' "$input" | bash "$hook" "$@" >/dev/null 2>&1; got=$?
  if [[ "$got" == "$want" ]]; then
    printf '  ✅ %-46s (exit %s)\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  ❌ %-46s (want %s, got %s)\n' "$name" "$want" "$got"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
  fi
}

# assert_label <name> <expected_label> <input-json> [event]
# Expects pii-guard to BLOCK (exit 2) AND the named pattern to appear in stderr.
assert_label() {
  local name="$1" label="$2" input="$3"
  local err got
  err="$(printf '%s' "$input" | bash "$PII" 2>&1 >/dev/null)"; got=$?
  if [[ "$got" == 2 && "$err" == *"$label"* ]]; then
    printf '  ✅ %-46s (blocked: %s)\n' "$name" "$label"; PASS=$((PASS+1))
  else
    printf '  ❌ %-46s (want block+%s, exit %s)\n' "$name" "$label" "$got"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
  fi
}

pii() { printf '{"hook_event_name":"UserPromptSubmit","prompt":%s}' "$1"; }   # $1 must be a JSON string

echo "============================================================"
echo " claude-code-bedrock-security — comprehensive test suite"
echo " plugin root:  $ROOT"
echo " sandbox HOME: $HOME"
echo "============================================================"

echo
echo "[1] Syntax checks"
for f in "$HOOKS"/*.sh "$SCRIPTS"/*.sh; do
  if bash -n "$f" 2>/dev/null; then printf '  ✅ %-46s\n' "$(basename "$f") syntax"; PASS=$((PASS+1));
  else printf '  ❌ %-46s\n' "$(basename "$f") syntax"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$(basename "$f") syntax"); fi
done

echo
echo "[2] pii-guard — secrets & credentials (all patterns, verify correct label)"
# NOTE: test fixtures that look like real credentials are assembled from fragments
# at runtime so GitHub secret-scanning / push-protection never sees a complete
# token pattern in the source. Concatenation still yields a string that triggers
# the corresponding pii-guard regex, so the assertions remain valid.
AKIA_FIX="AKIA""IOSFODNN7""EXAMPLE"                       # AWS example access key
SECRET_FIX="wJalrXUtnFEMI/K7MDENG/""bPxRfiCYEXAMPLEKEY"   # AWS example secret
GHP_FIX="ghp_""0123456789abcdefghijABCDEFGHIJ012345"      # GitHub PAT shape (fake)
JWT_FIX="eyJhbGciOiJIUzI1NiIsIn"".eyJzdWIiOiIxMjM0NTY"".SflKxwRJSMeKKF2QT4"
assert_label "AWS access key"      "AWS_ACCESS_KEY"        "$(pii "\"key $AKIA_FIX\"")"
assert_label "AWS secret key"      "AWS_SECRET_KEY"        "$(pii "\"secret \\\"$SECRET_FIX\\\"\"")"
assert_label "generic api key"     "API_KEY_ASSIGNMENT"    "$(pii '"api_key = abcdef0123456789ghijkl"')"
assert_label "private key header"  "PRIVATE_KEY"           "$(pii '"-----BEGIN RSA PRIVATE KEY-----"')"
assert_label "JWT token"           "JWT_TOKEN"             "$(pii "\"$JWT_FIX\"")"
assert_label "DB connection string" "DB_CONNECTION_STRING" "$(pii '"postgres://user:pass@dbhost:5432/prod"')"
assert_label "password assignment" "PASSWORD_ASSIGNMENT"   "$(pii '"password=SuperSecret123"')"
assert_label "GitHub token"        "GIT_TOKEN"             "$(pii "\"$GHP_FIX\"")"
assert_label "Slack token"         "SLACK_TOKEN"           "$(pii '"xoxb-1234567890-abcdefABCDEF"')"
assert_label "hex secret (sha256)" "HEX_SECRET"            "$(pii '"digest a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"')"
assert_label "credit card 16"      "CREDIT_CARD_16"        "$(pii '"card 4111 1111 1111 1111"')"
assert_label "credit card amex"    "CREDIT_CARD_AMEX"      "$(pii '"amex 3782 822463 10005"')"
assert_label "email address"       "EMAIL_ADDRESS"         "$(pii '"reach me at john.doe@example.com"')"
assert_label "international phone"  "PHONE_INTL"            "$(pii '"call +1 415 555 1234 now"')"
assert_label "passport number"     "PASSPORT_NUMBER"       "$(pii '"passport AB1234567"')"

echo
echo "[3] pii-guard — national identifiers, 7 jurisdictions (verify correct label)"
assert_label "US SSN"        "US_SSN"       "$(pii '"SSN 123-45-6789"')"
assert_label "US ITIN"       "US_ITIN"      "$(pii '"ITIN 912-78-1234"')"
assert_label "UK NINO"       "UK_NINO"      "$(pii '"NINO AB123456C"')"
assert_label "UK NHS"        "UK_NHS"       "$(pii '"NHS 943-476-5919"')"
assert_label "JP My Number"  "JP_MYNUMBER"  "$(pii '"No 1234-5678-9012"')"
assert_label "KR RRN"        "KR_RRN"       "$(pii '"RRN 900101-1234567"')"
assert_label "SG NRIC"       "SG_NRIC"      "$(pii '"NRIC S1234567A"')"
assert_label "EU IBAN"       "EU_IBAN"      "$(pii '"IBAN DE89370400440532013000"')"
assert_label "AU TFN"        "AU_TFN"       "$(pii '"TFN 123-456-789"')"
assert_label "AU Medicare"   "AU_MEDICARE"  "$(pii '"Medicare 2123-45670-1"')"

echo
echo "[4] pii-guard — benign input (expect ALLOW=0, no false positives)"
assert_exit 0 "plain sentence"    "$(pii '"refactor the parser function please"')" "$PII"
assert_exit 0 "numbers/decimals"  "$(pii '"the year was 2024 and pi is 3.14159"')" "$PII"
assert_exit 0 "version string"    "$(pii '"version 1.2.3 build 456"')"             "$PII"
assert_exit 0 "short number"      "$(pii '"call me at extension 4567"')"           "$PII"
assert_exit 0 "uuid not card/mynumber" "$(pii '"id 12345678-1234-1234-1234-123456789012"')" "$PII"
assert_exit 0 "text under 8 chars" "$(pii '"hi"')"                                 "$PII"

echo
echo "[5] pii-guard — PreToolUse scans tool_input (not just prompts)"
assert_exit 2 "PreToolUse blocks AWS key in command" "{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"echo $AKIA_FIX\"}}" "$PII"
assert_exit 2 "PreToolUse blocks secret in file write" '{"hook_event_name":"PreToolUse","tool_input":{"file_path":"x.env","content":"password=SuperSecret123"}}' "$PII"
assert_exit 0 "PreToolUse allows clean command" '{"hook_event_name":"PreToolUse","tool_input":{"command":"ls -la"}}' "$PII"
assert_exit 0 "unrelated event ignored" '{"hook_event_name":"SessionStart"}' "$PII"

echo
echo "[6] git-guard — all 8 checks (BLOCK on violation, ALLOW otherwise)"
assert_exit 2 "remote add disallowed url"  '{"tool_name":"Bash","tool_input":{"command":"git remote add evil https://evil.com/x.git"}}' "$GIT"
assert_exit 0 "remote add allowed url"     '{"tool_name":"Bash","tool_input":{"command":"git remote add origin https://github.com/me/x.git"}}' "$GIT"
assert_exit 2 "remote rename blocked"      '{"tool_name":"Bash","tool_input":{"command":"git remote rename origin up"}}' "$GIT"
assert_exit 2 "remote rm blocked"          '{"tool_name":"Bash","tool_input":{"command":"git remote rm origin"}}' "$GIT"
assert_exit 2 "force push (--force)"       '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' "$GIT"
assert_exit 2 "force push (--force-with-lease)" '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin main"}}' "$GIT"
assert_exit 2 "push to protected branch"   '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$GIT"
assert_exit 0 "push to feature branch"     '{"tool_name":"Bash","tool_input":{"command":"git push origin feature/x"}}' "$GIT"
assert_exit 2 "reset --hard"               '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}' "$GIT"
assert_exit 2 "clean -fd"                  '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}' "$GIT"
assert_exit 2 "checkout --force"           '{"tool_name":"Bash","tool_input":{"command":"git checkout --force main"}}' "$GIT"
assert_exit 0 "git status (read-only)"     '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "$GIT"
assert_exit 0 "non-git bash ignored"       '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' "$GIT"
assert_exit 0 "non-Bash tool ignored"      '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "$GIT"
# Configurable knobs
CI_MODE=before; GIT_GUARD_CI_MODE=true assert_exit 0 "CI mode relaxes branch protect" '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$GIT"
GIT_GUARD_DISABLED=true assert_exit 0 "emergency disable bypasses all"                 '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' "$GIT"

echo
echo "[7] token-budget-guard — both dimensions"
export CLAUDE_CALL_BUDGET=2 CLAUDE_TOKEN_BUDGET=999999999
assert_exit 0 "call 1 under call-budget" '{"hook_event_name":"PreToolUse","session_id":"cb"}' "$TOKEN"
assert_exit 0 "call 2 under call-budget" '{"hook_event_name":"PreToolUse","session_id":"cb"}' "$TOKEN"
assert_exit 2 "call 3 over call-budget"  '{"hook_event_name":"PreToolUse","session_id":"cb"}' "$TOKEN"
unset CLAUDE_CALL_BUDGET CLAUDE_TOKEN_BUDGET
# Token dimension: record usage via PostToolUse, then PreToolUse must block
export CLAUDE_TOKEN_BUDGET=300 CLAUDE_CALL_BUDGET=999999
printf '{"hook_event_name":"PostToolUse","session_id":"tk","tool_response":{"usage":{"input_tokens":200,"output_tokens":200}}}' | bash "$TOKEN" >/dev/null 2>&1
assert_exit 2 "PreToolUse blocks over token-budget" '{"hook_event_name":"PreToolUse","session_id":"tk"}' "$TOKEN"
assert_exit 0 "fresh session not blocked"           '{"hook_event_name":"PreToolUse","session_id":"tk-new"}' "$TOKEN"
unset CLAUDE_TOKEN_BUDGET CLAUDE_CALL_BUDGET

echo
echo "[8] hook-wrapper — full exit-code matrix + telemetry"
CRASH="$SANDBOX/crash.sh"; printf '#!/usr/bin/env bash\necho boom >&2; exit 99\n' > "$CRASH"; chmod +x "$CRASH"
OKH="$SANDBOX/ok.sh";      printf '#!/usr/bin/env bash\nexit 0\n' > "$OKH"; chmod +x "$OKH"
BLOCKH="$SANDBOX/block.sh"; printf '#!/usr/bin/env bash\necho deny >&2; exit 2\n' > "$BLOCKH"; chmod +x "$BLOCKH"
SLOWH="$SANDBOX/slow.sh";  printf '#!/usr/bin/env bash\nsleep 2\n' > "$SLOWH"; chmod +x "$SLOWH"
assert_exit 0 "wrap passing hook → 0"   '{"hook_event_name":"PreToolUse","session_id":"w"}' "$WRAP" "$OKH"
assert_exit 2 "wrap blocking hook → 2"  '{"hook_event_name":"PreToolUse","session_id":"w"}' "$WRAP" "$BLOCKH"
assert_exit 2 "wrap crashing hook → 2 (fail-closed)" '{"hook_event_name":"PreToolUse","session_id":"w"}' "$WRAP" "$CRASH"
CLAUDE_HOOK_TIMEOUT_MS=500 assert_exit 2 "wrap timeout → 2 (fail-closed)" '{"hook_event_name":"PreToolUse","session_id":"w"}' "$WRAP" "$SLOWH"
assert_exit 2 "missing hook arg → 2"    '{"hook_event_name":"PreToolUse"}' "$WRAP" "$SANDBOX/does-not-exist.sh"
# Telemetry line emitted
printf '{"hook_event_name":"PreToolUse","session_id":"tel"}' | bash "$WRAP" "$OKH" >/dev/null 2>&1
TEL="$HOME/.claude/claude-code-security/hooks.jsonl"
if [[ -s "$TEL" ]] && grep -q '"status"' "$TEL"; then printf '  ✅ %-46s\n' "telemetry line emitted"; PASS=$((PASS+1));
else printf '  ❌ %-46s\n' "telemetry line emitted"; FAIL=$((FAIL+1)); FAILED_NAMES+=("telemetry emitted"); fi

echo
echo "[9] audit-logger — events logged across event types"
LOG="$HOME/.claude/claude-code-security/audit.jsonl"; rm -f "$LOG"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"hello"}' | bash "$AUDIT" >/dev/null 2>&1
for i in 1 2 3; do
  printf '{"hook_event_name":"PostToolUse","session_id":"a","tool_name":"Bash","tool_input":{"command":"echo %s"}}' "$i" | bash "$AUDIT" >/dev/null 2>&1
done
nlines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [[ "$nlines" == 4 ]]; then printf '  ✅ %-46s (%s lines)\n' "4 events logged (1 prompt + 3 tool)" "$nlines"; PASS=$((PASS+1));
else printf '  ❌ %-46s (got %s)\n' "4 events logged" "$nlines"; FAIL=$((FAIL+1)); FAILED_NAMES+=("4 events logged"); fi
# Each entry carries prev_hash and hmac
if [[ $(grep -c '"hmac"' "$LOG") == 4 && $(grep -c '"prev_hash"' "$LOG") == 4 ]]; then
  printf '  ✅ %-46s\n' "every entry has prev_hash + hmac"; PASS=$((PASS+1));
else printf '  ❌ %-46s\n' "every entry has prev_hash + hmac"; FAIL=$((FAIL+1)); FAILED_NAMES+=("hmac fields"); fi

echo
echo "[10] chain-verify — intact + 3 tamper modes"
assert_exit 0 "intact chain verifies" "" "$VERIFY" "$LOG"
# edit
cp "$LOG" "$LOG.edit"; sed -i.b '2s/echo 1/echo HACKED/' "$LOG.edit"
assert_exit 1 "edit detected"   "" "$VERIFY" "$LOG.edit"
# delete a middle line
sed '3d' "$LOG" > "$LOG.del"
assert_exit 1 "deletion detected" "" "$VERIFY" "$LOG.del"
# reorder two lines (swap 2 and 3)
awk 'NR==2{l2=$0;next} NR==3{print $0;print l2;next} {print}' "$LOG" > "$LOG.reorder"
assert_exit 1 "reorder detected" "" "$VERIFY" "$LOG.reorder"

echo
echo "[11] JSON validity"
if command -v jq >/dev/null 2>&1; then
  for j in "$ROOT/.claude-plugin/plugin.json" "$HOOKS/hooks.json"; do
    if jq empty "$j" 2>/dev/null; then printf '  ✅ %-46s\n' "$(basename "$j") valid"; PASS=$((PASS+1));
    else printf '  ❌ %-46s\n' "$(basename "$j") valid"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$(basename "$j") valid"); fi
  done
else
  printf '  ⚠️  jq not installed — skipping JSON validation\n'
fi

rm -rf "$SANDBOX"

echo
echo "============================================================"
echo " RESULT: $PASS passed, $FAIL failed  (total $((PASS+FAIL)))"
echo "============================================================"
if [[ "$FAIL" -gt 0 ]]; then printf ' Failed: %s\n' "${FAILED_NAMES[*]}"; exit 1; fi
exit 0
