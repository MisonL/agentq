#!/usr/bin/env bash
# Smoke: no PowerShell asset may hand a script to a native command as a
# command-line argument in a form that PowerShell 5.1 will word-split.  Scripts
# must travel through a channel that cannot be re-parsed -- base64 on stdin, or
# a file.
#
# Why this is its own check.  PowerShell 5.1 wraps a native-command argument
# that contains a space in double quotes, but it does NOT escape double quotes
# already inside that argument.  The wrapper therefore ends at the script's
# first inner quote, and the CRT parser then splits the rest on whitespace.
# Measured on Windows 10 / PowerShell 5.1.19041, handing one script to
# `bash -lc` and reading back bash's argv:
#
#     script body                                  bash received
#     -------------------------------------------  -------------------------
#     # a " b                                      "# a " + "b"  (two args)
#     echo "hi there"                              "echo hi" + "there"
#     # reports "Could not open file".  Verified   the whole tail word-split
#     "$PATH" --config "x"                         intact (one arg)
#     printf "%s" "$MSYSTEM"                       intact (one arg)
#     (no double quote anywhere)                   intact
#
# The last two matter as much as the failures: they are why a naive rule like
# "reject any literal containing a double quote" is wrong, and why this check
# models the actual parsing instead (see crt_argc below).  pwsh 7.5 quotes
# correctly, which is exactly why this survived every macOS-side check and
# every pwsh-based test.
#
# This was a real defect, not a hypothetical.  A comment reading
# `# reports "Could not open file".  Verified on Windows 10 ...` was added to
# the installer's status command while fixing the jq path-argument defect.  It
# broke that command outright: bash received `set -e` plus a fragment, ran
# neither the pueue call nor jq, and exited 0 with NO output.  The status file
# was still written (1.5 MB), so the failure surfaced four frames away as
# "Pueue shell smoke task result was empty" -- and the installer rolled back,
# five times, before the cause was found.
#
# This check is a source scan, and it is honest about that.  It cannot execute
# PowerShell: PowerShell 5.1 does not exist on macOS, and the macOS pwsh that
# is available does NOT have the defect, so running it would prove nothing
# about the platform that matters.  What the scan can do is refuse the unsafe
# SHAPE, which is worth a check because the shape is silent -- the failure mode
# is exit 0 with no output, so no behavioural check in this suite can see it.
#
# What it proves: no PowerShell asset in this repo passes a script to a native
# command in a form the modelled parser would split, and every script that does
# reach a native command travels the base64 channel.  What it does not prove:
# PowerShell 5.1's actual behaviour (it is modelled here, not executed), the
# real CRT for every exotic quoting case, or anything about assets not scanned.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ps_assets=${AGENTQ_SMOKE_PS_DIR:-$root/skill/assets}
work_violations=$(mktemp "${TMPDIR:-/tmp}/agentq-smoke-nativearg.XXXXXX")
work_hits=$(mktemp "${TMPDIR:-/tmp}/agentq-smoke-nativearg-hits.XXXXXX")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-nativearg-dir.XXXXXX")
trap 'rm -f -- "$work_violations" "$work_hits"; rm -rf -- "$work_dir"' EXIT

# QUOTED FLAGS (2026-11-10).  PowerShell accepts `-c`, `'-c'` and `"-c"`; the
# flag is a string literal like any other.  The first version of this scan
# only matched the bare spelling, so a site written as
# `& $bash --noprofile --norc '-c' "$cmd"` was never FOUND -- it is the same
# word-splitting defect, just spelled through a quote.  The flag set is now one
# variable used by the grep, by the extraction `sed`, and by the base64-channel
# test, so the three cannot drift apart.
flag_ere='(-l?c|'"'"'-l?c'"'"'|"-l?c")'

