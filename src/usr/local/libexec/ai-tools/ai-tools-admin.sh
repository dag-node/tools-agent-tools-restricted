#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-admin
# Host administration for the ai-tools sandbox. A root helper (run via sudo), not an ai-tools
# CLI verb: it edits host config (the OPERATORS list, the ai-ops group, the sandbox account's
# linger; the loaded optional SELinux policy groups) while the ai-tools CLI is unprivileged and
# refuses to run as root.
#
#   sudo ai-tools-admin operators                          # list (the zero-argument default)
#   sudo ai-tools-admin operators add [user]               # default: $SUDO_USER
#   sudo ai-tools-admin operators remove <user>
#   sudo ai-tools-admin selinux groups                     # show core + optional group state
#   sudo ai-tools-admin selinux groups enable <name>       # load a prebuilt (stable) group
#   sudo ai-tools-admin selinux groups disable <name>      # unload one
#   sudo ai-tools-admin system post-upgrade                # reconcile the .rpmnew files upgrades leave
#
# The spelling is the project's command grammar (.claude/rules/cli-grammar.rule.md): a bare-word
# command, a plural collection, the verb after the noun, `list` as the zero-argument default, and
# a singular domain (`selinux`, `system`) where one is needed. `--` introduces an option and
# never a command, which here is `--help`/`-h` and `--version`.
#
# An operator is a login user (a human or a rootless service account) that drives the sandbox
# through the shared ai-tools account. `add` is accumulating and idempotent: it appends the
# name to OPERATORS in /etc/ai-tools/operator.conf, adds the user to the ai-ops group (the
# sudoers grant and the launch wrapper gate on membership), seeds the user's allowlist, ensures
# the sandbox account's linger, and offers to wire the PATH dedup. `remove` reverses the host-side
# membership (drops the name from OPERATORS and ai-ops), leaving the user's own allowlist and config.
# `list` prints the current operators.
#
# `selinux groups` toggles the optional policy groups (systemd/pkgmgmt/netadmin/podman/tmpmap/apphost/netcore), all off
# by default. It loads the PREBUILT ai_tools_<group>.pp shipped in the base package via semodule --
# no source tree or selinux-policy-devel needed on the host. The group set, descriptions, and
# per-group stability are single-sourced from selinux-groups.lib.sh, shared with
# selinux/install-selinux.sh (the source-tree authoring tool that instead COMPILES a group; this
# operator helper only loads a shipped one). Only STABLE groups ship prebuilt (currently tmpmap);
# `groups enable` of an EXPERIMENTAL (unaudited) group is refused with a pointer to the source
# compile-and-verify workflow (install-selinux.sh + the avc bring-up loop), since this tool will
# not load an unaudited module. `groups disable` works for any loaded group, stable or not.
#
# `system post-upgrade` reconciles the `<file>.rpmnew` copies an upgrade leaves beside the
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

# Substituted at deploy time (install.sh install_subst from packaging/VERSION; the RPM from
# %{version}), and left as the literal token in the checkout -- which `--version` reports as
# `dev`, the same value and the same fallback the CLI uses.
AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_VERSION}" == @*@ ]] && AI_TOOLS_VERSION="dev"
readonly AI_TOOLS_VERSION

die() { printf 'ai-tools-admin: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-admin: %s\n' "$*"; }

# reject <message>: the command line was rejected. Exit 2 separates a command nobody can type
# correctly from an operation that ran and failed (`die`, exit 1), which is the split
# ai-tools-admin(8) documents and the one ai-tools(1) already uses.
reject() {
    printf 'ai-tools-admin: %s\n' "$*" >&2
    printf "try 'ai-tools-admin --help'\n" >&2
    exit 2
}

