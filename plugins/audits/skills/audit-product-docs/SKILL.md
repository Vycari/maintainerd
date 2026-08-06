---
name: audit-product-docs
description: Validate the repo's user-facing / product / contributor docs against the code (settings/config names + defaults, command/action IDs, file paths, schedule/cron formats, tool/function names), patch drift in place, and add new docs only for user-visible features that aren't covered. Use when the user asks to "audit the docs", "review the docs", "validate docs against the code", "sync docs with the codebase", "find doc gaps", or similar. Covers USER-FACING docs — the sibling `audit-design-docs` skill covers internal design/architecture docs. Writes drift fixes + new docs to the working tree and stops; the caller (a human, or the `daily-update` meta-skill) is responsible for committing and opening a PR.
---

# Audit and extend the user-facing documentation

This skill keeps the repo's **user-facing / product / contributor** documentation honest: it
verifies that what's written still matches the code, and fills in docs for user-visible features the
doc set doesn't cover yet. It is scoped to docs a *user* or *external contributor* reads — the
product guide, reference tables, the README landing page, the contributor handbook. Internal
design/architecture docs are out of scope here; the sibling **`audit-design-docs`** skill owns those.

The docs are prose-forward and pragmatic — match that voice in anything you write. They are read by
users (who have not seen the code) and by external contributors (who are about to read it). Optimize
for both.

## Load the repo config

