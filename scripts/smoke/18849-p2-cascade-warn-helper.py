#!/usr/bin/env python3
"""Helper for scripts/smoke/18849-p2-cascade-warn.sh (#18849 Part 2 PR-2).

argv-driven (NO heredoc-stdin / `<<` — footgun #11 / lint-heredoc-ban) so the
caller seeds a registry scenario and reads back a rotate-envelope field without
embedding Python in the shell.

Subcommands:
  seed <registry> <scenario>   Write a token registry for a named cascade
                               scenario (relative timestamps resolved to now).
  field <json> <dotted.key>    Print a field from a rotate JSON envelope
                               (empty string when absent).
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone


def _iso(offset_seconds: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=offset_seconds)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00"
    )


# Token rows are keyed by id; the cascade logic only reads enabled / token /
# limited_until / disabled_until / last_check_status / last_checked_at. Tokens
# are opaque non-secret placeholders (cmd_rotate only fingerprints them).
SCENARIOS: dict[str, dict[str, object]] = {
    # (a) cascade: active A, B carries a RECENT auth_failed check (enabled, so it
    # is still in the ring), C is clean. Rotation must skip B and land on C.
    "cascade_past_adverse": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "auth_failed", "last_checked_at": -60},
            {"id": "C"},
        ],
    },
    # cascade over a read-only quota_limited check (enabled — `check` ran WITHOUT
    # --disable-on-quota): skip B, land on C.
    "cascade_past_quota_check": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "quota_limited", "last_checked_at": -120},
            {"id": "C"},
        ],
    },
    # (b) exhaustion (mixed): B adverse-check, C inside a future limit window.
    # Every alternate unavailable -> all_tokens_limited; soonest_reset = C window.
    "exhausted_mixed": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "auth_failed", "last_checked_at": -60},
            {"id": "C", "limited_until": 3600},
        ],
    },
    # (b) exhaustion (adverse-only): both alternates carry a recent hard-error
    # check and NO window. all_tokens_limited with an EMPTY soonest_reset, so the
    # daemon falls back to its short floor cooldown (still latched, no thrash).
    "exhausted_adverse_only": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "auth_failed", "last_checked_at": -60},
            {"id": "C", "last_check_status": "quota_limited", "last_checked_at": -90},
        ],
    },
    # fail-safe: B's adverse check is STALE (older than the freshness window) ->
    # treated as available-but-unverified. C is window-limited. Rotation must NOT
    # strand the pool: it lands on B.
    "stale_adverse_available": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "auth_failed", "last_checked_at": -99999},
            {"id": "C", "limited_until": 3600},
        ],
    },
    # fail-safe (clock skew / hand-edit): B's adverse check is FUTURE-dated, which
    # yields a NEGATIVE age. An untrusted future stamp must fail OPEN (available),
    # never strand B until "future + window". C is window-limited so B is the only
    # rotation target — it must be selected.
    "future_adverse_available": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B", "last_check_status": "auth_failed", "last_checked_at": 99999},
            {"id": "C", "limited_until": 3600},
        ],
    },
    # availability is judged from registry signals only: a clean 2-token pool
    # rotates A->B with NO probe of B (the recorder shim must stay untouched).
    "no_probe": {
        "active": "A",
        "tokens": [
            {"id": "A"},
            {"id": "B"},
        ],
    },
}

_RELATIVE_KEYS = ("limited_until", "disabled_until", "last_checked_at")


def _seed(registry: str, scenario: str) -> int:
    spec = SCENARIOS.get(scenario)
    if spec is None:
        sys.stderr.write(f"unknown scenario: {scenario}\n")
        return 2
    rows = []
    for entry in spec["tokens"]:  # type: ignore[index]
        row = {
            "id": entry["id"],
            "token": f"fake-token-{entry['id'].lower()}",
            "enabled": bool(entry.get("enabled", True)),
        }
        for key in _RELATIVE_KEYS:
            if key in entry:
                row[key] = _iso(int(entry[key]))
        if "last_check_status" in entry:
            row["last_check_status"] = entry["last_check_status"]
        rows.append(row)
    payload = {
        "version": 1,
        "active_token_id": spec["active"],
        "auto_rotate_enabled": True,
        "tokens": rows,
    }
    with open(registry, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(payload))
    return 0


def _field(blob: str, dotted: str) -> int:
    try:
        value: object = json.loads(blob)
    except json.JSONDecodeError:
        print("")
        return 0
    for part in dotted.split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            print("")
            return 0
    print("" if value is None else value)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: helper.py <seed|field> ...\n")
        return 2
    cmd = argv[1]
    if cmd == "seed" and len(argv) == 4:
        return _seed(argv[2], argv[3])
    if cmd == "field" and len(argv) == 4:
        return _field(argv[2], argv[3])
    sys.stderr.write("usage: helper.py <seed <registry> <scenario>|field <json> <key>>\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
