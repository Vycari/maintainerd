# Answering "is my PR deployed?"

A repo that sets `config.deploy.versionz` (see [`config-schema.md`](config-schema.md)) exposes a
`GET /versionz` build-report endpoint: `{"service","commit","short","image_tag","built_at",
"alembic_head","db_revision"}`. This is how a skill answers "is my PR deployed?" — by fetching
that endpoint, never by shelling into the host or reading `docker inspect`. Those are exactly the
two things the endpoint exists to make unnecessary.

## The check

1. **Resolve the template.** Read `config.deploy.versionz`. Absent or `null` → **stop** and say so:
   "no deployed-state check configured for this repo." Do not fall back to ssh or `docker
   inspect` — a repo that hasn't wired this up gets an honest "can't check," not a workaround.

2. **Substitute `{prodHost}`**, if the template contains it, from the user-level
   `~/.claude/maintainerd.json`'s `deploy.prodHost` (see config-schema.md's "User-level config").
   If the template needs it and it's missing there → **stop**, name the missing key, and say what
   to add. Don't guess a hostname.

3. **Check for loopback.** If the resolved URL's host is `127.0.0.1`, `localhost`, or otherwise
   not tailnet/internet-routable, the endpoint is **host-only**: reachable only from a shell on the
   host itself, not from this session. Print the exact command —
   ```
   curl -s http://127.0.0.1:<port>/versionz
   ```
   — for a human (or an on-host session) to run, and **stop**. This is not a failure to route
   around; a host-only endpoint is a deliberate exposure decision for that repo, not a bug in the
   check.

4. **Fetch it.** `curl -fsS --max-time 10 "<resolved-url>"` so an unreachable endpoint fails fast
   rather than hanging. A non-2xx response, a timeout, or a connection failure → **stop** and
   report "couldn't reach /versionz" with the actual error. Same rule as step 1: no ssh fallback.

5. **Parse the response.** If `commit` is `null`, the endpoint is answering from an unpublished or
   locally-built image — report "can't tell" (there's nothing to compare against), never "not
   deployed."

6. **Compare commits.** `git fetch origin`, then get the PR's merge commit (`gh pr view <n> --json
   mergeCommit -q .mergeCommit.oid`; a PR with no merge commit yet hasn't merged, so "deployed" is
   not yet a meaningful question — say that instead of checking). Then:
   ```
   git merge-base --is-ancestor <merge-sha> <commit>
   ```
   Exit `0` means the merge commit is an ancestor of (or equal to) what's running — the PR's
   changes are live. Exit `1` means it isn't — not yet deployed. Anything else (e.g. the merge
   commit isn't known locally even after fetching) is "can't tell," not "not deployed."

7. **Compare migration state**, only when both `alembic_head` and `db_revision` are present
   (non-null): equal means the database has caught up with the image; different means the image is
   running but the migration hasn't, which is its own answer ("deployed, migration pending") and
   worth reporting distinctly from a plain yes/no.

## Reporting the answer

State one of, plainly:
- **Deployed** — merge commit is an ancestor-or-equal of the running `commit`, and
  `alembic_head == db_revision` when both are present.
- **Deployed, migration pending** — commit check passes but `alembic_head != db_revision`.
- **Not yet deployed** — merge commit is not an ancestor of the running `commit`.
- **Can't tell** — any of: no `config.deploy.versionz`, a `{prodHost}` needed but not configured
  locally, the endpoint is host-only and wasn't fetched from the host, the endpoint didn't answer,
  or `commit` came back `null`. Say which one; never round this up to "not deployed" or down to
  "deployed."

Every "can't tell" and "not yet deployed" answer ends the check there — it is not a cue to reach
for ssh or `docker inspect` as a fallback. If the maintainer wants the answer badly enough to use
those, that's their call to make, not something to do silently on their behalf.
