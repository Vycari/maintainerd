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
is_uint "$TIMEOUT_MIN" || die 3 "review.waitTimeoutMinutes must be a non-negative integer"
TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-$((TIMEOUT_MIN * 60))}"
INTERVAL="${WAIT_INTERVAL_SECONDS:-180}"

# review.bots: an absent key means the schema default; an explicit empty array means "no bot".
# Logins are compared with the [bot] suffix stripped: REST says greptile-apps[bot], GraphQL says
# greptile-apps, and a config naming one form must match the other.
BOTS_JSON="$(printf '%s' "$WAIT_CONFIG_JSON" | jq -c '
  if (.review // {}) | has("bots") then .review.bots else ["coderabbitai[bot]","gemini-code-assist[bot]"] end
  | if type == "array" then map(sub("\\[bot\\]$"; "")) else error("bots") end')" ||
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

PR_FIELDS="number,isDraft,state,labels,headRefOid,body,comments,reviews,reviewDecision"
# The latest edit of the PR description is asked for alongside the threads: the description's score
# block is only evidence when a configured bot is who last wrote it (see find_scores).
THREADS_QUERY='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){pullRequest(number:$number){
    userContentEdits(first:1){nodes{editor{login}}}
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{isResolved isOutdated path line originalLine comments(first:1){nodes{body author{login}}}}
    }}}}'

# score_from_text <text> — prints "<n>/<m> <sha>" (sha may be empty) when the text carries a
# `Confidence Score: n/m` token, nothing otherwise. Tolerates markdown around the token.
score_from_text() {
  local text="$1" score sha tail
  score="$(printf '%s' "$text" | tr -d '*' | sed -n 's/.*[Cc]onfidence [Ss]core:[^0-9]*\([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p' | head -n 1)"
  [ -n "$score" ] || return 0
  # The commit is named in the link after "Last reviewed commit:". Greptile's link TEXT is the commit
  # title (`[feat: x](.../commit/<sha>)`) and older shapes use the short sha as the text
  # (`[a1b2c3d](...)`), so the sha is read from the /commit/<sha> URL first, the bracketed text second.
  tail="$(printf '%s' "$text" | tr '\n' ' ' | sed -n 's/.*Last reviewed commit:\(.*\)$/\1/p')"
  sha="$(printf '%s' "$tail" | sed -n 's#.*/commit/\([0-9a-fA-F]\{7,40\}\).*#\1#p' | head -n 1)"
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
  block="$(printf '%s' "$body" | awk '/<!-- greptile_comment -->/{f=1} f{print} /<!-- \/greptile_comment -->/{f=0}')"
  for bot in $(printf '%s' "$BOTS_JSON" | jq -r '.[]'); do
    out=""
    if [ -n "$block" ] && [ "$editor" = "$bot" ]; then
      out="$(score_from_text "$block")"
    fi
    for kind in comments reviews; do
      [ -z "$out" ] || break
      cands="$(printf '%s' "$pr" | jq -c --arg bot "$bot" "
        [.${kind}[]? | select((.author.login // \"\" | sub(\"\\\\[bot\\\\]\$\"; \"\")) == \$bot)] | reverse | .[] | .body")"
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
  decision="$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')"

  gql="$(gh api graphql --paginate -f query="$THREADS_QUERY" -F owner="$OWNER" -F name="$NAME" -F number="$WAIT_PR" 2>&1)" || {
    LAST_ERR="gh api graphql failed: $gql"
    return 1
  }
  threads="$(printf '%s' "$gql" | jq -s -c '
    [.[] | .data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)]')" || {
    LAST_ERR="could not parse review threads"
    return 1
  }
  editor="$(printf '%s' "$gql" | jq -s -r '[.[] | .data.repository.pullRequest.userContentEdits.nodes[0].editor.login // empty][0] // "" | sub("\\[bot\\]$"; "")')" || editor=""
  unresolved="$threads"
  n="$(printf '%s' "$unresolved" | jq 'length')"

  # Is there a review of THIS head yet? Every configured bot that has published a score must have
  # scored the head (else its score is stale and we keep waiting), and — numeric threshold — every
  # one of them must meet the bar. Absence of any score is "not reviewed yet", never a pass.
  scores="$(find_scores "$pr" "$editor")"
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
    [ "$decision" = "APPROVED" ] && VERDICT="approved"
    return 0
  fi
  if [ "$all_met" = "1" ]; then
    VERDICT="approved"
    DETAIL=""
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
