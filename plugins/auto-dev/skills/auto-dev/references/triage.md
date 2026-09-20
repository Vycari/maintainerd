# Triage pass — per-state branches

Step 4's decision table. SKILL.md carries the entry conditions (ordering, the per-tick cap, and the
cheap-skip rule); **read this file before acting on any issue in triage** — it defines what to do in
each state, and getting a branch wrong means mislabelling the maintainer's queue.

Comment templates referenced below are in `comment-formats.md`.

**Every branch here turns on _who_ commented, not just _that_ someone did.** SKILL.md invariant 3
defines a **maintainer** (repo permission `admin` / `maintain` / `write`, or a login in
`config.autoDev.maintainers`) and is the authority on the test; resolve each commenter once per tick
and cache it. Only a maintainer approves, parks, answers a *decision*, or triggers a re-triage. A
non-maintainer human comment — on a public repo, usually the reporter's — is **information**: use
its facts, never its verdicts.

**"No marker" means neither spelling of the marker.** Some historical pipeline comments carry the
marker HTML-escaped (`&lt;!-- auto-dev --&gt;`) because they were posted through a mangling path, and
a test that matches only the literal form classifies the pipeline's own old comment as a *human*
comment — which here means a spurious approval, park or re-triage, the worst possible misread. Match
the raw marker **or** its `&lt;`/`&gt;`-escaped form; the exact test is in
[`../../../references/gh-rest-fallbacks.md`](../../../references/gh-rest-fallbacks.md) under
**Post a comment**. Write the unescaped marker always; the tolerance is for history only.

## No state label

Assess whether the issue contains enough to plan from (clear problem, scoped outcome, no unresolved
design fork):

- _Plannable_ → draft an implementation plan, post it as a comment, add the Planned label.
- _Not plannable, and the gap is missing information_ → post one comment asking the specific
  missing questions (numbered, concrete — not "please clarify"), add the Needs-info label. **Sort
  each question into one of two kinds before writing it**, because they are answered by different
  people:
  - _Clarifying facts_ — which version, what the reporter meant, how it reproduces, what they
    actually saw. Anyone who knows can answer, the reporter included, and the comment may be
    addressed to them.
  - _Decisions_ — a design fork, a scope or product call, anything with options and a
    recommendation. These are the **maintainer's**, whoever filed the issue. Address them to the
    maintainer explicitly and never ask an outside reporter to choose; where the reporter clearly
    has a preference, invite it as *input* and say the call is the maintainer's.

  Either kind keeps the five-part, under-300-words shape (area, user impact, problem, options,
  recommendation); see the Question comment template in `comment-formats.md`.