# Self-test: the scan must recognise every spelling it claims to cover -- a
# `''`- and a `""`-quoted flag as well as the bare one -- because the grep is
# the door: a spelling it does not match is a site it never reports.  What it
# does with the matched line (classify the argument) is covered by the existing
# `case` arms and by `sites` in the summary.
st_dir=$work_dir/self-test
mkdir -p "$st_dir"
cat >"$st_dir/f.ps1" <<'ST_FIXTURE'
& $GitBashPath --noprofile --norc -c $a
& $GitBashPath --noprofile --norc '-c' $b
& $GitBashPath --noprofile --norc "-c" $c
& $GitBashPath --noprofile --norc -lc $d
& $GitBashPath --noprofile --norc '-lc' $e
ST_FIXTURE
st_hits=$(grep -nE "&[[:space:]]*\\\$[A-Za-z_][A-Za-z0-9_]*.*[[:space:]]$flag_ere[[:space:]]" "$st_dir/f.ps1" 2>/dev/null | wc -l | tr -d ' ')
if [ "$st_hits" -ne 5 ]; then
    printf 'native-argument-quoting: the script-argument matcher found %s of 5 fixture spellings\n' "$st_hits" >&2
    exit 1
fi

# crt_argc <string>
#
# Number of arguments the MSVC CRT sees when PowerShell 5.1 has built a command
# line for it.  PowerShell wraps the argument in double quotes only when it
# contains a space; inside, a `"` closes and reopens the quoted region, and a
# `""` is one literal quote.  Whitespace outside a quoted region separates
# arguments.  Anything other than 1 means the script was split.
#
# Modelled, not executed -- but checked against the five measured rows in the
# header, which is why it is written this way rather than as a quote-counting
# heuristic.
crt_argc() {
    local s=$1
    local i=0 n=${#1} ch next in_q=0 argc=0 cur=''
    # No space -> PowerShell adds no wrapper, so there is nothing to split on.
    case $s in
    *' '*) s="\"$s\"" ;;
    esac
    n=${#s}
    while [ "$i" -lt "$n" ]; do
        ch=${s:$i:1}
        next=${s:$((i + 1)):1}
        if [ "$ch" = '"' ] && [ "$next" = '"' ]; then
            cur="$cur\""
            i=$((i + 2))
            continue
        fi
        if [ "$ch" = '"' ]; then
            if [ "$in_q" -eq 1 ]; then in_q=0; else in_q=1; fi
            i=$((i + 1))
            continue
        fi
        if [ "$ch" = ' ' ] && [ "$in_q" -eq 0 ]; then
            if [ -n "$cur" ]; then argc=$((argc + 1)); fi
            cur=''
            i=$((i + 1))
            continue
        fi
        cur="$cur$ch"
        i=$((i + 1))
    done
    if [ -n "$cur" ]; then argc=$((argc + 1)); fi
    printf '%s' "$argc"
}

# The model is only worth anything if it reproduces the measurements it was
# calibrated against.  These five rows are the measured bash argv from Windows
# 10 / PowerShell 5.1.19041 (see the header).  If someone edits crt_argc, this
# fails rather than silently changing what the check accepts.
selftest_failures=0
selftest() {
    local label=$1 script=$2 expected=$3 actual
    actual=$(crt_argc "$script")
    if [ "$actual" -ne "$expected" ]; then
        printf 'native-argument-quoting: crt_argc self-test failed for %s: got %s, expected %s\n' \
            "$label" "$actual" "$expected" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
}
selftest 'inner-quote'          '# a " b' 2
selftest 'quoted-space'         'echo "hi there"' 2
selftest 'balanced-quotes'      '"$PATH" --config "x"' 1
selftest 'printf-pattern'       'printf "%s" "$MSYSTEM"' 1
selftest 'no-quote'             'for d in jq base64; do command -v $d; done' 1
if [ "$selftest_failures" -ne 0 ]; then
    printf 'native-argument-quoting: parser model is not calibrated; refusing to report a verdict\n' >&2
    exit 1
fi

violation() {
    printf '%s\n' "$1" >&2
    printf '    %s\n' "$2" >&2
    echo "VIOLATION" >>"$work_violations"
}

files=0
sites=0

ps_files=$(find "$ps_assets" -name '*.ps1' -type f | sort)
if [ -z "$ps_files" ]; then
    printf 'native-argument-quoting: no PowerShell assets found\n' >&2
    exit 1
fi

for file in $ps_files; do
    files=$((files + 1))
    rel=${file#"$root"/}

    # Every place a script string is handed to a native command.  Two shapes:
    # a raw call with -c/-lc, and this repo's base64 helper called with
    # -Script.  Both must be classified; scanning only -c would miss an unsafe
    # literal added to a helper call.
    hits=$(
        {
            grep -nE "&[[:space:]]*\\\$[A-Za-z_][A-Za-z0-9_]*.*[[:space:]]$flag_ere[[:space:]]" "$file" 2>/dev/null || true
            grep -nE 'Invoke-GitBashScript[^|]*-Script[[:space:]]' "$file" 2>/dev/null || true
        } | sort -u
    )
    [ -n "$hits" ] || hits=''

    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >"$work_hits"
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            lineno=${hit%%:*}
            text=${hit#*:}
            case $text in
            *'-Script'*) arg=${text#*-Script} ;;
            *) arg=$(printf '%s' "$text" | sed -E "s/.*[[:space:]]$flag_ere[[:space:]]+//") ;;
            esac
            # Strip leading whitespace.
            arg=$(printf '%s' "$arg" | sed -E 's/^[[:space:]]+//')

            case $arg in
            \$*)
                var=$(printf '%s' "$arg" | sed -E 's/^\$([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                sites=$((sites + 1))
                # A variable is opaque, so it must PROVE it is safe.  Two
                # acceptable proofs:
                #   * the call is to this repo's base64 helper -- its body is
                #     checked separately below, and it is the sanctioned route;
                #   * the file builds the variable from the base64 channel
                #     itself, whose alphabet [A-Za-z0-9+/=] needs no quoting.
                # Anything else (a here-string handed straight to -lc) is the
                # defect.
                case $text in
                *Invoke-GitBashScript*) : ;;
                *)
                    if ! grep -qE "\\\$$var[[:space:]]*=.*base64 -d \\| bash" "$file" 2>/dev/null; then
                        violation \
                            "$rel:$lineno: variable \$$var is handed to a native command as a script argument; PowerShell 5.1 splits it at any quoted phrase. Use the base64 transfer helper." \
                            "$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//')"
                    fi
                    ;;
                esac
                ;;
            \"*)
                # A DOUBLE-QUOTED variable, e.g. -lc "$var".  This form used to
                # fall through the `case` with no branch at all: the site was
                # found by the grep, then silently dropped, and `sites` did not
                # even increment -- so the defect this check exists for
                # (`& $GitBashPath --noprofile --norc -c "$statusCommand"`) went
                # unreported while the summary stayed green.  A double-quoted
                # variable is still opaque: PowerShell expands it before it
                # quotes the native argument, so an inner quote still ends the
                # wrapper early.  Same proof is required as for the bare form.
                var=$(printf '%s' "$arg" | sed -E 's/^"\$([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                sites=$((sites + 1))
                if [ -z "$var" ]; then
                    violation \
                        "$rel:$lineno: a double-quoted argument is handed to a native command as a script argument and its origin cannot be established." \
                        "$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//')"
                elif ! grep -qE "\\\$$var[[:space:]]*=.*base64 -d \\| bash" "$file" 2>/dev/null; then
                    violation \
                        "$rel:$lineno: a double-quoted variable is handed to a native command as a script argument; PowerShell 5.1 splits it at any quoted phrase. Use the base64 transfer helper." \
                        "$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//')"
                fi
                ;;
            \'*)
                # Inline literal.  Single-quoted PowerShell strings escape a
                # quote by doubling it; unescape before modelling.
                inner=$(printf '%s' "$arg" | sed -E "s/^'([^']*)'.*/\1/")
                inner=$(printf '%s' "$inner" | sed "s/''/'/g")
                sites=$((sites + 1))
                argc=$(crt_argc "$inner")
                if [ "$argc" -ne 1 ]; then
                    violation \
                        "$rel:$lineno: literal script argument splits into $argc arguments under PowerShell 5.1 quoting (measured mechanism: an inner double quote ends the wrapper early, then whitespace separates)." \
                        "$inner"
                fi
                ;;
            *)
                # Nothing may fall through silently.  A form the classifier does
                # not understand is exactly where a real defect hides -- the
                # double-quoted case above was invisible for that reason.
                violation \
                    "$rel:$lineno: unrecognised script-argument form; the classifier cannot prove it is safe." \
                    "$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//')"
                ;;
            esac
        done <"$work_hits"
    fi

    # Any asset that passes scripts to bash must carry the base64 channel.
    # The pipeline ends `| base64 -d | bash` OR `| base64 -d | sh` (both are
    # live in this repo -- the Windows client hands the launcher to `sh`), so
    # the decoder test is `base64 -d` alone; a decoder that is not piped into a
    # shell is caught by the "no base64 pipeline fed from..." rule below.
    if grep -qE "noprofile --norc $flag_ere[[:space:]]" "$file" 2>/dev/null; then
        if ! grep -q 'base64 -d' "$file" 2>/dev/null; then
            violation "$rel: passes a script to bash but has no base64 transfer helper" "(expected a 'printf %s <b64> | base64 -d | bash' channel)"
        fi
    fi

    if grep -q 'base64 -d' "$file" 2>/dev/null; then
        # The encoder must exist AND be fed from the script variable: an asset
        # can hold an unrelated ToBase64String (the installer does, for the
        # launcher payload), so presence alone proves nothing.
        # Up to ONE level of nesting before the script variable: agentq.ps1
        # writes `GetBytes($script)` (one paren), install-agentq.ps1 writes
        # `GetBytes($Script)` inside `GetBytes($bytes.ToArray())` helpers.  A
        # pattern that forbids `)` between the call and the variable flags the
        # first and only accepts the second, which is the wrong way round.
        # So the arm spans the whole statement instead: script variable at ANY
        # bracket depth, stopping at `;` (grep is line-based anyway).
        if ! grep -qE 'ToBase64String\([^;]*\$[Ss]cript' "$file" 2>/dev/null; then
            violation "$rel: has a base64 decoder but no encoder fed from the script variable" "(the raw script text would reach the command line)"
        fi
        # And the pipeline must be fed from the ENCODED variable, not from the
        # script or from a variable whose name says it is the script itself --
        # an encoder that exists but is not used is no channel.  The encoder's
        # OUTPUT variable is resolved from the ToBase64String assignment and
        # that name is pinned as `$encoded`, so `| base64 -d | bash` must be
        # fed by a name that is neither `$Script` nor `$script`.  (The earlier
        # rule `<any var> | base64 -d | bash` accepted `$Script | …` on any
        # file whose first alternative this one did not reach.)
        if grep -qE '\$[Ss]cript[[:space:]]*\|[[:space:]]*base64 -d' "$file" 2>/dev/null; then
            violation "$rel: the base64 pipeline is fed from the script text directly" "(the raw script reaches the command line)"
        fi
        if ! grep -qE '\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\|[[:space:]]*base64 -d \|[[:space:]]*(ba)?sh' "$file" 2>/dev/null; then
            violation "$rel: no base64 pipeline fed from an encoded variable" "(the raw script reaches the command line)"
        fi
    fi
done

count=$(wc -l <"$work_violations" | tr -d ' ')
if [ "$count" -ne 0 ]; then
    printf 'native-argument-quoting: %s violation(s)\n' "$count" >&2
    exit 1
fi

printf 'native-argument-quoting checks passed: files=%s call_sites=%s violations=%s\n' \
    "$files" "$sites" "$count"
