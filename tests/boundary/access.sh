#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/boundary/access.sh
# Boundary: what the sandbox account can and cannot actually reach at runtime, probed AS the
# agent (runuser -u ai-tools). Each check names the threat its boundary prevents. "can"
# checks confirm access the sandbox needs to function; "cannot" checks confirm control-plane
# integrity and secret isolation. Probe-only (test -r/-w/-x); the one unlink attempt
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

# /usr/local/libexec/ai-tools (750 root:root) holds the root helpers. Listing it lets the agent
# enumerate helper names and probe for discrepancies against what sudoers authorises.
sbindir=/usr/local/libexec/ai-tools
if ! runuser -u "${SANDBOX_USER}" -- test -r "${sbindir}" 2>/dev/null; then
    pass "cannot list ${sbindir} (750 root:root): helper names not enumerable by agent"
else
    fail "can list ${sbindir} -- agent can enumerate root helper names"
fi

# The boundary half of ai-tools-unclaim --unlisted (see unit/unclaim.sh for the runtime half).
# That mode acts outside the allowlist, bounded instead by the operator identity it resolves from
# SUDO_UID plus OPERATORS. Both inputs must be out of the agent's reach, or it could aim a root
# permission rewrite at a tree of its choosing: the helper itself is unreadable (above), and the
# operator roster is not agent-writable. The third input, sudo, the agent does not hold at all
# (boundary/sudo.sh).
opconf=/etc/ai-tools/operator.conf
if ! runuser -u "${SANDBOX_USER}" -- test -w "${opconf}" 2>/dev/null; then
    pass "cannot write ${opconf}: agent cannot enroll an identity for ai-tools-unclaim --unlisted"
else
    fail "can write ${opconf} -- agent could add itself to OPERATORS"
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

# Custom system prompt / custom endpoint: the agent-side half of "the sandbox cannot widen its own
# surface" (the runtime refusal is unit/claude-prompt.sh + unit/claude-endpoint.sh). The enforced
# property is PERSISTENCE, not a running session's own environment: the prompt/endpoint config is
# operator configuration delivered at launch, and a session altering its OWN process env cannot
# repoint the already-started Claude Code client (it reads ANTHROPIC_BASE_URL at startup; a Bash-tool
# child's export does not reach the parent) -- and arbitrary egress is a network-policy matter, not
# this variable. What matters here is that the agent cannot WRITE these root-owned inputs: it cannot
# change what any session is launched with, cannot plant an untrusted file the resolver would honour,
# and cannot swap the auth token other sessions use. The resolvers honour these inputs only while
# root owns them and they are not group/other-writable, so we prove the agent cannot reach that
# writable state. The endpoint file is group-READABLE (the fragment reads it), so this asserts write
# specifically. Each is skipped when absent (a partial install).
for _cc in \
    /usr/local/lib/ai-tools/claude-prompt.lib.sh \
    /usr/local/lib/ai-tools/claude-endpoint.lib.sh \
    /etc/ai-tools/prompts \
    /etc/ai-tools/prompts/claude-system-prompt.md \
    /etc/ai-tools/endpoints \
    /etc/ai-tools/endpoints/custom-claude-endpoint.conf; do
    if [[ ! -e "${_cc}" ]]; then
        skip "custom prompt/endpoint write boundary" "${_cc} not installed"
    elif ! runuser -u "${SANDBOX_USER}" -- test -w "${_cc}" 2>/dev/null; then
        pass "cannot write ${_cc}: agent cannot change what sessions launch with or swap the token"
    else
        fail "can write ${_cc} -- agent could change the launch-time system prompt, endpoint URL, or auth token"
    fi
done

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

# ── The seal, from the agent's side ──────────────────────────────────────────────────────────
# The boundary half of the owner-only guarantee (unit/owner-only.sh and unit/{setgid,lockdown}.sh
# are the runtime half). Two things have to hold, and neither follows from the other.
#
# First, the agent cannot reach a sealed path. A stripped 0700 directory is what an operator is
# left with after `chmod 700` inside a claimed tree, and the point of removing the inherited
# group/setgid/ACL is that the mode is then the only thing standing -- so assert it stands, from
# the account it exists to stop. The parent is deliberately traversable, or it would be what
# denies access and the assertion would prove nothing.
mktestdir
sealed="${TESTDIR}/sealed"
mkdir -p "${sealed}"
: > "${sealed}/inside"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${sealed}"
chmod 700 "${sealed}"
chmod 600 "${sealed}/inside"
chmod 755 "${TESTDIR}"
if runuser -u "${SANDBOX_USER}" -- test -x "${sealed}" 2>/dev/null; then
    fail "the agent can traverse a sealed 0700 directory -- the seal is not a boundary"
