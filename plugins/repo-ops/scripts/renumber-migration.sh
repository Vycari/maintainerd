#!/usr/bin/env bash
#
# renumber-migration.sh — re-parent this branch's migrations onto the live head of the base branch.
#
#   renumber-migration.sh [--base REF] [--dry-run] [--no-fetch] [--config FILE]
#
# The cure for a migration collision: another PR merged a migration with the id this branch
# claimed, so the chain has two heads (or two files with one id). This tool
#
#   1. finds the migrations this branch added (in the index, absent from the base). The base must
#      already be merged or rebased into the branch: only then does the working tree hold the
#      base's migrations, which is what the graph check needs to judge,
#   2. reads the base's head revision (it must be exactly one),
#   3. renumbers the branch's migrations to head+1, head+2, ... in their existing chain order:
#      `git mv` to the new name, rewrite `revision` and `down_revision` (and the `Revision ID:` /
#      `Revises:` lines of the docstring header, if present), the first chained onto the base head,
#   4. re-runs the repo's graph check (`commands.migrationGraph`) and reports.
#
# It stages its changes and leaves the commit to the caller. It never pushes, and it never touches
# a file it did not add to the branch. Re-running it is safe: a branch already chained off the live
# head reports `up-to-date` and changes nothing.
#
# Verdict on the first line of stdout, exit status mirroring it:
#
#   renumbered:<n>         <n> migrations were moved or re-chained; the graph check passed. 0
#   would-renumber:<n>     --dry-run: the plan follows, nothing was changed. 0
#   up-to-date             already chained off the live head with the right numbers; the graph
#                          check passed. Re-running after a successful run lands here. 0
#   no-migrations          this branch adds no migration. 0
#   not-configured         `commands.migrationGraph` is unset or null: the repo has no migration
#                          graph to maintain, so the tool is inert. 0
#   graph-failed           renumbered (or already current), but the graph check still fails; its
#                          output tail follows, indented. 1
#   refused:<reason>       it could not do this safely and changed nothing: the branch does not
#                          contain the base yet (merge or rebase it first), uncommitted changes in
#                          the migrations directory, a base with no single head, a branch whose
#                          migrations are not one linear chain, a merge migration, a non-numeric
#                          id, a file name that does not start with its revision id. A person
#                          resolves it. 2
#
# Exit 3 is reserved for "the tool could not run" (bad usage, no git, bad config, fetch failed,
# a rewrite that did not read back) and is never a verdict.
#
# Config (.claude/maintainerd.json):
#   commands.migrationGraph   shell command that exits non-zero when the migration chain is broken.
#                             Run from the repo root. null/absent disables the tool.
#   paths.migrations          repo-root-relative directory holding the migration files. Required
#                             once `commands.migrationGraph` is set; there is no default.
#   defaultBranch             the base is `origin/<defaultBranch>` unless --base says otherwise.
#
# Assumes a linear chain of numeric revision ids (`0172`) with files named `<id>_<slug>.<ext>` and
# `revision = "<id>"` / `down_revision = "<id>"` assignments, optionally type-annotated: the shape
# Alembic repos using sequential ids have. A repo whose files are shaped differently gets a
# `refused:` verdict, not a guess.
#
# It steps over nothing but the base head. An id that another OPEN PR has claimed is invisible to
# it; if the graph check names such a collision, renumber again after that PR lands.
#
# Flags: --base REF (default origin/<defaultBranch>), --dry-run, --no-fetch (skip `git fetch`),
# --config FILE.
#
# Requires: bash 3.2+, git, jq, sed.

set -uo pipefail
export LC_ALL=C

