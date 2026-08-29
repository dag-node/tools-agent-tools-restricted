#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-relabel-agent
# Reconcile every enabled agent's entrypoint after a toolchain change, in two steps:
#
#   1. PIN   -- verify it against the checksum its vendor signed and record the result, which the
#              launch shim compares against (entrypoint-verify.lib.sh). Runs on every host,
#              including the DAC-only one where step 2 has nothing to do.
#   2. LABEL -- apply the SELinux file-context rules each agent declares and restore the labels on
#              what they match: its launcher binary -> ai_tools_exec_t, so its exec fires the ->
#              ai_tools_t domain transition, and its config directory -> ai_tools_home_t, so the
#              confined session can write its own state. Freshly installed files are born the
#              default type and only restorecon applies these.
#
# Why both live in one helper, and why a mismatch fails the run while an unverifiable entrypoint
# does not: .claude/rules/updater.rule.md.
#
# It names no agent: each ai-tools-agents-* package declares its own paths (entrypoint_fcontext
# and config_dir in its manifest under /usr/local/lib/ai-tools/agents.d), and this helper
# registers them as local file-context rules. The labelling body lives in relabel.lib.sh, shared
# with selinux/install-selinux.sh's verify pass so the two cannot drift.
#
# Usage:
#   ai-tools-relabel-agent              relabel every enabled agent's paths (idempotent)
#   ai-tools-relabel-agent --remove <agent>
#                                       drop that agent's file-context rules and restore default
#                                       labels -- run while its manifest still exists (rpm %preun
#                                       of the agent package)
#
# Runs as root (a domain that holds relabel), never the sandbox account. Three callers drive the
# default form: ai-tools-bootstrap at provision time, the ai-tools-relabel.path watcher after an
# upgrade, and `ai-tools --relabel` on demand. The operators' sudo grant covers the ZERO-ARGUMENT
# form only, so --remove is reachable by root alone. The domain story -- the watcher, the
# ai-tools-run fail-closed backstop, and why the relabel privilege stays off the agent-reachable
# handback domain -- is in .claude/rules/updater.rule.md.
#
# No-ops when SELinux is off or the ai_tools module is not installed: there is no
# ai_tools_exec_t to assign, which is a supported (DAC-only) deployment, not a failure.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#     src/usr/local/libexec/ai-tools/ai-tools-relabel-agent.sh \
#     /usr/local/libexec/ai-tools/ai-tools-relabel-agent

set -euo pipefail

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/relabel.log
# (shared with ai-tools-relabel). Best-effort -- a no-op fallback keeps the helper working
# if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel-agent"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log_info() { :; }; ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

say() { printf 'ai-tools-relabel-agent: %s\n' "$*"; }
die() { ai_tools_log_error "$*"; printf 'ai-tools-relabel-agent: error: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "must run as root (via sudo)"

# The labelling body + the manifest resolver it reads. REQUIRED: without them this helper can
# resolve no agent and would silently label nothing, leaving the next launch to fail closed on a
# mislabelled entrypoint with no explanation. Bare source under set -e.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
source /usr/local/lib/ai-tools/relabel.lib.sh
declare -F ai_tools_label_agent_paths >/dev/null 2>&1 \
    || die "relabel.lib.sh is incomplete -- reinstall ai-tools-base"

# Serialize against the other callers of this helper before touching the policy store: the agent
# package's %post, the ai-tools-relabel.path watcher, and `ai-tools --relabel` all run it, and an
# upgrade drives two of them at once. Taken here so it covers --remove as well, which writes the
# same store. Proceeding unserialized is reported, not fatal (see relabel.lib.sh).
ai_tools_relabel_lock
[[ -z "${AI_TOOLS_RELABEL_LOCK_NOTE}" ]] \
    || { say "NOTE: relabels are not serialized on this host -- ${AI_TOOLS_RELABEL_LOCK_NOTE}"
         ai_tools_log_warn "proceeding without the relabel lock -- ${AI_TOOLS_RELABEL_LOCK_NOTE}"; }

# --remove <agent>: erase-time counterpart, invoked by the agent package's own %preun while its
# manifest is still on disk. Dropping the rules matters because the types they name belong to the
# base policy, which the host may erase next.
if [[ "${1:-}" == --remove ]]; then
    agent="${2:?usage: ai-tools-relabel-agent --remove <agent-name>}"
    rc=0; ai_tools_unlabel_agent_paths "${agent}" || rc=$?
    case "${rc}" in
        0) say "dropped the file-context rules for ${agent}"
           ai_tools_log_info "dropped the file-context rules for ${agent}" ;;
        2) say "SELinux confinement inactive -- no file-context to drop" ;;
        *) die "${agent} declares no usable path rules -- nothing dropped" ;;
    esac
    exit 0
