#!/usr/bin/env bash
# scripts/smoke/1427-A-roster-materialize.sh — template-sync Lane A (#1427).
#
# Pins the two Contract-II + Contract-I deliverables of the roster
# materialize writer and the `agent create` defaults-profile consumption:
#
#   T1 (writer / roster-only). `agent roster materialize-fields` writes the
#      named roster dimensions into the managed block and NEVER creates or
#      mutates a .claude/settings.json (the sync target is the ROSTER, not
#      settings.json — model/effort/pm are launch flags, settings.json is a
#      no-op for them).
#   T2 (multi-field atomic + preserve). A single materialize call writes
#      multiple dimensions at once AND leaves every unrelated managed-role
#      field (engine / workdir / launch_cmd / description / continue) intact.
#   T3 (legacy refused). `--permission-mode legacy` is rejected non-zero and
#      writes nothing.
#   T4 (idempotent). Re-running the same materialize is a no-op (exit 0,
#      "materialize: no-op", roster byte-identical).
#   T5 (create reads profile). With a defaults-profile block present,
#      `agent create newA --dry-run` shows the new agent will get EXPLICIT
#      model/effort/plugins/skills rows (not the implicit legacy-launch
#      fallback); a real create materializes them and the new agent's own
#      explicit --model wins over the profile.
#   T6 (safety invariant). An EXISTING agent created with no model/effort/pm
#      and no profile is UNCHANGED and still resolves the legacy-launch
#      shape (bridge_agent_uses_legacy_launch_flags true → launch cmd has
#      --dangerously-skip-permissions and no --model). The profile is never
#      consulted by the live accessors.
#
# Caller-source trust is forced via BRIDGE_CALLER_SOURCE=operator-tui so the
# smoke does not depend on a real TTY. Per footgun #11 the inline parsing
# uses `python3 -c '<script>' <argv>` (no `<<PY` heredoc-stdin).

set -euo pipefail

SMOKE_NAME="1427-A-roster-materialize"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash

BA() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" "$@"
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  : >"$BRIDGE_AUDIT_LOG"
}

# Extract a single managed-role field value from the roster file, e.g.
# `roster_field alpha BRIDGE_AGENT_MODEL` -> the model string (or "" if the
# line is absent). python3 -c argv form (footgun #11).
roster_field() {
  local agent="$1"
  local var="$2"
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
    rhs = fm.group(1)
    try:
        parts = shlex.split(rhs)
        print(parts[0] if parts else "")
    except ValueError:
        print(rhs)
' "$BRIDGE_ROSTER_LOCAL_FILE" "$agent" "$var"
}

