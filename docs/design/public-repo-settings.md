# Design: profile settings that apply only to public repos

Status: accepted (open questions decided 2026-11-24). Tracking issue: #97. This note covers design only. Once it is merged, the
implementation follows in the PRs listed under [Implementation phases](#implementation-phases).

It picks up the four follow-up rows of
[`repo-visibility-override.md`](repo-visibility-override.md), section "Other settings that change
meaning on a public repo". That note added `repoOverrides.<key>.visibility` and left these settings
out of it on purpose.

## Problem

A [repo profile](../../plugins/core/references/profile-schema.md) can now say a repo is public, by
the fleet default or by a declared override. Some settings either exist only on a public repo or
matter much more there, and the profile has no way to state them:

- whether workflows from fork pull requests need approval before they run;
- secret scanning and push protection;
- private vulnerability reporting;
- files a public repo is expected to carry, such as a licence or a security policy.

Today these are set by hand and nothing reports drift on them. That matters most for a public repo,
whose main new risks are a committed secret and code from strangers running in CI. On a private
repo, the same settings are either unavailable or not worth requiring fleet-wide.

## Decisions this note proposes

1. **One new optional block in `defaults`, named `publicRepos`**, holding requirements that apply
   only to repos that are public. It is fleet policy. A single repo's override does not carry it,
   for the reason the visibility note gives: `"visibility": "public"` declares a fact about one
   repo, and should not also carry a security posture nobody can read off it.
2. **The block applies when the repo is public by either measure.** That means
   `effective.private == false` (the profile says public), **or** the live repo's `private` is
   `false` (the repo is public, whatever the profile says). The second case is a private-by-profile
   repo made public by accident. `settings-diff.sh` already reports it as a visibility `FAIL`, and
   it is also the repo that most needs secret scanning. Requiring the settings only once the
   profile agrees would leave the riskiest window unchecked.
3. **`settings-diff.sh` stays report-only**, the same as the visibility work: it prints the call
   that fixes each difference. It never prints a call that changes visibility (visibility note, Q1).
   `new-repo` applies the block's settings to a repo it creates public, after creation, under its
   usual confirmation.
4. **This is the profile's first conditional key**, and it is conditional on one fact only. Whether
   the block applies is computed from visibility; no key inside it is conditional on anything else.

## The block

```jsonc
"defaults": {
  "private": true,
  …
  "publicRepos": {                              // optional; applies only when a repo is public
    "secretScanning": true,                     // security_and_analysis.secret_scanning
    "pushProtection": true,                     // security_and_analysis.secret_scanning_push_protection
    "privateVulnerabilityReporting": true,      // repos/{slug}/private-vulnerability-reporting
    "forkPrApproval": "first_time_contributors",// actions/permissions/fork-pr-contributor-approval
    "files": { "license": true, "securityPolicy": true, "contributing": false }
  }
}
```

| Key | Type | Meaning |
| --- | --- | --- |
| `publicRepos` | object, optional | Absent: nothing changes, for any repo. Present: each key below is a requirement for a public repo. |
| `secretScanning` | bool, optional | Secret scanning must be enabled (`true`). `false` or absent: not checked. |
| `pushProtection` | bool, optional | Push protection must be enabled. `true` here with `secretScanning` not `true` is a validation error, because GitHub has no push protection without scanning. |
| `privateVulnerabilityReporting` | bool, optional | Private vulnerability reporting must be enabled. |
| `forkPrApproval` | string, optional | The minimum approval policy for workflows from fork pull requests: one of `first_time_contributors_new_to_github`, `first_time_contributors`, `all_external_contributors`, from loosest to strictest. A floor, as in [Floors](../../plugins/core/references/profile-schema.md#floors): a repo that is stricter conforms. |
| `files.license` | bool, optional | A licence file exists at the root: `LICENSE`, `LICENSE.md`, `LICENSE.txt` or `COPYING`. Existence only. |
| `files.securityPolicy` | bool, optional | `SECURITY.md` exists at the root, in `.github/`, or in `docs/`, the three places GitHub reads it from. Existence only. |
| `files.contributing` | bool, optional | `CONTRIBUTING.md` exists in one of the same three places. Existence only. |

Every key is a requirement or absent. A requirement can never turn a setting **off**. `false`
means "no opinion", so a fleet that leaves a key out and a fleet that writes `false` get the same
report. The profile states minimums for public repos and does not police repos that do more.

The file keys reuse the existence-only rule from `defaults.files` ("Existence-only, and why" in the
schema doc). The profile requires that a licence exists, never which one. Choosing a licence is a
legal decision for the person who owns the repo.

### Why `defaults` only

`publicRepos` is not a resolvable key. It is rejected in `languages` and `repoOverrides` with the
existing "fixed org-wide" message. A requirement that one repo could switch off is the exemption the
schema doc rules out. A fleet that needs one public repo without, say, a security policy has to
choose: drop the key for the whole fleet, or accept one open finding. See
[Q2](#open-questions) for whether that is too strict (decided: no, for now).

### Validation

`profile-resolve.sh --validate` gains these rules. Messages use the existing form:

1. `defaults.publicRepos` must be an object.
2. Each boolean key must be a boolean; `forkPrApproval` must be one of the three strings. An
   unknown key inside the block is an error: `defaults.publicRepos carries "<key>", expected one of
   …`. An unknown key in a security block should fail at the profile, not be silently ignored by
   the diff.
3. `pushProtection: true` without `secretScanning: true` is an error.
4. `publicRepos` in a `languages` block or a `repoOverrides` entry is an error, with today's
   message plus `— publicRepos is fleet policy and is legal only in defaults`.

## Resolution

`defaults` already passes through the merge, so `effective.publicRepos` equals `defaults.publicRepos`
for every repo, and is absent when the profile has none. No post-merge step is needed. The resolver
does not decide whether the block applies, because the answer depends on the live repo, which the
resolver never reads. `settings-diff.sh` decides that, since it holds both inputs.

## Reads, and what each one needs

The API shapes below were checked against GitHub on 2026-11-22 with a token that has admin on a
public repo, except where stated otherwise.

| Requirement | Read | Shape observed | Fix printed |
| --- | --- | --- | --- |
| `secretScanning`, `pushProtection` | `repos/{slug}`, already captured as `--repo-settings` | `.security_and_analysis.secret_scanning.status` and `.secret_scanning_push_protection.status`, each `"enabled"` or `"disabled"` | `gh api --method PATCH "repos/<slug>" --input -` with `{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, …}}` |
| `privateVulnerabilityReporting` | `repos/{slug}/private-vulnerability-reporting`, new input `--vuln-reporting` | `{"enabled": false}` | `gh api --method PUT "repos/<slug>/private-vulnerability-reporting"` |
| `forkPrApproval` | `repos/{slug}/actions/permissions/fork-pr-contributor-approval`, new input `--fork-approval` | **Not verified here**: the sandbox proxy used for this note refuses Actions paths. GitHub documents `{"approval_policy": "<one of the three values>"}`. The implementation PR verifies it before it relies on it. | `gh api --method PUT "repos/<slug>/actions/permissions/fork-pr-contributor-approval" -f approval_policy=<want>` |
| `files.*` | `doctor` check 14's existing file reads | — | none; the finding names the file |

**`security_and_analysis` is visible only to an admin or security manager.** For other tokens the
key is missing from the response. A missing key means **couldn't verify** (`SKIP`), never
`"disabled"` and never a pass. It is the same rule as for branch protection: a read-only token must
not produce invented differences.

The two new inputs follow the existing input contract. An input that was not passed, or a read that
failed (a 403 or 404, or a proxy refusal like the one above), is a `SKIP`, never a pass. Both
endpoints are repo-scoped REST, so they work where GraphQL is blocked
([`gh-rest-fallbacks.md`](../../plugins/core/references/gh-rest-fallbacks.md)), wherever the proxy
allows the path.

## Reporting

A new `publicRepos` section in `settings-diff.sh`'s findings:

| Case | Report |
| --- | --- |
| No `publicRepos` block in the profile | Nothing. |
| Block present, repo private by profile and live | One `NOTE  publicRepos: not applicable (repo is private)`. It is not counted, the same as the visibility note's `NOTE`. |
| Block present, repo public (by profile, or live) | One `FAIL` per unmet requirement, each with its fix. A met requirement prints nothing. |
| Block present, the visibility itself unknown (repo settings not read) | `SKIP  publicRepos: couldn't tell whether the repo is public`. |
| A requirement whose read was not passed, failed, or lacked the field | `SKIP` naming the requirement. |
| Live public, profile private (the accident case) | The existing visibility `FAIL`, **and** the `publicRepos` findings. The two are independent, and fixing the visibility clears the second set. |

Exit status and summary counts work as they do today: any `FAIL` exits `1`, and `NOTE` lines are
never counted.

`doctor --profile` check 15 shows the section as it shows the others, and check 14 adds the three
file rows, run only when the repo is public by the same rule. Check 14 reads visibility from the
same `repos/{slug}` response check 15 captures, so both agree on whether the block applies.

`new-repo` creating a repo public (by default or by override) applies the settings after the repo
exists, in the batch it already shows for confirmation, and scaffolds no licence, security policy
or contributing file. Those are the owner's words. It reports them as missing so the person creating
the repo sees what the standard expects.

## Versioning

`publicRepos` is an optional key in `defaults` and does **not** bump `profileVersion` (the schema
doc's Versioning rule). Unlike `visibility`, an older `profile-resolve.sh` does not check `defaults`
against an allow-list, so an older reader ignores the block instead of rejecting it. A fleet can add
it before every reader is upgraded, and the only cost is that older readers do not report on it.

## Out of scope

- Settings that the visibility note already put out of scope (forking, wiki, discussions, default
  token permissions, `internal` visibility, required checks that need secrets).
- Dependabot alerts and security updates. They exist on private repos too, so they are not
  public-only, and they belong in a separate design if a fleet wants them required.
- Licence **content** or which licence. That is the owner's decision, as above.

## Open questions

**Q1. What should the example profile and the docs suggest for `forkPrApproval`?** Decided (Allen, 2026-11-24): **(b) `all_external_contributors`.** The key is a
floor, so any value is valid. The question is which value maintainerd's own example shows.

- **(a)** `first_time_contributors`: anyone whose first contribution to this repo is a fork PR waits
  for approval. This is GitHub's middle setting.
- **(b)** `all_external_contributors`: every fork PR from someone outside the org waits. This is the
  strictest, and the most work for a busy public repo.

Reasoning: **(b)** for the example. The fleets this is written for have few outside
contributors, so the cost is small, and a contributor who has had one PR merged gets no wider CI
access. A fleet with many outside contributors can choose (a) in its own profile.

**Q2. Should a `repoOverrides` entry be able to relax a `publicRepos` requirement?** Decided (Allen, 2026-11-24): **no, for now.** The design
above says no. The alternative is a named, per-key exception in the override, such as
`"publicRepos": { "files": { "contributing": false } }`, reported as a `NOTE`. That follows the
visibility precedent: declared, in a block a reviewer reads.

Reasoning: **no for now**. Every requirement here is a security floor or the existence of a
file. A relaxation can be added later as an optional key without a version bump, and removing one
once fleets depend on it would need a bump.

## Implementation phases

Two PRs. B must not merge before A.

**PR A: mechanism.**

- `plugins/core/scripts/profile-resolve.sh`: the validation rules above.
- `plugins/core/scripts/settings-diff.sh`: the `publicRepos` section, the two new inputs, the
  applies-when rule, and the `SKIP` cases. The capture comment at the top of the file adds the two
  new reads.
- `scripts/test-profile.sh`: validation (each rule, including the push-protection-without-scanning
  error and the rejection in `languages` and `repoOverrides`); and diffs for each row of the
  reporting table. The tests include the accident case, where the visibility `FAIL` and the
  `publicRepos` findings both appear; a missing `security_and_analysis` read as `SKIP`; and a
  stricter `forkPrApproval` read as conformant.
- `plugins/core/references/profile-schema.md`: the block's rows under `defaults`, a short
  "Conditional on visibility" section, and a line in "Version 1 guarantees".
- `plugins/core/references/example-profile.json`: the block, with Q1's answer.

**PR B: skills prose.**

- `plugins/core/skills/doctor/SKILL.md`: check 14's three file rows and the applies-when rule; check
  15 capturing the two new inputs.
- `plugins/core/skills/new-repo/SKILL.md`: applying the block after creating a public repo, and
  reporting the files it does not write.

Neither PR touches `KNOWN_VERSION`. Plugin versions are bumped by the merge workflow, not in the PR.
