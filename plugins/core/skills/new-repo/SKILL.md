---
name: new-repo
description: Create a new repo — or adopt an existing one — against a repo profile, so every repo in a fleet is set up the same way. Reads a profile JSON (the standard: merge methods, branch protection, required checks, labels, coverage policy, the files every repo carries), resolves this repo's effective values from `defaults` + its language block + its override, scaffolds every file the profile requires (`.claude/settings.json`, the CI workflow with the coverage-ratchet steps, PR template, CODEOWNERS, dependabot config, review rules, CLAUDE.md), runs `bootstrap` for `.claude/maintainerd.json`, creates the labels, and applies the GitHub settings with `gh api` — showing every call in full and running none of them without a human's confirmation. Idempotent: a no-op on a conformant repo, and on a partial one it reports what it would change and asks. Refuses the whole GitHub-mutating half in a non-interactive session. Use when the user asks to "create a new repo", "set up a repo to our standard", "adopt this repo into the standard", "apply the repo profile", or "onboard <repo> to the fleet". For checking an existing repo without changing anything, use `doctor --profile` instead.
---

# Create or adopt a repo against a profile

A fleet of repos configured by hand is a fleet of repos configured differently. This skill applies a
**repo profile** — one versioned JSON holding the standard — to one repo, so that the standard is a
file and applying it is a script.

The profile is an **argument**. This skill ships no standard, knows no org, and has no defaults of
its own: everything it writes comes out of the profile it was handed. The contract is in
[`../../references/profile-schema.md`](../../references/profile-schema.md); read it before you
resolve anything.

## The boundary

**Files are one half of this skill; GitHub settings are the other, and they are not the same risk.**

| Half | What it touches | Reversible by | Runs when |
| --- | --- | --- | --- |
| **Scaffold** | Files in a working tree, and nothing else | `git checkout` | Any session. Nothing is pushed; the human reviews the diff. |
| **Mutate** | The repo's existence, its labels, its merge methods, its branch protection, its merge queue | A person, by hand, hopefully before someone force-pushes `main` | **Only** an interactive session, with the operator's own token, after they have seen every call and said yes |

Branch protection and merge-method changes are org configuration with the blast radius of a
production write. The mutating half therefore belongs to a person at a keyboard, and this skill
**refuses it** — not degrades, refuses — anywhere else. `doctor --profile` is the read-only companion
and is report-only forever.

## Inputs

- `/new-repo --profile <path> --repo <owner/name> --language <key>` — create the repo and bring it
  to the standard.
- `/new-repo --adopt --profile <path> --repo <owner/name> --language <key>` — the repo already
  exists; bring it to the standard without creating it. This is the common case.
- `--dry-run` — resolve, compare, and print everything that *would* change, including every `gh api`
  call, and stop. Safe anywhere, including non-interactively; it is what to run first.

`--language` must be a key in the profile's `languages`. If the repo is listed in a workspace's
`workspace.repos`, take `--repo` and `--language` from that entry rather than asking.

## Workflow

### 1. Resolve the profile

```bash
plugins/core/scripts/profile-resolve.sh --profile <path> --repo <owner/name> --language <key>
```

Use the script; do not merge the layers by hand. The rules it implements — an explicit `null`
overriding while an absent key inherits, `requiredChecks` being additive and never subtractive,
objects merging at every depth — are exactly the ones that are easy to get subtly wrong in prose,
and getting them wrong here writes the wrong standard into a repo.

It **fails** on a profile whose shape is wrong, on a language block carrying a key that is fixed
org-wide, and on a language with no entry in the profile. All three are stops, not warnings. For an
unknown language, print the known keys and stop: the repo whose language the profile doesn't name is
exactly the repo that gets missed when the standard is applied.

Everything below reads the `effective` object this prints. Nothing below reads the profile directly.

### 2. Establish the mode, and the session

**Create vs adopt:**

```bash
gh repo view <owner/name> --json nameWithOwner,isPrivate,defaultBranchRef >/dev/null 2>&1
```

