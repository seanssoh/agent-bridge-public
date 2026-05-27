#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/K-beta4-nits.sh
#
# Lane K of v0.15.0-beta4 — 5-issue nits batch:
#
#   #1282 (Surface A): `bridge_run_prune_legacy_teams_mcp` no longer
#         log-lines the steady-state `absent path=…` / `unchanged
#         path=…` rows — only `pruned` / `failed` / `skipped` reach the
#         operator's audit tail. Log noise downgrade.
#
#   #1282 (Surface B): `bridge-dev-plugin-cache.py` sync now marks a
#         plugin source that ships no `package.json` deps and no
#         lockfile as `node_modules=not-required` instead of the
#         cosmetic-noise `node_modules=missing`. `.mjs` proxy plugins
#         (Node.js inline deps) stop painting the dashboard with
#         false-positive alerts.
#
#   #1283: `agent-bridge diagnose acl` subcommand retired. ACL-based
#         cross-UID grants are no longer the recommended isolation
#         mechanism (iso v2 uses group-based perms). Verb invocation
#         now emits a deprecation notice to stderr and exits non-zero;
#         the heavy ACL scanner helpers are removed.
#
#   #1247: `agb admin set --auto-restart on|off` CLI surface added.
#         Phase 1 — persists the flag into `state/admin-config.json`
#         via the new `scripts/python-helpers/admin-set-config.py`
#         helper (file-as-argv per footgun #11). Future PRs wire the
#         flag into the post-`agent create` admin-set restart
#         automation.
#
#   #1253: `agb claim --note <text>` (and `--note-file <path>`) now
#         accepted and propagated through to the `task_events` row
#         (`event_type=claimed`, `note_text=<text>` / `note_path=<p>`).
#         Symmetric with `agb done` / `agb update`.
#
#   #1255: roster read-block softened for ADMIN shells. The strict
#         read-intent whitelist (cat/grep/head/tail/...) is now bypassed
#         when the bash command is issued by an admin agent AND has no
#         detectable write-intent token (`tee`, `sed -i`, `awk -i
#         inplace`, output redirection, known mutators). Non-admin
#         class still hits the original deny — those agents must not
#         dump roster secrets into commit messages / audit logs even
#         under a non-write-intent verb (`git commit -F <roster>`).
#         Write paths still flow through the `agent-bridge config
#         set` wrapper.
#
# Test plan:
#   T1  (#1282 A): `bridge_run_prune_legacy_teams_mcp` line filter
#                  drops `absent path=…` rows from the audit log.
#   T1t (#1282 A teeth): when the filter is bypassed, `absent path=`
#                  appears in the log. Proves the filter is what
#                  closes the noise.
#   T2  (#1282 B): `_plugin_source_declares_deps` returns False for a
#                  source dir with no package.json / lockfile, and
#                  True for a source dir with a `dependencies` entry.
#   T3  (#1283): `bash bridge-diagnose.sh acl` exits non-zero AND the
#                  deprecation notice appears on stderr. The
#                  `bridge_diagnose_acl_main` / `_scan_path` helpers
#                  are gone from the file.
#   T4  (#1247): `admin-set-config.py set-auto-restart --value on`
#                  writes a JSON object with `auto_restart_on_membership_change`
#                  set to true. A follow-up call with `--value off`
#                  flips it back to false. The `admin_agent` field
#                  is preserved across mutations.
#   T5  (#1253): `bridge-queue.py claim` with `--note "blah"` writes
#                  a `task_events` row with `event_type=claimed` and
#                  `note_text=blah`. The stdout summary line includes
#                  `claim_note=4c`.
#   T5t (#1253 teeth): claim without `--note` writes a `task_events`
#                  row with `event_type=claimed` AND `note_text IS
#                  NULL`. Proves the propagation is opt-in.
#   T6  (#1255): `_bash_command_has_no_write_intent` returns True for
#                  benign reads + custom non-write commands; False
#                  for `... > <roster>`, `tee <roster>`, `sed -i`, and
#                  any output redirection.
#   T6t (#1255 teeth): the strict `_is_read_intent_bash` whitelist
#                  rejects a custom command that the new softer
#                  classifier accepts — proving the softening is what
#                  unblocks issue #1255's repro shape.
#
# Footgun #11: no `<<EOF` to subprocess, no `<<<` here-strings into
# command substitutions, no inline Python heredoc-to-stdin. Helpers
# are exercised as standalone scripts.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home. No network.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:K-beta4-nits][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="K-beta4-nits"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
RUN_SH="$REPO_ROOT/bridge-run.sh"
DIAG_SH="$REPO_ROOT/bridge-diagnose.sh"
DEV_CACHE_PY="$REPO_ROOT/bridge-dev-plugin-cache.py"
ADMIN_SET_PY="$REPO_ROOT/scripts/python-helpers/admin-set-config.py"
QUEUE_PY="$REPO_ROOT/bridge-queue.py"
TOOL_POLICY_PY="$REPO_ROOT/hooks/tool-policy.py"

