#!/usr/bin/env python3
"""Classify a dependency PR's bump level from the ACTUAL manifest/lockfile diff.

The dependabot skill gates auto-merge on the bump level. Judging that level from the PR title
is how a `requirement >=2.43.0 to >=2.46.0` update (a minor) merged under a patch-only policy
(maintainerd#69), so the level is computed here, deterministically, from the unified diff, and
the title and Dependabot's own metadata are only cross-checks.

  gh pr diff <N> | classify-bump.py [--title T] [--body-file F] [--allow patch,minor]
  classify-bump.py --diff pr.diff --title "..." --body-file body.md

Output is one JSON object on stdout:

  level      "patch" | "minor" | "major": the HIGHEST level found anywhere in the diff
  confident  false when anything could not be classified, or the cross-checks disagree
  eligible   only with --allow: confident AND level is in the allowed list
  packages   one entry per version change found (name, from, to, kind, level, file)
  reasons    why it is not confident (also names the level as "unknown" when that is the case)

FAILS CLOSED. When it cannot tell, `level` is "major" and `confident` is false, so a caller that
reads either field holds the PR. Exit code is 0 for any classification (including "unknown"),
2 for a usage error; a caller must treat a non-zero exit or unparseable output as major.

Level rules (the same ones the skill documents): differing major is major, else differing minor
is minor, else patch. A pre-1.0 minor bump counts as major and a pre-1.0 patch bump as minor.
A range change is judged on both bounds (`^`, `~`, `~=` carry an implicit upper bound), so a
requirement that widens or raises across a minor or major is that level. A package that was
added, removed, downgraded, pinned to a SHA/digest/URL with no version, or written in a form
this script does not parse is unknown. Standard library only.
"""

import argparse
import json
import re
import sys

ORDER = {"patch": 1, "minor": 2, "major": 3}
NAMES = {1: "patch", 2: "minor", 3: "major"}

# uv.lock / poetry.lock / Cargo.lock keys that carry neither a version, a source nor an artifact:
# dependency edges and metadata. A changed line matching nothing here, and none of the stricter
# rules in extract_toml_lock, is Unknown.
TOML_NOISE = re.compile(
    r'^\s*("?(dependencies|dev-dependencies|optional-dependencies|requires-dist|requires-python|'
    r'resolution-markers|marker|markers|extra|extras|optional|description|python-versions|'
    r'groups|category)"?\s*=|(sdist|wheels|files)\s*=\s*\[\s*$|\{\s*name\s*=|\},?\s*$|\],?\s*$|\[\s*$)'
)
# Keys that say WHERE a package comes from. Any change to one is held: a same-version source swap
# is exactly what a version-only check cannot see.
TOML_SOURCE = re.compile(
    r'^\s*(source|url|reference|resolved_reference|type|registry|git|path|editable|directory|'
    r'virtual|index)\s*='
)
SOURCE_KEYS_INLINE = re.compile(r'\b(git|path|editable|directory|registry|index|url)\s*=')
ARTIFACT_REF = re.compile(r'\b(?:url|file)\s*=\s*"([^"]+)"')
HASH_ONLY = re.compile(r'^\s*"?(checksum|hash|size|upload-time)"?\s*=')


class Unknown(Exception):
    """Raised for anything this script cannot classify with confidence."""


# --------------------------------------------------------------------------------- versions
VER = re.compile(r"^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?$")


def parse_version(text):
    """-> (major, minor, patch, extra) ints. Anything with a suffix (rc, beta, post, +build) or a
    non-numeric part is Unknown: a prerelease or local build is not a level we can reason about."""
    m = VER.match(text.strip())
    if not m:
        raise Unknown(f"version {text!r} is not a plain numeric version")
    return tuple(int(g) if g is not None else 0 for g in m.groups())


