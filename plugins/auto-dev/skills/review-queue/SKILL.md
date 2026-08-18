---
name: review-queue
description: The maintainer's daily console for the auto-dev pipeline — gather everything blocked on you, present a worklist, loop executing your decisions against the `auto:*` state machine as you (never with the bot marker), until the queue drains. Never merges on its own; never builds issues. Use when the user says "review the pipeline", "what needs my input", "process the auto-dev queue", "check what auto-dev is waiting on", "approve/answer/park #N", "let's do the daily review", or similar.
---

# Review queue: the maintainer's console for the auto-dev pipeline

The **auto-dev** skill (this plugin's machine half) runs headless on a cron schedule and advances the
issue-to-PR pipeline — triaging, planning, building, and answering review feedback. It deliberately
stops at the two gates only a human can clear: **plan approval** and **merge**, plus anything it flags
as needing your judgement (clarifying questions, park proposals, design forks).

This skill is the **human half**: a single interactive session where you clear those gates. It
surfaces everything blocked on you, you decide item by item, and it writes your decisions back into
the state-machine labels and issue comments that the next cron tick reads. Think of it as processing
an inbox to empty.

The label state machine, eligibility rules, and comment-classification conventions are owned by the
**auto-dev** skill — read it for the authoritative semantics. This skill only **drives** that machine
from the human side; it never duplicates the machine's own work (it does not triage-plan or build).

## Load the repo config

Before anything else, read `.claude/maintainerd.json` from the repo root (see
[`../../references/config-schema.md`](../../references/config-schema.md) for the full
contract). If it does not exist, **stop** and tell the user:

> This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

Don't guess values or hardcode another repo's settings. If `config.autoDev.enabled` is `false`,
**stop** and tell the user that the auto-dev / review-queue pipeline is disabled for this repo. The
keys this skill needs:

- `config.repo` — GitHub `owner/name`, passed to every `gh ... --repo`.
- `config.autoDev.enabled` — must be `true` for this skill to run.
- `config.autoDev.marker` — the HTML comment the pipeline stamps on its **own** comments. This skill
  posts as the human and **must never** emit this marker (see Invariant 1).
- `config.autoDev.stateLabels.*` — the `auto:*` label names this skill flips. The state → config-key
  mapping is below.
- `config.autoDev.excludedLabels` — labels that exclude a new issue from auto-building.

### State → config-key table

This skill never hardcodes a label literal — every state name below maps to a config key. (Same
mapping the **auto-dev** skill uses.)

| State (this doc)  | Config key                             | Example label      |
| ----------------- | -------------------------------------- | ------------------ |
| needs-info        | `config.autoDev.stateLabels.needsInfo` | `auto:needs-info`  |
| planned           | `config.autoDev.stateLabels.planned`   | `auto:planned`     |
| ready             | `config.autoDev.stateLabels.ready`     | `auto:ready`       |
| in-progress       | `config.autoDev.stateLabels.inProgress`| `auto:in-progress` |
| parked            | `config.autoDev.stateLabels.parked`    | `auto:parked`      |
| skip              | `config.autoDev.stateLabels.skip`      | `auto:skip`        |

The bot comment marker is `config.autoDev.marker` (e.g. `<!-- auto-dev -->`). Branches the pipeline
opens are prefixed with `config.autoDev.branchPrefix` (e.g. `auto/issue-`).

## Invariants — read these first

1. **You are the human. Never use the bot marker.** Every comment this skill posts is _your_ input to
   the pipeline. It MUST NOT begin with `config.autoDev.marker` and MUST NOT imitate the pipeline's
   comment templates. auto-dev classifies any comment carrying `config.autoDev.marker` as its _own_
   output and ignores it as human input — so a marked comment would make your decision **invisible**
   to the next tick. This is the single most important rule.
2. **Never merge automatically.** Merging is your deliberate act and is what unblocks the pipeline for
   the next build. The skill may run `gh pr merge` ONLY when you explicitly tell it to merge a
   specific PR in this session, and even then it confirms first. Default posture: it surfaces the PR
   and you merge (in the browser or by explicit instruction). Never enable auto-merge.
3. **You decide; the skill executes.** It never invents or infers a decision you didn't state. For
   each item it shows the context and waits for your call, then performs exactly the state transition
   you asked for.
4. **Humans always win, but don't fight a tick mid-flight.** Your label/comment edits are always safe
   (the pipeline treats human label changes as authoritative). But don't implement/build issues from
   this skill — that's auto-dev's job. If you want to take an issue over yourself, the skill adds the
   skip label (`config.autoDev.stateLabels.skip`) first so a scheduled tick can't build it
   concurrently.
5. **Stay within the `auto:*` namespace.** Don't add or change non-`auto:*` labels (categorization
   belongs to the `triage-issues` skill). Don't remove the skip label unless you say so. Don't close
   human issues or edit human comments without your explicit instruction.

