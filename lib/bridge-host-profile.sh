#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-host-profile.sh — first-run host profile (server vs dev) + production
# cron gating.
#
# Background: Issue #713 + 2026-05-13 follow-up. On a fresh install, the admin
# agent inherits the same managed cron set on every host — including
# production-style wiki/librarian maintenance jobs that only make sense on a
# hosted/server install. On a developer laptop they generate `[cron-followup]`
# storms from transient network blips and assume infra (wiki content,
# ingestion sources) the laptop never set up. This helper adds a one-time
# onboarding question and, on a `dev` answer, offers to disable the
# production-style jobs (default-yes). `memory-daily-<agent>` is also in the
# gated set on dev hosts as of 2026-05-13: Claude Code's own session-memory
# system already covers the long-term-context use case on a developer laptop,
# so running the harvester is duplicative there. Re-enable any time with
# `agb cron update memory-daily-<agent> --enable`.
#
# Schema-extension follow-up (cron job definitions declaring
# `profiles: [server, dev]` directly) is out of scope here — see #713's
# follow-up note. We hardcode the family list as a single named constant
# (BRIDGE_HOST_PROFILE_PRODUCTION_CRONS) so the eventual schema migration
# has one site to update.

# Production-style cron names that are gated off on profile=dev. Sourced
# from the issue body's "Suggested cron classification" table. Order is the
# operator-facing display order in the prompt.
BRIDGE_HOST_PROFILE_PRODUCTION_CRONS=(
  "librarian-watchdog"
  "wiki-mention-scan"
  "wiki-daily-ingest"
  "wiki-hub-audit"
  "wiki-weekly-summarize"
  "wiki-monthly-summarize"
  "wiki-copy-full-backfill"
  "wiki-dedup-weekly"
  "wiki-v2-rebuild"
  "wiki-repair-links"
)

# Cron name prefixes that are gated off on profile=dev. `memory-daily-<agent>`
# is per-agent (one cron per static agent), so the exact-name list above can't
# enumerate it. Operator decision (2026-05-13): dev hosts already get
# Claude Code's own session-memory system (`~/.claude/projects/<repo>/memory/`)
# which covers the long-term context use case memory-daily harvests serve, so
# the daily harvester is duplicative on a developer laptop. Re-enable any time
# with `agb cron update memory-daily-<agent> --enable`.
BRIDGE_HOST_PROFILE_PRODUCTION_CRON_PREFIXES=(
  "memory-daily-"
)

bridge_host_profile_path() {
  printf '%s/install/host-profile.json' "$BRIDGE_STATE_DIR"
}

# Read the persisted profile value (server|dev) or empty string if absent.
bridge_host_profile_load() {
  local path
  path="$(bridge_host_profile_path)"
  [[ -f "$path" ]] || { printf ''; return 0; }
  bridge_require_python
  python3 - "$path" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    profile = data.get("profile", "")
    if profile in ("server", "dev"):
        print(profile)
    else:
        print("")
except Exception:
    print("")
PY
}

# Lightweight host_profile check usable from scripts that haven't sourced the
# full bridge lib chain (e.g. scripts/picker-sweep.sh invoked from a bare
# cron line). Reads the persisted host-profile.json directly via inline
# python3 — does NOT call bridge_require_python (no roster, no logging
# setup required).
#
# Resolution order for the JSON path:
#   1. BRIDGE_HOST_PROFILE env (cheapest, explicit override; wins outright).
#   2. $BRIDGE_HOME/state/install/host-profile.json — checked first because
#      most invocations come from a cron line that sets BRIDGE_HOME and
#      expects state under it. When BRIDGE_HOME is set but the file under
#      it doesn't exist, we still fall through to (3) so a relocated
#      BRIDGE_STATE_DIR remains honored.
#   3. $BRIDGE_STATE_DIR/install/host-profile.json — honored when set
#      explicitly (e.g. an operator who relocated state with
#      BRIDGE_STATE_DIR=/var/lib/agent-bridge/state).
#
# Returns 0 (truthy in shell sense) when the resolved profile is "dev",
# 1 otherwise (including unknown / unset / file missing / read error).
bridge_host_profile_is_dev() {
  local env_profile="${BRIDGE_HOST_PROFILE:-}"
  case "$env_profile" in
    dev) return 0 ;;
    server) return 1 ;;
  esac
  local path=""
  if [[ -n "${BRIDGE_HOME:-}" && -f "$BRIDGE_HOME/state/install/host-profile.json" ]]; then
    path="$BRIDGE_HOME/state/install/host-profile.json"
  elif [[ -n "${BRIDGE_STATE_DIR:-}" && -f "$BRIDGE_STATE_DIR/install/host-profile.json" ]]; then
    path="$BRIDGE_STATE_DIR/install/host-profile.json"
  else
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  local profile
  profile="$(python3 - "$path" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    p = data.get("profile", "")
    if p in ("server", "dev"):
        print(p)
