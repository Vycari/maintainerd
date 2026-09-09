#!/usr/bin/env bash
#
# profile-resolve.sh — validate a repo profile, and resolve one repo's effective settings.
#
# A repo profile is the standard a fleet of repos is held to, as one versioned JSON file.
# A repo's effective settings are `defaults`, then its language block, then its override,
# merged key by key. The rules are subtle enough — an explicit null overrides while an
# absent key inherits, requiredChecks is additive rather than replacing — that both
# `new-repo` and `doctor --profile` call this instead of re-deriving them in prose. Two
# prose copies of a merge rule are two merge rules.
#
# Canonical source: maintainerd, plugins/core/scripts/profile-resolve.sh
# The full contract is in the plugin's references/profile-schema.md. Unlike the coverage
# scripts, this one is NOT vendored into consuming repos: it runs inside a skill, where
# the plugin is installed, never in the consuming repo's CI.
#
#   profile-resolve.sh --profile p.json --validate
#   profile-resolve.sh --profile p.json --repo my-org/site --language typescript-web
#   profile-resolve.sh --profile p.json --languages          # list the known language keys
#
# Requires: bash 3.2+, jq.
#
# Exit status: 0 valid/resolved, 1 the profile or the request is bad, 2 usage.
#
# Fails closed on everything it cannot resolve with certainty — an unknown language above
# all. A repo whose language has no profile entry is exactly the repo that gets missed
# when the standard is applied, so it is an error and never a fallback to the defaults.

set -euo pipefail
export LC_ALL=C

# The profileVersion this script understands. A file claiming a higher one is refused
# rather than read as this shape: guessing at a standard applies it wrong to every repo
# at once.
KNOWN_VERSION=1

# The only keys a `languages` or `repoOverrides` block may carry. Everything else in a
# profile is fixed org-wide, and that is not a convention — it is this list.
RESOLVABLE='["requiredChecks","coverage","commands","dependabot"]'

usage() {
  cat >&2 <<'USAGE'
usage: profile-resolve.sh --profile FILE (--validate | --languages | --repo SLUG --language KEY)

  --profile   the repo profile JSON. Required.
  --validate  check the profile's shape and exit; resolve nothing.
  --languages print the profile's language keys, one per line.
  --repo      the repo, as `owner/name` or a bare name. Selects the repoOverrides entry.
  --language  the repo's language, a key in the profile's `languages`.

Prints, for a resolve: {"repo","name","language","overrideKey","effective"}.
USAGE
}

die() { printf 'profile-resolve: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

profile=""
repo=""
language=""
mode=resolve

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   [ $# -ge 2 ] || { echo "profile-resolve: --profile needs a value" >&2; exit 2; }; profile="$2"; shift 2 ;;
    --repo)      [ $# -ge 2 ] || { echo "profile-resolve: --repo needs a value" >&2; exit 2; }; repo="$2"; shift 2 ;;
    --language)  [ $# -ge 2 ] || { echo "profile-resolve: --language needs a value" >&2; exit 2; }; language="$2"; shift 2 ;;
    --validate)  mode=validate; shift ;;
    --languages) mode=languages; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "profile-resolve: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$profile" ] || { echo "profile-resolve: --profile is required" >&2; usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "profile-resolve: jq is not installed" >&2; exit 2; }
[ -f "$profile" ] || die "no such profile: $profile"
jq -e 'type == "object"' "$profile" >/dev/null 2>&1 \
  || die "$profile is not a JSON object — it may be truncated, or the wrong file."

# ── Shape ────────────────────────────────────────────────────────────────────
# One jq pass, emitting one message per problem so a broken profile is fixed in one
# round rather than one error at a time.
errors="$(jq -r --argjson known "$KNOWN_VERSION" --argjson resolvable "$RESOLVABLE" '
  def is_str_array: type == "array" and (all(.[]; type == "string"));

  def block_errors($where):
    . as $b
    | ( if type != "object" then ["\($where) is \(type), expected an object"] else [] end )
    + ( if type != "object" then [] else
          ( ($b | keys_unsorted) - $resolvable
            | map("\($where) carries \"\(.)\", which is fixed org-wide — only "
                  + ($resolvable | join(", ")) + " may vary per language or repo") )
        + ( if ($b | has("requiredChecks")) and (($b.requiredChecks | is_str_array) | not)
              then ["\($where).requiredChecks must be an array of strings"] else [] end )
        + ( if ($b | has("coverage")) and ($b.coverage != null)
              then ( if ($b.coverage | type) != "object"
                       then ["\($where).coverage must be null or an object"]
                     elif ($b.coverage.mode != "ratchet")
                       then ["\($where).coverage.mode is \($b.coverage.mode | tojson), and \"ratchet\" is the only mode"]
                     else [] end )
              else [] end )
        + ( if ($b | has("commands")) and (($b.commands | type) != "object")
              then ["\($where).commands must be an object"] else [] end )
        + ( if ($b | has("commands")) and (($b.commands | type) == "object")
              then ($b.commands | to_entries | map(select(.value != null and (.value | type) != "string")
                                                   | "\($where).commands.\(.key) must be a string or null"))
              else [] end )
        + ( if ($b | has("dependabot")) and (($b.dependabot | is_str_array) | not)
              then ["\($where).dependabot must be an array of strings"] else [] end )
        end );

  [ ( if (.profileVersion | type) != "number" or (.profileVersion | floor) != .profileVersion
        then ["profileVersion is missing or not an integer"]
      elif .profileVersion > $known
        then ["profileVersion \(.profileVersion) is newer than this maintainerd knows (\($known)) — upgrade maintainerd rather than reading it as v\($known)"]
      elif .profileVersion < 1
        then ["profileVersion must be at least 1"]
      else [] end )
  , ( if (.org | type) != "string" or (.org | length) == 0 then ["org must be a non-empty string"] else [] end )
  , ( if (.defaults | type) != "object" then ["defaults must be an object"] else [] end )
  , ( if (.languages | type) != "object" then ["languages must be an object"]
      elif (.languages | length) == 0 then ["languages is empty — nothing can resolve against this profile"]
      else [] end )
  , ( if has("repoOverrides") and ((.repoOverrides | type) != "object")
        then ["repoOverrides must be an object"] else [] end )
  , ( if (.languages | type) == "object"
        then [ .languages | to_entries[] | .key as $k | .value | block_errors("languages.\($k)") ] | add // []
        else [] end )
  , ( if (.repoOverrides? | type) == "object"
        then [ .repoOverrides | to_entries[] | .key as $k | .value | block_errors("repoOverrides.\($k)") ] | add // []
        else [] end )
  ] | add | .[]
