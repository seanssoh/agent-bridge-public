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
      "isolation_v2_migration": [ {agent, os_user, action, reason, detail} ],
      "counts": {copied, preserved, conflicted, skipped, warnings, ...}
    }

iso v2 (#1820 rc3): an iso agent's agent-private memory is owned by its iso UID
at mode 0600/0700 and is NOT readable by the controller that runs this
reconcile. For each agent passed in ``--iso-agents-json`` the reconcile
GRACEFUL-SKIPS the controller-side backup + v1->v2 memory pass (no Errno13
perm-read) and records a structured ``isolation_v2_migration`` entry
(``action: skipped-iso-private``) instead of an unstructured warning. The
fencing/conflict DATA logic is unchanged — it simply is not entered for iso
agents.

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

# Common iso-v2 controller-boundary classifier (#1820 rc4). This standalone
# helper lives in lib/upgrade-helpers/, so the shared module sits one level up
# in lib/. Import it via a sys.path-relative insert that works under the
# file-as-argv invocation (footgun #11 — no package install, no PYTHONPATH
# assumption). If the import is ever unavailable (a stripped-down install), the
# file-level iso skip below degrades to the prior behavior (a per-file
# PermissionError stays a warning), never crashing.
_RECONCILE_LIB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _RECONCILE_LIB_DIR not in sys.path:
    sys.path.insert(0, _RECONCILE_LIB_DIR)
try:
    from bridge_iso_boundary import (
        is_permission_error as _iso_is_permission_error,
    )
except ImportError:  # pragma: no cover — stripped-down install fallback
    _iso_is_permission_error = None

SCHEMA = "layout-v2-reconcile/1"

# #1820 rc4 (item 4, A2): structured reason token for a per-FILE owner-only iso
# skip. Distinct from the rc3 up-front ``iso-agent-private`` (now removed) so
# last-apply.json records WHY a single agent-private 0600 file was skipped — the
# controller could not read it even with a fresh group set because it is genuine
# owner-only (mode 0600, owned by the iso UID). File-level granularity, not map-
# gated: correctness does not depend on iso-map completeness.
ISO_FILE_OWNER_ONLY_REASON = "file-owner-only"

# Append-like memory files reconciled with the prefix/superset rule. Anything
# matching these (top-level MEMORY.md and any users/*/MEMORY.md) is treated as
# append-like; divergent suffixes archive + queue rather than overwrite.
APPEND_LIKE_TOP = "MEMORY.md"


def _now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_bytes(path: Path) -> bytes | None:
    """Read ``path`` bytes, returning None on a NON-permission OSError.

    #1820 rc4 (item 4): a controller-side permission denial (PermissionError /
    EACCES / EPERM) is RE-RAISED rather than collapsed to None so the caller can
    classify a genuine 0600 owner-only iso file as a structured graceful-skip
    (reason file-owner-only) instead of an ``unreadable`` data-skip. Every other
    OSError (a transient read error, ENOENT-after-stat race, …) still maps to
    None → the existing ``*_unreadable`` skip, byte-identical to before.
    """
    try:
        return path.read_bytes()
    except OSError as exc:
        if _iso_is_permission_error is not None and _iso_is_permission_error(exc):
            raise
        if isinstance(exc, PermissionError):
            raise
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
        # iso v2 agents: a map {agent_id: os_user} (#1820 rc3, kept rc4 for the
        # os_user lookup ONLY — NOT as a skip gate). cm-prod real-host evidence
        # proved this registry-derived iso-map is INCOMPLETE (e.g.
        # cosmax_sales_mdj has no agent-meta.env, so a map misses it). The rc3
        # up-front whole-agent skip keyed on this map (the #1876 early-return) is
        # therefore REMOVED in rc4 (item 4 / A2): correctness must NOT depend on
        # iso-map completeness. We ALWAYS traverse every agent home (now possible
        # post fresh-group preflight) and reconcile ALL group-readable content,
        # skipping ONLY genuine 0600 owner-only files at FILE granularity (see
        # _record_iso_file_skip). The map survives solely so a file-level skip can
        # annotate os_user when the agent happens to be classified — an empty
        # os_user (the cm-prod mdj case) is fine and never blocks the file-level
        # skip.
        self.iso_agents: dict[str, str] = self._load_iso_agents(args.iso_agents_json)
        # File-level iso skip host gate (#1820 rc4, item 4). On a Linux iso-v2
        # host a per-file PermissionError on an agent-private file is the EXPECTED
        # owner-only (0600) boundary → a structured graceful-skip. Off such a host
        # (shared-mode / macOS / non-iso) a per-file PermissionError is GENUINE
        # and stays a warning (byte-identical to main). This is a FILE-LEVEL gate
        # only — it never whole-home-skips an agent (the retracted rc4 belt did,
        # removed in item 3). Passed host-level by the wrapper (Linux + at least
        # one rostered agent requesting linux-user isolation), independent of
        # iso-map completeness.
        self.iso_host: bool = bool(args.iso_host)
        self.stamp = _now_stamp()

        self.copied: list[dict] = []
        self.preserved: list[dict] = []
        self.conflicted: list[dict] = []
        self.skipped: list[dict] = []
        self.warnings: list[dict] = []
        self.agent_summaries: list[dict] = []
        self.backed_up: list[dict] = []
        # Structured per-iso-agent audit of the isolation-v2 memory pass so the
        # iso permission handling is auditable in last-apply.json rather than
        # falling to unstructured warnings (#1820 rc3 observability). In rc4 each
        # entry is a per-FILE owner-only skip (reason file-owner-only).
        self.isolation_v2_migration: list[dict] = []
        # Per-(agent, rel) keys already recorded as a file-owner-only iso skip,
        # so an idempotent re-run / a backup+reconcile double-touch of the SAME
        # 0600 file does not double-count (#1820 rc4).
        self._iso_file_skipped: set[tuple[str, str]] = set()
        self._cur_v1_home: Path | None = None
        self._cur_v2_home: Path | None = None

    @staticmethod
    def _load_iso_agents(path_arg: str | None) -> dict[str, str]:
        """Load the {agent_id: os_user} iso map from a file-as-argv JSON path.

        File-as-argv (not inline) keeps the anti-deadlock contract (footgun #11)
        and avoids passing a potentially large/odd map on the command line. A
        missing path, empty value, or malformed file means "no iso agents" — the
        reconcile then behaves exactly as it did before this fix (shared-mode).
        Only string->string entries with non-empty keys/values are kept.
        """
        if not path_arg:
            return {}
        try:
            raw = Path(path_arg).expanduser().read_text(encoding="utf-8")
        except OSError:
            return {}
        try:
            data = json.loads(raw)
        except (ValueError, TypeError):
            return {}
        if not isinstance(data, dict):
            return {}
        out: dict[str, str] = {}
        for k, v in data.items():
            if isinstance(k, str) and isinstance(v, str) and k.strip() and v.strip():
                out[k] = v
        return out

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

    # --- file-level iso owner-only skip (#1820 rc4, item 4 / A2) -------------
    def _is_iso_file_permission_error(self, exc: BaseException) -> bool:
        """True iff ``exc`` is a controller-side permission denial (PermissionError
        / EACCES / EPERM) on a Linux iso-v2 host — i.e. a genuine 0600 owner-only
        agent-private file the controller cannot read even with a fresh group
        set. Off an iso host (shared-mode / macOS / non-iso) this is False, so a
        per-file PermissionError there stays a warning (byte-identical to main —
        we never blanket-swallow). If the common classifier failed to import we
        conservatively treat NOTHING as an iso boundary (warning preserved)."""
        if not self.iso_host:
            return False
        if _iso_is_permission_error is None:
            return False
        return _iso_is_permission_error(exc)

    def _record_iso_file_skip(
        self, agent: str, kind: str, rel: str, exc: BaseException
    ) -> None:
        """Record a STRUCTURED per-FILE graceful-skip for a genuine 0600
        owner-only agent-private file the controller could not read (#1820 rc4
        item 4). FILE granularity — the agent home was traversed (post fresh-
        group preflight); only THIS owner-only file is skipped, not the whole
        agent. Idempotent per (agent, rel) so a backup+reconcile double-touch of
        the same 0600 file records one entry. os_user is annotated from the iso
        map when the agent happens to be classified, else empty (the cm-prod mdj
        case — a missing agent-meta.env never blocks the file-level skip, which
        is the whole point of NOT depending on iso-map completeness)."""
        key = (agent, rel)
        if key in self._iso_file_skipped:
            return
        self._iso_file_skipped.add(key)
        self.isolation_v2_migration.append(
            {
                "agent": agent,
                "os_user": self.iso_agents.get(agent, ""),
                "action": "skipped-iso-private",
                "reason": ISO_FILE_OWNER_ONLY_REASON,
                "kind": kind,
                "rel": rel,
                "detail": (
                    f"controller could not read agent-private file {kind}:{rel} "
                    f"({exc.__class__.__name__}: {exc}); it is owner-only (0600) "
                    "owned by the iso UID, which owns and manages it — "
                    "controller backup/reconcile of it is the wrong contract "
                    "(file-level graceful-skip)"
                ),
            }
        )
        self._skip(agent, kind, rel, "iso_file_owner_only")

    # --- mutation primitives (no-op in dry-run) ------------------------------
    def _backup(self, agent: str, side: str, src: Path, rel: str) -> None:
        if self.mode != "apply" or self.backup_root is None:
            return
        try:
            dst = self.backup_root / agent / side / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        except OSError as exc:
            # File-level iso skip (#1820 rc4 item 4): a controller-side permission
            # denial backing up an iso agent's 0600 owner-only file is the
            # expected per-file boundary on a Linux iso-v2 host — record a
            # structured file-level skip, not a "backup failed" warning. Off an
            # iso host (or any non-permission OSError) it stays a warning,
            # byte-identical to before.
            if self._is_iso_file_permission_error(exc):
                self._record_iso_file_skip(agent, side, rel, exc)
            else:
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
        archived_probe = archive_root / self.stamp / rel
        # Finding 1 (#1820 gate-2): the conflict-archive destination is a SEPARATE
        # write path from the reconcile dst (it lands under .reconcile-conflicts/,
        # not the v2 file). Guard its full chain too — a symlinked parent under
        # the archive root (or an escaping conflict_archive_root) must fail closed
        # before we mkdir+copy2 through it.
        #
        # Two fences are required (gate-2 r2, codex):
        #   * the per-conflict path must stay under the archive root, AND
        #   * the archive root itself must stay under data_root — otherwise an
        #     explicit --conflict-archive-root with a SYMLINKED ANCESTOR (between
        #     data_root and the archive root) would slip through, because fencing
        #     the per-conflict path against the archive root alone never checks
        #     ancestors ABOVE that root. Both default and explicit archive roots
        #     must resolve under data_root.
        if self.mode == "apply":
            if not self._path_chain_fenced(archived_probe, archive_root):
                self._skip(agent, kind, rel, "foreign_path_chain_archive")
                return
            if not self._path_chain_fenced(archive_root, self.data_root):
                self._skip(agent, kind, rel, "foreign_path_chain_archive")
                return
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

    def _path_chain_fenced(self, path: Path, home: Path) -> bool:
        """True iff EVERY component of ``path`` stays fenced under ``home``.

        Finding 1 (#1820 gate-2, patch-dev): the final-path-only foreign-symlink
        check (``_foreign_symlink``) misses a symlinked PARENT directory. If e.g.
        ``<v2_home>/memory`` is a symlink pointing outside the v2 home, then
        ``shutil.copy2(src, <v2_home>/memory/x.md)`` follows the parent symlink
        and writes OUTSIDE the fenced tree even though the final component is not
        itself a symlink. ``dst.parent.mkdir(parents=True)`` likewise materializes
        through the escaping parent.

        This guard walks the ENTIRE chain from ``home`` down to ``path`` (every
        intermediate parent AND the final component) and fails closed unless the
        resolved real target of each existing component remains under the resolved
        ``home``. It is symmetric for source (read/archive) and destination
        (copy/adopt) chains.

        Rules / edge cases:
          * ``home`` itself must resolve under itself (it does by definition once
            ``os.path.realpath`` is applied to both — we compare realpaths).
          * A component that does not yet exist (a leaf to be created, or a
            not-yet-materialized parent) is fine PROVIDED no already-existing
            ancestor of it escapes — i.e. we only need every *existing* prefix to
            stay fenced, because a missing component cannot itself redirect.
          * A BROKEN symlink anywhere in the chain fails closed (os.path.realpath
            of a dangling link resolves to a path that will NOT be under home, and
            even if it coincidentally were, lstat/readlink errors are treated as
            escape). We never crash on a dangling link.
          * Any OSError while inspecting a component => fail closed (return False).
        """
        try:
            home_real = os.path.realpath(home)
        except OSError:
            return False
        # Build the list of components from home down to the final path. We only
        # care about the path segments at or below home; a path that is not even
        # nominally under home is rejected outright.
        try:
            rel = path.resolve(strict=False).relative_to(Path(home).resolve(strict=False))
        except (ValueError, OSError):
            # path is not nominally under home (or unresolvable) -> reject.
            return False
        # Walk each prefix: home, home/p1, home/p1/p2, ... home/.../final.
        cur = Path(home)
        chain = [cur]
        for part in rel.parts:
            cur = cur / part
            chain.append(cur)
        for component in chain:
            try:
                is_link = os.path.islink(component)
            except OSError:
                return False
            if is_link:
                # A symlink (broken or not): its real target must stay under home.
                try:
                    target_real = os.path.realpath(component)
                except OSError:
                    return False
                if not self._realpath_within(target_real, home_real):
                    return False
            else:
                # Not a symlink. If it exists, its own realpath must stay fenced
                # (guards a parent that is itself reached through an escaping
                # symlink earlier in the chain — defense in depth). A missing
                # non-link component is fine (nothing to redirect yet).
                try:
                    exists = os.path.lexists(component)
                except OSError:
                    return False
                if exists:
                    try:
                        comp_real = os.path.realpath(component)
                    except OSError:
                        return False
                    if not self._realpath_within(comp_real, home_real):
                        return False
        return True

    def _home_anchored(self, home: Path, root: Path) -> bool:
        """True iff every component of ``home`` stays fenced under ``root``.

        Finding 1 (#1820 gate-2 r2): the agent home directory may ITSELF be a
        symlink (e.g. ``data_root/agents/<a>/home`` -> /outside). Comparing
        ``realpath(home)`` to ``realpath(home)`` is trivially true and misses
        this. Instead we require the WHOLE chain from ``root`` (the resolved
        bridge_home / data_root) down to ``home`` to stay fenced — every parent
        AND the home component's own realpath must remain under ``realpath(root)``.
        A home that is a symlink escaping ``root`` (or reached through an escaping
        parent) fails closed. This reuses the same chain logic as the per-file
        guard, so the home root is fenced with the same rigor as its contents.
        Fails closed on any resolution error.
        """
        return self._path_chain_fenced(home, root)

    @staticmethod
    def _realpath_within(child_real: str, parent_real: str) -> bool:
        """True iff resolved ``child_real`` is ``parent_real`` or a descendant.

        Pure realpath-string containment (both args already os.path.realpath'd),
        with a path-separator boundary so ``/a/bc`` is NOT treated as under
        ``/a/b``.
        """
        if child_real == parent_real:
            return True
        prefix = parent_real.rstrip(os.sep) + os.sep
        return child_real.startswith(prefix)

    def _chains_fenced(
        self, agent: str, kind: str, rel: str, src: Path, dst: Path
    ) -> bool:
        """Guard BOTH the source and destination path chains before a write.

        Returns True only when every component of ``src`` stays under the v1 home
        AND every component of ``dst`` stays under the v2 home. On any escape /
        broken-symlink-parent / error it records a fail-closed skip and returns
        False so the caller aborts the copy/adopt/archive for this rel.
        """
        v1_home = self._cur_v1_home
        v2_home = self._cur_v2_home
        if v1_home is not None and not self._path_chain_fenced(src, v1_home):
            self._skip(agent, kind, rel, "foreign_path_chain_src")
            return False
        if v2_home is not None and not self._path_chain_fenced(dst, v2_home):
            self._skip(agent, kind, rel, "foreign_path_chain_dst")
            return False
        return True

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
        # Finding 1 (#1820 gate-2): guard the ENTIRE source AND destination path
        # chains — every parent dir AND the final component — before any read /
        # copy / adopt / archive. A symlinked PARENT (e.g. v2_home/memory -> an
        # outside dir) would otherwise be followed by dst.parent.mkdir + copy2 and
        # write OUTSIDE the fenced tree, which the final-path-only symlink guard
        # above misses. Fail closed on any escape or broken-symlink parent.
        if not self._chains_fenced(agent, kind, rel, v1, v2):
            return

        v1_exists = v1.is_file()
        v2_exists = v2.is_file()
        if not v1_exists:
            # v1-only is the whole point; if v1 is absent there is nothing to
            # reverse-reconcile.
            self._skip(agent, kind, rel, "absent_on_v1")
            return
        # #1820 rc4 (item 4): a per-file PermissionError reading a genuine 0600
        # owner-only iso file on a Linux iso-v2 host is a structured file-level
        # graceful-skip (reason file-owner-only), NOT a data-skip / warning. Off
        # an iso host the PermissionError is genuine and falls through to the
        # legacy v1_unreadable data-skip (byte-identical to main). _read_bytes
        # re-raises only permission errors; other OSErrors still return None.
        try:
            v1_bytes = _read_bytes(v1)
        except PermissionError as exc:
            if self._is_iso_file_permission_error(exc):
                self._record_iso_file_skip(agent, kind, rel, exc)
            else:
                self._skip(agent, kind, rel, "v1_unreadable")
            return
        if v1_bytes is None:
            self._skip(agent, kind, rel, "v1_unreadable")
            return

        if not v2_exists:
            self._backup(agent, "v1", v1, rel)
            self._copy(agent, kind, rel, v1, v2)
            return

        try:
            v2_bytes = _read_bytes(v2)
        except PermissionError as exc:
            if self._is_iso_file_permission_error(exc):
                self._record_iso_file_skip(agent, kind, rel, exc)
            else:
                self._skip(agent, kind, rel, "v2_unreadable")
            return
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

        # #1820 rc4 (item 4 / A2): the rc3 #1876 up-front whole-agent iso-map
        # skip that lived here (an early-return when iso_agents.get(agent) was
        # truthy) is REMOVED. cm-prod real-host evidence proved the iso-map is
        # INCOMPLETE (cosmax_sales_mdj has no agent-meta.env → a map misses it),
        # so a map-gated whole-agent skip both (a) wrongly whole-skipped
        # map-covered agents whose group-readable content SHOULD reconcile, and
        # (b) missed map-absent iso bots that then died at os.scandir(home). The
        # fix: ALWAYS traverse the home (now controller-readable post fresh-group
        # preflight) and reconcile ALL group-readable content; skip ONLY genuine
        # 0600 owner-only files at FILE granularity (_record_iso_file_skip in
        # _reconcile_file / _backup). Correctness no longer depends on iso-map
        # completeness.

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

        # Finding 1 (#1820 gate-2 r2, codex): the AGENT HOME ITSELF may be a
        # symlink. If v2_home (or v1_home) resolves OUTSIDE its expected root,
        # then using realpath(home) as the fence would point the fence AT the
        # escape target, so every in-home write "passes" the chain guard while
        # actually landing outside. Reject a home whose realpath escapes the
        # expected v1/v2 agents root BEFORE any per-file work. The fence we hand
        # to _path_chain_fenced below is the NOMINAL (un-resolved) home so a
        # symlinked sub-path is still measured against where the home is supposed
        # to live, not against where a symlinked home points.
        if not self._home_anchored(v1_home, self.bridge_home):
            self._skip(agent, "agent", ".", "foreign_v1_home")
            self._warn(agent, "v1 home escapes expected root; skipped (fail-closed)")
            return
        if not self._home_anchored(v2_home, self.data_root):
            self._skip(agent, "agent", ".", "foreign_v2_home")
            self._warn(agent, "v2 home escapes expected root; skipped (fail-closed)")
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
        # Finding 3 (#1820 gate-2 r2, codex): a BROKEN or escaping v1 memory/
        # symlink makes v1_mem.is_dir() False, so the walk below would silently
        # skip it with NO classification — masking a fail-closed event. Detect the
        # symlinked-parent case explicitly and record foreign_path_chain_src so the
        # operator sees that v1 memory was refused (not "no memory tree").
        if os.path.islink(v1_mem):
            real = os.path.realpath(v1_mem)
            if not self._realpath_within(real, os.path.realpath(v1_home)):
                self._skip(agent, "memory_tree", "memory", "foreign_path_chain_src")
                v1_mem = None  # type: ignore[assignment]
        if v1_mem is not None and v1_mem.is_dir():
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
                # #1820 rc4 (item 3): the retracted whole-home defensive belt
                # (PermissionError reaching the 2770 home → silent whole-home
                # graceful-skip) is REMOVED. With the fresh-group preflight (item
                # 1) the home scandir succeeds; a RESIDUAL home-scandir
                # PermissionError after the preflight means the refresh could not
                # be applied (e.g. `sg` unavailable) and is a real operator-
                # actionable condition — it surfaces as an unstructured warning
                # (the item-1 WARN path), NEVER a silent whole-home skip. The
                # file-level 0600 skip (item 4) is the SOLE skip mechanism and it
                # fires inside _reconcile_agent at file granularity, not here.
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
            # Structured iso-v2 memory pass audit (#1820 rc3): one entry per iso
            # agent whose agent-private memory was graceful-skipped (or, in a
            # future iso-run variant, reconciled as the iso UID). Always present
            # (empty list on a shared-mode / non-iso install) so consumers can
            # rely on the key existing in last-apply.json.
            "isolation_v2_migration": self.isolation_v2_migration,
            "counts": {
                "copied": len(self.copied),
                "preserved": len(self.preserved),
                "conflicted": len(self.conflicted),
                "skipped": len(self.skipped),
                "warnings": len(self.warnings),
                "backed_up": len(self.backed_up),
                "isolation_v2_migration": len(self.isolation_v2_migration),
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
    # File-as-argv path to a JSON object mapping {agent_id: os_user} for iso v2
    # agents (#1820 rc3, kept rc4 for os_user annotation ONLY — NOT a skip gate;
    # the rc3 up-front whole-agent skip is removed). Empty / absent => prior
    # shared-mode behavior, byte-identical. The map may be incomplete (the
    # cm-prod mdj case) and correctness does NOT depend on its completeness.
    parser.add_argument("--iso-agents-json", default="")
    # Host-level iso-v2 signal for the FILE-LEVEL owner-only skip (#1820 rc4,
    # item 4). When set (Linux + at least one rostered agent requesting
    # linux-user isolation), a per-FILE PermissionError on an agent-private file
    # is recorded as a structured file-level graceful-skip (reason
    # file-owner-only) instead of a warning. Absent/unset => shared-mode / macOS
    # / non-iso: a per-file PermissionError stays a warning, byte-identical to
    # main. This is a FILE-LEVEL gate ONLY — it NEVER whole-home-skips an agent
    # (the retracted rc4 whole-home belt --host-iso-active is removed, item 3).
    parser.add_argument(
        "--iso-host",
        action="store_true",
        default=False,
    )
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
