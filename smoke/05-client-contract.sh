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
# See docs/verification-status.md's 05 row for the regression that made this necessary.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# The client path can be overridden (mirrors smoke/18's AGENTQ_SMOKE_SERVER) so
# a mutation proof can point the whole check at a modified copy -- without the
# hook, red-proofing a fix means swapping the real asset under this check.
client=${AGENTQ_SMOKE_CLIENT:-$root/skill/assets/client/unix/agentq}
work=$(mktemp -d /tmp/agentq-smoke-client.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
# Keep the client's platform-probe cache inside this run's temp dir (0.1.11).
# A cache under the real ~/.config/agentq would (a) write into the developer's
# own config and (b) leak the resolved platform of this check's test hosts into
# other cases or other suites, which then SKIP the probe they mean to exercise.
export AGENTQ_PLATFORM_CACHE_DIR="$work/platform-cache"
# and default the cache OFF: these cases exercise probing itself, and a
# warm entry (written by an earlier case for the same test host) would skip
# the probe under test. The dedicated cache case below re-enables it with
# its own fresh directory.
export AGENTQ_PLATFORM_PROBE_CACHE=off
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

# A stub that answers each mode the way the real server documents it, so the
# client's forwarding AND its response validation are both exercised: a client
# that stopped passing `--summary` would fail the argv assertion, and one that
# validated the summary against the full-status shape would fail the exit code
# (its own validation error).  The response shapes mirror `agentq-server`'s:
# status --summary -> {"tasks":{...},"group":...,"summary":true}, status --task
# -> {"task":{...}}, doctor default -> the summary, doctor --full -> the
# decorated map, remove --label -> an array of per-task results.  The request id
# is echoed back because the submit validator compares it to the one it sent.
cat > "$work/bin/ssh-modes" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "${AGENTQ_ARGV_CAPTURE:?}"
command=''
for argument in "$@"; do
    command=$argument
done
# The client quotes every argv element into one remote command string
# (`agentq_run 'status' '--summary'`), so strip the single quotes before
# matching -- otherwise every pattern below silently falls through to the
# default response and the cases above test the wrong shape.  The de-quoted
# command is what the assertions grep.
command=$(printf '%s' "$command" | tr -d "'")
printf '%s\n' "$command" >> "${AGENTQ_ARGV_CAPTURE}.cmd"
case "$command" in
    *'uname '*) printf 'Linux\n'; exit 0 ;;
esac
case "$command" in
    *"agentq_run submit"*)
        request_id=$(printf '%s' "$command" | sed -n 's/.*--request-id \([A-Za-z0-9._-]*\).*/\1/p')
        printf '{"task_id":7,"request_id":"%s","reused":false}\n' "$request_id"
        ;;
    *"agentq_run remove"*) printf '[]\n' ;;
    *"agentq_run wait"*)
        # Mirror the server's wait contract: `wait` takes exactly one task id.
        # A client that forwards --timeout makes the real server answer
        # `wait requires one task id` with exit 2, so the stub does the same --
        # otherwise the case below would pass on a client that leaks the flag.
        case "$command" in
            *'--timeout'*)
                printf 'agentq-server: wait requires one task id\nagentq-server: reason=protocol_error\n' >&2
                exit 2
                ;;
        esac
        printf '{"task":{"id":3,"group":"agentq","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"result":"Success"}}}}\n'
        ;;
    *'--summary'*) printf '{"tasks":{"3":{"id":3,"state":"Done","result":"Success","label":"agentq:x"}},"group":null,"summary":true}\n' ;;
    *'--task'*) printf '{"task":{"id":3,"group":"agentq","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"result":"Success"}}}}\n' ;;
    *'--full'*) printf '{"tasks":{},"group":null}\n' ;;
    *"agentq_run doctor"*) printf '{"tasks":{},"group":null,"summary":true}\n' ;;
    *) printf '{"group":"agentq","tasks":{}}\n' ;;
esac
exit 0
STUB
chmod 700 "$work/bin/ssh-modes"

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
# moving -- a small false green of its own.  That first fix left the 16 as a
# hardcoded base with only the LATER cases incrementing (2026-10-12 review);
# now every case increments it: expect_rejected bumps it, and the explicit
# cases=$((cases+1)) sites do too.  So the number tracks the assertions.
cases=0

