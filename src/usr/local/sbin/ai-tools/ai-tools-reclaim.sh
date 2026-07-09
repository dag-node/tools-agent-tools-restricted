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
# The walk is two-phase: collect, then apply. Nothing to hand back is reported as exactly
# that before any change; otherwise ONE confirmation covers the whole set (count + a
# sample with owner/group/mode), and each path is applied via ai-tools-chown --yes so the
# per-path prompt never fires inside the batch.
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
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                printf 'ai-tools-reclaim: too many arguments\n' >&2; exit 2
            fi ;;
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
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald + the root-only chown.log (co-located with the per-path chowns
# ai-tools-chown records there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-reclaim"
AI_TOOLS_LOG_FILE="chown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Directory-skip selector (shared single source of truth). A missing lib leaves a stub that
# skips nothing -- a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Protected-paths backstop (safe-paths.lib.sh): refuse to walk a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like
# safe-paths.lib.sh: the bare source under set -e aborts if it is missing -- a valid
# install ships it, so there is no fallback. Include-guarded, so this is a no-op when
# safe-paths.lib.sh above already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh

canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole walk if the project root is a protected system directory, before find.
ai_tools_assert_safe_target "${canonical}" "reclaim" || exit 3
ai_tools_resolve_owner "${canonical}" || exit 0

# Default reclaim walks .git but skips the heavy trees; --full skips nothing. The lib owns
# both defaults -- the helper only names the consumer.
if ${FULL}; then ai_tools_skip_find_expr reclaim-full '' "${canonical}"; else ai_tools_skip_find_expr reclaim '' "${canonical}"; fi
# find <project> -xdev <skip dirs> -prune -o ( file|dir ) -user SANDBOX_USER -print0
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -type f -o -type d ')' -user "${SANDBOX_USER}" -print0 )

# Two-phase: collect first, so a run with nothing to hand back says so and stops before
# any change, and a run with work confirms ONCE for the whole set -- ai-tools-chown --yes
# then applies each path without re-asking (one question, not one per .git object). The
# sample carries owner/group/mode columns so what is about to change is visible up front.
declare -a paths=()
while IFS= read -r -d '' path; do
    paths+=("${path}")
done < <(find "${expr[@]}" 2>/dev/null)

if (( ${#paths[@]} == 0 )); then
    printf 'ai-tools-reclaim: nothing to reclaim under %s\n' "${canonical}" >&2
    ai_tools_log_info "reclaim: nothing to reclaim under ${canonical}"
    exit 0
fi

printf 'ai-tools-reclaim: %d agent-owned path(s) under %s, e.g.:\n' \
    "${#paths[@]}" "${canonical}" >&2
for path in "${paths[@]:0:3}"; do
    read -r og m < <(stat -c '%U:%G %a' "${path}" 2>/dev/null) || { og='?'; m='?'; }
    printf '  %-18s %-4s %s\n' "${og}" "${m}" "${path//[[:cntrl:]]/?}" >&2
done
(( ${#paths[@]} > 3 )) && printf '  ... and %d more\n' "$(( ${#paths[@]} - 3 ))" >&2

# Default yes: handing agent-written files back to their operator is the reclaim's whole
# point, so Enter (and a no-tty batch run) proceeds; n leaves ownership as it stands.
if ! ai_tools_msg_confirm "Hand back all ${#paths[@]} path(s)?" y; then
    printf 'ai-tools-reclaim: declined; ownership left as it stands\n' >&2
    ai_tools_log_info "reclaim: declined for ${canonical}"
    exit 0
fi

declare -i n=0
for path in "${paths[@]}"; do
    "${CHOWN_BIN}" --yes "${path}" </dev/null || true
    n=$((n + 1))
done
printf 'ai-tools-reclaim: handed back %d path(s) under %s\n' "${n}" "${canonical}" >&2
ai_tools_log_info "reclaim: handed back ${n} agent-owned path(s) under ${canonical}"
exit 0