# usage: the command surface, grouped by domain. Orientation rather than reference -- every
# option, exit code and example is in ai-tools-admin(8), and tests/unit/man.sh holds the two in
# agreement on the command set.
usage() {
    cat <<EOF
ai-tools-admin -- administer the ai-tools host: operators, SELinux groups, upgrades

  Operators
    operators                        the enrolled operators
    operators add [user]             enrol an operator (default: \$SUDO_USER)
    operators remove <user>          withdraw an operator's enrolment
  SELinux
    selinux groups                   the core module and the optional groups
    selinux groups enable <name>     load a prebuilt optional group
    selinux groups disable <name>    unload a loaded group
  System
    system post-upgrade              reconcile the .rpmnew files an upgrade leaves

    --version                        the installed version
    --help                           this summary

  Run every command through sudo: each one administers the host and refuses a
  non-root caller. The project lifecycle is the unprivileged ai-tools CLI, which
  you run as yourself.

  Every command, exit code and example:  man ai-tools-admin
EOF
}

# Executed, this administers a host and needs root. Sourced -- by tests/unit/admin-operator-add.sh,
# which drives one function with sudo stubbed -- it does not assert anything about the host and only
# defines, stopping at the matching guard above the dispatch. Everything between the two is
# definitions, so the executed path still refuses a non-root caller before any action.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # --help and --version read no host state and leave the host as it is, so they answer any caller and
    # are handled here, ahead of the root check: an operator meeting the tool gets the command
    # surface rather than a refusal naming sudo without saying what to run under it. Both ignore
    # any further argument.
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --version) printf 'ai-tools-admin %s\n' "${AI_TOOLS_VERSION}"; exit 0 ;;
    esac
    [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
fi

# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
. "${OPERATOR_LIB}" || die "cannot source ${OPERATOR_LIB}"

# Optional SELinux policy-group registry + predicates, shared with install-selinux.sh.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/selinux-groups.lib.sh
. "${SELINUX_GROUPS_LIB}" || die "cannot source ${SELINUX_GROUPS_LIB}"

# The shared config grammar, sidecar handling, and hook-declaration merge that `system post-upgrade`
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
# agent hooks and the root helpers both read it; it is free of secrets) and root-write-only,
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
        "# Approved project directories for Claude Code (ai-tools) -- one directory per line." \
        "# A plain path allows that directory and everything under it; a '!'-prefixed path" \
        "# excludes one. Exclusions win over allows, and only they may use * ? [ ] globs --" \
        "# an allow line must be a literal directory (a glob there matches nothing and is inert)." \
        "#" \
        "# '#' starts a comment, whole-line or after a path; quote a path that contains a space" \
        "# or a literal '#', e.g.  \"/home/me/my project\"" \
        "#" \
        "# Managed by the ai-tools CLI -- prefer it over editing by hand:" \
        "#   ai-tools --project-create <dir>   create a new project directory and claim it" \
        "#   ai-tools --project-claim  <dir>   register/claim a real project in place" \
        "#   ai-tools --sandbox-create <dir>   shallow-clone a repo into the sandbox area" \
        "#   ai-tools --list                   review entries; flags stale/unusable/orphaned ones" \
        "" > "${tmp}"
    install -o "${user}" -g "${group}" -m 600 "${tmp}" "${allow}"
    rm -f "${tmp}"
}

# The line an operator's bash init carries: sources the PATH dedup when it is installed, and
# leaves the shell's own PATH standing when it is not.
readonly DEDUP_GUARD='[[ -f /usr/local/lib/ai-tools/path-dedup.sh ]] && source /usr/local/lib/ai-tools/path-dedup.sh || true'

