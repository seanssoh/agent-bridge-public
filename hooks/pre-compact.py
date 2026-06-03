#!/usr/bin/env python3
"""Agent Bridge PreCompact hook — structured envelope + canonical snapshot.

Claude Code fires this event right before `/compact` (manual) or an
auto-compact compresses the conversation. The hook writes a capture note
so the short-term memory thread survives the compaction. Failures are
swallowed and the hook ALWAYS exits 0 — compaction must never be blocked.

This implementation combines two prior designs that previously diverged:

  1. v1 envelope (schema_version="1") with stable keys (`agent`,
     `captured_at`, `session_type`, `trigger`, `source`,
     `custom_instructions_excerpt`, `suggested_entities`,
     `suggested_concepts`, `suggested_slug`, `suggested_title`,
     `excerpt`, `transcript_available`). The downstream librarian
     ingest pipeline (`scripts/librarian-process-ingest.py` →
     `load_envelope()`) requires `schema_version="1"`; otherwise it
     falls back to a path-based hint or rejects the capture per the
     librarian §9 contract.

  2. 0.7.x canonical-snapshot sidecar (gated by BRIDGE_COMPACT_RECOVERY)
     that copies CLAUDE.md / MEMORY.md / etc. into a per-agent snapshot
     directory before compaction so session-start can recover canonical
     state if the live files were touched mid-compact.

Output capture body (consumed by `bridge-memory capture --text-file`):

    schema_version=1 | excerpt=...

    { ...envelope JSON, includes `canonical_snapshot` when present... }

The leading one-liner keeps text-only consumers working; the JSON
block carries the structured envelope for librarian and any other
downstream parser that promotes envelope fields into capture metadata.

Settings.json wiring (installed by bridge-hooks.py ensure-pre-compact-hook):

    {
      "PreCompact": [
        {
          "hooks": [{
            "type": "command",
            "command": "python3 <BRIDGE_HOME>/hooks/pre-compact.py",
            "timeout": 20
          }]
        }
      ]
    }
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = "1"
CUSTOM_EXCERPT_LIMIT = 500
# Issue #597 Track B: schema for the precompact-events/started/<event_id>.json
# marker the daemon observer consumes. Bumped only when the marker layout
# changes in a way the observer needs to branch on; readers must tolerate a
# missing/older schema_version by treating it as 1.
MARKER_SCHEMA_VERSION = "1"

# Allow `from bridge_hook_common import …` even when this hook is invoked
# from `~/.agent-bridge/hooks/pre-compact.py` (the live-runtime layout
# Claude Code wires through settings.json). bridge_hook_common.py sits
# next to this file in both the source tree and the deployed runtime.
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import (
        compact_recovery_enabled,
        gather_canonical_files,
        under_isolated_uid,
        write_audit,
        write_compact_snapshot,
    )
except ImportError:  # pragma: no cover — keep pre-compact resilient if
    # bridge_hook_common is missing (e.g. hooks/ is partially deployed).
    compact_recovery_enabled = None  # type: ignore[assignment]
    gather_canonical_files = None  # type: ignore[assignment]
    under_isolated_uid = None  # type: ignore[assignment]
    write_audit = None  # type: ignore[assignment]
    write_compact_snapshot = None  # type: ignore[assignment]


def _bridge_home() -> Path:
    # NOTE (issue #1497 P2): intentionally NOT delegated to the canonical
    # operator_home() SSOT. This wrapper's fallback is load-bearing and
    # DIFFERENT from operator_home(): when BRIDGE_HOME is unset it returns the
    # script's own location (<this>/.. = where the hook is actually deployed),
    # not ~/.agent-bridge. That walk-up is how PreCompact locates its home under
    # a non-standard / live-runtime layout; swapping it for the default-home
    # SSOT would be a behavior change, not a pure dedup. Deferred to P3 (same
    # reason bridge_a2a_common.bridge_home() is deferred — divergent form).
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        return Path(env_home)
    # Hook scripts live at <bridge-home>/hooks/. Walk up.
    return Path(__file__).resolve().parent.parent


def _agent_id() -> str:
    return (os.environ.get("BRIDGE_AGENT_ID") or "").strip()


def _agent_home() -> Path | None:
    env_home = os.environ.get("BRIDGE_AGENT_HOME")
    if env_home:
        return Path(env_home)
    # Issue #582 r2: under v2 layout, bridge-run.sh exports BRIDGE_AGENT_WORKDIR
    # (not BRIDGE_AGENT_HOME). The v2 workdir is the agent's effective home for
    # raw/captures/inbox/ writes — and it matches what wiki-daily-ingest.sh's
    # raw enumeration walks (`<workdir>/raw/captures/inbox`). Without this
    # fallback, v2 PreCompact envelopes land under <BRIDGE_HOME>/agents/<agent>/
    # while the enumeration looks under the workdir, so the daily report misses
    # them. Preferring BRIDGE_AGENT_HOME first keeps legacy/v1 behavior intact.
    env_workdir = os.environ.get("BRIDGE_AGENT_WORKDIR")
    if env_workdir:
        return Path(env_workdir)
    agent = _agent_id()
    if not agent:
        return None
    candidate = _bridge_home() / "agents" / agent
    return candidate if candidate.exists() else None


def _stdin_payload() -> dict:
    """Claude Code passes hook metadata as JSON on stdin (trigger, custom instructions, etc)."""
    if sys.stdin.isatty():
        return {}
    raw = sys.stdin.read() or ""
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _read_session_type(home: Path) -> str:
    """Best-effort: pull the `Session Type: X` line from SESSION-TYPE.md."""
    path = home / "SESSION-TYPE.md"
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    match = re.search(
        r"^\s*-?\s*Session Type\s*:\s*([^\n#]+)",
        text,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    if not match:
        return ""
    raw = match.group(1).strip().strip("`")
    return raw.split()[0] if raw else ""


def _state_dir() -> Path:
    """Resolve $BRIDGE_STATE_DIR; defaults to <bridge-home>/state.

    The daemon observer reads markers from the same location, so the hook
    and daemon agree on the path even when BRIDGE_STATE_DIR is unset.
    """
    env_state = os.environ.get("BRIDGE_STATE_DIR")
    if env_state:
        return Path(env_state)
    return _bridge_home() / "state"


def _new_event_id() -> str:
    """Generate a sortable event id: <epoch-ms>-<8-hex>.

    Sortable prefix lets the daemon observer process markers in
    started-time order without parsing the JSON; the random suffix
    keeps two near-simultaneous compactions on the same agent
    (vanishingly unlikely but plausible during reproduction tests)
    from colliding on the same path.
    """
    return f"{int(time.time() * 1000):013d}-{secrets.token_hex(4)}"


def _write_started_marker(agent: str, payload: dict, trigger: str) -> None:
    """Write a best-effort started marker for the daemon observer.

    Issue #597 Track B. The marker tells `process_precompact_events` (in
    bridge-daemon.sh) that a compaction has just begun on this agent so
    the daemon can resolve a channel route and send the user a "back in
    ~Ns" notice. The hook stays exit-0 / non-blocking — every error here
    is swallowed and compaction proceeds exactly as before.
    """
    try:
        event_id = _new_event_id()
        started_ts = int(time.time())
        started_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
        marker = {
            "schema_version": MARKER_SCHEMA_VERSION,
            "event_id": event_id,
            "agent": agent,
            "trigger": trigger,
            "raw_trigger": str(payload.get("trigger") or payload.get("reason") or ""),
            "started_ts": started_ts,
            "started_iso": started_iso,
            "hook_pid": os.getpid(),
        }
        if isinstance(payload, dict) and payload:
            marker["payload_keys"] = sorted(k for k in payload.keys() if isinstance(k, str))

        target_dir = _state_dir() / "precompact-events" / agent / "started"
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / f"{event_id}.json"
            # Atomic temp-then-replace so a half-written marker can never be
            # read by the daemon mid-write.
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=str(target_dir),
                prefix=f".{event_id}.",
                suffix=".tmp",
                delete=False,
            ) as fh:
                json.dump(marker, fh, ensure_ascii=False)
                fh.write("\n")
                fh.flush()
                try:
                    os.fsync(fh.fileno())
                except OSError:
                    pass
                tmp_path = fh.name
            os.replace(tmp_path, target)
        except (PermissionError, OSError) as exc:
            # Issue #1217 (beta27 Track E): under iso v2, the precompact
            # marker dir lives under a controller-owned state tree the
            # isolated UID cannot mkdir into. Surface an audit event so
            # operators have telemetry on which marker writer fell open;
            # then return without dumping a traceback. Outside iso, raise
            # so the existing outer generic except keeps the previous
            # exit-0 contract (no observable behavior change for the
            # controller-side path).
            if under_isolated_uid is not None and under_isolated_uid():
                if write_audit is not None:
                    try:
                        write_audit(
                            "hook_permission_fail_open.precompact.started_marker",
                            str(target_dir),
                            {
                                "operation": "mkdir_or_replace",
                                "error_class": type(exc).__name__,
                            },
                        )
                    except Exception:  # noqa: BLE001 — best-effort audit
                        pass
                return
            raise
    except Exception:
        # Hook stays exit-0; missing marker just means no notice gets sent.
        pass


def _normalize_trigger(payload: dict) -> str:
    raw = str(payload.get("trigger") or payload.get("reason") or "").strip().lower()
    if raw in {"manual", "auto"}:
        return raw
    if raw:
        return raw
    return "unknown"


def _capture_canonical_snapshot(agent: str) -> str:
    """Persist a pre-compact snapshot of canonical agent files.

    Returns the snapshot path as a string for inclusion in the capture
    envelope (so an operator running `bridge-memory search` can locate
    the sidecar later, and the session-start hook can fall back to it
    when the live canonical files have been touched). Empty string when
    the feature is disabled or the helpers from bridge_hook_common are
    unavailable.
    """
    if (
        compact_recovery_enabled is None
        or gather_canonical_files is None
        or write_compact_snapshot is None
    ):
        return ""
    try:
        if not compact_recovery_enabled():
            return ""
        files = gather_canonical_files(agent)
        if not any(files.values()):
            return ""
        path = write_compact_snapshot(agent, files)
        return str(path) if path is not None else ""
    except Exception:
        # Snapshot failure must never block compaction.
        return ""


def _build_envelope(agent: str, home: Path, payload: dict, snapshot_path: str) -> dict:
    trigger = _normalize_trigger(payload)
    captured_at = datetime.now().astimezone().isoformat(timespec="seconds")
    custom = str(payload.get("custom_instructions") or "").strip()
    excerpt_line = f"pre-compact trigger={trigger} agent={agent} ts={captured_at}"
    if snapshot_path:
        excerpt_line += f" canonical_snapshot={snapshot_path}"
    if custom:
        excerpt_line += f" custom={custom[:120].replace(chr(10), ' ')}"

    envelope: dict = {
        "schema_version": SCHEMA_VERSION,
        "agent": agent,
        "captured_at": captured_at,
        "session_type": _read_session_type(home),
        "trigger": trigger,
        "source": "pre-compact-hook",
        "custom_instructions_excerpt": custom[:CUSTOM_EXCERPT_LIMIT],
        # Route pre-compact dumps to the `agents` wiki kind via the
        # `agents/` prefix in ENTITY_KIND_PREFIXES (see
        # scripts/librarian-process-ingest.py). Without this hint,
        # infer_kind() falls through to DEFAULT_KIND=operating-rules,
        # which the librarian §9 guard rejects as agent content, causing
        # a [librarian-ambiguous] escalation loop. See issue #976.
        "suggested_entities": [f"agents/{agent}/session-transcripts/"],
        "suggested_concepts": [],
        "suggested_slug": "",
        "suggested_title": "",
        "excerpt": excerpt_line,
        "transcript_available": False,
    }
    if snapshot_path:
        envelope["canonical_snapshot"] = snapshot_path
    return envelope


def _render_capture_body(envelope: dict) -> str:
    """Envelope serialized so text-only consumers still see a human line.

    Layout:
        schema_version=1 | excerpt=<...>
        <blank>
        {json envelope}
    """
    head = f"schema_version={envelope['schema_version']} | excerpt={envelope['excerpt']}"
    body = json.dumps(envelope, ensure_ascii=False, indent=2)
    return f"{head}\n\n{body}\n"


def _run_capture(
    bridge_memory: Path,
    agent: str,
    home: Path,
    template_root: Path,
    envelope: dict,
) -> None:
    # Write envelope to a temp file and pass via --text-file to avoid
    # argv length limits and preserve newlines in the JSON block.
    captures_inbox = home / "raw" / "captures" / "inbox"
    fd, tmp_path = tempfile.mkstemp(
        prefix="precompact-",
        suffix=".txt",
        dir=str(captures_inbox) if captures_inbox.exists() else None,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(_render_capture_body(envelope))
        cmd = [
            sys.executable or "python3",
            str(bridge_memory),
            "capture",
            "--agent", agent,
            "--home", str(home),
            "--template-root", str(template_root),
            "--source", "pre-compact-hook",
            "--title", f"pre-compact dump ({envelope['trigger']})",
            "--text-file", tmp_path,
        ]
        try:
            subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def main() -> int:
    try:
        agent = _agent_id()
        home = _agent_home()
        if not agent or home is None:
            return 0
        payload = _stdin_payload()

        # Issue #597 Track B: write the daemon-observer marker BEFORE the
        # synchronous capture path. The capture flow is best-effort and may
        # block briefly on bridge-memory; writing the marker first keeps
        # notice latency bounded by daemon interval rather than capture
        # duration. The marker write is itself best-effort/exit-0.
        _write_started_marker(agent, payload, _normalize_trigger(payload))

        snapshot_path = _capture_canonical_snapshot(agent)
        envelope = _build_envelope(agent, home, payload, snapshot_path)

        bridge_memory = _bridge_home() / "bridge-memory.py"
        template_root = _bridge_home() / "agents" / "_template"
        if not bridge_memory.exists():
            return 0
        _run_capture(bridge_memory, agent, home, template_root, envelope)
    except Exception:
        # Never block a compaction on hook failure.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
