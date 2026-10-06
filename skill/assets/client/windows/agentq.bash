#!/usr/bin/env bash

set -euo pipefail

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
powershell_script=$(cygpath -aw "$script_directory/agentq.ps1")

if [[ ${AGENTQ_SSH:-} == /* ]]; then
    export AGENTQ_SSH
    AGENTQ_SSH=$(cygpath -aw "$AGENTQ_SSH")
fi
if [[ ${AGENTQ_CONFIG:-} == /* ]]; then
    export AGENTQ_CONFIG
    AGENTQ_CONFIG=$(cygpath -aw "$AGENTQ_CONFIG")
fi
if [[ ${AGENTQ_ASKPASS:-} == /* ]]; then
    export AGENTQ_ASKPASS
    AGENTQ_ASKPASS=$(cygpath -aw "$AGENTQ_ASKPASS")
fi

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$powershell_script" "$@"