elif runuser -u "${SANDBOX_USER}" -- test -r "${sealed}/inside" 2>/dev/null; then
    fail "the agent can read a file inside a sealed 0700 directory"
else
    pass "the agent cannot enter a sealed 0700 directory or read what is inside it"
fi

# Second, the agent cannot reach the code that decides what sealing means. owner-only.lib.sh
# carries the predicate every claim walk gates on and the strip that removes the sandbox's own
# residue; were it agent-writable, the agent could make its own group read as "not residue" and
# have the next claim leave the grant standing. Same standing as secret-patterns.lib.sh above.
oolib=/usr/local/lib/ai-tools/owner-only.lib.sh
if [[ ! -e "${oolib}" ]]; then
    skip "owner-only library not agent-writable" "not installed at ${oolib}"
elif runuser -u "${SANDBOX_USER}" -- test -w "${oolib}" 2>/dev/null; then
    fail "the agent can write ${oolib} -- it could redefine which paths count as sealed"
else
    pass "the agent cannot write owner-only.lib.sh (the seal predicate and residue strip)"
fi

# ai-tools-allowlist edits an operator's allowed-projects -- the launch gate deciding where a
# session may start. Reaching it would let the agent approve its own projects, so this is the
# boundary half of the pair whose runtime half (each of the helper's gates fires) is in
# tests/unit/allowlist-helper.sh. The helper is 750 root:root inside a 750 root:root directory and
# the sandbox account holds no sudo rule, so it is unreachable three ways over; assert the two the
# filesystem can show.
alhelper=/usr/local/libexec/ai-tools/ai-tools-allowlist
if [[ ! -e "${alhelper}" ]]; then
    skip "cross-operator allowlist helper not agent-reachable" "not installed at ${alhelper}"
elif runuser -u "${SANDBOX_USER}" -- test -x "${alhelper}" 2>/dev/null; then
    fail "the agent can execute ${alhelper} -- it could write its own launch gate"
elif runuser -u "${SANDBOX_USER}" -- test -w "${alhelper}" 2>/dev/null; then
    fail "the agent can write ${alhelper} -- it could rewrite the registry helper"
else
    pass "the agent cannot execute or write ai-tools-allowlist (the cross-operator launch gate)"
fi

# The gate itself: an operator's allowed-projects. The agent must not be able to add a project to
# any operator's registry -- with or without the helper. The primary operator's is the one this
# host is guaranteed to have.
opallow="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
if [[ ! -e "${opallow}" ]]; then
    skip "operator allowlist not agent-writable" "not present at ${opallow}"
elif runuser -u "${SANDBOX_USER}" -- test -w "${opallow}" 2>/dev/null; then
    fail "the agent can write ${opallow} -- it could approve its own projects"
else
    pass "the agent cannot write the operator's allowed-projects (its own launch gate)"
fi

# ── Entrypoint verification: the agent must not be able to bless its own binary ───────────────
# The pin is only worth comparing against while the account it constrains cannot write it -- nor
# the key that decided what went into it. Probed rather than inferred from modes, so an ACL that
# contradicts a correct-looking mode still fails.
for _ev_path in /var/opt/ai-tools/state/entrypoint-pin.d \
                /usr/local/lib/ai-tools/keys \
                /usr/local/lib/ai-tools/keys/claude-code.asc \
                /usr/local/lib/ai-tools/entrypoint-verify.lib.sh; do
    if [[ ! -e "${_ev_path}" ]]; then
        skip "entrypoint verification not agent-writable" "${_ev_path} not installed"
    elif runuser -u "${SANDBOX_USER}" -- test -w "${_ev_path}" 2>/dev/null; then
        fail "the agent can write ${_ev_path} -- it could record or authorise a checksum for a binary it modified, defeating the launch-time verification"
    else
        pass "the agent cannot write ${_ev_path}"
    fi
done

# The pin directory's contents, specifically: a directory the agent cannot write is only half the
# guarantee if an existing pin inside it is writable (or is a symlink it can redirect).
_ev_pin=/var/opt/ai-tools/state/entrypoint-pin.d/claude-code
if [[ ! -e "${_ev_pin}" ]]; then
    skip "entrypoint pin not agent-writable" "no pin recorded yet at ${_ev_pin}"
elif [[ -L "${_ev_pin}" ]]; then
    fail "${_ev_pin} is a symlink -- the pin reader refuses one, but its presence means something other than the root helper wrote there"
elif runuser -u "${SANDBOX_USER}" -- test -w "${_ev_pin}" 2>/dev/null; then
    fail "the agent can write ${_ev_pin} -- it could pin the checksum of a binary it tampered with"
