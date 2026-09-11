# The repo profile contract: one standard, many repos

`.claude/maintainerd.json` describes **one repo**. A **repo profile** describes **the standard every
repo in a fleet is held to** — the merge methods, the branch protection, the labels, the CI shape,
the coverage policy — as one versioned JSON file, so that "our repos are all set up the same way" is
a file rather than a habit.

It is an **argument, never a location**. Maintainerd ships no profile and knows no org: `new-repo`
and `doctor --profile` are handed a path, and everything they apply comes out of it. A fleet keeps
its profile wherever it keeps its own tooling; a [workspace](config-schema.md#workspace-scope-the-workspace-block)
points at it with `workspace.profile`.

Two skills read it, and they split cleanly along the line that matters:

| Skill | What it does with the profile |
| --- | --- |
| [`new-repo`](../skills/new-repo/SKILL.md) | **Applies** it: scaffolds the files, creates the labels, and — interactively, with a human's own token — applies the GitHub settings. |
| [`doctor --profile`](../skills/doctor/SKILL.md) | **Compares** against it: checks 14, 15 and 16. Report-only, forever. It prints the `gh api` call that would fix each difference and never runs one. |

That asymmetry is deliberate and permanent. Branch protection, merge methods and merge queues are
org configuration with the blast radius of a production write, so the write half of the standard
belongs to a person at a keyboard. See **Who applies what** below.

---

## The shape

```jsonc
{
  "profileVersion": 1,             // shape of this file; readers refuse a major they don't know
  "org": "my-org",                 // GitHub org or user the standard covers — informational

  // Fixed org-wide. These keys appear ONLY here: a standard that lets one repo be public,
  // or skip reviews, is not a standard.
  "defaults": {
    "private": true,
    "defaultBranch": "main",
    "merge": { "squash": true, "mergeCommit": false, "rebase": false, "deleteBranchOnMerge": true },
    "mergeQueue": { "enabled": true, "mergeMethod": "squash" },
    "protection": {
      "requiredLinearHistory": true,
      "allowForcePushes": false,
      "allowDeletions": false,
      "strictRequiredChecks": false,          // optional; see "Fields"
      "requiredReviews": { "count": 1, "countsBotApproval": true, "dismissStale": true },
      "enforceAdmins": false
    },
    "labels": ["architecture", "test-quality", "security", "dependencies", "automated"],
    "review": { "bots": ["some-reviewer[bot]"], "approvalThreshold": "approved" },
    "requireIssueForDeferredWork": true,
    "files": { "prTemplate": true, "codeowners": "* @a-maintainer", "greptileRules": true },
    "claudeSettings": {                        // optional; without it, check 14 can't judge settings.json
      "marketplaces": ["my-org/maintainerd"],
      "plugins": ["maintainerd-core@maintainerd", "repo-ops@maintainerd"]
    }
  },

  // Per language. ONLY the four resolvable keys may appear here.
  "languages": {
    "python-service": {
      "requiredChecks": ["ci", "docs"],
      "coverage": { "mode": "ratchet", "target": 70 },
      "commands": {
        "format": "uv run ruff format --check",
        "lint": "uv run ruff check",
        "typecheck": "uv run ty check {source}",
        "test": "uv run pytest",
        "coverage": "uv run pytest --cov --cov-report=json:coverage-summary.json"
      },
      "dependabot": ["pip", "github-actions", "docker"]
    },
    "shell": {
      "requiredChecks": ["ci"],
      "coverage": null,                        // explicit null: a complete exemption
      "commands": { "format": null, "lint": "shellcheck -x $(git ls-files '*.sh')",
                    "typecheck": null, "test": null, "coverage": null },
      "dependabot": ["github-actions", "docker"]
    },
    "none": {                                  // tracked but not built here
      "requiredChecks": [], "coverage": null, "commands": {}, "dependabot": ["github-actions"]
    }
  },

  // Per repo. The pressure-relief valve. Same four keys, same rules.
  "repoOverrides": {
    "app":  { "requiredChecks": ["migration-collision"] },   // ADDED to the language's list
    "site": { "coverage": null,
              "commands": { "test": "npm run build && npm run linkcheck", "coverage": null } }
  }
}
```

A complete, resolvable example ships alongside this file as
[`example-profile.json`](example-profile.json). It is the fixture the resolution tests run against,
so it is a working profile rather than an illustration.

---

## Resolution: the effective values for one repo

**A repo's effective settings are `defaults`, then its language block, then its override — merged
key by key.** Everything `new-repo` scaffolds and everything `doctor --profile` compares against is
read from that one merged object, never from a layer directly. `profile-resolve.sh` computes it, and
the skills call the script rather than re-implementing the merge in prose.

```bash
plugins/core/scripts/profile-resolve.sh --profile repo-profile.json --repo my-org/site --language typescript-web
```

### The four resolvable keys

Exactly four keys may vary between repos:

| Key | Why it varies |
| --- | --- |
| `requiredChecks` | A repo carries checks nobody else does (a migration-collision guard, an invariants suite). |
| `coverage` | Some repos have nothing under test. |
| `commands` | Format/lint/typecheck/test/coverage are language-shaped. |
| `dependabot` | Ecosystems differ per repo. |

**A `languages` or `repoOverrides` block containing any other key is an error, not a warning.** That
is how "fixed org-wide" is mechanized: if `private` were settable per repo, the profile would
document a standard nobody is held to. `profile-resolve.sh` fails on it, naming the key and the
block it appeared in.

`defaults` may also carry the four resolvable keys, as the base layer for every language. Most
profiles don't need to; the layer exists so the merge has one rule rather than two.

### The rules, in order

1. **Objects merge key by key, at every depth.** `commands` in an override replaces only the
   sub-keys it names — `{"commands": {"test": "npm run build"}}` leaves `lint` and `format` as the
   language block set them. So does `protection.requiredReviews`.
2. **Arrays and scalars replace wholesale.** `dependabot` and `labels` are values, not merge
   targets: an override's `["npm"]` is the whole list, not an addition. The single exception is
   `requiredChecks`, below.
3. **`null` is a value; absent is not.** An explicit `"coverage": null` in a layer **overrides** the
   layer beneath it and means *exempt*. A `coverage` key simply **missing** from that layer inherits
   whatever the layer beneath it said. This distinction is the whole reason the site repo above can
   be exempt while every other TypeScript repo ratchets, so a resolver that treats missing and null
   alike is wrong in the one case anybody wrote an override for.
4. **`requiredChecks` is additive, and deduplicated.** The effective list is the language's checks
   followed by any override entries not already in it, in that order. `["ci","docs"]` plus an
   override of `["ci","migration-collision"]` is `["ci","docs","migration-collision"]`.
   **There is no way to remove a check with an override**, by design: a standard whose required
   checks can be subtracted per repo is a suggestion. A repo that genuinely shouldn't run a check
   belongs in a different language block, and a `languages` table growing a one-repo entry is the
   honest version of that request.
5. **An unknown language is an error.** A repo whose `language` has no entry in `languages` is a
   hard failure in both skills, naming the value and listing the keys that do exist. Never a silent
   skip and never a fallback to `defaults`: the repo with no profile entry is exactly the repo that
   gets missed when the standard is applied.
6. **Override keys are matched by repo short name, then by full slug.** `repoOverrides` is keyed by
   the repo name — the part of an `owner/name` slug after the `/` — which is also what
   `workspace.repos[].name` holds. A key written as a full `owner/name` slug is also honored and
   **wins** over a short-name key when a profile carries both. Two keys resolving to the same repo
   is a warning worth printing, since one of them is dead weight the author thinks is live.

### Worked example

For `site` (`typescript-web`) in the profile above:

| Effective key | Value | From |
| --- | --- | --- |
| `private` | `true` | `defaults` |
| `requiredChecks` | `["ci"]` | language (override adds nothing) |
| `coverage` | `null` | override's explicit `null` beats the language's ratchet |
| `commands.lint` | `npm run lint` | language (override didn't name it) |
| `commands.test` | `npm run build && npm run linkcheck` | override |
| `commands.coverage` | `null` | override — and it would be ignored anyway, since `coverage` is `null` |
| `dependabot` | `["npm", "github-actions"]` | language |

**When `coverage` resolves to `null`, `commands.coverage` is ignored** wherever it came from: the
scaffolded CI workflow omits the coverage step and the gate entirely, `bootstrap` writes no
`coverage.floor`, and `doctor`'s check 13 reports the repo exempt. An exemption is the absence of a
gate, not a floor of zero.

---

## Required checks must have a producer

A required status check that nothing produces blocks every merge in the repo forever, and it looks
identical to a correctly configured one until the first PR sits there. So **both** skills verify,
before a check name is written into branch protection or reported as conformant, that something
produces it:

```bash
# a job in a workflow on the default branch...
git show "origin/<defaultBranch>:.github/workflows/<file>.yml"
# ...or a check run that actually appeared on the default branch's latest commit
gh api "repos/<slug>/commits/<defaultBranch>/check-runs" --paginate --jq '.check_runs[].name'
```

The name to match is **the check run's name, which is per job and not per workflow**: a job's `name:`
if it has one, else its key under `jobs:`. A matrix job appears once per combination as
`<name> (<values>)`, and a job reached through a reusable workflow (`uses:`) reports under the
*calling* job's name. A workflow file named `ci.yml` produces no check called `ci` unless a job in it
is called that.

- No matching job **and** no matching check run → **error** in `doctor` (check 16), and `new-repo`
  refuses to write that name into protection.
- A match found only in the check-run list (a matrix combination, an external app like a coverage
  service) → fine, and reported as such, since the workflow scan alone can't see it.
- The check-run list is empty because the default branch has no run yet — a repo `new-repo` just
  created — → **couldn't verify**, not an error. Say so; don't call an empty repo conformant either.

### One scaffolded job, and every other check is the repo's

`new-repo` scaffolds **one** workflow with **one** job, keyed `ci`, running `commands.format`,
`lint`, `typecheck`, `test` and — when `coverage` is non-null — the four coverage-ratchet steps. That
is the only job the profile can honestly produce: `commands` describes exactly one pipeline, so
scaffolding a second job named after a second required check would mean inventing what it runs, and a
required check whose job does nothing is worse than one that doesn't exist.

So an effective check that isn't `ci` — `docs`, an invariants suite, a migration guard — names a
workflow **the repo already carries**. Adding it to a language's `requiredChecks` is a statement that
every repo of that language has that workflow; until one does, this section is what stops the name
from reaching branch protection. If a fleet finds itself wanting a second scaffolded job for every
repo, that is a request for a profile key that doesn't exist yet, not a reason to loosen this.

---

## Fields

### Top level

| Key | Required | Meaning |
| --- | --- | --- |
| `profileVersion` | yes | Integer. The shape of this file. A reader that sees a version above the one it knows **refuses** rather than guessing. Currently `1`. |
| `org` | yes | GitHub org or user. Informational for maintainerd — every repo is addressed by full slug — but it is what a fleet tool uses to build calls the profile doesn't spell out. |
| `defaults` | yes | The fixed, org-wide half of the standard. |
| `languages` | yes | Non-empty object; each value carries only the four resolvable keys. |
| `repoOverrides` | no | Defaults to `{}`. Same restriction as `languages`. |

### `defaults`

| Key | Type | Meaning and where it lands |
| --- | --- | --- |
| `private` | bool | `PATCH repos/{slug}` `private`. |
| `defaultBranch` | string | The branch protection is applied to, and what `bootstrap` writes as `defaultBranch`. |
| `merge.squash` / `.mergeCommit` / `.rebase` | bool | `allow_squash_merge` / `allow_merge_commit` / `allow_rebase_merge`. |
| `merge.deleteBranchOnMerge` | bool | `delete_branch_on_merge`. |
| `mergeQueue.enabled` | bool | A **ruleset** rule, not a branch-protection key — see **Merge queue lives in a ruleset**. |
| `mergeQueue.mergeMethod` | `SQUASH`\|`MERGE`\|`REBASE`, case-insensitive | The queue's merge method. |
| `protection.requiredLinearHistory` | bool | `required_linear_history`. |
| `protection.allowForcePushes` | bool | `allow_force_pushes`. |
| `protection.allowDeletions` | bool | `allow_deletions`. |
| `protection.strictRequiredChecks` | bool, optional, default `false` | `required_status_checks.strict` — "branches must be up to date before merging". Default `false` on purpose: with a merge queue enabled, `strict` is both redundant and a good way to make a busy repo unmergeable. |
| `protection.requiredReviews.count` | int ≥ 0 | `required_approving_review_count`. `0` means reviews aren't required. |
| `protection.requiredReviews.dismissStale` | bool | `dismiss_stale_reviews`. |
| `protection.requiredReviews.countsBotApproval` | bool | **No GitHub counterpart** — see **What the profile does not govern**. |
| `protection.enforceAdmins` | bool | `enforce_admins`. |
| `labels` | array of strings | Labels that must exist. Missing ones are a finding; **extra ones are not** — a repo's own labels are its business. |
| `review` | object | Passed through to the repo config's `review` block by `bootstrap` (`bots`, `approvalThreshold`, `responderTier`, `impasseRounds`, `sameFileRoundCap` — the schema for them is in [`config-schema.md`](config-schema.md)). Not a GitHub setting. |
| `requireIssueForDeferredWork` | bool | Passed through to `createPr.requireIssueForDeferredWork`. Not a GitHub setting. |
| `files.prTemplate` | bool | `.github/PULL_REQUEST_TEMPLATE.md` must exist. Existence only. |
| `files.greptileRules` | bool | `.greptile/rules.md` must exist. Existence only. |
| `files.claudeMd` | bool, optional | `CLAUDE.md` must exist. Existence only. |
| `files.codeowners` | string \| `null` | `.github/CODEOWNERS` must exist **and contain this line**. The one file whose content the profile owns, because an ownership rule that varies per repo isn't one. |
| `files.prTemplateHeadings` | array of strings, optional | Headings the PR template must carry, checked as exact lines (e.g. `"## Human overview"`) — no markdown parsing. `doctor --profile` checks 14 runs `grep -qxF` per heading against `files.prTemplate`'s path and names whichever ones are missing. Absent → today's existence-only check, unchanged. See **The one content check** below. |
| `files.prTemplateSource` | string, optional | Path to the canonical PR template, resolved against **the profile's own plugin root** — see **Resolving `prTemplateSource`** below. `bootstrap` copies this file verbatim when scaffolding a PR template, instead of its built-in minimal one, whenever it resolves. Named in `doctor`'s fix hint for a missing heading, since the fix is a copy, not free text. |
| `claudeSettings.marketplaces` | array of strings, optional | Marketplaces `.claude/settings.json` must declare. |
| `claudeSettings.plugins` | array of strings, optional | Plugins it must enable, as `<plugin>@<marketplace>`. |

**Existence-only, and why.** For every file but `CODEOWNERS`, the profile says *that* it exists, not
what is in it. A PR template and a review-rules file are prose the repo's maintainer writes; a
profile that pinned their text would make every repo's improvement a profile edit, and `doctor` would
report a better template as drift. `new-repo` scaffolds a starting version; the repo owns it after
that.

**The one content check** (`files.prTemplateHeadings`). A fleet can standardize the *shape* of a PR
template — e.g. one section for a human reviewer and a denser one for an AI reviewer — while leaving
its prose to each repo, the same way `files.codeowners` standardizes one line without pinning the
rest of `CODEOWNERS`. `prTemplateHeadings` is how: a list of headings, matched as exact lines against
the template `files.prTemplate` already requires exists. It is deliberately not markdown-aware —
`grep -qxF`, not a parser — because a heading is either on its own line verbatim or it isn't, and
that is all the check promises. Neither key names what the headings mean; maintainerd learns that a
list of required lines exists, never what a fleet decided to put in them.

**Resolving `prTemplateSource`**. A repo profile always lives at `<pluginRoot>/references/<name>.json`
— that's what a plugin's own skills pass as `--profile <path>`, and it's how `${CLAUDE_PLUGIN_ROOT}`
resolves it too. `prTemplateSource` is a path relative to that same `<pluginRoot>`, so
`"references/pr-template.md"` in a profile loaded from `plugins/my-ops/references/repo-profile.json`
resolves to `plugins/my-ops/references/pr-template.md` — two directories up from the profile file,
then back down through the given path. This is what lets the canonical template resolve in a
standalone clone that only has the profile-owning plugin installed, not only in an umbrella checkout
that happens to have every repo cloned side by side. A source path that doesn't resolve (the profile
names a file that doesn't exist) is reported, never silently swallowed — `bootstrap` falls through to
its built-in template and says why; `doctor` reports it as its own finding, since a `prTemplateSource`
nothing can copy is exactly as broken as a missing heading.

### `claudeSettings` is optional, and its absence is reported

A profile with no `claudeSettings` block gets no verdict on `.claude/settings.json` from check 14 —
it reports "not specified by the profile" rather than inventing an expected plugin set. Maintainerd
has no way to know which plugins a fleet installs, and a check that guesses would flag every repo.

---

## Merge queue lives in a ruleset

The classic branch-protection API (`repos/{slug}/branches/{branch}/protection`) has no merge-queue
key. Merge queues are configured as a **ruleset rule** (`"type": "merge_queue"`) or from the UI, so:

- **Reading:** `gh api "repos/{slug}/rulesets?includes_parents=true"`, then each ruleset by id, and
  look for an active `merge_queue` rule whose ruleset targets the default branch. An org-level parent
  ruleset can supply it, which is why `includes_parents=true` is not optional.
- **Reporting:** `mergeQueue.enabled: true` with no such rule is a finding whose fix is a ruleset
  `POST`, not a protection `PUT`.
- **Reading it can require admin.** When the rulesets read fails with a permissions error, that is
  **couldn't verify**, not a finding. A drift report that turns "your token is read-only" into six
  fabricated diffs is worse than no report.

The same caveat applies to required status checks: a ruleset can require checks that classic
protection doesn't list. Check 15 reads both and treats a requirement from either as satisfied.

---

## Branch protection is replaced, never patched

`PUT /repos/{slug}/branches/{branch}/protection` **replaces the whole object**. Every key absent from
the body is cleared, so a call that "fixes" one diverging key by sending only that key silently
switches off everything else the branch had.

So when check 15 finds *any* protection difference, the fix it prints is **one call carrying the
complete desired protection**, not one call per difference:

```bash
gh api --method PUT "repos/my-org/app/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["ci", "docs"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": true },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

The per-key differences are still listed individually — that is what a human reads — but they are
listed as *reasons for the one call*, with the current value beside the wanted one. Repo-level
settings (`PATCH repos/{slug}`) genuinely are a patch, so those are printed per key.

**The body is built from the branch as it is, with the profile's opinions laid over it.** The
profile governs seven keys; branch protection has more. Every key the profile does *not* name — a
locked branch, blocked creations, required conversation resolution, fork syncing, push restrictions,
code-owner review, last-push approval — keeps the value the branch already had, so that fixing a
merge method never quietly switches off a safeguard.

Three consequences worth stating, because each is a case where the obvious implementation is wrong:

- **A profile that is silent about a key has not asked for it to be off.** Silence inherits; only an
  explicit value in the profile changes anything. (Written out rather than reached with jq's `//`,
  which treats `false` as empty and would promote every disabled setting to the fallback.)
- **`requiredReviews.count: 0` is a statement about approvals, not about the object they live in.**
  Code-owner review, last-push approval and the bypass allowances share
  `required_pull_request_reviews` with the approval count, and a body that nulls the whole object to
  express "no approvals required" switches those off too.
- **The values whose GET shape differs from their PUT shape are translated, not dropped.** Three
  keys are actor lists — push restrictions, dismissal restrictions and review bypass allowances —
  and all three come back as user/team/app objects and go out as logins and slugs. That covers
  `required_pull_request_reviews` completely: all six of its fields are carried, the two the profile
  has an opinion on and the four it does not. App-pinned required checks come back as `checks[{context, app_id}]`, a shape the PUT
  accepts alongside the deprecated-but-still-required `contexts` list, so both are sent and each pin
  is carried across — an unpinned check omitting `app_id` entirely, since the request schema takes an
  optional integer there and `null` is the response's spelling. A warning printed above a call that
  still loses the thing is a warning read after the paste.

The one widening nothing can avoid is a check the **profile adds** to a branch whose existing checks
are app-pinned: there is no pin to carry across, so any app could satisfy it. That is one warning
naming the added checks, and it is the only protection warning left.

**And a failed read is not an unprotected branch.** GitHub answers both with a JSON object carrying
`message`, and only its not-protected message means the branch is open. A permissions error, a 404
on the repo, a rate limit — each of those means the current state was never established, so the diff
reports `couldn't verify` and prints **no** replacement call. A PUT computed from a read that failed
is a guess with the blast radius of a write.

---

## What the profile does not govern

- **`protection.requiredReviews.countsBotApproval` has no GitHub setting behind it.** GitHub has no
  toggle for "a bot's approval satisfies the review requirement". The key records the fleet's
  intent for the maintainerd review skills (`review.approvalThreshold` and the `address-review`
  loop), and check 15 **explicitly skips it** rather than diffing it against something invented.
  It is listed in the report's "not checked here" line so its absence isn't read as a pass.
- **Repo content beyond existence** — see above.
- **Labels a repo has and the profile doesn't.** Not drift.
- **Anything in the repo's own `.claude/maintainerd.json` that the profile has no opinion on.** The
  profile seeds `bootstrap`; it does not own the file afterwards.

---

## Who applies what

| | Files in the repo | Labels | GitHub settings |
| --- | --- | --- | --- |
| `new-repo` (interactive, human's token) | writes | creates, on confirmation | applies, on confirmation, after showing every call |
| `new-repo` (non-interactive) | **refuses the whole run** | — | — |
| `doctor --profile` | reports | reports | reports, with the fixing call |

`doctor --profile` never mutates GitHub — not with `--fix`, not with a flag that doesn't exist yet.
`--fix` remains what it already was: offering to create missing labels, the one mutation `bootstrap`
also offers. Settings live outside that boundary permanently.

---

## Versioning

`profileVersion` follows the same rules as `workspace.contractVersion`
([`config-schema.md`](config-schema.md#the-versioned-contract)):

- Adding an **optional** key — to `defaults`, to a language block, to an entry — does **not** bump it.
- Removing a key, renaming one, making an optional key required, or changing what a key means
  **does**.
- A reader seeing a version above the one it knows **refuses to read the file**. Guessing at a shape
  is how a standard gets applied wrong to every repo at once.

**Version 1 guarantees:** `profileVersion`, `org`, `defaults` and `languages` are present;
`languages` is a non-empty object; `languages` and `repoOverrides` values carry only
`requiredChecks`, `coverage`, `commands` and `dependabot`; `coverage` is either `null` or an object
with `mode: "ratchet"`; `requiredChecks` is an array of strings.

---

## The helpers

Both are bash 3.2 + `jq`, no other dependency, and both fail closed.

| Script | What it does |
| --- | --- |
| [`../scripts/profile-resolve.sh`](../scripts/profile-resolve.sh) | Validates the profile's shape, then prints one repo's effective settings as JSON. `--validate` checks the file alone. Every rule above lives here rather than in prose the two skills would drift on. |
| [`../scripts/settings-diff.sh`](../scripts/settings-diff.sh) | Diffs the effective settings against `gh api` output the caller has already captured, and prints each difference with the exact call that fixes it. It reads files, never the network, so the same diff can be dry-run, tested, and reviewed before anything is applied. |

Unlike the coverage scripts, these are **not vendored into consuming repos**: they run inside a
skill, where the plugin is installed, and never in the consuming repo's CI.

---

## The intended consumer: a weekly drift issue

A standard nobody measures is a document. The cadence these checks are built for is **weekly, one
issue per drifted repo**:

- A scheduled job runs `doctor --profile` once per repo in the fleet's repo list.
- A repo with findings gets **one** issue, titled `chore: repo standard drift`, labeled `automated`,
  whose body is the report: every difference with the `gh api` call that fixes it.
- **The issue is updated in place, not reopened or duplicated.** One issue per repo, edited each
  week — the same discipline a review bot uses on its comment. Search for the open issue by title
  and label before opening one.
- When the repo conforms, the issue is **closed**, with the run that found it clean.
- A human pastes the calls. Nothing in the loop applies a settings change.

Maintainerd ships the check, not the scheduler. Wiring it to a cron — a scheduled Claude Code
routine, a fleet-automation job, a CI workflow — is the fleet's, because that is where the repo list
and the credentials live.
