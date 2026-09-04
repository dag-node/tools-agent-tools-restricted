#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/.claude/filter-hook.sh
# Claude Code's adapter onto the shared token-saving filters (filters.lib.sh). Two events, one
# script, dispatched on $1 the way session-hook.sh dispatches its session phases:
#
#   pre-tool-use   PreToolUse  on Bash -- rewrite the command so the tool prints less, returning
#                              hookSpecificOutput.updatedInput
#   post-tool-use  PostToolUse on Bash -- strip terminal control noise from the output the model
#                              is about to read, returning hookSpecificOutput.updatedToolOutput
#
# Only the JSON shapes are Claude Code's; every decision is made in filters.lib.sh, so a second
# agent reuses the rules with an adapter of its own.
#
# A rewrite is NOT a permission decision. This hook never returns permissionDecision, so the
# harness runs its full permission pipeline on the result: an allow rule must still match it and a
# deny rule still overrides. That is what keeps a rules file from being a way around settings.json
# rather than an input to it.
#
# Fail SOFT, deliberately -- the opposite of the fail-closed rule the security gates follow.
# Filtering is a pure output path: a missing library, absent jq, a malformed event, a rule that
# does not apply all end the same way, with this hook emitting no output and the command running
# exactly as the agent wrote it. There is no state in which failing here denies, alters or hides
# anything, so refusing would only trade tokens for lost work.
#
# Deploy: sudo install -o root -g ai-tools -m 750 \
#             src/opt/ai-tools/agents/claude-code/filter-hook.sh /opt/ai-tools/.claude/filter-hook.sh

set -euo pipefail

readonly FILTERS_LIB="/usr/local/lib/ai-tools/filters.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/filters.lib.sh
if ! source "${FILTERS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_filter_rewrite >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_strip_noise >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_enabled >/dev/null 2>&1; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

event="${1-}"
hook_input="$(cat)" || exit 0
[[ -n "${hook_input}" ]] || exit 0

case "${event}" in
pre-tool-use)
    # One jq pass covers both the tool check and the extraction; a non-Bash event yields an empty result.
    # The matcher in settings.json already scopes this to Bash -- the check does not add a fork
    # and keeps the script correct wherever it is wired.
    agent_command="$(jq -r 'if .tool_name == "Bash" then (.tool_input.command // empty) else empty end' \
        <<< "${hook_input}" 2>/dev/null)" || exit 0
    [[ -n "${agent_command}" ]] || exit 0

    ai_tools_filter_rules_load || exit 0
    rewritten_command="$(ai_tools_filter_rewrite "${agent_command}")" || exit 0

    # updatedInput REPLACES the whole tool input, so it is built from the original object with
    # only .command changed: dropping a key the agent set (a timeout, run_in_background) would
    # silently change how the command runs.
    jq -c --arg command "${rewritten_command}" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse",
                               updatedInput: (.tool_input + {command: $command})}}' \
        <<< "${hook_input}" 2>/dev/null || exit 0
    ;;

post-tool-use)
    # The operator's kill switch (an empty AI_TOOLS_FILTERS) covers the noise strip as well as
    # the rewrite: turning filtering off must leave the output the model reads byte-identical to
    # what the tool produced. The rewrite path honors the same switch by loading no rules.
    ai_tools_filter_enabled || exit 0

    # The Bash tool's result shape is read from the event rather than assumed: an object carrying
    # stdout/stderr strings has those two filtered in place, a bare string is filtered whole, and
    # anything else is left alone.
    response_kind="$(jq -r '
        if .tool_name != "Bash" then "none"
        elif (.tool_response | type) == "object" then
            (if ((.tool_response.stdout | type) == "string")
                or ((.tool_response.stderr | type) == "string") then "object" else "none" end)
        elif (.tool_response | type) == "string" then "string"
        else "none" end' <<< "${hook_input}" 2>/dev/null)" || exit 0

    # Command substitution strips trailing newlines, so every capture below carries an `x`
    # sentinel appended inside the substitution and removed after: a filtered value must differ
    # from the raw one only by the noise removed, never by a lost final newline. jq -j prints the
    # string without adding a newline of its own, which is what makes the raw capture exact.
    case "${response_kind}" in
    object)
        raw_stdout="$(jq -j '.tool_response.stdout // ""' <<< "${hook_input}" 2>/dev/null && printf x)" || exit 0
        raw_stdout="${raw_stdout%x}"
        raw_stderr="$(jq -j '.tool_response.stderr // ""' <<< "${hook_input}" 2>/dev/null && printf x)" || exit 0
        raw_stderr="${raw_stderr%x}"
        filtered_stdout="$(printf '%s' "${raw_stdout}" | ai_tools_filter_strip_noise && printf x)" || exit 0
        filtered_stdout="${filtered_stdout%x}"
        filtered_stderr="$(printf '%s' "${raw_stderr}" | ai_tools_filter_strip_noise && printf x)" || exit 0
        filtered_stderr="${filtered_stderr%x}"
        # No line to emit when the output carried no noise, which is the common case.
        [[ "${filtered_stdout}" != "${raw_stdout}" || "${filtered_stderr}" != "${raw_stderr}" ]] || exit 0
        jq -c --arg out "${filtered_stdout}" --arg err "${filtered_stderr}" \
            '{hookSpecificOutput: {hookEventName: "PostToolUse",
                updatedToolOutput: (.tool_response
                    | (if (.stdout | type) == "string" then .stdout = $out else . end)
                    | (if (.stderr | type) == "string" then .stderr = $err else . end))}}' \
            <<< "${hook_input}" 2>/dev/null || exit 0
        ;;
    string)
        raw_output="$(jq -j '.tool_response' <<< "${hook_input}" 2>/dev/null && printf x)" || exit 0
        raw_output="${raw_output%x}"
        filtered_output="$(printf '%s' "${raw_output}" | ai_tools_filter_strip_noise && printf x)" || exit 0
        filtered_output="${filtered_output%x}"
        [[ "${filtered_output}" != "${raw_output}" ]] || exit 0
        jq -cn --arg out "${filtered_output}" \
            '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $out}}' \
            2>/dev/null || exit 0
        ;;
    esac
    ;;
esac

exit 0
