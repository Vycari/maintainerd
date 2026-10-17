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

    def test_parse_non_feed_xml_fails(self):
        sys.path.insert(0, os.path.join(ROOT, "plugins", "research", "scripts"))
        import importlib
        cr = importlib.import_module("changelog-radar")

        error_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>AccessDenied</Code>
  <Message>Rate limit exceeded</Message>
</Error>"""
        with self.assertRaises(SystemExit) as ctx:
            cr.parse_feed_xml(error_xml)
        self.assertIn("not an RSS or Atom feed", str(ctx.exception))

    def test_generic_command_stopwords_no_false_positive(self):
        d = self.tmp.name
        claude_dir = os.path.join(d, ".claude")
        os.makedirs(claude_dir, exist_ok=True)
        with open(os.path.join(claude_dir, "maintainerd.json"), "w") as f:
            json.dump({
                "language": "python",
                "commands": {"lint": "uv run ruff check"},
            }, f)

        proc = run_script(["profile", "--cwd", d])
        self.assertEqual(proc.returncode, 0)
        profile = json.loads(proc.stdout)
        self.assertNotIn("check", profile["terms"])
        self.assertNotIn("run", profile["terms"])

        # Feed item titled 'Check your billing details'
        records = [{
            "id": "billing-1",
            "title": "Check your billing details",
            "link": "https://example.com/billing",
            "published": "2026-10-14T12:00:00Z",
            "categories": [],
            "summary": "Please review payment information.",
        }]
        prof_file = os.path.join(self.tmp.name, "prof_check.json")
        rec_file = os.path.join(self.tmp.name, "rec_check.json")
        with open(prof_file, "w") as f:
            json.dump(profile, f)
        with open(rec_file, "w") as f:
            json.dump(records, f)

        proc = run_script(["prefilter", "--profile", prof_file, "--input", rec_file])
        self.assertEqual(proc.returncode, 0)
        survivors = json.loads(proc.stdout)
        self.assertEqual(len(survivors), 0)

    def test_same_timestamp_and_backdated_unseen_entries_survive(self):
        profile = {"technologies": [], "terms": ["actions"]}
        record_a = {
            "id": "post-a",
            "title": "GitHub Actions Post A",
            "link": "https://example.com/a",
            "published": "2026-10-14T12:00:00Z",
            "categories": ["actions"],
            "summary": "Actions A",
        }
        record_b_same_date = {
            "id": "post-b",
            "title": "GitHub Actions Post B",
            "link": "https://example.com/b",
            "published": "2026-10-14T12:00:00Z",
            "categories": ["actions"],
            "summary": "Actions B",
        }
        record_c_older_date = {
            "id": "post-c",
            "title": "GitHub Actions Post C",
            "link": "https://example.com/c",
            "published": "2026-10-13T10:00:00Z",
            "categories": ["actions"],
            "summary": "Actions C",
        }

        prof_file = os.path.join(self.tmp.name, "p_time.json")
        state_file = os.path.join(self.tmp.name, "s_time.json")
        rec_a_file = os.path.join(self.tmp.name, "r_a.json")
        rec_later_file = os.path.join(self.tmp.name, "r_later.json")

        with open(prof_file, "w") as f:
            json.dump(profile, f)
        with open(rec_a_file, "w") as f:
            json.dump([record_a], f)
        with open(rec_later_file, "w") as f:
            json.dump([record_a, record_b_same_date, record_c_older_date], f)

        # Advance state with A
        proc = run_script(["advance", "--state", state_file, "--input", rec_a_file])
        self.assertEqual(proc.returncode, 0)

        # Run prefilter with A, B, C: B and C must survive even though their date <= A's date!
        proc = run_script(["prefilter", "--profile", prof_file, "--input", rec_later_file, "--state", state_file])
        self.assertEqual(proc.returncode, 0)
        survivors = json.loads(proc.stdout)
        survivor_ids = {s["id"] for s in survivors}
        self.assertNotIn("post-a", survivor_ids)
        self.assertIn("post-b", survivor_ids)
        self.assertIn("post-c", survivor_ids)

    def test_advance_compare_and_set_conflict(self):
        state_file = os.path.join(self.tmp.name, "s_cas.json")
        with open(state_file, "w") as f:
            json.dump({
                "version": 1,
                "highWater": {"publishedDate": "2026-10-14T12:00:00Z"},
                "recentIds": ["id-1"],
            }, f)

        input_file = os.path.join(self.tmp.name, "cas_in.json")
        with open(input_file, "w") as f:
            json.dump([{"id": "id-2", "published": "2026-10-15T12:00:00Z"}], f)

        # Stale expected-mark fails
        proc = run_script(["advance", "--state", state_file, "--input", input_file, "--expected-mark", "2026-10-10T00:00:00Z"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to overwrite", proc.stderr)

        # Matching expected-mark succeeds
        proc = run_script(["advance", "--state", state_file, "--input", input_file, "--expected-mark", "2026-10-14T12:00:00Z"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_advance_only_marks_input_items(self):
        state_file = os.path.join(self.tmp.name, "s_partial.json")
        evaluated_file = os.path.join(self.tmp.name, "evaluated.json")
        with open(evaluated_file, "w") as f:
            json.dump([{"id": "evaluated-item-1", "published": "2026-10-14T12:00:00Z"}], f)

        proc = run_script(["advance", "--state", state_file, "--input", evaluated_file])
        self.assertEqual(proc.returncode, 0)
        with open(state_file) as f:
            st = json.load(f)
        self.assertIn("evaluated-item-1", st["recentIds"])
        self.assertNotIn("unevaluated-item-2", st["recentIds"])

    def test_prefilter_fails_on_empty_input(self):
        prof_file = os.path.join(self.tmp.name, "p_empty.json")
        empty_input = os.path.join(self.tmp.name, "empty_harvest.json")
        with open(prof_file, "w") as f:
            json.dump({"technologies": [], "terms": []}, f)
        with open(empty_input, "w") as f:
            pass  # 0 bytes

        proc = run_script(["prefilter", "--profile", prof_file, "--input", empty_input])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("is empty", proc.stderr)


if __name__ == "__main__":
    unittest.main()
