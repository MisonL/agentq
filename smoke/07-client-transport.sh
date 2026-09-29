#!/usr/bin/env bash
# Smoke: the POSIX client talking to the server over a REAL ssh transport.
#
# Every other check here either drives the server directly or gives the client a
# stub `ssh` (05).  Neither proves the thing the client exists for: turning a
# remote invocation into the right exit code and the right JSON on stdout.  A
# stub cannot get that wrong, so 05 passes even if the client mangles exit-code
# propagation, the response-loss reconcile, or the platform probe.
#
# This runs the real `ssh` binary against a throwaway sshd on 127.0.0.1:
#
#   - a user-level sshd with a FRESH host key, on a high port, listening only on
#     loopback.  It never touches /etc/ssh, the real authorized_keys, or the
#     system sshd, and needs no sudo.
#   - the remote "host" is this machine, with HOME redirected into the sandbox
#     via `environment="HOME=..."` in the sandbox authorized_keys, so the
#     client's hardcoded $HOME/.local/bin/agentq lands in the sandbox and the
#     real ~/.agentq and ~/.local/bin are never read or written.
#
# What it pins down: exit codes 0/1/2/3/5 crossing the transport intact, the
# not_started crash-recovery state, and that a failed task is never reported as
# success.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}
# Resolved from the script's own location, not hard-coded: a checkout in a
# different directory must still find the client under test.
# Named repo_root, not root: this script reuses `root` further down for the
# sandbox's remote home, and shadowing it here would silently break any
# later use of the repository path.
repo_root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$repo_root/skill/assets/client/unix/agentq"
client=${AGENTQ_SMOKE_CLIENT:-$client}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'client-transport: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi
if [ ! -x /usr/sbin/sshd ]; then
    printf '%s\n' 'client-transport: SKIPPED (no /usr/sbin/sshd)'
    exit 0
fi
if [ ! -x "$client" ]; then
    printf 'client-transport: client not found: %s\n' "$client" >&2
    exit 2
fi
for command_name in jq ssh-keygen ssh; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

