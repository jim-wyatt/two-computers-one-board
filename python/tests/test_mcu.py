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

from unoq.mcu import (
    JITTER_BIN_LABELS,
    JITTER_BINS,
    MCU,
    JitterHist,
    JitterStat,
    MCUError,
    ShellTimeout,
    TempLogStat,
    TempSample,
    _clean,
)

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


HEART = [
    "0000000000000",
    "0007700077000",
    "0077770777700",
    "0077777777700",
    "0007777777000",
    "0000777770000",
    "0000077700000",
    "0000007000000",
]
HEART_CMD = "app matrix frame " + " ".join(HEART)
HEART_LIT = sum(c != "0" for row in HEART for c in row)


def test_matrix_frame_sends_the_rows_in_one_command(mcu_factory: Any) -> None:
    mcu = mcu_factory({HEART_CMD: [f"ok frame lit={HEART_LIT}"]})
    mcu.matrix_frame(HEART)
    assert mcu._s.written == [HEART_CMD]


def test_matrix_frame_takes_any_sequence_of_rows(mcu_factory: Any) -> None:
    dark = ("0" * 13,) * 8
    mcu = mcu_factory({"app matrix frame " + " ".join(dark): ["ok frame lit=0"]})
    mcu.matrix_frame(dark)


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        (HEART[:7], r"need 8 rows, got 7"),
        ([*HEART, HEART[0]], r"need 8 rows, got 9"),
        ([*HEART[:3], "000000000000", *HEART[4:]], r"row 3: '000000000000' is not 13"),
        ([*HEART[:3], "00000000000000", *HEART[4:]], r"row 3"),
        (["0000000000008", *HEART[1:]], r"row 0: .* digits 0\.\.7"),
        ([*HEART[:7], "000000 000000"], r"row 7"),
        ([*HEART[:7], "000000000000\u0663"], r"row 7"),  # ARABIC-INDIC DIGIT THREE
        ([*HEART[:7], 1234567012345], r"row 7"),
        ("".join(HEART), r"one string"),
    ],
)
def test_matrix_frame_refuses_a_bad_frame_without_sending_it(
    mcu_factory: Any, rows: Any, message: str
) -> None:
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match=message):
        mcu.matrix_frame(rows)
    assert mcu._s.written == []


def test_matrix_frame_raises_when_the_mcu_refuses_it(mcu_factory: Any) -> None:
    mcu = mcu_factory({HEART_CMD: ["Error: row 2: '0' is not 13 digits 0..7"]})
    with pytest.raises(MCUError, match="row 2"):
        mcu.matrix_frame(HEART)


@pytest.mark.parametrize("reply", [[], ["ok"], ["ok px row=0 col=0 level=7"]])
def test_matrix_frame_raises_on_an_unparsable_reply(mcu_factory: Any, reply: list[str]) -> None:
    mcu = mcu_factory({HEART_CMD: reply})
    with pytest.raises(MCUError, match="could not parse matrix frame"):
        mcu.matrix_frame(HEART)


def test_matrix_frame_raises_when_the_mcu_lit_something_else(mcu_factory: Any) -> None:
    # A digit changed on the wire into another valid digit is still a frame
    # the firmware accepts. When it turns a lit LED dark, the count says so.
    mcu = mcu_factory({HEART_CMD: [f"ok frame lit={HEART_LIT - 1}"]})
    with pytest.raises(MCUError, match=f"lighting {HEART_LIT} LEDs"):
        mcu.matrix_frame(HEART)


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


# -- send: a line nobody waits for --------------------------------------------


def late_replies(mcu: MCU) -> None:
    """Make the fake behave like a UART whose replies are still arriving.

    The plain fake replaces its pending bytes on every write and empties them
    on every flush, so a reply could never outlive the command that asked for
    it. On the board it can: the echo and prompt of a line sent blind are
    still on the wire when the next command flushes the input. Here nothing
    is ever flushed, and each reply queues behind the last.
    """
    fake = mcu._s
    render = fake._render

    def write(data: bytes) -> int:
        command = data.decode().strip()
        fake.written.append(command)
        fake._pending += render(command).encode()
        return len(data)

    fake.write = write
    fake.reset_input_buffer = lambda: None


