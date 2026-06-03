#!/usr/bin/env bash
# scripts/smoke/1497-v2-handoff-workdir-resolution.sh — issue #1497 (concrete).
#
# Pins the v2-split handoff-drop fix: the Python hook layer must resolve an
# agent's workdir/identity-home to the v2 split tree (data/agents/<a>/{home,
# workdir}) — NOT the legacy v1 tree ($BRIDGE_HOME/agents/<a>) — so a fresh
# session's NEXT-SESSION.md handoff candidate list includes the real
# data/agents/<a>/workdir/NEXT-SESSION.md and the delivered-marker +
# [bridge:handoff-pending] enqueue fire.
#
# Root causes the fix closes (all confirmed live on a v2-split install):
#   1. bridge-run.sh exported `BRIDGE_AGENT_WORKDIR` (the NAME of a bash
#      associative array) — a silent no-op — so the child env never carried
#      the workdir. Fix: a distinctly-named BRIDGE_AGENT_WORKDIR_RESOLVED
#      scalar alias (mirrors the #1217 BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED).
#   2. hooks/bridge_hook_common.py agent_home_root/agent_default_home/
#      agent_workdir were v2-blind (read only the legacy BRIDGE_AGENT_HOME_ROOT
#      + the empty BRIDGE_AGENT_WORKDIR). Fix: consult BRIDGE_AGENT_ROOT_V2 /
#      BRIDGE_DATA_ROOT + BRIDGE_AGENT_WORKDIR_RESOLVED, mirroring bash.
#   3. agent_workdir's legacy `.is_dir()` short-circuit returned the legacy
#      path BEFORE the roster fallback on a split-brain install (the legacy
#      agents/<a> dir physically still exists post-migration). Fix: consult
#      the v2 resolution / RESOLVED env BEFORE that short-circuit.
#
# Tests:
#   T1 (v2 fast path)        — RESOLVED env set → agent_workdir returns the v2
#                              workdir; agent_default_home returns
#                              data/agents/<a>/home; the handoff candidate list
#                              resolves the real NEXT-SESSION.md.
#   T2 (split-brain immunity) — v2 present, RESOLVED env UNSET, legacy agents/<a>
#                              dir ALSO present → agent_workdir STILL returns the
#                              v2 workdir (the on-disk v2 dir wins over the legacy
#                              short-circuit), and the handoff is found.
#   T3 (legacy-only)         — NO v2 signal → agent_workdir/home resolve to the
#                              legacy tree exactly as before (no regression).
#   T4 (TEETH)               — re-run T1 against a v2-BLIND copy of the resolvers
#                              (v2-awareness stripped) → workdir/home mis-resolve
#                              to the legacy tree and the handoff is MISSED. Proves
#                              the assertions fail without the fix.
#   T5 (source guard, bash)  — bridge-run.sh exports BRIDGE_AGENT_WORKDIR_RESOLVED.
#   T6 (source guard, py)    — agent_workdir reads BRIDGE_AGENT_WORKDIR_RESOLVED
#                              before the legacy default `.is_dir()` short-circuit.
#
# Footgun #11: pipe/argv stdin only. Drivers written via `printf >>file`.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1497-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

HOOK_COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
BRIDGE_RUN="$REPO_ROOT/bridge-run.sh"
if [[ ! -f "$HOOK_COMMON" ]]; then
  printf '[FAIL] hooks/bridge_hook_common.py not found at %s\n' "$HOOK_COMMON" >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_RUN" ]]; then
  printf '[FAIL] bridge-run.sh not found at %s\n' "$BRIDGE_RUN" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# v2-split fixture: data/agents/<a>/{home,workdir} + a LEGACY agents/<a> dir
