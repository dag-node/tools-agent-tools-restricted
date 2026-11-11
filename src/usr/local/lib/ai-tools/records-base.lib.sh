#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/records-base.lib.sh
# The record model and the report state behind every record stream a report writes for a machine consumer: the column
# registry, the severity and subject-type token sets, the two exit constants, the fold that turns the severities a run
# noted into its exit status, the readers of what is at a subject's path, and the reader a report runs a collector
# through. The wire format is records-tsv.lib.sh, which sources this file; the public contract (the columns, their
# meaning, the escape, the identity recipe, the completion rules) is ai-tools-records(5), and the rules a report follows
# when it calls these functions are
# .claude/rules/records.rule.md.
#
# AI_TOOLS_RECORDS_BASE__COLUMNS is the one code-side declaration of the stream's header: `name:class` in stream order.
# The man page shows the same table for the operator, and tests/unit/records.sh holds the two to each other. A column is
# appended after `detail`; renaming, reordering or removing one is a BREAKING change, so a consumer written
# against the page keeps reading across releases. AI_TOOLS_RECORDS_BASE__EXIT_FINDINGS
# and AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE are the only place 4 and 5 are spelled in code: a caller ends a report
# with `ai_tools_records_base__get_exit_status || exit $?` and never writes the number
# itself.
#
# The state is three globals, reset by ai_tools_records_base__begin_report: the folded status, whether the header has
# been printed, and the run's `observed-at`, taken once in UTC. A report calls begin_report first, so a sourced shell
# that runs two reports does not carry one's state into the other; the file also calls it once at load, so a caller
# that writes before beginning has a valid state rather than an empty timestamp. Every function that changes state runs
# in the report's own shell (never in `$(...)`, a pipeline stage or the producer side of `< <(...)`), where a subshell
# would update a copy that the exit status never reads.
#
# The fold is one-directional: a severity a report notes can raise the status (`attention`, then `unreadable`), no
# severity lowers it, and a token outside AI_TOOLS_RECORDS_BASE__SEVERITIES folds as `unreadable`, so a token this file
# did not know cannot make a run read as clean. A report-level defect (an invalid row, a failed hash) is noted the same
# way and does not return non-zero from a library function: the consumers run under `set -e`, and a non-zero return
# there would end the script before the exit status is computed.
#
# Output-variable convention (shared with records-tsv.lib.sh): a function that writes into a caller's variable does
# so with `printf -v`, which bash resolves through its dynamic scope, so a callee local carrying the caller's name would
# catch the write. Every local in the two libraries therefore starts with `_records_`, each function's own locals carry
# a further per-function stem so a nested call cannot shadow an intermediate, and a function taking an output variable
# refuses a name that starts with `_records_`, `_AI_TOOLS_RECORDS_` or `AI_TOOLS_RECORDS_`, names `LC_ALL` (a local
# of the encoder), or is not a valid identifier. The refusal returns 1 without writing.
#
# Neither this file nor records-tsv.lib.sh sources msg.lib.sh: a root helper sources the data layer alone, and no
# function here emits a runtime message. Deployed 644 root:root and sourced by every principal that prints a report.

