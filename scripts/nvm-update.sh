#!/usr/bin/env bash
# ~/.local/bin/nvm-update.sh
# Updates xd's Node.js and global npm tools, then delegates to the ai-tools
# sandbox at the same resolved version so both installs stay in sync.
#
# Runs as xd via systemd user timer. Configuration via Environment= directives:
#   NVM_NODE_ALIAS        nvm alias to track        (default: default)
#   NVM_NODE_MAJOR        major version series       (default: 22)
#   NVM_GLOBAL_TOOLS      space-separated xd packages (default: npm typescript yarn grunt)

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_SCRIPT="/opt/ai-tools/bin/nvm-update.sh"

log()  { echo "$*"; }
warn() { echo "warn: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

# ---------------------------------------------------------------------------
# Prune Node versions not referenced by any named alias
# ---------------------------------------------------------------------------
prune_versions() {
    local node_alias="$1" nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
    local active_version ver aliased
    local -a removed=()

    active_version="$(nvm version "${node_alias}")"

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
            nvm uninstall "${ver}" && removed+=("${ver}") \
                || warn "failed to uninstall ${ver}"
        fi
    done

    if [[ ${#removed[@]} -gt 0 ]]; then
        log "prune: removed ${removed[*]}  kept ${active_version}"
    else
        log "prune: ${active_version} kept"
    fi
}

# ---------------------------------------------------------------------------
# Install or upgrade packages in the active nvm context
# ---------------------------------------------------------------------------
install_packages() {
    local pkg
    for pkg in "$@"; do
        if npm list -g --depth=0 "${pkg}" &>/dev/null; then
            log "  ${pkg}: updating"
            npm update -g "${pkg}" || warn "  ${pkg}: update failed, skipping"
        else
            log "  ${pkg}: installing"
            npm install -g "${pkg}" || warn "  ${pkg}: install failed, skipping"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local node_alias="${NVM_NODE_ALIAS:-default}"
    local major="${NVM_NODE_MAJOR:-22}"
    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"

    require_cmd curl
    [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"
    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh" --no-use

    local current_version
    current_version="$(nvm version "${node_alias}" 2>/dev/null || true)"
    [[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
        || die "nvm alias '${node_alias}' not set. Run: nvm alias ${node_alias} ${major}"

    # Resolve latest version once -- the same value is passed to the ai-tools
    # sandbox so both installs land on the identical Node build
    local latest_version
    latest_version="$(
        nvm ls-remote --lts "v${major}" 2>/dev/null \
            | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -V | tail -1
    )"
    [[ -n "${latest_version}" ]] || die "Could not resolve latest v${major} from nvm ls-remote"

    if [[ "${current_version}" != "${latest_version}" ]]; then
        log "node ${current_version} -> ${latest_version}"
        log "installing ${latest_version}"
        nvm install "${latest_version}" --no-progress
        nvm reinstall-packages "${current_version}"
        nvm alias "${node_alias}" "${latest_version}"
        nvm use "${node_alias}"
    else
        log "node ${current_version} up to date"
    fi

    nvm use "${node_alias}"

    local -a tools
    IFS=' ' read -ra tools <<< "${NVM_GLOBAL_TOOLS:-npm typescript yarn grunt}"
    log "packages: ${tools[*]}"
    install_packages "${tools[@]}"

    prune_versions "${node_alias}"

    # Delegate sandbox update to ai-tools at the same resolved version
    if [[ -f "${AI_TOOLS_SCRIPT}" ]]; then
        log "ai-tools: delegating sandbox update at ${latest_version}"
        sudo -u ai-tools "${AI_TOOLS_SCRIPT}" "${latest_version}" \
            || warn "ai-tools update failed -- claude may be on an old version"
    else
        warn "ai-tools: ${AI_TOOLS_SCRIPT} not found, skipping sandbox update"
    fi

    log "done: $(nvm version "${node_alias}")"
}

main "$@"