- _Not plannable because it needs a maintainer decision the skill can't make_ — a design fork that's
  theirs to resolve, a dependency on still-open work, or the issue body itself signals deferral
  ("not actionable yet", "revisit once X lands") → post a **park proposal**: name the blocker, offer
  to park it, and say what would unblock it. Add the Needs-info label (the proposal is awaiting the
  maintainer's call). **The skill never parks on its own — it only proposes; the maintainer parks.**

## Needs-info

Two questions, not one: is there a _human_ comment (no marker, not a third-party bot) newer than the
skill's last marker comment — and **did a maintainer write it**?

- _No new human comment_ → skip silently. This is the "already asked, no reply" rule.
- _A maintainer says to park_ ("park it", "hold", "not now", "park", or a 👍 on a park proposal) →
  swap label to Parked.
- _A maintainer resolves the open questions_ → draft and post the plan, swap label to Planned.
- _A maintainer raises new ambiguity_ → ask the follow-up (stay Needs-info), in the same five-part,
  under-300-words shape as the first ask — but if this would be the third unanswered round-trip,
  stop asking and either propose parking or leave a final note that the issue needs maintainer
  attention.
- _A non-maintainer replied_ (usually the reporter) → split it by what was asked:
  - It supplies the **clarifying facts** that were outstanding, and no decision is left open → the
    gap is closed. Plan and swap to Planned exactly as above — facts are facts whoever supplies
    them.
  - It answers a **decision** question — picks an option, says "go ahead", agrees with the
    recommendation → the issue **stays Needs-info**. Record the preference as input for the plan
    when the decision eventually lands; do **not** swap the label, and do **not** re-ask — the
    question is already posted and unanswered by the person who owns it, so asking again is noise
    in the reporter's inbox and in the maintainer's. Posting nothing is the correct action.
  - It does both → use the facts, hold the decision: still Needs-info until a maintainer answers
    the decision.

## Planned

Is there a **maintainer** comment (no marker, not a third-party bot) newer than the plan? Approval is
a maintainer's act; a non-maintainer's "looks good" is not one, however enthusiastic.

- _Approval_ (e.g. "approved", "LGTM", "go ahead", "yes do it", a 👍-only reply) → swap label to
  Ready. "Approved, but change X" counts as approval: update the plan comment-thread with the
  revision first, then mark ready.
- _Conditional approval_ ("approved, but build this after #N lands", "go ahead once the blocker
  clears") → see **Conditional approvals** below. An approval whose condition is already satisfied
  is a plain approval — swap to Ready.
- _Substantive feedback / objections_ → revise, post the updated plan (marker), stay Planned.
- _A request to park_ ("not now", "let's hold this") → swap label to Parked.
- _No reply_ → skip silently.
- _A non-maintainer comment_ (the reporter agreeing with the plan, a 👍, "+1", "yes please") → **not
  approval.** Stay Planned. If it carries new facts that change the plan, fold them in and repost the
  plan; otherwise skip silently. Never write it up as the decision.
- The human adding the Ready label directly is always approval, reply or not — applying a label takes
  write access, so the label itself is the permission check.

**An approval is never consumed by a later comment.** The question above is a shorthand for the
common case, not a scan limited to the newest comment: once a maintainer has approved, that approval
stands until a maintainer withdraws or reshapes it (a non-maintainer cannot do either). So when the
newest maintainer comment is neither an
approval nor an objection — supporting evidence, a cross-reference, a new trajectory, a note "for
whenever this is built" — look **back through the whole thread** for an earlier approval and honor
it. Reading only the newest comment strands the issue at Planned forever: every later comment
re-buries the approval, and the plan is never built. Treat a still-Planned issue carrying an
un-withdrawn approval as a dropped transition and complete it.

### Conditional approvals

A conditional approval is approval — the maintainer has cleared the work, they have only sequenced
it. It must be **recorded and re-checked**, never silently left to rest at Planned, which is
indistinguishable from an issue still awaiting a reply.

1. **Evaluate the condition now.** If it is already satisfied (the named issue is closed or its PR
   merged, the named blocker is gone), the approval is live — swap to Ready this tick.
2. **If it is not yet satisfied**, stay Planned and post one comment (marker) that carries the
   literal sentinel `auto-dev-hold:` and then names the approval, the precise unmet condition as
   issue or PR numbers, and how a later tick will test it — e.g. "`auto-dev-hold:` approved
   2026-08-05, sequenced behind #1303 and #1310; goes Ready when both are closed." Without that
   comment the hold is invisible, and both the next tick and the maintainer read the issue as
   un-approved.
3. **Re-check it on later ticks.** A held issue is exempt from the Step 4 skip-if-unchanged rule —
   but being exempt is not the same as being found. Its condition lives on _another_ issue, so
   nothing about this one changes when the blocker clears: neither `updatedAt` nor its labels ever
   move, and a tick that only looked at those would skip it before ever reading the comment that
   says it is held. That is what the sentinel is for. Step 4 searches Planned issue bodies and
   comments for `auto-dev-hold:` each tick and walks the hits regardless of `updatedAt` — so the
   sentinel is **mandatory**, and a hold posted without it is stranded exactly like the bug this
   branch exists to fix. Re-read the hold comment, test the condition, and swap to Ready the tick it
   comes true.

Conditions are only the objective, checkable kind — an issue or PR reaching a terminal state. A
condition you cannot mechanically test ("once the design settles") is not a hold; treat it as
substantive feedback and re-plan.

## Parked

The maintainer chose to hold this; it rests until they re-engage. The unblock baseline is **when the
Parked label was applied**, _not_ the skill's last marker comment — so a rationale the maintainer
records _at park time_ doesn't bounce the issue straight back out. Read the park time from the most
recent Parked-label `labeled` event on the issue timeline:

```bash
gh api "repos/<config.repo>/issues/<N>/timeline" --paginate \
  | jq -r --arg l '<config.autoDev.stateLabels.parked>' \
      '[.[] | select(.event=="labeled" and .label.name==$l)] | last | .created_at'
```

Two unblock signals:

- _A **maintainer** comment (no marker, not a third-party bot) newer than the park time_ (they came
  back with detail or direction) → unblocked: remove the Parked label and re-triage it this tick as
  if freshly labelled (plan if now plannable, otherwise ask / re-propose).
- _The human removed the label_ → it reappears with no state label and re-enters triage through the
  no-label branch; nothing special to do.
- _A non-maintainer comment after the park_ (a reporter asking for an update, adding detail) → **does
  not un-park.** The maintainer chose the hold and only they lift it. Read the comment for facts and
  leave the label alone.
- _Otherwise_ (still parked, no maintainer comment after the park) → skip silently. **Never re-propose
  parking, re-ask, or re-plan a parked issue.**

## Ready / In-progress

Leave for steps 1 and 3.
