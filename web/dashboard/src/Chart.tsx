// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// One time-series chart: a card with a title, a legend when there is more
// than one line, and the lines labeled at their ends.
//
// Every chart is in one ECharts group, so the crosshair and the zoom move
// together: point at 14:05 on the CPU and every other chart shows 14:05 too.
// Only the parts of ECharts used here are registered, which is most of what
// keeps the bundle the size it is.

import { LineChart } from "echarts/charts";
import {
  DataZoomComponent,
  GridComponent,
  LegendComponent,
  TooltipComponent,
} from "echarts/components";
import * as echarts from "echarts/core";
import type { EChartsCoreOption } from "echarts/core";
import { CanvasRenderer } from "echarts/renderers";
import ReactEChartsCore from "echarts-for-react/esm/core";
import { useMemo } from "react";

import type { History } from "./api";
import type { ChartSpec } from "./metrics";
import type { Theme } from "./theme";

echarts.use([LineChart, GridComponent, TooltipComponent, LegendComponent, DataZoomComponent, CanvasRenderer]);

const GROUP = "unoq";

const escape = (s: string) =>
  s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export function format(value: number, digits: number): string {
  return value.toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function clock(ms: number, withDate: boolean): string {
  const d = new Date(ms);
  return withDate
    ? d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })
    : d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

interface TooltipRow {
  axisValue: number;
  seriesName: string;
  color: string;
  value: [number, number | null];
}

// Roughly the plot's height in pixels, and a label's: enough to tell which
// end labels would sit on one another.
const PLOT_PX = 170;
const LABEL_PX = 13;

/**
 * How far to move each line's end label, in pixels down, so that no two
 * overlap. Two cores ending at 30 % would otherwise print "core 1" over
 * "core 2"; ECharts moves overlapping labels apart, but not end labels.
 *
 * The labels are placed where their last values would put them on a scale
 * from the lowest to the highest value drawn, then walked from the bottom up,
 * each pushed at least a label's height above the one below it.
 */
export function nudges(lasts: (number | null)[], lo: number, hi: number): number[] {
  const span = hi - lo || 1;
  const at = lasts.map((v) => (v == null ? null : ((v - lo) / span) * PLOT_PX));
  const order = at
    .map((y, i) => [y, i] as const)
    .filter((p): p is readonly [number, number] => p[0] != null)
    .sort((a, b) => a[0] - b[0]);
  const out = lasts.map(() => 0);
  let floor = -Infinity;
  for (const [y, i] of order) {
    const placed = Math.max(y, floor + LABEL_PX);
    // Up the chart is up the screen: a label raised is a negative offset.
    out[i] = -(placed - y);
    floor = placed;
  }
  return out;
}

const lastOf = (values: (number | null)[]) => {
  for (let i = values.length - 1; i >= 0; i--) if (values[i] != null) return values[i];
  return null;
};

function options(spec: ChartSpec, history: History, theme: Theme, span: number): EChartsCoreOption {
  const ms = history.t.map((t) => t * 1000);
  const many = spec.lines.length > 1;
  const columns = spec.lines.map((line) => line.pick(history.series, ms.length));
  const drawn = columns.flat().filter((v): v is number => v != null);
  const [lo, hi] = spec.range ?? [Math.min(...drawn), Math.max(...drawn)];
  const nudge = nudges(columns.map(lastOf), lo, hi);
  const unit = spec.unit ? ` ${spec.unit}` : "";
  const withDate = span > 86400;
  return {
    animation: false,
    backgroundColor: "transparent",
    textStyle: { fontFamily: "inherit" },
    grid: { left: 8, right: many ? 104 : 16, top: many ? 32 : 12, bottom: 8, containLabel: true },
    legend: many
      ? {
          top: 0,
          left: 0,
          icon: "rect",
          itemWidth: 14,
          itemHeight: 2,
          textStyle: { color: theme.inkSecondary },
        }
      : undefined,
    tooltip: {
      trigger: "axis",
      axisPointer: { type: "line", lineStyle: { color: theme.muted, width: 1 } },
      backgroundColor: theme.surface,
      borderColor: theme.border,
      textStyle: { color: theme.ink },
      // Values lead and names follow; a short stroke of the line's color keys
      // each row. Names are this page's own, escaped all the same.
      formatter: (rows: TooltipRow[]) => {
        if (!rows.length) return "";
        const head = `<div style="color:${theme.muted}">${escape(clock(rows[0].axisValue, withDate))}</div>`;
        const body = rows
          .map((r) => {
            const v = r.value[1];
            const shown = v == null ? "no reading" : `${format(v, spec.digits)}${escape(unit)}`;
            return (
              `<div><span style="display:inline-block;width:12px;height:2px;margin:0 6px 3px 0;background:${r.color}"></span>` +
              `<b>${shown}</b> <span style="color:${theme.inkSecondary}">${escape(r.seriesName)}</span></div>`
            );
          })
          .join("");
        return head + body;
      },
    },
    xAxis: {
      type: "time",
      min: history.since * 1000,
      max: history.until * 1000,
      axisLine: { lineStyle: { color: theme.baseline } },
      axisTick: { show: false },
      axisLabel: { color: theme.muted, hideOverlap: true },
      splitLine: { show: false },
    },
    yAxis: {
      type: "value",
      scale: !spec.range,
      min: spec.range?.[0],
      max: spec.range?.[1],
      // A percentage in quarters; anything else in steps ECharts picks, and
      // labels it as precisely as the steps need, so no two ticks read alike.
      interval: spec.range ? 25 : undefined,
      splitNumber: 4,
      axisLabel: { color: theme.muted },
      splitLine: { lineStyle: { color: theme.grid } },
    },
    dataZoom: [{ type: "inside", xAxisIndex: 0, filterMode: "none" }],
    series: spec.lines.map((line, i) => {
      const values = columns[i];
      return {
        type: "line",
        name: line.name,
        data: ms.map((t, j) => [t, values[j]]),
        color: theme.series[i],
        showSymbol: false,
        symbolSize: 8,
        lineStyle: { width: 2 },
        // A gap in the record is drawn as one: no line through the time
        // nothing was recorded (the API puts a null there).
        connectNulls: false,
        endLabel: many
          ? {
              show: true,
              formatter: "{a}",
              color: theme.inkSecondary,
              distance: 6,
              offset: [0, nudge[i]],
            }
          : undefined,
        emphasis: { focus: "series" },
      };
    }),
  };
}

export function Chart(props: {
  spec: ChartSpec;
  history: History;
  theme: Theme;
  span: number;
}) {
  const { spec, history, theme, span } = props;
  const option = useMemo(() => options(spec, history, theme, span), [spec, history, theme, span]);
  const empty = spec.lines.every((line) =>
    line.pick(history.series, history.t.length).every((v) => v == null),
  );
  return (
    <section className="card chart">
      <h3>
        {spec.title}
        {spec.unit && <span className="unit">{spec.unit}</span>}
      </h3>
      {empty ? (
        <p className="empty">Nothing recorded in this range.</p>
      ) : (
        <ReactEChartsCore
          echarts={echarts}
          option={option}
          notMerge
          style={{ height: 220 }}
          onChartReady={(chart: echarts.ECharts) => {
            chart.group = GROUP;
            echarts.connect(GROUP);
          }}
        />
      )}
    </section>
  );
}
