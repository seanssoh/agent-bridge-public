#!/usr/bin/env python3
"""mcp-miss-queue-drain-parse.py — parse the per-agent miss-queue jsonl
into a TSV of drain candidates AND rewrite the source file with the
un-drained tail.

Invocation contract:
    sys.argv[1] = path         (absolute path to the per-agent jsonl)
    sys.argv[2] = cap          (max rows to drain this tick, integer string)
    sys.argv[3] = drained_path (absolute path to TSV output file)

Output:
    On stdout: nothing.
    On disk (drained_path): TSV with one row per drained miss-log entry,
        sorted oldest-first:
            ts<TAB>title_b64<TAB>body_b64<TAB>priority<TAB>task_id<TAB>dedup
        (title and body are base64-encoded so the bash side can read with
        `read -r` without IFS issues. Empty `task_id` is emitted as the
        sentinel `-` so adjacent IFS=$'\\t' separators do not collapse.)
    On disk (path): rewritten to the kept tail (rows beyond cap). When
        the file would be empty, the rewrite still happens — caller is
        responsible for the unlink step if desired.
    stderr: `malformed_line_skipped` per non-JSON line so the caller
        audits the skip.

Exit 0 on success (even when the input file does not exist — empty
drained_path is then a valid result). The caller treats any non-zero
exit as a parse failure and skips drain for the tick.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$file" "$cap" "$drained_tmp" <<'PY'` heredoc-stdin inside
bridge_daemon_mcp_miss_queue_drain. Same migration precedent as
mcp-miss-queue-enqueue.py.
"""

import base64
import json
import sys


def main() -> int:
    if len(sys.argv) < 4:
        return 1
    path, cap_str, drained_path = sys.argv[1:4]
    try:
        cap = int(cap_str)
    except ValueError:
        cap = 0
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    # Skip malformed line; print sentinel so caller audits.
                    sys.stderr.write("malformed_line_skipped\n")
                    continue
    except OSError:
        # No source file — write an empty drained TSV and return.
        try:
            with open(drained_path, "w", encoding="utf-8") as f:
                pass
        except OSError:
            return 1
        return 0
    # Sort oldest-first so we redeliver the OLDEST messages first.
    rows.sort(key=lambda r: int(r.get("ts", 0) or 0))
    to_drain = rows[:cap] if cap > 0 else []
    to_keep = rows[cap:] if cap > 0 else rows
    with open(drained_path, "w", encoding="utf-8") as f:
        for r in to_drain:
            title = r.get("title", "") or ""
            body = r.get("body", "") or ""
            priority = r.get("priority", "normal") or "normal"
            task_id = r.get("task_id", "") or ""
            dedup = r.get("dedup_key", "") or ""
            ts = int(r.get("ts", 0) or 0)
            title_b64 = base64.b64encode(title.encode("utf-8")).decode("ascii")
            body_b64 = base64.b64encode(body.encode("utf-8")).decode("ascii")
            # Use `-` sentinel for empty task_id so bash `read -r` cannot
            # collapse adjacent IFS=$'\t' separators (default behavior for
            # the rd_read primitive). Shell converts back to "" below.
            task_id_field = task_id if task_id else "-"
            f.write(f"{ts}\t{title_b64}\t{body_b64}\t{priority}\t{task_id_field}\t{dedup}\n")
    # Truncate the file to the kept tail so a parallel enqueue doesn't
    # race on a partially-drained file. The caller will re-append any
    # entries that fail re-delivery.
    with open(path, "w", encoding="utf-8") as f:
        for r in to_keep:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
