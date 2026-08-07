#!/usr/bin/env bash
# Vendor maintainerd-core's shared reference docs into each plugin that links them.
#
# Why copies instead of one shared file: a plugin's skills can only reach files inside
# their own plugin. Relative links that climb out (../../../core/reference/...) resolve
# in this source tree but NOT in an installed marketplace layout, which interposes a
# version segment and uses the plugin name (maintainerd-core) rather than the source
# directory name (core):
#
#   source:     plugins/audits/skills/audit-tests/SKILL.md
#   installed:  <cache>/maintainerd/audits/0.1.0/skills/audit-tests/SKILL.md
#
# Intra-plugin links are the one form that resolves identically in both layouts, plus in
# the clone-and-read path the scheduled cloud routines use. So each consuming plugin gets
# its own copy and links to that.
#
#   ./scripts/sync-references.sh           regenerate the copies
#   ./scripts/sync-references.sh --check   verify they match the canonical (CI)

set -euo pipefail
cd "$(dirname "$0")/.."

CANON_DIR="plugins/core/references"

CONSUMERS="audits auto-dev deps-flow journal repo-ops research"

# Markdown, copied with a generated-file banner prepended.
# model-tiers.md ships wherever config-schema.md does: the schema links it as a sibling,
# so a plugin with only one of the two would carry a dead link.
DOCS=(config-schema.md model-tiers.md)

# Verbatim copies — the schema links these as siblings, and JSON cannot carry a comment banner.
ASSETS=(example-user.json example-pepper.json example-obsidian.json)

banner() {
  cat <<EOF
<!-- GENERATED COPY — DO NOT EDIT.
     Canonical source: $CANON_DIR/$1
     Vendored here because cross-plugin relative links do not resolve in an installed
     marketplace layout. Edit the canonical, then run scripts/sync-references.sh. -->

EOF
}

check=0
[[ "${1:-}" == "--check" ]] && check=1
fail=0

sync_one() {
  local file="$1" plugin="$2" with_banner="$3"
  local canon="$CANON_DIR/$file"
  local dest="plugins/$plugin/references/$file"
  [[ -f "$canon" ]] || { echo "missing canonical: $canon" >&2; exit 1; }

  local tmp; tmp="$(mktemp)"
  if [[ "$with_banner" == "yes" ]]; then
    { banner "$file"; cat "$canon"; } > "$tmp"
  else
    cat "$canon" > "$tmp"
  fi

  if (( check )); then
    cmp -s "$tmp" "$dest" 2>/dev/null || { echo "OUT OF SYNC: $dest" >&2; fail=1; }
  else
    mkdir -p "$(dirname "$dest")"
    cp "$tmp" "$dest"
    echo "wrote $dest"
  fi
  rm -f "$tmp"
}

for plugin in $CONSUMERS; do
  for file in "${DOCS[@]}";   do sync_one "$file" "$plugin" yes; done
  for file in "${ASSETS[@]}"; do sync_one "$file" "$plugin" no;  done
done

if (( check )); then
  (( fail )) && { echo "Run ./scripts/sync-references.sh to regenerate." >&2; exit 1; }
  echo "All vendored references are in sync."
fi