# ALSO present (reproduces the split-brain), with a real handoff file under
# the v2 workdir, and a legacy-only agent for the no-regression case.
# ---------------------------------------------------------------------------
FIX="$SMOKE_DIR/bridge"
V2_AGENT="patchy"
LEGACY_AGENT="lego"
# DYN_AGENT reproduces the v2 dynamic / shared-mode shape: its v2 IDENTITY HOME
# exists but it has NO <root_v2>/<a>/workdir on disk — its real workdir is a
# project directory resolved via the roster CLI (#1501 r1 / #509 D wave).
DYN_AGENT="dyna"
DYN_PROJECT_WORKDIR="$FIX/projects/dyna-checkout"
mkdir -p \
  "$FIX/data/agents/$V2_AGENT/home" \
  "$FIX/data/agents/$V2_AGENT/workdir" \
  "$FIX/agents/$V2_AGENT" \
  "$FIX/agents/$LEGACY_AGENT" \
  "$FIX/data/agents/$DYN_AGENT/home" \
  "$DYN_PROJECT_WORKDIR"
printf 'v2 handoff payload\n' >"$FIX/data/agents/$V2_AGENT/workdir/NEXT-SESSION.md"
printf 'legacy handoff payload\n' >"$FIX/agents/$LEGACY_AGENT/NEXT-SESSION.md"
printf 'dynamic project handoff payload\n' >"$DYN_PROJECT_WORKDIR/NEXT-SESSION.md"

# Driver loads the resolver module (path from DRIVER_HOOK_COMMON_PATH) and
# prints WORKDIR=/HOME=/HANDOFF= lines for the requested agent. The smoke env
# controls which v2 signals are present. The module path is parameterized so
# the TEETH test can point it at a v2-blind copy.
DRIVER="$SMOKE_DIR/driver.py"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Resolve workdir/home/handoff for an agent via a controlled env + module path."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import importlib.util'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'def load_module(path):'
  printf '%s\n' '    spec = importlib.util.spec_from_file_location("bridge_hook_common", str(path))'
  printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
  printf '%s\n' '    spec.loader.exec_module(module)'
  printf '%s\n' '    return module'
  printf '%s\n' ''
  printf '%s\n' 'def main() -> int:'
  printf '%s\n' '    common_path = Path(os.environ["DRIVER_HOOK_COMMON_PATH"])'  # noqa: iso-helper-boundary
  printf '%s\n' '    module = load_module(common_path)'
  # #1501 r1: optionally stub the roster fallback so the v2 dynamic/shared-mode
  # case (no on-disk v2 workdir) can be exercised without a live agent-bridge CLI.
  printf '%s\n' '    roster_wd = os.environ.get("DRIVER_ROSTER_WORKDIR", "").strip()'  # noqa: iso-helper-boundary
  printf '%s\n' '    if roster_wd:'
  printf '%s\n' '        module._resolve_workdir_via_roster = lambda a, _p=Path(roster_wd): _p'
  printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "patchy")'  # noqa: iso-helper-boundary
  printf '%s\n' '    wd = module.agent_workdir(agent)'
  printf '%s\n' '    dh = module.agent_default_home(agent)'
  printf '%s\n' '    handoff = module.first_existing_path([wd / "NEXT-SESSION.md", dh / "NEXT-SESSION.md"])'
  printf '%s\n' '    print("WORKDIR=" + str(wd))'
  printf '%s\n' '    print("HOME=" + str(dh))'
  printf '%s\n' '    print("HANDOFF=" + ("" if handoff is None else str(handoff)))'
  printf '%s\n' '    return 0'
  printf '%s\n' ''
  printf '%s\n' 'if __name__ == "__main__":'
  printf '%s\n' '    raise SystemExit(main())'
} >>"$DRIVER"
chmod +x "$DRIVER"

# Extracts a single VAR= line from driver output.
_field() { grep "^$1=" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# T1 — v2 fast path. RESOLVED env set (the bridge-run.sh-spawned shape).
# ---------------------------------------------------------------------------
T1_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="$V2_AGENT" \
  BRIDGE_HOME="$FIX" \
  BRIDGE_AGENT_HOME_ROOT="$FIX/agents" \
  BRIDGE_AGENT_ROOT_V2="$FIX/data/agents" \
  BRIDGE_AGENT_WORKDIR_RESOLVED="$FIX/data/agents/$V2_AGENT/workdir" \
  python3 "$DRIVER" 2>&1)"
