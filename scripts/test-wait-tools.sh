#!/usr/bin/env bash
#
# Tests for the repo-ops wait tools:
#   plugins/repo-ops/scripts/wait-for-review.sh
#   plugins/repo-ops/scripts/wait-for-checks.sh
#
# Every case runs the real script against a stubbed `gh` on PATH — no network, no git remote. The
# stub serves fixture files from a per-case directory and, for any fixture named `<name>.1`,
# `<name>.2`, ... serves the Nth on the Nth call (the last one repeats), so a case can say "the
# review is stale on the first poll and current on the second". Run from anywhere:
#
#   ./scripts/test-wait-tools.sh
#
# Requires bash, jq.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WFR="$ROOT/plugins/repo-ops/scripts/wait-for-review.sh"
WFC="$ROOT/plugins/repo-ops/scripts/wait-for-checks.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HEAD_SHA="aaaaaaa1111111111111111111111111111111111"
OLD_SHA="bbbbbbb2222222222222222222222222222222222"

# The stub gh. Dispatches on the subcommand and serves $STUB_DIR fixtures.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# serve <name> — print fixture <name>, or its Nth numbered variant, bumping a per-name counter.
serve() {
  local name="$1" n f
  n=$(($(cat "$STUB_DIR/.count.$name" 2>/dev/null || echo 0) + 1))
  printf '%s' "$n" >"$STUB_DIR/.count.$name"
  f="$STUB_DIR/$name.$n"
  [ -f "$f" ] || f="$STUB_DIR/$name"
  if [ ! -f "$f" ]; then
    # The highest-numbered variant repeats once the sequence runs out.
    f="$(ls "$STUB_DIR/$name".[0-9]* 2>/dev/null | sort | tail -n 1)"
  fi
  [ -n "$f" ] && [ -f "$f" ] || { echo "stub: no fixture $name" >&2; exit 1; }
  cat "$f"
  [ ! -f "$f.fail" ] || exit 1
}
echo "$*" >>"$STUB_DIR/.calls"
case "$1 $2" in
  "pr view") serve prview ;;
  "api graphql") serve threads ;;
  "api -H") serve remoteconfig ;;
  "run view") serve joblog ;;
  "repo view") echo "o/r" ;;
  "api repos/o/r/actions/jobs/"*) serve job ;;
  *) echo "stub: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# new_case <name> -> sets CASE (a fresh fixture dir) and exports STUB_DIR
new_case() {
  CASE="$TMP/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE/repo/.claude"
  STUB_DIR="$CASE/stub"
  mkdir -p "$STUB_DIR"
  export STUB_DIR
}

# write_config <json> — the case's .claude/maintainerd.json
write_config() { printf '%s' "$1" >"$CASE/repo/.claude/maintainerd.json"; }

# pr_json <body> <comments-json> [head] [extra-jq-merge] -> writes prview fixture
# Greptile-shaped comment: a persistent bot comment carrying score and "Last reviewed commit".
greptile_text() { # <score> <sha7>
  printf '<h2>Confidence Score: %s</h2>\n<sub>Reviews (2) · Last reviewed commit: [%s](https://github.com/o/r/commit/%s)</sub>' "$1" "$2" "$2"
}
write_prview() { # <file-suffix or ""> <jq-filter-over-base>
  local base
  base="$(jq -n --arg head "$HEAD_SHA" '{
    number: 7, isDraft: false, state: "OPEN", labels: [], headRefOid: $head, body: "",
    comments: [], reviews: [], reviewDecision: "", statusCheckRollup: []}')"
  printf '%s' "$base" | jq -c "$2" >"$STUB_DIR/prview$1"
}
bot_comment() { # <body> -> a JSON comment authored by the bot
  jq -n --arg b "$1" '{author: {login: "greptile-apps"}, body: $b}'
}
# write_threads <suffix> <json array of {resolved,path,line,body}> — BODY_EDITOR (env, optional) is
# the login that last edited the PR description.
write_threads() {
  printf '%s' "$2" | jq -c --arg ed "${BODY_EDITOR:-}" '{data: {repository: {pullRequest: {
    userContentEdits: {nodes: (if $ed == "" then [] else [{editor: {login: $ed}}] end)},
    reviewThreads: {
    pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [.[] | {isResolved: .resolved, isOutdated: false, path: .path, line: .line, originalLine: .line,
                   comments: {nodes: [{body: .body, author: {login: "greptile-apps"}}]}}]}}}}}' >"$STUB_DIR/threads$1"
}

