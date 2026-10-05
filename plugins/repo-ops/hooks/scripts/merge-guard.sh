#!/usr/bin/env bash
#
# repo-ops — merge guard (PreToolUse on Bash).
#
# ADVISORY ONLY. Never denies, never asks. Warns when a Bash command really runs a merge of a
# pull request — `gh pr merge` (any flags, `--auto` and `--admin` included), the REST merge
# endpoint (`gh api -X PUT repos/<o>/<r>/pulls/<n>/merge`), or a GraphQL merge mutation
# (`mergePullRequest`, `enablePullRequestAutoMerge`, `enqueuePullRequest`) — so that "agents
# never merge" is a reminder delivered at the moment of the call instead of a sentence retyped
# into every agent prompt.
#
# Why a warning and not a deny: the hook payload alone cannot reliably tell a spawned agent from
# the lead session or the maintainer, and a fail-closed hook that blocked the maintainer's own
# merges would be switched off within a day. Structural prevention for agents belongs in their
# definitions (an agent that declares no merge capability); this hook is the backstop for
# everyone else. When the payload does carry a non-empty `agent_id` / `agent_type` (a subagent
# call), the warning says so in stronger words — still without blocking.
#
# Scoping is structural and shared with the other repo-ops guards: lib/gh-command-scan.sh redacts
# heredoc bodies, splits the payload into simple commands outside quotes, and resolves each
# one's executable by basename after `command`/`env`/`exec`/assignments. So an `echo "gh pr merge
# 5"`, a heredoc that writes a script, or a PR body mentioning the command is invisible here, and
# every merge a compound command really runs is found. Residual limits (all toward checking
# LESS, never a false warning beyond the first): `sh -c "gh pr merge …"`, `xargs gh`, and a merge
# written inside a `$( … )` substitution are not recognized.
#
# Generic mechanism only. One optional config key, config.createPr.agentsMayMerge in
# .claude/maintainerd.json: absent or false (the default) the guard warns; `true` silences it
# for a repo that has deliberately delegated merging to agents. Unlike skip-label-race-guard it
# needs no config at all to be active.
#
# Contract: hook JSON on stdin, jq on PATH, bash 3.2 (macOS /bin/bash).
# Output: exit 0 with a warning (systemMessage + additionalContext, no decision), or exit 0
# silently.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

emit_warning() {
  jq -n --arg msg "$1" '{
    systemMessage: $msg,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $msg
    }
  }'
  exit 0
}

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
AGENT=$(printf '%s' "$INPUT" | jq -r '(.agent_id // .agent_type // empty) | tostring' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0
CWD="${CWD:-.}"

case "$COMMAND" in
  *gh*) : ;;          # cheap pre-filter: no "gh" anywhere means nothing to scan
  *) exit 0 ;;
esac

# Delegation is read from the config at the hook's cwd. It silences the guard only when the
# command cannot have left that repo: a `cd`/`pushd`, `-R/--repo` or `GH_REPO` means the merge may
# target a repo whose config was never read, so those still warn.
DELEGATED=0
CONFIG="$CWD/.claude/maintainerd.json"
if [ -f "$CONFIG" ]; then
  MAY_MERGE=$(jq -r '.createPr.agentsMayMerge // false' "$CONFIG" 2>/dev/null || true)
  [ "$MAY_MERGE" = "true" ] && DELEGATED=1
fi

SCAN_LIB="$SCRIPT_DIR/lib/gh-command-scan.sh"
if [ ! -r "$SCAN_LIB" ]; then
  emit_warning "repo-ops merge-guard: its command scanner (lib/gh-command-scan.sh) is missing from this install, so this \`gh\` command was NOT checked. Reinstall/update the repo-ops plugin."
fi
# shellcheck source=lib/gh-command-scan.sh
. "$SCAN_LIB"

# merge_kind <segment> -> prints what kind of merge the simple command performs, or nothing.
merge_kind() {
  local words w1 w2 lowered method="" has_path=0 has_fields=0 w prev=""
  words=$(gh_command_words "$1")
  [ -n "$words" ] || return 0
  w1=$(printf '%s\n' "$words" | sed -n 1p)
  w2=$(printf '%s\n' "$words" | sed -n 2p)
  if [ "$w1" = "pr" ] && [ "$w2" = "merge" ]; then
    printf 'gh pr merge'
    return 0
  fi
  [ "$w1" = "api" ] || return 0
  lowered=$(printf '%s' "$words" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *mutation*)
      case "$lowered" in
        *mergepullrequest*|*enablepullrequestautomerge*|*enqueuepullrequest*)
          printf 'a GraphQL merge mutation'
          return 0 ;;
      esac ;;
  esac
  # A GraphQL query read from a file cannot be inspected here; warn rather than miss a merge.
  case "$lowered" in
    *graphql*)
      if printf '%s\n' "$lowered" | grep -Eq '^(--input|--input=.*|[^=]*=@.*)$'; then
        printf 'a GraphQL call whose query is read from a file (not inspectable)'
        return 0
      fi ;;
  esac
  while IFS= read -r w; do
    case "$w" in
      */pulls/*/merge|pulls/*/merge|*/pulls/*/merge/*|*/pulls/*/merge\?*) has_path=1 ;;
    esac
    case "$w" in
      -X) : ;;
      -X?*) method="${w#-X}"; method="${method#=}" ;;
      --method=*) method="${w#--method=}" ;;
      --method) : ;;
      -f|-F|--field|--raw-field|--input|-f?*|-F?*|--field=*|--raw-field=*|--input=*) has_fields=1 ;;
    esac
    case "$prev" in
      -X|--method) method="$w" ;;
    esac
    prev="$w"
  done <<WORDS
$words
WORDS
  [ "$has_path" -eq 1 ] || return 0
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  # gh api defaults to GET unless fields are given (then POST); the merge endpoint is PUT-only.
  # A bare GET is a read; an explicit non-GET method, or fields, is a merge attempt.
  case "$method" in
    GET) return 0 ;;
    "") [ "$has_fields" -eq 1 ] || return 0 ;;
  esac
  printf 'the REST merge endpoint'
}

MASKED=$(mask_all_heredocs "$COMMAND")

while IFS=' ' read -r OFF LEN; do
  [ -n "$OFF" ] || continue
  KIND=$(merge_kind "${MASKED:$OFF:$LEN}")
  [ -n "$KIND" ] || continue
  if [ "$DELEGATED" -eq 1 ]; then
    case "$MASKED" in
      *cd\ *|*pushd\ *|*GH_REPO*|*\ -R*|*--repo*) : ;;
      *) exit 0 ;;
    esac
  fi
  if [ -n "$AGENT" ] && [ "$AGENT" != "null" ]; then
    emit_warning "repo-ops merge-guard: this command merges a pull request via $KIND, and it was issued from a SUBAGENT. Agents never merge: get the PR to a clean review and green checks, report, and leave the merge to the maintainer. Nothing is blocked, but stop here unless the maintainer told you to merge this PR."
  fi
  emit_warning "repo-ops merge-guard: this command merges a pull request via $KIND. Agents never merge — the maintainer does (or tells the lead session to). Nothing is blocked; if you are a spawned agent, stop and report instead. A repo that has deliberately delegated merging can set createPr.agentsMayMerge to true in .claude/maintainerd.json to silence this."
done <<SEGMENTS
$(split_simple_commands "$MASKED")
SEGMENTS

exit 0
