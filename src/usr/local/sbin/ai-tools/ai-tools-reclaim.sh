#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-reclaim
# Reclaims ownership of agent-written files under a project back to the owning operator, on demand
# -- the operator-invoked counterpart to the session sweeps. It walks <project> and hands each
# @SANDBOX_USER@-owned path to ai-tools-chown, the SAME per-path trust boundary (allowlist
# re-validation, exclusions, secret rules, TOCTOU-safe chown) the handback and sweeps use, so it
# carries none of its own. Nothing is .git-specific: .git is simply the one tree the per-session
# sweeps skip, so its objects linger @SANDBOX_USER@-owned, which is the usual reason to run this --
# e.g. before an ACL-unaware backup, where ownership (not the user:<operator> ACL) is what survives
# an rsync/tar. By default the heavy/transient trees (node_modules, .venv, ...) are left untouched
# -- their agent ownership is harmless (world-readable, regenerable) -- while .git is included;
# --full reclaims those too, for a fully operator-owned tree (a complete, ACL-independent backup).
#
# Runs as root via sudo under ai-tools --reclaim (no-NOPASSWD, like ai-tools-setfacl); root is
# required to chown files the projects user does not own.
#
# Deploy: sudo install -o root -g root -m 750 \
#     src/usr/local/sbin/ai-tools/ai-tools-reclaim.sh /usr/local/sbin/ai-tools/ai-tools-reclaim

set -euo pipefail

# Args: an optional --full flag (anywhere) reclaims the heavy trees skipped by default too; the
# remaining argument is the absolute project path.
FULL=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --full) FULL=true ;;
        -*) printf 'ai-tools-reclaim: unknown option: %s\n' "${arg}" >&2; exit 2 ;;
        *)  [[ -z "${TARGET}" ]] && TARGET="${arg}" \
                || { printf 'ai-tools-reclaim: too many arguments\n' >&2; exit 2; } ;;
    esac
done
[[ -n "${TARGET}" ]] \
    || { printf 'usage: ai-tools-reclaim [--full] <absolute-project-path>\n' >&2; exit 2; }
readonly TARGET FULL
readonly CHOWN_BIN="/usr/local/sbin/ai-tools/ai-tools-chown"
readonly SANDBOX_USER="@SANDBOX_USER@"

# Operator-identity resolver: a path no operator's allowlist covers is left untouched (fail-closed);
# ai-tools-chown re-validates each path independently regardless.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald + the root-only chown.log (co-located with the per-path chowns
# ai-tools-chown records there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-reclaim"
AI_TOOLS_LOG_FILE="chown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Heavy/transient tree names from the shared list, MINUS .git -- the one tree the reclaim includes.
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true
declare -a prune=()
for _n in "${AI_TOOLS_PRUNE_NAMES[@]:-}"; do [[ "${_n}" == ".git" ]] || prune+=("${_n}"); done

canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
ai_tools_resolve_owner "${canonical}" || exit 0

# find <project> -xdev ( heavy-tree names ) -prune -o ( file|dir ) -user SANDBOX_USER -print0
declare -a expr=( "${canonical}" -xdev )
if (( ${#prune[@]} > 0 )); then
    expr+=( '(' )
    for i in "${!prune[@]}"; do
        (( i > 0 )) && expr+=( -o )
        expr+=( -name "${prune[$i]}" )
    done
    expr+=( ')' -prune -o )
fi
expr+=( '(' -type f -o -type d ')' -user "${SANDBOX_USER}" -print0 )

declare -i n=0
while IFS= read -r -d '' path; do
    "${CHOWN_BIN}" "${path}" </dev/null || true
    n=$((n + 1))
done < <(find "${expr[@]}" 2>/dev/null)
ai_tools_log_info "reclaim: handed back ${n} agent-owned path(s) under ${canonical}"
exit 0
