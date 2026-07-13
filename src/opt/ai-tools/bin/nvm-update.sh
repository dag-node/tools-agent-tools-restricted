#!/usr/bin/env bash
# /opt/ai-tools/bin/nvm-update.sh
# Updates Node.js and sandbox npm tools under /opt/ai-tools.
# Runs as the ai-tools user in its own systemd --user instance (nvm-update.service).
# Resolves the latest LTS in the NVM_NODE_MAJOR series itself; an explicit version as
# $1 overrides that lookup (manual or out-of-band use).
#
# Configuration via the unit's Environment= directives:
#   NVM_NODE_ALIAS           nvm alias to track            (default: default)
#   NVM_NODE_MAJOR           major series to track for LTS (default: 22)
#   AI_TOOLS_GLOBAL_TOOLS    space-separated sandbox packages
#                            (default: npm @anthropic-ai/claude-code)

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_BIN="/opt/ai-tools/bin"

log()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p info;    echo "INFO : $*"; }
warn() { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p warning; echo "WARN : $*" >&2; }
die()  { printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p err;     echo "ERROR: $*" >&2; exit 1; }

# npm signature verifier (npm-verify.lib.sh). Best-effort source: the lib is root-owned, so a
# missing one is a broken install, not agent action -- degrade to "unable to verify" (a warn,
# never a blocked update), matching the check's own can't-verify posture. The lib refuses to
# run as root; this updater runs as the sandbox account, which is the required principal.
readonly NPM_VERIFY_LIB="/usr/local/lib/ai-tools/npm-verify.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/npm-verify.lib.sh
if ! source "${NPM_VERIFY_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_verify_npm_signatures >/dev/null 2>&1; then
    warn "signature-verification library unavailable (${NPM_VERIFY_LIB}) -- skipping the check"
    ai_tools_verify_npm_signatures() { return 2; }
fi

# verify_toolchain_signatures: run the signature check and apply the fail-closed policy.
# rc 0 verified; rc 1 TAMPER -> die BEFORE the prune/repoint, so the previous trusted version
# stays active and installed; rc 2 unable to verify -> warn and proceed (the toolchain is
# installed regardless, and the check is best-effort against offline/unsupported hosts).
verify_toolchain_signatures() {
    local rc=0
    ai_tools_verify_npm_signatures || rc=$?
    case "${rc}" in
        0) log "npm registry signatures verified for the installed toolchain" ;;
        1) die "npm signature verification FAILED (possible registry tampering) -- refusing to activate the new toolchain; the previous version stays in use" ;;
        *) warn "could not verify npm signatures (offline or unsupported) -- proceeding; the toolchain is updated but unverified" ;;
    esac
}

# version_in_use: succeed if a live process is executing from this version's tree.
# A session is pinned to the Node version it launched with (claude-run sets PATH to
# that version's bin and DISABLE_AUTOUPDATER=1), so pruning a version out from under a
# running session would break it -- a lazy require() or a node/npm/npx subprocess spawn
# would hit ENOENT on the deleted tree. Scans /proc/<pid>/exe; this runs as ai-tools,
# which can readlink only ITS OWN processes -- exactly the set that matters, since
# sessions and their node subprocesses all run as ai-tools. Best-effort: an exited or
# unreadable PID is skipped. A version found in use is deferred to the next prune cycle,
# by which time the session has ended.
# args:  version string (e.g. v22.23.0)
version_in_use() {
    local ver="$1"
    local verdir="${HOME}/.nvm/versions/node/${ver}"
    local exe tgt
    for exe in /proc/[0-9]*/exe; do
        tgt="$(readlink -- "${exe}" 2>/dev/null)" || continue
        [[ "${tgt}" == "${verdir}/"* ]] && return 0
    done
    return 1
}

