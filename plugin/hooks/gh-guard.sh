#!/bin/bash
# =============================================================================
# GitHub CLI Guard — repo-write policy for the `gh` command surface
# =============================================================================
# Hook version: 1.1.0
# Last updated: 2026-08-13
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 3.2+, jq (preferred)
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-08-13) — initial release: quote-aware parser, contents/ref/merge
#                        /secret/protection endpoint policy, nested -c recursion
#   1.1.0 (2026-08-13) — heredoc bodies are treated as data, not as command
#                        segments (they were denied for merely describing a
#                        blocked verb); a body a shell consumes is still scanned
# =============================================================================
# git-guard.sh inspects `git` commands. It does not inspect `gh`, and `gh` is a
# complete second write path to the same remote: `gh api --method PUT
# repos/O/R/contents/f` commits a file without git ever running, and `gh pr
# merge` lands a branch without a push. An agent that is blocked from
# `git push origin main` can do both. This hook closes that surface.
#
# Hook event: PreToolUse (matcher: Bash)
#
# Policy — the only sanctioned write path is a pull request:
#   1. branch create (POST git/refs)  → allowed
#   2. contents write on that branch  → allowed
#   3. gh pr create                   → allowed
#   4. review + merge                 → human, not the agent
#
# Enforced:
#   1. Contents-API writes with no explicit branch (they land on the default
#      branch) or with a branch matching a protected pattern
#   2. Ref updates/deletes (PATCH/DELETE git/refs/heads/<protected>)
#   3. gh pr merge, POST pulls/N/merge, POST repos/O/R/merges into a protected base
#   4. Repo/release/branch deletion, gh repo sync (writes a fork's default branch)
#   5. Branch-protection tampering, collaborator grants
#   6. Actions secret/variable writes (a credential leaving the machine)
#   7. gh alias set (an alias is a rename of a blocked verb)
#   8. --hostname outside the allowlist
#   9. curl/wget straight to api.github.com (or a GHE /api/v3/ host) with a
#      write method — the same endpoints, reached without gh
#
# Parsing notes (see docs/hook-hardening-lessons.md):
#   * Segments are split quote-aware AND escape-aware, so `-f m="a; gh x"` is
#     one segment and `Bob\'s` does not merge two.
#   * Field values are read by argument position, not by regex over the whole
#     command: `-f message="... branch=feature ..."` must not satisfy the
#     branch check for a write that actually targets the default branch.
#   * Multi-word tokens containing `gh` are re-scanned, so `bash -c 'gh pr
#     merge 1'` is inspected rather than treated as one opaque argument.
#
# Configuration via environment variables (settings.json env block):
#   GH_GUARD_PROTECTED_BRANCHES        — comma list, globs allowed
#                                        (default "main,master,release/*,production")
#   GH_GUARD_ALLOWED_HOSTS             — comma list (default "github.com")
#   GH_GUARD_ALLOW_DEFAULT_BRANCH_WRITE— "true" allows contents writes with no
#                                        branch field (default "false")
#   GH_GUARD_ALLOW_PR_MERGE            — "true" allows gh pr merge (default "false")
#   GH_GUARD_ALLOW_SECRET_WRITES       — "true" allows gh secret/variable set
#   GH_GUARD_ALLOW_ACCESS_CHANGES      — "true" allows collaborator/protection edits
#   GH_GUARD_CI_MODE                   — "true" relaxes branch protection
#   GH_GUARD_MAX_PARSE_BYTES           — above this, fall back to a conservative
#                                        regex pass (default 65536)
#   GH_GUARD_DISABLED                  — "true" bypasses all checks (emergency)
#
# Exit codes:
#   0 = allow
#   2 = block (stderr is what Claude sees — stdout is discarded on exit 2)
# =============================================================================

set -u
LC_ALL=C

input=$(cat)

# --- Parse input -------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  tool_name=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  command_str=$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

[[ "$tool_name" != "Bash" ]] && exit 0

# Cheap prefilter. "github" does NOT contain the substring "gh" (g-i-t-h-u-b),
# so the hostname needs its own pattern; api/v3 covers a self-hosted GitHub
# Enterprise host whose name contains neither.
case "$command_str" in
  *gh*|*github*|*api/v3*) ;;
  *) exit 0 ;;
