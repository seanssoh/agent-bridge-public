#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1427-B-template-sync-wizard.sh — Issue #1427 Lane B.
#
# Pins the `agent-bridge setup template-sync` wizard contract: a two-stage
# (bash Stage-1 + python Stage-2) helper that seeds new (and optionally
# existing) agents from a reference agent's ROSTER-resident config, with a
# hard security boundary (declarations only, never credentials) and a
# never-inherit rule for permission_mode=legacy.
#
# This smoke exercises the Stage-2 python wizard (`bridge-setup.py
# template-sync`) directly for the candidate/diff/redaction/profile-write
# assertions, the Stage-1 bash required-fields validator
# (`bridge_setup_wizard_validate_auto template-sync`) for the auto-mode
# fail-loud contract. T1-T8 STUB the Contract-II materialize writer for the
# --targets backfill call (unit-level), but the profile write is routed
# through the REAL gated `roster write-template-profile` verb. T9-T11 then
# drive a fully NON-STUBBED end-to-end pass against the live smoke roster:
# the real Contract-II materialize verb mutates a real target's fields, the
# gate denies a non-operator caller, and a backfill writer failure
# propagates to a non-zero wizard exit.
#
# Tests:
#   T1 (dry-run):  --dry-run from a fixture roster writes NOTHING and emits
#                  a deterministic candidate + before/after diff.
#   T2 (redact):   secret-shaped reference values (a token-shaped channel
#                  account, a client-secret-looking string) never appear on
#                  stdout, stderr, or in the written profile. The wizard is
#                  roster-only; it never opens a channel secret file.
#   T3 (legacy):   reference permission_mode=legacy is surfaced as
#                  refused/omitted (never written, warned).
#   T4 (validate): `bridge_setup_wizard_validate_auto template-sync` with
#                  --yes but no --from dies with a structured "missing"
#                  message and non-zero exit.
#   T5 (noref):    a reference with NO roster dimensions yields a partial
#                  candidate marking list dims "unset / reference missing"
#                  (never guessed); model/effort fall back to bridge
#                  defaults labelled `bridge-default`.
#   T6 (profile):  the written profile is the Contract-I block with correct
#                  delimiters + metadata (source_agent / updated_at /
#                  included / excluded / hash) and is sourceable bash.
#   T7 (contractII): --targets invokes the Contract-II writer (stubbed) with
#                  the expected --model/--effort/--plugins/... argv and the
#                  backfill result reports restart_required.
#   T8 (idempotent): re-running splices the block in place (exactly one
#                  block) rather than appending a duplicate.
#   T9 (e2e write):  the REAL Contract-II materialize verb backfills a real
#                  target agent — explicit model/effort land in its roster
#                  block; the gated profile block also lands in the live
#                  roster.
#   T10 (gate):    the gated `roster write-template-profile` verb DENIES a
#                  non-operator (agent-direct) caller and leaves the roster
#                  untouched.
#   T11 (fail):    a backfill writer failure (unknown target agent) makes
#                  `setup template-sync` exit non-zero (write_status=
#                  backfill_error) instead of swallowing the failure.
#
# Footgun #11: no `<<EOF` / `<<'PY'` to subprocess; python is driven via
# `python3 -c '<script>' <argv>` or by reading roster files written with
# plain redirects. Captured subprocesses use `out=$(... 2>&1)` or split
# stdout/stderr into temp files.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1427-B-template-sync-wizard][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="1427-B-template-sync-wizard"
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
SETUP_PY="$REPO_ROOT/bridge-setup.py"
WIZARD_LIB="$REPO_ROOT/lib/bridge-setup-wizard.sh"
CORE_LIB="$REPO_ROOT/lib/bridge-core.sh"

smoke_assert_file_exists "$SETUP_PY" "bridge-setup.py present"
smoke_assert_file_exists "$WIZARD_LIB" "lib/bridge-setup-wizard.sh present"

# A token-shaped secret string that MUST NOT survive into any output —
# even if a future reference declared it in a channel value. The wizard
# only ever sees declarations passed on argv, so this is the worst case.
SECRET_CANARY="SK-DEADBEEFc0ffee0123456789abcdefSECRET"

