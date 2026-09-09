#!/usr/bin/env bash
#
# Tests for the repo-profile helpers in plugins/core/scripts/.
#
# The profile is the standard a whole fleet of repos is held to, and these two scripts are
# what `new-repo` writes from and what `doctor --profile` reports from. So the cases that
# matter most are the ones where a bug would make a WRONG standard look applied: an
# explicit `null` read as an absent key (which would gate a repo everyone agreed was
# exempt), a required check silently dropped, a failed API read rendered as a settings
# difference somebody would then paste. Every one of those must be caught here rather than
# by a maintainer reading a drift issue.
#
#   ./scripts/test-profile.sh
#
# Requires: bash 3.2+, jq. No network — settings-diff.sh reads files by design, which is
# what makes the whole GitHub-settings diff testable offline.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVE="$ROOT/plugins/core/scripts/profile-resolve.sh"
DIFF="$ROOT/plugins/core/scripts/settings-diff.sh"
EXAMPLE="$ROOT/plugins/core/references/example-profile.json"

pass=0
fail=0
output=""
errout=""
status=0

ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

# run <cmd...> -> sets $status, $output (stdout) and $errout (stderr).
# Kept apart on purpose: profile-resolve.sh prints JSON on stdout and diagnostics on
# stderr, and a test harness that merges them can'''t tell a resolved profile from a
# warning printed beside one — which is exactly the case being tested below.
run() {
  errfile="$(mktemp "${TMPDIR:-/tmp}/maintainerd-profile-err.XXXXXX")"
  output="$("$@" 2>"$errfile")"; status=$?
  errout="$(cat "$errfile")"; rm -f "$errfile"
}

expect_status() {
  local label="$1" want="$2"
  if [ "$status" = "$want" ]; then ok "$label"; else bad "$label" "expected exit $want, got $status: $output"; fi
}

# Matches against stdout and stderr together: a finding is a finding wherever it printed.
expect_match() {
  local label="$1" pattern="$2"
  case "$output$errout" in
    *"$pattern"*) ok "$label" ;;
    *) bad "$label" "expected '$pattern' in: $output" ;;
  esac
}

expect_no_match() {
  local label="$1" pattern="$2"
  case "$output$errout" in
    *"$pattern"*) bad "$label" "did not expect '$pattern' in: $output" ;;
    *) ok "$label" ;;
  esac
}

# expect_jq <label> <jq filter over $output>
expect_jq() {
  local label="$1" filter="$2"
  if printf '%s' "$output" | jq -e "$filter" >/dev/null 2>&1; then ok "$label"
  else bad "$label" "filter '$filter' failed against: $output"; fi
}

scratch() { mktemp -d "${TMPDIR:-/tmp}/maintainerd-profile.XXXXXX"; }
d="$(scratch)"
trap 'rm -rf "$d"' EXIT INT TERM

echo "profile-resolve.sh — shape"

run "$RESOLVE" --profile "$EXAMPLE" --validate
expect_status "the shipped example profile validates" 0
expect_match  "and says which version and how many languages" "v1, 4 languages"

run "$RESOLVE" --profile "$d/nope.json" --validate
expect_status "a missing profile is an error, not an empty standard" 1

printf 'not json{' > "$d/broken.json"
run "$RESOLVE" --profile "$d/broken.json" --validate
expect_status "malformed JSON fails closed" 1

printf '[]' > "$d/array.json"
run "$RESOLVE" --profile "$d/array.json" --validate
expect_status "a JSON array is not a profile" 1

jq '.profileVersion = 2' "$EXAMPLE" > "$d/future.json"
run "$RESOLVE" --profile "$d/future.json" --validate
expect_status "a newer profileVersion is refused, not guessed at" 1
expect_match  "and says to upgrade rather than downgrade the read" "upgrade maintainerd"

jq '.languages["shell"].private = false' "$EXAMPLE" > "$d/fixedkey.json"
run "$RESOLVE" --profile "$d/fixedkey.json" --validate
expect_status "a language block carrying a fixed org-wide key is an error" 1
expect_match  "naming the key" 'languages.shell carries "private"'

jq '.repoOverrides["site"].labels = ["extra"]' "$EXAMPLE" > "$d/ovkey.json"
run "$RESOLVE" --profile "$d/ovkey.json" --validate
expect_status "so is an override carrying one" 1
expect_match  "naming the block" 'repoOverrides.site carries "labels"'