def bump_level(old, new):
    """Level of moving from version tuple `old` to `new`, or None when equal."""
    if old == new:
        return None
    if new < old:
        return "major"  # a downgrade is never routine
    if old[0] != new[0]:
        return "major"
    if old[0] == 0:
        # pre-1.0: a minor bump may break (-> major), a patch bump may add features (-> minor)
        if old[1] != new[1]:
            return "major"
        if old[2] != new[2]:
            return "minor"
        return "patch"
    if old[1] != new[1]:
        return "minor"
    return "patch"


def hi(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return a if ORDER[a] >= ORDER[b] else b


# ------------------------------------------------------------------------------------ specs
CLAUSE = re.compile(r"^(===|==|>=|<=|~=|~>|!=|\^|~|>|<|=)?\s*(\S+)$")


def _upper_caret(v):
    if v[0] != 0:
        return (v[0] + 1, 0, 0, 0)
    if v[1] != 0:
        return (0, v[1] + 1, 0, 0)
    return (0, 0, v[2] + 1, 0)


def parse_spec(spec):
    """-> (lower, upper, excluded); lower/upper are (version tuple, inclusive) or None.

    Strict on purpose: a bound given twice, an exact or inclusive-upper version with fewer than three
    parts (npm reads `1` and `<=1.2` as ranges), and anything else whose meaning depends on the
    ecosystem is Unknown rather than guessed."""
    spec = spec.split(";")[0].strip()
    if not spec or "||" in spec or "@" in spec or "*" in spec or spec.lower() in ("latest", "x"):
        raise Unknown(f"requirement {spec!r} is not a simple version range")
    lower = upper = None
    excluded = []
    clauses = [c for c in re.split(r"\s*,\s*|\s+(?=[<>=!~^])", spec) if c]
    if not clauses:
        raise Unknown(f"requirement {spec!r} is empty")

    def set_bound(cur, new, which):
        if cur is not None:
            raise Unknown(f"requirement {spec!r} gives its {which} bound more than once")
        return new

    for clause in clauses:
        m = CLAUSE.match(clause.strip())
        if not m:
            raise Unknown(f"requirement clause {clause!r} is not understood")
        op, ver = m.group(1) or "==", m.group(2)
        if re.search(r"[xX]$", ver) or "*" in ver:
            raise Unknown(f"requirement {spec!r} uses a wildcard")
        v = parse_version(ver)
        parts = len(ver.lstrip("vV").split("."))
        if parts < 3 and op in ("==", "===", "=", "<=", ">"):
            raise Unknown(f"requirement {spec!r} has a partial version whose range is ecosystem-specific")
        if op in ("==", "===", "="):
            lower = set_bound(lower, (v, True), "lower")
            upper = set_bound(upper, (v, True), "upper")
        elif op in (">=", ">"):
            lower = set_bound(lower, (v, op == ">="), "lower")
        elif op in ("<=", "<"):
            upper = set_bound(upper, (v, op == "<="), "upper")
        elif op == "!=":
            excluded.append(v)
        elif op == "^":
            lower = set_bound(lower, (v, True), "lower")
            upper = set_bound(upper, (_upper_caret(v), False), "upper")
        elif op in ("~", "~>"):
            lower = set_bound(lower, (v, True), "lower")
            up = (v[0] + 1, 0, 0, 0) if parts == 1 else (v[0], v[1] + 1, 0, 0)
            upper = set_bound(upper, (up, False), "upper")
        elif op == "~=":
            lower = set_bound(lower, (v, True), "lower")
            up = (v[0], v[1] + 1, 0, 0) if parts >= 3 else (v[0] + 1, 0, 0, 0)
            upper = set_bound(upper, (up, False), "upper")
    return lower, upper, tuple(sorted(excluded))


def range_level(old_spec, new_spec):
    """Level of a requirement change, judged on BOTH bounds. None when nothing moved."""
    if old_spec.strip() == new_spec.strip():
        return None
    lo_o, up_o, ex_o = parse_spec(old_spec)
    lo_n, up_n, ex_n = parse_spec(new_spec)
    if ex_o != ex_n:
        raise Unknown(f"excluded versions changed ({old_spec!r} -> {new_spec!r})")
    level = None
    for a, b in ((lo_o, lo_n), (up_o, up_n)):
        if (a is None) != (b is None):
            level = hi(level, "major")  # a bound appeared or vanished
        elif a is not None:
            if a[1] != b[1]:
                raise Unknown(f"a bound changed between inclusive and exclusive ({old_spec!r} -> {new_spec!r})")
            level = hi(level, bump_level(a[0], b[0]))
    # Same bounds, different spelling (`^1.2.3` -> `>=1.2.3,<2`): nothing moved.
    return level


# ------------------------------------------------------------------------------ diff parsing
def parse_diff(text):
    """-> list of (path, [(kind, line)]) with kind one of ' ', '-', '+' (hunks flattened,
    a marker ('@', '') between hunks so context tracking does not leak across them)."""
    files = []
    cur = None
    in_hunk = False
    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*) b/(.*)$", raw)
            cur = (m.group(2) if m else raw, [])
            files.append(cur)
            in_hunk = False
        elif cur is None:
            continue
        elif raw.startswith("@@"):
            in_hunk = True
            cur[1].append(("@", ""))
        elif not in_hunk:
            if raw.startswith("+++ ") and raw[4:].strip() not in ("/dev/null",):
                pass
            continue
        elif raw[:1] in (" ", "-", "+"):
            cur[1].append((raw[0], raw[1:]))
        elif raw.startswith("\\"):
            continue
    return files


