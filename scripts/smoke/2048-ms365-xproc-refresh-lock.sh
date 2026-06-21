#!/usr/bin/env bash
# scripts/smoke/2048-ms365-xproc-refresh-lock.sh — issue #2048.
#
# Cross-process refresh_token double-consume guard for the ms365 plugin.
#
# AAD refresh_token is single-use rotating. The in-process SingleFlight
# (token-refresh.ts) serializes refreshes WITHIN one Node process, but the
# SAME per-UPN token file is rotated by SEPARATE processes — the MCP server,
# the `get-valid-token` CLI one-shot, any other caller. Two processes that
# read RT1 concurrently → the first POST rotates RT2 (invalidating RT1) → the
# second POST replays the spent RT1 → invalid_grant / AADSTS70000 (permanent)
# → forced re-auth (~every 3h under concurrent Graph+bearer load).
#
# The fix (server.ts): a dependency-free O_EXCL cross-process lock keyed on the
# token file wraps the grant in getAccessToken, and AFTER acquiring the lock the
# token is RE-READ — if another holder already rotated it, the redundant grant
# is skipped and the shared fresh token returned. Serialize + re-read ⇒ exactly
# one grant, zero spent-RT replay.
#
# This smoke drives the REAL getAccessToken path via the plugin's one-shot
# `get-valid-token` CLI, spawning N processes that race a refresh against the
# SAME fixture UPN token file. A fetch-mock stub models Entra's single-use
# rotation in a shared sidecar (atomic O_EXCL compare-and-swap): a POST with
# the live RT rotates it and emits MOCK_GRANT; a POST with a SPENT RT emits
# MOCK_INVALID_GRANT and returns invalid_grant/AADSTS70000.
#
#   T1 (the fix): N racers against the real server.ts → EXACTLY ONE MOCK_GRANT,
#       ZERO MOCK_INVALID_GRANT, every racer exits 0 with a valid token.
#   T2 (mutation): the same race against a copy of server.ts with the
#       cross-process lock disabled (the acquireRefreshLock call sed-stripped to
#       a null handle) → the double-consume REPRODUCES (>= 1 MOCK_INVALID_GRANT).
#       Proves T1's pass is caused by the lock, not by accident of timing.
#   T3 (timeout): a pre-held stale-free lock makes a refresh caller proceed
#       cleanly within a bounded budget — it never hangs (rc 0, bounded wall).
#   T4 (stale reclaim): a lockfile with a dead PID is reclaimed; the refresh
#       still completes (no permanent deadlock from a crashed holder).
#   T5 (hygiene): the lockfile carries NO token material (only pid/host/ts).
#
# Falls back to a source-grep contract when bun is unavailable (CI images
# without bun); the behavioral race is the primary gate when bun exists.
#
# Footgun #11: heredocs here write to FILES only (fixture/stub), never to a
# subprocess stdin; bun is invoked with argv (no heredoc-fed bash/python3).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
MS365_DIR="$REPO_ROOT/plugins/ms365"
MS365_TS="$MS365_DIR/server.ts"

log() { printf '[smoke:2048-ms365-xproc-refresh-lock] %s\n' "$*"; }
fail() { printf '[smoke:2048-ms365-xproc-refresh-lock][error] %s\n' "$*" >&2; exit 1; }

[[ -f "$MS365_TS" ]] || fail "required file missing: $MS365_TS"

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR_BASE/agb-2048-smoke.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

# --- source-grep contract (always runs; fast and bun-independent) ----------
# C1: the cross-process lock primitive is an O_EXCL lockfile (no flock(1), no
#     proper-lockfile dep) keyed on the token path.
log "C1: O_EXCL lockfile primitive present (no flock shell-out)"
grep -Eq "function acquireRefreshLock" "$MS365_TS" \
  || fail "C1: no acquireRefreshLock helper"
grep -Eq "openSync\(lockPath, 'wx'" "$MS365_TS" \
  || fail "C1: lock does not use an O_EXCL ('wx') create"
grep -Eq "function lockPathFor" "$MS365_TS" \
  || fail "C1: no lockPathFor (token-keyed lock path) helper"
