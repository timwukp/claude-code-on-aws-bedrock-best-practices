#!/bin/bash
# =============================================================================
# Git Guard — Enterprise Git Security Hook for Claude Code
# =============================================================================
# Hook version: 1.2.0
# Last updated: 2026-08-13
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 3.2+, jq (preferred), git, grep
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-05-28) — initial release: allowlist, branch protection,
#                         force-push, destructive op prevention
#   1.1.0 (2026-08-13) — push checks run per command segment. They previously
#                         extracted the remote and branch with `echo | awk`,
#                         which reads a field per LINE, so any newline in the
#                         command turned the branch name into newline-joined
#                         junk and branch protection silently passed.
#   1.2.0 (2026-08-13) — policy is decided on TOKENS instead of on regexes over
#                         the command text (known-issues Issue 14). A `git`
#                         inside a quoted argument was invisible, so
#                         `bash -c "git push origin main"` was allowed; a `;`
#                         inside a quoted argument looked like a separator, so
#                         `echo "x; git push origin main"` was denied. Same
#                         cause, opposite symptoms. Also: a push whose target is
#                         not on the command line (`git push`, `--all`,
#                         `--mirror`) is now resolved or refused instead of
#                         skipped, every refspec is checked rather than only the
#                         first, `+ref:main` counts as a force push, and the
#                         parsing front end is generated from
#                         hooks/lib/shell-parse.sh (shared with gh-guard.sh).
# =============================================================================
# Comprehensive git protection that allows enterprise workflows while blocking
# data exfiltration, destructive operations, and policy violations.
#
# Hook event: PreToolUse (matcher: Bash)
# Inspects git commands and enforces:
#   1. Remote URL allowlist (only push to enterprise domains)
#   2. Force-push prevention (--force / --force-with-lease / +ref:dst / --mirror)
#   3. Branch protection (no direct push to main/master/release/*), including
#      pushes whose target is implicit (bare `git push`, `--all`)
#   4. Remote modification control (add/set-url only to allowed domains)
#   5. Destructive operation prevention (reset --hard, clean -fd, checkout -f)
#
# Parsing notes (see docs/hook-hardening-lessons.md §10, §11):
#   * Segments are split quote-aware AND escape-aware, and each segment is
#     tokenized. Policy is decided on tokens, so a quoted span is one token and
#     `echo "git push origin main"` cannot look like a push.
#   * The reverse of the same property: a `git` hidden in a quoted argument is
#     not a command, so `bash -c "git push origin main"` is re-scanned by
#     recursing into the arguments of interpreters and wrappers only.
#   * A heredoc body is data unless a shell consumes it (`bash <<EOF`).
#
# Note: Credential leak detection in file content is handled by pii-guard.sh
# (which scans Write/Edit tool inputs before files are written to disk).
#
# Configuration via environment variables (set in settings.json env block):
#   GIT_GUARD_ALLOWED_DOMAINS    — comma-separated allowed push domains
#                                  (default: "github.com,gitlab.com,bitbucket.org")
#   GIT_GUARD_PROTECTED_BRANCHES — comma-separated branches requiring PR
#                                  (default: "main,master,release/*,production")
#   GIT_GUARD_ALLOW_FORCE_PUSH   — "true" to allow force push (default: "false")
#   GIT_GUARD_MAX_FILE_SIZE_KB   — max file size in KB (default: "10240" = 10MB)
#   GIT_GUARD_MAX_PARSE_BYTES    — above this, fall back to a conservative regex
#                                  pass (default 65536)
#   GIT_GUARD_CI_MODE            — "true" to relax branch protection for CI/CD
#   GIT_GUARD_DISABLED           — "true" to bypass all checks (emergency)
#
# Exit codes:
#   0 = allow
#   2 = block (stderr shown to Claude — stdout is discarded on exit 2)
# =============================================================================

set -u
LC_ALL=C

input=$(cat)

# --- Parse input ---
if command -v jq >/dev/null 2>&1; then
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  CWD=$(printf '%s' "$input" | jq -r '.cwd // empty')
else
  tool_name=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  command_str=$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  CWD=$(printf '%s' "$input" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

# Only inspect Bash tool
[[ "$tool_name" != "Bash" ]] && exit 0

# Cheap prefilter: every command this hook has an opinion about contains "git",
# including the wrapped forms (`bash -c "git push ..."`).
case "$command_str" in
  *git*) ;;
  *) exit 0 ;;
