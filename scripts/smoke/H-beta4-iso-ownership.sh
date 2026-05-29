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

# ---------------------------------------------------------------------
# T_canonical — codex r2 BLOCKING: audit must use canonical identity
# helpers (bridge_isolation_v2_agent_group_name, bridge_agent_os_user,
# bridge_agent_default_os_user) instead of inline lowercase + underscore
# →hyphen + char-strip + prefix-compose. Also: --all driver must use
# bridge_load_roster + BRIDGE_AGENT_IDS instead of the dead
# bridge_register_agent / AGENT_NAMES+= grep. Plus the named-file read
# replacement for the process-substitution self-contract violation.
#
# All checks are static-source greps because the audit script exits 0
# early on non-Linux (so we can't directly run it on the macOS dev box
# this smoke runs from). A Linux-host behavioral test of the canonical
# path lives in Phase E operator-host verification.
# ---------------------------------------------------------------------

smoke_log "T_canonical: audit uses canonical helpers + sourced roster + named-file read (codex r1 BLOCKING)"

T_CANONICAL_FAILS=""

# T_canonical_a: audit sources bridge-lib.sh so the canonical helpers
# resolve at runtime (instead of being re-implemented inline).
if ! grep -F 'source "$REPO_ROOT/bridge-lib.sh"' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit does not source bridge-lib.sh; "
fi

# T_canonical_b: v2_agent_group calls bridge_isolation_v2_agent_group_name
# (lib/bridge-isolation-v2.sh:406). This is the canonical group name
# helper that preserves underscores in agent names and hash-truncates
# past Linux's 32-char groupadd cap. The prior r1 lowercased +
# tr '_' '-' which produced `ab-agent-h-smoke` for the operator-host
# agent `h_smoke` instead of the canonical `ab-agent-h_smoke` — false
# violations on every audit row.
if ! grep -F 'bridge_isolation_v2_agent_group_name' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit does not call bridge_isolation_v2_agent_group_name; "
fi

# T_canonical_c: iso_user_for_agent calls bridge_agent_os_user
# (lib/bridge-agents.sh:969) first — picks up explicit `--os-user manual`
# overrides from the roster (bridge-agent.sh:3000-3002/3259) — and falls
# back to bridge_agent_default_os_user (lib/bridge-agents.sh:990) which
# is the canonical default derivation. The prior r1 hardcoded
# `agent-bridge-${slug}` and disagreed with the operator-override path.
if ! grep -F 'bridge_agent_os_user' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit does not call bridge_agent_os_user; "
fi
if ! grep -F 'bridge_agent_default_os_user' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit does not call bridge_agent_default_os_user; "
fi

# T_canonical_d: --all driver uses bridge_load_roster + BRIDGE_AGENT_IDS
# (lib/bridge-state.sh:1024 + lib/bridge-core.sh:844/928). The prior r1
# grepped for `bridge_register_agent` / `AGENT_NAMES+=` patterns that do
# not exist anywhere in the current source — silent no-op on every live
# install. The canonical loader is what the runtime itself uses.
if ! grep -F 'bridge_load_roster' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit --all does not call bridge_load_roster; "
fi
if ! grep -F 'BRIDGE_AGENT_IDS' "$AUDIT_SH" >/dev/null; then
  T_CANONICAL_FAILS+="audit --all does not iterate BRIDGE_AGENT_IDS; "
fi

# T_canonical_e: the dead grep patterns from the r1 implementation are
# gone from executable code (comments referencing them are fine, since
# this file's history will keep mentioning the prior shape). The
# "line starts with optional whitespace then `#`" filter is done as a
# second grep so the comment-stripping anchor works correctly (a single
# bash regex anchoring "first non-whitespace char is not `#`" is
# surprisingly fragile under .* greediness).
if grep -nE 'bridge_register_agent' "$AUDIT_SH" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  T_CANONICAL_FAILS+="audit still has live (non-comment) bridge_register_agent grep; "
fi
if grep -nE 'AGENT_NAMES\+=' "$AUDIT_SH" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  T_CANONICAL_FAILS+="audit still has live (non-comment) AGENT_NAMES+= grep; "
fi

