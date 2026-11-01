#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Two root filesystems, phase 1: root's copy of the tool that plans them.
#
#   sudo bash ~/two-computers-one-board/provision/86-root-slots.sh
#   sudo /usr/local/lib/unoq/recovery/unoq-root.sh plan
#
# Idempotent: a second run reports "already correct" and changes nothing. It is
# not in bootstrap.sh's default run, nor in --everything: it takes
# --with-root-slots.
#
# Issue #169. A second root, `rootfs-b`, made from the second half of today's
# 20 GiB `rootfs`, so that an upgrade can be tried in one root while the other
# is left as it was. This step does NOT make it. All it installs is
# recovery/unoq-root.sh, as root's copy in /usr/local/lib/unoq/recovery/,
# whose `plan` prints this board's partition table, the one proposed, the
# exact sfdisk script that would get there, and whether the root filesystem
# fits a 10 GiB slot. It reads; it writes nothing.
#
# THE SPLIT IS A SEPARATE STEP, BY HAND, AND NOT IN THIS RELEASE. It rewrites
# the partition table and shrinks a mounted filesystem's partition, so it is
# done once, from the rescue shell (84-rescue-entry.sh), with nothing mounted:
# phase 2 of #169, which comes back to the owner for its own approval. No run
# of this script or of bootstrap.sh will ever do it.
#
# It installs no unit. The one that commits a blessed trial is phase 3.
#
# REVERT: nothing to undo on the disk or the EFI partition. Root's copy is part
#         of the one set every step installs (runtime_files, provision/lib.sh),
#         and is inert until someone runs it:
#         sudo rm -r /usr/local/lib/unoq/recovery    (the next step puts it back)
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

TOOL="$RUNTIME_DIR/recovery/unoq-root.sh"

# REVERT: sudo rm -r /usr/local/lib/unoq/recovery
step "root's copy of unoq-root"
# The whole set, as every step that installs root's scripts does: install_runtime
# removes what it is not given, so a step that passed only its own file would
# delete the others'. 1 only means nothing changed.
install_root_scripts || true
[ -x "$TOOL" ] || fail "$TOOL is not there after installing root's scripts"
skip "$TOOL"

step "now"
skip "nothing on the disk was changed: the split is a separate step, by hand, from the rescue shell (#169, phase 2), and not in this release"
skip "this board's plan, which only reads: sudo $TOOL plan"
skip "which root is running: sudo $TOOL status"

summary