# Reject an ACTUAL flock(1) shell-out (execSync/spawnSync 'flock ...'), but not
# the comments that explain why we DON'T use flock(1). Strip comment lines first.
grep -vE "^[[:space:]]*//|^[[:space:]]*\*" "$MS365_TS" >"$WORK/code-noc.txt" || true
if grep -Eq "execSync\(['\"\`][^'\"\`]*flock|spawnSync\(['\"]flock|exec\(['\"\`][^'\"\`]*flock" "$WORK/code-noc.txt"; then
  fail "C1: server.ts shells out to flock(1) — must stay a portable fs lock"
fi

# C2: getAccessToken acquires the lock then RE-READS the token (the
#     double-consume fix) and releases on every exit path.
log "C2: getAccessToken acquires lock + re-reads + releases in finally"
awk '
  /^async function getAccessToken/ {cap=1}
  cap {buf=buf$0 ORS}
  cap && /^}/ && NR>1 {print buf; exit}
' "$MS365_TS" >"$WORK/gat.txt"
[[ -s "$WORK/gat.txt" ]] || fail "C2: could not isolate getAccessToken"
grep -Eq "acquireRefreshLock\(upn\)" "$WORK/gat.txt" \
  || fail "C2: getAccessToken does not acquire the cross-process lock"
grep -Eq "normalizeTokenExpiry\(loadJson<TokenFile>\(tokenPath\(upn\)\)\)" "$WORK/gat.txt" \
  || fail "C2: getAccessToken does not re-read the token after acquiring the lock"
grep -Eq "release\?\.\(\)" "$WORK/gat.txt" \
  || fail "C2: getAccessToken does not release the lock (no release?.() in finally)"
grep -Eq "finally" "$WORK/gat.txt" \
  || fail "C2: getAccessToken has no finally block to release the lock"
# The lock+re-read+refresh must coalesce same-process callers through a
# SingleFlight (so only the in-process flight leader takes the cross-process
# lock), keyed distinctly from refreshInFlight so the leader can still call
# refreshToken() inside without self-deadlocking the flight.
grep -Eq "lockedRefreshInFlight\.run\(upn" "$WORK/gat.txt" \
  || fail "C2: getAccessToken does not coalesce the locked refresh through a per-UPN SingleFlight"
# The skip-redundant-grant decision must key off the rotated refresh_token VALUE
# (immune to same-second saved_at collisions), not a timestamp comparison.
grep -Eq "refresh_token !== prevRefreshToken|refresh_token!==prevRefreshToken" "$WORK/gat.txt" \
  || fail "C2: skip-grant does not compare the refresh_token value (saved_at-precision regression risk)"

# C3: lock hygiene — bounded timeout, stale-lock reclaim, no token in the file.
log "C3: bounded timeout + stale reclaim + no-token-in-lockfile"
grep -Eq "REFRESH_LOCK_TIMEOUT_MS" "$MS365_TS" \
  || fail "C3: no bounded acquisition timeout constant"
grep -Eq "function isStaleLock" "$MS365_TS" \
  || fail "C3: no stale-lock reclaim helper"
grep -Eq "process\.kill\(meta\.pid, 0\)" "$MS365_TS" \
  || fail "C3: stale reclaim does not PID-liveness-check the holder"
grep -Eq "REFRESH_LOCK_TTL_MS" "$MS365_TS" \
  || fail "C3: stale reclaim has no mtime TTL"
# Reclaim must be SERIALIZED under a guard + RE-VERIFY staleness before unlink,
# so two concurrent stale-waiters cannot both remove the lock and clobber a
# third process's freshly-created live lock (the r2 TOCTOU).
grep -Eq "function reclaimStaleLock" "$MS365_TS" \
  || fail "C3: no serialized reclaimStaleLock guard (reclaim is TOCTOU-unsafe)"
awk '
  /function reclaimStaleLock/ {cap=1}
  cap {buf=buf$0 ORS}
  cap && /^}/ && NR>1 {print buf; exit}
' "$MS365_TS" >"$WORK/reclaim.txt"
[[ -s "$WORK/reclaim.txt" ]] || fail "C3: could not isolate reclaimStaleLock"
grep -Eq "openSync\(guard, 'wx'" "$WORK/reclaim.txt" \
  || fail "C3: reclaim is not serialized by an O_EXCL guard"
grep -Eq "if \(isStaleLock\(lockPath\)\)" "$WORK/reclaim.txt" \
  || fail "C3: reclaim does not RE-VERIFY staleness under the guard before unlink"
