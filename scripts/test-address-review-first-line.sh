#!/usr/bin/env bash
#
# Tests for address-review's first-line "answer the final reviewer's threads" step. The two jq
# programs live as fenced `jq` blocks in plugins/repo-ops/skills/address-review/SKILL.md (the text
# the skill follows); this script extracts and runs those exact blocks, so weakening them fails
# here. It also checks the skill never tells the agent to post the re-review command in first-line
# mode.
#
#   ./scripts/test-address-review-first-line.sh
#
# Requires: bash 3.2+, jq, awk.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/repo-ops/skills/address-review/SKILL.md"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/address-review-fl.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Print the fenced jq block whose first line contains the marker.
block() {
  awk -v m="$1" '/^```jq$/ {buf=""; inb=1; next} inb && /^```$/ {if (index(buf, m)) {printf "%s", buf; exit} inb=0; next} inb {buf = buf $0 "\n"}' "$SKILL"
}
block "final-gate thread filter" > "$TMP/threads.jq"
block "final-gate reply check" > "$TMP/reply.jq"
[ -s "$TMP/threads.jq" ] && ok "SKILL.md carries the thread filter" || bad "SKILL.md carries the thread filter"
[ -s "$TMP/reply.jq" ] && ok "SKILL.md carries the reply check" || bad "SKILL.md carries the reply check"

t() { # thread JSON helper: id resolved author [reply-author:reply-body]...
  local id="$1" res="$2" au="$3"; shift 3
  local cs="{\"databaseId\":$id,\"body\":\"finding\",\"author\":{\"login\":\"$au\"}}" r
  for r in "$@"; do
    cs="$cs,{\"databaseId\":0,\"body\":\"${r#*:}\",\"author\":{\"login\":\"${r%%:*}\"}}"
  done
  printf '{"isResolved":%s,"opener":{"nodes":[{"databaseId":%s,"body":"finding","author":{"login":"%s"}}]},"comments":{"nodes":[%s]}}' "$res" "$id" "$au" "$cs"
}
THREADS="[$(t 1 false 'final-bot[bot]'),$(t 2 false 'final-bot[bot]' 'alice:Disputed: validated upstream'),$(t 3 true 'final-bot[bot]'),$(t 4 false 'first-bot[bot]'),$(t 5 false 'final-bot[bot]' 'final-bot[bot]:Fixed in abc1234'),$(t 6 false 'app/final-bot'),$(t 7 false 'final-bot[bot]' 'alice:thanks, will look'),$(t 8 false 'final-bot[bot]' 'alice:Fixed in abc1234'),$(t 9 false 'final-bot[bot]' 'alice:Declined: intentional' 'final-bot[bot]:still allocates per call')]"

got="$(printf '%s' "$THREADS" | jq -c --arg dispute 'Disputed:' --argjson final '["final-bot[bot]"]' --argjson bots '["final-bot[bot]","first-bot[bot]"]' -f "$TMP/threads.jq")"
[ "$got" = "[1,5,6,7,9]" ] && ok "lists final-gate threads with no acceptable non-bot answer (resolved, answered and first-line threads excluded; a 'thanks', a bot's reply, or an answer the final reviewer followed up on is not an answer)" \
  || bad "lists final-gate threads with no acceptable non-bot answer" "got $got, want [1,5,6,7,9]"

# A long thread: `comments` holds only its latest 100, so the opener is not among them. An answer
# in that window clears it; no answer, or an answer the final reviewer followed up on, does not.
long() { # id [author:body]...
  local id="$1" cs="" r; shift
  for r in "$@"; do cs="$cs${cs:+,}{\"databaseId\":0,\"body\":\"${r#*:}\",\"author\":{\"login\":\"${r%%:*}\"}}"; done
  printf '{"isResolved":false,"opener":{"nodes":[{"databaseId":%s,"body":"finding","author":{"login":"final-bot[bot]"}}]},"comments":{"nodes":[%s]}}' "$id" "$cs"
}
LONG="[$(long 10 'alice:Fixed in abc1234' 'alice:thanks'),$(long 11 'alice:thanks'),$(long 12 'alice:Declined: x' 'final-bot[bot]:still wrong'),$(long 13 'final-bot[bot]:still wrong' 'alice:Disputed: no')]"
got="$(printf '%s' "$LONG" | jq -c --arg dispute 'Disputed:' --argjson final '["final-bot[bot]"]' --argjson bots '["final-bot[bot]"]' -f "$TMP/threads.jq")"
[ "$got" = "[11,12]" ] && ok "a long thread is judged on its latest comments and replied to at its opener" \
  || bad "a long thread is judged on its latest comments and replied to at its opener" "got $got, want [11,12]"

