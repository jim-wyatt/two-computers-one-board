#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Fetch the pinned headless browser the diagram gate uses in CI.
#
#   tools/install-diagram-browser.sh <directory>
#
# Prints the path of the browser on stdout, and everything else on stderr, so:
#
#   export UNOQ_DIAGRAM_BROWSER="$(tools/install-diagram-browser.sh ~/.cache/unoq-browser)"
#   tools/check-diagrams.sh
#
# No sudo and no apt, like install-dev-tools.sh: one zip, unpacked where you
# say, removed by deleting that directory.
#
# WHY CI DOES NOT USE THE BROWSER IT ALREADY HAS
# ----------------------------------------------
# A GitHub runner ships a chromium and a google-chrome, and the gate used them.
# It failed three times there and two of the three were that browser changing
# underneath the job: old headless mode disappearing in one image update, and a
# chromium that never exits from --dump-dom arriving in another. Neither was a
# change to this repository, and both turned up as a red tick on somebody's
# unrelated pull request.
#
# So CI gets a browser that moves when a commit here moves it. Same argument as
# the shellcheck and shfmt pins in install-dev-tools.sh.
#
# chrome-headless-shell rather than full Chrome because it is the build made
# for exactly this - no window system, and fewer shared libraries to find. It
# comes from Chrome for Testing, which keeps every version at a permanent url.
#
# PINNED BY HASH AS WELL AS VERSION. The version makes the run repeatable; the
# hash is what makes a 124 MB executable from a storage bucket something this
# repository has actually chosen, rather than whatever is at that url today.
#
# x86_64 ONLY, DELIBERATELY. The board is aarch64 and uses Debian's own
# `chromium`, which check-diagrams.sh finds on PATH - it is what a reader of the
# course has, and the board must not depend on a download to run its own gates.
# This script is for the machines that have no browser of their own to trust.
#
# To move the pin: pick a version from
#   https://googlechromelabs.github.io/chrome-for-testing/
# set VERSION, run this once, and copy the hash it reports into SHA256.
set -euo pipefail

VERSION="155.0.8059.39"
SHA256="39dcb8c46550632a3d911850ab3b8af840b4e3f6d8622faa2018eb8756278786"

DEST="${1:-}"
if [ -z "$DEST" ]; then
  sed -n '4,6p' "$0" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64 | amd64) ;;
  *)
    echo "no pinned browser for $(uname -m) - install your distribution's chromium" >&2
    echo "  (on the board it is already there, and check-diagrams.sh will find it," >&2
    echo "  unless provision/56-slim-root.sh removed it: sudo apt-get install chromium)" >&2
    exit 1
    ;;
esac

BROWSER="$DEST/chrome-headless-shell-linux64/chrome-headless-shell"

# The version is asked of the binary, not inferred from the directory existing:
# a half-unpacked zip leaves the directory and no working browser.
if [ -x "$BROWSER" ] && "$BROWSER" --version 2>/dev/null | grep -qF " $VERSION"; then
  echo "chrome-headless-shell $VERSION already in $DEST" >&2
  echo "$BROWSER"
  exit 0
fi

mkdir -p "$DEST"
zip="$(mktemp)"
trap 'rm -f "$zip"' EXIT

echo "=== chrome-headless-shell $VERSION -> $DEST ===" >&2
# -f so an HTTP error is an error, rather than an HTML page handed to unzip.
curl -fsSL --retry 3 -o "$zip" \
  "https://storage.googleapis.com/chrome-for-testing-public/$VERSION/linux64/chrome-headless-shell-linux64.zip" || {
  echo "  could not download chrome-headless-shell $VERSION" >&2
  exit 1
}

got="$(sha256sum "$zip" | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
  cat >&2 <<EOF
  the download does not match the pinned hash, so it has NOT been unpacked

    pinned  $SHA256
    got     $got

  If you have just changed VERSION, that second line is the new SHA256.
  If you have not, the file at that url changed, and that wants looking into.
EOF
  exit 1
fi

# python's zipfile rather than `unzip`: python3 is already a requirement of the
# gate itself, and unzip is not installed everywhere - it was missing on the
# first machine this was run on. It does not restore the executable bit, hence
# the chmod.
rm -rf "$DEST/chrome-headless-shell-linux64"
python3 -m zipfile -e "$zip" "$DEST"
chmod +x "$BROWSER"

# A browser that cannot find its libraries says so in a way nobody can act on.
# Ask the loader instead, and name them.
missing="$(ldd "$BROWSER" 2>/dev/null | awk '/not found/ {print $1}' | sort -u)"
if [ -n "$missing" ]; then
  echo "  it is unpacked but cannot start - these shared libraries are missing:" >&2
  echo "$missing" | while read -r lib; do echo "    $lib" >&2; done
  echo "  its own list of Debian packages is $DEST/chrome-headless-shell-linux64/deb.deps" >&2
  exit 1
fi

"$BROWSER" --version >&2 || {
  echo "  it is unpacked and linked, and still will not run" >&2
  exit 1
}
echo "$BROWSER"
