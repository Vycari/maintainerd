# repo-ops

The baseline PR and changelog flow — the things you do on every repo, extracted so they behave the
same on all of them. Nothing here merges.

## Skills

| Skill | What it does | Typical trigger |
| --- | --- | --- |
| [`create-pr`](skills/create-pr/SKILL.md) | Open a PR only after the repo's own format/lint/build/test pre-flight passes, using the repo's PR template. | "open a PR", "create a pull request" |
| [`address-review`](skills/address-review/SKILL.md) | Drive the full response loop on your own PR — fetch every review comment (bot and human), triage, fix with one focused commit each, push, then reply to every thread. Silence makes bots re-raise items. | "address the review comments" |
| [`release`](skills/release/SKILL.md) | Cut a versioned release: gather changes since the last tag, write notes, run the gate, bump, tag, publish, verify. | "cut a release" |
| [`daily-changelog`](skills/daily-changelog/SKILL.md) | Turn a day's merged PRs into a short readable changelog at `config.paths.changelogDir/YYYY-MM-DD.md`. | "what shipped today" |
| [`daily-update`](skills/daily-update/SKILL.md) | Run the repo's per-day housekeeping skills and bundle their output into one PR. | scheduled, or "run the daily update" |

## Note on code review

This plugin used to ship a `code-review` skill. It was dropped in favour of Claude Code's built-in
`/code-review`, which covers the same ground and avoids two plugins claiming the same command name.
Point the built-in at `config.guidelines.coding` / `.testing` for this repo's specific standards —
the built-in supplies the method, your guidelines supply the rules it can't know.

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
/plugin install repo-ops@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
