#!/usr/bin/env python3
"""1966-orphan-walk-prune-helper.py — correctness teeth for Issue #1966.

The orphan-dir keep-set walk (`bridge_orphan_classifier._enumerate_symlink_
targets_under_root`) was rewritten to PRUNE heavy non-symlink content trees
(`node_modules`, `.git`, `.claude/{projects,cache}`) and to read symlink-ness
from a cached `os.scandir` DirEntry instead of a per-entry `os.path.islink`.

The invariant the prune must hold is ORPHAN-CLASSIFICATION-PRESERVING for every
BRIDGE keep — the orphan count + every bridge/registered/infra child's verdict
identical pre/post, the ONLY permitted change being the intended one-directional
`referenced-symlink-target -> orphan` flip — NOT "keep-set RESULT byte-
identical." On a realistic install the keep-set is NOT byte-identical: npm /
plugin-install drops `.bin` shims INSIDE the pruned `node_modules` trees whose
realpath lands under the home root (e.g. `<home>/.claude/plugins/cache/<plugin>/
.../node_modules/.bin/tsc -> ../typescript/bin/tsc`). The old unpruned walk
recorded them; the pruned walk drops them. The same-home `.bin` drop changes no
verdict (the registered child short-circuits to KIND_REGISTERED before the
keep-set is consulted). A non-bridge symlink nested inside a pruned tree that
points at an UNREGISTERED SIBLING direct child does flip that sibling
`referenced-symlink-target -> orphan` — intended and safe, because the flip is
strictly one-directional (kept -> orphan, never the reverse, so it never hides a
real orphan) and such non-bridge protection is spurious.

This helper:

  1. Builds a fixture home_root with a REGISTERED agent home `alpha` that holds
     (a) an npm-`.bin`-style symlink buried inside `.claude/plugins/cache/.../
     node_modules/.bin/` whose realpath lands UNDER the home root (dropped, but
     same-home so no verdict change), and (b) a non-bridge symlink inside
     `alpha`'s pruned top-level `node_modules` pointing at an UNREGISTERED
     SIBLING direct child `nested-protected-dir` (dropped -> intended flip) —
     plus shallow bridge keep-links, heavy prunable trees, a scoped-prune
     anchoring decoy, and a genuine UNREGISTERED orphan dir.
  2. Proves the keep-set genuinely DIFFERS pre/post (both the `.bin` shim and the
     nested sibling-link target are dropped) — else the teeth are vacuous.
  3. Asserts the CLASSIFICATION result (per-child verdict + orphan count, via the
     real `classify_agent_home_root` / `count_orphan_agent_dirs`): every bridge/
     registered/infra child + the genuine orphan are IDENTICAL pre/post, and the
     ONLY change is `nested-protected-dir` flipping `referenced-symlink-target ->
     orphan` (count +1, never the reverse). The pre-fix classification is
     produced by monkeypatching the keep-set enumerator back to an unpruned
     `os.walk` + `os.path.islink`.
  4. Proves the prune is real by instrumenting `os.scandir`: the buried
     `node_modules` / `.claude/projects` / `.git` / `.claude/plugins/cache`
     subtrees must NOT be scanned by the patched walk, while `.claude/skills` and
     the NON-`.claude` `userdir/plugins/cache` decoy ARE still walked.
  5. Mutation-tests the scoped-prune anchoring: if the `cache` prune were
     mis-anchored on the immediate-parent basename instead of the full
     `.claude/plugins` chain, the under-home link in the NON-`.claude`
     `userdir/plugins/cache` decoy would be dropped from the keep-set AND that
     decoy would no longer be scanned — both are asserted, so the teeth fail.
  6. Asserts idempotency (two patched runs return the identical keep-set).

No bridge runtime, no live state — pure filesystem fixture under a temp dir
passed as argv[1]. Exits non-zero with a diagnostic on any failed assertion.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any


def _die(msg: str) -> None:
    print(f"[1966-helper][error] {msg}", file=sys.stderr)
    raise SystemExit(1)


# --- reference implementation of the PRE-FIX keep-set walk ------------------
# Verbatim shape of the old _enumerate_symlink_targets_under_root (unpruned
# os.walk + per-entry os.path.islink). Monkeypatched into the classifier to
# produce the PRE-FIX classification, and used directly to prove the keep-set
# genuinely differs pre/post. Kept independent of the module under test.
def _reference_enumerate(
    tree: Path, home_root_real: str, out: set[str]
) -> None:
    if not tree.exists():
        return
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


def _reference_keepset(home_root: Path, kept_trees: list[Path]) -> set[str]:
    home_root_real = os.path.realpath(home_root)
    out: set[str] = set()
    for tree in kept_trees:
        _reference_enumerate(tree, home_root_real, out)
    return out


def _build_fixture(home_root: Path) -> None:
    """Create the fixture under `<root>/agents`-style home root.

    Direct children of home_root (what the classifier verdicts):
      shared/      infra; symlink TARGET dir for the bridge keep-links
      _template/   infra kept tree; a doc link
      alpha/       REGISTERED agent home (registry maps `alpha` -> this dir)
      orphan-dir/  genuine UNREGISTERED orphan (must classify orphan pre+post)
      nested-protected-dir/
                   UNREGISTERED dir protected SOLELY by a non-bridge symlink
                   NESTED inside registered `alpha`'s pruned node_modules tree
                   (`alpha/node_modules/pkg2/sibling-link -> ../../../
                   nested-protected-dir`). The UNPRUNED walk records its realpath
                   so it classifies referenced-symlink-target (kept); the PRUNED
                   walk skips node_modules so it falls through to ORPHAN. This is
                   the INTENDED one-directional flip (codex review #1966): such
                   non-bridge nested protection is spurious; the flip is
                   kept -> orphan only, never the reverse.

    Inside the REGISTERED `alpha` home:
      TOOLS.md   -> ../shared/TOOLS.md          (shallow bridge keep-link)
      SOUL.md    -> <abs>/shared/SOUL.md        (shallow bridge keep-link)
      sharedlink -> ../shared                    (symlinked SUBDIR, under root)
      outside    -> <tmp>/external/elsewhere     (OUTSIDE root — ignored)
      .claude/
        skills/agb -> <tmp>/runtime-skills/agb   (OUTSIDE root — not pruned)
        projects/<transcripts...>                (PRUNED; heavy)
        plugins/cache/<plugin>/node_modules/
          .bin/tsc -> ../typescript/bin/tsc      (npm .bin shim; realpath UNDER
                                                  root, INSIDE the pruned tree —
                                                  recorded by the UNPRUNED walk,
                                                  DROPPED by the pruned walk)
          typescript/bin/tsc                     (the shim's real target file)
          buried -> <tmp>/external/elsewhere     (decoy OUTSIDE root)
      .git/<objects...>                          (PRUNED)
      node_modules/<heavy>                        (PRUNED at top level too)
        buried2 -> <tmp>/external/elsewhere      (decoy OUTSIDE root)
      userdir/plugins/cache/ref-link -> ../shared/references/x.md
                                                 (NON-.claude scoped-prune decoy:
                                                  parent is `plugins` but NOT
                                                  `.claude/plugins/cache`, so it
                                                  is WALKED and its under-root
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
    # Shallow bridge keep-set symlinks (the real pattern): relative + absolute.
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

    # Heavy PRUNABLE trees.
    projects = claude / "projects" / "-Users-x-proj"
    projects.mkdir(parents=True, exist_ok=True)
    for i in range(20):
        (projects / f"transcript-{i}.jsonl").write_text("{}\n")

    # ★ The npm `.bin` shim INSIDE node_modules under the REGISTERED `alpha`
    # home, whose realpath lands UNDER the home root. The UNPRUNED keep-set
    # records it; the PRUNED keep-set drops it. This is the case the original
    # fixer + its internal codex both missed — it makes the keep-set genuinely
    # NON-identical while classification stays equivalent.
    nm = claude / "plugins" / "cache" / "claude-hud" / "node_modules"
    (nm / ".bin").mkdir(parents=True, exist_ok=True)
    (nm / "typescript" / "bin").mkdir(parents=True, exist_ok=True)
    (nm / "typescript" / "bin" / "tsc").write_text("#!/usr/bin/env node\n")
    # Relative shim target resolves to nm/typescript/bin/tsc — UNDER the root.
    os.symlink("../typescript/bin/tsc", nm / ".bin" / "tsc")
    for i in range(20):
        (nm / "typescript" / f"file-{i}.js").write_text("x\n")
    # Decoy symlink buried in node_modules pointing OUTSIDE the home root.
    os.symlink(str(external / "elsewhere"), nm / "buried")

    gitdir = alpha / ".git" / "objects" / "pack"
    gitdir.mkdir(parents=True, exist_ok=True)
    (gitdir / "pack-abc.idx").write_text("idx\n")

    # A top-level node_modules with a DECOY symlink that points OUTSIDE root.
    top_nm = alpha / "node_modules" / "pkg2"
    top_nm.mkdir(parents=True, exist_ok=True)
    for i in range(20):
        (top_nm / f"file-{i}.js").write_text("y\n")
    os.symlink(str(external / "elsewhere"), top_nm / "buried2")

    # ★ A non-bridge symlink NESTED inside `alpha`'s pruned node_modules that
    # points at an UNREGISTERED SIBLING direct child of the home root. This is
    # the classification-CHANGING path codex flagged: the unpruned walk records
    # the sibling's realpath (-> referenced-symlink-target, KEPT) while the
    # pruned walk skips node_modules (-> the sibling falls through to ORPHAN).
    # The sibling has NO other protection, so this is the one verdict that flips.
    nested_protected = home_root / "nested-protected-dir"
    nested_protected.mkdir(parents=True, exist_ok=True)
    (nested_protected / "stuff.txt").write_text("kept-by-nested-symlink\n")
    # ../../../nested-protected-dir from alpha/node_modules/pkg2/ -> home_root/...
    os.symlink("../../../nested-protected-dir", top_nm / "sibling-link")

    # NEGATIVE-SCOPE DECOY: a `plugins/cache` tree whose immediate parent is
    # `plugins` but which is NOT the real `.claude/plugins/cache` — it must still
    # be WALKED, and the UNDER-HOME symlink it holds must be RECORDED (the scoped
    # prune is anchored on the full `.claude/plugins` chain). A basename-only
    # `parent == "plugins"` check that wrongly pruned this is caught here.
    decoy_cache = alpha / "userdir" / "plugins" / "cache"
    decoy_cache.mkdir(parents=True, exist_ok=True)
    os.symlink(str(shared / "references" / "x.md"), decoy_cache / "ref-link")

    # A genuine UNREGISTERED orphan dir — must classify orphan-agent-dir both
    # pre and post the prune (it is not registered, not infra, and no kept tree
    # references it).
    orphan = home_root / "orphan-dir"
    orphan.mkdir(parents=True, exist_ok=True)
    (orphan / "stuff.txt").write_text("junk\n")


def _kept_trees(home_root: Path) -> list[Path]:
    # registered homes + infra dirs (mirrors _kept_trees_for_keepset).
    return [home_root / "alpha", home_root / "_template", home_root / "shared"]


def _verdicts(rows: list[dict[str, Any]]) -> dict[str, str]:
    return {str(r.get("name")): str(r.get("kind")) for r in rows}


def main() -> int:
    if len(sys.argv) < 2:
        _die("usage: 1966-orphan-walk-prune-helper.py <tmp_root>")
    tmp_root = Path(sys.argv[1])
    home_root = tmp_root / "agents"
    home_root.mkdir(parents=True, exist_ok=True)

    repo_root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(repo_root))
    import bridge_orphan_classifier as boc  # noqa: E402

    _build_fixture(home_root)
    kept_trees = _kept_trees(home_root)

    # `alpha` is a REGISTERED agent whose home is the alpha dir; nothing else is
    # registered, so `orphan-dir` is a genuine orphan.
    registry = [{"id": "alpha", "home": str(home_root / "alpha")}]

    # --- Pre-condition: the keep-set genuinely DIFFERS pre/post the prune. ---
    # Without this, the classification-equivalence teeth below would be vacuous:
    # we must prove the prune actually drops a real under-root keep-set member
    # (the npm `.bin` shim) before asserting classification is unaffected.
    patched_keepset = boc.referenced_symlink_target_realpaths(
        home_root, kept_trees
    )
    unpruned_keepset = _reference_keepset(home_root, kept_trees)
    shim_target = os.path.realpath(
        home_root
        / "alpha"
        / ".claude"
        / "plugins"
        / "cache"
        / "claude-hud"
        / "node_modules"
        / "typescript"
        / "bin"
        / "tsc"
    )
    nested_target = os.path.realpath(home_root / "nested-protected-dir")
    if shim_target not in unpruned_keepset:
        _die(
            "fixture bug: the unpruned reference walk did not record the npm "
            f".bin shim target {shim_target!r} — the difference teeth are vacuous"
        )
    if nested_target not in unpruned_keepset:
        _die(
            "fixture bug: the unpruned reference walk did not record the nested "
            f"sibling-link target {nested_target!r} — the intended-flip teeth are "
            "vacuous"
        )
    if shim_target in patched_keepset:
        _die(
            "the patched walk recorded the npm `.bin` shim under node_modules — "
            "the node_modules prune did not fire (cannot validate classification-"
            "equivalence on a non-identical keep-set)"
        )
    if nested_target in patched_keepset:
        _die(
            "the patched walk recorded the nested sibling-link target — the "
            "node_modules prune did not fire, so the intended kept->orphan flip "
            "cannot be validated"
        )
    if not (unpruned_keepset - patched_keepset):
        _die(
            "the keep-set is IDENTICAL pre/post — the fixture failed to exercise "
            "the under-registered-home drops, making the teeth vacuous"
        )

    # The pruned keep-set must still contain exactly the shallow bridge keep-set
    # targets (so the prune did not over-drop the legitimate keeps).
    expected_pruned = {
        os.path.realpath(home_root / "shared" / "TOOLS.md"),
        os.path.realpath(home_root / "shared" / "SOUL.md"),
        os.path.realpath(home_root / "shared"),  # the sharedlink symlinked dir
        os.path.realpath(home_root / "shared" / "references" / "x.md"),
    }
    if patched_keepset != expected_pruned:
        _die(
            "pruned keep-set does not match the hand-computed expected set.\n"
            f"  got:      {sorted(patched_keepset)}\n"
            f"  expected: {sorted(expected_pruned)}"
        )
    home_real = os.path.realpath(home_root)
    for t in patched_keepset:
        if not (t == home_real or t.startswith(home_real + os.sep)):
            _die(f"keep-set contains a target OUTSIDE the home root: {t}")

    # --- Teeth 1: the prune is ORPHAN-CLASSIFICATION-PRESERVING for every bridge
    # keep — the ONLY verdict that may change is the intended one-directional
    # `referenced-symlink-target -> orphan` flip of a dir protected solely by a
    # non-bridge symlink nested inside a pruned tree (`nested-protected-dir`).
    # The pre-fix classification is produced by monkeypatching the keep-set
    # enumerator back to the unpruned os.walk + os.path.islink.
    patched_rows = boc.classify_agent_home_root(registry, home_root)
    patched_verdicts = _verdicts(patched_rows)
    patched_count = boc.count_orphan_agent_dirs(registry, home_root)

    real_enumerate = boc._enumerate_symlink_targets_under_root
    boc._enumerate_symlink_targets_under_root = _reference_enumerate  # type: ignore[assignment]
    try:
        prefix_rows = boc.classify_agent_home_root(registry, home_root)
        prefix_verdicts = _verdicts(prefix_rows)
        prefix_count = boc.count_orphan_agent_dirs(registry, home_root)
    finally:
        boc._enumerate_symlink_targets_under_root = real_enumerate  # type: ignore[assignment]

    changed = {
        n
        for n in set(prefix_verdicts) | set(patched_verdicts)
        if prefix_verdicts.get(n) != patched_verdicts.get(n)
    }
    # Every BRIDGE keep + the genuine orphan must be identical pre/post. The ONLY
    # permitted change is the intended nested-non-bridge-symlink flip.
    if changed != {"nested-protected-dir"}:
        diff = {
            n: (prefix_verdicts.get(n), patched_verdicts.get(n)) for n in changed
        }
        _die(
            "classification changed on a child OTHER than the intended "
            "`nested-protected-dir` flip — the prune broke a bridge/registered/"
            f"infra keep.\n  (pre, post) per changed child: {diff}"
        )
    # ...and that one change must be EXACTLY kept(referenced) -> orphan, never the
    # reverse (the prune can only ever move kept -> orphan).
    if not (
        prefix_verdicts.get("nested-protected-dir")
        == boc.KIND_REFERENCED_SYMLINK_TARGET
        and patched_verdicts.get("nested-protected-dir") == boc.KIND_ORPHAN
    ):
        _die(
            "the nested-symlink flip was not the intended "
            "referenced-symlink-target -> orphan direction "
            f"(pre={prefix_verdicts.get('nested-protected-dir')!r}, "
            f"post={patched_verdicts.get('nested-protected-dir')!r})"
        )
    # The count may only INCREASE by the single intended flip — never decrease
    # (an orphan can never be hidden).
    if patched_count != prefix_count + 1:
        _die(
            "orphan COUNT did not increase by exactly the one intended flip "
            f"(pre={prefix_count}, post={patched_count}) — the prune is not "
            "one-directional / classification-preserving"
        )

    # Non-vacuity: the genuine orphan stays orphan, the bridge/registered/infra
    # children stay kept, both pre and post.
    for nm_, want in (
        ("orphan-dir", boc.KIND_ORPHAN),
        ("alpha", boc.KIND_REGISTERED),
        ("shared", boc.KIND_INFRA),
        ("_template", boc.KIND_INFRA),
    ):
        if prefix_verdicts.get(nm_) != want or patched_verdicts.get(nm_) != want:
            _die(
                f"fixture bug: `{nm_}` is not {want!r} pre+post "
                f"(pre={prefix_verdicts.get(nm_)!r}, "
                f"post={patched_verdicts.get(nm_)!r}) — teeth vacuous"
            )
    if prefix_count != 1 or patched_count != 2:
        _die(
            "fixture bug: expected orphan count 1 (pre) -> 2 (post), got "
            f"{prefix_count} -> {patched_count} — teeth vacuous"
        )

    # --- Teeth 2: the prune is real — instrument os.scandir and confirm the
    # patched walk NEVER descends the heavy prunable subtrees, while
    # `.claude/skills` + the NON-`.claude` plugins/cache decoy ARE still walked.
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
    # have both dropped the scan AND lost its under-home symlink (asserted in the
    # pruned-keep-set expected set above).
    decoy_cache = os.path.realpath(
        home_root / "alpha" / "userdir" / "plugins" / "cache"
    )
    if decoy_cache not in scanned_set:
        _die(
            "the NON-.claude userdir/plugins/cache decoy was pruned — the scoped "
            "prune must anchor on the full .claude/plugins chain, not just the "
            "immediate parent basename"
        )

    # --- Teeth 3: idempotency — a second patched run returns the identical set.
    if boc.referenced_symlink_target_realpaths(home_root, kept_trees) != patched_keepset:
        _die("keep-set is not idempotent across repeated patched runs")

    print(
        "[1966-helper] OK: every bridge/registered/infra keep + the genuine "
        f"orphan classify IDENTICALLY pre/post ({len(patched_verdicts)} children); "
        "the ONLY change is the intended one-directional "
        f"referenced-symlink-target->orphan flip of nested-protected-dir "
        f"(orphan count {prefix_count}->{patched_count}); keep-set DIFFERS by "
        f"{len(unpruned_keepset - patched_keepset)} under-registered-home target(s) "
        "(npm `.bin` + nested sibling-link); pruned "
        f"{len(pruned_dirs)} heavy subtrees; .claude/skills + non-.claude "
        "plugins/cache decoy still walked"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
