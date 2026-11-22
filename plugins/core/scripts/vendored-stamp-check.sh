#!/usr/bin/env bash
#
# vendored-stamp-check.sh — report vendored copies of maintainerd-core's coverage scripts
# whose version stamp differs from the canonical scripts of the loaded plugin.
#
# A consuming repo carries copies at .claude/maintainerd/ so CI runs without the plugin
# installed. Each canonical script carries a `# maintainerd-core: <version>` line, rewritten
# by the release tooling, so a copy's stamp says which version it was taken from. This tool
# compares each copy with the canonical script and prints one line per file:
#
#   current       stamp and script both match the canonical
#   MODIFIED      stamp matches but the script differs (a local edit, or a core change that
#                 landed without a version bump): re-copy it, after reading the diff
#   behind        stamp differs but the script is otherwise identical (re-copy is optional)
#   STALE         stamp differs and so does the script: re-copy it
#   UNSTAMPED     no stamp, and the script differs: a pre-stamp copy, re-copy it
#   unstamped     no stamp, but identical apart from that: re-copy to get a stamp
#   MISSING       no vendored copy of a script the canonical set has
#
# Exit 0 when nothing is MODIFIED, STALE, UNSTAMPED or MISSING; 1 otherwise; 2 on bad usage or an
# unreadable canonical. Read-only: it never copies anything, it prints the command.
#
# Canonical source: maintainerd, plugins/core/scripts/vendored-stamp-check.sh
#
#   vendored-stamp-check.sh                         # .claude/maintainerd vs $CLAUDE_PLUGIN_ROOT/scripts
#   vendored-stamp-check.sh --vendored-dir DIR --canonical-dir DIR

set -uo pipefail
export LC_ALL=C

vendored=".claude/maintainerd"
canonical="${CLAUDE_PLUGIN_ROOT:-}/scripts"
SCRIPTS="coverage-adapt.sh coverage-check.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --vendored-dir)  vendored="${2:?--vendored-dir needs a path}"; shift 2 ;;
    --canonical-dir) canonical="${2:?--canonical-dir needs a path}"; shift 2 ;;
    -h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "vendored-stamp-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

stamp_of() { sed -n 's/^# maintainerd-core: \([0-9][0-9.]*\)$/\1/p' "$1" | head -n 1; }
body_of()  { grep -v '^# maintainerd-core: ' "$1"; }

bad=0
for name in $SCRIPTS; do
  canon="$canonical/$name"
  if [ ! -r "$canon" ]; then
    echo "vendored-stamp-check: cannot read canonical $canon" >&2
    exit 2
  fi
  want="$(stamp_of "$canon")"
  [ -n "$want" ] || { echo "vendored-stamp-check: canonical $canon carries no stamp" >&2; exit 2; }
  copy="$vendored/$name"
  if [ ! -f "$copy" ]; then
    echo "MISSING    $copy  (canonical $want)  fix: cp \"$canon\" \"$copy\""
    bad=1
    continue
  fi
  have="$(stamp_of "$copy")"
  same_body=0
  [ "$(body_of "$copy")" = "$(body_of "$canon")" ] && same_body=1
  if [ "$have" = "$want" ]; then
    if [ "$same_body" = 1 ]; then
      echo "current    $copy  ($have)"
    else
      echo "MODIFIED   $copy  (stamp $have matches, script differs)  fix: cp \"$canon\" \"$copy\""
      bad=1
    fi
    continue
  fi
  if [ "$same_body" = 1 ]; then
    if [ -n "$have" ]; then
      echo "behind     $copy  (stamp $have, canonical $want; script unchanged)"
    else
      echo "unstamped  $copy  (canonical $want; script unchanged)  fix: cp \"$canon\" \"$copy\""
    fi
    continue
  fi
  if [ -n "$have" ]; then
    echo "STALE      $copy  (stamp $have, canonical $want)  fix: cp \"$canon\" \"$copy\""
  else
    echo "UNSTAMPED  $copy  (no stamp; canonical $want)  fix: cp \"$canon\" \"$copy\""
  fi
  bad=1
done
exit "$bad"
