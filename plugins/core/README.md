# maintainerd-core

The config layer every other maintainerd plugin depends on. `bootstrap` writes the contract;
`doctor` tells you why a skill isn't behaving. Install this first — the other plugins read the file
it generates and stop with "run `/bootstrap`" if it's missing.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`bootstrap`](skills/bootstrap/SKILL.md) | Generate `.claude/maintainerd.json` and scaffold `.claude/guidelines/{coding,testing,invariants}.md`. Inspects the repo for language, slug, branch, paths and commands; asks only about what's genuinely ambiguous. Adopts the coverage ratchet: measures `origin/<defaultBranch>` on a fresh worktree and records `coverage.floor`. Idempotent — a re-run never clobbers hand-edited guideline prose. | "bootstrap this repo", "set up maintainerd" |
| [`doctor`](skills/doctor/SKILL.md) | Validate the contract and everything it points at: the JSON parses and conforms, paths and commands resolve, the configured GitHub labels exist, the daily-update roster names only installed skills, and the coverage ratchet holds. Read-only PASS/WARN/FAIL; offers to create missing labels with `--fix`. With `--workspace`, validates an umbrella repo's `workspace` block and runs the whole check once per repo it lists. | "run doctor", "why isn't <skill> working" |

## Why `invariants.md` is the file that matters

`bootstrap` can detect your language, paths and commands. It cannot detect the load-bearing rules
that make *this* repo correct — "secrets are `SecretStr`", "use `plugin.logger`, never `console`".
Those go in `.claude/guidelines/invariants.md`, and `audit-architecture` checks diffs against them.
The scaffold leaves TODOs there on purpose; it's the one file that needs you.

## Configuration

Every skill here reads the repo's config contract — `.claude/maintainerd.json` plus
`.claude/guidelines/*.md`, checked into the consuming repo. Run `/bootstrap` (from
**maintainerd-core**) to generate it. The canonical schema ships with this plugin at
[`references/config-schema.md`](references/config-schema.md).

An umbrella repo — one that holds other repos rather than code — adds a top-level `workspace`
block naming the repos it covers. That block is the one repo list `doctor`, `review-queue` and
`daily-update` fan out over with `--workspace`, and it's a versioned contract other tools read
directly. The schema documents it, with a complete example at
[`references/example-workspace.json`](references/example-workspace.json).

## The coverage ratchet

A repo's coverage floor is one whole number in `.claude/maintainerd.json` — `coverage.floor`,
measured from the repo as it actually is and thereafter allowed only to rise. There is no
aspirational target to hit before the gate can be switched on, and lowering the number is a
reviewable diff to a tracked file rather than an invisible edit to a workflow.

This plugin ships the two shell steps that make it work, both bash 3.2 + `jq`, no other dependency:

| Script | What it does |
| --- | --- |
| [`scripts/coverage-adapt.sh`](scripts/coverage-adapt.sh) | Normalizes pytest-cov (`.totals.percent_covered`) or vitest/istanbul `json-summary` (`.total.lines.pct`) into the one shape every consumer reads: `{"metric": "lines", "percent": <float>}`. |
| [`scripts/coverage-check.sh`](scripts/coverage-check.sh) | The gate. Fails the job when the measured percentage is below `coverage.floor`; equal passes. Fails closed on a missing, malformed or un-normalized summary. |

`bootstrap` vendors both into the consuming repo at `.claude/maintainerd/`, since CI runs without the
plugin installed. The contract, the workflow snippet, and the profile-side `coverage` policy are in
[`references/config-schema.md`](references/config-schema.md).

Skills that read text authored outside the repo follow the shared contract in
[`references/untrusted-input.md`](references/untrusted-input.md); scheduled skills note which model
tier they want in [`references/model-tiers.md`](references/model-tiers.md).

## Install

```text
/plugin marketplace add Vycari/maintainerd
/plugin install maintainerd-core@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
