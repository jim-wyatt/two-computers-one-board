<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Knowing it works

Embedded development has a bad habit: you change something, flash it, look at
the board, and decide from the LEDs whether it worked. That is a test — a slow,
unreliable, unrepeatable one that only you can run, only once, and only with the
hardware in front of you.

This chapter is about the other kind. Not because testing is virtuous, but for a
specific and selfish reason: **a board is a terrible place to find out you were
wrong.** Flashing takes tens of seconds, a bad image can require a physical
recovery, and half the failures produce no output at all. Anything you can find
before the wire is worth finding there.

## The gates

Everything in this project is checked by one command, which is also exactly what
runs in CI:

```bash
tools/check.sh                # everything
tools/check.sh --fast         # skip the two slow gates (see below)
tools/check.sh --fix          # reformat in place, then check
tools/check.sh docs           # one area
```

`--fast` leaves out two gates: the firmware tests (about 70 seconds of Zephyr
build) and the check that draws every diagram in a headless browser (about a
minute). A `--fast` run that passes ends like this:

```
--- summary ---
  PASS  ruff lint
  PASS  ruff format
  PASS  mypy (strict)
  PASS  ruff lint (scripts)
  PASS  ruff format (scripts)
  PASS  mypy (scripts)
  PASS  pytest + coverage
  PASS  shellcheck
  PASS  shfmt
  PASS  bats (shell behavior)
  PASS  units and udev rules (systemd)
  PASS  zephyr version pin
  PASS  lock files cover the dependencies
  PASS  clang-format
  PASS  spelling (en_US)
  PASS  docs (zensical --strict)
  PASS  diagram assets (offline)
  PASS  settings page matches the code
  PASS  site inputs are watched
  PASS  actionlint

All 20 gates passed.
```

What each one looks for:

| Gate | What it catches |
|---|---|
| `ruff lint`, `ruff format` | Python mistakes, and Python layout |
| `mypy (strict)` | Python type errors |
| `ruff lint (scripts)`, `ruff format (scripts)`, `mypy (scripts)` | The same three, for the Python that is not the package: the docs build's hooks, the diagram check, the signing helper |
| `pytest + coverage` | Python behavior, with every branch run by a test |
| `shellcheck`, `shfmt` | shell mistakes, and shell layout |
| `bats (shell behavior)` | what the shell scripts do, with no board involved |
| `units and udev rules (systemd)` | a unit file or udev rule systemd would reject |
| `zephyr version pin` | the two places the Zephyr version is written disagreeing |
| `lock files cover the dependencies` | a Python package installed at a version no lock file names |
| `clang-format` | C layout |
| `spelling (en_US)` | a misspelling, or British spelling, in the project's own files |
| `docs (zensical --strict)` | a documentation link that does not resolve |
| `diagram assets (offline)` | a diagram that would need the internet to draw |
| `settings page matches the code` | a setting the code reads and the documentation omits |
| `site inputs are watched` | a page embedding a file whose changes would not republish the site |
| `actionlint` | mistakes in the CI definition itself |

