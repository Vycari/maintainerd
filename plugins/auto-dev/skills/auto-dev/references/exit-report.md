# Exit report format — auto-dev

The structured summary every tick prints. Read this when writing the report at the end of a run;
the tick logic itself never needs it.

Every tick ends by printing a structured report — it is the run's summary output (the scheduled task surfaces it; an interactive run shows it inline):

```text
auto-dev tick — <ISO timestamp>
step executed: <0-failed | 1-reconcile | 2-pr-advance | 3-build | 4-triage | 5-idle>
open auto PRs (<count>/<config.autoDev.maxPrsInFlight>): #<n> (<status>), … | none
actions:
- #123: asked 2 clarifying questions → needs-info
- #145: plan approved by reply → ready
- #151: proposed parking (design fork is the maintainer's call) → needs-info
- #152: maintainer replied "park it" → parked
- PR #210: fixed 2 CodeRabbit findings, replied to 4 threads, pushed <sha>
- PR #212: no external review after 60m — self-reviewed, fixed 1 finding (<sha>), posted fallback review
- #160: built approved plan → PR #211 (labeled auto:pr); verified via /verify (drove the new CLI flag, observed expected output) → marked ready
- #163: built approved plan → PR #212 (draft); behavioral verification not run in sandbox (needs a live DB) — flagged for manual check
blocked on human:
- PR #210 awaiting review/merge
- #145 ready to build once #210 merges
errors: <none | details>
```
