#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2171-daemon-active-dead-recover.sh — #2171 PR-B2 Part2 (incident
# #19460 M4 fleet-down): daemon active-dead recover (Option-B auth-dead marker +
# nudge-fanout recover gate).
#
# The fleet-down gap Part2 closes: a 401 / origin-403 on the controller's active
# Claude token was nowhere recovered (usage-probe degraded → 0 rotation signal),
# and the nudge fanout sent a keystroke to a dead-active agent (burning a turn).
# Detection is Option B ONLY: bridge-usage-probe.py is the SOLE marker writer; the
# fanout does ZERO network — it READS + identity-validates the marker, then reuses
# the EXISTING #19460 mark-adverse + the reactive rotate (--preflight, --sync,
# #1789 pool-exhausted) shapes. No second rotator, no new notifier.
#
# Coverage:
#   A  — helper (in-process probe seam): marker WRITER (401/origin-403 → marker,
#        edge-403 → none, clean read clears) + read-only VALIDATOR gate (consume
#        ONLY on fresh + active-id + display-fp + digest match; stale/replaced/
#        absent/unreadable → no-signal, never suppresses).
#   B  — CLI TSV contract: `auth-dead-marker-check` emits the stable 5-col line
#        the daemon parses (consume + no-signal).
#   C  — daemon recover integration (sources bridge-daemon.sh; fake claude, NO
#        network, mock tokens): consume → mark-adverse(auth_failed, fingerprint,
#        NO permanent disable) + rotate → rotated → return PROCEED; pool-exhausted
#        → return SUPPRESS + #1789 window armed; stale marker → stamps NOTHING +
#        return PROCEED (nudge NOT suppressed).
#   D  — scope-match unit (static/all/csv/empty) + wiring guards on the fanout gate
#        placement / engine+scope predicate / #1789 reuse / bridge-usage.sh marker
#        plumbing.
#   S  — footgun #11: no heredoc-stdin into a python3/bash subprocess.
#
# Hermetic: isolated BRIDGE_HOME (mktemp); NEVER touches the live ~/.agent-bridge
# or a real daemon; makes NO network call.

set -uo pipefail

SMOKE_NAME="2171-daemon-active-dead-recover"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"
# Daemon smoke hygiene: never let a leaked live runtime env reach the sourced
# daemon / the bridge-auth.sh + usage-probe children (prior fixer incident: a
# daemon smoke ran against the live ~/.agent-bridge). smoke_setup_bridge_home set
# the sandbox; scrub the inherited overrides that would re-point at the live tree.
unset BRIDGE_RUNTIME_CONFIG_FILE BRIDGE_RUNTIME_ROOT 2>/dev/null || true

REPO_ROOT="$SMOKE_REPO_ROOT"
# Stable copies captured BEFORE any subshell sources bridge-daemon.sh (which sets
# its own SCRIPT_DIR); the self-scan below must not read SCRIPT_DIR post-source.
SMOKE_SELF="$SCRIPT_DIR/${SMOKE_NAME}.sh"
HELPER="$SCRIPT_DIR/${SMOKE_NAME}-helper.py"
PROBE_PY="$REPO_ROOT/bridge-usage-probe.py"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
USAGE_SH="$REPO_ROOT/bridge-usage.sh"
for f in "$HELPER" "$PROBE_PY" "$DAEMON_SH" "$USAGE_SH"; do
  [[ -f "$f" ]] || smoke_fail "missing required file: $f"
done

# Mock OAT strings (never real, never logged raw).
TOK_DEAD="sk-ant-oat-MOCK-active-dead-AAAA"
TOK_GOOD="sk-ant-oat-MOCK-rotate-good-BBBB"

