#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/providers.sh
# Boundary: the sandbox account cannot widen its own surface. Probed AS the agent (`runuser -u ai-tools`),
# against the DEPLOYED provider control surface.
#
# The provider seam decides two things the agent must never get a vote on: which agents the toolchain installs,
# and what environment (and PATH) a session is handed. Those decisions come from operator.conf, the manifests
# under agents.d / integrations.d, the session-env fragments under session-env.d, and the two libraries that read them.
# providers.lib.sh and ai-tools-run refuse any of these that is not root-owned and non-group/other-writable (unit-tested
# in tests/unit/providers.sh); this file asserts the other half -- that on a real install the agent cannot put any
# of them into that state in the first place. Both halves must hold: the runtime check catches a host someone has
# already broken, this catches the agent trying to break it.
#
# Probe-only (`test -w` / `test -x`); no file is written, created, or unlinked. Run as root via sudo; drops to the agent
# per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Provider control surface is not agent-writable (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "provider control surface" "runuser not available"; finish; exit
fi

# not_writable <path> <what it would let the agent do> PASS when the agent cannot write <path>; FAIL naming
# the escalation it would allow. A path that is not deployed on this host SKIPs -- the optional integration packages are
# legitimately absent.
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

# The gating config. Writable, the agent names any installed provider in AI_TOOLS_INTEGRATIONS -- including
# a default_enable=no one held back precisely because it widens host surface.
not_writable /etc/ai-tools/operator.conf \
    "enable a surface-widening provider its package ships disabled"

# The two libraries that make the decision, and are sourced by ai-tools-run in the session's own pre-launch scope.
# Writable, the agent rewrites the verdict -- or executes arbitrary code as the sandbox account before confinement is
# applied.
not_writable /usr/local/lib/ai-tools/conf.lib.sh \
    "rewrite the trust predicate that gates every provider input"
not_writable /usr/local/lib/ai-tools/providers.lib.sh \
    "rewrite which providers resolve as enabled"

# The library that reads the toolchain for a disabled agent's package and refuses every launch on it, sourced
# by the wrapper as the operator and by ai-tools-run as the sandbox account. Writable, the agent rewrites the reader
# to pass residue as clean -- or the writer to remove an enabled agent's package.
not_writable /usr/local/lib/ai-tools/toolchain.lib.sh \
    "pass a disabled agent's package as clean, or remove an enabled agent's"

# The library every agent's launch wrapper sources as the operator for the gates a launch passes: the operator gate,
# the launcher resolution, the allowlist and the claim guard. Writable, the agent rewrites what the wrapper accepts
# before the drop -- ai-tools-run re-validates the executable, but the allowlist and the claim guard are decided here.
not_writable /usr/local/lib/ai-tools/launch-wrapper.lib.sh \
    "rewrite the gates every launch wrapper runs before dropping to the sandbox account"

# The library that turns a manifest's declared entrypoint pattern into a `semanage fcontext` rule. It pins the type
# (ai_tools_exec_t) and the containment check on the pattern, so writable it would let the agent label a file of its
# choosing as an entrypoint of the confined domain -- or as anything else.
not_writable /usr/local/lib/ai-tools/relabel.lib.sh \
    "label a file of its choosing as an entrypoint of the confined domain"

# The root helper that writes the launcher symlinks. It is reachable from a session through the handback SYMLINK verb,
# so its argument validation and manifest allowlist are the only things bounding what it will link; writable, the agent
# would rewrite both.
not_writable /usr/local/libexec/ai-tools/ai-tools-launcher-symlink \
    "rewrite the validation that bounds which launcher symlinks it can write"

# The three provider directories. A group- or other-writable directory is as good as a writable file: a non-root writer
# can unlink a root-owned manifest and put its own in that name.
not_writable /usr/local/lib/ai-tools/agents.d \
    "plant a manifest that provisions an npm package of its choosing"
not_writable /usr/local/lib/ai-tools/integrations.d \
    "plant a manifest that enables an integration by default"
not_writable /usr/local/lib/ai-tools/session-env.d \
    "plant a session-env fragment ai-tools-run would source"

# The contributed-command directory carries the same reasoning at the highest privilege in this file: ai-tools-admin
# execs what it finds here AS ROOT. Writable, the agent would not be widening its own session -- it would be writing
# a command an administrator runs as root. Its fragments are 0750 root:root, so the agent cannot read one either;
# what it may see is the domain names, which `ai-tools-admin --help` prints to any caller.
not_writable /usr/local/lib/ai-tools/admin-commands.d \
    "plant a command ai-tools-admin would exec as root"
not_writable /usr/local/lib/ai-tools/admin-commands.d/dotnet \
    "rewrite a command ai-tools-admin execs as root"

