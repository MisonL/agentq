#!/usr/bin/env bash
# Smoke: the unix installer's FAILURE contract.  Nothing is installed -- every
# case here must be rejected before the installer writes anything, so the whole
# check runs against a sandbox HOME and a stub PATH.
#
# Why this check exists: assets/unix/install-agentq.sh is 2,876 lines -- the
# largest asset in the repo with no behavioural coverage at all.  Before this
# file, the only thing that had ever looked at it was 01's `bash -n`.  It is the
# single biggest hole in the suite, and this session's seven defects were six
# installer defects, which is what that hole predicts.
#
# Shape, borrowed from 05-client-contract: assert the CONTRACT, not the success
# path.  The installer is driven entirely by environment variables and parses no
# argv at all (verified by function-stack analysis, not grep: the only `$1`
# occurrences sit inside sha256_file), so the reachable failure surface is a
# clean list of rejected inputs.
#
# NOT covered, and this is the honest limit:
#   - the success path.  It downloads pueue/pueued from GitHub, writes
#     ~/.agentq, and registers a launchd or systemd service.  Covering it needs
#     a real install, which is out of scope without explicit authorization.
#   - anything past `prepare_service_stage` (launchctl/systemctl behaviour).
#     Reaching it requires a successful binary stage and a service to register.
#   - Windows.  install-agentq.ps1 is a different 2,922-line asset with a
#     different failure surface; it is not touched here.
#   - the hash-mismatch case below proves the installer REJECTS a bad binary; it
#     does not prove it accepts a good one.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
real_assets="$root/skill/assets/unix"
# AGENTQ_SMOKE_INSTALLER points this check at a mutated copy of the installer;
# same convention as smoke/05, smoke/07 and smoke/13.
installer_source="${AGENTQ_SMOKE_INSTALLER:-$real_assets/install-agentq.sh}"

# The installer refuses any path containing a symlink component
# (installer_path_is_safe walks every component and rejects a link).  On macOS
# /tmp IS a symlink to /private/tmp, so a plain `mktemp -d` under /tmp would be
# rejected with "AgentQ transaction parent is unsafe" before any case ran.
# `pwd -P` resolves it, which also keeps this working on Linux where /tmp is a
# real directory.  Same idiom as smoke/05.
#
# /tmp rather than $TMPDIR on purpose: macOS puts TMPDIR under /var/folders,
# and the repo's convention is to keep sandbox paths short.  This check starts
# no unix socket so it is not bound by SUN_LEN, but matching the convention
# keeps one rule instead of two.
work=$(mktemp -d /tmp/agentq-smoke-installer.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
# The TOCTOU case below parks a `sleep` in the background as a stand-in for a
# lock holder.  It is killed explicitly, but a mid-file failure would exit past
# that, and a leaked 300s sleeper would hang the whole suite rather than fail it.
# The variable is expanded at trap time, so the trap stays correct once it is set.
background_pids=''
cleanup_sandbox() {
    local pid
    for pid in $background_pids; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf -- "$work"
}
# EXIT alone is not enough: a check killed by the harness (or by Ctrl-C) would
# never run an EXIT-only trap and would leak the sleeper into the next run.
trap cleanup_sandbox EXIT HUP INT TERM

home="$work/home"
stub_bare="$work/bin-bare"
stub_pkgmgr="$work/bin-pkgmgr"
stub_full="$work/bin-full"
assets="$work/assets"
source_dir="$work/src"
mkdir -p "$home" "$stub_bare" "$stub_pkgmgr" "$stub_full" "$assets" "$source_dir"

# Three stub PATHs, differing in exactly two things: whether jq resolves, and
# whether a package manager resolves.  All three symlink the host's real
# commands so the installer's preamble works; none of them can reach a real
# install.
#
# Why three and not one: the first version put recording stubs for the package
# managers into the jq-less PATH, which made `command -v brew` SUCCEED -- so the
# "no supported package manager" branch became unreachable and that case failed
# on the wrong message.  A stub that exists is not an absent stub.
#
#   bare    no jq, no package manager  -> "missing dependency jq and no
#                                          supported package manager"
#   pkgmgr  no jq, failing recording   -> the installer TRIES to install, the
#           package managers              stub fails, and it must still refuse
#   full    jq, failing recording      -> for the cases that must get past
#           package managers, and a       dependency resolution AND the sudo
#           succeeding sudo stub          prompt
#
# This machine really has jq and really has brew, so a sandbox HOME is not
# enough on its own: `brew install` would mutate the real machine.  Removing
# every package manager from PATH and replacing it with a stub that logs and
# fails is what makes "nothing was installed" an assertion rather than a hope.
#
# sudo is stubbed to succeed in `full` only.  Measured reason: on macOS the
# installer calls authorize_macos_root (which runs `sudo -v`) BEFORE it checks
# the wrapper destination or stages any binary, so without a stub those cases
# never reach the assertion under test -- they die on the sudo prompt instead.
#
# The stub EXECUTES its arguments rather than returning 0.  This matters and is
# not a detail: remove_installer_file (install-agentq.sh, the file under test)
# branches on
# `platform_kind = macos` and removes files through `run_as_root rm -f`, so a
# stub that reports success without deleting leaves the maintenance lock behind
# and the installer correctly reports "maintenance lock metadata remained after
# cleanup" -- which looked like a product defect for one debugging round and was
# this fixture's own doing.  A stub that lies about doing the work is not a
# stand-in for doing the work.  The case still cannot mutate anything real: it
# only ever runs against the sandbox HOME.
build_stub_path() {
    local destination=$1 allow_jq=$2
    local directory entry name
    for directory in /usr/bin /bin /usr/sbin /sbin; do
        [ -d "$directory" ] || continue
        for entry in "$directory"/*; do
            name=${entry##*/}
            case "$name" in
                uname) continue ;;                        # stubbed below
                jq) [ "$allow_jq" = yes ] || continue ;;
                # Never reachable, in any of the three PATHs.
                brew|port|apt|apt-get|apt-cache|dnf|yum|pacman|zypper|apk|sudo|doas) continue ;;
            esac
            [ -x "$entry" ] || continue
            [ -e "$destination/$name" ] && continue
            ln -s "$entry" "$destination/$name"
        done
    done
}

build_stub_path "$stub_bare" no
build_stub_path "$stub_pkgmgr" no
build_stub_path "$stub_full" yes

