#!/usr/bin/env bash
#
# Tests for plugins/repo-ops/scripts/renumber-migration.sh.
#
# Every case builds a real throwaway git history (a bare "origin" and a clone) with a handful of
# Alembic-shaped migration files, and runs the real script against it. No network, no Alembic: the
# repo's graph check is a one-line shell command the case supplies. Run from anywhere:
#
#   ./scripts/test-renumber-migration.sh
#
# Requires bash, git, jq.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/plugins/repo-ops/scripts/renumber-migration.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

DIRP="db/versions"
# A graph check that fails on duplicate revision ids or more than one head, as a repo's own would.
GRAPH='cd db/versions && revs=$(sed -nE "s/^revision[^=]*= *[\"'"'"']([^\"'"'"']*).*/\1/p" *.py | sort) && [ "$(printf "%s\n" "$revs" | uniq -d | wc -l)" -eq 0 ] && downs=$(sed -nE "s/^down_revision[^=]*= *[\"'"'"']([^\"'"'"']*).*/\1/p" *.py | sort) && [ "$(printf "%s\n" "$revs" | grep -vxFf <(printf "%s\n" "$downs") | wc -l)" -eq 1 ]'

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "$2"
}

# mig <dir> <id> <down|None> <slug> [annotated] — write a migration file in the alembic template's shape.
mig() {
  local d="$1" id="$2" down="$3" slug="$4" ann="${5:-}" dq
  if [ "$down" = "None" ]; then dq="None"; else dq="\"$down\""; fi
  {
    printf '"""%s\n\nRevision ID: %s\nRevises: %s\nCreate Date: 2026-01-01\n"""\n' "$slug" "$id" "$down"
    if [ -n "$ann" ]; then
      printf 'revision: str = "%s"\ndown_revision: str | None = %s\n' "$id" "$dq"
    else
      printf "revision = '%s'\ndown_revision = %s\n" "$id" "$dq"
    fi
    printf '\ndef upgrade():\n    pass\n'
  } >"$d/${id}_${slug}.py"
}

# new_case <name> [config-json] -> CASE, WORK (clone, on branch `feat`), ORIGIN. History: 0001..0003 on
# main. The config is committed to main so a branch inherits it.
new_case() {
  CASE="$TMP/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"
  WORK="$CASE/work"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK" 2>/dev/null
  (
    cd "$WORK" || exit 1
    git checkout -q -b main
    mkdir -p "$DIRP" .claude
    mig "$DIRP" 0001 None init annotated
    mig "$DIRP" 0002 0001 users annotated
    mig "$DIRP" 0003 0002 rooms annotated
    jq -n --arg g "$GRAPH" --arg d "$DIRP" '{defaultBranch: "main", commands: {migrationGraph: $g}, paths: {migrations: $d}}' >.claude/maintainerd.json
    [ -z "${2:-}" ] || printf '%s' "$2" >.claude/maintainerd.json
    echo "see migration 0004_widgets for context" >NOTES.md
    git add -A && git commit -q -m base && git push -q origin main 2>/dev/null
    git checkout -q -b feat
  )
}

# land_on_main <id> <down> <slug> — another PR merges a migration into origin/main
land_on_main() {
  (
    cd "$WORK" || exit 1
    git checkout -q main
    mig "$DIRP" "$1" "$2" "$3" annotated
    git add -A && git commit -q -m "main: $3" && git push -q origin main 2>/dev/null
    git checkout -q feat
  )
}
# sync_branch — bring origin/main into the feature branch, as `git merge origin/main` does for a person
sync_branch() {
  (cd "$WORK" && git fetch -q origin && git merge -q --no-edit origin/main >/dev/null 2>&1)
}

# on_branch <id> <down> <slug> [annotated] — commit a migration on the feature branch
on_branch() {
  (
    cd "$WORK" || exit 1
    mig "$DIRP" "$1" "$2" "$3" "${4-annotated}"
    git add -A && git commit -q -m "feat: $3"
  )
}

run_tool() {
  OUT="$(cd "$WORK" && "${BASH:-bash}" "$TOOL" "$@" 2>"$CASE/stderr")"
  RC=$?
  ERR="$(cat "$CASE/stderr")"
}
first() { printf '%s' "$OUT" | head -n 1; }

