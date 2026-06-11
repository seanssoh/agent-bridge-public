#!/usr/bin/env python3
"""No-LLM picker detector / policy resolver core for Agent Bridge (#1762).

This is the structured (data) half of the picker auto-resolve feature. The
shell stage (lib/bridge-picker.sh, driven from the daemon tick) owns ALL tmux
interaction; this module never touches tmux. It is invoked file-as-argv with a
subcommand (no heredoc-stdin — footgun #11) and exchanges JSON on stdout.

Subcommands
-----------
classify  --engine <e> --pane-file <f> [--catalog <c> ...] [--local-catalog <c>]
    Match the captured pane text against the catalog. Emits a JSON decision:
    {"matched": bool, "picker_id": ..., "policy": ..., "engine": ...,
     "keys": [...], "post_resolve_verify": bool, "expect_restart": bool,
     "destructive_match": [...], "defer_to": ..., "escalation_route": ...,
     "confidence": ..., "non_picker": bool, "pane_hash": "..."}.
    A non_picker entry (e.g. the status-line banner) reports matched=False so
    it can never register as stuck.

tick  --session <s> --engine <e> --picker-id <p> --pane-hash <h>
      [--stuck-confirm-ticks N] [--state-dir <d>]
    Advance the per-session stuck-confirmation state machine. A picker is
    "stuck" only when the SAME picker_id is present for N consecutive ticks
    AND the pane hash is unchanged across them. Emits {"stuck": bool,
    "ticks": N, "first_seen": epoch}. Any change of picker_id, pane hash, or a
    tick with no match resets the counter.

antiloop  --session <s> --picker-id <p> [--window-seconds W] [--max-resolves M]
          [--state-dir <d>]
    Record a resolution attempt and report whether the anti-loop ceiling is
    tripped: the same (session, picker_id) resolved >= M times within the last
    W seconds. Emits {"tripped": bool, "count": N}. When tripped the caller
    must ESCALATE instead of re-keying.

unknown-tick  --session <s> --pane-hash <h> [--stuck-minutes M] [--min-ticks N]
              [--state-dir <d>]
    Advance the per-session UNKNOWN-pane state machine (the novel-screen path).
    A pane that matched no catalog entry but looks prompt-like is "unknown-stuck"
    only when the SAME pane hash persists across >= N consecutive unknown ticks
    AND for at least M minutes of wall-clock time since first_seen. Emits
    {"stuck": bool, "ticks": N, "first_seen": epoch, "elapsed": secs}. A changing
    pane hash resets the counter. Layer-3 escalation (picker_id=unknown) fires
    only when this reports stuck=true.

clear-state  --session <s> [--state-dir <d>]
    Drop the stuck-confirmation state for a session (called after a successful
    resolution or when the session clears) so the next encounter starts fresh.

clear-unknown  --session <s> [--state-dir <d>]
    Drop the UNKNOWN-pane state for a session (called when the pane changes, a
    catalog entry matches, or after an unknown escalation fires) so the next
    novel screen starts fresh.

audit-line  --kw key=value [--kw key=value ...]
    Emit a single canonical JSON object (one line) for the audit log. Values
    are passed as key=value pairs; the caller appends the line to audit.jsonl.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any


# --------------------------------------------------------------------------
# Catalog loading + merge
# --------------------------------------------------------------------------
def _load_one(path: str) -> dict[str, Any] | None:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    return data


def load_catalog(paths: list[str], local_path: str | None) -> dict[str, Any]:
    """Merge shipped catalogs (in order) + an optional install-local catalog.

    Entries are keyed by picker_id; a later source overrides an earlier one
    with the same id (local overrides shipped). Defaults likewise merge with
    later sources winning. A missing/invalid file is skipped silently so a
    typo in one override can never wedge detection.
    """
    defaults: dict[str, Any] = {
        "stuck_confirm_ticks": 2,
        "antiloop_window_seconds": 120,
        "antiloop_max_resolves": 3,
        "unknown_stuck_minutes": 5,
    }
    by_id: dict[str, dict[str, Any]] = {}
    order: list[str] = []

    sources = list(paths)
    if local_path:
        sources.append(local_path)

    for src in sources:
        data = _load_one(src)
        if data is None:
            continue
        src_defaults = data.get("defaults")
        if isinstance(src_defaults, dict):
            for key, val in src_defaults.items():
                if isinstance(val, int):
                    defaults[key] = val
        entries = data.get("entries")
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            pid = entry.get("picker_id")
            if not isinstance(pid, str) or not pid:
                continue
            if pid not in by_id:
                order.append(pid)
            by_id[pid] = entry

    return {"defaults": defaults, "entries": [by_id[p] for p in order]}


# --------------------------------------------------------------------------
# Fingerprint matching
# --------------------------------------------------------------------------
def _all_regexes_present(text: str, patterns: list[Any]) -> bool:
    for pat in patterns:
        if not isinstance(pat, str):
            return False
        try:
            if re.search(pat, text) is None:
                return False
        except re.error:
            # A malformed regex in a data file must never crash the daemon; a
            # pattern that cannot compile simply does not match.
            return False
    return True


def pane_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()[:16]


# Box-drawing glyphs stripped when checking whether a selector caret is followed
# by real option text (so '│ ❯ Option │' counts, '│ ❯      │' does not).
_BOX_GLYPHS = "│┃|╮╯╭╰┐┘┌└─━"

# Case-insensitive whole-pane confirm/affordance tokens that mark an interactive
# prompt regardless of which engine rendered it.
_AFFORDANCE_TOKENS = (
    "[y/n]",
    "(y/n)",
    "press enter",
    "enter to ",
    "to continue",
    "↑/↓",
    "↑↓",
)
# "press <key> to <verb>" / "hit <key> to <verb>" style affordances.
_AFFORDANCE_RE = re.compile(r"\b(?:press|hit)\b.*\bto\b", re.IGNORECASE)
# A numbered option-list row: optional indent, a 1-2 digit run, '.'/')' , space,
# then real text.
_NUMBERED_OPTION_RE = re.compile(r"(?m)^\s*\d{1,2}[.)]\s+\S")


def _caret_has_option_text(line: str) -> bool:
    """True if a selector caret (❯/›) on this line is followed by real option
    text (box-drawing chars stripped). An empty idle composer renders the caret
    with only spaces / a closing border after it, so it returns False."""
    for caret in ("❯", "›"):
        idx = line.find(caret)
        if idx == -1:
            continue
        rest = line[idx + len(caret):]
        rest = "".join(" " if ch in _BOX_GLYPHS else ch for ch in rest)
        if rest.strip():
            return True
    return False


def _pane_has_picker_affordance(text: str, *, single_caret: bool = False) -> bool:
    """True if `text` contains ANY interactive picker affordance.

    Signals: a numbered option list ('1. Yes' / '2) No'); an explicit
    [y/n] / Press-<key> / 'to continue' / arrow affordance; a line-leading ASCII
    '>' menu marker with option text; or a selector caret (❯/›) followed by
    option text.

    `single_caret` controls how many caret-with-text rows count as a menu:
      - False (default, whole-pane scan): a SINGLE caret-with-text line is the
        engine's own idle composer (claude's is empty so it never trips this;
        codex's idle '› <ghost text>' would), so it requires >=2 caret rows to
        avoid mis-flagging a pure idle composer.
      - True: ONE caret-with-text line is enough. Use this only on the region
        BELOW the idle composer line (see _idle_ready_tail_clear), where the
        composer itself has been excluded — there a single highlighted option
        ('❯ Continue' with the alternative on an unmarked row) is a real picker.
    """
    lower = text.lower()
    for tok in _AFFORDANCE_TOKENS:
        if tok in lower:
            return True
    if _AFFORDANCE_RE.search(text):
        return True
    if _NUMBERED_OPTION_RE.search(text) is not None:
        return True
    need_carets = 1 if single_caret else 2
    caret_option_lines = 0
    for line in text.splitlines():
        # Line-leading ASCII '>' menu marker with option text ('> Continue').
        stripped = line.lstrip()
        if stripped.startswith(">") and stripped[1:].strip():
            return True
        if _caret_has_option_text(line):
            caret_option_lines += 1
            if caret_option_lines >= need_carets:
                return True
    return False


def _idle_ready_tail_clear(pane_text: str, patterns: list[Any]) -> bool:
    """Decide whether an idle `non_picker` entry may short-circuit on this pane.

    Composite-pane guard (#1783), tail-scoped to avoid two opposite failures:
      - a GENUINE novel picker rendered as the live foreground must escalate, so
        the idle entry must NOT hard-exclude it; but
      - ordinary STALE scrollback (a numbered list / 'press enter' from prior
        output) ABOVE a live idle ready composer/footer must NOT escalate — the
        session is simply at the ready prompt.
    In a real Claude/Codex TUI a live picker is the BOTTOM-most element (it
    replaces the composer); when idle, the composer/footer is the bottom. So the
    idle entry may short-circuit only when there is NO picker affordance at or
    BELOW the idle composer line (`idle_start` = the earliest of the idle
    patterns' last matches; the composer line is the line containing it). A
    picker affordance ABOVE that line is scrollback and ignored.

    The idle composer's OWN line is EXCLUDED before the affordance check, so the
    region below it is scanned with single-caret sensitivity: a single
    highlighted option ('❯ Continue' with the alternative on an unmarked row) IS
    a real foreground picker and escalates. A pure idle pane has nothing
    option-shaped below the composer, so it stays non_picker.
    """
    starts: list[int] = []
    for pat in patterns:
        if not isinstance(pat, str):
            return False
        try:
            first = re.search(pat, pane_text)
        except re.error:
            return False
        if first is None:
            return False
        starts.append(first.start())
    if not starts:
        return False
    # Anchor on the EARLIEST idle-signature occurrence. Using the FIRST match
    # (not the last) matters when picker option rows happen to also satisfy the
    # composer regex (e.g. codex options that contain a '/'-command): the first
    # such row becomes idle_start and any further option rows fall BELOW it, so
    # they are detected as foreground affordance and the pane escalates instead
    # of being mis-excluded (codex review #1783 P1 adversarial case).
    idle_start = min(starts)
    # Drop the idle composer's OWN line (the line containing idle_start) so its
    # caret/ghost text is not mistaken for an option, then scan the region BELOW
    # it with single-caret sensitivity. Anything above idle_start is scrollback.
    region = pane_text[idle_start:]
    newline = region.find("\n")
    below_composer = region[newline + 1:] if newline != -1 else ""
    return not _pane_has_picker_affordance(below_composer, single_caret=True)


def classify(
    engine: str,
    pane_text: str,
    catalog: dict[str, Any],
) -> dict[str, Any]:
    """Return the first catalog entry whose fingerprint matches the pane.

    A `non_picker` entry that matches reports matched=False (it is a context
    signal, not a stuck state) so it can shadow a noisier picker fingerprint
    and guarantee the banner never registers as stuck.

    Composite-pane guard (#1783): an IDLE `non_picker` entry is SKIPPED (does not
    short-circuit) when a genuine picker is the live foreground — see
    _idle_ready_tail_clear. A non-idle `non_picker` banner (e.g. the
    Auto-update-failed status line) short-circuits as before.
    """
    result: dict[str, Any] = {
        "matched": False,
        "picker_id": "",
        "policy": "",
        "engine": engine,
        "keys": [],
        "post_resolve_verify": False,
        "expect_restart": False,
        "destructive_match": [],
        "defer_to": "",
        "escalation_route": "",
        "confidence": "",
        "non_picker": False,
        "pane_hash": pane_hash(pane_text),
    }

    for entry in catalog.get("entries", []):
        if not entry.get("enabled", False):
            continue
        entry_engine = entry.get("engine", "any")
        if entry_engine not in ("any", engine):
            continue
        patterns = entry.get("match")
        if not isinstance(patterns, list) or not patterns:
            continue
        if not _all_regexes_present(pane_text, patterns):
            continue

        policy = entry.get("policy", "")
        # A non_picker context signal short-circuits: report a match for
        # observability (picker_id surfaced) but matched=False + non_picker so
        # the caller never treats it as stuck. EXCEPT idle-ready entries that opt
        # into the foreground guard (#1783): they may only short-circuit when the
        # idle composer/footer is the live tail with no foreground picker — a real
        # picker stacked as the foreground must still reach the unknown path
        # instead of being hard-excluded. A non-idle banner (foreground_guard
        # absent, e.g. Auto-update-failed) short-circuits unconditionally.
        if policy == "non_picker":
            if entry.get("foreground_guard") and not _idle_ready_tail_clear(
                pane_text, patterns
            ):
                continue
            result["picker_id"] = entry.get("picker_id", "")
            result["policy"] = policy
            result["non_picker"] = True
            result["confidence"] = entry.get("confidence", "")
            return result

        result["matched"] = True
        result["picker_id"] = entry.get("picker_id", "")
        result["policy"] = policy
        keys = entry.get("keys")
        result["keys"] = keys if isinstance(keys, list) else []
        result["post_resolve_verify"] = bool(entry.get("post_resolve_verify", False))
        result["expect_restart"] = bool(entry.get("expect_restart", False))
        dm = entry.get("destructive_match")
        result["destructive_match"] = dm if isinstance(dm, list) else []
        result["defer_to"] = entry.get("defer_to", "")
        result["escalation_route"] = entry.get("escalation_route", "")
        result["confidence"] = entry.get("confidence", "")
        return result

    return result


# --------------------------------------------------------------------------
# Per-session state (stuck-confirmation + anti-loop)
# --------------------------------------------------------------------------
def _safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)[:128] or "_"


def _state_dir(explicit: str | None) -> Path:
    if explicit:
        base = Path(explicit)
    else:
        root = (
            os.environ.get("BRIDGE_STATE_DIR")  # noqa: iso-helper-boundary — ordinary env read; "os.environ" substring-matches the \.env ratchet pattern, not a controller->iso boundary crossing
            or os.path.join(os.environ.get("BRIDGE_HOME", "/tmp"), "state")  # noqa: iso-helper-boundary — same: env read, no iso boundary
        )
        base = Path(root) / "picker"
    base.mkdir(parents=True, exist_ok=True)
    return base


def _read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload), encoding="utf-8")
    os.replace(tmp, path)


def cmd_tick(args: argparse.Namespace) -> dict[str, Any]:
    state_dir = _state_dir(args.state_dir)
    path = state_dir / f"{_safe_name(args.session)}.stuck.json"
    now = int(time.time())
    cur = _read_json(path)

    same = (
        cur.get("picker_id") == args.picker_id
        and cur.get("pane_hash") == args.pane_hash
    )
    if same:
        ticks = int(cur.get("ticks", 0)) + 1
        first_seen = int(cur.get("first_seen", now))
    else:
        ticks = 1
        first_seen = now

    _write_json(
        path,
        {
            "picker_id": args.picker_id,
            "pane_hash": args.pane_hash,
            "ticks": ticks,
            "first_seen": first_seen,
            "updated": now,
        },
    )
    need = max(1, int(args.stuck_confirm_ticks))
    return {"stuck": ticks >= need, "ticks": ticks, "first_seen": first_seen}


def cmd_unknown_tick(args: argparse.Namespace) -> dict[str, Any]:
    """Track an UNKNOWN (no catalog match) prompt-like pane across ticks.

    Mirrors cmd_tick but for the novel-screen path: a pane that matched no
    catalog entry but looks prompt-like. A pane is "unknown-stuck" only when the
    SAME pane hash has persisted across >= `min_ticks` consecutive unknown ticks
    AND for at least `stuck_minutes` of wall-clock time since first_seen. Any
    change of pane hash resets the counter (the agent is making progress); a tick
    that does not pass the prompt-like gate is handled by the caller clearing the
    state. This is what makes Layer-3 escalation real for genuinely novel screens
    instead of dead code.

    Emits {"stuck": bool, "ticks": N, "first_seen": epoch, "elapsed": secs}.
    """
    state_dir = _state_dir(args.state_dir)
    path = state_dir / f"{_safe_name(args.session)}.unknown.json"
    now = int(time.time())
    cur = _read_json(path)

    same = cur.get("pane_hash") == args.pane_hash
    if same:
        ticks = int(cur.get("ticks", 0)) + 1
        first_seen = int(cur.get("first_seen", now))
    else:
        ticks = 1
        first_seen = now

    _write_json(
        path,
        {
            "pane_hash": args.pane_hash,
            "ticks": ticks,
            "first_seen": first_seen,
            "updated": now,
        },
    )
    elapsed = now - first_seen
    stuck_minutes = max(0, int(args.stuck_minutes))
    min_ticks = max(1, int(args.min_ticks))
    stuck = ticks >= min_ticks and elapsed >= stuck_minutes * 60
    return {
        "stuck": stuck,
        "ticks": ticks,
        "first_seen": first_seen,
        "elapsed": elapsed,
    }


def cmd_clear_unknown(args: argparse.Namespace) -> dict[str, Any]:
    state_dir = _state_dir(args.state_dir)
    path = state_dir / f"{_safe_name(args.session)}.unknown.json"
    try:
        path.unlink()
    except OSError:
        pass
    return {"cleared": True}


def cmd_antiloop(args: argparse.Namespace) -> dict[str, Any]:
    state_dir = _state_dir(args.state_dir)
    key = f"{_safe_name(args.session)}__{_safe_name(args.picker_id)}"
    path = state_dir / f"{key}.resolves.json"
    now = int(time.time())
    window = max(1, int(args.window_seconds))
    cur = _read_json(path)
    stamps = cur.get("resolves") if isinstance(cur.get("resolves"), list) else []
    # Keep only stamps inside the window, then record this attempt.
    stamps = [s for s in stamps if isinstance(s, int) and now - s < window]
    stamps.append(now)
    _write_json(path, {"resolves": stamps})
    count = len(stamps)
    return {"tripped": count >= max(1, int(args.max_resolves)), "count": count}


def cmd_clear_state(args: argparse.Namespace) -> dict[str, Any]:
    state_dir = _state_dir(args.state_dir)
    path = state_dir / f"{_safe_name(args.session)}.stuck.json"
    try:
        path.unlink()
    except OSError:
        pass
    return {"cleared": True}


def cmd_classify(args: argparse.Namespace) -> dict[str, Any]:
    try:
        pane_text = Path(args.pane_file).read_text(encoding="utf-8", errors="replace")
    except OSError:
        pane_text = ""
    catalog = load_catalog(args.catalog or [], args.local_catalog)
    decision = classify(args.engine, pane_text, catalog)
    # Surface the resolved stuck_confirm_ticks default so the shell stage does
    # not need to re-parse the catalog.
    decision["stuck_confirm_ticks"] = int(
        catalog["defaults"].get("stuck_confirm_ticks", 2)
    )
    decision["antiloop_window_seconds"] = int(
        catalog["defaults"].get("antiloop_window_seconds", 120)
    )
    decision["antiloop_max_resolves"] = int(
        catalog["defaults"].get("antiloop_max_resolves", 3)
    )
    decision["unknown_stuck_minutes"] = int(
        catalog["defaults"].get("unknown_stuck_minutes", 5)
    )
    return decision


def cmd_audit_line(args: argparse.Namespace) -> dict[str, Any]:
    obj: dict[str, Any] = {}
    for pair in args.kw or []:
        if "=" not in pair:
            continue
        key, val = pair.split("=", 1)
        obj[key] = val
    obj.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    return obj


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bridge-picker")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_classify = sub.add_parser("classify")
    p_classify.add_argument("--engine", required=True)
    p_classify.add_argument("--pane-file", required=True)
    p_classify.add_argument("--catalog", action="append")
    p_classify.add_argument("--local-catalog")
    p_classify.set_defaults(func=cmd_classify)

    p_tick = sub.add_parser("tick")
    p_tick.add_argument("--session", required=True)
    p_tick.add_argument("--engine", default="")
    p_tick.add_argument("--picker-id", required=True)
    p_tick.add_argument("--pane-hash", required=True)
    p_tick.add_argument("--stuck-confirm-ticks", type=int, default=2)
    p_tick.add_argument("--state-dir")
    p_tick.set_defaults(func=cmd_tick)

    p_uticks = sub.add_parser("unknown-tick")
    p_uticks.add_argument("--session", required=True)
    p_uticks.add_argument("--pane-hash", required=True)
    p_uticks.add_argument("--stuck-minutes", type=int, default=5)
    p_uticks.add_argument("--min-ticks", type=int, default=2)
    p_uticks.add_argument("--state-dir")
    p_uticks.set_defaults(func=cmd_unknown_tick)

    p_uclear = sub.add_parser("clear-unknown")
    p_uclear.add_argument("--session", required=True)
    p_uclear.add_argument("--state-dir")
    p_uclear.set_defaults(func=cmd_clear_unknown)

    p_anti = sub.add_parser("antiloop")
    p_anti.add_argument("--session", required=True)
    p_anti.add_argument("--picker-id", required=True)
    p_anti.add_argument("--window-seconds", type=int, default=120)
    p_anti.add_argument("--max-resolves", type=int, default=3)
    p_anti.add_argument("--state-dir")
    p_anti.set_defaults(func=cmd_antiloop)

    p_clear = sub.add_parser("clear-state")
    p_clear.add_argument("--session", required=True)
    p_clear.add_argument("--state-dir")
    p_clear.set_defaults(func=cmd_clear_state)

    p_audit = sub.add_parser("audit-line")
    p_audit.add_argument("--kw", action="append")
    p_audit.set_defaults(func=cmd_audit_line)

    args = parser.parse_args(argv)
    out = args.func(args)
    sys.stdout.write(json.dumps(out))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
