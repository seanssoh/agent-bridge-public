#!/usr/bin/env python3
"""bridge-a2a.py — Agent Bridge cross-bridge task handoff (A2A) CLI + runner.

Subcommands (surfaced through `agent-bridge a2a ...`):

  send          Stage an outbound handoff into the durable outbox.
  outbox        list | retry | drop | gc — manage the sender outbox.
  inbox-dedupe  list | gc — inspect/prune the receiver dedupe ledger.
  peers         list | test <peer> — inspect configured peers.
  deliver       Drain the outbox: sign + POST each pending entry over the
                tailnet, with retry/backoff/jitter and dead-lettering.
  reconcile     Trigger + preview one receiver self-heal reconcile.
  migrate-identity  Rewrite raw-IP peers/listen to Tailscale identity keying
                so today's raw-`address` configs self-heal (dry-run default).

The receiver daemon lives in a separate file (`bridge-handoffd.py`).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import socket
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Optional

import bridge_a2a_common as a2a


# --------------------------------------------------------------------------
# small output helpers
# --------------------------------------------------------------------------

def err(msg: str) -> None:
    print(f"[a2a][error] {msg}", file=sys.stderr)


def info(msg: str) -> None:
    print(f"[a2a] {msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> "Optional[int]":
    err(msg)
    return code


def _audit_body_file_sudo_fallback(
    body_path: Path,
    iso_uid: str,
    success: bool,
    rc: "int | None",
    call_site: str,
    exception: "BaseException | None" = None,
) -> None:
    """Emit a ``body_file_sudo_fallback`` audit row (Lane J r2 SHOULD-FIX
    + r3 schema alignment).

    Mirrors ``bridge-queue.py:_audit_body_file_sudo_fallback`` for the
    A2A send path. See that helper for the rationale; this exists as a
    parallel copy because ``bridge-a2a.py`` does not import
    ``bridge-queue`` (and we deliberately avoid coupling the two CLIs
    through a shared module just for one audit hook).

    Lane J r3 (codex r2 SHOULD-FIX): align the row schema with the
    brief — the per-agent OS user field is named ``iso_uid`` (not
    ``owner``) and exception branches log ``exception`` +
    ``exception_type`` so the operator sees WHY the fallback failed.

    Best-effort: any failure to emit is swallowed silently.
    """
    import subprocess as _subprocess
    audit_path = (
        os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
        or os.path.expanduser(os.path.join(
            os.environ.get("BRIDGE_HOME", "").strip() or "~/.agent-bridge",
            "logs",
            "audit.jsonl",
        ))
    )
    detail = {
        "file_path": str(body_path),
        "iso_uid": iso_uid,
        "fallback_method": "sudo-read",
        "success": success,
        "rc": rc if rc is not None else "",
        "call_site": call_site,
    }
    if exception is not None:
        detail["exception"] = str(exception)
        detail["exception_type"] = type(exception).__name__
    audit_script = Path(__file__).resolve().with_name("bridge-audit.py")
    if not audit_script.is_file():
        return
    cmd = [
        sys.executable,
        str(audit_script),
        "write",
        "--file",
        audit_path,
        "--actor",
        "bridge-a2a",
        "--action",
        "body_file_sudo_fallback",
        "--target",
        str(body_path),
        "--detail-json",
        json.dumps(detail, ensure_ascii=True, sort_keys=True),
    ]
    try:
        Path(audit_path).expanduser().parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    try:
        _subprocess.run(
            cmd,
            stdin=_subprocess.DEVNULL,
            stdout=_subprocess.DEVNULL,
            stderr=_subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, _subprocess.TimeoutExpired):
        pass


def _sudo_read_text(path: Path) -> str | None:
    """v0.15.0-beta4 Lane J (#1280): sudo-fallback body-file reader.

    Mirrors ``bridge-queue.py:_sudo_read_body_file`` for the A2A send
    path. When the body file is owned by an isolated UID
    (``agent-bridge-<a>``) at mode 0660, the controller's bridge-a2a.py
    process may hit ``PermissionError`` despite being a normal CLI
    user. Drop to the owner via ``sudo -n -u <owner> cat`` (the
    pre-existing controller<->iso boundary; see
    ``lib/bridge-isolation-helpers.sh``) before surfacing the failure.
    Returns the decoded text on success, ``None`` on any failure.
    """
    try:
        st = path.stat()
    except OSError:
        return None
    try:
        import pwd as _pwd
        ent = _pwd.getpwuid(st.st_uid)
    except (KeyError, ImportError, OSError):
        return None
    owner = ent.pw_name
    prefix = os.environ.get("BRIDGE_AGENT_OS_USER_PREFIX", "agent-bridge-")
    if not owner.startswith(prefix):
        return None
    try:
        if os.geteuid() == st.st_uid:
            return None
    except OSError:
        return None
    import shutil
    sudo_bin = shutil.which("sudo") or "/usr/bin/sudo"
    if not Path(sudo_bin).is_file():
        return None
    import subprocess as _subprocess
    try:
        result = _subprocess.run(
            [sudo_bin, "-n", "-u", owner, "cat", "--", str(path)],
            stdin=_subprocess.DEVNULL,
            stdout=_subprocess.PIPE,
            stderr=_subprocess.PIPE,
            timeout=10,
        )
    except (OSError, _subprocess.TimeoutExpired) as exc:
        _audit_body_file_sudo_fallback(
            path, owner, success=False, rc=None,
            call_site="bridge-a2a.cmd_send",
            exception=exc,
        )
        return None
    if result.returncode != 0:
        _audit_body_file_sudo_fallback(
            path, owner, success=False, rc=result.returncode,
            call_site="bridge-a2a.cmd_send",
        )
        return None
    _audit_body_file_sudo_fallback(
        path, owner, success=True, rc=0,
        call_site="bridge-a2a.cmd_send",
    )
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return result.stdout.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------
# a2a send — stage an outbound entry into the durable outbox
# --------------------------------------------------------------------------

def cmd_send(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config()
        # #1331: fail-closed at send time too — surface the empty-secret
        # misconfiguration immediately, not only when the delivery runner
        # dead-letters the row. The peer-pair-narrow check below (after
        # `find_peer`) catches the more specific "this peer has no secret"
        # case so the operator sees the actionable error against the peer
        # they're trying to send to. The paired insecure-bind env vars are
        # honored — the helper itself enforces the paired flag.
        a2a.validate_config_peer_secrets(cfg, side="sender")
        peer = a2a.find_peer(cfg, args.peer)
        # Narrow check against the destination peer (covers the case
        # where ONLY this peer is missing a secret and the global check
        # was overridden by the test-bypass env pair).
        try:
            a2a.peer_send_secret(peer)
        except a2a.A2AError:
            if not a2a._allow_insecure_no_secret():
                raise
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    if args.priority not in a2a.VALID_PRIORITIES:
        return die(f"invalid --priority: {args.priority} "
                   f"(one of {', '.join(a2a.VALID_PRIORITIES)})") or 1

    # Resolve body from --body or --body-file.
    if args.body is not None and args.body_file is not None:
        return die("pass only one of --body / --body-file") or 1
    if args.body_file is not None:
        body_src = Path(args.body_file)
        if not body_src.is_file():
            return die(f"--body-file not found: {body_src}") or 1
        try:
            body_text = body_src.read_text(encoding="utf-8")
        except PermissionError as exc:
            # Issue #1280 (v0.15.0-beta4 Lane J): the body file may be
            # owned by an isolated UID (``agent-bridge-<a>`` at mode
            # 0660). Try the sudo-as-owner fallback before failing so
            # iso agent → controller workflows (brief → a2a send)
            # don't require a manual ``chmod 644`` on every send.
            fallback = _sudo_read_text(body_src)
            if fallback is None:
                return die(
                    f"--body-file unreadable: {body_src}: {exc} "
                    f"(iso UID may own this file; chmod 0644 or run "
                    f"`sudo -u <owner> cat {body_src}` to verify)"
                ) or 1
            body_text = fallback
    elif args.body is not None:
        body_text = args.body
    else:
        body_text = sys.stdin.read() if not sys.stdin.isatty() else ""

    if not args.title:
        return die("--title is required") or 1
    if not body_text and not args.allow_empty_body:
        return die("body is empty; pass --body/--body-file or "
                   "--allow-empty-body") or 1

    # bridge_id is the authenticated sender identity — it is what the
    # delivery runner signs + sends as X-AGB-Peer, and what the receiver
    # looks up in its inbound peer table. It MUST be explicitly set (a
    # hostname fallback would never match the receiver's allowlist).
    sender_bridge = cfg.get("bridge_id", "").strip()
    if not sender_bridge:
        return die("config has no 'bridge_id' — set it in handoff.local.json "
                   "to this bridge's id (the receiver matches it against "
                   "its inbound peer allowlist).") or 1
    sender_agent = args.from_agent or os.environ.get("BRIDGE_AGENT_ID") or os.environ.get("USER", "unknown")
    message_id = a2a.new_message_id(sender_bridge)

    body_bytes = body_text.encode("utf-8")
    body_hash = a2a.body_sha256(body_bytes)

    # Per-peer caps (sender-side fast fail; receiver re-checks).
    max_body = int(a2a.peer_cap(peer, "max_body_bytes", a2a.DEFAULT_MAX_BODY_BYTES))
    if len(body_bytes) > max_body:
        return die(f"body is {len(body_bytes)} bytes; peer {args.peer} cap is "
                   f"{max_body}. Trim the body or raise the cap.") or 1
    max_title = int(a2a.peer_cap(peer, "max_title_bytes", a2a.DEFAULT_MAX_TITLE_BYTES))
    if len(args.title.encode("utf-8")) > max_title:
        return die(f"title exceeds {max_title} bytes for peer {args.peer}") or 1

    envelope = a2a.build_envelope(
        message_id=message_id,
        sender_bridge=sender_bridge,
        sender_agent=sender_agent,
        target_agent=args.to,
        priority=args.priority,
        title=args.title,
        body=body_text,
        reply_peer=sender_bridge,
        reply_agent=sender_agent,
    )
    envelope_bytes = json.dumps(envelope, ensure_ascii=False).encode("utf-8")

    if args.dry_run:
        print(json.dumps({
            "dry_run": True,
            "message_id": message_id,
            "peer": args.peer,
            "peer_address": peer.get("address", ""),
            "target_agent": args.to,
            "priority": args.priority,
            "title": args.title,
            "body_bytes": len(body_bytes),
            "body_sha256": body_hash,
        }, ensure_ascii=False, indent=2))
        return 0

    a2a.ensure_handoff_dirs()
    conn = a2a.open_outbox()
    try:
        # Outbox caps — refuse new sends before unbounded disk growth.
        max_total = int(cfg.get("outbox_max_total_bytes", a2a.DEFAULT_OUTBOX_MAX_TOTAL_BYTES))
        if a2a.outbox_total_bytes(conn) + len(envelope_bytes) > max_total:
            return die(f"outbox over total-byte cap ({max_total}); run "
                       "'agent-bridge a2a outbox gc' or drain pending sends.") or 1
        max_pending = int(a2a.peer_cap(peer, "max_pending",
                                       cfg.get("outbox_max_pending_per_peer",
                                               a2a.DEFAULT_OUTBOX_MAX_PENDING_PER_PEER)))
        if a2a.outbox_pending_for_peer(conn, args.peer) >= max_pending:
            return die(f"peer {args.peer} has >= {max_pending} pending sends; "
                       "drain or 'agent-bridge a2a outbox gc' first.") or 1

        # Persist the full signed-able envelope to the outgoing/ staging dir.
        body_path = a2a.outgoing_dir() / f"{message_id.replace(':', '_').replace('/', '_')}.json"
        body_path.write_bytes(envelope_bytes)
        try:
            os.chmod(body_path, 0o600)
        except OSError:
            pass

        a2a.outbox_insert(
            conn,
            message_id=message_id,
            peer=args.peer,
            target_agent=args.to,
            priority=args.priority,
            title=args.title,
            body_path=str(body_path),
            body_sha256_hex=a2a.body_sha256(envelope_bytes),
            body_bytes=len(envelope_bytes),
        )
    finally:
        conn.close()

    print(f"queued A2A handoff {message_id} -> {args.peer}:{args.to} [{args.priority}] {args.title}")
    info("delivery runs on the next 'agent-bridge a2a deliver' tick "
         "(daemon-driven if bridge-handoff-daemon.sh is running).")
    return 0


# --------------------------------------------------------------------------
# a2a outbox
# --------------------------------------------------------------------------

def _format_seconds(s: int) -> str:
    """Compact text form for staleness fields. 90 -> '1m', 7200 -> '2h'."""
    if s < 0:
        s = 0
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


def cmd_outbox(args: argparse.Namespace) -> int:
    action = args.action
    conn = a2a.open_outbox()
    try:
        if action == "list":
            # Issue #1197 (beta22, codex r1 — 2026-05-25): include
            # created_ts, updated_ts, next_attempt_ts, lease_expires_ts so
            # we can compute staleness fields. No schema change — these
            # columns already exist in _OUTBOX_SCHEMA at
            # bridge_a2a_common.py:309-328.
            rows = conn.execute(
                "SELECT message_id, peer, target_agent, priority, status, "
                "attempts, next_attempt_ts, last_error, acked_remote_task_id, "
                "created_ts, updated_ts, lease_expires_ts "
                "FROM outbox ORDER BY created_ts DESC"
            ).fetchall()
            now = a2a.now_ts()
            enriched = []
            for r in rows:
                d = dict(r)
                status = d.get("status") or ""
                created_ts = int(d.get("created_ts") or 0)
                next_attempt_ts = int(d.get("next_attempt_ts") or 0)
                lease_expires_ts = int(d.get("lease_expires_ts") or 0)
                d["age_seconds"] = max(0, now - created_ts) if created_ts else 0
                d["due_for_seconds"] = None
                d["next_attempt_in_seconds"] = None
                d["lease_stale_seconds"] = None
                if status in ("pending", "retry"):
                    # next_attempt_ts==0 means "send now" (brand-new
                    # pending row). Anchor due-since to created_ts in
                    # that case so the staleness reflects "how long has
                    # this entry been waiting for ANY runner to pick
                    # it up", not "how long since next_attempt_ts=0".
                    due_anchor = next_attempt_ts if next_attempt_ts > 0 else created_ts
                    if due_anchor and due_anchor <= now:
                        d["due_for_seconds"] = max(0, now - due_anchor)
                    elif due_anchor and due_anchor > now:
                        # Future scheduled retry — surface how long until
                        # it becomes due.
                        d["next_attempt_in_seconds"] = max(0, due_anchor - now)
                if status == "sending" and lease_expires_ts and lease_expires_ts < now:
                    d["lease_stale_seconds"] = max(0, now - lease_expires_ts)
                enriched.append(d)

            if args.json:
                print(json.dumps(enriched, ensure_ascii=False, indent=2))
            else:
                if not enriched:
                    print("(outbox empty)")
                for d in enriched:
                    suffix_parts = []
                    if d["due_for_seconds"] is not None:
                        suffix_parts.append(f"due={_format_seconds(d['due_for_seconds'])}")
                    if d["next_attempt_in_seconds"] is not None:
                        suffix_parts.append(f"next={_format_seconds(d['next_attempt_in_seconds'])}")
                    if d["lease_stale_seconds"] is not None:
                        suffix_parts.append(
                            f"lease_stale={_format_seconds(d['lease_stale_seconds'])}"
                        )
                    suffix = ("  " + "  ".join(suffix_parts)) if suffix_parts else ""
                    print(f"{d['message_id']}  {d['status']:8}  "
                          f"{d['peer']}:{d['target_agent']}  "
                          f"[{d['priority']}]  attempts={d['attempts']}  "
                          f"{d['last_error'] or ''}"
                          f"{suffix}")
            return 0

        if action == "retry":
            if not args.message_id:
                return die("outbox retry needs <message_id>") or 1
            cur = conn.execute(
                "UPDATE outbox SET status='pending', next_attempt_ts=0, "
                "lease_owner=NULL, lease_expires_ts=0, updated_ts=? "
                "WHERE message_id=? AND status IN ('dead', 'retry')",
                (a2a.now_ts(), args.message_id),
            )
            conn.commit()
            if cur.rowcount == 0:
                return die(f"no dead/retry outbox entry: {args.message_id}") or 1
            print(f"requeued {args.message_id}")
            return 0

        if action == "drop":
            if not args.message_id:
                return die("outbox drop needs <message_id>") or 1
            cur = conn.execute("DELETE FROM outbox WHERE message_id=?", (args.message_id,))
            conn.commit()
            if cur.rowcount == 0:
                return die(f"no outbox entry: {args.message_id}") or 1
            print(f"dropped {args.message_id}")
            return 0

        if action == "gc":
            max_age = int(args.max_age or 86400 * 14)
            cutoff = a2a.now_ts() - max_age
            cur = conn.execute(
                "DELETE FROM outbox WHERE status IN ('acked', 'dead') "
                "AND updated_ts < ?",
                (cutoff,),
            )
            conn.commit()
            print(f"gc removed {cur.rowcount} terminal outbox rows older than {max_age}s")
            return 0
    finally:
        conn.close()
    return die(f"unknown outbox action: {action}") or 1


# --------------------------------------------------------------------------
# a2a inbox-dedupe
# --------------------------------------------------------------------------

def cmd_inbox_dedupe(args: argparse.Namespace) -> int:
    conn = a2a.open_inbox()
    try:
        if args.action == "list":
            rows = conn.execute(
                "SELECT message_id, peer, body_sha256, created_task_id, "
                "first_seen_ts, last_seen_ts, delivery_count FROM inbox_dedupe "
                "ORDER BY first_seen_ts DESC"
            ).fetchall()
            if args.json:
                print(json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2))
            else:
                if not rows:
                    print("(inbox dedupe ledger empty)")
                for r in rows:
                    print(f"{r['message_id']}  {r['peer']}  "
                          f"task={r['created_task_id'] or '-'}  "
                          f"seen={r['delivery_count']}")
            return 0
        if args.action == "gc":
            # Dedupe retention deliberately exceeds sender retry retention.
            max_age = int(args.max_age or 86400 * 60)
            cutoff = a2a.now_ts() - max_age
            cur = conn.execute(
                "DELETE FROM inbox_dedupe WHERE last_seen_ts < ?", (cutoff,)
            )
            conn.commit()
            print(f"gc removed {cur.rowcount} dedupe rows older than {max_age}s")
            return 0
    finally:
        conn.close()
    return die(f"unknown inbox-dedupe action: {args.action}") or 1


# --------------------------------------------------------------------------
# a2a peers
# --------------------------------------------------------------------------

def cmd_peers(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    if args.action == "list":
        peers = cfg.get("peers", [])
        if args.json:
            redacted = []
            for p in peers:
                rp = {k: v for k, v in p.items() if k not in ("secret", "secret_next", "secrets")}
                rp["secret_configured"] = bool(a2a.peer_secrets(p))
                redacted.append(rp)
            print(json.dumps(redacted, ensure_ascii=False, indent=2))
        else:
            if not peers:
                print("(no peers configured)")
            for p in peers:
                allow = p.get("inbound_allowlist", [])
                print(f"{p.get('id', '?'):20}  {p.get('address', '-'):20}  "
                      f"secret={'yes' if a2a.peer_secrets(p) else 'NO'}  "
                      f"inbound_allowlist={allow}")
        return 0

    if args.action == "test":
        if not args.peer:
            return die("peers test needs <peer>") or 1
        try:
            peer = a2a.find_peer(cfg, args.peer)
        except a2a.A2AError as exc:
            return die(str(exc)) or 1
        # P0: resolve the peer's CURRENT tailnet IP. If the peer carries a
        # Tailscale identity (`node_id` / `tailscale_name`) it is resolved
        # live via `tailscale status --json`; otherwise the literal
        # `address` is used (legacy back-compat). A resolve failure is a
        # hard error with an actionable message — we never probe a
        # possibly-stale stored IP behind an identity's back.
        try:
            address = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            return die(f"cannot resolve address for peer {args.peer}: {exc} "
                       f"({exc.code})") or 1
        port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
        if not address:
            return die(f"peer {args.peer} has no 'address' (and no resolvable "
                       "tailscale identity)") or 1
        info(f"probing {address}:{port} (TCP connect only — no enqueue) ...")
        try:
            with socket.create_connection((address, port), timeout=5.0):
                pass
        except OSError as exc:
            return die(f"cannot reach {address}:{port}: {exc}") or 1
        print(f"peer {args.peer} reachable at {address}:{port}")
        return 0
    return die(f"unknown peers action: {args.action}") or 1


# --------------------------------------------------------------------------
# a2a deliver — the sender delivery runner
# --------------------------------------------------------------------------

def _post_envelope(
    *,
    address: str,
    port: int,
    path: str,
    local_bridge_id: str,
    message_id: str,
    secret: str,
    envelope_bytes: bytes,
    timeout: float,
) -> tuple[int, dict[str, str], bytes]:
    """Sign and POST a single attempt. Returns (status, headers, body).

    `X-AGB-Peer` (and the peer-id field of the canonical signing string)
    carries the SENDER's own local bridge id — i.e. the authenticated
    sender identity the receiver looks up in its inbound peer table. The
    destination peer only determines routing (address/port) and which
    HMAC secret to sign with; it is NOT what goes on the wire as the peer
    identity.
    """
    timestamp = str(a2a.now_ts())
    body_hash = a2a.body_sha256(envelope_bytes)
    canonical = a2a.canonical_string(
        "POST", path, local_bridge_id, message_id, timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    url = f"http://{address}:{port}{path}"
    req = urllib.request.Request(url, data=envelope_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-AGB-Protocol", a2a.PROTOCOL_VERSION)
    req.add_header("X-AGB-Peer", local_bridge_id)
    req.add_header("X-AGB-Message-Id", message_id)
    req.add_header("X-AGB-Timestamp", timestamp)
    req.add_header("X-AGB-Body-SHA256", body_hash)
    req.add_header("X-AGB-Signature", signature)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read() or b""


def _deliver_one(conn, cfg: dict[str, Any], row, *, timeout: float) -> str:
    """Attempt one outbox row. Returns a short status word for logging."""
    message_id = row["message_id"]
    # `peer_id` here is the DESTINATION peer — it selects routing +
    # secret. The identity we sign + send is our OWN local bridge id.
    peer_id = row["peer"]
    local_bridge_id = cfg.get("bridge_id", "")
    if not local_bridge_id:
        _mark_dead(conn, message_id,
                   "config has no bridge_id (cannot identify sender)")
        return "dead(no-bridge-id)"
    try:
        peer = a2a.find_peer(cfg, peer_id)
    except a2a.A2AError as exc:
        _mark_dead(conn, message_id, f"peer config missing: {exc}")
        return "dead(config)"

    # P0: resolve the peer's CURRENT tailnet IP. A peer carrying a Tailscale
    # identity (`node_id` / `tailscale_name`) is resolved live via
    # `tailscale status --json`; otherwise the literal `address` is used
    # (legacy back-compat). A resolve failure (Tailscale temporarily
    # unavailable, or the peer/identity not yet visible in the tailnet) is
    # treated as TRANSIENT and scheduled for retry — NOT dead-lettered —
    # because nothing stores a resolved IP, so the next tick self-heals once
    # Tailscale / the peer is reachable again. This is the inherent self-heal
    # of identity-keyed config (today's stale-IP incident cannot recur). The
    # max-attempts ceiling still eventually dead-letters a permanently-bad
    # identity, so an unresolvable peer does not wedge the outbox forever.
    attempts = int(row["attempts"]) + 1
    try:
        address = a2a.resolve_peer_address(peer)
    except a2a.A2AError as exc:
        return _schedule_retry(
            conn, message_id, attempts, cfg,
            f"address resolve failed: {exc} ({exc.code})",
        )
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    path = peer.get("enqueue_path", "/enqueue")
    if not address:
        # No identity AND no literal address — a permanent misconfiguration.
        _mark_dead(conn, message_id, "peer has no address (and no resolvable "
                                     "tailscale identity)")
        return "dead(noaddr)"

    body_path = Path(row["body_path"])
    if not body_path.is_file():
        _mark_dead(conn, message_id, f"staged body missing: {body_path}")
        return "dead(nobody)"
    envelope_bytes = body_path.read_bytes()

    try:
        secret = a2a.peer_send_secret(peer)
    except a2a.A2AError as exc:
        _mark_dead(conn, message_id, str(exc))
        return "dead(nosecret)"

    try:
        status, headers, resp_body = _post_envelope(
            address=address, port=port, path=path,
            local_bridge_id=local_bridge_id,
            message_id=message_id, secret=secret,
            envelope_bytes=envelope_bytes, timeout=timeout,
        )
    except (urllib.error.URLError, socket.timeout, OSError) as exc:
        # Connection-level failure → retryable.
        return _schedule_retry(conn, message_id, attempts, cfg, f"transport: {exc}")

    if 200 <= status < 300:
        remote_task = ""
        try:
            parsed = json.loads(resp_body.decode("utf-8")) if resp_body else {}
            remote_task = str(parsed.get("task_id", ""))
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        conn.execute(
            "UPDATE outbox SET status='acked', attempts=?, "
            "acked_remote_task_id=?, last_error=NULL, updated_ts=? "
            "WHERE message_id=?",
            (attempts, remote_task, a2a.now_ts(), message_id),
        )
        conn.commit()
        return f"acked(task={remote_task or '?'})"

    detail = ""
    try:
        detail = resp_body.decode("utf-8", "replace")[:200]
    except Exception:  # noqa: BLE001 - defensive only
        detail = ""

    if status in a2a.PERMANENT_FAIL_STATUSES:
        _mark_dead(conn, message_id, f"HTTP {status}: {detail}")
        return f"dead(http{status})"

    # 429 / 5xx / anything else → retry, honoring Retry-After.
    retry_after = headers.get("Retry-After")
    return _schedule_retry(conn, message_id, attempts, cfg,
                           f"HTTP {status}: {detail}", retry_after=retry_after)


def _schedule_retry(conn, message_id: str, attempts: int, cfg: dict[str, Any],
                    last_error: str, retry_after: Optional[str] = None) -> str:
    max_attempts = int(cfg.get("delivery_max_attempts", 12))
    if attempts >= max_attempts:
        conn.execute(
            "UPDATE outbox SET status='dead', attempts=?, last_error=?, updated_ts=? "
            "WHERE message_id=?",
            (attempts, f"max attempts ({max_attempts}): {last_error}",
             a2a.now_ts(), message_id),
        )
        conn.commit()
        return "dead(maxattempts)"

    delay = a2a.backoff_seconds(attempts)
    if retry_after:
        try:
            delay = max(delay, int(float(retry_after)))
        except (TypeError, ValueError):
            pass
    # Full jitter.
    delay = int(delay * (0.5 + random.random() * 0.5))
    next_ts = a2a.now_ts() + max(1, delay)
    conn.execute(
        "UPDATE outbox SET status='retry', attempts=?, next_attempt_ts=?, "
        "last_error=?, lease_owner=NULL, lease_expires_ts=0, updated_ts=? "
        "WHERE message_id=?",
        (attempts, next_ts, last_error[:500], a2a.now_ts(), message_id),
    )
    conn.commit()
    return f"retry(in={next_ts - a2a.now_ts()}s)"


def _mark_dead(conn, message_id: str, reason: str) -> None:
    conn.execute(
        "UPDATE outbox SET status='dead', last_error=?, "
        "lease_owner=NULL, lease_expires_ts=0, updated_ts=? WHERE message_id=?",
        (reason[:500], a2a.now_ts(), message_id),
    )
    conn.commit()


def cmd_deliver(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config()
        # #1331: refuse to drain the outbox if any peer is unprovisioned
        # (paired test-bypass env vars still respected). Without this,
        # rows targeted at the unprovisioned peer would dead-letter on
        # the first attempt with no operator-visible warning until they
        # ran `agb a2a outbox list`.
        a2a.validate_config_peer_secrets(cfg, side="sender")
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    runner_id = f"{socket.gethostname()}:{os.getpid()}:{uuid.uuid4().hex[:8]}"
    lease_seconds = int(args.lease or 120)
    timeout = float(args.timeout or 20.0)
    batch = int(args.batch or 25)

    conn = a2a.open_outbox()
    delivered = 0
    try:
        now = a2a.now_ts()

        # Reclaim crashed-runner rows: a row stuck in status='sending'
        # with an expired lease means the runner that claimed it died
        # mid-attempt. Demote it back to 'retry' (and clear the lease) so
        # the candidate scan below picks it up again — otherwise it would
        # sit wedged forever, since the scan only selects pending/retry.
        reclaimed = conn.execute(
            "UPDATE outbox SET status='retry', lease_owner=NULL, "
            "lease_expires_ts=0, next_attempt_ts=?, updated_ts=?, "
            "last_error='reclaimed: prior runner lease expired' "
            "WHERE status='sending' AND lease_expires_ts < ?",
            (now, now, now),
        )
        conn.commit()
        if reclaimed.rowcount:
            info(f"reclaimed {reclaimed.rowcount} stale 'sending' "
                 f"entr{'y' if reclaimed.rowcount == 1 else 'ies'} "
                 "(expired lease)")

        # Per-entry lease: claim due rows so two runners cannot double-send.
        candidates = conn.execute(
            "SELECT message_id FROM outbox WHERE status IN ('pending', 'retry') "
            "AND next_attempt_ts <= ? AND (lease_owner IS NULL OR lease_expires_ts < ?) "
            "ORDER BY next_attempt_ts ASC LIMIT ?",
            (now, now, batch),
        ).fetchall()
        for cand in candidates:
            mid = cand["message_id"]
            claim = conn.execute(
                "UPDATE outbox SET status='sending', lease_owner=?, "
                "lease_expires_ts=?, updated_ts=? WHERE message_id=? "
                "AND status IN ('pending', 'retry') "
                "AND (lease_owner IS NULL OR lease_expires_ts < ?)",
                (runner_id, now + lease_seconds, now, mid, now),
            )
            conn.commit()
            if claim.rowcount == 0:
                continue  # lost the race to another runner
            row = conn.execute("SELECT * FROM outbox WHERE message_id=?", (mid,)).fetchone()
            if row is None:
                continue
            result = _deliver_one(conn, cfg, row, timeout=timeout)
            delivered += 1
            info(f"{mid} -> {result}")
    finally:
        conn.close()

    if delivered == 0:
        info("no due outbox entries")
    else:
        info(f"processed {delivered} outbox entr{'y' if delivered == 1 else 'ies'}")
    return 0


# --------------------------------------------------------------------------
# a2a reconcile (self-heal trigger + preview, P-self-heal-1, #1403)
# --------------------------------------------------------------------------

def cmd_reconcile(args: argparse.Namespace) -> int:
    """Trigger + preview one receiver self-heal reconcile (P-self-heal-1, #1403).

    Two parts:
      1. PREVIEW (always): validate the config, then run the SAME fail-closed
         bind proof the receiver daemon performs at bind time by delegating to
         `bridge-handoffd.py reconcile` (config load + `resolve_bind()`:
         candidate ∈ `tailscale ip` set; refuse wildcard/loopback; refuse if
         Tailscale unavailable). The preview therefore RE-PROVES the listen
         candidate rather than merely resolving it — an out-of-tailnet-set
         `listen.address` prints a `bind_not_tailnet` failure and exits
         nonzero, exactly matching the daemon (codex r1 BLOCKING 2).
      2. TRIGGER (if a daemon is running): send SIGHUP to the receiver pid so
         the LIVE daemon runs an immediate reconcile (auto-rebind on local-IP
         drift + config hot-reload) with no `bridge-handoff-daemon.sh restart`.

    The preview never weakens the proof — it shares the daemon's proof code as
    its single source, so the CLI can never drift looser. The running daemon
    keeps serving on its current proven bind + last-good config on any
    reconcile failure (see bridge-handoffd.py).
    """
    try:
        cfg = a2a.load_config()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    rc = 0
    # --- preview: config validity (fail-closed report) ---
    try:
        a2a.validate_config_peer_secrets(cfg, side="receiver")
        info(f"config OK: {len(cfg.get('peers', []))} peer(s) configured")
    except a2a.A2AError as exc:
        err(f"config invalid: {exc} ({exc.code}) — a running daemon would keep "
            "its last-good config (fail-closed)")
        rc = 1

    # --- preview: bind proof (DELEGATE to the receiver's real proof) ---
    # codex r1 BLOCKING 2: this preview must run the SAME fail-closed bind
    # proof the daemon performs at bind time — NOT a bare
    # `resolve_peer_address`, which resolves the listen identity but never
    # RE-PROVES the candidate is in this node's `tailscale ip` set. A bare
    # resolve would print "listen resolves to <addr>" and exit 0 even for an
    # address NOT in the tailnet set, contradicting the daemon's
    # `bind_not_tailnet` refusal and weakening the "performs/prints one safe
    # pass" claim. We delegate to `bridge-handoffd.py reconcile`, which loads
    # the same config + runs the UNCHANGED `resolve_bind()` proof (candidate ∈
    # `tailscale ip`; refuse wildcard/loopback; refuse if Tailscale
    # unavailable) and exits nonzero with the structured failure. Single source
    # of the proof — the CLI can never drift looser than the daemon.
    handoffd = Path(__file__).resolve().parent / "bridge-handoffd.py"
    if not handoffd.is_file():
        err(f"cannot locate receiver bind-proof helper at {handoffd}; "
            "skipping bind preview (a running daemon still RE-PROVES at "
            "bind time)")
        rc = 1
    else:
        import subprocess  # noqa: PLC0415 (only this path needs it)
        cmd = [sys.executable, str(handoffd), "reconcile"]
        # Thread an explicit --config through ONLY when the caller pinned one
        # via BRIDGE_A2A_CONFIG, so the child resolves the identical config
        # the parent's a2a.load_config() did. Otherwise let the child run its
        # own default resolution (same code path).
        cfg_override = os.environ.get("BRIDGE_A2A_CONFIG")
        if cfg_override:
            cmd += ["--config", cfg_override]
        try:
            proof = subprocess.run(  # noqa: PLW1510 (rc handled below)
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            err(f"could not run receiver bind proof ({handoffd.name}): {exc}")
            rc = 1
        else:
            # Surface the receiver's own proof output verbatim (it carries the
            # `bind proven: ...` line or the `bind FAIL: ... (bind_not_tailnet)`
            # refusal). Route its stdout through info and stderr through err so
            # the failure stays on the error stream + nonzero propagates.
            for line in (proof.stdout or "").splitlines():
                if line.strip():
                    info(line)
            for line in (proof.stderr or "").splitlines():
                if line.strip():
                    err(line)
            if proof.returncode != 0:
                # The daemon refuses to bind (e.g. bind_not_tailnet); the CLI
                # preview must mirror that fail-closed verdict, not exit 0.
                rc = 1

    # --- trigger: SIGHUP the running receiver, if any ---
    pid_file = a2a.handoff_dir() / "handoffd.pid"
    pid: Optional[int] = None
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            pid = None
    if pid is not None:
        try:
            os.kill(pid, signal.SIGHUP)
            info(f"sent SIGHUP to running receiver (pid {pid}) — immediate "
                 "reconcile (auto-rebind on local-IP drift + config "
                 "hot-reload); no restart needed")
        except ProcessLookupError:
            info("no running receiver (stale pidfile) — start it with "
                 "`agent-bridge handoff start`; it self-heals on its own timer")
        except OSError as exc:
            err(f"could not signal receiver pid {pid}: {exc}")
    else:
        info("no running receiver pidfile — start it with "
             "`agent-bridge handoff start`; the daemon self-heals on its timer")
    return rc


# --------------------------------------------------------------------------
# migrate-identity (P-self-heal-2): rewrite raw-IP entries to Tailscale identity
# --------------------------------------------------------------------------
#
# A peer (or listen) entry that carries only a raw `address` (today's configs)
# still goes STALE when the underlying node's Tailscale IP changes — only an
# identity-keyed entry (node_id / tailscale_name) self-heals via the P0 runtime
# resolver. This command performs the one-shot raw -> identity migration:
# reverse-resolve each raw `address` to its Tailscale node (via a single
# `tailscale status --json`) and, when EXACTLY one node owns that IP, record the
# node's StableID (`node_id`) + name (`tailscale_name`) on the entry. The raw
# `address` is KEPT as a fallback by default (resolver precedence is node_id >
# tailscale_name > address). Dry-run is the default; --apply writes atomically.
#
# Fail-closed + conservative (NEVER guess):
#   - tailscale status unavailable  -> exit nonzero, write nothing.
#   - IP matches 0 nodes (stale)    -> leave untouched, warn.
#   - IP matches >1 nodes (ambig)   -> leave untouched, warn.
#   - already identity-keyed        -> no-op (idempotent).
#   - secret/secret_next/inbound_allowlist/caps/port/bridge_id NEVER touched.


def warn(msg: str) -> None:
    print(f"[a2a][warn] {msg}", file=sys.stderr)


def _migrate_entry(
    entry: dict[str, Any], status: dict[str, Any], label: str,
    *, drop_address: bool,
) -> "Optional[dict[str, Any]]":
    """Plan an identity migration for a single peer/listen entry.

    Returns a change record (for reporting) when the entry would be migrated,
    or None when it is left untouched (already-keyed / no raw address / zero or
    ambiguous match). MUTATES `entry` in place with the new identity fields when
    a change is planned — callers run this on a working copy and only persist on
    --apply. Only `node_id` / `tailscale_name` (and, with --drop-address, the
    `address`) are ever modified; every other key is left byte-identical.
    """
    if not isinstance(entry, dict):
        return None
    has_node_id = isinstance(entry.get("node_id"), str) and entry["node_id"].strip()
    has_ts_name = isinstance(entry.get("tailscale_name"), str) and entry["tailscale_name"].strip()
    if has_node_id or has_ts_name:
        # Already identity-keyed -> idempotent no-op (regardless of address).
        return None
    address = entry.get("address")
    if not isinstance(address, str) or not address.strip():
        # Nothing to reverse-resolve.
        return None
    raw = address.strip()

    resolved = a2a.reverse_resolve_ip(status, raw)
    if resolved is None:
        n = len(a2a.nodes_owning_ip(status, raw))
        if n == 0:
            warn(
                f"{label}: address {raw} matches NO Tailscale node in "
                "'tailscale status --json' (stale/offline?) — left untouched, "
                "not guessing."
            )
        else:
            warn(
                f"{label}: address {raw} matches {n} Tailscale nodes "
                "(ambiguous) — left untouched, not guessing."
            )
        return None

    node_id, ts_name = resolved
    if not node_id and not ts_name:
        warn(
            f"{label}: address {raw} resolved to a node with neither a "
            "StableID nor a name — left untouched, not guessing."
        )
        return None

    before = {
        "node_id": entry.get("node_id", ""),
        "tailscale_name": entry.get("tailscale_name", ""),
        "address": entry.get("address", ""),
    }
    if node_id:
        entry["node_id"] = node_id
    if ts_name:
        entry["tailscale_name"] = ts_name
    if drop_address:
        entry.pop("address", None)
    after = {
        "node_id": entry.get("node_id", ""),
        "tailscale_name": entry.get("tailscale_name", ""),
        "address": entry.get("address", "<dropped>" if drop_address else ""),
    }
    return {"entry": label, "before": before, "after": after}


def _write_config_atomic(path: Path, cfg: dict[str, Any], mode: int) -> None:
    """Write `cfg` as pretty JSON to `path` atomically, preserving `mode`."""
    tmp = path.with_name(path.name + ".tmp")
    text = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    # Create the temp at 0o600 from the start so the HMAC-secret-bearing JSON
    # is never world/group-readable during the write+fsync window. os.open
    # honors 0o600 minus umask, so the worst case is tighter, never wider.
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)


def cmd_migrate_identity(args: argparse.Namespace) -> int:
    """Rewrite raw-`address` peers/listen to Tailscale identity keying.

    Dry-run by default (prints the before->after plan, writes nothing).
    Pass --apply to write the migrated config atomically (mode preserved).
    """
    cfg_path = a2a.config_path()
    try:
        cfg = a2a.load_config()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1
    # Capture the original file mode so --apply preserves it (default 0600).
    try:
        orig_mode = cfg_path.stat().st_mode & 0o777
    except OSError:
        orig_mode = 0o600

    # Single tailscale status parse, shared across every entry. Fail closed:
    # if the tailnet cannot be queried we exit nonzero and change NOTHING.
    try:
        status = a2a.tailscale_status_json()
    except a2a.TailscaleUnavailable as exc:
        return die(
            f"cannot query 'tailscale status --json' ({exc}) — refusing to "
            "migrate without a live tailnet view. Nothing was changed.",
            code=3,
        ) or 3

    changes: list[dict[str, Any]] = []

    listen = cfg.get("listen")
    if isinstance(listen, dict):
        rec = _migrate_entry(
            listen, status, "listen", drop_address=args.drop_address,
        )
        if rec is not None:
            changes.append(rec)

    peers = cfg.get("peers", [])
    if isinstance(peers, list):
        for peer in peers:
            if not isinstance(peer, dict):
                continue
            label = f"peer {peer.get('id') or '(no id)'}"
            rec = _migrate_entry(
                peer, status, label, drop_address=args.drop_address,
            )
            if rec is not None:
                changes.append(rec)

    if not changes:
        info("no raw-address entries to migrate — config already identity-keyed "
             "(or no resolvable matches).")
        return 0

    # Report the plan (before -> after) for every changed entry.
    for rec in changes:
        info(f"{rec['entry']}:")
        for field in ("node_id", "tailscale_name", "address"):
            b = rec["before"].get(field, "")
            a = rec["after"].get(field, "")
            if b != a:
                print(f"    {field}: {b!r} -> {a!r}")

    if not args.apply:
        info(
            f"DRY-RUN: {len(changes)} entry(ies) would be migrated. "
            "Re-run with --apply to write. (address kept as fallback unless "
            "--drop-address.)"
        )
        return 0

    _write_config_atomic(cfg_path, cfg, orig_mode)
    info(f"APPLIED: migrated {len(changes)} entry(ies); wrote {cfg_path} "
         f"(mode {orig_mode:04o} preserved).")
    return 0


# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent-bridge a2a",
        description="Cross-bridge task handoff (A2A) — Tailscale direct-mesh.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_send = sub.add_parser("send", help="stage an outbound cross-bridge handoff")
    p_send.add_argument("--peer", required=True, help="configured peer bridge id")
    p_send.add_argument("--to", required=True, help="target agent on the peer bridge")
    p_send.add_argument("--from", dest="from_agent", default=None, help="sending agent id")
    p_send.add_argument("--title", required=True)
    p_send.add_argument("--body", default=None)
    p_send.add_argument("--body-file", default=None)
    p_send.add_argument("--priority", default="normal")
    p_send.add_argument("--allow-empty-body", action="store_true")
    p_send.add_argument("--dry-run", action="store_true",
                        help="resolve + validate but do not write the outbox")
    p_send.set_defaults(func=cmd_send)

    p_outbox = sub.add_parser("outbox", help="manage the sender outbox")
    p_outbox.add_argument("action", choices=["list", "retry", "drop", "gc"])
    p_outbox.add_argument("message_id", nargs="?", default=None)
    p_outbox.add_argument("--json", action="store_true")
    p_outbox.add_argument("--max-age", type=int, default=None,
                          help="gc: terminal-row age cutoff in seconds")
    p_outbox.set_defaults(func=cmd_outbox)

    p_dedupe = sub.add_parser("inbox-dedupe", help="inspect/prune the receiver dedupe ledger")
    p_dedupe.add_argument("action", choices=["list", "gc"])
    p_dedupe.add_argument("--json", action="store_true")
    p_dedupe.add_argument("--max-age", type=int, default=None)
    p_dedupe.set_defaults(func=cmd_inbox_dedupe)

    p_peers = sub.add_parser("peers", help="inspect configured peers")
    p_peers.add_argument("action", choices=["list", "test"])
    p_peers.add_argument("peer", nargs="?", default=None)
    p_peers.add_argument("--json", action="store_true")
    p_peers.set_defaults(func=cmd_peers)

    p_deliver = sub.add_parser("deliver", help="drain the outbox (delivery runner)")
    p_deliver.add_argument("--batch", type=int, default=None)
    p_deliver.add_argument("--lease", type=int, default=None)
    p_deliver.add_argument("--timeout", type=float, default=None)
    p_deliver.set_defaults(func=cmd_deliver)

    p_reconcile = sub.add_parser(
        "reconcile",
        help="trigger + preview one receiver self-heal reconcile "
             "(re-resolve+prove bind, config hot-reload via SIGHUP)")
    p_reconcile.set_defaults(func=cmd_reconcile)

    p_migrate = sub.add_parser(
        "migrate-identity",
        help="rewrite raw-IP peers/listen to Tailscale identity keying",
        description=(
            "Reverse-resolve each raw `address` in handoff.local.json to its "
            "Tailscale node and record the node's StableID (node_id) + name "
            "(tailscale_name) so the entry self-heals on IP change. Dry-run by "
            "default; pass --apply to write. The raw `address` is kept as a "
            "fallback unless --drop-address. Fail-closed: needs a live "
            "`tailscale status --json`; zero/ambiguous IP matches are left "
            "untouched; secret/allowlist/caps are never modified."
        ),
    )
    p_migrate.add_argument(
        "--apply", action="store_true",
        help="write the migrated config (default: dry-run, no write)",
    )
    p_migrate.add_argument(
        "--drop-address", action="store_true",
        help="remove the raw `address` after keying on identity "
             "(default: keep it as a fallback)",
    )
    p_migrate.set_defaults(func=cmd_migrate_identity)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return args.func(args)
    except a2a.A2AError as exc:
        return die(f"{exc} ({exc.code})") or 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
