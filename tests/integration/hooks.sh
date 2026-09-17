#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/hooks.sh
# Integration: what the deployed hook configuration DECLARES -- settings.json names the handback hooks and the Bash deny
# rules -- and the optional /tmp isolation where a host carries it. Both read installed files and need no allowlisted
# path.
#
# The hooks themselves are not driven here. Each delegates to the handback socket daemon, which execs ai-tools-chown
# with its OWN environment, so the helper reads the operator's REAL allowlist and a fixture must sit inside a project
# that allowlist names -- which this suite may not write, and the checkout it runs from need not be one. The live chain
# (PostToolUse, the tool-call record, the Stop sweep, SessionStart and SessionEnd reclaim) is exercised
# in tests/manual/verify-live-flows.sh, inside the project that run claims. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

# The hook paths the declarations must name; the files are not run here.
readonly hook="/opt/ai-tools/.claude/post-tool-hook.sh"
readonly sweep="/opt/ai-tools/.claude/session-hook.sh"
readonly settings="/opt/ai-tools/.claude/settings.json"

# ── settings.json declares the hooks + Bash deny rules ───────────────────────────
# perms.sh pins settings.json's owner/mode and access.sh pins that the agent cannot write it, but no case asserts
# the file still DECLARES the handback hooks and the deny rules -- an install that shipped an empty or stale
# settings.json would disable handback + secret quarantine with every permission check still green. Pin
# the security-load-bearing content here. This runs independently of the live daemon (it needs only the file),
# so a socket-down host still exercises it. Requires jq; skips the content check (not the file's existence) without it.
section "settings.json declares the hooks + deny rules (integration)"
if [[ ! -r "${settings}" ]]; then
    fail "${settings} is missing or unreadable -- the session ships no hook/deny configuration"
elif ! command -v jq >/dev/null 2>&1; then
    skip "settings.json content" "jq not available to parse ${settings}"
elif ! jq -e . "${settings}" >/dev/null 2>&1; then
    fail "${settings} is not valid JSON -- Claude Code would ignore it and run with no hooks/denies"
else
    # (0a) Each hook event points at the installed hook body with the expected argument. A regression that drops
    # an event or repoints it silently disables that handback path.
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

    # (0a-i) The tool-call record is declared on Bash. It is a SEPARATE matcher group from the Write|Edit handback
    # rather than a widened matcher, because the settings merge keys on the command string: a widened matcher would
    # never reach a host whose settings.json is kept across an upgrade, leaving the records emitted on a fresh install
    # and silently nowhere else (claude-settings.rule.md). Pin the exact command, since that string IS the mechanism
    # that carries it onto an upgraded host.
    got="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command] | join("\n")' "${settings}" 2>/dev/null)"
    if grep -qxF "${hook} record" <<<"${got}"; then
        pass "settings.json declares the Bash tool-call record (${hook} record)"
    else
        fail "settings.json does not declare '${hook} record' -- the agent's Bash calls are unrecorded (merge the shipped hook declarations into the kept settings.json: sudo ai-tools-admin system post-upgrade)"
    fi

    # (0a-ii) The token-saving filter hook is declared on both Bash events. Losing it costs tokens rather than
    # a guarantee (see filters.rule.md), so it is asserted separately from the handback events -- a failure here means
    # unfiltered output, not unowned files. Both events must be present: PreToolUse without PostToolUse silently drops
    # the noise stripping.
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

    # (0b) The categorical deny rules are present: commands the core posture refuses regardless of arguments or target
    # (sudo/su under NNP, the manager/journal/audit CLIs, the package managers while pkgmgmt is off, mount/umount,
    # SELinux management). A tooling hint, not the boundary, but dropping one re-exposes the attempt -- pin them all
    # (groups and criteria: claude-settings.rule.md).
    deny="$(jq -r '.permissions.deny[]?' "${settings}" 2>/dev/null)"
    deny_ok=true
    for rule in 'Bash(sudo)' 'Bash(sudo *)' 'Bash(su)' 'Bash(su *)' 'Bash(journalctl *)' \
                'Bash(systemctl *)' 'Bash(ausearch *)' 'Bash(auditctl *)' 'Bash(aureport *)' \
                'Bash(dnf *)' 'Bash(yum *)' 'Bash(mount *)' 'Bash(umount *)' \
                'Bash(setenforce *)' 'Bash(semodule *)' 'Bash(semanage *)'; do
        grep -qxF "${rule}" <<<"${deny}" || { fail "settings.json deny list is missing '${rule}'"; deny_ok=false; }
    done
    ${deny_ok} && pass "settings.json denies the categorical dead-ends (sudo/su, manager/audit CLIs, pkg, mount, SELinux mgmt)"

    # (0b-ii) The irreversible-VCS deny group is present. Unlike the categorical group, these commands SUCCEED if
    # attempted -- the deny is the only thing between the agent and a force-push, a hard reset, or a forced clean, none
    # of which has an undo. They are pinned strictly (not reported like the host-survey group) because the two paths
    # that preserve a host's tuning -- install.sh's keep-existing and %config(noreplace) on upgrade -- are also
    # how a settings.json that predates the group, or one edited in the permission arrays it invites tuning of, silently
    # loses the gate while every other check stays green.
    vcs_ok=true
    for rule in 'Bash(git push --force*)' 'Bash(git push -f *)' \
                'Bash(git reset --hard*)' 'Bash(git clean -f*)'; do
        grep -qxF "${rule}" <<<"${deny}" || { fail "settings.json deny list is missing '${rule}' -- the irreversible-VCS gate is open (reseed or re-add it)"; vcs_ok=false; }
    done
    ${vcs_ok} && pass "settings.json denies the irreversible VCS operations (force-push, hard reset, forced clean)"

    # (0c) The host-survey deny group exists. Unlisted safe-reads are auto-approved by the harness past the prompt,
    # so these denies are the only layer keeping host recon (accounts, packages, processes, storage, security posture)
    # operator-mediated. A host may deliberately relax individual entries (claude-settings.rule.md), so a partial set
    # passes with the relaxed entries named; a file with NONE of them predates the group (a kept pre-upgrade
    # settings.json) and fails. One form per command keeps the relax report readable.
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

    # (0d) No entry sits in both lists. deny wins at runtime, so an overlap is not a bypass, but it means the lists
    # drifted -- an allow a deny silently overrides is a config error worth surfacing.
    overlap="$(comm -12 <(jq -r '.permissions.allow[]?' "${settings}" | sort -u) \
                        <(printf '%s\n' "${deny}" | sort -u))"
    if [[ -n "${overlap}" ]]; then
        fail "settings.json entries present in BOTH allow and deny: $(tr '\n' ' ' <<<"${overlap}")"
    else
        pass "settings.json allow and deny lists are disjoint"
    fi
