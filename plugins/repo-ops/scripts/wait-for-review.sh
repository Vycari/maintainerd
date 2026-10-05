#!/usr/bin/env bash
#
# wait-for-review.sh — block until a PR's automated review reaches a verdict, then print it.
#
#   wait-for-review.sh <pr> [-R owner/repo]
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
# Config (.claude/maintainerd.json, see references/config-schema.md): review.waitTimeoutMinutes,
# review.approvalThreshold, review.bots, review.skipLabel.
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
  sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ -n "$WAIT_PR" ] || die 3 "usage: wait-for-review.sh <pr> [-R owner/repo]"
[ -z "$WAIT_REST" ] || die 3 "unknown flag:$WAIT_REST"

THRESHOLD="$(cfg '.review.approvalThreshold' 'approved')"
SKIP_LABEL="$(cfg '.review.skipLabel' '')"
TIMEOUT_MIN="$(cfg '.review.waitTimeoutMinutes' '20')"
is_uint "$TIMEOUT_MIN" || die 3 "review.waitTimeoutMinutes must be a non-negative integer"
TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-$((TIMEOUT_MIN * 60))}"
INTERVAL="${WAIT_INTERVAL_SECONDS:-180}"

# review.bots: an absent key means the schema default; an explicit empty array means "no bot".
CFG_FILE="$(config_file)"
BOTS_JSON='["coderabbitai[bot]","gemini-code-assist[bot]"]'
if [ -n "$CFG_FILE" ]; then
  b="$(jq -c 'if (.review // {}) | has("bots") then .review.bots else null end' "$CFG_FILE" 2>/dev/null)" ||
    die 3 "$CFG_FILE is not valid JSON"
  case "$b" in
    null | '') ;;
    *) BOTS_JSON="$b" ;;
  esac
fi
# Compare logins with the [bot] suffix stripped: REST says greptile-apps[bot], GraphQL says
# greptile-apps, and a config naming one form must match the other.
BOTS_JSON="$(printf '%s' "$BOTS_JSON" | jq -c 'map(sub("\\[bot\\]$"; ""))')" || die 3 "review.bots must be an array of logins"

case "$THRESHOLD" in
  approved) THR_NUM="" THR_DEN="" ;;
  [0-9]*/[0-9]*)
    THR_NUM="${THRESHOLD%%/*}"
    THR_DEN="${THRESHOLD##*/}"
    is_uint "$THR_NUM" && is_uint "$THR_DEN" || die 3 "review.approvalThreshold '$THRESHOLD' is neither \"approved\" nor \"<n>/<m>\""
    ;;
  *) die 3 "review.approvalThreshold '$THRESHOLD' is neither \"approved\" nor \"<n>/<m>\"" ;;
esac

resolve_repo
OWNER="${WAIT_REPO%%/*}"
NAME="${WAIT_REPO##*/}"

PR_FIELDS="number,isDraft,state,labels,headRefOid,body,comments,reviews,reviewDecision"
THREADS_QUERY='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$number){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{isResolved isOutdated path line originalLine comments(first:1){nodes{body author{login}}}}
    }}}}'

# score_from_text <text> — prints "<n>/<m> <sha>" (sha may be empty) when the text carries a
# `Confidence Score: n/m` token, nothing otherwise. Tolerates markdown around the token.
score_from_text() {
  local text="$1" score sha
  score="$(printf '%s' "$text" | tr -d '*' | sed -n 's/.*[Cc]onfidence [Ss]core:[^0-9]*\([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p' | head -n 1)"
  [ -n "$score" ] || return 0
  sha="$(printf '%s' "$text" | sed -n 's/.*Last reviewed commit:[^0-9a-fA-F]*\([0-9a-fA-F]\{7,40\}\).*/\1/p' | head -n 1)"
  printf '%s %s' "$score" "$sha"
}

