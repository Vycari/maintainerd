#!/usr/bin/env bash
#
# repo-ops — shared command scanner for the PreToolUse Bash guards.
#
# Both guards ask the same question of a Bash payload: "which `gh pr create` / `gh pr edit`
# invocations does this command actually RUN, and what is the text of each one?" Answering that
# with regex alternatives ("also match `command gh`, also match `/usr/bin/gh`, also match…")
# needs a new pattern for every wrapper anyone thinks of, and the design this plugin follows
# says a guard that needs a fifth pattern is a design change, not a fifth pattern. So the
# answer here is structural instead: mask heredoc bodies, split the payload into SIMPLE
# COMMANDS, and for each one resolve the executable's basename after stripping the wrapper
# words that do not change which program runs.
#
# Sourced, not executed. Defines:
#   mask_all_heredocs <command>            -> the command with heredoc BODIES redacted in place
#   split_simple_commands <masked>         -> lines of "<offset> <length>" into that string
#   gh_pr_subcommand <segment>             -> "create" | "edit" | "" (empty = not a gh pr cmd)
#
# Offsets are byte-for-byte valid in the ORIGINAL command too: masking only ever replaces a
# body character with `x`, never inserts or drops one, so a segment can be sliced out of the
# masked text (to decide WHAT it is) and out of the original text (to read what it SAYS).
#
# bash 3.2 (macOS /bin/bash) compatible: no associative arrays, no `${var^^}`, no `mapfile`.

# ------------------------------------------------------------------------ mask heredoc payloads
# A heredoc's body is data, not a command: `cat > deploy.sh <<'EOF'` followed by a line reading
# `gh pr create --body "..."` writes that text into a file, it does not invoke gh. Redact every
# heredoc body IN PLACE — same length, same newlines, every other character replaced by `x` —
# leaving the opening line (including `<<-`, the quotes around the tag) and the terminator line
# untouched so offsets past the heredoc are unchanged.
#
# Documented limit: heredoc openers are found by scanning each command line for `<<[-] TAG`
# without tracking quoting, so a literal "<<TAG" inside a quoted string is misread as an opener.
# The failure direction is over-masking (text becomes inert), which can only ever cost a missed
# check, never a false denial.
mask_all_heredocs() {
  local s="$1"
  local out="" rest="$s" line nextrest last=0
  local pending_tags="" pending_strips=""   # newline-separated queues, first = innermost-open
  local scratch opener tag strip trimmed filler cur_tag cur_strip
  while :; do
    case "$rest" in
      *$'\n'*) line="${rest%%$'\n'*}"; nextrest="${rest#*$'\n'}"; last=0 ;;
      *) line="$rest"; nextrest=""; last=1 ;;
    esac

    if [ -n "$pending_tags" ]; then
      cur_tag="${pending_tags%%$'\n'*}"
      cur_strip="${pending_strips%%$'\n'*}"
      trimmed="$line"
      if [ "$cur_strip" = "1" ]; then
        while :; do
          case "$trimmed" in
            $'\t'*) trimmed="${trimmed#$'\t'}" ;;
            *) break ;;
          esac
        done
      fi
      if [ "$trimmed" = "$cur_tag" ]; then
        # Terminator: kept verbatim, and this heredoc is closed.
        out="$out$line"
        case "$pending_tags" in
          *$'\n'*) pending_tags="${pending_tags#*$'\n'}"; pending_strips="${pending_strips#*$'\n'}" ;;
          *) pending_tags=""; pending_strips="" ;;
        esac
      else
        filler=$(printf '%*s' "${#line}" '' | tr ' ' 'x')
        out="$out$filler"
      fi
    else
      out="$out$line"
      # Find this line's heredoc openers, in order. `<<<` is a here-string, not a heredoc, so
      # neutralize those first rather than letting the opener pattern match inside one.
      scratch=$(printf '%s' "$line" | sed 's/<<</@@@/g')
      while :; do
        opener=$(printf '%s' "$scratch" | grep -Eo -- '<<-?[[:space:]]*("[^"]*"|'"'"'[^'"'"']*'"'"'|[A-Za-z_][A-Za-z0-9_]*)' | head -1 || true)
        [ -n "$opener" ] || break
        scratch="${scratch#*"$opener"}"
        strip=0
        tag="${opener#<<}"
        case "$tag" in '-'*) strip=1; tag="${tag#-}" ;; esac
        while :; do
          case "$tag" in
            ' '*) tag="${tag# }" ;;
            $'\t'*) tag="${tag#$'\t'}" ;;
            *) break ;;
          esac
        done
        case "$tag" in
          "'"*) tag="${tag#\'}"; tag="${tag%\'}" ;;
          '"'*) tag="${tag#\"}"; tag="${tag%\"}" ;;
        esac
        [ -n "$tag" ] || continue
        pending_tags="$pending_tags$tag"$'\n'
        pending_strips="$pending_strips$strip"$'\n'
      done
    fi

    if [ "$last" -eq 1 ]; then
      printf '%s' "$out"
      return
    fi
    out="$out"$'\n'
    rest="$nextrest"
  done
}