# Stub for Lane A's Contract-II writer. Records its argv to a file and
# emits a JSON ack so the python backfill path can be exercised at the unit
# level without the real `agent-bridge agent roster materialize-fields` verb
# (the real verb is exercised non-stubbed in the T9-T11 e2e cases below).
MATERIALIZE_LOG="$SMOKE_TMP_ROOT/materialize-calls.log"
MATERIALIZE_STUB="$SMOKE_TMP_ROOT/materialize-stub.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -u\n'
  printf 'printf "%%s\\n" "$*" >> %q\n' "$MATERIALIZE_LOG"
  printf 'printf "{\\"status\\":\\"stubbed-ok\\"}\\n"\n'
} >"$MATERIALIZE_STUB"
chmod +x "$MATERIALIZE_STUB"

# Helper: run the python wizard. Splits stdout/stderr so redaction
# assertions can check both streams independently. The non-dry-run profile
# write is routed through the REAL gated `roster write-template-profile`
# verb (BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD points at bridge-agent.sh)
# with an operator-trusted caller source so the gate admits the write —
# this exercises the gated+audited path end-to-end rather than a stub.
TS_STDOUT="$SMOKE_TMP_ROOT/ts.out"
TS_STDERR="$SMOKE_TMP_ROOT/ts.err"
# bridge-agent.sh dispatches `roster` as its own $1 (the `agent` prefix is
# added only by the top-level `agent-bridge` wrapper, which execs
# `bridge-agent.sh roster …`). Calling the dispatcher directly skips that
# prefix.
PROFILE_WRITER_CMD="bash $SMOKE_REPO_ROOT/bridge-agent.sh roster write-template-profile"
run_ts() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD="$PROFILE_WRITER_CMD" \
    python3 "$SETUP_PY" template-sync "$@" >"$TS_STDOUT" 2>"$TS_STDERR"
}

# ---------------------------------------------------------------------------
# T1 — --dry-run writes nothing + deterministic candidate/diff.
# ---------------------------------------------------------------------------
ROSTER_T1="$SMOKE_TMP_ROOT/roster-t1.sh"
rm -f "$ROSTER_T1"
run_ts --from patch --roster-file "$ROSTER_T1" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-effort xhigh \
  --ref-plugins "cosmax-crm@cosmax playwright@official" \
  --ref-skills "agent-db memory-wiki" \
  --ref-channels "plugin:teams@mkt plugin:ms365" \
  --yes --dry-run
rc=$?
smoke_assert_eq "$rc" "0" "T1: dry-run exits 0"
[[ ! -e "$ROSTER_T1" ]] || smoke_fail "T1: --dry-run must NOT create the roster file ($ROSTER_T1 exists)"

t1_out="$(cat "$TS_STDOUT")"
smoke_assert_contains "$t1_out" '"write_status": "dry_run"' "T1: write_status=dry_run"
smoke_assert_contains "$t1_out" '"candidate_hash"' "T1: emits a candidate hash"
# Determinism: token order normalized — plugins sorted, de-duped.
smoke_assert_contains "$t1_out" 'BRIDGE_TEMPLATE_DEFAULT_PLUGINS=\"cosmax-crm@cosmax playwright@official\"' \
  "T1: plugins normalized in profile"
# Run again — the candidate_hash must be identical for the same input.
hash1="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_hash"])' <"$TS_STDOUT")"
run_ts --from patch --roster-file "$ROSTER_T1" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-effort xhigh \
  --ref-plugins "playwright@official cosmax-crm@cosmax" \
  --ref-skills "memory-wiki agent-db" \
  --ref-channels "plugin:ms365 plugin:teams@mkt" \
  --yes --dry-run
hash2="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate_hash"])' <"$TS_STDOUT")"
smoke_assert_eq "$hash1" "$hash2" "T1: candidate hash deterministic under token reorder"

