#!/usr/bin/env bash
#
# repo-ops — review-reply postcondition (PostToolUse on Bash).
#
# A reply to a review thread that says "fixed" is a claim about the world, and a claim an agent
# makes about its own diff is a postcondition, not a sentence: on 2026-09-11 a cloud worker's
# thread reply claimed full compliance for a fix that was half done, twice in one day. The
# remedy the maintainer proposed was "a 'fixed' reply must name the commit, and the reply gets
# written after re-reading the diff, not from the plan." This hook is that remedy.
#
# It runs AFTER a Bash command, and only acts on a command that really ran one of
#   gh pr comment …                                  (PR-level reply)
#   gh api repos/…/pulls/N/comments/ID/replies …     (inline-thread reply, REST)
#   gh api graphql … addPullRequestReviewThreadReply (inline-thread reply, GraphQL)
# whose BODY claims a fix ("fixed", "addressed", "resolved", "done in", …). For such a reply it
# requires the body to name a commit (a 7-40 hex-digit SHA) that exists in the local checkout
# and is reachable from HEAD or HEAD's upstream. If not, it returns PostToolUse feedback —
# decision "block" with a reason (the reply is already posted; "block" is how PostToolUse hands
# the model a correction it must act on) — telling the agent to re-read the diff and post a
# corrected reply, with the diff of any repo file the reply names attached as additionalContext.
#
# It never returns anything but that feedback, never edits the thread, and never touches the
# network: verification is `git` in the directory the reply was posted from (the hook's cwd,
# moved by any `cd`/`pushd` earlier in the same command) only.
#
# Opt-in, Vycari-agnostic: gated on `review.replyNamesCommit` (boolean, default false) in
# .claude/maintainerd.json. Unset/false → this hook says nothing, ever.
#
# Scoping is structural, via lib/gh-command-scan.sh + lib/gh-exec-words.sh (heredoc bodies
# masked, simple-command splitting outside quotes, wrapper-aware gh resolution), so an
# `echo "gh pr comment … fixed"` or a heredoc that writes a script never counts as a reply.
#
# Limits (stated in the README): a body whose text is decided at runtime ($VAR, ${VAR}, a
# command substitution other than a `$(cat <<EOF …)` heredoc, a backtick — outside single
# quotes and not escaped, see word_is_runtime — a file produced
# earlier in the same command, `--input`) is not read, so such a reply is not judged; a fix
# claim is detected by a fixed phrase list, with a simple negation guard ("not fixed"); outside
# a git checkout nothing can be verified, so the hook says nothing; after a `cd` to a runtime
# directory the checkout is unknown, so later replies are not judged; and the hook reads the
# command, not which parts of it ran (`false && gh pr comment …` is still judged — the feedback
# says a reply that never posted needs no correction).
#
# Contract: hook JSON on stdin, jq + git on PATH, bash 3.2 (macOS /bin/bash).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_MAX=6000

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0
CWD="${CWD:-.}"

case "$COMMAND" in
  *gh*) : ;;
  *) exit 0 ;;
esac

# opted_in <dir> -> 0 when <dir> is inside a git checkout whose config sets
# review.replyNamesCommit: true. The config lives at the repository root, and the directory may
# be a subdirectory: look in <dir> first, then at the top of the checkout it sits in. Outside a
# git checkout nothing can be verified, so the hook says nothing. The directory is the one the
# reply was POSTED from: the tool's cwd, moved by any `cd`/`pushd` earlier in the same command
# (see the scan below), so a `cd ../pr-worktree && gh pr comment …` is judged in that worktree.
opted_in() {
  local dir="$1" config top
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  config="$dir/.claude/maintainerd.json"
  if [ ! -f "$config" ]; then
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$top" ] && config="$top/.claude/maintainerd.json"
  fi
  [ -f "$config" ] || return 1
  [ "$(jq -r '.review.replyNamesCommit // false' "$config" 2>/dev/null || true)" = "true" ]
}

# Fast path: the tool's cwd is not opted in and nothing in the command could move to a checkout
# that is, so there is nothing this hook could ever say.
if ! opted_in "$CWD"; then
  case "$COMMAND" in
    *cd*|*pushd*|*popd*) : ;;
    *) exit 0 ;;
  esac
