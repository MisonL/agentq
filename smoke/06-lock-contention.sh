#!/usr/bin/env bash
# Smoke: the operation lock under concurrency.
#
# The server serialises queue-mutating operations behind an exclusive lock.  A
# caller that cannot take it is NOT failed immediately: it retries
# lock_acquire_attempts x lock_retry_delay_seconds and only then prints
# "AgentQ operation is already in progress" and exits 2 -- the same code as a
# protocol/argument error, which the client does not distinguish.  That makes
# two things worth pinning down, because both are documented claims with real
# consequences for a caller:
#
#   1. the rejected call is REJECTED, not silently dropped: exit 2, the message
#      on stderr, and zero side effects (no request record, no task);
#   2. retrying with the SAME request id afterwards SUCCEEDS and creates exactly
#      one task -- the retry the documentation tells callers to make.
#
# The contention is made deterministic instead of racy: the wrapper around
# pueue blocks inside `add`, which the server calls while holding the lock, so
# the holder's lock is guaranteed to be held when the contender starts.
#
# This runs against a throwaway runtime built under $work.  Nothing outside
# $work is touched.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'lock-contention: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

# Deliberately not TMPDIR: pueued binds a unix socket here and macOS fails the
# bind once the path gets long ($TMPDIR is /var/folders/<long hash>/T/).
work=$(mktemp -d /tmp/agentq-smoke-lock.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
case "$work" in
    /private/var/folders/*)
        printf '%s\n' 'refusing to run: the work directory is too long for a unix socket' >&2
        exit 2
        ;;
esac
daemon_pid=''
cleanup() {
    if [ -n "$daemon_pid" ]; then
        kill "$daemon_pid" >/dev/null 2>&1 || true
        wait "$daemon_pid" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT

home="$work/home"
mkdir -p "$home/config" "$home/data/task_logs" "$home/data/agentq-cancellations" \
    "$home/data/agentq-requests/.locks" "$home/data/agentq-requests/.tombstones" \
    "$home/runtime" "$work/control"
control="$work/control"

cp "$source_home/pueue" "$home/pueue.real"
cp "$source_home/pueued" "$home/pueued"
cp "$source_home/agentq-server" "$home/agentq-server"
chmod 700 "$home/pueue.real" "$home/pueued" "$home/agentq-server"

cat > "$home/config/pueue.yml" <<YAML
shared:
  pueue_directory: '$home/data'
  runtime_directory: '$home/runtime'
  use_unix_socket: true
  unix_socket_permissions: 448
  pid_path: '$home/runtime/pueued.pid'
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
YAML
chmod 600 "$home/config/pueue.yml"

# The server calls pueue through `env -i`, so control cannot travel as an
# environment variable -- a file the wrapper reads is the only way in.
cat > "$home/pueue" <<'WRAPPER'
#!/bin/sh
# Delegate to the real pueue, except: when control/add.block exists, an `add`
# call signals that it is inside the lock and then waits for it to be released.
here=$(CDPATH=; cd -- "$(dirname -- "$0")" && pwd -P)
control="$here/../control"
real="$here/pueue.real"
[ -d "$control" ] || exit 1

subcommand=''
expect_value=0
for argument in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$argument" in
        --config) expect_value=1 ;;
        -*) ;;
        *) subcommand=$argument; break ;;
    esac
done

if [ "$subcommand" = add ] && [ -e "$control/add.block" ]; then
    : > "$control/add.entered"
    while [ -e "$control/add.block" ]; do
        sleep 0.2
    done
fi

exec "$real" "$@"
WRAPPER
chmod 700 "$home/pueue"

# Start pueued BEFORE anything calls the server.  The server's ensure_daemon
# falls through to `launchctl kickstart gui/<uid>/com.agentq.pueued` when it
# believes the daemon is down -- a service change against the real launchd
# domain.  With the daemon already up, the first `status --json` succeeds and
# that path is never reached.
"$home/pueued" --config "$home/config/pueue.yml" >"$work/pueued.log" 2>&1 &
daemon_pid=$!
daemon_ready=0
for _ in $(seq 1 60); do
    if "$home/pueue.real" --config "$home/config/pueue.yml" status --json >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 0.5
done
if [ "$daemon_ready" -ne 1 ]; then
    printf '%s\n' 'the throwaway pueued did not become ready' >&2
    exit 1
fi

server="$home/agentq-server"
workdir="$work/wd"
mkdir -p "$workdir"
request_record_directory="$home/data/agentq-requests"

active_records() {
    [ -d "$request_record_directory" ] || return 0
    jq -s --argjson id "$1" '[.[] | select(.task_id == $id)] | length' \
        "$request_record_directory"/*.json 2>/dev/null || printf '0\n'
}

# ---------------------------------------------------------------------------
# 1. Hold the lock, then start a contender while the lock is provably held.
# ---------------------------------------------------------------------------
holder_request_id="lockholder-$$-aaaaaaaa"
contender_request_id="lockcontend-$$-aaaaaaa"

: > "$control/add.block"
"$server" submit --workdir "$workdir" --label holder \
    --request-id "$holder_request_id" -- true >"$work/holder.out" 2>"$work/holder.err" &
holder_shell_pid=$!

# Wait until the holder is actually inside `add`, i.e. holding the lock.
holder_inside=0
for _ in $(seq 1 100); do
    if [ -e "$control/add.entered" ]; then
        holder_inside=1
        break
    fi
    sleep 0.2
done
if [ "$holder_inside" -ne 1 ]; then
    printf '%s\n' 'the lock holder never reached the pueue call' >&2
    : > "$control/add.block" 2>/dev/null || true
    rm -f "$control/add.block" 2>/dev/null || true
    wait "$holder_shell_pid" >/dev/null 2>&1 || true
    exit 1
fi

# The contender must fail while the lock is held.  It retries for
# lock_acquire_attempts x lock_retry_delay_seconds, so give it time to exhaust
# that budget rather than guessing: poll for the holder's block to be released
# only after the contender has exited.
contender_status=0
"$server" submit --workdir "$workdir" --label contender \
    --request-id "$contender_request_id" -- true >"$work/contender.out" 2>"$work/contender.err" &
contender_shell_pid=$!

# Release the lock only after the contender has been given its full retry
# window.  Read the budget from the server itself so this check keeps working
# if the constants change.
# `|| true` so a renamed constant leaves the variables empty and the fallback
# below actually runs; without it pipefail aborted the script before the case
# (measured 2026-10-06: renaming the constant made this check exit 1 with no
# output at all, and the designed fallback was unreachable).
attempts=$(grep -m1 '^lock_acquire_attempts=' "$server" | cut -d= -f2) || true
delay=$(grep -m1 '^lock_retry_delay_seconds=' "$server" | cut -d= -f2) || true
case "$attempts" in ''|*[!0-9]*) attempts=30 ;; esac
case "$delay" in ''|*[!0-9]*) delay=1 ;; esac
budget=$((attempts * delay))

waited=0
while [ "$waited" -lt $((budget + 15)) ]; do
    if ! kill -0 "$contender_shell_pid" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

# The contender must have finished BY FAILING while the lock was still held.
if kill -0 "$contender_shell_pid" 2>/dev/null; then
    printf 'the contender was still running after %ss with the lock held\n' "$waited" >&2
    rm -f "$control/add.block"
    wait "$contender_shell_pid" >/dev/null 2>&1 || true
    wait "$holder_shell_pid" >/dev/null 2>&1 || true
    exit 1
fi
wait "$contender_shell_pid" 2>/dev/null && contender_status=0 || contender_status=$?

# Now let the holder finish.
rm -f "$control/add.block"
holder_wait_status=0
wait "$holder_shell_pid" 2>/dev/null || holder_wait_status=$?

if [ "$holder_wait_status" -ne 0 ]; then
    printf 'the lock holder failed (%s): %s\n' "$holder_wait_status" \
        "$(head -1 "$work/holder.err")" >&2
    exit 1
fi

if [ "$contender_status" -ne 2 ]; then
    printf 'a lock-rejected submit exited %s, expected 2: %s\n' \
        "$contender_status" "$(head -1 "$work/contender.err")" >&2
    exit 1
fi
grep -q 'already in progress' "$work/contender.err" || {
    printf 'a lock-rejected submit did not report "already in progress": %s\n' \
        "$(head -1 "$work/contender.err")" >&2
    exit 1
}
# The machine-readable class is what makes this 2 distinguishable from a real
# argument error without matching the message text.  A lock rejection is
# retryable with the same request ID; a protocol error is not.  Getting this
# class wrong would make a caller retry an argument error forever.
grep -qxF -- "agentq-server: reason=lock_contention" "$work/contender.err" || {
    printf 'a lock-rejected submit did not carry reason=lock_contention: %s\n' \
        "$(head -3 "$work/contender.err" | tr '\n' '|')" >&2
    exit 1
}
grep -q "^${server##*/}: " "$work/contender.err" || {
    printf 'the lock message did not carry the program prefix: %s\n' \
        "$(head -1 "$work/contender.err")" >&2
    exit 1
}

