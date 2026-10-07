#!/usr/bin/env bash
# Smoke: the POSIX client's local contract.  No remote is contacted -- a stub
# `ssh` answers the platform probe and nothing else, so everything here is the
# client's own argument handling and its response validation.
#
# This is the only check that covers assets/client/unix/agentq at all.  It is
# deliberately narrow: it proves the client rejects bad invocations with the
# documented message and exit code, and that it refuses to treat a malformed
# remote response as success.  It proves nothing about a real remote.
#
# The last section is the exception to "argument handling only": against a
# Windows-shaped stub it asserts that what the client SENDS actually arrives --
# the probe script on stdin, and the launcher's base64 payload on stdin -- plus
# that neither leaves a temporary behind.  Those are behavioural assertions, and
# they exist because a static check (smoke/14) can confirm the client still
# emits `-Command -` / `-EncodedCommand` while the bytes it feeds are empty.
# See CLAUDE.md's 05 row for the regression that made this necessary.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$root/skill/assets/client/unix/agentq"
work=$(mktemp -d /tmp/agentq-smoke-client.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# A stub ssh.  The client probes the remote platform before it validates its own
# arguments, so without a reachable probe nothing below would be exercised.  It
# answers the platform probe and returns an empty success for anything else --
# which is itself useful: an empty response is malformed, and the client must
# reject it rather than report success.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'STUB'
#!/bin/sh
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
exit 0
STUB
chmod 700 "$work/bin/ssh"

# Same stub, but it records what the client actually passed to ssh.  The
# BatchMode decision is invisible to a static check -- smoke/14 measures command
# line LENGTH and smoke/01 only parses -- so a client that always sent the same
# value would satisfy both.  This is what makes the decision observable.
cat > "$work/bin/ssh-argv" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "${AGENTQ_ARGV_CAPTURE:?}"
printf 'ASKPASS=%s\n' "${SSH_ASKPASS:-<unset>}" >> "${AGENTQ_ARGV_CAPTURE}.env"
printf 'REQUIRE=%s\n' "${SSH_ASKPASS_REQUIRE:-<unset>}" >> "${AGENTQ_ARGV_CAPTURE}.env"
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
printf '%s\n' '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$work/bin/ssh-argv"

# assert_credentials <yes|no> <label> [env assignments...]
#
# `yes` means a credential source is configured and ssh must be told to accept a
# password; `no` means no source is configured and ssh must stay in BatchMode.
assert_credentials() {
    local want=$1
    local label=$2
    shift 2
    credential_cases=$((credential_cases + 1))
    : > "$work/argv"
    : > "$work/argv.env"
    local status=0
    env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
        AGENTQ_ARGV_CAPTURE="$work/argv" AGENTQ_SSH="$work/bin/ssh-argv" \
        AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        "$@" "$client" status >"$work/out" 2>"$work/err" || status=$?
    if [ ! -s "$work/argv" ]; then
        printf 'client %s: ssh was never invoked, so the options cannot be checked\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if [ "$want" = yes ]; then
        if ! grep -qx -- '-o' "$work/argv" || ! grep -qx -- 'BatchMode=no' "$work/argv"; then
            printf 'client %s: expected BatchMode=no for ssh, argv was: %s\n' \
                "$label" "$(tr '\n' '|' < "$work/argv")" >&2
            failures=$((failures + 1))
        fi
        if ! grep -q '^NumberOfPasswordPrompts=' "$work/argv"; then
            printf 'client %s: expected a password prompt bound, argv was: %s\n' \
                "$label" "$(tr '\n' '|' < "$work/argv")" >&2
            failures=$((failures + 1))
        fi
        if ! grep -qx 'REQUIRE=force' "$work/argv.env"; then
            printf 'client %s: SSH_ASKPASS_REQUIRE was not forced: %s\n' \
                "$label" "$(tr '\n' '|' < "$work/argv.env")" >&2
            failures=$((failures + 1))
        fi
    else
        if ! grep -qx -- 'BatchMode=yes' "$work/argv"; then
            printf 'client %s: expected BatchMode=yes for ssh, argv was: %s\n' \
                "$label" "$(tr '\n' '|' < "$work/argv")" >&2
            failures=$((failures + 1))
        fi
        if grep -q '^NumberOfPasswordPrompts=' "$work/argv"; then
            printf 'client %s: prompts option must not appear without a source\n' "$label" >&2
            failures=$((failures + 1))
        fi
        # An exported-but-empty SSH_ASKPASS is not the same as an unset one:
        # OpenSSH tests getenv() != NULL, so an empty value makes it try to exec
        # the empty string.  Measured behaviour, not a guess.
        if ! grep -qx 'ASKPASS=<unset>' "$work/argv.env"; then
            printf 'client %s: SSH_ASKPASS must be absent, not empty: %s\n' \
                "$label" "$(tr '\n' '|' < "$work/argv.env")" >&2
            failures=$((failures + 1))
        fi
    fi
}

# expect_env_rejected <expected-message-fragment> <label> [env assignments...]
# The credential sources are environment variables, not arguments, so they need
# their own rejection helper; expect_rejected below passes its extras as argv.
expect_env_rejected() {
    local expected=$1
    local label=$2
    shift 2
    local status=0
    env_rejections=$((env_rejections + 1))
    env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
        AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
        AGENTQ_CONFIG="$work/absent-config" \
        "$@" "$client" status >"$work/out" 2>"$work/err" || status=$?
    if [ "$status" -ne 2 ]; then
        printf 'client %s: expected exit 2, got %s\n' "$label" "$status" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'client %s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

failures=0
# Runtime counters for the two families that used to be literals in the summary
# line.  Measured 2026-10-06: env=10 under-reported 15 executed env rejections
# (10 expect_env_rejected calls + the 5-variable loop), and both numbers were
# untracked literals that no case addition would move -- the same drift class
# the cases counter was fixed for on 2026-10-05.
env_rejections=0

# HOME unset: the client must refuse with its OWN parameter-error shape (exit 2
# + a message naming the variable), not die at the config_path expansion under
# `set -u` with bash's raw `HOME: unbound variable` and the generic exit 1
# (measured 2026-10-07 before the guard).  `env -u HOME` is the only way to
# reach it; the sandbox HOME elsewhere is deliberate.
env_rejections=$((env_rejections + 1))
home_status=0
env -u HOME -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
    AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
    AGENTQ_CONFIG="$work/absent-config" \
    "$client" status >"$work/out" 2>"$work/err" || home_status=$?
if [ "$home_status" -ne 2 ]; then
    printf 'client HOME unset: expected exit 2, got %s\n' "$home_status" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
if ! grep -qF 'HOME is not set' "$work/err"; then
    printf '%s\n' 'client HOME unset: stderr did not carry the controlled message' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

credential_cases=0
# The count of cases.  It was a literal `16` in the summary line until
# 2026-10-05, which meant a new case could be added without the reported number
# moving -- a small false green of its own.  It starts at the 16 pre-existing
# cases and the cases added since increment it; the summary prints this value.
cases=16

# expect_rejected <expected-message-fragment> [args...]
expect_rejected() {
    local expected=$1
    shift
    local label=$*
    local status=0
    AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
        "$client" "$@" >"$work/out" 2>"$work/err" || status=$?
    if [ "$status" -ne 2 ]; then
        printf 'client %s: expected exit 2, got %s\n' "${label:-<no args>}" "$status" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'client %s: stderr does not contain %s\n' "${label:-<no args>}" "$expected" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

expect_rejected 'Usage:'                 # no arguments
expect_rejected 'unknown command: bogus' bogus
expect_rejected 'lookup requires one request id' lookup
expect_rejected 'request id must be'     lookup abc
expect_rejected 'wait requires one task id' wait
expect_rejected 'task id must be a non-negative integer' wait abc
expect_rejected 'logs requires a task id' logs
expect_rejected 'task id must be a non-negative integer' logs abc
expect_rejected '--tail must be a positive integer or all' logs 1 --tail x
expect_rejected 'cancel requires one task id' cancel
expect_rejected 'task id must be a non-negative integer' cancel abc
expect_rejected 'remove requires one task id' remove
expect_rejected 'task id must be a non-negative integer' remove abc
expect_rejected 'doctor accepts no arguments' doctor extra
expect_rejected 'status accepts no arguments' status extra
expect_rejected '--workdir is required' submit

# --help is the one invocation that must succeed without a remote.
help_status=0
AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host "$client" --help >"$work/help" 2>&1 || help_status=$?
if [ "$help_status" -ne 0 ]; then
    printf 'client --help exited %s, expected 0\n' "$help_status" >&2
    failures=$((failures + 1))
elif ! grep -q 'submit' "$work/help"; then
    printf '%s\n' 'client --help did not print the usage text' >&2
    failures=$((failures + 1))
fi

# A malformed remote response must never be reported as success.  The stub
# returns an empty body, which is not valid AgentQ JSON.
if AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
    "$client" submit --workdir /tmp --request-id smokeclient00000001 -- true \
    >"$work/submit.out" 2>"$work/submit.err"; then
    printf '%s\n' 'client reported success for a malformed remote response' >&2
    failures=$((failures + 1))
fi

# The machine-readable failure class must survive the SSH hop.  The server
# prints `reason=<class>` on stderr next to every exit-2 message; the client
# reads that line out of its own SSH log and re-emits ONLY the controlled token
# (lower-case letters and underscores).  Without this, a caller driving the
# client has to string-match human-readable messages to tell a retryable lock
# rejection from an argument error -- the exact ambiguity the reason channel
# exists to remove.
# NOTE on where the reason line is written, because the first version of this
# fixture got it wrong and the mistake was invisible.  OpenSSH sends the REMOTE
# command's stderr to the LOCAL stderr; the -E log receives only ssh's own
# diagnostics.  Measured against a real sshd: a remote `printf ... >&2` lands on
# the local stderr and the -E file stays empty.  The first stub here wrote the
# reason into the -E file, so the check was passing against a transport model
# that does not exist.  These stubs now write to stderr, like real ssh.
reason_stub="$work/bin/ssh-reason"
cat > "$reason_stub" <<'STUB'
#!/bin/sh
printf '%s\n' 'agentq-server: AgentQ operation is already in progress: /x/y' >&2
printf '%s\n' 'agentq-server: reason=lock_contention' >&2
exit 2
STUB
chmod 700 "$reason_stub"
reason_status=0
AGENTQ_SSH="$reason_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/reason.out" 2>"$work/reason.err" || reason_status=$?
if [ "$reason_status" -ne 2 ]; then
    printf 'client status with a lock-rejected remote exited %s, expected 2\n' "$reason_status" >&2
    failures=$((failures + 1))
elif ! grep -qF 'remote failure reason: lock_contention' "$work/reason.err"; then
    printf 'client did not surface the remote failure reason: %s\n' \
        "$(tr '\n' '|' < "$work/reason.err")" >&2
    failures=$((failures + 1))
fi
if grep -qF 'already in progress' "$work/reason.err"; then
    printf '%s\n' 'client echoed raw remote stderr instead of the controlled token' >&2
    failures=$((failures + 1))
fi

# The PLATFORM PROBE runs before any operation is dispatched, and it used to be
# the one ssh call site that did not capture stderr -- so a remote could write a
# fully-formed forged line straight onto the caller's stderr, ahead of anything
# the client printed.  The case above drives the OPERATION path, which is why it
# stayed green while this was open.  The probe's first call answers `uname -s`;
# the stub below answers it and also writes the forged token, so the assertion is
# specifically about what reaches the caller during probing.
probe_stub="$work/bin/ssh-probe-forge"
cat > "$probe_stub" <<'STUB'
#!/bin/sh
printf '%s\n' 'Linux'
printf '%s\n' 'agentq: remote failure reason: lock_contention' >&2
exit 0
STUB
chmod 700 "$probe_stub"
probe_status=0
AGENTQ_SSH="$probe_stub" AGENTQ_HOST=smoke-host \
    "$client" status >"$work/probe.out" 2>"$work/probe.err" || probe_status=$?
if grep -qF 'lock_contention' "$work/probe.err"; then
    printf 'the platform probe let remote-controlled text reach the caller stderr: %s\n' \
        "$(tr '\n' '|' < "$work/probe.err")" >&2
    failures=$((failures + 1))
fi
if grep -qF 'remote failure reason' "$work/probe.err"; then
    printf '%s\n' 'the platform probe forwarded a forged reason line' >&2
    failures=$((failures + 1))
fi

# And the token must not become an injection channel: a remote that writes
# anything other than the strict character class must be ignored entirely.
inject_stub="$work/bin/ssh-inject"
cat > "$inject_stub" <<'STUB'
#!/bin/sh
printf '%s\n' 'agentq-server: reason=lock_contention; rm -rf /' >&2
printf '%s\n' 'agentq-server: reason=Lock_Contention' >&2
printf '%s\n' 'agentq-server: reason=lock contention' >&2
exit 2
STUB
chmod 700 "$inject_stub"
AGENTQ_SSH="$inject_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/inject.out" 2>"$work/inject.err" || true
if grep -q 'remote failure reason' "$work/inject.err"; then
    printf 'client forwarded a malformed reason line: %s\n' \
        "$(tr '\n' '|' < "$work/inject.err")" >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# The ssh diagnostic classifier.  Nothing asserted this before, and the defect
# it guards survived in FOUR assets (POSIX client, POSIX sshp, Windows client,
# Windows sshp) because of one missing prefix.
#
# Measured on a real host (macOS 15.7.7, OpenSSH server offering
# publickey,password,keyboard-interactive) with a client that had no usable key:
# `ssh -E <log>` writes EXACTLY this line, and the log is 81 bytes --
#
#     <user>@<host>: Permission denied (publickey,password,keyboard-interactive).
#
# The classifier matched `^(Permission denied|...)`, i.e. the message had to be
# at the START of the line.  OpenSSH prefixes it with `user@host: `, so the
# match never fired and every authentication failure was reported as the
# generic `class=ssh`.  Measured: the same run reported `class=ssh, 81 bytes`.
#
# The prefixes are copied from measurement, not guessed:
#   Permission denied          -> `<user>@<host>: Permission denied (...)`  (prefixed)
#   Host key verification      -> `Host key verification failed.`           (bare)
#   Could not resolve hostname -> writes NOTHING to the -E log at all
# `Could not resolve hostname` is therefore NOT asserted here: with an empty
# log the client reports nothing, which is honest, and inventing a prefix for it
# would be exactly the kind of unmeasured fixture this project keeps getting
# burned by.
auth_stub="$work/bin/ssh-auth"
cat > "$auth_stub" <<'STUB'
#!/bin/sh
# Faithful to a real ssh: the platform probe must answer first, or the client
# never reaches the operation whose diagnostics we want to classify.
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
# The exact bytes measured from OpenSSH, including the user@host prefix and the
# CRLF that the client strips.  The -E log is what carries them.
for argument in "$@"; do
    case "$argument" in
        -E) log_path=$2 ;;
    esac
    shift_once=1
done
# Re-scan properly: find the -E value.
prev=''
for argument in "$@"; do
    if [ "$prev" = '-E' ]; then log_path=$argument; fi
    prev=$argument
done
[ -n "${log_path:-}" ] || log_path=/dev/null
printf 'smokeuser@smoke-host: Permission denied (publickey,password,keyboard-interactive).\r\n' > "$log_path"
exit 255
STUB
chmod 700 "$auth_stub"
auth_status=0
AGENTQ_SSH="$auth_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/auth.out" 2>"$work/auth.err" || auth_status=$?
if ! grep -qF 'class=authentication' "$work/auth.err"; then
    printf 'ssh authentication failure was not classified as authentication: %s\n' \
        "$(tr '\n' '|' < "$work/auth.err")" >&2
    failures=$((failures + 1))
fi

# The class line alone does not tell the operator what to do, and the caller's
# next line ("set AGENTQ_REMOTE_PLATFORM") points the wrong way.  So an
# authentication failure must also say what actually fixes it.
if ! grep -qF 'BatchMode=yes' "$work/auth.err"; then
    printf 'an authentication failure did not explain the BatchMode limitation: %s\n' \
        "$(tr '\n' '|' < "$work/auth.err")" >&2
    failures=$((failures + 1))
fi
# A configured credential source changes the advice, because the fix for one
# case is wrong for the other: telling an operator to install a key is useless
# once they have handed the client a password.  Asserted in both directions --
# if the message did not change, this would pass while giving the wrong advice.
if ! grep -qF 'AGENTQ_ASKPASS' "$work/auth.err"; then
    printf 'an authentication failure with no credential source did not mention AGENTQ_ASKPASS: %s\n' \
        "$(tr '\n' '|' < "$work/auth.err")" >&2
    failures=$((failures + 1))
fi

credential_auth_stub="$work/bin/ssh-auth-credential"
sed 's/^STUB$//' "$auth_stub" > "$credential_auth_stub" 2>/dev/null || cp "$auth_stub" "$credential_auth_stub"
chmod 700 "$credential_auth_stub"
credential_status=0
printf '#!/bin/sh\nprintf "pw\\n"\n' > "$work/askpass-program"
chmod 700 "$work/askpass-program"
AGENTQ_ASKPASS="$work/askpass-program" \
    AGENTQ_SSH="$auth_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/auth2.out" 2>"$work/auth2.err" || credential_status=$?
if ! grep -qF 'even though a credential source (askpass) is configured' "$work/auth2.err"; then
    printf 'an authentication failure WITH a credential source gave the wrong advice: %s\n' \
        "$(tr '\n' '|' < "$work/auth2.err")" >&2
    failures=$((failures + 1))
fi

# The bare form must keep working: `Host key verification failed.` is written
# with no prefix (measured), so a fix that only added a prefix would break it.
hostkey_stub="$work/bin/ssh-hostkey"
cat > "$hostkey_stub" <<'STUB'
#!/bin/sh
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
prev=''
for argument in "$@"; do
    if [ "$prev" = '-E' ]; then log_path=$argument; fi
    prev=$argument
done
[ -n "${log_path:-}" ] || log_path=/dev/null
printf 'Host key verification failed.\r\n' > "$log_path"
exit 255
STUB
chmod 700 "$hostkey_stub"
AGENTQ_SSH="$hostkey_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/hostkey.out" 2>"$work/hostkey.err" || true
if ! grep -qF 'class=authentication' "$work/hostkey.err"; then
    printf 'a bare Host key verification failure was not classified as authentication: %s\n' \
        "$(tr '\n' '|' < "$work/hostkey.err")" >&2
    failures=$((failures + 1))
fi

# The client's own environment validation runs before anything else.
for variable in AGENTQ_SUBMIT_RETRY_ATTEMPTS AGENTQ_SUBMIT_RETRY_DELAY \
    AGENTQ_OPERATION_RETRY_ATTEMPTS AGENTQ_OPERATION_RETRY_DELAY \
    AGENTQ_PLATFORM_PROBE_TIMEOUT; do
    env_rejections=$((env_rejections + 1))
    status=0
    env "$variable=0" AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
        "$client" --help >"$work/env.out" 2>"$work/env.err" || status=$?
    if [ "$status" -ne 2 ] || ! grep -qF "$variable must be a positive integer" "$work/env.err"; then
        printf '%s\n' "$variable=0 was not rejected as a positive integer" >&2
        failures=$((failures + 1))
    fi
done

# ---------------------------------------------------------------------------
# The Windows probe path.  This exists because a static check could not see the
# defect it guards: the POSIX client could not reach ANY Windows host, and every
# length/extraction assertion stayed green.
#
# The defect (introduced with A5a, 2026-09-22, fixed 2026-09-24): the probe
# script is fed to `powershell.exe ... -Command -` on stdin, and the temporary
# holding it is created by make_windows_probe_script_file -- which sets a GLOBAL
# naming that file.  The caller invoked it inside `$( )`, which runs in a
# subshell, so the assignment died with the subshell: the global stayed empty,
# the probe was handed NO stdin, PowerShell read EOF, printed nothing and exited
# 0.  The client then reported "native Windows platform probe returned an
# unexpected response" and refused to talk to the host.
#
# Two more defects lived in the same few lines and are covered here too: the
# identity of that temporary was wiped before the check that consumes it, and
# the temporary was never registered with the EXIT trap, so every probe leaked a
# file into TMPDIR (measured: 1 per run, and a Windows target runs two probes).
#
# What is asserted is BEHAVIOUR on a stub: the probe's script must actually
# arrive on stdin, the Windows path must be entered and completed, and nothing
# may be left behind in TMPDIR.
windows_tmp="$work/tmp"
mkdir -p "$windows_tmp"
windows_stub="$work/bin/ssh-windows"
cat > "$windows_stub" <<'STUB'
#!/bin/sh
# Faithful to a real MINGW64 host: `uname -s` answers MINGW64_NT-10.0-19045, so
# the client takes the probe_native_windows_platform branch.  A `-Command -`
# probe is fed its script on stdin; the stub records how many bytes arrived and
# answers like PowerShell would.  With an EMPTY stdin it prints nothing and
# exits 0 -- exactly what the defect produced, so the assertion below fails for
# the right reason rather than by luck.
work=${AGENTQ_WINDOWS_STUB_WORK:?}
last=''
for argument in "$@"; do last=$argument; done
count=$(cat "$work/count" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s' "$count" > "$work/count"
case "$last" in
    *uname*)
        printf 'MINGW64_NT-10.0-19045\n'
        exit 0
        ;;
    *-EncodedCommand*)
        # A REAL command (status, submit, ...), not a probe: the launcher wrapper.
        # Both operations take this same path, so the stub decodes the payload and
        # dispatches on its first argument, the way the launcher+server pair would.
        # It records the payload size, which is what the assertion below reads.
        # This case must precede the generic powershell.exe one, which matches the
        # same command string.
        cat > "$work/launcher-stdin.$count"
        payload_bytes=$(wc -c < "$work/launcher-stdin.$count" | tr -d ' ')
        operation=$(base64 -d < "$work/launcher-stdin.$count" 2>/dev/null | tr '\0' '\n' | head -1)
        printf 'launcher %s %s %s\n' "$count" "$payload_bytes" "${operation:-none}" >> "$work/calls.txt"
        case "$operation" in
            submit) printf '{"task_id":1,"request_id":"smokeclient00000001","reused":false}' ;;
            *)      printf '{"group":"agentq","tasks":{}}' ;;
        esac
        exit 0
        ;;
    *powershell.exe*)
        cat > "$work/stdin.$count"
        printf '%s %s\n' "$last" "$(wc -c < "$work/stdin.$count" | tr -d ' ')" >> "$work/calls.txt"
        if [ ! -s "$work/stdin.$count" ]; then
            # PowerShell handed an empty stdin: no output, exit 0.  This is the
            # exact shape the subshell defect produced.
            exit 0
        fi
        if grep -q 'launcher-ready' "$work/stdin.$count"; then
            printf 'agentq-windows-launcher-ready'
        else
            printf 'agentq-windows'
        fi
        printf 'agentq-exit:0'
        exit 0
        ;;
