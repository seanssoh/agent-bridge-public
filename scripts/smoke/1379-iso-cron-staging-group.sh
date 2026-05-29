#!/usr/bin/env bash
# scripts/smoke/1379-iso-cron-staging-group.sh — Issue #1379 (follow-up
# to #1359): the iso-v2 cron-staging file must land in the actor's OWN
# per-agent cross-class group `ab-agent-<a>` (mode 0660), NOT the iso
# UID's user-private group `agent-bridge-<a>` AND NOT any shared group
# the iso UID also belongs to (e.g. `ab-shared`).
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
# actor's OWN per-agent group (`AGB_STAGE_FILE_GROUP` as an untrusted
# HINT / the per-agent dir's own group / derived `<prefix><agent>` — each
# accepted ONLY when its resolved group name is the canonical, purely
# actor-derived `ab-agent-<a>`) and explicitly `chgrp` the staging file
# to it BEFORE the atomic rename — fail-loud if the chgrp cannot be
# applied + verified — plus self-heal the per-agent subdir to 2770+setgid.
#
# Test strategy (Linux-host caveat): smokes run as the operator's UID, so
# the real `ab-agent-<a>` groups + iso UIDs do not exist. We pick a REAL
# supplementary group the current user is a member of (from `id -G`,
# excluding the effective GID) and make it the agent's CANONICAL group by
# setting BRIDGE_AGENT_GROUP_PREFIX="" + ISO_AGENT=<that group name>, so
# `_canonical_actor_group_names(ISO_AGENT) == {ISO_AGENT}`. The chgrp then
# succeeds deterministically and we assert the staged file carries THAT
# gid. patch re-verifies the real `ab-agent-<a>` mapping on a Linux host.
#
# Cases:
#   T1  — write-request resolves the canonical actor group → staged file
#         gid == that group, mode 0660 (NOT user-private), dir self-healed.
#   T1t — TEETH: NO resolvable canonical group (empty hint + non-existent
#         derived group) → file keeps the un-corrected non-shared group
#         (daemon-read-denied repro). Proves T1's gid assertion bites.
#   T1s — SECURITY (codex r2 BLOCKING 1): a SHARED group the writer also
#         belongs to (`ab-shared` stand-in) supplied via AGB_STAGE_FILE_
#         GROUP or as the dir's own group must be REJECTED — the gate is
#         purely actor-name-derived, NOT env-derived. Only the canonical
#         actor group is accepted.
#   T1f — FAIL-LOUD (codex r2 BLOCKING 2): when a canonical gid is
#         resolved but the chgrp+verify fails, write-request must NOT
#         publish + NOT print a uuid; it returns non-zero with an explicit
#         error (no silent user-private-group landing = no silent 30s
#         pickup-timeout reproduction).
#   T2  — fresh-install path: per-agent dir pre-created 0700 no-setgid →
#         file STILL gets the canonical group via the explicit chgrp.
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

