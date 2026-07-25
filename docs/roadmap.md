# Maintainerd — skill roadmap

A living catalog of skills for the Maintainerd suite: what's shipped, what's ready to extract
from an existing repo, and what's net-new. Use it to pick the next thing to build and to keep the
suite's scope coherent.

**Status legend**
- ✅ **Shipped** — in the marketplace today.
- ♻️ **Extract** — a working version already lives in `pepper` and/or `obsidian-gemini`; the job is
  the same generalize-against-config pass we've already done (swap repo tokens for `config.*`, lift
  repo specifics into `guidelines/*.md`).
- ✨ **Net-new** — no existing source; design from scratch.

**Design conventions every new skill follows** (so the suite stays consistent):
1. Opens by reading `.claude/maintainerd.json` (the "Load the repo config" preamble); stops and
   points the user to `/bootstrap` if it's missing.
2. Repo-specific *scalars* come from the config; repo-specific *rules* come from `guidelines/*.md`.
3. Anything that opens PRs runs the repo's pre-flight via `create-pr` (or `config.commands.*` inline).
4. Unattended/scheduled skills are **capped per run**, **dedup against open work**, and where
   appropriate are **silent on clean** (no findings → no PR, no issue, no report).
5. Never auto-merges. Human-in-the-loop for anything outward-facing. **One deliberate exception:**
   the `deps-flow` plugin's `dependabot` skill merges bot-authored dependency PRs that pass a strict,
   mechanical gate. It earns the exception by (a) shipping in its own plugin, so installing it *is*
   the consent, (b) requiring an explicit `depsFlow.enabled: true` — an absent config block means
   off, not defaults, and (c) confining the authority to PRs whose author is a configured bot, whose
   checks have all concluded green, and whose bump level the repo opted into. Any future
   merge-capable skill follows the same three rules.

---

## Shipped (v0.1)

| Plugin | Skills |
| --- | --- |
| `maintainerd-core` | `bootstrap` |
| `repo-ops` | `create-pr`, `address-review`, `code-review`, `release`, `daily-changelog`, `daily-update` |
| `audits` | `audit-architecture`, `audit-tests`, `audit-security`, `audit-deps`, `audit-design-docs`, `audit-product-docs` |
| `research` | `research-radar` |
| `auto-dev` | `auto-dev`, `review-queue`, `create-issue` |
| `deps-flow` | `dependabot` |

---

## deps-flow (dependency PR throughput — the merge-capable corner)

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`dependabot`~~ | ✅ **Shipped** | new | Drain the Dependabot queue: gate each bot PR on all checks concluded green + no requested changes + a semver policy (`autoMergeSemver`, patch/minor by default; majors and `0.x` minors held for the human), merge one PR per non-overlapping file group, let Dependabot rebase the rest (nudging `@dependabot rebase` only when a rebase is genuinely stuck), repeat. A broken update is **never fixed** — diagnosed from CI logs + the release notes in the PR body, filed as one issue with an honest confidence line, PR labelled `deps:blocked` so no later run re-diagnoses it. Tick mode for scheduling, `drain` for clearing the queue now, `dry-run` for a read-only preview. |
| `dependabot-config` | ✨ Net-new | — | The upstream half: author/maintain `.github/dependabot.yml` — ecosystems, grouping rules (fewer, larger PRs merge far better through the gate above), schedule, and ignore rules. Natural companion; would ship in the same plugin. |

---

## repo-ops candidates (the dev/PR lifecycle)

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`release`~~ | ✅ **Shipped** | was `release-process` (obsidian-gemini) | Gather changes since the last tag → update notes → pre-flight + the repo's final release gate → bump via `config.release.versionCommand` → tag → GitHub release → verify. The "ship a version" counterpart to `daily-changelog`. Version mechanism + notes file come from `config.release`; repo-specific gates/caveats from `config.guidelines.release`; `release: null` = continuous-deploy repo (confirms before acting). |
| ~~`address-review`~~ | ✅ **Shipped** | was `coderabbit-review` (global) | The review-response loop, expanded so bot (CodeRabbit / gemini-code-assist / `config.review.bots`) and human feedback are equal first-class citizens: fetch → triage → fix (one commit each) → pre-flight → push → reply to every inline thread + a PR-level round summary → wait → repeat to approval. Closes the PR lifecycle alongside `create-pr`. |

## audits candidates (capped, silent-on-clean findings)

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`audit-security`~~ | ✅ **Shipped** | new (complements `/security-review`) | Whole-tree + dependency sweep: vulnerable deps (CVEs), committed secrets, dangerous patterns (injection, unsafe deserialization, shelling out with user input). Severity-ranked; honest about scanner coverage (missing tool → "not scanned", never "clean"); safe secret handling (redact + alert, never auto-delete). Distinct from `/security-review`'s branch-diff scope. |
| ~~`audit-deps`~~ | ✅ **Shipped** | new | Dependency health (the non-security side): outdated (patch/minor batched into one PR, major → issue), deprecated/EOL, unused + phantom deps, lockfile drift, license issues. Honest about analyzer coverage; dedups against `audit-security` (CVEs) and any Dependabot/Renovate. |
| `audit-todos` | ✨ Net-new | — | Sweep `TODO`/`FIXME`/`HACK`/`XXX`, age them against blame, and file issues for stale ones. Lightweight, language-agnostic, satisfying. |
| `audit-config` | ✨ Net-new | — | Meta-maintenance of the plumbing: validate CI workflows, `.env.example` ↔ real settings sync, schedule definitions, and the repo's own `maintainerd.json`/guidelines health. |