# expect_rejected <expected-message-fragment> [args...]
expect_rejected() {
    local expected=$1
    shift
    local label=$*
    local status=0
    cases=$((cases + 1))
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
expect_rejected 'status accepts --summary or --task' status extra
# `status --summary` is no longer a local error: the client forwards it and
# validates the summary shape (asserted below against ssh-modes).
# --version and --help are local: they must answer before any SSH round trip.
version_status=0
AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host "$client" --version >"$work/ver.out" 2>"$work/ver.err" || version_status=$?
cases=$((cases + 1))
if [ "$version_status" -ne 0 ] || ! grep -qE '^agentq 0\.1\.[0-9]+$' "$work/ver.out"; then
    printf 'client --version: expected "agentq 0.1.x" on stdout with exit 0, got exit %s: %s\n' \
        "$version_status" "$(head -1 "$work/ver.out" "$work/ver.err" 2>/dev/null)" >&2
    failures=$((failures + 1))
fi
# Static locks: the version constant, the doctor side-effect warning, and the
# wait --timeout flag must exist in BOTH clients (the three copies of the
# payload protocol already have their own parity rule; these pin the CLI face).
static_failures=0
for client_file in "$root/skill/assets/client/unix/agentq" "$root/skill/assets/client/windows/agentq.ps1"; do
    grep -q "0\.1\.[0-9][0-9]*" "$client_file" || { printf 'client asset missing the version constant: %s\n' "$client_file" >&2; static_failures=$((static_failures + 1)); }
    grep -q 'NOT read-only' "$client_file" || { printf 'client usage missing the doctor warning: %s\n' "$client_file" >&2; static_failures=$((static_failures + 1)); }
    grep -q -- '--timeout' "$client_file" || { printf 'client missing wait --timeout: %s\n' "$client_file" >&2; static_failures=$((static_failures + 1)); }
done
failures=$((failures + static_failures))

# --- the global option TOKENS are case-insensitive; their VALUES are not ------
# The Windows twin matches `--host`/`-h`/`--help`/`help`/`--version` with `-eq`,
# which is case-INSENSITIVE by language rule.  This client's `case` is
# case-sensitive, so `--VERSION`, `--HELP`, `HELP` and `-H` exited 2
# `unknown command` here while the twin answered with the version line / usage
# -- measured 2026-10-27, the same input giving 0 and 2.  Same class as the
# operation fold below and as sshp's first-token fold: normalise the token the
# parser matches, never the value beside it.
#
# Each variant is compared against its canonical spelling AND against the
# expected answer (exit 0, byte-identical stdout): the self-comparison alone
# would stay green if both spellings broke the same way.
global_variants=0
for global_case in '--VERSION:--version' '--Version:--version' '--HELP:--help' 'Help:--help' 'HELP:--help' '-H:-h'; do
    variant=${global_case%%:*}
    canonical=${global_case#*:}
    cases=$((cases + 1))
    global_variants=$((global_variants + 1))
    canonical_status=0
    variant_status=0
    AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host "$client" "$canonical" \
        >"$work/canonical.out" 2>"$work/canonical.err" || canonical_status=$?
    AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host "$client" "$variant" \
        >"$work/variant.out" 2>"$work/variant.err" || variant_status=$?
    if [ "$canonical_status" -ne 0 ] || [ "$variant_status" -ne 0 ]; then
        printf 'client %s: exit %s, canonical %s exits %s (both must be 0)\n' \
            "$variant" "$variant_status" "$canonical" "$canonical_status" >&2
        head -2 "$work/variant.err" >&2 || true
        failures=$((failures + 1))
    elif ! cmp -s "$work/canonical.out" "$work/variant.out"; then
        printf 'client %s: stdout differs from %s (the Windows twin accepts any case)\n' \
            "$variant" "$canonical" >&2
        failures=$((failures + 1))
    fi
done
# The other half of the rule: the fold must stop at the token.  `--host`'s
# VALUE is a hostname handed to ssh verbatim; folding it would silently connect
# to a different host.  Assert the recorded ssh argv carries the mixed-case
# value unchanged (ssh-argv writes one argv element per line).
: > "$work/global-host.argv"
: > "$work/global-host.argv.env"
AGENTQ_ARGV_CAPTURE="$work/global-host.argv" AGENTQ_SSH="$work/bin/ssh-argv" \
    AGENTQ_HOST=smoke-host "$client" --HOST MiXeD-Case-Host status \
    >/dev/null 2>&1 || true
cases=$((cases + 1))
if ! grep -qxF -- 'MiXeD-Case-Host' "$work/global-host.argv"; then
    printf 'client --HOST: the host value did not reach ssh verbatim: %s\n' \
        "$(tr '\n' '|' < "$work/global-host.argv")" >&2
    failures=$((failures + 1))
fi

# --- the host VALUE has a shape, not just a length ---------------------------
# This client only checked that the host was non-empty (`[ -n "$host" ]`) while
# the Windows twin refuses a host that is whitespace-only (IsNullOrWhiteSpace)
# or begins with a hyphen (StartsWith("-")).  Same argv, opposite answers --
# measured 2026-10-27: `--host -x` and `--host ' '` exited 2 on the twin and
# 255 here.  255 is the RETRYABLE transport class ("the connection failed, try
# again"), so a caller following the contract would retry a permanent typo
# forever, after paying an SSH round trip it did not need.
#
# The sharpest face is not the exit code: with a config file naming one host
# while AGENTQ_HOST held only spaces, the two clients reached DIFFERENT
# machines (measured 2026-10-27 -- this one ssh'd to " ", the twin to the
# configured host).  That case is asserted at the end of this block.
#
# The stub counts its own invocations.  The platform probe runs before argument
# validation in general, so "the host was refused" must also mean "no
# connection was opened": otherwise the probe budget is spent on an argument
# the client was always going to reject.  AGENTQ_REMOTE_PLATFORM bypasses the
# probe so the only possible call is the operation itself, which makes a
# non-zero count unambiguous.
cat > "$work/bin/ssh-count" <<'STUB'
#!/bin/sh
printf 'invoked\n' >> "${AGENTQ_SSH_COUNT:?}"
for argument in "$@"; do
    case "$argument" in
        *uname*) printf 'Linux\n'; exit 0 ;;
    esac
done
exit 255
STUB
chmod 700 "$work/bin/ssh-count"

host_shape_cases=0
# host_shape_run <uses-env(yes|no)> <host-value> [args...] -> sets host_status
host_shape_run() {
    local via_env=$1 value=$2
    shift 2
    : > "$work/ssh-count.log"
    host_status=0
    if [ "$via_env" = yes ]; then
        AGENTQ_SSH_COUNT="$work/ssh-count.log" AGENTQ_SSH="$work/bin/ssh-count" \
            AGENTQ_HOST="$value" AGENTQ_CONFIG="$work/absent-config" \
            AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
            AGENTQ_OPERATION_RETRY_DELAY=1 \
            "$client" "$@" >"$work/out" 2>"$work/err" || host_status=$?
    else
        AGENTQ_SSH_COUNT="$work/ssh-count.log" AGENTQ_SSH="$work/bin/ssh-count" \
            AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
            AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
            AGENTQ_OPERATION_RETRY_DELAY=1 \
            "$client" --host "$value" "$@" >"$work/out" 2>"$work/err" || host_status=$?
    fi
}
# expect_host_rejected <fragment> <label> <uses-env> <host-value>
expect_host_rejected() {
    local expected=$1 label=$2 via_env=$3 value=$4
    cases=$((cases + 1)); host_shape_cases=$((host_shape_cases + 1))
    host_shape_run "$via_env" "$value" status
    if [ "$host_status" -ne 2 ]; then
        printf 'client host [%s]: expected exit 2, got %s\n' "$label" "$host_status" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'client host [%s]: stderr does not contain %s\n' "$label" "$expected" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
    if [ -s "$work/ssh-count.log" ]; then
        printf 'client host [%s]: ssh was invoked %s time(s) for a locally refused host\n' \
            "$label" "$(tr -d ' ' < "$work/ssh-count.log" | wc -l)" >&2
        failures=$((failures + 1))
    fi
}
# expect_host_accepted <label> <uses-env> <host-value>
# The accept side is the boundary that stops a later "tighten the check" from
# silently widening to sshp's rule: sshp refuses whitespace ANYWHERE in the
# host, but both agentq twins hand an embedded space to ssh (measured
# 2026-10-27: both exit 255).  Pinning it keeps the two rules distinct.
expect_host_accepted() {
    local label=$1 via_env=$2 value=$3
    cases=$((cases + 1)); host_shape_cases=$((host_shape_cases + 1))
    host_shape_run "$via_env" "$value" status
    if [ "$host_status" -ne 255 ]; then
        printf 'client host [%s]: expected 255 (host handed to ssh), got %s: %s\n' \
            "$label" "$host_status" "$(head -2 "$work/err" | tr '\n' ' ')" >&2
        failures=$((failures + 1))
        return
    fi
    if [ ! -s "$work/ssh-count.log" ]; then
        printf 'client host [%s]: ssh was never invoked, yet exit was 255\n' "$label" >&2
        failures=$((failures + 1))
    fi
}
no_host='no SSH host configured; pass --host or set AGENTQ_HOST'
hyphen='SSH host must not begin with a hyphen'
expect_host_rejected "$hyphen"  'argv -x'      no -x
expect_host_rejected "$hyphen"  'argv -'       no -
expect_host_rejected "$hyphen"  'argv --'      no --
expect_host_rejected "$hyphen"  'argv -evil'   no -evil
expect_host_rejected "$no_host" 'argv space'   no ' '
expect_host_rejected "$no_host" 'argv tab'     no $'\t'
expect_host_rejected "$no_host" 'argv cr'      no $'\r'
expect_host_rejected "$no_host" 'argv nl'      no $'\n'
expect_host_rejected "$no_host" 'argv sp-nl'   no $' \n'
expect_host_rejected "$hyphen"  'env -x'       yes -x
expect_host_rejected "$no_host" 'env space'    yes ' '
expect_host_rejected "$no_host" 'env tab'      yes $'\t'
expect_host_rejected "$no_host" 'env cr'       yes $'\r'
expect_host_accepted 'argv embedded-space' no 'a b'
expect_host_accepted 'argv leading-space'  no ' a'

# The "different machines" face: a config file naming cfg-host, with
# AGENTQ_HOST holding only whitespace.  IsNullOrWhiteSpace falls back to the
# configured host; `:-` substitutes only for EMPTY, so this client used to send
# ssh to " ".  Assert the host that actually reached ssh.
printf 'AGENTQ_HOST=cfg-host\n' > "$work/host-config"
chmod 600 "$work/host-config"
cases=$((cases + 1)); host_shape_cases=$((host_shape_cases + 1))
: > "$work/cfg-host.argv"; : > "$work/cfg-host.argv.env"
AGENTQ_ARGV_CAPTURE="$work/cfg-host.argv" AGENTQ_SSH="$work/bin/ssh-argv" \
    AGENTQ_HOST=' ' AGENTQ_CONFIG="$work/host-config" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >/dev/null 2>"$work/err" || true
cfg_host_seen=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/cfg-host.argv")
if [ "$cfg_host_seen" != cfg-host ]; then
    printf 'client host [config fallback]: AGENTQ_HOST was whitespace-only and the config names cfg-host, but ssh was sent to [%s]; the Windows twin sends [cfg-host]\n' \
        "$cfg_host_seen" >&2
    failures=$((failures + 1))
fi

# The config FILE's value grammar: both clients take the LAST `AGENTQ_HOST=`
# line, so an EMPTY value is an assignment and a trailing blank line means "no
# host".  Pinned here as well as in smoke/12's twin table because this check
# runs on every platform while the twin block is NOT-covered on Windows.
printf 'AGENTQ_HOST=first-host\nAGENTQ_HOST=\n' > "$work/host-config-blank-last"
chmod 600 "$work/host-config-blank-last"
cases=$((cases + 1)); host_shape_cases=$((host_shape_cases + 1))
: > "$work/ssh-count.log"
host_status=0
env -u AGENTQ_HOST AGENTQ_SSH_COUNT="$work/ssh-count.log" \
    AGENTQ_SSH="$work/bin/ssh-count" AGENTQ_CONFIG="$work/host-config-blank-last" \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
    AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >"$work/out" 2>"$work/err" || host_status=$?
if [ "$host_status" -ne 2 ] || ! grep -qF 'no SSH host configured' "$work/err"; then
    printf 'client host [config blank-last]: a trailing empty AGENTQ_HOST= must mean "no host" (exit 2), got %s [%s]\n' \
        "$host_status" "$(head -1 "$work/err")" >&2
    failures=$((failures + 1))
elif [ -s "$work/ssh-count.log" ]; then
    printf '%s\n' 'client host [config blank-last]: ssh was invoked despite no resolved host' >&2
    failures=$((failures + 1))
fi
printf 'AGENTQ_HOST=alpha\nAGENTQ_HOST=beta\n' > "$work/host-config-two"
chmod 600 "$work/host-config-two"
cases=$((cases + 1)); host_shape_cases=$((host_shape_cases + 1))
: > "$work/two-host.argv"; : > "$work/two-host.argv.env"
AGENTQ_ARGV_CAPTURE="$work/two-host.argv" AGENTQ_SSH="$work/bin/ssh-argv" \
    AGENTQ_CONFIG="$work/host-config-two" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >/dev/null 2>"$work/err" || true
two_host_seen=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/two-host.argv")
if [ "$two_host_seen" != beta ]; then
    printf 'client host [config two-values]: the LAST AGENTQ_HOST= line must win (beta), ssh was sent to [%s]\n' \
        "$two_host_seen" >&2
    failures=$((failures + 1))
fi
# The floor: a block that silently stopped enumerating would report green on
# nothing, the blind-enumerator class this suite keeps re-learning.
if [ "$host_shape_cases" -lt 17 ]; then
    printf 'client host shape: only %s case(s) ran (expected at least 17); the enumeration broke\n' \
        "$host_shape_cases" >&2
    failures=$((failures + 1))
fi

# --- "is this executable?" must mean "a regular file you can exec" -----------
# `[ -x ]` tests the SEARCH BIT, which every directory has.  So a directory
# passed this client's AGENTQ_SSH and AGENTQ_JQ guards, and the failure that
# followed was not controlled at all -- measured 2026-10-27:
#   AGENTQ_SSH=<directory>  -> exit 126 with ZERO bytes on stdout AND stderr
#                              (126 is outside the documented contract
#                              0-6 / 42-45 / 124, and there is no diagnostic)
#   AGENTQ_JQ=<directory>   -> the shell's own line leaks to stderr
#                              ("line 1768: ...: is a directory") AND a
#                              perfectly VALID response is reported as
#                              "invalid JSON response" -- the blame lands on
#                              the server for a local misconfiguration
# The Windows twin refuses the same input with exit 2 and a controlled message
# ("not a regular non-reparse file").  The askpass guard in this same file
# already had the right ladder (-L, -e, -f, -x); these three siblings did not.
#
# `-f` FOLLOWS symlinks, so a symlink to a real executable still works -- that
# is deliberate: /usr/local/bin/ssh is a symlink on plenty of systems, and the
# accept-side case below pins it.
executable_shape_cases=0
mkdir -p "$work/exec-dir"
ln -sfn "$work/exec-dir" "$work/exec-dirlink" 2>/dev/null || true
ln -sf "$work/bin/ssh-count" "$work/exec-link" 2>/dev/null || true
# expect_not_a_regular_file <label> <env-var> <value>
expect_not_a_regular_file() {
    local label=$1 variable=$2 value=$3 status=0
    cases=$((cases + 1)); executable_shape_cases=$((executable_shape_cases + 1))
    : > "$work/ssh-count.log"
    host_status=0
    env AGENTQ_SSH_COUNT="$work/ssh-count.log" \
        AGENTQ_SSH="$work/bin/ssh-count" AGENTQ_HOST=smoke-host \
        AGENTQ_CONFIG="$work/absent-config" AGENTQ_REMOTE_PLATFORM=unix \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        "$variable=$value" \
        "$client" status >"$work/out" 2>"$work/err" || host_status=$?
    if [ "$host_status" -ne 2 ]; then
        printf 'client executable [%s]: expected exit 2, got %s\n' "$label" "$host_status" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "must be a regular file" "$work/err"; then
        printf 'client executable [%s]: stderr does not name the shape: %s\n' \
            "$label" "$(head -2 "$work/err" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    # A raw shell diagnostic is not an AgentQ diagnostic: the client withholds
    # raw remote output everywhere else, and "line NNNN: ...: is a directory"
    # is the shell's own text about a LOCAL path.
    if grep -qE 'is a directory|: line [0-9]+:' "$work/err"; then
        printf 'client executable [%s]: a raw shell diagnostic reached stderr: %s\n' \
            "$label" "$(head -2 "$work/err" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
    if [ -s "$work/ssh-count.log" ]; then
        printf 'client executable [%s]: ssh was invoked for a locally refused path\n' "$label" >&2
        failures=$((failures + 1))
    fi
}
expect_not_a_regular_file 'AGENTQ_SSH=directory' AGENTQ_SSH "$work/exec-dir"
expect_not_a_regular_file 'AGENTQ_SSH=symlink-to-dir' AGENTQ_SSH "$work/exec-dirlink"
expect_not_a_regular_file 'AGENTQ_JQ=directory' AGENTQ_JQ "$work/exec-dir"

# The JQ face has its own assertion: the refusal must happen BEFORE the remote
# response is judged, so a valid response can never be called invalid.
cases=$((cases + 1)); executable_shape_cases=$((executable_shape_cases + 1))
host_status=0
env AGENTQ_JQ="$work/exec-dir" AGENTQ_SSH="$work/bin/ssh-modes" \
    AGENTQ_ARGV_CAPTURE="$work/exec-jq.argv" AGENTQ_HOST=smoke-host \
    AGENTQ_CONFIG="$work/absent-config" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >"$work/out" 2>"$work/err" || host_status=$?
if [ "$host_status" -ne 2 ]; then
    printf 'client executable [AGENTQ_JQ=directory, valid response]: expected exit 2, got %s\n' \
        "$host_status" >&2
    failures=$((failures + 1))
elif grep -qF 'invalid JSON response' "$work/err"; then
    printf '%s\n' 'client executable [AGENTQ_JQ=directory, valid response]: the client blamed the REMOTE response for a local misconfiguration' >&2
    failures=$((failures + 1))
fi
if [ -s "$work/exec-jq.argv" ]; then
    printf '%s\n' 'client executable [AGENTQ_JQ=directory]: ssh was invoked before the parser was validated' >&2
    failures=$((failures + 1))
fi

# Accept side: a symlink to a real executable must still be accepted (exit 255
# here means "handed to the stub ssh"), or the fix would break /usr/local/bin
# style installs.
cases=$((cases + 1)); executable_shape_cases=$((executable_shape_cases + 1))
: > "$work/ssh-count.log"
host_status=0
AGENTQ_SSH_COUNT="$work/ssh-count.log" AGENTQ_SSH="$work/exec-link" \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
    AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >"$work/out" 2>"$work/err" || host_status=$?
if [ "$host_status" -ne 255 ]; then
    printf 'client executable [AGENTQ_SSH=symlink-to-executable]: expected 255 (accepted), got %s: %s\n' \
        "$host_status" "$(head -1 "$work/err")" >&2
    failures=$((failures + 1))
elif [ ! -s "$work/ssh-count.log" ]; then
    printf '%s\n' 'client executable [AGENTQ_SSH=symlink-to-executable]: ssh was never invoked, yet exit was 255' >&2
    failures=$((failures + 1))
fi
if [ "$executable_shape_cases" -lt 5 ]; then
    printf 'client executable shape: only %s case(s) ran (expected at least 5); the enumeration broke\n' \
        "$executable_shape_cases" >&2
    failures=$((failures + 1))
fi

# --- a file that passes `-x` and still cannot be EXECUTED --------------------
# `[ -x ]` is a PERMISSION, not a promise.  The directory cases above were only
# the first shape of that gap: three ordinary files pass the regular-file rule
# AND `-x`, then make the SHELL (not ssh, not jq) report 126/127 on every call.
# Measured 2026-10-30, all against HEAD:
#   AGENTQ_SSH=<such a file>  -> exit 126/127 with ZERO stderr on every
#                               operation (submit/cancel/remove too), and
#                               "unable to detect the remote platform; set
#                               AGENTQ_REMOTE_PLATFORM..." on the platform path
#                               -- advice that cannot help, since the platform
#                               was never the problem
#   AGENTQ_JQ=<such a file>   -> a VALID response reported as "invalid JSON
#                               response" (the SERVER blamed for a local
#                               misconfiguration) plus the shell's own line on
#                               stderr
# The Windows twin refuses both with exit 2 and "<variable> cannot be launched".
#
# The fix probes by RUNNING the file (`-V`: no connection for ssh, the version
# for jq) and refuses only when the shell's own 126/127 comes back, so the
# shapes are generated here rather than committed.
launch_shape_cases=0
for launch_shape in text missing-interpreter crlf-shebang; do
    case "$launch_shape" in
        text)                printf 'not an executable\n' > "$work/launch-$launch_shape" ;;
        missing-interpreter) printf '#!/nonexistent/interpreter\nexec /bin/true\n' > "$work/launch-$launch_shape" ;;
        crlf-shebang)        printf '#!/bin/sh\r\nexec /bin/true\r\n' > "$work/launch-$launch_shape" ;;
    esac
    chmod 755 "$work/launch-$launch_shape"
    # Both variables, same fixtures, same assertions: the ssh face runs against
    # a working stub so the failure cannot come from the transport, and the jq
    # face runs against a stub that returns a VALID response so a pass cannot
    # come from the validator never running.
    for launch_variable in AGENTQ_SSH AGENTQ_JQ; do
        cases=$((cases + 1)); launch_shape_cases=$((launch_shape_cases + 1))
        host_status=0
        if [ "$launch_variable" = AGENTQ_SSH ]; then
            env AGENTQ_SSH="$work/launch-$launch_shape" AGENTQ_HOST=smoke-host \
                AGENTQ_CONFIG="$work/absent-config" AGENTQ_REMOTE_PLATFORM=unix \
                AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
                "$client" status >"$work/out" 2>"$work/err" || host_status=$?
        else
            env AGENTQ_JQ="$work/launch-$launch_shape" AGENTQ_SSH="$work/bin/ssh-modes" \
                AGENTQ_ARGV_CAPTURE="$work/launch-jq.argv" \
                AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
                AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
                AGENTQ_OPERATION_RETRY_DELAY=1 \
                "$client" status >"$work/out" 2>"$work/err" || host_status=$?
        fi
        if [ "$host_status" -ne 2 ] || ! grep -qF "$launch_variable cannot be launched" "$work/err"; then
            printf 'client executable [%s=%s]: expected exit 2 naming the launch failure, got %s: %s\n' \
                "$launch_variable" "$launch_shape" "$host_status" \
                "$(head -2 "$work/err" | tr '\n' '|')" >&2
            failures=$((failures + 1))
        fi
        if grep -qF 'invalid JSON response' "$work/err"; then
            printf 'client executable [%s=%s]: the REMOTE response was blamed for a local misconfiguration\n' \
                "$launch_variable" "$launch_shape" >&2
            failures=$((failures + 1))
        fi
        if grep -qF 'unable to detect the remote platform' "$work/err"; then
            printf 'client executable [%s=%s]: the platform was blamed for a local misconfiguration\n' \
                "$launch_variable" "$launch_shape" >&2
            failures=$((failures + 1))
        fi
        if grep -qE 'is a directory|bad interpreter|: line [0-9]+:' "$work/err" &&
            [ "$launch_variable" = AGENTQ_SSH ]; then
            # Only for the ssh face: its stderr goes into the client's capture
            # file, so nothing about a LOCAL path may reach the caller.  The jq
            # face deliberately keeps jq's stderr -- that line is the ONLY
            # description of why a response failed validation (smoke/18 counts
            # the server's copies as a contract), and the shell's own line about
            # a local file is the price of it.  Asserting it absent there would
            # force the client to discard a diagnostic worth more than the
            # noise it removes.
            printf 'client executable [%s=%s]: a raw shell diagnostic reached stderr: %s\n' \
                "$launch_variable" "$launch_shape" \
                "$(head -2 "$work/err" | tr '\n' '|')" >&2
            failures=$((failures + 1))
        fi
    done
