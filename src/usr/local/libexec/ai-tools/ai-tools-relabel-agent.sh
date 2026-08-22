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
fi

# pin_agent_entrypoint <agent> : verify one agent's installed entrypoint against its vendor's
#   signed release manifest and record the result. Returns 1 only on a mismatch.
pin_agent_entrypoint() {
    local agent="$1" entrypoint url_template key_file fingerprints version checksum rc=0

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

    checksum="$(ai_tools_entrypoint_release_verify "${entrypoint}" "${version}" \
                    "${url_template}" "${key_file}" "${fingerprints}")" || rc=$?
    case "${rc}" in
        0)  if ai_tools_entrypoint_pin_write "${agent}" "${version}" "${checksum}" "${url_template}"; then
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
if declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    while IFS=$'\t' read -r pin_agent _ _; do
        [[ -n "${pin_agent}" ]] || continue
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
if (( status == 2 )); then
    say "SELinux confinement inactive -- no agent labelling needed"
    exit 0
fi

# Render the lib's status lines: it reports per path and per agent, this decides what an operator
# reads and what fails the run. The wanted type travels with a "bad" line, since an agent
# declares two paths that carry different types.
labelled=0 mislabelled=0 stale=0
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
                   say "WARNING: ${subject}: its installed entrypoint is ${detail}"
                   say "         -- a path the file-context rule its manifest declares does not cover"
                   ai_tools_log_warn "${subject}: installed entrypoint ${detail} is not covered by its declared entrypoint_fcontext" ;;
            none)  say "${subject}: ${detail} is not installed -- nothing to label"
                   ai_tools_log_info "${subject}: ${detail} absent, nothing to label" ;;
            skip)  say "${subject}: skipped -- ${detail} ${wanted}"
                   ai_tools_log_warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
        esac
    done <<< "${report}"
fi

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