# The installer's Darwin branch runs `require_command launchctl plutil chown`
# before it reaches ANY of the refusal cases below, and this fixture pins the
# platform to Darwin on every host -- the messages under test are the macOS ones
# (measured: the Linux CI job reported eleven cases dying on
# `required command is missing: launchctl`, none of them on its own assertion).
# build_stub_path symlinks whatever the host provides, so a macOS host supplies
# the real commands and is unchanged; a Linux host provides neither launchctl nor
# plutil (chown it has), and every Darwin-platform case stopped at the preamble.
# A stub is created only where the host has nothing to link.
for stub in "$stub_bare" "$stub_pkgmgr" "$stub_full"; do
    if [ ! -e "$stub/launchctl" ]; then
        cat > "$stub/launchctl" <<'STUB'
#!/bin/sh
# This host has no launchd.  The reachable installer code only ASKS whether
# com.agentq.pueued is loaded (bootstrap_existing_macos_service's `print`), and
# on a machine with no AgentQ the answer is "no such service" -- which is exit
# nonzero.  Anything else is a state change this fixture does not model, so it
# refuses loudly instead of pretending it worked.
case "${1:-}" in
    print) exit 3 ;;
    *) printf 'launchctl stub: this fixture does not model %s; failing rather than pretending it succeeded\n' "${1:-}" >&2; exit 1 ;;
esac
STUB
        chmod 700 "$stub/launchctl"
    fi
    if [ ! -e "$stub/plutil" ]; then
        cat > "$stub/plutil" <<'STUB'
#!/bin/sh
# Reached only by prepare_service_stage, which sits behind a successful
# download+verify of pueue/pueued -- out of scope for this offline fixture, so
# no case runs this.  It exists for the preamble's `require_command plutil`, and
# it refuses rather than reporting a lint it cannot perform: a stub that said
# "valid" would make a broken plist look checked.
printf '%s\n' 'plutil stub: this fixture host has no plutil; -lint is not modelled' >&2
exit 1
STUB
        chmod 700 "$stub/plutil"
    fi
done

# Recording stubs for every package manager the installer knows about, installed
# only into the two PATHs that are meant to have them.
package_log="$work/package-manager-invocations"
: >"$package_log"
for destination in "$stub_pkgmgr" "$stub_full"; do
    for manager in brew port apt-get dnf yum pacman zypper apk; do
        cat > "$destination/$manager" <<STUB
#!/bin/sh
printf '%s\n' "$manager \$*" >> "$package_log"
exit 1
STUB
        chmod 700 "$destination/$manager"
    done
done

cat > "$stub_full/sudo" <<'STUB'
#!/bin/sh
# Runs the command it was given, with no privilege change.  See the note above
# build_stub_path: the installer deletes files through `run_as_root rm -f` on
# macOS, so a stub that merely returned 0 would leave state behind and make a
# correct installer look broken.  Anything outside the sandbox HOME is refused.
#
# `sudo -v` is authorize_macos_root's credential check and runs nothing, so it
# is answered directly -- otherwise the stub would try to exec `-v`.
case "${1:-}" in
    -v|--validate|--non-interactive) exit 0 ;;
esac
# The first argument is the command name itself (e.g. `rm`); only the operands
# are checked against the sandbox.  The command is saved before the loop so the
# final exec still has it.
command_name=$1
shift
for argument in "$@"; do
    case "$argument" in
        *agentq-smoke-installer.*) ;;
        -*) ;;
        *) printf 'sudo stub: refusing to touch %s\n' "$argument" >&2; exit 1 ;;
    esac
done
exec "$command_name" "$@"
STUB
chmod 700 "$stub_full/sudo"

# uname is stubbed because the installer's platform table is keyed on it, and
# the table decides which asset names and hashes it expects.  The stub reads a
# file so a case can flip the platform to exercise the unsupported branch.
platform_file="$work/platform"
printf 'Darwin\narm64\n' >"$platform_file"
for stub in "$stub_bare" "$stub_pkgmgr" "$stub_full"; do
    cat > "$stub/uname" <<STUB
#!/bin/sh
case "\$1" in
    -s) sed -n 1p "$platform_file" ;;
    -m) sed -n 2p "$platform_file" ;;
    *)  sed -n 1p "$platform_file" ;;
esac
STUB
    chmod 700 "$stub/uname"
done

# The installer requires agentq-server, pueue.yml and agentq to sit next to it,
# plus the platform's service assets -- on macOS the two plists, on Linux the
# unit file.  All of them are copied so a case can remove one without touching
# the repo.  Missing any of the others would make every case fail identically on
# the wrong assertion, which is exactly how a broken fixture hides.
cp "$installer_source" "$assets/install-agentq.sh"
cp "$real_assets/agentq-server" "$assets/agentq-server"
cp "$real_assets/pueue.yml" "$assets/pueue.yml"
cp "$real_assets/agentq" "$assets/agentq"
cp "$real_assets/com.agentq.pueued.plist" "$assets/com.agentq.pueued.plist"
cp "$real_assets/com.agentq.pueued.daemon.plist" "$assets/com.agentq.pueued.daemon.plist"
cp "$real_assets/agentq-pueued.service" "$assets/agentq-pueued.service"
chmod 700 "$assets/install-agentq.sh"

# The fixture is only trustworthy if the installer gets past its preamble with
# it.  Prove that once, up front, by asserting the run fails on something LATE
# (dependency resolution) rather than on a missing asset.  If a future asset is
# added to the required list and not copied here, this catches it immediately
# instead of letting every case below report the same wrong message.
status=0
env HOME="$home" PATH="$stub_bare" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
if ! grep -qF 'missing dependency jq' "$work/err"; then
    printf '%s\n' 'fixture self-check: the installer did not reach dependency resolution;' >&2
    printf '%s\n' 'the sandbox asset directory is incomplete and every case below would' >&2
    printf '%s\n' 'fail on the wrong assertion.' >&2
    sed 's/^/      /' "$work/err" >&2 || true
    exit 1
fi

failures=0
cases=0