done

# The other direction, and the load-bearing one: a file that DOES run must never
# be refused, even when the remote command fails with the same 126/127 the shell
# uses for its own exec failures.  This fixture answers `-V` the way real
# OpenSSH does (exit 0) and every real call with 127 -- a missing remote
# dependency.  A refusal keyed on the status alone ("anything 126/127 is a local
# launch failure") passes every case above and fails here.
cat > "$work/ssh-remote-127" <<'STUB'
#!/bin/sh
case "$1" in
    -V) printf '%s\n' 'OpenSSH_9.9p1, LibreSSL 3.3.6' >&2; exit 0 ;;
esac
exit 127
STUB
chmod 755 "$work/ssh-remote-127"
cases=$((cases + 1)); launch_shape_cases=$((launch_shape_cases + 1))
host_status=0
env AGENTQ_SSH="$work/ssh-remote-127" AGENTQ_HOST=smoke-host \
    AGENTQ_CONFIG="$work/absent-config" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    "$client" status >"$work/out" 2>"$work/err" || host_status=$?
if [ "$host_status" -ne 127 ]; then
    printf 'client executable [working ssh, remote exit 127]: expected exit 127, got %s: %s\n' \
        "$host_status" "$(head -2 "$work/err" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
if grep -qF 'cannot be launched' "$work/err"; then
    printf '%s\n' 'client executable [working ssh, remote exit 127]: a working ssh was refused as a local launch failure' >&2
    failures=$((failures + 1))
fi

# EVERY operation, not just `status`.  The refusal lives in `run_ssh_logged`,
# the funnel every operation, submit and mutation call goes through -- but that
# is a claim about the code, and the measurement that produced it was: HEAD
# exits 126/127 with NO stderr at all for submit, cancel and remove, while
# status at least printed the (misleading) platform advice.  A fix wired into
# one caller's diagnostic branch would pass the case above and leave the other
# seven silent, so the surface is enumerated and each one must answer the same
# way.  `wait --timeout` is included because it invokes ssh through
# run_wait_ssh_with_timeout, NOT through run_ssh_logged -- a second funnel.
launch_operation_cases=0
for launch_operation in 'status' 'lookup Abcdefghij1234567' 'logs 1' 'wait 1' \
        'wait 1 --timeout 5' 'cancel 1' 'remove 1' 'doctor' 'submit --workdir /tmp --request-id Abcdefghij1234567 -- true'; do
    cases=$((cases + 1)); launch_operation_cases=$((launch_operation_cases + 1))
    host_status=0
    # shellcheck disable=SC2086 # the fixture IS the argv list; each value is
    # a literal here, never user input.
    env AGENTQ_SSH="$work/launch-text" AGENTQ_HOST=smoke-host \
        AGENTQ_CONFIG="$work/absent-config" AGENTQ_REMOTE_PLATFORM=unix \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_PLATFORM_PROBE_CACHE=off \
        "$client" $launch_operation >"$work/out" 2>"$work/err" || host_status=$?
    if [ "$host_status" -ne 2 ] || ! grep -qF 'AGENTQ_SSH cannot be launched' "$work/err"; then
        printf 'client executable [AGENTQ_SSH=text, operation %s]: expected exit 2 naming the launch failure, got %s: %s\n' \
            "$launch_operation" "$host_status" "$(head -2 "$work/err" | tr '\n' '|')" >&2
        failures=$((failures + 1))
    fi
done
if [ "$launch_operation_cases" -lt 9 ]; then
    printf 'client executable launch shape: only %s operation case(s) ran (expected 9); the enumeration broke\n' \
        "$launch_operation_cases" >&2
    failures=$((failures + 1))
fi
if [ "$launch_shape_cases" -lt 7 ]; then
    printf 'client executable launch shape: only %s case(s) ran (expected at least 7); the enumeration broke\n' \
        "$launch_shape_cases" >&2
    failures=$((failures + 1))
fi

