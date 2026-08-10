# Scheduling — audit-tests

Schedule this as its own slot (a few times a day is fine given the silent-on-clean + low-cap design), invoking it directly (`/audit-tests` or equivalent) — there is no autonomous-prompt variant. It is intentionally **separate** from both `daily-update` (which bundles its work into one PR; this skill opens discrete ones) and `audit-architecture` (which owns the source side). Running both audits is fine; they don't overlap and each dedups against its own label/branch prefix.

**Model tier:** "is this mock decorative? is this assertion actually weak?" is judgment — schedule on **`capable`**, or on a **`mid`** rung if the repo defines one (this runs several times a day, so the cost trade is real). See [`../../../references/model-tiers.md`](../../../references/model-tiers.md).
