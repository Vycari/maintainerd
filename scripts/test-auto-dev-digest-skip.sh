#!/usr/bin/env bash
#
# Tests for the auto-dev tick's digest-skip filter. A planner's rolling digest issue is its own
# output, not work; the tick must drop it at the open-issues read. The filter lives as a fenced
# `jq` block in plugins/auto-dev/skills/auto-dev/SKILL.md (the text the tick follows), and this
# script extracts that exact block and runs it, so removing or weakening the filter fails here.
#
#   ./scripts/test-auto-dev-digest-skip.sh
#
# Requires: bash 3.2+, jq, awk.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/auto-dev/skills/auto-dev/SKILL.md"
MARKERS='["<!-- auto-dev-shadow-digest ", "<!-- auto-dev-digest "]'

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

FILTER="$(mktemp "${TMPDIR:-/tmp}/auto-dev-digest-filter.XXXXXX")"
trap 'rm -f "$FILTER"' EXIT

awk '/^```jq$/ {grab=1; next} grab && /^```$/ {exit} grab {print}' "$SKILL" > "$FILTER"

if ! grep -q 'auto-dev digest-skip filter' "$FILTER"; then
  bad "SKILL.md carries the digest-skip jq filter" "no fenced jq block marked 'auto-dev digest-skip filter'"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "SKILL.md carries the digest-skip jq filter"

# One paginated --slurp file: a list of pages, each a list of entries (issues and PRs).
PAGES='[[
  {"number": 1, "body": "ordinary issue"},
  {"number": 2, "body": null},
  {"number": 3, "body": "<!-- auto-dev-shadow-digest repo=Vycari/foreman rev=7 -->\n## digest"},
  {"number": 4, "body": "\n  <!-- auto-dev-digest rev=2 -->\n## digest"}
],[
  {"number": 5, "body": "quoting one: <!-- auto-dev-shadow-digest repo=a rev=1 --> mid-body"},
  {"number": 6, "body": "<!-- auto-dev-shadow-digest repo=x rev=1 -->", "pull_request": {}},
  {"number": 7, "body": "<!-- auto-dev -->  a marker comment is not a digest"}
]]'

run_filter() { printf '%s' "$PAGES" | jq -c --argjson markers "$1" -f "$FILTER" 2>&1; }
numbers() { jq -c '[.[].number]'; }

got="$(run_filter "$MARKERS" | numbers)"
if [ "$got" = "[1,2,5,7]" ]; then
  ok "digest issues (either marker, leading whitespace) are dropped; PRs too; quoted markers stay"
else
  bad "digest issues are dropped" "got $got, want [1,2,5,7]"
fi

got="$(run_filter '["<!-- custom-digest "]' | numbers)"
if [ "$got" = "[1,2,3,4,5,7]" ]; then
  ok "a configured marker list replaces the default"
else
  bad "a configured marker list replaces the default" "got $got"
fi

got="$(run_filter '[]' | numbers)"
if [ "$got" = "[1,2,3,4,5,7]" ]; then
  ok "an empty marker list drops nothing"
else
  bad "an empty marker list drops nothing" "got $got"
fi

got="$(run_filter '["", "<!-- auto-dev-digest "]' | numbers)"
if [ "$got" = "[1,2,3,5,7]" ]; then
  ok "an empty marker string is ignored, not treated as matching every body"
else
  bad "an empty marker string is ignored" "got $got, want [1,2,3,5,7]"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
