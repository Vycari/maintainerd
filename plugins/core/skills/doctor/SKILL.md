---
name: doctor
description: Validate a repo's Maintainerd setup and report what's wrong — the companion to `bootstrap`. Checks that `.claude/maintainerd.json` exists, parses, and conforms to the schema; that the configured paths, commands, and guidelines files resolve; that the GitHub labels the skills apply actually exist; that the daily-update roster only names installed skills; that the auto-dev state labels exist when the pipeline is enabled; that release config is coherent; and that the coverage ratchet holds — a floor is recorded, CI enforces it, the default branch's latest run is above it, and no commit has ever lowered it. In an umbrella repo whose config carries a `workspace` block, `--workspace` additionally validates that block and then runs the whole check once per cloned repo in the list, emitting one combined report. Read-only diagnosis by default, grouped PASS/WARN/FAIL with a concrete fix for each finding; offers to create missing labels and points at `/bootstrap` or the guidelines files for the rest. Use when the user asks to "run doctor", "check the maintainerd setup", "validate the config", "why isn't <skill> working", "diagnose the agent-skills config", or after onboarding a repo to confirm it's wired correctly.
---

# Diagnose a repo's Maintainerd setup

This skill is the companion to `bootstrap`: where `bootstrap` **creates** the config contract,
`doctor` **validates** it and everything it points at. It's what you run when a skill misbehaves
("audit-architecture says no config", "daily-update tried to run a skill that isn't installed",
"my audit PRs have no label") or right after onboarding a repo to confirm it's wired correctly.

**It is read-only by default.** It diagnoses and reports; it does not rewrite your config or
guidelines. The one mutation it will *offer* (with confirmation) is creating missing GitHub labels,
since that's the same safe action `bootstrap` offers. Everything else it routes: "run `/bootstrap`
to regenerate X", "fill in `invariants.md`", "fix this key by hand".

## Inputs

