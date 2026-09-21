#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/typesafe.sh
# Boundary: the typesafe integration's call path is not agent-writable, and its credential stays off the world. Probed
# AS the agent (`runuser -u ai-tools`) against the DEPLOYED files (typesafe.rule.md).
#
# What the agent must not get a vote on: the credential file (which key is sent, and to which host), the decide command
# and the transport it calls (what leaves the host, and where a result comes from), and the manifest and fragment
# tests/boundary/providers.sh covers with every other provider's. The command refuses a world-readable or world-writable
# file (tests/unit/typesafe-client.sh drives that); this file asserts the other half -- that on a real install
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

section "typesafe: credential, command, and state root, probed as the agent (boundary)"

if ! command -v runuser >/dev/null; then
    skip "typesafe boundary" "runuser not available"; finish; exit
fi

CONF=/etc/ai-tools/endpoints/typesafe.conf
LIB=/usr/local/lib/ai-tools/typesafe
STATE=/opt/ai-tools/integrations/typesafe

as_agent() { runuser -u "${SANDBOX_USER}" -- "$@" 2>/dev/null; }

not_writable() {
    local path="$1" consequence="$2"
    if [[ ! -e "${path}" ]]; then
        skip "${path}" "not deployed on this host"; return
    fi
    if as_agent test -w "${path}"; then
        fail "agent can write ${path} -- it could ${consequence}"
    else
        pass "cannot write ${path}: agent cannot ${consequence}"
    fi
}

# The credential file: readable by the sandbox account (the command runs as it), not writable by it, and not readable
# by other -- the mode the package installs and the command re-checks at every call.
if [[ ! -e "${CONF}" ]]; then
    skip "${CONF}" "not deployed on this host"
else
    if as_agent test -r "${CONF}"; then
        pass "can read ${CONF}: the command reads the key as the sandbox account"
    else
        fail "agent cannot read ${CONF} -- every call refuses with the configuration status"
    fi
    not_writable "${CONF}" "swap the key or point the call at another host"
    mode="$(stat -c '%a' "${CONF}")"
    if (( (8#${mode} & 8#006) == 0 )); then
        pass "${CONF} is ${mode}: not readable or writable by other"
    else
        fail "${CONF} is ${mode}: readable or writable by other, and the command refuses such a file"
    fi
fi

# The command: what runs on every call, root-owned so a session cannot change what leaves the host or fabricate
# a result. transport.mjs is the file that decides where a request goes and what a body is trusted to carry.
not_writable "${LIB}" "replace the decide command"
not_writable "${LIB}/decide.mjs" "change what a call sends or prints"
not_writable "${LIB}/transport.mjs" "change where a request goes, or what an answer is held to"

# The state root: the one path a call writes (usage.log). Absent until the package is installed.
if [[ ! -e "${STATE}" ]]; then
    skip "${STATE}" "not deployed on this host"
elif as_agent test -w "${STATE}"; then
    pass "can write ${STATE}: the usage log has somewhere to land"
else
    fail "agent cannot write ${STATE} -- every call loses its usage line"
fi

finish
