#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-claude-symlink
# Atomically repoints the stable /opt/ai-tools/bin/claude symlink at a versioned
# claude binary under ai-tools' nvm.
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
# installed (bin_t) entrypoint is owned by the updater, which runs ai-tools-relabel-entrypoint
# as root right after this repoint, and by `ai-tools --relabel` on demand. If the label is
# still wrong at launch, claude-run fail-closes (refuses) rather than running unconfined.