py_fp() { python3 -c 'import hashlib,sys
t=sys.argv[1]
d=hashlib.sha256(t.encode()).hexdigest()
print("sha256:%s...%s" % (d[:12], t[-4:] if len(t)>=4 else t))' "$1"; }
py_dig() { python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$1"; }
reg_field() {
  python3 -c 'import json,sys
reg=json.load(open(sys.argv[1]))
row=next((t for t in reg["tokens"] if t["id"]==sys.argv[2]),{})
v=row.get(sys.argv[3],"")
print("true" if v is True else "false" if v is False else v)' "$1" "$2" "$3"
}
reg_active() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["active_token_id"])' "$1"; }

# write_registry <path> <active_id> — t1(active)=DEAD, t2=GOOD, auto_rotate on.
write_registry() {
  python3 -c 'import json,sys
reg={"version":1,"active_token_id":sys.argv[2],"auto_rotate_enabled":True,
     "rotation_threshold":99.0,"weekly_warn_threshold":95.0,
     "tokens":[{"id":"t1","token":sys.argv[3],"enabled":True},
               {"id":"t2","token":sys.argv[4],"enabled":True}],
     "last_rotation":{}}
json.dump(reg,open(sys.argv[1],"w"))' "$1" "$2" "$TOK_DEAD" "$TOK_GOOD"
}

# write_marker <path> <active_id> <token> <http_status> — fresh, identity-bound.
write_marker() {
  python3 -c 'import json,sys,hashlib,datetime
t=sys.argv[3]
d=hashlib.sha256(t.encode()).hexdigest()
m={"active_token_id":sys.argv[2],
   "token_fingerprint":"sha256:%s...%s"%(d[:12],t[-4:]),
   "_token_signal_digest":d[:16],
   "http_status":int(sys.argv[4]),
   "source":"usage-probe",
   "written_at":datetime.datetime.now(datetime.timezone.utc).isoformat()}
json.dump(m,open(sys.argv[1],"w"))' "$1" "$2" "$3" "$4"
}

# A fake `claude` for rotate --preflight: reads its handed token from
# $CLAUDE_CONFIG_DIR/.credentials.json, looks up $AGB_VERDICTS (token->status),
# emits classify-able JSON. NO network. Write-to-file heredoc (cat) is allowed by
# the heredoc-ban scanner (only python3/bash heredoc-STDIN is banned).
FAKE_CLAUDE="$SMOKE_TMP_ROOT/fake-claude"
cat > "$FAKE_CLAUDE" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
token = ""
try:
    with open(os.path.join(cfg, ".credentials.json"), encoding="utf-8") as fh:
        token = ((json.load(fh) or {}).get("claudeAiOauth") or {}).get("accessToken") or ""
except Exception:
    token = ""
verdicts = json.loads(os.environ.get("AGB_VERDICTS", "{}"))
status = verdicts.get(token, "available")
if status == "auth_failed":
    print(json.dumps({"is_error": True, "api_error_status": "401", "result": "unauthorized"}))
    sys.exit(1)
print(json.dumps({"is_error": False, "result": "OK"}))
sys.exit(0)
PYEOF
chmod 0755 "$FAKE_CLAUDE"

# Daemon-smoke convention (see scripts/smoke/1178-*.sh:316-334 + 1459-*.sh
# extract_fn): NEVER source the full 11k-line bridge-daemon.sh — sourcing it runs
# source-time code (bridge_load_roster / dispatch wiring) that is not hermetic for
# these fixtures and exits the subshell before the function under test ever runs.
# Instead extract ONLY the recover fn + its in-process bash deps via awk into a
# standalone file, stub the deps that would pull in roster/state/audit/notify, and
# keep the REAL subprocess shell-outs (bridge-usage-probe.py / bridge-auth.sh /
# bridge-daemon-helpers.py) so the registry mutation is genuinely exercised.
#
# extract_fn <name> — emit `name() { ... }` (first `^name() {` to the next `^}`).
extract_fn() { awk "/^$1\\(\\) \\{/,/^\\}/" "$DAEMON_SH"; }

# Build the standalone sourceable harness ONCE.
RECOVER_ENV="$SMOKE_TMP_ROOT/recover-env.sh"
build_recover_env() {
  : >"$RECOVER_ENV"
  # shellcheck disable=SC2129  # per-line emit mirrors the footgun #11 avoidance shape
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # Stub the heavy deps that the extracted functions reference but that would
    # otherwise pull in roster / audit / notify machinery. These are NOT under
    # test here (D2 source-greps the real fn for their presence); the C contract
    # is the registry mutation + the suppress/proceed return code.
    printf '%s\n' 'daemon_warn() { :; }'
    printf '%s\n' 'bridge_audit_log() { :; }'
    printf '%s\n' 'bridge_daemon_pass_due() { return 1; }'
    printf '%s\n' 'bridge_agent_has_notify_transport() { return 1; }'
    printf '%s\n' 'bridge_notify_send() { :; }'
    # The established blessed stub for the subprocess-timeout wrapper (1685/1151/
    # 1520): drop the <secs> <label> prefix and run the real command in-shell so
    # the probe/auth/helper shell-outs still execute (offline, fixture-bound).
    printf '%s\n' 'bridge_with_timeout() { shift 2 || true; "$@"; }'
    # bridge_agent_is_static is consulted only by scope-match (D1 exercises it
    # directly); the recover C-cases pass scope=static, so a static fixture is
    # deterministic. AGB_FIXTURE_STATIC=0 lets a caller flip it for a negative.
    printf '%s\n' 'bridge_agent_is_static() { [[ "${AGB_FIXTURE_STATIC:-1}" == "1" ]]; }'
    printf '%s\n' ''
    # Real in-process deps (pure / state-file-bounded) extracted verbatim.
    extract_fn bridge_claude_pool_exhausted_state_file
    printf '%s\n' ''
    extract_fn bridge_claude_iso_to_epoch
    printf '%s\n' ''
    extract_fn daemon_source_state_file
    printf '%s\n' ''
    extract_fn bridge_note_claude_pool_exhausted
    printf '%s\n' ''
    extract_fn bridge_clear_claude_pool_exhausted
    printf '%s\n' ''
    extract_fn bridge_claude_pool_rotate_suppressed
    printf '%s\n' ''
    extract_fn bridge_daemon_claude_recover_scope_match
    printf '%s\n' ''
    extract_fn bridge_daemon_claude_active_dead_recover
  } >>"$RECOVER_ENV"
  # Each extracted dep is non-empty (a typo'd rename would silently extract "").
  local fn
  for fn in bridge_claude_pool_exhausted_state_file bridge_claude_iso_to_epoch \
            daemon_source_state_file bridge_note_claude_pool_exhausted \
            bridge_clear_claude_pool_exhausted bridge_claude_pool_rotate_suppressed \
            bridge_daemon_claude_recover_scope_match bridge_daemon_claude_active_dead_recover; do
    grep -q "^$fn() {" "$RECOVER_ENV" \
      || smoke_fail "extract_fn produced no body for $fn (renamed in bridge-daemon.sh?)"
  done
}

