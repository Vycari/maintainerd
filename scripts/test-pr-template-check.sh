#!/usr/bin/env bash
#
# Tests for plugins/core/scripts/pr-template-check.sh — the helper `doctor --profile` check 14
# and `bootstrap` step 7 both call to check `files.prTemplateHeadings` and resolve
# `files.prTemplateSource`.
#
# The case that matters most here is the regression this script exists to fix: a heading like
# "## Human overview" is one profile value with a space in it, and the first version of this
# check was an unquoted `for h in $(jq -r ...)` in doctor's SKILL.md that silently split it into
# three separately meaningless grep targets. That bug produced a false PASS — a template missing
# the real heading would still "match" on the lone word "##" if the template happened to contain
# any heading at all — so the multi-word case below isn't a nice-to-have, it's the one case a
# word-splitting regression would pass silently.
#
#   ./scripts/test-pr-template-check.sh
#
# Requires: bash 3.2+, jq.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVE="$ROOT/plugins/core/scripts/profile-resolve.sh"
CHECK="$ROOT/plugins/core/scripts/pr-template-check.sh"
EXAMPLE="$ROOT/plugins/core/references/example-profile.json"

pass=0
fail=0
output=""
errout=""
status=0

ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

run() {
  errfile="$(mktemp "${TMPDIR:-/tmp}/maintainerd-prtmpl-err.XXXXXX")"
  output="$("$@" 2>"$errfile")"; status=$?
  errout="$(cat "$errfile")"; rm -f "$errfile"
}

expect_status() {
  local label="$1" want="$2"
  if [ "$status" = "$want" ]; then ok "$label"; else bad "$label" "expected exit $want, got $status: $output / $errout"; fi
}

expect_match() {
  local label="$1" pattern="$2"
  case "$output$errout" in
    *"$pattern"*) ok "$label" ;;
    *) bad "$label" "expected '$pattern' in: $output$errout" ;;
  esac
}

expect_no_match() {
  local label="$1" pattern="$2"
  case "$output$errout" in
    *"$pattern"*) bad "$label" "did not expect '$pattern' in: $output$errout" ;;
    *) ok "$label" ;;
  esac
}

# Normalized via cd+pwd, not just mktemp's own output: a TMPDIR with a trailing slash (common
# on macOS) would otherwise leave a literal "//" in $d that never matches the normalized path
# pr-template-check.sh's own `cd "$(dirname ...)" && pwd` resolves to.
scratch() { mktemp -d "${TMPDIR:-/tmp}/maintainerd-prtmpl.XXXXXX"; }
d="$(cd "$(scratch)" && pwd)"
trap 'rm -rf "$d"' EXIT INT TERM

echo "pr-template-check.sh parses"
run bash -n "$CHECK"
expect_status "syntactically valid shell" 0

# The example profile already carries both keys — see plugins/core/references/example-profile.json.
"$RESOLVE" --profile "$EXAMPLE" --repo my-org/worker --language typescript-web > "$d/eff.json"

echo "--headings — the word-splitting regression"

# The exact case that broke: a multi-word heading, present in the template. A `for h in $(...)`
# implementation reports this as still missing (it checks for the literal word "##", not the
# line), which is a false FAIL here — but the more dangerous direction is the false PASS below.
cat > "$d/tmpl-good.md" <<'EOF'
## Human overview

some text

## AI reviewer

more text
EOF
run "$CHECK" --effective "$d/eff.json" --headings --template "$d/tmpl-good.md"
expect_status "a template carrying both multi-word headings passes" 0
expect_no_match "and nothing is reported as missing" "missing:"

# The false-PASS direction: a template that does NOT carry the real headings, but does contain
# the word "##" on some other line. A word-splitting implementation would `grep -qxF "##"` and
# find a match, reporting the repo conformant when it is not.
cat > "$d/tmpl-decoy.md" <<'EOF'
## Summary

Just a plain summary section, not the fleet's two-audience shape. This line has ## in it too,
mid-sentence, which is the decoy a word-split implementation would false-match against.
EOF
run "$CHECK" --effective "$d/eff.json" --headings --template "$d/tmpl-decoy.md"
expect_status "a template missing the real headings fails" 1
expect_match "naming the first missing heading in full, not a fragment split on the first space" \
  "missing: ## Human overview"
expect_match "and the second" "missing: ## AI reviewer"

echo "--headings — other cases"

run "$CHECK" --effective "$d/eff.json" --headings --template "$d/no-such-file.md"
expect_status "a template that doesn't exist yet is reported the same as one missing everything" 1
expect_match "both headings are named" "missing: ## Human overview"

jq 'del(.defaults.files.prTemplateHeadings)' "$EXAMPLE" > "$d/noheadings-profile.json"
"$RESOLVE" --profile "$d/noheadings-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-noheadings.json"
run "$CHECK" --effective "$d/eff-noheadings.json" --headings --template "$d/tmpl-decoy.md"
expect_status "a profile with no prTemplateHeadings opinion always passes — existence-only" 0
expect_no_match "nothing is printed" "missing:"

echo "--headings — malformed prTemplateHeadings fails loudly rather than checking nothing"

# profile-resolve.sh --validate rejects these at the profile now (see test-profile.sh), but this
# script is handed an already-built `effective` object and cannot assume every caller validated
# first — a hand-built test fixture, or a future caller that skips validation. `[]?` on a
# non-array silently yields zero elements, which is indistinguishable from "nothing to check" —
# exactly the false PASS this guards against.
echo '{"effective":{"files":{"prTemplateHeadings":"## Human overview"}}}' > "$d/eff-scalar.json"
run "$CHECK" --effective "$d/eff-scalar.json" --headings --template "$d/tmpl-decoy.md"
expect_status "a bare string instead of an array fails, rather than checking zero headings" 1
expect_match "naming the malformed shape, not silence" "invalid: files.prTemplateHeadings must be an array"

