#!/usr/bin/env python3
"""a2a-receiver-exit-cause.py — assemble an A2A receiver exit-cause record.

Invoked by ``process_a2a_receiver_supervise_tick`` in bridge-daemon.sh when
the supervisor detects a dead/wedged receiver (#1405). It mines the two
artifacts the receiver itself leaves behind and writes a single secret-free
JSON object to an output file so the supervisor (and ``agent-bridge status``)
can show WHY the receiver went down instead of the silent black-hole the
issue reported.

Invocation contract (ALL paths passed as argv — footgun #11: NO heredoc-stdin
/ here-string to a captured subprocess; mirror process_a2a_outbox_stuck_scan_tick
at bridge-daemon.sh which writes JSON to a tmp file and reads it back):

    a2a-receiver-exit-cause.py \
        <out_json> <log_file> <jsonl_file> <reason> <last_pid> <detected_ts> \
        [tail_lines]

  out_json     : path to write the exit-cause JSON object to (mode 0600).
  log_file     : logs/a2a-handoffd.log — the receiver's stdout/stderr log.
  jsonl_file   : logs/a2a-handoff.jsonl — the receiver's structured audit log.
  reason       : the supervisor's own classification (process_gone /
                 healthz_timeout / healthz_status:<code> / bind_proof_failed).
  last_pid     : the pid the supervisor last knew the receiver by ("" if none).
  detected_ts  : unix ts the supervisor detected the death.
  tail_lines   : how many trailing log lines to capture (default 20).

Output JSON fields:
  detected_ts, reason, last_pid,
  log_tail        : last <tail_lines> lines of log_file (each already
                    secret-free — the receiver's audit() never logs secrets
                    or bodies), trailing whitespace stripped.
  last_audit_event: the LAST terminal audit event mined from jsonl_file
                    (bind_fail / startup_fail / stopped), as a dict with its
                    event + code/detail/address/port when present; null if no
                    terminal event is found. The jsonl carries the
                    authoritative cause (bridge-handoffd.py audit()).

The helper is read-only over the audit log and the daemon log; it never
touches the live receiver, its socket, or its config. It always exits 0 and
writes at least a minimal record so the supervisor has something to stamp
even when both artifacts are missing/unreadable.
"""

import json
import os
import sys

# Terminal audit events the receiver emits right before/at exit. We scan the
# jsonl from the end and surface the most recent one as the authoritative
# cause. `listening` is intentionally NOT terminal — it marks a (re)start.
_TERMINAL_EVENTS = ("bind_fail", "startup_fail", "stopped")
# Only these fields are carried out of the matched audit record. Whitelisted
# (not passthrough) so a future audit field carrying sensitive data can never
# leak into the exit-cause record by accident.
_AUDIT_FIELD_ALLOWLIST = ("event", "ts", "code", "detail", "address", "port")


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
            "<jsonl_file> <reason> <last_pid> <detected_ts> [tail_lines]\n")
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

    try:
        detected_ts_val = int(detected_ts)
    except (ValueError, TypeError):
        detected_ts_val = detected_ts

    record = {
        "detected_ts": detected_ts_val,
        "reason": reason,
        "last_pid": last_pid,
        "log_tail": _read_log_tail(log_file, tail_lines),
        "last_audit_event": _last_terminal_audit(jsonl_file),
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

    # Emit a one-line TSV summary of the mined terminal event on stdout:
    #   <event>\t<detail-or-code (<=200 chars)>
    # so the bash supervisor can stamp the supervise.env summary fields
    # without a second python invocation (and without an inline multi-line
    # `python3 -c` in bridge-daemon.sh). Always one line, empty fields ok.
    ev = record["last_audit_event"] or {}
    summary_event = ev.get("event") or ""
    summary_detail = str(ev.get("detail") or ev.get("code") or "")[:200]
    # Collapse any tab/newline in the detail so the single-line TSV contract
    # holds even on a pathological audit row.
    summary_detail = summary_detail.replace("\t", " ").replace("\n", " ")
    sys.stdout.write(f"{summary_event}\t{summary_detail}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
