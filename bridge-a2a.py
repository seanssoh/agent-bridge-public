#!/usr/bin/env python3
"""bridge-a2a.py — Agent Bridge cross-bridge task handoff (A2A) CLI + runner.

Subcommands (surfaced through `agent-bridge a2a ...`):

  send          Stage an outbound handoff into the durable outbox.
  outbox        list | retry | drop | gc — manage the sender outbox.
  inbox-dedupe  list | gc — inspect/prune the receiver dedupe ledger.
  peers         list | test <peer> — inspect configured peers.
  deliver       Drain the outbox: sign + POST each pending entry over the
                tailnet, with retry/backoff/jitter and dead-lettering.

The receiver daemon lives in a separate file (`bridge-handoffd.py`).
"""

from __future__ import annotations

import argparse
import json
import os
import random
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


# --------------------------------------------------------------------------
# a2a send — stage an outbound entry into the durable outbox
# --------------------------------------------------------------------------

def cmd_send(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config()
        peer = a2a.find_peer(cfg, args.peer)
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
        body_text = body_src.read_text(encoding="utf-8")
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
        address = peer.get("address", "")
        port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
        if not address:
            return die(f"peer {args.peer} has no 'address'") or 1
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

    address = peer.get("address", "")
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    path = peer.get("enqueue_path", "/enqueue")
    if not address:
        _mark_dead(conn, message_id, "peer has no address")
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

    attempts = int(row["attempts"]) + 1
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
