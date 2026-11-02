#!/usr/bin/env bash
# Build a throwaway AgentQ runtime so smoke/03, 04, 06 and 07 can actually run.
#
# Those four checks need a real `pueue` binary and a running `pueued`; the
# project does not vendor them, so they SKIP by default.  This script assembles
# the runtime in /tmp and prints the AGENTQ_SMOKE_HOME to point at.
#
#   ./sandbox.sh up      build it, start pueued, print the env var
#   ./sandbox.sh down    stop pueued and delete the sandbox
#   ./sandbox.sh status  report what is running
#
# It lives at the repo root, NOT in smoke/: run-tests.sh discovers checks with
# `find smoke -name '*.sh'`, so a helper in there would be executed as a check.
#
# What it deliberately does not do: touch the real ~/.agentq, the real launchd
# domain, or any system path.  Everything is under /tmp.  The pueue binaries are
# fetched from the URL and verified against the hashes the INSTALLER pins --
# extracted from assets/unix/install-agentq.sh at run time rather than copied
# here, so the two cannot drift apart.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
installer="$root/skill/assets/unix/install-agentq.sh"

# Short path on purpose: pueued binds a unix socket inside the home and macOS
# caps the path at SUN_LEN (~104 bytes).  $TMPDIR is /var/folders/<long hash>/T/
# and DOES fail; /tmp does not.  Measured: this path is 46 bytes.
sandbox_root=${AGENTQ_SANDBOX_ROOT:-/tmp/aqsb}
home="$sandbox_root/home"
agentq_home="$home/.agentq"
cache="$sandbox_root-cache"
marker="$sandbox_root/.agentq-sandbox"
config="$agentq_home/config/pueue.yml"

die() {
    printf 'sandbox: %s\n' "$1" >&2
    exit 1
}

# A failure part-way through `up` must not leave a half-built tree behind: the
# next `up` would find it and report "removing a stale sandbox", and a user
# reading the directory would see something that looks runnable but is not.
# Only a tree this script marked is removed.
cleanup_partial() {
    if [ -f "$marker" ]; then
        rm -rf -- "$sandbox_root" 2>/dev/null || true
    fi
}

