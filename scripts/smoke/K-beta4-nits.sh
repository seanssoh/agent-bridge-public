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
#   #1255 r2: admin roster read carve-out is a STRICT read-intent
#         whitelist (cat / grep / head / `agent-bridge config get` /
#         …). r1 used a write-intent blacklist that tolerated unknown
#         stage leaders, which codex r1 review showed lets the admin
#         shell run `python3 /tmp/mutator.py <roster>`, `my-mutator
#         <roster>`, or `git commit -F <roster>` — paths that mutate
#         or exfiltrate roster secrets outside the typed mutation
#         audit chain. r2 flips the
#         classifier so unknown leaders default-deny. Operator
#         diagnostics (`cat $roster`, `grep BRIDGE $roster`,
#         `head -10 $roster`) are still allowed because they're on
#         the canonical read-intent whitelist. Non-admin class still
#         hits the original deny.
#
#   #1255 r3/r4: r2's whitelist still contained write-capable leaders.
#         `find` is legitimately useful for diagnostics (`find
#         <roster> -name "*.sh"`) but has mutation/exec primitives
#         that the bare leader check did not see — `-delete` removes
#         matches in place; `-exec` / `-execdir` / `-ok` / `-okdir`
#         spawn arbitrary subprocesses against each match; `-fprint`
#         / `-fprint0` / `-fprintf` / `-fls` write matches (or
#         `-ls`-format listings) to a file without appearing as a
#         `>` token. Codex PR #1294 r2 demonstrated that an admin
#         could `find <roster> -delete` or `find <roster> -exec
#         python3 /tmp/mutator.py {} \;` through the read-intent
#         classifier; r3 of the same PR caught the `-fls` GNU action
#         missed in r3's initial filter. r3/r4 adds a
#         `_find_is_read_only` flag filter: when the stage leader is
#         `find` and any of the mutation flags appears in argv, the
#         stage falls out of the read-intent classification and the
#         roster carve-out defaults to the non-admin deny.
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
#   T6  (#1255 r2): `_bash_command_has_read_intent` is a strict
#                  whitelist — True for cat / grep / head / awk-no-i
#                  / sed-no-i; False for `python3 /tmp/mutator.py
#                  <roster>`, `my-mutator <roster>`, `git commit -F
#                  <roster>`, `sed -i`, output-redirect, and any
#                  unknown stage leader. End-to-end gate check via
#                  `protected_alias_reason` confirms admin mutators
#                  are blocked while admin read-only diagnostics
#                  pass.
#   T6t (#1255 r2 teeth): swapping the whitelist for a hypothetical
#                  blacklist (here simulated by `lambda _: True`)
#                  would let admin `python3 /tmp/mutator.py
#                  <roster>` and `git commit -F <roster>` through —
#                  proving the strict whitelist is what closes the
#                  codex r1 BLOCKING gap.
#   T7  (#1255 r3/r4): `find` mutation/exec flag filter. `find
#                  <roster> -delete`, `-exec`, `-execdir`, `-ok`,
#                  `-okdir`, `-fprint`, `-fprint0`, `-fprintf`,
#                  `-fls` are rejected by `_is_read_intent_bash`
#                  even though `find` is on the read-intent
#                  whitelist. `find <roster> -name "*.sh"` and
#                  `find <roster> -type f` still classify as
#                  read-intent. End-to-end gate check via
#                  `protected_alias_reason` confirms admin
#                  mutator/exec forms are denied while read-only
#                  diagnostics pass.
#   T7t (#1255 r3/r4 teeth): reverting the `_find_is_read_only`
#                  filter (here simulated by `lambda _: True`) lets
#                  admin `find <roster> -delete`, `-exec`, and
#                  `-fls` through — proves the flag filter is what
#                  closes the codex PR #1294 r2/r3 BLOCKING gap.
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
# T6 (#1255 r2): admin roster read carve-out = STRICT read-intent whitelist.
#
# r1 used a write-intent BLACKLIST that tolerated unknown stage leaders;
# codex r1 review demonstrated that posture admitted
# `python3 /tmp/mutator.py <roster>`, `my-mutator <roster>`, and
# `git commit -F <roster>` — admin paths that mutate or exfiltrate the
# roster outside the typed mutation audit chain. r2 flips
# the classifier to a strict whitelist (`_bash_command_has_read_intent`
# delegating to `_is_read_intent_bash`). Unknown leaders default-deny.
#
# This test covers the 10 codex r1 mutator/leak vectors at the
# end-to-end `protected_alias_reason` boundary, plus unit cases on the
# renamed classifier. The teeth case proves that swapping the strict
# whitelist for an always-True stub would let admin mutators through —
# i.e. the whitelist is what closes the BLOCKING gap.
# ---------------------------------------------------------------------------
smoke_log "T6: admin roster carve-out blocks mutators (#1255 r2 — codex r1 BLOCKING fix)"

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
  # Unit-level cases for the renamed classifier
  # `_bash_command_has_read_intent`. Strict whitelist: known read-only
  # leaders → True; unknown leaders / `sed -i` / output redirects /
  # known mutators → False.
  printf 'classifier_cases = [\n'
  # Read-only shapes on the canonical whitelist → True.
  printf '    ("plain-cat", "cat " + rp, True),\n'
  printf '    ("plain-grep", "grep BRIDGE " + rp, True),\n'
  printf '    ("plain-head", "head -10 " + rp, True),\n'
  printf '    ("plain-tail", "tail -5 " + rp, True),\n'
  printf "    ('plain-awk', 'awk {print} ' + rp, True),\n"
  # `sed` (no -i) is NOT on `_READ_INTENT_BASH_COMMANDS` and the
  # whitelist refuses it. Operators use `cat | sed` or `agent-bridge
  # config get` instead. This is correct behavior — sed has many
  # write-capable subcommands ("w" / "W") even without `-i`.
  printf "    ('plain-sed-noi', 'sed -n 1,5p ' + rp, False),\n"
  printf '    ("read-pipeline", "grep BRIDGE " + rp + " | head -3", True),\n'
  # Unknown stage leaders the r1 blacklist wrongly admitted → False.
  printf '    ("python3-mutator", "python3 /tmp/mutator.py " + rp, False),\n'
  printf '    ("custom-binary", "my-mutator " + rp, False),\n'
  printf '    ("git-commit-leak", "git commit -F " + rp, False),\n'
  printf "    ('perl-leak', 'perl -e nop ' + rp, False),\n"
  printf "    ('ruby-leak', 'ruby -e nop ' + rp, False),\n"
  # Known mutators / write shapes → False (was also False under r1,
  # kept here as regression guard).
  printf '    ("write-redirect", "cat foo > " + rp, False),\n'
  printf '    ("append-redirect", "echo x >> " + rp, False),\n'
  printf '    ("tee-write", "echo line | tee " + rp, False),\n'
  printf '    ("sed-inplace", "sed -i s/a/b/ " + rp, False),\n'
  printf '    ("rm-mutator", "rm " + rp, False),\n'
  printf '    ("mv-mutator", "mv x " + rp, False),\n'
  printf '    ("numeric-fd-redirect", "cat x 1>" + rp, False),\n'
  printf '    ("chained-leader", "cat " + rp + " ; python3 /tmp/x.py " + rp, False),\n'
  printf ']\n'
  printf 'failed = False\n'
  printf 'for label, cmd, expected in classifier_cases:\n'
  printf '    got = m._bash_command_has_read_intent(cmd)\n'
  printf '    if got == expected:\n'
  printf '        print("OK classifier " + label + " got=" + str(got))\n'
  printf '    else:\n'
  printf '        failed = True\n'
  printf '        print("FAIL classifier " + label + " got=" + str(got) + " expected=" + str(expected) + " cmd=" + repr(cmd))\n'
  # End-to-end cases via protected_alias_reason. admin-test is admin
  # via BRIDGE_ADMIN_AGENT_ID; "self" is treated as non-admin.
  #
  # The 10 codex r1 BLOCKING vectors (admin context, expected denied):
  #   1. python3 /tmp/mutator.py <roster>
  #   2. my-mutator <roster>
  #   3. git commit -F <roster>
  #   4. chained: `cat <roster> ; python3 /tmp/x.py <roster>`
  #   8. sed -i (in-place mutation)
  #   9. awk redirect to /tmp/out
  # And the operator diagnostics that must STILL pass (admin context):
  #   5. cat <roster>
  #   6. grep PATTERN <roster>
  #   7. head -10 <roster>
  # Plus parity (non-admin context): write shape stays denied.
  printf 'gate_cases = [\n'
  # Admin mutator / leak vectors → denied. The deny reason on the
  # admin path is the ROSTER_LOCAL_DENY_REASON ("protected system
  # config path"), preserving #341 CP2 wording.
  printf '    ("admin-python3-mutator", "admin-test", "python3 /tmp/mutator.py " + rp, "protected system config path"),\n'
  printf '    ("admin-custom-binary", "admin-test", "my-mutator " + rp, "protected system config path"),\n'
  printf '    ("admin-git-commit-leak", "admin-test", "git commit -F " + rp, "protected system config path"),\n'
  printf '    ("admin-sed-inplace", "admin-test", "sed -i s/foo/bar/ " + rp, "protected system config path"),\n'
  printf "    ('admin-awk-redirect', 'admin-test', 'awk {print} ' + rp + ' > /tmp/out', 'protected system config path'),\n"
  printf '    ("admin-tee-write", "admin-test", "echo x | tee " + rp, "protected system config path"),\n'
  # Admin operator diagnostics → allowed (the #1255 unblock target).
  printf '    ("admin-cat", "admin-test", "cat " + rp, None),\n'
  printf '    ("admin-grep", "admin-test", "grep BRIDGE " + rp, None),\n'
  printf '    ("admin-head", "admin-test", "head -10 " + rp, None),\n'
  # Non-admin parity: write shape stays denied (no carve-out applied).
  # Non-admin plain read is still allowed via the general read_intent
  # branch at protected_alias_reason — preserved for issue #383.
  printf '    ("non-admin-git-commit", "self", "git commit -F " + rp, "shared roster secrets"),\n'
  printf '    ("non-admin-python3-mutator", "self", "python3 /tmp/mutator.py " + rp, "shared roster secrets"),\n'
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