smoke_assert_file_exists "$RUN_SH" "bridge-run.sh present"
smoke_assert_file_exists "$DIAG_SH" "bridge-diagnose.sh present"
smoke_assert_file_exists "$DEV_CACHE_PY" "bridge-dev-plugin-cache.py present"
smoke_assert_file_exists "$ADMIN_SET_PY" "admin-set-config.py present"
smoke_assert_file_exists "$QUEUE_PY" "bridge-queue.py present"
smoke_assert_file_exists "$TOOL_POLICY_PY" "hooks/tool-policy.py present"

# ---------------------------------------------------------------------------
# T1 (#1282 Surface A): `bridge_run_prune_legacy_teams_mcp` drops the
# `absent path=…` / `unchanged path=…` lines.
# ---------------------------------------------------------------------------
smoke_log "T1: prune_legacy_teams_mcp filters absent/unchanged noise (#1282 Surface A)"

T1_FILTER_SCRIPT="$SMOKE_TMP_ROOT/t1-filter.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  # Inline the filter loop with the exact contract from
  # `bridge_run_prune_legacy_teams_mcp` so we exercise the case
  # statement faithfully without needing the rest of bridge-run.sh's
  # roster/agent plumbing.
  printf 'logged=()\n'
  printf 'log_line() { logged+=("$1"); }\n'
  printf 'output=$(printf "%%s\\n" \\\n'
  printf '    "absent path=/tmp/agent-root/.mcp.json" \\\n'
  printf '    "unchanged path=/tmp/agent-root/.mcp.json reason=no-mcpServers" \\\n'
  printf '    "pruned path=/tmp/workdir/.mcp.json" \\\n'
  printf '    "skipped path=/tmp/other.json reason=read-failed:ENOENT" \\\n'
  printf '    "failed path=/tmp/locked.json reason=write-failed:EROFS")\n'
  printf 'while IFS= read -r line; do\n'
  printf '  [[ -n "$line" ]] || continue\n'
  printf '  case "$line" in\n'
  printf '    "absent path="*|"unchanged path="*)\n'
  printf '      continue\n'
  printf '      ;;\n'
  printf '  esac\n'
  printf '  log_line "[legacy-teams-mcp] $line"\n'
  printf 'done <<<"$output"\n'
  printf 'printf "%%s\\n" "${logged[@]}"\n'
} >"$T1_FILTER_SCRIPT"

T1_OUT="$(bash "$T1_FILTER_SCRIPT" 2>&1)" || smoke_fail "T1: filter driver failed"
smoke_assert_not_contains "$T1_OUT" "absent path=" \
  "T1: 'absent path=' must be filtered out of the audit log"
smoke_assert_not_contains "$T1_OUT" "unchanged path=" \
  "T1: 'unchanged path=' must be filtered out of the audit log"
smoke_assert_contains "$T1_OUT" "[legacy-teams-mcp] pruned path=" \
  "T1: 'pruned path=' must still reach the audit log (action that happened)"
smoke_assert_contains "$T1_OUT" "[legacy-teams-mcp] skipped path=" \
  "T1: 'skipped path=' must still reach the audit log (operator must see)"