# Pids of every pueued running against THIS sandbox's config.
#
# Located by the --config path the process was started with, read from the
# process table -- NOT by the pid file.  Two measured reasons (2026-11-02):
#
#   * a daemon can outlive its pid file.  `down` used to reap only the pid the
#     file named, so when the file was gone (or the tree had been removed
#     underneath the daemon) it printed "removed <root>" and exited 0 while the
#     daemon kept running: an orphan started 2026-10-26 was still up six days
#     later, and a decoy reproduced the same shape here.
#   * the pid file holds a NUMBER, and `kill -0 <number>` cannot tell the
#     daemon from an unrelated process that later REUSED that number.  The old
#     form would `kill -9` a stranger.  Matching the config path fixes this by
#     construction: only a process actually running our config matches.
#
# `$2 ~ /pueued$/` requires argv[0] to be pueued, so a shell or editor whose
# command line merely MENTIONS the path is not matched.  Verified on macOS and
# ubuntu:24.04 with forged-argv decoys, including one on a DIFFERENT config
# path (not returned).  Boundary: the match reads `ps`'s command column, so a
# sandbox root long enough for ps to truncate it would not match; sandbox.sh
# keeps the root short for SUN_LEN anyway (see below).
#
# `-ww` is load-bearing on Linux: procps `ps` caps the command column at
# $COLUMNS even when stdout is a pipe, so an inherited narrow COLUMNS would
# truncate the line before config path and reboot the orphan this function
# exists to prevent.  Measured 2026-11-02 on procps-ng 4.0.4: with COLUMNS=20,
# `ps -axo pid=,command=` printed 20 chars and the predicate matched nothing,
# while `ps -ww ...` printed the full 108 and matched.  BSD ps (macOS) does not
# truncate the same way, but -ww is accepted there too, so one spelling covers
# both.
#
# TWO spellings, and the second one is not optional.  BusyBox ps -- alpine's
# default, and alpine is in this project's own platform matrix -- rejects BOTH
# `-w` and `-x` (`ps: unrecognized option: w`) and has no `command` column, so
# the single spelling this function used to have matched NOTHING there.  It did
# not fail loudly either: with pipefail the failing ps masked awk's 0, `set -e`
# killed the script at the assignment in cmd_down, and `down` exited 1 having
# printed nothing at all -- while `status` answered "not running" and `up`
# deleted the tree and left the daemon running.  Measured 2026-11-02 on
# alpine:3.20 and reproduced with a stub.  BusyBox accepts `-o pid=,args=`, and
# its ps lists every process by default, so that spelling is a faithful
# fallback THERE -- but it is used only when the first one is REJECTED, never
# as a second opinion: BSD ps answers `-ww -axo pid=,command=` correctly and
# its `-o pid=,args=` form silently lists only the current session (measured:
# 6 KB against 298 KB), so a fallback that ran unconditionally would hide every
# daemon that is not ours.
#
# `ps -ww -o pid=,args=` is deliberately NOT a candidate: procps accepts it and
# needs the -ww, but BSD ps accepts it and silently returns the session-scoped
# listing, so it is the one spelling that is wrong in both possible ways.
#
# Every caller must treat a nonzero return as "I could not look", never as "no
# daemons": the two are the difference between deleting a tree and leaving an
# orphan, and getting it wrong is what made the orphan this function exists for.
sandbox_daemon_pids() {
    local spelling out
    for spelling in '-ww -axo pid=,command=' '-o pid=,args='; do
        # shellcheck disable=SC2086 # the spelling is an argument LIST
        if out=$(ps $spelling 2>/dev/null); then
            printf '%s\n' "$out" |
                awk -v cfg="$config" 'index($0, cfg) > 0 && $2 ~ /pueued$/ { print $1 }'
            return 0
        fi
    done
    printf "sandbox: cannot read the process table: this host's ps accepted neither 'ps -ww -axo pid=,command=' nor 'ps -o pid=,args='\n" >&2
    return 1
}

# The one daemon this sandbox owns, for the status and ready displays.
# 0 = pid printed; 1 = the table was read and no daemon matches; 2 = the table
# could not be read -- callers must not read 2 as "not running".
daemon_pid() {
    local pids pid rc=0
    pids=$(sandbox_daemon_pids) || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 2
    fi
    pid=$(printf '%s\n' "$pids" | sed -n '1p')
    [ -n "$pid" ] || return 1
    printf '%s' "$pid"
}

daemon_responds() {
    [ -x "$agentq_home/pueue" ] || return 1
    [ -f "$config" ] || return 1
    "$agentq_home/pueue" --config "$config" status --json >/dev/null 2>&1
}

# Hash and asset name for this platform, read out of the installer's case block.
installer_hashes() {
    [ -f "$installer" ] || die "installer not found: $installer"
    local key
    case "$(uname -s):$(uname -m)" in
    Linux:x86_64) key='Linux:x86_64' ;;
    Linux:aarch64 | Linux:arm64) key='Linux:aarch64|Linux:arm64' ;;
    Darwin:x86_64) key='Darwin:x86_64' ;;
    Darwin:arm64) key='Darwin:arm64' ;;
    *) die "unsupported platform: $(uname -s) $(uname -m)" ;;
    esac
    local block
    block=$(awk -v key="$key)" 'index($0, "    " key) == 1 { f = 1; next } f && /;;/ { exit } f { print }' "$installer")
    [ -n "$block" ] || die "could not read the $key block from the installer"
    PUEUE_ASSET=$(printf '%s\n' "$block" | sed -n "s/^ *pueue_asset='\([^']*\)'.*/\1/p")
    PUEUE_SHA=$(printf '%s\n' "$block" | sed -n "s/^ *pueue_sha256='\([^']*\)'.*/\1/p")
    PUEUED_ASSET=$(printf '%s\n' "$block" | sed -n "s/^ *pueued_asset='\([^']*\)'.*/\1/p")
    PUEUED_SHA=$(printf '%s\n' "$block" | sed -n "s/^ *pueued_sha256='\([^']*\)'.*/\1/p")
    for value in "$PUEUE_ASSET" "$PUEUE_SHA" "$PUEUED_ASSET" "$PUEUED_SHA"; do
        [ -n "$value" ] || die "incomplete hash block for $key in the installer"
    done
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "no shasum or sha256sum available"
    fi
}