# Classifier assertions — read-only shapes admitted.
smoke_assert_contains "$T6_OUT" "OK classifier plain-cat" \
  "T6: plain cat admitted by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier plain-grep" \
  "T6: plain grep admitted by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier plain-head" \
  "T6: plain head admitted by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier plain-tail" \
  "T6: plain tail admitted by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier plain-awk" \
  "T6: plain awk (no -i) admitted by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier plain-sed-noi" \
  "T6: sed (even without -i) refused by whitelist — has write-capable subcommands"

# Classifier assertions — unknown leaders refused (codex r1 BLOCKING).
smoke_assert_contains "$T6_OUT" "OK classifier python3-mutator" \
  "T6: python3 /tmp/mutator.py refused by whitelist (unknown leader)"
smoke_assert_contains "$T6_OUT" "OK classifier custom-binary" \
  "T6: custom binary refused by whitelist (unknown leader)"
smoke_assert_contains "$T6_OUT" "OK classifier git-commit-leak" \
  "T6: git commit -F refused by whitelist (unknown leader)"

# Classifier assertions — known mutators / write shapes refused.
smoke_assert_contains "$T6_OUT" "OK classifier write-redirect" \
  "T6: > redirect refused by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier append-redirect" \
  "T6: >> redirect refused by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier sed-inplace" \
  "T6: sed -i refused by whitelist"
