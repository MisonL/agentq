#!/usr/bin/env bash
# Smoke: the server rejects bad invocations with the documented exit codes and
# the documented message.  Exit code alone is not enough here: this check runs
# against a synthetic runtime assembled on the spot, so a "2" really means the
# argument was rejected rather than that startup failed for an unrelated
# reason.  Each case asserts the message too, so the failure is attributable.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-error.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# Minimal runtime layout the server insists on before it will parse arguments.
mkdir -p "$work/config" "$work/data/task_logs" "$work/data/agentq-cancellations" \
    "$work/data/agentq-requests/.locks" "$work/data/agentq-requests/.tombstones" \
    "$work/runtime"
# AGENTQ_SMOKE_SERVER selects the server under test (same hook as smoke/18) so
# the static rules below can be mutation-proven against a modified copy.
cp "${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}" "$work/agentq-server"
cp "$root/skill/assets/unix/pueue.yml" "$work/config/pueue.yml"
for stub in pueue pueued; do
    printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" "%s"\n' "$stub" > "$work/$stub"
    chmod 700 "$work/$stub"
done

server="$work/agentq-server"
failures=0
cases=0

# expect_rejected <label> <expected-message-fragment> <expected-reason> [args...]
#
# The third argument is the machine-readable failure class the server must print
# as `reason=<class>`.  Exit code 2 covers three unrelated situations (argument
# errors, lock contention, cancelling a finished task) and used to be
# distinguishable only by matching the human-readable message; the reason line
# is the reliable channel.  Asserting it here means a site that loses its reason
# -- or one that acquires the wrong class -- fails this check.
expect_rejected() {
    local label=$1 expected=$2 reason=$3
    shift 3
    local actual=0
    cases=$((cases + 1))
    "$server" "$@" >"$work/$label.stdout" 2>"$work/$label.stderr" || actual=$?
    if [ "$actual" -ne 2 ]; then
        printf '%s: expected exit 2, got %s\n' "$label" "$actual" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/$label.stderr"; then
        printf '%s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -3 "$work/$label.stderr" >&2 || true
        failures=$((failures + 1))
    fi
    if ! grep -qxF -- "agentq-server: reason=$reason" "$work/$label.stderr"; then
        printf '%s: stderr does not carry reason=%s\n' "$label" "$reason" >&2
        head -3 "$work/$label.stderr" >&2 || true
        failures=$((failures + 1))
    fi
}

expect_rejected no-args 'Usage:' protocol_error
expect_rejected unknown-command 'unknown command: definitely-not-a-command' protocol_error definitely-not-a-command
expect_rejected submit-no-request-id '--request-id must be' protocol_error submit --workdir "$work" -- true
expect_rejected lookup-short-id 'request id must be' protocol_error lookup abc
expect_rejected wait-non-numeric 'task id must be a non-negative integer' protocol_error wait abc
expect_rejected logs-no-task 'logs requires one task id' protocol_error logs
expect_rejected cancel-no-task 'cancel requires one task id' protocol_error cancel
expect_rejected remove-no-task 'remove requires one task id' protocol_error remove
expect_rejected status-extra-arg 'status accepts --summary or --task <id>' protocol_error status extra
# The batch form must demand --confirm (a mass deletion needs an explicit
# acknowledgement) and reject a malformed form before anything touches Pueue.
expect_rejected remove-label-no-confirm 'remove --label requires exactly a label and --confirm' protocol_error remove --label smoke
expect_rejected remove-label-missing-flag 'remove --label requires --confirm' protocol_error remove --label smoke --nope
expect_rejected remove-label-empty 'remove --label requires a non-empty label' protocol_error remove --label '' --confirm
expect_rejected doctor-extra-arg 'doctor accepts --full or no arguments' protocol_error doctor --bogus

# A non-ASCII request id must be rejected here too.  The guard used a bracket
# RANGE (`A-Za-z`) until 2026-11-06; under bash with a collating locale
# (macOS defaults to en_US.UTF-8) accented Latin letters fall INSIDE `A-Z`, so
# this server accepted `aaaaaaaaaaaaaaaaé` and answered 3 `not_found` -- an id
# its own contract calls illegal, and one the Windows client refuses with 2.
# 17 characters, so the length rule passes and only the charset can answer.
expect_rejected lookup-nonascii-id 'request id must be 16-128 ASCII letters' protocol_error \
    lookup "$(printf 'aaaaaaaaaaaaaaaa\303\251')"

# `[ -x ]` is TRUE for a directory (it tests the search bit), so a directory
# where the Pueue binary belongs passed require_executable.  Measured
# 2026-10-27: `doctor` then printed the SHELL's own diagnostic inside its
# machine-readable version block --
#   pueue=<path>/agentq-server: line 5805: <path>/pueue: is a directory
# -- and the contract says this program only ever exits 0-6 with controlled
# diagnostics.  The guard must name the shape and stop before anything execs.
cases=$((cases + 1))
pueue_backup="$work/pueue.regular-backup"
mv "$work/pueue" "$pueue_backup"
mkdir -p "$work/pueue"
server_status=0
"$server" doctor >"$work/pueue-dir.stdout" 2>"$work/pueue-dir.stderr" || server_status=$?
rmdir "$work/pueue"
mv "$pueue_backup" "$work/pueue"
if [ "$server_status" -ne 2 ]; then
    printf 'pueue-directory: expected exit 2, got %s\n' "$server_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'must be a regular file' "$work/pueue-dir.stderr"; then
    printf 'pueue-directory: stderr does not name the shape: %s\n' \
        "$(head -2 "$work/pueue-dir.stderr" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
if ! grep -qxF -- 'agentq-server: reason=protocol_error' "$work/pueue-dir.stderr"; then
    printf 'pueue-directory: stderr does not carry reason=protocol_error\n' >&2
    failures=$((failures + 1))
fi
if grep -qE 'is a directory|: line [0-9]+:' "$work/pueue-dir.stderr"; then
    printf 'pueue-directory: a raw shell diagnostic reached doctor stderr: %s\n' \
        "$(head -2 "$work/pueue-dir.stderr" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi

