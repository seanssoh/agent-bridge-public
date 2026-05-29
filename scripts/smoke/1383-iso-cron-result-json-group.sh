#!/usr/bin/env bash
# scripts/smoke/1383-iso-cron-result-json-group.sh — Issue #1383 (follow-up
# to #1379 / #1359): the daemon-written `<uuid>.result.json` must land in
# the actor's OWN per-agent cross-class group `ab-agent-<a>` (mode 0660),
# NOT the controller's default/user-private group AND NOT any shared group
# (e.g. `ab-shared`), so the iso UID owner of the request can read its OWN
# cron result without a `PermissionError [Errno 13]`.
#
# Reproducer (patch v0.15.0-beta5-4 verify v2, cm-prod): an iso v2 agent's
# `agb cron create` stages a request the daemon now reads (O #1379 fixed),
# the cron job IS created, but the daemon-written result file lands
# `-rw-rw---- awfmanager awfmanager` (1003:1003) — group = the controller's
# default group. The iso UID (988) is neither owner nor group member →
# `PermissionError [Errno 13]` → `cron-staging cannot parse … .result.json`.
# The cron job runs, but the iso agent cannot read its own result-feedback.
#
# The fix (lib/cron-helpers/staging.py _write_result via _resolve_result_gid
# + _result_atomic_write): after building the result payload, resolve the
# actor's OWN per-agent group (the per-agent dir's own group / derived
# `<prefix><agent>` / `AGB_STAGE_FILE_GROUP` hint — each accepted ONLY when
# its resolved group name is the canonical, purely actor-derived
# `ab-agent-<a>`, NEVER `ab-shared`, NEVER the controller's own group) and
# explicitly `chgrp` the result file to it BEFORE the atomic rename. The
# chgrp is fail-loud-but-publish: a verify failure logs LOUD to stderr but
# STILL publishes (the result file is the only channel back to the iso
# poller — refusing to write it would strand the poller + turn the request
# into a poison-retry).
#
# Daemon-side note: the daemon writes the result as the controller, which
# in iso v2 is usually root. Root can chgrp to a non-member group; a
# non-root controller (shared-mode, test harness) can only chgrp to a group
# it is a member of. The resolver gates membership with `_writer_can_chown`
# (root → always; else must be a member) rather than the request leg's
# `_writer_in_group`.
#
# Test strategy (Linux-host caveat): smokes run as the operator's UID (not
# root, no real `ab-agent-<a>` groups / iso UIDs). We pick a REAL
# supplementary group the current user is a member of (from `id -G`,
# excluding the effective GID) and make it the agent's CANONICAL group by
# setting BRIDGE_AGENT_GROUP_PREFIX="" + actor=<that group name>, so
# `_canonical_actor_group_names(actor) == {actor}`. The chgrp then succeeds
# deterministically (the operator is a member) and we assert the result
# file carries THAT gid. patch re-verifies the real root-daemon +
# `ab-agent-<a>` mapping on a Linux iso host (the real gate).
#
# Cases:
#   T1  — _write_result resolves the canonical actor group → result.json
#         gid == that group, mode 0660 (NOT controller-group), iso-readable.
#   T1t — TEETH: revert the result chgrp (no resolvable canonical group) →
#         result keeps the controller's default group → iso-read denied
#         repro (Errno 13). Proves T1's gid assertion bites.
#   T1s — SECURITY: a SHARED / non-canonical group must be REJECTED by the
#         resolver — the gate is purely actor-name-derived. Also asserts the
#         controller's OWN egid is rejected (it IS the #1383 bug group).
#   T1f — FAIL-LOUD-BUT-PUBLISH: when a canonical gid resolves but the chgrp
#         verify fails, _result_atomic_write must STILL publish the result
#         (poller not stranded) AND emit a loud stderr warning (the #1383
#         fail-loud signal). Contrast the request leg, which REFUSES.
#   T2  — fresh-install path: per-agent dir pre-created 0700 no-setgid → the
#         result STILL gets the canonical group via the explicit chgrp.
#   T3  — full apply path: a valid staged request applied by the daemon-side
#         `apply` writes a result whose group is the canonical actor group
#         and mode 0660 (end-to-end, not just the unit writer).
#   T4  — #1379 request-path UNCHANGED: a write-request still lands the
#         request file in the canonical group 0660 (no regression of O).

