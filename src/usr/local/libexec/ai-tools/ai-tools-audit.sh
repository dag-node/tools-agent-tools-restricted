#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-audit
# Answers one question: what was refused, rejected, stranded or flagged BETWEEN two points in time? It reports EVENTS,
# never current state -- a condition recorded here may have been resolved since, and confirming that is
# `ai-tools status`'s job, not this one's. Conflating the two invites acting on a finding that is already fixed.
# The detections already exist and are already recorded -- what they lacked was a reader, and a detection nobody reads
# is decoration.
#
# It does not invent a detection, nor parse per-case wording. The root-only file sink already encodes severity in its
# line format (`<ts> <LEVEL> [<pid>] <msg>`, written by log.lib.sh and, in the same format, by the handback daemon),
# so a finding is simply a line at NOTICE or higher. That is what keeps this from drifting: a helper that adds a new
# warning is reported here the day it ships, with no pattern to update.
#
# THREE SOURCES, NOT EQUAL, AND SAID SO. /var/log/ai-tools/*.log is 700 root:root, root writers only, so the sandbox
# account can neither read nor append to it: those lines are EVIDENCE and are what this command reports
# as authoritative. A launch refusal is the exception -- it is written by ai-tools-run, which runs AS the sandbox
# account and therefore reaches journald only, under a tag whose legitimate writer is that same account. Those lines are
# the session's own account of itself, reportable but not proof, and are shown in a separately titled section rather
# than mixed into the first (see logging.rule.md). The third is the KERNEL's: an exec of an agent
# entrypoint by a confined session, which the SELinux core module audits with an `auditallow` on the one permission
# that exec takes (execute_no_trans on ai_tools_exec_t by ai_tools_t; the policy source ai_tools.te), so the kernel writes
# an AVC `granted` record for each one. A session launch enters the domain through a transition, which is a different
# permission, so a launch is not recorded and does not need telling apart. No process of the sandbox account writes
# that trail and none can suppress a record in it, so it is evidence of the first kind and answers what neither
# of the others can -- an agent started from inside a session runs in its parent's unit, so the launch and the handbacks
# both carry the parent's identity (see launch.rule.md).
#
# WHAT THE CLASSIFICATION IS AND IS NOT. One recorded exec is ordinary: an agent dispatching a tool it bundles
# through its own binary (claude-code for `rg`, `ugrep` and `bfs`; codex for `apply_patch`), told by a bare argv0. It is
# counted and summarized rather than reported as a finding. The argv0 is the caller's to arrange, so the split is
# a NOISE FILTER and not a control: the record is the evidence, and it is written either way. Every other record is
# a finding, including one whose exe no installed manifest claims, so a manifest this helper cannot read yields MORE
# findings rather than fewer.
#
# Root-only: the file sink is unreadable to anyone else, so there is no trail for a non-root caller to do here. Reached
# through `sudo ai-tools audit` with no NOPASSWD grant, like ai-tools-lockdown and ai-tools-reclaim.
#
# Usage:  ai-tools-audit [--since <when>]        <when> is anything date(1) parses
#
# Installed 750 root:root, so only root runs it. Its domain rule is cli.rule.md.

set -euo pipefail

# The severity floor for a finding. NOTICE is included deliberately: ai-tools-chown records a breached secret
# at that level, and a leaked credential is the single most actionable thing this command can surface.
readonly FINDING_LEVELS='NOTICE|WARNING|ERROR'

# Default window. Long enough to cover a weekend and a missed morning, short enough that the first run on a long-lived
# host is not a wall of history the operator stops reading.
readonly DEFAULT_SINCE='7 days ago'

readonly SANDBOX_USER='@SANDBOX_USER@'

# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads. Matched inline: these refusals answer before the renderer is loaded, and each
# keeps its own exit status at the call site.
warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-audit: %s\n' "$*" >&2
}

# Shared leveled logger. This helper does not write an audit line of its own -- reading a trail is not an event worth
# adding to it -- but it uses the sanitizer, which reduces a log line to safe-for-display characters before it reaches
# the operator's terminal. That is load-bearing here, not decorative: every line this command prints came from a file
# recording agent-influenced paths, so it is required fail-closed for the same reason ai-tools-chown
# and ai-tools-lockdown require it (see logging.rule.md).
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
source "${LOG_LIB}" 2>/dev/null || {
    warn MSG-T3T7 "cannot load ${LOG_LIB} -- refusing to print log text unsanitized"
    exit 1
}

# Shared message renderer, REQUIRED like every other user-facing consumer (msg.lib.sh).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source "${MSG_LIB}"

# Provider manifests, for the kernel-record section alone: which file is which agent's entrypoint. Loaded
# BEST-EFFORT, unlike the logger and the renderer, because a failure here is
# already the safe one -- with no manifest to match, every recorded exec is reported as a finding naming a file no
# manifest claims, so a library that will not load costs noise rather than coverage.
readonly PROVIDERS_LIB="/usr/local/lib/ai-tools/providers.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source "/usr/local/lib/ai-tools/conf.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/providers.lib.sh
source "${PROVIDERS_LIB}" 2>/dev/null || true

