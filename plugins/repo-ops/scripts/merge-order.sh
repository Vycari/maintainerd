#!/usr/bin/env bash
#
# merge-order.sh — compute the order a set of PRs should land in, and (with --watch) report each
# one as it lands.
#
#   merge-order.sh <pr> [<pr> ...] [-R owner/repo] [--watch]
#
# Every PR must be in the one repository (-R, a PR URL, or the current checkout's). The first line of
# stdout is the order:
#
#   order: #84 #86 #90       the sequence to merge in. One numbered line per PR follows, with what
#                            it needs first and which other PRs in the set touch the same files.
#   nothing-to-merge         every PR in the set has already merged or been closed.
#
# How the order is computed — structure, not judgment:
#   * dependencies. A PR needs another PR in the set when its description says so
#     (`Depends on #N`, `Stacked on #N`, `Blocked by #N`, `Requires #N`, any case; several numbers may
#     follow one phrase) or when its base branch is that PR's head branch (a stack). A dependency on
#     a PR outside the set is not an ordering constraint, but an OPEN one is reported. The
#     description is author-writable text, so it can only reorder the report, never approve anything.
#   * among PRs whose dependencies are met, the lowest PR number goes first.
#   * file overlap. PRs that change a file in common are listed against each other: whichever lands
#     second will likely need a rebase. Overlap does not reorder; it tells you where to expect work.
#   A dependency cycle is an error (exit 3), never a guessed order.
#
# --watch then polls (every --interval-seconds, default 180; until --timeout-seconds, default 3600)
# and prints one line per event as it happens:
#
#   queued: #N q<position>   the PR entered the base branch's merge queue (GraphQL mergeQueue)
#   landed: #N               the PR merged; `(out of order, expected #M first)` when M was due first
#   closed: #N               the PR was closed without merging
#   next: #M                 the next PR in the order that is still open
#
# and ends on exactly one verdict line: `all-landed` (exit 0), `done: <m> landed, <c> closed
# unmerged` (exit 1), or `timeout` followed by the PRs still open (exit 2). It is never "still
# waiting". Exit 3 means the tool could not run (usage, the first read failed, a cycle).
#
# Reports; never merges. It does not merge, enqueue, enable auto-merge, rebase, comment or edit:
# the order is advice for the maintainer, who merges.
#
# Requires: bash 3.2+, gh, jq.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/queue-common.sh
. "$HERE/lib/queue-common.sh"

REPO=""
URL_REPO=""
WATCH=0
TIMEOUT_SECONDS=3600
INTERVAL=180
PRS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R | --repo)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --watch)
      WATCH=1
      shift
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      is_uint "$2" || die 3 "--timeout-seconds must be a non-negative integer"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --interval-seconds)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      is_uint "$2" || die 3 "--interval-seconds must be a non-negative integer"
      INTERVAL="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die 3 "unknown flag: $1" ;;
    *)
      resolve_pr_arg "$1"
      if [ -n "$PR_URL_REPO" ]; then
        [ -z "$URL_REPO" ] || [ "$URL_REPO" = "$PR_URL_REPO" ] ||
          die 3 "$1 is in $PR_URL_REPO, not $URL_REPO: one invocation orders PRs of one repository"
        URL_REPO="$PR_URL_REPO"
      fi
      case " $PRS " in *" $PR_NUM "*) ;; *) PRS="$PRS $PR_NUM" ;; esac
      shift
      ;;
  esac
done
[ -n "$PRS" ] || die 3 "usage: merge-order.sh <pr> [<pr> ...] [-R owner/repo] [--watch]"
if [ -n "$URL_REPO" ]; then
  [ -z "$REPO" ] || [ "$REPO" = "$URL_REPO" ] || die 3 "-R $REPO contradicts the repository in the PR URL ($URL_REPO)"
  REPO="$URL_REPO"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=""
  [ -n "$REPO" ] || die 3 "could not determine the repository; pass -R owner/repo"
fi

# --- read the set --------------------------------------------------------------------------------

# stated_deps <body> — PR numbers a description says it depends on, one per line.
stated_deps() {
  local el='(\[?#[0-9]+\]?(\([^)]*\))?|https?://[^ )]*/pull/[0-9]+)'
  printf '%s' "$1" |
    grep -oiE "(depends on|stacked on|blocked by|requires)[: ]+((prs?|pull requests?)[: ]+)?$el(,? *(and )?$el)*" |
    grep -oE '#[0-9]+|/pull/[0-9]+' | tr -d '#' | sed 's#^/pull/##' | sort -un
}