## The session loop

Repeat until the queue is **drained** (nothing is blocked on you — every open item is closed, in the
ready/in-progress state, or resting in a state that's waiting on the _bot_, not you) or you say
**"done"** / "that's enough for today".

### 1 — Gather (one batch of read-only calls)

```bash
gh auth status >/dev/null && gh repo view "$REPO" --json nameWithOwner   # $REPO = config.repo

# Open automated PR(s): the merge gate. $PREFIX = config.autoDev.branchPrefix
gh pr list --repo "$REPO" --state open \
  --json number,title,headRefName,reviewDecision,mergeable,updatedAt \
  | jq --arg p "$PREFIX" '[.[] | select(.headRefName | startswith($p))]'

# Everything in a human-gated label state, plus brand-new untriaged issues
gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,title,labels,createdAt,updatedAt --search "sort:created-asc"
```

Bucket the open issues by their `auto:*` state (per the table above). For new/untriaged ones, apply
the same eligibility exclusions auto-dev uses — the skip label
(`config.autoDev.stateLabels.skip`) plus everything in `config.autoDev.excludedLabels` (e.g. `epic`,
`question`, `wontfix`, `duplicate`, `invalid`) — and surface the rest. For each open automated PR
(there may be several when `config.autoDev.maxPrsInFlight` is above `1`), also pull its CI + review
surfaces only when you choose to act on it (don't fetch all threads for every item up front — keep
the gather cheap).

To keep the list signal-dense, note how long each item has waited (from `updatedAt` / the relevant
comment time) so stale items stand out.

**Also check the planned bucket for dropped transitions.** An issue you already approved should not
still be sitting at planned — but it will be if a previous session posted the approval and never
applied the label (see step 3), or if a tick read only the newest comment and missed an approval
buried under later ones. These are the worst items in the queue precisely because they look
finished: the approval is on the record, so nothing about the issue reads as blocked, and no tick
will ever build it. Scan the planned issues' comments for a human approval, and bucket any hit
separately — it needs one label flip, not another decision:

```bash
gh api graphql -f query='query { repository(owner:"<owner>", name:"<name>") {
  i123: issue(number: 123) { number title comments(last: 30) {
    nodes { author { login } createdAt body } } }
} }' | jq -r '.data.repository | to_entries[] | .value as $i
  | [$i.comments.nodes[]
     | select((.body | startswith("<!-- auto-dev -->")) | not)
     | select(.body | test("(?i)^\\s*(approved|lgtm|ship it|go ahead)"))]
  | select(length > 0) | "#\($i.number)  \(.[-1].createdAt[0:10])"'
```

Two hits are **not** dropped transitions, and confirming which is which is the point of surfacing
them rather than flipping them blind — read each thread before acting:

- an approval the maintainer later **withdrew or reshaped** ("changing my mind on the split") — it
  is correctly at planned, awaiting a re-plan;
- a **conditional** approval ("build this after #N lands") whose condition is still unmet — also
  correctly held, and the pipeline re-checks it each tick.

Everything else is a dropped transition. Present it with the approval's date and wording so the
maintainer can confirm it still stands, and, where the approval named a dependency, resolve that
dependency's current state before presenting so the item arrives with its answer attached.

### 2 — Present the worklist

One line per item, grouped and prioritized so the most pipeline-unblocking work is first. Lead each
line with the number and a 3–8 word gist of what's blocked on you:

```text
Pipeline review — <date>

🔴 PRs awaiting your review/merge (each merge frees a build slot)
  • PR #986  per-use-case thinkingLevel — CI green, CodeRabbit approved, mergeable

🟠 Plans awaiting approval (planned)              — approve → queues a build
  • #663  AgentLoop streaming follow-ups — plan posted 1d ago
  • #670  obsidian:// URI handler — v1-slice plan posted 1d ago

🟡 Questions / park proposals awaiting you (needs-info)
  • #641  SVG support — 3 questions (rasterize now vs. block on #536)
  • #447  Gemini API capabilities — 3 questions, 2d unanswered

🟢 Parked — revisit? (parked)
  • (none)

⚪ New / untriaged — weigh in before a tick plans it
  • #990  bug: completions stall on large notes

Reply with an item and your decision — e.g. "#663 approved", "#641 use client-side
rasterization now", "park #447", "skip #990", "merge #986" — or "done" to end.
```

(The parenthetical state names above — planned, needs-info, parked — render with the repo's actual
label literals from `config.autoDev.stateLabels.*`.)

If nothing is blocked on you, say so plainly (e.g. "Queue's clear — the only open item is PR #986
waiting on you to merge" or "Nothing needs you right now") and stop.

### 3 — Act on your reply

Parse the item number and your stated decision, map it to the transition below, and execute it. Post
comments **as you, with no marker** (never `config.autoDev.marker`). Confirm before anything
outward-facing-and-hard-to-reverse (merge, close, applying the skip label); routine label flips and
comments that carry your stated decision can proceed without a second prompt. If your reply is
ambiguous (e.g. an approval that also reshapes the plan), ask one quick disambiguating question rather
than guessing.

When you give your answer/feedback in chat, the skill posts a faithful rendering of _your words_ as
the issue/PR comment — it doesn't editorialize, summarize away your intent, or add pipeline
boilerplate.

**Verify every state transition after writing it.** A decision reaches the pipeline as a _label_;
the comment is only the rationale. So a run that posts "Approved — go ahead" and then fails to
apply the label — interrupted session, a `gh` error swallowed mid-loop, a batch that stopped
halfway — leaves an issue that reads as approved to every human and is invisible to every tick. It
rests at Planned forever, and nothing downstream ever notices.

So after each transition, read the labels back and confirm the new state stuck and the old one is
gone:

```bash
gh issue edit <N> --repo "$REPO" --add-label "<new-state>" --remove-label "<old-state>"
gh issue view <N> --repo "$REPO" --json number,labels \
  | jq -r '"#\(.number): \([.labels[].name | select(startswith("auto:"))] | join(", "))"'
```

The states are **mutually exclusive** — a transition swaps, it never accumulates. An issue showing
two `auto:*` states is a half-applied transition; finish it. If a read-back doesn't match what you
intended, say so and retry rather than reporting the decision as done.

### 4 — Re-gather and re-present

Pull fresh state and show the now-shorter list. Loop.

### 5 — Stop and summarize

When drained or dismissed, print a short session summary: what you decided, what's now queued to build
(the ready label, oldest-first), what's still waiting on the bot, and anything still genuinely needing
you later.

## Decision → action map

**A plan (planned — `config.autoDev.stateLabels.planned`):**

- **Approve** ("approved", "lgtm", "go", "ship it") → swap the planned label for the ready label
  (`config.autoDev.stateLabels.ready`); the states are exclusive, so remove planned in the same
  edit. The oldest ready issue builds on the next tick whose open-PR
  count is below the in-flight cap (`config.autoDev.maxPrsInFlight`; with the default of `1`, that
  means the next tick with no automated PR open).
- **Approve with a tweak** ("approved, but use X") → post your tweak as a plain comment, then swap to
  the ready label (the build adapts to the latest comment). If the change is large enough to reshape the
  plan, instead post the change and leave the planned label so the next tick re-plans — ask which you
  want if it's unclear.
- **Request changes** → post your feedback as a comment; leave the planned label (next tick revises
  the plan).
- **Not now** → parked (`config.autoDev.stateLabels.parked`, hold, revisit later) or skip
  (`config.autoDev.stateLabels.skip`, opt out entirely), per your words. If you give a reason, record
  it the park-safe way (below).
- **I'll do this one** → add the skip label (so a tick won't build it concurrently); you implement it
  normally and remove the skip label later to hand it back, or close it via your PR.

**A question or park proposal (needs-info — `config.autoDev.stateLabels.needsInfo`):**

- **Answer it** → post your answer as a comment; the next tick incorporates it (plans, or asks a
  follow-up).
- **Park it** → add the parked label (it rests until you remove the label or add a comment _after_ the
  park). If you give a reason, record it the park-safe way (below).
- **Skip** → add the skip label.

**A parked issue (parked — `config.autoDev.stateLabels.parked`):**

- **Unpark with direction** → remove the parked label and post the new detail/decision as a comment;
  it re-enters triage with your input.
- **Decide the design** → post your decision; either remove the parked label to let the bot re-plan,
  or, if you've fully specced it, write the plan yourself and set the label you want (planned for the
  bot to confirm, or straight to ready).
