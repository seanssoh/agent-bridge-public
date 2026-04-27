#!/usr/bin/env bash
# tests/upgrade-conflicts/smoke.sh — `agb upgrade conflicts list` PR-1 smoke.
#
# Verifies the read-only enumeration introduced in #394 PR-1:
# - finds *.upgrade-conflict files under a target dir
# - excludes anything under backups/
# - both plain text and --json output shapes are sane
# - empty target produces 0 rows / count 0
#
# Runs with an isolated target dir under TMPDIR. No live state touched.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[upgrade-conflicts] %s\n' "$*"; }
ok()   { printf '[upgrade-conflicts] ok: %s\n' "$*"; }
die()  { printf '[upgrade-conflicts][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[upgrade-conflicts][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 missing"
fi

AB="$REPO_ROOT/agent-bridge"
[[ -x "$AB" ]] || die "agent-bridge missing or not executable at $AB"

TMP_ROOT="$(mktemp -d -t agb-upgrade-conflicts.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

POPULATED="$TMP_ROOT/populated"
EMPTY="$TMP_ROOT/empty"
mkdir -p "$POPULATED/agents/foo" \
         "$POPULATED/scripts" \
         "$POPULATED/backups/upgrade-old" \
         "$EMPTY"

# Two live conflicts that should be reported.
echo "<<<< live a" >"$POPULATED/agents/foo/CLAUDE.md.upgrade-conflict"
echo "<<<< live b" >"$POPULATED/scripts/smoke-test.sh.upgrade-conflict"

# One archived conflict under backups/ that must NOT be reported.
echo "<<<< archived" >"$POPULATED/backups/upgrade-old/stale.md.upgrade-conflict"

# 1. Plain text output: expect both live paths, no backups path.
log "case 1: plain text on populated target"
PLAIN_OUT="$("$AB" upgrade conflicts list --target "$POPULATED" 2>/dev/null || true)"
PLAIN_ERR="$("$AB" upgrade conflicts list --target "$POPULATED" 2>&1 >/dev/null || true)"

case "$PLAIN_OUT" in
  *"agents/foo/CLAUDE.md.upgrade-conflict"*) ok "agents/foo conflict listed" ;;
  *) die "agents/foo conflict missing from plain output: $PLAIN_OUT" ;;
esac
case "$PLAIN_OUT" in
  *"scripts/smoke-test.sh.upgrade-conflict"*) ok "scripts conflict listed" ;;
  *) die "scripts conflict missing from plain output: $PLAIN_OUT" ;;
esac
case "$PLAIN_OUT" in
  *"backups/upgrade-old/stale.md.upgrade-conflict"*) die "backups/ conflict leaked into output" ;;
  *) ok "backups/ excluded from plain output" ;;
esac
case "$PLAIN_ERR" in
  *"total: 2 conflict file(s)"*) ok "total count on stderr matches" ;;
  *) die "expected 'total: 2 conflict file(s)' on stderr, got: $PLAIN_ERR" ;;
esac

# 2. JSON output: expect count == 2, only live paths in conflicts[].
log "case 2: --json on populated target"
JSON_OUT="$("$AB" upgrade conflicts list --target "$POPULATED" --json 2>/dev/null || true)"
[[ -n "$JSON_OUT" ]] || die "expected non-empty JSON output"

python3 - "$JSON_OUT" "$POPULATED" <<'PY' || die "JSON validation failed"
import json
import sys

payload = json.loads(sys.argv[1])
target = sys.argv[2]
count = payload.get("count")
conflicts = payload.get("conflicts", [])
if count != 2 or len(conflicts) != 2:
    print(f"[upgrade-conflicts][error] expected count=2 with 2 entries, got count={count} entries={len(conflicts)}", file=sys.stderr)
    raise SystemExit(1)
paths = {c["path"] for c in conflicts}
expected = {
    f"{target}/agents/foo/CLAUDE.md.upgrade-conflict",
    f"{target}/scripts/smoke-test.sh.upgrade-conflict",
}
if paths != expected:
    print(f"[upgrade-conflicts][error] path set mismatch: got={paths} want={expected}", file=sys.stderr)
    raise SystemExit(1)
for c in conflicts:
    if not isinstance(c.get("size"), int) or c["size"] <= 0:
        print(f"[upgrade-conflicts][error] bad size on {c}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(c.get("mtime"), (int, float)):
        print(f"[upgrade-conflicts][error] bad mtime on {c}", file=sys.stderr)
        raise SystemExit(1)
print("[upgrade-conflicts] ok: JSON shape and counts correct")
PY

# 3. Empty target: expect 0 rows + count 0.
log "case 3: empty target"
EMPTY_PLAIN_ERR="$("$AB" upgrade conflicts list --target "$EMPTY" 2>&1 >/dev/null || true)"
case "$EMPTY_PLAIN_ERR" in
  *"total: 0 conflict file(s)"*) ok "empty target reports 0 on stderr" ;;
  *) die "expected 'total: 0 conflict file(s)', got: $EMPTY_PLAIN_ERR" ;;
esac

EMPTY_JSON="$("$AB" upgrade conflicts list --target "$EMPTY" --json 2>/dev/null || true)"
python3 - "$EMPTY_JSON" <<'PY' || die "empty JSON validation failed"
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("count") != 0 or payload.get("conflicts") != []:
    print(f"[upgrade-conflicts][error] expected empty payload, got: {payload}", file=sys.stderr)
    raise SystemExit(1)
print("[upgrade-conflicts] ok: empty target JSON shape correct")
PY

# 4. Missing target dir: expect non-zero exit.
log "case 4: missing target dir"
if "$AB" upgrade conflicts list --target "$TMP_ROOT/does-not-exist" >/dev/null 2>&1; then
  die "expected non-zero exit on missing target"
fi
ok "missing target produces non-zero exit"

# 5. Unknown subcommand under conflicts: expect non-zero exit.
log "case 5: unknown subcommand under conflicts"
if "$AB" upgrade conflicts diff /tmp/foo >/dev/null 2>&1; then
  die "expected non-zero exit for 'conflicts diff' (PR-2 not yet shipped)"
fi
ok "unknown 'conflicts diff' rejected"

log "all cases passed"
