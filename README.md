# Maintainerd

**Maintainerd** is a Claude Code plugin marketplace of **config-driven maintainer skills** — the nightly
audits, daily changelog, doc validation, PR flow, and autonomous issue→PR pipeline that a
solo maintainer wants on every repo, extracted so they live in one place instead of being
copy-pasted (and drifting) across projects.

Every skill reads a small per-repo config contract — `.claude/maintainerd.json` plus a few
`.claude/guidelines/*.md` files — checked into the consuming repo. The same skill runs
unchanged in a Python repo and a TypeScript repo; only the config differs. The `bootstrap`
skill generates that contract for any repo.

## Plugins

| Plugin | Skills | Install when |
| --- | --- | --- |
| **maintainerd-core** | `bootstrap`, `doctor` | Always — `bootstrap` generates the config every other plugin needs; `doctor` validates it. |
| **repo-ops** | `create-pr`, `address-review`, `code-review`, `release`, `daily-changelog`, `daily-update` | You want the baseline PR + changelog dev flow. |
| **audits** | `audit-architecture`, `audit-tests`, `audit-security`, `audit-deps`, `audit-design-docs`, `audit-product-docs` | You want scheduled tech-debt / test / security / dependency / doc sweeps. |
| **research** | `research-radar` | You want proactive research surfaced — a periodic arXiv scan for papers relevant to this repo. |
| **journal** | `worklog` | You want a day's shipped work captured into your Obsidian vault (user-scoped — spans all your repos). |
| **auto-dev** | `create-issue`, `auto-dev`, `review-queue` | You want the autonomous issue→PR pipeline (from issue intake through build to review). |
| **deps-flow** | `dependabot` | You want the Dependabot queue drained unattended — and you're willing to let a skill **merge**. |

A repo installs only the plugins it wants. `auto-dev` works standalone (with `maintainerd-core`
for config); the audits and repo-ops compose but don't require each other.

> **`deps-flow` is the exception to the suite's "never auto-merges" rule.** Every other skill stops
> at the merge gate; `dependabot` merges dependency PRs that pass a strict gate (all checks
> concluded green, no requested changes, bump level within the repo's policy). It requires an
> explicit `depsFlow.enabled: true` — an absent config block means *off*, never *defaults*. Run
> `/dependabot dry-run` first.

## Setup in a new repo

1. **Add the marketplace** (once per machine):

   ```bash
   claude plugin marketplace add allenhutchison/maintainerd
   # or, for local development:
   claude plugin marketplace add /Users/allen/src/maintainerd
   ```

2. **Install the plugins you want**, starting with core:

   ```
   /plugin   # then install maintainerd-core, repo-ops, audits, research, auto-dev as desired
   ```

3. **Generate the config** by running the bootstrap skill in the target repo:

   ```
   /bootstrap
   ```

   It inspects the repo (language, repo slug, default branch, source/test dirs, lint/test
   commands), confirms anything ambiguous with you, and writes:

   - `.claude/maintainerd.json` — the structured config (see
     [`plugins/core/reference/config-schema.md`](plugins/core/reference/config-schema.md)).
   - `.claude/guidelines/coding.md`, `testing.md`, `invariants.md` — starter guideline files
     seeded from your `CLAUDE.md`/`AGENTS.md`, with TODOs for the repo-specific invariants the
     audits should enforce.

4. **Fill in `invariants.md`** — this is the one file that needs real human judgment. It holds
   the load-bearing, repo-specific rules the audit-architecture checks (e.g. "secrets are
   `SecretStr`", "use `plugin.logger`, never `console`").

5. Commit `.claude/maintainerd.json` and `.claude/guidelines/` to the repo so the skills (and
   any scheduled cloud agents) pick them up.

## How the config contract works

- **Structured scalars → JSON.** Repo slug, default branch, language, source/test/doc paths,
  lint/format/build/test commands, label names, per-run caps, the daily-update roster, and the
  `auto:*` state-machine label names all live in `.claude/maintainerd.json`.
- **Free-form repo rules → markdown.** Coding standards, test conventions, and load-bearing
  invariants live in `.claude/guidelines/*.md`, which the skills read at runtime. This keeps the
  JSON scannable and lets the prose diff cleanly.

Most skills begin by reading `.claude/maintainerd.json`; if it's missing, the skill tells you to run
`/bootstrap`. The canonical schema and the shared "read your repo config" preamble live in
[`plugins/core/reference/config-schema.md`](plugins/core/reference/config-schema.md).

- **User-scoped exception.** A few settings are the same across every repo you work in (the `journal`
  category's Obsidian vault). Those live in a **user-level** `~/.claude/maintainerd.json`, read once
  regardless of repo. `worklog` reads the vault from there and an optional per-repo pointer from the
  repo config. See "User-level config" in the schema reference.

## Repository layout

```
maintainerd/
  .claude-plugin/marketplace.json
  plugins/
    core/      .claude-plugin/plugin.json  skills/{bootstrap,doctor}/  reference/config-schema.md
    repo-ops/  .claude-plugin/plugin.json  skills/{create-pr,address-review,code-review,release,daily-changelog,daily-update}/
    audits/    .claude-plugin/plugin.json  skills/{audit-architecture,audit-tests,audit-security,audit-deps,audit-design-docs,audit-product-docs}/  reference/pattern-promotion.md
    research/  .claude-plugin/plugin.json  skills/{research-radar}/
    journal/   .claude-plugin/plugin.json  skills/{worklog}/
    auto-dev/  .claude-plugin/plugin.json  skills/{create-issue,auto-dev,review-queue}/
    deps-flow/ .claude-plugin/plugin.json  skills/{dependabot}/
```

## Roadmap

Planned and candidate skills — what's shipped, what's ready to extract from an existing repo, and
what's net-new — live in [`docs/roadmap.md`](docs/roadmap.md).

## License

MIT