esac

# --- Configuration ---
ALLOWED_DOMAINS="${GIT_GUARD_ALLOWED_DOMAINS:-github.com,gitlab.com,bitbucket.org}"
PROTECTED_BRANCHES="${GIT_GUARD_PROTECTED_BRANCHES:-main,master,release/*,production}"
ALLOW_FORCE="${GIT_GUARD_ALLOW_FORCE_PUSH:-false}"
MAX_FILE_KB="${GIT_GUARD_MAX_FILE_SIZE_KB:-10240}"
MAX_PARSE_BYTES="${GIT_GUARD_MAX_PARSE_BYTES:-65536}"
CI_MODE="${GIT_GUARD_CI_MODE:-false}"
DISABLED="${GIT_GUARD_DISABLED:-false}"

[[ "$DISABLED" == "true" ]] && exit 0

# --- Deny helper ---
deny() {
  printf 'GIT GUARD: %s\nCommand: %s\n' "$1" "$command_str" >&2
  exit 2
}

# >>> SHARED PARSER — generated from hooks/lib/shell-parse.sh; edit there >>>

# --- Glob match against a comma-separated list -------------------------------
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

# refs/heads/main and main are the same branch; compare the short name.
normalize_branch() {
  local b="$1"
  b="${b#refs/heads/}"
  printf '%s' "$b"
}

