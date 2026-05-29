#!/usr/bin/env bash
# nvm-update.sh -- upgrade Node.js LTS alias to latest patch and reinstall
# global npm tools. Runs as the normal user via a systemd user timer.
# No root or sudo required for this script itself.
#
# Configuration is injected via systemd Environment= directives:
#   NVM_NODE_ALIAS  -- nvm alias to track (default: default)
#   NVM_NODE_MAJOR  -- major version series to stay on (default: 22)
#   NVM_GLOBAL_TOOLS -- space-separated list of npm global packages

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p info;    echo "INFO : $*"; }
warn() { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p warning; echo "WARN : $*" >&2; }
die()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p err;     echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    local cmd="$1"
    command -v "${cmd}" &>/dev/null || die "Required command not found: ${cmd}"
}

# ---------------------------------------------------------------------------
# Prune old Node versions (keep only active + any other named aliases)
# ---------------------------------------------------------------------------
prune_versions() {
    local node_alias="$1"
    local active_version ver aliased installed
    active_version="$(nvm version "${node_alias}")"

    log "Pruning old Node.js versions (keeping ${active_version})"

    # Collect all versions referenced by any alias -- never remove those
    local -A keep
    while IFS= read -r aliased; do
        ver="$(printf '%s\n' "${aliased}" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        [[ -n "${ver}" ]] && keep["${ver}"]=1
    done < <(nvm alias 2>/dev/null)
    keep["${active_version}"]=1

    while IFS= read -r installed; do
        ver="$(printf '%s\n' "${installed}" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        [[ -z "${ver}" ]] && continue
        if [[ -z "${keep[${ver}]+x}" ]]; then
            log "  removing ${ver}"
            nvm uninstall "${ver}" || warn "  failed to uninstall ${ver}"
        else
            log "  keeping ${ver} (aliased or active)"
        fi
    done < <(nvm ls --no-colors 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local node_alias="${NVM_NODE_ALIAS:-default}"
    local major="${NVM_NODE_MAJOR:-22}"
    local tools="${NVM_GLOBAL_TOOLS:-npm typescript yarn grunt @anthropic-ai/claude-code}"
    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"

    # Validation
    [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"

    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh" --no-use

    require_cmd nvm
    require_cmd curl

    # Resolve current and latest versions
    local current_version
    current_version="$(nvm version "${node_alias}" 2>/dev/null || true)"
    [[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
        || die "nvm alias '${node_alias}' not set. Run: nvm alias ${node_alias} ${major}"

    log "Current: ${current_version} (alias: ${node_alias})"

    local latest_version
    latest_version="$(
        nvm ls-remote --lts "v${major}" 2>/dev/null \
            | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -V \
            | tail -1
    )"
    [[ -n "${latest_version}" ]] \
        || die "Could not determine latest v${major} from nvm ls-remote"

    log "Latest v${major}: ${latest_version}"

    # Install latest if not already current
    if [[ "${current_version}" == "${latest_version}" ]]; then
        log "Already on latest ${latest_version} -- checking tools only"
    else
        log "Installing ${latest_version}"
        nvm install "${latest_version}" --no-progress

        log "Reinstalling global packages into ${latest_version}"
        nvm reinstall-packages "${current_version}"

        log "Updating alias '${node_alias}' -> ${latest_version}"
        nvm alias "${node_alias}" "${latest_version}"

        nvm use "${node_alias}"
    fi

    # Ensure alias version is active for subsequent npm calls
    nvm use "${node_alias}"

    # Install / upgrade specified tools to latest
    log "Upgrading global tools: ${tools}"
    local tool
    local -a tools_arr
    IFS=' ' read -ra tools_arr <<< "${tools}"
    for tool in "${tools_arr[@]}"; do
        if npm list -g --depth=0 "${tool}" &>/dev/null; then
            log "  updating ${tool}"
            npm update -g "${tool}" \
                || warn "  npm update failed for ${tool} -- skipping"
        else
            log "  installing ${tool}"
            npm install -g "${tool}" \
                || warn "  npm install failed for ${tool} -- skipping"
        fi
    done

    prune_versions "${node_alias}"

    log "Done. Active: $(nvm version "${node_alias}")"
}

main "$@"