set -euo pipefail

SMOKE_NAME="1383-iso-cron-result-json-group"
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

# Pick a REAL supplementary group the current user is a member of, differing
# from the effective (primary) GID — the `ab-agent-<a>` stand-in. `chgrp` to
# it succeeds unprivileged (the same property the real iso UID / a root
# daemon has).
MEMBER_GID=""
for g in $(id -G); do
  [[ "$g" == "$EFFECTIVE_GID" ]] && continue
  MEMBER_GID="$g"
  break
done

if [[ -z "$MEMBER_GID" ]]; then
  smoke_skip "T1/T1t/T1s/T1f/T2/T3" "current user has no non-primary supplementary group to use as the canonical-group stand-in"
else
  MEMBER_GROUP_NAME="$(group_name_for_gid "$MEMBER_GID")"
  if [[ -z "$MEMBER_GROUP_NAME" ]]; then
    MEMBER_GROUP_NAME="$("$PY_BIN" -c "import grp,sys;print(grp.getgrgid(int(sys.argv[1])).gr_name)" "$MEMBER_GID" 2>/dev/null || true)"
  fi
  [[ -n "$MEMBER_GROUP_NAME" ]] || smoke_fail "setup: could not resolve a name for gid $MEMBER_GID"

  # Make the member group the agent's canonical group: prefix="" +
  # agent=<member group name> → canonical == member group. The agent name
  # must satisfy staging.py _validate_agent_name
  # (^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$); group names like `ab-controller`,
  # `ab-shared`, `staff` qualify.
  ISO_AGENT="$MEMBER_GROUP_NAME"
  export BRIDGE_AGENT_GROUP_PREFIX=""

  # ---------------------------------------------------------------------------
  # T1 — _write_result resolves the canonical actor group → result gid==group.
  # ---------------------------------------------------------------------------
  smoke_log "T1: _write_result resolves canonical group ($MEMBER_GROUP_NAME) → result.json gid=$MEMBER_GID mode 0660"
  T1_AGENT="$ISO_AGENT"
  T1_DIR="$STAGING_ROOT/$T1_AGENT"
  mkdir -p "$T1_DIR"
  # Pin the dir to the controller's effective group to reproduce the
  # fresh-install path (no setgid inheritance of the actor group).
  chown ":$EFFECTIVE_GID" "$T1_DIR" 2>/dev/null || true
  T1_UUID="aaaa1111"
  T1_RESULT="$T1_DIR/$T1_UUID.result.json"
  AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" AGB_REPO_ROOT="$REPO_ROOT" \
  AGB_T1_RESULT="$T1_RESULT" AGB_T1_AGENT="$T1_AGENT" AGB_T1_UUID="$T1_UUID" \
    "$PY_BIN" - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))
