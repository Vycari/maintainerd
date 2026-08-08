<!-- GENERATED COPY — DO NOT EDIT.
     Canonical source: plugins/core/references/model-tiers.md
     Vendored here because cross-plugin relative links do not resolve in an installed
     marketplace layout. Edit the canonical, then run scripts/sync-references.sh. -->

# Model tiers — routing routines to the right-sized model

A shared reference for the skills that run as scheduled routines. The maintainerd skills don't pick
their own model; this doc tells the maintainer which **tier** each routine wants, and
`config.models` (below) is where the repo binds a tier to a concrete model id.

This is the proactive-loop cost lever: *route routine, mechanical work to a smaller/faster model, and
spend the most capable model only on judgment.* A nightly dependency bump and adjudicating whether a
disclosed CVE is actually reachable are both "audits," but they don't need the same brain.

## The mechanism (and its one honest limit)

A model is chosen in two places, both **outside** a running skill:

1. **When you schedule the routine.** The `/schedule` routine (or your own runner) runs the whole
   skill under one model. That is the primary lever — pick the tier from the table below.
2. **When a skill delegates to a subagent.** A skill that spawns a subagent (via the `Agent`/task
   tooling) can set that subagent's model per call — so a fast-tier routine can still escalate a
   single judgment call to the capable tier, or vice-versa.

The honest limit: **a skill cannot change its own model mid-run.** So a single routine whose run
*mixes* cheap and expensive work must be scheduled at the tier its **hardest step** needs — you only
get to down-tier the cheap part by splitting it into a separate routine or a separate subagent. Don't
schedule `auto-dev` on a fast model to save tokens on its triage pass; the same run also writes code.

## `config.models`

Optional. A mapping from tier label → model id (or `"inherit"` = don't override, use whatever the
routine/session already runs). Absent or a tier unset → that tier inherits. This is **declarative
reference config**: it records the repo's tier→model bindings in one place so every routine is tiered
consistently, and any subagent-spawning skill can read it. Skills that don't spawn subagents inherit
the routine's model and never read this block.

```jsonc
"models": {
  "fast":    "claude-haiku-4-5",  // mechanical, high-volume, low-judgment work
  "capable": "claude-opus-4-8",   // judgment, code generation, security reasoning
  "default": "inherit"            // fallback when a skill names no tier
}
```

Two tiers (`fast`, `capable`) cover the spectrum the article describes; a repo that wants a middle
rung can add one (e.g. `"mid": "claude-sonnet-5"`) and point the judgment-lighter routines at it.
Model ids change over time — check the current lineup with `/model` rather than trusting a pin here.

## Which tier each routine wants

| Routine | Tier | Why |
| --- | --- | --- |
| `audit-deps` | **fast** | Runs analyzers and parses their output; the judgment (major bump vs. patch, license policy) is narrow. Escalate a specific replacement decision to a `capable` subagent if needed. |
| `audit-architecture` | **capable** | DRY/abstraction smells, invariant drift, and PR-vs-issue routing are judgment-heavy — exactly what a smaller model gets wrong. |
| `audit-tests` | **capable** (or `mid`) | "Is this mock decorative? is this assertion actually weak?" is judgment. It runs several times a day, so a `mid` rung is a reasonable cost trade if the repo has one. |
| `audit-security` | **capable** | Advisory triage and "don't "fix" what you don't understand" are the highest-stakes judgment in the suite — is this CVE reachable here, is this string a live credential. Don't down-tier security. |
| `auto-dev` | **capable** | Writes code, drafts plans, adjudicates review feedback. Its `dry-run` mode (read-only report) is safe on **fast**. |
| `dependabot` | **fast** | Gating and merging is mechanical — read check conclusions, compare version strings, call `gh pr merge`. Its one judgment-heavy step (diagnosing a broken update) is the exception the subagent lever exists for: delegate *that* to a `capable` subagent rather than up-tiering the whole routine. |
| `research-radar` | **capable** (or `mid`) | Deriving themes and curating relevance is judgment; the arXiv fetch/parse around it is cheap but can't be split from the same run. |
| `daily-update` / `daily-changelog` | **mid**/**capable** | Changelog synthesis is moderate judgment — readable summaries, honest grouping. `fast` tends to produce thin, mechanical notes. |

The **pattern-promotion** step (documented in `references/pattern-promotion.md` in the **audits**
plugin) runs *inside* an audit, so it inherits that audit's tier — no separate choice.

## What not to do

- **Don't down-tier a routine to save tokens on its cheap steps** when the same run also does
  judgment or writes code — schedule to the hardest step, or split the cheap part out.
- **Don't put security or code-generation on the fast tier.** The token saving isn't worth a wrong
  security call or a broken PR.
- **Don't hardcode a model id inside a skill.** Tiers live in `config.models`; the binding is the
  repo's to set and to change as the model lineup moves.
- **Don't treat this as mandatory.** With no `config.models` block, every routine simply inherits its
  scheduled model — the pre-tiering behavior. Tiering is an optimization, not a requirement.
