#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-safedir
# Registers (or removes) one project path in git's safe.directory list inside the agent's
# global git config /opt/ai-tools/.gitconfig, the file the sandbox account reads on startup
# to decide which repositories git may operate in. The tree is operator-owned (the dual-
# ownership model), so an entry is what lets the agent's git trust it.
#
# Why a root helper: .gitconfig is root-owned and 644 (world-READABLE so the operator and the
# launch wrapper can see the list without belonging to @SANDBOX_GROUP@, root-write-only so the
# safe.directory list stays out of the confined agent's reach). The management CLI (ai-tools
# --project-claim/--project-unclaim) and the launch wrapper run as the operator, who lacks
# write access to a root-owned file, so they reach this write through sudo -- the same
# no-NOPASSWD model as ai-tools-setfacl/-relabel/-unclaim: the operator is prompted for a
# password and the sandbox account has no grant for it. The agent has no path to .gitconfig
# writes at all, so unlike the handback helpers this one is operator-only and stays off the
# handback socket.
#
# Usage:
#   ai-tools-safedir [<absolute-project-path>]            add the entry (idempotent)
#   ai-tools-safedir --remove [<absolute-project-path>]   drop the entry (idempotent)
# The path defaults to the current directory (the tooling passes it explicitly; the default
# eases a manual run from inside a project).
#
# Validation. On ADD the path must be a real directory that some operator's allowlist covers
# (operator.lib.sh resolve_owner) -- the same allow/exclude gate the other helpers share, so a
# safe.directory entry is only ever granted for an approved project; a path no operator covers
# is left untouched (exit 0, fail-closed). On --REMOVE the gate is SKIPPED: the CLI drops the
# allowlist entry BEFORE calling this on unclaim, so by the time the entry is removed the path
# is no longer allowlisted -- mirroring ai-tools-relabel --remove's lenient membership check.
#
# Idempotent: an ADD of an already-listed path and a --REMOVE of an absent one are quiet
# no-ops, so a re-run (or a re-claim) is safe.
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
        *)  [[ -z "${TARGET}" ]] && TARGET="${arg}" \
                || { printf 'ai-tools-safedir: too many arguments\n' >&2; exit 2; } ;;
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
# shellcheck source=/dev/null
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/safedir.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-safedir"
AI_TOOLS_LOG_FILE="safedir.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

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

# _confirm_cwd <question>: an inline [Y]/n gate (default yes -- registering safe.directory is a
# restrict-nothing convenience) that fires only when the path was defaulted from the current
# directory AND a terminal is present, so a bare interactive `sudo ai-tools-safedir` confirms
# before registering/dropping cwd. When an explicit path was given (the tooling passes one) or
# the run is non-interactive, it is a no-op, which keeps the helper from double-prompting after
# the CLI/wrapper's own confirm. Returns non-zero on an explicit decline.
_confirm_cwd() {
    ${FROM_CWD} || return 0
    [[ -t 0 ]] || return 0
    local reply
    printf '%s [Y]/n ' "$1" >&2
    read -r reply || reply=""
    [[ ! "${reply}" =~ ^[nN] ]]
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
        # literal and anchors match the whole line.
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