group_name_for_gid() {
  local gid="$1"
  getent group "$gid" 2>/dev/null | cut -d: -f1 || true
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

# Pick TWO distinct REAL supplementary groups the current user is a member
# of, both differing from the effective (primary) GID. The first becomes
# the agent's CANONICAL group (the `ab-agent-<a>` stand-in); the second is
# the SHARED-group stand-in (`ab-shared`) that the security gate must
# reject. `chgrp` to either succeeds unprivileged — the same property the
# real iso UID has for its supplementary groups.
MEMBER_GID=""
SHARED_GID=""
for g in $(id -G); do
  [[ "$g" == "$EFFECTIVE_GID" ]] && continue
  if [[ -z "$MEMBER_GID" ]]; then
    MEMBER_GID="$g"
  elif [[ "$g" != "$MEMBER_GID" ]]; then
    SHARED_GID="$g"
    break
  fi
done

if [[ -z "$MEMBER_GID" ]]; then
  smoke_skip "T1/T1s/T1f/T2" "current user has no non-primary supplementary group to use as the canonical-group stand-in"
else
  MEMBER_GROUP_NAME="$(group_name_for_gid "$MEMBER_GID")"
  if [[ -z "$MEMBER_GROUP_NAME" ]]; then
    MEMBER_GROUP_NAME="$("$PY_BIN" -c "import grp,sys;print(grp.getgrgid(int(sys.argv[1])).gr_name)" "$MEMBER_GID" 2>/dev/null || true)"
  fi
  [[ -n "$MEMBER_GROUP_NAME" ]] || smoke_fail "setup: could not resolve a name for gid $MEMBER_GID"

  # Make the member group the agent's canonical group:
  # prefix="" + agent=<member group name> → canonical == member group.
  # The agent name must satisfy staging.py _validate_agent_name
  # (^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$); group names like `ab-controller`
  # / `ab-shared` / `staff` qualify.
  ISO_AGENT="$MEMBER_GROUP_NAME"
  export BRIDGE_AGENT_GROUP_PREFIX=""

  # ---------------------------------------------------------------------------
  # T1 — write-request resolves the canonical actor group → file gid==group.
  # ---------------------------------------------------------------------------
  smoke_log "T1: write-request resolves canonical group ($MEMBER_GROUP_NAME) → file gid=$MEMBER_GID mode 0660"
  T1_PAYLOAD="$(make_payload "$ISO_AGENT" "$ISO_AGENT" "$CURRENT_UID")"
  T1_UUID="$(AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T1_PAYLOAD")"
  T1_UUID="${T1_UUID%%$'\n'*}"
  [[ -n "$T1_UUID" ]] || smoke_fail "T1: write-request returned empty uuid"

  T1_PATH="$STAGING_ROOT/$ISO_AGENT/$T1_UUID.json"
  [[ -f "$T1_PATH" ]] || smoke_fail "T1: staging file missing: $T1_PATH"
  T1_GID="$(stat_gid "$T1_PATH")"
  T1_MODE="$(stat_mode "$T1_PATH")"
  smoke_assert_eq "$MEMBER_GID" "$T1_GID" "T1: staging file must carry the canonical actor group (not user-private)"
  smoke_assert_eq "660" "$T1_MODE" "T1: staging file must be mode 0660"
  # The per-agent dir is self-healed toward 2770+setgid. On Linux assert
  # full 2770; on macOS BSD silently strips the setgid bit on chmod when
  # the owner is not in the dir's target group (bridge-isolation-v2.sh:
  # 1037 footnote), so assert only group-rwx (0770) there. patch
  # re-verifies setgid on a real Linux iso host.
  T1_DIR_MODE="$(stat_mode "$STAGING_ROOT/$ISO_AGENT")"
  if smoke_is_linux; then
    smoke_assert_eq "2770" "$T1_DIR_MODE" "T1: per-agent staging dir must be self-healed to 2770+setgid (Linux)"
  else
    smoke_assert_eq "770" "$T1_DIR_MODE" "T1: per-agent staging dir must be group-rwx 0770 (macOS strips setgid)"
  fi
  smoke_log "ok: T1 — staging file gid=$T1_GID ($MEMBER_GROUP_NAME) mode=$T1_MODE, dir mode=$T1_DIR_MODE"

  # ---------------------------------------------------------------------------
  # T1t TEETH — no resolvable canonical group → file keeps the un-corrected
  #             (non-shared) group. Proves T1's gid assertion bites.
  # ---------------------------------------------------------------------------
  smoke_log "T1t (teeth): no resolvable canonical group → file keeps un-corrected group (repro)"
  TEETH_AGENT="iso-teeth"
  TEETH_DIR="$STAGING_ROOT/$TEETH_AGENT"
  mkdir -p "$TEETH_DIR"
  chmod 0700 "$TEETH_DIR" 2>/dev/null || true
  chown ":$EFFECTIVE_GID" "$TEETH_DIR" 2>/dev/null || true
  TEETH_DIR_GID="$(stat_gid "$TEETH_DIR")"
  TEETH_PAYLOAD="$(make_payload "$TEETH_AGENT" "$TEETH_AGENT" "$CURRENT_UID")"
  # Empty hint + a prefix whose derived `<prefix>iso-teeth` does not exist
  # → no candidate resolves to a canonical group → no chgrp → file keeps
  # the inherited (user-private/effective) group. Note: the dir's own
  # group equals the user-private gid, so candidate 2 is also rejected.
  TEETH_UUID="$(AGB_STAGE_FILE_GROUP="" BRIDGE_AGENT_GROUP_PREFIX="ab-agent-nonexistent-" \
    staging_py write-request "$STAGING_ROOT" "$TEETH_AGENT" "$TEETH_PAYLOAD")"
  TEETH_UUID="${TEETH_UUID%%$'\n'*}"
  TEETH_PATH="$TEETH_DIR/$TEETH_UUID.json"
  [[ -f "$TEETH_PATH" ]] || smoke_fail "T1t: teeth staging file missing"
  TEETH_GID="$(stat_gid "$TEETH_PATH")"
  [[ "$TEETH_GID" != "$MEMBER_GID" ]] || smoke_fail "T1t: teeth gid ($TEETH_GID) must differ from the canonical-group gid ($MEMBER_GID)"
  smoke_assert_eq "$TEETH_DIR_GID" "$TEETH_GID" "T1t: teeth file must keep the un-corrected inherited dir group (no chgrp)"
  smoke_log "ok: T1t — without the chgrp the file lands in gid=$TEETH_GID (≠ canonical $MEMBER_GID; daemon-read-denied repro)"

  # ---------------------------------------------------------------------------
  # T1s SECURITY (codex r2 BLOCKING 1) — a SHARED group the writer also
  # belongs to must be REJECTED. The gate is purely actor-name-derived,
  # NOT env-derived, so a forged `AGB_STAGE_FILE_GROUP=<shared>` (or the
  # dir's own group being a shared group) cannot widen the file group.
  # Deterministic unit assertion on _resolve_staging_gid (dir-mode/file-gid
  # heuristics are ambiguous on macOS where BSD strips setgid).
  # ---------------------------------------------------------------------------
  smoke_log "T1s (security): shared/other group must be REJECTED; only canonical actor group accepted"
  if [[ -z "$SHARED_GID" ]]; then
    SHARED_GROUP_NAME=""
  else
    SHARED_GROUP_NAME="$(group_name_for_gid "$SHARED_GID")"
    if [[ -z "$SHARED_GROUP_NAME" ]]; then
      SHARED_GROUP_NAME="$("$PY_BIN" -c "import grp,sys;print(grp.getgrgid(int(sys.argv[1])).gr_name)" "$SHARED_GID" 2>/dev/null || true)"
    fi
  fi
  T1S_AGENT="iso-shared-gate"
  T1S_DIR="$STAGING_ROOT/$T1S_AGENT"
  mkdir -p "$T1S_DIR"
  # footgun #11: the python body is written to a FILE (cat > file <<'PY',
  # a SAFE write-to-file heredoc) and run file-as-argv ("$PY_BIN" "$_pyf")
  # instead of feeding the interpreter's stdin from a heredoc inside the
  # T1S_OUT="$( ... )" capture (which would be a C1 deadlock site). The
  # quoted <<'PY' means $REPO_ROOT is passed through AGB_REPO_ROOT env.
  T1S_PYF="$(mktemp "${TMPDIR:-/tmp}/1379-t1s-XXXXXX.py")"
  cat >"$T1S_PYF" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))  # noqa: iso-helper-boundary (os.environ read, not a .env file callsite)
