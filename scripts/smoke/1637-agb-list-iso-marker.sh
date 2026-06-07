#!/usr/bin/env bash
# scripts/smoke/1637-agb-list-iso-marker.sh — Issue #1637.
#
# `agb list` (bridge_list_active_agents_numbered) renders each agent's
# resolved workdir in the `cwd=` column and tags it `[missing]` when the
# directory does not exist on disk (Issue #305 Track C). The probe was a
# bare `[[ ! -d "$workdir" ]]`, which collapses two very different
# filesystem states into one:
#
#   * ENOENT — the directory genuinely is not there (stale/leaked
#     registration). This SHOULD show `[missing]`.
#   * EACCES — the directory exists but the controller cannot traverse to
#     it. For an iso (linux-user) agent this is the NORMAL, by-design state:
#     the controller is deliberately outside the agent's iso group, so it
#     cannot enter the iso UID's private home to reach the workdir. The old
#     code mislabeled this live, present agent `[missing]`.
#
# Fix: bridge_workdir_presence() reports present|denied|absent, and the list
# renderer maps `denied` on an iso-mode agent to a distinct `[iso]` marker
# while keeping `[missing]` for genuine ENOENT (iso or not) and for a
# `denied` result on a non-iso agent (the #305 "surface the anomaly"
# intent).
#
# Test matrix (controller POV, the UID that runs `agb list`):
#   T1. Iso agent whose resolved workdir is present-but-permission-blocked
#       (a chmod-000 ancestor reproduces the real 0700 iso-home boundary on
#       a non-root macOS/Linux smoke) → `[iso]`, never `[missing]`.
#   T2. Iso agent whose resolved workdir is genuinely absent (ENOENT) →
#       `[missing]`, never `[iso]`.
#   T3. Normal shared-mode agent with a readable workdir → no marker at all.
#   T4. Unit contract on bridge_workdir_presence: present|denied|absent for
#       readable / permission-blocked / ENOENT / empty inputs.
#
# Footgun #11: no `<<PY`/`<<EOF` heredoc-stdin to a subprocess — the
# in-process harness is a `bash -c '...'` string with the probe override
# defined AFTER sourcing bridge-lib.sh (mirrors
# scripts/smoke/1473-agent-list-iso-state-fallback.sh::harness).

set -euo pipefail

SMOKE_NAME="1637-agb-list-iso-marker"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # The blocked-ancestor fixture is chmod-000; restore it so rm -rf can
  # reap the whole temp root.
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -d "$BRIDGE_AGENT_ROOT_V2" ]]; then
    chmod -R u+rwx "$BRIDGE_AGENT_ROOT_V2" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A_ISO_BLOCKED="iso-blocked"   # iso, workdir present but EACCES → [iso]
A_ISO_ABSENT="iso-absent"     # iso, workdir genuinely ENOENT  → [missing]
A_ISO_FILE="iso-file"         # iso, workdir resolves to a FILE → [missing]
A_SHARED_OK="shared-ok"       # shared, workdir readable        → no marker

