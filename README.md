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
| **[maintainerd-core](plugins/core/README.md)** | `bootstrap`, `doctor` | Always — `bootstrap` generates the config every other plugin needs; `doctor` validates it. |
| **[repo-ops](plugins/repo-ops/README.md)** | `create-pr`, `address-review`, `release`, `daily-changelog`, `daily-update` | You want the baseline PR + changelog dev flow. |
| **[audits](plugins/audits/README.md)** | `audit-architecture`, `audit-tests`, `audit-security`, `audit-deps`, `audit-design-docs`, `audit-product-docs` | You want scheduled tech-debt / test / security / dependency / doc sweeps. |
| **[research](plugins/research/README.md)** | `research-radar` | You want proactive research surfaced — a periodic arXiv scan for papers relevant to this repo. |
| **[journal](plugins/journal/README.md)** | `worklog` | You want a day's shipped work captured into your Obsidian vault (user-scoped — spans all your repos). |
| **[auto-dev](plugins/auto-dev/README.md)** | `create-issue`, `auto-dev`, `review-queue` | You want the autonomous issue→PR pipeline (from issue intake through build to review). |
| **[deps-flow](plugins/deps-flow/README.md)** | `dependabot` | You want the Dependabot queue drained unattended — and you're willing to let a skill **merge**. |

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
   claude plugin marketplace add Vycari/maintainerd
   # or, for local development:
   claude plugin marketplace add /path/to/your/checkout/maintainerd
   ```

2. **Install the plugins you want**, starting with core:

   ```text
   /plugin   # then install maintainerd-core, repo-ops, audits, research, auto-dev as desired
   ```

3. **Generate the config** by running the bootstrap skill in the target repo:

   ```text
   /bootstrap
   ```

   It inspects the repo (language, repo slug, default branch, source/test dirs, lint/test
   commands), confirms anything ambiguous with you, and writes:

   - `.claude/maintainerd.json` — the structured config (see
     [`plugins/core/references/config-schema.md`](plugins/core/references/config-schema.md)).
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
[`plugins/core/references/config-schema.md`](plugins/core/references/config-schema.md).

- **User-scoped exception.** A few settings are the same across every repo you work in (the `journal`
  category's Obsidian vault). Those live in a **user-level** `~/.claude/maintainerd.json`, read once
  regardless of repo. `worklog` reads the vault from there and an optional per-repo pointer from the
  repo config. See "User-level config" in the schema reference.

## Repository layout

```text
maintainerd/
  .claude-plugin/marketplace.json
  scripts/sync-references.sh
  scripts/bump-version.py
  plugins/
    core/      .claude-plugin/plugin.json  skills/{bootstrap,doctor}/  references/{config-schema,model-tiers}.md
    repo-ops/  .claude-plugin/plugin.json  skills/{create-pr,address-review,release,daily-changelog,daily-update}/
    audits/    .claude-plugin/plugin.json  skills/{audit-architecture,audit-tests,audit-security,audit-deps,audit-design-docs,audit-product-docs}/  references/pattern-promotion.md
    research/  .claude-plugin/plugin.json  skills/{research-radar}/
    journal/   .claude-plugin/plugin.json  skills/{worklog}/
    auto-dev/  .claude-plugin/plugin.json  skills/{create-issue,auto-dev,review-queue}/
    deps-flow/ .claude-plugin/plugin.json  skills/{dependabot}/
```

### Shared reference docs

`config-schema.md` and `model-tiers.md` are authored once in `plugins/core/references/` and
**vendored into every plugin that links them**. A skill can only reach files inside its own
plugin: a relative link that climbs out resolves in this source tree but not in an installed
marketplace layout, which interposes a version segment and uses the plugin *name* rather than
the source directory name —

```text
source:     plugins/audits/skills/audit-tests/SKILL.md
installed:  <cache>/maintainerd/audits/0.1.0/skills/audit-tests/SKILL.md
```

So a link like `../../../core/references/config-schema.md` resolves from the source path and
lands nowhere from the installed one — it misses on both the extra version segment and the
directory name (`maintainerd-core`, not `core`). Intra-plugin links are the one form that
resolves identically in both layouts *and* in the clone-and-read path scheduled cloud routines
use, so every skill links its own plugin's copy.

Edit the canonical file in `plugins/core/references/`, then run:

```bash
./scripts/sync-references.sh
```

The copies carry a generated-file banner and CI fails if they drift.

## Versioning

**A plugin's version is the only signal Claude Code has that an installed copy is stale.** The
install cache is keyed by it —

```text
<cache>/maintainerd/audits/0.2.0/skills/audit-tests/SKILL.md
```

— so a merge that rewrites a skill but leaves the version alone reaches nobody who already
installed the plugin. They keep running the old content indefinitely.

So versions are not a release ceremony here; they are the delivery mechanism, and they are
automatic. [`.github/workflows/version-bump.yml`](.github/workflows/version-bump.yml) runs on
every push to `main`, patch-bumps each plugin whose files the push touched, commits that back to
`main`, and pushes a `<plugin>--v<version>` tag (the convention `claude plugin tag` uses). Plugins
the push didn't touch don't move, so installs of those stay put.

Two things to know when working in this repo:

- **The version lives in two files that must agree** — `plugins/<dir>/.claude-plugin/plugin.json`
  and the plugin's entry in `.claude-plugin/marketplace.json`. `validate.yml` fails the build if
  they drift. Use the script rather than editing either by hand:

  ```bash
  ./scripts/bump-version.py --level minor repo-ops
  ```

- **A hand-written bump wins.** For a change that deserves a minor or major, bump it in the PR;
  on merge the workflow sees the version already moved in that range, leaves it alone, and just
  tags it. The automatic patch is the default, not an override. A hand-written version has to be
  plain `X.Y.Z` and has to increase — the script refuses anything else rather than publish a
  `--vNone` tag or a downgrade that the version-keyed cache would read as a fresh release.

- **`[skip bump]` opts out.** A merge or squash commit message containing that marker skips the
  workflow entirely, for a change under `plugins/**` that shouldn't reach anyone — a typo in a
  comment, say. It's also what the workflow stamps on its own commits so they don't re-trigger
  it. Use it sparingly: a skipped bump means the change ships to nobody until the next one.

### Pulling updates into a local install

Claude Code refreshes the marketplace clone on its own schedule, which can leave a checkout well
behind `main`. To force it:

```bash
claude plugin marketplace update maintainerd
```

Then update the plugins themselves — this is what re-reads the version and re-downloads:

```bash
claude plugin update maintainerd-core@maintainerd --scope project
```

Both halves of that command matter, and each fails in its own way:

- **Use the full `<plugin>@<marketplace>` id.** A bare `claude plugin update maintainerd-core`
  fails with `Plugin "maintainerd-core" not found`, even though `claude plugin list` shows it
  installed.
- **Pass the scope it was installed with.** `update` defaults to `--scope user`; these are usually
  installed per-repo, and the user-scoped lookup won't find a project-scoped install. `claude
  plugin list` reports the scope of each.

A restart is required for either to take effect. If a skill looks like it's running an old
version, compare the version in `claude plugin list` against `marketplace.json` — and check the
version segment of the cache path, since that is what the skill is actually being read from.

## Roadmap

Planned and candidate skills — what's shipped, what's ready to extract from an existing repo, and
what's net-new — live in [`docs/roadmap.md`](docs/roadmap.md).

## License

MIT
