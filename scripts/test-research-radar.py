#!/usr/bin/env python3
"""Tests for plugins/research/scripts/research-radar.py.

Runs the script as a subprocess against a local fake OAI-PMH server, so every path below
exercises the real command line: harvest (complete, empty window, failures), window selection
from the state file, prefilter (categories, terms, old revisions, dedupe), advance, and profile.

  python3 scripts/test-research-radar.py
"""

import datetime as dt
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "plugins/research/scripts/research-radar.py")
TODAY = dt.datetime.now(dt.timezone.utc).date()
YM = TODAY.strftime("%y%m")                      # new-style ids carry their submission month
OLD_YM = (TODAY - dt.timedelta(days=120)).strftime("%y%m")


def aid(n):
    return f"{YM}.{n:05d}"

ENVELOPE = """<?xml version="1.0" encoding="UTF-8"?>
<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
<responseDate>{rd}</responseDate>
{inner}
</OAI-PMH>"""


def record(arxid, created, cats, title, abstract="", deleted=False):
    status = ' status="deleted"' if deleted else ""
    return f"""<record><header{status}><identifier>oai:arXiv.org:{arxid}</identifier>
<datestamp>{TODAY}</datestamp></header>
<metadata><arXiv xmlns="http://arxiv.org/OAI/arXiv/"><id>{arxid}</id><created>{created}</created>
<authors><author><keyname>Doe</keyname><forenames>Jane</forenames></author></authors>
<title>{title}</title><categories>{cats}</categories><abstract>{abstract}</abstract></arXiv></metadata>
</record>"""


def page(records, token="", rd=None):
    rd = rd or f"{TODAY}T06:00:00Z"
    return ENVELOPE.format(rd=rd, inner=f"<ListRecords>{''.join(records)}"
                                        f"<resumptionToken>{token}</resumptionToken></ListRecords>")


def oai_error(code, rd=None):
    return ENVELOPE.format(rd=rd or f"{TODAY}T06:00:00Z", inner=f'<error code="{code}">x</error>')


class FakeOAI:
    """Routes: 'first' for the initial ListRecords, else the resumptionToken value. Each route is
    a list of (status, body) served in order; the last entry repeats."""

    def __init__(self, routes):
        self.routes = routes
        self.requests = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
                outer.requests.append(q)
                key = q.get("resumptionToken", "first")
                seq = outer.routes.get(key, [(404, "")])
                status, body = seq.pop(0) if len(seq) > 1 else seq[0]
                self.send_response(status)
                self.end_headers()
                self.wfile.write(body.encode())

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}/oai"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def write_json(path, obj):
    write(path, json.dumps(obj))


def read_json(path):
    with open(path) as f:
        return json.load(f)