# --- mode forwarding and response validation ---------------------------------
# Each case runs against ssh-modes and asserts BOTH that the run succeeds (the
# response passed the client's validation for that mode) and that the mode
# actually travelled on the remote command.  The pair is what makes these
# non-vacuous: an empty response would fail the exit code, and a client that
# dropped the flag would fail the fragment check.
# expect_mode_ok <expected-raw-args> <label> [args...]
#
# `expected-raw-args` is the EXACT quoted argument list that must follow the
# final `agentq_run ` in the raw remote command -- not a substring.  Until
# 2026-10-16 this was a `grep -qF` substring test, and `agentq_run status` is a
# substring of `agentq_run status --summary`, so a bare `status` that wrongly
# appended `--summary` passed every mode case here (and smoke/12's
# `grep -q -- '--summary'`).  The comparison is on the RAW argv the client handed
# to ssh -- the last line of `modes.argv` -- because the stub's `tr -d "'"`
# de-quoting is NOT the inverse of the client's `quote_remote` (`'\''`) and
# would corrupt any argument carrying a single quote; the raw string has no
# such ambiguity.
expect_mode_ok() {
    local expected=$1
    local label=$2
    shift 2
    cases=$((cases + 1))
    : > "$work/modes.argv"
    : > "$work/modes.argv.cmd"
    local status=0
    AGENTQ_ARGV_CAPTURE="$work/modes.argv" AGENTQ_SSH="$work/bin/ssh-modes" \
        AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        "$client" "$@" >"$work/modes.out" 2>"$work/modes.err" || status=$?
    if [ "$status" -ne 0 ]; then
        printf 'client %s: expected exit 0, got %s: %s\n' \
            "$label" "$status" "$(head -1 "$work/modes.err")" >&2
        failures=$((failures + 1))
        return
    fi
    local invocation
    invocation=$(tail -n 1 "$work/modes.argv")
    invocation=${invocation##*agentq_run }
    if [ "$invocation" != "$expected" ]; then
        printf 'client %s: the remote invocation was %s, expected %s\n' \
            "$label" "$invocation" "$expected" >&2
        failures=$((failures + 1))
    fi
}
expect_mode_ok "'status'"                               status        status
expect_mode_ok "'status' '--summary'"                   status-summary status --summary
expect_mode_ok "'status' '--task' '3'"                  status-task   status --task 3
expect_mode_ok "'doctor'"                               doctor        doctor
expect_mode_ok "'doctor' '--full'"                      doctor-full   doctor --full
expect_mode_ok "'remove' '--label' 'smoke' '--confirm'" remove-label  remove --label smoke --confirm
expect_mode_ok "'wait' '3'"                             wait-plain    wait 3

# wait --timeout: the budget is CLIENT-side, and two things must hold at once.
# Neither was checked before 2026-10-16, which is how both halves of this
# feature shipped broken:
#   1. the flag must NOT travel on the remote command -- the server's wait arm
#      takes exactly one task id, so a forwarded flag makes it answer
#      `wait requires one task id` with exit 2 (measured against the real
#      server: `agentq-server wait 5 --timeout 60` -> exit 2,
#      reason=protocol_error).  The stub mirrors that contract.
#   2. the remote command must still be VALID SHELL.  The unix remote command
#      BEGINS with a function definition, and a `timeout <N>s` prefix turns
#      that into a syntax error -- `timeout 5s f() {...}` gives "syntax error
#      near unexpected token `('" on dash and bash -- so the remote executed
#      nothing and every timed wait died with an empty response.  `sh -n` on
#      the exact command string is the check: it accepts the `sh -c` form and
#      rejects the bare prefix form.
cases=$((cases + 1))
: > "$work/modes.argv"
: > "$work/modes.argv.cmd"
wait_status=0
AGENTQ_ARGV_CAPTURE="$work/modes.argv" AGENTQ_SSH="$work/bin/ssh-modes" \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$client" wait 3 --timeout 60 >"$work/modes.out" 2>"$work/modes.err" || wait_status=$?
if [ "$wait_status" -ne 0 ]; then
    printf 'client wait --timeout: expected exit 0, got %s: %s\n' \
        "$wait_status" "$(head -1 "$work/modes.err")" >&2
    failures=$((failures + 1))
fi
if grep -qF -- '--timeout' "$work/modes.argv.cmd"; then
    printf 'client wait --timeout: the budget leaked onto the remote command (the server takes one task id); command was: %s\n' \
        "$(tr '\n' '|' < "$work/modes.argv.cmd")" >&2
    failures=$((failures + 1))
fi
# The last argument ssh receives IS the remote command.
wait_remote_command=$(tail -n 1 "$work/modes.argv")
if ! printf '%s\n' "$wait_remote_command" | sh -n 2>"$work/modes.parse.err"; then
    printf 'client wait --timeout: the remote command is not valid shell: %s\n' \
        "$(head -1 "$work/modes.parse.err")" >&2
    failures=$((failures + 1))
fi
# The budget must be PRESENT on the remote command (as the leading assignment),
# and the remote wrapper must actually consume it.  Behaviour beyond this point
# -- that the remote wait is really bounded -- is only observable on a real unix
# target and is NOT claimed here; this pins the two things the client owns.
#
# The wrapper check is the exact exec form, not a `grep -q AGENTQ_WAIT_BUDGET`:
# the variable name also appears in the assignment above and in the surrounding
# comments, so a name-only grep stays green when the handling is deleted
# (measured 2026-10-16 -- the mutation that removed the exec line passed).
if ! grep -qF 'AGENTQ_WAIT_BUDGET=60s;' "$work/modes.argv.cmd"; then
    printf 'client wait --timeout: the remote command does not carry the budget assignment; command was: %s\n' \
        "$(tr '\n' '|' < "$work/modes.argv.cmd")" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'exec timeout "$AGENTQ_WAIT_BUDGET" "$agentq_server" "$@"' "$client"; then
    printf '%s\n' 'client wait --timeout: the remote wrapper does not exec the server under timeout with the budget, so the remote wait is unbounded' >&2
    failures=$((failures + 1))
fi

# submit --stdin-script: the script arrives as ONE base64 argument that decodes
# back to the script itself.  Asserting the decode (not just the exit code) is
# what proves the payload is the script and not, say, an empty or re-encoded
# copy -- the same class of blindness smoke/14 cannot see through.
cases=$((cases + 1))
: > "$work/modes.argv"
: > "$work/modes.argv.cmd"
stdin_script_text='printf hello-from-stdin'
submit_status=0
printf '%s\n' "$stdin_script_text" |
    AGENTQ_ARGV_CAPTURE="$work/modes.argv" AGENTQ_SSH="$work/bin/ssh-modes" \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$client" submit --workdir /tmp --stdin-script >"$work/submit.out" 2>"$work/submit.err" || submit_status=$?
if [ "$submit_status" -ne 0 ]; then
    printf 'client stdin-script: expected exit 0, got %s: %s\n' \
        "$submit_status" "$(head -1 "$work/submit.err")" >&2
    failures=$((failures + 1))
else
    submit_b64=$(sed -n 's/.*printf %s \([A-Za-z0-9+/=]*\) | base64 -d | sh.*/\1/p' "$work/modes.argv.cmd" | head -1)
    submit_decoded=$(printf '%s' "$submit_b64" | base64 -d 2>/dev/null)
    if [ -z "$submit_b64" ]; then
        printf 'client stdin-script: the remote command carried no base64 payload; command was: %s\n' \
            "$(tr '\n' '|' < "$work/modes.argv.cmd")" >&2
        failures=$((failures + 1))
    elif [ "$submit_decoded" != "$stdin_script_text" ]; then
        printf 'client stdin-script: the payload decodes to %s, not the script\n' \
            "$submit_decoded" >&2
        failures=$((failures + 1))
    fi
fi
# The local guards: a terminal on stdin cannot supply a script, and an empty
# pipe is a mistake worth catching before the round trip.
expect_rejected 'submit --stdin-script takes the script from standard input; drop the command after --' \
    submit --workdir /tmp --stdin-script -- true
cases=$((cases + 1))
empty_script_status=0
AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$client" submit --workdir /tmp --stdin-script </dev/null >"$work/empty.out" 2>"$work/empty.err" || empty_script_status=$?
if [ "$empty_script_status" -ne 2 ] || ! grep -qF 'received no script on standard input' "$work/empty.err"; then
    printf 'client stdin-script: an empty stdin exited %s, expected 2 with the empty-script message\n' \
        "$empty_script_status" >&2
    failures=$((failures + 1))
fi

# ...and the decode guard must be on the TARGET and BEFORE the pipeline.  0.1.13
# fixed that fail-open (remote `base64` absent -> `base64 -d` dies, the LAST
# stage `sh` reads empty input and exits 0, and the task lands Done/Success
# having run nothing) -- and until 2026-10-16 NOTHING pinned it: the extraction
# regex above matches `printf %s <b64> | base64 -d | sh` whether or not a guard
# precedes it.  Measured: deleting the guard from the asset left this check at
# 38 green cases, so a regression to the exact defect 0.1.13 fixed would ship
# silently.  The lock is behavioural, on the exact remote command string the
# client emitted: run it on a target whose PATH has `sh` but NOT `base64`, then
# with base64 present.  What it pins is the terminal state, not a token's
# position: a base64-less target must NOT be able to produce a silent success.
# Measured shapes -- deleting the guard and attaching it as a pipeline recovery
# clause (`... | sh || { command -v base64 ... || exit 2; }`) both leave exit 0
# and both red here; an UNCONDITIONAL append (`... | sh; command -v base64 ...`)
# exits 2 and passes, which is correct -- it ends in the same failed task.
cases=$((cases + 1))
: > "$work/guard.argv"
guard_script='printf hello-from-stdin'
guard_status=0
printf '%s\n' "$guard_script" |
    AGENTQ_ARGV_CAPTURE="$work/guard.argv" AGENTQ_SSH="$work/bin/ssh-modes" \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$client" submit --workdir /tmp --stdin-script >"$work/guard.out" 2>"$work/guard.err" || guard_status=$?
guard_remote_command=$(tail -n 1 "$work/guard.argv")
if [ "$guard_status" -ne 0 ] || [ -z "$guard_remote_command" ]; then
    printf 'client stdin-script guard: could not capture the remote command (exit %s): %s\n' \
        "$guard_status" "$(head -1 "$work/guard.err")" >&2
    failures=$((failures + 1))
else
    # A fake server at the path the remote command hardcodes lets the captured
    # string run LOCALLY as the exact bytes the client would send: the wrapper
    # is skipped and the payload after `--` is executed, so the guard's
    # behaviour on a base64-less target is observed rather than inferred.
    guard_path="$work/guard-path"
    guard_home="$work/guard-home"
    mkdir -p "$guard_path" "$guard_home/.local/bin"
    ln -s /bin/sh "$guard_path/sh"
    cat > "$guard_home/.local/bin/agentq" <<'GUARDSERVER'
#!/bin/sh
while [ "$#" -gt 0 ]; do [ "$1" = "--" ] && shift && break; shift; done
exec "$@"
GUARDSERVER
    chmod 700 "$guard_home/.local/bin/agentq"
    guard_absent_status=0
    env -i PATH="$guard_path" HOME="$guard_home" /bin/sh -c "$guard_remote_command" \
        >"$work/guard-target.out" 2>"$work/guard-target.err" || guard_absent_status=$?
    if [ "$guard_absent_status" -ne 2 ]; then
        printf 'client stdin-script guard: on a target WITHOUT base64 the remote command exited %s; it must exit 2, or the task lands Done/Success after running nothing: %s\n' \
            "$guard_absent_status" "$(head -1 "$work/guard-target.err")" >&2
        failures=$((failures + 1))
    elif ! grep -qF -- '--stdin-script requires base64 on the target' "$work/guard-target.err"; then
        printf 'client stdin-script guard: the target refusal does not name base64: %s\n' \
            "$(head -1 "$work/guard-target.err")" >&2
        failures=$((failures + 1))
    fi
    guard_present_status=0
    env -i PATH="$guard_path:/usr/bin:/bin" HOME="$guard_home" /bin/sh -c "$guard_remote_command" \
        >"$work/guard-present.out" 2>"$work/guard-present.err" || guard_present_status=$?
    if [ "$guard_present_status" -ne 0 ] || [ "$(cat "$work/guard-present.out")" != "hello-from-stdin" ]; then
        printf 'client stdin-script guard: with base64 present the remote command exited %s and printed [%s], expected the script to run (exit 0, hello-from-stdin)\n' \
            "$guard_present_status" "$(head -1 "$work/guard-present.out")" >&2
        failures=$((failures + 1))
    fi
fi

expect_rejected 'unknown command: bogus' bogus
expect_rejected 'lookup requires one request id' lookup
expect_rejected 'request id must be'     lookup abc
expect_rejected 'wait requires a task id and optional --timeout <seconds>' wait
expect_rejected 'task id must be a non-negative integer' wait abc
expect_rejected 'wait accepts only --timeout <seconds>' wait 1 --nope 3
expect_rejected '--timeout must be a positive integer' wait 1 --timeout abc
expect_rejected 'logs requires a task id' logs
expect_rejected 'task id must be a non-negative integer' logs abc
expect_rejected '--tail must be a positive integer or all' logs 1 --tail x
# A leading zero is not "a positive integer", in either client.  Measured
# 2026-10-21: this client accepted `05` (the value was forwarded and the
# request reached ssh) while the Windows twin refused it -- the same
# one-shape-two-answers drift as the numeric env vars above.  `all` and a plain
# integer must stay accepted; the accepted side is pinned by the usage cases.
expect_rejected '--tail must be a positive integer or all' logs 1 --tail 05
expect_rejected '--tail must be a positive integer or all' logs 1 --tail 00
# `all` is a VALUE forwarded verbatim to the server, and the server compares it
# with `[ "$2" = all ]` -- case-sensitive.  So a case variant is NOT accepted
# here, and the Windows twin now refuses it too (it used `-eq` and forwarded
# `ALL`, paying a round trip to be told what it could have said locally --
# measured 2026-10-27).  The tokens around it stay case-insensitive.
expect_rejected '--tail must be a positive integer or all' logs 1 --tail ALL
expect_rejected '--tail must be a positive integer or all' logs 1 --tail All
expect_rejected 'cancel requires one task id' cancel
expect_rejected 'task id must be a non-negative integer' cancel abc
expect_rejected 'remove requires one task id' remove
expect_rejected 'task id must be a non-negative integer' remove abc
expect_rejected 'doctor accepts --full or no arguments' doctor extra
expect_rejected 'status accepts --summary or --task' status extra
expect_rejected 'remove --label requires --confirm' remove --label smoke
expect_rejected 'remove --label requires --confirm' remove --label smoke --nope
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

# cancel exit 4: the CODE is the contract, the body is decoration.
# Until 2026-10-21 the client replaced 4 with 2 whenever the body failed its
# `cancellation_pending` validation -- i.e. it reported "protocol/parameter
# error, fix your arguments and retry" for the one state whose documented
# meaning is "the server cannot decide safely; STOP, do not retry".  Both
# directions are asserted: an unvalidated body must keep 4 and must NOT reach
# stdout, and a validated one must keep 4 and be printed.
cases=$((cases + 1))
cancel4_stub="$work/bin/ssh-cancel4-bad"
cat > "$cancel4_stub" <<'STUB'
#!/bin/sh
printf '%s\n' '{"task_id":1,"state":"bogus_state"}'
exit 4
STUB
chmod 700 "$cancel4_stub"
cancel4_status=0
AGENTQ_SSH="$cancel4_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" cancel 1 >"$work/cancel4.out" 2>"$work/cancel4.err" || cancel4_status=$?
if [ "$cancel4_status" -ne 4 ]; then
    printf 'client cancel with exit 4 and an unvalidated body exited %s, expected 4 (4 means STOP; 2 reads as "fix your arguments and retry")\n' \
        "$cancel4_status" >&2
    failures=$((failures + 1))
fi
if [ -s "$work/cancel4.out" ]; then
    printf 'client cancel printed an unvalidated body on stdout: %s\n' \
        "$(tr '\n' '|' < "$work/cancel4.out")" >&2
    failures=$((failures + 1))
fi

cancel4_ok_stub="$work/bin/ssh-cancel4-ok"
cases=$((cases + 1))
cat > "$cancel4_ok_stub" <<'STUB'
#!/bin/sh
printf '%s\n' '{"task_id":1,"state":"cancellation_pending","cancellation_requested_at":"2026-10-21T00:00:00Z"}'
exit 4
STUB
chmod 700 "$cancel4_ok_stub"
cancel4_ok_status=0
AGENTQ_SSH="$cancel4_ok_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" cancel 1 >"$work/cancel4-ok.out" 2>"$work/cancel4-ok.err" || cancel4_ok_status=$?
if [ "$cancel4_ok_status" -ne 4 ]; then
    printf 'client cancel with exit 4 and a valid cancellation_pending body exited %s, expected 4\n' \
        "$cancel4_ok_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF '"state":"cancellation_pending"' "$work/cancel4-ok.out"; then
    printf 'client cancel did not forward the validated cancellation_pending body: %s\n' \
        "$(tr '\n' '|' < "$work/cancel4-ok.out")" >&2
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
# The status is deliberately NOT captured.  These three cases assert on what
# reaches stderr, and `|| true` is the honest form: a `probe_status=$?` here
# would be a dead variable -- this very file's shellcheck lock (below) reports
# SC2034 for exactly that shape, and in the assets it is how the POSIX client's
# `wait_ssh_status=$?` defect read: like a status about to be checked.
AGENTQ_SSH="$probe_stub" AGENTQ_HOST=smoke-host \
    "$client" status >"$work/probe.out" 2>"$work/probe.err" || true
if grep -qF 'lock_contention' "$work/probe.err"; then
    printf 'the platform probe let remote-controlled text reach the caller stderr: %s\n' \
        "$(tr '\n' '|' < "$work/probe.err")" >&2
    failures=$((failures + 1))
fi
if grep -qF 'remote failure reason' "$work/probe.err"; then
    printf '%s\n' 'the platform probe forwarded a forged reason line' >&2
    failures=$((failures + 1))
fi

# A dead transport must not be probed twice.  The local probe retries a
# transport failure (254) a bounded number of times, then returns 255; the
# Windows probe used to run NEXT regardless, spending a second full retry
# budget against the same dead host -- up to ~70s more -- and could not change
# the answer.  The stub counts invocations, so "the second probe did not run"
# is asserted directly rather than inferred from timing.  The stub writes the
# transport line to the -E log, exactly as real ssh does (the client classifies
# from that file, not from stderr).
cases=$((cases + 1))
transport_stub="$work/bin/ssh-transport-dead"
cat > "$transport_stub" <<'STUB'
#!/bin/sh
prev=''
for argument in "$@"; do
    if [ "$prev" = '-E' ]; then log_path=$argument; fi
    prev=$argument
done
printf 'x\n' >> "$AGENTQ_TRANSPORT_COUNT_FILE"
printf 'ssh: connect to host smoke-host port 22: Connection refused\r\n' > "${log_path:-/dev/null}"
exit 255
STUB
chmod 700 "$transport_stub"
transport_count="$work/transport-count"
: > "$transport_count"
transport_status=0
AGENTQ_TRANSPORT_COUNT_FILE="$transport_count" \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_SSH="$transport_stub" AGENTQ_HOST=smoke-host \
    "$client" status >"$work/transport.out" 2>"$work/transport.err" || transport_status=$?
transport_calls=$(wc -l < "$transport_count" | tr -d ' ')
if [ "$transport_status" -ne 255 ]; then
    printf 'client status against a dead transport exited %s, expected 255\n' "$transport_status" >&2
    failures=$((failures + 1))
fi
if [ "$transport_calls" -ne 2 ]; then
    printf 'client made %s probe call(s) against a dead transport, expected 2 (initial + one retry; the Windows probe must not repeat the same failing transport)\n' \
        "$transport_calls" >&2
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
# Same as the probe-forge case above: the assertion is on the diagnostic text,
# so the exit status is discarded with `|| true` rather than captured into a
# variable nothing reads (SC2034).
AGENTQ_SSH="$auth_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/auth.out" 2>"$work/auth.err" || true
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
printf '#!/bin/sh\nprintf "pw\\n"\n' > "$work/askpass-program"
chmod 700 "$work/askpass-program"
AGENTQ_ASKPASS="$work/askpass-program" \
    AGENTQ_SSH="$auth_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    "$client" status >"$work/auth2.out" 2>"$work/auth2.err" || true
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
# AGENTQ_PLATFORM_PROBE_CACHE_TTL and AGENTQ_WAIT_TIMEOUT were missing from this
# list until 2026-10-21 -- and that gap is exactly how the two clients drifted:
# the POSIX side refused a bad TTL while the Windows side silently fell back to
# the default 604800, i.e. `..._CACHE_TTL=abc` quietly meant "seven days".  A
# contract shared by two implementations needs a case per variable, otherwise
# only the implementation you happen to test is pinned.
for variable in AGENTQ_SUBMIT_RETRY_ATTEMPTS AGENTQ_SUBMIT_RETRY_DELAY \
    AGENTQ_OPERATION_RETRY_ATTEMPTS AGENTQ_OPERATION_RETRY_DELAY \
    AGENTQ_PLATFORM_PROBE_TIMEOUT AGENTQ_PLATFORM_PROBE_CACHE_TTL; do
    # Three shapes per variable.  `0` was the only case until 2026-10-21, and
    # it cannot see the range defect: every one of these values feeds a
    # `[ ... -ge/-gt ... ]` comparison or a `sleep`, and a value past the
    # shell's integer range does not fail that test -- dash prints "Illegal
    # number" and the comparison reads as FALSE, so the probe deadline never
    # fires and the retry limit never fires.  The over-range case is what pins
    # the bound; the `0` case alone stayed green on an unbounded validator.
    #
    # `05` pins the OTHER end of the same contract.  Measured 2026-10-21: the
    # POSIX client accepted `05`/`007` while the Windows one refused them
    # (`^[1-9][0-9]*$`), and the two also disagreed on 1000000000 and
    # 2147483647 -- the POSIX side stopped at nine digits, so a value the
    # Windows client accepted was refused here and vice versa.  Both now take
    # exactly `^[1-9][0-9]*$` up to 2147483647, and this case is what keeps them
    # there: a leading zero is not a positive integer in either client.
    for env_value in 0 99999999999999999999 05; do
        env_rejections=$((env_rejections + 1))
        status=0
        env "$variable=$env_value" AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
            "$client" --help >"$work/env.out" 2>"$work/env.err" || status=$?
        if [ "$status" -ne 2 ] || ! grep -qF "$variable must be a positive integer" "$work/env.err"; then
            printf '%s\n' "$variable=$env_value was not rejected as a positive integer" >&2
            failures=$((failures + 1))
        fi
    done
done

# AGENTQ_WAIT_TIMEOUT is validated on the WAIT path, not at startup (both
# clients do it there, so the loop above cannot see it: `--help` never reaches
# the check).  Driven through a stub ssh that fails immediately -- the refusal
# happens before ssh is consulted, so the stub never has to model a session.
wait_timeout_stub="$work/bin/ssh-wait-timeout"
printf '%s\n' '#!/bin/sh' 'exit 255' > "$wait_timeout_stub"
chmod 700 "$wait_timeout_stub"
env_rejections=$((env_rejections + 1))
status=0
AGENTQ_WAIT_TIMEOUT=0 AGENTQ_SSH="$wait_timeout_stub" AGENTQ_HOST=smoke-host \
    AGENTQ_REMOTE_PLATFORM=unix "$client" wait 1 >"$work/env.out" 2>"$work/env.err" || status=$?
if [ "$status" -ne 2 ] || ! grep -qF 'AGENTQ_WAIT_TIMEOUT must be a positive integer' "$work/env.err"; then
    printf '%s\n' 'AGENTQ_WAIT_TIMEOUT=0 was not rejected on the wait path as a positive integer' >&2
    failures=$((failures + 1))
fi

# AGENTQ_REMOTE_PLATFORM is matched case-insensitively, like the Windows
# client's `switch` (a language rule there, a written-out pattern here).
# Measured 2026-10-21: `AUTO`/`Unix` were accepted by the Windows client and
# refused by this one, so the same instruction meant "probe as usual" on one
# platform and "argument error" on the other.  The upper-case forms must now
# reach ssh (255 through this stub) exactly like the lower-case ones; an
# invalid value must still be refused, which the last row pins.
for platform_case in auto unix windows AUTO Unix WINDOWS; do
    env_rejections=$((env_rejections + 1))
    platform_status=0
    AGENTQ_REMOTE_PLATFORM="$platform_case" AGENTQ_SSH="$wait_timeout_stub" \
        AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_PLATFORM_PROBE_CACHE=off \
        "$client" status >"$work/env.out" 2>"$work/env.err" || platform_status=$?
    # NOT "must be 255": `windows` also runs the launcher protocol probe, whose
    # own failure code is legitimate.  The defect being pinned is the argument
    # error -- 2 with the switch's message -- which is what a case-sensitive
    # match produced for `AUTO`/`Unix`.
    if [ "$platform_status" -eq 2 ] && grep -qF 'AGENTQ_REMOTE_PLATFORM must be auto, unix, or windows' "$work/env.err"; then
        printf 'AGENTQ_REMOTE_PLATFORM=%s was refused as an invalid value; it is accepted case-insensitively\n' \
            "$platform_case" >&2
        failures=$((failures + 1))
    fi
done
env_rejections=$((env_rejections + 1))
platform_bad_status=0
AGENTQ_REMOTE_PLATFORM=bogus AGENTQ_SSH="$work/bin/ssh" AGENTQ_HOST=smoke-host \
    "$client" status >"$work/env.out" 2>"$work/env.err" || platform_bad_status=$?
if [ "$platform_bad_status" -ne 2 ] || ! grep -qF 'AGENTQ_REMOTE_PLATFORM must be auto, unix, or windows' "$work/env.err"; then
    printf '%s\n' 'AGENTQ_REMOTE_PLATFORM=bogus was not refused with the controlled message' >&2
    failures=$((failures + 1))
fi

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
while read -r _tag launcher_count launcher_bytes _launcher_op; do
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
        if ! grep -qxF -- "$required" <<< "$submit_payload_vector"; then
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

# --- unsupported platform under a STRICT POSIX shell -------------------------
# The client's shebang is `#!/bin/sh`.  On macOS /bin/sh is bash (which
# accepts `$'\n'`, `${x//pat/}` and `${x:0:N}` even in POSIX mode), but on
# Debian/Ubuntu /bin/sh is dash, which rejects all three with `Bad
# substitution` and exits 2 BEFORE printing anything.  The offending lines are
# the platform-hint sanitiser in the "neither probe identified the platform"
# branch (client/unix/agentq: `local_platform_hint=${...%%$'\n'*}` and the
# two following expansions) -- remote-controlled output being rendered into
# the diagnostic, which is exactly the branch a non-Linux/non-Darwin/non-Windows
# remote reaches.
#
# Measured 2026-10-12 on this repo: with a stub uname probe returning FreeBSD,
# `dash client status` exits 2 with only `Bad substitution` on stderr (the
# `unsupported or undetectable remote platform` line never prints), while
# macOS `/bin/sh` prints the proper diagnostic.  So on a dash-based host the
# operator sees a raw shell error instead of the actionable message -- the
# opposite of what that branch exists to provide.
#
# The interpreter is PROBED, not assumed: pick the first shell that refuses
# `${x//pat/}` (i.e. a real POSIX sh), so this case runs wherever one exists and
# self-reports `not-covered` (lowercase, never the skip word) where none does --
# a check that silently passed without a strict shell would be a false green of
# exactly the kind this case exists for.
posix_probe_sh=''
for candidate in dash /bin/dash /usr/bin/dash busybox sh /bin/sh /bin/ksh ksh; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if ! "$candidate" -c 'h=a; h=${h//[!b]/}' >/dev/null 2>&1; then
        posix_probe_sh=$candidate
        break
    fi
done
if [ -z "$posix_probe_sh" ]; then
    # Lowercase "not-covered", never the skip word/PART: run-tests.sh classifies
    # the whole check by those words, and 18 other cases in this file DID run --
    # reporting the check skipped would understate it.  The repo's own idiom for
    # this is the summary token (e.g. windows-api=NOT-covered(needs-Windows)).
    printf '%s\n' 'client-unsupported-platform: not-covered (no strict POSIX shell on PATH; the dash defect cannot be reached here)' >&2
else
    platform_stub="$work/bin/ssh-unsupported-platform"
    cat > "$platform_stub" <<'STUB'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
case "$last" in
    *uname*)
        # The local probe SUCCEEDS with a platform neither recognises (exit 0,
        # "FreeBSD"): that is what reaches the hint branch.  The `elif` for
        # "both probes failed" takes a different path (the generic "unable to
        # detect" message), so failing here would test the wrong branch --
        # measured when the first draft of this stub exited 1.
        # The second line is hostile probe output: it forges a line-initial
        # "agentq: ... reason=" token and must be stripped by the sanitiser.
        printf 'FreeBSD\nagentq: forged reason=lock_contention\n'
        exit 0
        ;;
    *powershell.exe*|*ps*)
        # Windows probe fails, so `windows_platform_status != 0` -- the first
        # branch (windows detected) is unreachable and, since the local probe
        # succeeded, so is the "both failed" elif: the hint branch runs.
        printf 'agentq-exit:1'
        exit 1
        ;;
