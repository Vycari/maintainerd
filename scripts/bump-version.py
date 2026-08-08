#!/usr/bin/env python3
"""Bump plugin versions in lockstep across a plugin's manifest and the marketplace entry.

A plugin's version is the *only* signal Claude Code has that an installed copy is stale.
The install cache is keyed by version:

    <cache>/maintainerd/audits/0.1.0/skills/audit-tests/SKILL.md

so a merge that changes a skill but leaves `0.1.0` alone lands nowhere — every existing
install keeps serving the old content forever. Bumping is therefore not a release
ceremony here, it is how the change reaches anyone.

The version lives in two places that CI (`.github/workflows/validate.yml`) requires to
agree: `plugins/<dir>/.claude-plugin/plugin.json` and the plugin's entry in
`.claude-plugin/marketplace.json`. This script edits both or neither.

    scripts/bump-version.py core repo-ops           # bump these (patch)
    scripts/bump-version.py --level minor audits    # bump one, minor
    scripts/bump-version.py --changed-since HEAD~1  # bump whatever that range touched
    scripts/bump-version.py --changed-since abc123 --dry-run

Plugins are named by either source directory (`core`) or plugin name (`maintainerd-core`).

stdout is the machine-readable part: one `<name>--v<version>` git tag per bumped plugin,
matching the tag convention `claude plugin tag` uses. Everything human goes to stderr, so
`TAGS=$(scripts/bump-version.py ...)` composes cleanly in CI.

Edits are made as targeted text replacements rather than a json.dump round-trip, which
would reflow these hand-formatted manifests and bury a one-character change in a
whole-file diff. Every edit is verified by reparsing the result.
"""

import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MARKETPLACE = os.path.join(ROOT, ".claude-plugin", "marketplace.json")
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
# Matches a whole `"version": "..."` line. Anchored to line start so a `version` key
# nested inside some future object still needs the uniqueness check below to pass.
VERSION_LINE = re.compile(r'(?m)^(\s*"version"\s*:\s*")([^"]*)(")')


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def log(message):
    print(message, file=sys.stderr)


