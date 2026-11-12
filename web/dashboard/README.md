<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The dashboard's page

The page `unoq-dashboard` serves: the BME680's readings and the board's own
stats over time. It is React with [Apache ECharts](https://echarts.apache.org/),
built with Vite into `python/unoq/dashboard_static/`, where the Python module
serves it from. The API it reads, and everything else about the dashboard, is
in [mpu.md](../../docs/reference/mpu.md#the-dashboard).

| File | What it is |
|---|---|
| `src/api.ts` | The three API answers, as types, and how the page asks for them |
| `src/metrics.ts` | Which metrics make each chart and tile, as data |
| `src/Chart.tsx` | One chart: ECharts options, the tooltip, the end labels |
| `src/App.tsx` | The page: ranges, problems, tiles, charts, the table of every reading |
| `src/theme.ts`, `src/style.css` | Every color, as tokens, light and dark |

## Why the build is committed

Generated files stay out of git everywhere else in this project: the
documentation site is rebuilt on the board, and the reason is in `.gitignore`.
This one is the exception, for three reasons that all come from the board:

- **The board has no Node.js**, and nothing else here needs it. Installing it
  at provisioning would put a runtime and 130 MB of packages on a root
  filesystem that `--with-slim` exists to empty, to build one page once.
- **Provisioning would need npm's registry**, which is one more network
  dependency for a bootstrap that can otherwise be run from a checkout.
- **The page has to be on disk**, for the reason `unoq.learn` gives: the board
  is often on a cable to a laptop with no internet, so loading React or ECharts
  from a CDN would mean a blank page exactly when one is needed.

What makes a committed build safe is that it is checked. CI's `dashboard` job
rebuilds it from `package-lock.json` on the Node version `package.json` pins and
fails if the result is not byte for byte what is committed. So a change to
`src/` that was never built, or a build edited by hand, cannot be merged.

## Changing it

You need Node at exactly the version `engines` names in `package.json`. No
root is needed: unpack a release from <https://nodejs.org/dist/> anywhere and
put its `bin/` first on `PATH`.

```bash
tools/build-dashboard.sh            # npm ci when needed, then build
tools/build-dashboard.sh --check    # what CI runs: is the committed build current?
```

Commit `src/` and `python/unoq/dashboard_static/` together.

To work on the page with live reloading, run the dev server against a board
that is running `unoq-dashboard`. It serves on `:5173` and passes `/api` through
to the board:

```bash
cd web/dashboard
UNOQ_DASHBOARD=http://<board>:8090 npm run dev
```

`UNOQ_DASHBOARD` defaults to `http://localhost:8090`, a dashboard on the same
machine. It is read only by `vite.config.ts`, for the dev server; the board
never sees it.

The packages are pinned exactly, in `package.json` as well as the lock file,
and each was chosen at least two weeks after its release. Move them
deliberately, then run `--check`'s build and look at the page in light and
dark mode before committing.