# run_recover <marker> <registry> <scope> <verdicts-json> — source the EXTRACTED
# recover env in a SUBSHELL and run the recover against the isolated registry;
# print "RC=<n>". The registry mutation is the observable side effect the parent
# asserts. SCRIPT_DIR + BRIDGE_BASH_BIN are what the recover fn uses to locate the
# real probe/auth/helper subprocesses.
run_recover() {
  local marker="$1" registry="$2" scope="$3" verdicts="$4"
  # Test isolation: the #1789 pool-exhausted window is daemon state SHARED across
  # the C1/C2/C3 runs (one BRIDGE_STATE_DIR). Reset it so each scenario starts
  # from a clean across-pass cooldown (C2 still re-creates it within its call).
  rm -f "$BRIDGE_STATE_DIR/usage/claude-pool-exhausted.env" 2>/dev/null || true
  (
    export SCRIPT_DIR="$REPO_ROOT"
    export BRIDGE_BASH_BIN="${BASH:-bash}"
    export BRIDGE_CLAUDE_TOKEN_REGISTRY="$registry"
    export BRIDGE_CLAUDE_TOKEN_CHECK_BIN="$FAKE_CLAUDE"
    export AGB_VERDICTS="$verdicts"
    # Leave BRIDGE_ADMIN_AGENT_ID unset so the audit/notify branches stay inert.
    # Keep the preflight ring snappy + offline-bounded.
    export BRIDGE_CLAUDE_ROTATE_PREFLIGHT_PER_CANDIDATE_SECONDS=2
    export BRIDGE_CLAUDE_ROTATE_PREFLIGHT_BUDGET_SECONDS=6
    export BRIDGE_CLAUDE_ROTATE_TIMEOUT_SECONDS=30
    # shellcheck source=/dev/null
    source "$RECOVER_ENV"
    local rc=0
    bridge_daemon_claude_active_dead_recover "$marker" "$registry" "$scope" >/dev/null 2>&1 || rc=$?
    printf 'RC=%s\n' "$rc"
  )
}

# ── A: Part2-A behavioral helper (writer + validator via the probe seam) ──
test_part2a_helper() {
  python3 "$HELPER" || smoke_fail "Part2-A helper (marker writer + validator) failed"
}

