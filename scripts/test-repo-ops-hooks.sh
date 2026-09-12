#!/usr/bin/env bash
#
# Tests for the repo-ops plugin's two PreToolUse Bash hooks:
#   plugins/repo-ops/hooks/scripts/pr-template-guard.sh
#   plugins/repo-ops/hooks/scripts/skip-label-race-guard.sh
#
# Each case feeds a PreToolUse hook JSON payload on stdin and asserts the decision the script
# renders, against a scratch repo built fresh per case (a `.claude/maintainerd.json` and a PR
# template file under a temp dir passed as the hook's `cwd`). Run from anywhere:
#
#   ./scripts/test-repo-ops-hooks.sh
#
# Requires bash, jq. No network, no git.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_GUARD="$ROOT/plugins/repo-ops/hooks/scripts/pr-template-guard.sh"
SKIP_GUARD="$ROOT/plugins/repo-ops/hooks/scripts/skip-label-race-guard.sh"

PASS=0
FAIL=0

# hook_json <command> <cwd> -> the PreToolUse payload on stdin the real harness would send
hook_json() {
  jq -n --arg cmd "$1" --arg cwd "$2" '{
    session_id: "test",
    cwd: $cwd,
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: { command: $cmd }
  }'
}

# run_guard <script> <command> <cwd> -> prints the script's stdout
run_guard() {
  local script="$1" cmd="$2" cwd="$3" out rc
  set +e
  out=$(hook_json "$cmd" "$cwd" | bash "$script" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf 'HOOK_EXIT_%s' "$rc"
    return
  fi
  printf '%s' "$out"
}

# decision <output> -> "deny" | "warn" | "none"
decision() {
  local out="$1"
  if [ -z "$out" ]; then
    printf 'none'
    return
  fi
  local d
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
  if [ -n "$d" ]; then
    printf '%s' "$d"
    return
  fi
  if printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1; then
    printf 'warn'
    return
  fi
  printf 'unparseable:%s' "$out"
}

# repo <template-md-or-empty> <maintainerd-json-or-empty> -> prints a fresh scratch repo path
repo() {
  local tmpl="$1" config="$2" dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.github" "$dir/.claude"
  if [ -n "$tmpl" ]; then
    printf '%s' "$tmpl" > "$dir/.github/PULL_REQUEST_TEMPLATE.md"
  fi
  if [ -n "$config" ]; then
    printf '%s' "$config" > "$dir/.claude/maintainerd.json"
  fi
  printf '%s' "$dir"
}

# expect <script> <expected> <label> <repo-dir> <command>
expect() {
  local script="$1" want="$2" label="$3" dir="$4" cmd="$5" out got
  out=$(run_guard "$script" "$cmd" "$dir")
  got=$(decision "$out")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %-6s %s\n' "$got" "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL want=%s got=%s  %s\n' "$want" "$got" "$label"
    printf '       command: %s\n' "$cmd"
    [ -n "$out" ] && printf '       output:  %s\n' "$out"
  fi
  rm -rf "$dir"
}

# expect_match <script> <pattern> <label> <repo-dir> <command> — asserts a deny/warn reason
# contains a substring, then cleans up the same way `expect` does.
expect_match() {
  local script="$1" pattern="$2" label="$3" dir="$4" cmd="$5" out
  out=$(run_guard "$script" "$cmd" "$dir")
  case "$out" in
    *"$pattern"*) PASS=$((PASS + 1)); printf '  ok   match  %s\n' "$label" ;;
    *)
      FAIL=$((FAIL + 1))
      printf '  FAIL match  %s\n' "$label"
      printf '       expected substring: %s\n' "$pattern"
      printf '       got:                %s\n' "$out"
      ;;
  esac
  rm -rf "$dir"
}

TEMPLATE=$'## Human overview\n\nsome text\n\n### Human required (optional)\n\n- [ ]\n\n## AI reviewer\n\nmore text\n'
CONFIG_PLAIN='{}'
CONFIG_CUSTOM_PATH='{"paths": {"prTemplate": "docs/custom-template.md"}}'
CONFIG_SKIP_LABEL='{"review": {"skipLabel": "greptile:skip"}}'
CONFIG_SKIP_LABEL_SPACED='{"review": {"skipLabel": "skip review"}}'

