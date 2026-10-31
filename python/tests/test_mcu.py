# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the Zephyr shell protocol and the parsing built on top of it.

The parsing is the fragile part of this package: it consumes text produced by
firmware that can change, over a UART that injects echo, ANSI color and a
prompt. Each test below pins one of those behaviors.
"""

from __future__ import annotations

from typing import Any

import pytest
from conftest import PROMPT

from unoq.mcu import MCU, MCUError, ShellTimeout, TempLogStat, TempSample, _clean

# -- _clean -----------------------------------------------------------------


def test_clean_strips_ansi_prompt_and_blanks() -> None:
    raw = f"\x1b[1;32m{PROMPT}\x1b[0m\r\nhello\r\n\r\n  spaced  \r\n{PROMPT}"
    assert _clean(raw) == ["hello", "spaced"]


def test_clean_treats_cr_as_a_line_break() -> None:
    # The shell terminates lines with \r\n; a lone \r must not glue lines.
    assert _clean("one\rtwo\r\nthree") == ["one", "two", "three"]


def test_clean_returns_nothing_for_prompt_only_output() -> None:
    assert _clean(PROMPT) == []


# -- cmd --------------------------------------------------------------------


def test_cmd_sends_crlf_and_strips_the_echo(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=1 flip=0"]})
    assert mcu.cmd("app status") == ["uptime_ms=1 flip=0"]
    # The command itself is echoed by the shell and must not be returned.
    assert mcu._s.written == ["app status"]


def test_cmd_survives_ansi_coloring(mcu_factory: Any) -> None:
    mcu = mcu_factory({"device list": ["- gpio@1 (READY)"]}, ansi=True)
    assert mcu.cmd("device list") == ["- gpio@1 (READY)"]


def test_cmd_resets_the_input_buffer_before_writing(mcu_factory: Any) -> None:
    # Stale bytes from a previous command would otherwise be parsed as output.
    mcu = mcu_factory({"x": ["ok"]})
    before = mcu._s.reset_count
    mcu.cmd("x")
    assert mcu._s.reset_count > before


def test_cmd_raises_shell_timeout_when_no_prompt_comes_back(mcu_factory: Any) -> None:
    mcu = mcu_factory(silent=True)
    with pytest.raises(ShellTimeout, match="no prompt"):
        mcu.cmd("app status", timeout=0.05)


def test_cmd_raises_on_unknown_command(mcu_factory: Any) -> None:
    mcu = mcu_factory({"nope": ["nope: command not found"]})
    with pytest.raises(MCUError, match="command not found"):
        mcu.cmd("nope")


def test_a_shell_refusal_for_argument_count_raises(mcu_factory: Any) -> None:
    """Seen on the board, word for word: one argument short of what px takes.

    The shell rejects the line before the handler runs, so there is no
    `Error:` prefix on it - only its own complaint and the usage text. That
    used to come back as an ordinary two-line reply.
    """
    mcu = mcu_factory(
        {
            "app matrix px 1 1": [
                "px: wrong parameter count",
                "px - Light one LED: app matrix px <row> <col> <level>",
            ]
        }
    )
    with pytest.raises(MCUError, match="wrong parameter count"):
        mcu.cmd("app matrix px 1 1")


def test_cmd_raises_on_error_lines(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app bars 200": ["Error: bar 0: 200 outside 0..100"]})
    with pytest.raises(MCUError, match="outside"):
        mcu.cmd("app bars 200")


# -- status -----------------------------------------------------------------


def test_status_parses_the_firmware_status_line(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=12216 flip=0 sweeps=1043712"]})
    assert mcu.status() == {"uptime_ms": 12216, "flip": 0, "sweeps": 1043712}


def test_status_keeps_unparsable_values_as_strings(mcu_factory: Any) -> None:
    # A firmware change should surface as an odd value, not a missing key.
    mcu = mcu_factory({"app status": ["uptime_ms=25 mode=fast"]})
    assert mcu.status() == {"uptime_ms": 25, "mode": "fast"}


def test_status_raises_when_the_mcu_says_nothing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": []})
    with pytest.raises(MCUError, match="returned nothing"):
        mcu.status()


def test_status_raises_when_no_key_value_pairs_are_present(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["garbage output"]})
    with pytest.raises(MCUError, match="could not parse"):
        mcu.status()


# -- die temperature --------------------------------------------------------

# What a firmware built before `app temp` existed answers with. The Zephyr
# shell does not say "command not found" for an unknown *sub*command of a group
# that has no handler of its own: exec_cmd() in subsys/shell/shell.c prints the
# group's help and stops. This is that help, for the `app` group as it was.
OLD_FIRMWARE_HELP = [
    "app - UNO Q application commands",
    "Subcommands:",
    "status  : uptime, panel orientation, refresh sweeps",
    "bars    : Draw CPU bars: app bars <pct> [pct ...]",
    "matrix  : LED panel control",
]


# -- reset_cause ---------------------------------------------------------------


def test_reset_cause_after_the_watchdog(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app reset": ["reset=watchdog,pin"]})
    assert mcu.reset_cause() == ["watchdog", "pin"]
    assert mcu._s.written == ["app reset"]


def test_reset_cause_with_one_cause(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app reset": ["reset=pin"]}, ansi=True, chunk_size=3)
    assert mcu.reset_cause() == ["pin"]


def test_reset_cause_none_is_an_empty_list(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app reset": ["reset=none"]})
    assert mcu.reset_cause() == []


def test_reset_cause_passes_an_unfamiliar_name_through(mcu_factory: Any) -> None:
    # A newer firmware's name is still a reason; dropping it would make the
    # reset look less explained than it is.
    mcu = mcu_factory({"app reset": ["reset=gremlins,pin"]})
    assert mcu.reset_cause() == ["gremlins", "pin"]


def test_reset_cause_says_so_when_the_firmware_predates_it(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app reset": OLD_FIRMWARE_HELP})
    with pytest.raises(MCUError, match="no `app reset` command"):
        mcu.reset_cause()


@pytest.mark.parametrize(
    "reply",
    [[], ["reset="], ["reset=Watchdog"], ["reset=watchdog,"], ["reset=watchdog pin"], ["x"]],
)
def test_reset_cause_raises_on_an_unparsable_reply(mcu_factory: Any, reply: list[str]) -> None:
    mcu = mcu_factory({"app reset": reply})
    with pytest.raises(MCUError, match="could not parse app reset"):
        mcu.reset_cause()


def test_die_temp_converts_millidegrees_to_degrees(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp": ["temp_mc=31250"]})
    assert mcu.die_temp() == 31.25
    assert mcu._s.written == ["app temp"]


def test_die_temp_keeps_the_sign_below_freezing(mcu_factory: Any) -> None:
    # The part is rated to -40 C. A parser that dropped the minus would turn a
    # cold board into a warm one, and nothing downstream could tell.
    mcu = mcu_factory({"app temp": ["temp_mc=-1500"]})
    assert mcu.die_temp() == -1.5


def test_die_temp_survives_color_and_a_dribbling_uart(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp": ["temp_mc=40000"]}, ansi=True, chunk_size=3)
    assert mcu.die_temp() == 40.0


def test_die_temp_reports_a_sensor_the_firmware_could_not_read(mcu_factory: Any) -> None:
    # shell_error() prints in red and adds no "Error:" prefix, so cmd() lets
    # this line through; die_temp() has to recognize it for itself.
    mcu = mcu_factory({"app temp": ["temp_err=-19"]}, ansi=True)
    with pytest.raises(MCUError, match=r"could not read its die temperature.*temp_err=-19"):
        mcu.die_temp()


def test_die_temp_never_returns_the_error_number_as_a_reading(mcu_factory: Any) -> None:
    # -19 millidegrees is a temperature. The error line must not parse as one
    # even if a reading somehow follows it.
    mcu = mcu_factory({"app temp": ["temp_err=-5", "temp_mc=25000"]})
    with pytest.raises(MCUError, match="temp_err=-5"):
        mcu.die_temp()


def test_die_temp_says_so_when_the_firmware_predates_the_command(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp": OLD_FIRMWARE_HELP})
    with pytest.raises(MCUError, match="no `app temp` command"):
        mcu.die_temp()


def test_die_temp_raises_on_an_unparsable_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp": ["temp_mc=warm"]})
    with pytest.raises(MCUError, match="could not parse app temp"):
        mcu.die_temp()


def test_die_temp_rejects_a_reading_buried_in_other_text(mcu_factory: Any) -> None:
    # Anchored on purpose: a line that merely contains the key is some other
    # line, and guessing at it is how a wrong number gets reported as a right one.
    mcu = mcu_factory({"app temp": ["last temp_mc=25000 stale"]})
    with pytest.raises(MCUError, match="could not parse app temp"):
        mcu.die_temp()


def test_die_temp_raises_on_no_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp": []})
    with pytest.raises(MCUError, match="could not parse app temp"):
        mcu.die_temp()


# -- the temperature log ----------------------------------------------------


def _samples(first: int, last: int) -> list[str]:
    """The lines the firmware prints for samples first..last, one a second."""
    return [f"seq={n} ms={n * 1000} temp_mc={30000 + n}" for n in range(first, last + 1)]


def test_temp_log_reads_samples_oldest_first(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log": [*_samples(1, 3), "end head=3 more=0"]})
    assert mcu.temp_log() == [
        TempSample(1, 1000, 30.001),
        TempSample(2, 2000, 30.002),
        TempSample(3, 3000, 30.003),
    ]
    assert mcu._s.written == ["app temp log"]


def test_temp_log_asks_after_since(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log 41": [*_samples(42, 43), "end head=43 more=0"]})
    assert [s.seq for s in mcu.temp_log(41)] == [42, 43]
    assert mcu._s.written == ["app temp log 41"]


def test_temp_log_with_nothing_new_is_empty(mcu_factory: Any) -> None:
    # A reader that is keeping up: since is the newest sample.
    mcu = mcu_factory({"app temp log 43": ["end head=43 more=0"]})
    assert mcu.temp_log(43) == []


def test_temp_log_pages_until_nothing_is_left(mcu_factory: Any) -> None:
    """The firmware caps a reply at 32 lines; temp_log() keeps asking from the
    last number it got, so the caller sees one unbroken list."""
    mcu = mcu_factory(
        {
            "app temp log": [*_samples(1, 32), "end head=70 more=38"],
            "app temp log 32": [*_samples(33, 64), "end head=70 more=6"],
            "app temp log 64": [*_samples(65, 70), "end head=70 more=0"],
        },
        ansi=True,
    )
    assert [s.seq for s in mcu.temp_log()] == list(range(1, 71))
    assert mcu._s.written == ["app temp log", "app temp log 32", "app temp log 64"]


def test_temp_log_stops_if_a_reply_promises_more_and_sends_none(mcu_factory: Any) -> None:
    # Asking again from the same number would get the same reply forever.
    mcu = mcu_factory({"app temp log 5": ["end head=9 more=4"]})
    assert mcu.temp_log(5) == []
    assert mcu._s.written == ["app temp log 5"]


def test_temp_log_keeps_a_failed_read_as_a_sample(mcu_factory: Any) -> None:
    mcu = mcu_factory(
        {
            "app temp log": [
                "seq=1 ms=1000 temp_mc=30001",
                "seq=2 ms=2000 temp_err=-5",
                "end head=2 more=0",
            ]
        }
    )
    failed = mcu.temp_log()[1]
    assert failed == TempSample(2, 2000, None, -5)
    assert failed.temp_c is None


def test_temp_log_keeps_the_sign_below_freezing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log": ["seq=1 ms=0 temp_mc=-1500", "end head=1 more=0"]})
    assert mcu.temp_log()[0].temp_c == -1.5


def test_a_gap_shows_as_a_jump_in_seq(mcu_factory: Any) -> None:
    """Samples 5 to 10 were overwritten before anyone asked. The firmware says
    so, and the record says so too: 4 is followed by 11."""
    mcu = mcu_factory(
        {"app temp log 4": ["gap first=5 last=10", *_samples(11, 12), "end head=12 more=0"]}
    )
    assert [s.seq for s in mcu.temp_log(4)] == [11, 12]


def test_a_reply_that_skips_samples_without_saying_so_raises(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log 4": [*_samples(6, 7), "end head=7 more=0"]})
    with pytest.raises(MCUError, match="does not follow on"):
        mcu.temp_log(4)


def test_a_gap_that_does_not_meet_the_first_sample_raises(mcu_factory: Any) -> None:
    mcu = mcu_factory(
        {"app temp log 4": ["gap first=5 last=10", *_samples(12, 12), "end head=12 more=0"]}
    )
    with pytest.raises(MCUError, match="does not follow on"):
        mcu.temp_log(4)


def test_temp_log_since_a_restart_raises(mcu_factory: Any) -> None:
    # What the firmware says to a since beyond its newest sample.
    refusal = "Error: since 900 is past the newest sample, 12: the MCU has restarted"
    mcu = mcu_factory({"app temp log 900": [refusal]})
    with pytest.raises(MCUError, match="restarted"):
        mcu.temp_log(900)


def test_temp_log_raises_on_a_reply_cut_short(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log": _samples(1, 3)})
    with pytest.raises(MCUError, match="without its end line"):
        mcu.temp_log()


def test_temp_log_raises_on_a_line_it_does_not_know(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log": ["seq=1 ms=1000 temp_mc=warm", "end head=1 more=0"]})
    with pytest.raises(MCUError, match="could not parse"):
        mcu.temp_log()


@pytest.mark.parametrize(
    "reply",
    [OLD_FIRMWARE_HELP, ["temp_mc=31250"]],
    ids=["no app temp", "app temp without log"],
)
def test_temp_log_says_so_when_the_firmware_predates_it(mcu_factory: Any, reply: list[str]) -> None:
    mcu = mcu_factory({"app temp log": reply})
    with pytest.raises(MCUError, match="no temperature log"):
        mcu.temp_log()


def test_temp_log_stat_parses_the_counters(mcu_factory: Any) -> None:
    mcu = mcu_factory(
        {"app temp log stat": ["head=610 count=600 size=600 dropped=10 period_ms=1000"]}
    )
    stat = mcu.temp_log_stat()
    assert stat == TempLogStat(head=610, count=600, size=600, dropped=10, period_ms=1000)
    assert mcu._s.written == ["app temp log stat"]


@pytest.mark.parametrize("reply", [[], ["head=1 count=1"]], ids=["nothing", "short"])
def test_temp_log_stat_raises_on_an_unparsable_reply(mcu_factory: Any, reply: list[str]) -> None:
    mcu = mcu_factory({"app temp log stat": reply})
    with pytest.raises(MCUError, match="could not parse app temp log stat"):
        mcu.temp_log_stat()


def test_temp_log_stat_says_so_when_the_firmware_predates_it(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app temp log stat": ["temp_mc=31250"]})
    with pytest.raises(MCUError, match="no temperature log"):
        mcu.temp_log_stat()


# -- LED matrix -------------------------------------------------------------


def test_bars_sends_one_value_per_bar(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app bars 10 20 30 40": ["ok bars=4"]})
    mcu.bars([10, 20, 30, 40])
    assert mcu._s.written == ["app bars 10 20 30 40"]


def test_bars_rounds_floats(mcu_factory: Any) -> None:
    # The sampler produces percentages, and `app bars` takes integers.
    mcu = mcu_factory({"app bars 33 67": ["ok bars=2"]})
    mcu.bars([33.4, 66.6])
    assert mcu._s.written == ["app bars 33 67"]


def test_bars_clamps_rather_than_raising(mcu_factory: Any) -> None:
    # A live measurement that arrives as 100.4 should light a full bar. The
    # firmware rejects out-of-range values, so clamping has to happen here.
    mcu = mcu_factory({"app bars 0 100": ["ok bars=2"]})
    mcu.bars([-3, 104])
    assert mcu._s.written == ["app bars 0 100"]


def test_bars_rejects_a_count_the_panel_cannot_show(mcu_factory: Any) -> None:
    # Unlike a stray percentage, this is a programming error: it cannot come
    # from a noisy reading, only from asking for the wrong thing.
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match=r"need 1\.\.7 values"):
        mcu.bars([50] * 8)


def test_bars_rejects_an_empty_reading(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match=r"need 1\.\.7 values"):
        mcu.bars([])


def test_matrix_px_coerces_its_coordinates(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix px 7 0 7": ["ok px row=7 col=0 level=7"]})
    mcu.matrix_px(7.0, 0.0)
    assert mcu._s.written == ["app matrix px 7 0 7"]


def test_matrix_flip_reports_the_new_state(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["ok flip=1"]})
    assert mcu.matrix_flip() is True


def test_matrix_flip_reports_being_flipped_back(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["ok flip=0"]})
    assert mcu.matrix_flip() is False


def test_matrix_flip_raises_on_an_unparsable_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["what"]})
    with pytest.raises(MCUError, match="could not parse matrix flip"):
        mcu.matrix_flip()


def test_matrix_flip_raises_when_the_mcu_could_not_save_it(mcu_factory: Any) -> None:
    # The firmware applies the flip for this boot and says it was not
    # persisted. That must not come back as a setting that will survive a reset.
    reply = "Error: flip=1 applied but not saved (-28): it reverts at reset"
    mcu = mcu_factory({"app matrix flip": [reply]})
    with pytest.raises(MCUError, match="not saved"):
        mcu.matrix_flip()


def test_matrix_flip_raises_on_no_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": []})
    with pytest.raises(MCUError, match="could not parse matrix flip"):
        mcu.matrix_flip()


def test_matrix_off_blanks_the_panel(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix off": ["ok matrix off"]})
    mcu.matrix_off()
    assert mcu._s.written == ["app matrix off"]


# -- lifecycle --------------------------------------------------------------


def test_context_manager_closes_the_port(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    with mcu as handle:
        assert handle is mcu
        assert mcu._s.is_open
    assert not mcu._s.is_open


def test_close_is_idempotent(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    mcu.close()
    mcu.close()
    assert not mcu._s.is_open


def test_ensure_link_brings_the_link_up(
    monkeypatch: pytest.MonkeyPatch, serial_factory: Any
) -> None:
    import unoq.mcu

    called: list[bool] = []
    monkeypatch.setattr(unoq.mcu, "link_up", lambda: called.append(True))
    serial_factory(replies={})
    MCU(port="/dev/fake", ensure_link=True)
    assert called == [True]


def test_ensure_link_failure_is_not_fatal(
    monkeypatch: pytest.MonkeyPatch, serial_factory: Any
) -> None:
    # A board whose link is already up, or a user without gpiod rights, must
    # still get a usable MCU handle.
    import unoq.mcu

    def boom() -> None:
        raise PermissionError("no gpiod for you")

    monkeypatch.setattr(unoq.mcu, "link_up", boom)
    serial_factory(replies={})
    assert MCU(port="/dev/fake", ensure_link=True) is not None


# -- chunked / non-echoing shells -------------------------------------------


def test_cmd_reassembles_a_reply_that_arrives_in_pieces(mcu_factory: Any) -> None:
    # A real UART delivers a few bytes per read, so the prompt is usually not
    # in the first chunk. cmd() must keep reading until it sees one.
    mcu = mcu_factory({"app status": ["uptime_ms=7"]}, chunk_size=3)
    assert mcu.cmd("app status") == ["uptime_ms=7"]


def test_cmd_handles_a_shell_that_does_not_echo(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=7"]}, echo=False)
    assert mcu.cmd("app status") == ["uptime_ms=7"]