# The rejection must have done nothing: no task, and no request record.
contender_task_id=$(jq -r '.task_id // empty' "$work/contender.out" 2>/dev/null || printf '')
if [ -n "$contender_task_id" ]; then
    printf 'a rejected submit produced a task id: %s\n' "$contender_task_id" >&2
    exit 1
fi
if [ -f "$request_record_directory/$contender_request_id.json" ]; then
    printf 'a rejected submit left a request record behind\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Retry the rejected call with the SAME request id.  It must succeed and
#    produce exactly one task -- this is the documented recovery.
# ---------------------------------------------------------------------------
retry_status=0
retry_output=$("$server" submit --workdir "$workdir" --label contender \
    --request-id "$contender_request_id" -- true 2>"$work/retry.err") || retry_status=$?
if [ "$retry_status" -ne 0 ]; then
    printf 'retrying a lock-rejected submit with the same request id exited %s: %s\n' \
        "$retry_status" "$(head -1 "$work/retry.err")" >&2
    exit 1
fi
retry_task_id=$(jq -er '.task_id' <<<"$retry_output") || {
    printf 'the retry returned no task id: %s\n' "$retry_output" >&2
    exit 1
}
[ "$(active_records "$retry_task_id")" = 1 ] || {
    printf 'the retry left %s active records for task %s, expected 1\n' \
        "$(active_records "$retry_task_id")" "$retry_task_id" >&2
    exit 1
}

