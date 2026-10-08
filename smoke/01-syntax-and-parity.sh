#!/usr/bin/env bash
# Smoke: every asset parses under the interpreter that will run it, and the two
# canonical server assets are byte-identical.
#
#   shell assets  -> bash -n and zsh -n
#   .ps1 assets   -> PowerShell AST parse; reports 'skipped(pwsh-absent)' if pwsh
#                    is missing and 'skipped(pwsh-unusable)' (plus a failure) if
#                    pwsh is on PATH but cannot run -- an environment fault must
#                    not be reported as seven broken assets
#   .plist assets -> XML well-formedness, plus plutil -lint on macOS
#   .yml assets   -> YAML parse (python3 + pyyaml)
#   .service      -> structural check: required sections and keys, absolute
#                    ExecStart; systemd-analyze is Linux-only and not required
#   .cmd assets   -> structural check: no CRLF assumptions, and every .cmd must
#                    delegate to the .ps1 beside it with the same flags
#   canonical     -> assets/unix/agentq-server == assets/windows-git-bash/agentq
#   version       -> AgentQ's own version is one X.Y.Z recorded in the POSIX
#                    installer, the Windows installer and README.md, and both
#                    success lines interpolate it -- not Pueue's release_version
#   tools         -> every probe tool is inventoried; one that is missing turns
#                    the summary into skipped(tool-...), which run-tests.sh
#                    routes to its PART bucket instead of a green ok
#
# These are syntax and shape checks, not behaviour.  A .cmd can be
# well-formed and still wrong; a plist can parse and still be rejected by
# launchd.  They exist because these files had NO parsing coverage at all --
# a malformed plist or a YAML typo shipped silently.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
failures=0
shell_count=0

check_shell() {
    local file=$1
    if ! bash -n "$file"; then
        printf 'bash -n FAILED: %s\n' "${file#"$root"/}" >&2
        failures=$((failures + 1))
    fi
    if command -v zsh >/dev/null 2>&1; then
        if ! zsh -n "$file"; then
            printf 'zsh -n FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
        fi
    fi
}

# Every file whose shebang names a shell interpreter, so a newly added asset
# cannot escape parsing just because its name has an unexpected extension.
while IFS= read -r file; do
    check_shell "$file"
    shell_count=$((shell_count + 1))
done < <(find "$root/skill/assets" -type f -exec sh -c '
    first=$(head -1 "$1" 2>/dev/null) || exit 0
    case "$first" in
        "#!"*) ;;
        *) exit 0 ;;
    esac
    interpreter=${first#\#!}
    interpreter=${interpreter##* }
    case "$interpreter" in
        *sh) printf "%s\n" "$1" ;;
    esac
' _ {} \; | sort)

ps_count=0
# `command -v pwsh` only proves the binary is on PATH, not that it RUNS.  A
# pwsh whose startup cache is corrupt aborts on every invocation -- and then
# every .ps1 asset is reported as "PowerShell parse FAILED", which points the
# operator at seven correct files instead of at pwsh.  Measured twice in this
# project (2026-09-26 and 2026-09-28): a damaged
# ~/.cache/powershell/StartupProfileData-NonInteractive makes pwsh die with
# `Abort trap: 6` before it reads any script, and the two crashes did not even
# share a message (`String cannot have zero length` vs `Stack overflow`).
# So probe it once, and if it cannot run, say THAT instead of blaming the assets.
pwsh_state=absent
if command -v pwsh >/dev/null 2>&1; then
    pwsh_probe_status=0
    pwsh -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
    if [ "$pwsh_probe_status" -eq 0 ]; then
        pwsh_state=usable
    else
        pwsh_state=unusable
        printf 'pwsh is on PATH but cannot run (exit %s); the .ps1 assets were NOT checked.\n' "$pwsh_probe_status" >&2
        printf 'This is an environment fault, not an asset fault -- a corrupt pwsh startup cache does this.\n' >&2
        printf 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}   # pwsh regenerates it\n' >&2
        failures=$((failures + 1))
    fi
fi

if [ "$pwsh_state" = usable ]; then
    parse_ps1=$(mktemp "${TMPDIR:-/tmp}/agentq-parse-ps1.XXXXXX.ps1")
    trap 'rm -f -- "$parse_ps1"' EXIT
    cat > "$parse_ps1" <<'PSEOF'
