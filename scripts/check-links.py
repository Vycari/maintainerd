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
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def destinations(line):
    """Yield raw destinations from `](...)` spans.

    Hand-scanned rather than regexed because the two forms a regex gets wrong —
    `](<path with spaces.md>)` and `](foo(1).md)` — both fail by *truncating* the
    destination, and a truncated target no longer ends in a checked extension, so it
    is silently dropped instead of reported. A dropped link reads exactly like a
    passing one, which is the failure this whole script exists to prevent.
    """
    i = 0
    while True:
        start = line.find("](", i)
        if start < 0:
            return
        j = start + 2
        if j < len(line) and line[j] == "<":  # angle-bracket form: ](<dest>)
            end = line.find(">", j + 1)
            if end < 0:
                i = j
                continue
            yield line[j + 1 : end]
            i = end + 1
            continue
        depth, buf = 1, []  # bare form: scan to the matching ')', allowing nested pairs
        while j < len(line):
            char = line[j]
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


def links(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for raw in destinations(line):
                target = raw.strip()
                title = TITLE.match(target)
                if title:
                    target = title.group(1)
                target = target.split("#", 1)[0].split("?", 1)[0]
                if not target or REMOTE.match(target):
                    continue
                if target.endswith(CHECKED):
                    yield lineno, target


def check_tree(base, label):
    """Report links that fail to resolve anywhere under `base`."""
    broken = []
    count = 0
    for md in glob(os.path.join(base, "**", "*.md"), recursive=True):
        for lineno, target in links(md):
            count += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(md), target))
            if not os.path.exists(resolved):
                broken.append(f"  {os.path.relpath(md, base)}:{lineno} -> {target}")
    print(f"{label}: checked {count} links, {len(broken)} broken")
    return broken


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
    ("[a](../../references/model-tiers.md#tiers)", "../../references/model-tiers.md"),
    ("[a](https://example.com/x.md)", None),
    ("[a](//example.test/file.py)", None),
    ("[a](ftp://example.test/file.py)", None),
    ("[a](custom+v1://example.test/file.py)", None),
    ("[a](mailto:someone@example.com)", None),
    ("[a](#local)", None),
    ("[a](../sibling)", None),  # no checked extension
]


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
    parser_failures = self_test()
    failures = list(parser_failures)
    failures += check_tree(os.path.join(ROOT, "plugins"), "source tree")

    with tempfile.TemporaryDirectory() as tmp:
        build_install_layout(tmp)
        failures += check_tree(tmp, "installed layout")

    failures += check_boundaries()

    if failures:
        print("\nFAIL:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        if parser_failures:
            print(
                "\nThe destination parser regressed: the cases above are forms that must be\n"
                "parsed (or deliberately skipped). Fix destinations()/links(), not the cases.",
                file=sys.stderr,
            )
        if len(failures) > len(parser_failures):
            print(
                "\nA link must stay inside its own plugin. If a skill needs a doc from\n"
                "maintainerd-core, vendor it via scripts/sync-references.sh and link the copy.",
                file=sys.stderr,
            )
        return 1

    print("\nAll links resolve in both layouts and stay within their plugin.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
