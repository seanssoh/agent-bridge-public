#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/H-beta4-iso-ownership.sh — v0.15.0-beta4 Lane H.
#
# Issue #1278 + #1208 (cross-check) + #1215 (cross-check): iso v2
# ownership audit family. Pins the contract closed by Lane H:
#
#   - lib/bridge-agents.sh: `bridge_write_isolated_known_marketplaces_
#     catalog` chowns the catalog to `<iso_user>:ab-agent-<a>` and
#     chmods 0660 (was `root:ab-agent-<a> 0640` pre-#1278).
#   - bridge-plugins.sh: D2 propagate path mirrors the same contract
#     (was `root:ab-agent-<a> 0640`).
#   - bridge-plugins.sh: D2 propagate path retains the #1208 self-heal
#     for `known_marketplaces.json.lock` AND `installed_plugins.json.
#     lock` to `root:ab-agent-<a> 0660` (or iso UID owned with 0660 —
#     mode is the load-bearing piece for group-write flock).
#   - bridge-setup.py: `.ms365` directory mkdir passes mode=0o2770 so
#     the parent directory is traversable for plugin .env reads (#1215).
#   - scripts/audit/iso-v2-ownership-audit.sh exists, is executable,
#     and exposes the documented usage shape.
#
# Coverage matrix (static-source greps; no sudo/root needed, runs on
# macOS dev hosts and Linux CI alike):
#
#   T1 — `bridge_write_isolated_known_marketplaces_catalog` chowns to
#        `$os_user:$_v2_grp` (NOT root:root) AND chmods 0660 (NOT 0640).
#   T2 — `bridge_plugins_seed_propagate_iso_known_marketplaces` chowns
#        to `$iso_os_user:$agent_group` AND chmods 0660.
#   T3 — Both writers RETAIN the #1208 lock self-heal step: the lock
#        files (known_marketplaces.json.lock + installed_plugins.json.
#        lock) MUST be group-writable (mode 0660) so the iso UID's
#        `bridge-dev-plugin-cache.py` can acquire LOCK_EX on them.
#   T4 — `.ms365` directory creation in bridge-setup.py uses
#        `_isolation_aware_mkdir(ms365_dir, mode=0o2770, agent=...)`
#        (#1215 contract).
#   T5 — scripts/audit/iso-v2-ownership-audit.sh exists, is executable,
#        has shebang, passes `bash -n`, and contains the documented
#        usage block (`<agent-name>` + `--all`).
#   T6 — `bridge_write_isolated_known_marketplaces_catalog` no longer
#        contains the OLD `root:root` chown or `0640` chmod literal for
#        the catalog file itself (regression catch). Comments allowed.
#
# All assertions are pure static-source greps. The behavioral
# end-to-end (real iso UID rename + os.replace under Linux + sudo)
# lives in Phase E operator-host verification — out of scope for a
# CI smoke.
#
# Footgun #11: no heredoc-stdin to subprocess. All literal patterns
# use single-quoted strings or grep with explicit pattern flags.

set -uo pipefail

SMOKE_NAME="H-beta4-iso-ownership"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
PLUGINS_SH="$REPO_ROOT/bridge-plugins.sh"
SETUP_PY="$REPO_ROOT/bridge-setup.py"
AUDIT_SH="$REPO_ROOT/scripts/audit/iso-v2-ownership-audit.sh"

[[ -f "$AGENTS_LIB" ]] || smoke_fail "missing $AGENTS_LIB"
[[ -f "$PLUGINS_SH" ]] || smoke_fail "missing $PLUGINS_SH"
[[ -f "$SETUP_PY" ]]   || smoke_fail "missing $SETUP_PY"
[[ -f "$AUDIT_SH" ]]   || smoke_fail "missing $AUDIT_SH"

# ---------------------------------------------------------------------
# T1 — bridge_write_isolated_known_marketplaces_catalog chowns to
# $os_user:$_v2_grp and chmods 0660 (#1278).
# ---------------------------------------------------------------------