def basename(path):
    return path.rsplit("/", 1)[-1]


def norm(name):
    return re.sub(r"[-_.]+", "-", name.split("[")[0].strip().lower())


# --------------------------------------------------------------------- per-format extraction
# Each extractor returns (removed, added): lists of (name, value) in diff order, where value is a
# requirement spec ("range" kind) or an exact version ("version" kind). A changed line it does not
# recognize raises Unknown.

REQ_NAME = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._\-]*)\s*(\[[^\]]*\])?\s*(.*)$")


def parse_requirement(text):
    """`name[extras] <specifiers> ; markers  # comment` -> (name, specifiers), else None."""
    s = re.sub(r"\s+#.*$", "", text.strip())
    s = s.split(";")[0].strip().rstrip(",").strip()
    s = s.strip("\"'").strip()
    m = REQ_NAME.match(s)
    if not m or not m.group(3) or not re.match(r"^[<>=!~^]", m.group(3)):
        return None
    return norm(m.group(1)), m.group(3).strip()


def _pairs_for_requirements(lines, kind_label):
    removed, added = [], []
    for kind, text in lines:
        if kind not in "-+":
            continue
        stripped = text.strip()
        if not stripped or stripped.startswith("#") or re.match(r"^(--hash=|\\)", stripped):
            continue
        if stripped.startswith("-"):
            raise Unknown(f"{kind_label}: option line {stripped!r} changed")
        pair = parse_requirement(text)
        if pair is None:
            raise Unknown(f"{kind_label}: cannot read requirement line {stripped!r}")
        (removed if kind == "-" else added).append(pair)
    return removed, added


POETRY_LINE = re.compile(r'^\s*([A-Za-z0-9][A-Za-z0-9._\-]*)\s*=\s*"([^"]+)"\s*,?\s*$')
NOT_DEPS = {"version", "name", "description", "requires-python", "readme", "license", "python_requires"}


def extract_pyproject(lines):
    removed, added = [], []
    for kind, text in lines:
        if kind not in "-+":
            continue
        s = text.strip()
        if not s or s.startswith("#"):
            continue
        m = POETRY_LINE.match(text)
        if m and m.group(1) not in NOT_DEPS and re.match(r"^[\^~<>=!\d]", m.group(2)):
            pair = (norm(m.group(1)), m.group(2))
        else:
            if not re.match(r'^\s*"[^"]*"\s*,?\s*(#.*)?$', text):
                raise Unknown(f"pyproject.toml: cannot read changed line {s!r}")
            pair = parse_requirement(text)
            if pair is None:
                raise Unknown(f"pyproject.toml: cannot read changed line {s!r}")
        (removed if kind == "-" else added).append(pair)
    return removed, added


