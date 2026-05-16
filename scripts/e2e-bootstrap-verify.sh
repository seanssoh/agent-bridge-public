#!/usr/bin/env bash
# e2e-bootstrap-verify.sh — assert a single agent is fully wired:
#   1. PreCompact hook installed
#   2. v2 hybrid index present and non-empty
#   3. All 5 patch-owned wiki-* crons are registered
#
# Exit 0 on full pass; exit 1 with a human-readable diagnostic on any failure.
# Used by stream-e for end-to-end verification.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

AGENT=""
while (( $# > 0 )); do
  case "$1" in
    --agent) AGENT="${2:-}"; shift ;;
    -h|--help)
      echo "usage: $(basename "$0") --agent <name>" >&2
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$AGENT" ]]; then
  echo "--agent required" >&2
  exit 2
fi

HOME_DIR="$(agent_home_for "$AGENT")"
if [[ -z "$HOME_DIR" ]]; then
  echo "FAIL: agent '$AGENT' not found in bridge roster" >&2
  exit 1
fi

settings="$HOME_DIR/.claude/settings.json"
db="$HOME_DIR/memory/index.sqlite"

fails=0

# --- 1. hook ---
if [[ ! -f "$settings" ]]; then
  echo "FAIL[hook]: settings.json missing at $settings"
  fails=$((fails + 1))
else
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-hooks.py" status-pre-compact-hook \
        --workdir "$HOME_DIR" \
        --bridge-home "$BRIDGE_HOME" \
        --python-bin "$BRIDGE_PYTHON" \
        --settings-file "$settings" >/dev/null 2>&1; then
    echo "ok[hook]: PreCompact installed"
  else
    echo "FAIL[hook]: PreCompact NOT installed"
    fails=$((fails + 1))
  fi
fi

# --- 2. v2 index ---
if [[ ! -f "$db" ]]; then
  echo "FAIL[index]: $db missing"
  fails=$((fails + 1))
else
  res=$("$BRIDGE_PYTHON" - "$db" <<'PY'
import sqlite3, sys
db = sys.argv[1]
try:
    con = sqlite3.connect(db)
    cur = con.cursor()
    cur.execute("SELECT value FROM meta WHERE key='index_kind'")
    r = cur.fetchone()
    kind = r[0] if r else ""
    cur.execute("SELECT COUNT(*) FROM chunks")
    chunks = cur.fetchone()[0]
    con.close()
except Exception as e:
    print(f"err:{e}")
    sys.exit(0)
print(f"{kind}:{chunks}")
PY
)
  case "$res" in
    bridge-wiki-hybrid-v2:*)
      chunks=${res##*:}
      if [[ "$chunks" -gt 0 ]]; then
        echo "ok[index]: v2 index with $chunks chunks"
      else
        echo "FAIL[index]: v2 index but 0 chunks"
        fails=$((fails + 1))
      fi
      ;;
    *)
      echo "FAIL[index]: wrong kind or missing ($res)"
      fails=$((fails + 1))
      ;;
  esac
fi

# --- 3. crons ---
required_crons=(
  wiki-weekly-summarize
  wiki-monthly-summarize
  wiki-repair-links
  wiki-v2-rebuild
  wiki-dedup-weekly
)

cron_list_json="$(mktemp "${TMPDIR:-/tmp}/e2e-crons.json.XXXXXX")"
trap 'rm -f "$cron_list_json"' EXIT
"$BRIDGE_AGB" cron list --agent patch --json >"$cron_list_json" 2>/dev/null || echo '[]' > "$cron_list_json"

for title in "${required_crons[@]}"; do
  if "$BRIDGE_PYTHON" - "$cron_list_json" "$title" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
title = sys.argv[2]
for j in data if isinstance(data, list) else []:
    if isinstance(j, dict) and j.get("title") == title:
        sys.exit(0)
sys.exit(1)
PY
  then
    echo "ok[cron]: $title registered"
  else
    echo "FAIL[cron]: $title not registered"
    fails=$((fails + 1))
  fi
done

if (( fails > 0 )); then
  echo ""
  echo "SUMMARY: $fails failures for agent=$AGENT"
  exit 1
fi
echo ""
echo "SUMMARY: all checks passed for agent=$AGENT"
exit 0
