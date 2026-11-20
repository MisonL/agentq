#!/usr/bin/env bash
# Smoke: assets/client/unix/install-client.sh -- its local contract.
#
# Why this check exists: it is the LAST installer in the repo with no behavioural
# coverage at all.  The other two already have contract checks -- install-agentq.sh
# has smoke/11, install-agentq.ps1 has smoke/13 -- and this one had only 01's
# `sh -n`.  (No line count in this sentence: an embedded one goes stale, measured
# 2026-11-17 at 251 against 459.)  It sits in the "no check has ever executed it" table in
# docs/verification-status.md, and unlike the two Windows-only assets left there it is fully
# runnable on this machine, so leaving it uncovered was a choice, not a limit.
#
# Shape, borrowed from 11/13: assert the CONTRACT.  Unlike install-agentq.sh
# (env-var driven, no argv), this installer DOES parse argv, so the reachable
# surface is the option parser plus the path-safety and drift checks -- and,
# uniquely among the three, a real SUCCESS path that is safe to run here because
# it only copies two files into a sandbox directory.  That success path is
# covered: it is the only installer in the repo whose happy path is testable
# without a network, a service manager, or a package manager.
#
# WHAT THIS DOES NOT COVER: the destructive move semantics on a live destination
# (crash between the temp file and the rename), and anything about the clients it
# installs beyond their bytes matching the canonical assets.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source_directory="$root/skill/assets/client/unix"
# AGENTQ_SMOKE_INSTALLER points this check at a mutated copy of the installer;
# same convention as smoke/05, smoke/07, smoke/11 and smoke/13.  The installer
# resolves its two client assets from ITS OWN directory, so the installer under
# test is staged into a directory that also holds the canonical clients --
# $source_directory keeps pointing at the real assets for the byte comparisons.
installer_source="${AGENTQ_SMOKE_INSTALLER:-$source_directory/install-client.sh}"
[ -f "$installer_source" ] || { printf '%s\n' 'install-client-contract: missing installer asset' >&2; exit 1; }

