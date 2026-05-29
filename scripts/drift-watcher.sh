#!/usr/bin/env bash
# =============================================================================
# Drift Watcher — real-time tamper detection for managed config and hooks
# =============================================================================
# Watches a set of files and emits an alert the moment any of them change.
# Linux: uses inotifywait (apt: inotify-tools / dnf: inotify-tools)
# macOS: uses fswatch (brew install fswatch)
# Fallback: poll every 60s comparing sha256 baseline
#
# Output: JSONL events appended to $CLAUDE_DRIFT_LOG (default
#         /var/log/claude-code/drift.jsonl) AND piped to $CLAUDE_DRIFT_ALERT_CMD
#         if set (e.g., curl webhook).
#
# Run as: a systemd unit / launchd job under root.
#
# Test mode: --self-test runs a 2-second test loop, mutates a file, expects
# alert <1s, exits 0 on success.
# =============================================================================

set -u

LOG="${CLAUDE_DRIFT_LOG:-/var/log/claude-code/drift.jsonl}"
ALERT_CMD="${CLAUDE_DRIFT_ALERT_CMD:-}"
WATCHED=(
  "${WATCH_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"
  "${WATCH_HOOKS_DIR:-/usr/local/etc/claude-code/hooks}"
  "${WATCH_WRAPPER:-/usr/local/bin/claude}"
)
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

emit() {
  local path="$1" kind="$2" hash_before="$3" hash_after="$4"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  local host; host=$(hostname 2>/dev/null || echo unknown)
  local entry
  entry=$(jq -nc \
    --arg ts "$ts" --arg host "$host" --arg path "$path" --arg kind "$kind" \
    --arg before "$hash_before" --arg after "$hash_after" \
    '{ts:$ts,host:$host,path:$path,kind:$kind,sha256_before:$before,sha256_after:$after}')
  echo "$entry" >> "$LOG" 2>/dev/null
  if [[ -n "$ALERT_CMD" ]]; then
    printf '%s\n' "$entry" | bash -c "$ALERT_CMD" >/dev/null 2>&1 || true
  fi
  printf '[drift] %s %s %s\n' "$ts" "$kind" "$path"
}

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; fi
}

# ---- Self-test mode ---------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  TMP=$(mktemp -d)
  TEST_FILE="$TMP/managed-settings.json"
  echo '{"a":1}' > "$TEST_FILE"
  TEST_LOG="$TMP/drift.jsonl"
  WATCHED=("$TEST_FILE")
  CLAUDE_DRIFT_LOG="$TEST_LOG"
  LOG="$TEST_LOG"

  baseline=$(hash_of "$TEST_FILE")

  # Background poll loop
  ( while true; do
      cur=$(hash_of "$TEST_FILE")
      if [[ "$cur" != "$baseline" ]]; then
        emit "$TEST_FILE" "modified" "$baseline" "$cur"
        baseline="$cur"
      fi
      sleep 0.1
    done ) &
  WATCHER_PID=$!

  sleep 0.5
  echo '{"a":2,"tampered":true}' > "$TEST_FILE"
  start=$(python3 -c 'import time;print(time.time())')

  # Wait up to 2 seconds for log entry
  for i in $(seq 1 40); do
    if [[ -s "$TEST_LOG" ]]; then break; fi
    sleep 0.05
  done
  end=$(python3 -c 'import time;print(time.time())')
  kill "$WATCHER_PID" 2>/dev/null
  wait "$WATCHER_PID" 2>/dev/null || true

  if [[ -s "$TEST_LOG" ]]; then
    elapsed_ms=$(python3 -c "print(int(($end - $start) * 1000))")
    echo "self-test PASS: drift detected in ${elapsed_ms}ms"
    cat "$TEST_LOG"
    exit 0
  else
    echo "self-test FAIL: no drift event recorded"; exit 1
  fi
fi

# ---- Build baseline ---------------------------------------------------------
declare -A BASELINE
collect_files() {
  local p
  for p in "$@"; do
    if [[ -d "$p" ]]; then
      while IFS= read -r f; do BASELINE[$f]=$(hash_of "$f"); done < <(find "$p" -type f 2>/dev/null)
    elif [[ -f "$p" ]]; then
      BASELINE[$p]=$(hash_of "$p")
    fi
  done
}

collect_files "${WATCHED[@]}"
echo "[drift-watcher] baselined ${#BASELINE[@]} files"

# ---- Watcher implementation -------------------------------------------------
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -mrq -e modify,create,delete,move "${WATCHED[@]}" 2>/dev/null \
    | while read -r path event file; do
        full="${path}${file}"
        cur=$(hash_of "$full" 2>/dev/null || echo "")
        prev="${BASELINE[$full]:-}"
        if [[ "$cur" != "$prev" ]]; then
          emit "$full" "$event" "$prev" "$cur"
          BASELINE[$full]="$cur"
        fi
      done
elif command -v fswatch >/dev/null 2>&1; then
  fswatch -0 "${WATCHED[@]}" \
    | while IFS= read -r -d '' f; do
        cur=$(hash_of "$f" 2>/dev/null || echo "")
        prev="${BASELINE[$f]:-}"
        if [[ "$cur" != "$prev" ]]; then
          emit "$f" "fs_event" "$prev" "$cur"
          BASELINE[$f]="$cur"
        fi
      done
else
  echo "[drift-watcher] no inotifywait/fswatch — polling every 1s"
  while true; do
    for f in "${!BASELINE[@]}"; do
      cur=$(hash_of "$f" 2>/dev/null || echo "")
      prev="${BASELINE[$f]}"
      if [[ "$cur" != "$prev" ]]; then
        emit "$f" "polled_change" "$prev" "$cur"
        BASELINE[$f]="$cur"
      fi
    done
    sleep 1
  done
fi
