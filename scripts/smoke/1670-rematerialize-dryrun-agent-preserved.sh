#!/usr/bin/env bash
# 1670-rematerialize-dryrun-agent-preserved.sh
#
# Issue #1670: rematerialize-agent-identity.sh emitted `agent="" + usage` in the
# upgrade dry-run JSON for EVERY agent. Root cause: the helper did `shift 5`
# BEFORE sourcing bridge-lib.sh, which performs a Bash 3.2 -> 4+ re-exec
# (`exec "$cand" -p "$target_script" "$@"`, #1454). The stock macOS shebang
# `#!/usr/bin/env bash` resolves to /bin/bash 3.2 when Homebrew bash is not first
# on PATH, so when bridge-upgrade.py invokes the helper by argv that re-exec
# fires — and `$@` had already been shifted down to only the changed-file tail,
# so the re-run landed the changed files in the mandatory slots and blanked the
# agent (-z guard fired -> `agent=""` + usage). The boundary invariant: the
# agent must be PRESERVED across the dry-run re-exec boundary, with NO usage
# error, even when ZERO changed files are passed.
#
# This regression pins three things:
#   1. The helper run under Bash 3.2 (the REAL re-exec trigger) with valid 5 args
#      + ZERO changed files preserves the agent and emits no usage error.
#   2. The same holds with 5 args + changed files (the migrate-agents path).
#   3. The bridge-upgrade.py Python-side guard converts a payload whose agent is
#      blank / mismatched into a structured rematerialize error keyed on the
#      agent we actually asked for (never silently propagating agent="").

set -euo pipefail

SMOKE_NAME="1670-rematerialize-dryrun-agent-preserved"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/lib/upgrade-helpers/rematerialize-agent-identity.sh"

# A Bash 4+ shell (always required to drive the fixture).
BASH4=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
  if [[ -x "$c" ]] && "$c" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' 2>/dev/null; then
    BASH4="$c"; break
  fi
done
[[ -n "$BASH4" ]] || smoke_fail "no Bash 4+ found — cannot run $SMOKE_NAME"

# A Bash 3.2 (the real re-exec trigger). Present on macOS (/bin/bash), usually
# absent on Linux — there the re-exec path is a no-op and the Bash-4+ run below
# already exercises the (fixed) parse, so skip the 3.2-specific assertions.
BASH3=""
for c in /bin/bash /usr/bin/bash; do
  if [[ -x "$c" ]] && "$c" -c '[[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]' 2>/dev/null; then
    BASH3="$c"; break
  fi
done

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

setup_fixture() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_HOME/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

