---
name: create-pr
description: Create a pull request for the current repository the right way — enforce the repo's PR template, run every CI gate (format, lint, build, typecheck, tests) locally before pushing, require docs updates for user-facing changes, and write an honest, non-marketing PR body. Use whenever the user wants to "create a PR", "open a pull request", "submit changes", "prepare changes for review", or "push this for review". Never bypasses verification, never auto-merges.
---

# Create a Pull Request

## Load the repo config

Before anything else, load the repo config (see
[`../../../core/reference/config-schema.md`](../../../core/reference/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill needs: `config.repo`, `config.defaultBranch`, `config.commands.*`
   (`format`, `lint`, `build`, `typecheck`, `test`), and `config.paths.prTemplate`.
4. Treat a `null` command as **"this repo has no such step — skip it, don't invent one."**

## When to use this skill

Use this skill when:

- You are ready to submit code changes for review
- The user asks you to create a PR, open a PR, or submit changes
- You have finished implementing a feature, fix, or chore

## Pre-flight checks

Before creating a branch or pushing any code, run all of the applicable checks below **in this
order** and fix any failures. Run each command from `config.commands.*`; **skip any whose value is
`null`** (that step does not apply to this repo).

1. **Format** — run `config.commands.format`. If it fails, apply the repo's formatter and stage the
   changes, then re-run until clean.
2. **Lint** — run `config.commands.lint`. Fix every reported issue.
3. **Build & type check** — run `config.commands.build`, then `config.commands.typecheck`. Fix any
   type errors. (Some repos fold the type check into the build; if `typecheck` is `null`, the build
   covers it.)
4. **Tests** — run `config.commands.test`. All tests must pass with no warnings or unexpected
   console output.

Do NOT skip these steps. Do NOT push code that fails any of these checks. Do NOT use `--no-verify`
to bypass git hooks. **Tests must pass before the PR opens** — never open a PR on a red suite and
promise to fix it later.

Also confirm the working tree is in a clean, intentional state: review `git status` and `git diff`,
stage only the changes that belong in this PR, and make sure no stray or generated files are
included.

## Documentation requirements

Every PR that changes user-facing behavior **must** include documentation updates in the same
commit or PR:

- **Feature additions**: document the new behavior in the repo's user-facing docs.
- **Feature changes**: update all affected documentation.
- **Settings / configuration changes**: update the relevant settings or reference docs.
- **Feature removal**: remove or rewrite documentation for the removed feature.

If the change is purely internal (test cleanup, refactoring with no behavior change, CI/tooling),
documentation updates are not required — but mark the documentation checklist item as N/A with a
short note explaining why.

For the specific docs layout and any repo-specific documentation conventions, read
`config.guidelines.coding` (and any docs-specific guidance it points to) rather than assuming a
fixed file structure.

## PR template

If `config.paths.prTemplate` exists, read it and **use it** — the PR body must follow that
template's structure and fill in every section and checklist item. Do not drop sections the
template requires; for items that don't apply, keep the line and mark it N/A with a brief reason.

A typical template asks for:

### Summary

A concise description of what the PR does and why. Link the related issue with `Fixes #<number>`
when applicable.

### Changes

A bullet list of the key changes.

### Screenshots / Screencast

Required for UI changes. Omit only when the change is purely backend/internal.

### Checklist

Complete every item. Use `[x]` for done and `[ ]` for not-applicable items, adding a note that
explains why. Tick the CI-checks item only after the pre-flight gates above have actually passed
locally, and disclose AI assistance honestly where the template asks for it.

If `config.paths.prTemplate` is `null`, the repo deliberately uses no template — fall back to the
Summary / Changes / Checklist structure above without comment. If the key points at a file that
**doesn't exist**, use the same fallback but flag the dangling path in your run report and suggest
re-running `/bootstrap` (which offers to scaffold a template or set the key to `null`).

## Voice

Write the PR body the way a careful engineer writes for other engineers. State plainly what
changed and why. **No marketing language** — no "blazing-fast", "robust", "seamless",
"production-ready", no emoji, no exclamation points, no self-congratulation. Describe trade-offs
and known gaps honestly. Reviewers trust a description that names its own limitations.

## Creating the PR

Use `gh pr create` with a HEREDOC for the body to preserve formatting. Pass `--repo config.repo`
and target `config.defaultBranch`:

```bash
gh pr create \
  --repo <config.repo> \
  --base <config.defaultBranch> \
  --title "type: Short description" \
  --body "$(cat <<'EOF'
## Summary

...

## Changes

- ...

## Checklist

- [x] ...
EOF
)"
```

### Labels

If the caller asked for labels on the PR — a human naming them, or another skill delegating here
(the **auto-dev** pipeline passes its `config.autoDev.prLabel` so external review tooling can
recognize automated PRs) — apply them with `--label` **on the create call above**, not with a
follow-up `gh pr edit`. Review bots react to the `opened` webhook within seconds, and a label added
afterwards doesn't retract a review that already started. Labels must already exist; this skill
never creates them. Left unasked, don't invent labels — an unlabeled PR is the normal outcome here.

### Title conventions

- Keep under 70 characters
- Use conventional commit prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`
- Use imperative mood: "Add feature" not "Added feature"

## After creating the PR

- Return the PR URL to the user.
- **Do not auto-merge.** Leave the PR for review.
- Monitor for review comments (CodeRabbit, other bots, and human maintainers) and address them.
