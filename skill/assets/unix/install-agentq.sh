#!/bin/sh

set -eu

program=${0##*/}
release_version='4.0.4'
asset_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
agentq_home=${AGENTQ_HOME:-"$HOME/.agentq"}
artifact_source_directory=${AGENTQ_PUEUE_SOURCE_DIR:-}
wrapper_destination="$HOME/.local/bin/agentq"

stage_home=''
stage_home_identity=''
backup_home=''
backup_home_identity=''
failed_home=''
failed_home_identity=''
service_stage=''
service_stage_identity=''
service_temporary=''
service_temporary_identity=''
service_restore_temporary=''
service_restore_temporary_identity=''
service_backup=''
service_backup_identity=''
wrapper_backup=''
wrapper_backup_identity=''
wrapper_temporary=''
wrapper_temporary_identity=''
wrapper_restore_temporary=''
wrapper_restore_temporary_identity=''
binary_temporary=''
binary_temporary_identity=''
download_temporary=''
download_temporary_identity=''
health_temporary=''
health_temporary_identity=''
existing_status_temporary=''
existing_status_temporary_identity=''
group_temporary=''
group_temporary_identity=''
transaction_active=false
rollback_running=false
previous_install=false
previous_service=false
previous_wrapper=false
service_existed_before=false
previous_root_moved=false
previous_daemon_stopped=false
previous_daemon_stop_attempted=false
candidate_installed=false
service_replaced=false
wrapper_replaced=false
preserve_recovery_artifacts=false
platform_kind=''
service_destination=''
launch_domain=''
launch_service=''
launch_requires_root=false
lock_metadata_temporary=''
lock_metadata_temporary_identity=''
macos_system_service_directory=${AGENTQ_MACOS_SYSTEM_SERVICE_DIRECTORY:-/Library/LaunchDaemons}
macos_system_service_destination=''
macos_legacy_service=''
macos_legacy_service_requires_root=false
macos_legacy_plist_backup=''
macos_legacy_plist_backup_identity=''
macos_legacy_plist_moved=false
macos_legacy_service_active_before=false
macos_legacy_plist_existed_before=false
macos_service_active_before=false
previous_queue_verified_offline=false
existing_daemon_live=false
package_manager=''
apt_updated=false
maintenance_lock=''
maintenance_lock_held=false
maintenance_lock_observed_pid=''
maintenance_lock_observed_identity=''
linux_linger_before=''
linux_linger_changed=false

fail() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 2
}

require_file() {
    [ -f "$1" ] || fail "required staged asset is missing: $1"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0) return 1 ;;
        *) return 0 ;;
    esac
}

process_identity_state() {
    lock_process_pid=$1

    is_positive_integer "$lock_process_pid" || return 1
    if ! kill -0 "$lock_process_pid" 2>/dev/null; then
        printf '%s\n' dead
        return 0
    fi

    lock_process_identity=$(LC_ALL=C ps -o lstart= -p "$lock_process_pid" 2>/dev/null | awk '{$1 = $1; print}')
    [ -n "$lock_process_identity" ] || return 1
    printf 'alive:%s\n' "$lock_process_identity"
}

process_identity() {
    lock_process_state=$(process_identity_state "$1") || return 1
    case "$lock_process_state" in
        alive:*)
            printf '%s\n' "${lock_process_state#alive:}"
            ;;
        *)
            return 1
            ;;
    esac
}

process_is_confirmed_dead() {
    lock_process_pid=$1
    lock_expected_identity=${2:-}
    lock_process_state=$(process_identity_state "$lock_process_pid") || return 1

    case "$lock_process_state" in
        dead)
            return 0
            ;;
        alive:*)
            [ -n "$lock_expected_identity" ] || return 1
            lock_observed_identity=${lock_process_state#alive:}
            [ "$lock_observed_identity" != "$lock_expected_identity" ]
            ;;
        *)
            return 1
            ;;
    esac
}

read_lock_metadata() {
    lock_metadata_path=$1
    lock_metadata_directory=''
    lock_metadata_parent=''
    lock_contents=''
    lock_sample=''
    lock_metadata_limit=4096
    lock_metadata_sentinel=$(printf '\001')
    lock_read_status=0
    lock_metadata_byte_count=0
    lock_pid=''
    lock_identity=''

    case "$lock_metadata_path" in
        */*)
            lock_metadata_directory=${lock_metadata_path%/*}
            [ -n "$lock_metadata_directory" ] || lock_metadata_directory=/
            ;;
        *)
            lock_metadata_directory=.
            ;;
    esac
    case "$lock_metadata_directory" in
        */*)
            lock_metadata_parent=${lock_metadata_directory%/*}
            [ -n "$lock_metadata_parent" ] || lock_metadata_parent=/
            ;;
        *)
            lock_metadata_parent=.
            ;;
    esac
    [ ! -L "$lock_metadata_parent" ] || return 1
    [ ! -L "$lock_metadata_directory" ] || return 1
    [ ! -L "$lock_metadata_path" ] || return 1
    [ -f "$lock_metadata_path" ] || return 1

    [ -r "$lock_metadata_path" ] || return 1
    [ ! -L "$lock_metadata_parent" ] || return 1
    [ ! -L "$lock_metadata_directory" ] || return 1
    [ ! -L "$lock_metadata_path" ] || return 1
    [ -f "$lock_metadata_path" ] || return 1
    [ -r "$lock_metadata_path" ] || return 1
    if lock_sample=$(
        head -c "$((lock_metadata_limit + 1))" -- "$lock_metadata_path" 2>/dev/null
        lock_read_status=$?
        printf '%s' "$lock_metadata_sentinel"
        exit "$lock_read_status"
    ); then
        case "$lock_sample" in
            *"$lock_metadata_sentinel")
                lock_sample=${lock_sample%"$lock_metadata_sentinel"}
                ;;
            *)
                return 1
                ;;
        esac
        lock_metadata_byte_count=$(printf '%s' "$lock_sample" | wc -c)
        [ "$lock_metadata_byte_count" -le "$lock_metadata_limit" ] || return 1
        lock_contents=$lock_sample
    elif [ -e "$lock_metadata_path" ] || [ -L "$lock_metadata_path" ]; then
        return 1
    else
        lock_contents=''
    fi
    IFS="$(printf '\t')" read -r lock_pid lock_identity <<EOF
$lock_contents
EOF
    lock_pid=$(printf '%s' "$lock_pid" | tr -d '\r')
    lock_identity=$(printf '%s' "$lock_identity" | tr -d '\r')
}

installer_file_identity() {
    installer_identity_path=$1
    installer_identity=''

    if installer_identity=$(stat -c '%d:%i' -- "$installer_identity_path" 2>/dev/null); then
        :
    elif installer_identity=$(stat -f '%d:%i' "$installer_identity_path" 2>/dev/null); then
        :
    else
        return 1
    fi
    case "$installer_identity" in
        ''|*[!0-9:]*|*:*:*) return 1 ;;
    esac
    printf '%s\n' "$installer_identity"
}

write_lock_metadata() {
    lock_metadata_path=$1
    lock_metadata_directory=''
    lock_metadata_temporary=''
    lock_metadata_temporary_identity=''
    lock_current_identity=$(process_identity "$$") || return 1

    case "$lock_metadata_path" in
        */*)
            lock_metadata_directory=${lock_metadata_path%/*}
            [ -n "$lock_metadata_directory" ] || lock_metadata_directory=/
            ;;
        *)
            lock_metadata_directory=.
            ;;
    esac
    case "$lock_metadata_directory" in
        */*)
            lock_metadata_parent=${lock_metadata_directory%/*}
            [ -n "$lock_metadata_parent" ] || lock_metadata_parent=/
            ;;
        *)
            lock_metadata_parent=.
            ;;
    esac
    [ ! -L "$lock_metadata_parent" ] || return 1
    [ ! -L "$lock_metadata_directory" ] || return 1
    [ ! -L "$lock_metadata_path" ] || return 1
    [ -d "$lock_metadata_directory" ] || return 1
    lock_metadata_temporary=$(mktemp "$lock_metadata_directory/.agentq-lock-metadata.XXXXXX") || return 1
    lock_metadata_temporary_identity=$(installer_file_identity "$lock_metadata_temporary") || {
        discard_lock_metadata_temporary || return 1
        return 1
    }
    if ! printf '%s\t%s\n' "$$" "$lock_current_identity" > "$lock_metadata_temporary"; then
        discard_lock_metadata_temporary || return 1
        return 1
    fi
    if ! installer_existing_regular_file_is_safe "$lock_metadata_temporary" ||
        ! installer_path_is_safe "$lock_metadata_path"; then
        discard_lock_metadata_temporary || return 1
        return 1
    fi
    if ! mv -f -- "$lock_metadata_temporary" "$lock_metadata_path"; then
        discard_lock_metadata_temporary || return 1
        return 1
    fi
    if ! installer_existing_regular_file_is_safe "$lock_metadata_path" ||
        ! installer_path_is_absent "$lock_metadata_temporary"; then
        discard_lock_metadata_temporary || return 1
        return 1
    fi
    lock_metadata_temporary=''
    lock_metadata_temporary_identity=''
}

lock_is_owned_by_current_process() {
    lock_metadata_path=$1

    read_lock_metadata "$lock_metadata_path" || return 1
    [ "$lock_pid" = "$$" ] || return 1
    [ -n "$lock_identity" ] || return 1
    lock_current_identity=$(process_identity "$$") || return 1
    [ "$lock_identity" = "$lock_current_identity" ]
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail 'sha256sum or shasum is required'
    fi
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "missing dependency requires elevated privileges, but sudo is unavailable: $1"
    fi
}

installer_path_is_safe() {
    installer_guard_path=$1
    installer_guard_probe='.'
    installer_guard_remaining=$installer_guard_path

    case "$installer_guard_path" in
        '')
            return 1
            ;;
    esac
    case "/$installer_guard_path/" in
        */../*)
            return 1
            ;;
    esac
    case "$installer_guard_remaining" in
        /*)
            installer_guard_probe=/
            installer_guard_remaining=${installer_guard_remaining#/}
            ;;
    esac

    while [ -n "$installer_guard_remaining" ]; do
        case "$installer_guard_remaining" in
            */*)
                installer_guard_component=${installer_guard_remaining%%/*}
                installer_guard_remaining=${installer_guard_remaining#*/}
                ;;
            *)
                installer_guard_component=$installer_guard_remaining
                installer_guard_remaining=''
                ;;
        esac
        [ -n "$installer_guard_component" ] || continue
        [ "$installer_guard_component" = . ] && continue
        if [ "$installer_guard_probe" = / ]; then
            installer_guard_probe=/$installer_guard_component
        else
            installer_guard_probe=$installer_guard_probe/$installer_guard_component
        fi
        [ ! -L "$installer_guard_probe" ] || return 1
    done
}

installer_regular_file_is_safe() {
    installer_file_path=$1
    installer_path_is_safe "$installer_file_path" || return 1
    if [ -e "$installer_file_path" ] && [ ! -f "$installer_file_path" ]; then
        return 1
    fi
}

installer_existing_regular_file_is_safe() {
    installer_existing_file_path=$1
    installer_path_is_safe "$installer_existing_file_path" || return 1
    [ ! -L "$installer_existing_file_path" ] || return 1
    [ -f "$installer_existing_file_path" ]
}

installer_path_is_absent() {
    installer_absent_path=$1
    installer_path_is_safe "$installer_absent_path" || return 1
    [ ! -e "$installer_absent_path" ] && [ ! -L "$installer_absent_path" ]
}

installer_directory_is_safe() {
    installer_directory_path=$1
    installer_path_is_safe "$installer_directory_path" || return 1
    [ -d "$installer_directory_path" ] && [ ! -L "$installer_directory_path" ]
}

installer_tree_is_safe() {
    installer_tree_path=$1
    installer_directory_is_safe "$installer_tree_path" || return 1
    installer_tree_link=$(find "$installer_tree_path" -type l -print -quit)
    [ -z "$installer_tree_link" ]
}

move_installer_tree() {
    installer_move_source=$1
    installer_move_destination=$2
    installer_move_description=$3

    if ! installer_tree_is_safe "$installer_move_source"; then
        printf '%s: %s source is unsafe: %s\n' \
            "$program" "$installer_move_description" "$installer_move_source" >&2
        return 1
    fi
    if ! installer_path_is_absent "$installer_move_destination"; then
        printf '%s: %s destination already exists or is unsafe: %s\n' \
            "$program" "$installer_move_description" "$installer_move_destination" >&2
        return 1
    fi
    if ! mv -- "$installer_move_source" "$installer_move_destination"; then
        printf '%s: failed to move %s: %s -> %s\n' \
            "$program" "$installer_move_description" "$installer_move_source" "$installer_move_destination" >&2
        return 1
    fi
    if ! installer_tree_is_safe "$installer_move_destination" ||
        [ -e "$installer_move_source" ] || [ -L "$installer_move_source" ]; then
        printf '%s: %s move identity check failed: %s -> %s\n' \
            "$program" "$installer_move_description" "$installer_move_source" "$installer_move_destination" >&2
        return 1
    fi
}

assert_no_crash_leftover_transactions() {
    # W5 (POSIX half).  The crash window is between `mv agentq_home -> backup_home`
    # and `mv stage_home -> agentq_home`: $agentq_home is then ABSENT with a
    # `.${agentq_base}.backup.*` (and possibly `.stage.*`) sibling beside it --
    # the old queue, data and any credentials still inside the backup.  Without
    # this guard the re-run treats the machine as a fresh install (previous_install
    # stays false because `[ -e "$agentq_home" ]` is false), skips
    # copy_existing_data entirely and moves an EMPTY stage into place: a silent
    # empty deployment over a stranded previous one.  Measured 2026-10-07 on this
    # machine: the window is real on POSIX too -- it was only masked in the common
    # case by the unrelated wrapper check, which refused with a message pointing at
    # the wrapper instead of at the stranded backup (an operator following that
    # message would delete the wrapper and fall straight into the empty deploy).
    #
    # Both directions refuse: a leftover beside a MISSING root is the empty-deploy
    # window; a leftover beside a PRESENT root means a run crashed after the swap
    # or one is in progress -- only the operator can tell which, and the success
    # path always removes its own backup before exiting, so residue is never
    # normal.  Nothing is deleted, merged or restored automatically.
    #
    # The scan is fail-closed: if find cannot read the parent the guard refuses,
    # because an unreadable directory would otherwise bypass it exactly as a
    # missing root does.
    crash_leftovers=''
    crash_scan_failed=false
    for crash_kind in stage backup failed; do
        crash_matches=$(find "$agentq_parent" -mindepth 1 -maxdepth 1 \
            -name ".${agentq_base}.${crash_kind}.*" -print 2>/dev/null) || crash_scan_failed=true
        if [ -n "$crash_matches" ]; then
            if [ -n "$crash_leftovers" ]; then
                crash_leftovers="$crash_leftovers
$crash_matches"
            else
                crash_leftovers=$crash_matches
            fi
        fi
    done
    if [ "$crash_scan_failed" = true ]; then
        fail "refusing to install: cannot inspect $agentq_parent for leftover AgentQ transaction directories; refusing to risk a silent empty deployment over an unreadable directory. Check permissions and re-run. Nothing was modified."
    fi
    [ -n "$crash_leftovers" ] || return 0
    crash_leftover_list=$(printf '%s\n' "$crash_leftovers" | tr '\n' ' ')
    if [ ! -e "$agentq_home" ] && [ ! -L "$agentq_home" ]; then
        fail "refusing to install: AgentQ root $agentq_home is missing but a previous run's transaction residue exists ($crash_leftover_list). A run crashed between moving the old root aside and installing the new one; the previous deployment (queue data and credentials) is still in the .backup directory above. Move it back to $agentq_home and restart the AgentQ daemon (the crashed run stopped it) before re-running, or remove it to confirm a fresh install. Nothing was modified."
    fi
    fail "refusing to install: a previous run's transaction residue exists beside the AgentQ root ($crash_leftover_list). Either an install crashed after the swap or another install is in progress; inspect these directories and restore or remove the backup as intended, then re-run. Nothing was modified."
}