import staging
from pathlib import Path

agent = os.environ["AGB_T1S_AGENT"]
d = Path(os.environ["AGB_T1S_DIR"])
shared = os.environ.get("AGB_T1S_SHARED", "")
member = os.environ["AGB_T1S_MEMBER"]
member_gid = int(os.environ["AGB_T1S_MEMBER_GID"])

# The canonical group for T1S_AGENT is ab-agent-iso-shared-gate
# (default prefix), which does NOT exist on this host, so every real
# member group offered is a NON-canonical name and must be rejected.
os.environ["BRIDGE_AGENT_GROUP_PREFIX"] = "ab-agent-"

# (a) forged AGB_STAGE_FILE_GROUP=<shared group the writer belongs to>
#     → must be rejected (name is not the canonical actor group).
if shared:
    os.environ["AGB_STAGE_FILE_GROUP"] = shared
    print("forge_shared=" + ("None" if staging._resolve_staging_gid(agent, d) is None else "ACCEPTED"))
else:
    print("forge_shared=skip")

# (b) forged AGB_STAGE_FILE_GROUP=<member group> (a real group, member,
#     != primary) but NOT the canonical actor group → must be rejected.
os.environ["AGB_STAGE_FILE_GROUP"] = member
print("forge_member=" + ("None" if staging._resolve_staging_gid(agent, d) is None else "ACCEPTED"))