esac

# --- Configuration -----------------------------------------------------------
PROTECTED_BRANCHES="${GH_GUARD_PROTECTED_BRANCHES:-main,master,release/*,production}"
ALLOWED_HOSTS="${GH_GUARD_ALLOWED_HOSTS:-github.com}"
ALLOW_DEFAULT_WRITE="${GH_GUARD_ALLOW_DEFAULT_BRANCH_WRITE:-false}"
ALLOW_PR_MERGE="${GH_GUARD_ALLOW_PR_MERGE:-false}"
ALLOW_SECRET_WRITES="${GH_GUARD_ALLOW_SECRET_WRITES:-false}"
ALLOW_ACCESS_CHANGES="${GH_GUARD_ALLOW_ACCESS_CHANGES:-false}"
CI_MODE="${GH_GUARD_CI_MODE:-false}"
MAX_PARSE_BYTES="${GH_GUARD_MAX_PARSE_BYTES:-65536}"
DISABLED="${GH_GUARD_DISABLED:-false}"

[[ "$DISABLED" == "true" ]] && exit 0

GUIDE='Sanctioned write path (each step is allowed by this hook):
  1. gh api --method POST repos/O/R/git/refs -f ref=refs/heads/<feature> -f sha=<base-sha>
  2. gh api --method PUT  repos/O/R/contents/<path> -f branch=<feature> -f message=... -f content=<base64>
  3. gh pr create --base <default> --head <feature> --title ... --body ...
  4. Ask a human to review and merge.'

deny() {
  printf 'GH GUARD: %s\n\nCommand: %s\n\n%s\n\nHook: gh-guard.sh\n' \
    "$1" "$command_str" "$GUIDE" >&2
  exit 2
}

# --- Helper: glob match against a comma-separated list ------------------------
list_match() {
  local needle="$1" list="$2" pattern
  local oldifs="$IFS"
  IFS=','
  for pattern in $list; do
    IFS="$oldifs"
    # trim
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

# refs/heads/main and main are the same branch; compare the short name.
normalize_branch() {
  local b="$1"
  b="${b#refs/heads/}"
  printf '%s' "$b"
}

# --- Heredoc bodies are data, not commands -----------------------------------
# split_segments() treats a newline as a separator, so every line of a heredoc
# body arrives as its own command segment. Writing a file with
# `cat > policy.md <<'EOF' ... EOF` whose prose mentions `gh pr merge` was
# therefore denied as an attempt to merge a PR — nothing was being merged, and
# a docs-heavy repo hits this constantly. A denial nobody believes is how a
# guard ends up switched off, so this is a security bug, not a cosmetic one.
#
# Bodies are stripped from the command text and returned separately, because
# there is one case where a body IS a command list: when a shell consumes it
# (`bash <<EOF`, `cat <<EOF | bash`). Those get re-scanned; the rest are data.
#
# Sets HD_TEXT (command text, bodies removed) and the parallel arrays
# HD_OPENERS / HD_BODIES (the line that opened each body, and the body).
#
# Ambiguity is resolved toward "not a heredoc" on purpose. Mistaking a shift
# for a heredoc opens a phantom body that swallows every following line —
# `echo $((1<<SHIFT))` then `gh pr merge 1` would be a silent bypass. Mistaking
# a heredoc for plain text only risks a false positive, which is visible.
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

# Does the line that opened a heredoc hand the body to something that runs it?
# `cat <<EOF > notes.md` writes data; `bash <<EOF` and `cat <<EOF | bash` run it.
opener_runs_shell() {
  local seg="$1"
  tokenize "$seg"
  local -a toks=(${TOKENS[@]+"${TOKENS[@]}"})
  local cword
  cword=$(command_word ${toks[@]+"${toks[@]}"}) || cword=''
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

# --- Field access on a token array passed as "$@" ----------------------------
# Reads `-f name=value`, `-fname=value`, `--field name=value`,
# `--field=name=value`, and the -F / --raw-field variants. Anchored on the flag,
# so a `name=value` pair inside a quoted message body is never mistaken for one.
field_value() {
  local want="$1"; shift
  local t pending='' v
  for t in "$@"; do
    if [[ -n "$pending" ]]; then
      pending=''
      case "$t" in
        "$want"=*) v="${t#*=}"; printf '%s' "$v"; return 0 ;;
      esac
      continue
    fi
    case "$t" in
      -f|-F|--field|--raw-field) pending=1 ;;
      --field=*|--raw-field=*)
        v="${t#*=}"
        case "$v" in "$want"=*) printf '%s' "${v#*=}"; return 0 ;; esac ;;
      -f*|-F*)
        v="${t#-?}"
        case "$v" in "$want"=*) printf '%s' "${v#*=}"; return 0 ;; esac ;;
    esac
  done
  return 1
}

