#!/usr/bin/env bash
#
# pr-template-check.sh — check a PR template against a repo profile's `files.prTemplateHeadings`,
# and resolve `files.prTemplateSource` to the file `bootstrap` should copy.
#
# Both `doctor --profile` check 14 and `bootstrap` step 7 need these from the same
# `effective.files` object; this is the one place that does it, rather than two prose copies
# of the same shell logic drifting apart. That is not hypothetical here: the first version of
# this check was an inline `for h in $(jq ...)` in doctor's SKILL.md, which silently split
# "## Human overview" into three separate words before the first `grep` ever ran. Quoting that
# loop correctly is easy to get right once and easy to get wrong every time it is retyped.
#
# Canonical source: maintainerd, plugins/core/scripts/pr-template-check.sh
# Like profile-resolve.sh and settings-diff.sh (and unlike the coverage scripts), this runs
# inside a skill where the plugin is installed — it is not vendored into consuming repos.
#
#   pr-template-check.sh --effective FILE --headings --template FILE
#     Prints every prTemplateHeadings entry missing from FILE, one per line as "missing: <heading>".
#     A heading is present only as an exact line (`grep -qxF`) — no markdown parsing.
#     Exit 0: nothing missing, or the profile has no opinion (prTemplateHeadings absent/null).
#     Exit 1: at least one heading is missing (or the template file itself doesn't exist), OR
#     prTemplateHeadings is present but not an array of non-empty strings — printed as
#     "invalid: ..." rather than silently treated as no headings to check. `profile-resolve.sh
#     --validate` already rejects this shape at the profile; this is the same guard for an
#     `effective` object built by hand (a test fixture, a caller that skipped validation).
#
#   pr-template-check.sh --effective FILE --resolve-source --profile FILE
#     Prints the resolved, existing path of effective.files.prTemplateSource on stdout and exits 0.
#     Exit 0, no output: prTemplateSource is absent (JSON null) from `effective` — nothing to
#     resolve, not an error.
#     Exit 1: prTemplateSource is set but can't be resolved, or resolves to a path that doesn't
#     exist, or isn't a string at all (e.g. `false`) — the reason is on stderr. jq's `//` treats
#     `false` the same as absent, so this checks the JSON type explicitly rather than writing
#     `.prTemplateSource // empty`, which would silently read a malformed `false` as "not set".
#
# Requires: bash 3.2+, jq. No other dependency (no realpath, which isn't guaranteed present).
#
# Resolving prTemplateSource: an absolute path (leading `/`) is used exactly as given — no
# derivation needed, and this is the escape hatch for any profile that doesn't follow the layout
# below. A relative path is resolved against "the profile's own plugin root", but that phrase
# only has one meaning when the profile file itself lives at `<pluginRoot>/references/<name>.json`
# — the layout every current caller already uses (a plugin's own skill passing `--profile <path>`,
# or `${CLAUDE_PLUGIN_ROOT}/references/<name>.json`). Rather than assume that layout, this script
# checks it: if the profile's parent directory is not literally named `references`, there is no
# "two levels up" to resolve against, and deriving one anyway would silently point at whatever
# happens to be there. That case fails closed with the fix (give an absolute path instead), rather
# than guessing at a directory structure nothing in the profile schema guarantees.

set -euo pipefail
export LC_ALL=C

usage() {
  cat >&2 <<'USAGE'
usage:
  pr-template-check.sh --effective FILE --headings --template FILE
  pr-template-check.sh --effective FILE --resolve-source --profile FILE

  --effective        profile-resolve.sh's output (the {"effective": {...}} object). Required.
  --headings         check effective.files.prTemplateHeadings against --template.
  --template         the repo's PR template file. Required with --headings.
  --resolve-source   resolve and print effective.files.prTemplateSource.
  --profile          the path originally passed to `--profile`. Required with --resolve-source.
USAGE
}

effective=""
mode=""
template=""
profile=""

