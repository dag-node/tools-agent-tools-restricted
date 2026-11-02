#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-safedir
# Registers or removes one project path in git's safe.directory list in the agent's global git config
# /opt/ai-tools/.gitconfig, so the agent's git trusts an operator-owned project tree.
#
# .gitconfig is root-owned 644: world-readable (the operator and launch wrapper read the list without joining
# @SANDBOX_GROUP@) and root-write-only (the safe.directory list stays out of the confined agent's reach). The operator
# reaches this write through sudo, under `atr projects claim`/`projects unclaim` and the launch wrapper -- no-NOPASSWD,
# like `ai-tools-{setfacl,relabel,unclaim}`. The agent has no path here, so unlike the handback helpers this one is
# operator-only and off the handback socket.
#
# Each edit is a `git config --file` write, which renames a new inode over the file; the helper then restores the file's
# owner, mode and SELinux type through control-plane.lib.sh, a by-path label write that is sound because /opt/ai-tools
# does not carry group write (CP_HOME_MODE), so the sandbox account cannot place a name there.
#
# ADD requires the path to be an allowlisted project (resolve_owner); `--remove` does not take a registry gate,
# so an entry is removable whatever the registry holds for the path, before or after its de-list, and it removes
# the value as git holds it where the argument is that spelling, the canonical path of the directory otherwise. Both are
# idempotent; the path defaults to cwd. A list git cannot read, and an entry the list still holds after its removal,
# exit 1, so a caller does not report a trust entry gone that is still there.
#
# Usage:  ai-tools-safedir [--remove] [<absolute-project-path>]
#
# Installed 750 root:root, so only root runs it. Its domain rule is cli.rule.md.

set -euo pipefail

# Every refusal this helper makes goes through warn, so the component prefix is stated once here instead of at each
# site. A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads. Matched inline, since this helper reports before msg.lib.sh is loaded.
# The printed text is left in _warn_text, and the code it printed in _warn_code, for the sites that also record
# the condition: the log call passes the variable, so the code literal stays at the emit call the reference index reads
# as its definition (messaging.rule.md).
_warn_text="" _warn_code=""
warn() {
    local IFS=' ' code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    _warn_text="$*" _warn_code="${code}"
    printf 'ai-tools-safedir: %s\n' "${_warn_text}" >&2
}

# The agent's global git config, holding the safe.directory list this helper edits. AI_TOOLS_GITCONFIG points it
# at a fixture file for the unit test.
readonly GITCONFIG="${AI_TOOLS_GITCONFIG:-/opt/ai-tools/.gitconfig}"
readonly GROUP="@SANDBOX_GROUP@"

# Args: an optional --remove flag (anywhere) selects removal; the remaining argument is the
# absolute project path.
REMOVE=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --remove) REMOVE=true ;;
        -*) warn MSG-V7J8 "unknown option: ${arg}"; exit 2 ;;
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                warn MSG-F6Q4 "too many arguments"; exit 2
            fi ;;
    esac
done
# No path given -> default to the current directory, and remember it was defaulted so an interactive standalone run
# confirms before registering cwd (see _confirm_cwd). The tooling passes an explicit path, so this default and its
# prompt only affect a manual run.
FROM_CWD=false
if [[ -z "${TARGET}" ]]; then
    TARGET="${PWD}"
    FROM_CWD=true
fi
readonly TARGET REMOVE FROM_CWD

# Operator-identity resolver (operator.lib.sh): on ADD, confirms an operator's allowlist covers the path. A missing lib
# leaves ai_tools_operator__resolve_owner a fail-closed stub, so an ADD leaves the owner unresolved and the file
# untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_operator__resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/safedir.log. Best-effort -- a no-op
# fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-safedir"
AI_TOOLS_LOG_FILE="safedir.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log__write() { :; }; ai_tools_log__debug() { :; }; ai_tools_log__info() { :; }
    ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
fi