# Every case funnels through here so the exit-code and message assertions cannot
# drift apart from each other.
check_case() {
    local label=$1 expected=$2 status=$3
    cases=$((cases + 1))
    if [ "$status" -ne 2 ]; then
        printf 'installer %s: expected exit 2, got %s\n' "$label" "$status" >&2
        sed 's/^/      /' "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'installer %s: stderr does not contain %s\n' "$label" "$expected" >&2
        sed 's/^/      /' "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

# A rejected install must leave the user's home exactly as it found it.  This is
# the property that makes the whole file safe to run: the installer stages into
# a mktemp-named directory under $HOME and takes a maintenance lock, so a
# rejection that forgot to clean either would show up here.
home_listing() {
    find "$home" -mindepth 1 2>/dev/null | LC_ALL=C sort
}
assert_home_clean() {
    local label=$1
    local leftover
    leftover=$(home_listing)
    if [ -n "$leftover" ]; then
        printf 'installer %s: left artifacts in HOME:\n' "$label" >&2
        printf '%s\n' "$leftover" | sed 's/^/      /' >&2
        failures=$((failures + 1))
    fi
}

assert_no_package_manager() {
    local label=$1
    if [ -s "$package_log" ]; then
        printf 'installer %s: invoked a package manager:\n' "$label" >&2
        sed 's/^/      /' "$package_log" >&2
        failures=$((failures + 1))
    fi
}

# A PATH identical to stub_full except that curl is replaced by a stub writing a
# known-bad body.  The download-and-verify branch is otherwise unreachable
# offline, and it is a real branch: a mutation that deletes its sha256 check
# passed this file before this PATH existed.  Keeping it separate from
# stub_full means the other cases keep exercising the real curl.
stub_download="$work/bin-download"
mkdir -p "$stub_download"
for entry in "$stub_full"/*; do
    name=${entry##*/}
    [ "$name" = curl ] || ln -s "$entry" "$stub_download/$name"
done
cat > "$stub_download/curl" <<'STUB'
#!/bin/sh
# Writes a body whose hash cannot match the pinned one, then succeeds -- i.e. a
# download that completed but delivered the wrong bytes.  That is the only way
# to reach the mismatch branch without a network.
out=''
while [ $# -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] && printf 'this is not the pueue binary\n' >"$out"
exit 0
STUB
chmod 700 "$stub_download/curl"

# A PATH whose `ps` answers the identity question exactly once and then goes
# quiet.  That models the TOCTOU window recover_stale_maintenance_lock exists to
# close: the holder is confirmed dead, and by the time the lock is about to be
# removed the identity can no longer be re-confirmed.  The installer must fail
# rather than remove a lock it can no longer vouch for.  Without this shim the
# branch is unreachable in a single-process fixture, and a mutation deleting the
# re-confirmation passed this file.
#
# Note the shim delegates to the real ps on the FIRST identity query and returns
# nothing afterwards: `maintenance_lock_is_stale` is the first caller, the
# re-check inside recover_stale_maintenance_lock is the second.
stub_identity_gone="$work/bin-identity-gone"
mkdir -p "$stub_identity_gone"
for entry in "$stub_full"/*; do
    name=${entry##*/}
    [ "$name" = ps ] || ln -s "$entry" "$stub_identity_gone/$name"
done
ps_query_counter="$work/ps-identity-queries"
cat > "$stub_identity_gone/ps" <<STUB
#!/bin/sh
for ps_argument in "\$@"; do
    case "\$ps_argument" in
        -o)
            ;;
        lstart=)
            query_count=0
            [ -f "$ps_query_counter" ] && query_count=\$(cat "$ps_query_counter")
            query_count=\$((query_count + 1))
            printf '%s' "\$query_count" >"$ps_query_counter"
            if [ "\$query_count" -eq 1 ]; then
                exec /bin/ps "\$@"
            fi
            exit 0
            ;;
    esac
done
exec /bin/ps "\$@"
STUB
chmod 700 "$stub_identity_gone/ps"

# A PATH that records every mkdir operand together with the pid of the shell
# that invoked it -- that pid IS the installer's $$ -- and then does the real
# work.  The staging root is the one temporary whose creation the fixture can
# reach (the transaction fails later, on the pinned hash), so it is the one
# place the "is this name derivable from the pid" property can be OBSERVED
# rather than grepped.
stub_record_mkdir="$work/bin-record-mkdir"
mkdir -p "$stub_record_mkdir"
for entry in "$stub_full"/*; do
    name=${entry##*/}
    [ "$name" = mkdir ] || ln -s "$entry" "$stub_record_mkdir/$name"
done
real_mkdir=$(readlink "$stub_full/mkdir")
mkdir_log="$work/mkdir-invocations"
: >"$mkdir_log"
cat > "$stub_record_mkdir/mkdir" <<STUB
#!/bin/sh
for mkdir_argument in "\$@"; do
    printf '%s\t%s\n' "\$PPID" "\$mkdir_argument" >> "$mkdir_log"
done
exec "$real_mkdir" "\$@"
STUB
chmod 700 "$stub_record_mkdir/mkdir"

status=0

# --- pre-lock argument and platform validation -------------------------------
# These are rejected before the maintenance lock is taken, so they cannot leave
# anything behind even in principle.

# AGENTQ_HOME is not merely unvalidated -- it is refused outright, because the
# bundled pueue.yml is rooted at ~/.agentq.  That refusal is the reason this
# whole check can run against a sandbox HOME at all.
status=0
env HOME="$home" PATH="$stub_bare" AGENTQ_HOME="$home/elsewhere" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'AGENTQ_HOME override' \
    'AGENTQ_HOME overrides are unsupported' "$status"
assert_home_clean 'AGENTQ_HOME override'

status=0
env HOME="$home" PATH="$stub_bare" AGENTQ_PUEUE_SOURCE_DIR="$work/absent" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'source dir not a directory' \
    'AGENTQ_PUEUE_SOURCE_DIR is not a directory' "$status"
assert_home_clean 'source dir not a directory'

# A source directory reached through a symlink is refused by the same component
# walk that guards every other path the installer touches -- but LATE: measured,
# this fires inside stage_verified_binary, after the maintenance lock is taken
# and after authorize_macos_root.  So it needs the sudo stub, and the home must
# come back clean, which also proves the lock was released on the way out.
ln -s "$source_dir" "$work/src-link"
status=0
env HOME="$home" PATH="$stub_full" AGENTQ_PUEUE_SOURCE_DIR="$work/src-link" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'source dir via symlink' \
    'source directory is unsafe' "$status"
assert_home_clean 'source dir via symlink'

printf 'FreeBSD\namd64\n' >"$platform_file"
status=0
env HOME="$home" PATH="$stub_bare" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'unsupported platform' 'unsupported platform' "$status"
assert_home_clean 'unsupported platform'
printf 'Darwin\narm64\n' >"$platform_file"