A full run adds `diagrams (headless render)` and `ztest (native_sim)`.
[Working on this project](../reference/development.md#the-quality-gates) has the
reference version of this table, and how to install the tools.

Three things about that list are deliberate and worth stealing.

**Every gate runs even when an earlier one fails.** One pass shows you all the
work rather than the first thing to break. Stopping at the first failure feels
tidier and wastes your time.

**A missing tool is a failure, not a skip.** An early version of this script
reported "All 2 gates passed" on a machine with no `mypy` and no `pytest`,
having type-checked nothing and run no tests at all. A gate that silently does
nothing is worse than no gate, because it produces confidence.

**Formatting is a gate, not a suggestion.** Not because layout matters, but
because arguing about it in review is expensive and a diff full of whitespace
hides the change that matters.

> [!WARNING]
> Formatters are a real source of "works here, fails in CI". This project had
> that bug: two versions of `clang-format` disagreed about one `enum` in
> `status_leds.c`, so the gate passed on the board and failed on the runner.
> The fix was a pin. `python/pyproject.toml` now names one exact version,
> `tools/check.sh` uses only the copy in the project's venv, never one that
> happens to be on `PATH`, and it fails if the version it finds is not the
> pinned one. If your formatter is not version-pinned, it is not a gate — it is
> a coin toss with extra steps.

## Testing firmware without firmware

The MCU code is C, running on a Cortex-M33, driving hardware. It also runs on
your laptop.

Zephyr can build for a target called `native_sim`, which compiles the *same
source* — the kernel, your application, the logic — as an ordinary program for
the host machine. Test it there and you get results in seconds instead of a
flash cycle, on any machine, with a debugger that works properly.

```bash
mcu/ztest.sh          # what `tools/check.sh mcu` runs
```

This project tests two things that way:

- **`bars/`** — the rasterizer: given four CPU percentages, which of the 104
  pixels light up, and at what brightness. Pure arithmetic, no hardware, and
  exactly the kind of code that is embarrassing to get wrong.
- **`link_protocol/`** — framing and parsing of the messages coming from Linux.
- **`status_leds/`** — what LEDs 3 and 4 show, and in what rhythm, for each
  state the firmware can be in.

What it *cannot* test is the part that touches registers: the charlieplexing
driver writes `MODER` and `BSRR` directly, and there is no such register on a
laptop. That is the honest boundary. The rule this project follows is to split
code so the interesting logic sits on the testable side of it, and the untestable
part is as small and as dumb as possible.

```mermaid
flowchart TB
  A["CPU percentages"] --> B["bars.c<br/><small>rasterizer</small>"]
  B --> C["104 brightness values"]
  C --> D["matrix.c<br/><small>registers, interrupt handler</small>"]
  D --> E["the panel"]
  B -.-> T1["tested without the chip<br/>(native_sim)"]
  D -.-> T2["only testable<br/>on the board"]
```

That is the design decision, drawn: the boundary between the two boxes exists
*so that* the left one can be tested.

## Testing Linux-side code without a board

The Python suite is over a hundred tests and touches no hardware at all. There
is no serial port, no GPIO chip and no MCU involved; every one of them runs
against a fake.

That sounds like cheating and is not. What is being tested is the code this
project wrote — does it frame the message correctly, does it handle a short
read, does it recover when the port disappears mid-conversation. Testing that
`pyserial` can open a port tests `pyserial`.

The tests that genuinely need a board exist and are marked:

```python
@pytest.mark.hardware
```

They are **deselected by default** (`-m "not hardware"`), so the suite is
runnable on a laptop, in CI, and on a board whose serial port is currently held
by the demo. Opt in when the hardware is there, with the serial port free:

```bash
sudo systemctl stop unoq-cpu-bars
cd ~/two-computers-one-board/python
hpy -m pytest -m hardware --no-cov
sudo systemctl start unoq-cpu-bars
```

`--no-cov` is needed because the project's pytest settings fail any run that
covers less than 100% of the code, and a run of only the hardware tests covers
far less than that.

## Testing shell, which is where the bugs actually were

Here is an uncomfortable measurement of this project, taken before it had any
shell tests. The numbers have moved since; the shape has not:

| | lines then | checked by, then |
|---|---:|---|
| **shell** (40 scripts) | **5,256** | `shellcheck` + `shfmt` |
| Python | 807 | 104 tests, 100% of branches |
| C | 965 | ztest on `native_sim` |

The largest component by a factor of five had **no behavioral tests at all**.
And nearly every finding in
[the log](../reference/clean-board-findings.md) was in shell or in a `systemd`
unit — hardly any were in the Python or the C that all the testing effort went
into.

That is a very common shape, and it is worth recognizing in your own projects:
**the tested part is usually the part that was easy to test**, not the part most
likely to hurt you.

### The trick that made it possible

The obvious fix is to split every script into a "decide" half and a "do" half,
and test the first. That is a large change to scripts that currently work, made
*before* there are any tests to catch it going wrong — the wrong order.

But these scripts already have a seam, because **everything they actually do is
another program**: `ip`, `nmcli`, `systemctl`, `logger`. Put a directory of fake
versions at the front of `PATH` and the real script runs, unmodified, while
nothing reaches the board. What you assert on is the command line it *would*
have used.

```bash
stub_body ip <<'SH'
case "$1 $2" in "link show") exit 1 ;; esac   # pretend the bridge has gone
exit 0
SH

run usb/usb-route.sh add 192.168.137.1
[ "$status" -eq 0 ]
! ran_like 'ip route'      # it noticed, and did nothing
```

The runner is [bats](https://github.com/bats-core/bats-core), which is itself
shell.

### Write the bug down as a test

The first two suites exist because two scripts had already failed in ways that
were expensive:

- **The bind guard counted wrong.** At the time, `udev` triggered the bind unit
  three times on a perfectly healthy plug-in: once for the controller and once
  for each of the two network interfaces the gadget then had. Counting
  invocations reached the limit of 3 during the first *successful* plug-in and
  refused to bind ever again — a guard causing exactly the outage it exists to
  prevent. (The gadget has one network interface now, so it is two triggers,
  and the guard counts boots rather than invocations either way.)
- **The USB route metric was 500**, which beat wifi's 600, so plugging the board
  into a computer silently handed that computer the default route. SSH survived,
  so nothing looked broken, while `apt` and `git` simply stopped.

Neither is the kind of thing you would think to test in advance. Both are
obvious once they have happened, and a test is how you make sure they happen
only once.

> [!TIP]
> A suite that passes the first time you run it may be asserting nothing. Break
> the code on purpose and check the *right* test goes red. Both of these were
> mutation-tested against the two bugs above before being committed — reversing
> the guard's same-boot check turns exactly one test red, and it is the one
> named after the bug.

## The 100% that is not what it looks like

Coverage is enforced at 100%, including branches, and the build fails below it.
That number is easy to misread, so, plainly:

**Coverage measures which lines ran. It says nothing about whether the assertion
was any good.** A test that calls every function and asserts nothing scores
100%.

It is enforced anyway, for one narrow reason: at 100%, *any* drop is a signal.
New code without a test is visible immediately, in the diff, without anyone
having to notice. At 87% the number drifts and nobody can tell the difference
between 87% and 86%. The threshold is not a claim about quality — it is a
ratchet that makes one specific kind of omission impossible to miss.

## Where the gates run

```mermaid
flowchart TD
  A["you type: git commit"] --> B["pre-commit hook<br/><small>check.sh --fast</small>"]
  B -->|passes| C["commit lands"]
  C --> D["git push"]
  D --> E["GitHub Actions<br/><small>checks · changes · firmware</small>"]
  F["you, before pushing:<br/>check.sh<br/><small>+ the MCU suite</small>"] -.-> D
```

The hook runs the fast gates on every commit; ~70 seconds of Zephyr build and a
minute of browser are too slow to sit in front of one. CI runs the same script —
that matters, because a green CI then means the same thing as a clean local run
rather than something adjacent to it.

CI splits it into four jobs, and the shape is worth copying:

| job | time | what it is for |
|---|---|---|
| `checks` | ~30 s | lint, types, tests, coverage, docs |
| `changes` | ~2 s | does this change touch anything the firmware, or a diagram, is built from? |
| `diagrams` | ~1 min | draw every diagram in a headless browser; only when a diagram's inputs changed |
| `firmware` | ~5 min | cross-compile for the Cortex-M33, sign, run the MCU suites |

The expensive one is **gated twice**. It `needs: checks`, so thirty seconds of
linting decides whether five minutes of Zephyr download begins at all; and it is
skipped entirely when `changes` says nothing under `mcu/` moved. Most changes to
this repository are documentation, and none of those can affect a Cortex-M33
binary.

That gating proved itself on its first run: a workflow with a broken action
reference failed `checks` in two seconds, and `firmware` never started.

> [!WARNING]
> A skipped job reports as **skipped**, not **success**. If `firmware` were ever
> made a required check for merging, a documentation-only change would sit
> unmergeable forever. Require the job that always runs.

> [!NOTE]
> Until recently the `firmware` job did not exist, and **a change that broke the
> firmware build got a green tick** — nothing outside the board ever compiled
> it. That is the failure mode to watch for in any CI setup: not a test that
> fails, but a thing nobody checks that everyone assumes is checked.

One gap remains, and naming it is deliberate — a test suite you have oversold is
worse than a small one you have described accurately:

- **CI runs mostly on x86_64; the board is aarch64.** The fresh-install job runs
  on both, and for the Python that is enough: the tests use fakes and the
  libraries ship wheels for both. The firmware
  cross-compiles, so its output is identical either way. But nothing in CI runs
  on the actual hardware, so CI proves the logic and the build, never the board.

There is also a subtler trap the firmware job had to avoid. Zephyr's version is
now pinned in **two** places — the board's provisioning script, and a `west.yml`
that CI needs because of how its setup action works. If those drift, CI compiles
a different Zephyr from the one you are running, and reports green about
software nobody has. `tools/check-zephyr-pin.sh` is a gate whose entire job is
to fail when they disagree.

## Try it

Run the whole thing:

```bash
cd ~/two-computers-one-board
tools/check.sh --fast
```

Now break something and watch which gate catches it. Add an unused import to any
file in `python/unoq/`, then:

```bash
tools/check.sh python
```

Ruff catches it, in about a second, and names the file and line. Undo it, then
try a type error — assign a string to something annotated `int` — and watch a
different gate catch a different class of mistake. That separation is the point:
each gate is cheap because it only looks for one kind of thing.

Finally, prove the docs gate is real. Add a link to a page that does not exist:

```markdown
[nonsense](does-not-exist.md)
```

```bash
tools/check.sh docs
```

That build fails. Nineteen links in this course were broken on GitHub before
this gate existed, and nothing noticed for months.

> [!TIP]
> **Go deeper** — [pytest](https://docs.pytest.org/),
> [Ruff](https://docs.astral.sh/ruff/) (its rule index is a readable catalog
> of mistakes worth not making) and
> [ztest](https://docs.zephyrproject.org/latest/develop/test/ztest.html) with
> [twister](https://docs.zephyrproject.org/latest/develop/test/twister.html) for
> the firmware side. [ShellCheck](https://www.shellcheck.net/) will teach you
> more about shell quoting than any tutorial.

## Check yourself

1. Why does `tools/check.sh` treat a missing tool as a failure rather than
   skipping it?
2. `bars.c` is tested without the chip and `matrix.c` is not. What is the property
   of each that decides that, and how did the design make it true?
3. Coverage is 100%. Give a concrete bug that could still be in the code.
4. Nothing in CI runs on real hardware. Describe a change that would pass every
   gate here and still leave the board unable to boot.

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Because a gate that silently does nothing produces confidence.** An early
   version reported "All 2 gates passed" on a machine with no `mypy` and no
   `pytest`, having type-checked nothing and run no tests at all. That is
   worse than no gate.
2. **`bars.c` is pure arithmetic; `matrix.c` touches registers.** The
   rasterizer needs no hardware, so it runs under `native_sim`. The
   charlieplexing driver writes `MODER` and `BSRR` directly, and there is no
   such register on a laptop. The design made it true by splitting the code:
   the interesting logic sits on the testable side, and the untestable part is
   as small and as dumb as possible.
3. **No single answer.** Any bug where the line ran and nothing checked the
   result will do: coverage measures which lines ran, not whether the
   assertion was any good, and a test that calls every function and asserts
   nothing scores 100%. A good example names a specific wrong value — say, the
   rasterizer lighting the wrong pixel in a test that never looks at the
   pixels.
4. **No single answer.** A good answer puts the fault in what only the board
   exercises. CI proves the logic and the build, never the board, and
   `matrix.c` is only testable on the board — so a mistake in the code that
   touches registers compiles, signs and passes every suite. So does anything
   in the shell or `systemd` units that the stubbed tests do not cover, which
   is where every finding in the log was.

</details>

Next: [how a factory-fresh board becomes this one, one idempotent script at a
time](from-factory-to-this.md).
