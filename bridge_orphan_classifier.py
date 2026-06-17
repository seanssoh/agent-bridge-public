#!/usr/bin/env python3
"""bridge_orphan_classifier.py — single action-safe classifier for the
`agents/` home-root (Issue #1803).

This module is the SSOT for "what is a child of the agent-home root, and is
it safe to touch?". Three consumers import it so the classification logic is
written ONCE and can never drift between a read-only report and an actionable
GC move (codex constraint #3):

  * `bridge-doctor.py`  — the read-only `orphan-agent-dir` detector wraps
    `classify_agent_home_root` and renders the same verdicts it always did
    (behavior-preserving; `scripts/smoke/orphan-agent-dir.sh` T1-T10 green).
  * `bridge-orphan-gc.py` — the daemon GC action layer; ONLY a
    `kind == "orphan-agent-dir"` child is ever a quarantine candidate.
  * `bridge-status.py`  — the `orphan_agent_dirs` counter counts the same
    `orphan-agent-dir` verdicts.

Classification kinds (per child of the agent-home root):

  * ``registered``                   — IS a registered agent's home/workdir
                                       (basename id match OR inode-aware
                                       samefile match). KEEP.
  * ``infra``                        — bridge-managed infrastructure
                                       (`_template`, `shared`, a dotfile, or a
                                       non-directory root file). KEEP.
  * ``referenced-symlink-target``    — the child's realpath is the resolved
                                       target of a symlink owned by a KEPT
                                       tree (registered home or infra dir).
                                       This is the GENERIC keep that protects
                                       `agents/shared` (and any future, non-
                                       `shared`-named target) WITHOUT name
                                       hardcoding — closing the real blast
                                       radius (#1803: a manual sweep removed
                                       `agents/shared` and broke every agent's
                                       doc symlinks). KEEP.
  * ``orphan-agent-dir``             — a real directory under the home root,
                                       not registered, not infra, not a
                                       referenced target. The ONLY actionable
                                       kind.
  * ``orphan-agent-dir-unverifiable``— identity could not be PROVEN against
                                       the registry (a samefile/stat probe
                                       raised). Fail-safe: KEEP + notify
                                       (the #1787/#1795/#1791 rule).
  * ``detector-error``               — a per-child classification raised an
                                       unexpected error. KEEP + notify.

Every kind EXCEPT ``orphan-agent-dir`` is keep+notify. Indeterminate ⇒ keep.

The three-state samefile identity logic (#1787) is preserved verbatim from
the original `bridge-doctor.py` so the doctor's existing verdicts are
unchanged after the refactor.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any


# --- constants (mirrored from bridge-doctor.py; keep in lockstep) ----------

# Directory basenames under the agent-home root that are bridge-managed
# infrastructure rather than per-agent homes. NOTE: this name list is now ONLY
# a fast-path for the `infra` kind — the REAL protection for `shared` (and any
# other symlink target) is the generic resolved-symlink-target keep-set
# (Part B), which does not depend on these names.
ORPHAN_SKIP_NAMES = frozenset({"_template", "shared"})

# Basename prefixes / suffix that mark a throwaway test home so an operator can
# triage in one pass. Mirrors lib/bridge-core.sh:BRIDGE_TEST_ARTIFACT_PREFIXES.
ORPHAN_TEST_ARTIFACT_PREFIXES = (
    "smoke-",
    "test-",
    "bootstrap-",
    "created-agent-",
    "pref-",
)
ORPHAN_TEST_ARTIFACT_REPRO_REGEX = re.compile(r"-repro-\d+$")

# Issue #1787 sentinel: a samefile that could not be RESOLVED (stat failure)
# must never silently degrade to "not a registered agent". Distinct from
# `None` (PROVEN no-match).
_SAMEFILE_INDETERMINATE = "\0indeterminate\0"

# Classification kinds.
KIND_REGISTERED = "registered"
KIND_INFRA = "infra"
KIND_REFERENCED_SYMLINK_TARGET = "referenced-symlink-target"
KIND_ORPHAN = "orphan-agent-dir"
KIND_ORPHAN_UNVERIFIABLE = "orphan-agent-dir-unverifiable"
KIND_DETECTOR_ERROR = "detector-error"

# The ONLY kind a caller may act on. Anything else is keep+notify.
ACTIONABLE_KIND = KIND_ORPHAN


def is_test_artifact_name(name: str) -> bool:
    for prefix in ORPHAN_TEST_ARTIFACT_PREFIXES:
        if name.startswith(prefix):
            return True
    return bool(ORPHAN_TEST_ARTIFACT_REPRO_REGEX.search(name))


def registered_agent_dirs(
    registry: list[dict[str, Any]],
) -> list[tuple[str, str]]:
    """Yield (agent_id, dir) for every registered agent's home + workdir.

    The classifier checks a candidate dir case-insensitively (macOS APFS) via
    `os.path.samefile`, not just by a case-sensitive basename compare. Skips
    empty paths.
    """
    out: list[tuple[str, str]] = []
    for row in registry:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or row.get("agent") or "").strip()
        if not agent_id:
            continue
        for key in ("home", "workdir"):
            base = str(row.get(key) or "").strip()
            if base:
                out.append((agent_id, base))
    return out


def _path_lexists(path: Path) -> bool:
    """True if `path` exists (incl. a broken symlink), False ONLY when it is
    provably absent. A permission/other OSError errs toward True so the caller
    fails SAFE (indeterminate). Uses `os.lstat`, not a pathlib metadata probe,
    so it does not trip the raw-pathlib lint.
    """
    try:
        os.lstat(path)
        return True
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError:
        return True


def samefiles_registered_agent(
    candidate: Path,
    registered_dirs: list[tuple[str, str]],
) -> str | None:
    """Return the registered agent id whose home/workdir IS `candidate`.

    Filesystem-aware identity (Issue #1787). Three-state return — fail SAFE on
    indeterminate:
      * the matching agent id  — `candidate` IS a registered agent's dir;
      * `_SAMEFILE_INDETERMINATE` — a `samefile()` raised and NO confirmed
        match was found, so we could not PROVE the candidate is unregistered;
      * `None` — PROVEN no-match.

    `_SAMEFILE_INDETERMINATE` fires only when the probe could be MASKING a
    real match: (a) the CANDIDATE itself is unstatable, or (b) a registered
    dir EXISTS yet samefile still raised. A proven match always wins over
    indeterminate.
    """
    indeterminate = False
    cand_exists = _path_lexists(candidate)
    if not cand_exists:
        indeterminate = True
    try:
        cand_real = os.path.realpath(candidate)
    except OSError:
        cand_real = None
    for agent_id, base in registered_dirs:
        reg_path = Path(base).expanduser()
        if cand_real is not None:
            try:
                reg_real = os.path.realpath(reg_path)
            except OSError:
                reg_real = None
            if reg_real is not None and cand_real == reg_real:
                return agent_id
        try:
            if os.path.samefile(candidate, reg_path):
                return agent_id
        except OSError:
            # samefile raised. Clean no-match for this pair ONLY when the
            # registered dir provably does not exist; otherwise the raised
            # probe could be masking a case-variant collision → fail safe.
            if cand_exists and _path_lexists(reg_path):
                indeterminate = True
            continue
    if indeterminate:
        return _SAMEFILE_INDETERMINATE
    return None


# --- Part B: generic resolved-symlink-target keep-set ----------------------

# Real (non-symlink) subdirectory basenames the keep-set walk PRUNES — heavy
# content trees inside an agent home that can never themselves contain a
# bridge-managed keep-set symlink (Issue #1966). Every keep-set symlink the
# bridge creates whose target resolves UNDER the home root lives at a SHALLOW
# agent-home location (`agents/shared` -> `../shared`, `agents/<a>/<DOC>` ->
# `../shared/<DOC>` via bridge-docs.py's AGENT_SHARED_LINKS) — never nested
# inside these trees. The `.claude/skills/<skill>` links target the runtime
# `.claude/` root or the source checkout (OUTSIDE the home root), so they were
# never in the keep-set and `.claude/skills` is deliberately NOT pruned. The
# scoped trees are pruned only at their FULL real Claude path (`.claude/projects`
# transcripts, `.claude/plugins/cache` plugin cache) — anchored on the whole
# parent-chain tail, NOT just the immediate parent basename, so an unrelated
# user dir like `<agent>/x/plugins/cache` (whose parent is also `plugins` but
# which is NOT `.claude/plugins/cache`) is still walked and its symlinks still
# counted. Pruning changes only walk SPEED, not the keep-set RESULT (the 867k
# islink on a long-lived host was dominated by plugin-cache node_modules +
# transcripts).
_PRUNE_NAMES_ANYWHERE = frozenset({"node_modules", ".git"})
# basename -> the required parent-directory chain (immediate parent first,
# walking up) for the scoped prune. The dir is pruned only when its ancestor
# basenames match this chain exactly, anchoring each tree at its real `.claude`
# location.
_PRUNE_SCOPED_PARENT_CHAINS = {
    "projects": (".claude",),            # .claude/projects (Claude transcripts)
    "cache": ("plugins", ".claude"),     # .claude/plugins/cache (plugin cache)
}


def _safe_realpath(path: Path) -> str | None:
    try:
        return os.path.realpath(path)
    except OSError:
        return None


def _record_symlink_target(full: str, home_root_real: str, out: set[str]) -> None:
    target_real = _safe_realpath(Path(full))
    if target_real is None:
        return
    # Containment: only record targets that live UNDER the home root (a symlink
    # pointing outside `agents/` is irrelevant to the keep-set — we only ever
    # consider quarantining children of the home root).
    if target_real == home_root_real or target_real.startswith(
        home_root_real + os.sep
    ):
        out.add(target_real)


def _enumerate_symlink_targets_under_root(
    tree: Path,
    home_root_real: str,
    out: set[str],
) -> None:
    """Walk `tree`, resolve every symlink it contains, and record each
    resolved target whose realpath is under `home_root_real` into `out`.

    Hand-rolled `os.scandir` recursion (Issue #1966): reads each entry's
    symlink-ness from the cached `DirEntry.is_symlink()` (the directory read
    already stat'd the entry — no redundant per-entry `os.path.islink` lstat),
    and PRUNES the heavy non-symlink content trees (`node_modules`, `.git`,
    `.claude/{projects,cache}`) that can never hold a bridge keep-set symlink.
    A symlinked subdirectory is still RESOLVED as a target (matching the prior
    `os.walk` behavior where symlinked dirs appeared in `dirs`) — it is just not
    descended into; pruning only drops real (non-symlink) content dirs from
    descent, so the keep-set RESULT is unchanged — only the walk cost shrinks.

    Best-effort: a symlink we cannot resolve safely contributes nothing (so
    the candidate it might have protected stays an orphan ONLY if no OTHER
    kept tree references it — and an unresolvable link is itself never acted
    on because it is not a child of the home root we move). Every fs probe
    swallows its own OSError so a single unreadable entry never aborts the walk.
    """
    if not tree.exists():
        return
    _scan_dir_for_symlink_targets(str(tree), home_root_real, out)


def _scan_dir_for_symlink_targets(
    root: str,
    home_root_real: str,
    out: set[str],
) -> None:
    try:
        scanner = os.scandir(root)
    except OSError:
        return
    with scanner:
        for entry in scanner:
            try:
                is_link = entry.is_symlink()
            except OSError:
                continue
            if is_link:
                # Resolve the symlink (a file OR a symlinked subdir) as a
                # target; do NOT descend into it (followlinks=False semantics).
                _record_symlink_target(entry.path, home_root_real, out)
                continue
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue
            if not is_dir:
                continue
            name = entry.name
            if name in _PRUNE_NAMES_ANYWHERE:
                continue
            if _scoped_prune_matches(name, root):
                continue
            _scan_dir_for_symlink_targets(entry.path, home_root_real, out)


def _scoped_prune_matches(name: str, parent_dir: str) -> bool:
    """True if a dir named `name` whose parent is `parent_dir` is one of the
    scoped prune trees, matched on the FULL parent chain (not just the immediate
    parent basename). Anchors `cache` at `.claude/plugins/cache` and `projects`
    at `.claude/projects` so an unrelated `*/plugins/cache` is NOT pruned.
    """
    chain = _PRUNE_SCOPED_PARENT_CHAINS.get(name)
    if chain is None:
        return False
    cur = parent_dir
    for expected in chain:
        if os.path.basename(cur) != expected:
            return False
        cur = os.path.dirname(cur)
    return True


def referenced_symlink_target_realpaths(
    home_root: Path,
    kept_trees: list[Path],
) -> set[str]:
    """Compute the GENERIC keep-set of resolved symlink targets (Part B).

    Walk every KEPT tree (registered agent homes + infra dirs under the home
    root), enumerate their symlinks, resolve each (realpath), and collect
    every target that lives under the home root. A candidate child whose
    realpath is in this set is `referenced-symlink-target` → KEEP.

    This protects `agents/shared` because it is a referenced target, AND any
    future / non-`shared`-named target, WITHOUT name hardcoding. Relative
    symlinks (`../shared/TOOLS.md`) and one-level-up targets resolve correctly
    via realpath.
    """
    home_root_real = _safe_realpath(home_root)
    out: set[str] = set()
    if home_root_real is None:
        return out
    for tree in kept_trees:
        try:
            _enumerate_symlink_targets_under_root(tree, home_root_real, out)
        except Exception:  # noqa: BLE001 — keep-set is best-effort, never crash
            continue
    return out


# --- classification --------------------------------------------------------


def _list_home_root_children(home_root: Path) -> list[Path] | None:
    try:
        return sorted(home_root.iterdir(), key=lambda p: p.name)
    except OSError:
        return None


def _kept_trees_for_keepset(
    home_root: Path,
    children: list[Path],
    registered_dirs: list[tuple[str, str]],
    known: set[str],
) -> list[Path]:
    """The trees whose symlinks anchor the keep-set: every registered home/
    workdir that exists, plus the infra dirs (`_template`, `shared`, any
    name-skipped dir) directly under the home root. Registered dirs may live
    outside the home root (a `--prefer new` worktree workdir) — we still walk
    them for symlink targets that point BACK into the home root.
    """
    trees: list[Path] = []
    seen: set[str] = set()

    def _add(p: Path) -> None:
        rp = _safe_realpath(p)
        key = rp if rp is not None else str(p)
        if key in seen:
            return
        seen.add(key)
        trees.append(p)

    for _agent_id, base in registered_dirs:
        bp = Path(base).expanduser()
        # Use os.path.exists (not Path.exists) and swallow any OSError so a
        # registered home under an unreadable parent never crashes the
        # keep-set computation — it simply contributes no symlink targets.
        try:
            if os.path.exists(bp):
                _add(bp)
        except OSError:
            continue
    for child in children:
        name = child.name
        if name in ORPHAN_SKIP_NAMES or name in known:
            if child.is_dir():
                _add(child)
    return trees


def classify_agent_home_root(
    registry: list[dict[str, Any]],
    home_root: Path,
) -> list[dict[str, Any]]:
    """Classify every direct child of `home_root`. SSOT for #1803.

    Returns a list of dicts, one per child, each with:
      * ``name``     — basename
      * ``path``     — str(child)
      * ``kind``     — one of the KIND_* constants
      * ``agent``    — the matching registered id (for `registered`), else ""
      * ``reason``   — human string for keep+notify kinds
      * ``is_test_artifact`` — bool (for `orphan-agent-dir` triage)

    Never raises for a single child — a per-child failure becomes a
    `detector-error` entry (keep+notify).
    """
    results: list[dict[str, Any]] = []
    if not home_root.is_dir():
        return results

    known: set[str] = set()
    for row in registry:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or row.get("agent") or "").strip()
        if agent_id:
            known.add(agent_id)
    registered_dirs = registered_agent_dirs(registry)

    children = _list_home_root_children(home_root)
    if children is None:
        return results

    # Part B keep-set: resolved symlink targets referenced by any kept tree.
    kept_trees = _kept_trees_for_keepset(
        home_root, children, registered_dirs, known
    )
    keepset = referenced_symlink_target_realpaths(home_root, kept_trees)

    for child in children:
        name = child.name
        try:
            results.append(
                _classify_child(
                    child, name, known, registered_dirs, keepset
                )
            )
        except Exception as exc:  # noqa: BLE001 — classifier boundary, keep safe
            results.append(
                {
                    "name": name,
                    "path": str(child),
                    "kind": KIND_DETECTOR_ERROR,
                    "agent": "",
                    "reason": f"classification raised: {exc}",
                    "is_test_artifact": False,
                }
            )
    return results


def _classify_child(
    child: Path,
    name: str,
    known: set[str],
    registered_dirs: list[tuple[str, str]],
    keepset: set[str],
) -> dict[str, Any]:
    base = {
        "name": name,
        "path": str(child),
        "agent": "",
        "reason": "",
        "is_test_artifact": is_test_artifact_name(name),
    }

    # infra: name-skipped, dotfiles, non-directory root files.
    if name in ORPHAN_SKIP_NAMES:
        return {**base, "kind": KIND_INFRA, "reason": "bridge infra (name-skipped)"}
    if name.startswith("."):
        return {**base, "kind": KIND_INFRA, "reason": "dotfile/dotdir"}
    if not child.is_dir():
        return {**base, "kind": KIND_INFRA, "reason": "non-directory root file"}

    # registered: basename id match (fast path) or inode-aware samefile.
    if name in known:
        return {**base, "kind": KIND_REGISTERED, "agent": name}
    identity = samefiles_registered_agent(child, registered_dirs)
    if identity is not None:
        if identity == _SAMEFILE_INDETERMINATE:
            return {
                **base,
                "kind": KIND_ORPHAN_UNVERIFIABLE,
                "reason": (
                    "could not verify against the registry "
                    "(os.path.samefile stat failure); kept (fail-safe)"
                ),
            }
        return {**base, "kind": KIND_REGISTERED, "agent": identity}

    # referenced-symlink-target (Part B): the candidate IS, or CONTAINS, a
    # target referenced by a kept tree's symlink. A kept symlink usually points
    # at a FILE *inside* a shared dir (`agent/TOOLS.md -> ../shared/TOOLS.md`),
    # so removing the candidate DIRECTORY `shared` would break the link even
    # though the recorded target is `shared/TOOLS.md`, not `shared` itself.
    # Keep the candidate when its realpath equals a target OR is a parent of
    # one (containment) — that protects `agents/shared` and any non-`shared`-
    # named target generically, without name hardcoding.
    child_real = _safe_realpath(child)
    if child_real is None:
        # Could not resolve the candidate's realpath — fail safe.
        return {
            **base,
            "kind": KIND_ORPHAN_UNVERIFIABLE,
            "reason": "could not resolve realpath; kept (fail-safe)",
        }
    child_prefix = child_real + os.sep
    for target_real in keepset:
        if target_real == child_real or target_real.startswith(child_prefix):
            return {
                **base,
                "kind": KIND_REFERENCED_SYMLINK_TARGET,
                "reason": "contains the resolved target of a symlink in a kept tree",
            }

    # A child that is itself a symlink whose target is NOT a directory is
    # bridge infra (stale convenience link) — never an agent home. A dir-shaped
    # symlink (e.g. a `--prefer new` worktree home) is a real candidate and is
    # moved as a LINK only by the GC layer.
    try:
        if child.is_symlink():
            resolved = child.resolve(strict=False)
            if not resolved.is_dir():
                return {
                    **base,
                    "kind": KIND_INFRA,
                    "reason": "symlink to a non-directory (stale link)",
                }
    except OSError:
        return {
            **base,
            "kind": KIND_ORPHAN_UNVERIFIABLE,
            "reason": "symlink resolution raised; kept (fail-safe)",
        }

    # Everything else: a real, unregistered, unreferenced directory under the
    # home root → the ONLY actionable kind.
    return {**base, "kind": KIND_ORPHAN}


def count_orphan_agent_dirs(
    registry: list[dict[str, Any]],
    home_root: Path,
) -> int:
    """Count children classified `orphan-agent-dir`. Used by the status
    counter so the dashboard number is the SAME classifier the GC acts on.
    Never raises (returns 0 on any structural failure)."""
    try:
        return sum(
            1
            for row in classify_agent_home_root(registry, home_root)
            if row.get("kind") == KIND_ORPHAN
        )
    except Exception:  # noqa: BLE001 — observability counter, never crash status
        return 0