# shellcheck disable=SC2034  # include guard, read on the next source of this lib
if [[ -n "${_AI_TOOLS_RECORDS_BASE__LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_RECORDS_BASE__LOADED=1

# The stream's header, `name:class` in stream order. The class order (fixed, enum, id, path, text) is a property a unit
# test pins; there is no runtime validator for it.
# shellcheck disable=SC2034  # read by records-tsv.lib.sh, the man-page lockstep test and every consumer
readonly -a AI_TOOLS_RECORDS_BASE__COLUMNS=(
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
readonly -a AI_TOOLS_RECORDS_BASE__SEVERITIES=( ok info attention unreadable )
readonly -a AI_TOOLS_RECORDS_BASE__SUBJECT_TYPES=( file directory link unit agent integration project operator host )
# shellcheck disable=SC2034  # read by every report that returns an exit status
readonly AI_TOOLS_RECORDS_BASE__EXIT_FINDINGS=4
readonly AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE=5
# The most runs ai_tools_records_base__read_collector gives a collector whose status bash did not return.
readonly _AI_TOOLS_RECORDS_BASE__MAX_COLLECTOR_ATTEMPTS=3

# The report state: the folded status (`ok`, `attention`, `unreadable`), whether the header was printed, and the run's
# `observed-at`. Read and written by records-tsv.lib.sh's writer; a consumer reads them through
# ai_tools_records_base__get_exit_status.
_AI_TOOLS_RECORDS_BASE__STATUS=ok
AI_TOOLS_RECORDS_BASE__HEADER_PRINTED=0
AI_TOOLS_RECORDS_BASE__OBSERVED_AT=""

# ai_tools_records_base__is_output_name_valid <name>: 0 when <name> may receive a `printf -v` write from these
# libraries.
# args: $1 the caller's variable name
ai_tools_records_base__is_output_name_valid() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    case "$1" in
        _records_*|_AI_TOOLS_RECORDS_*|AI_TOOLS_RECORDS_*|LC_ALL) return 1 ;;
    esac
    return 0
}

# _ai_tools_records_base__is_in_set <token> <member>...: 0 when <token> equals one of the members.
_ai_tools_records_base__is_in_set() {
    local _records_set_token="$1" _records_set_member
    shift
    for _records_set_member in "$@"; do
        [[ "${_records_set_token}" == "${_records_set_member}" ]] && return 0
    done
    return 1
}

# ai_tools_records_base__begin_report: reset the report state -- status `ok`, header not printed, `observed-at` taken
# now in UTC. The `TZ=UTC` prefix reaches the printf builtin alone, so a report's own local-time output is unchanged.
ai_tools_records_base__begin_report() {
    _AI_TOOLS_RECORDS_BASE__STATUS=ok
    AI_TOOLS_RECORDS_BASE__HEADER_PRINTED=0
    TZ=UTC printf -v AI_TOOLS_RECORDS_BASE__OBSERVED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1
}

# ai_tools_records_base__accumulate_severity <severity>: fold one severity into the report state. `ok` and `info` leave
# it, `attention` raises `ok`, and `unreadable` -- or any token outside the set -- raises everything. Returns 0.
# args: $1 a severity token
ai_tools_records_base__accumulate_severity() {
    case "$1" in
        ok|info) ;;
        attention)
            [[ "${_AI_TOOLS_RECORDS_BASE__STATUS}" == unreadable ]] || _AI_TOOLS_RECORDS_BASE__STATUS=attention ;;
        *) _AI_TOOLS_RECORDS_BASE__STATUS=unreadable ;;
    esac
    return 0
}

# ai_tools_records_base__is_valid_record <occurred-at> <code> <severity> <finding> <subject-type> <operator> <item>
# <subject> <detail>: 0 when the arity is nine and `severity` and `subject-type` are in their sets; 1 otherwise.
# A predicate for a conditional, independent of the wire format, so a later writer for another format reuses it.
ai_tools_records_base__is_valid_record() {
    (( $# == 9 )) || return 1
    _ai_tools_records_base__is_in_set "$3" "${AI_TOOLS_RECORDS_BASE__SEVERITIES[@]}" || return 1
    _ai_tools_records_base__is_in_set "$5" "${AI_TOOLS_RECORDS_BASE__SUBJECT_TYPES[@]}" || return 1
    return 0
}

# _ai_tools_records_base__get_subject_type <variable> <type text>: write into <variable> the subject-type for the file
# type stat(1) prints for `%F` under LC_ALL=C: `link`, `directory`, or `file` for a regular file, empty or not. Returns
# 1 without writing for any other text. The one mapping the subject readers share; <variable> is a local of the reader
# that calls it.
_ai_tools_records_base__get_subject_type() {
    case "$2" in
        'symbolic link')                     printf -v "$1" link ;;
        directory)                           printf -v "$1" directory ;;
        'regular file'|'regular empty file') printf -v "$1" file ;;
        *)                                   return 1 ;;
    esac
}

# _ai_tools_records_base__is_absence_reported <stat's error text>: 0 when stat(1) under LC_ALL=C reported ENOENT
# or ENOTDIR for the lstat, which is no entry at the path; 1 for any other text.
_ai_tools_records_base__is_absence_reported() {
    case "$1" in
        *': No such file or directory'|*': Not a directory') return 0 ;;
    esac
    return 1
}

