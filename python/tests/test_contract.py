# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""The MPU<->MCU contract, checked against the firmware's own header.

unoq/mcu.py has to know the panel's limits, and there is no way to import a C
macro into Python - so those numbers exist twice. This file is what makes the
duplicate safe: it parses mcu/app/include/app_proto.h and fails if the two
copies disagree. Change the firmware's geometry and this test breaks before the
board does.

The same reasoning is written up in app_proto.h itself, which explains why the
C-side definitions were pulled out of main.c and into a shared header.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pytest
from conftest import PROMPT

from unoq import mcu

MCU_APP = Path(__file__).resolve().parents[2] / "mcu" / "app"
HEADER = MCU_APP / "include" / "app_proto.h"
PRJ_CONF = MCU_APP / "prj.conf"
GUARD = MCU_APP / "include" / "guard.h"

# `#define NAME value` - object-like macros only. The function-like ones in the
# header (the app_*_valid inline helpers are C functions, not macros) are not
# constants and have nothing to compare against.
_DEFINE = re.compile(r"^#define\s+(\w+)\s+(.+?)\s*$", re.MULTILINE)
# Guards how much of a #define body we are willing to hand to eval(): integers,
# arithmetic, parentheses and names we have already resolved.
_ARITHMETIC = re.compile(r"^[\w\s()+\-*/]+$")


def macros() -> dict[str, int]:
    """Every integer #define in app_proto.h, with expressions resolved.

    APP_BARS_MAX is defined in terms of APP_MATRIX_COLS, so a plain int() will
    not do; values are substituted and evaluated in definition order.
    """
    if not HEADER.exists():  # pragma: no cover - only if the tree is cut up
        pytest.skip(f"firmware header not found at {HEADER}")

    found: dict[str, int] = {}
    for name, body in _DEFINE.findall(HEADER.read_text()):
        body = body.split("/*")[0].strip()
        if not body or not _ARITHMETIC.match(body):
            continue  # a string, a format specifier, or a multi-line macro
        expanded = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(found.get(m.group(), "?")), body)
        try:
            # eval() on a string already screened by _ARITHMETIC: digits,
            # operators and names that resolved to digits, nothing else.
            found[name] = int(eval(expanded))
        except (SyntaxError, NameError, ValueError, ZeroDivisionError):
            continue
    return found


@pytest.fixture(scope="module")
def firmware() -> dict[str, int]:
    values = macros()
    assert values, f"parsed no constants out of {HEADER} - has the format changed?"
    return values


@pytest.mark.parametrize(
    ("python_name", "c_name"),
    [
        ("BARS_MAX", "APP_BARS_MAX"),
        ("BARS_PCT_MAX", "APP_BARS_PCT_MAX"),
        ("MATRIX_ROWS", "APP_MATRIX_ROWS"),
        ("MATRIX_COLS", "APP_MATRIX_COLS"),
        ("MATRIX_MAX_LEVEL", "APP_MATRIX_MAX_LEVEL"),
    ],
)
def test_python_constants_match_the_firmware(
    firmware: dict[str, int], python_name: str, c_name: str
) -> None:
    assert c_name in firmware, f"{c_name} is gone from app_proto.h"
    assert getattr(mcu, python_name) == firmware[c_name], (
        f"unoq.mcu.{python_name} is {getattr(mcu, python_name)} but the firmware "
        f"says {c_name} is {firmware[c_name]} - update python/unoq/mcu.py"
    )


def test_the_parser_resolves_expressions_not_just_literals(firmware: dict[str, int]) -> None:
    """APP_BARS_MAX is `((APP_MATRIX_COLS + 1) / 2)`. If the parser silently
    skipped expressions, the check above would pass by never running."""
    assert firmware["APP_BARS_MAX"] == (firmware["APP_MATRIX_COLS"] + 1) // 2


