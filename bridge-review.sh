#!/usr/bin/env bash
# bridge-review.sh — queue-first cross-agent review gates

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") policy [--agent <agent>] [--family <name>] [--json]
  $(basename "$0") request --subject <text> [--reviewer <agent>] [--agent <agent>] [--family <name>] [--from <agent>] [--priority low|normal|high|urgent] [--body <text> | --body-file <path>] [--bypass <reason>]
  $(basename "$0") complete <task-id> --reviewer <agent> --decision approved|changes_requested|comment [--note <text> | --note-file <path>]

Policy:
  Defaults are read from \$BRIDGE_REVIEW_POLICY_FILE or \$BRIDGE_HOME/review-policy.json.
  Policy is optional; pass --reviewer for ad hoc reviews.
EOF
}

review_policy_file() {
  printf '%s' "${BRIDGE_REVIEW_POLICY_FILE:-$BRIDGE_HOME/review-policy.json}"
}

review_infer_actor_if_possible() {
  local actor="${1:-}"

  if [[ -n "$actor" ]]; then
    printf '%s' "$actor"
    return 0
  fi

  if actor="$(bridge_infer_current_agent 2>/dev/null)"; then
    printf '%s' "$actor"
    return 0
  fi

  printf '%s' "${USER:-unknown}"
}

review_policy_shell() {
  local agent="${1:-}"
  local family="${2:-general}"
  local policy_file=""

  policy_file="$(review_policy_file)"
  bridge_require_python
  python3 - "$policy_file" "$agent" "$family" "${BRIDGE_REVIEW_DEFAULT_REVIEWER:-}" <<'PY'
import json
import shlex
import sys
from pathlib import Path

policy_file, agent, family, env_reviewer = sys.argv[1:]
policy = {}
if policy_file and Path(policy_file).is_file():
    try:
        policy = json.loads(Path(policy_file).read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"invalid review policy file: {policy_file}: {exc}")

result = {
    "required": False,
    "reviewer": env_reviewer or "",
    "priority": "normal",
    "bypass": ["trivial", "docs-only", "test-only"],
}

def merge(src):
    if not isinstance(src, dict):
        return
    if "required" in src:
        result["required"] = bool(src["required"])
    if src.get("reviewer"):
        result["reviewer"] = str(src["reviewer"])
    if src.get("priority"):
        result["priority"] = str(src["priority"])
    if isinstance(src.get("bypass"), list):
        result["bypass"] = [str(item) for item in src["bypass"] if str(item).strip()]

merge(policy.get("defaults"))
merge((policy.get("families") or {}).get(family))
agent_policy = (policy.get("agents") or {}).get(agent) if agent else None
merge(agent_policy)
if isinstance(agent_policy, dict):
    merge((agent_policy.get("families") or {}).get(family))

allowed_priorities = {"low", "normal", "high", "urgent"}
if result["priority"] not in allowed_priorities:
    result["priority"] = "normal"

print(f"REVIEW_REQUIRED={1 if result['required'] else 0}")
print(f"REVIEW_REVIEWER={shlex.quote(result['reviewer'])}")
print(f"REVIEW_PRIORITY={shlex.quote(result['priority'])}")
print(f"REVIEW_BYPASS_REASONS={shlex.quote(','.join(result['bypass']))}")
PY
}

