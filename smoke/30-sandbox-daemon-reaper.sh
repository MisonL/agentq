#!/usr/bin/env bash
# Smoke: the dev sandbox must identify its own pueued by the CONFIG PATH that
# process was started with -- never by the pid file alone, and never by a bare
# pid number.
#
# Five measured defects (2026-11-02/03).  The first three share one root:
#   * `down` located the daemon only through $agentq_home/runtime/pueued.pid.
#     With that file gone it printed "removed <root>" and exited 0 while pueued
#     kept running.  An orphan started 2026-10-26 was still alive six days
#     later, and the shape was reproduced deliberately before it was fixed.
#   * The pid file holds a NUMBER, and the old form did `kill -0 <n>` and then
#     `kill -9 <n>`.  A stale file whose number had since been reused by an
#     unrelated process makes `down` signal a stranger -- a number is not an
#     identity.
#   * A daemon can outlive its TREE.  `up` called `down` only inside
#     `[ -e "$sandbox_root" ]`, so with the tree gone it started a SECOND pueued
#     on the same config.  Measured: two live daemons, one of them unreachable
#     because its socket died with the tree.
# Two more are about ownership and ORDER rather than identity:
#   * `up` adopted a tree it did not create (swallowed `down`'s refusal, then
#     planted the ownership marker), and the following `down` deleted the user's
#     files.
#   * `down` said "I refuse to delete this tree" after it had already deleted a
#     file inside it -- and that file was the pid file whose loss creates the
#     orphan above.
#   * `up` validated that it could rebuild the sandbox (`installer_hashes`) only
#     AFTER it had destroyed the existing one.
# The fifth is about the READER of the process table, not the table itself: the
# locator had ONE ps spelling, and on a host whose ps is BusyBox (alpine's
# default, and alpine is in this project's own matrix) that spelling is
# rejected -- which turned "I cannot look" into "nothing is running", with the
# consequences listed under the ps-flavour cases below.
#
# What this proves: `down` reaps every pueued whose argv names THIS config, and
# nothing else -- a pueued on a different config path and an unrelated process
# whose pid the stale file happens to name both survive.  `up` reaps a
# tree-less stale daemon before it starts one of its own, refuses a tree it did
# not create, and leaves a sandbox intact when it is going to fail anyway; on a
# host whose ps only speaks the BusyBox spelling it still reaps, and on a host
# whose ps it cannot use at all it stops and says so instead of guessing.
# What it does NOT prove: anything about a real remote host; and nothing about
# a sandbox root long enough for `ps` to truncate the command column.  The
# `-ww` in the locator is what removes the COLUMNS cap, measured on procps-ng
# 4.0.4: `COLUMNS=20 ps -axo pid=,command=` printed 20 chars and matched
# nothing, while `-ww` printed the full 108 and matched.  BSD ps does not cap
# the column that way, but `-ww` is accepted there too, so one spelling covers
# both.  The fallback spelling for BusyBox, `ps -o pid=,args=`, is measured to
# list every process there (BusyBox ps has no session filter); the ORDER of the
# two spellings is load-bearing, because BSD ps answers `-o pid=,args=` with a
# session-scoped 6 KB listing against 298 KB for the wide form -- a fallback
# that ran unconditionally would hide every daemon that is not in the caller's
# own session.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
sandbox="$root/sandbox.sh"
if [ ! -x "$sandbox" ]; then
    printf '%s\n' 'sandbox-daemon-reaper: FAIL (sandbox.sh is missing or not executable)' >&2
    exit 1
fi