# ai_tools_records_base__read_subject_type <path>: print the observed subject-type of the entry at <path>, from one
# lstat(2) of its last component: `link` for a symbolic link, `directory` for a directory, `file` for a regular file.
# Returns 2 without printing where the lstat fails with ENOENT or ENOTDIR (no entry at <path>), and 1 without printing
# for any other entry type (a FIFO, a socket, a device) and for a read that did not complete (EACCES, an I/O error, no
# stat(1), output it does not recognize). It does not supply an expected type; what a caller writes on status 1 and 2 is
# records.rule.md's (ref-section-u5t7).
#
# The result labels a row and is not a check: the path may sit in a directory another account writes, the entry can
# change before or after the one read, and the ancestors are resolved as the kernel resolves them, symbolic links
# included. A caller writes it into the subject-type column and does not branch on it; a decision about the entry opens
# it under a trusted directory descriptor and inspects that descriptor instead.
# args: $1 the subject's path
ai_tools_records_base__read_subject_type() {
    local _records_subject_type_described _records_subject_type_token
    # `stat` without `-L` reads the entry itself; LC_ALL=C pins the type names and the two error texts this matches.
    # The output is matched whole, so a line stat(1) adds is an unrecognized read rather than a type.
    if _records_subject_type_described="$(LC_ALL=C stat -c %F -- "$1" 2>&1)"; then
        _ai_tools_records_base__get_subject_type _records_subject_type_token "${_records_subject_type_described}" \
            || return 1
        printf '%s' "${_records_subject_type_token}"
        return 0
    fi
    _ai_tools_records_base__is_absence_reported "${_records_subject_type_described}" && return 2
    return 1
}