echo "== every hook script emits valid JSON or nothing, on an unrelated command =="
for s in "$TEMPLATE_GUARD" "$SKIP_GUARD"; do
  d=$(repo "$TEMPLATE" "$CONFIG_PLAIN")
  out=$(run_guard "$s" "echo hello" "$d")
  if [ -z "$out" ]; then
    PASS=$((PASS + 1)); printf '  ok   none   %s ignores an unrelated command\n' "$(basename "$s")"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s spoke up on an unrelated command: %s\n' "$(basename "$s")" "$out"
  fi
  rm -rf "$d"
done

echo
echo "== pr-template-guard: skip silently — not applicable =="
expect "$TEMPLATE_GUARD" none "gh pr create with no --body at all" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --draft'
expect "$TEMPLATE_GUARD" none "gh pr edit that doesn't touch the body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr edit 42 --add-label bug'
expect "$TEMPLATE_GUARD" none "a repo with no PR template at all" \
  "$(repo "" "$CONFIG_PLAIN")" 'gh pr create --title x --body "no headings here"'
expect "$TEMPLATE_GUARD" none "a repo with no .claude/maintainerd.json, falling back to .github default" \
  "$(repo "$TEMPLATE" "")" 'gh pr create --title x --body "## Human overview
stuff

## AI reviewer
more"'

echo
echo "== pr-template-guard: the happy path — every required heading present =="
expect "$TEMPLATE_GUARD" none "both required headings present, optional one omitted" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
stuff

## AI reviewer
more"'
expect "$TEMPLATE_GUARD" none "the optional heading is also present — still fine" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
stuff

### Human required (optional)

- [ ] nothing

## AI reviewer
more"'
expect "$TEMPLATE_GUARD" none "extra headings beyond the template are not a problem" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
stuff

## AI reviewer
more

## Extra Section
nobody asked for this but it is fine"'
expect "$TEMPLATE_GUARD" none "single-quoted --body form" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body '"'"'## Human overview
stuff

## AI reviewer
more'"'"''
echo
echo "== pr-template-guard: --body-file is read relative to cwd =="
d=$(repo "$TEMPLATE" "$CONFIG_PLAIN")
printf '## Human overview\nstuff\n\n## AI reviewer\nmore\n' > "$d/body.md"
expect "$TEMPLATE_GUARD" none "a complete body from --body-file" "$d" "gh pr create --title x --body-file body.md"
d=$(repo "$TEMPLATE" "$CONFIG_PLAIN")
printf '## Human overview\nonly this one\n' > "$d/body.md"
expect "$TEMPLATE_GUARD" deny "an incomplete body from --body-file" "$d" "gh pr create --title x --body-file body.md"

echo
echo "== pr-template-guard: the heredoc form =="
CMD_HEREDOC_OK='gh pr create --title "x" --body "$(cat <<'"'"'EOF'"'"'
## Human overview
stuff

## AI reviewer
more
EOF
)"'
expect "$TEMPLATE_GUARD" none "--body \"\$(cat <<'EOF' ... EOF)\" with both headings" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" "$CMD_HEREDOC_OK"

CMD_HEREDOC_MISSING='gh pr create --title "x" --body "$(cat <<'"'"'EOF'"'"'
## Human overview
stuff only, no second heading
EOF
)"'
expect "$TEMPLATE_GUARD" deny "same heredoc form, missing the second heading" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" "$CMD_HEREDOC_MISSING"

echo
echo "== pr-template-guard: missing headings are denied, and named =="
expect "$TEMPLATE_GUARD" deny "missing the AI reviewer heading" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
only this"'
expect_match "$TEMPLATE_GUARD" "## AI reviewer" "the missing heading is named verbatim in the denial" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
only this"'
expect_match "$TEMPLATE_GUARD" ".github/PULL_REQUEST_TEMPLATE.md" "the denial names the template path" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
only this"'
expect "$TEMPLATE_GUARD" deny "missing both required headings" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "nothing here at all"'
expect "$TEMPLATE_GUARD" deny "gh pr edit --body missing a heading is checked the same way" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr edit 7 --body "## Human overview
only this"'
expect "$TEMPLATE_GUARD" deny "a wrong heading LEVEL does not count as the same heading" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "### Human overview
wrong level

## AI reviewer
ok"'

