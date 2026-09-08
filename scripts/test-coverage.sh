#!/usr/bin/env bash
#
# Tests for the coverage-ratchet shell helpers in plugins/core/scripts/.
#
# They are shell, they run unattended in every consuming repo's CI, and they are the only
# thing standing between a coverage regression and main — so the cases that matter most
# here are the ones where a bug would make the gate *pass*: a missing summary, a truncated
# file, a percentage read out of the wrong key. Every one of those must fail closed.
#
#   ./scripts/test-coverage.sh
#
# Requires: bash 3.2+, jq. No network, no fixtures on disk — each case builds its own
# tree in a temp dir, so the tests cannot pass by reading this repo's state.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPT="$ROOT/plugins/core/scripts/coverage-adapt.sh"
CHECK="$ROOT/plugins/core/scripts/coverage-check.sh"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

# Run a command in a scratch dir, capturing status and output.
# Usage: run <dir> <cmd...>   -> sets $status and $output
run() {
  local dir="$1"; shift
  output="$(cd "$dir" && "$@" 2>&1)"
  status=$?
}

scratch() { mktemp -d "${TMPDIR:-/tmp}/maintainerd-cov.XXXXXX"; }

expect_status() {
  local label="$1" want="$2" got="$3" out="$4"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "expected exit $want, got $got: $out"; fi
}

expect_match() {
  local label="$1" pattern="$2" text="$3"
  case "$text" in
    *"$pattern"*) ok "$label" ;;
    *) bad "$label" "expected to find '$pattern' in: $text" ;;
  esac
}

echo "coverage-adapt.sh"

# ── pytest-cov (coverage.py --cov-report=json) ───────────────────────────────
d="$(scratch)"
cat > "$d/coverage.json" <<'JSON'
{"meta": {"version": "7.6.1"},
 "files": {"src/a.py": {"summary": {"percent_covered": 91.5}}},
 "totals": {"covered_lines": 183, "num_statements": 200, "percent_covered": 91.5,
            "percent_covered_display": "92", "missing_lines": 17, "excluded_lines": 3}}
JSON
run "$d" "$ADAPT" --tool pytest-cov --input coverage.json
expect_status "pytest-cov: exits 0" 0 "$status" "$output"
expect_match "pytest-cov: normalizes to the contract shape" \
  '{"metric":"lines","percent":91.5}' "$(jq -c . "$d/coverage-summary.json" 2>/dev/null)"
rm -rf "$d"

# ── vitest / istanbul json-summary ───────────────────────────────────────────
d="$(scratch)"
mkdir -p "$d/coverage"
cat > "$d/coverage/coverage-summary.json" <<'JSON'
{"total": {"lines":      {"total": 400, "covered": 262, "skipped": 0, "pct": 65.5},
           "statements": {"total": 410, "covered": 268, "skipped": 0, "pct": 65.36},
           "functions":  {"total": 80,  "covered": 50,  "skipped": 0, "pct": 62.5},
           "branches":   {"total": 120, "covered": 60,  "skipped": 0, "pct": 50}},
 "src/index.ts": {"lines": {"total": 40, "covered": 30, "skipped": 0, "pct": 75}}}
JSON
run "$d" "$ADAPT" --tool istanbul --input coverage/coverage-summary.json
expect_status "istanbul: exits 0" 0 "$status" "$output"
expect_match "istanbul: takes lines.pct, not statements or branches" \
  '{"metric":"lines","percent":65.5}' "$(jq -c . "$d/coverage-summary.json" 2>/dev/null)"
rm -rf "$d"

# ── auto-detection, both shapes and its own output ───────────────────────────
d="$(scratch)"
echo '{"totals": {"percent_covered": 77.25}}' > "$d/coverage-summary.json"
run "$d" "$ADAPT"
expect_status "auto: detects pytest-cov" 0 "$status" "$output"
expect_match "auto: rewrites in place" '"percent":77.25' "$(jq -c . "$d/coverage-summary.json" 2>/dev/null)"
run "$d" "$ADAPT"
expect_status "auto: re-running on its own output is a no-op, not an error" 0 "$status" "$output"
expect_match "auto: the no-op preserves the percentage" '"percent":77.25' "$(jq -c . "$d/coverage-summary.json" 2>/dev/null)"
rm -rf "$d"

d="$(scratch)"
echo '{"total": {"lines": {"pct": 42}}}' > "$d/coverage.json"
run "$d" "$ADAPT"
expect_status "auto: detects istanbul" 0 "$status" "$output"
expect_match "auto: integer percentages stay numbers" '{"metric":"lines","percent":42}' \
  "$(jq -c . "$d/coverage-summary.json" 2>/dev/null)"
rm -rf "$d"

# ── failing closed ───────────────────────────────────────────────────────────
d="$(scratch)"
run "$d" "$ADAPT"
expect_status "no input anywhere: fails" 1 "$status" "$output"
expect_match "no input: says what to run" "commands.coverage" "$output"
rm -rf "$d"

d="$(scratch)"
printf '{"totals": {"percent_cov' > "$d/coverage.json"     # truncated mid-write
run "$d" "$ADAPT" --input coverage.json
expect_status "malformed JSON: fails" 1 "$status" "$output"
expect_match "malformed JSON: refuses to guess" "not valid JSON" "$output"
if [ -f "$d/coverage-summary.json" ]; then
  bad "malformed JSON: writes no output" "wrote a summary anyway"
else
  ok "malformed JSON: writes no output"
fi
rm -rf "$d"