# run_tool <script> [args...] -> sets OUT (stdout), ERR (stderr), RC; PATH has the stub gh first
run_tool() {
  local script="$1"
  shift
  OUT="$(cd "$CASE/repo" && PATH="$STUB_BIN:$PATH" "${BASH:-bash}" "$script" "$@" 2>"$CASE/stderr")"
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
# expect <label> <want-first-line> <want-rc>
expect() {
  local first
  first="$(printf '%s' "$OUT" | head -n 1)"
  if [ "$first" = "$2" ] && [ "$RC" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "want '$2' rc=$3; got '$first' rc=$RC (stderr: $ERR)"
  fi
}
expect_contains() { # <label> <needle>
  case "$OUT" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "output lacks '$2': $OUT" ;;
  esac
}
expect_not_contains() {
  case "$OUT" in
    *"$2"*) bad "$1" "output unexpectedly has '$2': $OUT" ;;
    *) ok "$1" ;;
  esac
}
calls_of() { grep -c "$1" "$STUB_DIR/.calls" 2>/dev/null || true; }

CFG_5='{"review":{"approvalThreshold":"5/5","skipLabel":"greptile:skip","bots":["greptile-apps[bot]"]}}'
FAST=(-R o/r --timeout-seconds 3 --interval-seconds 1)
FASTC=("${FAST[@]}" --settle-seconds 0)

echo "wait-for-review"

new_case review-approved
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "5/5 on head with no open threads -> approved" approved 0

new_case review-approved-resolved
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[{"resolved":true,"path":"a.sh","line":3,"body":"old"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "resolved threads do not block approval" approved 0

new_case review-findings
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 4/5 aaaaaaa)")]"
write_threads "" '[{"resolved":false,"path":"src/a.sh","line":12,"body":"P1: quoting\n\nthis breaks on spaces"},{"resolved":true,"path":"x","line":1,"body":"done"},{"resolved":false,"path":"src/b.sh","line":40,"body":"P2: unused var"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "unresolved threads -> findings:2" "findings:2" 1
expect_contains "findings carry file:line and a body" "src/a.sh:12  P1: quoting this breaks on spaces"
expect_contains "every unresolved finding is listed" "src/b.sh:40  P2: unused var"
expect_not_contains "resolved thread is not listed" "done"

new_case review-findings-at-threshold
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[{"resolved":false,"path":"a.sh","line":1,"body":"nit"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "5/5 but an open thread is not approved" "findings:1" 1

new_case review-below-threshold-no-threads
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 4/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "4/5 with no open thread -> findings:0, never approved" "findings:0" 1
expect_contains "findings:0 explains the shortfall" "below review.approvalThreshold"

new_case review-stale-comment
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 bbbbbbb)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "5/5 of an OLDER commit is stale -> timeout, not approved" timeout 2

new_case review-stale-then-current
write_config "$CFG_5"
write_prview ".1" ".comments = [$(bot_comment "$(greptile_text 5/5 bbbbbbb)")]"
write_prview ".2" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "stale on poll 1, edited in place to the head on poll 2 -> approved" approved 0
[ "$(calls_of 'pr view')" -ge 2 ] && ok "it polled again rather than trusting the stale comment" || bad "re-poll" "pr view called $(calls_of 'pr view') time(s)"

new_case review-greptile-title-link
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(printf '<h2>Confidence Score: 5/5</h2>\n<sub>Reviews (3) · Last reviewed commit: ["feat(repo-ops): wait tools (x)"](https://github.com/o/r/commit/%s)</sub>' "$HEAD_SHA")")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "Greptile's real shape (commit TITLE as link text, sha in the URL) is read" approved 0

new_case review-greptile-title-link-stale
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(printf '<h2>Confidence Score: 5/5</h2>\n<sub>Reviews (3) · Last reviewed commit: ["feat: older"](https://github.com/o/r/commit/%s)</sub>' "$OLD_SHA")")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "title-link shape naming an older commit is stale -> timeout" timeout 2

new_case review-no-sha
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment '<h2>Confidence Score: 5/5</h2>')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a score with no readable commit is unverifiable -> timeout" timeout 2

new_case review-body-block
write_config "$CFG_5"
write_prview "" ".body = $(jq -Rs . <<<"intro<!-- greptile_comment -->
$(greptile_text 5/5 aaaaaaa)
<!-- /greptile_comment -->")"
BODY_EDITOR=greptile-apps write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "score in the PR-description marker block, last edited by the bot, is read" approved 0

new_case review-body-block-forged
write_config "$CFG_5"
write_prview "" ".body = $(jq -Rs . <<<"intro<!-- greptile_comment -->
$(greptile_text 5/5 aaaaaaa)
<!-- /greptile_comment -->")"
BODY_EDITOR=someone-else write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a marker block last edited by a human is forged evidence -> timeout, not approved" timeout 2

new_case review-body-block-unattributed
write_config "$CFG_5"
write_prview "" ".body = $(jq -Rs . <<<"<!-- greptile_comment -->
$(greptile_text 5/5 aaaaaaa)
<!-- /greptile_comment -->")"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a marker block with no recorded bot edit is not trusted" timeout 2

new_case review-body-prose-not-block
write_config "$CFG_5"
write_prview "" '.body = "we scored Confidence Score: 5/5 last round, Last reviewed commit: aaaaaaa"'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "prose in the description outside the marker block is not a verdict" timeout 2

new_case review-non-bot-comment
write_config "$CFG_5"
write_prview "" ".comments = [{author:{login:\"someone\"}, body: \"$(greptile_text 5/5 aaaaaaa | tr '\n' ' ' | sed 's/"/\\"/g')\"}]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a score quoted by a non-bot author is ignored" timeout 2

new_case review-newest-bot-comment-with-score
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)"), $(bot_comment 'ordinary finding with no score')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a later bot comment without a score does not hide the score comment" approved 0

