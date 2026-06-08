#!/usr/bin/env bash
# scripts/smoke/1697-a2a-net-status.sh — `agb a2a net-status` read-only
# transport/substrate observability (#1697).
#
# #1697 adds a READ-ONLY `agb a2a net-status [--json]` (+ `status` alias) verb
# that reports THIS node's ACTIVE A2A transport + substrate health so a
# co-resident agent stops acting on a stale (Tailscale) assumption after a
# transport switch — and crucially probes ONLY the configured substrate (a
# cloudflare-warp-mesh install must NEVER shell `tailscale status`).
#
# This smoke proves the contract from the issue + the wave brief:
#   (1) STABLE SHAPE — `net-status --json` returns the fixed-key snapshot
#       (bridge_id / transport / listen / receiver / substrate / peers / rooms).
#   (2) ACTIVE-TRANSPORT-ONLY (WARP) — with transport.kind=cloudflare-warp-mesh
#       and a FAKE `tailscale` on PATH that fails LOUD if invoked, net-status
#       reports substrate.checked=cloudflare-warp-mesh, the substrate dict has NO
#       tailscale* keys, and the fake tailscale is NEVER executed (the dead-
#       Tailscale-restart bug the issue exists to kill).
#   (3) ACTIVE-TRANSPORT-ONLY (Tailscale) — with transport.kind=tailscale net-
#       status takes the tailscale probe path (substrate.checked=tailscale, has
#       tailscale_up; NO warp* keys).
#   (4) MALFORMED/MISSING transport config — net-status degrades SAFELY (a
#       nonzero diagnostic or a `legacy-none`/`unknown` snapshot) and mutates NO
#       state (the config file is byte-identical and no new files are created).
#   (5) NO SECRETS — a secret-bearing config never leaks a listen/peer secret
#       into the plain or JSON output (addresses/ports/counts/pids only).
#   (6) #1701 CONSISTENCY — on a cloudflare-warp-mesh install whose receiver
#       listen socket is HELD but whose GET /healthz self-probe can't hairpin
#       the /32 WARP bind, net-status must report receiver.healthz=healthy (NOT
#       healthz_timeout): it reuses the same cmd_healthz socket-held fallback
#       that #1701 added in bridge-handoffd.py, so net-status can never disagree
#       with the supervisor's warp-aware liveness verdict.
#   (7) STATIC TEETH — net-status is registered (net-status + status alias) and
#       its probes are read-only (os.kill(pid, 0), argv-list subprocess, no
#       config write / SIGHUP / bind-serve).
#
# Everything is exercised against an ISOLATED BRIDGE_HOME with mocked substrate
# seams (BRIDGE_A2A_WARP_CLI / BRIDGE_A2A_IFACE_ADDRS / BRIDGE_A2A_TAILSCALE_CLI
# / BRIDGE_A2A_CONFIG) — no real WARP/Tailscale install, no live A2A state.
# Footgun #11: all Python driving is via the *-helper.py file-as-argv sidecar.
# macOS: run with /opt/homebrew/bin/bash (Bash 5.x).

set -euo pipefail

SMOKE_NAME="1697-a2a-net-status"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1697-a2a-net-status-helper.py"
A2A_CLI="$SMOKE_REPO_ROOT/bridge-a2a.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

helper() { python3 "$HELPER" "$@"; }

# Run `agb a2a net-status` (json or plain) against a given config + optional
# extra env (fake tailscale, mocked iface/warp seams). Echoes stdout only.
net_status() {
  local config="$1"; shift
  local mode="$1"; shift   # "json" | "plain"
  local args=("net-status")
  [[ "$mode" == "json" ]] && args+=("--json")
  if [[ "$mode" == "plain" ]]; then
    BRIDGE_A2A_CONFIG="$config" python3 "$A2A_CLI" "${args[@]}" "$@" 2>/dev/null || true
  else
    BRIDGE_A2A_CONFIG="$config" python3 "$A2A_CLI" "${args[@]}" "$@" 2>/dev/null || true
  fi
}

# A fake `tailscale` that fails LOUD (writes a sentinel file + nonzero exit) if
# it is ever executed. Returned on stdout: the directory holding it (to prepend
# to PATH) and the sentinel path (to assert it was never written).
write_loud_fake_tailscale() {
  local dir="$SMOKE_TMP_ROOT/fakebin"
  mkdir -p "$dir"
  local sentinel="$SMOKE_TMP_ROOT/tailscale-was-invoked"
  cat >"$dir/tailscale" <<EOF
#!/usr/bin/env bash
echo "FAKE_TAILSCALE_INVOKED args=\$*" >&2
printf 'invoked\n' >>"$sentinel"
exit 99
EOF
  chmod 0755 "$dir/tailscale"
  printf '%s\n%s\n' "$dir" "$sentinel"
}