Before anything else, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill needs:
   - `config.paths.productDocs` — an **array** of user-facing doc roots (directories and/or individual
     files). This is the set this skill walks. Iterate it; never hardcode a doc path.
   - `config.paths.source` — the root of the source tree every factual claim is validated against.
   - `config.paths.prTemplate` — referenced only if the user asks for a PR (handed to `create-pr`).
   - `config.repo` / `config.defaultBranch` — used only if the caller later needs the slug or base
     branch; this skill itself doesn't push.
   - `config.guidelines.invariants` — the repo-specific rules file. **Read it.** It is the source of
     truth for any "this file is generated, don't hand-edit it / regenerate it with `<command>`
     instead" rule and any other doc-related invariant. Do not hardcode a generated-file rule here;
     it is repo-specific and lives in guidelines (see ["Generated and don't-touch
     files"](#generated-and-dont-touch-files) below).
4. For any key that's absent, fall back to the documented default and note the fallback in your run
   report. If `config.guidelines.invariants` is missing or still full of `TODO`s, say so — you'll
   proceed with the generic checks but can't enforce repo-specific generated-file rules.

## Generated and don't-touch files

Some repos generate a doc artifact from the markdown sources at build time (e.g. an in-app help
bundle compiled from the guide/reference directories) and forbid hand-editing the generated file —
the fix always belongs in the markdown source, which the build then re-derives. **This rule is
repo-specific. Read it from `config.guidelines.invariants`, don't assume it.**

If the invariants file names a generated doc artifact and its regeneration command, honor it: never
hand-edit the generated file, edit the markdown source instead, and (if the invariant says so)
re-run the regeneration command rather than touching the output. If the invariants file says nothing
about generated docs, there's no such constraint in this repo — proceed normally.

## Workflow

Do these steps in order. Use `TodoWrite` to track them — long doc audits benefit from visible progress.

### 1. Read every targeted doc

Enumerate the doc set from `config.paths.productDocs`. For directory entries, list them; for file
entries, read them directly:

```bash
ls <each directory in config.paths.productDocs>
```

Read each file under the `config.paths.productDocs` roots in full. Build a mental index keyed by
surface: what each doc claims, what it says is shipped vs. deferred, what it says is out of scope.

If a doc root is a contributor-handbook surface (a "how we work" doc rather than a user-facing
reference), the bar for "drift" there is whether the _workflow_ still matches reality, not whether
every code reference is current. Skim those, don't audit line-by-line.

### 2. Validate each doc against the code

For every factual claim a doc makes, confirm it in the tree under `config.paths.source`. The
categories below are the kinds of claims that drift fastest — validate each instance you find
against the code:

- **Config / settings names + defaults** — wherever a doc states the name and default of a setting
  or config field, compare against the type/struct/object that defines settings and their defaults
  in `config.paths.source`. Watch for renames and migration entries.
- **Command / action IDs and labels** — every doc that says "run command X" or "Command Palette → X"
  implies a registered command/action with that id and name. Grep the source for the command/action
  registration and verify each `id` + label referenced.
- **File / folder paths** — paths a doc says the tool reads or creates (state folders, output
  directories, on-disk layout). Verify the code creates or reads the same paths.
- **Schedule / cron formats** — any documented schedule grammar (e.g. `once`, `daily`, `weekly`,
  `interval:Xm`, cron expressions). Compare against the schedule/cron parser in the source.
- **Tool / function names** — wherever a doc lists agent tools, exposed functions, or API surface,
  compare against the actual registrations/definitions in the source.
- **Structured-config fields** — frontmatter/YAML/JSON schemas a doc documents (every field, whether
  required, its default). Verify every documented field is read by the code, and every code-read
  field is documented.
- **Enumerated values** — permission tiers, model lists, capability flags, and similar closed sets a
  doc enumerates. One rename in code can leave several docs stale.
- **UX / behavior claims** — drag-drop/paste behavior, size or count limits, classification rules.
  Compare against the code that implements them.

Record each discrepancy with file + line references. Don't fix drift inline as you find it; collect
them and patch in step 4 so the reviewer sees a single tight diff per doc.

### 3. Identify user-visible features not covered

For each feature shipped recently (use `git log` over `config.paths.source` for `feat`/`feature`
commits, plus any changelog files the repo keeps), ask: _is there a guide or reference doc whose
scope is mostly this feature?_

A feature is a candidate for a **new** doc when **all** are true:

1. It's user-visible (a settings page, command/action, agent tool, frontmatter field, etc.) — not a
   refactor.
2. It's load-bearing — a primary surface, not a one-off helper.
3. Its current documentation is _zero_ — not "thin", "zero". Thin docs get expanded in place; missing
   docs get a new file.

The form of the feature dictates where it goes. A new instance of an existing category (e.g. one more
agent tool) belongs as a section in the existing doc for that category, not a new file. A genuinely
new top-level feature (a new mode, a new pipeline) warrants its own file in the appropriate
`config.paths.productDocs` root.

Don't create user-facing reference docs for internal abstractions (factory patterns, decorators,
internal loop classes) — those belong in the contributor/design docs, not the product reference. The
user-facing reference is for user-facing references (settings, advanced settings, limits), not
internal architecture.

### 4. Patch drift in existing docs

For each discrepancy collected in step 2, `Edit` the existing doc in place. Keep diffs minimal — one
or two lines per drift item is typical. If the drift is conceptual (a wrong claim about behavior, not
just a stale name), call it out in the report so the commit message and PR body explicitly flag it.

If a setting was renamed and both the old and new name appear scattered through the docs, fix every
occurrence in this pass — readers get whiplash from a half-renamed surface.

### 5. Write new docs

One markdown file per uncovered feature, placed in the appropriate `config.paths.productDocs` root
(a user-flow guide vs. a reference table). Filename is kebab-case and matches the feature name
(`projects.md`, not `04-projects.md`).

Match the structure of an existing similar doc — read a neighboring guide to see the voice. Typical
shape:

```markdown
# <Feature name>

<One-paragraph framing: what it does, why a user would reach for it.>

## Overview

<2–4 paragraphs of context. Where the feature lives in the UI; what files
or settings back it; where its output goes.>

## <Tasks the user can perform>

<Step-by-step or table-driven sections describing the user's actions.>

## <Reference table if the feature has structured config>

| Field | Required | Default | Description |

## Tips / Gotchas

<Bulleted list of non-obvious behaviors.>
```

Writing guidance:

- **Explain the why, not just the what.** The UI shows _what_; the doc's value is _why_ a user would
  reach for this and what the trade-offs are.
- **Show the path through the UI.** "Command Palette → Open Scheduler → New task" beats abstract
  description.
- **Link to neighbors.** Cross-reference other guides when a concept spans them.
- **Don't dump code into a user-facing doc.** Frontmatter/config examples are fine; source-code
  snippets are not.
- **Keep each doc focused.** 100–250 lines is the sweet spot; split if it sprawls.

If the repo compiles a generated help bundle from these doc roots (per
`config.guidelines.invariants`), a new markdown file under the right root is picked up automatically
— no extra wiring needed, and you still must not hand-edit the generated output.

### 6. Stop — leave the changes in the working tree

This skill writes to the working tree and stops. Don't commit, don't push, don't open a PR — the
caller owns that:

- **Invoked by `daily-update`:** the meta-skill packages everything into one PR alongside the other
  daily sub-skills' changes. Don't try to commit yourself or you'll fight it.
- **Invoked manually by the user:** they'll review the diff and either run `create-pr` or commit by
  hand. If the user explicitly asks for a PR, hand off to `create-pr`; don't reimplement the
  PR-opening dance here.

Before you stop, **report what you changed** so the caller can write a useful commit message — list
new docs by filename + one-line purpose, and drift fixes by filename + what conceptually was wrong.
If conceptual drift was found (a wrong behavior claim, not just a stale name), call it out explicitly
so it lands in the commit message that follows.

If nothing drifted and no new docs were warranted (a quiet day), say so plainly. Don't pad with
"everything looks great." The caller may decide to skip committing entirely.

## What not to do

- **Don't hand-edit a generated doc artifact.** If `config.guidelines.invariants` names a generated
  file (e.g. a compiled in-app help bundle), editing the markdown source is the correct fix; the
  build re-derives the generated file. The set of generated files — and how to regenerate them — is
  repo-specific and comes from guidelines, not from this skill.
- **Don't fix code drift by editing code** as part of this task. Drift fixes belong in separate PRs
  with their own review. Docs work shouldn't hide code changes.
- **Don't touch the version-release surface.** A per-version release-notes file or a rendered
  docs-site changelog is owned by the repo's release process, not where doc updates land here.
- **Don't invent settings or commands.** If a doc references something that doesn't exist in the
  code, the doc is wrong — delete the reference, don't make the code match the doc.
- **Don't write internal-architecture docs in the product doc roots.** Internal design (factory/
  decorator patterns, the agent-loop design, internal contracts) belongs in the design/contributor
  docs that `audit-design-docs` covers, not the user-facing reference.
- **Don't change voice.** If a doc reads like a user guide today, keep it that way. If you're tempted
  to add a "Why we built this" section, ask whether the user actually needs that, or whether you're
  adding it for yourself.

## Calibrating scope

A typical daily run will find 0–3 drift items (mostly stale defaults or recently-renamed settings)
and need 0 new docs. A monthly or post-release run may find more. If the diff is sprawling, slow
down and ask the caller whether to split it into themed PRs — one mass "audit fixes" PR is hard to
review.

## Related skills

- **`audit-design-docs`** — the sibling audit for internal design/architecture docs
  (`config.paths.designDocs`). This skill is its user-facing counterpart.
- **`audit-architecture`** — sweeps the source for tech debt; the place code-level findings go.
- **`daily-update`** — the meta-skill that may invoke this one and packages the result into a PR.
- **`create-pr`** — hand off here when the user explicitly wants a PR from the working-tree changes.
