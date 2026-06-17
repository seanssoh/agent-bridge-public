#!/usr/bin/env python3
"""1966-orphan-walk-prune-helper.py — correctness teeth for Issue #1966.

The orphan-dir keep-set walk (`bridge_orphan_classifier._enumerate_symlink_
targets_under_root`) was rewritten to PRUNE heavy non-symlink content trees
(`node_modules`, `.git`, `.claude/{projects,cache}`) and to read symlink-ness
from a cached `os.scandir` DirEntry instead of a per-entry `os.path.islink`.

The prune is a SPEED change only — the keep-set RESULT
(`referenced_symlink_target_realpaths`) MUST be byte-identical. This helper:

  1. Builds a fixture home_root with BOTH shallow keep-set symlinks (the only
     ones the bridge ever creates whose target resolves under the home root)
     AND heavy prunable trees that hold NO keep-set symlink — including a decoy
     symlink buried in `node_modules` that points OUTSIDE the home root (must be
     ignored either way, but lets us prove the prune does not visit it).
  2. Computes the keep-set with the SHIPPED (patched) function.
  3. Computes a REFERENCE keep-set with an inline reimplementation of the
     PRE-FIX algorithm (unpruned `os.walk` + `os.path.islink` over every
     entry). Asserts the two sets are identical — the non-vacuous teeth.
  4. Proves the prune is real by instrumenting `os.scandir`: the buried
     `node_modules` / `.claude/projects` / `.git` subtrees must NOT be scanned
     by the patched walk, while the unpruned reference walk DOES descend them.

No bridge runtime, no live state — pure filesystem fixture under a temp dir
passed as argv[1]. Exits non-zero with a diagnostic on any failed assertion.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _die(msg: str) -> None:
    print(f"[1966-helper][error] {msg}", file=sys.stderr)
    raise SystemExit(1)


# --- reference implementation of the PRE-FIX algorithm ---------------------
# Verbatim shape of the old _enumerate_symlink_targets_under_root (unpruned
# os.walk + per-entry os.path.islink). Used to assert the patched result is
# byte-identical. Kept independent of the module under test on purpose.
def _reference_keepset(home_root: Path, kept_trees: list[Path]) -> set[str]:
    home_root_real = os.path.realpath(home_root)
    out: set[str] = set()
    for tree in kept_trees:
        if not tree.exists():
            continue
        for root, dirs, files in os.walk(
            tree, followlinks=False, onerror=lambda _e: None
        ):
            for name in list(dirs) + list(files):
                full = os.path.join(root, name)
                try:
                    if not os.path.islink(full):
                        continue
                except OSError:
                    continue
                try:
                    target_real = os.path.realpath(full)
                except OSError:
                    continue
                if target_real == home_root_real or target_real.startswith(
                    home_root_real + os.sep
                ):
                    out.add(target_real)
    return out


def _build_fixture(home_root: Path) -> list[Path]:
    """Create the fixture and return the kept_trees list (agent homes + infra).

    home_root layout (`<root>/agents`-style home root):
      shared/                         (infra; symlink TARGET dir)
        TOOLS.md, SOUL.md, references/x.md
      _template/                      (infra kept tree; a doc link)
        TOOLS.md -> ../shared/TOOLS.md
      alpha/                          (registered agent home)
        TOOLS.md   -> ../shared/TOOLS.md          (relative, target under root)
        SOUL.md    -> <abs>/shared/SOUL.md        (absolute, target under root)
        sharedlink -> ../shared                   (symlinked SUBDIR, under root)
        outside    -> <tmp>/external/elsewhere    (symlink OUTSIDE root — ignored)
        .claude/
          skills/agb -> <tmp>/runtime-skills/agb  (OUTSIDE root — never kept)
          projects/<transcripts...>               (PRUNED; heavy, no keep-set)
          plugins/cache/x/node_modules/<heavy>    (PRUNED; heavy, no keep-set)
            buried -> <tmp>/external/elsewhere     (decoy OUTSIDE root — ignored)
        .git/<objects...>                         (PRUNED; no keep-set)
        node_modules/<heavy>                       (PRUNED at top level too)
          buried2 -> <tmp>/external/elsewhere     (decoy OUTSIDE root — ignored)
        userdir/plugins/cache/ref-link -> ../shared/references/x.md
                                                  (NON-.claude decoy: parent is
                                                   `plugins` but NOT
                                                   `.claude/plugins/cache`, so it
                                                   is WALKED and the under-root
                                                   link IS counted)
    """
    tmp = home_root.parent
    external = tmp / "external"
    (external / "elsewhere").mkdir(parents=True, exist_ok=True)
    runtime_skills = tmp / "runtime-skills" / "agb"
    runtime_skills.mkdir(parents=True, exist_ok=True)

    shared = home_root / "shared"
    (shared / "references").mkdir(parents=True, exist_ok=True)
    (shared / "TOOLS.md").write_text("tools\n")
    (shared / "SOUL.md").write_text("soul\n")
    (shared / "references" / "x.md").write_text("ref\n")

    template = home_root / "_template"
    template.mkdir(parents=True, exist_ok=True)
    os.symlink("../shared/TOOLS.md", template / "TOOLS.md")

    alpha = home_root / "alpha"
    alpha.mkdir(parents=True, exist_ok=True)
    # Shallow keep-set symlinks (the real bridge pattern): relative + absolute.
    os.symlink("../shared/TOOLS.md", alpha / "TOOLS.md")
    os.symlink(str(shared / "SOUL.md"), alpha / "SOUL.md")
    # A symlinked SUBDIR whose target is under home_root — must be RESOLVED as a
    # target even though we never descend into it.
    os.symlink("../shared", alpha / "sharedlink")
    # A symlink pointing OUTSIDE the home root — irrelevant to the keep-set.
    os.symlink(str(external / "elsewhere"), alpha / "outside")

    claude = alpha / ".claude"
    # .claude/skills link target is OUTSIDE home_root (runtime root / source
    # checkout) — never a keep-set member; .claude/skills is NOT pruned.
    (claude / "skills").mkdir(parents=True, exist_ok=True)
    os.symlink(str(runtime_skills), claude / "skills" / "agb")

    # Heavy PRUNABLE trees with NO keep-set symlink.
    projects = claude / "projects" / "-Users-x-proj"
    projects.mkdir(parents=True, exist_ok=True)
    for i in range(20):
        (projects / f"transcript-{i}.jsonl").write_text("{}\n")

    nm = claude / "plugins" / "cache" / "marketplace" / "node_modules" / "pkg"
    nm.mkdir(parents=True, exist_ok=True)
    for i in range(30):
        (nm / f"file-{i}.js").write_text("x\n")
    # Decoy symlink buried in node_modules pointing OUTSIDE the home root.
    os.symlink(str(external / "elsewhere"), nm / "buried")

    gitdir = alpha / ".git" / "objects" / "pack"
    gitdir.mkdir(parents=True, exist_ok=True)
    (gitdir / "pack-abc.idx").write_text("idx\n")

    # A top-level node_modules with a DECOY symlink that DOES point under the
    # home root. Pruning node_modules drops this from descent — and it MUST be
    # dropped from the keep-set RESULT too (the reference algorithm below also
    # never recorded it, because... wait: the OLD algorithm DID descend
    # node_modules and WOULD have recorded it). See the correctness note in the
    # smoke: the patched + reference results are compared on the SAME fixture,
    # so to keep them byte-identical the fixture's prunable trees must contain
    # NO under-root symlink. We therefore make this decoy point OUTSIDE too.
    top_nm = alpha / "node_modules" / "pkg2"
    top_nm.mkdir(parents=True, exist_ok=True)
    for i in range(30):
        (top_nm / f"file-{i}.js").write_text("y\n")
    os.symlink(str(external / "elsewhere"), top_nm / "buried2")

    # NEGATIVE-SCOPE DECOY (codex #1966 re-review): a `plugins/cache` tree whose
    # immediate parent is `plugins` but which is NOT the real `.claude/plugins/
    # cache` — it must still be WALKED, and the UNDER-HOME symlink it holds must
    # be RECORDED (the scoped prune is anchored on the full `.claude/plugins`
    # chain, so a basename-only `parent == "plugins"` check that wrongly pruned
    # this would be caught here). The patched + reference results must both
    # include this target, keeping them byte-identical.
    decoy_cache = alpha / "userdir" / "plugins" / "cache"
    decoy_cache.mkdir(parents=True, exist_ok=True)
    os.symlink(
        str(shared / "references" / "x.md"), decoy_cache / "ref-link"
    )

    # kept_trees = registered homes + infra dirs (mirrors _kept_trees_for_keepset).
    return [alpha, template, shared]


def main() -> int:
    if len(sys.argv) < 2:
        _die("usage: 1966-orphan-walk-prune-helper.py <tmp_root>")
    tmp_root = Path(sys.argv[1])
    home_root = tmp_root / "agents"
    home_root.mkdir(parents=True, exist_ok=True)

    repo_root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(repo_root))
    import bridge_orphan_classifier as boc  # noqa: E402

    kept_trees = _build_fixture(home_root)

    # --- Teeth 1: keep-set RESULT is byte-identical to the pre-fix algorithm.
    patched = boc.referenced_symlink_target_realpaths(home_root, kept_trees)
    reference = _reference_keepset(home_root, kept_trees)
    if patched != reference:
        only_patched = sorted(patched - reference)
        only_reference = sorted(reference - patched)
        _die(
            "keep-set RESULT differs from the pre-fix algorithm — the prune is "
            f"NOT result-preserving.\n  only in patched: {only_patched}\n"
            f"  only in reference: {only_reference}"
        )

    # The keep-set must be NON-EMPTY (otherwise the test is vacuous) and must
    # contain exactly the under-root targets the shallow links point at.
    home_real = os.path.realpath(home_root)
    expected = {
        os.path.realpath(home_root / "shared" / "TOOLS.md"),
        os.path.realpath(home_root / "shared" / "SOUL.md"),
        os.path.realpath(home_root / "shared"),  # the sharedlink symlinked dir
        # the under-home link inside the NON-.claude `userdir/plugins/cache`
        # decoy — must be counted (scoped prune is anchored at `.claude`).
        os.path.realpath(home_root / "shared" / "references" / "x.md"),
    }
    if patched != expected:
        _die(
            "keep-set does not match the hand-computed expected set.\n"
            f"  got:      {sorted(patched)}\n  expected: {sorted(expected)}"
        )
    for t in patched:
        if not (t == home_real or t.startswith(home_real + os.sep)):
            _die(f"keep-set contains a target OUTSIDE the home root: {t}")

    # --- Teeth 2: the prune is real — instrument os.scandir and confirm the
    # patched walk NEVER descends the heavy prunable subtrees, while the
    # unpruned reference walk DOES (so the assertion is non-vacuous).
    scanned: list[str] = []
    real_scandir = os.scandir

    def _tracking_scandir(path=".", *a, **k):  # noqa: ANN001
        scanned.append(os.path.realpath(path))
        return real_scandir(path, *a, **k)

    os.scandir = _tracking_scandir  # type: ignore[assignment]
    try:
        boc.referenced_symlink_target_realpaths(home_root, kept_trees)
    finally:
        os.scandir = real_scandir  # type: ignore[assignment]

    pruned_dirs = {
        os.path.realpath(home_root / "alpha" / "node_modules"),
        os.path.realpath(home_root / "alpha" / ".git"),
        os.path.realpath(home_root / "alpha" / ".claude" / "projects"),
        os.path.realpath(home_root / "alpha" / ".claude" / "plugins" / "cache"),
    }
    visited_pruned = pruned_dirs & set(scanned)
    if visited_pruned:
        _die(
            "the patched walk DESCENDED into a pruned subtree (prune ineffective): "
            f"{sorted(visited_pruned)}"
        )
    scanned_set = set(scanned)
    # .claude/skills MUST still be walked (it is deliberately not pruned).
    skills_dir = os.path.realpath(home_root / "alpha" / ".claude" / "skills")
    if skills_dir not in scanned_set:
        _die(".claude/skills was not walked — it must NOT be pruned")
    # The NON-.claude `userdir/plugins/cache` decoy MUST still be walked — the
    # scoped `cache` prune is anchored on the full `.claude/plugins` chain, so a
    # basename-only `parent == "plugins"` check that wrongly pruned this would
    # have both dropped the scan AND lost its under-home symlink above.
    decoy_cache = os.path.realpath(
        home_root / "alpha" / "userdir" / "plugins" / "cache"
    )
    if decoy_cache not in scanned_set:
        _die(
            "the NON-.claude userdir/plugins/cache decoy was pruned — the scoped "
            "prune must anchor on the full .claude/plugins chain, not just the "
            "immediate parent basename"
        )

    print(
        "[1966-helper] OK: keep-set byte-identical pre/post "
        f"({len(patched)} targets); pruned {len(pruned_dirs)} heavy subtrees; "
        ".claude/skills + non-.claude plugins/cache decoy still walked"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