def extract_requirements(lines):
    return _pairs_for_requirements(lines, "requirements")


NPM_DEP = re.compile(r'^\s*"((?:@[A-Za-z0-9._~\-]+/)?[A-Za-z0-9._~\-]+)"\s*:\s*"([^"]*)"\s*,?\s*$')


def extract_package_json(lines):
    removed, added = [], []
    for kind, text in lines:
        if kind not in "-+":
            continue
        if not text.strip() or re.match(r"^\s*[{}\[\],]*\s*$", text):
            continue
        m = NPM_DEP.match(text)
        if not m or m.group(1) in ("version", "name") or not re.match(r"^[\^~<>=v\d]", m.group(2)):
            raise Unknown(f"package.json: cannot read changed line {text.strip()!r}")
        (removed if kind == "-" else added).append((m.group(1).lower(), m.group(2)))
    return removed, added


def url_host(ref):
    m = re.match(r"^[A-Za-z][A-Za-z0-9+.\-]*://(?:[^@/]*@)?([^/:?#]+)", ref)
    return m.group(1).lower() if m else None


def artifact_names_version(ref, name, version):
    """True when the artifact's file name is `<name>-<version>` followed by a separator: how npm
    tarballs, sdists, wheels and poetry `file` entries are all named."""
    fname = ref.split("?")[0].split("#")[0].rstrip("/").rsplit("/", 1)[-1]
    bare = name.rsplit("/", 1)[-1]  # npm scope: @s/pkg -> pkg-1.2.3.tgz
    return norm(fname).startswith(f"{norm(bare)}-{norm(version)}-")


class Entries:
    """Per-entry bookkeeping for a lockfile: which package each changed line belongs to, whether
    that entry's version changed, and the hosts its artifacts were fetched from on each side.

    Artifact lines (url/resolved/file, hashes, checksums, integrity) legitimately change on every
    version bump, so they are accepted only when (1) they belong to a package entry, (2) that
    entry's version changed, (3) each artifact's file name carries the version of its side of the
    diff, and (4) every new artifact host is one the old side already used for that package.
    Anything else - an artifact swap at an unchanged version, a new host, an unreadable artifact -
    is Unknown.

    (1) is usually the entry in view. A hunk that starts mid-entry (a long `dependencies` list
    pushes uv's `sdist`/`wheels` past the diff's context) has no name in view; there an artifact
    with a file name is attributed to the ONE package in this file whose version change it names
    (`aiohttp-3.14.5.tar.gz` -> aiohttp, 3.14.4 -> 3.14.5), and then held to (2)-(4) as usual. A
    nameless line with no file name (a bare checksum or integrity) is Unknown."""

    def __init__(self, label):
        self.label = label
        self.entries = []
        self.cur = None
        self.orphans = []

    def start(self, name):
        self.cur = {"name": name, "old": None, "new": None, "artifacts": [], "sources": {"-": [], "+": []}}
        self.entries.append(self.cur)

    def clear(self):
        self.cur = None

    def version(self, kind, value):
        if self.cur is None or self.cur["name"] is None:
            raise Unknown(f"{self.label}: a version changed with no package in view")
        self.cur["old" if kind == "-" else "new"] = value

    def artifact(self, kind, ref, text):
        if self.cur is None or self.cur["name"] is None:
            if ref is None:
                raise Unknown(f"{self.label}: an artifact line changed with no package in view: {text.strip()!r}")
            self.orphans.append((kind, ref, text.strip()))
            return
        self.cur["artifacts"].append((kind, ref, text.strip()))

    def _adopt_orphans(self):
        for kind, ref, text in self.orphans:
            owners = []
            for e in self.entries:
                if e["name"] is None or e["old"] is None or e["new"] is None:
                    continue
                want = e["old"] if kind == "-" else e["new"]
                if artifact_names_version(ref, e["name"], want) and e not in owners:
                    owners.append(e)
            names = {e["name"] for e in owners}
            if len(names) != 1:
                raise Unknown(f"{self.label}: an artifact line changed with no package in view: {text!r}")
            owners[0]["artifacts"].append((kind, ref, text))

    def source(self, kind, text):
        """A source line may appear on both sides when the diff realigns around it; only a real
        difference between the entry's old and new source lines is a source change."""
        if self.cur is None:
            raise Unknown(f"{self.label}: a package source changed with no package in view ({text.strip()!r})")
        self.cur["sources"][kind].append(text.strip())

    def check(self):
        self._adopt_orphans()
        for e in self.entries:
            if sorted(e["sources"]["-"]) != sorted(e["sources"]["+"]):
                raise Unknown(f"{self.label}: {e['name'] or 'a package'}'s source changed")
            if not e["artifacts"]:
                continue
            if e["old"] is None or e["new"] is None:
                raise Unknown(f"{self.label}: {e['name']}'s artifact or checksum changed but its version did not")
            hosts = {"-": set(), "+": set()}
            for kind, ref, text in e["artifacts"]:
                if ref is None:
                    continue
                want = e["old"] if kind == "-" else e["new"]
                if not artifact_names_version(ref, e["name"], want):
                    raise Unknown(f"{self.label}: {e['name']} artifact {ref!r} does not name version {want}")
                host = url_host(ref)
                if "://" in ref and host is None:
                    raise Unknown(f"{self.label}: {e['name']} artifact {ref!r} has no readable host")
                hosts[kind].add(host)
            new_hosts = hosts["+"] - hosts["-"]
            if new_hosts:
                raise Unknown(f"{self.label}: {e['name']} is now fetched from a different host "
                              f"({', '.join(sorted(h or '?' for h in new_hosts))})")


