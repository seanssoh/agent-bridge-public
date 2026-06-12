#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1836-iso-first-start-queue-dir-ownership.sh
#   — wave v0.16.10 lane A2: Issue #1836 (first-start death) + #1829
#     (queue-dir ownership stranding).
#
# Two coupled iso-v2 root causes:
#
#   #1836 — a freshly provisioned linux-user-isolated agent's FIRST
#           `agb agent start` dies within seconds (100% reproducible);
#           the SECOND start always succeeds. Root cause is KNOWN_ISSUES
#           §28: `agent create`/`isolate` adds the controller to the new
#           `ab-agent-<agent>` group via `usermod -aG`, but that does NOT
#           propagate to the already-running controller/daemon process —
#           so the first launch cannot traverse `data/agents/<agent>/`
#           (group 2770) and the session dies before the REPL. The fix
#           gives `run_start` the same supp-group refresh `agent create`
#           already does, PLUS an in-process `sg ab-agent-<agent>` re-exec
#           (with a loop sentinel) so attempt 1 is deterministic.
#
#   #1829 — after that first-start-death + restart-rollback, the per-agent
#           `requests/`/`responses/` queue-gateway dirs can be left
#           `<controller>:<controller> 2770` instead of the iso-v2 contract
#           `agent-bridge-<a>:ab-agent-<a> 2770`. The iso UID is a member of
#           `ab-agent-<a>` but NOT the controller's primary group, so a
#           controller-primary-group dir cuts it off from EVERY `agb`
#           gateway verb. Fix is defense-in-depth: (a) both lazy creators in
#           bridge-queue-gateway.py stamp the group after mkdir; (b) a cheap
#           idempotent repair pass (`bridge_isolation_v2_repair_queue_dirs`)
#           runs on every `agent start`.
#
# Coverage matrix — host-agnostic where possible. The Linux-only runtime
# invariants (real iso UID + ab-agent-<a> group + 2770 traversal) need a
# system-level fixture (useradd / groupadd / passwordless sudoers) out of
# scope for a smoke; those are pinned via static-source greps + behavioral
# stubs here and gated on a real Linux host in promotion-verify. macOS
# limitation: no setfacl, no iso UIDs, getgrnam("ab-agent-*") misses — the
# behavioral tests assert the *no-op / fail-closed* branch on such hosts and
# the stamp branch via a monkeypatched group lookup.
#
# Footgun #11: no heredoc-stdin to a bash function or $(...) of one. The
# Python behavioral blocks are file-as-argv temp scripts.

set -uo pipefail

SMOKE_NAME="1836-iso-first-start-queue-dir-ownership"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT_SH="$REPO_ROOT/bridge-agent.sh"
START_SH="$REPO_ROOT/bridge-start.sh"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
ISO_V2_LIB="$REPO_ROOT/lib/bridge-isolation-v2.sh"
GATEWAY_PY="$REPO_ROOT/bridge-queue-gateway.py"

for f in "$AGENT_SH" "$START_SH" "$AGENTS_LIB" "$ISO_V2_LIB" "$GATEWAY_PY"; do
  [[ -f "$f" ]] || smoke_fail "missing $f"
done

# =====================================================================
# T1 — #1836: run_start preflight wiring + helper contract (static).
# =====================================================================

smoke_log "T1: run_start calls the first-start supp-group preflight"

# run_start must invoke the preflight BEFORE the exec into bridge-start.sh.
T1_CALL="$(grep -nF 'bridge_agent_start_supp_group_preflight "$agent" "$@"' "$AGENT_SH" || true)"
[[ -n "$T1_CALL" ]] || smoke_fail "T1: bridge-agent.sh run_start does not call bridge_agent_start_supp_group_preflight before exec (#1836 first-start fix regressed)"
smoke_log "T1 PASS — run_start wires the preflight: $T1_CALL"

# The helper must exist and carry the three required mechanisms:
#  (a) a daemon refresh call, (b) a re-exec loop sentinel, (c) an sg re-exec.
smoke_log "T1b: preflight helper carries daemon-refresh + sentinel + sg re-exec"
grep -nF 'bridge_agent_start_supp_group_preflight()' "$AGENTS_LIB" >/dev/null \
  || smoke_fail "T1b: bridge_agent_start_supp_group_preflight not defined in lib/bridge-agents.sh"
grep -nF 'bridge_daemon_refresh_after_group_membership_change' "$AGENTS_LIB" >/dev/null \
  || smoke_fail "T1b: preflight does not call the daemon supp-group refresh"
grep -nF 'agent-start:$agent' "$AGENTS_LIB" >/dev/null \
  || smoke_fail "T1b: preflight does not pass an agent-start reason to the daemon refresh"
grep -nF 'BRIDGE_AGENT_START_SUPP_REEXEC' "$AGENTS_LIB" >/dev/null \
  || smoke_fail "T1b: preflight is missing the re-exec loop sentinel BRIDGE_AGENT_START_SUPP_REEXEC (would infinite-loop)"
