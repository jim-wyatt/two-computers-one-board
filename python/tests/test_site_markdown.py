# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""tools/site_markdown.py: the Markdown extension the documentation site is built with.

It replaced tools/mkdocs_hooks.py when the site moved from MkDocs to Zensical,
which runs no hooks. The hooks had no tests; their behavior was checked by
comparing a whole built site against the one before. These pin it down, through
a real Python-Markdown run with the extension loaded the way mkdocs.yml loads
it, so the order it runs in is under test as well as what it does.

Zensical's own part - registering the page being rendered - is stood in for by
a preprocessor with the same name, carrying the same attribute.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest
from markdown import Markdown
from markdown.preprocessors import Preprocessor

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "site_markdown.py"
REPO = "https://github.com/example/repo"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("site_markdown", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SITE = load()


class _Context(Preprocessor):
    """What Zensical registers: a preprocessor named rendering_context, with the page."""

    def __init__(self, md: Markdown, path: str) -> None:
        super().__init__(md)
        self.page = SimpleNamespace(path=path)

    def run(self, lines: list[str]) -> list[str]:
        return lines


def render(text: str, page: str | None = "learn/a-chapter.md", **config: Any) -> str:
    md = Markdown(extensions=[SITE.makeExtension(repo_url=REPO, **config), "admonition", "tables"])
    if page is not None:
        md.preprocessors.register(_Context(md, page), "rendering_context", 0)
    return md.convert(text)


# --- links out of docs/ -------------------------------------------------------


def test_a_file_outside_docs_becomes_a_repository_link() -> None:
    html = render("[bars](../../mcu/app/src/bars.c)")
    assert f'href="{REPO}/blob/main/mcu/app/src/bars.c"' in html


def test_a_directory_outside_docs_becomes_a_tree_link() -> None:
    # The slash is the only sign it is a directory, and normpath drops it.
    html = render("[the guide](../../tests/)")
    assert f'href="{REPO}/tree/main/tests"' in html


def test_the_anchor_and_title_survive_the_rewrite() -> None:
    html = render('[x](../../README.md#install "the install")')
    assert f'href="{REPO}/blob/main/README.md#install"' in html
    assert 'title="the install"' in html


def test_a_link_from_a_top_level_page_resolves_from_there() -> None:
    html = render("[x](../bootstrap.sh)", page="setup.md")
    assert f'href="{REPO}/blob/main/bootstrap.sh"' in html


@pytest.mark.parametrize(
    "target",
    [
        "../reference/usb.md",  # another page: Zensical resolves and checks these
        "#same-page",
        "https://example.com/x",
        "mailto:someone@example.com",
        "/absolute",
    ],
)
def test_everything_else_is_left_alone(target: str) -> None:
    assert f'href="{target}"' in render(f"[x]({target})")


def test_an_image_is_not_a_link() -> None:
    html = render("![a board](../../share/board.png)")
    assert REPO not in html


def test_a_link_inside_a_code_fence_is_not_touched() -> None:
    html = render("```\n[bars](../../mcu/app/src/bars.c)\n```")
    assert REPO not in html


def test_without_a_page_the_build_fails_rather_than_guess() -> None:
    with pytest.raises(RuntimeError, match="rendering context"):
        render("[x](../../a.c)", page=None)


def test_without_repo_url_the_extension_refuses_to_load() -> None:
    with pytest.raises(ValueError, match="repo_url"):
        Markdown(extensions=[SITE.makeExtension()])


# --- GitHub alerts --------------------------------------------------------------


@pytest.mark.parametrize(
    ("kind", "admonition"),
    [
        ("NOTE", "note"),
        ("TIP", "tip"),
        ("IMPORTANT", "info"),
        ("WARNING", "warning"),
        ("CAUTION", "danger"),
    ],
)
def test_each_alert_becomes_its_admonition(kind: str, admonition: str) -> None:
    html = render(f"> [!{kind}]\n> Read this first.")
    assert f'class="admonition {admonition}"' in html
    assert "Read this first." in html
    assert f"[!{kind}]" not in html


def test_a_callout_keeps_its_paragraphs() -> None:
    html = render("> [!TIP]\n> One.\n>\n> Two.")
    assert html.count("<p>") == 2


def test_an_ordinary_blockquote_stays_one() -> None:
    assert "<blockquote>" in render("> just a quote")


def test_an_alert_inside_a_code_fence_is_not_touched() -> None:
    html = render("~~~\n> [!NOTE]\n> literal\n~~~")
    assert "admonition" not in html
    assert "[!NOTE]" in html


# --- tables ---------------------------------------------------------------------

THREE = (
    "| Name | Kind | Meaning |\n|---|---|---|\n| `UNOQ_USB_MODE` | env | how the link behaves |\n"
)
TWO = "| Name | Meaning |\n|---|---|\n| `a_b` | c |\n"


def test_a_table_of_three_columns_can_be_set_as_cards() -> None:
    html = render(THREE)
    assert "<table data-stack>" in html
    assert '<td data-label="Name">' in html
    assert '<td data-label="Meaning">' in html


def test_a_table_of_two_columns_stays_a_table() -> None:
    html = render(TWO)
    assert "data-stack" not in html
    assert "data-label" not in html


def test_a_table_with_no_headings_stays_a_table() -> None:
    html = render("| | | |\n|---|---|---|\n| a | b | c |\n")
    assert "data-stack" not in html


def test_a_name_in_a_table_breaks_after_its_underscores() -> None:
    assert "<code>UNOQ_<wbr>USB_<wbr>MODE</code>" in render(THREE)
    # ...but only in a table: a paragraph's code is left as written.
    assert "<code>UNOQ_USB_MODE</code>" in render("`UNOQ_USB_MODE`")


def test_a_heading_with_a_quote_is_a_safe_attribute() -> None:
    html = render('| "A" | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n')
    assert 'data-label="&quot;A&quot;"' in html
