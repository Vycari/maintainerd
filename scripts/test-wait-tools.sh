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
BASE_SHA="dddddddd44444444444444444444444444444444"
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
  "pr view")
    case "$*" in
      # The re-read after verifying: "<head> <base>", the base being the case's unless prbase says
      # otherwise. A head-only re-read gets the head alone, so a tool that ignores the base is caught.
      *"--json headRefOid,baseRefOid,reviewDecision "*)
        h="$(serve prhead)" || exit 1
        b="$(cat "$STUB_DIR/prbase" 2>/dev/null || cat "$STUB_DIR/.base" 2>/dev/null)"
        # The decision is the PR fixture's as it stands now (the one the last poll read, without
        # advancing its sequence), so a verify stub that rewrites the fixture changes it.
        n="$(cat "$STUB_DIR/.count.prview" 2>/dev/null || echo 1)"
        f="$STUB_DIR/prview.$n"
        [ -f "$f" ] || f="$STUB_DIR/prview"
        [ -f "$f" ] || f="$(ls "$STUB_DIR"/prview.[0-9]* 2>/dev/null | sort | tail -n 1)"
        d="$(jq -r '.reviewDecision // ""' "$f" 2>/dev/null)"
        printf '%s %s %s\n' "$h" "${b:-dddddddd44444444444444444444444444444444}" "$d"
        ;;
      *"--json headRefOid "*) serve prhead ;;
      *) serve prview ;;
    esac
    ;;
  "api graphql") serve threads ;;
  "api -H")
    case "$*" in
      # The PR base's config (mechanical commits): the checkout's own unless a case says otherwise.
      *"?ref="*) if ls "$STUB_DIR"/basecfg* >/dev/null 2>&1; then serve basecfg; else cat "$STUB_DIR/../repo/.claude/maintainerd.json"; fi ;;
      *) serve remoteconfig ;;
    esac
    ;;
  "api repos/"*"/compare/"*)
    # The PR base's compare (mechanical commits): base...head, the base named by the case.
    b="$(cat "$STUB_DIR/.base" 2>/dev/null)"
    case "$2" in
      *"/compare/${b:-dddddddd}"*) if [ -f "$STUB_DIR/basecompare" ]; then serve basecompare; else serve compare; fi ;;
      *) serve compare ;;
    esac
    ;;
  "api repos/"*"/activity"*) serve activity ;;
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
  base="$(jq -n --arg head "$HEAD_SHA" --arg base "$BASE_SHA" '{
    number: 7, isDraft: false, state: "OPEN", labels: [], headRefOid: $head, headRefName: "feat",
    isCrossRepository: false, baseRefOid: $base, body: "",
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

new_case review-later-commit-link
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(printf '<h2>Confidence Score: 5/5</h2>\n<sub>Last reviewed commit: ["old"](https://github.com/o/r/commit/%s)</sub>\n(earlier round: [new](https://github.com/o/r/commit/%s))' "$OLD_SHA" "$HEAD_SHA")")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a later commit link in the text does not replace the one the label names" timeout 2

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
# --- rung 0: the check run, blockMarker, and the app/ normalizer ---------------------------------

CFG_CR='{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"],"checkName":"Vycari Review","checkApp":"vycari-review"}}'
# write_checks <app-slug> <status> <text> [oid] [conclusion] — adds the head commit's check suites to the threads fixture
write_checks() {
  jq -c --arg conclusion "${5:-SUCCESS}" --arg slug "$1" --arg status "$2" --arg text "$3" --arg oid "${4:-$HEAD_SHA}" '
    .data.repository.pullRequest.commits = {nodes: [{commit: {oid: $oid, checkSuites: {nodes: [
      {app: {slug: $slug}, checkRuns: {nodes: [{name: "Vycari Review", status: $status, conclusion: $conclusion,
        startedAt: "2026-10-08T00:00:00Z", completedAt: "2026-10-08T00:01:00Z", text: $text}]}}]}}}]}' \
    "$STUB_DIR/threads" >"$STUB_DIR/threads.tmp" && mv "$STUB_DIR/threads.tmp" "$STUB_DIR/threads"
}
cr_text() { # <score> <max> <sha>
  printf 'Round 1\n```json\n{"score": %s, "max": %s, "reviewed_sha": "%s", "round": 1, "open": {"p0": 0, "p1": 0, "p2": 0}, "findings": []}\n```\n' "$1" "$2" "$3"
}

new_case cr-valid
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "rung 0: 5/5 check run from the configured App on head -> approved" approved 0

new_case cr-below-threshold
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 3 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "rung 0: 3/5 with no open thread -> findings:0" "findings:0" 1

new_case cr-beats-greptile
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 2 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "rung 0 is the verdict: a Greptile 5/5 does not override a 2/5 check run" "findings:0" 1

new_case cr-open-thread
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[{"resolved":false,"path":"a.sh","line":1,"body":"P1: bug"}]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "rung 0: 5/5 with an unresolved thread is still findings" "findings:1" 1

new_case cr-wrong-app
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks evil-app COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "a same-named check run from another App is ignored -> timeout" timeout 2

new_case cr-wrong-app-falls-to-comment
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 4/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks evil-app COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "with a forged check run ignored, the lower rungs decide" "findings:0" 1

new_case cr-stale-sha
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$OLD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "a check run whose reviewed_sha is not the head is stale -> timeout" timeout 2

new_case cr-stale-then-current
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$OLD_SHA")"
cp "$STUB_DIR/threads" "$STUB_DIR/threads.1"
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
cp "$STUB_DIR/threads" "$STUB_DIR/threads.2"
rm -f "$STUB_DIR/threads"
run_tool "$WFR" 7 "${FAST[@]}"
expect "stale on poll 1, current on poll 2 -> approved" approved 0

new_case cr-in-progress
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review IN_PROGRESS "" 
run_tool "$WFR" 7 "${FAST[@]}"
expect "an in-progress check run keeps waiting, lower rungs do not pre-empt it" timeout 2

# write_suites <suites-json> [suites-hasNextPage] — the head commit's checkSuites connection, raw,
# for the cases that need several runs, ids, or page flags.
write_suites() {
  jq -c --argjson suites "$1" --argjson more "${2:-false}" --arg oid "$HEAD_SHA" '
    .data.repository.pullRequest.commits = {nodes: [{commit: {oid: $oid,
      checkSuites: {pageInfo: {hasNextPage: $more}, nodes: $suites}}}]}' \
    "$STUB_DIR/threads" >"$STUB_DIR/threads.tmp" && mv "$STUB_DIR/threads.tmp" "$STUB_DIR/threads"
}
cr_run() { # <databaseId> <status> [text] — a "Vycari Review" run; QUEUED carries no timestamps
  if [ "$2" = "COMPLETED" ]; then
    jq -n -c --argjson id "$1" --arg t "${3:-}" '{databaseId: $id, name: "Vycari Review", status: "COMPLETED",
      conclusion: "SUCCESS", startedAt: "2026-10-08T00:00:00Z", completedAt: "2026-10-08T00:01:00Z", text: $t}'
  else
    jq -n -c --argjson id "$1" --arg s "$2" '{databaseId: $id, name: "Vycari Review", status: $s,
      conclusion: null, startedAt: null, completedAt: null, text: null}'
  fi
}
cr_suite() { # <slug> <runs-json-array> [runs-hasNextPage]
  jq -n -c --arg slug "$1" --argjson runs "$2" --argjson more "${3:-false}" \
    '{app: {slug: $slug}, checkRuns: {pageInfo: {hasNextPage: $more}, nodes: $runs}}'
}

