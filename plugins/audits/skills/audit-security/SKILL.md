---
name: audit-security
description: Scheduled security sweep of the whole repo — known-vulnerable dependencies (CVEs), secrets/credentials committed to the tree or git history, and dangerous code patterns (injection, unsafe deserialization, shelling out with user input, weak crypto, disabled TLS verification). Severity-ranked; opens a focused PR for mechanically-safe fixes and files an issue for anything needing judgment — one PR or one issue per finding, never bundled, deliberately capped. Honest about coverage: a category whose scanner isn't installed is reported as "not scanned", never as clean. Reads the repo config + guidelines for language and repo-specific security rules. Use when the user asks to "audit security", "run a security sweep", "check for vulnerabilities/CVEs", "scan for secrets", "find dangerous patterns", or when invoked by a scheduled remote agent. Distinct from `/security-review`, which reviews the pending diff on a branch; this sweeps the whole tree + dependencies. Has working-tree side effects (branches + PRs) and GitHub side effects (issues, labels).
---

# Audit the repo for security problems and file discrete units of work

This skill is a recurring, whole-repo security sweep. Where `/security-review` reviews the **diff on
the current branch**, this audits the **entire tree and its dependencies** on a schedule — the
known-vulnerable dependency, the secret that got committed three months ago, the `eval()` nobody
flagged in review. It **severity-ranks** every finding, **fixes what is mechanically safe** (one
focused PR per finding) and **files an issue** for anything that needs judgment.

It shares the audits-family discipline: **deliberately conservative**, capped per run, dedups against
open work, one unit of work per finding. But security has two properties the other audits don't:

- **A real vulnerability must never be silently capped away.** Critical/High findings are *always*
  surfaced in the report even when they exceed the per-run cap (the cap only defers *filing*, not
  *telling you*).
- **Absence of a scanner is not absence of a problem.** If a detection tool isn't installed, the
  category is reported **"not scanned"** — never "clean". A green report from a security audit has to
  mean "we looked", not "we couldn't look."

## Load the repo config

Before anything else, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **stop** and tell the user to run `/bootstrap`, then re-run. Don't guess.
3. Keys this skill uses:
   - `config.repo` — GitHub `owner/name`, passed to every `gh ... --repo`.
   - `config.defaultBranch` — branch to check out and target PRs at.
   - `config.language` — `python` | `typescript`; selects the language-specific detection below.
   - `config.paths.source` — root of the source to sweep.
   - `config.commands.{format,lint,build,test}` — pre-flight gate before any PR (skip `null` ones).
   - `config.labels.security` — label applied to every PR/issue this skill opens (default `security`).
   - `config.labels.automated` — also applied (default `automated`).
   - `config.audits.securityPrCap` / `config.audits.securityIssueCap` — per-run caps (default **3 / 5**).
   - `config.audits.promoteThreshold` / `config.audits.promoteLookbackDays` — pattern-promotion knobs (default **3** within **90** days). See step 6.
   - `config.guidelines.invariants` / `config.guidelines.coding` — **the repo's own security rules.**
     Read these; they hold repo-specific invariants the generic checks can't know (e.g. "secrets are
     `SecretStr`, never `str`", "never log a secret", "all SQL goes through the query builder", "use
     `plugin.logger`, never shell out"). Flag violations of each rule listed there.

Treat a `null` command as "this repo has no such step — skip it."

## What it looks for

Four categories. Each has a **default severity**, a **detection method** (preferring tools that need
no install, escalating to scanners if present), and a **default routing** (PR vs issue). Severity and
routing are defaults — apply judgment.

