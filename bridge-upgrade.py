#!/usr/bin/env python3
"""Helpers for smart Agent Bridge upgrade flows."""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import uuid
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from stat import S_ISDIR, S_ISFIFO, S_ISLNK, S_ISREG, S_ISSOCK
import tempfile
from typing import Any, Iterator

MANAGED_CLAUDE_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_CLAUDE_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"


def _managed_start_pattern(start_marker: str) -> str:
    """Stamp-tolerant regex for a managed-block BEGIN marker (#1816 / #2062).

    Since #2062 the renderer (`bridge-docs.py`) emits the BEGIN marker as a
    STABLE LITERAL — the version stamp lives on a separate in-block metadata
    line, not on the marker — so a plain literal match would already suffice for
    blocks this engine renders. This regex is retained as DEFENSIVE TOLERANCE:
    it accepts BOTH the literal marker AND a transitional block that an interim
    build may have stamped on the marker (` v=<version>` before ` -->`), so the
    migrate-agents home managed-block refresh recognizes such a block instead of
    silently leaving it un-refreshed. Mirrors `MANAGED_START_RE` in
    bridge-docs.py: match the stable prefix
    `<!-- BEGIN AGENT BRIDGE DOC MIGRATION`, an optional ` v=<stamp>`, then
    ` -->`. Falls back to the literal escape for any marker that does not carry
    the DOC-MIGRATION shape (e.g. the #517 pair block).
    """
    suffix = " -->"
    if start_marker.endswith(suffix):
        prefix = start_marker[: -len(suffix)]
        return re.escape(prefix) + r"(?: v=[^\n>]*)?" + re.escape(suffix)
    return re.escape(start_marker)

# Issue #517: admin-only pair-programming SOP block. Generalized
# extract/refresh helpers below take delimiter args so the same logic
# rerenders both blocks idempotently.

# Issue #1817: the repo-root `CLAUDE.md` is the ~24 KB *contributor contract*
# (release rules, codex pair-review workflow, iso-v2 boundary tables). On
# layout v2 every agent workdir is a descendant of `BRIDGE_HOME`, so Claude
# Code's ancestor `CLAUDE.md` loading injects that whole contract into every
# agent session — including comms/ops agents that never edit source. The file
# even says so itself ("If you are an operator ... this is the wrong file").
# So the upgrader (a) skips the tracked root `CLAUDE.md` in the deploy
# classifier and (b) substitutes a thin operator-facing stub at the live root
# whenever the live file is still the *unmodified* bridge-managed contract.
#
# The #1 invariant is "never clobber an operator-customized CLAUDE.md". A loose
# marker/heading match would fail it: an operator who took the deployed contract
# and appended local notes still carries the markers but must be preserved. So
# detection is EXACT-MATCH on content hash — only bytes that the bridge has
# itself shipped to a live root count as "the managed contract". Any operator
# edit (even one byte) changes the hash and is preserved.
LIVE_ROOT_CLAUDE_MARKER = "<!-- agent-bridge: live-root operator stub (#1817) -->"
# Frozen allowlist of sha256 of every distinct repo-root `CLAUDE.md` content the
# bridge has shipped (one per distinct version of the tracked contributor
# contract across the v0.1x release tags). The current-source contract hash is
# added dynamically at call time (see `_managed_contract_sha256_set`) so a
# freshly-cut contract version is recognized without editing this list. Exact
# bytes only — an operator-edited copy never matches.
KNOWN_CONTRACT_SHA256 = frozenset(
    {
        # v0.14.5-beta27 .. v0.15.0-beta3 (14,329 B)
        "7acf7dd6989abc2581fe0bc8f43c5087af2dd01e1f9c92b00371be0c4a71cc8b",
        # v0.15.0-beta4 .. beta5-2 (17,075 B)
        "d23fde873a132d38f74f387ecb17c5f079a82a9d52b3a1e2527b0d1fbcdaf3cb",
        # v0.15.0-beta5-3 .. v0.15.1 (21,365 B)
        "e7e6c4a5e208f8a419df3888d42f67aa11beedcf4b882afa022d4b886ba0afcd",
        # v0.15.2 .. v0.16.3 (22,300 B)
        "b2c54809fbfbfba9173ed8446ce23c589b628f49cfc3bd197ed47c4abf4e3b80",
        # v0.16.4 (24,287 B)
        "35a019ba867c0621e72bc022efcb728b3a47dbe9496d7c439460bb1b8e5479d4",
        # v0.16.5 .. v0.16.11 (24,495 B — the field 24,495-byte file in #1817)
        "7938251cdc06c35a96ce37934bdd97b784063615ba2a101f33a438fe7a8ae861",
        # Earlier distinct contract revisions observed in the v0.1x tag history.
        "11608b008b6d750c5bb88cbca58c7759589ecd60efaca8cbe36ad2ac12ad453f",
        "2f6c0663cb656e0df4e3b18f12894779107f0c6f09482e0c4331094c70c158f7",
        "52f5c1ce5de1db43d0b2039d731ab1173eb0de57542cf1e00c2914398bfab789",
        "b088ea7c778aff4e4c5d134b2cebcba0b13cecc682121c2d51160cf2b88ca60b",
        "fc90ba800217a73d9aa5f6c03eab9f0cb275c1a9bf36ede314df4deeeb9d0dc9",
    }
)
LIVE_ROOT_OPERATOR_STUB = """\
# CLAUDE.md (live runtime root)

{marker}

This is the Agent Bridge **live runtime root** (`$BRIDGE_HOME`), not the source
checkout. Agent sessions ancestor-load this file, so it is deliberately thin —
the per-agent contract lives in each agent home's own `CLAUDE.md` /
`COMMON-INSTRUCTIONS.md`, and the repo *contributor* contract lives only in the
source checkout.

- **Operators / agents at first wake**: read your agent home's `SOUL.md`,
  `CLAUDE.md`, and `SESSION-TYPE.md`, then the shared docs under
  `shared/` and `docs/agent-runtime/`. Do not treat this root file as your
  operating manual.
- **Contributors editing Agent Bridge source**: the full contributor contract
  (source-vs-runtime boundaries, queue semantics, high-risk surfaces, release
  rules) lives in the source checkout's repo-root `CLAUDE.md`
  (`~/.agent-bridge-source` or wherever `AGENT_BRIDGE_SOURCE_DIR` points), not
  here. Edit there and run `agb upgrade`.

This stub is generated and refreshed by `agb upgrade`. Operator edits to this
file are preserved across upgrades (the upgrader only replaces an unmodified
bridge-managed contract, never an edited file).
"""


def _managed_contract_sha256_set(source_root: Path, upstream_ref: str = "") -> frozenset[str]:
    """The set of content hashes that count as "the unmodified managed contract":
    the frozen historical allowlist plus the contract this upgrade is shipping.
    Adding the current contract hash means a freshly-cut contract version is
    recognized without a code edit, while still requiring an EXACT byte match
    (operator edits never match).

    #1817 r2: "the contract this upgrade ships" is read via ``upstream_file_bytes``
    so that on a dry-run ``--ref`` preview it is the *ref's* CLAUDE.md (the bytes
    that would actually be deployed), not the checked-out working tree — making
    the dry-run ``live_root_claude_action`` preview faithful to the requested ref.
    On the apply path (``upstream_ref==""``) this is the working-tree read,
    unchanged."""
    try:
        current_bytes = upstream_file_bytes(source_root, upstream_ref, "CLAUDE.md")
    except OSError:
        return KNOWN_CONTRACT_SHA256
    if not current_bytes:  # None (path absent in the ref) or empty — never add an empty hash
        return KNOWN_CONTRACT_SHA256
    return KNOWN_CONTRACT_SHA256 | {sha256_bytes(current_bytes)}


def render_live_root_operator_stub() -> bytes:
    return LIVE_ROOT_OPERATOR_STUB.format(marker=LIVE_ROOT_CLAUDE_MARKER).encode("utf-8")


def substitute_live_root_claude(source_root: Path, target_root: Path, dry_run: bool, upstream_ref: str = "") -> str | None:
    """Issue #1817: keep the live-root `CLAUDE.md` a thin operator stub.

    Returns the action taken ("created" | "substituted") or None when the live
    file is operator-customized / already a stub (left untouched). Only a file
    whose content hash EXACTLY matches a bridge-shipped contract is replaced —
    an operator-edited CLAUDE.md (any byte changed, or the generated stub) is
    never overwritten.
    """
    live_path = target_root / "CLAUDE.md"
    live = live_path.read_bytes() if live_path.exists() else None  # noqa: raw-pathlib-controller-only
    if live is None:
        # Fresh install: the tracked contract is skipped in should_skip_relpath,
        # so seed the operator stub so the live root is never empty.
        if not dry_run:
            write_bytes(live_path, render_live_root_operator_stub(), 0o644)
        return "created"
    if LIVE_ROOT_CLAUDE_MARKER.encode("utf-8") in live:
        # Already the generated stub — leave it (idempotent re-run).
        return None
    if sha256_bytes(live) not in _managed_contract_sha256_set(source_root, upstream_ref):
        # Operator-customized file (or an unrecognized variant) — preserve it.
        return None
    if not dry_run:
        write_bytes(live_path, render_live_root_operator_stub(), 0o644)
    return "substituted"