write_warp_config() {
  local path="$1" addr="${2:-100.96.0.5}"
  cat >"$path" <<EOF
{
  "bridge_id": "warp-node",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "address": "${addr}", "port": 8787 },
  "peers": [ { "id": "peer-a", "address": "100.96.0.6", "node_id": "n-a" } ]
}
EOF
  chmod 0600 "$path"
}

write_tailscale_config() {
  local path="$1"
  cat >"$path" <<EOF
{
  "bridge_id": "ts-node",
  "transport": { "kind": "tailscale" },
  "listen": { "address": "100.64.0.5", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$path"
}

# A self-contained mock `tailscale` that returns an Online Self node, so the
# tailscale probe path produces deterministic output without a real tailnet.
write_mock_tailscale() {
  local cli="$SMOKE_TMP_ROOT/tailscale-mock"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "status" ]]; then
  echo '{"Self":{"Online":true,"TailscaleIPs":["100.64.0.5"]}}'
  exit 0
fi
echo '{}'
EOF
  chmod 0755 "$cli"
  printf '%s' "$cli"
}

# === (1) stable JSON shape ===================================================
check_stable_shape() {
  local cfg="$SMOKE_TMP_ROOT/shape.json"
  write_warp_config "$cfg"
  local out
  out="$(BRIDGE_A2A_WARP_CLI="$SMOKE_TMP_ROOT/no-warp-cli" \
         net_status "$cfg" json)"
  echo "$out" | helper has-keys "bridge_id,transport,listen,receiver,substrate,peers,rooms" \
    >/dev/null \
    && smoke_log "ok-fields" \
    || smoke_fail "(1) net-status --json missing one of the stable top-level keys; got: $out"
  echo "$out" | helper field "transport" "cloudflare-warp-mesh" >/dev/null \
    || smoke_fail "(1) transport field != cloudflare-warp-mesh; got: $out"
  echo "$out" | helper field "listen.port" "8787" >/dev/null \
    || smoke_fail "(1) listen.port field missing/!=8787; got: $out"
}

# === (2) active-transport-only: WARP config never shells tailscale ===========
check_warp_no_tailscale_probe() {
  local cfg="$SMOKE_TMP_ROOT/warp.json"
  write_warp_config "$cfg"
  local fake dir sentinel
  fake="$(write_loud_fake_tailscale)"
  dir="$(printf '%s' "$fake" | sed -n '1p')"
  sentinel="$(printf '%s' "$fake" | sed -n '2p')"
  rm -f "$sentinel"
  local out
  # Fake tailscale FIRST on PATH; also point the explicit CLI override at it so
  # ANY tailscale invocation (PATH discovery OR override) would trip the
  # sentinel. A correct net-status must invoke NEITHER on a WARP config.
  out="$(PATH="$dir:$PATH" \
         BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" \
         BRIDGE_A2A_WARP_CLI="$SMOKE_TMP_ROOT/no-warp-cli" \
         net_status "$cfg" json)"
  echo "$out" | helper substrate-checked "cloudflare-warp-mesh" >/dev/null \
    || smoke_fail "(2) substrate.checked != cloudflare-warp-mesh; got: $out"
  echo "$out" | helper substrate-no-tailscale >/dev/null \
    || smoke_fail "(2) WARP substrate dict leaked tailscale keys; got: $out"
  smoke_assert_not_contains "$(cat "$sentinel" 2>/dev/null || true)" "invoked" \
    "(2) ACTIVE-TRANSPORT-ONLY: a WARP-mesh net-status NEVER executes tailscale"
  smoke_assert_not_contains "$out" "FAKE_TAILSCALE_INVOKED" \
    "(2) no fake-tailscale output bled into the snapshot"
}

# === (3) active-transport-only: Tailscale config takes the tailscale path ====
check_tailscale_probe_path() {
  local cfg="$SMOKE_TMP_ROOT/ts.json"
  write_tailscale_config "$cfg"
  local ts; ts="$(write_mock_tailscale)"
  local out
  out="$(BRIDGE_A2A_TAILSCALE_CLI="$ts" net_status "$cfg" json)"
  echo "$out" | helper substrate-checked "tailscale" >/dev/null \
    || smoke_fail "(3) substrate.checked != tailscale; got: $out"
  echo "$out" | helper substrate-no-warp >/dev/null \
    || smoke_fail "(3) Tailscale substrate dict leaked warp keys; got: $out"
  echo "$out" | helper field "substrate.tailscale_up" "True" >/dev/null \
    || smoke_fail "(3) tailscale probe path not taken (tailscale_up!=True); got: $out"
}

