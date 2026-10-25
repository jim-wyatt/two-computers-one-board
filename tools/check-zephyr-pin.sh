#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr version is written down twice, uv's twice, and the SDK's in every
# script that defaults to it. Fail if any of them disagrees.
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

# --- uv ----------------------------------------------------------------------
#
# Not Zephyr, and the same shape of problem: the board installs uv with
# provision/user/20-host-tools.sh, CI with setup-uv, and uv is what resolves
# every lock file here. Two uv releases resolve differently, so the two must be
# the same release. Each workflow that uses setup-uv says which in its env.
HOST_TOOLS="$PROJECT/provision/user/20-host-tools.sh"
# UV_VERSION="${UV_VERSION:-0.13.5}"
uv_board="$(sed -n 's/^UV_VERSION=.*:-\([0-9][0-9.]*\)}.*/\1/p' "$HOST_TOOLS" | head -1)"
if [ -z "$uv_board" ]; then
  echo "could not read UV_VERSION from $HOST_TOOLS" >&2
  exit 1
fi
fail=0
for wf in "$PROJECT"/.github/workflows/*.yml; do
  grep -q 'astral-sh/setup-uv@' "$wf" || continue
  #   UV_VERSION: "0.13.5"
  uv_ci="$(sed -n 's/^[[:space:]]*UV_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$wf" | head -1)"
  # Every setup-uv step must be told; one without `version:` takes the latest.
  uses="$(grep -c 'astral-sh/setup-uv@' "$wf")"
  told="$(grep -cE '^[[:space:]]*version:[[:space:]]*\$\{\{[[:space:]]*env\.UV_VERSION[[:space:]]*\}\}' "$wf")"
  if [ "$uv_ci" != "$uv_board" ]; then
    echo "${wf#"$PROJECT"/} sets UV_VERSION ${uv_ci:-(not at all)}; the board installs $uv_board ($HOST_TOOLS)" >&2
    fail=1
  fi
  if [ "$told" -lt "$uses" ]; then
    echo "${wf#"$PROJECT"/}: $uses setup-uv step(s), $told given version: \${{ env.UV_VERSION }} - the rest install the latest uv" >&2
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1

echo "uv pinned at $uv_board on the board and in every workflow that installs it"

# --- the SDK -----------------------------------------------------------------
#
# provision/user/25-zephyr-sdk.sh pins the SDK release. Everything else that
# needs the SDK derives its path from ZEPHYR_SDK_VERSION, but the default still
# has to be written in each reader (env.sh, bootstrap.sh, the mcu/*.sh scripts)
# and the VS Code files cannot read a variable at all - nine places, and moving
# the pin in one left the others pointing at a directory that no longer
# existed. So every one is held to the pin here. tests/ is left out: it names
# other releases on purpose.
SDK_STEP="$PROJECT/provision/user/25-zephyr-sdk.sh"
# SDK_VERSION="${ZEPHYR_SDK_VERSION:-1.0.1}"
sdk_pin="$(sed -n 's/^SDK_VERSION=.*:-\([0-9][0-9.]*\)}.*/\1/p' "$SDK_STEP" | head -1)"
if [ -z "$sdk_pin" ]; then
  echo "could not read the SDK version from $SDK_STEP" >&2
  exit 1
fi
stray="$(cd "$PROJECT" && git grep -nE 'zephyr-sdk-[0-9][0-9.]*[0-9]|ZEPHYR_SDK_VERSION:-[0-9][0-9.]*' -- ':!tests/' 2>/dev/null |
  grep -vE "zephyr-sdk-${sdk_pin//./\\.}([^0-9.]|\$|\.[^0-9])|ZEPHYR_SDK_VERSION:-${sdk_pin//./\\.}([^0-9.]|\$)" || true)"
if [ -n "$stray" ]; then
  cat >&2 <<MSG
The Zephyr SDK is pinned at $sdk_pin (provision/user/25-zephyr-sdk.sh), and
these name another version:

$stray

Change them all together: docs/reference/mcu.md, "Upgrading Zephyr".
MSG
  exit 1
fi

echo "Zephyr SDK $sdk_pin named consistently wherever its version is written"