fi
[[ "$#" -eq 0 ]] || die "usage: ai-tools-relabel-agent [--remove <agent-name>]"

# ── Step 1: entrypoint pinning ───────────────────────────────────────────────────────────────
# Before the labelling and independent of it, so a DAC-only host still gets a pin.
readonly ENTRYPOINT_VERIFY_LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/entrypoint-verify.lib.sh
if ! source "${ENTRYPOINT_VERIFY_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_entrypoint_release_verify >/dev/null 2>&1; then
    say "entrypoint verifier unavailable (${ENTRYPOINT_VERIFY_LIB}) -- entrypoints will not be pinned"
    ai_tools_log_warn "entrypoint verifier unavailable -- no entrypoint pinned this run"
    ai_tools_entrypoint_release_verify() { return 2; }
    ai_tools_entrypoint_pin_write() { return 1; }
    ai_tools_entrypoint_label_write() { return 1; }
    ai_tools_entrypoint_inputs_digest() { return 1; }
    ai_tools_entrypoint_sha256() { return 1; }
fi

# pin_agent_entrypoint <agent> : verify one agent's installed entrypoint against its vendor's
#   signed release manifest and record the result. Returns 1 only on a mismatch.
#
#   AI_TOOLS_ENTRYPOINT_PIN_REUSE=1 lets a run answer from the existing pin when nothing that
#   decides the verdict has changed, skipping two network fetches and a gpgv per agent. It is
#   OPT-IN, and the two unattended callers are what it is for: the ai-tools-relabel.path watcher,
#   which an upgrade can fire several times for one change, and the agent package's %post. An
#   operator running `ai-tools --relabel` reaches this helper through sudo, which scrubs the
#   environment, so that command re-checks the vendor's signature every time -- the behaviour it
#   documents. What reuse gives up, and what it keeps, are in updater.rule.md.
pin_agent_entrypoint() {
    local agent="$1" entrypoint url_template key_file fingerprints version checksum rc=0
    local observed inputs

    url_template="$(ai_tools_agent_manifest_field "${agent}" release_manifest_url || true)"
    [[ -n "${url_template}" ]] || return 0          # declares no provenance: nothing to verify
    key_file="$(ai_tools_agent_manifest_field "${agent}" release_key || true)"
    fingerprints="$(ai_tools_agent_manifest_field "${agent}" release_fingerprint || true)"

    entrypoint="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
    if [[ -z "${entrypoint}" ]]; then
        say "${agent}: not provisioned -- nothing to verify or pin"
        return 0
    fi
    # The installed version, read from the package metadata beside the entrypoint. It is
    # sandbox-owned, so it is accepted only in semver shape -- and claiming a different version
    # buys nothing: every candidate manifest is signed, so a false claim yields a checksum that
    # does not match rather than one that does.
    version="$(_installed_agent_version "${entrypoint}")"
    if [[ -z "${version}" ]]; then
        say "${agent}: could not read the installed version -- not pinned"
        return 0
    fi

    inputs="$(ai_tools_entrypoint_inputs_digest "${url_template}" "${key_file}" "${fingerprints}" \
                2>/dev/null || true)"
    if [[ "${AI_TOOLS_ENTRYPOINT_PIN_REUSE:-0}" == "1" ]] \
            && declare -F ai_tools_entrypoint_pin_reusable >/dev/null 2>&1; then
        observed="$(ai_tools_entrypoint_sha256 "${entrypoint}" 2>/dev/null || true)"
        if ai_tools_entrypoint_pin_reusable "${agent}" "${version}" "${inputs}" "${observed}"; then
            say "${agent}: entrypoint unchanged since its pin for ${version} -- signature not re-checked"
            ai_tools_log_info "${agent}: pin reused at ${version} -- no manifest fetch"
            return 0
        fi
    fi

    checksum="$(ai_tools_entrypoint_release_verify "${entrypoint}" "${version}" \
                    "${url_template}" "${key_file}" "${fingerprints}")" || rc=$?
    case "${rc}" in
        0)  if ai_tools_entrypoint_pin_write "${agent}" "${version}" "${checksum}" "${url_template}" "${inputs}"; then
                say "${agent}: entrypoint verified against the signed release ${version} and pinned"
                ai_tools_log_info "${agent}: entrypoint pinned at ${version} (${checksum})"
            else
                say "WARNING: ${agent}: verified ${version} but could not write its pin"
                ai_tools_log_warn "${agent}: pin write failed at ${version}"
            fi ;;
        1)  ai_tools_log_error "${agent}: entrypoint does not match the signed release ${version}"
            return 1 ;;
        *)  say "${agent}: could not verify the entrypoint against release ${version} (see above) -- pin unchanged"
            ai_tools_log_warn "${agent}: entrypoint unverified at ${version}; pin left as-is" ;;
    esac
    return 0
}

