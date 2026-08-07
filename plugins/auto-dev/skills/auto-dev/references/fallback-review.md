# Fallback self-review

The pipeline's own review of a PR it wrote, used only when no external review arrives. Step 2 checks
a compact form of the qualifying conditions inline; **read this file before performing the review** —
it carries the exact condition semantics, the procedure, and the comment format.

## Why it exists

CodeRabbit normally reviews within minutes of a PR going ready; when it hits its rate limits it stays
silent or posts only a rate-limit/"in queue" notice, and the PR would otherwise sit with no review
signal at all, blocking the maintainer's merge decision. The pipeline reviews its own PR to fill that
gap.

## Qualifying conditions

A PR qualifies when **all** of these hold:

- it is ready (not draft) and CI is green;
- it has **no review activity from any human or third-party bot** — no reviews, no inline review
  comments. A CodeRabbit rate-limit notice does _not_ count as review activity: it arrives as an
  **issue-style comment** (not a review) whose body contains the line
  `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->`, and it often quotes a
  short "next review available in N minutes" — `config.autoDev.fallbackReviewMinutes` (default 60)
  deliberately overshoots those short waits, giving CodeRabbit several chances first;
- it has been ready for review longer than `config.autoDev.fallbackReviewMinutes` (from the PR's
  `createdAt`, or the latest `ready_for_review` timeline event if it started as a draft);
- it has no prior fallback self-review — no marker comment containing the `## Fallback review`
  heading. **At most one fallback self-review per PR**; that comment is the cross-tick memory.

## The review

1. **Fresh-eyes adversarial review.** The pipeline wrote this diff, so don't trust the memory of
   writing it — re-read the full diff from scratch (`gh pr diff`) against the approved plan on the
   issue. **If the repo's `code-review` skill is installed, apply its standards**; otherwise review
   for correctness, error handling, edge cases, test coverage and quality, the repo's documentation
   policy, and the rules in `config.guidelines`. Actively look for reasons the change is wrong, not
   confirmation that it's right.
2. **Fix what's real.** Valid findings get fixed now, in this tick: check out the automated branch,
   focused commits (one logical fix per commit), full pre-flight (`config.commands.*` — skip any
   whose value is `null`), push.
3. **Post one summary comment** in the format below: what was examined, findings fixed (with commit
   SHAs), and observations left to the maintainer's judgement. "No findings" is a valid, useful
   outcome — say it plainly rather than inventing nitpicks.
4. **Never submit a formal GitHub review** — no approval, no request-changes, not even a
   comment-type review. The summary is an ordinary PR comment. A self-review is a signal for the
   maintainer, not independent sign-off, and must never be dressed up to look like one.

After the fallback review is posted, the PR counts as quiescent. If CodeRabbit later catches up and
reviews the PR, its feedback flows through the normal item-3 handling — the fallback review never
suppresses or substitutes for a real external review.

## Re-triggering CodeRabbit

Its rate-limit notice offers two re-triggers: pushing new commits, or a `@coderabbitai review`
comment. The fallback review's own fix-push therefore doubles as a re-trigger — desirable, since a
real external review may follow. But **never post the `@coderabbitai review` trigger yourself**: a
bare command comment from the maintainer's account without the marker would be classified by every
later tick as human input (invariant 3), while adding the marker may break CodeRabbit's command
parsing. The fallback summary instead reminds the maintainer they can trigger it manually.

## Comment format

The `## Fallback review` heading is load-bearing — it is how later ticks detect that a fallback
review already exists — so keep it verbatim. The first line is `config.autoDev.marker` (the literal
`<!-- auto-dev -->` below stands in for the repo's configured marker).

```markdown
<!-- auto-dev -->

## Fallback review

No external review arrived within the review window (CodeRabbit appears rate-limited), so this is the pipeline's own fresh-eyes review of the diff against the approved plan. It is a **self-review** — treat it as a signal, not independent sign-off.

**Examined:** <scope: files/areas reviewed, and what they were checked against>

**Fixed in this review:**

- <finding> — fixed in <sha>
- _(or "nothing — no defects found")_

**For your judgement:**

- <observation or trade-off the maintainer should weigh before merging>
- _(or "nothing flagged")_

---

CodeRabbit can be re-run on this PR at any time with a `@coderabbitai review` comment.
```
