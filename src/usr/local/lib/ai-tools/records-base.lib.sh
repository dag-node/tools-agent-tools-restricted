#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/records-base.lib.sh
# The record model and the report state behind every record stream a report writes for a machine consumer: the column
# registry, the severity and subject-type token sets, the two exit constants, and the fold that turns the severities
# a run noted into its exit status. The wire format is records-tsv.lib.sh, which sources this file; the public contract
# (the columns, their meaning, the escape, the identity recipe, the completion rules) is ai-tools-records(5),
# and the rules a report follows when it calls these functions are .claude/rules/records.rule.md.
#
# AI_TOOLS_RECORDS_COLUMNS is the one code-side declaration of the stream's header: `name:class` in stream order.
# The man page shows the same table for the operator, and tests/unit/records.sh holds the two to each other. A column is
# appended after `detail`; renaming, reordering or removing one is a BREAKING change, so a consumer written
# against the page keeps reading across releases. AI_TOOLS_EXIT_FINDINGS and AI_TOOLS_EXIT_UNREADABLE are the only place
# 4 and 5 are spelled in code: a caller ends a report with `ai_tools_records_get_exit_status || exit $?` and never
# writes the number
# itself.
#
# The state is three globals, reset by ai_tools_records_begin_report: the folded status, whether the header has been
# printed, and the run's `observed-at`, taken once in UTC. A report calls begin_report first, so a sourced shell
# that runs two reports does not carry one's state into the other; the file also calls it once at load, so a caller
# that writes before beginning has a valid state rather than an empty timestamp. Every function that changes state runs
# in the report's own shell (never in `$(...)`, a pipeline stage or the producer side of `< <(...)`), where a subshell
# would update a copy that the exit status never reads.
#
# The fold is one-directional: a severity a report notes can raise the status (`attention`, then `unreadable`), no
# severity lowers it, and a token outside AI_TOOLS_RECORDS_SEVERITIES folds as `unreadable`, so a token this file did
# not know cannot make a run read as clean. A report-level defect (an invalid row, a failed hash) is noted the same way
# and does not return non-zero from a library function: the consumers run under `set -e`, and a non-zero return there
# would end the script before the exit status is computed.
#
# Output-variable convention (shared with records-tsv.lib.sh): a function that writes into a caller's variable does
# so with `printf -v`, which bash resolves through its dynamic scope, so a callee local carrying the caller's name would
# catch the write. Every local in the two libraries therefore starts with `_records_`, each function's own locals carry
# a further per-function stem so a nested call cannot shadow an intermediate, and a function taking an output variable
# refuses a name that starts with `_records_` or `_AI_TOOLS_RECORDS_`, names `LC_ALL` (a local of the encoder), or is
# not a valid identifier. The refusal returns 1 without writing.
#
# Neither this file nor records-tsv.lib.sh sources msg.lib.sh: a root helper sources the data layer alone, and no
# function here emits a runtime message. Deployed 644 root:root and sourced by every principal that prints a report.