move_installer_file() {
    installer_move_file_source=$1
    installer_move_file_destination=$2
    installer_move_file_description=$3

    if [ ! -f "$installer_move_file_source" ] || [ -L "$installer_move_file_source" ] ||
        ! installer_path_is_safe "$installer_move_file_source"; then
        printf '%s: %s source is unsafe or missing: %s\n' \
            "$program" "$installer_move_file_description" "$installer_move_file_source" >&2
        return 1
    fi
    if ! installer_path_is_absent "$installer_move_file_destination"; then
        printf '%s: %s destination already exists or is unsafe: %s\n' \
            "$program" "$installer_move_file_description" "$installer_move_file_destination" >&2
        return 1
    fi
    if ! mv -- "$installer_move_file_source" "$installer_move_file_destination"; then
        printf '%s: failed to move %s: %s -> %s\n' \
            "$program" "$installer_move_file_description" "$installer_move_file_source" "$installer_move_file_destination" >&2
        return 1
    fi
    if [ ! -f "$installer_move_file_destination" ] || [ -L "$installer_move_file_destination" ] ||
        ! installer_path_is_safe "$installer_move_file_destination" ||
        [ -e "$installer_move_file_source" ] || [ -L "$installer_move_file_source" ]; then
        printf '%s: %s move identity check failed: %s -> %s\n' \
            "$program" "$installer_move_file_description" "$installer_move_file_source" "$installer_move_file_destination" >&2
        return 1
    fi
}

remove_installer_tree() {
    installer_remove_tree_path=$1
    installer_remove_tree_description=${2:-transaction tree}

    [ -n "$installer_remove_tree_path" ] || return 0
    if [ ! -e "$installer_remove_tree_path" ] && [ ! -L "$installer_remove_tree_path" ]; then
        return 0
    fi
    if ! installer_tree_is_safe "$installer_remove_tree_path"; then
        printf '%s: %s is unsafe; preserving it: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 1
    fi
    if [ "$#" -lt 3 ] || [ -z "$3" ]; then
        printf '%s: refusing to remove %s without a recorded identity: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 2
    fi
    installer_remove_tree_expected_identity=$3
    installer_remove_tree_observed_identity=$(installer_file_identity "$installer_remove_tree_path") || {
        printf '%s: refusing to remove %s with an unreadable identity: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 1
    }
    if [ "$installer_remove_tree_observed_identity" != "$installer_remove_tree_expected_identity" ]; then
        printf '%s: %s identity changed during cleanup; preserving it: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 1
    fi
    if ! rm -rf -- "$installer_remove_tree_path"; then
        printf '%s: %s cleanup failed; preserving it: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 1
    fi
    if [ -e "$installer_remove_tree_path" ] || [ -L "$installer_remove_tree_path" ]; then
        printf '%s: %s remained after cleanup; preserving it: %s\n' \
            "$program" "$installer_remove_tree_description" "$installer_remove_tree_path" >&2
        return 1
    fi
}

existing_installation_paths_are_safe() {
    existing_path_root=$1
    for existing_path in \
        "$existing_path_root" "$existing_path_root/pueue" \
        "$existing_path_root/config" "$existing_path_root/config/pueue.yml" \
        "$existing_path_root/runtime" "$existing_path_root/runtime/pueued.pid" \
        "$existing_path_root/data" "$existing_path_root/data/state.json.gz"; do
        installer_path_is_safe "$existing_path" || return 1
    done
}

require_installer_tree() {
    installer_tree_path=$1
    installer_tree_description=$2
    installer_tree_is_safe "$installer_tree_path" ||
        fail "$installer_tree_description is unsafe: $installer_tree_path"
}

remove_installer_file() {
    installer_remove_path=$1
    [ -n "$installer_remove_path" ] || return 0
    installer_regular_file_is_safe "$installer_remove_path" || return 1
    if [ "$platform_kind" = macos ]; then
        run_as_root rm -f -- "$installer_remove_path"
    else
        rm -f -- "$installer_remove_path"
    fi
}

