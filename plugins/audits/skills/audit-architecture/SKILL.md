---
name: audit-architecture
description: Walk the repo's source in the configured language looking for technical debt — oversized files, DRY violations, dead code, missing tests, sloppy typing, weak abstractions, and drift against the repo's documented invariants. Categorize each finding into a discrete unit of work; open a focused PR for mechanically-safe fixes and file a GitHub issue for refactors that need design discussion. One PR or one issue per finding — never bundled. Use when the user asks to "audit the architecture", "find tech debt", "look for code smells", "do an architecture sweep", or when invoked nightly by a scheduled remote agent. Has working-tree side effects (branches + PRs) and GitHub side effects (issues, labels). Quiet-day result is "codebase looks good" with no PR or issue — that's a valid outcome.
---

# Audit the architecture and file discrete units of work

This skill is the repo's nightly tech-debt sweep. It looks at the source the way a diligent senior reviewer would on a slow Friday afternoon, finds the structural problems that don't trip CI but accumulate into pain, **categorizes each finding into a single unit of work**, and either fixes it (one focused PR) or files it for human review (one issue) — never both, never bundled.

The skill is **deliberately conservative**: it caps the number of PRs and issues it opens per run, refuses to land sprawling changes overnight, and skips findings that already have an open PR or issue. A clean run that reports "codebase looks good" is the expected steady state on most nights.

## Load the repo config