# ── Arguments ────────────────────────────────────────────────────────────────────────────────
# parse_command_line -- set SINCE from the command line, refusing an unknown option rather than reading past it.
parse_command_line() {
    SINCE="${DEFAULT_SINCE}"
    while (( $# )); do
        case "$1" in
            --since)
                [[ -n "${2:-}" ]] || { warn MSG-Y4C6 "--since needs a value"; exit 2; }
                SINCE="$2"; shift 2 ;;
            -*) warn MSG-Q7A2 "unknown option: $1"; exit 2 ;;
            *)  warn MSG-N4V9 "unexpected argument: $1"; exit 2 ;;
        esac
    done
    readonly SINCE
}

# assert_root -- refuse a non-root caller. Named apart from the shell's own `require_root` idiom so that sourcing this
# file into a test harness does not displace the harness's function of that name.
assert_root() {
    [[ "$(id -u)" == "0" ]] || {
        ai_tools_msg_error MSG-K9C5 "ai-tools-audit must run as root: the trail it reads is 700 root:root" \
            "run it as: sudo ai-tools audit"
        exit 1
    }
}

# resolve_window -- normalize the window once, into CUTOFF_EPOCH and SINCE_DISPLAY. A value date(1) cannot parse is
# refused rather than silently treated as "everything", which would turn a typo into a reassuring wall of old
# findings.
resolve_window() {
    CUTOFF_EPOCH="$(date -d "${SINCE}" +%s 2>/dev/null)" || {
        ai_tools_msg_error MSG-Y3M7 "ai-tools-audit: --since value not understood: ${SINCE}" \
            "give it anything date(1) parses, e.g. '2 days ago', 'yesterday', '2026-08-01'"
        exit 2
    }
    readonly CUTOFF_EPOCH
    SINCE_DISPLAY="$(date -d "@${CUTOFF_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "${SINCE}")"
    readonly SINCE_DISPLAY
}

