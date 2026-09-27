#!/usr/bin/env python3
"""Mechanical steps of the research-radar skill: harvest, profile, prefilter, advance.

The judgment steps (deriving core phrases from the repo, ranking survivors, writing the digest)
stay with the model running the skill. Everything here is deterministic, so it can be tested and
so a failed fetch can never be mistaken for a quiet week.

  harvest    fetch arXiv OAI-PMH pages for the window since the last complete harvest
  profile    build the interest profile from config, recent merged PRs, changed design docs,
             and an optional interests file
  prefilter  cheap local filter of a complete harvest against the profile (categories + terms),
             dropping revisions of old papers and ids already reported or already seen
  advance    move the high-water mark to this harvest's OAI responseDate (only after prefilter
             parsed every page)

Standard library only. Exit status is non-zero on any failure, with the reason on stderr.
"""

import argparse
import datetime as dt
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

OAI = "{http://www.openarchives.org/OAI/2.0/}"
ARX = "{http://arxiv.org/OAI/arXiv/}"
BASE = os.environ.get("RADAR_OAI_BASE", "https://oaipmh.arxiv.org/oai")
BACKOFF = [int(s) for s in os.environ.get("RADAR_BACKOFF", "15,60,180,300").split(",") if s != ""]
PAGE_SPACING = float(os.environ.get("RADAR_PAGE_SPACING", "3"))

STATE_VERSION = 1
FALLBACK_DAYS = 7        # no state yet: the old fixed window
MAX_WINDOW_DAYS = 28     # a long gap is capped (and reported), not harvested in full
CREATED_GRACE_DAYS = 7   # arXiv datestamps lag first submission by a few days (weekends, holds)
RECENT_IDS_KEEP = 500    # prefilter survivors remembered across runs, newest first
BACKGROUND_DF = 0.05     # a derived term in more than this share of in-category records is background
NEW_ID = re.compile(r"^(\d{2})(\d{2})\.\d{4,5}$")  # YYMM.NNNNN: the prefix is the v1 submission month

ARXIV_ID = re.compile(r"arxiv\.org/(?:abs|pdf)/([a-z\-]+(?:\.[A-Z]{2})?/\d{7}|\d{4}\.\d{4,5})", re.I)


def die(msg):
    sys.exit(f"research-radar: {msg}")


def utc_today():
    return dt.datetime.now(dt.timezone.utc).date()


# ── state ────────────────────────────────────────────────────────────────────────────────


def load_state(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        die(f"state file {path} is unreadable ({e}); fix or remove it rather than guess a window")
    if state.get("version") != STATE_VERSION:
        die(f"state file {path} has version {state.get('version')!r}, expected {STATE_VERSION}")
    return state


def compute_window(state, today):
    """Return (from_date, until_date, source). The mark's own day is included: datestamps are
    day-granular, so records can still land on that day after the mark was taken."""
    if state is None:
        return today - dt.timedelta(days=FALLBACK_DAYS), today, "fallback"
    mark = dt.date.fromisoformat(state["highWater"]["responseDate"][:10])
    earliest = today - dt.timedelta(days=MAX_WINDOW_DAYS)
    if mark < earliest:
        return earliest, today, "capped"
    return min(mark, today), today, "state"


# ── harvest ──────────────────────────────────────────────────────────────────────────────


def fetch(url, page, ua):
    """Return (body, root) for one page; retry transient failures, die on anything else."""
    for attempt in range(len(BACKOFF) + 1):
        wait, why = None, None
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ua})
            with urllib.request.urlopen(req, timeout=60) as r:
                body, code = r.read(), r.status
            print(f"page {page}: HTTP {code}", file=sys.stderr)
            if code != 200:
                die(f"harvest failed: page {page}: HTTP {code}")
            try:
                return body, ET.fromstring(body)
            except ET.ParseError as e:
                why = f"unparsable XML ({e})"  # truncated read: transient
        except urllib.error.HTTPError as e:
            print(f"page {page}: HTTP {e.code}", file=sys.stderr)
            # 406 is arXiv's throttle answer (seen intermittently from this endpoint); 503 is its
            # documented flow control. Any other 4xx will not change on retry.
            if e.code not in (406, 429, 503) and e.code < 500:
                die(f"harvest failed: page {page}: HTTP {e.code}")
            why = f"HTTP {e.code}"
            ra = e.headers.get("Retry-After", "") if e.headers else ""
            wait = int(ra) if ra.isdigit() else None
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            why = f"network error ({e})"
        if attempt == len(BACKOFF):
            die(f"harvest failed: page {page}: {why}; gave up after {attempt + 1} attempts")
        delay = max(BACKOFF[attempt], wait or 0)
        print(f"page {page}: {why}; retrying in {delay}s", file=sys.stderr)
        time.sleep(delay)