# wire_init_file <file> <user> <group> [login-chain] : add the guard line to one bash init file,
# creating it owned by the account when it is absent. Idempotent -- a file already naming the
# fragment is left as it is. `login-chain` seeds a created file with the `. ~/.bashrc` block EL's
# skel carries, which the caller passes for ~/.bash_profile alone: bash reads that file by itself
# at login, so one holding only the guard line would leave a login shell without the account's own
# .bashrc, its nvm init among it. Top-level so tests/unit/admin-operator-add.sh drives it against
# its own fixture files, apart from the prompt in wire_dedup.
wire_init_file() {
    local f="$1" user="$2" group="$3" seed="${4-}"
    if [[ ! -e "${f}" ]]; then
        install -o "${user}" -g "${group}" -m 644 /dev/null "${f}" || return 1
        [[ "${seed}" == login-chain ]] && printf '%s\n' \
            "# Created by ai-tools-admin: read this account's .bashrc at login." \
            'if [ -f ~/.bashrc ]; then' '    . ~/.bashrc' 'fi' >> "${f}"
    fi
    if grep -qF '/usr/local/lib/ai-tools/path-dedup.sh' "${f}"; then
        log "PATH dedup already present in ${f}"; return 0
    fi
    grep -qF 'NVM_DIR' "${f}" \
        || log "note: NVM_DIR not found in ${f} -- path-dedup still works, but it is meant to follow your nvm init"
    printf '\n# Added by ai-tools-admin: source the ai-tools PATH dedup (must follow nvm init).\n%s\n' \
        "${DEDUP_GUARD}" >> "${f}"
    log "wired PATH dedup into ${f}"
}

# wire_dedup <user>: offer (interactively) to source the ai-tools PATH dedup from the operator's
# ~/.bashrc and ~/.bash_profile after their nvm init, so /usr/local/bin (the claude wrapper) wins
# over the nvm shim in the operator's bash shells. This wiring is the dedup's only delivery: the
# file lives in the ai-tools lib dir, not /etc/profile.d, so unwired accounts keep their stock
# PATH. Those two files are what bash reads, so an account that logs in through another shell is
# told where its own ordering stands. Edits the operator's home, so it asks first and never
# rewrites non-interactively; a piped run prints the line to add.
wire_dedup() {
    local user="$1" home group login_shell bashrc bashprof
    home="$(getent passwd "${user}" | cut -d: -f6)"
    login_shell="$(getent passwd "${user}" | cut -d: -f7)"
    group="$(id -gn "${user}")"
    [[ -n "${home}" && -d "${home}" ]] || return 0
    bashrc="${home}/.bashrc"; bashprof="${home}/.bash_profile"
    # The two files below govern bash. Another login shell reads its own, so the operator hears
    # which ordering their sessions actually get, at the moment the wiring is offered.
    case "${login_shell}" in
        */bash|'') ;;
        *) log "note: ${user}'s login shell is ${login_shell}, which reads its own init files rather than ${bashrc} or ${bashprof}."
           log "      rank /usr/local/bin ahead of the nvm shims there too, so that typing claude reaches the ai-tools wrapper in that shell" ;;
    esac
    if [[ -t 0 && -e /dev/tty ]]; then
        if ai_tools_msg_confirm \
            "Wire the ai-tools PATH dedup into ${bashrc} and ${bashprof}?" y; then
            wire_init_file "${bashrc}"   "${user}" "${group}"
            wire_init_file "${bashprof}" "${user}" "${group}" login-chain
        else
            log "skipped PATH dedup; add this line after your nvm init in ${bashrc} and ${bashprof}:"
            log "  ${DEDUP_GUARD}"
        fi
    else
        log "non-interactive: not editing shell init. Add this line after your nvm init in ${bashrc} and ${bashprof}:"
        log "  ${DEDUP_GUARD}"
    fi
}

