#!/usr/bin/env bash
#
# repo-ops — PR template guard (PreToolUse on Bash).
#
# Denies a `gh pr create` / `gh pr edit --body ...` whose body is missing a heading the repo's
# own PR template requires. "Use the repo's PR template" was written in this plugin's own
# create-pr skill and in prose everywhere it is consumed, and PR bodies still drifted from it —
# a rule that has been violated while written down belongs in a hook, not another sentence.
#
# This hook only ever DENIES or WARNS. It never returns "allow", so it cannot widen anything: a
# command it says nothing about still goes through the normal permission flow.
#
#   - DENY only when the body was actually read and a required heading is provably missing.
#   - WARN (not deny) when the command is a create/edit-with-body but the body's text could not
#     be resolved from the command string — a heuristic that fails closed on its own parse
#     errors would block legitimate work it never actually looked at.
#   - Say nothing (exit 0, no output) when: the repo has no template, the command is not a
#     create/edit carrying a body at all, or the leading command is inert text that only
#     mentions "gh pr create" (an echo, a heredoc writing another script) rather than running it.
#
# Generic mechanism only: this script never names a specific repo, label, or org. The one
# config key it reads — .claude/maintainerd.json's paths.prTemplate — is part of the existing
# repo config contract (plugins/core/references/config-schema.md); everything else is read
# straight from the command string and the template file it points at.
#
# Contract: hook JSON on stdin, jq on PATH, bash 3.2 (macOS /bin/bash).
# Output: exit 0 with a PreToolUse permissionDecision of "deny", exit 0 with a warning
# (systemMessage + additionalContext, no decision), or exit 0 silently.

set -uo pipefail
# (not `set -e`: this script relies on parameter-expansion / case tests whose "no match" arm is
# a normal, expected outcome, not a failure the script should abort on.)

deny() {
  # $1: reason shown to Claude.
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

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

# --------------------------------------------------------------- inert-leading-command exemption
# Mirrors vycari-ops's prod guard: a command whose own leading executable does not execute its
# arguments (echo, printf, cat, jq) and that carries no shell operator/substitution anywhere is
# just quoting or describing "gh pr create ..." as inert text (an issue body, a log line), not
# running it. Any operator/substitution character anywhere forfeits the exemption — the safe
# direction, since that only ever costs an occasional false positive, never a missed check.
INERT_LEADING=' echo printf cat jq '
LEADING=$(printf '%s' "$COMMAND" \
  | grep -Eo '^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*[a-zA-Z0-9_./-]+' \
  | grep -Eo '[a-zA-Z0-9_./-]+$' || true)
LEADING="${LEADING##*/}"
LEADING_LOWER=$(printf '%s' "$LEADING" | tr '[:upper:]' '[:lower:]')
case "$INERT_LEADING" in
  *" $LEADING_LOWER "*)
    case "$COMMAND" in
      *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'('*|*$'\n'*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

# ------------------------------------------------------------------------ mask heredoc payloads
# A heredoc's body is data, not the command being run: `cat > deploy.sh <<'EOF'` followed by a
# line that reads `gh pr create --body "..."` writes that text into a file, it does not invoke
# gh. Blank out every heredoc body (keep the operator + delimiter lines so nothing downstream
# desyncs) before deciding whether this command is a real "gh pr create"/"gh pr edit" trigger.
# The *extraction* step below still reads the ORIGINAL, unmasked command, because a legitimate
# `--body "$(cat <<'EOF' ... EOF)"` needs exactly the heredoc body this step would blank.
mask_all_heredocs() {
  # Two `local` statements, not one: `local a=$1 b="$a"` expands every word on the line before
  # any of them is assigned, so under `set -u` the second `$a` is read before `a` exists.
  local s="$1"
  local out="" rest="$s" prefix after tag strip line_rest body_start remaining hl trimmed nextrest
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
      if [ "$nextrest" = "__EOF__" ]; then
        remaining=""
        break
      fi
      remaining="$nextrest"
    done
    [ "$remaining" = "__EOF__" ] && remaining=""
    out="$out$prefix<<$tag$line_rest"$'\n'"$tag"$'\n'
    rest="$remaining"
  done
}

