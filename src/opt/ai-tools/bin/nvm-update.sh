#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/bin/nvm-update.sh
# Updates Node.js and sandbox npm tools under /opt/ai-tools. Runs as the ai-tools user in its own
# `systemd --user instance` (nvm-update.service). Resolves the latest LTS in the NVM_NODE_MAJOR series itself;
# an explicit version as
# $1 overrides that lookup (manual or out-of-band use).
#
# Configuration via the unit's Environment= directives:
#   NVM_NODE_ALIAS           nvm alias to track            (default: default)
#   NVM_NODE_MAJOR           major series to track for LTS (default: 22)
#   AI_TOOLS_GLOBAL_TOOLS    space-separated sandbox packages; overrides the default set
#                            (npm plus each enabled agent's npm package, resolved from the
#                            agent manifests via providers.lib.sh -- see main)
#
# No package code runs before the registry signature over the installed tree is checked: every npm install of the run
# skips the packages' install scripts (npm_config_ignore_scripts, set in main), and run_install_scripts runs each
# managed package's own once verify_toolchain_signatures has passed. updater.rule.md states what that covers.
#
# Every run records its outcome in a last-run stamp (see write_stamp), the only evidence an operator has of this unit's
# health: it lives in the sandbox account's own `systemd --user` manager, which `ai-tools status` cannot query
# from the operator's session.
#
# The exit status classifies the run for the two readers that act on it -- that stamp, and the unit's Restart= policy:
#   0  the toolchain is current.
#   1  a fault on this host: something is broken or untrustworthy and it will still be broken on a
#      retry (no nvm, no curl, an unset alias, a failed signature check, a provider input the
#      trust predicate refused so that no agent resolved).
#   3  transient: the registry could not be reached, so the toolchain was left alone and the previous,
#      trusted toolchain stays active and installed. The unit retries this one; the stamp records
#      it as `skipped`, and `ai-tools status` reports it stale once it persists past its grace.
# Why the split is coarse and why an offline run is not a failure: updater.rule.md (ref-section-z2h7).

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_NVM_UPDATE__BIN_DIR="/opt/ai-tools/bin"
# The last-run stamp `ai-tools status` reads. The install creates it; this script only ever rewrites that one existing
# inode. Its directory is root-owned and NOT group-writable, so this account -- and so the agent, which runs as it --
# cannot create, unlink, rename, or symlink-swap anything there: the whole surface the stamp adds is the contents
# of this single file.
readonly NVM_UPDATE_STAMP="/var/opt/ai-tools/state/nvm-update.status"
# The transient exit status (see the header), the one the unit retries.
readonly EXIT_TRANSIENT=3
# Set by skip() and read by the EXIT trap, which receives only a status. A one-word token, since it reaches the stamp
# and the stamp's reader clamps to a short safe charset.
_run_skip_reason=""

# Each emitter writes to stdout/stderr FIRST -- the unit routes both to the journal (StandardOutput/StandardError),
# so that copy always lands -- and only then makes the best-effort systemd-cat copy, which carries the nvm-update-ai tag
# for a MANUAL run outside the unit.
#
# The order and the `|| true` are load-bearing, not tidiness. This script runs under `set -e -o pipefail`, so a bare
# `printf | systemd-cat` pipeline whose systemd-cat fails aborts the whole updater -- and aborts it SILENTLY, because
# the echo that would have said why came after the statement that failed. That is a logger deciding the fate
# of the operation it reports on, which is exactly what every other component here refuses to allow (log.lib.sh,
# ai-tools-run). A failed run must always be able to say what failed.
#
# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads, and carried into the journal line. Matched inline: this script does not load
# the library.
log()  { echo "INFO : $*";     printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p info    2>/dev/null || true; }
warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    echo "WARN : $*" >&2; printf '%s\n' "${code:+${code} }$*" | systemd-cat -t "nvm-update-ai" -p warning 2>/dev/null || true
}
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    echo "ERROR: $*" >&2; printf '%s\n' "${code:+${code} }$*" | systemd-cat -t "nvm-update-ai" -p err 2>/dev/null || true
    exit 1
}

# skip <reason-token> <message> : end the run as TRANSIENT (see the header) -- the counterpart to die for a condition
# this host did not cause and cannot fix, where the correct outcome is that the toolchain is left alone. It is a notice,
# not an error: it exits EXIT_TRANSIENT, so the unit retries it, and records <reason-token> in the stamp,
# so `ai-tools status` can say WHY a run made no change instead of reporting a failure the operator would go looking
# for.
skip() { _run_skip_reason="$1"; shift
         echo "SKIP : $*" >&2; printf '%s\n' "$*" | systemd-cat -t "nvm-update-ai" -p notice 2>/dev/null || true
         exit "${EXIT_TRANSIENT}"; }

