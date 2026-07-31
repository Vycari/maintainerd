---
name: bootstrap
description: Generate the maintainerd config contract for a repo — write `.claude/maintainerd.json` and scaffold `.claude/guidelines/{coding,testing,invariants}.md` so the repo-ops, audits, research, and auto-dev skills can run here. Inspects the repo (language, GitHub slug, default branch, source/test dirs, lint/format/build/test commands), confirms anything ambiguous, and seeds starter guidelines from existing CLAUDE.md/AGENTS.md. Use when the user asks to "bootstrap this repo", "set up maintainerd", "create the maintainerd config", "configure the maintainer skills", "onboard this repo to maintainerd", or when any other maintainerd skill reports the config is missing. Idempotent — re-running re-confirms and only rewrites changed keys; never clobbers hand-edited guideline prose.
---

# Bootstrap a repo for the Maintainerd toolkit

This skill writes the **config contract** that every other Maintainerd skill reads. After it
runs, the repo has:

- `.claude/maintainerd.json` — structured config (schema in
  [`../../reference/config-schema.md`](../../reference/config-schema.md)).
- `.claude/guidelines/coding.md`, `testing.md`, `invariants.md` — free-form rule files the audits
  and code-review read.

The goal is a config that's *correct on the first read* — detect everything you safely can, ask
the user only about what's genuinely ambiguous, and be honest in the final report about what still
needs human judgment (especially `invariants.md`).

Read the schema reference first: [`../../reference/config-schema.md`](../../reference/config-schema.md).
Every key you write must match it.

## Workflow

### 1. Detect whether this is a re-run

```bash
cat .claude/maintainerd.json 2>/dev/null
```

- **Exists** → this is an update. Read it, keep every value the user has set, and only re-confirm
  values that look stale or that the user asks to change. **Never** overwrite `.claude/guidelines/*.md`
  whose body is more than the scaffold (see step 6). Report what changed.
- **Missing** → fresh bootstrap. Continue.

### 2. Detect identity and language

Run these and read the results — don't assume:

```bash
# repo slug — gh first; if origin isn't a GitHub remote (e.g. a local clone), parse the URL
gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
# default branch — origin/HEAD, else the remote's advertised default
git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'
ls pyproject.toml package.json go.mod Cargo.toml 2>/dev/null
```

**Confirm the repo slug and default branch — don't trust detection blindly.** Two traps: (1) if
`origin` points at a local path or a non-GitHub host, `gh repo view` yields nothing — fall back to the
URL parse, and if that's also empty, **ask the user**. (2) `origin/HEAD` can be stale or, in a clone
made off a feature branch, point at that branch instead of `main`/`master` — so if the detected
default isn't `main`/`master`, or the current branch isn't it, **confirm with the user** rather than
writing a feature branch into the config.

- `pyproject.toml` present, no `package.json` → `language: "python"`.
- `package.json` present, no `pyproject.toml` → `language: "typescript"`.
- Both, or neither → **ask** the user which language the skills should target (this drives the
  audit/test detection rules). The toolkit currently ships Python and TypeScript rule sets; if the
  repo is another language, tell the user the audits will fall back to language-generic checks only.

### 3. Detect commands

Read the project manifest and pull the real commands rather than guessing:

- **Python** (`pyproject.toml`): look for ruff (`format` → `… ruff format --check`, `lint` →
  `… ruff check`), the test runner (`pytest` → `… pytest`). Honor the project's runner prefix
  (`uv run`, `poetry run`, `hatch run`, or bare) — check for `uv.lock`/`poetry.lock`. `build` is
  almost always `null`. `typecheck` → mypy/pyright if configured, else `null`.
- **TypeScript** (`package.json` `scripts`): map `format`/`format-check`, `lint`, `build`,
  `test`, `typecheck`/`typecheck:test` to whatever scripts exist. Use the exact `npm run <script>`
  names present; don't invent scripts.
- Show the user the command block you inferred and let them correct it. A wrong test command
  silently breaks create-pr and auto-dev, so confirm this one explicitly.

### 4. Detect paths

```bash
ls -d src/*/ src/ tests/ test/ planning/ docs/ 2>/dev/null
ls README.md AGENTS.md CLAUDE.md .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md 2>/dev/null
```

