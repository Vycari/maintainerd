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
# An input that was NOT passed is reported as "couldn't verify", never as a pass. Nor is
# a read that FAILED: GitHub answers "you may not read this" and "this branch has no
# protection" with the same JSON shape, and only its not-protected message means the
# branch is open. A drift report that turns a read-only token into six fabricated diffs
# is worse than no report.
#
# The branch-protection PUT replaces the whole object, so the body printed here is built
# from the branch AS READ with the opinions from the profile laid over it. Fixing a merge
# method must never switch off a safeguard as a side effect, and a warning above a call
# that still loses one is a warning read after the paste.
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

  # An error body and "this branch has no protection" are the same JSON shape and
  # opposite facts. Only the not-protected message GitHub returns means the branch is open; every
  # other `message` — a permissions error, a 404 on the repo, a rate limit — means the
  # read never established the current state, and inventing drift from a failed read is
  # how a report gets muted and how a blind write gets pasted.
  def prot_unreadable: ($prot != null) and ($prot | has("message"))
                       and (($prot.message | ascii_downcase | test("branch not protected")) | not);
  def prot_unprotected: ($prot != null) and ($prot | has("message"))
                        and ($prot.message | ascii_downcase | test("branch not protected"));
  def prot_present: ($prot != null) and (($prot | has("message")) | not);

  def prot_contexts:
    if prot_present | not then []
    else ($prot.required_status_checks.contexts
          // ([$prot.required_status_checks.checks[]?.context])
          // []) end;

  # Protections the profile has no opinion on are CARRIED THROUGH the replacement, not
  # dropped. The PUT replaces the whole object, so a body built from the profile alone
  # would silently switch off a safeguard the repo had — conversation resolution, a
  # locked branch, blocked creations — as a side effect of fixing a merge method.
  def preserved_protections:
    if prot_present | not then {}
    else
      ( (if ($prot | has("required_conversation_resolution"))
           then { required_conversation_resolution: $prot.required_conversation_resolution.enabled } else {} end)
      + (if ($prot | has("block_creations"))
           then { block_creations: $prot.block_creations.enabled } else {} end)
      + (if ($prot | has("lock_branch"))
           then { lock_branch: $prot.lock_branch.enabled } else {} end)
      + (if ($prot | has("allow_fork_syncing"))
           then { allow_fork_syncing: $prot.allow_fork_syncing.enabled } else {} end) )
    end;

  # GitHub returns an actor list as user/team/app OBJECTS and accepts it as logins and
  # slugs. Three keys use that shape — top-level restrictions, dismissal_restrictions and
  # bypass_pull_request_allowances — so the translation is written once. Converting them
  # is a translation, not a guess, which is why they are preserved rather than warned about.
  def actors(o): if o == null then null
                 else { users: [o.users[]?.login], teams: [o.teams[]?.slug], apps: [o.apps[]?.slug] } end;

  # The GET returns push restrictions as objects; the PUT wants logins and slugs.
  def preserved_restrictions:
    if prot_present | not then null else actors($prot.restrictions) end;

  # required_pull_request_reviews has exactly six fields, and ALL SIX are carried:
  # the four booleans/counts below, plus the two actor lists. The profile has an opinion
  # on two of them; a replacement that dropped the other four would broaden who can merge,
  # dismiss a review, or bypass one — every time an unrelated key was fixed.
  def observed_reviews:
    if (prot_present | not) or (($prot.required_pull_request_reviews | type) != "object") then {}
    else $prot.required_pull_request_reviews as $r
      | ( ( $r
            | { required_approving_review_count, dismiss_stale_reviews,
                require_code_owner_reviews, require_last_push_approval }
            | with_entries(select(.value != null)) )
        + (actors($r.dismissal_restrictions) as $d
           | if $d == null then {} else { dismissal_restrictions: $d } end)
        + (actors($r.bypass_pull_request_allowances) as $b
           | if $b == null then {} else { bypass_pull_request_allowances: $b } end) )
    end;

  def profile_reviews:
    ($e.protection.requiredReviews // {}) as $r
    | ( (if ($r | has("count")) then { required_approving_review_count: $r.count } else {} end)
      + (if ($r | has("dismissStale")) then { dismiss_stale_reviews: $r.dismissStale } else {} end) );

  # profile value, else what the branch already had, else off. Written out rather than
  # reached with `//`, because the jq alternative operator treats `false` as empty and
  # would quietly promote every disabled setting to the next fallback.
  def resolve(prof; obs): if (prof) != null then (prof) elif (obs) != null then (obs) else false end;
  def obs_enabled(k): if prot_present and (($prot[k] | type) == "object") then $prot[k].enabled else null end;

  # App-pinned required checks round-trip too: the PUT accepts
  # `required_status_checks.checks[{context, app_id}]`, not only the bare `contexts` list.
  # So a pinned check keeps its pin, and only a check the profile ADDS to a pinned branch
  # is unpinned — which is worth one warning, because it is a real widening.
  def obs_checks: if prot_present then ($prot.required_status_checks.checks // []) else [] end;
  def has_app_pins: ([obs_checks[] | select(.app_id != null)] | length) > 0;

  def unpinned_addition_findings:
    if has_app_pins | not then []
    else (($e.requiredChecks // []) - [obs_checks[] | select(.app_id != null) | .context])
         | if length == 0 then []
           else [{ sev: "WARN", section: "protection",
                   msg: "\($branch) pins its existing required checks to specific apps, but the profile adds \(join(", ")) with no pin — any app could satisfy those. Pin them in the UI afterwards if that matters." }]
           end
    end;

  # ── branch protection ──────────────────────────────────────────────────────
  def protection_findings:
    if $prot == null then
      [{ sev: "SKIP", section: "protection",
         msg: "branch protection on \($branch) not read — couldn'"'"'t verify. Reading it needs admin on most repos." }]
    elif prot_unreadable then
      [{ sev: "SKIP", section: "protection",
         msg: "the protection read on \($branch) returned an error (\($prot.message)) — couldn'"'"'t verify. That is a failed read, not an unprotected branch, so nothing is diffed against it and no replacement call is printed." }]
    elif prot_unprotected then
      [{ sev: "FAIL", section: "protection",
         msg: "\($branch) has no branch protection at all (\($prot.message)) — every profile rule is unmet",
         fix: "see the single PUT below" }]
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
      + unpinned_addition_findings
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
    # "Known" means the current state was actually established: the branch is protected
    # and we read it, or GitHub told us it is not protected. A failed read is neither, and
    # a replacement computed from one would be a guess.
    protectionKnown: (prot_present or prot_unprotected),
    protectionBody: ({
      required_status_checks:
        ( { strict: resolve($e.protection.strictRequiredChecks;
                            (if prot_present then $prot.required_status_checks.strict else null end)) }
          # `contexts` is deprecated but still required by the PUT schema, so it is sent
          # whether or not `checks` is; `checks` adds the per-context app pin on top.
          # `app_id` is an OPTIONAL integer in the request — an unpinned check omits the
          # key rather than sending the null the response shape uses.
          + { contexts: ($e.requiredChecks // []) }
          + (if has_app_pins
               then { checks: [ ($e.requiredChecks // [])[] as $c
                                | ([obs_checks[] | select(.context == $c) | .app_id] | first) as $a
                                | if $a == null then { context: $c } else { context: $c, app_id: $a } end ] }
               else {} end) ),
      enforce_admins: resolve($e.protection.enforceAdmins; obs_enabled("enforce_admins")),
      required_pull_request_reviews:
        ((observed_reviews + profile_reviews) as $r | if ($r | length) == 0 then null else $r end),
      restrictions: preserved_restrictions,
      required_linear_history: resolve($e.protection.requiredLinearHistory; obs_enabled("required_linear_history")),
      allow_force_pushes: resolve($e.protection.allowForcePushes; obs_enabled("allow_force_pushes")),
      allow_deletions: resolve($e.protection.allowDeletions; obs_enabled("allow_deletions"))
    } + preserved_protections) }
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
if printf '%s' "$findings" | jq -e '.protectionDiffers and .protectionKnown' >/dev/null; then
  printf 'The one call that fixes every branch-protection difference above.\n'
  printf 'PUT replaces the whole object — sending only the diverging key would clear the rest.\n'
  printf 'Protections the profile has no opinion on are carried through from the settings\n'
  printf 'as read, translated into the shapes the PUT accepts:\n\n'
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
