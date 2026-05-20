#!/usr/bin/env python3
"""Tap Claude Code rate_limits from HUD stdin → .usage-cache.json.

Claude Code HUD v0.0.12+ reads usage from stdin rate_limits rather than
writing .usage-cache.json (OAuth polling removed). bridge-usage.py still
reads .usage-cache.json to drive the token-rotation monitor. This script
bridges the gap:

  1. Read the full stdin JSON that Claude Code sends to the statusLine process.
  2. Extract rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}.
  3. Write .usage-cache.json in the format bridge-usage.py expects (fiveHour /
     sevenDay / fiveHourResetAt / sevenDayResetAt under a "data" key).
  4. Pass stdin through unchanged to stdout so the HUD process receives it.

Usage (statusLine command):
    python3 /path/to/hud-usage-tap.py | bun --env-file /dev/null "${plugin_dir}src/index.ts"

The write is atomic (temp-then-replace) and capped at 0.5 s via a daemon
thread so it never delays HUD rendering.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _to_iso(value: Any) -> str | None:
    """Normalise a reset-at value to an ISO-8601 string.

    Claude Code stdin emits resets_at as epoch seconds (integer) or an ISO
    string. bridge-usage.py's reset_cycle_advanced/format_reset parse the
    stored value with datetime.fromisoformat, which rejects bare integers.
    Normalise here so the latch-clearing path works across reset windows.
    """
    if value is None:
        return None
    if isinstance(value, str) and value.strip():
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
            return value
        except ValueError:
            pass
        # fall through to epoch parse below
    if isinstance(value, (int, float)) and value > 0:
        ts = float(value)
        if ts > 1e11:  # milliseconds → seconds
            ts /= 1000
        return datetime.fromtimestamp(ts, tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S+00:00"
        )
    return None


def _write_cache(data: dict) -> None:
    try:
        rl = data.get("rate_limits")
        if not isinstance(rl, dict) or not rl:
            return

        five_hour = rl.get("five_hour") or {}
        seven_day = rl.get("seven_day") or {}

        used_5h = five_hour.get("used_percentage")
        used_7d = seven_day.get("used_percentage")
        if used_5h is None and used_7d is None:
            return

        try:
            fh = float(used_5h) if used_5h is not None else None
        except (TypeError, ValueError):
            fh = None
        try:
            sd = float(used_7d) if used_7d is not None else None
        except (TypeError, ValueError):
            sd = None

        cache = {
            "data": {
                "planName": "subscription",
                "fiveHour": fh,
                "sevenDay": sd,
                "fiveHourResetAt": _to_iso(five_hour.get("resets_at")),
                "sevenDayResetAt": _to_iso(seven_day.get("resets_at")),
            },
            "_source": "stdin-tap",
            "_written_at": datetime.now(timezone.utc).isoformat(),
        }

        home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        cache_dir = Path(home) / "plugins" / "claude-hud"
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_path = cache_dir / ".usage-cache.json"

        fd, tmp = tempfile.mkstemp(
            dir=str(cache_dir), prefix=".usage-cache.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(cache, f, ensure_ascii=False)
            os.replace(tmp, cache_path)
        except Exception:
            try:
                os.unlink(tmp)
            except Exception:
                pass
    except Exception:
        pass


def main() -> None:
    raw = sys.stdin.buffer.read()

    try:
        data = json.loads(raw)
        t = threading.Thread(target=_write_cache, args=(data,), daemon=True)
        t.start()
        t.join(timeout=0.5)
    except Exception:
        pass

    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
