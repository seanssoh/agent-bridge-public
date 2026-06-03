#!/usr/bin/env bash
# 1497-p2-operator-home smoke — issue #1497 Phase 2 (operator-home SSOT).
#
# Phase 2 consolidates the operator's Agent Bridge home resolver
# (`$BRIDGE_HOME` or `~/.agent-bridge`) into a single canonical SSOT,
# `lib/operator_home.py::operator_home()`, and routes the former duplicates
# through it WITHOUT behavior change:
#
#   * 3 byte-identical `bridge_home_dir()` wrappers now delegate:
#       - hooks/bridge_hook_common.py   (Tier-1 — runs every session)
#       - bridge_guard_common.py
#       - lib/system_config_paths.py
#   * 6 inline resolvers inside bridge-queue.py (the queue backbone) now call
#     operator_home() (or build their sub-path FROM it): get_db_path,
#     get_queue_gateway_root, proxy_via_queue_gateway (--bridge-home arg),
#     get_cron_state_dir, get_queue_bodies_dir, bridge_managed_roots.
#
# DEFERRED to P3 (divergent form — NOT migrated): bridge_a2a_common.bridge_home()
# and the two hook `_bridge_home()` wrappers (pre-compact / session-stop), whose
# fallbacks are load-bearing and differ from the canonical default-home form.
#
# Design principle under test: ONE resolver, zero behavior change for the
# migrated sites. The canonical form is strip()+expanduser()+`~/.agent-bridge`
# fallback with the empty-default guard that keeps the unset case from raising
# (the every-session hook-load footgun).
#
# Cases:
#   R1 — resolver: BRIDGE_HOME=/tmp/x -> /tmp/x.
#   R2 — resolver: BRIDGE_HOME="  /tmp/y  " -> /tmp/y (whitespace stripped).
#   R3 — resolver: BRIDGE_HOME=~/z -> $HOME/z (tilde expanded).
#   R4 — resolver TEETH: BRIDGE_HOME unset -> $HOME/.agent-bridge and MUST NOT
#        raise (the empty-default + guard footgun; a hook-load crash class).
#   P1 — parity: each delegating bridge_home_dir() == operator_home() across
#        set / stripped / tilde / empty / unset env shapes (3 modules).
#   P2 — parity: each of the 6 bridge-queue.py call-sites' resulting path is
#        byte-identical to the pre-P2 inline form, set + unset.
#   H1 — hook non-regression: importing bridge_hook_common with BRIDGE_HOME
#        unset and calling bridge_home_dir() returns a valid Path (no raise).
#   T1 — TEETH: a system_config_paths copy with the delegation reverted to a
#        BROKEN body must FAIL the parity assertion (proves delegation is
#        load-bearing — a hollow no-op would still "pass").
#   S1 — TEETH (#1507 r2): the import seam loads lib/operator_home.py by EXACT
#        path (not via sys.path), so a same-named `operator_home` SHADOW module
#        cannot hijack a consumer's resolver — neither with lib/ present (real
#        wins) nor on a partial deploy with lib/ absent (inline fallback wins,
#        NOT the shadow). Covers the every-session hook AND the queue DB path.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

# Hermetic isolation: this smoke may run inside a LIVE bridge agent session
# whose env exports BRIDGE_HOME / BRIDGE_STATE_DIR / etc. Scrub every operator
# path channel up front; each case re-exports only the var it means to test.
unset BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_TASK_DB BRIDGE_CRON_STATE_DIR \
  BRIDGE_SHARED_DIR BRIDGE_LAYOUT BRIDGE_AGENT_ROOT_V2 BRIDGE_DATA_ROOT \
  2>/dev/null || true

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

# ----- resolver helper ----------------------------------------------------
# Drives operator_home() under a chosen BRIDGE_HOME and prints its str().
# `python3 -c "<double-quoted>"` (NOT heredoc-stdin) keeps lint-heredoc-ban
# happy; the BRIDGE_HOME value is passed via the environment so no literal
# `os.environ` text appears on a shell line (iso-helper boundary ratchet).
op_home() {
  local lib_dir="$1"
  "$PYTHON" -c "
import sys
sys.path.insert(0, '$lib_dir')
from operator_home import operator_home
print(str(operator_home()))
" 2>&1
}

