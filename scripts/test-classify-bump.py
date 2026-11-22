#!/usr/bin/env python3
"""Tests for plugins/deps-flow/scripts/classify-bump.py.

The classifier decides which Dependabot PRs may auto-merge, so the cases here are the bypass
shapes: every title form from maintainerd#69, ranges, extras, 0.x, groups, and everything that
must fail closed. Runs the script as a subprocess, like the skill does.

  python3 scripts/test-classify-bump.py
"""

import json
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "plugins/deps-flow/scripts/classify-bump.py")


def run(diff, title="", body=None, allow=None):
    cmd = [sys.executable, SCRIPT]
    if title:
        cmd += ["--title", title]
    if allow is not None:
        cmd += ["--allow", allow]
    with __import__("tempfile").NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body or "")
        bf = f.name
    try:
        if body is not None:
            cmd += ["--body-file", bf]
        p = subprocess.run(cmd, input=diff, capture_output=True, text=True)
    finally:
        os.unlink(bf)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def hunk(path, removed, added, context=()):
    lines = [f"diff --git a/{path} b/{path}", f"--- a/{path}", f"+++ b/{path}", "@@ -1,9 +1,9 @@"]
    lines += [" " + c for c in context]
    lines += ["-" + r for r in removed]
    lines += ["+" + a for a in added]
    return "\n".join(lines) + "\n"


def one_file(first, *more):
    """Join hunks of the same file into one file diff (later hunks lose their file header)."""
    return first + "".join(h.split("\n", 3)[3] for h in more)


def pyproject(old, new, name="resend", extras=""):
    return hunk("pyproject.toml", [f'    "{name}{extras}{old}",'], [f'    "{name}{extras}{new}",'])


def uvlock(name, old, new):
    return hunk("uv.lock", [f'version = "{old}"'], [f'version = "{new}"'], context=[f'name = "{name}"'])


