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
# Scoping is structural, not textual, and shared with pr-template-guard: the payload is split
# into simple commands by lib/gh-command-scan.sh (heredoc bodies redacted, split on
# `;`/`&&`/`||`/`|`/newline/subshell outside quotes), and only a simple command whose executable
# resolves to gh — bare, wrapped in `command`/`env`/`exec`, or reached by path — is scanned. So
# an `echo "gh pr create --label x"`, a heredoc that writes another script, and a different
# chained command's `--draft` are all invisible to this check, and every `gh pr create` the
# command really runs is checked on its own. The scanner's residual limits are documented on its
# functions and in the plugin README.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

CONFIG="$CWD/.claude/maintainerd.json"
[ -f "$CONFIG" ] || exit 0
SKIP_LABEL=$(jq -r '.review.skipLabel // empty' "$CONFIG" 2>/dev/null || true)
[ -n "$SKIP_LABEL" ] && [ "$SKIP_LABEL" != "null" ] || exit 0

case "$COMMAND" in
  *gh*) : ;;          # cheap pre-filter: no "gh" anywhere means nothing to scan
  *) exit 0 ;;
esac

SCAN_LIB="$SCRIPT_DIR/lib/gh-command-scan.sh"
if [ ! -r "$SCAN_LIB" ]; then
  # The scanner ships next to this script in every layout (source tree and installed plugin
  # alike). If it is somehow missing, say so rather than failing silently — but only once a
  # command has already passed the `gh` pre-filter, so a broken install is not announced on
  # every unrelated Bash call.
  jq -n --arg msg "repo-ops skip-label-race-guard: its command scanner (lib/gh-command-scan.sh) is missing from this install, so this \`gh\` command was NOT checked. Reinstall/update the repo-ops plugin." '{
    systemMessage: $msg,
    hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: $msg }
  }'
  exit 0
fi
# shellcheck source=lib/gh-command-scan.sh
. "$SCAN_LIB"

# ------------------------------------------------------------------------------ label extraction
# Every --label/-l value in one invocation, one per line, in order. Quote-aware (a quoted label
# containing spaces is read in full rather than truncated at its first space), repeat-aware (gh
# accepts --label more than once), and comma-aware (gh splits `--label a,b` into two labels, so
# both the whole value and each comma-separated part are candidates).
labels_in() {
  local scan="$1"
  local marker rest t val part remainder out=""
  while :; do
    marker=$(printf '%s' "$scan" | grep -Eo -- '(^|[[:space:]])(--label|-l)([[:space:]]+|=)' | head -1 || true)
    [ -n "$marker" ] || break
    rest="${scan#*"$marker"}"
    while :; do
      case "$rest" in
        ' '*) rest="${rest# }" ;;
        $'\t'*) rest="${rest#$'\t'}" ;;
        *) break ;;
      esac
    done
    case "$rest" in
      "'"*) t="${rest#\'}"; val="${t%%\'*}"; rest="${t#*\'}" ;;
      '"'*) t="${rest#\"}"; val="${t%%\"*}"; rest="${t#*\"}" ;;
      *) val=$(printf '%s' "$rest" | grep -Eo '^[^[:space:]]+' || true); rest="${rest#"$val"}" ;;
    esac
    if [ -n "$val" ]; then
      out="$out$val"$'\n'
      case "$val" in
        *,*)
          remainder="$val"
          while :; do
            case "$remainder" in
              *,*) part="${remainder%%,*}"; remainder="${remainder#*,}" ;;
              *) part="$remainder"; remainder="" ;;
            esac
            [ -n "$part" ] && out="$out$part"$'\n'
            [ -n "$remainder" ] || break
          done
          ;;
      esac
    fi
    # Advance past what was just consumed so a repeated --label further along is still found,
    # without re-matching the marker/value just processed.
    scan="$rest"
  done
  printf '%s' "$out"
}

MASKED=$(mask_all_heredocs "$COMMAND")

while IFS=' ' read -r OFF LEN; do
  [ -n "$OFF" ] || continue
  SEG_MASKED="${MASKED:$OFF:$LEN}"
  [ "$(gh_pr_subcommand "$SEG_MASKED")" = "create" ] || continue
  INVOCATION="${COMMAND:$OFF:$LEN}"

  MATCHED_LABEL=0
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    if [ "$val" = "$SKIP_LABEL" ]; then
      MATCHED_LABEL=1
      break
    fi
  done <<LABELS
$(labels_in "$INVOCATION")
LABELS
  [ "$MATCHED_LABEL" -eq 1 ] || continue

  # --draft anywhere in THIS invocation means this PR never fires an `opened` webhook while
  # unlabeled — the race this hook exists to catch cannot happen.
  printf '%s' "$INVOCATION" | grep -Eq -- '(^|[[:space:]])--draft([[:space:]]|$)' && continue

  warn "repo-ops skip-label-race-guard: this \`gh pr create\` applies \"$SKIP_LABEL\" without \`--draft\`. Most review bots schedule their run on the PR's \`opened\` webhook, which fires before a label from the same command has landed — so the label may not suppress the review it's meant to skip. Prefer: \`gh pr create --draft --label \"$SKIP_LABEL\" ...\` followed by \`gh pr ready\`, which fires no \`opened\` event for the bot to race. Proceeding anyway is your call; nothing is blocked."
done <<SEGMENTS
$(split_simple_commands "$MASKED")
SEGMENTS

exit 0