echo
echo "== pr-template-guard: config.paths.prTemplate overrides the .github default =="
d=$(mktemp -d); mkdir -p "$d/.claude" "$d/docs" "$d/.github"
printf '## Only Section\n' > "$d/docs/custom-template.md"
printf '## Human overview\n\n## AI reviewer\n' > "$d/.github/PULL_REQUEST_TEMPLATE.md"
printf '%s' "$CONFIG_CUSTOM_PATH" > "$d/.claude/maintainerd.json"
expect "$TEMPLATE_GUARD" none "the custom template's own heading is satisfied" "$d" \
  'gh pr create --title x --body "## Only Section
hi"'
d=$(mktemp -d); mkdir -p "$d/.claude" "$d/docs" "$d/.github"
printf '## Only Section\n' > "$d/docs/custom-template.md"
printf '## Human overview\n\n## AI reviewer\n' > "$d/.github/PULL_REQUEST_TEMPLATE.md"
printf '%s' "$CONFIG_CUSTOM_PATH" > "$d/.claude/maintainerd.json"
expect "$TEMPLATE_GUARD" deny "the .github template's headings are NOT what's checked once configured" "$d" \
  'gh pr create --title x --body "no headings"'

echo
echo "== pr-template-guard: fenced code blocks don't count as headings (either side) =="
expect "$TEMPLATE_GUARD" deny "a ## inside a fenced block in the BODY does not satisfy the real heading" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body '"'"'## Human overview
stuff

```
## AI reviewer
```
'"'"''
d=$(mktemp -d); mkdir -p "$d/.claude" "$d/.github"
printf '## Human overview\n\n```\n## AI reviewer\n```\n' > "$d/.github/PULL_REQUEST_TEMPLATE.md"
printf '%s' "$CONFIG_PLAIN" > "$d/.claude/maintainerd.json"
expect "$TEMPLATE_GUARD" none "a ## inside a fenced block in the TEMPLATE is not a required heading either" "$d" \
  'gh pr create --title x --body "## Human overview
stuff"'

echo
echo "== pr-template-guard: FALSE POSITIVES that must NOT trigger =="
expect "$TEMPLATE_GUARD" none "gh pr create written inside a heredoc that builds another script" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" "cat > deploy.sh <<'EOF'
#!/bin/bash
gh pr create --body \"## Human overview only\"
EOF
chmod +x deploy.sh"
expect "$TEMPLATE_GUARD" none "an echo that only mentions gh pr create --body as text" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'echo "reminder: run gh pr create --body \"only one heading\" later"'
expect "$TEMPLATE_GUARD" none "a gh issue create --body that only mentions gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh issue create --body "saw a bad PR: gh pr create --body \"only one heading\""'

echo
echo "== pr-template-guard: a compound command validates the RIGHT invocation's body =="
expect "$TEMPLATE_GUARD" none "a preceding, unrelated gh issue create's incomplete body is not read as the PR's" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh issue create --body "no headings here" && gh pr create --body "## Human overview
x

## AI reviewer
y"'
expect "$TEMPLATE_GUARD" deny "the PR's own incomplete body is still caught even with a complete body earlier on the line" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh issue create --body "## Human overview
x

## AI reviewer
y" && gh pr create --body "## Human overview
just this"'
expect_match "$TEMPLATE_GUARD" "## AI reviewer" "and names only the heading actually missing from the PR's own body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh issue create --body "## Human overview
x

## AI reviewer
y" && gh pr create --body "## Human overview
just this"'

echo
echo "== pr-template-guard: each gh pr create in a compound command is checked on its OWN body =="
expect "$TEMPLATE_GUARD" deny "first complete, second incomplete -> denies on the second" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
x

## AI reviewer
y" && gh pr create --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "first incomplete, second complete -> still denies (the first is not silently skipped)" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
only" && gh pr create --body "## Human overview
x

## AI reviewer
y"'
expect "$TEMPLATE_GUARD" none "both complete -> silent" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
x

## AI reviewer
y" && gh pr create --body "## Human overview
a

## AI reviewer
b"'
expect "$TEMPLATE_GUARD" none "a bodyless gh pr create is not backfilled with a LATER, unrelated gh command's --body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --draft && gh pr comment 1 --body "## Human overview
only"'

echo
echo "== pr-template-guard: wrapped/invoked-by-path gh still triggers the check =="
expect "$TEMPLATE_GUARD" deny "command gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'command gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "env gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'env gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "an absolute path to gh" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" '/usr/bin/gh pr create --title x --body "## Human overview
only"'

