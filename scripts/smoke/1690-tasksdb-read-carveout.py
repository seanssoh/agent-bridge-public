#!/usr/bin/env python3
# scripts/smoke/1690-tasksdb-read-carveout.py — KEEP-invariant unit
# layer for issue #1690 (queue tasks.db direct-READ over-block carve-out).
#
# Before #1690 both protected-path gates for state/tasks.db returned an
# UNCONDITIONAL deny — the only protected path that omitted the
# read_intent carve-out every sibling gate (roster, system-config) has.
# A read of the DB *file* does not mutate the queue, so the fix mirrors
# the roster gate shape: `if read_intent: return None`, deny otherwise.
#
# The whole point of the relaxation is fail-closed: the carve-out keys on
# `_is_read_intent_bash`, which already classifies any output
# redirection / write tool / unparseable command / sqlite3-mutate as
# write-intent (read_intent=False). `sqlite3` is deliberately NOT on
# `_READ_INTENT_BASH_COMMANDS`, so EVERY `sqlite3 …` (even a `-readonly`
# SELECT) classifies write-intent and stays denied — fail-closed.
#
# This unit layer pins the classifier-level invariants that underpin the
# carve-out. The end-to-end allow/deny verdict through the real
# PreToolUse hook is asserted in the sibling 1690-tasksdb-read-carveout.sh
# (Layer 2). Two layers because a classifier-only test gave false
# confidence on the roster carve-out (#1014 codex r1 catch).

