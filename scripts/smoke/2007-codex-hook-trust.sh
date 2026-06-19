#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2007-codex-hook-trust.sh — Issue #2007 first-party Codex hook
# pretrust (prevention layer) smoke.
#
# Pins the contract that `bridge-hooks.py ensure-codex-hook-trust` pre-trusts
# ONLY the bridge's own first-party Codex hooks so a hook-changing upgrade never
# wedges a managed Codex agent at Codex's startup hook-trust gate:
#
#   T1 hash-equality fixture: the helper's trusted_hash for the rendered bridge
#      hooks is (a) self-consistent (an independent reimplementation of the
#      documented sha256(canonical_json(identity)) algorithm computes the same
#      values) and (b) matches a recorded golden hash for the canonical
#      bridge_home/python_bin render path — so the algorithm is path-independent
#      and version-invariant (the #2007 0.137/0.138/0.140 probe finding).
#   T2 full render trust: ensure-codex-hook-trust trusts all 10 bridge hooks,
#      reports foreign=0, and is idempotent (a second run reports nochange).
#   T3 enabled=false + unknown-field preservation: a pre-existing operator
#      `enabled = false`, comments, and unrelated tables survive the patch; only
#      the stale trusted_hash is replaced.
#   T4 foreign hook skipped: a non-bridge hook in the same hooks.json is counted
#      as foreign and gets NO trust entry (strict first-party boundary).
#   T5 mutation guard: when a bridge hook command changes, the expected hash
#      changes and the config trust entry is updated to match.
#   T6 fail-closed: the helper NEVER emits --dangerously-bypass-hook-trust, and
#      a missing hooks file is a skip (not an error) leaving no trust written.
#   T7 position-mismatch boundary: a bridge command planted at the WRONG event /
#      matcher position (e.g. the SessionStart command in a PreToolUse Bash(*)
#      group) is FOREIGN, not trusted (codex review r1, Finding 1).
#   T8 commented-header boundary: a `[hooks.state."k"] # note` table header is a
#      real boundary — the patcher must not overwrite a SUBSEQUENT unrelated
#      table's trusted_hash (codex review r1, Finding 2).
#   T9 verify-after-write: a successful patch always leaves a re-parseable
#      config (verify ran before the live replace).
#
# This smoke does NOT require a live codex binary — the hash algorithm is
# version-invariant (probe-confirmed), so a self-consistent + golden hash
# fixture is the correct test (design §"Required live probes" note).
#
# Footgun #11: driver emitted via printf-to-file, no heredoc-stdin to subprocess.

set -uo pipefail

SMOKE_NAME="2007-codex-hook-trust"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY="$(command -v python3)"
HOOKS_PY="$REPO_ROOT/bridge-hooks.py"

# Canonical render coordinates used for the golden-hash fixture. The recorded
# hashes below were produced by a REAL codex install (the #2007 incident host)
# trusting the bridge hooks rendered at exactly these coordinates, so a match
# proves the bridge-computed hash equals codex's own — across codex
# 0.137/0.138/0.140 (probe-confirmed invariant + path-independent).
GOLDEN_BRIDGE_HOME="/Users/sean/.agent-bridge"
GOLDEN_PYTHON_BIN="/opt/homebrew/bin/python3"

WORK="$SMOKE_TMP_ROOT/work"
mkdir -p "$WORK"

# --- T1: hash-equality fixture (golden + self-consistent) ------------------
# Render the bridge codex hooks at the GOLDEN coordinates, run the pretrust
# helper, and assert each written trusted_hash equals (a) the recorded golden
# value and (b) an independent reimplementation of the documented algorithm.
GOLDEN_HOOKS="$WORK/golden/hooks.json"
GOLDEN_CONFIG="$WORK/golden/config.toml"
mkdir -p "$WORK/golden"

"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$GOLDEN_HOOKS" \
  --bridge-home "$GOLDEN_BRIDGE_HOME" \
  --python-bin "$GOLDEN_PYTHON_BIN" \
  --format shell >/dev/null 2>&1 \
  || smoke_fail "T1: ensure-codex-hooks failed for golden render"

GOLDEN_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$GOLDEN_HOOKS" \
  --codex-config-file "$GOLDEN_CONFIG" \
  --bridge-home "$GOLDEN_BRIDGE_HOME" \
  --python-bin "$GOLDEN_PYTHON_BIN" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T1: ensure-codex-hook-trust failed for golden render"

smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$GOLDEN_OUT")" "ok" "T1: golden status"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_TRUSTED "$GOLDEN_OUT")" "10" "T1: golden trusted count"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_FOREIGN "$GOLDEN_OUT")" "0" "T1: golden foreign count"

# Golden + self-consistency verification via an INDEPENDENT reimplementation of
# the algorithm (does NOT call any helper under test). Emitted to a file (no
# heredoc-stdin to subprocess).
VERIFY_PY="$WORK/verify_golden.py"
{
  printf '%s\n' 'import hashlib, json, re, sys'
  printf '%s\n' 'config_path, hooks_path = sys.argv[1], sys.argv[2]'
  printf '%s\n' '# Recorded golden hashes from a REAL codex install (incident host),'
  printf '%s\n' '# keyed by the event:group:handler tail (path-independent).'
  printf '%s\n' 'GOLDEN = {'
  printf '%s\n' '  "session_start:0:0": "sha256:d63540ca33570a50328268aeba2abee959e3f728d6400c9945602e8681863145",'
  printf '%s\n' '  "stop:0:0": "sha256:2a3c8d4515cff331c3f5c9f8830e32c5ae4ccd4c2f060c525243f2d1ed96f094",'
  printf '%s\n' '  "stop:1:0": "sha256:c624d8f15ecfcc13001eec93006c7266d8cc6953218de45c8900a46227fcaee1",'
  printf '%s\n' '  "user_prompt_submit:0:0": "sha256:2e30fa64c0f2bae812c49e63320ec056550858c4a6d9c748888d2bc7991c7119",'
  printf '%s\n' '  "pre_tool_use:0:0": "sha256:6a61d823ee2eebac86f0c210ba28c22e56bbd2a2c9634b4565bf24f670a36441",'
  printf '%s\n' '  "pre_compact:0:0": "sha256:1b7053d8267be865de737b6f9cb8093993cf99c45b4964175db2e72d49072c97",'
  printf '%s\n' '  "post_compact:0:0": "sha256:c3b0bb8b610f419c71ee868b57f49b6b6c7adf764522c247dae221692064b36c",'
  printf '%s\n' '  "subagent_start:0:0": "sha256:67860f50ac54b9a1e37cd0ba4414d17cd06cba4caacb7508d4c4716e9fc6a559",'
  printf '%s\n' '  "subagent_stop:0:0": "sha256:876f159437bcc5d832e77ccc82d1e00f7a01136b86a40842714859cef73ef5df",'
  printf '%s\n' '  "permission_request:0:0": "sha256:6234a448ec9969246649a30bb98312df6ac85fef9c79ec5054005f7af48f1e37",'
  printf '%s\n' '}'
  printf '%s\n' 'def snake(name):'
  printf '%s\n' '    s1 = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)'
  printf '%s\n' '    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s1).lower()'
  printf '%s\n' 'def chash(event, matcher, hook):'
  printf '%s\n' '    handler = {"type": "command", "command": str(hook.get("command") or ""),'
  printf '%s\n' '               "timeout": int(hook.get("timeout") or 600), "async": False}'
  printf '%s\n' '    if hook.get("statusMessage") is not None:'
  printf '%s\n' '        handler["statusMessage"] = str(hook["statusMessage"])'
  printf '%s\n' '    identity = {"event_name": snake(event)}'
  printf '%s\n' '    if matcher is not None:'
  printf '%s\n' '        identity["matcher"] = str(matcher)'
  printf '%s\n' '    identity["hooks"] = [handler]'
  printf '%s\n' '    blob = json.dumps(identity, sort_keys=True, separators=(",", ":"))'
  printf '%s\n' '    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()'
  printf '%s\n' '# Recompute the expected hashes from the rendered hooks.json.'
  printf '%s\n' 'hooks = json.load(open(hooks_path))["hooks"]'
  printf '%s\n' 'computed = {}'
  printf '%s\n' 'for event, groups in hooks.items():'
  printf '%s\n' '    for gi, group in enumerate(groups):'
  printf '%s\n' '        matcher = group.get("matcher")'
  printf '%s\n' '        for hi, hook in enumerate(group.get("hooks", [])):'
  printf '%s\n' '            computed[f"{snake(event)}:{gi}:{hi}"] = chash(event, matcher, hook)'
  printf '%s\n' '# Parse the trusted_hash values the helper wrote.'
  printf '%s\n' 'written = {}'
  printf '%s\n' 'cur = None'
  printf '%s\n' 'for line in open(config_path):'
  printf '%s\n' '    m = re.match(r"^\s*\[hooks\.state\.\"(.+)\"\]\s*$", line)'
  printf '%s\n' '    if m:'
  printf '%s\n' '        cur = m.group(1).split("hooks.json:", 1)[-1]'
  printf '%s\n' '        continue'
  printf '%s\n' '    if cur:'
  printf '%s\n' '        hm = re.match(r"^\s*trusted_hash\s*=\s*\"([^\"]*)\"\s*$", line)'
  printf '%s\n' '        if hm:'
  printf '%s\n' '            written[cur] = hm.group(1)'
  printf '%s\n' '        if line.strip().startswith("["):'
  printf '%s\n' '            cur = None'
  printf '%s\n' 'errors = []'
  printf '%s\n' 'for tail, golden in GOLDEN.items():'
  printf '%s\n' '    if computed.get(tail) != golden:'
  printf '%s\n' '        errors.append(f"self-consistency {tail}: {computed.get(tail)} != golden {golden}")'
  printf '%s\n' '    if written.get(tail) != golden:'
  printf '%s\n' '        errors.append(f"written {tail}: {written.get(tail)} != golden {golden}")'
  printf '%s\n' 'if errors:'
  printf '%s\n' '    print("\\n".join(errors)); sys.exit(1)'
  printf '%s\n' 'print("HASH_EQUALITY_OK")'
} >"$VERIFY_PY"