echo
echo "== pr-template-guard: unresolved shell content warns instead of guessing =="
expect "$TEMPLATE_GUARD" warn "a --body built from a bare variable is not denied on a guess" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "$BODY"'
expect "$TEMPLATE_GUARD" warn "a double-quoted body containing a \$ expansion is not denied on a guess" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
cost is $VALUE

## AI reviewer
ok"'
expect "$TEMPLATE_GUARD" none "the same content is fine once single-quoted (no expansion happens)" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body '"'"'## Human overview
cost is $VALUE literally

## AI reviewer
ok'"'"''
expect "$TEMPLATE_GUARD" warn "an unquoted heredoc delimiter allows expansion, so it is not trusted either" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title "x" --body "$(cat <<EOF
## Human overview
cost is $VALUE

## AI reviewer
ok
EOF
)"'

echo
echo "== skip-label-race-guard: no key configured, ever silent regardless of label/draft =="
expect "$SKIP_GUARD" none "skipLabel absent from config" \
  "$(repo "" "$CONFIG_PLAIN")" 'gh pr create --title x --label greptile:skip --body y'
expect "$SKIP_GUARD" none "no .claude/maintainerd.json at all" \
  "$(repo "" "")" 'gh pr create --title x --label greptile:skip --body y'

echo
echo "== skip-label-race-guard: warns on the race, never denies =="
expect "$SKIP_GUARD" warn "the configured skip label, no --draft" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label greptile:skip --body y'
expect "$SKIP_GUARD" warn "the label quoted" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label "greptile:skip" --body y'
expect "$SKIP_GUARD" warn "the -l shorthand" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x -l greptile:skip --body y'
expect_match "$SKIP_GUARD" "--draft" "the warning names the draft-then-ready fix" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label greptile:skip --body y'

echo
echo "== skip-label-race-guard: no warning when the race can't happen, or doesn't apply =="
expect "$SKIP_GUARD" none "the same label, but --draft is present" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --draft --label greptile:skip --body y'
expect "$SKIP_GUARD" none "a different label entirely" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label bug --body y'
expect "$SKIP_GUARD" none "gh pr edit is not gh pr create — no opened-webhook race to warn about" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr edit 5 --add-label greptile:skip'
expect "$SKIP_GUARD" none "an unrelated command" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr list'

echo
echo "== skip-label-race-guard: only THIS invocation is read, not the whole payload =="
expect "$SKIP_GUARD" none "an echo that only mentions the label as text" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'echo "run: gh pr create --label greptile:skip"'
expect "$SKIP_GUARD" none "gh pr create written inside a heredoc that builds another script" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" "cat > deploy.sh <<'EOF'
gh pr create --label greptile:skip --body x
EOF
chmod +x deploy.sh"
expect "$SKIP_GUARD" warn "a --draft mentioned only in a PRECEDING, unrelated command's --body does not suppress a real warning" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr comment 1 --body "please use --draft next time" && gh pr create --title x --label greptile:skip --body y'
expect "$SKIP_GUARD" warn "wrapped: command gh pr create" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'command gh pr create --title x --label greptile:skip --body y'

echo
echo "== skip-label-race-guard: a quoted, space-containing label is matched in full =="
expect "$SKIP_GUARD" warn "a configured label containing a space is not truncated at the space" \
  "$(repo "" "$CONFIG_SKIP_LABEL_SPACED")" 'gh pr create --title x --label "skip review" --body y'
expect "$SKIP_GUARD" none "a label that only partially matches (truncated form) is not a false positive either" \
  "$(repo "" "$CONFIG_SKIP_LABEL_SPACED")" 'gh pr create --title x --label "skip" --body y'

echo
echo "== pr-template-guard: EVERY gh pr create/edit in a compound command is checked =="
expect "$TEMPLATE_GUARD" deny "a SECOND gh pr create with an incomplete body is caught, not just the first" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
x

## AI reviewer
y" && gh pr create --body "## Human overview
just this"'
expect "$TEMPLATE_GUARD" deny "a FIRST incomplete body is still caught when a later one is complete" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
just this" && gh pr create --body "## Human overview
x

## AI reviewer
y"'
expect_match "$TEMPLATE_GUARD" "and another" "two bad bodies in one command are both reported" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
just this" ; gh pr edit 4 --body "nothing at all"'
expect "$TEMPLATE_GUARD" none "two complete bodies in one command are both fine" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
x

## AI reviewer
y" && gh pr edit 4 --body "## Human overview
x

