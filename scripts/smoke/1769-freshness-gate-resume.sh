#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1769-freshness-gate-resume.sh — Issue #1769 mechanism 2.
#
# The setup-freshness gate in bridge-start.sh used to SILENTLY drop a
# perfectly resumable Claude session whenever ANY of its checks tripped
# (bridge_project_claude_guidance_needed / skill-bootstrap / the five
# stop/session-start/prompt/prompt-guard/tool-policy hook status checks).
# It set FORCE_FRESH_SESSION=1 → EFFECTIVE_CONTINUE_MODE=0 → --no-continue,
# overriding whatever the resolver found. On normal restart flows the
# discard was invisible (the only visible warning fired when the operator
# explicitly passed --continue), so a controller-side settings re-render
# would silently launch every agent's NEXT restart fresh — discarding
# multi-MB live transcripts fleet-wide (issue follow-up comments, 2026-06-10).
#
# This smoke drives the REAL gate in bridge-start.sh (via `<agent> --dry-run`,
# which runs the full gate + ensure pass and prints `continue=N` + the
# bridge-run.sh resume verb without launching tmux). A synthesized
# agent-roster.local.sh (written by the sidecar helper) redefines the seven
# check functions and bridge_claude_resume_session_id_for_agent so the
# gate's inputs are deterministic and the run is hermetic.
#
# Test plan:
#   (a) resumable id + a re-ensurable check trip (guidance) → resume KEPT
#       (continue=1, `--continue`), one diagnostic line naming the check.
#   (b) NO resumable id + same trip → fresh (continue=0, `--no-continue`,
#       unchanged behavior) + a diagnostic line naming the check.
#   (c) resumable id + the SAME trip under `--skip-project-skill` (the
#       guidance/skill artifacts are NOT re-rendered this run → genuinely
#       fresh-required) → fresh (continue=0) + a "fresh-required" log line.
#   (d) clean checks + resumable id → resume (continue=1, `--continue`),
#       and NO #1769 diagnostics (byte-identical decision, no new noise).
#   (e) teeth: pin the downgrade seam (resolvable-id probe + the
#       FORCE_FRESH_SESSION=0 reset) textually so its removal — which would
#       silently regress (a) to the pre-#1769 unconditional fresh discard —
#       fails this smoke loudly.

set -euo pipefail

SMOKE_NAME="1769-freshness-gate-resume"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPERS_DIR="$SCRIPT_DIR/1769-freshness-gate-resume-helpers"
WRITE_ROSTER="$HELPERS_DIR/write-gate-roster.sh"
AGENT="gate-ca"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Run bridge-start.sh <agent> --dry-run for the synthesized agent with the
# requested gate inputs. Captures stdout (continue=/tmux line) and stderr
# (diagnostics) into caller-named vars via global GATE_STDOUT / GATE_STDERR.
gate_dry_run() {
  local guidance_rc="$1"
  local resume_id="$2"
  local skip_skill="${3:-0}"
  local workdir="$BRIDGE_AGENT_HOME_ROOT/$AGENT/workdir"
  local err_file="$SMOKE_TMP_ROOT/gate.err"
  local -a args=("$AGENT" --dry-run)

  mkdir -p "$workdir"
  bash "$WRITE_ROSTER" "$BRIDGE_ROSTER_LOCAL_FILE" "$workdir" "$AGENT" \
    "$guidance_rc" "$resume_id"
  [[ "$skip_skill" == "1" ]] && args+=(--skip-project-skill)

  GATE_STDOUT="$(bash "$SMOKE_REPO_ROOT/bridge-start.sh" "${args[@]}" \
    2>"$err_file")"
  GATE_STDERR="$(cat "$err_file" 2>/dev/null || true)"
}

