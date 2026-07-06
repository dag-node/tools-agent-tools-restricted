#!/usr/bin/env bash
# tests/boundary/access.sh
# Boundary: what the sandbox account can and cannot actually reach at runtime, probed AS the
# agent (runuser -u ai-tools). Each check names the threat its boundary prevents. "can"
# checks confirm access the sandbox needs to function; "cannot" checks confirm control-plane
# integrity and secret isolation. Non-destructive (test -r/-w/-x); the one unlink attempt
# targets a DECOY file (projects-user-owned, in the sticky .claude dir) so real control-plane
# files are never at risk. Run as root via sudo; drops to the agent per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Sandbox access boundaries (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "sandbox access boundaries" "runuser not available"; finish; exit
fi

# Config dir traversal: the allowlist and secret-pattern config live under
# ~/.config/ai-tools (700). If the agent could traverse it, it could read the allowlist,
# read secret-patterns to learn what triggers quarantine, or forge entries -- all via plain
# file I/O, no sudo.
confdir="${PROJECTS_HOME}/.config/ai-tools"
if ! runuser -u "${SANDBOX_USER}" -- test -x "${confdir}" 2>/dev/null; then
    pass "cannot traverse ${confdir} (700 ${PROJECTS_USER}:${PROJECTS_GROUP}): allowlist + secret config unreachable to agent"
else
    fail "can traverse ${confdir} -- agent could read/tamper with the allowlist or secret-pattern config"
fi

# The product's headline promise (README): a session "does not reach your secrets, SSH keys, or
# unrelated projects". The agent is neither the operator nor in the operator's primary group, so
# the operator's private credential stores stay out of reach by plain DAC. Probe that directly
# against the operator's real home: for each sensitive store that exists, the agent must be able
# to neither traverse it (dirs) nor read it (files). An exposure here is a real hole in the
# promise, not a product-internal detail -- so it FAILs rather than skips. Absent stores skip.
for _sec in .ssh .gnupg .aws .kube .docker/config.json .netrc .config/gh/hosts.yml; do
    _p="${PROJECTS_HOME}/${_sec}"
    [[ -e "${_p}" ]] || continue
    if [[ -d "${_p}" ]]; then
        if runuser -u "${SANDBOX_USER}" -- test -x "${_p}" 2>/dev/null; then
            fail "agent can traverse ${_p} -- operator credential store is reachable (README promise broken)"
        else
            pass "cannot traverse ${_p}: operator credential store unreachable to agent"
        fi
    else
        if runuser -u "${SANDBOX_USER}" -- test -r "${_p}" 2>/dev/null; then
            fail "agent can read ${_p} -- operator credential file is reachable (README promise broken)"
        else
            pass "cannot read ${_p}: operator credential file unreachable to agent"
        fi
    fi
done

# Secret-pattern library (640 root:root) defines what filenames trigger quarantine. The lib
# dir (750 root:ai-tools) is traversable, but the file's group is root, so traversal does not
# imply read. If readable, the agent could route secrets through a name not in the list.
splib=/usr/local/lib/ai-tools/secret-patterns.lib.sh
if ! runuser -u "${SANDBOX_USER}" -- test -r "${splib}" 2>/dev/null; then
    pass "cannot read ${splib} (640 root:root): secret classifier is opaque to the agent"
else
    fail "can read ${splib} -- agent can inspect the secret-pattern matcher and avoid triggering it"
fi

# Skip-dir library (640 root:ai-tools) is sourced by session-hook.sh while it runs AS the
# agent. Group read is intentional and required; the content is not sensitive.
skip_dirs_lib=/usr/local/lib/ai-tools/skip-dirs.lib.sh
if runuser -u "${SANDBOX_USER}" -- test -r "${skip_dirs_lib}" 2>/dev/null; then
    pass "can read ${skip_dirs_lib} (640 root:ai-tools): required by session-hook.sh at runtime"
else
    fail "cannot read ${skip_dirs_lib} -- session-hook.sh will fail to source the skip list"
fi