param([string]$Path)
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ("line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
    exit 1
}
exit 0
PSEOF
    while IFS= read -r file; do
        if ! pwsh -NoProfile -NonInteractive -File "$parse_ps1" -Path "$file" >/dev/null; then
            printf 'PowerShell parse FAILED: %s\n' "${file#"$root"/}" >&2
            pwsh -NoProfile -NonInteractive -File "$parse_ps1" -Path "$file" >&2 || true
            failures=$((failures + 1))
        fi
        ps_count=$((ps_count + 1))
    done < <(find "$root/skill/assets" -type f -name '*.ps1' | sort)
    ps_summary=$ps_count
else
    # Do not let a missing OR broken parser read as "the .ps1 assets were
    # checked".  These are distinct states: absent means the check could not run
    # here, unusable means the environment is broken -- and the latter already
    # counted a failure above.  "skipped(tool-absent)" names the tool inventory
    # below as the reason, so the summary line points at what is missing.
    case $pwsh_state in
        absent) ps_summary='skipped(tool-absent)' ;;
        *) ps_summary="skipped(pwsh-$pwsh_state)" ;;
    esac
fi

# --- tool inventory ----------------------------------------------------------
# Each probe silently stops checking something when its tool is missing, and
# "the check ran" then depends on the environment, not on the assets -- the
# same shape as the pwsh case above, which this project has now hit in four
# different tools (pwsh, pyyaml, zsh, xmllint).  So every tool this check needs
# is probed once and reported in the summary line as tool_full=N/M; when one is
# missing the summary carries skipped(tool-<names>), which run-tests.sh routes
# to its PART bucket (an honest "ran, but not fully") instead of a green ok.
# plutil is deliberately NOT in this list: it only exists on macOS, the plist
# loop documents "plutil -lint where available", and the macOS CI job is where
# that lint runs.  Counting it here would mark every Linux run partial by
# design and drown out the real gaps.
tool_total=0
tool_present=0
tool_missing=
tool_note() {
    local label=$1
    shift
    tool_total=$((tool_total + 1))
    if "$@" >/dev/null 2>&1; then
        tool_present=$((tool_present + 1))
    else
        tool_missing="$tool_missing,$label"
    fi
}
tool_note pwsh test "$pwsh_state" = usable
tool_note xmllint command -v xmllint
tool_note zsh command -v zsh
tool_note pyyaml python3 -c 'import yaml'
tool_note cmp command -v cmp
tool_note find command -v find
tool_summary=0
if [ -n "$tool_missing" ]; then
    tool_summary="skipped(tool-${tool_missing#,})"
fi

# --- .plist: XML well-formedness, and plutil -lint where available -----------
plist_count=0
plist_summary=0
while IFS= read -r file; do
    plist_count=$((plist_count + 1))
    if command -v xmllint >/dev/null 2>&1; then
        if ! xmllint --noout "$file" 2>&1; then
            printf 'plist XML FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
            continue
        fi
    fi
    if command -v plutil >/dev/null 2>&1; then
        if ! plutil -lint "$file" >/dev/null 2>&1; then
            printf 'plutil -lint FAILED: %s\n' "${file#"$root"/}" >&2
            plutil -lint "$file" >&2 || true
            failures=$((failures + 1))
            continue
        fi
    fi
    plist_summary=$((plist_summary + 1))
done < <(find "$root/skill/assets" -type f -name '*.plist' | sort)

# --- .yml: real YAML parse ---------------------------------------------------
yaml_count=0
yaml_summary=0
if python3 -c 'import yaml' >/dev/null 2>&1; then
    while IFS= read -r file; do
        yaml_count=$((yaml_count + 1))
        if ! python3 -c 'import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1], "rb").read())
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)' "$file"; then
            printf 'YAML parse FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
            continue
        fi
        yaml_summary=$((yaml_summary + 1))
    done < <(find "$root/skill/assets" -type f -name '*.yml' | sort)
else
    yaml_summary='skipped(no pyyaml)'
fi

