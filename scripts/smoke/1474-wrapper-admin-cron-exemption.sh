#!/usr/bin/env bash
# scripts/smoke/1474-wrapper-admin-cron-exemption.sh — Issue #1474 (v0.15.3
# wrapper-path regression).
#
# Background. The #1474 admin cross-agent cron exemption
# (`_bridge_cron_create_admin_cross_agent_allowed` in bridge-cron.sh) lets the
# registered admin agent provision `--kind text` crons for OTHER agents
# (bootstrap-memory-system.sh registering memory-daily-<peer>), passing the
# #1359 iso cross-agent reject through to the controller-side staging path.
#
# The exemption resolves the admin id via `bridge_admin_agent_id()`, which
# reads `${BRIDGE_ADMIN_AGENT_ID:-}`. That worked on a DIRECT
# `bash bridge-cron.sh create --agent <other>` call (the caller's live session
# already EXPORTED BRIDGE_ADMIN_AGENT_ID via bridge-run.sh) — but FAILED on the
# wrapper path `agent-bridge cron create --agent <other>`:
#
#   * the `agent-bridge`/`agb` wrapper runs `bridge_load_roster` (which sourced
#     the roster and set BRIDGE_ADMIN_AGENT_ID as a NON-exported shell var),
#   * then `exec`s `bridge-cron.sh create ...`,
#   * across `exec` only EXPORTED vars survive, so the non-exported admin id was
#     dropped, and `run_create` never re-loads the roster (on an iso host the
#     child runs as the iso UID and cannot read the controller roster anyway),
#   * → `bridge_admin_agent_id()` returns "" in the child → the exemption can
#     never pass → hard #1359 reject → bootstrap drift persists.
#
# The fix EXPORTS BRIDGE_ADMIN_AGENT_ID inside `bridge_load_roster` (mirroring
# bridge-run.sh's runtime-path export) so the resolved admin id survives `exec`
# into the bridge-cron.sh child.
#
# This smoke exercises the REAL wrapper boundary (a parent shell that, exactly
# like `agent-bridge`, sources bridge-lib.sh, calls `bridge_load_roster`, then
# `exec`s `bridge-cron.sh create`). To isolate the export-survives-exec
# behaviour deterministically on any platform, the child's own roster files are
# EMPTY — so the child can ONLY learn the admin id from the inherited env. That
# is precisely the iso-host condition the bug reproduces on.
#
# Cases:
#   T1 — POSITIVE (wrapper path now works): admin/controller wrapper
#        (BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID) creating a cross-agent
#        `--kind text` cron PASSES the exemption — routes to staging, NO
#        'cron mutation refused'. Pre-fix this FAILED (admin id lost across
#        exec). This is the regression the fix closes.
#   T2 — TEETH (gate NOT weakened): a NON-admin / iso agent
#        (BRIDGE_AGENT_ID != BRIDGE_ADMIN_AGENT_ID) running the SAME wrapper +
#        cross-agent command STILL gets the #1359 reject — even though its
#        scoped env carries the controller's admin id. The gate compares
#        BRIDGE_AGENT_ID against the admin id, so a non-admin agent can never
#        pass it; exporting the admin id does not change that.
#   T3 — TEETH (shell-kind stays blocked): an admin cross-agent request with
#        `--kind shell` is STILL refused at the CLI guard — #1474 only widens
#        the text path; shell staging is out of scope.
#
# lint-heredoc-ban hygiene: this smoke uses NO process-substitution and NO
# heredoc-fed subprocess (`bash -s <<EOF` / `python3 - <<PY`). Output is
# captured to temp files and consumed with a `while read` loop / grep.

set -euo pipefail

SMOKE_NAME="1474-wrapper-admin-cron-exemption"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home

ADMIN_AGENT="patch"
PEER_AGENT="other-agent"
ISO_AGENT="worker-a"

# The "wrapper home" carries the roster that sets BRIDGE_ADMIN_AGENT_ID — this
# is what the parent's bridge_load_roster sources (just like the controller's
# agent-roster.local.sh). It sets the admin id as a NON-exported shell var; the
# fix's `export BRIDGE_ADMIN_AGENT_ID` in bridge_load_roster is what carries it
# across the exec.
printf 'BRIDGE_ADMIN_AGENT_ID="%s"\n' "$ADMIN_AGENT" >"$BRIDGE_ROSTER_LOCAL_FILE"

# jobs.json owned + non-writable so the iso-context staging branch engages
# (matches the real reproduction: controller-owned 0640 jobs.json).
JOBS_FILE="$BRIDGE_NATIVE_CRON_JOBS_FILE"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$JOBS_FILE"
chmod 0400 "$JOBS_FILE"
[[ ! -w "$JOBS_FILE" ]] || smoke_fail "setup error — jobs.json must be non-writable"

STAGING_ROOT="$BRIDGE_STATE_DIR/cron-staging"
mkdir -p "$STAGING_ROOT"

BRIDGE_BASH="$(command -v bash)"