# write_stamp <exit-code>: record this run's outcome where the operator can read it, in the
# KEY=value grammar services.lib.sh parses (RESULT, EXIT_CODE, FINISHED, TRIGGER, NODE, and REASON
# on a skip). RESULT is the exit status classified for a reader: ok / failed / `skipped` for the transient case,
# which is reported as a run that correctly declined to act rather than as a fault (updater.rule.md, ref-section-z2h7).
# Installed as the EXIT trap, so it records EVERY exit path -- a die, an uncaught `set -e` failure, and a clean run
# alike; without it a failed run is visible only in the sandbox account's journal, which the operator cannot reach
# either. Best-effort by construction: it must never turn a successful update into a failed unit, so every step
# tolerates failure and the function always returns 0.
#
# TRIGGER says whether SYSTEMD started this run, which is what makes the run evidence about the TIMER rather than only
# about the update: no state nvm-update.timer publishes is reachable from an operator session, so `ai-tools status`
# infers its health from a run having happened -- and a run this script did by hand is no evidence about a schedule.
# systemd sets INVOCATION_ID for every unit it starts, so its presence separates the two. A run started by hand
# THROUGH the manager (`systemctl --user start nvm-update.service`) is indistinguishable from a triggered one and counts
# as `unit`; the inference is bounded to systemd-started runs, not to scheduled ones.
#
# It REWRITES the existing file rather than creating one: the stamp is owned by this account inside a directory that is
# not, which is what confines the added surface to one inode (see the constant it names) -- but it also means the file
# must already exist, so an absent one is a broken/partial install and is reported as such rather than silently skipped.
# A single write of the whole text keeps the window in which a reader sees a partial stamp negligible; should one land
# there anyway, the reader sees an unparseable RESULT and reports the unit unknown, never a wrong verdict.
write_stamp() {
    local rc="$1" result=failed node_version=unknown trigger=manual reason="" text
    case "${rc}" in
        0)                   result=ok ;;
        "${EXIT_TRANSIENT}") result=skipped; reason="${_run_skip_reason:-transient}" ;;
    esac
    [[ -n "${INVOCATION_ID:-}" ]] && trigger=unit

    if [[ ! -f "${NVM_UPDATE_STAMP}" || ! -w "${NVM_UPDATE_STAMP}" ]]; then
        warn "no writable last-run stamp at ${NVM_UPDATE_STAMP} -- 'atr status' cannot report this unit; reinstall ai-tools-integration-nodejs to restore it"
        return 0
    fi

    # nvm is a shell function from the sourced nvm.sh, so it exists only once main got that far; an early failure stamps
    # NODE=unknown rather than aborting the trap.
    if declare -F nvm >/dev/null 2>&1; then
        node_version="$(nvm version "${NVM_NODE_ALIAS:-default}" 2>/dev/null || true)"
        [[ "${node_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || node_version=unknown
    fi

    # A run that ended because the clock is behind keeps the previous run's FINISHED: the time this run would write is
    # the wrong one, and the previous is the last reading that was true, so the stamp ages into STALE as it should
    # instead of dating a run that never happened.
    local finished
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${reason}" == clock ]]; then
        local previous
        previous="$(sed -n 's/^FINISHED=//p' "${NVM_UPDATE_STAMP}" 2>/dev/null | head -n1)"
        [[ -n "${previous}" ]] && finished="${previous}"
    fi

    # Composed whole, then written in ONE call: REASON is present only on a skip, and building the text first keeps
    # that conditional line from splitting the write into two -- the single write is what keeps the window
    # in which a reader could see a partial stamp negligible.
    printf -v text '# nvm-update last-run stamp -- written by %s, read by "ai-tools status".\nRESULT=%s\nEXIT_CODE=%d\nFINISHED=%s\nTRIGGER=%s\nNODE=%s\n' \
        "${AI_TOOLS_NVM_UPDATE__BIN_DIR}/nvm-update.sh" "${result}" "${rc}" "${finished}" \
        "${trigger}" "${node_version}"
    [[ -n "${reason}" ]] && text+="REASON=${reason}"$'\n'
    printf '%s' "${text}" >"${NVM_UPDATE_STAMP}" 2>/dev/null \
        || warn "could not write the last-run stamp at ${NVM_UPDATE_STAMP}"
    return 0
}
# npm's own output, kept for the run: install_packages tees each install into it, and a package npm left without its
# declared entrypoint is reported with the first line that names the cause (npm_cause_line), since npm reports
# a dependency it could not unpack as a warning at exit 0.
_npm_capture="$(mktemp 2>/dev/null)" || _npm_capture=""
trap 'write_stamp "$?"; [[ -z "${_npm_capture}" ]] || rm -f -- "${_npm_capture}"' EXIT

# npm_cause_line : the first line of this run's npm output that names why a dependency was left out -- tar's entry error
# (no space left, a refused write), npm's own report of a failed optional dependency, or a platform it refused --
# through the log sanitizer and bounded; empty where none was captured.
npm_cause_line() {
    local line
    line="$(grep -m1 -E 'TAR_ENTRY_ERROR|failed optional dependency|optional dependency .* failed|EBADPLATFORM|ENOSPC' \
        "${_npm_capture:-/dev/null}" 2>/dev/null || true)"
    [[ -n "${line}" ]] || return 0
    line="${line:0:200}"
    if declare -F ai_tools_log__sanitize >/dev/null 2>&1; then
        ai_tools_log__sanitize "${line}"
    else
        printf 'withheld (the log library, which sanitizes it, did not load)'
    fi
}

# The KEY=value library (conf.lib.sh), for the clock reading main makes before anything else
# (ai_tools_conf__find_paths_ahead_of_clock). Best-effort source, the posture NPM_VERIFY_LIB and ENTRYPOINT_VERIFY_LIB
# take: a missing one is a broken install, and main reports the check as not made where the function is absent, rather
# than skipping it in silence.
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/conf.lib.sh
source "${CONF_LIB}" 2>/dev/null || true

# The logger (log.lib.sh), for the allowlist sanitizer npm's output passes through (npm_output). Best-effort source:
# without it that output is withheld rather than written to the journal raw, since npm, the packages' install scripts
# and the tree they run from are the sandbox account's.
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/log.lib.sh
source "${LOG_LIB}" 2>/dev/null || true

# The identity this script requires of itself (sandbox-exec.lib.sh, ai_tools_sandbox_exec__is_sandbox_account): it
# sources nvm.sh and runs npm from the tree, which runs whatever the sandbox account put there, so it runs
# as that account alone. Root and an operator are refused here, ahead of every read of the tree, with the routes
# that run it as the account named; a library that did not load leaves the identity unconfirmed, which refuses too.
readonly SANDBOX_EXEC_LIB="/usr/local/lib/ai-tools/sandbox-exec.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/sandbox-exec.lib.sh
source "${SANDBOX_EXEC_LIB}" 2>/dev/null || true
if ! declare -F ai_tools_sandbox_exec__is_sandbox_account >/dev/null 2>&1; then
    die MSG-T2F4 "cannot confirm this runs as the sandbox account: ${SANDBOX_EXEC_LIB} did not load -- reinstall ai-tools-base"
elif ! ai_tools_sandbox_exec__is_sandbox_account; then
    die MSG-U5C4 "refusing to run as $(id -un 2>/dev/null || printf 'uid %s' "${EUID}"): this script sources nvm.sh and runs npm from the sandbox toolchain, which only the sandbox account runs -- start it in that account's user instance (sudo systemctl --user -M ai-tools@ start nvm-update.service) or provision through atr admin system bootstrap"
fi
# npm_output: pass npm's output (stdin) through ai_tools_log__sanitize_stream, or withhold it with one line saying so.
npm_output() {
    if declare -F ai_tools_log__sanitize_stream >/dev/null 2>&1; then
        ai_tools_log__sanitize_stream
    else
        cat >/dev/null
        printf '%s\n' "(npm's output withheld: ${LOG_LIB}, which sanitizes it, did not load)"
    fi
}

# npm signature verifier (npm-verify.lib.sh). Best-effort source: the lib is root-owned, so a missing one is a broken
# install, not agent action -- degrade to "unable to verify" (a warn, never a blocked update), matching the check's own
# can't-verify posture. The lib refuses to run as root; this updater runs as the sandbox account, which is the required
# principal.
readonly NPM_VERIFY_LIB="/usr/local/lib/ai-tools/npm-verify.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/npm-verify.lib.sh
if ! source "${NPM_VERIFY_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_npm_verify__verify_signatures >/dev/null 2>&1; then
    warn "signature-verification library unavailable (${NPM_VERIFY_LIB}) -- skipping the check"
    ai_tools_npm_verify__verify_signatures() { return 2; }
fi

# verify_toolchain_signatures: run the signature check and apply the fail-closed policy. rc 0 verified; rc 1 TAMPER ->
# die BEFORE the install scripts, the prune and the repoint, so no code of the installed tree has run and the previous
# trusted version stays active and installed; rc 2 unable to verify -> warn and proceed (the toolchain is installed
# regardless, and the check is best-effort against offline/unsupported hosts).
verify_toolchain_signatures() {
    local rc=0
    ai_tools_npm_verify__verify_signatures || rc=$?
    case "${rc}" in
        0) log "npm registry signatures verified for the installed toolchain" ;;
        1) die "npm signature verification FAILED (possible registry tampering) -- refusing to activate the new toolchain; the previous version stays in use" ;;
        *) warn "could not verify npm signatures (the npm-verify line states why) -- proceeding; the toolchain is updated but unverified" ;;
    esac
}