def emit_json(payload: Any, rc: int = 0, *, indent: int | None = 2) -> int:
    """Emit a command's JSON payload to stdout, BrokenPipe-safe (Issue #1660).

    Every cmd_* helper ends by serializing its result and returning a process
    rc. When the caller captures via command substitution
    (`MIGRATION_JSON="$(python3 ... migrate-agents ...)"`) and that consumer
    vanishes mid-write — e.g. a concurrent upgrade thrash — an unguarded
    `print(json.dumps(...))` raises BrokenPipeError, which (uncaught) makes a
    *completed* migration exit non-zero (observed exit 144). That mislead any
    automation gating on the exit code.

    Contract:
      * write + flush happen INSIDE the try. The flush is REQUIRED — without
        it a BrokenPipeError can surface during interpreter shutdown and still
        perturb the exit code even though the body "succeeded".
      * on BrokenPipeError, redirect stdout to os.devnull (the standard CPython
        recipe) so the interpreter's final flush at shutdown does not re-raise,
        then return the caller's intended rc.
      * the caller's intended rc is ALWAYS preserved. A broken stdout must not
        turn a non-zero rc (cmd_verify_tasks_db, cmd_apply_live) into 0, nor a
        zero rc into non-zero. We do NOT install signal.signal(SIGPIPE,
        SIG_DFL) globally — that would convert this completed-work case into a
        141/signal exit instead of preserving rc.
    """
    text = json.dumps(payload, ensure_ascii=False, indent=indent)
    try:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        # Consumer went away. Point stdout at devnull so the interpreter's
        # shutdown flush is a no-op and cannot re-raise BrokenPipeError.
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
        except OSError:
            pass
    return rc


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def write_bytes(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if mode is not None:
        os.chmod(path, mode)


def tracked_files_modes(source_root: Path) -> dict[str, int]:
    # {relpath: git_mode_in_octal_int} from `git ls-files -s -z`. Using
    # the git index (not the working tree) is required because a dev's
    # checkout can have drifted filesystem permissions (e.g. 0744 / 0700
    # inherited from umask or editor rewrites) even when git tracks the
    # file as 100755. Anything that decides "should this be executable
    # downstream" must consult the index, not `stat`.
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-files", "-z", "-s"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    modes: dict[str, int] = {}
    if proc.returncode != 0:
        return modes
    # Record format: "<mode> <hash> <stage>\t<relpath>\0"
    for record in proc.stdout.split(b"\x00"):
        if not record:
            continue
        try:
            header, relpath_bytes = record.split(b"\t", 1)
        except ValueError:
            continue
        parts = header.split(b" ")
        if not parts:
            continue
        try:
            mode_octal = int(parts[0].decode("ascii"), 8)
            relpath = relpath_bytes.decode("utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        modes[relpath] = mode_octal
    return modes


_tracked_modes_cache: dict[str, dict[str, int]] = {}


def git_tracked_exec_bits(source_root: Path, relpath: str) -> int:
    # 100755 is the only tracked-executable regular-file mode in git.
    # 100644 (regular) and 120000 (symlink) carry no exec bit downstream.
    # Cache per source_root so a single analyze/apply cycle does not
    # fork `git ls-files` per path.
    key = str(source_root)
    modes = _tracked_modes_cache.get(key)
    if modes is None:
        modes = tracked_files_modes(source_root)
        _tracked_modes_cache[key] = modes
    return 0o111 if modes.get(relpath) == 0o100755 else 0


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
        return
    if path.exists():
        shutil.rmtree(path)


def conflict_backup_path(live_path: Path) -> Path:
    return live_path.with_name(f"{live_path.name}.upgrade-conflict")


# Issue #1638 / #1675 / #1694: settings.json `merge_required` files routinely
# text-conflict on purely-cosmetic axes even when the rendered hook SET is
# identical:
#   (1) hook-event group ORDER differs (e.g. live lists `inbox-auto-drain`
#       before `session-stop`; upstream lists them the other way),
#   (2) the python interpreter token differs (`python3` vs `/usr/bin/python3`
#       vs Homebrew's `/opt/homebrew/bin/python3`) inside a hook `command`, and
#   (3) the hook-script path ARGUMENT is `~/.agent-bridge/hooks/<x>` in the
#       tracked template but the rendered live file carries the `~`-expanded
#       absolute form (`<BRIDGE_HOME>/hooks/<x>`).
# Axes (2)+(3) are exactly the two reconciliations `shared_settings_rerender`
# performs after the merge — the render is authoritative for settings.json and
# always produces the correct file — so a diff that consists ONLY of these is a
# render-owned no-op. But `git merge-file` is line-oriented and writes a
# spurious `.upgrade-conflict` on every macOS/Homebrew (and iso v2) hook-region
# upgrade. The helpers below canonicalize ONLY those axes so `apply_live` can
# short-circuit such a cosmetic-only settings diff to `keep_live` (the render
# fixes up the live file right after) instead of forcing a manual conflict. The
# normalization is deliberately surgical — a real hook add/remove/retiming, or a
# genuinely operator-modified hook command, still falls through to the unchanged
# conflict path.
_SETTINGS_CONFLICT_BASENAME = "settings.json"
# Closed allowlist of interpreter tokens treated as cosmetically equivalent.
# Issue #1638 named two literals (`python3`, `/usr/bin/python3`); Issue #1675
# adds Homebrew's `/opt/homebrew/bin/python3`, which the render emits on
# Homebrew-python macOS hosts and which is equivalent to the system interpreter
# on the target. We deliberately do NOT generalize beyond these literals (codex
# #1638 review, three rounds): a bare `python` / `python2`, a different minor
# version (`python3.10` vs `python3.11`), a venv / relative interpreter, or any
# other absolute path is a runtime-RELEVANT change the operator should see, so
# it must NOT be collapsed to cosmetic. Anything outside this set falls through
# to the real merge/conflict path unchanged.
_COSMETIC_PYTHON_INTERPRETERS = frozenset(
    {"python3", "/usr/bin/python3", "/opt/homebrew/bin/python3"}
)
# The bridge-hooks directory segment the render rewrites. The tracked template
# stores `~/.agent-bridge/hooks/<script>`; `_normalize_bridge_hook_paths`
# (bridge-hooks.py) expands `~/.agent-bridge/hooks/` → `<BRIDGE_HOME>/hooks/` at
# render time, so the live command carries an absolute prefix the template never
# had. Issue #1694: canonicalize BOTH prefixes to a single placeholder, keeping
# the script BASENAME intact — so `~/.agent-bridge/hooks/session-stop.py` and
# `/Users/x/.agent-bridge/hooks/session-stop.py` collapse to the same token,
# while two genuinely-different hook scripts (different basename) still differ.
_COSMETIC_HOOKS_DIR_SEGMENT = "/hooks/"
_COSMETIC_HOOKS_DIR_PLACEHOLDER = "\x00hooks\x00/"


def _canonicalize_hook_path_arg(tail: str) -> str:
    """Collapse the render-owned bridge-hooks directory prefix in a path arg.

    Issue #1694: the tracked template stores a hook script as
    `~/.agent-bridge/hooks/<script>`, but the render expands `~` → the absolute
    `<BRIDGE_HOME>/hooks/<script>` (`_normalize_bridge_hook_paths`,
    bridge-hooks.py). That `~`-vs-absolute difference is a render-owned no-op,
    yet it makes `live != base` on the command line and forces a spurious
    text-merge conflict. Here we rewrite BOTH the template prefix
    (`~/.agent-bridge/hooks/`) and the render-expanded absolute form
    (`<abs>/.agent-bridge/hooks/`) to a single placeholder, preserving the
    script BASENAME so two genuinely-different hook scripts still differ.

    The match is deliberately anchored on the managed `.agent-bridge/hooks/`
    segment (default `BRIDGE_HOME`): a hook pointed at some unrelated `/hooks/`
    directory, or a non-default `BRIDGE_HOME` whose render prefix does not carry
    `.agent-bridge`, is left untouched and still surfaces as a real diff.
    """
    # The render replaces the WHOLE `~/.agent-bridge/hooks/` prefix with
    # `<BRIDGE_HOME>/hooks/`, so for both the template and rendered forms the
    # only invariant tail is the script basename. Collapse to a single
    # placeholder + the remainder after the `.agent-bridge/hooks/` segment in
    # BOTH cases (symmetric) so a template arg and its rendered absolute twin
    # canonicalize identically. The `~`-rooted template is just the absolute
    # form with a `~` home, so the same segment search handles both.
    for marker in (
        "~/.agent-bridge" + _COSMETIC_HOOKS_DIR_SEGMENT,
        "/.agent-bridge" + _COSMETIC_HOOKS_DIR_SEGMENT,
    ):
        idx = tail.find(marker)
        if idx != -1:
            rest = tail[idx + len(marker):]
            return _COSMETIC_HOOKS_DIR_PLACEHOLDER + rest
    return tail


def _canonicalize_hook_command(command: str) -> str:
    """Normalize the cosmetic axes of a hook command string.

    Splits off the first whitespace-delimited token (the interpreter); if it is
    one of the closed allowlist of cosmetically-equivalent python3 interpreters
    (bare `python3`, `/usr/bin/python3`, or Homebrew's
    `/opt/homebrew/bin/python3` — Issue #1675), rewrite it to the canonical
    `python3`. The remainder (the script path argument) is then run through
    `_canonicalize_hook_path_arg`, which collapses the render-owned
    `~`-vs-absolute bridge-hooks prefix (Issue #1694).

    Every other interpreter — `bash …`, bare `python`/`python2`, a
    minor-version-pinned `python3.11`, a venv/relative interpreter, any other
    absolute path — leaves the interpreter token unchanged so a runtime-relevant
    interpreter change still surfaces as a real conflict; the path-arg
    normalization still applies so a `bash ~/.agent-bridge/hooks/…` vs
    `bash <abs>/…` difference is also collapsed.
    """
    stripped = command.lstrip()
    if not stripped:
        return command
    head, sep, tail = stripped.partition(" ")
    interpreter = "python3" if head in _COSMETIC_PYTHON_INTERPRETERS else head
    return interpreter + sep + _canonicalize_hook_path_arg(tail)


def _canonicalize_settings_hooks(parsed: Any) -> Any:
    """Return a deep, order-insensitive canonical form of a settings doc.

    Only the `hooks` mapping is touched: each event's group list is rendered
    order-independent (sorted by canonical JSON) and every hook `command` has
    its python interpreter prefix normalized. All other keys/values are copied
    through unchanged, so a non-cosmetic difference anywhere still shows up in
    the comparison.
    """
    if not isinstance(parsed, dict):
        return parsed
    canonical = dict(parsed)
    hooks = parsed.get("hooks")
    if not isinstance(hooks, dict):
        return canonical
    canonical_hooks: dict[str, Any] = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            canonical_hooks[event] = groups
            continue
        canonical_groups = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                new_group = dict(group)
                new_group["hooks"] = [
                    {**hook, "command": _canonicalize_hook_command(hook["command"])}
                    if isinstance(hook, dict) and isinstance(hook.get("command"), str)
                    else hook
                    for hook in group["hooks"]
                ]
                canonical_groups.append(new_group)
            else:
                canonical_groups.append(group)
        # Order-independent: a different group ORDER with the same membership
        # collapses to the same canonical list. `sort_keys` makes the per-group
        # serialization stable regardless of key insertion order.
        canonical_groups.sort(
            key=lambda item: json.dumps(item, sort_keys=True, ensure_ascii=False)
        )
        canonical_hooks[event] = canonical_groups
    canonical["hooks"] = canonical_hooks
    return canonical


def settings_cosmetic_only_diff(live: bytes, upstream: bytes) -> bool:
    """True when live vs upstream settings.json differ ONLY cosmetically.

    Cosmetic == hook-event group ordering and/or python interpreter prefix.
    Returns False (→ fall through to the real conflict path) when either side
    is not parseable JSON, when the bytes are already identical (no decision to
    make here), or when any non-cosmetic difference remains after canonical
    normalization.
    """
    try:
        live_parsed = json.loads(live.decode("utf-8"))
        upstream_parsed = json.loads(upstream.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    if live_parsed == upstream_parsed:
        # Byte-level diff with structurally-equal JSON (whitespace/key order):
        # still cosmetic, keep_live is the right call.
        return True
    return _canonicalize_settings_hooks(live_parsed) == _canonicalize_settings_hooks(
        upstream_parsed
    )


def git_head(source_root: Path) -> str:
    return (
        subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True).strip()
    )


def git_ref(source_root: Path) -> str:
    for command in (
        ["git", "-C", str(source_root), "describe", "--tags", "--exact-match", "HEAD"],
        ["git", "-C", str(source_root), "rev-parse", "--abbrev-ref", "HEAD"],
    ):
        proc = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    return ""


def read_source_version(source_root: Path) -> str:
    version_path = source_root / "VERSION"
    try:
        version = version_path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (FileNotFoundError, IndexError):
        return "0.0.0-dev"
    return version or "0.0.0-dev"


def read_target_version(target_root: Path) -> str:
    """Read the live install's `VERSION` file, mirror of `read_source_version`.

    Returns "" when the file is missing or empty so callers can distinguish
    "no live VERSION recorded" (fresh / corrupt install) from a real
    semver string. Issue #666: used by `analyze_live` to recover from a
    missing/unreachable `base_ref` on a real cross-version upgrade by
    treating content-drifted files as `upstream_only` instead of
    `unknown_base_live_diff` (which silently keeps live and never copies).
    """
    version_path = target_root / "VERSION"
    try:
        version = version_path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (FileNotFoundError, IndexError, OSError):
        return ""
    return version


def load_json_arg(value: str = "", file_path: str = "") -> dict[str, Any]:
    if file_path:
        return json.loads(Path(file_path).read_text(encoding="utf-8"))
    if value:
        return json.loads(value)
    return {}


def git_file_bytes(source_root: Path, ref: str, relpath: str) -> bytes | None:
    proc = subprocess.run(
        ["git", "-C", str(source_root), "show", f"{ref}:{relpath}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def sha256_bytes(data: bytes | None) -> str:
    if data is None:
        return ""
    return hashlib.sha256(data).hexdigest()


def is_text_bytes(data: bytes | None) -> bool:
    if data is None:
        return True
    if b"\x00" in data:
        return False
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def tracked_files(source_root: Path) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-files", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return [item for item in proc.stdout.decode("utf-8").split("\x00") if item]


def tracked_files_at_ref(source_root: Path, ref: str) -> list[str]:
    """File set tracked by `ref`, read WITHOUT mutating the working tree.

    Issue #1602: the dry-run preview must reflect the requested `--ref`, not
    whatever ref `SOURCE_ROOT`'s working tree currently sits on. The apply
    path checks the ref out and walks the working tree via `tracked_files`;
    dry-run cannot (it must not mutate the tree), so it enumerates the target
    file set from the ref's git tree object instead. `-z` keeps parity with
    `tracked_files` (NUL-delimited paths, robust to spaces/newlines).
    """
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-tree", "-r", "-z", "--name-only", ref],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return [item for item in proc.stdout.decode("utf-8").split("\x00") if item]


def upstream_tracked_files(source_root: Path, upstream_ref: str) -> list[str]:
    """Upstream file set: from `upstream_ref` when set, else the working tree.

    Issue #1602: `upstream_ref` is set ONLY on the dry-run `--ref` preview
    path (threaded from `bridge-upgrade.sh` as `--upstream-ref`). The apply
    path leaves it empty and keeps reading the working tree, which it has
    already checked out to the ref.
    """
    if upstream_ref:
        return tracked_files_at_ref(source_root, upstream_ref)
    return tracked_files(source_root)


def upstream_file_bytes(source_root: Path, upstream_ref: str, relpath: str) -> bytes | None:
    """Upstream bytes for `relpath`: from `upstream_ref` when set, else WT.

    Issue #1602: ref-side reads reuse `git_file_bytes` (`git show <ref>:path`)
    so the dry-run preview's upstream bytes match the requested `--ref`
    without a checkout. The working-tree read is a direct `read_bytes()` —
    identical to the pre-#1602 inline read at the call sites (the file set
    comes from `git ls-files`, so every path is tracked + present); a
    missing path raises exactly as it did before.
    """
    if upstream_ref:
        return git_file_bytes(source_root, upstream_ref, relpath)
    return (source_root / relpath).read_bytes()


def upstream_exec_bits(source_root: Path, upstream_ref: str, relpath: str) -> int:
    """git-tracked exec bit for `relpath`: from `upstream_ref` when set, else WT.

    Issue #1602: mirrors `git_tracked_exec_bits` but resolves the mode from
    the ref's tree (`git ls-tree <ref> -- <path>`) so the dry-run mode-drift
    classification reflects the requested `--ref`. Empty `upstream_ref` keeps
    the existing working-tree-index lookup.
    """
    if not upstream_ref:
        return git_tracked_exec_bits(source_root, relpath)
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-tree", upstream_ref, "--", relpath],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout:
        return 0
    # `100755 blob <sha>\t<path>` — first field is the mode.
    mode_field = proc.stdout.decode("utf-8", errors="replace").split(maxsplit=1)[0]
    try:
        return int(mode_field, 8) & 0o111
    except ValueError:
        return 0


def read_upstream_version(source_root: Path, upstream_ref: str) -> str:
    """Source VERSION: from `upstream_ref` when set, else the working tree.

    Issue #1602: `versions_differ` (Issue #666 path) must compare the live
    install against the REQUESTED ref's VERSION on the dry-run preview, not
    the checked-out tree's VERSION. Falls back to the dev sentinel exactly
    like `read_source_version` when the ref has no readable VERSION.
    """
    if not upstream_ref:
        return read_source_version(source_root)
    data = git_file_bytes(source_root, upstream_ref, "VERSION")
    if data is None:
        return "0.0.0-dev"
    try:
        version = data.decode("utf-8").splitlines()[0].strip()
    except (IndexError, UnicodeDecodeError):
        return "0.0.0-dev"
    return version or "0.0.0-dev"


def should_skip_relpath(relpath: str) -> bool:
    # Issue #1817: the tracked root `CLAUDE.md` is the contributor contract and
    # must NOT land at the live root (it would ancestor-inject into every agent
    # session). The deploy classifier skips it; `substitute_live_root_claude`
    # then maintains a thin operator stub there instead.
    if relpath in {"agent-roster.local.sh", "CLAUDE.md"}:
        return True
    for prefix in ("logs/", "shared/", "state/", "backups/", "worktrees/"):
        if relpath.startswith(prefix):
            return True
    if relpath in {"logs", "shared", "state", "backups", "worktrees"}:
        return True
    if relpath.startswith("agents/"):
        allowed_prefixes = (
            "agents/_template/",
            "agents/.claude/",
        )
        allowed_files = {
            "agents/README.md",
            "agents/SYNC-MODEL.md",
            "agents/CUTOVER-WAVES.md",
            "agents/WORKSPACE-MIGRATION-PLAN.md",
        }
        if relpath in allowed_files:
            return False
        if any(relpath.startswith(prefix) for prefix in allowed_prefixes):
            return False
        return True
    return False


def render_template(text: str, agent_id: str, display_name: str, role_text: str, engine: str, session_type: str) -> str:
    runtime = "Claude Code CLI" if engine == "claude" else "Codex CLI"
    replacements = {
        "<Agent Name>": display_name,
        "<agent-id>": agent_id,
        "<Role>": role_text,
        "<Role Summary>": role_text,
        "<Runtime>": runtime,
        "<Boss>": "관리자 에이전트",
        "<한 줄 역할 설명>": role_text,
        "<표시 이름>": display_name,
        "<Session Type>": session_type,
        "<핵심 책임>": role_text,
        "<주 요청자>": "관리자 에이전트",
        "<Claude Code CLI | Codex CLI>": runtime,
        "<반드시 지킬 운영 규칙>": "큐를 source of truth로 삼고, claim/done note를 생략하지 않는다.",
        "<위험 작업 제한>": "크리티컬 변경 전에는 dry-run 또는 관련 상태 확인을 먼저 수행한다.",
        "<보고 방식>": "결과는 요청자 채널 또는 task queue로 반드시 남긴다.",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def extract_managed_block(text: str, start_marker: str, end_marker: str) -> str:
    match = re.search(
        rf"{_managed_start_pattern(start_marker)}.*?{re.escape(end_marker)}",
        text,
        re.S,
    )
    return match.group(0).strip() if match else ""


def refresh_managed_block(
    original: str, managed_block: str, start_marker: str, end_marker: str
) -> str:
    if not managed_block:
        return original
    block = managed_block.rstrip() + "\n"
    pattern = re.compile(
        rf"{_managed_start_pattern(start_marker)}.*?{re.escape(end_marker)}\n*",
        re.S,
    )
    if pattern.search(original):
        updated = pattern.sub(block + "\n", original, count=1)
        return updated if updated.endswith("\n") else updated + "\n"

    normalized = original.rstrip()
    if normalized.startswith("# "):
        first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        rest = rest.lstrip()
        updated = f"{first}\n\n{block}\n"
        if rest:
            updated += f"{rest}\n"
        return updated

    if normalized:
        return f"{block}\n{normalized}\n"
    return block


def extract_managed_claude_block(text: str) -> str:
    return extract_managed_block(text, MANAGED_CLAUDE_START, MANAGED_CLAUDE_END)


def refresh_managed_claude_block(original: str, managed_block: str) -> str:
    return refresh_managed_block(original, managed_block, MANAGED_CLAUDE_START, MANAGED_CLAUDE_END)


def discover_agent_dirs(agent_root: Path) -> list[Path]:
    if not agent_root.exists():
        return []
    results: list[Path] = []
    for path in sorted(agent_root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        results.append(path)
    return results


# Issue #1611: roster-restrict the migrate-agents loop. Hosts accumulate
# orphan / test-agent homes under `agents/` (one live host had ~97), and
# the pre-#1611 loop migrated every one of them — the write-surface noise
# that pushed operators to `--no-migrate-agents` and defeated the intent
# that an upgrade keeps active agents' canon/skills current.
#
# `BRIDGE_AGENT_*[...]=` map-key assignment in the roster shell files —
# the most robust roster-membership signal, since `agent create` writes a
# full per-agent record block keyed by id.
_ROSTER_MAP_KEY_RE = re.compile(
    r"""^\s*BRIDGE_[A-Z0-9_]+\[\s*(['"]?)([^'"\]\s]+)\1\s*\]""",
    re.M,
)
# `bridge_add_agent_id_if_missing <id>` (quoted or bare) — the helper the
# scaffolder emits alongside each per-agent record block.
_ROSTER_ADD_ID_RE = re.compile(
    r"""^\s*bridge_add_agent_id_if_missing\s+(['"]?)([^'"\s)]+)\1""",
    re.M,
)
# `BRIDGE_AGENT_IDS=( a b c )` / `BRIDGE_AGENT_IDS+=( ... )` literal arrays.
_ROSTER_IDS_ARRAY_RE = re.compile(
    r"""BRIDGE_AGENT_IDS\+?=\(([^)]*)\)""",
    re.S,
)
_ROSTER_ARRAY_TOKEN_RE = re.compile(r"""(['"])(.*?)\1|([^\s'"]+)""")
# `BRIDGE_AGENT_ENGINE["id"]="engine"` map assignment in the roster shell
# files — the authoritative per-agent engine declaration the scaffolder writes
# alongside the membership record (Issue #1892). Static parse only (never
# sources the file), mirroring _parse_roster_*_ids. Captures id (group 2) and
# the assigned engine token (group 4) so the doc-backfill pass can treat the
# roster engine as the source of truth when agent-meta.env is absent.
#
# FAIL-CLOSED tokenization: the engine token must be the ENTIRE assignment
# value AND occupy the whole logical line — the (optional) closing quote is
# followed only by trailing whitespace and an optional ``# comment`` before the
# line end. This rejects every ambiguous / non-atomic RHS whose static value a
# regex cannot trust:
#   * shell-expansion-tainted: ``"codex"$VAR`` / ``codex$VAR`` / ``${ENGINE:-codex}``
#   * concatenation / trailing junk: ``"codex"more`` / ``codex foo`` / ``"codex" $VAR``
#   * ``;``-chained multi-assignment on one line: ``...=codex; ...=claude``
#     (shell last-wins is NOT statically resolvable here — anchoring to the whole
#     line declines the chain entirely instead of mis-reading the FIRST clause).
# Any rejected line leaves the engine UNKNOWN → the decision helper holds
# fail-closed, never mis-resolving an ambiguous declaration to a positive codex.
# ``\r?`` tolerates CRLF rosters. A clean single whole-line assignment
# (``BRIDGE_AGENT_ENGINE["x"]="codex"`` / ``=codex`` / ``=codex  # note``) matches.
# A trailing ``# comment`` is only honored when it is a REAL shell comment —
# i.e. preceded by whitespace. ``=codex#junk`` / ``="codex"#junk`` have a runtime
# value of ``codex#junk`` (``#`` is NOT a comment mid-word), so they must NOT
# resolve to a bare ``codex``; the missing-whitespace form fails the whole-line
# anchor and is declined (engine unknown -> held).
_ROSTER_ENGINE_RE = re.compile(
    r"""^[ \t]*BRIDGE_AGENT_ENGINE\[\s*(['"]?)([^'"\]\s]+)\1\s*\]"""
    r"""[ \t]*=[ \t]*(['"]?)([A-Za-z0-9._-]+)\3(?:[ \t]+\#[^\r\n]*)?[ \t]*\r?$""",
    re.M,
)


def _parse_roster_shell_ids(text: str) -> set[str]:
    """Best-effort extraction of agent ids from a roster shell file.

    Static parse only — never sources the file. Three independent patterns
    are unioned so a malformed clause in one shape does not lose ids that
    another shape captured.
    """
    ids: set[str] = set()
    for match in _ROSTER_MAP_KEY_RE.finditer(text):
        ids.add(match.group(2))
    for match in _ROSTER_ADD_ID_RE.finditer(text):
        ids.add(match.group(2))
    for array_match in _ROSTER_IDS_ARRAY_RE.finditer(text):
        for token in _ROSTER_ARRAY_TOKEN_RE.finditer(array_match.group(1)):
            value = token.group(2) if token.group(2) is not None else token.group(3)
            if value:
                ids.add(value)
    # Drop obvious non-ids: shell expansions and empty strings.
    return {i for i in ids if i and "$" not in i and "{" not in i}


def _parse_roster_tsv_ids(path: Path) -> set[str]:
    """First column of a state roster TSV, header row skipped."""
    ids: set[str] = set()
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ids
    for idx, line in enumerate(text.splitlines()):
        if idx == 0 and line.startswith("agent\t"):
            continue
        first = line.split("\t", 1)[0].strip()
        if first:
            ids.add(first)
    return ids


def _parse_roster_tsv_engines(path: Path) -> dict[str, str]:
    """Issue #2016: per-agent engine declarations from ``state/active-roster.tsv``.

    The live active-roster TSV carries the engine in column 2 (header
    ``agent\\tengine\\tsession\\t…`` — see lib/bridge-state.sh
    bridge_render_active_roster). A dynamic / active claude agent that exists
    ONLY in this TSV (never written into a shell roster file) is otherwise
    invisible to ``collect_roster_engines`` (shell-only), so the codex
    AGENTS.md emission gate would fall back to the detect_engine heuristic and
    could still re-emit on it. Parse it here so the gate is roster-authoritative
    for dynamic agents too. Header row + malformed/short rows are skipped;
    read-as-existence (the OSError IS the probe) keeps the #1175 audit ceiling.
    """
    engines: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return engines
    for idx, line in enumerate(text.splitlines()):
        if idx == 0 and line.startswith("agent\t"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        agent_id = cols[0].strip()
        engine = cols[1].strip().lower()
        if agent_id and engine:
            engines[agent_id] = engine
    return engines


def _parse_roster_engines(text: str) -> dict[str, str]:
    """Best-effort extraction of per-agent engine declarations from a roster
    shell file. Static parse only — never sources the file. Returns an
    ``id -> engine`` map for every ``BRIDGE_AGENT_ENGINE["id"]="engine"`` clause
    (Issue #1892). Shell-expansion ids are dropped (mirrors _parse_roster_shell_ids).
    """
    engines: dict[str, str] = {}
    for match in _ROSTER_ENGINE_RE.finditer(text):
        agent_id = match.group(2)
        engine = match.group(4).strip().lower()
        if not agent_id or "$" in agent_id or "{" in agent_id:
            continue
        if engine:
            engines[agent_id] = engine
    return engines


def collect_roster_engines(target_root: Path) -> dict[str, str]:
    """Build the roster-declared ``id -> engine`` map for the doc-backfill pass.

    Issue #1892: the codex AGENTS.md doc-backfill must treat the roster engine
    as the source of truth, not a filesystem heuristic. The roster shell files
    (``agent-roster.sh`` + the operator's ``agent-roster.local.sh`` override)
    are the authoritative engine declaration. The local override wins on a
    conflict (it is the last-sourced map in the live runtime). Read-as-existence
    check (the OSError IS the probe) keeps the #1175 raw-pathlib audit ceiling.
    """
    engines: dict[str, str] = {}
    for rel in ("agent-roster.sh", "agent-roster.local.sh"):
        roster_path = target_root / rel
        try:
            text = roster_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        engines.update(_parse_roster_engines(text))
    return engines


def collect_registry_engines(target_root: Path) -> dict[str, str]:
    """Build the registry-published ``id -> engine`` map for the doc-backfill.

    Issue #1956: a DYNAMIC agent (`agb-dev-codex`, `crm-dev-codex`: source=dynamic)
    is not declared in the static roster shell files, so ``collect_roster_engines``
    returns nothing for it and the fail-closed resolver (#1892) holds it forever —
    even though its engine IS known authoritatively. The daemon publishes that
    authority in ``state/active-roster.tsv``: the ``engine`` column (index 1) is
    ``bridge_agent_engine``'s value, which for a dynamic agent is the engine
    recorded from its ``--codex``/``--claude`` launch flag in the agent registry.

    This is read as a strict FALLBACK below the static roster (the roster stays
    the SoT for roster-registered agents; the registry only fills the gap for
    dynamic agents the roster never declares). The lookup is exact per-id — no
    substring/heuristic — so it cannot reintroduce the #1930 ``detect_engine``
    false-positive: a dynamic agent whose registry engine is ``claude`` resolves
    to ``claude`` and is never codex-backfilled (the #1928 / smoke-T3 guard).

    Reads ``active-roster.tsv`` (live sessions, the authoritative engine column).
    The header row (``agent\\tengine\\t...``) is skipped. Read-as-existence (the
    OSError IS the probe) keeps the #1175 raw-pathlib audit ceiling. Dynamic
    agents are NEVER written back into the static roster — this map exists only
    in-memory for the duration of one backfill pass.
    """
    engines: dict[str, str] = {}
    roster_tsv = target_root / "state" / "active-roster.tsv"
    try:
        text = roster_tsv.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return engines
    for idx, line in enumerate(text.splitlines()):
        if idx == 0 and line.startswith("agent\t"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        agent_id = cols[0].strip()
        engine = cols[1].strip().lower()
        # Only a positive, atomic engine token is authoritative. The runtime
        # `unknown` sentinel (bridge_agent_engine's miss value) and any blank
        # are declined so they fall through to the roster's fail-closed path.
        if agent_id and engine and engine != "unknown":
            engines[agent_id] = engine
    return engines


def collect_roster_ids(target_root: Path, admin_agent: str) -> tuple[set[str], list[str]]:
    """Build the set of roster agent ids for the migrate-agents filter.

    Returns (roster_ids, sources_found). `sources_found` lists the roster
    artifacts that contributed at least one id; an empty list means the
    caller must fall back to migrating ALL dirs (#1611 safe fallback —
    missing a real agent is worse than migrating an orphan).

    `admin_agent` is always folded in when non-empty even if no source
    surfaced it, so the install's admin is never treated as an orphan.
    """
    roster_ids: set[str] = set()
    sources_found: list[str] = []

    # state/agents-aggregate.tsv lists ALL registered agents (active AND
    # stopped) — the strongest single source, since active-roster.tsv only
    # carries currently-running sessions and would skip a real-but-stopped
    # roster agent.
    aggregate_tsv = target_root / "state" / "agents-aggregate.tsv"
    aggregate_ids = _parse_roster_tsv_ids(aggregate_tsv)
    if aggregate_ids:
        roster_ids |= aggregate_ids
        sources_found.append("state/agents-aggregate.tsv")

    active_tsv = target_root / "state" / "active-roster.tsv"
    active_ids = _parse_roster_tsv_ids(active_tsv)
    if active_ids:
        roster_ids |= active_ids
        sources_found.append("state/active-roster.tsv")

    for rel in ("agent-roster.sh", "agent-roster.local.sh"):
        roster_path = target_root / rel
        try:
            text = roster_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            # Missing or unreadable roster file → skip. The read's
            # FileNotFoundError/OSError IS the existence check; no raw
            # pathlib .exists() probe (keeps the #1175 audit ceiling).
            continue
        shell_ids = _parse_roster_shell_ids(text)
        if shell_ids:
            roster_ids |= shell_ids
            sources_found.append(rel)

    admin_agent = (admin_agent or "").strip()
    if admin_agent:
        roster_ids.add(admin_agent)

    return roster_ids, sources_found


def detect_display_name(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        match = re.search(r"^#\s+(.+?)\s+—\s+.+$", claude_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    soul_path = agent_dir / "SOUL.md"
    if soul_path.exists():
        match = re.search(r"^#\s+(.+?)\s+Soul$", soul_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    return agent_dir.name


def detect_role_text(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        text = claude_path.read_text(encoding="utf-8", errors="ignore")
        match = re.search(r"^#\s+.+?\s+—\s+(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
        match = re.search(r"- \*\*역할\*\*:\s*(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
    return "Bridge-managed agent"


# Issue #1930: a genuine *codex* signal in a CLAUDE.md is the RESOLVED runtime
# declaration line — the `런타임`/`runtime` label whose value is `Codex CLI`
# (header form `(런타임: Codex CLI)`, body form `- **런타임**: Codex CLI`). A bare
# `"Codex CLI" in text` substring scan also fires on two NON-codex sources that
# every rendered claude profile carries, false-flagging the agent as codex (and
# making the #1892 fail-closed hold alert recur every hygiene/upgrade pass):
#   1. the unresolved template placeholder `- **런타임**: <Claude Code CLI | Codex CLI>`
#      (the angle-bracket choice line — both engine tokens present), and
#   2. prose that merely *mentions* Codex CLI as an example, e.g. the template's
#      background-subagent note `런타임에 ... 기능이 없으면(예: Codex CLI)`.
# Anchoring on the resolved runtime-label value excludes both while still
# detecting a real codex profile's resolved declaration. Shared by BOTH the
# session-type heuristic (below) and detect_engine — the false positive must be
# excluded on both paths, since detect_session_type -> "static-codex" itself
# short-circuits detect_engine to codex.
_CODEX_RUNTIME_DECL = re.compile(r"(?:런타임|runtime)\**\s*:\s*Codex CLI", re.IGNORECASE)


def detect_session_type(agent_dir: Path, admin_agent: str) -> str:
    session_path = agent_dir / "SESSION-TYPE.md"
    if session_path.exists():
        match = re.search(r"Session Type:\s*([A-Za-z0-9._-]+)", session_path.read_text(encoding="utf-8", errors="ignore"))
        if match:
            return match.group(1).strip()
    if agent_dir.name == admin_agent:
        return "admin"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and _CODEX_RUNTIME_DECL.search(
        claude_path.read_text(encoding="utf-8", errors="ignore")
    ):
        return "static-codex"
    return "static-claude"


def v2_session_type_candidates(agent_dir: Path) -> list[Path]:
    """Return existing per-agent SESSION-TYPE.md paths across v1/v2 layouts.

    Issue #906: v2 layout splits per-agent state across three roots:
    - ``agents/<agent>/``                  (profile source, watchdog-authoritative)
    - ``data/agents/<agent>/home/``        (runtime home)
    - ``data/agents/<agent>/workdir/``     (profile target)

    Operator-mutated state (onboarding completion, channel choice) can land
    in any of them depending on the install's history. Callers that need to
    preserve operator state across a template re-render must consult all
    three before overwriting. Returned in priority order (source first).
    """
    # ``agent_dir`` is ``<target_root>/agents/<agent>``. The v2 data root is
    # ``<target_root>/data/agents/<agent>`` — two levels up and over.
    target_root = agent_dir.parent.parent
    v2_root = target_root / "data" / "agents" / agent_dir.name
    return [
        agent_dir / "SESSION-TYPE.md",
        v2_root / "workdir" / "SESSION-TYPE.md",
        v2_root / "home" / "SESSION-TYPE.md",
    ]


def onboarding_state_dir(agent_dir: Path) -> Path:
    """The controller state-marker dir ``state/agents/<agent>`` for this agent.

    ``agent_dir`` is ``<target_root>/agents/<agent>``; the markers live under
    ``<target_root>/state/agents/<agent>`` (bridge-init.sh +
    bridge-agent.sh::_set_onboarding_state_dir compute the same path).
    """
    target_root = agent_dir.parent.parent
    return target_root / "state" / "agents" / agent_dir.name


def detect_onboarding_complete_marker(agent_dir: Path) -> bool:
    """Return True iff the ``onboarding-complete`` state marker exists.

    Issue #2004: the marker is the authoritative completion signal — the live
    completion verb (``agent set-onboarding <a> complete``) writes it only
    AFTER every SESSION-TYPE layer flipped to complete, so its presence is
    proof of a recorded completion even if a particular SESSION-TYPE candidate
    is unreadable to the controller (iso v2).
    """
    try:
        return (onboarding_state_dir(agent_dir) / "onboarding-complete").is_file()  # noqa: raw-pathlib-controller-only
    except (OSError, PermissionError):
        return False


def detect_stale_pending_onboarding(agent_dir: Path) -> bool:
    """Return True iff an ``onboarding-pending`` marker exists with NO complete signal.

    Issue #2004: a lingering ``onboarding-pending`` marker with no complete
    signal anywhere is AMBIGUOUS — it is either a genuinely-abandoned fresh
    install or an install whose completion never recorded. The upgrader must
    NOT silently force-complete from ``pending`` alone (that would un-onboard a
    truly-fresh install); instead the caller surfaces a warning so the operator
    has an explicit repair path. ``complete`` anywhere (marker OR any
    SESSION-TYPE layer) overrides — there is nothing stale to warn about then.
    """
    try:
        pending = (onboarding_state_dir(agent_dir) / "onboarding-pending").is_file()  # noqa: raw-pathlib-controller-only
    except (OSError, PermissionError):
        return False
    if not pending:
        return False
    # A complete signal anywhere resolves the ambiguity — not stale.
    return not detect_prior_onboarding_complete(agent_dir)


def detect_prior_onboarding_complete(agent_dir: Path) -> bool:
    """Return True iff onboarding completed — by state marker OR any SESSION-TYPE.md.

    Issue #906: ``agent-bridge upgrade --apply`` re-templates
    ``agents/<agent>/SESSION-TYPE.md`` from a fresh template that ships with
    ``Onboarding State: pending``. On a host that already completed
    onboarding, the prior ``complete`` state typically lives in
    ``data/agents/<agent>/{workdir,home}/SESSION-TYPE.md`` (v2 layout). The
    upgrade must not UN-onboard an already-onboarded install — onboarding
    state is a one-way ratchet from pending → complete. If any candidate
    says complete, the re-render must carry that forward.

    Issue #2004: ALSO honor the ``state/agents/<agent>/onboarding-complete``
    marker. It is the authoritative completion record (the live completion verb
    writes it only after every SESSION-TYPE layer flipped to complete), and on
    an iso v2 install the per-UID SESSION-TYPE candidates can be unreadable to
    the controller while the controller-owned marker is not — so the marker is
    both more authoritative and more reliably readable here.
    """
    if detect_onboarding_complete_marker(agent_dir):
        return True
    pattern = re.compile(r"^-?\s*Onboarding State:\s*complete\b", re.MULTILINE | re.IGNORECASE)
    for path in v2_session_type_candidates(agent_dir):
        try:
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
        except (OSError, PermissionError):
            # Per-UID isolated trees can be unreadable by the controller;
            # match migrate_agent_home's tolerance and skip silently.
            continue
        if pattern.search(text):
            return True
    return False


def repair_onboarding_complete_markers(agent_dir: Path, dry_run: bool) -> bool:
    """Issue #2004: write the ``onboarding-complete`` marker + clear ``-pending``.

    Called when ``detect_prior_onboarding_complete`` saw a complete SESSION-TYPE
    layer but the state markers had drifted (the original #2004 incident: a
    completed install whose ``onboarding-pending`` marker was never cleared).
    Idempotent + best-effort: a controller that cannot write the state dir
    (perms) returns False without aborting the migration. Returns True iff it
    actually wrote/removed a marker (so the caller can record a repair).
    """
    if dry_run:
        return False
    state_dir = onboarding_state_dir(agent_dir)
    complete = state_dir / "onboarding-complete"
    pending = state_dir / "onboarding-pending"
    changed = False
    try:
        if not complete.is_file():  # noqa: raw-pathlib-controller-only
            state_dir.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only
            import time as _time

            complete.write_text(  # noqa: raw-pathlib-controller-only
                f"agent={agent_dir.name}\nwritten={int(_time.time())}\n"
                f"reason=upgrade-repair-onboarding-complete\n",
                encoding="utf-8",
            )
            changed = True
        if pending.is_file():  # noqa: raw-pathlib-controller-only
            pending.unlink()  # noqa: raw-pathlib-controller-only
            changed = True
    except (OSError, PermissionError):
        # Iso trees / perms can block the controller; the SESSION-TYPE preserve
        # already carried `complete` forward, so a marker repair miss is a
        # warning-grade nicety, never fatal.
        return changed
    return changed


def apply_onboarding_state_complete(text: str) -> str:
    """Rewrite a rendered SESSION-TYPE.md so its Onboarding State reads ``complete``.

    Issue #906: counterpart to detect_prior_onboarding_complete. Mirrors the
    in-place rewrite that bridge-agent.sh already performs for static-claude
    homes, but applied at template-render time during upgrade migration so
    that the source-of-truth file at ``agents/<agent>/SESSION-TYPE.md``
    matches the operator's prior state instead of regressing to pending.
    """
    return re.sub(
        r"(^-?\s*Onboarding State:\s*)([A-Za-z0-9._-]+)",
        r"\1complete",
        text,
        count=1,
        flags=re.MULTILINE,
    )


def detect_engine(agent_dir: Path, session_type: str) -> str:
    if session_type == "static-codex":
        return "codex"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and _CODEX_RUNTIME_DECL.search(
        claude_path.read_text(encoding="utf-8", errors="ignore")
    ):
        return "codex"
    return "claude"


# Issue #1906: identity-line signature of a Codex-contract AGENTS.md. The codex
# AGENTS.md template (agents/_template/codex/AGENTS.md) opens its managed block
# with this exact literal prose — it carries no `<placeholder>` tokens, so it
# survives render_template byte-for-byte in every scaffolded/backfilled codex
# AGENTS.md. Keying on the rendered identity line (rather than mere file
# presence) means a codex agent's own legitimate AGENTS.md is recognised, while
# a hand-authored non-codex AGENTS.md never trips the residue detector.
CODEX_CONTRACT_AGENTS_MD_MARKER = "You are a Codex (gpt) agent"


def agents_md_is_codex_contract(agents_md_path: Path) -> bool:
    """Issue #1906: True iff ``AGENTS.md`` carries the Codex operating contract.

    Read-only content-signature probe (never mutates / never renames). Detects
    the codex identity line the codex AGENTS.md template materializes; an absent
    or unreadable file, or one without the marker, returns False.
    """
    try:
        if not agents_md_path.is_file():  # noqa: raw-pathlib-controller-only
            return False
        text = agents_md_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return CODEX_CONTRACT_AGENTS_MD_MARKER in text


@dataclass
class AgentMigrationResult:
    agent: str
    added_files: list[str]
    created_dirs: list[str]
    updated_files: list[str]
    session_type: str
    engine: str
    rematerialize: dict[str, Any] | None = None
    # Issue #2004: operator-visible, non-fatal upgrade notes (e.g.
    # stale onboarding-pending marker that the upgrader declined to
    # auto-complete). Default factory so each result owns its own list.
    warnings: list[str] = field(default_factory=list)


def backfill_codex_agents_md_home(
    agent_dir: Path,
    template_root: Path,
    agent: str,
    display_name: str,
    role_text: str,
    engine: str,
    session_type: str,
    dry_run: bool,
) -> str | None:
    """Issue #1809: create-if-absent + managed-block refresh of a CODEX agent's
    AGENTS.md identity entrypoint in its identity HOME (the authority tree).

    Codex agents created before the entrypoint-materialization existed (early
    admin-pair provisioning) have NO AGENTS.md in their home —
    `bridge_layout_materialize_identity` runs at CREATE time only, so nothing
    ever backfilled it and the watchdog flags `missing_files: AGENTS.md`
    forever. The home is the identity authority: once it carries AGENTS.md, the
    workdir copy is mirrored by `rematerialize_agent_identity` (which already
    create-if-absents the engine entrypoint home->workdir).

    AGENTS.md is CODEX-ONLY (the engine descriptor names it the codex
    entrypoint; claude/antigravity use CLAUDE.md) so this is a no-op for every
    other engine. The template carries the SAME `<!-- BEGIN/END AGENT BRIDGE
    DOC MIGRATION -->` managed block as CLAUDE.md, so:
      * absent dst  -> create-if-absent: the whole rendered template is the
        initial materialization (managed header + custom skeleton).
      * present dst -> marker-splice refresh: ONLY the managed header is
        re-rendered; the agent's hand-written custom contract below the END
        marker survives byte-for-byte (the live hand-backfill this issue must
        not clobber).

    Returns "backfilled", "refreshed", or None (no change / not codex /
    template absent). Honors dry_run: returns the action it WOULD take without
    writing.
    """
    if engine != "codex":
        return None
    agents_md_template = template_root / "codex" / "AGENTS.md"
    # Controller-only: the upgrade migrate path runs as the controller against
    # the controller-owned agent-home tree (never inside an iso UID), so these
    # pathlib probes/mutators are the same controller-context the rest of
    # migrate_agent_home uses (#1175 raw-pathlib whitelist).
    if not agents_md_template.exists():  # noqa: raw-pathlib-controller-only
        return None
    agents_md_target = agent_dir / "AGENTS.md"
    rendered = render_template(
        agents_md_template.read_text(encoding="utf-8"),
        agent,
        display_name,
        role_text,
        engine,
        session_type,
    )
    if not agents_md_target.exists():  # noqa: raw-pathlib-controller-only
        if not dry_run:
            agents_md_target.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only
            agents_md_target.write_text(rendered, encoding="utf-8")
        return "backfilled"
    managed_block = extract_managed_claude_block(rendered)
    if not managed_block:
        return None
    original = agents_md_target.read_text(encoding="utf-8", errors="ignore")
    refreshed = refresh_managed_claude_block(original, managed_block)
    if refreshed == original:
        return None
    if not dry_run:
        agents_md_target.write_text(refreshed, encoding="utf-8")
    return "refreshed"


def migrate_agent_home(
    agent_dir: Path,
    template_root: Path,
    admin_agent: str,
    dry_run: bool,
    roster_engine: str | None = None,
) -> AgentMigrationResult:
    agent = agent_dir.name
    session_type = detect_session_type(agent_dir, admin_agent)
    engine = detect_engine(agent_dir, session_type)
    display_name = detect_display_name(agent_dir)
    role_text = detect_role_text(agent_dir)
    added_files: list[str] = []
    created_dirs: list[str] = []
    updated_files: list[str] = []
    warnings: list[str] = []

    # Issue #2016: codex AGENTS.md is emitted onto the agent home in TWO places
    # during migrate — the `codex/` template subtree the rglob below copies
    # (`home/codex/AGENTS.md`) AND the home-ROOT `AGENTS.md` the #1809 entrypoint
    # backfill writes at the tail. BOTH are CODEX-ONLY; on a claude agent they
    # produce a self-contradictory file (codex identity line, claude runtime)
    # that then keeps the doc-backfill `detect_engine` heuristic flagging the
    # agent as codex — a benign-but-permanent `[hygiene] engine disagreement`
    # hold re-firing every upgrade/backfill pass. The engine SIGNAL for both
    # codex-emission gates must be ROSTER-authoritative (independent of the
    # `detect_engine` filesystem heuristic that incidental "Codex CLI" prose
    # trips and that #1930/#1975 hardens separately); fall back to the heuristic
    # `engine` only when the roster does not declare one. (The render `engine`
    # used for placeholder substitution above stays the heuristic value — that is
    # #1930/#1975's domain, not this gate's.)
    codex_emit_engine = (roster_engine or engine or "").strip().lower()
    skip_codex_subtree = codex_emit_engine != "codex"

    for path in sorted(template_root.rglob("*")):
        rel = path.relative_to(template_root)
        if rel.parts and rel.parts[0] == "session-types":
            continue
        # Issue #2016: never materialize the codex-only `codex/` subtree
        # (codex AGENTS.md contract) onto a non-codex agent home.
        if skip_codex_subtree and rel.parts and rel.parts[0] == "codex":
            continue
        # v0.8.2 (#652): skip the `memory/` subtree. The per-agent memory
        # wiki is the agent's working data, not template content — it is
        # created on first agent launch by the agent's own initializer.
        # For per-UID isolated agents the controller cannot stat into the
        # 0700-mode `memory/` tree at all (PermissionError on
        # `target.exists()`), which would otherwise abort the entire
        # multi-agent migration loop in `cmd_migrate_agents` before any
        # other agent gets touched.
        if rel.parts and rel.parts[0] == "memory":
            continue
        target = agent_dir / rel
        if path.is_dir():
            if not target.exists():
                created_dirs.append(rel.as_posix())
                if not dry_run:
                    target.mkdir(parents=True, exist_ok=True)
            continue
        if rel.as_posix() == "CLAUDE.md" and target.exists():
            continue
        if target.exists():
            continue
        added_files.append(rel.as_posix())
        if dry_run:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        rendered = render_template(path.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type)
        target.write_text(rendered, encoding="utf-8")

    session_template = template_root / "session-types" / f"{session_type}.md"
    session_target = agent_dir / "SESSION-TYPE.md"
    if not session_target.exists() and session_template.exists():
        added_files.append("SESSION-TYPE.md")
        if not dry_run:
            # Issue #906: preserve prior `Onboarding State: complete` across
            # the v2 layout's source/home/workdir split before stamping the
            # fresh template. Without this, every upgrade on an already-
            # onboarded install regresses the source to `pending`, which
            # triggers recurring watchdog profile-drift tasks and flips
            # restart_readiness to onboarding-pending (the admin tmux
            # session would `stop` instead of background-restarting).
            preserve_complete = detect_prior_onboarding_complete(agent_dir)
            rendered = render_template(
                session_template.read_text(encoding="utf-8"),
                agent,
                display_name,
                role_text,
                engine,
                session_type,
            )
            if preserve_complete:
                rendered = apply_onboarding_state_complete(rendered)
            session_target.parent.mkdir(parents=True, exist_ok=True)
            session_target.write_text(rendered, encoding="utf-8")

    # Issue #2004: onboarding-state authority reconciliation. The #906 preserve
    # block above only fires when the SOURCE SESSION-TYPE.md is ABSENT (a fresh
    # scaffold). On the real-world incident — a mature install whose source
    # SESSION-TYPE.md already exists but is stuck at `pending` while completion
    # WAS performed — that block is skipped entirely, so the stale `pending`
    # and its never-cleared marker survive every upgrade. Run a marker-authority
    # pass here regardless of whether the source was re-rendered:
    #   * complete detected anywhere (marker OR any SESSION-TYPE layer) →
    #     ratchet the existing source to complete (one-way) AND repair the
    #     state markers (write onboarding-complete, clear onboarding-pending);
    #   * only a stale `onboarding-pending` and NO complete signal → AMBIGUOUS:
    #     surface a warning, NEVER silently force-complete (that would un-onboard
    #     a genuinely-abandoned fresh install).
    if session_target.exists():  # noqa: raw-pathlib-controller-only
        if detect_prior_onboarding_complete(agent_dir):
            # Ratchet an existing, drifted source SESSION-TYPE.md to complete.
            try:
                existing = session_target.read_text(encoding="utf-8", errors="ignore")
            except (OSError, PermissionError):
                existing = ""
            if existing and not re.search(
                r"^-?\s*Onboarding State:\s*complete\b", existing, re.MULTILINE | re.IGNORECASE
            ):
                repaired = apply_onboarding_state_complete(existing)
                if repaired != existing:
                    updated_files.append("SESSION-TYPE.md")
                    if not dry_run:
                        session_target.write_text(repaired, encoding="utf-8")
            if repair_onboarding_complete_markers(agent_dir, dry_run):
                updated_files.append("onboarding-complete")
        elif detect_stale_pending_onboarding(agent_dir):
            warnings.append(
                "onboarding-pending marker present with no completion signal in any "
                "SESSION-TYPE.md layer or the onboarding-complete marker — onboarding "
                "may never have recorded completion. NOT auto-completing (it could be a "
                "genuinely-abandoned fresh install). To resolve: finish onboarding, or run "
                f"`agent-bridge agent set-onboarding {agent} complete` if this install is "
                "actually operational."
            )

    claude_template = template_root / "CLAUDE.md"
    claude_target = agent_dir / "CLAUDE.md"
    if claude_template.exists() and claude_target.exists():
        rendered = render_template(claude_template.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type)
        managed_block = extract_managed_claude_block(rendered)
        if managed_block:
            original = claude_target.read_text(encoding="utf-8", errors="ignore")
            refreshed = refresh_managed_claude_block(original, managed_block)
            if refreshed != original:
                updated_files.append("CLAUDE.md")
                if not dry_run:
                    claude_target.write_text(refreshed, encoding="utf-8")

    # Issue #1809: codex AGENTS.md home-entrypoint backfill + managed-block
    # refresh. Folded into the shared helper so the daemon doc-backfill hygiene
    # pass (cmd_backfill_codex_entrypoints) applies the IDENTICAL create-if-
    # absent + marker-splice refresh between upgrades.
    # Issue #2016: gate on the roster-authoritative `codex_emit_engine`, not the
    # `detect_engine` heuristic — a claude agent whose CLAUDE.md prose trips the
    # bare-substring heuristic would otherwise get a home-ROOT codex AGENTS.md
    # here (the 2nd of the two re-emit locations). The helper is a no-op for any
    # non-codex engine, so a claude/unknown signal cleanly backfills nothing.
    entrypoint_action = backfill_codex_agents_md_home(
        agent_dir, template_root, agent, display_name, role_text, codex_emit_engine,
        session_type, dry_run,
    )
    if entrypoint_action == "backfilled":
        added_files.append("AGENTS.md")
    elif entrypoint_action == "refreshed":
        updated_files.append("AGENTS.md")

    # Issue #4769 (reverts #517): no longer auto-inject the admin
    # pair-programming SOP managed block here. The block described a
    # `<admin>-dev` codex pair that was itself auto-created by the
    # removed admin-pair backfill helper; both halves of the feature
    # retire together. Operators who explicitly register a sibling
    # dev agent can author their own pair-programming SOP in the
    # admin's CLAUDE.md.

    return AgentMigrationResult(
        agent=agent,
        added_files=added_files,
        created_dirs=created_dirs,
        updated_files=updated_files,
        session_type=session_type,
        engine=engine,
        warnings=warnings,
    )


def bridge_upgrade_target_env(target_root: Path) -> dict[str, str]:
    """Mirror bridge-upgrade.sh::bridge_upgrade_with_target_env for helpers."""
    target = str(target_root)
    return {
        "HOME": os.environ.get("HOME", ""),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "USER": os.environ.get("USER", ""),
        "SHELL": os.environ.get("SHELL", ""),
        "TERM": os.environ.get("TERM", "dumb"),
        "BRIDGE_HOME": target,
        "BRIDGE_ROSTER_FILE": f"{target}/agent-roster.sh",
        "BRIDGE_ROSTER_LOCAL_FILE": f"{target}/agent-roster.local.sh",
        "BRIDGE_STATE_DIR": f"{target}/state",
        "BRIDGE_ACTIVE_AGENT_DIR": f"{target}/state/agents",
        "BRIDGE_HISTORY_DIR": f"{target}/state/history",
        "BRIDGE_WORKTREE_META_DIR": f"{target}/state/worktrees",
        "BRIDGE_ACTIVE_ROSTER_TSV": f"{target}/state/active-roster.tsv",
        "BRIDGE_ACTIVE_ROSTER_MD": f"{target}/state/active-roster.md",
        "BRIDGE_DAEMON_PID_FILE": f"{target}/state/daemon.pid",
        "BRIDGE_DAEMON_LOG": f"{target}/state/daemon.log",
        "BRIDGE_DAEMON_CRASH_LOG": f"{target}/state/daemon-crash.log",
        "BRIDGE_TASK_DB": f"{target}/state/tasks.db",
        "BRIDGE_PROFILE_STATE_DIR": f"{target}/state/profiles",
        "BRIDGE_CRON_STATE_DIR": f"{target}/state/cron",
        "BRIDGE_CRON_HOME_DIR": f"{target}/cron",
        "BRIDGE_NATIVE_CRON_JOBS_FILE": f"{target}/cron/jobs.json",
        "BRIDGE_CRON_DISPATCH_WORKER_DIR": f"{target}/state/cron/workers",
        "BRIDGE_WORKTREE_ROOT": f"{target}/worktrees",
        "BRIDGE_AGENT_HOME_ROOT": f"{target}/agents",
        "BRIDGE_RUNTIME_ROOT": f"{target}/runtime",
        "BRIDGE_RUNTIME_SCRIPTS_DIR": f"{target}/runtime/scripts",
        "BRIDGE_RUNTIME_SKILLS_DIR": f"{target}/runtime/skills",
        "BRIDGE_RUNTIME_SHARED_DIR": f"{target}/runtime/shared",
        "BRIDGE_RUNTIME_SHARED_TOOLS_DIR": f"{target}/runtime/shared/tools",
        "BRIDGE_RUNTIME_SHARED_REFERENCES_DIR": f"{target}/runtime/shared/references",
        "BRIDGE_RUNTIME_MEMORY_DIR": f"{target}/runtime/memory",
        "BRIDGE_RUNTIME_CREDENTIALS_DIR": f"{target}/runtime/credentials",
        "BRIDGE_RUNTIME_SECRETS_DIR": f"{target}/runtime/secrets",
        "BRIDGE_RUNTIME_CONFIG_FILE": f"{target}/runtime/bridge-config.json",
        "BRIDGE_HOOKS_DIR": f"{target}/hooks",
        "BRIDGE_LOG_DIR": f"{target}/logs",
        "BRIDGE_AUDIT_LOG": f"{target}/logs/audit.jsonl",
        "BRIDGE_SHARED_DIR": f"{target}/shared",
        "BRIDGE_TASK_NOTE_DIR": f"{target}/shared/tasks",
        "BRIDGE_DASHBOARD_STATE_FILE": f"{target}/state/dashboard.json",
        "BRIDGE_DISCORD_RELAY_STATE_FILE": f"{target}/state/discord-relay.json",
        "BRIDGE_LAYOUT_RESOLVER_BYPASS": os.environ.get("BRIDGE_LAYOUT_RESOLVER_BYPASS", ""),
        "BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID": os.environ.get("BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID", ""),
        "BRIDGE_UPGRADE_CONTEXT": os.environ.get("BRIDGE_UPGRADE_CONTEXT", ""),
        # Issue #1809: entrypoint-backfill-only mode for the daemon doc-backfill
        # hygiene pass — the rematerialize helper short-circuits to the engine
        # instruction entrypoint docs when this is "1".
        "BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY": os.environ.get(
            "BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY", ""
        ),
        # Test-only iso stub passthrough so the #1809 smoke can exercise the
        # entrypoint-only mirror through the iso write path (same stubs the
        # 1636 / workdir-migrate smokes use).
        "BRIDGE_REMATERIALIZE_TEST_STUB_ISO": os.environ.get(
            "BRIDGE_REMATERIALIZE_TEST_STUB_ISO", ""
        ),
    }


def rematerialize_error_result(agent: str, source_dir: str, target_dir: str, detail: str) -> dict[str, Any]:
    return {
        "agent": agent,
        "status": "error",
        "source_dir": source_dir,
        "target_dir": target_dir,
        "updated_paths": [],
        "errors": [detail],
    }


def rematerialize_agent_identity(
    source_root: Path,
    target_root: Path,
    result: AgentMigrationResult,
    dry_run: bool,
) -> dict[str, Any]:
    helper = source_root / "lib" / "upgrade-helpers" / "rematerialize-agent-identity.sh"
    if not helper.exists():
        return rematerialize_error_result(
            result.agent,
            "",
            "",
            f"helper missing: {helper}",
        )
    changed_files = sorted(set(result.added_files + result.updated_files))
    cmd = [
        str(helper),
        str(source_root),
        str(target_root),
        result.agent,
        result.engine,
        "1" if dry_run else "0",
        *changed_files,
    ]
    proc = subprocess.run(
        cmd,
        env=bridge_upgrade_target_env(target_root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    stdout = proc.stdout.strip()
    if proc.returncode != 0:
        return rematerialize_error_result(
            result.agent,
            "",
            "",
            f"helper exited {proc.returncode}: {proc.stderr.strip() or '<no stderr>'}",
        )
    if not stdout:
        return rematerialize_error_result(result.agent, "", "", "helper emitted no JSON")
    try:
        payload = json.loads(stdout.splitlines()[-1])
    except json.JSONDecodeError as exc:
        return rematerialize_error_result(
            result.agent,
            "",
            "",
            f"helper emitted invalid JSON: {exc}: {stdout[:500]}",
        )
    if not isinstance(payload, dict):
        return rematerialize_error_result(result.agent, "", "", "helper JSON was not an object")
    # Issue #1670: pin the identity boundary. The helper is always invoked with
    # `result.agent` in the third positional slot, so the payload's "agent" must
    # come back nonempty AND equal to it. If it does not (e.g. the helper's
    # Bash 3.2 -> 4+ re-exec dropped the mandatory args and re-ran with a blank
    # agent, the historical #1670 symptom), do NOT propagate a payload that
    # blames the wrong / empty agent — convert it to a structured rematerialize
    # error keyed on the agent we actually asked for, so the upgrade JSON, the
    # backup planner, and rollback all see a coherent agent identity.
    payload_agent = payload.get("agent")
    if not isinstance(payload_agent, str) or not payload_agent or payload_agent != result.agent:
        return rematerialize_error_result(
            result.agent,
            payload.get("source_dir", "") if isinstance(payload.get("source_dir"), str) else "",
            payload.get("target_dir", "") if isinstance(payload.get("target_dir"), str) else "",
            f"helper returned mismatched agent identity (expected '{result.agent}', "
            f"got {payload_agent!r}); refusing to attribute rematerialize result to the wrong agent",
        )
    if proc.stderr.strip():
        payload.setdefault("warnings", []).append(proc.stderr.strip())
    return payload


def cmd_migrate_agents(args: argparse.Namespace) -> int:
    template_root = Path(args.source_root).expanduser() / "agents" / "_template"
    agent_root = Path(args.target_root).expanduser() / "agents"
    source_root = Path(args.source_root).expanduser().resolve()
    target_root = Path(args.target_root).expanduser().resolve()
    admin_agent = (args.admin_agent or "").strip()
    results: list[AgentMigrationResult] = []
    skipped_isolated: list[dict[str, str]] = []

    # Issue #1611: roster-restrict the loop unless the operator opts into
    # migrate-all (`--migrate-all-agents`) or no roster source is parseable
    # (the safe fallback — never skip when the roster is unknown).
    migrate_all = bool(getattr(args, "migrate_all_agents", False))
    roster_ids, roster_sources = collect_roster_ids(target_root, admin_agent)
    # Issue #2016: roster-declared engine is the authoritative signal for the
    # codex-emission gate in migrate_agent_home (do not rely on the detect_engine
    # filesystem heuristic, which incidental "Codex CLI" prose can trip). Merge
    # both roster surfaces the migrate filter already honors: the shell rosters
    # (authoritative static SSOT) layered OVER state/active-roster.tsv (which
    # carries the engine in column 2 for ACTIVE/dynamic agents that may exist
    # only there, never in a shell roster). Shell wins on conflict; the TSV fills
    # the dynamic-agent gap so the gate is authoritative for them too, not just
    # static shell-roster agents.
    roster_engines = _parse_roster_tsv_engines(target_root / "state" / "active-roster.tsv")
    roster_engines.update(collect_roster_engines(target_root))
    if migrate_all:
        roster_filtering = "disabled"
    elif not roster_sources or not roster_ids:
        roster_filtering = "unavailable"
    else:
        roster_filtering = "active"
    if roster_filtering == "unavailable":
        print(
            "[bridge-upgrade] migrate-agents: roster filtering unavailable "
            "(no parseable roster source) — migrating all agent dirs",
            file=sys.stderr,
        )

    skipped_orphans: list[str] = []
    for path in discover_agent_dirs(agent_root):
        if roster_filtering == "active" and path.name not in roster_ids:
            skipped_orphans.append(path.name)
            continue
        try:
            result = migrate_agent_home(
                path, template_root, admin_agent, args.dry_run,
                roster_engine=roster_engines.get(path.name),
            )
            result.rematerialize = rematerialize_agent_identity(source_root, target_root, result, args.dry_run)
            results.append(result)
        except PermissionError as exc:
            # v0.8.2 (#652): per-UID isolated agent home is not stat-able
            # by the controller. Skip with a structured result instead of
            # aborting the entire multi-agent loop. The agent's own first
            # launch under v0.8.0+ rebuilds whatever it needs in its
            # memory tree; the upgrader's contract for isolated agents is
            # that the controller never enters per-agent owner-only
            # subtrees. The `memory/` template-skip above prevents the
            # common path; this catch is defense-in-depth for any future
            # template addition that re-introduces a 0700 path.
            skipped_isolated.append({
                "agent": path.name,
                "reason": f"PermissionError: {exc.filename or '<unknown path>'} (per-UID isolated tree)",
            })
    def result_has_changes(item: AgentMigrationResult) -> bool:
        remat = item.rematerialize or {}
        return bool(
            item.added_files
            or item.created_dirs
            or item.updated_files
            or remat.get("updated_paths")
            or remat.get("scaffold_paths")
        )

    if skipped_orphans:
        print(
            "[bridge-upgrade] migrate-agents: skipped "
            f"{len(skipped_orphans)} non-roster dir(s): "
            f"{', '.join(sorted(skipped_orphans))}",
            file=sys.stderr,
        )

    payload = {
        "agent_count": len(results) + len(skipped_isolated),
        "migrated_count": len(results),
        "skipped_isolated_count": len(skipped_isolated),
        "skipped_isolated": skipped_isolated,
        "skipped_orphans_count": len(skipped_orphans),
        "skipped_orphans": sorted(skipped_orphans),
        "roster_filtering": roster_filtering,
        "roster_sources": roster_sources,
        "agents_with_additions": sum(1 for item in results if result_has_changes(item)),
        "added_files": sum(len(item.added_files) for item in results),
        "created_dirs": sum(len(item.created_dirs) for item in results),
        "updated_files": sum(len(item.updated_files) for item in results),
        "rematerialized_files": sum(len((item.rematerialize or {}).get("updated_paths") or []) for item in results),
        "scaffold_files": sum(len((item.rematerialize or {}).get("scaffold_paths") or []) for item in results),
        # Issue #1781: agent-written state files kept (not overwritten) but
        # still captured in the targeted backup. Surfaced for operator audit.
        "preserved_files": sum(len((item.rematerialize or {}).get("preserved_paths") or []) for item in results),
        # Issue #2004: per-agent non-fatal upgrade notes (e.g. an ambiguous
        # stale onboarding-pending marker the upgrader declined to auto-complete).
        "onboarding_warnings": [
            {"agent": item.agent, "warning": w}
            for item in results
            for w in item.warnings
        ],
        "agents": [asdict(item) for item in results],
    }
    return emit_json(payload, 0)


def resolve_backfill_engine_decision(
    roster_engine: str | None,
    detected_engine: str,
) -> tuple[str, str | None]:
    """Fail-closed engine resolution for the codex AGENTS.md doc-backfill (#1892).

    The roster engine is the source of truth. ``detected_engine`` is the
    filesystem heuristic (``detect_engine``) used ONLY to corroborate or to
    flag a disagreement — never to manufacture a positive codex signal from the
    absence of a claude one.

    Returns ``(decision, hold_reason)`` where ``decision`` is one of:
      * ``"backfill"``   — roster says codex (or roster-unknown but the heuristic
        positively detected codex AND nothing contradicts it).
      * ``"skip"``       — roster says a non-codex engine; never materialize a
        codex template on it. Absence of metadata is NOT a codex signal.
      * ``"hold-quiet"`` — roster AUTHORITATIVELY declares a non-codex engine
        (claude/other) but the filesystem heuristic detected codex. The roster
        wins: the agent stays its declared engine and the codex signal is treated
        as residue / live codex-delegation tooling, NOT an engine reassignment.
        Held fail-closed (no destructive materialization) but RECORDED QUIETLY —
        it never makes the pass non-clean, so the same roster-authoritative agent
        does NOT regenerate an identical ``[hygiene]`` task every pass (#2044).
      * ``"hold"``       — roster engine could NOT be authoritatively resolved
        (no roster declaration) yet the filesystem heuristic detected codex. This
        is genuinely ambiguous, so it stays operator-visible (task-generating):
        the engine must be resolved before any backfill. ``hold_reason`` carries
        the human-readable cause.

    Truth table (roster \\ heuristic):
      roster=codex,  heuristic=codex  -> backfill
      roster=codex,  heuristic!=codex -> backfill (roster authoritative; the
                                          heuristic is the weaker signal)
      roster=claude/other, any        -> skip if heuristic agrees (non-codex),
                                          HOLD-QUIET if heuristic=codex (roster is
                                          authoritative; quiet/no recurring task)
      roster=unknown, heuristic=codex -> HOLD (no positive roster signal; do not
                                          materialize on a filesystem guess, stay
                                          operator-visible until resolved)
      roster=unknown, heuristic!=codex-> skip (no codex signal anywhere)
    """
    roster = (roster_engine or "").strip().lower()
    detected = (detected_engine or "").strip().lower()

    # The ``unknown`` sentinel (bridge_agent_engine's miss value) is NOT a
    # positive engine declaration — normalize it to absent so it falls through to
    # the fail-closed unknown path below. Without this, a literal
    # ``BRIDGE_AGENT_ENGINE["x"]="unknown"`` (or any ``unknown`` that reaches the
    # resolver) would wrongly enter the roster-authoritative non-codex branch and
    # get the #2044 QUIET hold, suppressing the task-generating warning a
    # genuinely-unresolved engine must keep. (collect_registry_engines already
    # drops this sentinel; this is the symmetric guard for the shell-roster
    # parser + any future caller, applied at the single decision chokepoint.)
    if roster == "unknown":
        roster = ""

    if roster == "codex":
        return ("backfill", None)
    if roster and roster != "codex":
        # Roster positively declares a non-codex engine. Never materialize a
        # codex template here. If the filesystem heuristic disagrees (thinks
        # codex), the ROSTER is authoritative — the agent IS its declared engine
        # and the codex signal is stale residue or live codex-delegation tooling
        # (a claude agent's CLAUDE.md legitimately referencing codex CLI), NOT an
        # engine reassignment. Hold fail-closed but QUIETLY (#2044): a recurring
        # task-generating warning on an authoritatively-claude agent re-fires
        # every pass and never converges. The operator already knows the engine
        # (they declared it); there is nothing to action.
        if detected == "codex":
            return (
                "hold-quiet",
                f"roster engine={roster} is authoritative; filesystem heuristic "
                "detected codex residue (not an engine reassignment). Holding "
                "codex AGENTS.md backfill fail-closed; recorded quietly so it "
                "does not regenerate a recurring hygiene task (#2044)",
            )
        return ("skip", None)
    # roster engine unknown (no roster declaration parsed / agent-meta.env absent).
    # Fail-closed: absence of a positive claude signal must NEVER become a
    # positive codex signal. Only the filesystem heuristic is left, and a bare
    # filesystem guess is not strong enough to destructively materialize.
    if detected == "codex":
        return (
            "hold",
            "roster engine unknown (no roster declaration) and only a filesystem "
            "heuristic suggests codex; holding backfill until the engine is "
            "authoritatively resolvable",
        )
    return ("skip", None)


def cmd_backfill_codex_entrypoints(args: argparse.Namespace) -> int:
    """Issue #1809: focused codex AGENTS.md backfill pass for the daemon
    doc-backfill hygiene cadence.

    Narrower than `migrate-agents`: it touches ONLY the codex AGENTS.md
    instruction entrypoint (home create-if-absent + managed-block refresh via
    the shared `backfill_codex_agents_md_home` helper, then a workdir mirror via
    the existing rematerialize helper) — NOT the full per-agent template/scaffold
    migration. That keeps the periodic side-effect surface tiny while reusing the
    exact same create-if-absent + marker-splice logic the upgrade path uses
    (never a whole-file clobber; custom content below the marker is preserved).

    Roster-restricted (same `collect_roster_ids` filter migrate-agents uses) so
    orphan/test homes are never touched. Codex-only: non-codex agents are
    skipped. Emits a compact summary JSON the daemon uses to decide non-clean
    and render the `[hygiene]` task body.
    """
    template_root = Path(args.source_root).expanduser() / "agents" / "_template"
    agent_root = Path(args.target_root).expanduser() / "agents"
    source_root = Path(args.source_root).expanduser().resolve()
    target_root = Path(args.target_root).expanduser().resolve()
    admin_agent = (args.admin_agent or "").strip()
    dry_run = bool(args.dry_run)

    roster_ids, roster_sources = collect_roster_ids(target_root, admin_agent)
    roster_filtering = "active" if (roster_sources and roster_ids) else "unavailable"
    # #1892: roster engine is the source of truth. When agent-meta.env is absent
    # the daemon's in-memory engine map is gone, so resolve the declared engine
    # statically from the roster shell files. Absence of a positive claude signal
    # must NEVER be inferred as codex (fail-closed) — see resolve_backfill_engine_decision.
    roster_engines = collect_roster_engines(target_root)
    # #1956: a dynamic agent (source=dynamic) is never in the static roster, so
    # the map above has no entry for it and #1892 would hold it forever. The
    # daemon-published state/active-roster.tsv carries that agent's AUTHORITATIVE
    # engine (the `--codex`/`--claude` launch flag, via bridge_agent_engine). Use
    # it as a strict FALLBACK below the static roster: the roster wins for any id
    # it declares (SoT preserved); the registry only fills the dynamic-agent gap.
    # This is exact per-id (no heuristic), so a registry-claude dynamic agent
    # still resolves to claude and is never codex-backfilled (#1928 / T3 guard).
    registry_engines = collect_registry_engines(target_root)

    backfilled: list[str] = []
    refreshed: list[str] = []
    held: list[dict[str, str]] = []
    # Issue #2044: QUIET holds — a roster-AUTHORITATIVE non-codex agent (claude)
    # whose filesystem heuristic still detects codex residue. The roster wins, so
    # this is held fail-closed (no destructive materialization) but recorded here
    # SEPARATELY from `held`: it must NOT make the pass non-clean, otherwise the
    # same authoritatively-claude agent regenerates an identical `[hygiene]` task
    # every pass (the recurring-4x bug). Kept in the summary for transparency only.
    held_quiet: list[dict[str, str]] = []
    # Issue #1906: REPORT-ONLY residue list. A correct non-codex agent that
    # still carries a stale Codex-contract AGENTS.md (a pre-#1896 mis-scaffold
    # residue) is invisible to the `skip` path — `detect_engine` keys on
    # CLAUDE.md only, so a stray codex AGENTS.md never flips the decision off
    # `skip` and the file is never inspected. Flag it for the operator; NEVER
    # delete/rename/edit it here (removal stays a deliberate operator action).
    engine_mismatch_docs: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    checked = 0

    for path in discover_agent_dirs(agent_root):
        if roster_filtering == "active" and path.name not in roster_ids:
            continue
        try:
            session_type = detect_session_type(path, admin_agent)
            detected_engine = detect_engine(path, session_type)
            # Static roster is the SoT; the registry (active-roster.tsv) is a
            # fallback that only supplies an engine for a dynamic agent the
            # roster never declares (#1956). Never the other way round — a
            # roster declaration always wins over the registry.
            roster_engine = roster_engines.get(path.name)
            if roster_engine is None:
                roster_engine = registry_engines.get(path.name)
            decision, hold_reason = resolve_backfill_engine_decision(
                roster_engine, detected_engine,
            )
            if decision == "hold":
                held.append({
                    "agent": path.name,
                    "roster_engine": (roster_engine or "unknown"),
                    "detected_engine": detected_engine,
                    "reason": hold_reason or "engine disagreement; held",
                })
                continue
            if decision == "hold-quiet":
                # Issue #2044: roster-authoritative claude vs detected codex.
                # Held fail-closed but QUIET — recorded for transparency, never
                # contributes to non-clean (no recurring hygiene task).
                held_quiet.append({
                    "agent": path.name,
                    "roster_engine": (roster_engine or "unknown"),
                    "detected_engine": detected_engine,
                    "reason": hold_reason or "roster-authoritative; held quietly",
                })
                continue
            if decision != "backfill":
                # decision == "skip": roster declares a non-codex engine (or no
                # engine signal). #1906 residue scan — REPORT-ONLY. Only a
                # POSITIVE non-codex roster engine is authoritative enough to
                # call an existing Codex-contract AGENTS.md "mismatched"; an
                # engine-unknown skip is not (mirrors the fail-closed stance,
                # and the disagreement-with-a-codex-CLAUDE.md case already
                # lands in `hold`, never here). Note: a non-codex agent's
                # compat CLAUDE.md is legitimate (lib/bridge-agent-layout.sh
                # codex read-target), so the symmetric "stray CLAUDE.md on a
                # codex agent" is NOT a mismatch and is intentionally out of
                # scope.
                roster = (roster_engine or "").strip().lower()
                if roster and roster != "codex":
                    # Issue #2016: scan BOTH spurious-codex-contract locations a
                    # pre-gate install could carry on a non-codex agent — the
                    # home-ROOT `AGENTS.md` (#1906) AND the `codex/AGENTS.md` the
                    # old un-gated migrate rglob copied (the latent 2nd copy the
                    # cm-prod 2-location finding surfaced; nothing flagged it, so
                    # it survived past workdir-only cleanups). Report-only for
                    # both: the residue is runtime-harmless and removal stays a
                    # deliberate operator action (the #1906 contract), but the
                    # operator now SEES the surviving copy instead of it lurking.
                    for residue_rel in ("AGENTS.md", "codex/AGENTS.md"):
                        residue_md = path / residue_rel
                        if agents_md_is_codex_contract(residue_md):
                            engine_mismatch_docs.append({
                                "agent": path.name,
                                "roster_engine": roster,
                                "doc": residue_rel,
                                "detected_contract": "codex",
                                "path": str(residue_md),
                            })
                continue
            # Roster is authoritative: materialize the codex template under the
            # roster-declared engine (`codex`), never the filesystem heuristic.
            engine = "codex"
            checked += 1
            display_name = detect_display_name(path)
            role_text = detect_role_text(path)
            action = backfill_codex_agents_md_home(
                path, template_root, path.name, display_name, role_text,
                engine, session_type, dry_run,
            )
            if action == "backfilled":
                backfilled.append(path.name)
            elif action == "refreshed":
                refreshed.append(path.name)
            else:
                # No home change — nothing to mirror. Skip the workdir pass so a
                # clean re-run stays a true no-op.
                continue
            # Mirror the freshly-backfilled/refreshed home entrypoint into the
            # workdir via the existing rematerialize helper, scoped to the
            # entrypoint docs only (BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY).
            mirror = AgentMigrationResult(
                agent=path.name,
                added_files=[],
                created_dirs=[],
                updated_files=[],
                session_type=session_type,
                engine=engine,
            )
            remat = rematerialize_agent_identity_entrypoint_only(
                source_root, target_root, mirror, dry_run,
            )
            remat_errors = (remat or {}).get("errors") or []
            for err in remat_errors:
                errors.append({"agent": path.name, "error": str(err)})
        except PermissionError as exc:
            errors.append({
                "agent": path.name,
                "error": f"PermissionError: {exc.filename or '<unknown path>'} (per-UID isolated tree)",
            })
        except OSError as exc:
            errors.append({"agent": path.name, "error": f"OSError: {exc}"})

    # #1892: a held agent (engine could not be authoritatively resolved) is
    # non-clean so the daemon files the operator-visible `[hygiene]` warning task
    # instead of silently materializing the wrong template. #1906: an
    # engine-mismatched doc (stale Codex-contract AGENTS.md on a non-codex agent)
    # is non-clean too, so the same `[hygiene]` surface flags the residue for an
    # operator to remove. #2044: `held_quiet` (roster-AUTHORITATIVE non-codex
    # agent with codex residue) is DELIBERATELY excluded — it must never make the
    # pass non-clean, or the same authoritatively-claude agent regenerates an
    # identical recurring hygiene task every pass (idempotent convergence).
    non_clean = bool(
        backfilled or refreshed or held or engine_mismatch_docs or errors
    )
    payload = {
        "dry_run": dry_run,
        "codex_agents_checked": checked,
        "roster_filtering": roster_filtering,
        "roster_sources": roster_sources,
        "backfilled": sorted(backfilled),
        "refreshed": sorted(refreshed),
        "backfilled_count": len(backfilled),
        "refreshed_count": len(refreshed),
        "held": sorted(held, key=lambda h: h["agent"]),
        "held_count": len(held),
        "held_quiet": sorted(held_quiet, key=lambda h: h["agent"]),
        "held_quiet_count": len(held_quiet),
        "engine_mismatch_docs": sorted(
            engine_mismatch_docs, key=lambda d: d["agent"]
        ),
        "engine_mismatch_docs_count": len(engine_mismatch_docs),
        "errors": errors,
        "non_clean": non_clean,
    }
    return emit_json(payload, 0)


def rematerialize_agent_identity_entrypoint_only(
    source_root: Path,
    target_root: Path,
    result: AgentMigrationResult,
    dry_run: bool,
) -> dict[str, Any]:
    """Run the rematerialize helper in entrypoint-backfill-only mode (Issue
    #1809) — mirror ONLY the engine instruction entrypoint home->workdir, not
    the full identity/users/scaffold sync. A thin wrapper around
    `rematerialize_agent_identity` that sets BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY
    so the helper short-circuits to the entrypoint docs.
    """
    prior = os.environ.get("BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY")
    os.environ["BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY"] = "1"
    try:
        return rematerialize_agent_identity(source_root, target_root, result, dry_run)
    finally:
        if prior is None:
            os.environ.pop("BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY", None)
        else:
            os.environ["BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY"] = prior


def conflict_backup_relpath(relpath: str) -> str:
    return (Path(relpath).parent / conflict_backup_path(Path(relpath)).name).as_posix()


def _record_backup_skip(
    skipped: list[dict[str, str]] | None,
    relpath: str,
    filename: str | None,
) -> None:
    """Record a backup entry the controller could not stat (iso boundary).

    Issue #1635: warn on stderr and append a structured skip record so the
    operator can see exactly which iso-owned path was skipped. The agent's own
    runtime owns these files; the controller's backup contract for isolated
    agents is that owner-only subtrees are not entered.
    """
    print(
        "[bridge-upgrade] backup-live: skipping unreadable iso-owned entry "
        f"{filename or relpath} (per-UID isolated tree; controller not in group)",
        file=sys.stderr,
    )
    if skipped is not None:
        skipped.append({
            "path": relpath,
            "reason": f"PermissionError: {filename or relpath} (per-UID isolated tree)",
        })


class _IsoPermissionSkip(Exception):
    """Raised by _probe_live_path when a path is unreadable for iso reasons."""

    def __init__(self, filename: str | None) -> None:
        super().__init__(filename or "")
        self.filename = filename


def _probe_live_path(path: Path) -> tuple[bool, bool, bool]:
    """Version-independent existence probe → (present, is_symlink, is_dir).

    Issue #1635 r5: `Path.exists()` / `Path.is_symlink()` SWALLOW PermissionError
    and return False on Python 3.14+ (they only re-raise on 3.13 and earlier).
    Relying on those raising would, on 3.14, silently record an unreadable
    iso-owned file as `state=absent` instead of skipping it — corrupting rollback
    metadata. Use raw `os.lstat` so the EACCES boundary is observed identically
    on every Python: FileNotFoundError → not present; PermissionError / EACCES →
    raise `_IsoPermissionSkip` (the iso boundary); anything else bubbles.
    """
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return (False, False, False)
    except NotADirectoryError:
        # A component of the path is a file, so the target cannot exist.
        return (False, False, False)
    except PermissionError as exc:
        raise _IsoPermissionSkip(exc.filename or str(path)) from exc
    except OSError as exc:
        if exc.errno == errno.EACCES:
            raise _IsoPermissionSkip(exc.filename or str(path)) from exc
        raise
    is_symlink = S_ISLNK(st.st_mode)
    is_dir = S_ISDIR(st.st_mode) and not is_symlink
    return (True, is_symlink, is_dir)


def build_backup_entries(
    target_root: Path,
    analysis_payload: dict[str, Any],
    migration_payload: dict[str, Any],
    skipped_isolated: list[dict[str, str]] | None = None,
) -> list[dict[str, str]]:
    entries: dict[str, dict[str, str]] = {}

    def remember(relpath: str, expected_kind: str = "file") -> None:
        relpath = relpath.strip().lstrip("./")
        if not relpath:
            return
        live_path = target_root / relpath
        # Issue #1635: under v2 isolation the controller is intentionally not a
        # member of the iso agent's group, so statting an iso-owned profile file
        # (e.g. `agents/<a>/workdir/SOUL.md`, mode 0600) or traversing an
        # owner-only `0700` subtree raises PermissionError. That is an EXPECTED
        # boundary, not a fatal upgrade error — graceful-skip the entry (warn +
        # record) instead of aborting the whole backup/upgrade. Mirrors the
        # `cmd_migrate_agents` and daily-backup `skipped_isolated` patterns.
        # Only genuine permission failures are demoted; a controller-readable
        # file that errors for any other reason still bubbles up so we never
        # silently drop a backup we COULD have taken.
        try:
            present, _is_symlink, is_dir = _probe_live_path(live_path)
        except _IsoPermissionSkip as skip:
            _record_backup_skip(skipped_isolated, relpath, skip.filename)
            return
        if present:
            kind = "dir" if is_dir else "file"
            entries[relpath] = {"path": relpath, "state": "present", "kind": kind}
            return
        current = entries.get(relpath)
        if current and current.get("state") == "present":
            return
        entries[relpath] = {"path": relpath, "state": "absent", "kind": expected_kind}

    for item in analysis_payload.get("files", []):
        strategy = str(item.get("strategy") or "")
        relpath = str(item.get("path") or "")
        if strategy not in {"deploy_upstream", "manual_merge"}:
            continue
        remember(relpath, "file")
        if str(item.get("classification") or "") == "merge_required":
            remember(conflict_backup_relpath(relpath), "file")

    for agent_payload in migration_payload.get("agents", []):
        agent = str(agent_payload.get("agent") or "").strip()
        if not agent:
            continue
        prefix = f"agents/{agent}"
        for relpath in agent_payload.get("updated_files", []):
            remember(f"{prefix}/{relpath}", "file")
        for relpath in agent_payload.get("added_files", []):
            remember(f"{prefix}/{relpath}", "file")
        for relpath in agent_payload.get("created_dirs", []):
            remember(f"{prefix}/{relpath}", "dir")
        rematerialize_payload = agent_payload.get("rematerialize") or {}
        if isinstance(rematerialize_payload, dict):
            for relpath in rematerialize_payload.get("updated_paths") or []:
                remember(str(relpath), "file")
            # Issue #1636: scaffolding files newly materialized in the workdir
            # are add-missing-only (absent in live pre-apply); record them so a
            # rollback removes them, mirroring the rematerialize updated_paths.
            for relpath in rematerialize_payload.get("scaffold_paths") or []:
                remember(str(relpath), "file")
            # Issue #1781: agent-written state files (workdir MEMORY.md,
            # users/<id>/MEMORY.md) are NEVER overwritten by rematerialization,
            # but they must stay in the targeted backup set regardless of the
            # fix — the issue credits that backup for the full recovery of the
            # 13 clobbered agents. Capture the live (current) workdir copy so a
            # future regression that re-introduces the home->workdir clobber is
            # still recoverable, and so an operator-driven rollback restores the
            # exact pre-upgrade memory.
            for relpath in rematerialize_payload.get("preserved_paths") or []:
                remember(str(relpath), "file")

    remember("state/upgrade/last-upgrade.json", "file")
    return [entries[key] for key in sorted(entries)]


def _is_permission_error(exc: BaseException) -> bool:
    """True iff exc (or every shutil.Error member) is a genuine permission failure.

    Issue #1635: `shutil.copytree` wraps per-member failures in a `shutil.Error`
    whose args carry `(src, dst, why)` tuples; the underlying error is usually a
    `PermissionError` but may surface as a raw `OSError(EACCES)`. Treat all of
    those as the iso boundary; everything else must still abort.
    """
    if isinstance(exc, PermissionError):
        return True
    if isinstance(exc, OSError) and exc.errno == errno.EACCES:
        return True
    if isinstance(exc, shutil.Error):
        # copytree's Error.args[0] is a list of (src, dst, why) triples where
        # `why` is the str() of the original exception. Be conservative: only
        # treat it as a permission boundary when EVERY recorded failure looks
        # like an EACCES/permission denial, so a mixed batch still aborts.
        records = exc.args[0] if exc.args else []
        if not isinstance(records, list) or not records:
            return False
        for rec in records:
            why = str(rec[2]) if isinstance(rec, (list, tuple)) and len(rec) >= 3 else str(rec)
            if "Permission denied" not in why and "[Errno 13]" not in why:
                return False
        return True
    return False


def _perm_error_blamed_paths(exc: BaseException) -> list[str]:
    """Best-effort list of EVERY filesystem path a permission error touches.

    For a plain OSError/PermissionError that is `exc.filename` (and `filename2`).
    For a `shutil.Error` (copytree per-member batch) each recorded triple is
    `(src, dst, why)` — we collect BOTH `src` AND `dst`, because a nested
    DESTINATION EACCES inside `copytree` surfaces at index 1 (Issue #1635 r4).
    Used to tell a SOURCE-side iso skip from a DESTINATION-side backup write
    failure (Issue #1635 r3): only a failure entirely on the source side is the
    iso boundary; any path under the backup dir must still abort.
    """
    paths: list[str] = []
    if isinstance(exc, shutil.Error):
        records = exc.args[0] if exc.args else []
        if isinstance(records, list):
            for rec in records:
                if isinstance(rec, (list, tuple)):
                    # rec == (src, dst, why); record src and dst so a dest-side
                    # EACCES is visible to the discriminator.
                    if len(rec) >= 1 and rec[0]:
                        paths.append(str(rec[0]))
                    if len(rec) >= 2 and rec[1]:
                        paths.append(str(rec[1]))
        return paths
    if isinstance(exc, OSError):
        if exc.filename:
            paths.append(str(exc.filename))
        # filename2 is the dest on dual-path ops (rename/link); include it so a
        # dest-side EACCES is visible to the source/dest discriminator.
        if getattr(exc, "filename2", None):
            paths.append(str(exc.filename2))
    return paths


def _is_under(path_str: str, root: Path) -> bool:
    try:
        Path(path_str).resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError):
        return False


def _is_source_side_perm_skip(
    exc: BaseException,
    src: Path,
    backup_root: Path,
) -> bool:
    """True iff exc is a genuine permission failure on the SOURCE (iso) tree.

    Issue #1635 r3: `shutil.copytree`/`copy2` read the source AND write the
    destination in one call, so a single try/except cannot syntactically split
    them. Discriminate by the blamed path instead: an EACCES on a path under
    `backup_root` is a destination write failure (operator's backup dir is not
    writable) and MUST abort — we never silently drop a controller-readable
    backup. An EACCES on the source path (or any path NOT under backup_root) is
    the expected iso owner-only boundary and is graceful-skipped.
    """
    if not _is_permission_error(exc):
        return False
    blamed = _perm_error_blamed_paths(exc)
    if not blamed:
        # No path attribution: we cannot PROVE the failure was source-side, so
        # abort rather than risk silently dropping a readable backup. (Every
        # OSError our copy ops raise carries .filename, and shutil.Error always
        # records member triples, so this branch is defensive only.)
        return False
    for path_str in blamed:
        if _is_under(path_str, backup_root):
            # A destination write failure is in the batch (src OR dst side) —
            # abort, do not skip; never silently drop a readable backup.
            return False
    return True


def copy_live_backup(
    target_root: Path,
    backup_root: Path,
    entries: list[dict[str, str]] | None = None,
    skipped_isolated: list[dict[str, str]] | None = None,
) -> None:
    backup_live = backup_root / "live"
    backup_live.mkdir(parents=True, exist_ok=True)
    if entries is not None:
        # Targeted snapshot: copy exactly the recorded present entries. Iso-owned
        # entries the scan could not stat were already dropped + recorded by
        # build_backup_entries, so they never reach here. But a directory entry
        # can be stat-able (recorded present) yet not traversable for the copy —
        # Issue #1635: graceful-skip the per-entry copy on a genuine permission
        # failure (warn + record), re-raising anything else.
        for entry in entries:
            if entry.get("state") != "present":
                continue
            relpath = str(entry["path"])
            src = target_root / relpath
            dst = backup_live / relpath
            # Version-independent stat gate (Issue #1635 r5): probe the source
            # before copying so an iso-unreadable path is skipped identically on
            # every Python, not silently treated as absent on 3.14+.
            try:
                present, src_is_symlink, src_is_dir = _probe_live_path(src)
            except _IsoPermissionSkip as skip:
                # Issue #1635 r6: demote the manifest entry so it no longer claims
                # a `present` backup that was never copied. rollback ignores the
                # `skipped_isolated` state (it is neither restored nor deleted),
                # so the live iso file is left untouched.
                entry["state"] = "skipped_isolated"
                _record_backup_skip(skipped_isolated, relpath, skip.filename)
                continue
            if not present:
                continue
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                if src_is_dir:
                    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
                else:
                    shutil.copy2(src, dst, follow_symlinks=False)
            except (PermissionError, OSError, shutil.Error) as exc:
                # Source-side iso EACCES → skip; destination (backup dir) write
                # failure → re-raise (never silently drop a readable backup).
                if _is_source_side_perm_skip(exc, src, backup_root):
                    entry["state"] = "skipped_isolated"
                    _record_backup_skip(skipped_isolated, relpath, getattr(exc, "filename", None))
                    continue
                raise
        return
    for child in sorted(target_root.iterdir()):
        if child.name == "backups":
            continue
        dst = backup_live / child.name
        if child.is_dir():
            shutil.copytree(child, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(child, dst, follow_symlinks=False)


# --- daily-backup constants -------------------------------------------------
#
# All daily-backup behavior funnels through `create_daily_backup_archive` and
# `cmd_daily_backup_live` below. The constants here exist so smoke tests and
# operators can grep the surface area in one place.

# Path-prefix excludes (root-anchored under target_root). The tar walk drops
# the entire subtree whenever a path's leading components match any tuple.
DAILY_BACKUP_HARDCODED_ROOT_EXCLUDES: tuple[tuple[str, ...], ...] = (
    ("logs",),
    ("worktrees",),
    ("runtime", "assets"),
    ("runtime", "media"),
    ("runtime", "extensions"),
    (".claude", "worktrees"),
    # state/backup-snapshots/ is excluded from the *walk* so prior days'
    # SQL dumps do not bloat each tarball; today's dump is added back as
    # an explicit member after the walk completes.
    ("state", "backup-snapshots"),
)

# Path-part excludes: drop any path that contains one of these components at
# any depth (mirrors the legacy __pycache__ skip). Cheap defense against
# committing or backing up vendored / generated trees. Entries containing a
# "/" match a consecutive sequence of components (e.g. "plugins/cache" matches
# .../<anything>/plugins/cache/... so the agent-name path segment doesn't
# matter). Issue #974: "plugins/cache" excludes the Claude plugin cache
# (~100-300 MB per agent home, 1+ GB on a 6-agent install, fully regenerable)
# which otherwise pushes the daily-backup walk past the default timeout.
DAILY_BACKUP_PATH_PART_EXCLUDES: tuple[str, ...] = (
    "__pycache__",
    "node_modules",
    "plugins/cache",
    # Issue #1462: regenerable per-agent trees that otherwise blow the walk
    # timeout on multi-agent installs (same any-depth mechanism as #974).
    # The agent-sdk venv is rebuilt on demand; the claude CLI versions cache
    # is re-downloaded — neither is restore-critical.
    ".claude/security/agent-sdk-venv",
    ".local/share/claude/versions",
)

# Raw sqlite databases that must never enter the tarball — they're handled
# via online snapshot dumps instead. Keep the list small and explicit; new
# entries should land with a deliberate review of their restore semantics.
DAILY_BACKUP_RAW_SQLITE_EXCLUDES: tuple[str, ...] = (
    "state/tasks.db",
    "state/tasks.db-wal",
    "state/tasks.db-shm",
    "state/tasks.db-journal",
)

# (relpath under target_root, dump filename stem). One entry per database we
# snapshot. Add new ones only after measuring size + verifying restore path.
DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS: tuple[tuple[str, str], ...] = (
    ("state/tasks.db", "tasks"),
)

DAILY_BACKUP_SNAPSHOT_DIR_REL = "state/backup-snapshots"
# Issue #979: operator-facing persistent exclude config. One relpath per line,
# `#`-prefixed and blank lines ignored. Read in addition to (union with) the
# BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS env var and the hardcoded excludes — no
# shell eval, so it's editable with a plain editor and survives upgrades.
DAILY_BACKUP_EXCLUDES_CONF_REL = "state/daily-backup/excludes.conf"
DAILY_BACKUP_LOCK_FILENAME = ".daily-backup.lock"
DAILY_BACKUP_TMP_GLOB = "*.tgz.tmp.*"
DAILY_BACKUP_FREE_SPACE_FLOOR_BYTES = 100 * 1024 * 1024  # 100 MiB


def daily_backup_archive_name(day: date) -> str:
    return f"agent-bridge-{day.isoformat()}.tgz"


def parse_daily_backup_archive_date(name: str) -> date | None:
    match = re.fullmatch(r"agent-bridge-(\d{4}-\d{2}-\d{2})\.tgz", name)
    if not match:
        return None
    try:
        return date.fromisoformat(match.group(1))
    except ValueError:
        return None


def daily_backup_sqlite_snapshot_filename(stem: str, day: date) -> str:
    return f"{stem}-{day.isoformat()}.sql.gz"


def parse_daily_backup_sqlite_snapshot_date(stem: str, name: str) -> date | None:
    pattern = re.compile(rf"{re.escape(stem)}-(\d{{4}}-\d{{2}}-\d{{2}})\.sql\.gz")
    match = pattern.fullmatch(name)
    if not match:
        return None
    try:
        return date.fromisoformat(match.group(1))
    except ValueError:
        return None


def _parse_extra_excluded_roots(value: str | None) -> list[tuple[str, ...]]:
    # Accepts colon- or comma-separated relpaths from
    # BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS. Each entry is normalized into a
    # tuple of path parts the walk-time skip can match against. Empty or
    # whitespace-only entries are dropped.
    if not value:
        return []
    raw_entries: list[str] = []
    for piece in value.replace(",", ":").split(":"):
        piece = piece.strip().strip("/")
        if not piece:
            continue
        raw_entries.append(piece)
    parsed: list[tuple[str, ...]] = []
    for entry in raw_entries:
        parts = tuple(part for part in Path(entry).parts if part not in ("", "."))
        if parts:
            parsed.append(parts)
    return parsed


def _parse_excludes_conf_file(conf_path: Path) -> list[tuple[str, ...]]:
    # Issue #979: parse the operator-facing excludes.conf — one relpath per
    # line, `#`-prefixed lines and blank lines ignored, leading/trailing
    # whitespace stripped. Each surviving line is normalized through
    # `_parse_extra_excluded_roots` so it produces the same root tuples as the
    # env var. A missing or unreadable file is treated as "no excludes".
    try:
        raw = conf_path.read_text(encoding="utf-8")
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError:
        return []
    parsed: list[tuple[str, ...]] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parsed.extend(_parse_extra_excluded_roots(stripped))
    return parsed


def resolve_daily_backup_excluded_roots(
    target_root: Path,
    backup_dir: Path,
    *,
    extra_excludes_env: str | None = None,
) -> list[tuple[str, ...]]:
    # Excluded roots are the UNION of three sources, none of which overrides
    # another (Issue #979):
    #   1. DAILY_BACKUP_HARDCODED_ROOT_EXCLUDES — baked-in defaults.
    #   2. BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS env var — one-shot / daemon-env.
    #   3. <target_root>/state/daily-backup/excludes.conf — operator-facing
    #      persistent config, the recommended way to set excludes permanently.
    # The file path derives from target_root so isolated-BRIDGE_HOME tests and
    # non-standard installs resolve it correctly. Order-equivalent duplicates
    # are dropped while preserving first-seen order.
    excluded: list[tuple[str, ...]] = list(DAILY_BACKUP_HARDCODED_ROOT_EXCLUDES)
    try:
        relative_backup_dir = backup_dir.resolve().relative_to(target_root.resolve())
    except ValueError:
        relative_backup_dir = None
    if relative_backup_dir is not None and relative_backup_dir.parts:
        excluded.append(relative_backup_dir.parts)
    if extra_excludes_env is None:
        extra_excludes_env = os.environ.get("BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS", "")
    excluded.extend(_parse_extra_excluded_roots(extra_excludes_env))
    excluded.extend(
        _parse_excludes_conf_file(target_root / DAILY_BACKUP_EXCLUDES_CONF_REL)
    )
    deduped: list[tuple[str, ...]] = []
    seen: set[tuple[str, ...]] = set()
    for parts in excluded:
        if parts in seen:
            continue
        seen.add(parts)
        deduped.append(parts)
    return deduped


def should_skip_daily_backup_relpath(
    relpath: Path,
    excluded_roots: list[tuple[str, ...]],
    *,
    path_part_excludes: tuple[str, ...] = DAILY_BACKUP_PATH_PART_EXCLUDES,
) -> bool:
    parts = relpath.parts
    if not parts:
        return False
    for skip_part in path_part_excludes:
        # Multi-component entry (e.g. "plugins/cache"): match a consecutive
        # subsequence anywhere in the path. Single-component entries keep
        # the legacy fast-path `in parts` check.
        if "/" in skip_part:
            sub = tuple(p for p in skip_part.split("/") if p)
            if sub:
                n = len(sub)
                for i in range(len(parts) - n + 1):
                    if parts[i : i + n] == sub:
                        return True
        elif skip_part in parts:
            return True
    relpath_posix = relpath.as_posix()
    for raw_relpath in DAILY_BACKUP_RAW_SQLITE_EXCLUDES:
        if relpath_posix == raw_relpath:
            return True
    for root_parts in excluded_roots:
        if len(parts) >= len(root_parts) and parts[: len(root_parts)] == root_parts:
            return True
    return False


def iter_daily_backup_members(
    target_root: Path,
    backup_dir: Path,
    *,
    extra_excludes_env: str | None = None,
) -> list[tuple[Path, str]]:
    excluded_roots = resolve_daily_backup_excluded_roots(
        target_root, backup_dir, extra_excludes_env=extra_excludes_env
    )
    members: list[tuple[Path, str]] = []

    for root, dirnames, filenames in os.walk(target_root, topdown=True, followlinks=False):
        root_path = Path(root)
        rel_root = root_path.relative_to(target_root)

        kept_dirs: list[str] = []
        for dirname in sorted(dirnames):
            rel_dir = rel_root / dirname if rel_root.parts else Path(dirname)
            if should_skip_daily_backup_relpath(rel_dir, excluded_roots):
                continue
            kept_dirs.append(dirname)
            members.append((root_path / dirname, rel_dir.as_posix()))
        dirnames[:] = kept_dirs

        for filename in sorted(filenames):
            rel_file = rel_root / filename if rel_root.parts else Path(filename)
            if should_skip_daily_backup_relpath(rel_file, excluded_roots):
                continue
            members.append((root_path / filename, rel_file.as_posix()))

    return members


def _resolve_grace_seconds(override: int | None = None) -> int:
    # bug #507: stale-tmp reaper must not unlink an in-flight peer's tmp
    # file, so only files older than (daemon_timeout + grace) are removed.
    # Issue #745: default raised 180 -> 360 to track the daemon-side
    # BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS default bump (120 -> 300) plus
    # the original 60s slack. Issue #975: bumped again 360 -> 660 to track
    # the timeout default bump (300 -> 600); preserves the 60s slack.
    if override is not None:
        return max(0, int(override))
    raw = os.environ.get("BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS", "")
    if raw.isdigit():
        return max(0, int(raw))
    return 660


def reap_stale_daily_backup_tmp(
    backup_dir: Path,
    *,
    grace_seconds: int | None = None,
    now_ts: float | None = None,
) -> list[str]:
    if not backup_dir.exists():
        return []
    grace = _resolve_grace_seconds(grace_seconds)
    now_ts = now_ts if now_ts is not None else _now_seconds()
    reaped: list[str] = []
    for path in backup_dir.glob(DAILY_BACKUP_TMP_GLOB):
        if not path.is_file():
            continue
        try:
            mtime = path.stat().st_mtime
        except FileNotFoundError:
            continue
        if (now_ts - mtime) < grace:
            continue
        try:
            path.unlink()
        except FileNotFoundError:
            continue
        except OSError:
            # Permission / busy file: leave it; cleanup helper will surface
            # it to the operator. Don't escalate from inside the backup
            # write path.
            continue
        reaped.append(str(path))
    return reaped


def _now_seconds() -> float:
    # Indirected so tests can monkeypatch the clock.
    return datetime.now(timezone.utc).timestamp()


def _resolve_free_bytes_override() -> int | None:
    raw = os.environ.get("BRIDGE_DAILY_BACKUP_FREE_BYTES_OVERRIDE", "")
    if raw == "":
        return None
    try:
        return max(0, int(raw))
    except ValueError:
        return None


def _previous_archive_size_bytes(backup_dir: Path) -> int:
    largest = 0
    if not backup_dir.exists():
        return largest
    for path in backup_dir.iterdir():
        if not path.is_file():
            continue
        if parse_daily_backup_archive_date(path.name) is None:
            continue
        try:
            size = path.stat().st_size
        except FileNotFoundError:
            continue
        if size > largest:
            largest = size
    return largest


def check_daily_backup_free_space(
    backup_dir: Path,
    *,
    floor_bytes: int = DAILY_BACKUP_FREE_SPACE_FLOOR_BYTES,
) -> tuple[bool, int, int]:
    """Return (ok, free_bytes, needed_bytes).

    needed = max(prev_largest_archive * 1.5, floor_bytes). On a fresh install
    with no prior archives, the floor governs. The caller is expected to
    short-circuit with `outcome=skipped_disk_full` when ok=False.
    """
    override = _resolve_free_bytes_override()
    if override is not None:
        free_bytes = override
    else:
        backup_dir.mkdir(parents=True, exist_ok=True)
        try:
            free_bytes = shutil.disk_usage(backup_dir).free
        except (FileNotFoundError, PermissionError):
            free_bytes = 0
    prev = _previous_archive_size_bytes(backup_dir)
    needed = max(int(prev * 1.5), floor_bytes)
    return (free_bytes >= needed, int(free_bytes), int(needed))


@contextlib.contextmanager
def acquire_daily_backup_lock(backup_dir: Path) -> Iterator[bool]:
    """Yield True if exclusive lock acquired, False if another writer holds it.

    Uses fcntl.flock on a sentinel file inside backup_dir. Non-blocking — a
    contended attempt yields False and the caller should report
    `outcome=skipped_concurrent` rather than fight the peer.
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    lock_path = backup_dir / DAILY_BACKUP_LOCK_FILENAME
    handle = None
    try:
        handle = open(lock_path, "a+")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                yield False
                return
            raise
        yield True
    finally:
        if handle is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            handle.close()


def _atomic_replace(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)


def _fsync_path(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


# Issue #1041: `sqlite3.Connection.iterdump()` emits the internal
# `sqlite_sequence` maintenance statements (DELETE/INSERT) up front — before
# the `CREATE TABLE` of the AUTOINCREMENT tables that cause SQLite to
# auto-create `sqlite_sequence`. A stdlib `executescript` restore of that
# stream therefore fails with `no such table: sqlite_sequence`. Matches only
# the top-level maintenance statements (a `CREATE TRIGGER` body that mentions
# the table is left in place).
_SQLITE_SEQUENCE_MAINT_RE = re.compile(
    r'^\s*(?:DELETE\s+FROM|INSERT\s+INTO|UPDATE)\s+"?sqlite_sequence"?\b',
    re.IGNORECASE,
)


def _reorder_iterdump_for_restore(lines: Iterator[str]) -> list[str]:
    """Reorder an ``iterdump()`` stream so it restores via ``executescript``.

    Defers every ``sqlite_sequence`` maintenance statement to just before the
    final ``COMMIT;`` — by that point every AUTOINCREMENT table (and thus the
    auto-created ``sqlite_sequence`` table) exists. All other statements keep
    their original relative order.
    """
    head: list[str] = []
    deferred: list[str] = []
    commit: list[str] = []
    for line in lines:
        if _SQLITE_SEQUENCE_MAINT_RE.match(line):
            deferred.append(line)
        elif line.strip() == "COMMIT;":
            commit.append(line)
        else:
            head.append(line)
    return head + deferred + commit


def dump_sqlite_snapshot(
    target_root: Path,
    today: date,
    *,
    tmp_root: Path | None = None,  # kept for back-compat; ignored intentionally
) -> list[dict[str, Any]]:
    """Hot-snapshot each entry in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS.

    Returns a list of {src_relpath, snapshot_relpath, snapshot_path,
    snapshot_bytes, source_present} dicts. A missing source DB (fresh
    install) is silently skipped — daily backup must still succeed.

    Implementation (PR #508 r2 fixes):

    1. Use `sqlite3.Connection.backup()` into a process-private temp DB
       first, then `iterdump` the temp copy. Raw `iterdump` against the
       live DB issues multiple SELECTs and can interleave with concurrent
       writer commits, producing a mixed dump. `.backup()` is the
       canonical online snapshot API and gives us a transactionally-
       consistent point-in-time copy.

    2. The gzipped `.partial` is staged as a sibling of the final path
       (inside `state/backup-snapshots/`), so `os.replace` is always on
       the same filesystem — no EXDEV when `BRIDGE_DAILY_BACKUP_DIR`
       lives on a different mount than the bridge home. The `tmp_root`
       parameter is kept for caller-side scratch (the temp DB) and the
       partial stays adjacent to the final.
    """
    snapshots: list[dict[str, Any]] = []
    final_dir = target_root / DAILY_BACKUP_SNAPSHOT_DIR_REL
    final_dir.mkdir(parents=True, exist_ok=True)
    # Temp DB lives in caller's tmp_root if given (out of the tar walk),
    # otherwise next to the final dump. Either path works because the
    # temp DB is unlinked before this function returns.
    db_tmp_dir = tmp_root if tmp_root is not None else final_dir
    db_tmp_dir.mkdir(parents=True, exist_ok=True)

    for src_relpath, stem in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS:
        src_path = target_root / src_relpath
        snapshot_name = daily_backup_sqlite_snapshot_filename(stem, today)
        final_path = final_dir / snapshot_name
        snapshot_relpath = f"{DAILY_BACKUP_SNAPSHOT_DIR_REL}/{snapshot_name}"
        entry: dict[str, Any] = {
            "src_relpath": src_relpath,
            "snapshot_relpath": snapshot_relpath,
            "snapshot_path": str(final_path),
            "snapshot_bytes": 0,
            "source_present": src_path.exists(),
        }
        if not src_path.exists():
            # Fresh install: nothing to dump, daily backup proceeds.
            snapshots.append(entry)
            continue

        # Sibling-of-final partial → atomic replace stays on the same fs.
        partial_path = final_dir / f".{snapshot_name}.partial.{uuid.uuid4().hex}"
        # Online-snapshot temp DB lives in db_tmp_dir; out of band.
        tmp_db_path = db_tmp_dir / f".{stem}-snapshot.{uuid.uuid4().hex}.sqlite"
        src_conn: sqlite3.Connection | None = None
        tmp_conn: sqlite3.Connection | None = None
        try:
            # mode=ro so verify-tasks-db / live writers aren't disturbed
            # by any side-effect of opening rw. .backup() works against
            # an ro source.
            src_uri = f"file:{src_path}?mode=ro"
            src_conn = sqlite3.connect(src_uri, uri=True)
            tmp_conn = sqlite3.connect(str(tmp_db_path))
            src_conn.backup(tmp_conn)
            # Now iterdump the consistent temp copy, not the live DB.
            # Issue #1041: reorder the stream so the `sqlite_sequence`
            # maintenance statements land after every `CREATE TABLE`, making
            # the snapshot restorable via stdlib `executescript`.
            dump_lines = _reorder_iterdump_for_restore(tmp_conn.iterdump())
            with gzip.open(partial_path, "wt", encoding="utf-8", compresslevel=6) as gz:
                for line in dump_lines:
                    gz.write(line)
                    gz.write("\n")
            _fsync_path(partial_path)
            _atomic_replace(partial_path, final_path)
            _fsync_path(final_path)
            entry["snapshot_bytes"] = final_path.stat().st_size
        except Exception as exc:  # pragma: no cover — surfaced to caller
            entry["error"] = f"{type(exc).__name__}: {exc}"
            with contextlib.suppress(FileNotFoundError):
                partial_path.unlink()
        finally:
            if tmp_conn is not None:
                with contextlib.suppress(Exception):
                    tmp_conn.close()
            if src_conn is not None:
                with contextlib.suppress(Exception):
                    src_conn.close()
            with contextlib.suppress(FileNotFoundError):
                tmp_db_path.unlink()
        snapshots.append(entry)
    return snapshots


def prune_sqlite_snapshots(
    target_root: Path, retain_days: int, today: date
) -> list[str]:
    if retain_days < 1:
        retain_days = 1
    final_dir = target_root / DAILY_BACKUP_SNAPSHOT_DIR_REL
    if not final_dir.exists():
        return []
    cutoff = today - timedelta(days=retain_days - 1)
    pruned: list[str] = []
    stems = {stem for _, stem in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS}
    for path in sorted(final_dir.iterdir()):
        if not path.is_file():
            continue
        # Only prune snapshots we recognize. Hand-placed files (e.g. an
        # operator-saved dump) are left alone.
        kept = False
        for stem in stems:
            parsed = parse_daily_backup_sqlite_snapshot_date(stem, path.name)
            if parsed is not None:
                if parsed < cutoff:
                    with contextlib.suppress(FileNotFoundError):
                        path.unlink()
                    pruned.append(str(path))
                kept = True
                break
        if not kept and path.name.endswith(".partial"):
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            pruned.append(str(path))
    return pruned


def create_daily_backup_archive(
    target_root: Path,
    backup_dir: Path,
    today: date,
    *,
    extra_excludes_env: str | None = None,
) -> dict[str, Any]:
    """Build today's daily archive end-to-end.

    Returns a structured result with `outcome` ∈ {created, skipped_disk_full,
    skipped_concurrent, error_<reason>}. Caller is responsible for surfacing
    the result as JSON; this function never raises into its caller for
    expected failure modes (disk full, lock contention, missing source DB).
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    archive_path = backup_dir / daily_backup_archive_name(today)

    result: dict[str, Any] = {
        "outcome": "error_unknown",
        "archive_path": str(archive_path),
        "snapshots": [],
        "free_bytes": 0,
        "needed_bytes": 0,
        "reaped_tmp": [],
    }

    with acquire_daily_backup_lock(backup_dir) as got_lock:
        if not got_lock:
            result["outcome"] = "skipped_concurrent"
            return result

        # bug #507 (1): glob-delete stale tmp files left by killed peers,
        # but only those older than the grace window so we don't trample
        # an active concurrent writer (defense-in-depth — the lock above
        # already enforces single-writer).
        result["reaped_tmp"] = reap_stale_daily_backup_tmp(backup_dir)

        # bug #507 (2): pre-flight free-space check. On a chronically-full
        # disk every retry would otherwise spawn another GB-scale tmp file
        # and fail.
        ok, free_bytes, needed_bytes = check_daily_backup_free_space(backup_dir)
        result["free_bytes"] = free_bytes
        result["needed_bytes"] = needed_bytes
        if not ok:
            result["outcome"] = "skipped_disk_full"
            return result

        # bug #507 (6): hot-snapshot tasks.db (and any future sqlite in
        # SQLITE_SNAPSHOT_TARGETS) into a temp dir outside the tar walk;
        # the resulting .sql.gz is gzip-friendly and ~10–20× smaller than
        # the raw .db. Today's snapshot will be added back to the tar as
        # an explicit member after the walk.
        with tempfile.TemporaryDirectory(
            prefix="agb-snap-", dir=backup_dir.parent
        ) as snap_tmp_str:
            snap_tmp = Path(snap_tmp_str)
            snapshots = dump_sqlite_snapshot(target_root, today, tmp_root=snap_tmp)
        result["snapshots"] = snapshots

        # PR #508 r3 (Codex blocker): if a source DB exists but its
        # snapshot failed (corruption, locked beyond timeout, FS error),
        # the tarball would otherwise ship with neither the raw .db
        # (excluded from the tar walk) nor the .sql.gz dump — a silently
        # empty queue snapshot that the daemon would still mark
        # `created`, clearing failure state and pruning prior good
        # backups. Treat that as a hard failure: surface
        # `error_sqlite_snapshot`, do NOT write a tarball, do NOT prune.
        # Missing source DB (`source_present=False`) stays non-fatal —
        # fresh installs must keep working.
        snapshot_errors = [
            entry for entry in snapshots
            if entry.get("source_present") and entry.get("error")
        ]
        if snapshot_errors:
            first = snapshot_errors[0]
            result["outcome"] = "error_sqlite_snapshot"
            result["error_detail"] = (
                f"{first.get('src_relpath', 'unknown')}: {first.get('error', 'unknown')}"
            )
            result["snapshot_errors"] = [
                {"src_relpath": e.get("src_relpath"), "error": e.get("error")}
                for e in snapshot_errors
            ]
            return result

        tmp_path = backup_dir / f"{archive_path.name}.tmp.{os.getpid()}"
        # Erase any prior tmp owned by this exact PID (rare, but possible
        # on PID reuse after a crash between two attempts in the same
        # second). The grace-gated reaper above won't catch a fresh tmp.
        with contextlib.suppress(FileNotFoundError):
            tmp_path.unlink()

        # Issue #785: under v0.9.7 unified isolation, files inside
        # `agents/<X>/` are owned by `agent-bridge-<X>:ab-agent-<X>` with
        # `0640/0700`. The controller (`ec2-user`) can `readdir` the parent
        # (2750 SetGID) but cannot `open` the inner files. Without a
        # per-member catch the first EACCES aborts the whole archive after
        # writing 0 bytes. Mirrors the `agent_migration` PermissionError
        # pattern (above) — accumulate skip records, surface in JSON.
        skipped_isolated: list[dict[str, str]] = []
        try:
            with tarfile.open(
                tmp_path, "w:gz", format=tarfile.PAX_FORMAT, dereference=False
            ) as archive:
                for src_path, arcname in iter_daily_backup_members(
                    target_root, backup_dir, extra_excludes_env=extra_excludes_env
                ):
                    try:
                        stat_result = os.lstat(src_path)
                    except FileNotFoundError:
                        continue
                    except PermissionError:
                        skipped_isolated.append({"path": str(src_path), "stage": "lstat"})
                        continue
                    if S_ISSOCK(stat_result.st_mode) or S_ISFIFO(stat_result.st_mode):
                        continue
                    try:
                        archive.add(src_path, arcname=arcname, recursive=False)
                    except PermissionError:
                        skipped_isolated.append({"path": str(src_path), "stage": "add"})
                        continue
                    except OSError as exc:
                        # CPython usually raises PermissionError, but
                        # tarfile.add may surface raw OSError(EACCES) for
                        # certain paths; treat both as the same isolation
                        # boundary.
                        if exc.errno == errno.EACCES:
                            skipped_isolated.append({"path": str(src_path), "stage": "add"})
                            continue
                        raise

                # Explicitly add today's snapshot dumps. The walk excluded
                # state/backup-snapshots/ so prior days' dumps don't bloat
                # this archive. Snapshots are written by the controller so
                # EACCES is unlikely, but defend symmetrically with the main
                # loop in case a future snapshot path becomes isolated.
                for entry in snapshots:
                    snap_path = Path(entry["snapshot_path"])
                    if not snap_path.exists():
                        continue
                    try:
                        archive.add(
                            snap_path,
                            arcname=entry["snapshot_relpath"],
                            recursive=False,
                        )
                    except PermissionError:
                        skipped_isolated.append({"path": str(snap_path), "stage": "add_snapshot"})
                        continue
                    except OSError as exc:
                        if exc.errno == errno.EACCES:
                            skipped_isolated.append({"path": str(snap_path), "stage": "add_snapshot"})
                            continue
                        raise
        except OSError as exc:
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            if exc.errno == errno.ENOSPC:
                result["outcome"] = "skipped_disk_full"
                # disk_usage may have raced; report what we know.
                with contextlib.suppress(Exception):
                    result["free_bytes"] = shutil.disk_usage(backup_dir).free
            else:
                result["outcome"] = f"error_oserror_{exc.errno or 'unknown'}"
            return result
        except Exception as exc:  # pragma: no cover — bubble for diagnostics
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            result["outcome"] = f"error_{type(exc).__name__.lower()}"
            result["error_detail"] = str(exc)
            return result

        try:
            _fsync_path(tmp_path)
            _atomic_replace(tmp_path, archive_path)
            _fsync_path(archive_path)
        except OSError as exc:
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            result["outcome"] = f"error_oserror_{exc.errno or 'unknown'}"
            return result

        result["outcome"] = "created"
        try:
            result["archive_bytes"] = archive_path.stat().st_size
        except FileNotFoundError:
            result["archive_bytes"] = 0
        if skipped_isolated:
            # Bound the path list so operator JSON stays grep-able even when
            # an isolated agent home has thousands of files (e.g. venv).
            result["skipped_isolated_count"] = len(skipped_isolated)
            if len(skipped_isolated) <= 60:
                result["skipped_isolated"] = skipped_isolated
            else:
                result["skipped_isolated"] = (
                    skipped_isolated[:50]
                    + [{"path": "...", "stage": "truncated"}]
                    + skipped_isolated[-10:]
                )
        return result


def prune_daily_backup_archives(backup_dir: Path, retain_days: int, today: date) -> list[str]:
    if retain_days < 1:
        retain_days = 1
    if not backup_dir.exists():
        return []

    cutoff = today - timedelta(days=retain_days - 1)
    pruned: list[str] = []
    for path in sorted(backup_dir.iterdir()):
        if not path.is_file():
            continue
        parsed = parse_daily_backup_archive_date(path.name)
        if parsed is not None and parsed < cutoff:
            path.unlink(missing_ok=True)
            pruned.append(str(path))
    # Bug #507: tmp cleanup belongs to reap_stale_daily_backup_tmp(), which
    # is age-gated to avoid stealing a concurrent writer's in-flight file.
    # The legacy unconditional `.tmp.*` unlink that lived here was the
    # exact behavior that made reap's grace gate useless.
    return pruned


def remove_existing_target_children(target_root: Path, preserve_relpaths: set[str] | None = None) -> int:
    # `preserve_relpaths` (Issue #1661): relative paths under target_root that
    # must survive the wipe. Used by rollback to keep `state/locks` — which
    # holds the active upgrade.lock the rollback ITSELF is holding — so a
    # full-snapshot restore cannot delete its own singleton lock mid-flight and
    # reopen the concurrent-mutation race. A preserved leaf keeps its inode
    # (flock identity) AND its mkdir lockdir intact.
    preserve = preserve_relpaths or set()
    # Top-level child names that contain a preserved subpath — never rmtree
    # these wholesale; descend and prune around the preserved entry instead.
    preserved_top = {rel.split("/", 1)[0] for rel in preserve if rel}
    # #1661: the raw pathlib metadata ops here are controller-only — this runs
    # during a controller-driven rollback restore over the controller-owned live
    # target tree (same category as the pre-#1661 body of this function, which
    # the raw-pathlib baseline already accepts). The preserve-recursion descends
    # ONLY into the controller-owned `state/` subtree (preserved_top); iso-owned
    # agent homes still take the wholesale `shutil.rmtree` branch unchanged.
    removed = 0
    for child in sorted(target_root.iterdir()):
        if child.name == "backups":
            continue
        if child.name in preserved_top and child.is_dir() and not child.is_symlink():  # noqa: raw-pathlib-controller-only
            removed += _remove_tree_except(child, target_root, preserve)
            continue
        removed += 1
        if child.is_symlink() or child.is_file():
            child.unlink(missing_ok=True)
        else:
            shutil.rmtree(child)
    return removed


def _remove_tree_except(node: Path, target_root: Path, preserve: set[str]) -> int:
    # Recursively remove everything under `node` except paths whose relpath
    # (from target_root) is in `preserve` or is an ancestor of a preserved
    # path. The preserved leaf and its parent chain stay intact. #1661:
    # controller-only — invoked solely from rollback's full-snapshot restore and
    # confined to the controller-owned `state/` subtree (the only preserved_top),
    # so the raw pathlib probes/mutations here never cross an iso-agent boundary.
    removed = 0
    for child in sorted(node.iterdir()):
        rel = child.relative_to(target_root).as_posix()
        if rel in preserve:
            continue  # exact preserved leaf — keep it (and its contents)
        if any(p == rel or p.startswith(rel + "/") for p in preserve):
            # Ancestor of a preserved path — descend, do not remove the dir.
            if child.is_dir() and not child.is_symlink():  # noqa: raw-pathlib-controller-only
                removed += _remove_tree_except(child, target_root, preserve)
            continue
        removed += 1
        if child.is_symlink() or child.is_file():  # noqa: raw-pathlib-controller-only
            child.unlink(missing_ok=True)  # noqa: raw-pathlib-controller-only
        else:
            shutil.rmtree(child)  # noqa: raw-pathlib-controller-only
    return removed


def restore_live_backup(target_root: Path, backup_root: Path) -> int:
    backup_live = backup_root / "live"
    if not backup_live.exists():
        raise FileNotFoundError(f"backup snapshot missing: {backup_live}")
    manifest = load_json(backup_root / "manifest.json", {})
    entries = manifest.get("entries") or []
    if entries:
        removed = 0
        for entry in entries:
            if entry.get("state") != "present":
                continue
            relpath = str(entry["path"])
            src = backup_live / relpath
            dst = target_root / relpath
            if not src.exists() and not src.is_symlink():
                continue
            remove_path(dst)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir() and not src.is_symlink():
                shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
        for entry in sorted(
            (item for item in entries if item.get("state") == "absent"),
            key=lambda item: str(item.get("path") or "").count("/"),
            reverse=True,
        ):
            dst = target_root / str(entry["path"])
            if dst.exists() or dst.is_symlink():
                remove_path(dst)
                removed += 1
        return removed
    # Issue #1661: preserve state/locks across the full-snapshot wipe so the
    # active upgrade.lock this rollback is holding survives — deleting it
    # mid-rollback would reopen the concurrent-mutation race (flock: a
    # recreated path is a new inode; mkdir: the lockdir frees immediately).
    lock_preserve = {"state/locks"}
    removed = remove_existing_target_children(target_root, preserve_relpaths=lock_preserve)
    for child in sorted(backup_live.iterdir()):
        dst = target_root / child.name
        if child.is_dir():
            # The backup snapshot itself can contain a STALE state/locks (it was
            # taken during a prior LOCKED upgrade), so a plain merge would copy
            # the old lock owner back over the live one — a concurrent run would
            # then read a dead pid and reclaim the lock mid-rollback (mkdir
            # backend). Skip the preserved subpaths on copy-back so the live
            # lock dir + owner are never overwritten by stale backup contents.
            shutil.copytree(
                child,
                dst,
                symlinks=True,
                dirs_exist_ok=True,
                ignore=_make_preserve_ignore(target_root, child, lock_preserve),
            )
        else:
            shutil.copy2(child, dst, follow_symlinks=False)
    return removed


def _make_preserve_ignore(target_root: Path, backup_child: Path, preserve: set[str]):
    # Build a shutil.copytree `ignore` callable that drops any directory entry
    # whose destination relpath (under target_root) is in `preserve`. The
    # callback receives the SOURCE dir + its entry names; we translate the
    # source dir back to its destination-relative path to compare. Returns the
    # set of names to skip at that level.
    backup_root_for_child = backup_child.parent  # == backup_live

    def _ignore(src_dir: str, names: list[str]) -> set[str]:
        try:
            rel_dir = Path(src_dir).relative_to(backup_root_for_child).as_posix()
        except ValueError:
            return set()
        skip = set()
        for name in names:
            rel = f"{rel_dir}/{name}" if rel_dir != "." else name
            if rel in preserve:
                skip.add(name)
        return skip

    return _ignore


def upgrade_state_path(target_root: Path) -> Path:
    return target_root / "state" / "upgrade" / "last-upgrade.json"


def load_upgrade_state(target_root: Path) -> dict[str, Any]:
    return load_json(upgrade_state_path(target_root), {})


def latest_backup_root(target_root: Path) -> Path | None:
    backups_dir = target_root / "backups"
    if not backups_dir.exists():
        return None
    candidates = [path for path in backups_dir.iterdir() if path.is_dir() and path.name.startswith("upgrade-")]
    if not candidates:
        return None
    return sorted(candidates)[-1]


def latest_backup_manifest(target_root: Path) -> dict[str, Any]:
    root = latest_backup_root(target_root)
    if root is None:
        return {}
    return load_json(root / "manifest.json", {})


def resolve_base_ref(target_root: Path, explicit_ref: str) -> str:
    if explicit_ref:
        return explicit_ref
    state = load_upgrade_state(target_root)
    base_ref = str(state.get("source_head") or "").strip()
    if base_ref:
        return base_ref
    manifest = latest_backup_manifest(target_root)
    return str(manifest.get("source_head") or "").strip()


def analyze_live(
    source_root: Path,
    target_root: Path,
    base_ref: str,
    upstream_ref: str = "",
) -> dict[str, Any]:
    # Issue #1602: `upstream_ref` is set ONLY on the dry-run `--ref` preview
    # path. When set, the upstream file SET and BYTES are read from the
    # requested ref's git tree (`git ls-tree` / `git show <ref>:path`) with no
    # working-tree mutation, so the preview reflects the requested ref instead
    # of whatever ref `SOURCE_ROOT` currently sits on. The apply path leaves
    # `upstream_ref` empty and keeps reading the working tree, which it has
    # already checked out to the ref. The merge BASE (`base_ref`, the recorded
    # `source_head`) is UNCHANGED — only the upstream side is ref-resolved.
    files: list[dict[str, Any]] = []
    counts = {
        "missing_live": 0,
        "unchanged": 0,
        "upstream_only": 0,
        "live_only": 0,
        "merge_required": 0,
        "unknown_base_live_diff": 0,
        "mode_drift": 0,
    }

    # Issue #666: when the source release ref differs from the live VERSION
    # (a real cross-version upgrade) but `base_ref` could not be resolved
    # / its commit is unreachable in this source clone, the previous
    # classifier sent every content-drifted file to `unknown_base_live_diff`
    # → `keep_live` and copied 0 files. Result: rc=0 + installed metadata
    # bumped + live runtime stayed on the prior version (silent failed
    # upgrade). Compute the version-mismatch flag once up-front so per-file
    # classification can fall back to `upstream_only` (deploy_upstream)
    # when there is no usable `base` *and* we know upstream is a different
    # release — preserving the "rerun same version → keep operator edits"
    # contract by gating on the version mismatch, not just on `base is None`.
    source_version = read_upstream_version(source_root, upstream_ref)
    target_version = read_target_version(target_root)
    # `read_source_version` falls back to the dev sentinel "0.0.0-dev" when
    # the source checkout has no `VERSION` file (a dev clone, not a real
    # release). Treating that as a real version would flip every
    # content-drifted file to `upstream_only` on a same-version rerun from
    # a dev clone, force-deploying over operator edits. Treat the sentinel
    # as "unknown" for `versions_differ` only; do NOT change the function's
    # return value because other callers (payload["version"], the
    # `--version` default in cmd_perform_replace) still need a non-empty
    # string.
    versions_differ = (
        bool(source_version)
        and bool(target_version)
        and source_version != target_version
        and source_version != "0.0.0-dev"
    )

    for relpath in upstream_tracked_files(source_root, upstream_ref):
        if should_skip_relpath(relpath):
            continue
        live_path = target_root / relpath
        upstream = upstream_file_bytes(source_root, upstream_ref, relpath)
        live = live_path.read_bytes() if live_path.exists() else None
        base = git_file_bytes(source_root, base_ref, relpath) if base_ref else None

        if live is None:
            classification = "missing_live"
            strategy = "deploy_upstream"
        elif upstream == live:
            # Content matches. Check whether the exec bit also matches
            # source — a mode-only drift (live 0644 vs upstream 0755 or
            # vice versa) is still a drift worth repairing, even though
            # the bytes agree. Without this the previous content-only
            # classifier skipped the file entirely, leaving the live
            # install with the wrong permission. Source-of-truth is the
            # git index, not source_path.stat() — a dev checkout may
            # have drifted filesystem perms (0744 / 0700) while git
            # still tracks 100755, and using stat would propagate the
            # bad worktree mode to every downstream install.
            source_exec = upstream_exec_bits(source_root, upstream_ref, relpath)
            live_exec = 0
            if not live_path.is_symlink():
                try:
                    live_exec = live_path.stat().st_mode & 0o111
                except OSError:
                    live_exec = 0
            if source_exec != live_exec:
                classification = "mode_drift"
                strategy = "sync_mode"
            else:
                classification = "unchanged"
                strategy = "noop"
        elif not base_ref or base is None:
            # Issue #666: no usable base for this file. If the source
            # release ref is a different version from the live install,
            # treat as a forward-rolling upgrade and deploy upstream
            # (release-shipped files like VERSION, bridge-upgrade.py,
            # lib/bridge-isolation-v2*.sh must actually land). On a
            # same-version rerun (e.g. re-applying v0.8.3 over v0.8.3
            # without recorded base_ref), keep_live still wins —
            # operator-edited content is preserved.
            if versions_differ:
                classification = "upstream_only"
                strategy = "deploy_upstream"
            else:
                classification = "unknown_base_live_diff"
                strategy = "keep_live"
        elif base == live:
            classification = "upstream_only"
            strategy = "deploy_upstream"
        elif base == upstream:
            classification = "live_only"
            strategy = "keep_live"
        else:
            classification = "merge_required"
            strategy = "manual_merge"

        counts[classification] += 1
        if classification == "unchanged":
            continue
        files.append(
            {
                "path": relpath,
                "classification": classification,
                "strategy": strategy,
                "base_ref": base_ref,
                "base_exists": base is not None,
                "live_exists": live is not None,
                "text": is_text_bytes(upstream) and is_text_bytes(live) and (base is None or is_text_bytes(base)),
                "hashes": {
                    "upstream": sha256_bytes(upstream),
                    "live": sha256_bytes(live),
                    "base": sha256_bytes(base),
                },
            }
        )

    return {
        "mode": "upgrade-analyze",
        "source_root": str(source_root),
        "target_root": str(target_root),
        "base_ref": base_ref,
        "counts": counts,
        "files": files,
    }


def merge_text_versions(base: bytes, live: bytes, upstream: bytes) -> tuple[str, bytes]:
    with tempfile.TemporaryDirectory(prefix="bridge-upgrade-merge-") as tmpdir:
        tmp_root = Path(tmpdir)
        live_path = tmp_root / "live"
        base_path = tmp_root / "base"
        upstream_path = tmp_root / "upstream"
        live_path.write_bytes(live)
        base_path.write_bytes(base)
        upstream_path.write_bytes(upstream)
        proc = subprocess.run(
            ["git", "merge-file", "-p", "--diff3", str(live_path), str(base_path), str(upstream_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode == 0:
            return ("clean", proc.stdout)
        if proc.returncode > 0 and proc.stdout:
            return ("conflict", proc.stdout)
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip() or "git merge-file failed")


def apply_live(
    source_root: Path,
    target_root: Path,
    base_ref: str,
    dry_run: bool,
    strict_merge: bool,
    run_id: str = "",
    upstream_ref: str = "",
) -> dict[str, Any]:
    # Issue #1602: `upstream_ref` is honored ONLY on the dry-run preview path
    # (the caller never sets it when actually writing). It is asserted below so
    # a ref-resolved upstream can never be paired with a real apply, which
    # MUST read the checked-out working tree it is about to copy from.
    if upstream_ref and not dry_run:
        raise ValueError("upstream_ref is only valid with dry_run=True (apply reads the checked-out working tree)")
    analysis = analyze_live(source_root, target_root, base_ref, upstream_ref)
    actions: list[dict[str, Any]] = []
    counts = {
        "files_copied": 0,
        "files_merged_clean": 0,
        "files_merged_conflict": 0,
        "files_preserved_live": 0,
        "files_skipped_noop": analysis["counts"].get("unchanged", 0),
        "files_mode_synced": 0,
        # Issue #1638: settings.json diffs that turned out to be cosmetic only
        # (hook-event order / python-interpreter prefix) and were preserved as
        # `keep_live` instead of conflicting.
        "settings_cosmetic_noconflict": 0,
    }
    conflicts: list[str] = []
    conflict_backups: list[str] = []
    # Issue #394: capture per-conflict metadata at write-time so the
    # next upgrade can auto-archive entries whose live target hash has
    # not changed since (operator already adopted/rejected, or hadn't
    # touched). `live_sha256_at_write` is `live`'s sha256 immediately
    # before the conflict file lands; "" when the live file did not
    # exist (treated as "any subsequent presence != at-write").
    conflict_records: list[dict[str, Any]] = []

    for item in analysis["files"]:
        relpath = str(item["path"])
        classification = str(item["classification"])
        live_path = target_root / relpath
        # Issue #1602: read upstream from the ref on the dry-run `--ref`
        # preview so the previewed merge/conflict bytes match the requested
        # ref. `upstream_ref` is empty on apply → working-tree read, unchanged.
        upstream = upstream_file_bytes(source_root, upstream_ref, relpath)
        if upstream is None:
            upstream = b""
        live = live_path.read_bytes() if live_path.exists() else None
        base = git_file_bytes(source_root, base_ref, relpath) if base_ref else None

        if classification == "mode_drift":
            counts["files_mode_synced"] += 1
            actions.append({"path": relpath, "action": "sync_mode"})
            continue

        if classification in {"missing_live", "upstream_only"}:
            counts["files_copied"] += 1
            actions.append(
                {
                    "path": relpath,
                    "action": "deploy_upstream",
                    "bytes": upstream,
                }
            )
            continue

        if classification in {"live_only", "unknown_base_live_diff"}:
            counts["files_preserved_live"] += 1
            actions.append({"path": relpath, "action": "keep_live"})
            continue

        if classification != "merge_required":
            actions.append({"path": relpath, "action": "noop"})
            continue

        # Issue #1638: before the generic text-merge conflict path, short-
        # circuit a settings.json diff that is cosmetic only (hook-event group
        # order and/or `python3` vs `/usr/bin/python3` interpreter prefix).
        # Such a diff is semantically a no-op, so preserve the operator's live
        # file (`keep_live`) and emit no `.upgrade-conflict`. A real hook
        # add/remove/retime is NOT cosmetic and falls through unchanged.
        if (
            Path(relpath).name == _SETTINGS_CONFLICT_BASENAME
            and live is not None
            and settings_cosmetic_only_diff(live, upstream)
        ):
            counts["files_preserved_live"] += 1
            counts["settings_cosmetic_noconflict"] += 1
            actions.append({"path": relpath, "action": "keep_live"})
            continue

        if item.get("text") and base is not None and live is not None:
            merge_kind, merged = merge_text_versions(base, live, upstream)
            if merge_kind == "clean":
                counts["files_merged_clean"] += 1
                actions.append(
                    {
                        "path": relpath,
                        "action": "merge_clean",
                        "bytes": merged,
                    }
                )
                continue
            counts["files_merged_conflict"] += 1
            conflicts.append(relpath)
            backup_path = conflict_backup_path(live_path)
            conflict_backups.append(str(backup_path))
            conflict_records.append(
                {
                    "path": str(backup_path),
                    "live_target": str(live_path),
                    "live_target_relpath": relpath,
                    "live_sha256_at_write": sha256_bytes(live),
                }
            )
            actions.append(
                {
                    "path": relpath,
                    "action": "merge_conflict",
                    "bytes": upstream,
                    "conflict_bytes": merged,
                    "conflict_backup_path": str(backup_path),
                }
            )
            continue

        counts["files_merged_conflict"] += 1
        conflicts.append(relpath)
        backup_path = conflict_backup_path(live_path)
        conflict_backups.append(str(backup_path))
        conflict_records.append(
            {
                "path": str(backup_path),
                "live_target": str(live_path),
                "live_target_relpath": relpath,
                "live_sha256_at_write": sha256_bytes(live),
            }
        )
        actions.append(
            {
                "path": relpath,
                "action": "merge_conflict",
                "bytes": upstream,
                "conflict_bytes": live if live is not None else upstream,
                "conflict_backup_path": str(backup_path),
            }
        )

    # Issue #1817: the tracked root `CLAUDE.md` is skipped by the deploy
    # classifier; decide the live-root operator-stub action here (detection
    # only — no write — so the dry-run preview is faithful) and surface it.
    live_root_claude_action = substitute_live_root_claude(source_root, target_root, dry_run=True, upstream_ref=upstream_ref)

    payload = {
        "mode": "upgrade-apply",
        "source_root": str(source_root),
        "target_root": str(target_root),
        "base_ref": base_ref,
        "dry_run": dry_run,
        "strict_merge": strict_merge,
        "analysis": analysis,
        "counts": counts,
        "conflicts": conflicts,
        "conflict_backups": conflict_backups,
        "live_root_claude_action": live_root_claude_action,
        "actions": [
            {
                "path": action["path"],
                "action": action["action"],
                **(
                    {"conflict_backup_path": action["conflict_backup_path"]}
                    if "conflict_backup_path" in action
                    else {}
                ),
            }
            for action in actions
        ],
        "applied": False,
        "aborted": False,
    }

    if conflicts and strict_merge:
        payload["aborted"] = True
        return payload

    if dry_run:
        return payload

    for action in actions:
        kind = action["action"]
        if kind in {"noop", "keep_live"}:
            continue
        live_path = target_root / action["path"]
        # Authoritatively mirror the git-tracked exec bit. `0o644 | 0`
        # for non-executable tracked files also propagates exec-bit
        # *removals* (100755 → 100644 upstream), which the earlier
        # "only chmod when exec_bits" variant silently ignored.
        target_mode = 0o644 | git_tracked_exec_bits(source_root, action["path"])
        if kind == "sync_mode":
            try:
                os.chmod(live_path, target_mode)
            except FileNotFoundError:
                # Live file was removed between analyze and apply.
                # Treat as a no-op — the next upgrade pass will redeploy.
                pass
            continue
        if kind == "merge_conflict":
            write_bytes(Path(action["conflict_backup_path"]), action["conflict_bytes"])
        write_bytes(live_path, action["bytes"], target_mode)

    # Issue #1817: now that the tracked payload has landed, maintain the thin
    # operator stub at the live root. Re-detect against the on-disk file (the
    # earlier call was dry-run) so a contract is substituted, a missing file is
    # seeded, and an operator-customized CLAUDE.md is left untouched.
    payload["live_root_claude_action"] = substitute_live_root_claude(source_root, target_root, dry_run=False)

    payload["applied"] = True

    # Issue #394: emit the structured conflict record for this run so
    # `agb upgrade conflicts list` and the next-run reconcile can find
    # it. Stat each conflict file *after* it has been written so size
    # and mtime are accurate; the at-write live-target hash captured
    # above is the reconcile anchor.
    if conflict_records and not dry_run:
        record_run_id = run_id or _generate_run_id()
        record_dir = target_root / "state" / "upgrade-conflicts"
        record_dir.mkdir(parents=True, exist_ok=True)
        rendered = []
        for entry in conflict_records:
            cp = Path(entry["path"])
            try:
                st = cp.stat()
                size = st.st_size
                mtime_iso = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(
                    timespec="seconds"
                )
            except OSError:
                size = 0
                mtime_iso = ""
            rendered.append(
                {
                    "path": entry["path"],
                    "live_target": entry["live_target"],
                    "live_target_relpath": entry["live_target_relpath"],
                    "size": size,
                    "mtime": mtime_iso,
                    "live_target_sha256_at_write": entry["live_sha256_at_write"],
                }
            )
        save_json(
            record_dir / f"{record_run_id}.json",
            {
                "run_id": record_run_id,
                "timestamp": now_iso(),
                "target_root": str(target_root),
                "conflict_files": rendered,
            },
        )
        payload["run_id"] = record_run_id
        payload["conflict_record_path"] = str(record_dir / f"{record_run_id}.json")

    return payload


def _generate_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]


def file_sha256(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except OSError:
        return ""


def path_exists_noexcept(path: Path) -> bool:
    try:
        return os.path.exists(path)
    except OSError:
        return False


def list_conflict_records(target_root: Path) -> list[Path]:
    record_dir = target_root / "state" / "upgrade-conflicts"
    if not record_dir.is_dir():
        return []
    return sorted(p for p in record_dir.glob("*.json") if p.is_file() and not p.name.startswith("auto-archive-"))


def list_conflict_files(target_root: Path) -> list[Path]:
    if not target_root.is_dir():
        return []
    out: list[Path] = []
    for path in target_root.rglob("*.upgrade-conflict"):
        if not path.is_file():
            continue
        rel = path.relative_to(target_root).as_posix()
        if rel.startswith("backups/"):
            continue
        out.append(path)
    return sorted(out, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)


def lookup_conflict_record(target_root: Path, conflict_path: Path) -> dict[str, Any] | None:
    """Return the most recent upgrade-conflicts/<run-id>.json entry that
    references `conflict_path` (matched by absolute path), or None.

    The "most recent" rule is needed because the same live file can
    accumulate multiple conflict-write events across upgrades; we want
    the one whose `live_target_sha256_at_write` matches the *current*
    pre-reconcile state, not an older fragment.
    """
    target = str(conflict_path)
    matches: list[tuple[float, dict[str, Any], dict[str, Any]]] = []
    for record_path in list_conflict_records(target_root):
        try:
            payload = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for entry in payload.get("conflict_files") or []:
            if entry.get("path") == target:
                ts = record_path.stat().st_mtime if record_path.exists() else 0.0
                matches.append((ts, payload, entry))
                break
    if not matches:
        return None
    matches.sort(key=lambda item: item[0], reverse=True)
    _, _payload, entry = matches[0]
    return entry


def archive_conflict_file(target_root: Path, conflict_path: Path) -> Path:
    """Move `conflict_path` under `<target_root>/backups/upgrade-conflict-archive/<YYYY-MM-DD>/<original-relpath>`
    and return the destination path. Caller is responsible for adding
    an audit row.
    """
    rel = conflict_path.relative_to(target_root) if conflict_path.is_absolute() else conflict_path
    archive_root = target_root / "backups" / "upgrade-conflict-archive" / date.today().isoformat()
    dest = archive_root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        # Tie-break by appending a millisecond timestamp; archives must be
        # additive, never destroy a prior archive on a same-day rerun.
        suffix = datetime.now(timezone.utc).strftime("%H%M%S%f")
        dest = dest.with_name(f"{dest.name}.{suffix}")
    shutil.move(str(conflict_path), str(dest))
    return dest


def write_conflict_audit(target_root: Path, action: str, detail: dict[str, Any]) -> None:
    """Append one JSONL row to `<target_root>/logs/upgrade-conflicts.log`
    so list/diff/adopt/discard/archive/reconcile leave an inspectable
    trail. Best-effort; failures are silent (do not break the action).
    """
    log_path = target_root / "logs" / "upgrade-conflicts.log"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "ts": now_iso(),
            "action": action,
            "detail": detail,
        }
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def cmd_analyze_live(args: argparse.Namespace) -> int:
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    payload = analyze_live(
        source_root,
        target_root,
        resolve_base_ref(target_root, args.base_ref or ""),
        str(getattr(args, "upstream_ref", "") or ""),
    )
    return emit_json(payload, 0)


def cmd_backup_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_root = Path(args.backup_root).expanduser()
    source_root = Path(args.source_root).expanduser() if args.source_root else None
    analysis_payload = load_json_arg(args.analysis_json, args.analysis_json_file)
    migration_payload = load_json_arg(args.migration_json, args.migration_json_file)
    skipped_isolated: list[dict[str, str]] = []
    # Issue #1635: distinguish "a targeted scan was requested" from "the targeted
    # scan produced entries". When every probed entry is an unreadable iso path
    # the entry list is empty, but we must NOT fall back to the full-tree copy —
    # that branch walks the whole install (including the protected iso subtrees)
    # and would re-trigger the very PermissionError abort this fix removes.
    targeted_scan_requested = bool(analysis_payload or migration_payload)
    entries = (
        build_backup_entries(target_root, analysis_payload, migration_payload, skipped_isolated)
        if targeted_scan_requested
        else []
    )
    payload = {
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "exists": target_root.exists(),
        "created": False,
        "manifest_path": str(backup_root / "manifest.json"),
        "snapshot_mode": "targeted" if targeted_scan_requested else "full",
        "entry_count": len(entries),
    }
    if source_root is not None:
        payload["source_head"] = git_head(source_root)
        payload["source_ref"] = git_ref(source_root)
        payload["version"] = read_source_version(source_root)
    if target_root.exists() and not args.dry_run:
        copy_live_backup(
            target_root,
            backup_root,
            entries if targeted_scan_requested else None,
            skipped_isolated,
        )
        manifest = {
            "created_at": now_iso(),
            "target_root": str(target_root),
            "source_root": str(source_root) if source_root is not None else "",
            "source_head": payload.get("source_head", ""),
            "source_ref": payload.get("source_ref", ""),
            "version": payload.get("version", ""),
            "snapshot_mode": payload["snapshot_mode"],
            "entries": entries,
        }
        save_json(backup_root / "manifest.json", manifest)
        payload["created"] = True
    # Issue #1635: surface iso-owned entries the controller could not stat OR
    # copy so operators can confirm the upgrade continued by design (not
    # silently). Computed AFTER copy_live_backup so copy-stage skips are
    # included; dedupe by path since a single relpath is only skipped once.
    if skipped_isolated:
        deduped: list[dict[str, str]] = []
        seen: set[str] = set()
        for rec in skipped_isolated:
            key = rec.get("path", "")
            if key in seen:
                continue
            seen.add(key)
            deduped.append(rec)
        payload["skipped_isolated_count"] = len(deduped)
        if len(deduped) <= 60:
            payload["skipped_isolated"] = deduped
        else:
            payload["skipped_isolated"] = (
                deduped[:50]
                + [{"path": "...", "reason": "truncated"}]
                + deduped[-10:]
            )
    return emit_json(payload, 0)


def cmd_backup_extend_live(args: argparse.Namespace) -> int:
    """Record additional files in an existing backup snapshot.

    Rationale: the primary `backup-live` snapshot is built from the tracked-file
    analysis and the migrate-agents preview. Later upgrade stages such as
    `bridge-docs.py apply --all` mutate files outside that targeted set (per-agent
    `MEMORY-SCHEMA.md`, `SKILLS.md`, `CLAUDE.md`, managed-doc symlinks, etc.) and
    their prior contents are not captured, so `rollback-live` cannot restore
    those files. This subcommand takes the changed-paths JSON produced by
    `bridge-docs.py apply --dry-run --json`, copies each still-present target
    path into `backup_root/live/`, and appends a manifest entry so the rollback
    path treats them identically to the primary backup set.
    """
    target_root = Path(args.target_root).expanduser().resolve()
    # Issue #150: keep a parallel unresolved form of target_root for the
    # fallback relative-path check. On macOS `/tmp` resolves to `/private/tmp`,
    # and operator-supplied paths typically use the unresolved form — a
    # resolve-vs-literal string mismatch would otherwise turn the fallback
    # into a no-op and leave parent-symlink-outside children dropped.
    target_root_literal = Path(args.target_root).expanduser().absolute()
    backup_root = Path(args.backup_root).expanduser()
    payload = {
        "mode": "backup-extend-live",
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "dry_run": bool(args.dry_run),
        "added_entries": 0,
        "skipped_existing": 0,
        "skipped_missing": 0,
        "skipped_outside_target": 0,
    }

    raw = (args.paths_json or "").strip()
    if not raw:
        return emit_json(payload, 0)

    try:
        doc_payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"--paths-json is not valid JSON: {exc}") from exc
    changed_paths = doc_payload.get("changed_paths") or []
    if not isinstance(changed_paths, list):
        raise SystemExit("--paths-json must contain a list under `changed_paths`")

    manifest_path = backup_root / "manifest.json"
    manifest = load_json(manifest_path, {})
    existing_entries = list(manifest.get("entries") or [])
    existing_relpaths = {str(entry.get("path") or "") for entry in existing_entries}

    added_entries: list[dict[str, str]] = []
    skipped_isolated: list[dict[str, str]] = []
    backup_live = backup_root / "live"

    for raw_path in changed_paths:
        if not isinstance(raw_path, str) or not raw_path:
            continue
        clean = raw_path
        if clean.startswith("removed:"):
            clean = clean[len("removed:"):]
        # Canonicalize the ancestor dirs but preserve the final component
        # unchanged. If we used `Path.resolve()` on the whole path, a symlink
        # at the tail (e.g. `agents/demo/TOOLS.md -> ../shared/TOOLS.md`)
        # would be followed and the manifest entry would record the target
        # instead of the link path — breaking rollback for exactly the
        # symlink paths bridge-docs.py rewrites. Resolve the parent only.
        raw = Path(clean).expanduser()
        if not raw.is_absolute():
            raw = Path.cwd() / raw
        try:
            parent_resolved = raw.parent.resolve()
        except OSError:
            payload["skipped_missing"] += 1
            continue
        abs_path = parent_resolved / raw.name
        try:
            relpath = abs_path.relative_to(target_root).as_posix()
        except ValueError:
            # Issue #150: the parent `.resolve()` above follows intermediate
            # symlinks. If an operator has retargeted a directory symlink
            # inside `target_root` to an absolute path outside (e.g.
            # `agents/shared -> /opt/external-shared`), the resolved parent
            # lands outside `target_root` and the entry was silently
            # dropped from the manifest — so rollback later cannot restore
            # the child file. Retry using the unresolved path against the
            # unresolved target root: the operator-supplied path is
            # guaranteed to be under `target_root` at the literal level
            # (otherwise it would not have been emitted by bridge-docs.py
            # for this install). Only truly-outside paths — e.g. an
            # absolute path that does not syntactically start with
            # `target_root` under either resolution — fall through to the
            # outside-target bucket now.
            try:
                relpath = raw.relative_to(target_root_literal).as_posix()
            except ValueError:
                payload["skipped_outside_target"] += 1
                continue
        if relpath in existing_relpaths:
            payload["skipped_existing"] += 1
            continue
        existing_relpaths.add(relpath)
        live_path = target_root / relpath
        # Issue #1635: the same iso boundary that aborts the primary backup scan
        # applies here. Graceful-skip a changed path the controller cannot stat
        # OR copy (genuine permission failure only) instead of aborting the loop
        # — which would also silently drop every LATER readable extension backup.
        # Version-independent stat gate (r5): never let 3.14's exists()-swallows-
        # EACCES record a real iso file as `absent`.
        try:
            present, is_symlink, is_dir = _probe_live_path(live_path)
        except _IsoPermissionSkip as skip:
            _record_backup_skip(skipped_isolated, relpath, skip.filename)
            continue
        if present:
            kind = "dir" if is_dir else "file"
            entry = {"path": relpath, "state": "present", "kind": kind}
        else:
            entry = {"path": relpath, "state": "absent", "kind": "file"}
            payload["skipped_missing"] += 1
        if args.dry_run:
            added_entries.append(entry)
            continue
        if entry["state"] != "present":
            added_entries.append(entry)
            continue
        dst = backup_live / relpath
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            if is_symlink:
                link_target = os.readlink(live_path)
                if dst.exists() or dst.is_symlink():
                    dst.unlink()
                os.symlink(link_target, dst)
            elif is_dir:
                shutil.copytree(live_path, dst, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copy2(live_path, dst, follow_symlinks=False)
        except (PermissionError, OSError, shutil.Error) as exc:
            # Source-side iso EACCES → skip; destination (backup dir) write
            # failure → re-raise (never silently drop a readable backup).
            if _is_source_side_perm_skip(exc, live_path, backup_root):
                _record_backup_skip(skipped_isolated, relpath, getattr(exc, "filename", None))
                continue
            raise
        # Only record the manifest entry once the copy actually succeeded, so a
        # skipped (uncopied) path never claims a backup that rollback can't find.
        added_entries.append(entry)

    payload["added_entries"] = len(added_entries)
    if skipped_isolated:
        payload["skipped_isolated_count"] = len(skipped_isolated)
        if len(skipped_isolated) <= 60:
            payload["skipped_isolated"] = skipped_isolated
        else:
            payload["skipped_isolated"] = (
                skipped_isolated[:50]
                + [{"path": "...", "reason": "truncated"}]
                + skipped_isolated[-10:]
            )

    if added_entries and not args.dry_run:
        merged = existing_entries + added_entries
        merged.sort(key=lambda item: str(item.get("path") or ""))
        manifest["entries"] = merged
        # If the snapshot was previously "full" (no entries), a targeted extend
        # still leaves the full tree intact; leave snapshot_mode alone.
        save_json(manifest_path, manifest)

    return emit_json(payload, 0)


def cmd_daily_backup_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_dir = Path(args.backup_dir).expanduser()
    retain_days = max(1, int(args.retain_days))
    today = date.today()
    payload: dict[str, Any] = {
        "mode": "daily-backup-live",
        "target_root": str(target_root),
        "backup_dir": str(backup_dir),
        "archive_path": str(backup_dir / daily_backup_archive_name(today)),
        "retain_days": retain_days,
        "exists": target_root.exists(),
        "created": False,
        "pruned": [],
        "snapshots_pruned": [],
        "outcome": "skipped_no_target_root",
    }
    if not target_root.exists():
        return emit_json(payload, 0)
    if args.dry_run:
        payload["outcome"] = "dry_run"
        return emit_json(payload, 0)

    result = create_daily_backup_archive(target_root, backup_dir, today)
    payload["outcome"] = result["outcome"]
    payload["archive_path"] = result.get("archive_path", payload["archive_path"])
    payload["snapshots"] = result.get("snapshots", [])
    payload["free_bytes"] = result.get("free_bytes", 0)
    payload["needed_bytes"] = result.get("needed_bytes", 0)
    payload["reaped_tmp"] = result.get("reaped_tmp", [])
    if "archive_bytes" in result:
        payload["archive_bytes"] = result["archive_bytes"]
    if "error_detail" in result:
        payload["error_detail"] = result["error_detail"]
    # Issue #785: surface per-member EACCES skips so operators can see what
    # was excluded from the archive instead of treating a partial-but-created
    # outcome as a silent success.
    if "skipped_isolated_count" in result:
        payload["skipped_isolated_count"] = result["skipped_isolated_count"]
    if "skipped_isolated" in result:
        payload["skipped_isolated"] = result["skipped_isolated"]

    if result["outcome"] == "created":
        payload["created"] = True
        payload["pruned"] = prune_daily_backup_archives(backup_dir, retain_days, today)
        payload["snapshots_pruned"] = prune_sqlite_snapshots(target_root, retain_days, today)

    return emit_json(payload, 0)


def open_tasks_db_readonly(
    db_path: Path,
) -> tuple[sqlite3.Connection | None, str, str]:
    """Open *db_path* read-only without disturbing the live queue.

    Returns ``(conn, mode, error)``. On success ``conn`` is non-None and
    ``error`` is empty; on failure ``conn`` is None and ``error`` carries a
    cause-tagged diagnostic.

    Why a fallback ladder rather than a bare ``mode=ro`` open (Issue #1786):
    the live queue runs in WAL journal mode (``bridge-queue.py`` sets
    ``PRAGMA journal_mode=WAL``). A plain ``file:<db>?mode=ro`` open of a
    WAL database from a *separate* process needs the ``-shm`` shared-memory
    file; when no live writer is holding it open and the sidecar is absent
    (e.g. right after a checkpoint/truncate), sqlite cannot create the
    ``-shm`` in read-only mode and a read fails with SQLITE_CANTOPEN
    ("unable to open database file") — a false negative on a perfectly
    healthy db. (The ``sqlite3.connect`` call itself succeeds lazily; the
    error surfaces on the FIRST query that touches the WAL, so we validate
    each candidate with a cheap probe read before accepting it.)
    ``immutable=1`` tells sqlite the file will not change for the life of the
    connection, so it bypasses WAL/shm entirely and reads the db directly.

    The ``immutable=1`` fallback is GATED on the WAL sidecar being empty or
    absent (codex r1 P2): because immutable reads bypass the WAL, a
    ``quick_check`` over an immutable open would validate only the
    checkpointed main DB and silently ignore committed-but-uncheckpointed
    pages in a non-empty ``-wal`` — a false "ok". So when ``mode=ro`` fails
    AND a non-empty ``-wal`` sidecar exists, we return no connection and let
    the caller report ``unverifiable`` rather than a possibly-stale "ok". A
    bare/empty ``-wal`` (no unmerged pages) is safe to read immutably. The
    gate is re-stat'd at the fallback point (codex r2 P2) so a live writer
    that creates a non-empty ``-wal`` between an early stat and the immutable
    branch cannot slip a stale "ok" through.
    """

    def _wal_has_unmerged_pages() -> bool:
        try:
            wal_sidecar = Path(f"{db_path}-wal")
            return wal_sidecar.is_file() and wal_sidecar.stat().st_size > 0  # noqa: raw-pathlib-controller-only — read-only sidecar size probe on the queue DB the operator/upgrader owns; OSError-guarded.
        except OSError:
            # Can't stat the sidecar — be conservative and assume it may hold
            # unmerged pages so we never silently skip them.
            return True

    last_err = ""
    saw_unmerged_wal = False
    for mode in ("mode=ro", "immutable=1"):
        if mode == "immutable=1" and _wal_has_unmerged_pages():
            # Re-stat'd here (not once up front) to close the TOCTOU race with
            # a live writer. Skipping the WAL would hide committed pages, so
            # refuse the potentially-stale read and fall through to
            # unverifiable.
            saw_unmerged_wal = True
            last_err = last_err or "wal_unmerged: refusing immutable read that would bypass a non-empty -wal"
            break
        conn = None
        try:
            conn = sqlite3.connect(f"file:{db_path}?{mode}", uri=True)
            # Probe read forces the WAL/shm attach so a lazy CANTOPEN
            # surfaces here, not on the caller's first real query.
            conn.execute("PRAGMA schema_version").fetchone()
            return conn, mode, ""
        except sqlite3.OperationalError as exc:
            # Open/access failure (unable to open, locked, disk I/O) — retry /
            # fall through to unverifiable.
            last_err = f"{type(exc).__name__}: {exc}"
            if conn is not None:
                conn.close()
        except sqlite3.DatabaseError as exc:
            # A non-Operational DatabaseError ("file is not a database",
            # "database disk image is malformed") IS corruption — the bytes
            # read are not a valid db. Signal the caller via the "__corrupt__"
            # mode sentinel so it reports state=corrupt, not unverifiable
            # (codex r3 P2). Retrying immutable would raise the same error.
            if conn is not None:
                conn.close()
            return None, "__corrupt__", f"{type(exc).__name__}: {exc}"
    # Both attempts failed (or the immutable fallback was unsafe). Distinguish
    # the open-failure cause so the operator/agent gets an actionable
    # "unverifiable: <cause>" instead of a bare sqlite string (Issue #1786
    # indeterminate-state contract).
    cause = "wal_unmerged_unreadable" if saw_unmerged_wal else "open_failed"
    try:
        st = db_path.stat()  # noqa: raw-pathlib-controller-only — read-only cause classification on the queue DB the operator/upgrader owns; OSError-guarded, runs controller/operator-side only.
        if not os.access(db_path, os.R_OK):
            cause = "not_readable"
        elif not os.access(db_path.parent, os.X_OK | os.R_OK):
            cause = "dir_not_accessible"
        elif not saw_unmerged_wal and st.st_size == 0:
            cause = "empty_file"
    except OSError:
        cause = "stat_failed"
    return None, "", f"{cause}: {last_err}"


def cmd_verify_tasks_db(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    db_path = target_root / "state/tasks.db"
    payload: dict[str, Any] = {
        "mode": "verify-tasks-db",
        "target": str(db_path),
        "exists": db_path.exists(),
        "ok": False,
    }
    if not db_path.exists():
        payload["error"] = "missing"
        payload["state"] = "missing"
        # Fresh installs don't have tasks.db until the first task is filed.
        # Treat missing as non-fatal (exit 0); operator/agent reads `ok=false`
        # + `error=missing` from the JSON and decides what to do.
        return emit_json(payload, 0)
    # `state` is a 3-state contract (Issue #1786): "ok" (quick_check passed),
    # "corrupt" (quick_check ran but failed), or "unverifiable" (the db could
    # not be opened for an UNKNOWN reason). An open failure must NEVER read as
    # "ok", and must be distinguishable from "corrupt".
    conn, open_mode, open_err = open_tasks_db_readonly(db_path)
    if conn is None:
        if open_mode == "__corrupt__":
            # The probe read proved the file is not a valid db — real
            # corruption, not an indeterminate open failure (codex r3 P2).
            payload["state"] = "corrupt"
            payload["quick_check"] = open_err
            payload["error"] = f"sqlite_error: {open_err}"
            return emit_json(payload, 1)
        payload["state"] = "unverifiable"
        payload["error"] = f"sqlite_error: unable to open database file ({open_err})"
        return emit_json(payload, 1)
    payload["open_mode"] = open_mode
    try:
        try:
            row = conn.execute("PRAGMA quick_check").fetchone()
        except sqlite3.OperationalError as exc:
            # Open/access failure surfacing on the query — indeterminate.
            payload["state"] = "unverifiable"
            payload["error"] = f"sqlite_error: {exc}"
            return emit_json(payload, 1)
        except sqlite3.DatabaseError as exc:
            # Non-Operational DatabaseError = corruption (codex r3 P2).
            payload["state"] = "corrupt"
            payload["quick_check"] = f"{type(exc).__name__}: {exc}"
            payload["error"] = f"sqlite_error: {exc}"
            return emit_json(payload, 1)
        check = row[0] if row else ""
        payload["quick_check"] = check
        if check == "ok":
            payload["ok"] = True
            payload["state"] = "ok"
        else:
            payload["state"] = "corrupt"
            payload["error"] = f"quick_check: {check}"
    finally:
        conn.close()
    return emit_json(payload, 0 if payload["ok"] else 1)


# --- backup residue cleanup -------------------------------------------------
#
# Used by `agb upgrade --apply` (via lib/bridge-cleanup.sh) and exposed as a
# standalone subcommand so operators can run it manually:
#
#   python3 bridge-upgrade.py cleanup-residue --target-root ~/.agent-bridge \
#     --backup-dir ~/.agent-bridge/backups/daily \
#     --upgrade-backups-dir ~/.agent-bridge/backups
#
# Always returns exit 0 with a structured JSON payload. `cleanup_failures`
# is non-empty when any individual step failed; the caller (upgrade flow)
# surfaces that to the operator instead of aborting the upgrade.

def _format_bytes(n: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(max(0, int(n)))
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{n} B"


def _free_bytes(path: Path) -> int:
    try:
        return shutil.disk_usage(path).free
    except (FileNotFoundError, PermissionError):
        return 0


def prune_upgrade_backups(
    upgrade_backups_dir: Path,
    *,
    current_backup_root: Path | None,
    retain_count: int,
    retain_days: int,
    today: date | None = None,
    no_backup_mode: bool = False,
) -> dict[str, Any]:
    """Conservative pruner for `backups/upgrade-*/` directories.

    Both gates apply:
      - keep at least `retain_count` newest entries (by mtime)
      - of the rest, only delete those older than `retain_days`
      - the current upgrade's BACKUP_ROOT (if any) is always preserved
      - in --no-backup mode, do nothing (no signal that operator is OK
        with destruction of older backup snapshots)
    """
    summary: dict[str, Any] = {
        "scanned": 0,
        "preserved": [],
        "pruned": [],
        "skipped_no_backup_mode": no_backup_mode,
    }
    if no_backup_mode:
        return summary
    if not upgrade_backups_dir.exists():
        return summary
    today = today or date.today()
    cutoff_ts = (
        datetime.combine(today, datetime.min.time()).timestamp()
        - max(0, retain_days) * 86400
    )

    candidates: list[tuple[float, Path]] = []
    for child in sorted(upgrade_backups_dir.iterdir()):
        if not child.is_dir():
            continue
        if not child.name.startswith("upgrade-"):
            continue
        try:
            mtime = child.stat().st_mtime
        except FileNotFoundError:
            continue
        candidates.append((mtime, child))
    summary["scanned"] = len(candidates)
    candidates.sort(key=lambda item: item[0], reverse=True)

    keep_paths: set[Path] = set()
    if current_backup_root is not None:
        try:
            current_resolved = current_backup_root.resolve()
        except OSError:
            current_resolved = current_backup_root
        for _, path in candidates:
            try:
                if path.resolve() == current_resolved:
                    keep_paths.add(path)
            except OSError:
                continue

    for _, path in candidates[: max(0, retain_count)]:
        keep_paths.add(path)

    for mtime, path in candidates:
        if path in keep_paths:
            summary["preserved"].append({"path": str(path), "mtime": int(mtime)})
            continue
        if mtime >= cutoff_ts:
            summary["preserved"].append({"path": str(path), "mtime": int(mtime)})
            continue
        try:
            shutil.rmtree(path)
            summary["pruned"].append(str(path))
        except OSError as exc:
            summary.setdefault("errors", []).append(
                {"path": str(path), "error": f"{type(exc).__name__}: {exc}"}
            )
    return summary


def validate_claude_config(path: Path) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "path": str(path),
        "exists": path.exists(),
        "status": "missing",
    }
    if not path.exists():
        return payload
    try:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
        payload["status"] = "ok"
    except json.JSONDecodeError as exc:
        payload["status"] = "corrupted"
        payload["error"] = f"JSONDecodeError: {exc}"
    except OSError as exc:
        payload["status"] = "unreadable"
        payload["error"] = f"{type(exc).__name__}: {exc}"
    if payload["status"] == "corrupted":
        backups_dir = Path.home() / ".claude" / "backups"
        if backups_dir.exists():
            backup_candidates = sorted(
                (p for p in backups_dir.glob("**/.claude.json") if p.is_file()),
                key=lambda p: p.stat().st_mtime if p.exists() else 0,
                reverse=True,
            )
            if backup_candidates:
                payload["recovery_candidate"] = str(backup_candidates[0])
    return payload


# Issue #1985 (follow-up to #1981 / PR #1984): detect + backup-gated repair of an
# operator-global `~/.claude/settings.json` that was ALREADY hijacked into a
# bridge-managed `settings.effective.json` symlink before the #1981 launch-time
# guard shipped. This is the REMEDIATION half — #1981 only *prevents* new
# hijacks. Default behavior is REPORT-ONLY: detection never mutates and never
# fails the upgrade. Repair runs only with the explicit
# `--repair-operator-global-settings-hijack` flag AND only after a complete,
# non-overwriting backup directory is written. The replacement is a neutral `{}`
# settings file (mode 0600) unless an explicit trusted restore-file is supplied.
# We deliberately do NOT reconstruct user intent by stripping bridge hooks out of
# the effective output (that is v0.17). Kept isolated from any Track A onboarding
# marker repair — different rollback/visibility contracts (design §"Sequencing").
OPERATOR_GLOBAL_NEUTRAL_SETTINGS = "{}\n"


def resolve_operator_global_settings_file(args: argparse.Namespace) -> Path:
    """Resolve the operator-global Claude settings path to inspect.

    The shell caller (lib/bridge-cleanup.sh) passes the already-resolved
    `--operator-global-settings-file` from the #1984 resolver
    (`bridge_hook_operator_global_settings_file`, which delegates to
    `bridge_agent_operator_home_dir`). Direct manual `cleanup-residue` runs omit
    it, so we fall back to `Path.home() / ".claude/settings.json"` — the same
    operator-home authority the #1984 guard uses for the manual case.
    """
    raw = getattr(args, "operator_global_settings_file", "") or ""
    if raw.strip():
        return Path(raw).expanduser()
    return Path.home() / ".claude" / "settings.json"  # noqa: raw-pathlib-controller-only — operator-HOME global settings probe; read-only classify, controller/operator-side only.


def _classify_bridge_effective_target(
    link_target_real: str,
    target_root: Path,
) -> dict[str, str]:
    """Return {matched_layout, matched_agent} if the resolved symlink target is a
    recognized bridge `settings.effective.json` output, else empty strings.

    Matches both exact existing candidates AND the dangling/orphan path shape so a
    symlink that went dangling (source agent closed/moved after the live hijack)
    is still classified. Detection stays narrow: the basename must be exactly
    `settings.effective.json`, the parent suffix exactly `.claude/
    settings.effective.json`, and the path must live under `<target_root>/agents/`
    or `<target_root>/data/agents/`.
    """
    out = {"matched_layout": "", "matched_agent": ""}
    if not link_target_real:
        return out
    try:
        target_root_real = os.path.realpath(str(target_root))
    except OSError:
        target_root_real = str(target_root)

    real = link_target_real
    real_path = Path(real)
    if real_path.name != "settings.effective.json":
        return out
    parent = real_path.parent
    if parent.name != ".claude":
        return out

    agents_v1 = os.path.join(target_root_real, "agents")
    agents_v2 = os.path.join(target_root_real, "data", "agents")
    under_v1 = real == agents_v1 or real.startswith(agents_v1 + os.sep)
    under_v2 = real == agents_v2 or real.startswith(agents_v2 + os.sep)
    if not (under_v1 or under_v2):
        return out

    # Shared install-wide effective: <target_root>/agents/.claude/settings.effective.json
    if under_v1 and os.path.realpath(parent.parent) == agents_v1:
        out["matched_layout"] = "shared"
        return out
    # v2 per-agent: <target_root>/data/agents/<agent>/home/.claude/settings.effective.json
    if under_v2:
        # parent = .../<agent>/home/.claude ; want <agent>
        home_dir = parent.parent
        if home_dir.name == "home":
            out["matched_layout"] = "v2-agent"
            out["matched_agent"] = home_dir.parent.name
            return out
        # Defensive: still under data/agents with the effective shape.
        out["matched_layout"] = "orphan-shape"
        return out
    # legacy v1 per-agent: <target_root>/agents/<agent>/.claude/settings.effective.json
    if under_v1:
        out["matched_layout"] = "legacy-agent"
        out["matched_agent"] = parent.parent.name
        return out
    out["matched_layout"] = "orphan-shape"
    return out


def classify_operator_global_settings_hijack(
    operator_global: Path,
    target_root: Path,
) -> dict[str, Any]:
    """Classify the operator-global settings file.

    Returns a payload whose `status` is one of:
      absent | non_symlink | symlink_non_bridge | detected | error

    A `detected` status means the operator-global path is a symlink whose
    realpath resolves to (or has the path-shape of) a bridge effective output.
    Regular files, non-bridge symlinks, and missing files are NOT hijacks.
    """
    payload: dict[str, Any] = {
        "status": "absent",
        "operator_global": str(operator_global),
        "is_symlink": False,
        "link_target_raw": "",
        "link_target_real": "",
        "matched_layout": "",
        "matched_agent": "",
    }
    try:
        st = os.lstat(operator_global)  # noqa: raw-pathlib-controller-only — read-only lstat on the operator-HOME global; OSError-guarded.
    except FileNotFoundError:
        return payload
    except OSError as exc:
        payload["status"] = "error"
        payload["message"] = f"{type(exc).__name__}: {exc}"
        return payload

    if not S_ISLNK(st.st_mode):
        payload["status"] = "non_symlink"
        return payload

    payload["is_symlink"] = True
    try:
        link_target_raw = os.readlink(operator_global)
    except OSError as exc:
        payload["status"] = "error"
        payload["message"] = f"{type(exc).__name__}: {exc}"
        return payload
    payload["link_target_raw"] = link_target_raw
    try:
        link_target_real = os.path.realpath(operator_global)
    except OSError:
        link_target_real = ""
    payload["link_target_real"] = link_target_real

    match = _classify_bridge_effective_target(link_target_real, target_root)
    payload["matched_layout"] = match["matched_layout"]
    payload["matched_agent"] = match["matched_agent"]
    if match["matched_layout"]:
        payload["status"] = "detected"
    else:
        payload["status"] = "symlink_non_bridge"
    return payload


def backup_operator_global_settings_hijack(
    detection: dict[str, Any],
    backup_parent: Path,
    restore_bytes: bytes,
    restore_mode: str,
    restore_source: str = "",
) -> dict[str, Any]:
    """Write a complete, non-overwriting backup of the hijacked operator-global
    symlink BEFORE any mutation. Returns {ok: bool, backup_dir, error?}.

    On ANY write failure, the partial dir is left in place (best-effort) and
    `ok=False` is returned so the caller refuses to mutate the operator global.
    """
    operator_global = Path(detection["operator_global"])
    link_target_raw = detection.get("link_target_raw", "")
    link_target_real = detection.get("link_target_real", "")
    result: dict[str, Any] = {"ok": False, "backup_dir": ""}
    try:
        backup_parent.mkdir(parents=True, exist_ok=True, mode=0o700)  # noqa: raw-pathlib-controller-only — controller/operator-owned backup tree under target_root.
    except OSError as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir: Path | None = None
    for _ in range(8):
        nonce = uuid.uuid4().hex[:8]
        candidate = backup_parent / f"{stamp}-{os.getpid()}-{nonce}"
        try:
            candidate.mkdir(mode=0o700)  # noqa: raw-pathlib-controller-only — exclusive backup-run dir creation; never overwrites.
            run_dir = candidate
            break
        except FileExistsError:
            continue
        except OSError as exc:
            result["error"] = f"{type(exc).__name__}: {exc}"
            return result
    if run_dir is None:
        result["error"] = "could not create a unique backup directory after 8 attempts"
        return result
    result["backup_dir"] = str(run_dir)

    target_readable = False
    target_sha256 = ""
    try:
        # 1. raw link target text
        (run_dir / "operator-global-settings.link-target.txt").write_text(  # noqa: raw-pathlib-controller-only — owner-only backup evidence file.
            link_target_raw + "\n", encoding="utf-8"
        )
        os.chmod(run_dir / "operator-global-settings.link-target.txt", 0o600)

        # 2. symlink backup with the SAME raw target (not a copy of the file)
        symlink_backup = run_dir / "operator-global-settings.symlink"
        os.symlink(link_target_raw, symlink_backup)

        # 3. best-effort target evidence (the effective file is expected to
        #    contain bridge hooks — evidence only, NEVER auto-restored from).
        if link_target_real and os.path.isfile(link_target_real):
            try:
                raw = Path(link_target_real).read_bytes()  # noqa: raw-pathlib-controller-only — best-effort read of the resolved effective target for evidence.
                (run_dir / "operator-global-settings.target.json").write_bytes(raw)  # noqa: raw-pathlib-controller-only — owner-only evidence copy.
                os.chmod(run_dir / "operator-global-settings.target.json", 0o600)
                target_sha256 = hashlib.sha256(raw).hexdigest()
                (run_dir / "operator-global-settings.target.sha256").write_text(  # noqa: raw-pathlib-controller-only — owner-only evidence hash.
                    target_sha256 + "\n", encoding="utf-8"
                )
                os.chmod(run_dir / "operator-global-settings.target.sha256", 0o600)
                target_readable = True
            except OSError:
                target_readable = False

        # 4. the exact replacement bytes that will be installed
        (run_dir / "restore-neutral.json").write_bytes(restore_bytes)  # noqa: raw-pathlib-controller-only — owner-only record of the installed replacement.
        os.chmod(run_dir / "restore-neutral.json", 0o600)

        # 5. manifest
        manifest = {
            "issue": "1985",
            "operator_global": str(operator_global),
            "link_target_raw": link_target_raw,
            "link_target_real": link_target_real,
            "target_root": str(detection.get("target_root", "")),
            "matched_layout": detection.get("matched_layout", ""),
            "matched_agent": detection.get("matched_agent", ""),
            "target_readable": target_readable,
            "target_sha256": target_sha256,
            "restore_mode": restore_mode,
            "restore_source": restore_source,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "rollback": [
                f'rm -f "{operator_global}"',
                f'ln -s "$(cat \'{run_dir}/operator-global-settings.link-target.txt\')" "{operator_global}"',
            ],
        }
        (run_dir / "manifest.json").write_text(  # noqa: raw-pathlib-controller-only — owner-only manifest.
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        os.chmod(run_dir / "manifest.json", 0o600)

        # 6. operator-facing ROLLBACK.txt
        rollback_txt = (
            "# Issue #1985 operator-global settings de-hijack rollback\n"
            "#\n"
            "# This backup was written before agb upgrade replaced a hijacked\n"
            f"# {operator_global}\n"
            "# (a symlink into a bridge settings.effective.json) with a neutral\n"
            "# Claude Code settings file.\n"
            "#\n"
            "# 1. Restore the previous symlink exactly (undo the repair):\n"
            f'rm -f "{operator_global}"\n'
            f"ln -s \"$(cat '{run_dir}/operator-global-settings.link-target.txt')\" "
            f'"{operator_global}"\n'
            "#\n"
            "# 2. Keep the repaired neutral file but inspect the saved target evidence:\n"
            f"less '{run_dir}/operator-global-settings.target.json'\n"
        )
        (run_dir / "ROLLBACK.txt").write_text(rollback_txt, encoding="utf-8")  # noqa: raw-pathlib-controller-only — owner-only rollback note.
        os.chmod(run_dir / "ROLLBACK.txt", 0o600)
    except OSError as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result

    result["ok"] = True
    result["target_readable"] = target_readable
    return result


def repair_operator_global_settings_hijack(
    detection: dict[str, Any],
    restore_bytes: bytes,
) -> dict[str, Any]:
    """Install the replacement file over the hijacked symlink ATOMICALLY.

    Stages a same-directory temp file, JSON-validates it, chmod 0600, then
    `os.replace` so the SYMLINK ITSELF is replaced (os.replace does not follow
    the link — it never touches the bridge effective target). Post-checks with
    lstat that the final path is a regular non-symlink valid-JSON file.

    Returns {ok: bool, error?}. On failure after staging, best-effort removes the
    temp file; that cleanup error never masks the primary failure.
    """
    operator_global = Path(detection["operator_global"])
    result: dict[str, Any] = {"ok": False}
    parent = operator_global.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — ensure operator ~/.claude exists; operator-owned.
    except OSError as exc:
        result["error"] = f"mkdir parent: {type(exc).__name__}: {exc}"
        return result

    # Validate the replacement bytes are a JSON object before staging.
    try:
        parsed = json.loads(restore_bytes.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        result["error"] = f"replacement is not valid JSON: {type(exc).__name__}: {exc}"
        return result
    if not isinstance(parsed, dict):
        result["error"] = "replacement JSON is not an object"
        return result

    tmp_path: Path | None = None
    try:
        fd, tmp_name = tempfile.mkstemp(
            prefix=".settings.json.1985-", dir=str(parent)
        )
        tmp_path = Path(tmp_name)
        with os.fdopen(fd, "wb") as handle:
            handle.write(restore_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, 0o600)
        # Re-validate the staged file on disk.
        with tmp_path.open("rb") as handle:
            json.loads(handle.read().decode("utf-8"))
        os.replace(tmp_path, operator_global)
        tmp_path = None
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        if tmp_path is not None:
            with contextlib.suppress(OSError):
                tmp_path.unlink()  # noqa: raw-pathlib-controller-only — best-effort staged-temp cleanup.
        return result

    # Post-check: final path is a regular non-symlink valid-JSON file.
    try:
        final_st = os.lstat(operator_global)  # noqa: raw-pathlib-controller-only — post-replace verify.
        if S_ISLNK(final_st.st_mode):
            result["error"] = "post-check: operator global is still a symlink"
            return result
        with operator_global.open("rb") as handle:
            json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        result["error"] = f"post-check failed: {type(exc).__name__}: {exc}"
        return result

    result["ok"] = True
    result["mode"] = oct(final_st.st_mode & 0o777)
    return result


def run_operator_global_settings_hijack_sweep(
    args: argparse.Namespace,
    target_root: Path,
) -> dict[str, Any]:
    """Detect (always) + repair (only with the explicit flag) the operator-global
    settings hijack. Returns the stable `operator_global_settings_hijack` payload.

    Report-only is the default and NEVER mutates / NEVER fails the upgrade. This
    function is exception-safe: a classify error is reported as status=error in
    the payload (the caller decides whether it counts as a cleanup_failure).
    """
    operator_global = resolve_operator_global_settings_file(args)
    repair_requested = bool(getattr(args, "repair_operator_global_settings_hijack", False))
    restore_file = getattr(args, "operator_global_settings_restore_file", "") or ""

    detection = classify_operator_global_settings_hijack(operator_global, target_root)
    detection["target_root"] = str(target_root)
    payload: dict[str, Any] = dict(detection)
    payload["repair_requested"] = repair_requested
    payload["backup_dir"] = ""
    payload["restore_mode"] = "report-only"
    payload["rollback"] = ""

    if payload["status"] != "detected":
        # absent / non_symlink / symlink_non_bridge / error — nothing to repair.
        if payload["status"] == "error":
            payload["message"] = payload.get("message", "classify error")
        else:
            payload.setdefault("message", "no operator-global settings hijack detected")
        return payload

    if not repair_requested:
        payload["message"] = (
            "operator-global settings is a symlink into a bridge effective file; "
            "re-run with --repair-operator-global-settings-hijack to back up and "
            "replace it with a neutral Claude settings file"
        )
        return payload

    # --- Repair path (explicit flag) ---
    # Resolve the replacement bytes.
    restore_mode = "neutral"
    restore_source = ""
    restore_bytes = OPERATOR_GLOBAL_NEUTRAL_SETTINGS.encode("utf-8")
    if restore_file.strip():
        restore_path = Path(restore_file).expanduser()
        try:
            rst = os.lstat(restore_path)  # noqa: raw-pathlib-controller-only — validate explicit restore-file.
        except OSError as exc:
            payload["status"] = "repair_failed"
            payload["message"] = f"restore-file unreadable: {type(exc).__name__}: {exc}"
            return payload
        if S_ISLNK(rst.st_mode):
            payload["status"] = "repair_failed"
            payload["message"] = "restore-file must be a regular file, not a symlink"
            return payload
        if not S_ISREG(rst.st_mode):
            payload["status"] = "repair_failed"
            payload["message"] = (
                "restore-file must be a regular file "
                "(not a directory, fifo, device, or socket)"
            )
            return payload
        try:
            candidate = restore_path.read_bytes()  # noqa: raw-pathlib-controller-only — read explicit trusted restore-file.
            parsed = json.loads(candidate.decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError) as exc:
            payload["status"] = "repair_failed"
            payload["message"] = f"restore-file is not valid JSON: {type(exc).__name__}: {exc}"
            return payload
        if not isinstance(parsed, dict):
            payload["status"] = "repair_failed"
            payload["message"] = "restore-file JSON must be an object"
            return payload
        restore_bytes = candidate
        restore_mode = "explicit-restore-file"
        restore_source = str(restore_path)

    payload["restore_mode"] = restore_mode

    # Re-run detection immediately before backup (TOCTOU narrowing). The recheck
    # result is what backup + repair act on — NOT the original detection — so a
    # symlink that re-pointed between the first classify and now is backed up and
    # replaced against its CURRENT raw target (the backed-up symlink + manifest
    # never record a stale link target).
    recheck = classify_operator_global_settings_hijack(operator_global, target_root)
    if recheck.get("status") != "detected":
        payload["status"] = recheck.get("status", "error")
        payload["message"] = (
            "operator-global state changed before repair; left untouched "
            f"(recheck status={recheck.get('status')})"
        )
        return payload
    recheck["target_root"] = str(target_root)
    # Surface the (possibly re-pointed) current target in the report payload too.
    payload["link_target_raw"] = recheck.get("link_target_raw", "")
    payload["link_target_real"] = recheck.get("link_target_real", "")
    payload["matched_layout"] = recheck.get("matched_layout", "")
    payload["matched_agent"] = recheck.get("matched_agent", "")

    backup_parent = (
        Path(args.operator_global_settings_hijack_backup_dir).expanduser()
        if getattr(args, "operator_global_settings_hijack_backup_dir", "")
        else (target_root / "backups" / "operator-global-settings-hijack")
    )
    backup = backup_operator_global_settings_hijack(
        recheck, backup_parent, restore_bytes, restore_mode, restore_source
    )
    payload["backup_dir"] = backup.get("backup_dir", "")
    if not backup.get("ok"):
        payload["status"] = "repair_failed"
        payload["message"] = (
            "backup failed; operator-global symlink left UNCHANGED: "
            + backup.get("error", "unknown")
        )
        return payload

    payload["rollback"] = f"see {payload['backup_dir']}/ROLLBACK.txt"
    repair = repair_operator_global_settings_hijack(recheck, restore_bytes)
    if not repair.get("ok"):
        payload["status"] = "repair_failed"
        payload["message"] = (
            "replace failed after backup; operator-global symlink left UNCHANGED "
            "(backup retained): " + repair.get("error", "unknown")
        )
        return payload

    payload["status"] = "repaired"
    payload["message"] = (
        "operator-global settings symlink backed up and replaced with a neutral "
        f"Claude settings file ({restore_mode}); rollback at "
        f"{payload['backup_dir']}/ROLLBACK.txt"
    )
    return payload


def _warn_operator_global_settings_hijack(hijack: dict[str, Any]) -> None:
    """Emit a stderr warning for the loud #1985 statuses so a standalone manual
    `cleanup-residue` run surfaces them even when nobody reads the JSON. stdout
    stays pure JSON (emit_json owns it); only stderr is touched here.
    """
    status = hijack.get("status", "")
    if status not in ("detected", "repaired", "repair_failed"):
        return
    op = hijack.get("operator_global", "~/.claude/settings.json")
    if status == "detected":
        sys.stderr.write(
            f"[bridge-upgrade] WARNING (#1985): operator-global settings '{op}' is "
            "a symlink into a bridge effective file (report-only — no change made). "
            "Re-run cleanup-residue with --repair-operator-global-settings-hijack "
            "to back it up and replace it with a neutral Claude settings file.\n"
        )
    elif status == "repaired":
        sys.stderr.write(
            f"[bridge-upgrade] (#1985): operator-global settings '{op}' was backed "
            f"up and replaced with a neutral Claude settings file; rollback at "
            f"{hijack.get('backup_dir', '?')}/ROLLBACK.txt\n"
        )
    else:  # repair_failed
        sys.stderr.write(
            f"[bridge-upgrade] ERROR (#1985): repair of operator-global settings "
            f"'{op}' FAILED; symlink left unchanged: {hijack.get('message', '?')}\n"
        )


def cmd_cleanup_residue(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    # PR #508 r2: default these to the canonical layout under target_root.
    # Without the defaults, `cleanup-residue --target-root <root>` (the
    # exact form in OPERATOR_ACTIONS_PENDING.md and in the upgrader's
    # printed recovery command) would skip stale-tmp / daily-prune /
    # upgrade-* prune entirely — defeating the manual fallback path.
    backup_dir = (
        Path(args.backup_dir).expanduser()
        if args.backup_dir
        else (target_root / "backups" / "daily")
    )
    upgrade_backups_dir = (
        Path(args.upgrade_backups_dir).expanduser()
        if args.upgrade_backups_dir
        else (target_root / "backups")
    )
    current_backup_root = (
        Path(args.current_backup_root).expanduser() if args.current_backup_root else None
    )
    retain_days = max(1, int(args.daily_retain_days))
    upgrade_retain_count = max(0, int(args.upgrade_retain_count))
    upgrade_retain_days = max(0, int(args.upgrade_retain_days))
    today = date.today()

    payload: dict[str, Any] = {
        "mode": "cleanup-residue",
        "target_root": str(target_root),
        "backup_dir": str(backup_dir) if backup_dir else "",
        "upgrade_backups_dir": str(upgrade_backups_dir) if upgrade_backups_dir else "",
        "no_backup_mode": bool(args.no_backup_mode),
        "stale_tmp_removed": [],
        "daily_pruned": [],
        "snapshots_pruned": [],
        "upgrade_backups": {},
        "claude_config": {},
        "operator_global_settings_hijack": {},
        "free_bytes_before": 0,
        "free_bytes_after": 0,
        "cleanup_failures": [],
    }

    measure_path = backup_dir if (backup_dir and backup_dir.exists()) else target_root
    if measure_path and measure_path.exists():
        payload["free_bytes_before"] = _free_bytes(measure_path)

    # 1. stale tmp reaping (no grace gate when run from upgrade — the
    # upgrade wouldn't proceed if the daemon were mid-write of yesterday's
    # tarball; in fact upgrade stops the daemon before this point). Use
    # the env-tuned grace anyway as defense in depth.
    if backup_dir and backup_dir.exists():
        try:
            payload["stale_tmp_removed"] = reap_stale_daily_backup_tmp(backup_dir)
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "stale_tmp_reap", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 2. daily archive prune at the new retain default.
    if backup_dir and backup_dir.exists():
        try:
            payload["daily_pruned"] = prune_daily_backup_archives(
                backup_dir, retain_days, today
            )
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "daily_prune", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 3. SQL snapshot prune.
    try:
        payload["snapshots_pruned"] = prune_sqlite_snapshots(
            target_root, retain_days, today
        )
    except Exception as exc:
        payload["cleanup_failures"].append(
            {"step": "snapshot_prune", "error": f"{type(exc).__name__}: {exc}"}
        )

    # 4. upgrade-* prune (conservative; preserves current BACKUP_ROOT).
    if upgrade_backups_dir is not None:
        try:
            payload["upgrade_backups"] = prune_upgrade_backups(
                upgrade_backups_dir,
                current_backup_root=current_backup_root,
                retain_count=upgrade_retain_count,
                retain_days=upgrade_retain_days,
                today=today,
                no_backup_mode=bool(args.no_backup_mode),
            )
            errors = payload["upgrade_backups"].get("errors") or []
            for err in errors:
                payload["cleanup_failures"].append(
                    {"step": "upgrade_prune", "error": err.get("error", "unknown"),
                     "path": err.get("path", "")}
                )
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "upgrade_prune", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 5. ~/.claude.json validation (read-only).
    try:
        payload["claude_config"] = validate_claude_config(
            Path(args.claude_config_path).expanduser()
            if args.claude_config_path
            else Path.home() / ".claude.json"
        )
    except Exception as exc:
        payload["cleanup_failures"].append(
            {"step": "claude_config", "error": f"{type(exc).__name__}: {exc}"}
        )

    # 6. Issue #1985: operator-global settings hijack detect (always) + repair
    # (explicit flag only). Report-only is the default and never mutates / never
    # fails the upgrade — so a report-only `detected` does NOT add to
    # cleanup_failures. Only an unexpected classify error or a *requested* repair
    # that failed (backup/replace) counts as a cleanup failure.
    try:
        hijack = run_operator_global_settings_hijack_sweep(args, target_root)
        payload["operator_global_settings_hijack"] = hijack
        status = hijack.get("status", "")
        # Warn on stderr too (stdout stays pure JSON): a standalone manual
        # `cleanup-residue` run may never read the JSON, so the louder statuses
        # must surface even without the renderer.
        _warn_operator_global_settings_hijack(hijack)
        if status == "error":
            payload["cleanup_failures"].append(
                {"step": "operator_global_settings_hijack",
                 "error": hijack.get("message", "classify error")}
            )
        elif status == "repair_failed":
            payload["cleanup_failures"].append(
                {"step": "operator_global_settings_hijack",
                 "error": hijack.get("message", "repair failed")}
            )
    except Exception as exc:
        payload["operator_global_settings_hijack"] = {
            "status": "error",
            "message": f"{type(exc).__name__}: {exc}",
        }
        payload["cleanup_failures"].append(
            {"step": "operator_global_settings_hijack",
             "error": f"{type(exc).__name__}: {exc}"}
        )

    if measure_path and measure_path.exists():
        payload["free_bytes_after"] = _free_bytes(measure_path)
    payload["free_bytes_before_human"] = _format_bytes(payload["free_bytes_before"])
    payload["free_bytes_after_human"] = _format_bytes(payload["free_bytes_after"])
    payload["bytes_freed"] = max(
        0, payload["free_bytes_after"] - payload["free_bytes_before"]
    )
    payload["bytes_freed_human"] = _format_bytes(payload["bytes_freed"])

    return emit_json(payload, 0)


def cmd_apply_live(args: argparse.Namespace) -> int:
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    base_ref = resolve_base_ref(target_root, args.base_ref or "")
    payload = apply_live(
        source_root,
        target_root,
        base_ref,
        bool(args.dry_run),
        bool(args.strict_merge),
        run_id=str(getattr(args, "run_id", "") or ""),
        upstream_ref=str(getattr(args, "upstream_ref", "") or ""),
    )
    return emit_json(payload, 2 if payload.get("aborted") else 0)


def cmd_write_state(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    source_root = Path(args.source_root).expanduser()
    payload = {
        "updated_at": now_iso(),
        "source_root": str(source_root),
        "version": args.version or read_source_version(source_root),
        "source_ref": args.source_ref or git_ref(source_root),
        "source_head": git_head(source_root),
        "channel": args.channel or "",
        "backup_root": str(Path(args.backup_root).expanduser()) if args.backup_root else "",
    }
    analysis_payload = load_json_arg(args.analysis_json, args.analysis_json_file)
    if analysis_payload:
        payload["analysis"] = analysis_payload
    save_json(upgrade_state_path(target_root), payload)
    return emit_json(payload, 0)


def cmd_rollback_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_root = Path(args.backup_root).expanduser() if args.backup_root else latest_backup_root(target_root)
    if backup_root is None:
        raise SystemExit("no upgrade backup found")
    payload = {
        "mode": "upgrade-rollback",
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "dry_run": bool(args.dry_run),
        "restored": False,
        "removed_entries": 0,
    }
    if not args.dry_run:
        payload["removed_entries"] = restore_live_backup(target_root, backup_root)
        payload["restored"] = True
    return emit_json(payload, 0)


def _resolve_conflict_path(target_root: Path, raw: str) -> Path:
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = (target_root / candidate).resolve()
    else:
        candidate = candidate.resolve(strict=False)
    return candidate


def _confirm_or_abort(prompt: str, yes: bool) -> bool:
    if yes:
        return True
    if not sys.stdin.isatty():
        print(
            f"refusing without confirmation: pass --yes to proceed ({prompt})",
            file=sys.stderr,
        )
        return False
    try:
        answer = input(f"{prompt} [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer in {"y", "yes"}


def cmd_conflicts_list(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    files = list_conflict_files(target_root)
    rows: list[dict[str, Any]] = []
    now = datetime.now(timezone.utc)
    for path in files:
        try:
            st = path.stat()
        except OSError:
            continue
        mtime = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc)
        record_entry = lookup_conflict_record(target_root, path)
        live_target = ""
        at_write = ""
        hash_changed: bool | None = None
        if record_entry is not None:
            live_target = str(record_entry.get("live_target") or "")
            at_write = str(record_entry.get("live_target_sha256_at_write") or "")
            if live_target:
                live_target_path = Path(live_target)
                current = file_sha256(live_target_path) if path_exists_noexcept(live_target_path) else ""
                if at_write:
                    hash_changed = current != at_write
        rows.append(
            {
                "path": str(path),
                "live_target": live_target,
                "size": st.st_size,
                "mtime": mtime.astimezone().isoformat(timespec="seconds"),
                "age_seconds": int(max(0, (now - mtime).total_seconds())),
                "live_target_sha256_at_write": at_write,
                "live_target_hash_changed_since_write": hash_changed,
            }
        )
    rows.sort(key=lambda row: row["mtime"], reverse=True)
    if args.json:
        return emit_json({"conflicts": rows, "count": len(rows)}, 0)
    if not rows:
        print("(no pending .upgrade-conflict files)")
        return 0
    print("path\tsize\tmtime\tage\thash-changed")
    for row in rows:
        age = row["age_seconds"]
        if age < 3600:
            age_str = f"{age // 60}m"
        elif age < 86400:
            age_str = f"{age // 3600}h"
        else:
            age_str = f"{age // 86400}d"
        hash_state = (
            "changed"
            if row["live_target_hash_changed_since_write"] is True
            else (
                "unchanged"
                if row["live_target_hash_changed_since_write"] is False
                else "unknown"
            )
        )
        print(f"{row['path']}\t{row['size']}\t{row['mtime']}\t{age_str}\t{hash_state}")
    print(f"total: {len(rows)} conflict file(s)")
    return 0


def cmd_conflicts_diff(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file():
        print(f"not a conflict file: {conflict}", file=sys.stderr)
        return 1
    if not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    live = conflict.with_name(conflict.name[: -len(".upgrade-conflict")])
    if not live.exists():
        print(f"live target missing: {live}", file=sys.stderr)
        return 1
    proc = subprocess.run(
        ["diff", "-u", "--", str(live), str(conflict)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    sys.stdout.buffer.write(proc.stdout)
    if proc.stderr:
        sys.stderr.buffer.write(proc.stderr)
    return 0 if proc.returncode in {0, 1} else proc.returncode


# Git merge-file --diff3 marker forms. A marker is a line that STARTS with
# exactly seven identical marker chars, optionally followed by a space + a
# label (`<<<<<<< live`, `||||||| base`, `>>>>>>> upstream`) or, for the
# divider, the seven chars alone (`=======`). We anchor to start-of-line and
# require the 8th char to be a space or end-of-line so a legitimate content
# line that merely begins with `=======` followed by more `=` (e.g. a Markdown
# `========` heading underline) or by non-space text is NOT a false positive.
_CONFLICT_MARKER_RE = re.compile(
    rb"^(?:<<<<<<<|\|\|\|\|\|\|\||>>>>>>>|=======)(?:[ \t].*)?$"
)


def _scan_conflict_markers(data: bytes) -> list[int]:
    """Return 1-based line numbers of any unresolved diff3 conflict markers."""
    hits: list[int] = []
    for lineno, line in enumerate(data.split(b"\n"), start=1):
        # Strip a trailing CR so CRLF sidecars are still matched.
        if _CONFLICT_MARKER_RE.match(line.rstrip(b"\r")):
            hits.append(lineno)
    return hits


def _syntax_check_for_target(live: Path, data: bytes) -> str | None:
    """Best-effort syntax validation of the already-read sidecar bytes against
    the live target's type. Returns an error string on failure, or None when
    the file type is unchecked or the check passes. Validates the SAME bytes
    that will be written (no re-read), and never imports/execs them — for `.py`
    it parse-compiles the in-memory bytes (no `.pyc` cache, no module load), so
    adopting a broken bridge-upgrade.py cannot re-enter the half-written
    module."""
    suffix = live.suffix.lower()
    name = live.name
    if suffix == ".py":
        try:
            # Parse + compile the bytes only; writes nothing to disk and does
            # not import/exec. `dont_inherit` keeps the current process's
            # __future__ flags out of the check.
            compile(data, str(live), "exec", dont_inherit=True)
        except (SyntaxError, ValueError) as exc:
            return str(exc).strip()
        return None
    if suffix == ".sh" or name in {"agent-bridge", "agb"}:
        proc = subprocess.run(
            ["bash", "-n", "/dev/stdin"],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            return (proc.stderr or proc.stdout).decode("utf-8", errors="replace").strip() or "bash -n failed"
    return None


def cmd_conflicts_adopt(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    live = conflict.with_name(conflict.name[: -len(".upgrade-conflict")])

    # Fail-closed content guard (#1601). The sidecar holds `git merge-file
    # --diff3` output, i.e. it may still contain unresolved conflict markers.
    # Adopting marker-laden / unparseable content over a working live file can
    # brick the very tool used to recover (CLAUDE.md high-risk area #3), and
    # the post-copy unlink would destroy the only obvious recovery artifact.
    # So we validate BEFORE copying and NEVER unlink on failure. --force is the
    # documented escape hatch for an operator who has knowingly hand-merged.
    force = bool(getattr(args, "force", False))
    try:
        sidecar_bytes = conflict.read_bytes()
    except OSError as exc:
        print(f"cannot read conflict sidecar: {conflict}: {exc}", file=sys.stderr)
        return 1

    if not force:
        marker_lines = _scan_conflict_markers(sidecar_bytes)
        if marker_lines:
            preview = ", ".join(str(n) for n in marker_lines[:10])
            if len(marker_lines) > 10:
                preview += ", …"
            print(
                f"refusing to adopt: {conflict} still contains unresolved conflict "
                f"markers at line(s): {preview}.\n"
                f"Resolve the markers in the sidecar first (see "
                f"`agb upgrade conflicts diff {conflict}`), then re-run adopt. "
                f"The sidecar has been left in place. Pass --force to override.",
                file=sys.stderr,
            )
            return 1
        syntax_err = _syntax_check_for_target(live, sidecar_bytes)
        if syntax_err is not None:
            print(
                f"refusing to adopt: {conflict} fails a syntax check for the live "
                f"target {live.name}:\n{syntax_err}\n"
                f"Fix the sidecar first, then re-run adopt. The sidecar has been "
                f"left in place. Pass --force to override.",
                file=sys.stderr,
            )
            return 1

    if not _confirm_or_abort(f"adopt {conflict} → {live}?", bool(args.yes)):
        return 1

    # Keep a `.pre-adopt` snapshot of the prior live bytes so even a --force'd
    # (or marker-free-but-still-wrong) adopt remains recoverable. Best-effort:
    # a missing live target is fine (the conflict path can pre-date the live
    # file in some scaffold cases).
    if live.exists():
        backup = live.with_name(f"{live.name}.pre-adopt")
        try:
            shutil.copyfile(live, backup)
        except OSError as exc:
            # The backup-before-overwrite invariant is load-bearing: if the
            # prior live bytes cannot be snapshotted, REFUSE before mutating
            # live. A non-writable PARENT DIR with a still-writable live file
            # would otherwise let the overwrite succeed WITHOUT a `.pre-adopt`
            # recovery copy (and then crash on the sidecar unlink) — exactly the
            # data-loss this guard exists to prevent (#1601 patch-dev re-review).
            # Controlled nonzero, no traceback, sidecar left in place.
            print(
                f"refusing to adopt: could not snapshot the prior live file to "
                f"{backup} ({exc}). The live file is UNCHANGED and the sidecar "
                f"is left in place. Fix the destination (e.g. parent-directory "
                f"permissions) and re-run adopt.",
                file=sys.stderr,
            )
            return 1

    # Only after the guard has passed do we mutate the live file, and only
    # after a successful write do we unlink the sidecar (the recovery artifact).
    # Write the EXACT bytes we validated (no re-read of `conflict`) so a sidecar
    # that changed during the prompt / between validate and copy cannot slip
    # marker-laden content past the guard. `open(wb)` preserves the live file's
    # existing mode (it overwrites contents, not the inode's permissions).
    try:
        with open(live, "wb") as handle:
            handle.write(sidecar_bytes)
    except OSError as exc:
        print(f"adopt failed writing {live}: {exc}", file=sys.stderr)
        return 1
    try:
        conflict.unlink()
    except OSError as exc:
        # The live file was already written successfully; failing to remove the
        # sidecar (e.g. a non-writable parent dir) is non-fatal — it is now a
        # stale recovery artifact, not corruption. Surface a CONTROLLED warning
        # rather than a traceback (#1601 patch-dev re-review).
        print(
            f"warning: adopted {live} but could not remove the sidecar "
            f"{conflict}: {exc}. Remove it manually.",
            file=sys.stderr,
        )
    write_conflict_audit(
        target_root,
        "conflict_adopt",
        {"conflict": str(conflict), "live_target": str(live), "forced": force},
    )
    return emit_json(
        {"action": "adopt", "conflict": str(conflict), "live_target": str(live), "forced": force},
        0,
        indent=None,
    )


def cmd_conflicts_discard(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    if not _confirm_or_abort(f"discard {conflict} (live unchanged)?", bool(args.yes)):
        return 1
    conflict.unlink()
    write_conflict_audit(
        target_root,
        "conflict_discard",
        {"conflict": str(conflict)},
    )
    return emit_json({"action": "discard", "conflict": str(conflict)}, 0, indent=None)


def cmd_conflicts_archive(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    if not _confirm_or_abort(f"archive {conflict} (live unchanged)?", bool(args.yes)):
        return 1
    dest = archive_conflict_file(target_root, conflict)
    write_conflict_audit(
        target_root,
        "conflict_archive",
        {"conflict": str(conflict), "archived_to": str(dest), "reason": "manual"},
    )
    return emit_json(
        {"action": "archive", "conflict": str(conflict), "archived_to": str(dest)},
        0,
        indent=None,
    )


def cmd_conflicts_reconcile(args: argparse.Namespace) -> int:
    """Auto-archive conflict files whose live target hash has not changed
    since the conflict was written.

    Operator semantics: an unchanged hash means the operator either
    explicitly kept the live version (their pre-write content survived
    the upgrade) or never touched it AND the conflict has not been
    re-deposited by a fresh merge in the meantime — either way the
    conflict file is no longer informative. A changed hash means the
    operator may be mid-reconcile (adopt-in-progress, partial edit), so
    we leave it alone.

    Only `--auto-archive` actually mutates state. Without the flag this
    is a read-only report (suitable for `agb status` integration).
    """
    target_root = Path(args.target_root).expanduser().resolve()
    files = list_conflict_files(target_root)
    actions: list[dict[str, Any]] = []
    for conflict in files:
        record_entry = lookup_conflict_record(target_root, conflict)
        if record_entry is None:
            actions.append(
                {
                    "conflict": str(conflict),
                    "decision": "skip",
                    "reason": "no structured record found",
                }
            )
            continue
        live_target = Path(str(record_entry.get("live_target") or ""))
        at_write = str(record_entry.get("live_target_sha256_at_write") or "")
        if not at_write:
            actions.append(
                {
                    "conflict": str(conflict),
                    "decision": "skip",
                    "reason": "missing at-write hash",
                }
            )
            continue
        current = file_sha256(live_target) if live_target.exists() else ""
        if current == at_write:
            decision = "auto-archive"
            reason = "live hash unchanged since conflict write"
        else:
            decision = "skip"
            reason = "live hash changed since conflict write"
        action = {
            "conflict": str(conflict),
            "live_target": str(live_target),
            "live_target_sha256_at_write": at_write,
            "live_target_sha256_now": current,
            "decision": decision,
            "reason": reason,
        }
        if decision == "auto-archive" and bool(args.auto_archive):
            try:
                dest = archive_conflict_file(target_root, conflict)
                action["archived_to"] = str(dest)
                write_conflict_audit(
                    target_root,
                    "conflict_auto_archive",
                    {
                        "conflict": str(conflict),
                        "archived_to": str(dest),
                        "live_target": str(live_target),
                        "reason": reason,
                    },
                )
            except OSError as exc:
                action["decision"] = "skip"
                action["reason"] = f"archive failed: {exc}"
        actions.append(action)
    payload = {
        "mode": "upgrade-conflicts-reconcile",
        "target_root": str(target_root),
        "auto_archive": bool(args.auto_archive),
        "actions": actions,
        "archived_count": sum(
            1 for entry in actions if entry.get("decision") == "auto-archive" and "archived_to" in entry
        ),
        "skipped_count": sum(1 for entry in actions if entry.get("decision") == "skip"),
    }
    if bool(args.auto_archive) and payload["archived_count"]:
        receipt_path = (
            target_root
            / "state"
            / "upgrade-conflicts"
            / f"auto-archive-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
        )
        save_json(receipt_path, payload)
    return emit_json(payload, 0)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-upgrade.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate = subparsers.add_parser("migrate-agents")
    migrate.add_argument("--source-root", required=True)
    migrate.add_argument("--target-root", required=True)
    migrate.add_argument("--admin-agent", default="")
    migrate.add_argument("--dry-run", action="store_true")
    # Issue #1611: escape hatch to force-include orphan / non-roster dirs.
    # Default is roster-restricted; this opt-in restores the pre-#1611
    # "migrate every dir under agents/" behavior for operators who want it.
    migrate.add_argument("--migrate-all-agents", action="store_true")
    migrate.set_defaults(handler=cmd_migrate_agents)

    # Issue #1809: focused codex AGENTS.md backfill pass for the daemon
    # doc-backfill hygiene cadence (process_agent_doc_backfill). Touches ONLY
    # the codex instruction entrypoint (home create-if-absent + managed-block
    # refresh + workdir mirror), not the full template/scaffold migration.
    backfill_entry = subparsers.add_parser("backfill-codex-entrypoints")
    backfill_entry.add_argument("--source-root", required=True)
    backfill_entry.add_argument("--target-root", required=True)
    backfill_entry.add_argument("--admin-agent", default="")
    backfill_entry.add_argument("--dry-run", action="store_true")
    backfill_entry.set_defaults(handler=cmd_backfill_codex_entrypoints)

    # Issue #4769 (reverts #517): the inject subcommand for the admin
    # pair-programming managed block is removed together with the admin
    # codex pair auto-backfill it served. Operators who explicitly
    # maintain a pair-programming SOP block do so in the admin's
    # CLAUDE.md directly; nothing else in the runtime parses the
    # markers, so no managed refresh is needed.

    backup = subparsers.add_parser("backup-live")
    backup.add_argument("--target-root", required=True)
    backup.add_argument("--backup-root", required=True)
    backup.add_argument("--source-root")
    backup.add_argument("--analysis-json", default="")
    backup.add_argument("--analysis-json-file", default="")
    backup.add_argument("--migration-json", default="")
    backup.add_argument("--migration-json-file", default="")
    backup.add_argument("--dry-run", action="store_true")
    backup.set_defaults(handler=cmd_backup_live)

    extend = subparsers.add_parser(
        "backup-extend-live",
        help=(
            "Extend an existing backup snapshot with files that a later upgrade "
            "stage (e.g. bridge-docs.py apply) is about to mutate. Accepts the "
            "`changed_paths` JSON from `bridge-docs.py apply --dry-run --json`."
        ),
    )
    extend.add_argument("--target-root", required=True)
    extend.add_argument("--backup-root", required=True)
    extend.add_argument(
        "--paths-json",
        default="",
        help="JSON payload matching bridge-docs.py --json output (expects a `changed_paths` key).",
    )
    extend.add_argument("--dry-run", action="store_true")
    extend.set_defaults(handler=cmd_backup_extend_live)

    daily_backup = subparsers.add_parser("daily-backup-live")
    daily_backup.add_argument("--target-root", required=True)
    daily_backup.add_argument("--backup-dir", required=True)
    # Bug #507 (3): default retention dropped from 30 → 7. Long-lived
    # installs were generating 45–60 GB of baseline disk consumption from
    # daily archives alone, which then triggered the disk-full death
    # spiral cascade. Operators who want the old behavior set
    # BRIDGE_DAILY_BACKUP_RETAIN_DAYS=30 (or pass --retain-days 30).
    daily_backup.add_argument("--retain-days", type=int, default=7)
    daily_backup.add_argument("--dry-run", action="store_true")
    daily_backup.set_defaults(handler=cmd_daily_backup_live)

    verify_tasks_db = subparsers.add_parser(
        "verify-tasks-db",
        help=(
            "Run PRAGMA quick_check against state/tasks.db in read-only mode "
            "and print a JSON result. Used by post-upgrade verification."
        ),
    )
    verify_tasks_db.add_argument("--target-root", required=True)
    verify_tasks_db.set_defaults(handler=cmd_verify_tasks_db)

    cleanup_residue = subparsers.add_parser(
        "cleanup-residue",
        help=(
            "Reap stale daily-backup tmp files, prune old archives + SQL "
            "snapshots, prune old upgrade-* backups (conservative), and "
            "validate ~/.claude.json. Used by `agb upgrade --apply` and "
            "available standalone."
        ),
    )
    cleanup_residue.add_argument("--target-root", required=True)
    cleanup_residue.add_argument(
        "--backup-dir", default="",
        help="Daily-backup directory (default: <target-root>/backups/daily)",
    )
    cleanup_residue.add_argument(
        "--upgrade-backups-dir", default="",
        help="Parent dir holding upgrade-* snapshots (default: <target-root>/backups)",
    )
    cleanup_residue.add_argument(
        "--current-backup-root", default="",
        help="Path of the in-progress upgrade backup (always preserved).",
    )
    cleanup_residue.add_argument(
        "--no-backup-mode", action="store_true",
        help="Set when invoked from `agb upgrade --no-backup`; skip upgrade-* prune.",
    )
    cleanup_residue.add_argument(
        "--daily-retain-days", type=int, default=7,
    )
    cleanup_residue.add_argument(
        "--upgrade-retain-count", type=int, default=5,
    )
    cleanup_residue.add_argument(
        "--upgrade-retain-days", type=int, default=14,
    )
    cleanup_residue.add_argument(
        "--claude-config-path", default="",
        help="Override path to .claude.json (default: ~/.claude.json).",
    )
    # Issue #1985: operator-global settings hijack detect/repair.
    cleanup_residue.add_argument(
        "--operator-global-settings-file", default="",
        help=(
            "Already-resolved operator-global Claude settings path "
            "(from the #1984 resolver). Default: ~/.claude/settings.json."
        ),
    )
    cleanup_residue.add_argument(
        "--repair-operator-global-settings-hijack", action="store_true",
        help=(
            "Repair (not just report) an operator-global settings symlink that "
            "points at a bridge effective file: back it up, then replace it with "
            "a neutral Claude settings file. Default is report-only."
        ),
    )
    cleanup_residue.add_argument(
        "--operator-global-settings-hijack-backup-dir", default="",
        help=(
            "Backup parent dir for the #1985 repair (default: "
            "<target-root>/backups/operator-global-settings-hijack)."
        ),
    )
    cleanup_residue.add_argument(
        "--operator-global-settings-restore-file", default="",
        help=(
            "Optional trusted regular JSON-object file to install instead of the "
            "neutral {} replacement during #1985 repair."
        ),
    )
    cleanup_residue.set_defaults(handler=cmd_cleanup_residue)

    apply_live_parser = subparsers.add_parser("apply-live")
    apply_live_parser.add_argument("--source-root", required=True)
    apply_live_parser.add_argument("--target-root", required=True)
    apply_live_parser.add_argument("--base-ref", default="")
    apply_live_parser.add_argument("--dry-run", action="store_true")
    apply_live_parser.add_argument("--strict-merge", action="store_true")
    # Issue #394: caller-supplied run-id stamps the structured record
    # at state/upgrade-conflicts/<run-id>.json. Empty → auto-generated.
    apply_live_parser.add_argument("--run-id", default="")
    # Issue #1602: dry-run-only ref for the upstream side of the preview. When
    # set, the upstream file set + bytes come from this ref's git tree (no
    # working-tree mutation) so `--ref <tag> --dry-run` previews the requested
    # ref. Rejected with a non-empty value unless --dry-run (apply must read
    # the checked-out tree). Empty → working tree, unchanged.
    apply_live_parser.add_argument("--upstream-ref", default="")
    apply_live_parser.set_defaults(handler=cmd_apply_live)

    analyze = subparsers.add_parser("analyze-live")
    analyze.add_argument("--source-root", required=True)
    analyze.add_argument("--target-root", required=True)
    analyze.add_argument("--base-ref", default="")
    # Issue #1602: see apply-live --upstream-ref. analyze-live has no apply
    # side, so no dry-run guard is needed; a set value always reads from the
    # ref's git tree.
    analyze.add_argument("--upstream-ref", default="")
    analyze.set_defaults(handler=cmd_analyze_live)

    write_state = subparsers.add_parser("write-state")
    write_state.add_argument("--source-root", required=True)
    write_state.add_argument("--target-root", required=True)
    write_state.add_argument("--backup-root", default="")
    write_state.add_argument("--analysis-json", default="")
    write_state.add_argument("--analysis-json-file", default="")
    write_state.add_argument("--version", default="")
    write_state.add_argument("--source-ref", default="")
    write_state.add_argument("--channel", default="")
    write_state.set_defaults(handler=cmd_write_state)

    rollback = subparsers.add_parser("rollback-live")
    rollback.add_argument("--target-root", required=True)
    rollback.add_argument("--backup-root", default="")
    rollback.add_argument("--dry-run", action="store_true")
    rollback.set_defaults(handler=cmd_rollback_live)

    # Issue #394: lifecycle subcommands for `*.upgrade-conflict` files.
    # The Bash dispatcher (`bridge-upgrade.sh conflicts ...`) forwards
    # diff/adopt/discard/archive/reconcile here; `list` is also wired
    # in Python so callers (CI, status surface) can stay in one runtime.
    conflicts_list = subparsers.add_parser("conflicts-list")
    conflicts_list.add_argument("--target-root", required=True)
    conflicts_list.add_argument("--json", action="store_true")
    conflicts_list.set_defaults(handler=cmd_conflicts_list)

    conflicts_diff = subparsers.add_parser("conflicts-diff")
    conflicts_diff.add_argument("--target-root", required=True)
    conflicts_diff.add_argument("path")
    conflicts_diff.set_defaults(handler=cmd_conflicts_diff)

    conflicts_adopt = subparsers.add_parser("conflicts-adopt")
    conflicts_adopt.add_argument("--target-root", required=True)
    conflicts_adopt.add_argument("--yes", action="store_true")
    conflicts_adopt.add_argument(
        "--force",
        action="store_true",
        help="skip the conflict-marker scan and syntax check (for a knowingly hand-merged sidecar)",
    )
    conflicts_adopt.add_argument("path")
    conflicts_adopt.set_defaults(handler=cmd_conflicts_adopt)

    conflicts_discard = subparsers.add_parser("conflicts-discard")
    conflicts_discard.add_argument("--target-root", required=True)
    conflicts_discard.add_argument("--yes", action="store_true")
    conflicts_discard.add_argument("path")
    conflicts_discard.set_defaults(handler=cmd_conflicts_discard)

    conflicts_archive = subparsers.add_parser("conflicts-archive")
    conflicts_archive.add_argument("--target-root", required=True)
    conflicts_archive.add_argument("--yes", action="store_true")
    conflicts_archive.add_argument("path")
    conflicts_archive.set_defaults(handler=cmd_conflicts_archive)

    conflicts_reconcile = subparsers.add_parser("conflicts-reconcile")
    conflicts_reconcile.add_argument("--target-root", required=True)
    conflicts_reconcile.add_argument("--auto-archive", action="store_true")
    conflicts_reconcile.set_defaults(handler=cmd_conflicts_reconcile)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
