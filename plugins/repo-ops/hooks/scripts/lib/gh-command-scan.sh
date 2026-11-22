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
#   gh_exec_words <segment>                -> "<offset> <length>" per argv word, starting AT `gh` (empty = not gh)
#   gh_command_words <segment>             -> the unquoted words after `gh`, one per line (empty = not gh)
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
# Heredoc openers are found by a quote-aware scan (_hd_scan_line), not a pattern over the raw
# line: a `<<TAG` inside single quotes, double quotes, backticks, a `#` comment or `$(( … ))`
# arithmetic is text, not an opener. A quoted `<<EOF` read as an opener would redact every line
# after it up to a terminator that never comes, hiding a real command from the guards. Quote
# state carries across lines (a string can span them) and resets inside `$( … )`, where a real
# heredoc may legitimately live (`--body "$(cat <<'EOF' … EOF)"`). Anything the scan cannot
# classify is treated as NOT an opener, so the failure direction is a body left unmasked (its
# text is then scanned as commands), never a command masked away.
#
# Documented limit: a heredoc whose opener sits inside backticks is not recognized.
# _hd_scan_line <line>
# Reads/updates the globals _HD_STACK (quote/nesting contexts, innermost LAST; "B" is the base)
# and appends the line's real heredoc openers to _HD_TAGS / _HD_STRIPS (newline-terminated).
# Contexts: B base shell, C `$( … )`, p plain `( … )`, A `$(( … ))`/`(( … ))` arithmetic,
# S single quote, E ANSI-C `$' … '` (a backslash escapes, so `\'` does not close it),
# D double quote, K backtick (inert), P parameter expansion `${ … }`, bare or inside `"…"` (a `#` in
# it is an operator, as in `${#x}` or `${x#pat}`, never a comment, and a `<<` in it is never an
# opener).
_hd_scan_line() {
  local line="$1"
  local len=${#line} i=0 c nc top prev=" " j tag strip q
  while [ "$i" -lt "$len" ]; do
    c="${line:$i:1}"
    top="${_HD_STACK: -1}"
    case "$top" in
      S)
        [ "$c" = "'" ] && _HD_STACK="${_HD_STACK%?}"
        i=$((i + 1)); prev="$c"; continue ;;
      E)
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        [ "$c" = "'" ] && _HD_STACK="${_HD_STACK%?}"
        i=$((i + 1)); prev="$c"; continue ;;
      P)
        case "$c" in
          '}') _HD_STACK="${_HD_STACK%?}" ;;
          "'") _HD_STACK="${_HD_STACK}S" ;;
          '"') _HD_STACK="${_HD_STACK}D" ;;
          '`') _HD_STACK="${_HD_STACK}K" ;;
          '\') i=$((i + 2)); continue ;;
          '$')
            if [ "${line:$((i + 1)):2}" = "((" ]; then _HD_STACK="${_HD_STACK}AA"; i=$((i + 3)); continue
            elif [ "${line:$((i + 1)):1}" = "(" ]; then _HD_STACK="${_HD_STACK}C"; i=$((i + 2)); prev="("; continue
            elif [ "${line:$((i + 1)):1}" = "{" ]; then _HD_STACK="${_HD_STACK}P"; i=$((i + 2)); continue
            elif [ "${line:$((i + 1)):1}" = "'" ]; then _HD_STACK="${_HD_STACK}E"; i=$((i + 2)); continue
            fi ;;
        esac
        i=$((i + 1)); prev="$c"; continue ;;
      K)
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        [ "$c" = '`' ] && _HD_STACK="${_HD_STACK%?}"
        i=$((i + 1)); prev="$c"; continue ;;
      D)
        case "$c" in
          '\') i=$((i + 2)); continue ;;
          '"') _HD_STACK="${_HD_STACK%?}" ;;
          '`') _HD_STACK="${_HD_STACK}K" ;;
          '$')
            if [ "${line:$((i + 1)):2}" = "((" ]; then _HD_STACK="${_HD_STACK}AA"; i=$((i + 3)); prev="("; continue
            elif [ "${line:$((i + 1)):1}" = "(" ]; then _HD_STACK="${_HD_STACK}C"; i=$((i + 2)); prev="("; continue
            # `${ … }` inside double quotes opens its own context: its quotes nest, so the `"` in
            # `"${x:-"<<EOF"}"` opens an inner string rather than closing the outer one.
            elif [ "${line:$((i + 1)):1}" = "{" ]; then _HD_STACK="${_HD_STACK}P"; i=$((i + 2)); continue
            fi ;;
        esac
        i=$((i + 1)); prev="$c"; continue ;;
      A)
        case "$c" in
          '(') _HD_STACK="${_HD_STACK}A" ;;
          ')') _HD_STACK="${_HD_STACK%?}" ;;
        esac
        i=$((i + 1)); prev="$c"; continue ;;
    esac
    # Code context: B, C or p.
    case "$c" in
      "'") _HD_STACK="${_HD_STACK}S" ;;
      '"') _HD_STACK="${_HD_STACK}D" ;;
      '`') _HD_STACK="${_HD_STACK}K" ;;
      '\') i=$((i + 2)); prev="x"; continue ;;
      '#')
        case "$prev" in
          ' '|$'\t'|';'|'&'|'|'|'('|'{') return 0 ;;     # a comment runs to the end of the line
        esac ;;
      '$')
        if [ "${line:$((i + 1)):2}" = "((" ]; then _HD_STACK="${_HD_STACK}AA"; i=$((i + 3)); prev="("; continue
        elif [ "${line:$((i + 1)):1}" = "(" ]; then _HD_STACK="${_HD_STACK}C"; i=$((i + 2)); prev="("; continue
        elif [ "${line:$((i + 1)):1}" = "{" ]; then _HD_STACK="${_HD_STACK}P"; i=$((i + 2)); prev="x"; continue
        elif [ "${line:$((i + 1)):1}" = "'" ]; then _HD_STACK="${_HD_STACK}E"; i=$((i + 2)); prev="x"; continue
        fi
        i=$((i + 1)); prev="x"; continue ;;       # `$#`, `$$`: the `#` after `$` is a name, not a comment
      '(')
        if [ "${line:$((i + 1)):1}" = "(" ]; then _HD_STACK="${_HD_STACK}AA"; i=$((i + 2)); prev="("; continue; fi
        _HD_STACK="${_HD_STACK}p" ;;
      ')') [ "$top" != "B" ] && _HD_STACK="${_HD_STACK%?}" ;;
      '<')
        if [ "${line:$i:3}" = "<<<" ]; then i=$((i + 3)); prev="<"; continue; fi
        if [ "${line:$i:2}" = "<<" ]; then
          j=$((i + 2)); strip=0
          if [ "${line:$j:1}" = "-" ]; then strip=1; j=$((j + 1)); fi
          while :; do
            case "${line:$j:1}" in ' '|$'\t') j=$((j + 1)) ;; *) break ;; esac
          done
          tag=""
          nc="${line:$j:1}"
          case "$nc" in
            "'"|'"')
              q="${line:$((j + 1))}"
              case "$q" in
                *"$nc"*) q="${q%%"$nc"*}"; tag="$q"; j=$((j + ${#q} + 2)) ;;
              esac ;;
            *)
              [ "$nc" = '\' ] && j=$((j + 1))
              while :; do
                nc="${line:$j:1}"
                case "$nc" in
                  [A-Za-z0-9_]) if [ -z "$tag" ]; then case "$nc" in [0-9]) break ;; esac; fi
                    tag="$tag$nc"; j=$((j + 1)) ;;
                  *) break ;;
                esac
              done ;;
          esac
          if [ -n "$tag" ]; then
            _HD_TAGS="$_HD_TAGS$tag"$'\n'
            _HD_STRIPS="$_HD_STRIPS$strip"$'\n'
            i=$j; prev="x"; continue
          fi
          i=$((i + 2)); prev="<"; continue
        fi ;;
    esac
    i=$((i + 1)); prev="$c"
  done
}

