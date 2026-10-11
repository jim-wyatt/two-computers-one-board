<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Contributing

Corrections, questions and fixes are all welcome. This is a small project with
one maintainer, so the most useful thing you can do is be specific.

## Something did not work

[Open an issue](https://github.com/jim-wyatt/two-computers-one-board/issues/new/choose).
If `bootstrap.sh` failed, paste the output from the last `##########` banner
down to the end. The step name and the line marked `FAILED` are usually enough.

"I followed the course and got stuck at this sentence" is a bug report too, and
a valued one. The course is for people who have not done this before, and the
author no longer is one.

## Changing something

1. You do not need a board for most of it. `tools/install-dev-tools.sh` sets up
   everything the checks need, on a board or an ordinary Linux machine, without
   `sudo`.
2. Run `tools/check.sh --fast` before you push. It is what CI runs.
3. A change to a shell script wants a test in `tests/`, and
   [tests/README.md](tests/README.md) says how. Check that the test fails when
   you break the script on purpose.
4. Say in the pull request what you ran it on. "Not tested on a board" is a
   perfectly good answer, and a much better one than silence: nothing in CI can
   flash a microcontroller or plug in a cable.

[Working on this project](docs/reference/development.md) has the layout, every
quality gate, and the conventions.

## What will be asked of a change

- **`bootstrap.sh` stays safe to run twice.** Running it again is the recovery
  path, so every step must leave a correct board alone.
- **Every change a provisioning step makes says how to undo it**, in a
  `REVERT:` comment above it.
- **The documentation still reads on GitHub and with no network.**
- **No secrets, and nothing that is somebody else's to distribute.** See
  [third-party.md](docs/third-party.md).

<a id="licence"></a> <!-- the heading's address before the spelling changed; links to it still land here. codespell:ignore licence -->

## License

By contributing you agree that your contribution is released under the
project's [MIT license](LICENSE).