| Category | Typical severity | Detection | Default routing |
| --- | --- | --- | --- |
| **Vulnerable dependencies (CVEs)** | per advisory | Run the ecosystem auditor if present (see language blocks). Each advisory = one finding: package, installed version, fixed version, CVE/GHSA id, severity. | **PR** if a non-breaking patch/minor bump fixes it (bump the pin + lockfile); **issue** if the fix needs a major/breaking bump or there's no fix yet. |
| **Committed secrets / credentials** | **Critical** | Run a secret scanner if present (`gitleaks detect`, `trufflehog`); otherwise grep heuristics over the tree **and git history** for high-entropy strings and known token shapes (`AKIA…`, `ghp_…`, `sk-…`, `-----BEGIN … PRIVATE KEY-----`, `xox[baprs]-…`, JWT triples, `password|secret|api_key\s*[:=]\s*["'][^"']+`). | **Issue (redacted) + alert the user directly.** Never a "fix" PR — see [Handling secrets safely](#handling-secrets-safely). |
| **Dangerous code patterns** | High/Medium | `semgrep --config auto` if present; else the language-specific greps below. Injection (string-built SQL/shell, `shell=True` with interpolation), unsafe deserialization (`pickle`, `yaml.load`, `eval`/`exec`, `vm`/`Function`), SSRF/open redirect, path traversal, weak/0-arg crypto, disabled TLS verification (`verify=False`, `rejectUnauthorized:false`), `innerHTML`/`dangerouslySetInnerHTML` with untrusted input. | **PR** if the fix is mechanical and behavior-preserving (`yaml.load`→`yaml.safe_load`, parameterized query, drop `shell=True`); **issue** if it needs redesign or the taint path is non-obvious. |
| **Hardcoded config / permissive defaults** | Medium | Read for in-source credentials that should be env/secret-managed, `DEBUG=True` in shippable config, CORS `*` with credentials, overly broad file modes, auth disabled in non-test code. Cross-check against `config.guidelines`. | **Issue** — usually a judgment/ownership call. |

You're not limited to this table — if a security-minded reviewer would flag something else (an
auth check that can be bypassed, a missing rate limit on a sensitive endpoint, a logged secret),
capture it. Keep the routing rule: mechanical + behavior-preserving → PR; judgment or redesign → issue.

### Language-specific detection

Run the block matching `config.language`. If neither, run the language-agnostic checks (deps via
whatever lockfile exists, secret scan, the cross-language pattern greps) and **say so in the report**.

**Python** (`config.language == "python"`):
- Deps: `pip-audit` (or `uv pip audit`) if present; else read `uv.lock`/`poetry.lock`/`requirements*.txt` and check the top direct deps against the OSV API.
- Patterns: `bandit -r <source>` if present; else grep for `yaml.load(` (without `Loader=SafeLoader`), `pickle.load`, `eval(`/`exec(`, `subprocess.*shell=True`, `os.system(`, `verify=False`, `hashlib.md5(`/`sha1(` for security use, `Jinja2(... autoescape=False)`, f-string/`%`-built SQL.

**TypeScript / JavaScript** (`config.language == "typescript"`):
- Deps: `npm audit --json` (available without extra install); prefer `osv-scanner`/`npm audit` and read `package-lock.json`.
- Patterns: `semgrep` if present; else grep for `eval(`, `new Function(`, `child_process` exec with interpolation, `dangerouslySetInnerHTML`, `.innerHTML =`, `rejectUnauthorized: false`, `Math.random()` for tokens/ids, template-built SQL, `vm.runInThisContext`.

## What it does NOT do

- **It is not `/security-review`.** That reviews the pending branch diff interactively; this is the
  scheduled whole-tree + dependency sweep. They complement each other.
- **It doesn't run penetration tests or hit live endpoints.** Static + dependency analysis only.
- **It doesn't fix secrets by deletion.** Removing a key from HEAD leaves it in git history and does
  nothing to revoke it; the fix is rotation, which is a human action.
- **It doesn't re-file what CI already gates.** If the repo runs `npm audit`/`pip-audit` in CI and
  it's red, that's a CI failure, not an audit finding — flag the gap, don't duplicate.

## Workflow

