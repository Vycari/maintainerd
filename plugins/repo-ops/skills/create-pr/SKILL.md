---
name: create-pr
description: Create a pull request for the current repository the right way — enforce the repo's PR template, run a `/simplify` pass and a `code-review` self-review, then every CI gate (format, lint, build, typecheck, tests) locally before pushing, require docs updates for user-facing changes, and write an honest, non-marketing PR body. Where the repo sets `createPr.requireIssueForDeferredWork`, it also refuses to open a PR whose body promises follow-up work without naming an issue. Use whenever the user wants to "create a PR", "open a pull request", "submit changes", "prepare changes for review", or "push this for review". Never bypasses verification, never auto-merges.
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

**Run the review gates against the PR's tree, not the session's.** `/simplify` takes no target: it
reviews the diff of the shell's current directory, and `code-review` does the same when given no
target. When the branch lives in a separate worktree (the recommended pattern) and the session was
started in another checkout, a gate run from there reviews that other checkout's diff, and the PR
body would report a review that never looked at the change. So before the gates:

- **Get the PR branch checked out before looking for it.** `BRANCH` is the branch the caller named
  (a delegating skill such as **research-radar** names one and asks for it to be created from
  `config.defaultBranch`), or one you name for this change. Resolve it in this order:

  ```bash
  BRANCH=<the PR branch>
  SESSION=$(git rev-parse --show-toplevel)   # the session's own checkout
  wt_for() { git worktree list --porcelain | awk -v b="refs/heads/$1" \
    '/^worktree /{p=substr($0,10)} $0=="branch "b{print p}'; }
  WT=$(wt_for "$BRANCH")
  git -C "$SESSION" fetch origin <config.defaultBranch>
  ```

  1. **`WT` is set**: the branch is checked out there. Use it.
  2. **The branch exists (locally, or on the remote: `git -C "$SESSION" ls-remote --exit-code
     --heads origin "$BRANCH"`) but is checked out nowhere**: fetch it
     (`git -C "$SESSION" fetch origin "$BRANCH"`) and check it out in the session checkout with
     `git -C "$SESSION" switch "$BRANCH"`, and only when
     `git -C "$SESSION" status --porcelain` is empty. A dirty session checkout here means work that
     belongs to some other branch: stop and say so rather than carrying it across.
  3. **The branch exists neither locally nor on the remote** (a new PR, e.g. a new research-radar digest): create it where
     the change was made, with `git -C "$SESSION" switch -c "$BRANCH"`, which carries the session's
     uncommitted work onto it. When the caller asked to branch from `config.defaultBranch`, first
     confirm `git -C "$SESSION" rev-parse HEAD` equals `git -C "$SESSION" rev-parse
     origin/<config.defaultBranch>`; if it does not, stop and say so, because the new branch would
     carry commits the caller did not ask for.

  Then re-run `WT=$(wt_for "$BRANCH")` and `git -C "$WT" fetch origin <config.defaultBranch>`.
  Only if `WT` is **still** empty, stop and say the branch could not be checked out.
- **Compute the change set**: committed changes against the fetched base, plus anything not yet
  committed (an earlier `--fix` pass, a staged edit, a new file). This is what the gates must cover
  and what "this PR's scope" means below. Keep it as one sorted list:

  ```bash
  EXPECTED=$( { git -C "$WT" diff --name-only origin/<config.defaultBranch>...HEAD
                git -C "$WT" diff --name-only HEAD          # uncommitted, staged or not
                git -C "$WT" ls-files --others --exclude-standard; } | sort -u )
  ```

- **`cd "$WT"` as its own command before invoking each gate**, so the diff the gate reads is the
  PR's. If the shell cannot stay in `$WT` (some harnesses reset the working directory between
  calls), do not run `/simplify`: record it in the PR body as not run because the session could
  not point it at the PR worktree.
- **Confirm each gate covered `$EXPECTED`.** Recompute `$EXPECTED` just before each gate (an edit
  Simplify kept can change it), and compare it with what the gate reviewed:
  - **When the gate names the files it read** (in its summary, findings or the diff it printed),
    sort that list and compare it with `$EXPECTED`. A missing file or an extra one is a mismatch.
  - **When it names none**, its input is the diff of the directory it ran in, so confirm that input
    in the same shell, immediately before invoking it: `git rev-parse --show-toplevel` must print
    `$WT`, and the three commands above run from `.` (not `-C "$WT"`) must give exactly
    `$EXPECTED`.

  Record a review line for the gate only when that comparison matches. On a mismatch, or when
  neither check could be made, its coverage is unconfirmed: **stop before recording a result for
  it**, and either re-run it pointed at the PR (for `code-review`, with `<branch>` as the target,
  from `$WT`) and compare again, or say in the PR body that it ran but its coverage of the PR could
  not be confirmed. Never report an unconfirmed gate as run over the PR.
