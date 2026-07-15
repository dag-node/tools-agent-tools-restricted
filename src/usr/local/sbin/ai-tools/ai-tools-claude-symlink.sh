#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-claude-symlink
# Atomically repoints the stable /opt/ai-tools/bin/claude symlink at a versioned
# claude binary under ai-tools' nvm. Idempotent: it skips the repoint (and its log
# line) when the link already points at the target and that target's entrypoint needs
# no relabel, so the daily same-version updater run is a quiet no-op.
#
# /opt/ai-tools/bin is locked (0551 root:ai-tools): ai-tools cannot write
# it, so the agent can neither tamper with nvm-update.sh nor swap the symlink the
# wrapper resolves and trusts. This helper is therefore the ONLY way the sandbox
# updater can move the symlink after a Node upgrade -- it runs as root (the only
# principal that can write the locked dir) and validates its argument strictly
# before acting.
#
# Invocation: the handback socket's SYMLINK verb (ai-tools-handback daemon, root)
#   when nvm-update.sh repoints the symlink after a Node upgrade, and directly by
#   install.sh (already root). Not a sudo target -- ai-tools has no sudo rights.
#
# Deploy: sudo install -o root -g root -m 750 \
#             src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh /usr/local/sbin/ai-tools/ai-tools-claude-symlink

set -euo pipefail

readonly LINK="/opt/ai-tools/bin/claude"
readonly BIN_DIR="/opt/ai-tools/bin"
readonly TARGET="${1:?usage: ai-tools-claude-symlink <versioned-claude-path>}"

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/symlink.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-claude-symlink"
AI_TOOLS_LOG_FILE="symlink.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

err() { ai_tools_log_error "$*"; printf 'ai-tools-claude-symlink: %s\n' "$*" >&2; exit 1; }

# Authoritative validation -- do NOT trust the sudoers glob: wildcards in command
# arguments can match '/', so the rule is only a coarse filter. The target must be
# an absolute, '..'-free path of EXACTLY the form the wrapper resolves and the
# (ai-tools:ai-tools) claude sudoers rule matches: a single vMAJOR.MINOR.PATCH
# component and no extra path segments. The anchored regex admits no '..' or
# slashes beyond the fixed structure.
readonly RE='^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$'
[[ "${TARGET}" =~ $RE ]] \
    || err "target is not a versioned claude path: ${TARGET}"

# The target is itself an npm symlink into the package; -e follows it, so this
# also confirms the final binary is present (not a dangling/half-installed tree).
[[ -e "${TARGET}" ]] || err "target does not exist: ${TARGET}"

# Operate only inside the expected locked dir, never an attacker-substituted one.
[[ -d "${BIN_DIR}" ]] || err "${BIN_DIR} missing"

# Idempotency guard. The repoint is also the sole trigger for the ai-tools-relabel.path
# watcher (the atomic rename below changes the link inode), so skipping it when nothing
# changed must not skip a pending relabel. entrypoint_relabel_pending reports whether the
# claude.exe the link resolves to still needs its ai_tools_exec_t label restored -- true
# for a freshly (re)minted bin_t entrypoint, including a same-version reinstall. Any
# uncertainty answers "pending", so the guard falls through to a repoint -- the safe
# default that preserves the pre-idempotency always-repoint-and-relabel behaviour.
entrypoint_relabel_pending() {
    # 0 = relabel pending (or unknowable) -> must repoint to trip the watcher.
    # 1 = entrypoint already correctly labelled, or SELinux/the module inactive -> may skip.
    command -v selinuxenabled >/dev/null 2>&1 || return 1
    selinuxenabled 2>/dev/null || return 1
    command -v matchpathcon >/dev/null 2>&1 || return 1
    local real want have
    real="$(realpath -e "${TARGET}" 2>/dev/null)" || return 0   # unresolvable -> repoint
    want="$(matchpathcon -n "${real}" 2>/dev/null | awk -F: '{print $3}' || true)"
    [[ "${want}" == "ai_tools_exec_t" ]] || return 1            # module does not govern this path
    have="$(stat -c '%C' -- "${real}" 2>/dev/null | awk -F: '{print $3}' || true)"
    [[ "${have}" == "ai_tools_exec_t" ]] && return 1           # already labelled -> skip
    return 0                                                    # mislabelled -> repoint to relabel
}

# Skip the repoint only when the stable link already points at TARGET AND no relabel is
# pending: nothing to do, so the daily no-op timer run stops churning the symlink and the
# log. Otherwise fall through to the atomic repoint below.
if [[ "$(readlink -- "${LINK}" 2>/dev/null || true)" == "${TARGET}" ]] \
   && ! entrypoint_relabel_pending; then
    ai_tools_log_debug "already current: ${LINK} -> ${TARGET} (entrypoint labelled; no repoint)"
    printf 'ai-tools-claude-symlink: already current: %s -> %s\n' "${LINK}" "${TARGET}"
    exit 0
fi

# Atomic repoint: build the new symlink under a temp name in the same dir, then
# rename(2) it over the old one -- no window in which the stable link is missing.
# (ai-tools cannot race us here: it has no write access to this 0551 dir; only
# root can write it.)
tmp="$(mktemp -u "${BIN_DIR}/.claude.XXXXXX")"
ln -s "${TARGET}" "${tmp}"
mv -Tf "${tmp}" "${LINK}"
ai_tools_log_info "repointed ${LINK} -> ${TARGET}"
printf 'ai-tools-claude-symlink: %s -> %s\n' "${LINK}" "${TARGET}"

# This helper does NOT relabel the new claude.exe entrypoint. It runs in
# ai_tools_handback_t, which is deliberately not granted relabel rights (ai_tools.te), so a
# restorecon here is a no-op under enforcing. Restoring ai_tools_exec_t on a freshly
# installed (bin_t) entrypoint is driven by the ai-tools-relabel.path watcher, which the
# atomic rename above trips (the link's inode changes on each repoint), and by
# `ai-tools --relabel` on demand -- both root-side, off the agent-reachable handback domain.
# The idempotency guard skips the rename only when it has confirmed the entrypoint already
# carries ai_tools_exec_t, so a pending relabel always drives a repoint and thus the
# watcher. If the label is still wrong at launch, claude-run fail-closes (refuses) rather
# than running unconfined.
