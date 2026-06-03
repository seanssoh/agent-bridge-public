#!/usr/bin/env bash
# Issue #1506 regression smoke — `isolate` (create→isolate) must
# normalize the pre-existing profile tree to the iso v2 contract.
#
# Bug: `bridge_linux_prepare_agent_isolation`
# (lib/bridge-agents.sh) transferred OWNER only (`chown -R "$os_user"`)
# on the create-shared-then-isolate path. The pre-existing scaffolded
# files under `home/` and `$workdir/` kept their controller-time
# `group=<controller>` `mode 0600/0700` — only files created AFTER
# isolation inherited `ab-agent-<a>` via the setgid parent. Result:
# `-rw------- agent-bridge-<a> <controller> CLAUDE.md` instead of the
# contract `-rw-rw---- agent-bridge-<a> ab-agent-<a>` (0660). The
# controller (incl. bridge-watchdog) — even as a group member — cannot
# read a `0600 group=<controller>` file, so the next scan emits a
# high-pri `scan_error` profile-drift false-positive.
#
# Fix: right after the `chown -R "$os_user"` passes, normalize the
# existing read-write content subtrees (home/workdir/runtime/logs) to
# the contract via the shared exec-bit-preserving / symlink-safe
# recursive helper `bridge_isolation_v2_chgrp_setgid_recursive`
# (2770 dirs / 0660 files), with the v3 channel state dirs excluded.
#
# This smoke verifies BOTH:
#   (A) Integration — `bridge_linux_prepare_agent_isolation` contains
#       the #1506 normalization call against home/workdir/runtime/logs,
#       reuses the shared helper (NOT a naive blanket `chmod 0660 -R`),
#       and excludes the v3 channel state dirs on the workdir pass.
#   (B) Behavior — driving the SAME helper with the SAME arguments the
#       fix uses, against a seeded `0600 group=<controller>` create→
#       isolate tree, converges it to the contract; is idempotent on a
#       second run; preserves exec bits; honors the channel-state
#       excludes; and is a clean no-op when v2 enforcement is off
#       (macOS / shared mode).
#
# Behavioral runs use the rootless primary-group seam (the helper is
# direct-first): `BRIDGE_ISOLATION_REQUIRED=yes` forces enforcement on
# a macOS dev host, and `$(id -gn)` is a group the caller can chgrp to
# without sudo — so the contract (group + 2770/0660 + exec-bit) is
# checked deterministically on macOS and Linux alike. The true OS-user
# + `ab-agent-<a>` group path needs a Linux host with sudo and is
# covered by the manual Linux repro in the PR body.
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): all driver bodies
# are emitted via printf-to-file — no heredoc-stdin, no here-strings,
# no process substitution.

set -uo pipefail

SMOKE_NAME="1506-isolate-normalize"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"

# shellcheck disable=SC2329 # invoked via `trap cleanup EXIT`
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

[[ -f "$AGENTS_LIB" ]] || smoke_fail "missing $AGENTS_LIB"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Portable LOW-bits mode helper: GNU `stat -c '%a'`, BSD `stat -f '%Lp'`.
# NOTE: BSD `%Lp` reports only the permission bits and DROPS the setgid
# bit on macOS, so for directories assert the setgid bit separately via
# _has_setgid (ls-based) rather than expecting `_mode_of` to return 2770.
_mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Portable setgid-bit probe. GNU `stat -c '%a'` returns a 4-digit mode
# with the leading 2 (e.g. 2770) when setgid is set; BSD does not, so
# fall back to parsing the `ls -ld` group-exec slot (`s`/`S` at the
# 6th permission character). Returns 0 when setgid is set.
_has_setgid() {
  local p="$1" gnu_mode perms
  gnu_mode="$(stat -c '%a' "$p" 2>/dev/null || printf '')"
  if [[ -n "$gnu_mode" ]]; then
    case "$gnu_mode" in
      2*|3*|6*|7*) return 0 ;;   # leading 2/3/6/7 → setgid bit present
      *) return 1 ;;
    esac
  fi
  # BSD path: inspect the symbolic perms from `ls -ld`. (A single known
  # path, not a glob expansion — SC2012's find-vs-ls concern doesn't apply.)
  # shellcheck disable=SC2012
  perms="$(ls -ld "$p" 2>/dev/null | awk '{print $1}')"
  case "${perms:6:1}" in
    s|S) return 0 ;;
    *) return 1 ;;
  esac
}