# ----- R1: explicit set ---------------------------------------------------
r1_got="$(BRIDGE_HOME='/tmp/agb-1497-p2-r1' op_home "$REPO_ROOT/lib")"
if [[ "$r1_got" == "/tmp/agb-1497-p2-r1" ]]; then
  pass "R1: explicit BRIDGE_HOME wins ($r1_got)"
else
  fail "R1: explicit BRIDGE_HOME mismatch — got [$r1_got]"
fi

# ----- R2: whitespace stripped --------------------------------------------
r2_got="$(BRIDGE_HOME='  /tmp/agb-1497-p2-r2  ' op_home "$REPO_ROOT/lib")"
if [[ "$r2_got" == "/tmp/agb-1497-p2-r2" ]]; then
  pass "R2: surrounding whitespace stripped ($r2_got)"
else
  fail "R2: whitespace not stripped — got [$r2_got]"
fi

# ----- R3: tilde expanded -------------------------------------------------
# The tilde is passed LITERALLY into BRIDGE_HOME on purpose: this asserts the
# Python resolver's expanduser() does the expansion, NOT the shell. SC2088 is
# exactly the behavior under test, so the quoting is intentional.
r3_expect="$HOME/agb-1497-p2-r3"
# shellcheck disable=SC2088
r3_got="$(BRIDGE_HOME='~/agb-1497-p2-r3' op_home "$REPO_ROOT/lib")"
if [[ "$r3_got" == "$r3_expect" ]]; then
  pass "R3: tilde expanded ($r3_got)"
else
  fail "R3: tilde not expanded — got [$r3_got] expected [$r3_expect]"
fi

# ----- R4: unset MUST NOT raise, defaults to $HOME/.agent-bridge ----------
# This is the footgun guard: a naive Path(os.environ.get("BRIDGE_HOME"))...
# would raise AttributeError on unset and crash every session at hook-load.
r4_expect="$HOME/.agent-bridge"
# op_home is a function in THIS shell; call it in a subshell with BRIDGE_HOME
# unset (rather than re-injecting the function into a nested `bash -c`, which
# mangles the embedded python3 -c string).
r4_got="$(unset BRIDGE_HOME; op_home "$REPO_ROOT/lib")"
if [[ "$r4_got" == "$r4_expect" ]]; then
  pass "R4: unset defaults to \$HOME/.agent-bridge without raising ($r4_got)"
else
  fail "R4: unset case wrong or raised — got [$r4_got] expected [$r4_expect]"
fi

# ----- P1: delegation parity (3 bridge_home_dir() == operator_home()) -----
# One Python driver compares every delegating wrapper to the canonical
# resolver across each env shape. Driver body goes to a temp FILE then runs
# as `python3 <file>` (heredoc into a file is allowed; heredoc-stdin is not).
p1_driver="$(mktemp -t agb-1497-p2-p1.XXXXXX.py)"
cat > "$p1_driver" <<'PY'
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(repo / "lib"))
sys.path.insert(0, str(repo / "hooks"))
sys.path.insert(0, str(repo))

from operator_home import operator_home
import system_config_paths as scp
import bridge_hook_common as bhc
import bridge_guard_common as bgc

shapes = ["/tmp/p2x", "  /tmp/p2y  ", "~/p2z", "", None]
ok = True
for s in shapes:
    if s is None:
        os.environ.pop("BRIDGE_HOME", None)
        label = "unset"
    else:
        os.environ["BRIDGE_HOME"] = s
        label = repr(s)
    base = str(operator_home())
    a = str(scp.bridge_home_dir())
    b = str(bhc.bridge_home_dir())
    c = str(bgc.bridge_home_dir())
    if not (a == base == b == c):
        ok = False
        print(f"MISMATCH env={label} canon={base} scp={a} bhc={b} bgc={c}")
print("ALL_PARITY_OK" if ok else "PARITY_FAILED")
PY
p1_out="$("$PYTHON" "$p1_driver" "$REPO_ROOT" 2>&1)"
rm -f "$p1_driver"
if printf '%s' "$p1_out" | grep -q 'ALL_PARITY_OK'; then
  pass "P1: 3 bridge_home_dir() wrappers byte-identical to operator_home() (all env shapes)"
