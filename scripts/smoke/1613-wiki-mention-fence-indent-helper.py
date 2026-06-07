#!/usr/bin/env python3
"""Helper for scripts/smoke/1613-wiki-mention-fence-indent.sh (issue #1613).

Imports the real ``scripts/wiki-mention-scan.py`` module and drives its
``iter_wikilinks`` over a fixture that mixes the four code-context shapes the
scanner must NOT read as wikilinks — a fenced ```` ``` ````-bash block, an
inline ``[[:space:]]`` codespan, a 4-space-indented code block, and a tab-
indented code block — alongside genuine ``[[wikilink]]`` references.

Before the #1613 fix, the indented blocks leaked bash ``[[ ... ]]`` tests and
POSIX ``[:space:]`` classes as wikilinks (``iter_wikilinks`` returned
``['$dry_run -eq 0', ':space:', 'people']``). After the fix it must return
only the real link(s).

Modes (file-as-argv, never heredoc-stdin — lint-heredoc-ban / footgun #11):

  repro <wiki-mention-scan.py>
      The exact issue-body repro: a fenced bash block, an inline span, a
      4-space indented block, plus a real ``[[people]]`` link. Asserts
      ``iter_wikilinks`` -> ['people'].

  controls <wiki-mention-scan.py>
      Regression controls that must NOT break:
        - legit links at column 0 (plain, ``|``-aliased, ``#``-anchored)
          still resolve;
        - a tab-indented code block is also blanked;
        - an indented line that merely continues a paragraph (no preceding
          blank line) is NOT treated as a code block, so its link survives
          (CommonMark: indented code cannot interrupt a paragraph);
        - the pre-processing stays length-preserving so match offsets still
          point at ``[[`` in the original text.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def _load_module(scan_py: Path):
    spec = importlib.util.spec_from_file_location("wiki_mention_scan", scan_py)
    if spec is None or spec.loader is None:
        _fail(f"could not load module spec for {scan_py}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _surfaces(module, text: str) -> list[str]:
    return [surface for surface, _pos in module.iter_wikilinks(text)]


def mode_repro(module) -> None:
    # Verbatim from issue #1613 (and the fixer brief). The fenced block and
    # inline span were already excluded pre-fix; the 4-space INDENTED block
    # is the regression this smoke pins.
    text = (
        "# Test\n"
        "Some prose with inline `[[:space:]]` and `$dry_run -eq 0` code.\n"
        "\n"
        "```bash\n"
        "if [[ $dry_run -eq 0 ]]; then echo hi; fi\n"
        "```\n"
        "\n"
        "Indented code block (4 spaces):\n"
        "\n"
        "    if [[ $dry_run -eq 0 ]]; then\n"
        "    grep [[:space:]] file\n"
        "\n"
        "A real link: [[people]] should resolve."
    )
    got = _surfaces(module, text)
    if got != ["people"]:
        _fail(f"repro: expected ['people'], got {got!r}")
    print("PASS repro: indented + fenced + inline excluded; only [[people]] kept")


def mode_controls(module) -> None:
    # 1) Legit links at column 0 still resolve (plain / aliased / anchored).
    legit = "# h\n\n[[alpha]] and [[beta|Beta]] and [[gamma#sec]] links."
    got = _surfaces(module, legit)
    if got != ["alpha", "beta", "gamma"]:
        _fail(f"controls/legit: expected ['alpha','beta','gamma'], got {got!r}")

    # 2) Tab-indented code block is also blanked.
    tabbed = (
        "intro para\n"
        "\n"
        "\tif [[ $x -eq 0 ]]; then\n"
        "\tgrep [[:alpha:]] f\n"
        "\n"
        "back to [[realone]] prose"
    )
    got = _surfaces(module, tabbed)
    if got != ["realone"]:
        _fail(f"controls/tab: expected ['realone'], got {got!r}")

    # 3) An indented line that interrupts a paragraph (no preceding blank
    #    line) is a lazy continuation, NOT an indented code block — its link
    #    must survive (CommonMark indented code cannot interrupt a paragraph).
    continuation = "a paragraph line\n    [[stillalink]] indented but interrupts"
    got = _surfaces(module, continuation)
    if got != ["stillalink"]:
        _fail(f"controls/continuation: expected ['stillalink'], got {got!r}")

    # 3b) A blank-line-separated 4-space-indented line UNDER a list item is a
    #     list paragraph, NOT an indented code block — a genuine link there
    #     must survive. The bias is toward keeping real links; an indented
    #     code block only opens OUTSIDE a list. (Bullet + ordered + the
    #     control that genuine indented code AFTER the list closes is still
    #     blanked.)
    list_bullet = "- item one\n\n    continuation with [[linkA]]\n\n- item two [[linkB]]"
    got = _surfaces(module, list_bullet)
    if got != ["linkA", "linkB"]:
        _fail(f"controls/list-bullet: expected ['linkA','linkB'], got {got!r}")
    list_ordered = "1. step one\n\n    note [[ordlink]]\n\n2. step two"
    got = _surfaces(module, list_ordered)
    if got != ["ordlink"]:
        _fail(f"controls/list-ordered: expected ['ordlink'], got {got!r}")
    after_list = (
        "- a\n- b\n\nback to prose\n\n"
        "    code [[notlink]] here\n    grep [[:digit:]] f\n\n[[realafter]]"
    )
    got = _surfaces(module, after_list)
    if got != ["realafter"]:
        _fail(f"controls/after-list: expected ['realafter'], got {got!r}")

    # 3c) Indented code may start after a NON-paragraph block (heading,
    #     thematic break, blockquote) — not only after a blank line. An
    #     indented code line right after an ATX heading must be blanked
    #     (CommonMark only forbids indented code from interrupting a
    #     *paragraph*). This is the round-1 codex finding.
    after_heading = "## Example\n    if [[ $dry_run -eq 0 ]]; then\n[[people]]"
    got = _surfaces(module, after_heading)
    if got != ["people"]:
        _fail(f"controls/after-heading: expected ['people'], got {got!r}")
    after_thematic = "---\n    grep [[:space:]] f\n    x [[notlink]]\n\n[[realtb]]"
    got = _surfaces(module, after_thematic)
    if got != ["realtb"]:
        _fail(f"controls/after-thematic-break: expected ['realtb'], got {got!r}")
    after_quote = "> quoted text\n    code [[notbq]]\n\n[[realbq]]"
    got = _surfaces(module, after_quote)
    if got != ["realbq"]:
        _fail(f"controls/after-blockquote: expected ['realbq'], got {got!r}")

    # 4) Offsets stay aligned: every reported position points at "[[" in the
    #    ORIGINAL text (the pre-processing is length-preserving).
    offset_text = "intro\n\n    code [[notlink]]\n\n[[reallink]] here"
    for surface, pos in module.iter_wikilinks(offset_text):
        if offset_text[pos : pos + 2] != "[[":
            _fail(
                f"controls/offset: position {pos} for {surface!r} does not "
                f"point at '[[' (got {offset_text[pos:pos + 4]!r})"
            )
    if _surfaces(module, offset_text) != ["reallink"]:
        _fail(
            "controls/offset: expected only ['reallink'], got "
            f"{_surfaces(module, offset_text)!r}"
        )

    print("PASS controls: legit links intact, tab-block blanked, "
          "paragraph-continuation + list-paragraph links preserved, "
          "code-after-list/heading/thematic-break/blockquote blanked, "
          "offsets aligned")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        _fail("usage: 1613-wiki-mention-fence-indent-helper.py "
              "<repro|controls> <wiki-mention-scan.py>")
    mode, scan_py_arg = argv[1], argv[2]
    scan_py = Path(scan_py_arg)
    if not scan_py.is_file():
        _fail(f"scanner not found: {scan_py}")
    module = _load_module(scan_py)
    if mode == "repro":
        mode_repro(module)
    elif mode == "controls":
        mode_controls(module)
    else:
        _fail(f"unknown mode: {mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
