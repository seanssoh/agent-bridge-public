#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1891-iso-create-path-completeness.sh — Issue #1891
# (iso-v2 create-path completeness, facets F1 + F3a).
#
# Later-created (Jun-4+) iso-v2 agents finished provisioning with an
# INCOMPLETE create-path:
#   F1: `workdir/memory/` (and `home/memory/`) left controller-owned
#       `2700` (no group bits) instead of the header-matrix contract
#       (owner=agent-bridge-<a>, group=ab-agent-<a>, mode 2770 dirs /
#       0660 files, EXCEPT `index.sqlite` which stays controller-owned
#       0600). The iso UID could not read its OWN memory/ → daily harvest
#       failed. v0.16.10 reconcile did NOT repair the existing stale tree.
#   F3a: `state/agents/<a>/agent-meta.env` could be silently absent
#       (warn-only writer), so the daemon mis-detected the engine.
#
# The fix:
#   * `bridge_isolation_v2_normalize_memory_tree` (lib/bridge-isolation-v2.sh)
#     normalizes the iso-owned `memory/` trees under BOTH home and workdir,
#     INCLUDING an existing stale `2700` subtree, while keeping
#     `index.sqlite` controller-owned 0600 (the recursive helper gained a
#     `--exclude-name` prune; the normalize re-asserts 0600 on index.sqlite).
#   * Both the create path (bridge_linux_prepare_agent_isolation,
#     lib/bridge-agents.sh) and reapply (bridge_isolation_v2_reapply_one_agent,
#     lib/bridge-isolation-v2-reapply.sh) call the normalize.
#   * agent-meta.env write became a VISIBLE/NONZERO failure on create
#     (return 1) and a hard error row on reapply (errors_file →
#     dispatch rc=1), via `bridge_isolation_v2_verify_agent_metadata`.
#
# Two layers, in order:
#
#   T1..T7 — Source-structure assertions (host-agnostic, no sudo, no
#            useradd). Pin that the create + reapply paths call the new
#            normalize, exclude index.sqlite from the broad recursive
#            pass, and that agent-meta absence is no longer warn-only.
#
#   T8     — Functional normalize on a fixture tree. `memory/` is a
#            controller-owned tree (no real iso UID needed); forcing
#            `BRIDGE_ISOLATION_REQUIRED=yes` makes the recursive helper
#            run its chgrp/chmod on EVERY host (incl. macOS — the helper's
#            find -exec path is the same one Linux runs). Plant a stale
#            `2700` memory tree + an `index.sqlite` at 0600, run the
#            normalize, then assert: dirs → 2770, files → 0660,
#            index.sqlite stays 0600. This is the real before/after the
#            fix guarantees, exercisable without root.
#
#   T9     — `--exclude-name` prune is honored by the recursive helper +
#            its verify partner (a file matching the excluded basename is
#            NOT relaxed and does NOT register as a verify mismatch).
#
# Footgun #11 (heredoc-stdin deadlock class): every harness file is
# built via `printf '%s\n' >file` per line; no `<<EOF` to subprocess.

set -uo pipefail

SMOKE_NAME="1891-iso-create-path-completeness"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
ISO_V2="$REPO_ROOT/lib/bridge-isolation-v2.sh"
REAPPLY="$REPO_ROOT/lib/bridge-isolation-v2-reapply.sh"
AGENTS="$REPO_ROOT/lib/bridge-agents.sh"

# shellcheck disable=SC2329  # invoked via trap below
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd bash
smoke_require_cmd stat

for f in "$ISO_V2" "$REAPPLY" "$AGENTS"; do
  [[ -r "$f" ]] || smoke_fail "cannot read source: $f"
done

# ---------------------------------------------------------------------
# T1 — the dedicated memory normalize helper exists.
# ---------------------------------------------------------------------
grep -q "^bridge_isolation_v2_normalize_memory_tree()" "$ISO_V2" \
  || smoke_fail "T1 bridge_isolation_v2_normalize_memory_tree not defined in bridge-isolation-v2.sh"
smoke_log "ok: T1 normalize_memory_tree helper defined"

# ---------------------------------------------------------------------
# T2 — the recursive chgrp/chmod helper supports --exclude-name (so
#      index.sqlite can be pruned from the broad memory walk).
# ---------------------------------------------------------------------
grep -q -- "--exclude-name" "$ISO_V2" \
  || smoke_fail "T2 --exclude-name option not present in bridge-isolation-v2.sh"