Before doing anything else, load the repo config (see [`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. **If it does not exist, STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill uses: `config.repo`, `config.defaultBranch`, `config.language`, `config.paths.source`, `config.paths.tests`, `config.paths.skillsDir`, `config.commands.format`/`lint`/`build`/`test`, `config.guidelines.invariants`, `config.guidelines.coding`, `config.labels.architecture`, `config.labels.automated`, `config.audits.prCap`, `config.audits.issueCap`, `config.audits.promoteThreshold`, `config.audits.promoteLookbackDays`. Treat any `null` command as *"this repo has no such step — skip it"*. For any key that is **absent**, fall back to the documented default (caps default to 3 PRs / 5 issues; pattern-promotion defaults to a threshold of 3 within 90 days) and mention the fallback in your run report.

Throughout this skill, `config.<path>` refers to a value from that file. In the detection commands below, `config.paths.source` stands for your configured source root (e.g. `src/pepper/` or `src/`) and `config.paths.tests` your test root — substitute the literal value when you run them.

Your linter/formatter already enforces the mechanical rules on every commit (CI + hooks) — see `config.commands.lint`/`config.commands.format`. **Don't re-file what the linter already catches**; those would already be red. This skill targets the structural issues the linter can't see: shape, cohesion, dead surfaces, and the repo's documented invariants.

## What it looks for

Each category has a default detection method and a default routing decision (PR vs. issue). The routing is a default — apply judgment when the situation deviates.

The detection table is **language-switched on `config.language`**: run the `### Python` or `### TypeScript` block that matches your repo. Two things run for **every** repo regardless of language:

- **Repo-invariant drift** (below) always runs — it's driven by `config.guidelines.invariants`, not by language.
- If `config.language` is **neither** `python` nor `typescript`, there is no language block to run; fall back to the **language-generic** categories only — oversized files (by plain line count), DRY violations, and weak abstractions — plus Repo-invariant drift, and **say so in the report**.

### Repo-invariant drift (all languages)

| Category | Detection | Default routing |
| --- | --- | --- |
| **Repo-invariant drift** | Read the rules in `config.guidelines.invariants` and check recent changes against **each one** (`git log`/`git diff` since the last audit, or the current state of recently-touched files). These are the load-bearing, repo-specific invariants CI doesn't catch — the file spells them out (e.g. lifespan/state wiring, secret handling, idempotent inbound channels, "use the logger not `console`/`print`", commit-before-emit ordering). The same guidelines also name the **generated / auto-generated files to skip** — never flag those for any category. | **Route per the PR-vs-issue rule** (step 4): a mechanical, local fix → PR; a fix that spans files or needs design discussion → issue. Most invariant fixes span files and are **issues**. |

If `config.guidelines.invariants` is missing or still full of `TODO` markers, note that in the report (invariant coverage is only as good as that file) and proceed with the categories you can still check.

Detection mechanics per language — the greps, tools and thresholds — live in
[`references/language-detection.md`](references/language-detection.md). Read the block matching
`config.language`; the judgment about what counts as a finding stays in the table above.

## What it does NOT look for

- **Formatting and style.** The formatter owns those (`config.commands.format`, pre-commit hook + CI gate). If formatting drifted, that's a CI bug, not architecture.
- **Anything the linter already lints.** Those rules are red on every commit (`config.commands.lint`). Don't re-file them — they wouldn't have made it past the hook.
- **Test pass/fail.** This skill checks test *existence* per subsystem/module, not test quality. Test-suite quality belongs to the **`audit-tests`** skill.
- **Performance.** Micro-optimization isn't tech debt; the skill is about structure, not throughput.
- **Documentation drift.** The **`audit-design-docs`** skill owns that (and **`audit-product-docs`** owns user-facing docs). If a finding here happens to surface a doc issue too, mention it but don't fix it — the next docs-audit run will.
- **Security review.** That's `/security-review`'s job.
- **Generated / auto-generated files.** Migrations, generated help references, generated API clients, etc. — these are output, not architecture surface. The list of paths to skip lives in `config.guidelines.invariants`; skip whatever it names. The fix for generated drift is in the source, not the output.
- **Markup-heavy directories.** Templates and static/legal pages where line-count thresholds don't apply; skip whatever the guidelines flag.

## Workflow

Track each finding as you process it (use your task/todo tool) — the audit can sprawl across many files and you'll lose your place without it.

### 1. Pre-flight: start clean

```bash
git status --short        # working tree must be clean
git checkout <config.defaultBranch>
git pull
```

If the working tree isn't clean, stop and report — don't try to stash. A dirty tree probably means a human is mid-work; this skill is for fully idle moments.

Exception: untracked files under `config.paths.skillsDir` are skill scaffolding, not in-progress source work. Treat them as benign — proceed with the audit, but stage carefully (`git add <specific-path>`) on each branch so they don't leak into the audit PRs.

### 2. Sweep the categories

Run each detection step for the block that matches `config.language`, plus **Repo-invariant drift** (always). **Collect findings into a list — don't open any PRs or issues until the sweep is complete.** This lets you de-dup across categories (e.g. an oversized file may also have several `Any`/`any` sites; bundle those into one issue rather than three).

Suggested order, fast-to-slow:

The per-language order — fast greps first, reading passes last — is in
[`references/language-detection.md`](references/language-detection.md) under **Order to run the
sweep**, alongside the detection commands themselves. Keeping order and commands together is what
stops the two drifting apart.

### 3. De-duplicate against existing work

For each finding, check whether it's already tracked:

```bash
# Open issues with the architecture label
gh issue list --repo <config.repo> \
  --state open --label <config.labels.architecture> --json number,title,body --limit 100

# Open PRs (any author)
gh pr list --repo <config.repo> \
  --state open --json number,title,headRefName --limit 50
```

Skip a finding if any of:

- An open issue mentions the same file/symbol/category.
- An open PR's branch name matches the slug you'd use for this finding (see step 5).
- The skill opened the same issue in a previous run and a human closed it `wontfix` / **Not planned** — don't re-file. Check with:
  ```bash
  gh issue list --repo <config.repo> \
    --state closed --label <config.labels.architecture> \
    --search "is:closed reason:not-planned" \
    --json number,title --limit 50
  ```
  (Also check the `config.labels.automated` label if this repo applies it.)

### 4. Categorize each finding into a unit of work

For each surviving finding, decide:

- **One PR** if all of:
  - Fix is < ~150 lines of diff.
  - Touches ≤ 5 files.
  - The correct change is mechanical (the reviewer would say "yes obviously" without design discussion).
  - It won't cause behavior change beyond what's claimed.
- **One issue** otherwise. Issues describe the finding + a proposed plan; they do not commit to a specific diff.

If you're unsure, default to **issue**. A merged PR is harder to undo than a closed issue.

**Umbrella vs. individual issues.** When a single category produces many similar findings (e.g. 8 subsystems with no test coverage, 50+ missing-test files, 5+ oversized files), the right shape is usually **one umbrella issue with a prioritized list of sub-targets**, not 5 thin issues that each say "module X needs Y." Use an umbrella when all are true:

- The findings share a single root cause or rationale.
- A reviewer would want to weigh them against each other (which 3 of the 8 untested subsystems matter most?), not pick them up in isolation.
- The list would otherwise blow past the per-run cap and force half the findings into "deferred."

The umbrella body should list every finding it covers, grouped by priority, with explicit out-of-scope items so the picker-upper can split it into sub-issues without re-doing triage. Don't use an umbrella to dodge the cap when the findings are genuinely independent; that just trades a flood of issues for a single unreviewable mega-issue.

### 5. Open PRs (capped at `config.audits.prCap` per run)

For each PR-routed finding, in priority order (highest-impact first):

```bash
# Each PR gets its own branch — never reuse a branch across findings
SLUG="arch-<category>-<short-descriptor>"   # e.g. arch-any-gmail-service
git checkout <config.defaultBranch> && git checkout -b "$SLUG"
```

Branch naming convention: `arch-<category>-<descriptor>` (kebab-case, ≤50 chars). The `arch-` prefix makes it easy to see automated audit branches at a glance.

Make the fix. Keep it laser-focused: **do not** clean up nearby unrelated code, **do not** rename for taste, **do not** add comments unless the original was load-bearing. The PR's blast radius must match its claim. If you find yourself "while I'm here"-ing, stop and route the extra finding to a separate issue.

**Open the PR.** If the **`create-pr`** skill is installed, delegate to it — it runs the repo's pre-flight before pushing; do not bypass it. If `create-pr` is **not** installed, run pre-flight inline, executing each of `config.commands.format`, `config.commands.lint`, `config.commands.build`, and `config.commands.test` that is **not `null`** (skip the null ones):

```bash
# Run only the commands that are non-null in config; example for a Python repo:
uv run ruff format --check      # config.commands.format
uv run ruff check               # config.commands.lint
uv run pytest                   # config.commands.test
```

All must pass. If any fails on code you didn't touch, the failure is unrelated — abandon this finding before pushing: `git checkout <config.defaultBranch> && git branch -D "$SLUG"` (nothing's been pushed yet, so there's no remote branch or PR to close). Capture the failure in the report and continue with the next finding. Don't try to fix unrelated test failures here. **No `--no-verify`, no skipping the hook.** This skill's whole credibility rests on its PRs being mergeable on first read.

Push and open the PR:

```bash
git push -u origin "$SLUG"
gh pr create --repo <config.repo> \
  --title "<prefix>: <one-line description>" \
  --label <config.labels.architecture> --label <config.labels.automated> \
  --body "$(cat <<'EOF'
## Summary

audit-architecture nightly sweep flagged: **<category>** in `<file>`.

<2–3 sentences: what the smell is, what the fix is, why it's safe.>

## Changes

- <bullet per file touched>

## Test plan

- [x] format check clean (`config.commands.format`)
- [x] lint clean (`config.commands.lint`, if non-null)
- [x] tests clean (`config.commands.test`)
- [ ] <any feature-specific manual check, if applicable>

---

_Filed by the `audit-architecture` skill._
EOF
)"
```

Match the conventional prefix to the work (`refactor:`, `chore:`, `fix:`).

**Stop at `config.audits.prCap` PRs.** Remaining PR-routed findings get re-routed to issues for this run; the next nightly run will pick them up as PRs if they're still relevant. A flood of similar PRs trains reviewers to ignore them.

### 6. File issues (capped at `config.audits.issueCap` per run)

For each issue-routed finding (and any PR-routed overflow), file one issue:

```bash
gh issue create --repo <config.repo> \
  --title "<category>: <one-line problem>" \
  --label <config.labels.architecture> --label <config.labels.automated> \
  --body "$(cat <<'EOF'
## What

<One paragraph: the smell, where it lives, why it's worth addressing.>

## Evidence

- `<config.paths.source>path/to/file:42–68` — <snippet or pattern>
- `<config.paths.source>path/to/other:103` — <duplicate location>

## Proposed unit of work

<3–6 bullets describing the smallest reasonable change that addresses the
finding. Be concrete — name the file(s) to create or split, the symbols to
move, the tests to add. Don't write the code; describe it.>

## Out of scope

<What this issue is _not_ — to keep the scope tight when someone picks it up.>

---

_Filed by the `audit-architecture` skill. If this isn't worth doing, close as **Not planned** / `wontfix` — the skill checks closed-not-planned and won't refile._
EOF
)"
```

**Stop at `config.audits.issueCap` issues.** Remaining findings are deferred to the next run. Capture them in the report so the human caller knows the backlog is growing.

### 7. Systemic escalation (recurring patterns)

Before reporting, run the **pattern-promotion** check — the loop that turns a nightly treadmill into
a ratchet. If this run's finding is an instance of a *specific, encodable pattern* this audit has
already fixed or filed `config.audits.promoteThreshold` times (default 3) within
`config.audits.promoteLookbackDays` (default 90), file **one** human-gated issue proposing the pattern
become a rule in `config.guidelines.invariants` (load-bearing/structural patterns) or
`config.guidelines.coding` (conventions like logger-not-`print`, typing style) — or, if the rule
already exists and keeps being violated, a **mechanical guard** (a lint rule / CI check) instead —
rather than only fixing the instance again. The full mechanism, history queries, dedup marker, and issue template live
in [`../../references/pattern-promotion.md`](../../references/pattern-promotion.md); this audit's
`<audit-name>` is `architecture` and its branch prefix is `arch-`. This proposal is **in addition to**
the normal fix, does **not** count against the PR/issue caps, and is capped at one per run. Never
auto-edit the guideline file — propose; the maintainer decides.

### 8. Report

Reply to the caller with a structured summary:

```text
Architecture audit — YYYY-MM-DD

Sweep scope: <N> source files, <M> lines analyzed   (language: <config.language>)
Findings: <total>
  - Routed to PR: <count> (opened <opened>, skipped-as-duplicate <dupes>)
  - Routed to issue: <count> (filed <filed>, skipped-as-duplicate <dupes>)
  - Deferred (over cap): <count>

PRs opened:
- #NNN  arch-any-gmail-service — replace 3 `Any` types in <file>
- #NNN  arch-console-tools-cleanup — swap console/print for the logger in 4 files
- ...

Issues filed:
- #NNN  oversized-file: <file> (828 lines) — propose split into <plan>
- #NNN  dry-violation: client setup duplicated between <a> and <b>
- ...

Deferred (will retry next run):
- <finding> — over PR cap, didn't route to issue because <reason>

Pre-flight failures (PRs not opened):
- arch-any-loop-types — tests failed on <test> (unrelated)

Systemic: proposed encoding <pattern> as a rule in <guideline file> (or a mechanical guard if the rule already exists) — issue #NNN (seen <N>× in <days>d)

No findings in: <list of categories that came up clean>
```

If the total finding count is zero, the entire report collapses to:

```text
Architecture audit — YYYY-MM-DD

Sweep scope: <N> source files
Findings: 0 — codebase looks good.
```

That's the expected steady-state output. Don't pad it with positive observations or "good job" notes; absence of findings is the message.

If `config.language` was neither `python` nor `typescript`, note in the report that only the language-generic categories (oversized files, DRY, weak abstractions) plus Repo-invariant drift were run. If `config.guidelines.invariants` was missing or stubbed, note that too.

## Calibrating scope

A healthy codebase produces 0–3 findings per nightly run. A run that surfaces 0 should report cleanly and stop. A run that surfaces >10 means real debt has accumulated — flag it in the report and let the maintainer decide whether to ratchet the thresholds tighter or schedule a focused debt-paydown sprint.

Tune the per-run caps (`config.audits.prCap` / `config.audits.issueCap`) downward if reviewers report fatigue. Tune upward only if the human caller explicitly asks for a deeper one-time sweep ("really go after the tech debt this weekend").

**Threshold tuning.** The size thresholds in the category tables (500 / 600 / 800 / 700 / 1000 lines, 15 public methods/members, etc.) are first-cut defaults — ratchet them tighter once the obvious offenders have been split. For example, once a chronically-large file drops below its bar, lower the threshold so the next overgrowth gets caught early. Don't loosen thresholds to make a noisy category quiet; that defeats the audit. Edit the thresholds in [`references/language-detection.md`](references/language-detection.md) (or a repo-local override) so future runs pick them up — that file is now the single home for anything language-specific.

## What not to do

- **Don't bundle findings into a single PR.** "Misc architecture fixes" PRs are unreviewable. One unit of work per PR. If two findings genuinely belong together, that's one finding — describe it that way.
- **Don't open a PR for a finding that needs design discussion.** Splitting a large module, extracting a shared client, changing a public interface or router surface — all of these are issues, not PRs, no matter how confident the agent feels.
- **Don't re-file what the linter already catches.** Those are red on every commit. If you see one, the pre-commit hook is broken or someone bypassed it; flag that separately, don't open a PR.
- **Don't reuse a branch from a previous run.** Each PR gets a fresh branch off `config.defaultBranch`. Same-named findings on subsequent runs are an indication of skipped de-dup, not a reason to push onto the old branch.
- **Don't re-file an issue that was closed Not planned / `wontfix`.** Check closed issues with the `config.labels.architecture` label before filing. That close is the maintainer's standing answer.
- **Don't comment on existing issues or PRs.** This skill files new ones or stays silent. Threaded discussion on prior automated issues belongs to humans.
- **Don't edit generated files.** The fix for generated drift is in the source, not the output. The skip list lives in `config.guidelines.invariants`.
- **Don't skip pre-flight.** No `--no-verify`, no skipping format/lint/build/test (whichever are non-null in `config.commands`). The audit's whole credibility rests on its PRs being mergeable on first read.
- **Don't push to `config.defaultBranch`.** Always branch + PR.
- **Don't operate on a dirty working tree.** A pre-existing diff in tracked source/test/doc paths means a human is mid-work; back off and report. Untracked skill scaffolding under `config.paths.skillsDir` is the one exception — see step 1.
- **Don't bypass the per-run caps** "just this once." The caps exist to keep the review burden sustainable; the next run will pick up the deferred findings.
- **Don't auto-merge.** Even green CI doesn't mean a refactor is right. Every PR this skill opens waits for human review and merge.
- **Don't auto-edit `invariants.md`/`coding.md`.** When a pattern recurs past the threshold, *propose* the rule as an issue (step 7); the maintainer edits the guideline. Never file more than one promotion per run, and never re-propose one closed Not planned.

## When integrated with scheduling

Cadence, the `daily-update` relationship, and the model tier this run wants are in
[`references/scheduling.md`](references/scheduling.md).