# T_canonical_f: no `done < <(...)` process-substitution in executable
# code. The audit file's own ban-list comment at the top of the file
# explicitly forbids this idiom; the r1 implementation violated its own
# contract at line 331. Allow the comment reference (the ban-list line)
# but reject any executable code that uses it.
if grep -nE 'done[[:space:]]*<[[:space:]]*<\(' "$AUDIT_SH" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  T_CANONICAL_FAILS+="audit still has live (non-comment) done < <(...) process-substitution; "
fi

if [[ -n "$T_CANONICAL_FAILS" ]]; then
  smoke_fail "T_canonical: canonical helper / roster enumeration / named-file regressions: $T_CANONICAL_FAILS"
fi

smoke_log "T_canonical PASS — audit uses bridge_isolation_v2_agent_group_name + bridge_agent_os_user + bridge_load_roster + BRIDGE_AGENT_IDS, no inline derivation, no process-substitution"

# ---------------------------------------------------------------------
# T_canonical teeth — verify the assertions actually bite by injecting
# the prior r1 shapes into copies of the audit script in a temp file.
#
# We don't mutate the real audit file. Instead we synthesize three
# fixture files in $SMOKE_TMP_ROOT that each carry one of the dead
# patterns the assertions look for; the helper used by T1 teeth is too
# tightly tied to the AGENTS_LIB function body, so we roll a thin
# inline grep harness here.
# ---------------------------------------------------------------------

smoke_log "T_canonical teeth: verify each canonical-check bites on a synthetic regression"

TEETH_AUDIT_NO_HELPERS="$SMOKE_TMP_ROOT/teeth-audit-no-helpers.sh"
TEETH_AUDIT_DEAD_GREP="$SMOKE_TMP_ROOT/teeth-audit-dead-grep.sh"
TEETH_AUDIT_PROC_SUB="$SMOKE_TMP_ROOT/teeth-audit-proc-sub.sh"

# Fixture #1 — audit that derives inline (no canonical helpers, no
# bridge-lib source). Should fail T_canonical_a/b/c.
{
  printf '#!/usr/bin/env bash\n'
  printf 'norm=$(printf %%s "$1" | tr -cd "a-z0-9-")\n'
  printf 'printf "ab-agent-%%s" "$norm"\n'
} > "$TEETH_AUDIT_NO_HELPERS"

if grep -F 'source "$REPO_ROOT/bridge-lib.sh"' "$TEETH_AUDIT_NO_HELPERS" >/dev/null; then
  smoke_fail "T_canonical teeth #1: fixture unexpectedly contains the bridge-lib source line (assertion would not bite)"
fi
if grep -F 'bridge_isolation_v2_agent_group_name' "$TEETH_AUDIT_NO_HELPERS" >/dev/null; then
  smoke_fail "T_canonical teeth #1: fixture unexpectedly contains the canonical group helper (assertion would not bite)"
fi

# Fixture #2 — audit with the dead bridge_register_agent grep restored
# in executable code. Should fail T_canonical_e.
{
  printf '#!/usr/bin/env bash\n'
  printf 'grep -hE "bridge_register_agent" "$roster_file"\n'
} > "$TEETH_AUDIT_DEAD_GREP"

if ! grep -nE 'bridge_register_agent' "$TEETH_AUDIT_DEAD_GREP" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  smoke_fail "T_canonical teeth #2: fixture does not actually expose the live bridge_register_agent grep — teeth setup broken"
fi

# Fixture #3 — audit with `done < <(...)` restored in executable code.
# Should fail T_canonical_f.
{
  printf '#!/usr/bin/env bash\n'
  printf 'while IFS= read -r line; do printf "%%s\\n" "$line"; done < <(grep foo bar)\n'
} > "$TEETH_AUDIT_PROC_SUB"