jq '.languages["shell"].coverage = {"mode": "floor", "target": 80}' "$EXAMPLE" > "$d/mode.json"
run "$RESOLVE" --profile "$d/mode.json" --validate
expect_status "ratchet is the only coverage mode" 1
expect_match  "and the message says so" '"ratchet" is the only mode'

jq '.languages = {}' "$EXAMPLE" > "$d/nolangs.json"
run "$RESOLVE" --profile "$d/nolangs.json" --validate
expect_status "an empty languages table resolves nothing" 1

jq '.languages["shell"].requiredChecks = "ci"' "$EXAMPLE" > "$d/badchecks.json"
run "$RESOLVE" --profile "$d/badchecks.json" --validate
expect_status "requiredChecks must be an array" 1

echo "profile-resolve.sh — resolution"

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/worker --language typescript-web
expect_status "a repo with no override resolves" 0
expect_jq "and reports that no override applied" '.overrideKey == null'
expect_jq "fixed keys come from defaults" '.effective.private == true'
expect_jq "the language's checks are the effective checks" '.effective.requiredChecks == ["ci"]'
expect_jq "and its coverage policy is inherited" '.effective.coverage.target == 50'

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/app --language python-service
expect_status "an override resolves" 0
expect_jq "requiredChecks are ADDITIVE across language and override" \
  '.effective.requiredChecks == ["ci","docs","migration-collision","docker-smoke"]'
expect_jq "and deduplicated — the override repeated \"ci\"" \
  '([.effective.requiredChecks[] | select(. == "ci")] | length) == 1'
expect_jq "an override that names only requiredChecks leaves coverage alone" \
  '.effective.coverage.target == 70'

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/site --language typescript-web
expect_status "the exempt repo resolves" 0
expect_jq "an explicit null in an override beats the language's ratchet" '.effective.coverage == null'
expect_jq "commands merge key by key — test is the override's" \
  '.effective.commands.test == "npm run build && npm run linkcheck"'
expect_jq "...and lint is still the language's" '.effective.commands.lint == "npm run lint"'
expect_jq "a coverage exemption nulls commands.coverage wherever it came from" \
  '.effective.commands.coverage == null'

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/nothing-special --language shell
expect_jq "a language-level coverage null is an exemption too" '.effective.coverage == null'
# The literal is the profile's command text, not something to expand here.
# shellcheck disable=SC2016
expect_jq "and the shell lint command survives shell-quoting through jq" \
  '.effective.commands.lint == "shellcheck -x $(git ls-files '"'"'*.sh'"'"')"'

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/app --language no-such-language
expect_status "an unknown language is an error, never a fallback to defaults" 1
expect_match  "and the message lists the keys that do exist" "python-service, typescript-web, shell, none"

# A profile carrying both a short-name and a full-slug key for one repo: the slug wins,
# and the duplication is called out rather than silently resolved.
jq '.repoOverrides["my-org/site"] = {"requiredChecks": ["ci","slug-only"]}' "$EXAMPLE" > "$d/dupe.json"
run "$RESOLVE" --profile "$d/dupe.json" --repo my-org/site --language typescript-web
expect_status "a slug-keyed override resolves" 0
expect_jq "the full slug wins over the short name" '.overrideKey == "my-org/site"'
expect_jq "so the slug entry's checks are the effective ones" \
  '.effective.requiredChecks == ["ci","slug-only"]'
expect_match "and the duplication is reported" "two repoOverrides keys resolve to the same repo"

run "$RESOLVE" --profile "$EXAMPLE" --languages
expect_match "--languages lists the keys" "typescript-web"

run "$RESOLVE" --profile "$EXAMPLE" --repo my-org/app
expect_status "resolving without a language is a usage error" 2

echo "settings-diff.sh"

"$RESOLVE" --profile "$EXAMPLE" --repo my-org/app --language python-service > "$d/eff-app.json"
"$RESOLVE" --profile "$EXAMPLE" --repo my-org/site --language typescript-web > "$d/eff-site.json"

# A fully conformant repo.
cat > "$d/repo-ok.json" <<'JSON'
{"private": true, "allow_squash_merge": true, "allow_merge_commit": false,
 "allow_rebase_merge": false, "delete_branch_on_merge": true}
JSON
cat > "$d/prot-ok.json" <<'JSON'
{"required_status_checks": {"strict": false, "contexts": ["ci","docs","migration-collision","docker-smoke"]},
 "enforce_admins": {"enabled": false},
 "required_pull_request_reviews": {"required_approving_review_count": 1, "dismiss_stale_reviews": true},
 "required_linear_history": {"enabled": true},
 "allow_force_pushes": {"enabled": false},
 "allow_deletions": {"enabled": false}}
