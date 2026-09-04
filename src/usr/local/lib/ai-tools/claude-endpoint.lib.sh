#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/claude-endpoint.lib.sh
# Resolves the ANTHROPIC_* session environment that routes a Claude Code session at a custom API
# endpoint, from a dedicated endpoint file that operator.conf's CLAUDE_BASE_URL_FILE points at.
# Sourced (never executed) by the claude-code session-env fragment, which runs inside ai-tools-run
# as the sandbox account; the pure resolution is split out so it is unit-tested apart from a real
# launch (tests/unit/claude-endpoint.sh), the same split claude-prompt.lib.sh makes.
#
# Why a dedicated file, not operator.conf: one of the four values is a bearer token
# (ANTHROPIC_AUTH_TOKEN), and operator.conf is 644 world-readable and must never hold a secret. The
# endpoint file lives at /etc/ai-tools/endpoints/ mode 640 root:@SANDBOX_GROUP@ instead -- readable
# by root and the sandbox account (which needs the token) but NOT world, and NOT by the operator
# (who is not in @SANDBOX_GROUP@), so the credential does not leak. operator.conf only holds the
# POINTER (CLAUDE_BASE_URL_FILE), never the token. That the operator cannot read the file is also why
# validation happens HERE, sandbox-side in the fragment, rather than in the operator-side wrapper.
#
# ── Tier: fail closed on an invalid CONFIGURED option ─────────────────────────────────────────
# An operator who enables a custom endpoint is relying on the session routing there, so a broken
# value is refused rather than quietly ignored. The states, and their outcomes:
#   * NOT configured (CLAUDE_BASE_URL_FILE absent/empty), or the endpoint file present but INERT
#     (no recognised key uncommented) -> no options; the session uses the default Anthropic endpoint.
#   * A recognised option is present (uncommented) but INVALID -- a malformed URL, a model label with
#     whitespace, a token with control bytes, or options set with no ANTHROPIC_BASE_URL to anchor
#     them -- or the pointer names a missing/untrusted file -> the resolver returns non-zero and the
#     fragment REFUSES the launch. Only sane, present options are ever passed to Claude Code.
# A non-local endpoint with no token is WARNED about but still applied: an absent token is an omitted
# option, not an invalid one, and Claude Code surfaces the resulting auth failure itself.
#
# What the resolver guarantees regardless:
#   * only the four RECOGNISED keys are read -- an arbitrary key in the file never becomes session
#     environment;
#   * the endpoint file must sit under /etc/ai-tools/endpoints/ (etc_t, the one place the confined
#     session can read), be root-owned, not group/other-writable, and not a symlink;
#   * ANTHROPIC_AUTH_TOKEN is imported BY NAME (--setenv=ANTHROPIC_AUTH_TOKEN, no value on the
#     command line) so it does not leak via ps / /proc/<pid>/cmdline -- the discipline ai-tools-run
#     already uses for the forwarded environment.
# Precedence: these are process environment variables. A Claude Code settings `env` block
# (settings.json, and authoritatively /etc/claude-code/managed-settings.json) that sets the same
# name takes precedence over them; the shipped settings set no ANTHROPIC_* key, so the endpoint file
# governs by default and managed-settings.json remains the un-overridable host lock.

# Include-guarded: the fragment and the unit test may both source this and its dependencies.
if [[ -n "${_AI_TOOLS_CLAUDE_ENDPOINT_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CLAUDE_ENDPOINT_LIB=1

# conf.lib (grammar + trust) and msg.lib (warnings). Include-guarded; ai-tools-run loads both before
# any fragment, so in production they are already present. Sourced here too for the unit test.
if [[ -z "${_AI_TOOLS_CONF_LIB:-}" ]]; then
    # shellcheck source=SCRIPTDIR/conf.lib.sh
    source /usr/local/lib/ai-tools/conf.lib.sh 2>/dev/null || true
fi
if [[ -z "${_AI_TOOLS_MSG_LIB_LOADED:-}" ]]; then
    # shellcheck source=SCRIPTDIR/msg.lib.sh
    source /usr/local/lib/ai-tools/msg.lib.sh 2>/dev/null || true
fi

_ai_tools_endpoint_warn() {
    if declare -F ai_tools_msg_warn >/dev/null 2>&1; then
        ai_tools_msg_warn "$@"
    else
        printf 'claude: %s\n' "$*" >&2
    fi
}

# _ai_tools_endpoint_is_local <url>: succeed when <url>'s host is a loopback name, so a token may be
# omitted without warning (a local proxy commonly needs none).
_ai_tools_endpoint_is_local() {
    local host="${1#*://}"       # strip scheme
    host="${host%%/*}"           # strip path
    case "${host}" in
        '[::1]'|'[::1]:'*) return 0 ;;
    esac
    host="${host%%:*}"           # strip :port
    case "${host}" in
        localhost|127.0.0.1|::1) return 0 ;;
        *) return 1 ;;
    esac
}