def test_send_writes_the_line_and_reads_nothing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter tick": []})
    before = mcu._s.reset_count
    mcu.send("app jitter tick")
    assert mcu._s.written == ["app jitter tick"]
    # The input is emptied before the write, so replies nobody reads cannot
    # pile up until the kernel throttles the MCU.
    assert mcu._s.reset_count == before + 1
    assert mcu._s._pending, "the reply is left where it is"


@pytest.mark.parametrize("chunk_size", [None, 1, 7])
def test_after_send_cmd_reads_past_the_stale_prompts_to_its_own_reply(
    mcu_factory: Any, chunk_size: int | None
) -> None:
    """One byte at a time, the buffer ends at a tick's prompt long before the
    stat reply begins. Without the echo check, cmd() stopped there and
    returned nothing - or the tick's echo, as though it were the reply."""
    mcu = mcu_factory({"app status": ["uptime_ms=7"]}, chunk_size=chunk_size)
    late_replies(mcu)
    for _ in range(3):
        mcu.send("app jitter tick")
    assert mcu.cmd("app status") == ["uptime_ms=7"]
    # One command later the reply is read the ordinary way again.
    assert mcu._unread is False
    assert mcu.cmd("app status") == ["uptime_ms=7"]


def test_after_send_an_error_after_the_echo_still_raises(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter tick": ["Error: not armed"], "x": ["Error: boom"]})
    late_replies(mcu)
    mcu.send("app jitter tick")
    # The tick's own error is before x's echo: not x's to raise.
    with pytest.raises(MCUError, match="boom"):
        mcu.cmd("x")


def test_after_send_an_empty_reply_is_empty(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter tick": ["stale"], "x": []})
    late_replies(mcu)
    mcu.send("app jitter tick")
    assert mcu.cmd("x") == []


def test_after_send_cmd_times_out_if_its_echo_never_comes(mcu_factory: Any) -> None:
    mcu = mcu_factory({}, echo=False)
    late_replies(mcu)
    mcu.send("app jitter tick")
    with pytest.raises(ShellTimeout):
        mcu.cmd("x", timeout=0.05)


# -- jitter -------------------------------------------------------------------

ZEROS = ",".join(["0"] * 15)


def stat_line(src: str, period_us: int, bins: list[int], lo: int = 0, hi: int = 0) -> str:
    n = sum(bins)
    mean = (lo + hi) // 2 if n else 0
    return (
        f"jitter src={src} period_us={period_us} n={n} min_ns={lo} max_ns={hi} "
        f"mean_ns={mean} bins={','.join(map(str, bins))}"
    )


def test_the_bin_labels_run_from_earliest_to_latest() -> None:
    assert len(JITTER_BIN_LABELS) == JITTER_BINS == 15
    assert JITTER_BIN_LABELS[0] == "<-5000"
    assert JITTER_BIN_LABELS[1] == "-5000..-2000"
    assert JITTER_BIN_LABELS[6] == "-100..-50"
    assert JITTER_BIN_LABELS[7] == "-50..50"
    assert JITTER_BIN_LABELS[8] == "50..100"
    assert JITTER_BIN_LABELS[13] == "2000..5000"
    assert JITTER_BIN_LABELS[14] == ">5000"


def test_jitter_arm_returns_the_period_the_mcu_took(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter arm 10000": ["ok jitter arm period_us=10000"]})
    assert mcu.jitter_arm(10000) == 10000


@pytest.mark.parametrize("period", [99, 10_000_001, -1])
def test_jitter_arm_refuses_a_period_out_of_range_without_sending(
    mcu_factory: Any, period: int
) -> None:
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match="period_us"):
        mcu.jitter_arm(period)
    assert mcu._s.written == []


def test_jitter_arm_raises_on_an_unparsable_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter arm 100": ["ok"]})
    with pytest.raises(MCUError, match="could not parse app jitter arm"):
        mcu.jitter_arm(100)


def test_jitter_arm_raises_on_no_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter arm 100": []})
    with pytest.raises(MCUError, match="could not parse"):
        mcu.jitter_arm(100)


def test_jitter_on_a_firmware_without_it_says_so(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter stat": OLD_FIRMWARE_HELP})
    with pytest.raises(MCUError, match="predates it"):
        mcu.jitter_stat()


def test_jitter_tick_is_sent_blind(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    mcu.jitter_tick()
    assert mcu._s.written == ["app jitter tick"]
    assert mcu._unread is True


def test_jitter_pwm_returns_the_real_period(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter pwm 7000": ["ok jitter pwm hz=7000 period_us=142"]})
    assert mcu.jitter_pwm(7000) == 142


@pytest.mark.parametrize("hz", [15, 10_001, 0])
def test_jitter_pwm_refuses_a_rate_out_of_range_without_sending(mcu_factory: Any, hz: int) -> None:
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match="hz"):
        mcu.jitter_pwm(hz)
    assert mcu._s.written == []


@pytest.mark.parametrize(
    "reply", [[], ["ok"], ["ok jitter pwm hz=99 period_us=10101"]], ids=["none", "junk", "other-hz"]
)
def test_jitter_pwm_raises_on_a_reply_that_is_not_for_it(
    mcu_factory: Any, reply: list[str]
) -> None:
    mcu = mcu_factory({"app jitter pwm 100": reply})
    with pytest.raises(MCUError, match="could not parse app jitter pwm"):
        mcu.jitter_pwm(100)


def test_jitter_stat_reads_both_histograms(mcu_factory: Any) -> None:
    tick = [0, 0, 0, 0, 1, 2, 3, 900, 50, 20, 10, 5, 3, 2, 1]
    pwm = [0] * 7 + [499] + [0] * 7
    mcu = mcu_factory(
        {
            "app jitter stat": [
                stat_line("tick", 10000, tick, -400000, 6100000),
                "jitter src=pwm period_us=10000 n=499 min_ns=-6 max_ns=6 mean_ns=0 bins="
                + ",".join(map(str, pwm)),
            ]
        }
    )
    stat = mcu.jitter_stat()
    assert isinstance(stat, JitterStat)
    assert stat.tick == JitterHist("tick", 10000, 997, -400000, 6100000, 2850000, tuple(tick))
    assert stat.pwm == JitterHist("pwm", 10000, 499, -6, 6, 0, tuple(pwm))


def test_jitter_stat_reads_empty_histograms(mcu_factory: Any) -> None:
    mcu = mcu_factory(
        {"app jitter stat": [stat_line("tick", 0, [0] * 15), stat_line("pwm", 0, [0] * 15)]}
    )
    stat = mcu.jitter_stat()
    assert stat.tick.n == stat.pwm.n == 0
    assert stat.tick.bins == (0,) * 15


@pytest.mark.parametrize(
    "lines",
    [
        [f"jitter src=tick period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins={ZEROS}"],
        [
            f"jitter src=tick period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins={ZEROS}",
            f"jitter src=tick period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins={ZEROS}",
        ],
        [
            f"jitter src=tick period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins={ZEROS}",
            f"jitter src=gps period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins={ZEROS}",
        ],
        [],
    ],
    ids=["pwm-missing", "tick-twice", "unknown-source", "nothing"],
)
def test_jitter_stat_wants_exactly_tick_and_pwm(mcu_factory: Any, lines: list[str]) -> None:
    mcu = mcu_factory({"app jitter stat": lines})
    with pytest.raises(MCUError, match="expected"):
        mcu.jitter_stat()


@pytest.mark.parametrize(
    "line",
    [
        "jitter src=tick period_us=1 n=1 min_ns=0 max_ns=0 mean_ns=0 bins=" + ZEROS,
        "jitter src=tick period_us=1 n=0 min_ns=0 max_ns=0 mean_ns=0 bins=0,0,0",
    ],
    ids=["count-disagrees", "too-few-bins"],
)
def test_jitter_stat_refuses_bins_that_do_not_add_up(mcu_factory: Any, line: str) -> None:
    mcu = mcu_factory({"app jitter stat": [line]})
    with pytest.raises(MCUError, match="do not add up"):
        mcu.jitter_stat()


def test_jitter_stat_raises_on_a_line_it_cannot_read(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter stat": ["jitter src=tick n=lots"]})
    with pytest.raises(MCUError, match="could not parse app jitter stat"):
        mcu.jitter_stat()


def test_jitter_off(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app jitter off": ["ok jitter off"]})
    mcu.jitter_off()
    assert mcu._s.written == ["app jitter off"]


@pytest.mark.parametrize("reply", [[], ["ok"]], ids=["none", "junk"])
def test_jitter_off_raises_on_a_reply_that_is_not_for_it(
    mcu_factory: Any, reply: list[str]
) -> None:
    mcu = mcu_factory({"app jitter off": reply})
    with pytest.raises(MCUError, match="could not parse app jitter off"):
        mcu.jitter_off()


def test_a_whole_run_reads_the_stat_after_the_ticks(mcu_factory: Any) -> None:
    """arm, pwm, ticks sent blind, stat, off: the shape unoq-jitter will have."""
    bins = [0] * 7 + [2] + [0] * 7
    mcu = mcu_factory(
        {
            "app jitter arm 10000": ["ok jitter arm period_us=10000"],
            "app jitter pwm 100": ["ok jitter pwm hz=100 period_us=10000"],
            "app jitter stat": [stat_line("tick", 10000, bins), stat_line("pwm", 10000, bins)],
            "app jitter off": ["ok jitter off"],
        },
        chunk_size=5,
    )
    late_replies(mcu)
    assert mcu.jitter_arm(10000) == 10000
    assert mcu.jitter_pwm(100) == 10000
    for _ in range(3):
        mcu.jitter_tick()
    assert mcu.jitter_stat().tick.n == 2
    mcu.jitter_off()


def test_a_command_longer_than_a_terminal_line_still_finds_its_echo(mcu_factory: Any) -> None:
    # Seen on the board: the shell wraps the echo of `app matrix frame` (about
    # 130 characters) at 80 columns, and the wrap took a space with it.
    rows = ["0000000000770", "0000000007700"] + ["0" * 13] * 6
    command = "app matrix frame " + " ".join(rows)
    mcu = mcu_factory({command: ["ok frame lit=4"]})
    assert mcu.cmd(command) == ["ok frame lit=4"]


def test_a_wrapped_echo_after_send_is_found_too(mcu_factory: Any) -> None:
    command = "app matrix frame " + " ".join(["1" * 13] * 8)
    mcu = mcu_factory({command: ["ok frame lit=104"]})
    mcu._unread = True
    assert mcu.cmd(command) == ["ok frame lit=104"]


def test_a_line_that_only_starts_like_the_echo_is_not_taken_for_it(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["app stat", "uptime_ms=1 flip=0"]}, echo=False)
    assert mcu.cmd("app status") == ["app stat", "uptime_ms=1 flip=0"]


def test_an_echo_cut_short_is_not_an_echo() -> None:
    # Only part of a long echo has arrived: the reply cannot start yet.
    from unoq.mcu import _echo_span

    assert _echo_span(["app matrix frame 0000"], 0, "app matrix frame 0000 1111") is None
    assert _echo_span(["app matrix frame 0000", "1111"], 0, "app matrix frame 0000 1111") == 2
