#!/usr/bin/env bash
#
# wait-for-checks.sh — block until a PR's checks reach a verdict, then print it.
#
#   wait-for-checks.sh <pr> [-R owner/repo]
#
# Reads the PR's statusCheckRollup (always the head commit's checks) and prints a verdict on the
# first line of stdout:
#
#   green                  every check has finished and none failed (success, neutral and skipped
#                          all count as not failed).
#   failed:<job>           a check failed. <job> is the JOB's name (the unit that has a log and a
#                          runner), not the workflow run's. The failing job's log tail follows,
#                          indented, from `gh run view --job <id> --log-failed` — job-level, so a
#                          run with ten jobs yields the one that broke. Failure is reported as soon
#                          as it is seen, without waiting for the other checks to finish.
#                          failure, timed_out, cancelled, startup_failure and action_required all
#                          count as failed: each leaves the PR unmergeable.
#   queued-no-runner       a job has sat queued longer than the threshold (default 10 minutes) and
#                          the Actions API says no runner was assigned to it. The job name follows
#                          on the next line. A queued job whose assignment cannot be confirmed is
#                          NOT reported this way; it keeps waiting.
#   timeout                no verdict by the deadline (review.waitTimeoutMinutes, default 20 — the
#                          same bound as wait-for-review). An empty rollup keeps waiting: checks
#                          register a little after a push.
#
# Exit status: 0 green, 1 failed, 2 timeout or queued-no-runner, 3 the tool could not run.
#
# Observe only. It never re-runs a job, cancels a run, restarts a runner, or touches the PR.
#
# Flags: --timeout-seconds N, --interval-seconds N (default 180), --queue-threshold-seconds N
# (default 600), --config FILE.
#
# Requires: bash 3.2+, gh, jq.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wait-common.sh
. "$HERE/lib/wait-common.sh"

# This script owns one extra flag; peel it off before the shared parser sees it.
QUEUE_THRESHOLD=600
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --queue-threshold-seconds)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      QUEUE_THRESHOLD="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
is_uint "$QUEUE_THRESHOLD" || die 3 "--queue-threshold-seconds must be a non-negative integer"

WAIT_HELP=""
parse_common_args ${args[@]+"${args[@]}"}
if [ -n "$WAIT_HELP" ]; then
  sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ -n "$WAIT_PR" ] || die 3 "usage: wait-for-checks.sh <pr> [-R owner/repo]"
[ -z "$WAIT_REST" ] || die 3 "unknown flag:$WAIT_REST"

TIMEOUT_MIN="$(cfg '.review.waitTimeoutMinutes' '20')"
is_uint "$TIMEOUT_MIN" || die 3 "review.waitTimeoutMinutes must be a non-negative integer"
TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-$((TIMEOUT_MIN * 60))}"
INTERVAL="${WAIT_INTERVAL_SECONDS:-180}"

resolve_repo

# job_id_of <detailsUrl> — the Actions job id in .../actions/runs/<run>/job/<job>, else empty.
job_id_of() {
  printf '%s' "$1" | sed -n 's#.*/actions/runs/[0-9][0-9]*/job/\([0-9][0-9]*\).*#\1#p'
}

# iso_to_epoch <ISO-8601 UTC> — epoch seconds, bash 3.2 / BSD and GNU date both. Empty on failure.
iso_to_epoch() {
  local t="$1" e
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null)" || e=""
  [ -n "$e" ] || e="$(date -u -d "$t" +%s 2>/dev/null)" || e=""
  printf '%s' "$e"
}

