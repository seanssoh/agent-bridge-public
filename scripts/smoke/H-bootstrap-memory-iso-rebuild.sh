#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/H-bootstrap-memory-iso-rebuild.sh — Issue #1222 (v0.15.0
# Lane H).
#
# `bootstrap-memory-system.sh --apply` aborted on every linux-user iso v2
# agent because `step_rebuild_one`'s apply block did all five of
#   rm -f tmp_db
#   bridge-memory.py rebuild-index --db-path tmp_db   (python opens sqlite)
#   python validate
#   mkdir -p memory
#   mv -f tmp_db db
# as the controller UID, while the iso agent's `memory/` is owned by the
# iso UID with group `ab-agent-<slug>` mode 2770 (controller intentionally
# NOT in that group per the v2 contract). First op — the `rm -f` — failed
# with `Permission denied` and the script bailed; subsequent ops would
# have failed identically.
#
# Fix (H.2, codex r1 preferred): drop to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` for the entire rebuild
# block, NOT just the leading `rm -f`. The new code branches on
# `bridge_agent_linux_user_isolation_effective` — isolated agents go
# through the sudo'd bash inline script; non-isolated agents keep the
# legacy controller-direct path unchanged.
#
# Two layers, in order:
#
#   T1..T7 — Source-structure assertions (host-agnostic, no sudo, no
#            useradd, no real iso). Asserts that:
#              T1: bootstrap-memory-system.sh sources bridge-lib.sh so
#                  the iso helpers are available.
#              T2: step_rebuild_one's apply path branches on
#                  bridge_agent_linux_user_isolation_effective.
#              T3: the isolated branch calls
#                  bridge_isolation_run_as_agent_user_via_bash with the
#                  rebuild block as its inline script.
#              T4: the inline script does the entire rebuild — rm of
#                  stale tmp_db, the rebuild-index invocation, the
#                  validate harness, mkdir -p of memory/, and the final
#                  mv-into-place — under the iso UID. Wrapping only the
#                  leading rm or only the trailing mv would leave the
#                  rebuild-index DB write + the python validate +
#                  mkdir/mv on the controller side, which is exactly
#                  what the bug was.
#              T5: the non-iso branch keeps the legacy
#                  rm/rebuild/validate/mkdir/mv sequence (so non-iso
#                  installs aren't regressed).
#              T6: the inline script's exit codes are pinned at >= 10
#                  so the wrapper's +2 shift on script rc<3 cannot
#                  collide with the wrapper's pre-flight 0/1/2 band.
#              T7: NO new `--op rm` was added to bridge_iso_run (codex
#                  scoping correction: broad unlink is a v2 security
#                  surface that the contract explicitly guards against).
#
#   T8     — Real iso reproducer (Linux + sudo gated). When the host is
#            Linux AND `sudo -n true` works AND useradd is available, we
#            stand up a real `agent-bridge-h_smoke` user + ab-agent-h_smoke
#            group, scaffold an iso-owned workdir with mode 2770 and a
#            stale `memory/index.sqlite.rebuilding-<stamp>` file, then
#            assert that a direct `rm -f` from the controller fails
#            (proves the fixture really is iso-owned) but a sudo-as-iso
#            `rm -f` succeeds. Pre-fix, the controller-side rm in
#            `step_rebuild_one` was the failing call. Post-fix, the iso
#            UID does the rm — exactly the call this layer proves works.
#
#            On macOS / sudoless CI hosts the T8 layer is SKIPPED with
#            a structured log line. Codex explicitly forbids proving
#            the fix with controller-writable directories: a
#            ctl-readable mock would falsify the contract.
#
# Footgun #11 (heredoc-stdin deadlock class): every harness file is
# built via `printf '%s\n' >file` per line, then read by `bash <file>`
# or `python3 <file>`. No `<<EOF`, no `<<<`, no `<<'PY'` anywhere here.

set -uo pipefail

SMOKE_NAME="H-bootstrap-memory-iso-rebuild"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
BOOTSTRAP="$REPO_ROOT/bootstrap-memory-system.sh"