# Deliberately not TMPDIR: the forged command line carries a config path, and
# /var/folders/<long hash>/ only makes that line longer for no benefit.
work=$(mktemp -d /tmp/agentq-smoke-reaper.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
decoys=''
cleanup() {
    for decoy_pid in $decoys; do
        kill -9 "$decoy_pid" >/dev/null 2>&1 || true
    done
    rm -rf -- "$work"
}
# A forged process is a child of an exited subshell (see forge below), so it is
# reparented and this shell never prints a "Terminated" job notice after the
# summary line -- run-tests.sh reports a check by its LAST line.
trap cleanup EXIT HUP INT TERM

failures=0
cases=0

# The config path sandbox.sh computes for a given root.  Kept in one place so
# the forged argv cannot drift from what the locator reads.
config_for() { # $1 = sandbox root -> the pueue.yml path sandbox.sh would use
    printf '%s' "$1/home/.agentq/config/pueue.yml"
}

# Forge a process whose argv looks exactly like a running daemon's: argv[0] is
# ./pueued and the config path is its own word, which is what the locator
# matches.  `exec -a` is how bash rewrites argv[0]; the ( ) subshell returns as
# soon as the pid is printed, so the recorded pid IS the process under test.
#
# The exec target is a COPY of bash NAMED pueued, running a `while` loop.  Three
# measured reasons, each from a host where the obvious form lied:
#   * BusyBox's `sleep` is an APPLET and re-derives argv[0]: on alpine
#     `exec -a './pueued ...' sleep 30` reaches ps as `sleep 30`.
#   * `bash -c 'sleep 300'` is worse in a different way: bash's final-command
#     optimization execs the child, so argv[0] comes back as `sleep 300` on
#     macOS too.  A `while` loop cannot be replaced that way, so the process
#     keeps the argv[0] `exec -a` gave it.
#   * BusyBox ps prints the kernel comm in braces as the first args word when
#     argv[0] differs from it -- measured `{bash} ./pueued --config ...`, which
#     the predicate `$2 ~ /pueued$/` does not match.  A REAL pueued is an ELF
#     whose comm IS pueued, so the fixture's comm must be too, and the copy's
#     BASENAME is what gives it one.  That basename is therefore load-bearing:
#     a copy called `forge-pueued` produced `{forge-pueued} ./pueued ...` and
#     the predicate missed (measured).
forge_setup() {
    mkdir -p "$work/forge-bin"
    FORGE_BIN="$work/forge-bin/pueued"
    cp "$(command -v bash)" "$FORGE_BIN"
    chmod 700 "$FORGE_BIN"
}
forge() { # $1 = forged argv -> prints the pid
    ( bash -c "exec -a '$1' '$FORGE_BIN' -c 'while :; do sleep 1; done'" >/dev/null 2>&1 & printf '%s\n' "$!" )
}
alive() { kill -0 "$1" >/dev/null 2>&1; }

# The reading this check does for itself must use the SAME spellings the locator
# does, or the check would be a one-spelling observer of a two-spelling asset --
# and would declare the very hosts the fallback exists for to be an environment
# fault.  Prints the listing, or nothing when no spelling is accepted.
table_dump() {
    local spelling
    for spelling in '-ww -axo pid=,command=' '-o pid=,args='; do
        # shellcheck disable=SC2086
        if ps $spelling 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# --- the premise: a forged argv really does reach `ps` ----------------------
# Every "must be reaped" case below is only meaningful if the forged command
# line is visible in the shape the locator reads.  If `exec -a` or the process
# table behaved differently here, the positive cases would fail loudly -- but
# the NEGATIVE cases would pass for no reason at all, which is why the
# calibration runs first and gates the rest.
forge_setup

cases=$((cases + 1))
probe_cfg=$(config_for "$work/probe")
probe_pid=$(forge "./pueued --config $probe_cfg")
decoys="$decoys $probe_pid"
sleep 0.3
probe_line=$(table_dump | awk -v wanted="$probe_pid" '$1 == wanted')
premise_ok=true
case $probe_line in
*"pueued --config $probe_cfg"*) : ;;
*)
    premise_ok=false
    printf "sandbox-daemon-reaper: this host shows a forged argv through neither of the locator's spellings (line was [%s]) -- an ENVIRONMENT fault, so the reaper cases were not run\n" \
        "$probe_line" >&2
    failures=$((failures + 1))
    ;;
esac
kill -9 "$probe_pid" >/dev/null 2>&1 || true