# A second submit with the same request id must be idempotent, not a duplicate.
repeat_status=0
repeat_output=$("$server" submit --workdir "$workdir" --label contender \
    --request-id "$contender_request_id" -- true 2>"$work/repeat.err") || repeat_status=$?
if [ "$repeat_status" -ne 0 ]; then
    printf 'resubmitting the same request id exited %s: %s\n' \
        "$repeat_status" "$(head -1 "$work/repeat.err")" >&2
    exit 1
fi
[ "$(jq -r '.task_id' <<<"$repeat_output")" = "$retry_task_id" ] || {
    printf 'resubmitting the same request id created a second task: %s vs %s\n' \
        "$(jq -r '.task_id' <<<"$repeat_output")" "$retry_task_id" >&2
    exit 1
}
jq -e '.reused == true' <<<"$repeat_output" >/dev/null || {
    printf 'resubmitting the same request id did not report reused: %s\n' \
        "$repeat_output" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 3. The operation lock must be released, not left behind.
# ---------------------------------------------------------------------------
lock_directory="$home/runtime/agentq-operation.lock"
if [ -e "$lock_directory" ]; then
    printf 'the operation lock was left behind: %s\n' "$lock_directory" >&2
    exit 1
fi

printf 'lock-contention checks passed: rejected=2/lock_contention/no-side-effects retry=ok reused=ok lock=released\n'