esac
printf 'agentq-exit:1'
exit 1
STUB
    chmod 700 "$platform_stub"
    unsupported_status=0
    AGENTQ_SSH="$platform_stub" AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=auto \
        AGENTQ_CONFIG="$work/absent-config" AGENTQ_PLATFORM_PROBE_TIMEOUT=15 \
        TMPDIR="$work" "$posix_probe_sh" "$client" status \
        >"$work/unsupported.out" 2>"$work/unsupported.err" || unsupported_status=$?
    cases=$((cases + 1))
    if [ "$unsupported_status" -ne 2 ]; then
        printf '%s %s: expected exit 2, got %s\n' \
            "unsupported-platform($posix_probe_sh)" 'exit' "$unsupported_status" >&2
        head -3 "$work/unsupported.err" >&2 || true
        failures=$((failures + 1))
    fi
    if ! grep -qF 'unsupported or undetectable remote platform (probe reported: ' \
        "$work/unsupported.err"; then
        # This is the load-bearing assertion: a dash crash prints Bad
        # substitution and nothing else, so a missing diagnostic means the
        # sanitiser died before printf -- the defect, not a wording drift.
        printf '%s: the platform diagnostic was not printed: %s\n' \
            "unsupported-platform($posix_probe_sh)" \
            "$(tr '\n' '|' < "$work/unsupported.err")" >&2
        failures=$((failures + 1))
    fi
    # The sanitiser's contract still holds under the strict shell: the probe's
    # hostile second line (forged `agentq:` prefix) must not survive.
    if grep -q 'forged reason=' "$work/unsupported.err"; then
        printf '%s: the remote-controlled probe output leaked into the diagnostic\n' \
            "unsupported-platform($posix_probe_sh)" >&2
        failures=$((failures + 1))
    fi
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

