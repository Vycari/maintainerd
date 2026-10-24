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
#                          or review.bots is configured empty.
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
# first-line reviewer is happy on the head itself. A second detail line says so. Judging whether
# that score carried a P1 is the merge gate's job, as it is for a score on the head.
#
# Mechanical commits (review.mechanicalCommits, any mode): a score at or above the threshold on an
# ANCESTOR G of the head is not stale when G..head is one linear chain of verified mechanical
# commits of ONE configured entry: authored by its `author` login, committed by it or web-flow,
# GitHub-verified (reason "valid"), carrying its `trailer:` trailer, pushed to the branch by that
# login (activity API), and passing its `verify` argv ({sha} substituted) run from a detached
# worktree at G. A second detail line says so. Anything unreadable or doubtful (compare or activity
# data truncated, the range touching the config file or the verifier, a fork, no local checkout or
# no G, verify missing / failing / out of time, the head moving meanwhile) is NOT covered. The
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
# polite poller keeps against the API), --config FILE.
#
# Requires: bash 3.2+, gh, jq.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wait-common.sh
. "$HERE/lib/wait-common.sh"

WAIT_HELP=""
parse_common_args "$@"
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
    userContentEdits(first:1){nodes{editor{login}}}
    commits(last:1){nodes{commit{oid checkSuites(first:50){pageInfo{hasNextPage} nodes{app{slug}
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
vr_read() {
  local run title json head="$2" reviewed requested
  VR_KIND="none"
  VR_N=0
  VR_DETAIL=""
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
# subshell). MECH_CACHE holds " <G>:<entry>:<sha>=<0|1> " verdicts so a commit's verify runs once per
# run, not once per poll; a verify that timed out or died on a signal is not cached, so it is tried
# again while time is left. MECH_WT_ROOT holds the detached worktrees verify runs in.
MECH_CACHE=" "
MECH_WT_ROOT=""
MECH_TOP=""
MECH_WT=""
MECH_HEAD_REF=""
MECH_CROSS=""
MECH_BASE=""
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

# mech_worktree <G> — sets MECH_WT to a detached worktree of this checkout at <G> (made once per
# run; called directly, never in $(...), so the cleanup trap sees what it made). The
# verifier runs there, from the version of the repo the passing score reviewed, never from the
# working tree or from the range it is vouching for. Fails when <G> is not available locally.
mech_worktree() {
  local g="$1" wt
  MECH_WT=""
  if [ -z "$MECH_TOP" ]; then
    MECH_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$MECH_TOP" ] || return 1
  fi
  if [ -z "$MECH_WT_ROOT" ]; then
    MECH_WT_ROOT="$(mktemp -d 2>/dev/null)" || return 1
    [ -n "$MECH_WT_ROOT" ] || return 1
  fi
  wt="$MECH_WT_ROOT/$g"
  if [ ! -d "$wt" ]; then
    mech_budget 60 || return 1
    run_bounded "$MECH_SECS" "${MECH_GIT[@]}" -C "$MECH_TOP" worktree add --detach --quiet "$wt" "$g" || return 1
  fi
  MECH_WT="$wt"
}

# mech_reset <worktree> <G> — puts the worktree back to a clean checkout of <G>, so one verify run
# cannot leave anything behind for the next.
mech_reset() {
  "${MECH_GIT[@]}" -C "$1" checkout -q -f --detach "$2" >/dev/null 2>&1 </dev/null || return 1
  "${MECH_GIT[@]}" -C "$1" clean -q -f -d -x >/dev/null 2>&1 </dev/null || return 1
  [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$2" ] &&
    [ -z "$(git -C "$1" status --porcelain --ignored 2>/dev/null)" ]
}

# range_covered_by_entry <entry-json> <entry-index> <compare-json> <activity-json> <G> — true when
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
  local entry="$1" idx="$2" cmp="$3" act="$4" g="$5" author trailer chain sha i key secs rc wt
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
  mech_worktree "$g" || return 1
  wt="$MECH_WT"
  while IFS= read -r sha; do
    [ -n "$sha" ] || return 1
    key="$g:$idx:$sha"
    case "$MECH_CACHE" in
      *" $key=1 "*)
        MECH_COUNT=$((MECH_COUNT + 1))
        continue
        ;;
      *" $key=0 "*) return 1 ;;
    esac
    # Each verify gets at most 120s, clipped to what is left of the wait's deadline, and starts from
    # a clean checkout of G whatever the previous run did to it.
    mech_budget 120 || return 1
    secs="$MECH_SECS"
    mech_reset "$wt" "$g" || return 1
    verify=()
    # NUL-separated: an argument may itself hold newlines (a multi-line `sh -c` script).
    while IFS= read -r -d '' i; do verify+=("${i//\{sha\}/$sha}"); done < <(printf '%s' "$entry" | jq -j '.verify[] | ., "\u0000"')
    [ "${#verify[@]}" -gt 0 ] || return 1
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
  local scores="$1" head="$2" line bot score reviewed entry ok total=0 name="" first="" cmp act g idx now_head
  local basecfg entries bcmp
  MECH_NOTE=""
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
  basecfg="$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$WAIT_REPO/contents/.claude/maintainerd.json?ref=$MECH_BASE" 2>/dev/null)" || return 1
  entries="$(mechanical_entries "$basecfg")"
  [ -n "$entries" ] || return 1
  # Nothing the PR changes, from its merge base to the head, may be the config or a file a verify
  # argument names. One page only: 300 files or more is not covered.
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
    act="$(gh api "repos/$WAIT_REPO/activity?ref=$(printf '%s' "refs/heads/$MECH_HEAD_REF" | jq -sRr @uri)&per_page=100" 2>/dev/null)" || return 1
    # Verify needs G (and is likely to want the range's commits); fetch them when they are missing.
    if ! git cat-file -e "$g^{commit}" 2>/dev/null || ! git cat-file -e "$head^{commit}" 2>/dev/null; then
      mech_budget 60 && run_bounded "$MECH_SECS" "${MECH_GIT[@]}" fetch -q --no-tags origin "$g" "$head"
    fi
    git cat-file -e "$g^{commit}" 2>/dev/null || return 1
    ok=0
    idx=0
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      idx=$((idx + 1))
      if range_covered_by_entry "$entry" "$idx" "$cmp" "$act" "$g"; then
        ok=1
        total=$((total + MECH_COUNT))
        name="$MECH_NAME"
        break
      fi
    done <<<"$entries"
    [ "$ok" = "1" ] || return 1
  done <<<"$scores"
  [ "$total" -gt 0 ] || return 1
  # Verifying took time: the head it covered must still be the head.
  now_head="$(gh pr view "$WAIT_PR" -R "$WAIT_REPO" --json headRefOid -q .headRefOid 2>/dev/null)" || return 1
  [ "$now_head" = "$head" ] || return 1
  MECH_NOTE="  covered: $first; $total verified mechanical commit(s) ($name) since"
  return 0
}

# covered_by_first_line <scores> <head> — covered staleness (first-line mode only). True when every
# published score is at the bar, names an ANCESTOR of the head (or the head), and the first-line
# reviewer has a completed, happy round on the head. Anything unreadable is "not covered".
COVERED_NOTE=""
covered_by_first_line() {
  local scores="$1" head="$2" line bot score reviewed num den status vr_gql first=""
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
  vr_gql="$(fetch_gql "$FL_NAME")" || return 1
  vr_read "$vr_gql" "$head"
  [ "$VR_KIND" = "happy" ] || return 1
  COVERED_NOTE="  covered: $first; first-line reviewer happy on ${head:0:7}"
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

# One poll. Sets VERDICT (empty = not decided yet) and DETAIL (extra stdout lines).
VERDICT=""
DETAIL=""
LAST_ERR=""
poll_once() {
  local pr gql threads editor head scores line bot score reviewed num den
  local unresolved n decision all_met stale

  VERDICT=""
  DETAIL=""
  COVERED_NOTE="" # a note from an earlier poll must never ride on this poll's verdict
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
  if [ -n "$SKIP_LABEL" ] && printf '%s' "$pr" | jq -e --arg l "$SKIP_LABEL" '[.labels[]?.name] | index($l)' >/dev/null 2>&1; then
    VERDICT="no-review-scheduled"
    return 0
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
  threads="$(printf '%s' "$gql" | jq -s -c '
    [.[] | .data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)]')" || {
    LAST_ERR="could not parse review threads"
    return 1
  }
  editor="$(printf '%s' "$gql" | jq -s -r '[.[] | .data.repository.pullRequest.userContentEdits.nodes[0].editor.login // empty][0] // "" | '"$NORM_LOGIN"'')" || editor=""
  unresolved="$threads"
  n="$(printf '%s' "$unresolved" | jq 'length')"

  # Is there a review of THIS head yet? Every configured bot that has published a score must have
  # scored the head (else its score is stale and we keep waiting), and — numeric threshold — every
  # one of them must meet the bar. Absence of any score is "not reviewed yet", never a pass.
  # Rung 0 first: the configured App's check run on this head, when it has a readable verdict. It
  # replaces the bot ladder below; if the run exists but is unreadable, the ladder decides.
  scores=""
  if [ -n "$CHECK_NAME" ]; then
    scores="$(check_run_score "$gql" "$head")"
    [ "$scores" != "PENDING" ] || return 0 # the reviewer is still working on this head
    if [ "$scores" = "INCOMPLETE" ]; then
      # More check suites or runs than one query returns: the configured run may be on a page not
      # read. Never let the lower rungs decide on that; wait, and say why if the deadline hits.
      LAST_ERR="rung 0: the head commit's check suites/runs were truncated (hasNextPage); the configured check run may be unseen"
      return 0
    fi
  fi
  [ -n "$scores" ] || scores="$(find_scores "$pr" "$editor")"
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
    if [ "$stale" = "1" ] && covered_by_mechanical "$scores" "$head"; then
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
    # Covered staleness (first-line mode only): the bar was met on an ancestor of the head, nothing
    # is open, and the first-line reviewer is happy on the head itself.
    if [ "$stale" = "1" ] && [ "$all_met" = "1" ] && covered_by_mechanical "$scores" "$head"; then
      # Verified mechanical commits since the passing score (any mode); open threads are reported below.
      stale=0
      COVERED_NOTE="$MECH_NOTE"
    elif [ "$stale" = "1" ] && [ "$all_met" = "1" ] && [ "$FIRST_LINE" = "1" ] && [ "$n" -eq 0 ] &&
      covered_by_first_line "$scores" "$head"; then
      stale=0
    else
      COVERED_NOTE=""
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