mask_all_heredocs() {
  local s="$1"
  local out="" rest="$s" line nextrest last=0
  local pending_tags="" pending_strips=""   # newline-separated queues, first = innermost-open
  local trimmed filler cur_tag cur_strip
  _HD_STACK="B"
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
      # Find this line's real heredoc openers, in order, tracking quote state (see _hd_scan_line).
      _HD_TAGS=""; _HD_STRIPS=""
      _hd_scan_line "$line"
      pending_tags="$pending_tags$_HD_TAGS"
      pending_strips="$pending_strips$_HD_STRIPS"
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
# single quotes, double quotes, backticks, a `${ … }` expansion or a `$( … )` command
# substitution. That last exclusion is deliberate: `--body "$(cat <<'EOF' … EOF)"` is one
# command's argument, and the heredoc's newlines inside it must not chop the invocation in half.
#
# Quote state is a stack (the same contexts as _hd_scan_line, innermost LAST), because quotes
# nest: in `"${x:-"'"}"` and `"$(echo "'")"` the inner `"…"` is its own string and the `'` in it
# is a literal. A single "current quote" variable closes the outer string at the inner `"` and
# then reads the `'` as an opener that swallows every command after it.
# Contexts: B base, C `$( … )`, p `( … )` nested inside a non-base context, P `${ … }` (only `${`
# opens one: bash does not count a bare `{` inside, so `${x:-{}` ends at its first `}`), S `'…'`,
# E `$'…'`, D `"…"`, K backtick.
#
# A `#` starts a comment only at the start of a word. `pw` says whether the last thing consumed in
# code context was part of a word (1) or a separator/start (0). A line continuation (`\<newline>`)
# is removed before bash splits words, so it leaves `pw` as it was: in `echo \<newline># x` the `#`
# follows a space and is a comment; in `echo a\<newline>#b` it is part of the word `a#b`. Any other
# escape (`\ #`, `\<tab>#`) is a word character.
#
# Documented limit: a `gh pr create` written INSIDE a command substitution is part of the
# enclosing simple command rather than one of its own, so it is checked only if the enclosing
# command is itself a `gh pr create`/`edit`.
split_simple_commands() {
  local s="$1"
  local len=${#s}
  local i=0 start=0 c nc top stack="B" pw=0 out=""
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    top="${stack: -1}"
    case "$top" in
      S|E|K|D|P) pw=1 ;;    # a quoted or expanded run is part of a word
    esac
    case "$top" in
      S)
        [ "$c" = "'" ] && stack="${stack%?}"
        i=$((i + 1)); continue ;;
      E|K)
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        if { [ "$top" = E ] && [ "$c" = "'" ]; } || { [ "$top" = K ] && [ "$c" = '`' ]; }; then
          stack="${stack%?}"
        fi
        i=$((i + 1)); continue ;;
      D|P)
        case "$c" in
          '\') i=$((i + 2)); continue ;;
          '`') stack="${stack}K" ;;
          '$')
            nc="${s:$((i + 1)):1}"
            case "$nc" in
              '(') stack="${stack}C"; i=$((i + 2)); continue ;;
              '{') stack="${stack}P"; i=$((i + 2)); continue ;;
              "'") if [ "$top" = P ]; then stack="${stack}E"; i=$((i + 2)); continue; fi ;;
            esac ;;
          '"') if [ "$top" = D ]; then stack="${stack%?}"; else stack="${stack}D"; fi ;;
          "'") [ "$top" = P ] && stack="${stack}S" ;;
          '}') [ "$top" = P ] && stack="${stack%?}" ;;
        esac
        i=$((i + 1)); continue ;;
    esac
    # Code context: B, C or p.
    case "$c" in
      "'") stack="${stack}S"; i=$((i + 1)) ;;
      '"') stack="${stack}D"; i=$((i + 1)) ;;
      '`') stack="${stack}K"; i=$((i + 1)) ;;
      '\')
        # A line continuation leaves pw alone; any other escaped character is a word character.
        [ "${s:$((i + 1)):1}" = $'\n' ] || pw=1
        i=$((i + 2)) ;;
      '#')
        # A comment runs to the end of the line; its apostrophes and quotes are prose and must not
        # open a quote that swallows the commands after it. Inside `${ … }` a `#` is an operator
        # (handled by the P arm above); `$#` is consumed by the `$` arm below.
        if [ "$pw" -eq 0 ]; then
          while [ "$i" -lt "$len" ] && [ "${s:$i:1}" != $'\n' ]; do i=$((i + 1)); done
        else
          i=$((i + 1))
        fi ;;
      '$')
        nc="${s:$((i + 1)):1}"
        pw=1
        case "$nc" in
          '(') stack="${stack}C"; pw=0; i=$((i + 2)) ;;
          '{') stack="${stack}P"; i=$((i + 2)) ;;
          "'") stack="${stack}E"; i=$((i + 2)) ;;
          '#') i=$((i + 2)) ;;             # `$#` is the argument count, not a comment
          *) i=$((i + 1)) ;;
        esac
        ;;
      '(')
        pw=0
        if [ "$stack" = "B" ]; then
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        else
          stack="${stack}p"; i=$((i + 1))
        fi
        ;;
      ')')
        pw=0
        if [ "$stack" = "B" ]; then
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        else
          # The end of a `$( … )` is the end of a word part; the end of a plain `( … )` is not.
          [ "$top" = "C" ] && pw=1
          stack="${stack%?}"; i=$((i + 1))
        fi
        ;;
      ';'|'&'|'|'|$'\n')
        pw=0
        if [ "$stack" = "B" ]; then
          out="$out$start $((i - start))"$'\n'; i=$((i + 1)); start=$i
        else
          i=$((i + 1))
        fi
        ;;
      ' '|$'\t') pw=0; i=$((i + 1)) ;;
      # `{` is not a metacharacter: `{#` is one word, and `{ # x` is a comment only for the space.
      *) pw=1; i=$((i + 1)) ;;
    esac
  done
  out="$out$start $((len - start))"$'\n'
  printf '%s' "$out"
}