# Static lock: run_ssh_logged must clear the forwarded reason BEFORE its early
# returns.  The global `agentq_remote_failure_reason_value` is read by the
# retry loop to classify a failure; several guards (log-file checks, the Windows
# arg-identity check) return WITHOUT reaching ssh.  If the clear sits after them
# a retry that failed a LOCAL guard reports the PREVIOUS attempt's
# `remote failure reason: <class>` for a call that never contacted the server
# (measured 2026-10-12).  Position is the whole point, so this asserts the clear
# is the FIRST statement in the FUNCTION BODY -- searched only inside
# run_ssh_logged, since the same literal also appears as the top-level global
# initialiser (line ~50), which a whole-file grep would wrongly credit.
cases=$((cases + 1))
reason_fn_line=$(grep -n '^run_ssh_logged()' "$client" | head -1 | cut -d: -f1) || true
if [ -z "$reason_fn_line" ]; then
    printf '%s\n' 'client-contract: could not locate run_ssh_logged' >&2
    failures=$((failures + 1))
else
    # Everything from the function opener to its closing brace at column 0.
    fn_body=$(awk -v start="$reason_fn_line" 'NR>=start{print} NR>start && /^}[[:space:]]*$/{exit}' "$client")
    # Line offset (1-based, relative to the opener) of the clear and of the
    # first early return, both measured WITHIN the function body.
    clear_rel=$(grep -n "agentq_remote_failure_reason_value=''" <<< "$fn_body" | head -1 | cut -d: -f1) || true
    return_rel=$(grep -n 'return \$?' <<< "$fn_body" | head -1 | cut -d: -f1) || true
    if [ -z "$clear_rel" ]; then
        printf '%s\n' 'client-contract: run_ssh_logged no longer clears the forwarded reason at all' >&2
        failures=$((failures + 1))
    elif [ -n "$return_rel" ] && [ "$clear_rel" -ge "$return_rel" ]; then
        printf '%s\n' 'client-contract: the forwarded-reason clear sits at/after run_ssh_logged'"'"'s first early return; a local-guard failure would report a stale reason from a prior attempt' >&2
        failures=$((failures + 1))
    fi
fi

# Both Windows launcher-wrapper copies must read the argument payload with the
# per-byte .NET stream read, never the 4096-char [Console]::In.Read(char[])
# block loop.  Measured 2026-10-14 on the Windows test host: the block read
# hangs intermittently once the payload passes ~4.5K characters (near-certainly
# past ~8.6K) -- a PS 5.1 Console.In block-read stall on the OpenSSH pipe;
# per-byte reads completed 12/12 with no hang (payloads to 53K).  The two
# copies (POSIX client's single-quoted one-liner, Windows client's here-string)
# cannot be compared by rule E -- assert the property in each file instead:
# the stream read must be present, and the block-read buffer must be gone.
#
# The launcher is the THIRD copy of this reader: its `-ArgumentsBase64 -` stdin
# entry reads the same payload through Read-AgentQBoundedText, which kept the
# 4096 block loop after the two wrappers were fixed (measured 2026-10-16).  No
# caller passes `-` today, so it is latent -- but SKILL.md documents that entry
# as one of the accepted delivery paths, so a future caller would hit the hang
# this lock exists to prevent.
cases=$((cases + 1))
windows_wrapper_asset="$root/skill/assets/client/windows/agentq.ps1"
launcher_asset="$root/skill/assets/windows-git-bash/agentq-launcher.ps1"
for wrapper_file in "$client" "$windows_wrapper_asset" "$launcher_asset"; do
    if ! grep -q 'OpenStandardInput\|\.Read()' "$wrapper_file" || \
       ! grep -q 'ReadByte\|\.Read()' "$wrapper_file"; then
        printf 'client-contract: %s no longer reads the Windows argument payload per byte (the block read hangs on real Windows ssh)\n' "$wrapper_file" >&2
        failures=$((failures + 1))
    fi
    if grep -q '\[char\[\]::new(4096)' "$wrapper_file"; then
        printf 'client-contract: %s still carries the 4096-char block-read buffer that hangs on real Windows ssh\n' "$wrapper_file" >&2
        failures=$((failures + 1))
    fi
