#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-relabel-agent
# Reconcile every enabled agent's entrypoint after a toolchain change, in two steps:
#
#   1. PIN   -- verify it against the checksum its vendor signed and record the result, which the
#              launch shim compares against (entrypoint-verify.lib.sh). Runs on every host,
#              including the DAC-only one where step 2 has no label to apply. A refusal to
#              re-record leaves the pin standing -- that staleness is what refuses the next
#              launch -- so it also files the mark both status reports read, and prints the two
#              commands that replace the binary.
#   2. LABEL -- apply the SELinux file-context rules each agent declares and restore the labels on
#              what they match: its launcher binary -> ai_tools_exec_t, so its exec fires the ->
#              ai_tools_t domain transition, and its config directory -> ai_tools_home_t, so the
#              confined session can write its own state. Freshly installed files are born the
#              default type and only restorecon applies these.
#
# Why both live in one helper, and why a mismatch fails the run while an unverifiable entrypoint does not:
# .claude/rules/updater.rule.md.
#
# It is agent-agnostic: each ai-tools-agents-* package declares its own paths (entrypoint_fcontext and config_dir in its
# manifest under /usr/local/lib/ai-tools/agents.d), and this helper registers them as local file-context rules.
# The labelling body lives in relabel.lib.sh, shared with selinux/install-selinux.sh's verify pass so the two cannot
# drift.
#
# Usage:
#   ai-tools-relabel-agent              relabel every enabled agent's paths (idempotent)
#   ai-tools-relabel-agent --remove <agent>
#                                       drop that agent's file-context rules and restore default
#                                       labels -- run while its manifest still exists (rpm %preun
#                                       of the agent package)
#
# Runs as root (a domain that holds relabel), never the sandbox account. Three callers drive the default form:
# ai-tools-bootstrap at provision time, the ai-tools-relabel.path watcher after an upgrade,
# and `ai-tools-admin system entrypoints relabel` on demand. Every one of them is already root, so this helper carries
# no %ai-ops sudoers rule and its 750 root:root mode is the whole gate. The domain story -- the watcher,
# the ai-tools-run fail-closed backstop, and why the relabel privilege stays off the agent-reachable handback domain --
# is in .claude/rules/updater.rule.md.
#
# No-ops when SELinux is off or the ai_tools module is not installed: there is no ai_tools_exec_t to assign, which is
# a supported (DAC-only) deployment, not a failure.
#
# Deploy:
#   ```bash
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-relabel-agent.sh \
#       /usr/local/libexec/ai-tools/ai-tools-relabel-agent
#   ```

set -euo pipefail

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/relabel.log (shared
# with ai-tools-relabel). Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-relabel-agent"
AI_TOOLS_LOG_FILE="relabel.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log_info() { :; }; ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# say reports progress on stdout, the stream an operator reads the run's story from; warn and die report a problem
# on stderr and carry the severity, so no message text spells one out. A warning that used to travel with the status
# lines therefore moves streams -- deliberately: it is not part of that story, and a caller capturing stdout was
# capturing warnings with it.
say() { printf 'ai-tools-relabel-agent: %s\n' "$*"; }
# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads, and carried into the log line. Matched inline: this helper does not load
# the library.
warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-relabel-agent: warn: %s\n' "$*" >&2
}
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; fi
    ai_tools_log_error "${code:+${code} }$*"
    [[ -z "${code}" ]] || printf '%s\n' "${code}" >&2
    printf 'ai-tools-relabel-agent: error: %s\n' "$*" >&2; exit 1
}

[[ "${EUID}" -eq 0 ]] || die MSG-M3E7 "must run as root (via sudo)"

# The labelling body + the manifest resolver it reads. REQUIRED: without them this helper can resolve no agent and would
# silently label no file, leaving the next launch to fail closed on a mislabelled entrypoint with no explanation. Bare
# source under `set -e`.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
source /usr/local/lib/ai-tools/relabel.lib.sh
declare -F ai_tools_label_agent_paths >/dev/null 2>&1 \
    || die MSG-S9Z3 "relabel.lib.sh is incomplete -- reinstall ai-tools-base"