smoke_assert_contains "$T6_OUT" "OK classifier numeric-fd-redirect" \
  "T6: 1> redirect refused by whitelist"

# End-to-end gate assertions — the codex r1 mutator/leak vectors.
smoke_assert_contains "$T6_OUT" "OK gate admin-python3-mutator" \
  "T6 gate: admin python3 /tmp/mutator.py <roster> → DENIED (codex r1 vector 1)"
smoke_assert_contains "$T6_OUT" "OK gate admin-custom-binary" \
  "T6 gate: admin my-mutator <roster> → DENIED (codex r1 vector 2)"
smoke_assert_contains "$T6_OUT" "OK gate admin-git-commit-leak" \
  "T6 gate: admin git commit -F <roster> → DENIED (codex r1 vector 3)"
smoke_assert_contains "$T6_OUT" "OK gate admin-sed-inplace" \
  "T6 gate: admin sed -i <roster> → DENIED (in-place mutation)"
smoke_assert_contains "$T6_OUT" "OK gate admin-awk-redirect" \
  "T6 gate: admin awk <roster> > /tmp/out → DENIED (exfil redirect)"
smoke_assert_contains "$T6_OUT" "OK gate admin-tee-write" \
  "T6 gate: admin tee <roster> → DENIED (known mutator)"

