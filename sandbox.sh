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

# The pueued we started, located by the pid file the config names -- NOT by
# `pgrep -f <pattern>`, which does not match a sandboxed pueued on this host
# (measured), so it reports "not running" while the daemon is up.
daemon_pid() {
    local pid_file="$agentq_home/runtime/pueued.pid"
    [ -f "$pid_file" ] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || return 1
    case $pid in
    '' | *[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
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
        printf 'sandbox already running.\n\n  AGENTQ_SMOKE_HOME=%s ./run-tests.sh\n\n' "$agentq_home"
        return 0
    fi
    if [ -e "$sandbox_root" ]; then
        printf 'sandbox: removing a stale sandbox at %s\n' "$sandbox_root" >&2
        cmd_down >/dev/null 2>&1 || true
    fi

    installer_hashes
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
    local pid
    if pid=$(daemon_pid); then
        kill "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
        printf 'stopped pueued (%s)\n' "$pid"
    fi
    # Only remove a tree this script created.  The marker keeps `down` from
    # deleting anything that happens to sit at the configured path.
    if [ -e "$sandbox_root" ]; then
        if [ -f "$marker" ]; then
            rm -rf -- "$sandbox_root"
            printf 'removed %s\n' "$sandbox_root"
        else
            printf 'sandbox: %s has no marker file; refusing to delete it\n' "$sandbox_root" >&2
            return 1
        fi
    fi
    printf 'cache kept at %s (delete it to force a re-download)\n' "$cache"
}

cmd_status() {
    if pid=$(daemon_pid); then
        printf 'pueued:  running (pid %s)\n' "$pid"
    else
        printf 'pueued:  not running\n'
    fi
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
