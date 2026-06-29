#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint
# Restore the ai_tools_exec_t SELinux label on the claude.exe entrypoint(s) under the
# sandbox nvm tree, so the -> ai_tools_t domain transition fires and a launched session is
# confined. A fresh Node tree's claude.exe is born bin_t; this helper restorecons every
# entrypoint under the nvm tree and verifies each took ai_tools_exec_t.
#
# Runs as root (a domain that holds relabel), never the sandbox account. Two callers drive
# it: the ai-tools-relabel.path watcher (automatic, after an upgrade) and `ai-tools
# --relabel` (on demand). The domain story -- the watcher, the claude-run fail-closed
# backstop, and why the relabel privilege stays off the agent-reachable handback domain --
# is in .claude/rules/updater.rule.md. Takes no arguments: it acts only on the fixed
# nvm-tree glob, nothing caller-supplied.
#
# This is the focused, always-installed counterpart to selinux/install-selinux.sh's full
# relabel sweep (entrypoint + home-state + every project); both run the same
# restorecon-and-verify body over the entrypoint glob, so they cannot drift.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#     src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh \
#     /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint

set -euo pipefail

# Fixed nvm-tree entrypoint glob -- the single npm layout for @anthropic-ai/claude-code.
# Unquoted at the for-loop so the '*' (node version) expands; rooted under /opt/ai-tools,
# so nothing here is caller-supplied.
readonly ENTRYPOINT_GLOB='/opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe'

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

# SELinux off, or restorecon/matchpathcon absent -- nothing to label, and not an error:
# the SELinux confinement layer is optional and simply is not active on this host.
if ! { command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled \
        && command -v restorecon >/dev/null 2>&1 \
        && command -v matchpathcon >/dev/null 2>&1; }; then
    say "SELinux inactive -- no entrypoint labelling needed"
    exit 0
fi

# Relabel every installed entrypoint (more than one node version can be on disk
# mid-upgrade) and verify each took the custom entrypoint type.
#
# The ai_tools policy MODULE is optional too: act on an entrypoint only when the
# file-context DB maps it to ai_tools_exec_t (i.e. the module is installed). This is the
# same condition claude-run keys its pre-launch check on -- where the module is absent
# there is no ai_tools_exec_t rule to apply, so leaving the label alone is correct, not a
# failure. 'managed' counts the entrypoints the layer actually governs.
shopt -s nullglob
found=0 managed=0 bad=0
for exe in ${ENTRYPOINT_GLOB}; do
    found=$((found + 1))
    want="$(matchpathcon -n "${exe}" 2>/dev/null | awk -F: '{print $3}' || true)"
    [[ "${want}" == "ai_tools_exec_t" ]] || continue   # module not installed for this path
    managed=$((managed + 1))
    restorecon -Fv "${exe}" 2>/dev/null || true
    ctx="$(ls -Zd "${exe}" 2>/dev/null | awk '{print $1}')"
    if [[ "${ctx}" == *:ai_tools_exec_t:* ]]; then
        say "labelled ai_tools_exec_t: ${exe}"
        ai_tools_log_info "relabelled entrypoint ai_tools_exec_t: ${exe}"
    else
        bad=$((bad + 1))
        say "WARNING: ${exe} is '${ctx:-unknown}', NOT ai_tools_exec_t"
        ai_tools_log_warn "${exe} did not take ai_tools_exec_t (now '${ctx:-unknown}')"
    fi
done

(( found > 0 )) \
    || die "no claude.exe entrypoint found under the nvm tree -- is the sandbox installed?"

if (( managed == 0 )); then
    say "ai_tools SELinux module not installed -- no entrypoint labelling needed"
    exit 0
fi

(( bad == 0 )) \
    || die "${bad} entrypoint(s) did not take ai_tools_exec_t -- is the ai_tools module loaded? run: sudo selinux/install-selinux.sh install"

say "all ${managed} entrypoint(s) labelled ai_tools_exec_t -- exit any running claude and relaunch"
ai_tools_log_info "relabelled ${managed} entrypoint(s) ai_tools_exec_t"
