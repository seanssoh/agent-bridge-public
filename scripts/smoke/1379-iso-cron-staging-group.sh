#!/usr/bin/env bash
# scripts/smoke/1379-iso-cron-staging-group.sh — Issue #1379 (follow-up
# to #1359): the iso-v2 cron-staging file must land in the shared
# cross-class group `ab-agent-<a>` (mode 0660), NOT the iso UID's
# user-private group `agent-bridge-<a>`.
#
# Reproducer (patch v0.15.0-beta5-3 verify, Lane H partial): an iso v2
# agent's `agb cron create` stages
# `state/cron-staging/<a>/<uuid>.json`, but the file is
# `-rw-rw---- agent-bridge-<a> agent-bridge-<a>` — group = the
# user-private group. The daemon (controller) is NOT a member of
# `agent-bridge-<a>`, so its read of the staged file is denied → it
# picks up nothing → 30s pickup timeout → cron create silently fails.
#
# The fix (lib/cron-helpers/staging.py cmd_write_request): resolve the
# shared cross-class group (`AGB_STAGE_FILE_GROUP` from the matrix-aware
# bash caller / the per-agent dir's own group / `<prefix><agent>`) and
# explicitly `chgrp` the staging file to it BEFORE the atomic rename,
# plus self-heal the per-agent subdir to 2770+setgid.
#
# Test strategy (Linux-host caveat): smokes run as the operator's UID,
# so the real `ab-agent-<a>` groups + iso UIDs do not exist. We pick a
# REAL supplementary group the current user is a member of (from
# `id -G`, excluding the effective GID) and point `AGB_STAGE_FILE_GROUP`
# at it. The chgrp then succeeds deterministically and we assert the
# staged file carries THAT gid (not the user-private/effective gid).
# This proves the chgrp+chmod COMMANDS are issued correctly; patch
# re-verifies the real `ab-agent-<a>` group mapping on a Linux iso host.
#
# Cases:
#   T1  — write-request with AGB_STAGE_FILE_GROUP=<member group> →
#         staged file gid == that group, mode 0660 (NOT user-private).
#   T1t — TEETH: write-request with NO resolvable shared group (env
#         unset, fresh user-private dir) → file lands in the writer's
#         effective/user-private group, which is the daemon-read-denied
#         repro. Proves T1's assertion is load-bearing.
#   T2  — fresh-install path: per-agent dir pre-created 0700 no-setgid →
#         file STILL gets the shared group via the explicit chgrp (does
#         not rely on dir setgid inheritance) AND the dir is self-healed
#         to setgid.
#   T3  — #1359 per-agent isolation preserved: the file is written under
#         `<root>/<actor>/`, and a payload that lies about actor_agent
#         (vs the path dirname) is still rejected at apply.

set -euo pipefail

SMOKE_NAME="1379-iso-cron-staging-group"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
EFFECTIVE_GID="$(id -g)"
STAGING_ROOT="$BRIDGE_STATE_DIR/cron-staging"
ISO_AGENT="iso-smoke"
PEER_AGENT="iso-peer"
mkdir -p "$STAGING_ROOT"
chmod 0711 "$STAGING_ROOT" 2>/dev/null || true

export BRIDGE_CRON_STAGING_DIR="$STAGING_ROOT"
export BRIDGE_NATIVE_CRON_JOBS_FILE="$BRIDGE_NATIVE_CRON_JOBS_FILE"

# Portable stat helpers — GNU (Linux) vs BSD (macOS) flag split.
stat_gid() {
  stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1" 2>/dev/null || echo '?'
}
stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

staging_py() {
  "$PY_BIN" "$REPO_ROOT/lib/cron-helpers/staging.py" "$@"
}

result_field() {
  local result_path="$1"
  local field="$2"
  "$PY_BIN" - "$result_path" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
val = data.get(sys.argv[2])
print("" if val is None else val)
PY
}

make_payload() {
  local actor="$1" target="$2" uid="$3"
  "$PY_BIN" - "$actor" "$target" "$uid" <<'PY'
import json
import sys

actor, target, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    "schema_version": 1,
    "action": "create",
    "actor_agent": actor,
    "actor_uid": uid,
    "agent": target,
    "schedule": "0 5 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"{target}-daily-brief",
    "payload": "Run the morning brief.",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
}

# Pick a REAL supplementary group the current user is a member of and
# whose GID differs from the effective GID. `chgrp` to it then succeeds
# unprivileged — the same property the real iso UID has for its
# `ab-agent-<a>` supplementary group.
MEMBER_GID=""
for g in $(id -G); do
  if [[ "$g" != "$EFFECTIVE_GID" ]]; then
    MEMBER_GID="$g"
    break
  fi
