# Scheduling a recurring drain

Guidance for whoever sets up the scheduled task. None of this is needed to execute a run.

## Cadence

Schedule it on its own slot — hourly to a few times a day suits most repos, since Dependabot's own
schedule sets the supply. A tick against an empty queue is one API call, so a tight cadence is cheap.

It is **not** part of `daily-update`: that skill bundles its sub-skills' output into one PR, and this
skill merges rather than producing a diff.

Pair it with `audit-deps` on a slower cadence: this skill drains the bumps Dependabot proposes,
`audit-deps` covers what Dependabot doesn't (unused, phantom, deprecated, licenses).

## One pass per external tick, or `drain`

There are two ways to get a queue drained over time, and the choice belongs to whoever schedules the
skill.

**One pass per tick (the default, and what a supervisor should do).** The scheduler fires
`/dependabot` on its cadence; each run executes one pass and exits. Draining across a rebase happens
*between* runs. This is what a job runner — a cron entry, a CI schedule, a supervisor process that
dispatches the skill per repo — should use, because a pass is short, bounded, and stateless: it
re-reads GitHub from scratch every time, so nothing is lost if a run is killed mid-pass and nothing
has to be handed from one run to the next. A supervisor that meters concurrency (one job slot, a
per-repo cooldown, a daily cap) gets its metering back promptly instead of parking it inside a
sleeping agent.

Cadence for that mode wants a floor as well as a ceiling: below `rebaseNudgeMinutes` a new pass can
only re-observe a rebase that is still in flight, so it costs an invocation to learn nothing. The
skill's own `rebaseNudgeMinutes` (default 30) is a sound cooldown.

**`drain` mode** repeats the pass in-process, sleeping `drainPollMinutes` between passes for up to
`drainMaxMinutes`. Use it when a human wants the queue cleared *now*. Don't use it as the scheduled
form: it holds whatever slot the run occupies for up to 90 minutes, mostly asleep, and a supervisor
that kills it has to reason about a partially-completed drain rather than a completed pass.

Either way the caps are **per invocation**, not per pass, and a supervisor's own limits stack on top
of them rather than replacing them — neither is a distributed semaphore ("Overlap & isolation" in
SKILL.md).

On a merge-queue branch, one pass per tick is also what makes the serialization work: a pass enqueues
at most one PR per file group and exits, and the *next* tick is what notices the queue merged it and
releases the group ([`merge-queue.md`](merge-queue.md)).

## Model tier

Gating and merging is mechanical — read check conclusions, compare version strings, call
`gh pr merge` — so the drain itself is safe on the **`fast`** tier. Its one judgment-heavy step is
diagnosing a broken update (the failure pass), which is the exception the subagent lever exists for:
delegate *that* to a `capable` subagent rather than up-tiering the whole routine.

See [`model-tiers.md`](../../../references/model-tiers.md) for the full tier guidance across the
maintainerd suite.
