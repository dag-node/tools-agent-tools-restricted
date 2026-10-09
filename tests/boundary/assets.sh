#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/assets.sh
# Boundary: the inputs that decide what signs an asset set and which assets a session loads are root-owned and not
# group- or other-writable, so the sandbox account cannot change them. Probed AS the agent (`runuser -u ai-tools`),
# against the DEPLOYED files assets-verify.lib.sh reads -- the library, the shipped signing key and the keyring written
# from it, the bindings directory and each binding in it -- and the ones assets.lib.sh reads and writes: the resolver,
# operator.conf, the roots and the sets under them, the view, the lock, and each agent's kind directories. A set links
# only under a signature by a primary a binding names (unit-tested in tests/unit/assets-verify.sh); this file asserts
# the other half -- that on a real install the agent cannot put any of those inputs into a state the verifier would
# read. Both halves must hold: the runtime check catches a host someone has already broken, this catches the agent
# trying to break it.
#
# It also asserts the modes the files ship with, so a mode change that widens one fails here before a refusal has
# to catch it. Probe-only (`test -w`); no file is written, created, or unlinked. Run as root via sudo; drops
# to the agent per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Asset-set signing inputs are not agent-writable (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "asset signing inputs" "runuser not available"; finish; exit
fi

readonly LIBDIR=/usr/local/lib/ai-tools
readonly BINDINGS="${LIBDIR}/assets-bindings.d"

# not_writable <path> <what it would let the agent do>: PASS when the agent cannot write <path>; FAIL naming
# the escalation it would allow. A path that is not deployed on this host SKIPs.
not_writable() {
    local path="$1" consequence="$2"
    if [[ ! -e "${path}" ]]; then
        skip "${path}" "not deployed on this host"
        return
    fi
    if runuser -u "${SANDBOX_USER}" -- test -w "${path}" 2>/dev/null; then
        fail "agent can write ${path} -- it could ${consequence}"
    else
        pass "cannot write ${path}: agent cannot ${consequence}"
    fi
}

# The verifier itself, sourced by the resolver as root.
not_writable "${LIBDIR}/assets-verify.lib.sh" \
    "rewrite the verifier to accept any signature"

# The key and the keyring gpgv reads. Writable, the agent swaps in a key of its own; the binding's fingerprint would
# still refuse the swap, which is why the key and the keyring are each asserted.
not_writable "${LIBDIR}/keys" \
    "replace a shipped key under its name"
not_writable "${LIBDIR}/keys/dag-node-package-signing.asc" \
    "replace the published key the keyring is written from"
not_writable "${LIBDIR}/keys/dag-node-package-signing.gpg" \
    "replace the keyring a set's signature is verified against"

# The bindings: which primary may sign each set name, and which keyring. Writable, the agent names its own key.
not_writable "${BINDINGS}" \
    "add or replace a binding and name its own key as a set's signer"
for binding in "${BINDINGS}"/*.conf; do
    [[ -e "${binding}" ]] || { skip "${BINDINGS}/*.conf" "no binding deployed"; break; }
    not_writable "${binding}" \
        "name its own key as the signer of set $(basename "${binding}" .conf)"
done

section "The resolver's inputs, the view and the agents' links are not agent-writable (run as the agent)"

# The resolver and the one input that enables an asset.
not_writable "${LIBDIR}/assets.lib.sh" \
    "rewrite the resolver to link a set that fails its signature or its rules"
not_writable /etc/ai-tools/operator.conf \
    "enable an asset, or empty AI_TOOLS_ASSETS"

# The roots: writable, the agent places a set of its own (refused unsigned, but the roots are the packages'
# and the operator's alone), or removes a packaged one.
for root in /usr/local/share/ai-tools-assets /usr/share/ai-tools-assets /usr/share/ai-tools; do
    not_writable "${root}" "create or remove a set under ${root}"
    [[ -d "${root}" ]] || continue
    owned="$(find -P "${root}" -mindepth 1 -user "${SANDBOX_USER}" -print -quit 2>/dev/null || true)"
    if [[ -n "${owned}" ]]; then
        fail "${owned} under ${root} is owned by ${SANDBOX_USER}, which could chmod or rewrite it"
    else
        pass "no entry under ${root} is owned by ${SANDBOX_USER}, so none takes its chmod"
    fi
    while IFS= read -r -d '' file; do
        not_writable "${file}" "rewrite a file of a set"
    done < <(find -P "${root}" -mindepth 1 -maxdepth 3 -type f -print0 2>/dev/null | head -z -n 20)
done

# The view: one root-owned link per linked asset. Writable, the agent places a link to a tree of its own.
not_writable /opt/ai-tools/skills "create or repoint a link in the skills view"
not_writable /opt/ai-tools/subagents "create or repoint a link in the subagents view"

# The lock serializes the view transaction; an agent that held it would stall every reconcile.
not_writable /run/lock/ai-tools-assets.lock "take or truncate the view transaction's lock"

# Each enabled agent's kind directories hold root-owned links into the view inside a setgid+sticky config directory;
# which directories those are is the deployed resolver's answer, so no agent is named here.
while IFS=$'\t' read -r agent agent_dir; do
    [[ -n "${agent_dir}" ]] || continue
    not_writable "${agent_dir}" "repoint a link in ${agent}'s ${agent_dir##*/}/ at a file of its own"
done < <(bash -c 'source /usr/local/lib/ai-tools/control-plane.lib.sh 2>/dev/null || exit 0
    ai_tools_agent_asset_dirs skills_dir; ai_tools_agent_asset_dirs subagents_dir' 2>/dev/null)

# The verbs that write AI_TOOLS_ASSETS refuse a caller that is not root before they read an input.
if runuser -u "${SANDBOX_USER}" -- /usr/local/sbin/ai-tools-admin assets reconcile >/dev/null 2>&1; then
    fail "ai-tools-admin assets reconcile ran as ${SANDBOX_USER}"
else
    pass "ai-tools-admin assets reconcile is refused as ${SANDBOX_USER}"
fi

section "Asset-set signing inputs ship at the modes the verifier requires"

check_file "${LIBDIR}/assets-verify.lib.sh" root root 644
check_file "${LIBDIR}/keys" root root 755
check_file "${LIBDIR}/keys/dag-node-package-signing.asc" root root 644
check_file "${LIBDIR}/keys/dag-node-package-signing.gpg" root root 644
check_file "${BINDINGS}" root root 755
check_file "${BINDINGS}/core.conf" root root 644
check_file "${BINDINGS}/ai-tools.conf" root root 644
check_file "${LIBDIR}/assets.lib.sh" root root 644
check_file /opt/ai-tools/skills root "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/subagents root "${SANDBOX_GROUP}" 750
check_file_optional /run/lock/ai-tools-assets.lock root root 644

finish