def harvest_set(oai_set, frm, until, ua, out_dir, first_page):
    pages, response_date, token, page = [], None, None, first_page
    while True:
        if token is None:
            q = {"verb": "ListRecords", "metadataPrefix": "arXiv", "set": oai_set,
                 "from": frm, "until": until}
        else:
            q = {"verb": "ListRecords", "resumptionToken": token}  # a resumption carries only these
        body, root = fetch(f"{BASE}?{urllib.parse.urlencode(q)}", page, ua)
        if root.tag != f"{OAI}OAI-PMH":
            die(f"harvest failed: page {page}: not an OAI-PMH response (root <{root.tag}>)")
        response_date = response_date or (root.findtext(f"{OAI}responseDate") or "").strip()
        err = root.find(f"{OAI}error")
        if err is not None:
            # OAI-PMH reports errors in an HTTP 200 body. noRecordsMatch on the first request is a
            # genuinely empty window; any other error, or any error mid-pagination, is a failure.
            if err.get("code") == "noRecordsMatch" and token is None:
                break
            die(f"harvest failed: page {page}: OAI error {err.get('code')}: {(err.text or '').strip()}")
        lr = root.find(f"{OAI}ListRecords")
        if lr is None:
            die(f"harvest failed: page {page}: response has neither <ListRecords> nor <error>")
        path = os.path.join(out_dir, f"{oai_set}-page{page}.xml")
        with open(path, "wb") as f:
            f.write(body)
        pages.append(path)
        token = (lr.findtext(f"{OAI}resumptionToken") or "").strip()
        if not token:
            break  # empty or absent token: last page
        page += 1
        time.sleep(PAGE_SPACING)
    if not response_date:
        die(f"harvest failed: set {oai_set}: no <responseDate> in the response")
    return pages, response_date, page


def cmd_harvest(a):
    today = utc_today()
    state = load_state(a.state)
    frm, until, source = compute_window(state, today)
    os.makedirs(a.out, exist_ok=True)
    if os.listdir(a.out):
        die(f"{a.out} is not empty; harvest into a fresh `mktemp -d` directory")
    sets = sorted(set(a.set))
    all_pages, dates, page = [], [], 1
    for s in sets:
        pages, response_date, page = harvest_set(s, frm.isoformat(), until.isoformat(), a.ua, a.out, page)
        all_pages += pages
        dates.append(response_date)
        page += 1
    manifest = {
        "complete": True,
        "pages": all_pages,
        "sets": sets,
        "from": frm.isoformat(),
        "until": until.isoformat(),
        "windowSource": source,  # "state" | "fallback" | "capped"
        "previousMark": state["highWater"]["responseDate"] if state else None,
        # The earliest responseDate across sets: the mark must not claim coverage a set lacks.
        "responseDate": min(dates),
    }
    # Written only after every page succeeded; prefilter and advance refuse to run without it.
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"harvest complete: {len(all_pages)} page(s), window {frm}..{until} ({source}) "
          f"-> {a.out}/manifest.json", file=sys.stderr)


def load_manifest(path):
    try:
        with open(path) as f:
            m = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        die(f"no usable manifest at {path} ({e}): the harvest failed; stop, do not open a PR")
    if m.get("complete") is not True:
        die("harvest incomplete: stop, do not open a PR")
    return m


# ── profile ──────────────────────────────────────────────────────────────────────────────

