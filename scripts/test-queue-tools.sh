#!/usr/bin/env bash
#
# Tests for the repo-ops queue tools:
#   plugins/repo-ops/scripts/pr-queue.sh
#   plugins/repo-ops/scripts/merge-order.sh
#
# Every case runs the real script against a stubbed `gh` on PATH — no network, no git remote. The
# stub serves fixture files from a per-case directory; a fixture named `<name>.1`, `<name>.2`, ...
# is served on the Nth call (the last one repeats), so a case can say "open on the first look, merged
# on the second". pr-queue's table logic is driven through stand-in verdict scripts (the real
# wait-for-review / wait-for-checks have their own suite, test-wait-tools.sh); one case runs the
# real ones end to end. Run from anywhere:
#
#   ./scripts/test-queue-tools.sh
#
# Requires bash, jq, column.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRQ="$ROOT/plugins/repo-ops/scripts/pr-queue.sh"
MO="$ROOT/plugins/repo-ops/scripts/merge-order.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HEAD_SHA="aaaaaaa1111111111111111111111111111111111"

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# serve <name> — print fixture <name> (or its Nth numbered variant, the last repeating), applying a
# `-q <jq>` argument the way gh does.
serve() {
  local name="$1" n f q="" prev="" a
  for a in "$@"; do
    [ "$prev" = "-q" ] && q="$a"
    prev="$a"
  done
  n=$(($(cat "$STUB_DIR/.count.$name" 2>/dev/null || echo 0) + 1))
  printf '%s' "$n" >"$STUB_DIR/.count.$name"
  f="$STUB_DIR/$name.$n"
  [ -f "$f" ] || f="$STUB_DIR/$name"
  [ -f "$f" ] || f="$(ls "$STUB_DIR/$name".[0-9]* 2>/dev/null | sort | tail -n 1)"
  [ -n "$f" ] && [ -f "$f" ] || { echo "stub: no fixture $name" >&2; exit 1; }
  if [ -f "$f.fail" ]; then exit 1; fi
  if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
}
echo "$*" >>"$STUB_DIR/.calls"
case "$1 $2" in
  "pr list") serve prlist "$@" ;;
  "pr view") serve "pv$3" "$@" ;;
  "api graphql") case "$*" in *mergeQueue*) serve queue ;; *) serve threads ;; esac ;;
  "run view") serve joblog ;;
  "repo view") echo "o/r" ;;
  *) echo "stub: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# Stand-in verdict scripts for pr-queue: print review.<pr> / checks.<pr>, exit with <name>.rc.<pr>.
for kind in review checks; do
  cat >"$TMP/fake-$kind.sh" <<FAKE
#!/usr/bin/env bash
cat "\$STUB_DIR/$kind.\$1"
exit "\$(cat "\$STUB_DIR/$kind.rc.\$1" 2>/dev/null || echo 0)"
FAKE
  chmod +x "$TMP/fake-$kind.sh"
done

new_case() {
  CASE="$TMP/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE/repo/.claude"
  STUB_DIR="$CASE/stub"
  mkdir -p "$STUB_DIR"
  export STUB_DIR
}

# run_tool <script> [args...] -> OUT (stdout), ERR (stderr), RC; the stub gh is first on PATH
run_tool() {
  local script="$1"
  shift
  OUT="$(cd "$CASE/repo" && PATH="$STUB_BIN:$PATH" "${BASH:-bash}" "$script" "$@" 2>"$CASE/stderr")"
  RC=$?
  ERR="$(cat "$CASE/stderr")"
}
run_prq_fake() {
  OUT="$(cd "$CASE/repo" && PATH="$STUB_BIN:$PATH" PR_QUEUE_WAIT_FOR_REVIEW="$TMP/fake-review.sh" PR_QUEUE_WAIT_FOR_CHECKS="$TMP/fake-checks.sh" "${BASH:-bash}" "$PRQ" "$@" 2>"$CASE/stderr")"
  RC=$?
  ERR="$(cat "$CASE/stderr")"
}

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "$2"
}
expect() { # <label> <want-first-line> <want-rc>
  local first
  first="$(printf '%s' "$OUT" | head -n 1)"
  if [ "$first" = "$2" ] && [ "$RC" = "$3" ]; then ok "$1"; else bad "$1" "want '$2' rc=$3; got '$first' rc=$RC (stderr: $ERR)"; fi
}
expect_rc() { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "want rc=$2; got rc=$RC out=$OUT err=$ERR"; }
expect_contains() {
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "output lacks '$2': $OUT" ;; esac
}
expect_not_contains() {
  case "$OUT" in *"$2"*) bad "$1" "output unexpectedly has '$2': $OUT" ;; *) ok "$1" ;; esac
}
row() { printf '%s\n' "$OUT" | awk -v p="#$1" '$2 == p'; }
expect_row() { # <label> <pr> <needle>
  case "$(row "$2")" in *"$3"*) ok "$1" ;; *) bad "$1" "row #$2 lacks '$3': $(row "$2")" ;; esac
}
no_writes() { # <label>
  if grep -qE 'pr (merge|edit|ready|comment|review)|run (rerun|cancel)|-X |--method|mutation|auto-merge|--auto' "$STUB_DIR/.calls"; then
    bad "$1" "mutating call: $(cat "$STUB_DIR/.calls")"
  else
    ok "$1"
  fi
}