# --- .service: structural ----------------------------------------------------
# systemd-analyze verify needs systemd, which macOS does not have, so this
# asserts the shape the unit must have rather than asking systemd.  An
# ExecStart that is not an absolute path is the failure this catches -- a
# relative one is accepted by systemd's parser and then fails at boot.
service_count=0
service_summary=0
while IFS= read -r file; do
    service_count=$((service_count + 1))
    service_ok=true
    for section in '[Unit]' '[Service]' '[Install]'; do
        grep -qF -- "$section" "$file" || {
            printf 'service FAILED (missing %s): %s\n' "$section" "${file#"$root"/}" >&2
            service_ok=false
        }
    done
    # systemd expands %h to the user's home, which is absolute, so an ExecStart
    # beginning with %h is as valid as one beginning with /.  Anything else --
    # a bare relative path, or a bare command name -- is accepted by systemd's
    # parser and then fails at boot.
    if ! grep -qE '^ExecStart=(/|%h/)[^ ]' "$file"; then
        printf 'service FAILED (ExecStart must start with / or %%h/): %s\n' "${file#"$root"/}" >&2
        service_ok=false
    fi
    if ! grep -qE '^WantedBy=' "$file"; then
        printf 'service FAILED (no WantedBy in [Install]): %s\n' "${file#"$root"/}" >&2
        service_ok=false
    fi
    if [ "$service_ok" = true ]; then
        service_summary=$((service_summary + 1))
    else
        failures=$((failures + 1))
    fi
done < <(find "$root/skill/assets" -type f -name '*.service' | sort)

# --- .cmd: structural --------------------------------------------------------
# There is no CMD parser here, so this checks the two things that actually
# break these shims: the delegation target must exist, and every .cmd must pass
# the same PowerShell flags.  A .cmd that drops -NonInteractive changes
# behaviour on a host with an interactive console, and that difference is
# invisible until something prompts.
cmd_count=0
cmd_summary=0
while IFS= read -r file; do
    cmd_count=$((cmd_count + 1))
    cmd_ok=true
    target=$(sed -n 's/.*-File "%~dp0\([^"]*\)".*/\1/p' "$file" | head -1)
    if [ -z "$target" ]; then
        printf 'cmd FAILED (no -File "%%~dp0<target>" delegation): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    elif [ ! -f "${file%/*}/$target" ]; then
        printf 'cmd FAILED (delegates to a missing file %s): %s\n' "$target" "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    # -NonInteractive must match the script being delegated to, not be present
    # unconditionally.  agentq.ps1 has no interactive construct and must never
    # block on a prompt; sshp.ps1 calls Read-Host (Confirm-Install) and drives
    # `ssh -tt` for a human session, so forcing -NonInteractive on it would
    # break the very thing it exists for.  Requiring the flag everywhere is
    # wrong, and so is omitting it everywhere -- the invariant is agreement.
    cmd_has_flag=true
    grep -q -- '-NonInteractive' "$file" || cmd_has_flag=false
    target_has_interactive=false
    if [ -n "$target" ] && [ -f "${file%/*}/$target" ]; then
        if grep -qE 'Read-Host|ShouldContinue|ReadKey' "${file%/*}/$target"; then
            target_has_interactive=true
        fi
    fi
    if [ "$target_has_interactive" = false ] && [ "$cmd_has_flag" = false ]; then
        printf 'cmd FAILED (delegates to a non-interactive script but omits -NonInteractive): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    if [ "$target_has_interactive" = true ] && [ "$cmd_has_flag" = true ]; then
        printf 'cmd FAILED (delegates to an interactive script but forces -NonInteractive): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    if [ "$cmd_ok" = true ]; then
        cmd_summary=$((cmd_summary + 1))
    else
        failures=$((failures + 1))
    fi
done < <(find "$root/skill/assets" -type f -name '*.cmd' | sort)

if ! cmp -s "$root/skill/assets/unix/agentq-server" "$root/skill/assets/windows-git-bash/agentq"; then
    printf '%s\n' 'canonical server parity FAILED: assets/unix/agentq-server != assets/windows-git-bash/agentq' >&2
    failures=$((failures + 1))
fi