# ------------------------------------------------------- the ONE wrapper resolver: gh_exec_words
# gh_exec_words <segment> -> "<offset> <length>" lines, one per argv word starting AT the `gh`
# executable; nothing when the segment's executable is not gh. Offsets are relative to the string
# passed in, exactly like argv_spans, and the segment is not truncated (a caller may read a long
# argument value). The executable is resolved by BASENAME after dropping the prefix words that do
# not change which program ends up running: shell keywords that precede a command (`if`, `then`,
# `!`, `{`, `time [-p]`, …), leading `VAR=value` assignments, `command [-p]`, `env [-i]
# [VAR=value…]`, and `exec`. So `command gh`, `env GH_TOKEN=x gh`, `/usr/bin/gh`, `exec gh` and a
# bare `gh` all resolve alike. Quote-aware word splitting means `FOO="a b" gh …` is ONE assignment
# word, so the `gh` after it is still found.
#
# gh_pr_subcommand and gh_command_words below are both derived from this, so every guard agrees
# on what a `gh` invocation is. (lib/gh-exec-words.sh remains as a thin source-compatible shim.)
#
# Documented limit: wrappers that run gh as *data* rather than as their own argv[1] —
# `sh -c "gh pr create …"`, `xargs gh`, `find -exec gh` — still resolve to sh/xargs/find and are
# not recognized.
gh_exec_words() {
  local head="$1"
  local offs=() lens=() off len
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    offs[${#offs[@]}]=$off
    lens[${#lens[@]}]=$len
  done <<ARGV
$(argv_spans "$head")
ARGV
  local n=${#offs[@]} i=0 w exe prev=""
  while [ "$i" -lt "$n" ]; do
    w="${head:${offs[$i]}:${lens[$i]}}"
    case "$w" in
      if|then|else|elif|while|until|do|'!'|'{'|'(') prev="keyword"; i=$((i + 1)); continue ;;
      time) prev="time"; i=$((i + 1)); continue ;;
      [a-zA-Z_]*=*) prev="assign"; i=$((i + 1)); continue ;;
      command|exec|env) prev="$w"; i=$((i + 1)); continue ;;
      -p) case "$prev" in command|time) i=$((i + 1)); continue ;; esac; break ;;
      -i) if [ "$prev" = "env" ]; then i=$((i + 1)); continue; fi; break ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  exe=$(unquote_word "${head:${offs[$i]}:${lens[$i]}}")
  exe="${exe##*/}"
  [ "$exe" = "gh" ] || return 0
  while [ "$i" -lt "$n" ]; do
    printf '%s %s\n' "${offs[$i]}" "${lens[$i]}"
    i=$((i + 1))
  done
}

# ------------------------------------------------- the words of a `gh` simple command, any subcommand
# Prints the segment's argv words AFTER the resolved `gh` executable, one unquoted word per line,
# or nothing when the segment's executable does not resolve to gh.
gh_command_words() {
  local head="$1"
  local off len first=1
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    if [ "$first" -eq 1 ]; then first=0; continue; fi     # the first span is `gh` itself
    unquote_word "${head:$off:$len}"
    printf '\n'
  done <<SPANS
$(gh_exec_words "$head")
SPANS
  return 0
}

# --------------------------------------------------------------- is this simple command `gh pr`?
# Prints "create" or "edit" when the segment's executable resolves to gh and its first two
# arguments are `pr create`/`pr edit`; prints nothing otherwise.
gh_pr_subcommand() {
  local sub1 sub2
  sub1=$(gh_command_words "$1" | sed -n 1p)
  sub2=$(gh_command_words "$1" | sed -n 2p)
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
