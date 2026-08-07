---
name: audit-design-docs
description: Review design/architecture/planning docs, validate each claim against the code, fix drift, and add docs for uncovered load-bearing subsystems. Use when the user asks to "review planning docs", "audit the design docs", "validate docs against the code", "sync docs with the codebase", "find doc gaps", or similar. Covers DESIGN docs — the sibling `audit-product-docs` covers user-facing docs. Writes drift fixes + new docs to the working tree and stops; the caller (a human, or the `daily-update` meta-skill) is responsible for committing and opening a PR.
---

# Audit design docs against the code

The repo's design/architecture/planning docs are the canonical home for design decisions — *why*
things are built the way they are. This skill keeps them honest: it verifies what's written still
matches the code, and fills in docs for load-bearing subsystems the design docs don't cover yet.

This skill covers **design docs** (architecture, planning, design rationale). The sibling
`audit-product-docs` skill covers **user-facing docs** (guides, references, READMEs). If you find a
claim that belongs in user-facing docs, note it for that skill rather than fixing it here.

## Load the repo config

Before anything else, read `.claude/maintainerd.json` from the repo root (see
[`../../references/config-schema.md`](../../references/config-schema.md) for the full
contract). If it does not exist, **stop** and tell the user:

> This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

Don't guess values or hardcode another repo's settings. The keys this skill needs:

- `config.paths.designDocs` — an **array** of design-doc roots (directories and/or individual
  files). Iterate every entry; a repo may have several. If absent, ask the user where the design
  docs live rather than guessing.
- `config.paths.source` — root of the source tree the docs' claims are validated against.
- `config.defaultBranch` — the branch the working tree is based on (`main`, `master`, …); only
  relevant if you need to reason about what's shipped.
- `config.guidelines` — the repo's free-form rule files. Read these when you need repo-specific
  judgment about what counts as a "load-bearing subsystem" and what invariants a doc must capture.

## Workflow

Do these steps in order. Use `TodoWrite` to track them — reviewers have asked to see progress before.

### 1. Read every design doc

For each entry in `config.paths.designDocs`: if it's a directory, glob its `*.md` files; if it's a
file, take it directly. Read each one in full. Build a mental index keyed by subsystem: what each doc
claims, what it lists as shipped vs. deferred, what it explicitly says is out of scope.

Note the prevailing voice and structure (typically context → design → invariants → out-of-scope /
future work, prose-heavy with rationale). The richest doc — often a PRD or top-level design doc — is
your style reference; match that voice in anything you write.

### 2. Validate each doc against the code

For every factual claim a doc makes, confirm it in the tree. Validate claims against the code under
`config.paths.source`, the repo's config/settings module, its route/registration wiring, and its
schema/model definitions. The **kinds** of claims worth checking (non-exhaustive):

- **Module paths / file paths** — open them; do they exist and contain what the doc says?
- **Named symbols** — do the classes, functions, constants, and modules the doc names actually exist
  where it says, with the responsibilities it describes?
- **Schemas / data models** — compare the doc's table/column/field list against the repo's
  schema or model definitions and the latest migration, if the repo has migrations.
- **Routes / registration wiring** — compare the doc's route or endpoint table against where the repo
  registers them (router/prefix declarations, route tables, plugin/command registration).
- **Config / settings keys** — compare documented keys, aliases, and default values against the
  repo's config/settings module.
- **Shipped vs. not-started status tables** — design docs and PRDs drift here most often. Verify each
  row against the actual code state.
- **Hook / event names** — check where the repo emits or gates them for what is actually fired.
- **Idempotency / ordering / transaction claims** — read the code path end-to-end, not just the
  comment above the function.

Record each discrepancy with file + line references. Don't fix drift inline as you find it; collect
them and patch the doc in step 5 so the reviewer sees a single tight diff.

### 3. Identify subsystems not covered

For each top-level area under `config.paths.source` and each top-level concern (migrations, build,
CI, git hooks, tests, deploy), ask: *is there a design doc whose scope is mostly this subsystem?* A
quick inventory: list the source tree (`config.paths.source`), then list the design-doc roots
(`config.paths.designDocs`), and compare coverage.

A subsystem is a candidate for a new design doc when **both** are true:

1. It's load-bearing (not a one-off utility), and
2. Its *design rationale* is non-obvious — the kind of thing that would be re-litigated or
   rediscovered the hard way without a written record.

The form the rationale currently takes (code comments, an agents/contributor guide, or nowhere)
doesn't by itself settle the question. If code comments already explain *why*, the design doc adds
value only if the concept is cross-cutting or the rationale is worth preserving outside the code's
edit-churn — lift that content into the design docs and leave pointer-only comments in the code. If
comments are adequate, leave them and move on.

