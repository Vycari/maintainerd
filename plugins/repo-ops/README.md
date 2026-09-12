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
| [`daily-update`](skills/daily-update/SKILL.md) | Run the repo's per-day housekeeping skills and bundle their output into one PR. `--workspace` runs the routine once per repo in an umbrella repo's `workspace` list — one PR per repo, one report. | scheduled, or "run the daily update" |

## Hooks

Two `PreToolUse` guards on `Bash`, installed automatically once this plugin is enabled — no
separate opt-in. Both read the hook JSON from stdin with `jq` and are written for bash 3.2
(macOS `/bin/bash`). Like the skills, both are generic: neither names a specific repo, label, or
org. See [`hooks/hooks.json`](hooks/hooks.json) for the manifest and
[`hooks/scripts/`](hooks/scripts/) for the implementations; the pin-file test suite lives at
`scripts/test-repo-ops-hooks.sh` in the maintainerd repo root (a cross-plugin link doesn't
resolve in an installed marketplace layout, so this is named rather than linked — see
"Repository layout" in the top-level README).

### `pr-template-guard`

**Denies** a `gh pr create` or `gh pr edit ... --body ...` whose body is missing a heading the
repo's own PR template requires. "Use the repo's PR template" is written into `create-pr`
(above) and into prose everywhere it's consumed; a rule that keeps getting violated while written
down belongs in a hook, not another sentence.

- The template is resolved from `config.paths.prTemplate` (see
  [`references/config-schema.md`](references/config-schema.md)), falling back to
  `.github/PULL_REQUEST_TEMPLATE.md` then `.github/pull_request_template.md`. No template found
  at all → the hook says nothing.
- Every `^## ` / `^### ` heading in the template is required **unless its text contains
  "(optional)"** (e.g. `### Human required (optional)`), and must appear **verbatim** — same
  level, same text — somewhere in the PR body. Extra headings in the body beyond the template are
  never a problem.
- Fenced code blocks (` ``` `/`~~~`) are stripped from both the template and the body before
  scanning, so an example `##` inside a code fence never reads as a real heading.
- The body is read out of `--body "..."`, `--body '...'`, `--body-file <path>`, and the
  `--body "$(cat <<'EOF' ... EOF)"` heredoc form. If the command is a create/edit that clearly
  carries a body, but that body's text can't be reliably resolved — an unrecognized quoting
  shape, or a `$`/backtick expansion whose real value is decided by the shell at runtime, not by
  this text scan — the hook **warns instead of denying**: a heuristic that fails closed on its
  own parse errors would block legitimate work it never actually read.
- The `gh pr create`/`gh pr edit` trigger itself must sit in command position (line start, right
  after a shell operator, or past a `command`/`env`/absolute-path wrapper) so that `gh issue
  create --body "saw this: gh pr create ..."` or a `gh pr create` line written into a heredoc
  that only builds another script (`cat > deploy.sh <<'EOF' ... EOF`) does not fire the hook on
  text that merely mentions the command.
- In a compound command (`gh issue create --body <A> && gh pr create --body <B>`), the body
  validated is the one that actually belongs to the matched `gh pr create`/`gh pr edit` — not
  whichever `--body`/`--body-file` happens to appear first in the whole command string.

Like every hook in the Vycari fleet, this **only ever denies or warns** — it never returns
`allow`, so it cannot widen anything a command it says nothing about would otherwise need.

Known heuristic limit: the command-position wrapper allowance covers `command`, `command -p`,
`env [VAR=val...]`, and a `gh` invoked by absolute/relative path — not every interpreter that can
also run `gh` (`sh -c "gh pr create ..."`, `xargs`, `nohup`, …). A `gh pr create` reached only
through one of those is not checked; per the split rule the rest of this plugin family follows,
that is a design change (tokenize, or enumerate more wrappers) to weigh later, not a patch to
chase indefinitely.

### `skip-label-race-guard`

**Warns** (advisory only, never denies) when a `gh pr create` applies the repo's
`config.review.skipLabel` (see the config schema) without `--draft`. Many review bots schedule
their run on the PR's `opened` webhook, which fires before a label from the same `gh pr create`
call has landed — so the label may not suppress the review it was meant to skip. The fix is
draft-first: `gh pr create --draft --label <skipLabel> ...` followed by `gh pr ready`, which
fires no `opened` event to race.

`review.skipLabel` is optional and repo-specific — a repo that sets no such key gets no warning
from this hook, ever. Which label (if any) means "skip review", and when it's appropriate to
apply, is entirely a house-rule decision for the consuming repo/organization; this hook only
knows the mechanism, not the policy.

Like `pr-template-guard`, the trigger is command-position anchored and heredoc bodies are
redacted first, so this only reads the matched `gh pr create` invocation — an echo, a
script-building heredoc, or a different chained command's `--body` text mentioning the label or
`--draft` does not affect the check. Label values are extracted quote-aware, so a label
containing a space (`--label "skip review"`) is matched in full, not truncated at the space.
Known heuristic limit: the far end of "this invocation" is bounded at the next `;`/`&`/`|`
character wherever it occurs, including inside this invocation's own quoted `--body` text — so a
`--draft`/`--label` placed *after* a `--body` whose content happens to contain one of those
characters can be missed. Placing `--draft`/`--label` before `--body` (as the warning's own
suggested fix already does) avoids this entirely.

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
