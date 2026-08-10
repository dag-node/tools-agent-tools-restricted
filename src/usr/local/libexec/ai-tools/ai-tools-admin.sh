#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-admin
# Host administration for the ai-tools sandbox. A root helper (run via sudo), not an ai-tools
# CLI verb: it edits host config (the OPERATORS list, the ai-ops group, the sandbox account's
# linger; the loaded optional SELinux policy groups) while the ai-tools CLI is unprivileged and
# refuses to run as root.
#
#   sudo ai-tools-admin operator add [user]           # default: $SUDO_USER
#   sudo ai-tools-admin operator remove <user>
#   sudo ai-tools-admin operator list
#   sudo ai-tools-admin selinux list-groups                # show core + optional group state
#   sudo ai-tools-admin selinux enable-group <name>        # load a prebuilt (stable) group
#   sudo ai-tools-admin selinux disable-group <name>       # unload one
#   sudo ai-tools-admin postupgrade                        # reconcile the .rpmnew files upgrades leave
#
# An operator is a login user (a human or a rootless service account) that drives the sandbox
# through the shared ai-tools account. `add` is accumulating and idempotent: it appends the
# name to OPERATORS in /etc/ai-tools/operator.conf, adds the user to the ai-ops group (the
# sudoers grant and the launch wrapper gate on membership), seeds the user's allowlist, ensures
# the sandbox account's linger, and offers to wire the PATH dedup. `remove` reverses the host-side
# membership (drops the name from OPERATORS and ai-ops), leaving the user's own allowlist and config.
# `list` prints the current operators.
#
# `selinux` toggles the optional policy groups (systemd/pkgmgmt/netadmin/podman/tmpmap/apphost/netcore), all off
# by default. It loads the PREBUILT ai_tools_<group>.pp shipped in the base package via semodule --
# no source tree or selinux-policy-devel needed on the host. The group set, descriptions, and
# per-group stability are single-sourced from selinux-groups.lib.sh, shared with
# selinux/install-selinux.sh (the source-tree authoring tool that instead COMPILES a group; this
# operator helper only loads a shipped one). Only STABLE groups ship prebuilt (currently tmpmap);
# enable-group of an EXPERIMENTAL (unaudited) group is refused with a pointer to the source
# compile-and-verify workflow (install-selinux.sh + the avc bring-up loop), since this tool will
# not load an unaudited module. disable-group works for any loaded group, stable or not.
#
# `postupgrade` reconciles the `<file>.rpmnew` copies an upgrade leaves beside the
# %config(noreplace) files this stack owns. rpm keeps what the host edited and parks the new
# version alongside it; choosing between the two is a judgement about the operator's own
# configuration, so it happens here, when the operator asks, and never in a scriptlet. Each file
# gets the treatment its content deserves -- merge, report, or show only, per the registry below --
# and every treatment shows what it would change, confirms, backs the file up before writing, and
# names each path it touched. The from-source installer reaches the same end through its own
# keep-or-reset prompts and dated .bak/.shipped sidecars; this is the RPM-side equivalent.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-admin.sh /usr/local/libexec/ai-tools/ai-tools-admin

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly OPERATORS_GROUP="ai-ops"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
readonly SELINUX_GROUPS_LIB="/usr/local/lib/ai-tools/selinux-groups.lib.sh"
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"