if [ "$premise_ok" = true ]; then
    # --- the pid file is GONE and the daemon is not -------------------------
    # The original orphan: `down` reaped only the pid the file named, so a
    # missing file meant "nothing to do" while the daemon kept running.
    cases=$((cases + 1))
    sb_gone="$work/pidfile-gone"
    pid_gone=$(forge "./pueued --config $(config_for "$sb_gone")")
    decoys="$decoys $pid_gone"
    mkdir -p "$sb_gone/home/.agentq/runtime"
    : >"$sb_gone/.agentq-sandbox"
    sleep 0.3
    down_gone_status=0
    AGENTQ_SANDBOX_ROOT="$sb_gone" "$sandbox" down >"$work/down-gone.out" 2>&1 || down_gone_status=$?
    if [ "$down_gone_status" -ne 0 ]; then
        printf 'sandbox-daemon-reaper: down exited %s on a marked tree whose pid file was absent (expected 0): %s\n' \
            "$down_gone_status" "$(tr '\n' '|' <"$work/down-gone.out")" >&2
        failures=$((failures + 1))
    fi
    if alive "$pid_gone"; then
        printf '%s\n' 'sandbox-daemon-reaper: down left the daemon running because its pid file was absent -- that is the 2026-10-26 orphan, found six days late' >&2
        failures=$((failures + 1))
    fi

    # --- a stale pid file naming an INNOCENT process ------------------------
    # The number in the file can belong to anything by the time `down` reads it.
    # Killing it would be `down` reaching outside the sandbox entirely.
    cases=$((cases + 1))
    sb_stale="$work/stale-number"
    pid_stale=$(forge "./pueued --config $(config_for "$sb_stale")")
    innocent=$(forge 'sleep 300 --not-a-daemon')
    decoys="$decoys $pid_stale $innocent"
    mkdir -p "$sb_stale/home/.agentq/runtime"
    : >"$sb_stale/.agentq-sandbox"
    printf '%s\n' "$innocent" >"$sb_stale/home/.agentq/runtime/pueued.pid"
    sleep 0.3
    AGENTQ_SANDBOX_ROOT="$sb_stale" "$sandbox" down >"$work/down-stale.out" 2>&1 || true
    if ! alive "$innocent"; then
        printf 'sandbox-daemon-reaper: down KILLED pid %s, which is not a pueued -- the pid file names a number, and a reused number is somebody else\n' \
            "$innocent" >&2
        failures=$((failures + 1))
    fi
    if alive "$pid_stale"; then
        printf '%s\n' 'sandbox-daemon-reaper: down chased the pid file and missed the daemon running on its OWN config' >&2
        failures=$((failures + 1))
    fi

    # --- a pueued on a DIFFERENT config path --------------------------------
    # The locator matches the config path, so a sandbox must never reach into a
    # sibling sandbox or another developer's runtime.
    cases=$((cases + 1))
    sb_other="$work/other-config"
    pid_other=$(forge "./pueued --config $(config_for "$sb_other")")
    pid_stranger=$(forge "./pueued --config $(config_for "$work/not-our-sandbox")")
    decoys="$decoys $pid_other $pid_stranger"
    mkdir -p "$sb_other/home/.agentq/runtime"
    : >"$sb_other/.agentq-sandbox"
    sleep 0.3
    AGENTQ_SANDBOX_ROOT="$sb_other" "$sandbox" down >"$work/down-other.out" 2>&1 || true
    if alive "$pid_stranger"; then
        :
    else
        printf 'sandbox-daemon-reaper: down killed a pueued whose config path belongs to a DIFFERENT sandbox (pid %s)\n' \
            "$pid_stranger" >&2
        failures=$((failures + 1))
    fi
    if alive "$pid_other"; then
        printf '%s\n' 'sandbox-daemon-reaper: down missed the daemon on its own config while sparing the stranger' >&2
        failures=$((failures + 1))
    fi

    # --- `up` with a tree-less stale daemon ---------------------------------
    # No tree at all: exactly the state in which `up` used to skip the reap (its
    # guard was `[ -e "$sandbox_root" ]`) and start a second daemon on a config
    # nobody could then reach.  A curl stub makes the install step fail at once,
    # so this case needs no network and no pueue download -- what is asserted is
    # only that the stale daemon was gone by the time `up` gave up.
    cases=$((cases + 1))
    sb_bare="$work/tree-less"
    pid_bare=$(forge "./pueued --config $(config_for "$sb_bare")")
    decoys="$decoys $pid_bare"
    mkdir -p "$work/stub-bin"
    cat >"$work/stub-bin/curl" <<'STUB'
