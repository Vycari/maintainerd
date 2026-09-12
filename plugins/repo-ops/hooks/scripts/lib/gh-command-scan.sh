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
  local head="${1:0:2048}"
  local words=() off len
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    words[${#words[@]}]="${head:$off:$len}"
  done <<ARGV
$(argv_spans "$head")
ARGV
  local n=${#words[@]} i=0 w exe prev=""
  while [ "$i" -lt "$n" ]; do
    w="${words[$i]}"
    case "$w" in
      # Shell keywords and grouping that PRECEDE a command without being it: `if gh pr create;
      # then …`, `! gh pr create`, `while gh pr create …`, `{ gh pr create …; }`, `time gh …`.
      if|then|else|elif|while|until|do|'!'|'{'|'(') prev="keyword"; i=$((i + 1)); continue ;;
      # `time` is a keyword that takes its own `-p` (POSIX output format) before the command.
      time) prev="time"; i=$((i + 1)); continue ;;
      # A leading VAR=value assignment. Quote-aware word splitting means `FOO="a b" gh …` is ONE
      # assignment word, so the `gh` after it is still found.
      [a-zA-Z_]*=*) prev="assign"; i=$((i + 1)); continue ;;
      command|exec|env) prev="$w"; i=$((i + 1)); continue ;;
      -p)
        case "$prev" in
          command|time) i=$((i + 1)); continue ;;
        esac
        break ;;
      -i) if [ "$prev" = "env" ]; then i=$((i + 1)); continue; fi; break ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  exe=$(unquote_word "${words[$i]}")
  exe="${exe##*/}"
  [ "$exe" = "gh" ] || return 0
  [ $((i + 2)) -lt "$n" ] || return 0
  local sub1 sub2
  sub1=$(unquote_word "${words[$((i + 1))]}")
  sub2=$(unquote_word "${words[$((i + 2))]}")
  [ "$sub1" = "pr" ] || return 0
  case "$sub2" in
    create|edit) printf '%s' "$sub2" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------- split a command into argv
# Emits one "<offset> <length>" line per WORD of a simple command, relative to the string passed
# in. Words are separated by unquoted whitespace; single quotes, double quotes, backticks and
# `$( … )` hold a word together, so `--body "use --draft here"` is two words, not four, and the
# body's prose can never be read as a flag of its own.
argv_spans() {
  local s="$1"
  local len=${#s}
  local i=0 start c nc q depth out=""
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    case "$c" in
      ' '|$'\t'|$'\n'|$'\r') i=$((i + 1)); continue ;;
    esac
    start=$i
    q=""
    depth=0
    while [ "$i" -lt "$len" ]; do
      c="${s:$i:1}"
      if [ -n "$q" ]; then
        if [ "$q" = '"' ] && [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        if [ "$c" = "$q" ]; then q=""; fi
        i=$((i + 1)); continue
      fi
      case "$c" in
        "'"|'"'|'`') q="$c"; i=$((i + 1)); continue ;;
        '\') i=$((i + 2)); continue ;;
        '$')
          nc="${s:$((i + 1)):1}"
          if [ "$nc" = '(' ]; then depth=$((depth + 1)); i=$((i + 2)); else i=$((i + 1)); fi
          continue ;;
        '(') if [ "$depth" -gt 0 ]; then depth=$((depth + 1)); fi; i=$((i + 1)); continue ;;
        ')') if [ "$depth" -gt 0 ]; then depth=$((depth - 1)); fi; i=$((i + 1)); continue ;;
        ' '|$'\t'|$'\n'|$'\r')
          if [ "$depth" -gt 0 ]; then i=$((i + 1)); continue; fi
          break ;;
        *) i=$((i + 1)); continue ;;
      esac
    done
    out="$out$start $((i - start))"$'\n'
  done
  printf '%s' "$out"
}

# unquote_word <raw word> -> the word with one layer of surrounding/inline quoting removed.
# Enough for comparing a flag or a label value; not a general shell unquoter.
unquote_word() {
  local w="$1"
  w="${w//\"/}"
  w="${w//\'/}"
  printf '%s' "$w"
}

# ------------------------------------------------------------------ short-option (-abc) parsing
# Parses ONE raw argv word that is a short-option cluster (`-d`, `-dl`, `-b"text"`, `-Fbody.md`,
# `-b=text`) the way gh's flag library actually reads it, and prints one line per flag found:
#
#   bool <char>                 a boolean shorthand (gh pr create/edit: -d draft, -f fill, -w web)
#   value <char> <offset>       a value-taking shorthand; <offset> is where its value starts
#                               INSIDE this word, or -1 when the value is the next argv word
#
# The key rule — and the one a naive "does the word end in b?" or "does the word contain d?" test
# gets wrong — is that a value-taking shorthand CONSUMES THE REST OF THE WORD. In `-tDraftTitle`
# the `d` belongs to the title, not to `--draft`; in `-db"…"` the `d` is a real boolean and `b`
# takes the quoted remainder. So parsing stops at the first value-taking character.
short_opt_parse() {
  # Two `local` statements, not one: every word on a `local` line is expanded before any of them
  # is assigned, so `local w="$1" len=${#w}` would measure the OLD w (the same trap noted above).
  local w="$1"
  local len=${#w} j=1 c rest
  case "$w" in
    -[!-]*) : ;;
    *) return 0 ;;      # not a short cluster (a long --flag, a bare "-", or not a flag at all)
  esac
  while [ "$j" -lt "$len" ]; do
    c="${w:$j:1}"
    case "$c" in
      [a-zA-Z]) : ;;
      *) return 0 ;;    # a quote, `=` or punctuation where a flag letter was expected
    esac
    case "$c" in
      d|f|w) printf 'bool %s\n' "$c"; j=$((j + 1)); continue ;;
    esac
    rest="${w:$((j + 1))}"
    case "$rest" in
      '') printf 'value %s -1\n' "$c" ;;
      '='*) printf 'value %s %s\n' "$c" "$((j + 2))" ;;
      *) printf 'value %s %s\n' "$c" "$((j + 1))" ;;
    esac
    return 0
  done
  return 0
}
