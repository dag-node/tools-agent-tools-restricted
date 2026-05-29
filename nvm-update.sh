#!/usr/bin/env bash
# nvm-update.sh
# Deploy to both ~/.local/bin/nvm-update.sh  (runs as xd, via systemd user timer)
#           and  /opt/ai-tools/bin/nvm-update.sh  (runs as ai-tools, via sudo).
#
# xd context   : resolves latest Node v${NVM_NODE_MAJOR} once, installs user
#                packages to ~/.nvm, then re-invokes this same script as
#                ai-tools (sudo) with the pinned version so both installs
#                land on identical Node and the version is resolved only once.
#
# ai-tools context (invoked by xd via sudo):
#                installs sandbox packages (@anthropic-ai/*) to
#                /opt/ai-tools/.nvm at the pinned version, then refreshes
#                the /opt/ai-tools/bin/claude symlink for the wrapper.
#
# Configuration via systemd Environment= directives (preserved through sudo
# via env_keep in /etc/sudoers.d/ai-tools-claude):
#   NVM_NODE_ALIAS      nvm alias to track           (default: default)
#   NVM_NODE_MAJOR      major version series          (default: 22)
#   NVM_GLOBAL_TOOLS    space-separated package list; packages matching
#                       @anthropic-ai/* are routed to the ai-tools sandbox,
#                       all others go to xd's ~/.nvm

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
readonly RUNNING_AS="$(id -un)"
readonly AI_TOOLS_SCRIPT="/opt/ai-tools/bin/nvm-update.sh"
readonly AI_TOOLS_BIN="/opt/ai-tools/bin"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p info;    echo "INFO : $*"; }
warn() { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p warning; echo "WARN : $*" >&2; }
die()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update" -p err;     echo "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

# ---------------------------------------------------------------------------
# Package routing: @anthropic-ai/* packages belong in the ai-tools sandbox
# ---------------------------------------------------------------------------
is_sandbox_package() { [[ "$1" == @anthropic-ai/* ]]; }

# ---------------------------------------------------------------------------
# Prune Node versions not referenced by any named alias
# ---------------------------------------------------------------------------
prune_versions() {
    local node_alias="$1"
    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
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
# Install or upgrade a list of packages in the active nvm context
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
# Bring an nvm install to target_version and install the given packages.
# Uses ${NVM_DIR:-${HOME}/.nvm} so it works for both xd (~/.nvm) and
# ai-tools (/opt/ai-tools/.nvm) without needing an explicit path argument.
# ---------------------------------------------------------------------------
update_nvm_install() {
    local node_alias="$1" target_version="$2"
    shift 2
    # remaining positional args are the packages to install (may be zero)

    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
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

    if [[ $# -gt 0 ]]; then
        log "Packages: $*"
        install_packages "$@"
    fi

    prune_versions "${node_alias}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local node_alias="${NVM_NODE_ALIAS:-default}"
    local major="${NVM_NODE_MAJOR:-22}"
    local pin_version="${1:-}"  # xd passes its resolved version when invoking as ai-tools

    # Parse NVM_GLOBAL_TOOLS once and split into routed lists
    local -a user_packages=() sandbox_packages=()
    local pkg
    for pkg in ${NVM_GLOBAL_TOOLS:-npm typescript yarn grunt @anthropic-ai/claude-code}; do
        if is_sandbox_package "${pkg}"; then
            sandbox_packages+=("${pkg}")
        else
            user_packages+=("${pkg}")
        fi
    done

    if [[ "${RUNNING_AS}" == "ai-tools" ]]; then
        # ----------------------------------------------------------------
        # ai-tools context: /opt/ai-tools/.nvm + sandbox packages
        # NVM_DIR is unset here (sudo resets HOME to /opt/ai-tools, so
        # update_nvm_install resolves ${HOME}/.nvm = /opt/ai-tools/.nvm)
        # ----------------------------------------------------------------
        [[ -n "${pin_version}" ]] \
            || die "ai-tools invocation requires a pinned version argument"
        log "=== ai-tools | ${pin_version} | sandbox: ${sandbox_packages[*]:-none} ==="

        update_nvm_install "${node_alias}" "${pin_version}" "${sandbox_packages[@]}"

        # Refresh the stable symlink that claude-wrapper resolves via realpath
        local versioned_claude="${HOME}/.nvm/versions/node/${pin_version}/bin/claude"
        [[ -x "${versioned_claude}" ]] \
            || die "claude binary not found at ${versioned_claude}"
        mkdir -p "${AI_TOOLS_BIN}"
        ln -sf "${versioned_claude}" "${AI_TOOLS_BIN}/claude"
        log "Symlink: ${AI_TOOLS_BIN}/claude -> ${versioned_claude}"

    else
        # ----------------------------------------------------------------
        # xd context: ~/.nvm + user packages, then delegate to ai-tools
        # ----------------------------------------------------------------
        require_cmd curl

        local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
        [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"
        # shellcheck source=/dev/null
        source "${nvm_dir}/nvm.sh" --no-use

        # Resolve version once -- the same value is passed to ai-tools so
        # both installs land on the identical Node build
        local latest_version
        latest_version="$(
            nvm ls-remote --lts "v${major}" 2>/dev/null \
                | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
                | sort -V | tail -1
        )"
        [[ -n "${latest_version}" ]] || die "Could not resolve latest v${major}"
        log "=== xd | resolved ${latest_version} | user: ${user_packages[*]:-none} ==="

        update_nvm_install "${node_alias}" "${latest_version}" "${user_packages[@]}"

        if [[ "${#sandbox_packages[@]}" -gt 0 ]]; then
            if [[ -x "${AI_TOOLS_SCRIPT}" ]]; then
                log "=== delegating to ai-tools | ${sandbox_packages[*]} ==="
                sudo -u ai-tools "${AI_TOOLS_SCRIPT}" "${latest_version}" \
                    || warn "ai-tools update failed -- claude may be on an old version"
            else
                warn "${AI_TOOLS_SCRIPT} not found -- skipping: ${sandbox_packages[*]}"
            fi
        fi
    fi

    log "=== done ==="
}

main "$@"