# The guard above catches a DIRECTORY, because `-f` rejects it before anything
# execs.  It does not catch the three shapes where `-x` says yes and exec still
# fails -- a 0755 regular file of plain text, a script whose interpreter is
# missing, and a shebang ending in CR -- because those pass both `-f` and `-x`.
# Measured 2026-10-30 (before the fix): doctor printed the SHELL's diagnostic
# inside the machine-readable version block --
#   pueue=/tmp/x/pueue: line 1: not: command not found
#   unavailable
# -- so the `pueue=` line carried shell noise instead of a value, and
# `unavailable` (the documented marker for exactly this case) was orphaned on
# the next line.  Same for `pueued=`.  The guard is in doctor's version block;
# assert all three shapes and both binaries, and require the fallback to land on
# the `key=` line where a parser will find it.
for pueue_shape in text missing-interpreter crlf-shebang; do
    case "$pueue_shape" in
        text)                printf 'not a binary\n' > "$work/pueue" ;;
        missing-interpreter) printf '#!/nonexistent/interpreter\nexit 0\n' > "$work/pueue" ;;
        crlf-shebang)        printf '#!/bin/sh\r\nexit 0\r\n' > "$work/pueue" ;;
    esac
    chmod 700 "$work/pueue"
    cp "$work/pueue" "$work/pueued"
    cases=$((cases + 1))
    server_status=0
    "$server" doctor >"$work/pueue-$pueue_shape.stdout" 2>"$work/pueue-$pueue_shape.stderr" || server_status=$?
    # Restore a working stub before the assertions, so a failure here cannot
    # cascade into every later case that needs a launcher.
    printf '#!/bin/sh\nprintf "pueue 4.0.4\\n"\n' > "$work/pueue"
    printf '#!/bin/sh\nprintf "pueued 4.0.4\\n"\n' > "$work/pueued"
    chmod 700 "$work/pueue" "$work/pueued"
    if ! grep -qxF 'pueue=unavailable' "$work/pueue-$pueue_shape.stderr"; then
        printf 'pueue-unlaunchable [%s]: the pueue= line is not the documented fallback: %s\n' \
            "$pueue_shape" "$(sed -n '/^pueue=/p' "$work/pueue-$pueue_shape.stderr" | head -1)" >&2
        failures=$((failures + 1))
    fi
    if ! grep -qxF 'pueued=unavailable' "$work/pueue-$pueue_shape.stderr"; then
        printf 'pueue-unlaunchable [%s]: the pueued= line is not the documented fallback: %s\n' \
            "$pueue_shape" "$(sed -n '/^pueued=/p' "$work/pueue-$pueue_shape.stderr" | head -1)" >&2
        failures=$((failures + 1))
    fi
    if grep -qE ': line [0-9]+:|bad interpreter|cannot execute|command not found' "$work/pueue-$pueue_shape.stderr"; then
        printf 'pueue-unlaunchable [%s]: a raw shell diagnostic reached doctor stderr: %s\n' \
            "$pueue_shape" "$(head -2 "$work/pueue-$pueue_shape.stderr" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    # The exit code must still be inside the documented contract: doctor may
    # legitimately fail (no real daemon here), but it must fail as 2, never as
    # the shell's own 126/127.
    case "$server_status" in
        0|2) ;;
        *)  printf 'pueue-unlaunchable [%s]: doctor exited %s, outside the documented 0-6 contract\n' \
                "$pueue_shape" "$server_status" >&2
            failures=$((failures + 1)) ;;
    esac
done

# The SAME class in the Linux arm of the same version block.  `platform` is
# `uname -s` at the top of the file, so this arm is reachable on any host by
# shadowing `uname`; the probes (systemctl/loginctl) are shadowed the same way, so no real
# service is ever consulted and nothing is started.  Pre-fix the block had the
# pueue= shape again -- `printf 'systemd_user_service=' >&2; systemctl ... >&2
# || true` -- which appended the probe's STDERR onto the key line.  Measured
# 2026-10-30 (this host, uname shadowed to Linux, no systemctl on PATH):
#   systemd_user_service=<path>/agentq-server: line N: systemctl: command not found
# and with a present-but-unusable systemctl:
#   systemd_user_service=Failed to connect to bus: No such file or directory
# A non-zero exit is NOT "no answer" here: `systemctl --user is-active` writes
# active/inactive/failed to STDOUT and exits 3 for an inactive unit, so the
# stdout answer must survive whatever the status -- the `unavailable` fallback
# is for "no stdout", not for "non-zero".  Assert both directions.
linux_shim="$work/linux-shim"
mkdir -p "$linux_shim"
printf '#!/bin/sh\nprintf "Linux\\n"\n' > "$linux_shim/uname"
chmod 700 "$linux_shim/uname"

# systemd_case <shape> <expected-user-service> <expected-linger>
systemd_case() {
    local shape=$1 expected_user=$2 expected_linger=$3
    case "$shape" in
        healthy)
            printf '#!/bin/sh\nprintf "active\\n"\n' > "$linux_shim/systemctl"
            printf '#!/bin/sh\nprintf "yes\\n"\n' > "$linux_shim/loginctl" ;;
        inactive-stdout)
            # Non-zero exit WITH the answer on stdout (systemd's is-active
            # returns 3 for an inactive unit): the value must still be taken.
            printf '#!/bin/sh\nprintf "inactive\\n"\nexit 3\n' > "$linux_shim/systemctl"
            printf '#!/bin/sh\nprintf "no\\n"\n' > "$linux_shim/loginctl" ;;
        bus-error)
            printf '#!/bin/sh\nprintf "Failed to connect to bus: No such file or directory\\n" >&2\nexit 1\n' > "$linux_shim/systemctl"
            printf '#!/bin/sh\nprintf "Failed to connect to bus: No such file or directory\\n" >&2\nexit 1\n' > "$linux_shim/loginctl" ;;
        unlaunchable)
            # 0755 regular file of plain text: `-x` says yes, exec fails, and
            # the SHELL writes the diagnostic.  Same shape as the pueue= loop.
            printf 'not a binary\n' > "$linux_shim/systemctl"
            printf 'not a binary\n' > "$linux_shim/loginctl" ;;
        uid-unresolved)
            # `id -un` -- the INNER command substitution feeding loginctl --
            # fails.  Its stderr is not covered by the OUTER `2>/dev/null` of
            # the capture line (a subshell's stderr is the server's stderr
            # unless that subshell redirects it itself), so pre-fix the
            # diagnostic rendered BETWEEN the two systemd lines.  The outer
            # probes answer normally: only the inner leak is under test.
            printf '#!/bin/sh\nprintf "inactive\\n"\nexit 3\n' > "$linux_shim/systemctl"
            printf '#!/bin/sh\nprintf "no\\n"\n' > "$linux_shim/loginctl"
            printf '#!/bin/sh\ncase "$*" in\n  *-un*) printf "id: cannot find name for user ID 501\\n" >&2; exit 1 ;;\n  *) printf "501\\n" ;;\nesac\n' > "$linux_shim/id" ;;
    esac
    chmod 700 "$linux_shim/systemctl" "$linux_shim/loginctl"
    [ -f "$linux_shim/id" ] || printf '#!/bin/sh\nprintf "501\\n"\n' > "$linux_shim/id"
    chmod 700 "$linux_shim/id"
    cases=$((cases + 1))
    server_status=0
    PATH="$linux_shim:$PATH" "$server" doctor \
        >"$work/systemd-$shape.stdout" 2>"$work/systemd-$shape.stderr" || server_status=$?
    local pair key expected count actual
    for pair in "systemd_user_service=$expected_user" "systemd_linger=$expected_linger"; do
        key=${pair%%=*}
        expected=${pair#*=}
        count=$(grep -c "^$key=" "$work/systemd-$shape.stderr" || true)
        if [ "$count" -ne 1 ]; then
            printf 'systemd-version-block [%s]: expected exactly one %s= line, found %s\n' \
                "$shape" "$key" "$count" >&2
            failures=$((failures + 1))
            continue
        fi
        if ! grep -qxF "$key=$expected" "$work/systemd-$shape.stderr"; then
            actual=$(grep "^$key=" "$work/systemd-$shape.stderr" | head -1)
            printf 'systemd-version-block [%s]: %s is `%s`, expected `%s=%s`\n' \
                "$shape" "$key" "$actual" "$key" "$expected" >&2
            failures=$((failures + 1))
        fi
    done
    if grep -qE ': line [0-9]+:|bad interpreter|cannot execute|command not found|Failed to connect to bus|(^|[^a-z_])id: ' \
        "$work/systemd-$shape.stderr"; then
        printf 'systemd-version-block [%s]: a raw probe diagnostic reached doctor stderr: %s\n' \
            "$shape" "$(head -3 "$work/systemd-$shape.stderr" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    case "$server_status" in
        0|2) ;;
        *)  printf 'systemd-version-block [%s]: doctor exited %s, outside the documented 0-6 contract\n' \
                "$shape" "$server_status" >&2
            failures=$((failures + 1)) ;;
    esac
}
systemd_case healthy          active   yes
systemd_case inactive-stdout  inactive no
systemd_case bus-error        unavailable unavailable
systemd_case unlaunchable     unavailable unavailable
systemd_case uid-unresolved   inactive no