# Deliberately not TMPDIR: pueued binds a unix socket here and macOS fails the
# bind once the path gets long ($TMPDIR is /var/folders/<long hash>/T/).
work=$(mktemp -d /tmp/agentq-smoke-transport.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
case "$work" in
    /private/var/folders/*)
        printf '%s\n' 'refusing to run: the work directory is too long for a unix socket' >&2
        exit 2
        ;;
esac

sshd_pid=''
pueued_pid=''
cleanup() {
    [ -n "$sshd_pid" ] && kill "$sshd_pid" >/dev/null 2>&1 || true
    [ -n "$pueued_pid" ] && kill "$pueued_pid" >/dev/null 2>&1 || true
    [ -n "$sshd_pid" ] && wait "$sshd_pid" >/dev/null 2>&1 || true
    [ -n "$pueued_pid" ] && wait "$pueued_pid" >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT

# --- sandbox sshd ---------------------------------------------------------
ssh_dir="$work/ssh"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/hostkey" -C agentq-smoke-hostkey
ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/id" -C agentq-smoke-client

# The remote home the client will be redirected into.
remote_home="$work/remote"
mkdir -p "$remote_home/.local/bin"
chmod 700 "$remote_home"
cp "$source_home/agentq-server" "$remote_home/.local/bin/agentq"
cp "$source_home/pueue" "$remote_home/.local/bin/pueue"
cp "$source_home/pueued" "$remote_home/.local/bin/pueued"
chmod 700 "$remote_home/.local/bin/agentq" "$remote_home/.local/bin/pueue" "$remote_home/.local/bin/pueued"
mkdir -p "$remote_home/.local/bin/config" \
    "$remote_home/.local/bin/data/task_logs" \
    "$remote_home/.local/bin/data/agentq-cancellations" \
    "$remote_home/.local/bin/data/agentq-requests/.locks" \
    "$remote_home/.local/bin/data/agentq-requests/.tombstones" \
    "$remote_home/.local/bin/runtime"
root="$remote_home/.local/bin"
cat > "$root/config/pueue.yml" <<YAML
shared:
  pueue_directory: '$root/data'
  runtime_directory: '$root/runtime'
  use_unix_socket: true
  unix_socket_permissions: 448
  pid_path: '$root/runtime/pueued.pid'
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
chmod 600 "$root/config/pueue.yml"

cat > "$ssh_dir/authorized_keys" <<EOF
environment="HOME=$remote_home" $(cat "$ssh_dir/id.pub")
EOF
chmod 600 "$ssh_dir/authorized_keys"

cat > "$ssh_dir/sshd_config" <<EOF
ListenAddress 127.0.0.1
HostKey $ssh_dir/hostkey
PidFile $ssh_dir/sshd.pid
AuthorizedKeysFile $ssh_dir/authorized_keys
PermitUserEnvironment yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
StrictModes no
LogLevel ERROR
EOF

# Start sshd, retrying with another port if the bind fails.  `sshd -t` only
# validates syntax, so the bind is the real test.
port=''
for _ in $(seq 1 25); do
    candidate=$(( 20000 + (RANDOM % 30000) ))
    if /usr/sbin/sshd -f "$ssh_dir/sshd_config" -p "$candidate" 2>"$work/sshd.err"; then
        port=$candidate
        break
    fi
    sleep 0.2
done
if [ -z "$port" ]; then
    printf 'client-transport: the sandbox sshd could not bind a port: %s\n' \
        "$(head -1 "$work/sshd.err")" >&2
    exit 1
fi
sshd_pid=$(cat "$ssh_dir/sshd.pid" 2>/dev/null || printf '')
[ -n "$sshd_pid" ] || { printf '%s\n' 'the sandbox sshd wrote no pid file' >&2; exit 1; }

# A pass-through ssh: the real binary with only the sandbox port, key and
# known_hosts added.  Options, -E logging and exit codes stay real.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<EOF
#!/bin/sh
exec /usr/bin/ssh -p $port -i "$ssh_dir/id" \\
    -o UserKnownHostsFile="$ssh_dir/known_hosts" \\
    -o StrictHostKeyChecking=no "\$@"
EOF
chmod 700 "$work/bin/ssh"

# --- sandbox daemon -------------------------------------------------------
# Start pueued before anything invokes the server: its ensure_daemon falls
# through to launchctl kickstart against the real launchd domain on macOS when
# it believes the daemon is down.
"$root/pueued" --config "$root/config/pueue.yml" >"$work/pueued.log" 2>&1 &
pueued_pid=$!
daemon_ready=0
for _ in $(seq 1 60); do
    if "$root/pueue" --config "$root/config/pueue.yml" status --json >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 0.5
done
if [ "$daemon_ready" -ne 1 ]; then
    printf '%s\n' 'the sandbox pueued did not become ready' >&2
    exit 1
fi

# The client resolves its ssh client from AGENTQ_SSH when set, which is cleaner
# than rewriting PATH.
export AGENTQ_SSH="$work/bin/ssh"
export AGENTQ_PLATFORM_PROBE_TIMEOUT=30

run_client() {
    "$client" --host 127.0.0.1 "$@"
}

workdir="$work/wd"
mkdir -p "$workdir"

# --- 1. submit over the real transport ------------------------------------
request_id="transport-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
submit_status=0
submit_out=$(run_client submit --workdir "$workdir" --label transport \
    --request-id "$request_id" -- sh -c 'printf transport-ok' 2>"$work/submit.err") || submit_status=$?
if [ "$submit_status" -ne 0 ]; then
    printf 'submit over ssh exited %s: %s\n' "$submit_status" "$(head -1 "$work/submit.err")" >&2
    exit 1
fi
task_id=$(jq -er '.task_id' <<<"$submit_out") || {
    printf 'submit over ssh returned no task_id: %s\n' "$submit_out" >&2
    exit 1
}

# --- 2. wait: a successful task ------------------------------------------
wait_status=0
wait_out=$(run_client wait "$task_id" 2>"$work/wait.err") || wait_status=$?
if [ "$wait_status" -ne 0 ]; then
    printf 'wait over ssh exited %s for a successful task: %s\n' \
        "$wait_status" "$(head -1 "$work/wait.err")" >&2
    exit 1
fi
jq -e '.task.status.Done.result == "Success"' <<<"$wait_out" >/dev/null || {
    printf 'wait over ssh did not report Success: %s\n' "$(head -c 200 <<<"$wait_out")" >&2
    exit 1
}

# --- 3. exit code 1: a failing task must not be reported as success -------
fail_request_id="${request_id}-fail"
fail_submit=$(run_client submit --workdir "$workdir" --label transport-fail \
    --request-id "$fail_request_id" -- sh -c 'exit 7' 2>/dev/null) || {
    printf '%s\n' 'submit of the failing task over ssh failed' >&2
    exit 1
}
fail_task_id=$(jq -er '.task_id' <<<"$fail_submit")
fail_wait_status=0
fail_wait_out=$(run_client wait "$fail_task_id" 2>/dev/null) || fail_wait_status=$?
if [ "$fail_wait_status" -eq 0 ]; then
    printf 'wait over ssh exited 0 for a task that exited non-zero: %s\n' \
        "$(head -c 200 <<<"$fail_wait_out")" >&2
    exit 1
fi
if jq -e '.task.status.Done.result == "Success"' <<<"$fail_wait_out" >/dev/null 2>&1; then
    printf 'wait over ssh reported Success for a failing task: %s\n' \
        "$(head -c 200 <<<"$fail_wait_out")" >&2
    exit 1
fi

# --- 4. exit code 3: lookup of an unknown request id ----------------------
lookup_status=0
lookup_out=$(run_client lookup "${request_id}-absent" 2>/dev/null) || lookup_status=$?
if [ "$lookup_status" -ne 3 ]; then
    printf 'lookup over ssh exited %s, expected 3: %s\n' \
        "$lookup_status" "$(head -c 200 <<<"$lookup_out")" >&2
    exit 1
fi
jq -e '.state == "not_found"' <<<"$lookup_out" >/dev/null || {
    printf 'lookup over ssh did not report not_found: %s\n' \
        "$(head -c 200 <<<"$lookup_out")" >&2
    exit 1
}

# --- 5. exit code 2: an argument error crosses the transport --------------
arg_status=0
run_client cancel not-a-number >/dev/null 2>"$work/arg.err" || arg_status=$?
if [ "$arg_status" -ne 2 ]; then
    printf 'an argument error over ssh exited %s, expected 2\n' "$arg_status" >&2
    exit 1
fi

# --- 5b. the reason class must cross the transport too ---------------------
# The client never forwards remote stderr verbatim (it redacts it to a class and
# a byte count), so the reason line is the ONLY channel by which a caller
# driving the client can tell a retryable lock rejection from an argument
# error.  05 pins this against a stub ssh; this is the same claim measured
# through a real SSH transport.
#
# The task id here must be SYNTACTICALLY VALID, and that is the whole point of
# the case.  The obvious choice -- `cancel not-a-number`, right above -- is
# rejected by the CLIENT, locally, and never reaches the server at all; the
# first version of this case used it and failed with `agentq: task id must be a
# non-negative integer` and no reason line, which is correct client behaviour.
# An unknown-but-well-formed id passes client validation, crosses the
# transport, and comes back from the server as a protocol_error.
unknown_status=0
run_client cancel 999999 >/dev/null 2>"$work/unknown.err" || unknown_status=$?
if [ "$unknown_status" -ne 2 ]; then
    printf 'an unknown task id over ssh exited %s, expected 2\n' "$unknown_status" >&2
    exit 1
fi
if ! grep -qF 'remote failure reason: protocol_error' "$work/unknown.err"; then
    printf 'a server-side protocol error over ssh did not carry reason=protocol_error: %s\n' \
        "$(tr '\n' '|' < "$work/unknown.err")" >&2
    exit 1
fi

# --- 6. exit code 5: a cancelled queued task reports removed -------------
# Fill the slots so the next task stays Queued, then cancel it.
blockers=''
for attempt in $(seq 1 12); do
    blocker_request_id="${request_id}-blk${attempt}"
    blocker_submit=$(run_client submit --workdir "$workdir" --label transport-blk \
        --request-id "$blocker_request_id" -- sleep 120 2>/dev/null) || break
    blocker_id=$(jq -r '.task_id' <<<"$blocker_submit") || break
    [ -n "$blocker_id" ] || break
    blockers="$blockers $blocker_id"
    sleep 1
    if run_client status 2>/dev/null \
        | jq -e --argjson id "$blocker_id" \
            '.tasks[($id|tostring)].status | has("Queued")' >/dev/null 2>&1; then
        break
    fi
done

victim_request_id="${request_id}-queued"
victim_submit=$(run_client submit --workdir "$workdir" --label transport-queued \
    --request-id "$victim_request_id" -- sleep 120 2>/dev/null) || {
    printf '%s\n' 'submit of the queued victim over ssh failed' >&2
    exit 1
}
victim_id=$(jq -er '.task_id' <<<"$victim_submit")

victim_queued=0
for _ in $(seq 1 20); do
    if run_client status 2>/dev/null \
        | jq -e --argjson id "$victim_id" \
            '.tasks[($id|tostring)].status | has("Queued")' >/dev/null 2>&1; then
        victim_queued=1
        break
    fi
    sleep 0.5
done
if [ "$victim_queued" -ne 1 ]; then
    printf 'task %s never reached Queued over the transport\n' "$victim_id" >&2
    exit 1
fi

cancel_status=0
cancel_out=$(run_client cancel "$victim_id" 2>/dev/null) || cancel_status=$?
if [ "$cancel_status" -ne 0 ]; then
    printf 'cancel over ssh exited %s: %s\n' "$cancel_status" "$(head -c 200 <<<"$cancel_out")" >&2
    exit 1
fi
jq -e '.cancellation_mode == "queued_removed"' <<<"$cancel_out" >/dev/null || {
    printf 'cancel over ssh did not report queued_removed: %s\n' \
        "$(head -c 200 <<<"$cancel_out")" >&2
    exit 1
}
removed_status=0
removed_out=$(run_client wait "$victim_id" 2>/dev/null) || removed_status=$?
if [ "$removed_status" -ne 5 ]; then
    printf 'wait over ssh after queued_removed exited %s, expected 5: %s\n' \
        "$removed_status" "$(head -c 200 <<<"$removed_out")" >&2
    exit 1
fi
jq -e '.state == "removed"' <<<"$removed_out" >/dev/null || {
    printf 'wait over ssh after queued_removed did not report removed: %s\n' \
        "$(head -c 200 <<<"$removed_out")" >&2
    exit 1
}

# --- 6b. task_not_running crosses the transport on the mutation path ------
# This is the ONE exit-2 class a caller must not respond to by fixing its
# arguments, and the mutation path is where it arrives.  The client forwards it
# from the remote command's stderr, which it captures separately from ssh's own
# -E log -- measured, not assumed: OpenSSH writes the remote command's stderr to
# the local stderr and the -E file stays empty, so a client that only reads -E
# never sees this line at all.
finished_status=0
run_client cancel "$victim_id" >/dev/null 2>"$work/finished.err" || finished_status=$?
if [ "$finished_status" -ne 2 ]; then
    printf 'cancel of an already-removed task over ssh exited %s, expected 2\n' \
        "$finished_status" >&2
    exit 1
fi
if ! grep -qF 'remote failure reason: ' "$work/finished.err"; then
    printf 'a mutation-path exit 2 over ssh carried no reason class: %s\n' \
        "$(tr '\n' '|' < "$work/finished.err")" >&2
    exit 1
fi

# --- 7. exit code 3: not_started, the crash-recovery state ---------------
# A prepared record with no Pueue task is what submit leaves behind when it dies
# between persisting the record and enqueueing.  Reproduce that STATE directly
# rather than racing a kill: the state is what lookup must classify, and three
# attempts at crashing submit over the real transport all proved unreproducible
# (see the note on the wrapper above).  The record is written with the same
# shape submit writes (version/request_id/payload/task_label/state/task_id/
# task_created_at/created_at), so this exercises the real recovery path.
crash_request_id="${request_id}-crash"
crash_created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
# task_label must be exactly "agentq:" + request_id -- the record validator
# enforces it, and a mismatch is rejected as an invalid record rather than
# reaching the recovery path this case is about.
jq -cn --arg request_id "$crash_request_id" --arg workdir "$workdir" \
    --arg created_at "$crash_created" \
    '{version: 1, request_id: $request_id,
      payload: {workdir: $workdir, label: "transport-crash", argv: ["true"]},
      task_label: ("agentq:" + $request_id), state: "prepared",
      task_id: null, task_created_at: null, created_at: $created_at}' \
    > "$root/data/agentq-requests/$crash_request_id.json" || {
    printf '%s\n' 'could not plant a prepared request record' >&2
    exit 1
}
chmod 600 "$root/data/agentq-requests/$crash_request_id.json"

notstarted_status=0
notstarted_out=$(run_client lookup "$crash_request_id" 2>/dev/null) || notstarted_status=$?
if [ "$notstarted_status" -ne 3 ]; then
    printf 'lookup of a prepared record with no task exited %s, expected 3: %s\n' \
        "$notstarted_status" "$(head -c 200 <<<"$notstarted_out")" >&2
    exit 1
fi
jq -e '.state == "not_started"' <<<"$notstarted_out" >/dev/null || {
    printf 'a prepared record with no task did not report not_started: %s\n' \
        "$(head -c 200 <<<"$notstarted_out")" >&2
    exit 1
}
# And it must be repeatable: not_started is a state, not a one-shot verdict.
notstarted_again_status=0
notstarted_again=$(run_client lookup "$crash_request_id" 2>/dev/null) || notstarted_again_status=$?
if [ "$notstarted_again_status" -ne 3 ]; then
    printf 'a second lookup of a not_started record exited %s, expected 3\n' \
        "$notstarted_again_status" >&2
    exit 1
fi

# --- 8. A7: network-interruption variants over the real transport ---------
#
# These three contracts were measured once on real hosts during C1, using a
# throwaway local scaffold that was then deleted -- so the repository had no
# repeatable form of the only real evidence for them.  This section is that
# form, and it needs no remote host: the failure is injected at the ssh layer.
#
# The injection is the whole point.  It must FAKE the failure while still
# REALLY running the command, because the contract under test is "the server
# completed the work and the caller only saw a failure".  A wrapper that failed
# without running anything would leave no completed work to reconcile against,
# and the test would pass while proving nothing.
#
# Where the diagnostic goes matters and is measured, not assumed: the client's
# ssh_transport_error() reads the -E log file, and OpenSSH writes only its OWN
# diagnostics there -- a remote command's stderr lands on the local stderr
# instead (measured on macOS with a real sshd).  So a real transport failure of
# this class appears in -E, and that is where the injected line goes.  Writing
# it to stderr instead would be an invented transport model, which is exactly
# the mistake 05's first ssh stub made.
cat > "$work/bin/ssh-flaky" <<'WRAPPER'
#!/bin/sh
# Pass-through ssh that can fake a transport failure for ONE operation while
# still really running the command.  Counts calls per operation and honours a
# countdown file so a single case can fail once and then let the retry through.
set -u

log_path=''
previous=''
for argument in "$@"; do
    if [ "$previous" = '-E' ]; then
        log_path=$argument
        break
    fi
    previous=$argument
done

remote_command=''
for argument in "$@"; do
    remote_command=$argument
done
operation=$(printf '%s' "$remote_command" | sed -n "s/.*agentq_run '\([a-z]*\)'.*/\1/p")

control=${AGENTQ_FLAKY_CONTROL:-}
if [ -n "$operation" ] && [ -n "$control" ] && [ -d "$control" ]; then
    printf '%s\n' "$operation" >> "$control/calls.$operation"
    remaining=$(cat "$control/fail.$operation" 2>/dev/null || printf '0')
    case "$remaining" in
        ''|*[!0-9]*) remaining=0 ;;
    esac
    if [ "$remaining" -gt 0 ]; then
        printf '%s\n' "$((remaining - 1))" > "$control/fail.$operation"
        "$AGENTQ_FLAKY_PASSTHROUGH" "$@"
        # The command really ran.  Now pretend the connection died before the
        # response made it back -- the shape the reconcile logic exists for.
        [ -n "$log_path" ] && printf '%s\n' \
            'ssh: connect to host 127.0.0.1 port 22: Connection reset by peer' > "$log_path"
        exit 255
    fi