OPEN="[]"
MERGED=""
CLOSED=""
for n in $PRS; do
  v="$(gh pr view "$n" -R "$REPO" --json number,title,state,body,headRefName,baseRefName,files </dev/null 2>&1)" ||
    die 3 "could not read PR #$n in $REPO: $v"
  printf '%s' "$v" | jq -e 'type == "object"' >/dev/null 2>&1 || die 3 "PR #$n: gh pr view returned non-JSON"
  case "$(printf '%s' "$v" | jq -r '.state')" in
    MERGED) MERGED="$MERGED $n" ;;
    CLOSED) CLOSED="$CLOSED $n" ;;
    *)
      stated="$(stated_deps "$(printf '%s' "$v" | jq -r '.body // ""')" | jq -R 'tonumber' | jq -s -c .)"
      OPEN="$(printf '%s' "$OPEN" | jq -c --argjson v "$v" --argjson st "$stated" '. + [{
        number: $v.number, title: ($v.title | gsub("[\n\t]"; " ")), head: $v.headRefName, base: $v.baseRefName,
        files: [$v.files[]?.path], stated: $st}]')"
      ;;
  esac
done

# --- compute the order ---------------------------------------------------------------------------

PLAN="$(printf '%s' "$OPEN" | jq -c '
  . as $prs
  | ($prs | map(.number)) as $all
  | ($prs | map(. as $p | {number: $p.number, title: $p.title, base: $p.base,
      needs: ([$p.stated[] | select(. != $p.number) | select(. as $d | $all | index($d)) | {pr: ., why: "stated"}]
              + [$prs[] | select(.head == $p.base and .number != $p.number) | {pr: .number, why: "stacked: its base is this PR branch"}]),
      overlaps: [$prs[] | select(.number != $p.number) | . as $o
                 | ([$p.files[] | select(. as $f | $o.files | index($f))]) as $c
                 | select($c | length > 0) | {pr: $o.number, files: $c}]})) as $nodes
  | {done: [], rest: ($all | sort)}
  | until(.rest | length == 0;
      . as $s
      | [$s.rest[] | . as $n
         | select(($nodes[] | select(.number == $n) | .needs | map(.pr)) | all(. as $d | ($s.rest | index($d)) | not))] as $ready
      | if ($ready | length) == 0
        then error("dependency cycle among " + ($s.rest | map("#" + tostring) | join(", ")))
        else {done: ($s.done + [$ready[0]]), rest: ($s.rest - [$ready[0]])} end)
  | .done | map(. as $n | $nodes[] | select(.number == $n))' 2>&1)" || die 3 "could not order the PRs: $PLAN"

# An OPEN dependency outside the set is worth a line; a merged or non-PR one is not.
EXTERNAL=""
for n in $(printf '%s' "$OPEN" | jq -r '[.[] | .stated[]] | unique | .[]'); do
  case " $PRS " in *" $n "*) continue ;; esac
  s="$(gh pr view "$n" -R "$REPO" --json state -q .state </dev/null 2>/dev/null)" || continue
  [ "$s" != "OPEN" ] || EXTERNAL="$EXTERNAL $n"
done

# A PR based on the branch of an OPEN PR that is not in the set is an open stack dependency too.
for b in $(printf '%s' "$OPEN" | jq -r --argjson heads "$(printf '%s' "$OPEN" | jq -c 'map(.head)')" \
  '[.[] | .base | select(. as $b | $heads | index($b) | not)] | unique | .[]'); do
  m="$(gh pr list -R "$REPO" --head "$b" --state open --json number -q '.[0].number // empty' </dev/null 2>/dev/null)" || continue
  [ -z "$m" ] || EXTERNAL="$EXTERNAL $m"
done

ORDER_LINE="$(printf '%s' "$PLAN" | jq -r 'map("#\(.number)") | join(" ")')"
skipped_notes() {
  for n in $MERGED; do printf '  already merged: #%s\n' "$n"; done
  for n in $CLOSED; do printf '  closed (not merged): #%s\n' "$n"; done
}

