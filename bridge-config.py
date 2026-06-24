#!/usr/bin/env python3
"""bridge-config.py — operator-gated wrapper for system-config mutations.

Issue #341 makes this the only normal mutation path for the protected
file list (see `lib/system_config_paths.py`). Direct Edit/Write tool
calls against those paths are denied by `hooks/tool-policy.py`; the
wrapper layers the caller-agent + caller-source check that the hook
deliberately does not enforce.

CLI shape mirrors the brief:

    bridge-config.py set  --path <p> --change <expr> [--from <agent>]
    bridge-config.py get  --path <p>
    bridge-config.py list-protected [--json]

`set` accepts:

    key=value                     # top-level scalar set
    a.b.c=value                   # nested scalar set (creates intermediate dicts)
    a.b.append=value              # append to a list at a.b
    a.b.remove=value              # remove first occurrence from a.b list

Both before-sha256 and after-sha256 are recorded in the audit row so the
operator can compare a wrapper-apply event against the file's at-rest
hash on disk.

Trust model (issue #1738 — process-ancestry binding, NOT env identity):

    The `set` / `set-env` mutation gate authorizes from a controller-published
    per-agent tmux pane-pid binding matched against THIS wrapper's process
    ancestry (a shell cannot set its own parent pid), or a real operator TTY
    passing `--from <canonical-admin>` when no agent binding matches.
    `BRIDGE_AGENT_ID` / `BRIDGE_ADMIN_AGENT_ID` / `BRIDGE_CALLER_SOURCE` no
    longer drive any positive authorization (they were spoofable by a sibling
    shell stage behind eval / bash -c / sh -c / $var indirection). See
    `resolve_config_caller` for the full decision table. The `operator-tui` /
    `operator-trusted-id` / `agent-direct` labels remain only as audit buckets.

This file is invoked through `bridge-config.sh`, which is in turn dispatched
by the `agent-bridge config …` subcommand.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
LIB_DIR = ROOT / "lib"
if LIB_DIR.is_dir() and str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from system_config_paths import (  # noqa: E402
    PROTECTED_GLOBS,
    bridge_home_dir,
    is_protected_path,
    matched_pattern,
)


# Caller-source audit buckets. These are the LABELS the audit row records for
# the resolved caller (issue #1738 `resolve_config_caller`); they are no longer
# read from process env for an authorization decision.
CALLER_SOURCE_OPERATOR_TUI = "operator-tui"
CALLER_SOURCE_OPERATOR_TRUSTED_ID = "operator-trusted-id"
CALLER_SOURCE_AGENT_DIRECT = "agent-direct"


# ---------------------------------------------------------------------------
# Issue #1734 — `set-env`: durable install env-override path for the admin.
#
# The admin had no working path to set a durable install-level env override:
# `agent-roster.local.sh` is blocked by the #341 write-gate and `config set`
# is JSON-only (the roster is shell `export VAR=val`). `set-env` writes a
# dedicated, audited managed file (`$BRIDGE_HOME/agent-env.local.sh`) that
# `bridge_load_roster` sources AFTER the roster, with the SAME trust model
# as `config set` (admin identity + operator-tui / operator-trusted-id).
#
# The KEY surface is a NARROW, explicit allowlist of non-secret operational
# knobs — NOT a general env-setter. Each allowed key is one that the daemon
# / receiver reads from `os.environ` (verified against the source), is a
# benign timing/threshold knob, and carries a per-key type so an out-of-type
# or out-of-range value is rejected before it can land in the managed file.
#
# Everything else is denied. The DENY surface is defense-in-depth: even if a
# future edit accidentally widened the allowlist, the explicit deny list
# (roots / identity / control / secrets / test-bypass) and the
# secret-substring screen below would still reject the dangerous keys.

# Per-key value type. The validator coerces+range-checks the raw string and
# returns the canonical string form (or raises ValueError). Two kinds today:
#   "pos_int"  — strictly positive integer (>= 1)
#   "pos_float"— strictly positive float  (> 0)
#   "int_min2" — integer >= 2 (hysteresis thresholds; a value of 1 defeats
#                the invariant the consuming code documents)
ENV_KEY_TYPE_POS_INT = "pos_int"
ENV_KEY_TYPE_POS_FLOAT = "pos_float"
ENV_KEY_TYPE_INT_MIN2 = "int_min2"
#   "non_neg_int" — integer >= 0, where 0 is a meaningful "disable" sentinel
#                   (e.g. BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=0 turns the reaper
#                   off). Distinct from pos_int, which floors at 1.
ENV_KEY_TYPE_NON_NEG_INT = "non_neg_int"
#   "flag_one"   — the literal string "1" and nothing else. The consuming code
#                  reads the var with strict `os.environ.get(...) != "1"`
#                  equality (a feature ON/OFF gate), so the only meaningful
#                  durable value is "1"; to turn the feature back OFF the
#                  operator removes the key from the managed file and restarts.
ENV_KEY_TYPE_FLAG_ONE = "flag_one"

# NARROW allowlist. Each entry was confirmed to be read from `os.environ`
# (not a JSON config field) and to be a non-secret operational timing /
# threshold / count knob. Path/executable overrides (BRIDGE_A2A_WARP_CLI /
# BRIDGE_A2A_TAILSCALE_CLI) are DELIBERATELY EXCLUDED — they are
# code-execution levers and belong to a separate typed path-setting feature,
# not this PR. Test/insecure binds are excluded (see ENV_KEY_DENY_*).
#
# Verified os.environ readers (origin/feat/v0166-mesh-quiet):
#   BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS  bridge_reconcile_common.py:553 (int>0)
#   BRIDGE_A2A_RECONCILE_INTERVAL            bridge_reconcile_common.py:79  (int>=0; 0 disables)
#   BRIDGE_A2A_PEER_SUSPECT_THRESHOLD        bridge_reconcile_common.py:786 (int>=2)
#   BRIDGE_A2A_PEER_PROBE_TIMEOUT_SECONDS    bridge_reconcile_common.py:804 (float>0)
#   BRIDGE_A2A_BACKOFF_CEILING_SECONDS       bridge_a2a_common.py:2650      (int, floored)
#   BRIDGE_A2A_RECEIVER_MAX_RESTARTS         bridge-status.py:1094          (int)
#   BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS bridge-status.py:1653        (int seconds)
#   BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS
#                                            lib/daemon-helpers/a2a-receiver-staleness.py:383 (int seconds)
#   BRIDGE_DYNAMIC_IDLE_REAP_SECONDS         bridge-daemon.sh:reap_idle_dynamic_agents (int>=0; 0 disables)
#   BRIDGE_A2A_ROOM_AUTOJOIN                 bridge-handoffd.py:_room_join_bootstrap_unknown_peer (== "1" gate)
ENV_KEY_ALLOWLIST: dict[str, str] = {
    "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECONCILE_INTERVAL": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_PEER_SUSPECT_THRESHOLD": ENV_KEY_TYPE_INT_MIN2,
    "BRIDGE_A2A_PEER_PROBE_TIMEOUT_SECONDS": ENV_KEY_TYPE_POS_FLOAT,
    "BRIDGE_A2A_BACKOFF_CEILING_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_MAX_RESTARTS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS": ENV_KEY_TYPE_POS_INT,
    # Issue #1795: idle dynamic-agent reaper threshold (seconds). 0 disables
    # the reaper entirely — the supported operator escape hatch when a long-
    # lived dynamic must not be GC'd. Non-secret operational knob, read from
    # os.environ by the daemon each sync cycle.
    "BRIDGE_DYNAMIC_IDLE_REAP_SECONDS": ENV_KEY_TYPE_NON_NEG_INT,
    # Issue #2024: leader-side A2A room first-contact auto-join feature gate.
    # The receiver admits an unknown peer presenting a valid room invite token
    # to a PENDING (still leader-approved) join only when this is exactly "1";
    # default-OFF, discoverable via `agb config set-env` + `agb a2a daemon
    # restart` so the receiver inherits it. Non-secret feature toggle.
    "BRIDGE_A2A_ROOM_AUTOJOIN": ENV_KEY_TYPE_FLAG_ONE,
    # Issue #16309: queue-gateway CLIENT read-wait timeout (seconds). An iso
    # agent's `agb done/claim` proxies through the daemon's once-per-tick
    # queue-gateway serve-once (bridge-queue.py:646 passes this to the gateway
    # client `--timeout`, default 45). On a heavy daemon tick the cumulative
    # pass weight can exceed 45s and starve the drain → "queue gateway timed
    # out". Raising this (e.g. 90) lets the iso client ride out a heavy tick.
    # Operator-settable here because the only sanctioned write path for the
    # shell-export `agent-env.local.sh` is `agb config set-env` (a direct edit
    # is blocked by the #341 config-path gate); a raw default-45 was otherwise
    # un-tunable on a live install. Non-secret operational knob, read from
    # os.environ by the gateway client. (Interim relief while #2 decouples the
    # gateway drain from the heavy tick.)
    "BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS": ENV_KEY_TYPE_POS_FLOAT,
}

# EXPLICIT DENY — keys that must NEVER be settable through set-env even if a
# future edit accidentally added them to the allowlist. The runtime check
# evaluates this BEFORE the allowlist so a key that appears in both is denied
# (fail-closed). Two layers:
#   (1) exact-name denies — roots, identity, control-plane, test/insecure binds.
#   (2) substring denies — anything carrying TOKEN / SECRET / KEY (any case).
ENV_KEY_DENY_EXACT: frozenset[str] = frozenset(
    {
        # Roots / state locations — repointing these moves the whole install.
        "BRIDGE_HOME",
        "BRIDGE_STATE_DIR",
        "BRIDGE_TASK_DB",
        "BRIDGE_RUNTIME_SECRETS_DIR",
        # Roster file locations (BRIDGE_ROSTER* prefix also caught below).
        "BRIDGE_ROSTER_FILE",
        "BRIDGE_ROSTER_LOCAL_FILE",
        "BRIDGE_AGENT_ENV_LOCAL_FILE",
        # Identity / control-plane — spoofing any of these defeats the trust
        # model (the wrapper's own admin/source gate keys on them).
        "BRIDGE_ADMIN_AGENT_ID",
        "BRIDGE_CALLER_SOURCE",
        "BRIDGE_CONTROLLER_UID",
        "BRIDGE_QUEUE_SAFE_CONTEXT",
        # Test / insecure binds — never settable in a durable install file.
        "BRIDGE_A2A_ALLOW_TEST_BIND",
        "BRIDGE_A2A_DEV_INSECURE_BIND",
        # Executable / CLI path overrides are code-execution levers — out of
        # scope for this typed-value feature (a separate path-setting feature
        # would validate them).
        "BRIDGE_A2A_WARP_CLI",
        "BRIDGE_A2A_TAILSCALE_CLI",
    }
)

# Prefix denies — any key starting with one of these is denied regardless of
# the rest of the name (covers BRIDGE_ROSTER*, BRIDGE_AGENT_* identity vars).
ENV_KEY_DENY_PREFIXES: tuple[str, ...] = (
    "BRIDGE_ROSTER",
    "BRIDGE_AGENT_",
)

# Substring denies (case-insensitive) — a key bearing any of these is a
# secret/credential lever and is never settable here.
ENV_KEY_DENY_SUBSTRINGS: tuple[str, ...] = ("TOKEN", "SECRET", "KEY")

# A valid env-var NAME is conservatively `[A-Z][A-Z0-9_]*`. We do NOT accept
# lowercase or leading digits — every knob we expose is an upper-snake
# BRIDGE_* name, and the strict shape keeps a value-bearing token from
# masquerading as a key.
_ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def admin_agent_id() -> str:
    """Return the configured canonical admin agent id.

    Read from `BRIDGE_ADMIN_AGENT_ID` (the controller exports this into the
    launch env). NOTE (issue #1738): this is the CANONICAL admin NAME, not a
    trust signal — `resolve_config_caller` authorizes by process-ancestry vs
    the controller-published binding (or a real operator TTY), never by this
    env value alone. An agent that re-exports a different value cannot thereby
    authorize a write: the binding's `admin_agent_id` is what the agent-pane
    path keys on, and the operator-TTY fallback still requires a real TTY.
    """
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


# ---------------------------------------------------------------------------
# Issue #1738 (SECURITY) — process-ancestry config-caller resolution.
#
# The pre-#1738 mutation gate (`detect_caller_source` / `caller_is_admin`)
# derived admin/operator trust ENTIRELY from process env
# (`BRIDGE_AGENT_ID`, `BRIDGE_ADMIN_AGENT_ID`, `BRIDGE_CALLER_SOURCE`). A
# sibling shell stage in the SAME agent-issued Bash command can seed exactly
# those vars and then hide the real invocation behind `eval` / `bash -c` /
# `sh -c` / `$var` indirection that the static `tool-policy.py` hook cannot
# resolve — so a non-admin agent spoofed admin and performed protected writes.
#
# The durable, unspoofable signal: A SHELL CANNOT SET ITS OWN PARENT PID. The
# controller (`bridge-start.sh`) publishes a per-agent binding record under
# `$BRIDGE_STATE_DIR/config-caller-bindings/<agent>.json` carrying the tmux
# `pane_pid` of the launched session right after `tmux new-session`. This
# wrapper walks ITS OWN process ancestry (via an absolute `/bin/ps`, falling
# back to /proc) and matches the parent chain against the published
# `pane_pid`. We deliberately do NOT trust `$TMUX`, a `$PATH` `tmux`, or
# env-provided identity — only ancestry vs the controller-published binding.
#
# TRUST BOUNDARY (issue #1738 r2):
#   * linux-user isolation — the binding lives under the controller-owned
#     `state/` tree (0711 dir / 0644 file), which an iso agent UID can neither
#     list nor overwrite. There the ancestry+ownership form is a REAL boundary:
#     an agent-pane admin binding authorizes a config mutation without a TTY.
#   * shared-UID (e.g. macOS without linux-user isolation) — the agent runs as
#     the same OS user that owns the bindings store, so it could forge
#     `<admin>.json` (agent_id == admin, pane_pid == one of its own ancestors)
#     and the ancestry match alone would not prove anything. We therefore FAIL
#     CLOSED on a self-writable store (`resolve_config_caller` /
#     `_binding_store_is_caller_writable`): an agent-pane admin binding is NOT
#     trusted when this caller could have written the store, so on shared-UID a
#     config mutation requires a real operator TTY with `--from <admin>`. A
#     "trust an agent pane on shared-UID too" model would need a
#     controller-verifiable signature / IPC the agent cannot forge — a separate
#     design, explicitly NOT attempted here.
# Either way, BRIDGE_AGENT_ID / BRIDGE_ADMIN_AGENT_ID / BRIDGE_CALLER_SOURCE
# never drive a positive decision; the verified env-spoof / indirection path is
# closed on both install shapes.
#
# Match-time liveness (issue #1738 r2 BLOCKER 2): a bare `pane_pid in ancestry`
# match is not sufficient — after the bound pane exits, its pid can be reused
# (iso shares the host PID space; there is no PID namespace), and a non-admin
# process that camps the freed pid would match an orphan binding. So at match
# time we re-resolve the LIVE `#{pane_pid}` of the recorded tmux `session` (via
# an absolute tmux, same discipline as the absolute ps — NO `$PATH`/`$TMUX`/env
# override in normal operation) and require it to equal the bound `pane_pid`; a
# dead session / mismatch / no-tmux is stale and is skipped (fail-closed). This
# is defense-in-depth with two other layers that shrink the orphan window
# directly: the orderly session-kill GC (fires even on the dead-session early
# return now) and a daemon reconcile prune that deletes bindings whose session
# is gone (covering crash / reboot / kill-server / SIGKILL).
#   No env seam (#1738 r3 FIX 2): `_resolve_tmux_bin` resolves tmux ONLY from a
#   fixed absolute candidate list, never from any env var — an agent owns its env
#   when it execs the wrapper, so an env-selectable tmux would be a
#   caller-controlled liveness oracle. The smoke drives liveness against a REAL
#   tmux session (real `#{pane_pid}`), not a stub.

CONFIG_CALLER_CONTEXT_AGENT_PANE = "agent-pane"
CONFIG_CALLER_CONTEXT_OPERATOR_TTY = "operator-tty"
CONFIG_CALLER_CONTEXT_UNKNOWN = "unknown"

# Walk at most this many ancestry hops. A real pane→engine→shell→wrapper chain
# is a handful deep; the bound stops a corrupted ppid loop (e.g. a ppid that
# points back into the chain) from spinning.
_ANCESTRY_MAX_HOPS = 64

# Absolute paths to the system ps. We refuse a `$PATH` ps so an agent cannot
# shadow it with a binary that lies about ppids. If neither absolute path
# exists we fall back to /proc (Linux) and finally fail closed.
_PS_ABSOLUTE_CANDIDATES = ("/bin/ps", "/usr/bin/ps")

# Absolute paths to tmux for the match-time liveness check (issue #1738 r2,
# BLOCKER 2). We refuse a `$PATH` / `$TMUX`-derived tmux for the same reason we
# refuse a `$PATH` ps: an agent controls its own process env, so any env- or
# PATH-resolved tmux could be a stub that lies about `#{pane_pid}` and re-opens
# the orphan-binding match. There is DELIBERATELY no env override for the tmux
# binary — the liveness check resolves only from this fixed absolute list, and
# tests exercise it against a REAL tmux server (a process running inside a tmux
# pane genuinely has the pane_pid in its ancestry, so the smoke seeds the real
# session + real pane_pid). If none of these exist, the check fails closed.
_TMUX_ABSOLUTE_CANDIDATES = (
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/usr/bin/tmux",
    "/bin/tmux",
)

# tmux env vars that select WHICH tmux server the absolute binary talks to. They
# are STRIPPED from the liveness probe's child env (#1738 r3 FIX 1) so a caller
# cannot redirect the probe at a private server carrying a forged pane_pid:
#   - TMUX / TMUX_PANE: set by tmux inside a pane; identify the *current* server
#     + pane. With them present, an absolute `tmux display-message` (no `-S`)
#     attaches to whatever server they name.
#   - TMUX_TMPDIR: the PARENT of tmux's default socket dir. tmux derives its
#     default socket path from it, so a caller-set TMUX_TMPDIR points a no-`-S`
#     `tmux` command at a private default server under a dir the agent controls
#     (codex r3 proof: `_live_with_TMUX_TMPDIR=44062`, `_live_without=None`).
# This tuple is the SINGLE SOURCE OF TRUTH for the strip list, mirrored by the
# daemon prune's subshell `unset TMUX TMUX_PANE TMUX_TMPDIR` guard in
# bridge-daemon.sh (`bridge_daemon_prune_orphan_config_caller_bindings`). Keep
# the two in sync.
_TMUX_SOCKET_SELECTION_ENV = ("TMUX", "TMUX_PANE", "TMUX_TMPDIR")

# #1738 r5 FIX B (env injection, HIGH): every probe subprocess (the absolute
# tmux liveness probe, the absolute ps ancestry walk, the absolute ps/owner
# lookup) runs with a STRICT ALLOWLIST env, NOT a denylist. The r3/r4 code
# stripped only the tmux socket-selection vars (`_TMUX_SOCKET_SELECTION_ENV`) but
# PASSED THROUGH everything else — including the dynamic-linker preload hooks
# `DYLD_INSERT_LIBRARIES` / `DYLD_*` (macOS) and `LD_PRELOAD` / `LD_*` (Linux).
# An agent owns its own env when it execs the wrapper, so it could preload a
# `connect()`-interpose library into the ABSOLUTE tmux/ps binary (homebrew tmux
# is adhoc-signed and honors DYLD_INSERT_LIBRARIES; `/usr/bin/tmux` honors
# LD_PRELOAD), redirecting tmux's socket connection to a private server that
# returns a forged `#{pane_pid}` — re-opening the orphan-binding match the
# absolute-binary + socket-strip discipline was meant to close (empirically
# confirmed on this host: forged 96506 vs real 89557). A denylist can never
# enumerate every injection seam; an allowlist passes ONLY the few vars the
# probes legitimately need and drops everything else (DYLD_*, LD_*, TMUX*, and
# any future loader/preload var) by construction.
#
# What stays: HOME (ps/tmux may read it), USER/LOGNAME (cosmetic), and the
# locale vars (LANG/LANGUAGE/LC_*) so ps/tmux output is not garbled. PATH is
# DELIBERATELY omitted — every probe execs an ABSOLUTE binary, so PATH is unused
# and a caller-controlled PATH is one less seam. TZ is dropped (irrelevant to
# pid/owner). The DEFAULT is exclude: an env name only survives if it is in
# `_PROBE_ENV_ALLOW` or matches `_PROBE_ENV_ALLOW_LC_PREFIX`.
_PROBE_ENV_ALLOW = ("HOME", "USER", "LOGNAME", "LANG", "LANGUAGE")
# Locale vars are an open-ended family (LC_ALL, LC_CTYPE, LC_MESSAGES, …). Allow
# the whole `LC_` namespace by prefix — none of them is a loader/preload seam.
_PROBE_ENV_ALLOW_LC_PREFIX = "LC_"


def _clean_probe_env() -> dict[str, str]:
    """Build the STRICT ALLOWLIST env for a #1738 probe subprocess (r5 FIX B).

    Returns a fresh dict containing ONLY the vars in `_PROBE_ENV_ALLOW` (when
    present in the current environment) plus any `LC_*` locale var. Every other
    var — crucially the dynamic-linker preload hooks (`DYLD_*`, `LD_*`) AND the
    tmux socket-selection vars (`TMUX`, `TMUX_PANE`, `TMUX_TMPDIR`) — is dropped
    by construction. This is the SINGLE place probe child env is built: the
    wrapper liveness probe, the ancestry `ps`, and the owner-UID lookup all use
    it, so there is exactly one allowlist to audit and keep correct.
    """
    env: dict[str, str] = {}
    for key, value in os.environ.items():
        if key in _PROBE_ENV_ALLOW or key.startswith(_PROBE_ENV_ALLOW_LC_PREFIX):
            env[key] = value
    return env


class ConfigCaller:
    """Resolved, authorization-relevant identity of a `set`/`set-env` call.

    Carries the EFFECTIVE agent/admin derived from the unspoofable binding
    (or the raw-operator-TTY fallback), the trust ``source`` bucket the audit
    row records, the ``context`` the decision came from, an ``allowed`` flag,
    and a ``reason`` string (a denial reason when ``allowed`` is False, or the
    allow rationale when True). Env identity is NEVER the basis of a positive
    decision.
    """

    __slots__ = (
        "agent_id",
        "admin_agent_id",
        "source",
        "context",
        "allowed",
        "reason",
    )

    def __init__(
        self,
        *,
        agent_id: str,
        admin_agent_id: str,
        source: str,
        context: str,
        allowed: bool,
        reason: str,
    ) -> None:
        self.agent_id = agent_id
        self.admin_agent_id = admin_agent_id
        self.source = source
        self.context = context
        self.allowed = allowed
        self.reason = reason


def config_caller_bindings_dir() -> Path:
    """Directory the controller publishes per-agent binding records into.

    `BRIDGE_STATE_DIR` is the canonical state root (the shell default is
    `$BRIDGE_HOME/state`). The binding writer in `lib/bridge-state.sh` and this
    reader MUST agree on this path. On iso this directory is controller-owned so
    the binding cannot be forged; on shared-UID it is best-effort (see caveat).
    """
    explicit = os.environ.get("BRIDGE_STATE_DIR", "").strip()  # noqa: raw-pathlib-controller-only
    if explicit:
        return Path(explicit).expanduser() / "config-caller-bindings"
    return bridge_home_dir() / "state" / "config-caller-bindings"


def _ps_ppid(pid: int) -> int | None:
    """Return the parent pid of *pid* via an ABSOLUTE ps, or None.

    Uses `<abs-ps> -o ppid= -p <pid>` (no `$PATH` lookup, no shell). On a
    platform without an absolute ps but with /proc (Linux), parses
    `/proc/<pid>/stat` field 4. Any failure returns None (the caller treats a
    broken hop as end-of-chain — fail-closed for matching).
    """
    for ps_bin in _PS_ABSOLUTE_CANDIDATES:
        if not os.path.exists(ps_bin):  # noqa: raw-pathlib-controller-only
            continue
        try:
            out = subprocess.run(
                [ps_bin, "-o", "ppid=", "-p", str(pid)],
                capture_output=True,
                text=True,
                check=False,
                # #1738 r5 FIX B: strict allowlist env so a caller-injected
                # DYLD_*/LD_* preload cannot interpose this absolute ps (which
                # walks the ancestry the whole authorization rests on).
                env=_clean_probe_env(),
            )
        except OSError:
            return None
        text = out.stdout.strip()
        if not text:
            return None
        try:
            return int(text.split()[0])
        except (ValueError, IndexError):
            return None
    # /proc fallback (Linux without an absolute ps on the probed paths).
    stat_path = Path("/proc") / str(pid) / "stat"  # noqa: raw-pathlib-controller-only
    try:
        raw = stat_path.read_text(encoding="utf-8", errors="replace")  # noqa: raw-pathlib-controller-only
    except OSError:
        return None
    # Field 2 (comm) is parenthesized and may contain spaces/parens — split on
    # the LAST ')' so field indexing after it is stable. ppid is field 4 (0-idx
    # 1 after the close-paren split).
    close = raw.rfind(")")
    if close == -1:
        return None
    tail = raw[close + 1:].split()
    if len(tail) < 2:
        return None
    try:
        return int(tail[1])
    except ValueError:
        return None


def process_ancestry_pids(start_pid: int) -> list[int]:
    """Return the chain of ancestor pids of *start_pid* (excluding itself).

    Walks ppid links until pid 1 / 0, a broken hop, a repeat (cycle guard), or
    the hop bound. The returned list is what we match the controller-published
    `pane_pid` against — the shell cannot forge any entry because it cannot set
    its own ppid.
    """
    chain: list[int] = []
    seen: set[int] = {start_pid}
    cur = start_pid
    for _ in range(_ANCESTRY_MAX_HOPS):
        ppid = _ps_ppid(cur)
        if ppid is None or ppid <= 1 or ppid in seen:
            break
        chain.append(ppid)
        seen.add(ppid)
        cur = ppid
    return chain


def _load_binding_record(path: Path) -> dict[str, Any] | None:
    """Parse one binding JSON record; return None on any read/parse problem."""
    try:
        raw = path.read_text(encoding="utf-8")  # noqa: raw-pathlib-controller-only
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _candidate_binding_paths(bindings_dir: Path) -> list[Path]:
    """Return the binding files to consider.

    Primary path: glob the bindings dir. On a shared-UID install this lists
    every agent's binding, so a match is found regardless of which agent the
    caller is. On linux-user isolation the controller publishes the dir at
    `state/` `dir_only_traverse` mode (0711) — an iso UID can NOT list it — so
    the glob returns nothing. Fallback: read the single per-agent record at the
    exact path `<dir>/<BRIDGE_AGENT_ID>.json` (0644, reachable by exact path
    even without dir-list). Using `BRIDGE_AGENT_ID` only SELECTS a candidate
    file; it is NOT trusted for authorization — the candidate's `pane_pid`
    still has to be in the caller's process ancestry, which an agent lying
    about its id cannot forge.
    """
    candidates: list[Path] = []
    try:
        listed = sorted(bindings_dir.glob("*.json"))  # noqa: raw-pathlib-controller-only
    except OSError:
        listed = []
    if listed:
        return listed
    env_agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    # Restrict to a single path component so the candidate cannot escape the
    # bindings dir via a crafted BRIDGE_AGENT_ID (e.g. `../../etc/x`).
    if env_agent and "/" not in env_agent and env_agent not in (".", ".."):
        per_agent = bindings_dir / f"{env_agent}.json"
        if per_agent.is_file():  # noqa: raw-pathlib-controller-only
            candidates.append(per_agent)
    return candidates


def _bindings_matching_ancestry(ancestry: set[int]) -> list[dict[str, Any]]:
    """Return binding records whose integer `pane_pid` is in *ancestry*.

    A record with a missing / non-integer `pane_pid` is STALE and never
    matches (deny-side of the decision table). Multiple matches are returned so
    the caller can deny on ambiguity. Each returned record carries the absolute
    path it was read from under the private `_source_path` key so the caller can
    apply the per-file store-writability gate (#1738 r2 BLOCKER 1).
    """
    bindings_dir = config_caller_bindings_dir()
    matched: list[dict[str, Any]] = []
    for entry in _candidate_binding_paths(bindings_dir):
        record = _load_binding_record(entry)
        if record is None:
            continue
        pane_pid = record.get("pane_pid")
        # bool is a subclass of int — exclude it explicitly so a JSON `true`
        # cannot masquerade as pid 1.
        if not isinstance(pane_pid, int) or isinstance(pane_pid, bool):
            # Stale / malformed binding — never matches (fail-closed).
            continue
        if pane_pid in ancestry:
            record["_source_path"] = str(entry)
            matched.append(record)
    return matched


def _path_is_caller_forgeable(path: str) -> bool:
    """True iff THIS euid could write/replace *path* (#1738 r3 B1, ownership).

    OWNERSHIP is the test, not the current mode bits. `os.access(W_OK)` only
    reflects the mode at probe time, which the OWNER can flip: a same-UID
    attacker can forge the record, then `chmod 0444`/`0555` it before invoking
    the wrapper so `os.access` reports non-writable — yet the owner can re-chmod
    and rewrite at will, so the record is still forgeable (r2 B1 bypass,
    reproduced by both reviewers). So we treat a path as forgeable when ANY of:

      * the caller OWNS it (`st_uid == os.geteuid()`) — the owner can always
        re-chmod and overwrite, regardless of the current 0444/0555 camouflage;
      * it is group-writable or other-writable (a non-owner in the group, or
        anyone, could write it directly).

    Only a path owned by a DIFFERENT uid AND not group/other-writable is
    non-forgeable by this caller — exactly the linux-user-isolation shape
    (controller-owned 0711 dir / 0644 file under a different uid). Any
    `os.stat` failure (missing / unreadable) is treated as forgeable
    (fail-closed): we never open the authorization on an inconclusive probe.
    """
    try:
        st = os.stat(path)
    except OSError:
        return True
    if st.st_uid == os.geteuid():
        return True
    # Group-writable (S_IWGRP 0o020) or other-writable (S_IWOTH 0o002): a
    # non-owner could still create/overwrite the record.
    if st.st_mode & 0o022:
        return True
    return False


def _binding_store_is_caller_writable(record: dict[str, Any]) -> bool:
    """True iff THIS process could forge the matched binding (#1738 r3 B1).

    The binding record is unsigned. On a shared-UID install the agent runs as
    the same OS user that owns the bindings store, so it can create or replace
    `<admin>.json` with `agent_id == admin` and a `pane_pid` of one of its own
    ancestors — turning the "pane-bound admin" positive path into a forgeable
    primitive (the env-spoof hole moved, not closed). We fail closed: an
    agent-pane admin binding only authorizes when the caller could NOT have
    written it.

    Forgeable (via `_path_is_caller_forgeable`, OWNERSHIP-based — r2's
    `os.access(W_OK)` was chmod-camouflage-bypassable) means the caller could
    write EITHER the bindings directory (create / replace a record) OR the
    matched record file (overwrite it in place). On linux-user isolation the
    controller owns the store under a different uid (0711 dir / 0644 file) and
    the agent UID owns neither → returns False → trusted (the real boundary). On
    shared-UID the caller owns both → True → fail-closed, regardless of any
    `chmod 0444`/`0555` the owner applied. We default to "writable" (fail-closed)
    if a probe raises, so an unexpected OS error never opens the authorization.
    """
    try:
        bindings_dir = str(config_caller_bindings_dir())
    except OSError:
        return True
    if _path_is_caller_forgeable(bindings_dir):
        return True
    source = record.get("_source_path")
    if isinstance(source, str) and source:
        if _path_is_caller_forgeable(source):
            return True
    return False


def _resolve_tmux_bin() -> str | None:
    """Return an ABSOLUTE tmux path for the liveness probe, or None.

    Mirrors `_PS_ABSOLUTE_CANDIDATES`: tmux resolves ONLY from the fixed absolute
    candidate list — never through `$PATH`, `$TMUX`, or ANY env override. There is
    DELIBERATELY no env seam (#1738 r3 FIX 2): an agent owns its own env when it
    execs the wrapper, so any env-selectable tmux is a caller-controlled security
    oracle — it could point liveness at a stub that lies about `#{pane_pid}` and
    re-open the orphan-binding match (the r2 `BRIDGE_CONFIG_ALLOW_TEST_TMUX` seam
    did exactly this; both reviewers rejected it). Bridge requires tmux, so this
    list resolves in production; the smoke drives liveness against a REAL tmux
    session. None makes the liveness check fail closed.
    """
    for candidate in _TMUX_ABSOLUTE_CANDIDATES:
        if os.path.exists(candidate):  # noqa: raw-pathlib-controller-only
            return candidate
    return None


def _live_pane_pid_for_session(session: str) -> int | None:
    """Return the LIVE `#{pane_pid}` of tmux *session*, or None if unresolvable.

    Uses an absolute tmux (`<abs-tmux> display-message -t <session> -p
    '#{pane_pid}'`, no `$PATH`, no shell). None means the session is gone, tmux
    is unavailable, or the output is not an integer — every such case is treated
    by the caller as "binding is stale → skip" (fail-closed).

    The child env is built by `_clean_probe_env` — a STRICT ALLOWLIST (#1738 r5
    FIX B) that drops, by construction, ALL tmux socket-selection env (`TMUX`,
    `TMUX_PANE`, `TMUX_TMPDIR` — `_TMUX_SOCKET_SELECTION_ENV`, the r3 FIX 1
    closure) AND the dynamic-linker preload hooks (`DYLD_*`, `LD_*`). The
    controller publishes the binding's session on the DEFAULT tmux server, so
    liveness must query that server. An agent owns its own env when it execs the
    wrapper and could otherwise point this probe at a private server — via
    `$TMUX`/`$TMUX_PANE`, via `$TMUX_TMPDIR` (the parent of the default socket
    dir), OR via a `connect()`-interpose library preloaded into the absolute
    tmux through `$DYLD_INSERT_LIBRARIES`/`$LD_PRELOAD` — carrying a same-named
    session with a forged pane_pid, re-opening the orphan-binding match the
    absolute-binary discipline closes. The allowlist passes only the few
    benign vars tmux needs and drops every redirection seam.
    """
    if not session:
        return None
    tmux_bin = _resolve_tmux_bin()
    if tmux_bin is None:
        return None
    try:
        out = subprocess.run(
            [tmux_bin, "display-message", "-t", session, "-p", "#{pane_pid}"],
            capture_output=True,
            text=True,
            check=False,
            env=_clean_probe_env(),
        )
    except OSError:
        return None
    if out.returncode != 0:
        return None
    text = out.stdout.strip()
    if not text:
        return None
    try:
        return int(text.split()[0])
    except (ValueError, IndexError):
        return None


def _pid_owner_uid(pid: int) -> int | None:
    """Return the OS owner UID of process *pid*, or None if unresolvable.

    Used by `_binding_session_is_live` for the #1738 r5 FIX C owner check.
    Linux: `os.stat("/proc/<pid>").st_uid` — the kernel's authoritative owner,
    not forgeable by the process. Otherwise (macOS / no /proc): the ABSOLUTE
    `/bin/ps -o uid= -p <pid>` under the FIX B clean env, so a preloaded
    interpose library cannot lie about the owner. Any failure / non-integer
    output returns None, which the caller treats as "owner unverifiable →
    not-live" (fail-closed).
    """
    if pid <= 0:
        return None
    proc_path = f"/proc/{pid}"
    if os.path.isdir(proc_path):  # noqa: raw-pathlib-controller-only
        try:
            return os.stat(proc_path).st_uid  # noqa: raw-pathlib-controller-only
        except OSError:
            return None
    for ps_bin in _PS_ABSOLUTE_CANDIDATES:
        if not os.path.exists(ps_bin):  # noqa: raw-pathlib-controller-only
            continue
        try:
            out = subprocess.run(
                [ps_bin, "-o", "uid=", "-p", str(pid)],
                capture_output=True,
                text=True,
                check=False,
                env=_clean_probe_env(),
            )
        except OSError:
            return None
        text = out.stdout.strip()
        if not text:
            return None
        try:
            return int(text.split()[0])
        except (ValueError, IndexError):
            return None
    return None


def _expected_pane_owner_uid(record: dict[str, Any]) -> int | None:
    """Expected OS owner UID of the bound pane process (#1738 r5 FIX C).

    The controller records `owner_uid` at publish time
    (`bridge_publish_config_caller_binding`) — the UID of the bound agent's OS
    user (on linux-user isolation, `agent-bridge-<agent>`; on shared-UID, the
    controller UID). The record lives in the controller-owned store, so on iso
    an attacking agent cannot forge `owner_uid` (it owns neither the dir nor the
    file). We require an explicit integer `owner_uid`.

    MISSING / malformed `owner_uid` (a legacy pre-r5 record, or a corrupt one)
    must FAIL CLOSED on iso (codex r5 BLOCKER): the only safe non-explicit value
    is the caller's own euid, and on iso the caller IS the attacker, so a
    geteuid() fallback would let an attacker park a PID THEY own on the recorded
    `pane_pid` slot and pass the owner check (their pid's owner == their euid).
    We therefore allow the geteuid() fallback ONLY when the bindings store is
    caller-WRITABLE — i.e. shared-UID, where the pane and caller are the same OS
    user anyway AND the admin-pane path is already operator-TTY-only via
    `_binding_store_is_caller_writable`. On a foreign-owned (iso) store with no
    explicit `owner_uid`, we return None → the binding is treated as NOT live
    (fail-closed). Iso records are (re)published WITH `owner_uid` by the daemon
    self-heal, so this denies only a transient legacy/corrupt record, never a
    healthy one.
    """
    owner_uid = record.get("owner_uid")
    if isinstance(owner_uid, bool):
        owner_uid = None
    if isinstance(owner_uid, int):
        return owner_uid
    if isinstance(owner_uid, str) and owner_uid.strip().lstrip("-").isdigit():
        try:
            return int(owner_uid.strip())
        except ValueError:
            pass
    # No explicit owner_uid: fall back to the caller's euid ONLY on a
    # caller-writable (shared-UID) store; fail closed on a foreign-owned (iso)
    # store where geteuid() would be the attacker's own UID.
    if not _binding_store_is_caller_writable(record):
        return None
    try:
        return os.geteuid()
    except AttributeError:  # pragma: no cover - non-POSIX
        return None


def _binding_session_is_live(record: dict[str, Any]) -> bool:
    """True iff the matched binding's pane is still the LIVE, admin-OWNED pane.

    Two checks, both must hold (#1738 r2 B2 liveness + r5 FIX C ownership):

    1. LIVENESS (r2 B2): the ancestry match alone authorizes purely on
       `pane_pid in ancestry`, which a non-admin agent can satisfy after the
       admin pane exits by PID-camping the freed `pane_pid` (iso shares the host
       PID space — no PID namespace). We re-resolve the live `#{pane_pid}` of the
       recorded tmux `session` and require it to equal the bound `pane_pid`.

    2. OWNERSHIP (r5 FIX C): even with the socket-strip + absolute-binary
       discipline, on iso the liveness probe derives tmux's default socket from
       the PROBE process's EUID — the attacker's own iso UID — so it queries a
       server the ATTACKER controls and could be fed a forged `#{pane_pid}` that
       matches the bound pane_pid (camp the pid, or have the private server
       report it). We close this at the kernel boundary: the live pane PID's
       process OWNER UID must equal the admin agent's expected OS UID
       (`owner_uid`, recorded by the controller). An attacker runs as a
       DIFFERENT OS user and physically cannot own a process as the admin UID,
       so a forged/camped pid owned by anyone but the admin is rejected. On
       shared-UID the expected owner is the caller's own UID (a trivial pass)
       and the admin-pane path is already fail-closed by the ownership gate.

    Any mismatch / dead session / unresolvable owner is stale → False (skip the
    binding, fail-closed).
    """
    session = str(record.get("session", "") or "").strip()
    pane_pid = record.get("pane_pid")
    if not isinstance(pane_pid, int) or isinstance(pane_pid, bool):
        return False
    live = _live_pane_pid_for_session(session)
    if live is None:
        return False
    if live != pane_pid:
        return False
    # r5 FIX C: the live pane PID must be OWNED by the admin's expected OS UID.
    expected_uid = _expected_pane_owner_uid(record)
    if expected_uid is None:
        return False
    actual_uid = _pid_owner_uid(live)
    if actual_uid is None or actual_uid != expected_uid:
        return False
    return True


def resolve_config_caller(args: argparse.Namespace) -> ConfigCaller:
    """Resolve the authoritative caller for a `set`/`set-env` mutation.

    Implements the #1738 decision table. The ONLY positive authorization
    inputs are (a) a binding record whose `pane_pid` is in this wrapper's
    process ancestry, or (b) a real operator TTY with `--from <canonical
    admin>` when NO binding matches. `BRIDGE_AGENT_ID` /
    `BRIDGE_ADMIN_AGENT_ID` / `BRIDGE_CALLER_SOURCE` never drive a positive
    decision.
    """
    admin = admin_agent_id()
    from_agent = getattr(args, "from_agent", None)
    from_agent = str(from_agent).strip() if from_agent else ""

    # Resolved once: a real interactive operator TTY explicitly passing
    # `--from <canonical admin>` is the only authorization that survives the
    # shared-UID fail-closed path below (and the no-binding fallback).
    try:
        is_tty = sys.stdin.isatty() and sys.stdout.isatty()
    except (OSError, ValueError):
        is_tty = False
    operator_tty_admin = bool(is_tty and from_agent and admin and from_agent == admin)

    def operator_tty_caller() -> ConfigCaller:
        return ConfigCaller(
            agent_id=from_agent,
            admin_agent_id=admin,
            source=CALLER_SOURCE_OPERATOR_TUI,
            context=CONFIG_CALLER_CONTEXT_OPERATOR_TTY,
            allowed=True,
            reason="operator-tty-from-admin",
        )

    ancestry = set(process_ancestry_pids(os.getpid()))
    matches = _bindings_matching_ancestry(ancestry)

    # #1738 r2 BLOCKER 2 (match-time liveness): a `pane_pid in ancestry` match is
    # not enough — after the bound pane exits, a different process can reuse the
    # freed pid (iso shares the host PID space) and ride the orphan binding. Drop
    # any matched binding whose recorded tmux session no longer resolves to the
    # bound pane_pid (dead session / pid-reuse / no tmux), so a stale binding can
    # never authorize. A binding that survives is genuinely the live pane's.
    matches = [m for m in matches if _binding_session_is_live(m)]

    if len(matches) > 1:
        return ConfigCaller(
            agent_id="",
            admin_agent_id=admin,
            source=CALLER_SOURCE_AGENT_DIRECT,
            context=CONFIG_CALLER_CONTEXT_AGENT_PANE,
            allowed=False,
            reason=(
                "agent-binding-ambiguous: multiple controller bindings match "
                "this process ancestry — stale or corrupt state, refusing"
            ),
        )

    if len(matches) == 1:
        record = matches[0]
        bound_agent = str(record.get("agent_id", "") or "").strip()
        bound_admin = str(record.get("admin_agent_id", "") or "").strip()
        # `--from` must agree with the bound identity — a mismatch is an
        # explicit identity spoof (env / flag claiming a different agent than
        # the one the pane is actually bound to).
        if from_agent and from_agent != bound_agent:
            return ConfigCaller(
                agent_id=bound_agent,
                admin_agent_id=bound_admin,
                source=CALLER_SOURCE_AGENT_DIRECT,
                context=CONFIG_CALLER_CONTEXT_AGENT_PANE,
                allowed=False,
                reason=(
                    f"identity-spoof: --from {from_agent} does not match the "
                    f"pane-bound agent {bound_agent}"
                ),
            )
        # Binding agent == binding admin → would be a legitimate admin-agent
        # call. The ancestry match is the proof of the launch-injected admin
        # identity (not BRIDGE_AGENT_ID) — BUT the binding record is unsigned, so
        # before we trust it we must rule out that THIS caller forged it.
        if bound_admin and bound_agent == bound_admin:
            # #1738 r3 BLOCKER 1 (fail-closed on a caller-OWNED store): on a
            # shared-UID install the agent owns the bindings store, so it can
            # write `<admin>.json` itself (and re-chmod it at will — the r2
            # `os.access(W_OK)` mode check was chmod-camouflage-bypassable), so
            # an ancestry-matched admin binding is forgeable → do NOT authorize
            # from it. The only thing that still authorizes here is a real
            # operator TTY with `--from` admin (an interactive operator, not an
            # agent shell); anything else is denied. On linux-user isolation the
            # controller owns the store under a DIFFERENT uid and the agent UID
            # owns neither → not forgeable → trust the binding (the real
            # boundary).
            if _binding_store_is_caller_writable(record):
                if operator_tty_admin:
                    return operator_tty_caller()
                return ConfigCaller(
                    agent_id=bound_agent,
                    admin_agent_id=bound_admin,
                    source=CALLER_SOURCE_AGENT_DIRECT,
                    context=CONFIG_CALLER_CONTEXT_AGENT_PANE,
                    allowed=False,
                    reason=(
                        "agent-binding-store-writable: the config-caller "
                        "bindings store is owned by this UID (shared-UID) — the "
                        "owner can forge/re-chmod an agent-pane admin binding, so "
                        "it is not trusted here. On a headless shared-UID host "
                        "there is no operator TTY: run this mutation from an "
                        "attended operator session (--from <admin> on a real "
                        "TTY), or migrate this admin to linux-user isolation "
                        "(iso-v2) for unattended headless config — the "
                        "controller/agent UID boundary then makes the binding "
                        "non-forgeable and authorizes it TTY-free. See "
                        'OPERATIONS.md "Iso v2 agent troubleshooting" (#1946).'
                    ),
                )
            return ConfigCaller(
                agent_id=bound_agent,
                admin_agent_id=bound_admin,
                source=CALLER_SOURCE_OPERATOR_TRUSTED_ID,
                context=CONFIG_CALLER_CONTEXT_AGENT_PANE,
                allowed=True,
                reason="agent-pane-binding",
            )
        # Binding matches a NON-admin agent → deny, regardless of what env or
        # `--from` claims.
        return ConfigCaller(
            agent_id=bound_agent,
            admin_agent_id=bound_admin,
            source=CALLER_SOURCE_AGENT_DIRECT,
            context=CONFIG_CALLER_CONTEXT_AGENT_PANE,
            allowed=False,
            reason=(
                f"agent-direct: pane-bound agent {bound_agent or '<unknown>'} "
                "is not the admin agent — refusing system-config mutation"
            ),
        )

    # No (live, non-forgeable) binding matched this process ancestry.
    if operator_tty_admin:
        # Raw-operator fallback: a real interactive TTY explicitly passing
        # `--from <canonical admin>`, with NO matching agent binding. This is
        # the only allowed path when ancestry yields nothing.
        return operator_tty_caller()

    # Everything else with no binding is fail-closed. Crucially this includes
    # the historical env-trust path (ambient BRIDGE_AGENT_ID / CALLER_SOURCE in
    # a non-TTY context): it no longer authorizes anything.
    if from_agent and admin and from_agent == admin:
        reason = (
            "noninteractive-untrusted: no pane binding matches this process "
            "and there is no operator TTY — env/--from-declared admin identity "
            "is not trusted for a config mutation (issue #1738)"
        )
    else:
        reason = (
            "agent-binding-missing: no controller pane binding matches this "
            "process ancestry and no operator-TTY admin fallback applies"
        )
    return ConfigCaller(
        agent_id=from_agent,
        admin_agent_id=admin,
        source=CALLER_SOURCE_AGENT_DIRECT,
        context=CONFIG_CALLER_CONTEXT_UNKNOWN,
        allowed=False,
        reason=reason,
    )


def write_audit(detail: dict[str, Any]) -> Path:
    """Write a `system_config_mutation` row to the bridge audit log.

    Uses bridge-audit.py write to keep the hash chain intact — the
    wrapper's rows hash-link with hook rows so an operator can verify
    the audit log end-to-end.
    """
    log_path = audit_log_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    detail_json = json.dumps(detail, ensure_ascii=True, sort_keys=True)
    cmd = [
        sys.executable,
        str(ROOT / "bridge-audit.py"),
        "write",
        "--file",
        str(log_path),
        "--actor",
        "wrapper",
        "--action",
        "system_config_mutation",
        "--target",
        detail.get("path", "") or "",
        "--detail-json",
        detail_json,
    ]
    try:
        subprocess.run(cmd, check=False, capture_output=True)
    except OSError:
        # Fallback: append the raw record directly so a missing python
        # interpreter does not silently swallow the audit row. Best-effort.
        record = {
            "ts": now_iso(),
            "actor": "wrapper",
            "action": "system_config_mutation",
            "target": detail.get("path", ""),
            "detail": detail,
            "pid": os.getpid(),
            "host": socket.gethostname(),
        }
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=True) + "\n")
    return log_path


def audit_log_path() -> Path:
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_home_dir() / "logs" / "audit.jsonl"


def file_sha256(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        with path.open("rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return ""


def parse_change_expr(expr: str) -> tuple[list[str], str, str]:
    """Split a change expression into (key path, operator, value).

    The operator is one of `set` / `append` / `remove`. The brief lists
    `<key=val|json-patch>` as syntax — we deliberately implement only the
    bounded set that's enough for the four test scenarios. JSON patch is
    out of scope for the v1 wrapper; an operator who needs full patch
    semantics can run multiple set calls or extend this parser later.
    """
    if "=" not in expr:
        raise SystemExit(f"--change must be 'key=value': {expr}")
    raw_key, value = expr.split("=", 1)
    raw_key = raw_key.strip()
    if not raw_key:
        raise SystemExit(f"--change key is empty: {expr}")
    parts = raw_key.split(".")
    if parts[-1] in {"append", "remove"}:
        op = parts[-1]
        keys = parts[:-1]
    else:
        op = "set"
        keys = parts
    if not keys:
        raise SystemExit(f"--change key path is empty: {expr}")
    return keys, op, value


def apply_change_to_json(payload: Any, keys: list[str], op: str, value: str) -> Any:
    if not isinstance(payload, dict):
        raise SystemExit("config root must be a JSON object")
    cursor: dict[str, Any] = payload
    for key in keys[:-1]:
        next_value = cursor.get(key)
        if not isinstance(next_value, dict):
            next_value = {}
            cursor[key] = next_value
        cursor = next_value
    last_key = keys[-1]
    if op == "set":
        cursor[last_key] = _coerce_value(value)
    elif op == "append":
        existing = cursor.get(last_key)
        if existing is None:
            existing = []
        if not isinstance(existing, list):
            raise SystemExit(f"cannot append: {'.'.join(keys)} is not a list")
        existing.append(_coerce_value(value))
        cursor[last_key] = existing
    elif op == "remove":
        existing = cursor.get(last_key)
        if not isinstance(existing, list):
            raise SystemExit(f"cannot remove: {'.'.join(keys)} is not a list")
        coerced = _coerce_value(value)
        # Match either the coerced form or the literal string so the
        # operator does not have to know whether the list stores ints
        # or strings.
        for candidate in (coerced, value):
            if candidate in existing:
                existing.remove(candidate)
                break
        cursor[last_key] = existing
    else:
        raise SystemExit(f"unsupported change op: {op}")
    return payload


def _coerce_value(value: str) -> Any:
    """Best-effort scalar coercion: try JSON literal first, fall back to str.

    `groups.append=1476851882533191681` is the obvious case — we want
    the int form to land in JSON, not the quoted string.
    """
    stripped = value.strip()
    if not stripped:
        return value
    try:
        return json.loads(stripped)
    except (ValueError, TypeError):
        return value


def agent_env_local_path() -> Path:
    """Resolve the managed install-env-override file `set-env` writes.

    `BRIDGE_AGENT_ENV_LOCAL_FILE` (exported by bridge-lib.sh) is the
    canonical location; default `$BRIDGE_HOME/agent-env.local.sh`. Kept in
    lock-step with the shell-side default so the writer and the
    `bridge_load_roster` reader agree on one path.
    """
    explicit = os.environ.get("BRIDGE_AGENT_ENV_LOCAL_FILE", "").strip()  # noqa: iso-helper-boundary
    if explicit:
        return Path(explicit).expanduser()
    return bridge_home_dir() / "agent-env.local.sh"


def env_key_deny_reason(key: str) -> str | None:
    """Return a deny reason if *key* is forbidden, else None.

    Evaluated BEFORE the allowlist so a forbidden key that somehow also
    appears in the allowlist is still denied (fail-closed). Order:
      1. shape (`[A-Z][A-Z0-9_]*`)
      2. exact-name deny list
      3. prefix deny list (BRIDGE_ROSTER*, BRIDGE_AGENT_*)
      4. substring deny (TOKEN / SECRET / KEY, case-insensitive)
    """
    if not _ENV_KEY_RE.match(key):
        return (
            f"invalid env key '{key}': must match [A-Z][A-Z0-9_]* "
            "(upper-snake BRIDGE_* names only)"
        )
    if key in ENV_KEY_DENY_EXACT:
        return f"env key '{key}' is explicitly forbidden (root/identity/control/test-bypass)"
    for prefix in ENV_KEY_DENY_PREFIXES:
        if key.startswith(prefix):
            return f"env key '{key}' is forbidden (matches reserved prefix '{prefix}')"
    upper = key.upper()
    for needle in ENV_KEY_DENY_SUBSTRINGS:
        if needle in upper:
            return f"env key '{key}' is forbidden (secret-bearing name contains '{needle}')"
    return None


def validate_env_value(key: str, raw: str) -> tuple[str | None, str | None]:
    """Type-check *raw* against the allowlisted *key*'s expected type.

    Returns ``(canonical_value, None)`` on success or ``(None, reason)`` on
    failure. The canonical value is the re-rendered string form (e.g. an int
    knob normalizes ``"086400"`` → ``"86400"``) so a smuggled non-numeric
    payload cannot survive into the managed file. A value carrying a NUL or
    any shell metacharacter / control char is rejected outright BEFORE typing
    (the typed knobs are numeric, so this is defense-in-depth against a
    value that types as a number but also embeds a shell control sequence —
    e.g. there is none, but the screen keeps the contract explicit for a
    future string-typed knob).
    """
    if "\0" in raw:
        return None, "value contains a NUL byte"
    # No newlines / carriage returns — the managed file is one `export` per
    # line; a value with an embedded newline could forge a second line.
    if "\n" in raw or "\r" in raw:
        return None, "value contains a newline / carriage return"
    # Reject any ASCII control char (other than the already-checked NUL).
    if any(ord(ch) < 0x20 for ch in raw):
        return None, "value contains a control character"
    expected = ENV_KEY_ALLOWLIST.get(key)
    if expected is None:  # pragma: no cover — caller checks allowlist first
        return None, f"env key '{key}' is not in the set-env allowlist"
    text = raw.strip()
    if expected in (
        ENV_KEY_TYPE_POS_INT,
        ENV_KEY_TYPE_INT_MIN2,
        ENV_KEY_TYPE_NON_NEG_INT,
    ):
        try:
            val = int(text)
        except (TypeError, ValueError):
            return None, f"value for {key} must be an integer, got {raw!r}"
        if expected == ENV_KEY_TYPE_INT_MIN2:
            floor = 2
        elif expected == ENV_KEY_TYPE_NON_NEG_INT:
            floor = 0
        else:
            floor = 1
        if val < floor:
            return None, f"value for {key} must be >= {floor}, got {val}"
        return str(val), None
    if expected == ENV_KEY_TYPE_FLAG_ONE:
        # The only durable value is the literal "1" (the consuming code uses
        # strict `!= "1"` equality). Reject everything else — "0"/"true"/"yes"
        # would be silently treated as OFF by the gate, so accepting them here
        # would be a confusing no-op. To disable, remove the key + restart.
        if text == "1":
            return "1", None
        return None, (
            f"value for {key} must be the literal \"1\" (the feature gate is "
            f"strict; remove the key + restart to disable), got {raw!r}"
        )
    if expected == ENV_KEY_TYPE_POS_FLOAT:
        try:
            val_f = float(text)
        except (TypeError, ValueError):
            return None, f"value for {key} must be a number, got {raw!r}"
        # Reject NaN / inf — `float("nan")`/`float("inf")` parse but are not
        # sane timeouts.
        if val_f != val_f or val_f in (float("inf"), float("-inf")):
            return None, f"value for {key} must be finite, got {raw!r}"
        if val_f <= 0.0:
            return None, f"value for {key} must be > 0, got {val_f}"
        # Canonical form: repr keeps `1.5` as `1.5` and `2` as `2.0`.
        return repr(val_f), None
    return None, f"unsupported value type for {key}"  # pragma: no cover


def parse_set_env_arg(arg: str) -> tuple[str, str]:
    """Split a `KEY=VALUE` positional into (key, value).

    Only the FIRST ``=`` splits — a value may itself contain ``=`` (none of
    the numeric knobs do, but the parser stays general). A missing ``=`` or
    empty key is a usage error.
    """
    if "=" not in arg:
        raise SystemExit(f"set-env argument must be KEY=VALUE: {arg!r}")
    key, value = arg.split("=", 1)
    key = key.strip()
    if not key:
        raise SystemExit(f"set-env key is empty: {arg!r}")
    return key, value


def render_env_export_line(key: str, value: str) -> str:
    """Render one shell-safe `export KEY='value'` line (single line, no eval).

    Single-quote the value and escape any embedded single quote with the
    canonical ``'\\''`` shell idiom so the rendered line is byte-exact for any
    value POSIX sh / bash would accept. The typed numeric values never contain
    a quote, but the renderer is correct for an arbitrary (control-char-free)
    string so a future string-typed knob is safe by construction.
    """
    escaped = value.replace("'", "'\\''")
    return f"export {key}='{escaped}'"


# Sentinel header for the managed file. The file is fully machine-owned: the
# writer rewrites it from the in-memory key→value map on every apply, so the
# header is informational only (operators should use `set-env`, not hand-edit
# — and the #341 gate enforces that).
_AGENT_ENV_HEADER = (
    "# Managed by `agent-bridge config set-env` (issue #1734). DO NOT EDIT BY HAND.\n"
    "# Direct edits are blocked by the #341 write-gate; use\n"
    "#   agent-bridge config set-env KEY=VALUE\n"
    "# Sourced by bridge_load_roster AFTER agent-roster.local.sh.\n"
)


def read_managed_env(path: Path) -> dict[str, str]:
    """Parse the managed env file into an ordered key→value map.

    Tolerant reader: only lines of the exact shape ``export KEY='...'`` (the
    shape the writer emits) are parsed; comments / blanks / anything else are
    ignored. A malformed managed file therefore degrades to "keys we can
    re-recognise" rather than raising — and because the writer rewrites the
    WHOLE file from the validated map on every apply, an unrecognised line is
    dropped on the next write (self-healing). Unknown keys (no longer in the
    allowlist) are preserved on read so a single set-env does not silently
    drop a sibling override an operator set earlier, but a key on the deny
    list is dropped defensively.
    """
    result: dict[str, str] = {}
    if not path.exists():  # noqa: raw-pathlib-controller-only
        return result
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return result
    line_re = re.compile(r"^export ([A-Z][A-Z0-9_]*)='(.*)'$")
    for line in text.splitlines():
        m = line_re.match(line.strip())
        if not m:
            continue
        key, raw = m.group(1), m.group(2)
        # Reverse the single-quote escaping the writer applied.
        value = raw.replace("'\\''", "'")
        # Drop any key that is now forbidden (defensive — a deny-listed key
        # must never round-trip even if it was somehow written earlier).
        if env_key_deny_reason(key) is not None:
            continue
        result[key] = value
    return result


def write_managed_env(path: Path, entries: dict[str, str]) -> None:
    """Atomically rewrite the managed env file from *entries*.

    Renders the header + one `export KEY='value'` line per entry (sorted for
    a stable diff), writes to a temp file in the same dir, fsync-free
    `os.replace`. Mode is 0600 on create (it can carry operator-tuned
    operational values; keep it owner-only like the roster).
    """
    path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only
    body = _AGENT_ENV_HEADER
    for key in sorted(entries):
        body += render_env_export_line(key, entries[key]) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        if path.exists():  # noqa: raw-pathlib-controller-only
            shutil.copymode(path, tmp_name)
        else:
            os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)  # noqa: raw-pathlib-controller-only
        except OSError:
            pass
        raise


def atomic_write(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        # Preserve mode if the original existed; default to 0600 otherwise
        # so secrets-bearing config files (access.json) do not loosen.
        if path.exists():
            shutil.copymode(path, tmp_name)
        else:
            os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def cmd_list_protected(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps(list(PROTECTED_GLOBS), ensure_ascii=True, indent=2))
        return 0
    print(f"BRIDGE_HOME: {bridge_home_dir()}")
    print("protected globs (relative to BRIDGE_HOME):")
    for pattern in PROTECTED_GLOBS:
        print(f"  {pattern}")
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser()
    if not is_protected_path(path):
        print(
            f"refusing: {path} is not in the system-config protected list",
            file=sys.stderr,
        )
        return 2
    if not path.exists():
        print(f"missing: {path}", file=sys.stderr)
        return 1
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"read failed: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser()
    # Issue #1738: derive the caller from the unspoofable controller pane-pid
    # binding + process ancestry, NOT from env identity. `resolve_config_caller`
    # implements the full decision table; env (BRIDGE_AGENT_ID /
    # BRIDGE_ADMIN_AGENT_ID / BRIDGE_CALLER_SOURCE) never drives a positive
    # authorization.
    caller = resolve_config_caller(args)
    caller_agent = caller.agent_id
    caller_source = caller.source

    deny_reason: str | None = None
    if not is_protected_path(path):
        deny_reason = "path not in system-config protected list"
    elif not caller.allowed:
        deny_reason = caller.reason

    actor_label = caller_agent or (
        "operator" if caller_source == CALLER_SOURCE_OPERATOR_TUI else "unknown"
    )
    if deny_reason is not None:
        # `after_sha256` is intentionally omitted on wrapper-deny — the
        # change was prevented, so there is no "after" state (codex r1
        # #341 CP3). The wrapper-apply row below is the only place
        # `after_sha256` is meaningful.
        write_audit(
            {
                "kind": "system_config_mutation",
                "actor": actor_label,
                "actor_source": caller_source,
                "trigger": "wrapper-deny",
                "path": str(path),
                "before_sha256": file_sha256(path),
                "operation": args.change,
                "matched_pattern": matched_pattern(path) or "",
                "reason": deny_reason,
            }
        )
        print(f"deny: {deny_reason}", file=sys.stderr)
        return 3

    # Limit to JSON files. Roster (`agent-roster.local.sh`) is a shell
    # file; mutating it through this wrapper would require shell-aware
    # editing that is well out of scope for v1. We still record a
    # `wrapper-deny` row (without `after_sha256`, codex r1 #341 CP3) so
    # the operator sees the attempt.
    if path.suffix != ".json":
        write_audit(
            {
                "kind": "system_config_mutation",
                "actor": actor_label,
                "actor_source": caller_source,
                "trigger": "wrapper-deny",
                "path": str(path),
                "before_sha256": file_sha256(path),
                "operation": args.change,
                "matched_pattern": matched_pattern(path) or "",
                "reason": "non-JSON system config files are not yet wrapper-mutable",
            }
        )
        print(
            f"deny: {path.suffix} files are not yet wrapper-mutable — "
            "edit at the operator-TUI manually and re-run `agent-bridge config get` to verify",
            file=sys.stderr,
        )
        return 4

    keys, op, value = parse_change_expr(args.change)

    before_sha = file_sha256(path)
    payload: Any
    if path.exists():
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"read failed: {exc}", file=sys.stderr)
            return 1
    else:
        payload = {}

    payload = apply_change_to_json(payload, keys, op, value)
    atomic_write(path, payload)
    after_sha = file_sha256(path)

    write_audit(
        {
            "kind": "system_config_mutation",
            "actor": actor_label,
            "actor_source": caller_source,
            "trigger": "wrapper-apply",
            "path": str(path),
            "before_sha256": before_sha,
            "after_sha256": after_sha,
            "operation": args.change,
            "matched_pattern": matched_pattern(path) or "",
        }
    )
    print(f"applied: {path} ({op} {'.'.join(keys)})")
    return 0


def _emit_set_env_audit(
    *,
    trigger: str,
    actor_label: str,
    caller_source: str,
    path: Path,
    key: str,
    before_sha: str,
    after_sha: str | None,
    reason: str | None,
) -> None:
    """Emit a `system_config_mutation` audit row for a set-env apply/deny.

    Mirrors the `cmd_set` audit shape: `before_sha256` always, `after_sha256`
    only on apply (a deny prevented any change, so there is no "after"
    state). `operation` carries the key (NOT the value — the value lands in
    the protected file, the audit row keeps the forensic anchor without
    persisting the operator's chosen number, consistent with the hash-only
    discipline elsewhere).
    """
    detail: dict[str, Any] = {
        "kind": "system_config_mutation",
        "actor": actor_label,
        "actor_source": caller_source,
        "trigger": trigger,
        "path": str(path),
        "before_sha256": before_sha,
        "operation": f"set-env {key}",
        "matched_pattern": matched_pattern(path) or "",
    }
    if after_sha is not None:
        detail["after_sha256"] = after_sha
    if reason is not None:
        detail["reason"] = reason
    write_audit(detail)


def cmd_set_env(args: argparse.Namespace) -> int:
    """Set a durable, allowlisted install env override (issue #1734).

    Writes/replaces a single `export KEY='value'` entry in the managed
    `agent-env.local.sh` through the same trust gate as `config set`
    (admin identity + operator-tui / operator-trusted-id). The KEY must be on
    the NARROW non-secret allowlist and pass the explicit deny screen; the
    value is type-checked per key. Every apply and every deny emits a
    `system_config_mutation` audit row with before/after file hashes.
    """
    path = agent_env_local_path()
    # Issue #1738: same unspoofable resolver as cmd_set. The set-env write gate
    # no longer trusts env-declared identity/source.
    caller = resolve_config_caller(args)
    caller_agent = caller.agent_id
    caller_source = caller.source
    actor_label = caller_agent or (
        "operator" if caller_source == CALLER_SOURCE_OPERATOR_TUI else "unknown"
    )

    try:
        key, raw_value = parse_set_env_arg(args.assignment)
    except SystemExit as exc:
        # Surface usage errors without an audit row (no key resolved yet).
        print(f"deny: {exc}", file=sys.stderr)
        return 2

    before_sha = file_sha256(path)

    def deny(reason: str, code: int) -> int:
        _emit_set_env_audit(
            trigger="set-env-deny",
            actor_label=actor_label,
            caller_source=caller_source,
            path=path,
            key=key,
            before_sha=before_sha,
            after_sha=None,
            reason=reason,
        )
        print(f"deny: {reason}", file=sys.stderr)
        return code

    # Trust gate FIRST (issue #1738): the resolver's decision is the boundary.
    # A non-admin pane binding, an identity spoof, a stale/ambiguous binding, or
    # a noninteractive caller with no binding is denied before we consider the
    # key.
    if not caller.allowed:
        return deny(caller.reason, 3)

    # Key screen: explicit deny BEFORE allowlist (fail-closed), then allowlist.
    forbidden = env_key_deny_reason(key)
    if forbidden is not None:
        return deny(forbidden, 4)
    if key not in ENV_KEY_ALLOWLIST:
        return deny(
            f"env key '{key}' is not in the set-env allowlist "
            "(only narrow non-secret operational knobs are settable)",
            4,
        )

    # Value typing / screen.
    canonical, value_reason = validate_env_value(key, raw_value)
    if canonical is None:
        return deny(value_reason or f"invalid value for {key}", 5)

    # Apply: load the current managed map, replace the single key, rewrite.
    entries = read_managed_env(path)
    entries[key] = canonical
    write_managed_env(path, entries)
    after_sha = file_sha256(path)

    _emit_set_env_audit(
        trigger="set-env-apply",
        actor_label=actor_label,
        caller_source=caller_source,
        path=path,
        key=key,
        before_sha=before_sha,
        after_sha=after_sha,
        reason=None,
    )
    print(f"applied: {path} (export {key})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="agent-bridge config — gated system-config mutations (issue #341)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    set_parser = sub.add_parser("set", help="apply a change to a protected path")
    set_parser.add_argument("--path", required=True)
    set_parser.add_argument(
        "--change",
        required=True,
        help="change expression: key=value | a.b=value | a.b.append=value | a.b.remove=value",
    )
    set_parser.add_argument(
        "--from",
        dest="from_agent",
        help=(
            "caller agent id; required when BRIDGE_AGENT_ID is unset. "
            "Operator workflows from a raw shell must pass --from <admin-agent> "
            "explicitly — anonymous callers cannot satisfy the admin check "
            "(codex r1 #341 CP5)."
        ),
    )
    set_parser.set_defaults(handler=cmd_set)

    set_env_parser = sub.add_parser(
        "set-env",
        help="set a durable, allowlisted install env override (issue #1734)",
    )
    set_env_parser.add_argument(
        "assignment",
        metavar="KEY=VALUE",
        help=(
            "env override to set, e.g. "
            "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS=86400. KEY must be on "
            "the narrow non-secret allowlist; VALUE is type-checked per key."
        ),
    )
    set_env_parser.add_argument(
        "--from",
        dest="from_agent",
        help=(
            "caller agent id; required when BRIDGE_AGENT_ID is unset. "
            "Operator workflows from a raw shell must pass --from <admin-agent> "
            "explicitly — anonymous callers cannot satisfy the admin check."
        ),
    )
    set_env_parser.set_defaults(handler=cmd_set_env)

    get_parser = sub.add_parser("get", help="read a protected path")
    get_parser.add_argument("--path", required=True)
    get_parser.set_defaults(handler=cmd_get)

    list_parser = sub.add_parser("list-protected", help="print the protected glob list")
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(handler=cmd_list_protected)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