# --- pr-queue ------------------------------------------------------------------------------------

echo "pr-queue"

# pr_item <n> <title> [draft] [mergeable] [mergeStateStatus]
pr_item() {
  jq -n -c --argjson n "$1" --arg t "$2" --argjson d "${3:-false}" --arg m "${4:-MERGEABLE}" --arg s "${5:-CLEAN}" \
    '{number: $n, title: $t, isDraft: $d, mergeable: $m, mergeStateStatus: $s, baseRefName: "main", author: {login: "dev"}, autoMergeRequest: {mergeMethod: "SQUASH"}}'
}
verdicts() { # <pr> <review> <checks>
  printf '%s\n' "$2" >"$STUB_DIR/review.$1"
  printf '%s\n' "$3" >"$STUB_DIR/checks.$1"
}

new_case prq-table
{
  pr_item 1 "ready one"
  pr_item 2 "red checks"
  pr_item 3 "a draft" true
  pr_item 4 "open findings"
  pr_item 5 "in the queue"
  pr_item 6 "conflicting" false CONFLICTING DIRTY
  pr_item 7 "awaiting review"
  pr_item 8 "unreadable review"
  pr_item 9 "ci running"
  pr_item 10 "skip labelled" false MERGEABLE BEHIND
  pr_item 11 "protection unmet" false MERGEABLE BLOCKED
} | jq -s -c . >"$STUB_DIR/prlist"
verdicts 1 approved green
verdicts 2 approved "failed:build"
verdicts 4 "findings:2" green
verdicts 5 approved green
verdicts 6 approved green
verdicts 7 timeout green
verdicts 8 "" green
printf '3' >"$STUB_DIR/review.rc.8"
verdicts 9 approved timeout
verdicts 10 no-review-scheduled green
verdicts 11 approved green
echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[{"position":2,"state":"UNMERGEABLE","pullRequest":{"number":5}}]}}}}}' >"$STUB_DIR/queue"
run_prq_fake o/r
expect_rc "the table prints and exits 0" 0
expect_row "approved + green + no threads -> ready" 1 "ready"
expect_row "an auto-merge request on the PR is NOT queue membership" 1 " -  "
expect_row "a failed job names itself" 2 "checks failed: build"
expect_row "a draft is blocked as a draft" 3 "draft"
expect_row "unresolved threads block" 4 "review: 2 unresolved thread(s)"
expect_row "queue position comes from mergeQueue; UNMERGEABLE is flagged" 5 "q2!"
expect_row "a queued PR is not reported ready" 5 "in the merge queue, entry UNMERGEABLE"
expect_row "a merge conflict blocks" 6 "merge conflict with main"
expect_row "an unfinished review is pending" 7 "awaiting review of the head commit"
expect_row "a tool that could not run is an error, not a verdict" 8 "could not read the review or check verdict"
expect_row "checks still running" 9 "checks still running"
expect_row "no-review-scheduled counts as reviewed; behind is shown but not blocking" 10 "behind"
expect_row "a skip-labelled PR can be ready" 10 "ready"
expect_row "GitHub BLOCKED is not ready even when the verdicts pass" 11 "GitHub reports the merge blocked"
expect_contains "a footer counts ready PRs" "11 open PRs; 2 ready, 1 in the merge queue."
no_writes "observe only: no merge/enqueue/label/comment call"