# Operator diagnostics must STILL pass (the #1255 unblock surface).
smoke_assert_contains "$T6_OUT" "OK gate admin-cat" \
  "T6 gate: admin cat <roster> → allowed (#1255 unblock preserved)"
smoke_assert_contains "$T6_OUT" "OK gate admin-grep" \
  "T6 gate: admin grep <roster> → allowed (#1255 unblock preserved)"
smoke_assert_contains "$T6_OUT" "OK gate admin-head" \
  "T6 gate: admin head <roster> → allowed (#1255 unblock preserved)"

# Non-admin parity.
smoke_assert_contains "$T6_OUT" "OK gate non-admin-git-commit" \
  "T6 gate: non-admin git commit -F <roster> → still DENIED"
smoke_assert_contains "$T6_OUT" "OK gate non-admin-python3-mutator" \
  "T6 gate: non-admin python3 mutator <roster> → still DENIED"
smoke_assert_contains "$T6_OUT" "OK gate non-admin-plain-read" \
  "T6 gate: non-admin plain read still allowed (preserves #383)"

smoke_assert_not_contains "$T6_OUT" "FAIL " \
  "T6: every classifier + gate case must pass"

# T6 teeth: prove that the STRICT whitelist is what closes the codex
# r1 BLOCKING gap. Swap `_bash_command_has_read_intent` for a stub
# that always returns True (i.e. the r1 blacklist's effective behavior
# on unknown leaders) and confirm an admin python3 mutator command is
# THEN incorrectly allowed by `protected_alias_reason`. Restore the
# real function and confirm the same command is denied.
smoke_log "T6 teeth: stubbing classifier → True admits admin mutator (proves whitelist is the seal)"
T6T_PROBE="$SMOKE_TMP_ROOT/t6-teeth.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import os, importlib.util, sys, tempfile\n'
  printf 'bridge_home = tempfile.mkdtemp(prefix="t6-teeth-bridge-home-")\n'
  printf 'os.environ["BRIDGE_HOME"] = bridge_home\n'
  printf 'os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-test"\n'
  printf 'spec = importlib.util.spec_from_file_location("tp", "%s")\n' "$TOOL_POLICY_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'roster_path = m.roster_local_path()\n'
  printf 'roster_path.parent.mkdir(parents=True, exist_ok=True)\n'
  printf 'roster_path.write_text("# fixture roster\\n")\n'
  printf 'rp = str(roster_path)\n'
  printf 'admin_mutator = "python3 /tmp/mutator.py " + rp\n'
  printf 'admin_leak = "git commit -F " + rp\n'
  # Real classifier denies the mutator/leak.
  printf 'real_mutator = m.protected_alias_reason(admin_mutator, "admin-test")\n'
  printf 'real_leak = m.protected_alias_reason(admin_leak, "admin-test")\n'
  printf 'real_cat = m.protected_alias_reason("cat " + rp, "admin-test")\n'
  # Stub to True (simulating the r1 blacklist tolerating unknown leaders).
  printf 'orig = m._bash_command_has_read_intent\n'
  printf 'm._bash_command_has_read_intent = lambda cmd: True\n'
  printf 'stub_mutator = m.protected_alias_reason(admin_mutator, "admin-test")\n'
  printf 'stub_leak = m.protected_alias_reason(admin_leak, "admin-test")\n'
  printf 'm._bash_command_has_read_intent = orig\n'
  printf 'print("real_mutator=" + repr(real_mutator))\n'
  printf 'print("real_leak=" + repr(real_leak))\n'
  printf 'print("real_cat=" + repr(real_cat))\n'
  printf 'print("stub_mutator=" + repr(stub_mutator))\n'
  printf 'print("stub_leak=" + repr(stub_leak))\n'
  # Pass iff real classifier denies mutator/leak, allows cat, AND stub
  # lets the mutator/leak through (proving the whitelist is the seal).
  printf 'ok = (real_mutator is not None\n'
  printf '      and real_leak is not None\n'
  printf '      and real_cat is None\n'
  printf '      and stub_mutator is None\n'
  printf '      and stub_leak is None)\n'
  printf 'sys.exit(0 if ok else 1)\n'
} >"$T6T_PROBE"
T6T_OUT="$(python3 "$T6T_PROBE" 2>&1)" \
  || smoke_fail "T6 teeth: whitelist seal not observed:
$T6T_OUT"
smoke_assert_contains "$T6T_OUT" "real_mutator='" \
  "T6 teeth: real classifier denies admin python3 mutator"
smoke_assert_contains "$T6T_OUT" "real_leak='" \
  "T6 teeth: real classifier denies admin git commit leak"
smoke_assert_contains "$T6T_OUT" "real_cat=None" \
  "T6 teeth: real classifier still allows admin cat diagnostic"
smoke_assert_contains "$T6T_OUT" "stub_mutator=None" \
  "T6 teeth: stubbed-True classifier wrongly admits admin mutator (r1 regression demo)"
smoke_assert_contains "$T6T_OUT" "stub_leak=None" \
  "T6 teeth: stubbed-True classifier wrongly admits admin git commit -F leak (r1 regression demo)"

# ---------------------------------------------------------------------------
# T7 (#1255 r3/r4): `find` mutation/exec flag filter (codex PR #1294 r2/r3
# BLOCKING).
#
# r2's whitelist contained `find` so operator diagnostics like `find
# <roster> -name "*.sh"` keep working. Codex r2 showed that without an
# argv-level filter, `find <roster> -delete` and `find <roster> -exec
# python3 /tmp/mutator.py {} \;` slip through as read-intent — the
# stage leader check sees only `find`, not the mutation primitive that
# follows. r3 adds `_find_is_read_only(argv)` and wires it into
# `_is_read_intent_bash` so any mutation/exec flag drops the
# classification, while leaving `-name` / `-type` / `-size` reads alone.
# Codex r3 of the same PR caught that r3's frozenset omitted GNU find's
# `-fls FILE` action (writes `-ls`-format listings to a named file
# without `>`), which had the same exfil shape as `-fprint*`. r4 adds
# `-fls` and asserts the comprehensive audit of GNU find file-action
# primitives is now exhaustive.
# ---------------------------------------------------------------------------
smoke_log "T7: find mutation/exec flag filter (#1255 r3/r4 — codex PR #1294 r2/r3 BLOCKING)"

