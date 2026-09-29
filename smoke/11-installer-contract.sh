#!/usr/bin/env bash
# Smoke: the unix installer's FAILURE contract.  Nothing is installed -- every
# case here must be rejected before the installer writes anything, so the whole
# check runs against a sandbox HOME and a stub PATH.
#
# Why this check exists: assets/unix/install-agentq.sh is 2,755 lines -- the
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
#   - Windows.  install-agentq.ps1 is a different 2,881-line asset with a
#     different failure surface; it is not touched here.
#   - the hash-mismatch case below proves the installer REJECTS a bad binary; it
#     does not prove it accepts a good one.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
real_assets="$root/skill/assets/unix"
installer_source="$real_assets/install-agentq.sh"

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
# instead of letting all twelve cases report the same wrong message.
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
# `$HOME/.<name>.stage.$$` and takes a maintenance lock, so a rejection that
# forgot to clean either would show up here.
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
if [ "$(cat "$ps_query_counter" 2>/dev/null)" -lt 2 ]; then
    # If only one identity query happened the shim never got the chance to lie,
    # and this case silently degraded into the ordinary stale-lock case.
    printf '%s\n' 'installer unconfirmable-lock case: the re-confirmation was never attempted' >&2
    failures=$((failures + 1))
fi
kill "$unconfirmable_pid" 2>/dev/null || true
wait "$unconfirmable_pid" 2>/dev/null || true
background_pids=
rm -rf "$home/.agentq.maintenance.lock"
assert_home_clean 'lock liveness cannot be re-confirmed'

if [ "$failures" -ne 0 ]; then
    printf 'installer-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'installer-contract checks passed: cases=%s sandbox-home=yes stub-path=yes download-path=covered toctou-path=covered\n' "$cases"
