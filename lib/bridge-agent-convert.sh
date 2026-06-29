#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/bridge-agent-convert.sh — FR #2061 Track A: the pure, roster-free
# migration engine that moves a Claude agent's config-dir-relative state
# (transcripts + subagents/workflows + project memory + per-agent
# auto-memory) from one CLAUDE_CONFIG_DIR tree to another when a dynamic
# agent is converted to a static roster role.
#
# Why this exists (the silent-data-loss trap): a dynamic *vanilla* Claude
# agent launches with NO per-agent CLAUDE_CONFIG_DIR — it reads the
# operator-global ~/.claude (bridge_agent_is_dynamic_vanilla_claude +
# bridge_resolve_agent_claude_config_dir short-circuit). A static agent
# reads an isolated <agent-home>/.claude. Flipping the roster without
# moving the state strands every transcript + memory file under the
# operator HOME while the converted agent boots empty. This engine builds
# a zero-omission manifest of that state and copies it (source untouched)
# into the target config dir, with an on-disk backup + internal rollback.
#
# Design contract (plan #2061 §0, BINDING):
#   - Copy, never move (§0.5 Q2): the source tree is left intact and an
#     orphan/source-path report is emitted for manual prune after soak.
#   - Three-class source resolver (§2): dynamic-vanilla -> operator ~/.claude,
#     else the agent's own config dir.
#   - Target derived as-if-static (§0.1 step 2): bridge_agent_claude_config_dir
#     does NOT consult source=, so it yields the static target WITHOUT a
#     roster pre-flip.
#   - Internal-only rollback (§0.4): bridge_convert_rollback is invoked by the
#     convert orchestrator's failure path, not a user-facing CLI verb in MVP.
#   - iso-target fail-closed (§0.5 Q5): MVP supports macOS/shared-mode targets
#     only; an iso-effective target is rejected with a clear message.
#
# This module is PURE: bridge_convert_build_manifest / _apply_manifest /
# _rollback depend only on python3 + the passed-in directories, so they are
# fully smoke-testable against a fabricated ~/.claude with no live agent.
# Only bridge_convert_resolve_config_dirs needs the roster (it calls the same
# bridge_agent_* predicates launch + resume-detection use).
#
# The Track B `convert` verb / roster flip / resume-pin (Tracks B/C) live in
# bridge-agent.sh / bridge-state.sh and call INTO this engine — they are NOT
# defined here.

# Idempotent source guard: this file is sourced both by the smoke (directly)
# and, once Track B lands, by bridge-lib.sh.
if [[ -z "${_BRIDGE_AGENT_CONVERT_SH_LOADED:-}" ]]; then
_BRIDGE_AGENT_CONVERT_SH_LOADED=1

# ---------------------------------------------------------------------------
# Embedded python (Pattern B: python3 -c "$VAR" argv — never heredoc-stdin, so
# it cannot wedge in the Bash 5.3.9 heredoc_write deadlock under $(...), and
# never a single quote inside the single-quoted body). Structured tree walks,
# JSON, and byte-hash work belong in python per the repo convention.
# ---------------------------------------------------------------------------

# _BRIDGE_CONVERT_SCAN_PY — cwd enumeration + manifest build (one source of
# truth for the slug/cwd classification, mirroring
# scripts/python-helpers/detect-claude-session-id.py:82-108).
#
# argv: mode source target workdir slug include_csv
#   mode        — "enumerate" (print TSV) | "manifest" (print JSON)
#   agent       — agent id (auto-memory subdir + manifest label)
#   source      — source CLAUDE_CONFIG_DIR
#   target      — target CLAUDE_CONFIG_DIR ("" for enumerate)
#   workdir     — the agent workdir (auto-include cwd-or-descendant)
#   slug        — $BRIDGE_HOME auto-memory slug ("" for enumerate)
#   include_csv — comma-separated outside-workdir cwds confirmed via --include-cwd
_BRIDGE_CONVERT_SCAN_PY='
import json
import os
import re
import sys

