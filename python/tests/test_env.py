# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""MCU.env(): the BME680 on the header's I2C, as the firmware reports it.

The part is not on the board yet, so every reply here is one the firmware's
format implies (test_contract.py renders them from app_proto.h itself). What
is pinned: the units come back as sent, a missing sensor is told apart from a
failed read and from an old firmware, and nothing half-parsed is a reading.
"""

from __future__ import annotations

from typing import Any

import pytest

from unoq import EnvError, EnvReading
from unoq.mcu import MCUError, ShellTimeout

ROOM = "temp_mc=21530 humidity_mpct=45123 pressure_pa=101325 gas_ohm=52345"


def test_env_reads_all_four_in_the_units_sent(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": [ROOM]})
    r = mcu.env()
    assert r == EnvReading(21530, 45123, 101325, 52345)
    assert mcu._s.written == ["app env"]


def test_the_properties_are_the_units_people_quote() -> None:
    r = EnvReading(21530, 45123, 101325, 52345)
    assert r.temp_c == pytest.approx(21.53)
    assert r.humidity_pct == pytest.approx(45.123)
    assert r.pressure_hpa == pytest.approx(1013.25)


def test_env_keeps_the_sign_below_freezing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": ["temp_mc=-500 humidity_mpct=0 pressure_pa=30000 gas_ohm=0"]})
    assert mcu.env().temp_c == -0.5


def test_env_survives_color_and_a_dribbling_uart(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": [ROOM]}, ansi=True, chunk_size=3)
    assert mcu.env().gas_ohm == 52345


def test_no_sensor_is_an_env_error_that_says_to_check_the_wiring(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": ["Error: env_err=-19"]}, ansi=True)
    with pytest.raises(EnvError, match=r"env_err=-19.*no BME680 answered.*3\.3 V") as caught:
        mcu.env()
    assert caught.value.errno == -19
    # Still an MCUError, so a caller that handles those handles this.
    assert isinstance(caught.value, MCUError)


def test_a_failed_read_is_an_env_error_of_its_own(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": ["Error: env_err=-11"]})
    with pytest.raises(EnvError, match=r"env_err=-11.*read failed") as caught:
        mcu.env()
    assert caught.value.errno == -11


def test_some_other_refusal_is_passed_on_unchanged(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app env": ["Error: something else"]})
    with pytest.raises(MCUError, match="something else") as caught:
        mcu.env()
    assert not isinstance(caught.value, EnvError)


def test_a_timeout_is_passed_on_unchanged(
    mcu_factory: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    mcu = mcu_factory({})

    def no_prompt(command: str, timeout: float = 2.0) -> list[str]:
        raise ShellTimeout(f"no prompt after {timeout}s for {command!r}")

    monkeypatch.setattr(mcu, "cmd", no_prompt)
    with pytest.raises(ShellTimeout):
        mcu.env()


def test_env_says_so_when_the_firmware_predates_it(mcu_factory: Any) -> None:
    help_text = ["app - UNO Q application commands", "Subcommands:", "status  : uptime"]
    mcu = mcu_factory({"app env": help_text})
    with pytest.raises(MCUError, match="no `app env` command"):
        mcu.env()


@pytest.mark.parametrize(
    "reply",
    [
        [],
        ["temp_mc=21530 humidity_mpct=45123 pressure_pa=101325"],
        ["temp_mc=21530 humidity_mpct=-1 pressure_pa=101325 gas_ohm=52345"],
        ["last " + ROOM],
        [ROOM, ROOM],
        ["temp_mc=21530"],
    ],
)
def test_env_raises_on_anything_but_one_whole_line(mcu_factory: Any, reply: list[str]) -> None:
    mcu = mcu_factory({"app env": reply})
    with pytest.raises(MCUError, match="could not parse app env"):
        mcu.env()
