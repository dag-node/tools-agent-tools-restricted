#!/usr/bin/bash -p
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-reclaim
# Reclaims ownership of agent-written files under a project back to the owning operator, on demand --
# the operator-invoked counterpart to the session sweeps. It walks <project> and hands each @SANDBOX_USER@-owned path
# to ai-tools-chown, the SAME per-path trust boundary (registry re-validation, exclusions, secret rules, TOCTOU-safe
# chown) the handback and sweeps use, so it carries none of its own. No part of it is .git-specific: .git is simply
# the one tree the per-session sweeps skip, so its objects linger @SANDBOX_USER@-owned, which is the usual reason to run
# this -- e.g. before an ACL-unaware backup, where ownership (not the user:<operator> ACL) is what survives
# an rsync/tar. By default the heavy/transient trees (node_modules, .venv, ...) are left untouched -- their agent
# ownership is harmless (world-readable, regenerable) -- while .git is included; `--full` reclaims those too,
# for a fully operator-owned tree (a complete, ACL-independent backup).
#
# The walk is two-phase: collect, then apply. An empty hand-back set is reported as exactly that before any change;
# otherwise ONE confirmation covers the whole set (count + a sample with owner/group/mode), and each path is applied
# via `ai-tools-chown --yes` so the per-path prompt never fires inside the batch. What the children print on stderr is
# folded and printed once with a ` (N paths)` count (_fold_child_messages), and a run a signal stops reports what it
# handed back before the stop (_stop_on_signal).
#
# Runs as root via sudo under `atr projects handback` (no-NOPASSWD, like ai-tools-setfacl); root is required to chown
# files the projects user does not own.
#
# Installed 750 root:root, so only root runs it. Its domain rule is cli.rule.md.

set -euo pipefail

# A fixed PATH, set before any command is resolved: with the interpreter line it is the start every root helper shares
# (cli.rule.md, ref-section-g7c8), so a command is found in the system directories whatever PATH the caller holds.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Every refusal and outcome line this helper prints goes through warn, so the component prefix is stated once here
# instead of at each site. A leading message code (msg.lib.sh states the form) is printed on its own line ahead
# of the message, the shape tests/lib/harness.sh's assert_msg reads. Matched inline, since this helper reports
# before msg.lib.sh is loaded. The reports that are not one situation -- the pre-scan sample and its count -- print raw
# where they are made, and carry no code. The code it printed is left in _warn_code, for a site that also records
# the situation through log.lib.sh: the log call passes the variable, so the code literal stays at the emit call
# the reference index reads as its definition (messaging.rule.md).
_warn_code=""
warn() {
    local IFS=' ' code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    _warn_code="${code}"
    printf 'ai-tools-reclaim: %s\n' "$*" >&2
}

# Args: an optional --full flag (anywhere) reclaims the heavy trees skipped by default too; the
# remaining argument is the absolute project path.
FULL=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --full) FULL=true ;;
        -*) warn MSG-W6A2 "unknown option: ${arg}"; exit 2 ;;
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                warn MSG-W2B2 "too many arguments"; exit 2
            fi ;;
    esac
done
[[ -n "${TARGET}" ]] \
    || { printf 'usage: ai-tools-reclaim [--full] <absolute-project-path>\n' >&2; exit 2; }
readonly TARGET FULL
readonly CHOWN_BIN="/usr/local/libexec/ai-tools/ai-tools-chown"
readonly SANDBOX_USER="@SANDBOX_USER@"

# Operator-identity resolver: a path no operator's allowlist covers is left untouched (fail-closed); ai-tools-chown
# re-validates each path independently regardless.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_operator__resolve_owner() { return 1; }

# Shared leveled logger: journald + the root-only chown.log (co-located with the per-path chowns ai-tools-chown records
# there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-reclaim"
AI_TOOLS_LOG_FILE="chown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
# Required, fail-closed: this helper prints agent-named paths to stderr and the log, so it needs ai_tools_log__sanitize
# -- a missing logger must refuse, not emit an agent path raw.
if ! source "${LOG_LIB}"; then
    printf 'ai-tools-reclaim: FATAL: cannot source %s\n' "${LOG_LIB}" >&2
    exit 1
fi

# Directory-skip selector (shared single source of truth). A missing lib leaves a stub that descends everywhere --
# a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_dirs__build_find_expression() { AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION=(); return 0; }