die() {
  local code="$1"
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

# refuse <reason> [detail...] — a verdict, not an error: the tool ran and chose to change nothing.
refuse() {
  local line
  printf 'refused:%s\n' "$1"
  shift
  for line in "$@"; do printf '  %s\n' "$line"; done
  exit 2
}

BASE=""
DRY=0
FETCH=1
CONFIG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      BASE="$2"
      shift 2
      ;;
    --config)
      [ "$#" -ge 2 ] || die 3 "$1 needs a value"
      CONFIG="$2"
      shift 2
      ;;
    --dry-run)
      DRY=1
      shift
      ;;
    --no-fetch)
      FETCH=0
      shift
      ;;
    -h | --help)
      sed -n '3,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die 3 "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 3 "jq is not installed"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 "not inside a git checkout"
cd "$ROOT" || die 3 "cannot enter $ROOT"

# ── Config ───────────────────────────────────────────────────────────────────
DEFAULT_CONFIG=".claude/maintainerd.json"
[ -n "$CONFIG" ] || CONFIG="$DEFAULT_CONFIG"
CONFIG_JSON="{}"
if [ -f "$CONFIG" ]; then
  CONFIG_JSON="$(cat "$CONFIG")"
elif [ "$CONFIG" != "$DEFAULT_CONFIG" ]; then
  die 3 "--config $CONFIG does not exist"
fi
printf '%s' "$CONFIG_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || die 3 "$CONFIG is not a valid JSON object"

# cfg <jq-path> — a string value; empty when absent, null, or not a string.
cfg() {
  printf '%s' "$CONFIG_JSON" | jq -r "try ($1 | select(type == \"string\")) // empty" 2>/dev/null
}

GRAPH_CMD="$(cfg '.commands.migrationGraph')"
if [ -z "$GRAPH_CMD" ]; then
  printf 'not-configured\n'
  printf '  commands.migrationGraph is not set in %s: this repo has no migration graph to maintain.\n' "$CONFIG"
  exit 0
fi
DIR="$(cfg '.paths.migrations')"
[ -n "$DIR" ] || die 3 "commands.migrationGraph is set but paths.migrations is not: name the migrations directory in $CONFIG"
DIR="${DIR%/}"
case "$DIR" in /* | *..*) die 3 "paths.migrations must be a repo-root-relative path without '..': $DIR" ;; esac

DEFAULT_BRANCH="$(cfg '.defaultBranch')"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
[ -n "$BASE" ] || BASE="origin/$DEFAULT_BRANCH"

if [ "$FETCH" = "1" ]; then
  case "$BASE" in
    origin/*)
      git fetch --quiet origin "${BASE#origin/}" 2>/dev/null ||
        die 3 "git fetch origin ${BASE#origin/} failed; the base head cannot be trusted (--no-fetch uses the local ref)"
      ;;
  esac
fi
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die 3 "base ref $BASE does not resolve"
if ! git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
  refuse "behind-base" "HEAD does not contain $BASE, so this tree lacks the base's newest migrations and the graph check cannot judge it." \
    "Merge or rebase $BASE into this branch (git fetch origin && git rebase $BASE), then re-run."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Parsing ──────────────────────────────────────────────────────────────────
# The first `revision` assignment's quoted id.
rev_of() {
  sed -nE "s/^revision[^=]*=[[:space:]]*[\"']([^\"']*)[\"'].*/\1/p" | head -n 1
}
# Every quoted id on the `down_revision` line(s), one per line. `None` yields nothing.
downs_of() {
  grep -E '^down_revision[^=]*=' | grep -oE "[\"'][^\"']+[\"']" | tr -d "\"'"
}

ls_dir() { # <ref> -> file names directly under $DIR at that ref
  git ls-tree --name-only "$1" "$DIR/" 2>/dev/null | sed "s#^$DIR/##"
}

ls_dir "$BASE" >"$TMP/base-names"
# The branch's files come from the index, so a renumber that is staged but not yet committed is
# seen as what it is, and a re-run before the commit reports `up-to-date`.
git ls-files -- "$DIR/" | sed "s#^$DIR/##" >"$TMP/head-names"
[ -s "$TMP/base-names" ] || die 3 "$BASE has no files under $DIR: is paths.migrations right?"

