# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Build-time hooks for the documentation site.

MkDocs loads this file directly from `hooks:` in mkdocs.yml - it is not a
plugin and needs no package, no entry point and no extra dependency. Three
jobs, all of which exist so that the SAME markdown reads correctly in two
places: on GitHub, and on the rendered site the board serves.

    docs/**/*.md  --+--> GitHub renders it raw
                    |
                    +--> this hook --> python-markdown --> Material --> site

Neither transformation is allowed to make the source worse to read. That rules
out the usual approach of writing site-flavored markdown and accepting that
GitHub shows the syntax as literal text.
"""

from __future__ import annotations

import posixpath
import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover - import-time only, for type checkers
    from mkdocs.config.defaults import MkDocsConfig
    from mkdocs.structure.files import Files
    from mkdocs.structure.pages import Page

# --------------------------------------------------------------------------
# 1. links that point out of docs/
# --------------------------------------------------------------------------
#
# The course talks about source files constantly - `../../mcu/app/src/bars.c`
# and friends. Those paths are correct on GitHub, where the reader is standing
# in the repository. The site is built from docs/ alone and has no such file,
# so a relative link would 404 exactly where a reader is most curious.
#
# Rewriting them to the repository means one dead-ish link class (needs the
# network) instead of another (needs a file that was never shipped). A reader
# offline on the USB drive can still see WHERE to look, which is most of the
# value; a 404 tells them nothing.

_LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")
_FENCE = re.compile(r"^\s*(```|~~~)")


def _is_local(target: str) -> bool:
    return not target.startswith(("http://", "https://", "#", "mailto:", "/"))


def _rewrite_target(target: str, page_dir: str, repo_blob: str) -> str:
    """Return `target` unchanged, or an absolute repository URL for it."""
    if not _is_local(target):
        return target
    path, _, anchor = target.partition("#")
    if not path:  # a bare "#anchor" - same page
        return target
    resolved = posixpath.normpath(posixpath.join(page_dir, path))
    if not resolved.startswith("../"):
        return target  # still inside docs/ - MkDocs will resolve and validate it
    return repo_blob + resolved.removeprefix("../") + (f"#{anchor}" if anchor else "")


# --------------------------------------------------------------------------
# 2. GitHub alerts -> Material admonitions
# --------------------------------------------------------------------------
#
# GitHub renders this as a colored callout:
#
#     > [!TIP]
#     > **Go deeper** - the reference pages have the exact detail.
#
# python-markdown renders it as a blockquote whose first line is the literal
# text "[!TIP]". Material's own syntax (`!!! tip`) has the mirror-image problem:
# GitHub shows the bangs. Converting here means the source keeps the form that
# degrades most gracefully - a plain blockquote - and the site still gets a
# proper admonition.

_ALERT = re.compile(r"^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$")
_ADMONITION = {
    "NOTE": "note",
    "TIP": "tip",
    "IMPORTANT": "info",
    "WARNING": "warning",
    "CAUTION": "danger",
}


def _convert_alerts(markdown: str) -> str:
    out: list[str] = []
    lines = markdown.splitlines()
    i = 0
    fence = ""
    while i < len(lines):
        line = lines[i]

        # Code blocks are verbatim: a shell transcript may legitimately contain
        # a line that looks like an alert marker.
        opener = _FENCE.match(line)
        if fence:
            out.append(line)
            if opener and line.strip().startswith(fence):
                fence = ""
            i += 1
            continue
        if opener:
            fence = opener.group(1)
            out.append(line)
            i += 1
            continue

        alert = _ALERT.match(line)
        if not alert:
            out.append(line)
            i += 1
            continue

        i += 1
        body: list[str] = []
        while i < len(lines) and lines[i].startswith(">"):
            body.append(lines[i].lstrip(">").removeprefix(" "))
            i += 1
        out.append(f'!!! {_ADMONITION[alert.group(1)]} ""')
        out.append("")
        # Four spaces is the admonition body indent. Blank lines stay blank so
        # a multi-paragraph callout survives the trip.
        out.extend(f"    {b}" if b.strip() else "" for b in body)
        out.append("")
    return "\n".join(out)


# --------------------------------------------------------------------------
# 3. tables that survive a narrow column
# --------------------------------------------------------------------------
#
# Two things, both done to the rendered HTML rather than by writing the tables
# differently in markdown - where GitHub would have to render the result too,
# and where nobody should have to think about either. Nothing is rearranged:
# with the stylesheet missing, what is left is still an ordinary table.
#
# NAMES THAT BREAK WHERE THEIR WORDS DO. A long name in a narrow column has to
# break somewhere, and a browser offers two choices. Anywhere at all is
# Material's default, and it cut names wherever the column happened to end,
# leaving the last five letters of a setting on a line of their own: measured
# over every page, 74 of the 763 pieces of code in table cells were split
# mid-word at 1440px, and 196 at 390px. Nowhere at all is the other, and it
# was tried: the names took the room the sentences needed, and two tables on
# the settings page no longer fitted the column. So docs/stylesheets/extra.css
# says "nowhere", and this marks the places that are acceptable after all -
# after each underscore - with <wbr>. At the same type size the settings page
# is 15618px tall without them and 13640px with, and no table on the site
# scrolls sideways at either width. <wbr> is an empty element:
# the name is still one unbroken string to select and copy, and none of it
# reaches the search index (checked in the built search_index.js).
#
# ROWS A PHONE CAN SET AS CARDS. Most tables in these pages hold sentences,
# and three columns of sentences do not fit a phone: measured at 390px, the
# first table on the setup page was three columns about 100px wide and 2283px
# tall. The stylesheet sets each row of such a table as a block instead, one
# cell under another. A cell on a line of its own has lost its column, so it
# needs its heading repeated beside it, and CSS can only print text that is
# already on the element. So each column's heading is copied onto the cells
# under it as `data-label`, and the table is marked `data-stack` so the
# stylesheet knows it may.

_TABLE = re.compile(r"<table>(.*?)</table>", re.DOTALL)
_HEAD = re.compile(r"<thead>(.*?)</thead>", re.DOTALL)
_TH = re.compile(r"<th\b[^>]*>(.*?)</th>", re.DOTALL)
_ROW = re.compile(r"<tr>(.*?)</tr>", re.DOTALL)
_TD = re.compile(r"<td\b")
_TAG = re.compile(r"<[^>]+>")
# Inline code is text and entities only, so there is no markup inside it to
# trip over, and no entity has an underscore in its name.
_CODE = re.compile(r"<code>([^<]*)</code>")

# Two columns are a name and its meaning, and fit side by side at 390px.
_STACK_FROM_COLUMNS = 3


def _breakable(code: re.Match[str]) -> str:
    return f"<code>{code.group(1).replace('_', '_<wbr>')}</code>"


def _fit_table(match: re.Match[str]) -> str:
    inner = _CODE.sub(_breakable, match.group(1))
    head = _HEAD.search(inner)
    # Tags out, entities left as they are: the text goes straight back into an
    # attribute, where `&amp;` is already what it has to be.
    labels = [
        _TAG.sub("", th).strip().replace('"', "&quot;")
        for th in _TH.findall(head.group(1) if head else "")
    ]
    # A header row of `| | | |` means the columns need no names. Those tables
    # are a few short words to a cell, and are fine as they are.
    if len(labels) < _STACK_FROM_COLUMNS or not any(labels):
        return f"<table>{inner}</table>"

    def label_row(row: re.Match[str]) -> str:
        cells = iter(labels)

        def label_cell(cell: re.Match[str]) -> str:
            label = next(cells, "")
            return f'{cell.group(0)} data-label="{label}"' if label else cell.group(0)

        return f"<tr>{_TD.sub(label_cell, row.group(1))}</tr>"

    return f"<table data-stack>{_ROW.sub(label_row, inner)}</table>"


def _fit_tables(html: str) -> str:
    return _TABLE.sub(_fit_table, html)


# --------------------------------------------------------------------------
# the hooks MkDocs calls
# --------------------------------------------------------------------------


def on_page_content(
    html: str,
    *,
    page: Page,  # noqa: ARG001 - part of the MkDocs hook signature
    config: MkDocsConfig,  # noqa: ARG001
    files: Files,  # noqa: ARG001
) -> str:
    return _fit_tables(html)


def on_page_markdown(
    markdown: str,
    *,
    page: Page,
    config: MkDocsConfig,
    files: Files,  # noqa: ARG001 - part of the MkDocs hook signature
) -> str:
    repo_blob = config.repo_url.rstrip("/") + "/blob/main/"
    page_dir = posixpath.dirname(page.file.src_uri)

    def replace(match: re.Match[str]) -> str:
        label, target, title = match.group(1), match.group(2), match.group(3) or ""
        return f"[{label}]({_rewrite_target(target, page_dir, repo_blob)}{title})"

    # Same fence-awareness as the alert pass: a code sample that shows markdown
    # link syntax must come out the other side unedited.
    out: list[str] = []
    fence = ""
    for line in markdown.splitlines():
        opener = _FENCE.match(line)
        if fence:
            out.append(line)
            if opener and line.strip().startswith(fence):
                fence = ""
            continue
        if opener:
            fence = opener.group(1)
            out.append(line)
            continue
        out.append(_LINK.sub(replace, line))
    return _convert_alerts("\n".join(out))