# Generic English plus software-process words. Deliberately domain-free: every term that
# survives comes from the target repo itself.
STOP = set("""
a about above after again against all also an and any are as at be because been before being
below between both but by can could did do does doing down during each few for from further had
has have having here how i if in into is it its itself just more most no nor not now of off on
once only or other our out over own same should so some such than that the their them then there
these they this those through to too under until up very was we were what when where which while
who whom why will with would you your yours new now via per vs using use used make makes made
get gets got keep keeps let lets one two three first last next back still even instead across
add adds added adding fix fixes fixed fixing update updates updated bump bumps remove removes
removed drop drops rename renames renamed move moves moved revert reverts merge merged merges
refactor refactors cleanup clean chore chores feat feature features docs doc test tests testing
tested ci wip pr prs issue issues phase part step steps follow followup follow-up small minor
support handle handles handling allow allows allowed ensure ensures when show shows shown
set sets setting settings change changes changed default defaults config configure enable enabled
disable disabled readme md todo tmp misc work works working version release notes note plan
planning design proposal draft review reviews reviewed fixup nit nits typo typos
every read reads write writes open opens run runs call calls name names longer many much
""".split())
TEMPLATE_MIN_DOCS = 3    # a heading repeated verbatim in this many changed docs is template, not topic

PREFIX = re.compile(r"^\s*(?:revert\s+\")?[a-z]+(?:\([^)]*\))?!?:\s*", re.I)  # conventional commit
NOISE = re.compile(r"\(#\d+\)|\b[\w.-]+#\d+\b|#\d+|§[\d.]+|\bv?\d+(?:\.\d+)+\b|`")
WORD = re.compile(r"[a-z][a-z0-9]+(?:-[a-z0-9]+)*")


def title_terms(text, extra_stop=frozenset()):
    """Unigrams and adjacent-pair bigrams of content words in one title or heading."""
    text = NOISE.sub(" ", PREFIX.sub("", text)).lower()
    words = [w for w in WORD.findall(text)
             if len(w) >= 3 and w not in STOP and w not in extra_stop and not w.isdigit()]
    grams = set(words)
    grams.update(f"{x} {y}" for x, y in zip(words, words[1:]))
    return grams


def rank_terms(docs, min_count, top, extra_stop=frozenset()):
    """Count each term once per document; keep the frequent ones, bigrams before unigrams.
    A document is one title, or a list of phrases (a doc's name and headings); bigrams never
    span two phrases."""
    counts = {}
    for d in docs:
        grams = set()
        for phrase in ([d] if isinstance(d, str) else d):
            grams |= title_terms(phrase, extra_stop)
        for g in grams:
            counts[g] = counts.get(g, 0) + 1
    kept = [(g, c) for g, c in counts.items() if c >= min_count]
    kept.sort(key=lambda gc: (-gc[1], -len(gc[0].split()), gc[0]))
    return [{"term": g, "count": c} for g, c in kept[:top]]


def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


def merged_pr_titles(repo, cwd, since, branch):
    """Titles of PRs merged since `since`. Prefer gh; without gh auth, fall back to the
    first-parent commit subjects of the default branch (a squash merge's subject is the PR title)."""
    if repo:
        try:
            out = subprocess.run(
                ["gh", "pr", "list", "--repo", repo, "--state", "merged", "--limit", "300",
                 "--search", f"merged:>={since.isoformat()}", "--json", "title", "--jq", ".[].title"],
                cwd=cwd, capture_output=True, text=True, timeout=120)
            if out.returncode == 0:
                return [t for t in out.stdout.splitlines() if t.strip()], "gh pr list"
            print(f"profile: gh unavailable ({out.stderr.strip()[:120]}); using git log", file=sys.stderr)
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"profile: gh unavailable ({e}); using git log", file=sys.stderr)
    subjects = git(["log", "--first-parent", f"--since={since.isoformat()}", "--pretty=%s", branch], cwd)
    return [s for s in subjects.splitlines() if s.strip()], f"git log --first-parent {branch}"


def changed_design_docs(roots, cwd, since, branch):
    if not roots:
        return []
    out = git(["log", f"--since={since.isoformat()}", "--name-only", "--pretty=format:", branch,
               "--", *roots], cwd)
    paths = sorted({p for p in out.splitlines() if p.strip().lower().endswith(".md")})
    return [p for p in paths if os.path.exists(os.path.join(cwd, p))]


def heading_key(text):
    """A heading with dates, numbers and punctuation stripped, so one template's instances match."""
    return " ".join(re.findall(r"[a-z]+", text.lower()))