fi

SCAN_LIB="$SCRIPT_DIR/lib/gh-exec-words.sh"
if [ ! -r "$SCAN_LIB" ] || [ ! -r "$SCRIPT_DIR/lib/gh-command-scan.sh" ]; then
  jq -n --arg msg "repo-ops review-reply-postcondition: its command scanner (lib/gh-exec-words.sh, lib/gh-command-scan.sh) is missing from this install, so this \`gh\` command was NOT checked. Reinstall/update the repo-ops plugin." '{
    systemMessage: $msg,
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $msg }
  }'
  exit 0
fi
# shellcheck source=lib/gh-exec-words.sh
. "$SCAN_LIB"

# ------------------------------------------------------------------ is it a reply, what's its body
# heredoc_expands <unquoted-delimiter heredoc body> -> 0 when the shell expands part of it. In
# such a body quotes are literal and a backslash escapes only the next character, so `\\$X`
# (an escaped backslash) still expands while `\$X` does not.
heredoc_expands() {
  local h="$1" n=${#1} k=0
  while [ "$k" -lt "$n" ]; do
    case "${h:$k:1}" in
      \\) k=$((k + 2)); continue ;;
      '`') return 0 ;;
      '$') case "${h:$((k + 1)):1}" in [A-Za-z0-9_\{\(@*#?!-]) return 0 ;; esac ;;
    esac
    k=$((k + 1))
  done
  return 1
}

# word_is_runtime <raw shell word> -> 0 when the shell substitutes part of the word when it runs
# ($VAR, ${VAR}, $1, $(cmd), `cmd`) outside single quotes and not backslash-escaped: the posted
# text may then name a commit this hook cannot see. A `$(cat <<TAG …)` heredoc is not runtime —
# its text is in the command — unless TAG is unquoted and the heredoc body itself expands.
word_is_runtime() {
  local w="$1" n=${#1} k=0 c sq=0 dq=0 rest opener tag quoted body b after
  while [ "$k" -lt "$n" ]; do
    c="${w:$k:1}"
    if [ "$sq" -eq 1 ]; then
      [ "$c" = "'" ] && sq=0
      k=$((k + 1)); continue
    fi
    case "$c" in
      \\) k=$((k + 2)); continue ;;
      "'") [ "$dq" -eq 0 ] && sq=1 ;;
      '"') dq=$((1 - dq)) ;;
      '`') return 0 ;;
      '$')
        rest="${w:$((k + 1))}"
        case "$rest" in
          '(cat <<'*)
            opener="${rest#(cat <<}"
            opener="${opener#-}"
            while :; do case "$opener" in ' '*) opener="${opener# }" ;; *) break ;; esac; done
            tag="${opener%%[$' \n)']*}"
            case "$tag" in \'*|\"*|\\*) quoted=1 ;; *) quoted=0 ;; esac
            tag=$(unquote_word "$tag")
            case "$opener" in *$'\n'*) ;; *) return 0 ;; esac
            body=$'\n'"${opener#*$'\n'}"
            b="${body%%$'\n'"$tag"*}"
            if [ "$quoted" -eq 0 ] && heredoc_expands "$b"; then
              return 0
            fi
            after="${body#"$b"}"
            after="${after#$'\n'"$tag"}"
            k=$((n - ${#after})); continue ;;
          [A-Za-z0-9_\{\(@*#?!-]*) return 0 ;;
        esac ;;
    esac
    k=$((k + 1))
  done
  return 1
}

# field_file <name=@path> -> appends the file's text to EXTRA_TEXT (a `gh api -F body=@file`
# posts the FILE's contents, not the literal `@file`). `@-` (stdin) or an unreadable path is
# decided outside the command, so the body is marked runtime and not judged.
EXTRA_TEXT=""
field_file() {
  local f="${1#*=@}"
  if [ "$f" = "-" ]; then
    stdin_body "$CUR_ORIG"
  elif [ -r "$DIR/$f" ]; then
    EXTRA_TEXT="$EXTRA_TEXT $(cat "$DIR/$f")"
  elif [ -r "$f" ]; then
    EXTRA_TEXT="$EXTRA_TEXT $(cat "$f")"
  else
    REPLY_RUNTIME=1
  fi
}

# stdin_body <segment-original> -> appends to EXTRA_TEXT the text this segment feeds on stdin:
# its own `<<TAG` heredoc (the lines after the segment's line, up to TAG) or `<<<` here-string.
# Only that text — never the rest of the command, whose other words (a later `git show <sha>`)
# must not vote. Stdin from a pipe or a redirected file is decided outside the command, so the
# body is marked runtime and not judged.
stdin_body() {
  local seg="$1" opener tag quoted rest b="" line strip=0 found=0
  case "$seg" in
    *'<<<'*)
      rest="${seg#*<<<}"
      while :; do case "$rest" in ' '*) rest="${rest# }" ;; *) break ;; esac; done
      EXTRA_TEXT="$EXTRA_TEXT $rest"
      word_is_runtime "$rest" && REPLY_RUNTIME=1
      return 0 ;;
    *'<<'*) ;;
    *) REPLY_RUNTIME=1; return 0 ;;
  esac
  opener="${seg#*<<}"
  case "$opener" in -*) strip=1; opener="${opener#-}" ;; esac
  while :; do case "$opener" in ' '*) opener="${opener# }" ;; *) break ;; esac; done
  tag="${opener%%[$' \t\n;&|)<>']*}"
  case "$tag" in \'*|\"*|\\*) quoted=1 ;; *) quoted=0 ;; esac
  tag=$(unquote_word "$tag")
  [ -n "$tag" ] || { REPLY_RUNTIME=1; return 0; }
  # The body starts on the line after the one this segment ends on.
  rest="${COMMAND:$((CUR_OFF + CUR_LEN))}"
  case "$rest" in *$'\n'*) ;; *) REPLY_RUNTIME=1; return 0 ;; esac
  rest="${rest#*$'\n'}"
  # The terminator is a line that is exactly TAG (after leading tabs, for `<<-`); a body line
  # that merely starts with TAG is body. No terminator: the body runs to the end of the
  # command, as bash sends it (with a warning), so it is still judged.
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\n'*) line="${rest%%$'\n'*}"; rest="${rest#*$'\n'}" ;;
      *) line="$rest"; rest="" ;;
    esac
    if [ "$strip" -eq 1 ]; then
      while :; do case "$line" in $'\t'*) line="${line#$'\t'}" ;; *) break ;; esac; done
    fi
    if [ "$line" = "$tag" ]; then found=1; break; fi
    b="$b"$'\n'"$line"
  done
  if [ "$quoted" -eq 0 ] && heredoc_expands "$b"; then
    REPLY_RUNTIME=1
  fi
  EXTRA_TEXT="$EXTRA_TEXT $b"
}

