#!/bin/bash
# =============================================================================
# shell-parse.sh — canonical source of the shell-command parsing front end
# =============================================================================
# Parser version: 1
# Last updated: 2026-08-13
# Used by: hooks/git-guard.sh, hooks/gh-guard.sh (and their plugin/ copies)
# =============================================================================
# WHY THIS FILE IS COPIED INTO THE HOOKS INSTEAD OF BEING SOURCED BY THEM
#
# A hook is a single file that people copy into `~/.claude/hooks/` and name in
# `settings.json`. Making a security control depend on a second file at runtime
# creates a failure mode with no good branch:
#
#   * `source lib/shell-parse.sh` fails and we continue  → the guard silently
#     enforces nothing (every helper is undefined, every check decides "no").
#   * `source` fails and we exit 2                        → every Bash command in
#     the session is blocked, and the operator removes the hook within a minute.
#
# Both are worse than duplication. So this file is the single source of truth at
# *edit* time and `scripts/sync-parser.sh` copies the marked region below into
# each hook between the same two sentinel lines. `tests/test_shared_parser.sh`
# fails if any copy has drifted, which is the part that makes the arrangement
# hold: before this file existed the two hooks carried the same 150-line
# `strip_heredocs` by hand, and the plugin's copy of one hook silently sat a
# version behind while the suites reported green
# (docs/test-evidence.md §7c).
#
# Regenerate after editing this file:
#
#   bash scripts/sync-parser.sh          # rewrite the hooks + plugin copies
#   bash scripts/sync-parser.sh --check  # exit 1 if anything is out of date
#
# Nothing in the region below may reference a hook-specific variable: it is
# shared code, and both hooks' policies are built on top of it, not inside it.
# bash 3.2 is a target (macOS ships it), so: no associative arrays, no `mapfile`,
# array append is `arr[${#arr[@]}]=`, and every expansion of a possibly-empty
# array is written `${arr[@]+"${arr[@]}"}` to survive `set -u`.
# =============================================================================

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