# (c) the canonical actor group IS accepted — set the prefix so the
#     canonical name equals the real member group, then resolve.
os.environ["BRIDGE_AGENT_GROUP_PREFIX"] = ""
os.environ["AGB_STAGE_FILE_GROUP"] = member
canon = staging._resolve_staging_gid(member, d)  # agent == member group name
print("canonical=" + ("None" if canon is None else str(canon)))
PY
  T1S_OUT="$(
    AGB_REPO_ROOT="$REPO_ROOT" \
    AGB_T1S_DIR="$T1S_DIR" AGB_T1S_AGENT="$T1S_AGENT" \
    AGB_T1S_SHARED="${SHARED_GROUP_NAME}" AGB_T1S_MEMBER="$MEMBER_GROUP_NAME" \
    AGB_T1S_MEMBER_GID="$MEMBER_GID" \
    "$PY_BIN" "$T1S_PYF"
  )"
  rm -f "$T1S_PYF"
  T1S_FORGE_SHARED="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^forge_shared=//p')"
  T1S_FORGE_MEMBER="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^forge_member=//p')"
  T1S_CANON="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^canonical=//p')"
  if [[ "$T1S_FORGE_SHARED" != "skip" ]]; then
    smoke_assert_eq "None" "$T1S_FORGE_SHARED" "T1s: forged AGB_STAGE_FILE_GROUP=<shared> must be REJECTED by the actor-name gate"
  fi
  smoke_assert_eq "None" "$T1S_FORGE_MEMBER" "T1s: a real member group that is NOT the canonical actor group must be REJECTED"
  smoke_assert_eq "$MEMBER_GID" "$T1S_CANON" "T1s: the canonical actor group must be ACCEPTED"
  smoke_log "ok: T1s — actor-name gate rejects shared/other groups, accepts only the canonical actor group"

  # ---------------------------------------------------------------------------
  # T1f FAIL-LOUD (codex r2 BLOCKING 2) — when a canonical gid is resolved
  # but the chgrp+verify fails, write-request must NOT publish a file and
  # must NOT print a uuid; it exits non-zero with an explicit error.
  # We force the failure by monkeypatching os.chown to a no-op (so the
  # post-chown stat never confirms the requested gid) and driving
  # cmd_write_request directly.
  # ---------------------------------------------------------------------------
  smoke_log "T1f (fail-loud): chgrp cannot be applied/verified → no publish, no uuid, non-zero rc"
  T1F_AGENT="$MEMBER_GROUP_NAME"   # canonical group resolvable (prefix="")
  T1F_DIR="$STAGING_ROOT/$T1F_AGENT"
  # footgun #11: same file-as-argv extraction as T1s — the python body is a
  # SAFE write-to-file heredoc (cat > file <<'PY'), then run as
  # "$PY_BIN" "$_pyf" inside the T1F_OUT="$( ... )" capture (no
  # heredoc-fed interpreter stdin inside the capture). $REPO_ROOT crosses
  # via AGB_REPO_ROOT so the body stays a quoted <<'PY'.
  T1F_PYF="$(mktemp "${TMPDIR:-/tmp}/1379-t1f-XXXXXX.py")"
  cat >"$T1F_PYF" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))  # noqa: iso-helper-boundary (os.environ read, not a .env file callsite)