# find_score <pr-json> — the bot's verdict artifact, searched in the order address-review uses:
# (a) the PR description's bot block, (b) the most recent bot issue comment carrying a score,
# (c) the most recent bot review body carrying one. Prints "<n>/<m> <sha>" or nothing.
find_score() {
  local pr="$1" body block out cand cands kind
  body="$(printf '%s' "$pr" | jq -r '.body // ""')"
  # Scope to the marker block when present, so prose in the description that mentions "4/5"
  # is never read as the verdict.
  block="$(printf '%s' "$body" | awk '/<!-- greptile_comment -->/{f=1} f{print} /<!-- \/greptile_comment -->/{f=0}')"
  if [ -n "$block" ]; then
    out="$(score_from_text "$block")"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  # Bot comments newest first, then bot review bodies newest first; the first with a score wins.
  # shellcheck disable=SC2016
  local sel='select((.author.login // "" | sub("\\[bot\\]$"; "")) as $a | $bots | index($a))'
  for kind in comments reviews; do
    cands="$(printf '%s' "$pr" | jq -c --argjson bots "$BOTS_JSON" "[.${kind}[]? | $sel] | reverse | .[] | .body")"
    [ -n "$cands" ] || continue
    while IFS= read -r cand; do
      out="$(score_from_text "$(printf '%s' "$cand" | jq -r '.')")"
      if [ -n "$out" ]; then
        printf '%s' "$out"
        return 0
      fi
    done <<<"$cands"
  done
  return 0
}

# One poll. Sets VERDICT (empty = not decided yet) and DETAIL (extra stdout lines).
VERDICT=""
DETAIL=""
LAST_ERR=""
poll_once() {
  local pr threads head score_line score reviewed den num current unresolved n

  VERDICT=""
  DETAIL=""
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
  if [ "$(printf '%s' "$BOTS_JSON" | jq 'length')" = "0" ]; then
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

  # Is there a review of THIS head yet?
  current=0
  score=""
  if [ -z "$THR_NUM" ]; then
    # Threshold "approved": the gate is reviewDecision. Review of the head is whatever GitHub says.
    [ "$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')" = "APPROVED" ] && current=1
    score_line="$(find_score "$pr")"
    if [ -n "$score_line" ]; then
      reviewed="${score_line#* }"
      if [ -n "$reviewed" ] && case "$head" in "$reviewed"*) true ;; *) false ;; esac; then
        current=1
      fi
    fi
  else
    score_line="$(find_score "$pr")"
    [ -n "$score_line" ] || return 0 # the bot has not published a score at all yet
    score="${score_line%% *}"
    reviewed="${score_line#* }"
    [ "$reviewed" != "$score_line" ] || reviewed=""
    # A score whose commit is missing or is not the head is stale: keep waiting.
    if [ -n "$reviewed" ]; then
      case "$head" in "$reviewed"*) current=1 ;; esac
    fi
  fi
  [ "$current" = "1" ] || return 0

  threads="$(gh api graphql --paginate -f query="$THREADS_QUERY" -F owner="$OWNER" -F name="$NAME" -F number="$WAIT_PR" 2>&1)" || {
    LAST_ERR="gh api graphql failed: $threads"
    return 1
  }
  unresolved="$(printf '%s' "$threads" | jq -s -c '
    [.[] | .data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)]')" || {
    LAST_ERR="could not parse review threads"
    return 1
  }
  n="$(printf '%s' "$unresolved" | jq 'length')"

  if [ "$n" -gt 0 ]; then
    VERDICT="findings:$n"
    DETAIL="$(printf '%s' "$unresolved" | jq -r '.[] |
      "  \(.path // "?"):\((.line // .originalLine // 0))  " +
      ((.comments.nodes[0].body // "") | gsub("\\s+"; " ") | .[0:160])')"
    return 0
  fi

  if [ -z "$THR_NUM" ]; then
    # Default threshold: approved on GitHub, or a current-head review with nothing open.
    if [ "$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')" = "APPROVED" ]; then
      VERDICT="approved"
    fi
    return 0
  fi

  num="${score%%/*}"
  den="${score##*/}"
  if [ "$den" = "$THR_DEN" ] && [ "$num" -ge "$THR_NUM" ]; then
    VERDICT="approved"
  else
    VERDICT="findings:0"
    DETAIL="  score $score is below review.approvalThreshold $THRESHOLD on the head commit; no unresolved thread carries it"
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
      approved | no-review-scheduled) exit 0 ;;
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