has_field_flag() {
  local t
  for t in "$@"; do
    case "$t" in
      -f|-F|--field|--raw-field|--field=*|--raw-field=*|-f?*|-F?*|--input|--input=*) return 0 ;;
    esac
  done
  return 1
}

flag_value() {
  local want="$1"; shift
  local t pending=''
  for t in "$@"; do
    if [[ -n "$pending" ]]; then printf '%s' "$t"; return 0; fi
    case "$t" in
      "$want") pending=1 ;;
      "$want"=*) printf '%s' "${t#*=}"; return 0 ;;
    esac
  done
  return 1
}

# --- Branch that a contents/ref write will actually land on ------------------
# Absent `branch`, the GitHub contents API commits to the repository default
# branch. We do not resolve the default branch over the network (a hook must
# work offline and fast): an unspecified branch is treated as the default
# branch and denied, which also forces the explicit-branch habit the PR
# workflow needs.
write_branch() {
  local b
  if b=$(field_value branch "$@"); then normalize_branch "$b"; return 0; fi
  # --input <file>: read the JSON body if we can, otherwise report unknown.
  local inp
  if inp=$(flag_value --input "$@") || inp=$(flag_value --input= "$@"); then
    if [[ "$inp" != "-" && -r "$inp" ]] && command -v jq >/dev/null 2>&1; then
      b=$(jq -r '.branch // empty' <"$inp" 2>/dev/null)
      if [[ -n "$b" ]]; then normalize_branch "$b"; return 0; fi
    fi
    printf '%s' '__unknown__'
    return 0
  fi
  return 1
}

# --- gh api: strip scheme/host, leaving repos/O/R/... ------------------------
normalize_endpoint() {
  local e="$1"
  e="${e#https://}"; e="${e#http://}"
  case "$e" in
    api.github.com/*) e="${e#api.github.com/}" ;;
    */api/v3/*)       e="${e#*/api/v3/}" ;;
  esac
  e="${e#/}"
  printf '%s' "${e%%\?*}"
}

# The HTTP method gh will use: explicit flag, else POST when fields are
# present, else GET.
api_method() {
  local m t
  if m=$(flag_value --method "$@"); then printf '%s' "$m"; return 0; fi
  if m=$(flag_value -X "$@"); then printf '%s' "$m"; return 0; fi
  for t in "$@"; do
    case "$t" in
      -X?*) printf '%s' "${t#-X}"; return 0 ;;
      --method=*) printf '%s' "${t#*=}"; return 0 ;;
    esac
  done
  if has_field_flag "$@"; then printf '%s' POST; else printf '%s' GET; fi
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# First positional argument after the subcommand (flag values skipped).
positional() {
  local want_index="$1"; shift
  local t pending='' seen=0
  for t in "$@"; do
    if [[ -n "$pending" ]]; then pending=''; continue; fi
    case "$t" in
      -X|--method|-f|-F|--field|--raw-field|-H|--header|--input|--hostname|--jq|-q|--template|-t|--cache)
        pending=1; continue ;;
      -*) continue ;;
    esac
    seen=$((seen+1))
    if [[ $seen -eq $want_index ]]; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# =============================================================================