import staging
from pathlib import Path
staging._write_result(
    Path(os.environ["AGB_T1_RESULT"]),
    os.environ["AGB_T1_UUID"],
    actor_agent=os.environ["AGB_T1_AGENT"],
    status="ok",
    cron_id="cron-abc",
    error=None,
    audit_action="cron_staging_applied",
)
PY
  [[ -f "$T1_RESULT" ]] || smoke_fail "T1: result file missing: $T1_RESULT"
  T1_GID="$(stat_gid "$T1_RESULT")"
  T1_MODE="$(stat_mode "$T1_RESULT")"
  smoke_assert_eq "$MEMBER_GID" "$T1_GID" "T1: result file must carry the canonical actor group (not controller-group)"
  smoke_assert_eq "660" "$T1_MODE" "T1: result file must be mode 0660"
  smoke_log "ok: T1 — result.json gid=$T1_GID ($MEMBER_GROUP_NAME) mode=$T1_MODE"

  # ---------------------------------------------------------------------------
  # T1t TEETH — no resolvable canonical group → result keeps the controller's
  #             default group (iso-read-denied repro). Proves T1's assertion
  #             bites: revert the result chgrp and the bug returns.
  # ---------------------------------------------------------------------------
  smoke_log "T1t (teeth): no resolvable canonical group → result keeps controller group (Errno 13 repro)"
  TEETH_AGENT="iso-teeth"
  TEETH_DIR="$STAGING_ROOT/$TEETH_AGENT"
  mkdir -p "$TEETH_DIR"
  chown ":$EFFECTIVE_GID" "$TEETH_DIR" 2>/dev/null || true
  TEETH_DIR_GID="$(stat_gid "$TEETH_DIR")"
  TEETH_RESULT="$TEETH_DIR/teeth1.result.json"
  # Empty hint + a prefix whose derived `<prefix>iso-teeth` does not exist →
  # no candidate resolves to a canonical group → no chgrp → result keeps the
  # inherited (controller-effective) group = the #1383 bug group.
  AGB_STAGE_FILE_GROUP="" BRIDGE_AGENT_GROUP_PREFIX="ab-agent-nonexistent-" \
  AGB_REPO_ROOT="$REPO_ROOT" \
  AGB_TEETH_RESULT="$TEETH_RESULT" AGB_TEETH_AGENT="$TEETH_AGENT" \
    "$PY_BIN" - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))
import staging
from pathlib import Path
staging._write_result(
    Path(os.environ["AGB_TEETH_RESULT"]),
    "teeth1",
    actor_agent=os.environ["AGB_TEETH_AGENT"],
    status="ok",
    cron_id="cron-teeth",
    error=None,
    audit_action="cron_staging_applied",
)
PY
  [[ -f "$TEETH_RESULT" ]] || smoke_fail "T1t: teeth result file missing"
  TEETH_GID="$(stat_gid "$TEETH_RESULT")"
  [[ "$TEETH_GID" != "$MEMBER_GID" ]] || smoke_fail "T1t: teeth gid ($TEETH_GID) must differ from the canonical-group gid ($MEMBER_GID)"
  smoke_assert_eq "$TEETH_DIR_GID" "$TEETH_GID" "T1t: teeth result must keep the un-corrected controller group (no chgrp)"
  smoke_log "ok: T1t — without the chgrp the result lands in gid=$TEETH_GID (≠ canonical $MEMBER_GID; iso-read-denied repro)"

  # ---------------------------------------------------------------------------
  # T1s SECURITY — a SHARED / non-canonical group must be REJECTED by the
  # resolver; only the canonical actor group is accepted. Also: the
  # controller's OWN egid is rejected (it IS the #1383 bug group).
  # Deterministic unit assertion on _resolve_result_gid.
  # ---------------------------------------------------------------------------
  smoke_log "T1s (security): non-canonical / controller group REJECTED; only canonical actor group accepted"
  T1S_DIR="$STAGING_ROOT/iso-shared-gate"
  mkdir -p "$T1S_DIR"
  # Footgun #11 (Bash 5.3.9 read_comsub deadlock): NEVER put a heredoc-stdin
  # inside a command substitution (`X="$(cmd <<PY ...)"`). Write the Python
  # body to a mktemp FILE via `cat > file <<'PY'` (heredoc-to-a-file is NOT
  # the C1 deadlock class) and capture by running python on the file path.
  T1S_PYF="$(mktemp -t agb-1383-t1s.XXXXXX)" || smoke_fail "T1s: mktemp failed"
  cat > "$T1S_PYF" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))
import staging
from pathlib import Path

d = Path(os.environ["AGB_T1S_DIR"])
member = os.environ["AGB_T1S_MEMBER"]
member_gid = int(os.environ["AGB_T1S_MEMBER_GID"])
egid = int(os.environ["AGB_T1S_EGID"])

