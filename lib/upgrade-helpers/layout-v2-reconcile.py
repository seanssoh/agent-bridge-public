#!/usr/bin/env python3
"""layout-v2-reconcile.py — idempotent v1->v2 agent-data reconciler (#1820).

Issue #1820: after the v0.15 layout split, four runtime writers kept appending
agent *memory* and capture state to the v1 ``<bridge_home>/agents/<a>`` tree
while interactive sessions read/write the v2
``<data_root>/agents/<a>/{home,workdir}`` tree, silently forking agent memory.
The companion writer fixes (cron resolver, PreCompact resolved-env, settings
render path, doc-sync target) stop *new* writes from landing on v1; this helper
reverse-reconciles the v1-only data that already accumulated, into v2 — once,
idempotently, as part of the gated migration in
``lib/bridge-layout-v2-reconcile.sh``.

CONTRACT (per the design verdict, agb-1820-design-verdict.md):
  * Never choose by mtime alone — content hashes + structural append checks.
    mtime is diagnostic only.
  * Missing on v2, present on v1 -> copy v1->v2, report ``copied_from_v1``.
  * Identical on both sides -> no-op (``identical``).
  * Append-like memory (MEMORY.md, users/*/MEMORY.md): if one side is an exact
    line-boundary prefix of the other, keep the superset in v2 and report the
    direction (``prefix_superset_v1`` / ``prefix_superset_v2``). If both sides
    have different suffixes -> keep the live v2 file, copy the v1 variant to a
    conflict archive under v2, write a marker, queue a manual task
    (``conflict_divergent``).
  * memory/** : copy v1-only relative files; identical no-op; divergent
    same-relative-path files preserve both with a conflict archive + manual
    queue task.
  * Generated settings/doc surfaces: NOT handled here (re-rendered by the v2
    writers; this helper deliberately skips them).
  * Idempotent: a second run after success produces zero new data changes and
    repeats the same summary.

This is a STANDALONE helper (file-as-argv, no heredoc-stdin) invoked by the
bash wrapper — same anti-deadlock contract as the other lib/upgrade-helpers/*.

Usage:
    layout-v2-reconcile.py \
        --bridge-home <abs> --data-root <abs> \
        --agents-csv <a,b,c> \
        [--mode apply|dry-run] \
        [--backup-root <abs>] \
        [--conflict-archive-root <abs>] \
        [--queue-task-dir <abs>]

Emits a single structured JSON object on stdout:
    {
      "mode": "apply"|"dry-run",
      "schema": "layout-v2-reconcile/1",
      "agents": [ ... per-agent ... ],
      "copied":     [ {agent, kind, rel, src, dst} ],
      "preserved":  [ {agent, kind, rel, direction, path} ],
      "conflicted": [ {agent, kind, rel, live, archived, marker, queue_task} ],
      "skipped":    [ {agent, kind, rel, reason} ],
      "warnings":   [ {agent, detail} ],
      "counts": {copied, preserved, conflicted, skipped, warnings}
    }

Exit code: 0 on success (including conflicts — conflicts are a reported outcome,
not a failure), non-zero only on an internal/unexpected error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "layout-v2-reconcile/1"

# Append-like memory files reconciled with the prefix/superset rule. Anything
# matching these (top-level MEMORY.md and any users/*/MEMORY.md) is treated as
# append-like; divergent suffixes archive + queue rather than overwrite.
APPEND_LIKE_TOP = "MEMORY.md"


def _now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_bytes(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except OSError:
        return None


def _is_line_boundary_prefix(shorter: bytes, longer: bytes) -> bool:
    """True iff ``shorter`` is a prefix of ``longer`` ending on a line boundary.

    Append-like files only legitimately differ by *appended* whole lines. A raw
    byte-prefix that splits a line (the shorter file was truncated mid-line) is
    NOT a clean append and must NOT be auto-merged — treat it as divergent.
    """
    if not longer.startswith(shorter):
        return False
    if len(shorter) == len(longer):
        return False  # identical handled separately
    # The byte at the split point (first byte of the appended remainder must
    # begin a new line, i.e. the prefix ended with a newline) OR the prefix is
    # empty (an empty file is a clean prefix of anything).
    if not shorter:
        return True
    return shorter.endswith(b"\n")


class Reconciler:
    def __init__(self, args: argparse.Namespace) -> None:
        self.bridge_home = Path(args.bridge_home).expanduser().resolve()
        self.data_root = Path(args.data_root).expanduser().resolve()
        self.mode = args.mode
        self.agents = [a for a in (args.agents_csv or "").split(",") if a.strip()]
        self.backup_root = (
            Path(args.backup_root).expanduser().resolve() if args.backup_root else None
        )
        self.conflict_archive_root = (
            Path(args.conflict_archive_root).expanduser().resolve()
            if args.conflict_archive_root
            else None
        )
        self.queue_task_dir = (
            Path(args.queue_task_dir).expanduser().resolve()
            if args.queue_task_dir
            else None
        )
        self.stamp = _now_stamp()

        self.copied: list[dict] = []
        self.preserved: list[dict] = []
        self.conflicted: list[dict] = []
        self.skipped: list[dict] = []
        self.warnings: list[dict] = []
        self.agent_summaries: list[dict] = []
        self.backed_up: list[dict] = []
        self._cur_v1_home: Path | None = None
        self._cur_v2_home: Path | None = None

    # --- path helpers --------------------------------------------------------
    def _v1_agent_home(self, agent: str) -> Path:
        return self.bridge_home / "agents" / agent

    def _v2_agent_home(self, agent: str) -> Path:
        return self.data_root / "agents" / agent / "home"

    def _within(self, child: Path, parent: Path) -> bool:
        try:
            child.resolve().relative_to(parent.resolve())
            return True
        except (ValueError, OSError):
            return False

    # --- recording helpers ---------------------------------------------------
    def _warn(self, agent: str, detail: str) -> None:
        self.warnings.append({"agent": agent, "detail": detail})

    def _skip(self, agent: str, kind: str, rel: str, reason: str) -> None:
        self.skipped.append(
            {"agent": agent, "kind": kind, "rel": rel, "reason": reason}
        )

    # --- mutation primitives (no-op in dry-run) ------------------------------
    def _backup(self, agent: str, side: str, src: Path, rel: str) -> None:
        if self.mode != "apply" or self.backup_root is None:
            return
        try:
            dst = self.backup_root / agent / side / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        except OSError as exc:
            self._warn(agent, f"backup failed for {side}:{rel}: {exc}")

    def _pre_mutation_backup(self, agent: str, v1_home: Path, v2_home: Path) -> None:
        """Snapshot BOTH sides' reconcile surfaces before any write.

        Verdict "Recovery gate": the backup manifest must include both v1 and v2
        state before apply. This runs once per agent at the top of the walk, so
        the manifest exists even if a later per-file decision raises. No-op in
        dry-run (backup_root unset / mode != apply makes _backup a no-op).
        """
        if self.mode != "apply" or self.backup_root is None:
            return
        for side, home in (("v1", v1_home), ("v2", v2_home)):
            for rel in (APPEND_LIKE_TOP,):
                f = home / rel
                if f.is_file() and not f.is_symlink():
                    self._backup(agent, side, f, rel)
                    self.backed_up.append({"agent": agent, "side": side, "rel": rel})
            users = home / "users"
            if users.is_dir():
                for user_dir in sorted(p for p in users.iterdir() if p.is_dir()):
                    rel = f"users/{user_dir.name}/{APPEND_LIKE_TOP}"
                    f = home / rel
                    if f.is_file() and not f.is_symlink():
                        self._backup(agent, side, f, rel)
                        self.backed_up.append({"agent": agent, "side": side, "rel": rel})
            mem = home / "memory"
            if mem.is_dir():
                for src in sorted(mem.rglob("*")):
                    if src.is_file() and not src.is_symlink():
                        try:
                            rel = str(src.relative_to(home))
                        except ValueError:
                            continue
                        self._backup(agent, side, src, rel)
                        self.backed_up.append({"agent": agent, "side": side, "rel": rel})

    def _copy(self, agent: str, kind: str, rel: str, src: Path, dst: Path) -> None:
        self.copied.append(
            {
                "agent": agent,
                "kind": kind,
                "rel": rel,
                "src": str(src),
                "dst": str(dst),
            }
        )
        if self.mode != "apply":
            return
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            # #1820 r3 (codex): if dst is a symlink (broken or otherwise), unlink
            # it FIRST so we write a real file at dst — never follow the link and
            # write THROUGH it to an unexpected (possibly out-of-tree) target. The
            # foreign-symlink guard already rejects escaping links upstream; this
            # is defense-in-depth for an in-home symlink dst.
            if os.path.islink(dst):
                dst.unlink()
            shutil.copy2(src, dst)
        except OSError as exc:
            self._warn(agent, f"copy failed {rel}: {exc}")

    def _conflict_dedup_marker(self, agent: str, rel: str, pair_hash: str) -> Path:
        """Stable per-conflict dedup marker (timestamp-independent).

        Idempotence (verdict): a second apply after a divergent conflict must
        produce ZERO new data changes — it must NOT re-archive the same v1/v2
        variant under a fresh timestamp each run. The dedup marker is keyed on
        the (agent, rel, v1-hash, v2-hash) pair, so an unchanged conflict is
        recognized and re-archiving is skipped (the conflict is still *reported*
        in the summary, satisfying "only repeats the same summary").
        """
        safe_rel = rel.replace("/", "__")
        ledger = self.data_root / "agents" / agent / "home" / ".reconcile-conflicts"
        return ledger / f".seen-{safe_rel}-{pair_hash}.json"

    def _archive_conflict(
        self,
        agent: str,
        kind: str,
        rel: str,
        v1_src: Path,
        live_v2: Path,
        pair_hash: str = "",
    ) -> None:
        archive_root = self.conflict_archive_root or (
            self.data_root / "agents" / agent / "home" / ".reconcile-conflicts"
        )
        # Idempotence: skip re-archiving an already-recorded identical conflict.
        dedup = self._conflict_dedup_marker(agent, rel, pair_hash) if pair_hash else None
        already_seen = bool(dedup and dedup.is_file())
        archived = archive_root / self.stamp / rel
        marker = archived.with_name(archived.name + ".CONFLICT.md")
        queue_task = None
        if self.queue_task_dir is not None:
            safe_rel = rel.replace("/", "__")
            queue_task = (
                self.queue_task_dir
                / f"reconcile-conflict-{agent}-{safe_rel}-{self.stamp}.md"
            )
        record = {
            "agent": agent,
            "kind": kind,
            "rel": rel,
            "live": str(live_v2),
            "archived": None if already_seen else str(archived),
            "marker": None if already_seen else str(marker),
            "queue_task": None if already_seen else (str(queue_task) if queue_task else None),
            "already_archived": already_seen,
        }
        self.conflicted.append(record)
        if self.mode != "apply" or already_seen:
            # dry-run writes nothing; an already-seen conflict is reported but
            # NOT re-written (idempotence: zero new data changes on re-apply).
            return
        try:
            archived.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(v1_src, archived)
            marker.write_text(
                self._conflict_marker_text(agent, rel, live_v2, archived),
                encoding="utf-8",
            )
        except OSError as exc:
            self._warn(agent, f"conflict archive failed {rel}: {exc}")
            return
        if queue_task is not None:
            try:
                queue_task.parent.mkdir(parents=True, exist_ok=True)
                queue_task.write_text(
                    self._queue_task_text(agent, rel, live_v2, archived),
                    encoding="utf-8",
                )
            except OSError as exc:
                self._warn(agent, f"queue-task write failed {rel}: {exc}")
        # Record the dedup marker so a re-apply recognizes this exact conflict
        # and does not re-archive it (idempotence).
        if dedup is not None:
            try:
                dedup.parent.mkdir(parents=True, exist_ok=True)
                dedup.write_text(
                    json.dumps(
                        {
                            "agent": agent,
                            "rel": rel,
                            "archived": str(archived),
                            "stamp": self.stamp,
                        },
                        ensure_ascii=False,
                    ),
                    encoding="utf-8",
                )
            except OSError as exc:
                self._warn(agent, f"conflict dedup marker failed {rel}: {exc}")

    def _conflict_marker_text(
        self, agent: str, rel: str, live: Path, archived: Path
    ) -> str:
        return (
            f"# layout-v2 reconcile conflict (#1820)\n\n"
            f"- agent: `{agent}`\n"
            f"- relative path: `{rel}`\n"
            f"- live (v2, kept): `{live}`\n"
            f"- archived v1 variant: `{archived}`\n"
            f"- detected: {self.stamp}\n\n"
            f"The v1 and v2 copies diverged (different suffixes, neither a clean "
            f"line-boundary prefix of the other). The v2 file was kept live and "
            f"the v1 variant archived here for manual merge. Reconcile by hand, "
            f"then delete this marker.\n"
        )

    def _queue_task_text(
        self, agent: str, rel: str, live: Path, archived: Path
    ) -> str:
        return (
            f"[reconcile-conflict] {agent}: divergent v1/v2 memory `{rel}`\n\n"
            f"Issue #1820 layout-v2 reconcile found a divergent memory file for "
            f"agent `{agent}`.\n\n"
            f"- live (v2, kept): {live}\n"
            f"- archived v1 variant: {archived}\n\n"
            f"Action: manually merge any unique v1 entries into the live v2 file, "
            f"then remove the archive + CONFLICT marker.\n"
        )

    def _foreign_symlink(self, path: Path, home: Path) -> bool:
        """True if ``path`` is a symlink whose real target escapes ``home``.

        Fail-closed guard (#1820 r2, codex): applies to EVERY reconciled file —
        top-level MEMORY.md, users/*/MEMORY.md, and memory/** — not just the
        memory tree. A v1 (or v2) file that is actually a symlink pointing
        outside the agent home must never be copied/adopted/archived, or it
        could exfiltrate or clobber arbitrary paths.
        """
        try:
            if not path.is_symlink():
                return False
        except OSError:
            return True
        target = Path(os.path.realpath(path))
        return not self._within(target, home)

    # --- per-file reconcile --------------------------------------------------
    def _reconcile_file(
        self, agent: str, kind: str, rel: str, v1: Path, v2: Path, append_like: bool
    ) -> None:
        # Universal fail-closed symlink guard (both sides). Check v2 with
        # os.path.islink (NOT .exists) — a BROKEN v2 symlink does not "exist" but
        # is still a symlink that a copy/adopt would write THROUGH to its escape
        # target (#1820 r3, codex). Guard it regardless of existence.
        if self._cur_v1_home is not None and self._foreign_symlink(v1, self._cur_v1_home):
            self._skip(agent, kind, rel, "foreign_symlink")
            return
        if self._cur_v2_home is not None and os.path.islink(v2):
            if self._foreign_symlink(v2, self._cur_v2_home):
                self._skip(agent, kind, rel, "foreign_symlink_v2")
                return
        v1_exists = v1.is_file()
        v2_exists = v2.is_file()
        if not v1_exists:
            # v1-only is the whole point; if v1 is absent there is nothing to
            # reverse-reconcile.
            self._skip(agent, kind, rel, "absent_on_v1")
            return
        v1_bytes = _read_bytes(v1)
        if v1_bytes is None:
            self._skip(agent, kind, rel, "v1_unreadable")
            return

        if not v2_exists:
            self._backup(agent, "v1", v1, rel)
            self._copy(agent, kind, rel, v1, v2)
            return

        v2_bytes = _read_bytes(v2)
        if v2_bytes is None:
            self._skip(agent, kind, rel, "v2_unreadable")
            return

        if _sha256_bytes(v1_bytes) == _sha256_bytes(v2_bytes):
            self.skipped.append(
                {"agent": agent, "kind": kind, "rel": rel, "reason": "identical"}
            )
            return

        # Both present, differ. Back up both sides before any decision.
        self._backup(agent, "v1", v1, rel)
        self._backup(agent, "v2", v2, rel)

        if append_like:
            # v2 is a clean prefix of v1 -> v1 is the superset; adopt v1 into v2.
            if _is_line_boundary_prefix(v2_bytes, v1_bytes):
                self.preserved.append(
                    {
                        "agent": agent,
                        "kind": kind,
                        "rel": rel,
                        "direction": "prefix_superset_v1",
                        "path": str(v2),
                    }
                )
                if self.mode == "apply":
                    try:
                        v2.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(v1, v2)
                    except OSError as exc:
                        self._warn(agent, f"superset adopt failed {rel}: {exc}")
                return
            # v1 is a clean prefix of v2 -> v2 already the superset; keep v2.
            if _is_line_boundary_prefix(v1_bytes, v2_bytes):
                self.preserved.append(
                    {
                        "agent": agent,
                        "kind": kind,
                        "rel": rel,
                        "direction": "prefix_superset_v2",
                        "path": str(v2),
                    }
                )
                return
            # Divergent suffixes -> archive v1, keep v2 live, queue manual task.
            pair_hash = _sha256_bytes(v1_bytes + b"\x00" + v2_bytes)[:16]
            self._archive_conflict(agent, kind, rel, v1, v2, pair_hash)
            return

        # Non-append-like under memory/** that differ -> divergent: preserve
        # both via conflict archive + manual task (verdict memory/** rule).
        pair_hash = _sha256_bytes(v1_bytes + b"\x00" + v2_bytes)[:16]
        self._archive_conflict(agent, kind, rel, v1, v2, pair_hash)

    # --- per-agent walk ------------------------------------------------------
    def _reconcile_agent(self, agent: str) -> None:
        v1_home = self._v1_agent_home(agent)
        v2_home = self._v2_agent_home(agent)
        summary = {
            "agent": agent,
            "v1_home": str(v1_home),
            "v2_home": str(v2_home),
            "v1_present": v1_home.is_dir(),
            "v2_present": v2_home.is_dir(),
        }
        self.agent_summaries.append(summary)

        if not v1_home.is_dir():
            self._skip(agent, "agent", ".", "no_v1_home")
            return
        if not v2_home.is_dir():
            # Per verdict: v2 home must exist for a rostered v2 agent. If it is
            # absent we fail closed (skip) rather than fabricate the tree — the
            # gated wrapper treats this as a warning the operator must resolve.
            self._skip(agent, "agent", ".", "no_v2_home")
            self._warn(agent, "v2 home absent; skipped (fail-closed)")
            return

        self._cur_v1_home = v1_home
        self._cur_v2_home = v2_home

        # Pre-mutation backup (#1820 r2, codex / verdict "Recovery gate"):
        # snapshot BOTH v1 and v2 reconcile surfaces for this agent BEFORE any
        # write begins, so a manifest of both sides exists independent of the
        # per-decision backups below. Backs up only the files the reconcile will
        # touch (MEMORY.md, users/*/MEMORY.md, memory/**) on each side.
        self._pre_mutation_backup(agent, v1_home, v2_home)

        # 1. Top-level append-like MEMORY.md
        self._reconcile_file(
            agent,
            "memory_top",
            APPEND_LIKE_TOP,
            v1_home / APPEND_LIKE_TOP,
            v2_home / APPEND_LIKE_TOP,
            append_like=True,
        )

        # 2. users/*/MEMORY.md (append-like)
        v1_users = v1_home / "users"
        if v1_users.is_dir():
            for user_dir in sorted(p for p in v1_users.iterdir() if p.is_dir()):
                rel = f"users/{user_dir.name}/{APPEND_LIKE_TOP}"
                self._reconcile_file(
                    agent,
                    "memory_user",
                    rel,
                    v1_home / rel,
                    v2_home / rel,
                    append_like=True,
                )

        # 3. memory/** (copy v1-only; identical no-op; divergent -> archive)
        v1_mem = v1_home / "memory"
        if v1_mem.is_dir():
            for src in sorted(v1_mem.rglob("*")):
                if not src.is_file():
                    continue
                try:
                    rel = str(src.relative_to(v1_home))
                except ValueError:
                    continue
                # Fail-closed on a symlink / foreign path that escapes v1_home.
                if src.is_symlink():
                    target = os.path.realpath(src)
                    if not self._within(Path(target), v1_home):
                        self._skip(agent, "memory_tree", rel, "foreign_symlink")
                        continue
                self._reconcile_file(
                    agent,
                    "memory_tree",
                    rel,
                    src,
                    v2_home / rel,
                    append_like=False,
                )

    def run(self) -> dict:
        for agent in self.agents:
            try:
                self._reconcile_agent(agent)
            except Exception as exc:  # pragma: no cover — defensive
                self._warn(agent, f"unexpected error: {exc}")
        return {
            "mode": self.mode,
            "schema": SCHEMA,
            "bridge_home": str(self.bridge_home),
            "data_root": str(self.data_root),
            "stamp": self.stamp,
            "agents": self.agent_summaries,
            "copied": self.copied,
            "preserved": self.preserved,
            "conflicted": self.conflicted,
            "skipped": self.skipped,
            "warnings": self.warnings,
            "backed_up": self.backed_up,
            "counts": {
                "copied": len(self.copied),
                "preserved": len(self.preserved),
                "conflicted": len(self.conflicted),
                "skipped": len(self.skipped),
                "warnings": len(self.warnings),
                "backed_up": len(self.backed_up),
            },
        }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="layout-v2 v1->v2 reconciler (#1820)")
    parser.add_argument("--bridge-home", required=True)
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--agents-csv", default="")
    parser.add_argument("--mode", choices=("apply", "dry-run"), default="dry-run")
    parser.add_argument("--backup-root", default="")
    parser.add_argument("--conflict-archive-root", default="")
    parser.add_argument("--queue-task-dir", default="")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    reconciler = Reconciler(args)
    result = reconciler.run()
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
