#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-allowlist
# Reads and edits ANOTHER enrolled operator's project allowlist
# (<their-home>/.config/ai-tools/allowed-projects) on behalf of the operator invoking sudo.
# This is the one privileged seam behind `ai-tools ... --for <operator>`: it lets a human
# operator claim a project for a service account that has no password and therefore cannot
# authenticate the claim's own root helpers.
#
# Root is needed for READS as well as writes: an allowlist is 0600 inside a 0700
# .config/ai-tools (ai-tools-admin seeds an operator's config), so one operator cannot see
# another's list at all. --print exists for exactly that, and the CLI snapshots it for the
# decisions a claim makes (is the path listed, disabled, or absent) before routing the mutation
# back through the four editing actions.
#
# The allowlist is the LAUNCH GATE: an entry here is what lets that operator's agent start in
# the directory, and what makes the ownership handback restore files to them. Editing another
# operator's gate stays inside the trust model's "%ai-ops operators are trusted" boundary, but
# it is not something the sandbox account may ever reach, so the helper is 750 root:root, and holds
# NO NOPASSWD grant (the invoking human authenticates, like ai-tools-lockdown/-setfacl/-relabel),
# and every mutation is logged with both the caller and the target.
#
# Every gate this helper applies resolves to LESS access on failure, never more:
#   - no SUDO_UID (a bare root call, or an unclean sudo context)  -> refuse, write no entry
#   - the CALLER is not in OPERATORS                              -> refuse, write no entry
#   - the TARGET is not in OPERATORS                              -> refuse, write no entry
#   - the target is the sandbox account or root                   -> refuse, write no entry
#   - the path is not a real directory, or is a protected system  -> refuse, write no entry
#     directory (safe-paths backstop)
#   - a required library will not load                            -> refuse, write no entry
# A refused run leaves the target's allowlist byte-identical, so a failure can only ever leave
# the agent with fewer places to launch than the operator intended, never more.
#
# Usage:
#   ai-tools-allowlist --operator <name> --print
#   ai-tools-allowlist --operator <name> --add    <absolute-project-path>
#   ai-tools-allowlist --operator <name> --remove <absolute-project-path>
#   ai-tools-allowlist --operator <name> --enable  <absolute-project-path>
#   ai-tools-allowlist --operator <name> --disable <absolute-project-path>
#
# --enable and --disable neither add nor drop a line: they take the leading '!' off an entry, or
# put it on, IN PLACE. They are the privileged half of `ai-tools --project-enable/--project-disable`
# (and of the claim's re-enable prompt), and they are deliberately not an add/remove pair: the line
# keeps its position and its comment, so a park-and-restore round trip leaves an ordered, commented
# allowed-projects exactly as its operator wrote it.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-allowlist.sh /usr/local/libexec/ai-tools/ai-tools-allowlist

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"

# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the
# message, the shape tests/lib/harness.sh's assert_msg reads. Matched inline: this helper does
# not load the library.
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-allowlist: %s\n' "$*" >&2; exit 1
}
# note: the same line on stdout, for an action that completed or had nothing to do. It does not
# exit, so the exit status stays where the action decides it, and it carries the prefix so no call
# site repeats it.
note() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}"; fi
    printf 'ai-tools-allowlist: %s\n' "$*"
}