smoke_assert_contains "$T1_OUT" "[legacy-teams-mcp] failed path=" \
  "T1: 'failed path=' must still reach the audit log (operator must see)"

# T1 teeth: when the filter is removed the noise comes back.
smoke_log "T1 teeth: filter removed → 'absent path=' re-appears"
T1T_SCRIPT="$SMOKE_TMP_ROOT/t1-teeth.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'logged=()\n'
  printf 'log_line() { logged+=("$1"); }\n'
  printf 'output=$(printf "%%s\\n" "absent path=/tmp/x" "pruned path=/tmp/y")\n'
  # No case statement — teeth simulates the pre-fix behavior.
  printf 'while IFS= read -r line; do\n'
  printf '  [[ -n "$line" ]] || continue\n'
  printf '  log_line "[legacy-teams-mcp] $line"\n'
  printf 'done <<<"$output"\n'
  printf 'printf "%%s\\n" "${logged[@]}"\n'
} >"$T1T_SCRIPT"
T1T_OUT="$(bash "$T1T_SCRIPT" 2>&1)" || smoke_fail "T1 teeth driver failed"
smoke_assert_contains "$T1T_OUT" "absent path=" \
  "T1 teeth: without the filter, the noise line re-appears"

# Belt-and-braces: confirm the actual production filter sits in
# bridge-run.sh — regressing the case lines would be caught by a grep.
smoke_assert_contains \
  "$(grep -n 'absent path=' "$RUN_SH" 2>/dev/null || true)" \
  "absent path=" \
  "T1: production bridge-run.sh keeps the 'absent path=' filter line"

# ---------------------------------------------------------------------------
# T2 (#1282 Surface B): _plugin_source_declares_deps heuristic.
# ---------------------------------------------------------------------------
smoke_log "T2: _plugin_source_declares_deps heuristic (#1282 Surface B)"

T2_NO_DEPS="$SMOKE_TMP_ROOT/plugin-no-deps"
mkdir -p "$T2_NO_DEPS"
printf '// inline-deps proxy\nimport http from "node:http";\n' >"$T2_NO_DEPS/ep-mcp-proxy.mjs"

T2_DEPS_DECLARED="$SMOKE_TMP_ROOT/plugin-deps-declared"
mkdir -p "$T2_DEPS_DECLARED"
printf '{"name":"x","dependencies":{"foo":"^1.0.0"}}\n' >"$T2_DEPS_DECLARED/package.json"

T2_DEPS_LOCKFILE="$SMOKE_TMP_ROOT/plugin-lockfile-only"
mkdir -p "$T2_DEPS_LOCKFILE"
printf '{}\n' >"$T2_DEPS_LOCKFILE/package.json"
printf '{}' >"$T2_DEPS_LOCKFILE/bun.lock"

T2_PROBE="$SMOKE_TMP_ROOT/t2-probe.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import importlib.util, sys\n'
  printf 'spec = importlib.util.spec_from_file_location("dpc", "%s")\n' "$DEV_CACHE_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'from pathlib import Path\n'
  printf 'cases = [\n'
  printf '    ("no-deps", "%s", False),\n' "$T2_NO_DEPS"
  printf '    ("deps-declared", "%s", True),\n' "$T2_DEPS_DECLARED"
  printf '    ("lockfile-only", "%s", True),\n' "$T2_DEPS_LOCKFILE"
  printf ']\n'
  printf 'for label, path, expected in cases:\n'
  printf '    got = m._plugin_source_declares_deps(Path(path))\n'
  printf '    status = "OK" if got == expected else "FAIL"\n'
  printf '    print(f"{status} {label} got={got} expected={expected}")\n'
} >"$T2_PROBE"
T2_OUT="$(python3 "$T2_PROBE" 2>&1)" || smoke_fail "T2: probe failed: $T2_OUT"
smoke_assert_contains "$T2_OUT" "OK no-deps got=False" \
  "T2: source with no package.json deps + no lockfile → False"
smoke_assert_contains "$T2_OUT" "OK deps-declared got=True" \
  "T2: source with non-empty 'dependencies' → True"
