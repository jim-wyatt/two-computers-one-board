// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// What the page draws, as data: which metrics make each chart and tile, in
// what unit. The metric names are the ones python/unoq/dashboard.py writes.
//
// One unit per chart, never two axes: a chart that put degrees beside
// percent would let the scale of one decide how the other looks. And at most
// four lines per chart, so each carries a label at its end as well as a
// legend entry, and none is told apart by color alone. The ten thermal zones
// are folded into their hottest for that reason; every one of them is in the
// table under the charts.

export type Column = (number | null)[];
export type Columns = Record<string, Column>;

/** A line: a metric by name, or one worked out from several. */
export interface Line {
  name: string;
  pick: (series: Columns, length: number) => Column;
}

export interface ChartSpec {
  title: string;
  unit: string;
  lines: Line[];
  /** Fixed scale for a percentage; otherwise it fits the data. */
  range?: [number, number];
  digits: number;
}

export interface TileSpec {
  label: string;
  unit: string;
  digits: number;
  line: Line;
  /** The latest value, from /api/latest's flat dict. */
  now: (values: Record<string, number>) => number | undefined;
}

const nulls = (length: number): Column => new Array<number | null>(length).fill(null);

/** One metric, as recorded. */
const metric = (name: string, key: string): Line => ({
  name,
  pick: (series, length) => series[key] ?? nulls(length),
});

/** Every metric whose name matches, folded point by point. A point with none is null. */
function fold(name: string, match: RegExp, how: (got: number[]) => number): Line {
  return {
    name,
    pick: (series, length) => {
      const keys = Object.keys(series).filter((k) => match.test(k));
      return Array.from({ length }, (_, i) => {
        const got = keys.map((k) => series[k][i]).filter((v): v is number => v != null);
        return got.length ? how(got) : null;
      });
    },
  };
}

const max = (got: number[]) => Math.max(...got);
const sum = (got: number[]) => got.reduce((a, b) => a + b, 0);
const mean = (got: number[]) => sum(got) / got.length;

/** The same fold, over the latest sample's dict. */
function foldNow(match: RegExp, how: (got: number[]) => number) {
  return (values: Record<string, number>) => {
    const got = Object.entries(values)
      .filter(([k]) => match.test(k))
      .map(([, v]) => v);
    return got.length ? how(got) : undefined;
  };
}

const SOC_ZONE = /^temp\./;
const CORE = /^cpu\.\d+$/;

export const AIR: ChartSpec[] = [
  { title: "Temperature", unit: "°C", digits: 2, lines: [metric("Air", "env.temp_c")] },
  {
    title: "Relative humidity",
    unit: "%",
    digits: 1,
    range: [0, 100],
    lines: [metric("Humidity", "env.humidity_pct")],
  },
  { title: "Pressure", unit: "hPa", digits: 1, lines: [metric("Pressure", "env.pressure_hpa")] },
  {
    title: "Gas resistance",
    unit: "kΩ",
    digits: 1,
    lines: [metric("Gas resistance", "env.gas_kohm")],
  },
];

export const BOARD: ChartSpec[] = [
  {
    title: "CPU busy, per core",
    unit: "%",
    digits: 0,
    range: [0, 100],
    lines: [0, 1, 2, 3].map((n) => metric(`core ${n}`, `cpu.${n}`)),
  },
  {
    title: "Temperatures",
    unit: "°C",
    digits: 1,
    lines: [
      fold("hottest SoC zone", SOC_ZONE, max),
      metric("MCU die", "mcu.die_c"),
      metric("air", "env.temp_c"),
    ],
  },
  {
    title: "Load average",
    unit: "",
    digits: 2,
    lines: [metric("1 min", "load.1"), metric("5 min", "load.5"), metric("15 min", "load.15")],
  },
  {
    title: "Memory in use",
    unit: "MiB",
    digits: 0,
    lines: [metric("RAM", "mem.used_mib"), metric("swap", "swap.used_mib")],
  },
  {
    title: "Clocks",
    unit: "MHz",
    digits: 0,
    lines: [metric("CPU", "freq.policy0_mhz"), metric("GPU", "freq.gpu_mhz")],
  },
  {
    title: "Network, all interfaces",
    unit: "kbit/s",
    digits: 1,
    lines: [fold("in", /^net\..*\.rx_kbps$/, sum), fold("out", /^net\..*\.tx_kbps$/, sum)],
  },
  {
    title: "Disk used",
    unit: "%",
    digits: 1,
    range: [0, 100],
    lines: [metric("root", "disk.root_pct"), metric("home", "disk.home_pct")],
  },
];

const tile = (label: string, unit: string, digits: number, key: string): TileSpec => ({
  label,
  unit,
  digits,
  line: metric(label, key),
  now: (values) => values[key],
});

export const TILES: TileSpec[] = [
  tile("Air temperature", "°C", 1, "env.temp_c"),
  tile("Humidity", "%", 1, "env.humidity_pct"),
  tile("Pressure", "hPa", 0, "env.pressure_hpa"),
  tile("Gas resistance", "kΩ", 1, "env.gas_kohm"),
  {
    label: "CPU busy",
    unit: "%",
    digits: 0,
    line: fold("CPU busy", CORE, mean),
    now: foldNow(CORE, mean),
  },
  tile("Memory", "%", 0, "mem.used_pct"),
  {
    label: "Hottest SoC zone",
    unit: "°C",
    digits: 1,
    line: fold("Hottest SoC zone", SOC_ZONE, max),
    now: foldNow(SOC_ZONE, max),
  },
  tile("MCU die", "°C", 1, "mcu.die_c"),
];

/** A metric name in words, and its unit, for the table of every reading. */
export function describe(key: string): [string, string] {
  const [group, ...rest] = key.split(".");
  const what = rest.join(".");
  switch (group) {
    case "env":
      return [
        { temp_c: "Air temperature", humidity_pct: "Relative humidity", pressure_hpa: "Pressure", gas_kohm: "Gas resistance" }[what] ?? what,
        { temp_c: "°C", humidity_pct: "%", pressure_hpa: "hPa", gas_kohm: "kΩ" }[what] ?? "",
      ];
    case "mcu":
      return ["MCU die temperature", "°C"];
    case "cpu":
      return [`CPU core ${what} busy`, "%"];
    case "load":
      return [`Load average, ${what} min`, ""];
    case "mem":
      return what === "used_pct" ? ["Memory in use", "%"] : ["Memory in use", "MiB"];
    case "swap":
      return ["Swap in use", "MiB"];
    case "temp":
      return [`Thermal zone ${what}`, "°C"];
    case "freq":
      return [`Clock, ${what.replace(/_mhz$/, "")}`, "MHz"];
    case "net": {
      const [iface, dir] = what.split(".");
      return [`${iface} ${dir === "rx_kbps" ? "in" : "out"}`, "kbit/s"];
    }
    case "disk":
      return [`Disk used, ${what.replace(/_pct$/, "")}`, "%"];
    default:
      return [key, ""];
  }
}
