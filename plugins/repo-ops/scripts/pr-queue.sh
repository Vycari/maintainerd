#!/usr/bin/env bash
#
# pr-queue.sh — one table of every open PR in one or more repos: review verdict, check verdict,
# mergeability, merge-queue position, and the single reason each one is not ready.
#
#   pr-queue.sh [owner/repo ...] [-R owner/repo ...] [--json]
#
# With no repository it reads the current checkout's. Columns:
#
#   REVIEW    approved | findings:<n> | no-review-scheduled | pending | error | - (draft)
#   CHECKS    green | failed:<job> | queued-no-runner | pending | error | - (draft)
#   MERGE     ok | conflict | behind | unknown      (from GitHub's mergeable / mergeStateStatus)
#   QUEUE     q<position> when the PR is in the base branch's merge queue, q<position>! when its
#             entry is UNMERGEABLE (not progressing), - otherwise. From GraphQL mergeQueue only.
#   BLOCKING  the first thing standing between the PR and "ready", or `ready`.
#
# The verdicts are wait-for-review.sh and wait-for-checks.sh run once (--timeout-seconds 0), so
# "ready" is exactly their rule: the review.approvalThreshold score on the head commit, every check
# green, and 0 unresolved threads — judged with each target repo's own .claude/maintainerd.json. A
# review or check that has not finished is `pending`. `green` here is a single read of the rollup
# (--settle-seconds 0): this is a snapshot, not a gate; use wait-for-checks.sh before acting on it.
#
# --json prints the records (one object per PR) instead of the table.
#
# Exit status: 0 the table was printed (a PR that could not be read shows `error` in its row),
# 3 the tool could not run (bad usage, a repository's PR list could not be read).
#
# Observe only. It never merges, enqueues, enables auto-merge, labels, comments or edits anything:
# deciding what to merge is the maintainer's.
#
# Test hooks: PR_QUEUE_WAIT_FOR_REVIEW and PR_QUEUE_WAIT_FOR_CHECKS name replacement verdict scripts.
#
# Requires: bash 3.2+, gh, jq, column.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/queue-common.sh
. "$HERE/lib/queue-common.sh"

WFR="${PR_QUEUE_WAIT_FOR_REVIEW:-$HERE/wait-for-review.sh}"
WFC="${PR_QUEUE_WAIT_FOR_CHECKS:-$HERE/wait-for-checks.sh}"

