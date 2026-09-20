# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/claude-code.env.sh
# Session environment for the claude-code agent that reaches claude-code sessions ALONE: the custom API endpoint (a
# bearer token among its options) and the custom system prompt check. ai-tools-run sources this last, after every
# enabled integration and after every enabled agent's pins, and only when claude-code is the agent being launched --
# a codex session under the same account never sources it, so the endpoint token stays in claude-code sessions. The pins
# every session of the account carries (CLAUDE_CONFIG_DIR, NODE_COMPILE_CACHE, DISABLE_AUTOUPDATER) are
# claude-code.pins.env.sh, beside this file.
#
# Fragment contract (see providers.rule.md): append to session_environment_options and session_path_entries, unset your
# own temporaries, and do not exec, prompt, or read stdin. This fragment additionally EXPORTS ANTHROPIC_AUTH_TOKEN
# when a custom endpoint supplies one (the credential-off-cmdline pattern) -- the one sanctioned caller-environment
# mutation, so the paired name-only `--setenv` imports it without the value reaching any command line.
# shellcheck disable=SC2154  # both arrays belong to the sourcing launcher

# Custom API endpoint (operator.conf CLAUDE_BASE_URL_FILE -> /etc/ai-tools/endpoints/<file>). Routes the session
# at a non-default ANTHROPIC_BASE_URL with its auth token and model labels. Only valid, uncommented options are
# injected; a configured-but-invalid option REFUSES the launch (exit 1) rather than route the session partially
# or wrongly -- this fragment is sourced in ai-tools-run's own shell before the unit is created
# and before the session-end sweep trap, so exiting here is a clean fail-closed with no session started. The token is
# imported by name (value off the command line). See claude-endpoint.lib.sh and providers.rule.md.
# shellcheck source=/dev/null
if source /usr/local/lib/ai-tools/claude-endpoint.lib.sh 2>/dev/null \
        && declare -F ai_tools_claude_resolve_endpoint_setenv >/dev/null 2>&1; then
    if ! ai_tools_claude_resolve_endpoint_setenv session_environment_options /etc/ai-tools/operator.conf; then
        ai_tools_msg_error \
            "ai-tools-run: a custom Claude Code endpoint is configured but has an invalid option --" \
            "refusing to launch (see the warning above). Fix the file named by CLAUDE_BASE_URL_FILE" \
            "in /etc/ai-tools/operator.conf, or comment CLAUDE_BASE_URL_FILE out to use the default."
        exit 1
    fi
elif ai_tools_conf_read /etc/ai-tools/operator.conf CLAUDE_BASE_URL_FILE 2>/dev/null \
        && [[ -n "${_ai_tools_conf_value}" ]]; then
    # The resolver lib did not load but an endpoint IS configured: refuse rather than route the session at the default
    # endpoint the operator did not ask for (same fail-closed-when-configured posture the custom system prompt takes
    # in claude.sh).
    ai_tools_msg_error \
        "ai-tools-run: a custom Claude Code endpoint is configured but its resolver library is" \
        "unavailable -- refusing to launch rather than ignore it. Reinstall ai-tools."
    exit 1
fi

# Custom system prompt (operator.conf CLAUDE_SYSTEM_PROMPT_FILE): the wrapper resolved and stat'd the configured file
# as the operator, who cannot read it (0640 root:SANDBOX_GROUP). This is the half only the sandbox account can do --
# read it and refuse the launch when it is not plain text, since its bytes go to the model verbatim. A per-invocation
# prompt flag is not visible here, so a configured prompt must be text whether or not this launch overrides it. Same
# clean fail-closed as the endpoint resolution: sourced before the unit exists. See claude-prompt.lib.sh.
# shellcheck source=/dev/null
if source /usr/local/lib/ai-tools/claude-prompt.lib.sh 2>/dev/null \
        && declare -F ai_tools_claude_prompt_content_is_text >/dev/null 2>&1; then
    if ! ai_tools_claude_prompt_content_is_text /etc/ai-tools/operator.conf; then
        ai_tools_msg_error \
            "ai-tools-run: a custom Claude Code system prompt is configured but is not plain text --" \
            "refusing to launch (see the warning above). Fix the file named by" \
            "CLAUDE_SYSTEM_PROMPT_FILE in /etc/ai-tools/operator.conf, or comment the key out."
        exit 1
    fi
elif ai_tools_conf_read /etc/ai-tools/operator.conf CLAUDE_SYSTEM_PROMPT_FILE 2>/dev/null \
        && [[ -n "${_ai_tools_conf_value}" ]]; then
    ai_tools_msg_error \
        "ai-tools-run: a custom Claude Code system prompt is configured but its resolver library" \
        "is unavailable -- refusing to launch rather than skip the check. Reinstall ai-tools."
    exit 1
fi
