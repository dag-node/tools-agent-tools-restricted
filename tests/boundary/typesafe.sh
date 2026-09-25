#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/typesafe.sh
# Boundary: the typesafe integration's call path is not agent-writable, and its credential stays off the world. Probed
# AS the agent (`runuser -u ai-tools`) against the DEPLOYED files (typesafe.rule.md).
#
# What the agent must not get a vote on: the credential file (which key is sent, and to which host), the decide command
# and the transport it calls (what leaves the host, and where a result comes from), and the manifest and fragment
# tests/boundary/providers.sh covers with every other provider's. The command refuses a world-readable or world-writable
# file (the suite of its source repository drives that); this file asserts the other half -- that on a real install
# the shipped file is not in that state and the agent has no write on it to put it there. The one path the agent MUST
# write is the state root, where the usage log lands; a read-only root costs the log and not the result, so that is
# asserted as writable.
#
# Probe-only (`test -r` / `test -w` and a stat); no file is written, created, or unlinked. Run as root via sudo; drops
# to the agent per check. Every path SKIPs where the package is not installed.

set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "typesafe: credential, command, and state root, probed as the agent"

if ! command -v runuser >/dev/null; then
    skip "typesafe boundary" "runuser not available"; finish; exit
fi

CONF=/etc/ai-tools/endpoints/typesafe.conf
LIB=/usr/local/lib/ai-tools/typesafe
STATE=/opt/ai-tools/integrations/typesafe

as_agent() { runuser -u "${SANDBOX_USER}" -- "$@" 2>/dev/null; }

# The credential file: readable by the sandbox account (the command runs as it), not writable by it, and not readable
# by other -- the mode the package installs and the command re-checks at every call. One PASS for the file, one FAIL
# per property it breaks.
if [[ ! -e "${CONF}" ]]; then
    skip "${CONF}" "not deployed on this host"
else
    mode="$(stat -c '%a' "${CONF}")"
    conf_ok=1
    if ! as_agent test -r "${CONF}"; then
        fail "agent cannot read ${CONF} -- every call refuses with the configuration status"; conf_ok=0
    fi
    if as_agent test -w "${CONF}"; then
        fail "agent can write ${CONF} -- it could swap the key or point the call at another host"; conf_ok=0
    fi
    if (( (8#${mode} & 8#006) != 0 )); then
        fail "${CONF} is ${mode}: readable or writable by other, and the command refuses such a file"; conf_ok=0
    fi
    if (( conf_ok )); then
        pass "${CONF} (${mode}): the agent reads it and cannot write it"
    fi
fi

# The command: what runs on every call, root-owned so a session cannot change what leaves the host or fabricate
# a result. transport.mjs is the file that decides where a request goes and what a body is trusted to carry. The
# directory and every module a call imports are checked; one PASS covers them, one FAIL names each writable path.
if [[ ! -e "${LIB}" ]]; then
    skip "${LIB}" "not deployed on this host"
else
    module_count=0
    writable=()
    for path in "${LIB}" "${LIB}"/*.mjs; do
        [[ -e "${path}" ]] || continue
        [[ "${path}" == "${LIB}" ]] || module_count=$(( module_count + 1 ))
        if as_agent test -w "${path}"; then
            writable+=("${path}")
        fi
    done
    for path in "${writable[@]}"; do
        fail "agent can write ${path} -- it could change what a call sends, where it goes, or what an answer is held to"
    done
    if (( ${#writable[@]} == 0 )); then
        pass "${LIB} and its ${module_count} modules: not writable by the agent"
    fi
fi

# The state root: the one path a call writes (usage.log). Absent until the package is installed.
if [[ ! -e "${STATE}" ]]; then
    skip "${STATE}" "not deployed on this host"
elif as_agent test -w "${STATE}"; then
    pass "${STATE}: writable by the agent, for the usage log"
else
    fail "agent cannot write ${STATE} -- every call loses its usage line"
fi

finish
