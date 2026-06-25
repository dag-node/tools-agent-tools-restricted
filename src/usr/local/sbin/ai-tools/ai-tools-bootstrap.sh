#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-bootstrap
# Provision the sandbox account's Node toolchain: create the @SANDBOX_USER@ system account
# and its /opt/ai-tools home (if absent), then install nvm, Node, and the agent's npm package
# AS @SANDBOX_USER@, and point /opt/ai-tools/bin/<tool> at the freshly installed binary. This
# is the one step that reaches the network (nvm from GitHub, packages from npm), so it is a
# command run once by the operator -- never an RPM scriptlet, which must succeed offline and
# inside build chroots. The scheduled nvm-update timer maintains the tree afterwards.
#
# Provider-generic: the npm package is an argument (default @anthropic-ai/claude-code), so the
# same command serves other AI tools. The /opt/ai-tools/bin/<tool> symlink is created only for
# a package that ships a matching launcher.
#
# Idempotent: an existing account, nvm install, or Node version is reused, not rebuilt.
#
# Run as root (it creates a user and execs npm as @SANDBOX_USER@):
#       sudo ai-tools-bootstrap [npm-package]
# nvm defaults to its latest GitHub release (resolved at run time, so it does not rot); set
# AI_TOOLS_NVM_VERSION=vX.Y.Z to pin it, or AI_TOOLS_NODE_MAJOR to choose the Node line.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-bootstrap.sh /usr/local/sbin/ai-tools/ai-tools-bootstrap

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly SANDBOX_HOME="/opt/ai-tools"
readonly NVM_DIR="${SANDBOX_HOME}/.nvm"
# nvm version is resolved at run time (latest release, unless pinned); see resolve_nvm_version.
# The fallback is used only when the GitHub API cannot be reached and no pin is set.
readonly NVM_FALLBACK_VERSION="v0.40.3"
readonly NODE_MAJOR="${AI_TOOLS_NODE_MAJOR:-22}"
readonly PKG="${1:-@anthropic-ai/claude-code}"
# The launcher name a package installs into the Node bin dir, symlinked at
# /opt/ai-tools/bin/<launcher> for the wrapper to resolve. Only the Claude Code package is
# mapped; an unknown package installs the toolchain without a bin symlink.
case "${PKG}" in
    @anthropic-ai/claude-code) readonly LAUNCHER="claude" ;;
    *)                         readonly LAUNCHER="" ;;
esac

die() { printf 'ai-tools-bootstrap: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-bootstrap: %s\n' "$*"; }

# resolve_nvm_version: echo the nvm release tag to install. An explicit AI_TOOLS_NVM_VERSION
# pin wins; otherwise query the GitHub API for the latest release tag, falling back to the
# pinned default on any failure (offline, rate-limited, unparseable) so bootstrap stays robust
# without carrying a version that rots. The caller validates the result before it is used.
resolve_nvm_version() {
    if [[ -n "${AI_TOOLS_NVM_VERSION:-}" ]]; then
        printf '%s' "${AI_TOOLS_NVM_VERSION}"
        return
    fi
    local tag
    tag="$(curl -fsSL --max-time 10 \
            https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || true
    if [[ "${tag}" == v[0-9]* ]]; then
        printf '%s' "${tag}"
    else
        printf '%s' "${NVM_FALLBACK_VERSION}"
    fi
}

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
command -v curl >/dev/null 2>&1 || die "curl is required to fetch nvm"

# Concrete tag (latest, pinned, or fallback). Constrained to v + digits/dots before it reaches
# the download URL piped to bash, so a resolved value can never inject shell or URL.
NVM_VERSION="$(resolve_nvm_version)"
[[ "${NVM_VERSION}" =~ ^v[0-9][0-9.]*$ ]] \
    || die "invalid nvm version '${NVM_VERSION}' (expected vMAJOR.MINOR.PATCH)"
readonly NVM_VERSION

