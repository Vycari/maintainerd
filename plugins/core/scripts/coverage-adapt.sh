#!/usr/bin/env bash
#
# coverage-adapt.sh — normalize a coverage tool's native JSON into the maintainerd
# coverage summary contract:
#
#     {"metric": "lines", "percent": <float>}
#
# Canonical source: maintainerd, plugins/core/scripts/coverage-adapt.sh
# A consuming repo carries a copy at .claude/maintainerd/coverage-adapt.sh so CI can run
# it without the plugin installed. Re-copy it when maintainerd-core updates.
#
#   coverage-adapt.sh                                  # auto-detect input and format, rewrite in place
#   coverage-adapt.sh --tool pytest-cov                # force the pytest-cov (coverage.py) shape
#   coverage-adapt.sh --tool istanbul --input coverage/coverage-summary.json
#   coverage-adapt.sh --output build/coverage-summary.json
#
# Line coverage only. Branch coverage is deliberately not gated: it is noisier, moves for
# reasons unrelated to test quality, and a ratchet on it ratchets on noise.
#
# Requires: bash 3.2+, jq.
#
# Exits non-zero — and writes nothing — on anything it cannot read with certainty. A
# coverage gate that guesses a number is worse than one that stops.

set -euo pipefail
# Float parsing and printing must not follow the runner's locale: a comma decimal
# separator turns 87.4 into 87 in awk, and the gate silently moves.
export LC_ALL=C

usage() {
  cat >&2 <<'USAGE'
usage: coverage-adapt.sh [--tool auto|pytest-cov|istanbul] [--input FILE] [--output FILE]

  --tool    input format. Default "auto": detect from the JSON's shape.
              pytest-cov  coverage.py / pytest-cov `--cov-report=json`  (.totals.percent_covered)
              istanbul    vitest / jest / nyc `json-summary`            (.total.lines.pct)
  --input   the tool's native JSON. Default: the first of
            coverage-summary.json, coverage.json, coverage/coverage-summary.json that exists.
  --output  where to write the normalized summary. Default: coverage-summary.json
USAGE
}

tool=auto
input=""
output="coverage-summary.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --tool)   [ $# -ge 2 ] || { echo "coverage-adapt: --tool needs a value" >&2; exit 2; }; tool="$2"; shift 2 ;;
    --input)  [ $# -ge 2 ] || { echo "coverage-adapt: --input needs a value" >&2; exit 2; }; input="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || { echo "coverage-adapt: --output needs a value" >&2; exit 2; }; output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "coverage-adapt: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$tool" in
  auto|pytest-cov|istanbul) ;;
  *) echo "coverage-adapt: unknown --tool '$tool' (auto|pytest-cov|istanbul)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "coverage-adapt: jq is not installed — the summary cannot be read" >&2; exit 2; }

if [ -z "$input" ]; then
  for candidate in coverage-summary.json coverage.json coverage/coverage-summary.json; do
    if [ -f "$candidate" ]; then input="$candidate"; break; fi
  done
fi

if [ -z "$input" ] || [ ! -f "$input" ]; then
  echo "coverage-adapt: no coverage JSON found${input:+ at $input}." >&2
  echo "  Run the repo's commands.coverage first, or pass --input." >&2
  exit 1
fi

jq -e . "$input" >/dev/null 2>&1 || {
  echo "coverage-adapt: $input is not valid JSON — refusing to guess a percentage." >&2; exit 1; }

# Each supported shape, as the jq path to its line-coverage percentage. The normalized
# shape is included so re-running the adapter on its own output is a no-op rather than an
# error: CI steps get re-run, and a step that only works once is a step that breaks.
percent=""
detected=""
try_shape() {
  local name="$1" filter="$2" value
  value="$(jq -r "$filter // empty" "$input" 2>/dev/null || true)"
  if [ -n "$value" ]; then detected="$name"; percent="$value"; return 0; fi
  return 1
}

case "$tool" in
  pytest-cov) try_shape pytest-cov 'select(.totals.percent_covered | type == "number") | .totals.percent_covered' || true ;;
  istanbul)   try_shape istanbul   'select(.total.lines.pct     | type == "number") | .total.lines.pct'             || true ;;
  auto)
    try_shape normalized 'select(.metric == "lines" and (.percent | type == "number")) | .percent' \
      || try_shape pytest-cov 'select(.totals.percent_covered | type == "number") | .totals.percent_covered' \
      || try_shape istanbul   'select(.total.lines.pct | type == "number") | .total.lines.pct' \
      || true
    ;;
esac

if [ -z "$percent" ]; then
  echo "coverage-adapt: $input has no line-coverage percentage in the ${tool} shape." >&2
  echo "  Expected .totals.percent_covered (pytest-cov) or .total.lines.pct (istanbul)," >&2
  echo "  as a number. istanbul writes \"Unknown\" when it measured no lines at all." >&2
  exit 1
fi

# 0-100 is the only range a percentage can be in. Anything else means the shape matched
# something that is not a percentage (a count, a ratio) and the gate would be nonsense.
awk -v p="$percent" 'BEGIN { exit !(p + 0 >= 0 && p + 0 <= 100) }' || {
  echo "coverage-adapt: $input yielded percent=$percent, which is not in 0-100." >&2; exit 1; }

outdir="$(dirname "$output")"
[ -d "$outdir" ] || mkdir -p "$outdir"

# The temp file is created beside the output, not in TMPDIR: mv is only atomic within one
# filesystem, and on CI runners TMPDIR is regularly on another. A reader — the gate, the
# artifact upload — must never see a half-written summary.
tmp="$(mktemp "$outdir/.coverage-summary.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Written through jq so the output is valid JSON with a real number, whatever the input's
# formatting. `-n` plus --argjson keeps the value numeric rather than a quoted string.
jq -n --argjson percent "$percent" '{metric: "lines", percent: $percent}' > "$tmp"
# mktemp creates the file 0600; the summary is uploaded as an artifact and read by the
# gate, so give it the ordinary readable mode a generated file would have.
chmod 644 "$tmp"
mv "$tmp" "$output"
trap - EXIT

echo "coverage-adapt: $input ($detected) -> $output  lines ${percent}%"