new_case cr-queued-rerun-hides-older-pass
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
# The queued re-run is listed AFTER the completed one, and has no timestamp to sort by: only its
# creation order (databaseId) says it is the newer one.
write_suites "[$(cr_suite vycari-review "[$(cr_run 100 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"), $(cr_run 200 QUEUED)]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "an older completed 5/5 plus a newer queued re-run keeps waiting -> timeout" timeout 2

new_case cr-queued-rerun-listed-first
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites "[$(cr_suite vycari-review "[$(cr_run 200 QUEUED), $(cr_run 100 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")")]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "a newer queued re-run wins whatever the list order -> timeout" timeout 2

new_case cr-newer-completed-beats-older-queued
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites "[$(cr_suite vycari-review "[$(cr_run 100 QUEUED), $(cr_run 200 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")")]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "a newer completed run supersedes an older stuck one -> approved" approved 0

new_case cr-newest-by-id-across-suites
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites "[$(cr_suite vycari-review "[$(cr_run 300 COMPLETED "$(cr_text 2 5 "$HEAD_SHA")")]"), $(cr_suite vycari-review "[$(cr_run 100 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")")]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "the newest run by id across suites decides (2/5 over an older 5/5) -> findings:0" "findings:0" 1

new_case cr-suites-truncated
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_suites "[$(cr_suite other-app '[]')]" true
run_tool "$WFR" 7 "${FAST[@]}"
expect "check suites truncated: never fall back to the lower rungs -> timeout" timeout 2
grep -q 'truncated' "$CASE/stderr" && ok "check suites truncated: the timeout says why" ||
  bad "truncation reason" "stderr: $(cat "$CASE/stderr")"

new_case cr-runs-truncated
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_suites "[$(cr_suite vycari-review "[$(cr_run 100 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")")]" true)]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "the App's check runs truncated: a newer run may be unseen -> timeout" timeout 2

new_case cr-other-app-runs-truncated
write_config "$CFG_CR"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites "[$(cr_suite other-app '[]' true), $(cr_suite vycari-review "[$(cr_run 100 COMPLETED "$(cr_text 5 5 "$HEAD_SHA")")]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "another App's truncated run list does not block rung 0 -> approved" approved 0

new_case cr-shadow-json
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 3/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA" | sed 's/"score"/"mode": "shadow", "score"/')"
run_tool "$WFR" 7 "${FAST[@]}"
expect "a shadow-mode (JSON mode) 5/5 check run is not a verdict; the 3/5 comment decides" "findings:0" 1

new_case cr-shadow-neutral
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 3/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA")" "$HEAD_SHA" NEUTRAL
run_tool "$WFR" 7 "${FAST[@]}"
expect "a NEUTRAL-conclusion 5/5 check run is not a verdict; the 3/5 comment decides" "findings:0" 1

new_case cr-malformed-text
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED 'not json at all {{'
run_tool "$WFR" 7 "${FAST[@]}"
expect "malformed output.text falls back to the comment rung" approved 0

new_case cr-malformed-fields
write_config "$CFG_CR"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 4/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED '```json
{"score": "five", "max": 5, "reviewed_sha": "aaaaaaa"}
```'
run_tool "$WFR" 7 "${FAST[@]}"
expect "well-formed JSON with a bad score field falls back to the lower rungs" "findings:0" 1

new_case cr-unconfigured
write_config "$CFG_5"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 1 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "unconfigured: a check run is never read, behaviour is unchanged" approved 0
if grep -q 'checkName' "$STUB_DIR/.calls"; then
  bad "unconfigured query" "sent the check-run query: $(cat "$STUB_DIR/.calls")"
else
  ok "unconfigured: the check-run query is not even sent"
fi

new_case cr-name-without-app
write_config '{"review":{"checkName":"Vycari Review"}}'
write_prview "" '.comments = []'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "checkName without checkApp is a config error (never name-only)" "" 3

new_case cr-empty-bots-with-check
write_config '{"review":{"approvalThreshold":"5/5","bots":[],"checkName":"Vycari Review","checkApp":"vycari-review"}}'
write_prview "" '.comments = []'
write_threads "" '[]'
write_checks vycari-review COMPLETED "$(cr_text 5 5 "$HEAD_SHA")"
run_tool "$WFR" 7 "${FAST[@]}"
expect "bots:[] with a check run configured still reads the check run" approved 0

new_case marker-custom
write_config '{"review":{"approvalThreshold":"5/5","bots":["vycari-review[bot]"],"blockMarker":"<!-- vycari_review -->"}}'
write_prview "" ".body = $(jq -Rs . <<<"intro<!-- vycari_review -->
$(greptile_text 5/5 aaaaaaa)
<!-- /vycari_review -->")"
BODY_EDITOR=vycari-review write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "review.blockMarker scopes the body block" approved 0

new_case marker-custom-ignores-default
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"],"blockMarker":"<!-- vycari_review -->"}}'
write_prview "" ".body = $(jq -Rs . <<<"<!-- greptile_comment -->
$(greptile_text 5/5 aaaaaaa)
<!-- /greptile_comment -->")"
BODY_EDITOR=greptile-apps write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "with a custom marker the old literal marker no longer counts" timeout 2

new_case bot-app-prefix
write_config '{"review":{"approvalThreshold":"5/5","bots":["app/greptile-apps"]}}'
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a configured app/<slug> login matches the GraphQL spelling" approved 0

new_case bot-app-prefix-actor
write_config "$CFG_5"
write_prview "" ".comments = [$(jq -n --arg b "$(greptile_text 5/5 aaaaaaa)" '{author: {login: "app/greptile-apps"}, body: $b}')]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "an author spelled app/<slug> matches a configured <slug>[bot]" approved 0

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

new_case checks-push-during-settle
rollup ".1" "$(check_run build COMPLETED SUCCESS)"
write_prview ".2" ".headRefOid = \"ccccccc3333333333333333333333333333333333\" | .statusCheckRollup = [$(check_run build COMPLETED SUCCESS)]"
write_prview ".3" ".headRefOid = \"ccccccc3333333333333333333333333333333333\" | .statusCheckRollup = [$(check_run build IN_PROGRESS '')]"
run_tool "$WFC" 7 -R o/r --timeout-seconds 4 --interval-seconds 1 --settle-seconds 1
expect "same check names green on a NEW head after the settle delay -> not green" timeout 2

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
# --- first-line mode: the VR stage, and covered staleness ----------------------------------------

CFG_FL='{"review":{"mode":"first-line","approvalThreshold":"5/5","bots":["greptile-apps[bot]"]}}'
# vr_run <databaseId> <title> <json-or-empty> [status] — the first-line reviewer's check run
vr_run() {
  jq -n -c --argjson id "$1" --arg title "$2" --arg t "$3" --arg status "${4:-COMPLETED}" '{databaseId: $id,
    name: "Vycari Review", status: $status, conclusion: "NEUTRAL", startedAt: "2026-10-16T00:00:00Z",
    completedAt: "2026-10-16T00:01:00Z", title: $title, text: (if $t == "" then null else ("```json\n" + $t + "\n```") end)}'
}
vr_json() { # <sha> <happy> <p0> <p1> <p2> <findings-json> <disputed-json> <escalated-json> <greptile_requested-json>
  jq -n -c --arg sha "$1" --argjson happy "$2" --argjson p0 "$3" --argjson p1 "$4" --argjson p2 "$5" \
    --argjson f "$6" --argjson d "$7" --argjson e "$8" --argjson g "$9" '{score: 4, max: 5, reviewed_sha: $sha,
    round: 1, mode: "first-line", open: {p0: $p0, p1: $p1, p2: $p2}, findings: $f, disputed: $d, escalated: $e,
    happy: $happy, greptile_requested: $g}'
}
vr_case() { # <case> <config> <title> <json> [status]
  new_case "$1"
  write_config "$2"
  write_prview "" '.comments = []'
  write_threads "" '[]'
  write_suites "[$(cr_suite vycari-review "[$(vr_run 100 "$3" "$4" "${5:-COMPLETED}")]")]"
}

vr_case vr-happy "$CFG_FL" "Confidence Score: 5/5" "$(vr_json "$HEAD_SHA" true 0 0 0 '[]' '[]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: a happy verdict is reported, not recomputed -> vr-happy" vr-happy 0

# A 3/5 that VR calls happy is happy: the script never works happiness out from the score.
vr_case vr-happy-is-read "$CFG_FL" "Confidence Score: 3/5" "$(vr_json "$HEAD_SHA" true 0 0 1 '[]' '[]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: happy comes from the JSON flag even with open P2s" vr-happy 0

vr_case vr-findings "$CFG_FL" "Confidence Score: 3/5" "$(vr_json "$HEAD_SHA" false 0 2 1 '["VR-aaaa1111","VR-bbbb2222","VR-cccc3333"]' '["VR-bbbb2222"]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: not happy, nothing handed off -> vr-findings:3" "vr-findings:3" 1
expect_contains "vr stage: finding ids are listed" "VR-aaaa1111"
expect_contains "vr stage: a disputed finding is marked" "VR-bbbb2222 (disputed)"
expect_not_contains "vr stage: an undisputed finding is not marked" "VR-aaaa1111 (disputed)"
expect_not_contains "vr stage: no other undisputed finding is marked" "VR-cccc3333 (disputed)"

# An id that is a prefix of a disputed one is a different finding: the match is exact, not substring.
vr_case vr-disputed-exact "$CFG_FL" "Confidence Score: 3/5" "$(vr_json "$HEAD_SHA" false 0 2 0 '["VR-ffff","VR-ffff6666"]' '["VR-ffff6666"]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: two findings, one disputed -> vr-findings:2" "vr-findings:2" 1
expect_contains "vr stage: the disputed id is marked" "VR-ffff6666 (disputed)"
expect_not_contains "vr stage: a prefix of a disputed id is not marked" "VR-ffff (disputed)"

vr_case vr-escalated "$CFG_FL" "Needs maintainer: P0 dispute (VR-dddd4444)" "$(vr_json "$HEAD_SHA" false 1 0 0 '["VR-dddd4444"]' '["VR-dddd4444"]' '["VR-dddd4444"]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: an escalated P0 dispute -> vr-escalated" vr-escalated 1
expect_contains "vr stage: the escalated id is named" "VR-dddd4444 (escalated)"

vr_case vr-escalated-by-title "$CFG_FL" "Needs maintainer: P0 dispute (VR-dddd4444)" "$(vr_json "$HEAD_SHA" false 1 0 0 '["VR-dddd4444"]' '[]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: the title alone marks an escalation" vr-escalated 1

vr_case vr-cap "$CFG_FL" "Confidence Score: 3/5" "$(vr_json "$HEAD_SHA" false 0 1 0 '["VR-eeee5555"]' '[]' '[]' "\"$HEAD_SHA\"")"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: round cap reached, head handed to the final reviewer -> vr-handoff" vr-handoff 0
expect_contains "vr stage: the unresolved findings are still listed" "VR-eeee5555"

vr_case vr-cap-other-head "$CFG_FL" "Confidence Score: 3/5" "$(vr_json "$HEAD_SHA" false 0 1 0 '["VR-eeee5555"]' '[]' '[]' "\"$OLD_SHA\"")"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: a hand-off recorded for another commit is not this head's -> vr-findings:1" "vr-findings:1" 1

vr_case vr-unavailable "$CFG_FL" "Review unavailable: model overloaded" ""
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: Review unavailable -> vr-unavailable, carry on with the final stage" vr-unavailable 0

vr_case vr-in-progress "$CFG_FL" "" "" IN_PROGRESS
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: a run still in progress keeps waiting -> timeout" timeout 2

vr_case vr-round-incomplete "$CFG_FL" "Round incomplete: judge unavailable" ""
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: Round incomplete keeps waiting -> timeout" timeout 2

vr_case vr-stale-head "$CFG_FL" "Confidence Score: 5/5" "$(vr_json "$OLD_SHA" true 0 0 0 '[]' '[]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: a verdict for an earlier commit is not this head's -> timeout" timeout 2

vr_case vr-unchanged-repost "$CFG_FL" "unchanged since bbbbbbb" "$(vr_json "$OLD_SHA" true 0 0 0 '[]' '[]' '[]' null)"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: an 'unchanged since' re-post is terminal for the head it sits on" vr-happy 0

new_case vr-no-run
write_config "$CFG_FL"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites '[]'
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: no VR run yet -> timeout (address-review owns the 60-minute escalation)" timeout 2

new_case vr-default-timeout-from-config
write_config '{"review":{"mode":"first-line","firstLine":{"unavailableMinutes":0},"waitTimeoutMinutes":0}}'
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites '[]'
run_tool "$WFR" 7 -R o/r --interval-seconds 1 --stage vr
expect "vr stage: review.waitTimeoutMinutes still overrides the default deadline" timeout 2

new_case vr-draft
write_config "$CFG_FL"
write_prview "" '.isDraft = true'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: a draft PR has nothing to wait for" no-review-scheduled 0

new_case vr-truncated
write_config "$CFG_FL"
write_prview "" '.comments = []'
write_threads "" '[]'
write_suites "[$(cr_suite vycari-review "[$(vr_run 100 "Confidence Score: 5/5" "$(vr_json "$HEAD_SHA" true 0 0 0 '[]' '[]' '[]' null)")]" true)]"
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "vr stage: truncated check data is never read as a verdict -> timeout" timeout 2

# Inert unless the mode is first-line.
new_case vr-stage-needs-mode
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"]}}'
write_prview "" '.comments = []'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}" --stage vr
expect "--stage vr without review.mode first-line is a tool error" "" 3

new_case vr-stage-bad-value
write_config "$CFG_FL"
write_prview "" '.comments = []'
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}" --stage bogus
expect "--stage rejects an unknown stage" "" 3

new_case vr-stage-on-checks
write_config "$CFG_FL"
echo '{}' >"$STUB_DIR/prview"
run_tool "$WFC" 7 -R o/r --timeout-seconds 3 --interval-seconds 1 --stage vr
expect "wait-for-checks.sh refuses --stage" "" 3

# Covered staleness.
cov_case() { # <case> <config> <greptile-score> <greptile-sha7> <compare-status> <vr-json> <threads-json>
  new_case "$1"
  write_config "$2"
  write_prview "" ".comments = [$(bot_comment "$(greptile_text "$3" "$4")")]"
  write_threads "" "$7"
  write_suites "[$(cr_suite vycari-review "[$(vr_run 100 "Confidence Score: 5/5" "$6")]")]"
  printf '%s' "$5" >"$STUB_DIR/compare"
}
HAPPY="$(vr_json "$HEAD_SHA" true 0 0 0 '[]' '[]' '[]' null)"
UNHAPPY="$(vr_json "$HEAD_SHA" false 0 1 0 '["VR-ffff6666"]' '[]' '[]' null)"
THREAD_OPEN='[{"resolved":false,"path":"a.py","line":3,"body":"P1 something"}]'

cov_case cov-ok "$CFG_FL" 5/5 bbbbbbb ahead "$HAPPY" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: Greptile 5/5 on an ancestor + VR happy on head + no open thread -> approved" approved 0
expect_contains "covered: the output says why the older score stands" "covered:"

cov_case cov-vr-unhappy "$CFG_FL" 5/5 bbbbbbb ahead "$UNHAPPY" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: VR not happy on head -> the score stays stale (timeout)" timeout 2

cov_case cov-open-thread "$CFG_FL" 5/5 bbbbbbb ahead "$HAPPY" "$THREAD_OPEN"
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: an open Greptile thread blocks it -> still stale (timeout)" timeout 2

cov_case cov-below-bar "$CFG_FL" 4/5 bbbbbbb ahead "$HAPPY" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: a score under the threshold is never covered -> timeout" timeout 2

cov_case cov-not-ancestor "$CFG_FL" 5/5 bbbbbbb diverged "$HAPPY" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: a score on a commit that is not an ancestor of head -> timeout" timeout 2

cov_case cov-compare-fails "$CFG_FL" 5/5 bbbbbbb ahead "$HAPPY" '[]'
touch "$STUB_DIR/compare.fail"
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: an unreadable ancestry check is not covered -> timeout" timeout 2

cov_case cov-vr-fallback "$CFG_FL" 5/5 bbbbbbb ahead "" '[]'
write_suites "[$(cr_suite vycari-review "[$(vr_run 100 "Review unavailable: x" "")]")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "covered: VR unavailable on head is a fallback, not a completed round -> timeout" timeout 2

cov_case cov-default-mode "$CFG_FL" 5/5 bbbbbbb ahead "$HAPPY" '[]'
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"]}}'
run_tool "$WFR" 7 "${FAST[@]}"
expect "inert: without review.mode first-line the same data stays stale (timeout)" timeout 2
if grep -q compare "$STUB_DIR/.calls"; then bad "inert: no compare call" "$(cat "$STUB_DIR/.calls")"; else ok "inert: no compare call without first-line mode"; fi

new_case fl-final-on-head
write_config "$CFG_FL"
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 aaaaaaa)")]"
write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "first-line mode: a Greptile 5/5 on the head still approves with no VR call" approved 0
expect_not_contains "first-line mode: no covered note when the score names the head" "covered:"

# Mechanical commits (review.mechanicalCommits): verified bot commits after a passing score. Each
# case's head is a real commit (mech_case); the fixed HEAD_SHA comes back after the section.
FIXED_HEAD_SHA="$HEAD_SHA"
# mech_commit <sha> <login|""> <verified> <message> [parents] [committer] [reason] -> one
# compare-API commit object (mech_compare rewrites the parent chain).
mech_commit() {
  jq -n -c --arg sha "$1" --arg login "$2" --argjson v "$3" --arg msg "$4" --argjson p "${5:-1}" \
    --arg cm "${6:-web-flow}" --arg why "${7:-valid}" '{
    sha: $sha, parents: [range($p) | {sha: "p"}],
    author: (if $login == "" then null else {login: $login} end),
    committer: (if $cm == "" then null else {login: $cm} end),
    commit: {message: $msg, verification: {verified: $v, reason: $why}}}'
}
MECH_MSG=$'chore: renumber\n\nExample-Bot: renumber'
# mech_compare <status> <commits-json-array> [files-json-array] -> compare fixture for
# $MECH_G...$HEAD_SHA: the last commit becomes the head and each commit's first parent the one
# before it (G for the first). Also writes the default activity: the bot pushed each commit alone.
MECH_FILES='[{"filename":"db/0002.sql"}]'
mech_compare() {
  jq -n -c --arg st "$1" --argjson c "$2" --argjson f "${3:-$MECH_FILES}" --arg g "$MECH_G" --arg h "$HEAD_SHA" '
    ($c | .[-1].sha = $h) as $c
    | ([$g] + [$c[].sha]) as $chain
    | {status: $st, base_commit: {sha: $g}, total_commits: ($c | length),
       commits: [range(0; $c | length) as $k | $c[$k] | .parents[0].sha = $chain[$k]], files: $f}' >"$STUB_DIR/compare"
  jq -c '([.base_commit.sha] + [.commits[].sha]) as $ch
    | [range(($ch | length) - 1; 0; -1) as $k
       | {activity_type: "push", before: $ch[$k - 1], after: $ch[$k], actor: {login: "example-bot[bot]"}}]' \
    "$STUB_DIR/compare" >"$STUB_DIR/activity"
}
# A verify command stub that records its argument and the commit it runs at; $1 is its exit status.
mech_verify() {
  mkdir -p "$CASE/bin"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/verified"\ngit rev-parse HEAD >>"%s/where" 2>/dev/null\nexit %s\n' \
    "$CASE" "$CASE" "$1" >"$CASE/bin/verify"
  chmod +x "$CASE/bin/verify"
}
mech_config() { # -> writes config with one entry whose verify is the stub
  write_config "$(jq -n -c --arg v "$CASE/bin/verify" '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
    mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
      verify: [$v, "--verify-commit", "{sha}"]}]}}')"
}
# mech_pr_base — commits the case repo as it stands as the PR's base commit (baseRefOid): the tree
# verify runs from. Later prview fixtures carry it.
mech_pr_base() {
  git -C "$CASE/repo" add -A >/dev/null 2>&1
  git -C "$CASE/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m 'pr base' >/dev/null 2>&1
  BASE_SHA="$(git -C "$CASE/repo" rev-parse HEAD)"
  printf '%s' "$BASE_SHA" >"$STUB_DIR/.base"
}
# mech_base <score> — commits the case repo as it stands (a new G) and points the score at it.
mech_base() {
  git -C "$CASE/repo" add -A >/dev/null 2>&1
  git -C "$CASE/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m base >/dev/null 2>&1
  MECH_G="$(git -C "$CASE/repo" rev-parse HEAD)"
  write_prview "" ".comments = [$(bot_comment "$(greptile_text "$1" "${MECH_G:0:7}")")]"
}
mech_case() { # <case> <score> <verify-exit>
  new_case "$1"
  git init -q "$CASE/repo" >/dev/null 2>&1
  mech_verify "$3"
  mech_config
  mech_pr_base
  mech_base "$2"
  # The head is a real commit after G: verify needs the range locally, so the tool checks for it.
  git -C "$CASE/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m head >/dev/null 2>&1
  HEAD_SHA="$(git -C "$CASE/repo" rev-parse HEAD)"
  git -C "$CASE/repo" checkout -q --detach "$MECH_G" >/dev/null 2>&1
  write_prview "" ".comments = [$(bot_comment "$(greptile_text "$2" "${MECH_G:0:7}")")]"
  printf '%s' "$HEAD_SHA" >"$STUB_DIR/prhead"
  write_threads "" '[]'
}
GOOD1="$(mech_commit c1 'example-bot[bot]' true "$MECH_MSG")"
GOOD2="$(mech_commit c2 'example-bot[bot]' true "$MECH_MSG" 1 'example-bot[bot]')"

mech_case mech-ok 5/5 0
mech_compare ahead "[$GOOD1,$GOOD2]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a passing score + verified bot commits that verify -> approved" approved 0
expect_contains "mechanical: the output says why the older score stands" "covered:"
expect_contains "mechanical: the output names the entry" "(renumber)"
[ "$(wc -l <"$CASE/verified")" = "2" ] && grep -q -- '--verify-commit c1' "$CASE/verified" &&
  ok "mechanical: verify ran once per commit with {sha} substituted" ||
  bad "mechanical: verify argv" "$(cat "$CASE/verified" 2>/dev/null)"
[ "$(sort -u "$CASE/where" 2>/dev/null)" = "$BASE_SHA" ] && ok "mechanical: verify ran in a checkout of the PR's base commit" ||
  bad "mechanical: verify location" "want $BASE_SHA; got $(cat "$CASE/where" 2>/dev/null)"

mech_case mech-below-bar 4/5 0
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a score under the bar is never covered -> timeout" timeout 2

mech_case mech-verify-fails 5/5 1
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: verify exiting non-zero -> stale (timeout)" timeout 2
[ "$(calls_of 'compare/')" -ge 2 ] && [ "$(wc -l <"$CASE/verified")" = "1" ] &&
  ok "mechanical: a failed verify is remembered, not re-run every poll" ||
  bad "mechanical: failed-verify cache" "compare calls $(calls_of 'compare/'); verified: $(cat "$CASE/verified" 2>/dev/null)"

mech_case mech-verify-missing 5/5 0
rm "$CASE/bin/verify"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: verify command missing -> stale (timeout)" timeout 2

mech_case mech-mixed-author 5/5 0
mech_compare ahead "[$GOOD1,$(mech_commit c3 someone true "$MECH_MSG")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: one human-authored commit in the range -> stale (timeout)" timeout 2

mech_case mech-null-author 5/5 0
mech_compare ahead "[$(mech_commit c3 '' true "$MECH_MSG")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an unlinked (null) author -> stale (timeout)" timeout 2

mech_case mech-unverified 5/5 0
mech_compare ahead "[$GOOD1,$(mech_commit c3 'example-bot[bot]' false "$MECH_MSG")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a commit GitHub does not verify -> stale (timeout)" timeout 2

mech_case mech-no-trailer 5/5 0
mech_compare ahead "[$(mech_commit c3 'example-bot[bot]' true 'chore: no trailer here')]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a commit without the trailer -> stale (timeout)" timeout 2

mech_case mech-trailer-in-subject 5/5 0
mech_compare ahead "[$(mech_commit c3 'example-bot[bot]' true 'chore: Example-Bot: not a trailer')]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the trailer must start a line -> stale (timeout)" timeout 2

mech_case mech-merge-commit 5/5 0
mech_compare ahead "[$(mech_commit c3 'example-bot[bot]' true "$MECH_MSG" 2)]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a merge commit (two parents) -> stale (timeout)" timeout 2

mech_case mech-touches-config 5/5 0
mech_compare ahead "[$GOOD1]" '[{"filename":".claude/maintainerd.json"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a range that edits the config file -> stale (timeout)" timeout 2

mech_case mech-truncated 5/5 0
mech_compare ahead "[$GOOD1]"
jq -c '.total_commits = 400' "$STUB_DIR/compare" >"$STUB_DIR/compare.new" && mv "$STUB_DIR/compare.new" "$STUB_DIR/compare"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a truncated compare page (commits) -> stale (timeout)" timeout 2

mech_case mech-truncated-files 5/5 0
mech_compare ahead "[$GOOD1]" "$(jq -n -c '[range(300) | {filename: "db/\(.).sql"}]')"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a truncated compare page (300 files) -> stale (timeout)" timeout 2

mech_case mech-diverged 5/5 0
mech_compare diverged "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a score on a non-ancestor -> stale (timeout)" timeout 2

mech_case mech-compare-fails 5/5 0
mech_compare ahead "[$GOOD1]"
touch "$STUB_DIR/compare.fail"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an unreadable compare -> stale (timeout)" timeout 2

mech_case mech-open-thread 5/5 0
mech_compare ahead "[$GOOD1]"
write_threads "" "$THREAD_OPEN"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: covered, but an open thread still yields findings" findings:1 1

mech_case mech-bad-entry 5/5 0
mech_compare ahead "[$GOOD1]"
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot"}]}}')"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an entry missing 'verify' covers nothing -> stale (timeout)" timeout 2

mech_case mech-absent 5/5 0
mech_compare ahead "[$GOOD1]"
write_config "$CFG_5"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: no review.mechanicalCommits -> today's behaviour (timeout)" timeout 2
if grep -q compare "$STUB_DIR/.calls"; then bad "mechanical: no compare call when unconfigured" "$(cat "$STUB_DIR/.calls")"; else ok "mechanical: no compare call when unconfigured"; fi

mech_case mech-score-on-head 5/5 0
write_prview "" ".comments = [$(bot_comment "$(greptile_text 5/5 "${HEAD_SHA:0:7}")")]"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a score on the head approves without covering" approved 0
expect_not_contains "mechanical: no covered note when the score names the head" "covered:"

mech_case mech-config-other-repo 5/5 0
mech_compare ahead "[$GOOD1]"
cp "$CASE/repo/.claude/maintainerd.json" "$CASE/cfg.json"
run_tool "$WFR" 7 -R x/other --config "$CASE/cfg.json" --timeout-seconds 3 --interval-seconds 1
expect "mechanical: --config for a repo that is not this checkout -> stale (timeout)" timeout 2
[ ! -f "$CASE/verified" ] && ok "mechanical: verify never ran in a foreign checkout" ||
  bad "mechanical: verify ran in a foreign checkout" "$(cat "$CASE/verified")"

mech_case mech-config-same-repo 5/5 0
mech_compare ahead "[$GOOD1]"
cp "$CASE/repo/.claude/maintainerd.json" "$CASE/cfg.json"
run_tool "$WFR" 7 -R o/r --config "$CASE/cfg.json" --timeout-seconds 3 --interval-seconds 1
expect "mechanical: --config for this checkout's own repo still covers" approved 0

mech_case mech-multiline-argv 5/5 0
mech_compare ahead "[$GOOD1]"
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", "true\nfalse", "{sha}"]}]}}')"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a multi-line verify script runs whole (its failing line fails it) -> timeout" timeout 2

mech_case mech-multiline-argv-ok 5/5 0
mech_compare ahead "[$GOOD1]"
write_config "$(jq -n -c --arg out "$CASE/argv" --arg h "$HEAD_SHA" '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", ("test \"$1\" = " + $h + "\nprintf %s \"$2\" >" + $out), "x", "{sha}", "two\nlines"]}]}}')"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a multi-line verify script that passes covers" approved 0
[ "$(cat "$CASE/argv" 2>/dev/null)" = $'two\nlines' ] && ok "mechanical: an argument with a newline reaches verify intact" ||
  bad "mechanical: newline argument" "$(cat "$CASE/argv" 2>/dev/null)"

mech_case mech-note-no-leak 5/5 0
write_config "$(jq -n -c --arg v "$CASE/bin/verify" '{review: {approvalThreshold: "approved", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: [$v, "--verify-commit", "{sha}"]}]}}')"
write_prview .1 ".reviewDecision = \"REVIEW_REQUIRED\" | .comments = [$(bot_comment "$(greptile_text 5/5 "${MECH_G:0:7}")")]"
write_prview .2 ".reviewDecision = \"APPROVED\" | .comments = [$(bot_comment "$(greptile_text 5/5 "${HEAD_SHA:0:7}")")]"
rm -f "$STUB_DIR/prview"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: approved mode, a later score on the head approves" approved 0
expect_not_contains "mechanical: a covered note from an earlier poll does not leak onto it" "covered:"

mech_case mech-cache 5/5 0
write_config "$(jq -n -c --arg v "$CASE/bin/verify" '{review: {approvalThreshold: "approved", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: [$v, "--verify-commit", "{sha}"]}]}}')"
write_prview "" ".reviewDecision = \"REVIEW_REQUIRED\" | .comments = [$(bot_comment "$(greptile_text 5/5 "${MECH_G:0:7}")")]"
mech_compare ahead "[$GOOD1,$GOOD2]"
run_tool "$WFR" 7 -R o/r --timeout-seconds 4 --interval-seconds 1
expect "mechanical: approved mode, no approval yet -> timeout" timeout 2
[ "$(calls_of 'compare/')" -ge 2 ] && [ "$(wc -l <"$CASE/verified")" = "2" ] &&
  ok "mechanical: each commit is verified once per run, not once per poll" ||
  bad "mechanical: verify cache" "compare calls $(calls_of 'compare/'); verified: $(cat "$CASE/verified" 2>/dev/null)"

mech_case mech-deadline 5/5 0
printf '#!/usr/bin/env bash\nsleep 5\n' >"$CASE/bin/verify"
mech_compare ahead "[$GOOD1]"
t0=$(date +%s)
run_tool "$WFR" 7 -R o/r --timeout-seconds 2 --interval-seconds 1
t1=$(date +%s)
expect "mechanical: a slow verify -> timeout" timeout 2
[ $((t1 - t0)) -le 4 ] && ok "mechanical: a slow verify cannot overrun the deadline" ||
  bad "mechanical: deadline" "took $((t1 - t0))s against a 2s deadline"

mech_case mech-verifier-in-range 5/5 0
mkdir -p "$CASE/repo/scripts"
printf '#!/bin/sh\nexit 0\n' >"$CASE/repo/scripts/check.sh"
chmod +x "$CASE/repo/scripts/check.sh"
mech_pr_base
mech_base 5/5
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["./scripts/check.sh", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]" '[{"filename":"db/0002.sql"},{"filename":"scripts/check.sh"}]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a range that edits the verifier itself -> stale (timeout)" timeout 2

# The verifier and what it reads come from the PR base, so a PR cannot weaken a file the verify
# argv does not name (a sourced library) before the scored commit.
mech_lib_case() { # <case> <base lib exit> <PR lib exit>
  mech_case "$1" 5/5 0
  printf 'check() { return %s; }\n' "$2" >"$CASE/repo/lib.sh"
  mech_pr_base
  printf 'check() { return %s; }\n' "$3" >"$CASE/repo/lib.sh"
  mech_base 5/5
  write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
    mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
      verify: ["sh", "-c", ". ./lib.sh && check", "x", "{sha}"]}]}}')"
  mech_compare ahead "[$GOOD1]"
}
mech_lib_case mech-verifier-from-base 1 0
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a PR that loosens a library the verifier sources is not trusted (base's fails) -> timeout" timeout 2

mech_lib_case mech-verifier-from-base-ok 0 1
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: verify runs the base's verifier and library (passes there) -> approved" approved 0
[ "$(git -C "$CASE/repo" worktree list --porcelain | grep -c '^worktree ')" = "1" ] &&
  ok "mechanical: the verify worktree is removed on exit" ||
  bad "mechanical: worktree left behind" "$(git -C "$CASE/repo" worktree list)"

# The base branch tightened its verifier after the PR branched: the base's version is the one run.
mech_case mech-base-tightened 5/5 0
mkdir -p "$CASE/repo/scripts"
printf '#!/bin/sh\nexit 0\n' >"$CASE/repo/scripts/check.sh"
chmod +x "$CASE/repo/scripts/check.sh"
mech_base 5/5
printf '#!/bin/sh\nexit 1\n' >"$CASE/repo/scripts/check.sh"
mech_pr_base
mech_base 5/5
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["scripts/check.sh", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a verifier the base tightened since the PR branched applies -> timeout" timeout 2

# A base whose entry changes between polls gets a fresh verify, never the old entry's cached pass.
mech_case mech-cache-entry-changed 5/5 0
jq -n -c '{review: {approvalThreshold: "approved", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["true", "{sha}"]}]}}' >"$STUB_DIR/basecfg.1"
jq -n -c '{review: {approvalThreshold: "approved", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["false", "{sha}"]}]}}' >"$STUB_DIR/basecfg.2"
write_config "$(cat "$STUB_DIR/basecfg.1")"
write_prview .1 ".reviewDecision = \"REVIEW_REQUIRED\" | .comments = [$(bot_comment "$(greptile_text 5/5 "${MECH_G:0:7}")")]"
write_prview .2 ".reviewDecision = \"APPROVED\" | .comments = [$(bot_comment "$(greptile_text 5/5 "${MECH_G:0:7}")")]"
rm -f "$STUB_DIR/prview"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the base's entry changed to a failing verify -> the old pass is not reused (timeout)" timeout 2

# The time limit holds against verifiers that resist it, and nothing they start survives it.
mech_case mech-term-exits-zero 5/5 0
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", "trap \"exit 0\" TERM; while :; do sleep 1; done", "x", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 -R o/r --timeout-seconds 2 --interval-seconds 1
expect "mechanical: a verify that exits 0 when stopped at its limit does not pass (timeout)" timeout 2

mech_case mech-term-ignored 5/5 0
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", "trap \"\" TERM; sleep 30", "x", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
t0=$(date +%s)
run_tool "$WFR" 7 -R o/r --timeout-seconds 2 --interval-seconds 1
t1=$(date +%s)
expect "mechanical: a verify that ignores TERM -> timeout" timeout 2
[ $((t1 - t0)) -le 7 ] && ok "mechanical: a verify that ignores TERM is killed, not waited on" ||
  bad "mechanical: TERM-resistant verify" "took $((t1 - t0))s against a 2s deadline"

mech_case mech-grandchild 5/5 0
write_config "$(jq -n -c --arg f "$CASE/leaked" '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", ("(sleep 4; touch " + $f + ") & sleep 30"), "x", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 -R o/r --timeout-seconds 2 --interval-seconds 1
expect "mechanical: a verify that forks and overruns -> timeout" timeout 2
sleep 5
[ ! -e "$CASE/leaked" ] && ok "mechanical: what a stopped verify started is stopped with it" ||
  bad "mechanical: grandchild survived" "$CASE/leaked exists"

mech_case mech-human-committer 5/5 0
mech_compare ahead "[$(mech_commit c1 'example-bot[bot]' true "$MECH_MSG" 1 someone)]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a bot-authored commit committed by a person -> stale (timeout)" timeout 2

mech_case mech-bad-signature-reason 5/5 0
mech_compare ahead "[$(mech_commit c1 'example-bot[bot]' true "$MECH_MSG" 1 web-flow unknown_key)]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: verification reason other than valid -> stale (timeout)" timeout 2

mech_case mech-human-push 5/5 0
mech_compare ahead "[$GOOD1,$GOOD2]"
jq -c '.[1].actor.login = "someone"' "$STUB_DIR/activity" >"$STUB_DIR/activity.new" && mv "$STUB_DIR/activity.new" "$STUB_DIR/activity"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a bot commit a person pushed (rebased in the web UI) -> stale (timeout)" timeout 2

mech_case mech-one-push 5/5 0
mech_compare ahead "[$GOOD1,$GOOD2]"
jq -n -c --arg g "$MECH_G" --arg h "$HEAD_SHA" \
  '[{activity_type: "push", before: $g, after: $h, actor: {login: "example-bot[bot]"}}]' >"$STUB_DIR/activity"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: one bot push carrying two commits covers both -> approved" approved 0

mech_case mech-push-unseen 5/5 0
mech_compare ahead "[$GOOD1,$GOOD2]"
jq -n -c --arg h "$HEAD_SHA" \
  '[{activity_type: "force_push", before: "elsewhere", after: $h, actor: {login: "example-bot[bot]"}}]' >"$STUB_DIR/activity"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a commit no bot push accounts for -> stale (timeout)" timeout 2

mech_case mech-activity-fails 5/5 0
mech_compare ahead "[$GOOD1]"
touch "$STUB_DIR/activity.fail"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an unreadable activity log -> stale (timeout)" timeout 2

mech_case mech-broken-chain 5/5 0
mech_compare ahead "[$GOOD1,$GOOD2]"
jq -c '.commits[1].parents[0].sha = "elsewhere"' "$STUB_DIR/compare" >"$STUB_DIR/compare.new" && mv "$STUB_DIR/compare.new" "$STUB_DIR/compare"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: commits that are not one chain from the scored commit -> stale (timeout)" timeout 2

mech_case mech-cross-repo 5/5 0
mech_compare ahead "[$GOOD1]"
write_prview "" ".isCrossRepository = true | .comments = [$(bot_comment "$(greptile_text 5/5 "${MECH_G:0:7}")")]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a PR from a fork -> stale (timeout)" timeout 2

mech_case mech-head-moved 5/5 0
mech_compare ahead "[$GOOD1]"
printf 'ccccccc3333333333333333333333333333333333' >"$STUB_DIR/prhead"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the head moved while verifying -> not covered (timeout)" timeout 2

# Review state that changes while verify runs: the stub verifier rewrites the PR fixtures mid-run.
# The wait must not report approved on the strength of the state it read before verify ran.
mech_case mech-decision-changes 5/5 0
mech_compare ahead "[$GOOD1]"
printf '#!/usr/bin/env bash\njq -c ".reviewDecision = \\"CHANGES_REQUESTED\\"" "%s/prview" >"%s/prview.new" && mv "%s/prview.new" "%s/prview"\nexit 0\n' \
  "$STUB_DIR" "$STUB_DIR" "$STUB_DIR" "$STUB_DIR" >"$CASE/bin/verify"
run_tool "$WFR" 7 "${FAST[@]}"
[ "$(printf '%s' "$OUT" | head -n 1)" != "approved" ] && ok "mechanical: a changes-requested review that lands during verify is never approved" ||
  bad "mechanical: decision changed mid-verify" "got: $OUT"
expect "mechanical: ...the next poll reports it (findings:0)" findings:0 1

mech_case mech-thread-opens 5/5 0
mech_compare ahead "[$GOOD1]"
NEW_THREADS="$(jq -c '.data.repository.pullRequest.reviewThreads.nodes = [{isResolved: false, isOutdated: false, path: "a.py", line: 3, originalLine: 3, comments: {nodes: [{body: "P1 late", author: {login: "someone"}}]}}]' "$STUB_DIR/threads")"
printf '#!/usr/bin/env bash\nprintf %%s %q >"%s/threads"\nexit 0\n' "$NEW_THREADS" "$STUB_DIR" >"$CASE/bin/verify"
run_tool "$WFR" 7 "${FAST[@]}"
[ "$(printf '%s' "$OUT" | head -n 1)" != "approved" ] && ok "mechanical: a thread that opens during verify is never approved" ||
  bad "mechanical: thread opened mid-verify" "got: $OUT"
expect "mechanical: ...the next poll reports it (findings:1)" findings:1 1

mech_case mech-base-moved 5/5 0
mech_compare ahead "[$GOOD1]"
printf 'eeeeeeee55555555555555555555555555555555' >"$STUB_DIR/prbase"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the base moved while verifying (its policy may be revoked) -> not covered (timeout)" timeout 2

mech_case mech-g-missing 5/5 0
mech_compare ahead "[$GOOD1]"
obj="$CASE/repo/.git/objects/${MECH_G:0:2}/${MECH_G:2}"
rm -f "$obj"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the scored commit is missing and the fetch fails -> not covered (timeout)" timeout 2
[ ! -f "$CASE/verified" ] && ok "mechanical: verify never runs without the scored commit" ||
  bad "mechanical: verify ran without G" "$(cat "$CASE/verified")"

mech_case mech-head-missing 5/5 0
mech_compare ahead "[$GOOD1]"
rm -f "$CASE/repo/.git/objects/${HEAD_SHA:0:2}/${HEAD_SHA:2}"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: the head is missing and the fetch fails -> not covered (timeout)" timeout 2
[ ! -f "$CASE/verified" ] && ok "mechanical: verify never runs without the range's commits" ||
  bad "mechanical: verify ran without the head" "$(cat "$CASE/verified")"

mech_case mech-user-lookalike 5/5 0
mech_compare ahead "[$(mech_commit c1 example-bot true "$MECH_MSG" 1 example-bot)]"
jq -c '.[].actor.login = "example-bot"' "$STUB_DIR/activity" >"$STUB_DIR/activity.new" && mv "$STUB_DIR/activity.new" "$STUB_DIR/activity"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a user login equal to the App's slug is not the App -> stale (timeout)" timeout 2

mech_case mech-app-form 5/5 0
write_config "$(jq -n -c --arg v "$CASE/bin/verify" '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "app/example-bot", trailer: "Example-Bot",
    verify: [$v, "--verify-commit", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an app/<slug> author is read as <slug>[bot] -> approved" approved 0

mech_case mech-base-lacks-entry 5/5 0
mech_compare ahead "[$GOOD1]"
printf '%s' "$CFG_5" >"$STUB_DIR/basecfg"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an entry the PR base's config does not carry covers nothing -> stale (timeout)" timeout 2

mech_case mech-basecfg-fails 5/5 0
mech_compare ahead "[$GOOD1]"
printf '%s' "$CFG_5" >"$STUB_DIR/basecfg"
touch "$STUB_DIR/basecfg.fail"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: an unreadable base config -> stale (timeout)" timeout 2

mech_case mech-base-touches-config 5/5 0
mech_compare ahead "[$GOOD1]"
jq -c '.files = [{"filename":".claude/maintainerd.json"},{"filename":"db/0002.sql"}]' "$STUB_DIR/compare" >"$STUB_DIR/basecompare"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a PR that edits the config before the scored commit -> stale (timeout)" timeout 2

mech_case mech-base-touches-verifier 5/5 0
mkdir -p "$CASE/repo/scripts"
printf '#!/bin/sh\nexit 0\n' >"$CASE/repo/scripts/check.sh"
chmod +x "$CASE/repo/scripts/check.sh"
mech_pr_base
mech_base 5/5
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["scripts/check.sh", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1]"
jq -c '.files = [{"filename":"scripts/check.sh"},{"filename":"db/0002.sql"}]' "$STUB_DIR/compare" >"$STUB_DIR/basecompare"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: a PR that edits the verifier before the scored commit -> stale (timeout)" timeout 2

mech_case mech-verify-mutates 5/5 0
write_config "$(jq -n -c '{review: {approvalThreshold: "5/5", bots: ["greptile-apps[bot]"],
  mechanicalCommits: [{name: "renumber", author: "example-bot[bot]", trailer: "Example-Bot",
    verify: ["sh", "-c", "test ! -e marker && touch marker", "x", "{sha}"]}]}}')"
mech_compare ahead "[$GOOD1,$GOOD2]"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical: each verify starts from a clean checkout of the base -> approved" approved 0

# First-line mode: mechanical coverage waives only "the score names the head". The first-line
# reviewer's happy round on the head and the no-open-thread condition still apply.
mech_fl_case() { # <case> <vr-happy:true|false> <threads-json>
  mech_case "$1" 5/5 0
  write_config "$(jq -n -c --arg v "$CASE/bin/verify" '{review: {mode: "first-line", approvalThreshold: "5/5",
    bots: ["greptile-apps[bot]"], mechanicalCommits: [{name: "renumber", author: "example-bot[bot]",
      trailer: "Example-Bot", verify: [$v, "--verify-commit", "{sha}"]}]}}')"
  write_threads "" "$3"
  write_suites "[$(cr_suite vycari-review "[$(vr_run 100 "Confidence Score: 5/5" \
    "$(vr_json "$HEAD_SHA" "$2" 0 0 0 '[]' '[]' '[]' null)")]")]"
  mech_compare ahead "[$GOOD1]"
}
mech_fl_case mech-fl-ok true '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical, first-line: VR happy on the head + no open thread -> approved" approved 0
expect_contains "mechanical, first-line: the output says why the older score stands" "covered:"

mech_fl_case mech-fl-vr-unhappy false '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical, first-line: VR not happy on the head -> not covered (timeout)" timeout 2

mech_fl_case mech-fl-open-thread true "$THREAD_OPEN"
run_tool "$WFR" 7 "${FAST[@]}"
expect "mechanical, first-line: an open thread -> not covered (timeout)" timeout 2

HEAD_SHA="$FIXED_HEAD_SHA"

new_case bare-marker
write_config '{"review":{"approvalThreshold":"5/5","bots":["greptile-apps[bot]"],"blockMarker":"greptile_comment"}}'
write_prview "" ".body = $(jq -Rs . <<<"<!-- greptile_comment -->
$(greptile_text 5/5 aaaaaaa)
<!-- /greptile_comment -->")"
BODY_EDITOR=greptile-apps write_threads "" '[]'
run_tool "$WFR" 7 "${FAST[@]}"
expect "a bare blockMarker name is read as its comment form" approved 0

echo
printf '%s\n' "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