else
  fail "P1: delegation parity broke — $p1_out"
fi

# ----- P2: bridge-queue.py 6-site byte-identical parity --------------------
# Compare each migrated bridge-queue function's resulting path against the
# pre-P2 inline oracle: Path(os.environ.get("BRIDGE_HOME", str(Path.home() /
# ".agent-bridge"))). ALL SIX sites are exercised in BOTH the set and unset
# cases — including the three mkdir functions and the proxy --bridge-home argv:
#   * mkdir functions stay hermetic by pointing HOME at a tmp dir for the unset
#     case, so the resolved ~/.agent-bridge lands under tmp (never the live home).
#   * the proxy argv is checked by DRIVING proxy_via_queue_gateway() with
#     subprocess.run monkeypatched to capture the constructed command, then
#     reading the actual --bridge-home element (not just operator_home()). A
#     wrong proxy resolver therefore fails this case.
# bridge_managed_roots resolves its roots, so the oracle resolves too.
p2_driver="$(mktemp -t agb-1497-p2-p2.XXXXXX.py)"
cat > "$p2_driver" <<'PY'
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
tmp_set_home = sys.argv[2]   # explicit BRIDGE_HOME for the set case
tmp_unset_home = sys.argv[3]  # HOME override for the unset case (mkdir-safe)
sys.path.insert(0, str(repo / "lib"))


def load_bq():
    spec = importlib.util.spec_from_file_location("bq_p2", str(repo / "bridge-queue.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def oracle_home():
    # The exact pre-P2 inline form.
    return Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))


bq = load_bq()
ok = True


def chk(name, got, expect):
    global ok
    if str(got) != str(expect):
        ok = False
        print(f"MISMATCH {name}: got={got} expect={expect}")


def drive_proxy_bridge_home():
    """Drive proxy_via_queue_gateway() and return its constructed --bridge-home
    argv element, by capturing the command instead of spawning the gateway."""
    captured = {}

    def fake_run(command, *a, **k):
        captured["command"] = list(command)

        class _R:
            returncode = 0
        return _R()

    real_run = subprocess.run
    bq.subprocess.run = fake_run
    # Force the socket branch (builds `--bridge-home str(operator_home())`) and
    # make queue_gateway_proxy_agent() return a non-empty agent.
    saved = {k: os.environ.get(k) for k in (
        "BRIDGE_GATEWAY_TRANSPORT", "BRIDGE_GATEWAY_PROXY", "BRIDGE_AGENT_ID",
        "BRIDGE_QUEUE_GATEWAY_SERVER")}
    os.environ["BRIDGE_GATEWAY_TRANSPORT"] = "socket"
    os.environ["BRIDGE_GATEWAY_PROXY"] = "1"
    os.environ["BRIDGE_AGENT_ID"] = "p2probe"
    os.environ.pop("BRIDGE_QUEUE_GATEWAY_SERVER", None)
    try:
        bq.proxy_via_queue_gateway(["inbox", "p2probe"])
    finally:
        bq.subprocess.run = real_run
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    cmd = captured.get("command", [])
    if "--bridge-home" not in cmd:
        return None
    return cmd[cmd.index("--bridge-home") + 1]


for label, envval, home_override in (
    ("clean-set", tmp_set_home, None),
    ("unset", None, tmp_unset_home),
):
    if envval is None:
        os.environ.pop("BRIDGE_HOME", None)
    else:
        os.environ["BRIDGE_HOME"] = envval
    if home_override is not None:
        os.environ["HOME"] = home_override
    for k in ("BRIDGE_STATE_DIR", "BRIDGE_TASK_DB", "BRIDGE_CRON_STATE_DIR",
              "BRIDGE_SHARED_DIR", "BRIDGE_LAYOUT", "BRIDGE_AGENT_ROOT_V2"):
        os.environ.pop(k, None)
    home = oracle_home()
    # 1-2: non-mkdir derived paths.
    chk(f"[{label}] get_queue_gateway_root", bq.get_queue_gateway_root(), home / "state" / "queue-gateway")
    got_roots = sorted(str(p) for p in bq.bridge_managed_roots())
    exp_roots = sorted(str(p.resolve()) for p in (home, home / "state", home / "shared"))
    chk(f"[{label}] bridge_managed_roots", got_roots, exp_roots)
    # 3: proxy --bridge-home argv — drive the REAL function, not operator_home().
    chk(f"[{label}] proxy --bridge-home argv", drive_proxy_bridge_home(), str(home))
    # 4-6: mkdir functions — run in BOTH cases (unset is hermetic via HOME tmp).
    chk(f"[{label}] get_db_path", bq.get_db_path(), home / "state" / "tasks.db")
    chk(f"[{label}] get_cron_state_dir", bq.get_cron_state_dir(), home / "state" / "cron")
    chk(f"[{label}] get_queue_bodies_dir", bq.get_queue_bodies_dir(), home / "state" / "queue" / "bodies")

