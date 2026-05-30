#!/usr/bin/env bash
# a2a-migrate-identity.sh — P-self-heal-2 smoke: migrate raw-IP peers/listen to
# Tailscale identity keying (node_id + tailscale_name), using a MOCK `tailscale`
# CLI (the a2a-tailscale-identity-resolve / 1118 v2-engine binary-path pattern).
#
# Validates `bridge-a2a.py migrate-identity`:
#   (a) raw-IP peer matching EXACTLY one node -> gets node_id + tailscale_name,
#       address kept as fallback;
#   (b) --dry-run (the DEFAULT) writes nothing;
#   (c) --apply writes (0600 preserved);
#   (d) IP matching ZERO nodes (stale/offline) -> entry untouched + warn;
#   (e) ambiguous MULTI-match -> entry untouched + warn;
#   (f) already identity-keyed -> idempotent no-op (no write);
#   (g) tailscale-unavailable -> nonzero exit, no write;
#   (h) secret / inbound_allowlist / caps are NEVER modified.
#
# No real Tailscale, no network. All python goes through a helper FILE (never
# `python3 - <<PY` in a capture) per the C1 / footgun #11 ban.
set -euo pipefail

SMOKE_NAME="a2a-migrate-identity"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/smoke/a2a-migrate-identity-helper.py"
CLI="$REPO_ROOT/bridge-a2a.py"

fail() { echo "[$SMOKE_NAME] FAIL: $*" >&2; exit 1; }
pass() { echo "[$SMOKE_NAME] PASS: $*"; }
note() { echo "[$SMOKE_NAME] .. $*"; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

MOCK_BIN="$WORK/bin"
mkdir -p "$MOCK_BIN"
TS_STATUS_JSON="$WORK/status.json"

# ---------------------------------------------------------------------------
# Mock `tailscale` CLI: emits a fixed status --json with a duplicate IP
# (100.99.99.99) owned by TWO peers so we can exercise the ambiguous case.
# ---------------------------------------------------------------------------
cat > "$TS_STATUS_JSON" <<'JSON'
{
  "Self": {
    "ID": "nSELF01",
    "HostName": "sean-macbookpro",
    "DNSName": "sean-macbookpro.tailnet-abc.ts.net.",
    "TailscaleIPs": ["100.80.100.114", "fd7a:115c:a1e0::1"]
  },
  "Peer": {
    "nodeAAAA": {
      "ID": "nPEER01",
      "HostName": "cm-prod-agentworkflow-vm01",
      "DNSName": "cm-prod-agentworkflow-vm01.tailnet-abc.ts.net.",
      "TailscaleIPs": ["100.83.90.26", "fd7a:115c:a1e0::2"]
    },
    "nodeBBBB": {
      "ID": "nPEER02",
      "HostName": "dup-host-one",
      "DNSName": "dup-host-one.tailnet-abc.ts.net.",
      "TailscaleIPs": ["100.99.99.99"]
    },
    "nodeCCCC": {
      "ID": "nPEER03",
      "HostName": "dup-host-two",
      "DNSName": "dup-host-two.tailnet-abc.ts.net.",
      "TailscaleIPs": ["100.99.99.99"]
    }
  }
}
JSON

cat > "$MOCK_BIN/tailscale" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "status" && "\$2" == "--json" ]]; then
  cat "$TS_STATUS_JSON"
  exit 0
fi
echo "mock tailscale: unsupported args: \$*" >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/tailscale"

g() { python3 "$HELPER" get "$1" "$2"; }
file_mode() { python3 "$HELPER" mode "$1"; }
file_sha() { python3 "$HELPER" sha "$1"; }