discard_lock_metadata_temporary() {
    lock_metadata_cleanup_status=0

    [ -n "$lock_metadata_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$lock_metadata_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ lock metadata temporary: %s\n' "$program" "$lock_metadata_temporary" >&2
        return 2
    fi
    if [ ! -e "$lock_metadata_temporary" ] && [ ! -L "$lock_metadata_temporary" ]; then
        lock_metadata_temporary=''
        lock_metadata_temporary_identity=''
        return 0
    fi
    if [ -z "$lock_metadata_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ lock metadata temporary without a recorded identity: %s\n' \
            "$program" "$lock_metadata_temporary" >&2
        return 2
    fi
    lock_metadata_observed_identity=$(installer_file_identity "$lock_metadata_temporary") || {
        printf '%s: refusing to remove AgentQ lock metadata temporary with an unreadable identity: %s\n' \
            "$program" "$lock_metadata_temporary" >&2
        return 1
    }
    if [ "$lock_metadata_observed_identity" != "$lock_metadata_temporary_identity" ]; then
        printf '%s: AgentQ lock metadata temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$lock_metadata_temporary" >&2
        lock_metadata_temporary=''
        lock_metadata_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$lock_metadata_temporary"; then
        :
    else
        lock_metadata_cleanup_status=$?
        printf '%s: failed to remove AgentQ lock metadata temporary: %s\n' "$program" "$lock_metadata_temporary" >&2
        return "$lock_metadata_cleanup_status"
    fi
    if [ -e "$lock_metadata_temporary" ] || [ -L "$lock_metadata_temporary" ]; then
        printf '%s: AgentQ lock metadata temporary remained after cleanup: %s\n' "$program" "$lock_metadata_temporary" >&2
        return 1
    fi
    lock_metadata_temporary=''
    lock_metadata_temporary_identity=''
    return 0
}

discard_service_stage_temporary() {
    service_stage_cleanup_status=0

    [ -n "$service_stage" ] || return 0
    if ! installer_regular_file_is_safe "$service_stage"; then
        printf '%s: refusing to remove unsafe AgentQ service staging temporary: %s\n' "$program" "$service_stage" >&2
        return 2
    fi
    if [ ! -e "$service_stage" ] && [ ! -L "$service_stage" ]; then
        service_stage=''
        service_stage_identity=''
        return 0
    fi
    if [ -z "$service_stage_identity" ]; then
        printf '%s: refusing to remove AgentQ service staging temporary without a recorded identity: %s\n' \
            "$program" "$service_stage" >&2
        return 2
    fi
    service_stage_observed_identity=$(installer_file_identity "$service_stage") || {
        printf '%s: refusing to remove AgentQ service staging temporary with an unreadable identity: %s\n' \
            "$program" "$service_stage" >&2
        return 1
    }
    if [ "$service_stage_observed_identity" != "$service_stage_identity" ]; then
        printf '%s: AgentQ service staging temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$service_stage" >&2
        service_stage=''
        service_stage_identity=''
        return 1
    fi
    if remove_installer_file "$service_stage"; then
        :
    else
        service_stage_cleanup_status=$?
        printf '%s: failed to remove AgentQ service staging temporary: %s\n' "$program" "$service_stage" >&2
        return "$service_stage_cleanup_status"
    fi
    if [ -e "$service_stage" ] || [ -L "$service_stage" ]; then
        printf '%s: AgentQ service staging temporary remained after cleanup: %s\n' "$program" "$service_stage" >&2
        return 1
    fi
    service_stage=''
    service_stage_identity=''
    return 0
}

discard_service_temporary() {
    service_temporary_cleanup_status=0

    [ -n "$service_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$service_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ service temporary: %s\n' "$program" "$service_temporary" >&2
        return 2
    fi
    if [ ! -e "$service_temporary" ] && [ ! -L "$service_temporary" ]; then
        service_temporary=''
        service_temporary_identity=''
        return 0
    fi
    if [ -z "$service_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ service temporary without a recorded identity: %s\n' \
            "$program" "$service_temporary" >&2
        return 2
    fi
    service_temporary_observed_identity=$(installer_file_identity "$service_temporary") || {
        printf '%s: refusing to remove AgentQ service temporary with an unreadable identity: %s\n' \
            "$program" "$service_temporary" >&2
        return 1
    }
    if [ "$service_temporary_observed_identity" != "$service_temporary_identity" ]; then
        printf '%s: AgentQ service temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$service_temporary" >&2
        service_temporary=''
        service_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$service_temporary"; then
        :
    else
        service_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ service temporary: %s\n' "$program" "$service_temporary" >&2
        return "$service_temporary_cleanup_status"
    fi
    if [ -e "$service_temporary" ] || [ -L "$service_temporary" ]; then
        printf '%s: AgentQ service temporary remained after cleanup: %s\n' "$program" "$service_temporary" >&2
        return 1
    fi
    service_temporary=''
    service_temporary_identity=''
    return 0
}

discard_wrapper_temporary() {
    wrapper_temporary_cleanup_status=0

    [ -n "$wrapper_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$wrapper_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ wrapper temporary: %s\n' "$program" "$wrapper_temporary" >&2
        return 2
    fi
    if [ ! -e "$wrapper_temporary" ] && [ ! -L "$wrapper_temporary" ]; then
        wrapper_temporary=''
        wrapper_temporary_identity=''
        return 0
    fi
    if [ -z "$wrapper_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ wrapper temporary without a recorded identity: %s\n' \
            "$program" "$wrapper_temporary" >&2
        return 2
    fi
    wrapper_temporary_observed_identity=$(installer_file_identity "$wrapper_temporary") || {
        printf '%s: refusing to remove AgentQ wrapper temporary with an unreadable identity: %s\n' \
            "$program" "$wrapper_temporary" >&2
        return 1
    }
    if [ "$wrapper_temporary_observed_identity" != "$wrapper_temporary_identity" ]; then
        printf '%s: AgentQ wrapper temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$wrapper_temporary" >&2
        wrapper_temporary=''
        wrapper_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$wrapper_temporary"; then
        :
    else
        wrapper_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ wrapper temporary: %s\n' "$program" "$wrapper_temporary" >&2
        return "$wrapper_temporary_cleanup_status"
    fi
    if [ -e "$wrapper_temporary" ] || [ -L "$wrapper_temporary" ]; then
        printf '%s: AgentQ wrapper temporary remained after cleanup: %s\n' "$program" "$wrapper_temporary" >&2
        return 1
    fi
    wrapper_temporary=''
    wrapper_temporary_identity=''
    return 0
}

discard_service_restore_temporary() {
    service_restore_temporary_cleanup_status=0

    [ -n "$service_restore_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$service_restore_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ service restore temporary: %s\n' \
            "$program" "$service_restore_temporary" >&2
        return 2
    fi
    if [ ! -e "$service_restore_temporary" ] && [ ! -L "$service_restore_temporary" ]; then
        service_restore_temporary=''
        service_restore_temporary_identity=''
        return 0
    fi
    if [ -z "$service_restore_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ service restore temporary without a recorded identity: %s\n' \
            "$program" "$service_restore_temporary" >&2
        return 2
    fi
    service_restore_temporary_observed_identity=$(installer_file_identity "$service_restore_temporary") || {
        printf '%s: refusing to remove AgentQ service restore temporary with an unreadable identity: %s\n' \
            "$program" "$service_restore_temporary" >&2
        return 1
    }
    if [ "$service_restore_temporary_observed_identity" != "$service_restore_temporary_identity" ]; then
        printf '%s: AgentQ service restore temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$service_restore_temporary" >&2
        service_restore_temporary=''
        service_restore_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$service_restore_temporary"; then
        :
    else
        service_restore_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ service restore temporary: %s\n' \
            "$program" "$service_restore_temporary" >&2
        return "$service_restore_temporary_cleanup_status"
    fi
    if [ -e "$service_restore_temporary" ] || [ -L "$service_restore_temporary" ]; then
        printf '%s: AgentQ service restore temporary remained after cleanup: %s\n' \
            "$program" "$service_restore_temporary" >&2
        return 1
    fi
    service_restore_temporary=''
    service_restore_temporary_identity=''
    return 0
}

discard_wrapper_restore_temporary() {
    wrapper_restore_temporary_cleanup_status=0

    [ -n "$wrapper_restore_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$wrapper_restore_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ wrapper restore temporary: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        return 2
    fi
    if [ ! -e "$wrapper_restore_temporary" ] && [ ! -L "$wrapper_restore_temporary" ]; then
        wrapper_restore_temporary=''
        wrapper_restore_temporary_identity=''
        return 0
    fi
    if [ -z "$wrapper_restore_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ wrapper restore temporary without a recorded identity: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        return 2
    fi
    wrapper_restore_temporary_observed_identity=$(installer_file_identity "$wrapper_restore_temporary") || {
        printf '%s: refusing to remove AgentQ wrapper restore temporary with an unreadable identity: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        return 1
    }
    if [ "$wrapper_restore_temporary_observed_identity" != "$wrapper_restore_temporary_identity" ]; then
        printf '%s: AgentQ wrapper restore temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        wrapper_restore_temporary=''
        wrapper_restore_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$wrapper_restore_temporary"; then
        :
    else
        wrapper_restore_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ wrapper restore temporary: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        return "$wrapper_restore_temporary_cleanup_status"
    fi
    if [ -e "$wrapper_restore_temporary" ] || [ -L "$wrapper_restore_temporary" ]; then
        printf '%s: AgentQ wrapper restore temporary remained after cleanup: %s\n' \
            "$program" "$wrapper_restore_temporary" >&2
        return 1
    fi
    wrapper_restore_temporary=''
    wrapper_restore_temporary_identity=''
    return 0
}

discard_binary_temporary() {
    binary_temporary_cleanup_status=0

    [ -n "$binary_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$binary_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ binary temporary: %s\n' "$program" "$binary_temporary" >&2
        return 2
    fi
    if [ ! -e "$binary_temporary" ] && [ ! -L "$binary_temporary" ]; then
        binary_temporary=''
        binary_temporary_identity=''
        return 0
    fi
    if [ -z "$binary_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ binary temporary without a recorded identity: %s\n' \
            "$program" "$binary_temporary" >&2
        return 2
    fi
    binary_temporary_observed_identity=$(installer_file_identity "$binary_temporary") || {
        printf '%s: refusing to remove AgentQ binary temporary with an unreadable identity: %s\n' \
            "$program" "$binary_temporary" >&2
        return 1
    }
    if [ "$binary_temporary_observed_identity" != "$binary_temporary_identity" ]; then
        printf '%s: AgentQ binary temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$binary_temporary" >&2
        binary_temporary=''
        binary_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$binary_temporary"; then
        :
    else
        binary_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ binary temporary: %s\n' "$program" "$binary_temporary" >&2
        return "$binary_temporary_cleanup_status"
    fi
    if [ -e "$binary_temporary" ] || [ -L "$binary_temporary" ]; then
        printf '%s: AgentQ binary temporary remained after cleanup: %s\n' "$program" "$binary_temporary" >&2
        return 1
    fi
    binary_temporary=''
    binary_temporary_identity=''
    return 0
}

discard_service_backup() {
    service_backup_cleanup_status=0

    [ -n "$service_backup" ] || return 0
    if ! installer_regular_file_is_safe "$service_backup"; then
        printf '%s: refusing to remove unsafe AgentQ service backup: %s\n' "$program" "$service_backup" >&2
        return 2
    fi
    if [ ! -e "$service_backup" ] && [ ! -L "$service_backup" ]; then
        service_backup=''
        service_backup_identity=''
        return 0
    fi
    if [ -z "$service_backup_identity" ]; then
        printf '%s: refusing to remove AgentQ service backup without a recorded identity: %s\n' \
            "$program" "$service_backup" >&2
        return 2
    fi
    service_backup_observed_identity=$(installer_file_identity "$service_backup") || {
        printf '%s: refusing to remove AgentQ service backup with an unreadable identity: %s\n' \
            "$program" "$service_backup" >&2
        return 1
    }
    if [ "$service_backup_observed_identity" != "$service_backup_identity" ]; then
        printf '%s: AgentQ service backup identity changed during cleanup; preserving it: %s\n' \
            "$program" "$service_backup" >&2
        service_backup=''
        service_backup_identity=''
        return 1
    fi
    if remove_installer_file "$service_backup"; then
        :
    else
        service_backup_cleanup_status=$?
        printf '%s: failed to remove AgentQ service backup: %s\n' "$program" "$service_backup" >&2
        return "$service_backup_cleanup_status"
    fi
    if [ -e "$service_backup" ] || [ -L "$service_backup" ]; then
        printf '%s: AgentQ service backup remained after cleanup: %s\n' "$program" "$service_backup" >&2
        return 1
    fi
    service_backup=''
    service_backup_identity=''
    return 0
}

discard_wrapper_backup() {
    wrapper_backup_cleanup_status=0

    [ -n "$wrapper_backup" ] || return 0
    if ! installer_regular_file_is_safe "$wrapper_backup"; then
        printf '%s: refusing to remove unsafe AgentQ wrapper backup: %s\n' "$program" "$wrapper_backup" >&2
        return 2
    fi
    if [ ! -e "$wrapper_backup" ] && [ ! -L "$wrapper_backup" ]; then
        wrapper_backup=''
        wrapper_backup_identity=''
        return 0
    fi
    if [ -z "$wrapper_backup_identity" ]; then
        printf '%s: refusing to remove AgentQ wrapper backup without a recorded identity: %s\n' \
            "$program" "$wrapper_backup" >&2
        return 2
    fi
    wrapper_backup_observed_identity=$(installer_file_identity "$wrapper_backup") || {
        printf '%s: refusing to remove AgentQ wrapper backup with an unreadable identity: %s\n' \
            "$program" "$wrapper_backup" >&2
        return 1
    }
    if [ "$wrapper_backup_observed_identity" != "$wrapper_backup_identity" ]; then
        printf '%s: AgentQ wrapper backup identity changed during cleanup; preserving it: %s\n' \
            "$program" "$wrapper_backup" >&2
        wrapper_backup=''
        wrapper_backup_identity=''
        return 1
    fi
    if remove_installer_file "$wrapper_backup"; then
        :
    else
        wrapper_backup_cleanup_status=$?
        printf '%s: failed to remove AgentQ wrapper backup: %s\n' "$program" "$wrapper_backup" >&2
        return "$wrapper_backup_cleanup_status"
    fi
    if [ -e "$wrapper_backup" ] || [ -L "$wrapper_backup" ]; then
        printf '%s: AgentQ wrapper backup remained after cleanup: %s\n' "$program" "$wrapper_backup" >&2
        return 1
    fi
    wrapper_backup=''
    wrapper_backup_identity=''
    return 0
}

discard_download_temporary() {
    download_cleanup_status=0

    [ -n "$download_temporary" ] || return 0
    if ! installer_regular_file_is_safe "$download_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ download temporary: %s\n' "$program" "$download_temporary" >&2
        return 2
    fi
    if [ ! -e "$download_temporary" ] && [ ! -L "$download_temporary" ]; then
        download_temporary=''
        download_temporary_identity=''
        return 0
    fi
    if [ -z "$download_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ download temporary without a recorded identity: %s\n' \
            "$program" "$download_temporary" >&2
        return 2
    fi
    download_temporary_observed_identity=$(installer_file_identity "$download_temporary") || {
        printf '%s: refusing to remove AgentQ download temporary with an unreadable identity: %s\n' \
            "$program" "$download_temporary" >&2
        return 1
    }
    if [ "$download_temporary_observed_identity" != "$download_temporary_identity" ]; then
        printf '%s: AgentQ download temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$download_temporary" >&2
        download_temporary=''
        download_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$download_temporary"; then
        :
    else
        download_cleanup_status=$?
        printf '%s: failed to remove AgentQ download temporary: %s\n' "$program" "$download_temporary" >&2
        return "$download_cleanup_status"
    fi
    if [ -e "$download_temporary" ] || [ -L "$download_temporary" ]; then
        printf '%s: AgentQ download temporary remained after cleanup: %s\n' "$program" "$download_temporary" >&2
        return 1
    fi
    download_temporary=''
    download_temporary_identity=''
    return 0
}

discard_health_temporary() {
    health_temporary_cleanup_status=0

    [ -n "${health_temporary:-}" ] || return 0
    if ! installer_regular_file_is_safe "$health_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ health status temporary: %s\n' "$program" "$health_temporary" >&2
        return 2
    fi
    if [ ! -e "$health_temporary" ] && [ ! -L "$health_temporary" ]; then
        health_temporary=''
        health_temporary_identity=''
        return 0
    fi
    if [ -z "$health_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ health status temporary without a recorded identity: %s\n' \
            "$program" "$health_temporary" >&2
        return 2
    fi
    health_temporary_observed_identity=$(installer_file_identity "$health_temporary") || {
        printf '%s: refusing to remove AgentQ health status temporary with an unreadable identity: %s\n' \
            "$program" "$health_temporary" >&2
        return 1
    }
    if [ "$health_temporary_observed_identity" != "$health_temporary_identity" ]; then
        printf '%s: AgentQ health status temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$health_temporary" >&2
        health_temporary=''
        health_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$health_temporary"; then
        :
    else
        health_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ health status temporary: %s\n' "$program" "$health_temporary" >&2
        return "$health_temporary_cleanup_status"
    fi
    if [ -e "$health_temporary" ] || [ -L "$health_temporary" ]; then
        printf '%s: AgentQ health status temporary remained after cleanup: %s\n' "$program" "$health_temporary" >&2
        return 1
    fi
    health_temporary=''
    health_temporary_identity=''
    return 0
}

discard_existing_status_temporary() {
    existing_status_cleanup_status=0

    [ -n "${existing_status_temporary:-}" ] || return 0
    if ! installer_regular_file_is_safe "$existing_status_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ existing status temporary: %s\n' "$program" "$existing_status_temporary" >&2
        return 2
    fi
    if [ ! -e "$existing_status_temporary" ] && [ ! -L "$existing_status_temporary" ]; then
        existing_status_temporary=''
        existing_status_temporary_identity=''
        return 0
    fi
    if [ -z "$existing_status_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ existing status temporary without a recorded identity: %s\n' \
            "$program" "$existing_status_temporary" >&2
        return 2
    fi
    existing_status_observed_identity=$(installer_file_identity "$existing_status_temporary") || {
        printf '%s: refusing to remove AgentQ existing status temporary with an unreadable identity: %s\n' \
            "$program" "$existing_status_temporary" >&2
        return 1
    }
    if [ "$existing_status_observed_identity" != "$existing_status_temporary_identity" ]; then
        printf '%s: AgentQ existing status temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$existing_status_temporary" >&2
        existing_status_temporary=''
        existing_status_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$existing_status_temporary"; then
        :
    else
        existing_status_cleanup_status=$?
        printf '%s: failed to remove AgentQ existing status temporary: %s\n' "$program" "$existing_status_temporary" >&2
        return "$existing_status_cleanup_status"
    fi
    if [ -e "$existing_status_temporary" ] || [ -L "$existing_status_temporary" ]; then
        printf '%s: AgentQ existing status temporary remained after cleanup: %s\n' "$program" "$existing_status_temporary" >&2
        return 1
    fi
    existing_status_temporary=''
    existing_status_temporary_identity=''
    return 0
}

discard_group_temporary() {
    group_temporary_cleanup_status=0

    [ -n "${group_temporary:-}" ] || return 0
    if ! installer_regular_file_is_safe "$group_temporary"; then
        printf '%s: refusing to remove unsafe AgentQ group status temporary: %s\n' "$program" "$group_temporary" >&2
        return 2
    fi
    if [ ! -e "$group_temporary" ] && [ ! -L "$group_temporary" ]; then
        group_temporary=''
        group_temporary_identity=''
        return 0
    fi
    if [ -z "$group_temporary_identity" ]; then
        printf '%s: refusing to remove AgentQ group status temporary without a recorded identity: %s\n' \
            "$program" "$group_temporary" >&2
        return 2
    fi
    group_temporary_observed_identity=$(installer_file_identity "$group_temporary") || {
        printf '%s: refusing to remove AgentQ group status temporary with an unreadable identity: %s\n' \
            "$program" "$group_temporary" >&2
        return 1
    }
    if [ "$group_temporary_observed_identity" != "$group_temporary_identity" ]; then
        printf '%s: AgentQ group status temporary identity changed during cleanup; preserving it: %s\n' \
            "$program" "$group_temporary" >&2
        group_temporary=''
        group_temporary_identity=''
        return 1
    fi
    if remove_installer_file "$group_temporary"; then
        :
    else
        group_temporary_cleanup_status=$?
        printf '%s: failed to remove AgentQ group status temporary: %s\n' "$program" "$group_temporary" >&2
        return "$group_temporary_cleanup_status"
    fi
    if [ -e "$group_temporary" ] || [ -L "$group_temporary" ]; then
        printf '%s: AgentQ group status temporary remained after cleanup: %s\n' "$program" "$group_temporary" >&2
        return 1
    fi
    group_temporary=''
    group_temporary_identity=''
    return 0
}

require_installer_stage_file() {
    installer_stage_path=$1
    installer_stage_description=$2
    installer_regular_file_is_safe "$installer_stage_path" ||
        fail "$installer_stage_description is unsafe: $installer_stage_path"
}

require_installer_existing_file() {
    installer_existing_path=$1
    installer_existing_description=$2
    installer_existing_regular_file_is_safe "$installer_existing_path" ||
        fail "$installer_existing_description is missing or not a safe regular file: $installer_existing_path"
}

require_installer_absent_path() {
    installer_absent_path=$1
    installer_absent_description=$2
    installer_path_is_absent "$installer_absent_path" ||
        fail "$installer_absent_description already exists or is unsafe: $installer_absent_path"
}

# Whether $1 can only be written through sudo.  Keyed off the directory itself
# rather than off platform_kind: on macOS the service destination's parent is
# root-owned while the wrapper's is the user's own, and one flag per call site
# would have to be re-derived per platform to get that right.
installer_directory_needs_elevation() {
    [ -w "$1" ] || printf 'elevated'
}

# Create an installer temporary inside $1 and print its path; $2 is the name
# prefix, $3 non-empty when the directory is only reachable through sudo (the
# macOS LaunchDaemon directory is root-owned).
#
# Two shapes, and the difference is load-bearing.  mktemp without -u CREATES the
# file (O_EXCL, unguessable suffix) and that is what every site whose content the
# installer itself writes must use: there is then no name to guess and no gap
# between "the path is absent" and "the bytes land there".  mktemp -u only PRINTS
# a name, which is right for the sites whose temporary is a rename target or a
# directory to mkdir -- those operations are already atomic at the final
# component, so what they needed was an unpredictable name, not an atomic
# create.
#
# Before this, every one of these paths was "${destination}.new.$$": a name
# derived from the shell's pid, paired with a check-then-write
# (require_installer_absent_path, then a cp or a redirect).  The check closed no
# window -- anything able to create the file between the two steps owned the
# write.  It also broke installs for no reason at all: a temporary left by a
# killed install collides with a recycled pid, and the absence check then
# refuses the next install with "already exists or is unsafe".
#
# The directory must be the destination's own directory -- the callers move the
# result into place, and a rename is only atomic within one filesystem.
create_installer_temporary_file() {
    installer_temporary_directory=$1
    installer_temporary_prefix=$2
    installer_temporary_elevated=${3:-}

    # mktemp guards the final component only; the directory chain is this
    # installer's own rule.  The callers used to get it from
    # require_installer_absent_path (installer_path_is_safe walks every
    # component), so it belongs here now that the guard is gone.
    #
    # Reported with return, not fail: these helpers run inside a command
    # substitution, where fail's `exit 2` would end only the subshell and hand
    # the caller an empty string.  The caller's own `|| fail` reports it.
    installer_directory_is_safe "$installer_temporary_directory" || {
        printf '%s: temporary directory is unsafe: %s\n' "$program" "$installer_temporary_directory" >&2
        return 1
    }
    if [ -n "$installer_temporary_elevated" ]; then
        run_as_root mktemp "$installer_temporary_directory/$installer_temporary_prefix.XXXXXX"
    else
        mktemp "$installer_temporary_directory/$installer_temporary_prefix.XXXXXX"
    fi
}

create_installer_temporary_name() {
    installer_temporary_name_directory=$1
    installer_temporary_name_prefix=$2
    installer_temporary_name_elevated=${3:-}

    installer_directory_is_safe "$installer_temporary_name_directory" || {
        printf '%s: temporary directory is unsafe: %s\n' "$program" "$installer_temporary_name_directory" >&2
        return 1
    }
    # BSD mktemp -u still opens the template (it creates and unlinks), so it
    # needs write access to the directory exactly like the creating form does.
    # That is why the root-owned LaunchDaemon directory needs the elevated form
    # here too, even though nothing is being created.
    if [ -n "$installer_temporary_name_elevated" ]; then
        run_as_root mktemp -u "$installer_temporary_name_directory/$installer_temporary_name_prefix.XXXXXX"
    else
        mktemp -u "$installer_temporary_name_directory/$installer_temporary_name_prefix.XXXXXX"
    fi
}

authorize_macos_root() {
    [ "$platform_kind" = macos ] || return 0
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || fail 'macOS LaunchDaemon installation requires sudo'
    printf '%s: requesting sudo authorization for the macOS LaunchDaemon\n' "$program" >&2
    sudo -v || fail 'sudo authorization failed; AgentQ installation was not changed'
}

run_launchctl() {
    if [ "$launch_requires_root" = true ]; then
        run_as_root launchctl "$@"
    else
        launchctl "$@"
    fi
}

resolve_macos_launch_domain() {
    macos_uid=$(id -u)

    launch_domain=system
    launch_requires_root=true
    launch_service="$launch_domain/com.agentq.pueued"
    macos_system_service_destination="$macos_system_service_directory/com.agentq.pueued.plist"
}

bootstrap_existing_macos_service() {
    existing_service_path="$HOME/Library/LaunchAgents/com.agentq.pueued.plist"
    macos_uid=$(id -u)
    macos_service_active_before=false
    macos_legacy_service_active_before=false
    macos_legacy_plist_existed_before=false
    macos_legacy_plist_backup_identity=''

    [ "$platform_kind" = macos ] || return 0
    macos_system_service_destination="$macos_system_service_directory/com.agentq.pueued.plist"
    if [ ! -e "$agentq_home" ] && [ ! -e "$existing_service_path" ] && [ ! -e "$macos_system_service_destination" ]; then
        return 0
    fi
    if run_as_root launchctl print system/com.agentq.pueued >/dev/null 2>&1; then
        macos_service_active_before=true
    fi
    if [ -e "$existing_service_path" ]; then
        macos_legacy_plist_existed_before=true
        if run_as_root launchctl print "gui/$macos_uid/com.agentq.pueued" >/dev/null 2>&1; then
            macos_legacy_service="gui/$macos_uid/com.agentq.pueued"
            macos_legacy_service_requires_root=true
            macos_legacy_service_active_before=true
        elif run_as_root launchctl print "user/$macos_uid/com.agentq.pueued" >/dev/null 2>&1; then
            macos_legacy_service="user/$macos_uid/com.agentq.pueued"
            macos_legacy_service_requires_root=true
            macos_legacy_service_active_before=true
        fi
    fi
}

run_macos_legacy_launchctl() {
    if [ "$macos_legacy_service_requires_root" = true ]; then
        run_as_root launchctl "$@"
    else
        launchctl "$@"
    fi
}

retire_legacy_macos_service_file() {
    legacy_service_path="$HOME/Library/LaunchAgents/com.agentq.pueued.plist"

    [ "$platform_kind" = macos ] || return 0
    [ "$macos_legacy_plist_existed_before" = true ] || return 0
    [ "$macos_legacy_plist_moved" = false ] || return 0
    # The prefix keeps the whole original name and randomises only the tail, so
    # the ".agentq-disabled.*" backup shape SKILL.md documents is unchanged.
    macos_legacy_plist_backup=$(create_installer_temporary_name "$HOME/Library/LaunchAgents" 'com.agentq.pueued.plist.agentq-disabled') ||
        fail "failed to reserve the legacy macOS AgentQ LaunchAgent backup path"
    if ! move_installer_file "$legacy_service_path" "$macos_legacy_plist_backup" 'legacy macOS AgentQ LaunchAgent'; then
        fail "failed to disable the legacy macOS AgentQ LaunchAgent: $legacy_service_path"
    fi
    macos_legacy_plist_moved=true
    if ! macos_legacy_plist_backup_identity=$(installer_file_identity "$macos_legacy_plist_backup"); then
        fail "failed to record legacy macOS AgentQ LaunchAgent backup identity: $macos_legacy_plist_backup"
    fi
}

detect_package_manager() {
    case "$platform_kind" in
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                package_manager=apt
            elif command -v dnf >/dev/null 2>&1; then
                package_manager=dnf
            elif command -v yum >/dev/null 2>&1; then
                package_manager=yum
            elif command -v pacman >/dev/null 2>&1; then
                package_manager=pacman
            elif command -v zypper >/dev/null 2>&1; then
                package_manager=zypper
            elif command -v apk >/dev/null 2>&1; then
                package_manager=apk
            fi
            ;;
        macos)
            if command -v brew >/dev/null 2>&1; then
                package_manager=brew
            elif command -v port >/dev/null 2>&1; then
                package_manager=port
            fi
            ;;
    esac
}

install_package() {
    package_name=$1

    [ -n "$package_manager" ] || fail "missing dependency $package_name and no supported package manager is available"
    printf '%s: installing missing dependency: %s\n' "$program" "$package_name" >&2

    case "$package_manager" in
        apt)
            if [ "$apt_updated" = false ]; then
                run_as_root apt-get update
                apt_updated=true
            fi
            run_as_root apt-get install -y "$package_name"
            ;;
        dnf)
            run_as_root dnf install -y "$package_name"
            ;;
        yum)
            run_as_root yum install -y "$package_name"
            ;;
        pacman)
            run_as_root pacman -S --needed --noconfirm "$package_name"
            ;;
        zypper)
            run_as_root zypper --non-interactive install "$package_name"
            ;;
        apk)
            run_as_root apk add "$package_name"
            ;;
        brew)
            brew install "$package_name"
            ;;
        port)
            run_as_root port install "$package_name"
            ;;
        *)
            fail "unsupported package manager: $package_manager"
            ;;
    esac
}

ensure_dependency() {
    command_name=$1
    package_name=$2

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    install_package "$package_name"
    require_command "$command_name"
}

download_and_verify() {
    destination=$1
    url=$2
    expected_sha256=$3
    destination_parent=$(dirname "$destination")
    download_temporary_identity=''

    installer_directory_is_safe "$destination_parent" ||
        fail "download destination parent is unsafe: $destination_parent"
    require_installer_stage_file "$destination" 'download destination path'
    temporary=$(create_installer_temporary_file "$destination_parent" '.agentq-download') ||
        fail "failed to create the AgentQ download temporary in: $destination_parent"
    download_temporary=$temporary

    if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 300 \
        --output "$temporary" "$url"; then
        :
    else
        download_status=$?
        if [ -e "$temporary" ] || [ -L "$temporary" ]; then
            download_temporary_identity=$(installer_file_identity "$temporary") || {
                printf '%s: failed to inspect the AgentQ download temporary: %s\n' "$program" "$temporary" >&2
                return 1
            }
        fi
        discard_download_temporary || return 1
        # The installer's failure contract is exit 2 with a prefixed message.
        # Returning curl's own code (7 connect, 22 HTTP, 28 timeout, ...) made a
        # network failure indistinguishable from a rejected install -- measured
        # 2026-10-06 with a curl stub exiting 7.  curl has already printed its
        # own --show-error line; this adds the installer's attribution.
        fail "failed to download the AgentQ Pueue binary: $url (curl exit code $download_status)"
    fi
    require_installer_stage_file "$temporary" 'download temporary path'
    download_temporary_identity=$(installer_file_identity "$temporary") || {
        discard_download_temporary || return 1
        return 1
    }
    actual_sha256=$(sha256_file "$temporary")
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        if ! discard_download_temporary; then
            fail "failed to clean up the downloaded AgentQ binary after checksum mismatch: $url"
        fi
        fail "sha256 mismatch for $url"
    fi
    installer_directory_is_safe "$destination_parent" || fail "download destination parent is unsafe: $destination_parent"
    require_installer_stage_file "$temporary" 'download temporary path'
    require_installer_stage_file "$destination" 'download destination path'
    chmod 700 "$temporary"
    require_installer_stage_file "$temporary" 'download temporary path'
    require_installer_stage_file "$destination" 'download destination path'
    if ! mv -f -- "$temporary" "$destination"; then
        fail "failed to install the verified AgentQ binary: $destination"
    fi
    if ! installer_existing_regular_file_is_safe "$destination" ||
        ! installer_path_is_absent "$temporary"; then
        fail "download replacement move identity check failed"
    fi
    download_temporary=''
    download_temporary_identity=''
}

stage_verified_binary() {
    destination=$1
    asset_name=$2
    url=$3
    expected_sha256=$4
    existing_path=$5
    source_path=''
    destination_parent=$(dirname "$destination")

    installer_directory_is_safe "$destination_parent" ||
        fail "staged binary destination parent is unsafe: $destination_parent"
    require_installer_stage_file "$destination" 'staged binary destination path'
    # Created per branch rather than here: the download fallback below never
    # touches binary_temporary, and a temporary created eagerly would then be
    # left behind inside the staging tree with its variable already cleared.
    binary_temporary=''
    binary_temporary_identity=''
    if [ -n "$artifact_source_directory" ]; then
        source_path="$artifact_source_directory/$asset_name"
        installer_path_is_safe "$artifact_source_directory" ||
            fail "staged binary source directory is unsafe: $artifact_source_directory"
        require_installer_stage_file "$source_path" 'staged binary source path'
        actual_sha256=$(sha256_file "$source_path")
        [ "$actual_sha256" = "$expected_sha256" ] || fail "sha256 mismatch for staged asset: $source_path"
        binary_temporary=$(create_installer_temporary_file "$destination_parent" '.agentq-binary') ||
            fail "failed to create the staged binary temporary in: $destination_parent"
        if ! cp "$source_path" "$binary_temporary"; then
            if [ -e "$binary_temporary" ] && [ -f "$binary_temporary" ] &&
                ! [ -L "$binary_temporary" ]; then
                binary_temporary_identity=$(installer_file_identity "$binary_temporary") || true
            fi
            fail "failed to stage the AgentQ binary: $destination"
        fi
        if [ -f "$binary_temporary" ] && [ ! -L "$binary_temporary" ]; then
            binary_temporary_identity=$(installer_file_identity "$binary_temporary") ||
                fail "failed to inspect AgentQ binary temporary: $binary_temporary"
        fi
        require_installer_stage_file "$binary_temporary" 'staged binary temporary path'
        chmod 700 "$binary_temporary"
        installer_directory_is_safe "$destination_parent" || fail "staged binary destination parent is unsafe: $destination_parent"
        require_installer_stage_file "$binary_temporary" 'staged binary temporary path'
        require_installer_stage_file "$destination" 'staged binary destination path'
        if ! mv -f -- "$binary_temporary" "$destination"; then
            fail "failed to install the staged AgentQ binary: $destination"
        fi
        if ! installer_existing_regular_file_is_safe "$destination" ||
            ! installer_path_is_absent "$binary_temporary"; then
            fail "staged binary replacement move identity check failed"
        fi
        binary_temporary=''
        binary_temporary_identity=''
        return 0
    fi

    installer_path_is_safe "$existing_path" ||
        fail "existing AgentQ binary path is unsafe: $existing_path"
    if [ -e "$existing_path" ] || [ -L "$existing_path" ]; then
        require_installer_stage_file "$existing_path" 'existing AgentQ binary path'
    fi
    if [ -x "$existing_path" ]; then
        source_path=$existing_path
        actual_sha256=$(sha256_file "$source_path")
        if [ "$actual_sha256" = "$expected_sha256" ]; then
            binary_temporary=$(create_installer_temporary_file "$destination_parent" '.agentq-binary') ||
                fail "failed to create the staged binary temporary in: $destination_parent"
            if ! cp "$source_path" "$binary_temporary"; then
                if [ -e "$binary_temporary" ] && [ -f "$binary_temporary" ] &&
                    ! [ -L "$binary_temporary" ]; then
                    binary_temporary_identity=$(installer_file_identity "$binary_temporary") || true
                fi
                fail "failed to stage the AgentQ binary: $destination"
            fi
            if [ -f "$binary_temporary" ] && [ ! -L "$binary_temporary" ]; then
                binary_temporary_identity=$(installer_file_identity "$binary_temporary") ||
                    fail "failed to inspect AgentQ binary temporary: $binary_temporary"
            fi
            require_installer_stage_file "$binary_temporary" 'staged binary temporary path'
            chmod 700 "$binary_temporary"
            installer_directory_is_safe "$destination_parent" || fail "staged binary destination parent is unsafe: $destination_parent"
            require_installer_stage_file "$binary_temporary" 'staged binary temporary path'
            require_installer_stage_file "$destination" 'staged binary destination path'
            if ! mv -f -- "$binary_temporary" "$destination"; then
                fail "failed to install the existing AgentQ binary: $destination"
            fi
            if ! installer_existing_regular_file_is_safe "$destination" ||
                ! installer_path_is_absent "$binary_temporary"; then
                fail "existing binary replacement move identity check failed"
            fi
            binary_temporary=''
            binary_temporary_identity=''
            return 0
        fi
    fi

    if download_and_verify "$destination" "$url" "$expected_sha256"; then
        binary_temporary=''
        binary_temporary_identity=''
    else
        binary_status=$?
        return "$binary_status"
    fi
}

assert_existing_queue_has_no_active_tasks() {
    existing_client="$agentq_home/pueue"
    existing_config="$agentq_home/config/pueue.yml"

    if [ ! -e "$agentq_home" ]; then
        return 0
    fi

    existing_installation_paths_are_safe "$agentq_home" ||
        fail "existing AgentQ installation contains an unsafe path; refuse to overwrite $agentq_home"
    [ -d "$agentq_home" ] || fail "existing AgentQ path is not a directory: $agentq_home"
    [ ! -L "$agentq_home" ] || fail "existing AgentQ path must not be a symbolic link: $agentq_home"
    [ -x "$existing_client" ] || fail "existing AgentQ installation is incomplete; refuse to overwrite $agentq_home"
    [ -f "$existing_config" ] || fail "existing AgentQ installation is incomplete; refuse to overwrite $agentq_home"

    existing_pid_file="$agentq_home/runtime/pueued.pid"
    if [ -e "$existing_pid_file" ] && [ ! -f "$existing_pid_file" ]; then
        fail "existing AgentQ daemon pid path is not a regular file; refuse to overwrite $agentq_home"
    fi
    if [ -e "$existing_pid_file" ] || [ -L "$existing_pid_file" ]; then
        installer_existing_regular_file_is_safe "$existing_pid_file" ||
            fail "existing AgentQ daemon pid path is not a regular file; refuse to overwrite $agentq_home"
    fi
    if [ -r "$existing_pid_file" ]; then
        existing_pid=$(tr -d '\r\n' < "$existing_pid_file")
        case "$existing_pid" in
            ''|*[!0-9]*) fail "existing AgentQ daemon pid file is invalid; refuse to overwrite $agentq_home" ;;
        esac
        if kill -0 "$existing_pid" 2>/dev/null; then
            existing_process_command=$(ps -o command= -p "$existing_pid" 2>/dev/null | awk '{$1 = $1; print}')
            case "$existing_process_command" in
                *"$agentq_home/pueued"*)
                    existing_daemon_live=true
                    ;;
                *)
                    fail "an unrelated live process owns the existing AgentQ pid; refuse to overwrite $agentq_home"
                    ;;
            esac
        fi
    fi

    existing_status_temporary=$(create_installer_temporary_file "$agentq_home/runtime" '.agentq-existing-status') ||
        fail "failed to create the AgentQ existing status temporary in: $agentq_home/runtime"
    existing_status_temporary_identity=''
    if "$existing_client" --config "$existing_config" status --json > "$existing_status_temporary" 2>/dev/null; then
        if [ -f "$existing_status_temporary" ] && [ ! -L "$existing_status_temporary" ]; then
            existing_status_temporary_identity=$(installer_file_identity "$existing_status_temporary") ||
                fail "failed to inspect AgentQ existing status temporary: $existing_status_temporary"
        fi
    elif [ "$platform_kind" = macos ] && [ "$existing_daemon_live" = false ] && \
        [ "$macos_service_active_before" = false ] && [ "$macos_legacy_service_active_before" = false ]; then
        if [ -f "$existing_status_temporary" ] && [ ! -L "$existing_status_temporary" ]; then
            existing_status_temporary_identity=$(installer_file_identity "$existing_status_temporary") || true
        fi
        discard_existing_status_temporary ||
            fail "failed to clean AgentQ existing status temporary before offline state migration"
        existing_state="$agentq_home/data/state.json.gz"
        [ -f "$existing_state" ] || fail "existing AgentQ daemon is unavailable and its compressed state is missing; refuse to overwrite $agentq_home"
        require_command gzip
        # A second temporary for the decompressed state.  The first one was just
        # discarded, so this is the same pattern rather than a reuse: gzip
        # truncates whatever it is given, and a reused path would leave a window
        # between the discard and the redirect.
        existing_status_temporary=$(create_installer_temporary_file "$agentq_home/runtime" '.agentq-existing-status') ||
            fail "failed to create the AgentQ existing status temporary in: $agentq_home/runtime"
        if ! gzip -cd -- "$existing_state" > "$existing_status_temporary"; then
            if [ -f "$existing_status_temporary" ] && [ ! -L "$existing_status_temporary" ]; then
                existing_status_temporary_identity=$(installer_file_identity "$existing_status_temporary") || true
            fi
            fail "existing AgentQ compressed state cannot be read; refuse to overwrite $agentq_home"
        fi
        existing_status_temporary_identity=$(installer_file_identity "$existing_status_temporary") ||
            fail "failed to inspect AgentQ existing status temporary: $existing_status_temporary"
        previous_queue_verified_offline=true
    else
        if [ -f "$existing_status_temporary" ] && [ ! -L "$existing_status_temporary" ]; then
            existing_status_temporary_identity=$(installer_file_identity "$existing_status_temporary") || true
        fi
        fail "existing AgentQ daemon is unavailable; start it and re-run (the installer must confirm the queue is idle before replacing a deployment), or restore the deployment manually; refusing to overwrite $agentq_home"
    fi
    require_installer_existing_file "$existing_status_temporary" 'existing status temporary path'
    jq -e '
        (.tasks | type) == "object"
        and all(.tasks[];
            (.status | type) == "object"
            and (.status | has("Done"))
        )
    ' < "$existing_status_temporary" >/dev/null || fail "existing AgentQ queue has active tasks or its state is invalid; wait for them to finish before reinstalling"
    discard_existing_status_temporary || fail 'failed to clean AgentQ existing status temporary'

    previous_install=true
}

wait_for_daemon() {
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        if "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" status --json >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    fail "AgentQ daemon did not become ready after ${attempt}s"
}

ensure_linux_linger() {
    linger_user=$(id -un)
    linger_state=$(loginctl show-user "$linger_user" -p Linger --value 2>/dev/null) || fail 'failed to inspect systemd user lingering before installing AgentQ'
    case "$linger_state" in
        yes)
            linux_linger_before=yes
            return 0
            ;;
        no)
            linux_linger_before=no
            ;;
        *)
            fail "unexpected systemd user lingering state before installing AgentQ: $linger_state"
            ;;
    esac

    if ! loginctl enable-linger "$linger_user"; then
        fail 'failed to enable systemd user lingering for AgentQ'
    fi
    linux_linger_changed=true

    linger_state=$(loginctl show-user "$linger_user" -p Linger --value 2>/dev/null) || fail 'failed to verify systemd user lingering for AgentQ'
    [ "$linger_state" = yes ] || fail "systemd user lingering is not enabled for AgentQ: $linger_state"
}

