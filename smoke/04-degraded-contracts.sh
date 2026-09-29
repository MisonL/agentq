#!/usr/bin/env bash
# Smoke: the two contracts a caller is most likely to get wrong, both of which
# only appear when Pueue cannot answer.  Neither is reachable by normal means:
# the runtime has to be made to fail on purpose.
#
#   wait  -> exit 6 / {"state":"unavailable"}   when the final state is unknown
#   cancel-> exit 4 / {"state":"cancellation_pending"}  when the cancel intent
#            is persisted but Pueue did not confirm it
#
# Both are "stop and re-read" outcomes.  Neither is a completion, and neither
# may be retried automatically -- so both must be distinguishable from success,
# from a plain failure, and from each other.
#
# This runs against a throwaway runtime built under $work, driven through a
# wrapper around the real pueue binary.  Nothing outside $work is touched.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'degraded-contracts: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

# Deliberately not TMPDIR: pueued binds a unix socket inside this directory and
# macOS fails the bind with "path must be shorter than SUN_LEN" once the path
# gets long -- and $TMPDIR on macOS is /var/folders/<long hash>/T/.  /tmp is
# short enough on every platform this check runs on.
work=$(mktemp -d /tmp/agentq-smoke-degraded.XXXXXX)
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

# The server invokes pueue through `env -i`, so a control flag cannot travel as
# an environment variable.  A file the wrapper reads is the only way in.
cat > "$home/pueue" <<'WRAPPER'
#!/bin/sh
# Delegate to the real pueue, except when the control files say otherwise.
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

# fail.list: subcommands to fail outright.
if [ -f "$control/fail.list" ] && grep -qx -- "$subcommand" "$control/fail.list" 2>/dev/null; then
    printf 'degraded-contracts: simulated failure for pueue %s\n' "$subcommand" >&2
    exit 1
fi

# status.target: fail only the Nth status call, so the daemon probe that runs
# before it still succeeds.  Without this the server would try to restart a
# daemon it believes is down -- which on macOS means launchctl.
target=$(cat "$control/status.target" 2>/dev/null || printf '0')
if [ "$subcommand" = status ] && [ "$target" -gt 0 ]; then
    count=$(cat "$control/status.count" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$control/status.count"
    if [ "$count" -eq "$target" ]; then
        printf 'degraded-contracts: simulated failure for pueue status (call %s)\n' "$count" >&2
        exit 1
    fi
fi

exec "$real" "$@"
WRAPPER
chmod 700 "$home/pueue"
printf '0\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
: > "$control/fail.list"

# Absolute paths: run_pueue runs with `env -i HOME="$HOME"`, so a literal '~'
# in the config would expand against the real home directory.
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

# Start the daemon up front.  If it were absent, the server's ensure_daemon
# would fall through to launchctl on macOS -- a service change against the real
# launchd domain, which this check must never cause.
# No -d: that flag forks and the parent exits immediately, so $! would name a
# process that is already gone and the trap could not stop the real daemon.
"$home/pueued" --config "$home/config/pueue.yml" >/dev/null 2>&1 &
daemon_pid=$!
ready=0
for _ in $(seq 1 60); do
    if "$home/pueue.real" --config "$home/config/pueue.yml" status --json >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    printf '%s\n' 'the throwaway pueued did not become reachable' >&2
    exit 1
fi

server="$home/agentq-server"
workdir="$work/workdir"
mkdir -p "$workdir"

failures=0
note() { printf '  %s\n' "$1" >&2; }

submit() {
    local label=$1 request_id=$2
    shift 2
    local output
    output=$("$server" submit --workdir "$workdir" --label "$label" \
        --request-id "$request_id" -- "$@") || return 1
    jq -er '.task_id' <<<"$output"
}

# Remove a task from Pueue without going through the server, so no tombstone is
# written and the server has to fall back to asking Pueue for the final state.
forget_in_pueue() {
    local task_id=$1
    "$home/pueue.real" --config "$home/config/pueue.yml" kill "$task_id" >/dev/null 2>&1 || true
    sleep 1
    "$home/pueue.real" --config "$home/config/pueue.yml" remove "$task_id" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 1. wait -> exit 6 when the final state cannot be determined.
#
#    The task must be gone from Pueue while an accepted request record still
#    exists, and the status call the server makes to reconcile must fail.  The
#    status call is the third one in this flow: the daemon probe, then
#    compact_task, then the reconcile.
# ---------------------------------------------------------------------------
task_id=$(submit unavailable "smoke-degraded-unavailable-$$" sleep 900) || {
    printf '%s\n' 'submit for the unavailable case failed' >&2
    exit 1
}
forget_in_pueue "$task_id"
printf '3\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
status=0
output=$("$server" wait "$task_id" 2>"$work/unavailable.stderr") || status=$?
printf '0\n' > "$control/status.target"
if [ "$status" -ne 6 ]; then
    note "wait exit=$status, expected 6: $(cat "$work/unavailable.stderr")"
    failures=$((failures + 1))
elif ! jq -e '.state == "unavailable"' <<<"$output" >/dev/null 2>&1; then
    note "wait did not report state unavailable: $output"
    failures=$((failures + 1))
elif ! jq -e '.task_id' <<<"$output" >/dev/null 2>&1; then
    note "wait did not report a task_id: $output"
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# 2. cancel -> exit 4 when the cancel intent is persisted but unconfirmed.
#
#    The task must be running so the server takes the kill path, and that kill
#    must fail.  The marker is written before the attempt, so the outcome is
#    recorded even though Pueue never confirmed it.
# ---------------------------------------------------------------------------
task_id=$(submit pending "smoke-degraded-pending-$$" sleep 900) || {
    printf '%s\n' 'submit for the pending case failed' >&2
    exit 1
}
sleep 2
printf 'kill\n' > "$control/fail.list"
status=0
output=$("$server" cancel "$task_id" 2>"$work/pending.stderr") || status=$?
: > "$control/fail.list"
if [ "$status" -ne 4 ]; then
    note "cancel exit=$status, expected 4: $(cat "$work/pending.stderr")"
    failures=$((failures + 1))
elif ! jq -e '.state == "cancellation_pending"' <<<"$output" >/dev/null 2>&1; then
    note "cancel did not report cancellation_pending: $output"
    failures=$((failures + 1))
elif ! jq -e '.cancellation_requested_at' <<<"$output" >/dev/null 2>&1; then
    note "cancel did not report cancellation_requested_at: $output"
    failures=$((failures + 1))
fi

# The pending outcome must be visible to a later reader, so a caller who lost
# the response can still find out what happened.
if ! "$server" status 2>/dev/null \
    | jq -e --argjson id "$task_id" '.tasks[($id|tostring)].agentq.cancellation_pending_at' >/dev/null 2>&1; then
    note "status did not surface cancellation_pending_at for task $task_id"
    failures=$((failures + 1))
fi

# A second explicit cancel, with Pueue healthy again, must confirm the outcome.
if ! "$server" cancel "$task_id" >/dev/null 2>&1; then
    note "the follow-up cancel did not succeed"
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Neither degraded outcome may ever be reported as a completed task.
# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
    printf 'degraded-contracts: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'degraded-contracts checks passed: wait=6/unavailable cancel=4/cancellation_pending\n'
