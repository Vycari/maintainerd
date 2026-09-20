<!-- GENERATED COPY — DO NOT EDIT.
     Canonical source: plugins/core/references/gh-rest-fallbacks.md
     Vendored here because cross-plugin relative links do not resolve in an installed
     marketplace layout. Edit the canonical, then run scripts/sync-references.sh. -->

# Running the skills where GitHub's GraphQL API is blocked

Some sandboxes reach GitHub through an egress proxy that allows the REST API and refuses the
GraphQL one. `gh`'s porcelain is mostly GraphQL underneath, so in such an environment these all
return **403** even though the token is fine and `gh auth status` is green:

`gh issue list` · `gh issue view --json` · `gh issue create` · `gh pr list` · `gh pr view --json` ·
`gh pr create` · `gh pr ready` · `gh pr edit` · `gh pr checks` · `gh pr merge` · `gh search issues`
· `gh search prs` · any `gh api graphql …`

What still works is **repo-scoped REST** through `gh api`: `repos/{owner}/{repo}/issues`,
`/pulls`, `/issues/{n}/comments`, `/issues/{n}/labels`, `/issues/{n}/timeline`,
`/commits/{sha}/check-runs`, `/collaborators/{login}/permission`, `/labels`. The **global**
`search/issues` endpoint is refused too, so it is not a fallback for anything.

This file is the one place those REST forms are written down. A skill that needs one links here
rather than re-deriving it — hand-derivation is where `-f body=@file` came from (see
**Posting a comment**).

## Three rules that outrank everything below

1. **Fail closed on reads.** If neither the porcelain nor the REST form can answer "what work
   already exists?", the answer is **not** "nothing exists". Do not create, do not skip, do not
   assume zero. Stop that step and say in the report which call failed and what it was for.
2. **Never silently skip a step that has no REST path.** The three below are GraphQL-only. A skill
   that reaches one in blocked mode **stops and reports**, naming the exact action a human must
   take. Dropping the step and carrying on is the failure this file exists to prevent.
3. **No unattended path may depend on `search/issues`.** Not the porcelain (`gh search issues`),
   not the REST endpoint. Replace it with a repo-scoped list plus a client-side filter, and state
   the pagination bound you used — see **Replacing search**.

## Detecting the condition

Two inputs, checked **once per run** and cached for the rest of it.

```bash
# 1. The caller's setup step may declare it. Any value other than the empty string counts;
#    `1` is the documented spelling.
#      export GH_GRAPHQL_BLOCKED=1
#
# 2. Otherwise probe once. Cheap, read-only, no side effects.
gh api graphql -f query='{viewer{login}}' --jq '.data.viewer.login' >/dev/null 2>&1
```

```bash
# Returns 0 (true) when GraphQL must be treated as unavailable.
gh_graphql_blocked() {
  [ -n "${GH_GRAPHQL_BLOCKED:-}" ] && return 0
  gh api graphql -f query='{viewer{login}}' >/dev/null 2>&1 && return 1
  return 0
}
```

The probe **fails closed**: any non-zero exit — 403, a proxy error, a timeout, `gh` not
authenticated — means "treat GraphQL as blocked". A run that cannot tell should use the REST forms,
which work in both worlds; the cost of using them unnecessarily is nothing.

`GH_GRAPHQL_BLOCKED` set takes precedence and skips the probe, so a caller who already knows can
save the round trip. Say in the run report which of the two decided it.

## The REST forms

Throughout: `$REPO` is `owner/name`, `$N` an issue or PR number. Everything uses
`gh api -X GET … -f key=value` for reads rather than a hand-built query string — `gh` URL-encodes
the values, which matters the moment a label is named `auto:in-progress` or a branch contains `/`.

### Pagination, and the `--jq` trap

`--paginate` fetches every page, but **`--jq` is applied to each page separately**, so
`--paginate --jq 'length'` prints one number *per page* and `--paginate --jq '.[0]'` gives the first
item of every page. `--slurp` wraps the pages into one outer array — and `gh` **rejects `--slurp`
together with `--jq` or `--template`** (`the --slurp option is not supported with --jq`). So for
anything that aggregates, slurp and pipe to `jq`, flattening the page array with `.[][]`:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/issues" \
  -f state=open -f per_page=100 \
| jq '[.[][]] | length'
```

Use `--jq` directly only when the expression is per-item and you are happy with per-page output.

**Always pass `per_page=100`** (the maximum; the default is 30) and **always `--paginate`** on a
read whose completeness a decision depends on. A truncated list read as complete is the same bug as
a failed read read as empty. Where a skill deliberately bounds the scan instead of paginating, it
must say so in its report — "scanned the first 200 open issues" is a usable caveat, "no open
issues" on a truncated page is not.

### List issues by label and state

`gh issue list --repo $REPO --state open --label L --json …` becomes:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/issues" \
  -f state=open -f labels="$L" -f sort=created -f direction=asc -f per_page=100 \
| jq '[.[][] | select(has("pull_request") | not)
       | {number, title, body, createdAt: .created_at, updatedAt: .updated_at,
          labels: [.labels[].name], author: .user.login}]'
```

