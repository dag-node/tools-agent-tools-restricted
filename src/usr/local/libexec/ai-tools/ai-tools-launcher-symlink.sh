#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-launcher-symlink
# Atomically repoints an agent's stable launcher symlink -- /opt/ai-tools/bin/<launcher> -- at a
# versioned binary under the sandbox account's nvm. Idempotent: it skips the repoint (and its log
# line) when the link already points at the target and that target's entrypoint is already labelled,
# so the daily same-version updater run is a quiet no-op.
#
# It is agent-agnostic: the launcher is the TARGET's own basename, accepted only when an ENABLED
# agent manifest claims it -- the same allowlist ai-tools-run builds -- so the link it writes is
# always <bin>/<launcher> for a declared launcher, and never differs from the binary it points at.
#
# /opt/ai-tools/bin is locked (0551 root:ai-tools), so this root helper is the ONLY way the
# sandbox updater can move a launcher symlink; it validates its argument strictly, because the
# caller is the agent-reachable handback socket (SYMLINK verb) or install.sh, never sudo.
#
# Deploy: sudo install -o root -g root -m 750 \
#             src/usr/local/libexec/ai-tools/ai-tools-launcher-symlink.sh /usr/local/libexec/ai-tools/ai-tools-launcher-symlink

set -euo pipefail

readonly BIN_DIR="/opt/ai-tools/bin"
readonly TARGET="${1:?usage: ai-tools-launcher-symlink <versioned-launcher-path>}"

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/symlink.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-launcher-symlink"
AI_TOOLS_LOG_FILE="symlink.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

err() { ai_tools_log_error "$*"; printf 'ai-tools-launcher-symlink: %s\n' "$*" >&2; exit 1; }

# Authoritative validation of the caller-supplied path: EXACTLY the shape a wrapper resolves --
# a single vMAJOR.MINOR.PATCH component under the sandbox toolchain, then bin/, then ONE path
# component, the launcher name. The anchored regex admits no '..' and no extra slashes.
readonly RE='^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/([A-Za-z0-9._-]+)$'
[[ "${TARGET}" =~ $RE ]] \
    || err "target is not a versioned launcher path: ${TARGET}"
readonly LAUNCHER="${BASH_REMATCH[1]}"
# The link is NAMED from the target's own basename, so the two can never diverge: this helper
# cannot be made to point one agent's stable link at another binary.
readonly LINK="${BIN_DIR}/${LAUNCHER}"

# ...and that name must belong to an ENABLED agent: without this, any binary sitting in a
# versioned bin/ could be given a stable link in the locked control-plane dir. An unresolvable
# allowlist REFUSES rather than degrading to "allow anything", so probe the resolver rather than
# assume the source succeeded (providers.lib.sh returns non-zero without defining a resolver when
# its dependency is missing).
readonly PROVIDERS_LIB="/usr/local/lib/ai-tools/providers.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/providers.lib.sh
if ! source "${PROVIDERS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    err "cannot resolve the enabled agents (${PROVIDERS_LIB}) -- refusing to repoint ${LINK}"
fi
launcher_is_enabled=no
while IFS=$'\t' read -r _ _ manifest_launcher; do
    [[ "${manifest_launcher}" == "${LAUNCHER}" ]] && launcher_is_enabled=yes
done < <(ai_tools_enabled_agents 2>/dev/null)
[[ "${launcher_is_enabled}" == yes ]] \
    || err "no enabled agent provides the launcher \"${LAUNCHER}\" -- refusing to repoint ${LINK}"

# The target is itself an npm symlink into the package; -e follows it, so this
# also confirms the final binary is present (not a dangling/half-installed tree).
[[ -e "${TARGET}" ]] || err "target does not exist: ${TARGET}"

# Operate only inside the expected locked dir, never an attacker-substituted one.
[[ -d "${BIN_DIR}" ]] || err "${BIN_DIR} missing"

# Idempotency guard. The repoint is also the sole trigger for the ai-tools-relabel.path watcher
# (the rename below changes an entry in the watched bin directory), so skipping it when no change
# changed must not skip a pending relabel: entrypoint_relabel_pending reports whether the binary
# the link resolves to still needs its ai_tools_exec_t label -- true for a freshly (re)minted
# entrypoint, including a same-version reinstall. Any uncertainty answers "pending", so the
# guard falls through to a repoint.
entrypoint_relabel_pending() {
    # 0 = relabel pending (or unknowable) -> must repoint to trip the watcher.
    # 1 = entrypoint already correctly labelled, or SELinux/the module inactive -> may skip.
    command -v selinuxenabled >/dev/null 2>&1 || return 1
    selinuxenabled 2>/dev/null || return 1
    command -v matchpathcon >/dev/null 2>&1 || return 1
    local real want have
    real="$(realpath -e "${TARGET}" 2>/dev/null)" || return 0   # unresolvable -> repoint
    want="$(matchpathcon -n "${real}" 2>/dev/null | awk -F: '{print $3}' || true)"
    [[ "${want}" == "ai_tools_exec_t" ]] || return 1            # no rule governs this path
    have="$(stat -c '%C' -- "${real}" 2>/dev/null | awk -F: '{print $3}' || true)"
    [[ "${have}" == "ai_tools_exec_t" ]] && return 1            # already labelled -> skip
    return 0                                                    # mislabelled -> repoint to relabel
}

# Skip the repoint only when the stable link already points at TARGET AND no relabel is
# pending: no work to do, so the daily no-op timer run stops churning the symlink and the
# log. Otherwise fall through to the atomic repoint below.
if [[ "$(readlink -- "${LINK}" 2>/dev/null || true)" == "${TARGET}" ]] \
   && ! entrypoint_relabel_pending; then
    ai_tools_log_debug "already current: ${LINK} -> ${TARGET} (entrypoint labelled; no repoint)"
    printf 'ai-tools-launcher-symlink: already current: %s -> %s\n' "${LINK}" "${TARGET}"
    exit 0
fi

# Atomic repoint: build the new symlink under a temp name in the same dir, then
# rename(2) it over the old one -- no window in which the stable link is missing.
# (The sandbox account cannot race us here: it has no write access to this 0551
# dir; only root can write it.)
tmp="$(mktemp -u "${BIN_DIR}/.${LAUNCHER}.XXXXXX")"
ln -s "${TARGET}" "${tmp}"
mv -Tf "${tmp}" "${LINK}"
ai_tools_log_info "repointed ${LINK} -> ${TARGET}"
printf 'ai-tools-launcher-symlink: %s -> %s\n' "${LINK}" "${TARGET}"

# This helper does NOT relabel the new entrypoint: it runs in ai_tools_handback_t, which is granted
# no relabel rights by design (ai_tools.te), so the privilege stays off the agent-reachable
# domain. The rename above instead trips the root-side ai-tools-relabel.path watcher, which
# watches the bin DIRECTORY and so fires for whichever agent's link moved; `ai-tools --relabel`
# is the on-demand path. A label still wrong at launch makes ai-tools-run fail closed.
# See .claude/rules/updater.rule.md.
