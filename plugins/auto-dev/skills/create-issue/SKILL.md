---
name: create-issue
description: Turn a rough request into a well-formed GitHub issue that's ready for the auto-dev pipeline. Takes the user's description, then either investigates the codebase to isolate the affected files, likely root cause, and repro — or asks targeted clarifying questions when the ask is underspecified — and drafts an issue with a crisp problem statement, acceptance criteria, and concrete file/symbol pointers. Dedups against existing issues, shows the draft for confirmation, files it, and labels it so auto-dev's triage can pick it up. Reads the repo config for the repo slug, source paths, and (when auto-dev is enabled) the pipeline labels. Use when the user wants to "create/file/open an issue", "turn this into an issue", "file a bug / feature request", or "write up an issue for X". Do NOT use to browse or triage existing issues, or when the user only wants an in-chat answer without filing anything.
---

# Create a pipeline-ready issue

This skill is the **front door to the auto-dev pipeline**: it turns a rough request — "X is broken",
"we should add Y" — into a GitHub issue well-formed enough that the pipeline can actually build it.
An autonomous builder is only as good as the issues fed into it; a vague issue wastes a whole
build cycle or sends it sideways. The value here is the *grounding*: real file/symbol pointers,
concrete acceptance criteria, and a tight scope, produced by reading the code — not by transcribing
the user's one-liner into a bug template.

It's the intake stage of the pipeline (`create-issue` → `auto-dev` builds → `review-queue`), and it's
useful on its own even where auto-dev isn't enabled: a well-scoped issue is worth filing regardless.

## Load the repo config

Read `.claude/maintainerd.json` (see
[`../../references/config-schema.md`](../../references/config-schema.md)); if missing,
stop and tell the user to run `/bootstrap`.

Keys this skill uses:
- `config.repo` — GitHub `owner/name` for every `gh` call.
- `config.paths.source` — where to investigate to ground the issue in real pointers.
- `config.autoDev.enabled` — if `true`, align labels so the pipeline's triage picks the issue up
  (below). If `false`/absent, just file a well-formed issue; skip the pipeline-specific labeling.
- `config.autoDev.stateLabels.*` — the `auto:*` state labels (only used if the user wants to
  fast-track; default is to leave the issue for auto-dev's own triage).
- `config.autoDev.excludedLabels` — labels that make auto-dev **skip** an issue (e.g. `epic`,
  `question`). Apply one of these when the request isn't a single buildable unit.

## Workflow

### 1. Understand the request

Read what the user gave you and classify it: **bug**, **feature/enhancement**, **refactor/chore**, or
**question** (a question usually shouldn't become a build issue — answer it or file it labeled to be
excluded). Note what's already concrete and what's missing for a buildable issue: a bug needs a repro
+ expected/actual + the code path; a feature needs the desired behavior + acceptance criteria + where
it plugs in.

### 2. Investigate first, then clarify only the gaps

This is the core of the skill. **Prefer reading the code over interrogating the user** — don't ask
about anything you can find yourself.

- **Investigate the codebase** to ground the issue. Use the search tools (or dispatch an `Explore`
  subagent for a broad "where does X live" question) over `config.paths.source`:
  - *Bug:* locate the likely code path, the specific file(s)/function(s) involved, and how it
    reproduces. Read enough to state a plausible root cause (hedged — "likely in `X:42` where …")
    without committing to a fix.
  - *Feature:* find where it would plug in, the existing patterns it should follow, and the modules
    it touches. Note prior art in the repo.
  - Collect concrete `file:line` / symbol pointers as you go — these are what make the issue buildable.
- **Ask targeted clarifying questions** (via `AskUserQuestion`) *only* for what investigation can't
  resolve: genuinely ambiguous scope, a missing repro you can't reconstruct, unclear acceptance
  criteria, or several plausible interpretations. Ask the minimum. If the code answered it, don't ask.

### 3. Draft the issue

Write a draft the pipeline can build from. Match the repo's issue conventions/templates if it has
them. Aim for this shape (trim sections that don't apply):

```markdown
## Problem / motivation
<what's wrong or missing, and why it matters — 1–3 sentences>

## Repro (bugs)
<steps · expected vs actual>

## Acceptance criteria
- [ ] <observable, checkable outcome>
- [ ] <…>

## Pointers
- `path/to/file.ext:42` — <what lives here / why it's relevant>
- <symbol / module the implementer should start from>

## Scope
In: <the single coherent unit this issue covers>
Out: <explicitly deferred, to keep it buildable>
```

**Keep it a single buildable unit.** If the request is really several things or an epic, say so and
either (a) propose splitting into separate issues, or (b) file it as an epic **labeled to be excluded
from auto-dev** (`config.autoDev.excludedLabels`) so the pipeline doesn't try to one-shot it. A tight,
well-bounded issue is the whole point — resist the urge to pad scope.

Don't over-prescribe the implementation: give pointers and criteria, not a full diff. The plan step
(auto-dev, or a human) decides *how*.

### 4. Dedup, then confirm before filing

```bash
gh issue list --repo <config.repo> --state open --search "<key terms>" --json number,title,url --limit 30
```

If an open issue already covers this, surface it and ask whether to add a comment there instead of
filing a duplicate.

Then **show the user the full draft (title + body + intended labels) and get confirmation** — filing
a GitHub issue is outward-facing; never create it silently. Let them edit first.

### 5. File and label

```bash
gh issue create --repo <config.repo> --title "<title>" --body "<body>" --label "<labels>"
```

Labeling:
- Apply an appropriate **type label** if the repo uses them (`bug`, `enhancement`, …) — only ones
  that already exist; don't invent labels.
- **When `config.autoDev.enabled`:** a well-formed, buildable issue should be left **unlabeled by
  state** so auto-dev's own triage evaluates it fresh and runs the plan-approval handshake — do
  **not** stamp `auto:ready` by default (that would skip planning). Only apply a `config.autoDev.stateLabels.*`
  value if the user explicitly wants to fast-track. For a non-buildable request (epic, question,
  needs-a-human-decision), apply a `config.autoDev.excludedLabels` value so the pipeline skips it.
- **When auto-dev is disabled/absent:** just the type label; no `auto:*` labels.

### 6. Report

Give the user the issue number + URL, its labels, and its pipeline status: "ready for auto-dev triage"
/ "filed as epic, excluded from auto-dev — suggest splitting into #… " / "duplicate of #… , commented
there instead."

## What makes an issue "ready for the pipeline"

A checklist to hold the draft against before filing:
- A reader (or an autonomous builder) knows **what to change and how to tell when it's done** —
  problem is clear, acceptance criteria are observable and checkable.
- It's grounded in the **actual code** — concrete file/symbol pointers, not just a restatement of the
  user's words.
- It's a **single coherent unit of work**, with out-of-scope called out.
- It's **not** an epic, a question, or a "figure out what we want" — those get excluded or split.

## What not to do

- **Don't file without confirmation.** Show the draft; the issue is outward-facing.
- **Don't interrogate the user for things the code answers** — investigate first, ask only the gaps.
- **Don't stamp `auto:ready` by default** — let auto-dev triage and the plan-approval handshake do
  their job; fast-track only on explicit request.
- **Don't feed an epic to the pipeline.** Split it, or file it excluded.
- **Don't invent labels** — use only ones that exist in the repo.
- **Don't over-specify the implementation** — pointers and criteria, not a prescribed diff.
- **Don't file a duplicate** — dedup against open issues first.