# The OTHER `$(id -un)` fallback, and a different consumer: run_pueue builds
# Pueue's environment with `env -i USER="${USER:-$(id -un)}" ...`.  ssh command
# execution, cron and containers leave USER and LOGNAME unset, and the
# fallback's stderr is NOT covered by any redirect on that line (the `env -i`
# argument list has no redirection of its own), so it lands on the server's own
# stderr as a stray `id: cannot find name for user ID N` line -- noise for a
# caller that reads stderr for `reason=`.  Measured 2026-10-31 on Linux and
# macOS: two such lines (one per `$(id -un)`, since the two expansions do not
# see each other's assignment) with both variables unset and an `id` that
# fails; zero with USER set.  run_pueue's unix branch is chosen by
# platform_kind, not by the doctor arm, so this case needs no platform gate.
pueue_env_id="$work/pueue-env-id"
mkdir -p "$pueue_env_id"
printf '#!/bin/sh\ncase "$*" in\n  *-un*) printf "id: cannot find name for user ID 501\\n" >&2; exit 1 ;;\n  *) printf "501\\n" ;;\nesac\n' > "$pueue_env_id/id"
chmod 700 "$pueue_env_id/id"
cases=$((cases + 1))
env_status=0
env -u USER -u LOGNAME PATH="$pueue_env_id:$PATH" "$server" status \
    >"$work/pueue-env-id.stdout" 2>"$work/pueue-env-id.stderr" || env_status=$?
if grep -qE '(^|[^a-z_])id: ' "$work/pueue-env-id.stderr"; then
    printf 'pueue-env-id: the USER/LOGNAME fallback leaked its stderr: %s\n' \
        "$(head -3 "$work/pueue-env-id.stderr" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
case "$env_status" in
    0|1|2|3|4|5|6) ;;
    *)  printf 'pueue-env-id: server exited %s, outside the documented 0-6 contract\n' \
            "$env_status" >&2
        failures=$((failures + 1)) ;;
esac