MASKED=$(mask_all_heredocs "$COMMAND")

# The trigger must sit in COMMAND POSITION — the start of a line, or right after a shell
# operator (optionally past an env-var prefix) — not merely appear as a substring anywhere.
# Without this, `gh issue create --body "saw this: gh pr create --body ..."` would trigger on
# text that only quotes another command, the same class of false positive vycari-ops's prod
# guard had to rule out for the same reason. grep matches `^`/`$` per line by default, which is
# exactly what's wanted here: a real `gh pr create` that starts a later line in a multi-line
# command (common after a heredoc closes) still counts as command position.
CMD_POS='(^|[;&|(])[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*'
printf '%s' "$MASKED" | grep -Eq "${CMD_POS}gh[[:space:]]+pr[[:space:]]+(create|edit)([^a-zA-Z0-9_]|\$)" \
  || exit 0
case "$MASKED" in
  *'--body'*) ;;   # matches both --body and --body-file
  *) exit 0 ;;
esac

# ---------------------------------------------------------------------------- resolve the template
resolve_path() {
  # $1: a path from config or a relative default. Absolute paths pass through.
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s' "$CWD/$1" ;;
  esac
}

TEMPLATE_PATH=""
CONFIG="$CWD/.claude/maintainerd.json"
if [ -f "$CONFIG" ]; then
  CONFIGURED=$(jq -r '.paths.prTemplate // empty' "$CONFIG" 2>/dev/null || true)
  if [ -n "$CONFIGURED" ] && [ "$CONFIGURED" != "null" ]; then
    TEMPLATE_PATH=$(resolve_path "$CONFIGURED")
  fi
fi
if [ -z "$TEMPLATE_PATH" ] || [ ! -f "$TEMPLATE_PATH" ]; then
  if [ -f "$CWD/.github/PULL_REQUEST_TEMPLATE.md" ]; then
    TEMPLATE_PATH="$CWD/.github/PULL_REQUEST_TEMPLATE.md"
  elif [ -f "$CWD/.github/pull_request_template.md" ]; then
    TEMPLATE_PATH="$CWD/.github/pull_request_template.md"
  else
    exit 0   # no template exists for this repo — nothing to enforce
  fi
fi
[ -f "$TEMPLATE_PATH" ] || exit 0

# --------------------------------------------------------------------------- extract the PR body
# scan_single_quoted <text-after-opening-quote> -> SQ_VAL
# Bash single quotes have no escape mechanism at all, so the first `'` always closes it — the
# same one-layer-of-quoting limit the rest of this plugin family documents.
scan_single_quoted() {
  case "$1" in
    *"'"*) SQ_VAL="${1%%\'*}"; return 0 ;;
    *) return 1 ;;
  esac
}

# scan_double_quoted <text-after-opening-quote> -> DQ_VAL
# Walks character by character so a `\"` inside the value never reads as the closing quote.
# Any other backslash escape is passed through untouched; only `\"` is unescaped afterward,
# since that is the one bash double-quote escape that would otherwise hide a real `"` from the
# heading scan below.
scan_double_quoted() {
  local s="$1" i=0 len c nc out=""
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "$c" = '\' ] && [ $((i + 1)) -lt "$len" ]; then
      nc="${s:$((i + 1)):1}"
      out="$out$c$nc"
      i=$((i + 2))
      continue
    fi
    if [ "$c" = '"' ]; then
      DQ_VAL="${out//\\\"/\"}"
      return 0
    fi
    out="$out$c"
    i=$((i + 1))
  done
  return 1
}

BODY_OK=1
BODY_TEXT=""
BODY_FILE_PATH=""