Use `TaskCreate` to track each finding — a security sweep sprawls and you'll lose your place.

### 1. Pre-flight: start clean

```bash
git status --short            # working tree must be clean (except untracked config.paths.skillsDir scaffolding)
git checkout <config.defaultBranch>
git pull
```

Dirty tree (outside `config.paths.skillsDir`) → stop and report; a human is mid-work.

### 2. Detect available tooling — and record what's missing

Probe once, up front, and **carry the result into the report**:

```bash
for t in gitleaks trufflehog osv-scanner semgrep bandit pip-audit; do command -v "$t" >/dev/null 2>&1 && echo "have: $t" || echo "missing: $t"; done
```

For every category whose preferred scanner is missing, you'll either fall back to the grep/OSV-API
method (and note the lower confidence) or, if no fallback exists, mark the category **"not scanned"**.
**Never let a missing tool become a silent "clean".**

### 3. Sweep the categories

Run each detection. **Collect findings into a list — open nothing until the sweep is complete**, so
you can dedup across categories and rank by severity. Assign each finding a severity
(Critical/High/Medium/Low) and a one-line evidence pointer (`file:line` or `package@version → CVE`).

### 4. Dedup against existing work

```bash
gh issue list --repo <config.repo> --state open --label <config.labels.security> --json number,title,body --limit 100
gh pr list   --repo <config.repo> --state open --json number,title,headRefName --limit 50
```

Skip a finding if an open issue/PR already covers the same package/file/pattern, or if it was closed
`wontfix`/not-planned (a standing human decision). For a **Critical/High** that was previously closed
without a fix, don't silently re-file — but **do** call it out in the report; a deferred critical is
worth a second look.

### 5. Route and act — severity first

Process findings **highest-severity first**. For each:

- **PR** (counts against `config.audits.securityPrCap`) when the fix is mechanical, behavior-preserving,
  < ~150 lines, ≤ 5 files: a non-breaking dependency bump, `yaml.load`→`yaml.safe_load`, a
  parameterized query, dropping `shell=True`, enabling TLS verification.
  - Branch `sec-<category>-<descriptor>` off `config.defaultBranch`.
  - **Delegate to `create-pr` if installed**; else run `config.commands.{format,lint,build,test}`
    (skip `null`) as pre-flight before pushing. No `--no-verify`. Never auto-merge.
  - Label `config.labels.security` + `config.labels.automated`. For a dependency bump, the PR body
    must name the CVE/GHSA, the version delta, and that tests pass.
- **Issue** (counts against `config.audits.securityIssueCap`) otherwise — describe the vuln, its
  impact, evidence (`file:line`), and a proposed fix; don't write the code.

Caps: default **3 PRs / 5 issues** per run. **But Critical/High findings over the cap are still listed
in the report** (clearly marked "over cap — file next run / fix now"); only Medium/Low silently defer.

### 6. Systemic escalation (recurring patterns)

