#!/usr/bin/env bash
# scripts/smoke/2216-convert-preserve-model-effort.sh — issue #2216: the
# dynamic→static converter must carry the source agent's RESOLVED/effective
# model+effort into the baked launch_cmd, the materialized roster fields, AND
# the rendered settings.effective.json — so a converted role boots on the same
# working model it ran on instead of the user-class template default
# (`claude-fable-5`, unavailable on the static pool token → empty shell).
#
# Two halves of the fix, each with an independent mutation-backed assertion:
#
#   Part B (converter-seed, bridge-agent.sh run_convert + lib/bridge-agents.sh
#     bridge_agent_operator_global_model): a dynamic-vanilla agent runs on the
#     operator-global ~/.claude model and records NO BRIDGE_AGENT_MODEL, so the
#     carry MUST resolve the operator-global model. Proven by the baked
#     launch_cmd `--model` + the materialized BRIDGE_AGENT_MODEL roster field,
#     which #11901 operator-global inheritance can NOT affect (revert Part B →
#     no --model bake, no roster model → T1 fails).
#
#   Part A (render-layer, bridge-hooks.py cmd_render_shared_settings
#     --agent-model + lib/bridge-hooks.sh threading): the carried model is
#     layered into settings.effective.json ABOVE the operator-global #11901
#     inheritance. Proven in ISOLATION (T4) by rendering with --agent-model set
#     to a DIFFERENT model than the operator-global carries and asserting the
#     carried value wins (revert Part A → operator-global wins → T4 fails).
#
#   T1  carry-over: operator-global model=claude-opus-4-8 + a non-default roster
#       effort → convert (no --model/--effort) bakes `--model claude-opus-4-8`,
#       materializes BRIDGE_AGENT_MODEL=claude-opus-4-8 + BRIDGE_AGENT_EFFORT,
#       and renders settings.effective.json model=claude-opus-4-8 (NOT fable).
#   T2  override precedence: explicit --model/--effort win over the carry-over.
#   T3  no regression: a render with an EMPTY --agent-model (the genuinely-new
#       static path) does NOT inject a model — the effective `model` keeps
#       deriving from operator-global / preserved keys exactly as before.
#   T4  Part-A mutation isolation: --agent-model wins over a DIFFERENT
#       operator-global model in the rendered effective file (load-bearing).
#
# Fully isolated BRIDGE_HOME (mktemp), fabricated operator ~/.claude, no live
# Claude / tmux. Models are arbitrary tokens (claude-opus-4-8 / claude-fable-5)
# — the smoke asserts on token routing, not on any real model's availability.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2216-convert-preserve-model-effort][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="2216-convert-preserve-model-effort"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# Operator-global ~/.claude the dynamic-vanilla agent inherits. Pinned via HOME
# + BRIDGE_CONTROLLER_HOME so bridge_agent_operator_home_dir resolves here.
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OPERATOR_HOME/.claude"

# The model the dynamic agents were actually running on (operator-global).
OPERATOR_MODEL="claude-opus-4-8"
# A stand-in for the user-class template default the converted static would
# otherwise fall through to (unavailable on the static pool token).
TEMPLATE_DEFAULT_MODEL="claude-fable-5"

write_operator_global_model() {
  local model="$1"
  if [[ -n "$model" ]]; then
    printf '{"model":"%s"}\n' "$model" > "$OPERATOR_HOME/.claude/settings.json"
  else
    printf '{}\n' > "$OPERATOR_HOME/.claude/settings.json"
  fi
}

slug_of() { local p="$1"; p="${p//\//-}"; printf '%s' "$p"; }

