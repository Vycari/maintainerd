#!/usr/bin/env bash
#
# repo-ops — source-compatible shim.
#
# gh_exec_words now lives in gh-command-scan.sh, next to gh_command_words and gh_pr_subcommand,
# which are derived from it so the guards cannot disagree about what a `gh` invocation is
# (maintainerd#85, #90). This file only keeps `. lib/gh-exec-words.sh` working for a caller (or a
# vendored copy) that still sources it by that name.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gh-command-scan.sh
. "$SCRIPT_LIB_DIR/gh-command-scan.sh"
