---
name: dependabot
description: Drain the repo's Dependabot queue safely — gate every bot-authored dependency PR on all checks green, no requested changes, and the repo's semver policy (patch/minor by default; majors held for the human), merge one PR per non-overlapping file group, wait for Dependabot to rebase the rest, and repeat until the queue is empty or nothing can progress. Never fixes a broken update: it diagnoses the CI failure, files one issue with the evidence, labels the PR blocked, and moves on. This is the only maintainerd skill that merges, and it runs only where `depsFlow.enabled` is true in `.claude/maintainerd.json`. Designed as a recurring scheduled tick; also invocable as "/dependabot", "/dependabot drain", "/dependabot dry-run", or when the user says "merge the dependabot PRs", "clear the dependency queue", "what's blocking the dependabot backlog".
---

# Dependabot: drain the dependency-update queue

Dependabot opens the PRs; this skill decides which of them are **provably safe**, merges those, and
keeps the rest moving. It is the **one maintainerd skill that merges** — every other skill in the
suite stops at the merge gate on purpose. That authority is narrow and conditional: it applies only
to PRs authored by a configured bot, only when every check has concluded green, and only for bump
levels the repo has opted into. Everything else is reported, never forced.

The shape of the problem is a queue with a serialization point: every npm bump rewrites the same
`package-lock.json`, so merging one invalidates the rest. So the loop is *merge what's disjoint →
let Dependabot rebase the rest → re-gate → merge again*, until nothing is left that can move.

## Load the repo config

