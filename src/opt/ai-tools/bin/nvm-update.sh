#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/bin/nvm-update.sh
# Updates Node.js and sandbox npm tools under /opt/ai-tools.
# Runs as the ai-tools user in its own systemd --user instance (nvm-update.service).
# Resolves the latest LTS in the NVM_NODE_MAJOR series itself; an explicit version as
# $1 overrides that lookup (manual or out-of-band use).
#
# Configuration via the unit's Environment= directives:
#   NVM_NODE_ALIAS           nvm alias to track            (default: default)
#   NVM_NODE_MAJOR           major series to track for LTS (default: 22)
#   AI_TOOLS_GLOBAL_TOOLS    space-separated sandbox packages; overrides the default set
#                            (npm plus each enabled agent's npm package, resolved from the
#                            agent manifests via providers.lib.sh -- see main)
#
# Every run records its outcome in a last-run stamp (see write_stamp), the only evidence an
# operator has of this unit's health: it lives in the sandbox account's own systemd --user
# manager, which `ai-tools --status` cannot query from the operator's session.
#
# The exit status classifies the run for the two readers that act on it -- that stamp, and the
# unit's Restart= policy:
#   0  the toolchain is current.
#   1  a fault on this host: something is broken or untrustworthy and it will still be broken on a
#      retry (no nvm, no curl, an unset alias, a failed signature check).
#   3  transient: the registry could not be reached, so NOTHING was changed and the previous,
#      trusted toolchain stays active and installed. The unit retries this one; the stamp records
#      it as `skipped` rather than a failure, because an offline host has nothing to fix.
# The split is deliberately coarse. It is not a diagnosis of why the registry was unreachable -- a
# disconnected laptop and a registry outage are one state from here -- only of whether a retry is
# the right response and whether an operator should be alarmed now. A transient condition that
# PERSISTS still surfaces: the stamp ages, and `ai-tools --status` reports it stale past its grace.

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_BIN="/opt/ai-tools/bin"
# The last-run stamp `ai-tools --status` reads. The install creates it; this script only ever
# rewrites that one existing inode. Its directory is root-owned and NOT group-writable, so this
# account -- and so the agent, which runs as it -- cannot create, unlink, rename, or symlink-swap
# anything there: the whole surface the stamp adds is the contents of this single file.
readonly NVM_UPDATE_STAMP="/var/opt/ai-tools/state/nvm-update.status"
# The transient exit status (see the header). Its own code, not a reuse of 1: the unit retries only
# this one, so a fault that a retry cannot fix does not churn against the registry.
readonly EXIT_TRANSIENT=3
# Set by skip() and read by the EXIT trap, which receives only a status. A one-word token, since it
# reaches the stamp and the stamp's reader clamps to a short safe charset.
_run_skip_reason=""

# Each emitter writes to stdout/stderr FIRST -- the unit routes both to the journal
# (StandardOutput/StandardError), so that copy always lands -- and only then makes the best-effort
# systemd-cat copy, which carries the nvm-update-ai tag for a MANUAL run outside the unit.
#
# The order and the `|| true` are load-bearing, not tidiness. This script runs under
# `set -e -o pipefail`, so a bare `printf | systemd-cat` pipeline whose systemd-cat fails aborts the
# whole updater -- and aborts it SILENTLY, because the echo that would have said why came after the
# statement that failed. That is a logger deciding the fate of the operation it reports on, which is
# exactly what every other component here refuses to allow (log.lib.sh, ai-tools-run). A failed run
# must always be able to say what failed.
log()  { echo "INFO : $*";     printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p info    2>/dev/null || true; }
warn() { echo "WARN : $*" >&2; printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p warning 2>/dev/null || true; }
die()  { echo "ERROR: $*" >&2; printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p err     2>/dev/null || true; exit 1; }

# skip <reason-token> <message> : end the run as TRANSIENT (see the header) -- the counterpart to
# die for a condition this host did not cause and cannot fix, where the correct outcome is that
# nothing changed. It is a notice, not an error: it exits EXIT_TRANSIENT, so the unit retries it,
# and records <reason-token> in the stamp, so `ai-tools --status` can say WHY a run did nothing
# instead of reporting a failure the operator would go looking for.
skip() { _run_skip_reason="$1"; shift
         echo "SKIP : $*" >&2; printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p notice 2>/dev/null || true
         exit "${EXIT_TRANSIENT}"; }