# ── The authoritative source: the root-only file sink ────────────────────────────────────────
# collect_file_findings -- PRINT one `<component>|<timestamp>|<level>|<message>` per finding. Two passes by design:
# a cheap severity grep over the whole file, then a date comparison only on the lines that survived it. Findings are
# rare, so the expensive half runs on almost no line.
collect_file_findings() {
    local log_file component line entry_timestamp entry_level entry_epoch entry_message
    for log_file in "${AI_TOOLS_LOG_DIR}"/*.log; do
        [[ -f "${log_file}" && -r "${log_file}" ]] || continue
        component="$(basename -- "${log_file}" .log)"
        while IFS= read -r line; do
            # `<ts> <LEVEL> [<pid>] <message>` -- anything else is not a record this format produced and is left alone
            # rather than guessed at.
            [[ "${line}" =~ ^([^[:space:]]+)[[:space:]]+(${FINDING_LEVELS})[[:space:]]+\[[0-9]+\][[:space:]]+(.*)$ ]] || continue
            entry_timestamp="${BASH_REMATCH[1]}"
            entry_level="${BASH_REMATCH[2]}"
            entry_message="${BASH_REMATCH[3]}"
            entry_epoch="$(date -d "${entry_timestamp}" +%s 2>/dev/null)" || continue
            (( entry_epoch >= CUTOFF_EPOCH )) || continue
            printf '%s|%s|%s|%s\n' "${component}" "${entry_timestamp}" "${entry_level}" \
                "$(ai_tools_log_sanitize "${entry_message}")"
        done < <(grep -E "[[:space:]](${FINDING_LEVELS})[[:space:]]" "${log_file}" 2>/dev/null || true)
    done
}

# ── The secondary source: launch refusals, which only journald can hold ──────────────────────
# collect_launch_refusals -- PRINT one `launch|<timestamp>|WARNING|<message>` per REFUSED line ai-tools-run recorded,
# in the same shape as a file finding so it collapses through the same renderer: a refusal that recurs on every launch
# attempt would otherwise flood the report exactly as the handback lines did. Filtered by the sandbox account's uid
# as every documented query is: the tag alone does not establish identity, and here the legitimate writer IS the account
# under scrutiny -- which is exactly why these are reported apart from the file sink's evidence.
collect_launch_refusals() {
    local sandbox_uid line entry_timestamp entry_message
    command -v journalctl >/dev/null 2>&1 || return 0
    sandbox_uid="$(id -u "${SANDBOX_USER}" 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ "${line}" =~ ^([0-9-]+[[:space:]][0-9:]+)[[:space:]]+(.*)$ ]] || continue
        entry_timestamp="${BASH_REMATCH[1]}"
        entry_message="${BASH_REMATCH[2]}"
        printf 'launch|%s|WARNING|%s\n' "${entry_timestamp}" \
            "$(ai_tools_log_sanitize "${entry_message}")"
    done < <(journalctl -t ai-tools-run _UID="${sandbox_uid}" \
                --since "@${CUTOFF_EPOCH}" --no-pager \
                --output=short-iso --output-fields=MESSAGE 2>/dev/null \
             | grep -F 'REFUSED:' | sed -E 's/^([^ ]+) [^ ]+ [^:]+: /\1 /' || true)
}

# ── Report ───────────────────────────────────────────────────────────────────────────────────
# render_findings -- read `<component>|<ts>|<level>|<message>` on stdin and print one line per DISTINCT finding, most
# serious and most recent first.
#
# Collapsing is not cosmetic, it is what makes the command usable. A recurring condition writes one line per occurrence
# -- the handback daemon's refusals alone run to hundreds over a week on a host that exercises them -- and a report
# that lists each one buries the single ERROR that needs acting on under a wall of a condition already understood.
# That is the same reason INFO is out of scope entirely: an audit nobody finishes reading is one nobody acts on.
#
# Findings are grouped by their message with digit runs replaced by `#`, so occurrences that differ only in a pid,
# a count, or a timestamp collapse into one line carrying the number of times it happened and the most recent example
# in full. No occurrence is hidden -- the count states what was folded, and the underlying files are named with it.
#
# Ordering is by severity first and recency second, because those are the two questions actually being asked: what is
# worst, and is it still happening.
render_findings() {
    awk -F'|' '
        {
            component = $1; entry_timestamp = $2; entry_level = $3; entry_message = $4
            normalized = entry_message
            gsub(/[0-9]+/, "#", normalized)
            key = component SUBSEP entry_level SUBSEP normalized
            occurrences[key]++
            if (entry_timestamp > last_seen[key]) {
                last_seen[key] = entry_timestamp
                most_recent[key] = entry_message
            }
            finding_component[key] = component
            finding_level[key] = entry_level
        }
        END {
            for (key in occurrences) {
                severity_rank = (finding_level[key] == "ERROR") ? 1 \
                              : (finding_level[key] == "WARNING") ? 2 : 3
                printf "%d|%s|%s|%d|%s\n", severity_rank, last_seen[key],
                       finding_component[key], occurrences[key], most_recent[key]
            }
        }' \
    | sort -t'|' -k1,1n -k2,2r \
    | awk -F'|' '
        {
            severity_rank = $1; last_seen = $2; component = $3
            occurrences = $4; most_recent = $5
            level = (severity_rank == 1) ? "ERROR" : (severity_rank == 2) ? "WARNING" : "NOTICE"
            # The date alone: the time of the latest of several occurrences is not a fact worth
            # a column, and the day is what an operator correlates against.
            split(last_seen, timestamp_parts, "T")
            printf "  %-7s  %-10s  %-9s %5dx  %s\n", level, timestamp_parts[1], component,
                   occurrences, most_recent
        }'
}

# ── The kernel's own source: an agent entrypoint exec'd from inside a session ─────────────────
# The core SELinux module carries `auditallow ai_tools_t ai_tools_exec_t:file execute_no_trans;`, so the kernel writes
# an AVC `granted` record each time the confined domain execs a file carrying its own entry type without a transition --
# which is an entrypoint started from inside a session, and only that: a launch enters the domain through `entrypoint`,
# a different permission, and does not fire it. The three ENTRYPOINT_EXEC_* constants are what the parser holds a record
# to; they are the policy's, and a record carrying any other pair is not this section's.
readonly ENTRYPOINT_EXEC_SUBJECT_TYPE='ai_tools_t'
readonly ENTRYPOINT_EXEC_OBJECT_TYPE='ai_tools_exec_t'
readonly ENTRYPOINT_EXEC_PERMISSION='execute_no_trans'
readonly SELINUX_CORE_MODULE='ai_tools'

# entrypoint_exec_state -- PRINT which of four states this host is in, which decides what the section can say:
#   no-auditd    no ausearch/auditctl, kernel auditing switched off, or no daemon writing the log: the records
#                have nowhere to land that this helper reads
#   no-selinux   SELinux disabled, or the core module not loaded: no policy rule writes the records
#   no-rule      the loaded core module does not carry the auditallow for the exec (an older build), read with sesearch
#   loaded       the rule is in force, so an empty window means no such exec happened
# The diagnostic states are not findings (the reading was not made, and a missing detector is a host condition), so they
# leave the exit status alone -- the same rule `status` follows for a reading it could not make.
entrypoint_exec_state() {
    if ! command -v ausearch >/dev/null 2>&1 || ! command -v auditctl >/dev/null 2>&1; then
        printf 'no-auditd\n'; return 0
    fi
    local audit_status
    audit_status="$(auditctl -s 2>/dev/null)" || audit_status=""
    if [[ -z "${audit_status}" ]] \
            || [[ "${audit_status}" =~ (^|[[:space:]])enabled[[:space:]]+0($|[[:space:]]) ]] \
            || [[ "${audit_status}" =~ (^|[[:space:]])pid[[:space:]]+0($|[[:space:]]) ]]; then
        printf 'no-auditd\n'; return 0
    fi
    local mode
    mode="$(getenforce 2>/dev/null)" || mode=""
    [[ "${mode}" == Enforcing || "${mode}" == Permissive ]] || { printf 'no-selinux\n'; return 0; }
    # THE LISTINGS ARE CAPTURED, NOT PIPED. `semodule -l | grep -q` loses the answer on a host with more modules than
    # a pipe buffer holds: grep exits at the match, the writer dies of SIGPIPE writing the rest, and `pipefail` turns
    # that into "no match" -- reporting a loaded module as absent. semodule prints a module's name alone
    # or with a version column, by release; either is the module being loaded.
    local modules
    modules="$(semodule -l 2>/dev/null)" || modules=""
    grep -qE "^${SELINUX_CORE_MODULE}([[:space:]]|$)" <<<"${modules}" || { printf 'no-selinux\n'; return 0; }
    # sesearch (setools) is optional; without it the module's presence is the reading.
    if command -v sesearch >/dev/null 2>&1; then
        local rules
        rules="$(sesearch --auditallow -s "${ENTRYPOINT_EXEC_SUBJECT_TYPE}" -t "${ENTRYPOINT_EXEC_OBJECT_TYPE}" \
                    -c file -p "${ENTRYPOINT_EXEC_PERMISSION}" 2>/dev/null)" || rules=""
        grep -q '^auditallow ' <<<"${rules}" || { printf 'no-rule\n'; return 0; }
    fi
    printf 'loaded\n'
}

# THE RECORDS ARE READ RAW, AND THAT IS A SECURITY CHOICE. A path and an argv are the agent's to compose, and the audit
# format already answers that: auditd hex-encodes any untrusted string holding a space, a quote or a control byte,
# so every field arrives as ONE token on ONE line -- a quoted literal, or hex. `ausearch -i` would decode those back
# to their literal bytes before this helper ever saw them, so an argv0 carrying a newline would arrive as a second LINE,
# and a line beginning `type=SYSCALL` is one this parser reads: a session could then name its own record's exe and have
# its exec reported as another agent's expected dispatch, or kept out of the report altogether. Decoding here instead,
# after the line structure is fixed, is what keeps a record's fields data rather than input.
#
# audit_field <line> <name> -- PRINT the raw token of `<name>=` in a record line, one layer of quotes removed. Empty
# when the field is absent. The result is the FORMAT's value, not yet a value to print: see audit_record_field.
audit_field() {
    local line="$1" name="$2"
    if [[ "${line}" =~ (^|[[:space:]])"${name}"=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    elif [[ "${line}" =~ (^|[[:space:]])"${name}"=([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# audit_string_field <line> <name> -- PRINT an UNTRUSTED string field (a path, an argv word), decoded. The audit
# format's own rule decides which form it is in: quoted means the string held no byte needing encoding, so it is
# literal; unquoted means auditd hex-encoded it. A value in neither form is taken as it stands rather than guessed at.
# The hex is clamped before decoding, since an argv is as long as its caller made it and a report is read by a person.
audit_string_field() {
    local line="$1" name="$2" raw
    if [[ "${line}" =~ (^|[[:space:]])"${name}"=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"; return 0
    fi
    raw="$(audit_field "${line}" "${name}")"
    [[ -n "${raw}" ]] || return 0
    if [[ "${raw}" =~ ^([0-9A-Fa-f][0-9A-Fa-f])+$ ]]; then
        printf '%s' "$(audit_hex_decode "${raw:0:AUDIT_FIELD_HEX_LIMIT}")"
    else
        printf '%s' "${raw}"
    fi
}

# A field is clamped twice: before it is decoded, so a megabyte of argv is never held in full, and again after it is
# sanitized, which is the clamp that MARKS the cut. The decode limit is derived one byte longer than the display limit
# (two hex characters to the byte) precisely so the second clamp is the one that fires -- cutting at exactly the display
# limit would leave a truncated value reading as a complete one.
readonly AUDIT_FIELD_DISPLAY_LIMIT=200
readonly AUDIT_FIELD_HEX_LIMIT=$(( (AUDIT_FIELD_DISPLAY_LIMIT + 1) * 2 ))

# audit_hex_decode <hex> -- PRINT the bytes a hex-encoded audit field holds. Whatever comes out is untrusted text
# and reaches a terminal only through audit_record_field.
audit_hex_decode() {
    local hex="$1" escaped="" index
    for (( index = 0; index < ${#hex}; index += 2 )); do
        escaped+="\\x${hex:index:2}"
    done
    printf '%b' "${escaped}"
}

# audit_record_field <field> -- reduce one record field to something safe to print and safe to carry
# through the pipe-delimited record format, the same treatment every untrusted string reaching a sink or a terminal gets
# (see logging.rule.md). ai_tools_log_sanitize is the allowlist -- printable ASCII alone, so a decoded
# newline, terminal escape or bidi byte becomes `?`; the pipe is replaced after it, since a value carrying one would
# fabricate a column in the rendered table; and the result is clamped, marked where it was cut.
audit_record_field() {
    local value; value="$(ai_tools_log_sanitize "$1")"
    value="${value//|/?}"
    if (( ${#value} > AUDIT_FIELD_DISPLAY_LIMIT )); then
        value="${value:0:AUDIT_FIELD_DISPLAY_LIMIT}..."
    fi
    printf '%s' "${value}"
}

# build_agent_entrypoint_map -- fill AGENT_NAMES/AGENT_PATTERNS from the installed manifests, one entry per agent
# declaring an entrypoint_fcontext, enabled or not: a disabled agent whose package is still in the tree is exactly
# the case this section exists for. Leaves the arrays empty when the resolver is unavailable, which reports every record
# as an exe no manifest claims.
build_agent_entrypoint_map() {
    AGENT_NAMES=(); AGENT_PATTERNS=()
    declare -F ai_tools_installed_agents >/dev/null 2>&1 || return 0
    declare -F ai_tools_agent_manifest_field >/dev/null 2>&1 || return 0
    local agent pattern
    while IFS=$'\t' read -r agent _ _; do
        pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext 2>/dev/null || true)"
        [[ -n "${pattern}" ]] || continue
        AGENT_NAMES+=( "${agent}" )
        AGENT_PATTERNS+=( "${pattern}" )
    done < <(ai_tools_installed_agents 2>/dev/null)
    return 0
}

# classify_entrypoint_exec <exe> <argv0> -- PRINT `<class> <agent>`, where class is `self` or `finding` and agent is
# empty for an exe no manifest claims.
#
# The argv0 is not a CONTROL -- a caller chooses its own -- so the split is a noise filter over a record written either
# way, and the count render_entrypoint_section prints names what it folded.
#
# The two classes, in the order they are decided:
#   self     a bare argv0 (no `/`) into an agent's own entrypoint: the agent dispatching a tool it bundles, as
#            claude-code does for `rg`, `ugrep` and `bfs`, and codex for `apply_patch`. An exec that names a PATH
#            is not this, so starting an entrypoint at its real path stays a finding whichever agent does it.
#   finding  everything else, including every exe no manifest claims -- so a manifest this helper cannot read
#            yields MORE findings rather than fewer.
#
# The declared pattern is matched anchored, as the relabel matches it.
classify_entrypoint_exec() {
    local exe="$1" argv0="$2" agent="" index=0
    while (( index < ${#AGENT_NAMES[@]} )); do
        if [[ "${exe}" =~ ^${AGENT_PATTERNS[${index}]}$ ]]; then
            agent="${AGENT_NAMES[${index}]}"; break
        fi
        index=$(( index + 1 ))
    done
    if [[ -n "${agent}" && -n "${argv0}" && "${argv0}" != */* ]]; then
        printf 'self %s\n' "${agent}"; return 0
    fi
    printf 'finding %s\n' "${agent}"
}

