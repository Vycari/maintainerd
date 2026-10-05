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
    # Accept a PR URL as well as a number. The URL names its repository, and that is the repository
    # to poll: resolving it from the current checkout instead would verdict a same-numbered PR in
    # the wrong repo.
    case "$WAIT_PR" in
      http*://*/pull/*)
        url_repo="${WAIT_PR#*://*/}"
        url_repo="$(printf '%s' "$url_repo" | cut -d/ -f1,2)"
        if [ -n "$WAIT_REPO" ] && [ "$WAIT_REPO" != "$url_repo" ]; then
          die 3 "-R $WAIT_REPO contradicts the repository in the PR URL ($url_repo)"
        fi
        WAIT_REPO="$url_repo"
        ;;
    esac
    WAIT_PR="${WAIT_PR##*/pull/}"
    WAIT_PR="${WAIT_PR%%[/?#]*}"
    is_uint "$WAIT_PR" || die 3 "PR must be a number or a pull request URL"
  fi
  [ -z "$WAIT_TIMEOUT_SECONDS" ] || is_uint "$WAIT_TIMEOUT_SECONDS" || die 3 "--timeout-seconds must be a non-negative integer"
  [ -z "$WAIT_INTERVAL_SECONDS" ] || is_uint "$WAIT_INTERVAL_SECONDS" || die 3 "--interval-seconds must be a non-negative integer"
}

# resolve_repo — sets WAIT_REPO to owner/name (from -R / the PR URL, else the current checkout), and
# WAIT_REPO_EXPLICIT=1 when it was named rather than inferred.
resolve_repo() {
  WAIT_REPO_EXPLICIT=0
  if [ -n "$WAIT_REPO" ]; then
    WAIT_REPO_EXPLICIT=1
    return 0
  fi
  WAIT_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || WAIT_REPO=""
  [ -n "$WAIT_REPO" ] || die 3 "could not determine the repository; pass -R owner/repo"
}

# load_config — sets WAIT_CONFIG_JSON to the review policy of the repository being waited on.
# That is the checkout's .claude/maintainerd.json when the checkout IS the target repo, and the
# target's own file (default branch, via the contents API) when -R or a PR URL names another one:
# judging repo B's PR by repo A's bots, threshold and skip label would be a wrong verdict that
# looks right. No config at all is `{}` (schema defaults); a config that cannot be parsed, or a
# fetch that fails for any reason but "not found", is an error, never a silent default.
load_config() {
  local f here out
  WAIT_CONFIG_JSON="{}"
  if [ -n "$WAIT_CONFIG" ]; then
    [ -f "$WAIT_CONFIG" ] || die 3 "--config $WAIT_CONFIG does not exist"
    WAIT_CONFIG_JSON="$(cat "$WAIT_CONFIG")"
  else
    here=""
    if [ "$WAIT_REPO_EXPLICIT" = "1" ]; then
      here="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || here=""
    else
      here="$WAIT_REPO"
    fi
    if [ "$here" = "$WAIT_REPO" ]; then
      f="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/maintainerd.json"
      [ ! -f "$f" ] || WAIT_CONFIG_JSON="$(cat "$f")"
    else
      if out="$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$WAIT_REPO/contents/.claude/maintainerd.json" 2>&1)"; then
        WAIT_CONFIG_JSON="$out"
      else
        case "$out" in
          *"404"* | *"Not Found"*) ;;
          *) die 3 "could not read $WAIT_REPO's .claude/maintainerd.json: $out" ;;
        esac
      fi
    fi
  fi
  printf '%s' "$WAIT_CONFIG_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    die 3 "the repository's .claude/maintainerd.json is not a valid JSON object"
}

# cfg <jq-expr> <default> — read a value from the loaded config; the default when the key or a null
# is absent.
cfg() {
  local expr="$1" default="$2" v
  v="$(printf '%s' "$WAIT_CONFIG_JSON" | jq -r "($expr) // empty" 2>/dev/null)" || die 3 "could not read $expr from the config"
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