# Entrypoint verifier (entrypoint-verify.lib.sh). Best-effort source, same posture as the npm verifier: a missing lib is
# a broken install, and degrades to "unable to verify".
readonly ENTRYPOINT_VERIFY_LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/entrypoint-verify.lib.sh
if ! source "${ENTRYPOINT_VERIFY_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_entrypoint_verify__verify_release >/dev/null 2>&1; then
    warn "entrypoint verifier unavailable (${ENTRYPOINT_VERIFY_LIB}) -- skipping the release-checksum check"
    ai_tools_entrypoint_verify__verify_release() { return 2; }
fi

# The cache remover (cache-cleanup.lib.sh), which prune_npm_cache empties npm's cache through. Best-effort source:
# emptying the cache is housekeeping, so a library that did not load leaves the cache in place with a warning rather
# than failing the update.
readonly CACHE_CLEANUP_LIB="/usr/local/lib/ai-tools/cache-cleanup.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/cache-cleanup.lib.sh
source "${CACHE_CLEANUP_LIB}" 2>/dev/null || true

# entrypoint_blocked[<launcher>] : set where a declared release manifest exists but the freshly installed entrypoint did
# not verify against it AND the operator required verification. The repoint loop skips those launchers. Populated
# by verify_agent_entrypoints.
declare -A entrypoint_blocked=()
entrypoint_unverified=0

# verify_agent_entrypoints <target-version>: check every enabled agent's just-installed entrypoint against the checksum
# its vendor signed for the version its package declares. A MISMATCH dies here, before the prune and the repoint,
# exactly as the npm gate does. Anything else is not fatal; see the branch comments.
verify_agent_entrypoints() {
    local target="$1" agent launcher entrypoint version rc
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r agent _ launcher; do
        [[ -n "${agent}" && -n "${launcher}" ]] || continue
        local url_template
        url_template="$(ai_tools_providers__read_agent_manifest_field "${agent}" release_manifest_url || true)"
        [[ -n "${url_template}" ]] || continue      # declares no provenance: nothing to check
        # Resolved, never executed: the versioned launcher is a symlink into the package, and what must be hashed is
        # the file it points at -- the same inode the launch shim verifies.
        entrypoint="$(realpath -e "${HOME}/.nvm/versions/node/${target}/bin/${launcher}" 2>/dev/null || true)"
        if [[ -z "${entrypoint}" ]]; then
            log "${agent}: ${launcher} not installed in ${target} -- nothing to verify"
            continue
        fi
        version="$(agent_package_version "${entrypoint}")"
        if [[ -z "${version}" ]]; then
            warn "${agent}: could not read the installed version beside ${entrypoint} -- not verified"
            ai_tools_entrypoint_verify__is_required 2>/dev/null \
                && { entrypoint_blocked["${launcher}"]=1; entrypoint_unverified=$(( entrypoint_unverified + 1 )); }
            continue
        fi
        rc=0
        ai_tools_entrypoint_verify__verify_release "${entrypoint}" "${version}" "${url_template}" \
            "$(ai_tools_providers__read_agent_manifest_field "${agent}" release_key || true)" \
            "$(ai_tools_providers__read_agent_manifest_field "${agent}" release_fingerprint || true)" \
            >/dev/null || rc=$?
        case "${rc}" in
            0) log "${agent}: entrypoint matches the checksum signed for release ${version}" ;;
            1) die "${agent}: the installed entrypoint does NOT match the checksum its vendor signed for release ${version} -- refusing to activate it; the previous version stays in use" ;;
            *) # Unverifiable does not block by default -- an air-gap decision (updater.rule.md):
               # a host with an internal npm mirror and no vendor route keeps updating, unpinned. Where the operator
               # required verification, activating such a release would instead refuse every launch, so the repoint is
               # held back and the verified version stays.
               if ai_tools_entrypoint_verify__is_required 2>/dev/null; then
                   warn "${agent}: could not verify release ${version} against its signed manifest -- not activating it (AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY is set); the previously verified version stays in use"
                   entrypoint_blocked["${launcher}"]=1; entrypoint_unverified=$(( entrypoint_unverified + 1 ))
               else
                   warn "${agent}: could not verify release ${version} against its signed manifest -- activating it anyway; its entrypoint will be unpinned until the vendor's manifest is reachable"
               fi ;;
        esac
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    return 0
}

