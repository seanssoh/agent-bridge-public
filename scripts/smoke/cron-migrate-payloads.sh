#!/usr/bin/env bash
# scripts/smoke/cron-migrate-payloads.sh — Issue #541 PR-A smoke.
#
# Validates `agb cron migrate-payloads --jsonl-aware`:
#   1. --dry-run on a mixed fixture reports migrated=2, unchanged=1,
#      skipped_non_memory_daily=1 and does NOT mutate the file.
#   2. apply pass writes a jobs.json.bak-<timestamp> backup (matching the
#      cleanup-prune naming convention), rewrites the two stale memory-daily
#      payloads to a body that passes the jsonl-aware predicate, and leaves
#      the non-memory-daily job byte-identical.
#   3. re-running --dry-run after the apply pass reports migrated=0,
#      unchanged=3 (idempotency).
#   4. `agb cron create --title memory-daily-<agent> --agent <agent>` with
#      no explicit --payload defaults to the canonical jsonl-aware body
#      (acceptance criterion 2 of the issue).
#
# This smoke uses isolated fixtures under SMOKE_TMP_ROOT and never touches
# the operator's live runtime jobs.json.

set -euo pipefail

SMOKE_NAME="cron-migrate-payloads"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root
FIXTURE="$SMOKE_TMP_ROOT/jobs.json"

write_fixture() {
  cat >"$FIXTURE" <<'JSON'
{
  "format": "agent-bridge-cron-v1",
  "updatedAt": "2026-05-04T00:00:00+00:00",
  "jobs": [
    {
      "id": "memory-daily-already-aware-aaaaaaaa",
      "name": "memory-daily-already",
      "agentId": "already",
      "enabled": true,
      "schedule": {"kind": "cron", "expr": "0 3 * * *", "tz": "Asia/Seoul"},
      "payload": {
        "kind": "text",
        "text": "bash \"$BRIDGE_HOME/scripts/memory-daily-harvest.sh\" --agent already\n# Reconciles jsonl via session_id and daily-note-reconcile.py before harvest."
      },
      "metadata": {"source": "fixture"}
    },
    {
      "id": "memory-daily-stale-one-bbbbbbbb",
      "name": "memory-daily-stale-one",
      "agentId": "stale-one",
      "enabled": true,
      "schedule": {"kind": "cron", "expr": "0 3 * * *", "tz": "Asia/Seoul"},
      "payload": {
        "kind": "text",
        "text": "bash \"$BRIDGE_HOME/scripts/memory-daily-harvest.sh\" --agent stale-one\n# Pre-#390 body: no jsonl/session_id/reconcile keywords."
      },
      "metadata": {"source": "fixture"}
    },
    {
      "id": "memory-daily-stale-two-cccccccc",
      "name": "memory-daily-stale-two",
      "agentId": "stale-two",
      "enabled": true,
      "schedule": {"kind": "cron", "expr": "0 3 * * *", "tz": "Asia/Seoul"},
      "payload": {
        "kind": "text",
        "text": "bash \"$BRIDGE_HOME/scripts/memory-daily-harvest.sh\" --agent stale-two\n# Authoritative RESULT_SCHEMA JSON; do not re-interpret actions_taken."
      },
      "metadata": {"source": "fixture"}
    },
    {
      "id": "morning-briefing-other-dddddddd",
      "name": "morning-briefing-other",
      "agentId": "other",
      "enabled": true,
      "schedule": {"kind": "cron", "expr": "30 8 * * *", "tz": "Asia/Seoul"},
      "payload": {
        "kind": "text",
        "text": "morning briefing — should be left alone by --jsonl-aware migration"
      },
      "metadata": {"source": "fixture"}
    }
  ]
}
JSON
}

# 1. Dry-run on a fresh fixture.
write_fixture
ORIGINAL_HASH="$("$PY_BIN" -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$FIXTURE")"

DRY_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-cron.py" migrate-payloads --jsonl-aware --dry-run --jobs-file "$FIXTURE" --json)"
"$PY_BIN" - "$DRY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["migrated"] == 2, payload
assert payload["unchanged"] == 1, payload
assert payload["skipped_non_memory_daily"] == 1, payload
assert payload["dry_run"] is True, payload
assert payload["backup_file"] is None, payload
PY

DRY_HASH="$("$PY_BIN" -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$FIXTURE")"
smoke_assert_eq "$ORIGINAL_HASH" "$DRY_HASH" "dry-run must not mutate fixture"
smoke_log "ok: dry-run counters correct, fixture unchanged"

