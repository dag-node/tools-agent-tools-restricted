#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/hooks.sh
# Integration: what the deployed hook configuration DECLARES -- settings.json names the handback
# hooks and the Bash deny rules -- and the optional /tmp isolation where a host carries it. Both
# read installed files and need no allowlisted path.
#
# The hooks themselves are not driven here. Each delegates to the handback socket daemon, which
# execs ai-tools-chown with its OWN environment, so the helper reads the operator's REAL allowlist
# and a fixture must sit inside a project that allowlist names -- which this suite may not write,
# and the checkout it runs from need not be one. The live chain (PostToolUse, the tool-call record,
# the Stop sweep, SessionStart and SessionEnd reclaim) is exercised in
# tests/manual/verify-live-flows.sh, inside the project that run claims. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

# The hook paths the declarations must name; the files are not run here.
readonly hook="/opt/ai-tools/.claude/post-tool-hook.sh"
readonly sweep="/opt/ai-tools/.claude/session-hook.sh"
readonly settings="/opt/ai-tools/.claude/settings.json"

# ── settings.json declares the hooks + Bash deny rules ───────────────────────────
# perms.sh pins settings.json's owner/mode and access.sh pins that the agent cannot write it,
# but no case asserts the file still DECLARES the handback hooks and the deny rules -- an install
# that shipped an empty or stale settings.json would disable handback + secret quarantine with
# every permission check still green. Pin the security-load-bearing content here. This runs
# independently of the live daemon below (it needs only the file), so a socket-down host still
# exercises it. Requires jq; skips the content check (not the file's existence) without it.
section "settings.json declares the hooks + deny rules (integration)"
if [[ ! -r "${settings}" ]]; then
    fail "${settings} is missing or unreadable -- the session ships no hook/deny configuration"
elif ! command -v jq >/dev/null 2>&1; then
    skip "settings.json content" "jq not available to parse ${settings}"
elif ! jq -e . "${settings}" >/dev/null 2>&1; then
    fail "${settings} is not valid JSON -- Claude Code would ignore it and run with no hooks/denies"