def test_led_count_is_the_grid(firmware: dict[str, int]) -> None:
    assert firmware["APP_MATRIX_LEDS"] == firmware["APP_MATRIX_ROWS"] * firmware["APP_MATRIX_COLS"]


# -- the shell prompt -------------------------------------------------------
#
# The prompt is the end-of-response marker for every command MCU.cmd() sends,
# so it is as much a part of the contract as the status line is. It lives in
# Kconfig on one side and in a regex plus the test fake on the other; these
# pin all three together.


def firmware_prompt() -> str:
    """CONFIG_SHELL_PROMPT_UART from prj.conf, unquoted."""
    if not PRJ_CONF.exists():  # pragma: no cover - only if the tree is cut up
        pytest.skip(f"firmware config not found at {PRJ_CONF}")
    m = re.search(r'^CONFIG_SHELL_PROMPT_UART="(.*)"\s*$', PRJ_CONF.read_text(), re.MULTILINE)
    assert m, f"CONFIG_SHELL_PROMPT_UART is gone from {PRJ_CONF}"
    return m.group(1)


def test_the_fake_shell_uses_the_prompt_the_firmware_prints() -> None:
    """The fake had "uno_q:~$ " while the firmware printed "unoq:~$ ". Both
    happen to satisfy the regex, so nothing failed - which is exactly why it
    went unnoticed. A fake imitating a prompt no firmware sends proves less
    than it appears to."""
    assert firmware_prompt() == PROMPT, (
        f"tests/conftest.py PROMPT is {PROMPT!r} but the firmware prints "
        f"{firmware_prompt()!r} - update conftest.py"
    )


def test_the_parser_recognizes_the_real_prompt() -> None:
    """Both places mcu.py looks for it: _clean() drops the prompt line, and
    cmd() uses it to decide a response has finished arriving."""
    assert mcu._PROMPT.match(firmware_prompt().strip())
    assert re.search(r":~\$\s*$", firmware_prompt())


# -- the temp line ----------------------------------------------------------
#
# `app temp` answers with one of two printf formats from the header, and mcu.py
# matches them with two regexes. Neither side can import the other's, so the
# regex each format *implies* is rebuilt here and compared with the one in use.


def firmware_format(name: str) -> str:
    """A string #define from app_proto.h, unquoted."""
    if not HEADER.exists():  # pragma: no cover - only if the tree is cut up
        pytest.skip(f"firmware header not found at {HEADER}")
    m = re.search(rf'^#define\s+{name}\s+"(.*)"\s*$', HEADER.read_text(), re.MULTILINE)
    assert m, f"{name} is gone from app_proto.h"
    return m.group(1)


def implied_regex(fmt: str) -> str:
    """The anchored regex a printf format made of literals, %d, %lld and %u implies.

    Signed conversions take an optional minus and unsigned ones do not, so a
    Python regex that accepted a negative sequence number would not match.
    re.escape() escapes spaces, which the regexes in mcu.py write plainly.
    """
    body = re.escape(fmt).replace("\\ ", " ")
    for spec, group in (("%lld", r"(-?\d+)"), ("%d", r"(-?\d+)"), ("%u", r"(\d+)")):
        body = body.replace(spec, group)
    return "^" + body + "$"


@pytest.mark.parametrize(
    ("python_name", "c_name"),
    [("_TEMP", "APP_TEMP_FMT"), ("_TEMP_ERR", "APP_TEMP_ERR_FMT")],
)
def test_temp_regexes_are_the_ones_the_firmware_formats_imply(
    python_name: str, c_name: str
) -> None:
    fmt = firmware_format(c_name)
    assert getattr(mcu, python_name).pattern == implied_regex(fmt), (
        f"unoq.mcu.{python_name} no longer matches {c_name} ({fmt!r}) - "
        f"a change to app_proto.h is a protocol change; update python/unoq/mcu.py"
    )


