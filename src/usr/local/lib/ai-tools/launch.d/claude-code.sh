# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/launch.d/claude-code.sh
# Claude Code's launch hook: adds the custom system prompt that operator.conf configures (CLAUDE_SYSTEM_PROMPT_FILE)
# to every claude launch, through claude-prompt.lib.sh. ai-tools-launch sources it because the claude-code manifest
# declares launch_hook=yes.
#
# A custom prompt is not confinement, so a host that configures none launches normally even when the resolver library
# is missing; a host that configures one refuses the launch instead of falling back to Claude Code's default prompt.
# What a configured prompt must satisfy is in agent-claude-code.rule.md.

readonly CLAUDE_PROMPT_LIB="/usr/local/lib/ai-tools/claude-prompt.lib.sh"

# ai_tools_launch_hook_args <array> <arg>... -- append the custom-system-prompt arguments to the array named <array>, or
# refuse through ai_tools_launch_die. None are appended when no prompt is configured, or when the operator passed
# a system-prompt flag for this invocation.
ai_tools_launch_hook_args() {
    local array_name="$1"; shift
    # shellcheck source=SCRIPTDIR/../claude-prompt.lib.sh
    if ! source "${CLAUDE_PROMPT_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_claude_resolve_prompt_args >/dev/null 2>&1; then
        command -v logger >/dev/null 2>&1 \
            && logger -t claude -p user.warning \
                "custom-system-prompt library ${CLAUDE_PROMPT_LIB} unavailable for $(id -un 2>/dev/null)"
        if ai_tools_conf_read "${OPERATOR_CONF}" CLAUDE_SYSTEM_PROMPT_FILE 2>/dev/null \
                && [[ -n "${_ai_tools_conf_value}" ]]; then
            ai_tools_launch_die MSG-U9G5 "a custom system prompt is configured but its resolver library is unavailable" \
                "       ${CLAUDE_PROMPT_LIB}" \
                "       refusing to launch rather than ignore the configured prompt -- reinstall ai-tools"
        fi
        return 0
    fi
    if ! ai_tools_claude_resolve_prompt_args "${array_name}" "${OPERATOR_CONF}" "$@"; then
        ai_tools_launch_die MSG-A3U4 "a custom system prompt is configured but cannot be applied -- refusing to launch" \
            "       see the warning above; fix CLAUDE_SYSTEM_PROMPT_FILE / CLAUDE_SYSTEM_PROMPT_MODE" \
            "       in ${OPERATOR_CONF}, or comment the keys out to use Claude Code's default prompt"
    fi
}