smoke_assert_contains "$T2_OUT" "OK lockfile-only got=True" \
  "T2: source with sibling lockfile → True"
smoke_assert_not_contains "$T2_OUT" "FAIL " \
  "T2: every heuristic case must pass"

# ---------------------------------------------------------------------------
# T3 (#1283): diagnose acl deprecation notice + non-zero exit.
# ---------------------------------------------------------------------------
smoke_log "T3: 'agent-bridge diagnose acl' retired (#1283)"

T3_RC=0
T3_OUT="$(bash "$DIAG_SH" acl 2>&1)" || T3_RC=$?
if (( T3_RC == 0 )); then
  smoke_fail "T3: diagnose acl must exit non-zero (got rc=0). Output: $T3_OUT"
fi
smoke_assert_contains "$T3_OUT" "deprecated" \
  "T3: deprecation notice surfaces on the diagnose acl path"
smoke_assert_contains "$T3_OUT" "isolation reconcile" \
  "T3: notice points operators at the iso v2 replacement"

# The heavy ACL scanner helpers must be gone — regressing them would
# resurrect the ACL diagnostic pathway #1283 retired.
smoke_assert_not_contains "$(cat "$DIAG_SH")" "bridge_diagnose_acl_scan_path" \
  "T3: bridge_diagnose_acl_scan_path helper removed from bridge-diagnose.sh"
smoke_assert_not_contains "$(cat "$DIAG_SH")" "bridge_diagnose_acl_targets" \
  "T3: bridge_diagnose_acl_targets helper removed from bridge-diagnose.sh"
smoke_assert_not_contains "$(cat "$DIAG_SH")" "getfacl" \
  "T3: getfacl reference removed (ACL scanner gone)"

# `agent-bridge diagnose` (no subcommand) still prints a usage banner.
T3_USAGE_OUT="$(bash "$DIAG_SH" 2>&1)" || smoke_fail "T3: diagnose (no args) must succeed"
smoke_assert_contains "$T3_USAGE_OUT" "Usage:" \
  "T3: diagnose with no subcommand still prints usage"

# ---------------------------------------------------------------------------
# T4 (#1247): `agb admin set --auto-restart on|off` writes JSON config.
# ---------------------------------------------------------------------------
smoke_log "T4: admin-set-config.py persists auto_restart_on_membership_change (#1247)"

T4_CONFIG="$SMOKE_TMP_ROOT/admin-config.json"

python3 "$ADMIN_SET_PY" set-auto-restart \
  --admin patch \
  --config "$T4_CONFIG" \
  --value on >"$SMOKE_TMP_ROOT/t4-on.out" 2>&1 \
  || smoke_fail "T4: set-auto-restart on failed"

smoke_assert_file_exists "$T4_CONFIG" "T4: config file created"
T4_ON="$(cat "$T4_CONFIG")"
smoke_assert_contains "$T4_ON" '"admin_agent": "patch"' \
  "T4 ON: admin_agent recorded"
smoke_assert_contains "$T4_ON" '"auto_restart_on_membership_change": true' \
  "T4 ON: flag persisted to true"

python3 "$ADMIN_SET_PY" set-auto-restart \
  --admin patch \
  --config "$T4_CONFIG" \
  --value off >"$SMOKE_TMP_ROOT/t4-off.out" 2>&1 \
  || smoke_fail "T4: set-auto-restart off failed"

T4_OFF="$(cat "$T4_CONFIG")"
smoke_assert_contains "$T4_OFF" '"auto_restart_on_membership_change": false' \
  "T4 OFF: flag flips back to false"
smoke_assert_contains "$T4_OFF" '"admin_agent": "patch"' \
  "T4 OFF: admin_agent preserved across mutations"

# Reject an invalid value.
T4_INVALID_RC=0
python3 "$ADMIN_SET_PY" set-auto-restart \
  --admin patch \
  --config "$T4_CONFIG" \
  --value sometimes >/dev/null 2>&1 || T4_INVALID_RC=$?
