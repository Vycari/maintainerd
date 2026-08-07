# Scheduling a recurring drain

Guidance for whoever sets up the scheduled task. None of this is needed to execute a run.

## Cadence

Schedule it on its own slot — hourly to a few times a day suits most repos, since Dependabot's own
schedule sets the supply. A tick against an empty queue is one API call, so a tight cadence is cheap.

It is **not** part of `daily-update`: that skill bundles its sub-skills' output into one PR, and this
skill merges rather than producing a diff.

Pair it with `audit-deps` on a slower cadence: this skill drains the bumps Dependabot proposes,
`audit-deps` covers what Dependabot doesn't (unused, phantom, deprecated, licenses).

## Model tier

Gating and merging is mechanical — read check conclusions, compare version strings, call
`gh pr merge` — so the drain itself is safe on the **`fast`** tier. Its one judgment-heavy step is
diagnosing a broken update (the failure pass), which is the exception the subagent lever exists for:
delegate *that* to a `capable` subagent rather than up-tiering the whole routine.

See [`model-tiers.md`](../../../references/model-tiers.md) for the full tier guidance across the
maintainerd suite.
