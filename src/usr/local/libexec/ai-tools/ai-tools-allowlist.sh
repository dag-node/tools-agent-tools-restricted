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
# .config/ai-tools (ai-tools-admin seeds both), so one operator cannot see another's list at
# all. --print exists for exactly that, and the CLI snapshots it for the decisions a claim
# makes (is the path listed, disabled, or absent) before routing the mutation back through the
# four editing actions.
#
# The allowlist is the LAUNCH GATE: an entry here is what lets that operator's agent start in
# the directory, and what makes the ownership handback restore files to them. Editing another
# operator's gate stays inside the trust model's "%ai-ops operators are trusted" boundary, but
# it is not something the sandbox account may ever reach, so the helper is 750 root:root, holds
# NO NOPASSWD grant (the invoking human authenticates, like ai-tools-lockdown/-setfacl/-relabel),
# and every mutation is logged with both the caller and the target.
#
# Every gate below resolves to LESS access on failure, never more:
#   - no SUDO_UID (a bare root call, or an unclean sudo context)  -> refuse, change nothing
#   - the CALLER is not in OPERATORS                              -> refuse, change nothing
#   - the TARGET is not in OPERATORS                              -> refuse, change nothing
#   - the target is the sandbox account or root                   -> refuse, change nothing
#   - the path is not a real directory, or is a protected system  -> refuse, change nothing
#     directory (safe-paths backstop)
#   - a required library will not load                            -> refuse, change nothing
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

die() { printf 'ai-tools-allowlist: %s\n' "$*" >&2; exit 1; }

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
    (( $# )) || die "${flag} needs a value"
    [[ "$1" != -* ]] || die "${flag} needs a value, not another option: $1"
}
while (( $# )); do
    case "$1" in
        --operator) _need_value "$1" "${@:2}"; OPERATOR="$2"; shift 2 ;;
        --print)    [[ -z "${ACTION}" ]] || die "only one action may be given"
                    ACTION=print; shift ;;
        --add)      [[ -z "${ACTION}" ]] || die "only one action may be given"
                    _need_value "$1" "${@:2}"; ACTION=add; TARGET_PATH="$2"; shift 2 ;;
        --remove)   [[ -z "${ACTION}" ]] || die "only one action may be given"
                    _need_value "$1" "${@:2}"; ACTION=remove; TARGET_PATH="$2"; shift 2 ;;
        --enable)   [[ -z "${ACTION}" ]] || die "only one action may be given"
                    _need_value "$1" "${@:2}"; ACTION=enable; TARGET_PATH="$2"; shift 2 ;;
        --disable)  [[ -z "${ACTION}" ]] || die "only one action may be given"
                    _need_value "$1" "${@:2}"; ACTION=disable; TARGET_PATH="$2"; shift 2 ;;
        *)          die "unknown argument: $1
usage: ai-tools-allowlist --operator <name>
       (--print | --add <path> | --remove <path> | --enable <path> | --disable <path>)" ;;
    esac
done
[[ -n "${OPERATOR}" ]] || die "--operator <name> is required"
[[ -n "${ACTION}"   ]] || die "one of --print, --add, --remove, --enable, --disable is required"
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
    || die "config library defines no allowlist matcher -- refusing (fail closed)"
declare -F ai_tools_load_operators >/dev/null 2>&1 \
    || die "operator library defines no operator list -- refusing (fail closed)"
declare -F ai_tools_assert_safe_target >/dev/null 2>&1 \
    || die "safe-paths library defines no protected-path guard -- refusing (fail closed)"

# Shared leveled logger: journald (always) + the root-only /var/log/ai-tools/allowlist.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-allowlist"
AI_TOOLS_LOG_FILE="allowlist.log"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source /usr/local/lib/ai-tools/log.lib.sh 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# ── Caller gate ──────────────────────────────────────────────────────────────────
# The identity that authorizes this edit is the operator who invoked sudo, resolved from the
# kernel-supplied SUDO_UID rather than from SUDO_USER (a name is spoofable through the
# environment; the uid sudo sets is not). A direct root call carries no such context and is
# refused rather than defaulting to some operator.
caller_uid="${SUDO_UID:-}"
[[ -n "${caller_uid}" ]] \
    || die "run me through sudo as an operator (no SUDO_UID) -- nothing changed"
