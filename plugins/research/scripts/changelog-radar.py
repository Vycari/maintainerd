#!/usr/bin/env python3
"""Mechanical steps of the changelog-radar skill: harvest, profile, prefilter, advance.

The judgment steps (evaluating relevance to open issues, assessing impact on repo code,
drafting the issue) stay with the model running the skill. Everything here is deterministic,
so it can be tested without network dependencies.

  harvest    fetch changelog RSS/Atom feeds and parse into normalized JSON records
  profile    build interest/technology profile from .claude/maintainerd.json, workflows,
             and dependency files
  prefilter  filter harvested records against state (dropping seen IDs and older items)
             and match against the repo profile
  advance    update the state high-water mark and remember recently seen record IDs

Standard library only. Exit status is non-zero on any failure, with the reason on stderr.
"""

import argparse
import datetime as dt
import email.utils
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

STATE_VERSION = 1
DEFAULT_FEED = "https://github.blog/changelog/feed/"
DEFAULT_STATE_DIR = "planning/changelog-radar"
RECENT_IDS_KEEP = 2000
LOOKBACK_DAYS = 30
BACKOFF = [5, 15, 30]

WORD = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
STOPWORDS = frozenset({
    "a", "about", "all", "an", "and", "any", "are", "as", "at", "be", "been", "being",
    "by", "for", "from", "has", "have", "in", "is", "it", "its", "new", "now", "of",
    "on", "or", "our", "out", "over", "so", "some", "than", "that", "the", "their",
    "then", "there", "these", "they", "this", "to", "under", "up", "was", "we", "were",
    "what", "when", "where", "which", "while", "who", "will", "with", "you", "your",
})

COMMAND_STOPWORDS = STOPWORDS | {
    "run", "check", "test", "lint", "format", "build", "exec", "cmd", "sh", "bash",
    "python", "node", "cli", "gh", "set", "env", "echo", "true", "false", "all",
    "src", "dir", "path", "file", "scripts", "script", "args", "exit",
}


def die(msg):
    sys.exit(f"changelog-radar: {msg}")


def parse_rfc822_or_iso(date_str):
    """Parse either RFC 822 (RSS) or ISO 8601 (Atom) into an ISO UTC datetime string."""
    if not date_str:
        return None
    date_str = date_str.strip()
    # Try RFC 822 first (standard in RSS)
    try:
        parsed_tuple = email.utils.parsedate_to_datetime(date_str)
        if parsed_tuple.tzinfo is None:
            parsed_tuple = parsed_tuple.replace(tzinfo=dt.timezone.utc)
        return parsed_tuple.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        pass
    # Try ISO 8601 (standard in Atom)
    try:
        clean = date_str.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(clean)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        pass
    return None


def parse_iso_dt(date_str):
    """Parse ISO UTC datetime string back into datetime object."""
    if not date_str:
        return None
    try:
        clean = date_str.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(clean)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except Exception:
        return None


def clean_html(text):
    """Strip basic HTML tags and collapse whitespace."""
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", text).strip()


# ── state ────────────────────────────────────────────────────────────────────────────────


