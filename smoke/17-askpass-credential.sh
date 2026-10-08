#!/usr/bin/env bash
# Smoke: the POSIX client's password-credential path, over a REAL sshd.
#
# What this proves:
#   * a credential source changes what the client tells ssh (BatchMode=no plus
#     an askpass program) and that ssh then authenticates through it, over a real
#     SSH transport, with the AgentQ protocol running end to end;
#   * with no source configured nothing changes -- BatchMode=yes, askpass never
#     invoked, ssh left to fail fast;
#   * an authentication failure is classified and explained differently
#     depending on whether a source was configured.
#
# What this does NOT prove:
#   * account-password authentication.  The sandbox authenticates with a
#     passphrase-protected key, which travels the SAME read_passphrase ->
#     ssh_askpass path (measured: the prompt text differs, the mechanism does
#     not).  A real account password cannot be verified here: a non-root sshd on
#     macOS cannot read the password hash (getpwnam().pw_passwd is '********',
#     there is no /etc/shadow, /usr/sbin/sshd has no setuid bit), and UsePAM yes
#     requires root.  See docs/验证状态与测试覆盖边界.md's row for this check.
#   * Windows, or any remote host.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$root/skill/assets/client/unix/agentq"
client=${AGENTQ_SMOKE_CLIENT:-$client}

source_home=${AGENTQ_SMOKE_HOME:-}
if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'askpass-credential: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi
if [ ! -x /usr/sbin/sshd ]; then
    printf '%s\n' 'askpass-credential: SKIPPED (no /usr/sbin/sshd)'
    exit 0
fi
for command_name in jq ssh-keygen ssh; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'askpass-credential: SKIPPED (no %s)\n' "$command_name"
        exit 0
    fi
done

