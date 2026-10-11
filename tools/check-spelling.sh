#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# American spelling, across every file this project wrote.
#
#   tools/check-spelling.sh
#
# Runs codespell (configured in .codespellrc: its ordinary typo lists, its
# British-to-American list, and tools/spelling-extra.txt) over the tracked
# files, minus other people's text.
#
# WHY THE FILE LIST IS BUILT HERE
# -------------------------------
# codespell's own `skip` setting is meant for directories it walks. Handed a
# list of files, as it is here, a bare directory name in `skip` matches none of
# them: the first version of this gate "skipped" LICENSES and was reading
# LICENSES/Apache-2.0.txt all the same. So what is not ours is taken out of
# the list before codespell sees it, where a test can check that it was.
#
# Every tracked file otherwise, because the British spellings this was written
# to remove were in comments and messages as much as in prose.
set -uo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT" || exit 1
CODESPELL="${UNOQ_CODESPELL:-$PROJECT/.venv/bin/codespell}"
[ -x "$CODESPELL" ] || CODESPELL="$(command -v codespell || true)"
[ -n "$CODESPELL" ] || {
  echo "codespell is not installed - run tools/install-dev-tools.sh" >&2
  exit 1
}

# Not this project's words: license texts, a vendored search library, a
# chip vendor's register description, and files a tool writes.
NOT_OURS='^(LICENSE$|LICENSES/|docs/assets/javascripts/lunr/|\.vscode/.*\.svd$|python/requirements-lock\.txt$|mcu/requirements-zephyr-lock\.txt$|mcu/requirements-zephyr\.in$)|\.(svg|png|ico|pem)$'

mapfile -t FILES < <(git ls-files | grep -vE "$NOT_OURS")
[ "${#FILES[@]}" -gt 0 ] || {
  echo "no files to check - is this a git checkout?" >&2
  exit 1
}
"$CODESPELL" "${FILES[@]}" || {
  echo >&2
  echo "American spelling is used throughout: see .codespellrc for why, and for" >&2
  echo "how to mark a word that only looks like a misspelling." >&2
  exit 1
}
echo "spelling: ${#FILES[@]} files, en_US"