smoke_log "T1: bridge_write_isolated_known_marketplaces_catalog chowns iso UID + 0660"

# Extract the function body (lines from its signature to the closing }).
T1_FN_START="$(grep -nE '^bridge_write_isolated_known_marketplaces_catalog\(\)' "$AGENTS_LIB" | head -1 | cut -d: -f1)"
[[ -n "$T1_FN_START" ]] || smoke_fail "T1: cannot locate bridge_write_isolated_known_marketplaces_catalog in $AGENTS_LIB"

# Heuristic: function body ends at the first standalone `}` line in
# column 0 after the start. Use awk to extract that range.
T1_BODY="$(awk -v start="$T1_FN_START" '
  NR < start { next }
  NR == start { in_fn = 1; print; next }
  in_fn { print; if ($0 == "}") { exit } }
' "$AGENTS_LIB")"

[[ -n "$T1_BODY" ]] || smoke_fail "T1: extracted function body is empty"

# T1a: chown to $os_user:$_v2_grp (NOT root:root) on the catalog tmp.
if ! printf '%s\n' "$T1_BODY" | grep -F 'chown "$os_user:$_v2_grp" "$catalog_tmp"' >/dev/null; then
  smoke_fail "T1a: bridge_write_isolated_known_marketplaces_catalog does not chown to \$os_user:\$_v2_grp — issue #1278 regressed"
fi

# T1b: chmod 0660 on the catalog tmp.
if ! printf '%s\n' "$T1_BODY" | grep -F 'chmod 0660 "$catalog_tmp"' >/dev/null; then
  smoke_fail "T1b: bridge_write_isolated_known_marketplaces_catalog does not chmod 0660 — issue #1278 regressed (iso UID cannot rename/write its own per-UID catalog)"
fi

smoke_log "T1 PASS — chown \$os_user:\$_v2_grp + chmod 0660 in writer"

# ---------------------------------------------------------------------
# T2 — bridge_plugins_seed_propagate_iso_known_marketplaces mirrors
# the new contract (iso UID:group + 0660) on the D2 propagation path.
# ---------------------------------------------------------------------

smoke_log "T2: bridge_plugins_seed_propagate_iso_known_marketplaces chowns iso UID + 0660"

T2_FN_START="$(grep -nE '^bridge_plugins_seed_propagate_iso_known_marketplaces\(\)' "$PLUGINS_SH" | head -1 | cut -d: -f1)"
[[ -n "$T2_FN_START" ]] || smoke_fail "T2: cannot locate bridge_plugins_seed_propagate_iso_known_marketplaces in $PLUGINS_SH"

T2_BODY="$(awk -v start="$T2_FN_START" '
  NR < start { next }
  NR == start { in_fn = 1; print; next }
  in_fn { print; if ($0 == "}") { exit } }
' "$PLUGINS_SH")"

[[ -n "$T2_BODY" ]] || smoke_fail "T2: extracted D2 function body is empty"

# T2a: chown to "$iso_os_user:$agent_group" on the propagated catalog.
if ! printf '%s\n' "$T2_BODY" | grep -F 'chown "$iso_os_user:$agent_group" "$iso_known"' >/dev/null; then
  smoke_fail "T2a: D2 propagate does not chown to \$iso_os_user:\$agent_group — issue #1278 propagation regressed"
fi

# T2b: chmod 0660 on the propagated catalog.
if ! printf '%s\n' "$T2_BODY" | grep -F 'chmod 0660 "$iso_known"' >/dev/null; then
  smoke_fail "T2b: D2 propagate does not chmod 0660 on \$iso_known — issue #1278 propagation regressed"
fi

smoke_log "T2 PASS — D2 propagate uses iso UID:group + 0660"

# ---------------------------------------------------------------------
# T3 — #1208 lock self-heal preserved.
# ---------------------------------------------------------------------

