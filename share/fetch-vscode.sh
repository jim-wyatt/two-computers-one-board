#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Fetch the VS Code installers that the board hands out over USB.
#
#   sudo bash ~/two-computers-one-board/share/fetch-vscode.sh
#
# Idempotent: an installer already present with a non-zero size is left alone.
# Re-run it to pick up a newer VS Code release (use --refresh to force).
#
# WHY THE BOARD CARRIES THESE
# ---------------------------
# The board is the thing you plug into a laptop that may have no internet, or a
# locked-down one. Microsoft's `update.code.visualstudio.com/latest/...` aliases
# always resolve to the current stable build, so this stays current without
# pinning a version that goes stale in the repo.
#
# These are Microsoft's binaries under their own license - they are downloaded
# onto your board, never redistributed by this project. See docs/third-party.md.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/provision/lib.sh"
need_root

SHARE="${UNOQ_SHARE:-/var/lib/unoq-share}"
DEST="$SHARE/vscode"
# Where share/build-image.sh puts them: it MOVES the installers out of $DEST
# into the drive image, because the small root filesystem has no room for
# both copies. So "not in $DEST" is the normal state after a build, and this
# used to read it as "not downloaded" and fetch all ~2 GB again.
ON_DRIVE="${UNOQ_SHARE_MOUNT:-/srv/unoq-share}/vscode"
REFRESH=0
[ "${1:-}" = "--refresh" ] && REFRESH=1

# platform-id -> filename. The ids are Microsoft's own download aliases.
TARGETS=(
  "win32-x64-user|VSCodeUserSetup-x64.exe|Windows 10/11, 64-bit (per-user install)"
  "win32-arm64-user|VSCodeUserSetup-arm64.exe|Windows on ARM (Surface, Snapdragon)"
  "darwin-universal|VSCode-darwin-universal.zip|macOS, Intel and Apple Silicon"
  "linux-deb-x64|code-amd64.deb|Debian/Ubuntu, 64-bit"
  "linux-deb-arm64|code-arm64.deb|Debian/Ubuntu, ARM64 (incl. this board)"
  "linux-x64|code-x64.tar.gz|Any Linux, 64-bit (portable tarball)"
)

mkdir -p "$DEST"

step "VS Code installers -> $DEST"
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r platform filename _ <<<"$entry"
  target="$DEST/$filename"
  if [ "$REFRESH" = 0 ] && [ -s "$target" ]; then
    skip "$filename ($(du -h "$target" | cut -f1))"
    continue
  fi
  if [ "$REFRESH" = 0 ] && [ -s "$ON_DRIVE/$filename" ]; then
    skip "$filename already on the drive ($(du -h "$ON_DRIVE/$filename" | cut -f1)); --refresh to fetch it again"
    continue
  fi
  url="https://update.code.visualstudio.com/latest/$platform/stable"
  # Download beside the target and move on success, so an interrupted run never
  # leaves a truncated installer that looks complete to the next one.
  if curl -fL --progress-bar --max-time 900 "$url" -o "$target.part"; then
    mv "$target.part" "$target"
    did "$filename ($(du -h "$target" | cut -f1))"
  else
    rm -f "$target.part"
    warn "could not fetch $filename from $url"
  fi
done

step "checksums"
# So a laptop can verify what it copied off a board that has been sitting on a
# bench. Written last, covering whatever actually downloaded.
#
# The installers that are here, as a list: the four patterns were handed to
# sha256sum as they were, and any one that matched nothing reached it as a
# literal "./*.zip". sha256sum then failed for that one file, having summed
# every other, and this warned "no installers present" over a full set of
# checksums.
#
# And every installer the drive will hold, not only those fetched this run:
# build-image.sh moves this SHA256SUMS.txt over the one on the drive, so a list
# of the new ones alone would drop the checksums of everything already there.
# An installer here replaces the drive's copy, so it is the one summed.
shopt -s nullglob
new=("$DEST"/*.exe "$DEST"/*.zip "$DEST"/*.deb "$DEST"/*.tar.gz)
kept=()
for f in "$ON_DRIVE"/*.exe "$ON_DRIVE"/*.zip "$ON_DRIVE"/*.deb "$ON_DRIVE"/*.tar.gz; do
  [ -e "$DEST/${f##*/}" ] || kept+=("$f")
done
shopt -u nullglob
if [ ${#new[@]} -eq 0 ]; then
  if [ ${#kept[@]} -gt 0 ]; then
    skip "nothing new here; the drive keeps the checksums of what it holds"
  else
    warn "no installers present to checksum"
  fi
elif sha256sum "${new[@]}" ${kept[@]+"${kept[@]}"} | sed 's#  .*/#  #' >"$DEST/SHA256SUMS.txt.part" &&
  mv "$DEST/SHA256SUMS.txt.part" "$DEST/SHA256SUMS.txt"; then
  did "SHA256SUMS.txt ($((${#new[@]} + ${#kept[@]})) files, ${#new[@]} new)"
else
  rm -f "$DEST/SHA256SUMS.txt.part"
  warn "could not checksum the installers in $DEST"
fi

step "total"
skip "$(du -sh "$DEST" | cut -f1) in $DEST"

summary
