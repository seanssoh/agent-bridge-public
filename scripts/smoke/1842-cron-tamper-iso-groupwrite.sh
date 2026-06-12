#!/usr/bin/env bash
# scripts/smoke/1842-cron-tamper-iso-groupwrite.sh — Issue #1842 (CRITICAL,
# 7-day production email-intake outage): the cron runner's run-dir tamper-check
# (`request_artifact_tampered: group/other writable mode`) false-positives on
# iso v2 agent run dirs, blocking EVERY cron owned by an iso v2 agent.
#
# Root cause: a TEXT cron run dir for an iso v2 agent is group-widened to 2770
# group=ab-agent-<agent> by `bridge_cron_run_dir_grant_isolation` (the normal
# setgid iso contract so the controller can read sidecars the iso UID writes).
# `shell_artifact_route` (the classifier at the top of `cmd_run`) treated ANY
# group-write bit as tamper BEFORE reading the body → the legitimate iso run
# dir was rejected and the cron never ran (devmail-poll-drain: 0 intake for 7
# days, 1898 consecutive `request_artifact_tampered` errors).
#
# Fix (option A — NARROW, security-preserving): permit the group-write bit ONLY
# when the dir's group is EXACTLY the owning iso agent's own group
# `ab-agent-<agent>` AND the dir carries the STICKY bit (3770); keep rejecting
# other-write (always), group-write with a wrong/unexpected group, a non-sticky
# group-writable dir, and a non-iso agent's group-writable dir. The run dir must
# still be controller-OWNED (the owner-uid trust anchor is unchanged).
#
# TOCTOU close (#1842 codex r2): request.json is pinned ONCE through an
# `O_NOFOLLOW` fd; the fstat owner-uid + 0600-mode check binds to that inode and
# every downstream body read consumes the pinned bytes — never a path re-open.
# A group member that renames/unlinks request.json after the pin cannot retarget
# the run (the fd holds the original inode), and the 3770 sticky bit blocks that
# rename/unlink in the first place. The exemption is gated on the sticky bit so
# it never widens to a non-sticky group-writable dir.
#
# The required tamper cases:
#   ALLOW  iso-group-write : 3770 dir (setgid+sticky), group=ab-agent-<agent>,
#                            owner=controller, no other-write → "text" (PASS).
#   DENY   other-write     : same dir + other-write bit → still tamper.
#   DENY   wrong-group     : 3770 dir, group != ab-agent-<agent> → still tamper.
#   DENY   non-iso         : 3770 dir, blank/unknown owning agent (non-iso cron)
#                            → strict no-group-write → still tamper.
#   DENY   no-sticky       : 2770 dir, correct iso group → exemption withheld.
#   DENY   request-swap    : swap request.json after the pin → runner reads the
#                            ORIGINAL inode (window CLOSED, not narrowed).
#
# Test strategy (Linux-host caveat, mirrors 1383): smokes run as the operator's
# UID (not root, no real `ab-agent-<a>` groups). The PREDICATE-LOGIC cases
# (P1..P7) are asserted deterministically on ALL platforms by driving the
# runner's `mode_has_disallowed_write` / `group_write_is_expected_iso_group` /
# `shell_artifact_route` functions with a stubbed group-name resolver. The
# REAL-CHGRP end-to-end case (E1) is gated on the current user having a real
# non-primary supplementary group to stand in for `ab-agent-<agent>` (then
# `BRIDGE_AGENT_GROUP_PREFIX=""` + agent=<that group name> makes the canonical
# name equal the real member group, so the chgrp succeeds unprivileged and the
# REAL `shell_artifact_route` runs end-to-end). patch re-verifies the real
# root-daemon + `ab-agent-<a>` mapping on a Linux iso host (the real gate).

set -euo pipefail

SMOKE_NAME="1842-cron-tamper-iso-groupwrite"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
  [[ -n "${PRED_PYF:-}" && -f "${PRED_PYF:-}" ]] && rm -f "$PRED_PYF"
  [[ -n "${E1_PYF:-}" && -f "${E1_PYF:-}" ]] && rm -f "$E1_PYF"
  [[ -n "${E2_PYF:-}" && -f "${E2_PYF:-}" ]] && rm -f "$E2_PYF"
  return 0
}
trap cleanup EXIT