# collect_entrypoint_execs -- PRINT one `<class>|<component>|<timestamp>|<level>|<message>` per recorded exec,
# where class partitions the two outcomes and the remaining four fields are the shape render_findings reads. Findings
# therefore collapse and sort exactly as the other two sources' do.
#
# `-m AVC` selects every event holding an AVC record in the window -- every domain's denials among them --
# and the parser keeps the ones this section's rule wrote. ausearch takes a timestamp as TWO argv words
# (`-ts <date> <time>`) and refuses the single token, which is why the window is formatted as a pair.
collect_entrypoint_execs() {
    local since_date since_time
    since_date="$(date -d "@${CUTOFF_EPOCH}" '+%m/%d/%Y')"
    since_time="$(date -d "@${CUTOFF_EPOCH}" '+%H:%M:%S')"
    parse_entrypoint_exec_records \
        < <(ausearch -m AVC -ts "${since_date}" "${since_time}" 2>/dev/null || true)
}

# avc_line_records_entrypoint_exec <line> -- succeed when a raw `type=AVC` line is the auditallow's own record:
# `granted`, the permission inside the braces, the subject type in `scontext=` and the object type in `tcontext=`, each
# read as the TYPE component of a `user:role:type[:level]` context so a user or role prefix does not decide. A denial,
# a grant of any other permission, and either label on another domain's record all fail it.
avc_line_records_entrypoint_exec() {
    local line="$1" braces context
    braces='avc:[[:space:]]+granted[[:space:]]+[{][^}]*[[:space:]]'"${ENTRYPOINT_EXEC_PERMISSION}"'[[:space:]][^}]*[}]'
    [[ "${line}" =~ ${braces} ]] || return 1
    context='(^|[[:space:]])scontext=[^:[:space:]]+:[^:[:space:]]+:'"${ENTRYPOINT_EXEC_SUBJECT_TYPE}"'(:|[[:space:]]|$)'
    [[ "${line}" =~ ${context} ]] || return 1
    context='(^|[[:space:]])tcontext=[^:[:space:]]+:[^:[:space:]]+:'"${ENTRYPOINT_EXEC_OBJECT_TYPE}"'(:|[[:space:]]|$)'
    [[ "${line}" =~ ${context} ]] || return 1
    [[ "${line}" =~ (^|[[:space:]])tclass=file($|[[:space:]]) ]]
}