write_roster_fixture() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${A_SHARED_OK}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${A_ISO_BLOCKED}
bridge_add_agent_id_if_missing ${A_ISO_BLOCKED}
BRIDGE_AGENT_DESC["${A_ISO_BLOCKED}"]='iso blocked role'
BRIDGE_AGENT_ENGINE["${A_ISO_BLOCKED}"]='claude'
BRIDGE_AGENT_SESSION["${A_ISO_BLOCKED}"]='sess-${A_ISO_BLOCKED}'
BRIDGE_AGENT_SOURCE["${A_ISO_BLOCKED}"]="static"
BRIDGE_AGENT_ISOLATION_MODE["${A_ISO_BLOCKED}"]='linux-user'
BRIDGE_AGENT_OS_USER["${A_ISO_BLOCKED}"]='agent-bridge-${A_ISO_BLOCKED}'
BRIDGE_AGENT_LAUNCH_CMD["${A_ISO_BLOCKED}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A_ISO_BLOCKED}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A_ISO_BLOCKED}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${A_ISO_ABSENT}
bridge_add_agent_id_if_missing ${A_ISO_ABSENT}
BRIDGE_AGENT_DESC["${A_ISO_ABSENT}"]='iso absent role'
BRIDGE_AGENT_ENGINE["${A_ISO_ABSENT}"]='claude'
BRIDGE_AGENT_SESSION["${A_ISO_ABSENT}"]='sess-${A_ISO_ABSENT}'
BRIDGE_AGENT_SOURCE["${A_ISO_ABSENT}"]="static"
BRIDGE_AGENT_ISOLATION_MODE["${A_ISO_ABSENT}"]='linux-user'
BRIDGE_AGENT_OS_USER["${A_ISO_ABSENT}"]='agent-bridge-${A_ISO_ABSENT}'
BRIDGE_AGENT_LAUNCH_CMD["${A_ISO_ABSENT}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A_ISO_ABSENT}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A_ISO_ABSENT}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${A_ISO_FILE}
bridge_add_agent_id_if_missing ${A_ISO_FILE}
BRIDGE_AGENT_DESC["${A_ISO_FILE}"]='iso file role'
BRIDGE_AGENT_ENGINE["${A_ISO_FILE}"]='claude'
BRIDGE_AGENT_SESSION["${A_ISO_FILE}"]='sess-${A_ISO_FILE}'
BRIDGE_AGENT_SOURCE["${A_ISO_FILE}"]="static"
BRIDGE_AGENT_ISOLATION_MODE["${A_ISO_FILE}"]='linux-user'
BRIDGE_AGENT_OS_USER["${A_ISO_FILE}"]='agent-bridge-${A_ISO_FILE}'
BRIDGE_AGENT_LAUNCH_CMD["${A_ISO_FILE}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A_ISO_FILE}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A_ISO_FILE}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${A_SHARED_OK}
bridge_add_agent_id_if_missing ${A_SHARED_OK}
BRIDGE_AGENT_DESC["${A_SHARED_OK}"]='shared ok role'
BRIDGE_AGENT_ENGINE["${A_SHARED_OK}"]='claude'
BRIDGE_AGENT_SESSION["${A_SHARED_OK}"]='sess-${A_SHARED_OK}'
BRIDGE_AGENT_SOURCE["${A_SHARED_OK}"]="static"
BRIDGE_AGENT_WORKDIR["${A_SHARED_OK}"]='${BRIDGE_AGENT_HOME_ROOT}/${A_SHARED_OK}'
BRIDGE_AGENT_LAUNCH_CMD["${A_SHARED_OK}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A_SHARED_OK}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A_SHARED_OK}
EOF

  # Shared agent's readable workdir.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A_SHARED_OK"

  # Iso-blocked agent: create its resolved v2 workdir, then chmod-000 the
  # per-agent root so the controller cannot traverse into it — the same
  # EACCES the real 0700 iso-UID home produces. (The resolved path for a
  # linux-user agent is $BRIDGE_AGENT_ROOT_V2/<agent>/workdir.)
  mkdir -p "$BRIDGE_AGENT_ROOT_V2/$A_ISO_BLOCKED/workdir"
  chmod 000 "$BRIDGE_AGENT_ROOT_V2/$A_ISO_BLOCKED"

  # Iso-absent agent: deliberately do NOT create its workdir → ENOENT. Its
  # readable parent (BRIDGE_AGENT_ROOT_V2) must NOT list the agent, so leave
  # it out entirely.

  # Iso-file agent: its resolved v2 workdir path exists but as a regular FILE,
  # not a directory (a corrupted/stub install). The controller can stat it, so
  # presence is `absent` (not the iso permission boundary) → must render
  # [missing], never [iso]. Pins the #1637 review-r1 file-workdir case
  # end-to-end through the renderer.
  mkdir -p "$BRIDGE_AGENT_ROOT_V2/$A_ISO_FILE"
  : >"$BRIDGE_AGENT_ROOT_V2/$A_ISO_FILE/workdir"
}

# In-process harness: source bridge-lib.sh in the SAME Bash 4+ binary that
# runs this smoke, load the fixture roster, force every agent "active" so
# bridge_active_agent_ids yields all three, then run the list renderer and
# echo its output for the caller to assert against. The probe override is
# appended AFTER the source so it wins over the library definition.
run_list() {
  local _bash_bin="${BASH:-/usr/bin/env bash}"
  BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" \
    "$_bash_bin" -c '
      set +e
      set -uo pipefail
      BRIDGE_SCRIPT_DIR="'"$SMOKE_REPO_ROOT"'"
      export BRIDGE_SCRIPT_DIR
      source "$BRIDGE_SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1
      BRIDGE_ROSTER_CACHE_DISABLE=1 bridge_load_roster >/dev/null 2>&1 || true
      # Force all roster agents active so they all render. The list renderer
      # iterates bridge_active_agent_ids -> bridge_agent_is_active; on this
      # single-UID smoke there is no live tmux server to probe.
      bridge_agent_is_active() { return 0; }
      bridge_list_active_agents_numbered
    '
}

extract_presence_fn() {
  PRESENCE_FN_FILE="$SMOKE_TMP_ROOT/presence-fn.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    awk '/^bridge_workdir_presence\(\) \{/,/^\}/' \
      "$SMOKE_REPO_ROOT/lib/bridge-agents.sh"
  } >"$PRESENCE_FN_FILE"
  grep -q '^bridge_workdir_presence()' "$PRESENCE_FN_FILE" \
    || smoke_fail "extract: bridge_workdir_presence not found in lib/bridge-agents.sh"
}

test_t1_t2_t3_list_markers() {
  write_roster_fixture
  local out
  out="$(run_list)"

  # The iso-blocked agent line must carry [iso], never [missing].
  local iso_line
  iso_line="$(printf '%s\n' "$out" | grep -F " $A_ISO_BLOCKED " || true)"
  smoke_assert_contains "$iso_line" "[iso]" \
    "T1: iso agent with permission-blocked workdir renders [iso]"
  smoke_assert_not_contains "$iso_line" "[missing]" \
    "T1: iso agent with permission-blocked workdir is NOT [missing]"

  # The iso-absent agent (ENOENT) must carry [missing], never [iso].
  local absent_line
  absent_line="$(printf '%s\n' "$out" | grep -F " $A_ISO_ABSENT " || true)"
  smoke_assert_contains "$absent_line" "[missing]" \
    "T2: iso agent with genuinely absent workdir renders [missing]"
  smoke_assert_not_contains "$absent_line" "[iso]" \
    "T2: iso agent with genuinely absent workdir is NOT [iso]"

  # The iso-file agent (resolved workdir is a regular file, not a dir) must
  # carry [missing], never [iso] — the controller CAN stat it, so it is not
  # the permission boundary. Pins the #1637 review-r1 file-workdir case.
  local file_line
  file_line="$(printf '%s\n' "$out" | grep -F " $A_ISO_FILE " || true)"
  smoke_assert_contains "$file_line" "[missing]" \
    "T2b: iso agent whose workdir is a file renders [missing]"
  smoke_assert_not_contains "$file_line" "[iso]" \
    "T2b: iso agent whose workdir is a file is NOT [iso]"

  # The shared agent with a readable workdir carries no marker.
  local shared_line
  shared_line="$(printf '%s\n' "$out" | grep -F " $A_SHARED_OK " || true)"
  smoke_assert_not_contains "$shared_line" "[missing]" \
    "T3: shared agent with readable workdir has no [missing]"
  smoke_assert_not_contains "$shared_line" "[iso]" \
    "T3: shared agent with readable workdir has no [iso]"
  [[ -n "$shared_line" ]] || smoke_fail "T3: shared agent line missing from list output"
}

test_t4_presence_unit() {
  extract_presence_fn
  local readable="$SMOKE_TMP_ROOT/readable"
  local blocked_parent="$SMOKE_TMP_ROOT/blocked"
  local blocked_wd="$blocked_parent/inner/workdir"
  mkdir -p "$readable" "$blocked_wd"
  chmod 000 "$blocked_parent"
  # Final path component is a regular FILE, not a directory: the controller
  # CAN stat it, so it is present-but-not-a-dir → absent, NOT denied. This
  # pins the #1637 review-r1 misclassification (file workdir was returning
  # denied → false [iso]). Also a top-level file (path itself is a file).
  local file_wd="$SMOKE_TMP_ROOT/agentdir/workdir"
  mkdir -p "$SMOKE_TMP_ROOT/agentdir"
  : >"$file_wd"
  local top_file="$SMOKE_TMP_ROOT/topfile"
  : >"$top_file"
  # Dangling (broken) symlink final component: `[[ -e ]]` is false (follows
  # the link to a missing target) but `[[ -L ]]` is true (the link entry is
  # lstat-able). The controller can resolve the entry at the path, so it is
  # present-but-not-a-usable-dir → absent, NOT denied. Pins #1637 review-r2.
  local dangling_wd="$SMOKE_TMP_ROOT/danglingdir/workdir"
  mkdir -p "$SMOKE_TMP_ROOT/danglingdir"
  ln -s "$SMOKE_TMP_ROOT/no-such-target" "$dangling_wd"
  # Symlink TO a real directory must stay `present` (a usable workdir).
  local symdir_target="$SMOKE_TMP_ROOT/symtarget"
  local symdir_wd="$SMOKE_TMP_ROOT/symdir/workdir"
  mkdir -p "$symdir_target" "$SMOKE_TMP_ROOT/symdir"
  ln -s "$symdir_target" "$symdir_wd"

  local out
  out="$("${BASH:-/usr/bin/env bash}" -c '
    set -uo pipefail
    source "'"$PRESENCE_FN_FILE"'"
    echo "PRESENT=$(bridge_workdir_presence "'"$readable"'")"
    echo "DENIED=$(bridge_workdir_presence "'"$blocked_wd"'")"
    echo "ABSENT=$(bridge_workdir_presence "'"$SMOKE_TMP_ROOT"'/nope/nowhere")"
    echo "FILE_FINAL=$(bridge_workdir_presence "'"$file_wd"'")"
    echo "FILE_TOP=$(bridge_workdir_presence "'"$top_file"'")"
    echo "DANGLING=$(bridge_workdir_presence "'"$dangling_wd"'")"
    echo "SYMDIR=$(bridge_workdir_presence "'"$symdir_wd"'")"
    echo "EMPTY=$(bridge_workdir_presence "")"
  ')"

  # Restore so cleanup can reap it.
  chmod -R u+rwx "$blocked_parent" >/dev/null 2>&1 || true

  smoke_assert_contains "$out" "PRESENT=present"  "T4: readable dir -> present"
  smoke_assert_contains "$out" "DENIED=denied"    "T4: permission-blocked ancestor -> denied"
  smoke_assert_contains "$out" "ABSENT=absent"    "T4: ENOENT under readable parent -> absent"
  smoke_assert_contains "$out" "FILE_FINAL=absent" "T4: final component is a file -> absent (not denied/[iso])"
  smoke_assert_contains "$out" "FILE_TOP=absent"  "T4: path itself is a file -> absent"
  smoke_assert_contains "$out" "DANGLING=absent"  "T4: dangling symlink final component -> absent (not denied/[iso])"
  smoke_assert_contains "$out" "SYMDIR=present"   "T4: symlink to a real dir -> present"
  smoke_assert_contains "$out" "EMPTY=absent"     "T4: empty input -> absent"
}

main() {
  smoke_require_cmd bash
  smoke_require_cmd awk
  smoke_require_cmd grep
  smoke_setup_bridge_home "$SMOKE_NAME"

  PRESENCE_FN_FILE=""
  smoke_run "T1-T3: agb list iso/missing/normal markers" test_t1_t2_t3_list_markers
  smoke_run "T4: bridge_workdir_presence unit contract"  test_t4_presence_unit
  smoke_log "passed"
}

main "$@"
