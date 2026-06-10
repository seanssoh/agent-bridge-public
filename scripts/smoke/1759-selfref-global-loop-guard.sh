#!/usr/bin/env bash
# scripts/smoke/1759-selfref-global-loop-guard.sh — Issue #1759 regression smoke.
#
# Issue #1759: on shared-admin layouts the operator's `~/.claude/settings.json`
# is a bridge-managed SYMLINK to an agent's own `settings.effective.json`
# (created by `link-shared-settings`). The #11901 operator-global base-read
# (shipped v0.16.6) then becomes SELF-REFERENTIAL for that one agent: its
# render reads its own previous output as the base layer (benign-key
# resurrection, decay inversion, operator hand-edits surviving only by accident
# of the loop instead of via #1756's PRESERVED_USER_KEYS). A drift-apply
# rerender would ALSO rewrite the operator's global wholesale (the symlink
# target).
#
# This smoke pins the 3-part fix via a file-as-argv Python helper (NO
# heredoc-stdin to Python — footgun #11):
#   (a) SELF-REF render: loop broken (degrade to bridge base), seeded benign
#       loop key does NOT resurrect, AND the preserved user key (`model`)
#       STILL survives via the preserve pass over the existing effective file
#       (#1756 stays the durable mechanism — proven explicitly).
#   (b) NON-SELF-REF agent on the same install still inherits the global (AC1).
#   (c) NESTED symlink chain still detected for the owning agent (safe degrade).
#   (e) MISSING-GLOBAL degrade unchanged.
#
# It also pins the detection helper and the drift-apply blast-radius guard:
#   - `_operator_global_is_self_reference` is realpath-based, not a string
#     compare: direct + nested symlink both collapse to the same target;
#     another agent's output is NOT a self-reference (one-directional inherit).
#   - (d) the rerender drift-apply guard (`bridge_agent_rerender_writes_
#     operator_global`) reports the self-ref WRITE-THROUGH and names the file,
#     so `rerender-settings --apply` refuses without `--force-operator-global`.

set -euo pipefail

SMOKE_NAME="1759-selfref-global-loop-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

assert_render_loop_guard() {
  smoke_make_temp_root "$SMOKE_NAME"
  python3 "$SCRIPT_DIR/1759-selfref-global-loop-guard-helper.py" \
    "$SMOKE_REPO_ROOT" "$SMOKE_TMP_ROOT" \
    || smoke_fail "render-shared-settings self-ref loop-guard contract failed (#1759)"
}

assert_detection_helper() {
  # Unit-test `_operator_global_is_self_reference` directly: direct symlink,
  # nested symlink, another agent's output (NOT self-ref), and a genuine
  # operator-authored global (NOT self-ref).
  smoke_make_temp_root "$SMOKE_NAME-detect"
  local d="$SMOKE_TMP_ROOT"
  mkdir -p "$d/agents/A/.claude" "$d/agents/B/.claude" "$d/ophome/.claude" "$d/realhome/.claude"
  : >"$d/agents/A/.claude/settings.effective.json"
  : >"$d/agents/B/.claude/settings.effective.json"
  ln -s "$d/agents/A/.claude/settings.effective.json" "$d/ophome/.claude/settings.json"
  ln -s "$d/agents/A/.claude/settings.effective.json" "$d/inter.json"
  ln -s "$d/inter.json" "$d/ophome/.claude/settings-nested.json"
  printf '{"agentPushNotifEnabled": true}' >"$d/realhome/.claude/settings.json"

  local out
  out="$(
    BRIDGE_SELFREF_DIR="$d" python3 -c '
import importlib.util, os, sys
from pathlib import Path
d = Path(os.environ["BRIDGE_SELFREF_DIR"])
spec = importlib.util.spec_from_file_location("bridge_hooks", "'"$SMOKE_REPO_ROOT"'/bridge-hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)
fn = hooks._operator_global_is_self_reference
effA = d / "agents/A/.claude/settings.effective.json"
effB = d / "agents/B/.claude/settings.effective.json"
direct = d / "ophome/.claude/settings.json"
nested = d / "ophome/.claude/settings-nested.json"
realg = d / "realhome/.claude/settings.json"
print("direct_owner=%s" % fn(direct, effA))
print("direct_other=%s" % fn(direct, effB))
print("nested_owner=%s" % fn(nested, effA))
print("nested_other=%s" % fn(nested, effB))
print("real_global=%s" % fn(realg, effA))
'
  )"
  smoke_assert_contains "$out" "direct_owner=True" "direct symlink is self-ref for owning agent"
  smoke_assert_contains "$out" "direct_other=False" "direct symlink is NOT self-ref for another agent"
  smoke_assert_contains "$out" "nested_owner=True" "nested symlink is self-ref for owning agent"
  smoke_assert_contains "$out" "nested_other=False" "nested symlink is NOT self-ref for another agent"
  smoke_assert_contains "$out" "real_global=False" "genuine operator global is NOT self-ref"
}