# prune_versions: uninstall every installed Node version not referenced by a named
# nvm alias; the alias-tracked version is always kept, as is any version a live session
# is still running from (see version_in_use). Logs each removal and retention to the
# journal.
# args:  nvm alias to track
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
        if [[ -n "${keep[${ver}]+x}" ]]; then
            log "  keeping ${ver}"
        elif version_in_use "${ver}"; then
            log "  keeping ${ver} (in use by a live session -- deferring prune)"
        else
            log "  removing ${ver}"
            nvm uninstall "${ver}" || warn "  failed to uninstall ${ver}"
        fi
    done
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
    # covering only the package being installed leaves its siblings (e.g. claude-code's
    # required postinstall) flagged. Scoped to our named tools by the caller's list,
    # never a blanket --dangerously-allow-all-scripts.
    for pkg in "$@"; do
        if npm list -g --depth=0 "${pkg}" &>/dev/null; then
            log "  updating ${pkg}"
            npm update -g --allow-scripts="${allow_csv}" "${pkg}" || warn "  npm update failed for ${pkg} -- skipping"
        else
            log "  installing ${pkg}"
            npm install -g --allow-scripts="${allow_csv}" "${pkg}" || warn "  npm install failed for ${pkg} -- skipping"
        fi
    done
}

# main: resolve the latest LTS in the vMAJOR series (or take it from $1), install it
# under /opt/ai-tools if not already active, refresh the sandbox global tools, prune
# superseded versions, and repoint the stable /opt/ai-tools/bin/claude symlink at the
# versioned binary.
# args:  optional target Node version override (e.g. v22.15.0)
main() {
    local target_version="${1:-}"

    local node_alias="${NVM_NODE_ALIAS:-default}"
    local major="${NVM_NODE_MAJOR:-22}"
    local nvm_dir="${HOME}/.nvm"   # HOME=/opt/ai-tools when running as ai-tools

    [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"
    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh" --no-use

    local current_version
    current_version="$(nvm version "${node_alias}" 2>/dev/null || true)"
    [[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
        || die "nvm alias '${node_alias}' not set"

    # The timer invokes this with no argument, so resolve the latest LTS in the vMAJOR
    # series here -- the same `sort -V | tail -1` highest-semver selection the prune logic
    # keys on. An explicit argument overrides the lookup.
    if [[ -z "${target_version}" ]]; then
        command -v curl >/dev/null 2>&1 || die "curl required to resolve the latest version"
        target_version="$(
            nvm ls-remote --lts "v${major}" 2>/dev/null \
                | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
                | sort -V | tail -1
        )"
        [[ -n "${target_version}" ]] \
            || die "could not resolve latest v${major} from nvm ls-remote"
    fi

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
    # The full managed set is the allow-scripts allowlist -- npm re-scans the whole
    # global tree on every install, so each call must cover all of them (see install_packages).
    local allow_csv; allow_csv="$(IFS=,; printf '%s' "${tools[*]}")"
    log "Packages: ${tools[*]}"
    install_packages "${allow_csv}" "${tools[@]}"

    # Fail-closed signature gate BEFORE prune and repoint: a detected tamper (die) leaves the
    # previous version un-pruned and the launcher symlink un-repointed, so the trusted toolchain
    # stays active. Runs against the just-installed global tree as the sandbox account.
    verify_toolchain_signatures

    prune_versions "${node_alias}"

    # Refresh the stable symlink that claude-wrapper resolves with one readlink hop.
    # /opt/ai-tools/bin is locked 0551 (root:ai-tools) so this process -- running as
    # ai-tools -- cannot write it directly; delegate the repoint to the root helper
    # via the handback socket bridge (sudo fails under NNP, which the session service
    # always runs under due to RestrictNamespaces=yes forcing PR_SET_NO_NEW_PRIVS).
    local versioned_claude="${nvm_dir}/versions/node/${target_version}/bin/claude"
    [[ -x "${versioned_claude}" ]] || die "claude binary not found at ${versioned_claude}"
    # Repoint (and, via the ai-tools-relabel.path watcher the touched symlink drives,
    # relabel) is best-effort, NOT fatal: this warns rather than dying. A manual/out-of-band
    # run (this script's documented use) executes outside a session, where the handback
    # socket may be down -- and the toolchain is already installed by this point, so aborting
    # here would strand a completed update over a symlink the operator can repoint by hand.
    # The scheduled timer run has the socket up and repoints normally.
    if ! /usr/local/bin/ai-tools-handback-client SYMLINK "${versioned_claude}"; then
        warn "failed to repoint ${AI_TOOLS_BIN}/claude via handback SYMLINK -- the toolchain is updated but the stable symlink may be stale; repoint it as root: ln -sfn ${versioned_claude} ${AI_TOOLS_BIN}/claude && ai-tools --relabel"
    fi

    log "Done. Active: $(nvm version "${node_alias}")"
}

main "$@"