# --- Heredoc bodies are data, not commands -----------------------------------
# Segments are split on newlines, so without this every line of a heredoc body
# arrives as its own command segment: writing a file with
# `cat > policy.md <<'EOF' ... EOF` whose prose quotes a blocked command was
# denied as an attempt to run it. A denial nobody believes is how a guard ends
# up switched off, so this is a security bug, not a cosmetic one.
#
# Bodies are stripped from the command text and returned separately, because
# there is one case where a body IS a command list: when a shell consumes it
# (`bash <<EOF`, `cat <<EOF | bash`). Those get re-scanned; the rest are data.
#
# Sets HD_TEXT (command text, bodies removed) and the parallel arrays
# HD_OPENERS / HD_BODIES (the line that opened each body, and the body).
#
# Ambiguity is resolved toward "not a heredoc" on purpose. Mistaking a shift for
# a heredoc opens a phantom body that swallows every following line —
# `echo $((1<<SHIFT))` then a blocked command on the next line would be a silent
# bypass. Mistaking a heredoc for plain text only risks a false positive, which
# is visible.
strip_heredocs() {
  local s="$1"
  HD_TEXT="$s"
  HD_OPENERS=()
  HD_BODIES=()
  # Fast path: no heredoc operator anywhere, which is almost every command.
  [[ "$s" != *'<<'* ]] && return 0

  local n=${#s}
  local i=0
  local out=''
  local q=''
  local hd_open=''
  local hd_body=''
  local line='' rest='' opener='' probe='' delim='' qq=''
  local nxt=0 j=0 m=0 k=0 d=0 c=''
  local -a pend_delim=()
  local -a pend_dash=()
  local pend_i=0

  while [[ $i -lt $n ]]; do
    # One line at a time: a 60KB body must not be walked character by
    # character, and its terminator is line-oriented anyway.
    rest="${s:i}"
    if [[ "$rest" == *$'\n'* ]]; then
      line="${rest%%$'\n'*}"
      nxt=$((i + ${#line} + 1))
    else
      line="$rest"
      nxt=$n
    fi

    # --- inside a body: consume up to the terminator line ---
    if [[ $pend_i -lt ${#pend_delim[@]} ]]; then
      probe="$line"
      # <<- allows the terminator to be indented with tabs (not spaces).
      [[ "${pend_dash[pend_i]}" == 1 ]] && probe="${probe#"${probe%%[!$'\t']*}"}"
      probe="${probe%$'\r'}"
      if [[ "$probe" == "${pend_delim[pend_i]}" ]]; then
        HD_OPENERS[${#HD_OPENERS[@]}]="$hd_open"
        HD_BODIES[${#HD_BODIES[@]}]="$hd_body"
        hd_body=''
        pend_i=$((pend_i+1))
      else
        hd_body="$hd_body$line"$'\n'
      fi
      i=$nxt
      continue
    fi

    # --- a command line: track quotes, pull out heredoc operators ---
    if [[ ${#pend_delim[@]} -gt 0 ]]; then
      pend_delim=(); pend_dash=(); pend_i=0
    fi
    opener=''
    j=0
    m=${#line}
    while [[ $j -lt $m ]]; do
      c="${line:j:1}"
      if [[ -n "$q" ]]; then
        if [[ "$q" == '"' && "$c" == '\' ]]; then opener="$opener$c${line:j+1:1}"; j=$((j+2)); continue; fi
        [[ "$c" == "$q" ]] && q=''
        opener="$opener$c"; j=$((j+1)); continue
      fi
      case "$c" in
        '\') opener="$opener$c${line:j+1:1}"; j=$((j+2)); continue ;;
        "'"|'"') q="$c"; opener="$opener$c"; j=$((j+1)); continue ;;
      esac
      # `<<<` is a herestring — one word, no body.
      if [[ "${line:j:2}" == '<<' && "${line:j:3}" != '<<<' ]]; then
        k=$((j+2)); d=0
        if [[ "${line:k:1}" == '-' ]]; then d=1; k=$((k+1)); fi
        while [[ "${line:k:1}" == ' ' || "${line:k:1}" == $'\t' ]]; do k=$((k+1)); done
        delim=''
        case "${line:k:1}" in
          "'"|'"')
            qq="${line:k:1}"; k=$((k+1))
            while [[ $k -lt $m && "${line:k:1}" != "$qq" ]]; do delim="$delim${line:k:1}"; k=$((k+1)); done
            if [[ $k -lt $m ]]; then k=$((k+1)); else delim=''; fi ;;
          *)
            [[ "${line:k:1}" == '\' ]] && k=$((k+1))
            while [[ $k -lt $m ]]; do
              case "${line:k:1}" in
                [A-Za-z0-9_.-]) delim="$delim${line:k:1}"; k=$((k+1)) ;;
                *) break ;;
              esac
            done
            # A delimiter is a whole shell word starting like an identifier.
            # `$((1<<SHIFT))` stops at ')', which is not a word boundary here,
            # so it stays a shift. `<<4` is not a delimiter either.
            case "$delim" in [A-Za-z_]*) ;; *) delim='' ;; esac
            if [[ -n "$delim" && $k -lt $m ]]; then
              case "${line:k:1}" in
                ' '|$'\t'|';'|'&'|'|'|'>'|'<') ;;
                *) delim='' ;;
              esac
            fi ;;
        esac
        if [[ -n "$delim" ]]; then
          pend_delim[${#pend_delim[@]}]="$delim"
          pend_dash[${#pend_dash[@]}]="$d"
          opener="$opener "
          j=$k
          continue
        fi
      fi
      opener="$opener$c"; j=$((j+1))
    done
    out="$out$opener"$'\n'
    hd_open="$opener"
    hd_body=''
    i=$nxt
  done

  # An unterminated heredoc: bash reads the rest of the input as the body.
  if [[ $pend_i -lt ${#pend_delim[@]} && -n "$hd_body" ]]; then
    HD_OPENERS[${#HD_OPENERS[@]}]="$hd_open"
    HD_BODIES[${#HD_BODIES[@]}]="$hd_body"
  fi

  HD_TEXT="$out"
  return 0
}

# --- Quote-aware, escape-aware segment split ---------------------------------
# Separators: ; & | newline and the subshell/backtick boundaries ( ) `
# so that `$(gh pr merge 1)` yields a segment of its own.
split_segments() {
  local s="$1"
  local n=${#s} i=0 c q='' cur=''
  SEGMENTS=()
  # Fast path: nothing quoted or escaped — plain field splitting is exact.
  if [[ "$s" != *[\'\"\\]* ]]; then
    local t="$s"
    t="${t//;/$'\n'}"; t="${t//&/$'\n'}"; t="${t//|/$'\n'}"
    t="${t//(/$'\n'}"; t="${t//)/$'\n'}"; t="${t//\`/$'\n'}"
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && SEGMENTS[${#SEGMENTS[@]}]="$line"
    done <<< "$t"
    return 0
  fi
  while [[ $i -lt $n ]]; do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$c" == '\' && "$q" == '"' ]]; then cur="$cur$c${s:i+1:1}"; i=$((i+2)); continue; fi
      [[ "$c" == "$q" ]] && q=''
      cur="$cur$c"; i=$((i+1)); continue
    fi
    case "$c" in
      '\') cur="$cur$c${s:i+1:1}"; i=$((i+2)); continue ;;
      "'"|'"') q="$c"; cur="$cur$c"; i=$((i+1)); continue ;;
      ';'|'&'|'|'|'('|')'|'`'|$'\n')
        [[ -n "$cur" ]] && SEGMENTS[${#SEGMENTS[@]}]="$cur"
        cur=''; i=$((i+1)); continue ;;
    esac
    cur="$cur$c"; i=$((i+1))
  done
  [[ -n "$cur" ]] && SEGMENTS[${#SEGMENTS[@]}]="$cur"
  return 0
}

# --- Tokenize one segment into real argument values (quotes removed) ---------
# A quoted span collapses into ONE token, which is what makes every token scan
# quote-aware for free: `echo "git push origin main"` has two tokens, and the
# second is not the word `git`.
tokenize() {
  local s="$1"
  local n=${#s} i=0 c q='' cur='' has=0
  TOKENS=()
  while [[ $i -lt $n ]]; do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$q" == '"' && "$c" == '\' ]]; then cur="$cur${s:i+1:1}"; i=$((i+2)); has=1; continue; fi
      if [[ "$c" == "$q" ]]; then q=''; i=$((i+1)); continue; fi
      cur="$cur$c"; i=$((i+1)); continue
    fi
    case "$c" in
      '\') cur="$cur${s:i+1:1}"; i=$((i+2)); has=1; continue ;;
      "'"|'"') q="$c"; has=1; i=$((i+1)); continue ;;
      ' '|$'\t'|$'\n')
        if [[ $has -eq 1 || -n "$cur" ]]; then TOKENS[${#TOKENS[@]}]="$cur"; fi
        cur=''; has=0; i=$((i+1)); continue ;;
    esac
    cur="$cur$c"; i=$((i+1)); has=1
  done
  if [[ $has -eq 1 || -n "$cur" ]]; then TOKENS[${#TOKENS[@]}]="$cur"; fi
  return 0
}

# --- The command word of a token list ----------------------------------------
# Leading VAR=value assignments and transparent prefixes (env, sudo, ...) are
# skipped, and the result is a basename so /bin/bash and bash compare equal.
command_word() {
  local t
  for t in "$@"; do
    case "$t" in
      [A-Za-z_]*=*) continue ;;
      env|command|builtin|exec|sudo|doas|nohup|time|then|do|else|!) continue ;;
      *) printf '%s' "${t##*/}"; return 0 ;;
    esac
  done
  return 1
}

# --- Where a named program's arguments start in a token list -----------------
# Echoes the 1-based index of the token *after* $1, or fails if the token list is
# not an invocation of it. Handles VAR=val prefixes, transparent prefixes
# (`sudo gh ...`) and wrappers that carry arguments of their own
# (`timeout 5 git push`, `xargs -0 git push`), which a plain "first word" test
# misses — and missing them is a fail-open, not a false positive.
#
# Residual limit: a wrapper option that takes a *non-flag* value stops the walk,
# so `sudo -u bob git push` is not recognised. Skipping arbitrary words instead
# would let `xargs -I{} echo git push` read as a push, and a false positive on
# `echo` costs more than this case is worth. See docs/known-issues.md.
cmd_arg_start() {
  local want="$1"; shift
  local i=0 t wrapped=0
  for t in "$@"; do
    i=$((i+1))
    case "$t" in
      [A-Za-z_]*=*) continue ;;
    esac
    case "${t##*/}" in
      "$want") printf '%s' "$i"; return 0 ;;
      env|command|builtin|exec|sudo|doas|nohup|time|then|do|else|!) continue ;;
      timeout|xargs|nice|stdbuf|flock|setsid|watch|parallel|script)
        wrapped=1; continue ;;
    esac
    if [[ $wrapped -eq 1 ]]; then
      case "$t" in
        -*|[0-9]*) continue ;;
      esac
    fi
    return 1
  done
  return 1
}

# --- Quoted arguments that a wrapper will hand to a shell --------------------
# Sets NESTED to the multi-word arguments of an interpreter or exec wrapper, so
# `bash -c "git push origin main"` can be re-scanned as a command. Empty for
# anything else: recursing into every quoted string would turn
# `echo "git push origin main"` into a denial, and a guard that blocks talking
# about a command is a guard that gets switched off.
nested_candidates() {
  NESTED=()
  local cword
  cword=$(command_word "$@") || return 0
  case "$cword" in
    bash|sh|zsh|dash|ksh|eval|xargs|timeout|ssh|script|setsid|flock|nice|stdbuf|watch|parallel) ;;
    *) return 0 ;;
  esac
  local t
  for t in "$@"; do
    case "$t" in
      *[[:space:]]*) NESTED[${#NESTED[@]}]="$t" ;;
    esac
  done
  return 0
}

# --- Does the line that opened a heredoc hand the body to something that runs it?
# `cat <<EOF > notes.md` writes data; `bash <<EOF` and `cat <<EOF | bash` run it.
# Skipping this would be a regression: before heredoc bodies were separated from
# command text, body lines were inspected as commands, so `bash <<EOF ... EOF`
# was caught by accident.
opener_runs_shell() {
  local seg="$1"
  tokenize "$seg"
  local -a toks=(${TOKENS[@]+"${TOKENS[@]}"})
  local cword
  cword=$(command_word ${toks[@]+"${toks[@]}"}) || cword=''
  # The list errs toward "this runs a shell": guessing wrong in that direction
  # costs a visible false positive, guessing wrong the other way lets a script
  # through unread.
  case "$cword" in
    bash|sh|zsh|dash|ksh|eval|xargs|timeout|script|setsid|flock|nice|stdbuf) return 0 ;;
  esac
  # A pipe into a shell makes the producer's output a script. The scan runs over
  # TOKENS, not the raw text, because tokenize() collapses a quoted span into a
  # single token: a `| bash` sitting inside a quoted argument is data being
  # handed to some other program, and treating it as a real pipe would recurse
  # into that argument and parse its contents as commands.
  local t w expect=0
  for t in ${toks[@]+"${toks[@]}"}; do
    if [[ $expect -eq 1 ]]; then
      case "$t" in
        sudo|env|command|exec|nohup|[A-Za-z_]*=*) continue ;;
      esac
      case "${t##*/}" in
        bash|sh|zsh|dash|ksh) return 0 ;;
      esac
      expect=0
    fi
    case "$t" in
      *'|'*)
        # `cat <<EOF|bash` tokenizes as one word; `| bash` as two.
        w="${t##*|}"
        if [[ -z "$w" ]]; then
          expect=1
        else
          case "${w##*/}" in
            bash|sh|zsh|dash|ksh) return 0 ;;
          esac
        fi ;;
    esac
  done
  return 1
}

# <<< SHARED PARSER — end of generated region <<<

# --- Helper: check if URL domain is in allowlist ------------------------------
url_allowed() {
  local url="$1"
  local domain=""

  # Extract domain from the URL forms git accepts
  case "$url" in
    https://*|http://*)
      domain="${url#*://}"
      domain="${domain%%/*}"
      domain="${domain##*@}"
      domain="${domain%%:*}" ;;
    ssh://*)
      domain="${url#ssh://}"
      domain="${domain%%/*}"
      domain="${domain##*@}"
      domain="${domain%%:*}" ;;
    git://*)
      domain="${url#git://}"
      domain="${domain%%/*}"
      domain="${domain%%:*}" ;;
    *@*:*)
      # scp-style: git@host:owner/repo.git
      domain="${url#*@}"
      domain="${domain%%:*}" ;;
    *)
      # Unknown format — block by default
      return 1 ;;
  esac
  [[ -z "$domain" ]] && return 1
  list_match "$domain" "$ALLOWED_DOMAINS"
}

# Does a token look like a remote URL at all? (Anything else is a remote name or
# a path, which git resolves itself.)
looks_like_url() {
  case "$1" in
    https://*|http://*|ssh://*|git://*) return 0 ;;
    *@*:*) return 0 ;;
  esac
  return 1
}

# --- Helper: check if branch matches protected pattern ------------------------
# CI_MODE lives here rather than at each call site so that every path which
# resolves a branch — command line, refspec, or HEAD — relaxes together.
branch_protected() {
  [[ "$CI_MODE" == "true" ]] && return 1
  list_match "$1" "$PROTECTED_BRANCHES"
}

# --- Repository context -------------------------------------------------------
# `git -C <dir>` moves the repository the command acts on, so the directory used
# to resolve a remote or HEAD has to come from the command, not only from cwd.
resolve_dir() {
  local hint="$1"
  if [[ -n "$hint" ]]; then
    case "$hint" in
      /*) printf '%s' "$hint" ;;
      *)  printf '%s' "${CWD:-.}/$hint" ;;
    esac
    return 0
  fi
  printf '%s' "${CWD:-}"
}

is_repo() {
  local d="$1"
  [[ -n "$d" ]] || return 1
  [[ -d "$d/.git" || -f "$d/.git" ]]
}

get_remote_url() {
  local remote_name="$1" d="$2"
  command -v git >/dev/null 2>&1 || return 1
  if is_repo "$d"; then
    git -C "$d" remote get-url "$remote_name" 2>/dev/null
  else
    return 1
  fi
}

# The branch a bare `git push` would publish. Only consulted when the command
# line does not name one; a detached HEAD or a non-repository yields nothing and
# the check is skipped (the push would fail anyway).
#
# `.git` is required to exist in the directory itself rather than letting git
# walk up to a parent repository: an agent running `git push` in /tmp must not
# be judged against whatever repository happens to contain /tmp's parent.
current_branch() {
  local d="$1" b
  is_repo "$d" || return 1
  command -v git >/dev/null 2>&1 || return 1
  b=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [[ -z "$b" || "$b" == "HEAD" ]] && return 1
  printf '%s' "$b"
}

# =============================================================================
# CHECK 1 & 2: git remote — allowlist on add/set-url, no rename/rm
# =============================================================================
check_remote() {
  local t verb='' url=''
  for t in "$@"; do
    case "$t" in
      -*) continue ;;
    esac
    if [[ -z "$verb" ]]; then verb="$t"; continue; fi
    if looks_like_url "$t"; then url="$t"; fi
  done

  case "$verb" in
    add|set-url)
      # No URL in the command means a local path or a `--delete` form: git will
      # resolve it, and there is no domain to police.
      if [[ -n "$url" ]] && ! url_allowed "$url"; then
        deny "Remote URL not in enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS. Blocked URL: $url"
      fi ;;
    rename|rm|remove)
      deny "Modifying or removing git remotes is restricted. Contact your team lead to change remote configuration." ;;
  esac
  return 0
}

# =============================================================================
# CHECK 2 & 3: git push — force push, remote allowlist, branch protection
# =============================================================================
# Everything here is decided from this push's own tokens. Reading the fields out
# of the whole command text is what made this check fail open twice: once on a
# newline (v1.1.0) and once on a quoted wrapper (v1.2.0).
check_push() {
  local dir="$1"; shift
  local t force=0 mirror=0 pushall=0 pending=''
  local -a pos=()
  for t in "$@"; do
    if [[ -n "$pending" ]]; then pending=''; continue; fi
    case "$t" in
      --force|--force-with-lease|--force-with-lease=*) force=1; continue ;;
      --mirror) mirror=1; continue ;;
      --all|--branches) pushall=1; continue ;;
      -o|--push-option|--repo|--receive-pack|--exec) pending=1; continue ;;
      --*) continue ;;
      -*)
        # Short flags bundle: -f, -uf and -fu are all --force.
        case "$t" in *f*) force=1 ;; esac
        continue ;;
    esac
    pos[${#pos[@]}]="$t"
  done

  # 3a. Force push, in either spelling. `--mirror` is a force push of every ref
  # plus a delete of anything the local repository does not have.
  if [[ "$ALLOW_FORCE" != "true" ]]; then
    [[ $force -eq 1 ]] && deny "Force push is forbidden by enterprise policy. Use a regular push or create a new branch."
    [[ $mirror -eq 1 ]] && deny "'git push --mirror' force-updates every ref on the remote and deletes refs missing locally. This is never an agent action."
  fi

  # 3b. Remote: either a configured name or a URL written inline.
  local remote='' remote_url
  if [[ ${#pos[@]} -gt 0 ]]; then
    remote="${pos[0]}"
    if looks_like_url "$remote"; then
      if ! url_allowed "$remote"; then
        deny "Push target '$remote' is not in the enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS"
      fi
    elif remote_url=$(get_remote_url "$remote" "$dir"); then
      if [[ -n "$remote_url" ]] && ! url_allowed "$remote_url"; then
        deny "Push target '$remote' ($remote_url) is not in the enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS"
      fi
    fi
    # An unresolvable remote is allowed: the push will fail on its own.
  fi

  # 3c. Branch protection for every refspec, not only the first. `git push
  # origin feature main` names two destinations and the second one matters.
  local spec dst had_spec=0 i=1
  while [[ $i -lt ${#pos[@]} ]]; do
    spec="${pos[i]}"
    i=$((i+1))
    had_spec=1
    # A leading + on a refspec is --force for that ref alone.
    case "$spec" in
      +*)
        if [[ "$ALLOW_FORCE" != "true" ]]; then
          deny "Refspec '$spec' begins with '+', which force-updates the remote ref. Use a regular push or create a new branch."
        fi
        spec="${spec#+}" ;;
    esac
    # Tags are not branches.
    case "$spec" in
      refs/tags/*|*:refs/tags/*) continue ;;
    esac
    # local:remote — the destination is what branch protection is about, and
    # `:main` (no source) is a request to DELETE main.
    dst="${spec#*:}"
    [[ -z "$dst" ]] && dst="$spec"
    dst=$(normalize_branch "$dst")
    if branch_protected "$dst"; then
      deny "Direct push to protected branch '$dst' is forbidden. Use a pull request instead. Protected branches: $PROTECTED_BRANCHES"
    fi
  done

  # 3d. Targets that are not written on the command line at all. Skipping these
  # was a fail-open: the check only ever ran when a branch happened to be typed.
  if [[ $pushall -eq 1 ]]; then
    if [[ "$CI_MODE" != "true" ]]; then
      deny "'git push --all' publishes every local branch, which includes the protected ones ($PROTECTED_BRANCHES). Push one feature branch and open a pull request."
    fi
  elif [[ $had_spec -eq 0 ]]; then
    local cb
    if cb=$(current_branch "$dir"); then
      if branch_protected "$cb"; then
        deny "'git push' with no refspec publishes the current branch, which is '$cb' — a protected branch. Create a feature branch and open a pull request. Protected branches: $PROTECTED_BRANCHES"
      fi
    fi
    # HEAD unresolvable (not a repository, or detached): nothing to compare.
  fi
  return 0
}

# =============================================================================
# CHECK 4-6: destructive operations
# =============================================================================
check_reset() {
  local t
  for t in "$@"; do
    case "$t" in
      --hard) deny "git reset --hard is forbidden. Use 'git reset --soft' or 'git revert' for non-destructive alternatives." ;;
    esac
  done
  return 0
}

check_clean() {
  local t
  for t in "$@"; do
    case "$t" in
      --force) deny "git clean -f is forbidden. It permanently removes untracked files. Use 'git clean -n' to preview first." ;;
      --*) continue ;;
      -*f*) deny "git clean -f is forbidden. It permanently removes untracked files. Use 'git clean -n' to preview first." ;;
    esac
  done
  return 0
}

check_checkout() {
  local sub="$1"; shift
  local t
  for t in "$@"; do
    case "$t" in
      --force) deny "Forced $sub can discard uncommitted changes. Remove --force or commit your changes first." ;;
      --*) continue ;;
      -*f*) deny "Forced $sub can discard uncommitted changes. Remove -f/--force or commit your changes first." ;;
    esac
  done
  return 0
}

# =============================================================================
# Policy for one `git ...` invocation. Tokens are passed as "$@", starting at the
# token after `git`.
# =============================================================================
check_git() {
  local -a args=("$@")
  local n=${#args[@]} i=0 t sub='' dirhint=''
  # git's own options come before the subcommand, and -C changes which
  # repository the subcommand acts on.
  while [[ $i -lt $n ]]; do
    t="${args[i]}"
    case "$t" in
      -C) dirhint="${args[i+1]:-}"; i=$((i+2)); continue ;;
      --git-dir|--work-tree|--namespace|--exec-path|-c) i=$((i+2)); continue ;;
      -C?*) dirhint="${t#-C}"; i=$((i+1)); continue ;;
      -*) i=$((i+1)); continue ;;
      *) sub="$t"; i=$((i+1)); break ;;
    esac
  done
  local -a rest=()
  [[ $i -lt $n ]] && rest=("${args[@]:i}")
  local dir
  dir=$(resolve_dir "$dirhint")

  case "$sub" in
    push)            check_push "$dir" ${rest[@]+"${rest[@]}"} ;;
    remote)          check_remote ${rest[@]+"${rest[@]}"} ;;
    reset)           check_reset ${rest[@]+"${rest[@]}"} ;;
    clean)           check_clean ${rest[@]+"${rest[@]}"} ;;
    checkout|switch) check_checkout "$sub" ${rest[@]+"${rest[@]}"} ;;
  esac
  return 0
}

# =============================================================================
# Walk the command: heredocs → segments → tokens → policy, recursing into
# interpreter arguments
# =============================================================================
scan_command() {
  local cmd="$1" depth="$2"
  # A body fed to a shell, or a quoted argument handed to one, is a script and
  # gets re-scanned. The cap stops a crafted nest from spinning; three levels is
  # far past anything real.
  [[ $depth -gt 3 ]] && return 0

  # Pull heredoc bodies out before splitting on newlines, and copy the results
  # into locals immediately — the recursive calls below overwrite the globals.
  strip_heredocs "$cmd"
  local text="$HD_TEXT"
  local -a hopeners=(${HD_OPENERS[@]+"${HD_OPENERS[@]}"})
  local -a hbodies=(${HD_BODIES[@]+"${HD_BODIES[@]}"})
  local hi=0
  while [[ $hi -lt ${#hbodies[@]} ]]; do
    if opener_runs_shell "${hopeners[hi]}"; then
      scan_command "${hbodies[hi]}" $((depth+1))
    fi
    hi=$((hi+1))
  done

  split_segments "$text"
  local -a segs=(${SEGMENTS[@]+"${SEGMENTS[@]}"})
  local seg idx t
  for seg in ${segs[@]+"${segs[@]}"}; do
    case "$seg" in *git*) ;; *) continue ;; esac
    tokenize "$seg"
    local -a toks=(${TOKENS[@]+"${TOKENS[@]}"})
    # Collect the nested candidates before running policy: check_git() calls
    # tokenize() again for its own work and would overwrite TOKENS/NESTED.
    nested_candidates ${toks[@]+"${toks[@]}"}
    local -a nested=(${NESTED[@]+"${NESTED[@]}"})
    if idx=$(cmd_arg_start git ${toks[@]+"${toks[@]}"}); then
      local -a rest=()
      [[ $idx -lt ${#toks[@]} ]] && rest=("${toks[@]:idx}")
      check_git ${rest[@]+"${rest[@]}"}
    fi
    for t in ${nested[@]+"${nested[@]}"}; do
      case "$t" in *git*) scan_command "$t" $((depth+1)) ;; esac
    done
  done
  return 0
}

# Oversized commands are not tokenized character by character (a 1MB heredoc
# would cost seconds). They get a conservative regex pass instead: the risk of a
# false positive on a 64KB git command is preferable to skipping enforcement.
if [[ ${#command_str} -gt $MAX_PARSE_BYTES ]]; then
  if printf '%s' "$command_str" | grep -qE 'git[[:space:]]+([^;&|]*[[:space:]])?(push|reset[[:space:]]+--hard|clean[[:space:]]+-[a-zA-Z]*f|remote[[:space:]]+(add|set-url|rename|rm|remove))'; then
    deny "git write or destructive operation found in an oversized command (${#command_str} bytes, above GIT_GUARD_MAX_PARSE_BYTES=$MAX_PARSE_BYTES) that is too large to parse precisely. Split the command."
  fi
  exit 0
fi

# =============================================================================
# All checks passed
# =============================================================================
scan_command "$command_str" 0
exit 0