# report_operator_role <user> -- say which of the two operator shapes this enrolment produced,
# where the decision is being made rather than where it first fails.
#
# This command writes both facts that make an operator (ai-ops membership, a name in OPERATORS)
# and CANNOT write the third thing a claim needs: a general sudo grant, which the host's own
# sudoers decides. Group membership cannot imply a sudoers rule, so the only way to know is to
# ask sudo -- and running as root, it can ask on the enrolled account's behalf without a password.
# The probe names ai-tools-lockdown because the secret gate is a claim's first sudo, so it answers
# the question the administrator actually has: can this account claim a project?
#
# An account without the grant is a supported shape, not a misconfiguration, so this reports and
# never refuses: it names the --for command that claims on the account's behalf.
#
# A non-zero answer is a refusal only while sudo is answering at all -- for a command no rule
# matches, `sudo -l` exits non-zero with EMPTY output, so there is no message separating that from
# a sudo which failed for its own reasons (an unreachable sudoers backend, a host that refuses -l).
# It is separated by a second probe, the same way the CLI's sudo_grant_missing does it: listing the
# account's whole rule set, which succeeds for anyone this command has just enrolled, since the
# %ai-ops rules apply to the membership written moments earlier (sudo reads the group database, not
# a cached credential). Only a first probe refused while the second answers is read as "no grant";
# anything else is reported as undetermined, because a wrong verdict here is acted on immediately.
report_operator_role() {
    local user="$1"
    local claim_helper="/usr/local/libexec/ai-tools/ai-tools-lockdown"
    if ! command -v sudo >/dev/null 2>&1; then
        log "${user}: no sudo on this host, so no project can be claimed by anyone -- ${user} can still launch agent sessions"
        return 0
    fi
    if LC_ALL=C sudo -l -U "${user}" "${claim_helper}" >/dev/null 2>&1; then
        log "${user} holds a general sudo grant: it can claim projects as well as launch sessions"
        return 0
    fi
    if ! LC_ALL=C sudo -l -U "${user}" >/dev/null 2>&1; then
        log "${user}: sudo did not answer, so whether ${user} holds a general sudo grant is undetermined -- check with: sudo -l -U ${user}"
        return 0
    fi
    log "${user} holds no general sudo grant: it can launch agent sessions and read the reports, and cannot claim a project"
    log "${user}: claim on its behalf from an operator that holds one -- ai-tools --project-claim --for ${user} <path>"
}

op_add() {
    local user="${1:-${SUDO_USER:-}}"
    [[ -n "${user}" ]] || reject "operators add: name a user, or run it through sudo so SUDO_USER is set"
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
    # so it does not need linger here; enabling operator linger for other reasons is host policy.
    log "enabling linger for ${SANDBOX_USER}"
    loginctl enable-linger "${SANDBOX_USER}"  2>/dev/null || log "warn: could not enable linger for ${SANDBOX_USER}"

    wire_dedup "${user}"
    log "operator ${user} added"
    report_operator_role "${user}"
    # ai-ops membership applies to NEW login sessions; an already-open shell keeps the credential
    # set it had at login, and the launch wrapper gates on that live set. Name the activation step
    # so the operator's first claude launch does not hit the stale-session refusal.
    log "${user}: start a new login session (or run 'newgrp ${OPERATORS_GROUP}') before launching claude -- ${OPERATORS_GROUP} membership does not apply to already-open shells"
}