# Serialize against the other callers of this helper before touching the policy store: the agent package's %post,
# the ai-tools-relabel.path watcher, and `ai-tools-admin system entrypoints relabel` all run it, and an upgrade drives
# two of them at once. Taken here so it covers `--remove` as well, which writes the same store. Proceeding unserialized
# is reported, not fatal (see relabel.lib.sh).
ai_tools_relabel_lock
[[ -z "${AI_TOOLS_RELABEL_LOCK_NOTE}" ]] \
    || { warn MSG-E4U5 "relabels are not serialized on this host -- ${AI_TOOLS_RELABEL_LOCK_NOTE}"
         ai_tools_log_warn "proceeding without the relabel lock -- ${AI_TOOLS_RELABEL_LOCK_NOTE}"; }

# `--remove <agent>`: erase-time counterpart, invoked by the agent package's own %preun while its manifest is still
# on disk. Dropping the rules matters because the types they name belong to the base policy, which the host may erase
# next.
if [[ "${1:-}" == --remove ]]; then
    agent="${2:?usage: ai-tools-relabel-agent --remove <agent-name>}"
    rc=0; ai_tools_unlabel_agent_paths "${agent}" || rc=$?
    case "${rc}" in
        0) say "dropped the file-context rules for ${agent}"
           ai_tools_log_info "dropped the file-context rules for ${agent}" ;;
        2) say "SELinux confinement inactive -- no file-context to drop" ;;
        *) die MSG-S6C5 "no usable path rules declared by ${agent} -- nothing dropped" ;;
    esac
    exit 0
fi
[[ "$#" -eq 0 ]] || die MSG-T2W3 "usage: ai-tools-relabel-agent [--remove <agent-name>]"

# ── Step 1: entrypoint pinning ───────────────────────────────────────────────────────────────
# Before the labelling and independent of it, so a DAC-only host still gets a pin.
readonly ENTRYPOINT_VERIFY_LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/entrypoint-verify.lib.sh
if ! source "${ENTRYPOINT_VERIFY_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_entrypoint_release_verify >/dev/null 2>&1; then
    warn MSG-H9M5 "entrypoint verifier unavailable (${ENTRYPOINT_VERIFY_LIB}) -- entrypoints will not be pinned"
    ai_tools_log_warn "entrypoint verifier unavailable -- no entrypoint pinned this run"
    ai_tools_entrypoint_release_verify() { return 2; }
    ai_tools_entrypoint_pin_write() { return 1; }
    ai_tools_entrypoint_label_write() { return 1; }
    ai_tools_entrypoint_inputs_digest() { return 1; }
    ai_tools_entrypoint_sha256() { return 1; }
    ai_tools_entrypoint_stale_write() { return 1; }
    ai_tools_entrypoint_stale_clear() { return 0; }
    ai_tools_entrypoint_package_dir() { return 1; }
fi

# reinstall_remedy <agent> <entrypoint> : print the two commands that replace a changed binary, one per line,
#   or an empty string when the package directory cannot be derived. `system bootstrap` alone does NOT do it --
#   its npm step is a no-op at an already-installed version, so the modified file survives the reprovision
#   and the host keeps refusing every launch with no explanation. Removing the package directory is what makes
#   the reinstall fetch it again.
reinstall_remedy() {
    local agent="$1" entrypoint="$2" package package_dir
    package="$(ai_tools_agent_manifest_field "${agent}" npm_package || true)"
    package_dir="$(ai_tools_entrypoint_package_dir "${entrypoint}" "${package}" 2>/dev/null || true)"
    [[ -n "${package_dir}" ]] || return 0
    printf '  sudo rm -rf %s\n  sudo ai-tools-admin system bootstrap' "${package_dir}"
}

# report_entrypoint_refusal <agent> <version> <reason-token> <entrypoint> : file the stale mark and print the remedy,
#   for either tier's refusal to re-record a pin. The mark is what the two status reports read: the pin is left
#   standing on purpose -- that is what makes the next launch refuse -- so without a record beside it both reports
#   render the stale pin green and the refusal reaches only whoever ran this helper. Best-effort, and it never
#   changes the outcome of the reconciliation it describes.
report_entrypoint_refusal() {
    local agent="$1" version="$2" reason="$3" entrypoint="$4" remedy
    ai_tools_entrypoint_stale_write "${agent}" "${version}" "${reason}" \
        || warn MSG-K4D7 "could not record ${agent}'s stale pin for ai-tools status -- the reports will render its pin as current"
    remedy="$(reinstall_remedy "${agent}" "${entrypoint}")"
    if [[ -n "${remedy}" ]]; then
        say "replace the binary and reprovision -- reprovisioning alone reinstalls nothing at an unchanged version:"
        say "${remedy}"
    fi
    return 0
}

