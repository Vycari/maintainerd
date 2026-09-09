#!/usr/bin/env bash
#
# settings-diff.sh — diff a repo's GitHub settings against a profile's effective values,
# and print the exact `gh api` call that fixes each difference.
#
# It reads FILES, never the network. The caller (`doctor --profile` check 15, or
# `new-repo` deciding what it would change) captures the `gh api` responses first and
# hands them over. That split is the point: the same diff can be produced in a dry run, in
# a test, and in a report a human reads before pasting anything, and the script that
# computes what should change can never be the thing that changes it.
#
# Canonical source: maintainerd, plugins/core/scripts/settings-diff.sh
# The contract, and what a profile does and does not govern, is in the plugin's
# references/profile-schema.md. Not vendored into consuming repos: it runs inside a skill.
#
#   settings-diff.sh --repo my-org/app --effective eff.json \
#       --repo-settings repo.json --protection prot.json --rulesets rules.json --labels labels.json
#
# Capture the inputs with:
#   gh api "repos/my-org/app"                                        > repo.json
#   gh api "repos/my-org/app/branches/main/protection"               > prot.json   # may 404
#   gh api "repos/my-org/app/rulesets?includes_parents=true"         > rulesets-list.json
#   #   ...then each ruleset by id, since the list omits `rules`:
#   #   gh api "repos/my-org/app/rulesets/<id>" | jq -s '.' > rules.json
#   gh api "repos/my-org/app/labels" --paginate --jq '[.[].name]'    > labels.json
#
# An input that was NOT passed is reported as "couldn't verify", never as a pass. A
# read that failed because the token lacks admin is the commonest reason for a missing
# protection file, and a drift report that turns a read-only token into six fabricated
# diffs is worse than no report.
#
# Requires: bash 3.2+, jq.
#
# Exit status: 0 conformant (as far as it could see), 1 differences found, 2 usage/parse.

set -euo pipefail
export LC_ALL=C

usage() {
  cat >&2 <<'USAGE'
usage: settings-diff.sh --repo SLUG --effective FILE [inputs]

  --repo            owner/name. Required — it is what the fix calls address.
  --effective       profile-resolve.sh output, or a bare effective object. Required.
  --branch          branch to check protection on. Default: the profile's defaultBranch.
  --repo-settings   `gh api repos/{slug}` response.
  --protection      `gh api repos/{slug}/branches/{branch}/protection` response (404 body is fine).
  --rulesets        array of ruleset objects, each WITH its `rules` (fetch each by id).
  --labels          array of label names, or of label objects.

Anything not passed is reported as "couldn't verify".
USAGE
}