fi

exec "$AGENTQ_FLAKY_PASSTHROUGH" "$@"
WRAPPER
chmod 700 "$work/bin/ssh-flaky"

flaky_control="$work/control"
mkdir -p "$flaky_control"
export AGENTQ_FLAKY_CONTROL="$flaky_control"
export AGENTQ_FLAKY_PASSTHROUGH="$work/bin/ssh"

# Switch the client onto the flaky transport for the rest of this check.
export AGENTQ_SSH="$work/bin/ssh-flaky"

# --- 8a. submit loses its response -> reconcile, and do NOT duplicate ------
#
# The client must re-run the SAME request id as a lookup and adopt the server's
# answer, rather than resubmitting.  A resubmit would create a second task for
# one request -- the failure this contract exists to prevent.
interrupt_request_id="interrupt-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
interrupt_label="transport-interrupt"
printf '1\n' > "$flaky_control/fail.submit"
: > "$flaky_control/calls.submit"
: > "$flaky_control/calls.lookup"

interrupt_status=0
interrupt_out=$(run_client submit --workdir "$workdir" --label "$interrupt_label" \
    --request-id "$interrupt_request_id" -- sh -c 'printf interrupt-ok' 2>"$work/interrupt.err") \
    || interrupt_status=$?
if [ "$interrupt_status" -ne 0 ]; then
    printf 'submit with a lost response exited %s, expected 0 (reconcile): %s\n' \
        "$interrupt_status" "$(head -c 300 <<<"$interrupt_out")" >&2
    exit 1