d="$(scratch)"
# istanbul writes the string "Unknown" when it measured no lines at all.
echo '{"total": {"lines": {"total": 0, "covered": 0, "pct": "Unknown"}}}' > "$d/coverage.json"
run "$d" "$ADAPT" --tool istanbul --input coverage.json
expect_status "istanbul \"Unknown\": fails rather than coercing to 0" 1 "$status" "$output"
rm -rf "$d"

d="$(scratch)"
echo '{"totals": {"percent_covered": 183}}' > "$d/coverage.json"
run "$d" "$ADAPT" --tool pytest-cov --input coverage.json
expect_status "a percentage above 100: fails" 1 "$status" "$output"
rm -rf "$d"

d="$(scratch)"
echo '{"coverage": "great"}' > "$d/coverage.json"
run "$d" "$ADAPT" --input coverage.json
expect_status "an unrecognized shape: fails" 1 "$status" "$output"
expect_match "unrecognized shape: names the keys it looked for" "percent_covered" "$output"
rm -rf "$d"

d="$(scratch)"
echo '{"totals": {"percent_covered": 50}}' > "$d/coverage.json"
run "$d" "$ADAPT" --tool cobertura --input coverage.json
expect_status "an unknown --tool: usage error (2), not a coverage failure" 2 "$status" "$output"
run "$d" "$ADAPT" --input
expect_status "a flag with no value: usage error" 2 "$status" "$output"
rm -rf "$d"

echo
echo "coverage-check.sh"

# A repo tree: .claude/maintainerd.json with a floor, plus a summary.
mkrepo() {
  local dir floor percent
  dir="$(scratch)"; floor="$1"; percent="${2:-}"
  mkdir -p "$dir/.claude"
  if [ "$floor" = "none" ]; then
    printf '{"repo": "o/r"}\n' > "$dir/.claude/maintainerd.json"
  else
    printf '{"repo": "o/r", "coverage": {"floor": %s, "floorCommit": "abc1234"}}\n' "$floor" \
      > "$dir/.claude/maintainerd.json"
  fi
  [ -z "$percent" ] || printf '{"metric": "lines", "percent": %s}\n' "$percent" > "$dir/coverage-summary.json"
  printf '%s' "$dir"
}

d="$(mkrepo 80 92.4)"
run "$d" "$CHECK"
expect_status "above the floor: passes" 0 "$status" "$output"
expect_match "above the floor: reports both numbers" "92.4% (floor 80%)" "$output"
rm -rf "$d"

d="$(mkrepo 85 85)"
run "$d" "$CHECK"
expect_status "exactly at the floor: passes" 0 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 85 85.0)"
run "$d" "$CHECK"
expect_status "at the floor as a float: passes" 0 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 85 84.99)"
run "$d" "$CHECK"
expect_status "a fraction below the floor: fails" 1 "$status" "$output"
expect_match "below the floor: says the ratchet may not be lowered" "may rise, never fall" "$output"
rm -rf "$d"

d="$(mkrepo 0 0)"
run "$d" "$CHECK"
expect_status "a floor of 0 with 0% measured: passes" 0 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 80)"                                    # config, but no summary written
run "$d" "$CHECK"
expect_status "missing summary: fails closed" 1 "$status" "$output"
expect_match "missing summary: says why it failed closed" "never ran" "$output"
rm -rf "$d"

d="$(mkrepo 80)"
printf '{"metric": "lines", "perce' > "$d/coverage-summary.json"
run "$d" "$CHECK"
expect_status "malformed summary: fails closed" 1 "$status" "$output"
expect_match "malformed summary: names the file" "not valid JSON" "$output"
rm -rf "$d"

d="$(mkrepo 80)"
echo '{"totals": {"percent_covered": 91.5}}' > "$d/coverage-summary.json"
run "$d" "$CHECK"
expect_status "un-normalized summary: fails rather than reading a native shape" 1 "$status" "$output"
expect_match "un-normalized summary: points at the adapter" "coverage-adapt.sh" "$output"
rm -rf "$d"

d="$(mkrepo 80)"
echo '{"metric": "lines", "percent": "91.5"}' > "$d/coverage-summary.json"
run "$d" "$CHECK"
expect_status "a stringified percentage: fails" 1 "$status" "$output"
rm -rf "$d"

d="$(mkrepo none 91.5)"
run "$d" "$CHECK"
expect_status "no coverage.floor: fails closed" 1 "$status" "$output"
expect_match "no floor: names the adopt invocation" "/bootstrap --adopt" "$output"
rm -rf "$d"

d="$(scratch)"
printf '{"metric": "lines", "percent": 91.5}\n' > "$d/coverage-summary.json"
run "$d" "$CHECK"
expect_status "no config at all: fails closed" 1 "$status" "$output"
rm -rf "$d"

d="$(mkrepo '"eighty"' 91.5)"
run "$d" "$CHECK"
expect_status "a non-numeric floor: fails" 1 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 120 91.5)"
run "$d" "$CHECK"
expect_status "a floor above 100: fails" 1 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 80 70)"
run "$d" "$CHECK" --floor 60
expect_status "--floor overrides the config" 0 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 80 92.4)"
run "$d" env GITHUB_ACTIONS=true "$CHECK" --summary coverage-summary.json
expect_status "an explicit --summary path resolves" 0 "$status" "$output"
rm -rf "$d"

d="$(mkrepo 95 92.4)"
run "$d" env GITHUB_ACTIONS=true "$CHECK"
expect_match "on Actions, a failure is annotated" "::error::" "$output"
rm -rf "$d"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
