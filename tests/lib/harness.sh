#!/usr/bin/env bash
# Tiny test harness — POSIX-ish, no bats dependency.
# Usage:
#   source tests/lib/harness.sh
#   it "description" expected_exit_code command...
#   summary  # at end of file

set -u

: "${TEST_PASS:=0}"
: "${TEST_FAIL:=0}"
: "${TEST_FAIL_DETAILS:=}"
: "${TEST_NAME:=harness}"

_color() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
_red()   { _color '0;31'; printf '%s' "$1"; _color 0; }
_green() { _color '0;32'; printf '%s' "$1"; _color 0; }
_dim()   { _color '0;90'; printf '%s' "$1"; _color 0; }

it() {
  local desc="$1" expected="$2"; shift 2
  local out; local actual
  out=$("$@" 2>&1); actual=$?
  if [[ "$actual" == "$expected" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    _green "  ✓"; printf ' %s\n' "$desc"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    _red "  ✗"; printf ' %s\n' "$desc"
    _dim "    expected exit $expected, got $actual"; printf '\n'
    [[ -n "$out" ]] && _dim "    output: $(printf %s "$out" | head -c 200)" && printf '\n'
    TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - ${desc} (exp ${expected}, got ${actual})"
  fi
}

# Pipe stdin into a hook and assert exit code
hook_with_input() {
  local hook="$1" expected="$2" input="$3"
  local actual
  printf '%s' "$input" | "$hook" >/dev/null 2>&1
  actual=$?
  [[ "$actual" == "$expected" ]] && return 0 || return 1
}

assert_blocked() {
  local hook="$1" payload="$2" desc="$3"
  if hook_with_input "$hook" 2 "$payload"; then
    TEST_PASS=$((TEST_PASS + 1))
    _green "  ✓"; printf ' %s\n' "$desc"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    _red "  ✗"; printf ' %s\n' "$desc"
    TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - BLOCK expected: ${desc}"
  fi
}

assert_allowed() {
  local hook="$1" payload="$2" desc="$3"
  if hook_with_input "$hook" 0 "$payload"; then
    TEST_PASS=$((TEST_PASS + 1))
    _green "  ✓"; printf ' %s\n' "$desc"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    _red "  ✗"; printf ' %s\n' "$desc"
    TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - ALLOW expected: ${desc}"
  fi
}

summary() {
  printf '\n'
  _dim "──────────────────────────────────────"; printf '\n'
  printf '%s — passed: %d  failed: %d\n' "$TEST_NAME" "$TEST_PASS" "$TEST_FAIL"
  if [[ "$TEST_FAIL" -gt 0 ]]; then
    printf 'Failures:%b\n' "$TEST_FAIL_DETAILS"
    exit 1
  fi
  exit 0
}
