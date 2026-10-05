#!/usr/bin/env bash
# Shared helpers for pr-queue.sh and merge-order.sh. Source it; do not execute it.
#
# Requires: bash 3.2+, gh, jq. Like the wait tools, nothing here writes to GitHub.

# shellcheck source=wait-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/wait-common.sh"

# resolve_pr_arg <number-or-url> — sets PR_NUM, and PR_URL_REPO (owner/repo, empty for a bare
# number). A PR URL names its repository; the caller decides what to do when it contradicts -R.
resolve_pr_arg() {
  local a="$1"
  PR_URL_REPO=""
  case "$a" in
    http*://*/pull/*)
      PR_URL_REPO="$(printf '%s' "${a#*://*/}" | cut -d/ -f1,2)"
      ;;
  esac
  PR_NUM="${a##*/pull/}"
  PR_NUM="${PR_NUM%%[/?#]*}"
  is_uint "$PR_NUM" || die 3 "'$a' is neither a PR number nor a pull request URL"
}

QUEUE_QUERY='query($owner:String!,$name:String!,$branch:String!){
  repository(owner:$owner,name:$name){mergeQueue(branch:$branch){
    entries(first:100){nodes{position state pullRequest{number}}}}}}'

# fetch_queue <owner/repo> <branch> — prints one "<pr> <position> <state>" line per entry in the
# branch's merge queue; nothing when the branch has no queue. Returns 1 (with QUEUE_ERR set) when
# GitHub could not be asked. Queue membership comes only from the GraphQL mergeQueue connection:
# no PR field (mergeStateStatus, autoMergeRequest, ...) says whether a PR is queued.
fetch_queue() {
  local out
  QUEUE_ERR=""
  out="$(gh api graphql -f query="$QUEUE_QUERY" -f owner="${1%%/*}" -f name="${1##*/}" -f branch="$2" 2>&1)" || {
    QUEUE_ERR="gh api graphql failed: $out"
    return 1
  }
  if printf '%s' "$out" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
    QUEUE_ERR="mergeQueue query returned errors: $(printf '%s' "$out" | jq -c '.errors' | cut -c1-200)"
    return 1
  fi
  printf '%s' "$out" | jq -r '.data.repository.mergeQueue.entries.nodes[]? | "\(.pullRequest.number) \(.position) \(.state)"' 2>/dev/null || {
    QUEUE_ERR="could not parse the mergeQueue response"
    return 1
  }
}

# queue_lookup <queue-lines> <pr> — prints "<position> <state>" for the PR, nothing when it is not
# in the queue.
queue_lookup() {
  printf '%s\n' "$1" | awk -v n="$2" '$1 == n { print $2, $3; exit }'
}
