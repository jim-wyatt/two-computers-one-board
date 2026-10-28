/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Render the ```mermaid fences. The library itself is NOT loaded by this file
 * and is not next to it: the theme vendors mermaid (the `privacy` plugin turns
 * its CDN reference into a local copy under assets/external/) and emits its own
 * script tag for it. All this file supplies is the call that draws them.
 *
 * WHY NOT THE THEME'S BUILT-IN INTEGRATION
 * ----------------------------------------
 * Found under Material for MkDocs, which built this site before Zensical did;
 * Zensical carries on the same theme and the same bundle.
 *
 * Material knows how to render mermaid, and it was doing so - but it fetches
 * the library itself, at a path baked into its shared JavaScript bundle, and
 * neither available form of that path works here:
 *
 *   site_url SET     the `privacy` plugin rewrites it to an ABSOLUTE url on the
 *                    public site, so every page with a diagram fetches the
 *                    library over the network. Dead on the USB drive.
 *   site_url UNSET   it comes out relative - and one bundle is shared by pages
 *                    at different depths, so `assets/external/...` resolves
 *                    correctly only from the site root. Every diagram in this
 *                    course lives under learn/ or reference/, where it 404s.
 *
 * Measured, not guessed: a headless Chromium render of learn/from-power-to-
 * prompt.html reported 0 blocks with `data-processed`, and
 * /learn/assets/external/... returned 404 while /assets/external/... returned
 * 200.
 *
 * `extra_javascript` does not have that problem: Material emits it as a script
 * tag per page, with the right number of ../ for that page's depth. So the
 * library is loaded here instead, and rendering is driven from here too.
 *
 * The one cost is that the file is a checked-in third-party blob (3.5 MB, MIT,
 * listed in docs/third-party.md) rather than something the build fetches. That
 * is the right trade: the whole point of these pages is that they work with no
 * network at all.
 */

(() => {
  let done = false;

  // Snapshot every fence's source NOW, synchronously, as this script tag runs -
  // before DOMContentLoaded, and so before anything else can rewrite it.
  //
  // The class these blocks carry is `unoq-mermaid`, not `mermaid`, and that is
  // deliberate (see mkdocs.yml): Material's own bundle renders anything classed
  // `mermaid`, it used to get there first, and it drew an error graphic and left
  // its temp container behind on every page. Renaming took it out of the race,
  // so this file is now the only renderer.
  //
  // The snapshot stays anyway. It is what render() replays to strip the <code>
  // wrapper below, and it means a fence survives anything else that might one
  // day touch it before we do.
  const SRC = new WeakMap();
  document.querySelectorAll("pre.unoq-mermaid").forEach((el) => {
    SRC.set(el, el.textContent);
  });

  const render = () => {
    if (done) return;
    // The library is loaded by a plain <script> AFTER this file, and its very
    // last statement is the one that publishes the global:
    //
    //   globalThis["mermaid"] = globalThis.__esbuild_esm_mermaid_nm["mermaid"].default
    //
    // So "not defined yet" is the normal state on the first attempt, and the
    // caller below retries rather than giving up. Measured: without the retry,
    // every page reported 0 rendered blocks while the same script and the same
    // library rendered correctly in isolation.
    if (typeof mermaid === "undefined") return;
    done = true;

    // startOnLoad is deliberately off. This script runs on DOMContentLoaded
    // anyway, and leaving mermaid to hook load as well means two passes over
    // the same elements on some browsers.
    mermaid.initialize({
      startOnLoad: false,
      // Match the page, including the reader's light/dark choice. Material puts
      // the scheme on <body data-md-color-scheme>, which is set before this
      // runs.
      theme:
        document.body.getAttribute("data-md-color-scheme") === "slate"
          ? "dark"
          : "default",
      fontFamily: "inherit",
      securityLevel: "strict",
      // useMaxWidth is off for every kind of diagram used here. Left on, a
      // diagram wider than the text column is SCALED to fit it, lettering
      // included: measured in a 688px column, the boot diagram's 16px labels
      // came out at 5.9px. A diagram is its labels. So each one is drawn at
      // its natural size, extra.css lets a wide one scroll, and
      // tools/check-diagrams.sh refuses one that does not fit a desktop column.
      flowchart: { htmlLabels: true, curve: "basis", useMaxWidth: false },
      sequence: { useMaxWidth: false },
      state: { useMaxWidth: false },
    });

    // UNWRAP BEFORE RENDERING. superfences emits each fence as
    //
    //   <pre class="unoq-mermaid"><code>flowchart LR ...</code></pre>
    //
    // and mermaid parses the element's innerHTML, so the source it is handed
    // literally begins with the string "<code>". That is a syntax error, and it
    // is why every diagram on this site drew mermaid's "Syntax error in text"
    // graphic. Replaying the snapshot as textContent replaces the <code> child
    // with a plain text node holding the decoded source.
    //
    // Measured, not guessed. Three variants through the vendored library:
    //
    //   <pre class="mermaid"><code>src</code></pre>   mermaid.run threw
    //   the same, unwrapped to textContent first      rendered
    //   <pre class="mermaid">src</pre>                rendered
    const todo = [];
    document.querySelectorAll("pre.unoq-mermaid").forEach((el) => {
      const src = SRC.get(el);
      if (!src) return;
      el.textContent = src;
      // Cleared so mermaid.run will consider the element at all - it skips
      // anything already marked, and a re-render after a theme switch would
      // otherwise be a no-op.
      el.removeAttribute("data-processed");
      todo.push(el);
    });

    // Marked once mermaid has finished with them, whether it drew them or
    // drew its error graphic. Nothing on the page needs this; the diagram gate
    // (tools/check_diagrams.py) does. From mermaid 12 a block first holds a
    // placeholder <svg width="100%"> that fits any column, and only the mark
    // says the real drawing has replaced it.
    const finished = () => {
      todo.forEach((el) => el.setAttribute("data-unoq-drawn", ""));
    };
    if (todo.length) mermaid.run({ nodes: todo }).then(finished, finished);
  };

  // Three chances, deliberately. DOMContentLoaded is usually enough; `load`
  // covers a slow parse of a 3.5 MB library; and a short poll covers the case
  // where the theme's own bundle is still doing something to the page. Each is
  // a no-op once one has succeeded.
  document.addEventListener("DOMContentLoaded", render);
  window.addEventListener("load", render);

  let tries = 0;
  const poll = setInterval(() => {
    render();
    if (done || ++tries > 40) clearInterval(poll);
  }, 100);

  render();
})();
