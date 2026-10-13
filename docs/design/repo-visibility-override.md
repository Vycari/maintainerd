# Design: a `visibility` key under `repoOverrides`

Status: proposed. Tracking issue: #93. This note is design only; the implementation follows in the
PRs listed under [Implementation phases](#implementation-phases) once it is merged.

## Problem

A [repo profile](../../plugins/core/references/profile-schema.md) fixes repo visibility for the whole
fleet with `defaults.private`. That is enforced in two places today:

- `plugins/core/scripts/profile-resolve.sh` allows a `languages` or `repoOverrides` block to carry
  only the keys in its `RESOLVABLE` list (`requiredChecks`, `coverage`, `commands`, `dependabot`,
  `mergeQueue`, `protection`). Any other key fails validation in `block_errors` with
  `<block> carries "<key>", which is fixed org-wide — only … may vary per language or repo`.
  `scripts/test-profile.sh` pins this for `private` in a language block and for `labels` in an
  override.
- `plugins/core/scripts/settings-diff.sh` compares `effective.private` with the live repo's
  `private` field in `repo_findings`, and reports a mismatch as a `FAIL` whose fix is
  `gh api --method PATCH "repos/<slug>" -F private=<want>`.

So a public repo held to a profile whose `defaults.private` is `true` reports a visibility
difference on every run, and its weekly drift issue (see "The intended consumer" in the schema doc)
never closes. The only way to avoid that today is to leave the repo out of the profile, which also
drops every other check `doctor --profile` runs for it: required files, merge methods, branch
protection, the merge queue, labels, required-check producers.

A consumer fleet has a client repo that is meant to be public, with a second likely to follow. Both
should be held to the full standard apart from visibility.

## Decision this note implements

Decided by the maintainer on 2026-10-06 and not reopened here: visibility becomes an explicit, named
per-repo exception. A `visibility` key is legal only in a `repoOverrides` entry. `doctor --profile`
and `settings-diff.sh` report such a repo as "public by override" instead of as drift, and keep
diffing every other setting. Keeping the public repo outside the profile was rejected because it
loses the drift checks for everything else.

## The key

```jsonc
"repoOverrides": {
  "cli": { "visibility": "public" }
}
```

| Property | Value |
| --- | --- |
| Name | `visibility` |
| Type | string |
| Allowed values | `"public"`, `"private"` |
| Default | Absent. An absent key inherits `defaults.private`, exactly as today. |
| Legal in | A `repoOverrides` entry, and nowhere else. |

`"public"` is the value the key exists for. `"private"` is accepted so that the key reads the same
in a fleet whose `defaults.private` is `false`, where the exception runs the other way. An override
whose value matches the fleet default is redundant but valid, like any override that restates the
layer beneath it.

The name and the values are GitHub's own: the `repos/{slug}` response carries a `visibility` string
next to the `private` boolean.

`"internal"` is not accepted. `defaults.private` is a boolean and cannot express it either, and
`settings-diff.sh` reads only the live repo's `private` boolean, which cannot tell an internal repo
from a private one. Supporting it would mean changing the base key and reading GitHub's `visibility`
field instead, which is outside this note.

### How `visibility` relates to `private`

`private` stays what it is: the fleet-wide value, in `defaults`, a boolean, and still rejected in
every `languages` and `repoOverrides` block. `visibility` does not replace it and is not a second
spelling of it. The two names are different on purpose:

- A reader who sees `private` knows they are looking at the standard.
- A reader who sees `visibility` knows they are looking at one repo's declared exception.

Allowing `"private": false` in an override was considered and rejected. It would make the fixed
key settable per repo by the same name, which is the thing the schema doc says must not happen, and
a search for `private` in a profile would no longer find one authoritative line.

`visibility` is also not a seventh resolvable key. The six resolvable keys vary by language and by
repo and merge across three layers. `visibility` has one legal layer and no merge.

### Validation

`profile-resolve.sh --validate` (and every resolve, since validation runs first) gains four rules.
Messages follow the existing form so a profile author sees one style.

1. `visibility` in a `repoOverrides` entry must be the string `"public"` or `"private"`:

   ```text
   repoOverrides.cli.visibility is "internal", expected "public" or "private"
   ```

   A non-string (`true`, `null`, an object) gets the same message with the value printed as JSON.
   There is no `null` form: an override either states a visibility or does not carry the key.

2. `visibility` in a `languages` block is an error:

   ```text
   languages.shell carries "visibility", which is legal only in a repoOverrides entry — visibility is a per-repo exception, not a property of a language
   ```

3. `visibility` in `defaults` is an error:

   ```text
   defaults carries "visibility" — the fleet-wide value is defaults.private; visibility is legal only in a repoOverrides entry
   ```

   This one needs its own rule. `defaults` is not checked against an allow-list today (it is the
   layer that holds the fixed keys, and it passes unknown keys through), so without the rule a
   `defaults.visibility` would validate, flow into every repo's effective object through the merge,
   and be read downstream as if every repo had an override.

4. `private` in a `repoOverrides` entry stays an error, with a pointer added to the existing text:

   ```text
   repoOverrides.cli carries "private", which is fixed org-wide — only requiredChecks, coverage, commands, dependabot, mergeQueue, protection may vary per language or repo. To declare this one repo public, use "visibility": "public"
   ```

   The prefix is unchanged, so the existing assertions in `scripts/test-profile.sh` still match.
   `private` in a `languages` block keeps today's message with no pointer, since there is no legal
   way to vary visibility by language.

Mechanically, `block_errors` is one function applied to both block kinds with one allow-list. Adding
`visibility` to `RESOLVABLE` would legalize it in `languages`, so the implementation passes the
block kind in and keeps `RESOLVABLE` at six keys, with `visibility` allowed only when the block is
an override.

All problems are still reported in one pass, and the exit status is still `1`.

## Resolution

`profile-resolve.sh` merges `defaults * language * override`. An override's `visibility` is a scalar,
so the existing merge already carries it into `effective`. One step is added after the merge:

- If the override carries `visibility`, set `effective.private` to `visibility == "private"`, and
  leave `effective.visibility` in place.
- If it does not, `effective` has no `visibility` key at all. Nothing is invented, in line with the
  existing rule in `scripts/test-profile.sh` that an absent optional key must stay absent.

The result is that `effective.private` remains the single answer to "should this repo be private",
for every reader that already uses it, and `effective.visibility` is present exactly when that
answer came from an override. That presence is the only signal `settings-diff.sh` needs, and it
lives inside `effective` because `settings-diff.sh` accepts either the full resolver output or a
bare effective object.

Because validation rejects `visibility` in `defaults` and `languages`, the override is the only way
the key can reach `effective`.

One statement in the tests changes meaning: `scripts/test-profile.sh` asserts "fixed keys come from
defaults" with `.effective.private == true`. That stays true for every repo without the override and
gets a counterpart for a repo with it.

## Reporting

### A new severity: `NOTE`

`settings-diff.sh` has three severities today: `FAIL`, `WARN` and `SKIP`. A conformant key prints
nothing. "Public by override" is none of those: it is not a difference, not a warning, and the read
succeeded. It needs a line of its own because the point of the decision is that the exception is
visible in the report as well as in the profile.

`NOTE` is added with these properties:

- It is printed in the findings list like any other line.
- It does not count toward `difference(s)`, `warning(s)` or `not verified` in the summary.
- It does not affect the exit status, which stays "1 if any `FAIL`".
- A repo whose report holds only `NOTE` lines is conformant. The weekly drift issue for it closes.

`doctor --profile` check 15 reports a `NOTE` as a **PASS** carrying the note's text, and surfaces it
rather than folding it into a count, so a person reading the doctor report sees which repos are
public by declaration.

### The cases

`want` is `effective.private`; `got` is the live repo's `private`. The first four rows are a fleet
whose `defaults.private` is `true`.

| Override | Live repo | Report |
| --- | --- | --- |
| `visibility: "public"` | public | `NOTE  repos/<slug> is public by override (repoOverrides.<key>.visibility)` |
| `visibility: "public"` | private | `FAIL` — see below and [Q1](#open-questions) |
| absent | public | `FAIL`, as today, with one added line naming the override as the other fix |
| absent | private | Nothing, as today |
| `visibility: "private"` (fleet default public) | private | `NOTE  repos/<slug> is private by override (…)` |
| `visibility: "private"` (fleet default public) | public | `FAIL`, with the usual `PATCH … -F private=true` |
| any | repo settings not read | `SKIP`, as today: couldn't verify |

Every other setting is diffed exactly as it is now in all of these rows. The override changes one
row of `repo_findings` and nothing else.

**Override absent, live repo public.** This is the standard working, and it stays a `FAIL` with
today's `PATCH` call. The message gains one line, because there are now two legitimate ways to
resolve it and the report should not imply only one:

```text
FAIL  repos/my-org/cli private is false, profile wants true
      fix: gh api --method PATCH "repos/my-org/cli" -F private=true
      or, if this repo is meant to be public, declare it: repoOverrides.cli.visibility = "public" in the profile
```

**Override says public, live repo private.** The profile declares something that is not true of the
repo, so it is reported as a `FAIL`, not ignored. A private repo carrying a public override is not
"stricter and therefore fine": the override is a standing permission, and while it sits unused the
repo could be made public by anyone with admin and no report would notice. The finding names both
resolutions (publish the repo, or remove the override). Whether it also prints a paste-ready call
that publishes the repo is [Q1](#open-questions).

**Naming the override.** `overrideKey` is in the resolver's full output but not in a bare effective
object. `settings-diff.sh` reads it when it was handed the full output and prints
`repoOverrides.<key>.visibility`; handed a bare object, it prints `a repoOverrides entry`.

### `new-repo`

`plugins/core/skills/new-repo/SKILL.md` step 3 already takes `--<private|public>` from the profile,
and step 9 applies what `settings-diff.sh` prints. Both keep working unchanged once
`effective.private` is resolved from the override. Two prose changes:

- Step 3 says, in the confirmation it already shows, when the repo is being created public by
  override, and names the override key. Creating a public repo should never be a silent consequence
  of a flag derived three layers down.
- Step 9 treats a `NOTE` as nothing to apply.

## Other settings that change meaning on a public repo

The override changes one fact about a repo. Several GitHub settings exist only on public repos, or
only matter there. Each is decided here.

**Nothing the profile governs today stops applying.** Merge methods, delete-branch-on-merge, branch
protection, rulesets, the merge queue, labels, required files and required-check producers all
exist on a public repo and are diffed the same way. No existing check needs a public-repo branch.

| Item | Decision | Why |
| --- | --- | --- |
| Approval for workflow runs from fork pull requests | Follow-up | A public repo accepts pull requests from forks, and whether their workflows run without approval is a repo Actions setting. The profile governs no Actions settings today, and reading this one needs a new input to `settings-diff.sh`. |
| Secret scanning and push protection | Follow-up | The strongest candidate, since the main new risk on a public repo is a committed secret. But it is a requirement that should hold for every public repo in a fleet, so it is fleet policy and belongs in `defaults`, conditional on the resolved visibility. It does not belong inside one repo's override. |
| Private vulnerability reporting | Follow-up, with the two above | Only exists on public repos. Same shape: fleet policy conditional on visibility. |
| A license, security policy or contributing file | Follow-up, with the above | `defaults.files` is existence checks fixed fleet-wide. Requiring a file only on public repos is the same conditional-key design. |
| Required checks that need secrets | Out of scope | A check whose job needs a secret will not pass on a fork's pull request. That is a property of the repo's own workflows. Check 16 verifies a producer exists and cannot know what the job needs. |
| Issues, comments and pull requests from people outside the fleet | Out of scope for the profile | Already covered by [`untrusted-input.md`](../../plugins/core/references/untrusted-input.md), which treats that text as data whatever the repo's visibility. A public repo raises the volume, not the rule. |
| Forking, wiki, discussions, default token permissions | Out of scope | Not governed by the profile for private repos either. |
| `internal` visibility | Out of scope | See [The key](#the-key). |

The four follow-up rows are one piece of work: a `defaults` block of requirements that apply only
when `effective.private` is `false`. It is kept out of this key for two reasons. First, this key's
job is to stop a false drift report; bundling a security posture into it would give
`"visibility": "public"` an implied meaning nobody can read off the profile, which is the opposite
of declaring an exception in the open. Second, those settings need their own reads and their own
decisions about `couldn't verify` (several are only visible to an admin token), and the exact API
shapes should be verified against GitHub at that point, not asserted here.

That follow-up is the first conditional key the profile would have. It needs its own issue before
the implementation of this note merges, so it does not live only in this document.

## Versioning

`visibility` is an optional key and does not bump `profileVersion`. The practice is stated in the
schema doc's **Versioning** section:

> Adding an **optional** key — to `defaults`, to a language block, to an entry — does **not** bump it.

Two precedents in the repo followed it:

- `protectionFloors`, described in the schema doc's **Floors** section as "additive and optional and
  does not bump `profileVersion`".
- `mergeQueue` and `protection` becoming legal in `languages` and `repoOverrides` blocks (#81).
  `KNOWN_VERSION` in `profile-resolve.sh` stayed `1`.

One consequence should be stated plainly, because it differs from `protectionFloors`. That key was
placed as a sibling of `protection` in `defaults` so that an older reader ignores it. `visibility`
sits in a block that older readers check against an allow-list, so an older `profile-resolve.sh`
**rejects** a profile carrying it, for every repo, with `repoOverrides.<key> carries "visibility",
which is fixed org-wide`. That is loud and fail-closed, and it is the same thing that happened to
older readers when #81 landed. It means a fleet upgrades maintainerd before adding the key to its
profile. The implementation PR says so in the schema doc.

A tool that reads `defaults.private` straight from the profile, instead of the effective object,
would be wrong for an overridden repo. The schema doc already says everything is read from the
merged object and never from a layer directly; the implementation repeats that next to the key.

The schema doc's **Version 1 guarantees** paragraph is already out of date: it says `languages` and
`repoOverrides` values carry only `requiredChecks`, `coverage`, `commands` and `dependabot`, which
has not been true since #81. The implementation PR corrects it for all six keys and adds
`visibility`.

## The principle, amended

The schema doc states the principle in two places. Both change.

**The comment above `defaults` in "The shape".** Current:

```jsonc
  // Fixed org-wide. These keys appear ONLY here: a standard that lets one repo be public,
  // or skip reviews, is not a standard.
```

Proposed:

```jsonc
  // Fixed org-wide. These keys appear ONLY here: a standard that lets one repo quietly be
  // public, or skip reviews, is not a standard. The one named exception is `visibility`,
  // which a repoOverrides entry may declare — see "Visibility is a declared exception".
```

**The paragraph under "The six resolvable keys".** Current:

> **A `languages` or `repoOverrides` block containing any other key is an error, not a warning.** That
> is how "fixed org-wide" is mechanized: if `private` were settable per repo, the profile would
> document a standard nobody is held to. `profile-resolve.sh` fails on it, naming the key and the
> block it appeared in.

Proposed:

> **A `languages` or `repoOverrides` block containing any other key is an error, not a warning**,
> with one exception described below. That is how "fixed org-wide" is mechanized: if `private` were
> settable per repo, the profile would document a standard nobody is held to. `profile-resolve.sh`
> fails on it, naming the key and the block it appeared in.
>
> **Visibility is a declared exception.** A `repoOverrides` entry, and only a `repoOverrides` entry,
> may carry `"visibility": "public"` (or `"private"`, in a fleet whose default is public). It is not
> a seventh resolvable key: it has no language form and no `defaults` form, and `private` itself is
> still rejected in every block. A repo that is public by accident is drift, and is still reported
> as drift. A repo that is public by override is *declared*, in a block a reviewer reads, and that is
> the difference between an override and an exemption. The standard still names every public repo;
> what it no longer does is force a fleet to choose between a false drift report and no drift
> report at all. `doctor --profile` reports such a repo as public by override and diffs every other
> setting as usual.

The "declared, in a block a reviewer reads" sentence reuses the argument the same section already
makes for `mergeQueue` and `protection` overrides ("both are *declared*, in a block a reviewer
reads, and that is the difference between an override and an exemption").

Smaller edits to the same file, all in the implementation PR:

- "The shape": add a `visibility` line to the `repoOverrides` example, and change its comment from
  "Same six keys, same rules" to say the six keys plus `visibility`.
- "Worked example": the `private` row's "From" column notes that an override's `visibility` would
  replace it.
- "Fields", top level: the `repoOverrides` row no longer says "Same restriction as `languages`".
- "Fields", `defaults`: the `private` row points at the override.
- "Versioning": the corrected Version 1 guarantees, and the upgrade-order sentence.

## Test plan

All in `scripts/test-profile.sh`, which CI runs as its own step in `.github/workflows/validate.yml`.
No network is needed; `settings-diff.sh` reads files.

Validation:

- `repoOverrides.<key>.visibility` of `"public"` and of `"private"` validates.
- `"internal"`, `true`, `null` and an object are each rejected, naming the block and the value.
- `languages.<key>.visibility` is rejected with the language-specific message.
- `defaults.visibility` is rejected.
- `repoOverrides.<key>.private` is still rejected, and the message now names `visibility`.
- `languages.<key>.private` is still rejected with today's message (existing assertion, unchanged).

Resolution:

- With the override: `effective.private == false` and `effective.visibility == "public"`.
- Without it: `effective.private == true` and `effective` has no `visibility` key.
- A repo with no override in a profile that has the override on another repo is unaffected.
- `visibility: "private"` in a profile whose `defaults.private` is `false` resolves to
  `effective.private == true`.
- The short-name and full-slug override keys both work, and the slug wins, as for any override key.

Diff, one case per row of the table in [The cases](#the-cases):

- Public by override, live public: exit `0`, `Summary: 0 difference(s)`, the `NOTE` line present, no
  `PATCH` call printed for `private`.
- The same repo with a merge-method difference: exit `1`, the merge-method `FAIL` and its `PATCH`
  present. This is the assertion that the override does not mute anything else.
- Public by override, live private: `FAIL`, exit `1`, with the output [Q1](#open-questions) settles.
- No override, live public: `FAIL`, today's `PATCH` call, and the added line naming the override.
- Private by override, live private and live public.
- Repo settings not read: `SKIP`, no `NOTE` and no `FAIL`.
- A bare effective object (no `overrideKey`) still produces the `NOTE`, with the generic wording.
- A `NOTE` does not appear in the summary counts.

Fixture: `plugins/core/references/example-profile.json` is the fixture the tests resolve against,
and the schema doc calls it a working profile, so it should show the key. Add it as a **new**
override entry. Do not put it on `site`: the existing case "a coverage-exempt repo is still held to
the settings standard" diffs `site` against a fixture with `private: true` and would start failing.

Also run, per the PR template: `./scripts/sync-references.sh --check` (the schema doc is not one of
the vendored references, so this should be a no-op) and `python3 scripts/check-links.py`.

## Implementation phases

Two PRs. They can be collapsed into one if the maintainer prefers a single review; if they are
split, B must not merge before A.

**PR A — mechanism.**

- `plugins/core/scripts/profile-resolve.sh`: the four validation rules; the post-merge step that
  sets `effective.private`; usage text unchanged.
- `plugins/core/scripts/settings-diff.sh`: the `NOTE` severity; the visibility row of
  `repo_findings`; rendering; the summary and exit status left counting only what they count now.
- `scripts/test-profile.sh`: the test plan above.
- `plugins/core/references/profile-schema.md`: the amended principle and the smaller edits listed
  above.
- `plugins/core/references/example-profile.json`: one new override entry.

**PR B — skills prose.**

- `plugins/core/skills/doctor/SKILL.md`, check 15: a `NOTE` is a PASS that is surfaced; the
  two-fix wording for a public repo with no override.
- `plugins/core/skills/new-repo/SKILL.md`, steps 3 and 9: as described under
  [`new-repo`](#new-repo).
- `plugins/core/README.md` and the root `README.md`, where they summarize the profile: one sentence
  each, if the existing summaries mention visibility at all after the change.

Neither PR touches `KNOWN_VERSION`. Plugin versions are bumped by the merge workflow, not in the PR.

## Open questions

**Q1. When the profile wants a repo public and the live repo is private, does the report print a
paste-ready call that publishes it?**

Context: this arises with the override (`visibility: "public"`, repo still private) and, already
today, in a fleet whose `defaults.private` is `false`. In both, `settings-diff.sh` as written would
print `gh api --method PATCH "repos/<slug>" -F private=false`, and `new-repo --adopt` would offer to
run it in its batch. Publishing a repo exposes its full history and cannot be meaningfully undone.

- **(a)** `FAIL`, with no call. The finding names the two resolutions in words: publish the repo
  deliberately, or remove the override. `new-repo` therefore never publishes an existing repo; it
  only creates one public.
- **(b)** `FAIL`, with the `PATCH` call, labelled the way a loosening protection change is labelled
  today, so the person pasting it is told what it does.
- **(c)** `WARN`, with no call: an unused permission is worth saying but is not drift, so it does not
  hold the weekly issue open.

Recommendation: **(a)**. It keeps the mismatch visible and the weekly issue open until someone
resolves it, and it keeps the one irreversible repo-level change out of a batch of calls a person
approves with a single answer. (b) is consistent with "report-only, a human pastes", but the
labelling precedent is for a change that can be reversed by pasting the previous value. (c) leaves
a standing permission unreported in the place drift is tracked.
