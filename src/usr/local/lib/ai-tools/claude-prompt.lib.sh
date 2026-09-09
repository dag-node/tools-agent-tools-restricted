#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/claude-prompt.lib.sh
# Resolves the Claude Code launch arguments that carry an operator-configured custom system
# prompt, from operator.conf's CLAUDE_SYSTEM_PROMPT_FILE / CLAUDE_SYSTEM_PROMPT_MODE keys. Sourced
# (never executed) by claude.sh just before it execs the session; the pure resolution is split from
# the wrapper so tests/unit/claude-prompt.sh drives it apart from a real launch. Claude Code-specific
# (the four --{,append-}system-prompt{,-file} flags are its own), so it ships with the agent
# wrapper rather than in the agent-agnostic shim, and the keys are prefixed CLAUDE_ for the same
# reason.
#
# Fail closed WHEN CONFIGURED: an unconfigured host launches with Claude Code's default prompt,
# and a configured prompt that cannot be honoured makes the resolver return non-zero and claude.sh
# refuse the launch -- launching with the default instead would be a wrong result, not a safe
# degradation. A per-invocation --{,append-}system-prompt{,-file} flag steps the standing default
# aside with no refusal. What a configured prompt must satisfy, and why the base is
# /etc/ai-tools/prompts/ (the one etc_t place the confined domain reads), are in
# agent-claude-code.rule.md. The file is resolved here as the operator and read by the confined
# binary as the sandbox account, so each path component and operator.conf itself pass
# ai_tools_conf_is_trusted: the sandbox account cannot swap the prompt between resolution and read.

# Include-guarded: claude.sh and the unit test may both source this and its dependencies.
if [[ -n "${_AI_TOOLS_CLAUDE_PROMPT_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CLAUDE_PROMPT_LIB=1

# The shared KEY=value grammar (ai_tools_conf_read) and the trust predicate
# (ai_tools_conf_is_trusted). Include-guarded, so a re-source in a shell that already has it is a
# no-op. claude.sh loads and verifies it before this lib, so in production it is already present;
# sourced here too so the unit test can drive this lib directly.
if [[ -z "${_AI_TOOLS_CONF_LIB:-}" ]]; then
    # shellcheck source=SCRIPTDIR/conf.lib.sh
    source /usr/local/lib/ai-tools/conf.lib.sh 2>/dev/null || true
fi
# Warnings render through msg.lib (ai_tools_msg_warn), best-effort: a missing formatter drops the
# warning text, never the refusal it accompanies (the caller acts on the return code, not the text).
if [[ -z "${_AI_TOOLS_MSG_LIB_LOADED:-}" ]]; then
    # shellcheck source=SCRIPTDIR/msg.lib.sh
    source /usr/local/lib/ai-tools/msg.lib.sh 2>/dev/null || true
fi

# _ai_tools_claude_warn <line...>: warn through msg.lib when present, else a plain stderr line, so a
# resolution refusal is visible whether or not the formatter loaded.
_ai_tools_claude_warn() {
    if declare -F ai_tools_msg_warn >/dev/null 2>&1; then
        ai_tools_msg_warn "$@"
    else
        printf 'claude: %s\n' "$*" >&2
    fi
}

# _ai_tools_claude_argv_has_prompt_flag <arg...>: succeed when any argument is one of Claude Code's
# system-prompt flags, in either the `--flag value` or `--flag=value` form. Presence means the
# operator is steering this one launch's prompt by hand, so the standing operator.conf default steps
# aside.
_ai_tools_claude_argv_has_prompt_flag() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --system-prompt|--system-prompt=*|\
            --system-prompt-file|--system-prompt-file=*|\
            --append-system-prompt|--append-system-prompt=*|\
            --append-system-prompt-file|--append-system-prompt-file=*)
                return 0 ;;
        esac
    done
    return 1
}

