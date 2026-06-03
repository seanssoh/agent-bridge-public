#!/usr/bin/env bash
# dynamic-agent-handoff smoke — issue #509 wave Track C follow-up.
#
# Asserts the SessionStart bootstrap_artifact_context hook surfaces
# `Handoff present: …` for dynamic claude agents whose workdir lives
# outside `$BRIDGE_HOME/agents/<name>/`. Three cases:
#
#   C1 — `BRIDGE_AGENT_WORKDIR` env explicitly points at the dynamic
#        agent's project workdir + NEXT-SESSION.md is there.
#   C2 — env unset, dynamic agent registered via a stubbed
#        `agent-bridge agent list --json` whose row carries the
#        workdir. Hook must consult the roster CLI fallback.
#   C3 — env unset, roster CLI fails (returns rc=1 / empty). Hook
#        must NOT crash; must return empty (graceful fallback to the
#        prior default-home behaviour).

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

# Each case sets up a fresh BRIDGE_HOME under /tmp so the live install
# is never touched. The dynamic agent's project workdir lives at the
# same level (sibling to BRIDGE_HOME), mimicking the operator's
# `--workdir /Users/sean/Projects/repo` shape.

# ----- C1: explicit env --------------------------------------------------
sce1_root="$(mktemp -d -t agb-c1.XXXXXX)"
sce1_home="$sce1_root/bridge-home"
sce1_workdir="$sce1_root/project-workdir"
mkdir -p "$sce1_home/agents" "$sce1_workdir"
cat >"$sce1_workdir/NEXT-SESSION.md" <<'MD'
# Handoff
Read this first.
MD

sce1_out="$(
  BRIDGE_HOME="$sce1_home" \
    BRIDGE_AGENT_WORKDIR="$sce1_workdir" \
    BRIDGE_AGENT_ID=dyn-test \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
import bridge_hook_common as bhc
print(bhc.bootstrap_artifact_context('dyn-test'))
" 2>&1 || true
)"
if [[ "$sce1_out" == *"Handoff present:"* ]]; then
  pass "C1: explicit BRIDGE_AGENT_WORKDIR surfaces Handoff present"
else
  fail "C1: did not surface Handoff present — output: $sce1_out"
fi
rm -rf "$sce1_root"

# ----- C2: env unset, roster CLI returns workdir -------------------------
# Stubs `agent-bridge` via a PATH-prepended script that prints a JSON
# roster row. The hook discovers the CLI via bridge_script_dir() —
# which is the parent of the hooks/ dir — so we need to overlay our
# fake `agent-bridge` next to a copy of bridge_hook_common.py.
sce2_root="$(mktemp -d -t agb-c2.XXXXXX)"
sce2_home="$sce2_root/bridge-home"
sce2_workdir="$sce2_root/project-workdir"
sce2_overlay="$sce2_root/overlay-source"
mkdir -p "$sce2_home/agents" "$sce2_workdir" "$sce2_overlay/hooks"

cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$sce2_overlay/hooks/bridge_hook_common.py"

cat >"$sce2_overlay/agent-bridge" <<EOF
#!/usr/bin/env bash
# fake agent-bridge for C2 smoke
if [[ "\$1" == "agent" && "\$2" == "list" && "\$3" == "--json" ]]; then
  cat <<JSON
[
  {"agent":"dyn-c2","engine":"claude","source":"dynamic","workdir":"$sce2_workdir"}
]
JSON
  exit 0
fi
echo "fake agent-bridge: unsupported invocation: \$*" >&2
exit 1
EOF
chmod +x "$sce2_overlay/agent-bridge"

cat >"$sce2_workdir/NEXT-SESSION.md" <<'MD'
# Handoff (C2)
Read this first.
MD

sce2_out="$(
  BRIDGE_HOME="$sce2_home" \
    BRIDGE_AGENT_ID=dyn-c2 \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$sce2_overlay/hooks')
import bridge_hook_common as bhc
print(bhc.bootstrap_artifact_context('dyn-c2'))
" 2>&1 || true
)"
if [[ "$sce2_out" == *"Handoff present:"* ]]; then
  pass "C2: env unset, roster CLI fallback surfaces Handoff present"
else
  fail "C2: roster CLI fallback did not surface Handoff present — output: $sce2_out"
fi
rm -rf "$sce2_root"