# Fetch one binary into the cache, verifying against the installer's hash.
# A cached copy that already matches is reused, so repeat runs need no network.
fetch_verified() {
    local asset=$1 expected=$2 destination=$3
    local url="https://github.com/Nukesor/pueue/releases/download/v4.0.4/$asset"
    local cached="$cache/$asset"
    mkdir -p "$cache"
    if [ -f "$cached" ] && [ "$(sha256_of "$cached")" = "$expected" ]; then
        printf '  %s (cached, hash ok)\n' "$asset"
    else
        rm -f "$cached"
        printf '  %s (downloading)\n' "$asset"
        curl -fsSL -o "$cached" "$url" || die "download failed: $url"
        local actual
        actual=$(sha256_of "$cached")
        if [ "$actual" != "$expected" ]; then
            rm -f "$cached"
            die "sha256 mismatch for $asset: expected $expected, got $actual"
        fi
    fi
    cp "$cached" "$destination"
    chmod 700 "$destination"
}

cmd_up() {
    if daemon_responds; then
        # Refresh the server copy even on the idempotent path: the sandbox is
        # reused across days, so this file would otherwise stay at whatever the
        # repo held the day the sandbox was BUILT (measured 2026-10-21: 247276
        # bytes against the repo's 248213).  smoke/03 stages the repo asset
        # itself and no longer depends on this, but a human poking at the
        # sandbox with `$AGENTQ_SMOKE_HOME/agentq-server status` would be
        # running a different build than the one under test.  Nothing else is
        # touched -- the daemon keeps running untouched.
        cp "$root/skill/assets/unix/agentq-server" "$agentq_home/agentq-server"
        chmod 700 "$agentq_home/agentq-server"
        printf 'sandbox already running.\n\n  AGENTQ_SMOKE_HOME=%s ./run-tests.sh\n\n' "$agentq_home"
        return 0
    fi
    # Validate the repo BEFORE anything is torn down.  `installer_hashes` reads
    # the installer and dies if it is missing or its hash block is incomplete --
    # a cheap local check, but it used to run AFTER the reap below.  Measured
    # 2026-11-02: with a healthy sandbox running and the installer temporarily
    # moved aside, `up` printed "removing a stale sandbox", deleted the tree,
    # killed the daemon, and only then died on the missing installer -- leaving
    # neither a working sandbox nor the ability to rebuild one.  A destructive
    # step must come after the cheap checks that can abort it, not before.
    installer_hashes
    # A tree may only be reaped if THIS script created it, and the marker is what
    # says so.  `down` already refuses an unmarked tree, but `up` printed a note
    # and carried on -- so the refusal was swallowed, `mkdir -p` found the
    # directory already there, and the next line wrote the marker into somebody
    # else's tree.  Measured 2026-11-02: with AGENTQ_SANDBOX_ROOT pointing at a
    # directory holding precious/keep.txt, `up` exited 0 and planted the marker,
    # and the following `down` printed "removed <root>" and deleted the file.
    # Refuse BEFORE the daemon reap, so nothing at all is touched: an unmarked
    # tree is not ours, and a `down` that declines to delete it does not license
    # `up` to adopt it.
    if [ -e "$sandbox_root" ] && [ ! -f "$marker" ]; then
        die "$sandbox_root exists but carries no $(basename "$marker") marker; refusing to touch a tree this script did not create -- move it aside, or pick another AGENTQ_SANDBOX_ROOT"
    fi
    if [ -e "$sandbox_root" ]; then
        printf 'sandbox: removing a stale sandbox at %s\n' "$sandbox_root" >&2
    fi
    # Reap unconditionally, not only when the tree is still there.  A daemon can
    # outlive its tree: if `down` runs after the pid file is gone it reports
    # success and leaves the daemon behind, and if the tree was then deleted the
    # daemon keeps running on a config path that no longer exists.  A later `up`
    # used to skip `down` in exactly that state (tree absent, daemon not
    # answering, since its socket went with the tree) and start a SECOND pueued
    # on the same config -- measured 2026-11-02: two live pueueds, one of them
    # unreachable.  We already know none responds, so any match here is useless
    # and must go before a new one binds.
    # The failure mode this must never recreate: `|| true` here swallowed
    # cmd_down's "cannot read the process table" refusal on a BusyBox-ps host,
    # after which up deleted the tree and left the daemon running (measured
    # 2026-11-02).  cmd_down's stderr is allowed through so the reason is on
    # screen, and a nonzero return stops the rebuild -- an unknown process
    # table is not a clean slate, it is an unexamined one.
    local down_rc=0
    cmd_down >/dev/null || down_rc=$?
    if [ "$down_rc" -ne 0 ]; then
        die "could not stop the previous sandbox (reason above); refusing to delete or rebuild over an unexamined state"
    fi

    mkdir -p "$home" "$agentq_home/config" "$agentq_home/data/task_logs" "$agentq_home/runtime"
    : >"$marker"
    # From here the tree exists; clear it if anything below fails.
    up_complete=false
    trap 'if [ "$up_complete" != true ]; then cleanup_partial; fi' EXIT

    printf 'fetching pueue 4.0.4 for %s\n' "$(uname -s) $(uname -m)"
    fetch_verified "$PUEUE_ASSET" "$PUEUE_SHA" "$agentq_home/pueue"
    fetch_verified "$PUEUED_ASSET" "$PUEUED_SHA" "$agentq_home/pueued"
    cp "$root/skill/assets/unix/agentq-server" "$agentq_home/agentq-server"
    chmod 700 "$agentq_home/agentq-server"

    # Absolute paths, not the asset's '~/.agentq/...'.  run_pueue runs pueue
    # under `env -i HOME="$HOME"`, so a '~' here would expand to the REAL home
    # and point pueued at the real data directory.
    cat >"$config" <<YML
shared:
  pueue_directory: '$agentq_home/data'
  runtime_directory: '$agentq_home/runtime'
  use_unix_socket: true
  unix_socket_permissions: 448
  pid_path: '$agentq_home/runtime/pueued.pid'
client:
  read_local_logs: true
  show_confirmation_questions: false
  edit_mode: 'toml'
daemon:
  pause_group_on_failure: false
  pause_all_on_failure: false
  compress_state_file: true
  shell_command:
    - '/bin/bash'
    - '-lc'
    - '{{ pueue_command_string }}'
YML

    # The layout the server insists on before it will do anything.
    mkdir -p "$agentq_home/data/agentq-cancellations" \
        "$agentq_home/data/agentq-requests/.locks" \
        "$agentq_home/data/agentq-requests/.tombstones"
    chmod 700 "$agentq_home/data/agentq-cancellations" \
        "$agentq_home/data/agentq-requests/.locks" \
        "$agentq_home/data/agentq-requests/.tombstones"

    printf 'starting pueued\n'
    (
        cd "$agentq_home"
        nohup ./pueued --config "$config" >"$sandbox_root/pueued.log" 2>&1 &
    )

    # Wait for it to actually answer.  Starting the daemon is not optional:
    # the server's ensure_daemon falls back to `launchctl kickstart
    # gui/<uid>/com.agentq.pueued` on macOS, which is a service change against
    # the real launchd domain.
    local waited=0
    while [ "$waited" -lt 20 ]; do
        if daemon_responds; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if ! daemon_responds; then
        printf 'sandbox: pueued did not come up; log follows\n' >&2
        cat "$sandbox_root/pueued.log" >&2 || true
        cmd_down >/dev/null 2>&1 || true
        exit 1
    fi

    up_complete=true
    printf '\nsandbox ready (%s).\n\n  AGENTQ_SMOKE_HOME=%s ./run-tests.sh\n\n' \
        "$(daemon_pid)" "$agentq_home"
    printf 'tear it down with: ./sandbox.sh down\n'
}