expect() { # <label> <want-first-line> <want-rc>
  if [ "$(first)" = "$2" ] && [ "$RC" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "want '$2' rc=$3; got '$(first)' rc=$RC (stderr: $ERR) out: $OUT"
  fi
}
expect_contains() { # <label> <needle>
  case "$OUT" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "output lacks '$2': $OUT" ;;
  esac
}
in_work() { (cd "$WORK" && "$@"); }
file_has() { # <label> <file> <fixed string>
  if grep -qF -- "$3" "$WORK/$2" 2>/dev/null; then ok "$1"; else bad "$1" "$2 lacks '$3': $(cat "$WORK/$2" 2>/dev/null)"; fi
}
file_lacks() {
  if grep -qF -- "$3" "$WORK/$2" 2>/dev/null; then bad "$1" "$2 still has '$3'"; else ok "$1"; fi
}
exists() { [ -f "$WORK/$2" ] && ok "$1" || bad "$1" "$2 is missing"; }
absent() { [ ! -e "$WORK/$2" ] && ok "$1" || bad "$1" "$2 should be gone"; }

echo "renumber-migration"

[ -x "$TOOL" ] && ok "the script is executable (the README runs it by path)" || bad "mode" "$TOOL is not executable"

# ── inert without config ────────────────────────────────────────────────────
new_case unconfigured '{"defaultBranch":"main","commands":{"migrationGraph":null}}'
on_branch 0004 0003 widgets
run_tool
expect "commands.migrationGraph null -> not-configured, exit 0" not-configured 0
exists "nothing was touched" "$DIRP/0004_widgets.py"

new_case no-config-file
rm -f "$WORK/.claude/maintainerd.json"
git -C "$WORK" commit -q -am rm
run_tool
expect "no config file at all -> not-configured" not-configured 0

new_case no-path '{"commands":{"migrationGraph":"true"}}'
run_tool
[ "$RC" = "3" ] && ok "migrationGraph without paths.migrations is a tool error (exit 3)" || bad "path required" "rc=$RC out=$OUT"

new_case bad-config 'not json'
run_tool
[ "$RC" = "3" ] && ok "malformed config is a tool error (exit 3)" || bad "bad config" "rc=$RC out=$OUT"

# ── the collision it exists for ─────────────────────────────────────────────
new_case collision
on_branch 0004 0003 widgets ""
land_on_main 0004 0003 gadgets
sync_branch
run_tool --dry-run
expect "dry run -> would-renumber:1" would-renumber:1 0
expect_contains "dry run prints the plan" "0004_widgets.py -> 0005_widgets.py"
exists "dry run changed nothing" "$DIRP/0004_widgets.py"
in_work git status --porcelain | grep -q . && bad "dry run leaves a clean tree" "$(in_work git status --porcelain)" || ok "dry run leaves a clean tree"

run_tool
expect "collision on 0004 -> renumbered:1" renumbered:1 0
exists "file moved to the next number" "$DIRP/0005_widgets.py"
absent "old name is gone" "$DIRP/0004_widgets.py"
file_has "revision rewritten (unannotated, single quotes)" "$DIRP/0005_widgets.py" "revision = '0005'"
file_has "down_revision re-chained onto the live head" "$DIRP/0005_widgets.py" 'down_revision = "0004"'
file_has "docstring Revision ID rewritten" "$DIRP/0005_widgets.py" "Revision ID: 0005"
file_has "docstring Revises rewritten" "$DIRP/0005_widgets.py" "Revises: 0004"
file_lacks "no stale revision left" "$DIRP/0005_widgets.py" "'0004'"
in_work git diff --cached --name-only | grep -qx "$DIRP/0005_widgets.py" && ok "the new file is staged" || bad "staged" "$(in_work git diff --cached --name-status)"
expect_contains "stale prose references are reported" "NOTES.md"
file_has "and not edited" NOTES.md "migration 0004_widgets"
in_work git status --porcelain | grep -q 'renumber' && bad "no scratch files left" "$(in_work git status --porcelain)" || ok "no scratch files left"

# ── idempotent ──────────────────────────────────────────────────────────────
run_tool
expect "re-run before committing (staged) -> up-to-date" up-to-date 0
in_work git commit -q -m "renumber"
run_tool
expect "re-run after commit -> up-to-date" up-to-date 0
in_work git diff --quiet HEAD && ok "re-run changed nothing" || bad "re-run" "$(in_work git diff HEAD --stat)"
run_tool
expect "and again" up-to-date 0

# main moves again: renumber a second time off the new head
land_on_main 0005 0004 sprockets
sync_branch
land_on_main 0006 0005 cogs
sync_branch
run_tool
expect "main moved again -> renumbered:1 (re-runnable on a busy day)" renumbered:1 0
exists "now 0007" "$DIRP/0007_widgets.py"
file_has "chained off 0006" "$DIRP/0007_widgets.py" 'down_revision = "0006"'
absent "0005 widgets gone" "$DIRP/0005_widgets.py"
run_tool
expect "idempotent after the second renumber" up-to-date 0

# ── several migrations on the branch shift together, in chain order ─────────
new_case chain
on_branch 0004 0003 a
on_branch 0005 0004 b
on_branch 0006 0005 c
land_on_main 0004 0003 other
sync_branch
run_tool
expect "three-migration branch -> renumbered:3" renumbered:3 0
exists "a -> 0005" "$DIRP/0005_a.py"
exists "b -> 0006" "$DIRP/0006_b.py"
exists "c -> 0007" "$DIRP/0007_c.py"
file_has "b chains off a's new id" "$DIRP/0006_b.py" 'down_revision: str | None = "0005"'
file_has "c chains off b's new id" "$DIRP/0007_c.py" 'down_revision: str | None = "0006"'
file_has "a chains off the base head" "$DIRP/0005_a.py" 'down_revision: str | None = "0004"'
exists "main's own migration untouched" "$DIRP/0004_other.py"

# ── a branch that is simply behind (no id clash) is still re-parented ───────
new_case behind
on_branch 0004 0003 widgets
land_on_main 0004 0003 gadgets
sync_branch
run_tool --base origin/main
expect "named base ref" renumbered:1 0

# ── nothing to do ───────────────────────────────────────────────────────────
new_case nothing
run_tool
expect "no branch migration -> no-migrations" no-migrations 0

new_case already-ok
on_branch 0004 0003 widgets
run_tool
expect "already on the head -> up-to-date" up-to-date 0

# ── refusals: nothing is changed ────────────────────────────────────────────
new_case behind-base
on_branch 0004 0003 widgets
(
  cd "$WORK" && git checkout -q main && mig "$DIRP" 0004 0003 gadgets annotated && git add -A && git commit -q -m gadgets && git push -q origin main 2>/dev/null
  git checkout -q feat
)
run_tool
expect "branch lacks the base -> refused:behind-base" refused:behind-base 2
exists "and nothing moved" "$DIRP/0004_widgets.py"

new_case dirty
on_branch 0004 0003 widgets
land_on_main 0004 0003 gadgets
sync_branch
echo "# wip" >>"$WORK/$DIRP/0004_widgets.py"
run_tool
expect "uncommitted change in the migrations dir -> refused" refused:uncommitted-changes 2
file_has "and it stayed put" "$DIRP/0004_widgets.py" "# wip"

new_case non-linear
on_branch 0004 0003 a
on_branch 0005 0003 b
land_on_main 0004 0003 other
sync_branch
run_tool
expect "two branch migrations off one parent -> refused" refused:not-a-linear-chain 2
exists "left alone" "$DIRP/0005_b.py"

new_case merge-migration
on_branch 0004 0003 a
(
  cd "$WORK" && {
    printf 'revision = "0005"\ndown_revision = ("0004", "0003")\n'
  } >"$DIRP/0005_merge.py" && git add -A && git commit -q -m merge
)
land_on_main 0004 0003 other
sync_branch
run_tool
expect "merge migration -> refused" refused:merge-migration 2

new_case nested
mkdir -p "$WORK/$DIRP/archive"
mig "$WORK/$DIRP/archive" 0004 0003 buried annotated
(cd "$WORK" && git add -A && git commit -q -m nested)
run_tool
expect "a branch migration in a subdirectory -> refused, not silently skipped" refused:nested-migration 2

new_case nested-helper
(
  cd "$WORK" && git checkout -q main && mkdir -p "$DIRP/archive" &&
    mig "$DIRP/archive" 0002 0001 old_users annotated &&
    echo "notes" >"$DIRP/archive/README.md" &&
    git add -A && git commit -q -m archive && git push -q origin main 2>/dev/null && git checkout -q feat
)
sync_branch
on_branch 0004 0003 widgets
land_on_main 0004 0003 gadgets
sync_branch
run_tool
expect "an archive subdirectory (README, old revision) is ignored, not a head and not a blocker" renumbered:1 0

new_case nested-readme-on-branch
mkdir -p "$WORK/$DIRP/docs"
echo "notes" >"$WORK/$DIRP/docs/README.md"
(cd "$WORK" && git add -A && git commit -q -m readme)
on_branch 0004 0003 widgets
land_on_main 0004 0003 gadgets
sync_branch
run_tool
expect "a non-migration file added in a subdirectory does not block" renumbered:1 0

new_case nested-unparsed-revision
mkdir -p "$WORK/$DIRP/sub"
printf 'revision = ("0004")\ndown_revision = "0003"\n' >"$WORK/$DIRP/sub/x.py"
(cd "$WORK" && git add "$DIRP/sub/x.py" && git commit -q -m nested)
run_tool
expect "a nested file with an unparseable revision assignment is refused, not skipped" refused:nested-migration 2

new_case inline-comment
(
  cd "$WORK" && printf 'revision = "0004"\ndown_revision = "0003"  # replaces "0002"\n' >"$DIRP/0004_widgets.py" && git add -A && git commit -q -m c
)
land_on_main 0004 0003 gadgets
sync_branch
run_tool
expect "a quoted word in a trailing comment is not a second parent" renumbered:1 0
file_has "and the comment survives" "$DIRP/0005_widgets.py" '"0004"  # replaces "0002"'

new_case non-numeric
on_branch abc123 0003 hashy
run_tool
expect "hash-style id -> refused" refused:non-numeric-id 2

new_case name-mismatch
on_branch 0004 0003 widgets
(cd "$WORK" && git mv "$DIRP/0004_widgets.py" "$DIRP/0009_widgets.py" && git commit -q -m mv)
run_tool
expect "file prefix disagrees with its revision -> refused" refused:name-mismatch 2

new_case two-heads-on-base
land_on_main 0004 0003 one
sync_branch
(
  cd "$WORK" && git checkout -q main && mig "$DIRP" 0005 0003 two annotated && git add -A && git commit -q -m two && git push -q origin main 2>/dev/null
  git checkout -q feat
)
sync_branch
on_branch 0006 0003 widgets
run_tool
expect "base with two heads -> refused" refused:base-head-ambiguous 2

# ── the graph check has the last word ───────────────────────────────────────
new_case graph-fails "$(jq -n --arg d "$DIRP" '{commands: {migrationGraph: "echo chain is broken; exit 1"}, paths: {migrations: $d}}')"
on_branch 0004 0003 widgets
land_on_main 0004 0003 gadgets
sync_branch
run_tool
expect "graph check still red after the renumber -> graph-failed, exit 1" graph-failed 1
expect_contains "its output is relayed" "chain is broken"
exists "the renumber itself stands" "$DIRP/0005_widgets.py"

new_case graph-config-ran-from-root "$(jq -n --arg d "$DIRP" '{commands: {migrationGraph: "test -d .claude && test -d db/versions"}, paths: {migrations: $d}}')"
on_branch 0004 0003 widgets
run_tool
expect "the graph check runs from the repo root" up-to-date 0

# ── environment errors are never verdicts ───────────────────────────────────
new_case bad-base
on_branch 0004 0003 widgets
run_tool --base origin/nope --no-fetch
[ "$RC" = "3" ] && ok "unresolvable base ref is a tool error (exit 3)" || bad "bad base" "rc=$RC out=$OUT"

new_case fetch-fails
on_branch 0004 0003 widgets
git -C "$WORK" remote set-url origin "$CASE/missing.git"
run_tool
[ "$RC" = "3" ] && ok "a failed fetch is a tool error, not a stale head (exit 3)" || bad "fetch" "rc=$RC out=$OUT"
run_tool --no-fetch
expect "--no-fetch trusts the local ref" up-to-date 0

new_case unknown-flag
run_tool --bogus
[ "$RC" = "3" ] && ok "unknown flag is a usage error (exit 3)" || bad "usage" "rc=$RC"

echo
printf '%s\n' "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