except Exception:
    pass
PY
)"
  [[ "$profile" == "dev" ]]
}

# Read the persisted set_at timestamp (best-effort context for idempotency
# logging). Empty string if file absent or malformed.
bridge_host_profile_set_at() {
  local path
  path="$(bridge_host_profile_path)"
  [[ -f "$path" ]] || { printf ''; return 0; }
  bridge_require_python
  python3 - "$path" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(data.get("set_at", "") or "")
except Exception:
    print("")
PY
}

# Persist the chosen profile to host-profile.json.
# Args: profile (server|dev), set_by (init|reconfigure|non-interactive-default)
bridge_host_profile_save() {
  local profile="$1"
  local set_by="${2:-init}"
  local path
  path="$(bridge_host_profile_path)"
  mkdir -p "$(dirname "$path")"
  bridge_require_python
  python3 - "$path" "$profile" "$set_by" <<'PY'
import json, os, sys, datetime
path, profile, set_by = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "profile": profile,
    "set_at": datetime.datetime.now().astimezone().isoformat(),
    "set_by": set_by,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
  # Codex r2: ensure operators can read this file (umask on shared installs
  # can produce 0640/0600 by default). Failure is non-fatal — the JSON itself
  # is already on disk; this only widens read access.
  chmod 0644 "$path" 2>/dev/null || true
}

# Resolve cron job ids by name. Echos lines of "<id>\t<name>" for jobs whose
# `name` field matches one of BRIDGE_HOST_PROFILE_PRODUCTION_CRONS *and* is
# currently enabled. Names not present in the cron inventory are skipped
# silently — on a brand-new install bootstrap-memory-system.sh may not have
# run yet, and that's fine.
# Args: agent-bridge CLI path
bridge_host_profile_list_production_crons() {
  local agent_bridge_cli="$1"
  local list_json=""
  # `cron list --json` exits non-zero when the jobs file is missing on a
  # fresh install — treat that as "no production crons to disable" rather
  # than fatal. The dev operator will still get the host-profile saved.
  if ! list_json="$("$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron list --enabled yes --json 2>/dev/null)"; then
    return 0
  fi
  [[ -n "$list_json" ]] || return 0
  bridge_require_python
  # Pass exact-name list first, then a `--prefixes` separator, then prefix list.
  # The separator is an argv-static sentinel — the two source lists at the top
  # of this file (BRIDGE_HOST_PROFILE_PRODUCTION_CRONS,
  # BRIDGE_HOST_PROFILE_PRODUCTION_CRON_PREFIXES) are controller-owned constants
  # that never contain `--prefixes` literally, and adding new entries is
  # reviewed alongside this helper. Codex r1 reviewer caught that cron `name`
  # is the raw operator-supplied title (not slugified — only `job_id` runs
  # through `slugify_title`), so the contract relies on caller discipline,
  # not on cron-name format invariants. Structural encoding (single JSON
  # payload via stdin) would be safer but adds bash-side JSON escaping risk
  # for no current benefit; revisit if a future addition needs `--`-prefixed
  # tokens.
  python3 - "$list_json" "${BRIDGE_HOST_PROFILE_PRODUCTION_CRONS[@]}" "--prefixes" "${BRIDGE_HOST_PROFILE_PRODUCTION_CRON_PREFIXES[@]}" <<'PY'
import json, sys
list_json = sys.argv[1]
args = sys.argv[2:]
gated_names = set()
gated_prefixes = []
mode = "names"
for arg in args:
    if arg == "--prefixes":
        mode = "prefixes"
        continue
    if mode == "names":
        gated_names.add(arg)
    else:
        gated_prefixes.append(arg)
try:
    data = json.loads(list_json)
except Exception:
    sys.exit(0)
for job in data.get("jobs", []):
    name = job.get("name", "")
    if name in gated_names or any(name.startswith(p) for p in gated_prefixes):
        print(f"{job.get('id', '')}\t{name}")
PY
}