smoke_setup_bridge_home

# ---------------------------------------------------------------------------
# P1..P7 — deterministic predicate logic (ALL platforms). Stub the runner's
# group-name resolver so the 4 tamper cases + edges are asserted without real
# `ab-agent-<a>` groups. Footgun #11: heredoc body written to a FILE, then run
# python on the file path (never a heredoc-in-command-substitution).
# ---------------------------------------------------------------------------
smoke_log "P: predicate logic — mode_has_disallowed_write / group_write_is_expected_iso_group / shell_artifact_route"
PRED_PYF="$(mktemp -t agb-1842-pred.XXXXXX)" || smoke_fail "P: mktemp failed"
cat > "$PRED_PYF" <<'PY'
import importlib.util
import os
import stat
import sys
import tempfile

repo = os.environ["AGB_REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "ccr", os.path.join(repo, "bridge-cron-runner.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []


def check(name, cond):
    if cond:
        print("PASS:", name)
    else:
        print("FAIL:", name)
        failures.append(name)


# Deterministic group-name resolver stub (macOS has no real ab-agent-* groups).
def stub_group_name(path):
    return stub_group_name.value


stub_group_name.value = None
m._path_group_name = stub_group_name

AGENT = "devmail"
exp = m._expected_iso_group_names(AGENT)
ISO_GROUP = m.os.environ.get("BRIDGE_AGENT_GROUP_PREFIX", "ab-agent-") + AGENT
check("expected-set-contains-canonical", ISO_GROUP in exp)

d = tempfile.mkdtemp()
p = m.Path(d)


def setmode(bits):
    os.chmod(d, bits)


# P1 ALLOW — iso group-write: 3770 dir (setgid+STICKY), group=ab-agent-devmail,
# no other-write. The sticky bit is now REQUIRED for the exemption (#1842 r2).
setmode(0o3770)
stub_group_name.value = ISO_GROUP
check(
    "P1-iso-group-write-sticky-ALLOW-predicate",
    m.mode_has_sticky_bit(p) is True
    and m.group_write_is_expected_iso_group(p, AGENT) is True
    and m.mode_has_disallowed_write(p, AGENT) is False,
)

# P2 DENY — other-write: even with the correct iso group + sticky, other-write
# is tamper.
setmode(0o3776)
stub_group_name.value = ISO_GROUP
check(
    "P2-other-write-DENY-predicate",
    m.mode_has_other_write(p) is True
    and m.group_write_is_expected_iso_group(p, AGENT) is False
    and m.mode_has_disallowed_write(p, AGENT) is True,
)

# P3 DENY — wrong group: sticky group-writable but group is a SHARED/non-iso group.
setmode(0o3770)
stub_group_name.value = "ab-shared"
check(
    "P3-wrong-group-shared-DENY-predicate",
    m.group_write_is_expected_iso_group(p, AGENT) is False
    and m.mode_has_disallowed_write(p, AGENT) is True,
)

# P3b DENY — wrong group: a DIFFERENT iso agent's group must not pass for AGENT.
setmode(0o3770)
stub_group_name.value = "ab-agent-attacker"
check(
    "P3b-wrong-iso-agent-group-DENY-predicate",
    m.mode_has_disallowed_write(p, AGENT) is True,
)

# P4 DENY — non-iso (blank owning agent): no iso group → strict no-group-write.
setmode(0o3770)
stub_group_name.value = ISO_GROUP  # even if a name resolves, blank agent rejects
check(
    "P4-non-iso-blank-agent-group-write-DENY-predicate",
    m._expected_iso_group_names("") == set()
    and m.group_write_is_expected_iso_group(p, "") is False
    and m.mode_has_disallowed_write(p, "") is True,
)

# P5 ALLOW — non-iso private (0700) still passes (legacy behaviour unchanged).
setmode(0o700)
check(
    "P5-non-iso-private-0700-ALLOW-predicate",
    m.mode_has_disallowed_write(p, "") is False,
)

# P6 DENY — group-name unresolvable (grp lookup fails) → fail-closed tamper.
setmode(0o3770)
stub_group_name.value = None
check(
    "P6-unresolvable-group-DENY-predicate",
    m.group_write_is_expected_iso_group(p, AGENT) is False
    and m.mode_has_disallowed_write(p, AGENT) is True,
)

# P6b DENY (#1842 codex r2) — group-writable iso group but NO sticky bit (2770).
# Without the sticky bit a group member can rename/unlink request.json, so the
# exemption MUST NOT apply: the dir stays tamper even though the group matches.
setmode(0o2770)
stub_group_name.value = ISO_GROUP
check(
    "P6b-iso-group-write-NO-sticky-DENY-predicate",
    m.mode_has_sticky_bit(p) is False
    and m.group_write_is_expected_iso_group(p, AGENT) is False
    and m.mode_has_disallowed_write(p, AGENT) is True,
)

# P7 — hash-truncated long agent name parity with bridge_isolation_v2_agent_group_name.
longname = "a" * 40
expl = m._expected_iso_group_names(longname)
check(
    "P7-long-name-hash-trunc-32cap",
    any(len(n) <= 32 for n in expl) and len(expl) == 2,
)

os.chmod(d, 0o700)
import shutil

shutil.rmtree(d, ignore_errors=True)

if failures:
    print("PREDICATE-FAILURES:", ",".join(failures))
    sys.exit(1)
print("ALL-PREDICATE-CASES-PASS")
PY

PRED_OUT="$(AGB_REPO_ROOT="$REPO_ROOT" "$PY_BIN" "$PRED_PYF" 2>&1)" || {
  printf '%s\n' "$PRED_OUT"
  smoke_fail "P: predicate-logic cases failed"
}
printf '%s\n' "$PRED_OUT" | sed 's/^/  /'
smoke_assert_contains "$PRED_OUT" "ALL-PREDICATE-CASES-PASS" "P: predicate logic"
smoke_log "ok: P — all 4 tamper cases (+ edges) asserted at the predicate layer"

# ---------------------------------------------------------------------------
# E1 — REAL end-to-end: drive the ACTUAL `shell_artifact_route` against a REAL
# group-writable, controller-owned run dir + request.json, with a REAL member
# group standing in for ab-agent-<agent>. Gated on a usable member group.
# ---------------------------------------------------------------------------
EFFECTIVE_GID="$(id -g)"
MEMBER_GID=""
for g in $(id -G); do
  [[ "$g" == "$EFFECTIVE_GID" ]] && continue
  MEMBER_GID="$g"
  break
done

if [[ -z "$MEMBER_GID" ]]; then
  smoke_skip "E1" "current user has no non-primary supplementary group to stand in for ab-agent-<agent> (predicate cases P1..P7 already cover the logic)"
else
  MEMBER_GROUP_NAME="$("$PY_BIN" -c "import grp,sys;print(grp.getgrgid(int(sys.argv[1])).gr_name)" "$MEMBER_GID" 2>/dev/null || true)"
  [[ -n "$MEMBER_GROUP_NAME" ]] || smoke_fail "E1: could not resolve a name for gid $MEMBER_GID"

  smoke_log "E1: real shell_artifact_route over a real group-writable run dir (iso-group stand-in=$MEMBER_GROUP_NAME)"
  E1_PYF="$(mktemp -t agb-1842-e1.XXXXXX)" || smoke_fail "E1: mktemp failed"
  cat > "$E1_PYF" <<'PY'
import importlib.util
import json
import os
import sys
import tempfile

repo = os.environ["AGB_REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "ccr", os.path.join(repo, "bridge-cron-runner.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

member_group = os.environ["AGB_E1_MEMBER_GROUP"]
member_gid = int(os.environ["AGB_E1_MEMBER_GID"])
# Make the member group the agent's CANONICAL iso group: prefix="" +
# agent=<member group name> → _expected_iso_group_names(agent) == {member_group}.
os.environ["BRIDGE_AGENT_GROUP_PREFIX"] = ""
AGENT = member_group

failures = []


def check(name, cond):
    if cond:
        print("PASS:", name)
    else:
        print("FAIL:", name)
        failures.append(name)


def route_pinned(req):
    """Mirror cmd_run's pin-then-route: pin the request.json ONCE through the
    O_NOFOLLOW fd, then classify with the pinned bytes. Returns
    (route, err, pinned). A pin failure surfaces as ('tampered', reason, None),
    exactly as cmd_run treats it."""
    try:
        pinned = m.pin_request_file(req)
    except m.RequestArtifactTampered as exc:
        return "tampered", exc.reason, None
    route, err = m.shell_artifact_route(req, pinned)
    return route, err, pinned


def make_run_dir(group_writable_gid, *, target=None):
    """Controller-owned run dir + request.json. dir 3770 (setgid+STICKY)
    group=<gid> when group_writable_gid is not None; request.json stays 0600
    (controller-private, as in the real text-cron flow). Returns the
    request_file Path."""
    rd = tempfile.mkdtemp()
    d = m.Path(rd)
    req = d / "request.json"
    body_agent = AGENT if target is None else target
    req.write_text(json.dumps({"target_agent": body_agent, "target_engine": "claude"}))
    os.chmod(req, 0o600)
    if group_writable_gid is not None:
        os.chown(rd, -1, group_writable_gid)
        os.chmod(rd, 0o3770)  # setgid + STICKY (#1842 r2: sticky now required)
    else:
        os.chmod(rd, 0o700)
    return req


# E1a ALLOW — iso group-write (3770 sticky) dir routes to "text" (NOT tampered).
req = make_run_dir(member_gid)
route, err, _ = route_pinned(req)
check("E1a-iso-group-write-sticky-routes-text", route == "text" and err is None)

# E1b DENY — other-write bit on the same dir → tampered.
req = make_run_dir(member_gid)
os.chmod(req.parent, 0o3772)  # add other-write (keep sticky)
route, err, _ = route_pinned(req)
check(
    "E1b-other-write-tampered",
    route == "tampered" and err is not None and "writable" in err,
)

# E1c DENY — wrong group (controller's own primary group, NOT the iso group).
req = make_run_dir(int(os.getegid()))
os.chmod(req.parent, 0o3770)
route, err, _ = route_pinned(req)
check(
    "E1c-wrong-group-tampered",
    route == "tampered" and err is not None and "writable" in err,
)

# E1d DENY — non-iso: blank owning agent in body → strict no-group-write.
req = make_run_dir(member_gid, target="")
route, err, _ = route_pinned(req)
check(
    "E1d-non-iso-blank-agent-tampered",
    route == "tampered" and err is not None and "writable" in err,
)

# E1e ALLOW — private 0700/0600 still routes to "shell" (non-iso unchanged).
rd = tempfile.mkdtemp()
d = m.Path(rd)
req = d / "request.json"
req.write_text(json.dumps({"target_agent": "", "target_engine": "claude"}))
os.chmod(req, 0o600)
os.chmod(rd, 0o700)
route, err, _ = route_pinned(req)
check("E1e-private-routes-shell", route == "shell" and err is None)

# E1f DENY (codex r1 [P1]) — the iso-group exemption is for the run DIR ONLY.
# A group-writable request.json (even with the correct iso group) is tamper:
# request.json is never group-widened by bridge_cron_run_dir_grant_isolation,
# and cmd_run consumes it for paths/routing, so it stays strictly private. The
# fd-fstat mode check in pin_request_file now catches this at the pin.
rd = tempfile.mkdtemp()
d = m.Path(rd)
req = d / "request.json"
req.write_text(json.dumps({"target_agent": AGENT, "target_engine": "claude"}))
os.chown(rd, -1, member_gid)
os.chmod(rd, 0o3770)          # run dir legitimately group-writable (iso group)
os.chown(req, -1, member_gid)
os.chmod(req, 0o660)          # request.json group-writable with the SAME iso group
route, err, _ = route_pinned(req)
check(
    "E1f-group-writable-request-json-tampered",
    route == "tampered" and err is not None and "writable" in err,
)

# E1g DENY (#1842 codex r2 SWAP TEETH) — prove the TOCTOU window is CLOSED, not
# just narrowed. Pin the original controller-owned request.json, then AFTER the
# pin + route check simulate the iso UID swapping in its OWN request.json
# carrying a DIFFERENT target_agent (the cross-agent cron-injection an attacker
# would attempt in the group-writable dir). The runner must act on the ORIGINAL
# inode the fd holds — never the swapped file. We assert:
#   (1) the post-pin body the runner consumes == the ORIGINAL target_agent, and
#   (2) a pre-pin swap to an AGENT-OWNED request.json is caught at the pin
#       (wrong uid) → tampered.
req = make_run_dir(member_gid)            # original: target_agent == AGENT
route, err, pinned = route_pinned(req)
assert route == "text" and pinned is not None, (route, err)
# Attacker swaps in a DIFFERENT-target request.json AFTER the pin/route check
# (rename is what a group member could do in a non-sticky dir; here we just
# overwrite the path to model the worst case of a successful swap).
swapped = req.parent / "evil.json"
swapped.write_text(json.dumps({"target_agent": "victim-other-agent", "target_engine": "claude"}))
os.chmod(swapped, 0o600)
os.replace(swapped, req)                  # path now points at the attacker body
# The runner consumes pinned.json() (the fd holds the ORIGINAL inode); the body
# it routes on must still be the ORIGINAL target, NOT the swapped one.
consumed = pinned.json()
check(
    "E1g-swap-after-pin-reads-ORIGINAL-inode",
    isinstance(consumed, dict)
    and consumed.get("target_agent") == AGENT
    and consumed.get("target_agent") != "victim-other-agent",
)

# E1g2 DENY — a PRE-pin swap to an AGENT-OWNED request.json is caught by the
# fd-fstat owner-uid check (a swapped agent-owned file has the wrong uid).
rd = tempfile.mkdtemp()
d = m.Path(rd)
os.chown(rd, -1, member_gid)
os.chmod(rd, 0o3770)
req = d / "request.json"
# Simulate the swapped-in file being group-owned + group-writable (agent-shaped,
# not controller-private). pin_request_file must reject it on the mode bits even
# though the uid happens to match in this unprivileged smoke (real attacker file
# is also wrong-uid; both the uid and mode gates are exercised — mode here).
req.write_text(json.dumps({"target_agent": "victim-other-agent", "target_engine": "claude"}))
os.chown(req, -1, member_gid)
os.chmod(req, 0o660)                       # NOT controller-private 0600
route, err, pinned = route_pinned(req)
check(
    "E1g2-pre-pin-noncontroller-request-json-tampered",
    route == "tampered" and pinned is None and err is not None and "writable" in err,
)

# E1h DENY (#1842 codex r2) — iso group-write dir WITHOUT the sticky bit (2770).
# A non-sticky group-writable dir lets a member rename/unlink request.json, so
# the exemption MUST NOT apply even with the correct iso group + controller
# owner: the dir stays tamper.
req = make_run_dir(member_gid)
os.chmod(req.parent, 0o2770)               # strip the sticky bit
route, err, _ = route_pinned(req)
check(
    "E1h-iso-group-write-NO-sticky-tampered",
    route == "tampered" and err is not None and "writable" in err,
)

if failures:
    print("E1-FAILURES:", ",".join(failures))
    sys.exit(1)
print("ALL-E1-CASES-PASS")
PY

  E1_OUT="$(
    AGB_REPO_ROOT="$REPO_ROOT" \
    AGB_E1_MEMBER_GROUP="$MEMBER_GROUP_NAME" \
    AGB_E1_MEMBER_GID="$MEMBER_GID" \
      "$PY_BIN" "$E1_PYF" 2>&1
  )" || {
    printf '%s\n' "$E1_OUT"
    smoke_fail "E1: real shell_artifact_route cases failed"
  }
  printf '%s\n' "$E1_OUT" | sed 's/^/  /'
  smoke_assert_contains "$E1_OUT" "ALL-E1-CASES-PASS" "E1: real route"
  smoke_log "ok: E1 — real shell_artifact_route ALLOWs iso-group-write, DENYs other-write / wrong-group / non-iso"
