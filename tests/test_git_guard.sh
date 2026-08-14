#!/usr/bin/env bash
# =============================================================================
# git-guard.sh — policy, parser-bypass and false-positive tests
# =============================================================================
# This hook shipped without a suite of its own, and two bugs lived in it for
# that reason. Both came from matching a multi-line command as though it were
# one line:
#
#   * `echo "$norm" | awk '{print $1}'` reads a field per LINE, so on a
#     two-line command the branch name became "/repo\nmain" and matched no
#     protected pattern. `cd repo && git push origin main` was blocked while
#     the same two commands separated by a newline sailed through.
#   * every check inspected heredoc body lines as if they were commands, so
#     documentation quoting `git reset --hard` as an example was denied.
#
# The pairs below are the point of this file: the same operation written on one
# line and across two must reach the same verdict, and prose about a command
# must never be confused with the command.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$ROOT/tests/lib/harness.sh"
TEST_NAME="git-guard"
HOOK="$ROOT/hooks/git-guard.sh"
chmod +x "$HOOK" 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "git-guard tests need jq to build payloads" >&2
  exit 1
fi

# cwd is a non-repo on purpose: get_remote_url() then resolves nothing, so the
# allowlist check cannot mask a branch-protection result.
payload() {
  jq -nc --arg c "$1" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}'
}
blocked() { assert_blocked "$HOOK" "$(payload "$1")" "$2"; }
allowed() { assert_allowed "$HOOK" "$(payload "$1")" "$2"; }

