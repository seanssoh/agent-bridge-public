#!/usr/bin/env bash
# scripts/smoke/admin-codex-pair.sh — Issue #517 smoke.
#
# Validates:
# 1. bridge-upgrade.py inject-admin-pair-block injects the managed block
#    into a fixture admin's CLAUDE.md.
# 2. Re-running is a no-op (changed=false on second run).
# 3. Operator overlay outside the managed block is preserved across reruns.
# 4. The pre-existing AGENT BRIDGE DOC MIGRATION block is preserved
#    (regression check on the generalized refresh helper).
# 5. The bash-side managed block (bridge_admin_pair_managed_block) and the
#    python-side managed block (render_admin_pair_block) are byte-identical
#    when invoked with the same admin name — preserves the fresh-install
#    vs upgrade-install convergence contract.
#
# This smoke does NOT exercise `bridge-init.sh`/`bridge-upgrade.sh` end-to-end
# — those require a real Claude/Codex CLI on PATH and live tmux. The
# integration is covered by ci-select-smoke routing the existing `upgrade`
# smoke + this targeted contract check on the helpers themselves.

set -euo pipefail

SMOKE_NAME="admin-codex-pair"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=lib/bridge-admin-pair.sh
source "$SMOKE_REPO_ROOT/lib/bridge-admin-pair.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
ADMIN_CODEX="testadmincodex"
SENTINEL_LINE="<!-- operator-note: smoke-${RANDOM}-${RANDOM} -->"
PRE_EXISTING_MIGRATION_LINE="## Agent Bridge Runtime Canon"

write_admin_fixture() {
  local admin_home="$BRIDGE_AGENT_HOME_ROOT/$ADMIN"
  mkdir -p "$admin_home"
  cat >"$admin_home/CLAUDE.md" <<'EOF'
# testadmin — Admin Role

<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
## Agent Bridge Runtime Canon
- existing migration block content kept by the generalized refresh helper.
<!-- END AGENT BRIDGE DOC MIGRATION -->

너는 testadmin이야. 운영 contract.

EOF
  printf '%s\n' "$SENTINEL_LINE" >>"$admin_home/CLAUDE.md"
}

inject_block() {
  python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" inject-admin-pair-block \
    --target-root "$BRIDGE_HOME" \
    --admin-agent "$ADMIN"
}

assert_first_inject_writes_block() {
  local output changed claude_path content
  output="$(inject_block)"
  changed="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["changed"])')"
  smoke_assert_eq "True" "$changed" "first inject reports changed=true"

  claude_path="$BRIDGE_AGENT_HOME_ROOT/$ADMIN/CLAUDE.md"
  content="$(cat "$claude_path")"
  smoke_assert_contains "$content" "<!-- BEGIN MANAGED:admin-pair-programming -->" "block start marker present"
  smoke_assert_contains "$content" "<!-- END MANAGED:admin-pair-programming -->" "block end marker present"
  smoke_assert_contains "$content" "${ADMIN}-dev" "pair name substituted into block"
  smoke_assert_contains "$content" "$PRE_EXISTING_MIGRATION_LINE" "pre-existing migration block preserved after inject"
  smoke_assert_contains "$content" "$SENTINEL_LINE" "operator overlay sentinel preserved after inject"
}

assert_second_inject_is_noop() {
  local output changed
  output="$(inject_block)"
  changed="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["changed"])')"
  smoke_assert_eq "False" "$changed" "second inject reports changed=false (idempotent)"
}

assert_dry_run_does_not_mutate() {
  local before after output
  local claude_path="$BRIDGE_AGENT_HOME_ROOT/$ADMIN/CLAUDE.md"

  # Force a drift so dry-run has something to report.
  python3 - "$claude_path" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text = text.replace("Pair Programming Protocol", "PAIR PROGRAMMING (drifted)", 1)
p.write_text(text, encoding="utf-8")
PY
  before="$(cat "$claude_path")"
  output="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" inject-admin-pair-block \
    --target-root "$BRIDGE_HOME" --admin-agent "$ADMIN" --dry-run)"
  after="$(cat "$claude_path")"
  smoke_assert_eq "$before" "$after" "dry-run does not mutate file"
  printf '%s' "$output" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
