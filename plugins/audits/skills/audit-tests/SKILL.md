---
name: audit-tests
description: The repo's test-suite health expert. Reviews the test suite the way a senior staff engineer who cares about test quality would — coverage gaps on critical paths, inappropriate or excessive mocking (mocking what you own, mocks that never assert, asserting on mock internals over behavior), weak or absent assertions, brittle test strategy (testing private implementation, over-pinned arg matchers, golden-snapshot noise), flaky patterns (unfrozen time/randomness, real network, sleeps, order dependence), fixture smells, test duplication that wants parametrization/table-driven cases, rotting skip/xfail, and drift from the repo's own documented test conventions. FIX-FIRST: open one focused PR per mechanically-safe fix; file an issue only for design-heavy test-strategy changes. Scoped to TEST quality only — source-architecture findings are deferred to the `audit-architecture` skill. SILENT ON CLEAN: a run that finds nothing (even nitpicks) produces no PR, no issue, and no report. Built to run unattended several times a day, so dedup is strict and per-run caps are low. Reads the repo's test conventions from `config.guidelines.testing`. Use when the user asks to "audit the tests", "check test quality", "find test smells", "review the test suite", or when invoked by a scheduled remote agent. Has working-tree side effects (branches + PRs) and GitHub side effects (issues, labels).
---

# Audit the test suite and fix what's safe to fix

This skill is a recurring test-health sweep. It reads the **test suite** the way a senior staff engineer who is opinionated about testing would — finding the quality problems that don't fail CI (the suite is green) but quietly erode the suite's value: tests that pass without proving anything, mocks that hide the bug they should catch, coverage that looks fine in aggregate but misses the error path that actually breaks in prod. It **fixes what is mechanically safe** (one focused PR per finding) and **files an issue** only for changes that need design discussion.

Two properties make this skill safe to schedule several times a day:

- **Silent on clean.** A run that surfaces no findings — including nitpicks — opens no PR, files no issue, and prints no report. Absence is the signal. Most runs should be silent.
- **Strict dedup, low caps.** Because it runs unattended and often, it never re-opens a fix that already has an open PR/issue, never re-files something a human closed `wontfix`, and caps itself hard per run so it can't flood review.

## Load the repo config

Before anything else, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **STOP** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.

   Do not guess values or hardcode another repo's settings.