# remove_residue <nvm-dir>: remove every installed, not enabled agent's package from the toolchain, and its stable
# launcher link with it, through the shared routine (toolchain.lib.sh) -- ahead of install_packages, so npm's
# allow-scripts rescan sees the smaller tree, and every launch stops refusing on residue with this run. The link goes
# only once no version directory still holds the package: a removal deferred under a live session leaves the link
# as the operator-side evidence that a launch is still refused. The link is root's to remove (/opt/ai-tools/bin is
# 0551), reached through the handback bridge like the repoint; a removal the bridge did not land warns, since
# the package itself is gone and the next run retries the link.
remove_residue() {
    local nvm_dir="$1" agent package version_dir outcome launcher
    local -A still_present=()
    declare -F ai_tools_toolchain__find_agent_residue >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r agent package version_dir; do
        [[ -n "${agent}" ]] || continue
        outcome="$(ai_tools_toolchain__remove_agent_package "${version_dir}" "${package}")" || outcome="${outcome:-failed}"
        log "${agent}: ${package} in ${version_dir##*/} -- ${outcome}"
        [[ "${outcome}" == removed || "${outcome}" == absent ]] || still_present["${agent}"]=1
    done < <(ai_tools_toolchain__find_agent_residue "${nvm_dir}")
    while IFS=$'\t' read -r agent launcher; do
        [[ -n "${agent}" && -z "${still_present[${agent}]:-}" ]] || continue
        if /usr/local/bin/ai-tools-handback-client SYMLINK_REMOVE "${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher}"; then
            log "${agent}: removed the stable launcher link ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher}"
        else
            warn MSG-G4Q2 "could not remove ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher} via handback SYMLINK_REMOVE -- the ${agent} package is gone and every launch stays refused until the link is; remove it as root: rm -f ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher}"
        fi
    done < <(ai_tools_toolchain__find_agent_residue_links "${AI_TOOLS_NVM_UPDATE__BIN_DIR}")
    return 0
}

# relink_agent_launchers <target-version>: point each enabled agent's versioned launcher at the executable its manifest
# declares (launcher_target; the check and the refusals are providers.lib.sh's). npm rewrites bin/<launcher> on every
# install, so this runs after every install_packages and BEFORE the entrypoint verifier and the stable repoint:
# the verifier hashes what the versioned launcher resolves to, and the repoint is what fires the relabel watcher,
# so each must read the chain in its final shape. A refusal is reported by the library and leaves npm's link in place;
# the run continues, and that agent's launch fails closed at the label preflight until its manifest and its package
# agree.
relink_agent_launchers() {
    local target="$1" agent launcher launcher_target fcontext verdict
    declare -F ai_tools_providers__relink_launcher >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r agent _ launcher; do
        [[ -n "${agent}" && -n "${launcher}" ]] || continue
        launcher_target="$(ai_tools_providers__read_agent_manifest_field "${agent}" launcher_target || true)"
        [[ -n "${launcher_target}" ]] || continue      # npm's own link is the launcher
        fcontext="$(ai_tools_providers__read_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
        if verdict="$(ai_tools_providers__relink_launcher "${HOME}/.nvm/versions/node/${target}" "${launcher}" "${launcher_target}" "${fcontext}")"; then
            case "${verdict}" in
                linked) log "${agent}: ${launcher} in ${target} re-linked at ${launcher_target}" ;;
                *)      log "${agent}: ${launcher} in ${target} already links ${launcher_target}" ;;
            esac
        else
            warn "${agent}: ${launcher} in ${target} was not re-linked at its declared target (see above) -- npm's own link stays, and a launch fails closed at the label preflight until the manifest and the installed package agree"
        fi
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    return 0
}

