# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the /sys/devices/system/cpu/cpufreq reader.

Every input here is a sysfs tree written out under tmp_path, never the real
one: which governor the machine running the suite has, and what it is clocked
at this instant, is not a reproducible fixture.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from unoq.cpufreq import Policy, read_policies, read_policy

# policy0 as this board reported it under kernel 7.0.0: one policy for all four
# Cortex-A53 cores, driven by qcom-cpufreq-hw. The values are verbatim,
# trailing spaces included - the kernel really does end the governor list and
# the frequency list with one.
BOARD = {
    "related_cpus": "0 1 2 3",
    "scaling_driver": "qcom-cpufreq-hw",
    "scaling_governor": "schedutil",
    "scaling_available_governors": "ondemand userspace performance schedutil ",
    "scaling_available_frequencies": (
        "300000 614400 864000 1017600 1305600 1420800 1612800 1804800 2016000 "
    ),
    "scaling_min_freq": "300000",
    "scaling_max_freq": "2016000",
    "scaling_cur_freq": "2016000",
}
TIME_IN_STATE = (
    "300000 0\n614400 5028260\n864000 109265\n1017600 68021\n1305600 268812\n"
    "1420800 336111\n1612800 177969\n1804800 99915\n2016000 910855"
)


def add_policy(
    root: Path,
    number: int,
    files: dict[str, str] | None = None,
    time_in_state: str | None = None,
) -> Path:
    """Write one policyN. A file left out of `files` is left out of the tree;
    time_in_state=None leaves out the whole stats directory."""
    policy = root / f"policy{number}"
    policy.mkdir(parents=True)
    # sysfs ends every value with a newline, so the fake does too.
    for name, value in (BOARD if files is None else files).items():
        (policy / name).write_text(f"{value}\n")
    if time_in_state is not None:
        (policy / "stats").mkdir()
        (policy / "stats" / "time_in_state").write_text(f"{time_in_state}\n")
    return policy


def board(tmp_path: Path) -> str:
    add_policy(tmp_path, 0, time_in_state=TIME_IN_STATE)
    # The real directory also holds these: a global boost switch, and on this
    # board a per-governor tunables directory next to the policy.
    (tmp_path / "boost").write_text("0\n")
    return str(tmp_path)


# -- read_policies ----------------------------------------------------------


def test_reads_the_boards_one_policy(tmp_path: Path) -> None:
    [policy] = read_policies(board(tmp_path))
    assert policy == Policy(
        name="policy0",
        cpus=(0, 1, 2, 3),
        driver="qcom-cpufreq-hw",
        governor="schedutil",
        governors=("ondemand", "userspace", "performance", "schedutil"),
        min_khz=300000,
        max_khz=2016000,
        cur_khz=2016000,
        frequencies=(300000, 614400, 864000, 1017600, 1305600, 1420800, 1612800, 1804800, 2016000),
        time_in_state=(
            (300000, 0.0),
            (614400, 50282.6),
            (864000, 1092.65),
            (1017600, 680.21),
            (1305600, 2688.12),
            (1420800, 3361.11),
            (1612800, 1779.69),
            (1804800, 999.15),
            (2016000, 9108.55),
        ),
    )


def test_several_policies_sort_by_number_not_by_name(tmp_path: Path) -> None:
    """A big.LITTLE part has one policy per cluster, numbered by its first
    CPU - policy0 and policy4, say - and as text policy10 sorts before
    policy2. Created out of order so directory order cannot pass it by luck."""
    for number in (10, 2, 0):
        add_policy(tmp_path, number, {**BOARD, "related_cpus": str(number)})
    policies = read_policies(str(tmp_path))
    assert [p.name for p in policies] == ["policy0", "policy2", "policy10"]
    assert [p.cpus for p in policies] == [(0,), (2,), (10,)]


def test_a_missing_root_reads_as_no_policies(tmp_path: Path) -> None:
    """A virtual machine, or a kernel without cpufreq, has nothing to report.
    That is an answer, not an error."""
    assert read_policies(str(tmp_path / "nope")) == []


def test_an_empty_root_reads_as_no_policies(tmp_path: Path) -> None:
    assert read_policies(str(tmp_path)) == []


def test_a_root_that_is_not_a_directory_reads_as_no_policies(tmp_path: Path) -> None:
    path = tmp_path / "cpufreq"
    path.write_text("not a directory\n")
    assert read_policies(str(path)) == []