@pytest.mark.parametrize("millidegrees", [31250, 0, -1, -40000, 125000])
def test_a_line_the_firmware_would_print_parses_back(millidegrees: int) -> None:
    """The same samples mcu/tests/link_protocol round-trips in C. %d means the
    same thing to Python's % operator, so this renders the real format."""
    line = firmware_format("APP_TEMP_FMT") % millidegrees
    m = mcu._TEMP.match(line)
    assert m, f"{line!r} is what the firmware prints and mcu.py cannot read it"
    assert int(m.group(1)) == millidegrees


def test_the_failure_line_is_not_a_reading() -> None:
    line = firmware_format("APP_TEMP_ERR_FMT") % -19
    assert mcu._TEMP_ERR.match(line)
    assert not mcu._TEMP.match(line)


# -- the temperature log -----------------------------------------------------
#
# `app temp log` and `app temp log stat` print five formats between them, each
# matched in mcu.py by a regex of its own. Pinned the same way as the temp line.


@pytest.mark.parametrize(
    ("python_name", "c_name"),
    [
        ("_TEMPLOG", "APP_TEMPLOG_FMT"),
        ("_TEMPLOG_ERR", "APP_TEMPLOG_ERR_FMT"),
        ("_TEMPLOG_GAP", "APP_TEMPLOG_GAP_FMT"),
        ("_TEMPLOG_END", "APP_TEMPLOG_END_FMT"),
        ("_TEMPLOG_STAT", "APP_TEMPLOG_STAT_FMT"),
    ],
)
def test_temp_log_regexes_are_the_ones_the_firmware_formats_imply(
    python_name: str, c_name: str
) -> None:
    fmt = firmware_format(c_name)
    assert getattr(mcu, python_name).pattern == implied_regex(fmt), (
        f"unoq.mcu.{python_name} no longer matches {c_name} ({fmt!r}) - "
        f"a change to app_proto.h is a protocol change; update python/unoq/mcu.py"
    )


def render(fmt: str, *values: int) -> str:
    """printf a format from the header. Python's % takes one length modifier
    and ignores it, but not two, so %lld becomes the %d it means here."""
    return fmt.replace("%lld", "%d") % values


def test_a_temp_log_reply_the_firmware_would_print_parses_back(mcu_factory: Any) -> None:
    """Every line of a reply rendered through the header's own formats, with
    the values mcu/tests/templog renders in C, read back by MCU.temp_log()."""
    reply = [
        render(firmware_format("APP_TEMPLOG_GAP_FMT"), 5, 10),
        render(firmware_format("APP_TEMPLOG_FMT"), 11, 123456789012, -40000),
        render(firmware_format("APP_TEMPLOG_ERR_FMT"), 12, 123456790012, -19),
        render(firmware_format("APP_TEMPLOG_END_FMT"), 12, 0),
    ]
    board = mcu_factory({"app temp log 4": reply})
    assert board.temp_log(4) == [
        mcu.TempSample(11, 123456789012, -40.0),
        mcu.TempSample(12, 123456790012, None, -19),
    ]


def test_a_temp_log_stat_line_the_firmware_would_print_parses_back(mcu_factory: Any) -> None:
    line = render(firmware_format("APP_TEMPLOG_STAT_FMT"), 610, 600, 600, 10, 1000)
    board = mcu_factory({"app temp log stat": [line]})
    assert board.temp_log_stat() == mcu.TempLogStat(610, 600, 600, 10, 1000)


def test_a_logged_sample_is_never_read_as_a_temp_reply() -> None:
    """die_temp() and temp_log() share the temp_mc= key. Anchoring keeps a log
    line from passing for an `app temp` reply, and the other way round."""
    line = render(firmware_format("APP_TEMPLOG_FMT"), 1, 1000, 25000)
    assert not mcu._TEMP.match(line)
    assert not mcu._TEMPLOG.match(firmware_format("APP_TEMP_FMT") % 25000)


# -- the reset cause ---------------------------------------------------------
#
# `app reset` prints APP_RESET_FMT with the names from guard_reset_table in
# guard.h. The format and the table are both read here, so a renamed cause or
# a reordered table fails before a reset is misreported.