def doc_signals(path, cwd):
    """A changed doc's concepts come from its name and its top-level headings, not its body.
    Returned as separate phrases so no bigram spans two headings."""
    name = os.path.splitext(os.path.basename(path))[0].replace("_", " ").replace("-", " ")
    heads = []
    try:
        with open(os.path.join(cwd, path), errors="replace") as f:
            for line in f:
                m = re.match(r"^#{1,2}\s+(.+)", line)
                if m:
                    heads.append(m.group(1))
                if len(heads) >= 12:
                    break
    except OSError:
        pass
    return [name, *heads]


def drop_template_headings(docs):
    """Remove phrases (headings, or dated filenames) that recur verbatim across many docs: a
    report series' "Summary" / "Open questions" / "Daily changelog — <date>" say nothing about
    what the repo is working on."""
    seen = {}
    for phrases in docs:
        for k in {heading_key(p) for p in phrases}:
            seen[k] = seen.get(k, 0) + 1
    template = {k for k, n in seen.items() if n >= TEMPLATE_MIN_DOCS}
    return [[p for p in phrases if heading_key(p) not in template] for phrases in docs]


def read_interests(path):
    """One interest per line; bullets, blank lines and '#' headings/comments are ignored."""
    if not path or not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = re.sub(r"^\s*[-*+]\s+", "", line).strip()
            if line and not line.startswith("#"):
                out.append(line.lower())
    return out


def cmd_profile(a):
    cfg = {}
    if a.config and os.path.exists(a.config):
        with open(a.config) as f:
            cfg = json.load(f)
    rr = cfg.get("researchRadar") or {}
    paths = cfg.get("paths") or {}
    since = utc_today() - dt.timedelta(weeks=a.weeks)
    branch = a.branch or f"origin/{cfg.get('defaultBranch', 'main')}"
    try:
        git(["rev-parse", "--verify", "--quiet", branch], a.repo_root)
    except subprocess.CalledProcessError:
        branch = "HEAD"

    themes = rr.get("themes")
    core = [t.lower() for t in (themes if isinstance(themes, list) else [])]
    core += [p.lower() for p in a.phrase]
    categories = sorted(set(rr.get("categories") or []) | set(a.category))
    if not categories:
        die("no arXiv categories: set researchRadar.categories or pass --category")

    interests_path = a.interests or rr.get("interestsFile")
    if not interests_path and paths.get("researchRadarDir"):
        interests_path = os.path.join(paths["researchRadarDir"], "interests.md")
    if interests_path and not os.path.isabs(interests_path):
        interests_path = os.path.join(a.repo_root, interests_path)
    interests = read_interests(interests_path)

    # The repo's own name is in half its titles and in no paper worth finding.
    own = frozenset(w for w in re.findall(r"[a-z0-9]+", (cfg.get("repo") or "").lower()) if len(w) >= 3)
    titles, title_source = merged_pr_titles(None if a.no_gh else cfg.get("repo"), a.repo_root, since, branch)
    design_roots = paths.get("designDocs") or []
    if isinstance(design_roots, str):
        design_roots = [design_roots]
    docs = changed_design_docs(design_roots, a.repo_root, since, branch)

    profile = {
        "generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lookbackWeeks": a.weeks,
        "since": since.isoformat(),
        "categories": categories,
        "core": sorted(set(core)),
        "interests": {"file": os.path.relpath(interests_path, a.repo_root) if interests_path else None,
                      "terms": interests},
        "prTitles": {"source": title_source, "count": len(titles),
                     "terms": rank_terms(titles, a.min_title_count, a.top_titles, own)},
        "designDocs": {"roots": design_roots, "count": len(docs),
                       "terms": rank_terms(drop_template_headings([doc_signals(p, a.repo_root) for p in docs]),
                                           a.min_doc_count, a.top_docs, own)},
    }
    json.dump(profile, sys.stdout, indent=2)
    print()


def profile_terms(profile):
    """term -> weight. Hand-given phrases outweigh derived ones; a derived bigram outweighs a unigram."""
    w = {}
    for t in profile["core"] + profile["interests"]["terms"]:
        w[t] = max(w.get(t, 0), 3)
    for src in ("prTitles", "designDocs"):
        for e in profile[src]["terms"]:
            w[e["term"]] = max(w.get(e["term"], 0), 2 if " " in e["term"] else 1)
    return w


# ── prefilter ────────────────────────────────────────────────────────────────────────────


