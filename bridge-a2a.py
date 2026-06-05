#!/usr/bin/env python3
"""bridge-a2a.py — Agent Bridge cross-bridge task handoff (A2A) CLI + runner.

Subcommands (surfaced through `agent-bridge a2a ...`):

  send          Stage an outbound handoff into the durable outbox.
  outbox        list | retry | drop | gc — manage the sender outbox.
  inbox-dedupe  list | gc — inspect/prune the receiver dedupe ledger.
  peers         list | test <peer> — inspect configured peers.
  deliver       Drain the outbox: sign + POST each pending entry over the
                tailnet, with retry/backoff/jitter and dead-lettering.
  diagnose-stuck  Classify backoff-waiting retry rows by failing leg
                (peer_receiver_unreachable / *_tailnet_degraded / unknown) and
                reset backoff for peers whose TCP probe recovered (#1563 PR-8).
  reconcile     Trigger + preview one receiver self-heal reconcile.
  migrate-identity  Rewrite raw-IP peers/listen to Tailscale identity keying
                so today's raw-`address` configs self-heal (dry-run default).
  setup         Agent-driven A2A setup wizard (S0/S1/S2/S5/S6, manual secret,
                idempotent/resumable). `--show-state [--json]` reports the
                derived state; the secret comes from `--peer-secret-env`.

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
        st = path.stat()  # noqa: raw-pathlib-controller-only
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
            os.chmod(body_path, 0o600)  # noqa: raw-pathlib-controller-only
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
        # #1563 PR-8 item #5: a non-fatal WARN for any peer keyed on a raw
        # `address` with no Tailscale identity. A raw IP is vulnerable to
        # peer-IP staleness (the peer's IP drifts after a re-login); an
        # identity-keyed peer (`node_id` / `tailscale_name`) re-resolves to the
        # current IP at use-time. WARN-only — no behavior change for existing
        # raw-IP peers — and on stderr so it never pollutes `--json` stdout.
        for p in peers:
            if not isinstance(p, dict):
                continue
            has_identity = bool(
                (isinstance(p.get("node_id"), str) and p["node_id"].strip())
                or (isinstance(p.get("tailscale_name"), str) and p["tailscale_name"].strip())
            )
            if not has_identity and str(p.get("address") or "").strip():
                info(
                    f"WARN peer {p.get('id', '?')!r} is keyed on a raw IP "
                    f"({p.get('address')}) with no node_id/tailscale_name — "
                    "vulnerable to peer-IP staleness. Run "
                    "`agb a2a migrate-identity --apply` to identity-key it "
                    "(see docs/a2a-cross-bridge.md)."
                )
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
        # #1563 PR-8 item #4 (history preservation): do NOT NULL `last_error`
        # on ack. The prior code wiped it, so a row that succeeded only after
        # a long retry storm landed in the outbox as `status='acked'` with no
        # trace of the transient failures — post-mortems then had to rely on
        # the (cooldown-throttled, eventually-pruned) stuck-alert bodies.
        # Keeping the last transient error preserves the attempt trail
        # (visible in `agb a2a outbox list`); `status='acked'` is the
        # authoritative success signal, and the stuck-scan only ever inspects
        # pending/retry rows, so a non-NULL last_error on an acked row never
        # re-triggers an alert. Ack success semantics are unchanged.
        conn.execute(
            "UPDATE outbox SET status='acked', attempts=?, "
            "acked_remote_task_id=?, updated_ts=? "
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
# a2a diagnose-stuck (#1563 PR-8): directional diagnosis + backoff recovery
# --------------------------------------------------------------------------
#
# After the 2026-06-06 tailnet outage (#1563 A2A subtrack) two recovery
# defects prolonged the incident, even though the death itself was
# environmental (a one-way tailnet dead path needing a re-handshake — NOT a
# bridge receiver/protocol bug):
#
#   1. DIAGNOSIS — a bare "transport: timed out" last_error told neither side
#      which leg failed, so each agent blamed the OTHER's receiver. This
#      classifies the failing leg from the three EXISTING non-mutating probes:
#      local receiver healthz (TCP GET /healthz), peer TCP `address:port`
#      connect (the `peers test` mechanic), and `tailscale status` node
#      online + tx/rx asymmetry.
#
#   2. RECOVERY — `backoff_seconds(base=15, ceiling=3600)` + jitter means an
#      attempt-8..10 retry row waits 16-60 min. The deliver tick only selects
#      `next_attempt_ts <= now` rows, so after the peer RECOVERED the high-
#      attempt rows stayed dormant for tens of minutes (the incident needed a
#      manual `agb a2a outbox retry`). Here, when a retry row's peer TCP probe
#      SUCCEEDS, we reset that peer's retry rows to `next_attempt_ts=0` so the
#      next deliver tick sends immediately (bounded by `deliver --batch`).
#
# HEALTH ORACLE: TCP `peer:port` — never `tailscale ping` (a disco-protocol
# artifact that times out on a healthy A2A path; see the #10114 root-cause
# writeup). We do NOT mutate tailscale state (no `tailscale up/down`); the
# only self-recovery is the backoff reset on a TCP-probe SUCCESS transition.
# This is sender-side diagnosis + outbox recovery ONLY — the fail-closed
# receiver bind proof / HMAC / remote_addr / allowlist / dedupe are untouched.

# Directional classification codes (surfaced in the report + stuck-alert).
A2A_DIAG_PEER_RECEIVER_UNREACHABLE = "peer_receiver_unreachable"
A2A_DIAG_LOCAL_TAILNET_DEGRADED = "local_tailnet_degraded"
A2A_DIAG_PEER_TAILNET_DEGRADED = "peer_tailnet_degraded"
A2A_DIAG_TRANSPORT_DEAD_PATH_UNKNOWN = "transport_dead_path_unknown"
# Probe SUCCEEDED — the path is healthy; the row is only backoff-waiting.
A2A_DIAG_TCP_HEALTHY_BACKOFF_WAITING = "tcp_healthy_backoff_waiting"


def _a2a_tcp_probe(address: str, port: int, timeout: float) -> tuple[bool, str]:
    """TCP-connect probe to ``address:port`` — the A2A reachability ORACLE.

    Mirrors the `peers test` / setup-S6 mechanic (socket.create_connection,
    no enqueue, no auth). Returns (ok, detail). NEVER uses `tailscale ping`.
    """
    if not address:
        return False, "no resolvable address"
    try:
        with socket.create_connection((address, port), timeout=timeout):
            pass
    except OSError as exc:
        return False, str(exc)
    return True, "ok"


def _a2a_local_healthz(cfg: dict[str, Any], timeout: float) -> tuple[Optional[bool], str]:
    """Best-effort probe of THIS node's receiver via `bridge-handoffd.py healthz`.

    Returns (healthy, detail): healthy is True/False, or None when the probe
    could not run conclusively (no receiver configured / helper missing /
    tailscale unavailable). Non-fatal — a None here just means the local leg
    is indeterminate, and the classifier degrades to *_unknown rather than
    asserting a local fault.
    """
    repo_root = os.path.dirname(os.path.abspath(__file__))
    handoffd = os.path.join(repo_root, "bridge-handoffd.py")
    if not os.path.isfile(handoffd):
        return None, "healthz helper missing"
    config_override = os.environ.get("BRIDGE_A2A_CONFIG")
    argv = [sys.executable, handoffd, "healthz", "--timeout", str(int(max(1, timeout)))]
    if config_override:
        argv += ["--config", config_override]
    try:
        out = _run_subprocess(argv, timeout=max(2.0, timeout + 2.0))
    except (OSError, ValueError) as exc:
        return None, f"healthz probe failed to run: {exc}"
    text = (out.stdout or "").strip().splitlines()
    last = text[-1].strip() if text else ""
    if out.returncode == 0 and last == "healthy":
        return True, "healthy"
    # Non-zero rc OR a non-"healthy" terminal line → unhealthy/indeterminate.
    # The healthz command prints a machine token (healthz_timeout /
    # healthz_status:<code> / healthz_badbody / bind-unresolved) we relay.
    if not last:
        return None, "healthz indeterminate (no output)"
    return False, last


def _a2a_tailnet_asymmetry(address: str) -> dict[str, Any]:
    """Non-mutating `tailscale status` read for the directional classifier.

    Returns a dict with best-effort flags (all optional — the classifier
    tolerates a fully-empty dict when tailscale is unavailable):
      self_tx, self_rx        — Self node TxBytes/RxBytes (outbound/inbound)
      peer_online             — True/False/None: does a node own `address`
                                and is it Online?
    Never raises — tailscale being unavailable is an expected, benign state
    on hosts without a tailnet (the classifier falls back to *_unknown).
    """
    out: dict[str, Any] = {
        "self_tx": None, "self_rx": None, "peer_online": None,
    }
    try:
        status = a2a.tailscale_status_json()
    except Exception:  # noqa: BLE001 - tailscale-unavailable is benign here
        return out
    self_node = status.get("Self")
    if isinstance(self_node, dict):
        try:
            out["self_tx"] = int(self_node.get("TxBytes") or 0)
            out["self_rx"] = int(self_node.get("RxBytes") or 0)
        except (TypeError, ValueError):
            pass
    if address:
        try:
            owners = a2a.nodes_owning_ip(status, address)
        except Exception:  # noqa: BLE001
            owners = []
        if owners:
            node = owners[0]
            out["peer_online"] = bool(node.get("Online"))
    return out


def _a2a_classify_leg(
    *,
    probe_ok: bool,
    local_healthz: Optional[bool],
    tailnet: dict[str, Any],
) -> str:
    """Classify the failing A2A leg from the three EXISTING probes (#1).

    Priority of evidence:
      - probe_ok           → path is healthy; the row is only backoff-waiting.
      - peer TCP FAIL + local healthz OK + peer not tailnet-online
                           → peer_tailnet_degraded (peer's tailnet/node down).
      - peer TCP FAIL + local healthz OK + peer tailnet-online
                           → peer_receiver_unreachable (node up, port closed).
      - peer TCP FAIL + local healthz UNHEALTHY
                           → local_tailnet_degraded (our own serve/path issue).
      - local Self shows tx==0 while rx>0 (outbound dead path)
                           → local_tailnet_degraded.
      - otherwise          → transport_dead_path_unknown.
    """
    if probe_ok:
        return A2A_DIAG_TCP_HEALTHY_BACKOFF_WAITING

    self_tx = tailnet.get("self_tx")
    self_rx = tailnet.get("self_rx")
    # Outbound-dead asymmetry: we have received bytes but sent none — our own
    # outbound tailnet path is the suspect leg.
    if isinstance(self_tx, int) and isinstance(self_rx, int) and self_tx == 0 and self_rx > 0:
        return A2A_DIAG_LOCAL_TAILNET_DEGRADED

    if local_healthz is False:
        # Our own receiver is unhealthy → most likely a local serve/tailnet
        # problem, not the peer's. (We still couldn't reach the peer, but the
        # local fault is the actionable one.)
        return A2A_DIAG_LOCAL_TAILNET_DEGRADED

    if local_healthz is True:
        peer_online = tailnet.get("peer_online")
        if peer_online is False:
            return A2A_DIAG_PEER_TAILNET_DEGRADED
        if peer_online is True:
            return A2A_DIAG_PEER_RECEIVER_UNREACHABLE
        # Peer online status indeterminate, but our local leg is healthy and
        # the peer TCP port is closed → most likely the peer's receiver.
        return A2A_DIAG_PEER_RECEIVER_UNREACHABLE

    # local healthz indeterminate AND peer TCP fail → cannot attribute a leg.
    return A2A_DIAG_TRANSPORT_DEAD_PATH_UNKNOWN


def _run_subprocess(argv: list[str], *, timeout: float):
    """Thin subprocess.run wrapper kept local so the import stays lazy."""
    import subprocess
    return subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout, check=False,
    )


def _a2a_load_diag_ledger(path: str) -> dict[str, str]:
    """Per-peer last-probe-result ledger (peer -> 'ok' | 'fail').

    Used to GATE the backoff reset on a fail→ok TRANSITION so we never reset
    the same peer's rows every tick (which would thrash an unreachable peer if
    the gate were ever weakened). Missing/corrupt ledger → empty (first scan).
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items()}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return {}