Two things the porcelain did for you that the endpoint does not:

- **`/issues` returns pull requests too.** Every PR is an issue in REST. The
  `select(has("pull_request") | not)` filter is not optional — without it a PR-shaped result will be
  triaged, labelled or de-duped against as if it were an issue.
- **`labels` is a comma-separated AND.** `-f labels="a,b"` means *both*. There is no OR; for
  "any of these labels" make one call per label and union client-side, or list unlabelled and filter.

`state` is `open` / `closed` / `all`. `sort` is `created` / `updated` / `comments`; pair it with
`direction=asc|desc`. To find issues closed as **not planned**, list `state=closed` and filter on
`.state_reason == "not_planned"` — there is no query parameter for it:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/issues" \
  -f state=closed -f labels="$L" -f per_page=100 \
| jq '[.[][] | select(has("pull_request") | not)
       | select(.state_reason == "not_planned") | {number, title}]'
```

### List PRs by state, and find one by branch

`gh pr list --repo $REPO --state open --json number,headRefName,…` becomes:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/pulls" \
  -f state=open -f per_page=100 \
| jq '[.[][] | {number, title, draft, state,
                headRefName: .head.ref, headRefOid: .head.sha,
                baseRefName: .base.ref, author: .user.login,
                labels: [.labels[].name],
                createdAt: .created_at, updatedAt: .updated_at}]'
```

`/pulls` takes `state`, `head`, `base`, `sort` (`created`/`updated`/`popularity`/`long-running`),
`direction`. Recently closed PRs — `-f state=closed -f sort=updated -f direction=desc` — carry
`merged_at` (null when closed unmerged), which is how you tell a merge from an abandonment.

To ask about one branch directly — the cheap de-dup for "did a previous run already open this?" —
`head` is qualified with the owner:

```bash
gh api -X GET "repos/$REPO/pulls" -f state=all -f head="<owner>:<branch>" \
  --jq '[.[] | {number, state, merged_at}]'
```

Fields the porcelain had and REST does not: `reviewDecision`, `mergeStateStatus`,
`statusCheckRollup`, `mergeQueueEntry`, `autoMergeRequest`. See **No REST path** and
**Check runs** for what replaces each.

### Read one PR's fields

`gh pr view $N --repo $REPO --json …` becomes:

```bash
gh api "repos/$REPO/pulls/$N" \
  --jq '{number, title, body, state, draft, merged,
         mergeable, mergeable_state,
         head: .head.sha, headRef: .head.ref, base: .base.ref,
         labels: [.labels[].name], author: .user.login}'
```

`mergeable` / `mergeable_state` are **computed lazily**: the first read after a push commonly
returns `null` / `"unknown"` while GitHub works it out. Re-read after a second or two, and treat a
still-unknown value as *unknown*, never as mergeable.

The changed-file list (`--json files`) is its own paginated endpoint:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/pulls/$N/files" -f per_page=100 \
| jq '[.[][].filename] | sort'
```

Reviews and comments are plain REST already and work unchanged:
`repos/$REPO/pulls/$N/reviews` (formal reviews), `repos/$REPO/pulls/$N/comments` (inline review
comments), `repos/$REPO/issues/$N/comments` (conversation comments — a PR's conversation lives under
`/issues`, not `/pulls`).

### Check runs, in place of `statusCheckRollup`

`gh pr checks` and `--json statusCheckRollup` are both GraphQL. Read the head SHA from the PR, then:

```bash
SHA=$(gh api "repos/$REPO/pulls/$N" --jq '.head.sha')