def reported_ids(report_dir):
    ids = set()
    if report_dir and os.path.isdir(report_dir):
        for name in os.listdir(report_dir):
            if name.endswith(".md"):
                with open(os.path.join(report_dir, name), errors="replace") as f:
                    ids.update(m.group(1).lower() for m in ARXIV_ID.finditer(f.read()))
    return ids


def term_pattern(term):
    return re.compile(r"(?<![a-z0-9])" + r"[\s-]+".join(map(re.escape, term.split())) + r"(?![a-z0-9])")


def submitted_too_early(arxid, created, floor):
    """True for a revision of an old paper. `<created>` alone isn't enough: arXiv's OAI feed has
    been seen reporting a recent `<created>` for a paper whose id says it was submitted months
    earlier, so a new-style id's YYMM prefix is checked too. Old-style ids (cs/0101001) predate 2007."""
    if dt.date.fromisoformat(created) < floor:
        return True
    m = NEW_ID.match(arxid)
    if m is None:
        return "/" in arxid
    return (2000 + int(m.group(1)), int(m.group(2))) < (floor.year, floor.month)


def cmd_prefilter(a):
    m = load_manifest(a.manifest)
    with open(a.profile) as f:
        profile = json.load(f)
    state = load_state(a.state)
    weights = profile_terms(profile)
    patterns = {t: term_pattern(t) for t in weights}
    cats = set(profile["categories"])
    frm, until = dt.date.fromisoformat(m["from"]), dt.date.fromisoformat(m["until"])
    created_floor = frm - dt.timedelta(days=CREATED_GRACE_DAYS)
    reported = reported_ids(a.reported_dir)
    recent = set((state or {}).get("recentIds", []))

    stats = dict(records=0, deleted=0, oldRevisions=0, category=0, terms=0,
                 alreadyReported=0, alreadySeen=0, survivors=0)
    seen, in_cat, out = set(), [], []
    for path in m["pages"]:
        try:
            root = ET.parse(path).getroot()
        except (OSError, ET.ParseError) as e:
            die(f"cannot parse harvested page {path} ({e}); stop, do not open a PR")
        for r in root.iter(f"{OAI}record"):
            stats["records"] += 1
            header = r.find(f"{OAI}header")
            if header is not None and header.get("status") == "deleted":
                stats["deleted"] += 1
                continue
            md = r.find(f"{OAI}metadata/{ARX}arXiv")
            if md is None:
                continue
            arxid = (md.findtext(f"{ARX}id") or "").strip().lower()
            created = (md.findtext(f"{ARX}created") or "")[:10]
            if not arxid or not created or arxid in seen:
                continue
            seen.add(arxid)
            if created > until.isoformat() or submitted_too_early(arxid, created, created_floor):
                stats["oldRevisions"] += 1  # first submitted long ago; only a revision/metadata touch
                continue
            categories = (md.findtext(f"{ARX}categories") or "").split()
            if not set(categories) & cats:
                continue
            stats["category"] += 1
            title = " ".join((md.findtext(f"{ARX}title") or "").split())
            abstract = " ".join((md.findtext(f"{ARX}abstract") or "").split())
            text = f"{title} {abstract}".lower()
            authors = [f"{x.findtext(f'{ARX}forenames') or ''} {x.findtext(f'{ARX}keyname') or ''}".strip()
                       for x in md.findall(f"{ARX}authors/{ARX}author")]
            in_cat.append({"id": arxid, "url": f"https://arxiv.org/abs/{arxid}", "title": title,
                           "abstract": abstract, "submitted": created,
                           "primary": categories[0] if categories else "",
                           "authors": [x for x in authors if x][:6],
                           "hits": {t for t, p in patterns.items() if p.search(text)}})

    # A derived term that shows up in a large share of this harvest ("agent", "model" in cs.AI)
    # separates nothing; it may still be listed as matched but it neither admits nor scores.
    df = {t: sum(t in r["hits"] for r in in_cat) for t in weights}
    background = sorted(t for t in weights if weights[t] < 3 and in_cat
                        and df[t] > BACKGROUND_DF * len(in_cat))
    for r in in_cat:
        hits = sorted(r.pop("hits"))
        signal = [t for t in hits if t not in background]
        # One hand-given phrase is enough; derived terms are noisier, so ask for two.
        if not (any(weights[t] >= 3 for t in signal) or len(signal) >= 2):
            continue
        stats["terms"] += 1
        if r["id"] in reported:
            stats["alreadyReported"] += 1
            continue
        if r["id"] in recent:
            stats["alreadySeen"] += 1
            continue
        out.append({**r, "matched": signal, "score": sum(weights[t] for t in signal),
                    "coreHits": sum(weights[t] >= 3 for t in signal)})
    # Hand-given phrases first, so a cap at --max never drops a core hit for a pile of unigrams.
    out.sort(key=lambda c: (-c["coreHits"], -c["score"], c["id"]))
    stats["survivors"] = len(out)
    capped = out[: a.max]
    result = {"responseDate": m["responseDate"], "from": m["from"], "until": m["until"],
              "windowSource": m["windowSource"], "stats": stats, "backgroundTerms": background,
              "returned": len(capped),
              "candidates": capped,
              # every survivor, not just the returned slice, so the next run skips all of them
              "survivorIds": [c["id"] for c in out]}
    json.dump(result, sys.stdout, indent=2)
    print()
    print(f"prefilter: {json.dumps(stats)}; returning {len(capped)}", file=sys.stderr)


