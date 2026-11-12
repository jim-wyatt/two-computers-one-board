// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// The colors live in style.css, as custom properties on :root, light and dark.
// ECharts draws on a canvas and cannot read CSS, so this reads them back out,
// and useTheme() reads them again when the system switches between the two.

import { useEffect, useState } from "react";

export interface Theme {
  surface: string;
  ink: string;
  inkSecondary: string;
  muted: string;
  grid: string;
  baseline: string;
  border: string;
  /** The categorical slots, in their fixed order: line n of a chart is series[n]. */
  series: string[];
}

function read(): Theme {
  const css = getComputedStyle(document.documentElement);
  const v = (name: string) => css.getPropertyValue(name).trim();
  return {
    surface: v("--surface-1"),
    ink: v("--text-primary"),
    inkSecondary: v("--text-secondary"),
    muted: v("--text-muted"),
    grid: v("--gridline"),
    baseline: v("--baseline"),
    border: v("--border"),
    series: [1, 2, 3, 4].map((n) => v(`--series-${n}`)),
  };
}

export function useTheme(): Theme {
  const [theme, setTheme] = useState(read);
  useEffect(() => {
    const dark = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setTheme(read());
    dark.addEventListener("change", update);
    return () => dark.removeEventListener("change", update);
  }, []);
  return theme;
}
