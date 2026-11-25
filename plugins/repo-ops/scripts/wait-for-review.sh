#!/usr/bin/env bash
#
# wait-for-review.sh — block until a PR's automated review reaches a verdict, then print it.
#
#   wait-for-review.sh <pr> [-R owner/repo] [--stage vr]
#
# Prints a verdict on the first line of stdout, and nothing is ever "still waiting":
#
#   approved               the bot's score meets review.approvalThreshold on the PR's HEAD commit
#                          AND there are 0 unresolved review threads. (With the default threshold
#                          "approved", GitHub's reviewDecision must be APPROVED instead.)
#   findings:<n>           the review of the HEAD commit is in and <n> review threads are
#                          unresolved. One indented line follows per finding: `path:line  body`.
#                          findings:0 means the score is below the threshold with no open thread —
#                          the shortfall is in the review summary, not on a line.
#   no-review-scheduled    nothing will review this PR: it is a draft, carries review.skipLabel,
#                          or review.bots is configured empty. With the skip label and a numeric
#                          threshold, a score a bot already published on the HEAD is still judged
#                          (approved / findings as usual); only when none is on the head is the
#                          label's verdict reported, with any older-commit score as a detail line.
#   timeout                no verdict by the deadline (review.waitTimeoutMinutes, default 20).
#
# First-line stage (only with review.mode "first-line"; --stage vr is an error otherwise). The
# first-line reviewer's check run (review.firstLine.checkName / checkApp) is read, and its verdict
# JSON is reported, never recomputed:
#
#   vr-happy               the reviewer says it is happy with the head (JSON "happy": true).
#   vr-handoff             not happy, but the reviewer has handed the head to the final reviewer
#                          (its round cap was reached): "greptile_requested" is the head. Findings
#                          still open are listed; they are no longer this stage's to chase.
#   vr-findings:<n>        a round for the head is in and <n> findings are open; one indented line
#                          per finding id follows ("(disputed)" marks one already disputed).
#   vr-escalated           a P0 dispute the reviewer still holds ("escalated" non-empty, or the
#                          title says "Needs maintainer: P0 dispute"). Stop and escalate.
#   vr-unavailable         the reviewer concluded "Review unavailable": it asked the final
#                          reviewer itself. Carry on with the final stage.
#
# Waiting continues for a queued/in-progress/superseded/"Round incomplete" run, for a verdict whose
# reviewed_sha is not the head (an "unchanged since <sha>" re-post is the exception: it is terminal
# for the head it sits on), and for check data truncated by page limits. The deadline defaults to
# review.firstLine.unavailableMinutes + 5 (45 + 5), or review.waitTimeoutMinutes when that is set.
# Exit status of the stage: 0 vr-happy / vr-handoff / vr-unavailable / no-review-scheduled,
# 1 vr-findings / vr-escalated, 2 timeout, 3 the tool could not run.
#
# In first-line mode the DEFAULT stage is still the final reviewer, with one addition, covered
# staleness: a score at or above the threshold on an ANCESTOR of the head (so every later commit
# was a fix to a passing review) still yields `approved`, when no review thread is open and the
# first-line reviewer is happy on the head itself. A second detail line says so. The first-line read
# comes last, and after it the head, the review decision, the open threads and the scores are read
# again: any change since the poll's read (a new below-bar score included) is not covered. Judging
# whether that score carried a P1 is the merge gate's job, as it is for a score on the head.
#
# Verified (first-line mode, default stage): a score BELOW the threshold on an ancestor G of the head
# also yields `approved` when the first-line reviewer verified the final reviewer's fixes instead of
# asking it for a second round (foreman's docs/design/vr-one-greptile-round.md §3-§4). The evidence
# is the first-line reviewer's check run on the head, never the "Verified:" text of its summary
# comment: from its App, concluded SUCCESS, happy, naming the head, and carrying
# "gate_fix_verified": {"verdict_sha": G, ...}. No review thread may be open, and the head may carry no
# check run of review.checkName (default "Greptile Review") from a review.bots App, in any state: a
# final review of the head is waited for and scored as usual. The same re-reads as covered staleness
# apply, then that check-run read, and last a read of every place a person can ask for a final round
# (issue comments, review bodies, inline review comments, each dated from its last edit): a request
# by anyone but the reviewers since the earliest of the round's start, the head's committer date, its
# earliest check suite's creation and the start of the final reviewer's own run on G (which predates
# the push) keeps the wait going. A second detail line (`verified:`) says
# so. Any doubt waits as before.
#
# Mechanical commits (review.mechanicalCommits, any mode; in first-line mode they waive only "the
# score names the head", so an approval still needs a happy first-line round on the head, and open
# threads are reported as findings): a score at or above the threshold on an
# ANCESTOR G of the head is not stale when G..head is one linear chain of verified mechanical
# commits of ONE configured entry: authored by its `author` login, committed by it or web-flow,
# GitHub-verified (reason "valid"), carrying its `trailer:` trailer, pushed to the branch by that
# login (activity API), and passing its `verify` argv ({sha} substituted) run from a detached
# worktree of the PR's base commit (so the verifier and everything it reads are the base branch's). A second detail line says so. Anything unreadable or doubtful (compare or activity
# data truncated, the range touching the config file or the verifier, a fork, no local checkout or
# no G, verify missing / failing / out of time, the head or base moving meanwhile, the review
# decision, the open threads or the scores changing meanwhile) is NOT covered, and a poll that ran
# verify and is not covered decides nothing: it never falls back to the first-line covered-staleness
# path on what it read before verify, and the next poll judges from a fresh read. The
# default stage only: --stage vr does not use it. Only entries in the PR base's config count, and a
# PR that edits the config or a verifier anywhere since its merge base is never covered.
#
# Exit status: 0 approved / no-review-scheduled, 1 findings, 2 timeout, 3 the tool could not run
# (bad usage, gh failure on the first read, invalid config). A verdict is never an error text and an
# error is never a verdict.
#
# It observes and reports. It never edits code, replies, resolves a thread, labels, or merges.
#
# Polls the SAME bot artifact each round. Scoring bots (Greptile) edit one comment or the PR
# description in place rather than posting anew, and that artifact names the commit it reviewed
# ("Last reviewed commit"). A score for any commit other than the PR's current head is STALE and
# counts as "no review yet" — it never satisfies the gate, whatever the number says, and a score
# whose commit cannot be read is treated the same way.
#
# Rung 0 (opt-in): when review.checkName AND review.checkApp are both set, a check run of that name
# on the PR's head commit, created by the App with that slug (the name alone proves nothing: any App
# can create a check run with any name), is the verdict. Its `output.text` carries a fenced JSON
# object `{score, max, reviewed_sha, ...}`; a reviewed_sha that is not the head is STALE (keep
# waiting), a shadow-mode run (conclusion NEUTRAL, or JSON "mode": "shadow") is never a verdict and is
# ignored like an unparseable one, a run still in progress keeps the wait going (the newest run by creation counts, so a
# queued re-run hides an older completed one), check data truncated by GitHub's page limits keeps
# the wait going too, and a run whose text cannot be parsed is ignored so the lower rungs decide. Unset = exactly the behaviour without rung 0.
#
# Config (.claude/maintainerd.json, see references/config-schema.md): review.waitTimeoutMinutes,
# review.approvalThreshold, review.bots, review.skipLabel, review.checkName, review.checkApp,
# review.blockMarker (a bare name such as `greptile_comment` is read as `<!-- greptile_comment -->`),
# review.mode, review.firstLine.checkName / checkApp / unavailableMinutes, review.mechanicalCommits.
# Flags for tests and tuning: --timeout-seconds N, --interval-seconds N (default 180, the floor a
# polite poller keeps against the API), --verify-seconds N (the cap on one mechanical-commit verify
# call, default 120), --config FILE.
#
# Requires: bash 3.2+, gh, jq.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wait-common.sh
. "$HERE/lib/wait-common.sh"

# This script owns one extra flag; peel it off before the shared parser sees it. --verify-seconds N
# caps one mechanical-commit verify call (default 120); it is a tuning and test flag.
MECH_VERIFY_CAP=120
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify-seconds)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      MECH_VERIFY_CAP="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
{ is_uint "$MECH_VERIFY_CAP" && [ "$MECH_VERIFY_CAP" -gt 0 ]; } || die 3 "--verify-seconds must be a positive integer"

WAIT_HELP=""
parse_common_args ${args[@]+"${args[@]}"}
if [ -n "$WAIT_HELP" ]; then
  sed -n '3,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ -n "$WAIT_PR" ] || die 3 "usage: wait-for-review.sh <pr> [-R owner/repo]"
[ -z "$WAIT_REST" ] || die 3 "unknown flag:$WAIT_REST"

resolve_repo
load_config

THRESHOLD="$(cfg '.review.approvalThreshold' 'approved')"
SKIP_LABEL="$(cfg '.review.skipLabel' '')"
TIMEOUT_MIN="$(cfg '.review.waitTimeoutMinutes' '20')"
CHECK_NAME="$(cfg '.review.checkName' '')"
CHECK_APP="$(cfg '.review.checkApp' '')"
BLOCK_MARKER="$(cfg '.review.blockMarker' '<!-- greptile_comment -->')"
[ -n "$BLOCK_MARKER" ] || BLOCK_MARKER='<!-- greptile_comment -->'
# A bare marker name (the repo profile spells it that way) is the same marker as its comment form.
case "$BLOCK_MARKER" in
  '<!--'*) ;;
  *) BLOCK_MARKER="<!-- $BLOCK_MARKER -->" ;;
esac
# First-line mode. Anything but the exact string "first-line" leaves every line below this block
# inert: no first-line key is read, no extra query is sent.
STAGE="${WAIT_STAGE:-final}"
case "$STAGE" in
  final | vr) ;;
  *) die 3 "--stage must be 'vr' or 'final' (final is the default)" ;;