esac
printf '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$windows_stub"

windows_status=0
AGENTQ_WINDOWS_STUB_WORK="$work" AGENTQ_SSH="$windows_stub" \
    AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto TMPDIR="$windows_tmp" \
    "$client" status >"$work/win.out" 2>"$work/win.err" || windows_status=$?

if [ "$windows_status" -ne 0 ]; then
    printf 'client could not complete a Windows status on a Windows-shaped stub (exit %s): %s\n' \
        "$windows_status" "$(tr '\n' '|' < "$work/win.err")" >&2
    failures=$((failures + 1))
fi

# The probe script must reach the remote on stdin.  This is the assertion that
# fails on the subshell defect: the client still calls `-Command -`, it just
# sends nothing.
windows_probe_stdin_bytes=$(awk '/powershell\.exe/ { print $NF; exit }' "$work/calls.txt" 2>/dev/null || printf '')
if [ -z "$windows_probe_stdin_bytes" ]; then
    printf '%s\n' 'client never invoked the Windows PowerShell probe' >&2
    failures=$((failures + 1))
elif [ "$windows_probe_stdin_bytes" -le 0 ]; then
    printf 'client sent an EMPTY Windows probe script on stdin (got %s bytes)\n' \
        "$windows_probe_stdin_bytes" >&2
    failures=$((failures + 1))
