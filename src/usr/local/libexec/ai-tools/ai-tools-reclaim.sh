#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-reclaim
# Reclaims ownership of agent-written files under a project back to the owning operator, on demand
# -- the operator-invoked counterpart to the session sweeps. It walks <project> and hands each
# @SANDBOX_USER@-owned path to ai-tools-chown, the SAME per-path trust boundary (allowlist
# re-validation, exclusions, secret rules, TOCTOU-safe chown) the handback and sweeps use, so it
# carries none of its own. No part of it is .git-specific: .git is simply the one tree the per-session
# sweeps skip, so its objects linger @SANDBOX_USER@-owned, which is the usual reason to run this --
# e.g. before an ACL-unaware backup, where ownership (not the user:<operator> ACL) is what survives
# an rsync/tar. By default the heavy/transient trees (node_modules, .venv, ...) are left untouched
# -- their agent ownership is harmless (world-readable, regenerable) -- while .git is included;
# --full reclaims those too, for a fully operator-owned tree (a complete, ACL-independent backup).
#
# The walk is two-phase: collect, then apply. An empty hand-back set is reported as exactly
# that before any change; otherwise ONE confirmation covers the whole set (count + a
# sample with owner/group/mode), and each path is applied via ai-tools-chown --yes so the
# per-path prompt never fires inside the batch.
#
# Runs as root via sudo under ai-tools --reclaim (no-NOPASSWD, like ai-tools-setfacl); root is
# required to chown files the projects user does not own.
#
# Deploy: sudo install -o root -g root -m 750 \
#     src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh /usr/local/libexec/ai-tools/ai-tools-reclaim

set -euo pipefail

# Every refusal and outcome line this helper prints goes through warn, so the component prefix is
# stated once here instead of at each site. A leading message code (msg.lib.sh states the form) is
# printed on its own line ahead of the message, the shape tests/lib/harness.sh's assert_msg reads.
# Matched inline, since this helper reports before msg.lib.sh is loaded. The reports that are not
# one situation -- the pre-scan sample and its count -- print raw below, and carry no code.
warn() {
    local IFS=' ' code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
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
# Required, fail-closed: this helper prints agent-named paths to stderr and the log, so it
# needs ai_tools_log_sanitize -- a missing logger must refuse, not emit an agent path raw.
if ! source "${LOG_LIB}"; then
    printf 'ai-tools-reclaim: FATAL: cannot source %s\n' "${LOG_LIB}" >&2
    exit 1
fi

# Directory-skip selector (shared single source of truth). A missing lib leaves a stub that
# descends everywhere -- a slower but correct walk.
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
# safe-paths.lib.sh already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh

canonical="$(realpath -e -- "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole walk if the project root is a protected system directory, before find.
ai_tools_assert_safe_target "${canonical}" "reclaim" || exit 3
# Not under any operator's allowed-projects -> no path legitimately to reclaim. Say so rather than
# exiting silently, so a direct `sudo ai-tools-reclaim` (past the CLI's own front-line check) still
# reports why it reclaimed no path. The path is operator-supplied, so it prints without log_sanitize.
ai_tools_resolve_owner "${canonical}" || {
    warn MSG-K9H2 "nothing to reclaim -- ${canonical} is not under any claimed project"
    ai_tools_log_info "reclaim: ${canonical} not under any claimed project"
    exit 0
}

# Default reclaim walks .git but skips the heavy trees; --full descends everywhere. The lib owns
# both defaults -- the helper only names the consumer.
if ${FULL}; then ai_tools_skip_find_expr reclaim-full '' "${canonical}"; else ai_tools_skip_find_expr reclaim '' "${canonical}"; fi
# find <project> -xdev <skip dirs> -prune -o ( file|dir ) -user SANDBOX_USER -print0
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -type f -o -type d ')' -user "${SANDBOX_USER}" -print0 )

# Two-phase: collect first, so a run with no path to hand back says so and stops before
# any change, and a run with work confirms ONCE for the whole set -- ai-tools-chown --yes
# then applies each path without re-asking (one question, not one per .git object). The
# sample carries owner/group/mode columns so what is about to change is visible up front.
declare -a paths=()
while IFS= read -r -d '' path; do
    paths+=("${path}")
done < <(find "${expr[@]}" 2>/dev/null)

if (( ${#paths[@]} == 0 )); then
    warn MSG-J6B2 "nothing to reclaim under ${canonical}"
    ai_tools_log_info "reclaim: nothing to reclaim under ${canonical}"
    exit 0
fi

warn "${#paths[@]} agent-owned path(s) under ${canonical}, e.g.:"
for path in "${paths[@]:0:3}"; do
    read -r og m < <(stat -c '%U:%G %a' "${path}" 2>/dev/null) || { og='?'; m='?'; }
    printf '  %-18s %-4s %s\n' "${og}" "${m}" "$(ai_tools_log_sanitize "${path}")" >&2
done
(( ${#paths[@]} > 3 )) && printf '  ... and %d more\n' "$(( ${#paths[@]} - 3 ))" >&2

# Default yes: handing agent-written files back to their operator is the reclaim's whole
# point, so Enter (and a no-tty batch run) proceeds; n leaves ownership as it stands.
if ! ai_tools_msg_confirm "Hand back all ${#paths[@]} path(s)?" y; then
    warn MSG-T9M5 "declined; ownership left as it stands"
    ai_tools_log_info "reclaim: declined for ${canonical}"
    exit 0
fi

# Count CONFIRMED handbacks (ai-tools-chown exit 0), not attempts: a path that stopped being
# @SANDBOX_USER@-owned between the collect and apply phases is a legitimate skip, and reporting it
# as handed back would overstate what changed. A non-zero tally is surfaced, not hidden.
declare -i confirmed=0 failed=0
for path in "${paths[@]}"; do
    if "${CHOWN_BIN}" --yes "${path}" </dev/null; then
        confirmed+=1
    else
        failed+=1
    fi
done
if (( failed > 0 )); then
    warn MSG-J4W5 "handed back ${confirmed} path(s), ${failed} skipped/failed under ${canonical}"
    ai_tools_log_warn "reclaim: handed back ${confirmed} path(s), ${failed} skipped/failed under ${canonical}"
else
    warn "handed back ${confirmed} path(s) under ${canonical}"
    ai_tools_log_info "reclaim: handed back ${confirmed} agent-owned path(s) under ${canonical}"
fi
exit 0