done

# Two precise shellcheck rules, over EVERY shell asset, when the tool is
# present.  They are the only two that found real defects here (2026-10-18):
# SC2319 (a `$?` captured after a `[` test -- it is the TEST's status, always 0,
# so a failed cleanup was reported as success) and SC2034 (an
# assigned-but-never-read variable).  The first was found in the POSIX client;
# the second in the SERVER -- `removal_status=$?` in remove_task, never read,
# with a comment right below it explaining why pueue's code is not propagated.
# A dead `$?` capture is worse than dead code: it reads as if the status were
# about to be used, which is exactly what the neighbouring comment was read as.
# Restricted with `-i` so a newer shellcheck's new rules cannot redden CI on
# their own; the two IDs are stable.  Absent tool = skipped, like pwsh
# elsewhere in this suite.  Dialect per file: the two canonical servers run
# bash, everything else is `#!/bin/sh` and is checked as POSIX sh.
shellcheck_summary=absent
shellcheck_assets=0
shellcheck_scripts=0
shellcheck_bad=0
shellcheck_directives=0
if command -v shellcheck >/dev/null 2>&1; then
    # The locked codes.  SC2221/SC2222 joined on 2026-10-20: a duplicated case
    # pattern (''|en|en-*|'') makes the repeated branch DEAD, and a dead branch
    # in a check is the same defect class as a dead variable -- an assertion
    # that silently never runs.  It was found by widening the lock in a
    # real-host run, after three checks had shipped with it.
    #
    # SC1072/SC1073 joined on 2026-10-26, and they are a different KIND of
    # code: "shellcheck stopped parsing this file".  Two prose comments that
    # began with the directive token made shellcheck emit SC1073 + SC1072 and
    # then ANALYSE NOTHING AFTER THAT LINE -- measured by planting a dead
    # variable after smoke/01's line 1104: the lock exited 0.  Without these
    # two codes in the include list the lock cannot see the very event that
    # switches it off, because `-i` suppresses parse errors along with
    # everything else.  Measured 2026-10-26: with the six codes, all 40 shell
    # files in this repo are otherwise clean, so the two add signal, not noise.
    shellcheck_codes='SC2319,SC2034,SC2221,SC2222,SC1072,SC1073'
    shellcheck_probe_dir=$work/shellcheck-probe
    mkdir -p "$shellcheck_probe_dir"
    # ONE invocation shape for the real lint, the directive probes and the
    # self-check below, so the three cannot drift apart.  `--norc` and the
    # explicit `-S style` are not decoration: `-i` was measured (2026-10-26) to
    # accept its narrowing from OUTSIDE the file as well --
    #   * a `.shellcheckrc` anywhere above the file (`disable=SC2034` -> a
    #     planted dead variable went unreported, rc 0),
    #   * `$XDG_CONFIG_HOME/shellcheckrc` (same),
    #   * `SHELLCHECK_OPTS` (`-e SC2034`, `-i SC2319`, `--rcfile=<narrowing>`
    #     and `-S error` each silenced it),
    # and each one turns the lock off for every file at once.  Measured on
    # 0.11.0: an explicit flag on the command line wins over every one of those
    # channels -- `--norc` over an rc file however it was named, `-S style`
    # over `-S error`, `-i` over `-e`/`-i`/`--include`/`--exclude` -- so the
    # three flags below are the whole defence.  (No `SHELLCHECK_OPTS=`
    # prefix: it was measured to change nothing, and an element that no
    # mutation can turn red is decoration; the self-check below is what
    # reddens if a future shellcheck lets the environment win.)
    run_shellcheck() { # $1 = dialect, rest = arguments for shellcheck
        local sc_dialect=$1
        shift
        shellcheck --norc -S style -s "$sc_dialect" -i "$shellcheck_codes" "$@"
    }
    # A line shaped like a directive is a CANDIDATE.  The enumerator is
    # deliberately BROADER than the tool's own rule -- any comment line
    # containing the word, any case -- because the cost of a false candidate is
    # one probe that passes, and the cost of a missed candidate is the defect
    # this arm exists for.  The probe, not this grep, is the judge: it asks the
    # tool what the line DOES.
    #
    # Why this arm exists at all, measured 2026-10-26: two prose comments began
    # with the token (smoke/01 and smoke/20), which shellcheck parses as a
    # MALFORMED directive -- SC1073/SC1072 -- and then ABORTS the rest of that
    # file's analysis.  `-i` suppresses parse errors too, so both files had
    # been passing with everything from the offending line to EOF unlinted:
    # measured by planting a dead variable AFTER smoke/01's line 1104, the lock
    # still exited 0.  The same shape also hides a second, quieter class: a
    # WELL-FORMED directive (`disable=SC2034`, `disable=all`, and the
    # line-scoped `disable-next=`) narrows the lock from inside the file it
    # guards -- measured by putting `disable=SC2319,SC2034` at the top of
    # client/unix/sshp: smoke/05 stayed green at checked(9).
    shellcheck_directive_candidates() { # $1 = file -> "line:text" per candidate
        grep -n '^[[:space:]]*#.*[Ss][Hh][Ee][Ll][Ll][Cc][Hh][Ee][Cc][Kk]' "$1" 2>/dev/null
    }
    shellcheck_directive_violation() { # $1 = candidate line; rc 0 = clean
        local probe=$shellcheck_probe_dir/probe.sh parse_probe=$shellcheck_probe_dir/parse-probe.sh found parse_found
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' "$1"
            # One trigger per locked code.  If the candidate narrows any of
            # them (file-level `disable=`, or `disable-next=` -- the next line
            # is a trigger) that code goes missing; if it is malformed,
            # analysis stops at it and ALL of them go missing.
            printf '%s\n' 'agentq_sc_probe_dead=1'
            printf '%s\n' 'if [ -n "" ]; then agentq_sc_probe_status=$?; fi'
            printf '%s\n' 'printf "%s\n" "$agentq_sc_probe_status"'
            printf '%s\n' 'case agentq_sc_probe_kind in a) printf a ;; a) printf dup ;; esac'
        } >"$probe"
        # `-f gcc` only shapes the output; the detection flags are the shared
        # ones.  The expected set is EXACT: a missing code means the directive
        # silenced it, an extra code means the directive did not parse.
        found=$(run_shellcheck sh -f gcc "$probe" 2>&1 | grep -o '\[SC[0-9]*\]' | tr -d '[]' | sort -u | tr '\n' ' ')
        [ "$found" = 'SC2034 SC2221 SC2222 SC2319 ' ] || return 1
        # A SECOND fixture, because one file cannot answer both questions: a
        # parse abort suppresses every other finding (measured -- a dead
        # variable plus an unterminated `if` reports only SC1072/SC1073), so
        # the parse-error signal has to be provoked in a file of its own.
        # Without this probe a file could carry
        # `# shellcheck disable=SC1072,SC1073` at the top and every later
        # parse abort -- the exact event that makes the lock blind -- would be
        # silent; measured: rc 0 on a file with an unterminated `if`.
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' "$1"
            printf '%s\n' 'if true; then'
        } >"$parse_probe"
        parse_found=$(run_shellcheck sh -f gcc "$parse_probe" 2>&1 | grep -o '\[SC[0-9]*\]' | tr -d '[]' | sort -u | tr '\n' ' ')
        case $parse_found in
            *SC1072*SC1073*) return 0 ;;
            *) return 1 ;;
        esac
    }
    # The detector must be able to fail, and its "clean" answer must be a real
    # answer.  Five planted lines: a narrowing directive, a malformed one and
    # one that switches off the parse-error signal itself must be flagged; an
    # unrelated valid directive and plain prose must pass.
    shellcheck_directive_selftest() {
        local selftest_got=
        shellcheck_directive_violation '# shellcheck disable=SC2034' && selftest_got="$selftest_got missed-narrowing"
        shellcheck_directive_violation '# shellcheck reported it SC2034' && selftest_got="$selftest_got missed-malformed"
        shellcheck_directive_violation '# shellcheck disable=SC1072,SC1073' && selftest_got="$selftest_got missed-parse-signal"
        shellcheck_directive_violation '# shellcheck disable=SC2016' || selftest_got="$selftest_got false-valid"
        shellcheck_directive_violation '# see shellcheck disable=SC2034' || selftest_got="$selftest_got false-prose"
        if [ -n "$selftest_got" ]; then
            printf 'client-contract: the shellcheck-directive probe FAILED its self-check:%s -- a narrowing directive is invisible, or a clean one is reported as a defect\n' "$selftest_got" >&2
            shellcheck_bad=$((shellcheck_bad + 1))
        fi
    }
    # The enumerator is the SHIPPED one, exercised through the same function the
    # lint loop calls -- a self-test that re-spells the pattern would validate a
    # copy, not the code.  The fixture has four candidate lines (directive
    # shaped, prose, unspaced, uppercase) and two decoys (token after code,
    # no token); a drift in the pattern must move the line set.
    shellcheck_enumerator_selftest() {
        local fixture=$shellcheck_probe_dir/enum.sh enum_lines
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' '# shellcheck disable=SC2016'
            printf '%s\n' '# see shellcheck disable=SC2016'
            printf '%s\n' '    #shellcheck disable=SC2016'
            printf '%s\n' '# Shellcheck disable=SC2016'
            printf '%s\n' 'printf x  # shellcheck disable=SC2016'
            printf '%s\n' 'printf y'
        } >"$fixture"
        enum_lines=$(shellcheck_directive_candidates "$fixture" | cut -d: -f1 | tr '\n' ' ')
        if [ "$enum_lines" != '2 3 4 5 ' ]; then
            printf 'client-contract: the shellcheck-directive enumerator returned lines [%s] in a fixture whose candidates are lines 2-5; it no longer matches the lines the lock must probe\n' "${enum_lines:-none}" >&2
            shellcheck_bad=$((shellcheck_bad + 1))
        fi
    }
    # The lock must not be silenceable from the environment either.  Plant a
    # known defect in a directory that carries a narrowing `.shellcheckrc`, and
    # run with `SHELLCHECK_OPTS='-S error'`: the defect must still be reported.
    # A tool that rejects the invocation (unknown flag on an older shellcheck)
    # is a THIRD outcome and is reported as such -- reading it as "not silenced"
    # would be the same false green this arm exists to prevent.
    shellcheck_external_config_selftest() {
        local dir=$shellcheck_probe_dir/external rc=0
        mkdir -p "$dir"
        printf '%s\n' '#!/bin/sh' 'agentq_sc_probe_dead=1' >"$dir/defect.sh"
        printf 'disable=SC2034\n' >"$dir/.shellcheckrc"
        (unset CDPATH; cd "$dir" && SHELLCHECK_OPTS='-S error' run_shellcheck sh defect.sh >/dev/null 2>&1) || rc=$?
        case $rc in
            0) printf 'client-contract: shellcheck can be silenced from OUTSIDE the file on this host (a narrowing .shellcheckrc or SHELLCHECK_OPTS defeated --norc/-S style) -- every file would pass unlinted\n' >&2
               shellcheck_bad=$((shellcheck_bad + 1)) ;;
            1) : ;;
            *) printf 'client-contract: shellcheck rejected the lock invocation itself (rc=%s; an older shellcheck without --norc or -S?) -- the lock never ran, so nothing was linted\n' "$rc" >&2
               shellcheck_bad=$((shellcheck_bad + 1)) ;;
        esac
    }
    # $1 = path to lint, $2 = the name to print.  Runs in this shell, not a
    # subshell, so `shellcheck_bad` accumulates.
    lint_shell_file() {
        local shell_file=$1 shell_label=$2 shell_dialect first directive_line directive_text candidate_line
        first=$(head -1 "$shell_file")
        case $first in
            *bash*) shell_dialect=bash ;;
            *) shell_dialect=sh ;;
        esac
        if ! run_shellcheck "$shell_dialect" "$shell_file" >/dev/null 2>&1; then
            printf 'client-contract: shellcheck found SC2319/SC2034/SC2221/SC2222 (a `$?` after a test, a dead variable, or a dead case branch) or SC1072/SC1073 (a file shellcheck stopped parsing -- often a comment that begins with the directive token, which aborts the rest of the analysis) in %s:\n' "$shell_label" >&2
            run_shellcheck "$shell_dialect" "$shell_file" >&2 || true
            shellcheck_bad=$((shellcheck_bad + 1))
        fi
        # Every candidate line is probed, so a directive that narrows the lock
        # or fails to parse is named with its file and line.
        #
        # The empty line is skipped: a command substitution that yields nothing
        # still leaves one empty here-doc line, so a candidate-less file used to
        # contribute one phantom probe (measured 2026-10-26 on the tree of that
        # day: 31 such files inflated the counter from 47 real candidates to 78).
        # Worse, a grep that failed on an unreadable file was indistinguishable
        # from a clean one -- and the `checked(0)` guard below, which exists to
        # catch a blind enumerator, could never fire while every file
        # contributed one.
        # (The split itself is fine: `IFS=: read` gives the last variable the
        # remainder INCLUDING later separators -- measured -- so the text was
        # never truncated.  Splitting with parameter expansion anyway keeps the
        # line number and text visibly one field apart.)
        while IFS= read -r candidate_line; do
            [ -n "$candidate_line" ] || continue
            directive_line=${candidate_line%%:*}
            directive_text=${candidate_line#*:}
            shellcheck_directives=$((shellcheck_directives + 1))
            if ! shellcheck_directive_violation "$directive_text"; then
                printf 'client-contract: shellcheck directive in %s:%s is malformed or disables a locked code -- a malformed one makes shellcheck stop analysing the rest of the file, and either kind turns this lock off for that file: %s\n' \
                    "$shell_label" "$directive_line" "$directive_text" >&2
                shellcheck_bad=$((shellcheck_bad + 1))
            fi
        done <<EOF
$(shellcheck_directive_candidates "$shell_file")
EOF
    }
    while IFS= read -r shell_asset; do
        lint_shell_file "$shell_asset" "${shell_asset#"$root"/}"
        shellcheck_assets=$((shellcheck_assets + 1))
    done < <(find "$root/skill/assets" -type f -exec sh -c '
        first=$(head -1 "$1" 2>/dev/null) || exit 0
        case "$first" in
            "#!"*sh*) printf "%s\n" "$1" ;;
        esac
    ' _ {} \; | sort)
    # ...and the repo's OWN shell scripts, because this lock's two rules have
    # now found the same defect class in both halves.  Round eleven found SC2319
    # in the POSIX client, round twelve widened the lock to all nine assets and
    # immediately found SC2034 in the SERVER.  Then a 2026-10-20 sweep found
    # TWELVE more SC2034 sites -- all of them in smoke/ itself, invisible to a
    # lock that only looked at skill/assets: dead status captures in 05/06/07/15
    # that read like assertions about to be made.  A check that silently stops
    # checking is worse than an asset defect, because it hides the next one.
    while IFS= read -r shell_script; do
        lint_shell_file "$shell_script" "${shell_script#"$root"/}"
        shellcheck_scripts=$((shellcheck_scripts + 1))
    done < <({ find "$root/smoke" -type f -name '*.sh'; printf '%s\n' "$root/run-tests.sh" "$root/sandbox.sh"; } | sort)
    # Zero in EITHER set means an enumeration failed, not that there was nothing
    # to check -- the same reasoning as the shell enumeration in smoke/01.
    if [ "$shellcheck_assets" -eq 0 ]; then
        printf 'client-contract: no shell assets were enumerated for shellcheck; refusing to report a pass\n' >&2
        shellcheck_bad=$((shellcheck_bad + 1))
    fi
    if [ "$shellcheck_scripts" -eq 0 ]; then
        printf 'client-contract: no repo scripts were enumerated for shellcheck; refusing to report a pass\n' >&2
        shellcheck_bad=$((shellcheck_bad + 1))
    fi
    # The three self-checks run LAST, after every file has been probed, so a
    # detector that has gone blind cannot be hidden by an empty candidate set.
    # `shellcheck_directives` is a count of what was actually probed; the
    # enumerator is broad (any comment line mentioning the tool), so the number
    # is much larger than the directive count a human would tally -- that is
    # the point: a line is judged by what the tool DOES with it, not by how it
    # looks.  Zero means the enumerator matched nothing across every shell file
    # in the repo, which is a broken enumerator, not a clean tree.
    shellcheck_directive_selftest
    shellcheck_enumerator_selftest
    shellcheck_external_config_selftest
    if [ "$shellcheck_directives" -eq 0 ]; then
        printf 'client-contract: not one shellcheck-directive candidate was enumerated across %s files; the enumerator is blind and the directive lock never ran\n' "$((shellcheck_assets + shellcheck_scripts))" >&2
        shellcheck_bad=$((shellcheck_bad + 1))
    fi
    cases=$((cases + 1))
    failures=$((failures + shellcheck_bad))
    shellcheck_summary="checked($shellcheck_assets) scriptcheck=checked($shellcheck_scripts) directives=checked($shellcheck_directives)"