# Disable a single cron job by id. Returns the CLI's exit code.
# Args:
#   $1 = agent-bridge CLI path
#   $2 = job id
#   $3 = quiet (1=fully silence subprocess stdout+stderr, 0=surface stderr)
# Codex r2: caller QUIET (json_mode / non-interactive) propagates to the
# subprocess. `agent-bridge cron update` does not currently expose a
# `--quiet` flag, so we redirect at the shell level. When the operator is
# interactive we keep stderr visible so cron-update failures surface in
# the same terminal.
bridge_host_profile_disable_cron() {
  local agent_bridge_cli="$1"
  local job_id="$2"
  local quiet="${3:-0}"
  if [[ "$quiet" == "1" ]]; then
    "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron update "$job_id" --disable >/dev/null 2>&1
  else
    "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron update "$job_id" --disable >/dev/null
  fi
}

# Offer to disable the production-style crons (default-yes). Caller has
# already confirmed profile=dev. Args:
#   $1 = agent-bridge CLI path
#   $2 = stdin-tty (1=interactive prompt, 0=auto-accept default-yes)
# Echoes a one-line summary to stdout: "disabled=<n> skipped=<n>".
bridge_host_profile_offer_dev_cron_disable() {
  local agent_bridge_cli="$1"
  local interactive="${2:-1}"
  local pairs=""
  pairs="$(bridge_host_profile_list_production_crons "$agent_bridge_cli")"
  if [[ -z "$pairs" ]]; then
    printf 'disabled=0 skipped=0 reason=no-matching-crons\n'
    return 0
  fi
  printf '\n' >&2
  printf '이 호스트(profile=dev)에는 librarian / wiki-* 유지보수 크론과\n' >&2
  printf 'memory-daily-<agent> 크론이 일반적으로 필요하지 않습니다\n' >&2
  printf '(memory-daily 는 Claude Code 자체 세션 메모리와 기능이 중복됩니다).\n' >&2
  printf '다음 크론을 disable 하시겠습니까?\n' >&2
  printf '(나중에 `agb cron update <id> --enable` 으로 다시 켤 수 있습니다.)\n' >&2
  printf '\n' >&2
  while IFS=$'\t' read -r _id _name; do
    [[ -n "$_name" ]] && printf '  - %s\n' "$_name" >&2
  done <<<"$pairs"
  printf '\n' >&2
  local answer="y"
  if [[ "$interactive" == "1" ]]; then
    printf '계속할까요? [Y/n]: ' >&2
    if ! IFS= read -r answer; then
      answer="y"
    fi
    [[ -z "$answer" ]] && answer="y"
  else
    printf '(non-interactive: default-yes 적용)\n' >&2
  fi
  case "$answer" in
    n|N|no|No|NO)
      printf 'disabled=0 skipped=%s reason=user-declined\n' "$(printf '%s\n' "$pairs" | wc -l | tr -d '[:space:]')"
      return 0
      ;;
  esac
  local disabled=0 failed=0
  # Codex r2: forward QUIET (== non-interactive) into subprocess so json_mode
  # init runs don't pollute the structured handoff with cron-update chatter.
  local quiet_flag="0"
  if [[ "$interactive" != "1" ]]; then
    quiet_flag="1"
  fi
  while IFS=$'\t' read -r _id _name; do
    [[ -n "$_id" ]] || continue
    if bridge_host_profile_disable_cron "$agent_bridge_cli" "$_id" "$quiet_flag"; then
      disabled=$((disabled + 1))
      printf '  disabled %s (%s)\n' "$_name" "$_id" >&2
    else
      failed=$((failed + 1))
      printf '  failed   %s (%s)\n' "$_name" "$_id" >&2
    fi
  done <<<"$pairs"
  printf 'disabled=%d failed=%d\n' "$disabled" "$failed"
}

