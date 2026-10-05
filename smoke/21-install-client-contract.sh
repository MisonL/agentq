#!/usr/bin/env bash
# Smoke: assets/client/unix/install-client.sh -- its local contract.
#
# Why this check exists: it is the LAST installer in the repo with no behavioural
# coverage at all.  The other two already have contract checks -- install-agentq.sh
# has smoke/11, install-agentq.ps1 has smoke/13 -- and this one, 251 lines, had
# only 01's `sh -n`.  It sits in the "no check has ever executed it" table in
# CLAUDE.md, and unlike the two Windows-only assets left there it is fully
# runnable on this machine, so leaving it uncovered was a choice, not a limit.
#
# Shape, borrowed from 11/13: assert the CONTRACT.  Unlike install-agentq.sh
# (env-var driven, no argv), this installer DOES parse argv, so the reachable
# surface is the option parser plus the path-safety and drift checks -- and,
# uniquely among the three, a real SUCCESS path that is safe to run here because
# it only copies two files into a sandbox directory.  That success path is
# covered: it is the only installer in the repo whose happy path is testable
# without a network, a service manager, or a package manager.
#
# WHAT THIS DOES NOT COVER: the destructive move semantics on a live destination
# (crash between the temp file and the rename), and anything about the clients it
# installs beyond their bytes matching the canonical assets.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source_directory="$root/skill/assets/client/unix"
installer="$source_directory/install-client.sh"
[ -f "$installer" ] || { printf '%s\n' 'install-client-contract: missing installer asset' >&2; exit 1; }