# --- AgentQ's own version: one value, three records --------------------------
# The 2026-10-08 defect this replaces: both installers printed Pueue's
# release_version (the value that builds the download URL) as AgentQ's own, and
# nothing noticed because nothing read either value.  The three records must
# agree and be X.Y.Z.  The success lines must interpolate the AgentQ value --
# a revert to release_version leaves all three definitions agreeing, so the
# values alone cannot catch that shape.  Same lesson as rule E for the launcher
# protocol: one mechanism copied into several files stays consistent only if a
# check compares the copies.
version_summary=0
version_posix_line=$(grep -m1 '^agentq_version=' "$root/skill/assets/unix/install-agentq.sh" || true)
version_posix=${version_posix_line#agentq_version=}
version_posix=${version_posix#\'}
version_posix=${version_posix%\'}
version_windows_line=$(grep -m1 '^\$agentqVersion = ' "$root/skill/assets/windows-git-bash/install-agentq.ps1" || true)
version_windows=${version_windows_line#* = }
version_windows=${version_windows#\"}
version_windows=${version_windows%\"}
version_readme_line=$(grep -m1 '^\*\*Version:\*\* ' "$root/README.md" || true)
version_readme=${version_readme_line#\*\*Version:\*\* }
version_readme=${version_readme%% *}

version_recorded=
version_check_record() {
    # $1 label, $2 value
    if [ -z "$2" ]; then
        printf 'version FAILED: no AgentQ version recorded for the %s\n' "$1" >&2
        failures=$((failures + 1))
        return
    fi
    if ! printf '%s' "$2" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf 'version FAILED: the %s records "%s", which is not X.Y.Z\n' "$1" "$2" >&2
        failures=$((failures + 1))
        return
    fi
    version_recorded="$version_recorded $2"
}
version_check_record 'POSIX installer' "$version_posix"
version_check_record 'Windows installer' "$version_windows"
version_check_record 'README' "$version_readme"

version_unique_count=0
if [ -n "$version_recorded" ]; then
    version_unique_count=$(printf '%s\n' $version_recorded | sort -u | grep -c . || true)
fi
if [ -z "$version_recorded" ]; then
    printf '%s\n' 'version FAILED: no version was extracted from any of the three files; refusing to report a pass' >&2
    failures=$((failures + 1))
elif [ "$version_unique_count" -ne 1 ]; then
    printf 'version FAILED: the three records disagree -- POSIX installer "%s", Windows installer "%s", README "%s"\n' \
        "$version_posix" "$version_windows" "$version_readme" >&2
    failures=$((failures + 1))
else
    version_summary=$version_posix
fi

version_posix_success=$(grep -m1 -F 'installed at' "$root/skill/assets/unix/install-agentq.sh" || true)
case $version_posix_success in
    *'${agentq_version}'*) ;;
    *)
        printf '%s\n' 'version FAILED: install-agentq.sh success line does not interpolate ${agentq_version} -- the 2026-10-08 defect printed Pueue release_version there' >&2
        failures=$((failures + 1))
        ;;
esac
version_windows_success=$(grep -m1 -F 'installed at' "$root/skill/assets/windows-git-bash/install-agentq.ps1" || true)
case $version_windows_success in
    *'$agentqVersion'*) ;;
    *)
        printf '%s\n' 'version FAILED: install-agentq.ps1 success line does not interpolate $agentqVersion -- the 2026-10-08 defect printed Pueue releaseVersion there' >&2
        failures=$((failures + 1))
        ;;
esac

# --- config-file path patterns must still point at real files ----------------
# .gitattributes and .editorconfig name paths in order to protect them, and a
# pattern that matches nothing is not an error in either format -- it simply
# stops protecting.  When the Skill moved under skill/ on 2026-09-29,
# .editorconfig's `[assets/**]` kept parsing fine and matched zero files, so the
# section that exists to stop editors rewriting the byte-verified assets became
# a silent no-op.  Verified with a real editorconfig implementation: the two
# canonical servers resolved to end_of_line=lf / trim_trailing_whitespace=true,
# i.e. exactly what that section was written to prevent.
#
# So: every path-qualified pattern in these two files must match a real file.
config_patterns=0
config_failures=0

glob_to_regex() {
    local glob=$1 out= i=0 n c d
    # n must be computed AFTER `local glob=$1`: in `local glob=$1 n=${#glob}`
    # the expansion happens before the assignment, so n would be 0 and this
    # function would emit an empty pattern that matches nothing.
    n=${#glob}
    while [ "$i" -lt "$n" ]; do
        c=${glob:$i:1}
        case $c in
            '*')
                if [ "${glob:$((i + 1)):1}" = '*' ]; then
                    if [ "${glob:$((i + 2)):1}" = / ]; then
                        out="$out(.*/)?"; i=$((i + 3))
                    else
                        out="$out.*"; i=$((i + 2))
                    fi
                else
                    out="$out[^/]*"; i=$((i + 1))
                fi
                ;;
            '?') out="$out[^/]"; i=$((i + 1)) ;;
            '{')
                local inner= j=$((i + 1)) depth=1
                while [ "$j" -lt "$n" ] && [ "$depth" -gt 0 ]; do
                    d=${glob:$j:1}
                    [ "$d" = '{' ] && depth=$((depth + 1))
                    [ "$d" = '}' ] && depth=$((depth - 1))
                    [ "$depth" -gt 0 ] && inner="$inner$d"
                    j=$((j + 1))
                done
                out="$out(${inner//,/|})"; i=$j
                ;;
            '.'|'+'|'('|')'|'|'|'^'|'$'|'['|']'|'\\') out="$out\\$c"; i=$((i + 1)) ;;
            *) out="$out$c"; i=$((i + 1)) ;;
        esac
    done
    printf '%s' "$out"
}