if [ -z "$ORDER_LINE" ]; then
  echo "nothing-to-merge"
  skipped_notes
  [ -z "$CLOSED" ] || exit 1
  exit 0
fi

echo "order: $ORDER_LINE"
printf '%s' "$PLAN" | jq -r '
  to_entries[] | .key as $i | .value |
  "  \($i + 1). #\(.number)  \(.title | .[0:70])",
  (if (.needs | length) > 0 then "       needs: " + (.needs | map("#\(.pr) (\(.why))") | join(", ")) else empty end),
  (if (.overlaps | length) > 0 then
     "       shares files with: " + (.overlaps | map("#\(.pr) [" + (.files[0:3] | join(", ")) +
       (if (.files | length) > 3 then ", +\(.files | length - 3) more" else "" end) + "]") | join("; "))
   else empty end)'
skipped_notes
for n in $(printf '%s\n' $EXTERNAL | sort -un); do
  printf '  note: #%s is open, outside this set, and a PR in it depends on it\n' "$n"
done
[ "$WATCH" = "1" ] || exit 0

# --- watch ---------------------------------------------------------------------------------------

# LEFT: the open PRs still being watched, in order. LANDED / UNMERGED count what has finished.
LEFT="$(printf '%s' "$PLAN" | jq -r 'map(.number) | join(" ")')"
BASES="$(printf '%s' "$PLAN" | jq -r 'map(.base) | unique | join(" ")')"
LANDED_N=0
UNMERGED_N=0
QSEEN="" # "<pr>:<position>" for the queue entries already announced
LAST_ERR=""

# poll_watch — read every watched PR's state once and print an event for each change. Sets LEFT.
poll_watch() {
  local n s still="" expected q pos base lines="" seen
  for n in $LEFT; do
    s="$(gh pr view "$n" -R "$REPO" --json state -q .state </dev/null 2>&1)" || {
      LAST_ERR="gh pr view #$n failed: $s"
      still="$still $n"
      continue
    }
    expected="${LEFT%% *}"
    case "$s" in
      MERGED)
        LANDED_N=$((LANDED_N + 1))
        if [ "$n" = "$expected" ]; then
          printf 'landed: #%s\n' "$n"
        else
          printf 'landed: #%s (out of order, expected #%s first)\n' "$n" "$expected"
        fi
        ;;
      CLOSED)
        UNMERGED_N=$((UNMERGED_N + 1))
        printf 'closed: #%s\n' "$n"
        ;;
      *) still="$still $n" ;;
    esac
  done
  LEFT="${still# }"
  for base in $BASES; do
    fetch_queue "$REPO" "$base" </dev/null || {
      LAST_ERR="$QUEUE_ERR"
      continue
    }
    lines="$lines
$QUEUE_LINES"
  done
  for n in $LEFT; do
    pos="$(printf '%s\n' "$lines" | awk -v n="$n" '$1 == n { print $2; exit }')"
    [ -n "$pos" ] || continue
    seen="$n:$pos"
    case " $QSEEN " in *" $seen "*) continue ;; esac
    QSEEN="$QSEEN $seen"
    printf 'queued: #%s q%s\n' "$n" "$pos"
  done
  return 0
}

deadline=$(($(now) + TIMEOUT_SECONDS))
first=1
while :; do
  before="$LEFT"
  poll_watch
  if [ "$first" = "1" ] && [ "$LEFT" = "$before" ] && [ -n "$LAST_ERR" ]; then
    # Nothing could be read on the first look: a setup problem, not a slow merge.
    die 3 "$LAST_ERR"
  fi
  first=0
  if [ -z "$LEFT" ]; then
    if [ "$UNMERGED_N" = "0" ]; then
      echo "all-landed"
      exit 0
    fi
    echo "done: $LANDED_N landed, $UNMERGED_N closed unmerged"
    exit 1
  fi
  [ "$LEFT" = "$before" ] || printf 'next: #%s\n' "${LEFT%% *}"
  if [ "$(now)" -ge "$deadline" ]; then
    echo "timeout"
    for n in $LEFT; do printf '  still open: #%s\n' "$n"; done
    [ -z "$LAST_ERR" ] || printf 'last error: %s\n' "$LAST_ERR" >&2
    exit 2
  fi
  sleep_within "$INTERVAL" "$deadline"
done
