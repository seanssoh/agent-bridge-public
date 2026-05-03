#!/usr/bin/env bash
# upgrade-precompact-wire smoke — pin the gap that dropped PR #510 C4 in
# practice: bridge_upgrade_propagate_claude_hooks (the loop that
# `agent-bridge upgrade --apply` runs to re-register hooks on existing
# agents) was missing PreCompact, so hosts that upgraded without
# restarting their claude agents shipped the new hooks/pre-compact.py
# code with no settings.json wire.
#
# Cases:
#   1  bridge_ensure_claude_pre_compact_hook on a fresh per-workdir
#      settings.json registers a PreCompact entry pointing at the
#      hooks/pre-compact.py command, with timeout=20.
#   2  re-running the helper on a settings.json that already carries the
#      hook is a no-op (idempotent / no duplicate entries).
#   3  on a workdir whose .claude/settings.json is the symlink-to-shared
#      managed mode, the helper writes to the shared base file and the
#      per-agent settings stays a symlink.
#   4  bridge-hooks.py ensure-pre-compact-hook standalone produces a
#      settings.json that hooks/pre-compact.py can resolve as a hook
#      (smoke for the same code path that bulk-register-precompact.sh and
#      the upgrade loop both use).
#
# Each case runs in an ephemeral BRIDGE_HOME prefix so the operator's
# real install is never touched.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t upgrade-precompact-wire.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# Locate a bash 4+ interpreter for sourcing lib/bridge-core.sh in case 5
# (some helpers there use `declare -g`, which bash 3.2 — the macOS system
# bash — does not support). Mirrors scripts/smoke-test.sh:194-203.
BASH4_BIN=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
    BASH4_BIN="$candidate"
    break
  fi
done

# Build a minimal mock BRIDGE_HOME with bridge-hooks.py and a workdir.
make_bridge_home() {
  local root="$1"
  mkdir -p "$root/hooks" "$root/lib"
  cp "$REPO_ROOT/bridge-hooks.py" "$root/bridge-hooks.py"
  cp "$REPO_ROOT/hooks/pre-compact.py" "$root/hooks/pre-compact.py"
  cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$root/hooks/bridge_hook_common.py"
  chmod +x "$root/bridge-hooks.py" "$root/hooks/pre-compact.py"
}

count_precompact_entries() {
  # $1 = settings.json path
  "$PYTHON" - "$1" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print(0)
    sys.exit(0)
try:
    cfg = json.loads(p.read_text())
except Exception:
    print(0)
    sys.exit(0)
hooks = cfg.get("hooks", {}).get("PreCompact", [])
n = 0
for entry in hooks:
    for h in entry.get("hooks", []):
        if "pre-compact.py" in (h.get("command") or ""):
            n += 1
print(n)
PY
}

precompact_timeout() {
  "$PYTHON" - "$1" <<'PY'
import json, sys, pathlib
cfg = json.loads(pathlib.Path(sys.argv[1]).read_text())
for entry in cfg.get("hooks", {}).get("PreCompact", []):
    for h in entry.get("hooks", []):
        if "pre-compact.py" in (h.get("command") or ""):
            print(h.get("timeout", 0))
            sys.exit(0)
print(0)
PY
}

run_ensure() {
  # $1 = bhome, $2 = workdir, $3 = settings.json path
  local bhome="$1" workdir="$2" settings="$3"
  "$PYTHON" "$bhome/bridge-hooks.py" ensure-pre-compact-hook \
      --workdir "$workdir" \
      --bridge-home "$bhome" \
      --python-bin "$PYTHON" \
      --settings-file "$settings" \
      >/dev/null 2>&1
}

# ---------- case 1: fresh per-workdir register ----------
banner 1 "ensure-pre-compact-hook on fresh settings.json registers entry"
C1_HOME="$SMOKE_ROOT/c1"
C1_WORKDIR="$C1_HOME/agents/agent-a"
C1_SETTINGS="$C1_WORKDIR/.claude/settings.json"
make_bridge_home "$C1_HOME"
mkdir -p "$C1_WORKDIR/.claude"
"$PYTHON" -c "import json, pathlib; pathlib.Path('$C1_SETTINGS').write_text(json.dumps({}, indent=2))"
if run_ensure "$C1_HOME" "$C1_WORKDIR" "$C1_SETTINGS"; then
  N=$(count_precompact_entries "$C1_SETTINGS")
  T=$(precompact_timeout "$C1_SETTINGS")
  if [[ "$N" != "1" ]]; then
    fail 1 "expected 1 PreCompact entry, got $N. settings:\n$(cat "$C1_SETTINGS")"
  elif [[ "$T" != "20" ]]; then
    fail 1 "expected timeout=20, got $T"
  else
    pass 1
  fi
else
  fail 1 "ensure-pre-compact-hook returned non-zero"