# write_stamp <exit-code>: record this run's outcome where the operator can read it, in the
# KEY=value grammar services.lib.sh parses (RESULT, EXIT_CODE, FINISHED, TRIGGER, NODE, and REASON
# on a skip). RESULT is the exit status classified for a reader: ok / failed / `skipped` for the
# transient case, which is reported as a run that correctly did nothing rather than as a fault --
# an offline host has nothing for an operator to fix, and calling it FAILED spends attention that
# a real fault then has to compete with. Installed
# as the EXIT trap, so it records EVERY exit path -- a die, an uncaught set -e failure, and a clean
# run alike; without it a failed run is visible only in the sandbox account's journal, which the
# operator cannot reach either. Best-effort by construction: it must never turn a successful update
# into a failed unit, so every step tolerates failure and the function always returns 0.
#
# TRIGGER says whether SYSTEMD started this run, which is what makes the run evidence about the
# TIMER rather than only about the update: nvm-update.timer publishes no state an operator session
# can reach, so `ai-tools --status` infers its health from a run having happened -- and a run this
# script did by hand proves nothing about a schedule. systemd sets INVOCATION_ID for every unit it
# starts, so its presence separates the two. A run started by hand THROUGH the manager
# (`systemctl --user start nvm-update.service`) is indistinguishable from a triggered one and
# counts as `unit`; the inference is bounded to systemd-started runs, not to scheduled ones.
#
# It REWRITES the existing file rather than creating one: the stamp is owned by this account inside
# a directory that is not, which is what confines the added surface to one inode (see the constant
# above) -- but it also means the file must already exist, so an absent one is a broken/partial
# install and is reported as such rather than silently skipped. A single write of the whole text
# keeps the window in which a reader sees a partial stamp negligible; should one land there anyway,
# the reader finds no parseable RESULT and reports the unit unknown, never a wrong verdict.
write_stamp() {
    local rc="$1" result=failed node_version=unknown trigger=manual reason="" text
    case "${rc}" in
        0)                   result=ok ;;
        "${EXIT_TRANSIENT}") result=skipped; reason="${_run_skip_reason:-transient}" ;;
    esac
    [[ -n "${INVOCATION_ID:-}" ]] && trigger=unit

    if [[ ! -f "${NVM_UPDATE_STAMP}" || ! -w "${NVM_UPDATE_STAMP}" ]]; then
        warn "no writable last-run stamp at ${NVM_UPDATE_STAMP} -- 'ai-tools --status' cannot report this unit; reinstall ai-tools-integration-nodejs to restore it"
        return 0
    fi

    # nvm is a shell function from the sourced nvm.sh, so it exists only once main got that far;
    # an early failure stamps NODE=unknown rather than aborting the trap.
    if declare -F nvm >/dev/null 2>&1; then
        node_version="$(nvm version "${NVM_NODE_ALIAS:-default}" 2>/dev/null || true)"
        [[ "${node_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || node_version=unknown
    fi

    # Composed whole, then written in ONE call: REASON is present only on a skip, and building the
    # text first keeps that conditional line from splitting the write into two -- the single write
    # is what keeps the window in which a reader could see a partial stamp negligible.
    printf -v text '# nvm-update last-run stamp -- written by %s, read by "ai-tools --status".\nRESULT=%s\nEXIT_CODE=%d\nFINISHED=%s\nTRIGGER=%s\nNODE=%s\n' \
        "${AI_TOOLS_BIN}/nvm-update.sh" "${result}" "${rc}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${trigger}" "${node_version}"
    [[ -n "${reason}" ]] && text+="REASON=${reason}"$'\n'
    printf '%s' "${text}" >"${NVM_UPDATE_STAMP}" 2>/dev/null \
        || warn "could not write the last-run stamp at ${NVM_UPDATE_STAMP}"
    return 0
}
trap 'write_stamp "$?"' EXIT

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
# A session is pinned to the Node version it launched with (ai-tools-run sets PATH to
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

    # Same bare-assignment rule as the target-version lookup in main: absorb the status so a failed
    # lookup is reported and SKIPPED rather than aborting the run here -- the prune is housekeeping,
    # and an abort at this point would strand the launcher repoint that follows it, leaving the new
    # toolchain installed but unwired.
    active_version="$(nvm version "${node_alias}" 2>/dev/null)" || true
    if [[ -z "${active_version}" || "${active_version}" == "N/A" ]]; then
        warn "could not resolve the version alias '${node_alias}' points at -- skipping the prune"
        return 0
    fi
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
# superseded versions, and repoint each enabled agent's stable /opt/ai-tools/bin/<launcher>
# symlink at the versioned binary.
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
        # The `|| true` is load-bearing, the same way the emitters' is. A BARE assignment takes the
        # exit status of its command substitution, so under `set -e -o pipefail` a registry this host
        # cannot reach (or a grep that matches nothing) aborts the updater ON THIS LINE -- silently,
        # since nvm's own error is discarded above and the die below never runs. Absorbing the status
        # here is what lets the emptiness be REPORTED, by the check that was always meant to.
        target_version="$(
            nvm ls-remote --lts "v${major}" 2>/dev/null \
                | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
                | sort -V | tail -1
        )" || true
        # Transient, not a fault: nothing here is broken, the registry simply was not reachable, and
        # the host keeps the toolchain it already has. See the header's exit-status contract.
        [[ -n "${target_version}" ]] \
            || skip offline "could not resolve the latest v${major} from nvm ls-remote (registry unreachable) -- keeping ${current_version}; nothing was changed"
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

    # The enabled agents -- their npm packages (installed below) and their launchers (repointed
    # at the end) -- come from the manifests via providers.lib.sh, the same seam
    # ai-tools-bootstrap uses, so this updater names no agent. Guarded load: providers.lib.sh
    # returns non-zero and defines nothing when its own dependency (conf.lib.sh, the shared
    # KEY=value grammar) is missing, so probe the resolver rather than assume the source
    # succeeded -- a bare `source` under set -e would abort the run instead of degrading. A
    # missing lib is a broken install (root-owned, so not agent action): existing agents keep
    # working, they are simply not refreshed or repointed this run.
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    local -a agent_packages=() agent_launchers=()
    # shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/providers.lib.sh
    if source "${providers_lib}" 2>/dev/null \
            && declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
        local manifest_package manifest_launcher
        while IFS=$'\t' read -r _ manifest_package manifest_launcher; do
            [[ -n "${manifest_package}" ]]  && agent_packages+=("${manifest_package}")
            [[ -n "${manifest_launcher}" ]] && agent_launchers+=("${manifest_launcher}")
        done < <(ai_tools_enabled_agents)
    else
        warn "provider resolver unavailable (${providers_lib}) -- updating npm only; enabled agents are unrefreshed and their launchers unrepointed this run"
    fi

    # The managed tool set: an explicit AI_TOOLS_GLOBAL_TOOLS (unit Environment= or manual)
    # overrides; otherwise npm (self-update) plus each enabled agent's package.
    local -a tools
    if [[ -n "${AI_TOOLS_GLOBAL_TOOLS:-}" ]]; then
        IFS=' ' read -ra tools <<< "${AI_TOOLS_GLOBAL_TOOLS}"
    else
        tools=(npm "${agent_packages[@]}")
    fi
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

    # Refresh the stable launcher symlink each wrapper resolves with one readlink hop -- one per
    # enabled agent, from the same manifest-resolved set installed above, so the updater names no
    # agent here either. A launcher missing from the new version (an agent whose install failed,
    # or one an operator dropped from AI_TOOLS_AGENTS) is skipped rather than failing the run.
    # /opt/ai-tools/bin is locked 0551 (root:ai-tools) so this process -- running as ai-tools --
    # cannot write it directly; delegate each repoint to the root helper via the handback socket
    # bridge (sudo fails under NNP, which the session service always runs under due to
    # RestrictNamespaces=yes forcing PR_SET_NO_NEW_PRIVS).
    local launcher versioned_launcher
    for launcher in "${agent_launchers[@]}"; do
        versioned_launcher="${nvm_dir}/versions/node/${target_version}/bin/${launcher}"
        if [[ ! -x "${versioned_launcher}" ]]; then
            log "${launcher} not installed in ${target_version} -- skipping its stable-symlink repoint"
            continue
        fi
        # Repoint (and, via the ai-tools-relabel.path watcher the touched bin directory drives,
        # relabel) is best-effort, NOT fatal: this warns rather than dying. A manual/out-of-band
        # run (this script's documented use) executes outside a session, where the handback
        # socket may be down -- and the toolchain is already installed by this point, so aborting
        # here would strand a completed update over a symlink the operator can repoint by hand.
        # The scheduled timer run has the socket up and repoints normally.
        if ! /usr/local/bin/ai-tools-handback-client SYMLINK "${versioned_launcher}"; then
            warn "failed to repoint ${AI_TOOLS_BIN}/${launcher} via handback SYMLINK -- the toolchain is updated but the stable symlink may be stale; repoint it as root: ln -sfn ${versioned_launcher} ${AI_TOOLS_BIN}/${launcher} && ai-tools --relabel"
        fi
    done

    log "Done. Active: $(nvm version "${node_alias}")"
}

main "$@"
