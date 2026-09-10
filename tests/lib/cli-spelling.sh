#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/cli-spelling.sh
# The one place a test spells an ai-tools command. A test names what a command DOES -- a key such as `projects.claim` --
# and this table turns the key into the tokens the deployed CLI accepts today, so no assertion in the suite carries
# a spelling. A rename of the command surface (.claude/rules/cli-grammar.rule.md) edits this file alone;
# tests/integration/cli-flags.sh then re-asserts every effect against the new spelling, which is what makes that file
# the retention proof for the conversion.
#
# cli_cmd <key>   fills CLI_ARGV with the command's tokens (one today; two once a command is
#                 a noun and a verb), and returns 1 for an unknown key so a typo in a row fails
#                 the row rather than running the bare binary.
# cli_flag <key>  prints one option token. A `.short` key is the one-letter form a verb accepts
#                 beside the long one; `--dry-run` has none, so `-n` stays free for a `--no`.

# shellcheck disable=SC2034  # CLI_ARGV is the output, read by the caller's shell
cli_cmd() {
    case "$1" in
        help)             CLI_ARGV=(--help) ;;
        version)          CLI_ARGV=(--version) ;;
        projects.list)    CLI_ARGV=(--list) ;;
        projects.create)  CLI_ARGV=(--project-create) ;;
        projects.claim)   CLI_ARGV=(--project-claim) ;;
        projects.unclaim) CLI_ARGV=(--project-unclaim) ;;
        projects.remove)  CLI_ARGV=(--project-remove) ;;
        projects.disable) CLI_ARGV=(--project-disable) ;;
        projects.enable)  CLI_ARGV=(--project-enable) ;;
        projects.clone)   CLI_ARGV=(--sandbox-create) ;;
        projects.push)    CLI_ARGV=(--sandbox-push) ;;
        # The clone kind's removal is its own command today and folds into projects.remove with the conversion; a row
        # that drives it keeps this key so the fold is one edit here.
        sandbox.remove)   CLI_ARGV=(--sandbox-remove) ;;
        projects.lockdown) CLI_ARGV=(--lockdown) ;;
        projects.reclaim) CLI_ARGV=(--reclaim) ;;
        status)           CLI_ARGV=(--status) ;;
        providers)        CLI_ARGV=(--providers) ;;
        audit)            CLI_ARGV=(--audit) ;;
        stop)             CLI_ARGV=(--stop) ;;
        *) printf 'cli-spelling: unknown command key: %s\n' "$1" >&2; return 1 ;;
    esac
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
        keep-entry)     printf -- '--keep-entry' ;;
        since)          printf -- '--since' ;;
        from)           printf -- '--from' ;;
        branch)         printf -- '--branch' ;;
        dir)            printf -- '--dir' ;;
        all)            printf -- '--all' ;;
        *) printf 'cli-spelling: unknown flag key: %s\n' "$1" >&2; return 1 ;;
    esac
}
