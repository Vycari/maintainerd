#!/usr/bin/env python3
"""Tests for plugins/research/scripts/changelog-radar.py.

Exercises:
  - Feed parsing (RSS 2.0 and Atom feeds, dates, categories, HTML cleaning)
  - Profile generation (extracting from .claude/maintainerd.json, workflows, dependencies)
  - Prefilter scoring (term matching, score calculation, seen ID suppression, date filtering)
  - State management (save, load, advance high-water mark, seen ID tracking)

Run:
  python3 scripts/test-changelog-radar.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "plugins", "research", "scripts", "changelog-radar.py")


def run_script(args, input_data=None):
    cmd = [sys.executable, SCRIPT, *args]
    proc = subprocess.run(
        cmd,
        input=input_data,
        capture_output=True,
        text=True,
    )
    return proc


SAMPLE_RSS = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>GitHub Changelog</title>
    <link>https://github.blog/changelog/</link>
    <item>
      <title>GitHub Actions workflow lockfiles in public preview</title>
      <link>https://github.blog/changelog/2026-10-14-github-actions-workflow-lockfiles-in-public-preview/</link>
      <guid isPermaLink="true">https://github.blog/changelog/2026-10-14-github-actions-workflow-lockfiles-in-public-preview/</guid>
      <pubDate>Wed, 14 Oct 2026 13:49:15 +0000</pubDate>
      <category><![CDATA[actions]]></category>
      <category><![CDATA[release]]></category>
      <description><![CDATA[<p>GitHub Actions workflow dependency lockfiles are now in public preview.</p>]]></description>
    </item>
    <item>
      <title>Unrelated Announcement</title>
      <link>https://github.blog/changelog/unrelated/</link>
      <guid>unrelated-1</guid>
      <pubDate>Mon, 12 Oct 2026 10:00:00 +0000</pubDate>
      <category>billing</category>
      <description>Payment invoices updated.</description>
    </item>
  </channel>
</rss>
"""

SAMPLE_ATOM = """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Feed</title>
  <entry>
    <title>Rust 1.85 Released</title>
    <id>tag:blog,2026:rust-185</id>
    <link href="https://example.com/rust-185"/>
    <published>2026-10-15T12:00:00Z</published>
    <category term="rust"/>
    <summary>New cargo features released.</summary>
  </entry>
</feed>
"""


class FeedParsingTest(unittest.TestCase):
    def test_parse_rss(self):
        sys.path.insert(0, os.path.join(ROOT, "plugins", "research", "scripts"))
        import importlib
        cr = importlib.import_module("changelog-radar")

        records = cr.parse_feed_xml(SAMPLE_RSS.encode("utf-8"))
        self.assertEqual(len(records), 2)
        r0 = records[0]
        self.assertEqual(r0["title"], "GitHub Actions workflow lockfiles in public preview")
        self.assertEqual(r0["published"], "2026-10-14T13:49:15Z")
        self.assertIn("actions", r0["categories"])
        self.assertIn("public preview", r0["summary"])

    def test_parse_atom(self):
        sys.path.insert(0, os.path.join(ROOT, "plugins", "research", "scripts"))
        import importlib
        cr = importlib.import_module("changelog-radar")

        records = cr.parse_feed_xml(SAMPLE_ATOM.encode("utf-8"))
        self.assertEqual(len(records), 1)
        r0 = records[0]
        self.assertEqual(r0["title"], "Rust 1.85 Released")
        self.assertEqual(r0["id"], "tag:blog,2026:rust-185")
        self.assertEqual(r0["published"], "2026-10-15T12:00:00Z")
        self.assertIn("rust", r0["categories"])


class ProfileAndPrefilterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_profile_extraction(self):
        # Create minimal mock repo
        d = self.tmp.name
        claude_dir = os.path.join(d, ".claude")
        os.makedirs(claude_dir, exist_ok=True)
        with open(os.path.join(claude_dir, "maintainerd.json"), "w") as f:
            json.dump({
                "language": "python",
                "commands": {"test": "uv run pytest", "lint": "ruff check"},
            }, f)

        wf_dir = os.path.join(d, ".github", "workflows")
        os.makedirs(wf_dir, exist_ok=True)
        with open(os.path.join(wf_dir, "test.yml"), "w") as f:
            f.write("""
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v1
""")

        proc = run_script(["profile", "--cwd", d])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)

        self.assertIn("python", data["technologies"])
        self.assertIn("actions/checkout", data["technologies"])
        self.assertIn("ubuntu-latest", data["technologies"])
        self.assertIn("pytest", data["terms"])
        self.assertIn("ruff", data["terms"])
        self.assertIn("uv", data["terms"])

    def test_prefilter_relevance_scoring(self):
        profile = {
            "technologies": ["actions/checkout", "python", "uv"],
            "terms": ["actions", "github actions", "lockfiles", "workflow", "python", "uv"],
        }
        records = [
            {
                "id": "item-1",
                "title": "GitHub Actions workflow lockfiles in public preview",
                "link": "https://example.com/item-1",
                "published": "2026-10-14T13:49:15Z",
                "categories": ["actions"],
                "summary": "Lockfiles for GitHub actions.",
            },
            {
                "id": "item-2",
                "title": "Unrelated Notice About Invoices",
                "link": "https://example.com/item-2",
                "published": "2026-10-14T10:00:00Z",
                "categories": ["billing"],
                "summary": "Payment changes.",
            },
        ]

        prof_file = os.path.join(self.tmp.name, "profile.json")
        rec_file = os.path.join(self.tmp.name, "records.json")
        with open(prof_file, "w") as f:
            json.dump(profile, f)
        with open(rec_file, "w") as f:
            json.dump(records, f)

        proc = run_script(["prefilter", "--profile", prof_file, "--input", rec_file])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        survivors = json.loads(proc.stdout)

        self.assertEqual(len(survivors), 1)
        self.assertEqual(survivors[0]["id"], "item-1")
        self.assertGreater(survivors[0]["score"], 0)
        self.assertIn("actions", survivors[0]["matchedTerms"])

    def test_state_advance_and_filtering(self):
        profile = {"technologies": [], "terms": ["actions"]}
        records = [{
            "id": "item-1",
            "title": "GitHub Actions update",
            "link": "https://example.com/1",
            "published": "2026-10-14T12:00:00Z",
            "categories": ["actions"],
            "summary": "Actions update summary",
        }]

        prof_file = os.path.join(self.tmp.name, "profile.json")
        rec_file = os.path.join(self.tmp.name, "records.json")
        state_file = os.path.join(self.tmp.name, "changelog-state.json")

        with open(prof_file, "w") as f:
            json.dump(profile, f)
        with open(rec_file, "w") as f:
            json.dump(records, f)

        # First prefilter: item-1 passes
        proc = run_script(["prefilter", "--profile", prof_file, "--input", rec_file, "--state", state_file])
        self.assertEqual(proc.returncode, 0)
        survivors = json.loads(proc.stdout)
        self.assertEqual(len(survivors), 1)

        # Advance state
        proc = run_script(["advance", "--state", state_file, "--input", rec_file])
        self.assertEqual(proc.returncode, 0)
        with open(state_file) as f:
            st = json.load(f)
        self.assertEqual(st["highWater"]["publishedDate"], "2026-10-14T12:00:00Z")
        self.assertIn("item-1", st["recentIds"])

        # Second prefilter: item-1 is dropped because it is seen
        proc = run_script(["prefilter", "--profile", prof_file, "--input", rec_file, "--state", state_file])
        self.assertEqual(proc.returncode, 0)
        survivors = json.loads(proc.stdout)
        self.assertEqual(len(survivors), 0)


if __name__ == "__main__":
    unittest.main()