# ai_tools_claude_resolve_endpoint_setenv <out-array-name> <operator-conf> : append the
#   --setenv= options that route this session at a custom endpoint to the named array, reading the
#   endpoint file operator.conf's CLAUDE_BASE_URL_FILE points at. Returns:
#     0  applied (out holds the valid options) or no option to apply (not configured / inert file).
#     1  a configured option is invalid, or the pointer names a missing/untrusted file. The caller
#        must REFUSE the launch rather than route the session with a partial or wrong endpoint.
#   As a deliberate side effect it EXPORTS ANTHROPIC_AUTH_TOKEN into the caller's environment when a
#   valid token is present, so the paired name-only --setenv=ANTHROPIC_AUTH_TOKEN imports the value
#   without placing it on any command line. AI_TOOLS_ENDPOINT_BASE_DIR overrides the required parent
#   directory; ROOT-ONLY test hook of the AI_TOOLS_ALLOWLIST family (sudo strips it, not in
#   env_keep), unset in production.
ai_tools_claude_resolve_endpoint_setenv() {
    local -n _ai_tools_endpoint_out="$1"
    local operator_conf="$2"

    # Without the parser this cannot tell configured from unconfigured, so it cannot promise the
    # default is what the operator wants -- fail closed. In production conf.lib is loaded by
    # ai-tools-run before any fragment, so this only fires on a broken install.
    if ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
            || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1; then
        _ai_tools_endpoint_warn "custom endpoint: the config library is unavailable -- cannot resolve the endpoint"
        return 1
    fi

    local base_dir="${AI_TOOLS_ENDPOINT_BASE_DIR:-/etc/ai-tools/endpoints}"

    # The pointer comes from operator.conf, so operator.conf must be trustworthy before it is read.
    # An untrusted operator.conf is treated as "not configured" (the baseline), matching how the
    # provider gating downgrades an untrusted operator.conf rather than failing a launch on it.
    ai_tools_conf_is_trusted "${operator_conf}" || return 0

    local endpoint_file=""
    if ai_tools_conf_read "${operator_conf}" CLAUDE_BASE_URL_FILE 2>/dev/null; then
        endpoint_file="${_ai_tools_conf_value}"
    fi
    [[ -n "${endpoint_file}" ]] || return 0          # not configured: default Anthropic endpoint

    # From here an endpoint IS configured, so a broken pointer is a refusal, never a silent default.
    if [[ "${endpoint_file}" != /* ]]; then
        _ai_tools_endpoint_warn "custom endpoint: CLAUDE_BASE_URL_FILE must be an absolute path under ${base_dir} -- got '${endpoint_file}'"
        return 1
    fi
    if ! ai_tools_conf_is_trusted "${endpoint_file}"; then
        _ai_tools_endpoint_warn "custom endpoint: ${endpoint_file} is missing, a symlink, not root-owned, or group/other-writable"
        return 1
    fi
    local base_canon file_canon
    base_canon="$(realpath -m -- "${base_dir}" 2>/dev/null)" || return 1
    file_canon="$(realpath -e -- "${endpoint_file}" 2>/dev/null)" || {
        _ai_tools_endpoint_warn "custom endpoint: ${endpoint_file} cannot be resolved"
        return 1
    }
    if [[ "${file_canon}" != "${base_canon}/"* ]] || ! ai_tools_conf_is_trusted "${base_canon}"; then
        _ai_tools_endpoint_warn "custom endpoint: ${endpoint_file} is not under a trusted ${base_dir}; the confined session can only read endpoints there"
        return 1
    fi

    # Read ONLY the recognised keys. An unknown key in the file is never consulted.
    local base_url="" auth_token="" model="" haiku=""
    ai_tools_conf_read "${file_canon}" ANTHROPIC_BASE_URL 2>/dev/null && base_url="${_ai_tools_conf_value}"
    ai_tools_conf_read "${file_canon}" ANTHROPIC_AUTH_TOKEN 2>/dev/null && auth_token="${_ai_tools_conf_value}"
    ai_tools_conf_read "${file_canon}" ANTHROPIC_MODEL 2>/dev/null && model="${_ai_tools_conf_value}"
    ai_tools_conf_read "${file_canon}" ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null && haiku="${_ai_tools_conf_value}"

    # A fully inert file (no option uncommented) is the shipped default: no endpoint, launch normally.
    if [[ -z "${base_url}" && -z "${auth_token}" && -z "${model}" && -z "${haiku}" ]]; then
        return 0
    fi

    # ANTHROPIC_BASE_URL anchors the endpoint: options set without it would only mis-route the
    # default Anthropic connection, so their presence with no base URL is a refusal.
    if [[ -z "${base_url}" ]]; then
        _ai_tools_endpoint_warn "custom endpoint: ${endpoint_file} sets ANTHROPIC_* options but no ANTHROPIC_BASE_URL to anchor them"
        return 1
    fi
    if [[ ! "${base_url}" =~ ^https?://[^[:space:]]+$ ]]; then
        _ai_tools_endpoint_warn "custom endpoint: ANTHROPIC_BASE_URL '${base_url}' is not a valid http(s) URL"
        return 1
    fi

    # Model labels are opaque single tokens the endpoint resolves; a present-but-malformed one is a
    # refusal (never let whitespace/control bytes reach systemd-run), an omitted one is skipped.
    if [[ -n "${model}" && ! "${model}" =~ ^[[:graph:]]+$ ]]; then
        _ai_tools_endpoint_warn "custom endpoint: ANTHROPIC_MODEL is not a single printable token"
        return 1
    fi
    if [[ -n "${haiku}" && ! "${haiku}" =~ ^[[:graph:]]+$ ]]; then
        _ai_tools_endpoint_warn "custom endpoint: ANTHROPIC_DEFAULT_HAIKU_MODEL is not a single printable token"
        return 1
    fi
    if [[ -n "${auth_token}" && ! "${auth_token}" =~ ^[[:graph:]]+$ ]]; then
        _ai_tools_endpoint_warn "custom endpoint: ANTHROPIC_AUTH_TOKEN contains whitespace or control characters"
        return 1
    fi

    # All present options validated: build the setenv list.
    _ai_tools_endpoint_out+=( "--setenv=ANTHROPIC_BASE_URL=${base_url}" )
    [[ -n "${model}" ]] && _ai_tools_endpoint_out+=( "--setenv=ANTHROPIC_MODEL=${model}" )
    [[ -n "${haiku}" ]] && _ai_tools_endpoint_out+=( "--setenv=ANTHROPIC_DEFAULT_HAIKU_MODEL=${haiku}" )
    if [[ -n "${auth_token}" ]]; then
        # Imported by name: export it so the paired name-only --setenv picks it up from the
        # environment (ai-tools-run sources this fragment in its own shell) without the value ever
        # reaching a command line.
        export ANTHROPIC_AUTH_TOKEN="${auth_token}"
        _ai_tools_endpoint_out+=( "--setenv=ANTHROPIC_AUTH_TOKEN" )
    elif ! _ai_tools_endpoint_is_local "${base_url}"; then
        _ai_tools_endpoint_warn "custom endpoint: no ANTHROPIC_AUTH_TOKEN set for non-local ${base_url} -- the endpoint may reject requests"
    fi
    return 0
}
