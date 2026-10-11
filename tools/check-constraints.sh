#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The lock files still cover what is installed.
#
#   tools/check-constraints.sh
#
# The two lock files (tools/update-constraints.sh) pin every Python package
# this project installs. They are constraints: a package that is asked for and
# is NOT in the file is installed anyway, at whatever version is newest. So
# the way a lock file goes stale is silent - somebody adds a dependency, the
# install works, and that one package is unpinned from then on.
#
# This does not ask whether the pinned versions are the latest. That answer
# changes every day without the repository changing, and a gate that does that
# teaches people to ignore it. It asks three things that only change when
# somebody edits a file here:
#
#   1. every package pyproject.toml names is pinned in python/requirements-lock.txt
#   2. the Zephyr lock was compiled for the Zephyr version that is pinned, and
#      holds the tools the steps install by name
#   3. every line of both is an exact pin
set -uo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PY_LOCK="${UNOQ_PY_LOCK:-$PROJECT/python/requirements-lock.txt}"
Z_LOCK="${UNOQ_ZEPHYR_LOCK:-$PROJECT/mcu/requirements-zephyr-lock.txt}"
PYPROJECT="${UNOQ_PYPROJECT:-$PROJECT/python/pyproject.toml}"
WORKSPACE_STEP="${UNOQ_WORKSPACE_STEP:-$PROJECT/provision/user/30-zephyr-workspace.sh}"
rc=0
bad() {
  echo "  $*" >&2
  rc=1
}

# pinned <lock> <package> - is it there, under PyPI's idea of the same name
# (case-insensitive, with - _ and . all meaning the same thing)?
norm() { tr 'A-Z_.' 'a-z--' <<<"$1"; }
pinned() {
  local want
  want="$(norm "$2")"
  sed -n 's/^\([A-Za-z0-9._-]*\)==.*/\1/p' "$1" | tr 'A-Z_.' 'a-z--' | grep -qx "$want"
}

for f in "$PY_LOCK" "$Z_LOCK"; do
  [ -s "$f" ] || {
    echo "missing or empty: $f - run tools/update-constraints.sh" >&2
    exit 1
  }
done

# 1. Every name in a dependency list of pyproject.toml. The lists are the
# quoted strings on the `dependencies = [...]` line and under
# [project.optional-dependencies]; a name ends at the first character that
# cannot be part of one.
names="$(awk '
  /^dependencies *=/ { print; next }
  /^\[project.optional-dependencies\]/ { on = 1; next }
  /^\[/ { on = 0 }
  on && /^[a-z]+ *=/ { print }
' "$PYPROJECT" | grep -oE '"[A-Za-z0-9._-]+' | tr -d '"' | sort -u)"
[ -n "$names" ] || bad "found no dependencies in $PYPROJECT - has its layout changed?"
for n in $names; do
  pinned "$PY_LOCK" "$n" ||
    bad "$n is in python/pyproject.toml and not in python/requirements-lock.txt"
done

# 2. The Zephyr lock: for the pinned version, and holding what is installed by name.
want_z="$(sed -n 's/^ZEPHYR_VERSION="\${ZEPHYR_VERSION:-\(v[0-9.]*\)}"$/\1/p' "$WORKSPACE_STEP")"
[ -n "$want_z" ] || bad "could not read the pinned Zephyr version from $WORKSPACE_STEP"
grep -q "(Zephyr $want_z)" "$Z_LOCK" ||
  bad "mcu/requirements-zephyr-lock.txt was not compiled for Zephyr $want_z"
for n in west imgtool natsort cmake ninja pyelftools pytest; do
  pinned "$Z_LOCK" "$n" || bad "$n is installed by a provisioning step and not in mcu/requirements-zephyr-lock.txt"
done

# 3. Exact pins only. A line that names a package without == would let the
# newest version in, which is the thing these files exist to stop.
for f in "$PY_LOCK" "$Z_LOCK"; do
  loose="$(grep -vE '^\s*(#|$)' "$f" | grep -vE '^[A-Za-z0-9._-]+==[^ ;]+( *;.*)?$' || true)"
  [ -z "$loose" ] || bad "not an exact pin, in ${f#"$PROJECT"/}: $(head -3 <<<"$loose" | tr '\n' ' ')"
done

if [ "$rc" = 0 ]; then
  echo "lock files: $(grep -cE '^[A-Za-z0-9]' "$PY_LOCK") + $(grep -cE '^[A-Za-z0-9]' "$Z_LOCK") packages pinned, covering every dependency named (Zephyr $want_z)"
else
  echo "fix: tools/update-constraints.sh, then commit both files" >&2
fi
exit "$rc"