- Exists, and `--adopt` was passed → adopt.
- Exists, and it wasn't → **stop** and say so. Silently adopting a repo somebody asked you to create
  is how the wrong repo gets reconfigured. Re-run with `--adopt`.
- Doesn't exist, and `--adopt` was passed → **stop**. There is nothing to adopt; the user has the
  name wrong, or the token can't see it.
- Doesn't exist → create.

**Then decide whether the mutating half may run at all.** With `--dry-run`, skip this — the dry run
mutates nothing. Otherwise, check every one of these, and stop the mutating half if any holds:

```bash
printenv CI GITHUB_ACTIONS GITHUB_JOB GH_TOKEN GITHUB_TOKEN 2>/dev/null   # any set → not a human session
gh auth status                                                            # must be a user login
```

- `CI`, `GITHUB_ACTIONS` or `GITHUB_JOB` set → a scheduled or CI run. **Refuse.**
- `GH_TOKEN` or `GITHUB_TOKEN` set in the environment → an app, Actions or bot token rather than the
  operator's login. **Refuse**, naming the variable: the whole point is that the settings change is
  attributable to a person.
- `gh auth status` reports anything but a logged-in user account → **refuse**.
- You cannot ask a question (this session can't use `AskUserQuestion` — a headless or piped run) →
  **refuse**. A confirmation nobody saw is not a confirmation.

A refusal is not a failure: **do the scaffold half anyway**, print every `gh api` call the mutating
half would have run, and tell the user to re-run interactively (or paste the calls). That output is
useful; a half-applied standard is not.

### 3. Create the repo (create mode only)

Show the call, confirm, run it:

```bash
gh repo create <owner/name> --<private|public> --description "<one line the user gives you>"
```

`private` comes from the profile — don't ask, and don't infer it from the org's other repos. Then
clone it, make the initial commit on `<effective.defaultBranch>`, and push, so that there is a
default branch for protection to attach to. **Branch protection cannot be applied to a branch that
doesn't exist**, and the API's error for it is unhelpful; a repo with no commits is the commonest
reason a create run half-succeeds.

### 4. Scaffold the files

Work in a clean checkout, on a branch, and let the user review the diff — **never commit or push**.
Everything below is written **only if absent**; a file that already exists is left alone and reported
as a difference for the human to reconcile. A scaffolder that overwrites a maintainer's PR template
with a stub is a scaffolder people turn off.

| Written when | Path | Content |
| --- | --- | --- |
| `files.prTemplate` | `.github/PULL_REQUEST_TEMPLATE.md` | The minimal template from `bootstrap` step 7. |
| `files.codeowners` non-null | `.github/CODEOWNERS` | The profile's line, verbatim. This is the one file whose *content* the profile owns. |
| `files.greptileRules` | `.greptile/rules.md` | A stub with a header naming the repo. Content is the repo's to write. |
| `files.claudeMd` | `CLAUDE.md` | A stub: what the repo is, its architecture in a paragraph, and a pointer to the fleet's house rules. |
| `claudeSettings` present | `.claude/settings.json` | `extraKnownMarketplaces` for each entry in `claudeSettings.marketplaces`, `enabledPlugins` for each in `claudeSettings.plugins`. Merge into an existing file key by key; never replace one. |
| `dependabot` non-empty | `.github/dependabot.yml` | One `updates` entry per ecosystem, `directory: "/"`, `schedule.interval: weekly`. |
| always | `.github/workflows/ci.yml` | Below. |

**`.claude/settings.json` is the one file to merge rather than write.** It carries the user's own
permissions and hooks; replacing it to add a marketplace destroys work that has nothing to do with
the standard. Read it, add the missing entries, keep everything else, and show the diff.

### 5. The CI workflow

Scaffold **one** workflow, `.github/workflows/ci.yml`, with **one job whose key is `ci`** — the check
run's name is the job's, so this is what makes a required check called `ci` exist. It runs the
commands from `effective.commands`, in order, skipping every `null` one:

```yaml
name: ci
on:
  push:
    branches: [<defaultBranch>]
  pull_request:
permissions:
  contents: read
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      #   <language setup: actions/setup-python + uv, actions/setup-node + npm ci, …>
      - name: Format
        run: <commands.format>
      - name: Lint
        run: <commands.lint>
      - name: Typecheck
        run: <commands.typecheck>
      - name: Test
        run: <commands.test>
```

**When `effective.coverage` is not null**, append the four coverage-ratchet steps — and only then.
An exemption is the absence of a gate, not a floor of zero, so an exempt repo's workflow carries no
coverage step at all:

```yaml
      - name: Coverage
        run: <commands.coverage>
      - name: Normalize the coverage summary
        run: .claude/maintainerd/coverage-adapt.sh --tool <pytest-cov|istanbul>
      # Before the gate, so a regression still publishes the number that proves it.
      - name: Upload the coverage summary
        uses: actions/upload-artifact@v4
        with:
          name: coverage          # doctor's check 13 looks for this exact name
          path: coverage-summary.json
          if-no-files-found: error
      - name: Coverage ratchet
        run: .claude/maintainerd/coverage-check.sh
```

Those two scripts are **vendored into the repo by `bootstrap`** (step 6) — CI runs without the plugin
installed. Don't inline them, don't curl them.

**One job, not one per required check.** The profile carries the commands for exactly one pipeline,
so it can scaffold exactly one job. Every other effective check — `docs`, an invariants suite, a
migration guard — names a workflow **the repo already carries**; the profile is not where its
contents live. Step 7 is where an unproduced check is caught, and it is a stop, not a shrug.

### 6. Run `bootstrap`

`.claude/maintainerd.json` is `bootstrap`'s file, not this skill's — writing it here would be a
second generator of the same contract, drifting from the first. Run `/bootstrap` and seed its answers
from the effective profile:

- `defaultBranch`, `commands.*` — from the effective values, not from detection.
- `review` and `createPr.requireIssueForDeferredWork` — from the profile's `defaults`.
- `labels.*` — from the profile's label names, where they map onto config keys.
- Coverage: when `effective.coverage` is non-null, let `bootstrap` step 10 vendor the scripts and
  measure the floor on a fresh worktree of the default branch. When it is `null`, `commands.coverage`
  is `null` too (the resolver guarantees that), so step 10 skips itself and the repo is exempt.

On a brand-new empty repo the measurement has nothing to measure: `bootstrap` writes no floor and
says so, which is the honest "not yet adopted" state. Adopt the floor on the first real commit.

### 7. Verify every required check has a producer — before touching protection

**A required status check that nothing produces blocks every merge in the repo, forever, and looks
exactly like a correctly configured one.** So this is a gate, not a report:

```bash
# jobs in the default branch's workflows...
git show "origin/<defaultBranch>:.github/workflows/<file>.yml"
# ...and check runs that actually appeared on its latest commit
gh api "repos/<slug>/commits/<defaultBranch>/check-runs" --paginate --jq '.check_runs[].name'
```

Match against the **check-run name, which is per job**: a job's `name:` if it has one, else its key
under `jobs:`; a matrix job appears once per combination as `<name> (<values>)`; a job reached
through a reusable workflow reports under the *calling* job's name. A workflow file called `ci.yml`
produces no check called `ci` unless a job in it is called that.

- Every effective check has a producer → continue.
- Any check has none → **do not write protection.** Name the check, say what it would do (block
  every merge), and stop that step. Do the rest. A repo with correct merge methods and no protection
  is recoverable in one call; a repo nobody can merge to is an incident.
- The default branch has no runs yet (a repo created five minutes ago) → the check-run list is
  empty and proves nothing. Fall back to the workflow scan, and say plainly which checks you could
  only see statically.

### 8. Labels

```bash
gh api "repos/<slug>/labels" --paginate --jq '.[].name'    # --paginate: `gh label list` caps at 30
```

Create the ones the profile names and the repo lacks, on confirmation:

```bash
gh label create "<name>" --repo <slug> --color <hex> --description "<what applies it>"
```

**Labels the repo has and the profile doesn't are not drift.** Never delete one. A repo's own labels
are its business; the profile says what must exist, not what may.

### 9. Apply the GitHub settings

Compute the difference with the helper rather than by eye:

```bash
gh api "repos/<slug>"                                    > /tmp/repo.json
gh api "repos/<slug>/branches/<branch>/protection"       > /tmp/prot.json   # 404 body is fine
gh api "repos/<slug>/rulesets?includes_parents=true"      # then each by id, with its rules
gh api "repos/<slug>/labels" --paginate --jq '[.[].name]' > /tmp/labels.json

plugins/core/scripts/settings-diff.sh --repo <slug> --effective /tmp/eff.json \
  --repo-settings /tmp/repo.json --protection /tmp/prot.json --rulesets /tmp/rules.json --labels /tmp/labels.json
```

Then, in this order:

1. **Print every call, in full, before running any of them.** Not a summary. The operator is
   approving the calls, so the calls are what they read.
2. **Ask once, for the batch**, with the count and the blast radius named ("this changes branch
   protection on `main` in `my-org/app`"). One question, not one per call — a per-call prompt trains
   people to click yes.
3. **Run them in the safe order**: repo settings, then labels, then protection, then the merge-queue
   ruleset. Protection last of the three that can lock people out, so a failure part-way leaves the
   repo *less* protected rather than protected against a check that doesn't exist yet.
4. **Branch protection is a PUT that replaces the whole object.** Send the complete desired state —
   the one body `settings-diff.sh` prints — never the diverging key alone, which clears every key it
   omits. If the repo currently requires a check the profile doesn't name, that PUT removes it: say
   so before asking, and let the operator add it to the profile instead if it should stay.
5. **A failed call stops the batch.** Report what succeeded, what didn't, and the exact call to
   retry. Never retry a settings write in a loop.

If `settings-diff.sh` reports **couldn't verify** for a section (the read needed admin and the token
doesn't have it), do not apply that section blind. A write computed from a failed read is a guess.

### 10. Idempotence

Re-running this skill on a conformant repo must do **nothing** and say so in one line. That is what
makes it safe to run on a schedule, and safe to run when you're not sure whether someone already did.

On a partially conformant repo — the common case for `--adopt` — **report what would change and
ask**, per section: files to add, labels to create, settings to change. Never a blanket "make it
conform". The user gets to decline the settings and take the files, which is exactly what somebody
adopting a repo they don't own needs.

### 11. Report

- The profile path, its `profileVersion`, the resolved language and the override key that applied
  (or that none did).
- Files written, files left alone because they already existed, files skipped because the profile
  didn't ask for them.
- The coverage decision: the floor measured, or exempt, or not yet adoptable.
- Labels created.
- Settings: applied (with the calls), refused (with why, and the calls to paste), or already
  conformant.
- **Anything that stopped**: an unproduced required check, a section that couldn't be read, a file
  whose existing content differs from the profile's.
- The reminder to review and commit the diff. This skill doesn't commit.

## What not to do

- **Don't apply GitHub settings non-interactively.** Not with a flag, not "just the safe ones", not
  because the run is scheduled and nobody is watching. Print the calls and stop.
- **Don't apply a settings change the operator hasn't read.** The calls are the thing being
  approved.
- **Don't PATCH branch protection one key at a time.** The endpoint is a PUT that replaces the whole
  object; a partial body clears the rest.
- **Don't write a required check into protection without a producer.** It blocks every merge in the
  repo forever, and the failure appears on somebody else's PR, not on this run.
- **Don't overwrite a file that exists** — templates, `CLAUDE.md`, `.greptile/rules.md`,
  `.coderabbit.yaml`, and above all `.claude/settings.json`, which carries the user's own permissions.
  Merge or report; never replace.
- **Don't delete labels, branch rules, or workflows the profile doesn't mention.** The profile says
  what must exist. Absence from it is not a verdict.
- **Don't invent profile values.** No key means no opinion: report it as unspecified rather than
  filling in a plausible default. A standard nobody wrote is not a standard.
- **Don't re-implement the merge.** `profile-resolve.sh` is the resolver; a second copy of those
  rules in prose is a second set of rules.
- **Don't commit or push.** Write the files, print the calls, let the human review.
