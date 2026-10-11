#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Run every quality gate in the project. This is what CI runs.
#
#   ~/two-computers-one-board/tools/check.sh              # everything
#   ~/two-computers-one-board/tools/check.sh --fix        # reformat in place, then check
#   ~/two-computers-one-board/tools/check.sh --fast       # skip the slow ones (MCU build, diagrams)
#   ~/two-computers-one-board/tools/check.sh python       # one area: python | shell | c | docs | workflows | diagrams | mcu
#
# Every gate runs even if an earlier one fails, so one pass shows you all the
# work rather than the first thing to break. Exit status is non-zero if any
# gate failed.
#
# Missing tools are failures, not skips: a gate that silently does nothing is
# worse than no gate. Install them with tools/install-dev-tools.sh.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
export PATH="$HOME/.local/bin:$PATH"

FIX=0
FAST=0
AREAS=()
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    python | shell | c | mcu | docs | workflows | diagrams) AREAS+=("$arg") ;;
    *)
      echo "unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done
[ ${#AREAS[@]} -eq 0 ] && AREAS=(python shell c docs workflows diagrams mcu)

if [ -t 1 ]; then
  RED=$'\033[31m' GREEN=$'\033[32m' DIM=$'\033[2m' BOLD=$'\033[1m' OFF=$'\033[0m'
else
  RED="" GREEN="" DIM="" BOLD="" OFF=""
fi

FAILED=()
PASSED=()

# run <name> <command...> - report and record, never abort the script.
run() {
  local name="$1"
  shift
  printf '%s>>> %s%s\n' "$BOLD" "$name" "$OFF"
  if "$@"; then
    PASSED+=("$name")
  else
    FAILED+=("$name")
    printf '%s    FAILED: %s%s\n' "$RED" "$name" "$OFF"
  fi
  echo
}

# need <tool> <gate name> - a missing tool fails its gate rather than
# vanishing from the report. For tools expected on PATH.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  FAILED+=("$2 (missing tool: $1)")
  printf '%s    MISSING: %s - run tools/install-dev-tools.sh%s\n' "$RED" "$1" "$OFF"
  return 1
}

# have <tool> <gate name> - the same contract for tools in the project venv.
# Without this, a venv missing mypy or pytest reported "All 2 gates passed" and
# exited 0, having type-checked nothing and run no tests at all.
have() {
  [ -x "$VENV/bin/$1" ] && return 0
  FAILED+=("$2 (missing tool: $VENV/bin/$1)")
  printf '%s    MISSING: %s/bin/%s - run tools/install-dev-tools.sh%s\n' "$RED" "$VENV" "$1" "$OFF"
  return 1
}

wanted() {
  local a
  for a in "${AREAS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# --- python ----------------------------------------------------------------

if wanted python; then
  cd "$PROJECT/python" || exit 1
  if have ruff "ruff"; then
    if [ "$FIX" = 1 ]; then
      run "ruff format" "$VENV/bin/ruff" format .
      run "ruff --fix" "$VENV/bin/ruff" check --fix .
    else
      run "ruff lint" "$VENV/bin/ruff" check .
      run "ruff format" "$VENV/bin/ruff" format --check .
    fi
  fi
  have mypy "mypy (strict)" && run "mypy (strict)" "$VENV/bin/mypy"
  # Coverage threshold lives in pyproject.toml, so it fails here too.
  have pytest "pytest + coverage" && run "pytest + coverage" "$VENV/bin/pytest"
fi

# --- shell -----------------------------------------------------------------

if wanted shell; then
  cd "$PROJECT" || exit 1
  mapfile -t SCRIPTS < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.venv/*')
  if [ ${#SCRIPTS[@]} -gt 0 ]; then
    need shellcheck "shellcheck" && run "shellcheck" shellcheck -x "${SCRIPTS[@]}"
    if need shfmt "shfmt"; then
      if [ "$FIX" = 1 ]; then
        run "shfmt (write)" shfmt -i 2 -ci -w "${SCRIPTS[@]}"
      else
        run "shfmt" shfmt -i 2 -ci -d "${SCRIPTS[@]}"
      fi
    fi
  fi
  # Behavior, not style. shellcheck and shfmt are linters: they will tell you
  # a variable is unquoted and never that the bind guard counts wrong. Shell is
  # the largest thing in this project by a factor of five and every finding in
  # docs/reference/clean-board-findings.md was in it or in a unit file, so it
  # is the last place that should have been checked for syntax only.
  need bats "bats (shell behavior)" &&
    run "bats (shell behavior)" bats "$PROJECT/tests"
  # The unit files and udev rules are what start all of that shell on a board,
  # and systemd will say whether it accepts them without one.
  run "units and udev rules (systemd)" "$PROJECT/tools/check-units.sh"
fi

# --- c ---------------------------------------------------------------------

if wanted c; then
  cd "$PROJECT" || exit 1
  # Static, instant, no network - so it runs here rather than in the mcu area,
  # which --fast skips and which is exactly when a version drift would land.
  run "zephyr version pin" "$PROJECT/tools/check-zephyr-pin.sh"
  # Also static and instant: an unpinned dependency is added by editing a file
  # here, never by the passing of time.
  run "lock files cover the dependencies" "$PROJECT/tools/check-constraints.sh"
  mapfile -t CFILES < <(git ls-files 'mcu/**/*.c' 'mcu/**/*.h' 2>/dev/null)
  CF="$VENV/bin/clang-format"
  # Deliberately NO fallback to a clang-format on PATH. There used to be one,
  # and it is how the gate came to disagree with itself: the board formatted an
  # enum onto one line, CI wanted it expanded, and the "fix" was to run the
  # other version. A formatter that answers differently in two places is not a
  # gate. Same argument as the shellcheck and shfmt pins in install-dev-tools.sh.
  if [ ${#CFILES[@]} -gt 0 ] && have clang-format "clang-format"; then
    # The pin lives in pyproject.toml, so it cannot drift from what gets
    # installed. A venv built before the pin has the wrong version and would
    # otherwise fail silently in exactly the confusing way this is meant to end.
    want="$(sed -n 's/.*clang-format==\([0-9.]*\).*/\1/p' "$PROJECT/python/pyproject.toml")"
    got="$("$CF" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      FAILED+=("clang-format (version $got, pinned at $want)")
      printf '%s    VERSION: clang-format is %s, pyproject.toml pins %s%s\n' \
        "$RED" "$got" "$want" "$OFF"
      printf '    refresh the venv:  tools/install-dev-tools.sh\n'
    elif [ "$FIX" = 1 ]; then
      run "clang-format (write)" "$CF" -i "${CFILES[@]}"
    else
      run "clang-format" "$CF" --dry-run --Werror "${CFILES[@]}"
    fi
  fi
fi

# --- docs ------------------------------------------------------------------

if wanted docs; then
  cd "$PROJECT" || exit 1
  # --strict, so a link to a page that moved fails here instead of 404ing for
  # a reader. This gate is the reason the docs tree can be reorganized at all.
  # Which English, as well as whether it is spelled right: .codespellrc says
  # why American, and what is deliberately not a misspelling. Over every
  # tracked file, because the British spellings were in comments and messages
  # as much as in the prose.
  if have codespell "spelling (en_US)"; then
    mapfile -t SPELL_FILES < <(git ls-files)
    run "spelling (en_US)" "$VENV/bin/codespell" "${SPELL_FILES[@]}"
  fi
  if have mkdocs "docs (mkdocs --strict)"; then
    run "docs (mkdocs --strict)" "$PROJECT/tools/build-docs.sh"
    # Deliberately not chained onto the build with &&: `run` always succeeds
    # (it records the failure rather than propagating it), so a && here would
    # look like a dependency and enforce nothing. If the build failed there is
    # no site to inspect and this reports that, which is a second failure line
    # for one root cause - noisy, but never silently skipped.
    #
    # A tenth of a second, no browser, and it guards the constraint the whole
    # site is designed around: the diagram library is on disk rather than at a
    # CDN, and every page that needs the init script loads it. The browser gate
    # below proves diagrams DRAW; this proves they COULD without a network.
    run "diagram assets (offline)" "$PROJECT/tools/check-diagram-assets.sh"
    # The one page that is a list of facts about the code rather than prose
    # about it, so it is the one page that can be checked against the code.
    run "settings page matches the code" "$PROJECT/tools/check-config-docs.sh"
    # The workflows rebuild the site only when its inputs change, and a page
    # can quietly acquire an input outside docs/.
    run "site inputs are watched" "$PROJECT/tools/check-site-inputs.sh"
  fi
fi

# --- workflows ---------------------------------------------------------------

if wanted workflows; then
  cd "$PROJECT" || exit 1
  # The CI definition is code too, and the only code here that used to be
  # testable solely by pushing it. actionlint finds its shellcheck on PATH,
  # which is the pinned one.
  need actionlint "actionlint" && run "actionlint" actionlint
fi

# --- diagrams ---------------------------------------------------------------

if wanted diagrams; then
  cd "$PROJECT" || exit 1
  if [ "$FAST" = 1 ]; then
    printf '%s>>> diagrams (skipped: --fast)%s\n\n' "$DIM" "$OFF"
  else
    # The only gate that opens a browser, and the only one that can catch a
    # diagram silently coming out as gray text - which is exactly what twelve of
    # them did, through a clean --strict build, for hours. It drives ONE browser
    # over every page, so it is seconds plus a site build rather than the minute
    # it used to be; it stays out of --fast because it still needs a browser,
    # which a machine making a commit may not have.
    run "diagrams (headless render)" "$PROJECT/tools/check-diagrams.sh"
  fi
fi

# --- mcu -------------------------------------------------------------------

if wanted mcu; then
  if [ "$FAST" = 1 ]; then
    printf '%s>>> ztest (skipped: --fast)%s\n\n' "$DIM" "$OFF"
  else
    # Builds Zephyr for native_sim, so this is the slow one (~70s).
    run "ztest (native_sim)" "$PROJECT/mcu/ztest.sh"
  fi
fi

# --- summary ---------------------------------------------------------------

printf '%s--- summary ---%s\n' "$BOLD" "$OFF"
for p in "${PASSED[@]}"; do printf '  %sPASS%s  %s\n' "$GREEN" "$OFF" "$p"; done
for f in "${FAILED[@]}"; do printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$f"; done

if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\n%d gate(s) failed.\n' "${#FAILED[@]}"
  exit 1
fi
printf '\nAll %d gates passed.\n' "${#PASSED[@]}"
