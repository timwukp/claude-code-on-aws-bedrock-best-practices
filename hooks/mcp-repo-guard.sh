#!/bin/bash
# =============================================================================
# MCP Repo Guard — repo-write policy for MCP tool calls
# =============================================================================
# Hook version: 1.0.0
# Last updated: 2026-08-13
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 3.2+, jq (preferred)
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-08-13) — initial release: closes the MCP write path documented
#                        as Issue 13 in docs/known-issues.md
# =============================================================================
# An MCP GitHub server writes to a repository over HTTPS from inside the MCP
# process. No shell runs, so a PreToolUse hook registered with matcher "Bash"
# never sees it: `mcp__github__push_files` commits straight to the default
# branch while git-guard.sh and gh-guard.sh report a clean session. This hook is
# the same policy applied to the third write surface.
#
# Hook event: PreToolUse (matcher: "mcp__.*")
# It also self-filters on tool_name, so registering it under matcher "*" is
# safe: anything that is not an mcp__ tool exits 0 immediately.
#
# Policy — identical to gh-guard.sh, expressed in MCP terms:
#   create_branch → create_or_update_file/push_files with an explicit branch →
#   create_pull_request → a human merges.
#
# Enforced:
#   1. Content writes (push_files, create_or_update_file, delete_file, ...) with
#      no branch field — the MCP server commits to the default branch — or with
#      a branch matching a protected pattern
#   2. merge_pull_request
#   3. Repository lifecycle: create/delete/fork/transfer
#   4. Branch/ref/tag/release deletion on protected refs
#   5. Secret writes
#   6. Writes to owners outside MCP_GUARD_ALLOWED_OWNERS, when set
#
# Server names differ per machine (mcp__github__, mcp__MCP_DOCKER__,
# mcp__gh-enterprise__ ...), so policy matches the tool suffix after the last
# "__", never the full tool name.
#
# False positives: a filesystem MCP server also has a `delete_file`. A call is
# only treated as a repository write when it carries owner+repo fields or comes
# from a server whose name matches MCP_GUARD_REPO_SERVER_PATTERN.
#
# Configuration via environment variables (settings.json env block):
#   MCP_GUARD_PROTECTED_BRANCHES        — comma list, globs allowed
#                                         (default "main,master,release/*,production")
#   MCP_GUARD_ALLOWED_OWNERS            — comma list of org/user names the agent
#                                         may write to (default "" = any)
#   MCP_GUARD_ALLOW_DEFAULT_BRANCH_WRITE— "true" allows writes with no branch
#   MCP_GUARD_ALLOW_PR_MERGE            — "true" allows merge_pull_request
#   MCP_GUARD_ALLOW_SECRET_WRITES       — "true" allows secret writes
#   MCP_GUARD_ALLOW_REPO_LIFECYCLE      — "true" allows create/fork repository
#   MCP_GUARD_EXTRA_BLOCKED_TOOLS       — comma list of extra tool suffixes
#   MCP_GUARD_REPO_SERVER_PATTERN       — ERE for repo-ish server names
#                                         (default "github|gitlab|git|forge")
#   MCP_GUARD_LIVENESS_FILE             — path to touch on every invocation, so
#                                         operators can prove the hook is
#                                         actually registered (default "" = off)
#   MCP_GUARD_CI_MODE                   — "true" relaxes branch protection
#   MCP_GUARD_DISABLED                  — "true" bypasses all checks (emergency)
#
# Exit codes:
#   0 = allow
#   2 = block (stderr is what Claude sees — stdout is discarded on exit 2)
# =============================================================================

set -u
LC_ALL=C

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
else
  HAVE_JQ=0
  tool_name=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

# Not an MCP call — nothing here applies.
case "$tool_name" in
  mcp__*) ;;
  *) exit 0 ;;
esac

# --- Configuration -----------------------------------------------------------
PROTECTED_BRANCHES="${MCP_GUARD_PROTECTED_BRANCHES:-main,master,release/*,production}"
ALLOWED_OWNERS="${MCP_GUARD_ALLOWED_OWNERS:-}"
ALLOW_DEFAULT_WRITE="${MCP_GUARD_ALLOW_DEFAULT_BRANCH_WRITE:-false}"
ALLOW_PR_MERGE="${MCP_GUARD_ALLOW_PR_MERGE:-false}"
ALLOW_SECRET_WRITES="${MCP_GUARD_ALLOW_SECRET_WRITES:-false}"
ALLOW_LIFECYCLE="${MCP_GUARD_ALLOW_REPO_LIFECYCLE:-false}"
EXTRA_BLOCKED="${MCP_GUARD_EXTRA_BLOCKED_TOOLS:-}"
REPO_SERVER_PATTERN="${MCP_GUARD_REPO_SERVER_PATTERN:-github|gitlab|git|forge}"
LIVENESS_FILE="${MCP_GUARD_LIVENESS_FILE:-}"
CI_MODE="${MCP_GUARD_CI_MODE:-false}"
DISABLED="${MCP_GUARD_DISABLED:-false}"

# Liveness first: a hook that never records an invocation cannot be
# distinguished from a hook that was never registered. Written before the
# DISABLED check on purpose — "disabled" is still a live hook.
if [[ -n "$LIVENESS_FILE" ]]; then
  mkdir -p "$(dirname "$LIVENESS_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$tool_name" \
    >> "$LIVENESS_FILE" 2>/dev/null || true
fi

[[ "$DISABLED" == "true" ]] && exit 0

# --- tool_name → server + tool suffix ----------------------------------------
rest="${tool_name#mcp__}"
tool_suffix="${rest##*__}"
server="${rest%__*}"
[[ "$server" == "$rest" ]] && server=''
tool_lc=$(printf '%s' "$tool_suffix" | tr '[:upper:]' '[:lower:]')