is_wsl_environment() {
    [ -r /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease && return 0
    [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version
}

ensure_wsl_systemd_user_runtime() {
    [ "$platform_kind" = linux ] || return 0
    is_wsl_environment || return 0

    init_process=$(ps -p 1 -o comm= 2>/dev/null | awk '{$1 = $1; print}')
    [ "$init_process" = systemd ] || fail 'WSL requires systemd as PID 1 for persistent AgentQ; enable systemd in /etc/wsl.conf and restart the WSL distribution'
    systemctl --user show-environment >/dev/null 2>&1 || fail 'WSL systemd user service is unavailable for this SSH user; log in once after enabling systemd and retry AgentQ installation'
    loginctl show-user "$(id -un)" >/dev/null 2>&1 || fail 'WSL logind is unavailable; AgentQ requires a functional systemd user service with linger support'
}

restore_linux_linger() {
    [ "$linux_linger_changed" = true ] || return 0
    [ "$linux_linger_before" = no ] || return 1

    if ! loginctl disable-linger "$(id -un)"; then
        return 1
    fi
    linger_state=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null) || return 1
    [ "$linger_state" = "$linux_linger_before" ] || return 1
    linux_linger_changed=false
}

prepare_service_stage() {
    service_stage_identity=''
    case "$platform_kind" in
        linux)
            service_destination="$HOME/.config/systemd/user/agentq-pueued.service"
            service_stage=$(create_installer_temporary_file "$agentq_parent" '.agentq-service.stage') ||
                fail "failed to create the AgentQ service staging path in: $agentq_parent"
            cp "$asset_directory/agentq-pueued.service" "$service_stage"
            chmod 600 "$service_stage"
            require_installer_stage_file "$service_stage" 'service staging path'
            ;;
        macos)
            service_destination="$macos_system_service_directory/com.agentq.pueued.plist"
            service_stage=$(create_installer_temporary_file "$agentq_parent" '.agentq-plist.stage') ||
                fail "failed to create the AgentQ service staging path in: $agentq_parent"
            escaped_home=$(printf '%s' "$agentq_home" | sed 's/[\\&|]/\\&/g')
            escaped_user=$(printf '%s' "$(id -un)" | sed 's/[\\&|]/\\&/g')
            escaped_home_parent=$(printf '%s' "$HOME" | sed 's/[\\&|]/\\&/g')
            # Both directions, like the Windows renderer: first require that the
            # template still carries every token this sed list substitutes.  A
            # token deleted from the template would otherwise render "cleanly"
            # (nothing to replace, nothing left over, plutil-lint passes) into a
            # plist with a missing key -- measured gap recorded 2026-10-06.
            for service_placeholder in __AGENTQ_HOME__ __AGENTQ_USER__ __AGENTQ_HOME_PARENT__; do
                grep -qF "$service_placeholder" "$asset_directory/com.agentq.pueued.daemon.plist" ||
                    fail "service template is missing the $service_placeholder placeholder: $asset_directory/com.agentq.pueued.daemon.plist"
            done
            sed -e "s|__AGENTQ_HOME__|$escaped_home|g" \
                -e "s|__AGENTQ_USER__|$escaped_user|g" \
                -e "s|__AGENTQ_HOME_PARENT__|$escaped_home_parent|g" \
                "$asset_directory/com.agentq.pueued.daemon.plist" > "$service_stage"
            chmod 600 "$service_stage"
            require_installer_stage_file "$service_stage" 'service staging path'
            # A placeholder that survives substitution means the template and this
            # sed list have drifted apart (a renamed or newly added token): launchd
            # would then exec a literal "__AGENTQ_...__" path.  The Windows
            # installer guards its templates the same way; fail loudly instead of
            # installing a service that cannot start.  The pattern is deliberately
            # generic rather than a list of the three known tokens, so a token
            # added to the template but not to the sed list is caught too -- which
            # is the drift this exists for.  A substituted value would have to
            # contain a literal "__ALLCAPS__" run to trip it, and if that ever
            # happened the install fails loudly with this message rather than
            # writing a broken service.
            if grep -qE '__[A-Z][A-Z0-9_]*__' "$service_stage"; then
                fail "generated launchd plist retained a template placeholder: $service_stage"
            fi
            plutil -lint "$service_stage" >/dev/null || fail "generated launchd plist is invalid: $service_stage"
            resolve_macos_launch_domain
            ;;
    esac

    installer_path_is_safe "$service_destination" ||
        fail "service destination path is unsafe: $service_destination"
    service_stage_identity=$(installer_file_identity "$service_stage") ||
        fail "failed to inspect AgentQ service staging path: $service_stage"

    if [ -e "$service_destination" ] || [ -L "$service_destination" ]; then
        service_existed_before=true
    fi
}

