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


def classify(
    engine: str,
    pane_text: str,
    catalog: dict[str, Any],
) -> dict[str, Any]:
    """Return the first catalog entry whose fingerprint matches the pane.

    A `non_picker` entry that matches reports matched=False (it is a context
    signal, not a stuck state) so it can shadow a noisier picker fingerprint
    and guarantee the banner never registers as stuck.
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
        # the caller never treats it as stuck.
        if policy == "non_picker":
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