if printf '%s' "$COMMAND" | grep -Eq -- '--body-file([[:space:]]|=)'; then
  REST="${COMMAND#*--body-file}"
  case "$REST" in
    '='*) REST="${REST#=}" ;;
    *) REST="${REST# }" ;;
  esac
  while :; do
    case "$REST" in
      ' '*) REST="${REST# }" ;;
      $'\t'*) REST="${REST#$'\t'}" ;;
      *) break ;;
    esac
  done
  case "$REST" in
    "'"*) VAL="${REST#\'}"; VAL="${VAL%%\'*}" ;;
    '"'*) VAL="${REST#\"}"; VAL="${VAL%%\"*}" ;;
    *) VAL=$(printf '%s' "$REST" | grep -Eo '^[^[:space:]]+' || true) ;;
  esac
  if [ -n "$VAL" ]; then
    BODY_FILE_PATH=$(resolve_path "$VAL")
    if [ -f "$BODY_FILE_PATH" ]; then
      BODY_TEXT=$(cat "$BODY_FILE_PATH")
      BODY_OK=0
    fi
  fi
elif printf '%s' "$COMMAND" | grep -Eq -- '--body([[:space:]]|=)'; then
  REST="${COMMAND#*--body}"
  case "$REST" in
    '='*) REST="${REST#=}" ;;
    *) REST="${REST# }" ;;
  esac
  while :; do
    case "$REST" in
      ' '*) REST="${REST# }" ;;
      $'\t'*) REST="${REST#$'\t'}" ;;
      *) break ;;
    esac
  done
  case "$REST" in
    '"$(cat'*|'$(cat'*)
      # --body "$(cat <<'EOF' ... EOF)" / --body $(cat <<EOF ... EOF) — read the heredoc that
      # feeds the command substitution, straight out of the ORIGINAL command text.
      case "$REST" in
        *'<<'*)
          HAFTER="${REST#*<<}"
          HSTRIP=0
          case "$HAFTER" in '-'*) HSTRIP=1; HAFTER="${HAFTER#-}" ;; esac
          while :; do
            case "$HAFTER" in
              ' '*) HAFTER="${HAFTER# }" ;;
              $'\t'*) HAFTER="${HAFTER#$'\t'}" ;;
              *) break ;;
            esac
          done
          HQUOTED=1
          case "$HAFTER" in
            "'"*) HAFTER="${HAFTER#\'}"; HTAG="${HAFTER%%\'*}"; HAFTER="${HAFTER#*\'}" ;;
            '"'*) HAFTER="${HAFTER#\"}"; HTAG="${HAFTER%%\"*}"; HAFTER="${HAFTER#*\"}" ;;
            *) HQUOTED=0; HTAG=$(printf '%s' "$HAFTER" | grep -Eo '^[A-Za-z_][A-Za-z0-9_]*' || true); HAFTER="${HAFTER#"$HTAG"}" ;;
          esac
          if [ -n "$HTAG" ]; then
            case "$HAFTER" in
              *$'\n'*)
                HBODY_START="${HAFTER#*$'\n'}"
                HREMAINING="$HBODY_START"
                HCONTENT=""
                HFOUND=0
                while :; do
                  case "$HREMAINING" in
                    *$'\n'*) HLINE="${HREMAINING%%$'\n'*}"; HNEXT="${HREMAINING#*$'\n'}" ;;
                    *) HLINE="$HREMAINING"; HNEXT="__EOF__" ;;
                  esac
                  HTRIMMED="$HLINE"
                  if [ "$HSTRIP" -eq 1 ]; then
                    while :; do
                      case "$HTRIMMED" in
                        $'\t'*) HTRIMMED="${HTRIMMED#$'\t'}" ;;
                        *) break ;;
                      esac
                    done
                  fi
                  if [ "$HTRIMMED" = "$HTAG" ]; then
                    HFOUND=1
                    break
                  fi
                  HCONTENT="$HCONTENT$HLINE"$'\n'
                  if [ "$HNEXT" = "__EOF__" ]; then break; fi
                  HREMAINING="$HNEXT"
                done
                if [ "$HFOUND" -eq 1 ]; then
                  BODY_TEXT="$HCONTENT"
                  BODY_OK=0
                  # An unquoted heredoc delimiter (`<<EOF`, no quotes anywhere in the word) still
                  # expands $vars/`` `cmd` ``/$(...) inside the body — the text bash hands to psql
                  # (well, to gh) is decided at runtime, not the text scanned here. A quoted
                  # delimiter (`<<'EOF'`/`<<"EOF"`) suppresses all of that, so its body is safe to
                  # read literally regardless of what it contains.
                  if [ "$HQUOTED" -eq 0 ]; then
                    case "$BODY_TEXT" in
                      *'$'*|*'`'*) BODY_OK=1 ;;
                    esac
                  fi
                fi
                ;;
            esac
          fi
          ;;
      esac
      ;;
    "'"*)
      # Single quotes: bash performs no expansion at all inside them, so the text between the
      # quotes is always exactly what gh receives, `$`/backtick included.
      AFTER="${REST#\'}"
      if scan_single_quoted "$AFTER"; then
        BODY_TEXT="$SQ_VAL"
        BODY_OK=0
      fi
      ;;
    '"'*)
      # Double quotes still expand $vars/`` `cmd` ``/$(...): if any of those appear in the
      # extracted text, what gh actually receives is decided at runtime, not by this scan.
      AFTER="${REST#\"}"
      if scan_double_quoted "$AFTER"; then
        case "$DQ_VAL" in
          *'$'*|*'`'*) BODY_OK=1 ;;
          *) BODY_TEXT="$DQ_VAL"; BODY_OK=0 ;;
        esac
      fi
      ;;
  esac
