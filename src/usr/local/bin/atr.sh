#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/atr -- the short command over the two CLIs of Agent Tools Restricted. `atr admin <command>` runs
# ai-tools-admin at its fixed path: directly as root, and otherwise through sudo after one line on stderr saying
# so, since the helper directory is root-only and the program refuses every other caller. Every other invocation runs
# ai-tools, which keeps its own refusals (the sandbox account; root for a writing verb). The programs, their help
# and their pages are the reference; this file adds a spelling. cli-grammar.rule.md states the split.
#
# Both programs are named by fixed path, so neither an operator's PATH nor the sandbox account redirects the exec; sudo
# is resolved by name, as ai-tools resolves it for its own root steps, and `--` ends sudo's option parsing ahead
# of the path. Every branch execs, so the program's exit status, prompts and signals are its own.
set -eu
readonly AI_TOOLS_ATR__ADMIN=/usr/local/libexec/ai-tools/ai-tools-admin
readonly AI_TOOLS_ATR__CLI=/usr/local/bin/ai-tools
if [[ "${1:-}" == admin ]]; then
    shift
    [[ "${EUID}" -eq 0 ]] && exec "${AI_TOOLS_ATR__ADMIN}" "$@"
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'atr admin: runs as root, and sudo is not installed -- run the command as root: ai-tools-admin\n' >&2
        exit 1
    fi
    printf 'atr admin: runs as root through sudo\n' >&2
    exec sudo -- "${AI_TOOLS_ATR__ADMIN}" "$@"
fi
exec "${AI_TOOLS_ATR__CLI}" "$@"