T1_WD="$(printf '%s\n' "$T1_OUT" | _field WORKDIR)"
T1_HOME="$(printf '%s\n' "$T1_OUT" | _field HOME)"
T1_HANDOFF="$(printf '%s\n' "$T1_OUT" | _field HANDOFF)"
if [[ "$T1_WD" == "$FIX/data/agents/$V2_AGENT/workdir" \
   && "$T1_HOME" == "$FIX/data/agents/$V2_AGENT/home" \
   && "$T1_HANDOFF" == "$FIX/data/agents/$V2_AGENT/workdir/NEXT-SESSION.md" ]]; then
  _pass "T1: v2 fast path — workdir/home/handoff resolve to the v2 split tree"
else
  _fail "T1" "v2 resolution wrong: WORKDIR=[$T1_WD] HOME=[$T1_HOME] HANDOFF=[$T1_HANDOFF]"
fi

# ---------------------------------------------------------------------------
# T2 — split-brain immunity. v2 present, RESOLVED UNSET, legacy agents/<a>
# dir ALSO present. The on-disk v2 workdir must win over the legacy
# `.is_dir()` short-circuit so the handoff is still found.
# ---------------------------------------------------------------------------
T2_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="$V2_AGENT" \
  BRIDGE_HOME="$FIX" \
  BRIDGE_AGENT_HOME_ROOT="$FIX/agents" \
  BRIDGE_AGENT_ROOT_V2="$FIX/data/agents" \
  python3 "$DRIVER" 2>&1)"
T2_WD="$(printf '%s\n' "$T2_OUT" | _field WORKDIR)"
T2_HANDOFF="$(printf '%s\n' "$T2_OUT" | _field HANDOFF)"
if [[ "$T2_WD" == "$FIX/data/agents/$V2_AGENT/workdir" \
   && "$T2_HANDOFF" == "$FIX/data/agents/$V2_AGENT/workdir/NEXT-SESSION.md" ]]; then
  _pass "T2: split-brain immunity — v2 workdir wins over the legacy short-circuit"
else
  _fail "T2" "split-brain mis-resolved: WORKDIR=[$T2_WD] HANDOFF=[$T2_HANDOFF]"
fi

# ---------------------------------------------------------------------------
# T3 — legacy-only (NO v2 signal). Must resolve to the legacy tree exactly
# as before — no regression.
# ---------------------------------------------------------------------------
T3_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="$LEGACY_AGENT" \
  BRIDGE_HOME="$FIX" \
  BRIDGE_AGENT_HOME_ROOT="$FIX/agents" \
  python3 "$DRIVER" 2>&1)"
T3_WD="$(printf '%s\n' "$T3_OUT" | _field WORKDIR)"
T3_HOME="$(printf '%s\n' "$T3_OUT" | _field HOME)"
T3_HANDOFF="$(printf '%s\n' "$T3_OUT" | _field HANDOFF)"
if [[ "$T3_WD" == "$FIX/agents/$LEGACY_AGENT" \
   && "$T3_HOME" == "$FIX/agents/$LEGACY_AGENT" \
   && "$T3_HANDOFF" == "$FIX/agents/$LEGACY_AGENT/NEXT-SESSION.md" \
   && "$T3_WD" != *"data/agents"* ]]; then
  _pass "T3: legacy-only — resolves to the legacy tree (no regression)"
else
  _fail "T3" "legacy regression: WORKDIR=[$T3_WD] HOME=[$T3_HOME] HANDOFF=[$T3_HANDOFF]"
fi