fi

# ---------------------------------------------------------------------------
# E2 — REGRESSION (#1842 codex r2 [P1]): the task-id rewrite must NOT leave
# request.json group-writable on an ACL host. `bridge_cron_run_dir_grant_isolation`
# installs a `default:group::rw-` ACL on the 3770 run dir, so the temp file the
# rewrite helper creates IN that dir inherits a group-writable owning-group mode;
# `update-request-task-id.py` now re-chmods request.json back to 0600 after the
# os.replace. Without that, the runner's pin/route gate would misclassify every
# iso text cron as tampered after the rewrite. Gated on setfacl (Linux).
# ---------------------------------------------------------------------------
if ! command -v setfacl >/dev/null 2>&1; then
  smoke_skip "E2" "setfacl unavailable (macOS); the default-ACL rewrite path is Linux-only — patch re-verifies on a real iso host"
else
  smoke_log "E2: task-id rewrite preserves 0600 request.json under a default group ACL (3770 dir)"
  E2_PYF="$(mktemp -t agb-1842-e2.XXXXXX)" || smoke_fail "E2: mktemp failed"
  cat > "$E2_PYF" <<'PY'
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile

repo = os.environ["AGB_REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "ccr", os.path.join(repo, "bridge-cron-runner.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []


def check(name, cond):
    if cond:
        print("PASS:", name)
    else:
        print("FAIL:", name)
        failures.append(name)


# Build a controller-owned run dir mirroring the real iso text-cron dispatch:
# 3770 (setgid+sticky) + the default:group::rw- ACL that
# bridge_cron_run_dir_grant_isolation installs, request.json 0600.
rd = tempfile.mkdtemp()
os.chmod(rd, 0o3770)
try:
    acl_ok = subprocess.run(
        ["setfacl", "-m", "default:group::rw-,default:mask::rw-", rd],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
except FileNotFoundError:
    acl_ok = False
if not acl_ok:
    print("E2-SKIP-setfacl-failed")
    sys.exit(0)

req = os.path.join(rd, "request.json")
with open(req, "w", encoding="utf-8") as fh:
    json.dump({"target_agent": "devmail", "target_engine": "claude"}, fh)
os.chmod(req, 0o600)

# Sanity: confirm the default ACL really would taint a fresh temp file's mode
# (so this test would FAIL pre-fix). Create a temp file in the dir and read it.
probe = os.path.join(rd, "acl-probe.tmp")
with open(probe, "w", encoding="utf-8") as fh:
    fh.write("{}")
probe_groupwrite = bool(os.stat(probe).st_mode & stat.S_IWGRP)
os.unlink(probe)
check("E2-precondition-default-acl-taints-new-file", probe_groupwrite is True)

# Run the REAL rewrite helper (the dispatch path that sets dispatch_task_id).
rc = subprocess.run(
    [sys.executable, os.path.join(repo, "lib/cron-helpers/update-request-task-id.py"), req, "4242"],
    check=False,
).returncode
check("E2-rewrite-helper-exit-0", rc == 0)

final_mode = stat.S_IMODE(os.stat(req).st_mode)
check(
    "E2-request-json-restored-0600-after-rewrite",
    final_mode == 0o600
    and not (os.stat(req).st_mode & (stat.S_IWGRP | stat.S_IWOTH)),
)

# The task id must actually be in the rewritten body (helper did its real job).
with open(req, "r", encoding="utf-8") as fh:
    body = json.load(fh)
check("E2-rewrite-applied-task-id", body.get("dispatch_task_id") == 4242)

# And the runner's pin/route gate must now ALLOW it: the request file pins clean
# (0600), the 3770 dir routes text (group-writable but sticky + controller-owned;
# the default ACL on the dir is the legacy text-cron grant, not terminal unless a
# shell payload is declared).
try:
    pinned = m.pin_request_file(m.Path(req))
    pin_ok = True
except m.RequestArtifactTampered:
    pin_ok = False
check("E2-pin-after-rewrite-ok", pin_ok is True)

if failures:
    print("E2-FAILURES:", ",".join(failures))
    sys.exit(1)
print("ALL-E2-CASES-PASS")
PY

  E2_OUT="$(AGB_REPO_ROOT="$REPO_ROOT" "$PY_BIN" "$E2_PYF" 2>&1)" || {
    printf '%s\n' "$E2_OUT"
    smoke_fail "E2: task-id rewrite 0600-preservation failed"
  }
  printf '%s\n' "$E2_OUT" | sed 's/^/  /'
  if printf '%s\n' "$E2_OUT" | grep -q "E2-SKIP-setfacl-failed"; then
    smoke_skip "E2" "setfacl present but the default-ACL set failed on this filesystem (no ACL support)"
  else
    smoke_assert_contains "$E2_OUT" "ALL-E2-CASES-PASS" "E2: rewrite 0600 preservation"
    smoke_log "ok: E2 — task-id rewrite restores 0600 under default group ACL; pin/route still ALLOWs"
  fi
fi

smoke_log "all 1842-cron-tamper-iso-groupwrite cases passed"