# _installed_agent_version <entrypoint> : print the MAJOR.MINOR.PATCH the package beside the
#   entrypoint declares, walking up to the nearest package.json the way ai-tools-run does for the
#   launch banner. Bounded read; anything not semver-shaped yields nothing.
_installed_agent_version() {
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

pin_failures=0
enabled_agents=()
if declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    while IFS=$'\t' read -r pin_agent _ _; do
        [[ -n "${pin_agent}" ]] || continue
        enabled_agents+=( "${pin_agent}" )
        pin_agent_entrypoint "${pin_agent}" || pin_failures=$(( pin_failures + 1 ))
    done < <(ai_tools_enabled_agents 2>/dev/null)
fi
# Reported before any labelling outcome: an entrypoint that is not the binary its vendor published
# is a more serious finding than any label, and the remedy is different in kind.
(( pin_failures == 0 )) \
    || die "${pin_failures} agent entrypoint(s) do NOT match the checksum their vendor signed for the installed version -- treat the toolchain as tampered; reprovision it (sudo ai-tools-bootstrap) and, if it recurs, investigate before launching a session"

# Collect the report first, so the lib's return code survives (2 = the SELinux layer is not
# active here, which is a supported deployment and not a failure).
report=""; status=0
report="$(ai_tools_label_agent_paths)" || status=$?

# record_label_outcome <agent> <ok|failed|skipped> [reason-token] : file what this run could do
#   about that agent's labels where `ai-tools --status` can read it. The operator cannot inspect
#   the labels themselves -- the entrypoint sits in a toolchain they cannot traverse -- so this
#   record is the only account of the labelling half they have, the counterpart to the pin the
#   verification half writes. Best-effort: a record that cannot be written is reported and never
#   changes the outcome of the relabel it describes.
record_label_outcome() {
    ai_tools_entrypoint_label_write "$1" "$2" "${3:-}" && return 0
    say "WARNING: could not record ${1}'s labelling outcome for ai-tools --status"
    ai_tools_log_warn "could not write the label record for $1"
    return 0
}

if (( status == 2 )); then
    say "SELinux confinement inactive -- no agent labelling needed"
    # Recorded rather than left silent: on a DAC-only host there is nothing to label and nothing to
    # fix, which is a different report from "this vantage point cannot tell".
    for label_agent in "${enabled_agents[@]:-}"; do
        [[ -n "${label_agent}" ]] || continue
        record_label_outcome "${label_agent}" skipped selinux-inactive
    done
    exit 0
fi

# Render the lib's status lines: it reports per path and per agent, this decides what an operator
# reads and what fails the run. The wanted type travels with a "bad" line, since an agent
# declares two paths that carry different types.
labelled=0 mislabelled=0 stale=0
declare -A agent_outcome=() agent_reason=()
if [[ -n "${report}" ]]; then
    while read -r verdict subject detail wanted; do
        case "${verdict}" in
            ok)    labelled=$(( labelled + 1 ))
                   say "labelled: ${subject}"
                   ai_tools_log_info "relabelled ${subject}" ;;
            bad)   mislabelled=$(( mislabelled + 1 ))
                   say "WARNING: ${subject} is '${detail}', NOT ${wanted}"
                   ai_tools_log_warn "${subject} did not take ${wanted} (now '${detail}')" ;;
            stale) stale=$(( stale + 1 ))
                   agent_reason["${subject}"]="stale-declaration"
                   say "WARNING: ${subject}: its installed entrypoint is ${detail}"
                   say "         -- a path the file-context rule its manifest declares does not cover"
                   ai_tools_log_warn "${subject}: installed entrypoint ${detail} is not covered by its declared entrypoint_fcontext" ;;
            none)  say "${subject}: ${detail} is not installed -- nothing to label"
                   ai_tools_log_info "${subject}: ${detail} absent, nothing to label" ;;
            skip)  agent_reason["${subject}"]="rule-not-registered"
                   say "${subject}: skipped -- ${detail} ${wanted}"
                   ai_tools_log_warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
            # Closes an agent's lines with its whole outcome. Recorded here, where the per-agent
            # reason lines above have already been seen, so a failure is filed with the cause that
            # decides the remedy rather than with a bare "failed".
            agent) agent_outcome["${subject}"]="${detail}" ;;
        esac
    done <<< "${report}"
