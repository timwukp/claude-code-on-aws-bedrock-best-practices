#!/bin/bash
# Enterprise Claude Code wrapper — blocks bypass flags before invoking real binary.
#
# Deploy:
#   /usr/local/bin/claude               (root:root 0755)  — this script
#   /opt/claude-code/bin/claude         (root:claude-users 0750) — real binary
#   /etc/sudoers.d/claude-code          — see scripts/sudoers-claude-code below
#
# Hardening (P0-3):
#   - Real binary 0750 root:claude-users so non-members cannot exec it directly
#   - Sudoers NOPASSWD rule lets /usr/local/bin/claude exec via sudo without
#     leaking root to the user shell. Only this wrapper can run it.
#
# [TESTED ✅ 2026-05-29] All 32 documented bypasses blocked (tests/bypass-attempts.sh).

set -euo pipefail
next=0
for arg in "$@"; do
  # --permission-mode=VALUE form
  if [[ "$arg" =~ ^--permission-mode=(bypassPermissions|auto)$ ]]; then
    echo "Refused: \"$arg\" is disabled by enterprise policy." >&2
    exit 1
  fi
  case "$arg" in
    --dangerously-skip-permissions|--allow-dangerously-skip-permissions|--bare)
      echo "Refused: \"$arg\" is disabled by enterprise policy." >&2
      exit 1
      ;;
    --permission-mode)
      next=1 ;;
    *)
      if [[ "$next" == "1" ]] && [[ "$arg" =~ ^(bypassPermissions|auto)$ ]]; then
        echo "Refused: \"--permission-mode $arg\" is disabled by enterprise policy." >&2
        exit 1
      fi
      next=0 ;;
  esac
done

# Also block `claude mcp add` subcommand
if [[ "${1:-}" == "mcp" && "${2:-}" == "add" ]]; then
  echo "Refused: 'claude mcp add' is disabled by enterprise policy. Contact IT to approve MCP servers." >&2
  exit 1
fi

exec /opt/claude-code/bin/claude "$@"