esac
FIRST_LINE=0
if [ "$(cfg '.review.mode' '')" = "first-line" ]; then
  FIRST_LINE=1
  FL_NAME="$(cfg '.review.firstLine.checkName' 'Vycari Review')"
  FL_APP="$(cfg '.review.firstLine.checkApp' 'vycari-review')"
  FL_UNAVAILABLE_MIN="$(cfg '.review.firstLine.unavailableMinutes' '45')"
  is_uint "$FL_UNAVAILABLE_MIN" || die 3 "review.firstLine.unavailableMinutes must be a non-negative integer"
  # The verified read (verified_by_first_line): the final reviewer's own check run, by the name the
  # merge gate reads it by (review.checkName, default "Greptile Review") and owned by an App whose
  # slug is a review.bots login, and the mention that asks it for a round.
  FL_GATE_CHECK="$(cfg '.review.checkName' 'Greptile Review')"
  FL_REREVIEW="$(cfg '.review.rereviewCommand' '@greptileai review')"
fi
[ "$STAGE" != "vr" ] || [ "$FIRST_LINE" = "1" ] ||
  die 3 "--stage vr needs review.mode \"first-line\" in the repository's config"
# A name without an App is the name-only match rung 0 exists to refuse; an App without a name matches
# nothing. Either alone is a configuration error, not a silent fallback.
if [ -n "$CHECK_NAME" ] && [ -z "$CHECK_APP" ]; then
  die 3 "review.checkName needs review.checkApp: a check run is never trusted by name alone"
fi
if [ -z "$CHECK_NAME" ] && [ -n "$CHECK_APP" ]; then
  die 3 "review.checkApp needs review.checkName"
fi
is_uint "$TIMEOUT_MIN" || die 3 "review.waitTimeoutMinutes must be a non-negative integer"
if [ "$STAGE" = "vr" ] &&
  ! printf '%s' "$WAIT_CONFIG_JSON" | jq -e '(.review // {}).waitTimeoutMinutes != null' >/dev/null 2>&1; then
  TIMEOUT_MIN=$((FL_UNAVAILABLE_MIN + 5)) # the reviewer's own bound, plus the sweep's slack
fi
TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-$((TIMEOUT_MIN * 60))}"
INTERVAL="${WAIT_INTERVAL_SECONDS:-180}"

# review.bots: an absent key means the schema default; an explicit empty array means "no bot".
# Logins are compared with a leading "app/" (gh's spelling of an App actor) and the [bot] suffix
# stripped: REST says greptile-apps[bot], GraphQL says greptile-apps, `gh` can say app/greptile-apps,
# and a config naming one form must match the others.
NORM_LOGIN='sub("^app/"; "") | sub("\\[bot\\]$"; "")'
BOTS_JSON="$(printf '%s' "$WAIT_CONFIG_JSON" | jq -c '
  if (.review // {}) | has("bots") then .review.bots else ["coderabbitai[bot]","gemini-code-assist[bot]"] end
  | if type == "array" then map('"$NORM_LOGIN"') else error("bots") end')" ||
  die 3 "review.bots must be an array of logins"
# The reviewers' own logins (both stages), whose comments are never a person's re-review request.
REVIEWER_LOGINS_JSON="$BOTS_JSON"
if [ "$FIRST_LINE" = "1" ]; then
  REVIEWER_LOGINS_JSON="$(printf '%s' "$WAIT_CONFIG_JSON" | jq -c --argjson b "$BOTS_JSON" '
    ((.review // {}).firstLine // {}) | (if has("bots") then .bots else ["vycari-review[bot]"] end)
    | if type == "array" then map(select(type == "string") | '"$NORM_LOGIN"') + $b else $b end')" ||
    die 3 "review.firstLine.bots must be an array of logins"
fi

case "$THRESHOLD" in
  approved) THR_NUM="" THR_DEN="" ;;
  [0-9]*/[0-9]*)
    THR_NUM="${THRESHOLD%%/*}"
    THR_DEN="${THRESHOLD##*/}"
    if ! is_uint "$THR_NUM" || ! is_uint "$THR_DEN"; then
      die 3 "review.approvalThreshold '$THRESHOLD' is neither \"approved\" nor \"<n>/<m>\""
    fi
    ;;
  *) die 3 "review.approvalThreshold '$THRESHOLD' is neither \"approved\" nor \"<n>/<m>\"" ;;
esac

OWNER="${WAIT_REPO%%/*}"
NAME="${WAIT_REPO##*/}"

PR_FIELDS="number,isDraft,state,labels,headRefOid,headRefName,isCrossRepository,baseRefOid,body,comments,reviews,reviewDecision"
# The latest edit of the PR description is asked for alongside the threads: the description's score
# block is only evidence when a configured bot is who last wrote it (see find_scores).
THREADS_QUERY='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$number){
    reviewDecision
    userContentEdits(first:1){nodes{editor{login}}}
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{isResolved isOutdated path line originalLine comments(first:1){nodes{body author{login}}}}
    }}}}'

# Rung 0 asks GitHub for the head commit's check suites alongside the threads, but only when
# review.checkName is configured, so an unconfigured repo sends the query it always did. The App
# slug lives on the check SUITE; the run's name is filtered server side. `--paginate` advances only
# reviewThreads, so the check connections carry their own pageInfo: a truncated list could hide the
# newest run, and rung 0 then reports INCOMPLETE (keep waiting) rather than decide on part of it.
THREADS_QUERY_CHECKS='query($owner:String!,$name:String!,$number:Int!,$checkName:String!,$endCursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$number){
    reviewDecision
    userContentEdits(first:1){nodes{editor{login}}}
    commits(last:1){nodes{commit{oid committedDate checkSuites(first:50){pageInfo{hasNextPage} nodes{app{slug} createdAt
      checkRuns(first:20,filterBy:{checkName:$checkName}){pageInfo{hasNextPage}
        nodes{databaseId name status conclusion startedAt completedAt title text}}}}}}}
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{isResolved isOutdated path line originalLine comments(first:1){nodes{body author{login}}}}
    }}}}'

