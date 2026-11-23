#!/usr/bin/env bash
#
# Tests for the auto-dev tick's closed-issue sweep candidate read. The read lives as a fenced bash
# block in plugins/auto-dev/skills/auto-dev/SKILL.md (marked "auto-dev closed-sweep candidate
# read"); this script extracts that exact block, fills its config placeholders, and runs it against
# a stub `gh`, so a regression in the text the tick follows fails here. It covers: search used when
# it works; a refused search (gh exits non-zero, empty stdout) reaching the repo-scoped fallback; a
# page too big to pass as one argument; opted-out issues filling a page without hiding later ones;
# and a failed page reading as FAILED, never as "no candidates".
#
#   ./scripts/test-auto-dev-closed-sweep.sh
#
# Requires: bash 3.2+, jq, awk, sed.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/plugins/auto-dev/skills/auto-dev/SKILL.md"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/auto-dev-closed-sweep.XXXXXX")"
trap 'rm -rf "$T"' EXIT

awk '/^```bash$/ {buf=""; inb=1; next} inb && /^```$/ {if (index(buf, "auto-dev closed-sweep candidate read")) {printf "%s", buf; exit} inb=0; next} inb {buf = buf $0 "\n"}' "$SKILL" \
  | sed -e 's|<config.repo>|o/r|g' \
        -e 's|<config.autoDev.stateLabels.inProgress>|auto:in-progress|g' \
        -e 's|<config.autoDev.stateLabels.skip>|auto:skip|g' \
        -e 's|<config.autoDev.excludedLabels as a JSON array>|["wontfix"]|g' \
        -e 's|<config.autoDev.closedSweepMax>|3|g' \
        -e 's|<config.autoDev.closedSweepDays>|14|g' > "$T/block.sh"
if [ -s "$T/block.sh" ] && ! grep -q '<config\.' "$T/block.sh"; then
  ok "SKILL.md carries the candidate read, every placeholder filled"
else
  bad "SKILL.md carries the candidate read, every placeholder filled"
fi

# Stub gh. SEARCH: ok | fail | garbage. A listing page N is $T/case/page-N.json, or a failure when
# $T/case/page-N.fail exists; a missing page is an empty list. Every call is logged.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/calls"
case "$*" in
  *search/issues*)
    case "$SEARCH" in
      ok) cat "$CASE/search.json" ;;
      garbage) printf '<html>blocked</html>' ;;
      *) echo 'gh: Access to this path is not permitted through this proxy. (HTTP 403)' >&2; exit 1 ;;
    esac ;;
  *repos/o/r/issues*)
    page=$(printf '%s\n' "$@" | sed -n 's/^page=//p')
    [ -e "$CASE/page-$page.fail" ] && { echo 'gh: HTTP 502' >&2; exit 1; }
    if [ -e "$CASE/page-$page.json" ]; then cat "$CASE/page-$page.json"; else echo '[]'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/gh"

# issues <first> <count> <labels-json> [body-bytes]: a JSON array of closed issues.
issues() {
  jq -cn --argjson a "$1" --argjson n "$2" --argjson l "$3" --argjson b "${4:-10}" \
    '[range($a; $a - $n; -1) | {number: ., labels: ($l | map({name: .})), body: ("x" * $b)}]'
}

run() { # name search-mode -> prints the result line
  CASE="$T/$1" SEARCH="$2" PATH="$T/bin:$PATH" bash "$T/block.sh" 2>/dev/null | tail -1
}

# 1. search works: its candidates are used and the listing is never read.
mkdir -p "$T/c1"
jq -n '{incomplete_results: false, items: [{number: 9, labels: [{name: "auto:in-progress"}]},
        {number: 8, labels: [{name: "auto:in-progress"}], pull_request: {}}]}' > "$T/c1/search.json"
out="$(run c1 ok)"
[ "$out" = "closed sweep: candidates [9] from search" ] && ok "search result used" || bad "search result used" "$out"
grep -q 'repos/o/r/issues' "$T/c1/calls" && bad "no listing when search works" || ok "no listing when search works"
grep -q -- '-label:"wontfix"' "$T/c1/calls" && ok "excluded labels go into the query" || bad "excluded labels go into the query" "$(cat "$T/c1/calls")"

# 2. a refused search (non-zero exit, empty stdout) reaches the fallback.
mkdir -p "$T/c2"; issues 20 2 '["auto:in-progress"]' > "$T/c2/page-1.json"
out="$(run c2 fail)"
[ "$out" = "closed sweep: candidates [20,19] from repo-scoped fallback (search failed)" ] \
  && ok "refused search falls back" || bad "refused search falls back" "$out"

# 3. a search answer jq cannot read also falls back.
mkdir -p "$T/c3"; cp "$T/c2/page-1.json" "$T/c3/"
out="$(run c3 garbage)"
case "$out" in *"from repo-scoped fallback"*"[20,19]"*|*"[20,19] from repo-scoped fallback"*) ok "unreadable search falls back" ;; *) bad "unreadable search falls back" "$out" ;; esac

# 4. a ~200 KB page (100 issues, 2 KB bodies) is read, not lost to the argument limit.
mkdir -p "$T/c4"; issues 500 100 '["auto:in-progress"]' 2048 > "$T/c4/page-1.json"
[ "$(wc -c < "$T/c4/page-1.json")" -gt 131072 ] && ok "fixture page exceeds 128 KiB" || bad "fixture page exceeds 128 KiB"
out="$(run c4 fail)"
[ "$out" = "closed sweep: candidates [500,499,498] from repo-scoped fallback (search failed)" ] \
  && ok "large page yields candidates" || bad "large page yields candidates" "$out"

# 5. a full page of opted-out issues does not hide eligible ones on the next page.
mkdir -p "$T/c5"
issues 300 50 '["auto:in-progress","auto:skip"]' > "$T/a.json"
issues 250 50 '["auto:in-progress","wontfix"]' > "$T/b.json"
jq -s 'add' "$T/a.json" "$T/b.json" > "$T/c5/page-1.json"
issues 200 1 '["auto:in-progress"]' > "$T/c5/page-2.json"
out="$(run c5 fail)"
[ "$out" = "closed sweep: candidates [200] from repo-scoped fallback (search failed)" ] \
  && ok "opted-out page is paged past" || bad "opted-out page is paged past" "$out"

# 6. a failed page is FAILED, even after a good page.
mkdir -p "$T/c6"; cp "$T/c5/page-1.json" "$T/c6/"; : > "$T/c6/page-2.fail"
out="$(run c6 fail)"
[ "$out" = "closed sweep: candidates FAILED from repo-scoped fallback (search failed)" ] \
  && ok "failed page reads as FAILED" || bad "failed page reads as FAILED" "$out"

# 7. the page bound: at most 5 listing reads.
mkdir -p "$T/c7"; for p in 1 2 3 4 5 6; do cp "$T/c5/page-1.json" "$T/c7/page-$p.json"; done
out="$(run c7 fail)"
n=$(grep -c 'repos/o/r/issues' "$T/c7/calls")
[ "$n" = 5 ] && [ "$out" = "closed sweep: candidates [] from repo-scoped fallback (search failed)" ] \
  && ok "fallback stops at 5 pages" || bad "fallback stops at 5 pages" "calls=$n out=$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