# ----- C3: env unset, roster CLI fails (no crash, empty output) ---------
sce3_root="$(mktemp -d -t agb-c3.XXXXXX)"
sce3_home="$sce3_root/bridge-home"
sce3_overlay="$sce3_root/overlay-source"
mkdir -p "$sce3_home/agents" "$sce3_overlay/hooks"

cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$sce3_overlay/hooks/bridge_hook_common.py"

cat >"$sce3_overlay/agent-bridge" <<'EOF'
#!/usr/bin/env bash
# fake agent-bridge that always fails (simulates roster unreachable)
echo "fake agent-bridge: roster unavailable" >&2
exit 1
EOF
chmod +x "$sce3_overlay/agent-bridge"

# We expect bootstrap_artifact_context to return an empty string (no
# NEXT-SESSION.md found anywhere) without raising or printing a stack
# trace. Capture both stdout and stderr; assert no Python traceback.
sce3_combined="$(
  BRIDGE_HOME="$sce3_home" \
    BRIDGE_AGENT_ID=dyn-c3 \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$sce3_overlay/hooks')
import bridge_hook_common as bhc
out = bhc.bootstrap_artifact_context('dyn-c3')
print(f'OUT={out!r}')
" 2>&1 || true
)"
if [[ "$sce3_combined" == *"OUT=''"* ]] && [[ "$sce3_combined" != *"Traceback"* ]]; then
  pass "C3: roster CLI failure → empty output, no crash"
else
  fail "C3: graceful-fallback contract broken — output: $sce3_combined"
fi
rm -rf "$sce3_root"

# ----- C4: v2 split-brain prefers data/agents/<a>/workdir ---------------
sce4_root="$(mktemp -d -t agb-c4.XXXXXX)"
sce4_home="$sce4_root/bridge-home"
sce4_data="$sce4_root/data"
sce4_agent_root="$sce4_data/agents"
sce4_v2_workdir="$sce4_agent_root/v2-c4/workdir"
sce4_v2_home="$sce4_agent_root/v2-c4/home"
sce4_legacy_home="$sce4_home/agents/v2-c4"
mkdir -p "$sce4_v2_workdir" "$sce4_v2_home" "$sce4_legacy_home"

cat >"$sce4_v2_workdir/NEXT-SESSION.md" <<'MD'
# Handoff (C4 v2)
Read v2 workdir first.
MD
cat >"$sce4_legacy_home/NEXT-SESSION.md" <<'MD'
# Handoff (C4 legacy)
This must not win in v2 mode.
MD

sce4_out="$(
  BRIDGE_HOME="$sce4_home" \
    BRIDGE_DATA_ROOT="$sce4_data" \
    BRIDGE_AGENT_ROOT_V2="$sce4_agent_root" \
    BRIDGE_AGENT_ID=v2-c4 \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
import bridge_hook_common as bhc
print('WORKDIR=' + str(bhc.agent_workdir('v2-c4')))
print('HOME=' + str(bhc.agent_default_home('v2-c4')))
print(bhc.bootstrap_artifact_context('v2-c4'))
" 2>&1 || true
)"
if [[ "$sce4_out" == *"WORKDIR=$sce4_v2_workdir"* \
   && "$sce4_out" == *"HOME=$sce4_v2_home"* \
   && "$sce4_out" == *"Handoff present: NEXT-SESSION.md exists at $sce4_v2_workdir/NEXT-SESSION.md"* ]]; then
  pass "C4: v2 workdir/home beat existing legacy home"
else
  fail "C4: v2 split-brain resolver failed — output: $sce4_out"
fi
rm -rf "$sce4_root"

# ----- C5: BRIDGE_AGENT_WORKDIR_RESOLVED beats bare workdir -------------
sce5_root="$(mktemp -d -t agb-c5.XXXXXX)"
sce5_home="$sce5_root/bridge-home"
sce5_resolved="$sce5_root/resolved-workdir"
sce5_bare="$sce5_root/bare-workdir"
mkdir -p "$sce5_home/agents" "$sce5_resolved" "$sce5_bare"

cat >"$sce5_resolved/NEXT-SESSION.md" <<'MD'
# Handoff (C5 resolved)
Resolved env must win.
MD
cat >"$sce5_bare/NEXT-SESSION.md" <<'MD'
# Handoff (C5 bare)
Bare env must not win when RESOLVED is present.
MD