op_remove() {
    local user="${1:-}"
    [[ -n "${user}" ]] || reject "operators remove: name the user to withdraw"
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

# ── selinux groups: optional policy-group management ─────────────────────────────────
# These load/unload the PREBUILT ai_tools_<group>.pp shipped in the base package; the group
# set and text come from selinux-groups.lib.sh. Distinct from selinux/install-selinux.sh,
# which compiles a group from source in a repo checkout -- this runs on any installed host.

# require_selinux: guard shared by every selinux command. Returns 1 (caller exits 0 --
# no policy to manage) when SELinux is disabled; dies when semodule is absent (a real gap).
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
    [[ $# -le 1 ]] || reject "selinux groups enable: one group name at a time"
    [[ -n "${name}" && "${name}" != -* ]] || reject "selinux groups enable: name the group to load"
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
    [[ $# -le 1 ]] || reject "selinux groups disable: one group name at a time"
    [[ -n "${name}" && "${name}" != -* ]] || reject "selinux groups disable: name the group to unload"
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

# sel_list is a read-only REPORT, not operational output, so it renders as a plain section (like
# the CLI's --providers/--list) instead of `log`'s per-line `ai-tools-admin:` prefix. The core
# module uses the same bracketed [LOADED]/[disabled] state column as the group rows for one legend.
sel_list() {
    require_selinux || return 0
    local core_state='[disabled]' modules
    # Captured, not piped into `grep -q`: an early-exiting reader makes semodule die of SIGPIPE
    # and pipefail then reports the probe failed -- see ai_tools_selinux_group_loaded.
    modules="$(semodule -l 2>/dev/null || true)"
    grep -qx 'ai_tools' <<<"${modules}" && core_state='[LOADED]  '
    printf '\nSELinux policy groups\n\n'
    printf '  %s core module (ai_tools) -- the confinement domain; DAC-only when disabled\n\n' "${core_state}"
    printf '  optional groups (all default: disabled)\n'
    local entry name desc stability state
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        desc="$(ai_tools_selinux_group_desc "${entry}")"
        stability="$(ai_tools_selinux_group_stability "${entry}")"
        if ai_tools_selinux_group_loaded "${name}"; then state='[LOADED]  '; else state='[disabled]'; fi
        printf '    %s %-9s %-15s %s\n' "${state}" "${name}" "(${stability})" "${desc}"
    done
    printf '\n  toggle       : sudo ai-tools-admin selinux groups enable <name> | disable <name>\n'
    printf '  experimental : not shipped prebuilt -- enable from a source checkout with\n'
    printf '                 sudo selinux/install-selinux.sh enable-group <name>\n'
}

# ── system post-upgrade: reconcile the .rpmnew files an upgrade leaves ───────────────────────
# rpm keeps an operator-modified %config(noreplace) file and parks the package's copy beside it as
# <file>.rpmnew. Choosing between the two is a judgement call about the operator's own
# configuration, so no scriptlet makes it: this is the explicit, interactive command that does, and
# it is what the install output points at. Every treatment confirms first, backs the file up before
# writing, and names each path it touched.
#
# The treatment follows the file's CONTENT, rather than one generic merge covering all three:
#   json    hook DECLARATIONS merge additively -- they are control plane, and a declaration the
#           file lacks means a shipped hook installs but no event invokes it. The permission arrays
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
    # .rpmnew has no difference left to report and keeping it only invites a second look later.
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
    [[ $# -eq 0 ]] || reject "system post-upgrade: takes no arguments"
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

# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
# One arm per name in the grammar's two shapes: `<collection> [verb]`, where the absent verb is
# `list`, and `<domain> <collection|verb>`. A bare collection lists; a bare domain prints its own
# commands, since a domain has no reading that a default could safely take and every verb under
# one of these mutates the host.

operators_dispatch() {
    local verb="${1:-list}"; [[ $# -eq 0 ]] || shift
    case "${verb}" in
        list)   op_list   "$@" ;;
        add)    op_add    "$@" ;;
        remove) op_remove "$@" ;;
        *)      reject "unknown command 'operators ${verb}' (list|add|remove)" ;;
    esac
}

selinux_groups_dispatch() {
    local verb="${1:-list}"; [[ $# -eq 0 ]] || shift
    case "${verb}" in
        list)    sel_list ;;
        enable)  sel_enable  "$@" ;;
        disable) sel_disable "$@" ;;
        *)       reject "unknown command 'selinux groups ${verb}' (list|enable|disable)" ;;
    esac
}

selinux_dispatch() {
    [[ $# -ge 1 ]] || reject "selinux owns one collection: 'selinux groups [list|enable|disable]'"
    local resource="$1"; shift
    case "${resource}" in
        groups) selinux_groups_dispatch "$@" ;;
        *)      reject "unknown command 'selinux ${resource}' (groups)" ;;
    esac
}

system_dispatch() {
    [[ $# -ge 1 ]] || reject "system takes a verb: 'system post-upgrade'"
    local verb="$1"; shift
    case "${verb}" in
        post-upgrade) postupgrade "$@" ;;
        *)            reject "unknown command 'system ${verb}' (post-upgrade)" ;;
    esac
}

# Sourced rather than executed (see the note at the root check): stop here with every function
# defined and no command dispatched, so the caller's arguments are not read as a command.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

# --help/-h and --version are answered above, before the root check.
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in
    operators) shift; operators_dispatch "$@" ;;
    selinux)   shift; selinux_dispatch   "$@" ;;
    system)    shift; system_dispatch    "$@" ;;
    *) printf 'ai-tools-admin: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