repo=""; eff=""; branch=""; repo_settings=""; protection=""; rulesets=""; labels=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          [ $# -ge 2 ] || { echo "settings-diff: --repo needs a value" >&2; exit 2; }; repo="$2"; shift 2 ;;
    --effective)     [ $# -ge 2 ] || { echo "settings-diff: --effective needs a value" >&2; exit 2; }; eff="$2"; shift 2 ;;
    --branch)        [ $# -ge 2 ] || { echo "settings-diff: --branch needs a value" >&2; exit 2; }; branch="$2"; shift 2 ;;
    --repo-settings) [ $# -ge 2 ] || { echo "settings-diff: --repo-settings needs a value" >&2; exit 2; }; repo_settings="$2"; shift 2 ;;
    --protection)    [ $# -ge 2 ] || { echo "settings-diff: --protection needs a value" >&2; exit 2; }; protection="$2"; shift 2 ;;
    --rulesets)      [ $# -ge 2 ] || { echo "settings-diff: --rulesets needs a value" >&2; exit 2; }; rulesets="$2"; shift 2 ;;
    --labels)        [ $# -ge 2 ] || { echo "settings-diff: --labels needs a value" >&2; exit 2; }; labels="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "settings-diff: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$repo" ] || { echo "settings-diff: --repo is required" >&2; usage; exit 2; }
[ -n "$eff" ]  || { echo "settings-diff: --effective is required" >&2; usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "settings-diff: jq is not installed" >&2; exit 2; }

read_json() {  # read_json FILE FALLBACK_JSON — a passed file must parse; absent yields the fallback
  local file="$1" fallback="$2"
  if [ -z "$file" ]; then printf '%s' "$fallback"; return; fi
  [ -f "$file" ] || { echo "settings-diff: no such file: $file" >&2; exit 2; }
  jq -e '.' "$file" >/dev/null 2>&1 || { echo "settings-diff: $file is not valid JSON" >&2; exit 2; }
  cat "$file"
}

[ -f "$eff" ] || { echo "settings-diff: no such file: $eff" >&2; exit 2; }
# Accept either shape: profile-resolve.sh's full output, or just the effective object.
effective="$(jq -c 'if has("effective") then .effective else . end' "$eff" 2>/dev/null)" \
  || { echo "settings-diff: $eff is not valid JSON" >&2; exit 2; }
[ -n "$effective" ] || { echo "settings-diff: $eff is empty" >&2; exit 2; }

[ -n "$branch" ] || branch="$(printf '%s' "$effective" | jq -r '.defaultBranch // "main"')"

j_repo="$(read_json "$repo_settings" 'null')"
j_prot="$(read_json "$protection"    'null')"
j_rules="$(read_json "$rulesets"     'null')"
j_labels="$(read_json "$labels"      'null')"

findings="$(jq -n \
  --argjson e "$effective" --arg slug "$repo" --arg branch "$branch" \
  --argjson repo "$j_repo" --argjson prot "$j_prot" --argjson rules "$j_rules" --argjson labels "$j_labels" '

  def q: @sh;

  # ── repo-level settings: a real PATCH, so each key gets its own call ────────
  def repo_findings:
    if $repo == null then
      [{ sev: "SKIP", section: "repo", msg: "repo settings not read — couldn'"'"'t verify private / merge methods / delete-branch-on-merge" }]
    else
      [ { key: "private",                 want: $e.private,                  got: $repo.private }
      , { key: "allow_squash_merge",      want: $e.merge.squash,             got: $repo.allow_squash_merge }
      , { key: "allow_merge_commit",      want: $e.merge.mergeCommit,        got: $repo.allow_merge_commit }
      , { key: "allow_rebase_merge",      want: $e.merge.rebase,             got: $repo.allow_rebase_merge }
      , { key: "delete_branch_on_merge",  want: $e.merge.deleteBranchOnMerge, got: $repo.delete_branch_on_merge }
      ]
      | map(select(.want != null))
      | map(select(.want != .got)
            | { sev: "FAIL", section: "repo",
                msg: "repos/\($slug) \(.key) is \(.got | tojson), profile wants \(.want | tojson)",
                fix: "gh api --method PATCH \"repos/\($slug)\" -F \(.key)=\(.want | tojson)" })
    end;

  # ── the required-check contexts a ruleset supplies, on top of protection ────
  def ruleset_contexts:
    if $rules == null then []
    else [ $rules[]
           | select(.enforcement == "active")
           | .rules[]? | select(.type == "required_status_checks")
           | .parameters.required_status_checks[]?.context ]
    end;

  def protection_absent: ($prot == null) or ($prot | has("message"));

  def prot_contexts:
    if protection_absent then []
    else ($prot.required_status_checks.contexts
          // ([$prot.required_status_checks.checks[]?.context])
          // []) end;

  # ── branch protection ──────────────────────────────────────────────────────
  def protection_findings:
    if $prot == null then
      [{ sev: "SKIP", section: "protection",
         msg: "branch protection on \($branch) not read — couldn'"'"'t verify. Reading it needs admin on most repos." }]
    elif ($prot | has("message")) then
      [{ sev: "FAIL", section: "protection",
         msg: "\($branch) has no branch protection at all (\($prot.message)) — every profile rule below is unmet",
         fix: "see the single PUT above" }]
    else
      ( [ { key: "required_linear_history", want: $e.protection.requiredLinearHistory, got: $prot.required_linear_history.enabled }
        , { key: "allow_force_pushes",      want: $e.protection.allowForcePushes,      got: $prot.allow_force_pushes.enabled }
        , { key: "allow_deletions",         want: $e.protection.allowDeletions,        got: $prot.allow_deletions.enabled }
        , { key: "enforce_admins",          want: $e.protection.enforceAdmins,         got: $prot.enforce_admins.enabled }
        , { key: "required_status_checks.strict", want: ($e.protection.strictRequiredChecks // false),
            got: ($prot.required_status_checks.strict // false) }
        , { key: "required_approving_review_count", want: $e.protection.requiredReviews.count,
            got: ($prot.required_pull_request_reviews.required_approving_review_count // 0) }
        , { key: "dismiss_stale_reviews", want: $e.protection.requiredReviews.dismissStale,
            got: ($prot.required_pull_request_reviews.dismiss_stale_reviews // false) }
        ]
        | map(select(.want != null))
        | map(select(.want != .got)
              | { sev: "FAIL", section: "protection",
                  msg: "\($branch) protection \(.key) is \(.got | tojson), profile wants \(.want | tojson)" }) )
      + ( (($e.requiredChecks // []) - (prot_contexts + ruleset_contexts))
          | map({ sev: "FAIL", section: "protection",
                  msg: "\($branch) does not require the check \"\(.)\"" }) )
      + ( ((prot_contexts) - ($e.requiredChecks // []))
          | map({ sev: "WARN", section: "protection",
                  msg: "\($branch) requires the check \"\(.)\", which the profile does not name. The PUT below would REMOVE it, because it replaces the whole object — add it to the profile'"'"'s requiredChecks first if it should stay." }) )
    end;

  # ── merge queue: a ruleset rule, not a protection key ──────────────────────
  def merge_queue_findings:
    if ($e.mergeQueue | not) or ($e.mergeQueue.enabled | not) then []
    elif $rules == null then
      [{ sev: "SKIP", section: "mergeQueue", msg: "rulesets not read — couldn'"'"'t verify the merge queue" }]
    else
      ( [ $rules[] | select(.enforcement == "active") | .rules[]? | select(.type == "merge_queue") ] ) as $mq
      | if ($mq | length) == 0 then
          [{ sev: "FAIL", section: "mergeQueue",
             msg: "no active ruleset carries a merge_queue rule for \($branch)",
             fix: ("gh api --method POST \"repos/\($slug)/rulesets\" --input - <<'"'"'JSON'"'"'\n"
                  + ({ name: "merge queue", target: "branch", enforcement: "active",
                       conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
                       rules: [ { type: "merge_queue",
                                  parameters: { merge_method: ($e.mergeQueue.mergeMethod // "squash" | ascii_upcase),
                                                grouping_strategy: "ALLGREEN", max_entries_to_build: 5,
                                                min_entries_to_merge: 1, max_entries_to_merge: 5,
                                                min_entries_to_merge_wait_minutes: 5,
                                                check_response_timeout_minutes: 60 } } ] } | tojson)
                  + "\nJSON") }]
        else
          ( $mq[0].parameters.merge_method // "" | ascii_upcase ) as $have
          | ( $e.mergeQueue.mergeMethod // "squash" | ascii_upcase ) as $want
          | if $have == $want then []
            else [{ sev: "FAIL", section: "mergeQueue",
                    msg: "the merge queue merges with \($have), profile wants \($want)",
                    fix: "edit the ruleset that carries the merge_queue rule: gh api --method PUT \"repos/\($slug)/rulesets/<id>\"" }]
            end
        end
    end;

  # ── labels: missing ones are drift, extra ones are the repo'"'"'s business ────
  def label_findings:
    if $labels == null then
      [{ sev: "SKIP", section: "labels", msg: "labels not read — couldn'"'"'t verify" }]
    else
      ( [ $labels[] | if type == "object" then .name else . end ] ) as $have
      | (($e.labels // []) - $have)
        | map({ sev: "FAIL", section: "labels",
                msg: "label \"\(.)\" does not exist — every skill that applies it will error",
                fix: "gh label create \(. | q) --repo \($slug)" })
    end;

  { findings: (repo_findings + protection_findings + merge_queue_findings + label_findings),
    protectionDiffers: (([ protection_findings[] | select(.section == "protection" and .sev == "FAIL") ] | length) > 0),
    protectionReadable: ($prot != null),
    protectionBody: {
      required_status_checks: { strict: ($e.protection.strictRequiredChecks // false),
                                contexts: ($e.requiredChecks // []) },
      enforce_admins: ($e.protection.enforceAdmins // false),
      required_pull_request_reviews:
        (if ($e.protection.requiredReviews.count // 0) > 0
         then { required_approving_review_count: $e.protection.requiredReviews.count,
                dismiss_stale_reviews: ($e.protection.requiredReviews.dismissStale // false) }
         else null end),
      restrictions: null,
      required_linear_history: ($e.protection.requiredLinearHistory // false),
      allow_force_pushes: ($e.protection.allowForcePushes // false),
      allow_deletions: ($e.protection.allowDeletions // false)
    } }
')"

# ── Render ───────────────────────────────────────────────────────────────────
printf 'settings-diff — %s (branch %s)\n\n' "$repo" "$branch"

printf '%s' "$findings" | jq -r '
  .findings[]
  | "\(.sev)  \(.msg)" + (if .fix then "\n      fix: \(.fix)" else "" end) + "\n"
'

# Branch protection is REPLACED by its PUT, never patched: a call carrying only the
# diverging key clears every key it omits. So one call, carrying the whole desired state,
# with the per-key differences above as its reasons.
if printf '%s' "$findings" | jq -e '.protectionDiffers and .protectionReadable' >/dev/null; then
  printf 'The one call that fixes every branch-protection difference above.\n'
  printf 'PUT replaces the whole object — sending only the diverging key would clear the rest:\n\n'
  printf '  gh api --method PUT "repos/%s/branches/%s/protection" --input - <<'"'"'JSON'"'"'\n' "$repo" "$branch"
  printf '%s' "$findings" | jq '.protectionBody' | sed 's/^/  /'
  printf '  JSON\n\n'
fi

printf '%s' "$findings" | jq -r '
  ([.findings[] | select(.sev == "FAIL")] | length) as $f
  | ([.findings[] | select(.sev == "WARN")] | length) as $w
  | ([.findings[] | select(.sev == "SKIP")] | length) as $s
  | "Summary: \($f) difference(s), \($w) warning(s), \($s) not verified."
  + "\nNot checked here: protection.requiredReviews.countsBotApproval — GitHub has no setting behind it."
'

printf '%s' "$findings" | jq -e '[.findings[] | select(.sev == "FAIL")] | length == 0' >/dev/null