- `/doctor` — full read-only check, print the report.
- `/doctor --fix` — additionally offer to create any missing GitHub labels (still asks first).
- `/doctor --run` — additionally *execute* `config.commands.*` to confirm they work (slower, has
  side effects: runs the test/build). Default is the static check (the command's script is defined),
  not running it.
- `/doctor --workspace` — only in a repo whose config carries a `workspace` block: validate that
  block (check 12), then run every per-repo check once per **cloned** repo in the list and print one
  combined report. Composes with the other two — `--workspace --fix` still confirms each label creation, per
  repo; `--workspace --run` executes every repo's commands, which is slow enough to be worth saying
  out loud before you start.

## The check

Read `.claude/maintainerd.json` and the schema (`../../references/config-schema.md`) — the schema is
the source of truth for what's valid. Then run every check below, collecting findings as
**PASS / WARN / FAIL**:

- **FAIL** — a skill *will* break: no config, invalid JSON, a missing required key, a label a skill
  applies that doesn't exist, a daily-update roster entry that isn't installed.
- **WARN** — degraded but not broken: a path that doesn't resolve, a command whose script is
  undefined, a stubbed `invariants.md`, an unverifiable schedule, an unknown (likely typo'd) key.
- **PASS** — fine; list briefly, don't pad.

### 1. Config presence and validity
- `.claude/maintainerd.json` exists. If not → **FAIL**: "Run `/bootstrap`." Stop here; nothing else
  can be checked.
- It parses as JSON (`jq . .claude/maintainerd.json`). If not → **FAIL** with the parse error and the
  offending line.

### 2. Schema conformance
- Required top-level keys present: `repo`, `defaultBranch`, `language`, `commands`, `paths`,
  `guidelines`. Missing → **FAIL**.
- `language` is `python` | `typescript` (else **WARN**: audits fall back to language-generic checks).
- Types match the schema (arrays are arrays, caps are numbers, `commands.*` are strings or `null`).
- **Unknown keys** not in the schema → **WARN** (usually a typo, e.g. `commands.tests` for `test`;
  the skill reading it will silently miss the value).

### 3. Paths resolve

**Umbrella exemption:** if the config carries a `workspace` block *and* its top-level `language` is
`"none"`, this check and check 4 are `n/a (umbrella repo)` — a workspace repo holds config and docs,
not a source tree, and `paths.source`/`paths.tests` are legitimately `null` there. Report them as
n/a; never as PASS (nothing was verified) and never as FAIL. Everything else is checked as usual.

For each `config.paths.*`: the directory/file exists in the repo. `designDocs`/`productDocs` are
arrays — check each entry. A configured `prTemplate` that doesn't exist → **WARN**. `source`/`tests`
not existing → **FAIL** (the audits sweep nothing). `skillsDir` missing is fine (it may not exist yet).

### 4. Commands
For each non-`null` `config.commands.*`: confirm it's plausibly runnable.
- **TypeScript**: an `npm run <x>` command → `<x>` exists in `package.json` `scripts`. Missing → **FAIL**.
- **Python**: the tool (`ruff`, `pytest`, …) is on `PATH` or declared in `pyproject.toml` dev deps.
- With `--run`: actually execute each and report pass/fail (this is the real proof, but slow).

### 5. Guidelines health
- Each file named in `config.guidelines.*` exists. Missing → **WARN** (the skill that reads it falls
  back to generic checks).
- `invariants.md` is more than a stub — flag if it's empty or still all `TODO`/template
  (**WARN**: "audit-architecture is only as good as the invariants listed here").
- `guidelines.release` present iff `config.release` is non-null (a versioned-release repo should have
  release gates documented; a `release: null` repo shouldn't need the file).

### 6. GitHub labels exist
```bash
# --paginate, NOT `gh label list`: that caps at 30 by default, and a truncated
# list makes existing labels report as missing (a FAIL the maintainer can't reproduce).
gh api "repos/<config.repo>/labels" --paginate --jq '.[].name'
```
Every label in `config.labels.*` must exist. Missing → **FAIL** (the skill's `gh ... --label` call
errors at runtime). With `--fix`, offer to create the missing ones (same `gh label create` as
`bootstrap`). If `config.autoDev.enabled`, the `config.autoDev.stateLabels.*` and `config.autoDev.prLabel`
(default `auto:pr`) must also exist. If `config.depsFlow.enabled`, so must
`config.depsFlow.blockedLabel` (default `deps:blocked`).

### 7. daily-update roster
Every skill in `config.dailyUpdate.subSkills` must be installed/available (a Maintainerd skill name,
or a repo-local skill that exists). A roster entry that resolves to nothing → **FAIL** ("daily-update
will try to invoke a missing skill"). Cross-check against the plugins actually installed.

### 8. auto-dev coherence (only if `config.autoDev.enabled`)
- All six `stateLabels.*` exist on GitHub (covered in check 6).
- `marker` is a non-empty HTML comment; `branchPrefix` is set; `excludedLabels` is an array.
- `prLabel` (default `auto:pr` if absent) exists on GitHub — **FAIL** with the `gh label create` fix
  (same severity as check 6, which covers it). The pipeline stamps it on every PR it opens so the
  maintainer can configure external review tooling to skip automated PRs; while it's missing, every
  automated PR is unlabeled and that tooling reviews all of them.
- `fallbackReviewMinutes` (default `60` if absent), when present, is a positive number → else **WARN**.
- `maxPrsInFlight` (default `1` if absent), when present, is an integer ≥ 1 → else **WARN**.
- `orphanReclaimMinutes` (default `90` if absent), when present, is a positive number → else **WARN**.
- **The CodeRabbit ignore rule is wired up** — the consuming half of `prLabel`. Check this **only**
  when `config.review.bots` includes `coderabbitai[bot]` — the key is optional and its default
  includes it, so treat absent as included — and a `.coderabbit.yaml` (or `.coderabbit.yml`) exists
  in the repo root. If **both** spellings exist, report **WARN** naming both paths and check neither
  — which one CodeRabbit honors isn't knowable from here, so a verdict read off the wrong file is
  worse than no verdict. Otherwise read `reviews.auto_review.labels`; if it does not
  contain a negative match for `prLabel` (`!auto:pr` by default) → **WARN**: "automated PRs carry
  `<prLabel>`, but CodeRabbit isn't configured to skip them — it reviews every pipeline PR alongside
  auto-dev's own review." The fix is the `labels: ["!<prLabel>"]` key; with `--fix`, propose the edit
  and apply it only on confirmation — never merge into an existing `labels` value unprompted (the
  matchers combine, so a blind append can silence review on PRs the maintainer wants reviewed).

  **If no `.coderabbit.yaml` exists, report nothing** — not even an INFO. CodeRabbit is equally
  configurable from its web dashboard, so an absent file is not evidence of a missing rule, and a
  finding that can't distinguish "misconfigured" from "configured elsewhere" is noise that trains
  the maintainer to ignore the report. Other bots in `review.bots` have their own ignore
  mechanisms and are out of scope here.
- If `autoDev.enabled` is `false`, skip — note it as a PASS ("auto-dev disabled").

### 9. deps-flow coherence

First, the disabled path — **always checked**, so it always reports:

- `depsFlow` absent, or `enabled` not `true` → PASS ("automated dependency merging disabled"). Say so
  explicitly rather than silently skipping: a maintainer who thinks it's on should see that it isn't.
  Then skip the rest of this section.

**When `config.depsFlow.enabled` is `true`**, run the checks below. The `dependabot` skill merges
PRs, so a misconfiguration here has real blast radius — check it harder than the rest.

- `blockedLabel` (default `deps:blocked`) exists on GitHub → else **FAIL**: the skill can't mark a
  diagnosed PR, so every run would re-diagnose the same failure. Fix: `/doctor --fix`.
- `labels.dependencies` and `labels.automated` exist (covered by check 6) — the skill labels its
  broken-update issues with both.
- `autoMergeSemver` is an array whose entries are all in `patch|minor|major`. An unknown entry →
  **WARN** (it will never match, silently narrowing the policy). Containing `"major"` → **WARN**,
  not a failure: "majors auto-merge here; green CI doesn't prove a breaking API change is safe."
- `mergeMethod` is one of `squash|merge|rebase` **and** is enabled on the repo:

  ```bash
  gh repo view <config.repo> --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed
  ```

  A method the repo forbids → **FAIL** (every merge attempt errors).
- `botLogins` is a non-empty array of `*[bot]`-shaped logins → else **WARN** (a typo'd login means
  the skill silently sees an empty queue forever).
- `maxMergesPerRun` ≥ 1, `rebaseNudgeMinutes` > 0, `drainPollMinutes` > 0, `drainMaxMinutes` > 0 →
  else **WARN**.
- Branch protection on `config.defaultBranch` requires status checks → advisory **WARN** if not:
  without required checks the skill's own gate is the only thing standing between a red build and
  the default branch. It still checks every check itself, so this is a defense-in-depth note, not a
  failure.

### 10. release coherence
- `config.release` is `null` → PASS ("continuous-deploy repo, no versioned releases").
- Non-null → `notesFile` (if set) exists; `versionCommand` references a real mechanism (an
  `npm version`/script that exists, a tool on PATH); `versionPushesTag` is a boolean. Gaps → **WARN**.

### 11. Schedules (best-effort, advisory)
Scheduled runs live in Claude Code's scheduling config, not the repo, so this can't always be
verified from here. Don't fail on it. Advise: the audits and `daily-update` are designed to run on a
schedule — list which skills the repo has installed that *want* scheduling, and suggest the user
confirm they're wired via the `schedule` skill. Mark **WARN** only if you can positively tell an
expected schedule is absent.

### 12. Workspace block and fan-out (`--workspace` only)

Skipped entirely without the flag — with one exception: when the config **does** carry a `workspace`
block and the flag was **not** passed, close the report with one line noting it
("this repo carries a workspace block listing <n> repos; `/doctor --workspace` checks them too"), so
a workspace's repos are never silently unchecked because nobody knew the flag existed.

With `--workspace` and **no** `workspace` block: **stop**. Print
"this repo isn't a workspace — no `workspace` block in `.claude/maintainerd.json`" and the pointer to
the schema. Do not fall back to a plain run, and never infer a repo list from sibling directories.

The full contract for the block is in [`../../references/config-schema.md`](../../references/config-schema.md).
Validate it first — a fan-out driven by a broken list produces confident nonsense:

- **`contractVersion`** is an integer this version of maintainerd knows (currently `1`). Absent →
  **WARN**, read as `1`, and say so. A version *above* what's known → **FAIL**: "this config was
  written for a newer contract; upgrade maintainerd rather than reading it as v1."
- **`org`** is a non-empty string → else **WARN** (nothing in maintainerd needs it, but the tools
  reading the list downstream do).
- **`repos`** is a non-empty array → else **FAIL**.
- **`name` is unique across the list** → a duplicate is a **FAIL**, not a WARN: two entries claiming
  the same checkout directory means one of them is silently never visited.
- **`name` is a single path segment** — no `/`, no `.` or `..` → else **FAIL**. It becomes a
  directory path under `root`.
- **`repo` matches `owner/name`** and resolves on GitHub:

  ```bash
  gh repo view <entry.repo> --json nameWithOwner,isArchived --jq '.nameWithOwner + (if .isArchived then " (archived)" else "" end)'
  ```

  Doesn't resolve → **FAIL** (every `gh --repo` against it will error). Resolves but is **archived** →
  **WARN**: a fan-out will keep visiting a repo nobody can merge to. If `gh` is unauthenticated,
  report "couldn't verify" for the whole batch — not a FAIL per repo, which would read as 6 broken
  slugs when the real finding is one missing token.
- **`clone`**, where present, is a boolean → else **WARN** (a string `"false"` is truthy, so the repo
  would be cloned and swept exactly against the maintainer's intent).
- **`profile`**, where set, points at a file that exists and parses as JSON → else **FAIL** (the
  `language` values it is the only validator for go unchecked). Then every entry's `language` is a
  key in the profile's `languages` table → else **FAIL**, naming the unknown value and the keys that
  do exist. A repo whose language has no profile entry is an error, not a silent skip: it is exactly
  the repo that will be missed when the profile is applied.
- **`profile` absent** → report it once, plainly: "no profile configured — `repos[].language` values
  are unvalidated." Don't imply they were checked.
- **Checkouts** — for each `clone: true` entry, `<root>/<name>` exists and is a git working tree
  (`git -C <path> rev-parse --git-dir`) → else **FAIL** for that repo ("not checked out; fan-out
  skipped it"). For a `clone: false` entry, a checkout that happens to exist is **not** a finding —
  `clone` records the default for a fresh workspace, not a prohibition.

### The fan-out

Then, for each entry with `clone` not `false` whose checkout resolved, run **checks 1–11 and 13 in
that repo** exactly as a plain `/doctor` would: `cd` into `<root>/<name>` and read *that repo's*
`.claude/maintainerd.json`. Never carry a value across the boundary — the umbrella repo's labels,
branch and roster describe the umbrella repo and nothing else.

- A listed repo with **no** `.claude/maintainerd.json` is one finding, not a dozen: **FAIL**, "not
  bootstrapped — run `/bootstrap` there", and move to the next repo.
- **One repo's failure never aborts the run.** An unhandled error against a repo is captured as that
  repo's finding; the remaining repos still get checked. A fan-out that dies on repo two has told you
  less than no fan-out at all.
- **No recursion.** A listed repo carrying its own `workspace` block is checked as an ordinary repo.
- The umbrella repo itself is checked only if the list names it.

### 13. Coverage ratchet

`coverage.floor` in `.claude/maintainerd.json` is the line coverage this repo has promised not to
drop below (the contract is in [`../../references/config-schema.md`](../../references/config-schema.md)).
This check answers three questions: is there a floor, does CI enforce it, and is the default branch
currently above it — plus a fourth the other three can't see, whether the floor has ever been
*lowered*.

**When it runs.** `config.commands.coverage` is `null` → PASS ("exempt from the coverage ratchet"),
skip the rest. That is a complete exemption, not a floor of zero, and it's the right answer for a
config repo, a static site or a docs repo. Say it out loud rather than skipping silently, for the
same reason check 9 does: a maintainer who thinks the gate is on should see that it isn't. Where a
repo profile is available and its language block says `coverage: null`, that exempts the repo too.

**a. The floor exists.** `config.coverage.floor` present → else **WARN**, as **one** finding:

> coverage ratchet not yet adopted — no `coverage.floor` in `.claude/maintainerd.json`.
> Fix: `/bootstrap --adopt` (measures `origin/<defaultBranch>` and records the floor)

That is the whole finding. Don't also report the missing CI step, the missing artifact and the
un-checkable history — they are all the same fact, and a repo that hasn't adopted the ratchet yet is
not violating it. **Stop this check there.**

Otherwise: `floor` is a whole number in 0–100 → else **FAIL** (`coverage-check.sh` refuses to run
against it, so every build fails). `coverage.floorCommit` present and resolvable
(`git cat-file -e <sha>^{commit}`) → else **WARN**: the number is still enforced, but nothing records
what it was measured against, so nobody can reproduce it.

**b. CI enforces it.** The scaffolded gate is two things, and both must be present:

```bash
grep -rl "coverage-check" .github/workflows/          # candidate workflows — then READ them
ls .claude/maintainerd/coverage-check.sh .claude/maintainerd/coverage-adapt.sh
```

**The grep only narrows the search; it never settles the question.** `coverage-check` appearing
somewhere in a workflow file is not evidence that anything runs it — the match can be in a `#`
comment, in a job gated `if: false`, in a workflow triggered only by `workflow_dispatch`, or in a
step whose own `if:` never holds on the default branch. Read the matching files and confirm all
four before calling it enforced:

1. the match is a **`run:` step**, not a comment or a string in some other key;
2. its **job** isn't disabled — no `if: false`, and the job is reachable from the workflow's
   `on:` triggers for pushes to the default branch;
3. the **step** carries no `if:` that excludes those pushes, and no `continue-on-error: true`,
   which turns the gate into a notification;
4. the **job that contains the step** is a required check — a gate nobody must pass is advice.
   Required checks are named per *job*, not per workflow, so "this workflow has a required job in
   it" proves nothing: a workflow whose `build` job is required and whose `coverage` job is not
   will merge a red coverage job all day. Match the containing job's check-run name against the
   required contexts:

   ```bash
   gh api "repos/<config.repo>/branches/<config.defaultBranch>/protection/required_status_checks" \
     --jq '.contexts[]'
   # ...and, where the repo uses rulesets instead:
   gh api "repos/<config.repo>/rulesets?includes_parents=true"
   ```

   The context is the job's `name:` if it has one, else its key in `jobs:`; a matrix job appears
   once per combination as `<name> (<values>)`, so requiring only some combinations leaves the rest
   advisory. A job that reaches the gate through a reusable workflow (`uses:`) reports under the
   *calling* job's name — read that, not the callee's.

   Protection is readable only with admin on many repos, and rulesets can grant the requirement
   from an org-level parent. When either read fails, say **couldn't verify** for this criterion and
   report the other three; don't assume enforcement, and don't call it a failure either.

Nothing that actually runs it → **FAIL**: "`coverage.floor` is recorded but nothing enforces it —
the ratchet is decorative." Report *which* of the four failed, because "the step is there but the
job is `if: false`" and "there is no step" have different fixes. A referenced-but-missing vendored
script is the same severity, since the step errors on every run. Fix for the missing pieces:
`/bootstrap --adopt`, which writes the scripts and prints the workflow snippet.

**c. The default branch is above its own floor.** Read the `coverage` artifact from the **latest**
`ci` run on the default branch:

```bash
gh api "repos/<config.repo>/actions/runs?branch=<config.defaultBranch>&per_page=100" \
  --jq '[.workflow_runs[] | select(.name == "ci" or (.path | endswith("/ci.yml")))]
        | sort_by([.run_number, .run_attempt]) | last
        | {id, run_number, run_attempt, status, conclusion, head_sha, html_url}'
gh run download <id> --repo <config.repo> --name coverage --dir "$tmp"
jq -r '.percent' "$tmp/coverage-summary.json"
```

**Latest means latest, and a rerun of the same commit is newer than the original.** Sort by
`run_number` and then `run_attempt`, and take the last — never `--status success`, never the newest
green. A stale green run is exactly the run that hides the regression this check exists to catch, so
falling back to one turns the check into a rubber stamp.

- `percent` ≥ `floor` → **PASS**. If `percent` floored to a whole number is **greater** than
  `coverage.floor`, append the suggestion: "measured <n>%, floor <m>% — consider raising the floor to
  <n> in `.claude/maintainerd.json`". **Suggest it; never apply it.** doctor is report-only, and a
  ratchet that tightens itself turns the next unrelated red build into a mystery.
- `percent` < `floor` → **FAIL**: "the default branch is below its own floor" — naming both numbers
  and the run URL.
- The latest run **failed or was cancelled** → **FAIL** in its own words: "the default branch's
  latest `ci` run is red — coverage is unknown, and the run before it doesn't answer for this
  commit." Report the run URL. Don't reach back for an older run to salvage a number.
- The latest run has **no `coverage` artifact** → **FAIL**: "CI is not producing the coverage
  summary" — the upload step is missing, or the coverage command failed before writing one.
- The latest run is still `in_progress`/`queued` → **couldn't verify**, not a FAIL and not a PASS.
  It will have an answer in a few minutes.
- The artifact has **expired** (`gh run download` reports it gone on an old run) → **couldn't
  verify**, naming the run's age. Expiry is a retention setting, not a coverage problem.
- No `ci` run on the default branch at all → **WARN**: nothing has enforced the floor yet.

**d. The floor has never been lowered.** The ratchet direction can't be seen at `HEAD` — a lowered
floor looks exactly like a floor. Check it against history:

```bash
git fetch origin "<config.defaultBranch>"
git log --reverse --format='%H' "origin/<config.defaultBranch>" -- .claude/maintainerd.json
# for each commit, in order:
git show "<sha>:.claude/maintainerd.json" | jq -r '.coverage.floor // empty'
```

Walk the values forward and keep the highest seen. If any earlier commit's floor is **higher** than
the floor at `HEAD` → **FAIL**, naming the commit that lowered it and both numbers:

> `coverage.floor` was lowered from 78 to 71 in a1b2c3d ("chore: relax coverage", 2026-08-14).
> The floor is a ratchet. Fix: restore it to 78 and add tests, or — if the drop was deliberate and
> reviewed — say so in the issue this drift report opens.

A commit where the floor first *appears* is adoption, not a lowering. A commit that **removes** the
block is a lowering to nothing: **FAIL**, same finding. If the history isn't present (a shallow
clone — `git rev-parse --is-shallow-repository` is `true`), report **couldn't verify** and name
`--unshallow`; don't read one commit's worth of history as a clean ratchet.

## Report

```text
maintainerd doctor — <repo>   (<config.language>, default branch <config.defaultBranch>)

FAIL (<n>) — skills will break until fixed:
  - labels: `security` missing on GitHub — audit-security's PRs will error.   Fix: /doctor --fix  (or gh label create security)
  - daily-update roster lists `triage-issues`, which isn't installed.          Fix: install it, or drop it from config.dailyUpdate.subSkills

WARN (<n>) — degraded:
  - guidelines/invariants.md is still the bootstrap stub.                       Fix: fill in the repo's load-bearing invariants
  - paths.prTemplate (.github/PULL_REQUEST_TEMPLATE.md) doesn't exist.          Fix: create it, or set the key to null

PASS (<n>): config parses · schema OK · source/tests resolve · commands defined · 4/5 labels present · release: null (continuous-deploy)

Summary: <n> FAIL, <n> WARN — fix the FAILs before relying on the affected skills.
```

If everything passes: `maintainerd doctor — all green. <n> checks passed.` Don't pad a clean run.

### The combined workspace report

With `--workspace`, print the workspace findings first, then a **roll-up line per repo**, then the
per-repo detail for every repo that isn't clean. A clean repo gets its roll-up line and nothing more —
the point of the combined report is that a maintainer can read the first ten lines and know where to
look.

```text
maintainerd doctor --workspace — my-org   (7 repos: 6 cloned, 1 tracked)

Workspace (contract v1):
  FAIL  repos[3].language "typescript-service" isn't in profiles/repo-profile.json
        (known: python-service, typescript-web, shell, none)
  FAIL  app is listed with clone: true but <root>/app isn't a git working tree — not checked
  WARN  site resolves but is archived — fan-out will keep visiting a repo nobody can merge to

Per repo:
  app       — not checked out (see above)
  worker    ✅ all green (11 checks)
  site      ⚠️  1 WARN     invariants.md is still the bootstrap stub
  infra     ❌ 2 FAIL      labels: `security`, `automated` missing on GitHub
  docs-hub  ❌ 1 FAIL      no .claude/maintainerd.json — run /bootstrap there
  toolkit   — skipped (clone: false)

infra — 2 FAIL:
  - labels: `security` missing on GitHub — audit-security's PRs will error.  Fix: /doctor --fix (in infra)
  - labels: `automated` missing on GitHub — every skill that labels unattended work will error.

site — 1 WARN:
  - guidelines/invariants.md is still the bootstrap stub.  Fix: fill in the repo's invariants

Summary: 6 repos checked, 2 clean · 3 FAIL, 1 WARN across the workspace, plus 2 workspace-level FAIL.
```

**A repo that couldn't be checked is never counted as clean.** "6 repos checked" counts the ones the
fan-out actually reached; the unreachable ones are named on their own line. The failure this guards
against is a workspace that reports green because four of its repos were quietly invisible.

Fixes name the repo they belong to, since the maintainer will run them somewhere other than where
they're reading the report.

## What not to do

- **Don't rewrite the config or guidelines.** doctor diagnoses; `bootstrap` (or the user) fixes.
  The only mutations it performs are creating missing labels and adding the CodeRabbit ignore rule,
  both only with `--fix` + confirmation.
- **Don't merge into an existing `.coderabbit.yaml` unprompted.** Show the proposed change and let
  the user apply it. That file isn't maintainerd's, and its label matchers combine — a blind append
  can silence review on PRs the maintainer wants reviewed.
- **Don't run `config.commands.*` without `--run`.** They have side effects (and can be slow); the
  default check is static.
- **Don't fail on things it can't verify** (schedules) — mark advisory, not FAIL.
- **Don't report PASS for a check it skipped** — if a tool needed to verify something is missing, say
  "couldn't verify", not "OK".
- **Don't raise `coverage.floor`, and don't fall back to an older CI run to find a green one.**
  Raising the floor is a suggestion for the maintainer; reading a stale green run is how a coverage
  regression reports as clean.
- **Don't create labels silently** — always confirm, like `bootstrap`.
- **Don't infer a workspace.** `--workspace` runs off the `workspace` block and nothing else — not
  sibling directories, not `gh repo list <org>`. An inferred list is a list nobody reviewed.
- **Don't let a workspace run report green with repos it never reached.** An unreachable repo is a
  finding of its own; it is never folded into the passing count.
- **Don't read one repo's config while checking another.** Each repo's findings come from its own
  `.claude/maintainerd.json`, or it is reported as not bootstrapped.
