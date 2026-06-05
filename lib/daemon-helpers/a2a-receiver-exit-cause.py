#!/usr/bin/env python3
"""a2a-receiver-exit-cause.py — assemble an A2A receiver exit-cause record.

Invoked by ``process_a2a_receiver_supervise_tick`` in bridge-daemon.sh when
the supervisor detects a dead/wedged receiver (#1405). It mines the two
artifacts the receiver itself leaves behind and writes a single secret-free
JSON object to an output file so the supervisor (and ``agent-bridge status``)
can show WHY the receiver went down instead of the silent black-hole the
issue reported.

#1563 PR-4: it also CLASSIFIES the exit into an ``error_class`` so the
supervisor can back off a TRANSIENT bind-availability failure (tailnet not
yet up / IP drift after a re-login) instead of thrashing it into a ~9-minute
crash-loop, while a real auth/config error is held immediately (NOT retried).
The classification is observability-only — it NEVER changes what the receiver
accepts or binds; the fail-closed bind/HMAC boundary in bridge-handoffd.py is
untouched.

Invocation contract (ALL paths passed as argv — footgun #11: NO heredoc-stdin
/ here-string to a captured subprocess; mirror process_a2a_outbox_stuck_scan_tick
at bridge-daemon.sh which writes JSON to a tmp file and reads it back):

    a2a-receiver-exit-cause.py \
        <out_json> <log_file> <jsonl_file> <reason> <last_pid> <detected_ts> \
        [tail_lines] [config_file]

  out_json     : path to write the exit-cause JSON object to (mode 0600).
  log_file     : logs/a2a-handoffd.log — the receiver's stdout/stderr log.
  jsonl_file   : logs/a2a-handoff.jsonl — the receiver's structured audit log.
  reason       : the supervisor's own classification (process_gone /
                 healthz_timeout / healthz_status:<code> / bind_proof_failed /
                 bind_unresolved).
  last_pid     : the pid the supervisor last knew the receiver by ("" if none).
  detected_ts  : unix ts the supervisor detected the death.
  tail_lines   : how many trailing log lines to capture (default 20).
  config_file  : optional handoff.local.json path; when present we compute a
                 secret-free config_fingerprint so the supervisor can key its
                 backoff/circuit-breaker per (config-fingerprint, error_class)
                 and reset it cleanly when the config changes. NEVER includes
                 any peer secret — only structural identity (bind + peer ids).

Output JSON fields:
  detected_ts, reason, last_pid,
  log_tail        : last <tail_lines> lines of log_file (each already
                    secret-free — the receiver's audit() never logs secrets
                    or bodies), trailing whitespace stripped.
  last_audit_event: the LAST terminal audit event mined from jsonl_file
                    (bind_fail / startup_fail / stopped), as a dict with its
                    event + code/detail/address/port/phase when present; null
                    if no terminal event is found. The jsonl carries the
                    authoritative cause (bridge-handoffd.py audit()).
  error_class     : "transient" | "auth_config" | "unknown" — the supervision
                    policy class (see _classify_error_class).
  config_fingerprint: a short secret-free hash of the config's structural
                    identity, or "" when no config_file was given / readable.

The helper is read-only over the audit log and the daemon log; it never
touches the live receiver, its socket, or its config. It always exits 0 and
writes at least a minimal record so the supervisor has something to stamp
even when both artifacts are missing/unreadable.
"""

import hashlib
import json
import os
import sys

# Terminal audit events the receiver emits right before/at exit. We scan the
# jsonl from the end and surface the most recent one as the authoritative
# cause. `listening` is intentionally NOT terminal — it marks a (re)start.
_TERMINAL_EVENTS = ("bind_fail", "startup_fail", "stopped")
# Only these fields are carried out of the matched audit record. Whitelisted
# (not passthrough) so a future audit field carrying sensitive data can never
# leak into the exit-cause record by accident. `phase` (#1563 PR-4) tags the
# config-vs-bind stage the receiver failed at — the primary classifier signal.
_AUDIT_FIELD_ALLOWLIST = ("event", "ts", "code", "detail", "address", "port",
                          "phase")