def test_everything_that_is_not_a_policy_is_ignored(tmp_path: Path) -> None:
    """`policy3` as a plain file is not a policy directory, and the rest do
    not match the name. Each stray is a directory holding a governor, so only
    its name or type is keeping it out."""
    add_policy(tmp_path, 0)
    (tmp_path / "policy3").write_text("stray\n")
    for stray in ("boost", "schedutil", "policy", "policy1.bak", "old_policy2"):
        (tmp_path / stray).mkdir()
        (tmp_path / stray / "scaling_governor").write_text("performance\n")
    assert [p.name for p in read_policies(str(tmp_path))] == ["policy0"]


def test_the_default_root_is_the_real_sysfs_path() -> None:
    """Called with no argument it reads the live machine. The values are not
    reproducible, so this only checks the shape - including on a machine with
    no cpufreq at all."""
    for policy in read_policies():
        assert policy.name.startswith("policy")
        assert all(isinstance(cpu, int) for cpu in policy.cpus)


# -- one policy, file by file -----------------------------------------------


def test_no_stats_directory_reads_as_no_time_in_state(tmp_path: Path) -> None:
    """A kernel built without CONFIG_CPU_FREQ_STAT has no stats directory.
    Everything else is still there and still read."""
    policy = read_policy(add_policy(tmp_path, 0))
    assert policy.time_in_state == ()
    assert policy.governor == "schedutil"


def test_a_policy_with_no_files_reads_as_all_unknown(tmp_path: Path) -> None:
    """Drivers differ in which files they offer - intel_pstate, for one, has
    no list of available frequencies. A missing file costs only its field."""
    assert read_policy(add_policy(tmp_path, 0, {})) == Policy(
        name="policy0",
        cpus=(),
        driver=None,
        governor=None,
        governors=(),
        min_khz=None,
        max_khz=None,
        cur_khz=None,
        frequencies=(),
        time_in_state=(),
    )


def test_a_file_that_refuses_to_read_costs_only_its_field(tmp_path: Path) -> None:
    """A directory where a file should be fails the read with an OSError, the
    way a file the kernel refuses would, without needing a kernel."""
    policy = add_policy(tmp_path, 0)
    (policy / "scaling_cur_freq").unlink()
    (policy / "scaling_cur_freq").mkdir()
    result = read_policy(policy)
    assert result.cur_khz is None
    assert result.max_khz == 2016000


def test_an_empty_governor_reads_as_none(tmp_path: Path) -> None:
    files = {**BOARD, "scaling_governor": "", "scaling_available_governors": ""}
    policy = read_policy(add_policy(tmp_path, 0, files))
    assert policy.governor is None
    assert policy.governors == ()


@pytest.mark.parametrize("garbage", ["", "fast", "2016.0", "0x1e"])
def test_a_frequency_that_is_not_an_integer_reads_as_none(tmp_path: Path, garbage: str) -> None:
    """Whatever this is, it is not kHz. A guessed number would be worse than
    a missing one."""
    policy = read_policy(add_policy(tmp_path, 0, {**BOARD, "scaling_cur_freq": garbage}))
    assert policy.cur_khz is None


def test_a_list_with_a_bad_entry_reads_as_empty(tmp_path: Path) -> None:
    """All or nothing: a frequency list with a hole in it would pass for a
    complete list of fewer frequencies."""
    files = {**BOARD, "scaling_available_frequencies": "300000 fast 2016000"}
    assert read_policy(add_policy(tmp_path, 0, files)).frequencies == ()


def test_frequencies_are_sorted_lowest_first(tmp_path: Path) -> None:
    files = {**BOARD, "scaling_available_frequencies": "2016000 300000 864000"}
    assert read_policy(add_policy(tmp_path, 0, files)).frequencies == (300000, 864000, 2016000)


def test_time_in_state_is_sorted_lowest_first(tmp_path: Path) -> None:
    policy = add_policy(tmp_path, 0, time_in_state="2016000 50\n300000 100")
    assert read_policy(policy).time_in_state == ((300000, 1.0), (2016000, 0.5))


@pytest.mark.parametrize("garbage", ["300000", "300000 1 2", "300000 lots", "300000 1.5"])
def test_a_time_in_state_with_a_bad_line_reads_as_empty(tmp_path: Path, garbage: str) -> None:
    policy = add_policy(tmp_path, 0, time_in_state=f"2016000 50\n{garbage}")
    assert read_policy(policy).time_in_state == ()


def test_a_stats_directory_with_no_time_in_state_reads_as_empty(tmp_path: Path) -> None:
    policy = add_policy(tmp_path, 0)
    (policy / "stats").mkdir()
    assert read_policy(policy).time_in_state == ()