if ! grep -nE 'done[[:space:]]*<[[:space:]]*<\(' "$TEETH_AUDIT_PROC_SUB" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  smoke_fail "T_canonical teeth #3: fixture does not actually expose the live process-substitution — teeth setup broken"
fi

smoke_log "T_canonical teeth PASS — every canonical-check assertion would catch a regression to the r1 shape"

# ---------------------------------------------------------------------
# T_canonical runtime (Linux-only) — source bridge-lib.sh, register a
# fake roster with three pathological agents, then probe the canonical
# helpers the audit now uses:
#
#   - agent `h_smoke` (underscore in name) → canonical group keeps the
#     underscore (`ab-agent-h_smoke`), canonical default user keeps the
#     underscore too (`agent-bridge-h_smoke`); the r1 shape mangled
#     both to `-`.
#   - agent `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` (32 chars) → canonical
#     group hash-truncates per the 32-char Linux groupadd cap.
#   - agent `manual_explicit` with `BRIDGE_AGENT_OS_USER[manual_explicit]
#     =manual-name` → `bridge_agent_os_user` returns `manual-name`
#     (the explicit operator override).
#
# Skipped on non-Linux because `bridge_isolation_v2_agent_group_name`
# branches on uname; the Linux branch is what the audit's --all path
# will actually run against on the operator host.
# ---------------------------------------------------------------------