assert payload["dry_run"] is True, payload
assert payload["changed"] is True, payload
'
}

assert_missing_admin_home_is_skip() {
  local output skipped
  output="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" inject-admin-pair-block \
    --target-root "$BRIDGE_HOME" --admin-agent "ghostadmin")"
  skipped="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("skipped",""))')"
  smoke_assert_eq "admin CLAUDE.md missing" "$skipped" "missing admin home is skipped, not failed"
}

# Issue #517 r1 finding 2: bridge-init.sh dropped the engine=="claude" gate
# so codex admins also get the SOP block. The python inject path was already
# engine-agnostic by code reading; this fixture pins that contract — a
# CLAUDE.md authored as a codex admin still receives the same managed block
# markers + pair-name substitution after inject.
write_codex_admin_fixture() {
  local admin_home="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_CODEX"
  mkdir -p "$admin_home"
  cat >"$admin_home/CLAUDE.md" <<'EOF'
# testadmincodex — Admin Role (Codex CLI)

너는 testadmincodex이야. Codex CLI로 동작하는 admin.

EOF
}

assert_codex_admin_inject_writes_block() {
  local output changed claude_path content
  output="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" inject-admin-pair-block \
    --target-root "$BRIDGE_HOME" --admin-agent "$ADMIN_CODEX")"
  changed="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["changed"])')"
  smoke_assert_eq "True" "$changed" "codex-admin inject reports changed=true"

  claude_path="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_CODEX/CLAUDE.md"
  content="$(cat "$claude_path")"
  smoke_assert_contains "$content" "<!-- BEGIN MANAGED:admin-pair-programming -->" "codex-admin block start marker present"
  smoke_assert_contains "$content" "<!-- END MANAGED:admin-pair-programming -->" "codex-admin block end marker present"
  smoke_assert_contains "$content" "${ADMIN_CODEX}-dev" "codex-admin pair name substituted into block"
}

assert_bash_python_blocks_byte_identical() {
  local bash_block python_block
  bash_block="$(bridge_admin_pair_managed_block "$ADMIN")"
  # Load bridge-upgrade.py under a Python-legal module name so the embedded
  # dataclass does not trip __module__ lookups (hyphens in spec name break
  # `sys.modules.get(cls.__module__)` on py3.9 stdlib dataclasses).
  python_block="$(BRIDGE_UPGRADE_PATH="$SMOKE_REPO_ROOT/bridge-upgrade.py" SMOKE_ADMIN="$ADMIN" python3 -c '
import importlib.util, os, sys
path = os.environ["BRIDGE_UPGRADE_PATH"]
admin = os.environ["SMOKE_ADMIN"]
spec = importlib.util.spec_from_file_location("bridge_upgrade", path)
module = importlib.util.module_from_spec(spec)
sys.modules["bridge_upgrade"] = module
spec.loader.exec_module(module)
print(module.render_admin_pair_block(admin))
')"
  if [[ "$bash_block" != "$python_block" ]]; then
    smoke_log "bash block:"
    printf '%s\n' "$bash_block" | sed 's/^/  /' >&2
    smoke_log "python block:"
    printf '%s\n' "$python_block" | sed 's/^/  /' >&2
    smoke_fail "bash and python managed-block content drifted (issue #517 contract)"
  fi
}

assert_pair_name_helper() {
  local got
  got="$(bridge_admin_pair_name "$ADMIN")"
  smoke_assert_eq "${ADMIN}-dev" "$got" "bridge_admin_pair_name returns <admin>-dev"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "admin-codex-pair"
  write_admin_fixture
  write_codex_admin_fixture
  smoke_run "pair name helper" assert_pair_name_helper
  smoke_run "bash and python managed blocks are byte-identical" assert_bash_python_blocks_byte_identical
  smoke_run "first inject writes block + preserves overlay" assert_first_inject_writes_block
  smoke_run "second inject is a no-op (idempotent)" assert_second_inject_is_noop
  smoke_run "dry-run reports change without mutating" assert_dry_run_does_not_mutate
  smoke_run "missing admin home is skipped, not failed" assert_missing_admin_home_is_skip
  smoke_run "codex-admin inject writes block (engine-neutral)" assert_codex_admin_inject_writes_block
  smoke_log "passed"
}

main "$@"
