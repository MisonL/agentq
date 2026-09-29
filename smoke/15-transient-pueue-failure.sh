#!/usr/bin/env bash
# Smoke: a transient Pueue read failure must never be mistaken for "the task is
# gone".
#
# This is the regression lock for a P0 defect found by an external review
# (2026-09-24).  `find_request_task` reports "cannot inspect Pueue" by calling
# `fail`, which is `exit 2`; but every one of its call sites used the shape
# `if task=$(find_request_task ...)`, and `exit` inside `$( )` terminates only
# the subshell.  The caller therefore saw an EMPTY string and a FALSE condition,
# concluded the task did not exist, and archived a LIVE request as `removed`:
# the active request record was deleted, a tombstone was written, and the task
# kept running.  The state was permanent -- `lookup` returned 5 forever, the
# task lost all `agentq` metadata, and the request id could never be reused.
#
# No existing check could catch it: they all assert exit codes for STABLE
# conditions and never for a Pueue read that fails mid-operation.  So this check
# injects exactly one failure, at exactly the reconcile call, and asserts the
# side effects that must NOT happen.
#
# Runs against a throwaway runtime under /tmp.  Nothing outside $work is touched.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'transient-pueue-failure: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

# Not TMPDIR: pueued binds a unix socket in here and macOS fails the bind once
# the path exceeds SUN_LEN, and $TMPDIR is /var/folders/<long hash>/T/.
work=$(mktemp -d /tmp/agentq-smoke-transient.XXXXXX)
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

# The server runs pueue through `env -i`, so the control channel has to be a
# file.  status.target names the Nth `status --json` call to fail: call 1 is the
# daemon probe inside ensure_daemon, call 2 is the one inside reconcile.  Failing
# call 1 instead would make the server believe the daemon is down and reach for
# launchctl -- a real service change.
cat > "$home/pueue" <<'WRAPPER'
#!/bin/sh
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

if [ "$subcommand" = status ]; then
    target=$(cat "$control/status.target" 2>/dev/null || printf '0')
    if [ "$target" -gt 0 ]; then
        count=$(cat "$control/status.count" 2>/dev/null || printf '0')
        count=$((count + 1))
        printf '%s\n' "$count" > "$control/status.count"
        if [ "$count" -eq "$target" ]; then
            printf 'transient-pueue-failure: simulated failure for pueue status (call %s)\n' "$count" >&2
            exit 1
        fi
    fi
fi

exec "$real" "$@"
WRAPPER
chmod 700 "$home/pueue"
printf '0\n' > "$control/status.target"
printf '0\n' > "$control/status.count"

# Absolute paths: run_pueue uses `env -i HOME="$HOME"`, so '~' would expand
# against the real home directory.
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

# Start the daemon up front: with none running, ensure_daemon falls through to
# launchctl on macOS, which is a service change against the real launchd domain.
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
requests="$home/data/agentq-requests"
tombstones="$home/data/agentq-requests/.tombstones"

failures=0
note() { printf '  %s\n' "$1" >&2; }

record_count() { find "$requests" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
tombstone_count() { find "$tombstones" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

request_id="smoke-transient-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
request_id=${request_id:0:120}

# A long-running task, so it is unambiguously still live when the read fails.
if ! submit_output=$("$server" submit --workdir "$workdir" --label transient \
        --request-id "$request_id" -- sh -c 'sleep 60'); then
    printf '%s\n' 'submit failed' >&2
    exit 1
fi
task_id=$(jq -er '.task_id' <<<"$submit_output") || {
    printf 'submit returned no task_id: %s\n' "$submit_output" >&2
    exit 1
}
sleep 2

records_before=$(record_count)
tombstones_before=$(tombstone_count)

# Fail the reconcile call, and only that one.
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
lookup_status=0
lookup_output=$("$server" lookup "$request_id" 2>"$work/lookup.stderr") || lookup_status=$?
printf '0\n' > "$control/status.target"

# 1. The failure must be REPORTED, not silently converted into a data verdict.
if [ "$lookup_status" -ne 2 ]; then
    note "lookup returned $lookup_status after a transient Pueue failure; expected 2"
    failures=$((failures + 1))
fi
if ! grep -q 'cannot inspect Pueue' "$work/lookup.stderr"; then
    note 'lookup did not report that Pueue could not be inspected'
    failures=$((failures + 1))
fi
if ! grep -qx 'agentq-server: reason=protocol_error' "$work/lookup.stderr"; then
    note 'lookup did not carry reason=protocol_error'
    failures=$((failures + 1))
fi

# 2. The live request must NOT have been archived.  This is the defect: the
#    record was deleted and a tombstone written while the task kept running.
if [ "$(record_count)" != "$records_before" ]; then
    note "a live request was archived during a transient failure (records $records_before -> $(record_count))"
    failures=$((failures + 1))
fi
if [ "$(tombstone_count)" != "$tombstones_before" ]; then
    note "a tombstone was written for a live request during a transient failure"
    failures=$((failures + 1))
fi

# 3. And it must not be reported as removed -- that is the caller-visible lie.
if grep -q '"state":"removed"' <<<"$lookup_output"; then
    note "lookup reported a live request as removed: $lookup_output"
    failures=$((failures + 1))
fi

# 4. Once Pueue answers again, the request must be intact and resolvable.
recovered=0
lookup_after=$("$server" lookup "$request_id" 2>/dev/null) || recovered=$?
if [ "$recovered" -ne 0 ]; then
    note "lookup did not recover after the transient failure (exit $recovered)"
    failures=$((failures + 1))
elif [ "$(jq -r '.task_id' <<<"$lookup_after")" != "$task_id" ]; then
    note "lookup returned a different task after recovery: $lookup_after"
    failures=$((failures + 1))
fi

# 5. The task itself must still be visible and still running.
if ! task_state=$("$server" status 2>/dev/null | jq -r --argjson id "$task_id" \
        '.tasks[($id|tostring)].status | keys[0]'); then
    note 'could not read the task state after recovery'
    failures=$((failures + 1))
elif [ "$task_state" != "Running" ] && [ "$task_state" != "Queued" ]; then
    note "the task did not survive the transient failure: state=$task_state"
    failures=$((failures + 1))
fi

"$server" remove "$task_id" >/dev/null 2>&1 || true

if [ "$failures" -ne 0 ]; then
    printf 'transient-pueue-failure: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'transient-pueue-failure checks passed: exit=2/reason live-request-preserved=yes tombstones=0 recovery=ok task=survived\n'