# ── B: CLI TSV contract the daemon parses ──
test_cli_tsv_contract() {
  local d="$SMOKE_TMP_ROOT/cli"
  mkdir -p "$d"
  local reg="$d/reg.json" marker="$d/marker.json"
  write_registry "$reg" t1
  write_marker "$marker" t1 "$TOK_DEAD" 401
  # consume: fresh + matching → TSV col1=consume, col2=t1, col3=display-fp, col4=401
  local line
  line="$(python3 "$PROBE_PY" auth-dead-marker-check --registry-path "$reg" --marker-path "$marker" --max-age 300)"
  local verdict id fp http reason
  IFS=$'\t' read -r verdict id fp http reason <<<"$line"
  smoke_assert_eq "consume" "$verdict" "CLI consume verdict col1"
  smoke_assert_eq "t1" "$id" "CLI consume active id col2"
  smoke_assert_eq "$(py_fp "$TOK_DEAD")" "$fp" "CLI consume display fingerprint col3"
  smoke_assert_eq "401" "$http" "CLI consume http_status col4"
  # no-signal: replace the active token value → fingerprint/digest mismatch.
  write_registry "$reg" t1   # rewrites t1 token = TOK_DEAD; now mutate it:
  python3 -c 'import json,sys
reg=json.load(open(sys.argv[1]))
for r in reg["tokens"]:
    if r["id"]=="t1": r["token"]="sk-ant-oat-MOCK-rotated-away-XYZ9"
json.dump(reg,open(sys.argv[1],"w"))' "$reg"
  line="$(python3 "$PROBE_PY" auth-dead-marker-check --registry-path "$reg" --marker-path "$marker" --max-age 300)"
  IFS=$'\t' read -r verdict id fp http reason <<<"$line"
  smoke_assert_eq "no-signal" "$verdict" "CLI no-signal verdict on token replacement"
  [[ "$reason" == "fingerprint_mismatch" || "$reason" == "digest_mismatch" ]] \
    || smoke_fail "CLI no-signal reason should be identity mismatch, got '$reason'"
}

# ── C1: consume → mark-adverse + rotate → rotated → PROCEED (rc 0) ──
test_recover_rotated() {
  local d="$SMOKE_TMP_ROOT/c1"
  mkdir -p "$d"
  local reg="$d/reg.json" marker="$d/marker.json"
  write_registry "$reg" t1
  write_marker "$marker" t1 "$TOK_DEAD" 401
  local verdicts
  verdicts="$(python3 -c 'import json,sys;print(json.dumps({sys.argv[1]:"available",sys.argv[2]:"available"}))' "$TOK_GOOD" "$TOK_DEAD")"
  local out
  out="$(run_recover "$marker" "$reg" static "$verdicts")"
  smoke_assert_eq "RC=0" "$out" "consume+rotated → recover returns PROCEED (nudge after fresh token)"
  smoke_assert_eq "t2" "$(reg_active "$reg")" "active rotated to the live candidate t2"
  smoke_assert_eq "auth_failed" "$(reg_field "$reg" t1 last_check_status)" "dead t1 stamped auth_failed (deterministic #19460)"
  smoke_assert_eq "true" "$(reg_field "$reg" t1 enabled)" "auth_failed NEVER permanently disables t1 (TTL-bounded)"
  [[ -z "$(reg_field "$reg" t1 disabled_until)" ]] || smoke_fail "auth_failed must NOT stamp a disable window on t1"
}

# ── C2: every candidate dead → all_tokens_limited → SUPPRESS (rc 1) + #1789 ──
test_recover_pool_exhausted() {
  local d="$SMOKE_TMP_ROOT/c2"
  mkdir -p "$d"
  local reg="$d/reg.json" marker="$d/marker.json"
  write_registry "$reg" t1
  write_marker "$marker" t1 "$TOK_DEAD" 401
  local verdicts
  verdicts="$(python3 -c 'import json,sys;print(json.dumps({sys.argv[1]:"auth_failed",sys.argv[2]:"auth_failed"}))' "$TOK_GOOD" "$TOK_DEAD")"
  local out
  out="$(run_recover "$marker" "$reg" static "$verdicts")"
  smoke_assert_eq "RC=1" "$out" "pool-exhausted → recover returns SUPPRESS (futile nudge skipped)"
  smoke_assert_eq "t1" "$(reg_active "$reg")" "active UNCHANGED when no live candidate (no dead-token sync)"
  smoke_assert_file_exists "$BRIDGE_STATE_DIR/usage/claude-pool-exhausted.env" \
    "#1789 D2 pool-exhausted window armed (reuses existing escalation, no new notifier)"
}

