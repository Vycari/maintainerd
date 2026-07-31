# The repo config contract: `.claude/maintainerd.json`

Every Maintainerd skill is **repo-agnostic**. The repo-specific details — slug, branch,
language, paths, commands, label names, caps — live in a config file the consuming repo checks
in. This document is the canonical schema. The `bootstrap` skill generates the file; the other
skills read it.

There are two halves to the contract:

1. **`.claude/maintainerd.json`** — structured scalars (this document).
2. **`.claude/guidelines/*.md`** — free-form repo rules the skills read as prose (see
   [Guidelines files](#guidelines-files)).

---

## The "read your repo config" preamble

Every skill in this toolkit starts the same way. When a skill says *"load the repo config (see
config-schema.md)"*, it means exactly this:

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **stop** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.
   Do not guess values or hardcode another repo's settings.
3. Read only the keys the skill needs. Treat a `null` command as *"this repo has no such step —
   skip it"* (e.g. a Python repo has `commands.build: null`; don't invent a build step).
4. For any key a skill needs that is **absent** (older config, optional section), fall back to the
   documented default below and mention the fallback in your run report so the user can add it.
5. When a skill needs repo-specific *rules* (coding standards, test conventions, invariants),
   read the markdown file named in `guidelines.*` rather than relying on built-in assumptions.

Read with whatever is convenient — the `Read` tool, or `jq` for a single value, e.g.
`jq -r '.defaultBranch' .claude/maintainerd.json`.

---

## Full schema

```jsonc
{
  // ── Identity ────────────────────────────────────────────────────────────
  "repo": "owner/name",            // GitHub slug, e.g. "allenhutchison/pepper". Used in every `gh ... --repo`.
  "defaultBranch": "main",         // Branch PRs target and audits check out. "main" | "master" | ...
  "language": "python",            // "python" | "typescript". Selects audit/test detection rules.

  // ── Commands ────────────────────────────────────────────────────────────
  // The shell commands a skill runs for pre-flight gates. null = step not applicable; skip it.
  "commands": {
    "format":   "uv run ruff format --check",   // formatting check (non-mutating)
    "lint":     "uv run ruff check",            // linter; null if folded into format
    "build":    null,                           // e.g. "npm run build"; null for interpreted repos
    "test":     "uv run pytest",                // the test suite
    "coverage": "uv run pytest --cov --cov-report=json", // optional; used by audit-tests
    "typecheck": null                           // e.g. "npm run typecheck:test"; null if covered elsewhere
  },

  // ── Paths ───────────────────────────────────────────────────────────────
  "paths": {
    "source":       "src/pepper/",              // root of source the audits sweep
    "tests":        "tests/",                    // root of the test tree
    "designDocs":   ["planning/"],               // design/architecture docs (audit-design-docs)
    "productDocs":  ["docs/", "README.md", "AGENTS.md"], // user-facing docs (audit-product-docs)
    "changelogDir": "planning/changelog/",       // where daily-changelog writes YYYY-MM-DD.md
    "researchRadarDir": "planning/research-radar/", // where research-radar writes its digests
    "prTemplate":   ".github/PULL_REQUEST_TEMPLATE.md", // PR body template create-pr enforces; null = repo uses no template
    "skillsDir":    ".claude/skills/"            // local skill scaffolding dir; pre-flight clean-tree exception
  },

  // ── Guidelines (free-form rule files; see below) ─────────────────────────
  "guidelines": {
    "coding":     ".claude/guidelines/coding.md",
    "testing":    ".claude/guidelines/testing.md",
    "invariants": ".claude/guidelines/invariants.md",
    "release":    ".claude/guidelines/release.md"  // optional; repo-specific release gates + caveats (read by `release`)
  },

  // ── GitHub labels ────────────────────────────────────────────────────────
  "labels": {
    "architecture": "architecture",  // applied to audit-architecture PRs/issues
    "testQuality":   "test-quality", // applied to audit-tests PRs/issues
    "security":      "security",     // applied to audit-security PRs/issues
    "dependencies":  "dependencies", // applied to audit-deps PRs/issues
    "automated":     "automated"     // applied to anything a skill opens unattended
  },

  // ── Per-run caps for the audits (keep review load sustainable) ───────────
  "audits": {
    "prCap":      3,   // audit-architecture: max PRs opened per run
    "issueCap":   5,   // audit-architecture: max issues filed per run
    "testPrCap":  2,   // audit-tests: max PRs per run
    "testIssueCap": 2, // audit-tests: max issues per run
    "securityPrCap":    3, // audit-security: max PRs per run
    "securityIssueCap": 5, // audit-security: max issues per run (Critical/High over cap still reported)
    "depsPrCap":    3, // audit-deps: max PRs per run (a batched routine-bump PR counts as one)
    "depsIssueCap": 5, // audit-deps: max issues per run

    // Pattern promotion (audit-architecture/-tests/-security): when the same specific
    // pattern has been fixed/filed this many times within the lookback window, the audit
    // files ONE human-gated issue proposing it become a guideline rule. See
    // plugins/audits/reference/pattern-promotion.md. Both optional; defaults shown.
    "promoteThreshold":    3,  // recurrences (incl. this run) before a promotion is proposed
    "promoteLookbackDays": 90  // how far back to count prior actioned instances
  },

  // ── Model tiers (optional) — bind tier labels to model ids for scheduled routines ──
  // Absent, or a tier set to "inherit" → no override (use the routine/session model).
  // See plugins/core/reference/model-tiers.md for which routine wants which tier.
  "models": {
    "fast":    "claude-haiku-4-5",  // mechanical, high-volume, low-judgment (e.g. audit-deps)
    "capable": "claude-opus-4-8",   // judgment, code generation, security (e.g. auto-dev, audit-security)
    "default": "inherit"            // fallback when a skill names no tier
  },

  // ── daily-update meta-skill ──────────────────────────────────────────────
  "dailyUpdate": {
    "subSkills":    ["daily-changelog", "audit-product-docs"], // roster; ONLY list installed skills
    "branchPrefix": "daily-update-",
    "commitSubject": "chore(daily): {date} daily update"       // {date} -> YYYY-MM-DD
  },

  // ── auto-dev pipeline ─────────────────────────────────────────────────────
  "autoDev": {
    "enabled":      true,
    "branchPrefix": "auto/issue-",
    "marker":       "<!-- auto-dev -->",  // HTML comment stamped on bot comments so the pipeline recognizes its own
    "stateLabels": {
      "needsInfo":  "auto:needs-info",
      "planned":    "auto:planned",
      "ready":      "auto:ready",
      "inProgress": "auto:in-progress",
      "parked":     "auto:parked",
      "skip":       "auto:skip"
    },
    "excludedLabels": ["epic", "question", "wontfix", "duplicate", "invalid"], // never auto-build these
    "openPrsAsDraft": true,
    "prLabel":        "auto:pr",  // applied to every PR the pipeline opens, so external tooling (e.g. CodeRabbit) can treat automated PRs specially. Distinct from labels.automated (which the audits also use). Must already exist; bootstrap creates it.
    "fallbackReviewMinutes": 60,  // how long a ready, CI-green automated PR may sit with zero review activity before auto-dev posts a fallback self-review (CodeRabbit normally reviews within minutes; past this, assume it's rate-limited). Default 60 if absent.
    "maxPrsInFlight": 1,          // how many automated PRs may be open at once. 1 = classic single-PR pipeline (an open PR blocks new builds until it merges). >1 lets the queue drain into several built-but-unmerged PRs awaiting review. Never merges/closes anything. Default 1 if absent.
    "orphanReclaimMinutes": 90    // min age of a PR-less in-progress issue before a tick treats it as a crashed build (and rebuilds) rather than one running concurrently in an overlapping tick (and leaves it alone). Default 90 if absent.
  },

  // ── deps-flow (the `dependabot` skill) — the ONE skill that merges ─────────
  // Absent, or `enabled` not true, = disabled. There is no permissive default here:
  // merge authority is granted explicitly or not at all.
  "depsFlow": {
    "enabled":         false,                  // explicit opt-in to letting the skill merge in this repo
    "botLogins":       ["dependabot[bot]"],    // whose PRs it may act on; add "renovate[bot]" if applicable
    "marker":          "<!-- deps-flow -->",   // HTML comment stamped on its own comments/issues
    "autoMergeSemver": ["patch", "minor"],     // bump levels eligible for auto-merge; anything else is held for the human
    "holdPackages":    [],                     // package names (exact or *-globbed) never auto-merged at any level
    "mergeMethod":     "squash",               // "squash" | "merge" | "rebase" — must be allowed by the repo's settings
    "requireApproval": false,                  // true = also require reviewDecision == APPROVED, not just "nothing blocking"
    "maxMergesPerRun": 5,                      // hard cap on merges per invocation (drain mode included)
    "rebaseNudgeMinutes": 30,                  // how long a stale PR sits before a single `@dependabot rebase` nudge
    "blockedLabel":    "deps:blocked",         // applied to a PR whose failure was diagnosed + filed; future runs skip it
    "drainPollMinutes": 5,                     // pause between passes in `/dependabot drain`
    "drainMaxMinutes":  90                     // wall-clock ceiling on a drain run
  },

  // ── research-radar ─────────────────────────────────────────────────────────
  "researchRadar": {
    "themes":    "derive",  // "derive" (infer from repo) | ["explicit", "theme", "list"]
    "userAgent": "research-radar/1.0 (mailto:you@example.com)" // arXiv API courtesy UA
  },

  // ── review feedback (address-review) ─────────────────────────────────────────
  "review": {
    // Automated-reviewer logins to recognize. Humans need no listing — any reviewer
    // who isn't the PR author is treated as a human reviewer. Optional; defaults to these two.
    "bots": ["coderabbitai[bot]", "gemini-code-assist[bot]"]
  },

  // ── release (the `release` skill) — null/omitted = repo ships continuously, no versioned release ──
  "release": {
    "versionCommand":   "npm version {level}", // {level} -> patch|minor|major; null = tag manually
    "versionPushesTag": true,                   // true if that command also commits+tags+pushes (e.g. npm postversion)
    "notesFile":        "src/release-notes.json", // changelog/notes file to update; null = GitHub-release notes only
    "readmeSection":    "What's New",           // a README heading to keep in sync; null = skip
    "githubRelease":    true                     // create/publish a GitHub release from the tag
  },

  // ── journal (optional) — maps THIS repo to its project in the user's vault (used by `worklog`) ──
  // The vault itself is user-scoped and lives in the user-level config (see "User-level config" below).
  "journal": {
    "project":  "my-project",                              // project folder name under the vault's projectsGlob
    "hubNote":  "Projects/my-project/my-project.md"        // explicit vault-relative hub note; optional (else inferred)
  }
}
```

---

## Field reference

### Identity

| Key | Meaning | Example |
| --- | --- | --- |
| `repo` | GitHub `owner/name`; passed to every `gh --repo`. | `allenhutchison/pepper` |
| `defaultBranch` | Branch PRs target; audits `git checkout` it before sweeping. | `main`, `master` |
| `language` | Selects the language-specific detection rules in `audit-architecture` and `audit-tests`. | `python`, `typescript` |

### `commands`

Each value is a shell command or `null`. A skill that needs a step whose command is `null`
**skips that step** (and says so). Skills must never substitute a different repo's command.

| Key | Used by | Notes |
| --- | --- | --- |
| `format` | create-pr, audits | Non-mutating format check. |
| `lint` | create-pr, audits | May be `null` if the formatter also lints. |
| `build` | create-pr, auto-dev | `null` for interpreted languages with no build. |
| `test` | create-pr, audit-tests, auto-dev | The suite that gates PRs. |
| `coverage` | audit-tests | Optional; emits machine-readable coverage. |
| `typecheck` | create-pr, auto-dev | Optional separate type-check pass. |

### `paths`

All paths are repo-root-relative. `designDocs` and `productDocs` are **arrays** (a repo can have
several doc roots; entries may be directories or individual files). `skillsDir` names the directory
where untracked skill scaffolding may legitimately appear — the audits treat untracked files there
as benign rather than "a human is mid-work."

`prTemplate` may be `null`: the repo deliberately uses no PR template, and `create-pr` (and
anything else that writes PR bodies) falls back to its built-in Summary / Changes / Checklist
structure. A non-null value must point at a file that exists — bootstrap offers to scaffold one
when the repo has none, and `doctor` flags a dangling path.

### `guidelines`

Pointers to the markdown rule files. See [Guidelines files](#guidelines-files).

### `labels`, `audits`, `models`, `dailyUpdate`, `autoDev`, `depsFlow`, `researchRadar`, `review`, `release`

- `labels.*` — GitHub label names the skills apply. They must already exist in the repo (bootstrap
  offers to create them).
- `audits.*` — per-run caps, plus the two pattern-promotion knobs. Cap defaults `3/5`
  (architecture), `2/2` (test), `3/5` (security), and `3/5` (deps) if absent. `audit-security` still
  *reports* Critical/High findings that exceed its cap;
  `audit-deps` counts a batched routine-bump PR as a single PR. `promoteThreshold` (default `3`) and
  `promoteLookbackDays` (default `90`) govern **pattern promotion** — when the guideline-checking
  audits (architecture/tests/security) have fixed the same specific pattern `promoteThreshold` times
  within the window, they file one human-gated issue proposing it become a guideline rule; if a rule
  already exists and keeps being violated, they instead propose the corresponding **mechanical guard**
  (a lint/CI check). See
  [`../../audits/reference/pattern-promotion.md`](../../audits/reference/pattern-promotion.md).
- `models.*` *(optional)* — tier→model bindings. `fast` / `capable` (optionally a `mid` rung) map a
  tier to a concrete model id; **`default` is not a tier — it's the fallback key** used when a skill
  names no tier. Any of them set to `"inherit"` means no override. Declarative reference config: it
  records which concrete model backs each tier so scheduled routines are tiered consistently, and
  subagent-spawning skills can read it. Absent → every routine inherits its scheduled model
  (pre-tiering behavior). See [`model-tiers.md`](model-tiers.md) for which routine wants which tier.
- `dailyUpdate.subSkills` — the ordered roster `daily-update` runs. **Only list skills that are
  actually installed in this repo**, or `daily-update` will try to invoke a missing skill.
  `{date}` in `commitSubject` is replaced with the ISO date.
- `autoDev.*` — the `auto:*` state-machine label names, the bot comment `marker`, the branch
  prefix, the labels that exclude an issue from auto-building, and whether PRs open as drafts.
  `prLabel` *(default `auto:pr`)* is stamped on **every** PR the pipeline opens — at creation time,
  since review bots fire on the `opened` webhook — so external tooling can single out automated PRs
  and leave them to auto-dev's own review loop. In CodeRabbit that's a negative match in
  `.coderabbit.yaml`: `reviews.auto_review.labels: ["!auto:pr"]`. It's deliberately separate from the
  generic `labels.automated` the audits share, so silencing automated *development* PRs doesn't also
  silence review on audit PRs. `fallbackReviewMinutes` *(default `60`)* is how long
  a ready, CI-green automated PR may sit with no review activity before auto-dev posts a one-per-PR
  **fallback self-review** to fill the gap when CodeRabbit is rate-limited. `maxPrsInFlight`
  *(default `1`)* caps how many automated PRs may be open at once — `1` is the classic single-PR
  pipeline (an open PR blocks new builds until it merges); a higher cap lets the pipeline drain the
  Ready queue into several built-but-unmerged PRs awaiting review (it still never merges or closes
  anything). `orphanReclaimMinutes` *(default `90`)* is the minimum age of a PR-less in-progress
  issue before a tick treats it as a crashed build to rebuild, rather than one running concurrently
  in an overlapping tick (which it leaves alone) — the guard against two ticks racing on the same
  build. All optional; absent → the documented defaults.
- `depsFlow.*` *(the `dependabot` skill — the only maintainerd skill that merges)* — **the one block
  whose absence means "off", not "use the defaults".** A missing block, or `enabled` anything other
  than `true`, disables the skill entirely; merge authority is never acquired by omission. Once
  enabled, the rest have the defaults shown: `botLogins` *(`["dependabot[bot]"]`)* is whose PRs the
  skill may touch — authorship is checked by login, never inferred from a branch or title;
  `autoMergeSemver` *(`["patch","minor"]`)* is the bump levels eligible for auto-merge, everything
  else (majors, and `0.x` minors, which the skill classifies as major) is **held for the human**;
  `holdPackages` *(`[]`)* never auto-merges regardless of level; `mergeMethod` *(`"squash"`)* must be
  a method the repo allows; `requireApproval` *(`false`)* additionally demands an explicit approving
  review; `maxMergesPerRun` *(`5`)* caps merges per invocation including drain mode;
  `rebaseNudgeMinutes` *(`30`)* is how long a stale PR waits before one `@dependabot rebase` nudge
  (Dependabot usually rebases unprompted, so the default action is to wait); `blockedLabel`
  *(`"deps:blocked"`)* marks a PR whose CI failure has been diagnosed and filed as an issue, and is
  the cross-run memory that stops re-diagnosis; `drainPollMinutes` *(`5`)* and `drainMaxMinutes`
  *(`90`)* bound `/dependabot drain`. The skill files its issues under `labels.dependencies` +
  `labels.automated`, so it dedups against `audit-deps` findings for free.
- `researchRadar.themes` — `"derive"` to infer themes from the repo, or an explicit string array.
- `review.bots` *(optional)* — extra automated-reviewer logins `address-review` should recognize.
  Defaults to `["coderabbitai[bot]", "gemini-code-assist[bot]"]`. Humans are auto-detected (any
  reviewer who isn't the PR author), so only bots go here.
- `release.*` *(optional; `null`/omitted = no versioned releases — the repo ships continuously)* —
  the version-bump mechanism (`versionCommand` with `{level}`, `versionPushesTag`), the notes file
  to update (`notesFile`), an optional README section to sync (`readmeSection`), and whether to
  create a GitHub release (`githubRelease`). Repo-specific gates/caveats live in
  `guidelines.release`, not here.
- `journal.*` *(optional)* — maps this repo to its project in the user's Obsidian vault for
  `worklog`: `project` (folder name) and/or `hubNote` (explicit vault-relative path). Absent → the
  project is inferred from the repo name. The **vault itself is not here** — it's user-scoped; see
  [User-level config](#user-level-config).

---

## Guidelines files

Long-form, judgment-heavy rules don't belong in JSON. They live in markdown files named by
`guidelines.*` and are read by the skills as prose.

| File | Read by | Holds |
| --- | --- | --- |
| `coding.md` | `code-review`, `audit-architecture` | The coding standards a senior reviewer enforces here — error-handling conventions, logging (`logger` vs `print`/`console`), typing expectations, naming, banned patterns. |
| `testing.md` | `audit-tests`, `code-review` | Test conventions — the DB/fixture pattern, what may and may not be mocked, isolation rules, assertion expectations, naming. |
| `invariants.md` | `audit-architecture` | The **load-bearing, repo-specific invariants** that CI doesn't catch. This is the file that replaces the hardcoded repo-specific prose the old per-repo audits carried (e.g. pepper's `app.state` lifespan wiring + `SecretStr` rule; an Obsidian plugin's "use `plugin.logger`, never `console`" + "don't touch the generated-help file"). The audit reads each rule here and checks the diff against it. |
| `release.md` *(optional)* | `release` | Repo-specific release gates and caveats: a runtime/smoke test the unit suite can't cover, dependency caveats, release-name formatting a registry enforces, notes-rendering quirks, artifact specifics (e.g. an Obsidian plugin's live-transport smoke gate + the "release title must contain full X.Y.Z" rule). |

A skill that finds a guidelines file missing or still full of `TODO` markers should note that in
its report (the rule coverage is only as good as these files) and proceed with the
language-generic checks it can still perform.

---

## User-level config

Almost everything above is **repo-scoped** — it lives in each repo's `.claude/maintainerd.json`,
because it describes *that repo*. A few settings are **user-scoped**: they're the same across every
repo the user works in, so pinning them per-repo would be redundant and wrong. Those live in a
**user-level** file at `~/.claude/maintainerd.json`, read once regardless of which repo you're in.

Today this holds the `journal` category's vault:

```jsonc
// ~/.claude/maintainerd.json  (per-user, not checked into any repo)
{
  "journal": {
    "vault":        "/Users/you/Obsidian/my-vault", // Obsidian vault root — required by `worklog`
    "projectsGlob": "Projects/**"                    // where project folders live (optional; default "Projects/**")
  }
}
```

The split rule: **repo-scoped settings → repo config; user-scoped settings → user config.** `worklog`
bridges them — it reads the vault from here, and the *optional* per-repo `journal.project`/`hubNote`
pointer (above) from the repo config to know which vault project *this* repo maps to. If the user-level
file or `journal.vault` is absent, `worklog` asks for the vault path and offers to write it here.

A sample lives alongside this file as [`example-user.json`](example-user.json).

---

## Worked examples

A complete pepper (`python`) and obsidian-gemini (`typescript`) repo config live alongside this file
as [`example-pepper.json`](example-pepper.json) and [`example-obsidian.json`](example-obsidian.json),
and a user-level config as [`example-user.json`](example-user.json). They double as the round-trip
fixtures the verification step checks the schema against.