NPM_ENTRY_NOISE = re.compile(
    r'^"(license|funding|engines|cpu|os|libc|dev|optional|devOptional|peer|inBundle|deprecated|'
    r'bin|type|url)"\s*:'
)
NPM_NESTED = {"dependencies", "devDependencies", "optionalDependencies", "peerDependencies",
              "peerDependenciesMeta", "engines", "funding", "bin"}


def extract_package_lock(lines):
    """Version changes keyed by their package entry, plus dependency ranges. `resolved` and
    `integrity` are held to the Entries rules; a changed package key, `name` (an npm alias),
    `link`, or `hasInstallScript` turning on is Unknown."""
    removed, added = [], []
    ents = Entries("package-lock.json")
    for kind, text in lines:
        if kind == "@":
            ents.clear()
            continue
        s = text.strip()
        km = re.match(r'^"([^"]*)"\s*:\s*\{\s*$', s)
        if km and km.group(1) not in NPM_NESTED:
            if kind != " ":
                raise Unknown(f"package-lock.json: package entry {km.group(1)!r} was added, removed or renamed")
            k = km.group(1)
            if "node_modules/" in k:
                k = k.rsplit("node_modules/", 1)[1]
            ents.start(k.lower() if k else None)
            continue
        if kind == " ":
            continue
        if not s or re.match(r"^[{}\[\],]*$", s) or km:
            continue
        vm = re.match(r'^"version"\s*:\s*"([^"]+)"\s*,?$', s)
        if vm:
            ents.version(kind, vm.group(1))
            (removed if kind == "-" else added).append((("v", ents.cur["name"]), vm.group(1)))
            continue
        rm = re.match(r'^"resolved"\s*:\s*"([^"]*)"\s*,?$', s)
        if rm:
            ents.artifact(kind, rm.group(1), text)
            continue
        if re.match(r'^"integrity"\s*:', s):
            ents.artifact(kind, None, text)
            continue
        if re.match(r'^"hasInstallScript"\s*:', s):
            if kind == "+" and re.search(r":\s*true", s):
                raise Unknown("package-lock.json: a package gained an install script (hasInstallScript)")
            continue
        if re.match(r'^"(name|link|lockfileVersion|requires)"\s*:', s):
            raise Unknown(f"package-lock.json: cannot accept changed line {s!r}")
        dm = NPM_DEP.match(text)
        if dm and re.match(r"^[\^~<>=v\d]", dm.group(2)):
            (removed if kind == "-" else added).append((("r", dm.group(1).lower()), dm.group(2)))
            continue
        if NPM_ENTRY_NOISE.match(s):
            continue
        raise Unknown(f"package-lock.json: cannot read changed line {s!r}")
    ents.check()
    return removed, added