new_case review-two-bots-one-below
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]","other-bot[bot]"]}}'
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)"), $(jq -n --arg b "$(greptile_text 3/5 aaaaaaa)" '{author:{login:"other-bot"},body:$b}')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "two bots, one scored below the bar on head -> never approved" "findings:0" 1
expect_contains "the failing bot is named" "other-bot scored 3/5"

new_case review-two-bots-both-met
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]","other-bot[bot]"]}}'
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)"), $(jq -n --arg b "$(greptile_text 5/5 aaaaaaa)" '{author:{login:"other-bot"},body:$b}')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "two bots, both at the bar on head -> approved" approved 0

new_case review-two-bots-one-stale
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]","other-bot[bot]"]}}'
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)"), $(jq -n --arg b "$(greptile_text 5/5 bbbbbbb)" '{author:{login:"other-bot"},body:$b}')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "two bots, one still on an older commit -> keeps waiting (timeout)" timeout 2

new_case review-human-changes-requested
write_config "$CFG_5"
write_prview "" ".reviewDecision = \"CHANGES_REQUESTED\" | .comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "5/5 on head but a reviewer requested changes -> not approved" "findings:0" 1
expect_contains "the blocking decision is named" "requested changes"

new_case review-pr-url-other-repo
write_config "$CFG_5"
write_prview "" '.labels = [{name:"greptile:skip"}]'
echo '{"review":{"skipLabel":"greptile:skip","approvalThreshold":"5/5","bots":["greptile-apps[bot]"]}}' >"$STUB_DIR/remoteconfig"
run_tool "$WFR" https://github.com/x/y/pull/7 --timeout-seconds 3 --interval-seconds 1
expect "a PR URL for another repo is polled there and judged by THAT repo's config" no-review-scheduled 0
grep -q 'pr view 7 -R x/y' "$STUB_DIR/.calls" && ok "the URL's repository, not the checkout's, is polled" || bad "url repo" "$(cat "$STUB_DIR/.calls")"