mode = sys.argv[1]
agent = sys.argv[2]
source = sys.argv[3]
target = sys.argv[4]
workdir = os.path.realpath(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else ""
slug = sys.argv[6] if len(sys.argv) > 6 else ""
include = set()
if len(sys.argv) > 7 and sys.argv[7]:
    for raw in sys.argv[7].split(","):
        if raw:
            include.add(os.path.realpath(raw))


def slug_candidates(path):
    out = []
    for cand in (path.replace("/", "-"), re.sub(r"[/.]", "-", path), re.sub(r"[/._]", "-", path)):
        if cand not in out:
            out.append(cand)
    return out


def transcript_cwd(proj_dir):
    try:
        names = sorted(os.listdir(proj_dir))
    except OSError:
        return ""
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(proj_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                seen = 0
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    seen += 1
                    try:
                        obj = json.loads(line)
                    except Exception:
                        if seen >= 20:
                            break
                        continue
                    if isinstance(obj, dict) and obj.get("cwd"):
                        return str(obj.get("cwd"))
                    if seen >= 20:
                        break
        except OSError:
            continue
    return ""


def is_within(child, parent):
    if not child or not parent:
        return False
    if child == parent:
        return True
    return child.startswith(parent + os.sep)


projects_root = os.path.join(source, "projects")
wd_slugs = set(slug_candidates(workdir)) if workdir else set()
selected = []
skipped = []
if os.path.isdir(projects_root):
    for name in sorted(os.listdir(projects_root)):
        pdir = os.path.join(projects_root, name)
        if not os.path.isdir(pdir):
            continue
        cwd_raw = transcript_cwd(pdir)
        cwd_real = os.path.realpath(cwd_raw) if cwd_raw else ""
        if cwd_real and is_within(cwd_real, workdir):
            status = "include"
        elif cwd_real and cwd_real in include:
            status = "include"
        elif (not cwd_real) and name in wd_slugs:
            status = "include"
            cwd_real = workdir
        else:
            status = "candidate"
        if status == "include":
            selected.append((name, cwd_real))
        else:
            skipped.append({"slug": name, "cwd": cwd_real or cwd_raw})

if mode == "enumerate":
    for name, cwd in selected:
        sys.stdout.write("include\t" + name + "\t" + cwd + "\n")
    for row in skipped:
        sys.stdout.write("candidate\t" + row["slug"] + "\t" + str(row["cwd"]) + "\n")
    sys.exit(0)


def categorize(rel):
    parts = rel.split(os.sep)
    if "subagents" in parts:
        return "subagent"
    if "workflows" in parts:
        return "workflow"
    if "memory" in parts:
        return "memory"
    if rel.endswith(".jsonl") and len(parts) == 3:
        return "transcript"
    return "project-other"


files = []


def add_tree(base, category_fn):
    if not os.path.isdir(base):
        return
    for root, dirs, names in os.walk(base):
        dirs.sort()
        for name in sorted(names):
            fp = os.path.join(root, name)
            if os.path.islink(fp) or not os.path.isfile(fp):
                continue
            rel = os.path.relpath(fp, source)
            try:
                size = os.path.getsize(fp)
            except OSError:
                size = 0
            files.append({
                "rel": rel,
                "src": fp,
                "dest": os.path.join(target, rel),
                "size": size,
                "category": category_fn(rel),
            })


for name, _cwd in selected:
    add_tree(os.path.join(projects_root, name), categorize)

if slug and agent:
    add_tree(os.path.join(source, "auto-memory", slug, agent), lambda rel: "auto-memory")

manifest = {
    "agent": agent,
    "source_config_dir": source,
    "target_config_dir": target,
    "workdir": workdir,
    "bridge_home_slug": slug,
    "included_cwds": [{"slug": n, "cwd": c} for n, c in selected],
    "skipped_cwds": skipped,
    "files": files,
    "total_files": len(files),
    "total_bytes": sum(f["size"] for f in files),
}
print(json.dumps(manifest, indent=2, sort_keys=True))
'

# _BRIDGE_CONVERT_APPLY_PY — backup + copy (mtime-preserving, idempotent).
# argv: manifest_file backup_dir
_BRIDGE_CONVERT_APPLY_PY='
import hashlib
import json
import os
import sys

CHUNK = 65536

manifest_path = sys.argv[1]
backup_dir = sys.argv[2]

with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

target = manifest.get("target_config_dir", "")
files = manifest.get("files", [])


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_nofollow(src, dest, mode, atime, mtime):
    # Write dest with O_NOFOLLOW so a symlink swapped in at the final component
    # AFTER the dest_is_safe pre-check cannot redirect the write outside the
    # target tree (closes the TOCTOU window codex r2 flagged). mode + mtimes are
    # set on the fd, never re-opening dest by path.
    sfd = os.open(src, os.O_RDONLY)
    try:
        dfd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            while True:
                chunk = os.read(sfd, CHUNK)
                if not chunk:
                    break
                os.write(dfd, chunk)
            try:
                os.fchmod(dfd, mode & 0o777)
            except OSError:
                pass
            os.utime(dfd, (atime, mtime))
        finally:
            os.close(dfd)
    finally:
        os.close(sfd)


def backup_nofollow(dest, bpath):
    # Read the existing dest with O_NOFOLLOW so a symlinked dest is never backed
    # up THROUGH the link; the backup lands under the controlled backup dir.
    sfd = os.open(dest, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(sfd)
        os.makedirs(os.path.dirname(bpath), exist_ok=True)
        with open(bpath, "wb") as out:
            while True:
                chunk = os.read(sfd, CHUNK)
                if not chunk:
                    break
                out.write(chunk)
        os.utime(bpath, (st.st_atime, st.st_mtime))
    finally:
        os.close(sfd)


def dest_is_safe(dest):
    # Fail-closed against symlink traversal: the target config dir must be a
    # real directory (never a symlink), and no existing component BELOW it on
    # the way to dest may be a symlink. Otherwise a pre-existing link could
    # redirect a backup/copy write outside the target config tree.
    if not target or os.path.islink(target):
        return False
    rel = os.path.relpath(dest, target)
    if rel == ".." or rel.startswith(".." + os.sep):
        return False
    cur = target
    for part in rel.split(os.sep):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return False
    return True


# Persist the recovery state BEFORE any mutation (codex r2 item 1): the manifest
# + the target land first, and each mutation is journaled INTENT-FIRST to
# apply-journal.jsonl as it happens, so a crash mid-copy is still fully
# rollback-recoverable (the journal already names every started write).
os.makedirs(backup_dir, exist_ok=True)
overwritten_root = os.path.join(backup_dir, "overwritten")
with open(os.path.join(backup_dir, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
with open(os.path.join(backup_dir, "apply-meta.json"), "w", encoding="utf-8") as fh:
    json.dump({"target_config_dir": target}, fh, indent=2, sort_keys=True)
journal = open(os.path.join(backup_dir, "apply-journal.jsonl"), "a", encoding="utf-8")


def record(rec):
    journal.write(json.dumps(rec, sort_keys=True) + "\n")
    journal.flush()
    os.fsync(journal.fileno())


log = []
created = 0
overwrote = 0
skipped = 0
missing = 0
unsafe = 0
for entry in files:
    src = entry["src"]
    dest = entry["dest"]
    rel = entry["rel"]
    if not os.path.isfile(src) or os.path.islink(src):
        log.append({"rel": rel, "dest": dest, "action": "missing-src"})
        missing += 1
        continue
    if not dest_is_safe(dest):
        log.append({"rel": rel, "dest": dest, "action": "unsafe-dest"})
        unsafe += 1
        continue
    try:
        st = os.stat(src)
        existed = os.path.isfile(dest) and not os.path.islink(dest)
        if existed and os.path.getsize(src) == os.path.getsize(dest) and sha256(src) == sha256(dest):
            log.append({"rel": rel, "dest": dest, "action": "skip"})
            skipped += 1
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if existed:
            bpath = os.path.join(overwritten_root, rel)
            backup_nofollow(dest, bpath)
            record({"action": "overwrite", "dest": dest, "backup": bpath})
            copy_nofollow(src, dest, st.st_mode, st.st_atime, st.st_mtime)
            log.append({"rel": rel, "dest": dest, "action": "overwrote", "backup": bpath})
            overwrote += 1
        else:
            record({"action": "create", "dest": dest})
            copy_nofollow(src, dest, st.st_mode, st.st_atime, st.st_mtime)
            log.append({"rel": rel, "dest": dest, "action": "created"})
            created += 1
    except OSError as exc:
        # A symlink swapped in after the pre-check fails the O_NOFOLLOW open
        # here — record it unsafe and fail closed rather than write outside.
        log.append({"rel": rel, "dest": dest, "action": "unsafe-dest", "error": str(exc)})
        unsafe += 1

journal.close()
with open(os.path.join(backup_dir, "apply-log.json"), "w", encoding="utf-8") as fh:
    json.dump({"target_config_dir": target, "entries": log}, fh, indent=2, sort_keys=True)

result = {
    "backup_dir": backup_dir,
    "created": created,
    "overwrote": overwrote,
    "skipped": skipped,
    "missing_src": missing,
    "unsafe_dest": unsafe,
    "total": len(files),
    "source_orphans": [e["src"] for e in files],
}
print(json.dumps(result, indent=2, sort_keys=True))
# Fail-closed: a source that vanished between manifest build and apply, or a
# dest rejected for symlink traversal, means the migration is INCOMPLETE. Exit
# nonzero so the convert orchestrator triggers the internal rollback rather than
# treating a partial copy as success (the apply-log above lets rollback undo it).
sys.exit(1 if (missing or unsafe) else 0)
'

# _BRIDGE_CONVERT_ROLLBACK_PY — undo an apply from its backup dir + re-verify.
# argv: backup_dir
_BRIDGE_CONVERT_ROLLBACK_PY='
import json
import os
import sys

CHUNK = 65536

backup_dir = sys.argv[1]
journal_path = os.path.join(backup_dir, "apply-journal.jsonl")
meta_path = os.path.join(backup_dir, "apply-meta.json")
if not os.path.isfile(journal_path):
    sys.stderr.write("convert rollback: no apply-journal.jsonl under " + backup_dir + "\n")
    sys.exit(2)

target = ""
if os.path.isfile(meta_path):
    with open(meta_path, "r", encoding="utf-8") as fh:
        target = json.load(fh).get("target_config_dir", "")

# The write-ahead journal is the source of truth: one intent line per started
# mutation. Undoing exactly these makes a crashed/partial apply recoverable.
entries = []
with open(journal_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            continue

restored = 0
removed = 0
errors = []


def dest_is_safe(dest):
    # Same fail-closed symlink-traversal guard the apply path uses: never
    # restore a file THROUGH a pre-existing symlink at/below the target.
    if not target or os.path.islink(target):
        return False
    rel = os.path.relpath(dest, target)
    if rel == ".." or rel.startswith(".." + os.sep):
        return False
    cur = target
    for part in rel.split(os.sep):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return False
    return True


def restore_nofollow(bpath, dest):
    sfd = os.open(bpath, os.O_RDONLY)
    try:
        st = os.fstat(sfd)
        dfd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            while True:
                chunk = os.read(sfd, CHUNK)
                if not chunk:
                    break
                os.write(dfd, chunk)
            os.utime(dfd, (st.st_atime, st.st_mtime))
        finally:
            os.close(dfd)
    finally:
        os.close(sfd)


# Reverse order so created files clear before their parent dirs are pruned.
for entry in reversed(entries):
    dest = entry.get("dest", "")
    action = entry.get("action", "")
    if not dest:
        continue
    if action == "create":
        try:
            # islink-first so a symlink dest is unlinked (the link itself),
            # never followed; os.remove never traverses on delete.
            if os.path.islink(dest) or os.path.isfile(dest):
                os.remove(dest)
                removed += 1
        except OSError as exc:
            errors.append("remove " + dest + ": " + str(exc))
    elif action == "overwrite":
        if not dest_is_safe(dest):
            errors.append("restore " + dest + ": unsafe dest (symlink traversal)")
            continue
        bpath = entry.get("backup", "")
        try:
            if bpath and os.path.isfile(bpath):
                restore_nofollow(bpath, dest)
                restored += 1
            else:
                errors.append("restore " + dest + ": backup missing")
        except OSError as exc:
            errors.append("restore " + dest + ": " + str(exc))

# Prune now-empty directories left behind under the target.
if target and os.path.isdir(target):
    for root, dirs, names in os.walk(target, topdown=False):
        if os.path.realpath(root) == os.path.realpath(target):
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass

# Re-verify: every "create" dest is gone, every "overwrite" dest is back.
for entry in entries:
    if entry.get("action") == "create" and os.path.exists(entry.get("dest", "")):
        errors.append("verify: created file still present " + entry.get("dest", ""))
    if entry.get("action") == "overwrite" and not os.path.exists(entry.get("dest", "")):
        errors.append("verify: overwritten file not restored " + entry.get("dest", ""))

result = {"restored": restored, "removed": removed, "errors": errors}
print(json.dumps(result, indent=2, sort_keys=True))
sys.exit(1 if errors else 0)
'

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# _bridge_convert_backup_root <agent> — state/convert-backups/<agent>.
_bridge_convert_backup_root() {
  local agent="$1"
  local state_dir="${BRIDGE_STATE_DIR:-}"
  if [[ -z "$state_dir" ]]; then
    state_dir="${BRIDGE_HOME:-}/state"
  fi
  printf '%s/convert-backups/%s' "$state_dir" "$agent"
}

# _bridge_convert_target_is_shared <agent> — true iff the target config dir is
# a shared-mode (macOS / non-iso) home this engine can write directly. An
# iso-effective target is rejected (§0.5 Q5 fail-closed).
_bridge_convert_target_is_shared() {
  local agent="$1"
  if command -v bridge_isolation_disabled_by_env >/dev/null 2>&1 \
     && bridge_isolation_disabled_by_env 2>/dev/null; then
    return 0
  fi
  if command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
     && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Public engine API
# ---------------------------------------------------------------------------

# bridge_convert_resolve_config_dirs <agent>
# Echo "<source_config_dir>\t<target_config_dir>".
#   source: dynamic-vanilla -> operator ~/.claude, else the agent's own dir.
#   target: bridge_agent_claude_config_dir evaluated as-if-static (no roster
#           flip required — the resolver does not consult source=).
# Fails (rc 3) fail-closed when the target is an iso-effective UID home.
bridge_convert_resolve_config_dirs() {
  local agent="$1"
  if [[ -z "$agent" ]]; then
    printf 'convert: agent name required\n' >&2
    return 2
  fi
  if ! _bridge_convert_target_is_shared "$agent"; then
    printf 'convert: agent %s resolves to an iso-effective target config dir; iso-target convert is a fast-follow (MVP supports shared-mode/macOS targets only)\n' \
      "$agent" >&2
    return 3
  fi

  local source_dir="" target_dir=""
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$agent"; then
    local operator_home=""
    operator_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
    if [[ -z "$operator_home" ]]; then
      printf 'convert: cannot resolve operator home for %s\n' "$agent" >&2
      return 4
    fi
    source_dir="$operator_home/.claude"
  else
    source_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  fi

  target_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  if [[ -z "$source_dir" || -z "$target_dir" ]]; then
    printf 'convert: could not resolve source/target config dirs for %s\n' "$agent" >&2
    return 5
  fi

  printf '%s\t%s\n' "$source_dir" "$target_dir"
}

# bridge_convert_enumerate_cwds <agent> <source_config_dir> <workdir>
# Print one TSV row per project dir: "<status>\t<slug>\t<cwd>".
#   status=include  — cwd is the workdir or a descendant (auto-migrate).
#   status=candidate — cwd is outside the workdir; requires --include-cwd
#                      confirmation before the manifest will migrate it.
bridge_convert_enumerate_cwds() {
  local agent="$1"
  local source_dir="$2"
  local workdir="$3"
  if [[ -z "$source_dir" ]]; then
    printf 'convert: source config dir required\n' >&2
    return 2
  fi
  python3 -c "$_BRIDGE_CONVERT_SCAN_PY" enumerate "$agent" "$source_dir" "" "$workdir"
}

# bridge_convert_build_manifest <agent> <source_config_dir> <target_config_dir>
#                               <workdir> <bridge_home_slug> [include_cwd_csv]
# Print the JSON migration manifest (every file with size + dest). This is what
# --dry-run / --json render. Zero omissions is the acceptance gate.
bridge_convert_build_manifest() {
  local agent="$1"
  local source_dir="$2"
  local target_dir="$3"
  local workdir="$4"
  local slug="$5"
  local include_csv="${6:-}"
  if [[ -z "$source_dir" || -z "$target_dir" ]]; then
    printf 'convert: source and target config dirs required\n' >&2
    return 2
  fi
  python3 -c "$_BRIDGE_CONVERT_SCAN_PY" manifest "$agent" "$source_dir" \
    "$target_dir" "$workdir" "$slug" "$include_csv"
}

# bridge_convert_apply_manifest <manifest_file> [<timestamp>]
# Back up any pre-existing target files to state/convert-backups/<agent>/<ts>/,
# then COPY every manifest file into the target (source untouched, mtimes
# preserved, skip-if-identical). Prints the apply-result JSON (counts +
# backup_dir + source_orphans).
bridge_convert_apply_manifest() {
  local manifest_file="$1"
  local ts="${2:-}"
  if [[ ! -f "$manifest_file" ]]; then
    printf 'convert: manifest file not found: %s\n' "$manifest_file" >&2
    return 2
  fi
  if [[ -z "$ts" ]]; then
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  local agent=""
  agent="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent",""))' "$manifest_file" 2>/dev/null || true)"
  if [[ -z "$agent" ]]; then
    printf 'convert: manifest has no agent field: %s\n' "$manifest_file" >&2
    return 3
  fi
  local backup_dir=""
  backup_dir="$(_bridge_convert_backup_root "$agent")/$ts"
  python3 -c "$_BRIDGE_CONVERT_APPLY_PY" "$manifest_file" "$backup_dir"
}

# bridge_convert_rollback <agent> <ts>
# INTERNAL-only (§0.4): restore the pre-apply state from
# state/convert-backups/<agent>/<ts>/ and re-verify. Invoked by the convert
# orchestrator's failure path, NOT a user-facing CLI verb in MVP.
bridge_convert_rollback() {
  local agent="$1"
  local ts="$2"
  if [[ -z "$agent" || -z "$ts" ]]; then
    printf 'convert: rollback requires <agent> <timestamp>\n' >&2
    return 2
  fi
  local backup_dir=""
  backup_dir="$(_bridge_convert_backup_root "$agent")/$ts"
  python3 -c "$_BRIDGE_CONVERT_ROLLBACK_PY" "$backup_dir"
}

fi  # _BRIDGE_AGENT_CONVERT_SH_LOADED guard
