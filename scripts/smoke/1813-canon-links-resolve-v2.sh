#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1813-canon-links-resolve-v2.sh — Issue #1813.
#
# bridge-docs.py `ensure_agent_shared_links` hard-coded the shared-doc symlink
# target as the relative string `../shared/<name>`. That math only resolves at
# v1 depth (`<bridge_home>/agents/<a>/`). At v2 home depth
# (`<bridge_home>/data/agents/<a>/home/`) the same string resolved to a
# non-existent `data/agents/<a>/shared/`, so the four canon links
# (COMMON-INSTRUCTIONS/CHANGE-POLICY/TOOLS/ADMIN-PROTOCOL) never reached the
# homes v2 sessions actually read. `current_ok` also required a byte-equal
# relative readlink, so a correct *absolute* link was treated as wrong and
# clobbered; and `cleanup_broken_shared_doc_links` deleted any broken
# `../shared/*.md` link by name, so links the engine itself mis-created at v2
# depth were garbage-collected instead of fixed.
#
# Verdict gate: "the four canon shared-doc links resolve to real content from
# inside each agent's RESOLVED home on BOTH layouts; an already-correct
# (absolute or relative) link is preserved across re-apply; a foreign/broken
# operator link is never deleted."
#
# Asserts (driving bridge-docs.py directly through importlib, no live runtime):
#   T1 — v1 home depth: after ensure_agent_shared_links, all four canon links
#        resolve to the canonical <bridge_home>/shared/<name> content.
#   T2 — v2 home depth (data/agents/<a>/home): same — links resolve to real
#        content, NOT to a non-existent data/agents/<a>/shared/.
#   T3 — idempotence: a second apply on the v2 home makes zero changes.
#   T4 — an already-correct ABSOLUTE link is accepted (not clobbered) on apply.
#   T5 — a legacy relative `../shared/<name>` link that resolves correctly
#        through the v1 `agents/shared` intermediary is accepted with no churn.
#   T6 — cleanup leaves a FOREIGN broken link (resolving OUTSIDE shared) untouched.
#   T7 — cleanup leaves a broken operator link that resolves INTO shared on a
#        NON-managed name (e.g. OPERATOR-NOTE.md) untouched — scoping is by the
#        bridge-managed namespace, not "any broken .md into shared".
#   T8 — cleanup DOES remove a broken link whose resolved name is a managed
#        (deprecated) shared doc (e.g. ROSTER.md) — the namespace it owns.

set -uo pipefail
SMOKE_NAME="1813-canon-links-resolve-v2"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
DOCS="$REPO_ROOT/bridge-docs.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"

