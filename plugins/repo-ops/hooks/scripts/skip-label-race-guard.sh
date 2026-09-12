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

CONFIG="$CWD/.claude/maintainerd.json"
[ -f "$CONFIG" ] || exit 0
SKIP_LABEL=$(jq -r '.review.skipLabel // empty' "$CONFIG" 2>/dev/null || true)
[ -n "$SKIP_LABEL" ] && [ "$SKIP_LABEL" != "null" ] || exit 0

# ------------------------------------------------------------------------ mask heredoc payloads
# Same reasoning as pr-template-guard.sh: a heredoc's body is data, not the command being run
# (`cat > deploy.sh <<'EOF'` followed by a line mentioning `gh pr create --label ...` writes that
# text to a file, it does not invoke gh). Redact IN PLACE — same length, same newlines — so the
# trigger-position lookup below can slice the ORIGINAL command at the matched offset.
mask_all_heredocs() {
  # Two `local` statements, not one: `local a=$1 b="$a"` expands every word on the line before
  # any of them is assigned, so under `set -u` the second `$a` is read before `a` exists.
  local s="$1"
  local out="" rest="$s" prefix after tag strip line_rest body_start remaining hl trimmed nextrest redacted filler
  while :; do
    case "$rest" in
      *'<<'*) : ;;
      *) out="$out$rest"; printf '%s' "$out"; return ;;
    esac
    prefix="${rest%%<<*}"
    after="${rest#*<<}"
    case "$after" in
      '<'*) out="$out$prefix<<"; rest="$after"; continue ;;  # a here-string "<<<", not a heredoc
    esac
    strip=0
    case "$after" in '-'*) strip=1; after="${after#-}" ;; esac
    while :; do
      case "$after" in
        ' '*) after="${after# }" ;;
        $'\t'*) after="${after#$'\t'}" ;;
        *) break ;;
      esac
    done
    case "$after" in
      "'"*) after="${after#\'}"; tag="${after%%\'*}"; after="${after#*\'}" ;;
      '"'*) after="${after#\"}"; tag="${after%%\"*}"; after="${after#*\"}" ;;
      *)
        tag=$(printf '%s' "$after" | grep -Eo '^[A-Za-z_][A-Za-z0-9_]*' || true)
        after="${after#"$tag"}"
        ;;
    esac
    if [ -z "$tag" ]; then
      out="$out$prefix<<$after"
      printf '%s' "$out"
      return
    fi
    case "$after" in
      *$'\n'*) line_rest="${after%%$'\n'*}"; body_start="${after#*$'\n'}" ;;
      *) out="$out$prefix<<$tag$after"; printf '%s' "$out"; return ;;
    esac
    remaining="$body_start"
    redacted=""
    while :; do
      case "$remaining" in
        *$'\n'*) hl="${remaining%%$'\n'*}"; nextrest="${remaining#*$'\n'}" ;;
        *) hl="$remaining"; nextrest="__EOF__" ;;
      esac
      trimmed="$hl"
      if [ "$strip" -eq 1 ]; then
        while :; do
          case "$trimmed" in
            $'\t'*) trimmed="${trimmed#$'\t'}" ;;
            *) break ;;
          esac
        done
      fi
      if [ "$trimmed" = "$tag" ]; then
        remaining="$nextrest"
        break
      fi
      filler=$(printf '%*s' "${#hl}" '' | tr ' ' 'x')
      redacted="$redacted$filler"$'\n'
      if [ "$nextrest" = "__EOF__" ]; then
        remaining=""
        break
      fi
      remaining="$nextrest"
    done
    [ "$remaining" = "__EOF__" ] && remaining=""
    out="$out$prefix<<$tag$line_rest"$'\n'"$redacted$tag"$'\n'
    rest="$remaining"
  done
}

MASKED=$(mask_all_heredocs "$COMMAND")