# ---------------------------------------------------------------------------
# T2 — secret-shaped fixtures never leak (stdout / stderr / profile).
# ---------------------------------------------------------------------------
ROSTER_T2="$SMOKE_TMP_ROOT/roster-t2.sh"
rm -f "$ROSTER_T2"
# Seed the canary into EVERY secret-shaped file a leaky implementation might
# probe for the reference's channels: a `.teams/.env`, a `.ms365/.env`, a
# `.teams/access.json`, and a `.claude/.mcp.json`. The wizard is roster-only
# by contract, so it must never open ANY of these. We make them mode 000 so
# that if a naive future patch DID try to read one, the wizard would die or
# warn (proving the read) instead of silently succeeding.
SECRET_TREE="$SMOKE_TMP_ROOT/ref-home"
mkdir -p "$SECRET_TREE/.teams" "$SECRET_TREE/.ms365" "$SECRET_TREE/.claude"
printf 'TEAMS_APP_PASSWORD=%s\n' "$SECRET_CANARY" >"$SECRET_TREE/.teams/.env"
printf 'MS365_CLIENT_SECRET=%s\n' "$SECRET_CANARY" >"$SECRET_TREE/.ms365/.env"
printf '{"appPassword":"%s"}\n' "$SECRET_CANARY" >"$SECRET_TREE/.teams/access.json"
printf '{"mcpServers":{"x":{"env":{"TOKEN":"%s"}}}}\n' "$SECRET_CANARY" >"$SECRET_TREE/.claude/.mcp.json"
chmod 000 "$SECRET_TREE/.teams/.env" "$SECRET_TREE/.ms365/.env" \
  "$SECRET_TREE/.teams/access.json" "$SECRET_TREE/.claude/.mcp.json"
# HOME points at the secret tree so a `$HOME/.claude` introspection (which the
# contract FORBIDS) would land here and fail on the 000-mode files.
HOME="$SECRET_TREE" run_ts --from patch --roster-file "$ROSTER_T2" --ref-engine claude \
  --ref-model claude-opus-4-8 \
  --ref-channels "plugin:teams@mkt plugin:ms365" \
  --yes
rc=$?
chmod 600 "$SECRET_TREE/.teams/.env" "$SECRET_TREE/.ms365/.env" \
  "$SECRET_TREE/.teams/access.json" "$SECRET_TREE/.claude/.mcp.json" 2>/dev/null || true
smoke_assert_eq "$rc" "0" "T2: roster-only read succeeds without touching the secret tree"
out_all="$(cat "$TS_STDOUT" "$TS_STDERR")"
smoke_assert_not_contains "$out_all" "$SECRET_CANARY" "T2: secret canary never on stdout/stderr"
profile_t2="$(cat "$ROSTER_T2")"
smoke_assert_not_contains "$profile_t2" "$SECRET_CANARY" "T2: secret canary never in written profile"
# The channel DECLARATIONS (no creds) are what gets copied.
smoke_assert_contains "$profile_t2" 'BRIDGE_TEMPLATE_DEFAULT_CHANNELS="plugin:ms365 plugin:teams@mkt"' \
  "T2: channel declarations copied (declarations only)"
# Per-channel setup-pending next-action surfaced.
smoke_assert_contains "$(cat "$TS_STDOUT")" 'agb setup teams' "T2: teams setup-pending next-action"

# ---------------------------------------------------------------------------
# T3 — reference permission_mode=legacy refused / omitted / warned.
# ---------------------------------------------------------------------------
ROSTER_T3="$SMOKE_TMP_ROOT/roster-t3.sh"
rm -f "$ROSTER_T3"
run_ts --from patch --roster-file "$ROSTER_T3" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-permission-mode legacy \
  --yes
rc=$?
smoke_assert_eq "$rc" "0" "T3: legacy reference still exits 0"
profile_t3="$(cat "$ROSTER_T3")"
smoke_assert_not_contains "$profile_t3" "BRIDGE_TEMPLATE_DEFAULT_PERMISSION_MODE" \
  "T3: legacy permission_mode never written to profile"
smoke_assert_contains "$profile_t3" "permission_mode intentionally omitted" \
  "T3: profile documents the legacy omission"
