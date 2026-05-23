#!/usr/bin/env bash
# bridge-tmux-ux.sh — managed tmux UX defaults for Claude/Codex TUI sessions.
#
# Issue #1058: Agent Bridge launches Claude Code / Codex inside tmux. A fresh
# server's stock tmux defaults degrade the TUI:
#   - `default-terminal screen` → near-monochrome rendering
#   - `mouse off`               → rough scrollback / copy-mode interaction
#   - `escape-time 500`         → unreliable / delayed double-`Esc`
#
# This helper writes an idempotent *managed block* into `~/.tmux.conf`
# (delimited by BEGIN/END markers), re-running bootstrap replaces the block
# in place without duplicating it and without rewriting the rest of the file
# or clobbering existing user customizations. The whole step is non-fatal:
# any failure prints a `tmux UX` next-step note and returns 0 so bootstrap
# never aborts on it.
#
# Sourced by bridge-bootstrap.sh after bridge-lib.sh, so bridge_warn /
# bridge_info are available; the helper still tolerates their absence so it
# can be unit-smoke-tested standalone.
#
# Footgun #11 (Bash 5.3.9 heredoc_write deadlock): the managed block is
# assembled with `printf` into a plain string and written to a *file* with
# a single `printf '%s' >file` — no heredoc-to-subprocess, no `<<<`
# here-string, no process-substitution-into-reader.

# --- soft fallbacks so the helper is testable without bridge-lib.sh ----------
if ! declare -F bridge_warn >/dev/null 2>&1; then
  bridge_warn() { echo "[경고] $*" >&2; }
fi
if ! declare -F bridge_info >/dev/null 2>&1; then
  bridge_info() { echo "$*"; }
fi

# bridge_tmux_ux_version_supports_terminal_features <version-string>
# `terminal-features` is a tmux 3.2+ option. On older tmux, sourcing a conf
# that sets it errors out, so the line must be gated. Returns 0 when the
# detected version is >= 3.2.
bridge_tmux_ux_version_supports_terminal_features() {
  local raw="${1:-}"
  # `tmux -V` prints e.g. "tmux 3.6a" or "tmux next-3.4"; strip to digits.dot.
  local num
  num="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$num" ]] || return 1
  local major="${num%%.*}"
  local minor="${num##*.}"
  # strip any leading zeros defensively (printf %d would choke on "08")
  major="$((10#${major:-0}))"
  minor="$((10#${minor:-0}))"
  if (( major > 3 )); then
    return 0
  fi
  if (( major == 3 && minor >= 2 )); then
    return 0
  fi
  return 1
}

# bridge_tmux_ux_render_block
# Emits the managed-block body (between but excluding the markers) to stdout.
# Args:
#   $1 default-terminal value ("tmux-256color" or "screen-256color")
#   $2 "1" to include the terminal-features line, "0" to omit it
bridge_tmux_ux_render_block() {
  local default_terminal="$1"
  local with_terminal_features="$2"

  printf 'set -g default-terminal "%s"\n' "$default_terminal"
  printf 'set -ag terminal-overrides ",xterm-256color:RGB"\n'
  if [[ "$with_terminal_features" == "1" ]]; then
    printf 'set -ag terminal-features ",xterm-256color:RGB"\n'
  fi
  printf 'set -g mouse on\n'
  printf 'set -s escape-time 10\n'
}

# bridge_tmux_ux_write_conf <conf-path> <block-body>
# Idempotently install the managed block into <conf-path>. Replaces an
# existing BEGIN/END block in place; otherwise appends. Never rewrites lines
# outside the markers. Returns:
#   0 — written/updated
#   1 — already up to date (no change)
#   2 — malformed existing block (BEGIN without END or vice versa)
bridge_tmux_ux_write_conf() {
  local conf="$1"
  local body="$2"
  local begin="# BEGIN AGENT BRIDGE TMUX UX"
  local end="# END AGENT BRIDGE TMUX UX"

  # $body is captured via $(...) which strips trailing newlines, so join the
  # marker lines with explicit newlines rather than relying on a trailing one.
  local managed
  managed="$(printf '%s\n%s\n%s' "$begin" "$body" "$end")"

  mkdir -p "$(dirname "$conf")"
  if [[ ! -f "$conf" ]]; then
    printf '%s\n' "$managed" >"$conf"
    return 0
  fi

  local has_begin=0 has_end=0
  grep -Fqx "$begin" "$conf" && has_begin=1
  grep -Fqx "$end" "$conf" && has_end=1

  if (( has_begin != has_end )); then
    return 2
  fi

  if (( has_begin == 0 )); then
    # Append with a leading blank line separator if the file is non-empty
    # and does not already end in a newline-only tail.
    if [[ -s "$conf" ]]; then
      printf '\n%s\n' "$managed" >>"$conf"
    else
      printf '%s\n' "$managed" >>"$conf"
    fi
    return 0
  fi

  # Replace the existing block in place. Walk the file line by line: copy
  # everything verbatim, swap the BEGIN..END span for the freshly rendered
  # managed block exactly once.
  local tmp
  tmp="$(mktemp "${conf}.tmpXXXXXX" 2>/dev/null)" || return 3
  [[ -n "$tmp" ]] || return 3
  local in_block=0 replaced=0 line
  while IFS='' read -r line || [[ -n "$line" ]]; do
    if [[ "$in_block" -eq 0 && "$line" == "$begin" ]]; then
      in_block=1
      if [[ "$replaced" -eq 0 ]]; then
        printf '%s\n' "$managed" >>"$tmp"
        replaced=1
      fi
      continue
    fi
    if [[ "$in_block" -eq 1 ]]; then
      if [[ "$line" == "$end" ]]; then
        in_block=0
      fi
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$conf"

  if cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    return 1
  fi

  # Preserve the original file mode where possible.
  chmod --reference="$conf" "$tmp" 2>/dev/null || true
  mv "$tmp" "$conf"
  return 0
}