import importlib.util
import pathlib
import sys


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    policy_path = repo_root / "hooks" / "tool-policy.py"
    spec = importlib.util.spec_from_file_location(
        "tool_policy_tasksdb_read", policy_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {policy_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    is_read = module._is_read_intent_bash

    db = "state/tasks.db"

    # (command, expected read_intent). True => the carve-out's
    # `if read_intent: return None` fires and the read is ALLOWED.
    # False => stays DENIED (KEEP-invariant teeth).
    cases: list[tuple[str, bool]] = [
        # ---- read-intent of the DB file => ALLOWED after #1690 ----
        (f"cat {db}", True),
        (f"ls -l {db}", True),
        (f"stat {db}", True),
        (f"file {db}", True),
        (f"head -c 64 {db}", True),
        (f"xxd {db} | head", True),
        (f"sha256sum {db}", True),
        # ---- KEEP teeth: output redirection INTO / FROM a sink ----
        (f"cat foo > {db}", False),          # clobber the DB
        (f"cat foo >> {db}", False),         # append to the DB
        (f"cat {db} > /tmp/leak", False),    # read redirected to a file sink
        (f"cat {db} 1>/tmp/leak", False),    # numeric-fd sink
        (f"cat {db} | tee /tmp/leak", False),  # tee sink stage (unknown leader)
        # ---- KEEP teeth: sqlite3 stays write-intent (NOT unblocked) ----
        # sqlite3 is intentionally absent from _READ_INTENT_BASH_COMMANDS,
        # so a mutate AND even a -readonly SELECT both classify write-intent
        # and stay denied. Fail-closed: we never let `sqlite3 db 'UPDATE'`
        # become read-intent.
        (f"sqlite3 {db} 'UPDATE tasks SET status=1'", False),
        (f"sqlite3 {db} 'DELETE FROM tasks'", False),
        (f"sqlite3 {db} 'INSERT INTO tasks VALUES (1)'", False),
        (f"sqlite3 {db} '.dump' > /tmp/dump.sql", False),
        (f"sqlite3 {db} '.backup /tmp/bk.db'", False),
        (f"sqlite3 -readonly {db} 'SELECT id,status FROM tasks'", False),
        (f"sqlite3 {db} '.schema'", False),
        # ---- KEEP teeth: write tools / mutators ----
        (f"rm {db}", False),
        (f"truncate -s 0 {db}", False),
        (f"dd if=/dev/zero of={db}", False),
        # ---- KEEP teeth: awk in-program write/exec/pipe (issue #1690 ----
        # codex direction-review). awk is on _READ_INTENT_BASH_COMMANDS but
        # its program body can write/exfil with NO shell `>` token. These
        # MUST classify write-intent; a plain awk read (below) stays True.
        (f'awk \'{{print>"/tmp/leak"}}\' {db}', False),    # in-program file write
        (f'awk \'{{print >> "/tmp/leak"}}\' {db}', False),  # in-program append
        (f'awk \'{{print | "cmd"}}\' {db}', False),        # pipe to a command
        (f'awk \'BEGIN{{system("cp {db} /tmp/copy")}}\' {db}', False),  # system()
        (f'awk \'{{getline x < "cmd"}}\' {db}', False),    # getline from a source
        (f"awk -i inplace '{{print}}' {db}", False),       # -i inplace flag
        # plain awk reads stay read-intent (regression guard)
        (f"awk '{{print $2}}' {db}", True),
        (f"awk -F: '{{print $1}}' {db}", True),
        # ---- KEEP teeth: other read-intent leaders with their OWN named- ----
        # file output / external-exec primitive (#1690 codex re-review).
        # sort -o, less -o, view -c 'w!', rg --pre, xxd infile outfile,
        # xxd -r, yq -i all write/exfil WITHOUT a shell `>` token.
        (f"sort -o /tmp/leak {db}", False),         # sort -o output file
        (f"sort --output=/tmp/leak {db}", False),   # sort --output=
        (f"sort -o/tmp/leak {db}", False),          # glued short flag
        (f"less -o /tmp/leak {db}", False),         # less -o log file
        (f"less --log-file=/tmp/leak {db}", False),  # less --log-file=
        # less lesskey loader can set `#env LESSOPEN=|cmd` preprocessor
        # (RCE), same surface the LESSOPEN env prefix blocks (#1690 r2).
        (f"less -k /tmp/evil.lesskey {db}", False),
        (f"less --lesskey-file=/tmp/x {db}", False),
        (f"less --lesskey-src=/tmp/x {db}", False),
        (f"less --lesskey-context=stuff {db}", False),
        (f"xxd {db} /tmp/leak", False),             # xxd 2nd positional = output
        (f"xxd {db} leak", False),                  # bare-name output in CWD
        (f"xxd -r {db}", False),                    # xxd reverse/patch
        (f"view -c 'w! /tmp/leak' -c 'qa!' {db}", False),  # ex :w write
        (f"view +w! {db}", False),                  # +cmd ex write
        (f"rg --pre sh . {db}", False),             # rg preprocessor RCE
        (f"rg --pre=sh . {db}", False),             # rg --pre= glued
        (f"yq -i . {db}", False),                   # yq in-place write
        (f"yq eval -i . {db}", False),              # yq eval in-place write
        # round-3 residuals: pager +cmd startup (less/more/view) + sort
        # --compress-program RCE + quoted-token forms that the raw split
        # exposes (the token keeps its surrounding quote).
        (f"view '+w! /tmp/leak' {db}", False),      # ex :w via +cmd (quoted)
        (f"less '+!cp {db} /tmp/leak' {db}", False),  # less +!shell
        (f"less '+s /tmp/leak' {db}", False),       # less +s save-to-file
        (f"more '+!cp {db} /tmp/leak' {db}", False),  # more +!shell
        (f"sort --compress-program=sh {db}", False),  # sort RCE flag (glued)
        (f"sort --compress-program sh {db}", False),  # sort RCE flag (sep)
        (f'rg "--pre" sh . {db}', False),           # quoted --pre token
        # round-4 residuals: awk program-from-file (unverifiable), yq
        # split-exp write, and command-execution env prefixes that the
        # leader check strips (LESSOPEN/PAGER/LD_PRELOAD/BASH_ENV/…).
        (f"awk -f /tmp/evil.awk {db}", False),      # awk program from a file
        (f"awk --file=/tmp/evil.awk {db}", False),  # awk --file= glued
        # r2 patch/codex sweep: gawk loads EXTERNAL program/extension code
        # via --include/-i/@include and --load/-l/@load (each can carry a
        # system()/print>file the inline scan never sees); glued -iinplace
        # slips the caller's bare `-i` check. All MUST deny.
        (f"awk --include=/tmp/evil.awk '{{print}}' {db}", False),
        (f"awk -l /tmp/evil_ext '{{print}}' {db}", False),
        (f"awk --load=/tmp/evil_ext '{{print}}' {db}", False),
        (f"awk @include /tmp/evil.awk {db}", False),
        (f"awk -iinplace '{{print}}' {db}", False),
        (f"awk -E /tmp/evil.awk {db}", False),       # gawk --exec program file
        (f"awk --exec=/tmp/evil.awk {db}", False),
        (f"awk -o /tmp/o.awk '{{print}}' {db}", False),  # --pretty-print write
        (f"awk -p /tmp/prof '{{print}}' {db}", False),   # --profile write
        (f"awk -D '{{print}}' {db}", False),         # --debug interactive exec
        (f"awk --dump-variables=/tmp/o '{{print}}' {db}", False),  # var-dump write
        (f"awk -W exec=/tmp/x {db}", False),         # -W meta-flag (exec alias)
        (f"awk --some-future-flag '{{print}}' {db}", False),  # allowlist fail-closed
        (f"yq --in-place . {db}", False),            # hyphenated in-place write
        # awk benign read flags stay read-intent (allowlist regression guard)
        (f"awk --field-separator=: '{{print $1}}' {db}", True),
        (f"awk --assign x=1 '{{print x}}' {db}", True),
        (f"awk -b '{{print}}' {db}", True),
        (f"awk --posix '{{print}}' {db}", True),
        (f"awk --sandbox '{{print}}' {db}", True),
        # r3 FIX 1: the write-marker scan must read ONLY the awk PROGRAM
        # word, not a `-F`/`-v` flag VALUE or an INPUT-FILE-PATH positional.
        # These were over-blocked (the exact reads #1690 must unblock).
        (f"awk -F '|' '{{print $2}}' {db}", True),       # `|` is the -F value
        (f"awk -F'|' '{{print $2}}' {db}", True),        # glued -F value
        (f"awk -v FS='|' '{{print $2}}' {db}", True),    # `|` is the -v value
        (f"awk --field-separator='|' '{{print $2}}' {db}", True),
        (f"awk -F '[:,]' '{{print $1}}' {db}", True),
        ("awk '{print $1}' lib/system_config_paths.py", True),  # path has "system"
        ("awk '{print $2}' shared/2026-05-28-232-closed.md", True),  # path has "close"
        # r3 FIX 1 security: markers INSIDE the program word still DENY,
        # incl. programs whose body contains whitespace (shlex keeps the
        # program as one word so the `|`/system after a space is still seen).
        (f'awk \'{{print | "sh -c id"}}\' {db}', False),
        (f'awk \'BEGIN{{system("cp x y")}}\' {db}', False),
        # r3 FIX 4: -M/--bignum has no file/exec surface — must ALLOW.
        (f"awk -M 1 {db}", True),
        (f"awk --bignum '{{print $1}}' {db}", True),
        # r3 codex final-sweep: a shell-expanded awk PROGRAM word hides its
        # real content from the marker scan ('p=...; awk "$p"') — fail
        # closed. A single-quoted awk computed field ($(NF-1)) is NOT a
        # shell substitution and must stay ALLOWed.
        ('p=\'BEGIN{system("id")}\'; awk "$p" ' + db, False),  # shell-var program
        ('awk $p ' + db, False),                       # unquoted var program
        (f"awk '{{print $(NF-1)}}' {db}", True),       # awk computed field (allow)
        (f"awk '{{print $(NF)}}' {db}", True),
        (f"awk '{{print $1}}' $HOME/data.txt", True),  # $HOME in datafile = benign
        # r3 codex: gawk @include/@load inside the INLINE program (leading
        # space/newline/comment makes it the program word, not the first
        # token) loads external code — must DENY via program marker.
        ('awk \' @include "/tmp/evil.awk"\' ' + db, False),
        ('awk \'\n@include "/tmp/evil.awk"\' ' + db, False),
        ('awk \' @load "evil"\' ' + db, False),
        (f"yq -s /tmp/leak . {db}", False),         # yq split-exp short
        (f"yq --split-exp /tmp/leak . {db}", False),  # yq split-exp long
        (f"PAGER=sh less {db}", False),             # PAGER env exec prefix
        (f"LESSOPEN=|cmd less {db}", False),        # LESSOPEN preprocessor
        (f"LD_PRELOAD=/tmp/x.so cat {db}", False),  # LD_PRELOAD injection
        (f"BASH_ENV=/tmp/x cat {db}", False),       # BASH_ENV injection
        # r3 FIX 2: dynamic-loader / preprocessor env vars are a code-exec
        # surface (rtld-audit / converter / profile run before main()).
        (f"LD_AUDIT=/tmp/x.so cat {db}", False),    # glibc rtld-audit RCE
        (f"LD_PROFILE=/tmp/x cat {db}", False),
        (f"GCONV_PATH=/tmp/x cat {db}", False),
        (f"NLSPATH=/tmp/x cat {db}", False),
        (f"DYLD_FALLBACK_LIBRARY_PATH=/tmp cat {db}", False),
        (f"DYLD_FRAMEWORK_PATH=/tmp cat {db}", False),
        # r3 FIX 3: `file -C` compiles a `.mgc` magic DB (file write); the
        # read-only -m/--magic-file/-M stay allowed.
        (f"file -C -m /tmp/x {db}", False),
        (f"file --compile -m /tmp/x {db}", False),
        (f"file {db}", True),
        (f"file -m /tmp/magic {db}", True),
        (f"file --magic-file /tmp/magic {db}", True),
        # VIMINIT/EXINIT carry vim/ex startup commands (:write!/:!cmd) for
        # the read-intent `view` leader (#1690 codex re-review round 6).
        (f"VIMINIT=x view {db}", False),
        (f"EXINIT=x view {db}", False),
        # option/config-injection env vars for read leaders (#1690 round 7):
        # the same write/exec primitive injected via env not argv.
        (f"LESS=-o/tmp/log less {db}", False),               # less -o via LESS
        (f"RIPGREP_CONFIG_PATH=/tmp/rg.rc rg needle {db}", False),  # rg --pre via cfg
        (f"GREP_OPTIONS=--foo grep x {db}", False),          # grep option inject
        (f"AWKPATH=/tmp awk '{{print}}' {db}", False),       # awk include path
        (f"MORE=-foo more {db}", False),                     # more option inject
        # benign env prefixes stay read-intent (regression guard)
        (f"LC_ALL=C grep x {db}", True),
        (f"TZ=UTC stat {db}", True),
        # round-5 residual: adjacent-quote concatenation hides an awk
        # `system`/`getline`/`close` marker from the raw substring scan
        # (`'syst''em(...)'` reaches awk as system(...)). The quote-strip
        # in _awk_is_read_only collapses the fragments. These MUST deny.
        ("awk 'BEGIN{syst''em(\"id\")}' " + db, False),
        ("awk 'BEGIN{sy''st''em(\"id\")}' " + db, False),  # triple-split
        ("awk '{getl''ine x}' " + db, False),
        ("awk '{cl''ose(\"x\")}' " + db, False),
        # round-6 residual: shell embedding ($()/backtick/procsub) runs an
        # arbitrary command BEFORE the visible read leader, so the whole
        # command is not read-intent. _command_has_shell_embedding catches
        # it. These MUST deny.
        (f"cat {db} $(cp {db} sink)", False),       # command substitution
        (f"cat $(cp {db} sink) {db}", False),       # cmd-subst leading arg
        (f"cat `cp {db} sink` {db}", False),        # backtick substitution
        (f"grep x {db} $(rm {db})", False),         # cmd-subst destructive
        (f"cat <(cp {db} sink)", False),            # process substitution
        (f"cat {db} <<< $(id)", False),             # here-string + subst
        # benign forms of the same leaders stay read-intent
        (f"sort -n {db}", True),
        (f"less {db}", True),
        (f"xxd {db}", True),
        (f"xxd -s 0 -l 64 {db}", True),             # numeric flag values, lone input
        (f"rg pattern {db}", True),
        (f"view {db}", True),
        (f"yq . {db}", True),
        # ---- KEEP teeth: r2 patch adversarial review ----
        # uniq [opts] [INPUT [OUTPUT]] — 2nd positional is an OUTPUT file
        # (write/exfil), same shape as xxd. MUST deny; 1-positional read OK.
        (f"uniq {db} /tmp/leak", False),
        (f"uniq -c {db} /tmp/leak", False),
        (f"uniq -f 2 {db} /tmp/leak", False),   # skip the -f value, still 2 pos
        (f"uniq {db}", True),                   # lone input = read
        (f"uniq -c {db}", True),
        (f"uniq -f 2 {db}", True),              # flag-value not counted as output
        # view is a benign-flag ALLOWLIST: vim's exec/write/startup/verbose
        # flags all deny; only no-file mode toggles + plain `view <f>` read.
        (f"view -u /tmp/evil.vim {db}", False),       # -u arbitrary vimrc
        (f"view -U /tmp/g.vim {db}", False),          # -U gvimrc
        (f"view -i /tmp/x.shada {db}", False),        # -i viminfo/shada write
        (f"view --startuptime /tmp/out {db}", False),  # verbose-to-file write
        (f"view --log /tmp/out {db}", False),         # --log file write
        (f"view -V1/tmp/out {db}", False),            # -V[N]file verbose write
        (f"view -es {db}", False),                    # ex/silent mode (exec)
        (f"view -r /tmp/recover {db}", False),        # recovery (write)
        (f"view --some-future-flag {db}", False),     # allowlist fail-closed
        (f"view -R {db}", True),                      # readonly toggle (read)
        (f"view -M {db}", True),                      # modifiability off (read)
        (f"view -R -n {db}", True),                   # combined mode toggles
        # quoted-flag bypass: a shell-quoted flag (`"-c"` / `'-f'`) arrives
        # with embedded quotes; the allowlist loops quote-strip before
        # classification so they still DENY (#1690 r2 codex sweep).
        (f'view "-c" "w!/tmp/leak" {db}', False),
        (f"view '-c' 'w!/tmp/leak' {db}", False),
        (f'view "--startuptime" /tmp/out {db}', False),
        (f'awk "-f" /tmp/x.awk {db}', False),
        (f"awk '-f' /tmp/x.awk {db}", False),
        (f'sort "-o" /tmp/leak {db}', False),
        (f'less "-k" /tmp/lesskey {db}', False),
        (f'rg "--pre" sh . {db}', False),
        (f'find {db} "-exec" cp x {{}} ;', False),  # find quoted -exec
        (f"find {db} '-delete'", False),            # find quoted -delete
        (f"find {db} -type f -name x", True),       # benign find still read
        # quoted flag-with-value must NOT over-block a lone-input read
        (f'xxd "-s" 0 {db}', True),
        (f'uniq "-f" 2 {db}', True),
        # r4 FIX 1: bash 5.3 funsub `${ cmd; }` is a command substitution
        # the stage-splitter can't see (a subshell body `${ (cmd) }` self-
        # terminates), so the embedding gate must flag `${`+whitespace/`|`.
        # These classify NOT read-intent (deny). `${VAR}` param-expansion
        # (no space after `{`) must stay read-intent.
        (f"cat {db} ${{ (cp {db} /tmp/sink) }}", False),  # funsub subshell
        (f"cat {db} ${{| cp {db} /tmp/sink; }}", False),  # funsub pipe form
        (f"cat {db} ${{ cp x y; }}", False),              # funsub brace-cmd
        (f"cat ${{SOMEVAR}}", True),                       # param expansion
        (f"cat ${{#x}}", True),
        (f"echo ${{arr[@]}}", True),
        (f"cat ${{x:-d}}", True),
        (f"cat ${{BRIDGE_HOME}}/path", True),             # param expansion path
        # ---- KEEP teeth: fail-closed on unparseable command ----
        (f"cat {db} ' | tee /tmp/leak", False),  # unbalanced quote
    ]

    failures: list[str] = []
    for cmd, want in cases:
        got = bool(is_read(cmd))
        if got != want:
            tag = "read-mis-as-write" if want else "write-mis-as-read"
            failures.append(
                f"  FAIL  [{tag}] _is_read_intent_bash({cmd!r}) = {got}, want {want}"
            )
        else:
            print(f"  PASS  _is_read_intent_bash({cmd!r}) = {got}")

    # Belt-and-suspenders: sqlite3 must NOT be on the read-intent allowlist.
    if "sqlite3" in module._READ_INTENT_BASH_COMMANDS:
        failures.append(
            "  FAIL  sqlite3 must NOT be on _READ_INTENT_BASH_COMMANDS "
            "(a 'sqlite3 db UPDATE …' would wrongly become read-intent)"
        )
    else:
        print("  PASS  sqlite3 absent from _READ_INTENT_BASH_COMMANDS")

    # r4 FIX 1: the funsub `${ space`-vs-`${VAR}` discriminator at the
    # helper level, for BOTH embedding gates (strict + quote-aware).
    strict = module._command_has_shell_embedding
    unq = module._command_has_unquoted_shell_embedding
    funsub_deny = ["cat ${ cmd; }", "cat ${| cmd; }", "cat ${\t(x) }", "cat ${\nx; }"]
    param_allow = ["cat ${VAR}", "cat ${#x}", "echo ${arr[@]}", "cat ${x:-d}",
                   "cat ${BRIDGE_HOME}/p"]
    for c in funsub_deny:
        if not strict(c):
            failures.append(f"  FAIL  strict embedding MISSED funsub: {c!r}")
        elif not unq(c):
            failures.append(f"  FAIL  unquoted embedding MISSED funsub: {c!r}")
        else:
            print(f"  PASS  both gates flag funsub {c!r}")
    for c in param_allow:
        if strict(c) or unq(c):
            failures.append(f"  FAIL  embedding over-flagged ${{VAR}} param: {c!r}")
        else:
            print(f"  PASS  ${{VAR}} param not flagged {c!r}")

    # r4 FIX 2: the unresolved-path-expansion detector — $VAR/${VAR}/~/brace
    # outside single quotes flagged; funsub/single-quoted/literal not.
    pe = module._has_unresolved_path_expansion
    pe_yes = ["cat ${BRIDGE_HOME}/x", "cat $BRIDGE_HOME/x", "cat ${HOME}/x",
              "cat ~/x", "cat a {b,c}/x"]
    pe_no = ["cat /abs/literal", "cat ${ cmd; }", "cat '${VAR}'/x",
             "grep x file", "cat foo~bar"]
    for c in pe_yes:
        if not pe(c):
            failures.append(f"  FAIL  path-expansion detector MISSED: {c!r}")
        else:
            print(f"  PASS  path-expansion detected {c!r}")
    for c in pe_no:
        if pe(c):
            failures.append(f"  FAIL  path-expansion detector over-flagged: {c!r}")
        else:
            print(f"  PASS  path-expansion not flagged {c!r}")

    if failures:
        print(f"\n{len(failures)} failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print(
        f"\n[smoke:1690-tasksdb-read-carveout] all {len(cases)} cases passed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