# check_run_score <graphql-json-stream> <head> — rung 0. Prints one of:
#   "checkrun:<app> <n>/<m> <reviewed_sha>"   a usable verdict (the caller still checks the sha)
#   "PENDING"                                  the App's newest run for the head is not completed
#   "INCOMPLETE"                               a check connection was truncated (hasNextPage), so
#                                              the newest run may be unseen: keep waiting, never
#                                              fall back to the lower rungs on partial data
#   nothing                                    no such run, or its output.text is not the contract
# Only a run on the head commit, created by the configured App slug, is looked at. The newest run
# BY CREATION wins (a re-run supersedes the earlier one), and only then is its status read: a queued
# re-run has neither startedAt nor completedAt, so ordering by those would let an older completed
# run's score stand in for it. Check-run databaseIds are allocated in creation order, and GraphQL's
# CheckRun exposes no createdAt, so the id is the creation order.
# newest_check_run <graphql-json-stream> <head> <app-slug> <name> — prints the newest run (by
# creation) named <name> on <head> from the App <app-slug> as one JSON object, or "INCOMPLETE" (a
# JSON string) when a check connection was truncated, or nothing when there is no such run.
newest_check_run() {
  printf '%s' "$1" | jq -s -c --arg app "$3" --arg name "$4" --arg head "$2" '
    [.[0].data.repository.pullRequest.commits.nodes[]? | select(.commit.oid == $head) | .commit.checkSuites]
    | if any(.[]; .pageInfo.hasNextPage == true
                  or any(.nodes[]? | select((.app.slug // "") == $app); .checkRuns.pageInfo.hasNextPage == true))
      then "INCOMPLETE"
      else [.[] | .nodes[]? | select((.app.slug // "") == $app)
            | .checkRuns.nodes[]? | select(.name == $name)]
           | sort_by(.databaseId // 0) | last // empty
      end' 2>/dev/null
}

# run_json_text <run-json> — the fenced (or bare) JSON object in the run's output.text.
run_json_text() {
  local text json
  text="$(printf '%s' "$1" | jq -r '.text // ""')"
  # The contract is a fenced JSON object; a bare JSON object is accepted too.
  json="$(printf '%s\n' "$text" | awk '/^[[:space:]]*```/{ if (f) exit; f = 1; next } f { print }')"
  [ -n "$json" ] || json="$text"
  printf '%s' "$json"
}

check_run_score() {
  local run json
  run="$(newest_check_run "$1" "$2" "$CHECK_APP" "$CHECK_NAME")" || return 0
  [ -n "$run" ] || return 0
  if [ "$run" = '"INCOMPLETE"' ]; then
    printf 'INCOMPLETE'
    return 0
  fi
  if [ "$(printf '%s' "$run" | jq -r '.status // ""')" != "COMPLETED" ]; then
    printf 'PENDING'
    return 0
  fi
  # A NEUTRAL conclusion is never a gate verdict: shadow-mode runs publish neutral and must not be
  # read as a score. (A run still in progress was handled above.)
  [ "$(printf '%s' "$run" | jq -r '.conclusion // ""')" != "NEUTRAL" ] || return 0
  json="$(run_json_text "$run")"
  printf '%s' "$json" | jq -r --arg app "$CHECK_APP" '
    select(type == "object"
      and (.mode // "") != "shadow"
      and (.score | type == "number" and . >= 0 and . == floor)
      and (.max | type == "number" and . > 0 and . == floor)
      and .score <= .max
      and (.reviewed_sha | type == "string" and test("^[0-9a-fA-F]{7,64}$")))
    | "checkrun:\($app) \(.score)/\(.max) \(.reviewed_sha)"' 2>/dev/null | head -n 1
  return 0
}

# vr_read <graphql-json-stream> <head> — the first-line reviewer's check run for <head>. Sets
# VR_KIND to one of: none (no such run yet), pending (keep waiting), happy, handoff, findings,
# escalated, unavailable; and VR_N / VR_DETAIL for findings. It reads the reviewer's verdict JSON and
# never works out happiness itself.
VR_KIND=""
VR_N=0
VR_DETAIL=""
VR_RUN=""  # the run vr_read judged, and its verdict JSON (the verified read needs both)
VR_JSON=""
vr_read() {
  local run title json head="$2" reviewed requested
  VR_KIND="none"
  VR_N=0
  VR_DETAIL=""
  VR_RUN=""
  VR_JSON=""
  run="$(newest_check_run "$1" "$head" "$FL_APP" "$FL_NAME")" || return 0
  [ -n "$run" ] || return 0
  if [ "$run" = '"INCOMPLETE"' ]; then
    VR_KIND="pending"
    LAST_ERR="first-line: the head commit's check suites/runs were truncated (hasNextPage); the check run may be unseen"
    return 0
  fi
  if [ "$(printf '%s' "$run" | jq -r '.status // ""')" != "COMPLETED" ]; then
    VR_KIND="pending"
    return 0
  fi
  title="$(printf '%s' "$run" | jq -r '.title // ""')"
  case "$title" in
    Superseded* | "Round incomplete"*)
      VR_KIND="pending" # a newer round is coming / the judge retries
      return 0
      ;;
    "Review unavailable"*)
      VR_KIND="unavailable"
      VR_DETAIL="  $title"
      return 0
      ;;
  esac
  json="$(run_json_text "$run")"
  if ! printf '%s' "$json" | jq -e 'type == "object" and (.mode // "") == "first-line"' >/dev/null 2>&1; then
    case "$title" in
      "Needs maintainer: P0 dispute"*)
        VR_KIND="escalated"
        VR_DETAIL="  $title"
        return 0
        ;;
    esac
    VR_KIND="pending" # unreadable: never guess a verdict
    LAST_ERR="first-line: the check run's output.text is not the first-line JSON contract"
    return 0
  fi
  VR_RUN="$run"
  VR_JSON="$json"
  # A pure-rebase re-post carries the earlier round's JSON on the new head: terminal for this head.
  # Any other verdict must name the head, or it is the previous head's.
  reviewed="$(printf '%s' "$json" | jq -r '.reviewed_sha // ""')"
  case "$title" in
    "unchanged since"*) ;;
    *)
      if ! is_head_sha "$reviewed" "$head"; then
        VR_KIND="pending"
        return 0
      fi
      ;;
  esac
  if [ "$(printf '%s' "$json" | jq '(.escalated // []) | length')" -gt 0 ] ||
    case "$title" in "Needs maintainer: P0 dispute"*) true ;; *) false ;; esac; then
    VR_KIND="escalated"
    VR_DETAIL="$(printf '%s' "$json" | jq -r '(.escalated // [])[] | "  \(.) (escalated)"')"
    [ -n "$VR_DETAIL" ] || VR_DETAIL="  $title"
    return 0
  fi
  if [ "$(printf '%s' "$json" | jq -r '.happy == true')" = "true" ]; then
    VR_KIND="happy"
    return 0
  fi
  VR_N="$(printf '%s' "$json" | jq -r '((.open.p0 // 0) + (.open.p1 // 0) + (.open.p2 // 0))')"
  is_uint "$VR_N" || VR_N=0
  # Bind each finding id before the lookup: inside `($j.disputed // []) | ...`, `.` is the disputed
  # list itself, so `index(.)` would mark every finding once anything at all is disputed.
  VR_DETAIL="$(printf '%s' "$json" | jq -r '. as $j | ($j.findings // [])[] | . as $id |
    "  \($id)" + (if (($j.disputed // []) | index([$id])) != null then " (disputed)" else "" end)')"
  requested="$(printf '%s' "$json" | jq -r '.greptile_requested // ""')"
  if [ -n "$requested" ] && is_head_sha "$requested" "$head"; then
    VR_KIND="handoff"
    return 0
  fi
  VR_KIND="findings"
  return 0
}

# fetch_gql [check-name] — the PR's review threads, plus the head commit's check runs of that name
# when one is given. The one place the GraphQL query is sent.
fetch_gql() {
  if [ -n "$1" ]; then
    gh api graphql --paginate -f query="$THREADS_QUERY_CHECKS" -F owner="$OWNER" -F name="$NAME" -F number="$WAIT_PR" -f checkName="$1" 2>&1
  else
    gh api graphql --paginate -f query="$THREADS_QUERY" -F owner="$OWNER" -F name="$NAME" -F number="$WAIT_PR" 2>&1
  fi
}

# unresolved_threads <graphql-json-stream> — the open review threads of a fetch_gql result, as one
# compact JSON array. poll_once and the mechanical re-read share it so both judge "open" alike.
unresolved_threads() {
  printf '%s' "$1" | jq -s -c '
    [.[] | .data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)]'
}

# mechanical_entries [config-json] — prints the valid review.mechanicalCommits entries of the given
# config (default: the loaded one) as compact JSON lines. An
# entry missing a field, or of the wrong type, is dropped (fail closed: it can only cover less), and
# so is one whose verify argv holds a NUL, which no argv can carry.
mechanical_entries() {
  printf '%s' "${1:-$WAIT_CONFIG_JSON}" | jq -c '
    ((.review // {}).mechanicalCommits // []) | if type == "array" then .[] else empty end
    | select(type == "object"
        and (.name | type == "string" and length > 0)
        and (.author | type == "string" and length > 0)
        and (.trailer | type == "string" and length > 0)
        and (.verify | type == "array" and length > 0
          and all(.[]; type == "string" and (explode | any(. == 0) | not))))' 2>/dev/null
}

# Mechanical-commit state that lives for the whole run (poll_once runs in this shell, never in a
# subshell). MECH_CACHE holds " <base>:<entry-digest>:<sha>=<0|1> " verdicts so a commit's verify runs
# once per run, not once per poll; the key names the base commit and the entry's whole content, so a
# base branch that changes its verifier or its entry gets a fresh run. A verify that timed out or died
# on a signal is not cached, so it is tried again while time is left. MECH_WT_ROOT holds the detached
# worktrees verify runs in.
MECH_CACHE=" "
MECH_WT_ROOT=""
MECH_TOP=""
MECH_WT=""
MECH_HEAD_REF=""
MECH_CROSS=""
MECH_BASE=""
MECH_DECISION="" # the review decision and the open threads poll_once judged on; the final re-read
MECH_THREADS=""  # must find both unchanged
MECH_SCORES=""   # the scores poll_once judged on; fl_read must find them unchanged
MECH_HOLD=0      # 1 when this poll ran verify (or a fetch) and was not covered: it decides nothing
MECH_HELD=0      # 1 when the previous poll held: this one tries the first-line path first
MECH_SECS=0
mech_cleanup() {
  local wt
  [ -n "$MECH_WT_ROOT" ] || return 0
  for wt in "$MECH_WT_ROOT"/*; do
    [ -d "$wt" ] || continue
    git -C "$MECH_TOP" worktree remove --force "$wt" >/dev/null 2>&1
  done
  rm -rf "$MECH_WT_ROOT"
  git -C "$MECH_TOP" worktree prune >/dev/null 2>&1
  return 0
}
trap mech_cleanup EXIT

# run_bounded <seconds> <argv...> — runs argv with stdin/stdout/stderr on /dev/null, in a process
# group of its own, and stops it after <seconds>: TERM to the whole group, then KILL to the group
# RB_GRACE seconds later. Exit status is argv's, or 124 whenever the time limit fired (even if argv
# then exited 0 from a TERM handler), or >= 128 for a signal. Whatever argv leaves running in its
# group is killed when it returns. One implementation everywhere, so timeout(1)'s presence or flavour
# changes nothing. A process that moves itself to another session (setsid) is out of reach.
RB_GRACE=2
run_bounded() {
  local secs="$1" pid wd flag rc
  shift
  flag="$(mktemp 2>/dev/null)" || return 1
  rm -f "$flag"
  set -m
  "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  (sleep "$secs" && : >"$flag" && kill -TERM -- "-$pid" && sleep "$RB_GRACE" && kill -KILL -- "-$pid") </dev/null >/dev/null 2>&1 &
  wd=$!
  set +m
  wait "$pid" 2>/dev/null
  rc=$?
  kill -KILL -- "-$wd" >/dev/null 2>&1
  wait "$wd" 2>/dev/null
  kill -KILL -- "-$pid" >/dev/null 2>&1
  if [ -e "$flag" ]; then
    rm -f "$flag"
    return 124
  fi
  return "$rc"
}

# mech_budget <max-seconds> — sets MECH_SECS to <max-seconds> clipped to what is left of the wait's
# deadline; fails when nothing is left.
mech_budget() {
  local left
  left=$((deadline - $(now)))
  [ "$left" -gt 0 ] || return 1
  MECH_SECS="$1"
  [ "$left" -ge "$MECH_SECS" ] || MECH_SECS="$left"
}

# Git run on the verifier's behalf, as an argv prefix (run_bounded's timeout(1) cannot run a shell
# function): no hooks, no LFS smudge, no credential or ssh prompt.
MECH_GIT=(env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"
  git -c core.hooksPath=/dev/null)

# mech_worktree <base> — sets MECH_WT to a detached worktree of this checkout at the PR's base commit
# (made once per base per run; called directly, never in $(...), so the cleanup trap sees what it
# made). The verifier runs there: the base branch's verifier, reading the base branch's files, never
# the working tree's or anything the PR changed. The PR's commits are still objects in the shared
# store, so `git show {sha}` and the like work. Fails when <base> is not available locally.
mech_worktree() {
  local b="$1" wt
  MECH_WT=""
  if [ -z "$MECH_TOP" ]; then
    MECH_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$MECH_TOP" ] || return 1
  fi
  if [ -z "$MECH_WT_ROOT" ]; then
    MECH_WT_ROOT="$(mktemp -d 2>/dev/null)" || return 1
    [ -n "$MECH_WT_ROOT" ] || return 1
  fi
  wt="$MECH_WT_ROOT/$b"
  if [ ! -d "$wt" ]; then
    mech_budget 60 || return 1
    # A worktree add that fails may have run up to its bound: hold, as for a reset.
    run_bounded "$MECH_SECS" "${MECH_GIT[@]}" -C "$MECH_TOP" worktree add --detach --quiet "$wt" "$b" || {
      MECH_HOLD=1
      return 1
    }
  fi
  MECH_WT="$wt"
}

# mech_reset <worktree> <base> — puts the worktree back to a clean checkout of <base>, so one verify
# run cannot leave anything behind for the next. Bounded by the wait's deadline like the verify.
mech_reset() {
  mech_budget 60 || return 1
  run_bounded "$MECH_SECS" "${MECH_GIT[@]}" -C "$1" checkout -q -f --detach "$2" || return 1
  mech_budget 60 || return 1
  run_bounded "$MECH_SECS" "${MECH_GIT[@]}" -C "$1" clean -q -f -d -x || return 1
  mech_budget 60 || return 1
  run_bounded "$MECH_SECS" sh -c '[ "$(git -C "$1" rev-parse HEAD)" = "$2" ] && [ -z "$(git -C "$1" status --porcelain --ignored)" ]' sh "$1" "$2"
}

# range_covered_by_entry <entry-json> <compare-json> <activity-json> <G> — true when
# EVERY commit in the compare range is a verified mechanical commit of this entry (the range's shape,
# chain and config-file checks are the caller's). Sets MECH_COUNT / MECH_NAME for the note.
#
# Who made a commit is bound by three things GitHub records and a person cannot forge alone: the
# author login (GitHub's mapping of the author email), the committer login (the bot itself, or
# `web-flow` when GitHub made the commit on its behalf), and the push that put the commit on the
# branch (the activity API's actor). Commit metadata alone is not enough: GitHub re-signs commits
# as `web-flow` when a person rebases a branch in the web UI, so a person's action can yield a
# commit that is authored by the bot, committed by web-flow and verified. The push actor is what
# tells those apart.
range_covered_by_entry() {
  local entry="$1" cmp="$2" act="$3" g="$4" author trailer chain sha i key secs rc wt digest
  local -a verify
  MECH_COUNT=0
  MECH_NAME="$(printf '%s' "$entry" | jq -r .name)"
  # Logins compare exactly. A GitHub App's account is `<slug>[bot]` and no user login can contain
  # brackets, so stripping the suffix would let a user who owns the bare `<slug>` login pass as the
  # App. A configured `app/<slug>` is read as `<slug>[bot]`.
  author="$(printf '%s' "$entry" | jq -r '.author | if startswith("app/") then (.[4:] + "[bot]") else . end')"
  trailer="$(printf '%s' "$entry" | jq -r .trailer)"
  # Every commit: authored and committed by the entry's login (or committed by GitHub's web-flow on
  # its behalf), verified with reason "valid", carrying the trailer.
  printf '%s' "$cmp" | jq -e --arg a "$author" --arg t "$trailer" '
    def login: (. // "");
    .commits | all(.[];
      (.author.login | login) == $a
      and ((.committer.login | login) as $c | $c == $a or $c == "web-flow")
      and (.commit.verification.verified == true)
      and (.commit.verification.reason == "valid")
      and ((.commit.message // "") | split("\n") | any(.[]; startswith($t + ":"))))' >/dev/null 2>&1 || return 1
  # Every commit was put on the branch by a push whose actor is the entry's login. A push from
  # <before> to <after> introduced the chain commits after <before> up to <after> when <before> is
  # on the chain below <after>; otherwise it is only evidence for <after> itself. One page of
  # activity: a commit the page does not attribute is not covered.
  chain="$(printf '%s' "$cmp" | jq -c --arg g "$g" '[$g] + [.commits[].sha]')" || return 1
  printf '%s' "$act" | jq -e --arg a "$author" --argjson chain "$chain" '
    def login: (. // "");
    type == "array"
    and ([.[]
        | select((.activity_type == "push" or .activity_type == "force_push") and ((.actor.login | login) == $a))
        | . as $p
        | ($chain | index($p.after)) as $j
        | select($j != null and $j >= 1)
        | ($chain | index($p.before)) as $i
        | if $i != null and $i < $j then range($i + 1; $j + 1) else $j end] as $cov
      | all(range(1; $chain | length); . as $k | $cov | any(.[]; . == $k)))' >/dev/null 2>&1 || return 1
  # The verifier must not be one of the files the range changes: it would be vouching for itself.
  printf '%s' "$cmp" | jq -e --argjson e "$entry" '
    [.files[] | .filename, (.previous_filename // empty)] as $f
    | [$e.verify[] | sub("^(\\./)+"; "")] | any(.[]; . as $x | $f | any(.[]; . == $x)) | not' >/dev/null 2>&1 || return 1
  digest="$(printf '%s' "$entry" | jq -c -S . | git hash-object --stdin 2>/dev/null)" || return 1
  [ -n "$digest" ] || return 1
  mech_worktree "$MECH_BASE" || return 1
  wt="$MECH_WT"
  while IFS= read -r sha; do
    [ -n "$sha" ] || return 1
    # The deadline is checked for every commit, cached or not.
    mech_budget 1 || return 1
    key="$MECH_BASE:$digest:$sha"
    case "$MECH_CACHE" in
      *" $key=1 "*)
        MECH_COUNT=$((MECH_COUNT + 1))
        continue
        ;;
      *" $key=0 "*) return 1 ;;
    esac
    # Each verify starts from a clean checkout of the base whatever the previous run did to it, and
    # gets at most MECH_VERIFY_CAP (120s), clipped to what is left of the wait's deadline. A verify
    # that hangs until the deadline leaves no time for the next poll's first-line path: the wait
    # then reports timeout, never an approval from the state read before verify.
    # A reset that fails holds too: it may have used up to its whole bound (a hang), and what the
    # poll read before it is then as stale as after a verify. Holding costs one interval at most.
    mech_reset "$wt" "$MECH_BASE" || {
      MECH_HOLD=1
      return 1
    }
    mech_budget "$MECH_VERIFY_CAP" || return 1
    secs="$MECH_SECS"
    verify=()
    # NUL-separated: an argument may itself hold newlines (a multi-line `sh -c` script).
    while IFS= read -r -d '' i; do verify+=("${i//\{sha\}/$sha}"); done < <(printf '%s' "$entry" | jq -j '.verify[] | ., "\u0000"')
    [ "${#verify[@]}" -gt 0 ] || return 1
    # From here this poll runs verify, so it holds unless the cover succeeds: what the poll read
    # before verify is stale by the time it ends, whatever verify's outcome (see covered_by_mechanical).
    MECH_HOLD=1
    (cd "$wt" && run_bounded "$secs" "${verify[@]}")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 124 ] || [ "$rc" -ge 128 ] || MECH_CACHE="$MECH_CACHE$key=0 "
      return 1
    fi
    MECH_CACHE="$MECH_CACHE$key=1 "
    MECH_COUNT=$((MECH_COUNT + 1))
  done < <(printf '%s' "$cmp" | jq -r '.commits[].sha')
  [ "$MECH_COUNT" -gt 0 ]
}

# covered_by_mechanical <scores> <head> — true when every published score names an ancestor of the
# head (or the head) and each stale one's range is covered by one configured mechanical entry. The
# bar is checked by the caller. Anything unreadable is "not covered".
MECH_NOTE=""
covered_by_mechanical() {
  local scores="$1" head="$2" line bot score reviewed entry ok total=0 name="" first="" cmp act g now_head
  local basecfg entries bcmp now_pr now_gql now_threads now_scores
  MECH_NOTE=""
  MECH_HOLD=0
  [ -n "$scores" ] || return 1
  [ -n "$(mechanical_entries)" ] || return 1
  # A verify command runs in the checkout; when the config was fetched for another repo there is none.
  [ "${WAIT_CONFIG_LOCAL:-0}" = "1" ] || return 1
  # A fork's branch is pushed outside this repo: its activity is not this repo's to read.
  [ "$MECH_CROSS" = "false" ] && [ -n "$MECH_HEAD_REF" ] || return 1
  printf '%s' "$MECH_BASE" | grep -Eq '^[0-9a-f]{40}$' || return 1
  # The entries that count are the PR base's, never the PR's own: the working tree is usually the PR
  # branch, and a PR could otherwise add an entry (or a permissive verifier) before the scored
  # commit and then cover its own later commits with it.
  mech_budget 1 || return 1
  basecfg="$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$WAIT_REPO/contents/.claude/maintainerd.json?ref=$MECH_BASE" 2>/dev/null)" || return 1
  entries="$(mechanical_entries "$basecfg")"
  [ -n "$entries" ] || return 1
  # Nothing the PR changes, from its merge base to the head, may be the config or a file a verify
  # argument names. One page only: 300 files or more is not covered.
  mech_budget 1 || return 1
  bcmp="$(gh api "repos/$WAIT_REPO/compare/$MECH_BASE...$head" 2>/dev/null)" || return 1
  printf '%s' "$bcmp" | jq -e --argjson e "$(printf '%s' "$entries" | jq -s -c '[.[].verify[] | sub("^(\\./)+"; "")]')" '
    (.files | type == "array") and (.files | length) < 300
    and ([.files[] | .filename, (.previous_filename // empty)]
      | any(.[]; . == ".claude/maintainerd.json" or (. as $x | $e | any(.[]; . == $x))) | not)' >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bot="${line%% *}"
    score="$(printf '%s' "$line" | cut -d' ' -f2)"
    reviewed="$(printf '%s' "$line" | cut -d' ' -f3)"
    [ -n "$reviewed" ] || return 1
    [ -n "$first" ] || first="$bot $score on ${reviewed:0:7}"
    is_head_sha "$reviewed" "$head" && continue
    mech_budget 1 || return 1
    cmp="$(gh api "repos/$WAIT_REPO/compare/$reviewed...$head" 2>/dev/null)" || return 1
    # One page only (<=250 commits, <=300 files): a truncated range is not covered. The range is one
    # linear chain from the reviewed commit G to the head: each commit's only parent is the one
    # before it, so no commit outside the list is part of what the head contains.
    printf '%s' "$cmp" | jq -e --arg r "$reviewed" --arg h "$head" '
      .status == "ahead" and (.commits | type == "array") and (.commits | length) > 0
      and (.total_commits == (.commits | length)) and (.commits | length) <= 250
      and (.files | type == "array") and (.files | length) < 300
      and ((.base_commit.sha // "") | test("^[0-9a-f]{40}$") and startswith($r))
      and (.commits[-1].sha == $h)' >/dev/null 2>&1 || return 1
    g="$(printf '%s' "$cmp" | jq -r '.base_commit.sha')"
    printf '%s' "$cmp" | jq -e --arg g "$g" '
      ([$g] + [.commits[].sha]) as $chain
      | [range(0; .commits | length) as $k | .commits[$k]
          | ((.parents | length) == 1 and .parents[0].sha == $chain[$k])] | all' >/dev/null 2>&1 || return 1
    # A range that edits the config could have rewritten the entry that vouches for it.
    printf '%s' "$cmp" | jq -e '[.files[] | .filename, (.previous_filename // empty)]
      | any(. == ".claude/maintainerd.json") | not' >/dev/null 2>&1 || return 1
    mech_budget 1 || return 1
    act="$(gh api "repos/$WAIT_REPO/activity?ref=$(printf '%s' "refs/heads/$MECH_HEAD_REF" | jq -sRr @uri)&per_page=100" 2>/dev/null)" || return 1
    # Verify runs from the base and inspects the range's commits; fetch them when they are missing.
    if ! git cat-file -e "$MECH_BASE^{commit}" 2>/dev/null || ! git cat-file -e "$g^{commit}" 2>/dev/null ||
      ! git cat-file -e "$head^{commit}" 2>/dev/null; then
      MECH_HOLD=1 # a fetch takes time too: hold as for verify
      mech_budget 60 && run_bounded "$MECH_SECS" "${MECH_GIT[@]}" fetch -q --no-tags origin "$MECH_BASE" "$g" "$head"
    fi
    # The base (the verifier's tree), G and the head (so the whole range) must all be here now,
    # however the fetch went: a commit the verifier cannot see is not one it vouched for.
    git cat-file -e "$MECH_BASE^{commit}" 2>/dev/null || return 1
    git cat-file -e "$g^{commit}" 2>/dev/null || return 1
    git cat-file -e "$head^{commit}" 2>/dev/null || return 1
    ok=0
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if range_covered_by_entry "$entry" "$cmp" "$act" "$g"; then
        ok=1
        total=$((total + MECH_COUNT))
        name="$MECH_NAME"
        break
      fi
    done <<<"$entries"
    [ "$ok" = "1" ] || return 1
  done <<<"$scores"
  [ "$total" -gt 0 ] || return 1
  # Verifying took time: the head it covered must still be the head, and the base whose config and
  # verifier vouched for it must still be the base. The review decision, the open threads and the
  # scores were read before verify ran, so a human's "changes requested", a new thread or a new
  # score that landed meanwhile must show here too: any change means not covered. The answer must
  # also arrive before the deadline. A poll that ran verify or a fetch already holds (MECH_HOLD), so
  # a verify that failed or timed out did too; from here on every way out but success holds, cached
  # verdicts or not: a change, running out of time, or a read or parse that fails, since a failed
  # read cannot show that nothing changed. The caller must not fall back to another
  # covered-staleness path, or judge anything else, on the state it read before verify ran.
  MECH_HOLD=1
  mech_budget 1 || return 1
  now_pr="$(gh pr view "$WAIT_PR" -R "$WAIT_REPO" --json headRefOid,baseRefOid,reviewDecision,body,comments,reviews 2>/dev/null)" || return 1
  now_head="$(printf '%s' "$now_pr" | jq -r '"\(.headRefOid) \(.baseRefOid) \(.reviewDecision // "")"' 2>/dev/null)" || return 1
  [ "$now_head" = "$head $MECH_BASE $MECH_DECISION" ] || return 1
  mech_budget 1 || return 1
  now_gql="$(fetch_gql "$CHECK_NAME")" || return 1
  now_threads="$(unresolved_threads "$now_gql")" || return 1
  [ "$now_threads" = "$MECH_THREADS" ] || return 1
  now_scores="$(scores_of "$now_pr" "$now_gql" "$head")"
  [ "$now_scores" = "$scores" ] || return 1
  mech_budget 1 || return 1
  MECH_HOLD=0
  MECH_NOTE="  covered: $first; $total verified mechanical commit(s) ($name) since"
  return 0
}

# fl_read <head> — the first-line reviewer's verdict on <head> (vr_read), from a read whose open
# review threads and review decision must still be the ones the poll judged on (MECH_THREADS,
# MECH_DECISION): a thread that opened since, or a "changes requested", fails it, as does a read that
# fails. When the reviewer is happy, the PR (head, review decision) and the bots' scores are read
# once more after it, and must still be the ones the poll judged on (MECH_SCORES): a below-bar score
# that landed mid-poll, a moved head or a failed read fails it. When rung 0 needs its own read for
# those scores, that read's threads and decision are held to MECH_THREADS and MECH_DECISION too. It is the last read before a covered
# approval, so the verdict rests on it. Both covered-staleness paths read through it.
fl_read() {
  local vr_gql now_pr now_gql now_head
  vr_gql="$(fetch_gql "$FL_NAME")" || return 1
  [ "$(unresolved_threads "$vr_gql")" = "$MECH_THREADS" ] || return 1
  # Every page carries the decision; each must still be the one the poll judged on.
  printf '%s' "$vr_gql" | jq -s -e --arg d "$MECH_DECISION" \
    '[.[].data.repository.pullRequest.reviewDecision // ""] | all(. == $d)' >/dev/null 2>&1 || return 1
  vr_read "$vr_gql" "$1"
  # Only a happy verdict can approve; any other needs no second look.
  [ "$VR_KIND" = "happy" ] || return 0
  now_pr="$(gh pr view "$WAIT_PR" -R "$WAIT_REPO" --json headRefOid,baseRefOid,reviewDecision,body,comments,reviews 2>/dev/null)" || return 1
  now_head="$(printf '%s' "$now_pr" | jq -r '"\(.headRefOid) \(.reviewDecision // "")"' 2>/dev/null)" || return 1
  [ "$now_head" = "$1 $MECH_DECISION" ] || return 1
  # The scores are read as poll_once reads them: rung 0 needs its own check name's runs; without
  # rung 0, a fresh first-line read carries the description's last editor. Either way this read is
  # taken after the PR re-read, so it must not show a thread or a decision the poll did not judge on:
  # scores_of reads neither, and a match on the scores alone would approve over them. Reusing the
  # first read here would leave a thread opened between it and the PR re-read unseen (#146).
  now_gql="$(fetch_gql "${CHECK_NAME:-$FL_NAME}")" || return 1
  [ "$(unresolved_threads "$now_gql")" = "$MECH_THREADS" ] || return 1
  printf '%s' "$now_gql" | jq -s -e --arg d "$MECH_DECISION" \
    '[.[].data.repository.pullRequest.reviewDecision // ""] | all(. == $d)' >/dev/null 2>&1 || return 1
  [ "$(scores_of "$now_pr" "$now_gql" "$1")" = "$MECH_SCORES" ] || return 1
  return 0
}

# first_line_waiver_ok <head> <open-thread-count> — in first-line mode, covered staleness (mechanical
# or not) waives only "the score names the head"; an approval still needs the first-line reviewer's
# completed, happy round on the head itself. Open review threads pass here because they are reported
# as findings:<n> (never approved), whatever the first-line reviewer says. Outside first-line mode
# there is nothing more to hold. Anything unreadable, late or changed is "no", and the caller holds
# on a "no" (it follows a mechanical cover, so the poll's own read is stale by now).
first_line_waiver_ok() {
  [ "$FIRST_LINE" = "1" ] || return 0
  [ "$2" -eq 0 ] || return 0
  mech_budget 1 || return 1
  fl_read "$1" || return 1
  [ "$VR_KIND" = "happy" ]
}

# covered_by_first_line <scores> <head> — covered staleness (first-line mode only). True when every
# published score is at the bar, names an ANCESTOR of the head (or the head), and the first-line
# reviewer has a completed, happy round on the head. Anything unreadable is "not covered".
COVERED_NOTE=""
covered_by_first_line() {
  local scores="$1" head="$2" line bot score reviewed num den status first=""
  COVERED_NOTE=""
  [ -n "$scores" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bot="${line%% *}"
    score="$(printf '%s' "$line" | cut -d' ' -f2)"
    reviewed="$(printf '%s' "$line" | cut -d' ' -f3)"
    [ -n "$reviewed" ] || return 1
    num="${score%%/*}"
    den="${score##*/}"
    if [ "$den" != "$THR_DEN" ] || [ "$num" -lt "$THR_NUM" ]; then
      return 1
    fi
    if ! is_head_sha "$reviewed" "$head"; then
      status="$(gh api "repos/$WAIT_REPO/compare/$reviewed...$head" --jq .status 2>/dev/null)" || return 1
      case "$status" in ahead | identical) ;; *) return 1 ;; esac
    fi
    [ -n "$first" ] || first="$bot $score on ${reviewed:0:7}"
  done <<<"$scores"
  fl_read "$head" || return 1
  [ "$VR_KIND" = "happy" ] || return 1
  COVERED_NOTE="  covered: $first; first-line reviewer happy on ${head:0:7}"
  return 0
}

# JQ_TS — a jq `ts` def: an ISO-8601 time (Z or a +hh:mm / -hhmm offset, fractions dropped) as
# epoch seconds, or null when it is not one. Git committer dates keep their offset, so Z alone is not
# enough.
JQ_TS='def ts: if type != "string" then null else
  ((capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")) // null) as $x
  | if $x == null then null
    else ((($x.b + "Z") | try fromdateiso8601 catch null) as $e
      | if $e == null then null elif $x.z == "Z" then $e
        else $e - ((if $x.sg == "+" then 1 else -1 end) * (($x.h | tonumber) * 3600 + ($x.m | tonumber) * 60)) end)
    end end;'

# The PR's reviews with their edit times, which neither `gh pr view` nor REST carries.
REVIEWS_QUERY='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$number){
    reviews(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
      nodes{author{login} body submittedAt lastEditedAt updatedAt}}}}}'

# no_rereview_request <cutoff-epoch> <mention> — true when every place a person can ask the final
# reviewer for a round was read and none holds the mention, by anyone but the reviewers
# (review.bots, review.firstLine.bots), dated at or after the cutoff: issue comments, review bodies
# and inline review comments (a reply in a resolved thread included). Each item is dated from its
# last edit (the latest of the times it carries); an item whose time cannot be read counts as recent.
# Any failed or unreadable read is false. The lists go through pipes, never argv, since a busy PR's
# comments outgrow an argument's size limit.
no_rereview_request() {
  local cut="$1" m="$2" raw ic rv il
  raw="$(gh api "repos/$WAIT_REPO/issues/$WAIT_PR/comments" --paginate 2>/dev/null)" || return 1
  ic="$(printf '%s' "$raw" | jq -c 'if type == "array" then .[] else error("not a list") end
    | {dates: [.created_at, .updated_at], login: (.user.login // ""), body: (.body // "")}' 2>/dev/null)" || return 1
  raw="$(gh api graphql --paginate -f query="$REVIEWS_QUERY" -F owner="$OWNER" -F name="$NAME" -F number="$WAIT_PR" 2>/dev/null)" || return 1
  rv="$(printf '%s' "$raw" | jq -c '.data.repository.pullRequest.reviews.nodes
    | if type == "array" then .[] else error("not a list") end
    | {dates: [.submittedAt, .lastEditedAt, .updatedAt], login: (.author.login // ""), body: (.body // "")}' 2>/dev/null)" || return 1
  raw="$(gh api "repos/$WAIT_REPO/pulls/$WAIT_PR/comments" --paginate 2>/dev/null)" || return 1
  il="$(printf '%s' "$raw" | jq -c 'if type == "array" then .[] else error("not a list") end
    | {dates: [.created_at, .updated_at], login: (.user.login // ""), body: (.body // "")}' 2>/dev/null)" || return 1
  printf '%s\n%s\n%s\n' "$ic" "$rv" "$il" | jq -s -e --arg m "$m" --argjson cut "$cut" \
    --argjson bots "$REVIEWER_LOGINS_JSON" "$JQ_TS"'
    map(select((.login | '"$NORM_LOGIN"') as $a | any($bots[]; . == $a) | not)
        | select(.body | ascii_downcase | contains($m))
        | select([.dates[] | select(. != null) | ts] as $d
                 | ($d | length) == 0 or any($d[]; . == null) or ($d | max) >= $cut))
    | length == 0' >/dev/null 2>&1
}

# verified_by_first_line <scores> <head> — a verified hand-off (first-line mode only; foreman's
# docs/design/vr-one-greptile-round.md §3-§4). The final reviewer reviewed an ANCESTOR G of the head
# once and scored it below the bar; the first-line reviewer then confirmed each of its findings fixed
# on the head and asked for no second round. True only when all of these hold, on reads taken in
# this order, the last one last:
#   - exactly one score is published, from the bot ladder (not rung 0), it names a commit G, and it
#     is below the bar with the bar's denominator (at or above it is plain covered staleness);
#   - fl_read: the first-line reviewer is happy on the head, with the same open threads, review
#     decision, head and scores the poll judged on;
#   - that run concluded SUCCESS, its JSON names the head itself (an "unchanged since" re-post is not
#     enough here), and carries gate_fix_verified whose verdict_sha is G (as a prefix, either way);
#   - G is a proper ancestor of the head (compare: ahead);
#   - a read of the head commit's check runs named review.checkName shows the head unmoved, the same
#     threads and decision, nothing truncated, and no run by a review.bots App: a final review of the
#     head, queued, running or done, means the head is the final reviewer's to score. The same read
#     gives the cutoff: the earliest of the round's start, the head's committer date, its earliest
#     check suite's creation and the start of the final reviewer's own run on G (read before it;
#     GitHub's times, which the pusher cannot set, and the last predates the push);
#   - last, no_rereview_request: no issue comment, review body or inline review comment by anyone
#     but the reviewers carries the review.rereviewCommand mention, dated from its last edit, at or
#     after the cutoff. Someone asked for a final round, so it is waited for.
# The comment text "Verified: ..." is never read: anyone can write a comment, only the App writes its
# check run. Anything unreadable or doubtful is "not verified", and the poll keeps waiting as before.
verified_by_first_line() {
  local scores="$1" head="$2" line bot score reviewed num den verdict started mention gql cut g graw gstart
  COVERED_NOTE=""
  [ -n "$scores" ] || return 1
  [ "$(printf '%s\n' "$scores" | grep -c .)" = "1" ] || return 1
  line="$scores"
  bot="${line%% *}"
  case "$bot" in checkrun:*) return 1 ;; esac
  score="$(printf '%s' "$line" | cut -d' ' -f2)"
  reviewed="$(printf '%s' "$line" | cut -d' ' -f3 | tr 'A-F' 'a-f')"
  [ -n "$reviewed" ] || return 1
  ! is_head_sha "$reviewed" "$head" || return 1
  num="${score%%/*}"
  den="${score##*/}"
  { is_uint "$num" && [ "$den" = "$THR_DEN" ] && [ "$num" -lt "$THR_NUM" ]; } || return 1
  fl_read "$head" || return 1
  [ "$VR_KIND" = "happy" ] || return 1
  [ "$(printf '%s' "$VR_RUN" | jq -r '.conclusion // ""')" = "SUCCESS" ] || return 1
  is_head_sha "$(printf '%s' "$VR_JSON" | jq -r '.reviewed_sha // ""')" "$head" || return 1
  verdict="$(printf '%s' "$VR_JSON" | jq -r '
    .gate_fix_verified | select(type == "object") | .verdict_sha
    | select(type == "string" and test("^[0-9a-fA-F]{7,64}$")) | ascii_downcase' 2>/dev/null)" || return 1
  [ -n "$verdict" ] || return 1
  case "$verdict" in "$reviewed"*) ;; *) case "$reviewed" in "$verdict"*) ;; *) return 1 ;; esac ;; esac
  [ "$(gh api "repos/$WAIT_REPO/compare/$reviewed...$head" --jq .status 2>/dev/null)" = "ahead" ] || return 1
  # When the final reviewer started its review of G: the start of its own review.checkName run on G,
  # from a review.bots App (the earliest, when there are several). GitHub records it, G is an ancestor
  # of the head, so it predates the head's push whatever the head's own dates say. Every run on G is
  # read (filter=all: GitHub's default keeps only the latest, and a retry would hide the first). No
  # such run, or no readable start, is "not verified" (design §3 condition 2 needs that run anyway).
  g="$verdict"
  [ "${#reviewed}" -le "${#verdict}" ] || g="$reviewed"
  graw="$(gh api "repos/$WAIT_REPO/commits/$g/check-runs" --method GET -f check_name="$FL_GATE_CHECK" -f filter=all --paginate 2>/dev/null)" || return 1
  gstart="$(printf '%s' "$graw" | jq -s -r --arg name "$FL_GATE_CHECK" --argjson bots "$BOTS_JSON" "$JQ_TS"'
    if all(.[]; (.check_runs | type) == "array") | not then empty
    else [.[].check_runs[] | select(.name == $name)
          | select((.app.slug // "") as $s | any($bots[]; . == $s)) | .started_at | ts]
      | if length == 0 or any(.[]; . == null) then empty else min | floor end
    end' 2>/dev/null)" || return 1
  is_uint "$gstart" || return 1
  started="$(printf '%s' "$VR_RUN" | jq -r '.startedAt // ""')"
  [ -n "$started" ] || return 1
  mention="$(printf '%s' "$FL_REREVIEW" | tr 'A-Z' 'a-z' | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^@/) { print $i; exit } }')"
  [ -n "$mention" ] || mention="$(printf '%s' "$FL_REREVIEW" | tr 'A-Z' 'a-z')"
  [ -n "$mention" ] || return 1
  gql="$(fetch_gql "$FL_GATE_CHECK")" || return 1
  [ "$(unresolved_threads "$gql")" = "$MECH_THREADS" ] || return 1
  printf '%s' "$gql" | jq -s -e --arg d "$MECH_DECISION" --arg head "$head" --arg name "$FL_GATE_CHECK" \
    --argjson bots "$BOTS_JSON" '
    [.[].data.repository.pullRequest] as $p
    | ($p | all((.reviewDecision // "") == $d))
      and ($p[0].commits.nodes | length == 1 and .[0].commit.oid == $head)
      and ([$p[].commits.nodes[]?.commit.checkSuites]
           | all(.pageInfo.hasNextPage != true and all(.nodes[]?; .checkRuns.pageInfo.hasNextPage != true))
           and ([.[].nodes[]? | select((.app.slug // "") as $s | any($bots[]; . == $s))
                 | .checkRuns.nodes[]? | select(.name == $name)] | length == 0))' >/dev/null 2>&1 || return 1
  # The cutoff for a person's request: the earliest of the first-line round's start, the head
  # commit's committer date, the head's earliest check suite and the final reviewer's run on G. The
  # committer date alone is the pusher's to set (a future one would hide every request), and the
  # head's only suite may be the first-line reviewer's own, made at the round's start; the run on G
  # predates the push, so any person's request since the final reviewer took up G counts. Anything
  # unreadable is "not verified".
  cut="$(printf '%s' "$gql" | jq -s -r --arg s "$started" --argjson g "$gstart" "$JQ_TS"'
    [.[].data.repository.pullRequest.commits.nodes[]?.commit] as $c
    | [$c[].committedDate | ts] as $cd
    | [$c[].checkSuites.nodes[]? | .createdAt | ts] as $su
    | ($s | ts) as $st
    | if $st == null or ($cd | length) == 0 or any($cd[]; . == null)
         or ($su | length) == 0 or any($su[]; . == null)
      then empty else [$st, $g] + $cd + $su | min | floor end' 2>/dev/null)" || return 1
  is_uint "$cut" || return 1
  # Read last, right before approving: a request posted while the reads above ran is still seen.
  no_rereview_request "$cut" "$mention" || return 1
  COVERED_NOTE="  verified: $bot $score on ${reviewed:0:7}; the first-line reviewer verified its fixes on ${head:0:7}, no final-review round needed"
  return 0
}

# score_from_text <text> — prints "<n>/<m> <sha>" (sha may be empty) when the text carries a
# `Confidence Score: n/m` token, nothing otherwise. Tolerates markdown around the token.
score_from_text() {
  local text="$1" score sha tail
  score="$(printf '%s' "$text" | tr -d '*' | sed -n 's/.*[Cc]onfidence [Ss]core:[^0-9]*\([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p' | head -n 1)"
  [ -n "$score" ] || return 0
  # The commit is named in the link after "Last reviewed commit:". Greptile's link TEXT is the commit
  # title (`[feat: x](.../commit/<sha>)`) and older shapes use the short sha as the text
  # (`[a1b2c3d](...)`), so the sha is read from the /commit/<sha> URL first, the bracketed text second.
  # Only the FIRST label and the FIRST commit link after it count: a later link in the text (a quoted
  # older review, say) must not replace the one the label names.
  tail="$(printf '%s' "$text" | tr '\n' ' ' | awk '{ i = index($0, "Last reviewed commit:"); if (i) print substr($0, i + 21) }')"
  sha="$(printf '%s' "$tail" | grep -oE '/commit/[0-9a-fA-F]{7,40}' | head -n 1 | sed 's#/commit/##')"
  [ -n "$sha" ] || sha="$(printf '%s' "$tail" | sed -n 's/^[^0-9a-fA-F]*\[\{0,1\}\([0-9a-fA-F]\{7,40\}\)\].*/\1/p' | head -n 1)"
  printf '%s %s' "$score" "$sha"
}

# is_head_sha <reviewed> <head> — true when the commit a score names is the PR's head. The reviewed
# sha is usually abbreviated, so it matches as a prefix; an unreadable (empty) one never matches.
is_head_sha() {
  [ -n "$1" ] || return 1
  case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac
}

# find_scores <pr-json> <body-editor> — one line per configured bot that has published a score:
# "<login> <n>/<m> <sha>" (sha may be empty). Per bot, the same ladder address-review documents:
# (a) the PR description's marker block, but ONLY when that bot is who last edited the description
# (the body is author-writable, so an unattributed block proves nothing and a forged one must not
# approve a PR); (b) the bot's newest issue comment carrying a score; (c) its newest review body.
find_scores() {
  local pr="$1" editor="$2" bot body block out cands cand kind
  body="$(printf '%s' "$pr" | jq -r '.body // ""')"
  # Scope to the marker block, so prose in the description that mentions "4/5" is never a verdict.
  # The opener is review.blockMarker (`<!-- name -->`); the closer is the same with a slash, matched
  # as plain strings, never as a pattern.
  block="$(printf '%s' "$body" | awk -v open="$BLOCK_MARKER" '
    BEGIN { close_m = open; sub(/^<!-- ?/, "&/", close_m) }
    index($0, open) { f = 1 } f { print } index($0, close_m) { f = 0 }')"
  for bot in $(printf '%s' "$BOTS_JSON" | jq -r '.[]'); do
    out=""
    if [ -n "$block" ] && [ "$editor" = "$bot" ]; then
      out="$(score_from_text "$block")"
    fi
    for kind in comments reviews; do
      [ -z "$out" ] || break
      cands="$(printf '%s' "$pr" | jq -c --arg bot "$bot" "
        [.${kind}[]? | select((.author.login // \"\" | $NORM_LOGIN) == \$bot)] | reverse | .[] | .body")"
      [ -n "$cands" ] || continue
      while IFS= read -r cand; do
        out="$(score_from_text "$(printf '%s' "$cand" | jq -r '.')")"
        [ -z "$out" ] || break
      done <<<"$cands"
    done
    [ -z "$out" ] || printf '%s %s\n' "$bot" "$out"
  done
  return 0
}

# scores_of <pr-json> <graphql-json-stream> <head> — the scores a poll judges on: rung 0 (the
# configured App's check run on the head; may be PENDING or INCOMPLETE) when it answers, else the
# bot ladder of find_scores. poll_once and the mechanical re-read share it so both read alike.
scores_of() {
  local pr="$1" gql="$2" head="$3" s="" editor
  [ -z "$CHECK_NAME" ] || s="$(check_run_score "$gql" "$head")"
  if [ -z "$s" ]; then
    editor="$(printf '%s' "$gql" | jq -s -r '[.[] | .data.repository.pullRequest.userContentEdits.nodes[0].editor.login // empty][0] // "" | '"$NORM_LOGIN"'')" || editor=""
    s="$(find_scores "$pr" "$editor")"
  fi
  printf '%s' "$s"
}

# One poll. Sets VERDICT (empty = not decided yet) and DETAIL (extra stdout lines).
VERDICT=""
DETAIL=""
LAST_ERR=""
poll_once() {
  local pr gql threads head scores line bot score reviewed num den
  local unresolved n decision all_met stale held skip_labelled head_scored

  VERDICT=""
  DETAIL=""
  COVERED_NOTE="" # a note from an earlier poll must never ride on this poll's verdict
  MECH_HOLD=0
  pr="$(gh pr view "$WAIT_PR" -R "$WAIT_REPO" --json "$PR_FIELDS" 2>&1)" || {
    LAST_ERR="gh pr view failed: $pr"
    return 1
  }
  printf '%s' "$pr" | jq -e . >/dev/null 2>&1 || {
    LAST_ERR="gh pr view returned non-JSON"
    return 1
  }

  # Nothing to wait for: say so immediately rather than burn the deadline.
  if [ "$(printf '%s' "$pr" | jq -r '.isDraft // false')" = "true" ]; then
    VERDICT="no-review-scheduled"
    return 0
  fi
  # The skip label: no reviewer is scheduled. In the final stage with a numeric threshold, a score a
  # bot already published on the head (it raced the label, or the label came later) still counts,
  # so read the scores first and only report no-review-scheduled when none of them is on the head.
  skip_labelled=0
  if [ -n "$SKIP_LABEL" ] && printf '%s' "$pr" | jq -e --arg l "$SKIP_LABEL" '[.labels[]?.name] | index($l)' >/dev/null 2>&1; then
    if [ "$STAGE" = "vr" ] || [ -z "$THR_NUM" ]; then
      VERDICT="no-review-scheduled"
      return 0
    fi
    skip_labelled=1
  fi
  if [ "$STAGE" = "final" ] && [ "$(printf '%s' "$BOTS_JSON" | jq 'length')" = "0" ] && [ -z "$CHECK_NAME" ]; then
    VERDICT="no-review-scheduled"
    return 0
  fi
  if [ "$(printf '%s' "$pr" | jq -r '.state // "OPEN"')" != "OPEN" ]; then
    LAST_ERR="PR is not open"
    return 1
  fi

  head="$(printf '%s' "$pr" | jq -r '.headRefOid // ""')"
  [ -n "$head" ] || {
    LAST_ERR="PR has no headRefOid"
    return 1
  }
  decision="$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')"
  MECH_HEAD_REF="$(printf '%s' "$pr" | jq -r '.headRefName // ""')"
  MECH_CROSS="$(printf '%s' "$pr" | jq -r 'if .isCrossRepository == false then "false" else "true" end')"
  MECH_BASE="$(printf '%s' "$pr" | jq -r '.baseRefOid // ""')"

  if [ "$STAGE" = "vr" ]; then
    gql="$(fetch_gql "$FL_NAME")" || {
      LAST_ERR="gh api graphql failed: $gql"
      return 1
    }
    vr_read "$gql" "$head"
    case "$VR_KIND" in
      happy) VERDICT="vr-happy" ;;
      handoff)
        VERDICT="vr-handoff"
        DETAIL="$VR_DETAIL"
        ;;
      findings)
        VERDICT="vr-findings:$VR_N"
        DETAIL="$VR_DETAIL"
        ;;
      escalated)
        VERDICT="vr-escalated"
        DETAIL="$VR_DETAIL"
        ;;
      unavailable)
        VERDICT="vr-unavailable"
        DETAIL="$VR_DETAIL"
        ;;
    esac
    return 0 # none / pending: keep waiting
  fi
  gql="$(fetch_gql "$CHECK_NAME")" || {
    LAST_ERR="gh api graphql failed: $gql"
    return 1
  }
  threads="$(unresolved_threads "$gql")" || {
    LAST_ERR="could not parse review threads"
    return 1
  }
  unresolved="$threads"
  n="$(printf '%s' "$unresolved" | jq 'length')"
  MECH_DECISION="$decision"
  MECH_THREADS="$unresolved"

  # Is there a review of THIS head yet? Every configured bot that has published a score must have
  # scored the head (else its score is stale and we keep waiting), and — numeric threshold — every
  # one of them must meet the bar. Absence of any score is "not reviewed yet", never a pass.
  # Rung 0 first: the configured App's check run on this head, when it has a readable verdict. It
  # replaces the bot ladder below; if the run exists but is unreadable, the ladder decides.
  scores="$(scores_of "$pr" "$gql" "$head")"
  MECH_SCORES="$scores" # the last read before a covered approval must find them unchanged (fl_read)
  [ "$scores" != "PENDING" ] || return 0 # the reviewer is still working on this head
  if [ "$scores" = "INCOMPLETE" ]; then
    # More check suites or runs than one query returns: the configured run may be on a page not
    # read. Never let the lower rungs decide on that; wait, and say why if the deadline hits.
    LAST_ERR="rung 0: the head commit's check suites/runs were truncated (hasNextPage); the configured check run may be unseen"
    return 0
  fi
  if [ "$skip_labelled" = "1" ]; then
    # Skip-labelled: judge a score on the head as on any PR; with none, nothing will review it. A
    # score on a known older commit is named in the detail (it is not a review of this head, and no
    # bot will refresh it), never waited on. A score whose commit cannot be read is not "an older
    # commit": it may well be the head, so it is never waived. Below the threshold it halts as a
    # found failing score does (findings:<n>); at or above it, it waives nothing.
    head_scored=0
    unreadable_below=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      reviewed="$(printf '%s' "$line" | cut -d' ' -f3)"
      ! is_head_sha "$reviewed" "$head" || head_scored=1
      if [ -z "$reviewed" ]; then
        score="$(printf '%s' "$line" | cut -d' ' -f2)"
        num="${score%%/*}"
        den="${score##*/}"
        if [ "$den" != "$THR_DEN" ] || ! [ "$num" -ge "$THR_NUM" ] 2>/dev/null; then
          unreadable_below="${unreadable_below}  ${line%% *} scored $score on an unreadable commit, below review.approvalThreshold $THRESHOLD; the skip label does not waive a found score"$'\n'
        fi
      fi
    done <<<"$scores"
    if [ -n "$unreadable_below" ]; then
      VERDICT="findings:$n"
      DETAIL="${unreadable_below%$'\n'}"
      [ "$n" -eq 0 ] || DETAIL="$(printf '%s' "$unresolved" | jq -r '.[] |
        "  \(.path // "?"):\((.line // .originalLine // 0))  " +
        ((.comments.nodes[0].body // "") | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | sub("^ "; "") | .[0:160])')"$'\n'"$DETAIL"
      return 0
    fi
    if [ "$head_scored" = "0" ]; then
      VERDICT="no-review-scheduled"
      [ -z "$scores" ] || DETAIL="$(printf '%s\n' "$scores" | awk 'NF { if ($3 == "") printf "  %s scored %s on an unreadable commit, at or above the threshold; the PR carries the skip label\n", $1, $2; else printf "  %s scored %s on %s, not the head; the PR carries the skip label\n", $1, $2, $3 }')"
      return 0
    fi
  fi
  stale=0
  all_met=1
  if [ -z "$THR_NUM" ]; then
    # Threshold "approved": the gate is GitHub's reviewDecision; a score that is stale still means
    # the bot has not looked at the head, so it holds the verdict back too.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      reviewed="$(printf '%s' "$line" | cut -d' ' -f3)"
      is_head_sha "$reviewed" "$head" || stale=1
    done <<<"$scores"
    if [ "$stale" = "1" ] && covered_by_mechanical "$scores" "$head" && first_line_waiver_ok "$head" "$n"; then
      stale=0
      COVERED_NOTE="$MECH_NOTE"
    fi
    [ "$stale" = "0" ] || return 0
    [ "$decision" = "APPROVED" ] || [ -n "$scores" ] || return 0
  else
    [ -n "$scores" ] || return 0 # no bot has published a score at all yet
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      bot="${line%% *}"
      score="$(printf '%s' "$line" | cut -d' ' -f2)"
      reviewed="$(printf '%s' "$line" | cut -d' ' -f3)"
      # A score whose commit is missing or is not the head is stale: keep waiting.
      is_head_sha "$reviewed" "$head" || stale=1
      num="${score%%/*}"
      den="${score##*/}"
      if [ "$den" != "$THR_DEN" ] || [ "$num" -lt "$THR_NUM" ]; then
        all_met=0
        DETAIL="  $bot scored $score, below review.approvalThreshold $THRESHOLD on the head commit"
      fi
    done <<<"$scores"
    # Covered staleness: the bar was met on an ancestor of the head. A poll that ran a mechanical
    # cover decides nothing unless the cover succeeds: what it read before verify (or a fetch) is
    # stale by now, so it never falls back to the first-line path below, which would approve from
    # that read. It holds, and the next poll judges from a fresh one: in first-line mode with
    # nothing open, that poll tries the first-line path first, before anything slow runs, so a
    # verifier that keeps hanging (or a fetch that keeps failing) costs one interval, not the wait.
    if [ "$stale" = "1" ] && [ "$all_met" = "1" ]; then
      held="$MECH_HELD"
      MECH_HELD=0
      if [ "$held" = "1" ] && [ "$FIRST_LINE" = "1" ] && [ "$n" -eq 0 ] &&
        covered_by_first_line "$scores" "$head"; then
        stale=0
      elif covered_by_mechanical "$scores" "$head"; then
        # Verified mechanical commits since the passing score (any mode). Open threads are
        # reported below; in first-line mode an approval also needs a happy first-line round on
        # the head, and a "no" holds too.
        first_line_waiver_ok "$head" "$n" || {
          MECH_HELD=1
          return 0
        }
        stale=0
        COVERED_NOTE="$MECH_NOTE"
      elif [ "$MECH_HOLD" = "1" ]; then
        MECH_HELD=1
        return 0
      elif [ "$held" != "1" ] && [ "$FIRST_LINE" = "1" ] && [ "$n" -eq 0 ] && covered_by_first_line "$scores" "$head"; then
        # First-line mode only: nothing is open and the first-line reviewer is happy on the head.
        stale=0
      fi
    fi
    # Verified (first-line mode only): the bar was not met on an ancestor, and the first-line
    # reviewer verified the final reviewer's fixes on the head instead of asking for a second round.
    # It stands in for the met bar, the way covered staleness stands in for the head.
    if [ "$stale" = "1" ] && [ "$all_met" = "0" ] && [ "$FIRST_LINE" = "1" ] && [ "$n" -eq 0 ] &&
      [ "$decision" != "CHANGES_REQUESTED" ] && verified_by_first_line "$scores" "$head"; then
      stale=0
      all_met=1
    fi
    [ "$stale" = "0" ] || return 0
  fi

  if [ "$n" -gt 0 ]; then
    VERDICT="findings:$n"
    DETAIL="$(printf '%s' "$unresolved" | jq -r '.[] |
      "  \(.path // "?"):\((.line // .originalLine // 0))  " +
      ((.comments.nodes[0].body // "") | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | sub("^ "; "") | .[0:160])')"
    return 0
  fi

  # A human who asked for changes still blocks, whatever the bot scored.
  if [ "$decision" = "CHANGES_REQUESTED" ]; then
    VERDICT="findings:0"
    DETAIL="  a reviewer has requested changes (reviewDecision CHANGES_REQUESTED); no unresolved thread carries it"
    return 0
  fi

  if [ -z "$THR_NUM" ]; then
    if [ "$decision" = "APPROVED" ]; then
      VERDICT="approved"
      DETAIL="$COVERED_NOTE"
    fi
    return 0
  fi
  if [ "$all_met" = "1" ]; then
    VERDICT="approved"
    DETAIL="$COVERED_NOTE"
  else
    VERDICT="findings:0"
  fi
  return 0
}

deadline=$(($(now) + TIMEOUT_SECONDS))
first=1
while :; do
  if poll_once; then
    first=0
  elif [ "$first" = "1" ]; then
    # A failure on the very first read is a setup problem (auth, wrong repo, bad PR number), not a
    # slow review. Say so instead of waiting out the deadline and calling it a timeout.
    die 3 "$LAST_ERR"
  fi
  # A covered approval lands before the deadline: it rests on reads made after the poll's own (a
  # mechanical re-read, a first-line read), and one that ran past the deadline approves nothing; the
  # timeout below reports it. A plain approval is the poll's single read, so the last look at the
  # deadline (and --timeout-seconds 0) can still report it.
  if [ "$VERDICT" = "approved" ] && [ -n "$COVERED_NOTE" ] && [ "$(now)" -ge "$deadline" ]; then
    VERDICT=""
    LAST_ERR="a covered approval was read only after the deadline; not reported"
  fi
  if [ -n "$VERDICT" ]; then
    printf '%s\n' "$VERDICT"
    [ -z "$DETAIL" ] || printf '%s\n' "$DETAIL"
    case "$VERDICT" in
      approved | no-review-scheduled | vr-happy | vr-handoff | vr-unavailable) exit 0 ;;
      *) exit 1 ;;
    esac
  fi
  if [ "$(now)" -ge "$deadline" ]; then
    printf 'timeout\n'
    [ -z "$LAST_ERR" ] || printf 'last error: %s\n' "$LAST_ERR" >&2
    exit 2
  fi
  # The sleep is clipped to the deadline, so the next loop iteration is one last look at it.
  sleep_within "$INTERVAL" "$deadline"
done