# parse_entrypoint_exec_records -- read ausearch's output on stdin and print one record per event. Separate
# from the search so the suite drives the parser and the classification over fixture records, which is the half no test
# can produce on a host: writing to the kernel trail is the one thing this section's evidence rests on nobody being able
# to do.
#
# Each event is a block of `type=` lines that a `----` separator ends. THE AVC LINE IS THE PREDICATE: a block is
# a record of this section only where one of its AVC lines passes avc_line_records_entrypoint_exec, whatever else
# the event holds, and a block with none is another domain's and is dropped. The exec'd file is that line's `path=` --
# the object whose label matched -- with the SYSCALL line's `exe=` as the fallback for a kernel that wrote none;
# the pids come from the SYSCALL line and argv0 from the EXECVE line. The syscall number is not read: execute_no_trans
# is checked inside the exec family alone, and holding the block to execve's own number would drop an execveat(2),
# which is the same exec reached through a descriptor. A block the AVC line admits and no other line describes is still
# a record, with the file and the pids unknown -- fewer fields, and the finding still reported. The lines of an event
# arrive in whichever order ausearch prints them, so each field is read wherever it turns up.
parse_entrypoint_exec_records() {
    local line exe="" argv0="" pid="" ppid="" timestamp="" avc_path="" matched=no
    while IFS= read -r line; do
        case "${line}" in
            ----*)
                [[ "${matched}" == yes ]] \
                    && emit_entrypoint_exec_record "${exe:-?}" "${argv0}" "${pid}" "${ppid}" "${timestamp}"
                exe=""; argv0=""; pid=""; ppid=""; timestamp=""; matched=no ;;
            type=AVC*)
                avc_line_records_entrypoint_exec "${line}" || continue
                matched=yes
                avc_path="$(audit_string_field "${line}" path)"
                [[ -z "${avc_path}" ]] || exe="${avc_path}"
                [[ -n "${pid}" ]] || pid="$(audit_field "${line}" pid)"
                [[ -n "${timestamp}" ]] || timestamp="$(audit_event_timestamp "${line}")" ;;
            type=SYSCALL*)
                [[ -n "${exe}" ]] || exe="$(audit_string_field "${line}" exe)"
                pid="$(audit_field "${line}" pid)"
                ppid="$(audit_field "${line}" ppid)"
                timestamp="$(audit_event_timestamp "${line}")" ;;
            type=EXECVE*)
                argv0="$(audit_string_field "${line}" a0)" ;;
        esac
    done
    [[ "${matched}" == yes ]] \
        && emit_entrypoint_exec_record "${exe:-?}" "${argv0}" "${pid}" "${ppid}" "${timestamp}"
    return 0
}