## AI reviewer
y"'
expect "$TEMPLATE_GUARD" none "a LATER non-PR command's incomplete body is not attributed to the PR" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
x

## AI reviewer
y" && gh issue create --body "no headings here"'
expect "$TEMPLATE_GUARD" deny "commands separated by a newline are separate invocations" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'git push
gh pr create --body "## Human overview
just this"'
expect "$TEMPLATE_GUARD" deny "a piped gh pr create is still checked" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --body "## Human overview
just this" | tee /dev/null'
expect "$TEMPLATE_GUARD" deny "a gh pr create inside a subshell is still checked" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" '(gh pr create --body "## Human overview
just this")'

expect "$TEMPLATE_GUARD" deny "a heredoc EARLIER in the command does not shift a later gh pr create out of alignment" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" "cat > notes.md <<'EOF'
## Human overview
## AI reviewer
EOF
gh pr create --body \"## Human overview
just this\""

echo
echo "== pr-template-guard: more wrapper forms resolve to the same executable =="
expect "$TEMPLATE_GUARD" deny "exec gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'exec gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "command -p gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'command -p gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "env with an assignment before gh" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'env GH_HOST=github.com gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "a bare VAR=value assignment before gh" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'GH_HOST=github.com gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "a relative path to gh" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" './bin/gh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" none "a DIFFERENT executable whose name merely ends in gh is not gh" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'mygh pr create --title x --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" none "an echo whose quoted text contains operators and a gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'echo "run: git push && gh pr create --body \"only one heading\"; done"'

echo
echo "== pr-template-guard: shell keywords and quoted assignments don't hide the invocation =="
expect "$TEMPLATE_GUARD" deny "if gh pr create ...; then" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'if gh pr create --body "## Human overview
only"; then echo opened; fi'
expect "$TEMPLATE_GUARD" deny "! gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" '! gh pr create --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "while gh pr create ...; do" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'while gh pr create --body "## Human overview
only"; do break; done'
expect "$TEMPLATE_GUARD" deny "time gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'time gh pr create --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "an assignment whose QUOTED value contains a space" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'GH_PAGER="less -R" gh pr create --body "## Human overview
only"'

echo
echo "== pr-template-guard: flag-shaped text in the invocation's own prose is not a flag =="
expect "$TEMPLATE_GUARD" deny "a --title that merely mentions --body-file does not hijack extraction" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title "fix --body-file parsing" --body "## Human overview
only"'
expect "$TEMPLATE_GUARD" none "a COMPLETE body that mentions --body-file in its prose is still fine" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "## Human overview
we now parse --body-file too

## AI reviewer
yes"'

echo
echo "== skip-label-race-guard: body prose is prose, not flags =="
expect "$SKIP_GUARD" warn "a --draft mentioned inside this invocation's own body does not suppress the warning" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label greptile:skip --body "reviewer asked: please use --draft next time"'
expect "$SKIP_GUARD" none "a --label mentioned inside the body applies no label, so there is nothing to warn about" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --body "next time pass --label greptile:skip"'
expect "$SKIP_GUARD" warn "if gh pr create ...; then, with the skip label" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'if gh pr create --label greptile:skip --title x; then echo ok; fi'
expect "$SKIP_GUARD" warn "an assignment with a quoted, spaced value before gh" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'GH_PAGER="less -R" gh pr create --label greptile:skip --title x'

echo
echo "== gh's own short flags count too (-b, -F, -d, -l, and bundles) =="
expect "$TEMPLATE_GUARD" deny "-b shorthand for --body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -t x -b "## Human overview
only"'
expect "$TEMPLATE_GUARD" none "-b shorthand carrying a complete body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -t x -b "## Human overview
a

## AI reviewer
b"'
d=$(repo "$TEMPLATE" "$CONFIG_PLAIN")
printf '## Human overview\nonly this one\n' > "$d/body.md"
expect "$TEMPLATE_GUARD" deny "-F shorthand for --body-file" "$d" 'gh pr create -t x -F body.md'
expect "$TEMPLATE_GUARD" deny "a short-option bundle whose last flag is -b" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -db "## Human overview
only"'
expect "$TEMPLATE_GUARD" deny "time -p gh pr create" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'time -p gh pr create --body "## Human overview
only"'
expect "$SKIP_GUARD" none "-d shorthand for --draft suppresses the warning" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -d --label greptile:skip --title x'
expect "$SKIP_GUARD" none "a -dl bundle is both a draft and a label" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -dl greptile:skip --title x'
expect "$SKIP_GUARD" warn "an ATTACHED short label value (-lvalue)" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -lgreptile:skip --title x'
expect "$SKIP_GUARD" none "-tl VALUE is a --title of \"l\", not a label — gh's own rule" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -tl greptile:skip'
expect "$SKIP_GUARD" warn "time -p gh pr create with the skip label" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'time -p gh pr create --label greptile:skip --title x'