die() { printf 'ai-tools-admin: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-admin: %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"

# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
. "${OPERATOR_LIB}" || die "cannot source ${OPERATOR_LIB}"

# Optional SELinux policy-group registry + predicates, shared with install-selinux.sh.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/selinux-groups.lib.sh
. "${SELINUX_GROUPS_LIB}" || die "cannot source ${SELINUX_GROUPS_LIB}"

# The shared config grammar, sidecar handling, and hook-declaration merge that `postupgrade`
# drives. Required, not optional: a reconcile that silently skipped its merge would leave a
# shipped hook uninvoked while reporting success.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
. "${CONF_LIB}" || die "cannot source ${CONF_LIB}"

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like the
# operator lib above: a valid install ships it, so there is no fallback.
# Include-guarded, so a re-source is a no-op.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh || die "cannot source /usr/local/lib/ai-tools/msg.lib.sh"
# Fixed 80-column frame for any box this tool renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

# write_operators <name>...: set the OPERATORS list in operator.conf (root:root 644).
# Edits ONLY the OPERATORS line in an existing file, preserving every other setting the
# operator maintains there (the SKIP_* categories; template: src/etc/ai-tools/operator.conf,
# reference: skip-dirs.lib.sh); seeds a minimal file when absent. 644: world-readable (the
# agent hooks and the root helpers both read it; it carries no secret) and root-write-only,
# so the agent cannot rewrite the identity root hands files back to.
write_operators() {
    install -d -o root -g root -m 755 /etc/ai-tools
    local tmp; tmp="$(mktemp)"
    if [[ -f "${OPERATOR_CONF}" ]] && grep -qE '^[[:space:]]*OPERATORS=' "${OPERATOR_CONF}"; then
        sed -E "s|^[[:space:]]*OPERATORS=.*|OPERATORS=\"$*\"|" "${OPERATOR_CONF}" > "${tmp}"
    elif [[ -f "${OPERATOR_CONF}" ]]; then
        cat "${OPERATOR_CONF}" > "${tmp}"
        printf 'OPERATORS="%s"\n' "$*" >> "${tmp}"
    else
        printf '%s\n' \
            "# ai-tools host configuration -- full reference: /usr/local/lib/ai-tools/skip-dirs.lib.sh" \
            "# and the template src/etc/ai-tools/operator.conf." \
            "OPERATORS=\"$*\"" > "${tmp}"
    fi
    install -o root -g root -m 644 "${tmp}" "${OPERATOR_CONF}"
    rm -f "${tmp}"
}

# in_list <name>: succeed when <name> is already in AI_TOOLS_OPERATORS.
in_list() {
    local n; for n in "${AI_TOOLS_OPERATORS[@]:-}"; do [[ "${n}" == "$1" ]] && return 0; done
    return 1
}

# seed_allowlist <user>: create the operator's empty allowed-projects (header only) when absent,
# 700 .config/ai-tools + 600 allowlist so the sandbox account -- not owner, not in the group,
# unable to enter the 700 dir -- cannot read it. Never clobbers an existing allowlist.
seed_allowlist() {
    local user="$1" home group cfg allow tmp
    home="$(getent passwd "${user}" | cut -d: -f6)"
    group="$(id -gn "${user}")"
    [[ -n "${home}" && -d "${home}" ]] || { log "warn: no home for ${user}; skipping allowlist seed"; return 0; }
    cfg="${home}/.config/ai-tools"
    [[ -d "${home}/.config" ]] || install -d -o "${user}" -g "${group}" -m 700 "${home}/.config"
    [[ -d "${cfg}" ]]          || install -d -o "${user}" -g "${group}" -m 700 "${cfg}"
    allow="${cfg}/allowed-projects"
    [[ -f "${allow}" ]] && return 0
    log "seeding ${allow}"
    tmp="$(mktemp)"
    printf '%s\n' \
        "# Approved project directories for Claude Code (ai-tools)." \
        "# A plain path allows it (and its contents); a '!'-prefixed path excludes it." \
        "# Manage with the ai-tools CLI rather than by hand:" \
        "#   ai-tools --project-create <dir>   register a real project" \
        "#   ai-tools --sandbox-create <dir>   shallow-clone a repo into the sandbox area" \
        "" > "${tmp}"
    install -o "${user}" -g "${group}" -m 600 "${tmp}" "${allow}"
    rm -f "${tmp}"
}

# wire_dedup <user>: offer (interactively) to source the ai-tools PATH dedup from the operator's
# ~/.bashrc and ~/.bash_profile after their nvm init, so /usr/local/bin (the claude wrapper)
# wins over the nvm shim in every shell. This wiring is the dedup's only delivery: the file
# lives in the ai-tools lib dir, not /etc/profile.d, so unwired accounts keep their stock PATH.
# Edits the operator's home, so it asks first and never rewrites non-interactively; a piped run
# prints the line to add.
readonly DEDUP_GUARD='[[ -f /usr/local/lib/ai-tools/path-dedup.sh ]] && source /usr/local/lib/ai-tools/path-dedup.sh || true'
wire_dedup() {
    local user="$1" home group bashrc bashprof f
    home="$(getent passwd "${user}" | cut -d: -f6)"
    group="$(id -gn "${user}")"
    [[ -n "${home}" && -d "${home}" ]] || return 0
    bashrc="${home}/.bashrc"; bashprof="${home}/.bash_profile"
    _wire_one() {
        f="$1"
        [[ -e "${f}" ]] || install -o "${user}" -g "${group}" -m 644 /dev/null "${f}"
        if grep -qF '/usr/local/lib/ai-tools/path-dedup.sh' "${f}"; then
            log "PATH dedup already present in ${f}"; return
        fi
        grep -qF 'NVM_DIR' "${f}" \
            || log "note: NVM_DIR not found in ${f} -- path-dedup still works, but it is meant to follow your nvm init"
        printf '\n# Added by ai-tools-admin: source the ai-tools PATH dedup (must follow nvm init).\n%s\n' \
            "${DEDUP_GUARD}" >> "${f}"
        log "wired PATH dedup into ${f}"
    }
    if [[ -t 0 && -e /dev/tty ]]; then
        if ai_tools_msg_confirm \
            "Wire the ai-tools PATH dedup into ${bashrc} and ${bashprof}?" y; then
            _wire_one "${bashrc}"; _wire_one "${bashprof}"
        else
            log "skipped PATH dedup; add this line after your nvm init in ${bashrc} and ${bashprof}:"
            log "  ${DEDUP_GUARD}"
        fi
    else
        log "non-interactive: not editing shell init. Add this line after your nvm init in ${bashrc} and ${bashprof}:"
        log "  ${DEDUP_GUARD}"
    fi
}

op_add() {
    local user="${1:-${SUDO_USER:-}}"
    [[ -n "${user}" ]] || die "usage: ai-tools-admin operator add <user>  (or run via sudo so SUDO_USER is set)"
    [[ "${user}" != "${SANDBOX_USER}" ]] || die "an operator must not be the sandbox account ${SANDBOX_USER}"
    [[ "${user}" != "root" ]]            || die "an operator must be a normal login user, not root"
    id "${user}" &>/dev/null || die "no such user: ${user}"

    ai_tools_load_operators || true   # tolerate an unenrolled host (empty list)
    if in_list "${user}"; then
        log "${user} is already an operator; reconciling group, allowlist, and sandbox linger"
    else
        local newlist=()
        [[ "${#AI_TOOLS_OPERATORS[@]}" -gt 0 ]] && newlist=( "${AI_TOOLS_OPERATORS[@]}" )
        newlist+=( "${user}" )
        write_operators "${newlist[@]}"
        log "added ${user} to OPERATORS"
    fi

    # ai-ops membership: the sudoers grant and the launch wrapper gate on it. The sandbox
    # account is never a member (it must not be able to drive itself as an operator). Add --
    # and log -- only when the user is not already a member, so a reconciling re-run does not
    # report a change it did not make.
    if id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${OPERATORS_GROUP}"; then
        log "${user} is already in group ${OPERATORS_GROUP}"
    else
        usermod -aG "${OPERATORS_GROUP}" "${user}" || die "failed to add ${user} to ${OPERATORS_GROUP}"
        log "added ${user} to group ${OPERATORS_GROUP}"
    fi

    seed_allowlist "${user}"

    # The sandbox account needs a systemd --user instance without an interactive login: its
    # nvm-update timer and each ai-tools-run session unit run there, and it has no login shell, so
    # only linger keeps that instance alive. An operator runs claude from its own active login,
    # so it needs no linger here; enabling operator linger for other reasons is host policy.
    log "enabling linger for ${SANDBOX_USER}"
    loginctl enable-linger "${SANDBOX_USER}"  2>/dev/null || log "warn: could not enable linger for ${SANDBOX_USER}"

    wire_dedup "${user}"
    log "operator ${user} added"
    # ai-ops membership applies to NEW login sessions; an already-open shell keeps the credential
    # set it had at login, and the launch wrapper gates on that live set. Name the activation step
    # so the operator's first claude launch does not hit the stale-session refusal.
    log "${user}: start a new login session (or run 'newgrp ${OPERATORS_GROUP}') before launching claude -- ${OPERATORS_GROUP} membership does not apply to already-open shells"
}

op_remove() {
    local user="${1:-}"
    [[ -n "${user}" ]] || die "usage: ai-tools-admin operator remove <user>"
    ai_tools_load_operators || true
    if ! in_list "${user}"; then
        log "${user} is not an operator; nothing to remove"
        return 0
    fi
    local kept=() n
    for n in "${AI_TOOLS_OPERATORS[@]}"; do [[ "${n}" == "${user}" ]] || kept+=("${n}"); done
    write_operators "${kept[@]}"
    log "removed ${user} from OPERATORS"
    # Drop ai-ops membership; leave the user's own allowlist and config (their data).
    gpasswd -d "${user}" "${OPERATORS_GROUP}" >/dev/null 2>&1 \
        || log "warn: could not remove ${user} from ${OPERATORS_GROUP}"
    log "removed ${user} from group ${OPERATORS_GROUP}"
}

op_list() {
    if ai_tools_load_operators; then
        printf '%s\n' "${AI_TOOLS_OPERATORS[@]}"
    else
        log "no operators configured"
    fi
}

# ── selinux: optional policy-group management ────────────────────────────────────────
# These load/unload the PREBUILT ai_tools_<group>.pp shipped in the base package; the group
# set and text come from selinux-groups.lib.sh. Distinct from selinux/install-selinux.sh,
# which compiles a group from source in a repo checkout -- this runs on any installed host.

# require_selinux: guard shared by every selinux subcommand. Returns 1 (caller exits 0 --
# nothing to manage) when SELinux is disabled; dies when semodule is absent (a real gap).
require_selinux() {
    if [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        log "SELinux is disabled on this host -- no policy groups to manage"
        return 1
    fi
    command -v semodule >/dev/null 2>&1 || die "semodule not found -- install policycoreutils"
    return 0
}

# _selinux_usage_groups: list the known groups (name + description) to stderr.
_selinux_usage_groups() {
    local entry
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        printf '    %-10s %s\n' \
            "$(ai_tools_selinux_group_name "${entry}")" \
            "$(ai_tools_selinux_group_desc "${entry}")" >&2
    done
}

sel_enable() {
    local name="${1:-}"
    [[ $# -le 1 ]] || die "one group name at a time (usage: ai-tools-admin selinux enable-group <name>)"
    [[ -n "${name}" && "${name}" != -* ]] || die "usage: ai-tools-admin selinux enable-group <name>"
    require_selinux || return 0
    if ! ai_tools_selinux_group_valid "${name}"; then
        log "unknown group '${name}'. Available groups:"; _selinux_usage_groups
        die "no such policy group: ${name}"
    fi
    if ai_tools_selinux_group_loaded "${name}"; then
        log "group '${name}' is already loaded -- nothing to do"
        return 0
    fi
    # Experimental groups are unaudited drafts and are NOT shipped prebuilt. This tool loads only
    # shipped, stable modules; an experimental group must be compiled and verified against a real
    # workload from a source checkout first (install-selinux.sh does both), because it widens the
    # sandbox domain's access beyond the repo-only core. Point the operator there rather than
    # loading an unaudited module.
    if ai_tools_selinux_group_is_experimental "${name}"; then
        ai_tools_msg_warn \
            "The '${name}' SELinux policy group is an EXPERIMENTAL, unaudited draft. It is not shipped prebuilt and cannot be enabled from here -- it widens the sandbox domain's access beyond the repo-only core and must be compiled and verified against a real workload from a source checkout first."
        log "compile, audit under permissive, and load it from a repo checkout:"
        log "    sudo selinux/install-selinux.sh enable-group ${name}"
        log "    (then re-run the bring-up loop in selinux/avc/ before relying on it)"
        log "docs: selinux/README.md, \"Optional policy groups\""
        die "'${name}' is experimental -- verify and enable it from source (see above)"
    fi
    local pp="${AI_TOOLS_SELINUX_PACKAGE_DIR}/ai_tools_${name}.pp"
    [[ -f "${pp}" ]] || die "prebuilt module ${pp} not found -- reinstall ai-tools-base"
    log "loading group: ai_tools_${name}"
    semodule -i "${pp}" || die "semodule failed to load ${pp}"
    log "group '${name}' enabled"
    log "re-run the SELinux bring-up loop (selinux/avc/) to catch any new denials from the"
    log "expanded surface before relying on it under enforcing."
}

sel_disable() {
    local name="${1:-}"
    [[ $# -le 1 ]] || die "one group name at a time (usage: ai-tools-admin selinux disable-group <name>)"
    [[ -n "${name}" && "${name}" != -* ]] || die "usage: ai-tools-admin selinux disable-group <name>"
    require_selinux || return 0
    if ! ai_tools_selinux_group_valid "${name}"; then
        log "unknown group '${name}'. Available groups:"; _selinux_usage_groups
        die "no such policy group: ${name}"
    fi
    if ai_tools_selinux_group_loaded "${name}"; then
        semodule -r "ai_tools_${name}" || die "semodule failed to remove ai_tools_${name}"
        log "group '${name}' disabled"
    else
        log "group '${name}' is not loaded -- nothing to do"
    fi
}

sel_list() {
    require_selinux || return 0
    local core_state="NOT loaded"
    semodule -l 2>/dev/null | grep -qx 'ai_tools' && core_state="loaded"
    log "core module (ai_tools): ${core_state}"
    log "optional policy groups (all default: disabled):"
    local entry name desc stability state
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        desc="$(ai_tools_selinux_group_desc "${entry}")"
        stability="$(ai_tools_selinux_group_stability "${entry}")"
        if ai_tools_selinux_group_loaded "${name}"; then state="[LOADED]  "; else state="[disabled]"; fi
        printf '    %s %-10s %-13s %s\n' "${state}" "${name}" "(${stability})" "${desc}"
    done
    log "toggle: sudo ai-tools-admin selinux enable-group <name> | disable-group <name>"
    log "only stable groups ship prebuilt; an experimental group is enabled from a source"
    log "checkout after verification (sudo selinux/install-selinux.sh enable-group <name>)"
}

# ── postupgrade: reconcile the .rpmnew files an upgrade leaves ───────────────────────────────
# rpm keeps an operator-modified %config(noreplace) file and parks the package's copy beside it as
# <file>.rpmnew. Choosing between the two is a judgement call about the operator's own
# configuration, so no scriptlet makes it: this is the explicit, interactive command that does, and
# it is what the install output points at. Every treatment confirms first, backs the file up before
# writing, and names each path it touched.
#
# The treatment follows the file's CONTENT, rather than one generic merge covering all three:
#   json    hook DECLARATIONS merge additively -- they are control plane, and a declaration the
#           file lacks means a shipped hook installs but nothing invokes it. The permission arrays
#           are the host's and stay exactly as written (claude-settings.rule.md).
#   keyval  reported, never rewritten. An absent key already means its default, so a stale file
#           costs knowledge rather than behaviour, and its layout is the operator's own prose.
#   review  shown only. A tool does not merge the sudo grant.
readonly -a POSTUPGRADE_FILES=(
    "/opt/ai-tools/.claude/settings.json|json|Claude Code settings"
    "/etc/ai-tools/operator.conf|keyval|host options"
    "/etc/sudoers.d/ai-tools|review|sudoers grant"
)

# AI_TOOLS_POSTUPGRADE_ROOT prefixes every path in that registry, so the test suite drives this
# command against fixtures in its own /tmp testdir instead of the live host's control plane. It is
# a ROOT-ONLY test hook of the same shape and standing as AI_TOOLS_ALLOWLIST: sudo strips the
# environment (env_reset, and this name is not in env_keep) and the helper is reachable only as
# root, so neither an operator nor the agent can set it, and a caller who could is one that may
# already edit these files outright. Unset in production, where the registry paths are absolute.

# _pu_diff <deployed> <rpmnew>: show what the package would change, indented. Colourized through
# colordiff when the host has it AND stdout is a terminal: colordiff is an EPEL package on RHEL, so
# it is used where present and never depended on, and the terminal test keeps escape sequences out
# of a redirected run, the way every other message this project prints degrades when piped. diff(1)
# is optional too -- without it the report continues and only the difference itself is missing.
_pu_diff() {
    local differ=diff
    command -v diff >/dev/null 2>&1 || { log "    (install diffutils to see the difference here)"; return 0; }
    [[ -t 1 ]] && command -v colordiff >/dev/null 2>&1 && differ=colordiff
    "${differ}" -u "$1" "$2" 2>/dev/null | sed 's/^/    /' || true
}

# _pu_cleanup <rpmnew> <default>: offer to drop the .rpmnew now that it has been dealt with.
_pu_cleanup() {
    local rpmnew="$1" def="$2"
    if ai_tools_msg_confirm "  Remove ${rpmnew}?" "${def}"; then
        rm -f "${rpmnew}" && log "  removed ${rpmnew}"
    else
        log "  kept ${rpmnew}"
    fi
}

# _pu_json <deployed> <rpmnew>: merge the hook declarations the deployed file does not carry.
# The addition list comes from running the merge on a THROWAWAY COPY first, so what the operator
# confirms is the exact set the real merge adds rather than a promise of one, and a merge that
# would fail says so before the real file is touched.
_pu_json() {
    local deployed="$1" rpmnew="$2" scratch status=0
    ai_tools_conf_require_jq || { log "  jq is missing -- cannot read JSON; merge by hand"; return 0; }

    scratch="$(mktemp -d)" || return 0
    cp -p "${deployed}" "${scratch}/probe" 2>/dev/null || { rm -rf "${scratch}"; return 0; }
    ai_tools_conf_merge_hook_declarations "${scratch}/probe" "${rpmnew}" || status=$?
    rm -rf "${scratch}"

    case "${status}" in
    1)  log "  hook declarations are already current -- nothing to merge"
        log "  the difference left is in the permission rules, which are yours to tune:"
        _pu_diff "${deployed}" "${rpmnew}"
        _pu_cleanup "${rpmnew}" n
        return 0 ;;
    2)  log "  cannot merge: ${_ai_tools_conf_merge_reason}"
        log "  ${deployed} is unchanged -- copy the \"hooks\" block from ${rpmnew} by hand"
        return 0 ;;
    esac

    log "  hook declarations this version adds:"
    local line
    for line in "${_ai_tools_conf_merge_added[@]}"; do log "    + ${line}"; done
    log "  nothing else changes -- your permission rules stay as written."
    ai_tools_msg_confirm "  Merge these into ${deployed}?" y || { log "  skipped -- ${deployed} unchanged"; return 0; }

    status=0
    ai_tools_conf_merge_hook_declarations "${deployed}" "${rpmnew}" || status=$?
    if (( status >= 2 )); then
        log "  merge failed: ${_ai_tools_conf_merge_reason} -- ${deployed} is unchanged"
        return 0
    fi
    log "  merged. the previous file is saved as ${_ai_tools_conf_merge_backup}"

    # Offer the cleanup against what is actually left. Once the permission rules match too, the
    # .rpmnew has nothing further to say and keeping it only invites a second look later.
    if command -v diff >/dev/null 2>&1 && diff -q "${deployed}" "${rpmnew}" >/dev/null 2>&1; then
        log "  ${deployed} now matches the shipped file exactly."
        _pu_cleanup "${rpmnew}" y
    else
        log "  the permission rules still differ -- review them before dropping the copy:"
        _pu_diff "${deployed}" "${rpmnew}"
        _pu_cleanup "${rpmnew}" n
    fi
}

# _pu_keyval <deployed> <rpmnew>: report and never write. A KEY=value config is mostly prose --
# commented option blocks whose layout is the operator's -- and merging prose would need a
# convention an operator has to learn before they can predict it. Name the options the new version
# documents that this file does not mention, show the difference, and leave the edit to them.
_pu_keyval() {
    local deployed="$1" rpmnew="$2" key
    local -a new_keys=()
    if ai_tools_conf_new_keys new_keys "${deployed}" "${rpmnew}"; then
        log "  options this version documents that ${deployed} does not mention:"
        for key in "${new_keys[@]}"; do log "    ${key}"; done
        log "  each one is optional and an unmentioned key keeps its default, so leaving them out"
        log "  breaks nothing. Copy the blocks you want; see operator.conf(5)."
    else
        log "  every option this version documents is already mentioned in ${deployed}"
    fi
    log "  the full difference:"
    _pu_diff "${deployed}" "${rpmnew}"
    _pu_cleanup "${rpmnew}" n
}

# _pu_review <deployed> <rpmnew>: show and stop. This file is the sudo grant itself.
_pu_review() {
    local deployed="$1" rpmnew="$2"
    ai_tools_msg_warn \
        "This file defines the sudo grant that lets an operator launch the sandbox. It is shown, never merged: check any change yourself with visudo -c before adopting it."
    _pu_diff "${deployed}" "${rpmnew}"
    log "  adopt the packaged version with:  sudo visudo -c -f ${rpmnew} && sudo cp ${rpmnew} ${deployed}"
    _pu_cleanup "${rpmnew}" n
}

postupgrade() {
    [[ $# -eq 0 ]] || die "usage: ai-tools-admin postupgrade   (takes no arguments)"
    local entry file kind label found=0
    local root="${AI_TOOLS_POSTUPGRADE_ROOT:-}"

    for entry in "${POSTUPGRADE_FILES[@]}"; do
        IFS='|' read -r file kind label <<< "${entry}"
        file="${root}${file}"
        [[ -f "${file}.rpmnew" && -f "${file}" ]] || continue
        found=1
        ai_tools_msg_headline "${label}: ${file}" 1
        case "${kind}" in
            json)   _pu_json   "${file}" "${file}.rpmnew" ;;
            keyval) _pu_keyval "${file}" "${file}.rpmnew" ;;
            review) _pu_review "${file}" "${file}.rpmnew" ;;
        esac
    done

    if (( found == 0 )); then
        log "no .rpmnew files are waiting -- every config file this stack owns is reconciled"
        return 0
    fi
    log "done. this command is idempotent -- re-run it at any time."
}

selinux_dispatch() {
    [[ $# -ge 1 ]] || die "usage: ai-tools-admin selinux <list-groups|enable-group|disable-group> [name]"
    local sub="$1"; shift
    case "${sub}" in
        list-groups)    sel_list ;;
        enable-group)   sel_enable  "$@" ;;
        disable-group)  sel_disable "$@" ;;
        *) die "unknown selinux subcommand '${sub}' (list-groups|enable-group|disable-group)" ;;
    esac
}

# Dispatch: `operator <add|remove|list>` | `selinux <list-groups|enable-group|disable-group>`.
[[ $# -ge 1 ]] || die "usage: ai-tools-admin <operator|selinux|postupgrade> ..."
case "$1" in
    postupgrade)
        shift
        postupgrade "$@"
        ;;
    operator)
        shift
        [[ $# -ge 1 ]] || die "usage: ai-tools-admin operator <add|remove|list> [user]"
        sub="$1"; shift
        case "${sub}" in
            add)    op_add    "$@" ;;
            remove) op_remove "$@" ;;
            list)   op_list   "$@" ;;
            *)      die "unknown operator subcommand '${sub}' (add|remove|list)" ;;
        esac
        ;;
    selinux)
        shift
        selinux_dispatch "$@"
        ;;
    *) die "unknown subcommand '$1' (operator|selinux|postupgrade)" ;;
esac