Infer:
- `source` — the source root. For Python, the single package dir under `src/` (e.g. `src/pepper/`);
  for TS, usually `src/`.
- `tests` — `tests/` or `test/` (Python convention vs TS convention — detect which exists).
- `designDocs` / `productDocs` — `planning/` is usually design; `docs/`, `README.md`, `AGENTS.md`,
  `CLAUDE.md` are usually product/contributor docs. Present your split and let the user adjust.
- `changelogDir`, `researchRadarDir` — default under `planning/` if it exists, else propose a
  location.
- `prTemplate` — whichever template path exists. If neither exists, the value is decided by the
  step 5 ask: the path of the template you'll scaffold in step 7 if the user wants one, else
  explicit `null`. **Never write a path to a file that doesn't exist** — create-pr would try to
  enforce a template it can't read.
- `skillsDir` — where this repo keeps local skill scaffolding (`.claude/skills/` or `.agents/skills/`).

### 5. Confirm the ambiguous bits, then assemble the JSON

Use `AskUserQuestion` for anything you couldn't determine confidently — typically: which plugins
they installed (so the `dailyUpdate.subSkills` roster lists only real skills), whether auto-dev is
`enabled`, label names if they differ from the defaults, and the research-radar `userAgent` email.

If step 4 found no PR template, include the offer in this ask: **create a minimal template**
(step 7 scaffolds it; `paths.prTemplate` gets its path) or **skip it** (`paths.prTemplate: null` —
create-pr then uses its built-in Summary / Changes / Checklist fallback). Recommend creating one:
the repo-ops and auto-dev skills write better PR bodies against a template than against the
fallback.

If `autoDev.enabled` is `true` **and** `review.bots` includes `coderabbitai[bot]` (the key is
optional and its default includes it, so treat absent as included), also ask whether
CodeRabbit should **skip the pipeline's own PRs** (step 9 writes the config). Recommend yes: auto-dev
reviews its own PRs and the maintainer still reviews before merge, so a third review is noise and
burns CodeRabbit's rate limit that human-authored PRs need. Say plainly that this only changes
CodeRabbit's behavior — it doesn't reduce what auto-dev checks.

Also determine the **release** model. If the repo ships versioned releases, detect the version-bump
mechanism (`npm version` + a `postversion` push hook, `hatch version`, `bump2version`, a manual
tag…) and the notes file, and write the `release` section. If it ships continuously (deploys from
the default branch, no tags/versioned artifact — e.g. a web service), write `"release": null`. When
in doubt, ask.

Defaults to apply without asking (state them in the report):
- `labels`: `architecture` / `test-quality` / `security` / `dependencies` / `automated`.
- `audits`: caps `3 / 5 / 2 / 2 / 3 / 5 / 3 / 5`; pattern promotion `promoteThreshold` 3, `promoteLookbackDays` 90.
- `models` *(optional)*: write the tier scaffold with every tier set to `"inherit"` (no behavior change until the maintainer binds `fast`/`capable` to real model ids — point them at [`../../reference/model-tiers.md`](../../reference/model-tiers.md)). Omitting the block entirely is equally valid.
- `autoDev` label names: the `auto:*` set from the schema.
- `autoDev.excludedLabels`: `["epic", "question", "wontfix", "duplicate", "invalid"]`.
- `autoDev.prLabel`: `auto:pr` (stamped on every automated PR); `autoDev.fallbackReviewMinutes`: `60`.
- `autoDev.maxPrsInFlight`: `1` (single-PR pipeline; raise it to let the queue drain into several open PRs); `autoDev.orphanReclaimMinutes`: `90`.
- `depsFlow`: **`enabled: false`**, plus the rest of the block at its schema defaults
  (`botLogins: ["dependabot[bot]"]`, `autoMergeSemver: ["patch","minor"]`, `mergeMethod: "squash"`,
  `maxMergesPerRun: 5`, `rebaseNudgeMinutes: 30`, `blockedLabel: "deps:blocked"`).

**The one thing to ask about rather than default:** the `deps-flow` plugin's `dependabot` skill is
the only maintainerd skill that **merges PRs**. If the repo has the plugin installed (or the user
asks for Dependabot automation), ask explicitly whether a bot may merge dependency PRs here, and
whether major bumps should be included (default: no — patch/minor only). **Write `enabled: false`
unless they say yes in this session.** Never flip it to `true` as part of a re-run's "keep the
config current" pass.