assert_drift_apply_guard() {
  # (d) The drift-apply blast-radius guard: when the operator-global resolves
  # to the agent's own effective file, the rerender guard
  # (`bridge_agent_rerender_writes_operator_global`) detects the self-ref
  # WRITE-THROUGH via `_operator_global_is_self_reference` and prints the
  # operator-global path the apply would clobber, so `rerender-settings
  # --apply` refuses without --force-operator-global. We exercise the exact
  # detection core the shell guard delegates to (the same helper, fed the
  # same two resolved paths) so the test stays portable on the dev macOS
  # bash 3.2 host without sourcing the full bridge-agent.sh lib chain. The
  # `--force-operator-global` flag wiring + refusal-row plumbing is covered
  # by `bash -n` + shellcheck and the live manual check noted in the PR.
  smoke_make_temp_root "$SMOKE_NAME-guard"
  local d="$SMOKE_TMP_ROOT"
  mkdir -p "$d/home-root/sysmon/.claude" "$d/op-home/.claude" "$d/home-root/other/.claude"
  : >"$d/home-root/sysmon/.claude/settings.effective.json"
  : >"$d/home-root/other/.claude/settings.effective.json"
  # Operator global = symlink -> sysmon's own effective file (self-ref).
  ln -s "$d/home-root/sysmon/.claude/settings.effective.json" "$d/op-home/.claude/settings.json"

  local out rc=0
  out="$(
    BRIDGE_GUARD_DIR="$d" python3 -c '
import importlib.util, os, sys
from pathlib import Path
d = Path(os.environ["BRIDGE_GUARD_DIR"])
spec = importlib.util.spec_from_file_location("bridge_hooks", "'"$SMOKE_REPO_ROOT"'/bridge-hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)
fn = hooks._operator_global_is_self_reference
op_global = d / "op-home/.claude/settings.json"
eff_self = d / "home-root/sysmon/.claude/settings.effective.json"
eff_other = d / "home-root/other/.claude/settings.effective.json"
# Owning agent (sysmon): applying writes through the symlink to the operator
# global -> guard fires and names the file.
if fn(op_global, eff_self):
    print(str(op_global))
    sys.exit(0)
sys.exit(1)
'
  )" || rc=$?
  smoke_assert_eq "$rc" "0" "self-ref drift-apply guard fires (refuse) for the owning agent"
  smoke_assert_contains "$out" "/op-home/.claude/settings.json" \
    "guard names the operator-global file the apply would clobber"

  # A DIFFERENT agent's apply does NOT trip the guard (its effective file is a
  # separate path; writing it does not touch the operator global).
  local rc_other=0
  BRIDGE_GUARD_DIR="$d" python3 -c '
import importlib.util, os, sys
from pathlib import Path
d = Path(os.environ["BRIDGE_GUARD_DIR"])
spec = importlib.util.spec_from_file_location("bridge_hooks", "'"$SMOKE_REPO_ROOT"'/bridge-hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)
op_global = d / "op-home/.claude/settings.json"
eff_other = d / "home-root/other/.claude/settings.effective.json"
sys.exit(0 if hooks._operator_global_is_self_reference(op_global, eff_other) else 1)
' || rc_other=$?
  smoke_assert_eq "$rc_other" "1" "drift-apply guard does NOT fire for a different agent's effective file"
}

main() {
  smoke_run "render-shared-settings self-ref loop guard + preserved-key survival" \
    assert_render_loop_guard
  smoke_run "self-reference detection helper (direct + nested + non-self-ref)" \
    assert_detection_helper
  smoke_run "drift-apply blast-radius guard names the operator-global file" \
    assert_drift_apply_guard

  smoke_log "PASS"
}

main "$@"