class Classify(unittest.TestCase):
    def level(self, diff, **kw):
        r = run(diff, **kw)
        return r["level"], r["confident"], r

    # --- the maintainerd#69 shapes -----------------------------------------------------------
    def test_resend_requirement_minor_is_minor_not_patch(self):
        d = pyproject(">=2.43.0", ">=2.46.0", extras="[async]") + uvlock("resend", "2.43.0", "2.46.0")
        lvl, conf, r = self.level(d, title="update resend[async] requirement from >=2.43.0 to >=2.46.0",
                                  allow="patch")
        self.assertEqual((lvl, conf), ("minor", True))
        self.assertFalse(r["eligible"])

    def test_resend_earlier_minor(self):
        d = pyproject(">=2.42.0", ">=2.43.0", extras="[async]")
        self.assertEqual(self.level(d)[:2], ("minor", True))

    def test_sqlalchemy_patch_requirement_is_patch(self):
        d = pyproject(">=2.0.52", ">=2.0.54", name="sqlalchemy", extras="[asyncio]") + uvlock("sqlalchemy", "2.0.52", "2.0.54")
        lvl, conf, r = self.level(d, title="update sqlalchemy[asyncio] requirement from >=2.0.52 to >=2.0.54", allow="patch")
        self.assertEqual((lvl, conf, r["eligible"]), ("patch", True, True))

    def test_uvicorn_standard_requirement_minor_0x_is_major(self):
        d = pyproject(">=0.52.4", ">=0.53.0", name="uvicorn", extras="[standard]")
        self.assertEqual(self.level(d)[:2], ("major", True))

    def test_requirement_with_unchanged_range_but_lock_jumps_a_minor(self):
        d = pyproject(">=2.43.0", ">=2.43.1") + uvlock("resend", "2.43.0", "2.50.0")
        self.assertEqual(self.level(d)[:2], ("minor", True))

    def test_lock_only_minor(self):
        self.assertEqual(self.level(uvlock("resend", "2.43.0", "2.46.0"))[:2], ("minor", True))

    def test_lock_only_patch_and_major(self):
        self.assertEqual(self.level(uvlock("x", "1.2.3", "1.2.4"))[:2], ("patch", True))
        self.assertEqual(self.level(uvlock("x", "1.2.3", "2.0.0"))[:2], ("major", True))

    # --- ranges ------------------------------------------------------------------------------
    def test_operators(self):
        cases = [
            ("~=1.2.3", "~=1.2.4", "patch"), ("~=1.2", "~=1.3", "minor"), ("~=1.2", "~=2.0", "major"),
            (">=1.2.0,<2", ">=1.3.0,<2", "minor"), (">=1.2.0,<2", ">=1.2.0,<3", "major"),
            ("==1.2.3", "==1.2.4", "patch"), (">=1.2", "~=1.2", "major"),
        ]
        for old, new, want in cases:
            with self.subTest(old=old, new=new):
                self.assertEqual(self.level(pyproject(old, new, name="pkg"))[:2], (want, True))

    def test_npm_ranges(self):
        for old, new, want in [("^1.2.3", "^1.2.4", "patch"), ("^1.2.3", "^1.3.0", "minor"),
                               ("~1.2.3", "~1.3.0", "minor"), ("^1.9.0", "^2.0.0", "major"),
                               ("^0.2.3", "^0.3.0", "major"), (">=1.0.0", ">=1.1.0", "minor")]:
            with self.subTest(old=old, new=new):
                d = hunk("package.json", [f'    "left-pad": "{old}",'], [f'    "left-pad": "{new}",'])
                self.assertEqual(self.level(d)[:2], (want, True))

    def test_zero_x_rules(self):
        self.assertEqual(self.level(uvlock("x", "0.4.2", "0.5.0"))[:2], ("major", True))
        self.assertEqual(self.level(uvlock("x", "0.4.2", "0.4.3"))[:2], ("minor", True))

    # --- groups, highest wins ----------------------------------------------------------------
    def test_group_takes_highest(self):
        d = uvlock("a", "1.0.0", "1.0.1") + uvlock("b", "2.1.0", "2.2.0") + uvlock("c", "3.0.0", "3.0.2")
        r = run(d, title="bump the python-minor group with 3 updates", allow="patch,minor")
        self.assertEqual((r["level"], r["confident"], r["eligible"]), ("minor", True, True))
        self.assertEqual(len(r["packages"]), 3)

    def test_group_one_major_holds_all(self):
        d = uvlock("a", "1.0.0", "1.0.1") + uvlock("b", "2.1.0", "3.0.0")
        self.assertEqual(self.level(d)[:2], ("major", True))

    # --- cross-checks ------------------------------------------------------------------------
    def test_title_disagreeing_with_diff_holds(self):
        d = uvlock("resend", "2.43.0", "2.46.0")
        lvl, conf, r = self.level(d, title="Bump resend from 2.43.0 to 2.43.1", allow="patch,minor,major")
        self.assertFalse(conf)
        self.assertFalse(r["eligible"])
        self.assertEqual(lvl, "major")

    def test_title_naming_a_package_absent_from_the_diff_holds(self):
        d = uvlock("other", "1.0.0", "1.0.1")
        self.assertFalse(self.level(d, title="Bump resend from 1.0.0 to 1.0.1")[1])

    def test_title_agreement_is_confident(self):
        d = uvlock("resend", "2.43.0", "2.43.1")
        self.assertEqual(self.level(d, title="Bump resend from 2.43.0 to 2.43.1")[:2], ("patch", True))

    def test_metadata_can_raise_never_lower(self):
        body = "---\nupdated-dependencies:\n- dependency-name: resend\n  update-type: version-update:semver-major\n"
        d = uvlock("resend", "2.43.0", "2.43.1")
        lvl, conf, _ = self.level(d, body=body)
        self.assertEqual((lvl, conf), ("major", False))
        body = body.replace("major", "patch")
        self.assertEqual(self.level(uvlock("resend", "2.43.0", "2.46.0"), body=body)[:2], ("minor", True))

    # --- fail closed -------------------------------------------------------------------------
    def assertHeld(self, diff, **kw):
        lvl, conf, r = self.level(diff, **kw)
        self.assertEqual((lvl, conf), ("major", False), r)
        self.assertIn("level unknown", r["reasons"])

    def test_empty_and_garbage(self):
        self.assertHeld("")
        self.assertHeld("not a diff at all\n")

    def test_source_file_in_the_diff_holds(self):
        self.assertHeld(uvlock("x", "1.0.0", "1.0.1") + hunk("src/app.py", ["a = 1"], ["a = 2"]))

    def test_dependabot_config_in_the_diff_holds(self):
        self.assertHeld(uvlock("x", "1.0.0", "1.0.1") + hunk(".github/dependabot.yml", ["a: 1"], ["a: 2"]))

    def test_prerelease_and_suffix_versions_hold(self):
        self.assertHeld(uvlock("x", "1.0.0", "1.1.0rc1"))
        self.assertHeld(uvlock("x", "1.0.0", "1.0.1+local"))

    def test_added_or_removed_dependency_holds(self):
        self.assertHeld(hunk("pyproject.toml", [], ['    "newdep>=1.0",']))
        self.assertHeld(hunk("pyproject.toml", ['    "gone>=1.0",'], []))

    def test_downgrade_is_major(self):
        self.assertEqual(self.level(uvlock("x", "1.5.0", "1.4.0"))[:2], ("major", True))

    def test_wildcards_urls_and_alternations_hold(self):
        for old, new in [("*", "1.0.0"), ("^1.2.3 || ^2.0.0", "^1.2.4 || ^2.0.0"), ("latest", "^1.0.0")]:
            with self.subTest(old=old):
                self.assertHeld(hunk("package.json", [f'    "x": "{old}",'], [f'    "x": "{new}",']))
        self.assertHeld(hunk("package.json", ['    "x": "github:o/r#abc",'], ['    "x": "github:o/r#def",']))

    def test_unparsed_lock_formats_hold(self):
        self.assertHeld(hunk("yarn.lock", ['  version "1.0.0"'], ['  version "1.0.1"']))
        self.assertHeld(hunk("pnpm-lock.yaml", ["  x@1.0.0:"], ["  x@1.0.1:"]))
        self.assertHeld(hunk("Dockerfile", ["FROM python:3.12"], ["FROM python:3.13"]))

    def test_version_with_no_name_in_view_holds(self):
        self.assertHeld(hunk("uv.lock", ['version = "1.0.0"'], ['version = "1.0.1"']))

    def test_project_version_bump_in_package_json_holds(self):
        self.assertHeld(hunk("package.json", ['  "version": "1.0.0",'], ['  "version": "1.0.1",']))

    # --- other ecosystems --------------------------------------------------------------------
    def test_github_action_tags(self):
        w = ".github/workflows/ci.yml"
        for old, new, want in [("v4.1.0", "v4.1.1", "patch"), ("v4.1.0", "v4.2.0", "minor"),
                               ("v3", "v4", "major")]:
            with self.subTest(old=old, new=new):
                d = hunk(w, [f"      - uses: actions/checkout@{old}"], [f"      - uses: actions/checkout@{new}"])
                self.assertEqual(self.level(d)[:2], (want, True))

    def test_github_action_sha_pin_uses_the_comment_version(self):
        sha1, sha2 = "a" * 40, "b" * 40
        d = hunk(".github/workflows/ci.yml", [f"      - uses: o/r@{sha1} # v1.2.3"], [f"      - uses: o/r@{sha2} # v1.3.0"])
        self.assertEqual(self.level(d)[:2], ("minor", True))
        d = hunk(".github/workflows/ci.yml", [f"      - uses: o/r@{sha1}"], [f"      - uses: o/r@{sha2}"])
        self.assertHeld(d)

    def test_workflow_gaining_a_step_holds(self):
        self.assertHeld(hunk(".github/workflows/ci.yml", ["      - uses: a/b@v1"], ["      - uses: a/b@v2", "      - run: curl x | sh"]))

    def test_requirements_txt_and_package_lock_and_go_mod(self):
        self.assertEqual(self.level(hunk("requirements.txt", ["requests==2.31.0"], ["requests==2.32.0"]))[:2], ("minor", True))
        d = hunk("package-lock.json", ['      "version": "1.2.3",', '      "resolved": "https://r/left-pad/-/left-pad-1.2.3.tgz",'],
                 ['      "version": "1.2.4",', '      "resolved": "https://r/left-pad/-/left-pad-1.2.4.tgz",'],
                 context=['    "node_modules/left-pad": {'])
        self.assertEqual(self.level(d)[:2], ("patch", True))
        d = hunk("go.mod", ["\tgithub.com/a/b v1.2.3"], ["\tgithub.com/a/b v1.4.0"]) + hunk("go.sum", ["h1:a"], ["h1:b"])
        self.assertEqual(self.level(d)[:2], ("minor", True))
        self.assertHeld(hunk("go.sum", ["h1:a"], ["h1:b"]))

    def test_markers_extras_and_comments_in_requirement_lines(self):
        d = hunk("requirements.txt", ["resend[async]>=2.43.0  # mail"],
                 ['resend[async]>=2.46.0 ; python_version >= "3.9"'])
        self.assertEqual(self.level(d)[:2], ("minor", True))
        d = hunk("pyproject.toml", ['    "uvicorn[standard]>=0.52.4; sys_platform != \'win32\'",'],
                 ['    "uvicorn[standard]>=0.52.5; sys_platform != \'win32\'",'])
        self.assertEqual(self.level(d)[:2], ("minor", True))

    def test_requirements_option_lines_hold(self):
        self.assertHeld(hunk("requirements.txt", ["--index-url https://a/"], ["--index-url https://b/"]))

    # --- review round 1: everything below must be levelled exactly or held ------------------
    def test_sha_pin_whose_sha_moves_under_an_unchanged_comment_holds(self):
        sha1, sha2 = "a" * 40, "b" * 40
        w = hunk(".github/workflows/ci.yml", [f"      - uses: o/r@{sha1} # v1.2.3"],
                 [f"      - uses: o/r@{sha2} # v1.2.3"])
        self.assertHeld(uvlock("resend", "2.43.0", "2.43.1") + w, allow="patch")
        # moving to a SHA with no comment, or off a SHA to a tag, still needs a readable version
        w = hunk(".github/workflows/ci.yml", [f"      - uses: o/r@{sha1}"], [f"      - uses: o/r@{sha1[:39]}c"])
        self.assertHeld(w)

    def test_sha_pin_with_a_moved_comment_is_levelled(self):
        sha1, sha2 = "a" * 40, "b" * 40
        w = hunk(".github/workflows/ci.yml", [f"      - uses: o/r@{sha1} # v1.2.3"],
                 [f"      - uses: o/r@{sha2} # v1.2.4"])
        self.assertEqual(self.level(w)[:2], ("patch", True))

    def test_workflow_steps_that_swap_places_hold(self):
        w = hunk(".github/workflows/ci.yml",
                 ["      - uses: a/one@v1.0.0", "      - uses: b/two@v2.0.0"],
                 ["      - uses: b/two@v2.0.0", "      - uses: a/one@v1.0.1"])
        self.assertHeld(w, allow="patch")

    def test_workflow_line_whose_surroundings_change_holds(self):
        w = hunk(".github/workflows/ci.yml", ["      - uses: a/one@v1.0.0"], ["        uses: a/one@v1.0.1"])
        self.assertHeld(w)

    def test_npm_lock_resolved_on_a_new_host_holds(self):
        d = hunk("package-lock.json",
                 ['      "version": "1.2.0",',
                  '      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.2.0.tgz",',
                  '      "integrity": "sha512-old",'],
                 ['      "version": "1.2.1",',
                  '      "resolved": "https://evil.example/left-pad/-/left-pad-1.2.1.tgz",',
                  '      "integrity": "sha512-new",'],
                 context=['    "node_modules/left-pad": {'])
        self.assertHeld(d, allow="patch")

    def test_npm_lock_same_host_bump_is_patch(self):
        d = hunk("package-lock.json",
                 ['      "version": "1.2.0",',
                  '      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.2.0.tgz",',
                  '      "integrity": "sha512-old",'],
                 ['      "version": "1.2.1",',
                  '      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.2.1.tgz",',
                  '      "integrity": "sha512-new",'],
                 context=['    "node_modules/left-pad": {'])
        r = run(d, allow="patch")
        self.assertEqual((r["level"], r["confident"], r["eligible"]), ("patch", True, True), r)

    def test_npm_lock_artifact_change_without_a_version_change_holds(self):
        bump = hunk("package-lock.json", ['      "version": "1.0.0",'], ['      "version": "1.0.1",'],
                    context=['    "node_modules/other": {'])
        swap = hunk("package-lock.json",
                    ['      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.2.0.tgz",',
                     '      "integrity": "sha512-old",'],
                    ['      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.2.0.tgz",',
                     '      "integrity": "sha512-evil",'],
                    context=['    "node_modules/left-pad": {', '      "version": "1.2.0",'])
        self.assertHeld(one_file(bump, swap), allow="patch")

    def test_npm_lock_install_script_turning_on_holds(self):
        d = hunk("package-lock.json", ['      "version": "1.2.0",'],
                 ['      "version": "1.2.1",', '      "hasInstallScript": true,'],
                 context=['    "node_modules/left-pad": {'])
        self.assertHeld(d, allow="patch")

    def test_npm_lock_renamed_or_aliased_package_holds(self):
        d = one_file(hunk("package-lock.json", ['    "node_modules/left": {'], ['    "node_modules/evil": {']),
                     hunk("package-lock.json", ['      "version": "1.0.0",'], ['      "version": "1.0.1",'],
                          context=['    "node_modules/other": {']))
        self.assertHeld(d, allow="patch")
        d = hunk("package-lock.json", ['      "version": "1.0.0",'],
                 ['      "name": "evil",', '      "version": "1.0.1",'], context=['    "node_modules/left": {'])
        self.assertHeld(d, allow="patch")

    def uv_entry(self, name, old, new, old_url=None, new_url=None, extra_removed=(), extra_added=()):
        old_url = old_url or f"https://files.pythonhosted.org/packages/aa/{name}-{old}.tar.gz"
        new_url = new_url or f"https://files.pythonhosted.org/packages/bb/{name}-{new}.tar.gz"
        return hunk("uv.lock",
                    [f'version = "{old}"', *extra_removed,
                     f'sdist = {{ url = "{old_url}", hash = "sha256:aaa", size = 1, upload-time = "t" }}'],
                    [f'version = "{new}"', *extra_added,
                     f'sdist = {{ url = "{new_url}", hash = "sha256:bbb", size = 2, upload-time = "u" }}'],
                    context=["[[package]]", f'name = "{name}"'])

    def test_uv_lock_same_host_artifacts_are_patch(self):
        r = run(self.uv_entry("resend", "2.43.0", "2.43.1"), allow="patch")
        self.assertEqual((r["level"], r["confident"], r["eligible"]), ("patch", True, True), r)

    def test_uv_lock_artifact_on_a_new_host_holds(self):
        d = self.uv_entry("resend", "2.43.0", "2.43.1", new_url="https://evil.example/resend-2.43.1.tar.gz")
        self.assertHeld(d, allow="patch")

    def test_uv_lock_artifact_not_naming_the_new_version_holds(self):
        d = self.uv_entry("resend", "2.43.0", "2.43.1",
                          new_url="https://files.pythonhosted.org/packages/bb/resend-9.9.9.tar.gz")
        self.assertHeld(d, allow="patch")

    def test_uv_lock_source_change_holds(self):
        d = self.uv_entry("resend", "2.43.0", "2.43.1",
                          extra_removed=['source = { registry = "https://pypi.org/simple" }'],
                          extra_added=['source = { registry = "https://evil.example/simple" }'])
        self.assertHeld(d, allow="patch")

    def test_uv_lock_artifact_change_without_a_version_change_holds(self):
        swap = hunk("uv.lock",
                    ['sdist = { url = "https://files.pythonhosted.org/p/left-1.0.0.tar.gz", hash = "sha256:a" }'],
                    ['sdist = { url = "https://files.pythonhosted.org/p/left-1.0.0.tar.gz", hash = "sha256:evil" }'],
                    context=["[[package]]", 'name = "left"', 'version = "1.0.0"'])
        self.assertHeld(one_file(uvlock("resend", "2.43.0", "2.43.1"), swap), allow="patch")

    def test_uv_lock_artifacts_in_a_later_hunk_are_attributed_by_file_name(self):
        """A long dependencies list splits sdist/wheels into a hunk with no name in view."""
        ver = hunk("uv.lock", ['version = "3.14.4"'], ['version = "3.14.5"'], context=["[[package]]", 'name = "aiohttp"'])
        def art(url_new):
            return hunk("uv.lock",
                        ['sdist = { url = "https://files.pythonhosted.org/p/aiohttp-3.14.4.tar.gz", hash = "sha256:a" }'],
                        [f'sdist = {{ url = "{url_new}", hash = "sha256:b" }}'],
                        context=['    { name = "yarl" },', "]"])
        good = one_file(ver, art("https://files.pythonhosted.org/p/aiohttp-3.14.5.tar.gz"))
        self.assertEqual(self.level(good)[:2], ("patch", True))
        self.assertHeld(one_file(ver, art("https://evil.example/p/aiohttp-3.14.5.tar.gz")), allow="patch")
        self.assertHeld(one_file(ver, art("https://files.pythonhosted.org/p/aiohttp-3.14.9.tar.gz")), allow="patch")
        bare = hunk("uv.lock", ['checksum = "a"'], ['checksum = "b"'], context=['    { name = "yarl" },'])
        self.assertHeld(one_file(ver, bare), allow="patch")

    def test_toml_lock_rename_at_the_same_version_holds(self):
        rename = hunk("uv.lock", ['name = "left"'], ['name = "evil"'], context=["[[package]]"])
        self.assertHeld(one_file(uvlock("resend", "2.43.0", "2.43.1"), rename), allow="patch")

    def test_cargo_checksum_follows_its_version(self):
        bump = hunk("Cargo.lock", ['version = "1.0.1"', 'checksum = "aaa"'], ['version = "1.0.2"', 'checksum = "bbb"'],
                    context=["[[package]]", 'name = "serde"'])
        self.assertEqual(self.level(bump)[:2], ("patch", True))
        swap = hunk("Cargo.lock", ['checksum = "ccc"'], ['checksum = "evil"'],
                    context=["[[package]]", 'name = "libc"', 'version = "0.2.1"'])
        self.assertHeld(one_file(bump, swap), allow="patch")

    def test_poetry_files_follow_their_version(self):
        d = hunk("poetry.lock",
                 ['version = "1.0.0"', '    {file = "left-1.0.0.tar.gz", hash = "sha256:a"},'],
                 ['version = "1.0.1"', '    {file = "left-1.0.1.tar.gz", hash = "sha256:b"},'],
                 context=["[[package]]", 'name = "left"'])
        self.assertEqual(self.level(d)[:2], ("patch", True))

    def test_inclusive_upper_bound_change_holds(self):
        self.assertHeld(pyproject(">=1.2.3,<2.0.0", ">=1.2.4,<=2.0.0", name="pkg"), allow="patch")
        self.assertHeld(pyproject(">1.2.3", ">=1.2.3", name="pkg"), allow="patch")

    def test_repeated_bounds_hold(self):
        self.assertHeld(pyproject(">=1.0.0,<2.0.0,<3.0.0", ">=1.0.1,<3.0.0,<3.0.1", name="pkg"), allow="patch")
        self.assertHeld(pyproject(">=2.0,>=1.0", ">=2.5,>=1.0", name="pkg"))

    def test_npm_partial_exact_version_holds(self):
        d = hunk("package.json", ['    "left-pad": "1.0.0",'], ['    "left-pad": "1",'])
        self.assertHeld(d + uvlock("x", "1.0.0", "1.0.1"), allow="patch")
        d = hunk("package.json", ['    "left-pad": "1.0.0",'], ['    "left-pad": "1.0.1",'])
        self.assertEqual(self.level(d)[:2], ("patch", True))

    def test_short_tag_titles_still_level(self):
        d = hunk(".github/workflows/ci.yml", ["      - uses: a/b@v4.1"], ["      - uses: a/b@v4.2"])
        self.assertEqual(self.level(d, title="Bump a/b from 4.1 to 4.2")[:2], ("minor", True))

    # --- the skill's own shell block ---------------------------------------------------------
    def test_skill_block_runs_as_written(self):
        """The documented block must run under `set -u` with no TMP in the environment, and give
        a patch-only lock diff `eligible: true` (a block writing to an unset $TMP holds every PR)."""
        import re, tempfile
        skill = open(os.path.join(ROOT, "plugins/deps-flow/skills/dependabot/SKILL.md")).read()
        blocks = [b for b in re.findall(r"```bash\n(.*?)```", skill, re.S) if "classify-bump.py" in b]
        self.assertEqual(len(blocks), 1)
        block = (blocks[0].replace("<N>", "7").replace("<PR title>", "Bump resend from 2.43.0 to 2.43.1")
                 .replace("<config.depsFlow.autoMergeSemver, comma-joined>", "patch"))
        self.assertIn("mktemp -d", block)
        with tempfile.TemporaryDirectory() as d:
            diff = os.path.join(d, "diff")
            with open(diff, "w") as f:
                f.write(uvlock("resend", "2.43.0", "2.43.1"))
            gh = os.path.join(d, "gh")
            with open(gh, "w") as f:
                f.write(f'#!/bin/sh\ncase "$2" in diff) cat "{diff}";; view) echo "body";; esac\n')
            os.chmod(gh, 0o755)
            env = {k: v for k, v in os.environ.items() if k not in ("TMP", "tmp")}
            env.update(PATH=d + os.pathsep + env.get("PATH", ""), REPO="o/r",
                       CLAUDE_PLUGIN_ROOT=os.path.join(ROOT, "plugins/deps-flow"))
            p = subprocess.run(["bash", "-euo", "pipefail", "-c", block], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = json.loads(p.stdout)
        self.assertTrue(out["eligible"], out)

    # --- interface ---------------------------------------------------------------------------
    def test_eligible_follows_allow(self):
        d = uvlock("x", "1.0.0", "1.1.0")
        self.assertTrue(run(d, allow="patch,minor")["eligible"])
        self.assertFalse(run(d, allow="patch")["eligible"])
        self.assertNotIn("eligible", run(d))

    def test_bad_allow_is_a_usage_error(self):
        p = subprocess.run([sys.executable, SCRIPT, "--allow", "huge"], input="", capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