review_policy_json() {
  local agent="${1:-}"
  local family="${2:-general}"
  local REVIEW_REQUIRED=""
  local REVIEW_REVIEWER=""
  local REVIEW_PRIORITY=""
  local REVIEW_BYPASS_REASONS=""

  # shellcheck disable=SC1090
  source <(review_policy_shell "$agent" "$family")
  bridge_require_python
  python3 - "$agent" "$family" "$REVIEW_REQUIRED" "$REVIEW_REVIEWER" "$REVIEW_PRIORITY" "$REVIEW_BYPASS_REASONS" <<'PY'
import json
import sys

agent, family, required, reviewer, priority, bypass = sys.argv[1:]
payload = {
    "agent": agent or None,
    "family": family,
    "required": required == "1",
    "reviewer": reviewer or None,
    "priority": priority,
    "bypass": [item for item in bypass.split(",") if item],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

review_bypass_allowed() {
  local bypass="$1"
  local reasons_csv="$2"
  local item=""
  local -a items=()

  [[ -n "$bypass" ]] || return 1
  IFS=',' read -r -a items <<<"$reasons_csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    [[ "$item" == "$bypass" ]] && return 0
  done
  return 1
}

cmd_policy() {
  local agent=""
  local family="general"
  local json_mode=0
  local REVIEW_REQUIRED=""
  local REVIEW_REVIEWER=""
  local REVIEW_PRIORITY=""
  local REVIEW_BYPASS_REASONS=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        agent="$2"
        shift 2
        ;;
      --family)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        family="$2"
        shift 2
        ;;
      --json)
        json_mode=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 review policy 옵션입니다: $1"
        ;;
    esac
  done

  if [[ $json_mode -eq 1 ]]; then
    review_policy_json "$agent" "$family"
    return 0
  fi

  # shellcheck disable=SC1090
  source <(review_policy_shell "$agent" "$family")
  printf 'agent: %s\n' "${agent:--}"
  printf 'family: %s\n' "$family"
  printf 'required: %s\n' "$REVIEW_REQUIRED"
  printf 'reviewer: %s\n' "${REVIEW_REVIEWER:--}"
  printf 'priority: %s\n' "$REVIEW_PRIORITY"
  printf 'bypass: %s\n' "${REVIEW_BYPASS_REASONS:--}"
}

cmd_request() {
  local subject=""
  local reviewer=""
  local reviewed_agent=""
  local family="general"
  local actor=""
  local priority=""
  local body=""
  local body_file=""
  local bypass_reason=""
  local REVIEW_REQUIRED=""
  local REVIEW_REVIEWER=""
  local REVIEW_PRIORITY=""
  local REVIEW_BYPASS_REASONS=""
  local task_body_file=""
  local task_title=""
  local TASK_ID=""
  local TASK_ASSIGNED_TO=""
  local TASK_PRIORITY=""
  local TASK_TITLE=""
  local notice_message=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        subject="$2"
        shift 2
        ;;
      --reviewer|--to)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        reviewer="$2"
        shift 2
        ;;
      --agent)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        reviewed_agent="$2"
        shift 2
        ;;
      --family)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        family="$2"
        shift 2
        ;;
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        actor="$2"
        shift 2
        ;;
      --priority)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        priority="$2"
        shift 2
        ;;
      --body)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        body="$2"
        shift 2
        ;;
      --body-file)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        body_file="$2"
        shift 2
        ;;
      --bypass)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        bypass_reason="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 review request 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$subject" ]] || bridge_die "--subject는 필수입니다."
  actor="$(review_infer_actor_if_possible "$actor")"
  if [[ -n "$reviewed_agent" ]]; then
    bridge_require_agent "$reviewed_agent"
  fi

  # shellcheck disable=SC1090
  source <(review_policy_shell "$reviewed_agent" "$family")
  reviewer="${reviewer:-$REVIEW_REVIEWER}"
  priority="${priority:-$REVIEW_PRIORITY}"
  if review_bypass_allowed "$bypass_reason" "$REVIEW_BYPASS_REASONS"; then
    printf 'review_bypassed: yes\n'
    printf 'reason: %s\n' "$bypass_reason"
    printf 'subject: %s\n' "$subject"
    return 0
  fi

  [[ -n "$reviewer" ]] || bridge_die "reviewer가 필요합니다. --reviewer <agent>를 지정하거나 review policy를 설정하세요."
  bridge_require_agent "$reviewer"
  case "$priority" in
    low|normal|high|urgent) ;;
    *) bridge_die "지원하지 않는 priority 입니다: $priority" ;;
  esac

  mkdir -p "$BRIDGE_SHARED_DIR/reviews"
  # BSD-portable: macOS `mktemp` only expands trailing `X` sequences;
  # a `.XXXXXX.md` template returns the literal `XXXXXX.md` path. Use
  # suffix-less mktemp + rename so the `.md` cosmetic extension (for
  # operator editor highlighting in shared/reviews/) is preserved.
  # Task #4648 surfaced the parallel bug at bridge-agent.sh:1959.
  task_body_file_base="$(mktemp "$BRIDGE_SHARED_DIR/reviews/review-request.XXXXXX")"
  task_body_file="${task_body_file_base}.md"
  mv "$task_body_file_base" "$task_body_file" || { rm -f "$task_body_file_base"; bridge_die "review-request body rename failed"; }
  {
    echo "# Review Request"
    echo
    echo "- review_contract_version: 1"
    echo "- subject: $subject"
    echo "- requested_by: $actor"
    echo "- reviewer: $reviewer"
    echo "- reviewed_agent: ${reviewed_agent:--}"
    echo "- family: $family"
    echo "- required_by_policy: $REVIEW_REQUIRED"
    echo "- bypass_allowed: ${REVIEW_BYPASS_REASONS:--}"
    echo
    echo "## Reviewer Instructions"
    echo
    echo "Review for correctness, regressions, missing tests, unsafe operations, and whether the request should be blocked, approved, or commented."
    echo
    echo "Complete this review with:"
    echo
    echo '```bash'
    echo "agent-bridge review complete <task-id> --reviewer $reviewer --decision approved --note \"...\""
    echo '```'
    echo
    echo "## Payload"
    echo
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
    elif [[ -n "$body_file" ]]; then
      [[ -r "$body_file" ]] || bridge_die "body file을 읽을 수 없습니다: $body_file"
      printf 'body_file: %s\n\n' "$body_file"
      cat "$body_file"
    else
      echo "(no payload provided)"
    fi
  } >"$task_body_file"

  task_title="[review-request] $subject"
  bridge_queue_source_shell create --to "$reviewer" --title "$task_title" --from "$actor" --priority "$priority" --body-file "$task_body_file" --format shell
  printf 'created review task #%s for %s [%s] %s\n' "$TASK_ID" "$TASK_ASSIGNED_TO" "$TASK_PRIORITY" "$TASK_TITLE"
  printf 'review_body_file: %s\n' "$task_body_file"
  notice_message="agb inbox ${reviewer}"
  bridge_dispatch_notification "$reviewer" "$TASK_TITLE" "$notice_message" "$TASK_ID" "$TASK_PRIORITY" >/dev/null 2>&1 || true
}