# Order: a Fixed in reply goes up after the push, on a sha checked against the pushed head.
grep -q 'merge-base --is-ancestor <sha> "$NEW_HEAD"' "$SKILL" && ok "Fixed in sha is checked against the pushed head" || bad "Fixed in sha is checked against the pushed head"
grep -q 'If the push fails, post no `Fixed in` reply' "$SKILL" && ok "no Fixed in reply when the push fails" || bad "no Fixed in reply when the push fails"
# The filter's input is a read the skill actually spells out.
grep -q 'reviewThreads(first: 100, after: $endCursor)' "$SKILL" && grep -q 'opener: comments(first: 1)' "$SKILL" \
  && grep -q 'comments(last: 100) { nodes { databaseId body author { login } } }' "$SKILL" \
  && ok "the skill spells out the GraphQL read the filter consumes" || bad "the skill spells out the GraphQL read the filter consumes"
# Every thread is read: the read paginates, joins the pages, and a failed read stops the step.
grep -q 'gh api graphql --paginate' "$SKILL" && grep -q "jq -s 'add // \[\]'" "$SKILL" \
  && ok "the thread read paginates and joins every page" || bad "the thread read paginates and joins every page"
grep -q 'thread read failed' "$SKILL" && ok "a failed thread read is not read as []" || bad "a failed thread read is not read as []"

chk() { # want body
  local g
  g="$(jq -n -r --arg b "$2" --arg dispute 'Disputed:' '$b | '"$(cat "$TMP/reply.jq")")"
  [ "$g" = "$1" ] && ok "reply check $1: $2" || bad "reply check $1: $2" "got $g"
}
chk true  'Fixed in abc1234 - moved the check'
chk false 'Fixed it'
chk false 'Fixed in HEAD'
chk true  'Disputed: validated upstream'
chk true  'Declined: intentional'
chk true  'Deferred: tracked in #42'
chk true  'Deferred: o/r#42'
chk true  'Deferred: https://github.com/o/r/issues/9'
chk false 'Deferred: later'
chk false 'Thanks, will look'

# Prose gates: first-line section forbids the re-review post; the non-first-line path stays.
sec="$(awk '/^## First-line mode/ {g=1; next} /^## The principle/ {g=0} g' "$SKILL")"
printf '%s' "$sec" | grep -qi 'never post `review.rereviewCommand`' && ok "first-line section forbids rereviewCommand" || bad "first-line section forbids rereviewCommand"
printf '%s' "$sec" | grep -q 'gh pr comment.*@[a-z]' && bad "first-line section posts a re-review mention" || ok "first-line section never posts a re-review mention"
grep -q 'gh pr comment <PR> --repo <config.repo> --body "@[a-z]*ai please re-review' "$SKILL" && ok "non-first-line stale-score re-review request unchanged" || bad "non-first-line stale-score re-review request unchanged"
grep -q 'not in first-line mode' "$SKILL" && ok "stale-score re-review is gated off in first-line mode" || bad "stale-score re-review is gated off in first-line mode"
# Every "request a re-review" instruction outside the first-line section carries the gate.
ungated="$(awk '/^## First-line mode/ {g=1} /^## The principle/ {g=0} !g && /request a re-review/ && !/not in first-line/' "$SKILL")"
[ -z "$ungated" ] && ok "every re-review request outside the first-line section is gated" || bad "every re-review request outside the first-line section is gated" "$ungated"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
