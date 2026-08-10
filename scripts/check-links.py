#!/usr/bin/env python3
"""Verify every relative markdown link in plugins/ resolves — in BOTH layouts.

A skill can only reach files inside its own plugin. Links that climb out resolve in
this source tree but break once installed, because the installed layout interposes a
version segment and uses the plugin *name* rather than the source directory name:

    source:     plugins/audits/skills/audit-tests/SKILL.md
    installed:  <cache>/maintainerd/audits/0.1.0/skills/audit-tests/SKILL.md

So checking the source tree alone is not enough — that is exactly how 28 dead links
shipped. This checks the source tree, rebuilds the installed layout in a temp dir and
checks that too, and rejects any link that crosses a plugin boundary.
"""

import json
import os
import re
import shutil
import sys
import tempfile
from glob import glob

TITLE = re.compile(r'^(\S+)\s+["\'(].*$')
# Anything with a URI scheme (`ftp:`, `custom+v1:`) or network-relative (`//host/x`) is not a
# path on disk. A bare relative path can't match: it would need a ':' before any '/'.
REMOTE = re.compile(r"^(?://|[A-Za-z][A-Za-z0-9+.\-]*:)")
# Any linked file, not just markdown — the schema links its example .json configs as siblings.
CHECKED = (".md", ".json", ".sh", ".py", ".yml", ".yaml")
# CommonMark lets a destination escape ASCII punctuation: `foo\).md` is the file `foo).md`.
UNESCAPE = re.compile(r"\\([!-/:-@\[-`{-~])")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def split_unescaped(text, delimiters):
    """Return `text` up to the first *unescaped* delimiter, escapes still intact."""
    out = []
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\" and i + 1 < len(text):
            out.append(char)
            out.append(text[i + 1])
            i += 2
            continue
        if char in delimiters:
            break
        out.append(char)
        i += 1
    return "".join(out)


def destinations(line):
    """Yield raw destinations from `](...)` spans.

    Hand-scanned rather than regexed because the forms a regex gets wrong —
    `](<path with spaces.md>)`, `](foo(1).md)`, `](foo\\).md)` — all fail by
    *truncating* the destination, and a truncated target no longer ends in a checked
    extension, so it is silently dropped instead of reported. A dropped link reads
    exactly like a passing one, which is the failure this whole script exists to
    prevent. Escapes are preserved here and decoded once delimiters are stripped.
    """
    i = 0
    while True:
        start = line.find("](", i)
        if start < 0:
            return
        j = start + 2
        if j < len(line) and line[j] == "<":  # angle-bracket form: ](<dest>)
            end, buf = j + 1, []
            while end < len(line) and line[end] != ">":
                if line[end] == "\\" and end + 1 < len(line):
                    buf.append(line[end])
                    end += 1
                buf.append(line[end])
                end += 1
            if end >= len(line):  # unterminated — not a link span
                i = j
                continue
            yield "".join(buf)
            i = end + 1
            continue
        depth, buf = 1, []  # bare form: scan to the matching ')', allowing nested pairs
        while j < len(line):
            char = line[j]
            if char == "\\" and j + 1 < len(line):  # an escaped ')' is part of the path
                buf.append(char)
                buf.append(line[j + 1])
                j += 2
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
            buf.append(char)
            j += 1
        if depth:  # unbalanced — not a link span; resume past this ']('
            i = start + 2
            continue
        yield "".join(buf)
        i = j + 1


# A prose cross-reference to a section by name: `see **X**`, `**X** below/above`, `**X** section`.
#
# Two forms, chosen by measurement rather than intuition. `see **X**` is a reliable signal — it
# produced zero false positives across this repo. `in the **X**` is not, and was dropped: every one
# of its 10 hits was ordinary emphasis ("in the **audits** plugin", "in the **stale** bucket").
# The second form catches a trailing locator without needing "see".
#
# The first form must stay locator-optional. The bug this check exists for read
# `see **Overlap & isolation**)` — no locator — so a rule requiring one misses precisely the
# regression it was written to catch.
#
# Backticked spans are excluded: here they are config keys like `config.commands.lint`, never
# section names.
XREF = re.compile(
    r"see\s+(?:the\s+)?\*\*([^*]{3,60})\*\*"          # see **X** / see the **X**
    r"|\*\*([^*]{3,60})\*\*[\s,]+(?:section\b|below\b|above\b)"  # **X** below / above / section
)
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$")
# A fence opens with a run of >=3 backticks or tildes and closes only with a run of the SAME
# character, at least as long, carrying no info string. Toggling on either delimiter lets a `~~~`
# inside a ``` block close it early, after which the real closing ``` re-opens one — anchors and
# references on both sides of that point then land in the wrong bucket.
FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*(\S*)")
# A code span is a run of N backticks closed by a run of EXACTLY N. Two ways to get this wrong,
# and they fail in opposite directions:
#   - matching only single backticks leaves ``see **X**`` half-stripped, turning a literal
#     example into a reported reference (false positive);
#   - matching a run non-maximally lets the first backtick of a longer closing run close a
#     shorter opening one, so `see **X**`` — not a code span at all, per CommonMark — gets
#     stripped and the reference inside it silently disappears (false negative).
# The lookarounds pin both delimiters to maximal runs, which is what makes the run lengths
# comparable in the first place.
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)")