stop_managed_daemon() {
    if [ "$previous_install" = false ] && [ "$candidate_installed" = false ] && \
        [ "$macos_legacy_service_active_before" = false ] && [ "$macos_service_active_before" = false ]; then
        return 0
    fi

    case "$platform_kind" in
        linux)
            if ! systemctl --user stop agentq-pueued.service; then
                printf '%s: failed to stop the managed AgentQ systemd user service\n' "$program" >&2
                return 1
            fi
            ;;
        macos)
            if [ "$macos_legacy_service_active_before" = true ]; then
                if ! run_macos_legacy_launchctl bootout "$macos_legacy_service"; then
                    printf '%s: failed to stop the legacy macOS AgentQ launchd service\n' "$program" >&2
                    return 1
                fi
            fi
            if run_launchctl print "$launch_service" >/dev/null 2>&1; then
                if ! run_launchctl bootout "$launch_service"; then
                    printf '%s: failed to stop the managed AgentQ launchd service\n' "$program" >&2
                    return 1
                fi
            fi
            ;;
    esac

    attempt=0
    while [ "$attempt" -lt 10 ]; do
        daemon_active=false
        case "$platform_kind" in
            linux)
                if systemctl --user is-active --quiet agentq-pueued.service; then
                    daemon_active=true
                fi
                ;;
            macos)
                if run_launchctl print "$launch_service" >/dev/null 2>&1; then
                    daemon_active=true
                fi
                ;;
        esac
        if [ "$daemon_active" = false ] && ! "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" status --json >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    printf '%s: managed AgentQ daemon did not stop; refusing to replace a live deployment\n' "$program" >&2
    return 1
}

start_managed_daemon() {
    case "$platform_kind" in
        linux)
            systemctl --user daemon-reload
            systemctl --user enable agentq-pueued.service >/dev/null
            systemctl --user start agentq-pueued.service
            ;;
        macos)
            if ! run_launchctl print "$launch_service" >/dev/null 2>&1; then
                run_launchctl bootstrap "$launch_domain" "$service_destination"
            fi
            run_launchctl kickstart "$launch_service"
            ;;
    esac
}

verify_health_status() {
    health_temporary=$(create_installer_temporary_file "$agentq_home/runtime" '.agentq-health-status') ||
        fail "failed to create the AgentQ health status temporary in: $agentq_home/runtime"
    health_temporary_identity=''

    if ! "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" status --json > "$health_temporary"; then
        if [ -f "$health_temporary" ] && [ ! -L "$health_temporary" ]; then
            health_temporary_identity=$(installer_file_identity "$health_temporary") || true
        fi
        fail 'AgentQ Pueue health check failed'
    fi
    if [ -f "$health_temporary" ] && [ ! -L "$health_temporary" ]; then
        health_temporary_identity=$(installer_file_identity "$health_temporary") ||
            fail "failed to inspect AgentQ health status temporary: $health_temporary"
    fi
    require_installer_existing_file "$health_temporary" 'health status temporary path'
    jq -e '(.tasks | type) == "object" and (.groups.agentq | type) == "object"' \
        < "$health_temporary" >/dev/null || fail 'AgentQ health check returned an invalid Pueue status payload'
    discard_health_temporary || fail 'failed to clean AgentQ health status temporary'
}

ensure_agentq_group() {
    group_temporary=$(create_installer_temporary_file "$agentq_home/runtime" '.agentq-group-status') ||
        fail "failed to create the AgentQ group status temporary in: $agentq_home/runtime"
    group_temporary_identity=''

    if "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" group --json > "$group_temporary"; then
        if [ -f "$group_temporary" ] && [ ! -L "$group_temporary" ]; then
            group_temporary_identity=$(installer_file_identity "$group_temporary") ||
                fail "failed to inspect AgentQ group status temporary: $group_temporary"
        fi
    else
        if [ -f "$group_temporary" ] && [ ! -L "$group_temporary" ]; then
            group_temporary_identity=$(installer_file_identity "$group_temporary") || true
        fi
        fail 'AgentQ group query failed'
    fi
    require_installer_existing_file "$group_temporary" 'group status temporary path'
    [ -n "$group_temporary_identity" ] || fail "failed to inspect AgentQ group status temporary: $group_temporary"
    jq -e 'type == "object"' < "$group_temporary" >/dev/null ||
        fail 'AgentQ group query returned invalid JSON'
    if jq -e 'has("agentq")' < "$group_temporary" >/dev/null; then
        "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" parallel --group agentq 1 >/dev/null ||
            fail 'AgentQ group parallelism update failed'
    else
        "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" group add --parallel 1 agentq >/dev/null ||
            fail 'AgentQ group creation failed'
    fi
    discard_group_temporary || fail 'failed to clean AgentQ group status temporary'
}

