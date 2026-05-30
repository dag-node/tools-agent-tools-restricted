#!/usr/bin/env bash
# /opt/ai-tools/bin/nvm-update.sh
# Updates Node.js and sandbox npm tools under /opt/ai-tools.
# Runs as ai-tools user, invoked from nvm-update.sh via sudo.
# Receives the target Node version as $1 so both installs track the same
# version resolved by nvm-update.sh rather than re-querying nvm ls-remote.
#
# Configuration via Environment= directives (preserved through sudo via
# env_keep in /etc/sudoers.d/ai-tools-claude):
#   NVM_NODE_ALIAS           nvm alias to track   (default: default)
#   AI_TOOLS_GLOBAL_TOOLS    space-separated sandbox packages
#                            (default: npm @anthropic-ai/claude-code)

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_BIN="/opt/ai-tools/bin"

log()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p info;    echo "INFO : $*"; }
warn() { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p warning; echo "WARN : $*" >&2; }
die()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p err;     echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# prune_versions: uninstall every installed Node version not referenced by a
# named nvm alias; the alias-tracked version is always kept. Logs each removal
# and retention to the journal.
# args:  nvm alias to track
# ---------------------------------------------------------------------------
prune_versions() {
    local node_alias="$1" nvm_dir="${HOME}/.nvm"
    local active_version ver aliased

    active_version="$(nvm version "${node_alias}")"
    log "Pruning old Node.js versions (keeping ${active_version})"

    local -A keep
    while IFS= read -r aliased; do
        ver="$(printf '%s\n' "${aliased}" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        [[ -n "${ver}" && -d "${nvm_dir}/versions/node/${ver}" ]] && keep["${ver}"]=1
    done < <(nvm alias 2>/dev/null)
    keep["${active_version}"]=1

    for ver in "${nvm_dir}/versions/node"/v*/; do
        ver="${ver%/}"; ver="${ver##*/}"
        [[ "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        if [[ -z "${keep[${ver}]+x}" ]]; then
            log "  removing ${ver}"
            nvm uninstall "${ver}" || warn "  failed to uninstall ${ver}"
        else
            log "  keeping ${ver}"
        fi
    done
}

# ---------------------------------------------------------------------------
# install_packages: install each package missing from the active nvm context, or
# update it if already present globally. A failed package warns and is skipped,
# never aborting the run.
# args:  package names
# ---------------------------------------------------------------------------
install_packages() {
    local pkg
    for pkg in "$@"; do
        if npm list -g --depth=0 "${pkg}" &>/dev/null; then
            log "  updating ${pkg}"
            npm update -g "${pkg}" || warn "  npm update failed for ${pkg} -- skipping"
        else
            log "  installing ${pkg}"
            npm install -g "${pkg}" || warn "  npm install failed for ${pkg} -- skipping"
        fi
    done
}

# ---------------------------------------------------------------------------
# main: install the target Node version under /opt/ai-tools if not already
# active, refresh the sandbox global tools, prune superseded versions, and
# repoint the stable /opt/ai-tools/bin/claude symlink at the versioned binary.
# args:  target Node version (e.g. v22.15.0)
# ---------------------------------------------------------------------------
main() {
    local target_version="${1:-}"
    [[ -n "${target_version}" ]] \
        || die "Usage: nvm-update.sh <version>  e.g. v22.15.0"

    local node_alias="${NVM_NODE_ALIAS:-default}"
    local nvm_dir="${HOME}/.nvm"   # HOME=/opt/ai-tools when running as ai-tools

    [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"
    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh" --no-use

    local current_version
    current_version="$(nvm version "${node_alias}" 2>/dev/null || true)"
    [[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
        || die "nvm alias '${node_alias}' not set"

    log "Current: ${current_version}  ->  target: ${target_version}"

    if [[ "${current_version}" != "${target_version}" ]]; then
        log "Installing ${target_version}"
        nvm install "${target_version}" --no-progress
        nvm reinstall-packages "${current_version}"
        nvm alias "${node_alias}" "${target_version}"
        nvm use "${node_alias}"
    fi

    nvm use "${node_alias}"

    local -a tools
    IFS=' ' read -ra tools <<< "${AI_TOOLS_GLOBAL_TOOLS:-npm @anthropic-ai/claude-code}"
    log "Packages: ${tools[*]}"
    install_packages "${tools[@]}"

    prune_versions "${node_alias}"

    # Refresh the stable symlink that claude-wrapper resolves with one readlink hop
    local versioned_claude="${nvm_dir}/versions/node/${target_version}/bin/claude"
    [[ -x "${versioned_claude}" ]] || die "claude binary not found at ${versioned_claude}"
    mkdir -p "${AI_TOOLS_BIN}"
    ln -sf "${versioned_claude}" "${AI_TOOLS_BIN}/claude"
    log "Symlink: ${AI_TOOLS_BIN}/claude -> ${versioned_claude}"

    log "Done. Active: $(nvm version "${node_alias}")"
}

main "$@"
