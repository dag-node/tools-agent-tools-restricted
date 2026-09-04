#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/filters.sh
# Boundary: the agent cannot decide what its own commands become. Probed AS the agent
# (runuser -u ai-tools), against the DEPLOYED filter surface.
#
# Command filtering is token economy, not a boundary -- but the inputs that drive it are still
# control plane. A rules file the agent could write would silently reshape every command a
# session runs (and the transcript the operator reads), and the hook that applies them runs as
# the agent on every Bash call. filters.lib.sh refuses a rules file or directory that is not
# root-owned and non-group/other-writable (unit-tested in tests/unit/filters.sh); this file
# asserts the other half -- that on a real install the agent cannot put any of them into that
# state in the first place. Both halves must hold: the runtime check catches a host someone has
# already broken, this catches the agent trying to break it.
#
# Probe-only (test -w); no file is written, created, or unlinked. Run as root via sudo; drops to
# the agent per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Command-filter surface is not agent-writable (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "command-filter surface" "runuser not available"; finish; exit
fi

# not_writable <path> <what it would let the agent do>
# PASS when the agent cannot write <path>; FAIL naming the consequence it would allow. A path not
# deployed on this host SKIPs -- the optional integration packages are legitimately absent.
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

# The engine. It runs as the agent, in the agent's own process, on every Bash call -- so writable
# it is not a filter rule the agent gains but arbitrary code on the hot path of every command.
not_writable /usr/local/lib/ai-tools/filters.lib.sh \
    "rewrite the engine that decides what every command in its session becomes"

# The rule-set directory. A group- or other-writable directory is as good as a writable file: a
# non-root writer can unlink a root-owned rule set and put its own in that name.
not_writable /usr/local/lib/ai-tools/filters.d \
    "plant a rule set that rewrites commands as it chooses"

# The shipped rule sets themselves.
not_writable /usr/local/lib/ai-tools/filters.d/core.rules \
    "rewrite the base rules every session applies"
not_writable /usr/local/lib/ai-tools/filters.d/dotnet.rules \
    "rewrite the rules applied to every dotnet command"

# The operator's switch. Writable, the agent selects which rule sets apply -- or turns filtering
# off so a rules file an operator relies on stops being applied.
not_writable /etc/ai-tools/operator.conf \
    "choose which rule sets its own session applies"

# The agent-side adapter, in the agent's own control-plane directory. Its directory is setgid
# +sticky, so the agent is a group-writer there for its session state yet cannot unlink or
# replace a root-owned file it does not own -- the property this check pins from the outside.
not_writable /opt/ai-tools/.claude/filter-hook.sh \
    "replace the hook body Claude Code executes before and after every Bash command"

finish