# Same, with a cwd the hook can resolve a repository in. Needed for the pushes
# whose target is not written on the command line: `git push` publishes whatever
# branch HEAD is on, which is repository state, not command text.
payload_at() {
  jq -nc --arg c "$1" --arg d "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}
blocked_at() { assert_blocked "$HOOK" "$(payload_at "$1" "$2")" "$3"; }
allowed_at() { assert_allowed "$HOOK" "$(payload_at "$1" "$2")" "$3"; }

# Both spellings of the same command must agree. A guard that depends on how
# the agent happened to format its command is not a guard.
both() {
  local a="$1" b="$2" want="$3" desc="$4"
  if [[ "$want" == 2 ]]; then
    blocked "$a" "$desc (one line)"
    blocked "$b" "$desc (across lines)"
  else
    allowed "$a" "$desc (one line)"
    allowed "$b" "$desc (across lines)"
  fi
}

echo "== blocked: push to a protected branch =="
blocked 'git push origin main' "push to main"
blocked 'git push origin master' "push to master"
blocked 'git push origin production' "push to production"
blocked 'git push origin release/v1.0' "push to release/* glob"
blocked 'git push upstream refs/heads/main' "push to a refs/heads/ spelling"
blocked 'git push origin HEAD:main' "refspec whose remote side is main"
blocked 'git push origin feature:master' "refspec pushing a feature onto master"
blocked 'cd /repo && git push origin main' "push after &&"
blocked 'cd /repo ; git push origin main' "push after ;"
blocked 'git status | tee log.txt ; git push origin main' "push in the third segment"

# The regression. Newlines are how an agent writes a multi-step command, so
# this is the common case, not an exotic one.
echo "== blocked: a newline is not a way out =="
both 'cd /repo && git push origin main' \
     "$(printf 'cd /repo\ngit push origin main')" 2 "push to main"
both 'set -e; cd /repo; git push origin master' \
     "$(printf 'set -e\ncd /repo\ngit push origin master')" 2 "push to master, three steps"
blocked "$(printf '# deploy the release\ngit push origin main')" \
  "push to main on the line after a comment"
both 'cd /repo && git push --force origin feature' \
     "$(printf 'cd /repo\ngit push --force origin feature')" 2 "force push"
both 'cd /repo && git reset --hard HEAD~1' \
     "$(printf 'cd /repo\ngit reset --hard HEAD~1')" 2 "reset --hard"
both 'cd /repo && git push origin feature/x' \
     "$(printf 'cd /repo\ngit push origin feature/x')" 0 "push to a feature branch"

echo "== blocked: force push =="
blocked 'git push --force origin feature' "--force"
blocked 'git push --force-with-lease origin feature' "--force-with-lease"
blocked 'git push -f origin feature' "-f before the remote"
blocked 'git push origin feature -f' "-f as the last word, with no trailing space"
allowed 'git push origin feature/x && rm -f /tmp/scratch' \
  "an -f belonging to another command in the same line is not a force push"

echo "== blocked: remotes =="
blocked 'git remote add origin https://evil.example.com/o/r.git' "remote add outside the allowlist"
blocked 'git remote set-url origin git@evil.example.com:o/r.git' "remote set-url outside the allowlist"
blocked 'git remote add origin ssh://git@evil.example.com/o/r.git' "ssh:// URL outside the allowlist"
blocked 'git remote rename origin upstream' "remote rename"
blocked 'git remote rm origin' "remote rm"
blocked 'git remote remove origin' "remote remove"

echo "== blocked: destructive operations =="
blocked 'git reset --hard HEAD~1' "reset --hard"
blocked 'git clean -fd' "clean -fd"
blocked 'git clean -f' "clean -f"
blocked 'git checkout --force main' "checkout --force"
blocked 'git switch --force main' "switch --force"

echo "== allowed: ordinary work =="
allowed 'git status' "status"
allowed 'git log --oneline -5' "log"
allowed 'git diff HEAD~1' "diff"
allowed 'git add -A && git commit -m "fix: parse heredoc bodies"' "add and commit"
allowed 'git push origin feature/x' "push to a feature branch"
allowed 'git push origin fix/git-guard-multiline' "push to a fix/ branch"
allowed 'git remote add origin https://github.com/o/r.git' "remote add on an allowed domain"
allowed 'git remote add origin git@github.com:o/r.git' "scp-style URL on an allowed domain"
allowed 'git remote -v' "remote -v is a read"
allowed 'git reset --soft HEAD~1' "reset --soft"
allowed 'git clean -n' "clean -n previews"
allowed 'git checkout main' "checkout without --force"
allowed 'echo hello' "a command with no git in it"
allowed 'grep -rn "git push" docs/' "searching docs for the phrase"
allowed 'echo "never git push origin main"' "quoting the policy is not running it"

# A heredoc body is data. Every check here matches line by line, so before
# v1.1.0 writing docs about the policy was denied as an attempt to execute it.
# This repo is mostly docs, so the guard was densest where it was least wanted.
echo "== allowed: heredoc bodies are data, not commands =="
allowed "$(printf 'cat > /tmp/policy.md <<%sEOF%s\nDirect git push origin main is blocked; open a PR.\nEOF' "'" "'")" \
  "heredoc prose naming a blocked push"
allowed "$(printf 'cat > /tmp/p.md <<EOF\ngit push origin main\nEOF')" \
  "heredoc whose body line starts with the blocked command"
allowed "$(printf 'cat > /tmp/p.md <<EOF\ncd /repo; git push origin main\nEOF')" \
  "heredoc body with a separator before the command"
allowed "$(printf 'cat > /tmp/p.md <<EOF\ngit reset --hard HEAD~1 destroys work\nEOF')" \
  "heredoc prose naming a destructive command"
allowed "$(printf 'cat <<-END > /tmp/p.md\n\tgit clean -fd is forbidden\n\tEND')" \
  "heredoc with <<- and a tab-indented terminator"
allowed "$(printf 'cat <<%sA%s > /tmp/a; cat <<%sB%s > /tmp/b\ngit push origin main\nA\ngit reset --hard\nB' "'" "'" "'" "'")" \
  "two heredocs of prose in one command"
allowed "$(printf 'gh pr create --title t --body-file - <<EOF\nThis PR stops git push origin main from working.\nEOF')" \
  "opening a PR whose body describes the blocked command"
allowed 'wc -c <<< "git push origin main"' "a herestring is not a heredoc"
allowed "$(printf 'logger.sh --tag deploy <<EOF\ngit push origin main\nEOF')" \
  "an arbitrary program consuming a heredoc does not execute it"
allowed "$(printf 'send.sh "pipeline: build | bash" <<EOF\ngit push origin main\nEOF')" \
  "a quoted \"| bash\" in the opener is not a pipe into a shell"

# Mistaking something for a heredoc is worse than missing one: the phantom body
# swallows every following line, so a blocked command after it is never seen.
echo "== blocked: heredoc lookalikes must not swallow the next command =="
blocked "$(printf 'echo $((1<<SHIFT))\ngit push origin main')" \
  "a left shift is not a heredoc opener (phantom body would hide the push)"
blocked "$(printf 'echo $((1<<4))\ngit reset --hard HEAD~1')" \
  "a numeric shift is not a heredoc opener"
blocked "$(printf 'echo "sample: cat <<EOF"\ngit push origin main')" \
  "<<EOF inside a quoted argument is not a heredoc opener"

# The exception: a body a shell consumes is a script. v1.0.0 caught these by
# accident, through the same bug that produced the false positives above, so
# dropping bodies without re-scanning these would have been a regression.
echo "== blocked: a heredoc fed to a shell is still a command list =="
blocked "$(printf 'bash <<%sEOF%s\ncd /repo\ngit push origin main\nEOF' "'" "'")" \
  "heredoc script fed to bash by redirection"
blocked "$(printf 'sh <<EOF\ngit reset --hard HEAD~1\nEOF')" \
  "heredoc script fed to sh"
blocked "$(printf 'cat <<%sEOF%s | bash\ngit push origin main\nEOF' "'" "'")" \
  "heredoc piped into bash"
blocked "$(printf 'cat <<%sEOF%s | sudo bash\ngit clean -fd\nEOF' "'" "'")" \
  "heredoc piped into sudo bash"

# v1.2.0. A `git` inside a quoted argument is not lexically a command, so the
# regexes that decided policy in v1.1.0 never saw it: `bash -c "git push origin
# main"` exited 0. This is the fail-open half of Issue 14; the false-positive
# half is the section after it, and both come from the same cause — deciding
# policy on command TEXT rather than on tokens.
echo "== blocked: a command wrapped in a shell is still a command =="
blocked 'bash -c "git push origin main"' "bash -c"
blocked "sh -c 'git reset --hard HEAD~1'" "sh -c with single quotes"
blocked 'eval "git push origin main"' "eval"
blocked '/bin/bash -c "git push --force origin feature"' "absolute path to the interpreter"
blocked 'bash -lc "cd /repo && git push origin main"' "bash -lc with a compound command inside"
blocked "bash -c 'bash -c \"git push origin main\"'" "two levels of wrapping"
blocked 'zsh -c "git push origin main"' "zsh -c"
blocked 'timeout 5 git push origin main' "a wrapper that carries its own arguments"
blocked 'nohup git push origin main' "nohup prefix"
blocked 'env GIT_TRACE=1 git push origin main' "env(1) prefix"
blocked 'GIT_TRACE=1 git push origin main' "env-assignment prefix"
blocked 'OUT=$(git push origin main)' "inside command substitution"
blocked 'echo $(git push origin main)' "inside command substitution as an argument"
blocked 'git -C /repo push origin main' "git -C moves the repository, not the policy"
blocked 'sudo git push origin main' "sudo prefix"

# The other half of the same cause. A quoted `;` is not a separator, so v1.1.0
# read `echo "x; git push origin main"` as two commands and denied the second —
# for a string that was only ever going to be printed. A guard that blocks
# talking about a command is a guard that gets switched off.
echo "== allowed: quoting a command is not running it =="
allowed 'echo "x; git push origin main"' "a quoted ';' is not a command separator"
allowed 'echo "deploy: git push origin main | tee log"' "quoted separators of every kind"
allowed "printf '%s\\n' 'git reset --hard HEAD~1'" "printf of a destructive command"
allowed 'git commit -m "revert the git push origin main change"' \
  "a commit message that names a blocked command"
allowed 'git log --grep="git push origin main"' "a log search for the phrase"
allowed 'jq -n "{note:\"git push origin main\"}"' "a JSON string containing the command"
allowed 'echo "run git clean -fd to wipe untracked files"' "prose about git clean"

# Every destination, not just the first argument after the remote. v1.1.0 read
# field 2 and stopped, so the second refspec of a two-refspec push was invisible.
echo "== blocked: every refspec is checked, not only the first =="
blocked 'git push origin feature/x main' "second refspec targets main"
blocked 'git push origin :main' "empty source refspec deletes main"
blocked 'git push origin --delete main' "--delete main"
blocked 'git push origin +feature:other' "leading + on a refspec is a force push"
blocked 'git push origin feature:release/2026' "refspec onto a release/* branch"
allowed 'git push origin feature/x:feature/y' "feature onto feature"
allowed 'git push origin refs/tags/v1.0' "a tag is not a branch"
allowed 'git push --tags origin' "--tags with no refspec, outside a repository"

echo "== blocked: force push in its remaining spellings =="
blocked 'git push -uf origin feature' "bundled short flags -uf"
blocked 'git push --mirror origin' "--mirror force-updates every ref"
allowed 'git push -u origin feature/x' "-u alone is --set-upstream, not --force"
allowed 'git push -o ci.skip origin feature/x' "-o takes a value that is not a refspec"

echo "== blocked: a URL written inline is still a push target =="
blocked 'git push https://evil.example.com/o/r.git feature' "inline URL outside the allowlist"
blocked 'git push git@evil.example.com:o/r.git feature' "inline scp-style URL outside the allowlist"
allowed 'git push https://github.com/o/r.git feature/x' "inline URL on an allowed domain"

echo "== blocked: destructive operations in short form =="
blocked 'git checkout -f main' "checkout -f"
blocked 'git switch -f main' "switch -f"
blocked 'git clean --force' "clean --force long form"
allowed 'git checkout -b feature/x' "-b is not -f"
allowed 'git checkout -- README.md' "'--' is not a force flag"
allowed 'git clean -nd' "clean -nd is a preview"

# A push with no refspec publishes the current branch, which is repository state
# rather than command text. v1.1.0 skipped the check whenever the branch was not
# typed out, which is the second half of Issue 14.
echo "== blocked: pushes whose target is not on the command line =="
if command -v git >/dev/null 2>&1; then
  GG_TMP=$(mktemp -d)
  mkrepo() {
    local d="$1" branch="$2"
    mkdir -p "$d"
    git -C "$d" init -q >/dev/null 2>&1
    git -C "$d" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$d" -c user.email=t@example.invalid -c user.name=t \
      commit -q --allow-empty -m init >/dev/null 2>&1
  }
  mkrepo "$GG_TMP/on-main" main
  mkrepo "$GG_TMP/on-feature" feature/x

  blocked_at 'git push' "$GG_TMP/on-main" "bare push while HEAD is main"
  blocked_at 'git push origin' "$GG_TMP/on-main" "push naming only the remote, HEAD is main"
  blocked_at 'cd /elsewhere && git push' "$GG_TMP/on-main" "bare push after a cd, HEAD is main"
  blocked_at 'bash -c "git push"' "$GG_TMP/on-main" "bare push inside bash -c"
  allowed_at 'git push' "$GG_TMP/on-feature" "bare push while HEAD is a feature branch"
  allowed_at 'git push origin' "$GG_TMP/on-feature" "remote-only push from a feature branch"
  blocked_at 'git push --all origin' "$GG_TMP/on-feature" \
    "--all publishes protected branches too, whatever HEAD is"
  blocked_at "git -C $GG_TMP/on-main push" "/tmp" \
    "git -C names the repository whose HEAD decides the target"
  allowed 'git push' "bare push with no repository in cwd (the push would fail anyway)"
  GIT_GUARD_CI_MODE=true \
    allowed_at 'git push' "$GG_TMP/on-main" "CI_MODE relaxes the resolved-branch check too"
  rm -rf "$GG_TMP"
else
  echo "  (skipped: git not installed)"
fi

echo "== oversized command falls back to conservative matching =="
PAD=$(head -c 70000 /dev/zero | tr '\0' 'x')
blocked "echo $PAD && git push origin main" "push in a 70KB command"
allowed "echo $PAD && git status" "read-only git in a 70KB command"
unset PAD

echo "== configuration =="
GIT_GUARD_PROTECTED_BRANCHES="develop,trunk" \
  blocked 'git push origin develop' "custom protected list blocks develop"
GIT_GUARD_PROTECTED_BRANCHES="develop,trunk" \
  allowed 'git push origin main' "custom protected list leaves main pushable (operator's choice)"
GIT_GUARD_CI_MODE=true allowed 'git push origin main' "CI_MODE relaxes branch protection"
GIT_GUARD_CI_MODE=true blocked 'git push --force origin main' "CI_MODE still refuses a force push"
GIT_GUARD_ALLOW_FORCE_PUSH=true allowed 'git push --force origin feature' "ALLOW_FORCE_PUSH opt-in"
GIT_GUARD_ALLOWED_DOMAINS="git.acme.com" \
  blocked 'git remote add origin https://github.com/o/r.git' "custom domain list blocks github.com"
GIT_GUARD_ALLOWED_DOMAINS="*.acme.com" \
  allowed 'git remote add origin https://git.acme.com/o/r.git' "wildcard domain match"
GIT_GUARD_DISABLED=true allowed 'git push --force origin main' \
  "GIT_GUARD_DISABLED bypass (documented escape hatch)"

echo "== hook contract =="
# On exit 2 Claude Code discards stdout, so a block reason printed there is
# invisible to the agent and it retries the same command.
p=$(payload 'git push origin main')
out=$(printf '%s' "$p" | "$HOOK" 2>/dev/null || true)
err=$(printf '%s' "$p" | "$HOOK" 2>&1 >/dev/null || true)
if [[ -z "$out" ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "nothing written to stdout on block"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stdout on block was: $out"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stdout must be empty on block"
fi
if [[ "$err" == *"GIT GUARD"* && "$err" == *"pull request"* ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "stderr carries the reason and the alternative"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "stderr missing reason/guidance"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - stderr must carry reason + guidance"
fi
# A hook whose own warnings reach the agent teaches it to distrust the channel.
if [[ "$err" != *"stray"* && "$err" != *"warning:"* ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "no tool warnings leak into the block reason"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "warning leaked: $err"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - grep/sed warnings must not reach stderr"
fi

# A hook slow enough to trip the wrapper timeout is a hook that gets disabled.
# Worst case here is a large heredoc body, which the parser must not walk
# character by character.
BIG=$(printf 'cat > /tmp/big.md <<EOF\n'; head -c 60000 /dev/zero | tr '\0' 'x'; printf '\nEOF\n')
allowed "$BIG" "a 60KB heredoc body is data"
unset BIG
start=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '%s' "$(payload 'git push origin feature/x')" | "$HOOK" >/dev/null 2>&1 || true
end=$(python3 -c 'import time;print(int(time.time()*1000))')
dur=$((end - start))
if [[ "$dur" -lt 1000 ]]; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s (%sms)\n' "single call under 1000ms" "$dur"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s (%sms)\n' "single call too slow" "$dur"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - latency ${dur}ms"
fi

echo "== plugin copy parity =="
# The plugin ships its own copy of this hook. They are meant to be byte
# identical, and nothing was checking that: during this change the gh-guard
# copy silently stayed a version behind, so plugin users would have run the
# unfixed parser while the suite reported green.
PLUGIN_COPY="$ROOT/plugin/hooks/git-guard.sh"
if [[ ! -f "$PLUGIN_COPY" ]]; then
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "plugin/hooks/git-guard.sh is missing"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - plugin copy missing"
elif cmp -s "$HOOK" "$PLUGIN_COPY"; then
  TEST_PASS=$((TEST_PASS + 1)); printf '  ✓ %s\n' "plugin/hooks copy is identical to hooks/"
else
  TEST_FAIL=$((TEST_FAIL + 1)); printf '  ✗ %s\n' "plugin/hooks copy has drifted from hooks/"
  TEST_FAIL_DETAILS="${TEST_FAIL_DETAILS}\n  - plugin/hooks/git-guard.sh differs from hooks/git-guard.sh"
fi

summary