# The base's head: the revision no other revision names as its parent.
: >"$TMP/base-revs"
: >"$TMP/base-downs"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  git show "$BASE:$DIR/$f" >"$TMP/cur" 2>/dev/null || continue
  r="$(rev_of <"$TMP/cur")"
  [ -n "$r" ] || continue
  printf '%s\n' "$r" >>"$TMP/base-revs"
  downs_of <"$TMP/cur" >>"$TMP/base-downs" || true
done <"$TMP/base-names"
[ -s "$TMP/base-revs" ] || refuse "no-revisions-on-base" "$BASE has files under $DIR but none carries a revision assignment."
grep -vxFf "$TMP/base-downs" "$TMP/base-revs" >"$TMP/base-heads" 2>/dev/null || true
if [ "$(wc -l <"$TMP/base-heads" | tr -d ' ')" != "1" ]; then
  refuse "base-head-ambiguous" "$BASE does not have exactly one head: $(tr '\n' ' ' <"$TMP/base-heads")" \
    "Fix the base before renumbering a branch onto it."
fi
HEAD_ID="$(cat "$TMP/base-heads")"
case "$HEAD_ID" in
  '' | *[!0-9]*) refuse "non-numeric-id" "base head '$HEAD_ID' is not a plain number; this tool only renumbers sequential numeric ids." ;;
esac