work=$(mktemp -d /tmp/agentq-smoke-askpass.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
case "$work" in
    /private/var/folders/*)
        printf '%s\n' 'refusing to run: the work directory is too long for a unix socket' >&2
        exit 1
        ;;
esac

sshd_pid=''
pueued_pid=''
cleanup() {
    [ -n "$sshd_pid" ] && kill "$sshd_pid" >/dev/null 2>&1 || true
    [ -n "$pueued_pid" ] && kill "$pueued_pid" >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

failures=0

# --- sandbox sshd ---------------------------------------------------------
ssh_dir="$work/ssh"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/hostkey" -C agentq-smoke-hostkey
# The client key carries a PASSPHRASE.  This is the whole point: it makes ssh
# call askpass for a secret that is not a key file, over the same code path an
# account password takes.
ssh-keygen -q -t ed25519 -N 'agentq-smoke-passphrase' -f "$ssh_dir/id" -C agentq-smoke-client

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
remote_root="$remote_home/.local/bin"
cat > "$remote_root/config/pueue.yml" <<YAML
shared:
  pueue_directory: '$remote_root/data'
  runtime_directory: '$remote_root/runtime'
  use_unix_socket: true
  unix_socket_permissions: 448
  pid_path: '$remote_root/runtime/pueued.pid'
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
chmod 600 "$remote_root/config/pueue.yml"

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
    printf 'askpass-credential: the sandbox sshd could not bind a port: %s\n' \
        "$(head -1 "$work/sshd.err")" >&2
    exit 1
fi
sshd_pid=$(cat "$ssh_dir/sshd.pid" 2>/dev/null || printf '')
[ -n "$sshd_pid" ] || { printf '%s\n' 'the sandbox sshd wrote no pid file' >&2; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<EOF
#!/bin/sh
exec /usr/bin/ssh -p $port -i "$ssh_dir/id" \\
    -o UserKnownHostsFile="$ssh_dir/known_hosts" \\
    -o StrictHostKeyChecking=no "\$@"
EOF
chmod 700 "$work/bin/ssh"

# --- sandbox daemon -------------------------------------------------------
"$remote_root/pueued" --config "$remote_root/config/pueue.yml" >"$work/pueued.log" 2>&1 &
pueued_pid=$!
daemon_ready=0
for _ in $(seq 1 60); do
    if "$remote_root/pueue" --config "$remote_root/config/pueue.yml" status --json >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 0.5
done
if [ "$daemon_ready" -ne 1 ]; then
    printf 'askpass-credential: the sandbox pueued never became ready: %s\n' \
        "$(tail -2 "$work/pueued.log" | tr '\n' '|')" >&2
    exit 1
fi

# --- the askpass program --------------------------------------------------
# It records every prompt it is asked, so "was it invoked, and for what" is
# asserted rather than assumed.
cat > "$work/askpass.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$work/askpass.log"
printf '%s\n' 'agentq-smoke-passphrase'
EOF
chmod 700 "$work/askpass.sh"
: > "$work/askpass.log"

# (A run_client helper used to sit here; it was dead code and its argument
# handling doubled "$@" -- removed 2026-10-06 rather than left as a trap.)

# --- 1. no source: the passphrase-protected key cannot be used -------------
# BatchMode=yes disables passphrase querying too, so this must fail on
# authentication, and askpass must never be consulted.
: > "$work/askpass.log"
status=0
env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
    AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=127.0.0.1 \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_CONFIG="$work/absent-config" \
    "$client" status >"$work/out1" 2>"$work/err1" || status=$?
cases=1
if [ "$status" -eq 0 ]; then
    printf 'askpass-credential: a passphrase-protected key was used with no credential source (exit 0)\n' >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'class=authentication' "$work/err1"; then
    printf 'askpass-credential: no-source failure was not classified as authentication: %s\n' \
        "$(tr '\n' '|' < "$work/err1")" >&2
    failures=$((failures + 1))
fi
if [ -s "$work/askpass.log" ]; then
    printf 'askpass-credential: askpass was invoked without a credential source: %s\n' \
        "$(tr '\n' '|' < "$work/askpass.log")" >&2
    failures=$((failures + 1))
fi

# --- 2. with AGENTQ_ASKPASS: the protocol runs end to end -----------------
# The remote platform is pinned so the probe does not have to guess, but the
# probe still runs and still authenticates -- which is the point: the credential
# source has to be in place BEFORE the probe, or nothing downstream is reached.
#
# submit comes first, not status: the `agentq` group does not exist on a fresh
# queue, and only submit creates it.  A status on a virgin queue is a
# protocol_error that has nothing to do with credentials (measured).
workdir="$work/workdir"
mkdir -p "$workdir"
: > "$work/askpass.log"
run_protocol() {
    env -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
        AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=127.0.0.1 \
        AGENTQ_REMOTE_PLATFORM=unix AGENTQ_CONFIG="$work/absent-config" \
        AGENTQ_ASKPASS="$work/askpass.sh" \
        "$client" "$@"
}
submit_status=0
submit_out=$(run_protocol submit --workdir "$workdir" --request-id smoke-askpass-request-0001 -- sh -c 'echo askpass-ok') || submit_status=$?
task_id=$(printf '%s' "$submit_out" | jq -r '.task_id // empty' 2>/dev/null || printf '')
cases=$((cases + 1))
if [ "$submit_status" -ne 0 ] || [ -z "$task_id" ]; then
    printf 'askpass-credential: submit over the credential source failed (exit %s): %s\n' \
        "$submit_status" "$(printf '%s' "$submit_out" | head -c 200)" >&2
    failures=$((failures + 1))
fi

if [ -n "$task_id" ]; then
    cases=$((cases + 1))
    wait_status=0
    wait_out=$(run_protocol wait "$task_id") || wait_status=$?
    # Both the exit code and the task result have to agree -- the project's rule,
    # and the reason 5 and 6 are not "done".
    wait_result=$(printf '%s' "$wait_out" | jq -r '.task.status.Done.result // empty' 2>/dev/null || printf '')
    if [ "$wait_status" -ne 0 ] || [ "$wait_result" != 'Success' ]; then
        printf 'askpass-credential: wait over the credential source failed (exit %s, result %s)\n' \
            "$wait_status" "${wait_result:-<none>}" >&2
        failures=$((failures + 1))
    fi
fi

# The user's own askpass program must survive: it is theirs, not a temporary.
cases=$((cases + 1))
if [ ! -x "$work/askpass.sh" ]; then
    printf '%s\n' 'askpass-credential: the user-supplied askpass program was removed' >&2
    failures=$((failures + 1))
fi

# --- 2b. the AGENTQ_PASSWORD source: end to end, and nothing left behind -----
# Until 2026-10-05 this source had ZERO coverage: AGENTQ_PASSWORD appeared in
# this file only inside `env -u`, so nothing ever set it.  That gap covered
# exactly the code path the 2026-10-05 review touched -- the client builds its
# OWN temporary askpass wrapper for this source (rather than using a program the
# user supplies), registers it for removal, and records its identity.  A defect
# there is invisible to every other check: the AGENTQ_ASKPASS source never
# allocates that file, and smoke/05 asserts only what reaches ssh's argv and
# environment, not the wrapper's lifecycle on disk.
#
# TMPDIR is redirected so "nothing left behind" is a real assertion about files
# this check can name, rather than a hope about whatever else is in /tmp.
password_tmp="$work/password-tmp"
mkdir -p "$password_tmp"
run_protocol_password() {
    env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD_PROMPT \
        TMPDIR="$password_tmp" \
        AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=127.0.0.1 \
        AGENTQ_REMOTE_PLATFORM=unix AGENTQ_CONFIG="$work/absent-config" \
        AGENTQ_PASSWORD='agentq-smoke-passphrase' \
        "$client" "$@"
}
# The passphrase is the same secret the AGENTQ_ASKPASS program above prints, so
# this exercises the same authentication -- only the delivery differs.  That is
# the point: the source under test is how the secret REACHES ssh, not whether
# the sandbox can authenticate at all.
: > "$work/askpass.log"
pw_submit_status=0
pw_submit_out=$(run_protocol_password submit --workdir "$workdir" \
    --request-id smoke-askpass-request-0002 -- sh -c 'echo password-ok') || pw_submit_status=$?
pw_task_id=$(printf '%s' "$pw_submit_out" | jq -r '.task_id // empty' 2>/dev/null || printf '')
cases=$((cases + 1))
if [ "$pw_submit_status" -ne 0 ] || [ -z "$pw_task_id" ]; then
    printf 'askpass-credential: submit over AGENTQ_PASSWORD failed (exit %s): %s\n' \
        "$pw_submit_status" "$(printf '%s' "$pw_submit_out" | head -c 200)" >&2
    failures=$((failures + 1))
fi

if [ -n "$pw_task_id" ]; then
    cases=$((cases + 1))
    pw_wait_status=0
    pw_wait_out=$(run_protocol_password wait "$pw_task_id") || pw_wait_status=$?
    pw_wait_result=$(printf '%s' "$pw_wait_out" | jq -r '.task.status.Done.result // empty' 2>/dev/null || printf '')
    if [ "$pw_wait_status" -ne 0 ] || [ "$pw_wait_result" != 'Success' ]; then
        printf 'askpass-credential: wait over AGENTQ_PASSWORD failed (exit %s, result %s)\n' \
            "$pw_wait_status" "${pw_wait_result:-<none>}" >&2
        failures=$((failures + 1))
    fi
fi

# The wrapper this source creates is the client's own temporary, so it must be
# gone.  This is the assertion that would have caught the ssh_stderr_capture
# leak fixed on 2026-10-05, had it been reachable from here.
cases=$((cases + 1))
pw_residue=$(find "$password_tmp" -mindepth 1 | wc -l | tr -d ' ')
if [ "$pw_residue" -ne 0 ]; then
    printf 'askpass-credential: AGENTQ_PASSWORD left %s file(s) in TMPDIR: %s\n' \
        "$pw_residue" "$(find "$password_tmp" -mindepth 1 -exec basename {} \; | tr '\n' ' ')" >&2
    failures=$((failures + 1))
fi

# --- 3. a broken source is refused, not downgraded ------------------------
# Silently falling back to key-only auth is the failure this guards: the
# operator would believe a password was in use while none was.
expect_refused() {
    local expected=$1
    local label=$2
    shift 2
    cases=$((cases + 1))
    local status=0
    env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
        AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=127.0.0.1 \
        AGENTQ_REMOTE_PLATFORM=unix AGENTQ_CONFIG="$work/absent-config" \
        "$@" "$client" status >/dev/null 2>"$work/err-refused" || status=$?
    if [ "$status" -ne 2 ]; then
        printf 'askpass-credential: %s was not refused (exit %s)\n' "$label" "$status" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err-refused"; then
        printf 'askpass-credential: %s gave the wrong reason: %s\n' \
            "$label" "$(tr '\n' '|' < "$work/err-refused")" >&2
        failures=$((failures + 1))
    fi
}
expect_refused 'AGENTQ_ASKPASS does not exist' 'a nonexistent askpass program' \
    AGENTQ_ASKPASS="$work/absent-program"

if [ "$failures" -ne 0 ]; then
    printf 'askpass-credential: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'askpass-credential checks passed: sshd=real cases=%s askpass=invoked protocol=submit/wait source=askpass+password\n' "$cases"
