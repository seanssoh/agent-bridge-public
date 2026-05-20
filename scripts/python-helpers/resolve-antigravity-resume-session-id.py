#!/usr/bin/env python3
"""Resolve the Antigravity (`agy`) resume conversation id for a workdir.

Backs `lib/bridge-state.sh::bridge_resolve_resume_session_id` for the
`antigravity` engine (Track A1). Invoked file-as-argv, never via a Python
heredoc-stdin, for the footgun #11 deadlock reason documented in
`detect-antigravity-session-id.py`.

This is the single source of truth for whether an agy conversation id may
be fed to `agy --conversation <id>`. It is pure: callers pass everything
in and it neither reads nor writes bridge state.

Args (positional, order-sensitive):
    sys.argv[1] — workdir (the agent workdir; `os.path.realpath`-resolved)
    sys.argv[2] — candidate conversation id (may be empty)
    sys.argv[3] — max_age_hours (float string; default 48)
    sys.argv[4] — agent name (debug-only)
    sys.argv[5] — exclude_csv (comma-separated conversation ids to skip)
    sys.argv[6] — history_file (path to agy `history.jsonl`)
    sys.argv[7] — conversation_state_dir (path to agy `conversations/`)

Stdout: accepted conversation id, or empty when there is nothing safe to
    resume.
Exit code (mirrors the Claude resolver contract so the bash call sites'
`case "$_rc" in 0|2) ... *) clear` logic is reused unchanged):
    0 = candidate accepted as-is (or empty candidate resolved to the
        freshest eligible conversation)
    1 = no eligible (in-window) conversation — caller MUST launch fresh,
        NOT `agy --conversation`. This is the STALE-ID REJECTION path: a
        candidate older than max_age_hours yields empty stdout + rc=1 so
        the agent starts a fresh conversation instead of false-resuming a
        dead one.
    2 = candidate ineligible/stale but a fresher in-window conversation
        exists for the same workdir; that fresher id is on stdout.

Two distinct time signals — kept deliberately separate:

  * STALENESS GATE: a conversation is "in-window" when its *freshness*
    timestamp — MAX of the history `timestamp` (epoch ms, seconds-normalized)
    and the `<id>.pb` state-file mtime — is within max_age_hours. Taking the
    max is conservative: a conversation whose `.pb` was touched recently
    (still being used) is NOT rejected just because its history row is old.

  * RANKING: among in-window conversations, the freshest is chosen by the
    history `timestamp` — the SAME ordering the detector
    (detect-antigravity-session-id.py) uses, so detector and resolver agree
    on "which is newest". The `.pb` mtime is a tie-break only. Ranking on
    `.pb` mtime directly would diverge from the detector, since `.pb` files
    written in the same wall-clock second sort unpredictably.
"""

import json
import os
import sys
import time


def history_ts_seconds(raw) -> float:
    try:
        value = float(raw or "0")
    except (TypeError, ValueError):
        return 0.0
    # agy history timestamps are epoch ms.
    if value > 10**11:
        value /= 1000.0
    return value


def collect_conversations(history_file, conversation_state_dir, workdir, exclude):
    """Return {conversation_id: (freshness, hist_ts)} for the workdir.

    `freshness` = max(history timestamp, `<id>.pb` mtime) — drives the
    in-window staleness gate. `hist_ts` = the raw history timestamp —
    drives ranking (matches the detector's pure-timestamp ordering).

    Only conversations whose `<id>.pb` still exists are included; a history
    row whose state file was pruned is not resumable.
    """
    result = {}
    try:
        with open(history_file, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return result

    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        cid = obj.get("conversationId")
        if not cid or cid in exclude:
            continue
        ws = obj.get("workspace")
        if not ws or os.path.realpath(str(ws)) != workdir:
            continue
        pb_path = os.path.join(conversation_state_dir, f"{cid}.pb")
        try:
            pb_mtime = os.path.getmtime(pb_path)
        except OSError:
            # state file gone -> not resumable.
            continue
        hist_ts = history_ts_seconds(obj.get("timestamp"))
        freshness = max(hist_ts, pb_mtime)
        # A workdir can have multiple history rows for the same id; keep
        # the one with the newest history timestamp (and its freshness).
        if cid not in result or hist_ts > result[cid][1]:
            result[cid] = (freshness, hist_ts)
    return result


def main() -> int:
    workdir = os.path.realpath(sys.argv[1])
    candidate = (sys.argv[2] if len(sys.argv) > 2 else "") or ""
    try:
        max_age_hours = float(sys.argv[3] if len(sys.argv) > 3 else "48")
    except ValueError:
        max_age_hours = 48.0
    agent = (sys.argv[4] if len(sys.argv) > 4 else "") or ""
    exclude = {
        x for x in (sys.argv[5] if len(sys.argv) > 5 else "").split(",") if x
    }
    history_file = sys.argv[6] if len(sys.argv) > 6 else ""
    conversation_state_dir = sys.argv[7] if len(sys.argv) > 7 else ""

    cutoff = time.time() - max_age_hours * 3600

    conversations = collect_conversations(
        history_file, conversation_state_dir, workdir, exclude
    )
    # In-window gate uses `freshness` (tuple[0] = max(hist_ts, pb_mtime)).
    eligible = {
        cid: rank
        for cid, rank in conversations.items()
        if rank[0] >= cutoff
    }

    if not eligible:
        # STALE-ID REJECTION: candidate (if any) is older than the
        # max-age window, or there is simply no conversation for this
        # workdir. Either way -> launch fresh, never false-resume.
        sys.stderr.write(
            f"[debug] agy resume id rejected: no conversation within "
            f"{max_age_hours}h for workdir={workdir} agent={agent} "
            f"candidate={candidate or '(none)'}\n"
        )
        print("", end="")
        return 1

    # Rank by history timestamp (tuple[1]) — same ordering as the
    # detector — with freshness (tuple[0]) only as a tie-break.
    freshest = max(
        eligible, key=lambda c: (eligible[c][1], eligible[c][0])
    )

    # A candidate explicitly excluded (quarantined) must not be accepted
    # even if in-window — resolve to the freshest non-excluded id (rc=2).
    if candidate and candidate in exclude:
        sys.stderr.write(
            f"[debug] agy resume id quarantined: candidate={candidate} "
            f"freshest={freshest} workdir={workdir} agent={agent}\n"
        )
        print(freshest, end="")
        return 2

    if candidate and candidate in eligible:
        # Candidate is itself in-window -> accept as-is.
        print(candidate, end="")
        return 0

    if candidate:
        # Candidate is stale (not in `eligible`) but the workdir has a
        # fresher conversation -> swap (rc=2).
        sys.stderr.write(
            f"[debug] agy resume id replaced: candidate={candidate} "
            f"freshest={freshest} workdir={workdir} agent={agent}\n"
        )
        print(freshest, end="")
        return 2

    # Empty candidate: freshest eligible is an acceptance, not a swap.
    print(freshest, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