def prose_lines(path):
    """Yield (lineno, line) for prose only: fenced blocks skipped, code spans blanked.

    Both directions matter. A fenced block showing a comment template contains real
    `## Headings` that are examples, not anchors — harvesting them makes the checker *more*
    permissive and can hide a genuinely stale reference (measured: `## Fallback review` inside
    fallback-review.md's template was being registered as an anchor). And an inline span
    written as a literal example is documentation, not a reference, so scanning it would
    invent a failure.
    """
    fence = None  # (delimiter char, opening run length) while open
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            m = FENCE.match(line)
            if m:
                run, info = m.group(1), m.group(2)
                if fence is None:
                    fence = (run[0], len(run))
                elif run[0] == fence[0] and len(run) >= fence[1] and not info:
                    fence = None
                continue
            if fence:
                continue
            yield lineno, CODE_SPAN.sub(" ", line)
# These docs mark subsections with a bold lead-in as often as with a heading —
# `**Fallback self-review** (when CodeRabbit can't keep up)` is a section in every sense that
# matters to a reader. Treating those as anchors too is what keeps the check honest rather than
# merely strict: a reference to one is not stale, and only genuinely vanished text gets reported.
LEAD_IN = re.compile(r"^\s*(?:[-*+]\s+|\d+\.\s+)?\*\*([^*]{3,60})\*\*")


def normalize(text):
    """Normalize an anchor or reference name for comparison."""
    return re.sub(r"[*`]", "", text).strip().lower()


def headings(path):
    """Anchor texts in a file: real headings plus bold subsection lead-ins."""
    out = set()
    for _, line in prose_lines(path):
        for pat in (HEADING, LEAD_IN):
            m = pat.match(line)
            if m:
                out.add(normalize(m.group(1)))
    return out


def stale_refs(path):
    """Yield (lineno, name) for prose references in `path` naming no anchor in `path`.

    The single implementation behind both the repo scan and the self-test — a self-test that
    reimplements the rule tests a copy, and the copy is what stays correct.
    """
    reachable = headings(path)
    for lineno, line in prose_lines(path):
        for m in XREF.finditer(line):
            name = (m.group(1) or m.group(2)).strip()
            # Exact match after normalization. Substring matching was the first attempt and it
            # swallows the failure it exists to report: `see **Isolation**` resolved happily
            # against `## Overlap & isolation`, an anchor nobody can navigate to.
            if normalize(name) not in reachable:
                yield lineno, name


def check_prose_refs():
    """Report `see **Section**` references whose target heading doesn't exist.

    Links are validated elsewhere; this catches the other half. When a section is moved into
    a reference file, prose that named it goes stale silently — the words still read fine and
    no link is broken, so nothing flags it. That is exactly how the auto-dev split left
    `see **Overlap & isolation**` pointing at a section that no longer existed.

    Resolution is **same-file only**, deliberately. Counting headings from every file this one
    links to was the first attempt and it silently defeated the check: SKILL.md links to
    scheduling.md from its reference index, so `see **Overlap & isolation**` anywhere in the file
    looked resolvable — the exact bug, reported clean. A bare section name only means something
    within one document. If the content moved, the sentence should name a link instead, and once
    it does it is no longer a bare prose reference and no longer matches.
    """
    stale = []
    for md in sorted(glob(os.path.join(ROOT, "plugins", "**", "*.md"), recursive=True)):
        for lineno, name in stale_refs(md):
            stale.append(f"  {os.path.relpath(md, ROOT)}:{lineno} -> **{name}** (no such heading)")
    print(f"prose cross-references: {len(stale)} stale")
    return stale


def links(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for raw in destinations(line):
                target = raw.strip()
                title = TITLE.match(target)
                if title:
                    target = title.group(1)
                # Only an *unescaped* '#'/'?' is a fragment/query delimiter; `foo\#a.md`
                # is a filename. Decode escapes afterwards, to the real path on disk.
                target = UNESCAPE.sub(r"\1", split_unescaped(target, "#?"))
                if not target or REMOTE.match(target):
                    continue
                if target.endswith(CHECKED):
                    yield lineno, target


def check_tree(base, label, files=None):
    """Report links that fail to resolve. Scans `base` recursively unless `files` is given."""
    broken = []
    count = 0
    for md in files if files is not None else glob(os.path.join(base, "**", "*.md"), recursive=True):
        for lineno, target in links(md):
            count += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(md), target))
            if not os.path.exists(resolved):
                broken.append(f"  {os.path.relpath(md, base)}:{lineno} -> {target}")
    print(f"{label}: checked {count} links, {len(broken)} broken")
    return broken