When "what counts as a load-bearing subsystem" is a repo-specific judgment call, lean on
`config.guidelines` (the repo's invariants and coding rules) and the repo's own structure rather than
a generic heuristic.

### 4. Write new docs

One markdown file per subsystem, placed in the appropriate design-doc root from
`config.paths.designDocs` (when there are several, pick the one whose scope fits; default to the
primary/first root). Filename is kebab-case and matches the subsystem name
(`trajectories-and-hooks.md`, not `04-hooks.md`).

Template — match this structure so the directory stays uniform:

```markdown
# <Title>

**Status:** Implemented | In progress | Deferred
**Author:** <author from existing docs>
**Last updated:** <today's date in "Month DD, YYYY" format>

---

## Context

Why this subsystem exists; what problem it solves. 2–4 short paragraphs.

## <Design sections: data model / contract / flow / invariants>

The actual design. Prefer prose + small code blocks over tables. Call out
the subtle bits explicitly — the kind of thing that would be rediscovered
the hard way if not written down.

## Invariants to preserve

Short bulleted list. The things a future edit must not break.

## Out of scope / future work

What this doc deliberately doesn't cover, and what's queued for later.
```

Writing guidance:

- **Explain the why, not the what.** The code already shows *what*; the doc's value is *why* a choice
  was made and what breaks if you reverse it.
- **Name the landmines.** If something in the code looks innocuous but has a non-obvious constraint
  (session splits, commit-before-emit ordering, URL reconstruction behind a proxy), say so out loud.
- **Link to neighbors.** Cross-reference other design docs when a concept spans them.
- **Don't copy the code.** If you're pasting a function body, you're probably writing a comment, not
  a design doc.
- **Keep each doc focused.** 100–200 lines is the sweet spot. Split if it's sprawling.

### 5. Patch drift in existing docs

For each discrepancy collected in step 2, `Edit` the existing doc in place. Keep diffs minimal — one
or two lines per drift item is typical. If the drift is conceptual (wrong architecture claim, not
just a stale status row), call it out in your report so it lands in the commit message and is visible
in the PR.

### 6. Stop — leave the changes in the working tree

This skill writes to the working tree and stops. Don't commit, don't push, don't open a PR — the
caller owns that:

- **Invoked by `daily-update`:** the meta-skill packages everything into one PR alongside the other
  daily sub-skills' changes. Don't try to commit yourself or you'll fight it.
- **Invoked manually by the user:** they'll review the diff and either run `create-pr` or commit by
  hand. If the user explicitly asks for a PR, hand off to `create-pr`; don't reimplement the
  PR-opening dance here.

Before you stop, **do report what you changed** so the caller can write a useful commit message —
list new docs by filename + one-line purpose, and drift fixes by filename + what conceptually was
wrong. If conceptual drift was found (wrong architecture claim, not just a stale status row), call it
out explicitly so it lands in the commit message that follows.

If nothing drifted and no new docs were warranted (a quiet day), say so plainly. Don't pad with
"everything looks great." The caller may decide to skip committing entirely.

## What not to do

- **Don't write docs for subsystems already covered**, and don't duplicate content that lives in code
  comments if the comments are the right home for it. Use the two-part criterion in "Identify
  subsystems not covered" to decide; duplicate docs rot at different rates and create confusion.
- **Don't fix code drift by editing code** as part of this task. Drift fixes belong in separate PRs
  with their own review. Docs work shouldn't hide code changes.
- **Don't invent a status** ("shipped", "in progress") without reading the code. Status tables drift
  fast; verify each row.
- **Don't create a `README.md` index** inside a design-doc directory unless explicitly asked. The
  directory listing is its own index.
- **Don't write design docs about the design-doc directory itself.** Meta-docs about the directory
  belong in a contributor guide or a skill, not in the docs themselves.
- **Don't touch user-facing docs.** Those are `audit-product-docs`'s job. If you spot user-facing
  drift, note it for that skill.

## Calibrating scope

When the design docs are few (≤5 files), expect to add 1–3 new docs and patch 1–5 drift items. When
larger, do the same validation pass but be pickier about which gaps warrant new docs — a well-covered
directory may need only drift fixes. Lean toward fewer, denser docs over many thin ones.

## Related skills

- `bootstrap` — generates the `.claude/maintainerd.json` this skill reads.
- `audit-product-docs` — the sibling that validates user-facing docs (guides, references, READMEs)
  against the code.
- `audit-architecture` — sweeps the source for tech debt; complements this doc-focused pass.
- `daily-update` — the meta-skill that runs this plus the other per-day housekeeping skills and
  bundles their output into one PR.
- `create-pr` — used by `daily-update` (or manually) to open the PR once the changes are written.