init_roster() {
  printf '#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n' > "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Seed a registered dynamic-vanilla Claude agent. An optional effort roster
# field models a source agent whose reasoning effort must be carried.
seed_dynamic_agent() {
  local agent="$1" workdir="$2" effort="${3:-}"
  mkdir -p "$workdir/.claude"
  {
    printf '\n# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
    printf 'bridge_add_agent_id_if_missing %q\n' "$agent"
    printf 'BRIDGE_AGENT_DESC["%s"]=%q\n' "$agent" "$agent convert model/effort test"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]=%q\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]=%q\n' "$agent" "$workdir"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="dynamic"\n' "$agent"
    [[ -n "$effort" ]] && printf 'BRIDGE_AGENT_EFFORT["%s"]=%q\n' "$agent" "$effort"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
  } >> "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Seed a transcript under the operator ~/.claude so the migration manifest is
# non-empty (convert requires something to migrate).
seed_operator_state() {
  local workdir="$1" sid="$2"
  local sl; sl="$(slug_of "$workdir")"
  mkdir -p "$OPERATOR_HOME/.claude/projects/$sl/memory"
  printf '{"cwd":"%s","sessionId":"%s"}\n' "$workdir" "$sid" \
    > "$OPERATOR_HOME/.claude/projects/$sl/$sid.jsonl"
  printf '# MEMORY\nconverted-agent project memory\n' \
    > "$OPERATOR_HOME/.claude/projects/$sl/memory/MEMORY.md"
}

convert_cli() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_CALLER_SOURCE="${BRIDGE_CALLER_SOURCE:-operator-trusted-id}" \
    "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" convert "$@"
}

lib_eval() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" -c "source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1; $1"
}

# Read the rendered settings.effective.json `model` for an agent (or '' if the
# key/file is absent).
effective_model_of() {
  local agent="$1" eff
  eff="$(lib_eval "bridge_hook_per_agent_settings_effective_file $agent")"
  [[ -f "$eff" ]] || { printf '%s' ''; return 0; }
  python3 -c '
import json, sys
try:
    p = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    sys.exit(0)
m = p.get("model") if isinstance(p, dict) else None
sys.stdout.write(m if isinstance(m, str) else "")
' "$eff"
}

roster_field_of() {
  local var="$1" agent="$2"
  grep -F "${var}[\"${agent}\"]=" "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | tail -1 || true
}

# ===========================================================================
# T1 — carry-over: operator-global model + roster effort flow into the baked
# launch_cmd, the materialized roster fields, AND the rendered effective file.
# Load-bearing for Part B (launch_cmd + roster, immune to #11901).
# ===========================================================================
test_t1_carry_over() {
  init_roster
  write_operator_global_model "$OPERATOR_MODEL"
  local agent="carry" workdir="$SMOKE_TMP_ROOT/carry-wd" effort="high"
  seed_dynamic_agent "$agent" "$workdir" "$effort"
  seed_operator_state "$workdir" "sidC"

  local out
  out="$(convert_cli "$agent" --to static)" \
    || smoke_fail "T1: convert exited non-zero: $out"

  # --- Part B: baked launch_cmd carries the operator-global model -----------
  local launch_line
  launch_line="$(grep -F 'BRIDGE_AGENT_LAUNCH_CMD["carry"]=' "$BRIDGE_ROSTER_LOCAL_FILE" || true)"
  [[ -n "$launch_line" ]] || smoke_fail "T1: no baked launch_cmd in the roster"
  case "$launch_line" in
    *"--model $OPERATOR_MODEL"*) : ;;
    *) smoke_fail "T1 (Part B): baked launch_cmd did not carry the resolved operator-global model '$OPERATOR_MODEL': $launch_line";;
  esac
  case "$launch_line" in
    *"$TEMPLATE_DEFAULT_MODEL"*) smoke_fail "T1: baked launch_cmd carried the template default '$TEMPLATE_DEFAULT_MODEL'";;
    *) : ;;
  esac

  # --- Part B: materialized roster fields -----------------------------------
  local model_line effort_line
  model_line="$(roster_field_of BRIDGE_AGENT_MODEL "$agent")"
  effort_line="$(roster_field_of BRIDGE_AGENT_EFFORT "$agent")"
  smoke_assert_contains "$model_line" "$OPERATOR_MODEL" \
    "T1 (Part B): BRIDGE_AGENT_MODEL roster field did not carry the resolved model"
  smoke_assert_contains "$effort_line" "$effort" \
    "T1 (Part B): BRIDGE_AGENT_EFFORT roster field did not carry the source effort"

  # --- Part A: rendered effective file shows the carried model, NOT fable ----
  local eff_model
  eff_model="$(effective_model_of "$agent")"
  smoke_assert_eq "$OPERATOR_MODEL" "$eff_model" \
    "T1 (Part A): settings.effective.json model is not the carried model (fell back to the template default?)"  # noqa: iso-helper-boundary — assertion message, not an iso-boundary filesystem callsite
  [[ "$eff_model" != "$TEMPLATE_DEFAULT_MODEL" ]] \
    || smoke_fail "T1 (Part A): settings.effective.json rendered the unavailable template default '$TEMPLATE_DEFAULT_MODEL'"  # noqa: iso-helper-boundary — assertion message, not an iso-boundary filesystem callsite
  smoke_log "T1 OK — carry-over: launch_cmd + roster + effective.json all describe '$OPERATOR_MODEL' (effort '$effort'), not the template default"
}