def firmware_reset_names() -> list[str]:
    """The names in guard_reset_table, in table order."""
    text = GUARD.read_text()
    table = re.search(r"guard_reset_table\[\] = \{(.*?)\n\};", text, re.DOTALL)
    assert table, f"guard_reset_table is gone from {GUARD}"
    return re.findall(r'\{RESET_\w+, "(\w+)"\}', table.group(1))


def firmware_string(path: Path, name: str) -> str:
    m = re.search(rf'^#define\s+{name}\s+"(.*)"\s*$', path.read_text(), re.MULTILINE)
    assert m, f"{name} is gone from {path.name}"
    return m.group(1)


def test_the_reset_line_is_one_key_and_a_string() -> None:
    assert firmware_format("APP_RESET_FMT") == "reset=%s"


def test_python_knows_the_firmware_reset_names_in_order() -> None:
    names = firmware_reset_names()
    assert len(names) >= 17, names
    assert tuple(names) == mcu.RESET_CAUSES, (
        "unoq.mcu.RESET_CAUSES no longer matches guard_reset_table in guard.h"
    )
    assert firmware_string(GUARD, "GUARD_RESET_NONE") == mcu.RESET_NONE
    assert firmware_string(GUARD, "GUARD_RESET_UNKNOWN") == mcu.RESET_UNKNOWN


@pytest.mark.parametrize(
    "causes",
    [["watchdog", "pin"], ["software", "pin"], ["pin"], ["unknown"], ["watchdog", "unknown"]],
)
def test_a_reset_line_the_firmware_would_print_parses_back(
    mcu_factory: Any, causes: list[str]
) -> None:
    line = firmware_format("APP_RESET_FMT") % ",".join(causes)
    assert mcu_factory({"app reset": [line]}).reset_cause() == causes


def test_every_name_the_firmware_can_print_parses(mcu_factory: Any) -> None:
    every = [*firmware_reset_names(), firmware_string(GUARD, "GUARD_RESET_UNKNOWN")]
    line = firmware_format("APP_RESET_FMT") % ",".join(every)
    assert mcu_factory({"app reset": [line]}).reset_cause() == every


def test_no_cause_is_an_empty_list(mcu_factory: Any) -> None:
    line = firmware_format("APP_RESET_FMT") % firmware_string(GUARD, "GUARD_RESET_NONE")
    assert mcu_factory({"app reset": [line]}).reset_cause() == []


def test_the_firmware_marks_a_refusal_the_way_python_looks_for_it() -> None:
    """A refused command has to look like one from both ends.

    Zephyr's shell_error() only colors a line, and the color is stripped
    before MCU.cmd() reads it. The handlers used to print a bare message, so a
    refused command came back as an ordinary reply and nothing was raised. The
    prefix is now a macro the handlers share, and this pins it to the one
    Python tests for.
    """
    match = re.search(r'^#define\s+APP_ERR\s+"([^"]*)"', HEADER.read_text(), re.MULTILINE)
    assert match, "APP_ERR is not defined in app_proto.h"
    assert match.group(1).rstrip() == mcu.ERROR_PREFIX
    assert match.group(1).endswith(" "), "the message would run straight on from the prefix"


def test_every_refusal_in_the_firmware_uses_the_prefix() -> None:
    """One handler printing a bare shell_error() is all it takes to bring it back."""
    source = (MCU_APP / "src" / "main.c").read_text()
    calls = re.findall(r"shell_error\(sh,\s*([A-Z_]+|\")", source)
    assert calls, "no shell_error calls found - has main.c moved?"
    # APP_TEMP_ERR_FMT is the one exception: a keyed line of its own, which
    # MCU.die_temp() reads for the errno inside it.
    assert set(calls) <= {"APP_ERR", "APP_TEMP_ERR_FMT"}, calls