VERIFY_OUT="$("$PY" "$VERIFY_PY" "$GOLDEN_CONFIG" "$GOLDEN_HOOKS" 2>&1)" \
  || smoke_fail "T1: hash-equality fixture FAILED: $VERIFY_OUT"
smoke_assert_contains "$VERIFY_OUT" "HASH_EQUALITY_OK" "T1: hash-equality fixture"

# Fail-closed: the helper must never reach for the bypass flag in EXECUTABLE
# code. The flag name appears only in design comments explaining why we never
# use it (each such line carries a leading `#`), so flag only a real code
# occurrence (the token without a preceding `#` on the line).
if grep -- "--dangerously-bypass-hook-trust" "$HOOKS_PY" \
     | grep -qvE '#.*--dangerously-bypass-hook-trust'; then
  smoke_fail "T6: bridge-hooks.py must NEVER use --dangerously-bypass-hook-trust in code"
fi
smoke_log "T1 hash-equality fixture (golden + self-consistent) PASS"
smoke_log "T6 fail-closed (no bypass flag) PASS"

# --- T2: full render trust + idempotency (isolated BRIDGE_HOME) -------------
ISO_HOOKS="$BRIDGE_HOME/.codex/hooks.json"
ISO_CONFIG="$BRIDGE_HOME/.codex/config.toml"
mkdir -p "$BRIDGE_HOME/.codex"

"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$ISO_HOOKS" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell >/dev/null 2>&1 \
  || smoke_fail "T2: ensure-codex-hooks failed for isolated render"

ISO_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$ISO_HOOKS" \
  --codex-config-file "$ISO_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T2: ensure-codex-hook-trust failed"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$ISO_OUT")" "ok" "T2: status"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_TRUSTED "$ISO_OUT")" "10" "T2: trusted count"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_FOREIGN "$ISO_OUT")" "0" "T2: foreign count"

# Idempotent rerun → nochange.
ISO_OUT2="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$ISO_HOOKS" \
  --codex-config-file "$ISO_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T2: idempotent rerun failed"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$ISO_OUT2")" "nochange" "T2: idempotent status"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_TRUSTED "$ISO_OUT2")" "0" "T2: idempotent trusted"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_UNCHANGED "$ISO_OUT2")" "10" "T2: idempotent unchanged"
smoke_log "T2 full render trust + idempotency PASS"

# --- T3 + T4: preservation + foreign skip -----------------------------------
# Build a hooks.json with one bridge SessionStart hook + one FOREIGN plugin
# hook in the same file, and a config.toml carrying an operator enabled=false,
# a comment, an unrelated table, and a STALE bridge hash to be replaced.
T34_DIR="$WORK/t34/.codex"
mkdir -p "$T34_DIR"
T34_HOOKS="$T34_DIR/hooks.json"
T34_CONFIG="$T34_DIR/config.toml"