[[ "$T4_INVALID_RC" -ne 0 ]] || \
  smoke_fail "T4: invalid --value must reject (got rc=0)"

# ---------------------------------------------------------------------------
# T5 (#1253): claim --note propagates into task_events.
# ---------------------------------------------------------------------------
smoke_log "T5: claim --note writes note_text into task_events (#1253)"

T5_QUEUE_DB="$SMOKE_TMP_ROOT/k-tasks.db"
export BRIDGE_TASK_DB="$T5_QUEUE_DB"
export BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
mkdir -p "$BRIDGE_HOME/state"

# Bootstrap a queued task assigned to "patch" via the create verb.
T5_CREATE_OUT="$(python3 "$QUEUE_PY" create \
  --from operator --to patch --title "K-beta4 test" --body "smoke test body" 2>&1)" \
  || smoke_fail "T5: create failed: $T5_CREATE_OUT"

# Parse the task id from the create output. The line shape is
# `task #<id> queued ...`. We do not depend on JSON output so the
# smoke survives an older queue-CLI output format.
T5_TASK_ID="$(printf '%s\n' "$T5_CREATE_OUT" | awk '/task #[0-9]+/ {for (i=1; i<=NF; i++) if ($i ~ /^#[0-9]+$/) { gsub("#","",$i); print $i; exit }}')"
[[ -n "$T5_TASK_ID" ]] \
  || smoke_fail "T5: could not parse task id from create output: $T5_CREATE_OUT"

# Claim with --note.
T5_CLAIM_OUT="$(python3 "$QUEUE_PY" claim "$T5_TASK_ID" \
  --agent patch --note "blah" 2>&1)" \
  || smoke_fail "T5: claim --note failed: $T5_CLAIM_OUT"

smoke_assert_contains "$T5_CLAIM_OUT" "claim_note=4c" \
  "T5: claim stdout summary echoes claim_note=<n>c"

# Probe the events log directly via the helper Python.
T5_EVENT_PROBE="$SMOKE_TMP_ROOT/t5-event-probe.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import sqlite3, sys\n'
  printf 'conn = sqlite3.connect("%s")\n' "$T5_QUEUE_DB"
  printf 'conn.row_factory = sqlite3.Row\n'
  printf 'rows = list(conn.execute("SELECT event_type, note_text FROM task_events WHERE task_id = ? ORDER BY id", (int(sys.argv[1]),)))\n'
  printf 'for r in rows:\n'
  printf '    et = r["event_type"]\n'
  printf '    nt = r["note_text"]\n'
  printf '    print(et + "|" + (str(nt) if nt is not None else "None"))\n'
} >"$T5_EVENT_PROBE"

T5_EVENTS="$(python3 "$T5_EVENT_PROBE" "$T5_TASK_ID" 2>&1)" \
  || smoke_fail "T5: event probe failed: $T5_EVENTS"
smoke_assert_contains "$T5_EVENTS" "claimed|blah" \
  "T5: task_events row for the claim carries note_text='blah'"

# T5 teeth: claim a fresh task WITHOUT --note. note_text must be NULL.
smoke_log "T5 teeth: claim without --note leaves note_text NULL"
T5T_CREATE_OUT="$(python3 "$QUEUE_PY" create \
  --from operator --to patch --title "K-beta4 nonote" --body "smoke teeth body" 2>&1)" \
  || smoke_fail "T5 teeth: create failed: $T5T_CREATE_OUT"
T5T_TASK_ID="$(printf '%s\n' "$T5T_CREATE_OUT" | awk '/task #[0-9]+/ {for (i=1; i<=NF; i++) if ($i ~ /^#[0-9]+$/) { gsub("#","",$i); print $i; exit }}')"
[[ -n "$T5T_TASK_ID" ]] || smoke_fail "T5 teeth: could not parse task id"

T5T_CLAIM_OUT="$(python3 "$QUEUE_PY" claim "$T5T_TASK_ID" --agent patch 2>&1)" \
  || smoke_fail "T5 teeth: claim no-note failed: $T5T_CLAIM_OUT"