# --- dependency resolution ---------------------------------------------------
# jq is absent from the stub PATH and every package manager is a recording stub
# that fails.  The installer must refuse rather than proceed without jq.
status=0
env HOME="$home" PATH="$stub_bare" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'missing jq, no package manager' \
    'missing dependency jq and no supported package manager is available' "$status"
assert_home_clean 'missing jq, no package manager'
assert_no_package_manager 'missing jq, no package manager'

# --- staged asset validation -------------------------------------------------
# One required asset missing at a time.  The installer names the asset it
# wanted, which is what makes the failure attributable rather than a bare exit 2.
for missing in agentq-server pueue.yml agentq; do
    mv "$assets/$missing" "$assets/$missing.saved"
    status=0
    env HOME="$home" PATH="$stub_full" \
        /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
    check_case "missing asset $missing" \
        "required staged asset is missing: $assets/$missing" "$status"
    assert_home_clean "missing asset $missing"
    mv "$assets/$missing.saved" "$assets/$missing"
done

# --- existing state that must not be clobbered -------------------------------
# An unrelated file at the wrapper destination, with no AgentQ installation to
# justify replacing it.  The installer must refuse AND leave the file alone --
# overwriting it would be destroying something the installer never created.
mkdir -p "$home/.local/bin"
printf 'do not touch\n' >"$home/.local/bin/agentq"
wrapper_before=$(shasum -a 256 <"$home/.local/bin/agentq")
status=0
env HOME="$home" PATH="$stub_full" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'unowned wrapper destination' \
    'refuse to overwrite an existing wrapper without an AgentQ installation' "$status"
wrapper_after=$(shasum -a 256 <"$home/.local/bin/agentq")
if [ "$wrapper_before" != "$wrapper_after" ]; then
    printf '%s\n' 'installer unowned wrapper destination: modified the file it refused to overwrite' >&2
    failures=$((failures + 1))
fi

# A maintenance lock held by a LIVE process is the sharpest case in this file:
# the installer must refuse to recover it.  The lock metadata is `pid<TAB>identity`
# (see read_lock_metadata / write_lock_metadata).  The identity is NOT a stat
# value -- process_identity_state builds it from `ps -o lstart= -p <pid>`, i.e.
# the process start time, and read_lock_metadata splits the file on a tab.
#
# Seeding it with a live process rather than a dead one is deliberate, and it is
# what a mutation caught: with a garbage pid the installer fails on "cannot
# confirm stale lock" whatever it decides about liveness, so DELETING the
# refusal entirely still passed the case.  That is a check asserting the wrong
# thing.  A live holder closes it -- if the installer steals the lock, the
# assertion below sees the pid file gone.
#
# The identity is resolved in a child shell and read back, because this script
# is not the process whose identity the installer will look up.
lock_holder_ready="$work/lock-holder-ready"
lock_holder_pid_file="$work/lock-holder-pid"
(
    printf '%s' "$$" >"$lock_holder_pid_file"
    while [ ! -e "$lock_holder_ready" ]; do sleep 0.2; done
) &
lock_holder_pid=$!
waited=0
while [ ! -e "$lock_holder_pid_file" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
lock_pid_value=$(cat "$lock_holder_pid_file")
lock_identity_value=$(LC_ALL=C ps -o lstart= -p "$lock_pid_value" 2>/dev/null |
    awk '{$1 = $1; print}')

# The wrapper this case removes was left by the unowned-wrapper case above; drop
# it unconditionally so a failure in the branch below cannot leak it forward.
rm -f "$home/.local/bin/agentq"
rmdir "$home/.local/bin" "$home/.local" 2>/dev/null || true

if [ -z "$lock_identity_value" ]; then
    # Without a readable identity the installer could not confirm liveness
    # either, and this case would silently degrade into the weak version the
    # mutation exposed.  Fail loudly rather than test less.
    printf '%s\n' 'installer held maintenance lock: could not resolve the holder identity;' >&2
    printf '%s\n' 'this case cannot assert what it is meant to assert on this platform.' >&2
    failures=$((failures + 1))
else
    mkdir -p "$home/.agentq.maintenance.lock"
    printf '%s\t%s\n' "$lock_pid_value" "$lock_identity_value" \
        >"$home/.agentq.maintenance.lock/pid"
    status=0
    env HOME="$home" PATH="$stub_full" \
        /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
    check_case 'held maintenance lock' 'maintenance' "$status"
    # The lock must still be there, untouched, and nothing may have joined it.
    expected_home="$home/.agentq.maintenance.lock
$home/.agentq.maintenance.lock/pid"
    observed_home=$(home_listing)
    if [ "$observed_home" != "$expected_home" ]; then
        printf '%s\n' 'installer held maintenance lock: HOME does not hold exactly the seeded lock:' >&2
        printf '%s\n' "$observed_home" | sed 's/^/      /' >&2
        failures=$((failures + 1))
    fi
    if [ ! -e "$home/.agentq.maintenance.lock/pid" ]; then
        printf '%s\n' 'installer held maintenance lock: stole a lock held by a live process' >&2
        failures=$((failures + 1))
    fi
    rm -rf "$home/.agentq.maintenance.lock"
fi

# Release the holder last, and only by its ready flag, so no "Terminated" noise
# from a signal ever reaches the check's output.
: >"$lock_holder_ready"
wait "$lock_holder_pid" 2>/dev/null || true

# --- binary hash pinning -----------------------------------------------------
# The one case that gets past the maintenance lock and into the staging
# transaction.  A source directory holding a file with the right NAME and the
# wrong CONTENT must be rejected on the pinned hash, and the failed transaction
# must clean up after itself -- which is what assert_home_clean then verifies.
#
# This proves the installer rejects a bad binary.  It does not prove it accepts
# a good one: that needs a real download.
cp "$real_assets/pueue.yml" "$source_dir/pueue.yml"
printf 'this is not the pueue binary\n' >"$source_dir/pueue-aarch64-apple-darwin"
printf 'this is not the pueued binary\n' >"$source_dir/pueued-aarch64-apple-darwin"
status=0
env HOME="$home" PATH="$stub_full" AGENTQ_PUEUE_SOURCE_DIR="$source_dir" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'binary hash mismatch' 'sha256 mismatch for staged asset' "$status"
assert_home_clean 'binary hash mismatch'

# --- the download path's own hash pinning ------------------------------------
# Distinct from the case above: that one stages from AGENTQ_PUEUE_SOURCE_DIR, so
# it never reaches download_and_verify.  This one does, and it is the only case
# that covers the check on the DOWNLOADED bytes.
status=0
env HOME="$home" PATH="$stub_download" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'downloaded binary hash mismatch' 'sha256 mismatch for' "$status"
assert_home_clean 'downloaded binary hash mismatch'
assert_no_package_manager 'downloaded binary hash mismatch'

# --- a network failure must exit 2 with the installer's attribution ----------
# curl's own exit code (7 connect, 22 HTTP, 28 timeout) used to be returned
# verbatim, so a network failure was indistinguishable from the installer's
# documented "rejected before writing" exit 2, and the message carried no
# installer prefix.  Measured 2026-10-06 with a curl stub exiting 7; no case
# before this one made curl itself fail (the stub above writes a bad body and
# exits 0).
stub_curl_fail="$work/bin-curl-fail"
mkdir -p "$stub_curl_fail"
for entry in "$stub_full"/*; do
    name=${entry##*/}
    [ "$name" = curl ] || ln -s "$entry" "$stub_curl_fail/$name"
