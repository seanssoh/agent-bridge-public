#!/usr/bin/env python3
"""write-release-alert-body.py — emit the markdown body for a stable
release alert into a destination file.

Invocation contract (3 positional argv):
    sys.argv[1] = body_file           (path; parent dir created if needed)
    sys.argv[2] = monitor_json        (JSON string from release monitor)
    sys.argv[3] = upgrade_check_json  (JSON string, may be "{}")

Exits 0 on success, 1 when the monitor payload carries no alerts (the
caller suppresses the alert path in that case).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$body_file" "$monitor_json" "$upgrade_check_json" <<'PY'`
heredoc-stdin in bridge_write_release_alert_body. The Bash 5.3.9
`read_comsub` / `heredoc_write` deadlock chain wedges the daemon under
periodic monitor pressure; moved to a standalone file invoked as
`python3 write-release-alert-body.py <body> <monitor> <upgrade>` to
remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    body_file = Path(sys.argv[1])
    monitor_payload = json.loads(sys.argv[2])
    try:
        upgrade_payload = json.loads(sys.argv[3])
    except Exception:
        upgrade_payload = {}

    alerts = monitor_payload.get("alerts") or []
    if not alerts:
        return 1
    alert = alerts[0]
    release = monitor_payload.get("release") or {}
    tag = str(alert.get("latest_tag") or release.get("latest_tag") or "")
    version = str(alert.get("latest_version") or release.get("latest_version") or "")
    installed_version = str(alert.get("installed_version") or release.get("installed_version") or "")
    release_name = str(alert.get("release_name") or release.get("release_name") or tag or version)
    repo = str(alert.get("repo") or release.get("repo") or "")
    release_url = str(alert.get("html_url") or release.get("html_url") or "")
    published_at = str(alert.get("published_at") or release.get("published_at") or "")
    notes = str(alert.get("body") or release.get("body") or "").strip()

    upgrade_target_ref = str(upgrade_payload.get("target_ref") or "")
    upgrade_target_version = str(upgrade_payload.get("target_version") or "")
    upgrade_available = bool(upgrade_payload.get("update_available"))
    local_upgrade_ready = bool(
        upgrade_available
        and (
            (tag and upgrade_target_ref == tag)
            or (version and upgrade_target_version == version)
        )
    )

    if local_upgrade_ready:
        readiness_note = "Direct `agb upgrade` on this server should target the same stable release."
    else:
        readiness_note = (
            "This server's local source checkout is not yet pointing at the same stable release. "
            "Downstream/source sync may be required before `agb upgrade` can apply it."
        )

    body_file.parent.mkdir(parents=True, exist_ok=True)
    with body_file.open("w", encoding="utf-8") as fh:
        fh.write("# Stable Release Available\n\n")
        fh.write(f"- release: {release_name}\n")
        fh.write(f"- tag: {tag or '-'}\n")
        fh.write(f"- version: {version or '-'}\n")
        fh.write(f"- installed_version: {installed_version or '-'}\n")
        fh.write(f"- repo: {repo or '-'}\n")
        fh.write(f"- published_at: {published_at or '-'}\n")
        fh.write(f"- release_url: {release_url or '-'}\n")
        fh.write(f"- detected_at: {monitor_payload.get('generated_at') or '-'}\n")
        fh.write("\n## Patch Action\n\n")
        fh.write("1. Read the release notes below.\n")
        fh.write("2. Summarize the user-facing changes to the admin user in Korean.\n")
        fh.write("3. Ask whether to apply the upgrade now.\n")
        fh.write("4. If the local upgrade path is not ready, explain that source/downstream sync is required first.\n")
        fh.write("\n## Local Upgrade Readiness\n\n")
        fh.write(f"- local_upgrade_ready: {'yes' if local_upgrade_ready else 'no'}\n")
        fh.write(f"- local_upgrade_target_ref: {upgrade_target_ref or '-'}\n")
        fh.write(f"- local_upgrade_target_version: {upgrade_target_version or '-'}\n")
        fh.write(f"- local_upgrade_update_available: {'yes' if upgrade_available else 'no'}\n")
        fh.write(f"- note: {readiness_note}\n")
        fh.write("\n## Release Notes\n\n")
        if notes:
            fh.write(notes)
            fh.write("\n")
        else:
            fh.write("_No release notes were published in the GitHub release body._\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
