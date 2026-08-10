# Pattern promotion — close the loop from findings to rules

A shared mechanism for the guideline-checking audits (`audit-architecture`, `audit-tests`,
`audit-security`). Each of those skills references this file the way every skill references
[`config-schema.md`](config-schema.md); the mechanism lives here once instead of being
copy-pasted (and drifting) across three skills.

## The problem this solves

The audits fix instances. A nightly run finds a `print()` in library code, swaps it for the logger,
and moves on — and next week finds another one, fixes it, and moves on again. The mechanical fix
treats the symptom every run without ever changing anything that would stop the class of problem from
recurring. The audit becomes a treadmill: it keeps the tree tidy but the same smell reappears forever.

**Pattern promotion turns the treadmill into a ratchet.** When an audit notices it has fixed or filed
the *same specific pattern* enough times, it stops there being only individual fixes and **proposes
encoding the pattern as a rule** — a line in the repo's guidelines file (`invariants.md` /
`coding.md` / `testing.md`) or, if a rule already exists, a mechanical guard (a lint rule / CI check)
that enforces it. Future work is then caught at review or CI time instead of swept up after the fact.

This is the "improve the system for all future iterations" step: don't just fix the individual
result — encode what you learned so the next iteration is cheaper.

## When it runs

**After** the sweep, dedup, and routing (PRs opened / issues filed), and **before** the report — as
an *additional* output, not a replacement. The audit still fixes or files this run's instance the
normal way; the promotion proposal is filed on top when the recurrence bar is met.

It is **human-gated and never auto-edits a guideline file.** `invariants.md` is the one file in the
whole config contract that needs real human judgment (see the README) — the audit *proposes* the rule
as a GitHub issue; the maintainer decides whether it becomes a rule (editing the file directly, or
approving the issue through the `auto-dev` pipeline, which the proposal issue enters like any other).

## Config it reads

- `config.audits.promoteThreshold` — how many times the same pattern must have been actioned before a
  promotion is proposed. Default **3** if absent (note the fallback in the report).
- `config.audits.promoteLookbackDays` — how far back to count prior actions. Default **90** if absent.
- The audit's own `config.labels.<category>` + `config.labels.automated` and its category-prefixed
  branch slug (`arch-<category>-…`, `audit-tests-<category>-…`, `sec-<category>-…`) — the history this
  mechanism counts against already carries these; no new label is introduced.

Set `promoteThreshold` high enough that a promotion means "this is genuinely chronic," not "this
happened twice." If the maintainer finds promotions noisy, they raise the threshold in
`.claude/maintainerd.json`; they never edit it here.

## Step A — Identify a candidate pattern (specific and encodable)

A promotable pattern is a **specific, nameable shape that a written rule could actually prevent** —
not a broad category label. Judge the candidate against two tests:

- **Specific.** "`Any` overuse" or "weak assertions" is a category, not a rule — too broad to encode
  usefully. The promotable version is the concrete recurring shape underneath it: *"new FastAPI route
  handlers keep taking `dict[str, Any]` request bodies instead of a typed pydantic model,"* *"new
  tests keep mocking the DB session instead of using the `db` fixture,"* *"`console.*` keeps
  reappearing in `src/transport/`."* If you can't state the rule in one sentence a reviewer could
  apply, there's nothing to promote — skip it.
- **Encodable.** A written rule or a check could plausibly stop it. A pattern that only judgment can
  catch (subjective naming, case-by-case design forks) is not promotable; keep fixing those per
  instance.

If several recurrences merely share a category label but not a single encodable rule (scattered,
unrelated `Any` sites across the tree), that is **not** a pattern — don't promote it.

## Step B — Confirm recurrence from history

The audits keep no cross-run state of their own; recurrence is reconstructed from GitHub each run.
Count the distinct times this audit has **actioned** the candidate pattern — merged automated PRs and
closed-as-completed automated issues — within the lookback window, and **include this run's
instance**. Query by the audit's category label and branch prefix, e.g. for `audit-architecture`:

```bash
# Prior merged automated PRs for this pattern's category (branch-prefix + label are the signal)
gh pr list --repo <config.repo> --state merged --limit 100 \
  --json number,title,headRefName,mergedAt \
  | jq --arg p 'arch-<category>-' --arg since '<cutoff-ISO>' \
      '[.[] | select(.headRefName | startswith($p)) | select(.mergedAt >= $since)]'

# Prior automated issues for this pattern, closed as completed (not not-planned)
gh issue list --repo <config.repo> --state closed --label <config.labels.architecture> \
  --search "reason:completed" --json number,title,closedAt --limit 100
```

Read titles/bodies to keep only the ones that are the **same specific pattern** from Step A, not just
the same category label. If

```text
(prior actioned instances of this pattern within lookback) + (this run's instance)  ≥  promoteThreshold
```

the recurrence bar is met. Otherwise, fix this run's instance normally and propose nothing.

Two live instances of the identical narrow pattern in a *single* run, plus at least one prior, also
clears the bar — a burst is recurrence too.

## Step C — Choose the right systemic fix

- **The guideline doesn't state this rule yet** → propose **adding the rule** to the mapped guideline
  file (see the mapping table). This is the common case.