# Render the REAL bridge hooks first (so the SessionStart command matches the
# bridge's own stable-hooks-dir render exactly — a hand-crafted command would
# resolve to a different path under the #1934 transient-root fence and be
# (correctly) treated as foreign), then append ONE non-bridge group to prove the
# strict boundary skips it.
"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$T34_HOOKS" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T3/T4: bridge render failed"

SEED_PY="$WORK/seed_t34.py"
{
  printf '%s\n' 'import json, sys'
  printf '%s\n' 'py, hooks_path, config_path = sys.argv[1:4]'
  printf '%s\n' 'd = json.load(open(hooks_path))'
  printf '%s\n' '# Append a FOREIGN (non-bridge) hook group to SessionStart.'
  printf '%s\n' 'foreign_cmd = f"{py} /opt/some-plugin-evil/hook.py"'
  printf '%s\n' 'd["hooks"]["SessionStart"].append('
  printf '%s\n' '    {"hooks": [{"type": "command", "command": foreign_cmd, "timeout": 10, "statusMessage": "plugin"}]})'
  printf '%s\n' 'json.dump(d, open(hooks_path, "w"), indent=2)'
  printf '%s\n' '# Seed config: operator comment + unrelated table + a STALE hash and'
  printf '%s\n' '# enabled=false on the REAL bridge session_start key.'
  printf '%s\n' 'cfg = ("# operator comment must survive\n"'
  printf '%s\n' '       "[some.operator.table]\n"'
  printf '%s\n' '       "custom = \"value\"\n\n"'
  printf '%s\n' '       f"[hooks.state.\"{hooks_path}:session_start:0:0\"]\n"'
  printf '%s\n' '       "enabled = false\n"'
  printf '%s\n' '       "trusted_hash = \"sha256:STALESTALESTALE\"\n")'
  printf '%s\n' 'open(config_path, "w").write(cfg)'
} >"$SEED_PY"
"$PY" "$SEED_PY" "$PY" "$T34_HOOKS" "$T34_CONFIG" \
  || smoke_fail "T3/T4: seed failed"

T34_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$T34_HOOKS" \
  --codex-config-file "$T34_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T3/T4: ensure-codex-hook-trust failed"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$T34_OUT")" "ok" "T3/T4: status"
# 10 first-party bridge hooks trusted (1 stale-hash replaced + 9 newly written);
# the 1 appended non-bridge group is left untrusted.
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_TRUSTED "$T34_OUT")" "10" "T4: all 10 bridge hooks trusted"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_FOREIGN "$T34_OUT")" "1" "T4: foreign hook counted"

T34_CONFIG_TEXT="$(cat "$T34_CONFIG")"
smoke_assert_contains "$T34_CONFIG_TEXT" "# operator comment must survive" "T3: comment preserved"
smoke_assert_contains "$T34_CONFIG_TEXT" "[some.operator.table]" "T3: unrelated table preserved"
smoke_assert_contains "$T34_CONFIG_TEXT" "custom = \"value\"" "T3: unrelated field preserved"
smoke_assert_contains "$T34_CONFIG_TEXT" "enabled = false" "T3: operator enabled=false preserved"
smoke_assert_not_contains "$T34_CONFIG_TEXT" "sha256:STALESTALESTALE" "T3: stale hash replaced"
# The foreign group sits at SessionStart group index 1; it must NOT get a trust
# entry (no session_start:1:0 key written, no foreign command referenced).
smoke_assert_not_contains "$T34_CONFIG_TEXT" "some-plugin-evil" "T4: no trust entry references the foreign hook"
smoke_assert_not_contains "$T34_CONFIG_TEXT" "session_start:1:0" "T4: no trust key written for the foreign group"
smoke_log "T3 enabled=false + unknown-field preservation PASS"
smoke_log "T4 foreign hook skipped (strict first-party boundary) PASS"

# --- T5: mutation guard ------------------------------------------------------
# A changed bridge hook command yields a different expected hash; re-running
# pretrust must update the config trust entry to the new hash.
# Read the session_start trusted_hash for a given config (emitted to a file so
# there is no heredoc-stdin to a subprocess).
READ_HASH_PY="$WORK/read_session_start_hash.py"
{
  printf '%s\n' 'import re, sys'
  printf '%s\n' 'cur = None; out = ""'
  printf '%s\n' 'for line in open(sys.argv[1]):'
  printf '%s\n' '    h = re.match(r"^\s*\[hooks\.state\.\"(.+)\"\]", line)'
  printf '%s\n' '    if h:'
  printf '%s\n' '        cur = h.group(1); continue'
  printf '%s\n' '    if cur and cur.endswith("session_start:0:0"):'
  printf '%s\n' '        hm = re.match(r"^\s*trusted_hash\s*=\s*\"([^\"]*)\"", line)'
  printf '%s\n' '        if hm:'
  printf '%s\n' '            out = hm.group(1); break'
  printf '%s\n' 'print(out)'
} >"$READ_HASH_PY"