# ── Arguments ────────────────────────────────────────────────────────────────────
# One target operator (--operator) and exactly one action. The action's path argument is
# attached to the flag rather than free-standing, so a missing value cannot silently shift
# into the operator slot.
OPERATOR=""
ACTION=""
TARGET_PATH=""
# _need_value <flag> [remaining args...]: die unless a value follows <flag> AND that value is not
# itself option-shaped. A leading '-' is a mistyped flag far more often than a real operator name
# or path, and taking it at face value would bind the wrong thing silently. The remaining args are
# passed through so an absent value is a zero-length expansion rather than an empty string.
_need_value() {
    local flag="$1"; shift
    (( $# )) || die MSG-Z7E9 "a value is required after ${flag}"
    [[ "$1" != -* ]] || die MSG-S4M8 "a value is required after ${flag}, not another option: $1"
}
# _one_action: five arms refuse a second action, and it is one situation, so the refusal is
# stated once here rather than at each of them.
_one_action() { [[ -z "${ACTION}" ]] || die MSG-C5G8 "only one action may be given"; }
while (( $# )); do
    case "$1" in
        --operator) _need_value "$1" "${@:2}"; OPERATOR="$2"; shift 2 ;;
        --print)    _one_action; ACTION=print; shift ;;
        --add)      _one_action
                    _need_value "$1" "${@:2}"; ACTION=add; TARGET_PATH="$2"; shift 2 ;;
        --remove)   _one_action
                    _need_value "$1" "${@:2}"; ACTION=remove; TARGET_PATH="$2"; shift 2 ;;
        --enable)   _one_action
                    _need_value "$1" "${@:2}"; ACTION=enable; TARGET_PATH="$2"; shift 2 ;;
        --disable)  _one_action
                    _need_value "$1" "${@:2}"; ACTION=disable; TARGET_PATH="$2"; shift 2 ;;
        *)          die MSG-R4E8 "unknown argument: $1
usage: ai-tools-allowlist --operator <name>
       (--print | --add <path> | --remove <path> | --enable <path> | --disable <path>)" ;;
    esac
done
[[ -n "${OPERATOR}" ]] || die MSG-X4Z3 "--operator <name> is required"
[[ -n "${ACTION}"   ]] || die MSG-J8J2 "one of --print, --add, --remove, --enable, --disable is required"
readonly OPERATOR ACTION TARGET_PATH

# ── Required libraries (fail closed) ─────────────────────────────────────────────
# Bare sources under `set -e`: an unloadable library aborts the helper before it touches
# anything, rather than leaving this pass unable to recognise a protected path or an
# unenrolled operator.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source /usr/local/lib/ai-tools/operator.lib.sh
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source /usr/local/lib/ai-tools/safe-paths.lib.sh
declare -F ai_tools_conf_allowlist_has_entry >/dev/null 2>&1 \
    || die MSG-C9K7 "config library defines no allowlist matcher -- refusing (fail closed)"
declare -F ai_tools_load_operators >/dev/null 2>&1 \
    || die MSG-F5N3 "operator library defines no operator list -- refusing (fail closed)"
declare -F ai_tools_assert_safe_target >/dev/null 2>&1 \
    || die MSG-E8H6 "safe-paths library defines no protected-path guard -- refusing (fail closed)"

# Shared leveled logger: journald (always) + the root-only /var/log/ai-tools/allowlist.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-allowlist"
AI_TOOLS_LOG_FILE="allowlist.log"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source /usr/local/lib/ai-tools/log.lib.sh 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
    ai_tools_log_structured() { :; }; ai_tools_log_coded() { :; }
fi

# ── Caller gate ──────────────────────────────────────────────────────────────────
# The identity that authorizes this edit is the operator who invoked sudo, resolved from the
# kernel-supplied SUDO_UID rather than from SUDO_USER (a name is spoofable through the
# environment; the uid sudo sets is not). A direct root call arrives without that context and is
# refused rather than defaulting to some operator.
caller_uid="${SUDO_UID:-}"
[[ -n "${caller_uid}" ]] \
    || die MSG-T6R6 "run me through sudo as an operator (no SUDO_UID) -- nothing changed"
caller="$(id -un "${caller_uid}" 2>/dev/null)" \
    || die MSG-W6P9 "unknown invoking uid ${caller_uid} -- nothing changed"
[[ "${caller}" != "${SANDBOX_USER}" ]] \
    || die MSG-N3S4 "the sandbox account may not manage an allowlist -- nothing changed"

ai_tools_load_operators 2>/dev/null \
    || die MSG-Z7N7 "no operators configured -- run: sudo ai-tools-admin operators add <user>"

_is_operator() {
    local want="$1" op
    for op in "${AI_TOOLS_OPERATORS[@]}"; do
        [[ "${op}" == "${want}" ]] && return 0
    done
    return 1
}