caller="$(id -un "${caller_uid}" 2>/dev/null)" \
    || die "unknown invoking uid ${caller_uid} -- nothing changed"
[[ "${caller}" != "${SANDBOX_USER}" ]] \
    || die "the sandbox account may not manage an allowlist -- nothing changed"

ai_tools_load_operators 2>/dev/null \
    || die "no operators configured -- run: sudo ai-tools-admin operators add <user>"

_is_operator() {
    local want="$1" op
    for op in "${AI_TOOLS_OPERATORS[@]}"; do
        [[ "${op}" == "${want}" ]] && return 0
    done
    return 1
}

_is_operator "${caller}" \
    || die "${caller} is not a configured ai-tools operator -- nothing changed"

# ── Target gate ──────────────────────────────────────────────────────────────────
# The target must be an enrolled operator: the whole point of the entry is that ai-tools-setfacl
# and the handback helpers later resolve THIS path to THIS operator, and they resolve only over
# OPERATORS. Writing an entry for an unenrolled name would create a launch gate no ownership
# machinery can act on.
[[ "${OPERATOR}" != "${SANDBOX_USER}" ]] \
    || die "the sandbox account is not an operator and must not own projects -- nothing changed"
[[ "${OPERATOR}" != "root" ]] \
    || die "root is not an operator -- nothing changed"
_is_operator "${OPERATOR}" \
    || die "${OPERATOR} is not a configured ai-tools operator -- enrol it first with:
       sudo ai-tools-admin operators add ${OPERATOR}"

target_home="$(getent passwd "${OPERATOR}" 2>/dev/null | cut -d: -f6)" \
    || die "cannot resolve ${OPERATOR} -- nothing changed"
[[ -n "${target_home}" && -d "${target_home}" ]] \
    || die "no home directory for ${OPERATOR} -- nothing changed"
target_group="$(id -gn "${OPERATOR}" 2>/dev/null)" \
    || die "cannot resolve the primary group of ${OPERATOR} -- nothing changed"

# Resolve the target's allowlist through operator.lib's own path helper, so the
# AI_TOOLS_ALLOWLIST test hook applies here exactly as it does on every resolve_owner path and
# the helper cannot drift from what the root helpers read.
is_primary=secondary
[[ "${OPERATOR}" == "${AI_TOOLS_OPERATORS[0]}" ]] && is_primary=primary
allowlist="$(_ai_tools_operator_allowlist "${OPERATOR}" "${is_primary}")"
readonly caller allowlist target_home target_group

# ── print ────────────────────────────────────────────────────────────────────────
# Read-only, and the only action that does not require a path. An absent allowlist prints
# nothing and succeeds: "this operator has approved no projects" is a complete answer, and the
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
    || die "not an existing path: ${TARGET_PATH} -- nothing changed"
[[ -d "${canonical}" ]] \
    || die "not a directory: ${canonical} -- nothing changed"
ai_tools_assert_safe_target "${canonical}" "allowlist ${ACTION}" || exit 3
readonly canonical

# ensure_allowlist: create the target's .config/ai-tools and allowed-projects when absent, owned
# by the TARGET and with the modes ai-tools-admin seeds (0700 dir, 0600 file) -- so a project
# claimed for a freshly enrolled operator does not depend on that operator having logged in yet.
# The file is the target's own data; this helper only ever adds to it.
ensure_allowlist() {
    local cfg="${allowlist%/*}"
    [[ -d "${target_home}/.config" ]] \
        || install -d -o "${OPERATOR}" -g "${target_group}" -m 700 "${target_home}/.config"
    [[ -d "${cfg}" ]] \
        || install -d -o "${OPERATOR}" -g "${target_group}" -m 700 "${cfg}"
    [[ -f "${allowlist}" ]] \
        || install -o "${OPERATOR}" -g "${target_group}" -m 600 /dev/null "${allowlist}"
}