#!/bin/sh
printf 'sandbox-daemon-reaper: downloads are disabled in this case\n' >&2
exit 22
STUB
    chmod 700 "$work/stub-bin/curl"
    sleep 0.3
    up_bare_status=0
    PATH="$work/stub-bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_bare" "$sandbox" up \
        >"$work/up-bare.out" 2>&1 || up_bare_status=$?
    if [ "$up_bare_status" -eq 0 ]; then
        printf '%s\n' 'sandbox-daemon-reaper: up succeeded although every download was stubbed to fail; this case cannot tell whether the reap happened' >&2
        failures=$((failures + 1))
    fi
    if alive "$pid_bare"; then
        printf '%s\n' 'sandbox-daemon-reaper: up left a tree-less daemon alive and went on to start its own -- two pueueds on one config, one unreachable' >&2
        failures=$((failures + 1))
    fi

    # --- `up` must never adopt a tree it did not create ----------------------
    # The marker is the whole ownership proof.  `down` refuses an unmarked tree,
    # but that refusal was swallowed by `up`: it printed a note, `mkdir -p` found
    # the directory already there, and the very next line wrote the marker into
    # somebody else's tree -- after which `down` happily deleted it.  Measured
    # 2026-11-02 against a directory holding precious/keep.txt: up exited 0,
    # planted the marker, and the following `down` printed "removed <root>" and
    # deleted the file.  A refusal has to stop the caller, not just the callee.
    #
    # The download stub (created for the tree-less case above) makes `up` fail
    # after it has taken ownership, so in the mutant world the tree is destroyed
    # by `up`'s own partial-cleanup trap rather than by the later `down`.  Each
    # message below names only what was observed at that point in the sequence:
    # attributing a deletion to the wrong command is exactly the kind of
    # "evidence" this project keeps having to correct.
    cases=$((cases + 1))
    sb_foreign="$work/not-ours"
    mkdir -p "$sb_foreign/precious"
    printf 'user data\n' >"$sb_foreign/precious/keep.txt"
    up_foreign_status=0
    PATH="$work/stub-bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_foreign" "$sandbox" up \
        >"$work/up-foreign.out" 2>&1 || up_foreign_status=$?
    if [ "$up_foreign_status" -eq 0 ]; then
        printf '%s\n' 'sandbox-daemon-reaper: up exited 0 on a pre-existing tree it did not create' >&2
        failures=$((failures + 1))
    fi
    if [ -f "$sb_foreign/.agentq-sandbox" ]; then
        printf '%s\n' 'sandbox-daemon-reaper: up planted its ownership marker into a foreign tree -- every later down will delete it' >&2
        failures=$((failures + 1))
    fi
    if [ ! -f "$sb_foreign/precious/keep.txt" ]; then
        printf '%s\n' 'sandbox-daemon-reaper: up destroyed a tree it did not create (precious/keep.txt is gone after up alone)' >&2
        failures=$((failures + 1))
    else
        AGENTQ_SANDBOX_ROOT="$sb_foreign" "$sandbox" down >"$work/down-foreign.out" 2>&1 || true
        if [ ! -f "$sb_foreign/precious/keep.txt" ]; then
            printf '%s\n' 'sandbox-daemon-reaper: down DELETED a directory this script did not create (precious/keep.txt is gone)' >&2
            failures=$((failures + 1))
        fi
    fi

    # --- `down` must not MUTATE a tree it refuses to delete -------------------
    # "I will not delete this tree" is not the same promise as "I will not touch
    # it".  The pid-file removal ran before the ownership check, so `down` on a
    # foreign tree printed "refusing to delete it", exited 1, and had already
    # deleted a file inside it.  Worse, the file it deleted is exactly the pid
    # file whose loss creates the orphan this check exists to prevent -- the
    # refusal was manufacturing the failure mode.  Measured 2026-11-02: a foreign
    # tree's runtime/pueued.pid was gone after the refusal.
    cases=$((cases + 1))
    sb_mutate="$work/refuse-without-touching"
    mkdir -p "$sb_mutate/home/.agentq/runtime"
    printf '12345\n' >"$sb_mutate/home/.agentq/runtime/pueued.pid"
    printf 'notes\n' >"$sb_mutate/home/.agentq/runtime/notes.txt"
    AGENTQ_SANDBOX_ROOT="$sb_mutate" "$sandbox" down >"$work/down-mutate.out" 2>&1 || true
    if [ ! -f "$sb_mutate/home/.agentq/runtime/pueued.pid" ]; then
        printf '%s\n' 'sandbox-daemon-reaper: down deleted the pid file of a tree it refused to delete -- a missing pid file is exactly how the 2026-10-26 orphan was born' >&2
        failures=$((failures + 1))
    fi
    if [ ! -f "$sb_mutate/home/.agentq/runtime/notes.txt" ]; then
        printf '%s\n' 'sandbox-daemon-reaper: down touched a foreign tree beyond the ownership decision' >&2
        failures=$((failures + 1))
    fi

    # --- a doomed `up` must not destroy the sandbox it cannot rebuild ---------
    # `installer_hashes` reads a file in the checkout and dies if it is missing.
    # It ran AFTER the reap, so with a healthy sandbox running and the repo
    # temporarily broken, `up` tore the sandbox down and only then died: the user
    # has neither a working sandbox nor the means to rebuild one, and a valid
    # tree was destroyed for nothing.  Measured 2026-11-02 with the installer
    # moved aside -- "removing a stale sandbox", tree gone, then "installer not
    # found".  A destructive step must follow the cheap checks that can abort it.
    #
    # The fixture is a sandbox this script builds itself (a marked tree), made to
    # look stale by deleting its socket; the repo is broken by pointing the
    # checkout root at a copy with no installer.
    cases=$((cases + 1))
    sb_doomed="$work/doomed-rebuild"
    fake_root="$work/doomed-repo"
    mkdir -p "$fake_root/skill/assets/unix" "$sb_doomed/home/.agentq/config" "$sb_doomed/home/.agentq/runtime"
    : >"$sb_doomed/.agentq-sandbox"
    printf 'shared:\n  pueue_directory: x\n' >"$sb_doomed/home/.agentq/config/pueue.yml"
    # A copy of the script whose $root resolves to the installer-less tree, so the
    # case is hermetic: it never touches this repo.
    sed "s#^root=\$(unset CDPATH.*#root=$fake_root#" "$sandbox" >"$fake_root/sandbox.sh"
    chmod 700 "$fake_root/sandbox.sh"
    if grep -q "root=$fake_root" "$fake_root/sandbox.sh"; then
        up_doomed_rc=0
        PATH="$work/stub-bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_doomed" "$fake_root/sandbox.sh" up \
            >"$work/up-doomed.out" 2>&1 || up_doomed_rc=$?
        # Positive control first: the run must fail ON THE INSTALLER.  Without
        # this, a copy that dies for some earlier reason leaves the tree alone
        # and the assertion below goes green for the wrong reason.
        if [ "$up_doomed_rc" -eq 0 ] || ! grep -q 'installer not found' "$work/up-doomed.out"; then
            printf 'sandbox-daemon-reaper: the doomed-up case did not fail on the missing installer (exit %s), so it proves nothing\n' "$up_doomed_rc" >&2
            failures=$((failures + 1))
        fi
        if [ ! -d "$sb_doomed" ]; then
            printf '%s\n' 'sandbox-daemon-reaper: up destroyed a healthy sandbox and only then failed on a missing installer -- nothing was left to rebuild from' >&2
            failures=$((failures + 1))
        fi
    else
        printf '%s\n' 'sandbox-daemon-reaper: could not rewrite the checkout root in the copy, so the doomed-up case did not run' >&2
        failures=$((failures + 1))
    fi

    # --- "I cannot look" must not read as "nothing is running" ---------------
    # The locator read the process table with one spelling only:
    # `ps -ww -axo pid=,command=`.  BusyBox ps (alpine's default) rejects both
    # flags (`ps: unrecognized option: w`) and does not know `command` at all,
    # so on such a host the locator failed -- and failed SILENTLY.  With
    # pipefail the failing `ps` masked awk's 0, `set -e` killed the script at
    # `pids=$(sandbox_daemon_pids)`, and `down` exited 1 having printed nothing
    # at all.  Measured 2026-11-02 on alpine:3.20 and with a faithful stub:
    #   * `down`: exit 1, stdout 0 bytes, stderr 0 bytes, tree kept, daemon alive.
    #   * `status`: printed "pueued: not running" about a daemon it could not see.
    #   * `up`: `cmd_down || true` swallowed the failure, then deleted the tree
    #     and left the daemon running -- the orphan plus "destroyed for nothing",
    #     the two shapes the earlier cases in this file exist to prevent.
    #
    # Two fixtures, because they prove different things:
    #   A. a BusyBox-shaped ps: accepts ONLY `-o pid=,args=` (and implements it
    #      by delegating to the real ps, so the output shape is honest).  The
    #      fixed locator must fall back to it and do the job properly.
    #   B. a ps that rejects every spelling: the locator must SAY it cannot
    #      look and must touch nothing -- never answer "nothing running".
    mk_ps() { # $1 = dir, $2 = busybox|reject
        mkdir -p "$1"
        if [ "$2" = busybox ]; then
            # Delegating with a FIXED spelling made this stub wrong twice over,
            # both measured: `-ww -axo` fails on the very host it emulates
            # (alpine: BusyBox rejects -ww), and a bare `-o pid=,args=` is
            # session-scoped on macOS (6 KB against 298 KB) so it hid the
            # process under test.  What the stub must produce is a FULL listing
            # in `pid args` shape, so it asks the real ps for one with the same
            # preference order the locator uses.
            cat >"$1/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -ne 2 ] || [ "$1" != "-o" ] || [ "$2" != "pid=,args=" ]; then
    printf 'ps: unrecognized option: %s\n' "${1#-}" >&2
    exit 1
fi
for cand in '-ww -axo pid=,command=' '-axo pid=,args=' '-o pid=,args='; do
    if out=$(/bin/ps $cand 2>/dev/null); then
        printf '%s\n' "$out"
        exit 0
    fi
done
exit 1
STUB
        else
            cat >"$1/ps" <<'STUB'
#!/usr/bin/env bash
printf 'ps: unrecognized option: %s\n' "${1#-}" >&2
exit 1
STUB
        fi
        chmod 700 "$1/ps"
    }

    # --- A: a BusyBox-shaped ps is handled, not merely survived ---------------
    cases=$((cases + 1))
    bb_bin="$work/ps-busybox-bin"
    mk_ps "$bb_bin" busybox
    bb_cal="$work/ps-busybox-cal"
    mkdir -p "$bb_cal/home/.agentq/config"
    : >"$bb_cal/.agentq-sandbox"
    bb_cal_pid=$(forge "./pueued --config $(config_for "$bb_cal")")
    decoys="$decoys $bb_cal_pid"
    sleep 0.3
    bb_cal_hits=$(PATH="$bb_bin:$PATH" ps -o pid=,args= 2>/dev/null |
        awk -v c="$(config_for "$bb_cal")" 'index($0, c) > 0' | wc -l | tr -d ' ')
    if [ "$bb_cal_hits" -lt 1 ]; then
        printf '%s\n' 'sandbox-daemon-reaper: the BusyBox-shaped ps stub does not show a forged argv through -o pid=,args= -- an ENVIRONMENT fault, so the ps-flavour cases were not run' >&2
        failures=$((failures + 1))
    else
        # `down` must find and reap the daemon through the fallback spelling.
        cases=$((cases + 1))
        sb_bb="$work/ps-busybox-down"
        mkdir -p "$sb_bb/home/.agentq/config"
        : >"$sb_bb/.agentq-sandbox"
        bb_pid=$(forge "./pueued --config $(config_for "$sb_bb")")
        decoys="$decoys $bb_pid"
        sleep 0.3
        bb_rc=0
        PATH="$bb_bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_bb" "$sandbox" down \
            >"$work/down-busybox.out" 2>&1 || bb_rc=$?
        if [ "$bb_rc" -ne 0 ]; then
            printf 'sandbox-daemon-reaper: down exited %s on a host whose ps only speaks the BusyBox spelling: %s\n' \
                "$bb_rc" "$(tr '\n' '|' <"$work/down-busybox.out")" >&2
            failures=$((failures + 1))
        fi
        if alive "$bb_pid"; then
            printf '%s\n' 'sandbox-daemon-reaper: down could not find the daemon because its ps is BusyBox -- the locator has no fallback spelling' >&2
            failures=$((failures + 1))
        fi
    fi

    # --- B: a ps that answers nothing must produce a verdict, not a guess -----
    cases=$((cases + 1))
    rej_bin="$work/ps-reject-bin"
    mk_ps "$rej_bin" reject
    rej_ok=true
    for cand in '-ww -axo pid=,command=' '-ww -o pid=,args=' '-o pid=,args=' '-axo pid=,args='; do
        # shellcheck disable=SC2086
        if PATH="$rej_bin:$PATH" ps $cand >/dev/null 2>&1; then rej_ok=false; fi
    done
    if [ "$rej_ok" = false ]; then
        printf '%s\n' 'sandbox-daemon-reaper: the rejecting ps stub accepted a spelling, so the unusable-ps cases would prove nothing' >&2
        failures=$((failures + 1))
    else
        # `down`: nonzero, tells the user, and touches nothing.
        cases=$((cases + 1))
        sb_blind="$work/ps-unusable-down"
        mkdir -p "$sb_blind/home/.agentq/config"
        : >"$sb_blind/.agentq-sandbox"
        blind_pid=$(forge "./pueued --config $(config_for "$sb_blind")")
        decoys="$decoys $blind_pid"
        sleep 0.3
        down_blind_rc=0
        PATH="$rej_bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_blind" "$sandbox" down \
            >"$work/down-blind.out" 2>&1 || down_blind_rc=$?
        if [ "$down_blind_rc" -eq 0 ]; then
            printf '%s\n' 'sandbox-daemon-reaper: down claimed success while it could not inspect the process table' >&2
            failures=$((failures + 1))
        fi
        if [ ! -s "$work/down-blind.out" ]; then
            printf '%s\n' 'sandbox-daemon-reaper: down failed on an unreadable process table with ZERO bytes of output -- measured as exit 1 with no message, which is the shape that hid this defect' >&2
            failures=$((failures + 1))
        fi
        if [ ! -d "$sb_blind" ]; then
            printf '%s\n' 'sandbox-daemon-reaper: down deleted the tree although it could not tell whether a daemon was running' >&2
            failures=$((failures + 1))
        fi
        if ! alive "$blind_pid"; then
            printf '%s\n' 'sandbox-daemon-reaper: down killed a process it could not identify' >&2
            failures=$((failures + 1))
        fi

        # `up` in the same state must stop before it destroys anything.
        cases=$((cases + 1))
        sb_blind_up="$work/ps-unusable-up"
        mkdir -p "$sb_blind_up/home/.agentq/config"
        : >"$sb_blind_up/.agentq-sandbox"
        up_blind_pid=$(forge "./pueued --config $(config_for "$sb_blind_up")")
        decoys="$decoys $up_blind_pid"
        sleep 0.3
        up_blind_rc=0
        # The download stub from the tree-less case keeps this hermetic: without
        # it `up` would really fetch pueue and start a daemon for the fixture.
        PATH="$rej_bin:$work/stub-bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_blind_up" "$sandbox" up \
            >"$work/up-blind.out" 2>&1 || up_blind_rc=$?
        if [ ! -d "$sb_blind_up" ]; then
            printf '%s\n' 'sandbox-daemon-reaper: up deleted the sandbox although it could not list processes -- "could not look" was treated as "nothing running"' >&2
            failures=$((failures + 1))
        fi
        if ! alive "$up_blind_pid"; then
            printf '%s\n' 'sandbox-daemon-reaper: up killed a process it could not identify' >&2
            failures=$((failures + 1))
        fi
        if [ "$up_blind_rc" -eq 0 ] || [ ! -s "$work/up-blind.out" ]; then
            printf 'sandbox-daemon-reaper: up could not inspect the process table and said so nowhere (exit %s, %s bytes)\n' \
                "$up_blind_rc" "$(wc -c <"$work/up-blind.out" | tr -d ' ')" >&2
            failures=$((failures + 1))
        fi

        # `status`: an unknown verdict must not read as a negative one.
        cases=$((cases + 1))
        sb_st="$work/ps-unusable-status"
        mkdir -p "$sb_st/home/.agentq/config"
        : >"$sb_st/.agentq-sandbox"
        st_pid=$(forge "./pueued --config $(config_for "$sb_st")")
        decoys="$decoys $st_pid"
        sleep 0.3
        PATH="$rej_bin:$PATH" AGENTQ_SANDBOX_ROOT="$sb_st" "$sandbox" status \
            >"$work/status-blind.out" 2>&1 || true
        if grep -qi 'pueued: *not running' "$work/status-blind.out"; then
            printf '%s\n' 'sandbox-daemon-reaper: status printed "pueued: not running" about a daemon it could not see -- an unknown verdict must not read as a negative one' >&2
            failures=$((failures + 1))
        fi
    fi

fi

if [ "$failures" -ne 0 ]; then
    printf 'sandbox-daemon-reaper: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'sandbox-daemon-reaper checks passed: cases=%s locator=config-path pidfile=not-authoritative innocent=spared sibling=spared orphan=reaped tree-less=reaped foreign-tree=rejected refusal=read-only doomed-up=non-destructive ps-blind=reported\n' "$cases"