fi

# Nothing may be left in the temporary directory.  The leak was one file per
# probe, and a Windows target runs two (platform, then protocol), so a leftover
# count of 0 is the assertion -- not "fewer than two".
windows_leftovers=$(find "$windows_tmp" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$windows_leftovers" -ne 0 ]; then
    printf 'client left %s file(s) in TMPDIR after a Windows probe: %s\n' \
        "$windows_leftovers" "$(find "$windows_tmp" -mindepth 1 2>/dev/null | tr '\n' ' ')" >&2
    failures=$((failures + 1))
fi

# A submit's payload must also actually arrive.  Same class of defect as the
# probe one above, and the same reason it needs a behavioural assertion: a
# static check can confirm the client still emits `-EncodedCommand` while the
# base64 it feeds on stdin is empty, and every length/extraction assertion
# stays green.  The payload is base64, so a non-zero byte count is the
# observable, and the response is only accepted if the client validated it.
submit_status=0
AGENTQ_WINDOWS_STUB_WORK="$work" AGENTQ_SSH="$windows_stub" \
    AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto TMPDIR="$windows_tmp" \
    "$client" submit --workdir /tmp --request-id smokeclient00000001 -- true \
    >"$work/winsubmit.out" 2>"$work/winsubmit.err" || submit_status=$?
if [ "$submit_status" -ne 0 ]; then
    printf 'client could not complete a Windows submit on a Windows-shaped stub (exit %s): %s\n' \
        "$submit_status" "$(tr '\n' '|' < "$work/winsubmit.err")" >&2
    failures=$((failures + 1))
fi
# The submit's payload must actually decode to the NUL-separated argument
# vector the launcher contract requires.  Three distinct failures live here and
# they must not collapse into one message, or the reader is sent the wrong way:
# the launcher was never called; it was called but its payload was EMPTY (the
# P0 class); it was called with a payload that is not this submit's vector.
# Keying off the FIRST `launcher` line would be wrong -- the STATUS run above
# takes the same path and is recorded first, so a first-match lookup measures
# the status payload, and because that one is non-empty the assertion would sit
# green forever.  Map each recorded call back to the file the stub wrote, via
# the counter the stub now records.
submit_payload_bytes=''
submit_payload_vector=''
# awk, not `grep -c`: grep -c prints `0` AND exits 1 when nothing matches, so
# `|| printf '0'` appends a second zero and the variable becomes "0\n0" -- the
# `-eq 0` test below then errors out and the "never invoked" branch is dead.
launcher_calls=$(awk '/^launcher /{n++} END{print n+0}' "$work/calls.txt" 2>/dev/null || printf '0')
# The emptiness flag is scoped to the LAST launcher call, which in this check is
# always the submit.  A flag accumulated across every call would misfire on a
# status whose payload was empty while the submit's was fine -- a false red, and
# a message naming the wrong operation.
last_launcher_bytes=''
while read -r _tag launcher_count launcher_bytes launcher_op; do
    last_launcher_bytes=$launcher_bytes
    launcher_file="$work/launcher-stdin.$launcher_count"
    [ -e "$launcher_file" ] || continue
    [ "${launcher_bytes:-0}" -gt 0 ] 2>/dev/null || continue
    launcher_vector=$(base64 -d < "$launcher_file" 2>/dev/null | tr '\0' '\n' || true)
    if [ "$(printf '%s\n' "$launcher_vector" | head -1)" = submit ]; then
        submit_payload_bytes=$launcher_bytes
        submit_payload_vector=$launcher_vector
    fi
done <<EOF
$(grep '^launcher ' "$work/calls.txt" 2>/dev/null || true)
EOF
if [ "$launcher_calls" -eq 0 ]; then
    printf '%s\n' 'client never invoked the Windows launcher for a submit' >&2
    failures=$((failures + 1))
elif [ "${last_launcher_bytes:-0}" -le 0 ] 2>/dev/null; then
    printf '%s\n' 'client sent an EMPTY launcher payload on stdin' >&2
    failures=$((failures + 1))
elif [ -z "$submit_payload_bytes" ]; then
    printf 'the Windows launcher was invoked, but no payload decoded to a submit argument vector: %s\n' \
        "$(tr '\n' '|' < "$work/calls.txt")" >&2
    failures=$((failures + 1))
else
    # A non-empty payload is not enough -- it must be THIS submit's argument
    # vector.  The request id is the client's own, so it cannot be present by
    # accident, and the workdir is the one passed on the command line.
    for required in smokeclient00000001 /tmp; do
        if ! printf '%s\n' "$submit_payload_vector" | grep -qxF -- "$required"; then
            printf 'launcher payload for a submit lacks %s: %s\n' \
                "$required" "$(printf '%s' "$submit_payload_vector" | tr '\n' '|')" >&2
            failures=$((failures + 1))
        fi
    done
fi

# The submit path allocates its OWN temporaries (the base64 payload and the ssh
# stderr capture), so the zero-leftover assertion above -- which runs after the
# STATUS operation -- does not cover it.  Checking only one of the two operations
# is the same mistake this section exists to correct.
submit_leftovers=$(find "$windows_tmp" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$submit_leftovers" -ne 0 ]; then
    printf 'client left %s file(s) in TMPDIR after a Windows submit: %s\n' \
        "$submit_leftovers" "$(find "$windows_tmp" -mindepth 1 2>/dev/null | tr '\n' ' ')" >&2
    failures=$((failures + 1))
fi

# --- the flattened exit-code column (DefaultShell=powershell.exe) --------------
# When sshd's DefaultShell is powershell.exe, the outer PowerShell flattens the
# exit code of a native child (the `powershell.exe -EncodedCommand` launcher) to
# 1.  Measured on Windows 10 / PS 5.1 (2026-10-01): `cmd /c exit 5` -> 1, while
# a PowerShell-native `exit 5` -> 5; AgentQ's remote command is the former.  So
# the SSH exit code loses the 2/3/4/5/6 the recovery logic depends on, and the
# launcher wrapper reports the real code out of band as `agentq-exit:<code>` on
# stderr -- the same channel the server's `reason=` line already uses.
#
# This stub models exactly that: the JSON response on stdout, the token on
# stderr, and a FLATTENED exit 1.  The client must recover the real code from
# the token.  A regression that dropped the extraction would leave exit 1 and
# these assertions would fail -- the defect this lock exists for.
flat_stub="$work/bin/ssh-flattened"
cat > "$flat_stub" <<'STUB'
#!/bin/sh
work=${AGENTQ_FLAT_STUB_WORK:?}
last=''
for argument in "$@"; do last=$argument; done
case "$last" in
    *uname*) printf 'MINGW64_NT-10.0-19045\n'; exit 0 ;;
    *-EncodedCommand*)
        # The stub DERIVES its token from the wrapper it is handed, rather than
        # printing one unconditionally.  The real chain is: the client builds
        # the wrapper, the remote PowerShell runs it, and the wrapper emits
        # `agentq-exit:<code>`.  A stub that always emitted the token would test
        # only the client's extraction and stay green even if BOTH wrapper
        # copies dropped the emission (parity would also stay green, since the
        # two copies would still agree).  Decoding the wrapper and emitting the
        # token only when the wrapper actually emits it closes that gap.
        encoded=$(printf '%s' "$last" | sed -n 's/.*-EncodedCommand //p')
        wrapper=$(printf '%s' "$encoded" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null || printf '')
        # Key on the FINAL emission (the one carrying the launcher's real
        # code), not any `agentq-exit:` substring: the wrapper also emits a
        # token in its too-large and null-exit branches, so a substring match
        # would stay green even if the final emission -- the one that matters --
        # were dropped.  Measured: that is exactly how a first version of this
        # lock missed its mutation.
        emits_token=no
        case "$wrapper" in *'agentq-exit:$agentqLauncherExit'*) emits_token=yes ;; esac
        cat > "$work/flat-stdin.$$"
        operation=$(base64 -d < "$work/flat-stdin.$$" 2>/dev/null | tr '\0' '\n' | head -1)
        rm -f "$work/flat-stdin.$$"
        case "$operation" in
            lookup)
                # A not_found lookup: correct JSON, contract exit 3.
                printf '{"request_id":"smokeclient00000009","task_id":null,"state":"not_found"}'
                [ "$emits_token" = yes ] && printf 'agentq-exit:3\n' >&2
                ;;
            *)
                printf '{"group":"agentq","tasks":{}}'
                [ "$emits_token" = yes ] && printf 'agentq-exit:0\n' >&2
                ;;
        esac
        # The flattening: the real code is lost to the SSH exit status.
        exit 1
        ;;
    *powershell.exe*)
        # Distinguish the two probes by their stdin: the protocol probe's script
        # carries the ready marker, the platform probe's does not.  Answering
        # both with the platform marker relied on the old advisory behaviour of
        # the protocol probe (measured 2026-10-06); a real wrapper emits the
        # ready marker on success, so the fixture must model that.
        probe_stdin=$(cat)
        case "$probe_stdin" in
            *launcher-ready*) printf 'agentq-windows-launcher-ready' ;;
            *) printf 'agentq-windows' ;;
        esac
        printf 'agentq-exit:0'
        exit 0
        ;;