# run_wrapper_cron_create <agent_id> <admin_present:1|0> <target> <kind> <out>
#
# Simulates the `agent-bridge cron create` wrapper end to end:
#   parent shell sources bridge-lib.sh, runs `bridge_load_roster`, then
#   `exec`s `bridge-cron.sh create ...` — EXACTLY the agent-bridge:cron arm.
#
# The CHILD's roster files are EMPTY so the child cannot re-resolve the admin
# id on its own; it must inherit it across the exec. This is what gives the
# smoke teeth: pre-fix the inherited value is missing and T1 hits the reject.
#
# `admin_present` controls whether the parent's roster sets the admin id at all
# (the parent always sources THIS home's roster; both legs use the same
# BRIDGE_ROSTER_LOCAL_FILE which sets admin=patch). The agent's identity is
# BRIDGE_AGENT_ID — admin leg passes patch, non-admin leg passes worker-a.
run_wrapper_cron_create() {
  local agent_id="$1"
  local target="$2"
  local kind="$3"
  local out="$4"
  local rc=0

  # Child env: empty roster (child cannot read the admin id from disk),
  # v2 layout + marker inherited from smoke_setup_bridge_home, jobs.json
  # non-writable so the iso-context staging branch engages.
  set +e
  env \
    BRIDGE_AGENT_ID="$agent_id" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
    BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
    BRIDGE_NATIVE_CRON_JOBS_FILE="$JOBS_FILE" \
    BRIDGE_CRON_STAGING_DIR="$STAGING_ROOT" \
    BRIDGE_CRON_STAGING_TIMEOUT_SECONDS=2 \
    BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS=1 \
    WRAPPER_REPO_ROOT="$REPO_ROOT" \
    WRAPPER_BRIDGE_BASH="$BRIDGE_BASH" \
    WRAPPER_TARGET="$target" \
    WRAPPER_KIND="$kind" \
    "$BRIDGE_BASH" "$SCRIPT_DIR/1474-wrapper-admin-cron-exemption-wrapper.sh" \
    >"$out" 2>&1
  rc=$?
  set -e
  return "$rc"
}

# Assert helper: does an output file contain the #1359 reject string?
out_has_reject() {
  local out="$1"
  local line
  local hit=0
  while IFS= read -r line; do
    case "$line" in
      *"cron mutation refused"*) hit=1; break ;;
    esac
  done <"$out"
  [[ "$hit" -eq 1 ]]
}

out_has_staging() {
  local out="$1"
  local line
  local hit=0
  while IFS= read -r line; do
    case "$line" in
      *"cron-staging"*) hit=1; break ;;
    esac
  done <"$out"
  [[ "$hit" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# T1 — POSITIVE: admin/controller wrapper path now PASSES the exemption.
# ---------------------------------------------------------------------------
smoke_log "T1: admin wrapper cross-agent --kind text must NOT be refused (proceeds to staging)"

T1_OUT="$SMOKE_TMP_ROOT/t1.out"
run_wrapper_cron_create "$ADMIN_AGENT" "$PEER_AGENT" "text" "$T1_OUT" || true

if out_has_reject "$T1_OUT"; then
  smoke_log "T1 output:"
  while IFS= read -r _l; do smoke_log "  | $_l"; done <"$T1_OUT"
  smoke_fail "T1: admin wrapper cross-agent text was REFUSED — the exemption did not pass (admin id lost across exec). This is the #1474 regression."
fi
out_has_staging "$T1_OUT" \
  || smoke_fail "T1: admin wrapper cross-agent text did not route through the staging path (expected 'cron-staging' in output)"
smoke_log "ok: T1 — admin wrapper cross-agent text proceeded to staging (exemption passed across exec)"

# ---------------------------------------------------------------------------
# T2 — TEETH: non-admin / iso agent STILL gets the #1359 reject.
# ---------------------------------------------------------------------------
smoke_log "T2: non-admin/iso wrapper cross-agent --kind text MUST still be refused (#1359 gate intact)"

T2_OUT="$SMOKE_TMP_ROOT/t2.out"
run_wrapper_cron_create "$ISO_AGENT" "$PEER_AGENT" "text" "$T2_OUT" || true

out_has_reject "$T2_OUT" \
  || {
       smoke_log "T2 output:"
       while IFS= read -r _l; do smoke_log "  | $_l"; done <"$T2_OUT"
       smoke_fail "T2: non-admin/iso wrapper cross-agent text was NOT refused — the #1359 gate was weakened. The admin-id export must NOT let a non-admin agent pass the exemption."
     }
smoke_log "ok: T2 — non-admin/iso wrapper cross-agent text correctly refused (gate intact)"

# ---------------------------------------------------------------------------
# T3 — TEETH: admin cross-agent --kind shell stays blocked at the CLI guard.
# ---------------------------------------------------------------------------
smoke_log "T3: admin wrapper cross-agent --kind shell MUST still be refused (#1474 widens text only)"

T3_OUT="$SMOKE_TMP_ROOT/t3.out"
run_wrapper_cron_create "$ADMIN_AGENT" "$PEER_AGENT" "shell" "$T3_OUT" || true

out_has_reject "$T3_OUT" \
  || {
       smoke_log "T3 output:"
       while IFS= read -r _l; do smoke_log "  | $_l"; done <"$T3_OUT"
       smoke_fail "T3: admin wrapper cross-agent SHELL was NOT refused — shell-kind cross-agent staging must stay out of scope."
     }
smoke_log "ok: T3 — admin wrapper cross-agent shell correctly refused (text-only exemption)"

smoke_log "PASS: #1474 wrapper-path admin cron exemption — works for admin, gate intact for non-admin + shell"