# reply_body <segment-masked> <segment-original> -> sets REPLY_KIND ("" = not a reply),
# REPLY_BODY (the text of the body, "" = unresolvable) and REPLY_RUNTIME (1 when some of the
# body is decided by the shell at run time, so it is not judged).
REPLY_KIND=""
REPLY_BODY=""
REPLY_RUNTIME=0
reply_body() {
  local masked="$1" orig="$2" off len i n raw uq next
  local offs=() lens=() words=()
  REPLY_KIND=""
  REPLY_BODY=""
  REPLY_RUNTIME=0
  EXTRA_TEXT=""
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    offs[${#offs[@]}]=$off
    lens[${#lens[@]}]=$len
    words[${#words[@]}]=$(unquote_word "${masked:$off:$len}")
  done <<WORDS
$(gh_exec_words "$masked")
WORDS
  n=${#words[@]}
  [ "$n" -ge 3 ] || return 0

  case "${words[1]}" in
    pr)
      [ "${words[2]}" = "comment" ] || return 0
      REPLY_KIND="pr-comment"
      ;;
    api)
      local j path_ok=0
      for ((j = 2; j < n; j++)); do
        case "${words[$j]}" in
          */pulls/[0-9]*/comments/[0-9]*/replies|*/pulls/[0-9]*/comments/[0-9]*/replies\?*) path_ok=1 ;;
          graphql) [ "$path_ok" -eq 0 ] && path_ok=2 ;;
        esac
      done
      if [ "$path_ok" -eq 1 ]; then
        REPLY_KIND="api-reply"
      elif [ "$path_ok" -eq 2 ]; then
        case "$masked" in *addPullRequestReviewThreadReply*) REPLY_KIND="graphql-reply" ;; esac
      fi
      [ -n "$REPLY_KIND" ] || return 0
      ;;
    *) return 0 ;;
  esac

  # Collect the body. For pr-comment: --body/-b value, --body-file/-F value. For API forms:
  # a `body=…` field (-f/-F/--field/--raw-field, separate or attached, with or without `=`).
  local text="" file
  i=2
  while [ "$i" -lt "$n" ]; do
    raw="${orig:${offs[$i]}:${lens[$i]}}"
    uq="${words[$i]}"
    next=""
    if [ $((i + 1)) -lt "$n" ]; then
      next="${orig:${offs[$((i + 1))]}:${lens[$((i + 1))]}}"
    fi
    case "$REPLY_KIND:$uq" in
      pr-comment:--body|pr-comment:-b)
        text="$text $next"; word_is_runtime "$next" && REPLY_RUNTIME=1
        i=$((i + 2)); continue ;;
      pr-comment:--body=*) text="$text ${raw#--body=}"; word_is_runtime "$raw" && REPLY_RUNTIME=1 ;;
      pr-comment:-b?*) text="$text ${raw#-b}"; word_is_runtime "$raw" && REPLY_RUNTIME=1 ;;
      pr-comment:--body-file|pr-comment:-F)
        file=$(unquote_word "$next")
        if [ "$file" = "-" ]; then
          stdin_body "$orig"          # this segment's own heredoc / here-string, nothing else
        elif [ -r "$DIR/$file" ]; then
          text="$text $(cat "$DIR/$file")"
        elif [ -r "$file" ]; then
          text="$text $(cat "$file")"
        fi
        i=$((i + 2)); continue ;;
      pr-comment:--body-file=*) file=$(unquote_word "${raw#--body-file=}")
        [ -r "$DIR/$file" ] && text="$text $(cat "$DIR/$file")" ;;
      *:-f|*:-F|*:--field|*:--raw-field)
        case "$(unquote_word "$next")" in
          body=@*|query=@*)
            # -F/--field reads `@file` (and `@-`, stdin) as the value; -f/--raw-field sends it as-is.
            case "$uq" in
              -F|--field) field_file "$(unquote_word "$next")" ;;
              *) text="$text $next" ;;
            esac ;;
          body=*|query=*|*addPullRequestReviewThreadReply*)
            text="$text $next"; word_is_runtime "$next" && REPLY_RUNTIME=1 ;;
        esac
        i=$((i + 2)); continue ;;
      *:-f?*|*:-F?*|*:--field=*|*:--raw-field=*)
        case "$uq" in
          -Fbody=@*|-Fquery=@*|--field=body=@*|--field=query=@*)
            field_file "$uq" ;;
          *body=*|*query=*) text="$text $raw"; word_is_runtime "$raw" && REPLY_RUNTIME=1 ;;
        esac ;;
    esac
    i=$((i + 1))
  done
  REPLY_BODY="$text$EXTRA_TEXT"
}