fi
if ! jq -e '.reused == true' <<<"$interrupt_out" >/dev/null 2>&1; then
    printf 'a reconciled submit did not report reused:true: %s\n' \
        "$(head -c 300 <<<"$interrupt_out")" >&2
    exit 1
fi
if ! grep -q 'reconciling attempt' "$work/interrupt.err"; then
    printf 'a lost submit response did not trigger the reconcile path: %s\n' \
        "$(tr '\n' '|' < "$work/interrupt.err")" >&2
    exit 1
fi

# Exactly one task may exist for this request.  Count by label, which is unique
# to this case, so a duplicate submit would show up as a second task.
interrupt_tasks=$(run_client status 2>/dev/null \
    | jq --arg label "$interrupt_label" \
        '[.tasks[] | select(.label == $label)] | length') || interrupt_tasks=''
if [ "$interrupt_tasks" != 1 ]; then
    printf 'a lost submit response produced %s task(s) for one request, expected 1\n' \
        "${interrupt_tasks:-<status failed>}" >&2
    exit 1
fi
# And the request id must resolve to that same single task.
interrupt_lookup=$(run_client lookup "$interrupt_request_id" 2>/dev/null) || {
    printf '%s\n' 'lookup of a reconciled request failed' >&2
    exit 1
}
if ! jq -e --argjson id "$(jq -r '.task_id' <<<"$interrupt_out")" \
        '.task_id == $id' <<<"$interrupt_lookup" >/dev/null 2>&1; then
    printf 'the reconciled request did not resolve to the task it reported: %s\n' \
        "$(head -c 300 <<<"$interrupt_lookup")" >&2
    exit 1