# ---------------------------------------------------------------------------
# T4 — TEETH. Stand up a self-contained, v2-BLIND reproduction of the
# pre-#1497 resolver (reads only the legacy BRIDGE_AGENT_HOME_ROOT + the
# empty BRIDGE_AGENT_WORKDIR, with the legacy `.is_dir()` short-circuit and
# no RESOLVED fast-path). Re-run the EXACT same v2-split fixture + env against
# it and assert the v2 resolution NO LONGER holds and the handoff is MISSED.
# This proves T1/T2 fail without the fix — if a future patch silently reverts
# the v2-awareness, the real resolver would match this blind behaviour and T1
# would fail; this test pins that the legacy code path genuinely loses the
# handoff (so the comparison is meaningful, not vacuous).
# ---------------------------------------------------------------------------
BLIND="$SMOKE_DIR/blind_resolver.py"
: >"$BLIND"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Pre-#1497 v2-BLIND resolver reproduction (smoke teeth, self-contained)."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import os'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'def agent_home_root():'
  printf '%s\n' '    explicit = os.environ.get("BRIDGE_AGENT_HOME_ROOT", "").strip()'  # noqa: iso-helper-boundary
  printf '%s\n' '    if explicit:'
  printf '%s\n' '        return Path(explicit).expanduser()'
  printf '%s\n' '    bh = os.environ.get("BRIDGE_HOME", "").strip()'  # noqa: iso-helper-boundary
  printf '%s\n' '    return (Path(bh).expanduser() if bh else Path.home() / ".agent-bridge") / "agents"'
  printf '%s\n' ''
  printf '%s\n' 'def agent_default_home(agent):'
  printf '%s\n' '    return agent_home_root() / agent'
  printf '%s\n' ''
  printf '%s\n' 'def agent_workdir(agent):'
  printf '%s\n' '    explicit = os.environ.get("BRIDGE_AGENT_WORKDIR", "").strip()'  # noqa: iso-helper-boundary
  printf '%s\n' '    if explicit:'
  printf '%s\n' '        return Path(explicit).expanduser()'
  printf '%s\n' '    default = agent_default_home(agent)'
  printf '%s\n' '    if default.is_dir():'
  printf '%s\n' '        return default'
  printf '%s\n' '    return default'
  printf '%s\n' ''
  printf '%s\n' 'def first_existing_path(candidates):'
  printf '%s\n' '    for c in candidates:'
  printf '%s\n' '        try:'
  printf '%s\n' '            if c.exists():'
  printf '%s\n' '                return c'
  printf '%s\n' '        except OSError:'
  printf '%s\n' '            pass'
  printf '%s\n' '    return None'
} >>"$BLIND"

if python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$BLIND" 2>/dev/null; then
  T4_OUT="$(env -i \
    PATH="$PATH" \
    DRIVER_HOOK_COMMON_PATH="$BLIND" \
    DRIVER_AGENT="$V2_AGENT" \
    BRIDGE_HOME="$FIX" \
    BRIDGE_AGENT_HOME_ROOT="$FIX/agents" \
    BRIDGE_AGENT_ROOT_V2="$FIX/data/agents" \
    BRIDGE_AGENT_WORKDIR_RESOLVED="$FIX/data/agents/$V2_AGENT/workdir" \
    python3 "$DRIVER" 2>&1)"
  T4_WD="$(printf '%s\n' "$T4_OUT" | _field WORKDIR)"
  T4_HANDOFF="$(printf '%s\n' "$T4_OUT" | _field HANDOFF)"
  # v2-blind code mis-resolves to the legacy tree (the legacy agents/<a> dir
  # exists, so .is_dir() short-circuits there) and the handoff is MISSED.
  if [[ "$T4_WD" == "$FIX/agents/$V2_AGENT" && -z "$T4_HANDOFF" ]]; then
    _pass "T4: TEETH — v2-blind resolver mis-resolves to legacy + misses the handoff"
  else
    _fail "T4" "TEETH did not bite (v2-blind repro still resolved v2?): WORKDIR=[$T4_WD] HANDOFF=[$T4_HANDOFF]"
  fi
else
  _fail "T4" "could not compile the self-contained v2-blind reproduction for the teeth test"
fi