# claims_fix <lowercased body> -> 0 when the body claims something is fixed/addressed.
# A negation within a few characters before the claim ("not fixed", "isn't addressed", "won't
# fix") cancels that one occurrence; "will fix"/"to be fixed" are promises, not claims.
claims_fix() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
  t=$(printf '%s' "$t" | sed -E "s/(not|n't|never|won't|wont|cannot|can't|without|un)[[:space:]]+(yet[[:space:]]+)?(be[[:space:]]+)?(been[[:space:]]+)?(fix|fixed|address|addressed|resolve|resolved|implement|implemented|correct|corrected)/ /g; s/(will|to be|going to|would|could|should|need to|needs to)[[:space:]]+(be[[:space:]]+)?(fix|fixed|address|addressed|resolve|resolved|implement|implemented)/ /g")
  printf '%s' "$t" | grep -Eq '(^|[^a-z])(fixed|fixes|addressed|addresses|resolved|resolves|corrected|implemented|done in|handled in|applied in|fix applied|now fixed)([^a-z]|$)'
}

# commit_ok <sha> -> 0 when <sha> names a commit reachable from HEAD or HEAD's upstream.
commit_ok() {
  local sha="$1"
  git -C "$DIR" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$DIR" merge-base --is-ancestor "$sha" HEAD >/dev/null 2>&1 && return 0
  git -C "$DIR" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1 \
    && git -C "$DIR" merge-base --is-ancestor "$sha" '@{upstream}' >/dev/null 2>&1 && return 0
  return 1
}