else
    pass "the agent cannot write its own entrypoint pin"
fi

# ── journald attribution: a tag is not an attribution, _UID is ───────────────────────────────
# Every documented journal query pairs a syslog tag with the uid of that tag's legitimate writer
# (.claude/rules/logging.rule.md). This is the reason, probed rather than asserted from the
# design: the agent can write /dev/log under ANY tag, including a root helper's, so a tag-only
# query is poisonable by the very account it reports on. Emit a line AS the agent under
# ai-tools-chown's tag, then check both directions -- it must appear under the sandbox uid (the
# forgery does reach the trail, so the uid is load-bearing rather than ceremony) and must NOT
# appear under _UID=0 (the documented form excludes it). The probe line names itself as a test so
# a later reader of the real trail is not misled by it. A host with no journald skips: absence of
# the line proves nothing either way.
if ! command -v logger >/dev/null || ! command -v journalctl >/dev/null; then
    skip "journald _UID attribution" "logger or journalctl not available"
else
    _sbx_uid="$(id -u "${SANDBOX_USER}")"
    runuser -u "${SANDBOX_USER}" -- logger -t ai-tools-chown \
        "boundary-test forged-tag probe pid=$$ (test line, NOT a handback)" 2>/dev/null || true
    journalctl --sync >/dev/null 2>&1 || true
    _as_agent=0
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        _as_agent="$(journalctl -t ai-tools-chown _UID="${_sbx_uid}" --since '2 min ago' \
                        --no-pager 2>/dev/null | grep -cF "forged-tag probe pid=$$" || true)"
        [[ "${_as_agent}" != 0 ]] && break
        sleep 0.5
    done
    _as_root="$(journalctl -t ai-tools-chown _UID=0 --since '2 min ago' \
                    --no-pager 2>/dev/null | grep -cF "forged-tag probe pid=$$" || true)"
    if [[ "${_as_agent}" == 0 ]]; then
        skip "journald _UID attribution" "the agent's probe line never reached the journal (journald unavailable here)"
    elif [[ "${_as_root}" != 0 ]]; then
        fail "an agent-written line under the ai-tools-chown tag is returned by the _UID=0 query -- the documented query form does not separate a forged line from the root helper's own"
    else
        pass "an agent-written ai-tools-chown line files under uid ${_sbx_uid}, never _UID=0: '-t <tag> _UID=<writer>' separates a forged line from the helper's own"
    fi
fi

# ── the trail is append-only to the agent ────────────────────────────────────────────────────
# The tool-call record's whole value rests on one asymmetry: the agent WRITES the trail (the
# hooks run as the sandbox account, so it must be able to) but cannot go back and remove a line
# it would rather an operator did not read. That is what makes journald a usable sink for a
# record of the agent's own actions, where the session transcript -- which the agent owns -- is
# not. Probe the two ways a line could be unmade: the journal's own storage, and journalctl's
# destructive verbs. Both are DAC facts, which is what this vantage sees.
_journal_dir=/var/log/journal
if [[ ! -d "${_journal_dir}" ]]; then
    skip "journal is append-only to the agent" "no persistent journal at ${_journal_dir}"
else
    _breach=""
    # The storage directory must not accept a new file, and no journal file may be writable.
    if _probe="$(runuser -u "${SANDBOX_USER}" -- \
            mktemp "${_journal_dir}/.ai-tools-probe-XXXXXX" 2>/dev/null)"; then
        _breach="the agent created ${_probe} -- journal storage is agent-writable"
        rm -f -- "${_probe}"
    else
        while IFS= read -r _jf; do
            if runuser -u "${SANDBOX_USER}" -- test -w "${_jf}" 2>/dev/null; then
                _breach="the agent can write the journal file ${_jf}"; break
            fi
        done < <(find "${_journal_dir}" -name '*.journal' -type f 2>/dev/null | head -20)
    fi
    if [[ -n "${_breach}" ]]; then
        fail "the agent can unmake its own trail: ${_breach}"
    else
        pass "the agent cannot create or rewrite journal storage: its own trail is append-only to it"
    fi

    # journalctl's destructive verbs must fail for the agent. --vacuum-time would discard the
    # trail wholesale; it is the single most valuable call an agent covering its tracks could
    # make. (Bash(journalctl *) is denied in settings.json too, but that is a tooling hint --
    # this asserts the floor underneath it.)
    if runuser -u "${SANDBOX_USER}" -- journalctl --vacuum-time=99999d >/dev/null 2>&1; then
        fail "the agent can run 'journalctl --vacuum-time' -- it can discard the trail it is recorded in"
    else
        pass "the agent cannot vacuum or rotate the journal (destructive journalctl verbs refused)"
    fi
fi

finish