replace_service_file() {
    service_parent_directory=$(dirname "$service_destination")
    installer_path_is_safe "$service_parent_directory" ||
        fail "service destination parent is unsafe: $service_parent_directory"
    if [ "$platform_kind" = macos ]; then
        run_as_root mkdir -p "$service_parent_directory"
    else
        mkdir -p "$service_parent_directory"
    fi
    installer_directory_is_safe "$service_parent_directory" ||
        fail "service destination parent is unsafe: $service_parent_directory"
    require_installer_stage_file "$service_stage" 'service staging path'
    require_installer_stage_file "$service_destination" 'service destination path'
    if [ -e "$service_destination" ] || [ -L "$service_destination" ]; then
        service_backup=$(create_installer_temporary_name "$service_parent_directory" '.agentq-service-backup' \
            "$(installer_directory_needs_elevation "$service_parent_directory")") ||
            fail "failed to reserve the AgentQ service backup path in: $service_parent_directory"
        service_backup_identity=''
        require_installer_absent_path "$service_backup" 'service backup path'
        if [ "$platform_kind" = macos ]; then
            if ! run_as_root mv -- "$service_destination" "$service_backup"; then
                if [ -e "$service_backup" ] && [ -f "$service_backup" ] &&
                    ! [ -L "$service_backup" ]; then
                    service_backup_identity=$(installer_file_identity "$service_backup") || true
                fi
                fail "failed to move the previous AgentQ service definition into its backup"
            fi
        else
            if ! mv -- "$service_destination" "$service_backup"; then
                if [ -e "$service_backup" ] && [ -f "$service_backup" ] &&
                    ! [ -L "$service_backup" ]; then
                    service_backup_identity=$(installer_file_identity "$service_backup") || true
                fi
                fail "failed to move the previous AgentQ service definition into its backup"
            fi
        fi
        if ! installer_existing_regular_file_is_safe "$service_backup" ||
            ! installer_path_is_absent "$service_destination"; then
            fail "service backup move identity check failed"
        fi
        service_backup_identity=$(installer_file_identity "$service_backup") ||
            fail "failed to inspect AgentQ service backup: $service_backup"
        previous_service=true
    fi

    service_temporary=$(create_installer_temporary_file "$service_parent_directory" '.agentq-service' \
        "$(installer_directory_needs_elevation "$service_parent_directory")") ||
        fail "failed to create the AgentQ service temporary in: $service_parent_directory"
    service_temporary_identity=''
    installer_path_is_safe "$service_parent_directory" ||
        fail "service destination parent is unsafe: $service_parent_directory"
    require_installer_stage_file "$service_destination" 'service destination path'
    if [ "$platform_kind" = macos ]; then
        if ! run_as_root cp "$service_stage" "$service_temporary"; then
            if [ -e "$service_temporary" ] && [ -f "$service_temporary" ] &&
                ! [ -L "$service_temporary" ]; then
                service_temporary_identity=$(installer_file_identity "$service_temporary") || true
            fi
            fail "failed to stage the new AgentQ service definition"
        fi
        if [ -f "$service_temporary" ] && [ ! -L "$service_temporary" ]; then
            service_temporary_identity=$(installer_file_identity "$service_temporary") ||
                fail "failed to inspect AgentQ service temporary: $service_temporary"
        fi
        run_as_root chmod 644 "$service_temporary"
        run_as_root chown root:wheel "$service_temporary"
        require_installer_stage_file "$service_temporary" 'service temporary path'
        require_installer_stage_file "$service_destination" 'service destination path'
        if ! run_as_root mv -f -- "$service_temporary" "$service_destination"; then
            fail "failed to install the new AgentQ service definition"
        fi
    else
        if ! cp "$service_stage" "$service_temporary"; then
            if [ -e "$service_temporary" ] && [ -f "$service_temporary" ] &&
                ! [ -L "$service_temporary" ]; then
                service_temporary_identity=$(installer_file_identity "$service_temporary") || true
            fi
            fail "failed to stage the new AgentQ service definition"
        fi
        if [ -f "$service_temporary" ] && [ ! -L "$service_temporary" ]; then
            service_temporary_identity=$(installer_file_identity "$service_temporary") ||
                fail "failed to inspect AgentQ service temporary: $service_temporary"
        fi
        chmod 600 "$service_temporary"
        require_installer_stage_file "$service_temporary" 'service temporary path'
        require_installer_stage_file "$service_destination" 'service destination path'
        if ! mv -f -- "$service_temporary" "$service_destination"; then
            fail "failed to install the new AgentQ service definition"
        fi
    fi
    if ! installer_existing_regular_file_is_safe "$service_destination" ||
        ! installer_path_is_absent "$service_temporary"; then
        fail "service replacement move identity check failed"
    fi
    service_temporary=''
    service_temporary_identity=''
    service_replaced=true
}

replace_wrapper() {
    wrapper_parent_directory=$(dirname "$wrapper_destination")
    installer_path_is_safe "$wrapper_parent_directory" ||
        fail "wrapper destination parent is unsafe: $wrapper_parent_directory"
    mkdir -p "$wrapper_parent_directory"
    if ! chmod 700 "$HOME/.local" "$HOME/.local/bin" 2>/dev/null; then
        fail "failed to secure AgentQ wrapper directory: $HOME/.local"
    fi
    installer_directory_is_safe "$wrapper_parent_directory" ||
        fail "wrapper destination parent is unsafe: $wrapper_parent_directory"
    require_installer_stage_file "$wrapper_destination" 'wrapper destination path'

    if [ -e "$wrapper_destination" ] || [ -L "$wrapper_destination" ]; then
        wrapper_backup=$(create_installer_temporary_name "$wrapper_parent_directory" '.agentq-wrapper-backup') ||
            fail "failed to reserve the AgentQ wrapper backup path in: $wrapper_parent_directory"
        wrapper_backup_identity=''
        require_installer_absent_path "$wrapper_backup" 'wrapper backup path'
        if ! mv -- "$wrapper_destination" "$wrapper_backup"; then
            if [ -e "$wrapper_backup" ] && [ -f "$wrapper_backup" ] &&
                ! [ -L "$wrapper_backup" ]; then
                wrapper_backup_identity=$(installer_file_identity "$wrapper_backup") || true
            fi
            fail "failed to move the previous AgentQ wrapper into its backup"
        fi
        if ! installer_existing_regular_file_is_safe "$wrapper_backup" ||
            ! installer_path_is_absent "$wrapper_destination"; then
            fail "wrapper backup move identity check failed"
        fi
        wrapper_backup_identity=$(installer_file_identity "$wrapper_backup") ||
            fail "failed to inspect AgentQ wrapper backup: $wrapper_backup"
        previous_wrapper=true
    fi

    wrapper_temporary=$(create_installer_temporary_file "$wrapper_parent_directory" '.agentq-wrapper') ||
        fail "failed to create the AgentQ wrapper temporary in: $wrapper_parent_directory"
    wrapper_temporary_identity=''
    installer_path_is_safe "$wrapper_parent_directory" ||
        fail "wrapper destination parent is unsafe: $wrapper_parent_directory"
    require_installer_stage_file "$wrapper_destination" 'wrapper destination path'
    if ! cp "$asset_directory/agentq" "$wrapper_temporary"; then
        if [ -e "$wrapper_temporary" ] && [ -f "$wrapper_temporary" ] &&
            ! [ -L "$wrapper_temporary" ]; then
            wrapper_temporary_identity=$(installer_file_identity "$wrapper_temporary") || true
        fi
        fail "failed to stage the new AgentQ wrapper"
    fi
    if [ -f "$wrapper_temporary" ] && [ ! -L "$wrapper_temporary" ]; then
        wrapper_temporary_identity=$(installer_file_identity "$wrapper_temporary") ||
            fail "failed to inspect AgentQ wrapper temporary: $wrapper_temporary"
    fi
    chmod 700 "$wrapper_temporary"
    require_installer_stage_file "$wrapper_temporary" 'wrapper temporary path'
    require_installer_stage_file "$wrapper_destination" 'wrapper destination path'
    if ! mv -f -- "$wrapper_temporary" "$wrapper_destination"; then
        fail "failed to install the new AgentQ wrapper"
    fi
    if ! installer_existing_regular_file_is_safe "$wrapper_destination" ||
        ! installer_path_is_absent "$wrapper_temporary"; then
        fail "wrapper replacement move identity check failed"
    fi
    wrapper_temporary=''
    wrapper_temporary_identity=''
    wrapper_replaced=true
}

restore_service_file() {
    [ "$service_replaced" = true ] || [ "$previous_service" = true ] || return 0
    installer_path_is_safe "$service_destination" || return 1
    installer_regular_file_is_safe "$service_destination" || return 1
    # The replacement's temporary used to be recomputed here from the pid
    # ("${service_destination}.new.$$", the same name replace_service_file
    # chose).  Its name is mktemp's now, so the variable that holds it is the
    # only handle -- and an empty value means the replacement never created one
    # or already moved it into place, which is exactly when there is nothing
    # here to clean up.
    service_restore_temporary_path="$service_temporary"
    if [ -n "$service_restore_temporary_path" ]; then
        installer_path_is_safe "$service_restore_temporary_path" || return 1
        installer_regular_file_is_safe "$service_restore_temporary_path" || return 1
        if [ -n "$service_restore_temporary" ]; then
            [ "$service_restore_temporary" = "$service_restore_temporary_path" ] || return 1
        else
            service_restore_temporary="$service_restore_temporary_path"
            if [ -e "$service_restore_temporary" ] || [ -L "$service_restore_temporary" ]; then
                service_restore_temporary_identity=$(installer_file_identity "$service_restore_temporary") || return 1
            else
                service_restore_temporary_identity=''
            fi
        fi
    fi
    if [ "$previous_service" = true ]; then
        installer_existing_regular_file_is_safe "$service_backup" || return 1
        [ -n "$service_backup_identity" ] || return 1
        service_backup_observed_identity=$(installer_file_identity "$service_backup") || return 1
        [ "$service_backup_observed_identity" = "$service_backup_identity" ] || return 1
    fi
    remove_installer_file "$service_destination" || return 1
    discard_service_restore_temporary || return 1
    if [ "$previous_service" = true ]; then
        installer_path_is_safe "$(dirname "$service_destination")" || return 1
        if [ "$platform_kind" = macos ]; then
            if ! run_as_root mv -- "$service_backup" "$service_destination"; then
                return 1
            fi
        else
            if ! mv -- "$service_backup" "$service_destination"; then
                return 1
            fi
        fi
        if ! installer_existing_regular_file_is_safe "$service_destination" ||
            ! installer_path_is_absent "$service_backup"; then
            return 1
        fi
        service_backup=''
        service_backup_identity=''
    fi
}

restore_legacy_macos_service_file() {
    [ "$platform_kind" = macos ] || return 0
    [ "$macos_legacy_plist_moved" = true ] || return 0
    if ! installer_existing_regular_file_is_safe "$macos_legacy_plist_backup"; then
        printf '%s: legacy macOS AgentQ LaunchAgent restore source is unsafe or missing: %s\n' \
            "$program" "$macos_legacy_plist_backup" >&2
        return 1
    fi
    if [ -z "$macos_legacy_plist_backup_identity" ]; then
        printf '%s: legacy macOS AgentQ LaunchAgent restore source has no recorded identity: %s\n' \
            "$program" "$macos_legacy_plist_backup" >&2
        return 1
    fi
    macos_legacy_plist_backup_observed_identity=$(installer_file_identity "$macos_legacy_plist_backup") || return 1
    if [ "$macos_legacy_plist_backup_observed_identity" != "$macos_legacy_plist_backup_identity" ]; then
        printf '%s: legacy macOS AgentQ LaunchAgent backup identity changed before restore; preserving it: %s\n' \
            "$program" "$macos_legacy_plist_backup" >&2
        return 1
    fi
    if ! move_installer_file "$macos_legacy_plist_backup" "$HOME/Library/LaunchAgents/com.agentq.pueued.plist" 'legacy macOS AgentQ LaunchAgent restore'; then
        return 1
    fi
    macos_legacy_plist_moved=false
    macos_legacy_plist_backup=''
    macos_legacy_plist_backup_identity=''
}

restore_wrapper() {
    [ "$wrapper_replaced" = true ] || [ "$previous_wrapper" = true ] || return 0
    installer_path_is_safe "$wrapper_destination" || return 1
    installer_regular_file_is_safe "$wrapper_destination" || return 1
    # Same as restore_service_file: the temporary's name is the one
    # replace_wrapper chose, so it is read from that variable rather than
    # recomputed.
    wrapper_restore_temporary_path="$wrapper_temporary"
    if [ -n "$wrapper_restore_temporary_path" ]; then
        installer_path_is_safe "$wrapper_restore_temporary_path" || return 1
        installer_regular_file_is_safe "$wrapper_restore_temporary_path" || return 1
        if [ -n "$wrapper_restore_temporary" ]; then
            [ "$wrapper_restore_temporary" = "$wrapper_restore_temporary_path" ] || return 1
        else
            wrapper_restore_temporary="$wrapper_restore_temporary_path"
            if [ -e "$wrapper_restore_temporary" ] || [ -L "$wrapper_restore_temporary" ]; then
                wrapper_restore_temporary_identity=$(installer_file_identity "$wrapper_restore_temporary") || return 1
            else
                wrapper_restore_temporary_identity=''
            fi
        fi
    fi
    if [ "$previous_wrapper" = true ]; then
        installer_existing_regular_file_is_safe "$wrapper_backup" || return 1
        [ -n "$wrapper_backup_identity" ] || return 1
        wrapper_backup_observed_identity=$(installer_file_identity "$wrapper_backup") || return 1
        [ "$wrapper_backup_observed_identity" = "$wrapper_backup_identity" ] || return 1
    fi
    remove_installer_file "$wrapper_destination" || return 1
    discard_wrapper_restore_temporary || return 1
    if [ "$previous_wrapper" = true ]; then
        installer_path_is_safe "$(dirname "$wrapper_destination")" || return 1
        if ! mv -- "$wrapper_backup" "$wrapper_destination"; then
            return 1
        fi
        if ! installer_existing_regular_file_is_safe "$wrapper_destination" ||
            ! installer_path_is_absent "$wrapper_backup"; then
            return 1
        fi
        wrapper_backup=''
        wrapper_backup_identity=''
    fi
}

secure_stage_tree() {
    require_installer_tree "$stage_home" 'staging tree'
    for stage_directory in \
        "$stage_home/config" "$stage_home/data" \
        "$stage_home/data/task_logs" "$stage_home/data/agentq-cancellations" \
        "$stage_home/data/agentq-requests" "$stage_home/data/agentq-requests/.locks" \
        "$stage_home/data/agentq-requests/.tombstones" "$stage_home/runtime"; do
        installer_directory_is_safe "$stage_directory" ||
            fail "staging directory is unsafe: $stage_directory"
    done
    chmod 700 "$stage_home" "$stage_home/config" "$stage_home/data" \
        "$stage_home/data/task_logs" "$stage_home/data/agentq-cancellations" \
        "$stage_home/data/agentq-requests" "$stage_home/data/agentq-requests/.locks" \
        "$stage_home/data/agentq-requests/.tombstones" \
        "$stage_home/runtime"
    find "$stage_home/data" -type d -exec chmod 700 {} \;
    find "$stage_home/data" -type f -exec chmod 600 {} \;
    chmod 700 "$stage_home/agentq-server" "$stage_home/pueue" "$stage_home/pueued"
    chmod 600 "$stage_home/config/pueue.yml"
    require_installer_tree "$stage_home" 'staging tree'
}

copy_existing_data() {
    [ "$previous_install" = true ] || return 0
    [ -d "$agentq_home/data" ] || return 0
    require_installer_tree "$agentq_home/data" 'existing AgentQ data tree'
    require_installer_tree "$stage_home/data" 'staging data tree'
    cp -R "$agentq_home/data/." "$stage_home/data/"
    require_installer_tree "$stage_home/data" 'staging data tree'
}

