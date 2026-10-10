#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/check-site-inputs.sh is what makes it safe for the workflows to rebuild
# the site only when its inputs change. A page can embed any file in the
# repository, and from then on a change to that file changes the site without
# touching docs/. The gate has to see every way of writing such an include, and
# it has to check BOTH filters - the first version saw one form and one filter.
#
# It reads the repository it lives in, so each test builds a small one.

setup() {
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/tools" "$R/docs/learn" "$R/.github/workflows" "$R/mcu/app/src"
  cp "$PROJECT/tools/check-site-inputs.sh" "$R/tools/"
  : >"$R/mcu/app/src/bars.c"
  workflows
  git -C "$R" init -q
}

# workflows [extra pages path] [extra alternative in the diagrams regex]
workflows() {
  {
    printf 'on:\n  push:\n    paths:\n'
    printf "      - 'docs/**'\n      - 'mkdocs.yml'\n"
    [ -z "${1:-}" ] || printf "      - '%s'\n" "$1"
  } >"$R/.github/workflows/pages.yml"
  local extra=""
  [ -z "${2:-}" ] || extra="|$2"
  {
    printf "          if grep -qE '^(mcu/|west\\\\.yml)' <<<\"\$files\"; then\n"
    printf '            echo "firmware inputs changed - building"\n          fi\n'
    printf "          if grep -qE '^(docs/|mkdocs\\\\.yml%s)' <<<\"\$files\"; then\n" "$extra"
    printf '            echo "site inputs changed - rendering the diagrams"\n          fi\n'
  } >"$R/.github/workflows/ci.yml"
}

page() {
  cat >"$R/docs/learn/page.md"
  git -C "$R" add -A
}

check() { run "$R/tools/check-site-inputs.sh"; }

@test "a site with no includes passes" {
  page <<<"Just prose."
  check
  [ "$status" -eq 0 ]
}

@test "an include from inside docs/ is already watched" {
  page <<<'--8<-- "docs/includes/abbreviations.md"'
  check
  [ "$status" -eq 0 ]
}

@test "a one-line include from outside docs/ fails, and names the file" {
  page <<<'--8<-- "mcu/app/src/bars.c"'
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"mcu/app/src/bars.c"* ]]
}

@test "single quotes are an include too" {
  page <<<"--8<-- 'mcu/app/src/bars.c'"
  check
  [ "$status" -eq 1 ]
}

@test "the block form is seen: targets between two bare markers" {
  page <<'MD'
```c
--8<--
docs/includes/ok.md
mcu/app/src/bars.c
--8<--
```
MD
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"mcu/app/src/bars.c"* ]]
  [[ "$output" != *"docs/includes/ok.md"* ]]
}

@test "a line-number selector is not part of the name" {
  workflows mcu/app/src/bars.c 'mcu/app/src/bars\.c'
  page <<<'--8<-- "mcu/app/src/bars.c:10:20"'
  check
  [ "$status" -eq 0 ]
}

@test "a named-region selector is not part of the name either" {
  workflows mcu/app/src/bars.c 'mcu/app/src/bars\.c'
  page <<<'--8<-- "mcu/app/src/bars.c:draw"'
  check
  [ "$status" -eq 0 ]
}

@test "listed for the site but not for the diagrams is still a failure" {
  workflows mcu/app/src/bars.c
  page <<<'--8<-- "mcu/app/src/bars.c"'
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not covered by: .github/workflows/ci.yml"* ]]
}

@test "listed for the diagrams but not for the site is still a failure" {
  workflows "" 'mcu/app/src/bars\.c'
  page <<<'--8<-- "mcu/app/src/bars.c"'
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not covered by: .github/workflows/pages.yml"* ]]
  [[ "$output" != *"pages.yml and .github/workflows/ci.yml"* ]]
}

@test "an escaped marker is prose about includes, not an include" {
  page <<<';--8<-- "mcu/app/src/bars.c"'
  check
  [ "$status" -eq 0 ]
}

@test "a diagrams filter that cannot be found is an error, not a pass" {
  echo "jobs: {}" >"$R/.github/workflows/ci.yml"
  page <<<"Just prose."
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not find the diagrams filter"* ]]
}
