#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
local_patterns_file="${OSS_PREFLIGHT_PATTERNS_FILE:-$repo_root/.oss-preflight-patterns}"

fail=0
tracked_file_list="$(mktemp)"
trap 'rm -f "$tracked_file_list"' EXIT
git ls-files > "$tracked_file_list"
tracked_files=()
while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  tracked_files+=("$path")
done < "$tracked_file_list"
scan_files=()
for path in "${tracked_files[@]}"; do
  [[ "$path" == "scripts/oss-preflight.sh" ]] && continue
  scan_files+=("$path")
done

check_pattern() {
  local description="$1"
  local pattern="$2"
  local matches

  matches="$(rg -n --color never -e "$pattern" "${scan_files[@]}" || true)"
  if [[ -n "$matches" ]]; then
    echo "[oss] fail: ${description}"
    echo "$matches"
    fail=1
  fi
}

check_email_patterns() {
  local matches

  matches="$(rg -n --color never -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${scan_files[@]}" || true)"
  # Public plugin manifests may use non-routable placeholder contacts.
  matches="$(printf '%s\n' "$matches" | grep -Ev '@(agent-bridge\.local|example\.com|example\.test|local\.invalid|tenant\.com)([^A-Za-z0-9.-]|$)|@odata\.(bind|id|type)' || true)"
  if [[ -n "$matches" ]]; then
    echo "[oss] fail: email addresses in tracked content"
    echo "$matches"
    fail=1
  fi
}

echo "[oss] checking tracked agent profiles"
extra_profiles=""
for path in "${tracked_files[@]}"; do
  if [[ "$path" =~ ^agents/[^_/][^/]*/CLAUDE\.md$ ]]; then
    extra_profiles+="${path}"$'\n'
  fi
done
if [[ -n "$extra_profiles" ]]; then
  echo "[oss] fail: public repo should not ship private agent profiles"
  printf '%s' "$extra_profiles"
  fail=1
fi

check_email_patterns
check_pattern "discord webhook URLs in tracked content" 'discord\.com/api/webhooks/'
check_pattern "discord mention IDs in tracked content" '<@[0-9]{6,}>'

echo "[oss] checking Agent Bridge marketplace declarations"
if ! python3 - "$repo_root" <<'PY'
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
marketplace_path = repo / ".claude-plugin" / "marketplace.json"
try:
    marketplace = json.loads(marketplace_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"[oss] fail: cannot parse {marketplace_path.relative_to(repo)}: {exc}")
    raise SystemExit(1)

declared = {
    plugin.get("name")
    for plugin in marketplace.get("plugins", [])
    if isinstance(plugin, dict) and isinstance(plugin.get("name"), str)
}

missing = []
for plugin_json in sorted((repo / "plugins").glob("*/.claude-plugin/plugin.json")):
    try:
        payload = json.loads(plugin_json.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[oss] fail: cannot parse {plugin_json.relative_to(repo)}: {exc}")
        raise SystemExit(1)
    name = payload.get("name")
    if not isinstance(name, str) or not name:
        print(f"[oss] fail: {plugin_json.relative_to(repo)} missing non-empty name")
        raise SystemExit(1)
    if name not in declared:
        missing.append(name)

if missing:
    print("[oss] fail: shipped plugins missing from .claude-plugin/marketplace.json: " + ", ".join(missing))
    raise SystemExit(1)
PY
then
  fail=1
fi

if [[ -f "$local_patterns_file" ]]; then
  while IFS= read -r pattern; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -n "$pattern" ]] || continue
    [[ "$pattern" == \#* ]] && continue
    check_pattern "local sensitive pattern: $pattern" "$pattern"
  done < "$local_patterns_file"
fi

if (( fail != 0 )); then
  exit 1
fi

# Heredoc-ban ratchet for bridge-upgrade.sh (footgun #11 carry-over).
# See scripts/lint-heredoc-ban.sh for policy.
if [[ -x "$repo_root/scripts/lint-heredoc-ban.sh" ]]; then
  if ! "$repo_root/scripts/lint-heredoc-ban.sh"; then
    echo "[oss] heredoc-ban ratchet failed — see scripts/lint-heredoc-ban.sh policy"
    exit 1
  fi
fi

# beta23 Option A — controller->isolated boundary ratchet. Enforces
# that no new raw boundary callsite is added beyond
# scripts/baselines/iso-helper-baseline.txt. See
# scripts/iso-helper-ratchet.sh for policy.
if [[ -x "$repo_root/scripts/iso-helper-ratchet.sh" ]]; then
  if ! "$repo_root/scripts/iso-helper-ratchet.sh"; then
    echo "[oss] iso-helper boundary ratchet failed — see scripts/iso-helper-ratchet.sh policy"
    exit 1
  fi
fi

# Beta20 L2 Variant 3A — release-side ratchet for the daemon-refresh
# sudoers template + helper module. The runtime preflight row
# (daemon_group_refresh_sudoers=ok|missing|invalid|sudo-refresh-no-gid)
# is emitted by `agent-bridge init sudoers daemon-refresh --check`; this
# release check just makes sure the source tree carries the template +
# helper so a fresh install can render+install the sudoers drop-in.
if [[ ! -f "$repo_root/scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template" ]]; then
  echo "[oss] fail: missing scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template (L2 Variant 3A)"
  exit 1
fi
if [[ ! -f "$repo_root/lib/bridge-daemon-control.sh" ]]; then
  echo "[oss] fail: missing lib/bridge-daemon-control.sh (L2 Variant 3A)"
  exit 1
fi
# Belt-and-suspenders: the template must contain the three substitution
# placeholders so an upstream edit that drops one fails the release gate
# rather than landing a sudoers entry with a literal `{{...}}` in it.
for _placeholder in '{{controller_user}}' '{{bash_abs}}' '{{bridge_home_abs}}'; do
  if ! grep -qF -- "$_placeholder" "$repo_root/scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template"; then
    echo "[oss] fail: sudoers template missing placeholder ${_placeholder}"
    exit 1
  fi
done

echo "[oss] preflight passed"