# =====================================================================
# (A) Integration assertions — the fix lives in prepare_agent_isolation
#     and reuses the shared helper (NOT a naive blanket chmod).
# =====================================================================

smoke_log "A: bridge_linux_prepare_agent_isolation carries the #1506 normalization (shared helper, no naive blanket chmod)"

PREP_START="$(grep -nE '^bridge_linux_prepare_agent_isolation\(\)' "$AGENTS_LIB" | head -1 | cut -d: -f1)"
[[ -n "$PREP_START" ]] || smoke_fail "A: cannot locate bridge_linux_prepare_agent_isolation in $AGENTS_LIB"

PREP_BODY="$(awk -v start="$PREP_START" '
  NR < start { next }
  NR == start { in_fn = 1; print; next }
  in_fn { print; if ($0 == "}") { exit } }
' "$AGENTS_LIB")"
[[ -n "$PREP_BODY" ]] || smoke_fail "A: extracted prepare_agent_isolation body is empty"

# Whitespace-flattened copy: the normalization helper call spans several
# lines via `\` continuations, so single-line greps for "helper ... 2770
# 0660" must run against a newline-collapsed view of the body.
PREP_BODY_FLAT="$(printf '%s\n' "$PREP_BODY" | tr '\n' ' ' | tr -s ' ')"

A_FAILS=""

# A1: the #1506 block references the issue (anchor for future readers +
# greppability) and loops over home/workdir/runtime/logs.
if ! printf '%s\n' "$PREP_BODY" | grep -F '#1506' >/dev/null; then
  A_FAILS+="no #1506 anchor in prepare_agent_isolation; "
fi

# A2: it calls the shared exec-bit-preserving / symlink-safe recursive
# normalizer with the 2770/0660 contract (call spans line continuations,
# so match against the flattened body).
if ! printf '%s\n' "$PREP_BODY_FLAT" \
    | grep -E 'bridge_isolation_v2_chgrp_setgid_recursive[[:space:]]+.*2770[[:space:]]+0660' >/dev/null; then
  A_FAILS+="does not call bridge_isolation_v2_chgrp_setgid_recursive with 2770 0660; "
fi

# A3: it normalizes the home subtree (the #1238 scaffold tree that holds
# CLAUDE.md / SOUL.md / MEMORY*.md) and the workdir.
if ! printf '%s\n' "$PREP_BODY" | grep -F '$_v2_agent_root/home' >/dev/null; then
  A_FAILS+="normalization loop does not include the home subtree; "
fi
if ! printf '%s\n' "$PREP_BODY" | grep -F '"$workdir"' >/dev/null; then
  A_FAILS+="normalization loop does not include the workdir subtree; "
fi

# A4: workdir pass excludes the v3 channel state dirs so their
# 0600/iso-UID dotenv files are not clobbered.
for _excl in .teams .ms365 .discord .telegram .mattermost; do
  if ! printf '%s\n' "$PREP_BODY" | grep -F -- "--exclude-subdir $_excl" >/dev/null; then
    A_FAILS+="workdir normalization missing --exclude-subdir $_excl; "
  fi
done

# A5: NO naive blanket recursive chmod 0660 / chmod -R 0660 was
# introduced (that would strip exec bits — the exact anti-pattern the
# helper avoids; see lib/bridge-isolation-v2.sh:~1521).
if printf '%s\n' "$PREP_BODY" | grep -vE '^[[:space:]]*#' \
    | grep -E 'chmod[[:space:]]+(-R[[:space:]]+)?0?660[[:space:]].*find|find.*chmod[[:space:]]+0?660|chmod[[:space:]]+-R[[:space:]]+0?660' >/dev/null; then
  A_FAILS+="introduced a naive blanket/recursive chmod 0660 (kills exec bits); "
fi

if [[ -n "$A_FAILS" ]]; then
  smoke_fail "A: integration regressions: $A_FAILS"
fi
smoke_log "A PASS — #1506 normalization present, reuses shared helper (2770/0660), excludes channel dirs, no naive blanket chmod"

# =====================================================================
# (B) Behavioral — drive the SAME helper with the SAME args the fix
#     uses against a seeded create→isolate tree.
# =====================================================================

