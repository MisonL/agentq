#!/usr/bin/env bash

set -euo pipefail

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
powershell_script=$(cygpath -aw "$script_directory/sshp.ps1")

if [[ ${SSHP_SSH:-} == /* ]]; then
    export SSHP_SSH
    SSHP_SSH=$(cygpath -aw "$SSHP_SSH")
fi

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$powershell_script" "$@"
