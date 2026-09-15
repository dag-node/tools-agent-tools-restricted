#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/cli-spelling.sh
# The one place a test spells an ai-tools command. A test names what a command DOES -- a key such as `projects.claim` --
# and this table turns the key into the tokens the deployed CLI accepts, so no assertion in the suite carries
# a spelling. A rename of the command surface (.claude/rules/cli-grammar.rule.md) edits this file alone;
# tests/integration/cli-flags.sh then re-asserts every effect against the new spelling, which is what makes that file
# the retention proof for the conversion.
#
# The CLI accepts two spellings of each command, and AI_TOOLS_CLI_SPELLING selects which one cli_cmd fills:
# `collection`, the default, is the collection form (`projects claim`); `option` is the option spelling the CLI keeps
# for compatibility (`--project-claim`), which it rewrites to the command and notices on. cli-flags.sh drives its rows
# once per spelling, so the file green in each spelling is the proof that the kept one runs as the command it spells.
#
# cli_cmd <key>       fills CLI_ARGV with the command's tokens in the selected spelling -- the collection and its verb
#                     for a project command, one bare word for a host command -- and returns 1 for an unknown key
#                     so a typo in a row fails the row rather than running the bare binary.
# cli_cmd_text <key>  prints the command's tokens in the collection spelling joined by one space, whatever
#                     the selection, for a grep over output that names the command as a remedy: a remedy names
#                     the preferred form.
# cli_flag <key>      prints one option token. A `.short` key is the one-letter form a verb accepts
#                     beside the long one; `--dry-run` has none, so `-n` stays free for a `--no`. `group.short`
#                     is `-g`, the short form the CLI keeps for `--group` and rewrites wherever it stands.

# shellcheck disable=SC2034  # CLI_ARGV is the output, read by the caller's shell
cli_cmd() {
    # Tested rather than dispatched by `case`: cli-flags.sh reads this function's case arms as the command keys.
    local spelling="${AI_TOOLS_CLI_SPELLING:-collection}"
    if [[ "${spelling}" == option ]]; then cli_cmd_option "$1"; return; fi
    if [[ "${spelling}" != collection ]]; then
        printf 'cli-spelling: unknown spelling: %s (collection or option)\n' "${spelling}" >&2; return 1
    fi
    case "$1" in
        help)              CLI_ARGV=(--help) ;;
        version)           CLI_ARGV=(--version) ;;
        projects.list)     CLI_ARGV=(projects list) ;;
        projects.create)   CLI_ARGV=(projects create) ;;
        projects.claim)    CLI_ARGV=(projects claim) ;;
        projects.unclaim)  CLI_ARGV=(projects unclaim) ;;
        projects.remove)   CLI_ARGV=(projects remove) ;;
        projects.disable)  CLI_ARGV=(projects disable) ;;
        projects.enable)   CLI_ARGV=(projects enable) ;;
        projects.clone)    CLI_ARGV=(projects clone) ;;
        projects.push)     CLI_ARGV=(projects push) ;;
        # The clone kind of `projects remove`: one verb decides the kind from the path, and a row that drives a clone
        # keeps this key so the clone rows read as what they remove.
        sandbox.remove)    CLI_ARGV=(projects remove) ;;
        projects.lockdown) CLI_ARGV=(projects lockdown) ;;
        projects.handback) CLI_ARGV=(projects handback) ;;
        status)            CLI_ARGV=(status) ;;
        providers)         CLI_ARGV=(providers) ;;
        audit)             CLI_ARGV=(audit) ;;
        stop)              CLI_ARGV=(stop) ;;
        *) printf 'cli-spelling: unknown command key: %s\n' "$1" >&2; return 1 ;;
    esac
}

# cli_cmd_option <key>: the same keys in the option spelling, one token each. `help` has no option spelling of its own:
# `--help` and `-h` are the command in either form.
cli_cmd_option() {
    case "$1" in
        help)              CLI_ARGV=(--help) ;;
        version)           CLI_ARGV=(-V) ;;
        projects.list)     CLI_ARGV=(--list) ;;
        projects.create)   CLI_ARGV=(--project-create) ;;
        projects.claim)    CLI_ARGV=(--project-claim) ;;
        projects.unclaim)  CLI_ARGV=(--project-unclaim) ;;
        projects.remove)   CLI_ARGV=(--project-remove) ;;
        projects.disable)  CLI_ARGV=(--project-disable) ;;
        projects.enable)   CLI_ARGV=(--project-enable) ;;
        projects.clone)    CLI_ARGV=(--sandbox-create) ;;
        projects.push)     CLI_ARGV=(--sandbox-push) ;;
        sandbox.remove)    CLI_ARGV=(--sandbox-remove) ;;
        projects.lockdown) CLI_ARGV=(--lockdown) ;;
        projects.handback) CLI_ARGV=(--reclaim) ;;
        status)            CLI_ARGV=(--status) ;;
        providers)         CLI_ARGV=(--providers) ;;
        audit)             CLI_ARGV=(--audit) ;;
        stop)              CLI_ARGV=(--stop) ;;
        *) printf 'cli-spelling: unknown command key: %s\n' "$1" >&2; return 1 ;;
    esac
}

cli_cmd_text() {
    local -a argv
    AI_TOOLS_CLI_SPELLING=collection cli_cmd "$1" || return 1
    argv=("${CLI_ARGV[@]}")
    local IFS=' '
    printf '%s' "${argv[*]}"
}

cli_flag() {
    case "$1" in
        yes)            printf -- '--yes' ;;
        yes.short)      printf -- '-y' ;;
        dry-run)        printf -- '--dry-run' ;;
        for)            printf -- '--for' ;;
        force)          printf -- '--force' ;;
        full)           printf -- '--full' ;;
        group)          printf -- '--group' ;;
        group.short)    printf -- '-g' ;;
        keep-entry)     printf -- '--keep-entry' ;;
        since)          printf -- '--since' ;;
        from)           printf -- '--from' ;;
        branch)         printf -- '--branch' ;;
        dir)            printf -- '--dir' ;;
        all)            printf -- '--all' ;;
        *) printf 'cli-spelling: unknown flag key: %s\n' "$1" >&2; return 1 ;;
    esac
}
