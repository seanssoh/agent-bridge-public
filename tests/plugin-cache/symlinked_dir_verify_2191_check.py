#!/usr/bin/env python3
"""Regression check for issue #2191 — plugin-cache verify must descend a
within-marketplace symlinked *directory* dep so a required-contract file
reachable only through it is enumerated (and a partial copy is flagged).

The overlay (`_overlay_entry` step 4) recurses through ``is_dir()``-True inbound
symlinks and materializes them into the cache, skipping only symlinks whose
target escapes the marketplace root. Before the fix, verify walked with
``os.walk(followlinks=False)`` and never descended those dirs, so it certified a
cache missing the contract file (`unchanged-verified`) — the #2191 hole.

Adversarial symlink-topology battery, calling ``_find_missing_required_contract``
directly:
  T1  contract under a within-root symlinked dir MISSING from cache → flagged
      (was None pre-fix).
  T2  same file PRESENT in cache → None (no false positive).
  T3  SAFETY: a symlinked dir escaping the marketplace root is NOT descended
      (no false requirement, no crash) — the #786/#1663 boundary.
  T4  CYCLE: a symlink to its own parent (``dep -> .``) terminates.
  T5  ALIAS (codex r1): two DISTINCT aliases ``dep_a`` and ``dep_b`` -> shared;
      overlay materializes BOTH, so a cache with dep_a/* but MISSING dep_b/* is
      flagged (a global realpath-dedup would drop the second alias and certify).
  T6  both aliases present in cache → None.
  T7  MUTUAL CYCLE: ``a/x -> b`` and ``b/y -> a`` within root → terminates.
  T8  ALIAS-TO-ANCESTOR: ``up -> ..`` (a symlink to source_path's own ancestor
      within root) must TERMINATE (no infinite descent). Its exact enumeration
      is overlay-symmetric and out of #2191 scope — only non-hang is asserted.

Loads bridge-dev-plugin-cache.py by path (argv[1]) since the module name has a
hyphen. Exits 0 on success, 1 with a diagnostic on any failed assertion.
"""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path


