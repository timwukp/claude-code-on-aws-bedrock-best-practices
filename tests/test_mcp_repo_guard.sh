#!/usr/bin/env bash
# =============================================================================
# mcp-repo-guard.sh — MCP write-path policy tests
# =============================================================================
# MCP payloads look nothing like Bash payloads: there is no `command` string to
# regex, the target is structured (owner/repo/branch/files[]), and the server
# segment of tool_name differs per machine. Every case below is built from a
# real MCP GitHub payload shape.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$ROOT/tests/lib/harness.sh"
TEST_NAME="mcp-repo-guard"
HOOK="$ROOT/hooks/mcp-repo-guard.sh"
chmod +x "$HOOK" 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "mcp-repo-guard tests need jq to build payloads" >&2
  exit 1
fi

# payload <tool_name> <tool_input-json>
payload() {
  jq -nc --arg t "$1" --argjson i "$2" \
    '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i,cwd:"/tmp",session_id:"t"}'
}
blocked() { assert_blocked "$HOOK" "$(payload "$1" "$2")" "$3"; }
allowed() { assert_allowed "$HOOK" "$(payload "$1" "$2")" "$3"; }

REPO='{"owner":"acme","repo":"widgets"'

echo "== blocked: content writes =="
blocked mcp__github__push_files \
  "$REPO,\"files\":[{\"path\":\"a.md\",\"content\":\"x\"}],\"message\":\"m\"}" \
  "push_files with no branch (commits to the default branch)"
blocked mcp__github__push_files \
  "$REPO,\"branch\":\"main\",\"files\":[{\"path\":\"a.md\",\"content\":\"x\"}]}" \
  "push_files to main"
blocked mcp__github__create_or_update_file \
  "$REPO,\"branch\":\"master\",\"path\":\"a.md\",\"content\":\"x\"}" \
  "create_or_update_file to master"
blocked mcp__github__create_or_update_file \
  "$REPO,\"branch\":\"refs/heads/main\",\"path\":\"a.md\"}" \
  "refs/heads/main is the same branch as main"
blocked mcp__github__create_or_update_file \
  "$REPO,\"branch\":\"release/2026\",\"path\":\"a.md\"}" \
  "release/* glob"
blocked mcp__github__delete_file "$REPO,\"branch\":\"main\",\"path\":\"a.md\"}" \
  "delete_file on main"
blocked mcp__github__delete_file "$REPO,\"path\":\"a.md\"}" \
  "delete_file with no branch"

echo "== blocked: merging and lifecycle =="
blocked mcp__github__merge_pull_request "$REPO,\"pullNumber\":7}" "merge_pull_request"
blocked mcp__github__create_repository '{"name":"exfil","private":false}' \
  "create_repository (a new place for data to land)"
blocked mcp__github__fork_repository "$REPO}" "fork_repository"
blocked mcp__github__delete_repository "$REPO}" "delete_repository"
blocked mcp__github__delete_branch "$REPO,\"branch\":\"main\"}" "delete protected branch"
blocked mcp__github__update_ref "$REPO,\"ref\":\"refs/heads/main\",\"sha\":\"dead\"}" \
  "rewrite protected ref"
blocked mcp__github__delete_release "$REPO,\"tag\":\"v1\"}" "delete_release"
blocked mcp__github__create_or_update_secret "$REPO,\"secret_name\":\"AWS_KEY\"}" \
  "secret write"

echo "== blocked: server-name independence =="
# The server segment is whatever the operator named it. Policy matches the tool
# suffix, so all of these are the same call.
blocked mcp__MCP_DOCKER__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "mcp__MCP_DOCKER__ server prefix"
blocked mcp__gh-enterprise__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "mcp__gh-enterprise__ server prefix"
blocked mcp__github_v2__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "mcp__github_v2__ server prefix"

echo "== allowed: the sanctioned pull-request workflow =="
allowed mcp__github__create_branch "$REPO,\"branch\":\"feature/x\",\"from_branch\":\"main\"}" \
  "step 1 — create_branch"
allowed mcp__github__create_or_update_file \
  "$REPO,\"branch\":\"feature/x\",\"path\":\"a.md\",\"content\":\"x\"}" \
  "step 2 — write on the feature branch"
allowed mcp__github__push_files \
  "$REPO,\"branch\":\"feature/x\",\"files\":[{\"path\":\"a.md\",\"content\":\"x\"}]}" \
  "step 2 — push_files on the feature branch"
