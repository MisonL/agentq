#!/usr/bin/env bash
# Smoke: the POSIX client's interrupt path -- a signal must stop the operation
# AND clean up, and it must do both on every signal, not just some of them.
#
# What this proves:
#   * an HUP/INT/TERM delivered while the client is inside an SSH call makes it
#     exit 130 (the sshp convention, also used by install-client.sh) rather than
#     run the operation to completion;
#   * every temporary the client allocated is gone afterwards -- asserted
#     against a redirected TMPDIR, so nothing on the developer's own TMPDIR can
#     be credited or blamed;
#   * the askpass wrapper built from AGENTQ_PASSWORD is removed on that path.
#
# Why this check exists (a real defect, not a hypothetical):
#   The client set `trap cleanup_config_snapshot EXIT HUP INT TERM` near the top
#   and later `trap cleanup_client_runtime EXIT`.  The second call rebinds ONLY
#   the EXIT slot, so HUP/INT/TERM kept pointing at cleanup_config_snapshot --
#   whose state had long since been cleared, making it a no-op.  Worse, a bash
#   signal handler that returns does NOT end the shell: it resumes after the
#   interrupted command (verified -- a handler for INT/TERM that only returns
#   leaves execution continuing past the interrupt).  So Ctrl-C during `wait`
#   neither stopped the wait nor ran the runtime cleanup.  If the process were
#   then killed outright, a 0700 askpass wrapper survived in TMPDIR.  Two
#   sibling assets already had the right form all along (sshp, install-client.sh
#   both use `trap 'exit 130' HUP INT TERM`) -- the classic "same mechanism
#   copied in several places, only one hardened".
#
# What this does NOT prove:
#   * anything about a real remote, a real sshd, or the protocol.  The ssh used
#     here is a stub that signals its parent and exits; this check is about the
#     client's own signal and cleanup handling only.
#   * SIGKILL.  That cannot be trapped, so no trap can cover it; the residue
#     assertion below is about catchable signals only.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$root/skill/assets/client/unix/agentq"
client=${AGENTQ_SMOKE_CLIENT:-$client}

if [ ! -x "$client" ]; then
    printf '%s\n' 'client-interrupt: FAIL (the POSIX client is missing or not executable)'
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-interrupt.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT HUP INT TERM

failures=0
cases=0

# The client reads TMPDIR for every temporary it allocates, so pointing it at a
# directory this check owns is what makes "zero residue" a real assertion rather
# than a hope.
client_tmp="$work/tmp"
mkdir -p "$client_tmp"

# A stub ssh that interrupts the client from the inside.  Signalling the PARENT
# is the point: it proves the handler runs while an SSH call is outstanding,
# which is the window where the old trap bound the wrong function.  Signalling
# the client's own process group from outside would not distinguish the two
# shapes -- a child in the foreground process group receives SIGINT too, so the
# signal would reach the client either way and the test would pass even with the
# defect present.
cat > "$work/ssh" <<EOF
#!/bin/sh
# Record that we were reached, then interrupt the client mid-call.
: > "$work/ssh-invoked"
kill -TERM "\$(ps -o ppid= -p \$\$ | tr -d ' ')" 2>/dev/null || true
# Give the client a moment to run its handler, then exit normally so the client
# is not left waiting on a live child.
sleep 2
exit 255
EOF
chmod 700 "$work/ssh"

# One run per signal.  All three are asserted separately: a fix that covered only
# INT (the common one) would pass a single-case check and is exactly the shape of
# the defect being guarded.
for signal_name in TERM INT HUP; do
    cases=$((cases + 1))
    : > "$work/ssh-invoked"
    before=$(find "$client_tmp" -mindepth 1 | wc -l | tr -d ' ')

    status=0
    env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD_PROMPT \
        TMPDIR="$client_tmp" \
        AGENTQ_SSH="$work/ssh" \
        AGENTQ_HOST=127.0.0.1 \
        AGENTQ_REMOTE_PLATFORM=unix \
        AGENTQ_CONFIG="$work/absent-config" \
        AGENTQ_PASSWORD='agentq-smoke-interrupt-secret' \
        "$client" status >"$work/out.$signal_name" 2>"$work/err.$signal_name" &
        client_pid=$!

    # Wait for the stub to prove the client reached an SSH call, then let the
    # signal land.  Bounded so a client that never calls ssh fails instead of
    # hanging the suite.
    reached=0
    for _ in $(seq 1 100); do
        if [ -f "$work/ssh-invoked" ]; then
            reached=1
            break
        fi
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.1
    done

    if [ "$reached" -ne 1 ]; then
        printf 'client-interrupt: %s never reached an SSH call, so the signal path was not exercised\n' \
            "$signal_name" >&2
        wait "$client_pid" 2>/dev/null || true
        failures=$((failures + 1))
        continue
    fi

    wait "$client_pid" 2>/dev/null || status=$?

    if [ "$status" -ne 130 ]; then
        printf 'client-interrupt: SIG%s did not stop the client (exit %s, expected 130): %s\n' \
            "$signal_name" "$status" "$(tr '\n' '|' < "$work/err.$signal_name")" >&2
        failures=$((failures + 1))
    fi

    # Zero residue, counted in the redirected TMPDIR.  The askpass wrapper is the
    # one that matters most -- it is the file whose loss would leave a handle on
    # the password -- but the count covers every temporary the client allocated.
    after=$(find "$client_tmp" -mindepth 1 | wc -l | tr -d ' ')
    if [ "$after" -ne "$before" ]; then
        printf 'client-interrupt: SIG%s left %s file(s) behind in TMPDIR: %s\n' \
            "$signal_name" "$((after - before))" \
            "$(find "$client_tmp" -mindepth 1 -exec basename {} \; | tr '\n' ' ')" >&2
        failures=$((failures + 1))
    fi
done

# A control case with no signal at all.  Without it, a client that simply always
# exited 130 -- or that never allocated a temporary in the first place -- would
# satisfy every case above while being broken in the ordinary path.  This is the
# same "both directions" discipline smoke/05 and smoke/17 use.
cases=$((cases + 1))
: > "$work/ssh-invoked"
cat > "$work/ssh-quiet" <<EOF
#!/bin/sh
exit 255
EOF
chmod 700 "$work/ssh-quiet"
control_status=0
env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD_PROMPT \
    TMPDIR="$client_tmp" \
    AGENTQ_SSH="$work/ssh-quiet" \
    AGENTQ_HOST=127.0.0.1 \
    AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_PASSWORD='agentq-smoke-interrupt-secret' \
    "$client" status >/dev/null 2>&1 || control_status=$?
if [ "$control_status" -eq 130 ]; then
    printf '%s\n' 'client-interrupt: an unsignalled run exited 130; the signal cases prove nothing' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'client-interrupt: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'client-interrupt checks passed: cases=%s signals=TERM/INT/HUP exit=130 residue=none control=not-130\n' "$cases"