smoke_log "ok: T2 chgrp_setgid_recursive honors --exclude-name"

# ---------------------------------------------------------------------
# T3 — create path (bridge-agents.sh) calls the memory normalize AND
#      excludes index.sqlite from the broad #1506 recursive pass.
# ---------------------------------------------------------------------
grep -q "bridge_isolation_v2_normalize_memory_tree" "$AGENTS" \
  || smoke_fail "T3 create path does not call normalize_memory_tree"
grep -Eq "exclude-name[[:space:]]+index\.sqlite" "$AGENTS" \
  || smoke_fail "T3 create path broad recursive pass does not exclude index.sqlite"
smoke_log "ok: T3 create path normalizes memory/ + excludes index.sqlite"

# ---------------------------------------------------------------------
# T4 — reapply path calls the memory normalize AND excludes index.sqlite.
# ---------------------------------------------------------------------
grep -q "bridge_isolation_v2_normalize_memory_tree" "$REAPPLY" \
  || smoke_fail "T4 reapply path does not call normalize_memory_tree"
grep -Eq "exclude-name[[:space:]]+index\.sqlite" "$REAPPLY" \
  || smoke_fail "T4 reapply broad recursive pass does not exclude index.sqlite"
smoke_log "ok: T4 reapply path normalizes memory/ + excludes index.sqlite"

# ---------------------------------------------------------------------
# T5 — agent-meta.env became a visible/nonzero failure (NOT warn-only)
#      on the create path: a verifier exists and prepare returns 1 when
#      write or verify fails.
# ---------------------------------------------------------------------
grep -q "^bridge_isolation_v2_verify_agent_metadata()" "$ISO_V2" \
  || smoke_fail "T5 verify_agent_metadata not defined"
grep -q "bridge_isolation_v2_verify_agent_metadata" "$AGENTS" \
  || smoke_fail "T5 create path does not verify agent-meta.env"
# The create-path block must `return 1` on a meta write/verify miss, not
# just bridge_warn. Extract the agent-meta block and assert a return 1.
T5_BLOCK="$SMOKE_TMP_ROOT/agents-meta-block.txt"
awk '/Lane A \(v0.15.0-beta4\): write the sanitized/{inb=1}
     inb==1{print}
     inb==1 && /Issue #1533 \(run LAST in prepare/{exit}' "$AGENTS" >"$T5_BLOCK"
[[ -s "$T5_BLOCK" ]] || smoke_fail "T5 could not extract create-path agent-meta block"
grep -q "agent-meta.env write FAILED" "$T5_BLOCK" \
  || smoke_fail "T5 create-path agent-meta write failure is not surfaced"
grep -Eq "return 1" "$T5_BLOCK" \
  || smoke_fail "T5 create-path agent-meta block does not return 1 on failure (still warn-only?)"
smoke_log "ok: T5 create-path agent-meta.env absence is a hard failure"

# ---------------------------------------------------------------------
# T6 — reapply agent-meta.env block records a hard error row + writes an
#      errors_file line on write/verify failure (dispatch exits nonzero),
#      not a silent warn.
# ---------------------------------------------------------------------
grep -q "bridge_isolation_v2_verify_agent_metadata" "$REAPPLY" \
  || smoke_fail "T6 reapply path does not verify agent-meta.env"
grep -q "error:verify_failed" "$REAPPLY" \
  || smoke_fail "T6 reapply agent-meta verify failure is not a hard error row"
smoke_log "ok: T6 reapply agent-meta.env absence is a hard error row"

# ---------------------------------------------------------------------
# T7 — the normalize keeps index.sqlite controller-owned 0600 by design:
#      the helper re-asserts 0600 on the index DB after the recursive pass
#      skipped it. Pin the surgical contract (no recursive group-open of
#      every file — criterion 2).
# ---------------------------------------------------------------------
grep -q "chmod 0600" "$ISO_V2" \
  || smoke_fail "T7 normalize does not re-assert 0600 on index.sqlite"
smoke_log "ok: T7 index.sqlite 0600 re-assert present"