# observe_agent_entrypoint <agent> : record the checksum of the installed entrypoint for an agent that declares no
#   signed release manifest, so the launch gate has a value to compare against. Returns 1 when the same version now
#   hashes differently -- the one state an update does not explain, where the pin is deliberately left stale so the
#   next launch refuses. ai_tools_entrypoint_observe_decision holds that rule and is unit-tested over its table.
observe_agent_entrypoint() {
    local agent="$1" entrypoint version observed pinned_version pinned_sha decision
    declare -F ai_tools_entrypoint_pin_write_observed >/dev/null 2>&1 || return 0

    entrypoint="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
    if [[ -z "${entrypoint}" ]]; then
        say "${agent}: not provisioned -- nothing to pin"
        return 0
    fi
    observed="$(ai_tools_entrypoint_sha256 "${entrypoint}" 2>/dev/null || true)"
    # An unreadable version becomes the same token the pin records, so the two sides of the decision compare like
    # for like. Left empty here it would never equal the pinned `unknown`, every run would read as a new version,
    # and a changed binary would be re-recorded instead of refused -- the one outcome this tier exists to prevent.
    version="$(_installed_agent_version "${entrypoint}")"
    version="${version:-unknown}"
    pinned_version="$(ai_tools_entrypoint_pin_version "${agent}" 2>/dev/null || true)"
    pinned_sha="$(ai_tools_entrypoint_pin_read "${agent}" 2>/dev/null || true)"
    decision="$(ai_tools_entrypoint_observe_decision \
                    "${pinned_version}" "${pinned_sha}" "${version}" "${observed}" || true)"
    case "${decision}" in
        keep)   say "${agent}: entrypoint unchanged since its pin for ${version} -- no signature to check"
                ai_tools_entrypoint_stale_clear "${agent}" || true ;;
        pin)    if ai_tools_entrypoint_pin_write_observed "${agent}" "${version}" "${observed}"; then
                    say "${agent}: entrypoint pinned as installed at ${version} -- no vendor signature to verify it against"
                    ai_tools_log_info "${agent}: entrypoint pinned by observation at ${version} (${observed})"
                    # The pin this run wrote describes what is installed, so whatever a previous run refused is settled.
                    ai_tools_entrypoint_stale_clear "${agent}" || true
                else
                    warn MSG-M6C3 "could not write the observed pin for ${agent} at ${version}"
                    ai_tools_log_warn "${agent}: observed pin write failed at ${version}"
                fi ;;
        tamper) warn MSG-U6H8 "the ${agent} entrypoint changed under an unchanged version ${version} -- leaving the pin as it is, so the next session refuses to start"
                ai_tools_log_error "${agent}: entrypoint changed under an unchanged version ${version} -- pin left stale"
                report_entrypoint_refusal "${agent}" "${version}" "changed-under-same-version" "${entrypoint}"
                return 1 ;;
        *)      say "${agent}: entrypoint could not be hashed -- pin unchanged" ;;
    esac
    return 0
}