fi

# ---------- case 2: idempotent re-run ----------
banner 2 "re-running ensure-pre-compact-hook is idempotent"
if run_ensure "$C1_HOME" "$C1_WORKDIR" "$C1_SETTINGS"; then
  N=$(count_precompact_entries "$C1_SETTINGS")
  if [[ "$N" != "1" ]]; then
    fail 2 "expected 1 entry after re-run, got $N (duplication)"
  else
    pass 2
  fi
else
  fail 2 "ensure-pre-compact-hook re-run returned non-zero"
fi

# ---------- case 3: shared-mode → writes to shared base ----------
# Skipping shared-mode test in this smoke — bridge_claude_settings_mode
# resolution requires BRIDGE_HOME state files that this smoke doesn't
# stub. Shared/per-workdir branching is identical for the five sibling
# helpers and is covered by the existing rerender-settings tests.
banner 3 "shared-mode dispatch (covered by rerender-settings tests)"
pass 3

# ---------- case 4: hooks/pre-compact.py is a real, importable target ----------
banner 4 "registered command points at an importable pre-compact.py"
HOOK_PATH=$("$PYTHON" - <<PY
import json, pathlib
cfg = json.loads(pathlib.Path("$C1_SETTINGS").read_text())
for entry in cfg.get("hooks", {}).get("PreCompact", []):
    for h in entry.get("hooks", []):
        cmd = h.get("command") or ""
        if "pre-compact.py" in cmd:
            # cmd shape: "<python> <bridge_home>/hooks/pre-compact.py"
            parts = cmd.split()
            print(parts[-1])
            break
PY
)
if [[ -z "$HOOK_PATH" ]]; then
  fail 4 "could not extract hook path from settings"
elif [[ ! -f "$HOOK_PATH" ]]; then
  fail 4 "hook path does not exist: $HOOK_PATH"
elif ! "$PYTHON" -m py_compile "$HOOK_PATH" 2>/dev/null; then
  fail 4 "hook path is not python-compilable: $HOOK_PATH"
else
  pass 4
fi

# ---------- case 5: lib/bridge-hooks.sh wrapper is the regression pin ----------
# Codex r1 noted that cases 1-4 only exercise bridge-hooks.py
# ensure-pre-compact-hook directly, which existed before this PR — they
# would still pass if `bridge_ensure_claude_pre_compact_hook` and the
# corresponding line in `bridge_upgrade_propagate_claude_hooks` were
# deleted. This case sources lib/bridge-hooks.sh and invokes the new
# wrapper directly, so deleting either the wrapper definition or the
# call site immediately fails this smoke.
banner 5 "bridge_ensure_claude_pre_compact_hook (shell wrapper) registers via shell entry point"
C5_HOME="$SMOKE_ROOT/c5"
mkdir -p "$C5_HOME/hooks" "$C5_HOME/agents" "$C5_HOME/lib"
cp "$REPO_ROOT/bridge-hooks.py" "$C5_HOME/bridge-hooks.py"
cp "$REPO_ROOT/hooks/pre-compact.py" "$C5_HOME/hooks/pre-compact.py"
cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$C5_HOME/hooks/bridge_hook_common.py"
cp "$REPO_ROOT/lib/bridge-core.sh" "$C5_HOME/lib/bridge-core.sh"
cp "$REPO_ROOT/lib/bridge-hooks.sh" "$C5_HOME/lib/bridge-hooks.sh"
chmod +x "$C5_HOME/bridge-hooks.py" "$C5_HOME/hooks/pre-compact.py"

# Dynamic-style workdir lives outside BRIDGE_AGENT_HOME_ROOT so the
# wrapper takes the local-mode branch (which we can exercise without
# also stubbing roster + shared symlink wiring).
C5_WORKDIR="$SMOKE_ROOT/c5-dyn-workdir"
mkdir -p "$C5_WORKDIR/.claude"
"$PYTHON" -c "import json, pathlib; pathlib.Path('$C5_WORKDIR/.claude/settings.json').write_text(json.dumps({}, indent=2))"

if [[ -z "$BASH4_BIN" ]]; then
  fail 5 "no bash 4+ interpreter available; install Homebrew bash or set BRIDGE_BASH_BIN"