# ── C3: stale marker (active replaced) → stamp NOTHING + PROCEED (rc 0) ──
test_recover_stale_marker() {
  local d="$SMOKE_TMP_ROOT/c3"
  mkdir -p "$d"
  local reg="$d/reg.json" marker="$d/marker.json"
  write_registry "$reg" t1
  # Marker blames TOK_GOOD under id t1, but the registry active t1 token is
  # TOK_DEAD → fingerprint/digest mismatch → validator says no-signal.
  write_marker "$marker" t1 "$TOK_GOOD" 401
  local out
  out="$(run_recover "$marker" "$reg" static "{}")"
  smoke_assert_eq "RC=0" "$out" "stale marker → recover returns PROCEED (nudge NOT suppressed)"
  smoke_assert_eq "t1" "$(reg_active "$reg")" "stale marker triggers NO rotation"
  smoke_assert_eq "" "$(reg_field "$reg" t1 last_check_status)" "stale marker stamps NOTHING (no mark-adverse on a mismatch)"
}

# ── D1: scope-match unit (static/all/csv/empty) ──
test_scope_match() {
  (
    # shellcheck source=/dev/null
    source "$RECOVER_ENV"
    # 'all' matches any agent.
    bridge_daemon_claude_recover_scope_match anyagent all || exit 21
    # explicit-empty scope matches nothing (controller sentinels only).
    bridge_daemon_claude_recover_scope_match anyagent "" && exit 22
    # CSV membership.
    bridge_daemon_claude_recover_scope_match worker-a "worker-a,worker-b" || exit 23
    bridge_daemon_claude_recover_scope_match worker-z "worker-a,worker-b" && exit 24
    # 'static' delegates to bridge_agent_is_static (fixture: AGB_FIXTURE_STATIC).
    AGB_FIXTURE_STATIC=1 bridge_daemon_claude_recover_scope_match s1 static || exit 25
    AGB_FIXTURE_STATIC=0 bridge_daemon_claude_recover_scope_match d1 static && exit 26
    exit 0
  )
  local rc=$?
  smoke_assert_eq "0" "$rc" "scope-match: all=∀, empty=∅, csv-membership, static-delegate (rc marker $rc)"
}

