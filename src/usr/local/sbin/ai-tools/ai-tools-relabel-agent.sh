#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/sbin/ai-tools/ai-tools-relabel-agent
# Apply the SELinux file-context rules every enabled agent declares, and restore the labels on
# what they match: its launcher binary -> ai_tools_exec_t, so its exec fires the -> ai_tools_t
# domain transition and the session is confined, and its config directory -> ai_tools_home_t, so
# the confined session can write its own state. Freshly installed files are born the default type
# and only restorecon applies these.
#
# It names no agent: each ai-tools-agents-* package declares its own paths (entrypoint_fcontext
# and config_dir in its manifest under /usr/local/lib/ai-tools/agents.d), and this helper
# registers them as local file-context rules. The labelling body lives in relabel.lib.sh, shared
# with selinux/install-selinux.sh's verify pass so the two cannot drift.
#
# Usage:
#   ai-tools-relabel-agent              relabel every enabled agent's paths (idempotent)
#   ai-tools-relabel-agent --remove <agent>
#                                       drop that agent's file-context rules and restore default
#                                       labels -- run while its manifest still exists (rpm %preun
#                                       of the agent package)
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
#     src/usr/local/sbin/ai-tools/ai-tools-relabel-agent.sh \
#     /usr/local/sbin/ai-tools/ai-tools-relabel-agent

set -euo pipefail

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/relabel.log
# (shared with ai-tools-relabel). Best-effort -- a no-op fallback keeps the helper working
# if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel-agent"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log_info() { :; }; ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

say() { printf 'ai-tools-relabel-agent: %s\n' "$*"; }
die() { ai_tools_log_error "$*"; printf 'ai-tools-relabel-agent: error: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "must run as root (via sudo)"

# The labelling body + the manifest resolver it reads. REQUIRED: without them this helper can
# resolve no agent and would silently label nothing, leaving the next launch to fail closed on a
# mislabelled entrypoint with no explanation. Bare source under set -e.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
source /usr/local/lib/ai-tools/relabel.lib.sh
declare -F ai_tools_label_agent_paths >/dev/null 2>&1 \
    || die "relabel.lib.sh is incomplete -- reinstall ai-tools-base"

# --remove <agent>: erase-time counterpart, invoked by the agent package's own %preun while its
# manifest is still on disk. Dropping the rules matters because the types they name belong to the
# base policy, which the host may erase next.
if [[ "${1:-}" == --remove ]]; then
    agent="${2:?usage: ai-tools-relabel-agent --remove <agent-name>}"
    rc=0; ai_tools_unlabel_agent_paths "${agent}" || rc=$?
    case "${rc}" in
        0) say "dropped the file-context rules for ${agent}"
           ai_tools_log_info "dropped the file-context rules for ${agent}" ;;
        2) say "SELinux confinement inactive -- no file-context to drop" ;;
        *) die "${agent} declares no usable path rules -- nothing dropped" ;;
    esac
    exit 0
fi
[[ "$#" -eq 0 ]] || die "usage: ai-tools-relabel-agent [--remove <agent-name>]"

# Collect the report first, so the lib's return code survives (2 = the SELinux layer is not
# active here, which is a supported deployment and not a failure).
report=""; status=0
report="$(ai_tools_label_agent_paths)" || status=$?
if (( status == 2 )); then
    say "SELinux confinement inactive -- no agent labelling needed"
    exit 0
fi

# Render the lib's status lines: it reports per path and per agent, this decides what an operator
# reads and what fails the run. The wanted type travels with a "bad" line, since an agent
# declares two paths that carry different types.
labelled=0 mislabelled=0
if [[ -n "${report}" ]]; then
    while read -r verdict subject detail wanted; do
        case "${verdict}" in
            ok)   labelled=$(( labelled + 1 ))
                  say "labelled: ${subject}"
                  ai_tools_log_info "relabelled ${subject}" ;;
            bad)  mislabelled=$(( mislabelled + 1 ))
                  say "WARNING: ${subject} is '${detail}', NOT ${wanted}"
                  ai_tools_log_warn "${subject} did not take ${wanted} (now '${detail}')" ;;
            none) say "${subject}: ${detail} is not installed -- nothing to label"
                  ai_tools_log_info "${subject}: ${detail} absent, nothing to label" ;;
            skip) say "${subject}: skipped -- ${detail} ${wanted}"
                  ai_tools_log_warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
        esac
    done <<< "${report}"
fi

# A mislabelled path is a broken session: a mislabelled entrypoint runs unconfined (ai-tools-run
# refuses the launch) and a mislabelled config directory leaves the agent unable to write its own
# state. Fail rather than report success -- this is the earlier, clearer signal.
(( mislabelled == 0 )) \
    || die "${mislabelled} path(s) did not take their type -- is the ai_tools module loaded? run: sudo selinux/install-selinux.sh install"
(( status == 0 )) \
    || die "an agent's file-context rule could not be applied (see above)"

if (( labelled > 0 )); then
    say "all ${labelled} path(s) labelled -- exit any running session and relaunch"
    ai_tools_log_info "relabelled ${labelled} agent path(s)"
elif [[ -z "${report}" ]]; then
    say "no enabled agent declares a file-context rule -- nothing to label"
fi