remove_maintenance_lock() {
    maintenance_remove_lock_path=$1
    maintenance_remove_expected_pid=${2:-}
    maintenance_remove_expected_identity=${3:-}
    maintenance_remove_pid_path=''
    maintenance_remove_status=0

    [ -n "$maintenance_remove_lock_path" ] || return 1
    if ! installer_directory_is_safe "$maintenance_remove_lock_path"; then
        printf '%s: refusing to remove an unsafe AgentQ maintenance lock: %s\n' "$program" "$maintenance_remove_lock_path" >&2
        return 2
    fi
    maintenance_remove_pid_path="$maintenance_remove_lock_path/pid"
    if [ -n "$maintenance_remove_expected_pid" ]; then
        if ! read_lock_metadata "$maintenance_remove_pid_path" ||
            [ "$lock_pid" != "$maintenance_remove_expected_pid" ] ||
            [ "$lock_identity" != "$maintenance_remove_expected_identity" ]; then
            printf '%s: AgentQ maintenance lock identity changed during cleanup: %s\n' "$program" "$maintenance_remove_lock_path" >&2
            return 2
        fi
    elif [ -e "$maintenance_remove_pid_path" ] || [ -L "$maintenance_remove_pid_path" ]; then
        if ! installer_regular_file_is_safe "$maintenance_remove_pid_path"; then
            printf '%s: refusing to remove unsafe AgentQ maintenance lock metadata: %s\n' "$program" "$maintenance_remove_pid_path" >&2
            return 2
        fi
    fi
    if [ -e "$maintenance_remove_pid_path" ] || [ -L "$maintenance_remove_pid_path" ]; then
        if remove_installer_file "$maintenance_remove_pid_path"; then
            :
        else
            maintenance_remove_status=$?
            printf '%s: failed to remove AgentQ maintenance lock metadata: %s\n' "$program" "$maintenance_remove_pid_path" >&2
            return "$maintenance_remove_status"
        fi
        if [ -e "$maintenance_remove_pid_path" ] || [ -L "$maintenance_remove_pid_path" ]; then
            printf '%s: AgentQ maintenance lock metadata remained after cleanup: %s\n' "$program" "$maintenance_remove_pid_path" >&2
            return 1
        fi
    fi
    if ! rmdir -- "$maintenance_remove_lock_path"; then
        printf '%s: failed to remove AgentQ maintenance lock directory: %s\n' "$program" "$maintenance_remove_lock_path" >&2
        return 1
    fi
    if [ -e "$maintenance_remove_lock_path" ] || [ -L "$maintenance_remove_lock_path" ]; then
        printf '%s: AgentQ maintenance lock remained after cleanup: %s\n' "$program" "$maintenance_remove_lock_path" >&2
        return 1
    fi
    return 0
}

release_maintenance_lock() {
    maintenance_release_status=0
    maintenance_release_expected_pid=''
    maintenance_release_expected_identity=''

    if [ "$maintenance_lock_held" = true ] && [ -n "$maintenance_lock" ] && [ -d "$maintenance_lock" ]; then
        if ! installer_directory_is_safe "$maintenance_lock" ||
            ! installer_path_is_safe "$maintenance_lock/pid"; then
            printf '%s: refusing to release an unsafe AgentQ maintenance lock: %s\n' "$program" "$maintenance_lock" >&2
            maintenance_release_status=2
        elif lock_is_owned_by_current_process "$maintenance_lock/pid"; then
            maintenance_release_expected_pid=$lock_pid
            maintenance_release_expected_identity=$lock_identity
            if remove_maintenance_lock "$maintenance_lock" "$maintenance_release_expected_pid" "$maintenance_release_expected_identity"; then
                :
            else
                maintenance_release_status=$?
            fi
        fi
    fi
    maintenance_lock=''
    maintenance_lock_held=false
    return "$maintenance_release_status"
}

maintenance_lock_is_stale() {
    maintenance_lock_observed_pid=''
    maintenance_lock_observed_identity=''
    [ ! -L "$maintenance_lock" ] || return 1
    [ -d "$maintenance_lock" ] || return 1
    read_lock_metadata "$maintenance_lock/pid" || return 1
    maintenance_lock_observed_pid=$lock_pid
    maintenance_lock_observed_identity=$lock_identity
    process_is_confirmed_dead "$lock_pid" "$lock_identity"
}

recover_stale_maintenance_lock() {
    if maintenance_lock_is_stale; then
        maintenance_recovery_expected_pid=$maintenance_lock_observed_pid
        maintenance_recovery_expected_identity=$maintenance_lock_observed_identity
        if ! read_lock_metadata "$maintenance_lock/pid" ||
            [ "$lock_pid" != "$maintenance_recovery_expected_pid" ] ||
            [ "$lock_identity" != "$maintenance_recovery_expected_identity" ] ||
            ! process_is_confirmed_dead "$lock_pid" "$lock_identity"; then
            fail "cannot confirm stale AgentQ maintenance lock: $maintenance_lock"
        fi
        if ! remove_maintenance_lock "$maintenance_lock" "$maintenance_recovery_expected_pid" "$maintenance_recovery_expected_identity"; then
            fail "cannot recover stale AgentQ maintenance lock: $maintenance_lock"
        fi
    fi
}

remove_stale_operation_lock() {
    operation_remove_lock_path=$1
    operation_remove_expected_pid=${2:-}
    operation_remove_expected_identity=${3:-}
    operation_remove_pid_path=''
    operation_remove_status=0

    [ -n "$operation_remove_lock_path" ] || return 1
    if ! installer_directory_is_safe "$operation_remove_lock_path"; then
        printf '%s: refusing to recover an unsafe AgentQ operation lock: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 2
    fi
    [ -n "$operation_remove_expected_pid" ] &&
        [ -n "$operation_remove_expected_identity" ] || {
        printf '%s: refusing to recover an unowned AgentQ operation lock: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 2
    }

    operation_remove_pid_path="$operation_remove_lock_path/pid"
    if ! read_lock_metadata "$operation_remove_pid_path" ||
        [ "$lock_pid" != "$operation_remove_expected_pid" ] ||
        [ "$lock_identity" != "$operation_remove_expected_identity" ]; then
        printf '%s: AgentQ operation lock identity changed during recovery: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 2
    fi
    if ! process_is_confirmed_dead "$lock_pid" "$lock_identity"; then
        printf '%s: AgentQ operation lock owner changed during recovery: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 2
    fi

    if ! installer_regular_file_is_safe "$operation_remove_pid_path"; then
        printf '%s: refusing to remove unsafe AgentQ operation lock metadata: %s\n' "$program" "$operation_remove_pid_path" >&2
        return 2
    fi
    if remove_installer_file "$operation_remove_pid_path"; then
        :
    else
        operation_remove_status=$?
        printf '%s: failed to remove AgentQ operation lock metadata: %s\n' "$program" "$operation_remove_pid_path" >&2
        return "$operation_remove_status"
    fi
    if [ -e "$operation_remove_pid_path" ] || [ -L "$operation_remove_pid_path" ]; then
        printf '%s: AgentQ operation lock metadata remained after cleanup: %s\n' "$program" "$operation_remove_pid_path" >&2
        return 1
    fi
    if ! rmdir -- "$operation_remove_lock_path"; then
        printf '%s: failed to remove AgentQ operation lock directory: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 1
    fi
    if [ -e "$operation_remove_lock_path" ] || [ -L "$operation_remove_lock_path" ]; then
        printf '%s: AgentQ operation lock remained after cleanup: %s\n' "$program" "$operation_remove_lock_path" >&2
        return 1
    fi
    return 0
}

remove_uninitialized_maintenance_lock() {
    maintenance_cleanup_lock_path=$1
    maintenance_cleanup_pid_path=''

    [ -n "$maintenance_cleanup_lock_path" ] || return 1
    if ! installer_directory_is_safe "$maintenance_cleanup_lock_path"; then
        printf '%s: refusing to clean up an unsafe AgentQ maintenance lock: %s\n' "$program" "$maintenance_cleanup_lock_path" >&2
        return 2
    fi
    maintenance_cleanup_pid_path="$maintenance_cleanup_lock_path/pid"
    if [ -e "$maintenance_cleanup_pid_path" ] || [ -L "$maintenance_cleanup_pid_path" ]; then
        printf '%s: AgentQ maintenance lock metadata appeared during initialization cleanup: %s\n' "$program" "$maintenance_cleanup_pid_path" >&2
        return 2
    fi
    if ! rmdir -- "$maintenance_cleanup_lock_path"; then
        printf '%s: failed to remove AgentQ maintenance lock after initialization failure: %s\n' "$program" "$maintenance_cleanup_lock_path" >&2
        return 1
    fi
    if [ -e "$maintenance_cleanup_lock_path" ] || [ -L "$maintenance_cleanup_lock_path" ]; then
        printf '%s: AgentQ maintenance lock remained after initialization cleanup: %s\n' "$program" "$maintenance_cleanup_lock_path" >&2
        return 1
    fi
    return 0
}

acquire_maintenance_lock() {
    maintenance_lock="${agentq_home}.maintenance.lock"
    if [ -e "$maintenance_lock" ] || [ -L "$maintenance_lock" ]; then
        [ ! -L "$maintenance_lock" ] && [ -d "$maintenance_lock" ] || fail "invalid AgentQ maintenance lock path: $maintenance_lock"
        recover_stale_maintenance_lock
    fi
    if [ -e "$maintenance_lock" ] || [ -L "$maintenance_lock" ]; then
        fail "AgentQ maintenance is already in progress: $maintenance_lock"
    fi
    if ! mkdir -- "$maintenance_lock" 2>/dev/null; then
        # NOT "already in progress": the existence check above already handled
        # that case.  Getting here means mkdir itself failed (read-only or full
        # filesystem, quota), and claiming a lock exists while `find` shows none
        # sends the operator to clean a lock that is not there (measured
        # 2026-10-06).
        fail "failed to create the AgentQ maintenance lock: $maintenance_lock"
    fi
    if ! write_lock_metadata "$maintenance_lock/pid"; then
        if ! remove_uninitialized_maintenance_lock "$maintenance_lock"; then
            fail "failed to clean up the AgentQ maintenance lock after initialization failure: $maintenance_lock"
        fi
        fail "failed to initialize the AgentQ maintenance lock: $maintenance_lock"
    fi
    maintenance_lock_held=true
}

wait_for_operation_lock() {
    operation_lock="$agentq_home/runtime/agentq-operation.lock"
    operation_lock_parent="$agentq_home/runtime"
    attempt=0

    [ ! -L "$operation_lock_parent" ] || fail "invalid AgentQ operation lock parent path: $operation_lock_parent"
    [ ! -L "$operation_lock" ] || fail "invalid AgentQ operation lock path: $operation_lock"
    while [ -d "$operation_lock" ]; do
        [ ! -L "$operation_lock_parent" ] || fail "invalid AgentQ operation lock parent path: $operation_lock_parent"
        [ ! -L "$operation_lock" ] || fail "invalid AgentQ operation lock path: $operation_lock"
        if read_lock_metadata "$operation_lock/pid"; then
            if process_is_confirmed_dead "$lock_pid" "$lock_identity"; then
                operation_lock_expected_pid=$lock_pid
                operation_lock_expected_identity=$lock_identity
                if ! remove_stale_operation_lock \
                    "$operation_lock" \
                    "$operation_lock_expected_pid" \
                    "$operation_lock_expected_identity"; then
                    fail "cannot recover stale AgentQ operation lock: $operation_lock"
                fi
                continue
            fi
        fi

        if [ "$attempt" -ge 30 ]; then
            fail "AgentQ request is still in progress; refusing to update: $operation_lock"
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
}

rollback_transaction() {
    [ "$transaction_active" = true ] || return 0
    [ "$rollback_running" = false ] || return 0

    rollback_running=true
    set +e
    printf '%s: installation failed; restoring the previous AgentQ deployment\n' "$program" >&2
    rollback_safe=true

    if [ "$candidate_installed" = true ]; then
        if ! stop_managed_daemon; then
            printf '%s: candidate AgentQ daemon could not be stopped; previous deployment will not be restored over a live process\n' "$program" >&2
            rollback_safe=false
        fi
    fi

    if [ "$rollback_safe" = true ] && [ "$candidate_installed" = true ] && { [ -e "$agentq_home" ] || [ -L "$agentq_home" ]; }; then
        if ! move_installer_tree "$agentq_home" "$failed_home" 'candidate AgentQ root'; then
            printf '%s: failed to isolate the candidate AgentQ root: %s\n' "$program" "$agentq_home" >&2
            rollback_safe=false
        elif ! failed_home_identity=$(installer_file_identity "$failed_home"); then
            printf '%s: failed to record the candidate AgentQ root identity: %s\n' "$program" "$failed_home" >&2
            rollback_safe=false
        fi
    fi

    if [ "$rollback_safe" = true ] && [ "$previous_root_moved" = true ]; then
        if ! move_installer_tree "$backup_home" "$agentq_home" 'previous AgentQ root'; then
            printf '%s: failed to restore the previous AgentQ root: %s\n' "$program" "$agentq_home" >&2
            rollback_safe=false
        else
            backup_home_identity=''
        fi
    fi

    if [ "$rollback_safe" = true ] && ! restore_service_file; then
        printf '%s: failed to restore the previous AgentQ service definition\n' "$program" >&2
        rollback_safe=false
    fi
    if [ "$rollback_safe" = true ] && ! restore_legacy_macos_service_file; then
        printf '%s: failed to restore the previous macOS LaunchAgent definition\n' "$program" >&2
        rollback_safe=false
    fi
    if [ "$rollback_safe" = true ] && ! restore_wrapper; then
        printf '%s: failed to restore the previous AgentQ wrapper\n' "$program" >&2
        rollback_safe=false
    fi

    if [ "$rollback_safe" = true ]; then
        case "$platform_kind" in
            linux)
                if ! systemctl --user daemon-reload; then
                    printf '%s: failed to reload systemd while restoring AgentQ\n' "$program" >&2
                    rollback_safe=false
                elif [ "$service_existed_before" = true ]; then
                    if ! systemctl --user enable agentq-pueued.service >/dev/null || ! systemctl --user start agentq-pueued.service; then
                        printf '%s: failed to restart the previous AgentQ systemd user service\n' "$program" >&2
                        rollback_safe=false
                    fi
                else
                    systemctl --user disable agentq-pueued.service >/dev/null 2>&1 || true
                fi
                ;;
            macos)
                if [ "$macos_service_active_before" = true ]; then
                    if ! run_launchctl bootstrap "$launch_domain" "$service_destination" || ! run_launchctl kickstart "$launch_service"; then
                        printf '%s: failed to restart the previous AgentQ launchd service\n' "$program" >&2
                        rollback_safe=false
                    fi
                fi
                if [ "$rollback_safe" = true ] && [ "$macos_legacy_service_active_before" = true ]; then
                    if ! run_macos_legacy_launchctl bootstrap "${macos_legacy_service%/com.agentq.pueued}" "$HOME/Library/LaunchAgents/com.agentq.pueued.plist" || \
                        ! run_macos_legacy_launchctl kickstart "$macos_legacy_service"; then
                        printf '%s: failed to restart the previous macOS LaunchAgent\n' "$program" >&2
                        rollback_safe=false
                    fi
                fi
                ;;
        esac
    fi

    if [ "$platform_kind" = linux ] && [ "$linux_linger_changed" = true ]; then
        if ! restore_linux_linger; then
            printf '%s: failed to restore the previous systemd user lingering state\n' "$program" >&2
            rollback_safe=false
        fi
    fi

    if [ "$rollback_safe" = true ] && [ "$previous_install" = true ] && [ "$previous_queue_verified_offline" = false ] && \
        { [ "$previous_daemon_stopped" = true ] || [ "$previous_daemon_stop_attempted" = true ]; }; then
        rollback_attempt=0
        while [ "$rollback_attempt" -lt 10 ] && ! "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" status --json >/dev/null 2>&1; do
            rollback_attempt=$((rollback_attempt + 1))
            sleep 1
        done
        if ! "$agentq_home/pueue" --config "$agentq_home/config/pueue.yml" status --json >/dev/null 2>&1; then
            printf '%s: previous AgentQ daemon did not become reachable after rollback\n' "$program" >&2
            rollback_safe=false
        fi
    fi

    transaction_active=false
    if [ "$rollback_safe" = true ]; then
        rollback_cleanup_safe=true
        if ! remove_installer_tree "$failed_home" 'failed AgentQ root' "$failed_home_identity"; then
            rollback_cleanup_safe=false
        fi
        if ! remove_installer_tree "$stage_home" 'staging root' "$stage_home_identity"; then
            rollback_cleanup_safe=false
        fi
        if [ "$rollback_cleanup_safe" = false ]; then
            preserve_recovery_artifacts=true
            printf '%s: transaction cleanup was unsafe; preserving recovery paths: %s %s\n' \
                "$program" "$failed_home" "$stage_home" >&2
        fi
    else
        preserve_recovery_artifacts=true
        printf '%s: rollback is incomplete; preserving recovery paths: %s %s %s\n' \
            "$program" "$agentq_home" "$backup_home" "$failed_home" >&2
    fi

    return 0
}