done
cat > "$stub_curl_fail/curl" <<'STUB'
#!/bin/sh
printf 'curl: (7) Failed to connect to example.invalid port 443\n' >&2
exit 7
STUB
chmod 700 "$stub_curl_fail/curl"
status=0
env HOME="$home" PATH="$stub_curl_fail" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'download network failure' 'failed to download the AgentQ Pueue binary' "$status"
if ! grep -qF 'curl exit code 7' "$work/err"; then
    printf '%s\n' 'installer download-failure case: the message does not carry the curl exit code' >&2
    failures=$((failures + 1))
fi
assert_home_clean 'download network failure'

# --- an existing AgentQ path that is not a directory -------------------------
# A regular file where the installation root belongs.  installer_path_is_safe
# only rejects symlinks, so this reaches the is-it-a-directory check; a mutation
# deleting that check passed this file until this case existed.
printf 'not a directory\n' >"$home/.agentq"
status=0
env HOME="$home" PATH="$stub_full" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'existing AgentQ path is not a directory' \
    'existing AgentQ path is not a directory' "$status"
# The installer must not have replaced or removed the file it refused to use.
if [ ! -f "$home/.agentq" ] || [ -L "$home/.agentq" ]; then
    printf '%s\n' 'installer existing-path case: the file it refused was removed or replaced' >&2
    failures=$((failures + 1))
elif [ "$(cat "$home/.agentq" 2>/dev/null)" != 'not a directory' ]; then
    printf '%s\n' 'installer existing-path case: the file it refused was modified' >&2
    failures=$((failures + 1))
fi
rm -f "$home/.agentq"
assert_home_clean 'existing AgentQ path is not a directory'

# --- an existing installation whose daemon is DOWN ----------------------------
# The refusal must say what to DO, not only what it will not do: the W5 crash
# recovery path leads an operator here if they move the backup back but forget
# to restart the daemon, and a bare "daemon is unavailable" leaves them with no
# next step.  Platform is stubbed to Linux on purpose -- on Darwin the installer
# takes the offline-state-migration branch instead and never reaches this
# message.  The client is a stub that always fails, modelling "no daemon".
mkdir -p "$home/.agentq/config" "$home/.agentq/runtime"
cat >"$home/.agentq/pueue" <<'CLIENT'
#!/bin/sh
exit 1
CLIENT
chmod 700 "$home/.agentq/pueue"
printf 'shared:\n  pueue_directory: ~/.agentq/data\n' >"$home/.agentq/config/pueue.yml"
# On the Linux branch the installer also requires systemctl (for linger and the
# user unit) BEFORE it reaches the daemon check; a recording-failing stub would
# put it on the wrong failure, so this case gets a PATH with a systemctl that
# succeeds -- the case must die on the DAEMON message, not on a missing command.
stub_linux="$work/bin-linux"
mkdir -p "$stub_linux"
for entry in "$stub_full"/*; do
    name=${entry##*/}
    # systemctl and loginctl are replaced by stubs below; never symlink them.
    # On Linux loginctl exists on the host, so the symlink would be created and
    # the `cat >` heredoc would then write THROUGH it to /usr/bin/loginctl
    # (Permission denied) instead of creating a file in $stub_linux.
    case "$name" in
        systemctl|loginctl) continue ;;
    esac
    ln -s "$entry" "$stub_linux/$name"
done
for linux_command in systemctl loginctl; do
    cat >"$stub_linux/$linux_command" <<'LINUXCMD'
#!/bin/sh
# `loginctl show-user ... -p Linger --value` must print something the installer
# accepts; `yes` short-circuits the enable path.
case "$*" in
    *Linger*) printf 'yes\n' ;;
esac
exit 0
LINUXCMD
    chmod 700 "$stub_linux/$linux_command"
done
printf 'Linux\nx86_64\n' >"$platform_file"
status=0
env HOME="$home" PATH="$stub_linux" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
printf 'Darwin\narm64\n' >"$platform_file"
check_case 'existing daemon down' \
    'start it and re-run' "$status"
rm -rf "$home/.agentq"
assert_home_clean 'existing daemon down' 

# --- a stale maintenance lock that cannot be recovered -----------------------
# A lock whose holder is confirmed dead, but whose directory cannot be removed
# (an unexpected extra entry).  Recovery must fail loudly rather than proceed to
# install with the lock still in place.  A mutation deleting the "cannot
# recover" failure passed this file until this case existed.
mkdir -p "$home/.agentq.maintenance.lock"
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\t%s\n' "$dead_pid" 'Mon Jan  1 00:00:00 2001' \
    >"$home/.agentq.maintenance.lock/pid"
printf 'unexpected\n' >"$home/.agentq.maintenance.lock/extra"
status=0
env HOME="$home" PATH="$stub_full" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'unrecoverable stale maintenance lock' \
    'cannot recover stale AgentQ maintenance lock' "$status"
# The lock DIRECTORY must survive: an installer that reported failure but
# cleared the lock anyway would be lying about the state it left behind, and the
# next run would then believe the queue was free.  Asserting on the directory
# rather than on the pid file is deliberate -- remove_maintenance_lock deletes
# the pid file first and only then fails on rmdir, so the pid file legitimately
# disappears even on the correct path.  (An earlier version of this case
# asserted the pid file and failed against a correct installer.)
if [ ! -d "$home/.agentq.maintenance.lock" ]; then
    printf '%s\n' 'installer unrecoverable-lock case: cleared the lock it could not recover' >&2
    failures=$((failures + 1))