_is_operator "${caller}" \
    || die MSG-J6J3 "caller ${caller} is not a configured ai-tools operator -- nothing changed"

# ── Target gate ──────────────────────────────────────────────────────────────────
# The target must be an enrolled operator: the whole point of the entry is that ai-tools-setfacl
# and the handback helpers later resolve THIS path to THIS operator, and they resolve only over
# OPERATORS. Writing an entry for an unenrolled name would create a launch gate no ownership
# machinery can act on.
[[ "${OPERATOR}" != "${SANDBOX_USER}" ]] \
    || die MSG-Y3B2 "the sandbox account is not an operator and must not own projects -- nothing changed"
[[ "${OPERATOR}" != "root" ]] \
    || die MSG-B2Y8 "root is not an operator -- nothing changed"
_is_operator "${OPERATOR}" \
    || die MSG-M3R6 "target ${OPERATOR} is not a configured ai-tools operator -- enrol it first with:
       sudo ai-tools-admin operators add ${OPERATOR}"

target_home="$(getent passwd "${OPERATOR}" 2>/dev/null | cut -d: -f6)" \
    || die MSG-A2M5 "cannot resolve ${OPERATOR} -- nothing changed"
[[ -n "${target_home}" && -d "${target_home}" ]] \
    || die MSG-R4C4 "no home directory for ${OPERATOR} -- nothing changed"
# Resolve the target's allowlist through operator.lib's own path helper, so the
# AI_TOOLS_ALLOWLIST test hook applies here exactly as it does on every resolve_owner path and
# the helper cannot drift from what the root helpers read.
is_primary=secondary
[[ "${OPERATOR}" == "${AI_TOOLS_OPERATORS[0]}" ]] && is_primary=primary
allowlist="$(_ai_tools_operator_allowlist "${OPERATOR}" "${is_primary}")"
readonly caller allowlist target_home

# ── print ────────────────────────────────────────────────────────────────────────
# Read-only, and the only action that does not require a path. An absent allowlist prints
# an empty list and succeeds: "this operator has approved no projects" is a complete answer, and the
# caller (the CLI's snapshot) treats an empty list exactly as it treats a file of comments.
if [[ "${ACTION}" == print ]]; then
    [[ -r "${allowlist}" ]] || exit 0
    cat -- "${allowlist}"
    exit 0
fi

# ── Path gate (add/remove/enable/disable) ────────────────────────────────────────
# Canonicalise before every check and before the write, so a symlink or '..' cannot smuggle a
# path past the protected-paths backstop and land a different directory in the launch gate.
canonical="$(realpath -e "${TARGET_PATH}" 2>/dev/null)" \
    || die MSG-Q5X7 "not an existing path: ${TARGET_PATH} -- nothing changed"
[[ -d "${canonical}" ]] \
    || die MSG-R6C5 "not a directory: ${canonical} -- nothing changed"
ai_tools_assert_safe_target "${canonical}" "allowlist ${ACTION}" || exit 3
readonly canonical

# This run edits one operator's allowlist for one project, so the operator and the project
# ride as per-run log context (logging.rule.md). AI_TOOLS_OPERATOR names the operator
# whose launch gate the entry decides; the caller who ran the command is recorded
# as AI_TOOLS_CALLER, so an edit made through --for keeps the two apart in the trail.
AI_TOOLS_LOG_OPERATOR="${OPERATOR}"
AI_TOOLS_LOG_PROJECT="${canonical}"

# require_target_config: the target's allowlist must already exist. This helper applies the one
# entry change it was asked for and does not create the file: `ai-tools-admin operators add` is
# where an operator's config comes from -- the config files, at the modes that keep the sandbox
# account out (0700 dir, 0600 files) -- and it is idempotent. A missing allowlist therefore means
# the name reached OPERATORS and ai-ops another way, or the home did not exist at enrolment;
# seeding it from here would write the allowlist and leave the account without the secret-patterns
# file beside it, so the refusal names the command that writes the whole config.
require_target_config() {
    [[ -f "${allowlist}" ]] && return 0
    die MSG-S7Y3 "no ai-tools config yet for ${OPERATOR} (no ${allowlist}) -- nothing changed.
       If the ${OPERATOR} account is meant to run sandboxed sessions, enrol it first with:
       sudo ai-tools-admin operators add ${OPERATOR}"
}

