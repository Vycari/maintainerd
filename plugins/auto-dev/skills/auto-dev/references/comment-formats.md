# Issue comment formats

The three comment templates step 4's triage pass posts. Read this file when about to post one.
The fallback review's PR comment format lives in `fallback-review.md`.

The literal `<!-- auto-dev -->` lines below stand in for `config.autoDev.marker` — emit the repo's
configured marker as the first line of every comment.

## Plan comment

```markdown
<!-- auto-dev -->

## Proposed implementation plan

**Approach:** <2–4 sentences: what will change and why this approach>

**Changes:**

- `path/to/file.ext` — <what>
- <new files, tests, docs to update>

**Testing:** <unit tests to add/extend; manual verification if UI>

**Out of scope:** <explicitly excluded, if anything notable>

---

Reply with an approval ("approved", "LGTM", "go ahead") to queue this for implementation, reply with changes to revise the plan, or add the Skip label to opt this issue out of automation.
```

Plans follow the repo's "Implementation Planning" convention (plans live in the issue). Keep them
honest about size — if an issue is too large to land as one reviewable PR, the plan should say so and
propose the first slice only.

## Question comment

```markdown
<!-- auto-dev -->

Before this can be planned for implementation, a few things need clarification:

1. <specific question>
2. <specific question>

---

Reply here and the next automation pass will pick it up, or add the Skip label to opt this issue out of automation.
```

## Park proposal comment

Use this when an issue can't move forward because it needs a maintainer decision the skill can't
make — not missing facts, but a judgement call, a design fork, or a dependency on other work. It
**proposes** parking and waits; it never parks on its own.

```markdown
<!-- auto-dev -->

This isn't blocked on missing detail — it's waiting on a call that's yours to make:

<1–3 sentences naming the blocker: the design fork, the open dependency, or why the issue reads as deferred>

Want me to **park** it for now? Reply "park it" (or add the Parked label) and I'll leave it untouched until you remove the label or add more detail to the issue. If you'd rather move it forward, here's what would unblock it: <the specific decision or input needed>.
```

A parked issue is durable rest, not abandonment: the skill picks it back up the moment the maintainer
removes the Parked label or adds a comment _after_ the park (a rationale left at park time is
recorded but does not re-activate it — see the Parked branch in `triage.md`).