roster_sha() {
  python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Count every settings.json under the bridge home + data root (the writer
# must never create one).
settings_json_count() {
  python3 -c '
import os, sys
n = 0
for root in sys.argv[1:]:
    for dirpath, _dirs, files in os.walk(root):
        n += sum(1 for f in files if f == "settings.json")
print(n)
' "$BRIDGE_HOME" "$BRIDGE_DATA_ROOT"
}

create_agent() {
  # Plain create with no model/effort/pm flags unless passed.
  BA create "$@" >/dev/null 2>&1
}

test_writer_roster_only_never_settings() {
  reset_runtime
  create_agent wr1 --engine claude
  local before_settings
  before_settings="$(settings_json_count)"

  local out
  out="$(BA roster materialize-fields wr1 --model claude-opus-4-8 --effort xhigh 2>&1)"
  smoke_assert_contains "$out" "materialize: ok" "writer reports ok"

  smoke_assert_eq "claude-opus-4-8" "$(roster_field wr1 BRIDGE_AGENT_MODEL)" "model written to roster"
  smoke_assert_eq "xhigh" "$(roster_field wr1 BRIDGE_AGENT_EFFORT)" "effort written to roster"

  # The materialize call must not have created any settings.json.
  smoke_assert_eq "$before_settings" "$(settings_json_count)" "no settings.json created by materialize"
}

test_multi_field_atomic_preserves_unrelated() {
  reset_runtime
  create_agent wr2 --engine claude --description "wr2 role" --no-continue

  local before_engine before_continue before_launch
  before_engine="$(roster_field wr2 BRIDGE_AGENT_ENGINE)"
  before_continue="$(roster_field wr2 BRIDGE_AGENT_CONTINUE)"
  before_launch="$(roster_field wr2 BRIDGE_AGENT_LAUNCH_CMD)"

  BA roster materialize-fields wr2 \
    --model claude-opus-4-8 --effort xhigh --permission-mode auto \
    --plugins cosmax-crm,playwright --skills foo,bar >/dev/null 2>&1

  smoke_assert_eq "claude-opus-4-8" "$(roster_field wr2 BRIDGE_AGENT_MODEL)" "atomic: model"
  smoke_assert_eq "xhigh" "$(roster_field wr2 BRIDGE_AGENT_EFFORT)" "atomic: effort"
  smoke_assert_eq "auto" "$(roster_field wr2 BRIDGE_AGENT_PERMISSION_MODE)" "atomic: permission_mode"
  smoke_assert_eq "cosmax-crm,playwright" "$(roster_field wr2 BRIDGE_AGENT_PLUGINS)" "atomic: plugins"
  smoke_assert_eq "foo,bar" "$(roster_field wr2 BRIDGE_AGENT_SKILLS)" "atomic: skills"

  # Unrelated fields preserved byte-for-byte.
  smoke_assert_eq "$before_engine" "$(roster_field wr2 BRIDGE_AGENT_ENGINE)" "preserve: engine"
  smoke_assert_eq "$before_continue" "$(roster_field wr2 BRIDGE_AGENT_CONTINUE)" "preserve: continue"
  smoke_assert_eq "$before_launch" "$(roster_field wr2 BRIDGE_AGENT_LAUNCH_CMD)" "preserve: launch_cmd"
}

test_legacy_refused() {
  reset_runtime
  create_agent wr3 --engine claude
  local before_sha
  before_sha="$(roster_sha)"

  local rc=0 out
  set +e
  out="$(BA roster materialize-fields wr3 --permission-mode legacy 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "expected non-zero exit for --permission-mode legacy; out=$out"
  fi
  smoke_assert_contains "$out" "legacy" "refusal mentions legacy"
  smoke_assert_eq "$before_sha" "$(roster_sha)" "roster unchanged after legacy refusal"
  smoke_assert_eq "" "$(roster_field wr3 BRIDGE_AGENT_PERMISSION_MODE)" "no permission_mode line written"
}

test_idempotent_no_op() {
  reset_runtime
  create_agent wr4 --engine claude
  BA roster materialize-fields wr4 --model claude-opus-4-8 --effort xhigh >/dev/null 2>&1
  local sha_after_first
  sha_after_first="$(roster_sha)"

  local out
  out="$(BA roster materialize-fields wr4 --model claude-opus-4-8 --effort xhigh 2>&1)"
  smoke_assert_contains "$out" "materialize: no-op" "second run is a no-op"
  smoke_assert_eq "$sha_after_first" "$(roster_sha)" "roster byte-identical on idempotent re-run"
}

test_create_reads_profile() {
  reset_runtime
  create_agent base --engine claude

  # Append a Contract-I defaults-profile block (the shared format Lane B
  # writes / Lane C documents). python3 -c writer (footgun #11).
  python3 -c '
import sys
block = """
# === agb:template-defaults v1 (managed by `setup template-sync`) ===
# source_agent=base updated_at=2026-05-31T00:00:00Z included=model,effort,plugins,skills excluded=channels,permission_mode
BRIDGE_TEMPLATE_DEFAULT_MODEL="claude-opus-4-8"
BRIDGE_TEMPLATE_DEFAULT_EFFORT="xhigh"
BRIDGE_TEMPLATE_DEFAULT_PLUGINS="cosmax-crm,playwright"
BRIDGE_TEMPLATE_DEFAULT_SKILLS="alpha-skill,beta-skill"
# === end agb:template-defaults ===
"""
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(block)
' "$BRIDGE_ROSTER_LOCAL_FILE"

  # --dry-run shows the explicit rows it would materialize from the profile.
  local dry
  dry="$(BA create newA --engine claude --dry-run 2>&1)"
  smoke_assert_contains "$dry" "dry_run: yes" "create dry-run flagged"
  smoke_assert_contains "$dry" "materialize_model: claude-opus-4-8" "dry-run shows profile model row"
  smoke_assert_contains "$dry" "materialize_effort: xhigh" "dry-run shows profile effort row"
  smoke_assert_contains "$dry" "materialize_plugins: cosmax-crm,playwright" "dry-run shows profile plugins row"
  smoke_assert_contains "$dry" "materialize_skills: alpha-skill,beta-skill" "dry-run shows profile skills row"
  # The dry-run wrote nothing — newA is not in the roster.
  smoke_assert_eq "" "$(roster_field newA BRIDGE_AGENT_MODEL)" "dry-run wrote no roster fields"

  # Real create: profile materialized AND explicit --model wins over profile.
  BA create newB --engine claude --model claude-sonnet-4-5 >/dev/null 2>&1
  smoke_assert_eq "claude-sonnet-4-5" "$(roster_field newB BRIDGE_AGENT_MODEL)" "explicit --model wins over profile"
  smoke_assert_eq "xhigh" "$(roster_field newB BRIDGE_AGENT_EFFORT)" "profile effort materialized when not explicit"
  smoke_assert_eq "cosmax-crm,playwright" "$(roster_field newB BRIDGE_AGENT_PLUGINS)" "profile plugins materialized"
  smoke_assert_eq "alpha-skill,beta-skill" "$(roster_field newB BRIDGE_AGENT_SKILLS)" "profile skills materialized"
}

test_safety_invariant_legacy_launch_unchanged() {
  reset_runtime
  # No profile present, plain create, no model/effort/pm flags.
  create_agent leg --engine claude

  # The agent must have NO model/effort/pm roster lines — it stays on the
  # legacy-launch contract.
  smoke_assert_eq "" "$(roster_field leg BRIDGE_AGENT_MODEL)" "legacy agent: no model line"
  smoke_assert_eq "" "$(roster_field leg BRIDGE_AGENT_EFFORT)" "legacy agent: no effort line"
  smoke_assert_eq "" "$(roster_field leg BRIDGE_AGENT_PERMISSION_MODE)" "legacy agent: no permission_mode line"

  # And it resolves the legacy-launch shape. bridge-run.sh --dry-run prints
  # the resolved engine launch argv (`launch=...`) the daemon would use; a
  # legacy agent's claude launch carries --dangerously-skip-permissions and
  # no --model / --effort / --permission-mode flag (the empty roster fields
  # keep bridge_agent_uses_legacy_launch_flags true).
  local run_out
  run_out="$(BRIDGE_CALLER_SOURCE=operator-tui bash "$SMOKE_REPO_ROOT/bridge-run.sh" leg --dry-run </dev/null 2>/dev/null || true)"
  local launch_line
  launch_line="$(printf '%s\n' "$run_out" | sed -n 's/^launch=//p' | head -n 1)"
  smoke_assert_contains "$launch_line" "--dangerously-skip-permissions" "legacy launch keeps --dangerously-skip-permissions"
  smoke_assert_not_contains "$launch_line" "--model" "legacy launch carries no --model flag"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  # CI runners ship no engine npm package; `agent create --engine <e>` runs a
  # `command -v <e>` pre-flight (#1317-C) that hard-dies otherwise. Seed
  # executable engine stubs + prepend to PATH (the agent-doctor #1397 pattern).
  _stub_engine_dir="$SMOKE_TMP_ROOT/stub-engine-bin"
  mkdir -p "$_stub_engine_dir"
  for _eng in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$_stub_engine_dir/$_eng"
    chmod +x "$_stub_engine_dir/$_eng"
  done
  export PATH="$_stub_engine_dir:$PATH"

  smoke_run "writer is roster-only, never settings.json"         test_writer_roster_only_never_settings
  smoke_run "multi-field atomic + preserves unrelated fields"     test_multi_field_atomic_preserves_unrelated
  smoke_run "--permission-mode legacy refused"                    test_legacy_refused
  smoke_run "idempotent no-op on re-run"                          test_idempotent_no_op
  smoke_run "create reads defaults profile (explicit wins)"       test_create_reads_profile
  smoke_run "safety invariant: legacy-launch agent unchanged"     test_safety_invariant_legacy_launch_unchanged
  smoke_log "passed"
}

main "$@"
