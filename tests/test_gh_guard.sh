#!/usr/bin/env bash
# =============================================================================
# gh-guard.sh — policy, parser-bypass and false-positive tests
# =============================================================================
# The bypass cases are the point of this file. A guard that blocks
# `gh pr merge 1` and nothing else is trivial to write and trivial to walk
# around: quote the flag, hide it after &&, wrap it in bash -c, spell the
# endpoint as a full URL. Each of those is a case below.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$ROOT/tests/lib/harness.sh"
TEST_NAME="gh-guard"
HOOK="$ROOT/hooks/gh-guard.sh"
chmod +x "$HOOK" 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "gh-guard tests need jq to build payloads" >&2
  exit 1
fi

payload() {
  jq -nc --arg c "$1" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}'
}
blocked() { assert_blocked "$HOOK" "$(payload "$1")" "$2"; }
allowed() { assert_allowed "$HOOK" "$(payload "$1")" "$2"; }

echo "== blocked: merging =="
blocked 'gh pr merge 42 --squash --delete-branch' "gh pr merge"
blocked 'gh api --method POST repos/o/r/pulls/7/merge' "POST pulls/N/merge"
blocked 'gh api -X POST repos/o/r/merges -f base=main -f head=feature' "API merge into protected base"

echo "== blocked: contents API =="
blocked 'gh api --method PUT repos/o/r/contents/f.md -f message=x -f content=YWJj' \
  "contents PUT with no branch field (lands on default branch)"
blocked 'gh api --method PUT repos/o/r/contents/f.md -f branch=main -f content=YWJj' \
  "contents PUT to main"
blocked 'gh api -X PUT repos/o/r/contents/f.md -f branch=refs/heads/master -f content=YWJj' \
  "contents PUT to refs/heads/master (normalised)"
blocked 'gh api -X PUT repos/o/r/contents/f.md -f branch=release/2026 -f content=YWJj' \
  "contents PUT to release/* glob"
blocked 'gh api -X PUT repos/o/r/contents/f.md --field branch=main -f content=YWJj' \
  "--field long form"
blocked 'gh api -X PUT repos/o/r/contents/f.md -fbranch=main -f content=YWJj' \
  "-fbranch=main joined form"
blocked 'gh api -X PUT https://api.github.com/repos/o/r/contents/f.md -f content=YWJj' \
  "endpoint written as a full api.github.com URL"
blocked 'gh api -X DELETE repos/o/r/contents/f.md -f branch=main -f sha=abc' \
  "contents DELETE on main"

echo "== blocked: refs and repo lifecycle =="
blocked 'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=deadbeef -F force=true' \
  "force-update main via git/refs PATCH"
blocked 'gh api -X DELETE repos/o/r/git/refs/heads/main' "delete main via git/refs DELETE"
blocked 'gh repo delete o/r --yes' "gh repo delete"
blocked 'gh repo sync o/r' "gh repo sync (writes default branch)"
blocked 'gh api -X DELETE repos/o/r' "DELETE repos/O/R (repository deletion)"
blocked 'gh release delete v1.0 --yes' "gh release delete"

echo "== blocked: credentials, access, policy evasion =="
blocked 'gh secret set AWS_SECRET --body hunter2' "gh secret set"
blocked 'gh variable set REGION --body us-east-1' "gh variable set"
blocked 'gh api -X PUT repos/o/r/actions/secrets/AWS_KEY -f encrypted_value=zz' "Actions secret write"
blocked 'gh api -X DELETE repos/o/r/branches/main/protection' "branch-protection tampering"
blocked 'gh api -X PUT repos/o/r/collaborators/eve -f permission=admin' "collaborator grant"
blocked 'gh alias set prm "pr merge"' "gh alias set (renames a blocked verb)"
blocked 'gh api -X PUT repos/o/r/contents/f.md --hostname evil.example.com -f branch=x -f content=YWJj' \
  "--hostname outside the allowlist"

echo "== blocked: parser bypasses =="
blocked 'gh api -X PUT repos/o/r/contents/f.md -f message="fix: set branch=feature in config" -f content=YWJj' \
  "branch= inside a quoted message is not a branch field"