- **The guideline already states the rule and it's *still* recurring** → prose isn't the gap;
  enforcement is. Propose a **mechanical guard** instead: a lint rule, a CI grep, a pre-commit hook,
  a type constraint — whatever would make the next instance fail automatically. Say plainly in the
  issue that the rule already exists and keeps being violated, so the maintainer knows this is an
  enforcement gap, not a documentation gap.

Either way the output is one **issue** — a proposal, not a diff. Don't write the lint config or edit
the guideline; describe the smallest change that would close the gap.

## Step D — Dedup the proposal

A promotion proposal carries a stable marker as the first line of its body so future runs recognize
it:

```html
<!-- audit-promotion:<audit-name>:<pattern-slug> -->
```

(`<audit-name>` is `architecture` | `tests` | `security`; `<pattern-slug>` is a short kebab-case
identifier for the pattern, e.g. `route-untyped-body`.) Before filing, search for it and skip if any
match:

```bash
# Already proposed and still open
gh issue list --repo <config.repo> --state open --search "audit-promotion:<audit-name>:<pattern-slug> in:body" --json number --limit 20
# Maintainer already declined this promotion — a standing "no, don't make this a rule"
gh issue list --repo <config.repo> --state closed --search "audit-promotion:<audit-name>:<pattern-slug> in:body reason:not-planned" --json number --limit 20
```

A promotion the maintainer closed not-planned is a durable decision — **never re-propose it**, no
matter how many more instances accrue. (They've said "keep fixing it per instance"; respect that.)

## Step E — File exactly one proposal (per run)

**At most one promotion proposal per run**, even if several patterns qualify — pick the most chronic
(highest count) and defer the rest to future runs. The proposal **does not count against the audit's
PR/issue caps**; it is a distinct, low-volume output class (the caps guard review-load from routine
fixes; a systemic proposal is the rare, high-value exception). Apply the audit's normal
`config.labels.<category>` + `config.labels.automated` labels so it threads into the same review flow.

Issue template:

```markdown
<!-- audit-promotion:<audit-name>:<pattern-slug> -->

## Recurring pattern

`<audit-name>` has now fixed/filed the same pattern **<N> times** in the last
<promoteLookbackDays> days: <one-sentence statement of the specific, encodable pattern>.

Fixing each instance keeps the tree clean but doesn't stop the next one. Proposing to encode it.

## Evidence (prior instances)

- #<PR/issue> — <what it fixed> (<date>)
- #<PR/issue> — <what it fixed> (<date>)
- <this run> — <the instance being fixed/filed now>

## Proposed rule

<Pick one and delete the other:>

**Add to `<guideline file>`:** <the exact one- or two-sentence rule to add, written so a reviewer
could apply it and the next audit run could check the diff against it.>

**— or, if the rule already exists —**

**Enforce the existing rule** (`<guideline file>` already says "<quote>", yet it keeps recurring):
<the smallest mechanical guard that would catch the next instance — a lint rule, a CI grep, a
pre-commit check, a type constraint. Name it; don't write it.>

## Out of scope

This issue is about encoding the pattern, not re-fixing the instances above (those are already
handled). <Anything else explicitly excluded.>

---

_Filed by the `<audit-name>` audit's pattern-promotion step. If this shouldn't become a rule, close
as **Not planned** / `wontfix` — the audit records that and won't propose it again._
```

## Per-audit mapping

Which guideline file each audit proposes adding the rule to (Step C's "add a rule" case):

| Audit | `<audit-name>` | Branch prefix | Category label | Proposes rules for |
| --- | --- | --- | --- | --- |
| `audit-architecture` | `architecture` | `arch-` | `config.labels.architecture` | `config.guidelines.invariants` for load-bearing/structural patterns; `config.guidelines.coding` for a convention (logger-not-`print`, typing style). |
| `audit-tests` | `tests` | `audit-tests-` | `config.labels.testQuality` | `config.guidelines.testing`. |
| `audit-security` | `security` | `sec-` | `config.labels.security` | `config.guidelines.invariants` / `config.guidelines.coding` (repo security rules). |

## Report line

When a promotion is proposed, the audit adds one line to its run report (and an otherwise-silent
audit like `audit-tests` **does** report on a run where it proposed one — a promotion is something to
say):

```text
Systemic: proposed encoding <pattern> as a rule in <guideline file> — issue #NNN (seen <N>× in <days>d)
```

If a candidate pattern cleared the specificity test but not the count threshold, don't mention it —
only speak when a proposal is actually filed.

## What not to do

- **Don't auto-edit a guideline file.** The audit proposes; the human decides. `invariants.md`
  especially is human-judgment territory.
- **Don't promote a broad category.** "Stop using `Any`" is not a promotable rule; the specific
  recurring shape underneath it might be. If you can't state the rule in one sentence, don't file.
- **Don't file more than one promotion per run**, and don't count it against the PR/issue caps.
- **Don't re-propose a promotion the maintainer closed not-planned.** That's a standing decision to
  keep fixing per instance.
- **Don't skip fixing this run's instance** because you filed a promotion — the proposal is *in
  addition to* the normal fix, not instead of it.
- **Don't propose more prose when the rule already exists** — a recurring violation of a documented
  rule is an enforcement gap; propose a mechanical guard, not a second sentence saying the same thing.
