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
if (cd "$DEST" && sha256sum ./*.exe ./*.zip ./*.deb ./*.tar.gz 2>/dev/null >SHA256SUMS.txt); then
  did "SHA256SUMS.txt ($(grep -c . "$DEST/SHA256SUMS.txt") files)"
else
  warn "no installers present to checksum"
fi

step "total"
skip "$(du -sh "$DEST" | cut -f1) in $DEST"

summary