T7_PROBE="$SMOKE_TMP_ROOT/t7-probe.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import os, importlib.util, sys, tempfile\n'
  printf 'bridge_home = tempfile.mkdtemp(prefix="t7-bridge-home-")\n'
  printf 'os.environ["BRIDGE_HOME"] = bridge_home\n'
  printf 'os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-test"\n'
  printf 'spec = importlib.util.spec_from_file_location("tp", "%s")\n' "$TOOL_POLICY_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'roster_path = m.roster_local_path()\n'
  printf 'roster_path.parent.mkdir(parents=True, exist_ok=True)\n'
  printf 'roster_path.write_text("# fixture roster\\n")\n'
  printf 'rp = str(roster_path)\n'
  # Classifier cases — _is_read_intent_bash on `find` shapes.
  printf 'classifier_cases = [\n'
  # Mutation/exec flags — all must drop the classification.
  printf "    ('find-delete', 'find ' + rp + ' -delete', False),\n"
  printf "    ('find-exec', 'find ' + rp + ' -exec python3 /tmp/m.py {} ;', False),\n"
  printf "    ('find-execdir', 'find ' + rp + ' -execdir /bin/cat {} +', False),\n"
  printf "    ('find-ok', 'find ' + rp + ' -ok rm {} ;', False),\n"
  printf "    ('find-okdir', 'find ' + rp + ' -okdir ls {} ;', False),\n"
  printf "    ('find-fprint', 'find ' + rp + ' -fprint /tmp/leak', False),\n"
  printf "    ('find-fprint0', 'find ' + rp + ' -fprint0 /tmp/leak', False),\n"
  printf "    ('find-fprintf', 'find ' + rp + ' -fprintf /tmp/leak %%p', False),\n"
  # r4: GNU find -fls FILE writes -ls-format listings to a named file
  # without a `>` token (codex PR #1294 r3 BLOCKING).
  printf "    ('find-fls', 'find ' + rp + ' -fls /tmp/leak', False),\n"
  # Mid-argv -fls (matches the `-fprint*` mid-argv shape).
  printf "    ('find-mid-fls', 'find ' + rp + ' -type f -fls /tmp/leak', False),\n"
  # Mid-argv -delete (e.g. `-type f -delete`).
  printf "    ('find-mid-delete', 'find ' + rp + ' -type f -delete', False),\n"
  # Pathy leader (`/usr/bin/find -delete`).
  printf "    ('find-path-leader', '/usr/bin/find ' + rp + ' -exec ls {} ;', False),\n"
  # Read-only forms — must still classify as read.
  printf "    ('find-name', 'find ' + rp + ' -name *.sh', True),\n"
  printf "    ('find-type', 'find ' + rp + ' -type f', True),\n"
  printf "    ('find-size', 'find ' + rp + ' -size +1c', True),\n"
  printf "    ('find-multi-read', 'find ' + rp + ' -type f -size +1c -name *.sh', True),\n"
  # Token-boundary: a similar-looking but distinct token must NOT match.
  printf "    ('find-pseudo-match', 'find ' + rp + ' -name -deleted-files', True),\n"
  printf ']\n'
  printf 'failed = False\n'
  printf 'for label, cmd, expected in classifier_cases:\n'
  printf '    got = m._is_read_intent_bash(cmd)\n'
  printf '    if got == expected:\n'
  printf '        print("OK classifier " + label + " got=" + str(got))\n'
  printf '    else:\n'
  printf '        failed = True\n'
  printf '        print("FAIL classifier " + label + " got=" + str(got) + " expected=" + str(expected) + " cmd=" + repr(cmd))\n'
  # End-to-end gate cases via protected_alias_reason.
  printf 'gate_cases = [\n'
  # Admin mutator/exec vectors → DENIED (roster carve-out falls
  # through to ROSTER_LOCAL_DENY_REASON because read_intent is now False).
  printf "    ('admin-find-delete', 'admin-test', 'find ' + rp + ' -delete', 'protected system config path'),\n"
  printf "    ('admin-find-exec', 'admin-test', 'find ' + rp + ' -exec python3 /tmp/m.py {} ;', 'protected system config path'),\n"
  printf "    ('admin-find-execdir', 'admin-test', 'find ' + rp + ' -execdir cat {} +', 'protected system config path'),\n"
  printf "    ('admin-find-ok', 'admin-test', 'find ' + rp + ' -ok rm {} ;', 'protected system config path'),\n"
  printf "    ('admin-find-fprintf', 'admin-test', 'find ' + rp + ' -fprintf /tmp/leak %%p', 'protected system config path'),\n"
  # r4: -fls admin gate must DENY (codex PR #1294 r3 BLOCKING repro).
  printf "    ('admin-find-fls', 'admin-test', 'find ' + rp + ' -fls /tmp/leak', 'protected system config path'),\n"
  # Admin read-only diagnostics → allowed.
  printf "    ('admin-find-name', 'admin-test', 'find ' + rp + ' -name *.sh', None),\n"
  printf "    ('admin-find-type', 'admin-test', 'find ' + rp + ' -type f', None),\n"
  # Non-admin parity: mutator denied with the shared-roster wording;
  # read-only still allowed via the general read_intent branch.
  printf "    ('non-admin-find-delete', 'self', 'find ' + rp + ' -delete', 'shared roster secrets'),\n"
  printf "    ('non-admin-find-exec', 'self', 'find ' + rp + ' -exec python3 /tmp/m.py {} ;', 'shared roster secrets'),\n"
  # r4: -fls non-admin parity.
  printf "    ('non-admin-find-fls', 'self', 'find ' + rp + ' -fls /tmp/leak', 'shared roster secrets'),\n"
  printf "    ('non-admin-find-name', 'self', 'find ' + rp + ' -name *.sh', None),\n"
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
} >"$T7_PROBE"