# Shared yes/no prompt (ai_tools_msg__confirm; see msg.lib.sh). REQUIRED like safe-paths.lib.sh: the bare source
# under `set -e` aborts if it is missing -- a valid install ships it, so there is no fallback. Include-guarded,
# so a re-source is a no-op.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this helper renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

# The control plane's applier for a file a root writer replaced by rename (control-plane.lib.sh), the one this helper's
# write takes. Required: without it the file would keep the group, mode and SELinux type the rename gave the new inode,
# which the installed layout reports as drift.
readonly CONTROL_PLANE_LIB="/usr/local/lib/ai-tools/control-plane.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/control-plane.lib.sh
source "${CONTROL_PLANE_LIB}" 2>/dev/null || true
if ! declare -F ai_tools_control_plane__restore_file_attributes >/dev/null 2>&1; then
    warn MSG-T6R4 "cannot load ${CONTROL_PLANE_LIB} -- not editing safe.directory; reinstall ai-tools-base"
    ai_tools_log__coded error "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=failed"
    exit 1
fi

# Bring the gitconfig back to root:GROUP 644 and the type its file context gives it after a write. git config edits
# through a lock file renamed over the target, so the new inode takes root's group and umask and the type
# of /opt/ai-tools; world-readable for the operator and the wrapper, writable only by root. The parent is root-owned
# and not group-writable, which is what makes the library's by-path label write sound here. Best-effort: each step
# that did not take is reported by the library and recorded here, in place of a hard stop.
_reassert_mode() {
    local warning
    ai_tools_control_plane__restore_file_attributes "root:${GROUP}" 644 "${GITCONFIG}" && return 0
    for warning in "${AI_TOOLS_CONTROL_PLANE__RESTORE_WARNINGS[@]}"; do
        ai_tools_log__coded warning "${warning%%$'\t'*}" "${warning#*$'\t'}" "AI_TOOLS_RESULT=failed"
    done
}

# _read_entries: set SAFEDIR_ENTRIES to the safe.directory values GITCONFIG holds, one per line, empty when the file
# or the key is absent (git's exit 1); refuse with exit 1 when git cannot read the file, since every decision this
# helper makes reads the list and an unread list would read as one without the path. git runs from /: it reads its
# working directory at startup and exits 128 when that directory was deleted, and sudo hands the helper the caller's
# directory. The read works for any principal (644), so the CLI's own pre-check and this one agree.
SAFEDIR_ENTRIES=""
_read_entries() {
    local status=0
    SAFEDIR_ENTRIES="$(git -C / config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null)" || status=$?
    (( status <= 1 )) && return 0
    warn MSG-E7T5 "cannot read the safe.directory list in ${GITCONFIG} (git exit ${status}) -- not editing safe.directory"
    ai_tools_log__coded error "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=failed"
    exit 1
}

# _listed <path>: 0 when <path> is a safe.directory entry in the list _read_entries last read.
_listed() {
    grep -qxF -- "$1" <<< "${SAFEDIR_ENTRIES}"
}

# _confirm_cwd <question>: a shared-confirm gate (default yes -- registering safe.directory is an additive change
# to git's trust list) that fires only when the path was defaulted from the current directory AND a terminal is present,
# so a bare interactive `sudo ai-tools-safedir` confirms before registering/dropping cwd. When an explicit path was
# given (the tooling passes one) or the run is non-interactive, it is a no-op, which keeps the helper
# from double-prompting after the CLI/wrapper's own confirm. Returns non-zero on an explicit decline.
_confirm_cwd() {
    ${FROM_CWD} || return 0
    [[ -t 0 ]] || return 0
    ai_tools_msg__confirm "$1" y
}

