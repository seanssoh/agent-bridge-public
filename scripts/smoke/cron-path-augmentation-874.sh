#!/usr/bin/env bash
# scripts/smoke/cron-path-augmentation-874.sh — v0.13.6 hotfix smoke.
#
# Regression guard for issue #874. The bridge cron runner must search a
# PATH augmented with the stable alias / shim paths exposed by the common
# Node version managers (fnm / nvm / asdf / volta) so a cron-driven codex
# or claude invocation can resolve BOTH the CLI binary AND the `node`
# interpreter its `#!/usr/bin/env node` shebang re-exec's. Before this
# patch, COMMON_BIN_DIRS only carried `~/.local/bin`, `~/.nix-profile/bin`,
# `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, which led to a silent
# two-layer trap on every fnm/nvm/asdf host: layer 1 (the binary) succeeded
# only after an operator workaround, layer 2 (the `env node` shebang
# re-search) still failed because the per-version node binary was not on
# the cron PATH.
#
# This smoke checks two invariants:
#   T1-T4: the stable alias / shim paths for fnm, nvm, asdf, volta are
#          listed in `bridge_cron_runner.COMMON_BIN_DIRS` (set-membership,
#          not directory existence — the smoke is purely about the
#          registration contract).
#   T5-T7: BRIDGE_CRON_EXTRA_PATH is parsed colon-separated, supports `~`
#          expansion per entry, and yields an empty list when unset/blank.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock + multi-variant trap): this
# smoke writes its inline Python helper line-by-line via `printf` to a
# tmp file and runs `python3 <file>`. No heredoc, no here-string, and no
# `bash -c '...python...'` shape either.

set -euo pipefail

SMOKE_NAME="cron-path-augmentation-874"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root

HELPER="$SMOKE_TMP_ROOT/cron_path_check.py"

# Build the helper line-by-line via printf — no heredoc / no here-string.
{
  printf '%s\n' 'import importlib.util, os, sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
  printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
  printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(module)'
  printf '%s\n' ''
  printf '%s\n' 'errors = []'
  printf '%s\n' 'common = list(module.COMMON_BIN_DIRS)'
  printf '%s\n' ''
  printf '%s\n' 'expected_manager_paths = ['
  printf '%s\n' '    Path.home() / ".local" / "share" / "fnm" / "aliases" / "default" / "bin",'
  printf '%s\n' '    Path.home() / ".nvm" / "versions" / "node" / "default" / "bin",'
  printf '%s\n' '    Path.home() / ".asdf" / "shims",'
  printf '%s\n' '    Path.home() / ".volta" / "bin",'
  printf '%s\n' ']'
  printf '%s\n' ''
  printf '%s\n' 'labels = ("fnm-default-alias", "nvm-default-alias", "asdf-shims", "volta-bin")'
  printf '%s\n' 'for label, expected in zip(labels, expected_manager_paths):'
  printf '%s\n' '    if expected not in common:'
  printf '%s\n' '        errors.append("COMMON_BIN_DIRS missing %s entry: %s" % (label, expected))'
  printf '%s\n' ''
  printf '%s\n' '# Stable pre-existing entries must remain — guard against accidental removal.'
  printf '%s\n' 'baseline = ('
  printf '%s\n' '    Path.home() / ".local" / "bin",'
  printf '%s\n' '    Path.home() / ".nix-profile" / "bin",'
  printf '%s\n' '    Path.home() / "bin",'
  printf '%s\n' '    Path("/opt/homebrew/bin"),'
  printf '%s\n' '    Path("/usr/local/bin"),'
  printf '%s\n' ')'
  printf '%s\n' 'for expected in baseline:'
  printf '%s\n' '    if expected not in common:'
  printf '%s\n' '        errors.append("COMMON_BIN_DIRS regressed; missing baseline entry: %s" % expected)'
  printf '%s\n' ''
  printf '%s\n' '# T5: BRIDGE_CRON_EXTRA_PATH unset -> empty list.'
  printf '%s\n' 'os.environ.pop("BRIDGE_CRON_EXTRA_PATH", None)'
  printf '%s\n' 'unset_result = module.cron_extra_path_dirs()'
  printf '%s\n' 'if unset_result != []:'
  printf '%s\n' '    errors.append("cron_extra_path_dirs() with unset env returned %r, expected []" % unset_result)'
  printf '%s\n' ''
  printf '%s\n' '# T5b: blank env -> empty list.'
  printf '%s\n' 'os.environ["BRIDGE_CRON_EXTRA_PATH"] = "   "'
  printf '%s\n' 'blank_result = module.cron_extra_path_dirs()'
  printf '%s\n' 'if blank_result != []:'
  printf '%s\n' '    errors.append("cron_extra_path_dirs() with blank env returned %r, expected []" % blank_result)'
  printf '%s\n' ''
  printf '%s\n' '# T6: colon-separated entries, with ~ expansion + a no-op empty segment.'
  printf '%s\n' 'os.environ["BRIDGE_CRON_EXTRA_PATH"] = "/custom/one" + os.pathsep + "~/.custom/two" + os.pathsep + " "'
  printf '%s\n' 'multi_result = module.cron_extra_path_dirs()'
  printf '%s\n' 'expected_multi = [Path("/custom/one"), Path("~/.custom/two").expanduser()]'
  printf '%s\n' 'if multi_result != expected_multi:'
  printf '%s\n' '    errors.append("cron_extra_path_dirs() multi-entry parse: got %r, expected %r" % (multi_result, expected_multi))'
  printf '%s\n' ''
  printf '%s\n' '# T7: extras are surfaced ahead of built-in fallbacks in augmented_path() ordering.'
  printf '%s\n' '# We construct an extras path pointing at the smoke tmp root so the directory'
  printf '%s\n' '# actually exists and survives the is_dir() filter.'
  printf '%s\n' 'tmp_root = os.environ["SMOKE_TMP_ROOT"]'
  printf '%s\n' 'extra_dir = os.path.join(tmp_root, "extra-bin")'
  printf '%s\n' 'os.makedirs(extra_dir, exist_ok=True)'
  printf '%s\n' 'os.environ["BRIDGE_CRON_EXTRA_PATH"] = extra_dir'
  printf '%s\n' 'os.environ["PATH"] = "/usr/bin"'
  printf '%s\n' 'augmented = module.augmented_path().split(os.pathsep)'
  printf '%s\n' 'if extra_dir not in augmented:'
  printf '%s\n' '    errors.append("augmented_path() did not include BRIDGE_CRON_EXTRA_PATH entry %s; got %r" % (extra_dir, augmented))'
  printf '%s\n' ''
  printf '%s\n' '# Reset env so any later interpreter probes do not inherit the smoke state.'
  printf '%s\n' 'os.environ.pop("BRIDGE_CRON_EXTRA_PATH", None)'
  printf '%s\n' ''
  printf '%s\n' 'if errors:'
  printf '%s\n' '    for e in errors:'
  printf '%s\n' '        print("[smoke][error] " + e, file=sys.stderr)'
  printf '%s\n' '    sys.exit(1)'
  printf '%s\n' ''
  printf '%s\n' 'print("[smoke] cron PATH augmentation invariants ok")'
} >"$HELPER"

smoke_log "running cron PATH augmentation check via $HELPER"
REPO_ROOT="$REPO_ROOT" SMOKE_TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$HELPER"

smoke_log "ok"
