# audits

Six scheduled sweeps that find work and file it as discrete units — one PR or one issue per finding,
never bundled. Built to run unattended several times a day, which is why they are deliberately
capped, strict about dedup, and **silent on clean**: a run that finds nothing produces no PR, no
issue, and no report. Absence is the signal.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`audit-architecture`](skills/audit-architecture/SKILL.md) | Nightly tech-debt sweep of the source: oversized modules, DRY/typing problems, dead exports, and drift from the repo's own `invariants.md`. | scheduled |
| [`audit-tests`](skills/audit-tests/SKILL.md) | Test-suite health: coverage gaps on tested modules, decorative mocks, weak assertions, brittle strategy, rotting skips. | scheduled |
| [`audit-security`](skills/audit-security/SKILL.md) | Whole-tree + dependency + git-history sweep: CVEs, committed secrets, permissive defaults. Complements `/security-review`, which owns code patterns in the pending diff. | scheduled |
| [`audit-deps`](skills/audit-deps/SKILL.md) | Dependency *health* — outdated, deprecated, unused, phantom, lockfile drift, licenses. Vulnerabilities belong to `audit-security`. | scheduled |
| [`audit-design-docs`](skills/audit-design-docs/SKILL.md) | Check design/planning docs still describe the code as built. | scheduled |
| [`audit-product-docs`](skills/audit-product-docs/SKILL.md) | Check user-facing and contributor docs still match the code. | scheduled |

## Two properties worth knowing before you schedule these

**Honest about coverage.** A category whose scanner isn't installed is reported "not scanned", never
"clean". A green audit has to mean "we looked", not "we couldn't look".

**Pattern promotion.** When the same specific problem gets fixed repeatedly, the guideline-checking
audits stop re-fixing it and file one human-gated issue proposing it become a rule in
`config.guidelines` — or, if the rule already exists and keeps being violated, a mechanical guard.
The mechanism is in [`references/pattern-promotion.md`](references/pattern-promotion.md).

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
/plugin install audits@maintainerd
```

Source and issues: https://github.com/allenhutchison/maintainerd
