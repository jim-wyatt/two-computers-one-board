#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/check-constraints.sh is what notices a lock file going stale, and the
# way one goes stale is silent: the lock is a constraints file, so a
# dependency that is not in it installs anyway, unpinned. Nothing fails.
#
# So this gate has to be able to say no, and each of the three ways it does is
# tried here against a copy of the real files with one thing wrong.

setup() {
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$PROJECT/tools/check-constraints.sh"
  cp "$PROJECT/python/requirements-lock.txt" "$BATS_TEST_TMPDIR/py.lock"
  cp "$PROJECT/mcu/requirements-zephyr-lock.txt" "$BATS_TEST_TMPDIR/z.lock"
  cp "$PROJECT/python/pyproject.toml" "$BATS_TEST_TMPDIR/pyproject.toml"
  cp "$PROJECT/provision/user/30-zephyr-workspace.sh" "$BATS_TEST_TMPDIR/ws.sh"
  cp "$PROJECT/mcu/requirements-zephyr.in" "$BATS_TEST_TMPDIR/z.in"
  export UNOQ_ZEPHYR_IN="$BATS_TEST_TMPDIR/z.in"
  export UNOQ_PY_LOCK="$BATS_TEST_TMPDIR/py.lock"
  export UNOQ_ZEPHYR_LOCK="$BATS_TEST_TMPDIR/z.lock"
  export UNOQ_PYPROJECT="$BATS_TEST_TMPDIR/pyproject.toml"
  export UNOQ_WORKSPACE_STEP="$BATS_TEST_TMPDIR/ws.sh"
}

@test "the repository as it stands passes" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages pinned"* ]]
}

@test "a runtime dependency added without recompiling is caught" {
  sed -i 's/^dependencies = \["pyserial",/dependencies = ["pyserial", "a-new-library",/' "$UNOQ_PYPROJECT"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a-new-library is in python/pyproject.toml and not in"* ]]
}

@test "one added to an optional group is caught too" {
  sed -i 's/^dev = \["pytest>=8",/dev = ["pytest>=8", "another-tool>=2",/' "$UNOQ_PYPROJECT"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"another-tool"* ]]
}

@test "one added on a later line of a multi-line array is caught" {
  # The usual way to write a long list, and the way the first version of this
  # gate could not read.
  python3 - "$UNOQ_PYPROJECT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'dependencies = ["pyserial", "gpiod", "smpclient"]'
assert old in s
open(p, "w").write(s.replace(old, 'dependencies = [\n  "pyserial",\n  "gpiod",\n  "smpclient",\n  "hidden-on-line-five>=1.0",\n]'))
PY
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hidden-on-line-five is in python/pyproject.toml"* ]]
}

@test "a pyproject.toml that is not valid TOML fails the gate, not passes it" {
  echo 'dependencies = [unterminated' >>"$UNOQ_PYPROJECT"
  run "$CHECK"
  [ "$status" -ne 0 ]
}

@test "a package pinned under a different spelling of its name still counts" {
  # PyPI treats -, _ and . as the same, and ignores case. uv writes one form;
  # pyproject.toml may use another.
  sed -i 's/^dependencies = \["pyserial",/dependencies = ["PySerial",/' "$UNOQ_PYPROJECT"
  run "$CHECK"
  [ "$status" -eq 0 ]
}

@test "a lock compiled for another Zephyr version is caught" {
  sed -i 's/^ZEPHYR_VERSION="\${ZEPHYR_VERSION:-v[0-9.]*}"$/ZEPHYR_VERSION="${ZEPHYR_VERSION:-v9.9.9}"/' "$UNOQ_WORKSPACE_STEP"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not compiled for Zephyr v9.9.9"* ]]
}

@test "a tool the steps install by name, missing from the Zephyr lock, is caught" {
  sed -i '/^cmake==/d' "$UNOQ_ZEPHYR_LOCK"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cmake is asked for by a provisioning step"* ]]
}

@test "any package Zephyr's own lists ask for, missing from the lock, is caught" {
  # Not one of the handful this gate used to name: one from the middle of
  # requirements-build-test.txt.
  sed -i '/^junitparser==/d' "$UNOQ_ZEPHYR_LOCK"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"junitparser is asked for"* ]]
}

@test "the tool that builds the package has to be pinned as well" {
  sed -i '/^hatchling==/d' "$UNOQ_PY_LOCK"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hatchling is in python/pyproject.toml and not in"* ]]
}

@test "a list of what was asked for that has been emptied does not pass by saying nothing" {
  echo "# nothing" >"$UNOQ_ZEPHYR_IN"
  run "$CHECK"
  [ "$status" -ne 0 ]
}

@test "a line that is not an exact pin is caught" {
  echo "some-package>=1.0" >>"$UNOQ_PY_LOCK"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an exact pin"* ]]
}

@test "a pin with an environment marker is still an exact pin" {
  echo "windows-only==1.2.3 ; sys_platform == 'win32'" >>"$UNOQ_PY_LOCK"
  run "$CHECK"
  [ "$status" -eq 0 ]
}

@test "a missing lock file is said plainly, with the command that makes it" {
  rm "$UNOQ_PY_LOCK"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tools/update-constraints.sh"* ]]
}

@test "every install in the provisioning steps is given a lock file" {
  # The lock only does anything if it is passed. One install without -c is one
  # set of packages at whatever is newest.
  for f in provision/user/20-host-tools.sh provision/user/30-zephyr-workspace.sh \
    provision/user/35-python-venv.sh tools/install-dev-tools.sh; do
    while IFS= read -r line; do
      # join the continuation lines of this command before judging it
      [[ "$line" == *" -c "* ]] || {
        echo "no lock file on: $f: $line"
        false
      }
      # ...and as build constraints: what builds a package runs in an
      # isolated environment that -c alone does not reach.
      [[ "$line" == *" -b "* ]] || {
        echo "no build constraints on: $f: $line"
        false
      }
    done < <(awk '/^[^#]*uv (pip|tool) install/ && !/(fail|warn|echo|did|skip) "/ { cmd=$0; while (cmd ~ /\\$/) { getline nxt; cmd = cmd " " nxt }; print cmd }' "$PROJECT/$f")
  done
}
