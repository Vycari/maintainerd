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

### How both guards read a command

Both hooks ask the same question of a Bash payload — *which `gh pr create`/`gh pr edit`
invocations does this command actually run, and what does each one say?* — and both answer it
with one shared scanner, [`hooks/scripts/lib/gh-command-scan.sh`](hooks/scripts/lib/gh-command-scan.sh):

1. **Heredoc bodies are redacted in place.** `cat > deploy.sh <<'EOF'` followed by a line reading
   `gh pr create --body "..."` writes that text to a file; it does not run gh. Redaction replaces
   only body characters, one-for-one, so the redacted text is byte-for-byte the same length as
   the original and an offset into one addresses the other.
2. **The payload is split into simple commands** on `;`, `&&`, `||`, `|`, newlines and subshell
   parentheses — but only where those are *not* inside single quotes, double quotes, backticks or
   a `$( … )` substitution. So an `echo "run: gh pr create --label x && …"` is one simple command
   whose executable is `echo`, and a `--body "$(cat <<'EOF' … EOF)"` stays whole no matter what
   operator characters or newlines its prose contains.
3. **Each simple command's executable is resolved by basename**, after dropping the prefix words
   that don't change which program runs: leading `VAR=value` assignments, `command [-p]`,
   `env [-i] [VAR=value…]`, `exec`, and the shell keywords that can precede a command (`if`,
   `while`, `until`, `!`, `{`, `time`, …). `gh`, `command gh`, `env GH_HOST=… gh`, `exec gh`,
   `/usr/bin/gh`, `if gh pr create …; then`, `! gh pr create …` and `GH_PAGER="less -R" gh` all
   resolve alike; `mygh` does not.
4. **Flags are read from argv words, not from the raw text.** The same quote-aware splitting turns
   one invocation into words, so `--body "reviewer asked: please use --draft next time"` is a body
   and not a `--draft` flag, `--body "pass --label skip"` applies no label, and a `--title "fix
   --body-file parsing"` doesn't hijack body extraction. Only a word that *is* the flag counts —
   in every spelling gh accepts: long, `--flag=value`, the shorthands (`-b`, `-F`, `-d`, `-l`),
   and short-option clusters read by gh's own rule — a value-taking shorthand consumes the rest
   of the word. So `-dl skip` is a draft plus a label, `-b"…"` and `-Fbody.md` carry attached
   values, and `-tDraftTitle` is a *title* whose `d` is not `--draft`.

Every matching invocation is then checked **on its own** — a compound command that opens two PRs
is two checks, each against its own flags, and a bodyless or non-PR command is never backfilled
from a neighbour's `--body`. This structural split is deliberately *not* a growing list of regex
alternatives: per the rule this plugin family follows, a guard that needs a fifth pattern is a
design change, and tokenizing once is that change.

Both guards source that scanner from `hooks/scripts/lib/`; if it is ever missing from an
install, they say so in a warning rather than silently passing the command through unchecked.

Known limits of the scanner, all of which fail in the direction of checking *less*, never of a
false denial:

- Heredoc openers are found by scanning each command line for `<<[-]TAG` without tracking
  quoting, so a literal `<<TAG` inside a quoted string is misread as an opener and the lines
  after it are treated as an inert body. A heredoc body that itself contains a nested `gh pr
  create` is data either way and is never checked — that is the intended behaviour, not a gap.
- `gh` reached as another program's *data* rather than as its own `argv[0]` —
  `sh -c "gh pr create …"`, `xargs gh`, `find -exec gh`, `nohup` — resolves to `sh`/`xargs`/`find`
  and is not recognized.
- A `gh pr create` written inside a `$( … )` command substitution belongs to the enclosing simple
  command and is only checked if that enclosing command is itself a `gh pr create`/`edit`.

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
  `--body "$(cat <<'EOF' ... EOF)"` heredoc form — always from within the invocation it belongs
  to, so `gh issue create --body <A> && gh pr create --body <B>` checks *B* against the template
  and never *A*. If the command is a create/edit that clearly carries a body, but that body's
  text can't be reliably resolved — an unrecognized quoting shape, or a `$`/backtick expansion
  whose real value is decided by the shell at runtime, not by this text scan — the hook **warns
  instead of denying**: a heuristic that fails closed on its own parse errors would block
  legitimate work it never actually read.
- A command carrying more than one `gh pr create`/`gh pr edit` has every one of them checked
  against its own body, and the denial names the missing headings of each offender.

Like every hook in the Vycari fleet, this **only ever denies or warns** — it never returns
`allow`, so it cannot widen anything a command it says nothing about would otherwise need.

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