esac
printf '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$flat_stub"

flat_status=0
AGENTQ_FLAT_STUB_WORK="$work" AGENTQ_SSH="$flat_stub" \
    AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto TMPDIR="$windows_tmp" \
    "$client" lookup smokeclient00000009 >"$work/flat.out" 2>"$work/flat.err" || flat_status=$?
if [ "$flat_status" -ne 3 ]; then
    printf 'lookup on a flattened (DefaultShell=powershell.exe) target returned exit %s, expected 3: the out-of-band agentq-exit token was not honoured; stderr=%s\n' \
        "$flat_status" "$(tr '\n' '|' < "$work/flat.err")" >&2
    failures=$((failures + 1))
fi

# A malformed or hostile token must be IGNORED, not adopted.  The token is
# parsed with a digits-only charset (same discipline as the reason channel) and
# a non-numeric value would break the client's arithmetic comparisons, so the
# safe behaviour is to fall back to the SSH exit code.  A remote that emits
# `agentq-exit:<garbage>` must not steer the client's exit status.
junk_stub="$work/bin/ssh-junk-token"
cat > "$junk_stub" <<'STUB'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
case "$last" in
    *uname*) printf 'MINGW64_NT-10.0-19045\n'; exit 0 ;;
    *-EncodedCommand*)
        cat > /dev/null
        printf '{"request_id":"smokeclient00000010","task_id":null,"state":"not_found"}'
        # A token that is not a plain integer, and one carrying shell syntax.
        printf 'agentq-exit:3; echo pwned\n' >&2
        exit 1
        ;;
    *powershell.exe*)
        # Distinguish the two probes by their stdin: the protocol probe's script
        # carries the ready marker, the platform probe's does not.  Answering
        # both with the platform marker relied on the old advisory behaviour of
        # the protocol probe (measured 2026-10-06); a real wrapper emits the
        # ready marker on success, so the fixture must model that.
        probe_stdin=$(cat)
        case "$probe_stdin" in
            *launcher-ready*) printf 'agentq-windows-launcher-ready' ;;
            *) printf 'agentq-windows' ;;
        esac
        printf 'agentq-exit:0'
        exit 0
        ;;