case_resumable_re_ensurable_keeps_resume() {
  gate_dry_run 0 "RESUME-A1" 0
  local continue_field
  continue_field="$(smoke_shell_field continue "$GATE_STDOUT")"
  smoke_assert_eq "1" "$continue_field" \
    "(a) resumable id + re-ensurable trip keeps continue=1"
  smoke_assert_contains "$GATE_STDOUT" "bridge-run.sh $AGENT --continue --once" \
    "(a) resume verb is --continue"
  smoke_assert_contains "$GATE_STDERR" "claude_guidance_needed" \
    "(a) diagnostic names the tripped check"
  smoke_assert_contains "$GATE_STDERR" "resuming session_id=RESUME-A1" \
    "(a) diagnostic reports the resumed id"
}

case_no_resumable_id_forces_fresh() {
  gate_dry_run 0 "" 0
  local continue_field
  continue_field="$(smoke_shell_field continue "$GATE_STDOUT")"
  smoke_assert_eq "0" "$continue_field" \
    "(b) no resumable id falls through to fresh (continue=0)"
  smoke_assert_contains "$GATE_STDOUT" "bridge-run.sh $AGENT --no-continue --once" \
    "(b) fresh verb is --no-continue"
  smoke_assert_contains "$GATE_STDERR" "claude_guidance_needed" \
    "(b) fresh discard is no longer silent — names the check"
}

case_fresh_required_check_forces_fresh() {
  # --skip-project-skill: the guidance/skill re-render is skipped this run,
  # so the corrected artifact is NOT in place for the relaunch → the trip is
  # genuinely fresh-required even though a resume id is resolvable.
  gate_dry_run 0 "RESUME-C1" 1
  local continue_field
  continue_field="$(smoke_shell_field continue "$GATE_STDOUT")"
  smoke_assert_eq "0" "$continue_field" \
    "(c) fresh-required check forces fresh even with a resumable id"
  smoke_assert_contains "$GATE_STDOUT" "bridge-run.sh $AGENT --no-continue --once" \
    "(c) fresh verb is --no-continue"
  smoke_assert_contains "$GATE_STDERR" "fresh-required" \
    "(c) diagnostic classifies the check as fresh-required"
}

case_clean_checks_resume_no_noise() {
  gate_dry_run 1 "RESUME-D1" 0
  local continue_field
  continue_field="$(smoke_shell_field continue "$GATE_STDOUT")"
  smoke_assert_eq "1" "$continue_field" \
    "(d) clean checks keep continue=1"
  smoke_assert_contains "$GATE_STDOUT" "bridge-run.sh $AGENT --continue --once" \
    "(d) resume verb is --continue"
  smoke_assert_not_contains "$GATE_STDERR" "#1769" \
    "(d) clean checks emit no #1769 diagnostics"
}

case_teeth_downgrade_seam_present() {
  # Teeth: the resume-survival behavior asserted in (a) depends on the
  # downgrade seam in bridge-start.sh — the resolvable-id probe + the
  # FORCE_FRESH_SESSION=0 reset. If a future edit drops either, (a) would
  # silently regress to the pre-#1769 unconditional fresh discard. Pin the
  # seam textually so its removal fails this smoke loudly (mirrors the
  # A3-beta3-1248 T6 source-presence guard).
  local src="$SMOKE_REPO_ROOT/bridge-start.sh"
  grep -q 'bridge_claude_resume_session_id_for_agent "\$AGENT"' "$src" \
    || smoke_fail "(e) teeth: resolvable-id probe missing from bridge-start.sh gate"
  grep -q 'FORCE_FRESH_SESSION=0' "$src" \
    || smoke_fail "(e) teeth: gate downgrade reset (FORCE_FRESH_SESSION=0) missing"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "(a) resumable id + re-ensurable trip keeps resume" \
    case_resumable_re_ensurable_keeps_resume
  smoke_run "(b) no resumable id still forces fresh" \
    case_no_resumable_id_forces_fresh
  smoke_run "(c) fresh-required check forces fresh" \
    case_fresh_required_check_forces_fresh
  smoke_run "(d) clean checks resume with no new noise" \
    case_clean_checks_resume_no_noise
  smoke_run "(e) teeth: downgrade seam present in bridge-start.sh" \
    case_teeth_downgrade_seam_present
  smoke_log "passed"
}

main "$@"