# shellcheck disable=SC2034  # include guard, read on the next source of this lib
if [[ -n "${_AI_TOOLS_RECORDS_BASE_LIB_LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_RECORDS_BASE_LIB_LOADED=1

# The stream's header, `name:class` in stream order. The class order (fixed, enum, id, path, text) is a property a unit
# test pins; there is no runtime validator for it.
# shellcheck disable=SC2034  # read by records-tsv.lib.sh, the man-page lockstep test and every consumer
readonly -a AI_TOOLS_RECORDS_COLUMNS=(
    observed-at:fixed
    occurred-at:fixed
    code:fixed
    record-id:fixed
    severity:enum
    finding:enum
    subject-type:enum
    operator:id
    item:id
    subject:path
    detail:text
)
readonly -a AI_TOOLS_RECORDS_SEVERITIES=( ok info attention unreadable )
readonly -a AI_TOOLS_RECORDS_SUBJECT_TYPES=( file directory unit agent integration project operator host )
# shellcheck disable=SC2034  # read by every report that returns an exit status
readonly AI_TOOLS_EXIT_FINDINGS=4
readonly AI_TOOLS_EXIT_UNREADABLE=5

# The report state: the folded status (`ok`, `attention`, `unreadable`), whether the header was printed, and the run's
# `observed-at`. Read and written by records-tsv.lib.sh's writer; a consumer reads them through
# ai_tools_records_get_exit_status.
_AI_TOOLS_RECORDS_STATUS=ok
_AI_TOOLS_RECORDS_HEADER_PRINTED=0
_AI_TOOLS_RECORDS_OBSERVED_AT=""

# _ai_tools_records_output_name_ok <name>: 0 when <name> may receive a `printf -v` write from these libraries.
# args: $1 the caller's variable name
_ai_tools_records_output_name_ok() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    case "$1" in
        _records_*|_AI_TOOLS_RECORDS_*|LC_ALL) return 1 ;;
    esac
    return 0
}

# _ai_tools_records_in_set <token> <member>...: 0 when <token> equals one of the members.
_ai_tools_records_in_set() {
    local _records_set_token="$1" _records_set_member
    shift
    for _records_set_member in "$@"; do
        [[ "${_records_set_token}" == "${_records_set_member}" ]] && return 0
    done
    return 1
}

# ai_tools_records_begin_report: reset the report state -- status `ok`, header not printed, `observed-at` taken now
# in UTC. The `TZ=UTC` prefix reaches the printf builtin alone, so a report's own local-time output is unchanged.
ai_tools_records_begin_report() {
    _AI_TOOLS_RECORDS_STATUS=ok
    _AI_TOOLS_RECORDS_HEADER_PRINTED=0
    TZ=UTC printf -v _AI_TOOLS_RECORDS_OBSERVED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1
}

# ai_tools_records_accumulate_severity <severity>: fold one severity into the report state. `ok` and `info` leave it,
# `attention` raises `ok`, and `unreadable` -- or any token outside the set -- raises everything. Returns 0.
# args: $1 a severity token
ai_tools_records_accumulate_severity() {
    case "$1" in
        ok|info) ;;
        attention)
            [[ "${_AI_TOOLS_RECORDS_STATUS}" == unreadable ]] || _AI_TOOLS_RECORDS_STATUS=attention ;;
        *) _AI_TOOLS_RECORDS_STATUS=unreadable ;;
    esac
    return 0
}

# ai_tools_records_is_valid_record <occurred-at> <code> <severity> <finding> <subject-type> <operator> <item> <subject>
# <detail>: 0 when the arity is nine and `severity` and `subject-type` are in their sets; 1 otherwise. A predicate
# for a conditional, independent of the wire format, so a later writer for another format reuses it.
ai_tools_records_is_valid_record() {
    (( $# == 9 )) || return 1
    _ai_tools_records_in_set "$3" "${AI_TOOLS_RECORDS_SEVERITIES[@]}" || return 1
    _ai_tools_records_in_set "$5" "${AI_TOOLS_RECORDS_SUBJECT_TYPES[@]}" || return 1
    return 0
}

# ai_tools_records_get_exit_status: return 0, AI_TOOLS_EXIT_FINDINGS or AI_TOOLS_EXIT_UNREADABLE from the folded status.
# Prints nothing and does not exit the process: a caller ends with `ai_tools_records_get_exit_status || exit $?`
# or returns the status explicitly, so the value does not depend on `set -e`.
ai_tools_records_get_exit_status() {
    case "${_AI_TOOLS_RECORDS_STATUS}" in
        ok) return 0 ;;
        attention) return "${AI_TOOLS_EXIT_FINDINGS}" ;;
        *) return "${AI_TOOLS_EXIT_UNREADABLE}" ;;
    esac
}

ai_tools_records_begin_report