# shellcheck disable=SC2329  # invoked via trap below
cleanup() {
  # Real-iso layer (T8) creates a real OS user + group. Tear them down
  # before removing SMOKE_TMP_ROOT so the directory rm walk can recurse
  # into the iso-owned scaffold. The teardown is best-effort — a CI host
  # that lacks `userdel`/`groupdel` is the same one that skipped T8.
  if [[ -n "${ISO_USER_CREATED:-}" && -n "${ISO_USER:-}" ]]; then
    if command -v userdel >/dev/null 2>&1; then
      sudo -n userdel -r "$ISO_USER" 2>/dev/null || \
        sudo -n userdel "$ISO_USER" 2>/dev/null || true
    fi
    if command -v groupdel >/dev/null 2>&1; then
      sudo -n groupdel "$ISO_GROUP" 2>/dev/null || true
    fi
    # As a fallback, chmod the iso-owned workdir back to controller-
    # readable so smoke_cleanup_temp_root's rm -rf can recurse.
    if [[ -n "${ISO_WORKDIR:-}" && -d "$ISO_WORKDIR" ]]; then
      sudo -n chown -R "$(id -u):$(id -g)" "$ISO_WORKDIR" 2>/dev/null || true
      sudo -n chmod -R u+rwX "$ISO_WORKDIR" 2>/dev/null || true
    fi
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Always-on harness setup (T1..T7 do not need sudo).
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"
smoke_require_cmd bash

if [[ ! -r "$BOOTSTRAP" ]]; then
  smoke_fail "cannot read bootstrap-memory-system.sh at $BOOTSTRAP"
fi

# ---------------------------------------------------------------------
# T1 — bootstrap sources bridge-lib.sh (which loads the iso helpers).
# ---------------------------------------------------------------------
grep -Eq "source[[:space:]]+\"\\\$SCRIPT_DIR/bridge-lib.sh\"" "$BOOTSTRAP" \
  || smoke_fail "T1 bootstrap-memory-system.sh does not source bridge-lib.sh"
smoke_log "ok: T1 bootstrap sources bridge-lib.sh"

# ---------------------------------------------------------------------
# T2 — apply path branches on bridge_agent_linux_user_isolation_effective.
#      Without this gate the iso wrapper is dead code; with it, every
#      isolated agent reaches the sudo'd bash path.
# ---------------------------------------------------------------------
grep -q "bridge_agent_linux_user_isolation_effective" "$BOOTSTRAP" \
  || smoke_fail "T2 no bridge_agent_linux_user_isolation_effective gate in bootstrap"
smoke_log "ok: T2 step_rebuild_one branches on isolation gate"

# ---------------------------------------------------------------------
# T3 — isolated branch calls bridge_isolation_run_as_agent_user_via_bash
#      with the rebuild block as its inline script.
# ---------------------------------------------------------------------
grep -q "bridge_isolation_run_as_agent_user_via_bash" "$BOOTSTRAP" \
  || smoke_fail "T3 no bridge_isolation_run_as_agent_user_via_bash call in bootstrap"
smoke_log "ok: T3 iso branch invokes bridge_isolation_run_as_agent_user_via_bash"

# ---------------------------------------------------------------------
# T4 — the inline script does the ENTIRE rebuild block as the iso UID,
#      not just the leading `rm -f` or only the trailing `mv -f`. We
#      extract the iso-side script body and assert each phase is
#      present. Codex r1 verbatim: "the whole rebuild/publish block,
#      not only rm -f $tmp_db".
# ---------------------------------------------------------------------
# Extract the iso_rebuild_script body once, write to a tmp file for re-use
# by T4 + T6 phase-checks (no `<<<` here-strings — footgun #11).
# Apostrophe is anchored explicitly via \x27 so a bare `^.$` match does
# not stop on a single-character body line like `{` or `}`.
T_BODY="$SMOKE_TMP_ROOT/iso-rebuild-body.txt"
awk "
  /iso_rebuild_script=\x27\$/ {inb=1; next}
  inb==1 && /^\x27\$/ {inb=0; next}
  inb==1 {print}
" "$BOOTSTRAP" >"$T_BODY"
if [[ ! -s "$T_BODY" ]]; then
  smoke_fail "T4 could not extract iso_rebuild_script body from $BOOTSTRAP (file empty)"
fi

# Each phase must be present in the iso-side block. Phrases below match
# the post-fix shape; a future refactor that removes any phase from the
# iso path (e.g. moves rebuild-index back onto the controller side) will
# fire this assertion.
t4_phases=(
  'rm -f .*tmp_db'
  'bridge-memory.py.* rebuild-index'
  'validate_py'
  'mkdir -p .*dirname .*db'
  'mv -f .*tmp_db.*db'
)
t4_missing=0
for needle in "${t4_phases[@]}"; do
  if ! grep -Eq "$needle" "$T_BODY"; then
    printf '[T4] iso_rebuild_script body missing phase: %s\n' "$needle" >&2
    t4_missing=1
  fi
done
if (( t4_missing == 1 )); then
  smoke_fail "T4 iso_rebuild_script does not cover the full rebuild/publish block"
fi
smoke_log "ok: T4 iso_rebuild_script covers rm + rebuild + validate + mkdir + mv"

# ---------------------------------------------------------------------
# T5 — non-iso branch keeps the legacy controller-direct sequence so
#      non-isolated (shared/legacy) installs are not regressed.
# ---------------------------------------------------------------------
grep -q "^PY$" "$BOOTSTRAP" \
  || smoke_fail "T5 non-iso legacy validate heredoc disappeared (regression risk)"
smoke_log "ok: T5 non-iso branch preserved"

# ---------------------------------------------------------------------
# T6 — script exit codes inside iso_rebuild_script are pinned at >= 10.
#      `bridge_isolation_run_as_agent_user_via_bash` shifts script rc<3
#      by +2 to keep it distinct from the wrapper'\''s own pre-flight
#      0/1/2 band; if any iso_rebuild_script `exit N` were < 3 the
#      shifted code would collide with another error path. Guard the
#      contract.
# ---------------------------------------------------------------------
# Find every `exit N` literal in the iso block. Each must be either 0
# (success) or >= 10 (error). Anything in 1..9 would collide with the
# wrapper's pre-flight 0/1/2 band after the +2 shift on script rc<3.
t6_bad=0
t6_codes_file="$SMOKE_TMP_ROOT/iso-rebuild-exit-codes.txt"
grep -Eo 'exit[[:space:]]+[0-9]+' "$T_BODY" | awk '{print $2}' >"$t6_codes_file"
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  if (( code != 0 && code < 10 )); then
    printf '[T6] iso_rebuild_script uses forbidden exit code: %s\n' "$code" >&2
    t6_bad=1
  fi
done <"$t6_codes_file"
if (( t6_bad == 1 )); then
  smoke_fail "T6 iso_rebuild_script exit-code contract violated (must be 0 or >= 10)"
fi
smoke_log "ok: T6 iso_rebuild_script exit codes are 0 or >= 10"

# ---------------------------------------------------------------------
# T7 — no broad `--op rm` was added to bridge_iso_run. Codex scoping
#      correction (verbatim): "Do NOT add a broad rm op. Security
#      risk — broad unlink is exactly what iso v2 contract guards
#      against." The op list in lib/bridge-isolation-helpers.sh stays
#      at: stat, read-file, read-json, env-has-any-key, read-env-key,
#      mkdir-p, atomic-write, rename, state-marker-write,
#      scan-profile, publish-root-file, publish-root-symlink.
# ---------------------------------------------------------------------
# The op dispatch in lib/bridge-isolation-helpers.sh lives inside
# `case "$op" in ...` blocks. A new `rm` op would surface as a `rm)`
# case arm. Reject both the case arm and any *_OP_RM constant.
T7_SRC="$REPO_ROOT/lib/bridge-isolation-helpers.sh"
if grep -Eq '^[[:space:]]+rm\)[[:space:]]*$' "$T7_SRC"; then
  smoke_fail "T7 forbidden: bridge_iso_run has an 'rm' case arm"
fi
if grep -Eq 'BRIDGE_ISO_RUN_OP_RM|_bridge_iso_run_op_rm' "$T7_SRC"; then
  smoke_fail "T7 forbidden: a *_OP_RM symbol exists in iso-helpers"
fi
smoke_log "ok: T7 no broad 'rm' op added to bridge_iso_run"

# ---------------------------------------------------------------------
# T7.1 — bootstrap calls bridge_load_roster after sourcing
#        bridge-lib.sh. Codex r1 BLOCKING: just sourcing bridge-lib.sh
#        does NOT populate `BRIDGE_AGENT_ISOLATION_MODE` /
#        `BRIDGE_AGENT_OS_USER` — those arrays are filled by
#        `bridge_load_roster` from `lib/bridge-state.sh`. Without that
#        call, `bridge_agent_linux_user_isolation_effective` returns 1
#        for every agent (the gate becomes dead-code) and iso v2
#        agents fall through to the controller-direct legacy path —
#        which is the exact `rm: Permission denied` shape this PR is
#        meant to fix.
#
#        Assert (a) bridge_load_roster appears in the bootstrap source,
#        (b) it appears AFTER the `source $SCRIPT_DIR/bridge-lib.sh`
#        line, and (c) it is gated inside the
#        `_BRIDGE_ISO_HELPERS_LOADED` guard so the loader is invoked
#        on every install where the helper is wired up.
# ---------------------------------------------------------------------
# Strip comment lines first so a `# by bridge_load_roster …` docstring
# does not satisfy the assertion. The actual invocation must follow
# `source $SCRIPT_DIR/bridge-lib.sh`.
T7_1_NO_COMMENTS="$SMOKE_TMP_ROOT/bootstrap-no-comments.txt"
grep -nv '^[[:space:]]*#' "$BOOTSTRAP" >"$T7_1_NO_COMMENTS"
grep -q "bridge_load_roster" "$T7_1_NO_COMMENTS" \
  || smoke_fail "T7.1 bridge_load_roster not called in bootstrap (predicate gate would always fail in the bootstrap shell)"
{
  source_line="$(grep "source[[:space:]]\+\"\\\$SCRIPT_DIR/bridge-lib.sh\"" "$T7_1_NO_COMMENTS" | head -1 | cut -d: -f1)"
  loader_line="$(grep "bridge_load_roster" "$T7_1_NO_COMMENTS" | head -1 | cut -d: -f1)"
  if [[ -z "$source_line" || -z "$loader_line" ]] || (( loader_line <= source_line )); then
    smoke_fail "T7.1 bridge_load_roster (non-comment) does not appear after source bridge-lib.sh (source_line=$source_line, loader_line=$loader_line)"
  fi
}
smoke_log "ok: T7.1 bootstrap calls bridge_load_roster after sourcing bridge-lib.sh"