# ── advance ──────────────────────────────────────────────────────────────────────────────


def cmd_advance(a):
    m = load_manifest(a.manifest)
    with open(a.candidates) as f:
        cand = json.load(f)
    if cand.get("responseDate") != m["responseDate"]:
        die("candidates were not produced from this manifest; refusing to advance the mark")
    prev = load_state(a.state)
    recent = list(dict.fromkeys(cand["survivorIds"] + ((prev or {}).get("recentIds") or [])))
    state = {
        "version": STATE_VERSION,
        "highWater": {"responseDate": m["responseDate"], "from": m["from"], "until": m["until"],
                      "sets": m["sets"]},
        "recentIds": recent[:RECENT_IDS_KEEP],
    }
    os.makedirs(os.path.dirname(os.path.abspath(a.state)), exist_ok=True)
    tmp = a.state + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.replace(tmp, a.state)
    print(f"advance: mark {prev['highWater']['responseDate'] if prev else '(none)'} -> "
          f"{m['responseDate']}", file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("harvest", help="fetch the window since the last complete harvest")
    h.add_argument("--state", required=True, help="state file (may not exist yet)")
    h.add_argument("--out", required=True, help="fresh empty directory for pages + manifest.json")
    h.add_argument("--ua", required=True, help="courtesy User-Agent")
    h.add_argument("--set", action="append", required=True, help="top-level arXiv archive; repeatable")
    h.set_defaults(fn=cmd_harvest)

    pr = sub.add_parser("profile", help="build the interest profile from the repo")
    pr.add_argument("--config", default=".claude/maintainerd.json")
    pr.add_argument("--repo-root", default=".")
    pr.add_argument("--branch", help="default: origin/<defaultBranch>, else HEAD")
    pr.add_argument("--weeks", type=int, default=4, help="look-back for PRs and design docs")
    pr.add_argument("--phrase", action="append", default=[], help="core phrase from step 1; repeatable")
    pr.add_argument("--category", action="append", default=[], help="arXiv category; repeatable")
    pr.add_argument("--interests", help="interests file (default: researchRadar.interestsFile, "
                                        "else <researchRadarDir>/interests.md)")
    pr.add_argument("--no-gh", action="store_true", help="skip gh; use git log subjects")
    pr.add_argument("--min-title-count", type=int, default=3)
    pr.add_argument("--top-titles", type=int, default=40)
    pr.add_argument("--min-doc-count", type=int, default=2)
    pr.add_argument("--top-docs", type=int, default=25)
    pr.set_defaults(fn=cmd_profile)

    pf = sub.add_parser("prefilter", help="filter a complete harvest against the profile")
    pf.add_argument("--manifest", required=True)
    pf.add_argument("--profile", required=True)
    pf.add_argument("--state", help="state file, for ids seen by earlier runs")
    pf.add_argument("--reported-dir", help="digest directory; ids in its *.md are skipped")
    pf.add_argument("--max", type=int, default=150, help="candidates returned for ranking")
    pf.set_defaults(fn=cmd_prefilter)

    ad = sub.add_parser("advance", help="move the high-water mark after a complete prefilter")
    ad.add_argument("--manifest", required=True)
    ad.add_argument("--candidates", required=True, help="prefilter output for this manifest")
    ad.add_argument("--state", required=True)
    ad.set_defaults(fn=cmd_advance)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
