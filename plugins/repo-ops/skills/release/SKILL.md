---
name: release
description: Cut a versioned release of the repo — gather every change since the last tag (not just this session), update the repo's release notes / changelog, run the pre-flight checks and the repo's final release gate, bump the version via the repo's configured mechanism, push the tag, create/publish the GitHub release, and verify. Reads `config.release` for the version-bump mechanism + notes file and `config.guidelines.release` for repo-specific gates and caveats. Use when the user asks to "cut a release", "ship a release", "bump the version", "publish a new version", or "do the release". For repos that ship continuously (no versioned releases) it confirms before doing anything.
---

# Cut a versioned release

This skill drives the full release workflow: gather changes → write notes → check → bump → tag →
GitHub release → verify. The *shape* is universal; the *mechanics* (how a version is bumped, where
notes live, what final gate must pass) vary per repo and come from the config and a guidelines doc —
nothing about a specific repo's toolchain is baked into this skill.

It's the "ship a version" counterpart to `daily-changelog`'s "record a day": where `daily-changelog`
logs each day's merges, `release` consolidates everything since the last tag into one versioned
release.

## When to use

When the user wants to publish a new version. **Not** for recording daily activity (that's
`daily-changelog`) and **not** for repos that ship continuously with no versioned artifact — if
`config.release` is absent or `null`, this repo probably deploys straight from the default branch;
say so and confirm with the user before doing anything.

## Load the repo config

Read `.claude/maintainerd.json` (see
[`../../references/config-schema.md`](../../references/config-schema.md)); if missing,
stop and tell the user to run `/bootstrap`.

Keys this skill uses:
- `config.repo` — GitHub `owner/name` for every `gh` call.
- `config.defaultBranch` — must be checked out and up to date before releasing.
- `config.commands.{test,build,lint,typecheck}` — pre-flight gate (skip any that are `null`).
- `config.paths.changelogDir` — if `daily-changelog` is in use, the per-day files since the last tag
  are ready-made raw material for the release notes.
- `config.release` — the structured release mechanics (see below). **If absent/`null`, stop and
  confirm**: the repo may not cut versioned releases.
  - `config.release.versionCommand` — how to bump, with `{level}` → `patch`|`minor`|`major`
    (e.g. `npm version {level}`). `null` → no scripted bump; you'll tag manually.
  - `config.release.versionPushesTag` — `true` if that command also commits, tags, and pushes
    (e.g. npm's `postversion` hook); `false` → this skill commits the version files, tags, and pushes.
  - `config.release.notesFile` — the changelog/notes file to update (e.g. `src/release-notes.json`,
    `CHANGELOG.md`); `null` → notes live only on the GitHub release.
  - `config.release.readmeSection` — a README heading to keep in sync (e.g. `What's New`); `null` → skip.
  - `config.release.githubRelease` — `true` to create/publish a GitHub release from the tag.
- `config.guidelines.release` — **the repo's release-specific gates and caveats.** Read it in full.
  This is where repo-specific, judgment-heavy rules live: a runtime/smoke gate that Node tests can't
  cover, dependency caveats, release-name formatting rules a registry enforces, artifact specifics.
  If it's missing or stubbed, note that in your report and run only the universal steps.

Treat any `null` command as "this repo has no such step — skip it."

## Workflow

### 1. Pre-flight: clean tree, right branch, up to date

```bash
git status --short                       # must be clean
git checkout <config.defaultBranch> && git pull
```

Dirty tree or behind remote → stop and report.

### 2. Gather ALL changes since the last release

**Build the notes from the complete set of changes since the previous tag — never just the current
session's work.** A release bundles everything merged since the last version, which is almost always
more than what you just touched.

```bash
LAST=$(gh release list --repo <config.repo> --limit 1 --json tagName --jq '.[0].tagName')
echo "since: $LAST"
git log --oneline "$LAST..HEAD"                                  # every commit since the last tag
gh pr list --repo <config.repo> --state merged --search "merged:>$(git log -1 --format=%cs $LAST)" \
  --json number,title,labels,url --limit 200                     # merged PRs since the tag
```

If `daily-changelog` is in use, the files in `config.paths.changelogDir` dated after `$LAST` are a
ready-made, already-triaged source — consolidate them instead of reconstructing from scratch.

**Triage**: include **user-facing** work (features, fixes, new settings/commands/UI, behavior,
localization); exclude internal churn (CI, dev tooling, test-only, skill/automation plumbing,
routine dependency bumps unless notable). Sanity check: your feature-bullet count should roughly
match the number of user-facing `feat:` PRs in the range — if you've only listed the few things you
personally touched, you've missed some.

### 3. Pick the version level

`patch` (bug fixes), `minor` (new features, backward-compatible), `major` (breaking changes), per
semver. Derive a default from the triaged changes (any breaking change → major; any feature → minor;
else patch) and confirm with the user.

### 4. Update the release notes

If `config.release.notesFile` is set, add the new version's entry there, built from the full change
list — match the existing file's structure and voice (title, highlights, details; mirror any emoji
convention already in the file). If `config.release.readmeSection` is set, sync that README section
to the new highlights and demote the prior version. If `notesFile` is `null`, draft the notes now for
the GitHub release body in step 8.