fi

for label_agent in "${!agent_outcome[@]}"; do
    case "${agent_outcome[${label_agent}]}" in
        ok)     record_label_outcome "${label_agent}" ok ;;
        # Nothing installed to label: the ordinary state before ai-tools-bootstrap provisions the
        # toolchain, and not a fault -- so it is filed the same way an inactive SELinux layer is.
        none)   record_label_outcome "${label_agent}" skipped not-provisioned ;;
        failed) record_label_outcome "${label_agent}" failed \
                    "${agent_reason[${label_agent}]:-did-not-take-its-type}" ;;
    esac
done

# A stale declaration is reported FIRST, because it is the more specific cause and the only one
# here this helper cannot clear: the entrypoint is installed somewhere the declared rule does not
# reach, so every relabel -- this one included -- leaves it unlabelled and every launch
# fail-closes. Naming the module or a rerun as the remedy would send the operator around a loop
# that cannot end. The fix is upstream of this helper, in the agent package's manifest.
(( stale == 0 )) \
    || die "${stale} agent(s) install their entrypoint where their manifest no longer says -- this relabel cannot label it; update the agent package (dnf update 'ai-tools-agents-*'), then rerun"
# A mislabelled path is a broken session: a mislabelled entrypoint runs unconfined (ai-tools-run
# refuses the launch) and a mislabelled config directory leaves the agent unable to write its own
# state. Fail rather than report success -- this is the earlier, clearer signal.
(( mislabelled == 0 )) \
    || die "${mislabelled} path(s) did not take their type -- is the ai_tools module loaded? run: sudo selinux/install-selinux.sh install"
(( status == 0 )) \
    || die "an agent's file-context rule could not be applied (see above)"

if (( labelled > 0 )); then
    say "all ${labelled} path(s) labelled -- exit any running session and relaunch"
    ai_tools_log_info "relabelled ${labelled} agent path(s)"
elif [[ -z "${report}" ]]; then
    say "no enabled agent declares a file-context rule -- nothing to label"
fi