fi

if [ "$BODY_OK" -ne 0 ]; then
  warn "repo-ops pr-template-guard: this looks like \`gh pr create\`/\`gh pr edit\` with a body, but the body text could not be reliably read out of the command — either it isn't a plain \`--body \"...\"\`/\`--body '...'\`/heredoc/\`--body-file\` form this heuristic recognizes, or it contains a shell expansion (\`\$\` or a backtick) whose real value is decided at runtime, not by this text scan. Not denying on something it can't be sure about — double-check the body against $TEMPLATE_PATH yourself before opening the PR."
fi

# --------------------------------------------------------------------------- heading comparison
strip_fences() {
  # Drop fenced code blocks (``` or ~~~, 3+ chars, optionally indented) before scanning for
  # headings, so a `##` inside an example code block in the body never reads as a real heading.
  awk '
    BEGIN { infence = 0 }
    /^[[:space:]]*(```+|~~~+)/ { infence = !infence; next }
    infence { next }
    { print }
  '
}

extract_headings() {
  printf '%s\n' "$1" | tr -d '\r' | strip_fences | grep -E '^(## |### )' || true
}

TEMPLATE_CONTENT=$(cat "$TEMPLATE_PATH")
TEMPLATE_HEADINGS=$(extract_headings "$TEMPLATE_CONTENT")
BODY_HEADINGS=$(extract_headings "$BODY_TEXT")

MISSING=""
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  case "$heading" in
    *'(optional)'*) continue ;;   # a heading marked optional is never required
  esac
  if ! printf '%s\n' "$BODY_HEADINGS" | grep -qxF "$heading"; then
    if [ -z "$MISSING" ]; then
      MISSING="$heading"
    else
      MISSING="$MISSING
$heading"
    fi
  fi
done <<HEADINGS
$TEMPLATE_HEADINGS
HEADINGS

if [ -n "$MISSING" ]; then
  LIST=$(printf '%s' "$MISSING" | sed 's/^/  - /')
  deny "repo-ops pr-template-guard: this PR body is missing heading(s) required by $TEMPLATE_PATH:
$LIST
Add each one verbatim (matching '##'/'###' level and text exactly), or mark it optional in the template itself if it no longer applies. Extra headings beyond the template are fine."
fi

exit 0