JSON
cat > "$d/rules-ok.json" <<'JSON'
[{"id": 1, "enforcement": "active",
  "rules": [{"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}}]}]
JSON
jq '.effective.labels + ["a-label-the-profile-never-heard-of"]' "$d/eff-app.json" > "$d/labels-ok.json"

run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" \
  --repo-settings "$d/repo-ok.json" --protection "$d/prot-ok.json" \
  --rulesets "$d/rules-ok.json" --labels "$d/labels-ok.json"
expect_status "a conformant repo exits 0" 0
expect_match  "and reports no differences" "Summary: 0 difference(s)"
expect_no_match "a label the profile doesn't name is NOT drift" "a-label-the-profile-never-heard-of"
expect_no_match "and no protection PUT is printed when nothing differs" "method PUT"
expect_match  "the unenforceable key is named rather than passed silently" "countsBotApproval"

# Nothing read at all: every section is "couldn't verify", and that is not a difference.
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json"
expect_status "reads that never happened are not differences" 0
expect_match  "protection is reported unverified" "branch protection on main not read"
expect_match  "and so are the rulesets" "rulesets not read"
expect_no_match "nothing is reported as FAIL" "FAIL"

# A repo that differs on every axis.
cat > "$d/repo-bad.json" <<'JSON'
{"private": false, "allow_squash_merge": true, "allow_merge_commit": true,
 "allow_rebase_merge": true, "delete_branch_on_merge": false}
JSON
cat > "$d/prot-bad.json" <<'JSON'
{"required_status_checks": {"strict": true, "contexts": ["ci","stale-check"]},
 "enforce_admins": {"enabled": true},
 "required_pull_request_reviews": {"required_approving_review_count": 0, "dismiss_stale_reviews": false},
 "required_linear_history": {"enabled": false},
 "allow_force_pushes": {"enabled": true},
 "allow_deletions": {"enabled": false}}
JSON
echo '[]' > "$d/rules-none.json"
echo '["architecture"]' > "$d/labels-thin.json"

run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" \
  --repo-settings "$d/repo-bad.json" --protection "$d/prot-bad.json" \
  --rulesets "$d/rules-none.json" --labels "$d/labels-thin.json"
expect_status "a drifted repo exits 1" 1
expect_match "the merge-commit difference carries its PATCH call" \
  'gh api --method PATCH "repos/my-org/app" -F allow_merge_commit=false'
expect_match "so does the force-push difference — via the one PUT" "allow_force_pushes is true"
expect_match "a missing required check is named" 'does not require the check "migration-collision"'
expect_match "a check required on the branch but not in the profile warns that the PUT drops it" \
  "would REMOVE it"
expect_match "the merge queue's fix is a ruleset POST, not a protection PUT" \
  'method POST "repos/my-org/app/rulesets"'
expect_match "a missing label carries its create call" \
  "gh label create 'automated' --repo my-org/app"
expect_match "branch protection is fixed by ONE call carrying the whole object" \
  'method PUT "repos/my-org/app/branches/main/protection"'
expect_match "and the reason that call is whole-object is stated" \
  "sending only the diverging key would clear the rest"

# The PUT body must carry the full desired state, not just what differed.
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '
      (.required_status_checks.contexts == ["ci","docs","migration-collision","docker-smoke"])
      and (.required_linear_history == true) and (.allow_force_pushes == false)
      and (.required_pull_request_reviews.required_approving_review_count == 1)
      and (has("restrictions"))' >/dev/null 2>&1; then
  ok "the PUT body is the complete desired protection"
else
  bad "the PUT body is the complete desired protection" "$body"
fi

# No protection at all is a finding in its own words, not seven key-by-key ones.
echo '{"message": "Branch not protected", "documentation_url": "https://docs.github.com"}' > "$d/prot-404.json"
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" --protection "$d/prot-404.json"
expect_status "an unprotected branch is a difference" 1
expect_match  "reported as the one fact it is" "has no branch protection at all"

# An exempt repo still has settings; the exemption is about coverage, not conformance.
run "$DIFF" --repo my-org/site --effective "$d/eff-site.json" --repo-settings "$d/repo-ok.json"
expect_status "a coverage-exempt repo is still held to the settings standard" 0

run "$DIFF" --repo my-org/app --effective "$d/broken.json"
expect_status "a malformed effective object is a usage error, not a clean report" 2

run "$DIFF" --effective "$d/eff-app.json"
expect_status "--repo is required: the fix calls have to address something" 2

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