def run(args, env_extra=None, cwd=None):
    env = dict(os.environ, RADAR_BACKOFF="0,0", RADAR_PAGE_SPACING="0", **(env_extra or {}))
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True,
                          env=env, cwd=cwd)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.state = os.path.join(self.d, "radar-state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def harvest(self, routes, sets=("cs",)):
        srv = FakeOAI(routes)
        out = os.path.join(self.d, f"h{len(os.listdir(self.d))}")
        args = ["harvest", "--state", self.state, "--out", out, "--ua", "test"]
        for s in sets:
            args += ["--set", s]
        try:
            r = run(args, {"RADAR_OAI_BASE": srv.base})
        finally:
            srv.close()
        return r, out, srv.requests

    def write_state(self, rd, recent=(), sets=("cs",)):
        write_json(self.state, {"version": 1, "highWater": {"responseDate": rd, "sets": list(sets)},
                                "recentIds": list(recent)})


class Harvest(Base):
    def test_complete_two_pages(self):
        r, out, reqs = self.harvest({
            "first": [(200, page([record(aid(1), TODAY, "cs.AI", "A")], token="t/1&amp;x=2"))],
            "t/1&x=2": [(200, page([record(aid(2), TODAY, "cs.AI", "B")]))],
        })
        self.assertEqual(r.returncode, 0, r.stderr)
        m = read_json(os.path.join(out, "manifest.json"))
        self.assertTrue(m["complete"])
        self.assertEqual(len(m["pages"]), 2)
        self.assertEqual(m["windowSource"], "fallback")
        self.assertEqual(m["from"], str(TODAY - dt.timedelta(days=7)))
        # the token round-trips intact despite reserved characters, and alone
        self.assertEqual(reqs[1], {"verb": "ListRecords", "resumptionToken": "t/1&x=2"})

    def test_no_records_match_first_page_is_empty_complete(self):
        r, out, _ = self.harvest({"first": [(200, oai_error("noRecordsMatch"))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read_json(os.path.join(out, "manifest.json"))["pages"], [])

    def assert_failed(self, r, out, needle):
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(needle, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(out, "manifest.json")))

    def test_error_mid_pagination_fails_without_manifest(self):
        r, out, _ = self.harvest({
            "first": [(200, page([record(aid(1), TODAY, "cs.AI", "A")], token="t2"))],
            "t2": [(200, oai_error("noRecordsMatch"))],
        })
        self.assert_failed(r, out, "noRecordsMatch")

    def test_other_oai_error_fails(self):
        r, out, _ = self.harvest({"first": [(200, oai_error("badArgument"))]})
        self.assert_failed(r, out, "badArgument")

    def test_body_without_listrecords_fails(self):
        r, out, _ = self.harvest({"first": [(200, ENVELOPE.format(rd="2026-01-01T00:00:00Z", inner=""))]})
        self.assert_failed(r, out, "neither <ListRecords> nor <error>")

    def test_transient_503_retries_then_succeeds(self):
        r, out, reqs = self.harvest({"first": [(503, ""), (200, page([]))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(reqs), 2)

    def test_persistent_503_fails(self):
        r, out, reqs = self.harvest({"first": [(503, "")]})
        self.assert_failed(r, out, "gave up after 3 attempts")

    def test_truncated_xml_fails(self):
        r, out, _ = self.harvest({"first": [(200, "<OAI-PMH><ListRecords>")]})
        self.assert_failed(r, out, "unparsable XML")

    def test_other_4xx_fails_without_retry(self):
        r, out, reqs = self.harvest({"first": [(400, "")]})
        self.assert_failed(r, out, "HTTP 400")
        self.assertEqual(len(reqs), 1)

    def test_refuses_nonempty_out_dir(self):
        out = os.path.join(self.d, "busy")
        os.makedirs(out)
        open(os.path.join(out, "stale.xml"), "w").close()
        r = run(["harvest", "--state", self.state, "--out", out, "--ua", "t", "--set", "cs"],
                {"RADAR_OAI_BASE": "http://127.0.0.1:9/oai"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not empty", r.stderr)


class Window(Base):
    def window(self):
        r, out, reqs = self.harvest({"first": [(200, page([]))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        return read_json(os.path.join(out, "manifest.json")), reqs[0]

    def test_from_is_mark_day_inclusive(self):
        mark = TODAY - dt.timedelta(days=3)
        self.write_state(f"{mark}T05:00:00Z")
        m, req = self.window()
        self.assertEqual((m["from"], m["windowSource"]), (str(mark), "state"))
        self.assertEqual((req["from"], req["until"]), (str(mark), str(TODAY)))

    def test_long_gap_is_capped(self):
        self.write_state(f"{TODAY - dt.timedelta(days=90)}T05:00:00Z")
        m, _ = self.window()
        self.assertEqual((m["from"], m["windowSource"]), (str(TODAY - dt.timedelta(days=28)), "capped"))

    def test_new_set_falls_back(self):
        # The mark covers only "cs"; a newly added set was never harvested, so the old mark
        # says nothing about it and the window falls back to the first-run window.
        self.write_state(f"{TODAY - dt.timedelta(days=2)}T05:00:00Z", sets=["cs"])
        r, out, reqs = self.harvest({"first": [(200, page([]))]}, sets=("cs", "physics"))
        self.assertEqual(r.returncode, 0, r.stderr)
        m = read_json(os.path.join(out, "manifest.json"))
        self.assertEqual((m["from"], m["windowSource"]), (str(TODAY - dt.timedelta(days=7)), "new-sets"))
        self.assertEqual({q["from"] for q in reqs}, {str(TODAY - dt.timedelta(days=7))})

    def test_new_set_keeps_an_older_mark(self):
        # Mark 12 days back: the covered set must still be fetched from its mark, not from
        # the 7-day fallback, or the days between would never be harvested.
        mark = TODAY - dt.timedelta(days=12)
        self.write_state(f"{mark}T05:00:00Z", sets=["cs"])
        r, out, reqs = self.harvest({"first": [(200, page([]))]}, sets=("cs", "physics"))
        self.assertEqual(r.returncode, 0, r.stderr)
        m = read_json(os.path.join(out, "manifest.json"))
        self.assertEqual((m["from"], m["windowSource"]), (str(mark), "new-sets"))
        self.assertEqual({q["from"] for q in reqs}, {str(mark)})

    def test_subset_of_marked_sets_uses_mark(self):
        mark = TODAY - dt.timedelta(days=2)
        self.write_state(f"{mark}T05:00:00Z", sets=["cs", "physics"])
        r, out, _ = self.harvest({"first": [(200, page([]))]}, sets=("cs",))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read_json(os.path.join(out, "manifest.json"))["windowSource"], "state")

    def test_unreadable_state_fails(self):
        with open(self.state, "w") as f:
            f.write("{not json")
        r, out, _ = self.harvest({"first": [(200, page([]))]})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unreadable", r.stderr)


class PrefilterAdvance(Base):
    def setUp(self):
        super().setUp()
        self.profile = os.path.join(self.d, "profile.json")
        write_json(self.profile, {"categories": ["cs.AI"], "core": ["tool use"],
                   "interests": {"file": None, "terms": []},
                   "prTitles": {"terms": [{"term": "scheduler", "count": 4}, {"term": "agent", "count": 5},
                                          {"term": "retry budget", "count": 2}]},
                   "designDocs": {"terms": [{"term": "calendar", "count": 2}]}})
        self.reports = os.path.join(self.d, "reports")
        os.makedirs(self.reports)
        with open(os.path.join(self.reports, "2026-01-01.md"), "w") as f:
            f.write(f"### [Old](http://arxiv.org/abs/{aid(5)}v2)\n")
        old = TODAY - dt.timedelta(days=400)
        # Filler: in-category papers that match nothing but the background word "agent", so
        # document frequencies look like a real harvest's.
        filler = [record(aid(90000 + i), TODAY, "cs.AI", f"Agent study {i}") for i in range(60)]
        self.records = filler + [
            record(aid(1), TODAY, "cs.AI", "Agents with tool use"),                 # core hit
            record(aid(2), TODAY, "cs.AI", "A scheduler", "with a retry budget"),   # 2 derived
            record(aid(3), TODAY, "cs.AI", "A scheduler only"),                     # 1 derived
            record(aid(4), TODAY, "cs.CV", "Vision tool use"),                      # wrong cat
            record(aid(5), TODAY, "cs.AI", "Reported tool use"),                    # reported
            record(aid(6), TODAY, "cs.AI", "Seen tool use"),                        # seen
            record("1810.00007", old, "cs.AI", "Old paper, new version, tool use"),       # revision
            record(aid(8), TODAY - dt.timedelta(days=9), "cs.AI", "Friday tool use"),  # grace
            record(aid(9), TODAY, "cs.AI", "tool use", deleted=True),
            record(aid(10), TODAY, "cs.AI", "toolbox usefulness"),                   # no word hit
            record(f"{OLD_YM}.00011", TODAY, "cs.AI", "Tool use, created date reset"),  # id says old
            record(aid(12), TODAY, "cs.AI", "An agent scheduler"),                 # 1 + background
        ]

    def prefilter(self, out, max_=None):
        args = ["prefilter", "--manifest", os.path.join(out, "manifest.json"), "--profile",
                self.profile, "--state", self.state, "--reported-dir", self.reports]
        if max_ is not None:
            args += ["--max", str(max_)]
        return run(args)

    def test_filter_and_advance(self):
        self.write_state(f"{TODAY - dt.timedelta(days=3)}T05:00:00Z", recent=[aid(6)])
        r, out, _ = self.harvest({"first": [(200, page(self.records, rd=f"{TODAY}T06:00:00Z"))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.prefilter(out)
        self.assertEqual(p.returncode, 0, p.stderr)
        res = json.loads(p.stdout)
        self.assertEqual(sorted(c["id"] for c in res["candidates"]), [aid(1), aid(2), aid(8)])
        st = res["stats"]
        self.assertEqual((st["records"], st["deleted"], st["oldRevisions"]), (72, 1, 2))
        self.assertIn("agent", res["backgroundTerms"])
        self.assertNotIn("scheduler", res["backgroundTerms"])
        self.assertEqual((st["alreadyReported"], st["alreadySeen"], st["survivors"]), (1, 1, 3))

        cand = os.path.join(self.d, "cand.json")
        write(cand, p.stdout)
        a = run(["advance", "--manifest", os.path.join(out, "manifest.json"),
                 "--candidates", cand, "--state", self.state])
        self.assertEqual(a.returncode, 0, a.stderr)
        state = read_json(self.state)
        self.assertEqual(state["highWater"]["responseDate"], f"{TODAY}T06:00:00Z")
        self.assertEqual(sorted(state["recentIds"][:3]), [aid(1), aid(2), aid(8)])
        self.assertEqual(state["recentIds"][3], aid(6))

        # a second run over the same window surfaces nothing new
        r2, out2, _ = self.harvest({"first": [(200, page(self.records, rd=f"{TODAY}T07:00:00Z"))]})
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(read_json(os.path.join(out2, "manifest.json"))["from"], str(TODAY))
        self.assertEqual(json.loads(self.prefilter(out2).stdout)["candidates"], [])

    def test_small_harvest_has_no_background(self):
        # 3 in-category records: "scheduler" hits 2 of them (67%) but that is too few to call
        # background, so two derived terms still admit a paper.
        recs = [record(aid(1), TODAY, "cs.AI", "A scheduler", "with a retry budget"),
                record(aid(2), TODAY, "cs.AI", "Another scheduler"),
                record(aid(3), TODAY, "cs.AI", "Unrelated")]
        r, out, _ = self.harvest({"first": [(200, page(recs))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        res = json.loads(self.prefilter(out).stdout)
        self.assertEqual(res["backgroundTerms"], [])
        self.assertEqual([c["id"] for c in res["candidates"]], [aid(1)])

    def test_failed_harvest_leaves_mark_alone(self):
        self.write_state("2026-01-01T00:00:00Z")
        with open(self.state) as f:
            before = f.read()
        r, out, _ = self.harvest({"first": [(200, page(self.records, token="t"))], "t": [(503, "")]})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotEqual(self.prefilter(out).returncode, 0)
        a = run(["advance", "--manifest", os.path.join(out, "manifest.json"),
                 "--candidates", os.path.join(self.d, "none.json"), "--state", self.state])
        self.assertNotEqual(a.returncode, 0)
        with open(self.state) as f:
            self.assertEqual(f.read(), before)

    def test_advance_refuses_to_rewind_a_newer_mark(self):
        # Two runs harvest from the same committed mark; the first advances. The second must not
        # overwrite the newer mark with its own older view.
        self.write_state(f"{TODAY - dt.timedelta(days=3)}T05:00:00Z")
        r, out, _ = self.harvest({"first": [(200, page(self.records, rd=f"{TODAY}T06:00:00Z"))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        cand = os.path.join(self.d, "cand.json")
        write(cand, self.prefilter(out).stdout)
        self.write_state(f"{TODAY}T09:00:00Z")          # the other run's advance
        with open(self.state) as f:
            before = f.read()
        a = run(["advance", "--manifest", os.path.join(out, "manifest.json"),
                 "--candidates", cand, "--state", self.state])
        self.assertNotEqual(a.returncode, 0)
        self.assertIn("another run advanced it", a.stderr)
        with open(self.state) as f:
            self.assertEqual(f.read(), before)

    def test_advance_rejects_mismatched_candidates(self):
        r, out, _ = self.harvest({"first": [(200, page([], rd=f"{TODAY}T06:00:00Z"))]})
        cand = os.path.join(self.d, "cand.json")
        write_json(cand, {"responseDate": "2020-01-01T00:00:00Z", "candidates": []})
        a = run(["advance", "--manifest", os.path.join(out, "manifest.json"),
                 "--candidates", cand, "--state", self.state])
        self.assertNotEqual(a.returncode, 0)
        self.assertFalse(os.path.exists(self.state))

    def test_overflow_beyond_max_stays_unseen_and_resurfaces(self):
        # Of the 3 survivors, --max 2 admits the two core-phrase hits (aid1, aid8) and pushes the
        # derived-term-only aid2 into overflow — core hits sort first regardless of score, so a
        # cap never bumps a core hit for a pile of derived-term matches (see the sort comment in
        # cmd_prefilter).
        self.write_state(f"{TODAY - dt.timedelta(days=3)}T05:00:00Z", recent=[aid(6)])
        r, out, _ = self.harvest({"first": [(200, page(self.records, rd=f"{TODAY}T06:00:00Z"))]})
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.prefilter(out, max_=2)
        self.assertEqual(p.returncode, 0, p.stderr)
        res = json.loads(p.stdout)
        self.assertEqual([c["id"] for c in res["candidates"]], [aid(1), aid(8)])
        self.assertEqual(res["overflowIds"], [aid(2)])
        self.assertEqual((res["stats"]["survivors"], res["stats"]["returned"], res["stats"]["overflow"]),
                          (3, 2, 1))

        cand = os.path.join(self.d, "cand.json")
        write(cand, p.stdout)
        a = run(["advance", "--manifest", os.path.join(out, "manifest.json"),
                 "--candidates", cand, "--state", self.state])
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertIn("2 marked seen, 1 overflow left unseen", a.stderr)
        state = read_json(self.state)
        # The mark still advances to this run's responseDate (an overflowing run is not a failed
        # one) — see test_advance_refuses_to_rewind_a_newer_mark for the no-rewind guarantee.
        self.assertEqual(state["highWater"]["responseDate"], f"{TODAY}T06:00:00Z")
        # The ranked/returned ids are marked seen; the overflow id is deliberately not.
        self.assertIn(aid(1), state["recentIds"])
        self.assertIn(aid(8), state["recentIds"])
        self.assertNotIn(aid(2), state["recentIds"])

        # Re-running prefilter over the same harvested pages against the updated state resurfaces
        # the overflow id: it was never added to recentIds, so it isn't "alreadySeen" this time.
        # (Whether a genuinely later harvest's date window would still contain it is the open
        # question tracked in maintainerd#75 — this only checks the seen-set doesn't lose it.)
        res2 = json.loads(self.prefilter(out).stdout)
        self.assertEqual([c["id"] for c in res2["candidates"]], [aid(2)])


class Profile(Base):
    def test_profile_from_git_history(self):
        repo = os.path.join(self.d, "repo")
        os.makedirs(os.path.join(repo, "planning"))
        os.makedirs(os.path.join(repo, ".claude"))
        os.makedirs(os.path.join(repo, "radar"))
        write_json(os.path.join(repo, ".claude/maintainerd.json"), {"repo": "acme/widget", "defaultBranch": "main", "researchRadar": {"themes": ["Agent memory"],
                   "categories": ["cs.AI"]},
                   "paths": {"designDocs": ["planning/"], "researchRadarDir": "radar/"}})
        write(os.path.join(repo, "radar/interests.md"), "# interests\n- speech endpointing\n")

        def git(*a):
            subprocess.run(["git", *a], cwd=repo, check=True, capture_output=True)
        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "t")
        for i, subject in enumerate(["feat(sync): conflict resolver for offline sync (#1)",
                                     "fix: offline sync retries (#2)",
                                     "Offline sync: resolver metrics (#3)",
                                     "docs: typo",
                                     "widget: report 1", "widget: report 2", "widget: report 3"]):
            if i < 4:
                with open(os.path.join(repo, "planning", f"offline-sync-{i % 2}.md"), "a") as f:
                    f.write(f"# Offline sync plan\n## Conflict resolver {i}\n")
            else:
                # a report series: its repeated headings are template, its varied ones are topic
                topic = ["Latency budget for sync", "Sync latency budget", "Latency budget review"][i - 4]
                write(os.path.join(repo, "planning", f"2026-09-0{i}.md"),
                      f"# Daily report — 2026-09-0{i}\n## Open questions\n## Summary shipped\n## {topic}\n")
            git("add", "planning")
            git("commit", "-q", "-m", subject)
        r = run(["profile", "--repo-root", repo, "--config", os.path.join(repo, ".claude/maintainerd.json"),
                 "--no-gh", "--branch", "main"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        p = json.loads(r.stdout)
        self.assertEqual(p["core"], ["agent memory"])
        self.assertEqual(p["interests"]["terms"], ["speech endpointing"])
        self.assertEqual(p["prTitles"]["count"], 7)
        terms = {t["term"]: t["count"] for t in p["prTitles"]["terms"]}
        self.assertEqual(terms.get("offline sync"), 3)
        self.assertNotIn("fix", terms)
        self.assertNotIn("docs", terms)
        self.assertNotIn("widget", terms)             # the repo's own name
        doc_terms = {t["term"] for t in p["designDocs"]["terms"]}
        self.assertIn("offline sync", doc_terms)
        self.assertIn("latency budget", doc_terms)
        for template in ("open questions", "summary shipped", "daily report", "questions summary"):
            self.assertNotIn(template, doc_terms)

    def test_interests_default_dir(self):
        # No researchRadarDir configured: the interests file is looked up in the same fallback
        # directory the skill uses for digests and state.
        repo = os.path.join(self.d, "repo2")
        os.makedirs(os.path.join(repo, "planning/research-radar"))
        write_json(os.path.join(repo, "cfg.json"), {"researchRadar": {"categories": ["cs.AI"]}})
        write(os.path.join(repo, "planning/research-radar/interests.md"), "- speech endpointing\n")
        for cmd in (["init", "-q", "-b", "main"], ["add", "."],
                    ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "-m", "init"]):
            subprocess.run(["git", *cmd], cwd=repo, check=True, capture_output=True)
        r = run(["profile", "--repo-root", repo, "--config", os.path.join(repo, "cfg.json"),
                 "--no-gh", "--branch", "main"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        p = json.loads(r.stdout)
        self.assertEqual(p["interests"]["file"], "planning/research-radar/interests.md")
        self.assertEqual(p["interests"]["terms"], ["speech endpointing"])

    def test_profile_requires_categories(self):
        r = run(["profile", "--repo-root", self.d, "--config", os.path.join(self.d, "none.json"), "--no-gh"],
                cwd=self.d)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no arXiv categories", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