import staging

root = os.environ["AGB_T1F_ROOT"]
agent = os.environ["AGB_T1F_AGENT"]
uid = int(os.environ["AGB_T1F_UID"])
primary_gid = int(os.environ["AGB_T1F_PRIMARY_GID"])

# Sanity: a canonical gid resolves (else the fail-loud path is never
# reached and the test is vacuous).
from pathlib import Path
import glob
d = Path(root) / agent
d.mkdir(parents=True, exist_ok=True)
# Snapshot pre-existing request files so we can assert NO NEW file is
# published on the failure path (this dir may be shared with an earlier
# case that legitimately published).
def _requests():
    return {p for p in glob.glob(os.path.join(root, agent, "*.json"))
            if not p.endswith(".result.json")}
before = _requests()
# Pin the dir's group to the writer's PRIMARY gid (!= the requested
# canonical gid) BEFORE patching chown, so that with chown no-op'd the
# temp file inherits the primary group and the post-chown stat shows a
# gid mismatch -> StagingGroupError (the failure we are exercising).
try:
    os.chown(d, -1, primary_gid)
except OSError:
    pass
gid = staging._resolve_staging_gid(agent, d)
print("resolved=" + ("None" if gid is None else str(gid)))

# Monkeypatch os.chown to a no-op so the post-chown stat will NOT show
# the requested gid → _payload_atomic_write must raise StagingGroupError.
_orig_chown = os.chown
os.chown = lambda *a, **k: None  # type: ignore[assignment]
try:
    payload = json.dumps({
        "schema_version": 1, "action": "create", "actor_agent": agent,
        "actor_uid": uid, "agent": agent, "schedule": "0 5 * * *",
        "at": None, "tz": "Asia/Seoul", "title": "fail-loud", "payload": "x",
        "payload_file": None, "kind": "text", "disabled": False,
        "delete_after_run": False,
    })
    # Capture stdout to assert NO uuid is printed on the failure path.
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = staging.cmd_write_request(root, agent, payload)
    print("rc=" + str(rc))
    print("stdout_len=" + str(len(buf.getvalue().strip())))
finally:
    os.chown = _orig_chown  # type: ignore[assignment]