smoke_assert_contains "$(cat "$TS_STDERR")" "legacy" "T3: legacy refusal warned on stderr"

# ---------------------------------------------------------------------------
# T4 — bash validate_auto: --yes but missing --from dies structured.
# ---------------------------------------------------------------------------
# Drive the bash Stage-1 validator directly via a python3-free bash -c so we
# do not depend on the full bridge-setup.sh dispatch / roster sourcing.
VALIDATE_DRIVER="$SMOKE_TMP_ROOT/validate-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'bridge_die() { printf "%%s\\n" "$*" >&2; exit 3; }\n'
  printf 'bridge_warn() { printf "%%s\\n" "$*" >&2; }\n'
  printf 'bridge_info() { printf "%%s\\n" "$*"; }\n'
  printf 'source %q\n' "$WIZARD_LIB"
  printf 'bridge_setup_wizard_validate_auto template-sync template-sync --roster-file /tmp/x --yes\n'
} >"$VALIDATE_DRIVER"
val_out="$("$BASH" "$VALIDATE_DRIVER" 2>&1)"
val_rc=$?
smoke_assert_eq "$val_rc" "3" "T4: validate_auto dies (rc=3) when --from missing"
smoke_assert_contains "$val_out" "--from" "T4: structured die names the missing --from flag"

# Positive case: --from present → validator passes (rc 0).
VALIDATE_OK="$SMOKE_TMP_ROOT/validate-ok.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'bridge_die() { printf "%%s\\n" "$*" >&2; exit 3; }\n'
  printf 'bridge_warn() { printf "%%s\\n" "$*" >&2; }\n'
  printf 'bridge_info() { printf "%%s\\n" "$*"; }\n'
  printf 'source %q\n' "$WIZARD_LIB"
  printf 'bridge_setup_wizard_validate_auto template-sync template-sync --from patch --roster-file /tmp/x --yes\n'
  printf 'echo VALIDATE_OK\n'
} >"$VALIDATE_OK"
val_ok_out="$("$BASH" "$VALIDATE_OK" 2>&1)"
smoke_assert_contains "$val_ok_out" "VALIDATE_OK" "T4: validate_auto passes when --from present"

# ---------------------------------------------------------------------------
# T5 — no-reference-config reference → partial candidate, never guessed.
# ---------------------------------------------------------------------------
ROSTER_T5="$SMOKE_TMP_ROOT/roster-t5.sh"
rm -f "$ROSTER_T5"
# No --ref-* flags at all == reference declared none of the dimensions.
run_ts --from emptyref --roster-file "$ROSTER_T5" --ref-engine claude --yes --dry-run
rc=$?
smoke_assert_eq "$rc" "0" "T5: no-reference dry-run exits 0"
t5_out="$(cat "$TS_STDOUT")"
plugins_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate"]["plugins"]["status"])' <"$TS_STDOUT")"
smoke_assert_eq "$plugins_status" "unset / reference missing" "T5: missing plugins -> unset/reference missing (not guessed)"
model_source="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate"]["model"]["source"])' <"$TS_STDOUT")"
smoke_assert_eq "$model_source" "bridge-default" "T5: missing model -> labelled bridge-default (not reference)"
# A guessed value would surface plugins in the included set; it must not.
smoke_assert_not_contains "$t5_out" '"included_dimensions": [\n    "model",\n    "effort",\n    "permission_mode"' \
  "T5: no fabricated permission_mode in included set"

# ---------------------------------------------------------------------------
# T6 — profile-write produces the Contract-I block with correct metadata.
# ---------------------------------------------------------------------------
ROSTER_T6="$SMOKE_TMP_ROOT/roster-t6.sh"
rm -f "$ROSTER_T6"
run_ts --from patch --roster-file "$ROSTER_T6" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-effort xhigh \
  --ref-plugins "cosmax-crm@cosmax" --ref-skills "agent-db" \
  --ref-channels "plugin:teams@mkt" \
  --yes