# pin_agent_entrypoint <agent> : verify one agent's installed entrypoint against its vendor's
#   signed release manifest and record the result. Returns 1 only on a mismatch.
#
#   AI_TOOLS_ENTRYPOINT_PIN_REUSE=1 lets a run answer from the existing pin when no input that
#   decides the verdict has changed, skipping two network fetches and a gpgv per agent. It is
#   OPT-IN, and the two unattended callers are what it is for: the ai-tools-relabel.path watcher,
#   which an upgrade can fire several times for one change, and the agent package's %post.
#   `ai-tools-admin system entrypoints relabel` clears the variable before it execs this helper, so
#   the on-demand command re-checks the vendor's signature every time -- the behaviour it
#   documents. What reuse gives up, and what it keeps, are in updater.rule.md.
pin_agent_entrypoint() {
    local agent="$1" entrypoint url_template key_file fingerprints version checksum rc=0
    local observed inputs

    url_template="$(ai_tools_agent_manifest_field "${agent}" release_manifest_url || true)"
    # An agent whose vendor publishes no signed release manifest gets the weaker of the two pins rather than none: root
    # records the checksum of what is installed, so a later change to that file is refused at the next launch.
    [[ -n "${url_template}" ]] || { observe_agent_entrypoint "${agent}"; return $?; }
    key_file="$(ai_tools_agent_manifest_field "${agent}" release_key || true)"
    fingerprints="$(ai_tools_agent_manifest_field "${agent}" release_fingerprint || true)"

    entrypoint="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
    if [[ -z "${entrypoint}" ]]; then
        say "${agent}: not provisioned -- nothing to verify or pin"
        return 0
    fi
    # The installed version, read from the package metadata beside the entrypoint. It is sandbox-owned, so it is
    # accepted only in semver shape -- and claiming a different version gains the caller no advantage: every candidate
    # manifest is signed, so a false claim yields a checksum that does not match rather than one that does.
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
            # The pin describes this file and this version, so a refusal an earlier run recorded no longer stands.
            ai_tools_entrypoint_stale_clear "${agent}" || true
            return 0
        fi
    fi

    checksum="$(ai_tools_entrypoint_release_verify "${entrypoint}" "${version}" \
                    "${url_template}" "${key_file}" "${fingerprints}")" || rc=$?
    case "${rc}" in
        0)  if ai_tools_entrypoint_pin_write "${agent}" "${version}" "${checksum}" "${url_template}" "${inputs}"; then
                say "${agent}: entrypoint verified against the signed release ${version} and pinned"
                ai_tools_log_info "${agent}: entrypoint pinned at ${version} (${checksum})"
                ai_tools_entrypoint_stale_clear "${agent}" || true
            else
                warn MSG-W8N5 "could not write the pin for ${agent} after verifying ${version}"
                ai_tools_log_warn "${agent}: pin write failed at ${version}"
            fi ;;
        1)  ai_tools_log_error "${agent}: entrypoint does not match the signed release ${version}"
            report_entrypoint_refusal "${agent}" "${version}" "signature-mismatch" "${entrypoint}"
            return 1 ;;
        *)  warn MSG-B6H9 "could not verify the entrypoint for ${agent} against release ${version} (see above) -- pin unchanged"
            ai_tools_log_warn "${agent}: entrypoint unverified at ${version}; pin left as-is" ;;
    esac
    return 0
}