new_case review-other-repo-no-config
write_config "$CFG_5"
write_prview "" '.labels = [{name:"greptile:skip"}]'
echo 'gh: Not Found (HTTP 404)' >"$STUB_DIR/remoteconfig"
touch "$STUB_DIR/remoteconfig.fail"
write_threads "" '[]'
run_tool "$WFR" 7 -R x/y --timeout-seconds 2 --interval-seconds 1
expect "-R another repo with no config there: the local skipLabel does not apply (defaults) -> timeout" timeout 2

new_case review-other-repo-config-error
write_config "$CFG_5"
write_prview "" '.'
echo 'gh: HTTP 500' >"$STUB_DIR/remoteconfig"
touch "$STUB_DIR/remoteconfig.fail"
write_threads "" '[]'
run_tool "$WFR" 7 -R x/y --timeout-seconds 2 --interval-seconds 1
[ "$RC" = "3" ] && ok "an unreadable remote config fails closed (exit 3)" || bad "remote config error" "rc=$RC out=$OUT"

new_case review-url-contradicts-R
write_config "$CFG_5"
run_tool "$WFR" https://github.com/x/y/pull/7 -R o/r
[ "$RC" = "3" ] && ok "-R contradicting the PR URL is a usage error" || bad "url vs -R" "rc=$RC"

new_case review-skip-label
write_config "$CFG_5"
write_prview "" '.labels = [{name:"greptile:skip"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "skipLabel on the PR -> no-review-scheduled" no-review-scheduled 0

new_case review-draft
write_config "$CFG_5"
write_prview "" '.isDraft = true'
run_tool "$WFR" 7 "${FAST[@]}"
expect "draft PR -> no-review-scheduled" no-review-scheduled 0

new_case review-no-bot
write_config '{"review":{"approvalThreshold":"5/5","bots":[]}}'
write_prview "" '.'
run_tool "$WFR" 7 "${FAST[@]}"
expect "review.bots configured empty -> no-review-scheduled" no-review-scheduled 0

new_case review-timeout
write_config "$CFG_5"
write_prview "" '.'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "no bot comment ever appears -> timeout" timeout 2

new_case review-timeout-minutes-config
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"],"waitTimeoutMinutes":0}}'
write_prview "" '.'
write_threads "" '[]'
run_tool "$WFR" 7 -R o/r --interval-seconds 1
expect "review.waitTimeoutMinutes is read from config (0 -> immediate deadline)" timeout 2

new_case review-never-writes
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 4/5 aaaaaaa)")]"
write_threads "" '[{"resolved":false,"path":"a.sh","line":1,"body":"x"}]'
run_tool "$WFR" 7 "${FAST[@]}"
if grep -qE 'pr (edit|merge|comment|review|ready|close)|api .*(-X|--method) (POST|PUT|PATCH|DELETE)' "$STUB_DIR/.calls"; then
  bad "observe only" "a mutating gh call was made: $(cat "$STUB_DIR/.calls")"
else
  ok "observe only: no mutating gh call was made"
fi

new_case review-default-threshold-approved
write_config '{"review":{"bots":["greptile-apps[bot]"]}}'
write_prview "" '.reviewDecision = "APPROVED"'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "default threshold: reviewDecision APPROVED + 0 threads -> approved" approved 0

new_case review-default-threshold-changes
write_config '{"review":{"bots":["greptile-apps[bot]"]}}'
write_prview "" '.reviewDecision = "CHANGES_REQUESTED"'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "default threshold: not APPROVED -> timeout" timeout 2

new_case review-first-read-fails
write_config "$CFG_5"
echo '{}' >"$STUB_DIR/prview"
touch "$STUB_DIR/prview.fail"
run_tool "$WFR" 7 "${FAST[@]}"
[ "$RC" = "3" ] && ok "a failing first gh read is a tool error (exit 3), not a timeout" || bad "first read" "rc=$RC out=$OUT"

new_case review-bad-config
write_config '{not json'
write_prview "" '.'
run_tool "$WFR" 7 "${FAST[@]}"
[ "$RC" = "3" ] && ok "invalid config fails closed (exit 3)" || bad "bad config" "rc=$RC out=$OUT"

new_case review-bad-threshold
write_config '{"review":{"approvalThreshold":"high"}}'
write_prview "" '.'
run_tool "$WFR" 7 "${FAST[@]}"
[ "$RC" = "3" ] && ok "an unparseable approvalThreshold fails closed (exit 3)" || bad "bad threshold" "rc=$RC out=$OUT"