# Capture the non-memory-daily job's bytes AFTER load+normalize so the
# byte-identity check below targets whether migrate-payloads itself
# mutates the job — independent of the on-load normalize_job_agent_fields
# pass shared by every jobs.json writer (cleanup-prune, rebalance, etc.).
NON_MD_BEFORE="$("$PY_BIN" - "$FIXTURE" "$REPO_ROOT" <<'PY'
import json, sys, importlib.util, os
fixture_path, repo_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("bridge_cron", os.path.join(repo_root, "bridge-cron.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
_, jobs = mod.load_jobs_payload(fixture_path)
for job in jobs:
    if job.get("name") == "morning-briefing-other":
        print(json.dumps(job, sort_keys=True, ensure_ascii=False))
        break
PY
)"

# 2. Apply pass.
APPLY_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-cron.py" migrate-payloads --jsonl-aware --jobs-file "$FIXTURE" --json)"
BACKUP_FILE="$("$PY_BIN" - "$APPLY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["migrated"] == 2, payload
assert payload["unchanged"] == 1, payload
assert payload["skipped_non_memory_daily"] == 1, payload
assert payload["dry_run"] is False, payload
assert payload["backup_file"], payload
print(payload["backup_file"])
PY
)"
smoke_assert_file_exists "$BACKUP_FILE" "backup file should exist after apply"

# Backup name must match cleanup-prune convention: jobs.json.bak-<timestamp>.
case "$(basename "$BACKUP_FILE")" in
  jobs.json.bak-*) ;;
  *) smoke_fail "backup file naming must mirror cleanup-prune (jobs.json.bak-<ts>); got $(basename "$BACKUP_FILE")" ;;
esac

# Backup must be byte-identical to the pre-apply fixture.
BACKUP_HASH="$("$PY_BIN" -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$BACKUP_FILE")"
smoke_assert_eq "$ORIGINAL_HASH" "$BACKUP_HASH" "backup file must equal pre-apply fixture bytes"

# All three memory-daily jobs must now pass the jsonl-aware predicate, and
# the non-memory-daily job must be byte-identical to its pre-apply form.
"$PY_BIN" - "$FIXTURE" "$REPO_ROOT" "$NON_MD_BEFORE" <<'PY'
import json, sys, importlib.util, os

fixture_path, repo_root, non_md_before_json = sys.argv[1], sys.argv[2], sys.argv[3]

spec = importlib.util.spec_from_file_location("bridge_cron", os.path.join(repo_root, "bridge-cron.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

data = json.load(open(fixture_path))
md_count = 0
non_md_after = None
for job in data["jobs"]:
    name = job.get("name", "")
    if name.startswith("memory-daily"):
        text = (job.get("payload") or {}).get("text") or ""
        assert mod.memory_daily_payload_is_jsonl_aware(text), f"job {name} payload not jsonl-aware after migration: {text!r}"
        md_count += 1
    elif name == "morning-briefing-other":
        non_md_after = json.dumps(job, sort_keys=True, ensure_ascii=False)

assert md_count == 3, f"expected 3 memory-daily jobs, got {md_count}"
assert non_md_after == non_md_before_json, "non-memory-daily job mutated by --jsonl-aware migration"
print("ok: 3/3 memory-daily payloads jsonl-aware; non-memory-daily byte-identical")
PY
smoke_log "ok: apply pass migrates payloads, backup written, non-memory-daily preserved"

# 3. Idempotency — second apply pass should report all unchanged.
IDEMPOTENT_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-cron.py" migrate-payloads --jsonl-aware --jobs-file "$FIXTURE" --json)"
"$PY_BIN" - "$IDEMPOTENT_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["migrated"] == 0, payload
assert payload["unchanged"] == 3, payload
assert payload["skipped_non_memory_daily"] == 1, payload
assert payload["backup_file"] is None, payload
PY
smoke_log "ok: idempotent re-run reports migrated=0 unchanged=3"

# 4. cron create --family memory-daily acceptance: no explicit --payload
#    must default to the canonical jsonl-aware body.
FRESH_JOBS="$SMOKE_TMP_ROOT/fresh-jobs.json"
"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-create \
  --jobs-file "$FRESH_JOBS" \
  --agent acceptance-agent \
  --schedule "0 3 * * *" \
  --tz "Asia/Seoul" \
  --title "memory-daily-acceptance-agent" >/dev/null

"$PY_BIN" - "$FRESH_JOBS" "$REPO_ROOT" <<'PY'
import json, sys, importlib.util, os
fresh_path, repo_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("bridge_cron", os.path.join(repo_root, "bridge-cron.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
data = json.load(open(fresh_path))
assert len(data["jobs"]) == 1, data
text = data["jobs"][0]["payload"]["text"]
assert mod.memory_daily_payload_is_jsonl_aware(text), f"fresh memory-daily create did not default to jsonl-aware body: {text!r}"
assert "acceptance-agent" in text, text
PY
smoke_log "ok: cron create --title memory-daily-* defaults to canonical jsonl-aware body"

smoke_log "smoke test passed"
