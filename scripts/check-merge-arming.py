#!/usr/bin/env python3
"""Every `gh pr merge --auto` a skill tells an agent to run must pin the head commit.

Arming GitHub auto-merge is a standing instruction: it outlives the run that set it and
merges the PR later, on whatever commit is at the head by then. `--match-head-commit <sha>`
is what bounds that — GitHub drops the request if the head moves, so the instruction can
only ever merge the commit the skill actually gated. A documented command that arms without
the pin is therefore not a typo: it is the exact unattended-merge failure the deps-flow
invariants forbid, shipped as an instruction to every installed copy.

Prose is deliberately out of scope. Skills discuss `gh pr merge --auto` by name when
explaining why it is banned, so only *fenced code blocks* — the lines an agent is being told
to run — are checked.

    python3 scripts/check-merge-arming.py            check plugins/**/*.md
    python3 scripts/check-merge-arming.py --self-test  run the fixtures only
"""

import os
import re
import sys
from glob import glob

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def code_lines(text):
    """Yield (lineno, line) for lines inside fenced code blocks."""
    opener = None  # (char, length) of the fence currently open
    for lineno, line in enumerate(text.splitlines(), 1):
        match = FENCE.match(line)
        run = match.group(1) if match else ""
        if opener is None:
            if match:
                opener = (run[0], len(run))
            continue
        # A closing fence uses the same character, is AT LEAST as long as the opener, and
        # carries no info string. A shorter run does not close a longer block — treating it
        # as a closer would drop the rest of the block out of the scan unnoticed.
        char, length = opener
        if match and run[0] == char and len(run) >= length and not line.strip()[len(run):].strip():
            opener = None
            continue
        yield lineno, line


def strip_comment(line):
    """Drop a trailing `#` comment, respecting quotes.

    `gh pr merge 5 --auto  # --match-head-commit abc` runs unpinned: the pin is a comment.
    A checker that tokenized the raw line would read it as pinned, which is the one way this
    guard could bless the exact command it exists to catch.
    """
    quote = None
    for i, char in enumerate(line):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
        elif char == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def commands(text):
    """Yield (lineno, command) for shell commands in fenced blocks, continuations joined.

    A command split over several lines with trailing backslashes is one command; checking
    the lines separately is how a pinned `--match-head-commit` on the second line would read
    as a missing one.
    """
    buf, start = "", None
    for lineno, line in code_lines(text):
        stripped = strip_comment(line).strip()
        if start is None:
            start = lineno
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        for part in buf.split(";"):
            if part.strip():
                yield start, part.strip()
        buf, start = "", None
    if buf.strip():
        yield start, buf.strip()


def violations(text):
    """Yield (lineno, command) for armings with no head pin."""
    for lineno, command in commands(text):
        if "gh pr merge" not in command:
            continue
        tokens = command.replace("=", " ").split()
        if "--auto" not in tokens:          # `--disable-auto` is a different flag, and disarms
            continue
        if "--match-head-commit" not in tokens:
            yield lineno, command


CASES = [
    # (markdown, expected number of violations)
    ("```bash\ngh pr merge 5 --squash --auto\n```\n", 1),
    ("```bash\ngh pr merge 5 --squash --auto --match-head-commit abc123\n```\n", 0),
    # Continuation lines are one command: the pin lands on the second line.
    ("```bash\ngh pr merge 5 --squash --auto \\\n  --match-head-commit abc123\n```\n", 0),
    ("```bash\ngh pr merge 5 --squash \\\n  --auto\n```\n", 1),
    # Disarming is not arming.
    ("```bash\ngh pr merge 5 --disable-auto\n```\n", 0),
    # Direct merge, no arming.
    ("```bash\ngh pr merge 5 --squash --match-head-commit abc123\n```\n", 0),
    # Prose naming the flag is not an instruction to run it.
    ("Never run `gh pr merge --auto` on a queue-less branch.\n", 0),
    # Two commands on one line: each is checked.
    ("```bash\ngh auth status; gh pr merge 5 --auto\n```\n", 1),
    # Tildes fence too, and a longer fence closes.
    ("~~~bash\ngh pr merge 5 --auto\n~~~\n", 1),
    # A shorter run does not close a longer fence: the command after it is still in the block.
    ("````markdown\n```\ngh pr merge 5 --auto\n```\n````\n", 1),
    # The pin must be a real argument, not a comment.
    ("```bash\ngh pr merge 5 --auto  # --match-head-commit abc123\n```\n", 1),
    # A `#` inside quotes is not a comment.
    ("```bash\ngh pr merge 5 --auto --match-head-commit \"abc#123\"\n```\n", 0),
    # A comment on a continued line does not swallow the rest of the command.
    ("```bash\ngh pr merge 5 --auto \\\n  --match-head-commit abc123  # pin it\n```\n", 0),
    # A closed block does not leak into the prose that follows.
    ("```bash\necho hi\n```\nThen `gh pr merge --auto` is banned.\n", 0),
]


def self_test():
    failures = []
    for i, (text, expected) in enumerate(CASES):
        got = len(list(violations(text)))
        if got != expected:
            failures.append(f"  case {i}: expected {expected} violation(s), got {got}")
    print(f"merge-arming self-test: {len(CASES) - len(failures)}/{len(CASES)} cases pass")
    for line in failures:
        print(line)
    return failures


def main():
    failures = self_test()
    if "--self-test" not in sys.argv:
        checked = 0
        for path in sorted(glob(os.path.join(ROOT, "plugins", "**", "*.md"), recursive=True)):
            checked += 1
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for lineno, command in violations(text):
                rel = os.path.relpath(path, ROOT)
                failures.append(f"  {rel}:{lineno}: arms auto-merge with no --match-head-commit: {command}")
        print(f"merge-arming: {checked} markdown files checked")

    if failures:
        print("\nFAIL", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        print(
            "\nA documented `gh pr merge --auto` must carry --match-head-commit <sha>. Without the\n"
            "pin, the standing instruction can merge a commit the skill never gated.",
            file=sys.stderr,
        )
        return 1
    print("merge-arming: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