# The shipped manifests and fragment themselves.
not_writable /usr/local/lib/ai-tools/agents.d/claude-code.conf \
    "repoint the agent package the toolchain installs"
not_writable /usr/local/lib/ai-tools/integrations.d/dotnet.conf \
    "flip the dotnet integration to enabled-by-default"
not_writable /usr/local/lib/ai-tools/session-env.d/dotnet.env.sh \
    "inject environment and PATH into its own session"
not_writable /usr/local/lib/ai-tools/integrations.d/typesafe.conf \
    "flip the typesafe integration to enabled-by-default"
not_writable /usr/local/lib/ai-tools/session-env.d/typesafe.env.sh \
    "point the decide command at a credential file of its own"
not_writable /usr/local/lib/ai-tools/session-env.d/claude-code.pins.env.sh \
    "repoint its own config directory or re-enable the in-session updater"
# The pins reach every session of the account and the fragment reaches claude-code sessions alone; writable,
# the fragment is where a session of another agent would put the line that imports the claude endpoint token.
not_writable /usr/local/lib/ai-tools/session-env.d/claude-code.env.sh \
    "route the claude endpoint and its token into every agent's sessions"
# The codex package's manifest and pins, the same two decisions for the second agent. The manifest ships
# default_enable=no, so writable it would be the file the agent flips to enable itself.
not_writable /usr/local/lib/ai-tools/agents.d/codex.conf \
    "enable itself by default, or repoint the codex package the toolchain installs"
not_writable /usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh \
    "repoint CODEX_HOME at a directory it controls"

# Codex's managed files, read by codex at every start from a fixed path. No file under /etc/codex holds a guarantee --
# the session runs as the sandbox account in the confined domain whatever codex reads -- so what a writer there changes
# is what the package OWNS: the hook declarations that hand files back per turn and the pin that keeps codex from adding
# a sandbox of its own. Root-owned control-plane data stays root-written, like settings.json.
not_writable /etc/codex \
    "replace the managed files codex reads at every start"
not_writable /etc/codex/requirements.toml \
    "rewrite the pin and the hook declarations codex enforces on its own session"
not_writable /etc/codex/managed_config.toml \
    "rewrite the defaults codex reapplies at every start"

# The shared asset roots. Every agent symlinks into these two places, so a writable root here would let one session
# rewrite the standing instructions -- or the delegate definitions -- that every agent and every later session reads.
# The runtime half (their modes) is asserted in
# integration/perms.sh.
not_writable /opt/ai-tools/skills \
    "rewrite the standing instructions every agent and every later session reads"
not_writable /opt/ai-tools/subagents \
    "rewrite the subagent definitions every agent and every later session delegates to"

# The confinement shim itself. It is the sudoers target: writable, the agent would be executing its own code
# under the operators' NOPASSWD grant, with the unit properties of its choosing.
not_writable /opt/ai-tools/bin/ai-tools-run \
    "rewrite the confinement properties every session is launched with"
not_writable /opt/ai-tools/bin \
    "replace the confinement shim or the launcher symlink the wrapper resolves"

# The launch WRAPPERS, and they are the one cross-principal escalation in this chain: each runs AS THE OPERATOR
# who typed the launcher name, before any drop to the sandbox account. A writable wrapper is the agent's code executed
# with that operator's identity, credentials and home -- everything the confinement exists to keep it away from --
# so the modes in integration/perms.sh are not the only place this is asserted; here it is probed from the vantage
# of the account that would have to write one.
not_writable /usr/local/bin/claude \
    "run its own code as the operator, before any session is confined"
not_writable /usr/local/bin/codex \
    "run its own code as the operator, before any session is confined"

# The two libraries every wrapper loads fail-closed, sourced in that same operator-owned process. safe-paths carries
# the protected-paths backstop and msg carries the yes/no decisions, so either one writable is both a refusal the agent
# can remove and code it can place in the operator's shell.
not_writable /usr/local/lib/ai-tools/launch-wrapper.lib.sh \
    "rewrite the gates every wrapper runs, in a process owned by the operator"
not_writable /usr/local/lib/ai-tools/safe-paths.lib.sh \
    "remove the protected-paths backstop from every caller that loads it"
not_writable /usr/local/lib/ai-tools/msg.lib.sh \
    "answer the confirmations an operator is asked, in their own process"

# The integration state root itself: base-owned, one directory per integration inside it. A writable root would let
# the agent create or replace an integration's whole state tree.
not_writable /opt/ai-tools/integrations \
    "create or replace an integration's entire state tree"

# The dotnet integration's split of its own state: shared tools READ-ONLY (only the root command writes them), the NuGet
# restore cache WRITABLE (the agent restores into it every build). Both halves are asserted -- a read-only cache breaks
# the integration just as surely as a writable tools dir breaks the boundary. Absent until
# `sudo ai-tools-admin dotnet bootstrap` has run.
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