# ai_tools_records_base__read_subject_attributes <path> <type-var> <owner-var> <mode-var>: the read
# of ai_tools_records_base__read_subject_type with the owner and the mode the same lstat(2) returned. Writes
# the subject-type into <type-var>, the owner as `<user>:<group>` by name into <owner-var>, and the permission bits
# in octal as stat(1) prints them, without leading zeros, into <mode-var>. One stat(1) run prints the three, so they
# describe one inode, and a caller that needs them forks once and not once per value.
#
# Returns as that function does, writing no variable: 2 where no entry is at <path>, and 1 for any other entry type
# and for a read that did not complete, which includes output that is not the three lines it expects (an account name
# holding a line feed). Returns 1 without reading for another argument count, a name
# ai_tools_records_base__is_output_name_valid refuses, or one name given twice. The values label a row as the type does.
# args: $1 the subject's path  $2 $3 $4 the caller's variables for the type, the owner and the mode
ai_tools_records_base__read_subject_attributes() {
    (( $# == 4 )) || return 1
    ai_tools_records_base__is_output_name_valid "$2" && ai_tools_records_base__is_output_name_valid "$3" \
        && ai_tools_records_base__is_output_name_valid "$4" || return 1
    [[ "$2" != "$3" && "$2" != "$4" && "$3" != "$4" ]] || return 1
    local _records_subject_attributes_printed _records_subject_attributes_type
    local -a _records_subject_attributes_lines=()
    if ! _records_subject_attributes_printed="$(LC_ALL=C stat --printf '%F\n%U:%G\n%a\n' -- "$1" 2>&1)"; then
        _ai_tools_records_base__is_absence_reported "${_records_subject_attributes_printed}" && return 2
        return 1
    fi
    mapfile -t _records_subject_attributes_lines <<<"${_records_subject_attributes_printed}"
    (( ${#_records_subject_attributes_lines[@]} == 3 )) || return 1
    _ai_tools_records_base__get_subject_type _records_subject_attributes_type \
        "${_records_subject_attributes_lines[0]}" || return 1
    [[ "${_records_subject_attributes_lines[1]}" == ?*:?* \
        && "${_records_subject_attributes_lines[2]}" =~ ^[0-7]{1,4}$ ]] || return 1
    printf -v "$2" '%s' "${_records_subject_attributes_type}"
    printf -v "$3" '%s' "${_records_subject_attributes_lines[1]}"
    printf -v "$4" '%s' "${_records_subject_attributes_lines[2]}"
    return 0
}

# ai_tools_records_base__read_collector <lines-var> <status-var> <command> [<arg>...]: run <command> as a collector,
# write its standard output into the caller's array <lines-var>, one element per line with the line feed removed,
# and its exit status into <status-var>. Returns 0 once the collector ran, whatever its status, and 1 without running it
# for fewer than three arguments, a name ai_tools_records_base__is_output_name_valid refuses, or one name given twice.
# The consumer loops over the array after the call, in the report's own shell, and reports a non-zero status itself.
#
# <command> and its arguments are run as given, as one simple command with the caller's identity: no word is parsed
# again as shell, and no name is checked against a list. A caller passes a function or a program it names in its own
# source, and does not pass a command word read from a file, a collector's output or another account's input.
#
# The collector runs in a process substitution, so `errexit` is in force inside it where the caller has it set, also
# when this function is called under an `if` or ahead of `||`: a collector function that reaches a failed command ends
# there with that status and does not print a later line. `out="$(collector)" || status=$?` runs the same function
# with `errexit` ignored, to its last command, and reads 0. A collector that needs a redirection, an environment
# assignment or a pipe is a function that carries it, since the arguments are run as one simple command.
#
# The status is read with `wait` on the PID saved by the statement that opened the substitution, and bash does not
# return it for every child. process_substitute (subst.c) unblocks SIGCHLD in restore_pipeline before procsub_add
# records the child, and waitchld (jobs.c) drops the status of a child it reaps between the two; a child whose PID
# the shell still holds an earlier substitution's record for is not found either. `wait` then returns -1 (bash 5.2)
# or 127 (bash 5.3), whatever the collector exited with, and `$?` expands to that value as written: bash reduces
# a function's `return` to eight bits and not a builtin's status, so the 5.2 value reads `-1` and not `255`, which stays
# a collector's own exit. On either value this function discards the lines and runs the collector again,
# _AI_TOOLS_RECORDS_BASE__MAX_COLLECTOR_ATTEMPTS runs at most, and the last run's lines and status are the result:
# a collector that exits 127 itself, a command not found, runs that many times and reads 127. A collector is therefore
# a command that reads, so a second run observes the host again and does not repeat a change to it.
# args: $1 the caller's array for the lines  $2 the caller's variable for the exit status  $3... the collector
ai_tools_records_base__read_collector() {
    (( $# >= 3 )) || return 1
    ai_tools_records_base__is_output_name_valid "$1" || return 1
    ai_tools_records_base__is_output_name_valid "$2" || return 1
    [[ "$1" != "$2" ]] || return 1
    local _records_collector_lines_name="$1" _records_collector_status_name="$2"
    local _records_collector_fd _records_collector_pid _records_collector_status _records_collector_attempt
    shift 2
    for (( _records_collector_attempt = 1; ; _records_collector_attempt++ )); do
        exec {_records_collector_fd}< <("$@"); _records_collector_pid=$!
        mapfile -t -u "${_records_collector_fd}" "${_records_collector_lines_name}"
        exec {_records_collector_fd}<&-
        _records_collector_status=0
        wait "${_records_collector_pid}" 2>/dev/null || _records_collector_status=$?
        case "${_records_collector_status}" in
            -1|127) (( _records_collector_attempt < _AI_TOOLS_RECORDS_BASE__MAX_COLLECTOR_ATTEMPTS )) || break ;;
            *) break ;;
        esac
    done
    printf -v "${_records_collector_status_name}" '%s' "${_records_collector_status}"
    return 0
}

# ai_tools_records_base__get_exit_status: return 0, AI_TOOLS_RECORDS_BASE__EXIT_FINDINGS
# or AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE from the folded status. Prints nothing and does not exit the process:
# a caller ends with `ai_tools_records_base__get_exit_status || exit $?` or returns the status explicitly, so the value
# does not depend on `set -e`.
ai_tools_records_base__get_exit_status() {
    case "${_AI_TOOLS_RECORDS_BASE__STATUS}" in
        ok) return 0 ;;
        attention) return "${AI_TOOLS_RECORDS_BASE__EXIT_FINDINGS}" ;;
        *) return "${AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE}" ;;
    esac
}

ai_tools_records_base__begin_report