# --- #1563 PR-4 classification taxonomy ---------------------------------
#
# error_class is the supervision-policy class, NOT a security decision. The
# fail-closed receiver still refuses every bad bind / bad HMAC regardless of
# this label; the label only tells the supervisor whether to BACK OFF (the
# error is a transient network/bind-availability blip, config+secret are
# valid) or HOLD immediately (a real auth/config error that retrying cannot
# fix and that would otherwise thrash).
#
# TRANSIENT — network/bind availability, config+secret PROVEN valid:
#   the receiver reached resolve_bind / socket-bind (so validate_config_peer
#   _secrets already PASSED) and failed on an availability condition. These
#   clear on their own when the tailnet comes up / the IP re-stabilizes.
_TRANSIENT_CODES = frozenset({
    "tailscale_unavailable",   # `tailscale` CLI/daemon not up yet
    "bind_unresolved",         # auto-select found no tailnet IP (tailnet down)
    "bind_not_tailnet",        # configured addr not in CURRENT tailnet set (IP drift)
    "resolve_no_ip",           # identity given but tailscale can't resolve yet
    "resolve_node_id_unknown",
    "resolve_name_unknown",
})
# AUTH/CONFIG — non-transient operator error; retrying only thrashes:
#   a bad/missing secret, malformed config, or a STRUCTURALLY bad bind target
#   the operator configured (wildcard / loopback / non-IP). The fail-closed
#   refusal of these is correct and permanent until the operator fixes config.
_AUTH_CONFIG_CODES = frozenset({
    "peer_no_secret",
    "config_missing", "config_stat", "config_perms", "config_parse",
    "config_shape", "bind_config", "bind_not_ip",
    "bind_wildcard", "bind_loopback",
    "resolve_shape",
})


def _classify_error_class(reason, audit_event):
    """Map the supervisor reason + mined audit event to a supervision class.

    Returns one of: "transient", "auth_config", "unknown".

    Precedence:
      1. The mined audit event's ``phase`` (set by bridge-handoffd.py #1563
         PR-4): phase=config => auth_config (never transient); phase=bind =>
         decide by the specific code (a structurally-bad bind target is
         auth_config, an availability code is transient).
      2. The audit event's ``code`` against the transient / auth_config sets.
      3. The supervisor ``reason`` word as a fallback (process_gone /
         healthz_timeout are NOT bind-availability classes — a previously
         healthy receiver that died/wedged may restart promptly, so they are
         "unknown", NOT "transient": the supervisor must not back those off as
         if they were a tailnet blip).

    Conservative by design: anything we cannot positively prove is a transient
    availability error stays out of the back-off path (returns "unknown" or
    "auth_config"), because over-classifying as transient is what would let a
    real failure thrash.
    """
    audit_event = audit_event or {}
    phase = (audit_event.get("phase") or "").strip().lower()
    code = (audit_event.get("code") or "").strip()

    # (1) phase is the strongest signal — it is set right at the failing stage.
    if phase == "config":
        return "auth_config"
    if phase == "bind":
        if code in _AUTH_CONFIG_CODES:
            return "auth_config"
        if code in _TRANSIENT_CODES:
            return "transient"
        # bind_fail (socket OSError, e.g. EADDRNOTAVAIL on IP drift) carries no
        # A2AError code but is a bind-phase availability failure.
        if audit_event.get("event") == "bind_fail":
            return "transient"
        # A bind-phase failure we can't pin to a known code: treat as transient
        # ONLY because config+secret validation already passed to reach the
        # bind phase. (The code sets above catch the structural-config cases.)
        return "transient"

    # (2) no phase tag (older audit row / non-startup terminal event): fall
    #     back to the code alone.
    if code in _TRANSIENT_CODES:
        return "transient"
    if code in _AUTH_CONFIG_CODES:
        return "auth_config"
    # A bind_fail OSError row with no code, no phase.
    if audit_event.get("event") == "bind_fail":
        return "transient"

    # (3) supervisor reason fallback. A bare bind_unresolved reason (the
    # healthz/supervisor word) is a transient availability signal; everything
    # else (process_gone, healthz_timeout, healthz_status:*) is NOT a
    # bind-availability class and must not be auto-backed-off as transient.
    reason = (reason or "").strip()
    if reason == "bind_unresolved" or reason == "bind_proof_failed":
        # bind_proof_failed without a discriminating audit row is ambiguous:
        # it usually IS a transient tailnet/bind problem, but we only trust it
        # as transient when no auth/config audit row contradicted it. With no
        # audit event at all we cannot prove config validity, so stay
        # conservative: "unknown" (bounded restart, NOT the transient backoff
        # path, NOT an immediate hold). The audit-event path above is the
        # authoritative transient signal.
        if not audit_event:
            return "unknown"
        return "transient"
    return "unknown"