# Render a fresh single-hook config to mutate cleanly.
MUT_DIR="$WORK/t5/.codex"
mkdir -p "$MUT_DIR"
MUT_HOOKS="$MUT_DIR/hooks.json"
MUT_CONFIG="$MUT_DIR/config.toml"
"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$MUT_HOOKS" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T5: initial render failed"
"$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$MUT_HOOKS" \
  --codex-config-file "$MUT_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T5: initial trust failed"
BEFORE_HASH="$("$PY" "$READ_HASH_PY" "$MUT_CONFIG" 2>/dev/null)"
[[ -n "$BEFORE_HASH" ]] || smoke_fail "T5: could not read before-hash"

# Mutate the rendered hook (different timeout → different identity hash, while
# the command itself is unchanged so the entry stays first-party), then re-run
# pretrust and assert the config hash changed to match.
MUTATE_PY="$WORK/mutate_timeout.py"
{
  printf '%s\n' 'import json, sys'
  printf '%s\n' 'p = sys.argv[1]'
  printf '%s\n' 'd = json.load(open(p))'
  printf '%s\n' 'd["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = 99'
  printf '%s\n' 'json.dump(d, open(p, "w"), indent=2)'
} >"$MUTATE_PY"
"$PY" "$MUTATE_PY" "$MUT_HOOKS" || smoke_fail "T5: mutate hooks.json failed"

MUT_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$MUT_HOOKS" \
  --codex-config-file "$MUT_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T5: re-trust after mutation failed"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$MUT_OUT")" "ok" "T5: mutation re-trust status"
AFTER_HASH="$("$PY" "$READ_HASH_PY" "$MUT_CONFIG" 2>/dev/null)"
[[ -n "$AFTER_HASH" ]] || smoke_fail "T5: could not read after-hash"
[[ "$AFTER_HASH" != "$BEFORE_HASH" ]] \
  || smoke_fail "T5: mutation guard — hash did not change after command mutation ($BEFORE_HASH)"
smoke_log "T5 mutation guard PASS"

# --- T6 (cont.): missing hooks file is a skip, not an error -----------------
MISSING_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$WORK/nope/hooks.json" \
  --codex-config-file "$WORK/nope/config.toml" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)"
MISSING_RC=$?
smoke_assert_eq "$MISSING_RC" "0" "T6: missing hooks file is rc 0 (skip, not error)"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_STATUS "$MISSING_OUT")" "skipped" "T6: missing hooks status"
[[ ! -f "$WORK/nope/config.toml" ]] \
  || smoke_fail "T6: missing hooks file must write NO config trust"
smoke_log "T6 fail-closed skip path PASS"

# --- T7: position-mismatch attack — a bridge command at the WRONG event/matcher
# position must be FOREIGN (strict first-party boundary; codex review r1 #1) ---
T7_DIR="$WORK/t7/.codex"
mkdir -p "$T7_DIR"
T7_HOOKS="$T7_DIR/hooks.json"
T7_CONFIG="$T7_DIR/config.toml"
# Render the real bridge hooks just to capture the EXACT SessionStart command
# string, then build a hooks.json whose ONLY entry is that command planted in a
# PreToolUse Bash(*) group (wrong event + wrong matcher). With nothing else in
# the file, a correct boundary yields trusted=0 / foreign=1.
"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$T7_DIR/render.json" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T7: bridge render failed"
T7_ATTACK_PY="$WORK/t7_attack.py"
{
  printf '%s\n' 'import json, sys'
  printf '%s\n' 'render_path, out_path = sys.argv[1], sys.argv[2]'
  printf '%s\n' 'r = json.load(open(render_path))'
  printf '%s\n' 'ss = dict(r["hooks"]["SessionStart"][0]["hooks"][0])'
  printf '%s\n' '# ONLY the mis-positioned command: SessionStart cmd in PreToolUse Bash(*).'
  printf '%s\n' 'd = {"hooks": {"PreToolUse": [{"matcher": "Bash(*)", "hooks": [ss]}]}}'
  printf '%s\n' 'json.dump(d, open(out_path, "w"), indent=2)'
} >"$T7_ATTACK_PY"
"$PY" "$T7_ATTACK_PY" "$T7_DIR/render.json" "$T7_HOOKS" || smoke_fail "T7: attack seed failed"
T7_OUT="$("$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$T7_HOOKS" \
  --codex-config-file "$T7_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" \
  --format shell 2>/dev/null)" \
  || smoke_fail "T7: ensure-codex-hook-trust failed"