if smoke_is_linux; then
  smoke_log "T_canonical runtime: probe canonical helpers via bridge-lib.sh source (Linux only)"

  T_CANONICAL_RUNTIME_LOG="$SMOKE_TMP_ROOT/t_canonical-runtime.log"
  T_CANONICAL_RUNTIME_DRIVER="$SMOKE_TMP_ROOT/t_canonical-runtime-driver.sh"
  # Driver: source bridge-lib.sh + audit script. Audit script sources
  # bridge-lib.sh itself (idempotent under BRIDGE_ROSTER_CACHE_LOADED).
  # Set up three fake agents in BRIDGE_AGENT_OS_USER + BRIDGE_AGENT_IDS,
  # then echo the canonical group / iso user values for each.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'export BRIDGE_ROSTER_CACHE_DISABLE=1\n'
    printf 'source "%s/bridge-lib.sh"\n' "$REPO_ROOT"
    # The roster assoc maps are only declared by bridge_load_roster /
    # bridge_reset_roster_maps; sourcing bridge-lib.sh alone (cache
    # disabled, no load) leaves them undeclared. Under `set -u` an
    # undeclared-assoc subscript assignment (`MAP[h_smoke]=`) is parsed as
    # an ARITHMETIC subscript and dies with `h_smoke: unbound variable`.
    # Declare them idempotently (mirrors bridge-lib.sh cold-iso fallback).
    printf 'declare -gA BRIDGE_AGENT_OS_USER 2>/dev/null || true\n'
    printf 'declare -ga BRIDGE_AGENT_IDS 2>/dev/null || true\n'
    printf 'BRIDGE_AGENT_IDS+=(h_smoke aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa manual_explicit)\n'
    printf 'BRIDGE_AGENT_OS_USER[h_smoke]=""\n'
    printf 'BRIDGE_AGENT_OS_USER[aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]=""\n'
    printf 'BRIDGE_AGENT_OS_USER[manual_explicit]="manual-name"\n'
    printf '# Probe canonical helpers.\n'
    printf 'printf "h_smoke.group=%%s\\n"           "$(bridge_isolation_v2_agent_group_name h_smoke)"\n'
    printf 'printf "h_smoke.user_default=%%s\\n"   "$(bridge_agent_default_os_user h_smoke)"\n'
    printf 'printf "h_smoke.user_explicit=%%s\\n"  "$(bridge_agent_os_user h_smoke)"\n'
    printf 'printf "longname.group=%%s\\n"         "$(bridge_isolation_v2_agent_group_name aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"\n'
    printf 'printf "manual.user_explicit=%%s\\n"   "$(bridge_agent_os_user manual_explicit)"\n'
  } > "$T_CANONICAL_RUNTIME_DRIVER"
  chmod +x "$T_CANONICAL_RUNTIME_DRIVER"

  if ! bash "$T_CANONICAL_RUNTIME_DRIVER" > "$T_CANONICAL_RUNTIME_LOG" 2>&1; then
    smoke_log "T_canonical runtime: driver output:"
    cat "$T_CANONICAL_RUNTIME_LOG" >&2 || true
    smoke_fail "T_canonical runtime: driver bash exited non-zero"
  fi

  # h_smoke: canonical group preserves the underscore.
  if ! grep -F 'h_smoke.group=ab-agent-h_smoke' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_log "T_canonical runtime log:"
    cat "$T_CANONICAL_RUNTIME_LOG" >&2 || true
    smoke_fail "T_canonical runtime: bridge_isolation_v2_agent_group_name(h_smoke) did not return ab-agent-h_smoke (canonical preserves underscore)"
  fi

  # h_smoke: canonical default user preserves the underscore too.
  if ! grep -F 'h_smoke.user_default=agent-bridge-h_smoke' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_log "T_canonical runtime log:"
    cat "$T_CANONICAL_RUNTIME_LOG" >&2 || true
    smoke_fail "T_canonical runtime: bridge_agent_default_os_user(h_smoke) did not return agent-bridge-h_smoke (canonical preserves underscore)"
  fi

  # h_smoke: explicit os_user lookup is empty (no override).
  if ! grep -F 'h_smoke.user_explicit=' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_fail "T_canonical runtime: bridge_agent_os_user(h_smoke) did not return empty (no explicit override)"
  fi
  if grep -E '^h_smoke.user_explicit=.+' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_fail "T_canonical runtime: bridge_agent_os_user(h_smoke) unexpectedly returned a value (should be empty)"
  fi

  # long agent: canonical group must hash-truncate past 32 chars. The
  # prefix `ab-agent-` is 9 chars; total must be <=32. Therefore the
  # output is `ab-agent-<head>-<7hex>` with head length = 32-9-1-7 = 15.
  if ! grep -E 'longname.group=ab-agent-a{15}-[0-9a-f]{7}$' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_log "T_canonical runtime log:"
    cat "$T_CANONICAL_RUNTIME_LOG" >&2 || true
    smoke_fail "T_canonical runtime: bridge_isolation_v2_agent_group_name(<32-char name>) did not hash-truncate to the 32-char Linux limit"
  fi

  # manual: explicit os_user lookup returns the operator-provided value
  # (the canonical override path; the audit picks this up instead of
  # re-deriving `agent-bridge-manual_explicit`).
  if ! grep -F 'manual.user_explicit=manual-name' "$T_CANONICAL_RUNTIME_LOG" >/dev/null; then
    smoke_log "T_canonical runtime log:"
    cat "$T_CANONICAL_RUNTIME_LOG" >&2 || true
    smoke_fail "T_canonical runtime: bridge_agent_os_user(manual_explicit) did not return manual-name (explicit --os-user override path broken)"
  fi

  smoke_log "T_canonical runtime PASS — canonical helpers preserve underscores, hash-truncate long names, and honor explicit --os-user overrides"
else
  smoke_log "T_canonical runtime: skipped — non-Linux host (canonical helpers' Linux branch is what --all runs against on the operator host)"
fi

