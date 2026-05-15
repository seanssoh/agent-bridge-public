#!/usr/bin/env python3
"""emit-failure-json.py — render the failure-JSON envelope emitted by
`bridge_upgrade_emit_failure_json` when the upgrader exits non-zero before
reaching the success/dry-run JSON emission point.

Invocation contract (argv[1:16]):
    rc, reason, detail, remediation,
    source_version, source_root, source_ref, source_head,
    target_root, channel, target_ref, target_version, target_head,
    dry_run, iso_v2_json

Output: a single pretty-printed JSON document on stdout (indent=2).

Footgun #11 third variant (task #4538 codex r1 catch): this body used to live
as a `python3 - <<'PY' … PY` heredoc-stdin inside bridge_upgrade_emit_failure_json.
The function is invoked by the EXIT trap on non-zero exits — including
pre-apply isolation-v2 aborts at bridge-upgrade.sh:1457-1469 — so a heredoc
wedge there would mask the actual failure with a hang. Moved to a standalone
file to remove the heredoc-stdin path.

Body kept byte-for-byte (modulo this header docstring) with the prior heredoc
at bridge-upgrade.sh:175-215 (v0.13.8) per codex r2 review on PR #894.
"""

import json, sys

(rc, reason, detail, remediation,
 source_version, source_root, source_ref, source_head,
 target_root, channel, target_ref, target_version, target_head,
 dry_run, iso_v2_json) = sys.argv[1:16]

def _or_none(s):
    return s if s else None

def _load_json_str(s):
    if not s:
        return None
    try:
        return json.loads(s)
    except (ValueError, TypeError):
        return {"_raw": s, "_parse_error": True}

payload = {
    "mode": "upgrade",
    "rc": int(rc),
    "error": {
        "reason": reason,
        "detail": detail,
        "remediation": remediation,
    },
    "version": _or_none(source_version),
    "source_root": _or_none(source_root),
    "source_ref": _or_none(source_ref),
    "source_head": _or_none(source_head),
    "target_root": _or_none(target_root),
    "channel": _or_none(channel),
    "target_ref": _or_none(target_ref),
    "target_version": _or_none(target_version),
    "target_head": _or_none(target_head),
    "dry_run": dry_run == "1",
    "isolation_v2_migration": _load_json_str(iso_v2_json),
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
