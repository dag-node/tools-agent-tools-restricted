#!/usr/bin/env bash
# tests/boundary/providers.sh
# Boundary: the sandbox account cannot widen its own surface. Probed AS the agent
# (runuser -u ai-tools), against the DEPLOYED provider control surface.
#
# The provider seam decides two things the agent must never get a vote on: which agents the
# toolchain installs, and what environment (and PATH) a session is handed. Those decisions come
# from operator.conf, the manifests under agents.d / integrations.d, the session-env fragments
# under session-env.d, and the two libraries that read them. providers.lib.sh and ai-tools-run refuse
# any of these that is not root-owned and non-group/other-writable (unit-tested in
# tests/unit/providers.sh); this file asserts the other half -- that on a real install the agent
# cannot put any of them into that state in the first place. Both halves must hold: the runtime
# check catches a host someone has already broken, this catches the agent trying to break it.
#
# Probe-only (test -w / test -x); nothing is written, created, or unlinked. Run as root via sudo;
# drops to the agent per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Provider control surface is not agent-writable (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "provider control surface" "runuser not available"; finish; exit
fi

# not_writable <path> <what it would let the agent do>
# PASS when the agent cannot write <path>; FAIL naming the escalation it would allow. A path that
# is not deployed on this host SKIPs -- the optional integration packages are legitimately absent.
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

# The gating config. Writable, the agent names any installed provider in AI_TOOLS_INTEGRATIONS --
# including a default_enable=no one held back precisely because it widens host surface.
not_writable /etc/ai-tools/operator.conf \
    "enable a surface-widening provider its package ships disabled"

# The two libraries that make the decision, and are sourced by ai-tools-run in the session's own
# pre-launch scope. Writable, the agent rewrites the verdict -- or executes arbitrary code as the
# sandbox account before confinement is applied.
not_writable /usr/local/lib/ai-tools/conf.lib.sh \
    "rewrite the trust predicate that gates every provider input"
not_writable /usr/local/lib/ai-tools/providers.lib.sh \
    "rewrite which providers resolve as enabled"

# The library that turns a manifest's declared entrypoint pattern into a `semanage fcontext`
# rule. It pins the type (ai_tools_exec_t) and the containment check on the pattern, so writable
# it would let the agent label a file of its choosing as an entrypoint of the confined domain --
# or as anything else.
not_writable /usr/local/lib/ai-tools/relabel.lib.sh \
    "label a file of its choosing as an entrypoint of the confined domain"

# The root helper that writes the launcher symlinks. It is reachable from a session through the
# handback SYMLINK verb, so its argument validation and manifest allowlist are the only things
# bounding what it will link; writable, the agent would rewrite both.
not_writable /usr/local/sbin/ai-tools/ai-tools-launcher-symlink \
    "rewrite the validation that bounds which launcher symlinks it can write"

# The three provider directories. A group- or other-writable directory is as good as a writable
# file: a non-root writer can unlink a root-owned manifest and put its own in that name.
not_writable /usr/local/lib/ai-tools/agents.d \
    "plant a manifest that provisions an npm package of its choosing"
not_writable /usr/local/lib/ai-tools/integrations.d \
    "plant a manifest that enables an integration by default"
not_writable /usr/local/lib/ai-tools/session-env.d \
    "plant a session-env fragment ai-tools-run would source"

# The shipped manifests and fragment themselves.
not_writable /usr/local/lib/ai-tools/agents.d/claude-code.conf \
    "repoint the agent package the toolchain installs"
not_writable /usr/local/lib/ai-tools/integrations.d/dotnet.conf \
    "flip the dotnet integration to enabled-by-default"
not_writable /usr/local/lib/ai-tools/session-env.d/dotnet.env.sh \
    "inject environment and PATH into its own session"
not_writable /usr/local/lib/ai-tools/session-env.d/claude-code.env.sh \
    "repoint its own config directory or re-enable the in-session updater"

# The shared asset roots. Every agent symlinks into these two places, so a writable root here
# would let one session rewrite the standing instructions -- or the delegate definitions -- that
# every agent and every later session reads. The runtime half (their modes) is asserted in
# integration/perms.sh.
not_writable /opt/ai-tools/skills \
    "rewrite the standing instructions every agent and every later session reads"
not_writable /opt/ai-tools/subagents \
    "rewrite the subagent definitions every agent and every later session delegates to"

# The confinement shim itself. It is the sudoers target: writable, the agent would be executing
# its own code under the operators' NOPASSWD grant, with the unit properties of its choosing.
not_writable /opt/ai-tools/bin/ai-tools-run \
    "rewrite the confinement properties every session is launched with"
not_writable /opt/ai-tools/bin \
    "replace the confinement shim or the launcher symlink the wrapper resolves"

# The integration state root itself: base-owned, one directory per integration inside it. A
# writable root would let the agent create or replace an integration's whole state tree.
not_writable /opt/ai-tools/integrations \
    "create or replace an integration's entire state tree"

# The dotnet integration's split of its own state: shared tools READ-ONLY (only the sudo helper
# writes them), the NuGet restore cache WRITABLE (the agent restores into it every build). Both
# halves are asserted -- a read-only cache breaks the integration just as surely as a writable
# tools dir breaks the boundary. Absent until `sudo ai-tools-dotnet setup` has run.
not_writable /opt/ai-tools/integrations/dotnet/tools \
    "put an executable of its own on the session PATH"

_nuget=/opt/ai-tools/integrations/dotnet/nuget/packages
if [[ ! -e "${_nuget}" ]]; then
    skip "${_nuget}" "not deployed on this host"
elif runuser -u "${SANDBOX_USER}" -- test -w "${_nuget}" 2>/dev/null; then
    pass "can write ${_nuget}: the NuGet restore cache stays agent-writable, as the integration needs"
else
    fail "agent cannot write ${_nuget} -- dotnet restore has nowhere to land and every build fails"
fi

finish