# ---------------------------------------------------------------------
# T_audit_executes_against_bad_fixture — codex r2 BLOCKING.
#
# The prior R1/R2 only validated audit script existence + syntax + grep
# path-name refs. Codex r2 reproduced the actual silent-OK bug by
# constructing a fixture workdir with `root:wrong 0700` root and
# `.ms365/.env root:wrong 0600` then running the audit — it returned
# rc=0 stderr "OK" because no code path stats the workdir root, and the
# .env check only compared mode.
#
# This T_audit_executes_against_bad_fixture sub-test re-creates that
# exact fixture and runs the patched audit against it, asserting:
#
#   - audit exits rc=1
#   - violation row emitted for the workdir root (wrong owner + wrong
#     mode 0700, expected 2770)
#   - violation row emitted for the .env (wrong owner, even at 0600)
#
# Seam: a temp bin dir with fake `sudo`, `getent`, and `stat` shims is
# prepended to PATH. The fake `sudo` consults a JSON map of
# path-to-`owner:group:mode` for stat queries, falls through to real
# filesystem for `test -d` / `test -e`, and forwards everything else.
# The fake `getent passwd <user>` reads from a local passwd file the
# smoke writes. The fake `stat` shim supports `-c '%a'` and
# `-c '%U:%G'`. `BRIDGE_AUDIT_TEST_FORCE_LINUX=1` keeps the audit's
# `uname -s` early-exit from short-circuiting on macOS dev hosts.
# ---------------------------------------------------------------------

smoke_log "T_audit_executes_against_bad_fixture: audit detects bad workdir root + .env on synthetic fixture (codex r2 BLOCKING)"

FIXTURE_ROOT="$SMOKE_TMP_ROOT/audit-fixture"
FIXTURE_BIN="$FIXTURE_ROOT/bin"
FIXTURE_BRIDGE_HOME="$FIXTURE_ROOT/bridge-home"
FIXTURE_DATA_ROOT="$FIXTURE_ROOT/data"
FIXTURE_AGENT="testagent"
FIXTURE_ISO_USER="agent-bridge-${FIXTURE_AGENT}"
FIXTURE_AGENT_GROUP="ab-agent-${FIXTURE_AGENT}"
FIXTURE_WORKDIR="$FIXTURE_DATA_ROOT/agents/$FIXTURE_AGENT/workdir"
FIXTURE_MS365_DIR="$FIXTURE_WORKDIR/.ms365"
FIXTURE_ENV_FILE="$FIXTURE_MS365_DIR/.env"
FIXTURE_STAT_JSON="$FIXTURE_ROOT/stat-map.json"
FIXTURE_PASSWD="$FIXTURE_ROOT/passwd"
FIXTURE_AUDIT_LOG="$FIXTURE_ROOT/audit-output.log"

mkdir -p "$FIXTURE_BIN" "$FIXTURE_BRIDGE_HOME" "$FIXTURE_DATA_ROOT" "$FIXTURE_MS365_DIR"
printf 'TOKEN=x\n' > "$FIXTURE_ENV_FILE"
chmod 0700 "$FIXTURE_WORKDIR"   # wrong mode for root (canonical is 2770)
chmod 0600 "$FIXTURE_ENV_FILE"  # correct mode for .env, but owner will be wrong

# Stat map: workdir root reports root:wrong 0700 (no setgid, wrong owner
# + group). .ms365 reports correct iso_user:agent_group 2770 so the
# audit doesn't trip on the channel-dir check (we want the workdir-root
# + .env violations to be the ones surfaced). .env reports root:wrong
# 0600 — mode is "correct" but owner+group are wrong (the bug class).
cat > "$FIXTURE_STAT_JSON" <<EOF_STAT
{
  "$FIXTURE_WORKDIR": "root:wrong:700",
  "$FIXTURE_MS365_DIR": "$FIXTURE_ISO_USER:$FIXTURE_AGENT_GROUP:2770",
  "$FIXTURE_ENV_FILE": "root:wrong:600"
}
EOF_STAT

# Fake passwd line so `getent passwd <iso_user>` resolves with HOME
# pointing into the fixture (audit walks $HOME/.claude/plugins/ which
# we leave absent — audit gracefully skips that subtree).
printf '%s:x:9999:9999:%s test:%s/home:/bin/bash\n' \
  "$FIXTURE_ISO_USER" "$FIXTURE_ISO_USER" "$FIXTURE_ROOT" > "$FIXTURE_PASSWD"

