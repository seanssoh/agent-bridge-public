#!/usr/bin/env python3
"""wiki-mention-scan.py — Observation layer (L1) for Agent Bridge wiki graph.

Walks ``shared/wiki/**/*.md``, extracts ``[[wikilink]]`` mentions, resolves
each to a canonical entity slug via frontmatter ``aliases``, and records the
resulting (source, entity) edges to ``shared/wiki/_index/mentions.db``.

This is the foundation for the entity-graph automation pipeline:

  L1 Observation  (this script)                                    ← here
  L2 Candidacy    (threshold-based enqueue of hub-build tasks)
  L3 Enrichment   (librarian synthesizes hub from agent pages)
  L4 Validation   (graph-health nightly report)
  L5 Human Gate   (merge/delete approval)

Generic. No deployment-specific paths, agent names, or entity lists. Works
on any Agent Bridge wiki that follows ``wiki-graph-rules.md`` and
``wiki-entity-lifecycle.md``.

Usage:
  wiki-mention-scan.py --full-rebuild                   # scan all, reset db
  wiki-mention-scan.py --incremental                    # mtime-scoped rescan
  wiki-mention-scan.py --report                         # stdout distribution
  wiki-mention-scan.py --report --out <file>            # write report
  wiki-mention-scan.py --wiki-root <path>               # override wiki root

Default wiki root is derived in this order:

  1. --wiki-root CLI flag
  2. AGENT_BRIDGE_WIKI env var
  3. <SCRIPT_DIR>/../shared/wiki  (bridge default layout)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Regex + constants (shared with bridge-wiki.py)
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
_WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")
# Codespan detection — skip wikilinks inside `...` because those are
# prose illustrations, not live references.
_CODESPAN_RE = re.compile(r"(`+)(?!`)(.+?)\1(?!`)")
# Fenced code block fence line: a run of >=3 backticks or tildes at the
# start of a (optionally indented) line, optionally followed by an info
# string. A closing fence must use the same character and be at least as
# long as the opening fence (CommonMark). Bash `[[ ... ]]` tests and
# `[:space:]` classes inside such blocks are code, not wikilinks.
_FENCE_LINE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})")
# A blank (or whitespace-only) line. An indented code block can *start*
# after a blank line (or after any non-paragraph block); it can NOT
# interrupt a paragraph. Used by ``blank_indented_code``.
_BLANK_LINE_RE = re.compile(r"^[ \t]*$")
# A POSIX bracket-expression class such as ``[:space:]`` / ``[:alpha:]``.
# When ``[[`` immediately wraps one (``[[:space:]]``) it is a shell/grep
# character-class fragment, never a wikilink. Used as a defensive reject in
# ``iter_wikilinks`` on top of code-region blanking.
_POSIX_CLASS_RE = re.compile(r"^:[a-z]+:$")
# A list-item marker line (bullet ``-``/``*``/``+`` or ordered ``1.``/``1)``),
# optionally indented. Inside a list, a blank-line-separated indented line is a
# list paragraph (where a real ``[[wikilink]]`` can live), NOT an indented code
# block — so ``blank_indented_code`` must not open a block while in a list.
_LIST_MARKER_RE = re.compile(r"^[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]")
# An ATX heading line (``# ``..``###### ``) — a non-paragraph leaf block.
# Indented code MAY start immediately after one (CommonMark only forbids
# indented code from interrupting a *paragraph*), so a heading must not be
# treated as a "paragraph" line that swallows a following indented block.
_ATX_HEADING_RE = re.compile(r"^[ \t]{0,3}#{1,6}(?:[ \t]|$)")
# A thematic break (``---`` / ``***`` / ``___``, >=3 of one char, spaces
# allowed) — also a non-paragraph block.
_THEMATIC_BREAK_RE = re.compile(r"^[ \t]{0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$")
# A blockquote marker line — non-paragraph block opener for our purposes.
_BLOCKQUOTE_RE = re.compile(r"^[ \t]{0,3}>")

# Skip these top-level wiki subtrees during scans. They are not content.
_SKIP_TOP_DIRS = {"_workspace", "_audit", "_index", ".obsidian"}

# Content roots we care about for "source_kind" classification.
_KIND_DIRS = {
    "daily",
    "weekly",
    "monthly",
    "entities",
    "concepts",
    "decisions",
    "systems",
    "projects",
    "people",
    "research",
    "frameworks",
    "papers",
    "ingredients",
    "playbooks",
    "data-sources",
    "tools",
}

SCHEMA_VERSION = 1

SCHEMA_DDL = [
    """
    CREATE TABLE IF NOT EXISTS schema_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS entities (
      slug TEXT PRIMARY KEY,
      title TEXT,
      type TEXT,
      hub_path TEXT,
      hub_scope TEXT,
      first_seen_at TEXT,
      last_seen_at TEXT,
      updated_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS aliases (
      alias_normalized TEXT NOT NULL,
      alias_surface TEXT NOT NULL,
      entity_slug TEXT NOT NULL,
      source_path TEXT NOT NULL,
      PRIMARY KEY (alias_normalized, entity_slug)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_alias_normalized ON aliases(alias_normalized)",
    """
    CREATE TABLE IF NOT EXISTS mentions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_path TEXT NOT NULL,
      source_agent TEXT,
      source_kind TEXT,
      source_mtime INTEGER,
      entity_slug TEXT NOT NULL,
      surface_form TEXT NOT NULL,
      mention_count INTEGER NOT NULL,
      scanned_at TEXT NOT NULL,
      UNIQUE(source_path, entity_slug, surface_form)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_mentions_entity ON mentions(entity_slug)",
    "CREATE INDEX IF NOT EXISTS idx_mentions_agent  ON mentions(source_agent)",
    "CREATE INDEX IF NOT EXISTS idx_mentions_source ON mentions(source_path)",
    """
    CREATE TABLE IF NOT EXISTS unresolved (
      source_path TEXT NOT NULL,
      surface_form TEXT NOT NULL,
      surface_normalized TEXT NOT NULL,
      scanned_at TEXT NOT NULL,
      PRIMARY KEY (source_path, surface_form)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_unresolved_norm ON unresolved(surface_normalized)",
    """
    CREATE TABLE IF NOT EXISTS scans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      mode TEXT NOT NULL,
      files_scanned INTEGER,
      entities_seen INTEGER,
      mentions_new INTEGER,
      unresolved_new INTEGER,
      error TEXT
    )
    """,
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_wiki_root(cli_value: str | None) -> Path:
    if cli_value:
        return Path(cli_value).expanduser().resolve()
    env = os.environ.get("AGENT_BRIDGE_WIKI")
    if env:
        return Path(env).expanduser().resolve()
    script_dir = Path(__file__).resolve().parent
    # scripts/ sibling of shared/
    default = script_dir.parent / "shared" / "wiki"
    return default.resolve()


def normalize_surface(text: str) -> str:
    """Normalize a surface form for alias lookup.

    - NFC unicode normalize (combines precomposed Korean/Japanese forms)
    - strip whitespace
    - lowercase (affects ASCII only; CJK is unchanged)
    - collapse internal whitespace runs to single space
    """
    if text is None:
        return ""
    s = unicodedata.normalize("NFC", text).strip()
    s = re.sub(r"\s+", " ", s)
    return s.lower()


def classify_source(rel: Path) -> tuple[str, str]:
    """Return (source_agent, source_kind) from wiki-relative path.

    source_agent:
      - "shared" if path is not under a real agents/<dir>/ subtree
      - agent name if "agents/<name>/..." where <name> is a directory
        (redirect stubs like "agents/satomi.md" count as shared, not as
        an agent namespace — the file is at the agents/ root, not inside
        a per-agent dir)

    source_kind:
      - first segment in path that matches _KIND_DIRS, else "other"
    """
    parts = rel.parts
    if not parts:
        return "", "other"
    if parts[0] == "agents" and len(parts) >= 3:
        # Only count as agent namespace when the relative path has at
        # least one more segment AFTER the agent name — i.e. the file
        # lives inside agents/<agent>/<...>.md, not at agents/<name>.md.
        source_agent = parts[1]
        kind_parts = parts[2:]
    else:
        source_agent = "shared"
        kind_parts = parts
    source_kind = "other"
    for seg in kind_parts:
        if seg in _KIND_DIRS:
            source_kind = seg
            break
    return source_agent, source_kind


def parse_frontmatter(text: str) -> dict | None:
    """Parse YAML-ish frontmatter without full YAML dep.

    Supports:
      - ``key: value``
      - ``key: [a, b, "c d"]`` (inline list)
      - ``key: >``/``key: |`` blocks are ignored (returned as raw string)
    """
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return None
    body = m.group(1)
    out: dict = {}
    for line in body.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z0-9_\-]+)\s*:\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            if not inner:
                out[key] = []
                continue
            items = []
            for raw in _split_inline_list(inner):
                raw = raw.strip()
                if raw.startswith("\"") and raw.endswith("\""):
                    raw = raw[1:-1]
                elif raw.startswith("'") and raw.endswith("'"):
                    raw = raw[1:-1]
                if raw:
                    items.append(raw)
            out[key] = items
        else:
            if value.startswith("\"") and value.endswith("\""):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            out[key] = value
    return out


def _split_inline_list(inner: str) -> list[str]:
    """Split inline YAML list respecting quoted strings."""
    items: list[str] = []
    depth = 0
    current = []
    in_quote: str | None = None
    for ch in inner:
        if in_quote:
            current.append(ch)
            if ch == in_quote:
                in_quote = None
            continue
        if ch in ('"', "'"):
            in_quote = ch
            current.append(ch)
            continue
        if ch == "," and depth == 0:
            items.append("".join(current))
            current = []
            continue
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        current.append(ch)
    if current:
        items.append("".join(current))
    return items


def blank_fenced_code(text: str) -> str:
    """Return ``text`` with every fenced code block region blanked out.

    Each character inside a ```` ``` ````- or ``~~~``-fenced region (the
    fence lines included) is replaced by a space, preserving the original
    length and every newline so byte offsets stay aligned for callers that
    track positions. A wikilink never lives inside a fenced code block, so
    blanking the whole region prevents bash ``[[ ... ]]`` tests and
    ``[:space:]`` POSIX classes from satisfying ``_WIKILINK_RE``.

    Fence matching follows CommonMark's basics: an opening fence is a run
    of >=3 backticks or tildes; the closing fence must use the same
    character and be at least as long. An unterminated fence runs to EOF.
    """
    lines = text.split("\n")
    out: list[str] = []
    fence_char: str | None = None
    fence_len = 0
    for line in lines:
        m = _FENCE_LINE_RE.match(line)
        if fence_char is None:
            if m:
                fence_char = m.group(1)[0]
                fence_len = len(m.group(1))
                out.append(" " * len(line))
            else:
                out.append(line)
        else:
            # Inside a fenced region — blank every line, and check for the
            # matching closing fence (same char, >= opening length, and no
            # trailing info string per CommonMark).
            out.append(" " * len(line))
            if m and m.group(1)[0] == fence_char and len(m.group(1)) >= fence_len:
                rest = line[m.end():].strip()
                if not rest:
                    fence_char = None
                    fence_len = 0
    return "\n".join(out)


def blank_indented_code(text: str) -> str:
    """Return ``text`` with CommonMark indented code blocks blanked out.

    An indented code block is a run of lines each indented by >=4 spaces
    (a leading tab counts as >=4 columns) that is *introduced* by a blank
    line — i.e. it cannot interrupt a paragraph (CommonMark §4.4). Blank
    lines interior to the block are kept as part of it; the block ends at
    the first non-blank line indented by fewer than 4 columns.

    Like ``blank_fenced_code`` this is length-preserving: every blanked
    character becomes a space and newlines are kept, so byte offsets stay
    aligned. Bash ``[[ ... ]]`` tests and ``[:space:]`` POSIX classes that
    live in such a block are code, not wikilinks, so blanking the region
    keeps them from satisfying ``_WIKILINK_RE``.

    CommonMark rule, faithfully: an indented code block can begin only when
    the indented line is NOT a lazy continuation of a paragraph. It may
    start after a blank line, after a heading, after a thematic break, or at
    the very top of the document — but it may NOT interrupt a paragraph. So
    the block opens at a >=4-column line whenever the *previous* original
    line was not a paragraph line (a blank line and the non-paragraph leaf
    blocks — ATX heading, thematic break, blockquote, fence — all clear the
    paragraph state).

    It also refuses to open a block while inside a list: a blank-separated
    indented line under a list item is a list paragraph, where a genuine
    ``[[wikilink]]`` can live — not code. The overall bias is toward
    *keeping* real links: an occasional leaked fragment in an exotic layout
    is still caught by the POSIX-class reject in ``iter_wikilinks``, but a
    wrongly-blanked link is unrecoverable.

    ``text`` is expected to have already had its fenced regions blanked, so
    an indented line *inside* a fence (now all spaces) is treated as blank
    here and never re-opens a block.
    """

    def indent_columns(line: str) -> int:
        """Expanded leading-whitespace width, with tab = 4 columns."""
        cols = 0
        for ch in line:
            if ch == " ":
                cols += 1
            elif ch == "\t":
                cols += 4
            else:
                break
        return cols

    def is_paragraph_line(line: str, is_blank: bool, indented: bool) -> bool:
        """True when ``line`` is ordinary paragraph prose — a non-blank,
        non-indented line that is not itself a non-paragraph leaf block
        (heading / thematic break / blockquote / list marker). Only a
        paragraph line can lazily swallow a following indented line."""
        if is_blank or indented:
            return False
        if _ATX_HEADING_RE.match(line):
            return False
        if _THEMATIC_BREAK_RE.match(line):
            return False
        if _BLOCKQUOTE_RE.match(line):
            return False
        if _LIST_MARKER_RE.match(line):
            return False
        return True

    lines = text.split("\n")
    out: list[str] = []
    in_block = False
    # start-of-document is not a paragraph context, so an indented first
    # line opens a block.
    prev_paragraph = False
    in_list = False  # currently inside a (possibly multi-paragraph) list
    for line in lines:
        is_blank = _BLANK_LINE_RE.match(line) is not None
        indented = (not is_blank) and indent_columns(line) >= 4
        is_list_marker = (not is_blank) and _LIST_MARKER_RE.match(line) is not None
        if in_block:
            if is_blank:
                # A blank line may be interior whitespace of the block;
                # keep it blanked and stay in-block (the block only ends
                # at a non-blank, under-indented line).
                out.append(" " * len(line))
            elif indented:
                out.append(" " * len(line))
            else:
                in_block = False
                out.append(line)
        else:
            if indented and not prev_paragraph and not in_list:
                in_block = True
                out.append(" " * len(line))
            else:
                out.append(line)
        # Maintain list-region state on the ORIGINAL line. A list opens at
        # a marker line and persists across blank lines and indented
        # continuations (list paragraphs); it closes at a non-blank,
        # non-indented, non-marker line (a return to flush-left prose).
        if is_list_marker:
            in_list = True
        elif not is_blank and not indented:
            in_list = False
        # Track whether the ORIGINAL line was paragraph prose so the next
        # indented line knows whether it would be a lazy continuation
        # (CommonMark forbids an indented block from interrupting a
        # paragraph, but it MAY start after a heading / thematic break /
        # blank line).
        prev_paragraph = is_paragraph_line(line, is_blank, indented)
    return "\n".join(out)


def codespan_ranges(text: str) -> list[tuple[int, int]]:
    return [(m.start(), m.end()) for m in _CODESPAN_RE.finditer(text)]


def inside_codespan(pos: int, ranges: list[tuple[int, int]]) -> bool:
    for start, end in ranges:
        if start <= pos < end:
            return True
        if start > pos:
            break
    return False


def iter_wikilinks(text: str):
    """Yield (surface_form, position) for each [[...]] not in code.

    surface_form is the part BEFORE any ``|`` or ``#`` (i.e. the link target).

    Code regions are excluded before matching: fenced code blocks and
    indented (4-space / tab) code blocks are blanked first (length-
    preserving so positions stay aligned), then inline codespans are
    skipped via ``codespan_ranges``. A real markdown wikilink never lives
    inside any of those. As a final defensive guard, surfaces shaped like a
    POSIX character class (``:space:`` from ``[[:space:]]``) are rejected —
    those are shell/grep fragments, not links.
    """
    scan_text = blank_indented_code(blank_fenced_code(text))
    ranges = codespan_ranges(scan_text)
    for match in _WIKILINK_RE.finditer(scan_text):
        if inside_codespan(match.start(), ranges):
            continue
        surface = match.group(1).strip()
        if not surface:
            continue
        if _POSIX_CLASS_RE.match(surface):
            continue
        yield surface, match.start()


def walk_wiki(wiki: Path):
    """Yield Path objects for every ``*.md`` under wiki, excluding
    top-level underscored / dotfile subtrees that are not content."""
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in _SKIP_TOP_DIRS:
            continue
        yield path


# ---------------------------------------------------------------------------
# DB
# ---------------------------------------------------------------------------


def open_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.row_factory = sqlite3.Row
    for stmt in SCHEMA_DDL:
        conn.execute(stmt)
    conn.execute(
        "INSERT OR REPLACE INTO schema_meta(key, value) VALUES(?, ?)",
        ("schema_version", str(SCHEMA_VERSION)),
    )
    conn.commit()
    return conn


def reset_tables(conn: sqlite3.Connection) -> None:
    for table in ("aliases", "mentions", "unresolved", "entities"):
        conn.execute(f"DELETE FROM {table}")
    conn.commit()


# ---------------------------------------------------------------------------
# Pass 1: Build entity/alias registry
# ---------------------------------------------------------------------------


def build_alias_registry(conn: sqlite3.Connection, wiki: Path) -> int:
    """Walk every wiki file; for each with a ``slug`` frontmatter, register
    the slug itself + every alias + the filename stem as lookup keys.

    Redirect stubs (``type: redirect`` with a ``redirect_to`` pointer)
    contribute their aliases to the redirect target, not to themselves —
    otherwise their local slug competes with the canonical and steals
    cross-agent references. If the stub has no ``redirect_to`` field
    (malformed), it falls back to registering itself.

    Files without ``slug`` contribute nothing to the registry but still
    participate as mention sources in Pass 2.
    """
    entity_rows: list[tuple] = []
    alias_rows: list[tuple] = []
    seen_slugs: set[str] = set()
    now = now_iso()

    for path in walk_wiki(wiki):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        fm = parse_frontmatter(text)
        if not fm:
            continue
        slug = fm.get("slug")
        if not isinstance(slug, str) or not slug:
            continue
        rel = path.relative_to(wiki)
        entity_type = fm.get("type") or ""
        title = fm.get("title") or ""

        # Redirect short-circuit: point every alias at the redirect target
        # slug (derived from the ``redirect_to`` frontmatter, if present).
        # Legacy wiki-entity-lifecycle docs used ``moved_to`` for the
        # same pointer; honor both so older installs don't have to
        # rewrite their redirect stubs during upgrade.
        redirect_target_slug = ""
        if entity_type == "redirect":
            redirect_to = (
                fm.get("redirect_to") or fm.get("moved_to") or ""
            )
            if isinstance(redirect_to, str) and redirect_to:
                # ``redirect_to`` is a wiki-relative path or slug. Take the
                # last path segment as the target slug.
                redirect_target_slug = redirect_to.rsplit("/", 1)[-1]
                redirect_target_slug = redirect_target_slug.rsplit(".", 1)[0]

        # Determine hub scope: 'shared' if the canonical file itself lives
        # under a shared top-level dir (entities/, people/, concepts/, etc.
        # — NOT under agents/).
        rel_parts = rel.parts
        if rel_parts and rel_parts[0] != "agents":
            hub_scope = "shared"
            hub_path = str(rel)
        else:
            hub_scope = "agent"
            hub_path = ""  # agent-scoped canonical, not a shared hub
        if slug not in seen_slugs:
            seen_slugs.add(slug)
            entity_rows.append(
                (slug, title, entity_type, hub_path, hub_scope, now, now, now)
            )
        elif hub_scope == "shared":
            # A later shared hub promotes existing agent-scoped entity
            # record — overwrite hub_path/hub_scope on next merge pass.
            entity_rows.append(
                (slug, title, entity_type, hub_path, hub_scope, now, now, now)
            )

        # Register aliases + slug self + filename stem. For redirects the
        # target_slug is used so aliases map to the canonical, not the stub.
        alias_target = redirect_target_slug or slug
        seen_aliases: set[str] = set()
        to_register: list[str] = [slug, path.stem]
        aliases_field = fm.get("aliases") or []
        if isinstance(aliases_field, list):
            to_register.extend(str(a) for a in aliases_field if a)
        for surface in to_register:
            norm = normalize_surface(surface)
            if not norm or norm in seen_aliases:
                continue
            seen_aliases.add(norm)
            alias_rows.append((norm, surface, alias_target, str(rel)))

    cursor = conn.cursor()
    # Upsert entity rows. Use INSERT OR REPLACE on primary key.
    for row in entity_rows:
        cursor.execute(
            "INSERT OR REPLACE INTO entities "
            "(slug, title, type, hub_path, hub_scope, first_seen_at, last_seen_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, "
            "COALESCE((SELECT first_seen_at FROM entities WHERE slug=?), ?), "
            "?, ?)",
            (
                row[0],
                row[1],
                row[2],
                row[3],
                row[4],
                row[0],
                row[5],
                row[6],
                row[7],
            ),
        )
    # Alias rows: INSERT OR IGNORE — last writer doesn't win; first declaration wins
    cursor.executemany(
        "INSERT OR IGNORE INTO aliases "
        "(alias_normalized, alias_surface, entity_slug, source_path) "
        "VALUES (?, ?, ?, ?)",
        alias_rows,
    )
    conn.commit()
    return len(seen_slugs)


def load_alias_lookup(conn: sqlite3.Connection) -> dict[str, str]:
    """Return {alias_normalized: entity_slug}.

    When the same surface form is registered against multiple slugs (e.g.
    both ``shared/wiki/entities/cosmax.md`` and
    ``agents/syrs-production/entities/코스맥스.md`` claim ``코스맥스`` as an
    alias), the shared-scoped canonical hub wins. This mirrors the
    ``wiki-entity-lifecycle.md`` policy: shared hubs are the team-level
    source of truth; agent namespaces are views.
    """
    # Pull conflicts: same alias_normalized but multiple entity_slugs.
    out: dict[str, str] = {}
    shared_slugs: set[str] = set()
    for row in conn.execute(
        "SELECT slug FROM entities WHERE hub_scope='shared'"
    ):
        shared_slugs.add(row["slug"])
    pending: dict[str, list[str]] = defaultdict(list)
    for row in conn.execute(
        "SELECT alias_normalized, entity_slug FROM aliases"
    ):
        pending[row["alias_normalized"]].append(row["entity_slug"])
    for alias, candidates in pending.items():
        if len(candidates) == 1:
            out[alias] = candidates[0]
            continue
        # Prefer a shared-hub slug over agent-scoped duplicates.
        shared = [c for c in candidates if c in shared_slugs]
        if shared:
            out[alias] = shared[0]
        else:
            # No shared hub exists — keep the first registration.
            out[alias] = candidates[0]
    return out


def load_path_index(wiki: Path) -> tuple[set[str], dict[str, str]]:
    """Return (path_set, stem_map) for wikilink fallback resolution.

    - ``path_set`` holds every wiki-relative path sans ``.md`` suffix
      (e.g. ``agents/syrs-warehouse/entities/tracx``). A wikilink with
      this form resolves to that file regardless of frontmatter aliases.

    - ``stem_map`` maps a filename stem to its relative path (without
      ``.md``). Multiple files with the same stem produce an ambiguous
      entry (value prefixed with ``__ambiguous__``); callers should
      treat ambiguous stems as unresolved until dedup.
    """
    path_set: set[str] = set()
    stem_seen: dict[str, str] = {}
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in _SKIP_TOP_DIRS:
            continue
        rel_no_ext = str(rel).removesuffix(".md")
        path_set.add(rel_no_ext)
        stem = path.stem
        if stem in stem_seen:
            if not stem_seen[stem].startswith("__ambiguous__"):
                stem_seen[stem] = "__ambiguous__"
        else:
            stem_seen[stem] = rel_no_ext
    return path_set, stem_seen


# ---------------------------------------------------------------------------
# Pass 2: Scan mentions
# ---------------------------------------------------------------------------


def load_indexed_paths(conn: sqlite3.Connection) -> set[str]:
    """Return the set of source_path values already present in mentions.

    Used so incremental scans also catch NEW wiki files whose mtime is
    older than the last scan cutoff (e.g. files copied with
    ``shutil.copy2`` preserve source mtime).
    """
    return {
        row[0]
        for row in conn.execute("SELECT DISTINCT source_path FROM mentions")
    }


def scan_mentions(
    conn: sqlite3.Connection,
    wiki: Path,
    alias_lookup: dict[str, str],
    path_set: set[str],
    stem_map: dict[str, str],
    since_mtime: int | None = None,
) -> tuple[int, int, int]:
    """Walk wiki, record (source_path × entity_slug × surface_form) rows.

    Resolution order for each [[surface]]:
      1. alias_lookup[normalized_surface]
      2. path_set exact match (surface is a file path like
         ``agents/x/entities/y``) — returns a path, not a slug. We store
         the path-based resolution as a pseudo-slug ``path:<relpath>``.
      3. stem_map[surface_stem] — unique filename match, stored as
         ``path:<relpath>``.
      4. Otherwise: unresolved.

    Returns (files_scanned, mentions_upserted, unresolved_upserted).
    """
    files_scanned = 0
    mention_upserts = 0
    unresolved_upserts = 0
    now = now_iso()
    cursor = conn.cursor()

    # For incremental scans we need to catch both
    #   (a) files whose mtime is newer than the last scan cutoff, AND
    #   (b) files newly added to the wiki tree that still carry an older
    #       mtime (e.g. ``shutil.copy2`` byte-replicas preserve source mtime).
    # Passing None as since_mtime disables the cutoff entirely (full scan).
    indexed_paths = load_indexed_paths(conn) if since_mtime is not None else set()

    for path in walk_wiki(wiki):
        rel = path.relative_to(wiki)
        try:
            st = path.stat()
        except OSError:
            continue
        if since_mtime is not None:
            is_new_to_index = str(rel) not in indexed_paths
            if st.st_mtime < since_mtime and not is_new_to_index:
                continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        files_scanned += 1
        source_agent, source_kind = classify_source(rel)
        # First, delete prior mention rows for this source so stale links
        # from edits drop out cleanly.
        cursor.execute(
            "DELETE FROM mentions WHERE source_path = ?", (str(rel),)
        )
        cursor.execute(
            "DELETE FROM unresolved WHERE source_path = ?", (str(rel),)
        )
        # Aggregate surface-form counts within this file.
        counts: dict[tuple[str, str | None, str], int] = defaultdict(int)
        unresolved_counts: dict[str, int] = defaultdict(int)
        for surface, _pos in iter_wikilinks(text):
            norm = normalize_surface(surface)
            slug = alias_lookup.get(norm)
            if not slug:
                # Path-qualified fallback: surface may be a full relative
                # path like ``agents/x/entities/y``. Compare with/without
                # a trailing .md suffix.
                path_key = surface.removesuffix(".md")
                if path_key in path_set:
                    slug = f"path:{path_key}"
            if not slug and "/" not in surface:
                # Stem-only fallback: surface is a bare filename stem.
                mapped = stem_map.get(surface)
                if mapped and not mapped.startswith("__ambiguous__"):
                    slug = f"path:{mapped}"
            if slug:
                counts[(slug, surface, norm)] += 1
            else:
                unresolved_counts[surface] += 1
        for (slug, surface, _norm), count in counts.items():
            cursor.execute(
                "INSERT OR REPLACE INTO mentions "
                "(source_path, source_agent, source_kind, source_mtime, "
                " entity_slug, surface_form, mention_count, scanned_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    str(rel),
                    source_agent,
                    source_kind,
                    int(st.st_mtime),
                    slug,
                    surface,
                    count,
                    now,
                ),
            )
            mention_upserts += 1
        for surface, _count in unresolved_counts.items():
            cursor.execute(
                "INSERT OR REPLACE INTO unresolved "
                "(source_path, surface_form, surface_normalized, scanned_at) "
                "VALUES (?, ?, ?, ?)",
                (
                    str(rel),
                    surface,
                    normalize_surface(surface),
                    now,
                ),
            )
            unresolved_upserts += 1
        # Bump entities.last_seen_at for any real slug we saw (skip
        # path-resolved pseudo-slugs; those aren't in entities).
        touched = {k[0] for k in counts.keys() if not k[0].startswith("path:")}
        for slug in touched:
            cursor.execute(
                "UPDATE entities SET last_seen_at = ? WHERE slug = ?",
                (now, slug),
            )
    conn.commit()
    return files_scanned, mention_upserts, unresolved_upserts


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def render_report(conn: sqlite3.Connection) -> str:
    """Produce the distribution report used to decide Phase 2 thresholds.

    Sections:
      1. Summary counts
      2. Top entities by cross-agent count (≥2 distinct agents)
      3. Entities mentioned but no shared hub
      4. Top unresolved wikilinks (potential missing entities)
      5. Orphan entities (slug declared but zero inbound mentions)
    """
    lines: list[str] = []
    append = lines.append

    total_entities = conn.execute(
        "SELECT COUNT(*) FROM entities"
    ).fetchone()[0]
    total_aliases = conn.execute("SELECT COUNT(*) FROM aliases").fetchone()[0]
    total_mentions = conn.execute(
        "SELECT COUNT(*) FROM mentions"
    ).fetchone()[0]
    total_mention_count = conn.execute(
        "SELECT COALESCE(SUM(mention_count), 0) FROM mentions"
    ).fetchone()[0]
    total_unresolved = conn.execute(
        "SELECT COUNT(*) FROM unresolved"
    ).fetchone()[0]
    distinct_agents = conn.execute(
        "SELECT COUNT(DISTINCT source_agent) FROM mentions"
    ).fetchone()[0]
    shared_hubs = conn.execute(
        "SELECT COUNT(*) FROM entities WHERE hub_scope='shared'"
    ).fetchone()[0]

    append("# Wiki mention distribution report")
    append("")
    append(f"- generated: {now_iso()}")
    append(f"- entities_registered: {total_entities}")
    append(f"- shared_hubs: {shared_hubs}")
    append(f"- aliases_total: {total_aliases}")
    append(f"- mention_edges: {total_mentions}")
    append(f"- mention_occurrences: {total_mention_count}")
    append(f"- unresolved_wikilinks: {total_unresolved}")
    append(f"- distinct_source_agents: {distinct_agents}")
    append("")

    append("## 1. Entities by cross-agent reach (top 40)")
    append("")
    append("| Entity | Agents | Mentions | Hub | Type |")
    append("|---|---|---|---|---|")
    rows = conn.execute(
        """
        SELECT e.slug, e.title, e.type, e.hub_scope, e.hub_path,
               COUNT(DISTINCT m.source_agent) AS agent_count,
               COALESCE(SUM(m.mention_count), 0) AS total_mentions
        FROM entities e
        LEFT JOIN mentions m ON m.entity_slug = e.slug
        GROUP BY e.slug
        HAVING agent_count >= 1
        ORDER BY agent_count DESC, total_mentions DESC, e.slug
        LIMIT 40
        """
    ).fetchall()
    for row in rows:
        hub_marker = "✓ shared" if row["hub_scope"] == "shared" else "—"
        append(
            f"| `{row['slug']}` | {row['agent_count']} | {row['total_mentions']} | "
            f"{hub_marker} | {row['type'] or ''} |"
        )
    append("")

    append("## 2. Entities without shared hub, but cross-agent mentioned (top 40)")
    append("")
    append("These are hub-build candidates for Phase 2.")
    append("")
    append("| Entity | Agents | Mentions | Current hub_scope |")
    append("|---|---|---|---|")
    rows = conn.execute(
        """
        SELECT e.slug, e.hub_scope,
               COUNT(DISTINCT m.source_agent) AS agent_count,
               COALESCE(SUM(m.mention_count), 0) AS total_mentions
        FROM entities e
        JOIN mentions m ON m.entity_slug = e.slug
        WHERE e.hub_scope != 'shared' OR e.hub_scope IS NULL
        GROUP BY e.slug
        HAVING agent_count >= 2
        ORDER BY agent_count DESC, total_mentions DESC, e.slug
        LIMIT 40
        """
    ).fetchall()
    for row in rows:
        append(
            f"| `{row['slug']}` | {row['agent_count']} | "
            f"{row['total_mentions']} | {row['hub_scope'] or '—'} |"
        )
    append("")

    append("## 3. Top unresolved wikilinks (potential missing entities)")
    append("")
    append(
        "Surface forms that have no matching `aliases` entry in any "
        "frontmatter. These are candidates for stub creation."
    )
    append("")
    append("| Surface | Occurrences | Distinct sources |")
    append("|---|---|---|")
    rows = conn.execute(
        """
        SELECT surface_normalized,
               MAX(surface_form) AS surface_form,
               COUNT(*) AS source_count
        FROM unresolved
        GROUP BY surface_normalized
        ORDER BY source_count DESC, surface_normalized
        LIMIT 40
        """
    ).fetchall()
    for row in rows:
        append(
            f"| `{row['surface_form']}` | {row['source_count']} | "
            f"{row['source_count']} |"
        )
    append("")

    append("## 4. Orphan entity slugs (declared but unreferenced)")
    append("")
    rows = conn.execute(
        """
        SELECT e.slug, e.hub_scope
        FROM entities e
        LEFT JOIN mentions m ON m.entity_slug = e.slug
        WHERE m.entity_slug IS NULL
        ORDER BY e.slug
        LIMIT 40
        """
    ).fetchall()
    if rows:
        append("| Entity | Hub scope |")
        append("|---|---|")
        for row in rows:
            append(f"| `{row['slug']}` | {row['hub_scope'] or '—'} |")
    else:
        append("_None._")
    append("")

    append("## 5. Agent-scope activity breakdown")
    append("")
    append("| Agent | Distinct entities | Mention edges | Mention count |")
    append("|---|---|---|---|")
    rows = conn.execute(
        """
        SELECT source_agent,
               COUNT(DISTINCT entity_slug) AS distinct_entities,
               COUNT(*) AS mention_edges,
               COALESCE(SUM(mention_count), 0) AS occurrences
        FROM mentions
        GROUP BY source_agent
        ORDER BY mention_edges DESC, source_agent
        """
    ).fetchall()
    for row in rows:
        append(
            f"| `{row['source_agent']}` | {row['distinct_entities']} | "
            f"{row['mention_edges']} | {row['occurrences']} |"
        )
    append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def cmd_scan(args: argparse.Namespace) -> int:
    wiki = resolve_wiki_root(args.wiki_root)
    if not wiki.exists():
        print(f"[error] wiki root not found: {wiki}", file=sys.stderr)
        return 1
    db_path = wiki / "_index" / "mentions.db"
    conn = open_db(db_path)
    mode = "full" if args.full_rebuild else "incremental"
    started = now_iso()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO scans (started_at, mode) VALUES (?, ?)",
        (started, mode),
    )
    scan_id = cur.lastrowid
    conn.commit()

    error: str | None = None
    try:
        if args.full_rebuild:
            reset_tables(conn)
        entities_seen = build_alias_registry(conn, wiki)
        alias_lookup = load_alias_lookup(conn)
        path_set, stem_map = load_path_index(wiki)
        if args.incremental and not args.full_rebuild:
            # Use last successful scan's finished_at as cutoff.
            cutoff = conn.execute(
                "SELECT MAX(CAST(strftime('%s', finished_at) AS INTEGER)) "
                "FROM scans WHERE finished_at IS NOT NULL AND error IS NULL"
            ).fetchone()[0]
            since_mtime = cutoff or 0
        else:
            since_mtime = None
        files_scanned, mention_upserts, unresolved_upserts = scan_mentions(
            conn,
            wiki,
            alias_lookup,
            path_set,
            stem_map,
            since_mtime=since_mtime,
        )
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
        conn.execute(
            "UPDATE scans SET finished_at=?, error=? WHERE id=?",
            (now_iso(), error, scan_id),
        )
        conn.commit()
        print(f"[error] {error}", file=sys.stderr)
        return 2
    conn.execute(
        "UPDATE scans SET finished_at=?, files_scanned=?, entities_seen=?, "
        "mentions_new=?, unresolved_new=? WHERE id=?",
        (
            now_iso(),
            files_scanned,
            entities_seen,
            mention_upserts,
            unresolved_upserts,
            scan_id,
        ),
    )
    conn.commit()
    summary = {
        "scan_id": scan_id,
        "mode": mode,
        "files_scanned": files_scanned,
        "entities_seen": entities_seen,
        "mentions_new": mention_upserts,
        "unresolved_new": unresolved_upserts,
        "db_path": str(db_path),
    }
    print(json.dumps(summary, ensure_ascii=False))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    wiki = resolve_wiki_root(args.wiki_root)
    db_path = wiki / "_index" / "mentions.db"
    if not db_path.exists():
        print(
            f"[error] no mentions.db found; run --full-rebuild first: {db_path}",
            file=sys.stderr,
        )
        return 1
    conn = open_db(db_path)
    report = render_report(conn)
    if args.out:
        out_path = Path(args.out).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(report, encoding="utf-8")
        print(f"report written: {out_path}")
    else:
        sys.stdout.write(report)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wiki-mention-scan",
        description=(
            "Scan Agent Bridge shared/wiki/ for [[wikilink]] mentions and "
            "index them to shared/wiki/_index/mentions.db. L1 observation "
            "layer for the entity-graph automation pipeline."
        ),
    )
    parser.add_argument(
        "--wiki-root",
        help="Override wiki root (default: resolve_wiki_root logic).",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--full-rebuild",
        action="store_true",
        help="Drop mention tables and rescan every file from scratch.",
    )
    mode.add_argument(
        "--incremental",
        action="store_true",
        help="Only rescan files modified since last successful scan.",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help=(
            "Emit the distribution report instead of scanning. Use after a "
            "scan. Combine with --out to write to a file."
        ),
    )
    parser.add_argument(
        "--out",
        help="Target path for --report output (default: stdout).",
    )
    args = parser.parse_args(argv)

    if args.report:
        return cmd_report(args)
    # Default to incremental if neither flag given.
    if not args.full_rebuild and not args.incremental:
        args.incremental = True
    return cmd_scan(args)


if __name__ == "__main__":
    sys.exit(main())