sce5_out="$(
  BRIDGE_HOME="$sce5_home" \
    BRIDGE_AGENT_WORKDIR_RESOLVED="$sce5_resolved" \
    BRIDGE_AGENT_WORKDIR="$sce5_bare" \
    BRIDGE_AGENT_ID=dyn-c5 \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
import bridge_hook_common as bhc
print('WORKDIR=' + str(bhc.agent_workdir('dyn-c5')))
print(bhc.bootstrap_artifact_context('dyn-c5'))
" 2>&1 || true
)"
if [[ "$sce5_out" == *"WORKDIR=$sce5_resolved"* \
   && "$sce5_out" == *"Handoff present: NEXT-SESSION.md exists at $sce5_resolved/NEXT-SESSION.md"* ]]; then
  pass "C5: BRIDGE_AGENT_WORKDIR_RESOLVED wins over bare env"
else
  fail "C5: RESOLVED workdir did not win — output: $sce5_out"
fi
rm -rf "$sce5_root"

# ----- C6: v2 signalled, NO on-disk v2 workdir → roster fallback ---------
# The v2 dynamic / shared-mode shape (#1498 r1 BLOCKING gap): v2 is signalled
# and the v2 IDENTITY HOME exists, but <root_v2>/<a>/workdir does NOT — the
# agent's real workdir is a project dir resolved via the roster CLI.
# agent_workdir must consult _resolve_workdir_via_roster() and return the
# project workdir, NOT short-circuit to the v2 home/identity path. TEETH: if
# the v2 branch skipped the roster call (returning the non-existent v2 workdir),
# the project handoff would be missed and this assertion fails.
sce6_root="$(mktemp -d -t agb-c6.XXXXXX)"
sce6_home="$sce6_root/bridge-home"
sce6_data="$sce6_root/data"
sce6_agent_root="$sce6_data/agents"
sce6_v2_home="$sce6_agent_root/dyn-c6/home"        # v2 identity home EXISTS
sce6_project="$sce6_root/project-checkout"          # real workdir (via roster)
sce6_overlay="$sce6_root/overlay-source"
# deliberately do NOT create "$sce6_agent_root/dyn-c6/workdir"
mkdir -p "$sce6_home/agents" "$sce6_v2_home" "$sce6_project" "$sce6_overlay/hooks"

cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$sce6_overlay/hooks/bridge_hook_common.py"
cat >"$sce6_overlay/agent-bridge" <<EOF
#!/usr/bin/env bash
# fake agent-bridge for C6 smoke — roster returns the project workdir
if [[ "\$1" == "agent" && "\$2" == "list" && "\$3" == "--json" ]]; then
  cat <<JSON
[
  {"agent":"dyn-c6","engine":"claude","source":"dynamic","workdir":"$sce6_project"}
]
JSON
  exit 0
fi
echo "fake agent-bridge: unsupported invocation: \$*" >&2
exit 1
EOF
chmod +x "$sce6_overlay/agent-bridge"

cat >"$sce6_project/NEXT-SESSION.md" <<'MD'
# Handoff (C6 v2 dynamic)
Real workdir is a project dir resolved via the roster.
MD

sce6_out="$(
  BRIDGE_HOME="$sce6_home" \
    BRIDGE_DATA_ROOT="$sce6_data" \
    BRIDGE_AGENT_ROOT_V2="$sce6_agent_root" \
    BRIDGE_AGENT_ID=dyn-c6 \
    "$PYTHON" -c "
import sys
sys.path.insert(0, '$sce6_overlay/hooks')
import bridge_hook_common as bhc
print('WORKDIR=' + str(bhc.agent_workdir('dyn-c6')))
print(bhc.bootstrap_artifact_context('dyn-c6'))
" 2>&1 || true
)"
if [[ "$sce6_out" == *"WORKDIR=$sce6_project"* \
   && "$sce6_out" == *"Handoff present: NEXT-SESSION.md exists at $sce6_project/NEXT-SESSION.md"* \
   && "$sce6_out" != *"WORKDIR=$sce6_agent_root/dyn-c6"* ]]; then
  pass "C6: v2 + no on-disk v2 workdir → roster fallback reached (project workdir handoff)"
else
  fail "C6: v2 dynamic roster fallback unreachable — output: $sce6_out"
fi
rm -rf "$sce6_root"

# ----- Summary -----------------------------------------------------------
printf '\n[smoke] dynamic-agent-handoff: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