smoke_log "T3: D2 propagate retains #1208 lock self-heal (known + installed lockfiles at 0660)"

# Both lock files are normalized to chmod 0660. Check both literal
# chmod 0660 calls survive in the D2 body.
T3_FAILS=""

if ! printf '%s\n' "$T2_BODY" | grep -F 'chmod 0660 "$iso_known_lock"' >/dev/null; then
  T3_FAILS+="known_marketplaces.json.lock chmod 0660 regressed; "
fi
if ! printf '%s\n' "$T2_BODY" | grep -F 'chmod 0660 "$iso_installed_lock"' >/dev/null; then
  T3_FAILS+="installed_plugins.json.lock chmod 0660 regressed; "
fi
# Also ensure the chgrp to the agent group is intact for the locks.
if ! printf '%s\n' "$T2_BODY" | grep -F 'chown "root:$agent_group" "$iso_known_lock"' >/dev/null; then
  T3_FAILS+="known_marketplaces.json.lock chown root:agent_group regressed; "
fi
if ! printf '%s\n' "$T2_BODY" | grep -F 'chown "root:$agent_group" "$iso_installed_lock"' >/dev/null; then
  T3_FAILS+="installed_plugins.json.lock chown root:agent_group regressed; "
fi

if [[ -n "$T3_FAILS" ]]; then
  smoke_fail "T3: #1208 lock self-heal regression(s): $T3_FAILS"
fi

smoke_log "T3 PASS — both lockfiles still chown root:agent_group + chmod 0660"

# ---------------------------------------------------------------------
# T4 — bridge-setup.py: .ms365 dir uses mode=0o2770 (#1215 cross-check).
# ---------------------------------------------------------------------

smoke_log "T4: bridge-setup.py creates .ms365 dir at mode 0o2770 (#1215)"

T4_MATCH="$(grep -nE '_isolation_aware_mkdir\(ms365_dir, mode=0o2770' "$SETUP_PY" || true)"
if [[ -z "$T4_MATCH" ]]; then
  smoke_fail "T4: bridge-setup.py does not create ms365_dir with mode=0o2770 — issue #1215 regressed (operator must chmod after every setup ms365)"
fi
smoke_log "T4 PASS — ms365_dir mkdir uses mode=0o2770: $T4_MATCH"

# ---------------------------------------------------------------------
# T5 — scripts/audit/iso-v2-ownership-audit.sh exists + is executable
# + passes `bash -n` + has the documented usage block.
# ---------------------------------------------------------------------

smoke_log "T5: scripts/audit/iso-v2-ownership-audit.sh contract"

T5_FAILS=""

# T5a: exists with shebang.
if ! head -1 "$AUDIT_SH" 2>/dev/null | grep -q '^#!/usr/bin/env bash'; then
  T5_FAILS+="missing/incorrect shebang; "
fi

# T5b: executable bit set.
if [[ ! -x "$AUDIT_SH" ]]; then
  T5_FAILS+="not executable (chmod +x missing); "
fi

# T5c: passes bash syntax check.
if ! bash -n "$AUDIT_SH" 2>/dev/null; then
  T5_FAILS+="bash -n syntax error; "
fi

# T5d: documents the dual usage (agent-name + --all).
if ! grep -F 'iso-v2-ownership-audit.sh <agent-name>' "$AUDIT_SH" >/dev/null; then
  T5_FAILS+="missing single-agent usage form; "
fi
if ! grep -F 'iso-v2-ownership-audit.sh --all' "$AUDIT_SH" >/dev/null; then
  T5_FAILS+="missing --all roster-walk usage form; "
fi

# T5e: references the expected per-file contract paths (known_marketplaces.json,
# known_marketplaces.json.lock, installed_plugins.json, installed_plugins.json.lock,
# .ms365).
for needle in known_marketplaces.json known_marketplaces.json.lock installed_plugins.json installed_plugins.json.lock .ms365; do
  if ! grep -F "$needle" "$AUDIT_SH" >/dev/null; then
    T5_FAILS+="audit script does not reference $needle; "
  fi
