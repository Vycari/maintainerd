# Issue comment formats

The three comment templates step 4's triage pass posts. Read this file when about to post one.
The fallback review's PR comment format lives in `fallback-review.md`.

The literal `<!-- auto-dev -->` lines below stand in for `config.autoDev.marker` — emit the repo's
configured marker as the first line of every comment.

**Know who you are writing to.** Only a **maintainer** decides (SKILL.md invariant 3: repo permission
`admin` / `maintain` / `write`, or a login in `config.autoDev.maintainers`). On a public repo the
issue's author usually is not one. A comment may ask *anyone* for clarifying facts; a comment that
asks for a **decision** is addressed to the maintainer, and says so.

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

**Never open a plan by crediting a non-maintainer with the decision.** "@someone picked Option A on
both questions" reads as a settled call and quietly promotes a bystander to decision-maker — it is
the bug this rule exists to prevent. Where a non-maintainer stated a preference, record it as input
and keep the call open:

```markdown
The reporter prefers **A** on both questions; I'd recommend **A** as well. The choice and the
approval are the maintainer's — reply with an approval to queue this, or name a different option.
```

A decision a maintainer actually made is quoted as the decision, as ever ("approved A on 09-08").

## Question comment

Two kinds of question, one shape. Sort each one before you write it — the shapes differ only in who
is asked, but that difference is the whole point:

- **Clarifying facts** — which version, what the reporter meant, how it reproduces, what they saw.
  Whoever knows can answer; on a reporter-filed issue this comment is addressed to the reporter.
- **Decisions** — a design fork, a scope or product call, anything with options and a
  recommendation. **Addressed to the maintainer**, whoever filed the issue.

Never mix the two openers: a comment that asks an outside reporter to pick between product options
hands them a call that isn't theirs, and their answer then reads like the decision on the record.
When both are outstanding, ask the facts of the reporter and the decision of the maintainer — in
separate sections of the same comment, each labelled with who it is for.

Either way a question is answered **in one read** — not a request for an essay in reply. Keep every
question under **300 words** including its options, and give it exactly these five parts:

- **Area** — where the problem shows up (file, command, skill, subsystem).
- **Impact** — what a user experiences because of it; skip if genuinely user-invisible and say so.
- **Problem** — the ambiguity itself, 1–2 sentences.
- **Options** — the real choices, one line each with its tradeoff. Two or three; if there is only
  one real option this isn't a question, it's a plan.
- **Recommendation** — which one you'd take and why, one sentence.

**Decision comment** (the maintainer's call):

```markdown
<!-- auto-dev -->

**For the maintainer:** before this can be planned for implementation, a few decisions need a call
from someone with write access on this repo.

### 1. <short title of the decision>

**Area:** <file / command / subsystem>
**Impact:** <what a user sees or loses>
**Problem:** <the ambiguity, 1–2 sentences>
**Options:**

- **A** — <option> (<tradeoff>)
- **B** — <option> (<tradeoff>)

**Recommendation:** A — <one sentence why>

### 2. <short title of the decision>

<same five parts>

---

A maintainer's reply is what the next automation pass acts on, or add the Skip label to opt this
issue out of automation.
```

When the issue's author is **not** a maintainer, add one line before the `---` inviting their input
without handing them the decision:

```markdown
@<reporter> — your preference is welcome as input; the call itself is the maintainer's.
```

**Clarifying-facts comment** (may be addressed to the reporter):

```markdown
<!-- auto-dev -->

@<reporter> — a couple of details would let this be planned:

### 1. <short title of the missing fact>

**Area:** <file / command / subsystem>
**Impact:** <what a user sees or loses>
**Problem:** <what is ambiguous, 1–2 sentences>
**Needed:** <the specific fact — version, exact steps, the message you saw>

---

Reply here and the next automation pass will pick it up, or add the Skip label to opt this issue out of automation.
```

Cut anything that isn't one of the five parts: no restating the issue back to the maintainer, no
background they already have, no code excerpts, no "as discussed above". Three questions is the
practical ceiling for one comment — if there are more, ask the ones that block planning and leave
the rest.

A question with no genuine options is still a question — a pure missing-fact ("which account does
this run as?") keeps Area / Impact / Problem and replaces Options / Recommendation with the specific
fact needed, as in the clarifying-facts template above. The word cap applies the same way, and a
missing fact is exactly the kind anyone — the reporter included — may answer.

## Park proposal comment

Use this when an issue can't move forward because it needs a maintainer decision the skill can't
make — not missing facts, but a judgement call, a design fork, or a dependency on other work. It
**proposes** parking and waits; it never parks on its own.

```markdown
<!-- auto-dev -->

**For the maintainer:** this isn't blocked on missing detail — it's waiting on a call that's yours to make:

<1–3 sentences naming the blocker: the design fork, the open dependency, or why the issue reads as deferred>

Want me to **park** it for now? Reply "park it" (or add the Parked label) and I'll leave it untouched until you remove the label or comment again. If you'd rather move it forward, here's what would unblock it: <the specific decision or input needed>.
```

Parking is a maintainer's call like any other: a "park it" (or a 👍) from someone without write
access is a preference, not a park.

A parked issue is durable rest, not abandonment: the skill picks it back up the moment the maintainer
removes the Parked label or adds a comment _after_ the park (a rationale left at park time is
recorded but does not re-activate it — see the Parked branch in `triage.md`).
