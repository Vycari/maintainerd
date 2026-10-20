# maintainerd

Generic, repo-agnostic Claude Code plugins (bootstrap, doctor, create-pr, address-review, audits,
auto-dev, journal, ...) that any repo can load as a plugin marketplace. See `README.md` for the
plugins and `plugins/core/references/config-schema.md` for the `.claude/maintainerd.json` contract.
Keep the mechanism code free of any one organisation's repo names; per-repo values belong in a
consuming repo's config, not in a skill.

**Review.** This repo is on first-line review (`review.mode: "first-line"` in
`.claude/maintainerd.json`, the repo's own instance config for the generic `review.*` keys): an
automated first-line reviewer (`vycari-review[bot]`) reviews first, agents answer its findings and
then the final gate's on the capable tier, and agents never request a final-gate review themselves.
The first-line reviewer requests the final gate (`review.rereviewCommand`) once, when it is happy,
and a human may too. The final gate at `review.approvalThreshold` is still the merge gate. Agents
never merge.