# /usr/local/sbin/ai-tools (750 root:root) holds the root helpers. Listing it lets the agent
# enumerate helper names and probe for discrepancies against what sudoers authorises.
sbindir=/usr/local/sbin/ai-tools
if ! runuser -u "${SANDBOX_USER}" -- test -r "${sbindir}" 2>/dev/null; then
    pass "cannot list ${sbindir} (750 root:root): helper names not enumerable by agent"
else
    fail "can list ${sbindir} -- agent can enumerate root helper names"
fi

# settings.json (640) declares the hooks and the permissions allow/deny lists. Write access
# would let the agent expand its tool scope, drop deny rules, or remove hooks -- no signal.
sf=/opt/ai-tools/.claude/settings.json
if ! runuser -u "${SANDBOX_USER}" -- test -w "${sf}" 2>/dev/null; then
    pass "cannot write ${sf} (640 no group-write): agent cannot extend its own allowed tool scope"
else
    fail "can write ${sf} -- agent could add permissions.allow rules, remove deny rules, or drop hooks"
fi

# Even without file write, a group-writer of the DIRECTORY could unlink+recreate the file.
# The sticky bit on .claude (3770) forbids that: you can only unlink a file you own OR in a
# dir you own; the agent owns neither. Tested with a DECOY (same ownership, same dir).
_decoy="$(mktemp /opt/ai-tools/.claude/.test_sticky_XXXXXX)"
chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${_decoy}"
chmod 640 "${_decoy}"
_cleanup+=("${_decoy}")
runuser -u "${SANDBOX_USER}" -- rm -f "${_decoy}" 2>/dev/null || true
if [[ -e "${_decoy}" ]]; then
    pass "sticky .claude: agent cannot unlink ${PROJECTS_USER}-owned files (replacement attack blocked)"
else
    fail "sticky .claude FAILED: agent deleted a ${PROJECTS_USER}-owned file -- settings.json and hooks can be replaced"
fi

# post-tool-hook.sh (750) fires after every Write/Edit. Overwriting it with an empty script
# would skip handback and secret quarantine for the rest of the session.
hook=/opt/ai-tools/.claude/post-tool-hook.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${hook}" 2>/dev/null; then
    pass "cannot write ${hook} (750 no group-write): hand-back and quarantine hooks protected"
else
    fail "can write ${hook} -- agent could empty the hook and disable hand-back / secret quarantine"
fi

# session-hook.sh (750) runs the Stop sweep and SessionStart reclaim. Overwriting it would
# leave agent-owned files in the tree and skip setgid normalisation.
shook=/opt/ai-tools/.claude/session-hook.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${shook}" 2>/dev/null; then
    pass "cannot write ${shook} (750 no group-write): stop-sweep and session-start protected"
else
    fail "can write ${shook} -- agent could disable the stop-sweep or session-start reclaim"
fi

# nvm-update.sh (550) is run by the daily timer AS the projects user. Injection here executes
# arbitrary commands in the projects user's context on the next timer fire -- persistent.
updater=/opt/ai-tools/bin/nvm-update.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${updater}" 2>/dev/null; then
    pass "cannot write ${updater} (550 no group-write): scheduled updater protected from code injection"
else
    fail "can write ${updater} -- agent could inject commands run as ${PROJECTS_USER} by the daily timer"
fi

# Hooks must remain agent-executable, or Claude Code silently skips them and the entire
# hand-back / quarantine system stops with no error.
if runuser -u "${SANDBOX_USER}" -- test -x "${hook}" 2>/dev/null; then
    pass "can execute ${hook} (750 group-exec): PostToolUse hook will fire"
else
    fail "cannot execute ${hook} -- hook will be silently skipped by Claude Code"
fi
if runuser -u "${SANDBOX_USER}" -- test -x "${shook}" 2>/dev/null; then
    pass "can execute ${shook} (750 group-exec): Stop and SessionStart hooks will fire"
else
    fail "cannot execute ${shook} -- stop-sweep / session-start silently skipped"
fi