fi

# --- 8b. cancel loses its response -> exactly ONE call, no auto-retry ------
#
# This is the asymmetry that matters: response loss on a READ is retried, but on
# a MUTATION it must not be, because the client cannot know whether the mutation
# took effect.  The count of remote calls is the assertion -- a second call
# would be the forbidden automatic retry.
cancel_target="$workdir"
cancel_submit=$(run_client submit --workdir "$workdir" --label transport-interrupt-cancel \
    --request-id "${interrupt_request_id}-cancel" -- sleep 120 2>/dev/null) || {
    printf '%s\n' 'submit of the interruption cancel target failed' >&2
    exit 1
}
cancel_target_id=$(jq -er '.task_id' <<<"$cancel_submit")

# Record which cancel path this target will take, because the two paths are
# confirmed by DIFFERENT reads and the difference is real, not cosmetic:
#   - Queued  -> `pueue remove` (queued_removed); the task leaves Pueue, so
#                `status` no longer lists it and only `lookup` can confirm it,
#                through the tombstone (`state: "removed"`).
#   - Running -> `pueue kill`; the task stays in Pueue as Done/Killed and
#                `status` carries `.agentq.cancellation_requested_at`.
# Measured both ways on this sandbox.  Asserting a single channel regardless of
# path is what made the first version of this case fail: it demanded `removed`
# from a target that was Running, and reported the cancel as never having taken
# effect when it had.
cancel_target_was_queued=0
for _ in $(seq 1 20); do
    if run_client status 2>/dev/null \
        | jq -e --argjson id "$cancel_target_id" \
            '.tasks[($id|tostring)].status | has("Queued")' >/dev/null 2>&1; then
        cancel_target_was_queued=1
        break
    fi
    sleep 0.5