gh api --paginate --slurp -X GET "repos/$REPO/commits/$SHA/check-runs" -f per_page=100 \
| jq '[.[].check_runs[] | {name, status, conclusion, url: .html_url}]'
```

`status` is `queued` / `in_progress` / `completed`; `conclusion` is meaningful only once
`status == "completed"` (`success`, `failure`, `neutral`, `cancelled`, `timed_out`,
`action_required`, `skipped`). **An in-progress run is not a pass.** A repo may also have legacy
commit *statuses*, which check-runs does not include — `repos/$REPO/commits/$SHA/status` returns
those with a combined `state`. Read both before concluding "CI green"; a `total_count` of 0 from
both means *no checks reported*, which is not the same as green and should be said that way.

### Timeline

Already REST, and already used that way for label-event ages:

```bash
gh api --paginate --slurp -X GET "repos/$REPO/issues/$N/timeline" -f per_page=100 \
| jq -r --arg l "$LABEL" '[.[][] | select(.event=="labeled" and .label.name==$l)] | last | .created_at'
```

### Create an issue

`gh issue create --repo $REPO --title … --label … --body …` becomes one POST. Unlike PRs, the issue
endpoint **does** take labels inline, so there is no second call and no race:

```bash
jq -n --arg t "$TITLE" --rawfile b "$BODY_FILE" --args '
  {title: $t, body: $b, labels: $ARGS.positional}' -- "$LABEL_A" "$LABEL_B" \
| gh api "repos/$REPO/issues" --input -
```

Parameters (REST `POST /repos/{owner}/{repo}/issues`): `title` (required), `body`, `labels` (array
of strings), `assignees` (array), `milestone`. The response's `.number` and `.html_url` are what you
report. Building the payload with `jq --rawfile` keeps a body containing backticks, quotes or
`$(…)` out of the shell's hands entirely.

### Create a PR

`gh pr create` is GraphQL. `POST /repos/{owner}/{repo}/pulls` is the REST form, and it takes
`title`, `head`, `base`, `body`, `draft`, `maintainer_can_modify`. Push the branch first, exactly as
before:

```bash
git push -u origin "$BRANCH"

jq -n --arg t "$TITLE" --rawfile b "$BODY_FILE" --arg h "$BRANCH" --arg base "$BASE" \
  '{title: $t, head: $h, base: $base, body: $b, draft: false}' \
| gh api "repos/$REPO/pulls" --input -
```

`head` may be the bare branch name for a same-repo branch, or `owner:branch` from a fork. The
response carries `.number` and `.html_url`.

**Labels are a separate call, and this changes the ordering some skills rely on.** There is no
`labels` field on `POST /pulls`:

```bash
gh api "repos/$REPO/issues/$PR_NUMBER/labels" -f "labels[]=$LABEL"
```

Review bots schedule their run on the `opened` webhook, within seconds — before a label posted a
moment later can land. The usual way round that is **open as a draft, label, then mark ready**,
because bots do not review drafts. In blocked mode **the last step of that sequence does not
exist** (`gh pr ready` is GraphQL-only; see below). So a skill has exactly two honest options, and
must pick deliberately and say which:

- **The label does not gate review** (a routing or ownership label, an `auto:pr` marker a bot reads
  later): create with `draft: false`, apply the label immediately after, and note in the report that
  the label landed after the `opened` webhook.
- **The label must be in place before review starts** (a review-skip label, a bot-configuration
  label): create with `draft: true`, apply the label, and then **stop**. Report the PR URL and the
  one action a human must take — click *Ready for review*, or run `gh pr ready <N> --repo $REPO`
  from an environment with GraphQL. Never leave a draft behind without saying it is a draft and why.

### Post a comment — and the `-f` vs `-F` bug

`gh issue comment` / `gh pr comment` route through GraphQL. The REST form is
`POST /repos/{owner}/{repo}/issues/{issue_number}/comments` with one `body` parameter — a PR's
conversation comment goes to `/issues/{n}/comments` too.

**`-f/--raw-field` takes its value literally.** `-f body=@comment.md` posts the seven characters
`@comment.md`, not the file. Only `-F/--field` interprets a leading `@` as a filename. That slip is
issue #63: comments were posted through a path that mangled the body, and the pipeline's own
`<!-- marker -->` came out HTML-escaped as `&lt;!-- marker --&gt;`, visible in the rendered comment
and invisible to the next run's marker check.

Two correct forms. The second is the one to reach for when the body may contain anything at all:

```bash
# Short form: -F, not -f. The @ makes gh read the file; file contents are sent as a
# JSON string and are NOT type-coerced (a file containing only `42` stays "42").
gh api "repos/$REPO/issues/$N/comments" -F body=@comment.md