# ---------------------------------------------------------------------
# T8 — functional: normalize a stale 2700 memory fixture and assert the
#      post-state. Controller-owned tree + forced enforcement so the
#      chgrp/chmod find passes actually run on every host.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # sourced-module warn stub
bridge_warn() { printf '[smoke:%s][warn] %s\n' "$SMOKE_NAME" "$*" >&2; }

T8_GRP="$(id -gn)"
T8_ROOT="$SMOKE_TMP_ROOT/t8"
mkdir -p "$T8_ROOT/workdir/memory/daily" "$T8_ROOT/home/memory"
printf 'note\n'  >"$T8_ROOT/workdir/memory/notes.md"
printf 'day\n'   >"$T8_ROOT/workdir/memory/daily/2026.md"
printf 'db\n'    >"$T8_ROOT/workdir/memory/index.sqlite"
printf 'hnote\n' >"$T8_ROOT/home/memory/notes.md"
# Stale pre-fix shape: controller-owned 2700 dirs, 0600 files.
chmod 2700 "$T8_ROOT/workdir/memory" "$T8_ROOT/workdir/memory/daily" "$T8_ROOT/home/memory"
chmod 0600 "$T8_ROOT/workdir/memory/notes.md" "$T8_ROOT/workdir/memory/daily/2026.md" \
           "$T8_ROOT/workdir/memory/index.sqlite" "$T8_ROOT/home/memory/notes.md"

# Source the iso-v2 module standalone with v2 active + forced enforce.
(
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$T8_ROOT/data"
  export BRIDGE_ISOLATION_REQUIRED=yes
  # shellcheck source=lib/bridge-isolation-discriminator.sh
  source "$REPO_ROOT/lib/bridge-isolation-discriminator.sh" 2>/dev/null || true
  # shellcheck source=lib/bridge-isolation-v2.sh
  source "$ISO_V2" 2>/dev/null || true
  command -v bridge_isolation_v2_normalize_memory_tree >/dev/null 2>&1 \
    || { printf 'T8 normalize helper not loadable\n' >&2; exit 3; }
  bridge_isolation_v2_enforce \
    || { printf 'T8 enforce did not engage under REQUIRED=yes\n' >&2; exit 4; }
  bridge_isolation_v2_normalize_memory_tree "$T8_GRP" \
    "$T8_ROOT/home/memory" "$T8_ROOT/workdir/memory" \
    || { printf 'T8 normalize returned non-zero\n' >&2; exit 5; }
) || smoke_fail "T8 normalize sub-shell failed (see preceding output)"