smoke_assert_not_contains "$T5T_CLAIM_OUT" "claim_note=" \
  "T5 teeth: no --note → stdout summary omits the claim_note= field"

T5T_EVENTS="$(python3 "$T5_EVENT_PROBE" "$T5T_TASK_ID" 2>&1)" \
  || smoke_fail "T5 teeth: event probe failed"
smoke_assert_contains "$T5T_EVENTS" "claimed|None" \
  "T5 teeth: claim row's note_text is NULL when --note omitted"

# ---------------------------------------------------------------------------
# T6 (#1255): roster read-block softer classifier + admin-only gate.
# ---------------------------------------------------------------------------
smoke_log "T6: roster read-block softening — admin allow + non-admin still deny (#1255)"

T6_PROBE="$SMOKE_TMP_ROOT/t6-probe.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import os, importlib.util, sys, tempfile\n'
  printf 'from pathlib import Path\n'
  # Pin BRIDGE_HOME so roster_local_path() resolves to a stable absolute
  # path, then mention it directly in the test command. The hook's
  # path check operates on the canonical roster_local_path() — not on
  # the argv string verbatim — so the command must reference exactly
  # that absolute path.
  printf 'bridge_home = tempfile.mkdtemp(prefix="t6-bridge-home-")\n'
  printf 'os.environ["BRIDGE_HOME"] = bridge_home\n'
  printf 'os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-test"\n'
  printf 'spec = importlib.util.spec_from_file_location("tp", "%s")\n' "$TOOL_POLICY_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'roster_path = m.roster_local_path()\n'
  printf 'roster_path.parent.mkdir(parents=True, exist_ok=True)\n'
  printf 'roster_path.write_text("# fixture roster\\n")\n'
  printf 'rp = str(roster_path)\n'
  # _bash_command_has_no_write_intent unit-level cases.
  printf 'classifier_cases = [\n'
  printf '    ("plain-read", "cat " + rp, True),\n'
  printf '    ("custom-tool", "myprog --opt " + rp, True),\n'
  printf '    ("read-pipeline", "grep BRIDGE " + rp + " | head -3", True),\n'
  printf '    ("write-redirect", "cat foo > " + rp, False),\n'
  printf '    ("tee-write", "echo line | tee " + rp, False),\n'
  printf '    ("sed-inplace", "sed -i s/a/b/ " + rp, False),\n'
  printf '    ("rm-mutator", "rm " + rp, False),\n'
  printf '    ("mv-mutator", "mv x " + rp, False),\n'
  printf '    ("numeric-fd-redirect", "cat x 1>" + rp, False),\n'
  printf ']\n'
  printf 'failed = False\n'
  printf 'for label, cmd, expected in classifier_cases:\n'
  printf '    got = m._bash_command_has_no_write_intent(cmd)\n'
  printf '    if got == expected:\n'
  printf '        print("OK classifier " + label + " got=" + str(got))\n'
  printf '    else:\n'
  printf '        failed = True\n'
  printf '        print("FAIL classifier " + label + " got=" + str(got) + " expected=" + str(expected) + " cmd=" + repr(cmd))\n'
  # End-to-end cases via protected_alias_reason. admin-test is admin via
  # BRIDGE_ADMIN_AGENT_ID; "self" is treated as non-admin.
  printf 'gate_cases = [\n'
  # admin + custom non-write-intent tool → allowed (None).
  printf '    ("admin-custom-tool", "admin-test", "myprog --opt " + rp, None),\n'
  # admin + write-redirect → blocked. Admin deny preserves the
  # `agent-bridge config set` wrapper wording per #341 CP2.
  printf '    ("admin-redirect-write", "admin-test", "cat x > " + rp, "protected system config path"),\n'
  # non-admin + custom non-write-intent tool → blocked ("shared roster
  # secrets" wording, intentionally distinct from the admin deny).
  printf '    ("non-admin-custom-tool", "self", "git commit -F " + rp, "shared roster secrets"),\n'
  # non-admin + plain read → allowed via strict read_intent.
  printf '    ("non-admin-plain-read", "self", "cat " + rp, None),\n'
  printf ']\n'
  printf 'for label, agent, cmd, expected in gate_cases:\n'
  printf '    got = m.protected_alias_reason(cmd, agent)\n'
  printf '    if expected is None:\n'
  printf '        if got is None:\n'
  printf '            print("OK gate " + label + " allowed")\n'
  printf '        else:\n'
  printf '            failed = True\n'
  printf '            print("FAIL gate " + label + " expected=allow got=" + repr(got))\n'
  printf '    else:\n'
  printf '        if got is not None and expected in str(got):\n'
  printf '            print("OK gate " + label + " denied containing=" + expected)\n'
  printf '        else:\n'
  printf '            failed = True\n'
  printf '            print("FAIL gate " + label + " expected_contains=" + expected + " got=" + repr(got))\n'
  printf 'sys.exit(1 if failed else 0)\n'
} >"$T6_PROBE"