## research candidates (proactive — surface outside knowledge, open a PR/digest)

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| `deep-research` | ♻️ Extract | `deep-research` (global) | The fan-out → fetch → adversarially-verify → cited-report harness. Drops straight into `research`. |
| `prior-art` | ✨ Net-new | — | GitHub/code search for similar implementations, competing libraries, or existing solutions before you build. Natural feeder into `auto-dev`'s planning step. |
| `dependency-watch` | ✨ Net-new | — | Track upstream changelogs and *coming* breaking changes in deps you actually use (distinct from `audit-deps`'s "what's stale right now"). |

## issues candidates (intake → pipeline-ready)

The job of these is to get well-formed, buildable issues *into* the repo so the `auto-dev`
pipeline has good raw material — vague, underspecified issues are the main thing that makes an
autonomous builder waste a cycle or go sideways. They'd ship in the `auto-dev` plugin, or a small
dedicated `issues` plugin.

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`create-issue`~~ | ✅ **Shipped** (in `auto-dev`) | new | Turn a rough request into a GitHub issue **ready for `auto-dev`**: investigate the codebase to ground it in real file/symbol pointers (or ask only the gaps investigation can't answer), draft a crisp problem statement + acceptance criteria + tight scope, dedup, confirm, and file. Leaves the issue for auto-dev's triage by default (doesn't skip the plan-approval handshake); excludes epics/questions via `config.autoDev.excludedLabels`. The front-door companion to the pipeline. |
| `triage-issues` | ♻️ Extract | `triage-issues` in obsidian-gemini | Label unlabeled issues via `gh`. Conservative — never closes or reassigns, only adds existing labels. |

## auto-dev candidates

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| `plan` | ✨ Net-new (extract from auto-dev) | inline in `auto-dev` | Stand-alone "draft an implementation plan for issue #N for maintainer approval." Pulling it out lets you plan without running a full tick. |

## meta / suite-health

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`doctor`~~ | ✅ **Shipped** | new (in `maintainerd-core`) | The companion to `bootstrap`: validate `.claude/maintainerd.json` (parses + schema-conformant), that paths/commands/guidelines resolve, that the configured labels exist on GitHub, that the daily-update roster only names installed skills, auto-dev + release coherence, and flag stubbed `invariants.md`. Read-only PASS/WARN/FAIL report; offers to create missing labels with `--fix`. The thing you run when a skill misbehaves. |
| `sync-config` | ✨ Net-new | — | Re-run bootstrap's detection when the repo changes (new test command, renamed dirs) and propose a config diff for approval. |
| `skill-author` | ♻️ Extract | `skill-author` in pepper | A *meta* skill that scaffolds a new config-driven Maintainerd skill (frontmatter, config preamble, conventions). On-brand and accelerates everything else in this list. |

---

## Category: journal (cross-repo, user-scoped) — shipped ✅

The `journal` **plugin** is live, anchored by **`worklog`**, which summarizes a day's shipped work as
a dated entry in an Obsidian vault — a session-summary note, a project-hub link, and a daily-note
line, drawn from the day's merged PRs enriched by the live session.

It's the first skill that isn't repo-scoped: it writes to a *personal vault* that spans projects,
which is exactly why it drove the two-tier config design below.

**Resolved design (two-tier config).** The intended usage is: install the plugins once at the
**user level**, then use them across many repos; each repo-scoped skill discovers that repo's
`.claude/maintainerd.json` as it runs there. User-scoped skills like `worklog` follow the same
grain — their settings live in a **user-level** config (`~/.claude/maintainerd.json`), read once
and shared across every repo. That file carries the things that are per-*user*, not per-*repo*:
- `journal.vault` — the Obsidian vault root (the same vault backs every repo's worklog).
- anything else not auto-discoverable. Most of the rest worklog already discovers from the vault
  itself (it reads `.obsidian/daily-notes.json` for the daily-note folder/format).

The only genuinely per-repo bit is *which* project folder / hub note a given repo maps to. That's
an optional `journal.hubNote` pointer in the repo-level `maintainerd.json`, falling back to
matching the repo name against `Projects/**`. So the rule stays clean: **repo-scoped settings →
repo config; user-scoped settings → user config**, and worklog bridges them with one optional
per-repo pointer. The canonical `config-schema.md` now has a "User-level config" section documenting
`~/.claude/maintainerd.json`.

| Skill | Status | Source | What it does |
| --- | --- | --- | --- |
| ~~`worklog`~~ | ✅ **Shipped** | was `worklog` (global) | Summarize the day's shipped work into the user's Obsidian vault: session-summary note + project-hub link + daily-note line, from merged PRs enriched by the live session. Vault from user-level config; optional per-repo `journal` pointer maps the repo to its vault project. Append-safe (never clobbers prior entries). |
| `weekly-review` | ✨ Net-new | — | Roll the week's worklogs/PRs into a higher-level review note. (Speculative sibling.) |
| `decision-log` | ✨ Net-new | — | Capture notable technical decisions as dated ADR-style notes. (Speculative sibling.) |

---

## v0.2 batch — done ✅

The loop *bootstrap → build → review → ship → keep-healthy* is closed: `address-review`,
`audit-security`, `release`, `audit-deps`, and `doctor` all shipped.

`worklog` (♻️, journal) and `create-issue` (✨, in `auto-dev`) also shipped since.

Next up:

- `weekly-review` / `decision-log` (✨) — speculative `journal` siblings once `worklog` has proven out.
- `triage-issues` (♻️) — the other issue-intake candidate, still on the list.
- **Migration** — onboard a real repo (pepper or obsidian-gemini) to prove the whole suite end-to-end.