pattern_matches_under() {
    local re f rel start=$root
    re="^$(glob_to_regex "$1")\$"
    [ -n "${2:-}" ] && start="$root/$2"
    while IFS= read -r f; do
        rel=${f#"$root"/}
        if [[ $rel =~ $re ]]; then
            return 0
        fi
    done < <(find "$start" -path "$root/.git" -prune -o -type f -print)
    return 1
}

pattern_matches_a_file() {
    pattern_matches_under "$1" ''
}

for config_file in .editorconfig .gitattributes; do
    [ -f "$root/$config_file" ] || continue
    while IFS= read -r pattern; do
        case $pattern in
            */*) ;;
            *) continue ;;
        esac
        config_patterns=$((config_patterns + 1))
        if ! pattern_matches_a_file "$pattern"; then
            printf '%s\n' "$config_file: pattern '$pattern' matches no file in the repository" >&2
            config_failures=$((config_failures + 1))
            failures=$((failures + 1))
        fi
    done < <(
        if [ "$config_file" = .editorconfig ]; then
            sed -n 's/^\[\(.*\)\]$/\1/p' "$root/$config_file"
        else
            sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$root/$config_file" | awk '{print $1}'
        fi
    )
done

# ...and the section that protects the assets must still exist.  Deleting it
# leaves every surviving pattern valid, so the rule above stays green while the
# protection is gone -- measured: removing the [skill/assets/**] section drops
# configpaths from 3 to 2 and the check reports a pass.
asset_protection=0
section=
while IFS= read -r line; do
    case $line in
        \[*\])
            section=${line#\[}
            section=${section%\]}
            continue
            ;;
    esac
    case $line in
        *end_of_line*unset*)
            if [ -n "$section" ] && pattern_matches_under "$section" skill/assets; then
                asset_protection=$((asset_protection + 1))
            fi
            ;;
    esac
done < "$root/.editorconfig"
if [ "$asset_protection" -eq 0 ]; then
    printf '%s\n' '.editorconfig: no section sets end_of_line = unset for anything under skill/assets -- the byte-verified assets are no longer protected from editor rewrites' >&2
    failures=$((failures + 1))
fi

# A pattern count of zero means the extraction broke, not that there was
# nothing to check -- the same reasoning as the shell-asset enumeration above.
if [ "$config_patterns" -eq 0 ]; then
    printf '%s\n' 'no config-file path patterns were extracted; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# Zero shell assets parsed means the enumeration itself failed (missing find,
# wrong root), not that there was nothing to check.
if [ "$shell_count" -eq 0 ]; then
    printf '%s\n' 'no shell assets were enumerated; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'syntax-and-parity: %s failure(s)\n' "$failures" >&2
    exit 1
fi
summary=$(printf 'syntax-and-parity checks passed: shell=%s ps1=%s plist=%s yml=%s service=%s cmd=%s configpaths=%s parity=ok version=%s tool_full=%s/%s' \
    "$shell_count" "$ps_summary" "$plist_summary" "$yaml_summary" "$service_summary" "$cmd_summary" "$config_patterns" "$version_summary" "$tool_present" "$tool_total")
[ "$tool_summary" = 0 ] || summary="$summary $tool_summary"
printf '%s\n' "$summary"