def extract_toml_lock(lines):
    """uv.lock / poetry.lock / Cargo.lock: `[[package]]`, `name = "x"`, `version = "y"`, the
    entry's source and artifacts, and uv's inline `requires-dist` entries with a `specifier`.
    A changed name or `[[package]]` line (a package added, removed or renamed), any change to where
    a package comes from, and an artifact change that the Entries rules do not explain is Unknown."""
    removed, added = [], []
    ents = Entries("lockfile")
    for kind, text in lines:
        if kind == "@":
            ents.clear()
            continue
        s = text.strip()
        if s == "[[package]]":
            if kind != " ":
                raise Unknown("lockfile: a package entry was added or removed")
            ents.start(None)
            continue
        nm = re.match(r'^name\s*=\s*"([^"]+)"\s*$', text)
        if nm:
            if kind != " ":
                raise Unknown(f"lockfile: package name line changed ({s!r}): a package was added, removed or replaced")
            if ents.cur is None or ents.cur["name"] is not None:
                ents.start(norm(nm.group(1)))
            else:
                ents.cur["name"] = norm(nm.group(1))
            continue
        if kind == " ":
            continue
        if not s:
            continue
        vm = re.match(r'^version\s*=\s*"([^"]+)"\s*$', text)
        if vm:
            ents.version(kind, vm.group(1))
            (removed if kind == "-" else added).append((("v", ents.cur["name"]), vm.group(1)))
            continue
        if TOML_SOURCE.match(text):
            ents.source(kind, text)
            continue
        am = ARTIFACT_REF.search(text)
        if am and re.match(r'^\s*(sdist\s*=\s*\{|wheels\s*=\s*\[\s*\{|\{)', text):
            ents.artifact(kind, am.group(1), text)
            continue
        if HASH_ONLY.match(text):
            ents.artifact(kind, None, text)
            continue
        im = re.search(r'name\s*=\s*"([^"]+)"[^}]*?specifier\s*=\s*"([^"]+)"', text)
        if im and not SOURCE_KEYS_INLINE.search(text):
            (removed if kind == "-" else added).append((("r", norm(im.group(1))), im.group(2)))
            continue
        if SOURCE_KEYS_INLINE.search(text):
            raise Unknown(f"lockfile: a dependency source changed ({s!r})")
        if TOML_NOISE.match(text):
            continue
        raise Unknown(f"lockfile: cannot read changed line {s!r}")
    ents.check()
    return removed, added


USES = re.compile(r"^\s*-?\s*uses:\s*['\"]?([^@\s'\"]+)@([^\s'\"#]+)['\"]?\s*(?:#\s*(\S+).*)?$")