fi

# ── requirements.toml declares codex's hooks + the pin ───────────────────────────
# The codex package's counterpart to settings.json: codex reads /etc/codex/requirements.toml at every start,
# and with allow_managed_hooks_only it is the ONLY source of hooks a session runs, so a stale or emptied file would drop
# the per-turn handback (the shim's session-end sweep still hands back -- the manifest declares handback=none)
# and, without the pin, send codex after a bubblewrap sandbox the session unit refuses. Pinned here as codex parses it,
# since a bare key that landed after a table header belongs to that table and reads as accepted while codex ignores it.
# Needs python3's tomllib (3.11+); skips the content check without it. Absent where the codex package is not installed.
readonly codex_requirements="/etc/codex/requirements.toml"
readonly codex_hook="/opt/ai-tools/.codex/post-tool-hook.sh"
readonly codex_sweep="/opt/ai-tools/.codex/session-hook.sh"
section "requirements.toml declares codex's hooks + the pin (integration)"
if [[ ! -e "${codex_requirements}" ]]; then
    skip "${codex_requirements}" "not deployed on this host (the codex package is absent)"
elif [[ ! -r "${codex_requirements}" ]]; then
    fail "${codex_requirements} is unreadable -- codex refuses to start on it"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import tomllib' 2>/dev/null; then
    skip "requirements.toml content" "python3 with tomllib (3.11+) not available to parse ${codex_requirements}"
else
    # One parse, printed as KEY<TAB>value lines; a hook event's value is its commands joined by '|'. A file codex would
    # refuse (a parse error) fails here with the parser's message.
    codex_decl="$(python3 - "${codex_requirements}" <<'PY' 2>&1
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
print("managed_only\t%s" % str(doc.get("allow_managed_hooks_only", "")).lower())
print("modes\t%s" % "|".join(doc.get("allowed_sandbox_modes", [])))
print("default_permissions\t%s" % doc.get("default_permissions", ""))
hooks = doc.get("hooks", {})
print("managed_dir\t%s" % hooks.get("managed_dir", ""))
for event in ("SessionStart", "PostToolUse", "Stop", "SessionEnd"):
    cmds = [h.get("command", "") for e in hooks.get(event, []) for h in e.get("hooks", [])]
    print("%s\t%s" % (event, "|".join(cmds)))
