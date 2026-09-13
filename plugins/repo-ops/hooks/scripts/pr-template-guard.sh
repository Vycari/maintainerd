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
#   - DENY only when a body was actually read and a required heading is provably missing.
#   - WARN (not deny) when the command runs a create/edit-with-body but that body's text could
#     not be resolved from the command string — a heuristic that fails closed on its own parse
#     errors would block legitimate work it never actually looked at.
#   - Say nothing (exit 0, no output) when: the repo has no template, no `gh pr create`/`edit`
#     is actually RUN by this command, or none of the ones that are carries a body.
#
# EVERY `gh pr create`/`gh pr edit` the command runs is checked, each against its own body:
# the payload is split into simple commands by lib/gh-command-scan.sh (heredoc bodies redacted,
# split on `;`/`&&`/`||`/`|`/newline/subshell outside quotes), and each simple command whose
# executable resolves to gh — bare, wrapped in `command`/`env`/`exec`, or reached by path — is
# scanned on its own. A `gh pr create` that is merely quoted inside an `echo`, a heredoc, or
# another command's `--body` is not a simple command of its own and is never scanned. The
# scanner's residual limits (heredoc openers found without quote tracking; gh reached as a
# wrapper's data, e.g. `sh -c "gh pr create …"`; a `gh pr create` inside `$( … )`) are documented
# on the functions there and in the plugin README.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  jq -n --arg msg "repo-ops pr-template-guard: its command scanner (lib/gh-command-scan.sh) is missing from this install, so this \`gh\` command was NOT checked. Reinstall/update the repo-ops plugin." '{
    systemMessage: $msg,
    hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: $msg }
  }'
  exit 0
fi
# shellcheck source=lib/gh-command-scan.sh
. "$SCAN_LIB"

# locate_body <one invocation's ORIGINAL text> -> sets BODY_FLAG ("body"|"body-file"|"") and
# BODY_REST (the raw command text starting at that flag's VALUE). Works on argv words, so
# `--body "mentions --body-file in prose"` has exactly one body flag, the real one.
locate_body() {
  local seg="$1" off len raw i n kind ch voff
  local offs=() lens=()
  BODY_FLAG=""
  BODY_REST=""
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    offs[${#offs[@]}]=$off
    lens[${#lens[@]}]=$len
  done <<ARGV
$(argv_spans "$seg")
ARGV
  n=${#offs[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    raw="${seg:${offs[$i]}:${lens[$i]}}"
    case "$raw" in
      --body=*) BODY_FLAG="body"; BODY_REST="${seg:$(( ${offs[$i]} + 7 ))}"; return 0 ;;
      --body-file=*) BODY_FLAG="body-file"; BODY_REST="${seg:$(( ${offs[$i]} + 12 ))}"; return 0 ;;
      --body|--body-file)
        case "$raw" in
          --body) BODY_FLAG="body" ;;
          *) BODY_FLAG="body-file" ;;
        esac
        if [ $((i + 1)) -lt "$n" ]; then
          BODY_REST="${seg:${offs[$((i + 1))]}}"
        fi
        return 0 ;;
      --*) i=$((i + 1)); continue ;;
      -[!-]*)
        # A short-option cluster. short_opt_parse knows that a value-taking shorthand consumes
        # the rest of the word, so `-b"…"`, `-Fbody.md`, `-b=…` and `-db"…"` all resolve, and a
        # `-tDraftTitle` is a title (its `b`/`F` letters, if any, are part of the value).
        while read -r kind ch voff; do
          [ "$kind" = "value" ] || continue
          case "$ch" in
            b) BODY_FLAG="body" ;;
            F) BODY_FLAG="body-file" ;;
            *) continue ;;
          esac
          if [ "$voff" = "-1" ]; then
            if [ $((i + 1)) -lt "$n" ]; then
              BODY_REST="${seg:${offs[$((i + 1))]}}"
            fi
          else
            BODY_REST="${seg:$(( ${offs[$i]} + voff ))}"
          fi
        done <<SHORT
$(short_opt_parse "$raw")
SHORT
        [ -z "$BODY_FLAG" ] || return 0
        i=$((i + 1)); continue ;;
      *) i=$((i + 1)); continue ;;
    esac
  done
  return 0
}


MASKED=$(mask_all_heredocs "$COMMAND")