# Fake `sudo` — handles `sudo -n stat -c <fmt> <path>` from a JSON map,
# `sudo -n test -d <path>` / `sudo -n test -e <path>` from the real
# filesystem, and refuses everything else with rc=1 (so the audit can't
# silently fall back to a real privileged op).
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): the python lookup
# helper is a separate file, NOT a `python3 - <<EOF` inside a `$(...)`
# command substitution. The python script is created once next to the
# sudo shim and invoked with file-as-argv.
FIXTURE_STAT_LOOKUP_PY="$FIXTURE_BIN/_stat-lookup.py"
cat > "$FIXTURE_STAT_LOOKUP_PY" <<'EOF_STAT_LOOKUP_PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
    print(m.get(sys.argv[2], ""))
except Exception:
    sys.exit(1)
EOF_STAT_LOOKUP_PY
chmod +x "$FIXTURE_STAT_LOOKUP_PY"

cat > "$FIXTURE_BIN/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
# Fake sudo for T_audit_executes_against_bad_fixture. Strips a leading
# -n flag, then dispatches stat/test to deterministic helpers.
_self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ "${1:-}" == "-n" ]]; then shift; fi
cmd="${1:-}"; shift || true
case "$cmd" in
  stat)
    fmt=""
    if [[ "${1:-}" == "-c" ]]; then
      shift
      fmt="${1:-}"; shift
    fi
    path="${1:-}"
    json="${BRIDGE_AUDIT_TEST_STAT_JSON:-}"
    [[ -f "$json" ]] || exit 1
    # Lookup the path key. Footgun #11: invoke python3 with file-as-argv
    # (NOT `python3 - <<EOF` inside `$(...)`).
    entry="$(python3 "$_self_dir/_stat-lookup.py" "$json" "$path" 2>/dev/null)"
    [[ -n "$entry" ]] || exit 1
    owner="${entry%%:*}"; rest="${entry#*:}"
    group="${rest%%:*}"; mode="${rest#*:}"
    case "$fmt" in
      '%a') printf '%s\n' "$mode" ;;
      '%U:%G') printf '%s:%s\n' "$owner" "$group" ;;
      *) exit 1 ;;
    esac
    ;;
  test)
    # test -d <path> / test -e <path>. Defer to real filesystem.
    /bin/test "$@"
    ;;
  *)
    # Refuse any other privileged op — the audit must not depend on
    # arbitrary sudo execution in test mode.
    exit 1
    ;;
esac
EOF_SUDO
chmod +x "$FIXTURE_BIN/sudo"

# Fake `getent` — only handles `getent passwd <name>` from our fixture
# passwd file.
cat > "$FIXTURE_BIN/getent" <<EOF_GETENT
#!/usr/bin/env bash
if [[ "\${1:-}" == "passwd" && -n "\${2:-}" ]]; then
  grep -E "^\${2}:" "$FIXTURE_PASSWD" || exit 2
  exit 0
fi
exit 2
EOF_GETENT
chmod +x "$FIXTURE_BIN/getent"

# Run the audit against the fixture. Use a subshell to scope PATH +
# BRIDGE_* env without leaking into subsequent smoke phases.
(
  export PATH="$FIXTURE_BIN:$PATH"
  export BRIDGE_AUDIT_TEST_FORCE_LINUX=1
  export BRIDGE_AUDIT_TEST_STAT_JSON="$FIXTURE_STAT_JSON"
  export BRIDGE_HOME="$FIXTURE_BRIDGE_HOME"
  export BRIDGE_DATA_ROOT="$FIXTURE_DATA_ROOT"
  export BRIDGE_AGENT_ROOT_V2="$FIXTURE_DATA_ROOT/agents"
  export BRIDGE_LAYOUT=v2
  bash "$AUDIT_SH" "$FIXTURE_AGENT"
) > "$FIXTURE_AUDIT_LOG" 2>&1
audit_rc=$?