3. Read the keys this skill needs:
   - `config.repo` — GitHub `owner/name`, passed to every `gh ... --repo`.
   - `config.defaultBranch` — the branch audits check out and PRs target.
   - `config.language` — `python` | `typescript`; selects the language-specific mechanics below.
   - `config.paths.tests` — root of the test tree (everything in scope lives under here).
   - `config.paths.source` — root of the source the suite covers.
   - `config.commands.test` — the suite that must be green before and after a fix.
   - `config.commands.coverage` — coverage command. **If `null`, skip the coverage-gap category entirely** (don't invent one).
   - `config.commands.format` / `config.commands.lint` — pre-flight gates (skip any that are `null`).
   - `config.labels.testQuality` / `config.labels.automated` — labels applied to every PR/issue this skill opens.
   - `config.audits.testPrCap` / `config.audits.testIssueCap` — per-run caps (default **2 / 2** if absent; note the fallback in your report).
   - `config.audits.promoteThreshold` / `config.audits.promoteLookbackDays` — pattern-promotion knobs (default **3** within **90** days if absent). See step 7.
   - `config.guidelines.testing` — **the repo's own test conventions.** Read this file in full; it holds the repo-specific rules (the DB/fixture pattern, what may and may not be mocked, isolation rules, assertion expectations, redundant framework boilerplate, naming) that this skill checks the suite against. If it's missing or still full of `TODO` markers, say so in your report and proceed with the language-generic checks only.

Treat a `null` command as **"this repo has no such step — skip it, don't invent one."**

## Scope: tests only

This skill audits **test quality**. It is the sibling of `audit-architecture`, which owns the **source** side (oversized modules, source DRY, source typing, dead exports, source invariants). To avoid two schedulers opening competing PRs:

- **In scope:** anything under `config.paths.tests` — the tests themselves, the fixtures, the conftest/setup files, the fakes and test doubles, test helpers, and the *coverage* of `config.paths.source` as measured by the suite.
- **Out of scope (defer to `audit-architecture`):** refactoring `config.paths.source` for its own sake. The one overlap — "this source module has **zero** tests" — belongs to `audit-architecture`'s missing-tests category; don't duplicate it here. This skill instead improves the *quality* of tests that already exist and closes *coverage gaps within already-tested modules* (the uncovered error path, the unexercised branch).
- If a test smell can only be fixed by changing source (e.g. code is untestable because a dependency is hard-wired instead of injected), **file an issue** describing the testability problem; don't refactor the source here.

The repo's formatter/linter and the test hook already gate the obvious. Don't re-file what they catch. This skill targets what they can't see: whether a passing test actually tests anything.

## What it looks for

Each category has a default detection method and a default routing decision (PR vs. issue). Routing is a default — apply judgment. The detection commands here are described language-agnostically; the exact greps and tool flags for `config.language` are in [Language-specific mechanics](#language-specific-mechanics).

| Category | Detection | Default routing |
| --- | --- | --- |
| **Coverage gaps on tested modules** | Run `config.commands.coverage`, then read its machine-readable report for files with covered lines but uncovered **branches** or error/exception paths. Focus on modules that *have* tests but leave a meaningful branch uncovered — the `catch`/`except`, the early-return guard, the cap-fallback. **Skip this whole category if `config.commands.coverage` is `null`.** | **PR** if the missing case is a small, obvious test to add (≤ ~60 lines, one behavior); **issue** if covering it needs new fixtures or non-trivial setup |
| **Mocking what you own** | Read tests that mock/patch an internal collaborator that could be exercised for real. The cardinal repo-specific case — e.g. mocking the DB layer instead of using the real test-DB fixture — **lives in `config.guidelines.testing`**; read that file and flag tests that violate it. Catch every mock constructor, not just one (see the language section's greps), then verify each hit is a legitimate placeholder (the unit under test doesn't touch the real collaborator) vs. a mock standing in for real behavior the test should assert against. | **PR** if swapping to the real fixture is local and the assertions still hold; **issue** if it reshapes the test |
| **Mocks that never assert** | A mock created and passed in but never checked (no call/await assertion) and whose return value isn't asserted on either — the mock is decorative, the test proves nothing about the interaction. Grep for mock construction, then confirm a corresponding assertion exists. | **PR** — add the missing behavioral assertion, or simplify away the mock |
| **Asserting on mock internals over behavior** | Tests that assert a mock was called with some incidental positional/argument shape instead of the observable outcome — brittle, breaks on harmless refactors. Prefer asserting the effect (DB row, returned value, emitted event). | **Issue** if rewriting the assertion changes what's tested; **PR** if it's a clean tighten |
| **Weak / absent assertions** | Two reliable greps: tests whose body has **no assertion** at all (exercise-only), and over-broad "expects any error" assertions where a specific type/message is meant. The "truthiness where a value check belongs" smell (a test whose **only** assertion is `assert x` / `x is not None` / `expect(x).toBeTruthy()`) is *not* a useful grep — those guards legitimately precede real assertions, so a bare grep over-matches by 10×. Find it by reading short test bodies, not sweeping. | **PR** — strengthen to assert the actual value / specific error |
| **Flaky patterns** | Grep for sleeps; unfrozen current-time / `random` in a test that asserts on the result; real network to a live host; tests that depend on execution order or shared module-global mutable state. | **PR** if the fix is freeze-the-clock / inject-the-value / use fake timers; **issue** if it needs a fixture redesign |
| **Redundant framework boilerplate** | Per `config.guidelines.testing`: a decorator/marker the repo's test config has made a no-op (e.g. a per-test async marker that auto-mode makes redundant, a leftover `.only`/`.skip` that disables the rest of the file). Read the convention there; don't assume one. | **PR** — mechanical removal (roll all hits in one file, or a few files, into one PR) |
| **Rotting skip / xfail** | Grep for the skip/expected-fail markers; flag any without a stated reason, and any expected-fail that now passes. | **PR** if the test now passes (un-skip it) or the skip is clearly obsolete; **issue** if the skip hides a real open bug |
| **Test duplication → parametrize** | Manual reading: 3+ near-identical test bodies differing only in input/expected — the textbook parametrized / table-driven case (`@pytest.mark.parametrize`, `it.each`/`test.each`). Also copy-pasted setup blocks across tests in a file that want a shared fixture/helper. | **PR** if the collapse is mechanical and the cases stay readable; **issue** if it's a big restructure |
| **Fixture smells** | Unused fixtures (defined, never requested); fixtures with hidden side effects; suite/session-scoped fixtures holding **mutable** state that can leak across tests; setup duplicated across files that belongs in a shared conftest/setup. | **PR** for unused-fixture deletion; **issue** for scope/leak redesign |
| **Slow tests** | Run the suite with the runner's slowest-tests report; flag individual tests far above the median (e.g. a unit test taking seconds because it sleeps, hits the network, or rebuilds heavy state per-case). | **Issue** — speeding up usually means restructuring setup |
| **Repo test-invariant drift** | Read the conventions in `config.guidelines.testing` and **check the suite against each one.** These are the repo's load-bearing test rules CI doesn't enforce — the DB/fixture isolation pattern, fixtures that must mirror a source change (e.g. a new app-state attribute mirrored in the test client fixture), user-facing rendering rules (timezone/locale), teardown that must rely on the rollback rather than be hand-rolled. Flag each violation against the rule as written. | **Issue** — these are load-bearing and the fix often spans setup + tests |
| **Untestable source (testability smell)** | Surfaced while writing/reading a test: source that can't be tested without mocking because a dependency is constructed inline instead of injected (e.g. a client built inside a function instead of passed in). | **Issue** — the fix is a source change; describe it, don't make it (that's `audit-architecture`/a human's call) |

The table isn't exhaustive, but every addition must be an **objective, nameable test-quality smell** that obeys the same routing rule and the "Scope: tests only" / "What it does NOT look for" sections — not source review, not subjective style. Concretely, also capture any of:

- A non-descriptive test name (`test_it_works`, `test_1`, `it('works')`) that doesn't state the behavior under test.
- A single test asserting several **unrelated** behaviors (should be split into focused tests).
- A test double / fake that has drifted from the real interface it stands in for (asserts pass against a contract production no longer has).
- A fixture or test helper that swallows errors or hides failures (bare `except` / empty `catch`, unconditional `return`).
- A tautological assertion (`assert x == x`, `expect(x).toBe(x)`, `assert mock.return_value == mock.return_value`).
- A test coupled to private implementation (asserts on an underscore-prefixed / non-exported attribute or method that isn't part of the contract).
- A golden-snapshot test whose snapshot is so large or volatile it's noise — it re-blesses on every harmless change and catches nothing.

Route each the same way: mechanical and behavior-preserving → PR, judgment-heavy or reshaping → issue. Anything about *source* goes to `audit-architecture`; anything that's a matter of taste (naming preference, comment density) is out of scope — don't open work for it.

## Language-specific mechanics

The smells above are language-agnostic. The exact detection commands and the framework names depend on `config.language`. Apply the equivalent for whichever language the config declares; read `config.guidelines.testing` for the conventions that are specific to this repo's runner.

### When `config.language` is `python`

Framework: pytest + `unittest.mock`. Treat `config.paths.tests` as the grep root.

- **Mocked collaborators / sessions:** `grep -rnE "(MagicMock|AsyncMock|Mock)\(" <tests>` and read for `patch("...")` / `patch.object(...)`. Cross-reference each against the "what may not be mocked" rule in `config.guidelines.testing` (e.g. mocking the DB session instead of the real test-DB fixture).
- **Weak assertions / broad raises:** `grep -rn "pytest.raises(Exception)\|pytest.raises(BaseException)" <tests>`; scan for assertion-free test bodies.
- **Flaky:** `grep -rn "time\.sleep\|asyncio\.sleep" <tests>`; scan for unfrozen `datetime.now()`/`date.today()`/`random` in result-asserting tests (the fix is `freezegun`/`freeze_time` or injecting the value).
- **Skip/xfail rot:** `grep -rn "@pytest.mark.skip\|@pytest.mark.xfail\|pytest.skip(" <tests>` — flag any without `reason=`, and any `xfail` that now passes (`--runxfail` reports XPASS).
- **Redundant framework boilerplate:** if `config.guidelines.testing` says the repo runs pytest-asyncio in `asyncio_mode = "auto"`, then `@pytest.mark.asyncio` is a no-op — `grep -rn "@pytest.mark.asyncio" <tests>` and remove. Don't assume auto-mode; confirm it in the guidelines first.
- **Parametrize:** the duplication target is `@pytest.mark.parametrize`.
- **Slow tests:** `<config.commands.test> --durations=25 -q`.
- **Coverage:** `config.commands.coverage` typically emits `coverage.json` (branch coverage on); read it for covered-lines-but-uncovered-branches.

### When `config.language` is `typescript`

Framework: the repo's test runner (Jest or Vitest — check `config.commands.test`). Apply the equivalent of each python check.

- **Mocked collaborators:** `grep -rnE "(jest|vi)\.(mock|fn|spyOn)\(" <tests>` and read each. Cross-reference against the "what may not be mocked" rule in `config.guidelines.testing`. Spying on / mocking a module you own that could run for real is the same smell as the python session-mock case.
- **Weak assertions / broad throws:** flag `expect(...).toThrow()` with no error matcher, and test bodies with **no `expect(...)`** at all. Tighten `toThrow()` to a specific error type/message.
- **Flaky:** `grep -rnE "setTimeout|new Promise\(.*setTimeout" <tests>` for real-time waits; unfrozen `Date.now()`/`Math.random()` in result-asserting tests. The fix is **fake timers** (`jest.useFakeTimers()` / `vi.useFakeTimers()` and `setSystemTime`) or injecting the value — the direct analog of freezing the clock.
- **Skip/only rot:** `grep -rnE "\.(skip|only|todo)\(|xit\(|xdescribe\(" <tests>`. A stray `.only` is a real smell — it silently disables every other test in the file; a `.skip`/`xit` without a comment reason is rot.
- **Redundant framework boilerplate:** per `config.guidelines.testing` — leftover `.only`, redundant `async` wrappers, etc.
- **Parametrize:** the duplication target is `it.each` / `test.each` / `describe.each`.
- **Golden-snapshot noise:** oversized or volatile `toMatchSnapshot()` / inline snapshots that re-bless on every change.
- **Slow tests:** the runner's slow-test reporting (Jest `--verbose` timings; Vitest's slow-test reporter).
- **Coverage:** `config.commands.coverage` typically emits `coverage-summary.json` / lcov; read it for uncovered branches in already-tested files.

## What it does NOT look for

- **Source architecture.** Oversized source modules, source DRY, source typing, dead source exports, source invariants → `audit-architecture`. A source module with **zero** tests is also that skill's call, not this one.
- **Formatting / lint.** The repo's formatter/linter owns it (hook + CI). Don't re-file what `config.commands.format` / `config.commands.lint` catch.
- **Test pass/fail.** The suite is green or this skill shouldn't be running fixes on top of red. If `config.commands.test` is red on a clean `config.defaultBranch`, stop and report that — don't audit on top of a broken suite.
- **Raising the coverage *number* for its own sake.** Chasing a percentage produces assertion-free tests that exercise lines without proving behavior — the exact anti-pattern this skill exists to remove. Only add coverage where a **real untested behavior/branch** exists and the test would *catch a real regression*.
- **Performance of the code under test.** Slow *tests* are in scope; slow *production code* is not.
- **Generated/vendored fixtures.** Recorded fixture data is data, not test logic — don't flag its shape.

## Workflow

Use a todo list to track findings as you process them — the sweep spans many files.

### 1. Pre-flight: start clean and green

```bash
git status --short             # working tree must be clean
git checkout <config.defaultBranch>
git pull
<config.commands.test>         # suite must be green before auditing
```

- **Dirty tree** → a human is mid-work. Stop, stay silent (or one line if invoked interactively). Don't stash. (Exception: untracked files under `config.paths.skillsDir` are scaffolding — benign; stage specific paths only.)
- **Red suite on clean `config.defaultBranch`** → don't audit on top of breakage. Report the failing tests and stop. Do not open any test-fix PRs while the suite is red.

The `config.labels.testQuality` label this skill applies must exist. If a fresh clone or remote runner reports "label not found" on `gh pr edit`/`gh issue create`, create it once and continue:

```bash
gh label create <config.labels.testQuality> --repo <config.repo> \
  --description "Automated audit-tests findings (test-suite health)" --color BFD4F2
```

### 2. Sweep the categories (fast greps first, coverage last)

**Collect findings into a list — open nothing until the sweep is done.** This lets you de-dup across categories and pick the highest-value fixes within the cap.

Fast pass (cheap greps from the [language section](#language-specific-mechanics); each hit is a *candidate*, not yet a finding — read the surrounding test before believing it):

1. Redundant framework boilerplate (per `config.guidelines.testing`).
2. Skip/xfail/only rot.
3. Flaky patterns — sleeps; unfrozen current-time/`random` in result-asserting tests.
4. Weak assertions / broad error expectations; assertion-free test bodies. (Don't grep for truthiness guards — they over-match; catch truthiness-only tests by reading.)
5. Mocked collaborators — construct-then-verify against `config.guidelines.testing` (placeholder vs. real-behavior-mock).

Reading pass (judgment — don't force findings if nothing obvious surfaces):

6. Mocks that never assert; assertions on mock internals over behavior.
7. Test duplication that wants parametrize/table-driven cases; fixture smells.
8. Repo test-invariant drift — read each rule in `config.guidelines.testing` and check the suite against it.

Slow pass (run once, near the end):

9. Slow tests — the runner's slowest-tests report.
10. **Coverage gaps** — run `config.commands.coverage` (skip if `null`), then read its report: for modules that already have tests, find uncovered **branches** / exception arms that represent real untested behavior. (Don't chase whole untested modules — that's `audit-architecture`.)

### 3. De-duplicate — strict (this runs several times a day)

For each candidate finding, skip it if any of these is true:

```bash
# This skill's own open PRs/issues
gh pr list --repo <config.repo> --state open --json number,title,headRefName --limit 50
gh issue list --repo <config.repo> --state open --label <config.labels.testQuality> --json number,title --limit 100

# Don't collide with audit-architecture mid-fix on the same file
gh pr list --repo <config.repo> --state open --search "head:arch-" --json number,headRefName,files --limit 50

# Don't re-file what a human closed wontfix
gh issue list --repo <config.repo> --state closed --label <config.labels.testQuality> \
  --search "is:closed reason:not-planned" --json number,title --limit 50
```

Skip when:

- An open PR with an `audit-tests-` branch already addresses this file+category (it may be from a run an hour ago — **the most important dedup, because this skill runs often**).
- An open `arch-*` PR touches the same test/source file (let it land first; auditing a file mid-flight causes conflicts).
- An open `config.labels.testQuality` issue already describes it.
- A human closed the same finding `wontfix` — that's their standing answer; don't refile.

### 4. Route each surviving finding

- **One PR** if all: fix is < ~120 lines of diff, touches ≤ 4 files, behavior-preserving for the code under test (you're improving the *test*, not changing what production code does), and a reviewer would say "yes, obviously better." Prefer PRs — the mandate is *fix it*.
- **One issue** otherwise (test-strategy reshapes, fixture-scope redesigns, testability smells that need a source change, slow-test restructures).
- Unsure → **issue**.

**Umbrella issues** when one category yields many similar findings (e.g. 8 files with the same fixture-leak smell): one prioritized umbrella, not 8 thin issues. The umbrella lists every covered finding grouped by priority with explicit out-of-scope notes.

### 5. Open PRs (cap: `config.audits.testPrCap`, default 2 per run)

The cap is low **on purpose** — this runs several times a day; a handful of focused, obviously-correct test PRs per run is a sustainable trickle, a flood of them trains reviewers to rubber-stamp.

For each PR-routed finding, highest-value first:

```bash
SLUG="audit-tests-<category>-<descriptor>"   # e.g. audit-tests-asyncio-marker-cleanup
git checkout <config.defaultBranch> && git checkout -b "$SLUG"
```

Make the fix. Keep it laser-focused — **only** the test change you described. Do not "while I'm here" adjacent tests, do not reformat, do not touch source unless the finding is explicitly a source change you've decided is mechanical and safe (rare; default is to route source changes to an issue).

**Pre-flight before pushing.** If the `create-pr` skill is installed, delegate the pre-flight + push + PR-open to it (it runs every gate the repo declares and enforces the PR template). Otherwise run the gates inline — all of these must pass, **skipping any whose command is `null`**:

```bash
<config.commands.format>   # skip if null
<config.commands.lint>     # skip if null
<config.commands.test>
```

If any fails on something you didn't touch, the failure is unrelated → abandon this finding (`git checkout <config.defaultBranch> && git branch -D "$SLUG"`; nothing was pushed), note it in the report, move on. **No `--no-verify`.** A test-quality skill that ships a red PR has no credibility.

Then open the PR (or let `create-pr` do it):

```bash
git push -u origin "$SLUG"
gh pr create --repo <config.repo> --base <config.defaultBranch> \
  --title "test: <one-line description>" \
  --body "<template below>"
gh pr edit <NUM> --add-label <config.labels.testQuality> --add-label <config.labels.automated>
```

PR body:

```markdown
## Summary

`audit-tests` sweep flagged: **<category>** in `<test file>`.

<2–3 sentences: what the test smell is, what the fix is, why the test now
proves more / is less brittle, and why it's behavior-preserving for the code
under test.>

## Changes

- <bullet per file touched>

## Verification

- `<config.commands.test>` green; `<config.commands.format>` / `<config.commands.lint>` clean.
```

**Stop at `config.audits.testPrCap` PRs.** Overflow re-routes to issues for this run; the next run picks them up. Never auto-merge — green CI doesn't mean a test change is *right*; a human reviews every one.

### 6. File issues (cap: `config.audits.testIssueCap`, default 2 per run)

```bash
gh issue create --repo <config.repo> \
  --title "test-quality: <one-line problem>" \
  --label <config.labels.testQuality> --label <config.labels.automated> \
  --body "<template below>"
```

Issue body:

```markdown
## What

<One paragraph: the test smell, where it lives, why it weakens the suite.>

## Evidence

- `<tests>/test_foo.py:42–68` — <snippet or pattern>
- `<tests>/test_bar.py:103` — <duplicate location>

## Proposed unit of work

<3–6 concrete bullets: which tests to rewrite/parametrize, which fixture to
extract, which branch to cover, which assertion to strengthen. Describe it;
don't write the code.>

## Out of scope

<What this issue is not — keeps it tight for the picker-upper.>

---

_Filed by the `audit-tests` skill. If this isn't worth doing, close with
`wontfix` (not-planned) — the skill checks that and won't refile._
```

**Stop at `config.audits.testIssueCap` issues.** Defer the rest to the next run.

### 7. Systemic escalation (recurring patterns)

Before reporting, run the **pattern-promotion** check. If a finding this run is an instance of a
*specific, encodable* test-quality pattern this audit has already fixed or filed
`config.audits.promoteThreshold` times (default 3) within `config.audits.promoteLookbackDays` (default
90) — e.g. *"new tests keep mocking the DB session instead of using the `db` fixture"* — file **one**
human-gated issue proposing the pattern become a rule in `config.guidelines.testing` — or, if the
rule already exists and keeps being violated, a **mechanical guard** (a lint rule / CI check) instead
— rather than only fixing the instance again. Full mechanism, history queries, dedup marker, and template live in
[`../../references/pattern-promotion.md`](../../references/pattern-promotion.md); this audit's
`<audit-name>` is `tests` and its branch prefix is `audit-tests-`. The proposal is **in addition to**
the normal fix, does **not** count against the caps, and is capped at one per run. Never auto-edit the
guideline — propose; the maintainer decides. **Silent-on-clean exception:** a run that files a
promotion *does* report it (below) even if it opened no PRs/issues — a promotion is something to say.

### 8. Report — only if there's something to say

- **Zero findings** (the common case): **say nothing and open nothing.** No PR, no issue, no "looks good" note. When invoked by a scheduled agent, a silent run is success. (If invoked interactively, a single line — "Test suite looks healthy; nothing to fix." — is fine; under automation, stay quiet.) The one exception: if step 7 filed a **pattern-promotion** proposal, report that (a promotion is worth surfacing even on an otherwise-quiet run).
- **Findings actioned:** a short structured summary, only listing what changed:

```text
Test audit — YYYY-MM-DD

PRs opened:
- #NNN  audit-tests-asyncio-marker-cleanup — drop redundant async markers in 6 files
- #NNN  audit-tests-cov-cap-fallback — cover the cap-fallback branch in <module>

Issues filed:
- #NNN  test-quality: tests mock the DB layer instead of using the real test-DB fixture

Deferred (over cap, next run): <n> — <one-line each>
Pre-flight abandoned (unrelated failure): <branch> — <reason>
Systemic: proposed encoding <pattern> as a rule in config.guidelines.testing (or a mechanical guard if the rule already exists) — issue #NNN (seen <N>× in <days>d)
```

## Calibrating scope

A healthy suite produces **0 findings on most runs** — that's the steady state, and silence is the correct output. An occasional run surfaces 1–2 real test smells; fix them and move on. A run that surfaces >8 means test debt has accumulated (a feature shipped with thin tests, a big mock-heavy module landed) — note it in the report and let the maintainer decide whether to schedule a focused test-hardening pass.

**Threshold/cadence tuning.** Because it runs several times a day, the `config.audits.testPrCap` / `config.audits.testIssueCap` caps are deliberately tight. Don't raise them to "catch up" — the trickle is the point. If reviewers report even 2/run is too much, lower the caps in `.claude/maintainerd.json`, or reduce the schedule frequency. Tune the caps in the config (not in this file) so future runs pick them up.

## What not to do

- **Don't manufacture findings to look busy.** Silence is a valid — and common — outcome. A run with nothing to fix opens nothing. Padding the suite with assertion-free "coverage" tests is the exact debt this skill removes.
- **Don't chase the coverage number.** Add a test only where it would catch a real regression. A test that exercises a line without asserting on behavior is worse than no test (it gives false confidence and resists refactors).
- **Don't change production code to fix a test smell.** If the source is untestable, file an issue describing the testability problem; the fix belongs to `audit-architecture` or a human.
- **Don't audit on a red suite or a dirty tree.** Both mean "not now" — back off.
- **Don't re-open a fix that already has an open `audit-tests-` PR.** This is the failure mode unique to a high-frequency skill — strict dedup against your own recent PRs is non-negotiable.
- **Don't collide with `audit-architecture`.** If an `arch-*` PR touches the file, skip it this run.
- **Don't bundle findings.** One test smell per PR. "Misc test cleanup" is unreviewable.
- **Don't re-file a `wontfix`.** Check closed-not-planned `config.labels.testQuality` issues first.
- **Don't auto-merge or `--no-verify`.** Every PR waits for human review; pre-flight always runs.
- **Don't auto-edit `testing.md`.** When a test-quality pattern recurs past the threshold, *propose* the rule as an issue (step 7); the maintainer edits the guideline. One promotion per run, never re-propose one closed Not planned.

## When integrated with scheduling

Schedule this as its own slot (a few times a day is fine given the silent-on-clean + low-cap design), invoking it directly (`/audit-tests` or equivalent) — there is no autonomous-prompt variant. It is intentionally **separate** from both `daily-update` (which bundles its work into one PR; this skill opens discrete ones) and `audit-architecture` (which owns the source side). Running both audits is fine; they don't overlap and each dedups against its own label/branch prefix.

**Model tier:** "is this mock decorative? is this assertion actually weak?" is judgment — schedule on **`capable`**, or on a **`mid`** rung if the repo defines one (this runs several times a day, so the cost trade is real). See [`../../references/model-tiers.md`](../../references/model-tiers.md).

## Related skills

- `audit-architecture` — owns the **source** side (oversized modules, source DRY/typing/dead code, source invariants, and modules with **zero** tests). Anything about source, not tests, goes there.
- `create-pr` — used (if installed) for the PR pre-flight + open in step 5; enforces the repo's gates and PR template.
- `/code-review` (Claude Code built-in) — the on-demand reviewer for a specific diff; this skill is the scheduled, test-only sweep.
- `audit-design-docs` / `audit-product-docs` — the doc-side audits; same FIX-FIRST, capped, dedup-aware shape, different surface.
- `bootstrap` — generates the `.claude/maintainerd.json` and `config.guidelines.testing` this skill reads.
- [`pattern-promotion.md`](../../references/pattern-promotion.md) — the shared step-7 mechanism for proposing a recurring test-quality pattern become a rule in `config.guidelines.testing`.