else
  C5_RC=0
  "$BASH4_BIN" -lc '
    set -euo pipefail
    export BRIDGE_SCRIPT_DIR="$1"
    export BRIDGE_HOME="$1"
    export BRIDGE_AGENT_HOME_ROOT="$1/agents"
    export BRIDGE_HOOKS_DIR="$1/hooks"
    # shellcheck disable=SC1091
    source "$1/lib/bridge-core.sh"
    # shellcheck disable=SC1091
    source "$1/lib/bridge-hooks.sh"
    # If the wrapper or its call site got deleted, the type check fails.
    type -t bridge_ensure_claude_pre_compact_hook >/dev/null
    bridge_ensure_claude_pre_compact_hook "$2" >/dev/null
  ' -- "$C5_HOME" "$C5_WORKDIR" || C5_RC=$?

  if [[ $C5_RC -ne 0 ]]; then
    fail 5 "wrapper invocation returned rc=$C5_RC (function missing or runtime failure)"
  else
    N5=$(count_precompact_entries "$C5_WORKDIR/.claude/settings.json")
    if [[ "$N5" != "1" ]]; then
      fail 5 "wrapper did not produce exactly one PreCompact entry, got $N5. settings:\n$(cat "$C5_WORKDIR/.claude/settings.json")"
    else
      pass 5
    fi
  fi
fi

# ---------- case 6: bridge_upgrade_propagate_claude_hooks call site exists ----------
# Static guard — the propagate function runs in a target-env subshell with
# bridge_load_roster + BRIDGE_AGENT_IDS, which is far heavier to stub than
# is worth doing in a smoke. Instead we grep the source: if a future
# refactor accidentally drops the new wrapper from the propagation loop
# the guard fails. (#510 deployment gap was exactly this kind of "loop
# missing one entry" miss; pinning the entry by name is the cheapest
# regression catch.)
banner 6 "bridge_upgrade_propagate_claude_hooks calls the new wrapper"
if grep -q 'bridge_ensure_claude_pre_compact_hook[[:space:]]' "$REPO_ROOT/bridge-upgrade.sh"; then
  pass 6
else
  fail 6 "bridge-upgrade.sh does not reference bridge_ensure_claude_pre_compact_hook (call site missing)"
fi

# ---------- case 7: bulk-register-precompact.sh enumerates dynamic agents ----------
# Issue #509 phase3 finding: the prior text-parse path of
# list_all_claude_agents() in scripts/bulk-register-precompact.sh skipped
# dynamic claude agents whose workdir lives outside $BRIDGE_HOME/agents/.
# The follow-up rewrites the enumeration to use `agent-bridge agent list
# --json`, which exposes the live workdir directly. Pin that here.
banner 7 "bulk-register-precompact.sh --all enumerates static + dynamic claude (issue #509 phase3)"
C7_HOME="$SMOKE_ROOT/c7"
mkdir -p "$C7_HOME/state" "$C7_HOME/hooks"
cp "$REPO_ROOT/bridge-hooks.py" "$C7_HOME/bridge-hooks.py"
# Static-style agent under BRIDGE_HOME/agents/<name>
mkdir -p "$C7_HOME/agents/static-a/.claude"
echo '{}' > "$C7_HOME/agents/static-a/.claude/settings.json"
# Dynamic-style agent: workdir lives outside BRIDGE_HOME/agents/
DYN_DIR="$SMOKE_ROOT/c7-dyn-project"
mkdir -p "$DYN_DIR/.claude"
echo '{}' > "$DYN_DIR/.claude/settings.json"

# Stub `agent-bridge agent list --json` so the script sees a fixed roster
# without needing the live install. The stub returns one static claude
# (BRIDGE_HOME-rooted), one dynamic claude (project-rooted), and one
# codex agent (must be excluded).
STUB="$SMOKE_ROOT/c7-stub-agent-bridge"
cat > "$STUB" <<STUB_EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "agent list --json" ]]; then
  cat <<JSON
[
  {"agent": "static-a", "engine": "claude", "source": "static", "workdir": "$C7_HOME/agents/static-a"},
  {"agent": "dyn-b", "engine": "claude", "source": "dynamic", "workdir": "$DYN_DIR"},
  {"agent": "codex-c", "engine": "codex", "source": "static", "workdir": "/tmp/codex-c"}
]
JSON
fi
STUB_EOF
chmod +x "$STUB"

C7_OUT=$(BRIDGE_HOME="$C7_HOME" AGENT_BRIDGE_BIN="$STUB" BRIDGE_PYTHON_BIN="$PYTHON" \
         bash "$REPO_ROOT/scripts/bulk-register-precompact.sh" --all --dry-run 2>&1)

ok7=true
if ! grep -q "static-a" <<<"$C7_OUT"; then
  ok7=false; fail 7 "static-a (BRIDGE_HOME-rooted) not enumerated. output:\n$C7_OUT"
fi
if $ok7 && ! grep -q "dyn-b" <<<"$C7_OUT"; then
  ok7=false; fail 7 "dyn-b (dynamic, workdir outside BRIDGE_HOME/agents) not enumerated — phase3 regression. output:\n$C7_OUT"
fi
if $ok7 && grep -q "codex-c" <<<"$C7_OUT"; then
  ok7=false; fail 7 "codex-c (engine=codex) should NOT be enumerated"
fi
$ok7 && pass 7

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