new_case prq-json
{ pr_item 1 "ready one"; pr_item 5 "queued"; } | jq -s -c . >"$STUB_DIR/prlist"
verdicts 1 approved green
verdicts 5 approved green
echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[{"position":1,"state":"QUEUED","pullRequest":{"number":5}}]}}}}}' >"$STUB_DIR/queue"
run_prq_fake o/r --json
[ "$(printf '%s' "$OUT" | jq -r '[.[] | select(.ready) | .number] | join(",")')" = "1" ] && ok "--json: only the unqueued, green, approved PR is ready" || bad "json ready" "$OUT"
[ "$(printf '%s' "$OUT" | jq -r '.[] | select(.number == 5) | .queue.position')" = "1" ] && ok "--json: queue position is carried" || bad "json queue" "$OUT"

new_case prq-no-queue
{ pr_item 1 "ready one"; } | jq -s -c . >"$STUB_DIR/prlist"
verdicts 1 approved green
echo '{"data":{"repository":{"mergeQueue":null}}}' >"$STUB_DIR/queue"
run_prq_fake o/r
expect_row "a repo with no merge queue renders - and is not an error" 1 "ready"

new_case prq-queue-unreadable
{ pr_item 1 "ready one"; } | jq -s -c . >"$STUB_DIR/prlist"
verdicts 1 approved green
touch "$STUB_DIR/queue.fail"
echo '{}' >"$STUB_DIR/queue"
run_prq_fake o/r
expect_row "an unreadable queue is never read as 'not queued, ready'" 1 "merge queue state unreadable"

new_case prq-empty
echo '[]' >"$STUB_DIR/prlist"
run_prq_fake o/r
expect "no open PRs says so" "no open PRs" 0

new_case prq-list-fails
echo '[]' >"$STUB_DIR/prlist"
touch "$STUB_DIR/prlist.fail"
run_prq_fake o/r
expect_rc "a PR list that cannot be read is a tool error (exit 3)" 3

new_case prq-usage
run_prq_fake --bogus
expect_rc "an unknown flag is a usage error" 3

# End to end with the real wait tools: the same readiness rule, no stand-in.
new_case prq-real-tools
printf '%s' '{"review":{"approvalThreshold":"5/5","skipLabel":"greptile:skip","bots":["greptile-apps[bot]"]}}' >"$CASE/repo/.claude/maintainerd.json"
{ pr_item 7 "real"; } | jq -s -c . >"$STUB_DIR/prlist"
jq -n -c --arg head "$HEAD_SHA" --arg body "$(printf '<h2>Confidence Score: 5/5</h2>\n<sub>Last reviewed commit: [aaaaaaa](https://github.com/o/r/commit/aaaaaaa)</sub>')" '{
  number: 7, isDraft: false, state: "OPEN", labels: [], headRefOid: $head, body: "", reviewDecision: "", reviews: [],
  comments: [{author: {login: "greptile-apps"}, body: $body}],
  statusCheckRollup: [{__typename: "CheckRun", name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "", startedAt: ""}]}' >"$STUB_DIR/pv7"
echo '{"data":{"repository":{"pullRequest":{"userContentEdits":{"nodes":[]},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' >"$STUB_DIR/threads"
echo '{"data":{"repository":{"mergeQueue":null}}}' >"$STUB_DIR/queue"
run_tool "$PRQ" o/r
expect_row "real tools: 5/5 on head + green + 0 threads -> ready" 7 "approved"
expect_row "real tools: green and ready" 7 "green"
expect_row "real tools: blocking column says ready" 7 "ready"
no_writes "real tools: still observe only"

# --- merge-order ---------------------------------------------------------------------------------

echo "merge-order"

# mo_pr <n> <head> <base> <body> <files-comma> [state]  -> writes pv<n>
mo_pr() {
  jq -n -c --argjson n "$1" --arg h "$2" --arg b "$3" --arg body "$4" --arg files "$5" --arg st "${6:-OPEN}" \
    '{number: $n, title: "PR \($n)", state: $st, body: $body, headRefName: $h, baseRefName: $b,
      files: ($files | split(",") | map(select(. != "") | {path: .}))}' >"$STUB_DIR/pv$1"
}
NOQ='{"data":{"repository":{"mergeQueue":null}}}'