blocked 'echo starting && gh pr merge 1' "blocked verb hidden after &&"
blocked 'echo a; echo b; gh pr merge 1' "blocked verb in the third segment"
blocked 'OUT=$(gh pr merge 1)' "blocked verb inside command substitution"
blocked 'bash -c "gh pr merge 1"' "blocked verb inside bash -c"
blocked 'sh -c "gh api -X PUT repos/o/r/contents/f -f branch=main -f content=YWJj"' \
  "contents write to main inside sh -c"
blocked 'GH_TOKEN=x gh pr merge 1' "env-assignment prefix"
blocked 'env GH_TOKEN=x gh pr merge 1' "env(1) prefix"
blocked '/usr/bin/gh pr merge 1' "absolute path to gh"
blocked 'git commit -m "Bob\"s fix" ; gh pr merge 1' \
  "escaped quote does not swallow the following segment"
blocked 'gh api -X PUT repos/o/r/contents/f.md --input /nonexistent-body.json' \
  "unreadable --input body cannot be checked, so it is denied"

echo "== blocked: curl/wget straight to the API (no gh involved) =="
blocked 'curl -X PUT https://api.github.com/repos/o/r/contents/f -d "{\"message\":\"m\",\"content\":\"YWJj\"}"' \
  "curl contents PUT with no branch in the body"
blocked 'curl -X PUT https://api.github.com/repos/o/r/contents/f -d "{\"branch\":\"main\",\"content\":\"YWJj\"}"' \
  "curl contents PUT to main"
blocked 'curl -X PUT https://git.acme.com/api/v3/repos/o/r/contents/f -d "{\"branch\":\"main\"}"' \
  "curl to a GitHub Enterprise /api/v3/ host"
blocked 'curl -X PUT https://api.github.com/repos/o/r/contents/f -d @body.json' \
  "curl with a @file body that cannot be checked"
blocked 'curl -X POST https://api.github.com/repos/o/r/pulls/7/merge' "curl PR merge"
blocked 'curl -X DELETE https://api.github.com/repos/o/r/git/refs/heads/main' "curl deletes main"
blocked 'curl -X PUT https://api.github.com/repos/o/r/actions/secrets/AWS_KEY -d "{}"' \
  "curl writes an Actions secret"
blocked 'curl -sS -X DELETE https://api.github.com/repos/o/r' "curl deletes the repository"
blocked 'wget --method=PUT --body-data="{\"branch\":\"main\"}" https://api.github.com/repos/o/r/contents/f' \
  "wget --method=PUT to main"
# "github" contains no "gh" substring (g-i-t-h-u-b), so a prefilter written as
# *gh* silently skips every api.github.com URL. This case is the regression.
blocked "bash -c 'curl -X DELETE https://api.github.com/repos/o/r/git/refs/heads/main'" \
  "curl to api.github.com inside bash -c (command has no standalone gh token)"
allowed 'curl -X PUT https://api.github.com/repos/o/r/contents/f -d "{\"branch\":\"feature/x\",\"content\":\"YWJj\"}"' \
  "curl contents PUT on a feature branch"
allowed 'curl -X POST https://api.github.com/repos/o/r/git/refs -d "{\"ref\":\"refs/heads/feature/x\",\"sha\":\"abc\"}"' \
  "curl creates a feature branch"
allowed 'curl -X POST https://api.github.com/repos/o/r/issues -d "{\"title\":\"t\"}"' \
  "curl opens an issue"
allowed 'curl -sSL https://api.github.com/repos/o/r' "curl GET is a read"
allowed 'curl -sSL https://example.com/install.sh -o /tmp/i.sh' "curl to an unrelated host"
allowed 'curl -sS https://api.github.com/repos/o/r/contents/f | jq -r .content' \
  "curl GET piped to jq"

echo "== blocked: oversized command falls back to conservative matching =="
PAD=$(head -c 70000 /dev/zero | tr '\0' 'x')
blocked "echo $PAD && gh pr merge 1" "blocked verb in a 70KB command"
unset PAD