def read_json_file(path):
    """Read a JSON file, tolerating UTF-8, UTF-8-BOM, and UTF-16 (from PowerShell > redirects)."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16")
    elif raw.startswith(b"\xef\xbb\xbf"):
        text = raw.decode("utf-8-sig")
    else:
        text = raw.decode("utf-8", errors="replace")
    return json.loads(text)


def load_state(path):
    if not path or not os.path.exists(path):
        return None
    try:
        state = read_json_file(path)
    except (OSError, json.JSONDecodeError) as e:
        die(f"state file {path} is unreadable ({e}); fix or remove it")
    if state.get("version") != STATE_VERSION:
        die(f"state file {path} has version {state.get('version')!r}, expected {STATE_VERSION}")
    return state


def save_state(path, state):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


# ── harvest ──────────────────────────────────────────────────────────────────────────────


def fetch_url(url, ua):
    """Fetch URL with retries on transient errors."""
    for attempt in range(len(BACKOFF) + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ua})
            with urllib.request.urlopen(req, timeout=30) as resp:
                if resp.status != 200:
                    die(f"fetch failed for {url}: HTTP {resp.status}")
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == len(BACKOFF):
                die(f"fetch failed for {url}: HTTP {e.code}")
            time_delay = BACKOFF[attempt]
            print(f"HTTP {e.code} from {url}; retrying in {time_delay}s", file=sys.stderr)
            import time
            time.sleep(time_delay)
        except (urllib.error.URLError, OSError) as e:
            if attempt == len(BACKOFF):
                die(f"network error fetching {url}: {e}")
            time_delay = BACKOFF[attempt]
            print(f"network error ({e}); retrying in {time_delay}s", file=sys.stderr)
            import time
            time.sleep(time_delay)


def parse_feed_xml(content_bytes):
    """Parse RSS 2.0 or Atom XML content into a list of record dicts."""
    try:
        root = ET.fromstring(content_bytes)
    except ET.ParseError as e:
        die(f"feed XML is malformed ({e})")

    # Validate that the root is an RSS or Atom feed element
    root_tag = root.tag
    if "}" in root_tag:
        root_tag = root_tag.split("}", 1)[1]
    if root_tag not in ("rss", "feed"):
        die(f"unrecognized XML root <{root.tag}>: not an RSS or Atom feed")

    records = []

    # Check for RSS 2.0 (<rss><channel><item>...)
    channel = root.find("channel")
    if channel is not None or root_tag == "rss":
        items = root.findall(".//item")
        for it in items:
            title = it.findtext("title", default="").strip()
            link = it.findtext("link", default="").strip()
            guid = it.findtext("guid", default="").strip() or link
            pub_date = parse_rfc822_or_iso(it.findtext("pubDate", default=""))
            desc = clean_html(it.findtext("description", default=""))
            cats = [c.text.strip().lower() for c in it.findall("category") if c.text and c.text.strip()]
            if title and (link or guid):
                records.append({
                    "id": guid,
                    "title": title,
                    "link": link or guid,
                    "published": pub_date,
                    "categories": sorted(set(cats)),
                    "summary": desc,
                })
        return records

    # Check for Atom (<feed><entry>...)
    ns = ""
    if root.tag.startswith("{"):
        ns = root.tag.split("}")[0] + "}"
    entries = root.findall(f".//{ns}entry")
    for entry in entries:
        title = entry.findtext(f"{ns}title", default="").strip()
        link_elem = entry.find(f"{ns}link")
        link = link_elem.attrib.get("href", "").strip() if link_elem is not None else ""
        entry_id = entry.findtext(f"{ns}id", default="").strip() or link
        pub_date = parse_rfc822_or_iso(
            entry.findtext(f"{ns}published", default="") or entry.findtext(f"{ns}updated", default="")
        )
        content = clean_html(
            entry.findtext(f"{ns}summary", default="") or entry.findtext(f"{ns}content", default="")
        )
        cats = [
            c.attrib.get("term", "").strip().lower()
            for c in entry.findall(f"{ns}category")
            if c.attrib.get("term")
        ]
        if title and (link or entry_id):
            records.append({
                "id": entry_id,
                "title": title,
                "link": link or entry_id,
                "published": pub_date,
                "categories": sorted(set(cats)),
                "summary": content,
            })

    return records


# ── profile ──────────────────────────────────────────────────────────────────────────────


def scan_workflows(cwd):
    """Extract action names, runner labels, and step names from .github/workflows/."""
    actions = set()
    runners = set()
    features = set()

    wf_dir = os.path.join(cwd, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        return actions, runners, features

    for fname in os.listdir(wf_dir):
        if not (fname.endswith(".yml") or fname.endswith(".yaml")):
            continue
        fpath = os.path.join(wf_dir, fname)
        try:
            with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError:
            continue

        # Look for actions: uses: foo/bar@...
        for m in re.finditer(r"uses:\s*([\w.-]+/[\w.-]+)@", content):
            act = m.group(1).lower()
            actions.add(act)
            # Add short name (e.g. 'checkout', 'setup-uv')
            short = act.split("/")[-1]
            features.add(short)

        # Look for runners: runs-on: ...
        for m in re.finditer(r"runs-on:\s*([^\s#]+)", content):
            runner = m.group(1).lower()
            runners.add(runner)

        # Look for key features: merge_group, concurrency, merge queue
        if "merge_group:" in content or "merge_group" in content:
            features.add("merge queue")
            features.add("merge_group")
        if "dependabot" in fname.lower():
            features.add("dependabot")

    return actions, runners, features


def scan_dependencies(cwd):
    """Scan root dependency and config files for tool and language signals."""
    tools = set()

    # Python
    if os.path.exists(os.path.join(cwd, "pyproject.toml")) or os.path.exists(os.path.join(cwd, "requirements.txt")):
        tools.add("python")
    if os.path.exists(os.path.join(cwd, "uv.lock")):
        tools.add("uv")
    if os.path.exists(os.path.join(cwd, "poetry.lock")):
        tools.add("poetry")

    # Node / JS
    if os.path.exists(os.path.join(cwd, "package.json")):
        tools.add("node")
        tools.add("npm")
    if os.path.exists(os.path.join(cwd, "pnpm-lock.yaml")):
        tools.add("pnpm")

    # Rust
    if os.path.exists(os.path.join(cwd, "Cargo.toml")):
        tools.add("rust")
        tools.add("cargo")

    # Go
    if os.path.exists(os.path.join(cwd, "go.mod")):
        tools.add("go")

    # Docker
    if os.path.exists(os.path.join(cwd, "Dockerfile")):
        tools.add("docker")

    return tools


def build_profile(cwd, config):
    """Assemble interest terms and technology profile from the repo."""
    technologies = set()
    terms = set()

    # From .claude/maintainerd.json
    lang = config.get("language")
    if lang:
        technologies.add(lang.lower())
        terms.add(lang.lower())

    cmds = config.get("commands", {}) or {}
    for cmd_str in cmds.values():
        if not cmd_str:
            continue
        for word in WORD.findall(cmd_str.lower()):
            if len(word) >= 2 and word not in COMMAND_STOPWORDS:
                terms.add(word)

    # Workflows
    wf_actions, wf_runners, wf_features = scan_workflows(cwd)
    technologies.update(wf_actions)
    technologies.update(wf_runners)
    technologies.update(wf_features)
    for act in wf_actions:
        terms.add(act)
        for part in act.split("/"):
            if len(part) >= 2 and part not in COMMAND_STOPWORDS:
                terms.add(part)
    for runner in wf_runners:
        terms.add(runner)
        for part in runner.split("-"):
            if len(part) >= 2 and part not in COMMAND_STOPWORDS:
                terms.add(part)

    # Dependencies & repo tools
    dep_tools = scan_dependencies(cwd)
    technologies.update(dep_tools)
    terms.update(dep_tools)

    # Core GitHub platform features that always matter to repo automation
    always_relevant = {
        "actions", "github actions", "workflow", "workflows", "runner", "runners",
        "dependabot", "codeql", "code scanning", "secret scanning", "security advisories",
        "merge queue", "merge queues", "lockfile", "lockfiles",
    }
    terms.update(always_relevant)

    # Explicit extra interests from config
    extra_interests = config.get("changelogRadar", {}).get("interests", [])
    for it in extra_interests:
        terms.add(it.lower())

    return {
        "technologies": sorted(technologies),
        "terms": sorted(terms),
    }


# ── prefilter ────────────────────────────────────────────────────────────────────────────


def score_record(rec, profile_terms):
    """Score record relevance based on title, category, and summary matches."""
    title_lower = rec["title"].lower()
    summary_lower = rec["summary"].lower()
    cats_lower = [c.lower() for c in rec.get("categories", [])]

    matched = set()
    score = 0

    for t in profile_terms:
        # Title match (highest weight)
        if re.search(r"\b" + re.escape(t) + r"\b", title_lower):
            matched.add(t)
            score += 10
        # Category match (exact or word boundary)
        elif any(t == c or re.search(r"\b" + re.escape(t) + r"\b", c) for c in cats_lower):
            matched.add(t)
            score += 5
        # Summary match
        elif re.search(r"\b" + re.escape(t) + r"\b", summary_lower):
            matched.add(t)
            score += 2

    return score, sorted(matched)


def prefilter(records, profile, state=None):
    """Filter out seen/old records and score surviving records by relevance."""
    recent_ids = set(state.get("recentIds", [])) if state else set()
    high_water = state.get("highWater", {}).get("publishedDate") if state else None
    hw_dt = parse_iso_dt(high_water) if high_water else None

    profile_terms = set(profile.get("terms", []))

    survivors = []
    for r in records:
        rid = r["id"]
        # Skip if already seen
        if rid in recent_ids:
            continue

        # Drop historical records older than the lookback window relative to high-water mark,
        # preventing old evicted items from looping indefinitely while preserving backdated entries.
        if hw_dt and r.get("published"):
            pub_dt = parse_iso_dt(r["published"])
            if pub_dt and (hw_dt - pub_dt).total_seconds() > LOOKBACK_DAYS * 86400:
                continue

        score, matched = score_record(r, profile_terms)
        if score > 0:
            survivors.append({
                **r,
                "score": score,
                "matchedTerms": matched,
            })

    # Sort descending by score, then newest date
    survivors.sort(key=lambda x: (-x["score"], x.get("published") or ""))
    return survivors


# ── CLI commands ─────────────────────────────────────────────────────────────────────────


def cmd_profile(args):
    cwd = os.path.abspath(args.cwd)
    cfg_path = os.path.join(cwd, ".claude", "maintainerd.json")
    config = {}
    if os.path.exists(cfg_path):
        try:
            config = read_json_file(cfg_path)
        except Exception as e:
            die(f"cannot parse {cfg_path}: {e}")
    prof = build_profile(cwd, config)
    print(json.dumps(prof, indent=2))


def cmd_harvest(args):
    feed_url = args.feed
    if not feed_url:
        cwd = os.path.abspath(args.cwd) if hasattr(args, "cwd") and args.cwd else os.getcwd()
        cfg_path = os.path.join(cwd, ".claude", "maintainerd.json")
        if os.path.exists(cfg_path):
            try:
                cfg = read_json_file(cfg_path)
                feed_url = cfg.get("changelogRadar", {}).get("feed")
            except Exception:
                pass
    feed_url = feed_url or DEFAULT_FEED
    ua = args.user_agent or "maintainerd-changelog-radar/1.0"
    content = fetch_url(feed_url, ua)
    records = parse_feed_xml(content)
    print(json.dumps(records, indent=2))


def cmd_prefilter(args):
    # Read harvested records from file or stdin
    if args.input:
        if not os.path.exists(args.input):
            die(f"input file {args.input} does not exist")
        if os.path.getsize(args.input) == 0:
            die(f"input file {args.input} is empty (harvest may have failed)")
        try:
            records = read_json_file(args.input)
        except Exception as e:
            die(f"cannot read input file {args.input}: {e}")
    else:
        try:
            records = json.load(sys.stdin)
        except Exception as e:
            die(f"cannot read input from stdin: {e}")

    # Read profile
    profile = read_json_file(args.profile)

    # Read state (optional)
    state = load_state(args.state) if args.state else None

    survivors = prefilter(records, profile, state)
    print(json.dumps(survivors, indent=2))


def cmd_advance(args):
    state_path = args.state
    if not state_path:
        die("--state is required for advance")

    state = load_state(state_path)
    current_mark = state.get("highWater", {}).get("publishedDate") if state else None

    # Compare-and-set mark verification (VR-1ae7cacf)
    if args.expected_mark is not None:
        expected = None if args.expected_mark in ("", "none", "null") else args.expected_mark
        if current_mark != expected:
            die(f"the state's mark is {current_mark or '(none)'} but this run started from "
                f"{expected or '(none)'}: another run advanced it since; refusing to overwrite. "
                "Start over from the latest state.")

    if not state:
        state = {
            "version": STATE_VERSION,
            "highWater": {"publishedDate": None},
            "recentIds": [],
        }

    # Only mark seen the items passed in --input (the evaluated survivors, VR-64c20138)
    if args.input:
        items = read_json_file(args.input)
    else:
        items = json.load(sys.stdin)

    seen_ids = list(state.get("recentIds", []))
    latest_date = current_mark

    for it in items:
        rid = it.get("id")
        if rid and rid not in seen_ids:
            seen_ids.insert(0, rid)
        pub = it.get("published")
        if pub and (not latest_date or pub > latest_date):
            latest_date = pub

    state["version"] = STATE_VERSION
    state["highWater"] = {"publishedDate": latest_date}
    state["recentIds"] = seen_ids[:RECENT_IDS_KEEP]

    save_state(state_path, state)
    print(f"advanced state {state_path}: highWater={latest_date}, {len(state['recentIds'])} recentIds")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="subcommand", required=True)

    # profile
    p_prof = sub.add_parser("profile", help="Extract tech profile from the repository")
    p_prof.add_argument("--cwd", default=".", help="Repo working directory")
    p_prof.set_defaults(func=cmd_profile)

    # harvest
    p_harv = sub.add_parser("harvest", help="Fetch RSS/Atom changelog feed into JSON records")
    p_harv.add_argument("--feed", default=None, help="Feed URL (default: GitHub changelog RSS)")
    p_harv.add_argument("--cwd", default=".", help="Repo working directory (to load config)")
    p_harv.add_argument("--user-agent", default=None, help="User agent string")
    p_harv.set_defaults(func=cmd_harvest)

    # prefilter
    p_pref = sub.add_parser("prefilter", help="Filter and score records against profile and state")
    p_pref.add_argument("--profile", required=True, help="Profile JSON file path")
    p_pref.add_argument("--input", default=None, help="Harvested JSON records file (or stdin)")
    p_pref.add_argument("--state", default=None, help="State JSON file path")
    p_pref.set_defaults(func=cmd_prefilter)

    # advance
    p_adv = sub.add_parser("advance", help="Advance state file with processed items")
    p_adv.add_argument("--state", required=True, help="State JSON file path")
    p_adv.add_argument("--input", default=None, help="JSON list of processed items (or stdin)")
    p_adv.add_argument("--expected-mark", default=None, help="Expected high-water mark timestamp for compare-and-set")
    p_adv.set_defaults(func=cmd_advance)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