echo
echo "== attached short-option values: the value eats the rest of the word (gh's own rule) =="
expect "$TEMPLATE_GUARD" deny "-b with an ATTACHED quoted body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -t x -b"## Human overview
only"'
expect "$TEMPLATE_GUARD" none "-b with an attached COMPLETE body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -t x -b"## Human overview
a

## AI reviewer
b"'
d=$(repo "$TEMPLATE" "$CONFIG_PLAIN")
printf '## Human overview\nonly this one\n' > "$d/body.md"
expect "$TEMPLATE_GUARD" deny "-F with an attached path (-Fbody.md)" "$d" 'gh pr create -t x -Fbody.md'
expect "$TEMPLATE_GUARD" deny "a -db bundle with an attached body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -db"## Human overview
only"'
expect "$TEMPLATE_GUARD" none "-tbTitle is a TITLE whose value happens to contain b, not a body" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create -tbTitle --draft'
expect "$SKIP_GUARD" warn "-tDraftTitle is a title, not a --draft, so the warning still fires" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -tDraftTitle --label greptile:skip'
expect "$SKIP_GUARD" none "a real -d alongside an attached title value containing d" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -d -tDraftTitle --label greptile:skip'
expect "$SKIP_GUARD" warn "-l=value form" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create -l=greptile:skip --title x'

echo
echo "== both guards fail LOUDLY, not silently, if the shared scanner is missing =="
NOLIB=$(mktemp -d)
cp "$TEMPLATE_GUARD" "$SKIP_GUARD" "$NOLIB/"
expect "$NOLIB/pr-template-guard.sh" warn "pr-template-guard warns rather than silently skipping the check" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'gh pr create --title x --body "no headings here"'
expect "$NOLIB/skip-label-race-guard.sh" warn "skip-label-race-guard warns rather than silently skipping the check" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label greptile:skip --body y'
expect "$NOLIB/pr-template-guard.sh" none "...and still says nothing at all on a command with no gh in it" \
  "$(repo "$TEMPLATE" "$CONFIG_PLAIN")" 'echo hello'
rm -rf "$NOLIB"

echo
echo "== skip-label-race-guard: every gh pr create is checked, and labels parse in full =="
expect "$SKIP_GUARD" warn "a SECOND, undrafted gh pr create is caught even when the first is a draft" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --draft --label greptile:skip --title a && gh pr create --label greptile:skip --title b'
expect "$SKIP_GUARD" none "both gh pr creates are drafts — nothing to warn about" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --draft --label greptile:skip --title a && gh pr create --draft --label greptile:skip --title b'
expect "$SKIP_GUARD" warn "a comma-separated --label list containing the skip label" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label bug,greptile:skip --body y'
expect "$SKIP_GUARD" warn "a quoted comma-separated list containing the skip label" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label "bug,greptile:skip" --body y'
expect "$SKIP_GUARD" warn "the skip label in the SECOND of two repeated --label flags" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label bug --label greptile:skip --body y'
expect "$SKIP_GUARD" warn "--label=value form" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'gh pr create --title x --label=greptile:skip --body y'
expect "$SKIP_GUARD" warn "a spaced label repeated after another label" \
  "$(repo "" "$CONFIG_SKIP_LABEL_SPACED")" 'gh pr create --title x --label bug --label "skip review" --body y'
expect "$SKIP_GUARD" none "a comma list that only contains a prefix of the skip label" \
  "$(repo "" "$CONFIG_SKIP_LABEL_SPACED")" 'gh pr create --title x --label "skip,review" --body y'
expect "$SKIP_GUARD" none "an echo mentioning the label, next to a real DRAFTED create" \
  "$(repo "" "$CONFIG_SKIP_LABEL")" 'echo "gh pr create --label greptile:skip" && gh pr create --draft --label greptile:skip --title a'

echo
printf '%s\n' "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
