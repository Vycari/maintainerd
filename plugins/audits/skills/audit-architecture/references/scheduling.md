# Scheduling — audit-architecture

This skill is **not** part of the `daily-update` meta-skill, because `daily-update` bundles its work into one PR and this skill explicitly opens many. Schedule it as its own slot (e.g. nightly at 2am local time) via the `schedule` skill. The schedule should invoke this skill directly; there is no autonomous-prompt variant — pass a literal `/audit-architecture` or equivalent.

If the user is running short on `/schedule` slots and wants to combine with `daily-update`, the right consolidation is to have this skill run *first*, produce its PRs/issues, and then let `daily-update` run its own one-PR sweep on top — but they remain logically separate runs from the maintainer's point of view.

**Model tier:** DRY/abstraction judgment, invariant drift, and PR-vs-issue routing are judgment-heavy — schedule this on the **`capable`** tier (a smaller model mis-routes and over-files). See [`../../../references/model-tiers.md`](../../../references/model-tiers.md).