# The control-plane home root is drwxr-s--- (2750 ${PROJECTS_USER}:${SANDBOX_GROUP}): the agent
# (group r-x) traverses and reads but must NOT create new top-level entries, or it could drop
# files that shadow control assets or escape its own subtrees (.nvm/.cache). Probed with a real
# create attempt; the probe is removed whether or not it (wrongly) succeeded.
_homeprobe="/opt/ai-tools/.test_homelock_$$"
runuser -u "${SANDBOX_USER}" -- touch "${_homeprobe}" 2>/dev/null || true
if [[ -e "${_homeprobe}" ]]; then
    rm -f "${_homeprobe}"
    fail "agent created ${_homeprobe} -- /opt/ai-tools is not locked (expected drwxr-s--- ${PROJECTS_USER}-owned)"
else
    pass "cannot create files in /opt/ai-tools (drwxr-s---): agent confined to its own subtrees"
fi

# The sandbox account's systemd --user manager runs unconfined (ai-tools maps to unconfined_u),
# so a --user unit the agent could drop and get enabled would run OUTSIDE the ai_tools_t session
# confinement at the next manager start -- a full confinement escape (no RestrictNamespaces, no
# ai_tools_t). The whole unit search tree (~/.config/systemd/user and its .wants dirs) is
# root-owned (root:${SANDBOX_GROUP} 2750), so the agent has group r-x but no write and can place
# neither a unit file nor an enablement symlink. Probed with real create attempts in both the
# unit dir and a .wants dir.
for _d in /opt/ai-tools/.config/systemd/user /opt/ai-tools/.config/systemd/user/timers.target.wants; do
    _unitprobe="${_d}/.test_escape_$$.unit"
    runuser -u "${SANDBOX_USER}" -- touch "${_unitprobe}" 2>/dev/null || true
    if [[ -e "${_unitprobe}" ]]; then
        rm -f "${_unitprobe}"
        fail "agent wrote ${_unitprobe} -- it could register a --user unit the unconfined manager runs (confinement escape)"
    else
        pass "cannot write ${_d} (root-owned 2750): confined session cannot register a --user unit"
    fi
done

# .claude.json is Claude Code's runtime state file, GROUP-writable but NOT agent-owned (root:ai-tools
# 0460): the agent persists its session state through the group, yet -- not being the owner -- cannot
# chmod the file to bypass the lock or repurpose it as a control-plane lever. The control plane is
# root-owned, so the load-bearing property is "not owned by the agent"; the enforced permission
# boundary is the locked settings.json (checked above), not this file. perms.sh pins the exact
# root:ai-tools 0460. Seeded by ai-tools-bootstrap; may be absent on a control-plane-only dev
# install, so the check is conditional.
cjson=/opt/ai-tools/.claude.json
if [[ -e "${cjson}" ]]; then
    if runuser -u "${SANDBOX_USER}" -- test -w "${cjson}" 2>/dev/null; then
        pass "can write ${cjson} (0460 group-write): agent persists session state across the home lock"
    else
        fail "cannot write ${cjson} -- agent cannot persist state (expected group-writable 0460)"
    fi
    cj_owner="$(stat -c %U "${cjson}")"
    if [[ "${cj_owner}" != "${SANDBOX_USER}" ]]; then
        pass "${cjson} not agent-owned (${cj_owner}): group-writes state but cannot bypass the 0460 lock"
    else
        fail "${cjson} owned by ${SANDBOX_USER} -- the agent owns its own state file (0460 lock bypassable)"
    fi
else
    skip "${cjson} state file" "absent (ai-tools-bootstrap not run / control-plane-only install)"
fi

# .gitignore (640) is the default-deny guard that keeps secrets uncommittable if the operator
# versions the control plane. Agent group-read but NOT group-write: it cannot weaken the denylist.
gi=/opt/ai-tools/.gitignore
if [[ -e "${gi}" ]] && ! runuser -u "${SANDBOX_USER}" -- test -w "${gi}" 2>/dev/null; then
    pass "cannot write ${gi} (640 no group-write): agent cannot re-include secrets into a commit"
elif [[ -e "${gi}" ]]; then
    fail "can write ${gi} -- agent could weaken the default-deny secret guard"
fi

finish