def _a2a_save_diag_ledger(path: str, ledger: dict[str, str]) -> None:
    """Atomic rewrite of the per-peer probe-result ledger (best-effort)."""
    try:
        import tempfile
        ledger_dir = os.path.dirname(path) or "."
        os.makedirs(ledger_dir, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=ledger_dir,
            prefix=".a2a-diag.", suffix=".tmp", delete=False,
        ) as tmp:
            json.dump(ledger, tmp, ensure_ascii=False)
            tmp_path = tmp.name
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except OSError:
        pass


def cmd_diagnose_stuck(args: argparse.Namespace) -> int:
    """Directional A2A diagnosis + probe-gated backoff recovery (#1563 PR-8).

    Scans the outbox for `status='retry'` rows whose `next_attempt_ts > now`
    (backoff-waiting). For each such PEER it runs the non-mutating probe set,
    classifies the failing leg, and — on a TCP-probe SUCCESS transition — resets
    that peer's retry rows to `next_attempt_ts=0` so the next deliver tick sends
    immediately. Emits a JSON report (one entry per affected peer) the daemon
    stuck-scan enriches its alert body with.

    Flags:
      --json          emit the machine report to stdout (default human lines).
      --dry-run       classify + report but do NOT reset any backoff (teeth
                      harness uses this to observe the decision without the SQL
                      side-effect).
      --probe-timeout TCP-connect / healthz timeout seconds (default 5).
      --ledger PATH   per-peer probe-result ledger for transition-gating
                      (default under the outbox dir).

    NEVER touches `sending`/leased rows. NEVER mutates tailscale state.
    """
    probe_timeout = float(args.probe_timeout or 5.0)
    apply_reset = not bool(getattr(args, "dry_run", False))

    try:
        cfg = a2a.load_config()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    ledger_path = args.ledger or str(
        a2a.outbox_db_path().parent / "a2a-diag-probe-ledger.json"
    )
    ledger = _a2a_load_diag_ledger(ledger_path)

    conn = a2a.open_outbox()
    report: list[dict[str, Any]] = []
    try:
        now = a2a.now_ts()
        # Backoff-waiting retry rows ONLY: status='retry' AND a future
        # next_attempt_ts. pending rows are already due; sending/leased rows
        # are mid-attempt and must never be disturbed; dead/acked are terminal.
        waiting = conn.execute(
            "SELECT peer, COUNT(*) AS n, MIN(next_attempt_ts) AS soonest, "
            "MAX(attempts) AS max_attempts "
            "FROM outbox WHERE status='retry' AND next_attempt_ts > ? "
            "GROUP BY peer ORDER BY peer ASC",
            (now,),
        ).fetchall()

        for prow in waiting:
            peer_id = prow["peer"]
            waiting_rows = int(prow["n"] or 0)
            soonest = int(prow["soonest"] or 0)
            next_in = max(0, soonest - now)
            # Resolve the peer to a current address (identity-keyed peers
            # resolve live via tailscale; raw-IP peers return the literal).
            address = ""
            port = int(cfg.get("listen", {}).get("port", 8787))
            resolve_err = ""
            try:
                peer = a2a.find_peer(cfg, peer_id)
                port = int(peer.get("port", port))
                address = a2a.resolve_peer_address(peer)
            except a2a.A2AError as exc:
                # TailscaleUnavailable is an A2AError subclass — both the
                # peer-unknown and tailscale-down cases land here, carrying a
                # machine-readable `.code` (tailscale_unavailable / resolve_*).
                resolve_err = f"{exc} ({exc.code})"

            if address:
                probe_ok, probe_detail = _a2a_tcp_probe(address, port, probe_timeout)
            else:
                probe_ok, probe_detail = False, (resolve_err or "unresolvable peer")

            local_healthz, healthz_detail = _a2a_local_healthz(cfg, probe_timeout)
            tailnet = _a2a_tailnet_asymmetry(address)
            classification = _a2a_classify_leg(
                probe_ok=probe_ok,
                local_healthz=local_healthz,
                tailnet=tailnet,
            )

            prev = ledger.get(peer_id)
            cur = "ok" if probe_ok else "fail"
            # Transition gate: reset ONLY on a fail→ok (or first-seen→ok)
            # transition, never on a sustained-ok every tick. A peer that
            # stays unreachable (cur='fail') is never reset → no thrash; its
            # backoff + max-attempts/dead-letter behavior is fully preserved.
            is_recovery_transition = probe_ok and prev != "ok"

            reset_rows = 0
            if probe_ok and is_recovery_transition and apply_reset:
                # Reuse the `outbox retry` SQL, peer-scoped: only status='retry'
                # rows (never pending/sending/leased), clear the lease, send now.
                cur_reset = conn.execute(
                    "UPDATE outbox SET status='pending', next_attempt_ts=0, "
                    "lease_owner=NULL, lease_expires_ts=0, updated_ts=? "
                    "WHERE peer=? AND status='retry'",
                    (now, peer_id),
                )
                conn.commit()
                reset_rows = cur_reset.rowcount or 0

            # Record the current probe result for the next-tick transition
            # gate — but ONLY when we actually applied resets. `--dry-run` is
            # strictly read-only: it must NOT consume the transition. Otherwise
            # an operator's `diagnose-stuck --dry-run` on a just-recovered peer
            # would stamp the ledger 'ok' without resetting any row, and the
            # next REAL run would see prev=='ok', skip the reset, and leave the
            # rows dormant until natural backoff / manual retry — re-opening the
            # exact recovery defect this PR closes.
            if apply_reset:
                ledger[peer_id] = cur

            report.append({
                "peer": peer_id,
                "address": address,
                "port": port,
                "waiting_rows": waiting_rows,
                "max_attempts": int(prow["max_attempts"] or 0),
                "next_attempt_in_seconds": next_in,
                "tcp_probe": cur,
                "tcp_probe_detail": probe_detail,
                "local_healthz": (
                    "healthy" if local_healthz is True
                    else "unhealthy" if local_healthz is False
                    else "indeterminate"
                ),
                "local_healthz_detail": healthz_detail,
                "peer_tailnet_online": tailnet.get("peer_online"),
                "classification": classification,
                "tcp_healthy_backoff_waiting": probe_ok,
                "backoff_reset": reset_rows > 0,
                "backoff_reset_rows": reset_rows,
                "recovery_transition": is_recovery_transition,
            })

        # Persist the transition ledger only on a real (non-dry-run) pass —
        # dry-run is strictly read-only and must leave the gate state for the
        # daemon untouched. Prune entries for peers no longer backoff-waiting
        # so it does not grow unboundedly. (A peer that drains or dead-letters
        # all its retry rows drops out of `waiting`; re-arming its transition
        # gate on a future stuck event is correct.)
        if apply_reset:
            live_peers = {str(p["peer"]) for p in waiting}
            ledger = {k: v for k, v in ledger.items() if k in live_peers}
            _a2a_save_diag_ledger(ledger_path, ledger)
    finally:
        conn.close()

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        if not report:
            info("no backoff-waiting retry rows")
        for r in report:
            line = (
                f"{r['peer']}: {r['classification']} "
                f"(tcp={r['tcp_probe']} healthz={r['local_healthz']} "
                f"waiting={r['waiting_rows']} next={r['next_attempt_in_seconds']}s"
            )
            if r["backoff_reset"]:
                line += f" -> RESET {r['backoff_reset_rows']} row(s) to send-now"
            line += ")"
            info(line)
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
    if not handoffd.is_file():  # noqa: raw-pathlib-controller-only
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
    if pid_file.exists():  # noqa: raw-pathlib-controller-only
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
# announce-identity (P-self-heal-3, design §9.6): push a signed
# peer-identity-update to every configured peer so they auto-update THIS
# node's stored identity/address after an IP change — closing the
# bidirectional-sync gap (no manual edit+restart on the peer side).
# --------------------------------------------------------------------------
#
# THIS NODE's identity is resolved from its OWN `tailscale status --json`
# (the Self node) — never a stored/asserted value. The control body is then
# HMAC-signed with the EXISTING per-pair secret and POSTed to each peer's
# /peer-identity-update endpoint, where the peer independently re-corroborates
# the claim against ITS own tailnet view before applying. This is NOT a
# discovery channel: it only reaches peers ALREADY in our config.