allowed mcp__github__create_pull_request \
  "$REPO,\"base\":\"main\",\"head\":\"feature/x\",\"title\":\"t\"}" \
  "step 3 — create_pull_request"

echo "== allowed: reads and non-repo tools =="
allowed mcp__github__get_file_contents "$REPO,\"path\":\"a.md\"}" "get_file_contents"
allowed mcp__github__list_commits "$REPO}" "list_commits"
allowed mcp__github__search_code '{"query":"push_files"}' "search_code"
allowed mcp__github__pull_request_read "$REPO,\"pullNumber\":7}" "pull_request_read"
allowed mcp__github__add_issue_comment "$REPO,\"issue_number\":1,\"body\":\"b\"}" \
  "add_issue_comment"
allowed mcp__filesystem__delete_file '{"path":"/tmp/scratch.txt"}' \
  "a filesystem server's delete_file is not a repo write"
allowed mcp__aws-docs__read_documentation '{"url":"https://docs.aws.amazon.com/x"}' \
  "an unrelated MCP server"
allowed Bash '{"command":"gh pr merge 1"}' "a Bash call is not this hook's business"
allowed Write '{"file_path":"/tmp/a","content":"x"}' "a built-in tool is not an MCP call"

echo "== configuration =="
MCP_GUARD_PROTECTED_BRANCHES="develop" \
  blocked mcp__github__push_files "$REPO,\"branch\":\"develop\",\"files\":[]}" \
  "custom protected list blocks develop"
MCP_GUARD_ALLOWED_OWNERS="acme,acme-labs" \
  allowed mcp__github__create_or_update_file \
  "$REPO,\"branch\":\"feature/x\",\"path\":\"a.md\"}" \
  "write to an allowlisted owner"
MCP_GUARD_ALLOWED_OWNERS="acme,acme-labs" \
  blocked mcp__github__create_or_update_file \
  '{"owner":"attacker","repo":"drop","branch":"feature/x","path":"a.md"}' \
  "write to an owner outside the allowlist"
MCP_GUARD_EXTRA_BLOCKED_TOOLS="get_file_contents" \
  blocked mcp__github__get_file_contents "$REPO,\"path\":\"a.md\"}" \
  "operator-supplied extra blocklist"
MCP_GUARD_ALLOW_PR_MERGE=true \
  allowed mcp__github__merge_pull_request "$REPO,\"pullNumber\":7}" "ALLOW_PR_MERGE opt-in"
MCP_GUARD_ALLOW_DEFAULT_BRANCH_WRITE=true \
  allowed mcp__github__push_files "$REPO,\"files\":[]}" \
  "ALLOW_DEFAULT_BRANCH_WRITE opt-in"
MCP_GUARD_CI_MODE=true \
  allowed mcp__github__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "CI_MODE relaxes branch protection"
MCP_GUARD_DISABLED=true \
  allowed mcp__github__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "MCP_GUARD_DISABLED bypass (documented escape hatch)"

echo "== hook contract =="
p=$(payload mcp__github__push_files "$REPO,\"branch\":\"main\",\"files\":[]}")
out=$(printf '%s' "$p" | "$HOOK" 2>/dev/null || true)
err=$(printf '%s' "$p" | "$HOOK" 2>&1 >/dev/null || true)
if [[ -z "$out" ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "nothing written to stdout on block"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stdout on block was: $out"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stdout must be empty on block"
fi
if [[ "$err" == *"MCP REPO GUARD"* && "$err" == *"acme/widgets"* ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "stderr names the hook and the target"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stderr missing hook name/target"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stderr must name hook + target"
fi

# Registration cannot be proven by this file: piping a payload into the hook
# tests the logic, not whether Claude Code ever calls it. The liveness file is
# how an operator checks the difference in a real session.
LIVE=$(mktemp -u)
MCP_GUARD_LIVENESS_FILE="$LIVE" MCP_GUARD_DISABLED=true \
  allowed mcp__github__push_files "$REPO,\"branch\":\"main\",\"files\":[]}" \
  "disabled hook still runs (so it can still record liveness)"
if [[ -s "$LIVE" ]] && grep -q 'push_files' "$LIVE"; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "liveness file records the invocation even when disabled"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "liveness file not written"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - MCP_GUARD_LIVENESS_FILE not written"
fi
rm -f "$LIVE"

summary