esac
printf '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$junk_stub"
junk_status=0
junk_out=$(AGENTQ_SSH="$junk_stub" AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto \
    TMPDIR="$windows_tmp" "$client" lookup smokeclient00000010 2>"$work/junk.err") || junk_status=$?
if [ "$junk_status" -ne 1 ]; then
    printf 'a hostile agentq-exit token changed the client exit to %s; expected the SSH code 1: %s\n' \
        "$junk_status" "$(tr '\n' '|' < "$work/junk.err")" >&2
    failures=$((failures + 1))
fi
case "$junk_out" in *pwned*) printf '%s\n' 'the agentq-exit token was executed as shell' >&2; failures=$((failures + 1)) ;; esac

# --- an EARLY valid token must not override the real one --------------------
# The junk case above proves a non-numeric token is ignored.  This one is the
# shape that actually decides the client's behaviour: every token here is a
# well-formed integer, so nothing is malformed and no charset guard rejects it.
# The remote emits a success token FIRST and the real failure token LAST.
#
# Why last wins: the launcher wrapper writes its authoritative token AFTER the
# launcher's own stderr, so the last token is the genuine one.  A first-match
# reader would take the planted `agentq-exit:0` and report SUCCESS for an
# operation that failed -- and this value drives the 3/4/5/6 recovery decisions,
# so a forged 0 skips the reconcile entirely.
#
# Measured divergence between the two clients (fixed 2026-10-05): the POSIX
# client has always taken the last match; the Windows client took the first, so
# a remote could make it claim success where POSIX correctly reported the
# failure.  Both directions are asserted here: the planted 0 must be ignored,
# and the trailing 3 must be honoured.
multi_stub="$work/bin/ssh-multi-token"
cat > "$multi_stub" <<'STUB'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
case "$last" in
    *uname*) printf 'MINGW64_NT-10.0-19045\n'; exit 0 ;;
    *-EncodedCommand*)
        cat > /dev/null
        printf '{"request_id":"smokeclient00000010","task_id":null,"state":"not_found"}'
        # A planted success token, then the real one.  Both are valid integers.
        printf 'agentq-exit:0\n' >&2
        printf 'agentq-exit:3\n' >&2
        exit 1
        ;;
    *powershell.exe*)
        # Distinguish the two probes by their stdin: the protocol probe's script
        # carries the ready marker, the platform probe's does not.  Answering
        # both with the platform marker relied on the old advisory behaviour of
        # the protocol probe (measured 2026-10-06); a real wrapper emits the
        # ready marker on success, so the fixture must model that.
        probe_stdin=$(cat)
        case "$probe_stdin" in
            *launcher-ready*) printf 'agentq-windows-launcher-ready' ;;
            *) printf 'agentq-windows' ;;
        esac
        printf 'agentq-exit:0'
        exit 0
        ;;
