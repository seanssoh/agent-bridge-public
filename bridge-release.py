#!/usr/bin/env python3
"""bridge-release.py - query and monitor stable GitHub releases."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
# Issue #1267 (v0.15.0-beta4 Lane J): the strict SEMVER_RE does not match
# prerelease tags like "0.15.0-beta3" → parse_semver returns None for the
# installed side, which made `release_record` flip `update_available=True`
# whenever the operator was on a beta. That produced redundant "[release]
# v0.14.4 available" downgrade prompts in the admin's inbox after every
# beta install. SEMVER_PRERELEASE_RE captures the leading core version so
# `release_record` can still order beta vs stable correctly: a beta of
# the same or higher base version is treated as "not an upgrade" relative
# to an older stable.
SEMVER_PRERELEASE_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-+].+)?$")


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_semver(text: str | None) -> tuple[int, int, int] | None:
    if not text:
        return None
    match = SEMVER_RE.fullmatch(text.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def parse_semver_core(text: str | None) -> tuple[int, int, int] | None:
    """Like parse_semver but tolerates prerelease/build suffixes.

    Returns the (major, minor, patch) tuple for the leading core version,
    ignoring anything after `-` or `+`. Used by release comparison so a
    beta install (e.g. ``0.15.0-beta3``) compares correctly against a
    stable tag (``v0.14.4``) — the base version determines update_available.
    """
    if not text:
        return None
    match = SEMVER_PRERELEASE_RE.fullmatch(text.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def normalize_tag(tag_name: str | None) -> str:
    raw = (tag_name or "").strip()
    if not raw:
        return ""
    if raw.startswith("v"):
        return raw
    return f"v{raw}"


def normalize_version(tag_name: str | None) -> str:
    tag = normalize_tag(tag_name)
    return tag[1:] if tag.startswith("v") else tag


def build_api_url(repo: str) -> str:
    return f"https://api.github.com/repos/{repo}/releases/latest"


def load_mock_payload(args: argparse.Namespace) -> dict[str, Any] | None:
    mock_json = os.environ.get("BRIDGE_RELEASE_MOCK_JSON", "").strip()
    if mock_json:
        payload = json.loads(mock_json)
        if not isinstance(payload, dict):
            raise SystemExit("BRIDGE_RELEASE_MOCK_JSON must decode to an object")
        return payload

    mock_file = args.mock_json_file or os.environ.get("BRIDGE_RELEASE_MOCK_JSON_FILE", "")
    if not mock_file:
        return None
    payload = json.loads(Path(mock_file).expanduser().read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit("mock release payload must decode to an object")
    return payload


def fetch_latest_release(args: argparse.Namespace) -> dict[str, Any]:
    mock = load_mock_payload(args)
    if mock is not None:
        return mock

    api_url = args.api_url or os.environ.get("BRIDGE_RELEASE_API_URL") or build_api_url(args.repo)
    user_agent = f"agent-bridge-release-check/{args.installed_version or 'unknown'}"
    request = urllib.request.Request(
        api_url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": user_agent,
        },
    )
    timeout = max(1, int(args.timeout_seconds))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"release fetch failed: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"release fetch failed: {exc.reason}") from exc
    if not isinstance(payload, dict):
        raise SystemExit("release fetch returned a non-object payload")
    return payload


def release_record(repo: str, installed_version: str, payload: dict[str, Any]) -> dict[str, Any]:
    tag_name = normalize_tag(str(payload.get("tag_name") or ""))
    version = normalize_version(tag_name)
    installed = installed_version.strip()
    installed_tuple = parse_semver(installed)
    latest_tuple = parse_semver(version)
    # Issue #1267: tolerate prerelease/build suffix on the installed side
    # so a beta install (e.g. 0.15.0-beta3) compares correctly against an
    # older stable tag (v0.14.4). When installed is a prerelease we use
    # the core (major.minor.patch) for the comparison; treating a beta
    # of an equal-or-newer base version as "not an upgrade" is the
    # operator's expectation (see #1267 reproduction).
    installed_core = parse_semver_core(installed)
    update_available = False
    if latest_tuple is not None:
        if installed_tuple is None and installed_core is None:
            # Truly unparseable installed version → fall back to the
            # legacy "always upgrade" hint so a misconfigured VERSION
            # file does not silently swallow real releases.
            update_available = True
        elif installed_tuple is None:
            # Prerelease/build suffix only (no strict semver match) —
            # compare the core. A beta of the same or higher base
            # version is treated as already-ahead, no downgrade prompt.
            update_available = latest_tuple > installed_core
        else:
            update_available = latest_tuple > installed_tuple

    return {
        "repo": repo,
        "installed_version": installed,
        "latest_tag": tag_name,
        "latest_version": version,
        "release_name": str(payload.get("name") or tag_name or ""),
        "html_url": str(payload.get("html_url") or ""),
        "published_at": str(payload.get("published_at") or ""),
        "body": str(payload.get("body") or ""),
        "draft": bool(payload.get("draft")),
        "prerelease": bool(payload.get("prerelease")),
        "update_available": update_available,
        "source_api_url": args_api_url(repo, payload),
    }


def args_api_url(repo: str, payload: dict[str, Any]) -> str:
    return str(payload.get("url") or build_api_url(repo))


def load_monitor_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def save_monitor_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def cmd_status(args: argparse.Namespace) -> int:
    payload = fetch_latest_release(args)
    result = {
        "generated_at": now_iso(),
        "release": release_record(args.repo, args.installed_version, payload),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        release = result["release"]
        print(f"repo: {release['repo']}")
        print(f"installed_version: {release['installed_version'] or '-'}")
        print(f"latest_tag: {release['latest_tag'] or '-'}")
        print(f"latest_version: {release['latest_version'] or '-'}")
        print(f"update_available: {'yes' if release['update_available'] else 'no'}")
        print(f"published_at: {release['published_at'] or '-'}")
        print(f"html_url: {release['html_url'] or '-'}")
    return 0


def cmd_monitor(args: argparse.Namespace) -> int:
    payload = fetch_latest_release(args)
    release = release_record(args.repo, args.installed_version, payload)
    state_path = Path(args.state_file).expanduser()
    state = load_monitor_state(state_path)
    last_alert_tag = str(state.get("last_alert_tag") or "")
    last_alert_published_at = str(state.get("last_alert_published_at") or "")
    alerts: list[dict[str, Any]] = []

    if (
        release["update_available"]
        and release["latest_tag"]
        and (
            release["latest_tag"] != last_alert_tag
            or str(release["published_at"] or "") != last_alert_published_at
        )
    ):
        alerts.append(
            {
                **release,
                "message": (
                    f"Stable release {release['latest_tag']} is available for Agent Bridge. "
                    f"Installed version is {release['installed_version'] or 'unknown'}."
                ),
            }
        )
        state["last_alert_tag"] = release["latest_tag"]
        state["last_alert_published_at"] = release["published_at"]
        state["last_alerted_at"] = now_iso()

    state["updated_at"] = now_iso()
    state["last_seen_tag"] = release["latest_tag"]
    state["last_seen_published_at"] = release["published_at"]
    state["last_installed_version"] = release["installed_version"]
    save_monitor_state(state_path, state)

    result = {
        "generated_at": now_iso(),
        "release": release,
        "alerts": alerts,
        "state_file": str(state_path),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for alert in alerts:
            print(alert["message"])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--repo", default=os.environ.get("BRIDGE_RELEASE_REPO", "SYRS-AI/agent-bridge-public"))
        cmd.add_argument("--installed-version", default=os.environ.get("BRIDGE_RELEASE_INSTALLED_VERSION", ""))
        cmd.add_argument("--api-url", default=os.environ.get("BRIDGE_RELEASE_API_URL", ""))
        cmd.add_argument("--mock-json-file", default="")
        cmd.add_argument("--timeout-seconds", type=int, default=int(os.environ.get("BRIDGE_RELEASE_TIMEOUT_SECONDS", "10")))
        cmd.add_argument("--json", action="store_true")

    status_parser = sub.add_parser("status")
    add_common(status_parser)
    status_parser.set_defaults(handler=cmd_status)

    monitor_parser = sub.add_parser("monitor")
    add_common(monitor_parser)
    monitor_parser.add_argument("--state-file", required=True)
    monitor_parser.set_defaults(handler=cmd_monitor)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