new_case review-usage
run_tool "$WFR"
[ "$RC" = "3" ] && ok "missing PR argument is a usage error" || bad "usage" "rc=$RC"

new_case review-pr-url
write_config "$CFG_5"
write_prview "" '.isDraft = true'
run_tool "$WFR" https://github.com/o/r/pull/7 "${FAST[@]}"
expect "a PR URL is accepted" no-review-scheduled 0

echo
echo "wait-for-checks"

CHECK_URL="https://github.com/o/r/actions/runs/900/job/4242"
check_run() { # <name> <status> <conclusion> [startedAt] [url]
  jq -n --arg n "$1" --arg s "$2" --arg c "$3" --arg t "${4:-2026-01-01T00:00:00Z}" --arg u "${5:-$CHECK_URL}" \
    '{__typename:"CheckRun", name:$n, status:$s, conclusion:$c, startedAt:(if $t == "NONE" then null else $t end), detailsUrl:$u}'
}
rollup() { write_prview "$1" ".statusCheckRollup = [$2]"; }

new_case checks-green
rollup "" "$(check_run build COMPLETED SUCCESS), $(check_run lint COMPLETED SKIPPED), $(check_run docs COMPLETED NEUTRAL)"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "all complete, none failed -> green" green 0

new_case checks-green-status-context
rollup "" "$(check_run build COMPLETED SUCCESS), {\"__typename\":\"StatusContext\",\"context\":\"ci/legacy\",\"state\":\"SUCCESS\"}"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "a StatusContext success counts as green" green 0

new_case checks-failed
rollup "" "$(check_run build COMPLETED SUCCESS), $(check_run 'test (3.12)' COMPLETED FAILURE), $(check_run slow IN_PROGRESS '')"
printf 'step: pytest\nFAILED tests/test_a.py::test_x\nAssertionError\n' >"$STUB_DIR/joblog"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "a failed job -> failed:<job name>, without waiting for the rest" "failed:test (3.12)" 1
expect_contains "the failing job's log tail follows" "FAILED tests/test_a.py::test_x"
grep -q 'run view --job 4242' "$STUB_DIR/.calls" && ok "the log is fetched per JOB id, not per run" || bad "job-level" "calls: $(cat "$STUB_DIR/.calls")"

new_case checks-failed-long-log
rollup "" "$(check_run build COMPLETED FAILURE)"
for i in $(seq 1 100); do echo "line $i"; done >"$STUB_DIR/joblog"
run_tool "$WFC" 7 "${FASTC[@]}"
expect_contains "the log is a tail (last line kept)" "line 100"
expect_not_contains "the log is a tail (early lines dropped)" "line 50"

new_case checks-failed-timed-out
rollup "" "$(check_run build COMPLETED TIMED_OUT)"
echo "log" >"$STUB_DIR/joblog"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "timed_out counts as failed" "failed:build" 1

new_case checks-failed-non-actions
rollup "" '{"__typename":"StatusContext","context":"ci/external","state":"FAILURE","targetUrl":"https://ci.example/1"}'
run_tool "$WFC" 7 "${FASTC[@]}"
expect "a failed external status -> failed:<context>" "failed:ci/external" 1
expect_contains "no Actions log is claimed for a non-Actions check" "not a GitHub Actions job"

new_case checks-pending-then-green
rollup ".1" "$(check_run build IN_PROGRESS '')"
rollup ".2" "$(check_run build COMPLETED SUCCESS)"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "in progress, then complete -> green on a later poll" green 0

new_case checks-empty-rollup-timeout
rollup "" ''
run_tool "$WFC" 7 "${FASTC[@]}"
expect "an empty rollup keeps waiting -> timeout" timeout 2

new_case checks-timeout
rollup "" "$(check_run build IN_PROGRESS '')"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "still running at the deadline -> timeout" timeout 2

new_case checks-queued-no-runner
rollup "" "$(check_run build QUEUED '' 2026-01-01T00:00:00Z)"
echo '{"status":"queued","runner_id":null,"runner_name":null}' >"$STUB_DIR/job"
run_tool "$WFC" 7 "${FASTC[@]}" --queue-threshold-seconds 60
expect "queued past the threshold, no runner -> queued-no-runner" queued-no-runner 2
expect_contains "the stuck job is named" "build"

