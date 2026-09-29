#!/bin/sh

set -eu

program=${0##*/}
script_directory=$(unset CDPATH; cd "$(dirname "$0")" && pwd -P)
destination_directory=${AGENTQ_CLIENT_BIN_DIR:-"$HOME/.local/bin"}
temporary_path=''
check_only=false

usage() {
    cat <<EOF
Usage: $program [--check] [--bin-dir <directory>]

Install the POSIX AgentQ and sshp clients for the current user.

With --check, verify that both destination clients match the canonical assets
without creating, replacing, or removing any file.
EOF
}

fail() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 2
}

require_safe_path() {
    case "$1" in
        -*) fail "path must not begin with a hyphen: $1" ;;
    esac
}

path_chain_is_safe() {
    guard_path=$1
    case "$guard_path" in
        '') return 1 ;;
    esac
    case "/$guard_path/" in
        */../*) return 1 ;;
    esac

    guard_probe='.'
    guard_remaining=$guard_path
    case "$guard_remaining" in
        /*)
            guard_probe=/
            guard_remaining=${guard_remaining#/}
            ;;
    esac

    while [ -n "$guard_remaining" ]; do
        case "$guard_remaining" in
            */*)
                guard_component=${guard_remaining%%/*}
                guard_remaining=${guard_remaining#*/}
                ;;
            *)
                guard_component=$guard_remaining
                guard_remaining=''
                ;;
        esac
        [ -n "$guard_component" ] || continue
        [ "$guard_component" = . ] && continue
        if [ "$guard_probe" = / ]; then
            guard_probe=/$guard_component
        else
            guard_probe=$guard_probe/$guard_component
        fi
        [ ! -L "$guard_probe" ] || return 1
    done
}

