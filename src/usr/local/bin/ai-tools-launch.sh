#!/usr/bin/bash -p
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/ai-tools-launch
# The launch wrapper every agent's command runs. Each agent package ships /usr/local/bin/<launcher> as a symlink to this
# file, and the launcher name it was invoked as ($0) selects the agent. It runs as the invoking operator: it loads
# the launch checks (launch-wrapper.lib.sh), refuses when they cannot be loaded, and hands them the name and
# the arguments; they end by executing the confinement shim /opt/ai-tools/bin/ai-tools-run as the sandbox account
# through sudo, which is where privilege changes. Shipped 0755 root:root by ai-tools-base. The launch sequence is
# in launch.rule.md.
#
# The script runs in the operator's own environment, so it takes none of that environment's code. The interpreter is
# named by absolute path rather than found through PATH, and `-p` (privileged mode) stops bash from sourcing
# $BASH_ENV/$ENV and importing exported functions at startup, which would otherwise replace a command the gates run.
# PATH is pinned to the root-owned system directories, so sudo, id, readlink and logger resolve there whatever
# the caller's PATH holds; ai-tools-run pins the session's own PATH after the drop. The script writes no file,
# so it leaves the operator's umask alone.

set -euo pipefail
IFS=$'\n\t'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
export PATH

readonly LAUNCH_LIB="/usr/local/lib/ai-tools/launch-wrapper.lib.sh"

# refuse_early <code> <line>... -- the refusal for the one state no library can report: the gate library itself will not
# load. The code on its own line, then the message, the shape msg.lib.sh's plain mode takes. It names this program rather
# than the launcher it was invoked as, since the name is validated by the library that did not load.
refuse_early() {
    printf '%s\n' "$1" >&2
    printf 'ai-tools-launch: %s\n' "$2" >&2
    printf '%s\n' "${@:3}" >&2
    exit 1
}

# Load the launch gates and FAIL CLOSED if they are unreachable: the library carries every gate and the exec, and
# a launch that ran on without it would start with every gate off. The functions verified are the ones this file calls.
# Logs to journald through logger, since the library that carries the logger may share the broken directory.
# shellcheck source=SCRIPTDIR/../lib/ai-tools/launch-wrapper.lib.sh
if ! source "${LAUNCH_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_launch_init       >/dev/null 2>&1 \
        || ! declare -F ai_tools_launch_gates      >/dev/null 2>&1 \
        || ! declare -F ai_tools_launch_agent_args >/dev/null 2>&1 \
        || ! declare -F ai_tools_launch_session    >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t ai-tools-launch -p user.err \
            "required library ${LAUNCH_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
    refuse_early MSG-R3Q4 "cannot load the launch gate library -- refusing to start" \
        "       ${LAUNCH_LIB}" \
        "       the install is incomplete or /usr/local/lib/ai-tools is not traversable;" \
        "       reinstall ai-tools, then retry"
fi

# The name this program was invoked as is the launcher; the library admits it and matches it to an enabled agent.
ai_tools_launch_init "${0##*/}"
ai_tools_launch_gates "$@"

# The agent's own launch arguments precede the operator's, so a standing input from operator.conf (claude's custom
# system prompt) sits before what was typed for this invocation. The ${arr[@]+"..."} form expands to no word at all
# when the array is empty, which is safe under `set -u`.
declare -a agent_args=()
ai_tools_launch_agent_args agent_args "$@"
ai_tools_launch_session ${agent_args[@]+"${agent_args[@]}"} "$@"
