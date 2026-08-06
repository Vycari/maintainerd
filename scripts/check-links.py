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

# Capture the whole destination, then strip decoration below. Matching the extension inline
# would silently skip anything with an anchor, query, or title — `foo.md#section`,
# `foo.md?raw=1`, `foo.md "Title"` — and a skipped link reads exactly like a passing one.
LINK = re.compile(r"\]\(([^)]+)\)")
TITLE = re.compile(r'^(\S+)\s+["\'(].*$')
# Any linked file, not just markdown — the schema links its example .json configs as siblings.
CHECKED = (".md", ".json", ".sh", ".py", ".yml", ".yaml")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def links(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for raw in LINK.findall(line):
                target = raw.strip()
                title = TITLE.match(target)
                if title:
                    target = title.group(1)
                target = target.split("#", 1)[0].split("?", 1)[0]
                if not target or target.startswith(("http://", "https://", "mailto:")):
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


def main():
    failures = []
    failures += check_tree(os.path.join(ROOT, "plugins"), "source tree")

    with tempfile.TemporaryDirectory() as tmp:
        build_install_layout(tmp)
        failures += check_tree(tmp, "installed layout")

    failures += check_boundaries()

    if failures:
        print("\nFAIL:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
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