fi
rm -rf "$home/.agentq.maintenance.lock"
assert_home_clean 'unrecoverable stale maintenance lock'

# --- a lock whose liveness cannot be RE-confirmed ----------------------------
# The stale path re-reads the metadata and re-confirms the holder is dead before
# removing anything.  This case makes that second confirmation fail: the first
# identity query succeeds (so the lock is judged stale) and the second returns
# nothing (so recovery cannot be justified).  The installer must refuse, and the
# lock must still be there -- removing it would mean acting on a liveness
# judgement it could no longer make.
mkdir -p "$home/.agentq.maintenance.lock"
sleep 300 &
unconfirmable_pid=$!
background_pids="$background_pids $unconfirmable_pid"
printf '%s\t%s\n' "$unconfirmable_pid" 'Mon Jan  1 00:00:00 2001' \
    >"$home/.agentq.maintenance.lock/pid"
: >"$ps_query_counter"
status=0
env HOME="$home" PATH="$stub_identity_gone" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
check_case 'lock liveness cannot be re-confirmed' \
    'cannot confirm stale AgentQ maintenance lock' "$status"
if [ ! -d "$home/.agentq.maintenance.lock" ]; then
    printf '%s\n' 'installer unconfirmable-lock case: removed a lock it could not re-confirm' >&2
    failures=$((failures + 1))
fi
unlistable_count=$(cat "$ps_query_counter" 2>/dev/null || true)
if [ "${unlistable_count:-0}" -lt 2 ]; then
    # If only one identity query happened the shim never got the chance to lie,
    # and this case silently degraded into the ordinary stale-lock case.
    # `${var:-0}` so an EMPTY or missing counter file reaches `[` as `0`, not as
    # a bare `[: integer expression expected` diagnostic -- measured twice: the
    # Linux CI run (37810470283) printed `[: : integer expression expected` when
    # every case died earlier on the missing launchctl and the counter file was
    # never written; the root-in-container run printed no diagnostic at all (root
    # ignores chmod 000, the unlistable case fails differently but the counter
    # still fills).  Both forms are properties of THIS fixture's shell, not of
    # the installer, so neither should be able to reach the report.
    printf '%s\n' 'installer unconfirmable-lock case: the re-confirmation was never attempted' >&2
    failures=$((failures + 1))
fi
kill "$unconfirmable_pid" 2>/dev/null || true
wait "$unconfirmable_pid" 2>/dev/null || true
background_pids=
rm -rf "$home/.agentq.maintenance.lock"
assert_home_clean 'lock liveness cannot be re-confirmed'

# --- the launchd template's retained-placeholder guard ------------------------
# The full installer only reaches prepare_service_stage after a successful
# download+verify of pueue/pueued, which is out of scope here (no network).  So
# this case drives the EXACT block from the asset -- extracted by text between
# two anchors, the way smoke/22 extracts PowerShell functions -- with its three
# helpers stubbed.  That is what makes the guard behavioural rather than a grep:
# a future edit that drops it fails here, not just in smoke/10's static rule.
#
# The defect it pins: the POSIX installer rendered the daemon plist with three
# sed substitutions and had NO check that any of them matched.  A placeholder
# that survives ships a plist whose ProgramArguments is literally
# "__AGENTQ_HOME__/pueued" -- launchd then cannot exec the daemon.  Its Windows
# sibling already guarded both directions; this one did not.
plist_guard_dir="$work/plist-guard"
mkdir -p "$plist_guard_dir/assets"
# An unknown placeholder that no sed rule substitutes, ADDED alongside the three
# known ones so the template-side pre-check (which requires the known tokens to
# be present) passes and this direction still exercises the post-render scan.
# Structure otherwise intact, so plutil -lint would still pass -- which is
# exactly why 01 never saw it.
sed 's/__AGENTQ_HOME_PARENT__/__AGENTQ_HOME_PARENT__ __AGENTQ_UNKNOWN__/' \
    "$real_assets/com.agentq.pueued.daemon.plist" > "$plist_guard_dir/assets/com.agentq.pueued.daemon.plist"
python3 - "$installer_source" > "$plist_guard_dir/run.sh" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
start = src.index('            escaped_home=$(printf')
end = src.index('            plutil -lint', start)
block = src[start:end]
sys.stdout.write('''#!/bin/sh
set -eu
program=agentq
fail() { printf "%s: %s\\n" "$program" "$1" >&2; exit 2; }
require_installer_stage_file() { [ -f "$1" ] || fail "stage file missing: $1"; }
asset_directory="$1"; service_stage="$2"
agentq_home=/Users/smoke/.agentq
HOME=/Users/smoke
platform_kind=macos
agentq_parent=/tmp; agentq_base=agentq
macos_system_service_directory=/tmp
''')
sys.stdout.write(block)
sys.stdout.write('printf "RENDERED-OK\\n"\n')
PY
# The extractor must find the block, or this case silently tests nothing.
if ! grep -q 'retained a template placeholder' "$plist_guard_dir/run.sh"; then
    printf '%s\n' 'installer plist-placeholder case: the guard block was not extracted from the installer' >&2
    failures=$((failures + 1))
