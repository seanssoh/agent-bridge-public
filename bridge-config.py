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

Trust model recap (from the issue's "신뢰 경계 정의" table):

    operator-tui          interactive shell (stdin+stdout are TTYs)
    operator-trusted-id   set explicitly by a verified channel handler
                          via BRIDGE_CALLER_SOURCE env
    agent-direct          everything else — denied

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


CALLER_SOURCE_OPERATOR_TUI = "operator-tui"
CALLER_SOURCE_OPERATOR_TRUSTED_ID = "operator-trusted-id"
CALLER_SOURCE_AGENT_DIRECT = "agent-direct"

# Caller sources allowed to mutate. The operator can extend this set via
# the env var below at deploy time, but the default set is deliberately
# narrow — issue #341 §"권한 모델이 코드에 없고 가이드 텍스트에만 있음" is
# the failure mode we are correcting.
ALLOWED_CALLER_SOURCES = frozenset(
    {CALLER_SOURCE_OPERATOR_TUI, CALLER_SOURCE_OPERATOR_TRUSTED_ID}
)


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
ENV_KEY_ALLOWLIST: dict[str, str] = {
    "BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECONCILE_INTERVAL": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_PEER_SUSPECT_THRESHOLD": ENV_KEY_TYPE_INT_MIN2,
    "BRIDGE_A2A_PEER_PROBE_TIMEOUT_SECONDS": ENV_KEY_TYPE_POS_FLOAT,
    "BRIDGE_A2A_BACKOFF_CEILING_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_MAX_RESTARTS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS": ENV_KEY_TYPE_POS_INT,
    "BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS": ENV_KEY_TYPE_POS_INT,
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


def detect_caller_source() -> str:
    """Resolve which trust bucket the current process belongs to.

    `BRIDGE_CALLER_SOURCE` is the explicit override a verified channel
    handler uses to declare it has already validated the operator's
    user_id against the canonical roster (issue #341 §B). When unset,
    we fall back to TTY detection: an interactive shell invoking
    `agent-bridge config set` is treated as operator-tui. Any
    non-interactive non-overridden caller is `agent-direct` and the
    wrapper denies the mutation.
    """
    explicit = os.environ.get("BRIDGE_CALLER_SOURCE", "").strip().lower()
    if explicit in {CALLER_SOURCE_OPERATOR_TUI, CALLER_SOURCE_OPERATOR_TRUSTED_ID}:
        return explicit
    if explicit:
        return CALLER_SOURCE_AGENT_DIRECT
    try:
        if sys.stdin.isatty() and sys.stdout.isatty():
            return CALLER_SOURCE_OPERATOR_TUI
    except (OSError, ValueError):
        pass
    return CALLER_SOURCE_AGENT_DIRECT


def admin_agent_id() -> str:
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


def caller_agent_id(args: argparse.Namespace) -> str:
    explicit = getattr(args, "from_agent", None)
    if explicit:
        return str(explicit).strip()
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


def caller_is_admin(agent: str) -> bool:
    """Return True only when the caller has explicitly identified as the
    admin agent.

    Strict identity check (codex r1 #341 CP5): the caller must pass
    ``--from <admin>`` *or* run with ``BRIDGE_AGENT_ID=<admin>`` set.
    A missing caller agent is rejected even from operator-TUI — the
    wrapper does not accept "operator at a TTY" as an implicit admin
    bypass. Bridge-managed TUI sessions already export
    ``BRIDGE_AGENT_ID``; operators running from a raw shell must pass
    ``--from`` explicitly.

    The check is intentionally stricter than the hook's
    ``is_admin_agent`` — the hook gates by session-type files that an
    agent could in theory plant; the wrapper requires an env- or
    flag-declared admin id and refuses anonymous callers.
    """
    admin = admin_agent_id()
    if not admin:
        return False
    if not agent:
        return False
    return agent == admin


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
    if expected in (ENV_KEY_TYPE_POS_INT, ENV_KEY_TYPE_INT_MIN2):
        try:
            val = int(text)
        except (TypeError, ValueError):
            return None, f"value for {key} must be an integer, got {raw!r}"
        floor = 2 if expected == ENV_KEY_TYPE_INT_MIN2 else 1
        if val < floor:
            return None, f"value for {key} must be >= {floor}, got {val}"
        return str(val), None
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
    if not path.exists():
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
    path.parent.mkdir(parents=True, exist_ok=True)
    body = _AGENT_ENV_HEADER
    for key in sorted(entries):
        body += render_env_export_line(key, entries[key]) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
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
    caller_agent = caller_agent_id(args)
    caller_source = detect_caller_source()

    deny_reason: str | None = None
    if not is_protected_path(path):
        deny_reason = "path not in system-config protected list"
    elif not caller_agent:
        # Strict admin check (codex r1 #341 CP5): the caller must
        # explicitly identify via --from or BRIDGE_AGENT_ID. Anonymous
        # callers (raw shell with neither set) cannot satisfy the
        # admin requirement, even from operator-TUI.
        deny_reason = (
            "caller_agent unspecified — pass `--from <admin-agent>` or set "
            "BRIDGE_AGENT_ID before invoking `agent-bridge config set`"
        )
    elif not caller_is_admin(caller_agent):
        deny_reason = (
            f"caller agent {caller_agent} is not the admin "
            "agent — refusing system-config mutation"
        )
    elif caller_source not in ALLOWED_CALLER_SOURCES:
        deny_reason = (
            f"caller source {caller_source} is not allowed to mutate "
            "system config (need operator-tui or operator-trusted-id)"
        )

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
    caller_agent = caller_agent_id(args)
    caller_source = detect_caller_source()
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

    # Trust gate FIRST — identical shape to cmd_set (codex r1 #341 CP5):
    # explicit admin identity AND an operator caller-source. A non-admin or
    # non-operator-TTY caller is denied before we even consider the key.
    if not caller_agent:
        return deny(
            "caller_agent unspecified — pass `--from <admin-agent>` or set "
            "BRIDGE_AGENT_ID before invoking `agent-bridge config set-env`",
            3,
        )
    if not caller_is_admin(caller_agent):
        return deny(
            f"caller agent {caller_agent} is not the admin agent — refusing "
            "set-env",
            3,
        )
    if caller_source not in ALLOWED_CALLER_SOURCES:
        return deny(
            f"caller source {caller_source} is not allowed to set env "
            "(need operator-tui or operator-trusted-id)",
            3,
        )

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