VERDICT=""
DETAIL=""
LAST_ERR=""
poll_once() {
  local pr norm failed name url jid log queued started age now_s job_json runner

  VERDICT=""
  DETAIL=""
  pr="$(gh pr view "$WAIT_PR" -R "$WAIT_REPO" --json statusCheckRollup,state 2>&1)" || {
    LAST_ERR="gh pr view failed: $pr"
    return 1
  }
  # Normalise CheckRun and StatusContext into one shape:
  #   name, state (SUCCESS|FAILED|PENDING|QUEUED), url, started
  norm="$(printf '%s' "$pr" | jq -c '
    [.statusCheckRollup[]? |
      if .__typename == "StatusContext" then
        {name: .context, url: (.targetUrl // ""), started: (.startedAt // ""),
         state: (if .state == "SUCCESS" then "SUCCESS"
                 elif (.state == "FAILURE" or .state == "ERROR") then "FAILED"
                 else "PENDING" end)}
      else
        {name: (.name // "?"), url: (.detailsUrl // ""), started: (.startedAt // ""),
         state: (if .status == "COMPLETED" then
                   (if (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED")) then "SUCCESS" else "FAILED" end)
                 elif (.status == "QUEUED" or .status == "WAITING" or .status == "PENDING") then "QUEUED"
                 else "PENDING" end)}
      end]' 2>/dev/null)" || {
    LAST_ERR="could not parse statusCheckRollup"
    return 1
  }

  failed="$(printf '%s' "$norm" | jq -c '[.[] | select(.state == "FAILED")] | .[0] // empty')"
  if [ -n "$failed" ]; then
    name="$(printf '%s' "$failed" | jq -r '.name')"
    url="$(printf '%s' "$failed" | jq -r '.url')"
    VERDICT="failed:$name"
    jid="$(job_id_of "$url")"
    if [ -n "$jid" ]; then
      log="$(gh run view --job "$jid" -R "$WAIT_REPO" --log-failed 2>&1 | tail -n 40)"
      [ -n "$log" ] || log="(the job log is empty)"
      DETAIL="$(printf '%s\n' "$log" | sed 's/^/  /')"
    else
      DETAIL="  (no Actions job log: this check is not a GitHub Actions job; see ${url:-its provider})"
    fi
    return 0
  fi

  # Stuck in the queue: queued past the threshold AND the API says no runner was assigned.
  now_s="$(now)"
  queued="$(printf '%s' "$norm" | jq -c '.[] | select(.state == "QUEUED")')"
  if [ -n "$queued" ]; then
    while IFS= read -r q; do
      started="$(printf '%s' "$q" | jq -r '.started')"
      [ -n "$started" ] || continue
      started="$(iso_to_epoch "$started")"
      [ -n "$started" ] || continue
      age=$((now_s - started))
      [ "$age" -ge "$QUEUE_THRESHOLD" ] || continue
      jid="$(job_id_of "$(printf '%s' "$q" | jq -r '.url')")"
      [ -n "$jid" ] || continue
      job_json="$(gh api "repos/$WAIT_REPO/actions/jobs/$jid" 2>/dev/null)" || continue
      runner="$(printf '%s' "$job_json" | jq -r 'if .status == "queued" and (.runner_id == null) then "none" else "some" end' 2>/dev/null)" || continue
      if [ "$runner" = "none" ]; then
        VERDICT="queued-no-runner"
        DETAIL="  $(printf '%s' "$q" | jq -r '.name') (queued $((age / 60)) min)"
        return 0
      fi
    done <<<"$queued"
  fi

  # Green only when there is something to be green about and nothing is still moving.
  if [ "$(printf '%s' "$norm" | jq 'length')" -gt 0 ] &&
    [ "$(printf '%s' "$norm" | jq '[.[] | select(.state != "SUCCESS")] | length')" = "0" ]; then
    VERDICT="green"
  fi
  return 0
}

deadline=$(($(now) + TIMEOUT_SECONDS))
first=1
while :; do
  if poll_once; then
    first=0
  elif [ "$first" = "1" ]; then
    die 3 "$LAST_ERR"
  fi
  if [ -n "$VERDICT" ]; then
    printf '%s\n' "$VERDICT"
    [ -z "$DETAIL" ] || printf '%s\n' "$DETAIL"
    case "$VERDICT" in
      green) exit 0 ;;
      failed:*) exit 1 ;;
      *) exit 2 ;;
    esac
  fi
  if [ "$(now)" -ge "$deadline" ]; then
    printf 'timeout\n'
    [ -z "$LAST_ERR" ] || printf 'last error: %s\n' "$LAST_ERR" >&2
    exit 2
  fi
  sleep_within "$INTERVAL" "$deadline"
done