# _installed_agent_version <entrypoint> : print the version the package around the entrypoint declares,
#   or an empty string. The walk, the bounded read and the clamp are the library's
#   (ai_tools_entrypoint_installed_version), which the launch banner reads through as well, so the pin
#   and the banner cannot report different versions for one binary.
_installed_agent_version() {
    ai_tools_entrypoint_installed_version "${1:-}"
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
# Reported before any labelling outcome: an entrypoint that is not the binary its vendor published is a more serious
# finding than any label, and the remedy is different in kind.
(( pin_failures == 0 )) \
    || die MSG-W6V4 "treat the toolchain as tampered: ${pin_failures} agent entrypoint(s) no longer match the checksum recorded for the installed version; the pin is left as it was, so their sessions refuse to start -- replace each binary with the two commands printed above, and investigate before launching a session"

# Collect the report first, so the lib's return code survives (2 = the SELinux layer is not active here, which is
# a supported deployment and not a failure).
report=""; status=0
report="$(ai_tools_label_agent_paths)" || status=$?

# record_label_outcome <agent> <ok|failed|skipped> [reason-token] : file what this run could do
#   about that agent's labels where `ai-tools status` can read it. The operator cannot inspect
#   the labels themselves -- the entrypoint sits in a toolchain they cannot traverse -- so this
#   record is the only account of the labelling half they have, the counterpart to the pin the
#   verification half writes. Best-effort: a record that cannot be written is reported and never
#   changes the outcome of the relabel it describes.
record_label_outcome() {
    ai_tools_entrypoint_label_write "$1" "$2" "${3:-}" && return 0
    warn MSG-G5H9 "could not record ${1}'s labelling outcome for ai-tools status"
    ai_tools_log_warn "could not write the label record for $1"
    return 0
}

if (( status == 2 )); then
    say "SELinux confinement inactive -- no agent labelling needed"
    # Recorded rather than left silent: on a DAC-only host there is no entrypoint to label and no fault to fix, which is
    # a different report from "this vantage point cannot tell".
    for label_agent in "${enabled_agents[@]:-}"; do
        [[ -n "${label_agent}" ]] || continue
        record_label_outcome "${label_agent}" skipped selinux-inactive
    done
    exit 0
fi

# Render the lib's status lines: it reports per path and per agent, this decides what an operator reads and what fails
# the run. The wanted type travels with a "bad" line, since an agent declares two paths that carry different types.
labelled=0 mislabelled=0 stale=0
declare -A agent_outcome=() agent_reason=()
if [[ -n "${report}" ]]; then
    while read -r verdict subject detail wanted; do
        case "${verdict}" in
            ok)    labelled=$(( labelled + 1 ))
                   say "labelled: ${subject}"
                   ai_tools_log_info "relabelled ${subject}" ;;
            bad)   mislabelled=$(( mislabelled + 1 ))
                   warn MSG-G7C7 "wrong type on ${subject}: it is '${detail}', NOT ${wanted}"
                   ai_tools_log_warn "${subject} did not take ${wanted} (now '${detail}')" ;;
            stale) stale=$(( stale + 1 ))
                   agent_reason["${subject}"]="stale-declaration"
                   warn MSG-Z5B4 "stale declaration for ${subject}: its installed entrypoint is
       ${detail} -- a path the file-context rule its manifest declares does not cover"
                   ai_tools_log_warn "${subject}: installed entrypoint ${detail} is not covered by its declared entrypoint_fcontext" ;;
            none)  say "${subject}: ${detail} is not installed -- nothing to label"
                   ai_tools_log_info "${subject}: ${detail} absent, nothing to label" ;;
            skip)  agent_reason["${subject}"]="rule-not-registered"
                   warn MSG-X7F9 "labelling skipped for ${subject} -- ${detail} ${wanted}"
                   ai_tools_log_warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
            # Closes an agent's lines with its whole outcome. Recorded here, where the per-agent reason lines have
            # already been seen, so a failure is filed with the cause that decides the remedy rather than with a bare
            # "failed".
            agent) agent_outcome["${subject}"]="${detail}" ;;
        esac
    done <<< "${report}"
fi

for label_agent in "${!agent_outcome[@]}"; do
    case "${agent_outcome[${label_agent}]}" in
        ok)     record_label_outcome "${label_agent}" ok ;;
        # Nothing installed to label: the ordinary state before ai-tools-bootstrap provisions the toolchain, and not
        # a fault -- so it is filed the same way an inactive SELinux layer is.
        none)   record_label_outcome "${label_agent}" skipped not-provisioned ;;
        failed) record_label_outcome "${label_agent}" failed \
                    "${agent_reason[${label_agent}]:-did-not-take-its-type}" ;;
    esac
done

# A stale declaration is reported FIRST, because it is the more specific cause and the only one here this helper cannot
# clear: the entrypoint is installed somewhere the declared rule does not reach, so every relabel -- this one included
# -- leaves it unlabelled and every launch fail-closes. Naming the module or a rerun as the remedy would send
# the operator around a loop that cannot end. The fix is upstream of this helper, in the agent package's manifest.
(( stale == 0 )) \
    || die MSG-M2M5 "a stale declaration stops this relabel: ${stale} agent(s) install their entrypoint where their manifest no longer says, so it cannot be labelled; update the agent package (dnf update 'ai-tools-agents-*'), then rerun"
# A mislabelled path is a broken session: a mislabelled entrypoint runs unconfined (ai-tools-run refuses the launch)
# and a mislabelled config directory leaves the agent unable to write its own state. Fail rather than report success --
# this is the earlier, clearer signal.
(( mislabelled == 0 )) \
    || die MSG-A3B5 "the relabel did not take: ${mislabelled} path(s) did not take their type -- is the ai_tools module loaded? run: sudo selinux/install-selinux.sh install"
(( status == 0 )) \
    || die MSG-N9B9 "an agent's file-context rule could not be applied (see above)"

if (( labelled > 0 )); then
    say "all ${labelled} path(s) labelled -- exit any running session and relaunch"
    ai_tools_log_info "relabelled ${labelled} agent path(s)"
elif [[ -z "${report}" ]]; then
    say "no enabled agent declares a file-context rule -- nothing to label"
fi