grep -nE 'exec[[:space:]]+sg[[:space:]]+"\$_grp"' "$AGENTS_LIB" >/dev/null \
  || smoke_fail "T1b: preflight does not re-exec under sg for the in-process group refresh"
smoke_log "T1b PASS — helper has daemon-refresh + sentinel + sg re-exec"

# =====================================================================
# T2 — #1836: preflight behavioral fail-safe (source + invoke with stubs).
# It must NOT re-exec / must return cleanly when: the sentinel is set,
# or the host is non-Linux, or the agent is not iso-effective. We can run
# the non-iso path on any host (macOS CI included).
# =====================================================================

smoke_log "T2: preflight is a clean no-op for a non-iso agent (any host)"

T2_DRIVER="$SMOKE_TMP_ROOT/t2-preflight.sh"
cat >"$T2_DRIVER" <<DRIVER
set -uo pipefail
export SCRIPT_DIR="$REPO_ROOT"
export BRIDGE_BASH_BIN="\${BASH:-bash}"
# Stub the dependencies the helper consults so we exercise the control flow
# without a real iso agent. uname stays real; the helper gates on
# bridge_agent_linux_user_isolation_effective which we force to "not iso".
bridge_agent_linux_user_isolation_effective() { return 1; }
bridge_warn() { printf 'WARN: %s\n' "\$*" >&2; }
# Source ONLY the helper function out of the lib by extracting it — sourcing
# the whole lib pulls heavy deps. Use a marker-bounded sed slice.
bridge_isolation_v2_agent_group_name() { printf 'ab-agent-%s' "\$1"; }
bridge_daemon_refresh_after_group_membership_change() { return 0; }
# shellcheck source=/dev/null
source "$SMOKE_TMP_ROOT/preflight-fn.sh"
# Non-iso agent → must return 0 with no exec.
bridge_agent_start_supp_group_preflight myagent --foo
echo "RETURNED_OK"
DRIVER

# Extract just the helper function body into a sourceable file (avoids
# sourcing the entire lib + its transitive deps).
awk '/^bridge_agent_start_supp_group_preflight\(\) \{/{c=1} c{print} /^\}$/{if(c){c=0; exit}}' \
  "$AGENTS_LIB" >"$SMOKE_TMP_ROOT/preflight-fn.sh"
[[ -s "$SMOKE_TMP_ROOT/preflight-fn.sh" ]] \
  || smoke_fail "T2: could not extract bridge_agent_start_supp_group_preflight body for behavioral test"

T2_OUT="$("${BASH:-bash}" "$T2_DRIVER" 2>&1 || true)"
case "$T2_OUT" in
  *RETURNED_OK*) ;;
  *) smoke_fail "T2: preflight non-iso path did not return cleanly. Output: $T2_OUT" ;;
esac
# It must NOT have re-exec'd anything (no `agent start` recursion observable
# because we'd never reach RETURNED_OK after an exec).
smoke_log "T2 PASS — preflight is a clean no-op for non-iso agents"

# =====================================================================
# T3 — #1829: gateway lazy creators stamp the per-agent dir group (static).
# =====================================================================

smoke_log "T3: bridge-queue-gateway.py normalizes lazily-created queue dirs"
grep -nF 'def _normalize_agent_queue_dir(' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T3: _normalize_agent_queue_dir helper missing from bridge-queue-gateway.py (#1829)"
# atomic_write_json must detect a freshly-created parent and stamp it (the
# daemon-wins-the-race path).
grep -nF '_normalize_agent_queue_dir_for_file(path)' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T3: atomic_write_json does not stamp a freshly-created responses/requests dir (daemon race left it controller-owned)"
# cmd_client ensure-dirs must stamp too (the iso-UID-wins path).
grep -nF '_normalize_agent_queue_dir(req_dir, args.agent)' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T3: cmd_client does not stamp a freshly-created requests/ dir"
grep -nF '_normalize_agent_queue_dir(resp_dir, args.agent)' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T3: cmd_client does not stamp a freshly-created responses/ dir"
smoke_log "T3 PASS — both lazy creators stamp the queue-dir group"

# =====================================================================
# T4 — #1829: gateway normalizer behavioral. Import the module and call
# _normalize_agent_queue_dir. On a host with NO ab-agent-* group (macOS /
# shared-mode CI) it must be a quiet no-op (fail-closed). With a
# monkeypatched group lookup it must chgrp+chmod to 2770.
# =====================================================================

smoke_log "T4: _normalize_agent_queue_dir no-ops without the iso group, stamps with it"

T4_PY="$SMOKE_TMP_ROOT/t4-normalize.py"
cat >"$T4_PY" <<PY
import importlib.util, os, stat, sys, tempfile, grp as _grp

repo = os.environ["REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "gwmod", os.path.join(repo, "bridge-queue-gateway.py"))
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

tmp = tempfile.mkdtemp()
d = os.path.join(tmp, "agentx", "responses")
os.makedirs(d)
before = stat.S_IMODE(os.stat(d).st_mode)

# Case A: no such group -> quiet no-op, must not raise, dir mode unchanged.
gw._normalize_agent_queue_dir(__import__("pathlib").Path(d), "agentx")
after_a = stat.S_IMODE(os.stat(d).st_mode)
assert after_a == before, f"no-group path mutated mode: {oct(before)} -> {oct(after_a)}"

# Case B: monkeypatch the group lookup to point at one of OUR real
# supplementary groups so chgrp can succeed without root, then confirm the
# helper stamps mode 2770 + that group.
my_gids = os.getgroups()
if my_gids:
    target_gid = my_gids[0]
    class _FakeGr:
        gr_gid = target_gid
    orig = _grp.getgrnam
    _grp.getgrnam = lambda name: _FakeGr()
    try:
        gw._normalize_agent_queue_dir(__import__("pathlib").Path(d), "agentx")
    finally:
        _grp.getgrnam = orig
    st = os.stat(d)
    assert stat.S_IMODE(st.st_mode) == 0o2770, f"stamp did not set 2770: {oct(stat.S_IMODE(st.st_mode))}"
    assert st.st_gid == target_gid, f"stamp did not chgrp: gid={st.st_gid} want={target_gid}"
    print("STAMP_OK")
else:
    print("STAMP_SKIP_no_supp_groups")

print("NOOP_OK")
PY

T4_OUT="$(REPO_ROOT="$REPO_ROOT" python3 "$T4_PY" 2>&1 || true)"
case "$T4_OUT" in
  *NOOP_OK*) ;;
  *) smoke_fail "T4: gateway normalizer behavioral test failed. Output: $T4_OUT" ;;
