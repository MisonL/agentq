#!/usr/bin/env bash
# Smoke: the Windows installers keep the invariants that six real defects broke.
#
# Every rule below exists because the corresponding defect shipped and was only
# caught by running the installer on a real Windows host.  None of them is
# hypothetical, and none of them is visible to any other check in this suite --
# the installers have no behavioural coverage (they need a Windows host and a
# real queue), so these source-level invariants are the only automatic guard.
#
# The defects, and the rule each produced:
#
#   1. A hard-coded 1 MiB ceiling on `pueue status --json` refused to update a
#      host with enough history (measured: 1507407 bytes, 270 tasks).
#      -> RULE A: any JSON read limit must be a parameter with a call site that
#         can raise it, never a bare literal at the read site.
#   2. The same ceiling sat on the health check.
#      -> RULE A again (this is why the rule checks every read, not one).
#   3. `& $exe ... 1> $file` decoded native stdout through the console code page
#      and re-encoded as UTF-16LE, doubling the file and corrupting non-ASCII.
#      -> RULE B: JSON destined for a parser must not be written by redirect.
#   4. A client `chmod 700` was a silent no-op (Git for Windows mounts noacl) and
#      reported success.
#      -> RULE C: the Windows client installer must not call chmod at all.
#   5. An ACL was set without verifying it landed.
#      -> RULE D: Set-Acl must be followed by a read-back in the same function.
#   6. The launcher payload protocol exists in three copies (launcher, Windows
#      client, POSIX client) with nothing keeping them in step; raising the
#      ceiling in one alone passed every other check in the suite.
#      -> RULE E: the three copies must agree (see 10-launcher-parity.py).
#   7. The server installer read `$acl.AccessRulesProtected`, which is not a
#      property of a .NET ACL object -- the real name is
#      `AreAccessRulesProtected`.  Under `Set-StrictMode -Version Latest` a
#      nonexistent property throws, so the ACL verification step aborted every
#      install at that line.  The CLIENT installer had the correct spelling all
#      along, so the two copies disagreed and only one was ever exercised on a
#      real host (2026-09-24, measured on Windows 10 / PS 5.1.19041: the
#      installer rolled back cleanly, deployment untouched).
#      -> RULE F: an ACL-object property read must use a name that actually
#         exists on the type.
#   8. No incident -- a gap found by reading: both POSIX installers `mv` files
#      into place and then re-check the result, and the two implementations are
#      independent (client_move_* vs installer_move_*), so "change one, forget
#      the other" was possible with nothing guarding it.  Listed here for
#      completeness: unlike 1-7 this rule was not written in response to a
#      failure observed on a real host.
#      -> RULE G: an `mv` into a destination must be re-checked in the same
#         function.
#   9. `Restore-ScheduledTaskDefinition` guarded its `Register-ScheduledTask
#      -Xml $Definition` with `if ($null -ne $Definition)`, but the parameter is
#      `[AllowNull()][string]` -- and PowerShell coerces `$null` to `""` for a
#      `[string]` parameter.  So the guard PASSED on the first-install case
#      (there was no previous task, `Get-ScheduledTaskDefinition` returned
#      `$null`), and `Register-ScheduledTask -Xml ""` threw a parameter
#      validation error.  Every FIRST install that failed reported
#      "rollback is incomplete" and left recovery artifacts behind -- a clean
#      failure described as a broken rollback.  Measured on Windows 10 /
#      PS 5.1.19041.3996: binding `$null` to `[AllowNull()][string]` reports
#      isNull=False / isNullOrEmpty=True.  The sibling guard one function away
#      (`Remove-AgentQInstallerResponseTemporaryFile`, `$ExpectedIdentity`)
#      already tested `[string]::IsNullOrWhiteSpace`; this site alone did not.
#      -> RULE H: a guard on a `[string]`-typed value must test for empty, not
#         for `$null`.
#
#  10. The POSIX installer rendered the launchd daemon plist with three `sed`
#      substitutions and never checked that any of them MATCHED -- so a template
#      and its sed list could drift apart and ship a plist whose ProgramArguments
#      is literally "__AGENTQ_HOME__/pueued", which launchd cannot exec.  The
#      Windows renderer guards this in both directions (throws when the template
#      LACKS the placeholder, throws again when the rendered text RETAINS it);
#      the POSIX site had neither.  Measured: renaming a placeholder left
#      01/10/11 all green, because plutil -lint only checks XML well-formedness.
#      -> RULE I: every placeholder a rendered template carries must be known to
#         its renderer, and the renderer must refuse a retained placeholder.
#
# What this proves: the shape is absent from these files.  What it does not
# prove: that the installers work -- that still needs a real host.  A rule here
# passing means "this specific failure cannot recur silently", not "correct".
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

failures=0
rules_checked=0

server_installer="$root/skill/assets/windows-git-bash/install-agentq.ps1"
client_installer="$root/skill/assets/client/windows/install-client.ps1"
for file in "$server_installer" "$client_installer"; do
    [ -f "$file" ] || {
        printf 'installer-invariants: missing %s\n' "${file#"$root"/}" >&2
        exit 1
    }
done