esac
printf '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$multi_stub"
multi_status=0
AGENTQ_SSH="$multi_stub" AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto \
    TMPDIR="$windows_tmp" "$client" lookup smokeclient00000010 >/dev/null 2>"$work/multi.err" || multi_status=$?
cases=$((cases + 1))
if [ "$multi_status" -ne 3 ]; then
    printf 'a planted leading agentq-exit:0 changed the client exit to %s; expected the LAST token (3): %s\n' \
        "$multi_status" "$(tr '\n' '|' < "$work/multi.err")" >&2
    failures=$((failures + 1))
fi

# The mirror image: a planted trailing token must NOT be honoured either, which
# is the same "last wins" rule seen from the other side -- if the reader took
# the first, this case would still pass, so it alone does not discriminate.  It
# is kept because the two together pin the rule to "last", not to "the one that
# happens to look like a plausible protocol code".
multi2_stub="$work/bin/ssh-multi-token-2"
cat > "$multi2_stub" <<'STUB'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
case "$last" in
    *uname*) printf 'MINGW64_NT-10.0-19045\n'; exit 0 ;;
    *-EncodedCommand*)
        cat > /dev/null
        printf '{"request_id":"smokeclient00000011","task_id":null,"state":"not_found"}'
        printf 'agentq-exit:3\n' >&2
        printf 'agentq-exit:0\n' >&2
        exit 1
        ;;
    *powershell.exe*)
        # Distinguish the two probes by their stdin: the protocol probe's script
        # carries the ready marker, the platform probe's does not.  Answering
        # both with the platform marker relied on the old advisory behaviour of
        # the protocol probe (measured 2026-10-06); a real wrapper emits the
        # ready marker on success, so the fixture must model that.
        probe_stdin=$(cat)
        case "$probe_stdin" in
            *launcher-ready*) printf 'agentq-windows-launcher-ready' ;;
            *) printf 'agentq-windows' ;;
        esac
        printf 'agentq-exit:0'
        exit 0
        ;;