def _config_fingerprint(config_file):
    """Secret-free structural fingerprint of the A2A config.

    Hashes ONLY the bind identity (listen address/port/node_id/name) and the
    sorted peer ids — never any secret. Used as the circuit-breaker key
    component so a config edit (new identity / peer set) resets the breaker.
    Returns "" on any read/parse error (the supervisor then keys on
    error_class alone — still safe, just coarser).
    """
    if not config_file or not os.path.isfile(config_file):
        return ""
    try:
        with open(config_file, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return ""
    if not isinstance(cfg, dict):
        return ""
    listen = cfg.get("listen") if isinstance(cfg.get("listen"), dict) else {}
    ident = {
        "bridge_id": cfg.get("bridge_id"),
        "address": listen.get("address"),
        "port": listen.get("port"),
        "node_id": listen.get("node_id"),
        "tailscale_name": listen.get("tailscale_name"),
    }
    peer_ids = []
    peers = cfg.get("peers")
    if isinstance(peers, list):
        for p in peers:
            if isinstance(p, dict) and p.get("id") is not None:
                peer_ids.append(str(p.get("id")))
    ident["peers"] = sorted(peer_ids)
    blob = json.dumps(ident, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def _read_log_tail(log_file, tail_lines):
    """Last `tail_lines` lines of `log_file`, trailing whitespace stripped.

    Plain builtin open() (NOT pathlib) — read-only, controller-local. Tolerant
    of a missing/unreadable/binary log: returns [] rather than raising.
    """
    if not log_file or not os.path.isfile(log_file):
        return []
    try:
        with open(log_file, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return []
    tail = lines[-tail_lines:] if tail_lines > 0 else lines
    return [ln.rstrip() for ln in tail]


def _last_terminal_audit(jsonl_file):
    """Scan `jsonl_file` from the end for the most recent terminal event.

    Returns a whitelisted dict, or None when none is found / the file is
    missing/unreadable. Reads the whole file (the audit jsonl is small and
    rotated by the operator); parsing each line defensively so one malformed
    row cannot poison the scan.
    """
    if not jsonl_file or not os.path.isfile(jsonl_file):
        return None
    try:
        with open(jsonl_file, "r", encoding="utf-8", errors="replace") as fh:
            rows = fh.readlines()
    except OSError:
        return None
    for line in reversed(rows):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        if rec.get("event") in _TERMINAL_EVENTS:
            return {k: rec[k] for k in _AUDIT_FIELD_ALLOWLIST if k in rec}
    return None


def main(argv):
    if len(argv) < 7:
        # Misinvocation — still write nothing-but-fail so the caller's
        # `|| true` keeps the tick alive; print to stderr for the daemon log.
        sys.stderr.write(
            "a2a-receiver-exit-cause: usage: <out_json> <log_file> "
            "<jsonl_file> <reason> <last_pid> <detected_ts> [tail_lines] "
            "[config_file]\n")
        return 2

    out_json = argv[1]
    log_file = argv[2]
    jsonl_file = argv[3]
    reason = argv[4]
    last_pid = argv[5]
    detected_ts = argv[6]
    try:
        tail_lines = int(argv[7]) if len(argv) > 7 else 20
    except ValueError:
        tail_lines = 20
    config_file = argv[8] if len(argv) > 8 else ""

    try:
        detected_ts_val = int(detected_ts)
    except (ValueError, TypeError):
        detected_ts_val = detected_ts

    last_audit_event = _last_terminal_audit(jsonl_file)
    error_class = _classify_error_class(reason, last_audit_event)
    config_fingerprint = _config_fingerprint(config_file)

    record = {
        "detected_ts": detected_ts_val,
        "reason": reason,
        "last_pid": last_pid,
        "log_tail": _read_log_tail(log_file, tail_lines),
        "last_audit_event": last_audit_event,
        "error_class": error_class,
        "config_fingerprint": config_fingerprint,
    }

    payload = json.dumps(record, ensure_ascii=False, indent=2)
    try:
        # Mode 0600 — exit-cause record may carry log_tail; restrict to owner.
        # os.open with O_CREAT|O_WRONLY|O_TRUNC + 0o600 so the create mode is
        # applied atomically (a later os.chmod would race a reader).
        fd = os.open(out_json, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, payload.encode("utf-8"))
        finally:
            os.close(fd)
    except OSError as exc:
        sys.stderr.write(f"a2a-receiver-exit-cause: cannot write {out_json}: {exc}\n")
        return 1

    # Emit a one-line TSV summary of the mined terminal event + the supervision
    # class on stdout:
    #   <event>\t<detail-or-code (<=200 chars)>\t<error_class>\t<config_fingerprint>
    # so the bash supervisor can stamp the supervise.env summary + key its
    # backoff/circuit-breaker without a second python invocation (and without
    # an inline multi-line `python3 -c` in bridge-daemon.sh). Always one line.
    ev = record["last_audit_event"] or {}
    summary_event = ev.get("event") or ""
    summary_detail = str(ev.get("detail") or ev.get("code") or "")[:200]
    # Collapse any tab/newline in the detail so the single-line TSV contract
    # holds even on a pathological audit row.
    summary_detail = summary_detail.replace("\t", " ").replace("\n", " ")
    sys.stdout.write(
        f"{summary_event}\t{summary_detail}\t{error_class}\t{config_fingerprint}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