# body_names_good_commit <body> -> 0 when some 7-40 hex token in the body is a reachable commit.
# Tokens are split on every non-alphanumeric character first, so adjacent candidates
# ("deadbeef1 50182d3") are each seen, and a hex run inside a longer word is not one.
body_names_good_commit() {
  local tok
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    commit_ok "$tok" && return 0
  done <<TOKENS
$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '0-9a-z' '\n' | grep -Ex '[0-9a-f]{7,40}' || true)
TOKENS
  return 1
}

# diff_context <body> -> the diff of repo files the body names, truncated; else the latest commit.
diff_context() {
  local base="" note="" files="" out="" tok f ref
  # The branch's fork point from the default branch, so every fix commit on it is covered;
  # only when no default-branch ref resolves, fall back to the latest commit and say so.
  for ref in origin/HEAD '@{upstream}' origin/main origin/master main master; do
    base=$(git -C "$DIR" merge-base HEAD "$ref" 2>/dev/null || true)
    [ -n "$base" ] && [ "$base" != "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" ] && break
    base=""
  done
  if [ -z "$base" ]; then
    base=$(git -C "$DIR" rev-parse --verify --quiet 'HEAD~1' 2>/dev/null || true)
    [ -n "$base" ] && note="[no default-branch ref found: diffs cover the latest commit only — run git log to see earlier fixes]"$'\n'
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    tok="${tok#./}"
    if git -C "$DIR" ls-files --error-unmatch -- "$tok" >/dev/null 2>&1; then
      case " $files " in *" $tok "*) ;; *) files="$files $tok" ;; esac
    fi
  done <<TOKENS
$(printf '%s' "$1" | grep -Eo '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u | head -20 || true)
TOKENS
  if [ -n "$base" ] && [ -n "$files" ]; then
    for f in $files; do
      out="$out$(git -C "$DIR" diff "$base" HEAD -- "$f" 2>/dev/null)"$'\n'
    done
  fi
  if [ -z "${out//[[:space:]]/}" ]; then
    note=""
    out=$(git -C "$DIR" log -3 --stat --format='%h %s' 2>/dev/null || true)
  fi
  out="$note$out"
  if [ "${#out}" -gt "$DIFF_MAX" ]; then
    out="${out:0:$DIFF_MAX}"$'\n[... truncated ...]'
  fi
  printf '%s' "$out"
}

# ------------------------------------------------------------------------------------ the scan
# cd_target <segment-masked> -> prints the directory a `cd`/`pushd` segment moves to (relative
# to DIR), "?" when it cannot be known statically ($VAR, `cd -`, ~user, `pushd +N`), "POPD" for
# a `popd`, nothing when the segment is none of these. A `pushd` result is prefixed "PUSH:" so
# the caller pushes the current directory; the verb is the resolved first word, never a
# substring of the segment (a `cd work/pushd` is a cd).
cd_target() {
  local seg="$1" off len w first="" arg="" n=0
  while IFS=' ' read -r off len; do
    [ -n "$off" ] || continue
    w="${seg:$off:$len}"
    if [ "$n" -eq 0 ]; then
      case "$w" in [a-zA-Z_]*=*) continue ;; esac
      first="$w"
    elif [ -z "$arg" ]; then
      case "$w" in -L|-P|-e|-@) ;; *) arg="$w" ;; esac
    fi
    n=$((n + 1))
  done <<ARGV