# ── D2: source-grep wiring guards ──
test_wiring_guards() {
  # The fanout gate must sit BETWEEN the dead-session check and nudge_agent_session.
  # Anchor the window on the UNIQUE fanout loop header and the UNIQUE nudge call so
  # an earlier bridge_tmux_session_exists site cannot mis-scope the awk.
  local fanout
  fanout="$(awk '/while IFS=\$.\\t. read -r agent session queued claimed idle nudge_key; do/{f=1} f{print} f&&/if nudge_agent_session /{exit}' "$DAEMON_SH")"
  [[ -n "$fanout" ]] || smoke_fail "could not isolate the nudge fanout window in bridge-daemon.sh"
  # The recover gate must come AFTER the dead-session check (defer/escalate) within
  # that window — assert the ordering explicitly.
  printf '%s\n' "$fanout" | grep -q 'bridge_tmux_session_exists "\$session"' \
    || smoke_fail "fanout window does not contain the dead-session check (anchor drift)"
  printf '%s\n' "$fanout" | grep -q 'bridge_daemon_claude_active_dead_recover' \
    || smoke_fail "fanout does NOT call the active-dead recover between the dead-session check and the nudge"
  printf '%s\n' "$fanout" | grep -q 'bridge_agent_engine "\$agent")" == "claude"' \
    || smoke_fail "fanout recover gate is not restricted to engine==claude"
  printf '%s\n' "$fanout" | grep -q 'bridge_daemon_claude_recover_scope_match' \
    || smoke_fail "fanout recover gate does not apply the rotation-scope predicate"
  printf '%s\n' "$fanout" | grep -qE '\[\[ -f "\$_authdead_marker" \]\]' \
    || smoke_fail "fanout recover gate is not short-circuited by the marker-file fast path"
  # The suppress `continue` must be INSIDE the suppress-verdict branch — anchor the
  # grep to that exact block (the fanout has many unrelated `continue`s, so a bare
  # grep -q 'continue' is vacuous: dropping the suppress continue would still pass).
  local suppress_block
  suppress_block="$(printf '%s\n' "$fanout" | awk '/\[\[ "\$_authdead_suppress_nudge" -eq 1 \]\]; then/{f=1} f{print} f&&/^[[:space:]]*fi$/{exit}')"
  [[ -n "$suppress_block" ]] \
    || smoke_fail "could not isolate the suppress-verdict branch in the fanout window"
  printf '%s\n' "$suppress_block" | grep -qE '^[[:space:]]*continue$' \
    || smoke_fail "suppress-verdict branch does not 'continue' (skip the futile nudge) — the futile keystroke would still fire"

  # The recover reuses the EXISTING shapes (no second rotator / no new notifier).
  local recover_fn
  recover_fn="$(awk '/^bridge_daemon_claude_active_dead_recover\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DAEMON_SH")"
  [[ -n "$recover_fn" ]] || smoke_fail "could not isolate bridge_daemon_claude_active_dead_recover"
  printf '%s\n' "$recover_fn" | grep -q 'mark-adverse' \
    || smoke_fail "recover does not call mark-adverse"
  printf '%s\n' "$recover_fn" | grep -q -- '--status auth_failed' \
    || smoke_fail "recover does not mark-adverse with --status auth_failed"
  printf '%s\n' "$recover_fn" | grep -q -- '--fingerprint' \
    || smoke_fail "recover does not pass --fingerprint to mark-adverse (stale-token guard)"
  printf '%s\n' "$recover_fn" | grep -q -- '--preflight' \
    || smoke_fail "recover rotate does not enable --preflight (Part1 live-probe)"
  printf '%s\n' "$recover_fn" | grep -q -- '--if-auto-enabled' \
    || smoke_fail "recover rotate dropped --if-auto-enabled"
  printf '%s\n' "$recover_fn" | grep -q -- '--sync' \
    || smoke_fail "recover rotate dropped the --sync fanout (would be a second rotator)"
  printf '%s\n' "$recover_fn" | grep -q 'bridge_claude_pool_rotate_suppressed' \
    || smoke_fail "recover does not reuse the #1789 across-pass pool cooldown"
  printf '%s\n' "$recover_fn" | grep -q 'bridge_note_claude_pool_exhausted' \
    || smoke_fail "recover does not arm the #1789 pool-exhausted window on all_tokens_limited"

  # bridge-usage.sh plumbs the marker path to the SOLE writer.
  grep -q -- '--auth-dead-marker' "$USAGE_SH" \
    || smoke_fail "bridge-usage.sh does not pass --auth-dead-marker to the probe"
  grep -q 'BRIDGE_CLAUDE_AUTH_DEAD_MARKER' "$USAGE_SH" \
    || smoke_fail "bridge-usage.sh does not honor the BRIDGE_CLAUDE_AUTH_DEAD_MARKER contract"
}

# ── S: footgun #11 self-scan ──
test_no_heredoc_stdin() {
  local lt='<'
  local redir_pattern="python3[^|]*${lt}${lt}|bash[[:space:]]+${lt}${lt}"
  local f
  for f in "$SMOKE_SELF" "$HELPER"; do
    if grep -nE "$redir_pattern" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
      smoke_fail "heredoc-stdin into a python3/bash subprocess found in $(basename "$f")"
    fi
  done
}

# Build the extracted recover env once (C1/C2/C3 + D1 source it).
build_recover_env

smoke_run "A  Part2-A: marker writer + validator (probe seam)"        test_part2a_helper
smoke_run "B  CLI TSV contract (consume + no-signal)"                  test_cli_tsv_contract
smoke_run "C1 consume → mark-adverse + rotate → rotated → PROCEED"     test_recover_rotated
smoke_run "C2 pool-exhausted → SUPPRESS + #1789 window armed"          test_recover_pool_exhausted
smoke_run "C3 stale marker → stamp NOTHING + PROCEED (no suppress)"    test_recover_stale_marker
smoke_run "D1 scope-match unit (static/all/csv/empty)"                 test_scope_match
smoke_run "D2 fanout gate + recover reuse + usage.sh plumbing guards"  test_wiring_guards
smoke_run "S  footgun #11: no heredoc-stdin into a subprocess"         test_no_heredoc_stdin

smoke_log "all checks passed"