# Canonical for a non-existent agent: every real member group offered is a
# NON-canonical name and must be rejected.
os.environ["BRIDGE_AGENT_GROUP_PREFIX"] = "ab-agent-"

# (a) forged AGB_STAGE_FILE_GROUP=<member group> (real, member, not primary)
#     but NOT the canonical actor group -> must be rejected.
os.environ["AGB_STAGE_FILE_GROUP"] = member
print("forge_member=" + ("None" if staging._resolve_result_gid("iso-no-such", d) is None else "ACCEPTED"))

# (b) the controller own egid must be rejected even if a name resolved -
#     it IS the #1383 bug group. Pin the dir to egid and resolve.
try:
    os.chown(d, -1, egid)
except OSError:
    pass
os.environ.pop("AGB_STAGE_FILE_GROUP", None)
print("controller_egid=" + ("None" if staging._resolve_result_gid("iso-no-such", d) is None else "ACCEPTED"))

# (c) the canonical actor group IS accepted: prefix empty so the canonical
#     name equals the real member group, then resolve via the derived path.
os.environ["BRIDGE_AGENT_GROUP_PREFIX"] = ""
print("canonical=" + ("None" if staging._resolve_result_gid(member, d) is None else str(staging._resolve_result_gid(member, d))))
PY
  T1S_OUT="$(
    AGB_T1S_DIR="$T1S_DIR" AGB_T1S_MEMBER="$MEMBER_GROUP_NAME" \
    AGB_T1S_MEMBER_GID="$MEMBER_GID" AGB_T1S_EGID="$EFFECTIVE_GID" \
    AGB_REPO_ROOT="$REPO_ROOT" \
    "$PY_BIN" "$T1S_PYF"
  )"
  rm -f "$T1S_PYF"
  T1S_FORGE_MEMBER="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^forge_member=//p')"
  T1S_CONTROLLER="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^controller_egid=//p')"
  T1S_CANON="$(printf '%s\n' "$T1S_OUT" | sed -n 's/^canonical=//p')"
  smoke_assert_eq "None" "$T1S_FORGE_MEMBER" "T1s: a real member group that is NOT the canonical actor group must be REJECTED"
  smoke_assert_eq "None" "$T1S_CONTROLLER" "T1s: the controller's own egid must be REJECTED (it is the #1383 bug group)"
  smoke_assert_eq "$MEMBER_GID" "$T1S_CANON" "T1s: the canonical actor group must be ACCEPTED"
  smoke_log "ok: T1s — actor-name gate rejects non-canonical/controller groups, accepts only the canonical actor group"

  # ---------------------------------------------------------------------------
  # T1f FAIL-LOUD-BUT-PUBLISH — when a canonical gid resolves but the chgrp
  # verify fails, _result_atomic_write must STILL publish the result file
  # (the poller is not stranded) AND emit a loud stderr warning. This is the
  # KEY contrast with the request leg (_payload_atomic_write), which REFUSES
  # to publish. We force the failure by monkeypatching os.chown to a no-op.
  # ---------------------------------------------------------------------------
  smoke_log "T1f (fail-loud-but-publish): chgrp verify fails → result STILL published + loud stderr warning"
  T1F_DIR="$STAGING_ROOT/iso-failloud"
  T1F_RESULT="$T1F_DIR/failloud1.result.json"
  # Footgun #11: same extract-to-file pattern as T1s — no heredoc-in-capture.
  T1F_PYF="$(mktemp -t agb-1383-t1f.XXXXXX)" || smoke_fail "T1f: mktemp failed"
  cat > "$T1F_PYF" <<'PY'
import io, contextlib, os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))
import staging
from pathlib import Path

