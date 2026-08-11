# maintainerd-core

The config layer every other maintainerd plugin depends on. `bootstrap` writes the contract;
`doctor` tells you why a skill isn't behaving. Install this first — the other plugins read the file
it generates and stop with "run `/bootstrap`" if it's missing.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`bootstrap`](skills/bootstrap/SKILL.md) | Generate `.claude/maintainerd.json` and scaffold `.claude/guidelines/{coding,testing,invariants}.md`. Inspects the repo for language, slug, branch, paths and commands; asks only about what's genuinely ambiguous. Idempotent — a re-run never clobbers hand-edited guideline prose. | "bootstrap this repo", "set up maintainerd" |
| [`doctor`](skills/doctor/SKILL.md) | Validate the contract and everything it points at: the JSON parses and conforms, paths and commands resolve, the configured GitHub labels exist, the daily-update roster names only installed skills. Read-only PASS/WARN/FAIL; offers to create missing labels with `--fix`. | "run doctor", "why isn't <skill> working" |

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

Skills that read text authored outside the repo follow the shared contract in
[`references/untrusted-input.md`](references/untrusted-input.md); scheduled skills note which model
tier they want in [`references/model-tiers.md`](references/model-tiers.md).

## Install

```text
/plugin marketplace add Vycari/maintainerd
/plugin install maintainerd-core@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