done

# ---------------------------------------------------------------------------
# T1 — write-request with a resolvable shared group → file gid == group,
#      mode 0660.
# ---------------------------------------------------------------------------
if [[ -z "$MEMBER_GID" ]]; then
  smoke_skip "T1" "current user has no non-primary supplementary group to use as the shared-group stand-in"
else
  smoke_log "T1: write-request with shared group → staged file gid=$MEMBER_GID mode 0660"
  MEMBER_GROUP_NAME="$(getent group "$MEMBER_GID" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$MEMBER_GROUP_NAME" ]]; then
    # macOS has no getent; resolve via python grp.
    MEMBER_GROUP_NAME="$("$PY_BIN" -c "import grp,sys;print(grp.getgrgid(int(sys.argv[1])).gr_name)" "$MEMBER_GID" 2>/dev/null || true)"
  fi
  [[ -n "$MEMBER_GROUP_NAME" ]] || smoke_fail "T1: could not resolve a name for gid $MEMBER_GID"

  T1_PAYLOAD="$(make_payload "$ISO_AGENT" "$ISO_AGENT" "$CURRENT_UID")"
  T1_UUID="$(AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T1_PAYLOAD")"
  T1_UUID="${T1_UUID%%$'\n'*}"
  [[ -n "$T1_UUID" ]] || smoke_fail "T1: write-request returned empty uuid"

  T1_PATH="$STAGING_ROOT/$ISO_AGENT/$T1_UUID.json"
  [[ -f "$T1_PATH" ]] || smoke_fail "T1: staging file missing: $T1_PATH"
  T1_GID="$(stat_gid "$T1_PATH")"
  T1_MODE="$(stat_mode "$T1_PATH")"
  smoke_assert_eq "$MEMBER_GID" "$T1_GID" "T1: staging file must carry the resolved shared group (not user-private)"
  smoke_assert_eq "660" "$T1_MODE" "T1: staging file must be mode 0660"
  # The per-agent dir is self-healed toward 2770+setgid. The setgid bit
  # is the belt-and-suspenders layer (the explicit per-file chgrp above
  # is the load-bearing fix). On Linux assert the full 2770; on macOS
  # BSD silently strips the setgid bit on `chmod` when the owner is not
  # in the dir's target group (bridge-isolation-v2.sh:1037 footnote), so
  # we only assert group-rwx (0770) there. patch re-verifies setgid on a
  # real Linux iso host.
  T1_DIR_MODE="$(stat_mode "$STAGING_ROOT/$ISO_AGENT")"
  if smoke_is_linux; then
    smoke_assert_eq "2770" "$T1_DIR_MODE" "T1: per-agent staging dir must be self-healed to 2770+setgid (Linux)"
  else
    smoke_assert_eq "770" "$T1_DIR_MODE" "T1: per-agent staging dir must be group-rwx 0770 (macOS strips setgid)"
  fi
  smoke_log "ok: T1 — staging file gid=$T1_GID ($MEMBER_GROUP_NAME) mode=$T1_MODE, dir mode=$T1_DIR_MODE"

  # ---------------------------------------------------------------------------
  # T1 TEETH — revert the chgrp (no resolvable shared group) → file lands
  #            in the writer's user-private/effective group, which is the
  #            daemon-read-denied repro. Proves T1's gid assertion bites.
  # ---------------------------------------------------------------------------
  smoke_log "T1t (teeth): no shared group resolvable → file keeps the un-corrected (non-shared) group (repro)"
  TEETH_AGENT="iso-teeth"
  TEETH_DIR="$STAGING_ROOT/$TEETH_AGENT"
  mkdir -p "$TEETH_DIR"
  # No setgid so there is no shared-group inheritance, and force the env
  # so staging.py's resolution chain finds nothing valid: empty
  # AGB_STAGE_FILE_GROUP, a derived-prefix that resolves to a
  # non-existent group, and a dir whose own group is the writer's
  # user-private/effective group (rejected as candidate 2).
  chmod 0700 "$TEETH_DIR" 2>/dev/null || true
  chown ":$EFFECTIVE_GID" "$TEETH_DIR" 2>/dev/null || true
  TEETH_DIR_GID="$(stat_gid "$TEETH_DIR")"
  TEETH_PAYLOAD="$(make_payload "$TEETH_AGENT" "$TEETH_AGENT" "$CURRENT_UID")"
  TEETH_UUID="$(AGB_STAGE_FILE_GROUP="" BRIDGE_AGENT_GROUP_PREFIX="ab-agent-nonexistent-" \
    staging_py write-request "$STAGING_ROOT" "$TEETH_AGENT" "$TEETH_PAYLOAD")"
  TEETH_UUID="${TEETH_UUID%%$'\n'*}"
  TEETH_PATH="$TEETH_DIR/$TEETH_UUID.json"
  [[ -f "$TEETH_PATH" ]] || smoke_fail "T1t: teeth staging file missing"
  TEETH_GID="$(stat_gid "$TEETH_PATH")"
  # With no resolvable shared group, no chgrp happens — the file keeps
  # the un-corrected inherited group (the dir's own group), which is the
  # broken daemon-read-denied state #1379 reports. The load-bearing
  # assertion: this gid DIFFERS from the T1 shared-group gid — proving
  # the explicit chgrp in T1 is what closes the bug.
  [[ "$TEETH_GID" != "$MEMBER_GID" ]] || smoke_fail "T1t: teeth gid ($TEETH_GID) must differ from the T1 shared-group gid ($MEMBER_GID)"
  smoke_assert_eq "$TEETH_DIR_GID" "$TEETH_GID" "T1t: teeth file must keep the un-corrected inherited dir group (no chgrp)"
  smoke_log "ok: T1t — without the chgrp the file lands in gid=$TEETH_GID (≠ shared gid $MEMBER_GID; daemon-read-denied repro)"

  # ---------------------------------------------------------------------------
  # T1s (codex r1 BLOCKING security gate) — a SHARED group the writer
  # also belongs to (stand-in for `ab-shared`) must NOT be selected for
  # the per-agent staging file/dir, even though it satisfies "resolves +
  # != user-private + writer-is-a-member". Selecting it would reopen the
  # cross-agent write/read surface the matrix avoids for the per-agent
  # leaf. We present the shared group only via the dir's own group
  # (candidate 2) — NOT via AGB_STAGE_FILE_GROUP — and via a prefix whose
  # derived `<prefix><actor>` does not exist, so the actor-name gate is
  # the only thing standing between accept and reject.
  smoke_log "T1s (security): shared member group must be REJECTED by the actor-name gate"
  # Deterministic, cross-platform unit assertion on _resolve_staging_gid
  # directly (dir-mode/file-gid heuristics are ambiguous on macOS where
  # BSD strips setgid). We import the resolver and prove that:
  #   (a) a SHARED member group offered as the dir's own group (candidate
  #       2) is NOT selected — even though it resolves, differs from the
  #       user-private gid, and the writer is a member — because its name
  #       is not the actor's own per-agent group; resolver returns None.
  #   (b) the SAME group, when its name IS whitelisted via
  #       AGB_STAGE_FILE_GROUP (the production path = bridge resolves
  #       ab-agent-<a>), IS selected. This isolates the name gate as the
  #       single discriminator.
  T1S_AGENT="iso-shared-gate"
  T1S_DIR="$STAGING_ROOT/$T1S_AGENT"
  mkdir -p "$T1S_DIR"
  chown ":$MEMBER_GID" "$T1S_DIR" 2>/dev/null || true
  T1S_OUT="$(
    AGB_STAGE_FILE_GROUP="" BRIDGE_AGENT_GROUP_PREFIX="ab-agent-nonexistent-" \
    AGB_T1S_DIR="$T1S_DIR" AGB_T1S_AGENT="$T1S_AGENT" AGB_T1S_GROUP="$MEMBER_GROUP_NAME" \
    "$PY_BIN" - <<PY