# ------------------------------------------------------------------- split into simple commands
# Emits one "<offset> <length>" line per simple command, splitting on `;`, `&` (so `&&` too),
# `|` (so `||` too), newlines, and subshell parentheses — but ONLY where they are not inside
# single quotes, double quotes, backticks, or a `$( … )` command substitution. That last
# exclusion is deliberate: `--body "$(cat <<'EOF' … EOF)"` is one command's argument, and the
# heredoc's newlines inside it must not chop the invocation in half.
#
# Documented limit: a `gh pr create` written INSIDE a command substitution is part of the
# enclosing simple command rather than one of its own, so it is checked only if the enclosing
# command is itself a `gh pr create`/`edit`.
split_simple_commands() {
  local s="$1"
  local len=${#s}
  local i=0 start=0 depth=0 c nc q="" out=""
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
      if [ "$c" = "$q" ]; then q=""; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'"|'"'|'`') q="$c"; i=$((i + 1)) ;;
      '\') i=$((i + 2)) ;;
      '$')
        nc="${s:$((i + 1)):1}"
        if [ "$nc" = '(' ]; then depth=$((depth + 1)); i=$((i + 2)); else i=$((i + 1)); fi
        ;;
      '(')
        if [ "$depth" -gt 0 ]; then
          depth=$((depth + 1)); i=$((i + 1))
        else
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        fi
        ;;
      ')')
        if [ "$depth" -gt 0 ]; then
          depth=$((depth - 1)); i=$((i + 1))
        else
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        fi
        ;;
      ';'|'&'|'|'|$'\n')
        if [ "$depth" -gt 0 ]; then
          i=$((i + 1))
        else
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        fi
        ;;
      *) i=$((i + 1)) ;;
    esac
  done
  out="$out$start $((len - start))"$'\n'
  printf '%s' "$out"
}

# --------------------------------------------------------------- is this simple command `gh pr`?
# Prints "create" or "edit" when the segment's executable resolves to gh and its first two
# arguments are `pr create`/`pr edit`; prints nothing otherwise. The executable is resolved by
# BASENAME after dropping the prefix words that do not change which program ends up running:
# leading `VAR=value` assignments, `command [-p]`, `env [-i] [VAR=value…]`, and `exec`. So
# `command gh`, `env GH_TOKEN=x gh`, `/usr/bin/gh`, `exec gh` and a bare `gh` all resolve alike.
#
# Documented limit: wrappers that run gh as *data* rather than as their own argv[1] —
# `sh -c "gh pr create …"`, `xargs gh`, `find -exec gh` — still resolve to sh/xargs/find and are
# not recognized.
gh_pr_subcommand() {
  local head="${1:0:512}"
  local restore_glob=0
  case "$-" in *f*) restore_glob=1 ;; esac
  set -f
  local words
  # shellcheck disable=SC2206
  words=($head)
  [ "$restore_glob" -eq 1 ] || set +f
  local n=${#words[@]} i=0 w exe prev=""
  while [ "$i" -lt "$n" ]; do
    w="${words[$i]}"
    case "$w" in
      [a-zA-Z_]*=*) i=$((i + 1)); prev="assign"; continue ;;
      command|exec|env) prev="$w"; i=$((i + 1)); continue ;;
      -p) if [ "$prev" = "command" ]; then i=$((i + 1)); continue; fi; break ;;
      -i) if [ "$prev" = "env" ]; then i=$((i + 1)); continue; fi; break ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  exe="${words[$i]}"
  case "$exe" in
    "'"*"'") exe="${exe#\'}"; exe="${exe%\'}" ;;
    '"'*'"') exe="${exe#\"}"; exe="${exe%\"}" ;;
  esac
  exe="${exe##*/}"
  [ "$exe" = "gh" ] || return 0
  [ $((i + 2)) -lt "$n" ] || return 0
  local sub1="${words[$((i + 1))]}" sub2="${words[$((i + 2))]}"
  sub1="${sub1//\"/}"; sub1="${sub1//\'/}"
  sub2="${sub2//\"/}"; sub2="${sub2//\'/}"
  [ "$sub1" = "pr" ] || return 0
  case "$sub2" in
    create|edit) printf '%s' "$sub2" ;;
  esac
  return 0
}