# --- Field extraction --------------------------------------------------------
field() {
  local name="$1"
  if [[ $HAVE_JQ -eq 1 ]]; then
    printf '%s' "$input" | jq -r --arg n "$name" '.tool_input[$n] // empty' 2>/dev/null
  else
    printf '%s' "$input" \
      | grep -oE "\"$name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed -E 's/.*"([^"]*)"$/\1/'
  fi
}

owner=$(field owner)
repo=$(field repo)
branch=$(field branch)
[[ -z "$branch" ]] && branch=$(field ref)

# Repo-ish? Either the payload names a repository or the server is a forge.
is_repo_call=0
[[ -n "$owner" && -n "$repo" ]] && is_repo_call=1
if [[ $is_repo_call -eq 0 && -n "$server" ]]; then
  if printf '%s' "$server" | grep -qiE "$REPO_SERVER_PATTERN"; then is_repo_call=1; fi
fi
[[ $is_repo_call -eq 0 ]] && exit 0

GUIDE='Sanctioned write path (each step is allowed by this hook):
  1. create_branch          — branch off the default branch
  2. create_or_update_file  — with branch: "<feature>" on every call
     (or push_files with branch set)
  3. create_pull_request    — base: default branch, head: <feature>
  4. Ask a human to review and merge.'

deny() {
  printf 'MCP REPO GUARD: %s\n\nTool: %s\nTarget: %s\n\n%s\n\nHook: mcp-repo-guard.sh\n' \
    "$1" "$tool_name" "${owner:-?}/${repo:-?}${branch:+ @ $branch}" "$GUIDE" >&2
  exit 2
}

list_match() {
  local needle="$1" list="$2" pattern
  local oldifs="$IFS"
  IFS=','
  for pattern in $list; do
    IFS="$oldifs"
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -z "$pattern" ]] && { IFS=','; continue; }
    # shellcheck disable=SC2053  — glob match is intended
    if [[ "$needle" == $pattern ]]; then IFS="$oldifs"; return 0; fi
    IFS=','
  done
  IFS="$oldifs"
  return 1
}

branch_protected() {
  [[ "$CI_MODE" == "true" ]] && return 1
  list_match "$1" "$PROTECTED_BRANCHES"
}

branch="${branch#refs/heads/}"

# --- Owner allowlist ---------------------------------------------------------
if [[ -n "$ALLOWED_OWNERS" && -n "$owner" ]]; then
  case "$tool_lc" in
    *create*|*update*|*push*|*delete*|*merge*|*fork*|*set*|*add*|*write*)
      if ! list_match "$owner" "$ALLOWED_OWNERS"; then
        deny "Writes to owner '$owner' are not allowed. Allowed owners: $ALLOWED_OWNERS"
      fi ;;
  esac
fi

# --- Operator-supplied extra blocklist ---------------------------------------
if [[ -n "$EXTRA_BLOCKED" ]] && list_match "$tool_lc" "$EXTRA_BLOCKED"; then
  deny "Tool '$tool_suffix' is in MCP_GUARD_EXTRA_BLOCKED_TOOLS."
fi

# =============================================================================
# Policy by tool suffix
# =============================================================================
case "$tool_lc" in

  # --- Content writes: must name a non-protected branch ----------------------
  push_files|create_or_update_file|update_file|create_file|delete_file|upload_file|create_commit|commit_files)
    if [[ -z "$branch" ]]; then
      [[ "$ALLOW_DEFAULT_WRITE" == "true" ]] && exit 0
      deny "'$tool_suffix' with no 'branch' argument commits to the repository default branch. Set branch to a feature branch and open a pull request."
    fi
    if branch_protected "$branch"; then
      deny "'$tool_suffix' targets protected branch '$branch'. Protected: $PROTECTED_BRANCHES"
    fi
    exit 0 ;;

  # --- Merging is a human decision ------------------------------------------
  merge_pull_request|merge_branch|merge)
    [[ "$ALLOW_PR_MERGE" == "true" ]] && exit 0
    deny "'$tool_suffix' merges code. The agent opens the pull request; a reviewer merges it." ;;

  # --- Ref/branch/tag/release deletion --------------------------------------
  delete_branch|delete_ref|delete_tag)
    if [[ -n "$branch" ]] && branch_protected "$branch"; then
      deny "'$tool_suffix' would delete protected ref '$branch'. Protected: $PROTECTED_BRANCHES"
    fi
    exit 0 ;;
  update_ref|update_branch)
    if [[ -n "$branch" ]] && branch_protected "$branch"; then
      deny "'$tool_suffix' would rewrite protected ref '$branch'. Protected: $PROTECTED_BRANCHES"
    fi
    exit 0 ;;
  delete_release|delete_repository|transfer_repository)
    deny "'$tool_suffix' is destructive and is never an agent action." ;;

  # --- Repository lifecycle -------------------------------------------------
  create_repository|fork_repository)
    [[ "$ALLOW_LIFECYCLE" == "true" ]] && exit 0
    deny "'$tool_suffix' creates a new remote repository — a new place for data to land outside review. Requires a human." ;;

  # --- Secrets --------------------------------------------------------------
  create_or_update_secret|set_secret|create_secret|update_secret|set_variable)
    [[ "$ALLOW_SECRET_WRITES" == "true" ]] && exit 0
    deny "'$tool_suffix' writes a credential to a remote. Set secrets from a human session or CI." ;;

  # --- Explicitly sanctioned ------------------------------------------------
  create_branch|create_pull_request|create_issue|add_issue_comment|create_pending_review)
    exit 0 ;;

  # --- Everything else: reads, comments, searches ---------------------------
  *)
    exit 0 ;;
esac
