#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-allowlist
# Reads and edits ANOTHER enrolled operator's project registry (<their-home>/.config/ai-tools/project-registry, the file
# ai_tools_conf__resolve_registry picks) on behalf of the operator invoking sudo. This is the one privileged seam behind
# `ai-tools ... --for <operator>`: it lets a human operator claim a project for a service account that has no password
# and therefore cannot authenticate the claim's own root helpers.
#
# Root is needed for READS as well as writes: a registry is 0600 inside a 0700 .config/ai-tools (ai-tools-admin seeds
# an operator's config), so one operator cannot see another's list at all. `--print` exists for exactly
# that, and the CLI snapshots it for the decisions a claim makes (is the path listed, disabled, or absent)
# before routing the mutation back through the four editing actions. It reads an existing registry and refuses a missing
# one with the code the add refuses it with, so the snapshot -- a --for run's first sudo -- carries the refusal ahead
# of any write the run makes.
#
# The registry is the LAUNCH GATE: an entry here is what lets that operator's agent start in the directory,
# and what makes the ownership handback restore files to them. Editing another operator's gate stays inside the trust
# model's "%ai-ops operators are trusted" boundary, but it is not something the sandbox account may ever reach,
# so the helper is 750 root:root, and holds NO NOPASSWD grant (the invoking human authenticates, like
# `ai-tools-{lockdown,setfacl,relabel}`), and every mutation is logged with both the caller and the target.
#
# Every gate this helper applies resolves to LESS access on failure, never more:
#   - no SUDO_UID (a bare root call, or an unclean sudo context)  -> refuse, write no entry
#   - the CALLER is not in OPERATORS                              -> refuse, write no entry
#   - the TARGET is not in OPERATORS                              -> refuse, write no entry
#   - the target is the sandbox account or root                   -> refuse, write no entry
#   - the target has no registry file yet                         -> refuse, print nothing, write no entry
#   - the target's registry is a legacy allowed-projects, or the  -> refuse, print nothing, write no entry
#     grammar refuses a line of it
#   - the path is not a real directory, or is a protected system  -> refuse, write no entry
#     directory (safe-paths backstop)
#   - a required library will not load                            -> refuse, write no entry
# A refused run leaves the target's allowlist byte-identical, so a failure can only ever leave the agent with fewer
# places to launch than the operator intended, never more.
#
# Usage:
#   ai-tools-allowlist --operator <name> --print
#   ai-tools-allowlist --operator <name> --add    <absolute-project-path>
#   ai-tools-allowlist --operator <name> --remove <absolute-project-path>
#   ai-tools-allowlist --operator <name> --enable  <absolute-project-path>
#   ai-tools-allowlist --operator <name> --disable <absolute-project-path>
#
# `--enable` and `--disable` neither add nor drop a line: they take the leading '%' off an entry, or put it
# on, IN PLACE. They are the privileged half of `atr projects enable`/`projects disable` (and of the claim's re-enable
# prompt), and they are deliberately not an add/remove pair: the line keeps its position and its comment,
# so a park-and-restore round trip leaves an ordered, commented registry exactly as its operator wrote it.
#
# Installed 750 root:root, so only root runs it. Its domain rule is cli.rule.md.

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"

# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads. Matched inline: this helper does not load the library.
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-allowlist: %s\n' "$*" >&2; exit 1
}
# note: the same line on stdout, for an action that completed or found the entry already in the state it asked for. It
# does not exit, so the exit status stays where the action decides it, and it carries the prefix so no call site repeats
# it.
note() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}"; fi
    printf 'ai-tools-allowlist: %s\n' "$*"
}

