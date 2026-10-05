#!/usr/bin/env bash
# Shared helpers for wait-for-review.sh and wait-for-checks.sh. Source it; do not execute it.
#
# Requires: bash 3.2+, gh, jq. No other dependencies, and nothing here writes to GitHub: these
# tools observe a PR and report a verdict, they never fix, label, comment, or merge.

# die <code> <message...> — a usage or environment error. Exit 3 is reserved for "the tool could
# not do its job", which is a different thing from a verdict (0/1/2) and must never be mistaken
# for one.
die() {
  local code="$1"
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

# is_uint <value> — true for a non-negative integer.
is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# parse_common_args "$@" — sets WAIT_PR, WAIT_REPO (may be empty), WAIT_TIMEOUT_SECONDS (may be empty),
# WAIT_INTERVAL_SECONDS (may be empty), WAIT_CONFIG (may be empty), and leaves any flag it does
# not recognise in WAIT_REST (space-joined) for the caller. Usage errors exit 3.
parse_common_args() {
  WAIT_PR=""
  WAIT_REPO=""
  WAIT_TIMEOUT_SECONDS=""
  WAIT_INTERVAL_SECONDS=""
  WAIT_CONFIG=""
  WAIT_REST=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R | --repo)
        [ "$#" -ge 2 ] || die 3 "$1 needs a value"
        WAIT_REPO="$2"
        shift 2
        ;;
      --repo=*)
        WAIT_REPO="${1#--repo=}"
        shift
        ;;
      --timeout-seconds)
        [ "$#" -ge 2 ] || die 3 "$1 needs a value"
        WAIT_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --interval-seconds)
        [ "$#" -ge 2 ] || die 3 "$1 needs a value"
        WAIT_INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --config)
        [ "$#" -ge 2 ] || die 3 "$1 needs a value"
        WAIT_CONFIG="$2"
        shift 2
        ;;
      -h | --help)
        WAIT_HELP=1
        shift
        ;;
      -*)
        WAIT_REST="$WAIT_REST $1"
        shift
        ;;
      *)
        [ -z "$WAIT_PR" ] || die 3 "unexpected extra argument: $1"
        WAIT_PR="$1"
        shift
        ;;
    esac
  done
  if [ -n "$WAIT_PR" ]; then
    # Accept a PR URL as well as a number.
    WAIT_PR="${WAIT_PR##*/pull/}"
    WAIT_PR="${WAIT_PR%%[/?#]*}"
    is_uint "$WAIT_PR" || die 3 "PR must be a number or a pull request URL"
  fi
  [ -z "$WAIT_TIMEOUT_SECONDS" ] || is_uint "$WAIT_TIMEOUT_SECONDS" || die 3 "--timeout-seconds must be a non-negative integer"
  [ -z "$WAIT_INTERVAL_SECONDS" ] || is_uint "$WAIT_INTERVAL_SECONDS" || die 3 "--interval-seconds must be a non-negative integer"
}

# resolve_repo — sets WAIT_REPO to owner/name, from -R or from the current checkout.
resolve_repo() {
  [ -n "$WAIT_REPO" ] && return 0
  WAIT_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || WAIT_REPO=""
  [ -n "$WAIT_REPO" ] || die 3 "could not determine the repository; pass -R owner/repo"
}

# config_file — path of .claude/maintainerd.json for the current checkout, or empty.
config_file() {
  local f root
  if [ -n "$WAIT_CONFIG" ]; then
    printf '%s' "$WAIT_CONFIG"
    return
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  f="$root/.claude/maintainerd.json"
  [ -f "$f" ] && printf '%s' "$f"
  return 0
}

# cfg <jq-expr> <default> — read a value from the config; the default when the file, the key, or
# a null is absent. A config file that exists but is not valid JSON is an error, not a default:
# silently ignoring a broken threshold would turn a 5/5 gate into "approved".
cfg() {
  local expr="$1" default="$2" f v
  f="$(config_file)"
  if [ -z "$f" ]; then
    printf '%s' "$default"
    return
  fi
  v="$(jq -r "($expr) // empty" "$f" 2>/dev/null)" || die 3 "$f is not valid JSON"
  if [ -z "$v" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$v"
  fi
}

now() { date +%s; }

# sleep_within <seconds> <deadline> — sleep, but never past the deadline.
sleep_within() {
  local want="$1" deadline="$2" left
  left=$((deadline - $(now)))
  [ "$left" -gt 0 ] || return 0
  [ "$want" -le "$left" ] || want="$left"
  [ "$want" -gt 0 ] && sleep "$want"
  return 0
}
