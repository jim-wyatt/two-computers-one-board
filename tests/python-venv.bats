#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/user/35-python-venv.sh builds the venv every Python thing on the
# board runs from: the demo, the MCU link check, the site build and the gates.
# Its skips are what matter. A skip that looks at too little leaves a broken
# venv reading `ok` forever, which is what a venv missing smbus2 and spidev
# did, and a run that dies half way must not leave a record saying it was
# built to the lock.
#
# uv is a stub here, and so is the venv's python: it imports what has been
# "installed" and nothing else. The user-steps job in provision.yml runs the
# step for real; this is for the decisions it makes along the way.

setup() {
  load helpers/stub
  stub_setup

  # A copy of the checkout: the lock is a test's to change, and the dev-tools
  # installer is replaced with one that does only what the step checks for.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT/python" "$PROJECT/tools"
  cp -r "$REAL/provision" "$PROJECT/"
  cp "$REAL/python/requirements-lock.txt" "$PROJECT/python/"
  STEP="$PROJECT/provision/user/35-python-venv.sh"
  LOCK="$PROJECT/python/requirements-lock.txt"

  export UNOQ_VENV="$BATS_TEST_TMPDIR/venv"
  VENV="$UNOQ_VENV"
  # The step puts ~/.local/bin first, which on a board is where the real uv is.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export UNOQ_IN_BOOTSTRAP=1

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  cat >"$PROJECT/tools/install-dev-tools.sh" <<'SH'
#!/bin/bash
[ -e "$FLAGS/dev-tools-fail" ] && exit 1
for t in pytest mypy ruff codespell; do
  printf '#!/bin/bash\n' >"$UNOQ_VENV/bin/$t"
  chmod +x "$UNOQ_VENV/bin/$t"
done
SH
  chmod +x "$PROJECT/tools/install-dev-tools.sh"

  # uv venv <dir>: a venv whose python imports module X while $FLAGS/mod-X
  # exists. uv pip install: each hardware package becomes importable, unless
  # a test says it fails to build or installs without becoming importable;
  # -e makes unoq importable and puts its entry points in bin/.
  stub_body uv <<'SH'
case "$1" in
  venv)
    mkdir -p "$2/bin"
    cat >"$2/bin/python" <<'PY'
#!/bin/bash
[ "$1" = --version ] && { echo "Python 3.13.5"; exit 0; }
case "$2" in
  "import unoq; print"*)
    [ -e "$FLAGS/mod-unoq" ] || { echo "ModuleNotFoundError: No module named 'unoq'"; exit 1; }
    echo 1.1.0
    ;;
  "import "*) [ -e "$FLAGS/mod-${2#import }" ] ;;
esac
PY
    chmod +x "$2/bin/python"
    ;;
  pip)
    shift 2
    venv="" editable=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --python) venv="$(dirname "$(dirname "$2")")"; shift ;;
        -c | -b) shift ;;
        -e) editable=1 ;;
        -q) ;;
        gpiod | smbus2 | pyserial | spidev | smpclient)
          [ -e "$FLAGS/build-fails-$1" ] && exit 1
          mod="$1"
          [ "$mod" = pyserial ] && mod=serial
          [ -e "$FLAGS/silent-miss-$1" ] || : >"$FLAGS/mod-$mod"
          ;;
      esac
      shift
    done
    if [ -n "$editable" ]; then
      [ -e "$FLAGS/unoq-broken" ] || : >"$FLAGS/mod-unoq"
      for e in unoq-cpu-bars zensical; do
        printf '#!/bin/bash\n' >"$venv/bin/$e"
        chmod +x "$venv/bin/$e"
      done
    fi
    ;;
esac
exit 0
SH
}

HW="gpiod smbus2 pyserial spidev smpclient"

# --- what it refuses --------------------------------------------------------

@test "under sudo it refuses, and creates nothing" {
  # It installs into the checkout. Root-owned files there are the usual way a
  # bootstrap half-works.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WITHOUT sudo"* ]]
  [ ! -e "$VENV" ]
  never_ran uv
}

