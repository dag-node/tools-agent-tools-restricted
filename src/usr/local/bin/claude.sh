#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/claude
# Sandboxed claude wrapper. Ships system-wide (root:root 0755, rpm-owned) and runs as the invoking operator. The gates
# are launch-wrapper.lib.sh's, shared by every agent's wrapper: it refuses a non-operator (not in the ai-ops group)
# up front with a framed refusal, resolves the current versioned claude binary under /opt/ai-tools via the stable
# symlink maintained by nvm-update.sh, gates the CWD on the allowlist and the claim, and re-executes the shared
# confinement shim /opt/ai-tools/bin/ai-tools-run as the sandbox account (SANDBOX_USER) via sudo with the resolved path
# in AI_TOOLS_AGENT_EXEC. ai-tools-run resolves this agent from its manifest, re-validates the path, and wraps
# the session in a systemd transient service before exec'ing the versioned binary. path-order.sh (wired into operator
# dotfiles by ai-tools-admin) ranks /usr/local/bin (Tier 1) ahead of the nvm shims, so this shadows any nvm-managed
# claude on an operator's PATH. What this file adds is the one claude-code launch input: when operator.conf configures
# a custom system prompt, it prepends the resolved `--append-system-prompt-file` / `--system-prompt-file` arguments
# (claude-prompt.lib.sh) ahead of the operator's own, and a configured but unhonourable prompt refuses the launch (fail
# closed). The gate order, and what each refusal distinguishes, are in agent-claude-code.rule.md.

set -euo pipefail
IFS=$'\n\t'

readonly LAUNCH_LIB="/usr/local/lib/ai-tools/launch-wrapper.lib.sh"

# refuse_early <code> <line>... -- the refusal for the one state no library can report: the gate library itself will not
# load. Prints the code on its own line, then the message, the shape msg.lib.sh's plain mode takes (a leading code is
# matched inline here because the library that carries the matcher is not loaded yet).
refuse_early() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf '%s\n' "$@" >&2
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
        && logger -t claude-wrapper -p user.err \
            "required library ${LAUNCH_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
    refuse_early MSG-R3Q4 "claude: cannot load the launch gate library -- refusing to start" \
        "       ${LAUNCH_LIB}" \
        "       the install is incomplete or /usr/local/lib/ai-tools is not traversable;" \
        "       reinstall ai-tools, then retry"
fi
ai_tools_launch_init claude

# die [<code>] <line>... -- this file's refusals take the library's: the first line prefixed `claude: `, framed
# by ai_tools_msg_error, paused on a tty, exit 1.
die() { ai_tools_launch_die "$@"; }

# Custom system prompt resolver (claude-prompt.lib.sh). Resolves the operator-configured `--append-system-prompt-file` /
# `--system-prompt-file` launch arguments from operator.conf. Loaded here; APPLIED after the gates. This input is not
# confinement, so a host that configures NO custom prompt launches normally even if this lib is missing -- but a host
# that HAS one configured must not silently fall back to Claude Code's default prompt, so a missing lib fails the launch
# CLOSED only in that case (handled at the resolution block, which detects a configured prompt via the already-required
# conf.lib). The load itself is therefore best-effort and only logged; the fail-closed decision is made
# where the configuration is known.
readonly CLAUDE_PROMPT_LIB="/usr/local/lib/ai-tools/claude-prompt.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/claude-prompt.lib.sh
if ! source "${CLAUDE_PROMPT_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_claude_resolve_prompt_args >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t claude -p user.warning \
            "custom-system-prompt library ${CLAUDE_PROMPT_LIB} unavailable for $(id -un 2>/dev/null)"
fi

# The gates, in the library's order: operator, launcher resolution, the print-and-exit short-circuit (which execs a sole
# `--version`/`--help` here and returns otherwise), the protected-paths backstop and the allowlist on the CWD, the claim
# guard. Each refuses before the next can matter.
ai_tools_launch_gates "$@"

# Resolve any operator-configured custom system prompt into launch arguments (empty when none is configured
# or when the operator passed a system-prompt flag for this invocation). This is not confinement, so an UNCONFIGURED
# host proceeds untouched -- but a CONFIGURED prompt that cannot be honoured refuses the launch (fail closed) rather
# than run with a prompt the operator did not set.
declare -a prompt_args=()
if declare -F ai_tools_claude_resolve_prompt_args >/dev/null 2>&1; then
    if ! ai_tools_claude_resolve_prompt_args prompt_args "${OPERATOR_CONF}" "$@"; then
        die "a custom system prompt is configured but cannot be applied -- refusing to launch" \
            "       see the warning above; fix CLAUDE_SYSTEM_PROMPT_FILE / CLAUDE_SYSTEM_PROMPT_MODE" \
            "       in ${OPERATOR_CONF}, or comment the keys out to use Claude Code's default prompt"
    fi
else
    # The resolver lib did not load. An unconfigured host launches normally; a configured one must not silently drop its
    # prompt, so refuse when CLAUDE_SYSTEM_PROMPT_FILE is set and non-empty.
    if ai_tools_conf_read "${OPERATOR_CONF}" CLAUDE_SYSTEM_PROMPT_FILE 2>/dev/null \
            && [[ -n "${_ai_tools_conf_value}" ]]; then
        die "a custom system prompt is configured but its resolver library is unavailable" \
            "       ${CLAUDE_PROMPT_LIB}" \
            "       refusing to launch rather than ignore the configured prompt -- reinstall ai-tools"
    fi
fi

# prompt_args (if any) precede "$@": the operator.conf-sourced flag sits before the operator's own arguments.
# A per-invocation system-prompt flag is detected earlier and suppresses prompt_args, so the two never collide here.
# The ${arr[@]+"..."} form expands to no word at all (not an empty word) when prompt_args is empty, safe under `set -u`.
ai_tools_launch_session ${prompt_args[@]+"${prompt_args[@]}"} "$@"