- **Keep holding** → leave it; move on.

> **Parking with a reason — order matters.** auto-dev keys a parked issue's unblock off **when the
> parked label was applied** (the label event on the timeline). So when you park _with_ a rationale,
> post the reason as a plain comment **first, then apply the label** — the comment ends up older than
> the park event, so it's recorded without bouncing the issue back into triage. Apply the label first
> and comment after, and the next tick reads that comment as "the maintainer came back" and un-parks
> it. (Unparking later is exactly this: a comment _after_ the park, or removing the label.)

**A new / untriaged issue:**

- **Pre-empt** → skip (bot never touches it), parked (hold), or hand-write a plan + planned/ready.
- **Add detail** → comment, then leave it for the next tick to triage.
- **Leave it** → do nothing; the bot will triage it on a future tick.

**The open automated PR:**

- **Surface** its CI rollup, CodeRabbit/human review threads, and mergeable state (`gh pr view`,
  `gh pr checks`, the reviews/comments APIs — all with `--repo config.repo`). **Flag the review
  provenance:** if the PR's only review signal is the pipeline's own **fallback self-review** (an
  `auto:pr`-labeled PR whose sole review is a marker comment headed `## Fallback review`, with no
  external CodeRabbit or human review), say so plainly — "self-reviewed only, no external review" —
  so you give it a closer look before merging. A self-review is a signal, not independent sign-off.
