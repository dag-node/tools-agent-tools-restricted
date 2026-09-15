#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/cli-spelling.sh
# The one place a test spells an ai-tools command. A test names what a command DOES -- a key such
# as `ai-tools.projects.claim` -- and this table turns the key into the tokens the deployed CLI accepts, so no assertion
# in the suite carries a spelling. A rename of the command surface (.claude/rules/cli-grammar.rule.md) edits this file
# alone; tests/integration/cli-flags.sh then re-asserts every effect against the new spelling, which is what makes
# that file the retention proof for the conversion.
#
# A key is the command's path with the binary in front and a dot for each space, so `ai-tools status` is
# `ai-tools.status`. The binary is part of the key because `status` names a command on ai-tools-admin as well,
# and because a key is what a test's own assertion labels carry: one greppable token per command, told apart
# from the same word in ordinary prose. `projects remove` decides its kind from the path, so neither of its keys is
# a command path: each names the kind the row drives, and a row reads as what it removes.
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
        ai-tools.help)                    CLI_ARGV=(--help) ;;
        ai-tools.version)                 CLI_ARGV=(--version) ;;
        ai-tools.projects.list)           CLI_ARGV=(projects list) ;;
        ai-tools.projects.create)         CLI_ARGV=(projects create) ;;
        ai-tools.projects.claim)          CLI_ARGV=(projects claim) ;;
        ai-tools.projects.unclaim)        CLI_ARGV=(projects unclaim) ;;
        # One verb, two kinds: the same tokens either way, and the key says which kind the row drives.
        ai-tools.projects.remove.inplace) CLI_ARGV=(projects remove) ;;
        ai-tools.projects.remove.clone)   CLI_ARGV=(projects remove) ;;
        ai-tools.projects.disable)        CLI_ARGV=(projects disable) ;;
        ai-tools.projects.enable)         CLI_ARGV=(projects enable) ;;
        ai-tools.projects.clone)          CLI_ARGV=(projects clone) ;;
        ai-tools.projects.push)           CLI_ARGV=(projects push) ;;
        ai-tools.projects.lockdown)       CLI_ARGV=(projects lockdown) ;;
        ai-tools.projects.handback)       CLI_ARGV=(projects handback) ;;
        ai-tools.status)                  CLI_ARGV=(status) ;;
        ai-tools.providers)               CLI_ARGV=(providers) ;;
        ai-tools.audit)                   CLI_ARGV=(audit) ;;
        ai-tools.stop)                    CLI_ARGV=(stop) ;;
        *) printf 'cli-spelling: unknown command key: %s\n' "$1" >&2; return 1 ;;
    esac
}

# cli_cmd_option <key>: the same keys in the option spelling, one token each. `ai-tools.help` has no option spelling
# of its own: `--help` and `-h` are the command in either form.
cli_cmd_option() {
    case "$1" in
        ai-tools.help)                    CLI_ARGV=(--help) ;;
        ai-tools.version)                 CLI_ARGV=(-V) ;;
        ai-tools.projects.list)           CLI_ARGV=(--list) ;;
        ai-tools.projects.create)         CLI_ARGV=(--project-create) ;;
        ai-tools.projects.claim)          CLI_ARGV=(--project-claim) ;;
        ai-tools.projects.unclaim)        CLI_ARGV=(--project-unclaim) ;;
        # The kind the collection form derives from the path is what the two option spellings named outright.
        ai-tools.projects.remove.inplace) CLI_ARGV=(--project-remove) ;;
        ai-tools.projects.remove.clone)   CLI_ARGV=(--sandbox-remove) ;;
        ai-tools.projects.disable)        CLI_ARGV=(--project-disable) ;;
        ai-tools.projects.enable)         CLI_ARGV=(--project-enable) ;;
        ai-tools.projects.clone)          CLI_ARGV=(--sandbox-create) ;;
        ai-tools.projects.push)           CLI_ARGV=(--sandbox-push) ;;
        ai-tools.projects.lockdown)       CLI_ARGV=(--lockdown) ;;
        ai-tools.projects.handback)       CLI_ARGV=(--reclaim) ;;
        ai-tools.status)                  CLI_ARGV=(--status) ;;
        ai-tools.providers)               CLI_ARGV=(--providers) ;;
        ai-tools.audit)                   CLI_ARGV=(--audit) ;;
        ai-tools.stop)                    CLI_ARGV=(--stop) ;;
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
