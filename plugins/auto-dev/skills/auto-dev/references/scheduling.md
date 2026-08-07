# Scheduling a recurring tick

Guidance for whoever sets up the scheduled task — cadence, overlap, and which model tier to run on.
None of this is needed to execute a tick; SKILL.md carries everything the tick itself depends on
(step 1 states the orphan age-gate rule directly).

## Overlap & isolation

With no lockfile, the scheduled task must not overlap its own runs — set the cadence comfortably
longer than a typical tick (a tick that builds can take many minutes).

The label state machine is the backstop: work is claimed by swapping to In-progress, and the build
step is gated on the count of open automated PRs being below `config.autoDev.maxPrsInFlight`.

Two truly concurrent ticks could still race — both picking the same oldest Ready issue, or a fresh
tick mistaking a build that's mid-flight (labelled In-progress but not yet PR'd) for a crashed orphan
and rebuilding it. Step 1's **orphan age-gate** closes the second race (only reclaim a PR-less
In-progress issue once its label event is older than `config.autoDev.orphanReclaimMinutes`); for the
first, still don't schedule tighter than a build tick can finish.

Each scheduled run is its own disposable sandbox, so runs never share a working tree.

## Model tier

A tick drafts plans, writes code, and adjudicates review feedback — schedule it on the **`capable`**
tier; don't down-tier to save tokens on its triage pass, because the *same* run also builds (a skill
can't switch its own model mid-run). The read-only **`dry-run`** mode does no judgment or code-gen
and is safe on the **`fast`** tier.

See [`model-tiers.md`](../../../references/model-tiers.md) for the full tier guidance across the
maintainerd suite.