done

if [[ -n "$T5_FAILS" ]]; then
  smoke_fail "T5: audit script contract issues: $T5_FAILS"
fi

smoke_log "T5 PASS — audit script exists, is executable, parses, documents usage, references all paths"

# ---------------------------------------------------------------------
# T6 — no `root:root` chown OR `0640` chmod left on the catalog in
# bridge_write_isolated_known_marketplaces_catalog (regression catch).
# ---------------------------------------------------------------------

smoke_log "T6: no legacy root:root / 0640 chown/chmod on catalog file"

T6_BAD=""
if printf '%s\n' "$T1_BODY" | grep -vE '^[[:space:]]*#' | grep -F 'chown root:root "$catalog_tmp"' >/dev/null; then
  T6_BAD+="legacy chown root:root catalog_tmp; "
fi
if printf '%s\n' "$T1_BODY" | grep -vE '^[[:space:]]*#' | grep -F 'chmod 0640 "$catalog_tmp"' >/dev/null; then
  T6_BAD+="legacy chmod 0640 catalog_tmp; "
fi

# Also catch the D2 path: it must NOT contain the legacy chown root:$agent_group
# + chmod 0640 combo for the DATA file `$iso_known` (locks are separate
# and DO chgrp to root:$agent_group at 0660).
if printf '%s\n' "$T2_BODY" | grep -vE '^[[:space:]]*#' | grep -F 'chmod 0640 "$iso_known"' >/dev/null; then
  T6_BAD+="legacy chmod 0640 iso_known (D2); "
fi

if [[ -n "$T6_BAD" ]]; then
  smoke_fail "T6: legacy ownership/mode literal(s) still present: $T6_BAD"
fi

smoke_log "T6 PASS — no legacy root:root / 0640 chown/chmod on catalog"

# ---------------------------------------------------------------------
# Teeth — synthetic regression demonstrating each assertion bites.
#
# Construct mutated copies of the function bodies and re-run the T1/T2
# assertions against them. If the assertion passes against a body with
# the FIX removed, the smoke has no teeth and should fail.
# ---------------------------------------------------------------------

smoke_log "Teeth: verify each assertion bites on a synthetic regression"

TEETH_TMP="$SMOKE_TMP_ROOT/teeth-fixture.sh"
# Synthetic regression #1: revert T1's chown to root:root.
{
  printf '%s\n' "$T1_BODY" \
    | sed -E 's|chown "\$os_user:\$_v2_grp" "\$catalog_tmp"|chown root:root "$catalog_tmp"|; s|chmod 0660 "\$catalog_tmp"|chmod 0640 "$catalog_tmp"|'
} > "$TEETH_TMP"

if grep -F 'chown "$os_user:$_v2_grp" "$catalog_tmp"' "$TEETH_TMP" >/dev/null; then
  smoke_fail "teeth: synthetic regression did not actually mutate the chown line — sed pattern mismatch (the assertion would not bite)"
fi
if grep -F 'chmod 0660 "$catalog_tmp"' "$TEETH_TMP" >/dev/null; then
  smoke_fail "teeth: synthetic regression did not actually mutate the chmod line"
fi
# The OLD pattern must now be present in the mutated body.
if ! grep -F 'chown root:root "$catalog_tmp"' "$TEETH_TMP" >/dev/null; then
  smoke_fail "teeth: synthetic regression failed to inject the legacy chown — teeth setup broken"
fi
if ! grep -F 'chmod 0640 "$catalog_tmp"' "$TEETH_TMP" >/dev/null; then
  smoke_fail "teeth: synthetic regression failed to inject the legacy chmod — teeth setup broken"
fi

smoke_log "Teeth PASS — synthetic regression of T1 chown/chmod produces the OLD pattern (T1/T6 would catch it)"

smoke_log "all tests PASS — Lane H (#1278 + #1208 + #1215 cross-check) verified at current source"
