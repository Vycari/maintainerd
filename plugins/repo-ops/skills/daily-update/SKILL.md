---
name: daily-update
description: Run the repo's per-day housekeeping skills and bundle their output into one PR. Each sub-skill writes to the working tree (or mutates GitHub directly); this skill runs the configured roster in sequence, collects what they wrote, and packages the combined diff into a single PR. Use when the user asks to "do the daily update", "run the daily skills", "morning sweep", "end-of-day cleanup", or when invoked by a scheduled remote agent doing the daily run. The roster is configured per-repo in `config.dailyUpdate.subSkills`. Bundles the per-day skills behind one entry point so a single schedule slot covers the whole routine. Safe to invoke manually at any time.
---

# Daily update — orchestrate per-day housekeeping skills

## Load the repo config

Before anything else, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill needs: `config.repo`, `config.defaultBranch`,
   `config.dailyUpdate.subSkills` (the ordered roster), `config.dailyUpdate.branchPrefix`,
   `config.dailyUpdate.commitSubject`, and — for the inline-PR fallback — `config.commands.*` and
   `config.paths.prTemplate`.
4. If `config.dailyUpdate.subSkills` is absent or empty, there is nothing to run. Say so and stop.

## What this skill is for

A repo's scheduled-agent slots are limited, so the per-day housekeeping skills are gathered behind
one entry point. This skill is that entry point: it runs each sub-skill in `config.dailyUpdate.subSkills`
in sequence, lets each one write to the working tree (or, for a triage-only sub-skill, mutate GitHub
directly), and then packages the combined diff into a single PR at the end.

The working-tree sub-skills are deliberately "write-only" — they don't commit or push. That's this
skill's job. Centralizing the side-effects means: one PR per daily run (easy to review), no empty PRs
on quiet days (don't commit if nothing changed), and adding a new daily sub-skill is a one-line edit
to `config.dailyUpdate.subSkills` rather than another schedule slot.

## The sub-skills

The roster is **whatever `config.dailyUpdate.subSkills` lists, in that order** — never a hardcoded
list. Iterate the array. Each named skill's full workflow lives in its own `SKILL.md` — read it and
execute it as if it had been invoked directly. Do not re-implement the logic here.

A typical roster looks like `["daily-changelog", "audit-product-docs", "triage-issues"]`, but it
varies per repo. Some entries write files (`daily-changelog` → a dated changelog/release-notes file;
`audit-product-docs` / `audit-design-docs` → drift fixes and any new docs); others mutate GitHub
directly with no working-tree diff at all (`triage-issues` → applies labels via `gh`). Treat both
kinds the same way: run them, capture an outcome line.

For each entry in `config.dailyUpdate.subSkills`:

- **If the named skill isn't available in this repo**, note it ("skipped — not installed") and
  continue. A missing roster entry is a config drift to flag, not a reason to abort.
- Otherwise read its `SKILL.md` and execute the workflow it describes.

Order matters only when sub-skills overlap on output paths. The roster is already in the intended
order; preserve it.

## Workflow

### 1. Start a fresh branch off the default branch

```bash
git checkout <config.defaultBranch> && git pull
BRANCH_NAME="<config.dailyUpdate.branchPrefix>$(date +%Y-%m-%d)"
git checkout -b "$BRANCH_NAME"
```

Substitute `config.defaultBranch` and `config.dailyUpdate.branchPrefix` from the config. If a branch
by that exact name already exists locally (the cron fired twice, or a manual run already happened
today), append `-2`, `-3`, etc. — never reuse a branch from a previous run; the diff would conflate
two days. Update `BRANCH_NAME` to the chosen suffix so the cleanup steps below find the right branch.

### 2. Run each sub-skill in sequence

For each sub-skill in `config.dailyUpdate.subSkills`:

- Read its `SKILL.md`.
- Execute the workflow it describes, writing to the working tree (or mutating GitHub, for a
  triage-only sub-skill).
- When it's done, capture a one-line outcome — e.g. "wrote planning/changelog/2026-04-25.md, 6 PRs"
  / "no drift, no new docs warranted" / "labeled 4 issues: #710 enhancement+agent-config, …". You'll
  need these for the commit message and the PR body.

If a sub-skill errors out partway, **don't abort the whole run**. Capture the error, move on to the
next sub-skill. A daily run that flags one broken sub-skill is more useful than a daily run that
breaks halfway and leaves the others un-attempted.

### 3. Package the changes

Check what's in the working tree:

```bash
git status --short
```

Decide what to do based on three cases:

**Case A — the working tree is clean and no GitHub-only sub-skill did anything.** Quiet day:

- Don't commit. Don't push. Don't open a PR. Empty PRs are noise.
- Delete the branch you just created (`git checkout <config.defaultBranch> && git branch -D "$BRANCH_NAME"`)
  so the local branch list stays clean.
- Report "no daily changes" and stop. The cron's job is done; absence of a PR is the signal.

**Case B — the working tree is clean but a GitHub-only sub-skill made changes** (e.g. `triage-issues`
applied labels). Report-only day:

- Don't open a PR. Those changes already live on GitHub; opening an empty-diff PR just to write a
  summary is more friction than it's worth.
- Delete the branch (same as Case A).
- Reply with the sub-skill's summary (e.g. the triage labels applied) so a human can audit it.

**Case C — the working tree has changes.** Commit them all in **one** commit. The subject comes from
`config.dailyUpdate.commitSubject` with `{date}` replaced by the ISO date (`date +%Y-%m-%d`):

```text
<config.dailyUpdate.commitSubject, {date} → YYYY-MM-DD>

- <sub-skill>: <one-line outcome>
- <sub-skill>: <one-line outcome>
- <sub-skill>: <one-line outcome>

[any errors that occurred during sub-skill execution]
```

Then open the PR — **delegate to the `create-pr` skill**, don't re-implement the pre-flight:

- If `create-pr` is installed, hand off to it. It enforces the repo's PR template and runs the
  pre-flight gates (`config.commands.*`) before pushing. Do not bypass it — the daily PR plays by the
  same rules as any other.
- If `create-pr` is **not** installed, fall back to opening the PR inline: run the applicable
  `config.commands.*` gates yourself (`format`, `lint`, `build`, `typecheck`, `test`; skip any that
  are `null`) as the pre-flight, then `gh pr create --repo <config.repo> --base <config.defaultBranch>`.
  Don't skip the gates — if a sub-skill added a doc that breaks the docs build, you want to know
  before the PR opens.

The PR body should list each sub-skill's outcome again with the file paths it touched (and, for a
GitHub-only sub-skill, the issue numbers/labels it changed), so a reviewer can navigate the diff by
sub-skill. A regular (non-draft) PR is fine; mark it **draft** only if a sub-skill made conceptual
drift fixes that benefit from a slower read (e.g. an `audit-*` skill rewrote prose).