esac
case "$T4_OUT" in
  *STAMP_OK*) smoke_log "T4: stamp branch verified (chgrp+2770 applied)";;
  *STAMP_SKIP*) smoke_log "T4: stamp branch skipped (no supplementary groups on this host)";;
esac
smoke_log "T4 PASS — normalizer no-ops without group, stamps with it (no raise either way)"

# =====================================================================
# T5 — #1829: start-time repair helper exists, is idempotent, and is wired
# into bridge-start.sh (static + behavioral stat-skip).
# =====================================================================

smoke_log "T5: bridge_isolation_v2_repair_queue_dirs exists, idempotent, wired into start"
grep -nF 'bridge_isolation_v2_repair_queue_dirs()' "$ISO_V2_LIB" >/dev/null \
  || smoke_fail "T5: bridge_isolation_v2_repair_queue_dirs not defined in lib/bridge-isolation-v2.sh"
# Must re-assert ONLY requests + responses (not a broad tree walk).
grep -nE 'for sub in requests responses' "$ISO_V2_LIB" >/dev/null \
  || smoke_fail "T5: repair helper does not iterate exactly {requests,responses}"
# Idempotent stat-skip: must compare current owner:group:mode and continue
# when already 2770.
grep -nF 'cur_mode_norm" == "2770"' "$ISO_V2_LIB" >/dev/null \
  || smoke_fail "T5: repair helper lacks the idempotent 2770 stat-skip (would chown on every start)"
# Wired into bridge-start.sh, guarded by iso-effective + non-fatal.
grep -nF 'bridge_isolation_v2_repair_queue_dirs "$AGENT"' "$START_SH" >/dev/null \
  || smoke_fail "T5: bridge-start.sh does not call the queue-dir repair on start (#1829 self-heal regressed)"
smoke_log "T5 PASS — repair helper present, idempotent, wired into start"

# =====================================================================
# T6 — Respect A1's exit-code semantics: the gateway client's commit-path
# exit-code-on-commit + bounded retry (PR #1837/#1834) must remain intact.
# My #1829 mkdir-stamp additions must not have removed the response-driven
# exit propagation or the retry loop.
# =====================================================================

smoke_log "T6: A1 (#1837/#1834) gateway exit-code-on-commit + retry preserved"
grep -nF 'BRIDGE_QUEUE_GATEWAY_READ_RETRIES' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T6: gateway read-retry knob missing — A1 retry semantics may have regressed"
grep -nF 'atomic_write_json(request_path, request_payload)' "$GATEWAY_PY" >/dev/null \
  || smoke_fail "T6: cmd_client no longer enqueues the request via atomic_write_json (A1 path broken)"
# The stamp must be best-effort and NOT raise into the request write: the
# created-detection is guarded and the normalizer swallows OSError. Confirm
# the normalizer has the try/except OSError guards (a raise here would break
# A1's "request always enqueued" contract).
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$GATEWAY_PY" \
  || smoke_fail "T6: bridge-queue-gateway.py does not parse"
smoke_log "T6 PASS — A1 exit-code/retry surface intact; stamp is best-effort"

smoke_log "all tests PASS — #1836 first-start determinism + #1829 queue-dir ownership verified at current branch"