d = Path(os.environ["AGB_T1F_DIR"])
d.mkdir(parents=True, exist_ok=True)
result = Path(os.environ["AGB_T1F_RESULT"])
member_gid = int(os.environ["AGB_T1F_MEMBER_GID"])
egid = int(os.environ["AGB_T1F_EGID"])
# Pin dir to the controller egid so the no-op chown leaves a gid mismatch.
try:
    os.chown(d, -1, egid)
except OSError:
    pass

# Monkeypatch os.chown to a no-op so the post-chown stat will NOT show the
# requested gid: _result_atomic_write must warn LOUD but STILL publish.
_orig = os.chown
os.chown = lambda *a, **k: None  # type: ignore[assignment]
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        staging._result_atomic_write(result, {"k": "v"}, 0o660, gid=member_gid)
finally:
    os.chown = _orig  # type: ignore[assignment]

print("published=" + ("1" if result.is_file() else "0"))
stderr_text = err.getvalue()
print("warned=" + ("1" if ("Issue #1383" in stderr_text and "write-result" in stderr_text) else "0"))
PY
  T1F_OUT="$(
    AGB_T1F_DIR="$T1F_DIR" AGB_T1F_RESULT="$T1F_RESULT" \
    AGB_T1F_MEMBER_GID="$MEMBER_GID" AGB_T1F_EGID="$EFFECTIVE_GID" \
    AGB_REPO_ROOT="$REPO_ROOT" \
    "$PY_BIN" "$T1F_PYF"
  )"
  rm -f "$T1F_PYF"
  T1F_PUBLISHED="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^published=//p')"
  T1F_WARNED="$(printf '%s\n' "$T1F_OUT" | sed -n 's/^warned=//p')"
  smoke_assert_eq "1" "$T1F_PUBLISHED" "T1f: the result MUST still be published on a chgrp-verify failure (no stranded poller)"
  smoke_assert_eq "1" "$T1F_WARNED" "T1f: a loud #1383 stderr warning MUST be emitted on a chgrp-verify failure"
  smoke_log "ok: T1f — fail-loud-but-publish: result written + loud warning (poison-retry avoided)"

  # ---------------------------------------------------------------------------
  # T2 — fresh-install path: per-agent dir pre-created 0700 no-setgid → the
  #      result STILL gets the canonical group via the explicit chgrp.
  # ---------------------------------------------------------------------------
  smoke_log "T2: fresh-install dir (0700 no-setgid) → explicit chgrp still lands canonical group on the result"
  T2_AGENT="$ISO_AGENT"
  T2_DIR="$STAGING_ROOT/$T2_AGENT"
  rm -rf "$T2_DIR" 2>/dev/null || true
  mkdir -p "$T2_DIR"
  chmod 0700 "$T2_DIR" 2>/dev/null || true
  chown ":$EFFECTIVE_GID" "$T2_DIR" 2>/dev/null || true
  T2_RESULT="$T2_DIR/bbbb2222.result.json"
  AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" AGB_REPO_ROOT="$REPO_ROOT" \
  AGB_T2_RESULT="$T2_RESULT" AGB_T2_AGENT="$T2_AGENT" \
    "$PY_BIN" - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["AGB_REPO_ROOT"], "lib", "cron-helpers"))