Before anything else, load the repo config (see
[`../../../core/reference/config-schema.md`](../../../core/reference/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. If the `config.depsFlow` block is **absent**, or `config.depsFlow.enabled` is not `true`, **STOP**
   and tell the user:
   > Automated dependency merging is not enabled for this repo. This skill merges PRs — set
   > `depsFlow.enabled` to `true` in `.claude/maintainerd.json` to opt in.

   **The opt-in is not optional and has no default.** Unlike every other block in the config, an
   absent `depsFlow` means *disabled*, not *use the defaults* — a skill that merges must never
   acquire that authority by omission. While disabled, do not merge, comment, label, or file
   anything.
4. Read the keys this skill needs: `config.repo`, `config.defaultBranch`, `config.commands.*` (used
   only to reproduce a failure locally when diagnosing — never to fix one), `config.labels.dependencies`
   and `config.labels.automated` (applied to the issues this skill files), and the whole
   `config.depsFlow` block — `botLogins`, `marker`, `autoMergeSemver`, `holdPackages`, `mergeMethod`,
   `requireApproval`, `maxMergesPerRun`, `rebaseNudgeMinutes`, `blockedLabel`, `drainPollMinutes`,
   `drainMaxMinutes`.
5. For any `depsFlow` key that is absent, fall back to the documented default (table below) and say
   so in the exit report — **except `enabled`, which has no permissive default.**

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | **none — absent = off** | Explicit opt-in to letting this skill merge here. |
| `botLogins` | `["dependabot[bot]"]` | Whose PRs this skill may act on. Add `"renovate[bot]"` if the repo runs Renovate. |
| `marker` | `<!-- deps-flow -->` | HTML comment stamped on every comment/issue this skill posts, so later runs recognize their own output. |
| `autoMergeSemver` | `["patch", "minor"]` | Bump levels eligible for auto-merge. Anything outside this list is **held for the human**. |
| `holdPackages` | `[]` | Package names (exact or `*`-globbed) never auto-merged at any level. |
| `mergeMethod` | `"squash"` | `squash` \| `merge` \| `rebase` — must be enabled in the repo's settings. |
| `requireApproval` | `false` | When `true`, also require `reviewDecision == "APPROVED"` (not just "nothing blocking"). |
| `maxMergesPerRun` | `5` | Hard cap on merges per invocation, drain mode included. |
| `rebaseNudgeMinutes` | `30` | How long a stale PR may sit before nudging with `@dependabot rebase`. |
| `blockedLabel` | `"deps:blocked"` | Applied to a PR whose failure has been diagnosed and filed, so later runs skip it. |
| `drainPollMinutes` | `5` | Pause between drain-mode passes. |
| `drainMaxMinutes` | `90` | Wall-clock ceiling on a drain run. |

## Invariants — read these first

1. **Merge only what the gate proves safe, and never widen the gate.** No `--admin`, no bypassing
   branch protection, no re-running or disabling a failing check to get it green, no merging with a
   check still pending. If a merge is refused by GitHub, that refusal stands — report it, don't route
   around it.
2. **Never enable GitHub auto-merge** (`gh pr merge --auto`). Auto-merge is a standing instruction
   that outlives this run and would merge a PR later, under conditions this skill never evaluated.
   Every merge happens in-run, immediately after its gate passed.
3. **Only PRs authored by a login in `config.depsFlow.botLogins`.** Verify `author.login` exactly —
   never infer bot authorship from the branch name, the title, or a label, all of which a human can
   set. A human's PR is never this skill's business, even one that only bumps a dependency.
4. **Never fix a broken update.** Do not push commits to a bot branch, do not edit code, do not pin
   or patch around a breakage, do not "just bump the peer dep too". A failing update is a signal for
   the maintainer: diagnose it, file one issue, label the PR, move on. Reproducing the failure locally
   in a throwaway checkout to *understand* it is allowed; committing anything is not.
5. **Never close a dependency PR, and never post a Dependabot command that creates lasting state.**
   `@dependabot rebase` is the only command this skill may post. Never `@dependabot close`,
   `ignore … `, `merge`, `squash and merge`, or `recreate` — the ignore commands write a permanent
   rule into the repo's Dependabot state that the maintainer then has to hunt down, and the merge
   commands hand the decision to a bot that hasn't run this gate.
6. **Never push to `config.defaultBranch`, never force-push, never create or delete labels.** The
   only label writes allowed are: *applying* `config.labels.dependencies` + `config.labels.automated`
   to the issues this skill files, and *applying or removing* `config.depsFlow.blockedLabel` on a
   dependency PR (removal only in the superseded case in step 1). All three must already exist;
   `bootstrap` creates them. Never touch a PR that isn't a dependency PR.
7. **Caps are hard.** At most `config.depsFlow.maxMergesPerRun` merges per invocation, at most one
   issue filed per broken PR (ever — the `blockedLabel` is the cross-run memory), at most one
   outstanding rebase nudge per PR per wait window.
8. **Honesty over tidiness.** If a diagnosis isn't supported by the logs, say "cause not determined"
   rather than inventing a plausible one. If a check couldn't be read, that PR is *not* green.

## Invocation modes

- **Scheduled (the primary mode):** a recurring task fires `/dependabot` in a sandbox with `gh`
  authenticated as the maintainer. One tick runs the passes below once, bounded by the caps, prints
  the exit report, and exits. Draining across a rebase happens *between* ticks — that's what the
  cadence is for. A tick is cheap when the queue is empty (one `gh pr list`, then "nothing to do").
- **Drain** (`/dependabot drain`): repeat the tick in-process, pausing `config.depsFlow.drainPollMinutes`
  between passes, until one of: nothing can progress, the merge cap is reached, or
  `config.depsFlow.drainMaxMinutes` of wall clock elapses. Use it interactively when you want the
  queue cleared *now* rather than over the next several ticks. Pause with whatever wait facility the
  session provides (a bounded `sleep`, a monitor/until-loop) — never busy-poll the GitHub API.
- **Dry run** (`/dependabot dry-run`): run the full gate read-only. Classify every PR, decide exactly
  what a live run would do, and print it with every action prefixed `would:` — but merge nothing,
  comment nothing, label nothing, file nothing. **Always safe, and the right first thing to run in a
  repo that has just enabled this skill.**

**Model tier.** The merge path is mechanical (read statuses, compare versions, call `gh pr merge`) and
runs fine on the **`fast`** tier. The one judgment-heavy step is diagnosing a broken update — when
subagent tooling is available, delegate *that step* to a **`capable`** subagent rather than up-tiering
the whole routine; when it isn't, the diagnosis is only as good as the run's model, so say so in the
issue's confidence line. See [`../../../core/reference/model-tiers.md`](../../../core/reference/model-tiers.md).

## What "safe to merge" means

A PR passes the gate only when **every** one of these holds. Any one unmet routes it elsewhere; none
of them is a judgment call.

1. **Authorship** — `author.login` is in `config.depsFlow.botLogins`.
2. **State** — open, not a draft.
3. **Mergeability** — `mergeable == "MERGEABLE"` **and** `mergeStateStatus == "CLEAN"`.
4. **Checks** — every check run and commit status on the head SHA has **concluded**, and every
   conclusion is `success`, `neutral`, or `skipped`. A single `queued`/`in_progress` check means "not
   yet", not "fine". `mergeStateStatus` alone is not sufficient here: it only reflects *required*
   checks, and the maintainer's stated bar is that **all** the tests pass.
5. **Reviews** — no `CHANGES_REQUESTED` review that hasn't been dismissed or superseded by a later
   review from the same reviewer. If `config.depsFlow.requireApproval` is `true`, also
   `reviewDecision == "APPROVED"`.
6. **Policy** — the bump level (below) is in `config.depsFlow.autoMergeSemver`, and no package in the
   PR matches `config.depsFlow.holdPackages`.
7. **Not already blocked** — the PR does not carry `config.depsFlow.blockedLabel` (a previous run
   diagnosed it; it's the maintainer's now).

`mergeStateStatus` is also the router for what *isn't* clean:

| Status | Meaning | Route to |
| --- | --- | --- |
| `CLEAN` | Nothing blocking | merge pass |
| `BEHIND` | Base moved; the repo requires up-to-date branches | rebase pass |
| `DIRTY` | Merge conflict (usually a lockfile another bump just rewrote) | rebase pass |
| `BLOCKED` | A required review is missing, or a required check hasn't reported | report as blocked-on-human (or wait, if checks are still running) |
| `UNSTABLE` | A non-required check is failing | **failure pass** — the maintainer's bar is *all* checks green, not just required ones |
| `HAS_HOOKS`, `UNKNOWN` | GitHub hasn't settled | leave for the next pass |

### Determining the bump level

Read it from the PR, don't guess:

- **Single-package PRs** — the title is `Bump <pkg> from <a> to <b>` (or `Update <pkg> requirement
  from <x> to <y>`). Compare the two versions: differing major → **major**; else differing minor →
  **minor**; else **patch**.
- **`0.x` packages are special.** Under semver, pre-1.0 minor bumps carry breaking changes
  (`0.4.2 → 0.5.0`). Classify a `0.x` minor bump as **major**, and a `0.x` patch bump as **minor**.
  This is deliberately conservative — pre-1.0 libraries are exactly where a green test suite proves
  the least.
- **Grouped PRs** (`Bump the <group> group with N updates`) — the body carries a table of every
  package's from→to. The PR's effective level is the **highest** level in the group, and a single
  held package holds the whole group.
- **Anything you can't parse confidently → treat as `major`** (i.e. hold for the human). Never
  default an unparseable version delta into the auto-merge bucket.

Version deltas that aren't semver at all (a Docker digest, a GitHub Action pinned to a SHA, a git
ref) can't be levelled: treat a **GitHub Action tag bump** by its tag semver when it has one, and
everything else as `major` — held.

### Determining overlap

Two open dependency PRs **overlap** when their changed file sets intersect. In practice that means
they touch the same manifest/lockfile pair, which is why a stack of npm bumps must merge one at a
time while an npm bump and a `github-actions` bump can both land in the same pass.

Compute it from the files, not from the ecosystem name in the branch:

```bash
gh pr view <N> --repo "$REPO" --json files --jq '[.files[].path] | sort'
```

Group the gate-passing PRs into **disjoint file groups**, and take at most **one PR from each group**
per pass — the oldest. Everything else in that group is expected to go `BEHIND`/`DIRTY` the moment its
neighbour merges; that's the rebase pass's job, not a failure.

## The run algorithm

One pass = steps 0–5. A scheduled tick runs one pass; drain mode repeats it.

### Step 0 — Preflight and gather

```bash
gh auth status
gh repo view "$REPO" --json nameWithOwner        # $REPO = config.repo

gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,author,headRefName,headRefOid,isDraft,createdAt,updatedAt,labels,mergeable,mergeStateStatus,reviewDecision \
  | jq --argjson bots '<config.depsFlow.botLogins as a JSON array>' \
       '[.[] | select(.author.login as $l | $bots | index($l))]'
```

If `gh` auth or repo resolution fails, print the failure and stop — do not attempt repairs. If no bot
PRs are open, print "queue empty" and stop (this is the common case; keep it cheap).

For each candidate PR, pull its checks and reviews:

```bash
gh pr checks <N> --repo "$REPO" --json name,state,link,bucket
gh api "repos/$REPO/pulls/<N>/reviews" --jq '[.[] | {user: .user.login, state: .state, submittedAt: .submitted_at}]'
```

### Step 1 — Classify

Put every candidate in exactly one bucket:

- **blocked** — carries `config.depsFlow.blockedLabel`. Already diagnosed and filed; skip it entirely
  (don't re-read its logs, don't nudge it, don't re-file). It appears in the report only as a count.
  **The one exception — superseded PRs.** Dependabot force-pushes a PR when a newer release lands, so
  a labelled PR can quietly become a *different* update. If the PR's target version no longer matches
  the one named in the linked issue, the diagnosis is stale: remove `blockedLabel`, comment on the
  issue that the PR now targets the new version, and re-classify the PR from scratch this pass. Never
  carry a `blocked` label across a version change — that's how a fixed dependency stays stuck forever.
- **held** — gate items 1–5 pass, but policy (item 6) doesn't: a major bump, a `holdPackages` match,
  an unparseable delta. **Never merged, never nudged, never issue-filed.** Surface it in the report so
  the maintainer can merge it themselves.
- **failing** — a concluded check failed, or `mergeStateStatus == "UNSTABLE"`.
- **stale** — `BEHIND` or `DIRTY`.
- **waiting** — checks still running, `HAS_HOOKS`/`UNKNOWN`, or `BLOCKED` with checks still reporting.
- **blocked-on-human** — `BLOCKED` with all checks concluded green (a required review is missing), or
  a live `CHANGES_REQUESTED`.
- **mergeable** — everything in the gate passes.

### Step 2 — Merge pass

Group the **mergeable** bucket by file overlap; take the oldest PR from each disjoint group, up to
`config.depsFlow.maxMergesPerRun` total. Then, **one at a time**:

1. **Re-gate immediately before merging.** The previous merge in this same pass moved the base branch,
   so re-fetch this PR's `mergeable`, `mergeStateStatus`, and checks. A PR that has gone `BEHIND` or
   `DIRTY` in the last thirty seconds is no longer mergeable — move it to the stale bucket and go on
   to the next group. This re-check is not optional; the whole point of the overlap grouping is that
   file-disjointness is a *heuristic*, and GitHub's answer is the truth.
2. Merge with the configured method:

   ```bash
   gh pr merge <N> --repo "$REPO" --squash        # or --merge / --rebase per config.depsFlow.mergeMethod
   ```

   No `--admin`, no `--auto`. Dependabot deletes its own branch on merge, so don't pass
   `--delete-branch` unless the repo's own setting is off and the maintainer asked for it.
3. If the merge is **refused** (branch protection, a method the repo doesn't allow, a race), record the
   refusal verbatim in the report and leave the PR alone. Never retry with a different method or a
   privilege flag.

### Step 3 — Rebase pass

Dependabot rebases its open PRs on its own when the base branch moves — usually within minutes. **The
default action here is to wait**, because a nudge posted into an in-flight rebase does nothing but add
noise.

Nudge a stale PR only when **all** of these hold:

- it is in the **stale** bucket (`BEHIND`/`DIRTY`), and not **held** or **blocked**;
- its head commit is older than `config.depsFlow.rebaseNudgeMinutes` — i.e. no rebase has landed in
  that window. Read the head commit's date, **not** the PR's `updatedAt` (which a label or comment
  bumps, making an untouched PR look freshly rebased):

  ```bash
  gh api "repos/$REPO/commits/<headRefOid>" --jq '.commit.committer.date'
  ```
- there is no outstanding nudge: no marker comment containing `@dependabot rebase` newer than
  `config.depsFlow.rebaseNudgeMinutes`.

Then post exactly:

```markdown
<!-- deps-flow -->

@dependabot rebase
```

(the first line is `config.depsFlow.marker`). The marker is what makes the nudge idempotent across
runs — it's how the next pass knows a nudge is already outstanding.

If a PR has been nudged twice and is still `DIRTY`, stop nudging it: report it as needing manual
attention (a conflict Dependabot can't resolve is usually a manifest the maintainer edited by hand).

### Step 4 — Failure pass: diagnose, file, never fix

For each PR in the **failing** bucket that does not already carry `config.depsFlow.blockedLabel`:

1. **Rule out a pre-existing breakage first.** If the same check is also failing on
   `config.defaultBranch`, the dependency is not the cause:

   ```bash
   gh run list --repo "$REPO" --branch "<config.defaultBranch>" --workflow "<failing workflow>" --limit 5 \
     --json conclusion,headSha,createdAt
   ```

   If the default branch is red too, **file nothing about the dependency** — report "CI is broken on
   `<defaultBranch>`; dependency PRs can't be gated until it's green" once for the whole run, and
   leave every failing PR untouched. This is the guard against a broken build spraying one bogus
   dependency issue per open PR.

2. **Gather evidence.** The failing job's log, trimmed to what actually matters:

   ```bash
   gh pr checks <N> --repo "$REPO"                       # which check, and its run URL
   gh run view <runId> --repo "$REPO" --log-failed        # the failing step's output
   ```

   Keep the first real error and the failing test names. Don't paste a thousand lines into an issue.

3. **Read the upstream notes Dependabot already embedded.** A Dependabot PR body carries the
   dependency's release notes, changelog entries, and commit list. When a breaking change is described
   there, quote the relevant entry — it is usually the whole diagnosis, and it costs no web fetch.

4. **Classify the failure** and reproduce it locally only if the logs are ambiguous — in a throwaway
   checkout of the PR branch, running `config.commands.*` read-only. **Commit nothing.** Typical
   classes: a genuine breaking API change; a transitive/peer-dependency conflict; a type-only break; a
   changed default that the repo relied on; a test asserting on a message the dependency changed; an
   install/resolution failure.

5. **Dedup, then file one issue.** Search for an existing marker issue for the same package:

   ```bash
   gh issue list --repo "$REPO" --state open --label "<config.labels.dependencies>" \
     --search "<package name> in:title" --json number,title
   ```

   If one exists for the same package, add a short comment only if the target version has changed
   since; otherwise do nothing. Otherwise file the issue in the format below, labelled
   `config.labels.dependencies` + `config.labels.automated`.

6. **Label the PR** `config.depsFlow.blockedLabel` and post one marker comment linking the issue.
   **This is the cross-run memory** — it's what stops every future run from re-diagnosing the same
   failure. Leave the PR open: closing it is the maintainer's call, and Dependabot treats a closed PR
   as a signal to stop offering that version.

### Step 5 — Exit report

Print the report (format below) and stop. In drain mode, print a one-line pass summary instead and
continue to the next pass; print the full report when the drain ends.

## Drain-mode loop

```
for pass in 1..∞:
    run steps 0–5
    stop when ANY of:
      - nothing moved this pass AND nothing is in the `waiting` bucket   (queue is as drained as it gets)
      - merges this run == config.depsFlow.maxMergesPerRun
      - elapsed >= config.depsFlow.drainMaxMinutes
      - only `held` / `blocked` / `blocked-on-human` PRs remain          (everything left needs the human)
    otherwise pause config.depsFlow.drainPollMinutes and start the next pass
```

The caps are per **invocation**, not per pass — a drain that merges five PRs stops at five, and says
so. Never let a drain run past `drainMaxMinutes` because "one more rebase is nearly done".

## Broken-update issue format

The literal `<!-- deps-flow -->` stands in for `config.depsFlow.marker`.

```markdown
<!-- deps-flow -->

## What broke

`<package>` **<from> → <to>** (#<PR>) fails CI on `<check name>`.

## Evidence

<the failing check, the first real error, failing test names — trimmed, in a code fence>

## Diagnosis

<best-effort cause in 2–4 sentences. Quote the upstream changelog/release-note entry from the PR body
when it explains the break. If the logs don't support a cause, write "Cause not determined from the
CI logs" and say what's missing — never invent one.>

**Confidence:** high | medium | low — <what would confirm it>

## Suggested next steps

- <the concrete thing a human would try first>
- <alternative: pin, wait for the next upstream release, adapt the call site>

---

This issue was filed by the `dependabot` skill, which **does not attempt fixes** — no commits were
pushed to the PR branch. PR #<PR> has been labelled `<blockedLabel>` and will be skipped by future
runs until that label is removed.
```

## Exit report

```text
dependabot — <ISO timestamp>   (repo: <config.repo>, mode: tick | drain | dry-run)
policy: auto-merge <config.depsFlow.autoMergeSemver joined> · cap <n>/<maxMergesPerRun> · method <mergeMethod>

open dependency PRs: <n>
  merged (<n>):
    - #201 bump lodash 4.17.20 → 4.17.21 (patch, npm)
    - #204 bump actions/checkout v4.1.1 → v4.2.0 (minor, github-actions — disjoint from #201)
  stale, awaiting rebase (<n>):
    - #202 (DIRTY since #201 merged — Dependabot rebasing, no nudge yet)
    - #203 (BEHIND 41m — nudged with @dependabot rebase)
  held for you (<n>):
    - #205 bump vite 5.4.2 → 6.0.1 — major, outside autoMergeSemver
    - #206 bump zod 0.9.4 → 0.10.0 — 0.x minor treated as major
  failing (<n>):
    - #207 bump pydantic 2.8 → 2.9 — filed #312 (type errors in 3 modules), labelled deps:blocked
  waiting on checks (<n>): #208
  blocked on you (<n>): #209 (required review missing)
  already diagnosed (<n>): #199

blocked on human: <n> PRs   errors: <none | verbatim>
next: <what the following tick is expected to do — e.g. "merge #202 once its rebase lands">
```

If the queue is empty: `dependabot — queue empty, nothing to do.` Don't pad it.

## What not to do

- **Don't merge anything that isn't provably green.** A pending check is not a passing check, and
  `mergeStateStatus: CLEAN` is not proof that non-required checks passed.
- **Don't merge with `--admin`, don't enable auto-merge, don't re-run or disable a failing check** to
  get a PR through.
- **Don't touch a human-authored PR**, ever — not even a dependency bump a human opened.
- **Don't fix a broken update.** No commits to bot branches, no pins, no workarounds. Diagnose, file,
  label, move on.
- **Don't post any Dependabot command except `@dependabot rebase`** — never `close`, never
  `ignore …` (it writes a permanent rule), never `merge`/`squash and merge` (it hands the decision to
  a bot that never ran this gate).
- **Don't nudge a rebase that's already in flight**, and don't nudge a PR you've already nudged inside
  the wait window — that's what the marker comment is for.
- **Don't file a second issue for a PR that already carries `blockedLabel`**, and don't file
  dependency issues at all while `config.defaultBranch` is red.
- **Don't leave `blockedLabel` on a PR whose target version has changed** — a superseded PR is a new
  update and gets a fresh gate, or a fixed dependency stays blocked forever.
- **Don't close dependency PRs.** Closing one tells Dependabot to stop offering that version; that's a
  standing decision only the maintainer should make.
- **Don't invent a diagnosis.** "Cause not determined from the CI logs" is a useful, honest issue;
  a confident wrong cause sends the maintainer down the wrong path.
- **Don't merge past the cap** because the queue is nearly clear, and don't extend a drain past
  `drainMaxMinutes`.
- **Don't create labels** — apply only the ones that already exist (`bootstrap` creates them). If
  `blockedLabel` is missing, note it in the report and skip the labelling step rather than filing an
  issue you can't mark.

## When integrated with scheduling

Schedule it on its own slot (hourly to a few times a day suits most repos — Dependabot's own schedule
sets the supply). It is **not** part of `daily-update`: that skill bundles its sub-skills' output into
one PR, and this skill merges rather than producing a diff. A tick against an empty queue is one API
call, so a tight cadence is cheap.

Pair it with `audit-deps` on a slower cadence: this skill drains the bumps Dependabot proposes,
`audit-deps` covers what Dependabot doesn't (unused, phantom, deprecated, licenses).

## Related skills

- **audit-deps** — the other half of dependency health. It deliberately *doesn't compete* with
  Dependabot's PRs; this skill is what processes them. The two dedup naturally: `audit-deps` skips
  anything an open Dependabot PR already covers, and files its findings under the same
  `config.labels.dependencies` label this skill searches when deduping.
- **address-review** — the skill for iterating on review feedback on a PR *you own*. This skill never
  iterates on a dependency PR; when one needs code changes it hands off to a human via an issue.
- **doctor** — validates the `depsFlow` block, and that `blockedLabel` and the dependency labels exist
  on GitHub before this skill needs them.
- **bootstrap** — generates the `depsFlow` block (defaulting `enabled` to `false`) and creates the
  labels.
