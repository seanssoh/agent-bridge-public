#!/usr/bin/env python3
"""bridge-orphan-gc.py — orphan agent-dir GC action layer (Issue #1803).

The daemon `bridge_orphan_dir_gc` periodic pass invokes this helper. It is the
ACTION layer that consumes the read-only `bridge_orphan_classifier` SSOT:
only a child classified ``orphan-agent-dir`` is ever a quarantine candidate.
Everything else (registered / infra / referenced-symlink-target /
orphan-agent-dir-unverifiable / detector-error) is KEEP + notify
(the #1795/#1791 fail-safe rule).

Two passes, deliberately SEPARATE code paths (codex #4):

  quarantine  — classify → age-gate → TOCTOU-revalidate → MOVE (never delete)
                a candidate to ``backups/orphan-agents-<YYYYMMDD>/<name>/``.
                v1 default is detect+count+notify ONLY: nothing moves unless
                BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1 (codex #1 kill-switch).
  prune       — delete ``backups/orphan-agents-*`` entries older than the
                retain window, with its OWN dry-run and a HARD containment
                check that the delete target is strictly under a
                ``backups/orphan-agents-*`` dir (never escapes).

Hard safety constraints folded in:
  * TOCTOU (codex #2): immediately before each move, re-fetch a fresh
    registry snapshot, re-classify THIS path, and realpath-containment-check
    it is still under the home root and still ``orphan-agent-dir``. Any change
    → abort the move, keep+notify.
  * Symlink candidate (Part B): if the candidate is itself a symlink, move the
    LINK only — never follow it, never touch its target.
  * Prune containment: a delete target must resolve strictly under a
    ``backups/orphan-agents-*`` directory or it is refused.

Output: a JSON summary to stdout (the daemon parses it to emit the admin
``[hygiene]`` task and the audit rows it cannot derive). Audit rows for each
actual MOVE/PRUNE are written directly here via ``bridge-audit.py write`` so
the action and its audit row are co-located (the hash chain stays canonical).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bridge_orphan_classifier import (
    KIND_ORPHAN,
    classify_agent_home_root,
)

# Quarantine destination dir prefix under <BRIDGE_HOME>/backups/.
QUARANTINE_DIR_PREFIX = "orphan-agents-"

DEFAULT_MIN_AGE_SECONDS = 7 * 24 * 60 * 60  # 7 days
DEFAULT_RETAIN_DAYS = 30


def _iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _layout_file_mtime(path: Path) -> float | None:
    """Best-effort mtime of `path`. Mirrors the portable shell helper
    `_bridge_layout_file_mtime`. Returns None on any stat failure (caller
    treats None as KEEP — an unstatable dir is never aged out)."""
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def _load_registry_from_file(path: str) -> list[dict[str, Any]]:
    p = Path(path).expanduser()
    with p.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        raise ValueError("registry json must be an array")
    return data


def _load_registry_from_cmd(binary: str) -> list[dict[str, Any]]:
    proc = subprocess.run(
        [binary, "agent", "registry", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(proc.stdout)
    if not isinstance(data, list):
        raise ValueError("agent registry --json did not return an array")
    return data


def _fresh_registry(args: argparse.Namespace) -> list[dict[str, Any]]:
    """Fetch a FRESH registry snapshot (for the initial scan AND for each
    TOCTOU revalidation). Prefers the live CLI; falls back to a file for
    isolated tests."""
    if getattr(args, "registry_cmd", None):
        return _load_registry_from_cmd(args.registry_cmd)
    if getattr(args, "registry_json", None):
        return _load_registry_from_file(args.registry_json)
    raise SystemExit("one of --registry-cmd / --registry-json is required")


def _audit_write(
    audit_log: str,
    actor: str,
    action: str,
    target: str,
    details: dict[str, Any],
) -> None:
    """Append one audit row via bridge-audit.py (canonical hash-chained
    writer). Best-effort: an audit failure must never abort the GC pass —
    the daemon also surfaces the move in the [hygiene] task."""
    if not audit_log:
        return
    audit_py = str(Path(__file__).resolve().parent / "bridge-audit.py")
    cmd = [
        sys.executable,
        audit_py,
        "write",
        "--file",
        audit_log,
        "--actor",
        actor,
        "--action",
        action,
        "--target",
        target,
    ]
    for key, value in details.items():
        cmd.extend(["--detail", f"{key}={value}"])
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True)
    except OSError:
        pass


# --- quarantine pass -------------------------------------------------------


def _revalidate_still_orphan(
    args: argparse.Namespace,
    home_root: Path,
    home_root_real: str,
    candidate_path: str,
) -> tuple[bool, str]:
    """TOCTOU guard (codex #2). Re-fetch a FRESH registry snapshot, re-classify
    the WHOLE home root, and confirm THIS candidate is still present AND still
    ``orphan-agent-dir`` AND still realpath-contained under the home root.

    Returns (ok, reason). `ok=False` means abort the move (keep+notify) — an
    agent may have just been created with this id, or the path became a symlink
    target, or it escaped containment.
    """
    cand = Path(candidate_path)
    # Containment, two parts:
    #  (a) the candidate's PARENT must still resolve to the home root, i.e. it
    #      is still a direct child of agents/ (the only thing we ever move).
    #  (b) for a NON-symlink candidate, its realpath must stay under the home
    #      root — this defends against a real dir being swapped for a
    #      symlink-to-elsewhere between scan and move. A candidate that is
    #      ITSELF a symlink is moved as a LINK only (we never follow it), so a
    #      realpath that points outside is EXPECTED and not a breach.
    try:
        parent_real = os.path.realpath(cand.parent)
    except OSError:
        return False, "candidate parent realpath raised at revalidation"
    if parent_real != home_root_real:
        return False, "candidate is no longer a direct child of the home root"
    is_link = os.path.islink(cand)
    if not is_link:
        try:
            cand_real = os.path.realpath(cand)
        except OSError:
            return False, "candidate realpath raised at revalidation"
        if not (
            cand_real == home_root_real
            or cand_real.startswith(home_root_real + os.sep)
        ):
            return False, "candidate escaped the home-root containment boundary"

    try:
        fresh = _fresh_registry(args)
    except Exception as exc:  # noqa: BLE001 — registry refetch failure ⇒ keep
        return False, f"could not refetch registry for revalidation: {exc}"

    rows = classify_agent_home_root(fresh, home_root)
    match = None
    for row in rows:
        if row.get("path") == candidate_path:
            match = row
            break
    if match is None:
        return False, "candidate vanished from the home root at revalidation"
    if match.get("kind") != KIND_ORPHAN:
        return False, (
            f"candidate reclassified to {match.get('kind')} at revalidation"
        )
    return True, "still orphan-agent-dir"


def _move_candidate(candidate: Path, dest_dir: Path, name: str) -> str:
    """Move the candidate into dest_dir/<name>. If the candidate is itself a
    symlink, move the LINK only (never follow / never touch the target).
    Returns the destination path string. Raises on failure."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / name
    # Disambiguate a name collision (two quarantines of the same name in one
    # day) with a numeric suffix so a move never clobbers a prior archive.
    if dest.exists() or os.path.islink(dest):
        n = 1
        while True:
            alt = dest_dir / f"{name}.{n}"
            if not (alt.exists() or os.path.islink(alt)):
                dest = alt
                break
            n += 1
    if os.path.islink(candidate):
        # Move the LINK itself: read its target, recreate the link at the
        # destination, then unlink the original. shutil.move would follow or
        # copy the target tree; os.rename across the same filesystem preserves
        # the link, but to be fs-agnostic we recreate + unlink.
        link_target = os.readlink(candidate)
        os.symlink(link_target, dest)
        os.unlink(candidate)
    else:
        # Real dir: os.rename when same-fs, else shutil.move. shutil.move
        # already does this fallback and copies the tree without following
        # symlinks INSIDE it (copy2 + copytree(symlinks=True) semantics in
        # move are not guaranteed, so prefer rename and only fall back).
        try:
            os.rename(candidate, dest)
        except OSError:
            shutil.move(str(candidate), str(dest))
    return str(dest)


def run_quarantine(args: argparse.Namespace) -> dict[str, Any]:
    home_root = Path(args.agent_home_root).expanduser()
    auto = os.environ.get("BRIDGE_ORPHAN_GC_AUTO_QUARANTINE", "0").strip() == "1"
    min_age = args.min_age_seconds
    now = datetime.now(timezone.utc).timestamp()

    summary: dict[str, Any] = {
        "pass": "quarantine",
        "ts": _iso_now(),
        "auto_quarantine": auto,
        "min_age_seconds": min_age,
        "home_root": str(home_root),
        "quarantined": [],          # actually moved
        "would_quarantine": [],     # actionable but auto-off OR below age gate not included here
        "kept_indeterminate": [],   # keep+notify (unverifiable / detector-error)
        "skipped_too_young": [],    # actionable kind but below the age gate
        "errors": [],
    }

    if not home_root.is_dir():
        return summary

    home_root_real = os.path.realpath(home_root)

    try:
        registry = _fresh_registry(args)
    except Exception as exc:  # noqa: BLE001 — initial registry load failure
        summary["errors"].append(f"registry load failed: {exc}")
        return summary

    rows = classify_agent_home_root(registry, home_root)

    today = datetime.now().strftime("%Y%m%d")
    backups_root = Path(args.backups_dir).expanduser()
    dest_dir = backups_root / f"{QUARANTINE_DIR_PREFIX}{today}"

    for row in rows:
        kind = row.get("kind")
        name = row.get("name", "")
        path = row.get("path", "")
        if kind != KIND_ORPHAN:
            # Surface the keep-because-indeterminate names so the admin task
            # can list them (only the genuinely indeterminate / error kinds —
            # registered/infra/referenced-symlink-target are silent KEEPs).
            if kind in ("orphan-agent-dir-unverifiable", "detector-error"):
                summary["kept_indeterminate"].append(
                    {"name": name, "path": path, "kind": kind,
                     "reason": row.get("reason", "")}
                )
            continue

        # Age gate. mtime-read failure ⇒ keep (never age out an unstatable dir).
        mtime = _layout_file_mtime(Path(path))
        if mtime is None:
            summary["kept_indeterminate"].append(
                {"name": name, "path": path, "kind": "mtime-unreadable",
                 "reason": "could not read mtime; kept (fail-safe)"}
            )
            continue
        age = now - mtime
        if age < min_age:
            summary["skipped_too_young"].append(
                {"name": name, "path": path, "age_seconds": int(age)}
            )
            continue

        entry = {
            "name": name,
            "path": path,
            "age_seconds": int(age),
            "is_test_artifact": bool(row.get("is_test_artifact")),
        }

        if not auto:
            # v1 default: detect + count + notify ONLY. Record the dry-run
            # would-quarantine set; move nothing.
            summary["would_quarantine"].append(entry)
            continue

        # AUTO mode: TOCTOU-revalidate immediately before the move.
        ok, reason = _revalidate_still_orphan(
            args, home_root, home_root_real, path
        )
        if not ok:
            summary["kept_indeterminate"].append(
                {"name": name, "path": path, "kind": "toctou-aborted",
                 "reason": reason}
            )
            continue

        try:
            quarantine_path = _move_candidate(Path(path), dest_dir, name)
        except Exception as exc:  # noqa: BLE001 — per-candidate move boundary
            summary["errors"].append(
                {"name": name, "path": path, "error": str(exc)}
            )
            continue

        _audit_write(
            args.audit_log,
            actor="daemon",
            action="orphan_agent_dir_gc_quarantined",
            target=name,
            details={
                "source": path,
                "quarantine_path": quarantine_path,
                "mtime_age_seconds": int(age),
                "is_test_artifact": bool(row.get("is_test_artifact")),
                "registry_checked": "agent registry --json (revalidated)",
            },
        )
        entry["quarantine_path"] = quarantine_path
        summary["quarantined"].append(entry)

    return summary


# --- prune pass (separate code path, codex #4) -----------------------------


def _is_under_quarantine_root(target_real: str, backups_real: str) -> bool:
    """HARD containment: target must resolve strictly UNDER a
    ``backups/orphan-agents-*`` directory (i.e. under backups_real, and the
    first path component below backups_real must start with the quarantine
    prefix). Never allows a delete to escape the quarantine tree."""
    if not (target_real == backups_real or target_real.startswith(backups_real + os.sep)):
        return False
    rel = os.path.relpath(target_real, backups_real)
    if rel in (".", ""):
        # Refuse deleting backups_real itself.
        return False
    first = rel.split(os.sep, 1)[0]
    return first.startswith(QUARANTINE_DIR_PREFIX)


def run_prune(args: argparse.Namespace) -> dict[str, Any]:
    backups_root = Path(args.backups_dir).expanduser()
    retain_days = args.retain_days
    dry_run = args.dry_run or (
        os.environ.get("BRIDGE_ORPHAN_GC_AUTO_QUARANTINE", "0").strip() != "1"
        and not args.force_prune
    )
    now = datetime.now(timezone.utc).timestamp()
    cutoff = now - retain_days * 24 * 60 * 60

    summary: dict[str, Any] = {
        "pass": "prune",
        "ts": _iso_now(),
        "retain_days": retain_days,
        "dry_run": dry_run,
        "backups_dir": str(backups_root),
        "pruned": [],
        "would_prune": [],
        "refused": [],
        "errors": [],
    }

    if not backups_root.is_dir():
        return summary

    try:
        backups_real = os.path.realpath(backups_root)
    except OSError as exc:
        summary["errors"].append(f"backups realpath failed: {exc}")
        return summary

    try:
        entries = sorted(backups_root.iterdir(), key=lambda p: p.name)
    except OSError as exc:
        summary["errors"].append(f"backups iterdir failed: {exc}")
        return summary

    for entry in entries:
        name = entry.name
        if not name.startswith(QUARANTINE_DIR_PREFIX):
            continue
        if not entry.is_dir():
            continue
        mtime = _layout_file_mtime(entry)
        if mtime is None:
            summary["refused"].append(
                {"name": name, "reason": "mtime unreadable; kept (fail-safe)"}
            )
            continue
        if mtime >= cutoff:
            continue  # within retain window

        # HARD containment check before any delete.
        try:
            target_real = os.path.realpath(entry)
        except OSError as exc:
            summary["refused"].append(
                {"name": name, "reason": f"realpath raised: {exc}"}
            )
            continue
        if not _is_under_quarantine_root(target_real, backups_real):
            summary["refused"].append(
                {"name": name, "real": target_real,
                 "reason": "outside backups/orphan-agents-* containment"}
            )
            continue

        if dry_run:
            summary["would_prune"].append(
                {"name": name, "path": str(entry),
                 "age_seconds": int(now - mtime)}
            )
            continue

        try:
            shutil.rmtree(entry)
        except Exception as exc:  # noqa: BLE001 — per-entry delete boundary
            summary["errors"].append({"name": name, "error": str(exc)})
            continue
        _audit_write(
            args.audit_log,
            actor="daemon",
            action="orphan_agent_dir_gc_pruned",
            target=name,
            details={
                "quarantine_path": str(entry),
                "age_seconds": int(now - mtime),
                "retain_days": retain_days,
            },
        )
        summary["pruned"].append(
            {"name": name, "path": str(entry), "age_seconds": int(now - mtime)}
        )

    return summary


def _add_common_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--backups-dir", required=True)
    p.add_argument("--audit-log", default="")
    # Registry source: prefer the live CLI; tests inject a file.
    p.add_argument("--registry-cmd", default="")
    p.add_argument("--registry-json", default="")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bridge-orphan-gc.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("quarantine", help="classify + age-gate + (auto) move")
    _add_common_args(q)
    q.add_argument("--agent-home-root", required=True)
    q.add_argument(
        "--min-age-seconds",
        type=int,
        default=int(
            os.environ.get(
                "BRIDGE_ORPHAN_DIR_MIN_AGE_SECONDS", str(DEFAULT_MIN_AGE_SECONDS)
            )
            or DEFAULT_MIN_AGE_SECONDS
        ),
    )

    pr = sub.add_parser("prune", help="delete aged quarantine dirs (separate pass)")
    _add_common_args(pr)
    pr.add_argument(
        "--retain-days",
        type=int,
        default=int(
            os.environ.get(
                "BRIDGE_ORPHAN_QUARANTINE_RETAIN_DAYS", str(DEFAULT_RETAIN_DAYS)
            )
            or DEFAULT_RETAIN_DAYS
        ),
    )
    pr.add_argument("--dry-run", action="store_true")
    pr.add_argument("--force-prune", action="store_true")

    args = parser.parse_args(argv)

    if args.cmd == "quarantine":
        summary = run_quarantine(args)
    elif args.cmd == "prune":
        summary = run_prune(args)
    else:  # pragma: no cover — argparse `required=True` prevents this
        parser.error("unknown command")
        return 2

    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
