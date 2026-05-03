#!/usr/bin/env bash
# Pin the bridge-memory <-> librarian envelope contract end-to-end.
#
# Background: hooks/pre-compact.py emits a structured v1 envelope (with
# excerpt / suggested_entities / suggested_concepts) wrapped in a leading
# "schema_version=1 | excerpt=..." head line, and pipes it into
# `bridge-memory capture --text-file`. cmd_capture in bridge-memory.py
# detects the JSON block via _sniff_envelope() and stores it under the
# "envelope" field of the produced capture .json, while only promoting
# four metadata keys (schema_version, suggested_slug, suggested_title,
# session_type, trigger) to the root.
#
# scripts/librarian-process-ingest.py:load_envelope() is the consumer.
# It must therefore unwrap the nested envelope so that excerpt /
# suggested_entities / suggested_concepts (envelope-only fields) reach
# infer_kind / infer_title / infer_summary.
#
# This smoke pins three assertions:
#   1. After bridge-memory capture, load_envelope() returns the inner
#      envelope with all envelope-only fields intact.
#   2. Direct root-level v1 emitters (legacy shape 1a) still work.
#   3. Captures with schema_version != "1" at root and inside envelope
#      are rejected (returns None).

set -euo pipefail

SMOKE_NAME="pre-compact-envelope-roundtrip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

assert_wrapper_unwrap() {
  local fixture capture_dir capture_path agent_home
  agent_home="$BRIDGE_HOME/agents/testagent"
  capture_dir="$agent_home/raw/captures/inbox"

  fixture="$SMOKE_TMP_ROOT/fixture.txt"
  cat >"$fixture" <<'EOF'
schema_version=1 | excerpt=smoke roundtrip excerpt

{
  "schema_version": "1",
  "agent": "testagent",
  "captured_at": "2026-05-03T00:00:00+09:00",
  "session_type": "static-claude",
  "trigger": "manual",
  "source": "pre-compact-hook",
  "custom_instructions_excerpt": "",
  "suggested_entities": ["entity-a", "entity-b"],
  "suggested_concepts": ["concept-x"],
  "suggested_slug": "smoke-roundtrip",
  "suggested_title": "smoke roundtrip",
  "excerpt": "smoke roundtrip excerpt",
  "transcript_available": false
}
EOF

  python3 "$SMOKE_REPO_ROOT/bridge-memory.py" capture \
    --agent testagent \
    --user testuser \
    --home "$agent_home" \
    --template-root "$SMOKE_REPO_ROOT/agents/_template" \
    --source pre-compact-hook \
    --title "smoke roundtrip" \
    --text-file "$fixture" >/dev/null

  capture_path="$(find "$capture_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | head -n 1)"
  [[ -n "$capture_path" ]] || smoke_fail "bridge-memory did not produce a capture under $capture_dir"

  python3 - "$capture_path" "$SMOKE_REPO_ROOT" <<'PY'
import importlib.util
import json
import sys

capture_path, repo_root = sys.argv[1], sys.argv[2]

with open(capture_path, "r", encoding="utf-8") as fh:
    wrapper = json.load(fh)

assert wrapper.get("text"), f"capture .json missing non-empty 'text': {wrapper.keys()}"
inner_in_wrapper = wrapper.get("envelope") or {}
assert inner_in_wrapper.get("schema_version") == "1", (
    f"capture wrapper envelope.schema_version != '1': {inner_in_wrapper.get('schema_version')!r}"
)

spec = importlib.util.spec_from_file_location(
    "librarian_process_ingest",
    f"{repo_root}/scripts/librarian-process-ingest.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

from pathlib import Path
env = module.load_envelope(Path(capture_path))
assert env is not None, "load_envelope returned None on bridge-memory wrapper capture"
assert env.get("schema_version") == "1", f"unwrapped schema_version != '1': {env!r}"
assert env.get("excerpt") == "smoke roundtrip excerpt", (
    f"excerpt not surfaced after unwrap: {env.get('excerpt')!r}"
)
assert env.get("suggested_entities") == ["entity-a", "entity-b"], (
    f"suggested_entities not surfaced: {env.get('suggested_entities')!r}"
)
assert env.get("suggested_concepts") == ["concept-x"], (
    f"suggested_concepts not surfaced: {env.get('suggested_concepts')!r}"
)
print("ok")
PY
}

assert_root_level_v1_still_works() {
  local raw_path
  raw_path="$SMOKE_TMP_ROOT/raw-direct.json"
  cat >"$raw_path" <<'EOF'
{
  "schema_version": "1",
  "agent": "testagent",
  "captured_at": "2026-05-03T00:00:00+09:00",
  "session_type": "static-claude",
  "trigger": "manual",
  "source": "direct",
  "suggested_entities": ["root-only-entity"],
  "suggested_concepts": ["root-only-concept"],
  "suggested_slug": "root-only",
  "suggested_title": "root only",
  "excerpt": "root level excerpt"
}
EOF

  python3 - "$raw_path" "$SMOKE_REPO_ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

raw_path, repo_root = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location(
    "librarian_process_ingest",
    f"{repo_root}/scripts/librarian-process-ingest.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

env = module.load_envelope(Path(raw_path))
assert env is not None, "load_envelope returned None on root-level v1 envelope"
assert env.get("schema_version") == "1", f"root-level envelope schema_version: {env.get('schema_version')!r}"
assert env.get("excerpt") == "root level excerpt", f"root-level excerpt: {env.get('excerpt')!r}"
assert env.get("suggested_entities") == ["root-only-entity"], (
    f"root-level suggested_entities: {env.get('suggested_entities')!r}"
)
print("ok")
PY
}

assert_non_v1_rejected() {
  local bad_path
  bad_path="$SMOKE_TMP_ROOT/non-v1.json"
  cat >"$bad_path" <<'EOF'
{
  "schema_version": "0",
  "agent": "testagent",
  "envelope": {
    "schema_version": "0",
    "excerpt": "should be rejected"
  }
}
EOF

  python3 - "$bad_path" "$SMOKE_REPO_ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

bad_path, repo_root = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location(
    "librarian_process_ingest",
    f"{repo_root}/scripts/librarian-process-ingest.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

env = module.load_envelope(Path(bad_path))
assert env is None, f"load_envelope should reject non-v1 schema, got: {env!r}"
print("ok")
PY
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "pre-compact-envelope-roundtrip"
  smoke_run "bridge-memory wrapper unwraps nested v1 envelope" assert_wrapper_unwrap
  smoke_run "root-level v1 envelope still loads (shape 1a)" assert_root_level_v1_still_works
  smoke_run "non-v1 schema is rejected" assert_non_v1_rejected
  smoke_log "passed"
}

main "$@"
