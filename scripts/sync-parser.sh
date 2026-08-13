#!/usr/bin/env bash
# =============================================================================
# sync-parser.sh — copy the shared parser into every hook that carries it
# =============================================================================
# `hooks/lib/shell-parse.sh` is the single source of truth for the shell-command
# parsing front end; the hooks are standalone files that must not depend on it at
# runtime (hooks/lib/shell-parse.sh explains why a runtime `source` has no safe
# failure branch). This script is the edit-time link between the two: it replaces
# the region between the sentinel lines
#
#   # >>> SHARED PARSER ... >>>
#   # <<< SHARED PARSER ... <<<
#
# in each hook, then refreshes the plugin's copies of the hooks.
#
# Usage:
#   bash scripts/sync-parser.sh            # rewrite in place
#   bash scripts/sync-parser.sh --check    # exit 1 if anything is out of date
#
# `--check` is what tests/test_shared_parser.sh runs, so a hand edit inside a
# generated region fails the suite instead of quietly diverging.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/hooks/lib/shell-parse.sh"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# Hooks that carry the shared region.
TARGETS="hooks/git-guard.sh hooks/gh-guard.sh"
# Hooks the plugin ships a copy of. They are meant to be byte identical.
PLUGIN_COPIES="git-guard.sh gh-guard.sh mcp-repo-guard.sh"

BEGIN_RE='^# >>> SHARED PARSER'
END_RE='^# <<< SHARED PARSER'

if [[ ! -f "$LIB" ]]; then
  echo "sync-parser: missing $LIB" >&2
  exit 1
fi

TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT
REGION="$TMPDIR_/region"

# The region body, without the sentinel lines themselves.
awk -v b="$BEGIN_RE" -v e="$END_RE" '
  $0 ~ b { inside=1; next }
  $0 ~ e { inside=0; next }
  inside { print }
' "$LIB" > "$REGION"

if [[ ! -s "$REGION" ]]; then
  echo "sync-parser: no sentinel region found in $LIB" >&2
  exit 1
fi

stale=0
changed=0

for rel in $TARGETS; do
  f="$ROOT/$rel"
  if [[ ! -f "$f" ]]; then
    echo "sync-parser: missing $rel" >&2
    exit 1
  fi
  if ! grep -q "$BEGIN_RE" "$f" || ! grep -q "$END_RE" "$f"; then
    echo "sync-parser: $rel has no shared-parser sentinels" >&2
    exit 1
  fi
  new="$TMPDIR_/$(basename "$f").new"
  awk -v b="$BEGIN_RE" -v e="$END_RE" -v repl="$REGION" '
    $0 ~ b { print; while ((getline line < repl) > 0) print line; close(repl); skip=1; next }
    $0 ~ e { skip=0; print; next }
    !skip  { print }
  ' "$f" > "$new"
  if cmp -s "$f" "$new"; then
    continue
  fi
  if [[ $CHECK -eq 1 ]]; then
    echo "STALE: $rel differs from hooks/lib/shell-parse.sh" >&2
    stale=1
  else
    cat "$new" > "$f"   # preserves the existing mode
    chmod +x "$f"       # ...and a hook that is not executable exits 126
    echo "updated: $rel"
    changed=1
  fi
done

for name in $PLUGIN_COPIES; do
  src="$ROOT/hooks/$name"
  dst="$ROOT/plugin/hooks/$name"
  [[ -f "$src" ]] || { echo "sync-parser: missing hooks/$name" >&2; exit 1; }
  [[ -f "$dst" ]] || { echo "sync-parser: missing plugin/hooks/$name" >&2; exit 1; }
  if cmp -s "$src" "$dst" && [[ ! -x "$src" || -x "$dst" ]]; then
    continue
  fi
  if [[ $CHECK -eq 1 ]]; then
    if ! cmp -s "$src" "$dst"; then
      echo "STALE: plugin/hooks/$name differs from hooks/$name" >&2
    else
      echo "STALE: plugin/hooks/$name is not executable (hooks/$name is)" >&2
    fi
    stale=1
  else
    cat "$src" > "$dst"
    [[ -x "$src" ]] && chmod +x "$dst"
    echo "updated: plugin/hooks/$name"
    changed=1
  fi
done

if [[ $CHECK -eq 1 ]]; then
  if [[ $stale -eq 1 ]]; then
    echo "sync-parser --check: out of date. Run: bash scripts/sync-parser.sh" >&2
    exit 1
  fi
  echo "sync-parser --check: all copies current"
  exit 0
fi

[[ $changed -eq 0 ]] && echo "sync-parser: already current"
exit 0