Before reporting, run the **pattern-promotion** check. If a finding this run is an instance of a
*specific, encodable* security pattern this audit has already fixed or filed
`config.audits.promoteThreshold` times (default 3) within `config.audits.promoteLookbackDays` (default
90) — e.g. *"new HTTP clients keep being constructed with `verify=False`"* — file **one** human-gated
issue proposing the pattern become a rule in `config.guidelines.invariants` / `config.guidelines.coding`,
rather than only fixing the instance again. If the rule already exists and keeps being violated, the
proposal should ask for a **mechanical guard** (a `semgrep`/`bandit` rule, a CI grep) instead of more
prose. Full mechanism, history queries, dedup marker, and template live in
[`../../references/pattern-promotion.md`](../../references/pattern-promotion.md); this audit's
`<audit-name>` is `security` and its branch prefix is `sec-`. The proposal is **in addition to** the
normal fix, does **not** count against the caps, and is capped at one per run. Never auto-edit the
guideline — propose; the maintainer decides. (This never applies to committed-secret findings — those
are handled per [Handling secrets safely](#handling-secrets-safely), not promoted.)

### 7. Report

```text
Security audit — <YYYY-MM-DD>   (repo: <config.repo>, language: <config.language>)

Coverage:
  - Dependencies:  scanned via <tool/OSV-API>  |  Secrets: scanned via <tool/grep+history>
  - Patterns:      scanned via <tool/grep>      |  NOT SCANNED: <category> (<tool> unavailable)

Findings: <total>   (Critical <n> · High <n> · Medium <n> · Low <n>)
  PRs opened:  #NNN sec-deps-bump-urllib3 — CVE-2024-XXXX urllib3 2.0.4→2.0.7 (High)
  Issues filed: #NNN dangerous-pattern: yaml.load on untrusted input in <file> (High)
  Over cap (NOT yet filed): <finding> (Critical) — recommend fixing now

Secrets: <0, or "see direct alert — N redacted finding(s), NOT posted publicly">

Systemic: proposed encoding <pattern> as a rule in <guideline file> (or a mechanical guard if the rule already exists) — issue #NNN (seen <N>× in <days>d)

No findings in: <clean categories>     Not scanned: <categories with no tool>
```

If zero findings **and** every category was actually scanned: `Findings: 0 — looks clean (all
categories scanned).` If any category couldn't be scanned, the report must say so — a partial sweep
is never reported as a clean bill of health.

## Handling secrets safely

A leaked secret is the one finding where the *audit itself* can make things worse. Rules:

- **Never paste the secret value into a GitHub issue, PR, or any public surface.** That re-broadcasts
  it. Reference only the **type**, the **location** (`file:line` or commit), and a **redacted** stub
  (`ghp_…last4`).
- **Alert the user directly** in your run reply (not just an issue): what kind of secret, where, and
  that it needs **rotation/revocation** — removing it from HEAD does **not** purge git history and
  does **not** revoke the credential.
- File the tracking **issue redacted** (or ask the user before filing, if the repo is public). The
  issue tracks rotation + history purge (e.g. `git filter-repo`/BFG), not a code diff.
- **Never** open a PR that just deletes the secret line — it implies "fixed" while the live
  credential is still valid and still in history.

## What not to do

- **Don't report a category clean when its scanner was missing.** "Not scanned" is the honest status.
- **Don't bundle findings** into one PR. One unit of work per PR/issue.
- **Don't auto-fix a vulnerability you don't understand.** A wrong security "fix" can open a worse
  hole. If the taint path or blast radius is unclear → issue, not PR.
- **Don't silently drop a Critical/High over the cap.** Surface it in the report.
- **Don't leak secret values** into issues/PRs/logs. Redact, alert, rotate.
- **Don't bump a dependency across a major version "to fix a CVE"** without checking it builds and
  tests pass — that's an issue (breaking-change review), not a mechanical PR.
- **Don't operate on a dirty tree, skip pre-flight, `--no-verify`, or auto-merge.**
- **Don't auto-edit the guidelines.** When a security pattern recurs past the threshold, *propose* the rule (or a mechanical guard, if the rule already exists) as an issue (step 6); the maintainer decides. One promotion per run, never for secrets, never re-propose one closed Not planned.

## When integrated with scheduling

Like the other audits, this is **not** part of `daily-update` (which bundles into one PR; this opens
discrete ones). Schedule it its own slot (e.g. nightly) via the `schedule` skill, invoking it
directly. Pairs with `audit-architecture` (structure), `audit-tests` (test quality), and
`audit-deps` (dependency freshness/licensing — the non-security side of dependencies); each dedups
against its own label/branch prefix, so running them together is fine.

**Model tier:** taint paths and "don't 'fix' what you don't understand" are the highest-stakes
judgment in the audit suite — schedule on the **`capable`** tier and never down-tier security to save
tokens. See [`../../references/model-tiers.md`](../../references/model-tiers.md).
