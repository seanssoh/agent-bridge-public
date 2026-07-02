#!/usr/bin/env bash
#
# Test shim for bridge-auth.sh — emulates the Contract-A (#21895 sub-PR 2)
# token-updater lease verbs the daemon tick calls:
#   claude-token lease status --check      (exit-code-only enable gate)
#   claude-token lease status --json       (lease-state + active mapping)
#   claude-token lease checkout --json
#   claude-token lease heartbeat --json
#   claude-token lease checkin
#
# Behavior is driven by a small env-file so each smoke case can configure a
# scenario without rewriting the shim (footgun #11: no heredoc-stdin here).
#
# Env inputs (all from the driver's environment):
#   LEASE_SHIM_STATE — path to a sourced env file setting:
#       LEASE_ENABLED         1|0   (status --check exit code: 0 iff 1)
#       LEASE_CONFIGURED      1|0   (status --json `configured`)
#       LEASE_HAS_LEASE       1|0   (emit a lease object with a service id)
#       LEASE_EXPIRES_AT      epoch|"" (lease.lease_expires_at)
#       LEASE_LOCAL_TOKEN_ID  str   (lease.local_token_id)
#       LEASE_ACTIVE_TOKEN_ID str   (top-level active_token_id)
#       LEASE_SERVICE_TOKEN_ID str  (lease.service_token_id)
#       LEASE_STATUS_BAD      1|0   (emit unparseable status JSON)
#       LEASE_HEARTBEAT_STATUS str  (heartbeat status: ok|error|conflict)
#       LEASE_HEARTBEAT_HTTP  int|"" (heartbeat http: 200|404|409|"")
#       LEASE_CHECKOUT_STATUS str   (checkout envelope status: ok|error)
#   LEASE_SHIM_CALLS — path to a log file; one line per verb invoked
#                      (status-check / status-json / checkout / heartbeat /
#                      checkin), so the smoke asserts what the daemon called.
set -uo pipefail

: "${LEASE_SHIM_STATE:?}"
: "${LEASE_SHIM_CALLS:?}"

# Defaults (a disabled, unconfigured lease). The state file overrides.
LEASE_ENABLED=0
LEASE_CONFIGURED=0
LEASE_HAS_LEASE=0
LEASE_EXPIRES_AT=""
LEASE_LOCAL_TOKEN_ID=""
LEASE_ACTIVE_TOKEN_ID=""
LEASE_SERVICE_TOKEN_ID=""
LEASE_STATUS_BAD=0
LEASE_HEARTBEAT_STATUS="ok"
LEASE_HEARTBEAT_HTTP="200"
LEASE_CHECKOUT_STATUS="ok"
if [[ -f "$LEASE_SHIM_STATE" ]]; then
  # shellcheck source=/dev/null
  source "$LEASE_SHIM_STATE"
fi

record_call() { printf '%s\n' "$1" >>"$LEASE_SHIM_CALLS"; }

# Positional walk: expect `claude-token lease <action> [--check] [--json]`.
action=""
want_check=0
want_json=0
seen_lease=0
for arg in "$@"; do
  case "$arg" in
    lease) seen_lease=1 ;;
    --check) want_check=1 ;;
    --json) want_json=1 ;;
    status|checkout|heartbeat|checkin|swap)
      [[ "$seen_lease" == "1" && -z "$action" ]] && action="$arg" ;;
    *) : ;;
  esac
done

if [[ "$seen_lease" != "1" || -z "$action" ]]; then
  echo "lease-shim: unexpected argv: $*" >&2
  exit 2
fi

emit_status_json() {
  if [[ "$LEASE_STATUS_BAD" == "1" ]]; then
    printf 'this is not json\n'
    return 0
  fi
  local lease_obj="null"
  if [[ "$LEASE_HAS_LEASE" == "1" ]]; then
    local expires="null"
    [[ -n "$LEASE_EXPIRES_AT" ]] && expires="$LEASE_EXPIRES_AT"
    lease_obj="$(printf '{"service_token_id": "%s", "local_token_id": "%s", "lease_expires_at": %s}' \
      "$LEASE_SERVICE_TOKEN_ID" "$LEASE_LOCAL_TOKEN_ID" "$expires")"
  fi
  printf '{"enabled": %s, "configured": %s, "active_token_id": "%s", "lease": %s}\n' \
    "$([[ "$LEASE_ENABLED" == "1" ]] && echo true || echo false)" \
    "$([[ "$LEASE_CONFIGURED" == "1" ]] && echo true || echo false)" \
    "$LEASE_ACTIVE_TOKEN_ID" "$lease_obj"
}

case "$action" in
  status)
    if [[ "$want_check" == "1" ]]; then
      record_call "status-check"
      [[ "$LEASE_ENABLED" == "1" ]] && exit 0 || exit 1
    fi
    record_call "status-json"
    emit_status_json
    exit 0
    ;;
  checkout)
    record_call "checkout"
    printf '{"status": "%s", "service_token_id": "%s", "account_email": "op@example.test", "lease_expires_at": %s}\n' \
      "$LEASE_CHECKOUT_STATUS" "$LEASE_SERVICE_TOKEN_ID" "$(( $(date +%s) + 900 ))"
    [[ "$LEASE_CHECKOUT_STATUS" == "ok" ]] && exit 0 || exit 0
    ;;
  heartbeat)
    record_call "heartbeat"
    local_http="$LEASE_HEARTBEAT_HTTP"
    if [[ -n "$local_http" ]]; then
      printf '{"status": "%s", "http": %s}\n' "$LEASE_HEARTBEAT_STATUS" "$local_http"
    else
      printf '{"status": "%s", "http": null}\n' "$LEASE_HEARTBEAT_STATUS"
    fi
    exit 0
    ;;
  checkin)
    record_call "checkin"
    printf '{"status": "ok"}\n'
    exit 0
    ;;
  *)
    echo "lease-shim: unsupported action: $action" >&2
    exit 2
    ;;
esac