echo '{"effective":{"files":{"prTemplateHeadings":false}}}' > "$d/eff-false-headings.json"
run "$CHECK" --effective "$d/eff-false-headings.json" --headings --template "$d/tmpl-decoy.md"
expect_status "false instead of an array fails the same way" 1
expect_match "and says which type it actually got" "got boolean"

echo '{"effective":{"files":{"prTemplateHeadings":["## ok", ""]}}}' > "$d/eff-emptyelem.json"
run "$CHECK" --effective "$d/eff-emptyelem.json" --headings --template "$d/tmpl-decoy.md"
expect_status "an array containing an empty-string element fails too" 1
expect_match "naming the element rule" "must be an array of non-empty strings"

echo "--resolve-source — the layout precondition"

mkdir -p "$d/plug/references"
jq '.defaults.files.prTemplateSource = "references/pr-template.md"' "$EXAMPLE" > "$d/plug/references/repo-profile.json"
printf '# canonical template\n' > "$d/plug/references/pr-template.md"
"$RESOLVE" --profile "$d/plug/references/repo-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-layout.json"
run "$CHECK" --effective "$d/eff-layout.json" --resolve-source --profile "$d/plug/references/repo-profile.json"
expect_status "a profile that lives at <pluginRoot>/references/<name>.json resolves" 0
expect_match "to <pluginRoot>/references/<prTemplateSource>" "$d/plug/references/pr-template.md"

mkdir -p "$d/flat"
jq '.defaults.files.prTemplateSource = "references/pr-template.md"' "$EXAMPLE" > "$d/flat/repo-profile.json"
"$RESOLVE" --profile "$d/flat/repo-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-flat.json"
run "$CHECK" --effective "$d/eff-flat.json" --resolve-source --profile "$d/flat/repo-profile.json"
expect_status "a profile NOT under a references/ dir fails closed rather than guessing" 1
expect_match "naming the fix: an absolute path, or the references/ layout" "absolute path"

jq --arg abs "$d/plug/references/pr-template.md" '.defaults.files.prTemplateSource = $abs' "$EXAMPLE" > "$d/abs-profile.json"
"$RESOLVE" --profile "$d/abs-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-abs.json"
run "$CHECK" --effective "$d/eff-abs.json" --resolve-source --profile "$d/abs-profile.json"
expect_status "an absolute prTemplateSource skips derivation entirely" 0
expect_match "and is used exactly as given" "$d/plug/references/pr-template.md"

jq '.defaults.files.prTemplateSource = "references/does-not-exist.md"' "$EXAMPLE" > "$d/plug/references/missing-profile.json"
"$RESOLVE" --profile "$d/plug/references/missing-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-missingsrc.json"
run "$CHECK" --effective "$d/eff-missingsrc.json" --resolve-source --profile "$d/plug/references/missing-profile.json"
expect_status "a source that resolves to a path but the file isn't there also fails closed" 1
expect_match "naming the resolved (wrong) path" "does-not-exist.md"

jq 'del(.defaults.files.prTemplateSource)' "$EXAMPLE" > "$d/plug/references/nosrc-profile.json"
"$RESOLVE" --profile "$d/plug/references/nosrc-profile.json" --repo my-org/worker --language typescript-web > "$d/eff-nosrc.json"
run "$CHECK" --effective "$d/eff-nosrc.json" --resolve-source --profile "$d/plug/references/nosrc-profile.json"
expect_status "prTemplateSource simply absent is not an error" 0
if [ -z "$output" ]; then ok "and nothing is printed"; else bad "and nothing is printed" "$output"; fi

echo "--resolve-source — malformed prTemplateSource fails loudly rather than reading as absent"

# The bug this guards against: jq's `//` treats `false` exactly like `null`, so
# `.prTemplateSource // empty` would silently read `"prTemplateSource": false` as "not set" and
# exit 0 with nothing printed — indistinguishable from a profile that never mentioned the key.
echo '{"effective":{"files":{"prTemplateSource":false}}}' > "$d/eff-false-source.json"
run "$CHECK" --effective "$d/eff-false-source.json" --resolve-source --profile "$d/plug/references/nosrc-profile.json"
expect_status "prTemplateSource: false is rejected, not read as not-set" 1
expect_match "naming the type it actually got" "must be a string, got boolean"

echo '{"effective":{"files":{"prTemplateSource":42}}}' > "$d/eff-number-source.json"
run "$CHECK" --effective "$d/eff-number-source.json" --resolve-source --profile "$d/plug/references/nosrc-profile.json"
expect_status "a number is rejected the same way" 1
expect_match "naming its type too" "must be a string, got number"

echo '{"effective":{"files":{"prTemplateSource":""}}}' > "$d/eff-empty-source.json"
run "$CHECK" --effective "$d/eff-empty-source.json" --resolve-source --profile "$d/plug/references/nosrc-profile.json"
expect_status "an empty string is rejected — a real string, but not a usable path" 1

echo "usage errors"

run "$CHECK" --headings --template "$d/tmpl-good.md"
expect_status "--effective is required" 2

run "$CHECK" --effective "$d/eff.json" --template "$d/tmpl-good.md"
expect_status "one of --headings/--resolve-source is required" 2

run "$CHECK" --effective "$d/eff.json" --headings
expect_status "--headings needs --template" 2

run "$CHECK" --effective "$d/eff.json" --resolve-source
expect_status "--resolve-source needs --profile" 2

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