# Every edit here is one call into conf.lib.sh's allowlist-editing functions -- the same
# implementation the CLI runs against the operator's own file and install.sh against its checkout.
# What is left here is this helper's own job: deciding WHO may edit WHOSE registry, and recording
# it. The library reports three outcomes -- 0 applied (or already so), 1 the write failed, 2 the
# request does not apply from the current state -- and each is reported to the caller distinctly,
# since a "not listed" and a "could not write" send an operator to different places.

case "${ACTION}" in
    add)
        require_target_config
        rc=0; ai_tools_conf_allowlist_add "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die MSG-T7B6 "that project is DISABLED for ${OPERATOR}: ${canonical} -- a '!' line
       parks it, and adding a second line would leave that '!' winning at the launch gate.
       Re-enable it instead:
       ai-tools-allowlist --operator ${OPERATOR} --enable ${canonical}" ;;
            *) die MSG-D3T3 "could not add ${canonical} to ${OPERATOR}'s allowlist -- nothing changed" ;;
        esac
        ai_tools_log_structured info \
            "operator ${caller} added ${canonical} to ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "added ${canonical} for ${OPERATOR}"
        ;;
    remove)
        # A missing allowlist has no entry to remove -- report it and succeed, so an unclaim that
        # runs twice is not an error. The library drops the exclusion line too, so de-registering
        # a project the operator had parked leaves no '!' behind to park whatever is claimed at
        # that path next.
        if [[ ! -f "${allowlist}" ]]; then
            note MSG-V9K7 "no allowlist for ${OPERATOR} -- nothing to remove"
            exit 0
        fi
        if [[ "$(ai_tools_conf_allowlist_state "${allowlist}" "${canonical}")" == absent ]]; then
            note MSG-H7J9 "nothing to remove: ${canonical} is not listed for ${OPERATOR}"
            exit 0
        fi
        ai_tools_conf_allowlist_remove "${allowlist}" "${canonical}" \
            || die MSG-K2G9 "could not remove ${canonical} from ${OPERATOR}'s allowlist -- a line naming it survived, so that project is still registered"
        ai_tools_log_structured info \
            "operator ${caller} removed ${canonical} from ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "removed ${canonical} for ${OPERATOR}"
        ;;
    enable)
        # The one action that WIDENS the target's launch gate. It does not append a line: the '!' comes off
        # the line the operator wrote, in place, and a path the file does not name is refused
        # rather than registered -- registering one is a claim, which scans for secrets first.
        rc=0; ai_tools_conf_allowlist_enable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) note MSG-E2G7 "not disabled for ${OPERATOR}: ${canonical} -- nothing to enable"
               exit 0 ;;
            *) die MSG-H9V5 "the entry is STILL disabled for ${OPERATOR}: ${canonical} -- the line was not rewritten" ;;
        esac
        ai_tools_log_structured info \
            "operator ${caller} enabled ${canonical} in ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "enabled ${canonical} for ${OPERATOR}"
        ;;
    disable)
        # Park the target's project: the '!' goes on, in place. It moves to LESS access -- no
        # session starts there and the ownership helpers stop resolving an owner for it -- so a
        # path the file does not name is refused rather than parked (there would be no entry to
        # park, and inventing one would register a project without claiming it).
        rc=0; ai_tools_conf_allowlist_disable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die MSG-H6K3 "not listed for ${OPERATOR}: ${canonical} -- there is no entry to disable" ;;
            *) die MSG-C7Q4 "could not disable ${canonical} for ${OPERATOR} -- nothing changed" ;;
        esac
        ai_tools_log_structured info \
            "operator ${caller} disabled ${canonical} in ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "disabled ${canonical} for ${OPERATOR}"
        ;;
esac

exit 0