import staging
from pathlib import Path
staging._write_result(
    Path(os.environ["AGB_T2_RESULT"]),
    "bbbb2222",
    actor_agent=os.environ["AGB_T2_AGENT"],
    status="ok",
    cron_id="cron-fresh",
    error=None,
    audit_action="cron_staging_applied",
)
PY
  [[ -f "$T2_RESULT" ]] || smoke_fail "T2: result file missing"
  T2_GID="$(stat_gid "$T2_RESULT")"
  smoke_assert_eq "$MEMBER_GID" "$T2_GID" "T2: explicit chgrp must override the fresh-install controller dir group on the result"
  smoke_log "ok: T2 — fresh-install result self-grouped, gid=$T2_GID"

  # ---------------------------------------------------------------------------
  # T3 — end-to-end apply: a valid staged request applied by `apply` writes a
  #      result whose group is the canonical actor group, mode 0660.
  # ---------------------------------------------------------------------------
  smoke_log "T3: end-to-end apply → result.json carries canonical group + mode 0660"
  T3_AGENT="$ISO_AGENT"
  T3_DIR="$STAGING_ROOT/$T3_AGENT"
  rm -rf "$T3_DIR" 2>/dev/null || true
  mkdir -p "$T3_DIR"
  # agent-meta.env so the apply path resolves the iso UID to CURRENT_USER.
  META_DIR="$BRIDGE_STATE_DIR/agents/$T3_AGENT"
  mkdir -p "$META_DIR"
  cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
  printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$BRIDGE_NATIVE_CRON_JOBS_FILE"
  T3_PAYLOAD="$(make_payload "$T3_AGENT" "$T3_AGENT" "$CURRENT_UID")"
  T3_UUID="$(AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py write-request "$STAGING_ROOT" "$T3_AGENT" "$T3_PAYLOAD")"
  T3_UUID="${T3_UUID%%$'\n'*}"
  [[ -n "$T3_UUID" ]] || smoke_fail "T3: write-request returned empty uuid"
  AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py apply "$STAGING_ROOT" "$T3_AGENT" "$T3_UUID" "$BRIDGE_NATIVE_CRON_JOBS_FILE" >/dev/null 2>&1 || true
  T3_RESULT="$T3_DIR/$T3_UUID.result.json"
  [[ -f "$T3_RESULT" ]] || smoke_fail "T3: apply did not write a result file"
  T3_GID="$(stat_gid "$T3_RESULT")"
  T3_MODE="$(stat_mode "$T3_RESULT")"
  T3_AUDIT="$(result_field "$T3_RESULT" audit_action)"
  smoke_assert_eq "$MEMBER_GID" "$T3_GID" "T3: end-to-end apply result must carry the canonical actor group"
  smoke_assert_eq "660" "$T3_MODE" "T3: end-to-end apply result must be mode 0660"
  smoke_assert_eq "cron_staging_applied" "$T3_AUDIT" "T3: end-to-end apply must succeed (audit_action=cron_staging_applied)"
  smoke_log "ok: T3 — end-to-end apply result gid=$T3_GID mode=$T3_MODE audit=$T3_AUDIT"

  # ---------------------------------------------------------------------------
  # T4 — #1379 request-path UNCHANGED: write-request still lands the REQUEST
  #      file in the canonical group 0660 (no regression of Track O).
  # ---------------------------------------------------------------------------
  smoke_log "T4: #1379 request-path intact — request file still canonical group 0660"
  T4_AGENT="$ISO_AGENT"
  T4_DIR="$STAGING_ROOT/$T4_AGENT"
  rm -rf "$T4_DIR" 2>/dev/null || true
  T4_PAYLOAD="$(make_payload "$T4_AGENT" "$T4_AGENT" "$CURRENT_UID")"
  T4_UUID="$(AGB_STAGE_FILE_GROUP="$MEMBER_GROUP_NAME" \
    staging_py write-request "$STAGING_ROOT" "$T4_AGENT" "$T4_PAYLOAD")"
  T4_UUID="${T4_UUID%%$'\n'*}"
  T4_PATH="$T4_DIR/$T4_UUID.json"
  [[ -f "$T4_PATH" ]] || smoke_fail "T4: request file missing (Track O regression)"
  T4_GID="$(stat_gid "$T4_PATH")"
  T4_MODE="$(stat_mode "$T4_PATH")"
  smoke_assert_eq "$MEMBER_GID" "$T4_GID" "T4: #1379 request file must still carry the canonical actor group"
  smoke_assert_eq "660" "$T4_MODE" "T4: #1379 request file must still be mode 0660"
  smoke_log "ok: T4 — #1379 request-write path unchanged (gid=$T4_GID mode=$T4_MODE)"

  unset BRIDGE_AGENT_GROUP_PREFIX
fi

smoke_log "all 1383-iso-cron-result-json-group cases passed"