cmd_down() {
    local pid pids
    # Ownership is decided FIRST, before anything is killed or deleted.  The
    # marker is the only proof this tree is ours, and a tree we refuse to delete
    # is a tree we must not modify either: the pid-file removal below used to run
    # BEFORE this check, so `down` on a foreign/unmarked tree printed "refusing to
    # delete it", exited 1, and had already deleted a file inside it.  Measured
    # 2026-11-02: a foreign tree holding runtime/pueued.pid came back missing that
    # file -- and a pueued whose pid file vanishes is exactly the orphan this
    # round exists to prevent, so the refusal was manufacturing the failure mode.
    #
    # A tree that does not exist is NOT a refusal case: the daemon can outlive its
    # tree, and that orphan is ours to reap (there is nothing else to protect).
    if [ -e "$sandbox_root" ] && [ ! -f "$marker" ]; then
        printf 'sandbox: %s has no marker file; refusing to delete it\n' "$sandbox_root" >&2
        return 1
    fi
    # Reap EVERY matching daemon, not just one: a second sandbox started after
    # the first lost its pid file leaves two pueueds on one config, and hunting
    # down the extra one by hand is what the pid-file-only form forced.
    # If the process table cannot be read we do not know whether a daemon is
    # running, and everything below kills processes and deletes the tree.
    # A bare `pids=$(...)` here once let `set -e` kill the script on that
    # failure: exit 1, zero bytes printed, tree kept, daemon alive -- silence
    # that `up`'s `|| true` then converted into an orphan.  A refusal must have
    # a voice, so the failure is caught and reported, and NOTHING below runs.
    pids=$(sandbox_daemon_pids) || return 1
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
    done
    [ -n "$pids" ] && printf 'stopped pueued (%s)\n' "$(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ $//')"
    # The pid file is written by pueued; drop it too so a later `up` does not
    # read a stale number and mistake it for a live daemon.
    rm -f -- "$agentq_home/runtime/pueued.pid" 2>/dev/null || true
    # Only remove a tree this script created.  Ownership was already established
    # above, so this is the removal itself, not a second decision point.
    if [ -e "$sandbox_root" ]; then
        rm -rf -- "$sandbox_root"
        printf 'removed %s\n' "$sandbox_root"
    fi
    printf 'cache kept at %s (delete it to force a re-download)\n' "$cache"
}

cmd_status() {
    local pid rc=0
    pid=$(daemon_pid) || rc=$?
    case $rc in
    0) printf 'pueued:  running (pid %s)\n' "$pid" ;;
    1) printf 'pueued:  not running\n' ;;
    *) printf 'pueued:  unknown (this host'\''s ps cannot be read; NOT a verified "not running")\n' ;;
    esac
    if daemon_responds; then
        printf 'queue:   responding\n'
        printf 'env:     AGENTQ_SMOKE_HOME=%s ./run-tests.sh\n' "$agentq_home"
    else
        printf 'queue:   not responding\n'
    fi
    [ -d "$sandbox_root" ] && printf 'root:    %s\n' "$sandbox_root" || printf 'root:    absent\n'
    [ -d "$cache" ] && printf 'cache:   %s\n' "$cache" || true
}

case "${1:-}" in
up) cmd_up ;;
down) cmd_down ;;
status) cmd_status ;;
*)
    printf 'usage: %s {up|down|status}\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