# The installer rejects any path containing a symlink component
# (assert_no_symlink_path_chain walks every component and rejects a link).  On
# macOS /tmp IS a symlink to /private/tmp, so a plain `mktemp -d` under /tmp is
# rejected with "destination directory contains a symbolic link" before any case
# runs.  `pwd -P` resolves it.  Same idiom as smoke/05, smoke/11, smoke/19.
work=$(mktemp -d /tmp/agentq-smoke-installclient.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
cleanup_sandbox() { rm -rf -- "$work"; }
trap cleanup_sandbox EXIT HUP INT TERM

# A sandbox HOME so a run that forgets --bin-dir cannot touch the real ~/.local/bin.
# The installer defaults the destination to "$HOME/.local/bin", so this matters.
export HOME="$work/home"
mkdir -p "$HOME"

failures=0
cases=0

# run_installer <args...> -- runs the installer, capturing status/stdout/stderr.
# The destination is ALWAYS explicit so no case can fall back to $HOME/.local/bin.
run_installer() {
    local status=0
    "$installer" "$@" >"$work/out" 2>"$work/err" || status=$?
    printf '%s' "$status"
}

# expect_rejected <label> <expected-stderr-fragment> [args...]
expect_rejected() {
    local label=$1 expected=$2
    shift 2
    cases=$((cases + 1))
    local status
    status=$(run_installer "$@")
    if [ "$status" -eq 0 ]; then
        printf 'install-client %s: expected a non-zero exit, got 0\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'install-client %s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

# --- the option contract ------------------------------------------------------
# Every message below was MEASURED off the installer, not guessed -- the first
# version of smoke/13 asserted wording that did not exist, and that is the trap.
expect_rejected 'unknown option'          'unknown option: --bogus' --bogus
expect_rejected 'bin-dir missing value'   '--bin-dir requires a directory' --bin-dir
# --bin-dir with an empty value: the empty string reaches the destination check.
expect_rejected 'empty bin-dir'           'destination directory cannot be empty' --bin-dir ''

# --help must succeed and must NOT touch anything.  It prints usage to stdout.
cases=$((cases + 1))
help_status=$(run_installer --help)
if [ "$help_status" -ne 0 ]; then
    printf 'install-client --help: expected 0, got %s\n' "$help_status" >&2
    failures=$((failures + 1))
elif ! grep -qF 'Usage: install-client.sh' "$work/out"; then
    printf 'install-client --help: usage text not on stdout\n' >&2
    failures=$((failures + 1))
fi
# -h is an alias for --help.
cases=$((cases + 1))
if [ "$(run_installer -h)" -ne 0 ]; then
    printf 'install-client -h: expected 0\n' >&2
    failures=$((failures + 1))
fi

# --- path safety --------------------------------------------------------------
# A destination whose path chain contains a symlink must be refused, and refused
# BEFORE anything is created.  This is the property that keeps the installer from
# following a link an attacker planted in the destination chain.
link_parent="$work/link-parent"
real_parent="$work/real-parent"
mkdir -p "$real_parent"
ln -s "$real_parent" "$link_parent"
expect_rejected 'symlinked destination' 'symbolic link' --bin-dir "$link_parent/child"

# A destination that is a regular FILE, not a directory, must be refused.  The
# message is the mkdir failure, not a "not a directory" phrasing -- measured, not
# guessed (the first draft asserted wording that does not exist).
file_destination="$work/not-a-directory"
printf 'x' > "$file_destination"
expect_rejected 'destination is a file' 'cannot create destination directory' --bin-dir "$file_destination"

# --- --check: the read-only drift check ---------------------------------------
# --check against an empty directory: both clients are "missing", exit 1, and
# nothing is written.  The empty destination must still be empty afterwards.
empty_destination="$work/empty-dest"
mkdir -p "$empty_destination"
cases=$((cases + 1))
check_status=$(run_installer --check --bin-dir "$empty_destination")
if [ "$check_status" -ne 1 ]; then
    printf 'install-client --check (empty): expected 1, got %s\n' "$check_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'client is missing from destination: agentq' "$work/err" \
   || ! grep -qF 'client is missing from destination: sshp' "$work/err"; then
    printf 'install-client --check (empty): did not report both clients missing\n' >&2
    failures=$((failures + 1))
fi
if [ -n "$(find "$empty_destination" -mindepth 1 -print -quit)" ]; then
    printf 'install-client --check (empty): --check wrote to the destination\n' >&2
    failures=$((failures + 1))
fi

# --- the success path ---------------------------------------------------------
# The ONLY installer happy path testable here: it copies two files into a sandbox
# directory, no network, no service manager.  Covered on purpose -- a contract
# check that only ever proves rejection cannot tell a working installer from one
# that always fails.
install_destination="$work/installed"
cases=$((cases + 1))
install_status=$(run_installer --bin-dir "$install_destination")
if [ "$install_status" -ne 0 ]; then
    printf 'install-client (install): expected 0, got %s\n' "$install_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
else
    # Both clients installed, byte-identical to the canonical assets.
    for client in agentq sshp; do
        if ! cmp -s "$source_directory/$client" "$install_destination/$client"; then
            printf 'install-client (install): %s is not byte-identical to the asset\n' "$client" >&2
            failures=$((failures + 1))
        fi
    done
    # Mode 700: the installer does `chmod 700` on each staged file.  Asserted
    # because that is the step whose Windows counterpart was a silent no-op
    # (CLAUDE.md: chmod on noacl mounts); on POSIX it must actually take.
    for client in agentq sshp; do
        mode=$(stat -f '%Lp' "$install_destination/$client" 2>/dev/null || stat -c '%a' "$install_destination/$client")
        if [ "$mode" != "700" ]; then
            printf 'install-client (install): %s mode is %s, expected 700\n' "$client" "$mode" >&2
            failures=$((failures + 1))
        fi
    done
    # No staging residue: the `.agentq.new.XXXXXX` temp files must all be gone.
    residue=$(find "$install_destination" -name '.agentq.new.*' -o -name '.sshp.new.*' | wc -l | tr -d ' ')
    if [ "$residue" -ne 0 ]; then
        printf 'install-client (install): %s staging temp file(s) left behind\n' "$residue" >&2
        failures=$((failures + 1))
    fi
fi

# --check against the freshly installed directory: must now match, exit 0.
cases=$((cases + 1))
recheck_status=$(run_installer --check --bin-dir "$install_destination")
if [ "$recheck_status" -ne 0 ]; then
    printf 'install-client --check (installed): expected 0, got %s\n' "$recheck_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'match canonical assets' "$work/out"; then
    printf 'install-client --check (installed): did not report a match\n' >&2
    failures=$((failures + 1))
fi

# --- --check must DETECT drift, not just accept what is there -----------------
# Overwrite one installed client with different bytes: --check must report the
# mismatch and exit 1.  Without this case, a --check that always returned 0 would
# pass every assertion above.
drift_destination="$work/drift"
mkdir -p "$drift_destination"
cp "$source_directory/agentq" "$drift_destination/agentq"
cp "$source_directory/sshp" "$drift_destination/sshp"
printf '\n# drift\n' >> "$drift_destination/sshp"
cases=$((cases + 1))
drift_status=$(run_installer --check --bin-dir "$drift_destination")
if [ "$drift_status" -ne 1 ]; then
    printf 'install-client --check (drift): expected 1, got %s\n' "$drift_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'client does not match canonical asset: sshp' "$work/err"; then
    printf 'install-client --check (drift): did not name the drifted client\n' >&2
    failures=$((failures + 1))
fi
# ...and the un-drifted client must NOT be reported as drifting.  A --check that
# reported every client as drifted would pass the assertion above.
if grep -qF 'client does not match canonical asset: agentq' "$work/err"; then
    printf 'install-client --check (drift): reported the un-drifted client as well\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'install-client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'install-client-contract checks passed: cases=%s install=covered check=covered drift=detected\n' "$cases"
