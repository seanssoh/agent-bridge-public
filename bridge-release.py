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
# beta install. SEMVER_PRERELEASE_RE captures the leading core version
# AND the prerelease/build suffix so `release_record` can order beta vs
# stable correctly per semver 2.0.0:
#   1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-beta < 1.0.0-rc.1 < 1.0.0
# i.e. a beta of the same core IS upgradable to the corresponding stable
# (Lane J r2 fix — r1 used core-only compare which treated
# 0.14.5-beta1 vs 0.14.5 as "already ahead" and emitted
# release_notification_downgrade_skip on a legitimate beta→stable
# upgrade).
SEMVER_PRERELEASE_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")


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
    ignoring anything after `-` or `+`. Kept for back-compat (used by the
    deprecated core-only comparison path); new code should use
    :func:`parse_semver_full` which also captures the prerelease suffix.
    """
    if not text:
        return None
    match = SEMVER_PRERELEASE_RE.fullmatch(text.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups()[:3])


_UNDOTTED_PRERELEASE_RE = re.compile(r"^([A-Za-z]+)(\d+)$")


def _normalize_prerelease_identifier(ident: str) -> str:
    """Normalize an undotted prerelease identifier into canonical dot form.

    Project tags use the undotted form ``betaN`` / ``rcN`` / ``alphaN``
    (e.g. ``v0.14.5-beta9``, ``v0.15.0-beta10``). Strict SemVer 2.0.0
    §11 splits prerelease on dots and compares each identifier; an
    identifier is "numeric" iff it parses as a base-10 integer. ``beta9``
    and ``beta10`` are both alphanumeric (letters + digits) and compare
    **lexically** — making ``beta10 < beta9`` ("1" < "9").

    The fix is to rewrite ``letter-run + digit-run`` identifiers into
    ``letters.digits`` BEFORE comparison so the digit run becomes a
    numeric identifier and orders numerically (``beta.9 < beta.10``).

    Codex r2 BLOCKING repros at HEAD ``2a4b926`` confirmed the
    regression:
      0.14.5-beta9  vs v0.14.5-beta10 → update_available=false (WRONG)
      0.15.0-beta2  vs v0.15.0-beta10 → same wrong-direction false-no-update

    CHANGELOG.md documents both ``v0.14.5-beta9`` and ``v0.14.5-beta10``
    as actual tags, so this is not hypothetical.

    Examples::

        _normalize_prerelease_identifier("beta9")  == "beta.9"
        _normalize_prerelease_identifier("beta10") == "beta.10"
        _normalize_prerelease_identifier("rc1")    == "rc.1"
        _normalize_prerelease_identifier("alpha2") == "alpha.2"
        _normalize_prerelease_identifier("beta")   == "beta"      # no digits → untouched
        _normalize_prerelease_identifier("beta.3") == "beta.3"    # already dotted → untouched
        _normalize_prerelease_identifier("9")      == "9"         # pure numeric → untouched
    """
    m = _UNDOTTED_PRERELEASE_RE.match(ident)
    if m:
        return f"{m.group(1)}.{m.group(2)}"
    return ident


def _normalize_prerelease(prerelease: str) -> str:
    """Apply :func:`_normalize_prerelease_identifier` to each dot-split
    identifier in ``prerelease`` and rejoin. Empty input → empty output."""
    if not prerelease:
        return prerelease
    return ".".join(
        _normalize_prerelease_identifier(p) for p in prerelease.split(".")
    )


def parse_semver_full(text: str | None) -> tuple[tuple[int, int, int], str] | None:
    """Parse ``text`` into ``(core_tuple, prerelease_str)``.

    Returns ``None`` when the input does not look like ``MAJOR.MINOR.PATCH``
    (optionally with ``-prerelease`` / ``+build``). Build metadata is
    discarded per semver 2.0.0 (build metadata MUST be ignored when
    determining precedence). Prerelease defaults to the empty string,
    which signals "final" — i.e. higher precedence than any prerelease
    of the same core.

    Lane J r3 (codex r2 BLOCKING): project tags use the undotted
    ``betaN``/``rcN``/``alphaN`` form (``v0.14.5-beta10``). We normalize
    each identifier in the prerelease suffix into the canonical dotted
    form (``beta.10``) before returning so downstream
    :func:`_compare_prerelease_identifiers` sees the digit run as a
    numeric identifier and orders ``beta.9 < beta.10`` correctly.

    Examples:
        parse_semver_full("0.15.0")          == ((0, 15, 0), "")
        parse_semver_full("0.14.5-beta1")    == ((0, 14, 5), "beta.1")
        parse_semver_full("v0.14.5-beta.11") == ((0, 14, 5), "beta.11")
        parse_semver_full("v0.14.5-beta10")  == ((0, 14, 5), "beta.10")
    """
    if not text:
        return None
    match = SEMVER_PRERELEASE_RE.fullmatch(text.strip())
    if not match:
        return None
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    prerelease = _normalize_prerelease(match.group(4) or "")
    return ((major, minor, patch), prerelease)


def _compare_prerelease_identifiers(a: str, b: str) -> int:
    """Compare two prerelease strings per semver 2.0.0 §11.

    Identifiers are dot-separated. Numeric identifiers compare
    numerically and have lower precedence than alphanumeric ones. A
    smaller set of identifiers (when all preceding ones equal) has
    lower precedence. Returns -1/0/+1.

    Caller MUST handle the "one side has no prerelease" case before
    calling this (that is the "final > prerelease" semver rule and is
    NOT expressible as a pure identifier compare).
    """
    a_parts = a.split(".") if a else []
    b_parts = b.split(".") if b else []
    for ai, bi in zip(a_parts, b_parts):
        a_is_num = ai.isdigit()
        b_is_num = bi.isdigit()
        if a_is_num and b_is_num:
            an, bn = int(ai), int(bi)
            if an != bn:
                return -1 if an < bn else 1
            continue
        if a_is_num and not b_is_num:
            # numeric < alphanumeric
            return -1
        if not a_is_num and b_is_num:
            return 1
        if ai != bi:
            return -1 if ai < bi else 1
    # All shared identifiers equal — the side with more identifiers wins.
    if len(a_parts) == len(b_parts):
        return 0
    return -1 if len(a_parts) < len(b_parts) else 1


def compare_semver(installed: str | None, latest: str | None) -> int | None:
    """Full semver 2.0.0 comparator. Returns -1/0/+1 or ``None`` when
    either side is unparseable.

    Used by both ``release_record`` (decide ``update_available``) and
    ``bridge-daemon-helpers.py:cmd_release_downgrade_classify`` (decide
    whether to emit ``release_notification_downgrade_skip``). They MUST
    agree, otherwise a beta→stable upgrade like ``0.14.5-beta1`` vs
    ``0.14.5`` is silently skipped by the downgrade classifier even
    though it is a legitimate upgrade (Lane J r2 BLOCKING from codex
    r1 — pre-fix used core-only compare).
    """
    inst = parse_semver_full(installed)
    lat = parse_semver_full(latest)
    if inst is None or lat is None:
        return None
    inst_core, inst_pre = inst
    lat_core, lat_pre = lat
    if inst_core != lat_core:
        return -1 if inst_core < lat_core else 1
    # Same core: prerelease compare. Per semver 2.0.0, a final (empty
    # prerelease) has HIGHER precedence than any prerelease.
    if inst_pre == lat_pre:
        return 0
    if not inst_pre and lat_pre:
        # installed is final, latest is prerelease → installed > latest
        return 1
    if inst_pre and not lat_pre:
        # installed is prerelease, latest is final → installed < latest
        # (this is the beta→stable upgrade case; THE fix.)
        return -1
    return _compare_prerelease_identifiers(inst_pre, lat_pre)


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
    # Issue #1267 (Lane J r2): use the full semver 2.0.0 comparator so
    # both core (major.minor.patch) AND prerelease suffix matter. r1
    # used core-only compare on the prerelease branch, which made
    # ``0.14.5-beta1`` vs ``0.14.5`` (legitimate beta→stable upgrade)
    # appear as "already ahead" — and the downgrade classifier in
    # ``bridge-daemon-helpers.py`` then suppressed the notification.
    cmp_result = compare_semver(installed, version)
    update_available = False
    latest_full = parse_semver_full(version)
    if latest_full is not None:
        installed_full = parse_semver_full(installed)
        if cmp_result is None:
            # Latest parsed, installed didn't → truly unparseable installed
            # version. Fall back to the legacy "always upgrade" hint so a
            # misconfigured VERSION file does not silently swallow real
            # releases.
            if installed_full is None:
                update_available = True
            else:
                update_available = False
        else:
            update_available = cmp_result < 0

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


def cmd_compare(args: argparse.Namespace) -> int:
    """Print the full semver 2.0.0 ordering of two versions.

    Used by ``bridge-upgrade.sh`` (Issue #1516) to decide whether a
    resolved upgrade TARGET would move the install BACKWARD relative to
    the currently-installed version. Prints ``-1`` / ``0`` / ``1`` for
    ``left < right`` / ``left == right`` / ``left > right`` and exits 0.

    When either side is unparseable, prints nothing and exits 2 so the
    caller treats the comparison as "unknown" and proceeds (it must NOT
    fabricate a downgrade verdict from a malformed VERSION file — a
    forward upgrade should never be blocked by an unreadable version).
    """
    result = compare_semver(args.left, args.right)
    if result is None:
        return 2
    print(result)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--repo", default=os.environ.get("BRIDGE_RELEASE_REPO", "seanssoh/agent-bridge-public"))
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

    # Issue #1516: a thin, network-free comparator so bridge-upgrade.sh can
    # detect a backward (downgrade) target before applying. Reuses the same
    # compare_semver the release-notification path uses so the two agree.
    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("left")
    compare_parser.add_argument("right")
    compare_parser.set_defaults(handler=cmd_compare)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
