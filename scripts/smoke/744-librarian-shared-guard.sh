#!/usr/bin/env bash
# scripts/smoke/744-librarian-shared-guard.sh — Issue #744 (+ r2) smoke.
#
# An agent's `agents/<name>/memory/shared/` subtree is that agent's own
# domain-content sharing area, NOT the team operating-rules SSOT. Two routes
# in scripts/librarian-process-ingest.py previously classified such captures
# as kind=operating-rules — the `("/memory/shared/", "operating-rules")` entry
# in PATH_KIND_HINTS (fallback route) and ENTITY_KIND_PREFIXES["shared/"]
# (schema-v1 envelope route). bridge-knowledge's target_for_kind() appends
# every operating-rules promote into the SINGLE wiki/operating-rules.md file
# regardless of page/title, so agent domain notes silently polluted the SSOT.
#
# The fix removes the path hint and adds a hard guard at the top of
# process_one() that rejects any capture whose path contains `/memory/shared/`
# (reason=agent-memory-shared-ambiguous), covering BOTH routes. The r2 canary
# fix reclassifies `rejected`/`duplicate` as non-canary-halting so a
# memory/shared reject in the batch[0] canary slot does not wedge the whole
# daily-ingest batch.
#
# This smoke drives the REAL librarian-process-ingest.py over an isolated
# fixture with a fake bridge-knowledge that logs every invocation, so the
# assertions are non-vacuous (a guard/canary regression makes them RED).
#
# T1 (guard):   two memory/shared captures — fixture A (no envelope) and
#               fixture B (schema-v1 envelope with suggested_entities=
#               ["shared/..."]) — are BOTH rejected with
#               reason=agent-memory-shared-ambiguous and reach
#               bridge-knowledge ZERO times. A leading memory/projects capture
#               (positive control) still promotes as kind=project.
# T2 (canary):  a memory/shared capture in the batch[0] canary slot does NOT
#               halt the batch (rc=0, no canary-failed); it is still rejected,
#               and a trailing memory/projects capture is still promoted.

set -euo pipefail

SMOKE_NAME="744-librarian-shared-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

LIBRARIAN_PY="$SMOKE_REPO_ROOT/scripts/librarian-process-ingest.py"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

smoke_require_cmd "$PYTHON"
[[ -r "$LIBRARIAN_PY" ]] || smoke_fail "cannot read $LIBRARIAN_PY"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root

AGENT="smoke-claude"

# Fake bridge-knowledge: logs every invocation and prints a minimal promote
# payload. If the guard regresses, a memory/shared capture shows up here.
FAKE_BK="$SMOKE_TMP_ROOT/fake-bk.py"
cat >"$FAKE_BK" <<'PY'
#!/usr/bin/env python3
import json, os, sys
log = os.environ.get("FAKE_BK_LOG", "")
if log:
    with open(log, "a", encoding="utf-8") as f:
        f.write(" ".join(sys.argv) + "\n")
print(json.dumps({"relative_path": "projects/guard-smoke.md",
                  "related_pages": []}))
PY
chmod +x "$FAKE_BK"

# Run the real librarian over a task body; echoes the stdout path.
run_librarian() {
  local dir="$1" task_body="$2" bk_log="$3"
  FAKE_BK_LOG="$bk_log" "$PYTHON" "$LIBRARIAN_PY" \
    --task-body "$task_body" \
    --shared-root "$dir/shared" \
    --template-root "$dir" \
    --team-name "smoke" \
    --bridge-knowledge "$FAKE_BK" \
    --sleep 0 \
    >"$dir/out" 2>"$dir/err"
}

# ---------------------------------------------------------------------------
# T1 — guard: memory/shared captures rejected, zero promotes; positive control
#      (leading memory/projects) still promotes.
# ---------------------------------------------------------------------------
T1="$SMOKE_TMP_ROOT/t1"
T1_MS="$T1/agents/$AGENT/memory/shared"
T1_MP="$T1/agents/$AGENT/memory/projects"
mkdir -p "$T1/shared" "$T1_MS" "$T1_MP"