$(argv_spans "$seg")
ARGV
  case "$first" in
    cd|pushd) ;;
    popd) if [ -z "$arg" ]; then printf 'POPD'; else printf '?'; fi; return 0 ;;
    *) return 0 ;;
  esac
  if [ -z "$arg" ]; then
    # bare `pushd` swaps the top two stack entries; bare `cd` goes home
    if [ "$first" = pushd ]; then printf '?'; else printf '%s' "${HOME:-?}"; fi
    return 0
  fi
  [ "$first" = pushd ] && printf 'PUSH:'
  word_is_runtime "$arg" && { printf '?'; return 0; }
  arg=$(unquote_word "$arg")
  case "$arg" in
    -|'~'?*|+[0-9]*|-[0-9]*) printf '?' ;;
    '~'|'~/'*) printf '%s' "${HOME:-?}${arg#\~}" ;;
    /*) printf '%s' "$arg" ;;
    *) printf '%s' "$DIR/$arg" ;;
  esac
}

MASKED=$(mask_all_heredocs "$COMMAND")
BAD_BODIES=""
BAD_DIR=""
DIR="$CWD"
DIR_STACK=""
while IFS=' ' read -r OFF LEN; do
  [ -n "$OFF" ] || continue
  SEG_MASKED="${MASKED:$OFF:$LEN}"
  SEG_ORIG="${COMMAND:$OFF:$LEN}"
  NEWDIR=$(cd_target "$SEG_MASKED")
  if [ -n "$NEWDIR" ]; then
    # A pushd/popd stack mirrors the shell's, so `pushd wt && … && popd` returns to DIR.
    case "$NEWDIR" in
      POPD)
        if [ -n "$DIR_STACK" ]; then
          DIR="${DIR_STACK%%$'\n'*}"
          case "$DIR_STACK" in *$'\n'*) DIR_STACK="${DIR_STACK#*$'\n'}" ;; *) DIR_STACK="" ;; esac
        else
          DIR="?"
        fi ;;
      *)
        case "$NEWDIR" in
          PUSH:*) DIR_STACK="$DIR${DIR_STACK:+$'\n'}$DIR_STACK"; NEWDIR="${NEWDIR#PUSH:}" ;;
        esac
        DIR="$NEWDIR" ;;
    esac
    continue
  fi
  CUR_OFF=$OFF CUR_LEN=$LEN CUR_ORIG="$SEG_ORIG"
  reply_body "$SEG_MASKED" "$SEG_ORIG"
  [ -n "$REPLY_KIND" ] || continue
  [ "$DIR" != "?" ] || continue          # posted from a directory this hook cannot know
  opted_in "$DIR" || continue
  [ -n "${REPLY_BODY//[[:space:]]/}" ] || continue
  claims_fix "$REPLY_BODY" || continue
  body_names_good_commit "$REPLY_BODY" && continue
  [ "$REPLY_RUNTIME" -eq 1 ] && continue
  BAD_BODIES="$BAD_BODIES$REPLY_BODY"$'\n'
  BAD_DIR="$DIR"
done <<SEGMENTS
$(split_simple_commands "$MASKED")
SEGMENTS

[ -n "$BAD_BODIES" ] || exit 0
DIR="$BAD_DIR"

CTX=$(diff_context "$BAD_BODIES")
REASON="repo-ops review-reply-postcondition: this command contains a review reply that claims a fix but names no commit that exists in this checkout and is reachable from HEAD (or its upstream). A 'fixed' reply must name the commit that fixed it, and be written after re-reading the diff, not from the plan. Re-read the diff below (git show <sha>), confirm the change really does what the reply says, then post a corrected reply that names the real commit SHA — and if the fix is partial, say exactly which part is done and which is not. If you have not pushed the fix yet, do that first. (This hook reads the command, not which parts of it ran: if that reply was never posted — a short-circuited && or a failed command — there is nothing to correct, and you should not post one.)"
jq -n --arg reason "$REASON" --arg ctx "Diff context (best effort; files named in the reply, else the latest commits):
$CTX" '{
  decision: "block",
  reason: $reason,
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $ctx }
}'
exit 0