python3 "$T6_PROBE" >"$SMOKE_TMP_ROOT/t6.out" 2>&1 \
  || smoke_fail "T6: probe failed:
$(cat "$SMOKE_TMP_ROOT/t6.out")"
T6_OUT="$(cat "$SMOKE_TMP_ROOT/t6.out")"
smoke_assert_contains "$T6_OUT" "OK classifier plain-read" \
  "T6: plain read passes the softer classifier"
smoke_assert_contains "$T6_OUT" "OK classifier custom-tool" \
  "T6: a custom (unknown) tool passes the softer classifier"
smoke_assert_contains "$T6_OUT" "OK classifier write-redirect" \
  "T6: write redirection rejected by softer classifier"
smoke_assert_contains "$T6_OUT" "OK classifier tee-write" \
  "T6: tee rejected by softer classifier"
smoke_assert_contains "$T6_OUT" "OK classifier sed-inplace" \
  "T6: sed -i rejected by softer classifier"
smoke_assert_contains "$T6_OUT" "OK gate admin-custom-tool" \
  "T6 gate: admin + custom non-write-intent tool → allowed (#1255 unblock)"
smoke_assert_contains "$T6_OUT" "OK gate admin-redirect-write" \
  "T6 gate: admin + write-redirect → blocked (security boundary preserved)"
smoke_assert_contains "$T6_OUT" "OK gate non-admin-custom-tool" \
  "T6 gate: non-admin + custom non-write-intent tool → STILL blocked (roster secrets)"
smoke_assert_contains "$T6_OUT" "OK gate non-admin-plain-read" \
  "T6 gate: non-admin + plain read still allowed via strict read_intent"
smoke_assert_not_contains "$T6_OUT" "FAIL " \
  "T6: every classifier + gate case must pass"

# T6 teeth: prove the admin-only softening (not the underlying
# read-intent whitelist) is what unblocks the custom-tool repro shape.
smoke_log "T6 teeth: strict read-intent whitelist STILL refuses custom-tool"
T6T_PROBE="$SMOKE_TMP_ROOT/t6-teeth.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import importlib.util, sys\n'
  printf 'spec = importlib.util.spec_from_file_location("tp", "%s")\n' "$TOOL_POLICY_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'cmd = "myprog --opt agent-roster.local.sh"\n'
  printf 'r = m._is_read_intent_bash(cmd)\n'
  printf 's = m._bash_command_has_no_write_intent(cmd)\n'
  printf 'print("read_intent=" + str(r) + " soft_no_write=" + str(s))\n'
  printf 'sys.exit(0 if (r is False and s is True) else 1)\n'
} >"$T6T_PROBE"
T6T_OUT="$(python3 "$T6T_PROBE" 2>&1)" \
  || smoke_fail "T6 teeth: classifier divergence not observed: $T6T_OUT"
smoke_assert_contains "$T6T_OUT" "read_intent=False" \
  "T6 teeth: strict whitelist refuses the custom-tool command"
smoke_assert_contains "$T6T_OUT" "soft_no_write=True" \
  "T6 teeth: softer classifier accepts the same command (issue #1255 unblock seed)"

smoke_log "K-beta4-nits: all 6 tests + teeth passed"
exit 0