# The installer rejects any path containing a symlink component
# (assert_no_symlink_path_chain walks every component and rejects a link).  On
# macOS /tmp IS a symlink to /private/tmp, so a plain `mktemp -d` under /tmp is
# rejected with "destination directory contains a symbolic link" before any case
# runs.  `pwd -P` resolves it.  Same idiom as smoke/05, smoke/11, smoke/19.
work=$(mktemp -d /tmp/agentq-smoke-installclient.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
cleanup_sandbox() { rm -rf -- "$work"; }
trap cleanup_sandbox EXIT HUP INT TERM

installer_directory="$work/installer"
mkdir -p "$installer_directory"
cp "$installer_source" "$installer_directory/install-client.sh"
cp "$source_directory/agentq" "$source_directory/sshp" "$installer_directory/"
chmod 700 "$installer_directory/install-client.sh" "$installer_directory/agentq" "$installer_directory/sshp"
installer="$installer_directory/install-client.sh"

# A sandbox HOME so a run that forgets --bin-dir cannot touch the real ~/.local/bin.
# The installer defaults the destination to "$HOME/.local/bin", so this matters.
export HOME="$work/home"
mkdir -p "$HOME"

failures=0
cases=0

# run_installer <args...> -- runs the installer, capturing status/stdout/stderr.
# The destination is ALWAYS explicit so no case can fall back to $HOME/.local/bin.
run_installer() {
    local status=0
    "$installer" "$@" >"$work/out" 2>"$work/err" || status=$?
    printf '%s' "$status"
}

# expect_rejected <label> <expected-stderr-fragment> [args...]
expect_rejected() {
    local label=$1 expected=$2
    shift 2
    cases=$((cases + 1))
    local status
    status=$(run_installer "$@")
    if [ "$status" -eq 0 ]; then
        printf 'install-client %s: expected a non-zero exit, got 0\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'install-client %s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

# --- the option contract ------------------------------------------------------
# Every message below was MEASURED off the installer, not guessed -- the first
# version of smoke/13 asserted wording that did not exist, and that is the trap.
expect_rejected 'unknown option'          'unknown option: --bogus' --bogus
expect_rejected 'bin-dir missing value'   '--bin-dir requires a directory' --bin-dir
# --bin-dir with an empty value: the empty string reaches the destination check.
expect_rejected 'empty bin-dir'           'destination directory cannot be empty' --bin-dir ''

# --help must succeed and must NOT touch anything.  It prints usage to stdout.
cases=$((cases + 1))
help_status=$(run_installer --help)
if [ "$help_status" -ne 0 ]; then
    printf 'install-client --help: expected 0, got %s\n' "$help_status" >&2
    failures=$((failures + 1))
elif ! grep -qF 'Usage: install-client.sh' "$work/out"; then
    printf 'install-client --help: usage text not on stdout\n' >&2
    failures=$((failures + 1))
fi
# -h is an alias for --help.
cases=$((cases + 1))
if [ "$(run_installer -h)" -ne 0 ]; then
    printf 'install-client -h: expected 0\n' >&2
    failures=$((failures + 1))
fi

# --- path safety --------------------------------------------------------------
# A destination whose path chain contains a symlink must be refused, and refused
# BEFORE anything is created.  This is the property that keeps the installer from
# following a link an attacker planted in the destination chain.
link_parent="$work/link-parent"
real_parent="$work/real-parent"
mkdir -p "$real_parent"
ln -s "$real_parent" "$link_parent"
expect_rejected 'symlinked destination' 'symbolic link' --bin-dir "$link_parent/child"

# A destination that is a regular FILE, not a directory, must be refused.  The
# message is the mkdir failure, not a "not a directory" phrasing -- measured, not
# guessed (the first draft asserted wording that does not exist).
file_destination="$work/not-a-directory"
printf 'x' > "$file_destination"
expect_rejected 'destination is a file' 'cannot create destination directory' --bin-dir "$file_destination"

# --- --check: the read-only drift check ---------------------------------------
# --check against an empty directory: both clients are "missing", exit 1, and
# nothing is written.  The empty destination must still be empty afterwards.
empty_destination="$work/empty-dest"
mkdir -p "$empty_destination"
cases=$((cases + 1))
check_status=$(run_installer --check --bin-dir "$empty_destination")
if [ "$check_status" -ne 1 ]; then
    printf 'install-client --check (empty): expected 1, got %s\n' "$check_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'client is missing from destination: agentq' "$work/err" \
   || ! grep -qF 'client is missing from destination: sshp' "$work/err"; then
    printf 'install-client --check (empty): did not report both clients missing\n' >&2
    failures=$((failures + 1))
fi
if [ -n "$(find "$empty_destination" -mindepth 1 -print -quit)" ]; then
    printf 'install-client --check (empty): --check wrote to the destination\n' >&2
    failures=$((failures + 1))
fi

# --check with the destination directory ABSENT (not merely empty): SKILL.md
# documents 0 match / 1 missing or drift / 2 unsafe, and the Windows twin's
# Invoke-CanonicalClientCheck reports each client as missing and returns 1.  The
# POSIX path ran assert_regular_directory_path first, which fail()ed with 2, so
# one state answered 2 on POSIX and 1 on Windows.  Nothing may be created.
absent_destination="$work/absent-dest"
cases=$((cases + 1))
absent_status=$(run_installer --check --bin-dir "$absent_destination")
if [ "$absent_status" -ne 1 ]; then
    printf 'install-client --check (absent directory): expected 1, got %s\n' "$absent_status" >&2
    failures=$((failures + 1))
fi
if [ -e "$absent_destination" ]; then
    printf 'install-client --check (absent directory): --check created the destination\n' >&2
    failures=$((failures + 1))
fi

# --- the success path ---------------------------------------------------------
# The ONLY installer happy path testable here: it copies two files into a sandbox
# directory, no network, no service manager.  Covered on purpose -- a contract
# check that only ever proves rejection cannot tell a working installer from one
# that always fails.
install_destination="$work/installed"
cases=$((cases + 1))
install_status=$(run_installer --bin-dir "$install_destination")
if [ "$install_status" -ne 0 ]; then
    printf 'install-client (install): expected 0, got %s\n' "$install_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
else
    # Both clients installed, byte-identical to the canonical assets.
    for client in agentq sshp; do
        if ! cmp -s "$source_directory/$client" "$install_destination/$client"; then
            printf 'install-client (install): %s is not byte-identical to the asset\n' "$client" >&2
            failures=$((failures + 1))
        fi
    done
    # Mode 700: the installer does `chmod 700` on each staged file.  Asserted
    # because that is the step whose Windows counterpart was a silent no-op
    # (docs/verification-status.md: chmod on noacl mounts); on POSIX it must actually take.
    #
    # Probe the stat flavour rather than trying one then the other with `||`:
    # on GNU, `stat -f` is `--file-system` and SUCCEEDS, printing a multi-line
    # filesystem block, so a `||` fallback never fires and the mode "700" is
    # swallowed inside that block.  Same order agentq-server's detect_stat_flavor
    # uses -- GNU first, since BSD's stat rejects `-c`.
    for client in agentq sshp; do
        target="$install_destination/$client"
        mode=$(stat -c '%a' -- "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null)
        if [ "$mode" != "700" ]; then
            printf 'install-client (install): %s mode is %s, expected 700\n' "$client" "$mode" >&2
            failures=$((failures + 1))
        fi
    done
    # No staging residue: the `.agentq.new.XXXXXX` temp files must all be gone.
    residue=$(find "$install_destination" -name '.agentq.new.*' -o -name '.sshp.new.*' | wc -l | tr -d ' ')
    if [ "$residue" -ne 0 ]; then
        printf 'install-client (install): %s staging temp file(s) left behind\n' "$residue" >&2
        failures=$((failures + 1))
    fi
fi

# --- W1: a failure on the SECOND client must leave NEITHER client updated ----
# The install used to stage+move agentq first, then stage+move sshp -- so any
# failure on the second client (unreadable asset, full destination) left a NEW
# agentq paired with a STALE sshp, and the pair is only ever read together
# (docs/PLAN.md A28 W4, the installer half).  Both directions are asserted because
# either one alone lets a broken installer pass: swapping the pre-existing
# old content in, or writing nothing at all, are both wrong -- what must hold
# is "the pair was never observed mixed after an aborted install".
w1_destination="$work/w1-dest"
mkdir -p "$w1_destination"
printf 'OLD-AGENTQ\n' > "$w1_destination/agentq"
printf 'OLD-SSHP\n' > "$w1_destination/sshp"

# The asset is readable as 111: it PASSES both prechecks (-f and -x both look at
# mode bits, not at read access -- measured: [ -x ] is true for --x--x--x) and
# fails only at cp, which is exactly the window the staging order must close.
# It is the SANDBOX copy that is chmodded, not the repo asset: the installer under
# test reads its clients from its own directory ($installer_directory), and the
# real assets stay untouched so the byte comparisons above remain canonical.
chmod 111 "$installer_directory/sshp"
cases=$((cases + 1))
w1_status=$(run_installer --bin-dir "$w1_destination")
chmod 700 "$installer_directory/sshp"
if [ "$w1_status" -eq 0 ]; then
    printf 'install-client (W1): expected a non-zero exit when sshp is unreadable, got 0\n' >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'cannot stage client: sshp' "$work/err"; then
    printf 'install-client (W1): stderr did not name the second client as the failure\n' >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
if [ "$(cat "$w1_destination/agentq")" != 'OLD-AGENTQ' ]; then
    printf 'install-client (W1): agentq was updated even though the install aborted on sshp\n' >&2
    failures=$((failures + 1))
fi
if [ "$(cat "$w1_destination/sshp")" != 'OLD-SSHP' ]; then
    printf 'install-client (W1): sshp changed despite its staging failure\n' >&2
    failures=$((failures + 1))
fi
# And the aborted run must leave no staging residue behind.
residue=$(find "$w1_destination" -name '.*.new.*' | wc -l | tr -d ' ')
if [ "$residue" -ne 0 ]; then
    printf 'install-client (W1): %s staging file(s) left behind after the aborted install\n' "$residue" >&2
    failures=$((failures + 1))
fi

# --check against the freshly installed directory: must now match, exit 0.
cases=$((cases + 1))
recheck_status=$(run_installer --check --bin-dir "$install_destination")
if [ "$recheck_status" -ne 0 ]; then
    printf 'install-client --check (installed): expected 0, got %s\n' "$recheck_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'match canonical assets' "$work/out"; then
    printf 'install-client --check (installed): did not report a match\n' >&2
    failures=$((failures + 1))
fi

# --- --check must DETECT drift, not just accept what is there -----------------
# Overwrite one installed client with different bytes: --check must report the
# mismatch and exit 1.  Without this case, a --check that always returned 0 would
# pass every assertion above.
drift_destination="$work/drift"
mkdir -p "$drift_destination"
cp "$source_directory/agentq" "$drift_destination/agentq"
cp "$source_directory/sshp" "$drift_destination/sshp"
printf '\n# drift\n' >> "$drift_destination/sshp"
cases=$((cases + 1))
drift_status=$(run_installer --check --bin-dir "$drift_destination")
if [ "$drift_status" -ne 1 ]; then
    printf 'install-client --check (drift): expected 1, got %s\n' "$drift_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'client does not match canonical asset: sshp' "$work/err"; then
    printf 'install-client --check (drift): did not name the drifted client\n' >&2
    failures=$((failures + 1))
fi
# ...and the un-drifted client must NOT be reported as drifting.  A --check that
# reported every client as drifted would pass the assertion above.
if grep -qF 'client does not match canonical asset: agentq' "$work/err"; then
    printf 'install-client --check (drift): reported the un-drifted client as well\n' >&2
    failures=$((failures + 1))
fi

# --- --check must detect a LOST EXECUTE BIT, not only changed bytes ----------
# The install stages each client and `chmod 700`s it, so the execute bit is part
# of the install result; a byte-identical copy with the bit cleared is
# unrunnable (the shell answers 126) while a bytes-only `--check` said "match".
# Measured 2026-11-20 (independent review, reproduced here): install, `chmod 600`
# both clients, `--check` -> exit 0 + "match", `<dest>/agentq --version` -> 126.
# Drift exits 1, like every other mismatch, and the message names the client.
mode_destination="$work/mode-drift"
mkdir -p "$mode_destination"
cp "$source_directory/agentq" "$mode_destination/agentq"
cp "$source_directory/sshp" "$mode_destination/sshp"
chmod 700 "$mode_destination/agentq" "$mode_destination/sshp"
chmod 600 "$mode_destination/agentq"
cases=$((cases + 1))
mode_status=$(run_installer --check --bin-dir "$mode_destination")
if [ "$mode_status" -ne 1 ]; then
    printf 'install-client --check (mode drift): expected 1, got %s\n' "$mode_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
if ! grep -qF 'client is not executable in destination: agentq' "$work/err"; then
    printf 'install-client --check (mode drift): did not name the unrunnable client\n' >&2
    failures=$((failures + 1))
fi
# The executable twin must NOT be blamed -- a check that flagged both would pass
# the assertion above for the wrong reason.
if grep -qF 'client is not executable in destination: sshp' "$work/err"; then
    printf 'install-client --check (mode drift): reported the executable client as well\n' >&2
    failures=$((failures + 1))
fi

# --- refusing to overwrite a co-located server wrapper -------------------------
# This installer's default destination ($HOME/.local/bin/agentq) is EXACTLY
# where install-agentq.sh puts its exec wrapper.  On a host that runs both, a
# plain install used to replace the 60-byte wrapper with the 175 KB client,
# silently, exit 0 -- measured 2026-10-09 on WSL, after which the remote
# agentq_run exec'd the client itself and every protocol call died with exit 2
# and empty output.  This is the only writer that can create that state, so it
# is the one that must refuse; the wrapper is recognizable as the one file
# containing the wrapper marker.  Assert three things: non-zero exit, the message
# names the conflict, and the wrapper bytes are untouched.
co_destination="$work/co-located"
mkdir -p "$co_destination"
cp "$root/skill/assets/unix/agentq" "$co_destination/agentq"
wrapper_before=$(shasum -a 256 <"$co_destination/agentq")
cases=$((cases + 1))
co_status=$(run_installer --bin-dir "$co_destination")
if [ "$co_status" -eq 0 ]; then
    printf 'install-client (co-located wrapper): expected a non-zero exit, got 0\n' >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'holds the AgentQ server wrapper' "$work/err"; then
    printf 'install-client (co-located wrapper): stderr did not name the wrapper conflict\n' >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
wrapper_after=$(shasum -a 256 <"$co_destination/agentq")
if [ "$wrapper_before" != "$wrapper_after" ]; then
    printf 'install-client (co-located wrapper): modified the wrapper it refused\n' >&2
    failures=$((failures + 1))
fi
# Nothing else may appear either: the guard runs before staging, so a stray
# temp file here would mean the installer started work it had already refused.
residue=$(find "$co_destination" -mindepth 1 ! -name agentq -print -quit)
if [ -n "$residue" ]; then
    printf 'install-client (co-located wrapper): left files beside the refused wrapper\n' >&2
    failures=$((failures + 1))
fi

# --- the conflict guard's rc=2 arm must be REACHABLE and fail CLOSED -----------
# `grep -q ... &&` reads rc=2 (the file could not be read) exactly like rc=1
# (not a wrapper), so one transient read error let the installer replace a live
# server wrapper with the client -- the silent clobber the guard above exists to
# prevent.  The rc=2 arm refuses instead.
#
# But a case has to be able to GET there.  Measured 2026-11-17: neither a PATH
# shim that fails the matching grep nor a chmod-000 wrapper reaches this arm --
# the installer already required the destination to be a readable file, so the
# real grep exits 1 on anything a case can construct.  The previous version of
# this block was that PATH shim: it went green for the wrong reason (the archive
# grep in the drift check), and a mutation folding the `0` arm with the `*` arm
# survived it.  The guard now resolves its grep through
# AGENTQ_INSTALL_CLIENT_GREP, so each arm is driven directly.
#
# One destination, one file, three verdicts.  The `absent` arm must INSTALL --
# without it, "refused" would just mean "this installer never installs".
guard_destination="$work/guard-arms"
guard_grep_directory="$work/bin-guard-grep"
mkdir -p "$guard_grep_directory"
real_grep=$(command -v grep)
# make_guard_grep <exit-status>: matches the wrapper marker through the REAL
# grep, then reports the wanted status.  Falling back to the real verdict when
# the marker is absent keeps the shim faithful to the guard's question.
make_guard_grep() {
    cat > "$guard_grep_directory/grep" <<EOF
#!/bin/sh
"$real_grep" "\$@" 2>/dev/null >/dev/null
matched=\$?
if [ "\$matched" -eq 0 ]; then
    exit $1
fi
exec "$real_grep" "\$@"
EOF
    chmod 700 "$guard_grep_directory/grep"
}
run_guard_arm() { # <label> <grep-status> -> sets guard_rc
    local label=$1 status=$2
    make_guard_grep "$status"
    rm -rf -- "$guard_destination"
    mkdir -p "$guard_destination"
    cp "$root/skill/assets/unix/agentq" "$guard_destination/agentq"
    guard_before=$(shasum -a 256 <"$guard_destination/agentq")
    cases=$((cases + 1))
    guard_rc=0
    AGENTQ_INSTALL_CLIENT_GREP="$guard_grep_directory/grep" HOME="$HOME" \
        "$installer" --bin-dir "$guard_destination" >"$work/out" 2>"$work/err" || guard_rc=$?
}
# The shim itself must work: if it silently never fires, every arm below reads
# the real grep and the three verdicts collapse into two.
make_guard_grep 2
printf 'agentq: exec agentq/agentq-server\n' > "$work/guard-probe"
printf '%s\n' 'a plain client body without the wrapper marker' > "$work/guard-probe-without-marker"
probe_status=0
"$guard_grep_directory/grep" -q 'agentq/agentq-server' "$work/guard-probe" || probe_status=$?
cases=$((cases + 1))
if [ "$probe_status" -ne 2 ]; then
    printf 'install-client (guard arms): the grep override did not report the wanted status (got %s); the arms below would test the real grep\n' "$probe_status" >&2
    failures=$((failures + 1))
fi
probe_status=0
"$guard_grep_directory/grep" -q 'agentq/agentq-server' "$work/guard-probe-without-marker" || probe_status=$?
cases=$((cases + 1))
if [ "$probe_status" -eq 0 ]; then
    printf '%s\n' 'install-client (guard arms): the grep override matched a file that does not contain the marker' >&2
    failures=$((failures + 1))
fi

# wrapper arm: grep says "this IS the wrapper", exit 0 -> refusal.
run_guard_arm wrapper 0
if [ "$guard_rc" -eq 0 ]; then
    printf 'install-client (guard arms, wrapper): expected a non-zero exit from the wrapper verdict, got 0\n' >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'holds the AgentQ server wrapper' "$work/err"; then
    printf 'install-client (guard arms, wrapper): stderr did not name the wrapper conflict\n' >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
if [ "$guard_before" != "$(shasum -a 256 <"$guard_destination/agentq")" ]; then
    printf '%s\n' 'install-client (guard arms, wrapper): modified the wrapper it refused' >&2
    failures=$((failures + 1))
fi

# unreadable arm: grep says "I could not read it", exit 2 -> refusal naming it.
run_guard_arm unreadable 2
if [ "$guard_rc" -eq 0 ]; then
    printf 'install-client (guard arms, unreadable): expected a refusal, got exit 0\n' >&2
    failures=$((failures + 1))
fi
if [ "$guard_rc" -ne 2 ]; then
    printf 'install-client (guard arms, unreadable): expected the contract code 2, got %s\n' "$guard_rc" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'cannot inspect the existing AgentQ client destination' "$work/err"; then
    printf 'install-client (guard arms, unreadable): stderr did not name the inspection failure\n' >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
if [ "$guard_before" != "$(shasum -a 256 <"$guard_destination/agentq")" ]; then
    printf '%s\n' 'install-client (guard arms, unreadable): overwrote the wrapper it could not inspect' >&2
    failures=$((failures + 1))
fi
residue=$(find "$guard_destination" -mindepth 1 ! -name agentq -print -quit)
if [ -n "$residue" ]; then
    printf 'install-client (guard arms, unreadable): left files beside the refused destination\n' >&2
    failures=$((failures + 1))
fi

# absent arm (positive control): grep exits 1 -> the install must PROCEED.
run_guard_arm absent 1
if [ "$guard_rc" -ne 0 ]; then
    printf 'install-client (guard arms, absent): a non-wrapper destination was refused (exit %s): %s\n' \
        "$guard_rc" "$(head -2 "$work/err" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
if ! cmp -s "$guard_destination/agentq" "$source_directory/agentq"; then
    printf '%s\n' 'install-client (guard arms, absent): the install did not produce the canonical client' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'install-client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'install-client-contract checks passed: cases=%s install=covered check=covered drift=detected\n' "$cases"