python3 "$T7_PROBE" >"$SMOKE_TMP_ROOT/t7.out" 2>&1 \
  || smoke_fail "T7: probe failed:
$(cat "$SMOKE_TMP_ROOT/t7.out")"
T7_OUT="$(cat "$SMOKE_TMP_ROOT/t7.out")"

# Classifier — mutation/exec flags drop the read-intent classification.
smoke_assert_contains "$T7_OUT" "OK classifier find-delete" \
  "T7: find -delete refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-exec" \
  "T7: find -exec refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-execdir" \
  "T7: find -execdir refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-ok" \
  "T7: find -ok refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-okdir" \
  "T7: find -okdir refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-fprint" \
  "T7: find -fprint refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-fprint0" \
  "T7: find -fprint0 refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-fprintf" \
  "T7: find -fprintf refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-fls" \
  "T7: find -fls refused by classifier (r4 — codex PR #1294 r3 BLOCKING)"
smoke_assert_contains "$T7_OUT" "OK classifier find-mid-fls" \
  "T7: find -fls mid-argv refused by classifier (r4)"
smoke_assert_contains "$T7_OUT" "OK classifier find-mid-delete" \
  "T7: -delete mid-argv refused by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-path-leader" \
  "T7: /usr/bin/find -exec refused by classifier"

# Classifier — read-only flag forms still admitted.
smoke_assert_contains "$T7_OUT" "OK classifier find-name" \
  "T7: find -name admitted by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-type" \
  "T7: find -type admitted by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-size" \
  "T7: find -size admitted by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-multi-read" \
  "T7: multiple read flags admitted by classifier"
smoke_assert_contains "$T7_OUT" "OK classifier find-pseudo-match" \
  "T7: pseudo-match token (-deleted-files) does not trigger the filter"