- **Check both trees after each gate, by content.** `git status --porcelain` cannot tell a gate's
  edit to a file that was already dirty from no edit at all, so compare content hashes instead.
  Hash with `git hash-object`, which every checkout has (stock macOS has no `sha256sum`). Unless
  `$SESSION` is `$WT`, snapshot the session checkout before the gate (define `manifest` in every
  shell that uses it; a harness that resets the shell between calls drops it):

  ```bash
  manifest() (   # HEAD, staged and unstaged content, every untracked file's hash; non-zero on any failure
    # Explicit checks, not `set -e`: errexit is ignored when the caller runs this under `||`, `&&` or `if`.
    set -o pipefail
    git -C "$1" rev-parse HEAD || exit 1
    git -C "$1" diff --cached --binary | git hash-object --stdin || exit 1
    git -C "$1" diff --binary | git hash-object --stdin || exit 1
    t=$(mktemp) && git -C "$1" ls-files -z --others --exclude-standard > "$t" || exit 1
    while IFS= read -r -d '' f; do
      h=$(git -C "$1" hash-object -- "$f") || exit 1; printf '%s %s\n' "$h" "$f"
    done < "$t"; rm -f "$t"
  )
  SNAP=$(mktemp -d) &&
  git -C "$SESSION" rev-parse HEAD > "$SNAP/head" &&
  git -C "$SESSION" diff --cached --binary > "$SNAP/staged.patch" &&
  git -C "$SESSION" diff --binary > "$SNAP/unstaged.patch" &&
  git -C "$SESSION" ls-files -z --others --exclude-standard > "$SNAP/untracked.list" &&
  tar -C "$SESSION" --null -T "$SNAP/untracked.list" -cf "$SNAP/untracked.tar" &&
  manifest "$SESSION" > "$SNAP/before" && echo SNAPSHOT-OK
  ```

  Go on to the gate only when that prints `SNAPSHOT-OK`. Any failed snapshot or manifest command
  means nothing can be compared afterwards: stop and say so rather than running the gate.

  After the gate, run `manifest "$SESSION" > "$SNAP/after"` and `git -C "$WT" status --porcelain`.
  If that `manifest` exits non-zero, or `cmp -s "$SNAP/before" "$SNAP/after"` fails, the gate may
  have worked on the wrong tree: **stop and say so**, and do not record a review line for that
  gate. Do not reset, clean or stash the session checkout yourself: it may be the user's
  interactive checkout, and their earlier work is in it. Keep `$SNAP`, show the user
  `diff "$SNAP/before" "$SNAP/after"`, and hand them these commands, which put the checkout back to
  the snapshot: they undo only the gate's edits and restore the user's earlier staged, unstaged and
  untracked work exactly. The patches go back before the untracked files (a staged `git rm --cached`
  whose file is kept untracked only applies to a clean tree), and the first failing step stops the
  rest:

  ```bash
  git -C "$SESSION" reset -q --hard "$(cat "$SNAP/head")" &&
  git -C "$SESSION" clean -fdq &&     # ignored files are untouched; the user's untracked ones come back last
  { [ ! -s "$SNAP/staged.patch" ] || git -C "$SESSION" apply --index --binary "$SNAP/staged.patch"; } &&
  { [ ! -s "$SNAP/unstaged.patch" ] || git -C "$SESSION" apply --binary "$SNAP/unstaged.patch"; } &&
  tar -C "$SESSION" -xf "$SNAP/untracked.tar" &&
  manifest "$SESSION" | cmp -s - "$SNAP/before" && echo RESTORED
  ```

  Anything but `RESTORED` means the snapshot did not restore cleanly: stop there, and `$SNAP` is the
  only copy of the pre-gate work. Never delete `$SNAP` unless the after-manifest matched the
  before-manifest. Every edit a gate keeps must be inside `$WT`.

1. **Simplify** — invoke the built-in `/simplify` skill (Skill tool, `skill: "simplify"`) on the
   branch's changes. It runs **first** because it may edit code, and every later gate has to check
   the simplified result, not the code as it stood before. Review what it changed with
   `git -C "$WT" diff` and keep only the edits that preserve behaviour and belong in this PR's
   scope; revert the rest. Skip it for a diff that touches no code (docs-only or config-only, the
   same diffs that may skip Build, Type check and Tests below), and say in the PR body that it was
   skipped and why. If the `simplify` skill is not available in the session, say so in the PR body
   — never skip it silently and never report it as run.
2. **Self-review** — invoke the built-in `code-review` skill (Skill tool, `skill: "code-review"`,
   `args: "medium --fix <branch>"`, where `<branch>` is the PR branch, run from `$WT` as above) on
   the branch's changes. Never omit the target: with none, `code-review` reviews the session's own
   diff. It runs after Simplify and before Format, so every later gate checks the fixed code:
   `/simplify` covers quality, `code-review` hunts correctness bugs. Never use the `ultra` level —
   it is a billed, user-triggered cloud review an agent must not launch. Review what `--fix`
   changed with `git -C "$WT" diff` and keep only the edits that fix a real defect within this
   PR's scope; revert the rest. Skip it for a diff that touches no code, as for Simplify, and say
   in the PR body that it was skipped and why. If the `code-review` skill is not available in the
   session, say so in the PR body — never skip it silently and never report it as run. Record the outcome as one line in the PR body's reviewer-facing section, e.g.
   `code-review (medium): 4 findings, 3 fixed, 1 not a defect — <one-line why>`, so downstream
   reviewers see what was already considered. It runs when the PR is created, not on every later
   push: a review-response loop does not repeat it.