while [ $# -gt 0 ]; do
  case "$1" in
    --effective)      [ $# -ge 2 ] || { echo "pr-template-check: --effective needs a value" >&2; exit 2; }; effective="$2"; shift 2 ;;
    --headings)       mode="headings"; shift ;;
    --resolve-source) mode="resolve-source"; shift ;;
    --template)       [ $# -ge 2 ] || { echo "pr-template-check: --template needs a value" >&2; exit 2; }; template="$2"; shift 2 ;;
    --profile)        [ $# -ge 2 ] || { echo "pr-template-check: --profile needs a value" >&2; exit 2; }; profile="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "pr-template-check: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$effective" ] || { echo "pr-template-check: --effective is required" >&2; usage; exit 2; }
[ -f "$effective" ] || { echo "pr-template-check: no such file: $effective" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "pr-template-check: jq is not installed" >&2; exit 2; }

case "$mode" in
  headings)
    [ -n "$template" ] || { echo "pr-template-check: --template is required with --headings" >&2; usage; exit 2; }
    # Check the JSON shape before iterating, not by consequence of iterating. `[]?` on a
    # non-array value (a string, `false`) suppresses jq's error and yields zero elements — the
    # same value as a genuinely empty or absent list — so a malformed profile would otherwise
    # check nothing and this mode would exit 0 as if every heading were present.
    heading_shape="$(jq -r '
      .effective.files.prTemplateHeadings as $h
      | if $h == null then "absent"
        elif ($h | type) != "array" then "not-array:" + ($h | type)
        elif ($h | any(type != "string" or length == 0)) then "bad-element"
        else "ok" end
    ' "$effective")"
    case "$heading_shape" in
      absent) exit 0 ;;
      not-array:*)
        echo "invalid: files.prTemplateHeadings must be an array of strings, got ${heading_shape#not-array:}"
        exit 1 ;;
      bad-element)
        echo "invalid: files.prTemplateHeadings must be an array of non-empty strings"
        exit 1 ;;
    esac
    missing=0
    # A `while read` loop over process substitution, not `for h in $(...)` — the latter splits
    # each heading on IFS before the loop body ever sees it, turning "## Human overview" into
    # three separate (and separately meaningless) grep targets.
    while IFS= read -r heading; do
      [ -n "$heading" ] || continue
      if [ ! -f "$template" ] || ! grep -qxF "$heading" "$template"; then
        printf 'missing: %s\n' "$heading"
        missing=1
      fi
    done < <(jq -r '.effective.files.prTemplateHeadings[]' "$effective")
    exit "$missing"
    ;;
  resolve-source)
    [ -n "$profile" ] || { echo "pr-template-check: --profile is required with --resolve-source" >&2; usage; exit 2; }
    [ -f "$profile" ] || { echo "pr-template-check: no such profile: $profile" >&2; exit 1; }
    # Type-checked explicitly, not `.prTemplateSource // empty` — `//` substitutes on `false`
    # exactly as it does on `null`, so a profile with `"prTemplateSource": false` would silently
    # read as "not set" instead of as the malformed value it is.
    source_type="$(jq -r '.effective.files.prTemplateSource | type' "$effective")"
    case "$source_type" in
      "null") exit 0 ;;
      string) : ;;
      *)
        echo "pr-template-check: files.prTemplateSource must be a string, got $source_type" >&2
        exit 1 ;;
    esac
    source_rel="$(jq -r '.effective.files.prTemplateSource' "$effective")"
    if [ -z "$source_rel" ]; then
      echo "pr-template-check: files.prTemplateSource is an empty string" >&2
      exit 1
    fi
    case "$source_rel" in
      /*)
        resolved="$source_rel"
        ;;
      *)
        parent_dir="$(cd "$(dirname "$profile")" && pwd)"
        parent_name="$(basename "$parent_dir")"
        if [ "$parent_name" != "references" ]; then
          {
            echo "pr-template-check: can't resolve prTemplateSource \"$source_rel\" — the profile at"
            echo "  $profile"
            echo "  doesn't live in a directory named 'references', so there is no plugin root two"
            echo "  levels up to resolve it against. Give prTemplateSource as an absolute path, or"
            echo "  move the profile to <pluginRoot>/references/<name>.json."
          } >&2
          exit 1
        fi
        plugin_root="$(dirname "$parent_dir")"
        resolved="$plugin_root/$source_rel"
        ;;
    esac
    if [ ! -f "$resolved" ]; then
      echo "pr-template-check: prTemplateSource resolved to $resolved, which doesn't exist" >&2
      exit 1
    fi
    printf '%s\n' "$resolved"
    ;;
  *)
    echo "pr-template-check: pass --headings or --resolve-source" >&2
    usage
    exit 2
    ;;
esac