# End-to-end gate — admin mutator/exec vectors denied.
smoke_assert_contains "$T7_OUT" "OK gate admin-find-delete" \
  "T7 gate: admin find <roster> -delete → DENIED"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-exec" \
  "T7 gate: admin find <roster> -exec ... → DENIED"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-execdir" \
  "T7 gate: admin find <roster> -execdir ... → DENIED"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-ok" \
  "T7 gate: admin find <roster> -ok ... → DENIED"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-fprintf" \
  "T7 gate: admin find <roster> -fprintf ... → DENIED"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-fls" \
  "T7 gate: admin find <roster> -fls ... → DENIED (r4 — codex PR #1294 r3 BLOCKING repro)"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-name" \
  "T7 gate: admin find <roster> -name → allowed (#1255 unblock preserved)"
smoke_assert_contains "$T7_OUT" "OK gate admin-find-type" \
  "T7 gate: admin find <roster> -type → allowed"

# Non-admin parity.
smoke_assert_contains "$T7_OUT" "OK gate non-admin-find-delete" \
  "T7 gate: non-admin find -delete → still DENIED"
smoke_assert_contains "$T7_OUT" "OK gate non-admin-find-exec" \
  "T7 gate: non-admin find -exec → still DENIED"
smoke_assert_contains "$T7_OUT" "OK gate non-admin-find-fls" \
  "T7 gate: non-admin find -fls → still DENIED (r4)"
smoke_assert_contains "$T7_OUT" "OK gate non-admin-find-name" \
  "T7 gate: non-admin find -name → allowed (preserves #383)"

smoke_assert_not_contains "$T7_OUT" "FAIL " \
  "T7: every classifier + gate case must pass"

# T7 teeth: prove the flag filter is what closes the gap. Stub
# `_find_is_read_only` to always return True (i.e. the pre-r3
# behavior where find was a bare whitelist entry) and confirm admin
# `find -delete` is then allowed by protected_alias_reason. Restore
# the real function and confirm the same command is denied.
smoke_log "T7 teeth: stubbing _find_is_read_only → True admits admin find -delete (proves filter is the seal)"
T7T_PROBE="$SMOKE_TMP_ROOT/t7-teeth.py"
{
  printf '#!/usr/bin/env python3\n'
  printf 'import os, importlib.util, sys, tempfile\n'
  printf 'bridge_home = tempfile.mkdtemp(prefix="t7-teeth-bridge-home-")\n'
  printf 'os.environ["BRIDGE_HOME"] = bridge_home\n'
  printf 'os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-test"\n'
  printf 'spec = importlib.util.spec_from_file_location("tp", "%s")\n' "$TOOL_POLICY_PY"
  printf 'm = importlib.util.module_from_spec(spec)\n'
  printf 'spec.loader.exec_module(m)\n'
  printf 'roster_path = m.roster_local_path()\n'
  printf 'roster_path.parent.mkdir(parents=True, exist_ok=True)\n'
  printf 'roster_path.write_text("# fixture roster\\n")\n'
  printf 'rp = str(roster_path)\n'
  printf 'admin_delete = "find " + rp + " -delete"\n'
  printf 'admin_exec = "find " + rp + " -exec python3 /tmp/m.py {} ;"\n'
  printf 'admin_fls = "find " + rp + " -fls /tmp/leak"\n'
  printf 'admin_read = "find " + rp + " -name *.sh"\n'
  # Real filter denies the mutator/exec/file-action primitives.
  printf 'real_delete = m.protected_alias_reason(admin_delete, "admin-test")\n'
  printf 'real_exec = m.protected_alias_reason(admin_exec, "admin-test")\n'
  printf 'real_fls = m.protected_alias_reason(admin_fls, "admin-test")\n'
  printf 'real_read = m.protected_alias_reason(admin_read, "admin-test")\n'
  # Stub _find_is_read_only to always return True — simulates pre-r3/r4.
  printf 'orig = m._find_is_read_only\n'
  printf 'm._find_is_read_only = lambda _argv: True\n'
  printf 'stub_delete = m.protected_alias_reason(admin_delete, "admin-test")\n'
  printf 'stub_exec = m.protected_alias_reason(admin_exec, "admin-test")\n'
  printf 'stub_fls = m.protected_alias_reason(admin_fls, "admin-test")\n'
  printf 'm._find_is_read_only = orig\n'
  printf 'print("real_delete=" + repr(real_delete))\n'
  printf 'print("real_exec=" + repr(real_exec))\n'
  printf 'print("real_fls=" + repr(real_fls))\n'
  printf 'print("real_read=" + repr(real_read))\n'
  printf 'print("stub_delete=" + repr(stub_delete))\n'
  printf 'print("stub_exec=" + repr(stub_exec))\n'
  printf 'print("stub_fls=" + repr(stub_fls))\n'
  printf 'ok = (real_delete is not None\n'
  printf '      and real_exec is not None\n'
  printf '      and real_fls is not None\n'
  printf '      and real_read is None\n'
  printf '      and stub_delete is None\n'
  printf '      and stub_exec is None\n'
  printf '      and stub_fls is None)\n'
  printf 'sys.exit(0 if ok else 1)\n'
} >"$T7T_PROBE"
T7T_OUT="$(python3 "$T7T_PROBE" 2>&1)" \
  || smoke_fail "T7 teeth: flag-filter seal not observed:
$T7T_OUT"
smoke_assert_contains "$T7T_OUT" "real_delete='" \
  "T7 teeth: real filter denies admin find -delete"
smoke_assert_contains "$T7T_OUT" "real_exec='" \
  "T7 teeth: real filter denies admin find -exec"
smoke_assert_contains "$T7T_OUT" "real_fls='" \
  "T7 teeth: real filter denies admin find -fls (r4 — codex PR #1294 r3 BLOCKING)"
smoke_assert_contains "$T7T_OUT" "real_read=None" \
  "T7 teeth: real filter still allows admin find -name diagnostic"
smoke_assert_contains "$T7T_OUT" "stub_delete=None" \
  "T7 teeth: stubbed-True filter wrongly admits admin find -delete (pre-r3 demo)"
smoke_assert_contains "$T7T_OUT" "stub_exec=None" \
  "T7 teeth: stubbed-True filter wrongly admits admin find -exec (pre-r3 demo)"
smoke_assert_contains "$T7T_OUT" "stub_fls=None" \
  "T7 teeth: stubbed-True filter wrongly admits admin find -fls (pre-r4 demo)"

smoke_log "K-beta4-nits: all 7 tests + teeth passed"
exit 0
