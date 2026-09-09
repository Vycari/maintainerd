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

echo "both scripts parse"

# Both scripts embed a long single-quoted jq program, where one unescaped apostrophe in a
# comment silently ends the quote and turns the rest of the program into shell. `bash -n`
# catches that in a millisecond; without it the symptom is twenty unrelated assertion
# failures.
for script in "$RESOLVE" "$DIFF"; do
  run bash -n "$script"
  expect_status "$(basename "$script") is syntactically valid shell" 0
done

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

# A failed protection read is NOT an unprotected branch. Same JSON shape, opposite fact:
# reporting drift from a read that never established the current state is how a weekly
# drift issue gets muted, and how a blind replacement gets pasted.
echo '{"message": "Must have admin rights to Repository.", "status": "403"}' > "$d/prot-403.json"
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" --protection "$d/prot-403.json"
expect_status "a permissions error on the protection read is not a difference" 0
expect_match  "it is reported as a failed read" "returned an error (Must have admin rights"
expect_no_match "and no replacement call is printed from a state nobody read" "method PUT"

# The PUT replaces the whole object, so protections the profile has no opinion on have
# to be carried through — otherwise fixing a merge method silently unlocks a branch.
cat > "$d/prot-extras.json" <<'JSON'
{"required_status_checks": {"strict": false, "contexts": ["ci","docs","migration-collision","docker-smoke"]},
 "enforce_admins": {"enabled": false},
 "required_pull_request_reviews": {"required_approving_review_count": 1, "dismiss_stale_reviews": false,
                                   "require_code_owner_reviews": true, "require_last_push_approval": true},
 "required_linear_history": {"enabled": true},
 "allow_force_pushes": {"enabled": false},
 "allow_deletions": {"enabled": false},
 "required_conversation_resolution": {"enabled": true},
 "block_creations": {"enabled": true},
 "lock_branch": {"enabled": false},
 "restrictions": {"users": [{"login": "a-maintainer"}], "teams": [{"slug": "core"}], "apps": [{"slug": "some-app"}]}}
JSON
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" --protection "$d/prot-extras.json"
expect_status "the one profile-governed difference is reported" 1
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '
      (.required_conversation_resolution == true) and (.block_creations == true)
      and (.lock_branch == false)
      and (.restrictions.users == ["a-maintainer"]) and (.restrictions.teams == ["core"])
      and (.restrictions.apps == ["some-app"])
      and (.required_pull_request_reviews.require_code_owner_reviews == true)
      and (.required_pull_request_reviews.require_last_push_approval == true)
      and (.required_pull_request_reviews.dismiss_stale_reviews == true)' >/dev/null 2>&1; then
  ok "the replacement carries through every protection the profile has no opinion on"
else
  bad "the replacement carries through every protection the profile has no opinion on" "$body"
fi

# "Zero approvals required" is a statement about approvals, not about the three other
# safeguards that share the required_pull_request_reviews object.
jq '.effective.protection.requiredReviews.count = 0' "$d/eff-app.json" > "$d/eff-noreview.json"
run "$DIFF" --repo my-org/app --effective "$d/eff-noreview.json" --protection "$d/prot-extras.json"
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '
      (.required_pull_request_reviews.required_approving_review_count == 0)
      and (.required_pull_request_reviews.require_code_owner_reviews == true)
      and (.required_pull_request_reviews.require_last_push_approval == true)' >/dev/null 2>&1; then
  ok "requiring zero approvals does not null out code-owner review"
else
  bad "requiring zero approvals does not null out code-owner review" "$body"
fi

# A profile with no opinion about a protection key must not switch it off. `//` would:
# it treats false as empty, so every disabled setting would fall through to the default.
jq 'del(.effective.protection.enforceAdmins, .effective.protection.allowDeletions)' \
   "$d/eff-app.json" > "$d/eff-silent.json"
jq '.enforce_admins.enabled = true | .allow_deletions.enabled = true' \
   "$d/prot-extras.json" > "$d/prot-strict.json"
run "$DIFF" --repo my-org/app --effective "$d/eff-silent.json" --protection "$d/prot-strict.json"
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '(.enforce_admins == true) and (.allow_deletions == true)' >/dev/null 2>&1; then
  ok "a key the profile is silent on keeps the value the branch already had"
else
  bad "a key the profile is silent on keeps the value the branch already had" "$body"
fi

# ...and a profile that explicitly says false still means false, rather than falling
# through to the observed true.
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" --protection "$d/prot-strict.json"
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '(.enforce_admins == false) and (.allow_deletions == false)' >/dev/null 2>&1; then
  ok "an explicit false in the profile still wins over the observed value"
else
  bad "an explicit false in the profile still wins over the observed value" "$body"
fi

# Bypass allowances and app-pinned checks both round-trip into the PUT, so they survive
# the replacement rather than being warned about and then dropped by it. A warning above
# a call that still loses the thing is a warning that gets read after the paste.
jq '.required_pull_request_reviews.bypass_pull_request_allowances = {"users":[{"login":"someone"}],"teams":[{"slug":"admins"}],"apps":[]}
    | .required_status_checks.checks = [{"context":"ci","app_id":15368},{"context":"docs","app_id":15368}]' \
   "$d/prot-extras.json" > "$d/prot-pinned.json"
run "$DIFF" --repo my-org/app --effective "$d/eff-app.json" --protection "$d/prot-pinned.json"
body="$(printf '%s' "$output" | sed -n '/method PUT/,/^  JSON$/p' | sed '1d;$d')"
if printf '%s' "$body" | jq -e '
      (.required_pull_request_reviews.bypass_pull_request_allowances.users == ["someone"])
      and (.required_pull_request_reviews.bypass_pull_request_allowances.teams == ["admins"])' >/dev/null 2>&1; then
  ok "review bypass allowances survive the replacement"
else
  bad "review bypass allowances survive the replacement" "$body"
fi
if printf '%s' "$body" | jq -e '
      (.required_status_checks | has("contexts") | not)
      and ([.required_status_checks.checks[] | select(.context == "ci")] | .[0].app_id == 15368)
      and ([.required_status_checks.checks[] | select(.context == "docs")] | .[0].app_id == 15368)
      and ([.required_status_checks.checks[] | select(.context == "docker-smoke")] | .[0].app_id == null)' >/dev/null 2>&1; then
  ok "an app-pinned check keeps its pin, and a check the profile adds carries none"
else
  bad "an app-pinned check keeps its pin, and a check the profile adds carries none" "$body"
fi
expect_match "and the checks the profile adds without a pin are called out" \
  "with no pin — any app could satisfy those"

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
