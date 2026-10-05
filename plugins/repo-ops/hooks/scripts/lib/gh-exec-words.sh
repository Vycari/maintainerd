#!/usr/bin/env bash
#
# repo-ops — additive companion to gh-command-scan.sh.
#
# Sourced, not executed (and sources gh-command-scan.sh itself). Defines:
#   gh_exec_words <masked segment>   -> "<offset> <length>" lines, one per argv word starting AT
#                                       the `gh` executable; nothing when the segment is not gh
#
# gh_pr_subcommand in gh-command-scan.sh answers "is this `gh pr create|edit`?" and nothing
# else. A hook that needs another gh subcommand's argv (`gh pr comment`, `gh api …`) needs the
# same wrapper resolution — leading VAR=value, `command [-p]`, `env [-i] [VAR=value…]`, `exec`,
# the shell keywords that precede a command — but then the WORDS, not a two-word verdict. This
# is that resolution, kept in its own file so gh-command-scan.sh and its callers are untouched.
# Offsets are relative to the string passed in, exactly like argv_spans.
#
# Same documented limit as gh_pr_subcommand: `sh -c "gh …"`, `xargs gh`, `find -exec gh` resolve
# to sh/xargs/find and are not recognized.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gh-command-scan.sh
. "$SCRIPT_LIB_DIR/gh-command-scan.sh"

# Unlike gh_pr_subcommand, the segment is NOT truncated: a caller reads argument values (a
# reply body) from these spans, and a cut would drop the end of a long body.
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