Heed any notes-rendering caveats documented in `config.guidelines.release` (e.g. an in-app modal that
shows only the exact released version's entry and doesn't roll up earlier ones).

### 5. Run the pre-flight checks

Run `config.commands.lint`, `config.commands.typecheck`, `config.commands.build`,
`config.commands.test` (skip `null`). All must pass. Prefer delegating to `create-pr`'s gate if
that's how the repo runs checks. No `--no-verify`.

### 6. Run the repo's final release gate — LAST, after everything else

If `config.guidelines.release` documents a release gate beyond unit tests (a runtime/smoke test, a
manual install-and-exercise step), **run it as the final step before bumping** — and understand *why
it's last*: build/unit tests run in a sandbox and can't catch failures that only appear in the real
runtime environment (renderer/CORS/native/packaged-artifact). 

**Ordering rule (portable):** the release gate is invalidated by *any* code or dependency change made
after it. If you change anything after the gate, re-run it. **Never bump a dependency after the
gate.** (This is a classic way releases break: gate passes, "minor" dep bump lands, release ships
untested.)

### 7. Commit the notes, then bump the version

```bash
git add <config.release.notesFile> README.md   # whatever step 4 touched
git commit -m "Add release notes for <version>"
```

Then bump using the repo's mechanism — **never hand-edit version numbers** in manifests:
- `config.release.versionCommand` set → run it with `{level}` substituted (e.g. `npm version minor`).
  If `config.release.versionPushesTag` is `true`, it already commits the version files, tags, and
  pushes — done. If `false`, commit the updated version files, then `git tag <version>` and
  `git push --follow-tags`.
- `config.release.versionCommand` is `null` → tag manually: `git tag <version> && git push origin <version>`.

### 8. Create / publish the GitHub release

Only if `config.release.githubRelease` is `true`. After the tag is on the remote:

```bash
gh release view <version> --repo <config.repo> 2>/dev/null   # did CI auto-create a draft?
```

- **Draft exists** (a CI workflow made it on tag push) → edit its body with the notes from step 4,
  set it as latest, and publish:
  `gh release edit <version> --repo <config.repo> --notes-file <notes.md> --latest --draft=false`
- **No draft** → create it: `gh release create <version> --repo <config.repo> --title "<title>" --notes-file <notes.md> --latest`

Apply any release-name formatting rule from `config.guidelines.release` (some registries require the
full `X.Y.Z` in the release title).

### 9. Verify

- The release appears on GitHub, marked **Latest**, tag matches the version.
- The bumped version files (manifest/package) on the default branch match the tag.
- Report: version cut, level, PR/commit count rolled in, release URL, and whether the repo's release
  gate was run (or skipped because `config.guidelines.release` didn't define one).

## Important rules

- **Notes before bump.** Always update release notes (step 4) before bumping the version (step 7).
- **Whole range, not the session.** Build notes from everything since the last tag (step 2).
- **Never hand-edit version numbers** in `package.json`/`manifest.json`/`pyproject.toml`/etc. — use
  `config.release.versionCommand` or a manual tag.
- **The release gate runs last and is invalidated by later changes** — re-run it; never bump deps
  after it (step 6).
- **On `config.defaultBranch`, clean and up to date, before starting.**
- **No `--no-verify`. Don't auto-publish a release the user hasn't seen the notes for** if they're
  in the loop — confirm the notes and version level first.
- **If `config.release` is absent/`null`, confirm before acting** — the repo may ship continuously.

## What not to do

- Don't cut a release from a dirty tree or a stale branch.
- Don't reconstruct notes from memory or only this session — gather the full range.
- Don't skip the repo's release gate when `config.guidelines.release` defines one.
- Don't bump a dependency after the gate without re-running it.
- Don't bake another repo's mechanics into the run — read them from `config.release` /
  `config.guidelines.release`. If a needed value is missing, ask rather than guess.
