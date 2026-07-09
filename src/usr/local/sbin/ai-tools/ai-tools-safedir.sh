#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-safedir
# Registers or removes one project path in git's safe.directory list in the agent's global git
# config /opt/ai-tools/.gitconfig, so the agent's git trusts an operator-owned project tree.
#
# .gitconfig is root-owned 644: world-readable (the operator and launch wrapper read the list
# without joining @SANDBOX_GROUP@) and root-write-only (the safe.directory list stays out of the
# confined agent's reach). The operator reaches this write through sudo, under ai-tools
# --project-claim/--project-unclaim and the launch wrapper -- no-NOPASSWD, like ai-tools-setfacl/
# -relabel/-unclaim. The agent has no path here, so unlike the handback helpers this one is
# operator-only and off the handback socket.
#
# ADD requires the path to be an allowlisted project (resolve_owner); --remove is lenient, since
# the CLI de-lists the project before removing. Both are idempotent; the path defaults to cwd.
#
# Usage:  ai-tools-safedir [--remove] [<absolute-project-path>]
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-safedir.sh /usr/local/sbin/ai-tools/ai-tools-safedir

set -euo pipefail

# The agent's global git config, holding the safe.directory list this helper edits.
# AI_TOOLS_GITCONFIG points it at a fixture file for the unit test.
readonly GITCONFIG="${AI_TOOLS_GITCONFIG:-/opt/ai-tools/.gitconfig}"
readonly GROUP="@SANDBOX_GROUP@"

# Args: an optional --remove flag (anywhere) selects removal; the remaining argument is the
# absolute project path.
REMOVE=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --remove) REMOVE=true ;;
        -*) printf 'ai-tools-safedir: unknown option: %s\n' "${arg}" >&2; exit 2 ;;
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                printf 'ai-tools-safedir: too many arguments\n' >&2; exit 2
            fi ;;
    esac
done
# No path given -> default to the current directory, and remember it was defaulted so an
# interactive standalone run confirms before registering cwd (see _confirm_cwd). The tooling
# passes an explicit path, so this default and its prompt only affect a manual run.
FROM_CWD=false
if [[ -z "${TARGET}" ]]; then
    TARGET="${PWD}"
    FROM_CWD=true
fi
readonly TARGET REMOVE FROM_CWD

# Operator-identity resolver (operator.lib.sh): on ADD, confirms an operator's allowlist covers
# the path. A missing lib leaves ai_tools_resolve_owner a fail-closed stub, so an ADD finds no
# owner and leaves the file untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/safedir.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-safedir"
AI_TOOLS_LOG_FILE="safedir.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like
# safe-paths.lib.sh: the bare source under set -e aborts if it is missing -- a valid
# install ships it, so there is no fallback. Include-guarded, so a re-source is a no-op.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this helper renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

# Re-assert the control-plane ownership/mode after a write. git config edits via a lock file
# renamed over the target, which can pick up a different group/mode from the parent dir's
# setgid bit and root's umask; pin it back to root:GROUP 644 (world-readable for the operator
# and the wrapper, writable only by root). Best-effort: a logged warning in place of a hard stop.
_reassert_mode() {
    chown "root:${GROUP}" "${GITCONFIG}" 2>/dev/null \
        || ai_tools_log_warn "could not chown ${GITCONFIG} to root:${GROUP}"
    chmod 644 "${GITCONFIG}" 2>/dev/null \
        || ai_tools_log_warn "could not chmod ${GITCONFIG} to 644"
}

# _listed <path>: 0 when <path> is already a safe.directory entry. The read works for any
# principal (644), so the CLI's own pre-check and this one agree.
_listed() {
    git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
        | grep -qxF "$1"
}

# _confirm_cwd <question>: a shared-confirm gate (default yes -- registering safe.directory is a
# restrict-nothing convenience) that fires only when the path was defaulted from the current
# directory AND a terminal is present, so a bare interactive `sudo ai-tools-safedir` confirms
# before registering/dropping cwd. When an explicit path was given (the tooling passes one) or
# the run is non-interactive, it is a no-op, which keeps the helper from double-prompting after
# the CLI/wrapper's own confirm. Returns non-zero on an explicit decline.
_confirm_cwd() {
    ${FROM_CWD} || return 0
    [[ -t 0 ]] || return 0
    ai_tools_msg_confirm "$1" y
}

if ${REMOVE}; then
    # Tolerate a since-deleted directory: realpath -m canonicalises lexically without requiring
    # the path to exist, so a stale entry for a removed tree is still cleanable. No allowlist
    # gate (the CLI de-lists before removing here).
    canonical="$(realpath -m -- "${TARGET}" 2>/dev/null || printf '%s' "${TARGET}")"
    _confirm_cwd "Remove ${canonical} from git safe.directory?" \
        || { ai_tools_log_info "declined removing safe.directory ${canonical}"; exit 0; }
    if _listed "${canonical}"; then
        # --unset-all takes a value REGEX; escape the path so regex metacharacters in it are
        # literal and anchors match the whole line. The sed program is a single-quoted regex:
        # its $ and () are literal metacharacters, not shell expansions, so SC2016 is expected.
        # shellcheck disable=SC2016
        esc="$(printf '%s' "${canonical}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"
        git config --file "${GITCONFIG}" --unset-all safe.directory "^${esc}$" 2>/dev/null || true
        _reassert_mode
        ai_tools_log_info "removed safe.directory ${canonical}"
    else
        ai_tools_log_debug "safe.directory ${canonical} not listed -- nothing to remove"
    fi
    exit 0
fi

# ADD. The path must be a real directory an operator's allowlist covers.
canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || {
    ai_tools_log_warn "no such directory ${TARGET} -- not registering safe.directory"
    exit 0
}
[[ -d "${canonical}" ]] || {
    ai_tools_log_warn "${canonical} is not a directory -- not registering safe.directory"
    exit 0
}
# resolve_owner succeeds only when some operator's allowlist covers the (non-excluded) path;
# otherwise leave the file untouched (fail-closed, mirrors the sibling helpers).
ai_tools_resolve_owner "${canonical}" || {
    ai_tools_log_info "no operator covers ${canonical} -- not registering safe.directory"
    exit 0
}
_confirm_cwd "Add ${canonical} to git safe.directory?" \
    || { ai_tools_log_info "declined adding safe.directory ${canonical}"; exit 0; }

if _listed "${canonical}"; then
    ai_tools_log_debug "safe.directory ${canonical} already listed"
    exit 0
fi
git config --file "${GITCONFIG}" --add safe.directory "${canonical}"
_reassert_mode
ai_tools_log_info "added safe.directory ${canonical}"
exit 0