# Endpoint policy for one authenticated write to the GitHub API. Shared by
# `gh api` and by curl/wget, which reach the same endpoints with a hand-supplied
# token and must not be a cheaper way round the same rule.
#   $1 endpoint (host stripped)   $2 HTTP method (upper)
#   $3 branch: a name, __none__ (field absent) or __unknown__ (body unreadable)
#   $4 base branch, for merge endpoints
# =============================================================================
check_api_write() {
  local endpoint="$1" method="$2" bstate="$3" base="$4"
  case "$endpoint" in
    repos/*/contents/*|repos/*/contents)
      case "$bstate" in
        __none__)
          [[ "$ALLOW_DEFAULT_WRITE" == "true" ]] && return 0
          deny "Contents-API write with no 'branch' field commits to the repository default branch. Name a feature branch and open a pull request." ;;
        __unknown__)
          deny "Contents-API write whose target branch cannot be read from the request body, so it cannot be checked against the protected list. Pass the branch explicitly." ;;
        *)
          if branch_protected "$bstate"; then
            deny "Contents-API write to protected branch '$bstate'. Protected: $PROTECTED_BRANCHES"
          fi
          return 0 ;;
      esac ;;
    repos/*/git/refs/*)
      local ref="${endpoint#*/git/refs/}"
      ref="${ref#heads/}"
      case "$method" in
        PATCH|PUT|DELETE)
          if branch_protected "$ref"; then
            deny "$method on ref '$ref' rewrites or deletes a protected branch. Protected: $PROTECTED_BRANCHES"
          fi ;;
      esac
      return 0 ;;
    repos/*/git/refs)
      # Branch creation is step 1 of the sanctioned flow.
      return 0 ;;
    repos/*/pulls/*/merge)
      [[ "$ALLOW_PR_MERGE" == "true" ]] && return 0
      deny "Merging a pull request through the API is the same act as 'gh pr merge' and is a human decision." ;;
    repos/*/merges)
      base=$(normalize_branch "$base")
      if [[ -n "$base" ]] && branch_protected "$base"; then
        deny "API merge into protected base '$base'. Open a pull request instead."
      fi
      return 0 ;;
    repos/*/branches/*/protection*)
      [[ "$ALLOW_ACCESS_CHANGES" == "true" ]] && return 0
      deny "$method on branch protection settings would weaken the control that makes the PR workflow enforceable." ;;
    repos/*/collaborators/*|orgs/*/memberships/*|orgs/*/teams/*/memberships/*)
      [[ "$ALLOW_ACCESS_CHANGES" == "true" ]] && return 0
      deny "$method grants or revokes repository/org access. Requires a human." ;;
    repos/*/actions/secrets/*|repos/*/actions/variables/*|orgs/*/actions/secrets/*|repos/*/environments/*/secrets/*)
      [[ "$ALLOW_SECRET_WRITES" == "true" ]] && return 0
      deny "$method writes an Actions secret/variable — a credential leaving this machine." ;;
    repos/*/releases/*)
      case "$method" in
        DELETE) deny "DELETE on a release removes a published artifact. Requires a human." ;;
      esac
      return 0 ;;
    repos/*)
      # DELETE repos/O/R is repository deletion; deeper paths matched above.
      case "$method" in
        DELETE)
          local slashes="${endpoint//[!\/]/}"
          if [[ ${#slashes} -le 2 ]]; then
            deny "DELETE on '$endpoint' deletes the repository."
          fi ;;
      esac
      return 0 ;;
  esac
  return 0
}

# =============================================================================
# curl/wget straight to the API — no gh, token supplied by hand
# =============================================================================
check_http() {
  local t url='' method='' data='' upload=0 bstate
  for t in "$@"; do
    case "$t" in
      http://*|https://*)
        case "$t" in
          *api.github.com/*|*/api/v3/*) url="$t" ;;
        esac ;;
      -T|--upload-file) upload=1 ;;
    esac
  done
  [[ -z "$url" ]] && return 0

  # -X/--request is curl; --method= is wget.
  method=$(flag_value -X "$@") \
    || method=$(flag_value --request "$@") \
    || method=$(flag_value --method "$@") \
    || method=''
  if [[ -z "$method" ]]; then
    for t in "$@"; do
      case "$t" in -X?*) method="${t#-X}"; break ;; esac
    done
  fi
  data=$(flag_value -d "$@")     || data=$(flag_value --data "$@")     || data=$(flag_value --data-raw "$@")     || data=$(flag_value --data-binary "$@")     || data=$(flag_value --json "$@")     || data=''
  if [[ -z "$method" ]]; then
    if [[ $upload -eq 1 ]]; then method=PUT
    elif [[ -n "$data" ]]; then method=POST
    else method=GET; fi
  fi
  method=$(upper "$method")
  case "$method" in GET|HEAD) return 0 ;; esac

  if [[ -z "$data" ]]; then
    bstate='__none__'
  elif command -v jq >/dev/null 2>&1; then
    bstate=$(printf '%s' "$data" | jq -r '.branch // empty' 2>/dev/null)
    if [[ -z "$bstate" ]]; then
      # No branch key, or a body we could not parse (@file, - for stdin).
      case "$data" in
        *'"branch"'*) bstate='__unknown__' ;;
        @*|-) bstate='__unknown__' ;;
        *) bstate='__none__' ;;
      esac
    else
      bstate=$(normalize_branch "$bstate")
    fi
  else
    bstate='__unknown__'
  fi

  local endpoint base
  endpoint=$(normalize_endpoint "$url")
  base=''
  if [[ -n "$data" ]] && command -v jq >/dev/null 2>&1; then
    base=$(printf '%s' "$data" | jq -r '.base // empty' 2>/dev/null)
  fi
  check_api_write "$endpoint" "$method" "$bstate" "$base"
  return 0
}

# =============================================================================
# Policy for one `gh ...` invocation. Tokens are passed as "$@", starting at the
# token after `gh`.
# =============================================================================
check_gh() {
  local sub host
  sub=$(positional 1 "$@") || sub=''
  if host=$(flag_value --hostname "$@"); then
    if ! list_match "$host" "$ALLOWED_HOSTS"; then
      deny "GitHub host '$host' is not in the allowlist ($ALLOWED_HOSTS)."
    fi
  fi

  case "$sub" in
    pr)
      local verb; verb=$(positional 2 "$@") || verb=''
      case "$verb" in
        merge)
          [[ "$ALLOW_PR_MERGE" == "true" ]] && return 0
          deny "'gh pr merge' is a human decision. The agent opens the pull request; a reviewer merges it." ;;
        close|reopen|edit|ready|review) return 0 ;;
        *) return 0 ;;
      esac ;;
    repo)
      local verb; verb=$(positional 2 "$@") || verb=''
      case "$verb" in
        delete)
          deny "'gh repo delete' destroys a repository and is never an agent action." ;;
        sync)
          [[ "$CI_MODE" == "true" ]] && return 0
          deny "'gh repo sync' overwrites the default branch of the target (it can hard-reset a fork). Open a pull request instead." ;;
        archive|rename|transfer)
          [[ "$ALLOW_ACCESS_CHANGES" == "true" ]] && return 0
          deny "'gh repo $verb' changes repository lifecycle/ownership. Requires a human." ;;
        *) return 0 ;;
      esac ;;
    release)
      local verb; verb=$(positional 2 "$@") || verb=''
      case "$verb" in
        delete) deny "'gh release delete' removes a published artifact. Requires a human." ;;
        *) return 0 ;;
      esac ;;
    secret|variable)
      local verb; verb=$(positional 2 "$@") || verb=''
      case "$verb" in
        set|remove|delete)
          [[ "$ALLOW_SECRET_WRITES" == "true" ]] && return 0
          deny "'gh $sub $verb' writes a credential to a remote. Set repository secrets from a human session or CI, not from an agent." ;;
        *) return 0 ;;
      esac ;;
    alias)
      local verb; verb=$(positional 2 "$@") || verb=''
      case "$verb" in
        set|delete) deny "'gh alias $verb' can rename a blocked verb into an allowed one, which defeats this hook." ;;
        *) return 0 ;;
      esac ;;
    api)
      local endpoint method bstate base
      endpoint=$(positional 2 "$@") || return 0
      endpoint=$(normalize_endpoint "$endpoint")
      method=$(upper "$(api_method "$@")")
      case "$method" in GET|HEAD) return 0 ;; esac
      bstate=$(write_branch "$@") || bstate='__none__'
      base=$(field_value base "$@") || base=''
      check_api_write "$endpoint" "$method" "$bstate" "$base"
      return 0 ;;
    *) return 0 ;;
  esac
}

# The command word of a segment: leading VAR=value assignments and transparent
# prefixes (env, sudo, ...) are skipped, and the result is a basename so
# /bin/bash and bash compare equal.
command_word() {
  local t
  for t in "$@"; do
    case "$t" in
      [A-Za-z_]*=*) continue ;;
      env|command|builtin|exec|sudo|nohup|time|then|do|else|!) continue ;;
      *) printf '%s' "${t##*/}"; return 0 ;;
    esac
  done
  return 1
}

