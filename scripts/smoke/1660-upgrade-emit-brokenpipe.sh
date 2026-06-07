#!/usr/bin/env bash
# scripts/smoke/1660-upgrade-emit-brokenpipe.sh — Issue #1660 smoke.
#
# `agent-bridge upgrade --apply` could exit non-zero (observed exit 144) with a
# BrokenPipeError at the `migrate-agents` step EVEN THOUGH the upgrade
# succeeded. Root cause: every cmd_* helper in bridge-upgrade.py ended with an
# unguarded `print(json.dumps(payload, ...))`. When the caller captures via
# command substitution (`MIGRATION_JSON="$(python3 ... migrate-agents ...)"`)
# and the consumer vanishes mid-write (e.g. a concurrent upgrade thrash), the
# write raises BrokenPipeError → uncaught → exit 144, misleading any automation
# that gates on the exit code.
#
# Fix: a single `emit_json(payload, rc)` helper does write+flush INSIDE a try,
# and on BrokenPipeError redirects stdout to devnull (so interpreter shutdown
# does not re-raise) then returns the caller's INTENDED rc. No global
# signal.signal(SIGPIPE, SIG_DFL) — that would convert this completed-work case
# into a 141/signal exit instead of preserving rc.
#
# Coverage (all against an isolated tmp source+target — never touches operator
# state):
#   T1  Real CLI through a consumer that closes immediately
#       (`migrate-agents ... | head -c 0`) → the PRODUCER rc (PIPESTATUS[0]) is
#       the intended 0 for a completed migration, NOT 144.
#   T2  Deterministic broken-stdout harness: emit_json(payload, rc=0) with a
#       guaranteed-broken stdout returns 0 (not 144/141).
#   T3  Intended non-zero rc is preserved: emit_json(payload, rc=1) and
#       emit_json(payload, rc=2) over a broken stdout still return 1 and 2 — a
#       broken stdout must NOT mask a real failure (cmd_verify_tasks_db,
#       cmd_apply_live rely on this).
#   T4  No global SIGPIPE SIG_DFL: the source must not install
#       signal.signal(signal.SIGPIPE, signal.SIG_DFL) (which would convert the
#       completed-migration case into a 141 exit).
#   T5  No unguarded `print(json.dumps(...))` emit sites remain — every JSON
#       emit goes through emit_json.
#
# Footgun #11: no heredoc / here-string feeding a subprocess interpreter.
# Python payloads run as `python3 -c '...'` with argv, not stdin.

set -euo pipefail

SMOKE_NAME="1660-upgrade-emit-brokenpipe"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$SMOKE_REPO_ROOT"
UPGRADE_PY="$ROOT_DIR/bridge-upgrade.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd git
smoke_require_cmd python3
smoke_require_cmd head
smoke_assert_file_exists "$UPGRADE_PY" "bridge-upgrade.py present"

smoke_make_temp_root

SRC="$SMOKE_TMP_ROOT/source"
TGT="$SMOKE_TMP_ROOT/target"

# --------------------------------------------------------------------------
# Build a minimal source checkout + a live target with a couple of agent dirs,
# enough for `migrate-agents` to produce a non-trivial JSON payload.
# --------------------------------------------------------------------------
build_source_and_target() {
  mkdir -p "$SRC/agents/_template"
  git -C "$SRC" init -q
  git -C "$SRC" config user.email smoke@example.com
  git -C "$SRC" config user.name "smoke"
  git -C "$SRC" config commit.gpgsign false
  printf '0.16.2\n' >"$SRC/VERSION"
  # A tiny template tree so migrate-agents has content to consider.
  printf 'template soul\n' >"$SRC/agents/_template/SOUL.md"
  printf 'template claude\n' >"$SRC/agents/_template/CLAUDE.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "src"

  mkdir -p "$TGT/state"
  printf '0.16.1\n' >"$TGT/VERSION"
  # Seed enough agent dirs that the migrate-agents JSON payload exceeds a
  # typical 64KB pipe buffer — so a consumer that closes early DETERMINISTICALLY
  # breaks the pipe on the producer's write (a small payload would just be
  # absorbed by the kernel buffer and the write would succeed regardless).
  local i
  for i in $(seq 1 200); do
    mkdir -p "$TGT/agents/agent$i"
    printf 'soul %d\n' "$i" >"$TGT/agents/agent$i/SOUL.md"
  done
}

# --------------------------------------------------------------------------
# T1: real CLI through a consumer that closes immediately.
# --------------------------------------------------------------------------
test_cli_brokenpipe_preserves_rc() {
  build_source_and_target

  # `head -c1` reads exactly one byte and closes the read end. The producer's
  # large JSON write then hits a closed pipe on the remainder (`head -c 0` is
  # rejected by BSD/macOS head, so we read the minimum portable amount). With
  # the guard the producer rc (PIPESTATUS[0]) must be the intended 0 — NOT 144
  # (the uncaught-BrokenPipeError exit). `--migrate-all-agents` so the roster
  # filter can't skip the seeded dirs.
  #
  # set -o pipefail is intentionally NOT used here: we read PIPESTATUS[0]
  # directly so the consumer's rc never masks the producer's.
  set +e
  python3 "$UPGRADE_PY" migrate-agents \
    --source-root "$SRC" \
    --target-root "$TGT" \
    --migrate-all-agents \
    --dry-run | head -c1 >/dev/null
  local producer_rc="${PIPESTATUS[0]}"
  set -e

  smoke_assert_eq "0" "$producer_rc" \
    "migrate-agents | head -c0 producer rc is intended 0, not 144"
}

