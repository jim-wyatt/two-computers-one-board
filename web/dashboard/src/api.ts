// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// The three answers python/unoq/dashboard.py gives, as types, and how to ask.
// The API is served from the same origin as this page, so every URL is
// relative: the page works on whatever address the board is reached by.

export interface Meta {
  host: string;
  version: string;
  interval: number;
  keep_days: number;
  mcu: boolean;
}

/** What the recorder could not read last time: "mcu" and "env", each a sentence. */
export type Status = Partial<Record<"mcu" | "env", string>>;

export interface Latest {
  t: number | null;
  values: Record<string, number>;
  status: Status;
}

/** One list per metric, as long as t, with null where nothing was read. */
export interface History {
  since: number;
  until: number;
  t: number[];
  series: Record<string, (number | null)[]>;
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { cache: "no-store" });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

export const getMeta = () => get<Meta>("api/meta");
export const getLatest = () => get<Latest>("api/latest");

export function getHistory(span: number, points: number): Promise<History> {
  const until = Date.now() / 1000;
  const q = new URLSearchParams({
    since: String(until - span),
    until: String(until),
    points: String(points),
  });
  return get<History>(`api/history?${q}`);
}