# bridge_setup_tmux_ux [--dry-run]
# Top-level entry invoked by bridge-bootstrap.sh. Detects tmux + terminfo,
# renders the version-gated managed block, writes it to ~/.tmux.conf, and
# re-sources a live tmux server if one is running. Always returns 0 — any
# failure is reported as a warning/next-step, never fatal.
bridge_setup_tmux_ux() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
  fi

  local conf="${BRIDGE_TMUX_UX_CONF:-$HOME/.tmux.conf}"

  if ! command -v tmux >/dev/null 2>&1; then
    bridge_warn "tmux UX: tmux 가 설치되어 있지 않아 ~/.tmux.conf 튜닝을 건너뜁니다."
    bridge_info "  next step: tmux 설치 후 'agb' 재실행 시 색상/마우스/escape-time 가 자동 보정됩니다."
    return 0
  fi

  # default-terminal: only set tmux-256color when its terminfo entry exists.
  # Setting a missing terminal breaks rendering, so fall back to
  # screen-256color (universally present) and note the downgrade.
  local default_terminal="tmux-256color"
  if ! infocmp -x tmux-256color >/dev/null 2>&1; then
    default_terminal="screen-256color"
    bridge_info "tmux UX: 'tmux-256color' terminfo 가 없어 'screen-256color' 로 대체합니다."
  fi

  # terminal-features is tmux 3.2+. Omit the line on older tmux so sourcing
  # the conf does not error.
  local tmux_version with_terminal_features=0
  tmux_version="$(tmux -V 2>/dev/null || printf '')"
  if bridge_tmux_ux_version_supports_terminal_features "$tmux_version"; then
    with_terminal_features=1
  else
    bridge_info "tmux UX: ${tmux_version:-tmux} 는 'terminal-features' 미지원 — 해당 줄을 생략합니다."
  fi

  local body
  body="$(bridge_tmux_ux_render_block "$default_terminal" "$with_terminal_features")"

  if (( dry_run == 1 )); then
    bridge_info "tmux UX: --dry-run — ~/.tmux.conf 를 수정하지 않습니다 (managed block 미리보기):"
    printf '%s\n' "# BEGIN AGENT BRIDGE TMUX UX"
    printf '%s\n' "$body"
    printf '%s\n' "# END AGENT BRIDGE TMUX UX"
    return 0
  fi

  local rc=0
  bridge_tmux_ux_write_conf "$conf" "$body" || rc=$?
  case "$rc" in
    0)
      bridge_info "tmux UX: managed block 적용 — $conf"
      ;;
    1)
      bridge_info "tmux UX: managed block 최신 상태 — $conf (변경 없음)"
      ;;
    2)
      bridge_warn "tmux UX: $conf 의 managed block 이 손상되었습니다 (BEGIN/END 불일치)."
      bridge_info "  next step: '# BEGIN AGENT BRIDGE TMUX UX' ~ '# END AGENT BRIDGE TMUX UX' 구간을 직접 정리 후 'agb' 재실행."
      return 0
      ;;
    *)
      bridge_warn "tmux UX: ~/.tmux.conf 갱신 중 예기치 못한 오류 (rc=$rc) — 건너뜁니다."
      return 0
      ;;
  esac

  # Re-source a live tmux server so the change takes effect immediately;
  # skip silently when no server is running.
  if tmux info >/dev/null 2>&1; then
    if tmux source-file "$conf" >/dev/null 2>&1; then
      bridge_info "tmux UX: 실행 중인 tmux 서버에 source-file 반영 완료."
    else
      bridge_info "tmux UX: tmux source-file 반영 실패 — 새 tmux 세션부터 적용됩니다."
    fi
  fi

  return 0
}
