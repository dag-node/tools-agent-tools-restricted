#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-relabel
# Apply (or revert) the ai_tools_project_t SELinux label on ONE approved project
# directory, so the confined agent (ai_tools_t) can read and write it. This is the
# privileged half of project claiming: `semanage fcontext` needs root, which the
# unprivileged `ai-tools` CLI does not have, so --project-claim / --project-create
# invoke this via sudo. There is NO sudoers NOPASSWD grant for it (by design): sudo
# prompts for the projects user's password, the same pattern as ai-tools-lockdown.
#
# The labelling body lives in the shared relabel.lib.sh (single source of truth,
# also used by selinux/install-selinux.sh's allowlist sweep). This helper only
# validates the target and dispatches.
#
# Labelling a path requires it to be in the operator's allowed-projects allowlist:
# only approved projects may carry the agent-accessible type. Reverting (--remove)
# is lenient -- it cleans up a path that may already have been unregistered, and
# restorecon only ever restores the system default context.
#
# Runs as root via sudo, invoked by YOU (the projects user) -- not ai-tools:
#       sudo ai-tools-relabel <dir>            # label <dir> ai_tools_project_t
#       sudo ai-tools-relabel --remove <dir>   # revert <dir> to its default type
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#     src/usr/local/sbin/ai-tools/ai-tools-relabel.sh /usr/local/sbin/ai-tools/ai-tools-relabel

set -euo pipefail

readonly RELABEL_LIB="/usr/local/lib/ai-tools/relabel.lib.sh"

# Operator identity (PROJECTS_HOME for the allowlist path) from /etc/ai-tools/operator.conf
# via the shared resolver. AI_TOOLS_OPERATOR_CONF / AI_TOOLS_ALLOWLIST override the paths --
# root-only test hooks: sudo strips them (env_reset, not in env_keep), so neither the operator
# nor the agent can inject them in production (relabel is only ever reached as root via sudo).
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
if source "${OPERATOR_LIB}" 2>/dev/null; then
    ai_tools_load_operator || true
else
    PROJECTS_USER=''; PROJECTS_HOME=''; PROJECTS_GROUP=''; PROJECTS_UID=-1
fi
readonly ALLOWLIST="${AI_TOOLS_ALLOWLIST:-${PROJECTS_HOME}/.config/ai-tools/allowed-projects}"

# Shared leveled logger: journald (always) + the root-only file
# /var/log/ai-tools/relabel.log. Best-effort -- a no-op fallback keeps the helper
# working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log_info() { :; }; ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

die() { ai_tools_log_error "$*"; printf 'ai-tools-relabel: error: %s\n' "$*" >&2; exit 1; }

# Protected-paths backstop (safe-paths.lib.sh): refuse to relabel a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=/dev/null
source "${SAFE_PATHS_LIB}"

[[ "${EUID}" -eq 0 ]] || die "must run as root (via sudo)"

# allowlisted <dir>: 0 when <dir> is an exact, non-excluded entry in the operator's
# allowed-projects allowlist. Mirrors selinux/install-selinux.sh for_each_project:
# an absolute path per line, '!'-prefixed lines exclude.
allowlisted() {
    local dir="$1"
    [[ -f "${ALLOWLIST}" ]] || return 1
    grep -qxF "!${dir}" "${ALLOWLIST}" && return 1     # explicit exclusion wins
    grep -qxF "${dir}" "${ALLOWLIST}"
}

# ── Parse args ─────────────────────────────────────────────────────────────────
remove=false
target=""
for a in "$@"; do
    case "${a}" in
        --remove|-r) remove=true ;;
        -*)          die "unknown option: ${a} (allowed: --remove)" ;;
        *)           [[ -z "${target}" ]] && target="${a}" || die "takes a single path" ;;
    esac
done
[[ -n "${target}" ]] || die "usage: ai-tools-relabel [--remove] <dir>"

dir="$(realpath -e "${target}" 2>/dev/null)" || die "path not found: ${target}"
[[ -d "${dir}" ]] || die "not a directory: ${dir}"
# Refuse to (un)label a protected system directory.
ai_tools_assert_safe_target "${dir}" "relabel" || exit 3

# shellcheck source=/dev/null
source "${RELABEL_LIB}" 2>/dev/null || die "missing label library: ${RELABEL_LIB}"

if ai_tools_relabel_available; then :; else
    # SELinux off or restorecon absent -- nothing to do, and not an error: the
    # confinement layer simply is not in play on this host.
    echo "ai-tools-relabel: SELinux inactive -- no labelling needed for ${dir}"
    exit 0
fi

if ${remove}; then
    if ai_tools_unlabel_project "${dir}"; then
        echo "ai-tools-relabel: reverted ${dir} to its default SELinux type"
        ai_tools_log_info "unlabelled project ${dir}"
    else
        die "failed to revert SELinux label on ${dir}"
    fi
else
    allowlisted "${dir}" \
        || die "refusing to label ${dir}: not in the allowed-projects allowlist"
    rc=0; ai_tools_label_project "${dir}" || rc=$?
    case "${rc}" in
        0) echo "ai-tools-relabel: labelled ${dir} ai_tools_project_t"
           ai_tools_log_info "labelled project ${dir} ai_tools_project_t" ;;
        2) echo "ai-tools-relabel: SELinux inactive -- no labelling needed for ${dir}" ;;
        *) die "failed to label ${dir} (is the ai_tools policy module loaded? run: sudo selinux/install-selinux.sh install)" ;;
    esac
fi