# === (4) malformed/missing config degrades safely + NO mutation ==============
check_malformed_safe_no_mutation() {
  # (4a) No transport block -> legacy-none label, tailscale probe, no mutation.
  local legacy="$SMOKE_TMP_ROOT/legacy.json"
  cat >"$legacy" <<'EOF'
{ "bridge_id": "legacy-node", "listen": { "address": "100.64.0.1", "port": 8787 }, "peers": [] }
EOF
  chmod 0600 "$legacy"
  local before after out
  before="$(helper free-port >/dev/null 2>&1; python3 -c "import hashlib,sys; print(hashlib.md5(open('$legacy','rb').read()).hexdigest())")"
  out="$(net_status "$legacy" json)"
  echo "$out" | helper field "transport" "legacy-none" >/dev/null \
    || smoke_fail "(4a) no-transport-block should report transport=legacy-none; got: $out"
  after="$(python3 -c "import hashlib; print(hashlib.md5(open('$legacy','rb').read()).hexdigest())")"
  smoke_assert_eq "$before" "$after" "(4a) net-status did NOT mutate the legacy config (read-only)"

  # (4b) Unknown-but-loadable transport.kind -> invalid:* label, safe fallback.
  local unk="$SMOKE_TMP_ROOT/unk.json"
  cat >"$unk" <<'EOF'
{ "bridge_id": "unk-node", "transport": { "kind": "weird-substrate" }, "listen": { "address": "100.64.0.9", "port": 8787 }, "peers": [] }
EOF
  chmod 0600 "$unk"
  out="$(net_status "$unk" json)"
  echo "$out" | helper substrate-checked "tailscale" >/dev/null \
    || smoke_fail "(4b) unknown transport.kind should fall back to a tailscale probe; got: $out"

  # (4c) Hard-invalid config (peers not a list) -> nonzero diagnostic, NO files
  # created in the config dir, config byte-identical.
  local bad="$SMOKE_TMP_ROOT/baddir/bad.json"
  mkdir -p "$SMOKE_TMP_ROOT/baddir"
  cat >"$bad" <<'EOF'
{ "bridge_id": "bad-node", "transport": { "kind": "tailscale" }, "listen": {}, "peers": "notalist" }
EOF
  chmod 0600 "$bad"
  local files_before files_after rc=0
  files_before="$(find "$SMOKE_TMP_ROOT/baddir" -maxdepth 1 | sort | tr '\n' ' ')"
  before="$(python3 -c "import hashlib; print(hashlib.md5(open('$bad','rb').read()).hexdigest())")"
  BRIDGE_A2A_CONFIG="$bad" python3 "$A2A_CLI" net-status --json >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "1" "$rc" "(4c) hard-invalid config -> nonzero diagnostic exit (no traceback)"
  files_after="$(find "$SMOKE_TMP_ROOT/baddir" -maxdepth 1 | sort | tr '\n' ' ')"
  smoke_assert_eq "$files_before" "$files_after" "(4c) net-status created NO files in the config dir"
  after="$(python3 -c "import hashlib; print(hashlib.md5(open('$bad','rb').read()).hexdigest())")"
  smoke_assert_eq "$before" "$after" "(4c) net-status did NOT mutate the invalid config"
}

# === (5) no secrets leak into output =========================================
check_no_secrets() {
  local cfg="$SMOKE_TMP_ROOT/sec.json"
  cat >"$cfg" <<'EOF'
{
  "bridge_id": "sec-node",
  "transport": { "kind": "tailscale" },
  "listen": { "address": "100.64.0.5", "port": 8787, "secret": "LISTENSECRETZZZ" },
  "peers": [ { "id": "p1", "address": "100.64.0.6", "node_id": "n1", "secret": "PEERSECRETZZZ", "send_secret": "SENDSECRETZZZ" } ]
}
EOF
  chmod 0600 "$cfg"
  local ts; ts="$(write_mock_tailscale)"
  local jout pout
  jout="$(BRIDGE_A2A_TAILSCALE_CLI="$ts" net_status "$cfg" json)"
  pout="$(BRIDGE_A2A_TAILSCALE_CLI="$ts" net_status "$cfg" plain)"
  printf '%s%s' "$jout" "$pout" | helper no-secrets "LISTENSECRETZZZ,PEERSECRETZZZ,SENDSECRETZZZ" >/dev/null \
    && smoke_log "ok-no-secrets" \
    || smoke_fail "(5) a secret leaked into net-status output"
}