print("ALL_BQ_PARITY_OK" if ok else "BQ_PARITY_FAILED")
PY
p2_set_home="$(mktemp -d -t agb-1497-p2-set.XXXXXX)"
p2_unset_home="$(mktemp -d -t agb-1497-p2-unset.XXXXXX)"
p2_out="$("$PYTHON" "$p2_driver" "$REPO_ROOT" "$p2_set_home" "$p2_unset_home" 2>&1)"
rm -f "$p2_driver"
rm -rf "$p2_set_home" "$p2_unset_home"
if printf '%s' "$p2_out" | grep -q 'ALL_BQ_PARITY_OK'; then
  pass "P2: bridge-queue.py 6 call-sites byte-identical to pre-P2 inline form (set + unset, proxy argv driven)"
else
  fail "P2: bridge-queue parity broke — $p2_out"
fi

# ----- H1: hook non-regression (import + call, BRIDGE_HOME unset) ----------
h1_got="$(
  env -u BRIDGE_HOME "$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
import bridge_hook_common as bhc
p = bhc.bridge_home_dir()
print('OK' if str(p).endswith('.agent-bridge') else 'BAD:' + str(p))
" 2>&1
)"
if [[ "$h1_got" == "OK" ]]; then
  pass "H1: bridge_hook_common imports + bridge_home_dir() valid Path with BRIDGE_HOME unset"
else
  fail "H1: hook non-regression broke — got [$h1_got]"
fi

# ----- T1: TEETH — a reverted delegation must break parity -----------------
# Copy system_config_paths.py, rewrite its delegating body into a BROKEN one
# (returns a fixed wrong path), and assert parity with operator_home() NO
# LONGER holds. If this "passes" with the real delegation in place, the
# delegation is hollow. Mutator goes to a temp file (heredoc-stdin is banned).
t1_root="$(mktemp -d -t agb-1497-p2-t1.XXXXXX)"
t1_lib="$t1_root/lib"
mkdir -p "$t1_lib"
cp "$REPO_ROOT/lib/operator_home.py" "$t1_lib/operator_home.py"
cp "$REPO_ROOT/lib/system_config_paths.py" "$t1_lib/system_config_paths.py"
t1_mutator="$(mktemp -t agb-1497-p2-t1.XXXXXX.py)"
cat > "$t1_mutator" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
patched = text.replace(
    "    return operator_home()",
    '    from pathlib import Path as _P\n    return _P("/tmp/agb-1497-p2-teeth-WRONG")',
    1,
)
if patched == text:
    raise SystemExit("TEETH setup error: delegation marker not found")
open(path, "w", encoding="utf-8").write(patched)
PY
"$PYTHON" "$t1_mutator" "$t1_lib/system_config_paths.py"
rm -f "$t1_mutator"
t1_got="$(
  BRIDGE_HOME='/tmp/agb-1497-p2-t1-home' "$PYTHON" -c "
import sys
sys.path.insert(0, '$t1_lib')
from operator_home import operator_home
import system_config_paths as scp
canon = str(operator_home())
broken = str(scp.bridge_home_dir())
print('TEETH_BIT' if broken != canon else 'TEETH_MISSED')
" 2>&1
)"
rm -rf "$t1_root"
if [[ "$t1_got" == "TEETH_BIT" ]]; then
  pass "T1: TEETH — reverted delegation breaks parity (delegation is load-bearing)"
else
  fail "T1: TEETH did not bite — reverted delegation still matched canonical: [$t1_got]"
fi