cmd_complete() {
  local task_id="${1:-}"
  local reviewer=""
  local decision=""
  local note=""
  local note_file=""
  local completion_file=""

  shift || true
  [[ -n "$task_id" ]] || bridge_die "Usage: $(basename "$0") complete <task-id> --reviewer <agent> --decision approved|changes_requested|comment [...]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reviewer|--agent)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        reviewer="$2"
        shift 2
        ;;
      --decision)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        decision="$2"
        shift 2
        ;;
      --note)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 review complete 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$reviewer" ]] || bridge_die "--reviewer는 필수입니다."
  bridge_require_agent "$reviewer"
  case "$decision" in
    approved|changes_requested|comment) ;;
    *) bridge_die "--decision은 approved|changes_requested|comment 중 하나여야 합니다." ;;
  esac

  mkdir -p "$BRIDGE_SHARED_DIR/reviews"
  # BSD-portable (task #4648 carry): see review-request mktemp comment above.
  completion_file_base="$(mktemp "$BRIDGE_SHARED_DIR/reviews/review-complete.XXXXXX")"
  completion_file="${completion_file_base}.md"
  mv "$completion_file_base" "$completion_file" || { rm -f "$completion_file_base"; bridge_die "review-complete body rename failed"; }
  {
    echo "review_decision: $decision"
    echo "reviewed_by: $reviewer"
    echo
    if [[ -n "$note" ]]; then
      printf '%s\n' "$note"
    elif [[ -n "$note_file" ]]; then
      [[ -r "$note_file" ]] || bridge_die "note file을 읽을 수 없습니다: $note_file"
      cat "$note_file"
    else
      echo "(no review note provided)"
    fi
  } >"$completion_file"

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-task.sh" done "$task_id" --agent "$reviewer" --note-file "$completion_file"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  policy)
    cmd_policy "$@"
    ;;
  request)
    cmd_request "$@"
    ;;
  complete)
    cmd_complete "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    bridge_die "지원하지 않는 review 명령입니다: $cmd"
    ;;
esac