# Collect every gh pr create/edit invocation that carries a body, as "<offset> <length>" into
# both $MASKED and $COMMAND (masking is length-preserving, so one offset addresses both).
INVOCATIONS=""
while IFS=' ' read -r OFF LEN; do
  [ -n "$OFF" ] || continue
  SEG_MASKED="${MASKED:$OFF:$LEN}"
  SUB=$(gh_pr_subcommand "$SEG_MASKED")
  [ -n "$SUB" ] || continue
  # A `--body`/`--body-file` FLAG of this invocation — not the string "--body" appearing inside
  # its own prose. locate_body reads argv words, so a title or body that merely mentions the flag
  # is one quoted word and is never mistaken for it.
  locate_body "${COMMAND:$OFF:$LEN}"
  [ -n "$BODY_FLAG" ] || continue
  INVOCATIONS="$INVOCATIONS$OFF $LEN"$'\n'
done <<SEGMENTS
$(split_simple_commands "$MASKED")
SEGMENTS
[ -n "$INVOCATIONS" ] || exit 0

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

# extract_body <flag: body|body-file> <raw text starting at the flag's value> -> sets BODY_OK
# (0 = text is trustworthy) and BODY_TEXT. Both come from locate_body, so what is read is this
# invocation's own body flag and nothing else.
extract_body() {
  local FLAG="$1"
  local REST="$2"
  local VAL AFTER BODY_FILE_PATH
  local HAFTER HSTRIP HQUOTED HTAG HBODY_START HREMAINING HCONTENT HFOUND HLINE HNEXT HTRIMMED
  BODY_OK=1
  BODY_TEXT=""
  [ -n "$REST" ] || return 0

  if [ "$FLAG" = "body-file" ]; then
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
    return 0
  fi

  case "$REST" in
    '"$(cat'*|'$(cat'*)
      # --body "$(cat <<'EOF' ... EOF)" / --body $(cat <<EOF ... EOF) — read the heredoc that
      # feeds the command substitution, straight out of the ORIGINAL command text (the scanner's
      # masking redacted it, which is exactly what must not be read here).
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
                  # expands $vars/`` `cmd` ``/$(...) inside the body — the text bash hands to gh
                  # is decided at runtime, not the text scanned here. A quoted delimiter
                  # (`<<'EOF'`/`<<"EOF"`) suppresses all of that, so its body is safe to read
                  # literally regardless of what it contains.
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
  return 0
}

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

# missing_headings <body text> -> the required headings that body lacks, one per line
missing_headings() {
  local body_headings missing="" heading
  body_headings=$(extract_headings "$1")
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    case "$heading" in
      *'(optional)'*) continue ;;   # a heading marked optional is never required
    esac
    if ! printf '%s\n' "$body_headings" | grep -qxF "$heading"; then
      if [ -z "$missing" ]; then
        missing="$heading"
      else
        missing="$missing
$heading"
      fi
    fi
  done <<HEADINGS
$TEMPLATE_HEADINGS
HEADINGS
  printf '%s' "$missing"
}

# ------------------------------------------------------------- check every invocation, in order
DENY_REASON=""
UNRESOLVED=0
while IFS=' ' read -r OFF LEN; do
  [ -n "$OFF" ] || continue
  locate_body "${COMMAND:$OFF:$LEN}"
  extract_body "$BODY_FLAG" "$BODY_REST"
  if [ "$BODY_OK" -ne 0 ]; then
    UNRESOLVED=1
    continue
  fi
  MISSING=$(missing_headings "$BODY_TEXT")
  [ -n "$MISSING" ] || continue
  LIST=$(printf '%s' "$MISSING" | sed 's/^/  - /')
  if [ -z "$DENY_REASON" ]; then
    DENY_REASON="repo-ops pr-template-guard: this PR body is missing heading(s) required by $TEMPLATE_PATH:
$LIST"
  else
    DENY_REASON="$DENY_REASON

…and another \`gh pr create\`/\`gh pr edit\` in the same command is missing:
$LIST"
  fi
done <<INVOCATIONS
$INVOCATIONS
INVOCATIONS

if [ -n "$DENY_REASON" ]; then
  deny "$DENY_REASON
Add each one verbatim (matching '##'/'###' level and text exactly), or mark it optional in the template itself if it no longer applies. Extra headings beyond the template are fine."
fi

if [ "$UNRESOLVED" -ne 0 ]; then
  warn "repo-ops pr-template-guard: this looks like \`gh pr create\`/\`gh pr edit\` with a body, but the body text could not be reliably read out of the command — either it isn't a plain \`--body \"...\"\`/\`--body '...'\`/heredoc/\`--body-file\` form this heuristic recognizes, or it contains a shell expansion (\`\$\` or a backtick) whose real value is decided at runtime, not by this text scan. Not denying on something it can't be sure about — double-check the body against $TEMPLATE_PATH yourself before opening the PR."
fi

exit 0
