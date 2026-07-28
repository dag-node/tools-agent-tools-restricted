#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint
# Give every enabled agent's launcher binary the ai_tools_exec_t label, so its exec fires the
# -> ai_tools_t domain transition and the launched session is confined. A freshly installed
# binary is born the default type (bin_t/lib_t) and only restorecon applies the entrypoint type.
#
# It names no agent: each ai-tools-agents-* package declares its own entrypoint path pattern
# (entrypoint_fcontext in its manifest under /usr/local/lib/ai-tools/agents.d), and this helper
# registers that pattern as a local file-context rule and relabels what it matches. The labelling
# body lives in relabel.lib.sh, shared with selinux/install-selinux.sh's verify pass so the two
# cannot drift.
#
# Usage:
#   ai-tools-relabel-entrypoint              relabel every enabled agent's entrypoint (idempotent)
#   ai-tools-relabel-entrypoint --remove <agent>
#                                            drop that agent's file-context rule and restore
#                                            default labels -- run while its manifest still
#                                            exists (rpm %preun of the agent package)
#
# Runs as root (a domain that holds relabel), never the sandbox account. Three callers drive the
# default form: ai-tools-bootstrap at provision time, the ai-tools-relabel.path watcher after an
# upgrade, and `ai-tools --relabel` on demand. The operators' sudo grant covers the ZERO-ARGUMENT
# form only, so --remove is reachable by root alone. The domain story -- the watcher, the
# ai-tools-run fail-closed backstop, and why the relabel privilege stays off the agent-reachable
# handback domain -- is in .claude/rules/updater.rule.md.
#
# No-ops when SELinux is off or the ai_tools module is not installed: there is no
# ai_tools_exec_t to assign, which is a supported (DAC-only) deployment, not a failure.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#     src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh \
#     /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint

set -euo pipefail

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/relabel.log
# (shared with ai-tools-relabel). Best-effort -- a no-op fallback keeps the helper working
# if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel-entrypoint"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log_info() { :; }; ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

say() { printf 'ai-tools-relabel-entrypoint: %s\n' "$*"; }
die() { ai_tools_log_error "$*"; printf 'ai-tools-relabel-entrypoint: error: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "must run as root (via sudo)"

# The labelling body + the manifest resolver it reads. REQUIRED: without them this helper can
# resolve no agent and would silently label nothing, leaving the next launch to fail closed on a
# mislabelled entrypoint with no explanation. Bare source under set -e.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
source /usr/local/lib/ai-tools/relabel.lib.sh
declare -F ai_tools_label_agent_entrypoints >/dev/null 2>&1 \
    || die "relabel.lib.sh is incomplete -- reinstall ai-tools-base"

# --remove <agent>: erase-time counterpart, invoked by the agent package's own %preun while its
# manifest is still on disk. Dropping the rule matters because the type it names belongs to the
# base policy, which the host may erase next.
if [[ "${1:-}" == --remove ]]; then
    agent="${2:?usage: ai-tools-relabel-entrypoint --remove <agent-name>}"
    rc=0; ai_tools_unlabel_agent_entrypoint "${agent}" || rc=$?
    case "${rc}" in
        0) say "dropped the entrypoint file-context for ${agent}"
           ai_tools_log_info "dropped entrypoint fcontext for ${agent}" ;;
        2) say "SELinux confinement inactive -- no file-context to drop" ;;
        *) die "${agent} declares no usable entrypoint_fcontext -- nothing dropped" ;;
    esac
    exit 0
fi
[[ "$#" -eq 0 ]] || die "usage: ai-tools-relabel-entrypoint [--remove <agent-name>]"

# Collect the report first, so the lib's return code survives (2 = the SELinux layer is not
# active here, which is a supported deployment and not a failure).
report=""; status=0
report="$(ai_tools_label_agent_entrypoints)" || status=$?
if (( status == 2 )); then
    say "SELinux confinement inactive -- no entrypoint labelling needed"
    exit 0
fi

# Render the lib's status lines: it reports per entrypoint and per agent, this decides what an
# operator reads and what fails the run.
labelled=0 mislabelled=0
if [[ -n "${report}" ]]; then
    while read -r verdict subject detail; do
        case "${verdict}" in
            ok)   labelled=$(( labelled + 1 ))
                  say "labelled ${AI_TOOLS_ENTRYPOINT_TYPE}: ${subject}"
                  ai_tools_log_info "relabelled entrypoint ${AI_TOOLS_ENTRYPOINT_TYPE}: ${subject}" ;;
            bad)  mislabelled=$(( mislabelled + 1 ))
                  say "WARNING: ${subject} is '${detail}', NOT ${AI_TOOLS_ENTRYPOINT_TYPE}"
                  ai_tools_log_warn "${subject} did not take ${AI_TOOLS_ENTRYPOINT_TYPE} (now '${detail}')" ;;
            none) say "${subject}: its declared entrypoint is not installed -- nothing to label"
                  ai_tools_log_info "${subject}: no installed entrypoint to label" ;;
            skip) say "${subject}: skipped -- ${detail}"
                  ai_tools_log_warn "${subject}: entrypoint labelling skipped -- ${detail}" ;;
        esac
    done <<< "${report}"
fi

# A mislabelled entrypoint is a confinement gap: the transition would not fire, so fail rather
# than report success. ai-tools-run refuses such a launch too -- this is the earlier, clearer
# signal.
(( mislabelled == 0 )) \
    || die "${mislabelled} entrypoint(s) did not take ${AI_TOOLS_ENTRYPOINT_TYPE} -- is the ai_tools module loaded? run: sudo selinux/install-selinux.sh install"
(( status == 0 )) \
    || die "an agent's entrypoint file-context could not be applied (see above)"

if (( labelled > 0 )); then
    say "all ${labelled} entrypoint(s) labelled ${AI_TOOLS_ENTRYPOINT_TYPE} -- exit any running session and relaunch"
    ai_tools_log_info "relabelled ${labelled} entrypoint(s) ${AI_TOOLS_ENTRYPOINT_TYPE}"
elif [[ -z "${report}" ]]; then
    say "no enabled agent declares an entrypoint file-context -- nothing to label"
fi
