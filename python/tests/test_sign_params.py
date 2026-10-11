# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""mcu/sign-params.py: the two numbers imgtool is given, read from a devicetree.

The script replaced `west sign`, and the first version of it got west's rule
wrong in a way no build on this board could show: it took the size of slot0,
where west takes slot1's when there is one. Here the two slots are the same
size, so the signed image was identical and every check passed. On a layout
where slot1 is a sector smaller, the image would have been signed to fit a slot
it is never uploaded to.

So the rule is tested against devicetrees this board does not have.
"""

from __future__ import annotations

import importlib.util
import pickle
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "mcu" / "sign-params.py"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("sign_params", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def partition(label: str, size: int | None) -> SimpleNamespace:
    regs = [] if size is None else [SimpleNamespace(addr=0, size=size)]
    return SimpleNamespace(labels=[label], regs=regs)


def tree(*, align: int | None = 16, slots: dict[str, int | None] | None = None) -> SimpleNamespace:
    """A devicetree with just enough in it: a flash, and its partitions."""
    props = {} if align is None else {"write-block-size": SimpleNamespace(val=align)}
    children: dict[str, Any] = {}
    if slots is not None:
        nodes = {
            f"partition@{i}": partition(label, size)
            for i, (label, size) in enumerate(slots.items())
        }
        nodes["partition@boot"] = partition("boot_partition", 0x10000)
        children["partitions"] = SimpleNamespace(children=nodes)
    flash = SimpleNamespace(props=props, children=children)
    return SimpleNamespace(chosen_node=lambda name: flash if name == "zephyr,flash" else None)


@pytest.fixture
def build(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    """A build directory whose edt.pickle 'contains' whatever the test says."""
    (tmp_path / "zephyr").mkdir()
    (tmp_path / "zephyr" / "edt.pickle").write_bytes(b"")
    holder: dict[str, Any] = {}
    monkeypatch.setattr(pickle, "load", lambda _f: holder["edt"])

    def use(edt: Any) -> Path:
        holder["edt"] = edt
        return tmp_path

    return use


def test_this_boards_layout(build: Any) -> None:
    edt = tree(slots={"slot0_partition": 0x68000, "slot1_partition": 0x68000})
    assert load().params(build(edt), Path("/z")) == (16, 0x68000)


def test_a_smaller_slot1_is_the_one_the_image_must_fit(build: Any) -> None:
    edt = tree(slots={"slot0_partition": 0x68000, "slot1_partition": 0x67000})
    assert load().params(build(edt), Path("/z")) == (16, 0x67000)


def test_with_no_slot1_it_is_slot0(build: Any) -> None:
    edt = tree(slots={"slot0_partition": 0x68000})
    assert load().params(build(edt), Path("/z")) == (16, 0x68000)


def test_the_alignment_is_the_flashs_write_block_size(build: Any) -> None:
    edt = tree(align=8, slots={"slot0_partition": 0x68000})
    assert load().params(build(edt), Path("/z"))[0] == 8


@pytest.mark.parametrize(
    ("edt", "says"),
    [
        (SimpleNamespace(chosen_node=lambda _n: None), "no chosen zephyr,flash"),
        (tree(align=None, slots={"slot0_partition": 0x68000}), "no write-block-size"),
        (tree(align=0, slots={"slot0_partition": 0x68000}), "write-block-size is 0"),
        (tree(slots=None), "no slot0_partition"),
        (tree(slots={"slot1_partition": 0x68000}), "no slot0_partition"),
        (tree(slots={"slot0_partition": None}), "has no size"),
        (tree(slots={"slot0_partition": 0x68000, "slot1_partition": 0}), "has no size"),
    ],
)
def test_a_devicetree_it_cannot_sign_from_is_refused_in_words(
    build: Any, edt: Any, says: str
) -> None:
    with pytest.raises(SystemExit, match=says):
        load().params(build(edt), Path("/z"))


def test_a_directory_that_was_never_built_says_so(tmp_path: Path) -> None:
    with pytest.raises(SystemExit, match="has this been built"):
        load().params(tmp_path, Path("/z"))


def test_main_prints_what_imgtool_takes(build: Any, capsys: pytest.CaptureFixture[str]) -> None:
    edt = tree(slots={"slot0_partition": 0x68000, "slot1_partition": 0x68000})
    assert load().main(["sign-params.py", str(build(edt)), "/z"]) == 0
    assert capsys.readouterr().out == "--align 16 --slot-size 425984\n"


def test_main_with_the_wrong_arguments_is_a_usage_error(capsys: pytest.CaptureFixture[str]) -> None:
    assert load().main(["sign-params.py"]) == 2
    assert "sign-params.py <build dir> <zephyr base>" in capsys.readouterr().err
