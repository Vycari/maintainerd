---
name: create-pr
description: Create a pull request for the current repository the right way — enforce the repo's PR template, run every CI gate (format, lint, build, typecheck, tests) locally before pushing, require docs updates for user-facing changes, and write an honest, non-marketing PR body. Where the repo sets `createPr.requireIssueForDeferredWork`, it also refuses to open a PR whose body promises follow-up work without naming an issue. Use whenever the user wants to "create a PR", "open a pull request", "submit changes", "prepare changes for review", or "push this for review". Never bypasses verification, never auto-merges.
---

# Create a Pull Request

## Load the repo config

Before anything else, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill needs: `config.repo`, `config.defaultBranch`, `config.commands.*`
   (`format`, `lint`, `build`, `typecheck`, `test`), `config.paths.prTemplate`, and
   `config.createPr.requireIssueForDeferredWork` *(optional; default `false`)*.
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

One more gate runs later, once the body exists rather than before the push:
see **Deferred work must name an issue**.

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

If `config.paths.prTemplate` exists, **read the file and take your headings from it, verbatim.**
`gh pr create --body` replaces the template entirely — GitHub does not merge the two — so the only
way the template reaches the PR is by you reproducing it. Concretely:

1. `cat` the template. Every `##`/`###` heading it contains appears in your body, in the same
   order, spelled the same way. Do not substitute headings you prefer or remember from another
   repo; the example body later in this skill is an *illustration*, and the repo's file wins over
   it every time.
2. Replace each HTML comment (`<!-- … -->`) with the content it asks for; drop the comment.
3. Fill every checklist item. Use `[x]` for done and `[ ]` for not-applicable items, adding a note
   that explains why. Tick the CI-checks item only after the pre-flight gates above have actually
   passed locally, and disclose AI assistance honestly where the template asks for it.
4. Sections marked optional in the template may be dropped when they would be empty; everything
   else stays.

Templates differ by repo. One common shape is two sections for two readers — a short glanceable
overview for a busy human, then a dense section for automated review and future sessions — and
another is the older Summary / Changes / Checklist shape. Which one you write is decided by the
file, not by this skill.

If `config.paths.prTemplate` is `null`, the repo deliberately uses no template — use a plain
Summary / Changes / Checklist structure without comment. If the key points at a file that
**doesn't exist**, use the same fallback but flag the dangling path in your run report and suggest
re-running `/bootstrap` (which offers to scaffold a template or set the key to `null`).

## Voice

Write the PR body the way a careful engineer writes for other engineers. State plainly what
changed and why. **No marketing language** — no "blazing-fast", "robust", "seamless",
"production-ready", no emoji, no exclamation points, no self-congratulation. Describe trade-offs
and known gaps honestly. Reviewers trust a description that names its own limitations.

## Deferred work must name an issue

Off unless `config.createPr.requireIssueForDeferredWork` is `true`. When it is, run this gate on
the finished PR body — after the template is filled in, immediately before `gh pr create` — and
**refuse to open the PR** if it fails.

It exists for one failure mode: *a follow-up that lives only in a PR dies with the PR.* "We'll
handle the retry path in a follow-up" reads like a commitment while the PR is open and is invisible
the day after it merges. Naming an issue in the same sentence costs one command and makes the
promise outlive the thread.

### What to check

1. **Bypass first.** If the body contains `<!-- no-deferred-work -->` anywhere, the gate is off for
   this PR. Skip to creating it, and say in your run report that a bypass marker was honored — a
   silent bypass is indistinguishable from a passed gate.
2. **Gather the text.** The PR body you are about to submit, plus the subject and body of every
   commit on the branch (`git log origin/<config.defaultBranch>..HEAD`). Ignore fenced code blocks
   and HTML comments in both — a `TODO` inside a code sample is an example, not a promise.
3. **Find the deferral cues.** Case-insensitive, either shape:
   - **A section heading** whose text is about later work: `Deferred work`, `Deferred`,
     `Follow-ups`, `Follow-up work`, `Future work`, `Next steps`, `Out of scope`, `Not in this PR`.
   - **A phrase inside a sentence or list item**: *follow-up*, *followup*, *deferred*, *defer*,
     *in a later PR*, *in a separate PR*, *in a future PR*, *out of scope*, *left for later*,
     *will be addressed later*, *TODO*.