else
    cases=$((cases + 1))
    guard_status=0
    /bin/sh "$plist_guard_dir/run.sh" "$plist_guard_dir/assets" "$plist_guard_dir/staged.plist" \
        >"$work/guard.out" 2>"$work/guard.err" || guard_status=$?
    if [ "$guard_status" -ne 2 ]; then
        printf 'installer retained-placeholder: expected exit 2, got %s\n' "$guard_status" >&2
        sed 's/^/      /' "$work/guard.err" >&2 || true
        failures=$((failures + 1))
    elif ! grep -qF 'retained a template placeholder' "$work/guard.err"; then
        printf '%s\n' 'installer retained-placeholder: refused, but not for the placeholder reason' >&2
        sed 's/^/      /' "$work/guard.err" >&2 || true
        failures=$((failures + 1))
    fi
    # ...and the other direction: the REAL template must render clean, so the
    # guard is not simply rejecting everything.
    cp "$real_assets/com.agentq.pueued.daemon.plist" "$plist_guard_dir/assets/"
    cases=$((cases + 1))
    ok_status=0
    /bin/sh "$plist_guard_dir/run.sh" "$plist_guard_dir/assets" "$plist_guard_dir/staged-ok.plist" \
        >"$work/guard-ok.out" 2>"$work/guard-ok.err" || ok_status=$?
    if [ "$ok_status" -ne 0 ]; then
        printf 'installer retained-placeholder: the real template was rejected (exit %s)\n' "$ok_status" >&2
        sed 's/^/      /' "$work/guard-ok.err" >&2 || true
        failures=$((failures + 1))
    elif grep -q '__AGENTQ' "$plist_guard_dir/staged-ok.plist"; then
        printf '%s\n' 'installer retained-placeholder: the real template rendered with a leftover placeholder' >&2
        failures=$((failures + 1))
    fi
    # ...and the third direction, added with the template-side pre-check
    # (2026-10-06): a placeholder DELETED from the template used to render
    # "cleanly" into a plist with a missing key -- nothing to replace, nothing
    # left over, plutil-lint passes.  The pre-check must refuse it.
    sed 's|__AGENTQ_HOME__|/opt/agentq|' \
        "$real_assets/com.agentq.pueued.daemon.plist" > "$plist_guard_dir/assets/com.agentq.pueued.daemon.plist"
    cases=$((cases + 1))
    missing_status=0
    /bin/sh "$plist_guard_dir/run.sh" "$plist_guard_dir/assets" "$plist_guard_dir/staged-missing.plist" \
        >"$work/guard-missing.out" 2>"$work/guard-missing.err" || missing_status=$?
    if [ "$missing_status" -ne 2 ]; then
        printf 'installer missing-placeholder: expected exit 2, got %s\n' "$missing_status" >&2
        failures=$((failures + 1))
    elif ! grep -qF 'service template is missing the __AGENTQ_HOME__ placeholder' "$work/guard-missing.err"; then
        printf '%s\n' 'installer missing-placeholder: refused, but not for the missing-placeholder reason' >&2
        sed 's/^/      /' "$work/guard-missing.err" >&2 || true
        failures=$((failures + 1))
    fi
fi

# --- installer temporaries are not named after the pid -----------------------
# Every temporary the installer creates used to be "${destination}.new.$$" -- a
# pid-derived name paired with a check-then-write (require_installer_absent_path
# then a cp or a redirect).  The check closes no window, and the name is
# guessable by anything that can write to the directory.  They are mktemp names
# now, and these two cases pin that: the first OBSERVES the staging root's real
# name, the second is a source rule over every site, because only one temporary
# is reachable in this offline fixture.
#
# The observable case reuses the binary-hash-mismatch run below: that one gets
# all the way to `mkdir "$stage_home"`, so the shim above records the name the
# installer actually chose, together with the pid of the shell that ran mkdir
# -- which is the installer's own $$, since mktemp's command substitution is a
# subshell of it and `exec`/`$( )` both preserve $$.
status=0
env HOME="$home" PATH="$stub_record_mkdir" AGENTQ_PUEUE_SOURCE_DIR="$source_dir" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
# The run must reach the mkdir, or this case silently tests nothing.  It fails
# later, on the pinned hash -- the same rejection the case below asserts.
if ! grep -qF 'sha256 mismatch for staged asset' "$work/err"; then
    printf '%s\n' 'installer temp-name case: the run never reached the staging mkdir' >&2
    sed 's/^/      /' "$work/err" >&2 || true
    failures=$((failures + 1))
