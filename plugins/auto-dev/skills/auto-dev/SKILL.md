---
name: auto-dev
description: Execute one tick of the autonomous issue-to-PR pipeline — triage open issues for readiness, draft plans for maintainer approval, build the oldest approved issue into a PR, address review feedback; never merges; state lives in configurable auto:* GitHub labels. Designed to run as a recurring scheduled task that invokes this skill directly each tick in a full-toolchain sandbox; also invocable interactively as "/auto-dev" or "run an auto-dev tick", and as "/auto-dev dry-run" for a read-only report of what a tick would do. The auto:* label names, comment marker, and branch prefix are configurable per repo via `.claude/maintainerd.json`.
---

# Auto-dev: one tick of the issue-to-PR pipeline

This skill automates the path from open issue to reviewed PR while keeping the maintainer in control of two gates: **plan approval** (nothing is built without an approved plan) and **merge** (the skill never merges — ever). It is designed to run unattended on a regular cadence (spaced comfortably longer than one build tick — see **Overlap & isolation**); each invocation is **one tick of a state machine**, does the single highest-priority piece of work, and exits. "Waiting" (for a reply, an approval, a review, a merge) is simply what happens between ticks.

## Load the repo config

Before anything else, load the repo config (see
[`../../../core/reference/config-schema.md`](../../../core/reference/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. If `config.autoDev.enabled` is `false`, **STOP** and tell the user:
   > Auto-dev is disabled for this repo. Set `autoDev.enabled` to `true` in `.claude/maintainerd.json` to use it.

   Do not run any tick logic, post any comment, or change any label while disabled.
4. Read the keys this skill needs: `config.repo`, `config.defaultBranch`, `config.commands.*`
   (`format`, `lint`, `build`, `typecheck`, `test`), `config.guidelines` (its behavioral/smoke
   checks feed step 3's verification — item 6), and the whole `config.autoDev` block —
   `branchPrefix`, `marker`, `stateLabels.*`, `excludedLabels`, `openPrsAsDraft`, `prLabel`
   (the label stamped on every automated PR — default `auto:pr` if absent),
   `fallbackReviewMinutes` (how long a PR may sit unreviewed before the fallback self-review —
   default `60` if absent), `maxPrsInFlight` (how many automated PRs may be open at once —
   default `1` if absent, i.e. the single-PR pipeline), and `orphanReclaimMinutes` (how old a
   PR-less In-progress issue must be before a tick treats it as a crashed build rather than one
   running concurrently — default `90` if absent).
5. Treat a `null` command as **"this repo has no such step — skip it, don't invent one."**

Throughout this skill, every `auto:*` label, the bot comment marker, and the `auto/issue-` branch
prefix are **config-driven** — they read from `config.autoDev`, never hardcoded. The state machine,
its transitions, and every safety rail below are identical regardless of what those labels are
named.

### State → config key

The pipeline's whole memory lives in a small set of GitHub labels. The rest of this document refers
to states by their **logical name** (left column); each maps to the configured label string via
`config.autoDev.stateLabels`:

| Logical state | Config key                              | Default label     |
| ------------- | --------------------------------------- | ----------------- |
| Needs-info    | `config.autoDev.stateLabels.needsInfo`  | `auto:needs-info` |
| Planned       | `config.autoDev.stateLabels.planned`    | `auto:planned`    |
| Ready         | `config.autoDev.stateLabels.ready`      | `auto:ready`      |
| In-progress   | `config.autoDev.stateLabels.inProgress` | `auto:in-progress`|
| Parked        | `config.autoDev.stateLabels.parked`     | `auto:parked`     |
| Skip          | `config.autoDev.stateLabels.skip`       | `auto:skip`       |

The bot comment **marker** is `config.autoDev.marker` (default `<!-- auto-dev -->`), and the
**branch prefix** for automated PRs is `config.autoDev.branchPrefix` (default `auto/issue-`).

## Invariants — read these first

1. **Never merge a PR.** Not with `gh pr merge`, not via the API, not by enabling auto-merge. Merging is exclusively the maintainer's act, and a merge is what unblocks the pipeline for the next issue.
2. **At most `config.autoDev.maxPrsInFlight` automated PRs in flight (default `1`).** Building is gated on the count of open automated PRs being _below_ this cap — not necessarily on zero. With the default of `1` this is the classic single-PR pipeline (while the one PR is open, no new issue gets built); a repo that sets a higher cap allows that many built-but-unmerged PRs to await review at once. While at the cap, no new issue is built; ticks either advance an open PR toward merge or groom the backlog. Merges remain exclusively the maintainer's act (invariant 1); this cap only widens how many built-but-unmerged PRs may await review — it never merges, auto-merges, or closes anything.
3. **All runs happen under the maintainer's own GitHub identity**, so authorship cannot distinguish this pipeline from the human. Every comment this skill posts MUST begin with `config.autoDev.marker` (an HTML comment, invisible in rendered Markdown). Classify comments into three buckets: **pipeline** (has the marker), **third-party bot** (author login ends in `[bot]` or `app/` — e.g. `coderabbitai`, `dependabot`; CodeRabbit posts auto-enrichment boilerplate on issues), and **human** (everything else). Only _human_ comments count as replies, answers, or approvals; third-party bot comments never satisfy "the human replied" and never gate-keep anything — read them for technical signal at most.
4. **Labels are the cross-run memory, and humans always win.** If a human has changed a state label since the last tick (e.g. removed Ready, added Skip), respect the label as found — never "correct" it back.
5. **Self-enforced hard prohibitions.** There is no external permission allowlist — this skill is the only guardrail, so treat the following as absolute and, if a tick ever seems to need one, stop and report it instead of doing it: never merge, close, or reopen any PR or issue; never force-push, and never push to `config.defaultBranch` directly; never run the release process (version bumps, publishes, `gh release …`); never create, delete, or edit labels (only **apply or remove the state labels** named in `config.autoDev.stateLabels`, and **apply** the PR label `config.autoDev.prLabel` to automated PRs — both must already exist; bootstrap creates them); never submit a formal GitHub review of any kind on the pipeline's own PRs (the fallback self-review in step 2 is a plain comment, never an approval or request-changes); never edit or delete human comments; never delete the repo, issues, or `gh api -X DELETE` anything; never run destructive or privileged shell (`rm -rf` outside the throwaway build sandbox, `sudo`, or `curl`/`wget` to exfiltrate). Working-tree resets are allowed **only** in the disposable scheduled sandbox (Step 0), never in an interactive checkout.
6. **Stay inside the repo's own conventions**: pre-flight checks, documentation policy, and the PR template all come from the `create-pr` skill and the repo's contributor docs, exactly as for human-driven work.

## Invocation modes

- **Scheduled (the primary mode):** a recurring scheduled task (e.g. a Claude scheduled task running in the cloud) fires `/auto-dev` on a cadence, in a fresh full-toolchain sandbox — git, the language toolchain, and `gh` authenticated as the maintainer. **There is no external runner script** and no permission allowlist: the skill owns its own setup (Step 0 establishes a clean `config.defaultBranch` baseline and installs deps) and the exit report is the run's summary output. Because the sandbox is disposable, Step 0 may hard-reset it to a clean `config.defaultBranch` — that is the one place a reset is allowed.
- **Interactive** (`/auto-dev` in a Claude Code session): identical decision logic, but under normal permission prompts and possibly in the maintainer's working checkout. **Never reset, clean, or stash an interactive checkout.** A dirty working tree or a branch other than `config.defaultBranch` does NOT block the GitHub-only steps (1-reconcile, 4-triage) — it only blocks steps that touch the working tree (2's CI/feedback fixes, 3-build). If a working-tree step is what the tick needs and the tree is dirty, report that and stop rather than stashing or resetting anything.
- **Dry run** (`/auto-dev dry-run`, or the user asks for a dry run): execute the full tick logic **read-only**. Gather all state, decide exactly what a live tick would do, and print it as the exit report with every action prefixed `would:` — but post no comments, change no labels, create no branches/commits/PRs, and push nothing. This is the recommended first test and is always safe to run.

**Overlap & isolation.** With no lockfile, the scheduled task must not overlap its own runs — set the cadence comfortably longer than a typical tick (a tick that builds can take many minutes). The label state machine is the backstop: work is claimed by swapping to In-progress, and the build step is gated on the count of open automated PRs being below `config.autoDev.maxPrsInFlight`. Two truly concurrent ticks could still race — both picking the same oldest Ready issue, or a fresh tick mistaking a build that's mid-flight (labelled In-progress but not yet PR'd) for a crashed orphan and rebuilding it. Step 1's **orphan age-gate** closes the second race (only reclaim a PR-less In-progress issue once its label event is older than `config.autoDev.orphanReclaimMinutes`); for the first, still don't schedule tighter than a build tick can finish. Each scheduled run is its own disposable sandbox, so runs never share a working tree.

**Model tier.** A tick drafts plans, writes code, and adjudicates review feedback — schedule it on the **`capable`** tier; don't down-tier to save tokens on its triage pass, because the *same* run also builds (a skill can't switch its own model mid-run). The read-only **`dry-run`** mode does no judgment or code-gen and is safe on the **`fast`** tier. See [`../../../core/reference/model-tiers.md`](../../../core/reference/model-tiers.md).