for r in doc.get("rules", {}).get("prefix_rules", []):
    tokens = [e.get("token") or "|".join(e.get("any_of", [])) for e in r.get("pattern", [])]
    print("rule\t%s => %s" % (" ".join(tokens), r.get("decision", "")))
PY
)" || { fail "${codex_requirements} does not parse as TOML -- codex refuses to start on it: ${codex_decl}"; codex_decl=""; }
    if [[ -n "${codex_decl}" ]]; then
        decl() { awk -F'\t' -v k="$1" '$1==k {print $2}' <<<"${codex_decl}"; }
        # (c0) The pin. danger-full-access is what keeps the host's confinement closed: codex's own sandbox needs a user
        # namespace the session unit refuses, so the managed default says codex does not add a sandbox of its own.
        if [[ "$(decl default_permissions)" == ":danger-full-access" ]] \
                && grep -q 'danger-full-access' <<<"$(decl modes)"; then
            pass "requirements.toml pins the session on the host's confinement (default_permissions :danger-full-access)"
        else
            fail "requirements.toml does not pin danger-full-access (modes '$(decl modes)', default '$(decl default_permissions)') -- codex would reach for bubblewrap and fail every tool call"
        fi
        # (c1) Managed hooks are the only hooks, and they live in the root-owned config directory.
        if [[ "$(decl managed_only)" == true && "$(decl managed_dir)" == /opt/ai-tools/.codex ]]; then
            pass "requirements.toml admits managed hooks only, from /opt/ai-tools/.codex"
        else
            fail "requirements.toml: allow_managed_hooks_only='$(decl managed_only)', managed_dir='$(decl managed_dir)' -- a user hooks file could run in the session"
        fi
        # (c2) Each event names the installed hook body with its argument, the same four events settings.json declares
        # for claude-code; a dropped or repointed event silently disables that handback path.
        declare -A want_codex_hook=(
            [SessionStart]="${codex_sweep} session-start"
            [PostToolUse]="${codex_hook}"
            [Stop]="${codex_sweep}"
            [SessionEnd]="${codex_sweep} session-end"
        )
        codex_hooks_ok=true
        for ev in SessionStart PostToolUse Stop SessionEnd; do
            got="$(decl "${ev}")"
            if [[ "${got}" != "${want_codex_hook[$ev]}" ]]; then
                fail "requirements.toml ${ev} hook is '${got:-<none>}', expected '${want_codex_hook[$ev]}'"
                codex_hooks_ok=false
            fi
        done
        ${codex_hooks_ok} && pass "requirements.toml declares SessionStart/PostToolUse/Stop/SessionEnd -> installed codex hook bodies"
        # (c3) The per-command refusals, codex's counterpart to settings.json's irreversible-VCS deny group: the git
        # verbs that destroy with no undo, which no host control refuses since they run unprivileged in the operator's
        # own tree. The live file is kept across an upgrade, so what this catches is an edit that dropped a row.
        codex_rules="$(decl rule)"
        codex_rules_ok=true
        for verb in "git push" "git reset --hard" "git clean"; do
            if ! grep -q "^${verb} " <<<"${codex_rules}"; then
                fail "requirements.toml [rules] refuses no '${verb}' -- a codex session runs it unprompted"
                codex_rules_ok=false
            fi
        done
        if grep -q '=> allow$' <<<"${codex_rules}"; then
            fail "requirements.toml [rules] carries an allow decision, which a requirements rule may not: codex refuses the file"
            codex_rules_ok=false
        fi
        ${codex_rules_ok} && pass "requirements.toml [rules] refuses the git verbs that destroy with no undo"
        # (c4) Every declared hook body is installed and executable by the agent: codex skips a hook it cannot run
        # without reporting it, so a declaration alone is not the mechanism.
        for hb in "${codex_hook}" "${codex_sweep}"; do
            if [[ -x "${hb}" ]]; then
                pass "${hb} is installed and executable"
            else
                fail "${hb} is declared in requirements.toml and not executable -- codex skips it silently"
            fi
        done
    fi
fi

# ── /tmp isolation (pam_namespace, optional) ─────────────────────────────────────
# pam_namespace polyinstantiation of /tmp + /var/tmp gives each session a private /tmp instance (a confinement property,
# and the reason the live hook chain is driven against a fixture under the operator's home rather than /tmp). It is
# OPTIONAL and outside this project's install, so a host without it is the default state and is not reported: the only
# line this emits is the PASS where the isolation is present, on a host whose administrator set it up.
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
