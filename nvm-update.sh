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
# Config (overridden by systemd Environment=)
# ---------------------------------------------------------------------------
readonly NODE_ALIAS="${NVM_NODE_ALIAS:-default}"
readonly MAJOR="${NVM_NODE_MAJOR:-22}"
readonly TOOLS="${NVM_GLOBAL_TOOLS:-npm typescript yarn grunt @anthropic-ai/claude-code}"
readonly NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
readonly LOG_TAG="nvm-update"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" | systemd-cat -t "${LOG_TAG:-script}" -p info;  echo "INFO : $*"; }
warn() { printf '%s\n' "$*" | systemd-cat -t "${LOG_TAG:-script}" -p warning; echo "WARN : $*" >&2; }
die()  { printf '%s\n' "$*" | systemd-cat -t "${LOG_TAG:-script}" -p err;   echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -s "${NVM_DIR}/nvm.sh" ]] || die "nvm not found at ${NVM_DIR}/nvm.sh"

# shellcheck source=/dev/null
source "${NVM_DIR}/nvm.sh" --no-use

require_cmd nvm
require_cmd curl

# ---------------------------------------------------------------------------
# Resolve current and latest versions
# ---------------------------------------------------------------------------
current_version="$(nvm version "${NODE_ALIAS}" 2>/dev/null || true)"

[[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
    || die "nvm alias '${NODE_ALIAS}' not set. Run: nvm alias ${NODE_ALIAS} ${MAJOR}"

log "Current: ${current_version} (alias: ${NODE_ALIAS})"

# Fetch latest v{MAJOR} release from nvm's remote list
latest_version="$(
    nvm ls-remote --lts "v${MAJOR}" 2>/dev/null \
        | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V \
        | tail -1
)"
[[ -n "${latest_version}" ]] \
    || die "Could not determine latest v${MAJOR} from nvm ls-remote"

log "Latest v${MAJOR}: ${latest_version}"

# ---------------------------------------------------------------------------
# Install latest if not already current
# ---------------------------------------------------------------------------
if [[ "${current_version}" == "${latest_version}" ]]; then
    log "Already on latest ${latest_version} -- checking tools only"
else
    log "Installing ${latest_version}"
    nvm install "${latest_version}" --no-progress

    log "Reinstalling global packages into ${latest_version}"
    nvm reinstall-packages "${current_version}"

    log "Updating alias '${NODE_ALIAS}' -> ${latest_version}"
    nvm alias "${NODE_ALIAS}" "${latest_version}"

    nvm use "${NODE_ALIAS}"
fi

# Ensure alias version is active for subsequent npm calls
nvm use "${NODE_ALIAS}"

# ---------------------------------------------------------------------------
# Install / upgrade specified tools to latest
# ---------------------------------------------------------------------------
log "Upgrading global tools: ${TOOLS}"
IFS=' ' read -ra tools_arr <<< "${TOOLS}"
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
# ---------------------------------------------------------------------------
# Prune old Node versions (keep only current alias + any other named aliases)
# ---------------------------------------------------------------------------
active_version="$(nvm version "${NODE_ALIAS}")"

log "Pruning old Node.js versions (keeping ${active_version})"

# Collect all versions referenced by any alias -- never remove those
declare -A keep
while IFS= read -r aliased; do
    ver="$(echo "${aliased}" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ -n "${ver}" ]] && keep["${ver}"]=1
done < <(nvm alias 2>/dev/null)

# Always keep active
keep["${active_version}"]=1

while IFS= read -r installed; do
    ver="$(echo "${installed}" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ -z "${ver}" ]] && continue
    if [[ -z "${keep[${ver}]+x}" ]]; then
        log "  removing ${ver}"
        nvm uninstall "${ver}" \
            || warn "  failed to uninstall ${ver}"
    else
        log "  keeping ${ver} (aliased or active)"
    fi
done < <(nvm ls --no-colors 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')

log "Done. Active: $(nvm version "${NODE_ALIAS}")"