3. **Format** — run `config.commands.format`. If it fails, apply the repo's formatter and stage the
   changes, then re-run until clean.
4. **Lint** — run `config.commands.lint`. Fix every reported issue.
5. **Build & type check** — run `config.commands.build`, then `config.commands.typecheck`. Fix any
   type errors. (Some repos fold the type check into the build; if `typecheck` is `null`, the build
   covers it.)
6. **Tests** — run `config.commands.test`. All tests must pass with no warnings or unexpected
   console output.

**A docs-only or config-only diff still runs Format and Lint.** "No source file changed" is not a
reason to mark them N/A: formatters increasingly reach into prose — `ruff format` rewrites Python
code blocks *inside Markdown*, Prettier formats fenced code and the Markdown itself — and CI runs
the same command over the whole tree. A design doc with one mis-spaced code sample passes every
docs check and then fails the format gate. Only Simplify, Self-review, Build, Type check and Tests may be
skipped for a diff that touches no code, and the PR body says which were skipped and why.

**A command that cannot start is a failure to fix, not a step to skip.** A fresh worktree or
sandbox often has no environment yet (`Failed to spawn: ruff`, `command not found`). Install the
repo's dev dependencies the way its docs or CI do (e.g. `uv sync` with the dev extra/group,
`npm ci`) and re-run. If the tool genuinely cannot be installed, run the same tool at the repo's
pinned version another way (`uvx ruff@<locked version>`, `npx <tool>@<pinned>`), and say so in the
PR body — never report a gate as passed, or as N/A, because it would not run.

Do NOT skip these steps. Do NOT push code that fails any of these checks. Do NOT use `--no-verify`
to bypass git hooks. **Tests must pass before the PR opens** — never open a PR on a red suite and
promise to fix it later.

Also confirm the PR worktree is in a clean, intentional state: review `git -C "$WT" status` and
`git -C "$WT" diff`, stage only the changes that belong in this PR, and make sure no stray or generated files are
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

### When GitHub's GraphQL API is blocked

Some sandboxes allow GitHub's REST API and refuse its GraphQL one. `gh pr create` is GraphQL
underneath, so it returns 403 there while `gh auth status` stays green. Check once, before creating
the PR, and reuse the answer:

```bash
# The caller's setup step may declare it; otherwise probe once.
[ -n "${GH_GRAPHQL_BLOCKED:-}" ] || gh api graphql -f query='{viewer{login}}' >/dev/null 2>&1
```

A non-zero probe means blocked — fail closed rather than retrying the porcelain. When blocked, push
the branch as usual and open the PR with `POST /repos/{owner}/{repo}/pulls`; the exact call, its
parameters, and how to build the body safely from a file are under **Create a PR** in
[`../../references/gh-rest-fallbacks.md`](../../references/gh-rest-fallbacks.md). Everything above
this section — pre-flight, the template, the deferred-work gate — is unchanged; only the last
command differs. Say in your run report that the REST path was used, and how it was decided.

### Labels

If the caller asked for labels on the PR — a human naming them, or another skill delegating here
(the **auto-dev** pipeline passes its `config.autoDev.prLabel` so external review tooling can
recognize automated PRs) — apply them with `--label` **on the create call above**, not with a
follow-up `gh pr edit`. Review bots react to the `opened` webhook within seconds, and a label added
afterwards doesn't retract a review that already started. Labels must already exist; this skill
never creates them. Left unasked, don't invent labels — an unlabeled PR is the normal outcome here.

**On the REST path there is no `--label` to pass.** `POST /pulls` has no `labels` field, so labels
are always a second call (`POST /issues/{n}/labels`) landing after the `opened` webhook. Which is
tolerable depends on what the label is for, and
[`../../references/gh-rest-fallbacks.md`](../../references/gh-rest-fallbacks.md) spells out the two
branches under **Create a PR**: a routing label → create non-draft, label right after, note the
ordering; a label that must be in place *before* a review bot starts → create as a draft, label it,
then **stop and report**, because `gh pr ready` is a GraphQL-only mutation with no REST equivalent.
Tell the caller the PR is a draft and name the command or click that finishes it — never hand back
a draft as if it were open for review, and never drop the label to avoid the problem.

### Title conventions

- Keep under 70 characters
- Use conventional commit prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`
- Use imperative mood: "Add feature" not "Added feature"

## After creating the PR

- Return the PR URL to the user.
- **Do not auto-merge.** Leave the PR for review.
- Monitor for review comments (CodeRabbit, other bots, and human maintainers) and address them.