else
    # `skipped(...)`, not a bare `absent`: run-tests.sh buckets a check into
    # PART on the word "skipped", so the old token read as a full pass on a
    # machine without shellcheck -- "9 assets and 38 scripts were never linted"
    # printed as green.  Same vocabulary as smoke/01's skipped(pwsh-absent).
    shellcheck_summary="skipped(shellcheck-absent)"
fi

# POSIX-dialect parse lock (2026-10-24).  Five assets declare `#!/bin/sh`,
# which on Debian/Ubuntu is dash -- the interpreter whose startup crash on
# three bashisms started this whole POSIX-contract work (0.1.4).  bash -n and
# zsh -n in smoke/01 validate the WRONG grammar for them: measured by planting
# `arr=(x y)` inside an uncalled function at EOF of client/unix/agentq --
# bash -n exit 0, zsh -n exit 0, `shellcheck -s sh -i SC2319,SC2034,SC2221,
# SC2222` exit 0, this check's own behavioral dash run cases=45 all GREEN,
# `dash -n` exit 2 "Syntax error: "(" unexpected".  A behavioral dash run
# cannot be the lock: dash parses lazily, so a bashism in a function
# definition past the line a given command exits at never executes -- the
# client's `--version` path exits long before EOF (measured: the planted file
# still answered `--version` under dash, exit 0).  `dash -n` reads the whole
# file.  Dialect per file: the canonical twins declare bash, so dash -n would
# reject their legitimate bash syntax; they stay under bash -n/zsh -n.
# Boundary: dash -n catches PARSE-level bashisms only.  Constructs that parse
# in dash but behave differently there are a different class and stay with
# the behavioral Linux-CI coverage.
posix_parse_state=absent
posix_bad=0
if command -v dash >/dev/null 2>&1; then
    posix_parsed=0
    # $1 = path to parse.  Runs in this shell, not a subshell, so posix_bad
    # and posix_parsed accumulate.
    parse_posix_file() {
        local posix_file=$1 posix_first posix_err
        posix_first=$(head -1 "$posix_file")
        case $posix_first in
            *bash*) return 0 ;;
        esac
        posix_parsed=$((posix_parsed + 1))
        if ! posix_err=$(dash -n "$posix_file" 2>&1); then
            printf 'client-contract: dash -n rejected %s (a bashism the shebang interpreter cannot parse): %s\n' \
                "${posix_file#"$root"/}" "$posix_err" >&2
            posix_bad=$((posix_bad + 1))
        fi
    }
    while IFS= read -r shell_asset; do
        parse_posix_file "$shell_asset"
    done < <(find "$root/skill/assets" -type f -exec sh -c '
        first=$(head -1 "$1" 2>/dev/null) || exit 0
        case "$first" in
            "#!"*sh*) printf "%s\n" "$1" ;;
        esac
    ' _ {} \; | sort)
    # Zero-or-few means the enumeration broke, not that there was nothing to
    # parse -- five `#!/bin/sh` assets exist today (agentq, sshp, both
    # installers, the unix wrapper); a count below that is a silent scan.
    if [ "$posix_parsed" -lt 5 ]; then
        printf 'client-contract: the POSIX parse arm could only see %s #!/bin/sh assets (expected 5); refusing to report a pass\n' "$posix_parsed" >&2
        posix_bad=$((posix_bad + 1))
    fi
    # Self-check, same reason as every other planted-fixture check here: a
    # detector that quietly stops matching reads exactly like a clean tree.
    # Both directions run against a SELF-CONTAINED fixture, never against an
    # asset -- the first version used client/unix/agentq as the "must still
    # parse" half, and when a bashism was planted in that same asset to prove
    # the rejection half worked, the acceptance half fired too and reported a
    # SECOND, wrong cause ("the detector is over-matching") alongside the real
    # one.  A self-check must stay independent of the thing it guards.
    posix_ok_fixture=$(mktemp)
    printf '#!/bin/sh\nzz_valid() {\n  local a\n  a=1\n  printf "%%s\\n" "$a"\n}\nzz_valid\n' > "$posix_ok_fixture"
    if ! dash -n "$posix_ok_fixture" >/dev/null 2>&1; then
        printf '%s\n' 'client-contract: the POSIX parse arm rejects a minimal valid POSIX fixture (the detector is broken)' >&2
        posix_bad=$((posix_bad + 1))
    fi
    posix_bad_fixture=$(mktemp)
    { cat "$posix_ok_fixture"
      printf 'zz_planted_posix_bashism() {\n  arr=(x y)\n}\n'
    } > "$posix_bad_fixture"
    if dash -n "$posix_bad_fixture" >/dev/null 2>&1; then
        printf '%s\n' 'client-contract: the POSIX parse arm is silent on a planted bashism (the detector itself is broken)' >&2
        posix_bad=$((posix_bad + 1))
    fi
    rm -f "$posix_ok_fixture" "$posix_bad_fixture"
    posix_parse_state="checked($posix_parsed)"
else
    # `skipped(...)`, so run-tests.sh buckets this as PART rather than reading
    # "5 assets were never parsed under the grammar they ship with" as green.
    posix_parse_state="skipped(dash-absent)"
fi
failures=$((failures + posix_bad))

if [ "$failures" -ne 0 ]; then
    printf 'client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi

printf 'client-contract checks passed: cases=%s env=%s cred=%s global=%s host=%s exec=%s stub-ssh=yes reason=forwarded/injection-safe exit-token=last-wins windows-probe=stdin-fed/no-leak windows-submit=payload-delivered/args-checked/no-leak shellcheck=%s posix=%s\n' "$cases" "$env_rejections" "$credential_cases" "$global_variants" "$host_shape_cases" "$executable_shape_cases" "$shellcheck_summary" "$posix_parse_state"