def git(*args):
    """Run a git command in ROOT, returning stdout. Raises on non-zero exit."""
    return subprocess.run(
        ["git", "-C", ROOT, *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def bump(version, level):
    match = SEMVER.match(version)
    if not match:
        # Prerelease/build metadata would need a policy this repo has not picked. Refuse
        # rather than guess: a wrong bump is published to every installed copy.
        fail(f"version {version!r} is not a plain X.Y.Z semver — bump it by hand")
    major, minor, patch = (int(part) for part in match.groups())
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def load_marketplace():
    with open(MARKETPLACE) as handle:
        text = handle.read()
    return text, json.loads(text)


def plugin_index(marketplace):
    """Map both the source directory name and the plugin name to one entry record."""
    index = {}
    for entry in marketplace["plugins"]:
        source = entry["source"].lstrip("./").rstrip("/")
        record = {
            "name": entry["name"],
            "source": source,
            "dir": os.path.basename(source),
            "version": entry.get("version"),
            "manifest": os.path.join(source, ".claude-plugin", "plugin.json"),
        }
        index[record["name"]] = record
        index[record["dir"]] = record
    return index


def replace_plugin_version(path, old, new):
    """Rewrite the version in a plugin.json, verifying the parse afterwards."""
    with open(path) as handle:
        text = handle.read()

    matches = VERSION_LINE.findall(text)
    if len(matches) != 1:
        fail(f"{path}: expected exactly one top-level \"version\" line, found {len(matches)}")
    if matches[0][1] != old:
        fail(f"{path}: version is {matches[0][1]!r}, expected {old!r}")

    updated = VERSION_LINE.sub(lambda m: f"{m.group(1)}{new}{m.group(3)}", text, count=1)
    verify(updated, path, lambda data: data.get("version"), new)
    return updated


def replace_marketplace_version(text, name, old, new):
    """Rewrite one entry's version in marketplace.json, verifying the parse afterwards.

    The entry is located by its `"name"` key and the *next* `"version"` after it. If any
    other `"name"` key intervenes we have walked into the following entry — which would
    mean this entry carries no version — so bail rather than corrupt a sibling.
    """
    anchor = re.search(rf'"name"\s*:\s*"{re.escape(name)}"', text)
    if not anchor:
        fail(f"marketplace.json: no entry named {name!r}")

    tail = text[anchor.end():]
    version = re.search(r'("version"\s*:\s*")([^"]*)(")', tail)
    if not version:
        fail(f"marketplace.json: entry {name!r} has no version field")

    intervening = re.search(r'"name"\s*:\s*"', tail[: version.start()])
    if intervening:
        fail(f"marketplace.json: entry {name!r} has no version before the next entry")
    if version.group(2) != old:
        fail(f"marketplace.json: {name} version is {version.group(2)!r}, expected {old!r}")

    start = anchor.end() + version.start()
    end = anchor.end() + version.end()
    updated = text[:start] + f"{version.group(1)}{new}{version.group(3)}" + text[end:]
    verify(
        updated,
        "marketplace.json",
        lambda data: next(e for e in data["plugins"] if e["name"] == name).get("version"),
        new,
    )
    return updated


def verify(text, label, extract, expected):
    """Reparse an edited manifest and confirm the edit landed where it was aimed.

    The text edits above are careful, but "careful" is not "checked" — and a manifest
    this script mangles ships straight to every install.
    """
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(f"{label}: edit produced invalid JSON ({exc})")
    actual = extract(data)
    if actual != expected:
        fail(f"{label}: edit left version at {actual!r}, expected {expected!r}")


def version_at(ref, manifest):
    """The plugin's version at `ref`, or None if the manifest did not exist there."""
    try:
        text = git("show", f"{ref}:{manifest}")
    except subprocess.CalledProcessError:
        return None
    try:
        return json.loads(text).get("version")
    except json.JSONDecodeError:
        return None


def changed_plugins(ref, index):
    """Source dirs under plugins/ touched between `ref` and HEAD, in marketplace order."""
    try:
        changed = git("diff", "--name-only", ref, "HEAD").splitlines()
    except subprocess.CalledProcessError:
        fail(f"cannot diff against {ref!r} — is it a valid ref in this repo?")

    touched = set()
    for path in changed:
        parts = path.split("/")
        if len(parts) > 2 and parts[0] == "plugins":
            touched.add("/".join(parts[:2]))

    selected = []
    for record in ordered(index):
        if record["source"] in touched:
            selected.append(record)
    unknown = touched - {record["source"] for record in ordered(index)}
    for source in sorted(unknown):
        # A directory under plugins/ with no marketplace entry ships to nobody, so there
        # is no install to invalidate. Worth saying out loud — it is usually a typo in
        # marketplace.json rather than a deliberate unlisted plugin.
        log(f"note: {source} changed but has no marketplace entry — skipping")
    return selected


def ordered(index):
    """The distinct entry records, in marketplace order (index holds each one twice)."""
    seen = []
    for record in index.values():
        if record not in seen:
            seen.append(record)
    return seen


def main():
    parser = argparse.ArgumentParser(
        description="Bump plugin versions in plugin.json and marketplace.json together.",
    )
    parser.add_argument(
        "plugins",
        nargs="*",
        help="plugins to bump, by source directory (core) or plugin name (maintainerd-core)",
    )
    parser.add_argument(
        "--level",
        choices=("patch", "minor", "major"),
        default="patch",
        help="semver level to bump (default: patch)",
    )
    parser.add_argument(
        "--changed-since",
        metavar="REF",
        help="bump every plugin whose files changed between REF and HEAD",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would change without writing anything",
    )
    args = parser.parse_args()

    if bool(args.plugins) == bool(args.changed_since):
        parser.error("give either plugin names or --changed-since, not both or neither")

    marketplace_text, marketplace = load_marketplace()
    index = plugin_index(marketplace)

    if args.changed_since:
        targets = changed_plugins(args.changed_since, index)
    else:
        targets = []
        for name in args.plugins:
            if name not in index:
                fail(f"unknown plugin {name!r} — known: {', '.join(sorted(index))}")
            record = index[name]
            if record not in targets:
                targets.append(record)

    tags = []
    edits = {}
    for record in targets:
        manifest_path = os.path.join(ROOT, record["manifest"])
        if not os.path.exists(manifest_path):
            fail(f"{record['name']}: no manifest at {record['manifest']}")
        with open(manifest_path) as handle:
            current = json.load(handle).get("version")
        if current != record["version"]:
            fail(
                f"{record['name']}: manifest version {current!r} != marketplace "
                f"{record['version']!r} — fix the mismatch before bumping"
            )

        # An author who deliberately bumped in the PR (a minor or major that this
        # script's default patch would flatten) already published a new version for this
        # range. Bumping again on merge would silently turn their 0.2.0 into 0.2.1.
        #
        # Their version still wants a tag, though: stdout means "this range published
        # this version", not "this script edited a file". A brand-new plugin is the one
        # case with nothing to announce — its first version has never been anywhere.
        if args.changed_since:
            previous = version_at(args.changed_since, record["manifest"])
            if previous is None:
                log(f"skip {record['name']}: new since {args.changed_since}, keeping {current}")
                continue
            if previous != current:
                log(f"skip {record['name']}: already bumped {previous} -> {current}")
                tags.append(f"{record['name']}--v{current}")
                continue

        new = bump(current, args.level)
        edits[manifest_path] = replace_plugin_version(manifest_path, current, new)
        marketplace_text = replace_marketplace_version(
            marketplace_text, record["name"], current, new
        )
        tags.append(f"{record['name']}--v{new}")
        log(f"bump {record['name']}: {current} -> {new}")

    if not tags:
        log("nothing to bump")
        return

    if args.dry_run:
        log("dry run — no files written")
    elif edits:
        for path, text in edits.items():
            with open(path, "w") as handle:
                handle.write(text)
        with open(MARKETPLACE, "w") as handle:
            handle.write(marketplace_text)

    for tag in tags:
        print(tag)


if __name__ == "__main__":
    main()