fail() {
    printf '%s: %s\n' "${1#"$root"/}" "$2" >&2
    failures=$((failures + 1))
}

# --- RULE A: the JSON read limit must be raisable ----------------------------
# The defect was not "a limit exists" but "the limit is a literal no caller can
# change", which made the installer refuse to update a host whose status had
# outgrown it.  Two things must hold, and the distinction matters: the reader
# must take a defaulted parameter, AND at least one call site must raise it.
# A small bounded payload (group query, launcher smoke) legitimately takes the
# default -- demanding an explicit limit everywhere would be wrong, and the
# comment at the reader says so.
#
# EVERY declaration is checked, not just the first match.  There are three
# `[int]$MaximumBytes` parameters here; asserting only that *one* of them
# carries a default leaves the other two free to lose theirs -- a mutation that
# strips the default from two of the three was measured to slip through the
# one-match version of this rule.
rules_checked=$((rules_checked + 1))
declarations=$(grep -nE '\[int\]\$MaximumBytes' "$server_installer" || true)
if [ -z "$declarations" ]; then
    fail "$server_installer" "no [int]\$MaximumBytes parameter found at all; the reader's limit is no longer raisable by a caller"
else
    while IFS= read -r decl; do
        if ! printf '%s' "$decl" | grep -qE '\[int\]\$MaximumBytes = [0-9]+'; then
            fail "$server_installer" "line ${decl%%:*} declares -MaximumBytes with no default; a caller that omits it gets an unusable limit"
        fi
    done <<EOF
$declarations
EOF
fi

rules_checked=$((rules_checked + 1))
if ! grep -qE 'Read-AgentQInstallerJsonFile .*-MaximumBytes \$[A-Za-z_]' "$server_installer"; then
    fail "$server_installer" "no call site can raise the JSON limit; every read is capped at the default, which is how a grown status payload broke the installer"
fi

# And the reader must not also carry an inline ceiling that would cap a caller's
# larger value.  The parameter is the only limit.
rules_checked=$((rules_checked + 1))
if grep -qE '^\s*\$maximumJsonBytes = [0-9]+' "$server_installer"; then
    fail "$server_installer" "Read-AgentQInstallerJsonFile hard-codes a byte ceiling instead of using its parameter"
fi

# --- RULE B: a redirect-written JSON file requires a BOM-aware reader --------
# `& $exe ... 1> $file` makes PowerShell decode the child's stdout through the
# console code page and re-encode it as UTF-16LE with a BOM, doubling the byte
# count.  That was a real defect when the reader assumed UTF-8 -- but the reader
# has since been hardened to detect the BOM, and it was verified on a real host
# that a redirected file is read back correctly.  So "never redirect" would be
# the wrong rule: it would flag working code.
#
# The invariant that actually matters is the COUPLING.  These three sites still
# depend on the reader staying BOM-aware; if that handling is ever dropped they
# fail silently, and the redirect is why.  This rule states the dependency
# instead of forbidding the pattern.
#
# SCOPE, and why it is the function and not the file: the first version of this
# rule grepped for '0xFF' anywhere in the file.  Measured: deleting the BOM
# handling from Read-AgentQInstallerJsonFile -- the reader every redirect site
# actually uses -- left the rule GREEN, because Read-AgentQInstallerTemplateFile
# still contained the same two byte constants.  A whole-file presence test
# proves nothing about the reader that matters.  So the rule now extracts the
# reader's own body and requires the detection inside it, exactly as rule D
# scopes to its function.
rules_checked=$((rules_checked + 1))
redirect_sites=$(grep -nE '& .*1> \$' "$server_installer" 2>/dev/null | grep -v '1> \$null' | grep -vE ':[[:space:]]*#' || true)
if [ -n "$redirect_sites" ]; then
    # The reader that consumes those redirects.  Every redirect site is followed
    # by a Read-AgentQInstallerJsonFile call; if a future site uses a different
    # reader, the extraction below will not find BOM handling in THIS one and
    # the rule fires -- which is the safe direction.
    reader_body=$(awk '/^function Read-AgentQInstallerJsonFile/ { in_fn = 1 }
                       in_fn { print }
                       in_fn && /^}/ { exit }' "$server_installer")
    if ! printf '%s' "$reader_body" | grep -q '0xFF' ||
        ! printf '%s' "$reader_body" | grep -q '0xFE'; then
        while IFS= read -r line; do
            fail "$server_installer" "line ${line%%:*} writes JSON by redirect, but its reader (Read-AgentQInstallerJsonFile) has no BOM detection; the UTF-16LE output would not parse"
        done <<EOF
$redirect_sites
EOF
    fi
fi

# --- RULE C: the Windows client installer must not call chmod ----------------
# chmod cannot work on a noacl mount and does not report failure, so any chmod
# here is a silent no-op.  ACLs are the only mechanism that applies.
rules_checked=$((rules_checked + 1))
chmod_calls=$(grep -nE '^[^#]*chmod[[:space:]]+[0-7]' "$client_installer" || true)
if [ -n "$chmod_calls" ]; then
    while IFS= read -r line; do
        fail "$client_installer" "chmod is a silent no-op on a noacl mount: $(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]]+//')"
    done <<EOF