# No NEW request file may be published on the failure path (the temp
# must be unlinked, and any pre-existing file from an earlier case is
# excluded via the before-snapshot).
after = _requests()
print("new_published=" + str(len(after - before)))
PY
  T1F_OUT="$(
    AGB_REPO_ROOT="$REPO_ROOT" \
    AGB_T1F_ROOT="$STAGING_ROOT" AGB_T1F_AGENT="$T1F_AGENT" \
    AGB_T1F_MEMBER="$MEMBER_GROUP_NAME" AGB_T1F_UID="$CURRENT_UID" \
    AGB_T1F_PRIMARY_GID="$EFFECTIVE_GID" \
    AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" BRIDGE_AGENT_GROUP_PREFIX="" \
    "$PY_BIN" "$T1F_PYF"
  )"
  rm -f "$T1F_PYF"
  T1F_RESOLVED="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^resolved=//p')"
  T1F_RC="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^rc=//p')"
  T1F_STDOUT_LEN="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^stdout_len=//p')"
  T1F_NEW_PUBLISHED="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^new_published=//p')"
  [[ "$T1F_RESOLVED" != "None" ]] || smoke_fail "T1f: setup — a canonical gid must resolve (else the fail-loud path is vacuous)"
  [[ "$T1F_RC" != "0" ]] || smoke_fail "T1f: write-request must return non-zero when the chgrp cannot be verified (got rc=$T1F_RC)"
  smoke_assert_eq "0" "$T1F_STDOUT_LEN" "T1f: NO uuid may be printed on the fail-loud path"
  smoke_assert_eq "0" "$T1F_NEW_PUBLISHED" "T1f: NO new staging file may be published when the chgrp fails"
  smoke_log "ok: T1f — fail-loud: rc=$T1F_RC, no uuid, no new published file (silent timeout repro closed)"
  # Clean the dir the T1f probe created so T2/T3 start fresh.
  rm -rf "$T1F_DIR" 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # T2 — fresh-install path: per-agent dir pre-created 0700 no-setgid →
  #      file STILL gets the canonical group via the explicit chgrp.
  # ---------------------------------------------------------------------------
  smoke_log "T2: fresh-install dir (0700 no-setgid) → explicit chgrp still lands canonical group"
  T2_AGENT="$MEMBER_GROUP_NAME"
  T2_DIR="$STAGING_ROOT/$T2_AGENT"
  # Re-create as a fresh user-private 0700 dir (T1 may have self-healed it).
  rm -rf "$T2_DIR" 2>/dev/null || true
  mkdir -p "$T2_DIR"
  chmod 0700 "$T2_DIR" 2>/dev/null || true
  chown ":$EFFECTIVE_GID" "$T2_DIR" 2>/dev/null || true
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

  unset BRIDGE_AGENT_GROUP_PREFIX
fi

# ---------------------------------------------------------------------------
# T3 — #1359 per-agent isolation preserved. The staging file is rooted
#      under the actor's own subdir, and a payload that lies about
#      actor_agent (vs the path dirname) is rejected at apply.
# ---------------------------------------------------------------------------
smoke_log "T3: #1359 per-agent isolation intact (path-rooted actor + payload mismatch reject)"
T3_ACTOR="iso-smoke"

# agent-meta.env so the apply path resolves the iso UID to CURRENT_USER.
META_DIR="$BRIDGE_STATE_DIR/agents/$T3_ACTOR"
mkdir -p "$META_DIR"
cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$BRIDGE_NATIVE_CRON_JOBS_FILE"

# A payload claiming PEER_AGENT, dropped into T3_ACTOR's subdir.
T3_PAYLOAD="$(make_payload "$PEER_AGENT" "$PEER_AGENT" "$CURRENT_UID")"
T3_UUID="$(staging_py write-request "$STAGING_ROOT" "$T3_ACTOR" "$T3_PAYLOAD")"
T3_UUID="${T3_UUID%%$'\n'*}"
[[ -f "$STAGING_ROOT/$T3_ACTOR/$T3_UUID.json" ]] || \
  smoke_fail "T3: staging file must be rooted under the actor's own subdir"
[[ ! -f "$STAGING_ROOT/$PEER_AGENT/$T3_UUID.json" ]] || \
  smoke_fail "T3: staging file must NOT leak into the peer's subdir"

set +e
staging_py apply "$STAGING_ROOT" "$T3_ACTOR" "$T3_UUID" "$BRIDGE_NATIVE_CRON_JOBS_FILE" >/dev/null 2>&1
T3_RC=$?
set -e
[[ "$T3_RC" -ne 0 ]] || smoke_fail "T3: cross-agent payload apply must fail"
T3_RESULT="$STAGING_ROOT/$T3_ACTOR/$T3_UUID.result.json"
T3_AUDIT="$(result_field "$T3_RESULT" audit_action)"
T3_ERROR="$(result_field "$T3_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T3_AUDIT" "T3: audit_action must be rejected"
smoke_assert_contains "$T3_ERROR" "payload_actor_agent_mismatch" "T3: error must explain payload_actor_agent_mismatch"
smoke_log "ok: T3 — #1359 per-agent isolation preserved (error=$T3_ERROR)"

smoke_log "all 1379-iso-cron-staging-group cases passed"
