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
# dir (0751 root:ai-tools) is traversable, but the file's group is root, so traversal does not
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

# Claude Code persists its state (.claude.json under CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude)
# atomically -- a temp file beside the target, then rename -- so persistence needs create+rename
# in the CONTAINING DIR, not write on the file. .claude (root:ai-tools 3770) grants the agent
# exactly that through the group bits, while the sticky bit keeps the root-owned control files
# undeletable (the settings.json lock is checked above). A regression here fails every state
# save silently: login and onboarding state are lost and each session demands a fresh token.
_state_tmp="/opt/ai-tools/.claude/.test_state_$$.tmp"
_state_dst="/opt/ai-tools/.claude/.test_state_$$.json"
if runuser -u "${SANDBOX_USER}" -- \
       bash -c "printf '{}\n' > '${_state_tmp}' && mv -- '${_state_tmp}' '${_state_dst}'" 2>/dev/null \
   && [[ -e "${_state_dst}" ]]; then
    pass "agent can create+rename under /opt/ai-tools/.claude: atomic state saves (.claude.json) persist"
else
    fail "agent cannot create+rename under /opt/ai-tools/.claude -- state saves fail, login is lost each session"
fi
rm -f "${_state_tmp}" "${_state_dst}"

# .gitignore (640) is the default-deny guard that keeps secrets uncommittable if the operator
# versions the control plane. Agent group-read but NOT group-write: it cannot weaken the denylist.
gi=/opt/ai-tools/.gitignore
if [[ -e "${gi}" ]] && ! runuser -u "${SANDBOX_USER}" -- test -w "${gi}" 2>/dev/null; then
    pass "cannot write ${gi} (640 no group-write): agent cannot re-include secrets into a commit"
elif [[ -e "${gi}" ]]; then
    fail "can write ${gi} -- agent could weaken the default-deny secret guard"
fi

# /opt/ai-tools is deliberately NOT a nosuid mount (the sudo UID-switch to the sandbox account
# needs suid to take effect there -- see launch.rule.md), and the agent owns its toolchain tree
# (.nvm). A suid/sgid binary born under an agent-owned, non-nosuid path would be a standing
# escalation primitive. The toolchain the updater installs carries none today; assert it stays
# that way. Scoped to the agent-owned trees to keep the walk cheap and the finding meaningful.
suid_hits=""
for _tree in /opt/ai-tools/.nvm /opt/ai-tools/.cache; do
    [[ -d "${_tree}" ]] || continue
    _found="$(find "${_tree}" -xdev -type f -perm /06000 2>/dev/null || true)"
    [[ -n "${_found}" ]] && suid_hits+="${_found}"$'\n'
done
if [[ -z "${suid_hits//[$'\n\t ']/}" ]]; then
    pass "no suid/sgid files under the agent-owned toolchain trees (.nvm/.cache on a non-nosuid mount)"
else
    fail "suid/sgid file(s) under agent-owned trees -- escalation primitive on /opt (non-nosuid): ${suid_hits//$'\n'/ }"
fi

finish
