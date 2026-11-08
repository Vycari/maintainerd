# `audits.extraPrLabels`: extra labels on audit PRs

`config.audits.extraPrLabels` (default `[]`) lists labels every audit applies to every **PR** it
opens, alongside its category label and `config.labels.automated`. Issues never get them. The
usual entry is a label that hands the PR to downstream automation, such as `foreman:watch`.

Every audit that opens PRs follows the same three rules.

1. **Check they exist, once per run, before the first PR.** Run
   `gh api "repos/<config.repo>/labels" --paginate --jq '.[].name'` and drop any
   `extraPrLabels` entry it does not list. Name each dropped label once in the run report. Never
   create a label. If the read itself fails (non-zero exit, an error body, or no output at all),
   that is not an empty list: fail closed per rule 1 of
   [`gh-rest-fallbacks.md`](gh-rest-fallbacks.md). Apply none of the extra labels, open PRs with
   the category labels only, and report "extra labels not applied: label check failed", never
   that the labels are missing. This matters for three reasons: `gh pr create --label` fails outright on an
   unknown name after the branch is already pushed; a single `gh pr edit --add-label …` fails as a
   whole, so one missing name would also cost the category and `automated` labels; and the REST
   `POST /issues/{n}/labels` call **creates** a missing label as a side effect.
2. **Apply the survivors wherever the category label is applied**: the `gh pr create` call, the
   follow-up `gh pr edit`, or the REST labels call in
   [`gh-rest-fallbacks.md`](gh-rest-fallbacks.md). When the skill delegates to `create-pr`, tell
   it to apply them on its own create call, exactly as it applies the category labels.
3. **Ordering on the REST fallback.** These are routing labels, not review-gating ones: `foreman`
   finds watched PRs by listing open PRs that carry the label on every tick, not from the
   `opened` webhook, so a label that lands a moment after `opened` is still picked up. Create the
   PR non-draft and label it immediately after. If a repo puts a label here that a review bot
   reads at open time, it belongs in the draft-then-stop branch of that reference instead, and
   this key is the wrong place for it.