# ── Arguments ────────────────────────────────────────────────────────────────────
# One target operator (`--operator`) and exactly one action. The action's path argument is attached to the flag rather
# than free-standing, so a missing value cannot silently shift into the operator slot.
OPERATOR=""
ACTION=""
TARGET_PATH=""
# _need_value <flag> [remaining args...]: die unless a value follows <flag> AND that value is not itself option-shaped.
# A leading '-' is a mistyped flag far more often than a real operator name or path, and taking it at face value would
# bind the wrong thing silently. The remaining args are passed through so an absent value is a zero-length expansion
# rather than an empty string.
_need_value() {
    local flag="$1"; shift
    (( $# )) || die MSG-Z7E9 "a value is required after ${flag}"
    [[ "$1" != -* ]] || die MSG-S4M8 "a value is required after ${flag}, not another option: $1"
}
# _one_action: five arms refuse a second action, and it is one situation, so the refusal is stated once here rather than
# at each of them.
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
# Bare sources under `set -e`: an unloadable library aborts the helper before it touches anything, rather than leaving
# this pass unable to recognise a protected path or an unenrolled operator.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source /usr/local/lib/ai-tools/operator.lib.sh
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source /usr/local/lib/ai-tools/safe-paths.lib.sh
declare -F ai_tools_conf__has_allowlist_entry >/dev/null 2>&1 \
    || die MSG-C9K7 "config library defines no allowlist matcher -- refusing (fail closed)"
declare -F ai_tools_operator__load_operators >/dev/null 2>&1 \
    || die MSG-F5N3 "operator library defines no operator list -- refusing (fail closed)"
declare -F ai_tools_safe_paths__assert_safe_target >/dev/null 2>&1 \
    || die MSG-E8H6 "safe-paths library defines no protected-path guard -- refusing (fail closed)"

# Shared leveled logger: journald (always) + the root-only /var/log/ai-tools/allowlist.log. Best-effort -- a no-op
# fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-allowlist"
AI_TOOLS_LOG_FILE="allowlist.log"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source /usr/local/lib/ai-tools/log.lib.sh 2>/dev/null; then
    ai_tools_log__write() { :; }; ai_tools_log__debug() { :; }; ai_tools_log__info() { :; }
    ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
    ai_tools_log__structured() { :; }; ai_tools_log__coded() { :; }
fi

# ── Caller gate ──────────────────────────────────────────────────────────────────
# The identity that authorizes this edit is the operator who invoked sudo, resolved from the kernel-supplied SUDO_UID
# rather than from SUDO_USER (a name is spoofable through the environment; the uid sudo sets is not). A direct root call
# arrives without that context and is refused rather than defaulting to some operator.
caller_uid="${SUDO_UID:-}"
[[ -n "${caller_uid}" ]] \
    || die MSG-T6R6 "run me through sudo as an operator (no SUDO_UID) -- nothing changed"
caller="$(id -un "${caller_uid}" 2>/dev/null)" \
    || die MSG-W6P9 "unknown invoking uid ${caller_uid} -- nothing changed"
[[ "${caller}" != "${SANDBOX_USER}" ]] \
    || die MSG-N3S4 "the sandbox account may not manage an allowlist -- nothing changed"

ai_tools_operator__load_operators 2>/dev/null \
    || die MSG-Z7N7 "no operators configured -- run: atr admin operators add <user>"

_is_operator() {
    local want="$1" op
    for op in "${AI_TOOLS_OPERATOR__OPERATORS[@]}"; do
        [[ "${op}" == "${want}" ]] && return 0
    done
    return 1
}

_is_operator "${caller}" \
    || die MSG-J6J3 "caller ${caller} is not a configured ai-tools operator -- nothing changed"

# ── Target gate ──────────────────────────────────────────────────────────────────
# The target must be an enrolled operator: the whole point of the entry is that ai-tools-setfacl and the handback
# helpers later resolve THIS path to THIS operator, and they resolve only over OPERATORS. Writing an entry
# for an unenrolled name would create a launch gate no ownership machinery can act on.
[[ "${OPERATOR}" != "${SANDBOX_USER}" ]] \
    || die MSG-Y3B2 "the sandbox account is not an operator and must not own projects -- nothing changed"
[[ "${OPERATOR}" != "root" ]] \
    || die MSG-B2Y8 "root is not an operator -- nothing changed"
_is_operator "${OPERATOR}" \
    || die MSG-M3R6 "target ${OPERATOR} is not a configured ai-tools operator -- enrol it first with:
       atr admin operators add ${OPERATOR}"

target_home="$(getent passwd "${OPERATOR}" 2>/dev/null | cut -d: -f6)" \
    || die MSG-A2M5 "cannot resolve ${OPERATOR} -- nothing changed"
[[ -n "${target_home}" && -d "${target_home}" ]] \
    || die MSG-R4C4 "no home directory for ${OPERATOR} -- nothing changed"
# Resolve the target's allowlist through operator.lib's own path helper, so the AI_TOOLS_ALLOWLIST test hook applies
# here exactly as it does on every resolve_owner path and the helper cannot drift from what the root helpers read.
is_primary=secondary
[[ "${OPERATOR}" == "${AI_TOOLS_OPERATOR__OPERATORS[0]}" ]] && is_primary=primary
allowlist="$(ai_tools_operator__get_allowlist_path "${OPERATOR}" "${is_primary}")"
readonly caller allowlist target_home
registry_state="$(ai_tools_conf__read_registry_state "${allowlist}")"
readonly registry_state

# require_target_config: the target's allowlist must already exist. This helper reads or changes an existing file
# and does not create one: `ai-tools-admin operators add` is where an operator's config comes from -- the config files,
# at the modes that keep the sandbox account out (0700 dir, 0600 files) -- and it is idempotent. A missing allowlist
# therefore means the name reached OPERATORS another way, or the home did not exist at enrolment; seeding it from here
# would write the allowlist and leave the account without the secret-patterns file beside it, so the refusal names
# the command that writes the whole config.
require_target_config() {
    if [[ -f "${allowlist}" ]]; then
        require_migrated_registry
        return 0
    fi
    die MSG-S7Y3 "no ai-tools config yet for ${OPERATOR} (no ${allowlist}) -- nothing changed.
       If the ${OPERATOR} account is meant to run sandboxed sessions, enrol it first with:
       atr admin operators add ${OPERATOR}"
}

# require_migrated_registry: refuse a target whose registry is the allowed-projects an earlier release wrote, and one no
# reader accepts. The editors write the current format alone, and a snapshot of a legacy file would hand the CLI a file
# it reads under another grammar, so every action refuses, `--print` included, naming the migration. The rest is
# the gate-side loader's read of the real file, so a line the grammar refuses and an exclusion spelled through a link
# the sandbox account can change both refuse here as they refuse the target's launch gate and every root helper;
# the CLI's snapshot is not owned by the account whose links it names, so the link check is made here alone. The library
# names the line or the link on stderr. The migration-pending refusal is the CLI's own situation, so its code is printed
# here and defined there.
require_migrated_registry() {
    local rc=0
    # shellcheck disable=SC2034  # filled through their names by the loader
    local -a gate_allowed=() gate_excluded=()
    if [[ "${registry_state}" == legacy ]]; then
        printf 'MSG-J6S8\nai-tools-allowlist: %s\n' "the registry ${allowlist} is the allowed-projects an earlier release wrote and is not migrated -- nothing changed; run atr admin system post-upgrade, which migrates it to ~/.config/ai-tools/project-registry" >&2
        exit 1
    fi
    ai_tools_conf__load_allowlist "${allowlist}" gate_allowed gate_excluded || rc=$?
    case "${rc}" in
        0)   ;;
        2|3) printf 'MSG-Y7K5\nai-tools-allowlist: %s\n' "the project registry ${allowlist} holds a line named above that no reader accepts -- nothing changed" >&2
             exit 1 ;;
        *)   die "cannot read the project registry ${allowlist} -- nothing changed" ;;
    esac
}