esac
printf '{"group":"agentq","tasks":{}}'
exit 0
STUB
chmod 700 "$multi2_stub"
multi2_status=0
AGENTQ_SSH="$multi2_stub" AGENTQ_HOST=smoke-win AGENTQ_REMOTE_PLATFORM=auto \
    TMPDIR="$windows_tmp" "$client" lookup smokeclient00000011 >/dev/null 2>"$work/multi2.err" || multi2_status=$?
cases=$((cases + 1))
if [ "$multi2_status" -ne 0 ]; then
    printf 'a planted trailing agentq-exit:0 changed the client exit to %s; expected 0: %s\n' \
        "$multi2_status" "$(tr '\n' '|' < "$work/multi2.err")" >&2
    failures=$((failures + 1))
fi

# --- credential sources -------------------------------------------------------
# What the client tells ssh, which no static check can see.
assert_credentials no 'without a credential source'

printf '#!/bin/sh\nprintf "pw\\n"\n' > "$work/askpass-ok"
chmod 700 "$work/askpass-ok"
assert_credentials yes 'with AGENTQ_ASKPASS' AGENTQ_ASKPASS="$work/askpass-ok"
assert_credentials yes 'with AGENTQ_PASSWORD' AGENTQ_PASSWORD=smoke-secret
# A path containing a SPACE is legal: ssh executes the whole value as one file
# name, so no quoting is involved and none is needed.  Asserted because the
# natural over-correction is to reject any value with a space, which would
# refuse ordinary paths like "C:\Program Files\..." -- and a guard that
# refuses everything still passes every rejection case below.
mkdir -p "$work/askpass dir"
printf '#!/bin/sh\nprintf "pw\\n"\n' > "$work/askpass dir/prog"
chmod 700 "$work/askpass dir/prog"
assert_credentials yes 'askpass path containing a space' \
    AGENTQ_ASKPASS="$work/askpass dir/prog"