else
    # (0a) Each hook event points at the installed hook body with the expected argument. A
    # regression that drops an event or repoints it silently disables that handback path.
    declare -A want_hook=(
        [PostToolUse]="${hook}"
        [Stop]="${sweep}"
        [SessionStart]="${sweep} session-start"
        [SessionEnd]="${sweep} session-end"
    )
    hooks_ok=true
    for ev in PostToolUse Stop SessionStart SessionEnd; do
        got="$(jq -r --arg e "${ev}" \
            '[.hooks[$e][]?.hooks[]?.command] | join("\n")' "${settings}" 2>/dev/null)"
        if ! grep -qxF "${want_hook[$ev]}" <<<"${got}"; then
            fail "settings.json ${ev} hook is '${got:-<none>}', expected '${want_hook[$ev]}'"
            hooks_ok=false
        fi
    done
    ${hooks_ok} && pass "settings.json declares PostToolUse/Stop/SessionStart/SessionEnd -> installed hook bodies"

    # (0a-i) The tool-call record is declared on Bash. It is a SEPARATE matcher group from the
    # Write|Edit handback rather than a widened matcher, because the settings merge keys on the
    # command string: a widened matcher would never reach a host whose settings.json is kept
    # across an upgrade, leaving the records emitted on a fresh install and silently nowhere
    # else (claude-settings.rule.md). Pin the exact command, since that string IS the mechanism
    # that carries it onto an upgraded host.
    got="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command] | join("\n")' "${settings}" 2>/dev/null)"
    if grep -qxF "${hook} record" <<<"${got}"; then
        pass "settings.json declares the Bash tool-call record (${hook} record)"
    else
        fail "settings.json does not declare '${hook} record' -- the agent's Bash calls are unrecorded (merge the shipped hook declarations into the kept settings.json: sudo ai-tools-admin system post-upgrade)"
    fi

    # (0a-ii) The token-saving filter hook is declared on both Bash events. Losing it costs
    # tokens rather than a guarantee (see filters.rule.md), so it is asserted separately from the
    # handback events above -- a failure here means unfiltered output, not unowned files. Both
    # events must be present: PreToolUse without PostToolUse silently drops the noise stripping.
    filter="/opt/ai-tools/.claude/filter-hook.sh"
    declare -A want_filter=(
        [PreToolUse]="${filter} pre-tool-use"
        [PostToolUse]="${filter} post-tool-use"
    )
    filter_ok=true
    for ev in PreToolUse PostToolUse; do
        got="$(jq -r --arg e "${ev}" '[.hooks[$e][]?.hooks[]?.command] | join("\n")' "${settings}" 2>/dev/null)"
        if ! grep -qxF "${want_filter[$ev]}" <<<"${got}"; then
            fail "settings.json ${ev} does not declare '${want_filter[$ev]}' -- Bash output is unfiltered (merge the shipped hook declarations into the kept settings.json: sudo ai-tools-admin system post-upgrade)"
            filter_ok=false
        fi
    done
    ${filter_ok} && pass "settings.json declares PreToolUse/PostToolUse -> the command-filter hook"

    # (0b) The categorical deny rules are present: commands the core posture refuses
    # regardless of arguments or target (sudo/su under NNP, the manager/journal/audit
    # CLIs, the package managers while pkgmgmt is off, mount/umount, SELinux management).
    # A tooling hint, not the boundary, but dropping one re-exposes the attempt -- pin
    # them all (groups and criteria: claude-settings.rule.md).
    deny="$(jq -r '.permissions.deny[]?' "${settings}" 2>/dev/null)"
    deny_ok=true
    for rule in 'Bash(sudo)' 'Bash(sudo *)' 'Bash(su)' 'Bash(su *)' 'Bash(journalctl *)' \
                'Bash(systemctl *)' 'Bash(ausearch *)' 'Bash(auditctl *)' 'Bash(aureport *)' \
                'Bash(dnf *)' 'Bash(yum *)' 'Bash(mount *)' 'Bash(umount *)' \
                'Bash(setenforce *)' 'Bash(semodule *)' 'Bash(semanage *)'; do
        grep -qxF "${rule}" <<<"${deny}" || { fail "settings.json deny list is missing '${rule}'"; deny_ok=false; }
    done
    ${deny_ok} && pass "settings.json denies the categorical dead-ends (sudo/su, manager/audit CLIs, pkg, mount, SELinux mgmt)"

    # (0b-ii) The irreversible-VCS deny group is present. Unlike the categorical group above,
    # these commands SUCCEED if attempted -- the deny is the only thing between the agent and a
    # force-push, a hard reset, or a forced clean, none of which has an undo. They are pinned
    # strictly (not reported like the host-survey group below) because the two paths that
    # preserve a host's tuning -- install.sh's keep-existing and %config(noreplace) on upgrade --
    # are also how a settings.json that predates the group, or one edited in the permission
    # arrays it invites tuning of, silently loses the gate while every other check stays green.
    vcs_ok=true
    for rule in 'Bash(git push --force*)' 'Bash(git push -f *)' \
                'Bash(git reset --hard*)' 'Bash(git clean -f*)'; do
        grep -qxF "${rule}" <<<"${deny}" || { fail "settings.json deny list is missing '${rule}' -- the irreversible-VCS gate is open (reseed or re-add it)"; vcs_ok=false; }
    done
    ${vcs_ok} && pass "settings.json denies the irreversible VCS operations (force-push, hard reset, forced clean)"

    # (0c) The host-survey deny group exists. Unlisted safe-reads are auto-approved by
    # the harness past the prompt, so these denies are the only layer keeping host recon
    # (accounts, packages, processes, storage, security posture) operator-mediated. A
    # host may deliberately relax individual entries (claude-settings.rule.md), so a
    # partial set passes with the relaxed entries named; a file with NONE of them
    # predates the group (a kept pre-upgrade settings.json) and fails. One form per
    # command keeps the relax report readable.
    survey_missing=(); survey_present=0
    for rule in 'Bash(df)' 'Bash(du *)' 'Bash(ps *)' 'Bash(id)' 'Bash(getent *)' \
                'Bash(rpm *)' 'Bash(mount)' 'Bash(readlink *)' 'Bash(getenforce)' \
                'Bash(matchpathcon *)'; do
        if grep -qxF "${rule}" <<<"${deny}"; then
            survey_present=$(( survey_present + 1 ))
        else
            survey_missing+=("${rule}")
        fi
    done
    if (( survey_present == 0 )); then
        fail "settings.json has no host-survey denies -- the file predates the deny group (reseed or add them)"
    elif (( ${#survey_missing[@]} > 0 )); then
        pass "host-survey denies present (${survey_present}) -- relaxed on this host: ${survey_missing[*]}"
    else
        pass "settings.json denies the full host-survey group (accounts, packages, processes, storage, posture)"
    fi

    # (0d) No entry sits in both lists. deny wins at runtime, so an overlap is not a
    # bypass, but it means the lists drifted -- an allow a deny silently overrides is a
    # config error worth surfacing.
    overlap="$(comm -12 <(jq -r '.permissions.allow[]?' "${settings}" | sort -u) \
                        <(printf '%s\n' "${deny}" | sort -u))"
    if [[ -n "${overlap}" ]]; then
        fail "settings.json entries present in BOTH allow and deny: $(tr '\n' ' ' <<<"${overlap}")"
    else
        pass "settings.json allow and deny lists are disjoint"
    fi
fi

# ── /tmp isolation (pam_namespace, optional) ─────────────────────────────────────
# pam_namespace polyinstantiation of /tmp + /var/tmp gives each session a private /tmp instance
# (a confinement property, and the reason the live hook chain is driven against a fixture under
# the operator's home rather than /tmp). It is OPTIONAL and outside this project's install, so a host without it
# is the default state and is not reported: the only line this emits is the PASS where the
# isolation is present, on a host whose administrator set it up.
readonly NSCONF="/etc/security/namespace.conf"
if [[ -r "${NSCONF}" ]]; then
    has_tmp=false; has_vartmp=false
    awk -v d=/tmp     '!/^[[:space:]]*#/ && $1==d && $3 ~ /level|context|user/ {exit 0} END{exit 1}' "${NSCONF}" && has_tmp=true
    awk -v d=/var/tmp '!/^[[:space:]]*#/ && $1==d && $3 ~ /level|context|user/ {exit 0} END{exit 1}' "${NSCONF}" && has_vartmp=true
    if ${has_tmp} && ${has_vartmp}; then
        section "/tmp isolation (pam_namespace)"
        pass "pam_namespace polyinstantiates /tmp and /var/tmp per session (isolation active)"
    fi
fi

finish