# Top-level entry point invoked from bridge-init.sh. Idempotent.
# Args:
#   $1 = agent-bridge CLI path (so we can shell out to `cron list/update`)
#   $2 = reconfigure (1=force re-prompt even if file exists)
#   $3 = profile_override ("server"|"dev"|"" = ask)
#   $4 = json_mode (1=non-interactive contract: default server, no prompt)
#   $5 = admin agent id (used by the dev advisory to render the real static
#        pair names; falls back to "admin" inside the advisory helper when
#        empty so older callers without this arg still get a sensible
#        message)
# Echoes the chosen/loaded profile; non-zero exit only on fatal write
# failures.
bridge_host_profile_run() {
  local agent_bridge_cli="$1"
  local reconfigure="${2:-0}"
  local profile_override="${3:-}"
  local json_mode="${4:-0}"
  local admin_agent="${5:-}"

  # Idempotent fast-path: existing profile + no --reconfigure and no
  # explicit override.
  if [[ "$reconfigure" != "1" && -z "$profile_override" ]]; then
    local existing
    existing="$(bridge_host_profile_load)"
    if [[ -n "$existing" ]]; then
      # Codex r2: emit `already=<profile>` as a single grep-able sentinel
      # so downstream tooling / operator runbooks can detect the
      # already-configured branch without parsing free text. Augment with
      # set_at for context (best-effort; empty when JSON is malformed).
      local existing_set_at=""
      existing_set_at="$(bridge_host_profile_set_at)"
      if [[ -n "$existing_set_at" ]]; then
        printf '[host-profile] already=%s (set_at=%s)\n' "$existing" "$existing_set_at" >&2
      else
        printf '[host-profile] already=%s\n' "$existing" >&2
      fi
      printf '[host-profile] hint: re-run with `--reconfigure` to change.\n' >&2
      printf '%s\n' "$existing"
      return 0
    fi
  fi

  local profile="" set_by="init"
  if [[ -n "$profile_override" ]]; then
    case "$profile_override" in
      server|dev) profile="$profile_override" ;;
      *)
        printf 'host_profile: invalid --profile value (%s); ignoring\n' "$profile_override" >&2
        ;;
    esac
    set_by="flag"
  fi

  local interactive=1
  if [[ "$json_mode" == "1" ]] || [[ ! -t 0 ]]; then
    interactive=0
  fi

  if [[ -z "$profile" ]]; then
    if [[ "$interactive" == "0" ]]; then
      # Non-interactive default per #713: fall back to "server" so we don't
      # silently disable production cron families on a hosted install. Audit
      # log it via stderr.
      profile="server"
      set_by="non-interactive-default"
      printf 'host_profile: non-interactive context (CI/pipe/--json) — defaulting to server\n' >&2
    else
      printf '\n' >&2
      printf '== Host profile ==\n' >&2
      printf '이 머신의 역할은 무엇인가요?\n' >&2
      printf '  [a] 서버 / 항상-켜진 운영 호스트 (production)\n' >&2
      printf '  [b] 개발용 PC (dev)\n' >&2
      printf '\n' >&2
      printf 'Which profile fits this machine?\n' >&2
      printf '  [a] always-on server / production host\n' >&2
      printf '  [b] developer PC\n' >&2
      printf '\n' >&2
      local answer=""
      while [[ -z "$profile" ]]; do
        printf '답 [a/b]: ' >&2
        if ! IFS= read -r answer; then
          # EOF — fall back to server like the non-interactive path.
          profile="server"
          set_by="non-interactive-default"
          printf '\nhost_profile: stdin EOF — defaulting to server\n' >&2
          break
        fi
        case "$answer" in
          a|A) profile="server" ;;
          b|B) profile="dev" ;;
          *) printf '"a" 또는 "b"로 답해주세요.\n' >&2 ;;
        esac
      done
    fi
  fi

  bridge_host_profile_save "$profile" "$set_by"
  printf 'host_profile: %s (saved to %s, set_by=%s)\n' "$profile" "$(bridge_host_profile_path)" "$set_by" >&2

  if [[ "$profile" == "dev" ]]; then
    # Codex r1 finding 5: capture the cron-disable summary so the advisory
    # below reflects what actually happened (user-declined / no-matching /
    # success / partial-failure) instead of unconditionally claiming
    # "disable 처리됨".
    local cron_disable_summary=""
    cron_disable_summary="$(bridge_host_profile_offer_dev_cron_disable "$agent_bridge_cli" "$interactive" || true)"
    bridge_host_profile_emit_dev_advisories "$admin_agent" "$cron_disable_summary" >&2 || true
  fi

  printf '%s\n' "$profile"
}