- **Review deeper** → hand off to the user-level `coderabbit-review` skill or `/code-review`; don't
  reimplement a review here.
- **Leave feedback** → post review comments **as you** (no marker). The next tick addresses them and
  replies.
- **Merge** → only on your explicit instruction for that PR, with a confirmation. After a merge, offer
  to clear a stale in-progress label (`config.autoDev.stateLabels.inProgress`) on the fixed issue (the
  next reconcile tick would otherwise do it).
- **Close without merging** → only if you say so; the next tick will treat that as rejecting the
  approach.

## What not to do

- Never add `config.autoDev.marker` to anything you post, and never mimic the pipeline's
  plan/question/park templates — your comments must read as human input or the pipeline ignores them.
- Never merge, close, or apply the skip label without your explicit say-so (and confirm merges/closes
  first). Never enable auto-merge.
- Never build or implement an issue from this skill — feed the decision to the pipeline, or take it
  over manually after adding the skip label.
- Never change non-`auto:*` labels; never remove the skip label unless told.
- Never post a decision you inferred rather than one the maintainer stated. When unsure, ask.

## Example turn

> **Worklist shows #663 (plan), #670 (plan), #641 (question), PR #986.**
>
> **You:** "#663 approved. For #641 let's do client-side rasterization now, cap at 2048px. Merge #986."
>
> **Skill:**
>
> - #663 → swaps planned for the ready label, reads the labels back to confirm (queued to build).
> - #641 → posts your comment ("Let's go with client-side rasterization now, capped at 2048px on the
>   longest edge…") as you, no marker; leaves the needs-info label so the next tick re-reads it and
>   plans. (Or, if you'd rather, swaps to no-label to force a fresh triage — it asks if unsure.)
> - PR #986 → confirms ("Merge #986 into <config.defaultBranch>?"), then `gh pr merge`, then offers to
>   clear the in-progress label on #621.
> - Re-presents the shorter list.

## Related skills

- **auto-dev** — the automated half of this pipeline (the cron-driven triage → plan → build →
  address-review machine). It owns the `auto:*` state machine and the comment-classification
  conventions this skill drives.
- **bootstrap** — generates `.claude/maintainerd.json`, including the `config.autoDev` block this
  skill reads.