new_case mo-deps-and-overlap
mo_pr 10 b10 main "" "a.sh,b.sh"
mo_pr 11 b11 main "Depends on #12" "c.sh"
mo_pr 12 b12 main "" "a.sh,d.sh"
run_tool "$MO" 10 11 12 -R o/r
expect "lowest ready number first; a stated dependency waits for its dependency" "order: #10 #12 #11" 0
expect_contains "a stated dependency is listed" "needs: #12 (stated)"
expect_contains "shared files are listed against the other PR" "shares files with: #12 [a.sh]"
no_writes "observe only"

new_case mo-stack
mo_pr 20 feat-b feat-a "" "x"
mo_pr 21 feat-a main "" "y"
run_tool "$MO" 20 21 -R o/r
expect "a PR based on another's branch lands after it, whatever the numbers" "order: #21 #20" 0
expect_contains "the stack is named as the reason" "stacked"

new_case mo-multi-dep-phrase
mo_pr 30 b30 main "Blocked by #32, #31 and #33." ""
mo_pr 31 b31 main "" ""
mo_pr 32 b32 main "" ""
mo_pr 33 b33 main "" ""
run_tool "$MO" 30 31 32 33 -R o/r
expect "several numbers after one phrase are all dependencies" "order: #31 #32 #33 #30" 0

new_case mo-cycle
mo_pr 40 b40 main "Depends on #41" ""
mo_pr 41 b41 main "Depends on #40" ""
run_tool "$MO" 40 41 -R o/r
expect_rc "a dependency cycle is an error, never a guessed order" 3
case "$ERR" in *cycle*) ok "the cycle is named" ;; *) bad "cycle message" "$ERR" ;; esac

new_case mo-external-dep
mo_pr 50 b50 main "Stacked on #99. Requires #98." ""
echo '{"state":"OPEN"}' >"$STUB_DIR/pv99"
echo '{"state":"MERGED"}' >"$STUB_DIR/pv98"
run_tool "$MO" 50 -R o/r
expect_contains "an open dependency outside the set is noted" "#99 is open, outside this set"
expect_not_contains "a merged one is not" "#98"

new_case mo-dep-wording
mo_pr 80 b80 main "Depends on PR #82 and [#83](https://github.com/o/r/pull/83)." ""
mo_pr 81 b81 main "Requires https://github.com/o/r/pull/82" ""
mo_pr 82 b82 main "" ""
mo_pr 83 b83 main "" ""
run_tool "$MO" 80 81 82 83 -R o/r
expect "'PR #n', markdown links and PR URLs are dependencies too" "order: #82 #81 #83 #80" 0

new_case mo-external-stack
mo_pr 70 child feat-parent "" "x"
echo '[{"number":71}]' >"$STUB_DIR/prlist"
run_tool "$MO" 70 -R o/r
expect_contains "a PR based on an open PR's branch outside the set is noted" "#71 is open, outside this set"

new_case mo-already-merged
mo_pr 60 b60 main "" "" MERGED
mo_pr 61 b61 main "" ""
run_tool "$MO" 60 61 -R o/r
expect "a merged PR drops out of the order" "order: #61" 0
expect_contains "and is noted" "already merged: #60"

new_case mo-all-merged
mo_pr 60 b60 main "" "" MERGED
run_tool "$MO" 60 -R o/r
expect "nothing left" "nothing-to-merge" 0

new_case mo-url-and-dedupe
mo_pr 10 b10 main "" ""
run_tool "$MO" https://github.com/o/r/pull/10 10
expect "a PR URL names the repo; duplicates collapse" "order: #10" 0
run_tool "$MO" https://github.com/o/r/pull/10 -R x/y
expect_rc "-R contradicting the PR URL is an error" 3

new_case mo-usage
run_tool "$MO"
expect_rc "no PRs is a usage error" 3
echo '{}' >"$STUB_DIR/pv9"
touch "$STUB_DIR/pv9.fail"
run_tool "$MO" 9 -R o/r
expect_rc "an unreadable PR is a tool error" 3

new_case mo-watch-in-order
mo_pr 10 b10 main "" "a.sh"
mo_pr 11 b11 main "" "a.sh"
jq -c '.state = "MERGED"' "$STUB_DIR/pv10" >"$STUB_DIR/pv10.2"
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.1"
cp "$STUB_DIR/pv11" "$STUB_DIR/pv11.1"
cp "$STUB_DIR/pv11" "$STUB_DIR/pv11.2"
jq -c '.state = "MERGED"' "$STUB_DIR/pv11" >"$STUB_DIR/pv11.3"
echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[{"position":1,"state":"QUEUED","pullRequest":{"number":11}}]}}}}}' >"$STUB_DIR/queue.1"
echo "$NOQ" >"$STUB_DIR/queue.2"
run_tool "$MO" 10 11 -R o/r --watch --interval-seconds 0 --timeout-seconds 30
expect "the first line is still the order" "order: #10 #11" 0
expect_contains "a landing is reported" "landed: #10"
expect_contains "queue membership comes from mergeQueue" "queued: #11 q1"
expect_contains "the next PR is named" "next: #11"
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "all-landed" ] && ok "the last line is the verdict: all-landed" || bad "verdict" "$OUT"
no_writes "watch is observe only"

