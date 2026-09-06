#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/claude-prompt.lib.sh
# Resolves the Claude Code launch arguments that carry an operator-configured custom system
# prompt, from operator.conf's CLAUDE_SYSTEM_PROMPT_FILE / CLAUDE_SYSTEM_PROMPT_MODE keys. Sourced
# (never executed) by claude.sh just before it execs the session; the pure resolution is split from
# the wrapper so it is unit-tested apart from a real launch (tests/unit/claude-prompt.sh), the same
# split confinement.lib.sh/providers.lib.sh make.
#
# This is Claude Code-specific (the four --{,append-}system-prompt{,-file} flags are its own), so it
# ships with the agent wrapper rather than in ai-tools-run's agent-agnostic shim, and the keys are
# prefixed CLAUDE_ rather than AI_TOOLS_ for the same reason (matching CLAUDE_CONFIG_DIR).
#
# ── Tier: fail closed WHEN CONFIGURED ─────────────────────────────────────────────────────────
# A custom system prompt is not confinement, but an operator who enabled one is relying on the
# model behaving the configured way, so silently launching with Claude Code's DEFAULT prompt instead
# is a wrong result, not a safe degradation. The two states are therefore treated differently:
#   * NOT configured (CLAUDE_SYSTEM_PROMPT_FILE absent or empty) -> no arguments; the session
#     launches with Claude Code's own default prompt. This is the baseline, not a failure.
#   * CONFIGURED but the file/mode cannot be honoured (missing, unreadable, a symlink, not root-
#     owned, group/other-writable, outside the trusted base, not a text prompt, or an unknown mode)
#     -> the resolver returns non-zero and claude.sh REFUSES the launch. Better a clear refusal the
#     operator fixes than a session that runs with a prompt they did not configure.
# An operator passing a --{,append-}system-prompt{,-file} flag for a single invocation is steering
# that launch by hand; the standing operator.conf default steps aside and no refusal fires.
#
# ── What it accepts, and why the bar is where it is ───────────────────────────────────────────
# The resolved file is opened TWICE: by claude.sh as the operator at launch, and -- once forwarded
# as --append-system-prompt-file/--system-prompt-file -- by the versioned binary running as the
# sandbox account under the ai_tools_t SELinux domain. Both reads must succeed and neither input may
# be one the sandbox account can influence, so a CONFIGURED prompt is accepted only when:
#   * the path resolves under /etc/ai-tools/prompts/ (etc_t), the one place the confined domain is
#     granted read on via files_read_etc_files -- a root-owned file elsewhere would pass the DAC
#     trust check yet be UNREADABLE to ai_tools_t under enforcing;
#   * that file, its directory, the prompts base, and operator.conf itself each pass
#     ai_tools_conf_is_trusted (exists, not a symlink, root-owned, not group/other-writable), so the
#     sandbox account cannot swap the approved prompt between the two reads;
#   * the file is a regular TEXT file, not a binary blob (a prompt is read as text, never executed);
#   * the mode is an allowlist (append|replace).
# Anything else on a configured prompt is a refusal, reported.

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

# _ai_tools_claude_is_text_file <path>: succeed when <path> is a regular file that is either empty
# or holds text (no binary/NUL content). The custom prompt is read as text and appended to (or
# substituted for) the model's system prompt -- it is never executed -- so the only sanity bar is
# that it is not a binary blob whose bytes would land in the prompt. An empty file is fine: it is the
# shipped inert default, and appending it leaves the prompt as it was. `grep -I` reports a binary file as no-match.
_ai_tools_claude_is_text_file() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    [[ -s "${path}" ]] || return 0                       # empty: valid (the inert default)
    LC_ALL=C grep -Iq . "${path}" 2>/dev/null
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
    # trust of operator.conf only has to be established once a value is actually in play.
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
    if ! _ai_tools_claude_is_text_file "${file_canon}"; then
        _ai_tools_claude_warn "CLAUDE_SYSTEM_PROMPT_FILE (${prompt_file}) is not a text file -- a system prompt must be readable text"
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