write_roster() {
  local agent="$1"
  {
    printf 'BRIDGE_AGENT_IDS=("%s" )\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

seed_agent() {
  local agent="$1"
  local source_marker="$2"
  local workdir_marker="$3"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  local dir="" marker=""
  mkdir -p "$BRIDGE_AGENT_ROOT_V2/$agent/home"
  for dir in "$profile:$source_marker" "$workdir:$workdir_marker"; do
    marker="${dir##*:}"
    dir="${dir%%:*}"
    mkdir -p "$dir"
    printf '# %s %s\n' "$agent" "$marker" >"$dir/CLAUDE.md"
    printf '# %s soul %s\n' "$agent" "$marker" >"$dir/SOUL.md"
    printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$dir/SESSION-TYPE.md"
    printf 'memory %s\n' "$marker" >"$dir/MEMORY.md"
  done
}

# Run the helper, return its last JSON line. $1 = bash binary, rest = helper argv.
run_helper_json() {
  local bash_bin="$1"; shift
  local out=""
  out="$("$bash_bin" "$HELPER" "$@" 2>/dev/null || true)"
  printf '%s' "$out" | tail -n 1
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | python3 -c '
import json
import sys

field = sys.argv[1]
try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("__PARSE_ERROR__")
    sys.exit(0)
value = payload.get(field, "")
if isinstance(value, (list, dict)):
    print(json.dumps(value))
else:
    print(value if value is not None else "")
' "$field"
}

# --- Test 1: Bash 3.2 re-exec boundary, valid 5 args + ZERO changed files ----
test_bash32_zero_changed_files_preserves_agent() {
  if [[ -z "$BASH3" ]]; then
    smoke_skip "bash3.2 zero-changed-files" "no Bash 3.2 available (re-exec path is a no-op on this host)"
    return 0
  fi
  setup_fixture
  write_roster boundary
  seed_agent boundary src-old workdir-stale

  local json=""
  json="$(run_helper_json "$BASH3" "$REPO_ROOT" "$BRIDGE_HOME" boundary claude 1)"
  smoke_assert_eq "boundary" "$(json_field "$json" agent)" \
    "bash3.2 zero-changed-files: agent must be preserved across the re-exec boundary (regression: was \"\")"
  smoke_assert_eq "planned" "$(json_field "$json" status)" \
    "bash3.2 zero-changed-files: dry-run status should be planned, not error"
  smoke_assert_not_contains "$json" "usage: rematerialize-agent-identity.sh" \
    "bash3.2 zero-changed-files: must NOT emit the usage error"
}

# --- Test 2: Bash 3.2 re-exec boundary, valid 5 args + changed files ---------
test_bash32_with_changed_files_preserves_agent() {
  if [[ -z "$BASH3" ]]; then
    smoke_skip "bash3.2 with-changed-files" "no Bash 3.2 available (re-exec path is a no-op on this host)"
    return 0
  fi
  setup_fixture
  write_roster boundary
  seed_agent boundary src-old workdir-stale

  local json=""
  # changed-file tail mirrors the migrate-agents payload that historically
  # landed `.claude/commands/wrap-up.md` in the source_root slot on re-exec.
  json="$(run_helper_json "$BASH3" "$REPO_ROOT" "$BRIDGE_HOME" boundary claude 1 \
    .claude/commands/wrap-up.md CLAUDE.md SOUL.md)"
  smoke_assert_eq "boundary" "$(json_field "$json" agent)" \
    "bash3.2 with-changed-files: agent must be preserved (regression: was \"CLAUDE.md\")"
  smoke_assert_not_contains "$json" "usage: rematerialize-agent-identity.sh" \
    "bash3.2 with-changed-files: must NOT emit the usage error"
  smoke_assert_not_contains "$(json_field "$json" source_dir)" "wrap-up.md" \
    "bash3.2 with-changed-files: a changed-file path must never leak into source_dir"
}

# --- Test 3: Bash 4+ parse (no re-exec) also preserves the agent ------------
test_bash4_preserves_agent() {
  setup_fixture
  write_roster boundary
  seed_agent boundary src-old workdir-stale

  local json=""
  json="$(run_helper_json "$BASH4" "$REPO_ROOT" "$BRIDGE_HOME" boundary claude 1)"
  smoke_assert_eq "boundary" "$(json_field "$json" agent)" \
    "bash4 zero-changed-files: agent preserved"
  smoke_assert_eq "planned" "$(json_field "$json" status)" \
    "bash4 zero-changed-files: status planned"
}

# --- Test 4: Python-side guard rejects a mismatched/blank-agent payload ------
test_python_guard_structures_mismatched_agent() {
  python3 - "$REPO_ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bridge_upgrade", repo_root / "bridge-upgrade.py")
mod = importlib.util.module_from_spec(spec)
# Register before exec so the @dataclass field-type resolution (the module uses
# `from __future__ import annotations`) can find the module in sys.modules.
sys.modules["bridge_upgrade"] = mod
spec.loader.exec_module(mod)

# Build the smallest AgentMigrationResult the guard touches (agent + engine).
result = mod.AgentMigrationResult(
    agent="boundary",
    added_files=[],
    created_dirs=[],
    updated_files=[],
    session_type="static-claude",
    engine="claude",
)

# Stand in for the helper subprocess: emit a payload with a BLANK agent + usage
# error (the historical #1670 shape) and a separate MISMATCHED-agent payload.
class _Proc:
    def __init__(self, stdout):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = 0

import json as _json

cases = {
    "blank-agent": _json.dumps({
        "agent": "",
        "status": "error",
        "source_dir": "",
        "target_dir": "",
        "errors": ["usage: rematerialize-agent-identity.sh ..."],
    }),
    "mismatched-agent": _json.dumps({
        "agent": "CLAUDE.md",
        "status": "applied",
        "source_dir": ".claude/commands/wrap-up.md",
        "target_dir": "",
    }),
    "correct-agent": _json.dumps({
        "agent": "boundary",
        "status": "planned",
        "source_dir": "/x/agents/boundary",
        "target_dir": "/x/agents/boundary/workdir",
        "updated_paths": [],
    }),
}

orig_run = mod.subprocess.run
helper_path = repo_root / "lib" / "upgrade-helpers" / "rematerialize-agent-identity.sh"
if not helper_path.exists():
    print("FAIL: helper path missing for guard test")
    sys.exit(1)

failures = []
for label, stdout in cases.items():
    def _fake_run(*_a, _stdout=stdout, **_kw):
        return _Proc(_stdout)
    mod.subprocess.run = _fake_run
    try:
        payload = mod.rematerialize_agent_identity(repo_root, Path("/x"), result, True)
    finally:
        mod.subprocess.run = orig_run

    if label == "correct-agent":
        if payload.get("agent") != "boundary" or payload.get("status") != "planned":
            failures.append(f"{label}: correct payload was not passed through ({payload!r})")
    else:
        if payload.get("agent") != "boundary":
            failures.append(f"{label}: guard did not re-key the error to the asked-for agent ({payload!r})")
        if payload.get("status") != "error":
            failures.append(f"{label}: guard did not produce a structured error ({payload!r})")
        errs = payload.get("errors") or []
        if not any("mismatched agent identity" in str(e) for e in errs):
            failures.append(f"{label}: guard error message missing the mismatch detail ({errs!r})")

if failures:
    for f in failures:
        print("FAIL: " + f)
    sys.exit(1)
print("OK: python-side guard re-keys blank/mismatched agent payloads and passes correct ones through")
PY
}

smoke_run "bash3.2 re-exec boundary: zero changed files preserves agent" test_bash32_zero_changed_files_preserves_agent
smoke_run "bash3.2 re-exec boundary: changed files preserves agent" test_bash32_with_changed_files_preserves_agent
smoke_run "bash4 parse preserves agent" test_bash4_preserves_agent
smoke_run "python guard re-keys mismatched/blank agent payloads" test_python_guard_structures_mismatched_agent
smoke_log "PASS: $SMOKE_NAME"
