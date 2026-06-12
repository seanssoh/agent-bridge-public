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
        # iso v2 agents: a map {agent_id: os_user}. Agent-private memory for these
        # agents is owned by the iso UID at mode 0600/0700 and is NOT readable by
        # the controller that runs this reconcile (#1820 rc3). The controller must
        # NOT direct-read or back up that 0600 state — it would raise Errno13 and
        # degrade to an unstructured perm-warning. For an agent in this map the
        # reconcile GRACEFUL-SKIPS the controller-side backup + v1->v2 reconcile
        # of its agent-private memory and records a STRUCTURED
        # isolation_v2_migration entry instead. The agent owns and manages its own
        # private memory; controller backup of 0600 agent-private state is the
        # wrong contract (same class as the #1827 wiki-rebuild that could not read
        # an iso home 0700). The conflict/fencing DATA logic below is unchanged —
        # it simply is not entered for these agents.
        self.iso_agents: dict[str, str] = self._load_iso_agents(args.iso_agents_json)
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
        # falling to unstructured warnings (#1820 rc3 observability).
        self.isolation_v2_migration: list[dict] = []
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

        # iso v2 graceful-skip (#1820 rc3). An iso agent's agent-private memory is
        # owned by its iso UID at mode 0600/0700; the controller running this
        # reconcile cannot read it (Errno13). Controller backup/reconcile of
        # 0600 agent-private state is the wrong contract — the agent owns and
        # manages it. Skip the ENTIRE controller-side memory pass for this agent
        # (no direct-read, no shutil.copy2 backup, none of the per-file walk) and
        # record a STRUCTURED isolation_v2_migration entry so the iso permission
        # pass is auditable in last-apply.json instead of degrading to Errno13
        # perm-warnings. This early-returns BEFORE _pre_mutation_backup and any
        # _read_bytes, so the controller never touches the 0600 files.
        os_user = self.iso_agents.get(agent)
        if os_user:
            self.isolation_v2_migration.append(
                {
                    "agent": agent,
                    "os_user": os_user,
                    "action": "skipped-iso-private",
                    "reason": "iso-agent-private",
                    "detail": (
                        "agent-private memory is owned by the iso UID "
                        f"({os_user}) at mode 0600/0700 and is not "
                        "controller-reconcilable; the agent owns and manages it"
                    ),
                }
            )
            self._skip(agent, "agent", ".", "iso_agent_private")
            return

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
    # agents (#1820 rc3). Agent-private memory for these agents is graceful-
    # skipped from the controller-side reconcile/backup (see Reconciler). Empty
    # / absent => no iso agents => prior shared-mode behavior, byte-identical.
    parser.add_argument("--iso-agents-json", default="")
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