# emit_entrypoint_exec_record <exe> <argv0> <pid> <ppid> <timestamp> -- print one
# `<class>|<component>|<timestamp>|<level>|<message>` record. An event with no exec'd file does not print a record.
emit_entrypoint_exec_record() {
    local exe="$1" argv0="$2" pid="${3:-?}" ppid="${4:-?}" timestamp="${5:-unknown}"
    [[ -n "${exe}" ]] || return 0
    local verdict class agent message
    verdict="$(classify_entrypoint_exec "${exe}" "${argv0}")"
    class="${verdict%% *}"; agent="${verdict#* }"
    if [[ "${class}" == self ]]; then
        message="${agent} exec'd its own entrypoint as $(audit_record_field "${argv0}")"
    elif [[ -n "${agent}" ]]; then
        message="${agent} entrypoint started from inside a session (pid ${pid}, parent ${ppid}, argv0 $(audit_record_field "${argv0}"))"
    else
        message="a file no installed manifest claims was exec'd from inside a session (exe $(audit_record_field "${exe}"), pid ${pid}, parent ${ppid}, argv0 $(audit_record_field "${argv0}"))"
    fi
    printf '%s|exec|%s|WARNING|%s\n' "${class}" "${timestamp}" "${message}"
}

# audit_event_timestamp <line> -- PRINT the record's time as `YYYY-MM-DDTHH:MM:SS`, the shape render_findings sorts
# on and splits the date out of. A raw record carries it as `msg=audit(<epoch>.<ms>:<serial>)`, which is a further
# reason to read raw: the epoch is one unambiguous number, where the interpreted form is a date whose spelling is
# the host's. A stamp date(1) cannot read is passed through rather than guessed at, so the row still sorts.
audit_event_timestamp() {
    local line="$1" stamp
    [[ "${line}" =~ msg=audit\(([0-9]+)\.[0-9]+:[0-9]+\) ]] || { printf 'unknown'; return 0; }
    stamp="${BASH_REMATCH[1]}"
    date -d "@${stamp}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || printf '%s' "${stamp}"
}