# Seed a tree mimicking the create-shared-then-isolate gap: scaffolded
# profile files owned <controller> at mode 0600/0700 (umask 077), a
# channel state dir whose dotenv must stay 0600, and an executable hook
# script that must keep its +x bit.
FIX="$SMOKE_TMP_ROOT/agent-tree"
WORKDIR="$FIX/workdir"
HOMEDIR="$FIX/home"
CH_DIR="$WORKDIR/.teams"
mkdir -p "$WORKDIR" "$HOMEDIR" "$CH_DIR" "$HOMEDIR/.claude/hooks"

CLAUDE_MD="$WORKDIR/CLAUDE.md"
SOUL_MD="$HOMEDIR/SOUL.md"
HOOK_SH="$HOMEDIR/.claude/hooks/session-start.sh"
CH_ENV="$CH_DIR/.env"

printf '# profile\n'  >"$CLAUDE_MD"
printf '# soul\n'     >"$SOUL_MD"
printf '#!/usr/bin/env bash\necho hi\n' >"$HOOK_SH"
printf 'TOKEN=secret\n' >"$CH_ENV"

# Controller-time modes: identity files 0600, dirs 0700, hook 0700
# (exec bit set), channel dotenv 0600.
chmod 0700 "$FIX" "$WORKDIR" "$HOMEDIR" "$HOMEDIR/.claude" \
  "$HOMEDIR/.claude/hooks" "$CH_DIR"
chmod 0600 "$CLAUDE_MD" "$SOUL_MD" "$CH_ENV"
chmod 0700 "$HOOK_SH"   # executable script — +x MUST survive

# --- Driver factory: emit a driver that sources the helper and runs it
# against $WORKDIR + $HOMEDIR exactly as the fix does (workdir gets the
# channel-state excludes). $1 = enforcement ("yes"|"no"), $2 = out path.
_emit_driver() {
  local enforce="$1" out_driver="$2"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_ISOLATION_REQUIRED=%q\n' "$enforce"
    printf '%s\n' 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes'
    printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
    printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
    printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2.sh" 2>&1'
    printf 'WORKDIR=%q\n' "$WORKDIR"
    printf 'HOMEDIR=%q\n' "$HOMEDIR"
    printf '%s\n' 'GRP="$(id -gn)"'
    # workdir pass with the channel-state excludes (mirrors the fix).
    printf '%s\n' 'if bridge_isolation_v2_chgrp_setgid_recursive "$GRP" 2770 0660 "$WORKDIR" --exclude-subdir .teams --exclude-subdir .ms365 --exclude-subdir .discord --exclude-subdir .telegram --exclude-subdir .mattermost; then echo "WORKDIR_RC=0"; else echo "WORKDIR_RC=$?"; fi'
    # home pass (no excludes — mirrors the fix).
    printf '%s\n' 'if bridge_isolation_v2_chgrp_setgid_recursive "$GRP" 2770 0660 "$HOMEDIR"; then echo "HOME_RC=0"; else echo "HOME_RC=$?"; fi'
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$out_driver"
  chmod +x "$out_driver"
}

# --- B1: enforced run converges the tree to the contract --------------
smoke_log "B1: enforced normalization converges seeded create→isolate tree to the contract"

D1="$SMOKE_TMP_ROOT/driver-enforce.sh"
O1="$SMOKE_TMP_ROOT/driver-enforce.out"
_emit_driver yes "$D1"
"$BRIDGE_BASH" "$D1" >"$O1" 2>&1 || true

grep -q '^WORKDIR_RC=0$' "$O1" || { cat "$O1"; smoke_fail "B1: workdir normalization returned non-zero"; }
grep -q '^HOME_RC=0$'    "$O1" || { cat "$O1"; smoke_fail "B1: home normalization returned non-zero"; }

CALLER_GROUP="$(id -gn)"

# Files → 0660 (the helper's exec-aware symbolic chmod lands a plain
# text file at g+rw / o-rwx).
CLAUDE_MODE="$(_mode_of "$CLAUDE_MD")"
SOUL_MODE="$(_mode_of "$SOUL_MD")"
case "$CLAUDE_MODE" in 660) : ;; *) cat "$O1"; smoke_fail "B1: $CLAUDE_MD not 0660 after normalize (got $CLAUDE_MODE) — #1506 not fixed"; esac
case "$SOUL_MODE"   in 660) : ;; *) cat "$O1"; smoke_fail "B1: $SOUL_MD not 0660 after normalize (got $SOUL_MODE) — home tree not normalized"; esac

