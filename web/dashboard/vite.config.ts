// Copyright (c) 2026 Jim Wyatt
// SPDX-License-Identifier: MIT
//
// The build lands in the Python package, beside the module that serves it
// (python/unoq/dashboard.py, static_dir()), so the editable install on the
// board serves whatever was last committed. README.md says why it is
// committed at all.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

// A license file, a NOTICE, or a directory of them: what each package ships.
const LICENSE_FILE = /^(licen[cs]es?|notice|copyrightnotice|copying)([.-].*)?$/i;

const ISC = (holder: string) => `ISC License

Copyright (c) ${holder}

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
`;

function licenseFiles(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir).sort()) {
    if (!LICENSE_FILE.test(name)) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...readdirSync(path).sort().map((f) => join(path, f)));
    else out.push(path);
  }
  return out;
}

/**
 * licenses.txt, beside the bundle: the license and notice texts of every
 * package the page is built from.
 *
 * The minifier drops the license comments those packages carry, and the
 * built page is redistributed - committed here, and served from every board.
 * Apache-2.0 (ECharts) and BSD-3-Clause (zrender) both require their notices
 * to go with it, so they are collected from node_modules, for exactly the
 * packages package-lock.json says the page depends on at run time.
 *
 * A package that ships no license file has the text of the license its
 * package.json names written out, with its author, when that license is one
 * this knows. Any other stops the build, rather than shipping without it.
 */
function licenses(): Plugin {
  return {
    name: "unoq-licenses",
    apply: "build",
    generateBundle() {
      const lock = JSON.parse(readFileSync("package-lock.json", "utf8"));
      const parts = [
        "The dashboard's page is built from these packages, under these licenses.\n" +
          "Written by web/dashboard/vite.config.ts from the packages themselves.\n",
      ];
      const entries = Object.entries(lock.packages as Record<string, Record<string, unknown>>)
        .filter(([path, info]) => path !== "" && !info.dev)
        .sort(([a], [b]) => a.localeCompare(b));
      for (const [path, info] of entries) {
        const name = path.replace(/^.*node_modules\//, "");
        const pkg = JSON.parse(readFileSync(join(path, "package.json"), "utf8"));
        const head = `${"=".repeat(72)}\n${name} ${info.version} - ${info.license}\n${"=".repeat(72)}\n`;
        const files = existsSync(path) ? licenseFiles(path) : [];
        if (files.length) {
          parts.push(head + files.map((f) => readFileSync(f, "utf8").trim()).join("\n\n---\n\n"));
        } else if (info.license === "ISC") {
          const author = typeof pkg.author === "string" ? pkg.author : pkg.author?.name;
          parts.push(
            head +
              `${name} ships no license file. Its package.json names the ISC license and\n` +
              `its author, ${author}; this is that license's text.\n\n` +
              ISC(author),
          );
        } else {
          this.error(`${name} ships no license file, and ${info.license} is not one this can write out`);
        }
      }
      this.emitFile({ type: "asset", fileName: "licenses.txt", source: parts.join("\n\n") + "\n" });
    },
  };
}

export default defineConfig({
  plugins: [react(), licenses()],
  // Relative, so the page works wherever it is mounted.
  base: "./",
  build: {
    outDir: "../../python/unoq/dashboard_static",
    emptyOutDir: true,
    // ECharts is most of the bundle, and it is served from the board's own
    // disk, never over the internet; the size warning is not about this case.
    chunkSizeWarningLimit: 1500,
  },
  server: {
    // `npm run dev` on a laptop, against a board's API.
    proxy: { "/api": process.env.UNOQ_DASHBOARD ?? "http://localhost:8090" },
  },
});