# Command-position anchored, same as pr-template-guard.sh and for the same reason: a bare
# substring scan for "gh pr create" would also fire on an echo, a heredoc building another
# script, or a DIFFERENT gh invocation's `--body` text that happens to mention it.
CMD_POS='(^|[;&|(])[[:space:]]*(command[[:space:]]+(-p[[:space:]]+)?|env[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)?([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GH_EXEC='([a-zA-Z0-9_./-]*/)?gh'
TRIGGER="${CMD_POS}${GH_EXEC}[[:space:]]+pr[[:space:]]+create([^a-zA-Z0-9_]|\$)"
printf '%s' "$MASKED" | grep -Eq "$TRIGGER" || exit 0

# Scope everything below to THIS invocation, not the whole command line: `gh pr comment ...
# --body "...--draft..." && gh pr create --label greptile:skip` must not read the wrong
# command's --draft/--label as its own. Redaction preserved length, so the match's offset in
# MASKED is the same offset in the original $COMMAND.
MATCH=$(printf '%s' "$MASKED" | grep -Eo "$TRIGGER" | head -1)
PREFIX="${MASKED%%"$MATCH"*}"
INVOCATION="${COMMAND:${#PREFIX}}"
# $MATCH may itself start with the operator that put it in command position (the `(^|[;&|(])`
# alternative), so $INVOCATION can still begin with that same character — strip it before
# scanning for the FAR-end chain operator below, or that scan would immediately "find" this
# leading one and truncate everything to empty.
case "$INVOCATION" in
  [\;\&\|\(]*) INVOCATION="${INVOCATION#?}" ;;
esac
# Bound the far end at the next top-level chain operator, so a LATER command's --draft/--label
# on the same line isn't read as belonging to this one either. This is necessarily approximate
# (it can't tell a real `;`/`&&` apart from one inside this invocation's own quoted text — the
# same class of limit vycari-ops's guards document for themselves), so it stops at the first
# occurrence of any of them regardless of quoting; the direction that costs is under-reading a
# very long, chain-operator-free real invocation, never over-reading past a real chain boundary.
INVOCATION="${INVOCATION%%;*}"
INVOCATION="${INVOCATION%%&*}"   # catches a lone `&` and the first `&` of `&&` alike
INVOCATION="${INVOCATION%%|*}"   # catches a lone `|` and the first `|` of `||` alike

# ------------------------------------------------------------------------------ label extraction
# Every --label/-l VALUE in $INVOCATION, one per line, in order. Quote-aware — unlike a bare
# `[^ ]+` token match, this does not truncate a quoted, space-containing label ("skip review")
# at its first space.
LABELS_LIST=""
scan="$INVOCATION"
while :; do
  marker=$(printf '%s' "$scan" | grep -Eo -- '(--label|-l)([[:space:]]+|=)' | head -1 || true)
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
    LABELS_LIST="$LABELS_LIST
$val"
  fi
  # Advance past whatever was just consumed so a repeated --label further along is still found,
  # without re-matching the marker/value just processed.
  scan="$rest"
done

MATCHED_LABEL=0
while IFS= read -r val; do
  [ -n "$val" ] || continue
  if [ "$val" = "$SKIP_LABEL" ]; then
    MATCHED_LABEL=1
    break
  fi
done <<LABELS
$LABELS_LIST
LABELS

[ "$MATCHED_LABEL" -eq 1 ] || exit 0

# --draft anywhere in THIS invocation means this PR never fires an `opened` webhook while
# unlabeled — the race this hook exists to catch cannot happen.
printf '%s' "$INVOCATION" | grep -Eq -- '(^|[[:space:]])--draft([[:space:]]|$)' && exit 0

warn "repo-ops skip-label-race-guard: this \`gh pr create\` applies \"$SKIP_LABEL\" without \`--draft\`. Most review bots schedule their run on the PR's \`opened\` webhook, which fires before a label from the same command has landed — so the label may not suppress the review it's meant to skip. Prefer: \`gh pr create --draft --label \"$SKIP_LABEL\" ...\` followed by \`gh pr ready\`, which fires no \`opened\` event for the bot to race. Proceeding anyway is your call; nothing is blocked."