if [[ $audit_rc -eq 0 ]]; then
  smoke_log "T_audit_executes_against_bad_fixture: audit output:"
  cat "$FIXTURE_AUDIT_LOG" >&2 || true
  smoke_fail "T_audit_executes_against_bad_fixture: audit exited rc=0 against fixture with bad workdir root + bad .env — silent false negative (codex r2 BLOCKING regressed)"
fi

if ! grep -F "$FIXTURE_WORKDIR" "$FIXTURE_AUDIT_LOG" | grep -F "workdir-root" >/dev/null; then
  smoke_log "T_audit_executes_against_bad_fixture: audit output:"
  cat "$FIXTURE_AUDIT_LOG" >&2 || true
  smoke_fail "T_audit_executes_against_bad_fixture: audit did not emit workdir-root violation row for bad fixture workdir root"
fi

if ! grep -F "$FIXTURE_ENV_FILE" "$FIXTURE_AUDIT_LOG" | grep -F "channel-env-file" >/dev/null; then
  smoke_log "T_audit_executes_against_bad_fixture: audit output:"
  cat "$FIXTURE_AUDIT_LOG" >&2 || true
  smoke_fail "T_audit_executes_against_bad_fixture: audit did not emit channel-env-file violation row for root:wrong 0600 .env"
fi

smoke_log "T_audit_executes_against_bad_fixture PASS — audit rc=$audit_rc + workdir-root + .env violations emitted"

# Teeth — revert the workdir-root stat block (write a copy of the audit
# script without the workdir-root branch) and confirm the fixture test
# would fail to catch the bad workdir root. Same for the .env owner/group
# triple check.
#
# We don't mutate the real audit file; we run a temp copy with the
# offending block stripped (sed -E delete-range) and assert rc=0 (silent
# OK on the bad fixture).
TEETH_AUDIT_NO_WORKDIR_ROOT="$SMOKE_TMP_ROOT/teeth-audit-no-workdir-root.sh"

# Strip the workdir-root stat block: from the "# ------ workdir root +
# channel state dirs ------" header through the matching "fi" before the
# channel loop. The simplest way is to delete every line between two
# markers we can grep for. Use awk to suppress the workdir-root block
# specifically: lines starting at "# Codex r2 BLOCKING: validate the
# workdir root itself" through the corresponding `fi` that closes the
# workdir-root if/else. Look for the next blank line followed by
# "local channel" as the end marker.
awk '
  /# Codex r2 BLOCKING: validate the workdir root itself/ { skip=1; next }
  skip && /^[[:space:]]+local channel$/ { skip=0; print; next }
  skip { next }
  { print }
' "$AUDIT_SH" > "$TEETH_AUDIT_NO_WORKDIR_ROOT"

# Confirm the strip actually happened.
if grep -F "workdir-root" "$TEETH_AUDIT_NO_WORKDIR_ROOT" >/dev/null; then
  smoke_fail "teeth: workdir-root revert did not actually remove the workdir-root block (sed/awk pattern broke) — teeth setup broken"
fi
if ! grep -F "workdir-root" "$AUDIT_SH" >/dev/null; then
  smoke_fail "teeth: real audit script does not contain the workdir-root literal — assertion would not bite on real script"
fi
chmod +x "$TEETH_AUDIT_NO_WORKDIR_ROOT"

(
  export PATH="$FIXTURE_BIN:$PATH"
  export BRIDGE_AUDIT_TEST_FORCE_LINUX=1
  export BRIDGE_AUDIT_TEST_STAT_JSON="$FIXTURE_STAT_JSON"
  export BRIDGE_HOME="$FIXTURE_BRIDGE_HOME"
  export BRIDGE_DATA_ROOT="$FIXTURE_DATA_ROOT"
  export BRIDGE_AGENT_ROOT_V2="$FIXTURE_DATA_ROOT/agents"
  export BRIDGE_LAYOUT=v2
  bash "$TEETH_AUDIT_NO_WORKDIR_ROOT" "$FIXTURE_AGENT"
) > "$FIXTURE_ROOT/teeth-no-workdir-root.log" 2>&1
teeth_no_root_rc=$?