# Portable mode helpers (repo canon — scripts/smoke/1506-isolate-normalize.sh).
# GNU `stat -c '%a'` first (Linux CI), BSD `stat -f '%Lp'` fallback. Two reasons
# BSD-first single-mode was wrong here (#1891 CI fix):
#   1. On Linux, BSD `stat -f` is --file-system and returns garbage exit-0, so a
#      `stat -f ... || stat -c` fallback never fires.
#   2. BSD `%Lp` reports only the permission bits and DROPS the setgid bit, so a
#      directory normalized to 2770 reads back as 770 on macOS. Assert the low
#      bits via t8_low and the setgid bit SEPARATELY via t8_has_setgid.
t8_mode() {  # clean low-bits octal (files: setgid never set, so safe for 8# math)
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
t8_low() {  # last 3 octal digits (strip any GNU leading setgid digit)
  local m; m="$(t8_mode "$1")"
  printf '%s' "${m: -3}"
}
t8_has_setgid() {  # 0 when the setgid bit is set, portably
  local p="$1" gnu_mode perms
  gnu_mode="$(stat -c '%a' "$p" 2>/dev/null || printf '')"
  if [[ -n "$gnu_mode" ]]; then
    case "$gnu_mode" in 2*|3*|6*|7*) return 0 ;; *) return 1 ;; esac
  fi
  # shellcheck disable=SC2012  # single known path, not a glob expansion
  perms="$(ls -ld "$p" 2>/dev/null | awk '{print $1}')"
  case "$perms" in ??????[sS]*) return 0 ;; *) return 1 ;; esac
}
t8_dir_assert() {  # dir contract: low bits 770 + setgid set (2770)
  local path="$1" got
  got="$(t8_low "$path")"
  [[ "$got" == "770" ]] || smoke_fail "T8 dir low-bits mismatch at $path: expected 770, got ${got:-<empty>}"
  t8_has_setgid "$path" || smoke_fail "T8 dir missing setgid at $path (expected 2770)"
}
t8_file_assert() {  # file contract: exact low bits, no setgid
  local path="$1" want="$2" got
  got="$(t8_low "$path")"
  [[ "$got" == "$want" ]] || smoke_fail "T8 file mode mismatch at $path: expected $want, got ${got:-<empty>}"
}
t8_dir_assert "$T8_ROOT/workdir/memory"
t8_dir_assert "$T8_ROOT/workdir/memory/daily"
t8_dir_assert "$T8_ROOT/home/memory"
t8_file_assert "$T8_ROOT/workdir/memory/notes.md"      660
t8_file_assert "$T8_ROOT/workdir/memory/daily/2026.md" 660
t8_file_assert "$T8_ROOT/home/memory/notes.md"         660
# Criterion 2: index.sqlite keeps its restrictive 0600 (no group read).
t8_file_assert "$T8_ROOT/workdir/memory/index.sqlite"  600
# Group assertion (criterion 4 — group, not just mode): the normalized
# memory/ entries carry the group we passed; index.sqlite must NOT (0600 has
# no group bits, but the chgrp would still have set the group name — the
# exclude prevents that, so the index keeps the controller's *original*
# group, i.e. unchanged from fixture creation under the controller).
t8_grp() { stat -c '%G' "$1" 2>/dev/null || stat -f '%Sg' "$1" 2>/dev/null; }
t8_owner() { stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null; }
[[ "$(t8_grp "$T8_ROOT/workdir/memory")" == "$T8_GRP" ]] \
  || smoke_fail "T8 memory dir group not normalized to $T8_GRP (got $(t8_grp "$T8_ROOT/workdir/memory"))"
[[ "$(t8_grp "$T8_ROOT/workdir/memory/notes.md")" == "$T8_GRP" ]] \
  || smoke_fail "T8 memory file group not normalized to $T8_GRP (got $(t8_grp "$T8_ROOT/workdir/memory/notes.md"))"
# Owner of every memory entry stays the controller running the smoke (the
# normalize only chgrps the GROUP — it never chowns the owner; under live iso
# the owner was already set to the iso UID by prepare's chown -R, which this
# helper deliberately does not touch).
[[ "$(t8_owner "$T8_ROOT/workdir/memory/index.sqlite")" == "$(id -un)" ]] \
  || smoke_fail "T8 index.sqlite owner changed (normalize must not chown; got $(t8_owner "$T8_ROOT/workdir/memory/index.sqlite"))"
smoke_log "ok: T8 memory/ trees normalized 2770/0660 group=$T8_GRP, index.sqlite stays 0600 owner-unchanged"