@test "no uv: it stops, and names the step that installs it" {
  rm "$STUB_DIR/uv"
  if PATH="$STUB_DIR:/usr/bin:/bin" command -v uv >/dev/null; then
    skip "a uv is installed system-wide on this machine"
  fi
  PATH="$STUB_DIR:/usr/bin:/bin" run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uv missing - run provision/user/20-host-tools.sh first"* ]]
  [ ! -e "$VENV" ]
}

# --- the first run ----------------------------------------------------------

@test "a fresh checkout gets the venv, the libraries, unoq and the tools, to the lock" {
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "uv venv $VENV"
  ran "uv pip install --python $VENV/bin/python -q -c $LOCK -b $LOCK $HW"
  ran "uv pip install --python $VENV/bin/python -q -c $LOCK -b $LOCK -e $PROJECT/python[docs]"
  [ -x "$VENV/bin/codespell" ]
  [[ "$output" == *"unoq 1.1.0"* ]]
  # And the record that says so.
  [ "$(cat "$VENV/.unoq-lock")" = "$(sha256sum "$LOCK" | cut -d' ' -f1)" ]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  never_ran uv
}

@test "one library missing is not 'already correct', and is named" {
  # The step used to check three of the five it installed. A venv missing the
  # other two passed the check, so the install that would fix it never ran.
  run "$STEP"
  rm "$FLAGS/mod-smbus2"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "uv pip install --python $VENV/bin/python -q -c $LOCK -b $LOCK $HW"
  [[ "$output" == *"hardware libraries installed (smbus2)"* ]]
}

@test "pyserial is checked under the name it imports as" {
  run "$STEP"
  rm "$FLAGS/mod-serial"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hardware libraries installed (pyserial)"* ]]
}

@test "a tool the gates need missing runs the dev tooling again" {
  # codespell joined after boards had been set up, and a check of three names
  # left those boards failing the spelling gate.
  run "$STEP"
  rm "$VENV/bin/codespell"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -x "$VENV/bin/codespell" ]
  [[ "$output" == *"dev tooling installed"* ]]
}

@test "a lock that moved reinstalls everything, and records the new one" {
  # Every check above passes on a venv built to the old pins. Without this,
  # provisioning again after a pin moved reads `ok` and keeps the old versions.
  run "$STEP"
  echo "# moved" >>"$LOCK"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "uv pip install --python $VENV/bin/python -q -c $LOCK -b $LOCK $HW"
  ran_like "^uv pip install .* -e $PROJECT/python\[docs\]$"
  [[ "$output" == *"hardware libraries brought to the locked versions"* ]]
  [[ "$output" == *"dev tooling installed"* ]]
  [ "$(cat "$VENV/.unoq-lock")" = "$(sha256sum "$LOCK" | cut -d' ' -f1)" ]
}

# --- a run that does not finish ---------------------------------------------

@test "spidev failing to build says what the board is missing, and records nothing" {
  : >"$FLAGS/build-fails-spidev"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not install the hardware libraries"* ]]
  [[ "$output" == *"gcc or python3-dev"* ]]
  [ ! -e "$VENV/.unoq-lock" ]
}

@test "an install that leaves a library unimportable is a failure, not a pass" {
  : >"$FLAGS/silent-miss-spidev"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still missing after install: spidev"* ]]
  [ ! -e "$VENV/.unoq-lock" ]
}

@test "dev tooling failing records nothing, so the next run does it all again" {
  : >"$FLAGS/dev-tools-fail"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"install-dev-tools.sh failed"* ]]
  [ ! -e "$VENV/.unoq-lock" ]
  rm "$FLAGS/dev-tools-fail"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "uv pip install --python $VENV/bin/python -q -c $LOCK -b $LOCK $HW"
  [ -e "$VENV/.unoq-lock" ]
}

@test "unoq that will not import after installing is a failure that shows why" {
  # Its entry points are there and uv said yes. Only the check at the end can
  # tell, and it must not let the summary say the venv is ready.
  : >"$FLAGS/unoq-broken"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq will not import: ModuleNotFoundError"* ]]
}

@test "unoq gone from a finished venv is installed again, not reported present" {
  run "$STEP"
  rm "$FLAGS/mod-unoq"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like "^uv pip install .* -e $PROJECT/python\[docs\]$"
  [[ "$output" == *"unoq installed editable"* ]]
}