# A source that is configured but unusable must be REFUSED, not silently
# downgraded to key-only auth -- a silent downgrade would leave the operator
# believing a password was in use.  Each case asserts exit 2 and the reason.
expect_env_rejected 'AGENTQ_ASKPASS does not exist' 'askpass absent' \
    AGENTQ_ASKPASS="$work/absent-program"
# ssh executes the WHOLE SSH_ASKPASS value as a single file name -- no shell, no
# word splitting -- so an argument or a surrounding quote can never be part of
# it.  Both must be refused with a message about the SHAPE: the file exists, so
# reporting "does not exist" would point the operator at the wrong thing.
# (Measured: a bare path authenticates; both of these fail.)
expect_env_rejected 'must be a single executable path' 'askpass with an argument' \
    AGENTQ_ASKPASS="$work/askpass-ok --flag"
expect_env_rejected 'must be a single executable path' 'askpass in quotes' \
    AGENTQ_ASKPASS="\"$work/askpass-ok\""
# A quote ANYWHERE makes the value unexecutable, not just a leading one -- ssh
# execs the literal string.  Asserted separately because a pattern anchored to the
# leading character passes the case above while still accepting this one.
expect_env_rejected 'must be a single executable path' 'quote inside the path' \
    AGENTQ_ASKPASS="$work/ask\"pass-ok"
printf 'not executable' > "$work/askpass-noexec"
chmod 600 "$work/askpass-noexec"
expect_env_rejected 'AGENTQ_ASKPASS is not executable' 'askpass not executable' \
    AGENTQ_ASKPASS="$work/askpass-noexec"
ln -sf "$work/askpass-ok" "$work/askpass-link"
expect_env_rejected 'symbolic links are not accepted' 'askpass is a symlink' \
    AGENTQ_ASKPASS="$work/askpass-link"
expect_env_rejected 'AGENTQ_ASKPASS must be a regular file' 'askpass is a directory' \
    AGENTQ_ASKPASS="$work/bin"
expect_env_rejected 'set only one' 'both sources set' \
    AGENTQ_ASKPASS="$work/askpass-ok" AGENTQ_PASSWORD=both
expect_env_rejected 'AGENTQ_PASSWORD_PROMPT must be 1' 'bad prompt value' \
    AGENTQ_PASSWORD_PROMPT=2
# No terminal here, so the prompt source must refuse rather than let ssh fall
# back to reading the payload off stdin.
expect_env_rejected 'requires a terminal' 'prompt without a tty' \
    AGENTQ_PASSWORD_PROMPT=1

# AGENTQ_PASSWORD goes through a temporary wrapper that ssh executes.  Asserting
# the option string alone would not show whether the secret actually ARRIVES --
# and a wrapper that delivers an empty or truncated password is the failure that
# matters, because it looks like "wrong password" at the far end.  So the stub
# below runs the askpass program exactly as ssh does and captures what comes
# back.  The value carries a space and shell metacharacters on purpose: a
# wrapper built by naive quoting loses those.
cat > "$work/bin/ssh-askpass" <<'STUB'
#!/bin/sh
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
if [ -n "${SSH_ASKPASS:-}" ]; then
    "$SSH_ASKPASS" "user@smoke-host's password:" > "$work/delivered" 2>/dev/null
fi
printf '%s\n' '{"group":"agentq","tasks":{}}'
exit 0
STUB
sed -i.bak "s|\$work/delivered|$work/delivered|" "$work/bin/ssh-askpass"
rm -f "$work/bin/ssh-askpass.bak"
chmod 700 "$work/bin/ssh-askpass"

secret='smoke p@ss!$x'
: > "$work/delivered"
env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD_PROMPT \
    AGENTQ_SSH="$work/bin/ssh-askpass" AGENTQ_HOST=smoke-host \
    AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_PASSWORD="$secret" "$client" status >/dev/null 2>&1 || true
if [ ! -s "$work/delivered" ]; then
    printf '%s\n' 'client: the askpass wrapper delivered nothing to ssh' >&2
    failures=$((failures + 1))
elif [ "$(cat "$work/delivered")" != "$secret" ]; then
    printf 'client: the askpass wrapper corrupted the password: got %s\n' \
        "$(cat "$work/delivered")" >&2
    failures=$((failures + 1))
fi
# The wrapper must not outlive the call.
leftovers=$(find "$work" -name 'agentq-askpass*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftovers" -ne 0 ]; then
    printf 'client: %s askpass temporary file(s) survived the call\n' "$leftovers" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi

printf 'client-contract checks passed: cases=%s env=%s cred=%s stub-ssh=yes reason=forwarded/injection-safe exit-token=last-wins windows-probe=stdin-fed/no-leak windows-submit=payload-delivered/args-checked/no-leak\n' "$cases" "$env_rejections" "$credential_cases"
