# deps-flow

Drains the Dependabot queue unattended.

> **This is the exception to the suite's "never auto-merges" rule.** Every other maintainerd skill
> stops at the merge gate. `dependabot` merges dependency PRs that pass a strict gate — all checks
> concluded green, no requested changes, bump level within your policy. It requires an explicit
> `depsFlow.enabled: true`; an absent config block means *off*, never *defaults*.

Run `/dependabot dry-run` first. It executes the full tick read-only and prints exactly what a live
run would do.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`dependabot`](skills/dependabot/SKILL.md) | Classify the open Dependabot PRs, merge the provably-safe ones, rebase what's stale, and diagnose what's broken — filing one issue per broken update and never attempting a fix. | scheduled, or "/dependabot" · "/dependabot dry-run" |

## What it does with a broken update

It diagnoses from CI logs and files an issue; it never fixes and never merges that PR. It also never
runs the broken update's code locally — checking out the branch and running the test suite would
execute the *updated dependency's* code on a machine holding a token with merge rights, which is the
exact supply-chain path a malicious release uses. Full procedure:
[`failure-pass.md`](skills/dependabot/references/failure-pass.md).

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
/plugin install deps-flow@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
