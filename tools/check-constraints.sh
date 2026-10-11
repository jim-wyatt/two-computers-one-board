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

# 1. Every name in a dependency list of pyproject.toml: [project].dependencies,
# every group under [project.optional-dependencies], and [build-system].requires.
#
# Read as TOML, by a TOML parser. The first version of this picked the lists
# out with awk, one line at a time, and a dependency on the second line of an
# array - which is how most people write a long one - was never seen. The gate
# passed, and would have gone on passing over exactly the mistake it exists
# to catch.
names="$(
  python3 - "$PYPROJECT" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    project = tomllib.load(f).get("project", {})
with open(sys.argv[1], "rb") as f:
    build = tomllib.load(f).get("build-system", {})
# What BUILDS the package counts too: an editable install fetches these into
# an environment of its own, and an unpinned one there is still unpinned.
reqs = list(project.get("dependencies", [])) + list(build.get("requires", []))
for group in project.get("optional-dependencies", {}).values():
    reqs.extend(group)
for req in reqs:
    # The name is everything before a version, an extra, a marker or a space.
    print(re.split(r"[\s<>=!~;\[(]", req.strip(), maxsplit=1)[0])
PY
)" || bad "could not read $PYPROJECT as TOML"
names="$(sort -u <<<"$names")"
[ -n "$names" ] || bad "found no dependencies in $PYPROJECT - has its layout changed?"
for n in $names; do
  pinned "$PY_LOCK" "$n" ||
    bad "$n is in python/pyproject.toml and not in python/requirements-lock.txt"
done

# 2. The Zephyr lock: for the pinned version, and holding what is installed by name.
# shellcheck disable=SC2016  # a literal ${...} in the file being read, not ours
want_z="$(sed -n 's/^ZEPHYR_VERSION="\${ZEPHYR_VERSION:-\(v[0-9.]*\)}"$/\1/p' "$WORKSPACE_STEP")"
[ -n "$want_z" ] || bad "could not read the pinned Zephyr version from $WORKSPACE_STEP"
grep -q "(Zephyr $want_z)" "$Z_LOCK" ||
  bad "mcu/requirements-zephyr-lock.txt was not compiled for Zephyr $want_z"
# Every package asked for by name, from the list update-constraints.sh wrote
# when it compiled the lock. Seven of them used to be spelled out here, and the
# other forty could have lost their pin without this noticing.
Z_IN="${UNOQ_ZEPHYR_IN:-$PROJECT/mcu/requirements-zephyr.in}"
[ -s "$Z_IN" ] || bad "missing $Z_IN - run tools/update-constraints.sh"
asked=0
while IFS= read -r n; do
  case "$n" in '' | '#'*) continue ;; esac
  asked=$((asked + 1))
  pinned "$Z_LOCK" "$n" ||
    bad "$n is asked for by a provisioning step and not in mcu/requirements-zephyr-lock.txt"
done <"$Z_IN"
[ "$asked" -gt 5 ] || bad "$Z_IN names only $asked packages - has it been truncated?"

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