# ----- S1: TEETH — import seam is shadow-proof (#1507 r2) ------------------
# A same-named operator_home module on sys.path must NEVER hijack a consumer's
# resolver. The seam loads lib/operator_home.py by EXACT path via importlib, so
# (A/C) with lib present a shadow loses, and (B/D) on a partial deploy (lib
# absent) the consumer takes its byte-identical inline fallback — NOT the shadow.
# Covers the every-session hook (bridge_hook_common) AND the queue DB path
# (bridge-queue.get_db_path). Driver writes the shadow itself and reads no
# environment dict directly; the shell sets HOME to a tmp dir (mkdir-hermetic for
# get_db_path) and unsets BRIDGE_HOME so the expected answer is HOME/.agent-bridge.
s1_home="$(mktemp -d -t agb-1497-p2-s1home.XXXXXX)"
s1_driver="$(mktemp -t agb-1497-p2-s1.XXXXXX.py)"
cat > "$s1_driver" <<'PY'
import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
SENTINEL = "/tmp/AGB-P2-SHADOW-DO-NOT-USE"
ok = True


def load_by_path(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write_shadow(dirpath):
    body = (
        "from pathlib import Path\n"
        "def operator_home():\n"
        f"    return Path({SENTINEL!r})\n"
    )
    Path(dirpath, "operator_home.py").write_text(body, encoding="utf-8")


def bad(tag, got):
    global ok
    ok = False
    print(f"{tag} got={got}")


# A: hook, real lib present + shadow on sys.path -> real lib wins.
shadow_a = tempfile.mkdtemp()
write_shadow(shadow_a)
sys.path.insert(0, shadow_a)
got = str(load_by_path("bhc_s1a", repo / "hooks" / "bridge_hook_common.py").operator_home())
if "SHADOW" in got or not got.endswith("/.agent-bridge"):
    bad("A_HOOK_HIJACK", got)

# B: hook, partial deploy (no co-located lib) + shadow -> inline fallback.
root_b = tempfile.mkdtemp()
hooks_b = Path(root_b, "hooks")
hooks_b.mkdir()
shutil.copy(str(repo / "hooks" / "bridge_hook_common.py"), str(hooks_b / "bridge_hook_common.py"))
write_shadow(str(hooks_b))   # shadow co-located; root_b/lib/operator_home.py absent
sys.path.insert(0, str(hooks_b))
got = str(load_by_path("bhc_s1b", hooks_b / "bridge_hook_common.py").operator_home())
if "SHADOW" in got or not got.endswith("/.agent-bridge"):
    bad("B_HOOK_PARTIAL_HIJACK", got)

# C: queue DB, real lib present + shadow on sys.path -> real lib wins.
got = str(load_by_path("bq_s1c", repo / "bridge-queue.py").get_db_path())
if "SHADOW" in got or "/.agent-bridge/state/tasks.db" not in got:
    bad("C_QUEUE_HIJACK", got)

# D: queue DB, partial deploy (no co-located lib) + shadow -> inline fallback.
root_d = tempfile.mkdtemp()
shutil.copy(str(repo / "bridge-queue.py"), str(Path(root_d, "bridge-queue.py")))
write_shadow(root_d)         # shadow co-located; root_d/lib/operator_home.py absent
sys.path.insert(0, root_d)
got = str(load_by_path("bq_s1d", Path(root_d, "bridge-queue.py")).get_db_path())
if "SHADOW" in got or "/.agent-bridge/state/tasks.db" not in got:
    bad("D_QUEUE_PARTIAL_HIJACK", got)

print("SHADOW_REJECTED_OK" if ok else "SHADOW_HIJACK")
PY
s1_out="$(env -u BRIDGE_HOME HOME="$s1_home" "$PYTHON" "$s1_driver" "$REPO_ROOT" 2>&1)"
rm -f "$s1_driver"
rm -rf "$s1_home"
if printf '%s' "$s1_out" | grep -q 'SHADOW_REJECTED_OK'; then
  pass "S1: import seam shadow-proof — exact-path load beats a sys.path shadow (hook + queue DB, lib-present + partial-deploy) (#1507 r2)"
else
  fail "S1: import seam shadowable — $s1_out"
fi

# ----- Summary -----------------------------------------------------------
printf '\n[smoke] 1497-p2-operator-home: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