rc=$?
smoke_assert_eq "$rc" "0" "T6: profile write exits 0"
profile_t6="$(cat "$ROSTER_T6")"
smoke_assert_contains "$profile_t6" '# === agb:template-defaults v1 (managed by `setup template-sync`) ===' \
  "T6: begin marker present"
smoke_assert_contains "$profile_t6" '# === end agb:template-defaults ===' "T6: end marker present"
smoke_assert_contains "$profile_t6" 'source_agent=patch' "T6: meta carries source_agent"
smoke_assert_contains "$profile_t6" 'included=model,effort,plugins,skills,channels' "T6: meta carries included dims"
smoke_assert_match "$profile_t6" 'hash=[0-9a-f]{16}' "T6: meta carries a 16-hex candidate hash"
smoke_assert_match "$profile_t6" 'updated_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
  "T6: meta carries an ISO-8601 updated_at"
# The block must be sourceable bash and yield the expected scalar values.
SOURCE_PROBE="$SMOKE_TMP_ROOT/source-probe.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -u\n'
  printf 'source %q\n' "$ROSTER_T6"
  printf 'printf "%%s|%%s|%%s\\n" "${BRIDGE_TEMPLATE_DEFAULT_MODEL:-}" "${BRIDGE_TEMPLATE_DEFAULT_PLUGINS:-}" "${BRIDGE_TEMPLATE_DEFAULT_PERMISSION_MODE:-NONE}"\n'
} >"$SOURCE_PROBE"
probe_out="$("$BASH" "$SOURCE_PROBE" 2>&1)"
smoke_assert_eq "$probe_out" "claude-opus-4-8|cosmax-crm@cosmax|NONE" \
  "T6: profile sources to the expected values (no permission_mode var)"

# ---------------------------------------------------------------------------
# T7 — --targets calls Contract-II writer (stubbed) with the right argv.
# ---------------------------------------------------------------------------
ROSTER_T7="$SMOKE_TMP_ROOT/roster-t7.sh"
rm -f "$ROSTER_T7" "$MATERIALIZE_LOG"
BRIDGE_TEMPLATE_SYNC_MATERIALIZE_CMD="$MATERIALIZE_STUB" \
  run_ts --from patch --roster-file "$ROSTER_T7" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-effort xhigh \
  --ref-plugins "cosmax-crm@cosmax" \
  --targets "alice,bob" --yes
rc=$?
smoke_assert_eq "$rc" "0" "T7: --targets backfill exits 0"
[[ -f "$MATERIALIZE_LOG" ]] || smoke_fail "T7: Contract-II writer was never invoked"
mat_calls="$(cat "$MATERIALIZE_LOG")"
smoke_assert_contains "$mat_calls" "alice --model claude-opus-4-8" "T7: writer called for alice with --model"
smoke_assert_contains "$mat_calls" "bob --model claude-opus-4-8" "T7: writer called for bob"
smoke_assert_contains "$mat_calls" "--plugins cosmax-crm@cosmax" "T7: writer receives --plugins"
smoke_assert_contains "$mat_calls" "--json" "T7: writer invoked with --json"
backfill_restart="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["backfill"][0]["restart_required"])' <"$TS_STDOUT")"
smoke_assert_eq "$backfill_restart" "True" "T7: backfill reports restart_required for runtime-affecting dims"

# ---------------------------------------------------------------------------
# T8 — idempotent splice: re-run replaces the block in place.
# ---------------------------------------------------------------------------
ROSTER_T8="$SMOKE_TMP_ROOT/roster-t8.sh"
rm -f "$ROSTER_T8"
run_ts --from patch --roster-file "$ROSTER_T8" --ref-engine claude --ref-model claude-opus-4-7 --yes
run_ts --from patch --roster-file "$ROSTER_T8" --ref-engine claude --ref-model claude-opus-4-8 --yes
begin_count="$(grep -c 'agb:template-defaults v1' "$ROSTER_T8")"
end_count="$(grep -c 'end agb:template-defaults' "$ROSTER_T8")"
smoke_assert_eq "$begin_count" "1" "T8: exactly one begin marker after re-run"
smoke_assert_eq "$end_count" "1" "T8: exactly one end marker after re-run"
smoke_assert_contains "$(cat "$ROSTER_T8")" 'BRIDGE_TEMPLATE_DEFAULT_MODEL="claude-opus-4-8"' \
  "T8: re-run updated the model value in place"