# The SAME class in the DARWIN arm of the same version block.  `platform` is
# `uname -s` at the top of the file, so this arm is reachable on ANY host by
# shadowing `uname`, exactly as the Linux arm above is -- it does NOT need a
# macOS machine.  (An earlier draft of these cases gated them behind a `uname -s
# = Darwin` host check and declared the rest a NOT-covered platform gap; that
# claim is false.  Measured 2026-10-31 on this macOS host running the SERVER
# SHADOWED TO Linux, and on a real ubuntu:24.04 container shadowing `uname` to
# Darwin: both entered the arm and printed their `launchd_` lines.)  The probes
# differ only in that `id` answers for the caller and `launchctl` for the
# service; on a Linux host launchctl is simply absent, which the arm already
# tolerates, and on macOS nothing of AgentQ's is installed here, so both hosts
# take the same fall-through and the assertions below match a SHAPE, not a
# host-specific value.
# Pre-fix, an `id` that fails or cannot start made doctor print
#   launchd_service=<path>/id: line 1: not: command not found
# and exit 127, outside the documented 0-6 range, with NO `launchd_domain=`
# line and no reason line at all.  `launchd_domain` is asserted to name one of
# launchd's three real scopes rather than a specific one: a host where the
# service is installed as a LaunchDaemon answers `system` and still passes.
darwin_assert() {
    local label=$1 stderr_file=$2 status=$3
    local key count actual
    for key in launchd_service launchd_domain; do
        count=$(grep -c "^$key=" "$stderr_file" || true)
        if [ "$count" -ne 1 ]; then
            printf 'darwin-version-block [%s]: expected exactly one %s= line, found %s\n' \
                "$label" "$key" "$count" >&2
            failures=$((failures + 1))
            continue
        fi
        actual=$(grep "^$key=" "$stderr_file" | head -1)
        case "$key:$actual" in
            launchd_service:launchd_service=active|launchd_service:launchd_service=inactive|launchd_service:launchd_service=unavailable) ;;
            launchd_domain:launchd_domain=system|launchd_domain:launchd_domain=gui/*|launchd_domain:launchd_domain=user/*|launchd_domain:launchd_domain=unavailable) ;;
            *)  printf 'darwin-version-block [%s]: %s is `%s`, outside the documented shape\n' \
                    "$label" "$key" "$actual" >&2
                failures=$((failures + 1)) ;;
        esac
    done
    if grep -qE '(^|[^a-z_])id: |: line [0-9]+:|command not found|bad interpreter|cannot execute' "$stderr_file"; then
        printf 'darwin-version-block [%s]: a raw probe diagnostic reached doctor stderr: %s\n' \
            "$label" "$(head -6 "$stderr_file" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    case "$status" in
        0|2) ;;
        *)  printf 'darwin-version-block [%s]: doctor exited %s, outside the documented 0-6 contract\n' \
                "$label" "$status" >&2
            failures=$((failures + 1)) ;;
    esac
}

# Shape A: `id` runs and answers, but nothing it can print is a uid.  The
# domain falls through to the user-scope fallback and both lines stay whole.
darwin_stub_uid='aq-smoke-noninteger'
darwin_shim="$work/darwin-shim"
mkdir -p "$darwin_shim"
printf '#!/bin/sh\nprintf "Darwin\\n"\n' > "$darwin_shim/uname"
printf '#!/bin/sh\nprintf "%s\\n" "$AGENTQ_SMOKE_UID"\n' > "$darwin_shim/id"
chmod 700 "$darwin_shim/uname" "$darwin_shim/id"
cases=$((cases + 1))
darwin_status=0
PATH="$darwin_shim:$PATH" AGENTQ_SMOKE_UID="$darwin_stub_uid" "$server" doctor \
    >"$work/darwin.stdout" 2>"$work/darwin.stderr" || darwin_status=$?
darwin_assert answers "$work/darwin.stderr" "$darwin_status"

# Shape B: `id` is on PATH but cannot start -- 0755 regular file of plain text,
# the same "permission is not a promise" shape the pueue= and systemctl cases
# use.  The shell writes the diagnostic; the arm must still report both lines,
# with the documented `unavailable` sentinel rather than a fabricated `user/`.
darwin_broken="$work/darwin-broken"
mkdir -p "$darwin_broken"
printf '#!/bin/sh\nprintf "Darwin\\n"\n' > "$darwin_broken/uname"
printf 'not a binary\n' > "$darwin_broken/id"
# A launchctl that is present but reports every target absent: this is the state
# on any host with no AgentQ launchd service, and it keeps a Linux host (which
# has no launchctl at all) from stopping at the earlier `launchctl is required`
# guard, so BOTH hosts reach the same target resolution the assertions cover.
printf '#!/bin/sh\nexit 1\n' > "$darwin_broken/launchctl"
chmod 700 "$darwin_broken/uname" "$darwin_broken/id" "$darwin_broken/launchctl"
cases=$((cases + 1))
darwin_status=0
PATH="$darwin_broken:$PATH" "$server" doctor \
    >"$work/darwin-broken.stdout" 2>"$work/darwin-broken.stderr" || darwin_status=$?
darwin_assert cannot-start "$work/darwin-broken.stderr" "$darwin_status"
# The `unavailable` sentinel is the FIX for the fabricated `user/` the old code
# rendered with no uid.  It is only the right answer when the system LaunchDaemon
# is absent: on a host where AgentQ IS installed as a LaunchDaemon the target
# resolves to `system` before `id` is ever consulted, and `system` is a
# legitimate answer.  Assert `unavailable` only in the case this host can reach.
if ! grep -qxF 'launchd_domain=system' "$work/darwin-broken.stderr"; then
    grep -qxF 'launchd_service=unavailable' "$work/darwin-broken.stderr" || {
        printf 'darwin-version-block [cannot-start]: launchd_service must be `unavailable` when no uid can be read\n' >&2
        failures=$((failures + 1))
    }
    grep -qxF 'launchd_domain=unavailable' "$work/darwin-broken.stderr" || {
        printf 'darwin-version-block [cannot-start]: launchd_domain must be `unavailable` when no uid can be read\n' >&2
        failures=$((failures + 1))
    }
fi

# The guard that keeps an empty target away from `launchctl kickstart`.  Tolerating a
# failing `id` made a previously-unreachable state reachable: with no uid the
# target is empty, and `launchctl kickstart ""` is not a no-op -- macOS answers
# by listing every service in the domain, 55238 bytes on stderr measured
# 2026-10-31, which would bury this command's own diagnostics.  Reaching the
# start path needs `run_pueue status --json` to fail, so the pueue stub is
# swapped the same way bad_status_run does it, and restored immediately.
cases=$((cases + 1))
cp "$work/pueue" "$work/pueue.real"
cat > "$work/pueue" <<'STUB'
#!/bin/sh
case "$*" in
    *"status --json"*) printf 'pueue status is unavailable\n' >&2; exit 1 ;;
    *) printf 'pueue 4.0.4\n' ;;
esac
STUB
chmod 700 "$work/pueue"
darwin_start_status=0
PATH="$darwin_broken:$PATH" "$server" status \
    >"$work/darwin-start.stdout" 2>"$work/darwin-start.stderr" || darwin_start_status=$?
mv "$work/pueue.real" "$work/pueue"
if [ "$darwin_start_status" -ne 2 ]; then
    printf 'darwin-start-guard: expected exit 2, got %s\n' "$darwin_start_status" >&2
    failures=$((failures + 1))
fi
# Two legitimate refusals reach here, and which one depends only on whether this
# host has AgentQ installed as a system LaunchDaemon: with the plist present the
# target resolves to `system` and the guard refuses THAT; otherwise the target is
# empty and the guard refuses the missing uid.  Both must be controlled, both
# must carry the reason line, and neither may be the shell's own diagnostic.
if grep -qxF -- 'agentq-server: cannot determine the launchd service target: no user id could be read' \
    "$work/darwin-start.stderr"; then
    :
elif grep -qxF -- 'agentq-server: system LaunchDaemon com.agentq.pueued is inactive; rerun the AgentQ installer in an interactive sudo session' \
    "$work/darwin-start.stderr"; then
    :
else
    printf 'darwin-start-guard: neither controlled refusal is present\n' >&2
    head -3 "$work/darwin-start.stderr" >&2 || true
    failures=$((failures + 1))
fi
if ! grep -qxF -- 'agentq-server: reason=protocol_error' "$work/darwin-start.stderr"; then
    printf 'darwin-start-guard: the reason line is missing\n' >&2
    failures=$((failures + 1))
fi
# The flood guard: an empty target must never reach launchctl, whose refusal is
# tens of kilobytes.  A byte ceiling is the measurable form of "it did not".
# 1024 is far below the 55238-byte flood and far above these controlled lines.
darwin_start_bytes=$(wc -c < "$work/darwin-start.stderr" | tr -d ' ')
if [ "$darwin_start_bytes" -gt 1024 ]; then
    printf 'darwin-start-guard: stderr was %s bytes; an empty target reached launchctl\n' \
        "$darwin_start_bytes" >&2
    failures=$((failures + 1))
fi


# The SAME class in the WINDOWS arm of the same version block -- the third and
# last of the three, and the one PLAN.md had recorded as "no platform to
# measure".  That was right about the FAILURE mode being unmeasurable (macOS
# has no Get-ScheduledTask) but wrong about reachability: the arm is entered by
# shadowing `uname -s` (-> MINGW64) AND `cygpath` AND `powershell.exe`, exactly
# as the Linux arm is entered by shadowing `uname`.  No real service is
# consulted and nothing is started -- every probe is a stub.  Pre-fix the block
# wrote the KEY (`printf 'scheduled_task=' >&2`, no newline) and the probe's
# stdout to the SAME stream, so a failing probe's own text landed ON the key
# line, and a quietly-failing probe made the human advisory the value.  Measured
# 2026-10-31 (this host, arm reached by the three shadows above):
#   scheduled_task=Get-ScheduledTask : No MSFT_ScheduledTask objects found ...
#   scheduled_task=<program>: scheduled startup task is unavailable; ...
# Assert one `scheduled_task=` line: the JSON on success, `unavailable` on any
# failure, never raw probe text, exit inside 0-6.
windows_shim="$work/windows-shim"
mkdir -p "$windows_shim"
printf '#!/bin/sh\nprintf "MINGW64_NT-10.0\\n"\n' > "$windows_shim/uname"
# The two cygpath shapes the server uses before doctor: -u (profile -> POSIX
# home at resolve time) and -aw (path -> windows form at dispatch time).
printf '#!/bin/sh\ncase "$1" in\n  -u) printf "/c/stub/aquser\\n" ;;\n  *) printf "%%s\\n" "${2:-$1}" ;;\nesac\n' > "$windows_shim/cygpath"
chmod 700 "$windows_shim/uname" "$windows_shim/cygpath"
# The Windows arm also needs the two launcher binaries and the durable-move
# helper, plus the v2 request-layout marker -- all reached before doctor's
# version block.  pueue/pueued are the same stub shape the pueue= cases use.
printf '#!/bin/sh\nprintf "pueue 4.0.4\\n"\n' > "$work/pueue.exe"
printf '#!/bin/sh\nprintf "pueued 4.0.4\\n"\n' > "$work/pueued.exe"
chmod 700 "$work/pueue.exe" "$work/pueued.exe"
# The layout marker the server writes on first unix doctor run.
printf 'v2\n' > "$work/runtime/agentq-request-tombstones-v2"
chmod 700 "$work/runtime/agentq-request-tombstones-v2"
printf 'placeholder\n' > "$work/agentq-durable-move.ps1"

# scheduled_task_case <shape> <expected-value-or-JSON>
#
# Shapes ok / err-stderr / quiet-fail assert the fixed line's contract.  Shape
# unlaunchable asserts the GATE: a powershell.exe that `-x` accepts but the
# kernel cannot exec makes the server exit 2 during profile resolution, BEFORE
# any version-block line exists -- there is no scheduled_task= line to leak on.
scheduled_task_case() {
    local shape=$1 expected=$2
    # The stub must answer BOTH powershell.exe calls the Windows branch makes:
    # resolve_windows_user_environment (-Command '<big script>') and doctor's
    # version block (-Command "Get-ScheduledTask ...").  A stub that answers
    # only the second dies on the first, before doctor runs at all.
    local resolve_json='{"identity":"STUB\\aquser","user_name":"aquser","profile":"C:\\Users\\aquser","app_data":"C:\\Users\\aquser\\AppData\\Roaming","local_app_data":"C:\\Users\\aquser\\AppData\\Local","temp":"C:\\Users\\aquser\\AppData\\Local\\Temp","path":"C:\\Windows\\System32;C:\\Program Files\\Git\\cmd","pathext":".COM;.EXE;.BAT;.CMD","comspec":"C:\\Windows\\System32\\cmd.exe","system_root":"C:\\Windows","system_drive":"C:","windir":"C:\\Windows","home_drive":"C:","home_path":"\\Users\\aquser"}'
    local task_json='{"TaskName":"AgentQ Pueued","State":3}'
    local scheduled_line
    case "$shape" in
        ok)
            # The success answer is GENERATED, not hand-quoted: writing it as
            # 'printf ''<json>''\n' does not embed quotes -- bash treats `''`
            # as two empty strings, so the stub gets the JSON unquoted and its
            # shell brace-expands `{a,b}` into garbage before printf runs.
            scheduled_line=$(printf "  *Get-ScheduledTask*) printf '%%s\\\\n' %s ;;" "'$task_json'")
            ;;
        err-stderr)
            # Failure WITH text on the ERROR stream -- what a real failing
            # cmdlet does (measured on pwsh 7.5: stderr 94 B, stdout 0).
            scheduled_line='  *Get-ScheduledTask*) printf "Get-ScheduledTask : No MSFT_ScheduledTask objects found\n" >&2; exit 1 ;;'
            ;;
        quiet-fail)
            # Failure with NO output at all: the old form made the advisory
            # itself the value.
            scheduled_line='  *Get-ScheduledTask*) exit 1 ;;'
            ;;
        unlaunchable)
            # 0755 regular file of plain text: `-x` says yes, exec fails, the
            # SHELL writes the diagnostic.  This is the WHOLE stub -- neither
            # call can be answered, so the profile resolution must fail first.
            printf 'not a binary\n' > "$windows_shim/powershell.exe"
            chmod 700 "$windows_shim/powershell.exe"
            cases=$((cases + 1))
            server_status=0
            MSYSTEM=MINGW64 PATH="$windows_shim:$PATH" "$server" doctor \
                >"$work/schtask-$shape.stdout" 2>"$work/schtask-$shape.stderr" || server_status=$?
            if [ "$server_status" -ne 2 ]; then
                printf 'scheduled-task-block [%s]: expected exit 2 (profile resolution fails first), got %s\n' \
                    "$shape" "$server_status" >&2
                failures=$((failures + 1))
            fi
            if ! grep -qF 'unable to resolve the current Windows user profile' "$work/schtask-$shape.stderr"; then
                printf 'scheduled-task-block [%s]: stderr does not carry the profile-resolution diagnosis\n' "$shape" >&2
                failures=$((failures + 1))
            fi
            if [ "$(grep -c '^scheduled_task=' "$work/schtask-$shape.stderr" || true)" -ne 0 ]; then
                printf 'scheduled-task-block [%s]: a scheduled_task= line exists although doctor never reached the version block\n' "$shape" >&2
                failures=$((failures + 1))
            fi
            return 0
            ;;
    esac
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '%s\n' "$scheduled_line"
        # The resolve format string must be quoted INSIDE the stub: unquoted
        # `%s\n` loses the backslash to the stub shell's quote removal, so
        # printf sees `%sn` -- the JSON gains a stray trailing `n` and loses
        # its newline, and the server's jq parse fails before doctor runs.
        printf "  *) printf '%%s\\\\n' %s ;;\n" "'$resolve_json'"
        printf 'esac\n'
    } > "$windows_shim/powershell.exe"
    chmod 700 "$windows_shim/powershell.exe"
    scheduled_task_assert "$shape" "$expected"
}

scheduled_task_assert() {
    local shape=$1 expected=$2
    cases=$((cases + 1))
    server_status=0
    MSYSTEM=MINGW64 PATH="$windows_shim:$PATH" "$server" doctor \
        >"$work/schtask-$shape.stdout" 2>"$work/schtask-$shape.stderr" || server_status=$?
    local count
    count=$(grep -c '^scheduled_task=' "$work/schtask-$shape.stderr" || true)
    if [ "$count" -ne 1 ]; then
        printf 'scheduled-task-block [%s]: expected exactly one scheduled_task= line, found %s\n' \
            "$shape" "$count" >&2
        failures=$((failures + 1))
    elif ! grep -qxF "scheduled_task=$expected" "$work/schtask-$shape.stderr"; then
        printf 'scheduled-task-block [%s]: scheduled_task is `%s`, expected `scheduled_task=%s`\n' \
            "$shape" "$(grep '^scheduled_task=' "$work/schtask-$shape.stderr" | head -1)" "$expected" >&2
        failures=$((failures + 1))
    fi
    if grep -qE 'MSFT_ScheduledTask|Get-ScheduledTask :|: line [0-9]+:|command not found' "$work/schtask-$shape.stderr"; then
        printf 'scheduled-task-block [%s]: a raw probe diagnostic reached doctor stderr: %s\n' \
            "$shape" "$(head -3 "$work/schtask-$shape.stderr" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    case "$server_status" in
        0|2) ;;
        *)  printf 'scheduled-task-block [%s]: doctor exited %s, outside the documented 0-6 contract\n' \
                "$shape" "$server_status" >&2
            failures=$((failures + 1)) ;;
    esac
}
scheduled_task_case ok          '{"TaskName":"AgentQ Pueued","State":3}'
scheduled_task_case err-stderr  unavailable
scheduled_task_case quiet-fail  unavailable
scheduled_task_case unlaunchable unavailable

# A malformed Pueue status must NOT surface as exit 5.  The contract reserves 5
# for a REMOVED task; but compact_status's jq filter ends in
# error("invalid visible Pueue task metadata"), and jq exits 5 on error() -- so
# before 2026-10-12 `status`/`doctor` exited 5 with no body and no reason line,
# and a caller reading 5 as "removed" was misled.  This drives status against a
# stub whose `status --json` returns a task MISSING `created_at` (a shape
# validate_pueue_task_shape_in_file does not check -- it only validates id
# precision), so the error() fires for real.  Every other compactor (logs, wait,
# cancel, remove) folds this through report_compact_task_failure.
bad_status_run() {
    local op=$1
    cases=$((cases + 1))
    local status_rc=0
    # The server resolves pueue as "$agentq_root/pueue" (its own directory),
    # NOT via PATH -- so swap $work/pueue itself, then restore it.
    cp "$work/pueue" "$work/pueue.real"
    cat > "$work/pueue" <<'STUB'
#!/bin/sh
# `status --json` returns a group with one task that has an id but no
# created_at; `group --json` reports the agentq group so verify_group passes.
case "$*" in
    *"group --json"*) printf '{"agentq":{"parallel_tasks":1}}\n' ;;
    *"status --json"*)
        printf '{"tasks":{"7":{"id":7,"group":"agentq"}},"groups":{"agentq":{"parallel_tasks":1}}}\n'
        ;;
    *) printf 'pueue 4.0.4\n' ;;
esac
STUB
    chmod 700 "$work/pueue"
    "$server" "$op" >"$work/bad.$op.out" 2>"$work/bad.$op.err" || status_rc=$?
    mv "$work/pueue.real" "$work/pueue"
    if [ "$status_rc" -ne 2 ]; then
        printf 'a malformed Pueue status made `%s` exit %s; the contract reserves 5 for a removed task and requires 2 (protocol_error) for an unreadable status\n' \
            "$op" "$status_rc" >&2
        head -3 "$work/bad.$op.err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    # Anchored exactly like expect_rejected above: an unanchored grep would
    # also match a reason line embedded in some longer message, and the
    # contract is a LINE `agentq-server: reason=<class>` at the end of stderr.
    if ! grep -qxF -- 'agentq-server: reason=protocol_error' "$work/bad.$op.err"; then
        printf 'a malformed Pueue status made `%s` exit 2 without a reason=protocol_error line\n' "$op" >&2
        head -3 "$work/bad.$op.err" >&2 || true
        failures=$((failures + 1))
    fi
}
bad_status_run status
bad_status_run doctor

# `cancel` on a finished task (`reason=task_not_running`) is deliberately NOT
# asserted here: it needs a real Pueue task that has actually completed, and
# this check's runtime is a stub.  It is covered in 03, which runs against the
# real runtime -- asserting it against the stub would only prove that a broken
# stub still produces exit 2.

# The usage text is the machine-readable command surface.  It must list exactly
# the commands SKILL.md and CLAUDE.md document -- no more, no fewer -- so a
# command cannot be added or dropped without the documentation following.
documented_commands='submit lookup status logs cancel wait remove doctor'
"$server" >"$work/usage.stdout" 2>"$work/usage.stderr" || true
actual_commands=$(
    sed -n 's/^  [^ ][^ ]* \([a-z][a-z]*\).*/\1/p' "$work/usage.stderr" \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
)
expected_commands=$(printf '%s\n' $documented_commands | sort -u | tr '\n' ' ' | sed 's/ $//')
if [ "$actual_commands" != "$expected_commands" ]; then
    printf 'command surface drift:\n  documented: %s\n  usage:      %s\n' \
        "$expected_commands" "$actual_commands" >&2
    failures=$((failures + 1))