def extract_workflow(lines):
    """Each changed `uses:` line must be replaced IN PLACE: within a hunk, the n-th removed line of a
    change block pairs with the n-th added line, names the same action, and is identical apart from
    the ref and its version comment. Anything else - a step added, removed or reordered, a moved
    indent - is Unknown. A SHA pin is levelled by its `# vX.Y.Z` comment, so a SHA that moves while
    the comment does not is new code under an old version: Unknown."""
    removed, added = [], []
    blocks, minus, plus = [], [], []

    def flush():
        if minus or plus:
            blocks.append((list(minus), list(plus)))
        minus.clear()
        plus.clear()

    for kind, text in lines:
        if kind == "-":
            if plus:
                flush()
            minus.append(text)
        elif kind == "+":
            plus.append(text)
        else:
            flush()
    flush()

    def read(text):
        m = USES.match(text)
        if not m:
            raise Unknown(f"workflow: changed line is not a `uses:` version {text.strip()!r}")
        return m, text[:m.start(1)]

    i = 0
    for old_lines, new_lines in blocks:
        if len(old_lines) != len(new_lines):
            raise Unknown("workflow: a change adds or removes lines, not only `uses:` versions")
        for old_text, new_text in zip(old_lines, new_lines):
            (mo, po), (mn, pn) = read(old_text), read(new_text)
            action = mo.group(1).lower()
            if mn.group(1).lower() != action or po != pn:
                raise Unknown(f"workflow: {old_text.strip()!r} became {new_text.strip()!r}, not a version change in place")
            vals = []
            for m in (mo, mn):
                ref, comment = m.group(2), m.group(3)
                if re.fullmatch(r"[0-9a-fA-F]{40}", ref):
                    if not comment:
                        raise Unknown(f"workflow: {m.group(1)} is pinned to a SHA with no version comment")
                    vals.append((ref.lower(), comment))
                else:
                    vals.append((ref, ref))
            (ref_o, ver_o), (ref_n, ver_n) = vals
            if ref_o != ref_n and ver_o == ver_n:
                raise Unknown(f"workflow: {mo.group(1)}'s pinned ref changed but its version ({ver_o}) did not")
            key = ("a", action, i)
            i += 1
            removed.append((key, ver_o))
            added.append((key, ver_n))
    return removed, added


def extract_go_mod(lines):
    removed, added = [], []
    for kind, text in lines:
        if kind not in "-+":
            continue
        m = re.match(r"^\s*(?:require\s+)?(\S+)\s+(v\S+?)(?:\s*//.*)?\s*$", text)
        if not m:
            raise Unknown(f"go.mod: cannot read changed line {text.strip()!r}")
        (removed if kind == "-" else added).append((m.group(1), m.group(2)))
    return removed, added


def classify_file(path):
    base = basename(path)
    if base in ("uv.lock", "poetry.lock", "Cargo.lock"):
        return "toml-lock", extract_toml_lock
    if base == "package-lock.json" or base == "npm-shrinkwrap.json":
        return "npm-lock", extract_package_lock
    if base == "package.json":
        return "range", extract_package_json
    if base == "pyproject.toml":
        return "range", extract_pyproject
    if re.match(r"^requirements.*\.txt$", base):
        return "range", extract_requirements
    if re.match(r"^\.github/(workflows|actions)/", path) and path.endswith((".yml", ".yaml")):
        return "action", extract_workflow
    if base == "go.mod":
        return "go", extract_go_mod
    if base == "go.sum":
        return "derived", None
    return None, None


def pair_up(removed, added, path, label):
    """Match removed to added by key, in order; any leftover is an add/remove -> Unknown."""
    out = []
    pool = {}
    for key, val in added:
        pool.setdefault(key, []).append(val)
    for key, old in removed:
        vals = pool.get(key)
        if not vals:
            raise Unknown(f"{path}: {key if isinstance(key, str) else key[1]} was removed or replaced")
        out.append((key, old, vals.pop(0)))
    for key, vals in pool.items():
        if vals:
            raise Unknown(f"{path}: {key if isinstance(key, str) else key[1]} was added")
    return out


def classify_diff(diff_text):
    pkgs, reasons = [], []
    files = parse_diff(diff_text)
    if not files:
        return pkgs, ["the diff is empty or unparseable"]
    paths = [p for p, _ in files]
    for path, lines in files:
        fmt, extract = classify_file(path)
        if fmt is None:
            reasons.append(f"{path}: not a recognized dependency-declaration file")
            continue
        if fmt == "derived":
            if "go.mod" not in [basename(p) for p in paths]:
                reasons.append(f"{path}: changed without a go.mod change")
            continue
        try:
            removed, added = extract(lines)
            if not removed and not added:
                reasons.append(f"{path}: no version change found")
                continue
            for key, old, new in pair_up(removed, added, path, fmt):
                name = key if isinstance(key, str) else key[1]
                is_range = fmt == "range" or (isinstance(key, tuple) and key[0] == "r")
                if is_range:
                    lvl = range_level(old, new)
                else:
                    lvl = bump_level(parse_version(old), parse_version(new))
                if lvl is None:
                    continue
                pkgs.append({"name": name, "from": old, "to": new,
                             "kind": "range" if is_range else "version", "level": lvl, "file": path})
        except Unknown as exc:
            reasons.append(str(exc))
    if not pkgs and not reasons:
        reasons.append("no version change found in the diff")
    return pkgs, reasons


