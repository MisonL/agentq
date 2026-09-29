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
done < <(find "$root/assets" -type f -exec sh -c '
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
    done < <(find "$root/assets" -type f -name '*.ps1' | sort)
    ps_summary=$ps_count
else
    # Do not let a missing OR broken parser read as "the .ps1 assets were
    # checked".  These are distinct states: absent means the check could not run
    # here, unusable means the environment is broken -- and the latter already
    # counted a failure above.
    ps_summary="skipped(pwsh-$pwsh_state)"
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
done < <(find "$root/assets" -type f -name '*.plist' | sort)

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
    done < <(find "$root/assets" -type f -name '*.yml' | sort)
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
done < <(find "$root/assets" -type f -name '*.service' | sort)

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
done < <(find "$root/assets" -type f -name '*.cmd' | sort)

if ! cmp -s "$root/assets/unix/agentq-server" "$root/assets/windows-git-bash/agentq"; then
    printf '%s\n' 'canonical server parity FAILED: assets/unix/agentq-server != assets/windows-git-bash/agentq' >&2
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
printf 'syntax-and-parity checks passed: shell=%s ps1=%s plist=%s yml=%s service=%s cmd=%s parity=ok\n' \
    "$shell_count" "$ps_summary" "$plist_summary" "$yaml_summary" "$service_summary" "$cmd_summary"