echo "== allowed: the sanctioned pull-request workflow =="
allowed 'gh api --method POST repos/o/r/git/refs -f ref=refs/heads/feature/x -f sha=abc123' \
  "step 1 — create a feature branch"
allowed 'gh api --method PUT repos/o/r/contents/f.md -f branch=feature/x -f message=m -f content=YWJj' \
  "step 2 — contents write on the feature branch"
allowed 'gh pr create --base main --head feature/x --title t --body b' \
  "step 3 — open the pull request"

echo "== allowed: reads and unrelated commands =="
allowed 'gh api repos/o/r --jq .default_branch' "GET repo metadata"
allowed 'gh api repos/o/r/contents/f.md' "GET file contents"
allowed 'gh api "repos/o/r/git/trees/main?recursive=1"' "GET tree with query string"
allowed 'gh pr list --state open' "gh pr list"
allowed 'gh pr view 42 --json title,body' "gh pr view"
allowed 'gh pr diff 42' "gh pr diff"
allowed 'gh run list --limit 5' "gh run list"
allowed 'gh auth status' "gh auth status"
allowed 'git status' "a git command (git-guard's business, not ours)"
allowed 'echo "gh pr merge is blocked by policy"' \
  "quoting the policy in an echo is not an attempt to run it"
allowed 'grep -rn "gh api" docs/' "searching docs for gh api"
allowed 'gh api -X POST repos/o/r/issues -f title=t -f body=b' "opening an issue"
allowed 'gh api -X POST repos/o/r/pulls/7/reviews -f body=b -f event=COMMENT' "leaving a review"

echo "== configuration =="
GH_GUARD_PROTECTED_BRANCHES="develop,trunk" \
  blocked 'gh api -X PUT repos/o/r/contents/f -f branch=develop -f content=YWJj' \
  "custom protected list blocks develop"
GH_GUARD_PROTECTED_BRANCHES="develop,trunk" \
  allowed 'gh api -X PUT repos/o/r/contents/f -f branch=main -f content=YWJj' \
  "custom protected list leaves main writable (operator's choice)"
GH_GUARD_CI_MODE=true \
  allowed 'gh api -X PUT repos/o/r/contents/f -f branch=main -f content=YWJj' \
  "CI_MODE relaxes branch protection"
GH_GUARD_ALLOW_PR_MERGE=true allowed 'gh pr merge 42' "ALLOW_PR_MERGE opt-in"
GH_GUARD_ALLOW_DEFAULT_BRANCH_WRITE=true \
  allowed 'gh api -X PUT repos/o/r/contents/f -f content=YWJj' \
  "ALLOW_DEFAULT_BRANCH_WRITE opt-in"
GH_GUARD_DISABLED=true allowed 'gh pr merge 42' "GH_GUARD_DISABLED bypass (documented escape hatch)"

echo "== hook contract =="
# On exit 2 Claude Code discards stdout, so a block reason printed there is
# invisible to the agent and it retries the same command. This asserts the
# reason is on stderr and that nothing lands on stdout.
p=$(payload 'gh pr merge 1')
out=$(printf '%s' "$p" | "$HOOK" 2>/dev/null || true)
err=$(printf '%s' "$p" | "$HOOK" 2>&1 >/dev/null || true)
if [[ -z "$out" ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "nothing written to stdout on block"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stdout on block was: $out"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stdout must be empty on block"
fi
if [[ "$err" == *"GH GUARD"* && "$err" == *"Sanctioned write path"* ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "stderr carries the reason and the sanctioned alternative"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stderr missing reason/guidance"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stderr must carry reason + guidance"
fi

# A hook that is slow enough to trip the wrapper timeout is a hook that gets
# disabled. Budget: the whole suite's worst case is a 70KB command.
start=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '%s' "$(payload 'gh api -X PUT repos/o/r/contents/f.md -f branch=feature/x -f content=YWJj')" \
  | "$HOOK" >/dev/null 2>&1 || true
end=$(python3 -c 'import time;print(int(time.time()*1000))')
dur=$((end - start))
if [[ "$dur" -lt 1000 ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s (%sms)\n' "single call under 1000ms" "$dur"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s (%sms)\n' "single call too slow" "$dur"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - latency ${dur}ms"
fi

summary
