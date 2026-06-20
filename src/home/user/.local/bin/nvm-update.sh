#!/usr/bin/env bash
# ~/.local/bin/nvm-update.sh
# Updates the user's Node.js and global npm tools, then delegates to the
# ai-tools sandbox at the same resolved version so both installs stay in sync.
#
# Runs as the projects user via systemd user timer. Configuration via Environment= directives:
#   NVM_NODE_ALIAS        nvm alias to track        (default: default)
#   NVM_NODE_MAJOR        major version series       (default: 22)
#   NVM_GLOBAL_TOOLS      space-separated user packages (default: npm typescript yarn grunt)

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_SCRIPT="/opt/ai-tools/bin/nvm-update.sh"
# Root helper that restores ai_tools_exec_t on the sandbox claude entrypoint. A fresh
# Node tree's claude.exe is born mislabelled (bin_t), and the confined handback domain
# that repoints the stable symlink is deliberately not granted relabel rights, so the
# relabel is done here -- this updater runs as the projects user (unconfined_t, which can
# relabel) and reaches the helper through a dedicated fixed-path NOPASSWD sudo rule.
readonly AI_TOOLS_RELABEL="/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint"

log()  { echo "$*"; }
warn() { echo "warn: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

# prune_versions: uninstall every installed Node version not referenced by a named
# nvm alias; the alias-tracked version is always kept. Logs what it removed and kept.
# args:  nvm alias to track
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

# install_packages: install each package missing from the active nvm context, or
# update it if already present globally. A failed package warns and is skipped,
# never aborting the run.
# args:  comma-joined allow-scripts allowlist, then package names
install_packages() {
    local allow_csv="$1"; shift
    local pkg
    # npm 11.5+ gates preinstall/install/postinstall behind an allowScripts allowlist
    # and, on every install, re-scans the WHOLE global tree -- warning "N packages have
    # install scripts not yet covered by allowScripts" for any top-level package still
    # unreviewed (advisory today, blocking in a future npm). approve-scripts cannot
    # persist this for us (it errors EGLOBAL on global installs), so we approve per
    # invocation with --allow-scripts, passing the FULL managed set on EVERY call:
    # covering only the package being installed leaves its siblings (e.g. yarn's
    # preinstall, claude-code's postinstall) flagged. Scoped to our named tools by the
    # caller's list, never a blanket --dangerously-allow-all-scripts.
    for pkg in "$@"; do
        if npm list -g --depth=0 "${pkg}" &>/dev/null; then
            log "  ${pkg}: updating"
            npm update -g --allow-scripts="${allow_csv}" "${pkg}" || warn "  ${pkg}: update failed, skipping"
        else
            log "  ${pkg}: installing"
            npm install -g --allow-scripts="${allow_csv}" "${pkg}" || warn "  ${pkg}: install failed, skipping"
        fi
    done
}

# main: resolve the latest LTS Node in the vMAJOR series once, upgrade the user's
# nvm install and global tools to it, prune superseded versions, then delegate the
# sandbox update to ai-tools at that same resolved version so both stay in sync.
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
    # The full managed set is the allow-scripts allowlist -- npm re-scans the whole
    # global tree on every install, so each call must cover all of them (see install_packages).
    local allow_csv; allow_csv="$(IFS=,; printf '%s' "${tools[*]}")"
    log "packages: ${tools[*]}"
    install_packages "${allow_csv}" "${tools[@]}"

    prune_versions "${node_alias}"

    # Delegate sandbox update to ai-tools at the same resolved version
    if [[ -f "${AI_TOOLS_SCRIPT}" ]]; then
        log "ai-tools: delegating sandbox update at ${latest_version}"
        sudo -u ai-tools "${AI_TOOLS_SCRIPT}" "${latest_version}" \
            || warn "ai-tools update failed -- claude may be on an old version"

        # Relabel the (possibly new) sandbox claude entrypoint so the SELinux domain
        # transition keeps firing. Best-effort and idempotent: a no-op when the label is
        # already correct or SELinux is inactive. No pre-check on the helper -- it is
        # 750 root:root under a dir the projects user cannot stat, reachable only via this
        # fixed-path NOPASSWD sudo rule; a missing helper or rule just makes sudo fail and
        # warn. If it fails, claude-run's pre-launch check still fail-closes (refuses
        # rather than running unconfined) and points the operator at `ai-tools --relabel`.
        sudo "${AI_TOOLS_RELABEL}" \
            || warn "entrypoint relabel failed -- run 'ai-tools --relabel' before launching claude"
    else
        warn "ai-tools: ${AI_TOOLS_SCRIPT} not found, skipping sandbox update"
    fi

    log "done: $(nvm version "${node_alias}")"
}

main "$@"