fi

# Static companion to the runtime cases above: every exit-2 site that prints a
# message must also print a reason line.  The runtime cases only reach the
# dispatcher's argument paths; the Windows-only paths (MSYSTEM missing, jq
# missing, profile metadata incomplete, cygpath failure, empty home path) are
# unreachable on this host and are exactly the ones that had lost their reason
# line -- a caller following the documented rule ("read reason, never match
# message text") got nothing there, and would read the silence as a client-side
# regression.
#
# The rule is structural, not a fixed line window: a line writing to stderr
# (`>&2`, whatever the printer -- see the widening note below) that does not
# itself carry `reason=` and whose next statement is `exit 2`.
# Windows in either direction are wrong -- a narrow one misses a re-check a few
# lines later, a wide one matches the next function (both mistakes were made in
# smoke/10's rule G).  Blank lines and comments between the two are tolerated.
# `fail()` is excluded: it emits reason= from the one place that owns it.
# Continuation lines are JOINED before the test.  Without that, a message split
# as `printf '...' \\` / `"$program" >&2` never satisfies the `>&2` test and the
# site is invisible -- the same shape the rule exists to catch, just wrapped.
#
# Why the rule matches literal `exit 2` and NOT `return 2`: the contract
# promises a reason line on every path that reaches the top level as 2.  A
# `return 2` inside a function is an internal value; whether it becomes the
# process exit code depends on how each caller folds it.  A 2026-10-12 review
# audited all 13 `return 2` sites (1188/1199/1507/1526/1540/1581/1588/1595/
# 1790/1794/1800/1807/3601) and concluded every one is folded -- but that audit
# MISSED the maintenance-lock family (recover_stale_maintenance_lock's three
# refusal sites, 1507/1526/1540 back then): it is called BARE from
# ensure_not_in_maintenance, which itself is called bare from main(), so its
# `return 2` reached the top level as exit 2 with NO reason line (reproduced
# 2026-10-13: a live-holder identity mismatch printed the refusal and exited 2
# with `grep -c reason=` = 0).  Fixed 2026-10-13: all three sites now emit
# `reason=protocol_error` before returning.  Matching `return 2` here instead
# would have reported all 13 and buried the one real gap, so the rule stays on
# `exit 2` and the return-2 audit lives in this comment plus the fix above.
# The scan is a FUNCTION so the self-test below exercises the published code
# instead of a copy of it (the smoke/05 lesson).  It prints one line per gap
# and, as its last line, `__SITES__N` -- the number of message sites it
# EXAMINED, gaps and conforming sites alike.  That count is the positive
# control: an absence rule whose enumerator finds nothing reports "no gaps" for
# exactly the same reason a broken one does.
#
# A message site is ANY line writing to stderr (`>&2`) whose next statement is
# `exit 2` -- not only `printf`.  Measured 2026-10-27: with the literal
# `printf` requirement, a server copy carrying an `echo ... >&2` + `exit 2`
# site with no reason line printed `reason-gaps=0` and exited 0.  Widening to
# `>&2` finds the same 9 sites on the real server, so it added no false
# positives.
reason_gap_scan() { # $1 = file -> gap lines + a final __SITES__N line
    awk '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                pending = line
                next
            }
            joined[++n] = line
        }
        END {
            if (pending != "") joined[++n] = pending
            for (i = 1; i < n; i++) {
                if (joined[i] ~ /^[[:space:]]*#/ || joined[i] !~ />&2/) continue
                j = i + 1
                while (j <= n && (joined[j] ~ /^[[:space:]]*$/ || joined[j] ~ /^[[:space:]]*#/)) j++
                if (j <= n && joined[j] ~ /^[[:space:]]*exit 2[[:space:]]*$/) {
                    sites++
                    if (joined[i] !~ /reason=/) printf "%d:%s\n", i, joined[i]
                }
                # Same one-liner shape on a single physical line
                # (`printf ... >&2; exit 2`): none exist today (checked
                # 2026-10-13) but the shape escapes the join above -- a
                # semicolon-joined message+exit-2 is reported as
                # cannot-conclude rather than silently invisible.
                if (j == i + 1 && joined[i] ~ />&2;[[:space:]]*exit 2[[:space:]]*$/ && joined[i] !~ /reason=/) {
                    sites++
                    printf "%d:CANNOT-CONCLUDE(one-liner message+exit2):%s\n", i, joined[i]
                }
            }
            printf "__SITES__%d\n", sites
        }' "$1"
}

# The scan must catch a message site with no reason line in BOTH spellings --
# `printf` and `echo` -- and must count the conforming site it examined.  A scan
# that silently stopped matching would otherwise read as a clean server.
reason_fixture=$work/reason-sites.fixture
cat >"$reason_fixture" <<'FIXTURE'
good_site() {
    printf '%s: reason=protocol_error\n' "$program" >&2
    exit 2
}
printf_missing_reason() {
    printf '%s: no reason here\n' "$program" >&2
    exit 2
}
echo_missing_reason() {
    echo 'no reason here either' >&2
    exit 2
}
FIXTURE
reason_fixture_raw=$(reason_gap_scan "$reason_fixture")
reason_fixture_sites=$(printf '%s\n' "$reason_fixture_raw" | sed -n 's/^__SITES__//p')
reason_fixture_gaps=$(printf '%s\n' "$reason_fixture_raw" | grep -v '^__SITES__' | grep -c . || true)
if [ "$reason_fixture_sites" != 3 ] || [ "$reason_fixture_gaps" != 2 ]; then
    printf 'error-contract: the exit-2 reason scan failed its self-test (expected 3 sites / 2 gaps, got %s / %s); a blind scan would read as a clean server\n' \
        "$reason_fixture_sites" "$reason_fixture_gaps" >&2
    failures=$((failures + 1))
fi

reason_scan_raw=$(reason_gap_scan "$server")
reason_sites=$(printf '%s\n' "$reason_scan_raw" | sed -n 's/^__SITES__//p')
case ${reason_sites:-} in
    '' | *[!0-9]*) reason_sites=0 ;;
esac
if [ "$reason_sites" -eq 0 ]; then
    printf '%s\n' 'error-contract: the exit-2 reason rule examined 0 message sites; a rule that examined nothing must not report "no gaps" -- the join or the site predicate has stopped matching the server' >&2
    failures=$((failures + 1))
fi
reason_gap_sites=$(printf '%s\n' "$reason_scan_raw" | grep -v '^__SITES__' || true)
if [ -n "$reason_gap_sites" ]; then
    printf 'exit-2 sites print a message but no reason line:\n%s\n' "$reason_gap_sites" >&2
    failures=$((failures + 1))
fi
# The gap count is derived from the same variable the guard above acts on, not a
# hardcoded 0: a literal would keep reading "reason-gaps=0" if the guard were
# ever separated from the summary.  It is 0 whenever this line is reached.
if [ -n "$reason_gap_sites" ]; then
    reason_gap_count=$(grep -c . <<< "$reason_gap_sites")
else
    reason_gap_count=0
fi

# Second structural rule, closing the hole the first one cannot see: a message
# followed by `return 2` inside a function that is invoked BARE (not as an `if`
# condition and not under `||`/`&&`) somewhere in the file.  A bare call under
# `set -e` turns that return value into the process exit code, so the contract
# applies to it exactly as to a literal `exit 2` -- this is precisely the shape
# the 2026-10-12 manual audit missed (recover_stale_maintenance_lock, see the
# comment above).  The rule is structural, not a name list: renaming the
# function, adding a call site, or dropping the reason line all go red.
# Functions are tracked by scanning for `name() {` definitions; a site is
# "bare" when a line IS that name, alone OR followed by arguments.  Calls
# guarded by if/||/&& or inside $( ) are fine -- their return value is folded by
# the caller, which must then carry the reason itself.
#
# ARGUMENTS ARE INCLUDED, and that was a measured hole (2026-10-20): the first
# version matched only `^[[:space:]]*[a-z_]+[[:space:]]*$`, i.e. a zero-argument
# call.  Injected proof: a function that prints to stderr and `return 2`s, called
# bare as `mutant_check jq` from ensure_runtime_dependencies, was NOT reported by
# this rule (26 other failures fired, all from the runtime half) -- the shape the
# rule exists for was reachable simply by passing an argument.  A fourth form was
# added 2026-10-20 after the same exercise on the REPAIR path: a call joined by
# a semicolon on one physical line.
# Same shape as the exit-2 scan: a function, a __SITES__ positive control and a
# self-test, so this rule also cannot report "no gaps" after examining
# nothing.  The site predicate is widened the same way -- any `>&2` writer,
# not only `printf`; measured on the real server, both predicates select the
# same 13 candidates and the same 3 judged sites.
return2_gap_scan() { # $1 = file -> gap lines + a final __SITES__N line
    awk '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                pending = line
                next
            }
            joined[++n] = line
        }
        END {
            if (pending != "") joined[++n] = pending
            for (i = 1; i <= n; i++) {
                if (joined[i] ~ /^[[:space:]]*[a-z_][a-z0-9_]*\(\) \{[[:space:]]*$/) {
                    f = joined[i]; sub(/^[[:space:]]*/, "", f); sub(/\(\).*$/, "", f)
                    defined[f] = 1
                }
                # a call is bare when the whole line is the name, optionally
                # followed by arguments -- but never when it is part of a
                # pipeline, an `if`/`while` head, an assignment, or a
                # substitution, all of which fold the status instead.
                if (joined[i] !~ /^[[:space:]]*[a-z_][a-z0-9_]*([[:space:]]|$)/) continue
                if (joined[i] ~ /[|&;]/ || joined[i] ~ /\$\(/ || joined[i] ~ /\\x60/) continue
                if (joined[i] ~ /(^|[[:space:]])[<>]/) continue
                f = joined[i]; sub(/^[[:space:]]*/, "", f); sub(/[[:space:]].*$/, "", f)
                bare[f] = 1
                # `name arg` joined after a guard keyword on the SAME line was
                # never bare either (the keyword is the first token), so it is
                # skipped by the regex above rather than here.
                # A call whose very next statement is `return $?` is FOLDING the
                # status, not letting it escape -- `set -e` never sees the
                # failure.  That is exactly the shape in
                # cleanup_temporary_file_after_make_failure, where the call to
                # remove_runtime_temporary_file is followed by `return $?`,
                # which the first draft of this widening reported as a gap; the
                # callers up the chain fold again (`|| return 1`).  Counting it
                # would be a false positive of the same kind the widening was
                # meant to remove, so the fold is subtracted before the site is
                # judged.  (No apostrophes in this block: it is inside a single-
                # quoted awk program and one would close it -- the exact crash
                # recorded for smoke/10 rule J.)
                if (joined[i] !~ /^[[:space:]]*[a-z_][a-z0-9_]*\(\) \{[[:space:]]*$/) {
                    f = joined[i]; sub(/^[[:space:]]*/, "", f)
                    if (f ~ /^[a-z_][a-z0-9_]*([[:space:]]|$)/ && f !~ /[|&;]/ && f !~ /\$\(/ && f !~ /\\x60/ &&
                        f !~ /(^|[[:space:]])[<>]/) {
                        sub(/[[:space:]].*$/, "", f)
                        k = i + 1
                        while (k <= n && (joined[k] ~ /^[[:space:]]*$/ || joined[k] ~ /^[[:space:]]*#/)) k++
                        if (k <= n && joined[k] ~ /^[[:space:]]*return \$[?][[:space:]]*$/) folded[f] = 1
                    }
                }
            }
            cur = ""
            for (i = 1; i < n; i++) {
                if (joined[i] ~ /^[[:space:]]*[a-z_][a-z0-9_]*\(\) \{[[:space:]]*$/) {
                    cur = joined[i]; sub(/^[[:space:]]*/, "", cur); sub(/\(\) \{[[:space:]]*$/, "", cur)
                }
                if (joined[i] ~ /^[[:space:]]*#/ || joined[i] !~ />&2/) continue
                j = i + 1
                while (j <= n && (joined[j] ~ /^[[:space:]]*$/ || joined[j] ~ /^[[:space:]]*#/)) j++
                if (j <= n && joined[j] ~ /^[[:space:]]*return 2[[:space:]]*$/ && cur != "" && bare[cur] && !(cur in folded)) {
                    sites++
                    if (joined[i] !~ /reason=/) printf "%d [%s]: %s\n", i, cur, joined[i]
                }
            }
            # POSITIVE CONTROL THAT STILL EXISTS when the server has no
            # message+return-2 site left in a bare function.  That happened in
            # 0.1.28: the rewritten recovery paths answer through fail(), which
            # exits 2 with its own reason line, so the judged-site count fell
            # to 0 -- not because the rule went blind, but because the shape is
            # gone.  Counting BARE-INVOKED FUNCTIONS keeps the "the detector
            # still matches this server" assertion alive: a bare-call detection
            # that stopped matching would read 0 here even with judged sites
            # still present.  (The judged-site count is still reported, and any
            # gap it finds still fails the check.)
            nb = 0
            for (f in defined) if (f in bare) nb++
            printf "__BAREFUNCS__%d\n", nb
            printf "__SITES__%d\n", sites
        }' "$1"
}

# The scan must catch a reason-less site in a bare-invoked function in BOTH
# spellings, count the conforming one, and NOT count a function that is never
# called bare (the rule's own boundary).
return2_fixture=$work/return2-sites.fixture
cat >"$return2_fixture" <<'FIXTURE'
conforming_helper() {
    printf '%s: reason=protocol_error\n' "$program" >&2
    return 2
}
missing_reason_helper() {
    echo 'no reason here' >&2
    return 2
}
never_called_helper() {
    echo 'not judged' >&2
    return 2
}
bare_caller() {
    conforming_helper
}
another_bare_caller() {
    missing_reason_helper
}
FIXTURE
return2_fixture_raw=$(return2_gap_scan "$return2_fixture")
return2_fixture_sites=$(printf '%s\n' "$return2_fixture_raw" | sed -n 's/^__SITES__//p')
return2_fixture_gaps=$(printf '%s\n' "$return2_fixture_raw" | grep -v '^__SITES__\|^__BAREFUNCS__' | grep -c . || true)
if [ "$return2_fixture_sites" != 2 ] || [ "$return2_fixture_gaps" != 1 ]; then
    printf 'error-contract: the return-2 reason scan failed its self-test (expected 2 judged sites / 1 gap, got %s / %s); a blind scan would read as a clean server\n' \
        "$return2_fixture_sites" "$return2_fixture_gaps" >&2
    failures=$((failures + 1))
fi

return2_scan_raw=$(return2_gap_scan "$server")
return2_sites=$(printf '%s\n' "$return2_scan_raw" | sed -n 's/^__SITES__//p')
case ${return2_sites:-} in
    '' | *[!0-9]*) return2_sites=0 ;;
esac
return2_bare_funcs=$(printf '%s\n' "$return2_scan_raw" | sed -n 's/^__BAREFUNCS__//p')
case ${return2_bare_funcs:-} in
    '' | *[!0-9]*) return2_bare_funcs=0 ;;
esac
if [ "$return2_bare_funcs" -eq 0 ]; then
    printf '%s\n' 'error-contract: the return-2 reason rule matched 0 bare-invoked functions; a rule that cannot find the functions it audits must not report "no gaps" -- the bare-call detection has stopped matching the server' >&2
    failures=$((failures + 1))
fi
return2_gap_sites=$(printf '%s\n' "$return2_scan_raw" | grep -v '^__SITES__\|^__BAREFUNCS__' || true)
if [ -n "$return2_gap_sites" ]; then
    printf 'return-2 sites in bare-invoked functions print a message but no reason line:\n%s\n' "$return2_gap_sites" >&2
    failures=$((failures + 1))
fi

# Third structural rule: the server's EXIT trap must be `|| true`-guarded.
# Measured 2026-10-13 on bash and dash: under `set -e`, a non-zero return from
# the trap body trips errexit and the process exits with the CLEANUP's code --
# a successful `exit 0` reads as 1, and a `wait`'s 5/6 or a `fail`'s 2 (reason
# already printed) read as an undifferentiated 1.  Reproduced on a real server
# with a lock directory made unremovable: stdout was the correct removed JSON
# and the exit code was 1.  The POSIX clients' signal traps were hardened in
# 0.1.5/0.1.6 and the server's EXIT slot was the one missed; this rule pins the
# hardened form so the next trap edit cannot regress it.
cases=$((cases + 1))
if ! grep -q "^trap 'cleanup || true' EXIT$" "$server"; then
    printf '%s\n' 'error-contract: the server EXIT trap is not `|| true`-guarded; a failing lock/teardown cleanup replaces the server protocol exit code (measured 2026-10-13)' >&2
    failures=$((failures + 1))
fi

# A bash function called at top level BEFORE its definition dies with
# "command not found" (exit 127) -- on the Windows target that surfaced as the
# installer's launcher smoke reading 127 instead of the contract's 2
# (measured on the test VM 2026-10-14: install_jq_line_ending_shim was called
# at line 220 from the platform dispatch while its definition sat at 382; the
# whole doctor path returned 127).  Lock the measured case structurally: the
# shim installer's definition must precede its every call site.
cases=$((cases + 1))
shim_def_line=$(grep -n '^install_jq_line_ending_shim() {' "$server" | head -1 | cut -d: -f1)
shim_call_lines=$(grep -n '^[[:space:]]*install_jq_line_ending_shim$' "$server" | cut -d: -f1)
if [ -z "$shim_def_line" ] || [ -z "$shim_call_lines" ]; then
    printf '%s\n' 'error-contract: install_jq_line_ending_shim definition or call sites vanished (the static ordering lock below would be vacuous)' >&2
    failures=$((failures + 1))
else
    for line in $shim_call_lines; do
        if [ "$line" -lt "$shim_def_line" ]; then
            printf 'error-contract: install_jq_line_ending_shim is called at line %s before its definition at line %s; the Windows dispatch exits 127 there (measured on the test VM, 2026-10-14)\n' "$line" "$shim_def_line" >&2
            failures=$((failures + 1))
        fi
    done
fi

# --- a raw subprocess diagnostic may not reach the server's stderr ---------
# `pueue group --json` that exits 0 with NON-JSON on stdout is not exotic: the
# generic stub in this file answers exactly that (`pueue 4.0.4`), so the shape
# is reachable in the harness.  Until 2026-11-05 the `jq` calls that validate
# that output redirected only stdout, so jq's own diagnostic landed verbatim on
# the server's stderr:
#   jq: parse error: Invalid numeric literal at line 1, column 6
# The server's stderr is a controlled channel -- `agentq-server: ...` plus
# `reason=<class>` -- and a bare jq line names neither the cause nor the fix,
# which is the same "diagnostic points at the wrong thing" class this file was
# built for.  The stub below also answers `status --json`, so `ensure_daemon`
# returns immediately and nothing here can start a service.
cases=$((cases + 1))
cp "$work/pueue" "$work/pueue.json-backup"
cat > "$work/pueue" <<'STUB'
#!/bin/sh
case "$*" in
    *"group --json"*) printf 'pueue 4.0.4\n' ;;
    *"status --json"*) printf '{"tasks":{},"groups":{}}\n' ;;
    *) exit 0 ;;
esac
STUB
chmod 700 "$work/pueue"
json_leak_status=0
"$server" status >"$work/jq-leak.stdout" 2>"$work/jq-leak.stderr" || json_leak_status=$?
mv "$work/pueue.json-backup" "$work/pueue"
if [ "$json_leak_status" -ne 2 ]; then
    printf 'jq-stderr-leak: a non-JSON `group --json` exited %s, expected the controlled 2\n' \
        "$json_leak_status" >&2
    failures=$((failures + 1))
elif ! grep -qF 'AgentQ group is missing or has unexpected parallelism: agentq' "$work/jq-leak.stderr"; then
    printf 'jq-stderr-leak: the refusal did not name the group: %s\n' \
        "$(head -2 "$work/jq-leak.stderr" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if grep -qE '^jq: ' "$work/jq-leak.stderr"; then
    printf 'jq-stderr-leak: a raw jq diagnostic reached the server stderr: %s\n' \
        "$(grep -E '^jq: ' "$work/jq-leak.stderr" | head -1)" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'error-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'error-contract checks passed: cases=%s commands=%s runtime=synthetic reasons=asserted reason-sites=%s return2-sites=%s reason-gaps=%s\n' \
    "$cases" \
    "$(printf '%s\n' $documented_commands | wc -l | tr -d ' ')" \
    "$reason_sites" "$return2_sites" "$reason_gap_count"
printf 'error-contract return-2 audit: bare-functions=%s\n' "$return2_bare_funcs" >&2