Write `.claude/maintainerd.json` with the full schema. Every command the repo doesn't have must be
explicit `null`, not omitted. Validate it parses:

```bash
jq . .claude/maintainerd.json >/dev/null && echo "config valid"
```

### 6. Scaffold the guidelines files

Create `.claude/guidelines/` and write the three files **only if they don't already exist** (on a
re-run, leave populated ones untouched). Seed each from what the repo already documents — read
`CLAUDE.md` / `AGENTS.md` / any `CONTRIBUTING.md` and lift the relevant rules.

- `coding.md` — coding standards (error handling, logging convention, typing expectations, banned
  patterns like `print`/`console`). Seed from the repo's existing guidance; mark gaps with `TODO`.
- `testing.md` — test conventions (DB/fixture pattern, what may/may not be mocked, isolation,
  assertion expectations). Seed from existing test docs; `TODO` the rest.
- `invariants.md` — the load-bearing, repo-specific invariants the audit-architecture enforces.
  **This is the file that most needs a human.** Seed it with a short template and any invariants you
  can extract from `CLAUDE.md`/`AGENTS.md`, but clearly `TODO`-mark it: the audit is only as good as
  the rules listed here.
- `release.md` *(only for repos that cut versioned releases)* — release-specific gates and caveats
  the `release` skill runs last: any runtime/smoke test the unit suite can't cover, dependency
  caveats, release-name formatting a registry enforces, notes-rendering quirks. Skip this file for
  continuous-deploy repos (`release: null`).

Each scaffolded file should start with a one-line header explaining what reads it and that it's
safe to edit freely.

### 7. Create the PR template (if agreed)

If the user opted in during step 5, write the minimal template at the path you put in
`paths.prTemplate` (conventionally `.github/PULL_REQUEST_TEMPLATE.md`):

```markdown
## Summary

<!-- What this PR does and why. Link the issue: Fixes #<number>. -->

## Changes

-

## Test plan

<!-- How the change was verified. -->

## Checklist

- [ ] Tests pass locally
- [ ] Documentation updated (or N/A with a reason)
```

If they declined, `paths.prTemplate` is `null` and there's nothing to create — don't force it,
some repos don't use templates.

**Re-run case:** if an existing config's `paths.prTemplate` points at a file that doesn't exist
(deleted, or a stale bootstrap wrote a bad path), make the same offer: create the file there, or
set the key to `null`. This matches the `doctor` fix for the same finding.

### 8. Offer to create the labels

The labels in the config must exist in GitHub for the audits and auto-dev to apply them. Offer:

**Always** (every repo needs these — the audits and any skill that opens work unattended):

```bash
gh label create architecture --color BFD4F2 --description "audit-architecture findings" 2>/dev/null || true
gh label create test-quality --color D4C5F9 --description "audit-tests findings" 2>/dev/null || true
gh label create security     --color D93F0B --description "audit-security findings" 2>/dev/null || true
gh label create dependencies --color 0366D6 --description "audit-deps findings" 2>/dev/null || true
gh label create automated    --color EDEDED --description "Opened by a Maintainerd skill" 2>/dev/null || true
```

**Only if `autoDev.enabled` is `true`** — the six `auto:*` state labels plus the PR label:

```bash
gh label create auto:pr      --color 5319E7 --description "Opened by the auto-dev pipeline" 2>/dev/null || true
```

**Only if `depsFlow.enabled` is `true`** — skip this entirely when the block is absent or disabled,
which is the default. Create the **configured** label, not the literal below: resolve
`depsFlow.blockedLabel` from the config you just wrote, falling back to `deps:blocked` only when the
key is absent. A repo that set a custom name and got `deps:blocked` created would fail `doctor` and
the skill could never mark a blocked PR:

```bash
# <blockedLabel> = config.depsFlow.blockedLabel, default "deps:blocked"
gh label create "<blockedLabel>" --color B60205 --description "Dependency update breaks CI — diagnosed, see linked issue" 2>/dev/null || true
```

The same rule applies to every command in this step: each one creates the name the config actually
holds (`labels.*`, `autoDev.prLabel`), not the default it was written with. The defaults above are
what a stock config contains, not values to paste over a customized one.

