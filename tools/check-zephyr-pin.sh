#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr version is written down twice. Fail if the two disagree.
#
#   tools/check-zephyr-pin.sh
#
# WHY IT IS WRITTEN TWICE
# -----------------------
# The board builds a standalone workspace at ~/zephyrproject, outside the
# checkout, because the Zephyr workspace is 2 GB and should survive deleting the
# repository. CI cannot do that - the setup action needs the application repo to
# BE the manifest repo (`west init -l`), so it needs a west.yml here.
#
# Two topologies, two declarations of the same version, and no mechanism in west
# to share one. So: a gate instead of a convention. A CI job that compiles a
# different Zephyr from the board is worse than no CI job at all, because it
# reports green about something nobody is running.
#
# No network, instant, so it runs on every check.sh.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PROV="$PROJECT/provision/user/30-zephyr-workspace.sh"
MANIFEST="$PROJECT/west.yml"

# ZEPHYR_VERSION="${ZEPHYR_VERSION:-v4.4.2}"
prov="$(sed -n 's/^ZEPHYR_VERSION=.*:-\(v[0-9][0-9.]*\)}.*/\1/p' "$PROV" | head -1)"
#     revision: v4.4.2
manifest="$(sed -n 's/^[[:space:]]*revision:[[:space:]]*\(v[0-9][0-9.]*\).*/\1/p' "$MANIFEST" | head -1)"

fail=0
if [ -z "$prov" ]; then
  echo "could not read ZEPHYR_VERSION from $PROV" >&2
  fail=1
fi
if [ -z "$manifest" ]; then
  echo "could not read the zephyr revision from $MANIFEST" >&2
  fail=1
fi
[ "$fail" = 0 ] || exit 1

if [ "$prov" != "$manifest" ]; then
  cat >&2 <<EOF
Zephyr version pinned in two places, and they disagree:

  provision/user/30-zephyr-workspace.sh   $prov   (what the board builds)
  west.yml                                $manifest   (what CI builds)

Change both. If you are upgrading Zephyr, docs/reference/mcu.md has the
procedure - the SDK version usually moves with it.
EOF
  exit 1
fi

echo "Zephyr pinned at $prov in both the provisioning script and the manifest"

# --- the module filter -----------------------------------------------------
#
# The version has to be written twice; the FILTER does not, so it is shared
# outright and this only has to prove nobody has quietly gone back to a copy.
# A hardcoded filter in either consumer would still work and would still build
# - it would just be free to drift, which is the failure this whole file exists
# to prevent.
FILTER_FILE="$PROJECT/west-project-filter"
WORKFLOW="$PROJECT/.github/workflows/ci.yml"

if [ ! -r "$FILTER_FILE" ]; then
  echo "missing $FILTER_FILE - both the board and CI read the filter from it" >&2
  exit 1
fi

filter="$(grep -vE '^[[:space:]]*(#|$)' "$FILTER_FILE" | head -1)"
if [ -z "$filter" ]; then
  echo "$FILTER_FILE has no filter line (first non-comment, non-blank line)" >&2
  exit 1
fi

fail=0
# The INPUT line specifically, not the string anywhere in the file. A bare
# `grep -q west-project-filter` also matched the step that reads the file, so
# deleting the `with:` input entirely would still have reported green - the
# check would have been measuring its own scaffolding.
if ! grep -qE '^[[:space:]]*west-project-filter:[[:space:]]*\S' "$WORKFLOW"; then
  echo "$WORKFLOW no longer passes west-project-filter: to the setup action" >&2
  fail=1
fi
for f in "$PROV" "$WORKFLOW"; do
  if grep -qE "^[^#]*['\"= ]-hal_\.\*," "$f"; then
    cat >&2 <<EOF
$f hardcodes a module filter instead of reading west-project-filter.

That is the copy this file exists to prevent: it builds fine and is free to
drift from the other consumer. Read the shared file instead.
EOF
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1

echo "module filter shared from west-project-filter by the board and CI"
