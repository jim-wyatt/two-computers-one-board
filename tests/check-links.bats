#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/check-links.sh runs once a month on a runner and files an issue with
# whatever it prints. It has three answers - nothing dead (0), something dead
# (1), could not tell (2) - and the third exists for one reason: a runner with
# no network sees every link fail, and that must not become an issue listing
# every link in the documentation as dead.
#
# It stopped being able to give that answer. Links into this repository are
# checked against the checkout, which needs no network, and they were counted
# in the same total the outage test asked about. So with the network gone the
# total was never zero, and "could not tell" came out as "all of these are
# dead".
#
# The script is copied into a small tree of its own here, because it works out
# the project from where it sits and reads every .md under docs/. That keeps
# these tests to the two or three links each one is about, and off the network.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/tools" "$TREE/docs"
  cp "$PROJECT/tools/check-links.sh" "$TREE/tools/"
  echo "# a readme" >"$TREE/README.md"
  LINKS="$TREE/tools/check-links.sh"
  OWN="https://github.com/jim-wyatt/two-computers-one-board/blob/main"

  # It waits between requests to one host, and before asking a failure again.
  stub sleep
}

# A curl for a machine with no network: no HTTP answer, so the status curl
# writes is 000, and it says why on stderr.
offline() {
  stub_body curl <<'SH'
printf '000'
echo "curl: (6) Could not resolve host" >&2
exit 6
SH
}

# A curl that answers $1 for every URL containing $2, and 200 for the rest.
answers() {
  export ANSWER_CODE="${1:-200}" ANSWER_FOR="${2:-no such url}"
  stub_body curl <<'SH'
case "$*" in
  *"$ANSWER_FOR"*) printf '%s' "$ANSWER_CODE" ;;
  *) printf '200' ;;
esac
SH
}

@test "no network is 'could not tell', even with links into this repository that check out" {
  cat >"$TREE/docs/page.md" <<EOF
[the readme]($OWN/README.md) and [somewhere else](https://zephyrproject.org/a-page).
EOF
  offline
  run "$LINKS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no network"* ]]
  [[ "$output" != *"DEAD"* ]]
}

@test "with the network up, a local link and an external one are both ok" {
  cat >"$TREE/docs/page.md" <<EOF
[the readme]($OWN/README.md) and [somewhere else](https://zephyrproject.org/a-page).
EOF
  answers
  run "$LINKS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 links: 2 ok, 0 unverifiable, 0 dead"* ]]
  # The local one was answered from the checkout, not by asking GitHub.
  refute ran_like 'github\.com/jim-wyatt'
}

@test "one dead link among live ones is still reported as dead" {
  cat >"$TREE/docs/page.md" <<EOF
[gone](https://zephyrproject.org/gone) and [there](https://docs.kernel.org/there).
EOF
  answers 404 /gone
  run "$LINKS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEAD (1)"* ]]
  [[ "$output" == *"404  https://zephyrproject.org/gone"* ]]
  [[ "$output" == *"docs/page.md:1"* ]]
}

@test "a link to a file this checkout does not have is dead, with the network up" {
  cat >"$TREE/docs/page.md" <<EOF
[renamed]($OWN/docs/no-such-file.md) and [there](https://docs.kernel.org/there).
EOF
  answers
  run "$LINKS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such file in this checkout: docs/no-such-file.md"* ]]
}

@test "documentation that links only into this repository needs no network to pass" {
  # Nothing was asked of the network, so its silence is not evidence of
  # anything: the outage answer is for when something was asked.
  cat >"$TREE/docs/page.md" <<EOF
[the readme]($OWN/README.md)
EOF
  offline
  run "$LINKS"
  [ "$status" -eq 0 ]
  never_ran curl
}

@test "every link answering 404 is every link dead, not 'no network'" {
  # A server that says "not here" has answered. Only good answers used to be
  # counted, so a run where all of them were real 404s exited 2 and listed
  # nothing.
  cat >"$TREE/docs/page.md" <<EOF2
[one](https://zephyrproject.org/gone) and [two](https://docs.kernel.org/gone).
EOF2
  answers 404 /gone
  run "$LINKS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEAD (2)"* ]]
  [[ "$output" != *"no network"* ]]
}

@test "every link answering a server error is unverifiable, not 'no network'" {
  cat >"$TREE/docs/page.md" <<EOF2
[one](https://zephyrproject.org/busy) and [two](https://docs.kernel.org/busy).
EOF2
  answers 503 /busy
  run "$LINKS"
  [[ "$output" != *"no network"* ]]
  [[ "$output" == *"UNVERIFIABLE (2)"* ]]
}