cleanup_on_exit() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    rollback_transaction
    cleanup_safe=true
    if [ -n "$service_stage" ] && ! discard_service_stage_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$service_temporary" ] && ! discard_service_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$wrapper_temporary" ] && ! discard_wrapper_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$service_restore_temporary" ] && ! discard_service_restore_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$wrapper_restore_temporary" ] && ! discard_wrapper_restore_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$binary_temporary" ] && ! discard_binary_temporary; then
        cleanup_safe=false
    fi
    if [ "$preserve_recovery_artifacts" = false ]; then
        if [ -n "$service_backup" ] && ! discard_service_backup; then
            cleanup_safe=false
        fi
        if [ -n "$wrapper_backup" ] && ! discard_wrapper_backup; then
            cleanup_safe=false
        fi
    fi
    if [ -n "$download_temporary" ] && ! discard_download_temporary; then
        cleanup_safe=false
    fi
    if [ -n "${health_temporary:-}" ] && ! discard_health_temporary; then
        cleanup_safe=false
    fi
    if [ -n "${existing_status_temporary:-}" ] && ! discard_existing_status_temporary; then
        cleanup_safe=false
    fi
    if [ -n "${group_temporary:-}" ] && ! discard_group_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$lock_metadata_temporary" ] && ! discard_lock_metadata_temporary; then
        cleanup_safe=false
    fi
    if [ -n "$stage_home" ] && ! remove_installer_tree "$stage_home" 'staging root' "$stage_home_identity"; then
        cleanup_safe=false
    fi
    if [ "$preserve_recovery_artifacts" = false ]; then
        if [ -n "$failed_home" ] && ! remove_installer_tree "$failed_home" 'failed AgentQ root' "$failed_home_identity"; then
            cleanup_safe=false
        fi
    fi
    if [ "$cleanup_safe" = false ]; then
        preserve_recovery_artifacts=true
        printf '%s: exit cleanup was unsafe; preserving recovery paths: %s %s\n' \
            "$program" "$stage_home" "$failed_home" >&2
        [ "$exit_status" -eq 0 ] && exit_status=1
    fi
    if [ "$preserve_recovery_artifacts" = false ]; then
        if ! release_maintenance_lock; then
            [ "$exit_status" -eq 0 ] && exit_status=1
        fi
    fi
    exit "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' HUP INT TERM

[ "$agentq_home" = "$HOME/.agentq" ] || fail 'AGENTQ_HOME overrides are unsupported because the bundled Pueue config is rooted at ~/.agentq'
[ ! -L "$agentq_home" ] || fail "AgentQ home must not be a symbolic link: $agentq_home"
agentq_parent=$(dirname "$agentq_home")
agentq_base=$(basename "$agentq_home")
[ "$agentq_parent" = "$HOME" ] || fail "unexpected AgentQ home parent: $agentq_parent"
installer_directory_is_safe "$agentq_parent" || fail "AgentQ transaction parent is unsafe: $agentq_parent"
# W5: refuse BEFORE taking the lock or staging anything when a previous run left
# transaction residue beside the root -- see assert_no_crash_leftover_transactions.
assert_no_crash_leftover_transactions

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        pueue_asset='pueue-x86_64-unknown-linux-musl'
        pueue_sha256='c1b10d7e4e62211075ddd0e1dc3e8cbfc5a43d662cb3be7402a28504e23fcb51'
        pueued_asset='pueued-x86_64-unknown-linux-musl'
        pueued_sha256='5afeff6adbafb909e8d54e2caff158e6966c2adffa2c09e60fd631cc51b60390'
        platform_kind=linux
        ;;
    Linux:aarch64|Linux:arm64)
        pueue_asset='pueue-aarch64-unknown-linux-musl'
        pueue_sha256='759bf5100a51024997111c6913aaf3330a0cdfd893ff552dcf429ae9b5e01e09'
        pueued_asset='pueued-aarch64-unknown-linux-musl'
        pueued_sha256='332c5ef74270b64aeaf04894c8c04826f3422eb7d50dbd1a8e0706d74a42f653'
        platform_kind=linux
        ;;
    Darwin:x86_64)
        pueue_asset='pueue-x86_64-apple-darwin'
        pueue_sha256='c5b89a2f9f9d355b33880735a1f12a8b8d09002f95cc7d2e5f3294e313fb8540'
        pueued_asset='pueued-x86_64-apple-darwin'
        pueued_sha256='4de7c4790989198007c6c0789c56606237d0456a2ce3666b5a0b198478c06263'
        platform_kind=macos
        ;;
    Darwin:arm64)
        pueue_asset='pueue-aarch64-apple-darwin'
        pueue_sha256='7780dbd21e3a4106e88a57396d6dc2dbcbbae253c7e00d92d994902896b8cb82'
        pueued_asset='pueued-aarch64-apple-darwin'
        pueued_sha256='bf5a1151d70c328dd036fb6d786fba53a68d8574c12391d04db3d08b04079205'
        platform_kind=macos
        ;;
    *)
        fail "unsupported platform: $(uname -s) $(uname -m)"
        ;;
esac

require_file "$asset_directory/agentq-server"
require_file "$asset_directory/pueue.yml"
require_file "$asset_directory/agentq"

case "$platform_kind" in
    linux)
        require_file "$asset_directory/agentq-pueued.service"
        ;;
    macos)
        require_file "$asset_directory/com.agentq.pueued.plist"
        require_file "$asset_directory/com.agentq.pueued.daemon.plist"
        ;;
esac

if [ -n "$artifact_source_directory" ]; then
    [ -d "$artifact_source_directory" ] || fail "AGENTQ_PUEUE_SOURCE_DIR is not a directory: $artifact_source_directory"
fi

detect_package_manager
ensure_dependency jq jq
ensure_dependency base64 coreutils
ensure_dependency perl perl
if [ -z "$artifact_source_directory" ]; then
    ensure_dependency curl curl
fi
for required_command in awk cp chmod date dirname find grep head id mkdir mktemp mv ps rm rmdir sed stat tail tr wc; do
    require_command "$required_command"
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    install_package coreutils
fi
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    fail 'sha256sum or shasum is required'
fi
[ -x /bin/bash ] || fail '/bin/bash is required by the bundled Pueue configuration'

case "$platform_kind" in
    linux)
        require_command systemctl
        require_command loginctl
        ensure_wsl_systemd_user_runtime
        ;;
    macos)
        require_command launchctl
        require_command plutil
        require_command chown
        ;;
esac

umask 077
acquire_maintenance_lock
if [ -e "$agentq_home" ]; then
    wait_for_operation_lock
fi
authorize_macos_root
bootstrap_existing_macos_service
assert_existing_queue_has_no_active_tasks
if [ "$previous_install" = false ] && { [ -e "$wrapper_destination" ] || [ -L "$wrapper_destination" ]; }; then
    fail "refuse to overwrite an existing wrapper without an AgentQ installation: $wrapper_destination"
fi
# All three are created by a later operation -- mkdir for the staging root, and
# a rename for the other two -- and each of those already fails rather than
# reusing whatever is at the final component, so an unpredictable name is all
# these need.
stage_home=$(create_installer_temporary_name "$agentq_parent" ".${agentq_base}.stage") ||
    fail "failed to reserve the AgentQ staging path in: $agentq_parent"
backup_home=$(create_installer_temporary_name "$agentq_parent" ".${agentq_base}.backup") ||
    fail "failed to reserve the AgentQ backup path in: $agentq_parent"
failed_home=$(create_installer_temporary_name "$agentq_parent" ".${agentq_base}.failed") ||
    fail "failed to reserve the AgentQ failed-installation path in: $agentq_parent"
require_installer_absent_path "$stage_home" 'staging path'
require_installer_absent_path "$backup_home" 'backup path'
require_installer_absent_path "$failed_home" 'failed-installation path'

mkdir "$stage_home"
require_installer_tree "$stage_home" 'staging root'
if ! stage_home_identity=$(installer_file_identity "$stage_home"); then
    fail "failed to record the staging root identity: $stage_home"
fi
mkdir -p "$stage_home/config" "$stage_home/data/task_logs" \
    "$stage_home/data/agentq-cancellations" "$stage_home/data/agentq-requests/.locks" \
    "$stage_home/data/agentq-requests/.tombstones" \
    "$stage_home/runtime"
cp "$asset_directory/agentq-server" "$stage_home/agentq-server"
cp "$asset_directory/pueue.yml" "$stage_home/config/pueue.yml"

release_base="https://github.com/Nukesor/pueue/releases/download/v${release_version}"
stage_verified_binary "$stage_home/pueue" "$pueue_asset" "$release_base/$pueue_asset" "$pueue_sha256" "$agentq_home/pueue"
stage_verified_binary "$stage_home/pueued" "$pueued_asset" "$release_base/$pueued_asset" "$pueued_sha256" "$agentq_home/pueued"

bash -n "$stage_home/agentq-server"
"$stage_home/pueue" --version >/dev/null
"$stage_home/pueued" --version >/dev/null
prepare_service_stage

transaction_active=true
if [ "$previous_install" = true ]; then
    previous_daemon_stop_attempted=true
fi
if ! stop_managed_daemon; then
    fail 'existing AgentQ daemon did not stop; refusing to replace a live deployment'
fi
retire_legacy_macos_service_file
if [ "$previous_install" = true ]; then
    previous_daemon_stopped=true
fi
copy_existing_data
secure_stage_tree

if [ "$previous_install" = true ]; then
    if ! move_installer_tree "$agentq_home" "$backup_home" 'previous AgentQ root'; then
        fail 'failed to move the previous AgentQ root into the transaction backup'
    fi
    if ! backup_home_identity=$(installer_file_identity "$backup_home"); then
        fail "failed to record the transaction backup identity: $backup_home"
    fi
    previous_root_moved=true
fi
if ! move_installer_tree "$stage_home" "$agentq_home" 'staging AgentQ root'; then
    fail 'failed to install the staged AgentQ root'
fi
stage_home=''
stage_home_identity=''
candidate_installed=true

replace_wrapper
replace_service_file

if [ "$platform_kind" = linux ]; then
    ensure_linux_linger
fi
start_managed_daemon
wait_for_daemon
ensure_agentq_group
verify_health_status

transaction_active=false
if ! remove_installer_tree "$backup_home" 'backup AgentQ root' "$backup_home_identity"; then
    preserve_recovery_artifacts=true
    fail "backup AgentQ root cleanup was unsafe; preserving recovery path: $backup_home"
fi
if [ -n "$service_backup" ] && ! discard_service_backup; then
    preserve_recovery_artifacts=true
    fail "service backup cleanup was unsafe; preserving recovery path: $service_backup"
fi
if [ -n "$wrapper_backup" ] && ! discard_wrapper_backup; then
    preserve_recovery_artifacts=true
    fail "wrapper backup cleanup was unsafe; preserving recovery path: $wrapper_backup"
fi
if [ -n "$service_temporary" ] && ! discard_service_temporary; then
    preserve_recovery_artifacts=true
    fail "service temporary cleanup was unsafe; preserving recovery path: $service_temporary"
fi
if [ -n "$wrapper_temporary" ] && ! discard_wrapper_temporary; then
    preserve_recovery_artifacts=true
    fail "wrapper temporary cleanup was unsafe; preserving recovery path: $wrapper_temporary"
fi
if [ -n "$service_restore_temporary" ] && ! discard_service_restore_temporary; then
    preserve_recovery_artifacts=true
    fail "service restore temporary cleanup was unsafe; preserving recovery path: $service_restore_temporary"
fi
if [ -n "$wrapper_restore_temporary" ] && ! discard_wrapper_restore_temporary; then
    preserve_recovery_artifacts=true
    fail "wrapper restore temporary cleanup was unsafe; preserving recovery path: $wrapper_restore_temporary"
fi
if [ -n "$binary_temporary" ] && ! discard_binary_temporary; then
    preserve_recovery_artifacts=true
    fail "binary temporary cleanup was unsafe; preserving recovery path: $binary_temporary"
fi
if [ -n "$service_stage" ] && ! discard_service_stage_temporary; then
    preserve_recovery_artifacts=true
    fail "service staging cleanup was unsafe; preserving recovery path: $service_stage"
fi
backup_home=''
backup_home_identity=''
failed_home=''
failed_home_identity=''
service_backup=''
service_backup_identity=''
wrapper_backup=''
wrapper_backup_identity=''
service_stage=''
service_stage_identity=''
service_temporary=''
service_temporary_identity=''
wrapper_temporary=''
wrapper_temporary_identity=''
service_restore_temporary=''
service_restore_temporary_identity=''
wrapper_restore_temporary=''
wrapper_restore_temporary_identity=''
binary_temporary=''
binary_temporary_identity=''
health_temporary=''
health_temporary_identity=''
existing_status_temporary=''
existing_status_temporary_identity=''
group_temporary=''
group_temporary_identity=''

printf '%s\n' "AgentQ ${release_version} installed at $agentq_home"