# agent_package_version <entrypoint>: print the MAJOR.MINOR.PATCH the package beside the entrypoint declares, walking
# up to the nearest package.json. Bounded read; anything not semver yields an empty string, so a crafted value cannot
# become part of a URL.
agent_package_version() {
    local dir="${1%/*}" declared
    for _ in 1 2 3; do
        if [[ -f "${dir}/package.json" ]]; then
            declared="$(head -c 65536 -- "${dir}/package.json" 2>/dev/null \
                | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
            [[ "${declared}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "${declared}"; return 0; }
        fi
        dir="${dir%/*}"
        [[ -n "${dir}" ]] || break
    done
    return 0
}

# version_in_use: succeed if a live process is executing from this version's tree. A session is pinned to the Node
# version it launched with (ai-tools-run sets PATH to that version's bin and DISABLE_AUTOUPDATER=1), so pruning
# a version out from under a running session would break it -- a lazy require() or a node/npm/npx subprocess spawn would
# hit ENOENT on the deleted tree. Scans /proc/<pid>/exe; this runs as ai-tools, which can readlink only ITS OWN
# processes -- exactly the set that matters, since sessions and their node subprocesses all run as ai-tools.
# Best-effort: an exited or unreadable PID is skipped. A version found in use is deferred to the next prune cycle,
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

# prune_versions: uninstall every installed Node version not referenced by a named nvm alias; the alias-tracked version
# is always kept, as is any version a live session is still running from (see version_in_use). Logs each removal
# and retention to the
# journal.
# args:  nvm alias to track
prune_versions() {
    local node_alias="$1" nvm_dir="${HOME}/.nvm"
    local active_version ver aliased

    # Same bare-assignment rule as the target-version lookup in main: absorb the status so a failed lookup is reported
    # and SKIPPED rather than aborting the run here -- the prune is housekeeping, and an abort at this point would
    # strand the launcher repoint that follows it, leaving the new toolchain installed but unwired.
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

# install_packages: install each package missing from the active nvm context, reinstall one the caller names
# as incomplete, and update the rest. A failed package warns and is skipped, never aborting the run.
#
# The reinstall branch takes the same invocation and the same allowlist as the install branch, on a package npm already
# reports as installed: `npm update` would leave the tree it finds, while `npm install` reifies the dependency tree
# from the package's own manifest. Which packages are named, and why that repair is keyed on the entrypoint's absence,
# are in updater.rule.md.
# args:  comma-joined allow-scripts allowlist, comma-joined packages to reinstall, then package names
install_packages() {
    local allow_csv="$1" repair_csv="$2"; shift 2
    local pkg
    # npm 11.5+ gates preinstall/install/postinstall behind an allowScripts allowlist and, on every install, re-scans
    # the WHOLE global tree -- warning "N packages have install scripts not yet covered by allowScripts" for any
    # top-level package still unreviewed (advisory today, blocking in a future npm). approve-scripts cannot persist this
    # for us (it errors EGLOBAL on global installs), so we approve per invocation with `--allow-scripts`, passing
    # the FULL managed set on EVERY call: covering only the package being installed leaves its siblings (e.g.
    # claude-code's required postinstall) flagged. Scoped to the named tools by the caller's list, never a blanket
    # `--dangerously-allow-all-scripts`. Each invocation's output is kept in _npm_capture as well as sanitized
    # into the log, so the completeness read after the install can quote the line that names what npm left out. None
    # of these invocations runs a script: main sets npm_config_ignore_scripts for the run's installs, and the allowlist
    # is passed so that npm's rescan of the global tree does not report the set as unreviewed; the scripts run
    # in run_install_scripts, after the signature verdict.
    local capture="${_npm_capture:-/dev/null}"
    for pkg in "$@"; do
        if [[ -n "${repair_csv}" && ",${repair_csv}," == *",${pkg},"* ]]; then
            log "  reinstalling ${pkg} -- the entrypoint its manifest declares is not in this toolchain"
            npm install -g --allow-scripts="${allow_csv}" "${pkg}" 2>&1 | tee -a "${capture}" | npm_output \
                || warn "  npm install failed for ${pkg} -- skipping"
        elif npm list -g --depth=0 "${pkg}" &>/dev/null; then
            log "  updating ${pkg}"
            npm update -g --allow-scripts="${allow_csv}" "${pkg}" 2>&1 | tee -a "${capture}" | npm_output \
                || warn "  npm update failed for ${pkg} -- skipping"
        else
            log "  installing ${pkg}"
            npm install -g --allow-scripts="${allow_csv}" "${pkg}" 2>&1 | tee -a "${capture}" | npm_output \
                || warn "  npm install failed for ${pkg} -- skipping"
        fi
    done
}

# run_install_scripts <version-dir> <package>...: run each named package's own install scripts -- preinstall, install
# and postinstall, in lifecycle order, through `npm run --if-present` in that package's directory
# under <version-dir>/lib/node_modules -- once the signature gate has passed. The packages named are the set
# whose scripts run, so a dependency's script does not run here, as it does not at install. Every install of the run
# skipped the scripts (npm_config_ignore_scripts), so a package the registry signature does not cover has not run any
# code as this account when the gate dies; the caller unsets the variable before this runs. `npm rebuild`
# under `--allow-scripts` does not serve here: its gate reads a package's identity from the registry URL a lockfile
# records, and a global tree carries none, so it blocks every script. claude-code's postinstall is what copies its
# native binary over the bin/claude.exe placeholder, so the entrypoint verifier and the launcher re-link run after this.
# A script that fails is a FAULT (die): the package is installed without it, so an agent whose entrypoint such a script
# places is refused at launch, under the pin's mismatch, until a provisioning run completes it. A name outside npm's
# package-name charset is refused before it is joined to a path (the shape toolchain.lib.sh holds a manifest's
# npm_package to).
run_install_scripts() {
    local version_dir="$1"; shift
    local capture="${_npm_capture:-/dev/null}" pkg package_dir script
    for pkg in "$@"; do
        [[ "${pkg}" =~ ^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$ ]] \
            || die "refusing to run the install scripts of $(printf '%q' "${pkg}"): not an npm package name"
        package_dir="${version_dir}/lib/node_modules/${pkg}"
        if [[ ! -d "${package_dir}" ]]; then
            log "  ${pkg}: not installed in ${version_dir##*/} -- no install script to run"
            continue
        fi
        log "  running the install scripts of ${pkg}"
        for script in preinstall install postinstall; do
            (cd "${package_dir}" && npm run --if-present "${script}") 2>&1 | tee -a "${capture}" | npm_output \
                || die "the ${script} script of ${pkg} did not complete -- the package is installed without it, so an agent whose entrypoint such a script places is refused at launch until it runs; fix what npm's output names, then run: atr admin system bootstrap"
        done
    done
}

# prune_npm_cache: empty npm's content cache. It is content-addressed with no eviction, so every tarball a nightly run
# downloaded stays in it -- an agent's platform build is hundreds of megabytes per release -- until the volume holding
# the toolchain is full, where npm then drops the optional dependency carrying that build and exits 0. Nothing reads
# the cache between runs, and a reinstall downloads what it needs again. The removal goes through the library's remover,
# which does not follow a link a session planted in the cache, and journals itself under this script's tag; the record
# is written to the state file both status reports read (updater.rule.md).
prune_npm_cache() {
    if ! declare -F ai_tools_cache_cleanup__remove_group >/dev/null 2>&1; then
        warn "the cache remover (${CACHE_CLEANUP_LIB}) did not load -- the cache under ${HOME}/.npm keeps this run's downloads; reinstall ai-tools-base"
        return 0
    fi
    local record
    record="$(AI_TOOLS_LOG_TAG=nvm-update-ai \
        ai_tools_cache_cleanup__remove_group "${AI_TOOLS_CACHE_CLEANUP__SANDBOX_HOME}" npm-cache)" || true
    ai_tools_cache_cleanup__write_state "${AI_TOOLS_CACHE_CLEANUP__STATE_FILE}" \
            "${AI_TOOLS_CACHE_CLEANUP__LAUNCH_BOUND_SECONDS}" "${record}" \
        || warn "could not record the npm cache removal in ${AI_TOOLS_CACHE_CLEANUP__STATE_FILE} -- both status reports show the previous one"
    return 0
}

# main: resolve the latest LTS in the vMAJOR series (or take it from $1), install it under /opt/ai-tools if not already
# active, remove a disabled agent's package left in the toolchain, refresh the sandbox global tools -- reinstalling
# rather than updating an enabled agent's package that does not hold the entrypoint its manifest declares -- with every
# install script held back, verify the installed tree's registry signatures, run the scripts, re-link each versioned
# launcher at the target its manifest declares, prune superseded versions, empty npm's content cache, and repoint each
# enabled agent's stable /opt/ai-tools/bin/<launcher> symlink at the versioned binary.
# args:  optional target Node version override (e.g. v22.15.0)
main() {
    local target_version="${1:-}"

    local node_alias="${NVM_NODE_ALIAS:-default}"
    local major="${NVM_NODE_MAJOR:-22}"
    local nvm_dir="${HOME}/.nvm"   # HOME=/opt/ai-tools when running as ai-tools

    # The clock, before anything is downloaded or written: a file this host wrote dated after now says the clock is
    # behind (a host with no battery-backed clock boots into an earlier time until it reaches a time source), and every
    # record this run would leave -- the stamp's FINISHED, the pin's VERIFIED, the journal -- would carry the wrong
    # time. Transient, like an unreachable registry: the unit retries, the stamp says why (REASON=clock,
    # with the previous run's FINISHED kept rather than a wrong one written), and the toolchain is left alone.
    local clock_behind_lines=""
    if ! declare -F ai_tools_conf__find_paths_ahead_of_clock >/dev/null 2>&1; then
        warn "the clock was not checked: ${CONF_LIB} did not load -- reinstall ai-tools-base"
    elif ! clock_behind_lines="$(ai_tools_conf__find_paths_ahead_of_clock "$0" "${NVM_UPDATE_STAMP}" \
                "${AI_TOOLS_ENTRYPOINT_PIN_DIR:-/var/opt/ai-tools/state/entrypoint-pin.d}"/* 2>/dev/null)"; then
        skip clock "the system clock reads $(date '+%Y-%m-%d %H:%M:%S'), earlier than a file this host wrote (${clock_behind_lines//$'\n'/; }) -- set the clock first (timedatectl set-time, or chronyc makestep once a time source is reachable); nothing was changed"
    fi

    [[ -s "${nvm_dir}/nvm.sh" ]] || die "nvm not found at ${nvm_dir}/nvm.sh"
    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh" --no-use

    local current_version
    current_version="$(nvm version "${node_alias}" 2>/dev/null || true)"
    [[ -n "${current_version}" && "${current_version}" != "N/A" ]] \
        || die "nvm alias '${node_alias}' not set"

    # The enabled agents -- their npm packages (installed by this run) and their launchers (repointed at the end) --
    # come from the manifests via providers.lib.sh, the same seam ai-tools-bootstrap uses, so this updater is
    # agent-agnostic. Guarded load: providers.lib.sh returns non-zero and does not define its resolvers when its own
    # dependency (conf.lib.sh, the shared
    # KEY=value grammar) is missing, so probe the resolver rather than assume the source
    # succeeded -- a bare `source` under `set -e` would abort the run instead of degrading. A missing lib is a broken
    # install (root-owned, so not agent action): existing agents keep working, they are simply not refreshed
    # or repointed this run.
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    local -a agent_packages=() agent_launchers=()
    # shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/providers.lib.sh
    if source "${providers_lib}" 2>/dev/null \
            && declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1; then
        local manifest_package manifest_launcher
        while IFS=$'\t' read -r _ manifest_package manifest_launcher; do
            [[ -n "${manifest_package}" ]]  && agent_packages+=("${manifest_package}")
            [[ -n "${manifest_launcher}" ]] && agent_launchers+=("${manifest_launcher}")
        done < <(ai_tools_providers__list_enabled_agents)
        # A resolver that loaded and returned an empty set is classified before npm alone becomes the managed set,
        # and before the run's first write to the toolchain, so a fault ends the run with no package installed.
        # The resolver refuses an input the trust predicate declines and reports it on stderr only, so without this step
        # a host whose inputs all read as untrusted -- every manifest, operator.conf -- maintains npm, exits 0
        # and stamps RESULT=ok while the agent stops updating. The fault class exits 1: the same inputs are read
        # on a retry, and that is the status the unit's RestartPreventExitStatus= names. A set the configuration asks
        # to be empty is logged and the run continues.
        if (( ${#agent_packages[@]} == 0 )); then
            local empty_verdict="" empty_reason=""
            IFS=$'\t' read -r empty_verdict empty_reason < <(ai_tools_providers__evaluate_empty_agents) || true
            case "${empty_verdict}" in
                none) log "no agent to maintain: ${empty_reason} -- updating npm only" ;;
                *)    die "no agent resolved: ${empty_reason:-the classification printed nothing} -- enabled agents are unrefreshed and their launchers unrepointed until this is fixed" ;;
            esac
        fi
    else
        warn "provider resolver unavailable (${providers_lib}) -- updating npm only; enabled agents are unrefreshed and their launchers unrepointed this run"
    fi

    # A transfer of the tree can leave a regular-file copy in bin/ where npm keeps a symlink, and npm does not start
    # from such a copy; every later step of main runs it. The repair (toolchain.lib.sh) replaces only a copy whose bytes
    # equal its target, and runs here as the tree's owner. Best-effort: a library that does not load leaves the tree
    # as it is.
    # shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/toolchain.lib.sh
    if source /usr/local/lib/ai-tools/toolchain.lib.sh 2>/dev/null \
            && declare -F ai_tools_toolchain__relink_copies >/dev/null 2>&1; then
        local copied_name copied_outcome
        while IFS=$'\t' read -r copied_name copied_outcome; do
            [[ -n "${copied_name}" ]] || continue
            if [[ "${copied_outcome}" == relinked ]]; then
                log "${current_version}: restored the bin/${copied_name} symlink a copy had replaced"
            else
                warn "${current_version}: bin/${copied_name} is a regular file where npm keeps a symlink, left as it is (${copied_outcome})"
            fi
        done < <(ai_tools_toolchain__relink_copies "${nvm_dir}/versions/node/${current_version}")
    fi

    # The timer invokes this with no argument, so resolve the latest LTS in the vMAJOR series here -- the same
    # `sort -V | tail -1` highest-semver selection the prune logic keys on. An explicit argument overrides the lookup.
    if [[ -z "${target_version}" ]]; then
        command -v curl >/dev/null 2>&1 || die "curl required to resolve the latest version"
        # The `|| true` is load-bearing, the same way the emitters' is. A BARE assignment takes the exit status of its
        # command substitution, so under `set -e -o pipefail` a registry this host cannot reach (or a grep with no
        # match) aborts the updater ON THIS LINE -- silently, since nvm's own error is discarded and the die never runs.
        # Absorbing the status here is what lets the emptiness be REPORTED, by the check that was always meant to.
        target_version="$(
            nvm ls-remote --lts "v${major}" 2>/dev/null \
                | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
                | sort -V | tail -1
        )" || true
        # Transient, not a fault: no component here is broken, the registry was not reachable, and the host keeps
        # the toolchain it already has. See the header's exit-status contract.
        [[ -n "${target_version}" ]] \
            || skip offline "could not resolve the latest v${major} from nvm ls-remote (registry unreachable) -- keeping ${current_version}; nothing was changed"
    fi

    log "Current: ${current_version}  ->  target: ${target_version}"

    # Every npm install from here to the signature gate skips the packages' install scripts, so no package code runs
    # as this account before the registry signature over the installed tree is checked. npm reads the variable
    # from the environment, which covers the installs nvm makes (`nvm install` over the default packages,
    # `nvm reinstall-packages` over the previous version's) as well as install_packages. run_install_scripts runs them
    # after the gate.
    export npm_config_ignore_scripts=true

    if [[ "${current_version}" != "${target_version}" ]]; then
        log "Installing ${target_version}"
        # One subshell for the two, piped through npm_output: reinstall-packages runs npm installs under the version
        # `nvm install` activated, and that activation lives in the subshell a pipeline runs its left side in. The alias
        # and the use that follow run here, so this shell takes the new version.
        { nvm install "${target_version}" --no-progress && nvm reinstall-packages "${current_version}"; } 2>&1 \
            | npm_output
        nvm alias "${node_alias}" "${target_version}"
        nvm use "${node_alias}"
    fi

    nvm use "${node_alias}"

    # The residue routine, from the library the resolver came from. Same guarded load: a library that will not load
    # leaves residue in place and says so, and every launch goes on refusing until a run that can read it.
    local toolchain_lib=/usr/local/lib/ai-tools/toolchain.lib.sh
    # shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/toolchain.lib.sh
    if source "${toolchain_lib}" 2>/dev/null && declare -F ai_tools_toolchain__find_agent_residue >/dev/null 2>&1; then
        remove_residue "${nvm_dir}"
    else
        warn "toolchain library unavailable (${toolchain_lib}) -- a disabled agent's package left in the toolchain is not removed this run"
    fi

    # The managed tool set: an explicit AI_TOOLS_GLOBAL_TOOLS (unit Environment= or manual) overrides; otherwise npm
    # (self-update) plus each enabled agent's package.
    local -a tools
    if [[ -n "${AI_TOOLS_GLOBAL_TOOLS:-}" ]]; then
        IFS=' ' read -ra tools <<< "${AI_TOOLS_GLOBAL_TOOLS}"
    else
        tools=(npm "${agent_packages[@]}")
    fi
    # Which of them are installed without the entrypoint their manifest declares (toolchain.lib.sh), read
    # from the version directory this run installs into, which is what makes the read cover a hole
    # `nvm reinstall-packages` copied there moments ago as well as one an earlier run left. A library that would not
    # load leaves the set empty and every package takes the branch it took before -- the state this repairs, not a new
    # one. What the branch then does, and why the read is keyed on the entrypoint's absence, are in updater.rule.md.
    local version_dir="${nvm_dir}/versions/node/${target_version}"
    local -a repair=()
    if declare -F ai_tools_toolchain__find_incomplete_agents >/dev/null 2>&1; then
        local repair_agent repair_package
        while IFS=$'\t' read -r repair_agent repair_package; do
            [[ -n "${repair_package}" ]] || continue
            warn "${repair_agent}: ${repair_package} is installed without the entrypoint its manifest declares -- reinstalling it; no session of that agent starts until it is back"
            repair+=("${repair_package}")
        done < <(ai_tools_toolchain__find_incomplete_agents "${version_dir}")
    fi

    # The full managed set is the allow-scripts allowlist -- npm re-scans the whole global tree on every install,
    # so each call must cover all of them (see install_packages).
    local allow_csv; allow_csv="$(IFS=,; printf '%s' "${tools[*]}")"
    local repair_csv; repair_csv="$(IFS=,; printf '%s' "${repair[*]}")"
    log "Packages: ${tools[*]}"
    install_packages "${allow_csv}" "${repair_csv}" "${tools[@]}"

    # Fail-closed signature gate BEFORE the install scripts, the prune and the repoint: a detected tamper (die) leaves
    # the tree installed with no script of it run, the previous version un-pruned and the launcher symlink un-repointed,
    # so the trusted toolchain stays active. Runs against the just-installed global tree as the sandbox
    # account.
    verify_toolchain_signatures

    # The install scripts, once the gate has returned verified or unable to verify; a tamper ended the run
    # in verify_toolchain_signatures (see the function).
    unset npm_config_ignore_scripts
    run_install_scripts "${version_dir}" "${tools[@]}"

    # The same read again, now that npm has run and the scripts with it: what it names is a package the install did not
    # complete, which npm itself reports as a success (updater.rule.md). Each is reported here with the line of npm's
    # output that names the cause and counted; the run ends as a fault once every complete agent is repointed (the end
    # of main), so the stamp names the agent no session can start rather than reporting the run as ok.
    local incomplete_after=0 npm_reason=""
    if declare -F ai_tools_toolchain__find_incomplete_agents >/dev/null 2>&1; then
        local left_agent left_package
        npm_reason="$(npm_cause_line)"
        while IFS=$'\t' read -r left_agent left_package; do
            [[ -n "${left_package}" ]] || continue
            incomplete_after=$(( incomplete_after + 1 ))
            warn "${left_agent}: ${left_package} still does not hold the entrypoint its manifest declares after the install -- no session of that agent starts until that executable is installed; npm's output ${npm_reason:+says: ${npm_reason}}${npm_reason:-carries the reason}"
        done < <(ai_tools_toolchain__find_incomplete_agents "${version_dir}")
    fi

    # The versioned launcher chain takes its final shape here, after the install scripts, and ahead of every gate
    # that reads it (see the function).
    relink_agent_launchers "${target_version}"

    # Second gate, the same fail-closed shape, asking the other question: the signature gate says the package was
    # DELIVERED untampered, this says the binary inside it is the one the vendor published. It runs as the sandbox
    # account, so it is a fail-fast economy measure rather than the boundary -- the root-side pin is
    # (updater.rule.md).
    verify_agent_entrypoints "${target_version}"

    prune_versions "${node_alias}"

    # Refresh the stable launcher symlink each wrapper resolves with one readlink hop -- one per enabled agent,
    # from the same manifest-resolved set just installed, so the updater stays agent-agnostic, naming no agent here
    # either. A launcher missing from the new version (an agent whose install failed, or one an operator dropped
    # from AI_TOOLS_AGENTS) is skipped rather than failing the run. /opt/ai-tools/bin is locked 0551 (root:ai-tools)
    # so this process -- running as ai-tools -- cannot write it directly; delegate each repoint to the root helper
    # via the handback socket bridge (sudo fails under NNP, which the session service always runs under due to
    # RestrictNamespaces=yes forcing PR_SET_NO_NEW_PRIVS).
    local launcher versioned_launcher
    for launcher in "${agent_launchers[@]}"; do
        versioned_launcher="${nvm_dir}/versions/node/${target_version}/bin/${launcher}"
        if [[ ! -x "${versioned_launcher}" ]]; then
            log "${launcher} not installed in ${target_version} -- skipping its stable-symlink repoint"
            continue
        fi
        # Not activated: leaving the stable symlink where it is keeps the previously verified and pinned version in use,
        # so the next launch works and this run left it as it was.
        if [[ -n "${entrypoint_blocked[${launcher}]:-}" ]]; then
            warn "not repointing ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher}: its new entrypoint is unverified (see above); the previously verified version stays active"
            continue
        fi
        # Repoint (and, via the ai-tools-relabel.path watcher the touched bin directory drives, relabel) is best-effort,
        # NOT fatal: this warns rather than dying. A manual/out-of-band run (this script's documented use) executes
        # outside a session, where the handback socket may be down -- and the toolchain is already installed by this
        # point, so aborting here would strand a completed update over a symlink the operator can repoint by hand.
        # The scheduled timer run has the socket up and repoints normally.
        if ! /usr/local/bin/ai-tools-handback-client SYMLINK "${versioned_launcher}"; then
            warn "failed to repoint ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher} via handback SYMLINK -- the toolchain is updated but the stable symlink may be stale; repoint it as root: ln -sfn ${versioned_launcher} ${AI_TOOLS_NVM_UPDATE__BIN_DIR}/${launcher} && atr admin system entrypoints relabel"
        fi
    done

    # After the last install of the run, so a package npm left incomplete for want of space has the space on the next
    # run, whose repair branch reinstalls it.
    prune_npm_cache

    log "Done. Active: $(nvm version "${node_alias}")"

    # Both verdicts are reported LAST, after every agent that is complete and did verify has been repointed, so one
    # agent's state never strands another's update, and each goes through the stamp because that is the only channel
    # an operator session can read at all -- see the stamp's own section in this file's header. A package still without
    # its declared entrypoint is a FAULT: the same install on the same host leaves it incomplete until what npm's line
    # names is fixed, so it is decided ahead of the transient verdict, which a reader takes as a retry.
    (( incomplete_after == 0 )) \
        || die MSG-U5N2 "the install left ${incomplete_after} enabled agent(s) without the entrypoint their manifest declares (above, with npm's reason) -- every launch of them is refused until that executable is installed; fix what npm names, then run: atr admin system bootstrap"
    # TRANSIENT rather than failed: no component is broken and that agent is left as it was.
    (( entrypoint_unverified == 0 )) \
        || skip unverified "${entrypoint_unverified} agent entrypoint(s) could not be verified against their vendor's signed release manifest -- not activated; the previously verified version stays in use"
}

main "$@"