import os, sys
sys.path.insert(0, os.path.join("$REPO_ROOT", "lib", "cron-helpers"))
import staging
from pathlib import Path

agent = os.environ["AGB_T1S_AGENT"]
d = Path(os.environ["AGB_T1S_DIR"])

# (a) shared group only via dir-group + non-matching name → must reject.
rejected = staging._resolve_staging_gid(agent, d)
print("rejected=" + ("None" if rejected is None else str(rejected)))

# (b) same group whitelisted via AGB_STAGE_FILE_GROUP → must accept.
os.environ["AGB_STAGE_FILE_GROUP"] = os.environ["AGB_T1S_GROUP"]
accepted = staging._resolve_staging_gid(agent, d)
print("accepted=" + ("None" if accepted is None else str(accepted)))
PY
  )"
  T1S_REJECTED="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^rejected=//p')"
  T1S_ACCEPTED="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^accepted=//p')"
  smoke_assert_eq "None" "$T1S_REJECTED" "T1s: shared group (non-actor-name) must be REJECTED by the gate"
  smoke_assert_eq "$MEMBER_GID" "$T1S_ACCEPTED" "T1s: same group whitelisted by AGB_STAGE_FILE_GROUP must be accepted"
  smoke_log "ok: T1s — actor-name gate rejects shared group, accepts whitelisted actor group"
