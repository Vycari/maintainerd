#!/usr/bin/env bash
#
# repo-ops — skip-label race guard (PreToolUse on Bash).
#
# ADVISORY ONLY. Never denies, never asks. Warns when a `gh pr create` carries the repo's
# review-skip label (config.review.skipLabel) without `--draft`: many review bots schedule
# their run on the PR's `opened` webhook, which fires before a label applied in the same `gh pr
# create` call has landed — so the label doesn't reliably suppress the review it was meant to
# skip. The fix is draft-first: open as a draft, apply the label, then `gh pr ready`, which fires
# no `opened` event for the bot to race.
#
# Generic mechanism only: this script never names a specific label or org. Which label (if any)
# means "skip review" is entirely config — config.review.skipLabel in .claude/maintainerd.json,
# part of the existing repo config contract (plugins/core/references/config-schema.md). A repo
# that sets no such key gets no warning from this hook at all, ever.
#
# Contract: hook JSON on stdin, jq on PATH, bash 3.2 (macOS /bin/bash).
# Output: exit 0 with a warning (systemMessage + additionalContext, no decision), or exit 0
# silently.

set -uo pipefail

warn() {
  # $1: message for both the user and Claude. No permissionDecision, so the normal permission
  # flow is untouched — this is advisory only.
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
[ -n "$COMMAND" ] || exit 0
CWD="${CWD:-.}"

printf '%s' "$COMMAND" | grep -Eq '(^|[^a-zA-Z0-9_])gh[[:space:]]+pr[[:space:]]+create([^a-zA-Z0-9_]|$)' || exit 0

CONFIG="$CWD/.claude/maintainerd.json"
[ -f "$CONFIG" ] || exit 0
SKIP_LABEL=$(jq -r '.review.skipLabel // empty' "$CONFIG" 2>/dev/null || true)
[ -n "$SKIP_LABEL" ] && [ "$SKIP_LABEL" != "null" ] || exit 0

# Every --label/-l value on the command line, one per line, quotes stripped. `gh pr create`
# requires a separate --label per label (no comma-splitting), so this only needs to look at
# single tokens, not lists.
LABELS=$(printf '%s' "$COMMAND" \
  | grep -Eo -- '(--label|-l)([[:space:]]+|=)[^ ]+' \
  | sed -E 's/^(--label|-l)([[:space:]]+|=)//')

MATCH=0
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  # Strip one layer of surrounding quotes, if any.
  val="$raw"
  case "$val" in
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
  esac
  if [ "$val" = "$SKIP_LABEL" ]; then
    MATCH=1
    break
  fi
done <<LABELS
$LABELS
LABELS

[ "$MATCH" -eq 1 ] || exit 0

# --draft anywhere on the line means this PR never fires an `opened` webhook while unlabeled —
# the race this hook exists to catch cannot happen.
printf '%s' "$COMMAND" | grep -Eq -- '(^|[[:space:]])--draft([[:space:]]|$)' && exit 0

warn "repo-ops skip-label-race-guard: this \`gh pr create\` applies \"$SKIP_LABEL\" without \`--draft\`. Most review bots schedule their run on the PR's \`opened\` webhook, which fires before a label from the same command has landed — so the label may not suppress the review it's meant to skip. Prefer: \`gh pr create --draft --label \"$SKIP_LABEL\" ...\` followed by \`gh pr ready\`, which fires no \`opened\` event for the bot to race. Proceeding anyway is your call; nothing is blocked."