# ---------------------------------------------------------------------------
# T9-T11 — NON-STUBBED end-to-end: the wizard drives the REAL gated profile
# writer AND the REAL Contract-II materialize verb against the live smoke
# roster. T7 stubs the writer; these cases prove the wired-up path actually
# mutates a target's roster fields, that the gate denies a non-operator
# caller, and that a backfill writer failure propagates to a non-zero exit.
# ---------------------------------------------------------------------------
# CI runners ship no engine npm package; `agent create --engine claude`
# runs a `command -v claude` pre-flight (#1317-C) that hard-dies otherwise.
# Seed executable engine stubs + prepend to PATH (the 1427-A pattern).
E2E_STUB_BIN="$SMOKE_TMP_ROOT/e2e-stub-bin"
mkdir -p "$E2E_STUB_BIN"
for _eng in claude codex; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$E2E_STUB_BIN/$_eng"
  chmod +x "$E2E_STUB_BIN/$_eng"
done
export PATH="$E2E_STUB_BIN:$PATH"

# Extract a single managed-role field value from the live smoke roster.
e2e_roster_field() {
  local agent="$1" var="$2"
  python3 -c '
import re, shlex, sys
path, agent, var = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
m = re.search(rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n(.*?)^# END AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n", text, re.M | re.S)
body = m.group(1) if m else ""
fm = re.search(rf"^{re.escape(var)}\[\"{re.escape(agent)}\"\]=(.*)$", body, re.M)
if not fm:
    print("")
else:
    try:
        parts = shlex.split(fm.group(1))
        print(parts[0] if parts else "")
    except ValueError:
        print(fm.group(1))
' "$BRIDGE_ROSTER_LOCAL_FILE" "$agent" "$var"
}

# Reset the live smoke roster + create a real target agent to backfill.
: >"$BRIDGE_ROSTER_LOCAL_FILE"
BRIDGE_CALLER_SOURCE="operator-tui" \
  bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create e2etgt --engine claude >/dev/null 2>&1

# Real materialize + real profile writer, both operator-gated, against the
# LIVE roster (not a per-test temp file) so we exercise the wired path.
REAL_MATERIALIZE_CMD="bash $SMOKE_REPO_ROOT/bridge-agent.sh roster materialize-fields"
run_ts_e2e() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD="$PROFILE_WRITER_CMD" \
  BRIDGE_TEMPLATE_SYNC_MATERIALIZE_CMD="$REAL_MATERIALIZE_CMD" \
    python3 "$SETUP_PY" template-sync "$@" >"$TS_STDOUT" 2>"$TS_STDERR"
}

# T9 — real backfill writes the target's explicit roster fields.
run_ts_e2e --from patch --roster-file "$BRIDGE_ROSTER_LOCAL_FILE" --ref-engine claude \
  --ref-model claude-opus-4-8 --ref-effort xhigh \
  --targets e2etgt --yes
e2e_rc=$?
smoke_assert_eq "$e2e_rc" "0" "T9: real materialize backfill exits 0"
smoke_assert_eq "$(e2e_roster_field e2etgt BRIDGE_AGENT_MODEL)" "claude-opus-4-8" \
  "T9: real backfill wrote explicit model into the target's roster block"
smoke_assert_eq "$(e2e_roster_field e2etgt BRIDGE_AGENT_EFFORT)" "xhigh" \
  "T9: real backfill wrote explicit effort into the target's roster block"
# The controller-owned defaults profile also landed in the live roster.
smoke_assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" 'agb:template-defaults v1' \
  "T9: defaults profile block landed in the live roster via the gated verb"