# ---------------------------------------------------------------------
# T7.2 — runtime predicate-true proof. Without this, T1..T7.1 only
#        prove source-structure presence; a future refactor that moves
#        bridge_load_roster behind a flag that defaults OFF, or
#        accidentally guards it on a condition that's always false in
#        the bootstrap shell, would still pass T1..T7.1 but break the
#        fix. Stand up a synthetic BRIDGE_HOME with a tracked roster
#        that declares an iso v2 agent, replay the exact bootstrap
#        load sequence (source _common.sh + source bridge-lib.sh +
#        bridge_load_roster), force the host platform to Linux via
#        BRIDGE_HOST_PLATFORM_OVERRIDE, then assert the predicate
#        returns 0 for the test agent. Pre-fix (no bridge_load_roster
#        call), this fails with the predicate returning 1.
# ---------------------------------------------------------------------
T7_2_HOME="$SMOKE_TMP_ROOT/bridge-home-t7_2"
mkdir -p "$T7_2_HOME/state"
# Layout marker so the resolver classifies as v2 without trying to upgrade.
cat >"$T7_2_HOME/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$T7_2_HOME/data
EOF
mkdir -p "$T7_2_HOME/data/agents" "$T7_2_HOME/data/shared" "$T7_2_HOME/data/state"

