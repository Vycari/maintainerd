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

# Keys whose lines carry no version information in lockfiles (checksums, urls, sizes).
LOCK_NOISE = re.compile(
    r'^\s*("?(integrity|resolved|hash|sha\d*|url|size|checksum|checksums|upload-time|registry|'
    r'source|dependencies|dev|optional|peer|license|engines|bin|funding|cpu|os|libc|'
    r'inBundle|hasInstallScript|peerDependenciesMeta|deprecated|requires-python|'
    r'sdist|wheels|extra|name)"?\s*[:=]|\{\s*(url|path|name|filename)\b|\},?\s*$|\],?\s*$)'
)


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
    """-> (lower, upper, excluded) with lower/upper a version tuple or None."""
    spec = spec.split(";")[0].strip()
    if not spec or "||" in spec or "@" in spec or "*" in spec or spec.lower() in ("latest", "x"):
        raise Unknown(f"requirement {spec!r} is not a simple version range")
    lower = upper = None
    excluded = []
    clauses = [c for c in re.split(r"\s*,\s*|\s+(?=[<>=!~^])", spec) if c]
    if not clauses:
        raise Unknown(f"requirement {spec!r} is empty")
    for clause in clauses:
        m = CLAUSE.match(clause.strip())
        if not m:
            raise Unknown(f"requirement clause {clause!r} is not understood")
        op, ver = m.group(1) or "==", m.group(2)
        if re.search(r"[xX]$", ver) or "*" in ver:
            raise Unknown(f"requirement {spec!r} uses a wildcard")
        v = parse_version(ver)
        if op in ("==", "===", "="):
            lower = upper = v
        elif op in (">=", ">"):
            lower = v
        elif op in ("<=", "<"):
            upper = v
        elif op == "!=":
            excluded.append(v)
        elif op == "^":
            lower, upper = v, _upper_caret(v)
        elif op in ("~", "~>"):
            parts = len(ver.split("."))
            lower = v
            upper = (v[0] + 1, 0, 0, 0) if parts == 1 else (v[0], v[1] + 1, 0, 0)
        elif op == "~=":
            parts = len(ver.split("."))
            lower = v
            upper = (v[0], v[1] + 1, 0, 0) if parts >= 3 else (v[0] + 1, 0, 0, 0)
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
            level = hi(level, bump_level(a, b))
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


def extract_package_lock(lines):
    """Version changes keyed by the nearest preceding package key, plus dependency ranges."""
    removed, added = [], []
    key = None
    for kind, text in lines:
        if kind == "@":
            key = None
            continue
        km = re.match(r'^\s*"([^"]*)"\s*:\s*\{\s*$', text)
        if km:
            k = km.group(1)
            if "node_modules/" in k:
                k = k.rsplit("node_modules/", 1)[1]
            key = k
            continue
        if kind == " ":
            continue
        s = text.strip()
        if not s or re.match(r"^[{}\[\],]*$", s):
            continue
        vm = re.match(r'^"version"\s*:\s*"([^"]+)"\s*,?$', s)
        if vm:
            if key is None:
                raise Unknown("package-lock.json: a version changed with no package key in view")
            (removed if kind == "-" else added).append((("v", key.lower()), vm.group(1)))
            continue
        if re.match(r'^"(integrity|resolved|license|name|funding|engines|bin|cpu|os|libc|dev|optional|'
                    r'peer|inBundle|hasInstallScript|deprecated|lockfileVersion|requires)"\s*:', s):
            continue
        dm = NPM_DEP.match(text)
        if dm and re.match(r"^[\^~<>=v\d]", dm.group(2)):
            (removed if kind == "-" else added).append((("r", dm.group(1).lower()), dm.group(2)))
            continue
        raise Unknown(f"package-lock.json: cannot read changed line {s!r}")
    return removed, added


def extract_toml_lock(lines):
    """uv.lock / poetry.lock / Cargo.lock: `name = "x"` then `version = "y"`, and uv's inline
    `requires-dist` entries with a `specifier`."""
    removed, added = [], []
    name = None
    for kind, text in lines:
        if kind == "@":
            name = None
            continue
        nm = re.match(r'^\s*name\s*=\s*"([^"]+)"\s*$', text)
        if nm:
            name = norm(nm.group(1))
            if kind == "-" or kind == "+":
                continue  # a renamed package shows up as unmatched versions below
            continue
        if kind == " ":
            continue
        vm = re.match(r'^\s*version\s*=\s*"([^"]+)"\s*$', text)
        if vm:
            if name is None:
                raise Unknown("lockfile: a version changed with no package name in view")
            (removed if kind == "-" else added).append((("v", name), vm.group(1)))
            continue
        im = re.search(r'name\s*=\s*"([^"]+)"[^}]*?specifier\s*=\s*"([^"]+)"', text)
        if im:
            (removed if kind == "-" else added).append((("r", norm(im.group(1))), im.group(2)))
            continue
        if LOCK_NOISE.match(text) or not text.strip():
            continue
        raise Unknown(f"lockfile: cannot read changed line {text.strip()!r}")
    return removed, added


USES = re.compile(r"^\s*-?\s*uses:\s*['\"]?([^@\s'\"]+)@([^\s'\"#]+)['\"]?\s*(?:#\s*(\S+).*)?$")


def extract_workflow(lines):
    removed, added = [], []
    for kind, text in lines:
        if kind not in "-+":
            continue
        m = USES.match(text)
        if not m:
            raise Unknown(f"workflow: changed line is not a `uses:` version {text.strip()!r}")
        ref, comment = m.group(2), m.group(3)
        if re.fullmatch(r"[0-9a-fA-F]{40}", ref):
            if not comment:
                raise Unknown(f"workflow: {m.group(1)} is pinned to a SHA with no version comment")
            ref = comment
        (removed if kind == "-" else added).append((m.group(1).lower(), ref))
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
