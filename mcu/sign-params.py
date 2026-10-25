#!/usr/bin/env python3
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Print the imgtool arguments a build's own devicetree calls for.

    sign-params.py <build dir> <zephyr base>
    ->  --align 16 --slot-size 425984     (this board's)

Called by mcu/zbuild.sh, which signs every MCUboot image it builds.

WHY THIS EXISTS
---------------
`west sign -t imgtool` used to do the whole job, and Zephyr has deprecated it:
every build printed a warning that it will be removed. Its replacement is to
let the build sign, which takes the image version from Kconfig - and a Kconfig
value that changes on every build rebuilds every object file on every build.
Measured: all 251 steps, where a build with nothing changed runs none. This
project stamps each build with a new version on purpose (the update chapter
depends on telling two builds apart), so that was not a trade worth making.

What `west sign` actually did was small: read two numbers out of the build's
devicetree and pass them to imgtool. This does the same reading, from the same
file, so the image is the same one - checked by signing one build both ways and
comparing the digest imgtool reports.

    --align       the flash's write-block-size
    --slot-size   the size of slot1_partition, or of slot0_partition if there
                  is no slot1 (see the comment in params)

The third number imgtool needs, the header size, is CONFIG_ROM_START_OFFSET in
the build's .config, and zbuild.sh reads that itself.

The devicetree is read from edt.pickle, which the build writes, with the
library Zephyr ships for the purpose. It is a pickle, and unpickling runs
whatever the file says; this one was written by the build that is about to be
signed, a moment ago, in a directory the same user owns.
"""

from __future__ import annotations

import pickle
import sys
from pathlib import Path


def params(build: Path, zephyr_base: Path) -> tuple[int, int]:
    """(write alignment, size of the slot the image must fit) for the build in `build`.

    The slot is slot1 when the devicetree has one, and slot0 otherwise.
    """
    sys.path.insert(0, str(zephyr_base / "scripts" / "dts" / "python-devicetree" / "src"))
    edt_file = build / "zephyr" / "edt.pickle"
    if not edt_file.is_file():
        raise SystemExit(f"no devicetree at {edt_file} - has this been built?")
    with edt_file.open("rb") as f:
        # Unpickling runs code, which is safe only because this build wrote it;
        # see the docstring. (Ruff's S rules are not enabled here, so a noqa
        # for one of them was itself a finding: RUF100.)
        edt = pickle.load(f)

    flash = edt.chosen_node("zephyr,flash")
    if not flash:
        raise SystemExit("the devicetree has no chosen zephyr,flash node")
    if "write-block-size" not in flash.props:
        raise SystemExit("the zephyr,flash node has no write-block-size")
    align = flash.props["write-block-size"].val
    if not align:
        raise SystemExit("the flash's write-block-size is 0")

    # slot1's size when there is a slot1, slot0's otherwise - which is west
    # sign's rule, and not an accident. An update is written to slot1, and some
    # layouts make it a sector smaller than slot0; an image signed to fit
    # slot0 would then build, flash, run, and fail to fit the first time it was
    # sent as an update. On this board the two are the same size, so signing
    # for slot0 gave the same image, and would have gone on doing so until
    # somebody changed the partition table.
    partitions = flash.children.get("partitions")
    slots = {}
    if partitions:
        for node in partitions.children.values():
            for label in ("slot0_partition", "slot1_partition"):
                if label in node.labels:
                    slots[label] = node
    if "slot0_partition" not in slots:
        raise SystemExit("the zephyr,flash node has no slot0_partition")
    slot = slots.get("slot1_partition", slots["slot0_partition"])
    if not slot.regs or not slot.regs[0].size:
        raise SystemExit("the slot the image must fit has no size in the devicetree")
    return int(align), int(slot.regs[0].size)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    align, size = params(Path(argv[1]), Path(argv[2]))
    print(f"--align {align} --slot-size {size}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