# ===========================================================================
# T2 — override precedence: explicit --model/--effort win over the carry-over.
# ===========================================================================
test_t2_explicit_override_wins() {
  init_roster
  write_operator_global_model "$OPERATOR_MODEL"
  local agent="override" workdir="$SMOKE_TMP_ROOT/override-wd"
  seed_dynamic_agent "$agent" "$workdir" "high"
  seed_operator_state "$workdir" "sidO"

  local override_model="claude-sonnet-4-7" override_effort="medium"
  local out
  out="$(convert_cli "$agent" --to static --model "$override_model" --effort "$override_effort")" \
    || smoke_fail "T2: convert exited non-zero: $out"

  local launch_line
  launch_line="$(grep -F 'BRIDGE_AGENT_LAUNCH_CMD["override"]=' "$BRIDGE_ROSTER_LOCAL_FILE" || true)"
  case "$launch_line" in
    *"--model $override_model"*) : ;;
    *) smoke_fail "T2: explicit --model did not win in the baked launch_cmd: $launch_line";;
  esac
  case "$launch_line" in
    *"--model $OPERATOR_MODEL"*) smoke_fail "T2: the carried operator-global model leaked past the explicit --model override";;
    *) : ;;
  esac
  smoke_assert_contains "$(roster_field_of BRIDGE_AGENT_MODEL "$agent")" "$override_model" \
    "T2: BRIDGE_AGENT_MODEL did not record the explicit --model override"
  smoke_assert_contains "$(roster_field_of BRIDGE_AGENT_EFFORT "$agent")" "$override_effort" \
    "T2: BRIDGE_AGENT_EFFORT did not record the explicit --effort override"
  local eff_model
  eff_model="$(effective_model_of "$agent")"
  smoke_assert_eq "$override_model" "$eff_model" \
    "T2: settings.effective.json did not render the explicit --model override"  # noqa: iso-helper-boundary — assertion message, not an iso-boundary filesystem callsite
  smoke_log "T2 OK — explicit --model/--effort win over the carry-over in launch_cmd, roster, and effective.json"
}