# === (6) #1701 consistency: warp held socket -> receiver healthz=healthy ======
check_1701_warp_receiver_alive() {
  local port; port="$(helper free-port)"
  local cfg="$SMOKE_TMP_ROOT/warp-held.json"
  # Loopback listen so resolve_bind succeeds under BRIDGE_A2A_ALLOW_TEST_BIND=1
  # (the same test-bind escape hatch 1701 + 1595 use); the held socket on this
  # (127.0.0.1, port) trips the cmd_healthz warp socket-held fallback.
  cat >"$cfg" <<EOF
{
  "bridge_id": "warp-held",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "address": "127.0.0.1", "port": ${port}, "healthz_path": "/healthz" },
  "peers": []
}
EOF
  chmod 0600 "$cfg"
  # Also drop a live handoffd.pid so the pid-alive leg is populated (this very
  # process is alive); the healthz verdict is what proves the #1701 reuse.
  mkdir -p "$BRIDGE_HOME/state/handoff"
  printf '%s\n' "$$" >"$BRIDGE_HOME/state/handoff/handoffd.pid" 2>/dev/null || true
  local out
  out="$(helper net-status-held "$cfg" "127.0.0.1" "$port" "2")"
  echo "$out" | helper receiver-healthz "healthy" >/dev/null \
    && smoke_log "ok-1701" \
    || smoke_fail "(6) #1701: warp-mesh held-socket receiver should report receiver.healthz=healthy (not healthz_timeout); got: $out"
  echo "$out" | helper substrate-checked "cloudflare-warp-mesh" >/dev/null \
    || smoke_fail "(6) #1701 case substrate.checked != cloudflare-warp-mesh; got: $out"
}

# === (7) fail-soft: a warp iface-enum failure records a NON-None error ========
# BLOCKING-2 fix: `error` is pre-seeded to None, so the iface-enum except branch
# must use `or`-assignment, not setdefault (a no-op on an existing key) — else a
# real probe failure silently reports error=None, violating the contract that
# every probe failure records an error string.
check_warp_iface_fail_records_error() {
  # (7a) No prior error: the iface-enum failure must POPULATE error (not None).
  helper substrate-iface-fail none \
    | helper substrate-error-nonnull "iface_enum_failed" >/dev/null \
    && smoke_log "ok-iface-fail-records" \
    || smoke_fail "(7a) warp iface-enum failure must record a NON-None error string (BLOCKING-2)"
  # (7b) A pre-existing warp_cli error must be PRESERVED, not clobbered.
  helper substrate-iface-fail warp \
    | helper substrate-error-nonnull "warp-cli not found" >/dev/null \
    && smoke_log "ok-iface-fail-preserves-warp" \
    || smoke_fail "(7b) a prior warp_cli error must be preserved (the iface-enum branch must not clobber it)"
}

# === (8) static teeth: registration + read-only probe primitives =============
check_static_read_only() {
  local src; src="$(cat "$A2A_CLI")"
  smoke_assert_contains "$src" "def cmd_net_status" \
    "(8) cmd_net_status handler exists"
  smoke_assert_contains "$src" '("net-status", "status")' \
    "(8) net-status + status alias both registered to the same handler"
  smoke_assert_contains "$src" "os.kill(pid, 0)" \
    "(8) receiver liveness is a SIGNAL-0 existence check (no mutation)"
  smoke_assert_contains "$src" "_a2a_local_healthz(cfg, timeout)" \
    "(8) healthz verdict delegates to the shared helper (inherits #1701 fallback)"
  # No mutating primitives in the net-status code region: assert the handler
  # does not write the config / send a signal other than 0 / open a server.
  smoke_assert_not_contains "$src" "write_config_atomic(.*net" \
    "(8) net-status never writes config"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1697-a2a-net-status"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "(1) net-status --json returns the stable transport/listen/receiver/substrate/peers/rooms shape" check_stable_shape
  smoke_run "(2) ACTIVE-TRANSPORT-ONLY: WARP config never executes tailscale (dead-Tailscale-restart bug killed)" check_warp_no_tailscale_probe
  smoke_run "(3) ACTIVE-TRANSPORT-ONLY: Tailscale config takes the tailscale probe path" check_tailscale_probe_path
  smoke_run "(4) malformed/missing transport config degrades safely with NO state mutation" check_malformed_safe_no_mutation
  smoke_run "(5) NO SECRETS: listen/peer secrets never leak into plain or JSON output" check_no_secrets
  smoke_run "(6) #1701 consistency: warp held-socket receiver reported healthy (not healthz_timeout)" check_1701_warp_receiver_alive
  smoke_run "(7) fail-soft: warp iface-enum failure records a NON-None error (BLOCKING-2)" check_warp_iface_fail_records_error
  smoke_run "(8) static: net-status registered + read-only probe primitives" check_static_read_only

  smoke_log "passed"
}

main "$@"