### 4. Report

Reply to the caller with:

- One line per sub-skill: ok / no-op / error (with the message if errored) / skipped (not installed).
- The PR URL, or "no PR — GitHub-only run, see summary above" (Case B) / "no changes — no PR"
  (Case A).

That's it. Don't paste the PR body or the commit message back — the URL is enough for a human, and
the cron only needs the success/failure signal.

## What not to do

- **Don't bundle sub-skill changes into separate commits.** One commit per daily run. The PR is the
  unit of review.
- **Don't open a PR with no diff.** Quiet days are valid signal; the absence of a PR is the message.
  GitHub-only days report inline, no PR.
- **Don't push to `config.defaultBranch`.** Always a branch + PR.
- **Don't hardcode the roster.** It comes from `config.dailyUpdate.subSkills`. Adding or removing a
  daily sub-skill is a config edit, not a SKILL.md edit.
- **Don't skip the pre-flight gates.** Whether `create-pr` runs them or you run `config.commands.*`
  inline, the daily PR is gated like any other.
- **Don't reuse a branch from a prior daily run.** Each run gets its own branch; same-day re-runs
  append a suffix.
- **Don't commit partial work.** If a sub-skill half-finished and left the tree in an inconsistent
  state, don't paper over it — capture the error and let a human triage from the run report.
- **Don't try to "fix" a failing sub-skill from inside this skill.** Capture the error, move on, and
  let a human triage it from the run report.
- **Don't reimplement sub-skill logic here.** Read the sub-skill's `SKILL.md` and follow it. If a
  sub-skill needs a behavior change, edit *that* skill's `SKILL.md` and ship it as a separate PR.

## When sub-skills fight

The roster is ordered, and well-behaved sub-skills write to disjoint surfaces (e.g. a changelog dir,
a docs tree, GitHub labels). If a future sub-skill ends up touching the same files as another, keep
them in dependency order in `config.dailyUpdate.subSkills` (whoever generates the input first) and
call out the dependency. If two sub-skills genuinely conflict on the same file, that's a sign one of
them is mis-scoped — flag it and stop, don't paper over it with merge logic in this skill.