4. **Take the enclosing unit** — the smallest piece of text that could carry the issue number.
   For a phrase, that's the sentence, or the list item if the phrase is inside one. For a heading,
   it's each list item or paragraph in the section under it (up to the next heading of the same or
   higher level), checked separately: a "Deferred work" section where three of four bullets cite an
   issue fails on the fourth, and the refusal names *that bullet*, not the section. A section with
   no list and no paragraph break is one unit.
5. **Require an issue reference in each unit**: `#123`, `owner/name#123`, or a full GitHub issue
   URL.
6. **Any failing unit fails the gate.** Refuse; do not open the PR.

### Refusing

Name the offending sentence verbatim — the author has to find it to fix it — say which config key
is in force, and offer the fix. Use this shape:

```text
Not opening the PR: it defers work without naming an issue.

  In the PR body, under "Follow-ups":
  > Rate-limit headers are out of scope for this PR; we'll wire them up in a follow-up.

  No issue reference (#N, owner/name#N, or an issue URL) appears in that sentence.

`createPr.requireIssueForDeferredWork` is true in .claude/maintainerd.json.

To proceed, pick one:
  1. File the follow-up now and cite it — run /create-issue (auto-dev plugin) if it is
     installed, otherwise `gh issue create --repo <config.repo>`, then put the number in
     that sentence. This is the intended path.
  2. Cite an existing issue, if one already covers it.
  3. Drop the promise — reword so the body doesn't commit to work nobody is tracking.
  4. If that "later" is prose rather than a promise, add <!-- no-deferred-work --> to the
     body to bypass this gate for this PR.

No PR was opened; the branch and its commits are untouched. Re-run me once the body
is fixed.
```

Offer to run `create-issue` — don't file the issue unasked. What the follow-up should say is the
author's call, and an issue filed on a guess is worse than the sentence that prompted it.

### What this gate cannot do

Say this plainly when you report a refusal, and don't oversell the check:

- **It matches words, not intent.** A body that says "the cache warms up later" trips it with
  nothing deferred; a real promise phrased without a cue word ("the retry path needs another
  pass") passes untouched. It catches the common phrasings, not the clever ones.
- **It checks presence, not correctness.** `#1` in the sentence satisfies it. Whether that issue
  exists, is open, or has anything to do with the deferred work is not something this gate knows.
- **It reads text, not the diff.** A `TODO` comment added in code is not in scope here.
- **The bypass is per-PR, not per-sentence.** That is deliberate: a per-sentence escape hatch ends
  up next to every sentence, and then the gate is decoration.

### Worked example

The body drafted for a PR adding a rate limiter:

```markdown
## Summary
Adds a token-bucket rate limiter to the public API.

## Follow-ups
- Per-tenant buckets, once the tenancy migration lands.
- Surface the limit in the response headers (#412).
```

The `## Follow-ups` heading is a cue, so each bullet under it is checked. The second cites `#412`
and passes; the first cites nothing, so the gate refuses and quotes it:

```text
Not opening the PR: it defers work without naming an issue.

  In the PR body, under "Follow-ups":
  > Per-tenant buckets, once the tenancy migration lands.
  ...
```

The author runs `/create-issue` ("Per-tenant rate-limit buckets"), gets `#455`, edits the bullet to
`- Per-tenant buckets, once the tenancy migration lands (#455).`, and re-runs. Both bullets now
carry an issue, the gate passes, and `gh pr create` runs.

## Creating the PR

Use `gh pr create` with a HEREDOC for the body to preserve formatting. Pass `--repo config.repo`
and target `config.defaultBranch`:

```bash
gh pr create \
  --repo <config.repo> \
  --base <config.defaultBranch> \
  --title "type: Short description" \
  --body "$(cat <<'EOF'
<the repo's template, headings verbatim, comments replaced with content>
EOF
)"
```

The body's headings come from `config.paths.prTemplate` (see **PR template** above), never from
memory. A quick self-check before running the command: `grep '^##' <template>` and your body
should list the same headings in the same order.

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