# -------------------------------------------------------------------------------- cross-checks
TITLE = re.compile(
    r"(?:bump|update)\s+(\S+?)(?:\s+requirement)?\s+from\s+(\S+)\s+to\s+(\S+?)(?:\s+in\s+.*)?$", re.I
)


def title_check(title, pkgs, reasons):
    m = TITLE.search(title.strip())
    if not m:
        return  # a grouped or free-form title makes no single-package claim
    name = norm(m.group(1))
    try:
        try:
            claimed = bump_level(parse_version(m.group(2)), parse_version(m.group(3)))
        except Unknown:
            claimed = range_level(m.group(2), m.group(3))
    except Unknown:
        reasons.append(f"title claims an update of {m.group(1)} that cannot be levelled")
        return
    found = None
    for p in pkgs:
        if norm(p["name"]) == name:
            found = hi(found, p["level"])
    if found is None:
        reasons.append(f"title names {m.group(1)} but the diff has no version change for it")
    elif found != claimed:
        reasons.append(f"title claims {claimed} for {m.group(1)} but the diff shows {found}")


def metadata_check(body, pkgs, reasons):
    """Dependabot's `updated-dependencies` YAML block. It can only raise the level or flag a
    disagreement; it is never trusted to lower one."""
    extra = None
    for block in re.finditer(r"dependency-name:\s*(\S+)(.*?)(?=dependency-name:|\Z)", body, re.S):
        um = re.search(r"update-type:\s*version-update:semver-(major|minor|patch)", block.group(2))
        if not um:
            continue
        level = um.group(1)
        extra = hi(extra, level)
        name = norm(block.group(1))
        found = None
        for p in pkgs:
            if norm(p["name"]) == name:
                found = hi(found, p["level"])
        if found is not None and ORDER[level] > ORDER[found]:
            reasons.append(f"Dependabot metadata says {level} for {block.group(1)} but the diff shows {found}")
    return extra


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--diff", default="-", help="unified diff file, or - for stdin (default)")
    ap.add_argument("--title", default="")
    ap.add_argument("--body-file", default="")
    ap.add_argument("--allow", default=None, help="comma-separated levels eligible, e.g. patch,minor")
    args = ap.parse_args(argv)

    allow = None
    if args.allow is not None:
        allow = [a.strip() for a in args.allow.split(",") if a.strip()]
        if any(a not in ORDER for a in allow):
            print("--allow takes patch, minor and/or major", file=sys.stderr)
            return 2
    try:
        diff = sys.stdin.read() if args.diff == "-" else open(args.diff, encoding="utf-8").read()
        body = open(args.body_file, encoding="utf-8").read() if args.body_file else ""
    except OSError as exc:
        print(f"cannot read input: {exc}", file=sys.stderr)
        return 2

    pkgs, reasons = classify_diff(diff)
    if args.title:
        title_check(args.title, pkgs, reasons)
    meta_level = metadata_check(body, pkgs, reasons) if body else None

    level = None
    for p in pkgs:
        level = hi(level, p["level"])
    level = hi(level, meta_level)
    confident = not reasons and level is not None
    if not confident:
        level = "major"
        if not reasons:
            reasons.append("level unknown")
        else:
            reasons.insert(0, "level unknown")
    result = {"level": level, "confident": confident, "packages": pkgs, "reasons": reasons}
    if allow is not None:
        result["allowed"] = allow
        result["eligible"] = bool(confident and level in allow)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - fail closed on anything unexpected
        print(json.dumps({"level": "major", "confident": False, "packages": [],
                          "reasons": ["level unknown", f"classifier error: {exc}"]}))
        sys.exit(0)