# Belt and braces: build the JSON with jq, post it as the request body. Nothing the
# body contains can be reinterpreted by gh or by the shell.
jq -Rs '{body: .}' < comment.md | gh api "repos/$REPO/issues/$N/comments" --input -
```

**Reading the marker back, tolerantly.** Because escaped markers exist in history, a check for "is
the newest comment the pipeline's own?" must match both spellings, or it will read the pipeline's
own old comment as an unanswered human reply:

```bash
# $MARKER is the configured marker, e.g. '<!-- auto-dev -->'
MARKER_ESCAPED=$(printf '%s' "$MARKER" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

gh api --paginate --slurp -X GET "repos/$REPO/issues/$N/comments" -f per_page=100 \
| jq --arg m "$MARKER" --arg e "$MARKER_ESCAPED" \
     '[.[][]] | last
      | select(. != null)
      | {author: .user.login,
         mine: ((.body | contains($m)) or (.body | contains($e)))}'
```

Post the **unescaped** marker always; accept **either** when reading. New comments written through
the forms above are never escaped, so the tolerance is for history only.

### Edit labels

```bash
# Add (does not remove existing labels)
gh api "repos/$REPO/issues/$N/labels" -f "labels[]=$LABEL"

# Remove one. The name is a path segment, so it must be URL-encoded:
#   auto:in-progress -> auto%3Ain-progress   (a space -> %20)
gh api -X DELETE "repos/$REPO/issues/$N/labels/$(jq -rn --arg s "$LABEL" '$s|@uri')"

# Read the labels now on an issue or PR
gh api "repos/$REPO/issues/$N/labels" --jq '[.[].name]'

# Does a label exist in the repo at all (before trying to apply it)?
gh api --paginate --slurp -X GET "repos/$REPO/labels" -f per_page=100 | jq '[.[][].name]'
```

A DELETE for a label the issue does not carry returns 404; treat that as already-absent, not as an
error, and keep going. Creating labels remains out of scope for the skills that read this file.

### Replacing search

`gh search issues` / `gh search prs` are GraphQL, and the REST `search/issues` endpoint is refused
by the same proxies, so **there is no search in blocked mode**. Every unattended use of search must
already be expressible as a repo-scoped list plus a client-side filter — a search restricted to one
repo always is.

A body/comment sentinel search (`'sentinel:' --match body,comments`) becomes: list the candidate
issues by label and state, then, for each, fetch the body and comments and match the sentinel
locally.

```bash
gh api --paginate --slurp -X GET "repos/$REPO/issues" \
  -f state=open -f labels="$L" -f per_page=100 \
| jq -r '.[][] | select(has("pull_request") | not) | .number' \
| while read -r n; do
    body=$(gh api "repos/$REPO/issues/$n" --jq '.body // ""')
    comments=$(gh api --paginate -X GET "repos/$REPO/issues/$n/comments" -f per_page=100 \
               --jq '.[].body' | tr '\n' ' ')
    case "$body$comments" in *"$SENTINEL"*) echo "$n" ;; esac
  done
```

This costs one call per candidate, which is why the label filter matters. **State the bound you
used** in the report: "checked the sentinel across the 40 open issues carrying `<label>`" is an
honest, reproducible claim; "no holds found" after an unstated truncation is not. If the candidate
set is larger than the run's budget allows, that is a failed read — fail closed per rule 1, don't
report an empty result from a partial scan.

## No REST path — stop and report

These have no REST equivalent at all. A skill that needs one in blocked mode **does the reachable
part, then stops and reports**, naming the PR and the exact command or click a human must supply.

| Blocked operation | Why | What the skill does instead |
| --- | --- | --- |
| **Mark a PR ready for review** (`gh pr ready`) | GraphQL mutation `markPullRequestReadyForReview`. `PATCH /pulls/{n}` cannot clear `draft`. | Either never open it as a draft (**Create a PR**), or leave it a draft and report: *"PR #N is a draft; GraphQL is blocked so it cannot be marked ready here. Run `gh pr ready N --repo $REPO`, or use the Ready for review button."* Never count a draft as delivered. |
| **Enable auto-merge** (`gh pr merge --auto`) | GraphQL mutation `enablePullRequestAutoMerge`. | Stop. Report that arming is unavailable and the PR is left un-armed. A direct merge is a different act and does not substitute for a queue arming. |
| **Read merge-queue state** (`mergeQueue`, `mergeQueueEntry`, `autoMergeRequest`) | GraphQL-only; the rulesets endpoint (`repos/$REPO/rules/branches/{branch}`) sees a queue configured by *ruleset* but is blind to one configured through classic branch protection. | Fail closed to the stricter rule: an unreadable queue state means **treat the branch as queued and merge nothing there**, and say which source could not be read. Never infer "no queue" from an unreadable second source. |

A direct merge, unlike arming one, *does* have a REST form —
`PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge` with `merge_method` (`merge`/`squash`/`rebase`)
and `sha`, where `sha` is the `--match-head-commit` equivalent and makes GitHub refuse the merge if
the head moved. It is listed here only for completeness: no skill that reads this file merges
anything unattended.

## Reporting

Any run that took the REST path says so in one line — how it decided (`GH_GRAPHQL_BLOCKED`, or the
probe), which steps used a fallback, and which steps stopped for want of one. A run that silently
degrades looks exactly like a clean run, and that is the whole problem this file addresses.