def repo_docs():
    """Markdown outside plugins/ — the root README and docs/.

    These were unchecked until the plugin READMEs gave the root README something to link to.
    They get resolution checking only: the plugin-boundary rule is meaningless here, since a
    repo-root file is never installed and is *expected* to point into plugins/.
    """
    found = [os.path.join(ROOT, "README.md")]
    found += sorted(glob(os.path.join(ROOT, "docs", "**", "*.md"), recursive=True))
    return [f for f in found if os.path.exists(f)]


def check_boundaries():
    """Report links that leave their own plugin — these break once installed."""
    escapes = []
    for md in glob(os.path.join(ROOT, "plugins", "**", "*.md"), recursive=True):
        rel = os.path.relpath(md, ROOT)
        plugin = rel.split(os.sep)[1]
        for lineno, target in links(md):
            resolved = os.path.relpath(
                os.path.normpath(os.path.join(os.path.dirname(md), target)), ROOT
            )
            parts = resolved.split(os.sep)
            if parts[0] != "plugins" or parts[1] != plugin:
                escapes.append(f"  {rel}:{lineno} -> {target}")
    print(f"plugin boundaries: {len(escapes)} link(s) escape their plugin")
    return escapes


def build_install_layout(dest):
    """Mirror how the marketplace installs plugins: <plugin-name>/<version>/."""
    for manifest in glob(os.path.join(ROOT, "plugins", "*", ".claude-plugin", "plugin.json")):
        src = os.path.dirname(os.path.dirname(manifest))
        with open(manifest, encoding="utf-8") as fh:
            meta = json.load(fh)
        # A manifest without a version installs under "unknown/", so never assume a number.
        shutil.copytree(src, os.path.join(dest, meta["name"], meta.get("version", "unknown")))


# (line, expected target or None if it must be skipped). Every case here is a form that
# silently vanished from an earlier version of this script rather than failing loudly.
PARSER_CASES = [
    ("[a](config-schema.md)", "config-schema.md"),
    ("[a](config-schema.md#section)", "config-schema.md"),
    ("[a](config-schema.md?raw=1)", "config-schema.md"),
    ('[a](config-schema.md "Title")', "config-schema.md"),
    ("[a](<config-schema.md>)", "config-schema.md"),
    ("[a](<path with spaces.md>)", "path with spaces.md"),
    ("[a](foo(1).md)", "foo(1).md"),
    (r"[a](foo\).md)", "foo).md"),
    (r"[a](foo\#archive.md)", "foo#archive.md"),
    (r"[a](foo\?draft.md)", "foo?draft.md"),
    (r"[a](<foo\>bar.md>)", "foo>bar.md"),
    ("[a](../../references/model-tiers.md#tiers)", "../../references/model-tiers.md"),
    ("[a](https://example.com/x.md)", None),
    ("[a](//example.test/file.py)", None),
    ("[a](ftp://example.test/file.py)", None),
    ("[a](custom+v1://example.test/file.py)", None),
    ("[a](mailto:someone@example.com)", None),
    ("[a](#local)", None),
    ("[a](../sibling)", None),  # no checked extension
]