# T10 — the gated profile-write verb DENIES a non-operator caller.
DENY_BLOCK="$SMOKE_TMP_ROOT/deny-block.txt"
printf '# === agb:template-defaults v1 (managed by `setup template-sync`) ===\n# meta: source_agent=patch\n# === end agb:template-defaults ===\n' >"$DENY_BLOCK"
DENY_ROSTER="$SMOKE_TMP_ROOT/deny-roster.sh"
: >"$DENY_ROSTER"
deny_out="$(BRIDGE_CALLER_SOURCE="agent-direct" \
  bash "$SMOKE_REPO_ROOT/bridge-agent.sh" roster write-template-profile \
  --source-agent patch --roster-file "$DENY_ROSTER" --block-file "$DENY_BLOCK" 2>&1)"
deny_rc=$?
[[ "$deny_rc" -ne 0 ]] || smoke_fail "T10: non-operator caller must be denied (got rc=0)"
smoke_assert_contains "$deny_out" "deny" "T10: deny message surfaced for agent-direct caller"
# The denied write left the roster untouched (no profile block written).
smoke_assert_not_contains "$(cat "$DENY_ROSTER")" 'agb:template-defaults' \
  "T10: denied write left the roster untouched"

# T11 — a backfill writer failure propagates to a non-zero wizard exit.
# `nope-not-an-agent` is not in the roster → the materialize verb's
# bridge_require_agent rejects it non-zero → the wizard must exit non-zero.
ROSTER_T11="$SMOKE_TMP_ROOT/roster-t11.sh"
: >"$ROSTER_T11"
run_ts_e2e --from patch --roster-file "$ROSTER_T11" --ref-engine claude \
  --ref-model claude-opus-4-8 \
  --targets nope-not-an-agent --yes
t11_rc=$?
[[ "$t11_rc" -ne 0 ]] || smoke_fail "T11: backfill writer failure must yield non-zero exit (got rc=0)"
t11_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("write_status",""))' <"$TS_STDOUT" 2>/dev/null || echo "")"
smoke_assert_eq "$t11_status" "backfill_error" "T11: write_status flags backfill_error"

# T12 — the wizard's main-path caller-source gate denies an agent-direct
# caller EVEN WHEN it controls BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD (#1432
# review BLOCKING). A caller-controlled override pointing at an un-gated
# writer must not bypass the boundary: the gate runs in cmd_template_sync's
# main path BEFORE any writer command is resolved/run, so the override writer
# below (which WOULD splice the block) never executes and the roster is
# untouched. (Built with printf, no heredoc — footgun #11.)
BYPASS_WRITER="$SMOKE_TMP_ROOT/bypass-writer.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'rf=""; bf=""\n'
  printf 'while [[ $# -gt 0 ]]; do case "$1" in --roster-file) rf="$2"; shift 2;; --block-file) bf="$2"; shift 2;; *) shift;; esac; done\n'
  printf '[[ -n "$rf" && -n "$bf" ]] && cat "$bf" >>"$rf"\n'
  printf 'exit 0\n'
} >"$BYPASS_WRITER"
T12_ROSTER="$SMOKE_TMP_ROOT/roster-t12.sh"
: >"$T12_ROSTER"
T12_OUT="$SMOKE_TMP_ROOT/t12-out.txt"
T12_ERR="$SMOKE_TMP_ROOT/t12-err.txt"
BRIDGE_CALLER_SOURCE="agent-direct" \
  BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD="bash $BYPASS_WRITER" \
  python3 "$SETUP_PY" template-sync --from patch --roster-file "$T12_ROSTER" \
    --ref-engine claude --ref-model claude-opus-4-8 --yes \
    >"$T12_OUT" 2>"$T12_ERR"
t12_rc=$?
[[ "$t12_rc" -ne 0 ]] || smoke_fail "T12: agent-direct must be denied even with a writer-cmd override (got rc=0)"
smoke_assert_contains "$(cat "$T12_OUT" "$T12_ERR")" "deny" \
  "T12: deny surfaced for agent-direct caller despite the override"
smoke_assert_not_contains "$(cat "$T12_ROSTER")" 'agb:template-defaults' \
  "T12: the override writer never ran — roster left untouched"

smoke_log "PASS: all template-sync wizard assertions (T1-T12)"
