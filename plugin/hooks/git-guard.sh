#!/bin/bash
# =============================================================================
# Git Guard — Enterprise Git Security Hook for Claude Code
# =============================================================================
# Hook version: 1.1.0
# Last updated: 2026-08-13
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 4+, jq (preferred), git, sed, grep
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-05-28) — initial release: allowlist, branch protection,
#                         force-push, destructive op prevention
#   1.1.0 (2026-08-13) — push checks run per command segment. They previously
#                         extracted the remote and branch with `echo | awk`,
#                         which reads a field per LINE, so any newline in the
#                         command turned the branch name into newline-joined
#                         junk and branch protection silently passed.
# =============================================================================
# Comprehensive git protection that allows enterprise workflows while blocking
# data exfiltration, destructive operations, and policy violations.
#
# Hook event: PreToolUse (matcher: Bash)
# Inspects git commands and enforces:
#   1. Remote URL allowlist (only push to enterprise domains)
#   2. Force-push prevention (--force / --force-with-lease)
#   3. Branch protection (no direct push to main/master/release/*)
#   4. Remote modification control (add/set-url only to allowed domains)
#   5. Destructive operation prevention (reset --hard, clean -fd, checkout --force)
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
#   GIT_GUARD_CI_MODE            — "true" to relax branch protection for CI/CD
#   GIT_GUARD_DISABLED           — "true" to bypass all checks (emergency)
#
# Exit codes:
#   0 = allow
#   2 = block (stderr shown to Claude)
# =============================================================================

set -u
input=$(cat)

# --- Parse input ---
if command -v jq >/dev/null 2>&1; then
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
  tool_name=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  command_str=$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

# Only inspect Bash tool
[[ "$tool_name" != "Bash" ]] && exit 0

# --- Configuration ---
ALLOWED_DOMAINS="${GIT_GUARD_ALLOWED_DOMAINS:-github.com,gitlab.com,bitbucket.org}"
PROTECTED_BRANCHES="${GIT_GUARD_PROTECTED_BRANCHES:-main,master,release/*,production}"
ALLOW_FORCE="${GIT_GUARD_ALLOW_FORCE_PUSH:-false}"
MAX_FILE_KB="${GIT_GUARD_MAX_FILE_SIZE_KB:-10240}"
CI_MODE="${GIT_GUARD_CI_MODE:-false}"
DISABLED="${GIT_GUARD_DISABLED:-false}"

[[ "$DISABLED" == "true" ]] && exit 0