# ---------------------------------------------------------------------
# T9 — the recursive helper's --exclude-name prune is honored by BOTH
#      the chmod pass and the verify partner (an excluded file is neither
#      relaxed nor flagged as a verify mismatch).
# ---------------------------------------------------------------------
T9_ROOT="$SMOKE_TMP_ROOT/t9"
mkdir -p "$T9_ROOT/sub"
printf 'a\n' >"$T9_ROOT/keep.md"
printf 'b\n' >"$T9_ROOT/sub/index.sqlite"
chmod 2700 "$T9_ROOT" "$T9_ROOT/sub"
chmod 0600 "$T9_ROOT/keep.md" "$T9_ROOT/sub/index.sqlite"
(
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$T9_ROOT/data"
  export BRIDGE_ISOLATION_REQUIRED=yes
  source "$REPO_ROOT/lib/bridge-isolation-discriminator.sh" 2>/dev/null || true
  # shellcheck source=lib/bridge-isolation-v2.sh
  source "$ISO_V2" 2>/dev/null || true
  T9_GRP="$(id -gn)"
  bridge_isolation_v2_chgrp_setgid_recursive "$T9_GRP" 2770 0660 "$T9_ROOT" \
    --exclude-name index.sqlite \
    || { printf 'T9 recursive helper returned non-zero (verify should still pass with the excluded file at 0600)\n' >&2; exit 6; }
) || smoke_fail "T9 recursive helper sub-shell failed (excluded file tripped verify?)"
t9_keep="$(t8_mode "$T9_ROOT/keep.md")"
t9_idx="$(t8_mode "$T9_ROOT/sub/index.sqlite")"
t9_keep="$(printf '%04o' "$((8#${t9_keep:-0}))")"
t9_idx="$(printf '%04o' "$((8#${t9_idx:-0}))")"
[[ "$t9_keep" == "0660" ]] || smoke_fail "T9 non-excluded file not relaxed (got $t9_keep)"
[[ "$t9_idx"  == "0600" ]] || smoke_fail "T9 excluded index.sqlite was relaxed (got $t9_idx)"
smoke_log "ok: T9 --exclude-name skips index.sqlite without tripping verify"

# ---------------------------------------------------------------------
# T10 — agent-meta.env verifier contract. The verifier must check
#       presence + mode 0640 + controller OWNER + group ab-agent-<a> +
#       iso-UID readability (criterion 3: visible/nonzero, secret-free).
#       Source-grep the four checks (a Linux+real-iso run is the live
#       proof; on macOS the verifier no-ops to a clean pass, so a
#       functional negative cannot be exercised here without a real iso
#       UID — assert the contract is present + that the verifier degrades
#       to success off-Linux rather than false-failing).
# ---------------------------------------------------------------------
grep -q "owner=\$cur_owner, expected controller" "$ISO_V2" \
  || smoke_fail "T10 verifier missing controller-owner check"
grep -Eq "expected 0640" "$ISO_V2" \
  || smoke_fail "T10 verifier missing mode 0640 check"
grep -q "cannot read .*group-read path broken" "$ISO_V2" \
  || smoke_fail "T10 verifier missing iso-UID readability check"
# The verifier must not log file CONTENTS (secret-free). It reads only
# stat metadata + a `test -r` probe; assert it never `cat`s the snippet.
T10_FN="$SMOKE_TMP_ROOT/verify-meta-fn.txt"
awk '/^bridge_isolation_v2_verify_agent_metadata\(\) \{/{inb=1}
     inb==1{print}
     inb==1 && /^}/{exit}' "$ISO_V2" >"$T10_FN"
[[ -s "$T10_FN" ]] || smoke_fail "T10 could not extract verify_agent_metadata body"
if grep -Eq "(^|[^a-zA-Z_])cat[[:space:]]+[\"']?\$meta_file" "$T10_FN"; then
  smoke_fail "T10 verifier reads snippet contents (must stay secret-free / metadata-only)"
fi
# Off-Linux degrade: the verifier returns 0 (clean) on a non-Linux host so it
# never false-fails on a dev box. Exercise it directly.
(
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$SMOKE_TMP_ROOT/t10-data"
  source "$REPO_ROOT/lib/bridge-isolation-discriminator.sh" 2>/dev/null || true
  # shellcheck source=lib/bridge-isolation-v2.sh
  source "$ISO_V2" 2>/dev/null || true
  command -v bridge_isolation_v2_verify_agent_metadata >/dev/null 2>&1 \
    || { printf 'T10 verifier not loadable\n' >&2; exit 7; }
  if [[ "$(uname)" != "Linux" ]]; then
    bridge_isolation_v2_verify_agent_metadata smoke-agent \
      || { printf 'T10 verifier false-failed on non-Linux host (should no-op clean)\n' >&2; exit 8; }
  fi
) || smoke_fail "T10 verifier off-Linux degrade check failed (see preceding output)"
smoke_log "ok: T10 agent-meta.env verifier checks owner+mode+readability, secret-free, off-Linux clean"

# ---------------------------------------------------------------------
# T11 — create-path ORDERING: the #1533 content-tree publisher runs LAST
#       and would re-relax a nested `memory/index.sqlite` to 0660 (its
#       excludes are top-level only). Prove the bug + the fix:
#         (a) run the real publisher walker directly → it relaxes
#             index.sqlite to 0660 (the exact regression);
#         (b) run normalize_memory_tree (the post-publisher step the create
#             path now performs LAST) → index.sqlite is restored to 0600,
#             the rest of memory/ stays 0660.
#       This is the false-green guard for the ordering: if a future change
#       drops the post-publisher normalize, (b) fails.
# ---------------------------------------------------------------------
T11_WALKER="$REPO_ROOT/scripts/python-helpers/isolation-normalize-content-tree.py"
if [[ ! -r "$T11_WALKER" ]]; then
  smoke_fail "T11 content-tree walker not found at $T11_WALKER"
fi
smoke_require_cmd python3
# Assert the create path actually re-runs the normalize AFTER the publisher.
grep -q "post-publish memory/ normalize" "$AGENTS" \
  || smoke_fail "T11 create path does not re-normalize memory/ AFTER the content-tree publisher (ordering regression)"
# Structural source-order proof (not just a marker grep): inside
# bridge_linux_prepare_agent_isolation, the LAST normalize_memory_tree call
# must appear AFTER the LAST publish_content_tree call. Extract the function
# body, then compare line positions. A future refactor that moves the
# re-normalize before the publisher (re-introducing the round-2 ordering bug)
# fails here even if the marker comment survives.
T11_FN="$SMOKE_TMP_ROOT/prepare-fn.txt"
awk '/^bridge_linux_prepare_agent_isolation\(\) \{/{inb=1}
     inb==1{print NR": "$0}
     inb==1 && /^}/{exit}' "$AGENTS" >"$T11_FN"
[[ -s "$T11_FN" ]] || smoke_fail "T11 could not extract bridge_linux_prepare_agent_isolation body"
t11_pub_line="$(grep -E "bridge_isolation_v2_publish_content_tree[[:space:]]+\\\\?$|bridge_isolation_v2_publish_content_tree[[:space:]]+\"" "$T11_FN" | tail -1 | cut -d: -f1)"
t11_norm_line="$(grep -E "bridge_isolation_v2_normalize_memory_tree[[:space:]]" "$T11_FN" | tail -1 | cut -d: -f1)"
if [[ -z "$t11_pub_line" || -z "$t11_norm_line" ]] || (( t11_norm_line <= t11_pub_line )); then
  smoke_fail "T11 source order: final normalize_memory_tree (line $t11_norm_line) is not after the last publish_content_tree (line $t11_pub_line) — ordering regression"
fi
smoke_log "ok: T11 source order: post-publisher memory normalize runs after the content-tree publisher (line $t11_norm_line > $t11_pub_line)"

T11_GRP="$(id -gn)"
T11_USR="$(id -un)"
T11_ROOT="$SMOKE_TMP_ROOT/t11"
mkdir -p "$T11_ROOT/workdir/memory"
printf 'n\n'  >"$T11_ROOT/workdir/memory/notes.md"
printf 'db\n' >"$T11_ROOT/workdir/memory/index.sqlite"
chmod 0600 "$T11_ROOT/workdir/memory/notes.md" "$T11_ROOT/workdir/memory/index.sqlite"
chmod 2770 "$T11_ROOT/workdir" "$T11_ROOT/workdir/memory"

# (a) the publisher walker relaxes index.sqlite (and notes.md) to 0660.
python3 "$T11_WALKER" "$T11_GRP" 0660 2770 "$T11_USR" "$T11_ROOT/workdir" \
  --controller-user "$T11_USR" >/dev/null 2>&1 \
  || smoke_fail "T11 publisher walker invocation failed"
t11_idx_after_pub="$(t8_mode "$T11_ROOT/workdir/memory/index.sqlite")"
t11_idx_after_pub="$(printf '%04o' "$((8#${t11_idx_after_pub:-0}))")"
[[ "$t11_idx_after_pub" == "0660" ]] \
  || smoke_fail "T11 precondition: publisher did NOT relax index.sqlite (got $t11_idx_after_pub) — the regression this ordering guards is not reproduced; test is meaningless"
smoke_log "ok: T11(a) publisher relaxes nested memory/index.sqlite to 0660 (regression reproduced)"

# (b) the post-publisher normalize restores index.sqlite to 0600.
(
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$T11_ROOT/data"
  export BRIDGE_ISOLATION_REQUIRED=yes
  source "$REPO_ROOT/lib/bridge-isolation-discriminator.sh" 2>/dev/null || true
  # shellcheck source=lib/bridge-isolation-v2.sh
  source "$ISO_V2" 2>/dev/null || true
  bridge_isolation_v2_normalize_memory_tree "$T11_GRP" "$T11_ROOT/workdir/memory" \
    || { printf 'T11 post-publisher normalize returned non-zero\n' >&2; exit 9; }
) || smoke_fail "T11 post-publisher normalize sub-shell failed"
t11_idx_final="$(t8_mode "$T11_ROOT/workdir/memory/index.sqlite")"
t11_notes_final="$(t8_mode "$T11_ROOT/workdir/memory/notes.md")"
t11_idx_final="$(printf '%04o' "$((8#${t11_idx_final:-0}))")"
t11_notes_final="$(printf '%04o' "$((8#${t11_notes_final:-0}))")"
[[ "$t11_idx_final"   == "0600" ]] || smoke_fail "T11 post-publisher normalize did NOT restore index.sqlite to 0600 (got $t11_idx_final)"
[[ "$t11_notes_final" == "0660" ]] || smoke_fail "T11 post-publisher normalize wrongly restricted a normal memory file (notes.md got $t11_notes_final)"
smoke_log "ok: T11(b) post-publisher normalize restores index.sqlite to 0600, keeps memory files 0660"

# ---------------------------------------------------------------------
# T12 — agent-meta.env carries the detected ENGINE (criterion 4). The
#       snippet's whole reason to exist is so the iso UID + daemon can
#       resolve the agent's engine/config_dir without reading the
#       protected roster. The writer emits `BRIDGE_AGENT_ENGINE=<engine>`
#       sourced from `bridge_agent_engine`. On macOS the writer no-ops
#       (Linux-gated), so:
#         (a) structurally assert the writer emits the engine field from
#             bridge_agent_engine (not a hardcoded literal);
#         (b) functionally assert the documented key=value snippet format
#             round-trips an engine value through a `grep '^KEY='` parse
#             (the same shape bridge-state.sh consumes), proving the
#             engine line is discoverable by the consumer contract.
# ---------------------------------------------------------------------
# (a) writer emits engine from bridge_agent_engine.
T12_WRITER_FN="$SMOKE_TMP_ROOT/write-meta-fn.txt"
awk '/^bridge_isolation_v2_write_agent_metadata\(\) \{/{inb=1}
     inb==1{print}
     inb==1 && /^}/{exit}' "$ISO_V2" >"$T12_WRITER_FN"
[[ -s "$T12_WRITER_FN" ]] || smoke_fail "T12 could not extract write_agent_metadata body"
grep -q "bridge_agent_engine" "$T12_WRITER_FN" \
  || smoke_fail "T12 writer does not source the engine from bridge_agent_engine"
grep -Eq "printf 'BRIDGE_AGENT_ENGINE=%s" "$T12_WRITER_FN" \
  || smoke_fail "T12 writer does not emit a BRIDGE_AGENT_ENGINE line"
# The consumer (bridge-lib.sh's sanitized-metadata loader) must parse the
# snippet and populate BRIDGE_AGENT_ENGINE — that is how the iso UID + daemon
# resolve the engine without the protected roster.
T12_CONSUMER="$REPO_ROOT/bridge-lib.sh"
grep -q "agent-meta.env" "$T12_CONSUMER" \
  || smoke_fail "T12 consumer (bridge-lib.sh) does not reference agent-meta.env"
grep -q "BRIDGE_AGENT_ENGINE" "$T12_CONSUMER" \
  || smoke_fail "T12 consumer (bridge-lib.sh) does not populate BRIDGE_AGENT_ENGINE from the snippet"
# (b) functional round-trip of the documented snippet format.
T12_META="$SMOKE_TMP_ROOT/agent-meta.env"
{
  printf '# Sanitized iso-UID-readable metadata snippet for agent=smoke\n'
  printf 'BRIDGE_AGENT_OS_USER=agent-bridge-smoke\n'
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=codex\n'
  printf 'BRIDGE_AGENT_HOME=/home/agent-bridge-smoke\n'
} >"$T12_META"
t12_engine="$(grep '^BRIDGE_AGENT_ENGINE=' "$T12_META" | head -1 | cut -d= -f2)"
[[ "$t12_engine" == "codex" ]] \
  || smoke_fail "T12 engine field not parseable from the snippet (got '$t12_engine')"
smoke_log "ok: T12 agent-meta.env carries the detected engine (writer emits it; consumer reads it; round-trips)"

smoke_log "all assertions passed"
exit 0
