#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-audit
# Answers one question: what was refused, rejected, stranded or flagged BETWEEN two points in
# time? It reports EVENTS, never current state -- a condition recorded here may have been
# resolved since, and confirming that is ai-tools --status's job, not this one's. Conflating the
# two invites acting on a finding that is already fixed.
# The detections already exist and are already recorded -- what they lacked was a
# reader, and a detection nobody reads is decoration.
#
# It INVENTS no detection and parses no per-case wording. The root-only file sink already
# encodes severity in its line format (`<ts> <LEVEL> [<pid>] <msg>`, written by log.lib.sh and,
# in the same format, by the handback daemon), so a finding is simply a line at NOTICE or above.
# That is what keeps this from drifting: a helper that adds a new warning is reported here the
# day it ships, with no pattern to update.
#
# TWO SOURCES, NOT EQUAL, AND SAID SO. /var/log/ai-tools/*.log is 700 root:root, root writers
# only, so the sandbox account can neither read nor append to it: those lines are EVIDENCE and
# are what this command reports as authoritative. A launch refusal is the exception -- it is
# written by ai-tools-run, which runs AS the sandbox account and therefore reaches journald
# only, under a tag whose legitimate writer is that same account. Those lines are the session's
# own account of itself, reportable but not proof, and are shown in a separately titled section
# rather than mixed into the first (see .claude/rules/logging.rule.md).
#
# Root-only: the file sink is unreadable to anyone else, so there is nothing for a non-root
# caller to do here. Reached through `sudo ai-tools --audit` with no NOPASSWD grant, like
# ai-tools-lockdown and ai-tools-reclaim.
#
# Usage:  ai-tools-audit [--since <when>]        <when> is anything date(1) parses
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-audit.sh /usr/local/libexec/ai-tools/ai-tools-audit

set -euo pipefail

# The severity floor for a finding. NOTICE is included deliberately: ai-tools-chown records a
# breached secret at that level, and a leaked credential is the single most actionable thing
# this command can surface.
readonly FINDING_LEVELS='NOTICE|WARNING|ERROR'

# Default window. Long enough to cover a weekend and a missed morning, short enough that the
# first run on a long-lived host is not a wall of history the operator stops reading.
readonly DEFAULT_SINCE='7 days ago'

readonly SANDBOX_USER='@SANDBOX_USER@'

# Shared leveled logger. This helper WRITES no audit line of its own -- reading a trail is not
# an event worth adding to it -- but it uses the sanitizer, which reduces a log line to
# safe-for-display characters before it reaches the operator's terminal. That is load-bearing
# here, not decorative: every line this command prints came from a file recording
# agent-influenced paths, so it is required fail-closed for the same reason ai-tools-chown and
# ai-tools-lockdown require it (see .claude/rules/logging.rule.md).
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
source "${LOG_LIB}" 2>/dev/null || {
    printf 'ai-tools-audit: cannot load %s -- refusing to print log text unsanitized\n' \
        "${LOG_LIB}" >&2
    exit 1
}

# Shared message renderer, REQUIRED like every other user-facing consumer (msg.lib.sh).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source "${MSG_LIB}"

# ── Arguments ────────────────────────────────────────────────────────────────────────────────
SINCE="${DEFAULT_SINCE}"
while (( $# )); do
    case "$1" in
        --since)
            [[ -n "${2:-}" ]] || { printf 'ai-tools-audit: --since needs a value\n' >&2; exit 2; }
            SINCE="$2"; shift 2 ;;
        -*) printf 'ai-tools-audit: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)  printf 'ai-tools-audit: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
readonly SINCE

[[ "$(id -u)" == "0" ]] || {
    ai_tools_msg_error 2 "ai-tools-audit must run as root: the trail it reads is 700 root:root" \
        "run it as: sudo ai-tools --audit"
    exit 1
}

# Normalize the window once. A value date(1) cannot parse is refused rather than silently
# treated as "everything", which would turn a typo into a reassuring wall of old findings.
CUTOFF_EPOCH="$(date -d "${SINCE}" +%s 2>/dev/null)" || {
    ai_tools_msg_error 2 "ai-tools-audit: --since value not understood: ${SINCE}" \
        "give it anything date(1) parses, e.g. '2 days ago', 'yesterday', '2026-08-01'"
    exit 2
}
readonly CUTOFF_EPOCH
SINCE_DISPLAY="$(date -d "@${CUTOFF_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "${SINCE}")"
readonly SINCE_DISPLAY

