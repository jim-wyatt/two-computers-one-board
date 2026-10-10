# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Package-level guarantees: the public surface and the real-hardware smoke test."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

import unoq


def test_public_names_are_all_importable() -> None:
    for name in unoq.__all__:
        assert hasattr(unoq, name), f"{name} is in __all__ but not exported"


def test_version_matches_pyproject() -> None:
    """Catch the classic drift between __version__ and the packaging metadata."""
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    declared = tomllib.loads(pyproject.read_text())["project"]["version"]
    assert unoq.__version__ == declared


def test_importing_unoq_touches_no_hardware() -> None:
    """Import must stay free of side effects.

    `import unoq` previously being safe is why tooling, tests and an editor can
    all load it on a board that is mid-flash. If someone adds a link_up() at
    module scope, this fails.
    """
    import subprocess
    import sys

    result = subprocess.run(
        [sys.executable, "-c", "import unoq"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr


# -- opt-in hardware checks --------------------------------------------------
# Run with:  pytest -m hardware
# These need a live MCU on /dev/ttyHS1 and are deselected by default so the
# suite stays runnable on a board that is mid-flash, or on no board at all.


@pytest.mark.hardware
def test_real_mcu_reports_status() -> None:
    from unoq import MCU

    with MCU() as mcu:
        status = mcu.status()
    assert "uptime_ms" in status
    assert "sweeps" in status


@pytest.mark.hardware
def test_real_link_lines_are_driven() -> None:
    from unoq.link import link_state

    # INPUT here means the link is floating - see docs/reference/hardware.md.
    assert link_state() == {"boot0": "OUTPUT", "link_enable": "OUTPUT"}