else
    stage_line=$(awk -F'\t' -v home="$home" '$2 ~ "^" home "/\\.[^/]*\\.stage" {print; exit}' "$mkdir_log")
    if [ -z "$stage_line" ]; then
        printf '%s\n' 'installer temp-name case: no staging root was recorded' >&2
        sed 's/^/      /' "$mkdir_log" >&2 || true
        failures=$((failures + 1))
    else
        stage_pid=${stage_line%%	*}
        stage_path=${stage_line#*	}
        # The name must not be derivable from the pid.  A suffix equal to the
        # pid is exactly the old "${prefix}.$$" shape; requiring a random tail
        # instead of merely "not equal to the pid" keeps this honest for a name
        # like "stage.1234" where 1234 happens not to be this pid.
        stage_tail=${stage_path##*.}
        if [ "$stage_tail" = "$stage_pid" ]; then
            printf 'installer temp-name case: the staging root is named after the pid: %s\n' \
                "$stage_path" >&2
            failures=$((failures + 1))
        elif [ "${#stage_tail}" -lt 6 ]; then
            printf 'installer temp-name case: the staging root suffix is too short to be random: %s\n' \
                "$stage_path" >&2
            failures=$((failures + 1))
        fi
    fi
fi
assert_home_clean 'installer temp-name case'

# The source rule, which covers the sites this fixture cannot reach: a variable
# assignment whose value interpolates $$ AND whose name looks like a path the
# installer creates.  Both halves are needed.  Matching every "$$" would flag
# the maintenance lock, where $$ is the lock OWNER recorded in the metadata --
# correct and unrelated; matching every "stage|backup|temporary" would flag the
# discard helpers, which only name a path they were handed.  The name pattern is
# the set of variables those sites actually use.
#
# This is a source assertion, and it is here because the observable case above
# can only see one of the seventeen sites -- the other sixteen need a successful
# download, a prior installation, or a rollback.  It cannot prove the sites are
# atomic; that is the behavioural half's job for the one it can reach.
pid_named_paths=$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*([[:space:]]*=[[:space:]]*[^#]*)?\$\$' "$installer_source" |
    grep -E 'stage|backup|temporary|failed_home|download|disabled' || true)
cases=$((cases + 1))
if [ -n "$pid_named_paths" ]; then
    printf '%s\n' 'installer temp-name rule: a temporary path is still derived from $$:' >&2
    printf '%s\n' "$pid_named_paths" | sed 's/^/      /' >&2
    failures=$((failures + 1))
fi

# The creating helper is the other half of the fix, and the case above cannot
# see it: a name that is not pid-derived can still be created by a
# check-then-write.  So this drives the helper itself, extracted from the asset
# by anchors the way smoke/22 extracts PowerShell functions, and asserts the
# one property the whole change rests on -- after the call the file EXISTS,
# because mktemp created it (O_EXCL) rather than merely naming it.  A mutation
# that swaps the creating form for `mktemp -u` fails here and nowhere else.
helper_dir="$work/temp-helper"
mkdir -p "$helper_dir"
python3 - "$installer_source" > "$helper_dir/run.sh" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
start = src.index('create_installer_temporary_file() {')
end = src.index('\nauthorize_macos_root() {', start)
block = src[start:end]
sys.stdout.write('''#!/bin/sh
set -eu
program=agentq
run_as_root() { "$@"; }
# The helpers guard the directory chain before calling mktemp, so the harness
# needs the real guard.  Extracted from the asset rather than reimplemented --
# a hand-written stand-in could accept what the asset rejects.
''')
guard_start = src.index('installer_path_is_safe() {')
guard_end = src.index('\ninstaller_regular_file_is_safe() {', guard_start)
sys.stdout.write(src[guard_start:guard_end])
sys.stdout.write('\n')
sys.stdout.write('''installer_directory_is_safe() {
    installer_directory_path=$1
    installer_path_is_safe "$installer_directory_path" || return 1
    [ -d "$installer_directory_path" ] && [ ! -L "$installer_directory_path" ]
}
''')
sys.stdout.write(block)
sys.stdout.write('''
directory=$1
link=$2
created=$(create_installer_temporary_file "$directory" '.agentq-probe') || exit 3
[ -e "$created" ] || { printf 'not created: %s\\n' "$created" >&2; exit 4; }
[ -f "$created" ] && [ ! -L "$created" ] || { printf 'not a regular file: %s\\n' "$created" >&2; exit 5; }
second=$(create_installer_temporary_file "$directory" '.agentq-probe') || exit 3
[ "$second" != "$created" ] || { printf 'repeated name: %s\\n' "$second" >&2; exit 6; }
reserved=$(create_installer_temporary_name "$directory" '.agentq-probe') || exit 3
[ ! -e "$reserved" ] || { printf 'name-only form created a file: %s\\n' "$reserved" >&2; exit 7; }
# The directory guard is load-bearing and would otherwise be untested: mktemp
# itself only guards the final component.  A symlinked directory must be
# refused by both forms.
ln -s "$directory" "$link" 2>/dev/null || true
if create_installer_temporary_file "$link" '.agentq-probe' >/dev/null 2>&1; then
    printf 'creating form accepted a symlinked directory\\n' >&2; exit 8
fi
if create_installer_temporary_name "$link" '.agentq-probe' >/dev/null 2>&1; then
    printf 'name-only form accepted a symlinked directory\\n' >&2; exit 9
fi
printf 'TEMP-HELPER-OK\\n'
''')
PY
# The extractor must find both helpers, or this case silently tests nothing.
if ! grep -q 'create_installer_temporary_name' "$helper_dir/run.sh"; then
    printf '%s\n' 'installer temp-helper case: the helpers were not extracted from the installer' >&2
    failures=$((failures + 1))
else
    cases=$((cases + 1))
    helper_status=0
    /bin/sh "$helper_dir/run.sh" "$helper_dir" "$helper_dir-link" >"$work/helper.out" 2>"$work/helper.err" || helper_status=$?
    if [ "$helper_status" -ne 0 ]; then
        printf 'installer temp-helper: expected exit 0, got %s\n' "$helper_status" >&2
        sed 's/^/      /' "$work/helper.err" >&2 || true
        failures=$((failures + 1))
    fi
fi

# --- W5: crash-leftover transactions must be refused, not deployed over -------
# The crash window is between `mv agentq_home -> backup_home` and `mv stage_home
# -> agentq_home`.  Measured 2026-10-07: without a guard the re-run treats the
# machine as fresh (`previous_install` stays false because $agentq_home is gone),
# skips copy_existing_data and moves an EMPTY stage into place.  In the common
# case an unrelated wrapper check masked it -- with a message pointing at the
# wrapper, not the stranded backup.  These cases pin the guard, and each also
# asserts the residue was NOT deleted: a guard that "fixed" the state by removing
# the operator's only copy of the queue would be worse than the silent deploy.
crash_case() {
    local label=$1 expected=$2 root_present=$3
    local home_before home_after status=0
    rm -rf "$home"/..agentq.backup.* "$home"/..agentq.stage.* "$home"/.agentq "$home"/.local
    mkdir -p "$home/..agentq.backup.SmokeAbC"
    [ "$root_present" = yes ] && mkdir -p "$home/.agentq"
    home_before=$(find "$home" -mindepth 1 2>/dev/null | LC_ALL=C sort)
    env HOME="$home" PATH="$stub_bare" \
        /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || status=$?
    check_case "$label" "$expected" "$status"
    home_after=$(find "$home" -mindepth 1 2>/dev/null | LC_ALL=C sort)
    if [ "$home_before" != "$home_after" ]; then
        printf 'installer %s: the guard changed HOME (it must touch nothing):\n' "$label" >&2
        diff <(printf '%s\n' "$home_before") <(printf '%s\n' "$home_after") | sed 's/^/      /' >&2 || true
        failures=$((failures + 1))
    fi
}
crash_case 'crash leftover, root missing' \
    "is missing but a previous run's transaction residue exists" no
# The recovery guidance must name the daemon restart: a crashed run has already
# stopped the daemon, so "move the backup back" alone leaves the operator stuck
# on the NEXT check (`daemon is unavailable`).  Measured in a real systemd
# container 2026-10-07.
crash_case 'crash leftover names the daemon restart' \
    'restart the AgentQ daemon' no
crash_case 'crash leftover, root present' \
    'exists beside the AgentQ root' yes
rm -rf "$home"/..agentq.backup.* "$home"/.agentq

# Fail-closed: an UNLISTABLE parent must refuse, not see "no residue" and
# proceed.  Without this case the fail-open mutation (dropping the `||
# crash_scan_failed=true`) passes the whole file -- measured: it did.
rm -rf "$home"/..agentq.backup.* "$home"/..agentq.stage.* "$home"/.agentq
chmod 000 "$home"
cases=$((cases + 1))
scan_status=0
env HOME="$home" PATH="$stub_bare" \
    /bin/sh "$assets/install-agentq.sh" >"$work/out" 2>"$work/err" || scan_status=$?
chmod 700 "$home"
if [ "$scan_status" -ne 2 ]; then
    printf 'installer unlistable parent: expected exit 2, got %s\n' "$scan_status" >&2
    sed 's/^/      /' "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'cannot inspect' "$work/err"; then
    printf 'installer unlistable parent: refused for the wrong reason:\n' >&2
    sed 's/^/      /' "$work/err" >&2 || true
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'installer-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'installer-contract checks passed: cases=%s sandbox-home=yes stub-path=yes download-path=covered toctou-path=covered plist-placeholder=guarded crash-leftover=covered\n' "$cases"