# die_registry_changed <action>: the refusal for an editor's status 3 after require_target_config passed -- the file
# became legacy or took a refused line between the check and the edit. The library's MSG-B8U2 line, first on stderr,
# names the line.
die_registry_changed() {
    die MSG-G8Q7 "the registry changed during the edit -- ${canonical} was not ${1} for ${OPERATOR}, and the line above names the reason"
}

# ── print ────────────────────────────────────────────────────────────────────────
# Read-only, and the only action that does not require a path. A missing allowlist is refused as the add refuses it.
# An existing file is printed as it stands; one holding only comments is an empty list to the caller (the CLI's
# snapshot).
if [[ "${ACTION}" == print ]]; then
    require_target_config
    cat -- "${allowlist}"
    exit 0
fi

# ── Path gate (add/remove/enable/disable) ────────────────────────────────────────
# Canonicalise before every check and before the write, so a symlink or '..' cannot smuggle a path past
# the protected-paths backstop and land a different directory in the launch gate.
canonical="$(realpath -e "${TARGET_PATH}" 2>/dev/null)" \
    || die MSG-Q5X7 "not an existing path: ${TARGET_PATH} -- nothing changed"
[[ -d "${canonical}" ]] \
    || die MSG-R6C5 "not a directory: ${canonical} -- nothing changed"
ai_tools_safe_paths__assert_safe_target "${canonical}" "allowlist ${ACTION}" || exit 3
readonly canonical

# This run edits one operator's allowlist for one project, so the operator and the project ride as per-run log context
# (logging.rule.md). AI_TOOLS_OPERATOR names the operator whose launch gate the entry decides; the caller who ran
# the command is recorded as AI_TOOLS_CALLER, so an edit made through `--for` keeps the two apart in the trail.
AI_TOOLS_LOG_OPERATOR="${OPERATOR}"
AI_TOOLS_LOG_PROJECT="${canonical}"