REPOS=()
AS_JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R | --repo)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      REPOS+=("$2")
      shift 2
      ;;
    --repo=*)
      REPOS+=("${1#--repo=}")
      shift
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    -h | --help)
      sed -n '3,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die 3 "unknown flag: $1" ;;
    */*)
      REPOS+=("$1")
      shift
      ;;
    *) die 3 "'$1' is not an owner/repo" ;;
  esac
done
if [ "${#REPOS[@]}" -eq 0 ]; then
  here="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || here=""
  [ -n "$here" ] || die 3 "could not determine the repository; pass owner/repo"
  REPOS+=("$here")
fi

# verdict_of <rc> <stdout> — the first line of a wait tool's stdout, mapped for a one-shot read:
# a `timeout` means "not decided yet", and a tool that could not run is `error`.
verdict_of() {
  local first
  [ "$1" != "3" ] || {
    printf 'error'
    return 0
  }
  first="$(printf '%s\n' "$2" | head -n 1 | tr -d '\r')"
  case "$first" in
    approved | no-review-scheduled | green | queued-no-runner | findings:* | failed:*) printf '%s' "$first" ;;
    timeout) printf 'pending' ;;
    *) printf 'error' ;;
  esac
}

RECORDS="[]"
for repo in "${REPOS[@]}"; do
  list="$(gh pr list -R "$repo" --state open --limit 200 \
    --json number,title,isDraft,mergeable,mergeStateStatus,baseRefName,author </dev/null 2>&1)" ||
    die 3 "could not list $repo's open PRs: $list"
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || die 3 "$repo: gh pr list returned non-JSON"

  # One queue read per distinct base branch.
  QUEUES=""
  QUEUE_FAILED=""
  for base in $(printf '%s' "$list" | jq -r '[.[].baseRefName] | unique | .[]'); do
    if fetch_queue "$repo" "$base" </dev/null; then
      [ -z "$QUEUE_LINES" ] || QUEUES="$QUEUES$(printf '%s\n' "$QUEUE_LINES" | awk -v b="$base" '{ print b, $0 }')
"
    else
      QUEUE_FAILED="$QUEUE_FAILED $base"
    fi
  done

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n="$(printf '%s' "$p" | jq -r '.number')"
    draft="$(printf '%s' "$p" | jq -r '.isDraft')"
    base="$(printf '%s' "$p" | jq -r '.baseRefName')"

    review="-"
    checks="-"
    if [ "$draft" != "true" ]; then
      out="$("$WFR" "$n" -R "$repo" --timeout-seconds 0 </dev/null 2>/dev/null)"
      review="$(verdict_of "$?" "$out")"
      out="$("$WFC" "$n" -R "$repo" --timeout-seconds 0 --settle-seconds 0 </dev/null 2>/dev/null)"
      checks="$(verdict_of "$?" "$out")"
    fi

    merge="ok"
    case "$(printf '%s' "$p" | jq -r '"\(.mergeable) \(.mergeStateStatus)"')" in
      CONFLICTING* | *" DIRTY") merge="conflict" ;;
      *" BLOCKED") merge="blocked" ;;
      *" BEHIND") merge="behind" ;;
      UNKNOWN* | *" UNKNOWN") merge="unknown" ;;
    esac

    qpos=""
    qstate=""
    qline="$(printf '%s' "$QUEUES" | awk -v b="$base" -v n="$n" '$1 == b && $2 == n { print $3, $4; exit }')"
    if [ -n "$qline" ]; then
      qpos="${qline%% *}"
      qstate="${qline##* }"
    fi
    qfailed=0
    case " $QUEUE_FAILED " in *" $base "*) qfailed=1 ;; esac

    # The first thing in the way, in the order a person would act on it.
    ready=false
    blocking=""
    if [ "$draft" = "true" ]; then
      blocking="draft"
    else
      case "$checks" in
        failed:*) blocking="checks failed: ${checks#failed:}" ;;
        queued-no-runner) blocking="checks stuck: queued with no runner" ;;
      esac
      if [ -z "$blocking" ]; then
        case "$review" in
          findings:0) blocking="review: score below the approval threshold" ;;
          findings:*) blocking="review: ${review#findings:} unresolved thread(s)" ;;
        esac
      fi
      if [ -z "$blocking" ]; then
        if [ "$review" = "error" ] || [ "$checks" = "error" ]; then
          blocking="could not read the review or check verdict"
        elif [ "$merge" = "conflict" ]; then
          blocking="merge conflict with $base"
        elif [ "$review" = "pending" ]; then
          blocking="awaiting review of the head commit"
        elif [ "$checks" = "pending" ]; then
          blocking="checks still running"
        elif [ "$qfailed" = "1" ]; then
          blocking="merge queue state unreadable"
        elif [ -n "$qpos" ]; then
          blocking="in the merge queue"
          [ "$qstate" != "UNMERGEABLE" ] || blocking="in the merge queue, entry UNMERGEABLE"
        elif [ "$merge" = "blocked" ]; then
          blocking="GitHub reports the merge blocked: a protection requirement the verdicts do not cover is unmet"
        else
          blocking="ready"
          ready=true
        fi
      fi
    fi

    rec="$(jq -n -c \
      --arg repo "$repo" --argjson number "$n" --arg title "$(printf '%s' "$p" | jq -r '.title' | tr '\n\t' '  ')" \
      --arg author "$(printf '%s' "$p" | jq -r '.author.login // "?"')" --argjson draft "$draft" \
      --arg review "$review" --arg checks "$checks" --arg merge "$merge" --arg base "$base" \
      --arg qpos "$qpos" --arg qstate "$qstate" --arg blocking "$blocking" --argjson ready "$ready" \
      '{repo: $repo, number: $number, title: $title, author: $author, draft: $draft, base: $base,
        review: $review, checks: $checks, merge: $merge,
        queue: (if $qpos == "" then null else {position: ($qpos | tonumber), state: $qstate} end),
        blocking: $blocking, ready: $ready}')"
    RECORDS="$(printf '%s' "$RECORDS" | jq -c --argjson r "$rec" '. + [$r]')"
  done < <(printf '%s' "$list" | jq -c 'sort_by(.number) | .[]')
done

if [ "$AS_JSON" = "1" ]; then
  printf '%s\n' "$RECORDS" | jq .
  exit 0
fi

total="$(printf '%s' "$RECORDS" | jq 'length')"
if [ "$total" = "0" ]; then
  echo "no open PRs"
  exit 0
fi
command -v column >/dev/null 2>&1 || die 3 "the column utility is required to print the table (use --json without it)"
{
  printf 'REPO\tPR\tAUTHOR\tREVIEW\tCHECKS\tMERGE\tQUEUE\tBLOCKING\tTITLE\n'
  printf '%s' "$RECORDS" | jq -r '.[] | [
    .repo, "#\(.number)", .author, .review, .checks, .merge,
    (if .queue then "q\(.queue.position)" + (if .queue.state == "UNMERGEABLE" then "!" else "" end) else "-" end),
    .blocking, (.title | .[0:60])] | @tsv'
} | column -t -s "$(printf '\t')" || die 3 "could not format the table"
printf '\n%s open PRs; %s ready, %s in the merge queue.\n' "$total" \
  "$(printf '%s' "$RECORDS" | jq '[.[] | select(.ready)] | length')" \
  "$(printf '%s' "$RECORDS" | jq '[.[] | select(.queue != null)] | length')"