# --------------------------------------------------------------------------
# T2 + T3: deterministic broken-stdout harness over emit_json directly.
# A real os.pipe() with the read end closed guarantees BrokenPipeError on the
# first write — no reliance on buffer sizes or scheduling.
# --------------------------------------------------------------------------
test_emit_json_guard_unit() {
  local out
  out="$(python3 -c '
import importlib.util, os, sys

upg_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("bridge_upgrade_mod", upg_path)
mod = importlib.util.module_from_spec(spec)
# Register before exec so @dataclass can resolve sys.modules[cls.__module__]
# (Python 3.9 dataclasses._is_type reads it during class construction).
sys.modules["bridge_upgrade_mod"] = mod
spec.loader.exec_module(mod)

# A payload large enough that the write definitely reaches the pipe.
payload = {"mode": "unit", "agents": [{"i": i, "blob": "x" * 256} for i in range(200)]}

def call_with_broken_stdout(rc):
    r, w = os.pipe()
    os.close(r)              # reader gone → any write raises BrokenPipeError
    saved = os.dup(1)        # save real stdout (the captured pipe to bash)
    try:
        os.dup2(w, 1)        # point fd 1 at the broken pipe
        os.close(w)
        sys.stdout = os.fdopen(os.dup(1), "w")  # rebind Python-level stdout
        result = mod.emit_json(payload, rc)      # must NOT raise
    finally:
        try:
            sys.stdout.close()
        except Exception:
            pass
        os.dup2(saved, 1)    # restore real stdout
        os.close(saved)
        sys.stdout = os.fdopen(1, "w", closefd=False)
    return result

r0 = call_with_broken_stdout(0)
r1 = call_with_broken_stdout(1)
r2 = call_with_broken_stdout(2)
print("rc0=%d rc1=%d rc2=%d" % (r0, r1, r2))
' "$UPGRADE_PY")"

  smoke_assert_contains "$out" "rc0=0" "emit_json rc=0 over broken stdout returns 0"
  smoke_assert_contains "$out" "rc1=1" "emit_json rc=1 over broken stdout returns 1 (failure preserved)"
  smoke_assert_contains "$out" "rc2=2" "emit_json rc=2 over broken stdout returns 2 (failure preserved)"
}

# --------------------------------------------------------------------------
# T4: no global SIGPIPE SIG_DFL — that would convert the completed-migration
# case into a 141/signal exit instead of preserving the intended rc.
# --------------------------------------------------------------------------
test_no_global_sigpipe_sig_dfl() {
  if grep -Eq 'signal\.signal\(\s*signal\.SIGPIPE\s*,\s*signal\.SIG_DFL' "$UPGRADE_PY"; then
    smoke_fail "bridge-upgrade.py installs global SIGPIPE SIG_DFL (forbidden by #1660)"
  fi
  smoke_log "ok: no global SIGPIPE SIG_DFL"
}

# --------------------------------------------------------------------------
# T5: every JSON emit goes through emit_json — NO `print(...)` call may embed a
# `json.dumps(...)`, including MULTILINE forms like `print(\n  json.dumps(...)\n)`
# (a same-line grep misses those — that gap let cmd_conflicts_adopt slip through
# the first pass, caught by codex review). We use a Python AST walk so the check
# is exact and multiline-safe; a same-line grep would be a false-negative trap.
# --------------------------------------------------------------------------
test_no_unguarded_print_json() {
  # Footgun #11: pass the AST walker via `python3 -c "$VAR"` (argv), NOT a
  # heredoc-stdin (`python3 - <<'PY'`), which wedges Bash 5.3.9 in read_comsub
  # under command substitution — and this smoke is selected for every upgrade
  # change, so a heredoc here could hang CI instead of validating #1660.
  local ast_walker
  ast_walker='
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
hits = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
        for arg in node.args:
            for sub in ast.walk(arg):
                if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute)
                        and sub.func.attr == "dumps"
                        and isinstance(sub.func.value, ast.Name) and sub.func.value.id == "json"):
                    hits.append(node.lineno)
print(",".join(str(n) for n in sorted(set(hits))))
'
  local bad
  bad="$(python3 -c "$ast_walker" "$UPGRADE_PY")"
  if [[ -n "$bad" ]]; then
    smoke_fail "print() call(s) still embed json.dumps (route through emit_json) at line(s): $bad"
  fi
  smoke_log "ok: no print(json.dumps(...)) emit sites (AST-verified, multiline-safe)"
}

smoke_run "T1 cli brokenpipe preserves intended rc (not 144)" test_cli_brokenpipe_preserves_rc
smoke_run "T2+T3 emit_json guard unit (rc preserved over broken stdout)" test_emit_json_guard_unit
smoke_run "T4 no global SIGPIPE SIG_DFL" test_no_global_sigpipe_sig_dfl
smoke_run "T5 no unguarded print(json.dumps)" test_no_unguarded_print_json

smoke_log "PASS"
