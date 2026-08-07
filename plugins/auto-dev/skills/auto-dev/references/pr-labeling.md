# Labeling automated PRs

Why the pipeline labels every PR it opens with `config.autoDev.prLabel` (default `auto:pr`), why the
timing matters, and what to do when the label is missing. The operational rules live in SKILL.md
(step 3 item 7 applies it at creation; step 0 re-stamps any that slipped through) — this file is the
reasoning behind them, needed only when something about the label goes wrong.

## What the label is for

**Every** PR the pipeline opens carries it — the complete build in step 3 item 7, a yielded WIP
draft, and any PR opened by delegating to `create-pr`. There is no path that opens a PR without it.

The label is what lets the maintainer configure external review tooling to stand down on automated
PRs (CodeRabbit's `reviews.auto_review.labels` takes negative matches, e.g. `["!auto:pr"]`) and
leave them to this pipeline's own review loop.

Note that the label is *only* for external tooling: the pipeline still identifies its own PRs by
`config.autoDev.branchPrefix` (step 0), so a missing label never confuses the state machine — it
just leaks a PR past the maintainer's tooling config.

## Apply it at creation, not afterwards

External tooling reacts to the `opened` webhook within seconds, and a label added after the fact
does not retract a review that already started. So pass it on the create call:

```bash
gh pr create --repo <config.repo> --base <config.defaultBranch> \
  --label "<config.autoDev.prLabel>" [--draft] --title "…" --body "…"
```

When delegating to `create-pr`, tell it to apply `config.autoDev.prLabel` on the `gh pr create`
call — it accepts caller-supplied labels for exactly this reason. Only fall back to
`gh pr edit <PR> --repo <config.repo> --add-label "<config.autoDev.prLabel>"` if a PR somehow got
opened without it.

## If the label doesn't exist

`gh pr create --label` fails — and on some `gh` versions it fails *after* pushing the branch,
leaving no PR. Don't risk losing the build: confirm the label exists before the first create, with
one `gh api "repos/<config.repo>/labels" --paginate --jq '.[].name'` (`--paginate`, not
`gh label list`, whose 30-item default would report an existing label as missing). A tick opens at
most a few PRs, so that single call covers all of them. If it's missing, open the PR **without** the
label and record in the exit report that the PR is unlabeled and why. Never create the label
yourself (invariant 5) — `/doctor` reports it, `/bootstrap` creates it.

### Why proceed unlabeled rather than refuse to open the PR?

Because refusing strands the build. The commits are already pushed, and a bare pushed branch is
invisible to the next tick — its discovery queries only look at PRs and issues. So a tick that
stopped here would leave the work unreachable, and the following tick would reclaim the issue as an
orphan and rebuild it from scratch, repeating for as long as the label is absent. The pipeline can't
fix the cause itself (invariant 5 forbids creating labels), so the stop would persist until a human
intervened, with each tick discarding a build.

The unlabeled PR is the strictly better failure: the work survives, the exit report names the
problem, `/doctor` FAILs on the missing label, and step 0's re-stamp labels the PR on the first tick
after the label exists. The only cost is that external tooling may review that one PR — which is
simply the behavior from before this label existed, not a regression.

## Why step 0 re-stamps every tick

The label is what lets external tooling skip these PRs, so a PR that missed it is a PR that gets
reviewed by tooling that was configured to leave it alone. Applying the label can miss for ordinary
reasons — the label didn't exist when the PR was opened, a transient `gh` failure, a PR opened by a
delegated skill — and nothing else would ever fix it.

So step 0 re-stamps on **every** tick, using the `labels` already fetched in its discovery queries
(no extra API call). This is a cheap no-op on the normal path, where every open automated PR already
carries the label. It is a **repair**, not the primary application — the primary application happens
at PR-creation time, because a label added minutes later doesn't retract a review that external
tooling already started. If the edit fails because the label doesn't exist, note it once in the exit
report and continue.