# Every edit here is one call into conf.lib.sh's allowlist-editing functions -- the same implementation the CLI runs
# against the operator's own file and install.sh against its checkout. What is left here is this helper's own job:
# deciding WHO may edit WHOSE registry, and recording it. The library reports its outcomes apart -- 0 applied (or
# already so), 1 the write failed, 2 the request does not apply from the current state, 3 the file is legacy or holds
# a refused line, 4 (add) the path cannot be written as a registry line -- and each is reported to the caller
# distinctly, since a "not listed" and a "could not write" send an operator to different places. require_target_config
# has refused a legacy or refused file before any edit, so a 3 is a file that changed between the check and the edit,
# reported with the library's own line.

case "${ACTION}" in
    add)
        require_target_config
        rc=0; ai_tools_conf__allowlist_add "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die MSG-T7B6 "that path is DISABLED or carved out for ${OPERATOR}: ${canonical} -- a '%' line parks it
       or a '!' line withholds it, and adding a second line would leave that line winning at the launch gate.
       A parked project is re-enabled instead:
       ai-tools-allowlist --operator ${OPERATOR} --enable ${canonical}" ;;
            3) die_registry_changed added ;;
            # The CLI's refusal for a name the grammar cannot carry, printed as its twin: a `--for` claim reaches it
            # here.
            4) printf 'MSG-Z9R2\nai-tools-allowlist: %s\n' "this directory's name cannot be written as a registry line: ${canonical} -- nothing changed; rename the directory, then claim it" >&2
               exit 1 ;;
            *) die MSG-D3T3 "could not add ${canonical} to ${OPERATOR}'s allowlist -- nothing changed" ;;
        esac
        ai_tools_log__structured info \
            "operator ${caller} added ${canonical} to ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "added ${canonical} for ${OPERATOR}"
        ;;
    remove)
        # A missing allowlist has no entry to remove -- report it and succeed, so an unclaim that runs twice is not
        # an error. The library drops the park line too, so de-registering a project the operator had parked leaves no
        # '%' behind to park whatever is claimed at that path next; a carve-out line is the operator's own edit
        # and stays.
        if [[ ! -f "${allowlist}" ]]; then
            note MSG-V9K7 "no allowlist for ${OPERATOR} -- nothing to remove"
            exit 0
        fi
        require_migrated_registry
        case "$(ai_tools_conf__read_allowlist_state "${allowlist}" "${canonical}")" in
            absent|excluded)
                note MSG-H7J9 "nothing to remove: ${canonical} is not listed for ${OPERATOR}"
                exit 0 ;;
        esac
        ai_tools_conf__allowlist_remove "${allowlist}" "${canonical}" \
            || die MSG-K2G9 "could not remove ${canonical} from ${OPERATOR}'s allowlist -- a line naming it survived, so that project is still registered"
        ai_tools_log__structured info \
            "operator ${caller} removed ${canonical} from ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "removed ${canonical} for ${OPERATOR}"
        ;;
    enable)
        # The one action that WIDENS the target's launch gate. It does not append a line: the '%' comes off the line
        # the operator wrote, in place, and a path the file does not name is refused rather than registered --
        # registering one is a claim, which scans for secrets first. A '!' line is a carve-out and is not lifted.
        require_target_config
        rc=0; ai_tools_conf__allowlist_enable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) note MSG-E2G7 "not disabled for ${OPERATOR}: ${canonical} -- nothing to enable"
               exit 0 ;;
            3) die_registry_changed enabled ;;
            *) die MSG-H9V5 "the entry is STILL disabled for ${OPERATOR}: ${canonical} -- the line was not rewritten" ;;
        esac
        ai_tools_log__structured info \
            "operator ${caller} enabled ${canonical} in ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "enabled ${canonical} for ${OPERATOR}"
        ;;
    disable)
        # Park the target's project: the '%' goes on, in place. It moves to LESS access -- no session starts there
        # and the ownership helpers stop resolving an owner for it -- so a path the file does not name is refused rather
        # than parked (there would be no entry to park, and inventing one would register a project without claiming it).
        require_target_config
        rc=0; ai_tools_conf__allowlist_disable "${allowlist}" "${canonical}" || rc=$?
        case "${rc}" in
            0) ;;
            2) die MSG-H6K3 "not listed for ${OPERATOR}: ${canonical} -- there is no entry to disable" ;;
            3) die_registry_changed disabled ;;
            *) die MSG-C7Q4 "could not disable ${canonical} for ${OPERATOR} -- nothing changed" ;;
        esac
        ai_tools_log__structured info \
            "operator ${caller} disabled ${canonical} in ${OPERATOR}'s allowlist" \
            "AI_TOOLS_CALLER=${caller}" "AI_TOOLS_RESULT=ok"
        note "disabled ${canonical} for ${OPERATOR}"
        ;;
esac

exit 0