# .env is still root:wrong 0600 — but the audit only reports rc=1 if
# the .env triple-check ALSO bites. So we expect teeth_no_root_rc=1
# (because .env still violates owner). To prove the workdir-root block
# is load-bearing, assert that the workdir-root violation row is GONE
# from the teeth output even though we ran against the bad fixture.
if grep -F "$FIXTURE_WORKDIR" "$FIXTURE_ROOT/teeth-no-workdir-root.log" | grep -F "workdir-root" >/dev/null; then
  smoke_fail "teeth: stripped audit still emits workdir-root violation row (strip did not work)"
fi

# Now teeth #2: revert the .env triple-check (drop the owner+group
# comparison, keep only mode). Use awk for portability — BSD sed handles
# the `||` operator differently from GNU sed, so a sed substitution that
# works on Linux can RE-error on macOS. awk with literal-string match +
# print is portable across BSD/GNU.
TEETH_AUDIT_ENV_MODE_ONLY="$SMOKE_TMP_ROOT/teeth-audit-env-mode-only.sh"
awk '
  /if \[\[ "\$mode" != "600" \|\| "\$owner_group" != "\$iso_user:\$agent_group" \]\]; then/ {
    # Replace the line with the mode-only form.
    sub(/if \[\[ "\$mode" != "600" \|\| "\$owner_group" != "\$iso_user:\$agent_group" \]\]; then/, "if [[ \"$mode\" != \"600\" ]]; then")
  }
  { print }
' "$AUDIT_SH" > "$TEETH_AUDIT_ENV_MODE_ONLY"

if ! grep -F 'if [[ "$mode" != "600" ]]; then' "$TEETH_AUDIT_ENV_MODE_ONLY" >/dev/null; then
  smoke_fail "teeth: .env triple-check revert did not produce the mode-only form — awk pattern mismatch"
fi
if grep -F 'if [[ "$mode" != "600" || "$owner_group" != "$iso_user:$agent_group" ]]; then' "$TEETH_AUDIT_ENV_MODE_ONLY" >/dev/null; then
  smoke_fail "teeth: .env triple-check revert did not remove the triple-check (awk picked the wrong line)"
fi
chmod +x "$TEETH_AUDIT_ENV_MODE_ONLY"

(
  export PATH="$FIXTURE_BIN:$PATH"
  export BRIDGE_AUDIT_TEST_FORCE_LINUX=1
  export BRIDGE_AUDIT_TEST_STAT_JSON="$FIXTURE_STAT_JSON"
  export BRIDGE_HOME="$FIXTURE_BRIDGE_HOME"
  export BRIDGE_DATA_ROOT="$FIXTURE_DATA_ROOT"
  export BRIDGE_AGENT_ROOT_V2="$FIXTURE_DATA_ROOT/agents"
  export BRIDGE_LAYOUT=v2
  bash "$TEETH_AUDIT_ENV_MODE_ONLY" "$FIXTURE_AGENT"
) > "$FIXTURE_ROOT/teeth-env-mode-only.log" 2>&1

# In the mode-only variant, the .env at mode 600 (but root:wrong) reports
# OK silently. Workdir-root violation still bites (because we kept that
# block), so rc=1 from workdir-root alone. But the channel-env-file row
# must be ABSENT.
if grep -F "$FIXTURE_ENV_FILE" "$FIXTURE_ROOT/teeth-env-mode-only.log" | grep -F "channel-env-file" >/dev/null; then
  smoke_fail "teeth: stripped audit (.env mode-only) still emits channel-env-file violation row for root:wrong 0600 — triple-check is not load-bearing"
fi

smoke_log "Teeth PASS — reverting workdir-root block silences workdir-root rows; reverting .env triple-check silences .env owner/group rows"

smoke_log "all tests PASS — Lane H (#1278 + #1208 + #1215 cross-check + r2 canonical helpers + r3 workdir-root/.env/canonical-workdir + fixture-run) verified at current source"