DRIVER="$SMOKE_TMP_ROOT/probe.py"
{
  printf '%s\n' 'import importlib.util, sys, os, json'
  printf 'spec = importlib.util.spec_from_file_location("docs", %s)\n' "\"$DOCS\""
  printf '%s\n' 'm = importlib.util.module_from_spec(spec)'
  # Register before exec so the module dataclasses resolve their own __module__
  # (importlib quirk on py3.9 with dataclass + from __future__ annotations).
  printf '%s\n' 'sys.modules["docs"] = m'
  printf '%s\n' 'spec.loader.exec_module(m)'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'root = Path(sys.argv[1]).resolve()'
  printf '%s\n' 'bh = root / "bridge-home"'
  printf '%s\n' 'shared = bh / "shared"'
  printf '%s\n' 'shared.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' 'for n in m.AGENT_SHARED_LINKS:'
  printf '%s\n' '    (shared / n).write_text("CONTENT:" + n)'
  printf '%s\n' ''
  # v1 layout uses an agents/shared -> ../shared intermediary (sync_shared_docs
  # creates it). Seed it so the legacy relative-link acceptance (T5) is faithful.
  printf '%s\n' '(bh / "agents").mkdir(parents=True, exist_ok=True)'
  printf '%s\n' 'os.symlink("../shared", bh / "agents" / "shared")'
  printf '%s\n' 'v1 = bh / "agents" / "acme"; v1.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' 'v2 = bh / "data" / "agents" / "acme" / "home"; v2.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' 'bk = bh / "state" / "bk"'
  printf '%s\n' ''
  printf '%s\n' 'def resolves_all(ad):'
  printf '%s\n' '    for n in m.AGENT_SHARED_LINKS:'
  printf '%s\n' '        p = ad / n'
  printf '%s\n' '        if not (p.is_symlink() and p.exists()):'
  printf '%s\n' '            return f"{n}: not a live symlink (readlink={os.readlink(p) if p.is_symlink() else None})"'
  printf '%s\n' '        if Path(os.path.realpath(p)).read_text() != "CONTENT:" + n:'
  printf '%s\n' '            return f"{n}: resolves to wrong content"'
  printf '%s\n' '    return None'
  printf '%s\n' ''
  printf '%s\n' '# T1 — v1 depth'
  printf '%s\n' 'm.ensure_agent_shared_links(v1, bh, False, bk)'
  printf '%s\n' 'err = resolves_all(v1)'
  printf '%s\n' 'assert err is None, f"T1 v1-depth resolution failed: {err}"'
  printf '%s\n' ''
  printf '%s\n' '# T2 — v2 depth'
  printf '%s\n' 'm.ensure_agent_shared_links(v2, bh, False, bk)'
  printf '%s\n' 'err = resolves_all(v2)'
  printf '%s\n' 'assert err is None, f"T2 v2-depth resolution failed: {err}"'
  printf '%s\n' '# the v2 link must NOT resolve into a non-existent data/agents/<a>/shared'
  printf '%s\n' 'for n in m.AGENT_SHARED_LINKS:'
  printf '%s\n' '    bad = v2.parent / "shared" / n'
  printf '%s\n' '    assert not Path(os.path.realpath(v2 / n)) == bad, f"T2 link still targets ghost {bad}"'
  printf '%s\n' ''
  printf '%s\n' '# T3 — idempotence on v2'
  printf '%s\n' 'ch = m.ensure_agent_shared_links(v2, bh, False, bk)'
  printf '%s\n' 'assert ch == [], f"T3 second v2 apply changed links: {ch}"'
  printf '%s\n' ''
  printf '%s\n' '# T4 — already-correct ABSOLUTE link preserved'
  printf '%s\n' 'absp = v2 / "TOOLS.md"; absp.unlink()'
  printf '%s\n' 'absp.symlink_to(shared / "TOOLS.md")'
  printf '%s\n' 'before = os.readlink(absp)'
  printf '%s\n' 'ch = m.ensure_agent_shared_links(v2, bh, False, bk)'
  printf '%s\n' 'after = os.readlink(absp)'
  printf '%s\n' 'assert before == after, f"T4 absolute link clobbered: {before} -> {after}"'
  printf '%s\n' 'assert str(absp) not in ch, f"T4 absolute link reported changed: {ch}"'
  printf '%s\n' ''
  printf '%s\n' '# T5 — legacy relative v1 link accepted with no churn'
  printf '%s\n' 'legacy = bh / "agents" / "legacy"; legacy.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' 'for n in m.AGENT_SHARED_LINKS:'
  printf '%s\n' '    os.symlink(f"../shared/{n}", legacy / n)'
  printf '%s\n' 'ch = m.ensure_agent_shared_links(legacy, bh, False, bk)'
  printf '%s\n' 'assert ch == [], f"T5 legacy relative v1 links re-churned: {ch}"'
  printf '%s\n' 'assert resolves_all(legacy) is None, "T5 legacy links do not resolve"'
  printf '%s\n' ''
  printf '%s\n' '# T6 — foreign broken link resolving OUTSIDE shared untouched'
  printf '%s\n' 'foreign = v2 / "OPERATOR-NOTE.md"'
  printf '%s\n' 'foreign.symlink_to("../../../../../somewhere/else/NOTE.md")'
  printf '%s\n' 'assert not foreign.exists(), "fixture: foreign link should be broken"'
  printf '%s\n' 'ch = m.cleanup_broken_shared_doc_links(v2, bh, False, bk)'
  printf '%s\n' 'assert foreign.is_symlink(), f"T6 foreign(outside-shared) broken link deleted: {ch}"'
  printf '%s\n' 'assert all("OPERATOR-NOTE" not in c for c in ch), f"T6 foreign link in cleanup set: {ch}"'
  printf '%s\n' ''
  printf '%s\n' '# T7 — broken operator link resolving INTO shared on a NON-managed name'
  printf '%s\n' '#      must be preserved (scoping is by managed namespace, not "any .md into shared")'
  printf '%s\n' 'op = v2 / "OPERATOR-DOC.md"'
  printf '%s\n' 'op.symlink_to("../../../../shared/OPERATOR-DOC.md")  # resolves into shared, but absent'
  printf '%s\n' 'assert not op.exists(), "fixture: operator-into-shared link should be broken"'
  printf '%s\n' 'ch = m.cleanup_broken_shared_doc_links(v2, bh, False, bk)'
  printf '%s\n' 'assert op.is_symlink(), f"T7 operator link (into shared, non-managed name) deleted: {ch}"'
  printf '%s\n' 'assert all("OPERATOR-DOC" not in c for c in ch), f"T7 non-managed link in cleanup set: {ch}"'
  printf '%s\n' ''
  printf '%s\n' '# T8 — broken link whose resolved name IS a managed (deprecated) shared doc'
  printf '%s\n' '#      (ROSTER.md) IS removed — the namespace cleanup owns.'
  printf '%s\n' 'dep = v2 / "ROSTER.md"'
  printf '%s\n' 'dep.symlink_to("../../../../shared/ROSTER.md")  # deprecated shared doc, absent'
  printf '%s\n' 'assert "ROSTER.md" in m.MANAGED_SHARED_DOC_NAMES, "fixture: ROSTER.md must be managed"'
  printf '%s\n' 'assert not dep.exists(), "fixture: deprecated link should be broken"'
  printf '%s\n' 'ch = m.cleanup_broken_shared_doc_links(v2, bh, False, bk)'
  printf '%s\n' 'assert not dep.is_symlink(), "T8 broken managed(deprecated) link was NOT removed"'
  printf '%s\n' 'assert any("ROSTER.md" in c for c in ch), f"T8 managed link not in cleanup set: {ch}"'
  printf '%s\n' ''
  printf '%s\n' 'print(json.dumps({"t1": "v1-resolves", "t2": "v2-resolves", "t3": "idempotent", "t4": "abs-preserved", "t5": "legacy-no-churn", "t6": "foreign-outside-safe", "t7": "operator-into-shared-safe", "t8": "managed-deprecated-cleaned"}))'
} >"$DRIVER"

OUT="$(python3 "$DRIVER" "$SMOKE_TMP_ROOT")" || smoke_fail "probe raised — see traceback above"
smoke_log "probe: $OUT"
smoke_log "all canon-link v2-resolution tests PASS (#1813)"