Ask before creating; don't mutate the repo's label set unprompted. Don't create a disabled feature's
labels "just in case" — an unused label is a standing hint that automation is running here when it
isn't, and `doctor` will flag the label as missing the moment the feature *is* enabled.

### 9. Silence external review on automated PRs (if agreed)

Creating `autoDev.prLabel` in step 8 only puts a label on the pipeline's PRs — nothing acts on it
until the review tooling is told to. This step closes that loop. Skip it entirely unless the user
opted in during step 5.

**Never overwrite an existing CodeRabbit config.** It is CodeRabbit's file, not maintainerd's, and a
tuned one represents work you can't reconstruct. Check both spellings — `.coderabbit.yaml` and
`.coderabbit.yml` — and branch:

- **Neither exists** → write the minimal file, using the name from `autoDev.prLabel` (not the literal
  below, if they customized it):

  ```yaml
  # Let the auto-dev pipeline review its own PRs; CodeRabbit reviews everything else.
  reviews:
    auto_review:
      labels: ["!auto:pr"]
  ```

- **One exists** → read it and show the user the specific edit rather than making it blind:
  - _No `reviews.auto_review.labels` key_ → propose adding it with `["!<prLabel>"]`, print the
    resulting snippet, and apply only on a yes.
  - _The key exists_ → **do not append silently.** CodeRabbit ANDs the matchers, so adding a negative
    match to an existing list narrows which PRs get reviewed, and combined with an existing positive
    match it can silence far more than intended. Print the current value and the proposed value side
    by side, explain what the combination will and won't review, and let the user decide.
  - _It already carries `!<prLabel>`_ → nothing to do; report it as already configured.

- **Both exist** → **stop and report the conflict.** Don't pick one, don't merge them, don't write
  either. Which file CodeRabbit actually honors when both are present isn't something to guess at,
  and editing the ignored one produces a rule that silently does nothing — the same class of bug
  this whole step exists to fix. Tell the user both spellings are present, name the paths, and let
  them consolidate first.

If the user declines, that's a normal outcome — say so and move on. CodeRabbit can also be
configured from its web dashboard instead of a repo file, so a repo with neither spelling present is
not evidence of anything broken; don't press the point.

This step is CodeRabbit-specific because the negative-label matcher is. Other review bots in
`review.bots` (e.g. `gemini-code-assist[bot]`) have their own mechanisms — don't guess at their
config format; mention in the report that they were left alone.

### 10. Report

Tell the user, concisely:
- The path of the config written and that it validated.
- The detected values for `repo`, `defaultBranch`, `language`, and the command block (the
  high-blast-radius ones).
- Which guideline files were created vs left alone, and that **`invariants.md` needs human review**.
- Whether labels / PR template were created or skipped, and whether a CodeRabbit ignore rule was
  written (and that any other review bot was left alone).
- The reminder to **commit `.claude/maintainerd.json` and `.claude/guidelines/`** so scheduled
  cloud agents pick them up — plus `.coderabbit.yaml` if step 9 wrote one: CodeRabbit reads it from
  the branch, so an uncommitted rule silences nothing.

## What not to do

- **Don't invent commands or paths.** If you can't detect something and the user doesn't know,
  write `null` (commands) or leave the path out and flag it — a wrong value is worse than an
  absent one the skill can report on.
- **Don't clobber hand-edited guidelines.** On a re-run, a guideline file with real content is the
  user's; only touch it if they explicitly ask.
- **Don't list uninstalled skills in `dailyUpdate.subSkills`.** The roster must match what's
  actually installed, or `daily-update` will try to run a missing skill.
- **Don't create labels or a PR template without asking.** These mutate the repo's GitHub/file
  state; confirm first.
- **Don't rewrite an existing `.coderabbit.yaml` or `.coderabbit.yml`.** Maintainerd doesn't own
  that file, in either spelling. Propose the one-key edit and let the user apply it; a merge that
  silences review on PRs they expected to be reviewed is worse than no rule at all. If both
  spellings exist, stop and report rather than choosing one.
- **Don't enable `depsFlow` without an explicit yes.** It grants a skill permission to merge PRs in
  this repo — the one setting in the config with real, irreversible blast radius. `false` is the
  correct value whenever there's any doubt.
- **Don't commit.** Write the files and let the user review and commit them.
