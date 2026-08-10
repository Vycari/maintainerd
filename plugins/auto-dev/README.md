# auto-dev

The autonomous issue-to-PR pipeline, and the console for watching it. State lives entirely in
configurable `auto:*` GitHub labels, so the pipeline has no memory beyond what you can see and
change yourself.

**It never merges.** The maintainer keeps two gates: plan approval (nothing is built without an
approved plan) and merge (exclusively yours).

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`create-issue`](skills/create-issue/SKILL.md) | The front door — turn a rough request into an issue well-formed enough for the pipeline to pick up: crisp problem statement, acceptance criteria, file pointers. | "file an issue for X" |
| [`auto-dev`](skills/auto-dev/SKILL.md) | One tick of the state machine: triage issues for readiness, draft plans for approval, build the oldest approved issue into a PR, address review feedback. Does the single highest-priority piece of work and exits. | scheduled, or "/auto-dev" · "/auto-dev dry-run" |
| [`review-queue`](skills/review-queue/SKILL.md) | The human half — what's waiting on you, what the pipeline is blocked on, and what it did while you weren't looking. | "what's in the review queue" |

## Reading the pipeline

Ticks are cheap and stateless; "waiting" is just what happens between them. If something looks
stuck, the labels are the truth — a human changing a state label always wins, and the next tick
respects it rather than correcting it back.

Per-topic detail lives beside the skill:
[`triage.md`](skills/auto-dev/references/triage.md),
[`fallback-review.md`](skills/auto-dev/references/fallback-review.md),
[`pr-labeling.md`](skills/auto-dev/references/pr-labeling.md),
[`comment-formats.md`](skills/auto-dev/references/comment-formats.md),
[`scheduling.md`](skills/auto-dev/references/scheduling.md).

## Configuration

Every skill here reads the repo's config contract — `.claude/maintainerd.json` plus
`.claude/guidelines/*.md`, checked into the consuming repo. Run `/bootstrap` (from
**maintainerd-core**) to generate it. The canonical schema ships with this plugin at
[`references/config-schema.md`](references/config-schema.md).

Skills that read text authored outside the repo follow the shared contract in
[`references/untrusted-input.md`](references/untrusted-input.md); scheduled skills note which model
tier they want in [`references/model-tiers.md`](references/model-tiers.md).

## Install

```text
/plugin marketplace add allenhutchison/maintainerd
/plugin install auto-dev@maintainerd
```

Source and issues: https://github.com/allenhutchison/maintainerd
