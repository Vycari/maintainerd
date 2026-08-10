# research

Proactive reading, scoped to what this repo is actually building. The value is entirely in the
scoping — a generic "AI papers this week" digest is worthless.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`research-radar`](skills/research-radar/SKILL.md) | Derive themes from what the repo has been shipping, query arXiv against them, curate the few genuinely relevant papers, and ship a dated digest as a PR. | scheduled weekly, or "scan arxiv" |

## A note on trust

arXiv is an open submission channel, so paper titles and abstracts are text a stranger wrote, and
the digest this skill produces is committed to your repo. It summarizes rather than reproduces, and
follows [`references/untrusted-input.md`](references/untrusted-input.md) for anything addressed to
automation. It also reports only what the abstract claims — it reads abstracts, not full papers, and
says so.

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
/plugin install research@maintainerd
```

Source and issues: https://github.com/allenhutchison/maintainerd