# ---------------------------------------------------------------------------
# T5 — source guard (bash): bridge-run.sh exports the RESOLVED scalar alias.
# ---------------------------------------------------------------------------
if grep -qE '^export BRIDGE_AGENT_WORKDIR_RESOLVED=' "$BRIDGE_RUN"; then
  _pass "T5: source guard — bridge-run.sh exports BRIDGE_AGENT_WORKDIR_RESOLVED"
else
  _fail "T5" "bridge-run.sh does not export BRIDGE_AGENT_WORKDIR_RESOLVED"
fi

# ---------------------------------------------------------------------------
# T6 — source guard (py): agent_workdir reads BRIDGE_AGENT_WORKDIR_RESOLVED
# before the legacy default `.is_dir()` short-circuit. Extract the function
# body and assert ordering.
# ---------------------------------------------------------------------------
T6_BODY_FILE="$SMOKE_DIR/t6-body.txt"
awk 'BEGIN{capture=0}
  /^def agent_workdir\(/ { capture=1; next }
  capture && /^def [A-Za-z_]/ { capture=0 }
  capture { print }
' "$HOOK_COMMON" >"$T6_BODY_FILE"

RESOLVED_LINE="$(grep -n 'BRIDGE_AGENT_WORKDIR_RESOLVED' "$T6_BODY_FILE" | head -1 | cut -d: -f1)"
SHORTCIRCUIT_LINE="$(grep -n 'default.is_dir()' "$T6_BODY_FILE" | head -1 | cut -d: -f1)"
if [[ -z "$RESOLVED_LINE" ]]; then
  _fail "T6" "agent_workdir body does not reference BRIDGE_AGENT_WORKDIR_RESOLVED"
elif [[ -z "$SHORTCIRCUIT_LINE" ]]; then
  _fail "T6" "agent_workdir body no longer has the legacy default.is_dir() short-circuit to order against"
elif [[ "$RESOLVED_LINE" -lt "$SHORTCIRCUIT_LINE" ]]; then
  _pass "T6: source guard — agent_workdir reads RESOLVED before the legacy short-circuit"
else
  _fail "T6" "agent_workdir reads RESOLVED (line $RESOLVED_LINE) AFTER the legacy short-circuit (line $SHORTCIRCUIT_LINE)"
fi

# ---------------------------------------------------------------------------
# T7 — v2 dynamic / shared-mode: the roster fallback MUST stay reachable.
# v2 signalled, RESOLVED unset, the agent's v2 IDENTITY HOME exists but it has
# NO <root_v2>/<a>/workdir on disk (its real workdir is a project dir resolved
# via the roster). agent_workdir must consult the roster and return the project
# workdir — NOT short-circuit to the identity home. (#1501 r1 BLOCKING: the v2
# branch returned <root_v2>/<a>/home and the roster fallback never ran, so a
# dynamic agent's <project>/NEXT-SESSION.md handoff was missed.)
# ---------------------------------------------------------------------------
T7_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="$DYN_AGENT" \
  DRIVER_ROSTER_WORKDIR="$DYN_PROJECT_WORKDIR" \
  BRIDGE_HOME="$FIX" \
  BRIDGE_AGENT_HOME_ROOT="$FIX/agents" \
  BRIDGE_AGENT_ROOT_V2="$FIX/data/agents" \
  python3 "$DRIVER" 2>&1)"
T7_WD="$(printf '%s\n' "$T7_OUT" | _field WORKDIR)"
T7_HANDOFF="$(printf '%s\n' "$T7_OUT" | _field HANDOFF)"
if [[ "$T7_WD" == "$DYN_PROJECT_WORKDIR" \
   && "$T7_HANDOFF" == "$DYN_PROJECT_WORKDIR/NEXT-SESSION.md" \
   && "$T7_WD" != "$FIX/data/agents/$DYN_AGENT/home" ]]; then
  _pass "T7: v2 dynamic/shared-mode — roster fallback reached, project workdir handoff found"
else
  _fail "T7" "v2 roster fallback unreachable: WORKDIR=[$T7_WD] HANDOFF=[$T7_HANDOFF] (expected project workdir, not the identity home)"
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