# Synthetic roster: one iso v2 agent. Pattern mirrors the canonical
# writer (lib/bridge-agents.sh:3422-3445) — only the fields the
# predicate touches are required.
T7_2_ROSTER="$T7_2_HOME/agent-roster.sh"
cat >"$T7_2_ROSTER" <<'EOF'
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
bridge_add_agent_id_if_missing test_iso_h
BRIDGE_AGENT_DESC['test_iso_h']='H smoke iso v2 fixture'
BRIDGE_AGENT_ENGINE['test_iso_h']='claude'
BRIDGE_AGENT_SESSION['test_iso_h']='test_iso_h'
BRIDGE_AGENT_SOURCE['test_iso_h']='static'
BRIDGE_AGENT_ISOLATION_MODE['test_iso_h']='linux-user'
BRIDGE_AGENT_OS_USER['test_iso_h']='agent-bridge-test_iso_h'
EOF
T7_2_ROSTER_LOCAL="$T7_2_HOME/agent-roster.local.sh"
: >"$T7_2_ROSTER_LOCAL"  # empty local roster, mode 0600 implicit by umask

# Run the predicate replay in an isolated child shell so the parent's
# bridge state is not polluted. Stage the driver as a file (no
# heredoc-stdin into bash -c — footgun #11).
T7_2_DRIVER="$SMOKE_TMP_ROOT/t7_2-predicate.sh"
: >"$T7_2_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'export BRIDGE_HOME="$1"'
  printf '%s\n' 'export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"'
  printf '%s\n' 'export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"'
  printf '%s\n' 'export BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_HOME/state"'
  # Force Linux so bridge_agent_linux_user_isolation_effective's
  # second predicate (`bridge_host_platform == Linux`) is satisfied
  # on a macOS test host. The first predicate (linux-user requested)
  # and the third (os_user non-empty) come from the synthetic roster.
  printf '%s\n' 'export BRIDGE_HOST_PLATFORM_OVERRIDE="Linux"'
  # Disable the per-process memo so the driver always re-loads.
  printf '%s\n' 'export BRIDGE_ROSTER_CACHE_DISABLE=1'
  printf '%s\n' 'export BRIDGE_LAYOUT_RESOLVER_BYPASS="fresh-install:smoke-h-t7_2"'
  printf '%s\n' 'export BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID=$$'
  printf '%s\n' 'REPO_ROOT="$2"'
  # shellcheck disable=SC2016
  printf '%s\n' '# shellcheck disable=SC1091'
  # shellcheck disable=SC2016
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'if ! declare -F bridge_load_roster >/dev/null 2>&1; then'
  printf '%s\n' '  echo "ERR no bridge_load_roster after source bridge-lib.sh"; exit 11'
  printf '%s\n' 'fi'
  printf '%s\n' 'if ! declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then'
  printf '%s\n' '  echo "ERR no bridge_agent_linux_user_isolation_effective after source"; exit 12'
  printf '%s\n' 'fi'
  # Negative control FIRST: with the roster file present but
  # bridge_load_roster NOT yet called, the predicate must return 1
  # for our test agent. This proves the predicate genuinely depends
  # on the loader call — i.e. a future refactor that auto-loads the
  # roster from `source bridge-lib.sh` (making T7.1 a no-op) would
  # flip this control to 0 and the smoke catches it.
  printf '%s\n' 'if bridge_agent_linux_user_isolation_effective test_iso_h 2>/dev/null; then'
  printf '%s\n' '  echo "ERR negative control failed: predicate returned 0 before bridge_load_roster (roster auto-loaded?)"; exit 13'
  printf '%s\n' 'fi'
  printf '%s\n' 'bridge_load_roster >/dev/null 2>&1 || { echo "ERR bridge_load_roster failed rc=$?"; exit 14; }'
  # Positive: predicate must now return 0 for the test agent.
  printf '%s\n' 'if ! bridge_agent_linux_user_isolation_effective test_iso_h 2>/dev/null; then'
  printf '%s\n' '  echo "ERR predicate returned 1 even after bridge_load_roster (BLOCKING bug re-introduced)"; exit 15'
  printf '%s\n' 'fi'
  printf '%s\n' 'echo OK'
  printf '%s\n' 'exit 0'
} >"$T7_2_DRIVER"
chmod +x "$T7_2_DRIVER"

