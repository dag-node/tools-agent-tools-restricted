#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/codex
# Sandboxed codex wrapper. Ships system-wide (root:root 0755, rpm-owned) and runs as the invoking operator. It is
# the shared gate library alone: launch-wrapper.lib.sh refuses a non-operator (not in the ai-ops group) up front
# with a framed refusal, resolves the current versioned codex launcher under /opt/ai-tools via the stable symlink
# maintained by nvm-update.sh, gates the CWD on the allowlist and the claim, and re-executes the shared confinement shim
# /opt/ai-tools/bin/ai-tools-run as the sandbox account (SANDBOX_USER) via sudo with the resolved path
# in AI_TOOLS_AGENT_EXEC. ai-tools-run resolves this agent from its manifest, re-validates the path, and wraps
# the session in a systemd transient service before exec'ing the versioned launcher, which the toolchain has re-linked
# at the vendor binary the manifest names (launcher_target). path-order.sh (wired into operator dotfiles
# by ai-tools-admin) ranks /usr/local/bin (Tier 1) ahead of the nvm shims and the system directories, so this shadows
# any other codex on an operator's PATH. Codex does not take a launch input from operator.conf: a custom system prompt
# and a custom endpoint are keys of /etc/codex/managed_config.toml, which codex reads itself. The gate order,
# and what each refusal distinguishes, are in agent-codex.rule.md.

set -euo pipefail
IFS=$'\n\t'

readonly LAUNCH_LIB="/usr/local/lib/ai-tools/launch-wrapper.lib.sh"

# refuse_early <line>... -- the refusal for the one state no library can report: the gate library itself will not load.
# Prints the code on its own line, then the message, the shape msg.lib.sh's plain mode takes. The code is the one
# claude's wrapper defines for the same situation (MSG-R3Q4): one situation, two wrappers, one token to search.
refuse_early() {
    printf '%s\n' "MSG-R3Q4" "$@" >&2
    exit 1
}

# Load the launch gates and FAIL CLOSED if they are unreachable. The library carries the operator gate, the launcher
# resolution, the allowlist, the claim guard and the exec, and it requires msg.lib.sh, safe-paths.lib.sh and conf.lib.sh
# in turn (ai_tools_launch_init); a wrapper that ran on without it would launch with every gate off. The three functions
# verified are the ones this file calls. Logs to journald (via logger, since the wrapper does not source log.lib and it
# may share the broken dir) for the audit trail, then refuses in the plain form.
# shellcheck source=SCRIPTDIR/../lib/ai-tools/launch-wrapper.lib.sh
if ! source "${LAUNCH_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_launch_init    >/dev/null 2>&1 \
        || ! declare -F ai_tools_launch_gates   >/dev/null 2>&1 \
        || ! declare -F ai_tools_launch_session >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t codex-wrapper -p user.err \
            "required library ${LAUNCH_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
    refuse_early "codex: cannot load the launch gate library -- refusing to start" \
        "       ${LAUNCH_LIB}" \
        "       the install is incomplete or /usr/local/lib/ai-tools is not traversable;" \
        "       reinstall ai-tools, then retry"
fi
ai_tools_launch_init codex

# The gates, in the library's order: operator, launcher resolution, the print-and-exit short-circuit (which execs a sole
# `--version`/`--help` here and returns otherwise), the protected-paths backstop and the allowlist on the CWD, the claim
# guard. Each refuses before the next can matter.
ai_tools_launch_gates "$@"

# No launch input of this agent's sits between the gates and the session: the operator's arguments go through as typed.
ai_tools_launch_session "$@"