if ${REMOVE}; then
    # Tolerate a since-deleted directory: `realpath -m` canonicalises lexically without requiring the path to exist,
    # so a stale entry for a removed tree is still cleanable. No registry gate (see the header). The value is removed
    # as typed where git holds that spelling: `atr projects list` prints a value as git stores it, and a hand-written
    # spelling through a link or a `..` canonicalises to another string, which would leave the stored value in place
    # and remove a sibling spelling where one exists. The canonical form, the spelling ADD writes, is removed otherwise.
    canonical="$(realpath -m -- "${TARGET}" 2>/dev/null || printf '%s' "${TARGET}")"
    stored_value="${canonical}"
    _read_entries
    _listed "${TARGET}" && stored_value="${TARGET}"
    # The project is the subject of every record this run writes, so it rides as per-run log context (logging.rule.md)
    # instead of being named at each site.
    AI_TOOLS_LOG_PROJECT="${stored_value}"
    _confirm_cwd "Remove ${stored_value} from git safe.directory?" \
        || { ai_tools_log__structured info "declined removing safe.directory ${stored_value}" \
                 "AI_TOOLS_RESULT=refused"; exit 0; }
    if _listed "${stored_value}"; then
        # `--unset-all` takes a value REGEX; escape the path so regex metacharacters in it are literal and anchors match
        # the whole line. The sed program is a single-quoted regex: its $ and () are literal metacharacters, not shell
        # expansions, so SC2016 is expected.
        # shellcheck disable=SC2016
        esc="$(printf '%s' "${stored_value}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"
        # The removal is read back rather than taken from git's status: the CLI reports this exit as the entry gone,
        # and the entry is the agent's git trust in the tree.
        git -C / config --file "${GITCONFIG}" --unset-all safe.directory "^${esc}$" 2>/dev/null || true
        _reassert_mode
        _read_entries
        if _listed "${stored_value}"; then
            warn MSG-X8T6 "safe.directory still lists ${stored_value} after the removal -- ${GITCONFIG} was not changed"
            ai_tools_log__coded error "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=failed"
            exit 1
        fi
        ai_tools_log__structured info "removed safe.directory ${stored_value}" "AI_TOOLS_RESULT=ok"
    else
        ai_tools_log__debug "safe.directory ${stored_value} not listed -- nothing to remove"
    fi
    exit 0
fi

# ADD. The path must be a real directory an operator's allowlist covers. Each refusal is reported as well as recorded:
# a direct `sudo ai-tools-safedir` that declined the path would otherwise exit 0 with no account of itself,
# and the CLI's own report says only that the step ran.
canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || {
    warn MSG-N4D4 "no such directory ${TARGET} -- not registering safe.directory"
    ai_tools_log__coded warning "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=refused"
    exit 0
}
[[ -d "${canonical}" ]] || {
    warn MSG-F4Y6 "not a directory: ${canonical} -- not registering safe.directory"
    ai_tools_log__coded warning "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=refused"
    exit 0
}
# resolve_owner succeeds only when some operator's allowlist covers the (non-excluded) path; otherwise leave the file
# untouched (fail-closed, mirrors the sibling helpers).
ai_tools_operator__resolve_owner "${canonical}" || {
    warn MSG-P5B5 "no operator covers ${canonical} -- not registering safe.directory"
    ai_tools_log__coded info "${_warn_code}" "${_warn_text}" "AI_TOOLS_RESULT=refused"
    exit 0
}
# Past the resolution the operator and the project are known, so each rides as per-run log context for every later
# record (logging.rule.md).
AI_TOOLS_LOG_OPERATOR="${PROJECTS_USER}"
AI_TOOLS_LOG_PROJECT="${canonical}"
_confirm_cwd "Add ${canonical} to git safe.directory?" \
    || { ai_tools_log__structured info "declined adding safe.directory ${canonical}" \
             "AI_TOOLS_RESULT=refused"; exit 0; }

_read_entries
if _listed "${canonical}"; then
    ai_tools_log__debug "safe.directory ${canonical} already listed"
    exit 0
fi
git -C / config --file "${GITCONFIG}" --add safe.directory "${canonical}"
_reassert_mode
ai_tools_log__structured info "added safe.directory ${canonical}" "AI_TOOLS_RESULT=ok"
exit 0