# ── The branch's own migrations ──────────────────────────────────────────────
N=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */*) continue ;; esac
  if grep -qxF -- "$f" "$TMP/base-names"; then
    continue
  fi
  [ -f "$DIR/$f" ] || continue
  N=$((N + 1))
  NAME[$N]="$f"
  REV[$N]="$(rev_of <"$DIR/$f")"
  DOWNS="$(downs_of <"$DIR/$f")"
  DOWN[$N]="$DOWNS"
  [ -n "${REV[$N]}" ] || refuse "no-revision" "$DIR/$f has no revision assignment."
  case "${REV[$N]}" in
    *[!0-9]*) refuse "non-numeric-id" "$DIR/$f: revision '${REV[$N]}' is not a plain number." ;;
  esac
  case "$f" in
    "${REV[$N]}"_*) ;;
    *) refuse "name-mismatch" "$DIR/$f does not start with its revision id ${REV[$N]}_." ;;
  esac
  [ "$(printf '%s' "$DOWNS" | grep -c .)" -le 1 ] ||
    refuse "merge-migration" "$DIR/$f has several down_revision ids; a merge migration is not renumbered automatically."
done <"$TMP/head-names"

if [ "$N" -eq 0 ]; then
  printf 'no-migrations\n'
  printf '  this branch adds no file under %s relative to %s.\n' "$DIR" "$BASE"
  exit 0
fi

# Chain order: the migration whose parent is outside the branch's set, then each one's child.
i=1
while [ "$i" -le "$N" ]; do
  USED[$i]=0
  i=$((i + 1))
done
step=1
PREV=""
while [ "$step" -le "$N" ]; do
  FOUND=0
  CAND=0
  i=1
  while [ "$i" -le "$N" ]; do
    if [ "${USED[$i]}" = "0" ]; then
      if [ "$step" -eq 1 ]; then
        inside=0
        j=1
        while [ "$j" -le "$N" ]; do
          [ "${REV[$j]}" != "${DOWN[$i]}" ] || inside=1
          j=$((j + 1))
        done
        if [ "$inside" -eq 0 ]; then
          FOUND=$i
          CAND=$((CAND + 1))
        fi
      elif [ "${DOWN[$i]}" = "$PREV" ]; then
        FOUND=$i
        CAND=$((CAND + 1))
      fi
    fi
    i=$((i + 1))
  done
  [ "$CAND" -eq 1 ] ||
    refuse "not-a-linear-chain" "this branch's migrations under $DIR do not form one linear chain (position $step has $CAND candidates)." \
      "Resolve by hand: ${NAME[*]}"
  ORDER[$step]=$FOUND
  USED[$FOUND]=1
  PREV="${REV[$FOUND]}"
  step=$((step + 1))
done

# ── The plan ─────────────────────────────────────────────────────────────────
WIDTH=${#HEAD_ID}
CHANGES=0
PREV_NEW="$HEAD_ID"
step=1
while [ "$step" -le "$N" ]; do
  i="${ORDER[$step]}"
  NEWID="$(printf '%0*d' "$WIDTH" $((10#$HEAD_ID + step)))"
  PNEWID[$step]="$NEWID"
  PNEWNAME[$step]="$NEWID${NAME[$i]#"${REV[$i]}"}"
  PNEWDOWN[$step]="$PREV_NEW"
  PCHANGE[$step]=0
  if [ "${PNEWNAME[$step]}" != "${NAME[$i]}" ] || [ "${DOWN[$i]}" != "$PREV_NEW" ]; then
    PCHANGE[$step]=1
    CHANGES=$((CHANGES + 1))
  fi
  PREV_NEW="$NEWID"
  step=$((step + 1))
done

# run_graph_check — exits 1 with the output tail when the repo's own graph check fails.
run_graph_check() {
  local out
  if out="$(bash -c "$GRAPH_CMD" 2>&1)"; then
    return 0
  fi
  printf 'graph-failed\n'
  printf '  `%s` still fails:\n' "$GRAPH_CMD"
  printf '%s\n' "$out" | tail -n 20 | sed 's/^/  | /'
  exit 1
}

print_plan() {
  local s k
  s=1
  while [ "$s" -le "$N" ]; do
    k="${ORDER[$s]}"
    if [ "${PCHANGE[$s]}" = "1" ]; then
      printf '  %s -> %s  (revision %s -> %s, down_revision %s -> %s)\n' \
        "${NAME[$k]}" "${PNEWNAME[$s]}" "${REV[$k]}" "${PNEWID[$s]}" "${DOWN[$k]:-none}" "${PNEWDOWN[$s]}"
    fi
    s=$((s + 1))
  done
}

if [ "$CHANGES" -eq 0 ]; then
  run_graph_check
  printf 'up-to-date\n'
  printf '  %s migration(s) already chain off %s head %s.\n' "$N" "$BASE" "$HEAD_ID"
  exit 0
fi

if [ "$DRY" = "1" ]; then
  printf 'would-renumber:%s\n' "$CHANGES"
  printf '  onto %s head %s\n' "$BASE" "$HEAD_ID"
  print_plan
  exit 0
fi

# ── Preflight, then apply ────────────────────────────────────────────────────
[ -z "$(git status --porcelain -- "$DIR" 2>/dev/null)" ] ||
  refuse "uncommitted-changes" "$DIR has uncommitted changes; commit or stash them first so a renumber is one reviewable diff."

step=1
while [ "$step" -le "$N" ]; do
  i="${ORDER[$step]}"
  if [ "${PNEWNAME[$step]}" != "${NAME[$i]}" ] && [ -e "$DIR/${PNEWNAME[$step]}" ]; then
    # The branch's own files are about to be vacated; anything else at the target is a real clash.
    mine=0
    j=1
    while [ "$j" -le "$N" ]; do
      [ "${NAME[$j]}" != "${PNEWNAME[$step]}" ] || mine=1
      j=$((j + 1))
    done
    [ "$mine" -eq 1 ] || refuse "target-exists" "$DIR/${PNEWNAME[$step]} already exists and is not one of this branch's migrations."
  fi
  step=$((step + 1))
done

# Phase 1: every renamed file to a scratch name, so 0172 -> 0173 cannot land on a not-yet-moved 0173.
step=1
while [ "$step" -le "$N" ]; do
  i="${ORDER[$step]}"
  if [ "${PNEWNAME[$step]}" != "${NAME[$i]}" ]; then
    git mv -- "$DIR/${NAME[$i]}" "$DIR/.renumber.$step" ||
      die 3 "git mv ${NAME[$i]} failed; run \`git status\` and move any $DIR/.renumber.* file back"
  fi
  step=$((step + 1))
done

# Phase 2: final names, ids rewritten. sed -E to a temp file, not -i, for BSD/GNU parity.
Q="[\"']"
step=1
while [ "$step" -le "$N" ]; do
  i="${ORDER[$step]}"
  if [ "${PNEWNAME[$step]}" != "${NAME[$i]}" ]; then
    git mv -- "$DIR/.renumber.$step" "$DIR/${PNEWNAME[$step]}" ||
      die 3 "git mv to ${PNEWNAME[$step]} failed; run \`git status\` and move any $DIR/.renumber.* file"
  fi
  F="$DIR/${PNEWNAME[$step]}"
  OLD="${REV[$i]}"
  OLDDOWN="${DOWN[$i]}"
  NEW="${PNEWID[$step]}"
  NEWDOWN="${PNEWDOWN[$step]}"
  if [ -n "$OLDDOWN" ]; then
    DOWN_EXPR="s/^(down_revision[^=]*=[[:space:]]*$Q)$OLDDOWN($Q)/\\1$NEWDOWN\\2/"
    REVISES_EXPR="s/^(Revises:[[:space:]]*)$OLDDOWN([[:space:]]*)\$/\\1$NEWDOWN\\2/"
  else
    # A migration with down_revision = None (a root) is being given a parent.
    DOWN_EXPR="s/^(down_revision[^=]*=[[:space:]]*)None/\\1\"$NEWDOWN\"/"
    REVISES_EXPR="s/^(Revises:[[:space:]]*)(None)?[[:space:]]*\$/\\1$NEWDOWN/"
  fi
  sed -E \
    -e "s/^(revision[^=]*=[[:space:]]*$Q)$OLD($Q)/\\1$NEW\\2/" \
    -e "s/^(Revision ID:[[:space:]]*)$OLD([[:space:]]*)\$/\\1$NEW\\2/" \
    -e "$DOWN_EXPR" \
    -e "$REVISES_EXPR" \
    "$F" >"$TMP/rewrite" || die 3 "could not rewrite $F"
  cat "$TMP/rewrite" >"$F"
  git add -- "$F"
  # Read it back: a pattern that silently missed would leave the file half-renumbered.
  GOT_REV="$(rev_of <"$F")"
  GOT_DOWN="$(downs_of <"$F")"
  if [ "$GOT_REV" != "$NEW" ] || [ "$GOT_DOWN" != "$NEWDOWN" ]; then
    die 3 "$F reads back revision='$GOT_REV' down_revision='$GOT_DOWN', wanted '$NEW'/'$NEWDOWN': the assignment is shaped in a way this tool does not rewrite. Inspect with \`git diff --cached\`."
  fi
  step=$((step + 1))
done

# Lines elsewhere that still cite an old id or file name. Reported, never edited: prose is the author's.
: >"$TMP/stale"
step=1
while [ "$step" -le "$N" ]; do
  i="${ORDER[$step]}"
  if [ "${PNEWNAME[$step]}" != "${NAME[$i]}" ]; then
    git grep -n -I -F -e "${NAME[$i]%.*}" >>"$TMP/stale" 2>/dev/null || true
    git grep -n -I -i -E -e "migrations? +${REV[$i]}([^0-9]|\$)" >>"$TMP/stale" 2>/dev/null || true
  fi
  step=$((step + 1))
done

run_graph_check
printf 'renumbered:%s\n' "$CHANGES"
printf '  onto %s head %s; changes are staged, not committed.\n' "$BASE" "$HEAD_ID"
print_plan
if [ -s "$TMP/stale" ]; then
  printf '  these lines may still cite an old id or file name (not edited):\n'
  sort -u "$TMP/stale" | head -n 20 | sed 's/^/    /'
fi
exit 0