# clampLockMs must validate the env config (no NaN unbounded spin).
grep -Eq "function clampLockMs" "$MS365_TS" \
  || fail "C3: no clampLockMs env validation (NaN timeout would unbound the spin)"
# The lock body must record pid/host/acquired_at and NOTHING token-shaped.
awk '
  /function acquireRefreshLock/ {cap=1}
  cap {buf=buf$0 ORS}
  cap && /^}/ && NR>1 {print buf; exit}
' "$MS365_TS" >"$WORK/acq.txt"
if grep -Eq "refresh_token|access_token|cur\.refresh|\.refresh_token" "$WORK/acq.txt"; then
  fail "C3: acquireRefreshLock references token material — the lockfile must carry none"
fi

# --- behavioral race (primary gate when bun is available) ------------------
if ! command -v bun >/dev/null 2>&1; then
  log "bun not found — behavioral race skipped (source-grep contract passed)"
  log "passed"
  exit 0
fi

if [[ ! -d "$MS365_DIR/node_modules/@modelcontextprotocol" ]]; then
  log "installing ms365 plugin deps (bun install)"
  ( cd "$MS365_DIR" && bun install --no-summary >/dev/null 2>&1 ) \
    || { log "bun install failed (offline?) — behavioral race skipped"; log "passed"; exit 0; }
fi

# Single-use-RT rotating Entra stub. State lives in a shared sidecar file so the
# stub enforces rotation across the racing PROCESSES (each CLI process loads the
# preload fresh). Compare-and-swap on the live RT is made atomic with an O_EXCL
# guard lock so two simultaneous POSTs cannot both "win" the rotation — exactly
# Entra's single-use contract. The submitted refresh_token is read from the POST
# body; a spent RT → invalid_grant + a MOCK_INVALID_GRANT marker.
cat >"$WORK/mock-fetch.ts" <<'TS'
import { openSync, closeSync, writeSync, readFileSync, writeFileSync, renameSync, unlinkSync, appendFileSync, statSync } from 'fs'

const RT_STATE = process.env.MOCK_RT_STATE_FILE as string
const RT_LOCK = RT_STATE + '.cas.lock'
const BARRIER = RT_STATE + '.barrier'
const BARRIER_N = Number(process.env.MOCK_BARRIER_N ?? '0')
const BARRIER_TIMEOUT_MS = Number(process.env.MOCK_BARRIER_TIMEOUT_MS ?? '1500')

// Converge the racing grant POSTs at a barrier BEFORE any rotation so the
// double-consume window is exercised DETERMINISTICALLY: every process that
// reaches a real refresh_token POST has already read its RT from the token file
// (the POST body), so if they all rendezvous here they all hold the SAME RT.
//   - Mutant (no cross-process lock): all N callers POST → barrier fills to N →
//     releases at once → first rotates, the rest replay the spent RT → the
//     double-consume reproduces every run.
//   - Fixed (lock present): only ONE caller reaches a POST (the others re-read
//     the freshly rotated token and skip), so the barrier never fills — it just
//     times out after BARRIER_TIMEOUT_MS and that lone caller grants cleanly.
// Disabled (BARRIER_N <= 0) for the non-race single-caller cases (T3/T4/T5).
function barrier(): void {
  if (BARRIER_N <= 0) return
  appendFileSync(BARRIER, 'x')
  const deadline = Date.now() + BARRIER_TIMEOUT_MS
  for (;;) {
    let arrived = 0
    try { arrived = statSync(BARRIER).size } catch {}
    if (arrived >= BARRIER_N) return
    if (Date.now() >= deadline) return
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10)
  }
}

function withCas<T>(fn: () => T): T {
  // Bounded spin on an O_EXCL guard so the stub's RT compare-and-swap is atomic
  // across the racing processes (models Entra serializing redemption).
  const deadline = Date.now() + 5000
  for (;;) {
    try {
      const fd = openSync(RT_LOCK, 'wx')
      closeSync(fd)
      break
    } catch (e: any) {
      if (!e || e.code !== 'EEXIST') throw e
      if (Date.now() >= deadline) throw new Error('mock CAS lock timeout')
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5)
    }
  }
  try {
    return fn()
  } finally {
    try { unlinkSync(RT_LOCK) } catch {}
  }
}

