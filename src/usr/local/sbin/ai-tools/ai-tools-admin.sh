#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-admin
# Host administration for the ai-tools sandbox. A root helper (run via sudo), not an ai-tools
# CLI verb: it edits host config (the OPERATORS list, the ai-ops group, the sandbox account's
# linger) while the ai-tools CLI is unprivileged and refuses to run as root. The ai-tools-admin name
# leaves room for further root-side admin subcommands beside operator management.
#
#   sudo ai-tools-admin operator add [user]     # default: $SUDO_USER
#   sudo ai-tools-admin operator remove <user>
#   sudo ai-tools-admin operator list
#
# An operator is a login user (a human or a rootless service account) that drives the sandbox
# through the shared ai-tools account. `add` is accumulating and idempotent: it appends the
# name to OPERATORS in /etc/ai-tools/operator.conf, adds the user to the ai-ops group (the
# sudoers grant and the launch wrapper gate on membership), seeds the user's allowlist, ensures
# the sandbox account's linger, and offers to wire the PATH dedup. `remove` reverses the host-side
# membership (drops the name from OPERATORS and ai-ops), leaving the user's own allowlist and config.
# `list` prints the current operators.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-admin.sh /usr/local/sbin/ai-tools/ai-tools-admin

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly OPERATORS_GROUP="ai-ops"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"

die() { printf 'ai-tools-admin: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-admin: %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"

# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
. "${OPERATOR_LIB}" || die "cannot source ${OPERATOR_LIB}"

# write_operators <name>...: rewrite operator.conf with the given operator list (root:root 644).
# 644: world-readable (the agent hooks and the root helpers both read it; it carries no secret)
# and root-write-only, so the agent cannot rewrite the identity root hands files back to.
write_operators() {
    install -d -o root -g root -m 755 /etc/ai-tools
    local tmp; tmp="$(mktemp)"
    printf '%s\n' \
        "# ai-tools operators -- the login users whose projects the sandbox works on." \
        "# Managed by ai-tools-admin; read at runtime by the root helpers and hooks." \
        "OPERATORS=\"$*\"" > "${tmp}"
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

# wire_dedup <user>: offer (interactively) to source the host-wide PATH dedup from the operator's
# ~/.bashrc and ~/.bash_profile after their nvm init, so ~/.local/bin wins over the nvm shim in
# every shell. Edits the operator's home, so it asks first and never rewrites non-interactively;
# a piped run prints the line to add.
readonly DEDUP_GUARD='[[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh || true'
wire_dedup() {
    local user="$1" home group bashrc bashprof reply f
    home="$(getent passwd "${user}" | cut -d: -f6)"
    group="$(id -gn "${user}")"
    [[ -n "${home}" && -d "${home}" ]] || return 0
    bashrc="${home}/.bashrc"; bashprof="${home}/.bash_profile"
    _wire_one() {
        f="$1"
        [[ -e "${f}" ]] || install -o "${user}" -g "${group}" -m 644 /dev/null "${f}"
        if grep -qF '/etc/profile.d/path_dedup.sh' "${f}"; then
            log "PATH dedup already present in ${f}"; return
        fi
        grep -qF 'NVM_DIR' "${f}" \
            || log "note: NVM_DIR not found in ${f} -- path_dedup still works, but it is meant to follow your nvm init"
        printf '\n# Added by ai-tools-admin: source the host-wide PATH dedup (must follow nvm init).\n%s\n' \
            "${DEDUP_GUARD}" >> "${f}"
        log "wired PATH dedup into ${f}"
    }
    if [[ -t 0 && -e /dev/tty ]]; then
        printf 'ai-tools-admin: wire the host-wide PATH dedup into %s and %s? [Y]/n ' \
            "${bashrc}" "${bashprof}" > /dev/tty
        read -r reply < /dev/tty || reply=""
        case "${reply}" in
            [Nn]*) log "skipped PATH dedup; add this line after your nvm init in ${bashrc} and ${bashprof}:"
                   log "  ${DEDUP_GUARD}" ;;
            *)     _wire_one "${bashrc}"; _wire_one "${bashprof}" ;;
        esac
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
    # nvm-update timer and each claude-run session unit run there, and it has no login shell, so
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

# Dispatch: `operator <add|remove|list> [args]`.
[[ $# -ge 1 ]] || die "usage: ai-tools-admin operator <add|remove|list> [user]"
case "$1" in
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
    *) die "unknown subcommand '$1' (operator)" ;;
esac
