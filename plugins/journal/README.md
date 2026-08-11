# journal

Captures what actually shipped into your Obsidian vault. **User-scoped, not repo-scoped**: the vault
path comes from a user-level `~/.claude/maintainerd.json`, so one setting covers every repo you work
in.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`worklog`](skills/worklog/SKILL.md) | Write up a day's work — drawn from the day's merged PRs for completeness, enriched by the live session for the *why* — into a session-summary note, a link from the project hub, and one line in the daily note. | "log this session", "write up a dev log" |

## Why merged PRs rather than the session

A session knows why a change was made; it doesn't know what else shipped that day from cloud
sessions, other terminals, or scheduled agents. Taking the PR list as the spine and the session as
enrichment is what makes the log complete rather than merely detailed.

Re-runs are append-safe: the skill never clobbers content it didn't write, and rewrites its own
daily-note line in place rather than adding a second one.

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
/plugin install journal@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