const realFetch = globalThis.fetch
globalThis.fetch = (async (url: any, init?: any) => {
  const u = String(url)
  if (u.includes('login.microsoftonline.com') && u.includes('/oauth2/v2.0/token')) {
    const body = String(init?.body ?? '')
    const params = new URLSearchParams(body)
    const submitted = params.get('refresh_token') ?? ''
    // Converge all racing POSTs here (they have already read their RT) before
    // any rotation, so the double-consume window is deterministic.
    barrier()
    return withCas(() => {
      const live = readFileSync(RT_STATE, 'utf8').trim()
      if (submitted !== live) {
        // Replay of a spent (already-rotated) refresh_token → permanent.
        process.stderr.write('MOCK_INVALID_GRANT submitted=' + submitted + '\n')
        return new Response(JSON.stringify({
          error: 'invalid_grant',
          error_description: 'AADSTS70000: provided value for refresh_token is not valid.',
        }), { status: 400, headers: { 'Content-Type': 'application/json' } })
      }
      // Live RT → rotate it (single-use) and mint a fresh access_token.
      const next = 'RT_' + Math.random().toString(36).slice(2, 12)
      const tmp = RT_STATE + '.tmp'
      writeFileSync(tmp, next)
      renameSync(tmp, RT_STATE)
      process.stderr.write('MOCK_GRANT old=' + submitted + ' new=' + next + '\n')
      return new Response(JSON.stringify({
        access_token: 'AT_' + next,
        refresh_token: next,
        expires_in: 3600,
        scope: 'openid profile offline_access',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
  }
  return realFetch(url, init)
}) as any
TS

UPN="smoke@example.com"
# slugUpn: lowercase + non-[A-Za-z0-9._-] → '_'. smoke@example.com → smoke_example.com
TOKEN_SLUG="smoke_example.com"
N=8

# write_expired_token <state_dir> <rt>  — token already expired so every racer
# crosses the refresh threshold (the worst-case concurrent-refresh window).
write_expired_token() {
  local state="$1" rt="$2" now
  now="$(date +%s)"
  mkdir -p "$state/tokens"
  cat >"$state/tokens/${TOKEN_SLUG}.json" <<JSON
{"upn":"$UPN","access_token":"AT_INITIAL","refresh_token":"$rt","expires_at":$((now - 60)),"scope":"openid profile offline_access","saved_at":$((now - 3600))}
JSON
}

# race <server.ts> <state_dir> <rt_state_file> [extra-cli-flag...] — spawn N CLI
# refreshers at once, wait, and tally MOCK_GRANT / MOCK_INVALID_GRANT + exit
# codes. Trailing args (e.g. --force) are passed to every racer's CLI. Sets
# globals GRANTS, INVALIDS, NONZERO.
race() {
  local server="$1" state="$2" rtfile="$3"
  shift 3
  local extra=("$@")
  local errdir="$state/errs"
  mkdir -p "$errdir"
  local pids=() i rc
  for ((i = 0; i < N; i++)); do
    (
      MS365_STATE_DIR="$state" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
      MS365_DEFAULT_UPN="$UPN" MOCK_RT_STATE_FILE="$rtfile" \
      MOCK_BARRIER_N="$N" \
        bun --preload "$WORK/mock-fetch.ts" "$server" get-valid-token "$UPN" ${extra[@]+"${extra[@]}"} \
        >"$errdir/out.$i" 2>"$errdir/err.$i"
      echo "$?" >"$errdir/rc.$i"
    ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  # MOCK_GRANT and MOCK_INVALID_GRANT are distinct markers (the latter is not a
  # substring of the former); count each from its own line prefix.
  GRANTS="$(cat "$errdir"/err.* 2>/dev/null | grep -c '^MOCK_GRANT ' || true)"
  INVALIDS="$(cat "$errdir"/err.* 2>/dev/null | grep -c '^MOCK_INVALID_GRANT ' || true)"
  NONZERO=0
  for ((i = 0; i < N; i++)); do
    rc="$(cat "$errdir/rc.$i" 2>/dev/null || echo 1)"
    [[ "$rc" == "0" ]] || NONZERO=$((NONZERO + 1))
  done
}

# T1 — the fix: N racers against the REAL server.ts → exactly one grant, zero
# invalid_grant, all exit 0.
log "T1: $N concurrent refreshers (real lock) → exactly 1 grant, 0 invalid_grant"
S1="$WORK/s1"; RT1="$WORK/rt1.state"
echo "RT_ORIGIN" >"$RT1"
write_expired_token "$S1" "RT_ORIGIN"
race "$MS365_TS" "$S1" "$RT1"
log "T1 result: grants=$GRANTS invalid_grant=$INVALIDS nonzero_exits=$NONZERO"
[[ "$GRANTS" == "1" ]]   || fail "T1: expected exactly 1 grant POST, got $GRANTS (the lock did not serialize the grant)"
[[ "$INVALIDS" == "0" ]] || fail "T1: expected 0 invalid_grant, got $INVALIDS (spent-RT replay — double-consume not closed)"
[[ "$NONZERO" == "0" ]]  || fail "T1: $NONZERO of $N racers exited non-zero (a caller failed to get a valid token)"

# T2 — mutation: disable the cross-process lock and prove the race REPRODUCES
# the double-consume. A copy of server.ts with acquireRefreshLock forced to
# return null (no lock) must produce >= 1 invalid_grant. If this does NOT
# reproduce, T1's pass is vacuous (the lock is not what made it green).
log "T2 (mutation): lock disabled → double-consume reproduces (>= 1 invalid_grant)"
# The mutant MUST live inside plugins/ms365/ so its relative imports
# (./disclosure.ts, ./token-refresh.ts) and the node_modules MCP SDK resolve.
# Unique name + explicit cleanup so a parallel run / interrupt cannot collide.
MUT="$MS365_DIR/.server.2048mutant.$$.ts"
cleanup_mutant() { rm -f "$MUT" 2>/dev/null || true; }
trap 'cleanup_mutant; rm -rf "$WORK" 2>/dev/null' EXIT INT TERM
# Replace the lock-acquire with a null handle so getAccessToken proceeds unlocked.
sed 's/const release = acquireRefreshLock(upn)/const release = (null as null | (() => void))/' \
  "$MS365_TS" >"$MUT"
grep -q "const release = (null as null" "$MUT" \
  || fail "T2: mutation sed did not match the acquireRefreshLock call site (source drifted)"
REPRO=0
# The stub barrier makes the double-consume DETERMINISTIC in the mutant (all N
# unlocked POSTs converge before any rotation), so one attempt is normally
# enough; a small retry budget absorbs any scheduler outlier. A passing fix
# must NEVER produce an invalid_grant, so any reproduction is the signal.
for attempt in 1 2 3; do
  SM="$WORK/sm.$attempt"; RTM="$WORK/rtm.$attempt.state"
  echo "RT_ORIGIN" >"$RTM"
  write_expired_token "$SM" "RT_ORIGIN"
  race "$MUT" "$SM" "$RTM"
  log "T2 attempt $attempt: grants=$GRANTS invalid_grant=$INVALIDS nonzero_exits=$NONZERO"
  if [[ "$INVALIDS" -ge 1 ]]; then REPRO=1; break; fi
done
[[ "$REPRO" == "1" ]] \
  || fail "T2: lock-disabled mutant produced 0 invalid_grant across 3 attempts — T1 is not mutation-proven"

# T3 — bounded timeout: a refresh caller must NOT hang on a held (non-stale)
# lock. Pre-create a FRESH lockfile owned by THIS shell's live PID, then time a
# single refresher with a short lock timeout — it must return within the budget
# (it cannot acquire, so it proceeds unlocked and refreshes), never hanging.
log "T3: held non-stale lock → caller returns within a bounded budget (no hang)"
S3="$WORK/s3"; RT3="$WORK/rt3.state"
echo "RT_ORIGIN" >"$RT3"
write_expired_token "$S3" "RT_ORIGIN"
LOCK3="$S3/tokens/${TOKEN_SLUG}.json.lock"
printf '{"pid":%s,"host":"%s","acquired_at":%s}' "$$" "$(hostname)" "$(( $(date +%s) * 1000 ))" >"$LOCK3"
START="$(date +%s)"
MS365_STATE_DIR="$S3" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
MS365_DEFAULT_UPN="$UPN" MOCK_RT_STATE_FILE="$RT3" MS365_REFRESH_LOCK_TIMEOUT_MS=500 \
  bun --preload "$WORK/mock-fetch.ts" "$MS365_TS" get-valid-token "$UPN" \
  >"$S3/out" 2>"$S3/err"
T3RC=$?
ELAPSED=$(( $(date +%s) - START ))
log "T3 result: rc=$T3RC elapsed=${ELAPSED}s"
[[ "$T3RC" == "0" ]] || fail "T3: refresher under a held lock exited non-zero ($T3RC) — should proceed unlocked, not fail"
[[ "$ELAPSED" -le 8 ]] || fail "T3: refresher took ${ELAPSED}s under a 500ms lock timeout — it HUNG on the lock"
rm -f "$LOCK3" 2>/dev/null || true

# T3b — NaN env guard: a non-numeric MS365_REFRESH_LOCK_TIMEOUT_MS must NOT
# disable the deadline (Number('garbage') === NaN; Date.now() >= NaN is always
# false → unbounded spin). With a held lock and a garbage timeout, the caller
# must still terminate within the built-in budget and proceed unlocked.
log "T3b: non-numeric lock timeout env still terminates (no NaN unbounded spin)"
S3B="$WORK/s3b"; RT3B="$WORK/rt3b.state"
echo "RT_ORIGIN" >"$RT3B"
write_expired_token "$S3B" "RT_ORIGIN"
LOCK3B="$S3B/tokens/${TOKEN_SLUG}.json.lock"
printf '{"pid":%s,"host":"%s","acquired_at":%s}' "$$" "$(hostname)" "$(( $(date +%s) * 1000 ))" >"$LOCK3B"
START="$(date +%s)"
MS365_STATE_DIR="$S3B" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
MS365_DEFAULT_UPN="$UPN" MOCK_RT_STATE_FILE="$RT3B" MS365_REFRESH_LOCK_TIMEOUT_MS=not-a-number \
  bun --preload "$WORK/mock-fetch.ts" "$MS365_TS" get-valid-token "$UPN" \
  >"$S3B/out" 2>"$S3B/err"
T3BRC=$?
ELAPSEDB=$(( $(date +%s) - START ))
log "T3b result: rc=$T3BRC elapsed=${ELAPSEDB}s (falls back to the built-in 8s budget)"
[[ "$T3BRC" == "0" ]] || fail "T3b: refresher with a garbage timeout env exited non-zero ($T3BRC)"
[[ "$ELAPSEDB" -le 12 ]] || fail "T3b: garbage timeout env caused an unbounded spin (${ELAPSEDB}s) — NaN not clamped"
rm -f "$LOCK3B" 2>/dev/null || true

# T4 — stale reclaim: a lockfile owned by a DEAD pid must be reclaimed so a
# crashed holder cannot deadlock the file. Pre-create a lock with a guaranteed-
# dead pid; a single refresher must reclaim it, acquire, and grant cleanly.
log "T4: stale lock (dead PID) is reclaimed → refresh completes (no deadlock)"
S4="$WORK/s4"; RT4="$WORK/rt4.state"
echo "RT_ORIGIN" >"$RT4"
write_expired_token "$S4" "RT_ORIGIN"
LOCK4="$S4/tokens/${TOKEN_SLUG}.json.lock"
# Find a PID that does not exist (kill -0 fails). 2147483646 is above any live
# pid; verify it really is dead before relying on it.
DEAD_PID=2147483646
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
printf '{"pid":%s,"host":"%s","acquired_at":%s}' "$DEAD_PID" "$(hostname)" "$(( $(date +%s) * 1000 ))" >"$LOCK4"
MS365_STATE_DIR="$S4" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
MS365_DEFAULT_UPN="$UPN" MOCK_RT_STATE_FILE="$RT4" MS365_REFRESH_LOCK_TIMEOUT_MS=2000 \
  bun --preload "$WORK/mock-fetch.ts" "$MS365_TS" get-valid-token "$UPN" \
  >"$S4/out" 2>"$S4/err"
T4RC=$?
G4="$(grep -c 'MOCK_GRANT' "$S4/err" || true)"
log "T4 result: rc=$T4RC grants=$G4"
[[ "$T4RC" == "0" ]] || fail "T4: refresher could not reclaim a dead-PID stale lock (rc=$T4RC) — crashed holder deadlocked the file"
[[ "$G4" == "1" ]] || fail "T4: expected exactly 1 grant after stale reclaim, got $G4"

# T5 — hygiene: the REAL lockfile written by acquireRefreshLock must carry NO
# token material. Run one refresher against a stub that BLOCKS (sleeps) while
# holding the token endpoint open, snapshot the live lockfile off disk during
# that window, and assert its content (token-shaped grep + key-shape check).
# The shape check runs from a python FILE invoked by argv — heredocs that write
# to a FILE are footgun-#11-safe; only heredoc-fed subprocess STDIN is banned.
log "T5: the real on-disk lockfile carries no token material (pid/host/ts only)"
S5="$WORK/s5"; RT5="$WORK/rt5.state"
echo "RT_ORIGIN" >"$RT5"
write_expired_token "$S5" "RT_ORIGIN"
LOCK5="$S5/tokens/${TOKEN_SLUG}.json.lock"
# A blocking stub: signal readiness, then spin so the lock stays held while we
# snapshot it. Written to a FILE (preload), never to a subprocess stdin.
cat >"$WORK/mock-block.ts" <<'TS'
import { writeFileSync } from 'fs'
const realFetch = globalThis.fetch
globalThis.fetch = (async (url: any, init?: any) => {
  const u = String(url)
  if (u.includes('login.microsoftonline.com') && u.includes('/oauth2/v2.0/token')) {
    writeFileSync(process.env.MOCK_READY_FILE as string, 'ready')
    const until = Date.now() + 2500
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2500)
    while (Date.now() < until) {}
    return new Response(JSON.stringify({
      access_token: 'AT_BLOCKED', refresh_token: 'RT_BLOCKED',
      expires_in: 3600, scope: 'openid',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })
  }
  return realFetch(url, init)
}) as any
TS
READY="$WORK/ready.flag"; rm -f "$READY"
(
  MS365_STATE_DIR="$S5" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
  MS365_DEFAULT_UPN="$UPN" MOCK_READY_FILE="$READY" \
    bun --preload "$WORK/mock-block.ts" "$MS365_TS" get-valid-token "$UPN" \
    >"$S5/out" 2>"$S5/err"
) &
BLOCK_PID=$!
# Wait (bounded) for the stub to enter the grant POST = the lock is held.
for _ in $(seq 1 200); do
  [[ -f "$READY" ]] && break
  sleep 0.05
done
[[ -f "$LOCK5" ]] || { wait "$BLOCK_PID" 2>/dev/null || true; fail "T5: no lockfile on disk while a grant was in flight"; }
cp "$LOCK5" "$WORK/lock.snapshot"
wait "$BLOCK_PID" 2>/dev/null || true
if grep -Eq 'RT_|AT_|refresh_token|access_token|RT_ORIGIN|RT_BLOCKED' "$WORK/lock.snapshot"; then
  fail "T5: the live lockfile contained token-shaped material"
fi
cat >"$WORK/check-shape.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
allowed = {"pid", "host", "acquired_at"}
extra = set(d.keys()) - allowed
assert not extra, f"unexpected lockfile keys: {extra}"
PY
python3 "$WORK/check-shape.py" "$WORK/lock.snapshot" \
  || fail "T5: lockfile is not the {pid,host,acquired_at}-only shape"

# T6 — concurrent --force racers: the force path is the precision-critical one.
# A force refresh bypasses the freshness margin, so the skip-redundant-grant
# decision keys off whether the refresh_token was ROTATED (a value compare,
# immune to same-second saved_at collisions), NOT a timestamp. N simultaneous
# --force callers against one UPN must still produce EXACTLY ONE grant and ZERO
# invalid_grant. The barrier converges them before any rotation, so a saved_at-
# precision bug (same-second writes) would reproduce the double-consume here.
log "T6: $N concurrent --force racers → exactly 1 grant, 0 invalid_grant"
S6="$WORK/s6"; RT6="$WORK/rt6.state"
echo "RT_ORIGIN" >"$RT6"
# A fresh (NOT expired) token so the ONLY reason to refresh is --force — this is
# the path #2035 item 2 added and the one the saved_at-precision concern targets.
mkdir -p "$S6/tokens"
NOW6="$(date +%s)"
cat >"$S6/tokens/${TOKEN_SLUG}.json" <<JSON
{"upn":"$UPN","access_token":"AT_INITIAL","refresh_token":"RT_ORIGIN","expires_at":$((NOW6 + 3600)),"scope":"openid profile offline_access","saved_at":$NOW6}
JSON
race "$MS365_TS" "$S6" "$RT6" --force
log "T6 result: grants=$GRANTS invalid_grant=$INVALIDS nonzero_exits=$NONZERO"
[[ "$GRANTS" == "1" ]]   || fail "T6: expected exactly 1 grant POST under concurrent --force, got $GRANTS (force path did not serialize)"
[[ "$INVALIDS" == "0" ]] || fail "T6: expected 0 invalid_grant under concurrent --force, got $INVALIDS (force-path double-consume — same-second saved_at bug?)"
[[ "$NONZERO" == "0" ]]  || fail "T6: $NONZERO of $N --force racers exited non-zero"

# T7 — mutation: the same concurrent --force race against the lock-disabled
# mutant must REPRODUCE the double-consume (>= 1 invalid_grant), proving T6's
# pass is caused by the cross-process serialization, not by timing.
log "T7 (mutation): --force race with lock disabled → double-consume reproduces"
REPRO_F=0
for attempt in 1 2 3; do
  SF="$WORK/sf.$attempt"; RTF="$WORK/rtf.$attempt.state"
  echo "RT_ORIGIN" >"$RTF"
  mkdir -p "$SF/tokens"
  nowf="$(date +%s)"
  cat >"$SF/tokens/${TOKEN_SLUG}.json" <<JSON
{"upn":"$UPN","access_token":"AT_INITIAL","refresh_token":"RT_ORIGIN","expires_at":$((nowf + 3600)),"scope":"openid profile offline_access","saved_at":$nowf}
JSON
  race "$MUT" "$SF" "$RTF" --force
  log "T7 attempt $attempt: grants=$GRANTS invalid_grant=$INVALIDS nonzero_exits=$NONZERO"
  if [[ "$INVALIDS" -ge 1 ]]; then REPRO_F=1; break; fi
done
[[ "$REPRO_F" == "1" ]] \
  || fail "T7: lock-disabled --force mutant produced 0 invalid_grant across 3 attempts — T6 is not mutation-proven"

# T8 — concurrent stale-waiters reclaim (codex r2 TOCTOU): pre-seed a stale
# (dead-PID) lock, then race N refreshers that ALL observe it and must reclaim.
# Without a SERIALIZED, re-verified reclaim, two waiters could each remove the
# lock and clobber a third's freshly-created live lock → >1 grant and/or a
# spent-RT replay. With the reclaim guard, exactly ONE winner grants; the rest
# re-read the rotated token and skip → 1 grant, 0 invalid_grant, 0 failures.
log "T8: $N racers over a pre-seeded stale lock → reclaim serialized (1 grant, 0 invalid_grant)"
S8="$WORK/s8"; RT8="$WORK/rt8.state"
echo "RT_ORIGIN" >"$RT8"
write_expired_token "$S8" "RT_ORIGIN"
LOCK8="$S8/tokens/${TOKEN_SLUG}.json.lock"
# Seed a dead-PID lock so every racer's first acquire attempt hits a stale lock
# and must go through the reclaim path concurrently.
DEAD_PID8=2147483646
while kill -0 "$DEAD_PID8" 2>/dev/null; do DEAD_PID8=$((DEAD_PID8 - 1)); done
printf '{"pid":%s,"host":"%s","acquired_at":%s}' "$DEAD_PID8" "$(hostname)" "$(( ($(date +%s) - 9999) * 1000 ))" >"$LOCK8"
race "$MS365_TS" "$S8" "$RT8"
log "T8 result: grants=$GRANTS invalid_grant=$INVALIDS nonzero_exits=$NONZERO"
[[ "$GRANTS" == "1" ]]   || fail "T8: expected exactly 1 grant after concurrent stale reclaim, got $GRANTS (reclaim not serialized → multiple holders)"
[[ "$INVALIDS" == "0" ]] || fail "T8: expected 0 invalid_grant over a concurrent stale reclaim, got $INVALIDS (a clobbered live lock let a spent RT replay)"
[[ "$NONZERO" == "0" ]]  || fail "T8: $NONZERO of $N racers exited non-zero during concurrent stale reclaim"

log "passed"