# Fixture A — no envelope (old PATH_KIND_HINTS route).
cat >"$T1_MS/formulation-lessons.md" <<'EOF'
# Formulation Lessons
ingredient profiles, comedogenic study notes, agent domain content
EOF
# Fixture B — schema-v1 envelope with a shared/ entity (ENTITY_KIND_PREFIXES).
cat >"$T1_MS/domain-playbook.json" <<EOF
{
  "schema_version": "1",
  "agent": "$AGENT",
  "suggested_entities": ["shared/domain-playbook"],
  "suggested_slug": "domain-playbook",
  "suggested_title": "domain playbook",
  "excerpt": "agent domain playbook that must not pollute operating-rules"
}
EOF
# Positive control — leads the batch (satisfies the canary) and must promote.
cat >"$T1_MP/guard-smoke.md" <<'EOF'
# Guard Smoke Project
legitimate project note that should still promote to kind=project
EOF

cat >"$T1/task-body.md" <<EOF
### Raw envelopes (3)
- $T1_MP/guard-smoke.md
- $T1_MS/formulation-lessons.md
- $T1_MS/domain-playbook.json
EOF

T1_BK_LOG="$T1/fake-bk.log"
: >"$T1_BK_LOG"
run_librarian "$T1" "$T1/task-body.md" "$T1_BK_LOG" \
  || smoke_fail "T1: librarian exited non-zero: $(tr '\n' ' ' <"$T1/err" | head -c 200)"

t1_out="$(cat "$T1/out")"
t1_rejects="$(grep -c '"reason": "agent-memory-shared-ambiguous"' "$T1/out" || true)"
smoke_assert_eq "$t1_rejects" "2" \
  "T1: expected 2 agent-memory-shared-ambiguous rejects (fixtures A+B); out: $t1_out"

t1_shared_bk="$(grep -c -e 'formulation-lessons' -e 'domain-playbook' "$T1_BK_LOG" || true)"
smoke_assert_eq "$t1_shared_bk" "0" \
  "T1: memory/shared capture reached bridge-knowledge (SSOT pollution); log: $(cat "$T1_BK_LOG")"

smoke_assert_contains "$t1_out" '"status": "ok"' \
  "T1: positive control (memory/projects) did not promote"
smoke_assert_contains "$t1_out" '"kind": "project"' \
  "T1: positive control promoted with the wrong kind (expected project)"
smoke_log "T1 PASS — memory/shared guarded off operating-rules, projects still promotes"

# ---------------------------------------------------------------------------
# T2 — canary regression: a memory/shared reject in the batch[0] canary slot
#      must NOT wedge the batch; a trailing legit capture still processes.
# ---------------------------------------------------------------------------
T2="$SMOKE_TMP_ROOT/t2"
T2_MS="$T2/agents/$AGENT/memory/shared"
T2_MP="$T2/agents/$AGENT/memory/projects"
mkdir -p "$T2/shared" "$T2_MS" "$T2_MP"

# batch[0] (canary slot) — memory/shared capture the guard rejects.
cat >"$T2_MS/domain-notes.md" <<'EOF'
# Domain Notes
agent domain content that must reject without halting the batch
EOF
# batch[1] — legit projects capture that must still process after the reject.
cat >"$T2_MP/canary-tail.md" <<'EOF'
# Canary Tail Project
legit project note that must promote even though batch[0] was rejected
EOF

cat >"$T2/task-body.md" <<EOF
### Raw envelopes (2)
- $T2_MS/domain-notes.md
- $T2_MP/canary-tail.md
EOF

T2_BK_LOG="$T2/fake-bk.log"
: >"$T2_BK_LOG"
# rc MUST be 0 — a wedge (halt on the canary reject) exits 1.
run_librarian "$T2" "$T2/task-body.md" "$T2_BK_LOG" \
  || smoke_fail "T2: batch halted on a memory/shared canary reject (daily-ingest wedge); out: $(cat "$T2/out") err: $(tr '\n' ' ' <"$T2/err" | head -c 200)"

t2_out="$(cat "$T2/out")"
smoke_assert_not_contains "$t2_out" '"status": "canary-failed"' \
  "T2: canary-failed emitted on a benign memory/shared reject"
smoke_assert_contains "$t2_out" '"reason": "agent-memory-shared-ambiguous"' \
  "T2: canary-slot memory/shared capture was not rejected by the guard"
smoke_assert_contains "$t2_out" '"kind": "project"' \
  "T2: trailing memory/projects capture was not processed after the canary reject (batch wedged)"

t2_tail_bk="$(grep -c 'canary-tail' "$T2_BK_LOG" || true)"
[[ "$t2_tail_bk" -ge 1 ]] || smoke_fail \
  "T2: trailing capture never reached bridge-knowledge — batch did not proceed past the canary; log: $(cat "$T2_BK_LOG")"
smoke_log "T2 PASS — memory/shared reject in canary slot does not wedge the batch"

smoke_log "ALL PASS"