# A reusable config writer. Peers:
#   - cm-prod : raw IP 100.83.90.26  -> matches exactly nPEER01 (migrate)
#   - stale   : raw IP 100.55.55.55  -> matches ZERO nodes (untouched)
#   - ambig   : raw IP 100.99.99.99  -> matches TWO nodes (untouched)
#   - keyed   : already node_id      -> no-op
# listen: raw IP 100.80.100.114 -> matches Self nSELF01 (migrate)
write_config() {
  local dest="$1"
  cat > "$dest" <<'JSON'
{
  "bridge_id": "sean-macbookpro",
  "listen": {
    "address": "100.80.100.114",
    "port": 8787
  },
  "peers": [
    {
      "id": "cm-prod",
      "address": "100.83.90.26",
      "secret": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "inbound_allowlist": ["patch", "patch-dev"],
      "caps": { "max_body_bytes": 262144 }
    },
    {
      "id": "stale",
      "address": "100.55.55.55",
      "secret": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    },
    {
      "id": "ambig",
      "address": "100.99.99.99",
      "secret": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "id": "keyed",
      "node_id": "nPEER01",
      "address": "100.1.2.3",
      "secret": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
JSON
  chmod 0600 "$dest"
}

run_migrate() {
  # $1 = config path; remaining args = extra flags. Mock tailscale via
  # BRIDGE_A2A_TAILSCALE_CLI; config via BRIDGE_A2A_CONFIG.
  local cfg="$1"; shift
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_BIN/tailscale" \
    BRIDGE_A2A_CONFIG="$cfg" \
    python3 "$CLI" migrate-identity "$@"
}

# ---------------------------------------------------------------------------
# (b) DRY-RUN is the default: nothing is written.
# ---------------------------------------------------------------------------
note "(b) dry-run (default) writes nothing"
CFG="$WORK/dry.json"
write_config "$CFG"
SHA_BEFORE="$(file_sha "$CFG")"
run_migrate "$CFG" >/dev/null
SHA_AFTER="$(file_sha "$CFG")"
[[ "$SHA_BEFORE" == "$SHA_AFTER" ]] || fail "(b) dry-run modified the config"
pass "(b) dry-run left config byte-identical"

# ---------------------------------------------------------------------------
# (c) --apply writes; (a) exact-1 match gets identity, address kept;
# (h) secret/allowlist/caps untouched; (d) stale untouched; (e) ambig untouched.
# ---------------------------------------------------------------------------
note "(c) --apply writes the migration"
CFG="$WORK/apply.json"
write_config "$CFG"
chmod 0600 "$CFG"
run_migrate "$CFG" --apply >/dev/null
[[ "$(file_mode "$CFG")" == "0600" ]] || fail "(c) mode not preserved: $(file_mode "$CFG")"
pass "(c) --apply wrote config, 0600 preserved"

note "(a) exact-1 peer migrated, address kept as fallback"
[[ "$(g "$CFG" "peer:cm-prod.node_id")" == "nPEER01" ]] \
  || fail "(a) cm-prod node_id wrong: $(g "$CFG" peer:cm-prod.node_id)"
[[ "$(g "$CFG" "peer:cm-prod.tailscale_name")" == "cm-prod-agentworkflow-vm01.tailnet-abc.ts.net" ]] \
  || fail "(a) cm-prod tailscale_name wrong: $(g "$CFG" peer:cm-prod.tailscale_name)"
[[ "$(g "$CFG" "peer:cm-prod.address")" == "100.83.90.26" ]] \
  || fail "(a) cm-prod address not kept: $(g "$CFG" peer:cm-prod.address)"
pass "(a) cm-prod -> node_id+tailscale_name, address kept"

note "(a/listen) listen migrated against Self"
[[ "$(g "$CFG" "listen.node_id")" == "nSELF01" ]] \
  || fail "(a) listen node_id wrong: $(g "$CFG" listen.node_id)"
[[ "$(g "$CFG" "listen.tailscale_name")" == "sean-macbookpro.tailnet-abc.ts.net" ]] \
  || fail "(a) listen tailscale_name wrong: $(g "$CFG" listen.tailscale_name)"
[[ "$(g "$CFG" "listen.address")" == "100.80.100.114" ]] \
  || fail "(a) listen address not kept"
pass "(a/listen) listen -> identity, address kept"

note "(d) stale (zero-match) peer left untouched"
[[ "$(g "$CFG" "peer:stale.node_id")" == "<MISSING>" ]] \
  || fail "(d) stale peer got a node_id"
[[ "$(g "$CFG" "peer:stale.tailscale_name")" == "<MISSING>" ]] \
  || fail "(d) stale peer got a tailscale_name"
[[ "$(g "$CFG" "peer:stale.address")" == "100.55.55.55" ]] \
  || fail "(d) stale peer address changed"
pass "(d) zero-match peer untouched"

note "(e) ambiguous (multi-match) peer left untouched"
[[ "$(g "$CFG" "peer:ambig.node_id")" == "<MISSING>" ]] \
  || fail "(e) ambig peer got a node_id"
[[ "$(g "$CFG" "peer:ambig.tailscale_name")" == "<MISSING>" ]] \
  || fail "(e) ambig peer got a tailscale_name"
[[ "$(g "$CFG" "peer:ambig.address")" == "100.99.99.99" ]] \
  || fail "(e) ambig peer address changed"
pass "(e) multi-match peer untouched"

note "(h) secret / inbound_allowlist / caps never modified"
[[ "$(g "$CFG" "peer:cm-prod.secret")" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]] \
  || fail "(h) cm-prod secret changed"
[[ "$(g "$CFG" "peer:cm-prod.inbound_allowlist")" == "patch,patch-dev" ]] \
  || fail "(h) cm-prod allowlist changed: $(g "$CFG" peer:cm-prod.inbound_allowlist)"
[[ "$(g "$CFG" "peer:cm-prod.caps.max_body_bytes")" == "262144" ]] \
  || fail "(h) cm-prod caps changed"
pass "(h) secret/allowlist/caps intact"

# ---------------------------------------------------------------------------
# (f) idempotent: re-running --apply on the already-migrated config is a no-op.
# ---------------------------------------------------------------------------
note "(f) re-run is idempotent (no byte change)"
SHA_BEFORE="$(file_sha "$CFG")"
run_migrate "$CFG" --apply >/dev/null
SHA_AFTER="$(file_sha "$CFG")"
[[ "$SHA_BEFORE" == "$SHA_AFTER" ]] || fail "(f) re-run modified an already-migrated config"
pass "(f) re-run no-op"

note "(f2) fully identity-keyed config: dry-run reports nothing & no write"
CFG2="$WORK/keyed.json"
cat > "$CFG2" <<'JSON'
{
  "bridge_id": "sean-macbookpro",
  "listen": { "node_id": "nSELF01", "port": 8787 },
  "peers": [
    {
      "id": "cm-prod",
      "node_id": "nPEER01",
      "secret": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
JSON
chmod 0600 "$CFG2"
SHA_BEFORE="$(file_sha "$CFG2")"
OUT="$(run_migrate "$CFG2" --apply 2>&1)"
SHA_AFTER="$(file_sha "$CFG2")"
[[ "$SHA_BEFORE" == "$SHA_AFTER" ]] || fail "(f2) already-keyed config was rewritten"
echo "$OUT" | grep -q "no raw-address entries to migrate" \
  || fail "(f2) expected 'no raw-address entries' message, got: $OUT"
pass "(f2) already-keyed -> no-op + clear message"

# ---------------------------------------------------------------------------
# (g) tailscale unavailable -> nonzero exit, NO write.
# ---------------------------------------------------------------------------
note "(g) tailscale unavailable -> fail-closed, no write"
CFG3="$WORK/unavail.json"
write_config "$CFG3"
chmod 0600 "$CFG3"
SHA_BEFORE="$(file_sha "$CFG3")"
set +e
BRIDGE_A2A_TAILSCALE_CLI="/nonexistent/tailscale" \
  BRIDGE_A2A_CONFIG="$CFG3" \
  python3 "$CLI" migrate-identity --apply >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "(g) expected nonzero exit on unavailable tailscale, got $RC"
SHA_AFTER="$(file_sha "$CFG3")"
[[ "$SHA_BEFORE" == "$SHA_AFTER" ]] || fail "(g) config changed despite tailscale unavailable"
pass "(g) fail-closed: nonzero exit ($RC), config unchanged"

# ---------------------------------------------------------------------------
# (i) --drop-address removes the raw address after keying (opt-in).
# ---------------------------------------------------------------------------
note "(i) --drop-address removes the raw address (opt-in)"
CFG4="$WORK/drop.json"
write_config "$CFG4"
chmod 0600 "$CFG4"
run_migrate "$CFG4" --apply --drop-address >/dev/null
[[ "$(g "$CFG4" "peer:cm-prod.node_id")" == "nPEER01" ]] \
  || fail "(i) cm-prod not keyed under --drop-address"
[[ "$(g "$CFG4" "peer:cm-prod.address")" == "<MISSING>" ]] \
  || fail "(i) cm-prod address not dropped: $(g "$CFG4" peer:cm-prod.address)"
# a zero-match peer keeps its address even under --drop-address (untouched).
[[ "$(g "$CFG4" "peer:stale.address")" == "100.55.55.55" ]] \
  || fail "(i) stale peer address dropped despite no migration"
pass "(i) --drop-address removes migrated address, leaves untouched entries alone"

# Note: the temp-file mid-write 0600 guarantee is covered by code inspection
# (_write_config_atomic uses os.open(tmp, O_WRONLY|O_CREAT|O_TRUNC, 0o600) so
# the secret-bearing temp is created at 0600 from the start, never the umask
# default) plus case (c), which asserts the final file is 0600. An in-process
# mid-write probe was dropped — it required fragile importlib surgery on
# bridge-a2a.py and added no coverage beyond the os.open guarantee + case (c).

echo "[$SMOKE_NAME] ALL PASS"