# ===========================================================================
# T3 — no regression for genuinely-new static agents: a render with EMPTY
# --agent-model injects nothing — the effective `model` keeps deriving from the
# operator-global / preserved keys exactly as before the fix.
# ===========================================================================
test_t3_no_regression_empty_agent_model() {
  local base="$SMOKE_TMP_ROOT/t3-base.json"
  local overlay="$SMOKE_TMP_ROOT/t3-overlay.json"
  local opglobal="$SMOKE_TMP_ROOT/t3-opglobal.json"
  local eff="$SMOKE_TMP_ROOT/t3-eff.json"
  printf '{}\n' > "$base"
  printf '{}\n' > "$overlay"
  # The operator-global carries a model; with an EMPTY --agent-model it must
  # still inherit via #11901 (prior behavior preserved).
  printf '{"model":"%s"}\n' "$OPERATOR_MODEL" > "$opglobal"

  python3 "$REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$eff" \
    --operator-global-settings-file "$opglobal" \
    --launch-cmd "claude" \
    --agent-class "static" \
    --channels-csv "" \
    --agent-model "" \
    --agent-effort "" >/dev/null \
    || smoke_fail "T3: render-shared-settings (empty --agent-model) failed"

  local got
  got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "$eff")"
  # With an empty --agent-model the carried-value layer is NOT applied; the
  # model comes from the operator-global inheritance (unchanged behavior). The
  # point is that the render did NOT crash and did NOT invent a model of its
  # own — it passed the operator-global through exactly as the pre-fix render.
  smoke_assert_eq "$OPERATOR_MODEL" "$got" \
    "T3: empty --agent-model changed the inherited operator-global model (regression)"
  smoke_log "T3 OK — empty --agent-model is inert; the effective model still derives from operator-global (no regression)"
}

# ===========================================================================
# T4 — Part-A mutation isolation: --agent-model wins over a DIFFERENT
# operator-global model in the rendered effective file. This is the load-bearing
# proof for the render-layer half: revert the cmd_render_shared_settings
# injection and the operator-global model wins instead → this test fails.
# ===========================================================================
test_t4_agent_model_wins_over_operator_global() {
  local base="$SMOKE_TMP_ROOT/t4-base.json"
  local overlay="$SMOKE_TMP_ROOT/t4-overlay.json"
  local opglobal="$SMOKE_TMP_ROOT/t4-opglobal.json"
  local eff="$SMOKE_TMP_ROOT/t4-eff.json"
  printf '{}\n' > "$base"
  printf '{}\n' > "$overlay"
  # Operator-global carries the UNAVAILABLE template default; the carried
  # --agent-model is the working model. Only the Part-A injection can make the
  # working model win here.
  printf '{"model":"%s"}\n' "$TEMPLATE_DEFAULT_MODEL" > "$opglobal"

  python3 "$REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$eff" \
    --operator-global-settings-file "$opglobal" \
    --launch-cmd "claude" \
    --agent-class "static" \
    --channels-csv "" \
    --agent-model "$OPERATOR_MODEL" \
    --agent-effort "high" >/dev/null \
    || smoke_fail "T4: render-shared-settings (--agent-model set) failed"

  local got
  got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "$eff")"
  smoke_assert_eq "$OPERATOR_MODEL" "$got" \
    "T4 (Part A mutation): the carried --agent-model did not win over the operator-global model in the effective file"
  [[ "$got" != "$TEMPLATE_DEFAULT_MODEL" ]] \
    || smoke_fail "T4: the effective file rendered the operator-global template default instead of the carried model"
  smoke_log "T4 OK — carried --agent-model wins over the operator-global model in settings.effective.json (Part-A mutation proof)"  # noqa: iso-helper-boundary — log message, not an iso-boundary filesystem callsite
}

# --- run -------------------------------------------------------------------
smoke_run "T1 carry-over: launch_cmd + roster + effective.json carry the resolved model+effort" test_t1_carry_over
smoke_run "T2 explicit --model/--effort override wins over the carry-over" test_t2_explicit_override_wins
smoke_run "T3 empty --agent-model is inert (no regression for new statics)" test_t3_no_regression_empty_agent_model
smoke_run "T4 carried --agent-model wins over operator-global (Part-A mutation proof)" test_t4_agent_model_wins_over_operator_global

smoke_log "PASS — #2216 convert preserves the source model+effort: carried into the baked launch_cmd, the materialized roster fields, and the rendered settings.effective.json; explicit overrides win; empty carry is inert; render injection is load-bearing"  # noqa: iso-helper-boundary — log message, not an iso-boundary filesystem callsite