# Is this token list a `gh` invocation? Echoes the index of the token after gh.
gh_arg_start() {
  local i=0 t
  for t in "$@"; do
    i=$((i+1))
    case "$t" in
      *=*) case "$t" in [A-Za-z_]*=*) continue ;; esac ;;
    esac
    case "$t" in
      env|command|builtin|exec|sudo|nohup|time|then|do|else|!|xargs) continue ;;
      gh|*/gh) printf '%s' "$i"; return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# =============================================================================
# Walk the command: segments → tokens → policy, recursing into quoted commands
# =============================================================================
scan_command() {
  local cmd="$1" depth="$2"
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
  local seg idx
  for seg in ${segs[@]+"${segs[@]}"}; do
    case "$seg" in *gh*|*github*|*api/v3*) ;; *) continue ;; esac
    tokenize "$seg"
    local -a toks=(${TOKENS[@]+"${TOKENS[@]}"})
    # A quoted multi-word argument is only re-scanned when the command word is
    # an interpreter or exec wrapper — `bash -c 'gh pr merge 1'` must be
    # inspected, while `echo "gh pr merge is blocked"` must not be blocked for
    # quoting the policy it is describing.
    local -a nested=()
    local t cword
    cword=$(command_word ${toks[@]+"${toks[@]}"}) || cword=''
    case "$cword" in
      bash|sh|zsh|dash|ksh|eval|xargs|timeout|ssh|script|setsid|flock|nice|stdbuf|watch|parallel)
        for t in ${toks[@]+"${toks[@]}"}; do
          case "$t" in
            *[[:space:]]*) case "$t" in *gh*|*github*|*api/v3*) nested[${#nested[@]}]="$t" ;; esac ;;
          esac
        done ;;
    esac
    if idx=$(gh_arg_start ${toks[@]+"${toks[@]}"}); then
      local -a rest=("${toks[@]:idx}")
      check_gh ${rest[@]+"${rest[@]}"}
    fi
    case "$cword" in
      curl|wget) check_http ${toks[@]+"${toks[@]}"} ;;
    esac
    for t in ${nested[@]+"${nested[@]}"}; do
      scan_command "$t" $((depth+1))
    done
  done
  return 0
}

# Oversized commands are not parsed character by character (a 1MB heredoc would
# cost seconds). They get a conservative regex pass instead: the risk of a false
# positive on a 64KB gh command is preferable to skipping enforcement.
if [[ ${#command_str} -gt $MAX_PARSE_BYTES ]]; then
  if printf '%s' "$command_str" | grep -qE 'gh[[:space:]]+(pr[[:space:]]+merge|repo[[:space:]]+(delete|sync)|secret[[:space:]]+set|variable[[:space:]]+set|alias[[:space:]]+set)'; then
    deny "Blocked verb found in an oversized command (${#command_str} bytes, above GH_GUARD_MAX_PARSE_BYTES=$MAX_PARSE_BYTES) that is too large to parse precisely. Split the command."
  fi
  if printf '%s' "$command_str" | grep -qE 'gh[[:space:]]+api|api\.github\.com|/api/v3/' \
     && printf '%s' "$command_str" | grep -qE 'contents/|/merge|git/refs/'; then
    deny "gh api write found in an oversized command (${#command_str} bytes) that is too large to parse precisely. Split the command."
  fi
  exit 0
fi

scan_command "$command_str" 0
exit 0
