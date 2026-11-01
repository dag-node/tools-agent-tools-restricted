#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/atr -- the short command over the two CLIs of Agent Tools Restricted. `atr admin <command>` runs
# ai-tools-admin at its fixed path: directly as root, and otherwise through sudo after one line on stderr saying
# so, since the helper directory is root-only and the program refuses every other caller. Every other invocation runs
# ai-tools, which keeps its own refusals (the sandbox account; root for a writing verb). The programs, their help
# and their pages are the reference; this file adds a spelling. cli-grammar.rule.md states the split.
#
# Three `atr admin` answers do not go through sudo. A stop with no help flag ahead of `--` runs `ai-tools stop`,
# whose bare form the %ai-ops NOPASSWD rule covers, for every caller; that branch does not read a library,
# so the incident rung depends on this file and the CLI alone. An operator's help request, bare `atr admin`
# and `--version` are rendered here from help.lib.sh, the library ai-tools-admin renders its own help
# from, over the fixed domain and manifest directories this file names, so the environment does not move the listing.
# The sandbox account takes the sudo route and meets sudo's refusal, and a library that does not load sends the line
# to the sudo route, where the program answers or refuses with its own codes.
#
# Every path is fixed, so neither an operator's PATH nor the sandbox account redirects the exec; sudo is resolved
# by name, as ai-tools resolves it for its own root steps, and `--` ends sudo's option parsing ahead of the path. Every
# branch that runs a program execs it, so the program's exit status, prompts and signals are its own.
set -eu
readonly AI_TOOLS_ATR__ADMIN=/usr/local/libexec/ai-tools/ai-tools-admin
readonly AI_TOOLS_ATR__CLI=/usr/local/bin/ai-tools
readonly AI_TOOLS_ATR__HELP_LIB=/usr/local/lib/ai-tools/help.lib.sh
readonly AI_TOOLS_ATR__ADMIN_COMMANDS_DIR=/usr/local/lib/ai-tools/admin-commands.d
readonly AI_TOOLS_ATR__INTEGRATIONS_DIR=/usr/local/lib/ai-tools/integrations.d
readonly AI_TOOLS_ATR__AGENTS_DIR=/usr/local/lib/ai-tools/agents.d
readonly AI_TOOLS_ATR__SANDBOX_USER="@SANDBOX_USER@"
# Substituted at deploy time, as in the two programs, and `dev` from a source tree.
AI_TOOLS_ATR__VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_ATR__VERSION}" == @*@ ]] && AI_TOOLS_ATR__VERSION="dev"
readonly AI_TOOLS_ATR__VERSION

# _ai_tools_atr__has_help_flag <arg>...: succeed when -h or --help stands ahead of the first `--`.
_ai_tools_atr__has_help_flag() {
    local argument
    for argument in "$@"; do
        [[ "${argument}" != -- ]] || return 1
        [[ "${argument}" != -h && "${argument}" != --help ]] || return 0
    done
    return 1
}

if [[ "${1:-}" == admin ]]; then
    shift
    if [[ "${1:-}" == stop ]] && ! _ai_tools_atr__has_help_flag "$@"; then
        shift
        exec "${AI_TOOLS_ATR__CLI}" stop "$@"
    fi
    [[ "${EUID}" -eq 0 ]] && exec "${AI_TOOLS_ATR__ADMIN}" "$@"
    # A name that cannot be read is taken as the sandbox account's, the route where sudo's refusal decides.
    invoking_user="$(id -un 2>/dev/null)" || invoking_user="${AI_TOOLS_ATR__SANDBOX_USER}"
    if [[ -n "${invoking_user}" && "${invoking_user}" != "${AI_TOOLS_ATR__SANDBOX_USER}" ]]; then
        # shellcheck disable=SC2034  # read by providers.lib.sh, which help.lib.sh sources, for each domain's summary
        AI_TOOLS_INTEGRATIONS_DIR="${AI_TOOLS_ATR__INTEGRATIONS_DIR}"
        # shellcheck disable=SC2034  # read by providers.lib.sh, likewise
        AI_TOOLS_AGENTS_DIR="${AI_TOOLS_ATR__AGENTS_DIR}"
        # shellcheck source=SCRIPTDIR/../lib/ai-tools/help.lib.sh
        if source "${AI_TOOLS_ATR__HELP_LIB}" 2>/dev/null \
                && declare -F ai_tools_help__resolve_request >/dev/null 2>&1; then
            if [[ "${1:-}" == --version ]]; then
                printf 'ai-tools-admin %s\n' "${AI_TOOLS_ATR__VERSION}"
                exit 0
            fi
            help_status=0
            help_target="$(ai_tools_help__resolve_request ai-tools-admin "${AI_TOOLS_ATR__ADMIN_COMMANDS_DIR}" -- "$@")" \
                || help_status=$?
            if [[ "${help_status}" -eq 0 ]]; then
                if [[ "${help_target}" == - ]]; then
                    ai_tools_help__render ai-tools-admin "${AI_TOOLS_ATR__ADMIN_COMMANDS_DIR}"
                else
                    ai_tools_help__render_hint ai-tools-admin "${help_target}"
                fi
                exit 0
            fi
        else
            printf 'atr admin: cannot load %s -- reinstall the ai-tools package; asking ai-tools-admin instead\n' \
                "${AI_TOOLS_ATR__HELP_LIB}" >&2
        fi
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'atr admin: runs as root, and sudo is not installed -- run the command as root: ai-tools-admin\n' >&2
        exit 1
    fi
    printf 'atr admin: runs as root through sudo\n' >&2
    exec sudo -- "${AI_TOOLS_ATR__ADMIN}" "$@"
fi
exec "${AI_TOOLS_ATR__CLI}" "$@"