# 1. Sandbox account + home. --system: no aging, low uid; /sbin/nologin + locked password:
#    the agent account has no interactive login. /opt (not /home) because /home is nosuid,
#    which would defeat the sudo UID-switch the launch path relies on.
if ! id "${SANDBOX_USER}" &>/dev/null; then
    log "creating system user ${SANDBOX_USER} (home ${SANDBOX_HOME})"
    useradd --system --shell /sbin/nologin --home-dir "${SANDBOX_HOME}" \
        --no-create-home --comment "AI tools sandbox user" "${SANDBOX_USER}"
    passwd -l "${SANDBOX_USER}" >/dev/null 2>&1 || true
fi
install -d "${SANDBOX_HOME}"
# Claim the home for the sandbox account ONLY while it is still unowned by an operator (a fresh
# dir, the RPM's root:ai-tools placeholder, or already ai-tools), so nvm/npm below can populate
# .nvm/.cache. Once ai-tools-enroll has re-owned the control plane to the operator (drwxr-s---
# operator:ai-tools), a re-run leaves that ownership intact: nvm updates then land inside the
# ai-tools-owned .nvm subtree, which stays writable.
_home_owner="$(stat -c %U "${SANDBOX_HOME}" 2>/dev/null || echo root)"
if [[ "${_home_owner}" == "root" || "${_home_owner}" == "${SANDBOX_USER}" ]]; then
    chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${SANDBOX_HOME}"
    chmod 2750 "${SANDBOX_HOME}"
fi

# 2. nvm + Node + the npm package, installed AS the sandbox account (network). The heredoc
#    is single-quoted, so the variables are expanded by the inner shell from the env passed
#    via `env`, never by this script. Existing nvm/Node are reused (idempotent).
log "installing nvm ${NVM_VERSION} + Node ${NODE_MAJOR} + ${PKG} as ${SANDBOX_USER} (network)"
sudo -u "${SANDBOX_USER}" env \
    NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" \
    NVM_VERSION="${NVM_VERSION}" NODE_MAJOR="${NODE_MAJOR}" \
    PKG="${PKG}" LAUNCHER="${LAUNCHER}" \
    bash -s <<'EOSU'
set -euo pipefail
if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"
nvm install "${NODE_MAJOR}"
nvm alias default "${NODE_MAJOR}"
npm install -g "${PKG}"

# Pre-create the agent's writable state dirs while the home is still ai-tools-writable, so they
# survive ai-tools-enroll locking the home root to the operator (drwxr-s---): afterwards the agent
# can only write within subtrees it owns. .cache holds NODE_COMPILE_CACHE; .nvm is the tree above.
mkdir -p "${HOME}/.cache" 2>/dev/null || true

# Seed an empty ~/.claude.json so the agent has a writable state file after ai-tools-enroll locks
# the home root (drwxr-s---): enroll sets it group-writable (r--rw----), but the agent could not
# CREATE it at the locked top level on first run. {} is valid JSON that claude extends in place;
# only when absent, so live state is never clobbered on a re-run.
[ -e "${HOME}/.claude.json" ] || { printf '{}\n' > "${HOME}/.claude.json"; } 2>/dev/null || true

# Source the host-wide PATH dedup from the agent's login init too (parity with the operator),
# after any nvm block. The account is nologin so this seldom runs, but keeps PATH ordering
# consistent if a login shell is ever opened for it. Tolerant of a locked home on a re-run.
_prof="${HOME}/.bash_profile"
if ! grep -qF '/etc/profile.d/path_dedup.sh' "${_prof}" 2>/dev/null; then
    { printf '\n# Added by ai-tools-bootstrap: source the host-wide PATH dedup (must follow nvm init).\n[[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh || true\n' >> "${_prof}"; } 2>/dev/null || true
fi

# Point /opt/ai-tools/bin/<launcher> at the versioned binary (pre-install; install.sh / the
# RPM later locks bin to 550 and repoints via the root symlink helper). Only for a package
# whose launcher is known and present.
ver="$(nvm version default)"
if [ -n "${LAUNCHER}" ]; then
    bin="${NVM_DIR}/versions/node/${ver}/bin/${LAUNCHER}"
    if [ -x "${bin}" ]; then
        mkdir -p "${HOME}/bin"
        ln -sf "${bin}" "${HOME}/bin/${LAUNCHER}"
    fi
fi
EOSU

log "toolchain ready under ${SANDBOX_HOME}"
log "next: deploy the control plane -- sudo ./install.sh install   (or install the RPM)"