# Protected-paths backstop (safe-paths.lib.sh): refuse to walk a system directory even when the allowlist includes it.
# See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared yes/no prompt (ai_tools_msg__confirm; see msg.lib.sh). REQUIRED like safe-paths.lib.sh: the bare source
# under `set -e` aborts if it is missing -- a valid install ships it, so there is no fallback. Include-guarded, so this
# is a no-op when safe-paths.lib.sh already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh

canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole walk if the project root is a protected system directory, before find.
ai_tools_safe_paths__assert_safe_target "${canonical}" "reclaim" || exit 3
# Not under any operator's project registry -> no path legitimately to reclaim. Say so rather than exiting silently,
# so a direct `sudo ai-tools-reclaim` (past the CLI's own front-line check) still reports why it reclaimed no path.
# The path is operator-supplied, so it prints without log_sanitize.
ai_tools_operator__resolve_owner "${canonical}" || {
    warn MSG-K9H2 "nothing to reclaim -- ${canonical} is not under any claimed project"
    ai_tools_log__coded info "${_warn_code}" "reclaim: ${canonical} not under any claimed project" \
        "AI_TOOLS_RESULT=refused"
    exit 0
}

# Past the owner resolution this run acts for one operator in one project, so the operator and the project ride
# as per-run log context (logging.rule.md).
AI_TOOLS_LOG_OPERATOR="${PROJECTS_USER}"
AI_TOOLS_LOG_PROJECT="${canonical}"

# Default reclaim walks .git but skips the heavy trees; `--full` descends everywhere. The lib owns both defaults --
# the helper only names the consumer.
if ${FULL}; then ai_tools_skip_dirs__build_find_expression reclaim-full '' "${canonical}"; else ai_tools_skip_dirs__build_find_expression reclaim '' "${canonical}"; fi
# find <project> -xdev <skip dirs> -prune -o ( file|dir ) -user SANDBOX_USER -print0
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" \
                  '(' -type f -o -type d ')' -user "${SANDBOX_USER}" -print0 )

# Two-phase: collect first, so a run with no path to hand back says so and stops before any change, and a run with work
# confirms ONCE for the whole set -- ai-tools-chown --yes then applies each path without re-asking (one question, not
# one per .git object). The sample carries owner/group/mode columns so what is about to change is visible up front.
declare -a paths=()
while IFS= read -r -d '' path; do
    paths+=("${path}")
done < <(find "${expr[@]}" 2>/dev/null)