# Emit one-shot advisory text for the operator on profile=dev. Currently
# covers: (a) external-channel setup will be skipped during this init run,
# (b) the v2 multi-tenant isolation layout is not required for dev hosts
# and stays opt-in via BRIDGE_LAYOUT=v2 / `agent-bridge migrate isolation-v2`,
# (c) the actual outcome of the production-cron disable offer (reflects
# user-declined, no-matching-crons, success, or partial-failure cases).
# No mutations — channel-skip is enforced at the bridge-init.sh call site,
# isolation is operator-opt-in. The block is informational so the dev
# operator sees in one place why the rest of the init flow looks lighter.
#
# Args:
#   $1 = admin agent id (e.g. "patch"). Used to render the static-pair line
#        accurately when --admin is non-default. Falls back to "admin" when
#        empty so legacy callers still get a sensible message.
#   $2 = cron-disable summary (the single-line output of
#        bridge_host_profile_offer_dev_cron_disable; e.g.
#        "disabled=10 failed=0", "disabled=0 skipped=12 reason=user-declined",
#        "disabled=0 skipped=0 reason=no-matching-crons"). Drives the
#        wording of the cron lines below. Empty string falls back to the
#        success wording ("disable 처리됨") — assumes a future caller that
#        forgot to wire the summary through has nevertheless run the
#        offer first (matches the actual call site in
#        bridge_host_profile_run, which always invokes offer + emit in
#        sequence). Codex r2 finding: keep this fallback honest by stating
#        the actual init value rather than promising "offered" wording the
#        code does not emit.
bridge_host_profile_emit_dev_advisories() {
  local admin_agent="${1:-admin}"
  local cron_summary="${2:-}"
  local admin_pair="${admin_agent}-dev"
  # Parse summary into a short user-facing verb. The summary is one of:
  #   disabled=N failed=M                          (success-or-mixed path)
  #   disabled=0 skipped=N reason=user-declined    (operator said no)
  #   disabled=0 skipped=N reason=no-matching-crons (nothing to disable yet)
  # We treat "disabled > 0" as truly disabled, anything else as offered-only.
  local cron_verb="disable 처리됨"
  local cron_extra=""
  if [[ -n "$cron_summary" ]]; then
    if [[ "$cron_summary" == *"reason=user-declined"* ]]; then
      cron_verb="유지됨 (운영자가 disable 거절)"
      cron_extra='    필요하면 나중에 `agb cron update <id> --disable` 으로 끌 수 있습니다.\n'
    elif [[ "$cron_summary" == *"reason=no-matching-crons"* ]]; then
      cron_verb="해당 없음 (현재 호스트에 등록된 매칭 크론 없음)"
      cron_extra=""
    elif [[ "$cron_summary" =~ disabled=0([[:space:]]|$) ]]; then
      cron_verb="disable 시도 결과 0건 (요약: ${cron_summary})"
      cron_extra=""
    fi
  fi
  printf '\n'
  printf '[host-profile=dev] 다음 운영용 기능은 이번 init 에서 건너뛰거나 비활성 상태로 둡니다:\n'
  printf '  - 외부 채널 (Discord / Telegram / Teams / Mattermost) 부트스트랩: skip\n'
  printf '    필요해지면 `agb setup discord %s` 등으로 나중에 켤 수 있습니다.\n' "$admin_agent"
  printf '  - 멀티테넌트 v2 isolation 레이아웃: legacy 유지 (마이그레이션 비강제)\n'
  printf '    Linux 운영 호스트에서 다중 사용자 분리가 필요해지면\n'
  printf '    `agent-bridge migrate isolation-v2 --apply` 로 전환할 수 있습니다.\n'
  printf '  - librarian / wiki-* 정기 크론: %s\n' "$cron_verb"
  printf '  - memory-daily-<agent> 크론: %s\n' "$cron_verb"
  printf '    (Claude Code 자체 세션 메모리와 기능이 중복되므로 dev 에서는 불필요)\n'
  if [[ -n "$cron_extra" ]]; then
    # shellcheck disable=SC2059
    printf "$cron_extra"
  fi
  printf '  - picker-sweep 자동 unstick: skip (BRIDGE_PICKER_SWEEP_ENABLED=1 로 override 가능)\n'
  printf '  - prompt-guard (채널/MCP/intake 검사): skip (BRIDGE_PROMPT_GUARD_ENABLED=1 로 override 가능)\n'
  printf '\n'
  printf '정적 에이전트는 admin(`%s`) + admin-dev(`%s` codex pair) 2개로\n' "$admin_agent" "$admin_pair"
  printf '시작합니다. 추가 정적 역할은 운영 모드에서만 필요한 경우가 일반적입니다.\n'
  printf '\n'
  printf 'admin 에이전트의 CLAUDE.md 에는 `wave-orchestration` 스킬을 default workflow\n'
  printf '로 사용하라는 SOP 블록이 자동 주입됩니다 — 사용자가 "X 만들어줘" 라고 하면\n'
  printf '%s + %s 페어가 wave (병렬 issue-fixer + codex review) 로 진행합니다.\n' "$admin_agent" "$admin_pair"
  printf '\n'
}