$chmod_calls
EOF
fi

# --- RULE D: Set-Acl must be verified by a read-back -------------------------
# The defect was not a wrong ACL but an unverified one: the call succeeded and
# nothing changed.  A Set-Acl with no Get-Acl after it in the same file is the
# shape that let that through.
#
# Scoped to the ENCLOSING FUNCTION, not to a fixed line window.  A window is
# wrong in both directions: the read-back here sits six lines after the write
# (comment included), and a window wide enough for it would also accept a
# read-back belonging to the *next* function.  The function body is the unit
# that must be self-verifying.
rules_checked=$((rules_checked + 1))
for file in "$server_installer" "$client_installer"; do
    while IFS=$'\t' read -r lineno where; do
        [ -n "$lineno" ] || continue
        fail "$file" "line $lineno calls Set-Acl with no Get-Acl read-back in the same function ($where)"
    done < <(awk '
        FNR == NR {
            if ($0 ~ /^function [A-Za-z0-9_-]+[ \t]*\{/) { name = $2; start = FNR; infunc = 1 }
            else if (infunc && $0 ~ /^\}/) { n++; fname[n] = name; fstart[n] = start; fend[n] = FNR; infunc = 0 }
            next
        }
        /Set-Acl[ \t]/ { nsa++; sa[nsa] = FNR }
        /Get-Acl[ \t(]/ { nga++; ga[nga] = FNR }
        END {
            for (i = 1; i <= nsa; i++) {
                s = sa[i]; owner = 0
                for (j = 1; j <= n; j++) if (s > fstart[j] && s <= fend[j]) owner = j
                if (owner == 0) { print s "\ttop level"; continue }
                ok = 0
                for (k = 1; k <= nga; k++) if (ga[k] > s && ga[k] <= fend[owner]) ok = 1
                if (!ok) print s "\t" fname[owner]
            }
        }
    ' "$file" "$file")
done

# --- RULE F: ACL property names must exist on the .NET type ------------------
# `AccessRulesProtected` is not a property of FileSecurity/DirectorySecurity; the
# real name is `AreAccessRulesProtected`.  The typo is invisible to every other
# check here: rule D only requires that a Get-Acl read-back EXISTS, and a check
# that merely greps for `Set-Acl` sees the read-back and is satisfied.  Under
# `Set-StrictMode -Version Latest` -- which every asset in this repo sets -- the
# bad name throws at runtime instead of evaluating to $null, so the whole
# verification step dies.  Only a real Windows host can execute that line, which
# is exactly why the name is pinned here at the source level.
#
# The allowed set is the documented property surface this repo actually uses,
# not a general ACL API model: a name outside it is either a typo or a new
# dependency that should be added deliberately.
rules_checked=$((rules_checked + 1))
# `AccessControlType` is a real property of an AccessRule (read off rule objects
# in the Where-Object filters above), NOT an ACL-object property.  It is in the
# allowlist because the matcher cannot tell which object a property is read
# from; the allowlist is "names that exist on one of the two types this repo
# reads", and the typo this rule exists for -- `AccessRulesProtected` -- is
# absent from it either way.
acl_property_allowlist='AreAccessRulesProtected AreAccessRulesCanonical Access AccessControlType Owner Group'
for file in "$server_installer" "$client_installer"; do
    # The variables that hold an ACL object in THIS file.
    acl_vars=$(grep -oE '\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*Get-Acl' "$file" 2>/dev/null |
        sed -E 's/^\$([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u)
    for acl_var in $acl_vars; do
    while IFS=$'\t' read -r lineno prop; do
        [ -n "$lineno" ] || continue
        case " $acl_property_allowlist " in
            *" $prop "*) ;;
            *) fail "$file" "line $lineno reads ACL property '$prop', which is not a property of the .NET ACL type" ;;
        esac
    done < <(awk '
        # EVERY `$x.Property` is collected and checked against the allowlist --
        # not just ones beginning with a known prefix.  The first version
        # matched only /AreAccess*|Access*|Owner|Group/, so a typo that fell
        # outside those prefixes (`$acl.Acess`) never reached the comparison at
        # all.  Measured: that mutation stayed green.  Collecting everything
        # makes the allowlist the single source of truth, which is what the
        # rule always claimed to be.
        #
        # No \b here: BSD awk (macOS) does not support it.  Measured: with \b
        # the match returned RSTART=0 and the rule silently passed the very
        # defect it exists to catch.
        # Scope: only variables that HOLD an ACL object -- i.e. assigned from
        # Get-Acl.  Collecting every `$x.Prop` produced 313 false positives
        # (methods like RemoveAccessRule, `$_` pipeline properties, namespace
        # member access), which is noise, not a rule.  But matching only names
        # beginning with a known prefix was too NARROW: `$acl.Acess` (one c
        # short) never reached the comparison at all and the mutation stayed
        # green.  Binding to the variable gives both: anything read off an ACL
        # object is checked, whatever it is spelled like.
        FILENAME == aclvar_file && $0 ~ ("^[[:space:]]*" aclvar "[[:space:]]*=[[:space:]]*Get-Acl") { holds = 1 }
        {
            rest = $0
            while (match(rest, /\$[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*/)) {
                name = substr(rest, RSTART, RLENGTH)
                var = name
                sub(/\..*$/, "", var)
                sub(/^\$/, "", var)
                sub(/^\$[A-Za-z_][A-Za-z0-9_]*\./, "", name)
                # A method call is not a property read.
                after = substr(rest, RSTART + RLENGTH, 1)
                if (after != "(" && var == aclvar) print FNR "\t" name
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    ' aclvar="$acl_var" aclvar_file="$file" "$file")
    done
done

# --- RULE E: the launcher protocol text must agree across all three copies ---
# The same "read a base64 payload from stdin, enforce a character ceiling, call
# agentq-launcher.ps1 -ArgumentsBase64" logic is written out three times: in the
# launcher itself, in the Windows client, and once more inside the POSIX client
# (compressed to one line, embedded in a base64 -EncodedCommand wrapper).  That
# is the same shape as the two canonical agentq-server copies and carries the
# same risk -- the ceiling and the exit codes ARE the protocol, so a copy that
# drifts is a client and a launcher that disagree.
#
# Measured before this rule existed: raising the ceiling in the POSIX copy alone
# to 1048577 -- a payload that client would send and the launcher would refuse
# with exit 2 -- passed every other check in the suite, including 01's parity
# assertion, which only ever compared the two agentq-server files.
#
# The comparison lives in 10-launcher-parity.py.  It compares token sequences
# rather than bytes, because the POSIX copy is a single line joined with `;`
# while the Windows copy is indented -- a byte comparison would be red on
# correct code.  Four divergence classes were verified to be caught: a changed
# ceiling in either embedded wrapper, a changed ceiling in the launcher itself,
# a changed exit code, and a dropped branch.
rules_checked=$((rules_checked + 1))
launcher_ps1="$root/skill/assets/windows-git-bash/agentq-launcher.ps1"
client_ps1="$root/skill/assets/client/windows/agentq.ps1"
client_posix="$root/skill/assets/client/unix/agentq"
parity_py="$root/smoke/10-launcher-parity.py"
missing=0
for file in "$launcher_ps1" "$client_ps1" "$client_posix" "$parity_py"; do
    if [ ! -f "$file" ]; then
        fail "$file" "missing; the launcher protocol copies cannot be compared"
        missing=1
    fi
done
if [ "$missing" -eq 0 ]; then
    if ! parity_output=$(python3 "$parity_py" "$launcher_ps1" "$client_ps1" "$client_posix" 2>&1); then
        while IFS= read -r problem; do
            [ -n "$problem" ] || continue
            fail "$client_posix" "launcher protocol divergence: $problem"
        done <<EOF
$parity_output
EOF
    fi
fi

# --- RULE G: an `mv` into a destination must be re-checked afterwards --------
# Both POSIX installers replace files with `mv` and then verify the result: the
# source is gone, the destination exists, is a regular file, is not a symlink,
# and its path chain is still safe.  That re-check is the whole reason the move
# is trusted -- the installers' own comments say so, and it is the same lesson
# the Windows side learned when `chmod` "succeeded" and changed nothing.
#
# Measured today: all 16 move sites across the two installers are followed by a
# re-check, and the two implementations are INDEPENDENT (client_move_* vs
# installer_move_*) -- they only share `fail()` and `cleanup_on_exit()`.  So
# "change one, forget the other" is possible, and nothing guarded it.
#
# What this rule asserts is deliberately weaker than "the move is atomic": it
# asserts the re-check is PRESENT.  A shell script cannot prove atomicity, and
# claiming otherwise would be the kind of overstatement this project keeps
# catching.
#
# Scope: the two POSIX installers only.  The Windows installers replace files
# through .NET APIs (Move-Item / File.Replace) inside an ACL'd transaction, so
# the shell idiom does not apply there and asserting it would be a false rule.
posix_installers="$root/skill/assets/client/unix/install-client.sh $root/skill/assets/unix/install-agentq.sh"
for posix_installer in $posix_installers; do
    [ -f "$posix_installer" ] || {
        printf 'installer-invariants: missing %s\n' "${posix_installer#"$root"/}" >&2
        exit 1
    }
    rules_checked=$((rules_checked + 1))
    # The window is the ENCLOSING FUNCTION, not a fixed line count.  My first
    # version used 9 lines and produced two false positives: the re-checks at
    # lines 1804 and 1852 sit 18 lines below their `mv` (inside an `if ! mv`
    # branch there is a recovery block first).  That is the same mistake RULE D
    # documents one rule above -- a fixed window is wrong in both directions,
    # too narrow here and too wide when it swallows the next function's check.
    while IFS=: read -r mv_line mv_text; do
        [ -n "$mv_line" ] || continue
        # A bare `mv` mentioned inside a required-command list is not a move.
        case "$mv_text" in *required_command*) continue ;; esac
        # `end` must be the FIRST `^}` after the move -- the enclosing
        # function's closing brace.  My first version kept overwriting `end`
        # with every later `^}`, so the scan ran to the end of the FILE and
        # matched some other function's `is_safe`.  Measured: deleting the
        # re-check from move_client_file still reported green.  That is the
        # "window too wide" half of the mistake RULE D documents.
        recheck=$(awk -v start="$mv_line" '
            { lines[NR] = $0 }
            END {
                fn = 0
                for (i = start; i >= 1; i--) {
                    if (lines[i] ~ /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/) { fn = i; break }
                }
                if (fn == 0) { fn = 1 }
                end = 0
                for (i = start + 1; i <= NR; i++) {
                    if (lines[i] ~ /^}/) { end = i; break }
                }
                if (end == 0) { end = start + 40 }
                for (i = start + 1; i <= end; i++) {
                    # Comments do not count.  Measured: replacing the re-check in
                    # move_client_file with the COMMENT "# the caller is expected
                    # to verify the result afterwards" left this rule GREEN --
                    # the word "verify" in prose satisfied a rule about code.
                    line = lines[i]
                    sub(/^[[:space:]]+/, "", line)
                    if (line ~ /^#/) continue
                    # A re-check is a CALL or a comparison, not a mention.  The
                    # substring test also accepted a call to a function that does
                    # not exist (`verify_client_move_telemetry`), so require the
                    # name to appear in call position -- followed by an argument
                    # list or a space -- or one of the explicit comparison forms.
                    # Bash calls are `name arg`, not `name(arg)`, so the name
                    # must be followed by whitespace or an open paren.  A bare
                    # `is_safe` substring test accepted `verify_client_move_
                    # telemetry` -- a call to a function that does not exist --
                    # so the name has to be a whole token AND be one of the
                    # helpers this repo actually defines.
                    if (line ~ /(^|[^A-Za-z0-9_])installer_(tree|path|directory|regular_file|existing_regular_file|file_identity)[a-z_]*([[:space:]]|\()/ ||
                        line ~ /(^|[^A-Za-z0-9_])path_chain_is_safe([[:space:]]|\()/ ||
                        line ~ /(^|[^A-Za-z0-9_])path_is_absent([[:space:]]|\()/ ||
                        line ~ /move identity check failed/) { print "yes"; exit }
                    # A `verify_*` call counts ONLY if the file actually defines
                    # it.  Measured: `verify_client_move_telemetry || return 1`
                    # -- a call to a function that does not exist -- passed the
                    # previous version, which accepted the name as a substring.
                    # The name is emitted for the shell to resolve.
                    if (match(line, /(^|[^A-Za-z0-9_])verify_[a-z_]*[[:space:]]*(\()?/)) {
                        name = substr(line, RSTART, RLENGTH)
                        sub(/^[^A-Za-z0-9_]*/, "", name)
                        sub(/[[:space:]]*\(?$/, "", name)
                        if (name != "") { print "call:" name; exit }
                    }
                }
            }' "$posix_installer")
        case "$recheck" in
        yes) ;;
        call:*)
            # The re-check calls a helper; it only counts if that helper exists.
            helper=${recheck#call:}
            if ! grep -qE "^[a-zA-Z_][a-zA-Z0-9_]*\(\)" "$posix_installer" ||
                ! grep -qE "^${helper}\(\)" "$posix_installer"; then
                fail "$posix_installer" "line $mv_line moves a file and the only re-check is a call to '$helper', which this file does not define"
            fi
            ;;
        *)
            fail "$posix_installer" "line $mv_line moves a file but nothing in its enclosing function re-checks the result; a move whose outcome is not verified is how 'the call succeeded and changed nothing' ships"
            ;;
        esac
    done <<EOF
$(grep -nE '(^|[[:space:]])(run_as_root[[:space:]]+)?mv([[:space:]]|$)' "$posix_installer" | grep -vE '^[0-9]+:[[:space:]]*#')
EOF
done

# --- RULE H: a [AllowNull()][string] guard must test for empty, not $null -----
# PowerShell coerces $null to "" for a [string] parameter, so `$null -ne $x` is
# TRUE when $x is the empty string.  A guard written that way passes on exactly
# the empty value it was meant to reject.
#
# The defect this pins: `Restore-ScheduledTaskDefinition` guarded
# `Register-ScheduledTask -Xml $Definition` with `$null -ne $Definition`, so the
# first-install case (no previous task, `Get-ScheduledTaskDefinition` returned
# `$null`) fell through to `-Xml ""` and threw a parameter-validation error --
# turning a clean first-install failure into a reported "rollback is incomplete"
# with recovery artifacts left behind.  The sibling guard one function away
# (`Remove-AgentQInstallerResponseTemporaryFile`, `$ExpectedIdentity`) already
# tested `[string]::IsNullOrWhiteSpace`; this site alone did not.
#
# Scope: only parameters declared `[AllowNull()][string]`.  A `[string]`
# parameter WITHOUT AllowNull cannot bind $null at all -- the binder rejects it
# -- so a $null guard there is redundant rather than wrong, and matching every
# `[string]` parameter produced false positives on local variables named `$item`
# that hold filesystem objects.  The AllowNull attribute is precisely what makes
# a $null guard look necessary while being ineffective.
rules_checked=$((rules_checked + 1))
for file in "$server_installer" "$client_installer"; do
    allownull_vars=$(grep -oE '\[AllowNull\(\)\][[:space:]]*\[string\][[:space:]]*\$[A-Za-z_][A-Za-z0-9_]*' "$file" 2>/dev/null |
        sed -E 's/.*\$//' | sort -u || true)
    for var in $allownull_vars; do
        # `grep -vE '^[0-9]+:[[:space:]]*#'` drops comments.  A comment is not a
        # guard, and the fix for this very defect quotes the bad pattern in one
        # -- a rule that counted it would fail the corrected file.
        while IFS=: read -r lineno text; do
            [ -n "$lineno" ] || continue
            fail "$file" "line $lineno guards [AllowNull()][string] \$$var with a \$null comparison; PowerShell coerces \$null to \"\" for [string], so the guard passes on the empty value"
        done <<EOF
$(grep -nE "\\\$null[[:space:]]+-(eq|ne)[[:space:]]+\\\$$var([^A-Za-z0-9_]|$)|\\\$$var[[:space:]]+-(eq|ne)[[:space:]]+\\\$null([^A-Za-z0-9_]|$)" "$file" 2>/dev/null |
    grep -vE '^[0-9]+:[[:space:]]*#' || true)
EOF
    done
done

# --- RULE I: a rendered template's placeholders must be substituted -----------
# Three templates in this repo are rendered by substituting `__AGENTQ_*__`
# tokens: the launchd daemon plist (POSIX installer, three sed rules), the
# Windows pueue.yml and the Windows launcher (PowerShell installer, .Replace).
# A token that survives into the rendered output means the template and the
# renderer's substitution list have drifted apart; the artifact then ships with
# a literal "__AGENTQ_...__" where a path belongs, and the failure surfaces only
# at run time -- launchd execs a nonexistent path, or the daemon starts with the
# wrong Git Bash.
#
# The Windows renderer already guards BOTH directions for both of its templates:
# it throws when the template LACKS the placeholder, and again when the RENDERED
# text RETAINS it.  The POSIX site had neither.  Measured before the fix
# (2026-10-03): renaming a plist placeholder so the installer no longer knows it
# left 01/10/11 all green (plutil -lint only checks XML well-formedness --
# "__AGENTQ_X__/pueued" is a perfectly valid string), and breaking the sed
# pattern the same way was equally invisible.
#
# Scope: exactly the templates a renderer substitutes.  The legacy
# `com.agentq.pueued.plist` is NOT rendered (only require_file'd; it is a
# leftover of an older install path), so holding it to the same token set would
# fail correct code -- it is named here so the omission is deliberate.
rules_checked=$((rules_checked + 1))
# template|renderer|guard-marker triples.  Both renderers must know every token
# their template carries, and each must carry a runtime guard that refuses a
# retained token.  The delimiter is `|`, not `:` -- the guard markers contain
# spaces and, on a host whose paths contain a colon, so could the paths.
render_pairs="\
$root/skill/assets/unix/com.agentq.pueued.daemon.plist|$root/skill/assets/unix/install-agentq.sh|retained a template placeholder
$root/skill/assets/windows-git-bash/pueue.yml|$root/skill/assets/windows-git-bash/install-agentq.ps1|retained the Git Bash runtime placeholder
$root/skill/assets/windows-git-bash/agentq-launcher.ps1|$root/skill/assets/windows-git-bash/install-agentq.ps1|retained the Git Bash launcher placeholder"
render_pairs_seen=0
while IFS='|' read -r template renderer guard_marker; do
    [ -n "$template" ] || continue
    render_pairs_seen=$((render_pairs_seen + 1))
    # Self-check: both extractors must find something, or the comparison below is
    # vacuously true and the rule would pass on any input.  A rule that cannot
    # fail is worse than no rule -- the false-green this repo keeps hitting.
    template_tokens=$(grep -oE '__[A-Z][A-Z0-9_]*__' "$template" 2>/dev/null | sort -u)
    renderer_tokens=$(grep -oE '__[A-Z][A-Z0-9_]*__' "$renderer" 2>/dev/null | sort -u)
    if [ -z "$template_tokens" ] || [ -z "$renderer_tokens" ]; then
        fail "$template" "placeholder extraction found nothing (template=[$template_tokens] renderer=[$renderer_tokens]); the rule cannot conclude"
        continue
    fi
    # Every template placeholder must be known to the renderer (present in its
    # source, i.e. named by a substitution).  A token only in the template is one
    # nothing substitutes -- exactly the drift this rule exists for.
    for token in $template_tokens; do
        if ! printf '%s\n' "$renderer_tokens" | grep -qxF -- "$token"; then
            fail "$template" "placeholder $token appears in the template but not in ${renderer#"$root"/}: nothing substitutes it, so it would ship literally"
        fi
    done
    # The renderer must also REFUSE a retained placeholder at run time, or a
    # future drift is caught only by this static rule and never at install time.
    if ! grep -qF -- "$guard_marker" "$renderer"; then
        fail "$renderer" "no runtime guard refuses a retained placeholder for ${template#"$root"/} (expected marker: $guard_marker)"
    fi
done <<EOF
$render_pairs
EOF
# The pair list must not have silently emptied -- that would make the whole rule
# vacuous while still reporting green.
if [ "$render_pairs_seen" -lt 3 ]; then
    fail "smoke/10" "template/renderer pair list yielded $render_pairs_seen pair(s), expected 3; the rule is not checking what it claims"
fi

# --- RULE J: the maintenance lock must be released even if cleanup fails -----
# Both installers hold a maintenance lock across the deployment and release it in
# the `finally` of the top-level try.  In PowerShell a `throw` inside a `finally`
# REPLACES the in-flight exception and aborts the rest of the block, so a cleanup
# step that threw would skip the release entirely.  Measured 2026-10-05 by
# reproducing the structure under pwsh: with the old shape, a failing
# Remove-SafeTransactionDirectory made the reported error the CLEANUP error --
# hiding the real install failure -- and Release-MaintenanceLock never ran, so the
# next invocation found a stale lock and refused.  Both symptoms at once.
#
# The invariant is about REACHABILITY, not about a particular keyword: the lock
# release has to sit somewhere that a failing sibling statement cannot jump over.
# Asserting "no throw anywhere in the finally" would be both too broad (the
# release itself is entitled to throw when the lock genuinely cannot be removed --
# that is a real condition the operator must see) and too weak (the throw could
# simply move above the release and the rule would pass).  So the rule extracts
# the cleanup region and requires the release to be wrapped in its own `finally`,
# which is the one construct that is unconditional.
#
# Scope: the SERVER installer only -- it is the one that takes a maintenance lock.
# The client installer has the same finally-masking shape but no lock, so its
# invariant is different and is rule K below.  This is a source-level invariant by
# necessity -- neither installer is executable on this host, so there is no
# behavioural alternative here.  See this file's header for why that is still
# worth having.
rules_checked=$((rules_checked + 1))
cleanup_regions=$(awk '
    # The cleanup is the LAST top-level `} finally {` in each installer: the one
    # that closes the deployment try/catch/finally.  Anchoring on `^}` (column 1)
    # is what makes this the top-level block rather than a nested one.  The
    # opening line itself matches the `^}` end pattern, so the end is only
    # considered on a line AFTER the opening one -- otherwise the block is the
    # opening line alone and the extraction is empty of everything that matters.
    /^\} finally \{/ { buf = $0 "\n"; capturing = 1; next }
    capturing { buf = buf $0 "\n" }
    capturing && /^\}/ { last = buf; capturing = 0 }
    END { printf "%s", last }
' "$server_installer")
if [ -z "$cleanup_regions" ]; then
    fail "$server_installer" "could not extract the top-level cleanup finally; rule J cannot conclude"
else
    # Locate the last NESTED `} finally {` (line 1 of the region is the outer
    # opener itself and must not count -- a version of this rule that let it count
    # passed a mutation with no nested finally at all, measured), then require the
    # release statement to sit INSIDE it, before its closing brace.
    #
    # "Inside" is decided by brace depth, not by line order: a release placed after
    # the nested finally has closed is a sibling of it, reachable only if nothing
    # threw -- which is exactly the defect.  Depth is the only thing that tells the
    # two apart, and it is what an awk scan can actually establish.
    #
    # The call is matched, not the bare word: the explanatory comment above the
    # block names Release-MaintenanceLock too, and anchoring on that line would
    # make the rule measure the comment instead of the statement.
    release_verdict=$(printf '%s\n' "$cleanup_regions" | awk '
        { line[NR] = $0 }
        END {
            nested = 0
            for (i = 2; i <= NR; i++) {
                if (line[i] ~ /^[ \t]*\} finally \{/) nested = i
            }
            if (nested == 0) { print "NO_NESTED_FINALLY"; exit }
            # Depth starts at 1: the `{` on the nested opener line is already open,
            # and that line itself is not rescanned.
            depth = 1
            inside = 0
            for (i = nested + 1; i <= NR; i++) {
                if (line[i] ~ /^[ \t]*Release-MaintenanceLock[ \t]*$/ && depth >= 1) inside = 1
                opens = gsub(/\{/, "", line[i])
                closes = gsub(/\}/, "", line[i])
                depth += opens - closes
                if (depth < 1) break
            }
            print (inside ? "INSIDE" : "OUTSIDE")
        }
    ')
    case "$release_verdict" in
        INSIDE) ;;
        NO_NESTED_FINALLY)
            fail "$server_installer" "the top-level cleanup finally has no nested finally, so a cleanup step that throws skips Release-MaintenanceLock and leaves the lock held"
            ;;
        *)
            fail "$server_installer" "Release-MaintenanceLock is not inside the nested finally of the top-level cleanup; a cleanup step that throws skips it and leaves the lock held"
            ;;
    esac
fi

# --- RULE K: a cleanup throw must not mask the failure that caused it ---------
# The client installer's Install-CommitSet removes its staged temporaries and
# backups in a `finally`.  When that removal fails it has to report something, and
# `throw` is the natural choice -- but a `throw` from `finally` replaces the
# in-flight exception, so an unconditional throw there erases the real error: the
# operator is told the cleanup failed and never learns that the copy, the reparse
# check, or the atomic replace is what actually broke.  Measured 2026-10-05 by
# reproducing the shape under pwsh.
#
# The fix keeps the report but makes it conditional: when the body already threw,
# the cleanup failure goes to stderr and the ORIGINAL error propagates; only when
# the body succeeded is the cleanup failure itself the error.  That requires the
# catch to capture the exception into a variable the finally can test.
#
# The invariant, stated so it cannot be satisfied by the old code: if the finally
# throws on cleanup failure, it must first distinguish "the body failed" from
# "the body succeeded".  Asserting merely that a throw exists would pass the
# defective version; asserting a specific variable name would be brittle.  So the
# rule requires that the finally both (a) throws for the cleanup failure and
# (b) tests a captured-exception variable before doing so.
#
# Source-level by necessity, like rule J: this installer cannot run on this host.
rules_checked=$((rules_checked + 1))
client_finally=$(awk '
    /^function Install-CommitSet/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
' "$client_installer" | awk '
    /\} finally \{/ { capturing = 1; next }
    capturing { print }
')
if [ -z "$client_finally" ]; then
    fail "$client_installer" "could not extract Install-CommitSet its finally block; rule K cannot conclude"
else
    cleanup_throw=$(printf '%s\n' "$client_finally" | grep -cE '^\s*throw "Client installer temporary cleanup failed"' || true)
    if [ "$cleanup_throw" -eq 0 ]; then
        fail "$client_installer" "Install-CommitSet no longer throws when its temporary cleanup fails; a cleanup failure would pass silently"
    elif ! printf '%s\n' "$client_finally" | grep -qE '\$originalError'; then
        fail "$client_installer" "Install-CommitSet throws on cleanup failure without testing a captured exception; the throw replaces the in-flight error and masks why the install failed"
    fi
fi

# --- K2: the same masking shape in ANY finally of EITHER installer -----------
# Rule K above pins the one site the client installer was fixed at.  Measured
# 2026-10-06: the SERVER installer carried four more copies of the identical
# defect (`Install-PueueConfiguration`, `Install-AgentQLauncher`,
# `Download-VerifiedPueueBinary`, `Install-StageAsset` each threw unconditionally
# from `finally`), and rule K's single-function anchor could not see them.  The
# invariant, generalized: a `finally` block that runs a `Remove-*TemporaryFile`
# cleanup must not throw unconditionally -- it has to record the cleanup failure
# into a variable ($cleanupError / $cleanupErrors) or gate the throw on the
# captured exception ($originalError).  The maintenance-lock release finally is
# deliberately out of scope: it does not call a Remove-*TemporaryFile helper
# (rule J owns that shape, and its throw is an accepted trade-off).
k2_blocks=0
k2_report=''
for k2_installer in "$server_installer" "$client_installer"; do
    k2_out=$(awk '
        function flush() {
            if (inblock) {
                k2_blocks++
                if (code ~ /Remove-[A-Za-z]*TemporaryFile/ && code ~ /(^|[^A-Za-z])throw / &&
                    code !~ /\$cleanupError/ && code !~ /\$cleanupErrors/ && code !~ /\$originalError/) {
                    printf "%s:%d\n", FILENAME, start
                }
            }
            inblock = 0
        }
        /\} finally \{/ { flush(); inblock = 1; start = NR; depth = 1; code = ""; next }
        inblock {
            line = $0
            sub(/^[ \t]*#.*$/, "", line)
            code = code line "\n"
            opens = gsub(/\{/, "{", line); closes = gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth <= 0) flush()
        }
        END { flush(); printf "__BLOCKS__%d\n", k2_blocks > "/dev/stderr" }
    ' "$k2_installer" 2>"/tmp/aq-k2-count.$$")
    k2_blocks=$(sed -n 's/^__BLOCKS__//p' "/tmp/aq-k2-count.$$")
    rm -f "/tmp/aq-k2-count.$$"
    if [ -z "$k2_blocks" ] || [ "$k2_blocks" -eq 0 ]; then
        fail "$k2_installer" "could not extract any finally block; rule K2 cannot conclude"
    fi
    if [ -n "$k2_out" ]; then
        k2_report="$k2_report$k2_out
"
    fi
done
if [ -n "$k2_report" ]; then
    while IFS= read -r k2_line; do
        [ -n "$k2_line" ] || continue
        k2_file=${k2_line%:*}
        k2_lineno=${k2_line##*:}
        fail "$k2_file" "line $k2_lineno: a finally block throws on cleanup failure without recording it or gating on the captured exception; the throw replaces the in-flight error and masks why the install failed"
    done <<EOF
$k2_report
EOF
fi

if [ "$failures" -ne 0 ]; then
    printf 'installer-invariants: %s violation(s)\n' "$failures" >&2
    exit 1
fi

printf 'installer-invariants checks passed: rules=%s files=5 violations=0 acl-properties=verified posix-mv-recheck=asserted placeholder-substitution=guarded lock-release=unconditional\n' "$rules_checked"