if (( ${#paths[@]} == 0 )); then
    warn MSG-J6B2 "nothing to reclaim under ${canonical}"
    ai_tools_log__coded info "${_warn_code}" "reclaim: nothing to reclaim under ${canonical}"
    exit 0
fi

warn "${#paths[@]} agent-owned path(s) under ${canonical}, e.g.:"
for path in "${paths[@]:0:3}"; do
    read -r og m < <(stat -c '%U:%G %a' "${path}" 2>/dev/null) || { og='?'; m='?'; }
    printf '  %-18s %-4s %s\n' "${og}" "${m}" "$(ai_tools_log__sanitize "${path}")" >&2
done
(( ${#paths[@]} > 3 )) && printf '  ... and %d more\n' "$(( ${#paths[@]} - 3 ))" >&2

# Default yes: handing agent-written files back to their operator is the reclaim's whole point, so Enter (and a no-tty
# batch run) proceeds; n leaves ownership as it stands.
if ! ai_tools_msg__confirm "Hand back all ${#paths[@]} path(s)?" y; then
    warn MSG-T9M5 "declined; ownership left as it stands"
    ai_tools_log__coded info "${_warn_code}" "reclaim: declined for ${canonical}" \
        "AI_TOOLS_RESULT=refused"
    exit 0
fi

# The children's messages, folded across the run: the number of children that wrote each one, and the order each
# was first written in. Storage grows with the number of distinct messages, not with the number of paths.
declare -A CHILD_MESSAGE_COUNT=()
declare -a CHILD_MESSAGES_IN_ORDER=()

# _fold_child_messages <text> : add one ai-tools-chown child's stderr to the fold. A message is a line, or a code line
#   and the line after it (the form warn writes); an empty line is not one. A child that writes a message twice counts
#   once for it. Each child re-resolves the path's owner and loads every enrolled operator's registry, so a refused
#   registry is reported by every child, and without the fold a large tree prints the refusal once per path.
_fold_child_messages() {
    local line pending="" message
    local -a messages=()
    local -A seen=()
    [[ -n "${1-}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if [[ -z "${pending}" && "${line}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then
            pending="${line}"; continue
        fi
        if [[ -n "${pending}" ]]; then messages+=("${pending}"$'\n'"${line}"); else messages+=("${line}"); fi
        pending=""
    done <<< "$1"
    [[ -z "${pending}" ]] || messages+=("${pending}")
    for message in "${messages[@]}"; do
        [[ -z "${seen[${message}]+set}" ]] || continue
        seen["${message}"]=1
        [[ -n "${CHILD_MESSAGE_COUNT[${message}]+set}" ]] || CHILD_MESSAGES_IN_ORDER+=("${message}")
        CHILD_MESSAGE_COUNT["${message}"]=$(( ${CHILD_MESSAGE_COUNT[${message}]-0} + 1 ))
    done
}

# _print_folded_child_messages : print to stderr each folded message once, in the order first written, with
#   ` (N paths)` after one that N children wrote, N > 1.
_print_folded_child_messages() {
    local message count
    for message in "${CHILD_MESSAGES_IN_ORDER[@]}"; do
        count="${CHILD_MESSAGE_COUNT[${message}]}"
        if (( count > 1 )); then printf '%s (%d paths)\n' "${message}" "${count}" >&2
        else printf '%s\n' "${message}" >&2; fi
    done
}

# _stop_on_signal <status> : a run interrupted part-way still reports what it did: the messages folded so far, and
#   the number of paths handed back before the signal, then exits <status>. Called where the loop reads stop_status,
#   never from a trap: bash runs a trap once the command in flight completes, which for a child is between its
#   assignment and its count.
_stop_on_signal() {
    trap - INT TERM
    _print_folded_child_messages
    warn "handback stopped by a signal -- ${confirmed} path(s) handed back under ${canonical} before it"
    ai_tools_log__structured warning \
        "reclaim: stopped by a signal after handing back ${confirmed} path(s) under ${canonical}" \
        "AI_TOOLS_RESULT=failed"
    exit "$1"
}

# Count CONFIRMED handbacks (ai-tools-chown exit 0), not attempts: a path that stopped being @SANDBOX_USER@-owned
# between the collect and apply phases is a legitimate skip, and reporting it as handed back would overstate
# what changed. A non-zero tally is surfaced, not hidden. Each child's stderr is captured on its own, its stdout left
# on the terminal, and folded (_fold_child_messages) into what is printed ahead of the tally. A signal traps into
# stop_status alone, and the loop reads it ahead of each child. Bash runs a trap between two commands, so a signal
# recorded ahead of the read stops the run before the next child, and one recorded after the read -- in the command
# that starts the child, or while the child runs -- stops the run once that child is counted and its stderr folded.
# The read and the start are two commands, so a signal can land between them and the stop then follows one more child
# than the signal preceded; the tally the stop prints includes every child that ran. The run waits for the child
# in flight, one ai-tools-chown of one path.
# The traps come off ahead of the last read, since bash runs a trap pending at `trap -` before removing it: a signal
# recorded up to that point is read, and one after it ends the run by its default disposition.
declare -i confirmed=0 failed=0 stop_status=0
trap 'stop_status=130' INT
trap 'stop_status=143' TERM
for path in "${paths[@]}"; do
    child_messages=""
    (( stop_status )) && _stop_on_signal "${stop_status}"
    if { child_messages="$("${CHOWN_BIN}" --yes "${path}" </dev/null 2>&1 1>&3)"; } 3>&1; then
        confirmed+=1
    else
        failed+=1
    fi
    _fold_child_messages "${child_messages}"
done
trap - INT TERM
(( stop_status )) && _stop_on_signal "${stop_status}"
_print_folded_child_messages
if (( failed > 0 )); then
    warn MSG-J4W5 "handed back ${confirmed} path(s), ${failed} skipped/failed under ${canonical}"
    ai_tools_log__coded warning "${_warn_code}" \
        "reclaim: handed back ${confirmed} path(s), ${failed} skipped/failed under ${canonical}" \
        "AI_TOOLS_RESULT=failed"
else
    warn "handed back ${confirmed} path(s) under ${canonical}"
    ai_tools_log__structured info \
        "reclaim: handed back ${confirmed} agent-owned path(s) under ${canonical}" \
        "AI_TOOLS_RESULT=ok"
fi
exit 0
