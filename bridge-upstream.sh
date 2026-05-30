#!/usr/bin/env bash
# bridge-upstream.sh — draft and file upstream Agent Bridge issues with consent

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

UPSTREAM_REPO="${BRIDGE_UPSTREAM_REPO:-seanssoh/agent-bridge-public}"
UPSTREAM_CANDIDATE_DIR="${BRIDGE_UPSTREAM_CANDIDATE_DIR:-$BRIDGE_SHARED_DIR/upstream-candidates}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") draft --title <title> --symptom <text> --why <text> [--reproduction-file <path>] [--output <path>]
  $(basename "$0") propose --title <title> --body-file <path> [--repo owner/name] [--yes]
  $(basename "$0") review
EOF
}

slugify() {
  local value="$1"

  bridge_require_python
  python3 - "$value" <<'PY'
import re
import sys

value = sys.argv[1].lower()
value = re.sub(r"[^a-z0-9._-]+", "-", value).strip("-")
print(value[:64] or "upstream-issue")
PY
}

redact_file() {
  local path="$1"

  [[ -f "$path" ]] || return 0
  bridge_require_python
  python3 - "$path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = [
    (r"(?i)(token|secret|password|api[_-]?key|authorization)(\s*[:=]\s*)(\S+)", r"\1\2[REDACTED]"),
    (r"(?i)bearer\s+[a-z0-9._~+/=-]+", "Bearer [REDACTED]"),
]
for pattern, repl in patterns:
    text = re.sub(pattern, repl, text)
if len(text) > 12000:
    text = text[:12000] + "\n\n[truncated]\n"
print(text.rstrip())
PY
}

save_candidate() {
  local title="$1"
  local body_file="$2"
  local slug=""
  local path=""

  mkdir -p "$UPSTREAM_CANDIDATE_DIR"
  slug="$(slugify "$title")"
  path="$UPSTREAM_CANDIDATE_DIR/$(date '+%Y%m%d-%H%M%S')-${slug}.md"
  {
    printf '# %s\n\n' "$title"
    printf 'repo: %s\n' "$UPSTREAM_REPO"
    printf 'saved_at: %s\n\n' "$(bridge_now_iso)"
    cat "$body_file"
    printf '\n'
  } >"$path"
  printf '%s\n' "$path"
}

cmd_draft() {
  local title=""
  local symptom=""
  local why=""
  local reproduction_file=""
  local output=""
  local body=""
  local repro=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        title="${2:-}"
        shift 2
        ;;
      --symptom)
        symptom="${2:-}"
        shift 2
        ;;
      --why)
        why="${2:-}"
        shift 2
        ;;
      --reproduction-file)
        reproduction_file="${2:-}"
        shift 2
        ;;
      --output)
        output="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 upstream draft 옵션: $1"
        ;;
    esac
  done

  [[ -n "$title" ]] || bridge_die "--title is required"
  [[ -n "$symptom" ]] || bridge_die "--symptom is required"
  [[ -n "$why" ]] || bridge_die "--why is required"

  if [[ -n "$reproduction_file" ]]; then
    [[ -f "$reproduction_file" ]] || bridge_die "reproduction file not found: $reproduction_file"
    repro="$(redact_file "$reproduction_file")"
  else
    repro="(Add exact command, redacted output, and minimal reproduction steps.)"
  fi

  body="$(cat <<EOF
## Symptom

$symptom

## Why this looks upstream

$why

## Reproduction

\`\`\`text
$repro
\`\`\`

## Environment

- Agent Bridge version: $(bridge_version)
- Agent Bridge source: $BRIDGE_SCRIPT_DIR
- OS: $(uname -a)
- Shell: ${SHELL:-unknown}

## Consent

This draft must not be filed until the user explicitly approves.
EOF
)"

  if [[ -n "$output" ]]; then
    mkdir -p "$(dirname "$output")"
    printf '%s\n' "$body" >"$output"
    printf '%s\n' "$output"
  else
    printf '%s\n' "$body"
  fi
}

cmd_propose() {
  local title=""
  local body_file=""
  local repo="$UPSTREAM_REPO"
  local yes=0
  local answer=""
  local saved=""
  local url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        title="${2:-}"
        shift 2
        ;;
      --body-file)
        body_file="${2:-}"
        shift 2
        ;;
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --yes)
        yes=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 upstream propose 옵션: $1"
        ;;
    esac
  done

  [[ -n "$title" ]] || bridge_die "--title is required"
  [[ -n "$body_file" ]] || bridge_die "--body-file is required"
  [[ -f "$body_file" ]] || bridge_die "body file not found: $body_file"

  UPSTREAM_REPO="$repo"

  if [[ "$yes" != "1" ]]; then
    printf 'Agent Bridge 코어 이슈 후보입니다.\n'
    printf 'title: %s\n' "$title"
    printf 'repo: %s\n\n' "$repo"
    sed -n '1,80p' "$body_file"
    printf '\nAgent Bridge 코어 이슈로 보입니다. upstream GitHub issue를 바로 등록할까요? [y/N] '
    if [[ -t 0 ]]; then
      read -r answer
    else
      answer="n"
    fi
    case "$answer" in
      y|Y|yes|YES)
        yes=1
        ;;
      *)
        saved="$(save_candidate "$title" "$body_file")"
        printf 'saved_candidate: %s\n' "$saved"
        exit 0
        ;;
    esac
  fi

  command -v gh >/dev/null 2>&1 || bridge_die "gh CLI is required to file upstream issues"
  url="$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file")"
  printf '%s\n' "$url"
}

cmd_review() {
  local file=""

  mkdir -p "$UPSTREAM_CANDIDATE_DIR"
  shopt -s nullglob
  for file in "$UPSTREAM_CANDIDATE_DIR"/*.md; do
    printf '%s\n' "$file"
  done | sort
  shopt -u nullglob
}

case "${1:-}" in
  draft)
    shift
    cmd_draft "$@"
    ;;
  propose)
    shift
    cmd_propose "$@"
    ;;
  review)
    shift
    [[ $# -eq 0 ]] || bridge_die "Usage: $(basename "$0") review"
    cmd_review
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    bridge_die "지원하지 않는 upstream 명령입니다: $1"
    ;;
esac
