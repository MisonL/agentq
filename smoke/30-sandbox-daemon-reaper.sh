#!/usr/bin/env bash
# Smoke: the dev sandbox must identify its own pueued by the CONFIG PATH that
# process was started with -- never by the pid file alone, and never by a bare
# pid number.
#
# Three measured defects (2026-11-02), one root:
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
#
# What this proves: `down` reaps every pueued whose argv names THIS config, and
# nothing else -- a pueued on a different config path and an unrelated process
# whose pid the stale file happens to name both survive.  `up` reaps a
# tree-less stale daemon before it starts one of its own.
# What it does NOT prove: anything about a real remote host; and nothing about
# a sandbox root long enough for `ps` to truncate the command column.  The
# `-ww` in the locator is what removes the COLUMNS cap, measured on procps-ng
# 4.0.4: `COLUMNS=20 ps -axo pid=,command=` printed 20 chars and matched
# nothing, while `-ww` printed the full 108 and matched.  BSD ps does not cap
# the column that way, but `-ww` is accepted there too, so one spelling covers
# both.
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
forge() { # $1 = forged argv -> prints the pid
    ( bash -c "exec -a '$1' sleep 300" >/dev/null 2>&1 & printf '%s\n' "$!" )
}
alive() { kill -0 "$1" >/dev/null 2>&1; }

# --- the premise: a forged argv really does reach `ps` ----------------------
# Every "must be reaped" case below is only meaningful if the forged command
# line is visible in the shape the locator reads.  If `exec -a` or `ps -ww`
# behaved differently here, the positive cases would fail loudly -- but the
# NEGATIVE cases would pass for no reason at all, which is why the calibration
# runs first and gates the rest.
cases=$((cases + 1))
probe_cfg=$(config_for "$work/probe")
probe_pid=$(forge "./pueued --config $probe_cfg")
decoys="$decoys $probe_pid"
sleep 0.3
probe_line=$(ps -ww -axo pid=,command= 2>/dev/null | awk -v wanted="$probe_pid" '$1 == wanted')
premise_ok=true
case $probe_line in
*"pueued --config $probe_cfg"*) : ;;
*)
    premise_ok=false
    printf 'sandbox-daemon-reaper: this host does not expose a forged argv through ps -ww -axo (line was [%s]) -- an ENVIRONMENT fault, so the reaper cases were not run\n' \
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
    AGENTQ_SANDBOX_ROOT="$sb_foreign" "$sandbox" down >"$work/down-foreign.out" 2>&1 || true
    if [ ! -f "$sb_foreign/precious/keep.txt" ]; then
        printf '%s\n' 'sandbox-daemon-reaper: down DELETED a directory this script did not create (precious/keep.txt is gone)' >&2
        failures=$((failures + 1))
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
fi

if [ "$failures" -ne 0 ]; then
    printf 'sandbox-daemon-reaper: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'sandbox-daemon-reaper checks passed: cases=%s locator=config-path pidfile=not-authoritative innocent=spared sibling=spared orphan=reaped tree-less=reaped foreign-tree=rejected refusal=read-only\n' "$cases"