' "$profile")"

if [ -n "$errors" ]; then
  printf 'profile-resolve: %s is not a valid repo profile:\n' "$profile" >&2
  printf '%s\n' "$errors" | sed 's/^/  - /' >&2
  exit 1
fi

# A repo reachable through two override keys (its short name and its full slug) means one
# of them is dead weight the author believes is live. Not fatal — the precedence is
# defined — but always worth saying.
dupes="$(jq -r '
  (.repoOverrides // {}) | keys_unsorted
  | map({ key: ., short: (. | split("/") | last) })
  | group_by(.short) | map(select(length > 1)) | .[]
  | "two repoOverrides keys resolve to the same repo: " + (map(.key) | join(", ")) + " — the full slug wins"
' "$profile")"
[ -z "$dupes" ] || printf '%s\n' "$dupes" | sed 's/^/profile-resolve: warning: /' >&2

case "$mode" in
  validate)
    printf 'profile-resolve: %s is a valid repo profile (v%s, %s languages)\n' \
      "$profile" "$(jq -r '.profileVersion' "$profile")" "$(jq -r '.languages | length' "$profile")"
    exit 0 ;;
  languages)
    jq -r '.languages | keys_unsorted[]' "$profile"
    exit 0 ;;
esac

# ── Resolve ──────────────────────────────────────────────────────────────────
[ -n "$repo" ]     || { echo "profile-resolve: --repo is required to resolve" >&2; usage; exit 2; }
[ -n "$language" ] || { echo "profile-resolve: --language is required to resolve" >&2; usage; exit 2; }

jq -e --arg l "$language" '.languages | has($l)' "$profile" >/dev/null 2>&1 || die \
  "language \"$language\" has no entry in $profile." \
  "Known languages: $(jq -r '.languages | keys_unsorted | join(", ")' "$profile")" \
  "A repo whose language the profile doesn't name is an error, not a silent skip — it is" \
  "the repo that gets missed when the standard is applied. Add the language, or fix the repo's."

jq --arg repo "$repo" --arg lang "$language" '
  ($repo | split("/") | last) as $name
  | (.repoOverrides // {}) as $ov
  # An exact match on what the caller passed wins; a full slug therefore beats the short
  # name whenever a profile carries both keys.
  | (if ($ov | has($repo)) then $repo
     elif ($ov | has($name)) then $name
     else null end) as $key
  | .defaults as $d
  | .languages[$lang] as $l
  | (if $key == null then {} else $ov[$key] end) as $o
  # `*` is jq'\''s recursive object merge: objects merge key by key at every depth, arrays
  # and scalars are replaced by the right-hand side, and an explicit null on the right
  # wins over whatever the left held. That is rules 1-3 of the contract, exactly.
  | ($d * $l * $o) as $merged
  # requiredChecks is the one additive key: language order first, then override entries
  # not already present. There is deliberately no way to subtract one.
  | ( [ ($d.requiredChecks // [])[], ($l.requiredChecks // [])[], ($o.requiredChecks // [])[] ]
      | reduce .[] as $c ([]; if index([$c]) != null then . else . + [$c] end) ) as $checks
  | ($merged + { requiredChecks: $checks }) as $merged
  # A coverage exemption is the absence of a gate, not a floor of zero: when coverage
  # resolves to null the coverage command is ignored wherever it came from, so it is
  # nulled here rather than left for each consumer to remember.
  | (if $merged.coverage == null and (($merged.commands? | type) == "object")
       then $merged | .commands.coverage = null
       else $merged end) as $merged
  | { repo: $repo, name: $name, language: $lang, overrideKey: $key, effective: $merged }
' "$profile"