# Every edit below is one call into conf.lib.sh's allowlist-editing functions -- the same
# implementation the CLI runs against the operator's own file and install.sh against its checkout.
# What is left here is this helper's own job: deciding WHO may edit WHOSE registry, and recording
# it. The library reports three outcomes -- 0 applied (or already so), 1 the write failed, 2 the
# request does not apply from the current state -- and each is reported to the caller distinctly,
# since a "not listed" and a "could not write" send an operator to different places.

case "${ACTION}" in
    add)
        ensure_allowlist
        rc=0; ai_tools_conf_allowlist_add "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die "${canonical} is DISABLED for ${OPERATOR} -- a '!' line parks it, and adding a
       second line would leave that '!' winning at the launch gate. Re-enable it instead:
       ai-tools-allowlist --operator ${OPERATOR} --enable ${canonical}" ;;
            *) die "could not add ${canonical} to ${OPERATOR}'s allowlist -- nothing changed" ;;
        esac
        ai_tools_log_info "operator ${caller} added ${canonical} to ${OPERATOR}'s allowlist"
        printf 'ai-tools-allowlist: added %s for %s\n' "${canonical}" "${OPERATOR}"
        ;;
    remove)
        # A missing allowlist has nothing to remove -- report it and succeed, so an unclaim that
        # runs twice is not an error. The library drops the exclusion line too, so de-registering
        # a project the operator had parked leaves no '!' behind to park whatever is claimed at
        # that path next.
        if [[ ! -f "${allowlist}" ]]; then
            printf 'ai-tools-allowlist: %s has no allowlist -- nothing to remove\n' "${OPERATOR}"
            exit 0
        fi
        if [[ "$(ai_tools_conf_allowlist_state "${allowlist}" "${canonical}")" == absent ]]; then
            printf 'ai-tools-allowlist: %s is not listed for %s\n' "${canonical}" "${OPERATOR}"
            exit 0
        fi
        ai_tools_conf_allowlist_remove "${allowlist}" "${canonical}" \
            || die "could not remove ${canonical} from ${OPERATOR}'s allowlist -- a line naming it survived, so that project is still registered"
        ai_tools_log_info "operator ${caller} removed ${canonical} from ${OPERATOR}'s allowlist"
        printf 'ai-tools-allowlist: removed %s for %s\n' "${canonical}" "${OPERATOR}"
        ;;
    enable)
        # The one action that WIDENS the target's launch gate. It adds no line: the '!' comes off
        # the line the operator wrote, in place, and a path the file does not name is refused
        # rather than registered -- registering one is a claim, which scans for secrets first.
        rc=0; ai_tools_conf_allowlist_enable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) printf 'ai-tools-allowlist: %s is not disabled for %s -- nothing to enable\n' \
                   "${canonical}" "${OPERATOR}"; exit 0 ;;
            *) die "${canonical} is STILL disabled for ${OPERATOR} -- the line was not rewritten" ;;
        esac
        ai_tools_log_info "operator ${caller} enabled ${canonical} in ${OPERATOR}'s allowlist"
        printf 'ai-tools-allowlist: enabled %s for %s\n' "${canonical}" "${OPERATOR}"
        ;;
    disable)
        # Park the target's project: the '!' goes on, in place. It moves to LESS access -- no
        # session starts there and the ownership helpers stop resolving an owner for it -- so a
        # path the file does not name is refused rather than parked (there would be no entry to
        # park, and inventing one would register a project without claiming it).
        rc=0; ai_tools_conf_allowlist_disable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die "${canonical} is not listed for ${OPERATOR} -- there is no entry to disable" ;;
            *) die "could not disable ${canonical} for ${OPERATOR} -- nothing changed" ;;
        esac
        ai_tools_log_info "operator ${caller} disabled ${canonical} in ${OPERATOR}'s allowlist"
        printf 'ai-tools-allowlist: disabled %s for %s\n' "${canonical}" "${OPERATOR}"
        ;;
esac

exit 0
