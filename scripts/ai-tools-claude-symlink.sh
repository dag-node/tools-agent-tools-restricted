#!/usr/bin/env bash
# /usr/local/sbin/ai-tools-claude-symlink
# Atomically repoints the stable /opt/ai-tools/bin/claude symlink at a versioned
# claude binary under ai-tools' nvm.
#
# /opt/ai-tools/bin is locked (550 @INSTALL_USER@:ai-tools): ai-tools cannot write
# it, so the agent can neither tamper with nvm-update.sh nor swap the symlink the
# wrapper resolves and trusts. This helper is therefore the ONLY way the sandbox
# updater can move the symlink after a Node upgrade -- it runs as root (the only
# principal that can write the locked dir) and validates its argument strictly
# before acting.
#
# Sudoers rule (in /etc/sudoers.d/ai-tools-claude):
#   ai-tools ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools-claude-symlink /opt/ai-tools/.nvm/versions/node/v[0-9]*
#
# Called as root by nvm-update-ai-tools.sh (via sudo) and by install.sh.
#
# Deploy: sudo install -o root -g root -m 750 \
#             scripts/ai-tools-claude-symlink.sh /usr/local/sbin/ai-tools-claude-symlink

set -euo pipefail

readonly LINK="/opt/ai-tools/bin/claude"
readonly BIN_DIR="/opt/ai-tools/bin"
readonly TARGET="${1:?usage: ai-tools-claude-symlink <versioned-claude-path>}"

err() { printf 'ai-tools-claude-symlink: %s\n' "$*" >&2; exit 1; }

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
# (ai-tools cannot race us here: it has no write access to this 550 dir; only
# root and the install user do.)
tmp="$(mktemp -u "${BIN_DIR}/.claude.XXXXXX")"
ln -s "${TARGET}" "${tmp}"
mv -Tf "${tmp}" "${LINK}"
printf 'ai-tools-claude-symlink: %s -> %s\n' "${LINK}" "${TARGET}"