new_case mo-watch-out-of-order
mo_pr 10 b10 main "" ""
mo_pr 11 b11 main "" ""
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.1"
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.2"
jq -c '.state = "MERGED"' "$STUB_DIR/pv10" >"$STUB_DIR/pv10.3"
cp "$STUB_DIR/pv11" "$STUB_DIR/pv11.1"
jq -c '.state = "MERGED"' "$STUB_DIR/pv11" >"$STUB_DIR/pv11.2"
echo "$NOQ" >"$STUB_DIR/queue"
run_tool "$MO" 10 11 -R o/r --watch --interval-seconds 0 --timeout-seconds 30
expect_contains "landing before an earlier PR is flagged" "landed: #11 (out of order, expected #10 first)"
[ "$RC" = "0" ] && ok "still all-landed in the end" || bad "rc" "$RC $OUT"

new_case mo-watch-closed
mo_pr 10 b10 main "" ""
mo_pr 11 b11 main "" ""
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.1"
jq -c '.state = "MERGED"' "$STUB_DIR/pv10" >"$STUB_DIR/pv10.2"
cp "$STUB_DIR/pv11" "$STUB_DIR/pv11.1"
jq -c '.state = "CLOSED"' "$STUB_DIR/pv11" >"$STUB_DIR/pv11.2"
echo "$NOQ" >"$STUB_DIR/queue"
run_tool "$MO" 10 11 -R o/r --watch --interval-seconds 0 --timeout-seconds 30
expect_contains "a PR closed unmerged is reported" "closed: #11"
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "done: 1 landed, 1 closed unmerged" ] && [ "$RC" = "1" ] && ok "verdict done:..., exit 1" || bad "closed verdict" "rc=$RC $OUT"

new_case mo-watch-queue-unreadable
mo_pr 10 b10 main "" ""
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.1"
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.2"
jq -c '.state = "MERGED"' "$STUB_DIR/pv10" >"$STUB_DIR/pv10.3"
echo '{}' >"$STUB_DIR/queue"
touch "$STUB_DIR/queue.fail"
run_tool "$MO" 10 -R o/r --watch --interval-seconds 0 --timeout-seconds 30
expect_rc "an unreadable merge queue does not abort the watch" 3
case "$ERR" in *"gh api graphql failed"*) ok "and the first-read failure names the queue error" ;; *) bad "queue error text" "rc=$RC err=$ERR" ;; esac

new_case mo-watch-queue-flaky
mo_pr 10 b10 main "" ""
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.1"
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.2"
cp "$STUB_DIR/pv10" "$STUB_DIR/pv10.3"
jq -c '.state = "MERGED"' "$STUB_DIR/pv10" >"$STUB_DIR/pv10.4"
echo "$NOQ" >"$STUB_DIR/queue.1"
echo "$NOQ" >"$STUB_DIR/queue.2"
touch "$STUB_DIR/queue.2.fail"
echo "$NOQ" >"$STUB_DIR/queue.3"
run_tool "$MO" 10 -R o/r --watch --interval-seconds 0 --timeout-seconds 30
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "all-landed" ] && ok "a transient queue-read failure mid-watch is tolerated" || bad "flaky queue" "rc=$RC out=$OUT err=$ERR"

new_case mo-watch-timeout
mo_pr 10 b10 main "" ""
echo "$NOQ" >"$STUB_DIR/queue"
run_tool "$MO" 10 -R o/r --watch --timeout-seconds 0
[ "$(printf '%s\n' "$OUT" | sed -n '/^timeout$/p')" = "timeout" ] && [ "$RC" = "2" ] && ok "no landing by the deadline -> timeout, exit 2" || bad "timeout" "rc=$RC $OUT"
expect_contains "the PRs still open are listed" "still open: #10"

echo
printf '%s\n' "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
