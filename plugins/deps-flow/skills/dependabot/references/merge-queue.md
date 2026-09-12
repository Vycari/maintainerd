# Merging on a branch that requires a merge queue

Read this before merging anything. It is the one place where invariant 2 does **not** simply say
"no `--auto`", and the conditions on that are narrow.

A repository ruleset can attach a **merge queue** rule to a branch. On such a branch GitHub does not
let anyone merge a PR directly — `gh pr merge --squash` is refused — because the queue exists
precisely to rebuild every candidate against the batched base before it lands. The only way in is
`gh pr merge --auto`, which *enqueues* the PR. So on those branches the choice is not "arm
auto-merge or merge normally"; it is "arm auto-merge or never merge here at all".

What makes arming safe is the head pin, not the queue. `--match-head-commit <sha>` tells GitHub to
drop the request the moment the head moves, so a Dependabot force-push between the gate and the
queue disarms the standing instruction instead of riding it. **An `--auto` without a head pin is
still banned everywhere, queue or no queue** — that is the unattended merge of a commit this skill
never looked at, which is what invariant 2 is about.

## Step A — Detect the queue (once per pass, per base branch)

A merge queue reaches a branch by **two** mechanisms, and a branch that has one may well not have
the other. Ask both, in this order, and stop at the first that answers "queue".

**A1 — the rules API (rulesets).** Ask GitHub for the rules that are **in effect** on the PR's base
branch. This endpoint evaluates every ruleset's conditions for you, which is why it is the right read
rather than listing rulesets and matching branch patterns by hand:

```bash
# $BASE is config.defaultBranch. A branch name containing "/" must be URL-encoded.
gh api "repos/$REPO/rules/branches/$BASE" \
  --jq '[.[] | select(.type == "merge_queue") | .parameters]'
```

A **non-empty** array → this branch requires a merge queue. Keep `parameters.merge_method`
(`"SQUASH"` \| `"MERGE"` \| `"REBASE"`) as the method to assert in step B, and `grouping_strategy`
for the report.

**A2 — the GraphQL `mergeQueue` field (legacy branch protection).** An empty array from A1 is **not**
proof there is no queue: a queue enabled through classic branch protection rather than a ruleset does
not appear there at all — `rules/branches/<branch>` returns `[]` and the repo may list no rulesets —
while the branch still refuses every direct merge. So when A1 comes back empty, ask the branch
itself:

```bash
gh api graphql -f query='
  query($owner:String!, $name:String!, $branch:String!) {
    repository(owner:$owner, name:$name) {
      mergeQueue(branch:$branch) {
        id
        configuration { mergeMethod mergingStrategy maximumEntriesToBuild }
      }
    }
  }' -F owner=<owner> -F name=<name> -F branch="$BASE" \
  --jq '.data.repository.mergeQueue'
```

A **non-null** `mergeQueue` → this branch has a queue. Here `configuration.mergeMethod` (same
`SQUASH`/`MERGE`/`REBASE` vocabulary) is the method to assert in step B, and `mergingStrategy` is the
grouping to report. A **null** result → no queue from this source either.

**Resolving the two.** Either source saying "queue" means queue; only both saying "no" means no. They
describe the same server-side gate, so they do not disagree about the method in practice — if they
somehow did, treat it as the step-B mismatch case and merge nothing on that branch this pass rather
than picking a winner.

**Fail closed on error.** A non-zero exit, a 403/404, a GraphQL `errors` block, output you cannot
parse — from *either* source — is "no queue" for that source, and "no queue" from both is the old
outright ban on `--auto`. The worst case is a direct merge that GitHub refuses on a queued branch,
which is a clean recorded refusal and costs one pass. The opposite default would arm an unattended
merge because an API call was flaky, which is the failure this whole document exists to prevent. Say
in the exit report that detection failed, which source failed, and what the error was.

Detect per pass. A ruleset or a branch-protection setting can be added or removed between ticks, and
a cached answer is exactly how a stale "no queue" would turn into an unexplained refusal every pass
(or worse, the other way).

## Step B — The method must match

The queue merges with **its own** method, not the one passed on the command line. Compare
`config.depsFlow.mergeMethod` with whichever source answered in step A —
`parameters.merge_method` (A1) or `configuration.mergeMethod` (A2) — **case-insensitively**: the
config value is lowercase (`"squash"`) and both APIs' are uppercase (`"SQUASH"`), and those two
*agree*. If they name different methods, **merge nothing on that branch this pass** and report the
exact mismatch, both values as they were read:

```text
merge-queue method mismatch: depsFlow.mergeMethod "rebase" vs queue merge_method "SQUASH" — merging nothing
```

Do not "helpfully" switch to the queue's method. The configured method is the maintainer's stated
intent for how dependency updates land in the history; a silent substitution is a config drift that
nobody would ever see. One line in the report, and a human fixes one of the two values.

## Step C — Arm the merge

Everything else in the gate is unchanged — same conditions, same immediately-before-merging re-run,
same `headRefOid`. Only the final call differs:

```bash
gh pr merge <N> --repo "$REPO" --squash --auto \
  --match-head-commit "<the headRefOid the gate validated>"
# --squash | --merge | --rebase per config.depsFlow.mergeMethod, which Step B proved matches
```

Still no `--admin`. A refusal is still a normal outcome to record, not something to route around.

**"Done" here means enqueued, not merged.** The pass does not wait for the queue, does not poll it,
and does not re-check it before exiting. The queue is a supervisor with its own schedule: it batches
entries, re-runs the required checks against the speculative merge, and evicts an entry whose batch
goes red. Duplicating that wait inside a metered run buys nothing, and holding a run open for it is
how a tick turns into an hour.

**An enqueued PR counts against `config.depsFlow.maxMergesPerRun`,** at the pass that armed it. The
cap bounds what one run sets in motion, and a PR handed to the queue is in motion. (The corollary:
if the queue later evicts it and a subsequent pass re-arms it, it consumes a slot in that run's cap
too. That is correct — each arming is its own act on its own gate.)

## Step D — Serialization moves to the queue

The "one PR per disjoint file group per pass" rule exists because merging one lockfile bump
invalidates its neighbours. With a queue, the base does not move when the PR is enqueued — it moves
when the queue reports it merged, which may be several minutes and one batch later. Until then an
overlapping neighbour still looks `CLEAN` against the old base, and arming it too would put both
lockfile bumps in one batch, fail the batch, and evict both.

So the rule extends **across** passes: **do not arm another PR in a file group that already has a PR
enqueued and not yet merged.** Such a neighbour is `waiting`, not `mergeable` — it is not stale, it
has nothing to nudge, and it is not the queue's problem yet.

Read the queue state per PR:

```bash
gh pr view <N> --repo "$REPO" --json number,autoMergeRequest,mergeQueueEntry
```

If the local `gh` does not know the `mergeQueueEntry` field, ask GraphQL directly:

```bash
gh api graphql -f query='
  query($owner:String!, $name:String!, $number:Int!) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$number) { mergeQueueEntry { state position } }
    }
  }' -F owner=<owner> -F name=<name> -F number=<N>
```

Any entry at all — `QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, `UNMERGEABLE`, `LOCKED` — occupies the
group. **A state you could not read also occupies it**: "I don't know" is not "free" (invariant 8).
A PR that is merged has no entry and has moved the base, which is the signal the next pass acts on.

## Step E — Nothing is left armed

Arming is a standing instruction, so a pass owns every arming it creates and every one it finds.

**At the end of the pass**, re-read each PR this pass armed. If it has no queue entry, the arming did
not take (the head moved, the gate stopped holding, the queue refused it). **Disarm it:**

```bash
gh pr merge <N> --repo "$REPO" --disable-auto
```

Then treat it as **stale** — the ordinary rebase-nudge path, which the next pass re-gates from
scratch. Never leave the pass with a PR armed and not enqueued.

**At the start of the pass**, do the same sweep over the whole candidate set, for the armings a
previous pass could not clean up: a run that was killed mid-pass, or — the case that matters — a PR
the queue **evicted** because its batch went red. GitHub leaves auto-merge armed after an eviction,
so that PR would re-enqueue on its own the next time it looked eligible, which is *exactly* the
"merged later under conditions nobody evaluated" outcome invariant 2 forbids. Any bot PR with
`autoMergeRequest` set and no `mergeQueueEntry` is disarmed and re-gated from scratch, whoever armed
it.

A PR with `autoMergeRequest` set **and** a live entry is mid-flight and correct: leave it alone,
count it as occupying its file group (Step D), and report it.

## What the queue does not change

- The gate. Every condition still has to pass, and it is still re-run immediately before arming.
- Invariant 4. The queue running the repo's tests against the speculative merge is CI doing that on
  CI's machine — it is never a reason for this skill to run a dependency's code.
- Invariant 1. A queue that evicts a PR has refused it. Re-gate next pass; never re-arm harder.
- Honesty. `enqueued` is reported as enqueued, never as merged. The pass that sees it merged is the
  one that says so.