assert_no_symlink_path_chain() {
    guard_path=$1
    guard_description=$2
    case "$guard_path" in
        '') fail "$guard_description cannot be empty" ;;
    esac
    case "/$guard_path/" in
        */../*) fail "$guard_description must not contain parent traversal: $guard_path" ;;
    esac
    path_chain_is_safe "$guard_path" || fail "$guard_description contains a symbolic link: $guard_path"
}

assert_regular_directory_path() {
    directory_path=$1
    directory_description=$2
    assert_no_symlink_path_chain "$directory_path" "$directory_description"
    [ -d "$directory_path" ] || fail "$directory_description is not a directory: $directory_path"
}

assert_regular_file_path() {
    file_path=$1
    file_description=$2
    assert_no_symlink_path_chain "$file_path" "$file_description"
    if [ -e "$file_path" ] && [ ! -f "$file_path" ]; then
        fail "$file_description is not a regular file: $file_path"
    fi
}

move_client_file() {
    client_move_source=$1
    client_move_destination=$2
    client_move_description=${3:-client file}

    if [ ! -f "$client_move_source" ] || [ -L "$client_move_source" ] ||
        ! path_chain_is_safe "$client_move_source"; then
        printf '%s: %s source is unsafe or missing: %s\n' \
            "$program" "$client_move_description" "$client_move_source" >&2
        return 1
    fi
    if ! path_chain_is_safe "$client_move_destination" ||
        { [ -e "$client_move_destination" ] && [ ! -f "$client_move_destination" ]; }; then
        printf '%s: %s destination is unsafe or not a regular file: %s\n' \
            "$program" "$client_move_description" "$client_move_destination" >&2
        return 1
    fi
    if ! mv -f -- "$client_move_source" "$client_move_destination"; then
        printf '%s: failed to move %s: %s -> %s\n' \
            "$program" "$client_move_description" "$client_move_source" "$client_move_destination" >&2
        return 1
    fi
    if [ ! -f "$client_move_destination" ] || [ -L "$client_move_destination" ] ||
        ! path_chain_is_safe "$client_move_destination" ||
        [ -e "$client_move_source" ] || [ -L "$client_move_source" ]; then
        printf '%s: %s move identity check failed: %s -> %s\n' \
            "$program" "$client_move_description" "$client_move_source" "$client_move_destination" >&2
        return 1
    fi
}

remove_client_file() {
    client_remove_path=$1
    client_remove_description=${2:-temporary client path}

    [ -n "$client_remove_path" ] || return 0
    if [ ! -e "$client_remove_path" ] && [ ! -L "$client_remove_path" ]; then
        return 0
    fi
    if ! path_chain_is_safe "$client_remove_path" ||
        [ ! -f "$client_remove_path" ] || [ -L "$client_remove_path" ]; then
        printf '%s: %s is unsafe; preserving it: %s\n' \
            "$program" "$client_remove_description" "$client_remove_path" >&2
        return 1
    fi
    if ! rm -f -- "$client_remove_path"; then
        printf '%s: %s cleanup failed; preserving it: %s\n' \
            "$program" "$client_remove_description" "$client_remove_path" >&2
        return 1
    fi
    if [ -e "$client_remove_path" ] || [ -L "$client_remove_path" ]; then
        printf '%s: %s remained after cleanup; preserving it: %s\n' \
            "$program" "$client_remove_description" "$client_remove_path" >&2
        return 1
    fi
}

cleanup_on_exit() {
    client_exit_status=$?
    trap - EXIT HUP INT TERM
    client_cleanup_safe=true
    if [ -n "$temporary_path" ] && ! remove_client_file "$temporary_path"; then
        client_cleanup_safe=false
    fi
    if [ "$client_cleanup_safe" = false ] && [ "$client_exit_status" -eq 0 ]; then
        client_exit_status=1
    fi
    exit "$client_exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            check_only=true
            shift
            ;;
        --bin-dir)
            [ "$#" -ge 2 ] || fail '--bin-dir requires a directory'
            destination_directory=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

case "$destination_directory" in
    '') fail 'destination directory cannot be empty' ;;
esac
require_safe_path "$destination_directory"
assert_no_symlink_path_chain "$destination_directory" 'destination directory'

for client in agentq sshp; do
    source_path="$script_directory/$client"
    [ -f "$source_path" ] || fail "client asset is missing: $source_path"
    [ -x "$source_path" ] || fail "client asset is not executable: $source_path"
done

if [ "$check_only" = true ]; then
    assert_regular_directory_path "$destination_directory" 'destination directory'
    client_drift_found=false
    for client in agentq sshp; do
        source_path="$script_directory/$client"
        destination_path="$destination_directory/$client"
        assert_regular_file_path "$destination_path" 'client destination path'
        if [ ! -f "$destination_path" ]; then
            printf '%s: client is missing from destination: %s\n' "$program" "$client" >&2
            client_drift_found=true
        elif ! cmp -s "$source_path" "$destination_path"; then
            printf '%s: client does not match canonical asset: %s\n' "$program" "$client" >&2
            client_drift_found=true
        fi
    done
    if [ "$client_drift_found" = true ]; then
        exit 1
    fi
    printf '%s\n' "AgentQ clients match canonical assets in $destination_directory"
    exit 0
fi

umask 077
mkdir -p "$destination_directory" || fail "cannot create destination directory: $destination_directory"
assert_regular_directory_path "$destination_directory" 'destination directory'

for client in agentq sshp; do
    source_path="$script_directory/$client"
    temporary_path=$(mktemp "$destination_directory/.${client}.new.XXXXXX") || fail "cannot create temporary client path: $client"
    destination_path="$destination_directory/$client"

    assert_regular_file_path "$temporary_path" 'temporary client path'
    assert_regular_file_path "$destination_path" 'client destination path'
    cp "$source_path" "$temporary_path" || fail "cannot stage client: $client"
    assert_regular_file_path "$temporary_path" 'temporary client path'
    chmod 700 "$temporary_path" || fail "cannot set executable mode: $temporary_path"
    assert_regular_directory_path "$destination_directory" 'destination directory'
    assert_regular_file_path "$temporary_path" 'temporary client path'
    assert_regular_file_path "$destination_path" 'client destination path'
    move_client_file "$temporary_path" "$destination_path" 'client' ||
        fail "cannot install client: $destination_path"
    temporary_path=''
done

printf '%s\n' "installed AgentQ clients in $destination_directory"