fi

# ---------------------------------------------------------------------------
# T2 — fresh-install path: per-agent dir pre-created 0700 no-setgid →
#      file STILL gets the shared group via the explicit chgrp, and the
#      dir is self-healed to setgid. Skipped if no member group.
# ---------------------------------------------------------------------------
if [[ -z "$MEMBER_GID" ]]; then
  smoke_skip "T2" "no shared-group stand-in available"
else
  smoke_log "T2: fresh-install dir (0700 no-setgid) → explicit chgrp still lands shared group"
  T2_AGENT="iso-fresh"
  T2_DIR="$STAGING_ROOT/$T2_AGENT"
  mkdir -p "$T2_DIR"
  chmod 0700 "$T2_DIR" 2>/dev/null || true
  T2_PAYLOAD="$(make_payload "$T2_AGENT" "$T2_AGENT" "$CURRENT_UID")"
  T2_UUID="$(AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py write-request "$STAGING_ROOT" "$T2_AGENT" "$T2_PAYLOAD")"
  T2_UUID="${T2_UUID%%$'\n'*}"
  T2_PATH="$T2_DIR/$T2_UUID.json"
  [[ -f "$T2_PATH" ]] || smoke_fail "T2: staging file missing"
  T2_GID="$(stat_gid "$T2_PATH")"
  smoke_assert_eq "$MEMBER_GID" "$T2_GID" "T2: explicit chgrp must override the fresh-install user-private dir group"
  T2_DIR_MODE="$(stat_mode "$T2_DIR")"
  if smoke_is_linux; then
    smoke_assert_eq "2770" "$T2_DIR_MODE" "T2: fresh dir must be self-healed to 2770+setgid (Linux)"
  else
    smoke_assert_eq "770" "$T2_DIR_MODE" "T2: fresh dir must be group-rwx 0770 (macOS strips setgid)"
  fi
  smoke_log "ok: T2 — fresh-install dir self-healed (mode=$T2_DIR_MODE), file gid=$T2_GID"
fi

# ---------------------------------------------------------------------------
# T3 — #1359 per-agent isolation preserved. The staging file is rooted
#      under the actor's own subdir, and a payload that lies about
#      actor_agent (vs the path dirname) is rejected at apply.
# ---------------------------------------------------------------------------
smoke_log "T3: #1359 per-agent isolation intact (path-rooted actor + payload mismatch reject)"

# agent-meta.env so the apply path resolves the iso UID to CURRENT_USER.
META_DIR="$BRIDGE_STATE_DIR/agents/$ISO_AGENT"
mkdir -p "$META_DIR"
cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$BRIDGE_NATIVE_CRON_JOBS_FILE"

# A payload claiming PEER_AGENT, dropped into ISO_AGENT's subdir.
T3_PAYLOAD="$(make_payload "$PEER_AGENT" "$PEER_AGENT" "$CURRENT_UID")"
T3_UUID="$(staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T3_PAYLOAD")"
T3_UUID="${T3_UUID%%$'\n'*}"
# The file must be rooted under the ACTOR's subdir (path-derived actor),
# not the payload's claimed agent.
[[ -f "$STAGING_ROOT/$ISO_AGENT/$T3_UUID.json" ]] || \
  smoke_fail "T3: staging file must be rooted under the actor's own subdir"
[[ ! -f "$STAGING_ROOT/$PEER_AGENT/$T3_UUID.json" ]] || \
  smoke_fail "T3: staging file must NOT leak into the peer's subdir"

set +e
staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T3_UUID" "$BRIDGE_NATIVE_CRON_JOBS_FILE" >/dev/null 2>&1
T3_RC=$?
set -e
[[ "$T3_RC" -ne 0 ]] || smoke_fail "T3: cross-agent payload apply must fail"
T3_RESULT="$STAGING_ROOT/$ISO_AGENT/$T3_UUID.result.json"
T3_AUDIT="$(result_field "$T3_RESULT" audit_action)"
T3_ERROR="$(result_field "$T3_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T3_AUDIT" "T3: audit_action must be rejected"
smoke_assert_contains "$T3_ERROR" "payload_actor_agent_mismatch" "T3: error must explain payload_actor_agent_mismatch"
smoke_log "ok: T3 — #1359 per-agent isolation preserved (error=$T3_ERROR)"

smoke_log "all 1379-iso-cron-staging-group cases passed"