done

printf '1\n' > "$flaky_control/fail.cancel"
: > "$flaky_control/calls.cancel"
cancel_interrupt_status=0
run_client cancel "$cancel_target_id" >/dev/null 2>"$work/cancel-interrupt.err" \
    || cancel_interrupt_status=$?
if [ "$cancel_interrupt_status" -ne 255 ]; then
    printf 'cancel with a lost response exited %s, expected 255\n' \
        "$cancel_interrupt_status" >&2
    exit 1
fi
cancel_calls=$(grep -c . "$flaky_control/calls.cancel" || true)
if [ "$cancel_calls" -ne 1 ]; then
    printf 'cancel with a lost response made %s remote call(s), expected exactly 1 (no auto-retry)\n' \
        "$cancel_calls" >&2
    exit 1
fi
# The cancel really took effect even though the caller saw only a failure --
# that is why automatic retry would be unsafe.  Confirm it by reading, which is
# what the contract says a caller must do.
#
# The read that works here is `lookup`, NOT `status`: the queue is full at this
# point (section 6 filled it), so the target was still Queued and the cancel
# took the queued_removed path, which removes the task from Pueue outright.
# Measured: after that, `status` no longer lists the task at all, while
# `lookup` resolves the request through its tombstone.  Asserting on `status`
# here failed for exactly that reason -- the task was gone, which is the
# cancel working, not failing.
cancel_confirmed=0
for _ in $(seq 1 20); do
    # Capture first, then match.  `lookup` on a removed request exits 5 by
    # design, and this script runs under `set -o pipefail`, so `lookup | jq`
    # reports the PIPELINE as failed even when jq matched -- the confirmation
    # then reads as "never took effect".  Measured.  Splitting the two steps is
    # the same shape section 6 already uses for its removed-path assertions.
    if [ "$cancel_target_was_queued" -eq 1 ]; then
        cancel_probe=''; cancel_probe_status=0
        cancel_probe=$(run_client lookup "${interrupt_request_id}-cancel" 2>/dev/null) \
            || cancel_probe_status=$?
        if [ "$cancel_probe_status" -eq 5 ] &&
            jq -e '.state == "removed"' <<<"$cancel_probe" >/dev/null 2>&1; then
            cancel_confirmed=1
            break
        fi
    else
        cancel_probe=''; cancel_probe_status=0
        cancel_probe=$(run_client status 2>/dev/null) || cancel_probe_status=$?
        if [ "$cancel_probe_status" -eq 0 ] &&
            jq -e --argjson id "$cancel_target_id" \
                '.tasks[($id|tostring)].agentq.cancellation_requested_at != null' \
                <<<"$cancel_probe" >/dev/null 2>&1; then
            cancel_confirmed=1
            break
        fi
    fi
    sleep 0.5