def load_module(path):
    spec = importlib.util.spec_from_file_location("bridge_dev_plugin_cache_2191", path)
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so any @dataclass annotations resolve cls.__module__.
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _base_marketplace(case_root: Path):
    """marketplace/plugins/myplugin (source_path) + marketplace/shared, each with
    a required-contract package.json. Returns (source_root, source_path, shared)."""
    mkt = case_root / "marketplace"
    src = mkt / "plugins" / "myplugin"
    shared = mkt / "shared"
    src.mkdir(parents=True)
    shared.mkdir(parents=True)
    (src / "package.json").write_text('{"name":"myplugin"}\n', encoding="utf-8")
    (shared / "package.json").write_text('{"name":"shared-dep"}\n', encoding="utf-8")
    return mkt, src, shared


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: symlinked_dir_verify_2191_check.py <bridge-dev-plugin-cache.py>\n")
        return 2
    m = load_module(sys.argv[1])
    fails = []

    def check(cond, label):
        if not cond:
            fails.append(label)

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # ---- T1 / T2: single within-root symlinked-dir dep -----------------
        c1 = root / "c1"
        src_root, src, _ = _base_marketplace(c1)
        os.symlink(os.path.join("..", "..", "shared"), str(src / "dep"))  # -> marketplace/shared
        cache_miss = c1 / "cache_miss"
        cache_miss.mkdir()
        (cache_miss / "package.json").write_text("x", encoding="utf-8")  # dep/package.json absent
        r1 = m._find_missing_required_contract(cache_miss, src, src_root)
        check(r1 is not None and "dep/package.json" in r1,
              "T1 missing through-symlink contract must be flagged, got %r" % (r1,))
        cache_ok = c1 / "cache_ok"
        (cache_ok / "dep").mkdir(parents=True)
        (cache_ok / "package.json").write_text("x", encoding="utf-8")
        (cache_ok / "dep" / "package.json").write_text("y", encoding="utf-8")
        r2 = m._find_missing_required_contract(cache_ok, src, src_root)
        check(r2 is None, "T2 complete cache must pass, got %r" % (r2,))

        # ---- T3: escaping symlinked dir is NOT descended (safety) -----------
        c3 = root / "c3"
        src_root3, src3, _ = _base_marketplace(c3)
        outside = c3 / "outside"
        outside.mkdir()
        (outside / "package.json").write_text('{"name":"evil"}\n', encoding="utf-8")
        os.symlink(str(outside), str(src3 / "ext"))  # escapes marketplace root
        cache3 = c3 / "cache"
        cache3.mkdir()
        (cache3 / "package.json").write_text("x", encoding="utf-8")  # no ext/* in cache
        r3 = m._find_missing_required_contract(cache3, src3, src_root3)
        check(r3 is None,
              "T3 escaping symlinked dir must NOT be enumerated (no false requirement), got %r" % (r3,))

        # ---- T4: self-cycle (dep -> .) terminates ---------------------------
        c4 = root / "c4"
        src_root4, src4, _ = _base_marketplace(c4)
        os.symlink(".", str(src4 / "loop"))  # -> myplugin itself
        cache4 = c4 / "cache"
        cache4.mkdir()
        (cache4 / "package.json").write_text("x", encoding="utf-8")
        r4 = m._find_missing_required_contract(cache4, src4, src_root4)
        check(r4 is None, "T4 self-cycle must terminate and pass a complete cache, got %r" % (r4,))

        # ---- T5 / T6: DISTINCT aliases to the same target (codex r1) --------
        # The r1 global realpath-dedup drops whichever alias os.walk visits
        # SECOND — so we assert BOTH aliases are independently required (missing
        # dep_a flagged AND missing dep_b flagged). A dedup bug fails exactly one
        # of these regardless of walk order; requiring both is order-independent.
        c5 = root / "c5"
        src_root5, src5, _ = _base_marketplace(c5)
        os.symlink(os.path.join("..", "..", "shared"), str(src5 / "dep_a"))
        os.symlink(os.path.join("..", "..", "shared"), str(src5 / "dep_b"))

        def _alias_cache(name, present_alias):
            # A cache with top-level package.json + only `present_alias`/package.json.
            c = c5 / name
            (c / present_alias).mkdir(parents=True)
            (c / "package.json").write_text("x", encoding="utf-8")
            (c / present_alias / "package.json").write_text("y", encoding="utf-8")
            return c

        r5a = m._find_missing_required_contract(_alias_cache("miss_b", "dep_a"), src5, src_root5)
        check(r5a is not None and "dep_b/package.json" in r5a,
              "T5a missing dep_b alias must be flagged, got %r" % (r5a,))
        r5b = m._find_missing_required_contract(_alias_cache("miss_a", "dep_b"), src5, src_root5)
        check(r5b is not None and "dep_a/package.json" in r5b,
              "T5b missing dep_a alias must be flagged, got %r" % (r5b,))
        # Both aliases present → passes.
        cache_alias_full = c5 / "cache_full"
        (cache_alias_full / "dep_a").mkdir(parents=True)
        (cache_alias_full / "dep_b").mkdir(parents=True)
        (cache_alias_full / "package.json").write_text("x", encoding="utf-8")
        (cache_alias_full / "dep_a" / "package.json").write_text("y", encoding="utf-8")
        (cache_alias_full / "dep_b" / "package.json").write_text("z", encoding="utf-8")
        r6 = m._find_missing_required_contract(cache_alias_full, src5, src_root5)
        check(r6 is None, "T6 both aliases present must pass, got %r" % (r6,))

        # ---- T7: mutual cycle a/x -> b, b/y -> a within root terminates -----
        c7 = root / "c7"
        mkt7 = c7 / "marketplace"
        src7 = mkt7 / "plugins" / "myplugin"
        a = src7 / "a"
        b = src7 / "b"
        a.mkdir(parents=True)
        b.mkdir(parents=True)
        (src7 / "package.json").write_text('{"name":"myplugin"}\n', encoding="utf-8")
        os.symlink(os.path.join("..", "b"), str(a / "x"))  # a/x -> myplugin/b
        os.symlink(os.path.join("..", "a"), str(b / "y"))  # b/y -> myplugin/a
        cache7 = c7 / "cache"
        cache7.mkdir()
        (cache7 / "package.json").write_text("x", encoding="utf-8")
        r7 = m._find_missing_required_contract(cache7, src7, mkt7)  # must return (not hang)
        check(r7 is None, "T7 mutual cycle must terminate and pass, got %r" % (r7,))

        # ---- T8: alias-to-ancestor (up -> ..) must TERMINATE (no infinite
        # descent). The specific enumeration result is overlay-symmetric and out
        # of #2191 scope; reaching this line proves the walk returned (a hang
        # would trip the caller's timeout and never get here).
        c8 = root / "c8"
        src_root8, src8, _ = _base_marketplace(c8)
        os.symlink("..", str(src8 / "up"))  # myplugin/up -> plugins (an ancestor)
        cache8 = c8 / "cache"
        cache8.mkdir()
        (cache8 / "package.json").write_text("x", encoding="utf-8")
        r8 = m._find_missing_required_contract(cache8, src8, src_root8)
        check(r8 is None or isinstance(r8, str),
              "T8 alias-to-ancestor must terminate (return), got %r" % (r8,))

    if fails:
        sys.stderr.write("FAIL:\n  " + "\n  ".join(fails) + "\n")
        return 1
    print("issue #2191 symlinked-dir verify regression checks: OK (T1-T8)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