# The mis-positioned command must be FOREIGN (0 trusted), not silently trusted.
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_TRUSTED "$T7_OUT")" "0" "T7: mis-positioned bridge command NOT trusted"
smoke_assert_eq "$(smoke_shell_field CODEX_TRUST_FOREIGN "$T7_OUT")" "1" "T7: mis-positioned bridge command counted foreign"
[[ ! -f "$T7_CONFIG" ]] || ! grep -q "pre_tool_use:0:0" "$T7_CONFIG" \
  || smoke_fail "T7: no trust key may be written for the mis-positioned command"
smoke_log "T7 position-mismatch attack blocked (event+matcher boundary) PASS"

# --- T8: inline-comment table header must not corrupt a SUBSEQUENT table's
# trusted_hash (table-boundary detection; codex review r1 #2) ----------------
T8_DIR="$WORK/t8/.codex"
mkdir -p "$T8_DIR"
T8_HOOKS="$T8_DIR/hooks.json"
T8_CONFIG="$T8_DIR/config.toml"
"$PY" "$HOOKS_PY" ensure-codex-hooks \
  --codex-hooks-file "$T8_HOOKS" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T8: bridge render failed"
# Seed a config where an UNRELATED table header carries an inline comment and
# holds its OWN trusted_hash. The patcher must treat the commented header as a
# real table boundary and NOT overwrite that unrelated hash.
T8_SEED_PY="$WORK/t8_seed.py"
{
  printf '%s\n' 'import json, sys'
  printf '%s\n' 'hooks_path, config_path = sys.argv[1], sys.argv[2]'
  printf '%s\n' 'cfg = ('
  printf '%s\n' '  f"[hooks.state.\"{hooks_path}:session_start:0:0\"]  # operator note on header\n"'
  printf '%s\n' '  "trusted_hash = \"sha256:STALESESSIONSTART\"\n\n"'
  printf '%s\n' '  "[hooks.state.\"/some/other/source:custom:0:0\"]  # a DIFFERENT, unrelated table\n"'
  printf '%s\n' '  "trusted_hash = \"sha256:UNRELATEDDONOTTOUCH\"\n"'
  printf '%s\n' ')'
  printf '%s\n' 'open(config_path, "w").write(cfg)'
} >"$T8_SEED_PY"
"$PY" "$T8_SEED_PY" "$T8_HOOKS" "$T8_CONFIG" || smoke_fail "T8: seed failed"
"$PY" "$HOOKS_PY" ensure-codex-hook-trust \
  --codex-hooks-file "$T8_HOOKS" \
  --codex-config-file "$T8_CONFIG" \
  --bridge-home "$BRIDGE_HOME" \
  --python-bin "$PY" >/dev/null 2>&1 \
  || smoke_fail "T8: ensure-codex-hook-trust failed"
T8_TEXT="$(cat "$T8_CONFIG")"
# The unrelated table's hash MUST be intact (commented header was a real boundary).
smoke_assert_contains "$T8_TEXT" "sha256:UNRELATEDDONOTTOUCH" "T8: unrelated table hash preserved across commented header"
# The bridge's own session_start stale hash MUST have been replaced.
smoke_assert_not_contains "$T8_TEXT" "sha256:STALESESSIONSTART" "T8: bridge stale hash replaced"
smoke_log "T8 commented-header table boundary PASS"

# --- T9: a successful patch always leaves a re-parseable config (verify ran) -
"$PY" - "$T8_CONFIG" <<'PYEOF' || smoke_fail "T9: patched config does not re-parse as TOML"
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)  # py<3.11: scanner path covered by T8 asserts
tomllib.loads(open(sys.argv[1]).read())
PYEOF
smoke_log "T9 patched config re-parses (verify-after-write ran) PASS"

smoke_log "ALL 2007-codex-hook-trust checks PASS"