new_case checks-queued-no-start-time
rollup "" "$(check_run build QUEUED '' NONE)"
echo '{"status":"queued","runner_id":null,"created_at":"2026-01-01T00:00:00Z"}' >"$STUB_DIR/job"
run_tool "$WFC" 7 "${FASTC[@]}" --queue-threshold-seconds 60
expect "a queued job with no startedAt is aged from the job's created_at -> queued-no-runner" queued-no-runner 2

new_case checks-queued-no-start-time-young
rollup "" "$(check_run build QUEUED '' NONE)"
echo "{\"status\":\"queued\",\"runner_id\":null,\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >"$STUB_DIR/job"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "a freshly queued job with no startedAt is not yet stuck (timeout)" timeout 2

new_case checks-partial-registration
rollup ".1" "$(check_run build COMPLETED SUCCESS)"
rollup ".2" "$(check_run build COMPLETED SUCCESS), $(check_run slow QUEUED '' 2026-01-01T00:00:00Z)"
echo '{"status":"queued","runner_id":5}' >"$STUB_DIR/job"
run_tool "$WFC" 7 -R o/r --timeout-seconds 4 --interval-seconds 1 --settle-seconds 1 --queue-threshold-seconds 99999
expect "all-green snapshot, then a second required check appears -> not green" timeout 2

new_case checks-settled-green
rollup ".1" "$(check_run build COMPLETED SUCCESS)"
run_tool "$WFC" 7 -R o/r --timeout-seconds 6 --interval-seconds 1 --settle-seconds 1
expect "the same set seen green after the settle delay -> green" green 0

new_case checks-queued-with-runner
rollup "" "$(check_run build QUEUED '' 2026-01-01T00:00:00Z)"
echo '{"status":"queued","runner_id":12,"runner_name":"r1"}' >"$STUB_DIR/job"
run_tool "$WFC" 7 "${FASTC[@]}" --queue-threshold-seconds 60
expect "queued but a runner is assigned -> keeps waiting (timeout)" timeout 2

new_case checks-queued-under-threshold
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rollup "" "$(check_run build QUEUED '' "$now_iso")"
echo '{"status":"queued","runner_id":null}' >"$STUB_DIR/job"
run_tool "$WFC" 7 "${FASTC[@]}"
expect "queued under the threshold -> not yet queued-no-runner (timeout)" timeout 2
[ "$(calls_of 'actions/jobs')" = "0" ] && ok "no runner lookup before the threshold" || bad "lookup" "$(cat "$STUB_DIR/.calls")"

new_case checks-queued-unverifiable
rollup "" "$(check_run build QUEUED '' 2026-01-01T00:00:00Z)"
echo '{}' >"$STUB_DIR/job"
touch "$STUB_DIR/job.fail"
run_tool "$WFC" 7 "${FASTC[@]}" --queue-threshold-seconds 60
expect "queued, assignment cannot be confirmed -> not claimed (timeout)" timeout 2

new_case checks-never-writes
rollup "" "$(check_run build COMPLETED FAILURE)"
echo log >"$STUB_DIR/joblog"
run_tool "$WFC" 7 "${FASTC[@]}"
if grep -qE 'run (rerun|cancel)|pr (edit|merge)|-X|--method' "$STUB_DIR/.calls"; then
  bad "observe only" "mutating call: $(cat "$STUB_DIR/.calls")"
else
  ok "observe only: no rerun/cancel/merge/mutating call"
fi

new_case checks-first-read-fails
echo '{}' >"$STUB_DIR/prview"
touch "$STUB_DIR/prview.fail"
run_tool "$WFC" 7 "${FASTC[@]}"
[ "$RC" = "3" ] && ok "a failing first gh read is a tool error (exit 3)" || bad "first read" "rc=$RC out=$OUT"

new_case checks-usage
run_tool "$WFC"
[ "$RC" = "3" ] && ok "missing PR argument is a usage error" || bad "usage" "rc=$RC"

echo
printf '%s\n' "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