def _resolve_self_identity() -> "tuple[str, str, str]":
    """Resolve THIS node's (node_id, tailscale_name, tailscale_ip) from its
    OWN `tailscale status --json` Self record. Raises A2AError /
    TailscaleUnavailable on any failure (the caller fails closed — we never
    announce a guessed/stale identity)."""
    status = a2a.tailscale_status_json()
    self_node = status.get("Self")
    if not isinstance(self_node, dict):
        raise a2a.A2AError(
            "'tailscale status --json' has no Self node — cannot resolve this "
            "node's identity to announce.",
            code="self_no_node",
        )
    node_id = str(self_node.get("ID", "")).strip()
    name = a2a.node_name(self_node)
    ip = a2a._node_first_ip(self_node) or ""
    if not node_id and not name:
        raise a2a.A2AError(
            "this node's Tailscale Self record has neither a StableID nor a "
            "name — cannot build an identity-update.",
            code="self_no_identity",
        )
    if not ip:
        raise a2a.A2AError(
            "this node's Tailscale Self record has no TailscaleIP.",
            code="self_no_ip",
        )
    return node_id, name, ip


def _post_identity_update(
    *,
    address: str,
    port: int,
    path: str,
    local_bridge_id: str,
    secret: str,
    body_bytes: bytes,
    timeout: float,
) -> "tuple[int, dict[str, str], bytes]":
    """Sign + POST one peer-identity-update attempt. Mirrors `_post_envelope`:
    `X-AGB-Peer` + the canonical-string peer field carry the SENDER's own
    bridge_id (the authenticated identity the receiver looks up). The path is
    the control endpoint, so the signature domain is separate from enqueue."""
    timestamp = str(a2a.now_ts())
    message_id = a2a.new_message_id(local_bridge_id)
    body_hash = a2a.body_sha256(body_bytes)
    canonical = a2a.canonical_string(
        "POST", path, local_bridge_id, message_id, timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    url = f"http://{address}:{port}{path}"
    req = urllib.request.Request(url, data=body_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-AGB-Protocol", a2a.IDENTITY_UPDATE_PROTOCOL_VERSION)
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


def announce_identity(
    cfg: dict[str, Any],
    *,
    dry_run: bool,
    timeout: float,
    only_peer: Optional[str] = None,
) -> "tuple[int, list[str]]":
    """Resolve THIS node's identity and push a signed peer-identity-update to
    every configured peer (or just `only_peer`). Returns (rc, lines) where
    `lines` are human-readable per-peer results. Single-flight + idempotent is
    the CALLER's concern (the reconcile trigger only fires on actual IP
    change); a manual `announce-identity` always sends.

    Fail-closed: a failure to resolve THIS node's own identity is a hard
    error (rc=1, nothing sent) — we never announce a guessed identity."""
    local_bridge_id = cfg.get("bridge_id", "").strip()
    if not local_bridge_id:
        return 1, ["config has no 'bridge_id' — cannot announce identity "
                   "(the receiver matches it against its peer table)."]
    try:
        node_id, name, ip = _resolve_self_identity()
    except a2a.A2AError as exc:
        return 1, [f"cannot resolve this node's Tailscale identity: {exc} "
                   f"({exc.code}) — nothing announced (fail-closed)."]

    body = a2a.build_identity_update(
        bridge_id=local_bridge_id, node_id=node_id,
        tailscale_name=name, tailscale_ip=ip)
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")

    lines = [f"self identity: node_id={node_id or '-'} "
             f"name={name or '-'} ip={ip}"]

    peers = cfg.get("peers", [])
    if not isinstance(peers, list):
        peers = []
    targets = [p for p in peers if isinstance(p, dict)
               and (only_peer is None or p.get("id") == only_peer)]
    if only_peer is not None and not targets:
        return 1, lines + [f"peer not configured: {only_peer}"]
    if not targets:
        return 0, lines + ["(no peers configured — nothing to announce)"]

    rc = 0
    for peer in targets:
        pid = peer.get("id", "?")
        # Resolve the DESTINATION peer's current IP (identity-keyed peers
        # self-heal here too) + its signing secret. A resolve / secret failure
        # is per-peer non-fatal: report it and continue to the others.
        try:
            address = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            rc = 1
            lines.append(f"  {pid}: SKIP (address resolve failed: {exc.code})")
            continue
        if not address:
            rc = 1
            lines.append(f"  {pid}: SKIP (no resolvable address)")
            continue
        try:
            secret = a2a.peer_send_secret(peer)
        except a2a.A2AError:
            rc = 1
            lines.append(f"  {pid}: SKIP (no secret configured)")
            continue
        port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
        path = a2a.IDENTITY_UPDATE_PATH

        if dry_run:
            lines.append(f"  {pid}: would POST {path} to {address}:{port} "
                         f"(node_id={node_id or '-'} ip={ip})")
            continue
        try:
            status, _headers, resp = _post_identity_update(
                address=address, port=port, path=path,
                local_bridge_id=local_bridge_id, secret=secret,
                body_bytes=body_bytes, timeout=timeout)
        except (urllib.error.URLError, socket.timeout, OSError) as exc:
            rc = 1
            lines.append(f"  {pid}: FAIL (transport: {exc})")
            continue
        detail = ""
        try:
            detail = resp.decode("utf-8", "replace")[:160]
        except Exception:  # noqa: BLE001 - defensive only
            detail = ""
        if 200 <= status < 300:
            applied = '"applied": true' in detail or '"applied":true' in detail
            lines.append(f"  {pid}: OK ({status}; "
                         f"{'applied' if applied else 'no-op/duplicate'})")
        else:
            rc = 1
            lines.append(f"  {pid}: FAIL (HTTP {status}: {detail})")
    return rc, lines


def cmd_announce_identity(args: argparse.Namespace) -> int:
    """Push a signed peer-identity-update to peers (preview with --dry-run).

    For the setup wizard + operators after a Tailscale IP change. The
    reconcile path (P-self-heal-1) calls `announce_identity` directly when it
    detects THIS node's own IP drifted; this CLI is the manual entry point."""
    try:
        cfg = a2a.load_config()
        a2a.validate_config_peer_secrets(cfg, side="sender")
    except a2a.A2AError as exc:
        return die(str(exc)) or 1
    rc, lines = announce_identity(
        cfg, dry_run=args.dry_run, timeout=float(args.timeout or 10.0),
        only_peer=args.peer)
    for line in lines:
        info(line)
    if args.dry_run:
        info("DRY-RUN: nothing was sent. Re-run without --dry-run to announce.")
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
    """Write `cfg` as pretty JSON to `path` atomically, preserving `mode`.

    Thin wrapper over the shared `a2a.write_config_atomic` so the sender
    CLI and the receiver's peer-identity-update apply share ONE copy of the
    secret-bearing 0600-atomic write (no fork of the os.open-0600-from-start
    guarantee).
    """
    a2a.write_config_atomic(path, cfg, mode)


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
        orig_mode = cfg_path.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only
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
# setup wizard (P1, design §5/§6/§7; umbrella #1226, plan #1405-P1)
# --------------------------------------------------------------------------
#
# `agb a2a setup` — an agent-driven, decision-gated, idempotent/resumable
# orchestrator that produces the SAME handoff.local.json + receiver state the
# manual runbook does. It introduces NO new wire protocol, NO new bind/HMAC/
# allowlist path — it only sequences the merged self-heal helpers
# (resolve_tailscale_cli / tailscale_status_json / node_name / reverse_resolve_ip
# / write_config_atomic 0600 / validate_config_peer_secrets / _migrate_entry)
# plus the in-process peers/send/deliver and the `bridge-handoff-daemon.sh
# start` lifecycle verb (NEVER a raw `bridge-handoffd.py serve`).
#
# SECURITY-CRITICAL (it writes the config for + starts the receiver, the only
# untrusted-remote-traffic surface):
#   - The config is written ONLY via a2a.write_config_atomic at 0o600.
#   - The peer HMAC secret comes from `--peer-secret-env <ENVVAR>` (never a
#     plaintext flag — that leaks through the process table + shell history).
#     An empty/unset env var is a hard, fail-closed error (`peer_no_secret`);
#     the daemon is NOT started in that state.
#   - S5 activation shells to `bash bridge-handoff-daemon.sh start`, which runs
#     the UNCHANGED fail-closed bind preflight (`resolve_bind`: candidate ∈
#     `tailscale ip`; refuse wildcard/loopback; refuse if Tailscale
#     unavailable) before any detach. The wizard never binds itself and never
#     weakens that proof. The only loopback path is the pre-existing
#     `BRIDGE_A2A_ALLOW_TEST_BIND` escape hatch (smoke-only), inherited
#     verbatim — the wizard adds no new wildcard/loopback bypass.
#
# Resume / idempotency: there is NO setup-wizard.state file (a 2nd source of
# truth that can lie). The current S-state is DERIVED purely from observable
# facts each run, so a re-run asks "already true?" per state and is inherently
# a no-op once setup is complete. The only persistent artifact is
# handoff.local.json (atomic, 0600).

# The ordered state ids the wizard reasons about. S3 (secret-pairing) and S4
# (roster/allowlist exchange) are DEFERRED to P2/P3 — P1 keeps the manual
# secret (via --peer-secret-env) and takes the allowlist via flag.
_SETUP_STATES = ("S0", "S1", "S2", "S5", "S6", "DONE")


def _setup_result(
    state: str, *, done: bool, action: str, needs: Optional[list[str]] = None,
    detail: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """A single state probe's verdict.

    `state`  — the state id this probe covers (S0/S1/S2/S5/S6).
    `done`   — True iff this state's observable post-condition already holds.
    `action` — the next human/agent action when not done (empty when done).
    `needs`  — the flags/inputs required to advance (for the agent-driven loop).
    `detail` — optional structured facts (e.g. discovered peers) for --json.
    """
    return {
        "state": state,
        "done": done,
        "action": action,
        "needs": needs or [],
        "detail": detail or {},
    }


def _setup_load_cfg_or_empty() -> dict[str, Any]:
    """Load handoff.local.json, or return an empty skeleton when absent.

    A missing config is the early-install state — the wizard's whole job is to
    PRODUCE it, so "not found" is not an error here. A config that EXISTS but
    is group/world-readable is still a hard error (the 0600 contract): we
    re-raise so the operator fixes the mode rather than have the wizard
    silently overwrite a misperm'd secret-bearing file.
    """
    cfg_path = a2a.config_path()
    if not cfg_path.exists():  # noqa: raw-pathlib-controller-only
        return {"bridge_id": "", "listen": {}, "peers": []}
    return a2a.load_config(cfg_path)


def _setup_tailscale_self() -> "Optional[dict[str, Any]]":
    """Return the Tailscale Self node dict, or None if Tailscale is unavailable.

    Probe-only: callers in the wizard treat None as "S0 not satisfied" rather
    than raising, so `--show-state` can report S0 without crashing on a host
    that has no Tailscale yet. The ACT path (S0/S1) re-queries and DOES fail
    closed on TailscaleUnavailable so nothing is written without a tailnet view.
    """
    try:
        status = a2a.tailscale_status_json()
    except a2a.TailscaleUnavailable:
        return None
    self_node = status.get("Self")
    if isinstance(self_node, dict):
        return self_node
    return None


def _setup_listen_has_identity(cfg: dict[str, Any]) -> bool:
    """True iff `listen` carries a resolvable Tailscale identity OR an address."""
    listen = cfg.get("listen")
    if not isinstance(listen, dict):
        return False
    for key in ("node_id", "tailscale_name", "address"):
        val = listen.get(key)
        if isinstance(val, str) and val.strip():
            return True
    return False


def _setup_probe_s0(args: argparse.Namespace, cfg: dict[str, Any]) -> dict[str, Any]:
    """S0 preflight: is the Tailscale CLI present + the node authenticated?"""
    cli = a2a.resolve_tailscale_cli()
    if cli is None:
        return _setup_result(
            "S0", done=False,
            action="Install Tailscale (human-confirmed) and run `tailscale up` "
                   "to log in (browser auth — the one human-only step), then "
                   "re-run `agb a2a setup`.",
            needs=["tailscale-cli", "tailscale-login"],
            detail={"tailscale_cli": None},
        )
    self_node = _setup_tailscale_self()
    if self_node is None:
        return _setup_result(
            "S0", done=False,
            action="Tailscale CLI found but `tailscale status --json` has no "
                   "authenticated Self node — run `tailscale up` to log in, "
                   "then re-run.",
            needs=["tailscale-login"],
            detail={"tailscale_cli": cli, "authenticated": False},
        )
    return _setup_result(
        "S0", done=True, action="",
        detail={
            "tailscale_cli": cli,
            "authenticated": True,
            "self_node_id": str(self_node.get("ID", "")).strip(),
            "self_name": a2a.node_name(self_node),
            "self_ip": a2a._node_first_ip(self_node) or "",
        },
    )


def _setup_probe_s1(args: argparse.Namespace, cfg: dict[str, Any]) -> dict[str, Any]:
    """S1 self-config: is bridge_id set + listen identity-keyed (or addressed)?"""
    bridge_id = str(cfg.get("bridge_id", "")).strip()
    has_listen = _setup_listen_has_identity(cfg)
    if bridge_id and has_listen:
        return _setup_result(
            "S1", done=True, action="",
            detail={"bridge_id": bridge_id},
        )
    return _setup_result(
        "S1", done=False,
        action="Write this bridge's id + an identity-keyed `listen` to "
               "handoff.local.json (0600). Provide --bridge-id <id>; the "
               "listen identity is auto-derived from `tailscale status --json` "
               "Self.",
        needs=["--bridge-id"],
        detail={"bridge_id": bridge_id, "listen_configured": has_listen},
    )


def _setup_probe_s2(args: argparse.Namespace, cfg: dict[str, Any]) -> dict[str, Any]:
    """S2 discover: is the chosen peer present in peers[] (with a secret)?

    When `--peer` names a peer that is not yet configured, the probe lists the
    Online tailnet peers (so the agent can relay the pick) and reports the
    flags needed to add it. When no `--peer` is given but peers already exist,
    S2 is considered satisfied (the operator can add more peers by re-running
    with --peer).
    """
    peers = cfg.get("peers", [])
    if not isinstance(peers, list):
        peers = []
    want = getattr(args, "peer", None)
    if want:
        for peer in peers:
            if isinstance(peer, dict) and peer.get("id") == want:
                # Already configured — to COUNT as done it must be both
                # secret-bearing AND resolvable (identity-keyed or a pre-placed
                # raw address). A peer with a secret but no node_id/
                # tailscale_name/address is not actually usable (it cannot
                # resolve to a tailnet IP) — reporting it "done" was the
                # #1418 codex r1 BLOCKING-1 gap. Require both.
                has_secret = bool(a2a.peer_secrets(peer))
                resolvable = bool(peer.get("node_id")
                                  or peer.get("tailscale_name")
                                  or peer.get("address"))
                if has_secret and resolvable:
                    return _setup_result(
                        "S2", done=True, action="",
                        detail={"peer": want, "secret_configured": True,
                                "resolvable": True},
                    )
                if not has_secret:
                    return _setup_result(
                        "S2", done=False,
                        action=f"Peer {want} is configured but has no secret. "
                               "Re-run with --peer-secret-env <ENVVAR> set to a "
                               "long random shared secret (>=32 bytes).",
                        needs=["--peer-secret-env"],
                        detail={"peer": want, "secret_configured": False},
                    )
                return _setup_result(
                    "S2", done=False,
                    action=f"Peer {want} is configured but unresolvable (no "
                           "node_id/tailscale_name/address). Bring that node "
                           "Online so `tailscale status` lists it (then re-run "
                           "with --peer to re-key), or pre-place a raw `address`.",
                    needs=["--peer"],
                    detail={"peer": want, "secret_configured": True,
                            "resolvable": False},
                )
        # Not yet configured — list discoverable peers to relay the pick.
        return _setup_result(
            "S2", done=False,
            action=f"Add peer {want}: discover its Tailscale identity, then "
                   "write a peers[] entry keyed on node_id+tailscale_name with "
                   "--inbound-allowlist + the secret from --peer-secret-env.",
            needs=["--peer", "--peer-secret-env", "--inbound-allowlist"],
            detail={"peer": want, "discovered": _setup_discover_peers()},
        )
    if peers:
        # S2 (no --peer) counts as done only if at least one peer is USABLE:
        # both secret-bearing AND resolvable (node_id / tailscale_name /
        # address). A secret-bearing-but-unresolvable peer (hand-edited or
        # pre-existing config with the identity dropped) must NOT report done —
        # otherwise --show-state says S5/done and `setup --yes` (no --peer)
        # would activate the receiver against a dead peer while skipping S6.
        # (#1418 codex r2 BLOCKING — the no-peer branch was missing the
        # resolvability gate the --peer branch already has.)
        def _peer_usable(p: dict[str, Any]) -> bool:
            return bool(isinstance(p, dict) and a2a.peer_secrets(p) and (
                p.get("node_id") or p.get("tailscale_name") or p.get("address")))
        usable = [p for p in peers if _peer_usable(p)]
        if usable:
            return _setup_result(
                "S2", done=True, action="",
                detail={"peer_count": len(peers), "usable_peer_count": len(usable)},
            )
        # Peers exist but NONE is usable — report the specific defect per peer
        # so the agent can relay it, and keep S2 not-done (blocks S5 activation
        # of a dead config).
        defects = []
        for p in peers:
            if not isinstance(p, dict):
                continue
            pid = p.get("id", "<no-id>")
            if not a2a.peer_secrets(p):
                defects.append(f"{pid}: no secret")
            elif not (p.get("node_id") or p.get("tailscale_name")
                      or p.get("address")):
                defects.append(f"{pid}: unresolvable (no node_id/tailscale_name/address)")
        return _setup_result(
            "S2", done=False,
            action="Configured peer(s) are not usable (" + "; ".join(defects)
                   + "). Re-run `setup --peer <id> --peer-secret-env <ENVVAR>` "
                   "with that node Online (to identity-key it), or pre-place a "
                   "raw `address`, so the peer resolves. S5 will not activate "
                   "against an unusable peer set.",
            needs=["--peer", "--peer-secret-env"],
            detail={"peer_count": len(peers), "usable_peer_count": 0,
                    "defects": defects},
        )
    return _setup_result(
        "S2", done=False,
        action="No peer chosen and none configured. Pick a peer from the "
               "discovered Online tailnet nodes and re-run with --peer <id> "
               "--peer-secret-env <ENVVAR> [--inbound-allowlist a,b].",
        needs=["--peer", "--peer-secret-env"],
        detail={"discovered": _setup_discover_peers()},
    )


def _setup_discover_peers() -> list[dict[str, Any]]:
    """List Online tailnet peers for the agent to relay the human pick.

    Probe-only: returns [] when Tailscale is unavailable (S0 handles that). The
    fields are the identity-decision inputs the human needs (HostName, the
    MagicDNS name, the live IPs, OS, StableID, Online)."""
    try:
        status = a2a.tailscale_status_json()
    except a2a.TailscaleUnavailable:
        return []
    out: list[dict[str, Any]] = []
    raw_peers = status.get("Peer")
    if not isinstance(raw_peers, dict):
        return out
    for node in raw_peers.values():
        if not isinstance(node, dict):
            continue
        if not node.get("Online"):
            continue
        out.append({
            "node_id": str(node.get("ID", "")).strip(),
            "tailscale_name": a2a.node_name(node),
            "host_name": str(node.get("HostName", "")).strip(),
            "tailscale_ips": [ip for ip in (node.get("TailscaleIPs") or [])
                              if isinstance(ip, str)],
            "os": str(node.get("OS", "")).strip(),
            "online": True,
        })
    return out


def _setup_probe_s5(args: argparse.Namespace, cfg: dict[str, Any]) -> dict[str, Any]:
    """S5 activate: is the receiver running + does the config pass the secret check?"""
    secret_ok = True
    secret_detail = ""
    try:
        a2a.validate_config_peer_secrets(cfg, side="receiver")
    except a2a.A2AError as exc:
        secret_ok = False
        secret_detail = f"{exc} ({exc.code})"
    running = _setup_receiver_running()
    if secret_ok and running:
        return _setup_result(
            "S5", done=True, action="",
            detail={"receiver_running": True, "secret_ok": True},
        )
    if not secret_ok:
        return _setup_result(
            "S5", done=False,
            action="Refuse to activate: a peer has no secret (fail-closed). "
                   "Set --peer-secret-env to a long random shared secret and "
                   "re-run. The receiver will NOT be started in this state.",
            needs=["--peer-secret-env"],
            detail={"receiver_running": running, "secret_ok": False,
                    "secret_error": secret_detail},
        )
    return _setup_result(
        "S5", done=False,
        action="Start the receiver via `bridge-handoff-daemon.sh start` "
               "(runs the fail-closed tailnet bind preflight, then detaches). "
               "Re-run with --yes to confirm activation.",
        needs=["--yes"],
        detail={"receiver_running": False, "secret_ok": True},
    )


def _setup_receiver_running() -> bool:
    """True iff a receiver pid file points at a live process.

    Mirrors the lifecycle helper's pid-file model (state/handoff/handoffd.pid)
    without importing the bash. A stale pid file (process gone) reads as
    not-running, which is exactly what S5 should re-activate."""
    pid_file = a2a.handoff_dir() / "handoffd.pid"
    if not pid_file.exists():  # noqa: raw-pathlib-controller-only
        return False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but owned by another uid — treat as running.
        return True
    except OSError:
        return False
    return True


def _setup_probe_s6(args: argparse.Namespace, cfg: dict[str, Any]) -> dict[str, Any]:
    """S6 handshake: this state is only ever 'done' transiently after a run.

    There is no durable observable for "the last handshake acked" (and we do
    NOT store one — no state file), so --show-state reports S6 as the final
    pending action once S0–S5 hold. cmd_setup runs the actual handshake
    (peers test + dry-run send, and a live send when --live-handshake)."""
    return _setup_result(
        "S6", done=False,
        action="Run the handshake: `agb a2a peers test <peer>` + a dry-run "
               "send. Pass --live-handshake to also do a real send+deliver and "
               "assert a 2xx ack (creates an inbox task on the peer).",
        needs=[],
        detail={},
    )


def _setup_detect_state(
    args: argparse.Namespace, cfg: dict[str, Any],
) -> "tuple[str, list[dict[str, Any]]]":
    """Run the ordered probes and return (current_state, all_probe_results).

    The current state is the FIRST state whose probe is not done; if S0–S5 all
    hold, the current state is S6 (the handshake is the last pending action);
    only after a successful handshake within `cmd_setup` is DONE reported.
    """
    probes = [
        _setup_probe_s0(args, cfg),
        _setup_probe_s1(args, cfg),
        _setup_probe_s2(args, cfg),
        _setup_probe_s5(args, cfg),
        _setup_probe_s6(args, cfg),
    ]
    for probe in probes:
        if not probe["done"]:
            return probe["state"], probes
    return "DONE", probes


def _setup_show_state(args: argparse.Namespace) -> int:
    """`--show-state` — report the detected S-state + next action + needed inputs.

    The agent-driven loop linchpin + the headless smoke driver: derive the
    state from observable facts (no state file), print the current state, the
    next action, and the flags needed to advance. `--json` emits the machine
    form (current_state + the full ordered probe list)."""
    try:
        cfg = _setup_load_cfg_or_empty()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1
    current, probes = _setup_detect_state(args, cfg)
    by_state = {p["state"]: p for p in probes}
    if args.json:
        print(json.dumps({
            "current_state": current,
            "states": probes,
        }, ensure_ascii=False, indent=2))
        return 0
    print(f"current state: {current}")
    if current == "DONE":
        print("  A2A setup is complete (S0–S6 satisfied). Nothing to do.")
        return 0
    probe = by_state.get(current, {})
    action = probe.get("action", "")
    needs = probe.get("needs", [])
    if action:
        print(f"  next action: {action}")
    if needs:
        print(f"  needs: {', '.join(needs)}")
    return 0


def cmd_setup(args: argparse.Namespace) -> int:
    """`agb a2a setup` — the P1 wizard (S0/S1/S2/S5/S6, manual secret).

    Decision-gated + idempotent/resumable. With --show-state it only REPORTS
    the derived state (no mutation). Otherwise it advances each state in order,
    gated by the supplied flags + --yes, writing the config atomically at 0600
    and starting the receiver only after a fail-closed bind preflight. The
    secret is read from --peer-secret-env (never a plaintext flag); an empty
    secret is a hard fail-closed error and the daemon is NOT started."""
    if args.show_state:
        return _setup_show_state(args)

    # --- resolve the secret from the named env var (fail-closed if empty) ---
    secret = ""
    if args.peer_secret_env:
        secret = os.environ.get(args.peer_secret_env, "")
        # Note: we do NOT echo the secret anywhere — only its presence.

    try:
        cfg = _setup_load_cfg_or_empty()
    except a2a.A2AError as exc:
        return die(str(exc)) or 1

    # ===== S0 preflight =====
    s0 = _setup_probe_s0(args, cfg)
    if not s0["done"]:
        info(f"S0 preflight: {s0['action']}")
        return die("S0 not satisfied — Tailscale must be installed + logged in "
                   "before the wizard can write a config or start the "
                   "receiver (fail-closed).", code="setup_s0") or 1
    info(f"S0 OK: tailscale authenticated (self ip "
         f"{s0['detail'].get('self_ip', '?')})")

    # ===== S1 self-config: bridge_id + identity-keyed listen =====
    s1_changed = False
    if args.bridge_id:
        if str(cfg.get("bridge_id", "")).strip() != args.bridge_id:
            cfg["bridge_id"] = args.bridge_id
            s1_changed = True
    if not str(cfg.get("bridge_id", "")).strip():
        return die("S1 needs --bridge-id (this bridge's id; the receiver "
                   "matches it against a peer's inbound allowlist).",
                   code="setup_s1") or 1

    listen = cfg.get("listen")
    if not isinstance(listen, dict):
        listen = {}
        cfg["listen"] = listen
    if args.listen_port:
        if int(listen.get("port", 0) or 0) != int(args.listen_port):
            listen["port"] = int(args.listen_port)
            s1_changed = True
    listen.setdefault("port", 8787)
    # Identity-key the listen on this node's Tailscale Self (never a raw IP).
    if not _setup_listen_has_identity(cfg) or args.bridge_id:
        self_node_id = s0["detail"].get("self_node_id", "")
        self_name = s0["detail"].get("self_name", "")
        if self_node_id and not listen.get("node_id"):
            listen["node_id"] = self_node_id
            s1_changed = True
        if self_name and not listen.get("tailscale_name"):
            listen["tailscale_name"] = self_name
            s1_changed = True
    # Migrate a pre-existing raw-IP listen to identity keying (kept address as
    # a fallback) using the SAME helper migrate-identity uses.
    if isinstance(listen, dict) and listen.get("address") and not (
            listen.get("node_id") or listen.get("tailscale_name")):
        try:
            status = a2a.tailscale_status_json()
            rec = _migrate_entry(listen, status, "listen", drop_address=False)
            if rec is not None:
                s1_changed = True
        except a2a.A2AError:
            pass  # leave as-is; the raw address still binds (back-compat)

    # ===== S2 discover: write/refresh the chosen peer entry =====
    s2_changed = False
    if args.peer:
        # ===== S2 fail-closed PRE-FLIGHT — validate EVERYTHING before any cfg
        # mutation or write (#1418 codex r1, both BLOCKINGs). The peer entry is
        # only written once it is (a) secret-bearing AND (b) resolvable — either
        # identity-keyed from a discovered Online node, or carrying a
        # pre-placed raw `address`. A peer that fails either check must NEVER be
        # persisted (no secretless peer on disk; no secret-bearing-but-dead
        # un-keyed peer that _setup_probe_s2 would then report as "done" and
        # that `setup --yes` without --peer could activate while skipping S6).

        # Locate any existing entry first (an operator may have pre-placed a raw
        # `address`, or a prior run already wrote an identity + secret, for a
        # peer that is not currently Online — back-compat / re-run).
        peers = cfg.get("peers", [])
        if not isinstance(peers, list):
            peers = []
            cfg["peers"] = peers
        existing = None
        for peer in peers:
            if isinstance(peer, dict) and peer.get("id") == args.peer:
                existing = peer
                break

        # (1) Secret is MANDATORY — but it may come from --peer-secret-env
        #     (non-empty) OR an already-on-disk secret on the existing entry
        #     (so re-running `setup --peer X` to re-key/handshake an
        #     already-configured peer does not force re-supplying the secret).
        #     A NEW or secretless peer with no usable secret source is a hard
        #     fail-closed error BEFORE any mutation. (Pre-fix the guard was
        #     gated on `args.peer_secret_env` being PRESENT, so a MISSING flag
        #     bypassed it and stranded a secretless peer — codex r1 BLOCKING-2.)
        if args.peer_secret_env and not secret:
            return die(
                f"--peer-secret-env {args.peer_secret_env} is empty/unset. "
                "Export a long random shared secret (>=32 bytes) into that env "
                "var, e.g. `export "
                f"{args.peer_secret_env}=$(openssl rand -hex 32)`, then re-run. "
                "Refusing to write an empty secret (fail-closed).",
                code="peer_no_secret") or 1
        has_existing_secret = bool(existing and a2a.peer_secrets(existing))
        if not secret and not has_existing_secret:
            return die(
                "--peer requires a shared secret: pass --peer-secret-env "
                "<ENVVAR> (a non-empty long random secret >=32 bytes, e.g. "
                "`export A2A_PEER_SECRET=$(openssl rand -hex 32)`), or re-run "
                "against a config where this peer already has one. Refusing to "
                "write a peer without a secret (fail-closed).",
                code="peer_no_secret") or 1

        # (2) Resolve the peer's Tailscale identity. --peer is the operator's
        #     choice relayed as the id; if a discovered Online node's
        #     node_id / MagicDNS name / HostName equals it, we key on that
        #     node's identity (self-heals on the peer's IP change).
        match = None
        for node in _setup_discover_peers():
            if args.peer in (node.get("tailscale_name"), node.get("host_name"),
                             node.get("node_id")):
                match = node
                break

        # (3) The peer MUST be resolvable: either we matched a live tailnet
        #     identity, OR an existing entry already carries an identity / raw
        #     address. If neither, REFUSE — do not persist a secret-bearing but
        #     unresolvable un-keyed peer (codex r1 BLOCKING-1). P1 does not
        #     invent an identity it cannot observe.
        has_prior_resolvable = bool(existing and (
            existing.get("node_id") or existing.get("tailscale_name")
            or existing.get("address")))
        if match is None and not has_prior_resolvable:
            return die(
                f"peer {args.peer!r} is not among the Online Tailscale nodes "
                "and has no pre-placed `address`. Refusing to write an "
                "unresolvable peer (fail-closed). Bring that node Online so "
                "`tailscale status` lists it, or pre-place a raw `address` for "
                "it in handoff.local.json, then re-run.",
                code="peer_unresolvable") or 1

        # ===== all checks passed — now mutate the cfg =====
        if existing is None:
            existing = {"id": args.peer}
            peers.append(existing)
            s2_changed = True
        if match:
            if match.get("node_id") and existing.get("node_id") != match["node_id"]:
                existing["node_id"] = match["node_id"]
                s2_changed = True
            if match.get("tailscale_name") and \
                    existing.get("tailscale_name") != match["tailscale_name"]:
                existing["tailscale_name"] = match["tailscale_name"]
                s2_changed = True
        else:
            # No live match but a prior entry is resolvable (pre-placed address
            # or previously-keyed identity) — keep it, note we did not re-key.
            info(
                f"peer {args.peer!r} not currently Online; keeping its existing "
                "identity/address (not re-keyed this run).")
        existing.setdefault("port", int(listen.get("port", 8787)))
        existing.setdefault("enqueue_path", "/enqueue")
        if args.inbound_allowlist is not None:
            allow = [a.strip() for a in args.inbound_allowlist.split(",")
                     if a.strip()]
            if existing.get("inbound_allowlist") != allow:
                existing["inbound_allowlist"] = allow
                s2_changed = True
        # Persist a NEWLY-supplied non-empty secret. When `secret` is empty we
        # only reach here because the existing entry already has one (validated
        # above) — do NOT clobber that good on-disk secret with an empty value.
        if secret and existing.get("secret") != secret:
            existing["secret"] = secret
            s2_changed = True

    # ===== persist the config atomically at 0600 if anything changed =====
    if s1_changed or s2_changed:
        cfg_path = a2a.config_path()
        try:
            orig_mode = cfg_path.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only
        except OSError:
            orig_mode = 0o600
        a2a.write_config_atomic(cfg_path, cfg, orig_mode)
        info(f"wrote {cfg_path} (mode 0600; "
             f"S1{'*' if s1_changed else ''} S2{'*' if s2_changed else ''})")
    else:
        info("config already current (no changes written)")

    # ===== S5 activate: validate secrets (fail-closed) then start receiver ==
    try:
        a2a.validate_config_peer_secrets(cfg, side="receiver")
    except a2a.A2AError as exc:
        return die(f"S5 refuses to activate: {exc} ({exc.code}). The receiver "
                   "was NOT started.", code="setup_s5_secret") or 1

    # Resolvability gate (#1418 codex r2 BLOCKING, defense-in-depth): refuse to
    # activate a config that HAS peers but NONE is resolvable (no node_id /
    # tailscale_name / address). This is independent of --show-state's probe, so
    # a `setup --yes` (no --peer) against a hand-edited / pre-existing dead
    # config cannot start a receiver that would skip S6 against an unreachable
    # peer set. A peer becomes resolvable by bringing its node Online (re-key
    # via `setup --peer`) or pre-placing a raw `address`.
    s5_peers = cfg.get("peers", []) if isinstance(cfg.get("peers"), list) else []
    if s5_peers and not any(
            isinstance(p, dict) and (p.get("node_id") or p.get("tailscale_name")
                                     or p.get("address"))
            for p in s5_peers):
        return die(
            "S5 refuses to activate: the config has peer(s) but NONE is "
            "resolvable (no node_id/tailscale_name/address). The receiver was "
            "NOT started. Re-run `setup --peer <id> --peer-secret-env <ENVVAR>` "
            "with that node Online to identity-key it, or pre-place a raw "
            "`address`, then re-run.",
            code="setup_s5_unresolvable_peers") or 1

    if not _setup_receiver_running():
        if not args.yes:
            info("S5: receiver not running. Re-run with --yes to start it "
                 "(`bridge-handoff-daemon.sh start` — fail-closed bind "
                 "preflight, then detach).")
            return 0
        rc = _setup_start_receiver()
        if rc != 0:
            return die("S5: receiver failed to start (bind preflight or "
                       "detach failed) — see the daemon log.",
                       code="setup_s5_start") or 1
        info("S5 OK: receiver started")
    else:
        info("S5 OK: receiver already running")

    # ===== S6 handshake: peers test + dry-run; live send behind --live-handshake
    if not args.peer:
        info("S6: no --peer given; skipping the handshake (S0–S5 satisfied).")
        return 0
    return _setup_handshake(cfg, args)


def _setup_start_receiver() -> int:
    """Shell to `bash bridge-handoff-daemon.sh start` — NEVER raw serve.

    The lifecycle verb runs the UNCHANGED fail-closed bind preflight
    (resolve_bind: candidate ∈ `tailscale ip`; refuse wildcard/loopback; refuse
    if Tailscale unavailable) BEFORE any detach, then double-fork detaches the
    durable listener. Returns the subprocess exit code (non-zero = bind
    preflight failed / no durable listener)."""
    import subprocess  # noqa: PLC0415 (only this path needs it)
    daemon = Path(__file__).resolve().parent / "bridge-handoff-daemon.sh"
    if not daemon.is_file():  # noqa: raw-pathlib-controller-only
        err(f"cannot locate {daemon}")
        return 1
    bash = os.environ.get("BRIDGE_BASH_BIN", "bash")
    try:
        proc = subprocess.run(  # noqa: PLW1510 (rc handled by caller)
            [bash, str(daemon), "start"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as exc:
        err(f"could not run {daemon.name} start: {exc}")
        return 1
    for line in (proc.stdout or "").splitlines():
        if line.strip():
            info(line)
    for line in (proc.stderr or "").splitlines():
        if line.strip():
            err(line)
    return proc.returncode


def _setup_handshake(cfg: dict[str, Any], args: argparse.Namespace) -> int:
    """S6: resolve+probe the peer, dry-run a send, and (opt-in) a live send.

    DEFAULT = GREEN-on-reachable: resolve the peer to its current IP, TCP-probe
    it, and validate a dry-run send envelope — WITHOUT creating an inbox task
    on the peer. `--live-handshake` additionally stages a real send, drains it
    once, and asserts a 2xx ack carrying a remote task id."""
    peer_id = args.peer
    try:
        peer = a2a.find_peer(cfg, peer_id)
    except a2a.A2AError as exc:
        return die(f"S6: {exc}", code="setup_s6_peer") or 1
    # Resolve the peer's CURRENT tailnet IP (identity-keyed → live resolve;
    # fail-closed if unresolvable — never probe a stale stored IP).
    try:
        address = a2a.resolve_peer_address(peer)
    except a2a.A2AError as exc:
        return die(f"S6: cannot resolve peer {peer_id}: {exc} ({exc.code})",
                   code=exc.code) or 1
    if not address:
        return die(f"S6: peer {peer_id} has no resolvable address",
                   code="setup_s6_noaddr") or 1
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    info(f"S6: peer {peer_id} resolves to {address}:{port}")
    # TCP-probe (reachability) — mirrors `peers test` (no enqueue).
    try:
        with socket.create_connection((address, port), timeout=5.0):
            pass
    except OSError as exc:
        return die(f"S6: peer {peer_id} not reachable at {address}:{port}: "
                   f"{exc}", code="setup_s6_unreachable") or 1
    info(f"S6: peer {peer_id} reachable (TCP) at {address}:{port}")

    if not args.live_handshake:
        info("S6 OK (dry-run): peer resolved + reachable. Pass "
             "--live-handshake to do a real send+deliver ack.")
        return 0

    # --- live handshake: real send + deliver + assert a 2xx ack ---
    sender_agent = (os.environ.get("BRIDGE_AGENT_ID")
                    or os.environ.get("USER") or "setup-wizard")
    target = ""
    allow = peer.get("inbound_allowlist")
    if isinstance(allow, list) and allow:
        target = str(allow[0])
    if not target:
        return die("S6 --live-handshake needs a target agent in the peer's "
                   "inbound_allowlist (set --inbound-allowlist).",
                   code="setup_s6_no_target") or 1
    send_ns = argparse.Namespace(
        peer=peer_id, to=target, from_agent=sender_agent,
        title="a2a setup handshake", body="A2A setup wizard live handshake.",
        body_file=None, priority="normal", allow_empty_body=False,
        dry_run=False,
    )
    rc = cmd_send(send_ns)
    if rc != 0:
        return die("S6 --live-handshake: staging the send failed.",
                   code="setup_s6_send") or 1
    deliver_ns = argparse.Namespace(batch=10, lease=60, timeout=10.0)
    cmd_deliver(deliver_ns)
    # Assert the row acked (carrying a remote task id).
    conn = a2a.open_outbox()
    try:
        row = conn.execute(
            "SELECT status, acked_remote_task_id FROM outbox "
            "WHERE peer=? ORDER BY created_ts DESC LIMIT 1", (peer_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return die("S6 --live-handshake: no outbox row after send.",
                   code="setup_s6_norow") or 1
    if row["status"] != "acked":
        return die(f"S6 --live-handshake: send did not ack (status="
                   f"{row['status']}).", code="setup_s6_noack") or 1
    info(f"S6 OK (live): handshake acked (remote task "
         f"{row['acked_remote_task_id'] or '?'}) — GREEN.")
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

    # #1563 PR-8: directional diagnosis + probe-gated backoff recovery.
    p_diag = sub.add_parser(
        "diagnose-stuck",
        help="classify backoff-waiting retry rows by failing leg + reset "
             "backoff for peers whose TCP probe recovered (#1563 PR-8)")
    p_diag.add_argument("--json", action="store_true",
                        help="emit the machine report to stdout")
    p_diag.add_argument("--dry-run", action="store_true",
                        help="classify + report only, do NOT reset any backoff")
    p_diag.add_argument("--probe-timeout", type=float, default=None,
                        help="TCP-connect / healthz timeout seconds (default 5)")
    p_diag.add_argument("--ledger", default=None,
                        help="per-peer probe-result ledger path for "
                             "transition-gating (default under the outbox dir)")
    p_diag.set_defaults(func=cmd_diagnose_stuck)

    p_reconcile = sub.add_parser(
        "reconcile",
        help="trigger + preview one receiver self-heal reconcile "
             "(re-resolve+prove bind, config hot-reload via SIGHUP)")
    p_reconcile.set_defaults(func=cmd_reconcile)

    p_announce = sub.add_parser(
        "announce-identity",
        help="push a signed peer-identity-update to peers after an IP change "
             "(so they auto-update this node's identity; --dry-run to preview)",
        description=(
            "Resolve THIS node's current Tailscale identity (node_id + "
            "MagicDNS name + IP) from its OWN `tailscale status --json` and "
            "push an HMAC-signed peer-identity-update to every configured peer "
            "(or just --peer <id>). Each peer independently re-corroborates "
            "the claim against ITS own tailscale status before applying — the "
            "wire-asserted IP is never trusted. Only reaches ALREADY-PAIRED "
            "peers (not a discovery channel). Dry-run with --dry-run."
        ),
    )
    p_announce.add_argument("--peer", default=None,
                            help="announce to a single configured peer "
                                 "(default: all peers)")
    p_announce.add_argument("--dry-run", action="store_true",
                            help="resolve + show what would be sent, send nothing")
    p_announce.add_argument("--timeout", type=float, default=None,
                            help="per-peer HTTP timeout seconds (default 10)")
    p_announce.set_defaults(func=cmd_announce_identity)

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

    p_setup = sub.add_parser(
        "setup",
        help="agent-driven A2A setup wizard (S0/S1/S2/S5/S6, manual secret, "
             "idempotent/resumable)",
        description=(
            "Agent-driven, decision-gated, idempotent/resumable wizard that "
            "produces the SAME handoff.local.json + receiver state the manual "
            "runbook does — no new wire protocol. Flag path is the contract "
            "(the agent relays human decisions as flags + re-runs); --show-state "
            "[--json] reports the derived S-state + next action + needed inputs "
            "(the agent-driven loop linchpin). There is NO state file — the "
            "S-state is derived from observable facts each run, so a re-run is a "
            "no-op once complete. SECURITY: the config is written 0600; the peer "
            "HMAC secret comes from --peer-secret-env (NEVER a plaintext flag); "
            "an empty secret is a hard fail-closed error and the receiver is NOT "
            "started; S5 starts the receiver via `bridge-handoff-daemon.sh "
            "start`, which runs the unchanged fail-closed tailnet bind preflight."
        ),
    )
    p_setup.add_argument("--bridge-id", default=None,
                         help="this bridge's id (the authenticated sender "
                              "identity; S1)")
    p_setup.add_argument("--peer", default=None,
                         help="the peer bridge id to connect to (S2)")
    p_setup.add_argument(
        "--peer-secret-env", default=None,
        help="NAME of the env var holding the peer's HMAC secret (read from "
             "the environment, never the command line — avoids the "
             "process-table/shell-history leak of a plaintext flag). "
             "Empty/unset is a hard fail-closed error.",
    )
    p_setup.add_argument("--listen-port", type=int, default=None,
                         help="receiver listen port (default 8787; S1)")
    p_setup.add_argument("--inbound-allowlist", default=None,
                         help="comma-separated local agent ids this peer may "
                              "enqueue to (S2; exact match, no wildcard)")
    p_setup.add_argument(
        "--install", action="store_true",
        help="(reserved) confirm an automated Tailscale install in S0 — P1 "
             "surfaces the install instruction; it does not auto-install.",
    )
    p_setup.add_argument("--show-state", action="store_true",
                         help="report the detected S-state + next action + "
                              "needed inputs, then exit (no mutation)")
    p_setup.add_argument("--json", action="store_true",
                         help="with --show-state, emit the machine-readable "
                              "state document")
    p_setup.add_argument("--yes", action="store_true",
                         help="confirm activation (S5 starts the receiver)")
    p_setup.add_argument(
        "--live-handshake", action="store_true",
        help="S6: do a REAL send+deliver and assert a 2xx ack (creates an "
             "inbox task on the peer). Default is dry-run + GREEN-on-reachable.",
    )
    p_setup.set_defaults(func=cmd_setup)

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