Because it uses the same scanner, only a real `gh pr create`'s own flags are read: an echo, a
script-building heredoc, or a different chained command's `--draft`/`--label` text does not
affect the check, and each `gh pr create` in a compound command is judged on its own `--draft`.
Label values are parsed the way gh accepts them — quoted (`--label "skip review"`, matched in
full rather than truncated at the space), repeated (`--label a --label b`), `--label=value`, the
`-l` shorthand, and comma-separated (`--label a,b`, which gh splits into two labels).

## Wait tools

Two scripts that block on a PR until a bot or CI has a verdict, and print it. They exist so an
agent (or a person) can say "wait for the review" once, instead of hand-rolling a polling loop that
forgets a deadline, reads a stale comment, or confuses a workflow run with a job. Both are plain
bash 3.2 over `gh` and `jq`, generic (no repo or org is named), and **observe only**: they never fix
code, reply, resolve a thread, label, re-run a job, or merge. They live in
[`scripts/`](scripts/) and are run by path
(`${CLAUDE_PLUGIN_ROOT}/scripts/wait-for-review.sh <pr> [-R owner/repo]`); the test suite is
`scripts/test-wait-tools.sh` in the maintainerd repo root, against a stubbed `gh` with no network.

The first line of stdout is the verdict; exit status mirrors it (0 good, 1 needs action, 2 gave up,
3 the tool itself could not run, which is never reported as a verdict). Both stop at
`review.waitTimeoutMinutes` (default 20) and poll every 3 minutes unless `--interval-seconds` says
otherwise; `--timeout-seconds` and `--config FILE` exist for tests and one-off use.

### `wait-for-review.sh <pr> [-R owner/repo]`

| Output | Meaning |
| --- | --- |
| `approved` | The bot's score meets `review.approvalThreshold` **on the PR's head commit** and there are 0 unresolved review threads. With the default threshold `"approved"`, GitHub's `reviewDecision` must be `APPROVED` instead. |
| `findings:<n>` | The head commit's review is in and `<n>` threads are unresolved; one indented `path:line  body` line follows per finding. `findings:0` means the score is below the threshold with nothing open on a line (the shortfall is in the summary). |
| `no-review-scheduled` | Nothing will review it: the PR is a draft, carries `review.skipLabel`, or `review.bots` is configured empty. Returned immediately. |
| `timeout` | No verdict by the deadline. |

It polls the **same** bot artifact every round — Greptile edits one comment (or the PR description's
marker block) in place — and compares its "Last reviewed commit" with the PR's current head. A
score for any other commit, or a score whose commit cannot be read, is stale and counts as "no
review yet": it never satisfies the gate, whatever the number. Scores are only trusted from a login
in `review.bots`; the description's marker block counts only when the PR description's latest edit
was made by that bot (the description is author-writable, so an unattributed block is not
evidence). When several configured bots have published a score, every one must be on the head and
at the bar, and a reviewer's outstanding `CHANGES_REQUESTED` blocks `approved` regardless of score.

Policy comes from the repository being waited on: the checkout's `.claude/maintainerd.json` when
the checkout is that repo, otherwise the target's file read from its default branch (so `-R` or a
PR URL for another repo is never judged by this checkout's bots, threshold or skip label). A PR URL
names its repository, and contradicting it with `-R` is an error.

### `wait-for-checks.sh <pr> [-R owner/repo]`

| Output | Meaning |
| --- | --- |
| `green` | Every check in `statusCheckRollup` has finished and none failed (success, neutral and skipped are not failures), and the same set of checks is still green after `--settle-seconds` (default 60) — a slower required check can register just after a push, when the rollup briefly holds only checks that are already green. |
| `failed:<job>` | A check failed (failure, timed out, cancelled, startup failure or action required). `<job>` is the **job** name, and the failing job's log tail follows (`gh run view --job <id> --log-failed`, last 40 lines) — job-level, not run-level. Reported as soon as seen; it does not wait for the rest. |
| `queued-no-runner` | A job has been queued past `--queue-threshold-seconds` (default 600) and the Actions API says no runner was assigned. A job with no start time yet is aged from the Actions job record's `created_at`. A queued job whose assignment cannot be confirmed is not reported this way. |
| `timeout` | No verdict by the deadline. An empty rollup keeps waiting, since checks register shortly after a push. |

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
tier they want in [`references/model-tiers.md`](references/model-tiers.md); "is my PR deployed?"
is answered by fetching the repo's `config.deploy.versionz` endpoint, per
[`references/deployed-check.md`](references/deployed-check.md) — never by ssh or `docker inspect`.

## Install

```text
/plugin marketplace add Vycari/maintainerd
/plugin install repo-ops@maintainerd
```

Source and issues: https://github.com/Vycari/maintainerd