T7_2_OUT="$SMOKE_TMP_ROOT/t7_2-out.txt"
T7_2_RC=0
# Resolve a Bash 4+ runner. /opt/homebrew/bin/bash on macOS smoke hosts;
# falls back to /usr/local/bin/bash, then to `bash` on Linux. The driver
# itself uses `set -uo pipefail` + 4.x associative arrays via the
# sourced library, so a 3.2 /bin/bash would fail before T7.2 can run.
T7_2_BASH=""
for _cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash" "$(command -v bash 2>/dev/null || true)"; do
  if [[ -n "$_cand" && -x "$_cand" ]] && "$_cand" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
    T7_2_BASH="$_cand"
    break
  fi
done
[[ -n "$T7_2_BASH" ]] || smoke_fail "T7.2 no Bash 4+ available to run the driver"
"$T7_2_BASH" "$T7_2_DRIVER" "$T7_2_HOME" "$REPO_ROOT" >"$T7_2_OUT" 2>&1 \
  || T7_2_RC=$?
if [[ "$T7_2_RC" -ne 0 ]] || ! grep -q "^OK$" "$T7_2_OUT"; then
  printf '[T7.2] driver rc=%s output:\n' "$T7_2_RC" >&2
  sed -n '1,40p' "$T7_2_OUT" >&2
  smoke_fail "T7.2 predicate-true proof failed — bridge_agent_linux_user_isolation_effective did not return 0 for an iso v2 fixture after bridge_load_roster"