# (markdown body, expected stale reference names). Each case is a form that a previous
# iteration of check_prose_refs() got wrong.
PROSE_CASES = [
    ("## Overlap & isolation\n\nsee **Overlap & isolation**)\n", []),          # heading present
    ("# Doc\n\nsee **Overlap & isolation**)\n", ["Overlap & isolation"]),      # the #11 bug: no locator
    ("# Doc\n\n**Fallback self-review** (why)\n\nsee **Fallback self-review** below\n", []),  # bold lead-in
    ("# Doc\n\nin the **audits** plugin\n", []),                               # emphasis, not a reference
    ("# Doc\n\nit is in the **stale** bucket\n", []),                          # emphasis, not a reference
    ("# Doc\n\nsee `config.commands.lint`\n", []),                             # backticked config key
    ("# Doc\n\nSee **Missing Thing** below.\n", ["Missing Thing"]),            # trailing locator
    ("# Doc\n\n[link](other.md) and see **Nope**\n", ["Nope"]),                # a link elsewhere must not excuse it
    # A partial name is not a match: `Isolation` is not the anchor `Overlap & isolation`.
    ("## Overlap & isolation\n\nsee **Isolation**\n", ["Isolation"]),
    # A heading inside a fenced template is an example, not an anchor.
    ("# Doc\n\n```markdown\n## Fallback review\n```\n\nsee **Fallback review**\n", ["Fallback review"]),
    # A reference written as a literal inline example is documentation, not a reference.
    ("# Doc\n\nWrite it as `see **Missing Thing**` in the body.\n", []),
    # ...including a multi-backtick span, which single-backtick stripping left half-stripped.
    ("# Doc\n\nWrite it as ``see **Missing Thing**`` in the body.\n", []),
    # Mismatched delimiter runs are NOT a code span, so the reference inside stays reportable.
    ("# Doc\n\ntext `see **Mismatched**`` more\n", ["Mismatched"]),
    # A different fence delimiter inside a fenced block must not close it early.
    ("# Doc\n\n```markdown\n~~~\n## Example Heading\n~~~\n```\n\nsee **Example Heading**\n",
     ["Example Heading"]),
    # A longer closing run still closes; text after the block is prose again.
    ("# Doc\n\n```\n## Inside\n````\n\nsee **Inside**\n", ["Inside"]),
    # ...and a real reference on the same line as an unrelated code span still counts.
    ("# Doc\n\nRun `make test`, then see **Also Missing**\n", ["Also Missing"]),
]


def prose_self_test():
    """Regression-check the prose cross-reference rule, including its false-positive cases."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (body, expected) in enumerate(PROSE_CASES):
            probe = os.path.join(tmp, f"case{i}.md")
            with open(probe, "w", encoding="utf-8") as fh:
                fh.write(body)
            got = [name for _, name in stale_refs(probe)]
            if got != expected:
                failures.append(f"  prose case {i}: expected {expected}, got {got}")
    print(f"prose self-test: {len(PROSE_CASES) - len(failures)}/{len(PROSE_CASES)} cases pass")
    return failures


def self_test():
    """Regression-check the destination parser against the forms that have broken it."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, "probe.md")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("\n".join(src for src, _ in PARSER_CASES) + "\n")
        found = dict(links(probe))
    for i, (src, expected) in enumerate(PARSER_CASES, 1):
        got = found.get(i)
        if got != expected:
            failures.append(f"  {src!r}: expected {expected!r}, got {got!r}")
    print(f"parser self-test: {len(PARSER_CASES) - len(failures)}/{len(PARSER_CASES)} cases pass")
    return failures


def main():
    # Kept separate so each failure kind prints its own remediation. Folding the prose fixtures
    # into parser_failures sent developers to destinations()/links() for a prose-rule bug.
    parser_failures = self_test()
    prose_fixture_failures = prose_self_test()

    # Plugin links and repo-doc links are different kinds of failure and must not share a
    # bucket: a root README is never installed and is *supposed* to point into plugins/, so the
    # plugin-boundary remediation is actively wrong advice for it.
    link_failures = check_tree(os.path.join(ROOT, "plugins"), "source tree")
    with tempfile.TemporaryDirectory() as tmp:
        build_install_layout(tmp)
        link_failures += check_tree(tmp, "installed layout")
    link_failures += check_boundaries()

    repo_doc_failures = check_tree(ROOT, "repo docs", files=repo_docs())
    prose_failures = check_prose_refs()

    failures = (parser_failures + prose_fixture_failures + link_failures
                + repo_doc_failures + prose_failures)
    if failures:
        print("\nFAIL:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        if parser_failures:
            print(
                "\nThe destination parser regressed: the cases above are forms that must be\n"
                "parsed (or deliberately skipped). Fix destinations()/links(), not the cases.",
                file=sys.stderr,
            )
        if prose_fixture_failures:
            print(
                "\nThe prose cross-reference rule regressed: the cases above are forms that must\n"
                "be reported (or deliberately ignored). Fix XREF/headings()/stale_refs().",
                file=sys.stderr,
            )
        if prose_failures:
            print(
                "\nA prose reference names a section that no longer exists. Either restore the\n"
                "heading, or repoint the sentence at a link to wherever the content moved.",
                file=sys.stderr,
            )
        if link_failures:
            print(
                "\nA link must stay inside its own plugin. If a skill needs a doc from\n"
                "maintainerd-core, vendor it via scripts/sync-references.sh and link the copy.",
                file=sys.stderr,
            )
        if repo_doc_failures:
            print(
                "\nA link in the root README or docs/ points at a file that isn't there. These may\n"
                "point into plugins/ — that's expected and not a boundary problem; just fix the path.",
                file=sys.stderr,
            )
        return 1

    print("\nPlugin links resolve in both layouts and stay within their plugin;\n"
          "repo docs resolve too.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
