// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// The page: a row of ranges, what could not be read, a tile per headline
// number, the charts, and a table of every reading in the latest sample.
//
// It polls. Every interval the recorder takes a sample, and every interval
// this asks for the latest and for the range again, averaged into a few
// hundred points. A week costs the same as an hour, and nothing is merged
// on this side, so what is drawn is always what the board has.

import { useCallback, useEffect, useState } from "react";

import { getHistory, getLatest, getMeta } from "./api";
import type { History, Latest, Meta } from "./api";
import { Chart, clock, format } from "./Chart";
import { AIR, BOARD, describe, TILES } from "./metrics";
import type { Column, TileSpec } from "./metrics";
import { useTheme } from "./theme";

const RANGES: [string, number][] = [
  ["15 min", 900],
  ["1 hour", 3600],
  ["6 hours", 6 * 3600],
  ["24 hours", 86400],
  ["7 days", 7 * 86400],
];
// About one per two pixels of a wide chart. More are downloaded, not seen.
const POINTS = 500;
const SPARK_POINTS = 60;

function Sparkline({ values, color }: { values: Column; color: string }) {
  const got = values.filter((v): v is number => v != null);
  if (got.length < 2) return <svg className="spark" aria-hidden="true" />;
  const lo = Math.min(...got);
  const hi = Math.max(...got);
  const w = 120;
  const h = 32;
  const x = (i: number) => (i / (values.length - 1)) * w;
  const y = (v: number) => (hi === lo ? h / 2 : h - 2 - ((v - lo) / (hi - lo)) * (h - 4));
  let d = "";
  values.forEach((v, i) => {
    if (v == null) return;
    const prev = i > 0 ? values[i - 1] : null;
    d += `${prev == null ? "M" : "L"}${x(i).toFixed(1)},${y(v).toFixed(1)}`;
  });
  return (
    <svg className="spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <path d={d} fill="none" stroke={color} strokeWidth="2" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

function Tile({ spec, latest, spark, color }: { spec: TileSpec; latest: Latest | null; spark: History | null; color: string }) {
  const now = latest ? spec.now(latest.values) : undefined;
  const values = spark ? spec.line.pick(spark.series, spark.t.length) : [];
  return (
    <div className="card tile">
      <div className="tile-label">{spec.label}</div>
      <div className="tile-value">
        {now == null ? "—" : format(now, spec.digits)}
        {now != null && <span className="unit">{spec.unit}</span>}
      </div>
      <Sparkline values={values} color={color} />
    </div>
  );
}

function Problems({ latest, meta }: { latest: Latest | null; meta: Meta | null }) {
  if (!latest) return null;
  const rows: [string, string][] = [];
  if (latest.status.mcu) rows.push(["The MCU was not read", latest.status.mcu]);
  if (latest.status.env) rows.push(["The BME680 was not read", latest.status.env]);
  const age = latest.t == null ? null : Date.now() / 1000 - latest.t;
  if (meta && age != null && age > 3 * meta.interval) {
    rows.push(["No new samples", `The newest is ${Math.round(age)} s old: is unoq-dashboard's recorder running?`]);
  }
  if (!rows.length) return null;
  return (
    <div className="problems" role="status">
      {rows.map(([title, why]) => (
        <div key={title} className="problem">
          <span className="problem-icon" aria-hidden="true">!</span>
          <div>
            <strong>{title}.</strong> <span className="why">{why}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

function Readings({ latest }: { latest: Latest | null }) {
  if (!latest || latest.t == null) return null;
  const rows = Object.entries(latest.values).sort(([a], [b]) => a.localeCompare(b));
  return (
    <details className="card readings">
      <summary>Every reading in the latest sample ({rows.length}), at {clock(latest.t * 1000, false)}</summary>
      <table>
        <thead>
          <tr>
            <th>Reading</th>
            <th className="num">Value</th>
            <th>Unit</th>
            <th>Metric</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([key, value]) => {
            const [name, unit] = describe(key);
            return (
              <tr key={key}>
                <td>{name}</td>
                <td className="num">{format(value, 2)}</td>
                <td>{unit}</td>
                <td>
                  <code>{key}</code>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </details>
  );
}

export function App() {
  const theme = useTheme();
  const [span, setSpan] = useState(3600);
  const [meta, setMeta] = useState<Meta | null>(null);
  const [latest, setLatest] = useState<Latest | null>(null);
  const [history, setHistory] = useState<History | null>(null);
  const [spark, setSpark] = useState<History | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getMeta().then(setMeta, (e: Error) => setError(e.message));
  }, []);

  const refresh = useCallback(async () => {
    try {
      const [l, h, s] = await Promise.all([getLatest(), getHistory(span, POINTS), getHistory(3600, SPARK_POINTS)]);
      setLatest(l);
      setHistory(h);
      setSpark(s);
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [span]);

  useEffect(() => {
    setLoading(true);
    refresh();
    const every = Math.max(2, meta?.interval ?? 10) * 1000;
    const timer = window.setInterval(refresh, every);
    return () => window.clearInterval(timer);
  }, [refresh, meta?.interval]);

  return (
    <div className="page">
      <header>
        <div>
          <h1>{meta?.host ?? "UNO Q"}</h1>
          <p className="sub">
            The air at the BME680, and the board itself
            {meta && ` · a sample every ${meta.interval} s, ${meta.keep_days} days kept · unoq ${meta.version}`}
          </p>
        </div>
        <p className="updated">{latest?.t != null && `Updated ${clock(latest.t * 1000, false)}`}</p>
      </header>

      <nav className="ranges" aria-label="Time range">
        {RANGES.map(([label, seconds]) => (
          <button key={label} type="button" aria-pressed={span === seconds} onClick={() => setSpan(seconds)}>
            {label}
          </button>
        ))}
        <span className="hint">Scroll or pinch on a chart to zoom; they move together.</span>
      </nav>

      {error && (
        <div className="problems" role="alert">
          <div className="problem">
            <span className="problem-icon" aria-hidden="true">!</span>
            <div>
              <strong>The dashboard's API did not answer.</strong> <span className="why">{error}</span>
            </div>
          </div>
        </div>
      )}
      <Problems latest={latest} meta={meta} />

      <div className="tiles">
        {TILES.map((t, i) => (
          <Tile key={t.label} spec={t} latest={latest} spark={spark} color={theme.series[i < 4 ? 0 : 1]} />
        ))}
      </div>

      {history && (
        <div className={loading ? "charts loading" : "charts"}>
          <h2>The air</h2>
          <div className="grid four">
            {AIR.map((spec) => (
              <Chart key={spec.title} spec={spec} history={history} theme={theme} span={span} />
            ))}
          </div>
          <h2>The board</h2>
          <div className="grid four">
            {BOARD.map((spec) => (
              <Chart key={spec.title} spec={spec} history={history} theme={theme} span={span} />
            ))}
          </div>
        </div>
      )}

      <Readings latest={latest} />

      <footer>
        Drawn with React and Apache ECharts: <a href="licenses.txt">their licenses</a>. The
        numbers are also at <a href="api/latest">api/latest</a> and{" "}
        <a href="api/history">api/history</a>.
      </footer>
    </div>
  );
}