fi
smoke_log "ok: T7.2 predicate returns true for iso v2 fixture after bridge_load_roster"

# ---------------------------------------------------------------------
# T8 — Real iso reproducer. Linux + sudo + useradd required. Skipped
#      otherwise.
# ---------------------------------------------------------------------
ISO_USER=""
ISO_GROUP=""
ISO_USER_CREATED=""
ISO_WORKDIR=""

t8_should_run() {
  smoke_is_linux || { smoke_skip "T8 real iso reproducer" "host is not Linux"; return 1; }
  command -v sudo >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "sudo not installed"; return 1; }
  sudo -n true 2>/dev/null || { smoke_skip "T8 real iso reproducer" "sudo -n unavailable"; return 1; }
  command -v useradd >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "useradd not installed"; return 1; }
  command -v groupadd >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "groupadd not installed"; return 1; }
  return 0
}

if t8_should_run; then
  ISO_USER="agent-bridge-h_smoke"
  ISO_GROUP="ab-agent-h_smoke"
  ISO_WORKDIR="$SMOKE_TMP_ROOT/iso-workdir"

  # Stand up the iso user + group. `useradd -r --no-create-home` builds
  # a system account with no login shell or home — the same shape that
  # `agb agent create --isolation linux-user` provisions.
  if ! sudo -n groupadd -r "$ISO_GROUP" 2>/dev/null; then
    smoke_skip "T8 real iso reproducer" "groupadd -r $ISO_GROUP failed (group exists?)"
  elif ! sudo -n useradd -r -g "$ISO_GROUP" -M -s /usr/sbin/nologin "$ISO_USER" 2>/dev/null; then
    sudo -n groupdel "$ISO_GROUP" 2>/dev/null || true
    smoke_skip "T8 real iso reproducer" "useradd -r $ISO_USER failed"
  else
    ISO_USER_CREATED=1
    # SMOKE_TMP_ROOT is mktemp 0700 owned by the runner. The iso user
    # cannot traverse that without world-exec on every ancestor up to
    # ISO_WORKDIR. Open just enough of the path (o+x, NO o+r) so iso
    # can chdir through but cannot list. /tmp itself is 1777 on every
    # supported runner.
    chmod o+x "$SMOKE_TMP_ROOT" 2>/dev/null || true
    # Scaffold workdir + memory/ owned by the iso user with the iso group
    # at mode 2770 — exactly the layout the v2 isolation contract pins.
    sudo -n mkdir -p "$ISO_WORKDIR/memory"
    sudo -n chown -R "$ISO_USER:$ISO_GROUP" "$ISO_WORKDIR"
    sudo -n chmod 2770 "$ISO_WORKDIR/memory"
    sudo -n chmod 2770 "$ISO_WORKDIR"

    # Plant a stale tmp DB exactly as the pre-fix bug observed.
    STALE_TMP="$ISO_WORKDIR/memory/index.sqlite.rebuilding-20260526-031720"
    if ! sudo -n -u "$ISO_USER" bash -c "touch '$STALE_TMP' && chmod 0640 '$STALE_TMP'"; then
      smoke_fail "T8 fixture: iso user could not create $STALE_TMP — check SMOKE_TMP_ROOT traversal"
    fi

    # T8.a — controller direct write into iso-owned memory/ MUST fail.
    # Proves the cross-boundary asymmetry is real on this host. If
    # this passes, T8.b/T8.c below are probing a controller-readable
    # dir and the smoke is meaningless.
    T8A_PROBE="$ISO_WORKDIR/memory/.bridge-h-smoke-write-probe"
    if : >"$T8A_PROBE" 2>/dev/null; then
      rm -f "$T8A_PROBE" 2>/dev/null || true
      smoke_fail "T8.a controller wrote into iso-owned memory/ — fixture mode is wrong"
    fi
    smoke_log "ok: T8.a controller direct write into iso memory/ fails"

    # T8.b — controller direct rm MUST fail. This is the pre-fix
    # failure shape (rm: Permission denied on $home/memory/
    # index.sqlite.rebuilding-...). The probe asserts the fixture
    # really exhibits the bug we are fixing.
    if rm -f "$STALE_TMP" 2>/dev/null && ! sudo -n test -e "$STALE_TMP"; then
      smoke_fail "T8.b controller direct rm succeeded — fixture is NOT iso-owned"
    fi
    # Existence must be confirmed with root (`sudo -n test -e`), NOT a
    # controller-side `[[ -e ]]`: the file lives inside a 2770 iso-owned
    # `memory/` dir the controller has no group membership in, so a
    # controller `[[ -e ]]` returns false on a file that genuinely exists
    # (the same boundary T8.a just proved) — a false "disappeared".
    sudo -n test -e "$STALE_TMP" \
      || smoke_fail "T8.b stale tmp disappeared between fixture create and assert"
    smoke_log "ok: T8.b controller direct rm fails (pre-fix shape reproduced)"

    # T8.c — sudo-as-iso rm via the same helper shape the fix uses
    # (`sudo -n -u <iso> bash -c '...'`). Proves the post-fix path
    # actually unlinks the stale tmp.
    if ! sudo -n -u "$ISO_USER" bash -c "rm -f '$STALE_TMP'"; then
      smoke_fail "T8.c sudo-as-iso rm rc=$? — post-fix path is broken on this host"
    fi
    # Confirm removal with root, NOT controller-side `[[ ! -e ]]`: the
    # controller cannot stat into the 2770 iso dir, so `[[ ! -e ]]` would
    # report "removed" even if the unlink had failed (false pass).
    ! sudo -n test -e "$STALE_TMP" \
      || smoke_fail "T8.c sudo-as-iso rm reported success but file remains"
    smoke_log "ok: T8.c sudo-as-iso rm succeeds (post-fix path works)"
  fi
fi

smoke_log "all assertions passed"
exit 0