# --- Helper: check if URL domain is in allowlist ---
url_allowed() {
  local url="$1"
  local domain=""

  # Extract domain from various URL formats
  if echo "$url" | grep -qE '^https?://'; then
    domain=$(echo "$url" | sed -E 's|https?://([^/:@]+).*|\1|')
  elif echo "$url" | grep -qE '^git@'; then
    domain=$(echo "$url" | sed -E 's|git@([^:]+):.*|\1|')
  elif echo "$url" | grep -qE '^ssh://'; then
    domain=$(echo "$url" | sed -E 's|ssh://([^@]+@)?([^/:]+).*|\2|')
  else
    # Unknown format — block by default
    return 1
  fi

  # Check against allowlist
  IFS=',' read -ra domains <<< "$ALLOWED_DOMAINS"
  for allowed in "${domains[@]}"; do
    allowed=$(echo "$allowed" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Support wildcard: *.example.com matches sub.example.com
    if [[ "$allowed" == \** ]]; then
      local suffix="${allowed#\*}"
      if [[ "$domain" == *"$suffix" ]]; then
        return 0
      fi
    elif [[ "$domain" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: check if branch matches protected pattern ---
branch_protected() {
  local branch="$1"
  IFS=',' read -ra branches <<< "$PROTECTED_BRANCHES"
  for pattern in "${branches[@]}"; do
    pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Support glob: release/* matches release/v1.0
    if [[ "$branch" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: get remote URL from name ---
get_remote_url() {
  local remote_name="$1"
  local cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  if [[ -n "$cwd" ]] && [[ -d "$cwd/.git" || -f "$cwd/.git" ]]; then
    git -C "$cwd" remote get-url "$remote_name" 2>/dev/null
  else
    git remote get-url "$remote_name" 2>/dev/null
  fi
}

# --- Deny helper ---
deny() {
  printf 'GIT GUARD: %s\nCommand: %s\n' "$1" "$command_str" >&2
  exit 2
}

# --- Helper: blank the inside of quoted spans -------------------------------
# Every check below matches on raw text, so a `| bash` written inside an
# argument would read as a real pipe into a shell. Replacing quoted contents
# with a filler of the same length keeps offsets and the quotes themselves
# while making the contents unmatchable.
blank_quoted() {
  # Two statements on purpose: bash expands every initializer in a single
  # `local a=.. b=..` before binding any of them, so `local s="$1" n=${#s}`
  # dies on "s: unbound variable" under `set -u`. That failure is silent and
  # fails OPEN — the caller just sees an empty string and decides nothing runs
  # a shell — and it only reproduces on the deployment platform's bash.
  local s="$1"
  local n=${#s}
  local i=0 q='' c='' out=''
  while [[ $i -lt $n ]]; do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$q" == '"' && "$c" == '\' ]]; then out="$out.."; i=$((i+2)); continue; fi
      if [[ "$c" == "$q" ]]; then q=''; out="$out$c"; else out="$out."; fi
      i=$((i+1)); continue
    fi
    case "$c" in
      '\') out="$out$c${s:i+1:1}"; i=$((i+2)); continue ;;
      "'"|'"') q="$c"; out="$out$c"; i=$((i+1)); continue ;;
    esac
    out="$out$c"; i=$((i+1))
  done
  printf '%s' "$out"
}

# --- Heredoc bodies are data, not commands ---------------------------------
# Every check here matches line by line, so before v1.1.0 each line of a
# heredoc body was inspected as if it were a command: writing
# `cat > policy.md <<'EOF' ... EOF` whose prose shows `git reset --hard` as an
# example was denied as an attempt to run it. A denial nobody believes is how a
# guard ends up switched off, so this is a security bug, not a cosmetic one.
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
# `echo $((1<<SHIFT))` then `git push origin main` would be a silent bypass.
# Mistaking a heredoc for plain text only risks a false positive, which is
# visible. Kept deliberately identical to the routine in gh-guard.sh; the two
# hooks ship independently, so neither may depend on the other being installed.
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
# Skipping this would be a regression: v1.0.0 inspected body lines as commands,
# so it caught `bash <<EOF ... git reset --hard ... EOF` by accident.
opener_runs_shell() {
  local bare word
  bare="$(blank_quoted "$1")"
  # Command word, skipping VAR=val assignments and wrapper prefixes so that
  # `sudo bash <<EOF` is seen as bash while `sudo tee f <<EOF` is seen as tee.
  word=$(printf '%s' "$bare" \
    | sed -E 's/^[[:space:]]*//; s/^(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|sudo|doas|env|command|exec|nohup)[[:space:]]+)*//' \
    | awk '{print $1}')
  word="${word##*/}"
  # Same list as gh-guard.sh. It errs toward "this runs a shell": guessing wrong
  # in that direction costs a visible false positive, guessing wrong the other
  # way lets a script through unread.
  case "$word" in
    bash|sh|zsh|dash|ksh|eval|xargs|timeout|script|setsid|flock|nice|stdbuf)
      return 0 ;;
  esac
  # A pipe into a shell makes the producer's output a script. Matched on the
  # blanked text so a quoted "build | bash" argument is not read as a pipe.
  if printf '%s' "$bare" \
    | grep -qE '\|[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*([^[:space:]]*/)?(bash|sh|zsh|dash|ksh)([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

# =============================================================================
# CHECK 1: git remote add / set-url — URL must be in allowlist
# =============================================================================
scan_command() {
  local cmd="$1" depth="$2"
  # A body fed to a shell is a script and gets re-scanned. The cap stops a
  # crafted nest from spinning; three levels is far past anything real.
  [[ $depth -gt 3 ]] && return 0

  # Pull heredoc bodies out before anything matches line by line, and copy the
  # results into locals immediately — the recursive calls below overwrite the
  # globals that strip_heredocs sets.
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

  # Normalize whitespace (per line — newlines survive, and every check below is
  # anchored at a line start or a separator)
  local norm
  norm=$(printf '%s' "$text" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //')

  # Check if this is a git command at all
  if ! echo "$norm" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]'; then
    return 0
  fi

  local url push_seg push_args remote_name branch_name remote_url target_branch

# =============================================================================
# CHECK 1: git remote add / set-url — URL must be in allowlist
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?remote[[:space:]]+(add|set-url)[[:space:]]'; then
  # Extract URL (last argument that looks like a URL)
  url=$(echo "$norm" | grep -oE '(https?://[^ ]+|git@[^ ]+|ssh://[^ ]+)' | tail -1)
  if [[ -n "$url" ]]; then
    if ! url_allowed "$url"; then
      deny "Remote URL not in enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS. Blocked URL: $url"
    fi
  fi
  # If no URL found in command, allow (might be a rename or other subcommand)
fi

# =============================================================================
# CHECK 2: git remote rename / rm — block (prevents circumventing allowlist)
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?remote[[:space:]]+(rename|rm|remove)[[:space:]]'; then
  deny "Modifying or removing git remotes is restricted. Contact your team lead to change remote configuration."
fi

# =============================================================================
# CHECK 3: git push — multiple checks
# =============================================================================
# One push per segment, each checked against its own arguments. Extracting the
# fields from the whole command instead is what made this check fail open: the
# `echo | sed | awk` pipeline below runs once per LINE, so on a two-line command
# awk emitted one field per line and branch_name became "/repo\nmain", which
# matches no protected pattern. `cd repo && git push origin main` was blocked
# while the same two commands separated by a newline were not.
while IFS= read -r push_seg; do
  [[ -z "$push_seg" ]] && continue

  # 3a. Force push check. Scoped to this segment so that a -f belonging to some
  # other command (`git push origin feat && rm -f /tmp/x`) is not read as one.
  if [[ "$ALLOW_FORCE" != "true" ]]; then
    # `-f` at the very end of the command matters as much as `-f` mid-command,
    # so the short form anchors on end-of-string as well as on whitespace.
    if printf '%s' "$push_seg" | grep -qE -e '--force|--force-with-lease|-f([[:space:]]|$)'; then
      deny "Force push is forbidden by enterprise policy. Use a regular push or create a new branch."
    fi
  fi

  # 3b. Extract remote name and branch from push command
  # Pattern: git push [options] <remote> [<branch>]
  push_args=$(printf '%s' "$push_seg" | sed -E 's/.*git[[:space:]]([^;&|]*[[:space:]])?push[[:space:]]*//')
  # Remove flags
  push_args=$(printf '%s' "$push_args" | sed -E 's/--[a-z-]+[[:space:]]*//g; s/-[a-z][[:space:]]*//g' | sed 's/^[[:space:]]*//')

  remote_name=$(printf '%s' "$push_args" | awk '{print $1}')
  branch_name=$(printf '%s' "$push_args" | awk '{print $2}')

  # 3c. Check remote URL is in allowlist
  if [[ -n "$remote_name" ]]; then
    remote_url=$(get_remote_url "$remote_name")
    if [[ -n "$remote_url" ]]; then
      if ! url_allowed "$remote_url"; then
        deny "Push target '$remote_name' ($remote_url) is not in the enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS"
      fi
    fi
    # If we can't resolve the URL (no git repo context), allow — the push will fail anyway
  fi

  # 3d. Branch protection (skip in CI mode)
  if [[ "$CI_MODE" != "true" ]] && [[ -n "$branch_name" ]]; then
    # Handle refspec format (local:remote)
    target_branch="${branch_name#*:}"
    [[ -z "$target_branch" ]] && target_branch="$branch_name"
    # A fully qualified ref is the same destination written differently, so
    # `git push origin refs/heads/main` must not read as a branch named
    # "refs/heads/main". gh-guard.sh normalises the same way.
    target_branch="${target_branch#refs/heads/}"

    if branch_protected "$target_branch"; then
      deny "Direct push to protected branch '$target_branch' is forbidden. Use a pull request instead. Protected branches: $PROTECTED_BRANCHES"
    fi
  fi
done < <(printf '%s\n' "$norm" \
  | grep -oE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?push([[:space:]][^;&|]*|$)')

# =============================================================================
# CHECK 4: git reset --hard — destructive
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?reset[[:space:]]+--hard'; then
  deny "git reset --hard is forbidden. Use 'git reset --soft' or 'git revert' for non-destructive alternatives."
fi

# =============================================================================
# CHECK 5: git clean -f/-fd — destructive (removes untracked files)
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?clean[[:space:]]+-[a-z]*f'; then
  deny "git clean -f is forbidden. It permanently removes untracked files. Use 'git clean -n' to preview first."
fi

# =============================================================================
# CHECK 6: git checkout/switch to detached HEAD with force — can lose work
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?(checkout|switch)[[:space:]].*--force'; then
  deny "Forced checkout/switch can discard uncommitted changes. Remove --force or commit your changes first."
fi

  return 0
}

# =============================================================================
# All checks passed
# =============================================================================
scan_command "$command_str" 0
exit 0