## Label state machine

| State        | Meaning                                                                                                                                     | Who sets it                                           |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| (no state label) | Not yet triaged by auto-dev                                                                                                             | —                                                     |
| Needs-info   | Skill asked a clarifying question; waiting on a human reply                                                                                 | skill                                                 |
| Planned      | Skill posted an implementation plan; waiting on approval                                                                                    | skill                                                 |
| Ready        | Plan approved; eligible to build                                                                                                            | skill (on detected approval) or human (directly)      |
| In-progress  | Being built / has an open automated PR                                                                                                      | skill                                                 |
| Parked       | Assessed; the maintainer chose to hold it. Skill does not re-triage until the label is removed or a human comment is added _after_ the park | human (directly), or skill on a human "park it" reply |
| Skip         | Opt-out — auto-dev never touches this issue                                                                                                 | human                                                 |

**Eligibility:** all open issues, oldest first, EXCEPT issues labeled with the Skip state label (`config.autoDev.stateLabels.skip`) or any label in `config.autoDev.excludedLabels` (defaults: `epic`, `question`, `wontfix`, `duplicate`, `invalid`). Pull requests are never triaged as issues.

## The tick algorithm

Work through these steps in order — the order **is** the priority. Execute the **first step that has work**, finish it, print the exit report, and stop. The ordering puts concrete, human-approved progress ahead of speculative grooming: advancing an open PR (step 2) and **building an approved issue (step 3) both outrank the triage pass (step 4)**, because a ready build is work the maintainer has already greenlit while triage only feeds the queue. With the default `config.autoDev.maxPrsInFlight` of `1`, an open PR blocks building until it merges, so most ticks either advance that PR or, finding it quiescent, fall through to triage. With a higher cap, an open PR **no longer blocks building**: a tick advances an open PR only when one actually needs work (CI red, unaddressed feedback, a draft to resume, or a review-window timeout that triggers a fallback self-review); when every open PR is quiescent (waiting on the maintainer's review or merge) and the in-flight count is below the cap, the tick builds the next Ready issue instead. That's what drains the queue overnight — each merge-blocked-but-quiescent PR simply frees the tick to build the following issue, up to the cap. Triage runs on the ticks that would otherwise idle (all PRs quiescent, and either nothing is Ready or the cap is reached).

Do not fall through to later steps after completing one, with one exception chain for the **idle** case: when **step 2 finds every open PR quiescent** (nothing to advance), it falls through to **step 3 (build)**, which runs if the in-flight count is below `config.autoDev.maxPrsInFlight` and something is Ready; if step 3 also has no work (at the cap, or nothing Ready), it falls through to **step 4 (triage)**. A tick that _does_ advance a PR (fixes CI, answers feedback) stops there — that was its unit of work.

### Step 0 — Preflight & environment

First establish the working baseline. **The skill owns this now that there is no runner script.**

- **Scheduled (disposable sandbox)** — put the repo on a clean, current `config.defaultBranch` and install deps (safe precisely because the sandbox is throwaway):

  ```bash
  git fetch origin --prune
  git checkout <config.defaultBranch> && git reset --hard origin/<config.defaultBranch> && git clean -fd
  git pull --ff-only origin <config.defaultBranch>
  # install dependencies with the repo's package manager (e.g. npm install --no-audit --no-fund, uv sync)
  ```

- **Interactive checkout** — do NOT reset, clean, or stash. Just observe state with `git status --porcelain`; a dirty tree or a branch other than `config.defaultBranch` only blocks the working-tree steps (see Invocation modes).

Then confirm GitHub access and identity:

```bash
gh auth status                      # must be authenticated (as the maintainer)
gh repo view <config.repo> --json nameWithOwner   # confirm the repo
```

Gather the current state in parallel (the branch prefix is the identity signal for automated PRs):

```bash
# Open automated PRs (branch prefix is the identity signal)
gh pr list --repo <config.repo> --state open --json number,headRefName,title,reviewDecision,mergeable,isDraft,labels \
  | jq --arg p '<config.autoDev.branchPrefix>' '[.[] | select(.headRefName | startswith($p))]'

# All open issues, oldest first
gh issue list --repo <config.repo> --state open --limit 200 \
  --json number,title,labels,createdAt,updatedAt --search "sort:created-asc"

# Recently closed automated PRs (for step 1's orphan/closure handling)
gh pr list --repo <config.repo> --state closed --limit 10 --json number,headRefName,mergedAt,closedAt \
  | jq --arg p '<config.autoDev.branchPrefix>' '[.[] | select(.headRefName | startswith($p))]'
```

If `gh` auth or repo resolution fails, print the failure in the exit report and stop — do not attempt repairs.

**Re-stamp the PR label (self-heal).** The label the pipeline puts on its own PRs
(`config.autoDev.prLabel`, default `auto:pr`) is what lets external tooling skip them, so a PR that
missed it is a PR that gets reviewed by tooling that was configured to leave it alone. Applying the
label can miss for ordinary reasons — the label didn't exist when the PR was opened, a transient
`gh` failure, a PR opened by a delegated skill — and nothing else would ever fix it. So on **every**
tick, using the `labels` already fetched above (no extra API call), add the label to any open
automated PR that lacks it:

```bash
gh pr edit <N> --repo <config.repo> --add-label "<config.autoDev.prLabel>"
```

This is a cheap no-op on the normal path, where every open automated PR already carries the label.
It is a **repair**, not the primary application — the primary application happens at PR-creation
time (step 3, item 7), because a label added minutes later doesn't retract a review that external
tooling already started. If the edit fails because the label doesn't exist, note it once in the exit
report and continue — never create the label yourself (invariant 5); `/doctor` reports it and
`/bootstrap` creates it.

### Step 1 — Reconcile finished work

For issues labeled In-progress:

- **PR merged** (or issue closed by `Fixes #N`): remove the In-progress label. If the issue is somehow still open after its PR merged, comment (with marker) linking the merged PR and noting it may be closable — but leave closing to the human.
- **PR closed without merging**: treat as rejection of the approach. Remove the In-progress label, add the Skip label, and comment (with marker) that the PR was closed unmerged and the issue needs human direction before auto-dev will touch it again.
- **No PR exists at all** — either a previous tick crashed between labeling and PR creation, or a build is running _right now_ in a concurrent tick. Distinguish by the age of the most recent In-progress `labeled` event: if it is older than `config.autoDev.orphanReclaimMinutes` (default 90), treat the issue as a crashed orphan and let step 3 rebuild it (its plan is already approved); if it is younger, assume a build is mid-flight and **leave the issue untouched this tick** — do not reclaim or rebuild. Read the label age from the timeline:

  ```bash
  gh api "repos/<config.repo>/issues/<N>/timeline" --paginate \
    | jq -r --arg l '<config.autoDev.stateLabels.inProgress>' \
        '[.[] | select(.event=="labeled" and .label.name==$l)] | last | .created_at'
  ```

### Step 2 — Advance an open automated PR

If one or more automated PRs are open, pick the **single most-urgent** one to advance this tick (one PR per tick keeps the tick bounded). Urgency order, oldest-first within a tier: (1) a **draft** to resume, (2) **CI red**, (3) **unaddressed feedback** (the newest comment on a thread lacks the marker — third-party bots' auto-generated notices don't count; see item 3 of the review loop), (4) **unreviewed past the review window** — ready, CI green, no review activity from any human or third-party bot, older than `config.autoDev.fallbackReviewMinutes`, and no prior fallback self-review (see **Fallback self-review** below). A PR with none of these is **quiescent** — waiting on the maintainer's review or merge. If every open PR is quiescent, step 2 has no work: fall through to step 3 (build). Otherwise advance that one PR with the loop below and stop.

**Draft PR** (a yielded partial build from step 3): resume the implementation first — finish the plan, run the full pre-flight, **behaviorally verify it (step 3, item 6)**, push, and mark it ready with `gh pr ready` (subject to the same verification gate — never mark ready on a failing or silently-skipped verification). Only then does the review loop below apply.

**Ready PR**: run one round of the review loop. The `coderabbit-review` skill describes the same loop in more depth — follow it when it is available (it may not be installed in a scheduled sandbox); the essentials below stand alone:

1. Fetch all four feedback surfaces: PR metadata + CI rollup, review summaries, inline review comments, and issue-style comments (`gh pr view`, `gh api repos/<config.repo>/pulls/N/reviews`, `.../pulls/N/comments`, `.../issues/N/comments`).
2. **CI red?** Fix CI first — check out the automated branch, fix, run the repo pre-flight (`config.commands.format`, `config.commands.build`, `config.commands.test`, `config.commands.typecheck` — skip any whose value is `null`), push.
3. **New feedback since the skill's last reply?** A thread is unaddressed if its newest comment lacks `config.autoDev.marker`. **Not feedback:** a third-party bot's auto-generated boilerplate — CodeRabbit rate-limit notices, walkthrough/summary comments, "finishing touches" checklists — identifiable by an HTML comment of the form `<!-- This is an auto-generated comment: … -->` in the body. Never reply to those and never count them as unaddressed feedback (a rate-limit notice matters only as the fallback-review trigger below). For real feedback, triage each item on its merits (CodeRabbit is not always right), fix valid items with **focused commits** (one logical fix per commit, conventional subjects), push, then **reply to every thread** — including ones you decline, with a one-sentence reason. Replies carry the marker.
4. **Human feedback** outranks bot feedback. If a human reviewer and CodeRabbit conflict, follow the human and say so in the reply to the bot.
5. **Scope creep requested in review?** Acknowledge in a reply, file a follow-up issue (it enters this same pipeline untriaged), link it, and keep the PR scoped.
6. **Nothing new** (no new comments, CI green, all threads answered): this PR is quiescent, waiting on the maintainer's review or merge — *unless it qualifies for a fallback self-review*. Check the fallback conditions below; if they all hold, do the self-review this tick and stop. Otherwise it isn't this tick's work; note it in the exit report and, since advancing it produced nothing, **fall through to step 3 (build)** — which builds the next Ready issue if the in-flight count is below `config.autoDev.maxPrsInFlight`, or itself falls through to triage.

**Fallback self-review** (when CodeRabbit can't keep up): CodeRabbit normally reviews within minutes of a PR going ready; when it hits its rate limits it stays silent or posts only a rate-limit/"in queue" notice, and the PR would otherwise sit with no review signal at all, blocking the maintainer's merge decision. The pipeline reviews its own PR to fill that gap. A PR qualifies when **all** of these hold:

- it is ready (not draft) and CI is green;
- it has **no review activity from any human or third-party bot** — no reviews, no inline review comments. A CodeRabbit rate-limit notice does _not_ count as review activity: it arrives as an **issue-style comment** (not a review) whose body contains the line `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->`, and it often quotes a short "next review available in N minutes" — `config.autoDev.fallbackReviewMinutes` (default 60) deliberately overshoots those short waits, giving CodeRabbit several chances first;
- it has been ready for review longer than `config.autoDev.fallbackReviewMinutes` (from the PR's `createdAt`, or the latest `ready_for_review` timeline event if it started as a draft);
- it has no prior fallback self-review — no marker comment containing the `## Fallback review` heading. **At most one fallback self-review per PR**; that comment is the cross-tick memory.

Then review it yourself:

1. **Fresh-eyes adversarial review.** The pipeline wrote this diff, so don't trust the memory of writing it — re-read the full diff from scratch (`gh pr diff`) against the approved plan on the issue. **If the repo's `code-review` skill is installed, apply its standards**; otherwise review for correctness, error handling, edge cases, test coverage and quality, the repo's documentation policy, and the rules in `config.guidelines`. Actively look for reasons the change is wrong, not confirmation that it's right.
2. **Fix what's real.** Valid findings get fixed now, in this tick: check out the automated branch, focused commits (one logical fix per commit), full pre-flight (`config.commands.*` — skip any whose value is `null`), push.
3. **Post one summary comment** in the fallback-review format below: what was examined, findings fixed (with commit SHAs), and observations left to the maintainer's judgement. "No findings" is a valid, useful outcome — say it plainly rather than inventing nitpicks.
4. **Never submit a formal GitHub review** — no approval, no request-changes, not even a comment-type review. The summary is an ordinary PR comment. A self-review is a signal for the maintainer, not independent sign-off, and must never be dressed up to look like one.

After the fallback review is posted, the PR counts as quiescent. If CodeRabbit later catches up and reviews the PR, its feedback flows through the normal item-3 handling — the fallback review never suppresses or substitutes for a real external review.

**Re-triggering CodeRabbit.** Its rate-limit notice offers two re-triggers: pushing new commits, or a `@coderabbitai review` comment. The fallback review's own fix-push therefore doubles as a re-trigger — desirable, since a real external review may follow. But **never post the `@coderabbitai review` trigger yourself**: a bare command comment from the maintainer's account without the marker would be classified by every later tick as human input (invariant 3), while adding the marker may break CodeRabbit's command parsing. The fallback summary instead reminds the maintainer they can trigger it manually.

### Step 3 — Build (only if under the in-flight cap)

Runs when the number of open automated PRs is **below `config.autoDev.maxPrsInFlight`** **and** there is a Ready issue (or a reclaimed step-1 orphan) to build — building approved, human-greenlit work outranks the triage pass below, so it never waits behind backlog grooming. If the in-flight count is already at the cap, or nothing is Ready, this step has no work; fall through to step 4. (With the default cap of `1`, "below the cap" means no automated PR is open — the classic single-PR gate.)

When the cap is above `1`, several PRs may be open at once, so each build still branches from a **fresh default branch** and is blind to the other open PRs' changes. Independent issues (disjoint files) are safe. When the oldest Ready issue obviously overlaps an already-open automated PR's files, prefer the next non-overlapping Ready issue to reduce merge-time conflicts and note the skip in the exit report — a best-effort heuristic, not a guarantee; the maintainer resolves any residual conflict at merge/rebase time.

Take the **oldest** eligible Ready issue (or a step-1 orphan). Then:

1. Swap labels: remove the Ready label, add the In-progress label.
2. Branch from a fresh default branch: `git checkout <config.defaultBranch> && git pull --ff-only && git checkout -b <config.autoDev.branchPrefix><N>-<short-slug>`.
3. Implement the approved plan as posted on the issue — the plan comment is the spec. Where reality diverges from the plan (an approach doesn't work, a file moved), prefer small sensible adaptation and document the deviation in the PR body; for a fundamental divergence, stop, comment on the issue explaining the blocker (marker), revert the label to Planned, and exit.
4. Follow the repo's documentation policy — docs updates ship in the same PR.
5. Run the full pre-flight: `config.commands.format`, `config.commands.build`, `config.commands.test`, `config.commands.typecheck` (skip any whose value is `null`). All green before pushing.
6. **Behaviorally verify the change.** Green pre-flight proves the code compiles and the suite passes; it does **not** prove the change does what the issue asked. When the change has a runnable surface — a CLI command, an endpoint, a UI, an observable side effect (i.e. **not** a docs-only, test-only, or pure-refactor diff) — exercise it end-to-end and observe the behavior:
   - **If the `/verify` skill is installed, invoke it** — it drives the affected flow and observes the result rather than trusting the diff. Also run any runtime/smoke gate the approved plan named, and any behavioral check `config.guidelines` documents.
   - **Verified** → note what you exercised and observed in the PR body's test plan.
   - **Observed wrong behavior** → that's a real defect, not a passing build: fix it, re-run pre-flight + verification, and only proceed once it passes. If it can't be made to pass within this run's budget, leave the PR a **draft** and say so in the exit report — don't mark it ready.
   - **Can't verify in this sandbox** (no runtime, or it needs a service the sandbox lacks) → don't block the pipeline: say so plainly in the PR body (`behavioral verification not run in sandbox — needs manual check`) and in the exit report, then proceed pre-flight-gated. **Never claim verified when verification didn't run** — the same "not scanned, never clean" honesty the audits follow.
7. Create the PR. **If the `create-pr` skill is installed, delegate to it** (it enforces the template, checklist, and AI-disclosure section, and runs the same pre-flight — but not behavioral verification, which is step 6's job). If it is not installed, run the pre-flight inline via `config.commands.*` (step 5 above) and open the PR directly with `gh pr create`. Honor `config.autoDev.openPrsAsDraft`: when `true`, open the PR as a draft (`gh pr create --draft`) and only mark it ready (`gh pr ready`) once it is complete, pre-flight is green, **and** behavioral verification has passed (or been honestly recorded as not-run-in-sandbox). The body must include `Fixes #<N>`, the marker line, and a note that this PR was produced by the auto-dev pipeline from the approved plan. **Apply the PR label** `config.autoDev.prLabel` (default `auto:pr`) to every PR the pipeline opens, so external tooling (e.g. CodeRabbit) can recognize and specially handle automated PRs — see **Labeling automated PRs** below for how and why the timing matters. This label is applied on top of, not instead of, whatever `create-pr` does; it never replaces the state machine's `auto:*` labels.
8. Comment on the issue (marker) linking the PR.

If the build cannot complete within this run's time/effort budget, push the WIP commits and open a **draft** PR (`gh pr create --draft`) before exiting — a bare pushed branch is invisible to the next tick, whose discovery queries only look at PRs and issues. The draft body still carries `Fixes #<N>` and the marker, plus a note that the build is incomplete and will be resumed, **and it carries the PR label like any other** (below) — a yielded build is still a PR the pipeline opened. Never mark a PR ready for review (`gh pr ready`) while pre-flight checks fail, or while behavioral verification is failing, or — for a change with a runnable surface — while it was skipped without recording *why* it couldn't run (a genuine sandbox limitation, honestly noted, is allowed to proceed; silently skipping is not). (When `config.autoDev.openPrsAsDraft` is `true`, every PR already opens as a draft, so this incomplete-build path is just the normal flow held back from `gh pr ready`.)

#### Labeling automated PRs

**Every** PR the pipeline opens carries `config.autoDev.prLabel` (default `auto:pr`) — the complete
build in item 7, the yielded WIP draft above, and any PR opened by delegating to `create-pr`. There
is no path that opens a PR without it. The label is what lets the maintainer configure external
review tooling to stand down on automated PRs (CodeRabbit's `reviews.auto_review.labels` takes
negative matches, e.g. `["!auto:pr"]`) and leave them to this pipeline's own review loop. Note that
the label is *only* for external tooling: the pipeline still identifies its own PRs by
`config.autoDev.branchPrefix` (step 0), so a missing label never confuses the state machine — it
just leaks a PR past the maintainer's tooling config.

**Apply it at creation, not afterwards.** External tooling reacts to the `opened` webhook within
seconds, and a label added after the fact does not retract a review that already started. So pass
it on the create call:

```bash
gh pr create --repo <config.repo> --base <config.defaultBranch> \
  --label "<config.autoDev.prLabel>" [--draft] --title "…" --body "…"
```

When delegating to `create-pr`, tell it to apply `config.autoDev.prLabel` on the `gh pr create`
call — it accepts caller-supplied labels for exactly this reason. Only fall back to
`gh pr edit <PR> --repo <config.repo> --add-label "<config.autoDev.prLabel>"` if a PR somehow got
opened without it.

**If the label doesn't exist**, `gh pr create --label` fails — and on some `gh` versions it fails
*after* pushing the branch, leaving no PR. Don't risk losing the build: confirm the label exists
before the first create, with one `gh api "repos/<config.repo>/labels" --paginate --jq '.[].name'`
(`--paginate`, not `gh label list`, whose 30-item default would report an existing label as
missing). A tick opens at most a few PRs, so that single call covers all of them. If it's missing,
open the PR **without** the label and record in the exit report that the PR is unlabeled and why.
Never create the label yourself (invariant 5) — `/doctor` reports it, `/bootstrap` creates it.

**Why proceed unlabeled rather than refuse to open the PR?** Because refusing strands the build. The
commits are already pushed, and a bare pushed branch is invisible to the next tick — its discovery
queries only look at PRs and issues. So a tick that stopped here would leave the work unreachable,
and the following tick would reclaim the issue as an orphan and rebuild it from scratch, repeating
for as long as the label is absent. The pipeline can't fix the cause itself (invariant 5 forbids
creating labels), so the stop would persist until a human intervened, with each tick discarding a
build. The unlabeled PR is the strictly better failure: the work survives, the exit report names the
problem, `/doctor` FAILs on the missing label, and step 0's re-stamp labels the PR on the first tick
after the label exists. The only cost is that external tooling may review that one PR — which is
simply the behavior from before this label existed, not a regression.

### Step 4 — Triage pass (bounded)

Walk eligible open issues oldest→newest. Act on at most **5** issues per tick (count only issues where you actually post/relabel; skipped issues are free). To stay cheap on idle ticks, only deep-read an issue's thread when it might have changed: a state-labelled issue whose `updatedAt` is no newer than the skill's own last marker comment on it has nothing new — skip it without re-reading (for a Parked issue, the baseline is the park-time label event, not a marker comment). For each issue that needs a look, read the full thread, then branch on its current state:

- **No state label** — assess whether the issue contains enough to plan from (clear problem, scoped outcome, no unresolved design fork):
  - _Plannable_ → draft an implementation plan (format below), post it as a comment, add the Planned label.
  - _Not plannable, and the gap is missing facts the maintainer can supply_ → post one comment asking the specific missing questions (numbered, concrete — not "please clarify"), add the Needs-info label.
  - _Not plannable because it needs a maintainer decision the skill can't make_ — a design fork that's theirs to resolve, a dependency on still-open work, or the issue body itself signals deferral ("not actionable yet", "revisit once X lands") → post a **park proposal** (format below): name the blocker, offer to park it, and say what would unblock it. Add the Needs-info label (the proposal is awaiting the maintainer's call). **The skill never parks on its own — it only proposes; the maintainer parks.**
- **Needs-info** — is there a _human_ comment (no marker, not a third-party bot) newer than the skill's last marker comment?
  - _No_ → skip silently. This is the "already asked, no reply" rule.
  - _Yes, and it says to park_ ("park it", "hold", "not now", "park", or a 👍 on a park proposal) → swap label to Parked.
  - _Yes, and it resolves the questions_ → draft and post the plan, swap label to Planned.
  - _Yes, but it raises new ambiguity_ → ask the follow-up (stay Needs-info) — but if this would be the third unanswered round-trip, stop asking and either propose parking or leave a final note that the issue needs maintainer attention.
- **Planned** — is there a _human_ comment (not a third-party bot) newer than the plan?
  - _Approval_ (e.g. "approved", "LGTM", "go ahead", "yes do it", a 👍-only reply) → swap label to Ready. "Approved, but change X" counts as approval: update the plan comment-thread with the revision first, then mark ready.
  - _Substantive feedback / objections_ → revise, post the updated plan (marker), stay Planned.
  - _A request to park_ ("not now", "let's hold this") → swap label to Parked.
  - _No reply_ → skip silently.
  - The human adding the Ready label directly is always approval, reply or not.
- **Parked** — the maintainer chose to hold this; it rests until they re-engage. The unblock baseline is **when the Parked label was applied**, _not_ the skill's last marker comment — so a rationale the maintainer records _at park time_ doesn't bounce the issue straight back out. Read the park time from the most recent Parked-label `labeled` event on the issue timeline:

  ```bash
  gh api "repos/<config.repo>/issues/<N>/timeline" --paginate \
    | jq -r --arg l '<config.autoDev.stateLabels.parked>' \
        '[.[] | select(.event=="labeled" and .label.name==$l)] | last | .created_at'
  ```

  Two unblock signals:
  - _A human comment (no marker, not a third-party bot) newer than the park time_ (the maintainer came back with detail or direction) → unblocked: remove the Parked label and re-triage it this tick as if freshly labelled (plan if now plannable, otherwise ask / re-propose).
  - _The human removed the label_ → it reappears with no state label and re-enters triage through the no-label branch; nothing special to do.
  - _Otherwise_ (still parked, no human comment after the park) → skip silently. **Never re-propose parking, re-ask, or re-plan a parked issue.**

- **Ready / In-progress** — leave for steps 1 and 3.

### Step 5 — Nothing to do

If no step had work: print "no work to be done" with the counts (open PRs awaiting human review/merge, issues awaiting replies, issues awaiting approval) and exit.

## Plan comment format

The literal `<!-- auto-dev -->` lines below stand in for `config.autoDev.marker` — emit the repo's
configured marker as the first line of every comment.

```markdown
<!-- auto-dev -->

## Proposed implementation plan

**Approach:** <2–4 sentences: what will change and why this approach>

**Changes:**

- `path/to/file.ext` — <what>
- <new files, tests, docs to update>

**Testing:** <unit tests to add/extend; manual verification if UI>

**Out of scope:** <explicitly excluded, if anything notable>

---

Reply with an approval ("approved", "LGTM", "go ahead") to queue this for implementation, reply with changes to revise the plan, or add the Skip label to opt this issue out of automation.
```

Plans follow the repo's "Implementation Planning" convention (plans live in the issue). Keep them honest about size — if an issue is too large to land as one reviewable PR, the plan should say so and propose the first slice only.

## Question comment format

```markdown
<!-- auto-dev -->

Before this can be planned for implementation, a few things need clarification:

1. <specific question>
2. <specific question>

---

Reply here and the next automation pass will pick it up, or add the Skip label to opt this issue out of automation.
```

## Park proposal comment format

Use this when an issue can't move forward because it needs a maintainer decision the skill can't make — not missing facts, but a judgement call, a design fork, or a dependency on other work. It **proposes** parking and waits; it never parks on its own.

```markdown
<!-- auto-dev -->

This isn't blocked on missing detail — it's waiting on a call that's yours to make:

<1–3 sentences naming the blocker: the design fork, the open dependency, or why the issue reads as deferred>

Want me to **park** it for now? Reply "park it" (or add the Parked label) and I'll leave it untouched until you remove the label or add more detail to the issue. If you'd rather move it forward, here's what would unblock it: <the specific decision or input needed>.
```

A parked issue is durable rest, not abandonment: the skill picks it back up the moment the maintainer removes the Parked label or adds a comment _after_ the park (a rationale left at park time is recorded but does not re-activate it — see the Parked triage branch).

## Fallback review comment format

Posted on a PR by step 2's fallback self-review. The `## Fallback review` heading is load-bearing — it is how later ticks detect that a fallback review already exists — so keep it verbatim. The first line is `config.autoDev.marker`.

```markdown
<!-- auto-dev -->

## Fallback review

No external review arrived within the review window (CodeRabbit appears rate-limited), so this is the pipeline's own fresh-eyes review of the diff against the approved plan. It is a **self-review** — treat it as a signal, not independent sign-off.

**Examined:** <scope: files/areas reviewed, and what they were checked against>

**Fixed in this review:**

- <finding> — fixed in <sha>
- _(or "nothing — no defects found")_

**For your judgement:**

- <observation or trade-off the maintainer should weigh before merging>
- _(or "nothing flagged")_

---

CodeRabbit can be re-run on this PR at any time with a `@coderabbitai review` comment.
```

## Exit report

Every tick ends by printing a structured report — it is the run's summary output (the scheduled task surfaces it; an interactive run shows it inline):

```text
auto-dev tick — <ISO timestamp>
step executed: <0-failed | 1-reconcile | 2-pr-advance | 3-build | 4-triage | 5-idle>
open auto PRs (<count>/<config.autoDev.maxPrsInFlight>): #<n> (<status>), … | none
actions:
- #123: asked 2 clarifying questions → needs-info
- #145: plan approved by reply → ready
- #151: proposed parking (design fork is the maintainer's call) → needs-info
- #152: maintainer replied "park it" → parked
- PR #210: fixed 2 CodeRabbit findings, replied to 4 threads, pushed <sha>
- PR #212: no external review after 60m — self-reviewed, fixed 1 finding (<sha>), posted fallback review
- #160: built approved plan → PR #211 (labeled auto:pr); verified via /verify (drove the new CLI flag, observed expected output) → marked ready
- #163: built approved plan → PR #212 (draft); behavioral verification not run in sandbox (needs a live DB) — flagged for manual check
blocked on human:
- PR #210 awaiting review/merge
- #145 ready to build once #210 merges
errors: <none | details>
```

## What not to do

- Don't merge, approve, or enable auto-merge on any PR.
- Don't submit a formal GitHub review of any kind on the pipeline's own PRs — the fallback self-review is a plain comment, never an approval or request-changes.
- Don't post more than one fallback self-review per PR, and don't self-review a PR that already has human or third-party review activity — the fallback exists only to fill the gap when CodeRabbit can't keep up.
- Don't reply to third-party bots' auto-generated notices (rate-limit, walkthrough, finishing-touches boilerplate), and don't post bot trigger commands like `@coderabbitai review` — a marker-less command comment reads as human input to every later tick.
- Don't create the `config.autoDev.prLabel` label yourself — only apply it; bootstrap creates it. If it's missing, note it and continue.
- Don't start a build while the open automated PR count is at `config.autoDev.maxPrsInFlight` (with the default cap of `1`, that means while any automated PR is open).
- Don't post a second question/plan when the previous one is still unanswered.
- Don't park an issue on your own initiative — only _propose_ parking; the maintainer parks by replying "park it" or adding the Parked label. (The Parked label is set by the skill solely on a human park reply, or by the human directly.)
- Don't re-propose parking, re-ask, or re-plan a Parked issue — it rests until the maintainer removes the label or adds a comment _after_ the park. Don't remove the Parked label yourself except when re-triaging it because the maintainer commented after parking.
- Don't touch issues labeled Skip or any label in `config.autoDev.excludedLabels`, and don't remove the Skip label ever.
- Don't apply or change non-state labels — categorization belongs to the `triage-issues` skill.
- Don't close issues, edit issue bodies, or modify human comments.
- Don't expand a PR's scope in response to review; file a follow-up issue instead.
- Don't bypass failing checks (`--no-verify`, skipping tests) to get a PR out.
- Don't mark a PR ready on green pre-flight alone when the change has a runnable surface — behaviorally verify it (step 3, item 6) first, or honestly record why it couldn't run in the sandbox. Never claim "verified" when nothing was actually exercised.
- Don't reach for any of the self-enforced hard prohibitions (invariant 5) — there is no external allowlist to catch you now, so the skill's own discipline is the only guardrail. If a tick seems to require one, stop and report it in the exit report instead.

## Related skills

- **review-queue** — the maintainer's daily console for this pipeline: the **human half** of auto-dev. It gathers everything blocked on the maintainer (the open automated PR, plans awaiting approval, questions and park proposals, parked issues, untriaged issues) and feeds their decisions back into the same state machine **as the human** (never with the marker). Use it to approve plans, answer questions, and park/merge.
- **create-pr** — the PR-creation skill step 3 delegates to when installed (template, CI gates, docs policy). It runs the command pre-flight but **not** behavioral verification — that stays auto-dev's own step-3 gate.
- **verify** — the harness skill step 3 (item 6) invokes when installed to drive the built change end-to-end and observe behavior before the PR is marked ready, rather than trusting a green pre-flight. May be absent in a scheduled sandbox; when it is, record the change as manually-verify-needed rather than claiming it verified.
- **code-review** — the review-standards skill step 2's fallback self-review applies when installed, to review the pipeline's own diff with fresh, adversarial eyes when no external review (CodeRabbit) arrives within `config.autoDev.fallbackReviewMinutes`. May be absent in a scheduled sandbox; when it is, fall back to the generic review checklist named in the fallback subsection.
- **bootstrap** — generates `.claude/maintainerd.json`, including the `autoDev` block this skill reads.