# ── The authoritative source: the root-only file sink ────────────────────────────────────────
# collect_file_findings -- PRINT one `<component>|<timestamp>|<level>|<message>` per finding.
# Two passes by design: a cheap severity grep over the whole file, then a date comparison only
# on the lines that survived it. Findings are rare, so the expensive half runs on almost nothing.
collect_file_findings() {
    local log_file component line entry_timestamp entry_level entry_epoch entry_message
    for log_file in "${AI_TOOLS_LOG_DIR}"/*.log; do
        [[ -f "${log_file}" && -r "${log_file}" ]] || continue
        component="$(basename -- "${log_file}" .log)"
        while IFS= read -r line; do
            # `<ts> <LEVEL> [<pid>] <message>` -- anything else is not a record this format
            # produced and is left alone rather than guessed at.
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
# collect_launch_refusals -- PRINT one `launch|<timestamp>|WARNING|<message>` per REFUSED line
# ai-tools-run recorded, in the same shape as a file finding so it collapses through the same
# renderer: a refusal that recurs on every launch attempt would otherwise flood the report
# exactly as the handback lines did. Filtered by the sandbox account's uid as every documented query is: the tag alone
# attributes nothing, and here the legitimate writer IS the account under scrutiny -- which is
# exactly why these are reported apart from the file sink's evidence.
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
# render_findings -- read `<component>|<ts>|<level>|<message>` on stdin and print one line per
# DISTINCT finding, most serious and most recent first.
#
# Collapsing is not cosmetic, it is what makes the command usable. A recurring condition writes
# one line per occurrence -- the handback daemon's refusals alone run to hundreds over a week on
# a host that exercises them -- and a report that lists each one buries the single ERROR that
# needs acting on under a wall of a condition already understood. That is the same reason INFO
# is out of scope entirely: an audit nobody finishes reading reports nothing.
#
# Findings are grouped by their message with digit runs replaced by `#`, so occurrences that
# differ only in a pid, a count, or a timestamp collapse into one line carrying the number of
# times it happened and the most recent example in full. Nothing is hidden -- the count states
# what was folded, and the underlying files are named above.
#
# Ordering is by severity first and recency second, because those are the two questions actually
# being asked: what is worst, and is it still happening.
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

mapfile -t FILE_FINDINGS < <(collect_file_findings)
mapfile -t LAUNCH_REFUSALS < <(collect_launch_refusals)
readonly FILE_FINDING_COUNT=${#FILE_FINDINGS[@]}
readonly LAUNCH_REFUSAL_COUNT=${#LAUNCH_REFUSALS[@]}

if (( FILE_FINDING_COUNT == 0 && LAUNCH_REFUSAL_COUNT == 0 )); then
    ai_tools_msg_headline "Audit" 1 \
        "Nothing refused, rejected, stranded or flagged since ${SINCE_DISPLAY}."
    printf '  %s\n' "trail: ${AI_TOOLS_LOG_DIR}/*.log (root-only)"
    exit 0
fi

DISTINCT_FINDING_COUNT=0
if (( FILE_FINDING_COUNT > 0 )); then
    DISTINCT_FINDING_COUNT="$(printf '%s\n' "${FILE_FINDINGS[@]}" | render_findings | wc -l)"
fi
readonly DISTINCT_FINDING_COUNT

ai_tools_msg_headline "Audit" 1 \
    "${DISTINCT_FINDING_COUNT} distinct finding(s) from ${FILE_FINDING_COUNT} recorded line(s), and ${LAUNCH_REFUSAL_COUNT} launch refusal(s), since ${SINCE_DISPLAY}."

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

printf '\n  %s\n' "Current state is a different question, asked elsewhere:"
printf '  %s\n'   "    ai-tools --status    service health and entrypoint verification, live"
printf '  %s\n'   "    ai-tools --relabel   re-verify and relabel the agent entrypoints now"
printf '  %s\n'   "    journalctl -t ai-tools-chown _UID=0    the full ownership trail" 
exit 1