# render_entrypoint_section -- print the section, whichever state the host is in. Always printed, so a clean report
# on a host whose policy does not write the record names the reading it could not make.
render_entrypoint_section() {
    printf '\n  %s\n' "In-session entrypoint execs -- the kernel's record of the SELinux auditallow"
    case "${ENTRYPOINT_EXEC_STATE}" in
        no-auditd)
            printf '  %s\n' "no reading was made: this host keeps no audit log for the kernel to write to"
            ai_tools_msg_notice MSG-C6E6 \
                "no audit daemon on this host, so an agent started from inside a session leaves no kernel record" \
                "install the audit package and start auditd; the SELinux policy writes the record, no rule file is needed"
            return 0 ;;
        no-selinux|no-rule)
            printf '  %s\n' "no reading was made: the policy rule that writes the record is not in force"
            # One situation, one code. The remedy differs by whether the core module is loaded at all or predates
            # the rule, so it is chosen into the second line; a second emit would declare the same code twice.
            local remedy="load the confinement policy: install ai-tools-selinux, or from a checkout run: sudo selinux/install-selinux.sh install"
            [[ "${ENTRYPOINT_EXEC_STATE}" == no-selinux ]] \
                || remedy="the loaded ${SELINUX_CORE_MODULE} module predates the rule: upgrade ai-tools-selinux, or from a checkout run: sudo selinux/install-selinux.sh rebuild"
            ai_tools_msg_notice MSG-V8Z9 \
                "the SELinux rule that records an agent started from inside a session is not in force, so no such start is recorded" \
                "${remedy}"
            return 0 ;;
    esac
    printf '  %s\n' "the kernel wrote these: no process of the sandbox account can add to this trail"
    printf '  %s\n' "or remove from it, so a record here is evidence of what ran, not of who ran it"
    if (( ENTRYPOINT_SELF_EXEC_COUNT > 0 )); then
        printf '  %s\n' "counted, not listed: ${ENTRYPOINT_SELF_EXEC_COUNT} exec(s) of an agent's own entrypoint under a bare"
        printf '  %s\n' "name, which is an agent dispatching a tool it bundles. What it counted:"
        printf '%s\n' "${ENTRYPOINT_SELF_EXEC_NAMES[@]}" | sort -u | sed 's/^/    /'
        printf '  %s\n' "the count filters noise and no decision reads it: a caller chooses its own argv0,"
        printf '  %s\n' "and the record is written either way -- it is the record that is evidence"
    fi
    if (( ${#ENTRYPOINT_EXEC_FINDINGS[@]} == 0 )); then
        printf '  %s\n' "no agent entrypoint was started from inside a session in this window"
        return 0
    fi
    printf '\n'
    printf '  %-7s  %-10s  %-9s %6s  %s\n' "LEVEL" "LAST SEEN" "COMPONENT" "COUNT" "MOST RECENT"
    render_findings < <(printf '%s\n' "${ENTRYPOINT_EXEC_FINDINGS[@]}")
    ai_tools_msg_warn MSG-H2B5 \
        "an agent entrypoint was started from inside a running session, which no launch gate saw" \
        "the child runs in its parent's unit, so the launch and the handbacks carry the parent's identity"
    # The command stays outside the frame: the wrapping emitter would break it across lines (msg.lib.sh).
    printf '  %s\n' "read the session it happened in:"
    printf '    %s\n' "journalctl -t ai-tools-hook _UID=\$(id -u ${SANDBOX_USER})"
}

# collect_entrypoint_findings -- fill ENTRYPOINT_EXEC_STATE, ENTRYPOINT_EXEC_FINDINGS, the folded count
# (ENTRYPOINT_SELF_EXEC_COUNT) and ENTRYPOINT_SELF_EXEC_NAMES -- what each counted dispatch was, so the count names
# what it folded away.
collect_entrypoint_findings() {
    ENTRYPOINT_EXEC_FINDINGS=()
    ENTRYPOINT_SELF_EXEC_NAMES=()
    ENTRYPOINT_SELF_EXEC_COUNT=0
    ENTRYPOINT_EXEC_STATE="$(entrypoint_exec_state)"
    [[ "${ENTRYPOINT_EXEC_STATE}" == loaded ]] || return 0
    build_agent_entrypoint_map
    local line
    while IFS= read -r line; do
        case "${line%%|*}" in
            self)
                ENTRYPOINT_SELF_EXEC_COUNT=$(( ENTRYPOINT_SELF_EXEC_COUNT + 1 ))
                ENTRYPOINT_SELF_EXEC_NAMES+=( "${line##*|}" ) ;;
            finding)
                ENTRYPOINT_EXEC_FINDINGS+=( "${line#*|}" ) ;;
        esac
    done < <(collect_entrypoint_execs)
    return 0
}