# Dirs → 2770 (group rwx + setgid). Assert low bits (770) and the setgid
# bit separately for BSD/GNU portability (BSD `%Lp` drops the setgid bit).
WD_MODE="$(_mode_of "$WORKDIR")"
HD_MODE="$(_mode_of "$HOMEDIR")"
case "$WD_MODE" in 770|2770) : ;; *) cat "$O1"; smoke_fail "B1: workdir low-bits not 770 after normalize (got $WD_MODE)"; esac
case "$HD_MODE" in 770|2770) : ;; *) cat "$O1"; smoke_fail "B1: homedir low-bits not 770 after normalize (got $HD_MODE)"; esac
_has_setgid "$WORKDIR" || { cat "$O1"; smoke_fail "B1: workdir missing setgid bit after normalize (got $WD_MODE) — new children would not inherit the agent group"; }
_has_setgid "$HOMEDIR" || { cat "$O1"; smoke_fail "B1: homedir missing setgid bit after normalize (got $HD_MODE) — new children would not inherit the agent group"; }

# Group → caller's primary group (the rootless seam stand-in for
# ab-agent-<a>; on the live Linux path this is the agent group).
CLAUDE_GRP="$(stat -c '%G' "$CLAUDE_MD" 2>/dev/null || stat -f '%Sg' "$CLAUDE_MD")"
if [[ "$CLAUDE_GRP" != "$CALLER_GROUP" ]]; then
  cat "$O1"
  smoke_fail "B1: $CLAUDE_MD group not normalized to '$CALLER_GROUP' (got '$CLAUDE_GRP')"
fi
smoke_log "B1 PASS — files 0660, dirs 2770 setgid, group=$CALLER_GROUP (matches the test_clean contract)"

# --- B2: exec-bit preservation ----------------------------------------
smoke_log "B2: executable hook script keeps its +x bit (no blanket chmod 0660)"
HOOK_MODE="$(_mode_of "$HOOK_SH")"
# Exec-aware symbolic chmod: a 0700 script lands at 0770 (g+rwX adds the
# group exec bit because the file already had user-exec). The load-
# bearing assertion is that SOME exec bit survives (i.e. mode is NOT
# 0660). A naive blanket chmod 0660 would strip it to 660 and break
# SessionStart hooks.
case "$HOOK_MODE" in
  770) smoke_log "B2 PASS — hook is 0770 (group exec preserved by the exec-aware symbolic chmod)" ;;
  660) cat "$O1"; smoke_fail "B2: hook lost its exec bit (got 660) — a naive blanket chmod 0660 was used, breaking SessionStart hooks" ;;
  *)
    # Any mode that still carries an exec bit somewhere is acceptable;
    # reject only the exec-stripped 0660. Probe via -x for robustness.
    if [[ -x "$HOOK_SH" ]]; then
      smoke_log "B2 PASS — hook still executable after normalize (mode $HOOK_MODE)"
    else
      cat "$O1"
      smoke_fail "B2: hook is no longer executable after normalize (mode $HOOK_MODE)"
    fi
    ;;
esac

# --- B3: channel-state dotenv is NOT clobbered ------------------------
smoke_log "B3: v3 channel state .env stays 0600 (workdir excludes .teams)"
CH_ENV_MODE="$(_mode_of "$CH_ENV")"
case "$CH_ENV_MODE" in
  600) smoke_log "B3 PASS — .teams/.env stayed 0600 (exclude honored, v3 contract intact)" ;;
  *) cat "$O1"; smoke_fail "B3: .teams/.env mode changed to $CH_ENV_MODE — channel-state exclude not honored (v3 dotenv would be group-readable)" ;;
esac