# ai_tools_claude_prompt_content_is_text <operator-conf> : the sandbox-side half of the check.
#   The wrapper resolves the configured prompt as the operator, whose checks are all stats: the
#   shipped prompt is 0640 root:SANDBOX_GROUP so a sensitive prompt stays unreadable to every other
#   account, the operator's own included (an operator holds sudo for editing it). This function
#   runs in the claude-code session-env fragment as the sandbox account, which can read the file:
#   it resolves the configured prompt the same way (no session arguments -- a per-invocation flag
#   override is not visible here, so a configured prompt must be text whether or not this launch
#   uses it) and succeeds when none is configured or the file holds text. Fails, with the reason
#   warned, when the configured prompt is not plain text; the caller refuses the launch, since the
#   file's bytes would otherwise go to the model verbatim.
ai_tools_claude_prompt_content_is_text() {
    local operator_conf="$1"
    local -a configured=()
    ai_tools_claude_resolve_prompt_args configured "${operator_conf}" || return 1
    (( ${#configured[@]} )) || return 0
    local prompt_file="${configured[${#configured[@]}-1]}"
    ai_tools_conf_is_text_file "${prompt_file}" && return 0
    _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) is not a text file -- a system prompt must be plain text"
    return 1
}

# ai_tools_claude_resolve_prompt_args <out-array-name> <operator-conf> [session-arg...] : set the
#   named array to the system-prompt launch arguments an operator has configured -- either
#   ( --append-system-prompt-file <path> ) or ( --system-prompt-file <path> ) -- or leave it EMPTY.
#   Returns:
#     0  the array holds the outcome to launch with. EMPTY means either no prompt is configured
#        (the baseline) or the operator passed a system-prompt flag for this invocation (they steer
#        it by hand); NON-EMPTY means a configured prompt validated. Either way, launch.
#     1  a prompt IS configured but could not be honoured. The caller must REFUSE the launch rather
#        than fall back to the default prompt. The reason is warned.
#   AI_TOOLS_PROMPT_BASE_DIR overrides the required parent directory; it is a ROOT-ONLY test hook of
#   the AI_TOOLS_ALLOWLIST family (sudo strips it, it is not in env_keep, and this resolves as the
#   operator before the drop to the sandbox account), unset in production where the base is the fixed
#   /etc/ai-tools/prompts.
ai_tools_claude_resolve_prompt_args() {
    local -n _ai_tools_claude_prompt_out="$1"
    local operator_conf="$2"
    shift 2
    _ai_tools_claude_prompt_out=()

    # Without the grammar parser this lib cannot tell configured from unconfigured, so it cannot
    # promise the baseline is safe -- fail closed. In production conf.lib is a hard, verified
    # dependency of claude.sh loaded before this lib, so this only fires on a broken install.
    if ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
            || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1; then
        _ai_tools_claude_warn "the config library is unavailable, so a custom system prompt cannot be resolved"
        return 1
    fi

    local base_dir="${AI_TOOLS_PROMPT_BASE_DIR:-/etc/ai-tools/prompts}"

    # A per-invocation flag wins: skip the operator.conf default entirely rather than passing both
    # and depending on which the binary's parser keeps (two same-kind flags may even be rejected).
    if _ai_tools_claude_argv_has_prompt_flag "$@"; then
        return 0
    fi

    # Is a prompt configured at all? Read it first; an absent or empty key is the baseline, and the
    # trust of operator.conf only has to be established once a value is in play.
    local prompt_file=""
    if ai_tools_conf_read "${operator_conf}" CLAUDE_SYSTEM_PROMPT_FILE 2>/dev/null; then
        prompt_file="${_ai_tools_conf_value}"
    fi
    [[ -n "${prompt_file}" ]] || return 0            # not configured: launch with the default prompt

    # From here a prompt IS configured, so every failure is a refusal (return 1), never a silent
    # fall-back. The value came FROM operator.conf, so operator.conf must itself be trustworthy
    # before its value is honoured -- the same predicate providers.lib.sh applies to a manifest.
    if ! ai_tools_conf_is_trusted "${operator_conf}"; then
        _ai_tools_claude_warn "${operator_conf} is not root-owned or is group/other-writable -- refusing to apply the configured system prompt"
        return 1
    fi

    # Absolute only: a relative path would resolve against the operator's cwd, not the trusted base.
    if [[ "${prompt_file}" != /* ]]; then
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE must be an absolute path under ${base_dir} -- got '${prompt_file}'"
        return 1
    fi

    # Reject a symlink at the configured path outright (before canonicalizing), so a link planted in
    # a writable directory cannot redirect the read at a file outside the trusted base.
    if ! ai_tools_conf_is_trusted "${prompt_file}"; then
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) is missing, a symlink, not root-owned, or group/other-writable"
        return 1
    fi

    # Canonicalize the base and the file, then require the file to sit under the base. realpath
    # collapses any '..' so the containment check cannot be smuggled past.
    local base_canon file_canon
    base_canon="$(realpath -m -- "${base_dir}" 2>/dev/null)" || {
        _ai_tools_claude_warn "cannot resolve the prompt base ${base_dir}"
        return 1
    }
    file_canon="$(realpath -e -- "${prompt_file}" 2>/dev/null)" || {
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) cannot be resolved"
        return 1
    }
    if [[ "${file_canon}" != "${base_canon}/"* ]]; then
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) is not under ${base_dir}; the confined session can only read prompts there"
        return 1
    fi

    # The base and the file's own directory must be trusted too: a group-writable directory anywhere
    # on the way lets a non-root writer replace the root-owned file the check above approved.
    if ! ai_tools_conf_is_trusted "${base_canon}"; then
        _ai_tools_claude_warn "the prompt base ${base_dir} is not root-owned or is group/other-writable"
        return 1
    fi
    local file_dir
    file_dir="$(dirname -- "${file_canon}")"
    if [[ "${file_dir}" != "${base_canon}" ]] && ! ai_tools_conf_is_trusted "${file_dir}"; then
        _ai_tools_claude_warn "the directory holding the custom prompt is not root-owned or is group/other-writable"
        return 1
    fi

    # A prompt is text the model reads, so refuse a binary blob (an ELF, a compiled artifact) whose
    # bytes would otherwise land verbatim in the system prompt.
    # A stat, not a read: this runs as the operator, who cannot read the 0640 file. Whether the
    # content is text is checked sandbox-side (ai_tools_claude_prompt_content_is_text).
    if [[ ! -f "${file_canon}" ]]; then
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) is not a regular file -- a system prompt is one plain file"
        return 1
    fi

    # Mode is an allowlist: append (the default) keeps Claude Code's built-in tool-use/safety
    # guidance and layers the file after it; replace drops the default entirely.
    local prompt_mode="append"
    if ai_tools_conf_read "${operator_conf}" CLAUDE_SYSTEM_PROMPT_MODE 2>/dev/null; then
        [[ -n "${_ai_tools_conf_value}" ]] && prompt_mode="${_ai_tools_conf_value}"
    fi
    case "${prompt_mode}" in
        append)  _ai_tools_claude_prompt_out=( --append-system-prompt-file "${file_canon}" ) ;;
        replace) _ai_tools_claude_prompt_out=( --system-prompt-file "${file_canon}" ) ;;
        *)
            _ai_tools_claude_warn "unknown CLAUDE_SYSTEM_PROMPT_MODE '${prompt_mode}' -- expected append or replace"
            return 1
            ;;
    esac
    return 0
}