main() {
    mapfile -t FILE_FINDINGS < <(collect_file_findings)
    mapfile -t LAUNCH_REFUSALS < <(collect_launch_refusals)
    collect_entrypoint_findings
    readonly FILE_FINDING_COUNT=${#FILE_FINDINGS[@]}
    readonly LAUNCH_REFUSAL_COUNT=${#LAUNCH_REFUSALS[@]}
    readonly ENTRYPOINT_FINDING_COUNT=${#ENTRYPOINT_EXEC_FINDINGS[@]}

    if (( FILE_FINDING_COUNT == 0 && LAUNCH_REFUSAL_COUNT == 0 && ENTRYPOINT_FINDING_COUNT == 0 )); then
        ai_tools_msg_headline "Audit" 1 \
            "Nothing refused, rejected, stranded or flagged since ${SINCE_DISPLAY}."
        printf '  %s\n' "trail: ${AI_TOOLS_LOG_DIR}/*.log (root-only)"
        # Printed on the clean path too: a window with no finding means one thing where the policy rule is in force
        # and another where it is not, and the difference is the operator's to know.
        render_entrypoint_section
        return 0
    fi

    DISTINCT_FINDING_COUNT=0
    if (( FILE_FINDING_COUNT > 0 )); then
        DISTINCT_FINDING_COUNT="$(printf '%s\n' "${FILE_FINDINGS[@]}" | render_findings | wc -l)"
    fi
    readonly DISTINCT_FINDING_COUNT

    ai_tools_msg_headline "Audit" 1 \
        "${DISTINCT_FINDING_COUNT} distinct finding(s) from ${FILE_FINDING_COUNT} recorded line(s), ${LAUNCH_REFUSAL_COUNT} launch refusal(s), and ${ENTRYPOINT_FINDING_COUNT} in-session entrypoint exec(s), since ${SINCE_DISPLAY}."

    if (( FILE_FINDING_COUNT > 0 )); then
        printf '\n  %s\n' "Recorded findings -- ${AI_TOOLS_LOG_DIR}/*.log, root writers only"
        printf '  %s\n' "these are evidence: the sandbox account can neither write nor read this trail"
        printf '  %s\n' "each line is something that HAPPENED, not something still true -- a condition"
        printf '  %s\n' "reported here may have been resolved since; check LAST SEEN, then confirm" 
        printf '\n'
        printf '  %-7s  %-10s  %-9s %6s  %s\n' "LEVEL" "LAST SEEN" "COMPONENT" "COUNT" "MOST RECENT"
        render_findings < <(printf '%s\n' "${FILE_FINDINGS[@]}")
        printf '\n  %s\n' "repeats are collapsed; a count above 1 means the same finding recurred"
    fi

    if (( LAUNCH_REFUSAL_COUNT > 0 )); then
        printf '\n  %s\n' "Launch refusals -- journald, tag ai-tools-run"
        printf '  %s\n' "the session's own account of itself: written by the sandbox account, so"
        printf '  %s\n' "reconcile these against the findings above rather than relying on them alone"
        printf '\n'
        printf '  %-7s  %-10s  %-9s %6s  %s\n' "LEVEL" "LAST SEEN" "COMPONENT" "COUNT" "MOST RECENT"
        render_findings < <(printf '%s\n' "${LAUNCH_REFUSALS[@]}")
    fi

    render_entrypoint_section

    printf '\n  %s\n' "Current state is a different question, asked elsewhere:"
    printf '    %-45s %s\n' "ai-tools status"                                 "service health and verification, live"
    printf '    %-45s %s\n' "sudo ai-tools-admin system entrypoints relabel"  "re-verify and relabel the entrypoints"
    printf '    %-45s %s\n' "journalctl -t ai-tools-chown _UID=0"             "the full ownership trail"
    return 1
}

# ── Entry point ──────────────────────────────────────────────────────────────────────────────
# SOURCING THIS FILE IS INERT: it defines the functions and returns here, without parsing an argument, reading a trail
# or resolving any host state. That is what lets the unit suite drive the record parser and the classification --
# whose inputs come from a kernel trail no test may write -- against fixture records, on any host, with no audit rule
# loaded and no privilege. Running the file is unchanged.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

parse_command_line "$@"
assert_root
resolve_window
# main's status IS the command's contract -- non-zero means findings -- so it is propagated explicitly rather than left
# to `set -e`, which would end the shell at the call and make the status an artifact of the shell option.
main || exit $?
exit 0