done
if [ "$cancel_confirmed" -ne 1 ]; then
    printf 'the cancel whose response was lost never took effect for request %s (queued=%s)\n' \
        "${interrupt_request_id}-cancel" "$cancel_target_was_queued" >&2
    exit 1
fi

# --- 8c. a safe operation retries through a transient interruption ---------
#
# status carries no mutation, so a transport failure is safe to retry -- and the
# client does, with a bounded number of attempts.  Failing exactly once proves
# the retry happened AND that it recovered.
printf '1\n' > "$flaky_control/fail.status"
: > "$flaky_control/calls.status"
retry_status=0
run_client status >/dev/null 2>"$work/status-retry.err" || retry_status=$?
if [ "$retry_status" -ne 0 ]; then
    printf 'status through a transient interruption exited %s, expected 0 after retry: %s\n' \
        "$retry_status" "$(tr '\n' '|' < "$work/status-retry.err")" >&2
    exit 1
fi
status_calls=$(grep -c . "$flaky_control/calls.status" || true)
if [ "$status_calls" -ne 2 ]; then
    printf 'status through one transient interruption made %s call(s), expected 2 (one failure, one retry)\n' \
        "$status_calls" >&2
    exit 1
fi
if ! grep -q 'SSH transport lost while running status' "$work/status-retry.err"; then
    printf 'the retried status did not report the transport loss it recovered from: %s\n' \
        "$(tr '\n' '|' < "$work/status-retry.err")" >&2
    exit 1
fi

printf 'client-transport checks passed: ssh=real exit=0/1/2/3/5 not_started=ok queued_removed=5 reason=protocol_error/mutation-path interrupt=reconcile/1-task no-retry=1-call safe-retry=2-calls\n'