# --- B4: idempotency — second enforced run is a no-op converge --------
smoke_log "B4: re-running the normalization converges (idempotent, no churn, rc=0)"
D2="$SMOKE_TMP_ROOT/driver-enforce-2.sh"
O2="$SMOKE_TMP_ROOT/driver-enforce-2.out"
_emit_driver yes "$D2"
"$BRIDGE_BASH" "$D2" >"$O2" 2>&1 || true
grep -q '^WORKDIR_RC=0$' "$O2" || { cat "$O2"; smoke_fail "B4: second workdir normalization returned non-zero (not idempotent)"; }
grep -q '^HOME_RC=0$'    "$O2" || { cat "$O2"; smoke_fail "B4: second home normalization returned non-zero (not idempotent)"; }
# Modes unchanged after the second pass (low bits + setgid still set).
[[ "$(_mode_of "$CLAUDE_MD")" == "660" ]] || { cat "$O2"; smoke_fail "B4: CLAUDE.md mode changed on the idempotent re-run"; }
case "$(_mode_of "$WORKDIR")" in 770|2770) : ;; *) cat "$O2"; smoke_fail "B4: workdir low-bits changed on the idempotent re-run"; esac
_has_setgid "$WORKDIR" || { cat "$O2"; smoke_fail "B4: workdir lost setgid on the idempotent re-run"; }
[[ "$(_mode_of "$CH_ENV")"    == "600" ]]  || { cat "$O2"; smoke_fail "B4: .teams/.env mode changed on the idempotent re-run"; }
smoke_log "B4 PASS — second run rc=0 with no mode churn (idempotent)"

# --- B5: no-op when v2 enforcement is OFF (macOS / shared mode) --------
smoke_log "B5: clean no-op when enforcement is off (macOS / shared mode)"
NOOP_FIX="$SMOKE_TMP_ROOT/noop-tree"
NOOP_WD="$NOOP_FIX/workdir"
mkdir -p "$NOOP_WD"
NOOP_FILE="$NOOP_WD/CLAUDE.md"
printf '# noop\n' >"$NOOP_FILE"
chmod 0700 "$NOOP_FIX" "$NOOP_WD"
chmod 0600 "$NOOP_FILE"
NOOP_FILE_BEFORE="$(_mode_of "$NOOP_FILE")"
NOOP_WD_BEFORE="$(_mode_of "$NOOP_WD")"

D3="$SMOKE_TMP_ROOT/driver-noop.sh"
O3="$SMOKE_TMP_ROOT/driver-noop.out"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  printf '%s\n' 'export BRIDGE_ISOLATION_REQUIRED=no'
  printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2.sh" 2>&1'
  printf 'NOOP_WD=%q\n' "$NOOP_WD"
  printf '%s\n' 'GRP="$(id -gn)"'
  printf '%s\n' 'if bridge_isolation_v2_chgrp_setgid_recursive "$GRP" 2770 0660 "$NOOP_WD"; then echo "NOOP_RC=0"; else echo "NOOP_RC=$?"; fi'
} | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$D3"
chmod +x "$D3"
"$BRIDGE_BASH" "$D3" >"$O3" 2>&1 || true

grep -q '^NOOP_RC=0$' "$O3" || { cat "$O3"; smoke_fail "B5: helper returned non-zero in no-op (enforcement off) mode"; }
NOOP_FILE_AFTER="$(_mode_of "$NOOP_FILE")"
NOOP_WD_AFTER="$(_mode_of "$NOOP_WD")"
if [[ "$NOOP_FILE_AFTER" != "$NOOP_FILE_BEFORE" || "$NOOP_WD_AFTER" != "$NOOP_WD_BEFORE" ]]; then
  cat "$O3"
  smoke_fail "B5: enforcement-off run mutated the tree (file $NOOP_FILE_BEFORE->$NOOP_FILE_AFTER dir $NOOP_WD_BEFORE->$NOOP_WD_AFTER) — should be a clean no-op on macOS / shared mode"
fi
smoke_log "B5 PASS — enforcement-off run left the tree untouched (file=$NOOP_FILE_AFTER dir=$NOOP_WD_AFTER)"

if smoke_is_linux; then
  smoke_log "host=Linux — behavioral runs used the rootless primary-group seam; the live OS-user + ab-agent-<a> path is covered by the PR's manual Linux repro"
else
  smoke_log "host=non-Linux — contract verified via the forced-enforcement primary-group seam; live OS-user/group path is Linux + sudo only (see PR manual repro)"
fi

smoke_log "PASS — #1506: isolate normalizes the pre-existing profile tree to the iso v2 contract (group + 2770/0660), idempotently, exec-bit-preserving, channel-state-excluding, no-op off Linux"
exit 0
