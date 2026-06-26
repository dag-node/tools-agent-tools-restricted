#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-enroll
# Enroll one operator -- a login user whose projects the sandbox works on -- as a per-host
# identity the control plane resolves at runtime. The control plane is owned root:ai-tools and
# the agent reaches it through group ai-tools, so binding an operator is a matter of host config,
# not ownership. This is the per-operator setup an RPM %post cannot do (it is specific to one
# user), so the package ships operator-agnostic and this command binds an operator. It:
#   1. writes /etc/ai-tools/operator.conf (PROJECTS_USER/HOME/GROUP), the single source the
#      root helpers and hooks read via operator.lib.sh;
#   2. writes /etc/sudoers.d/ai-tools-claude with the operator as principal (visudo-checked);
#   3. enables linger for the operator and @SANDBOX_USER@, so each has a systemd --user
#      instance (the launch path runs the session in @SANDBOX_USER@'s instance);
#   4. seeds the operator's ~/.config/ai-tools/allowed-projects (empty, with a header) when
#      absent, leaving an existing allowlist untouched;
#   5. captures the control plane's initial state in a root-private git repo (default-deny via
#      the shipped .gitignore), so control-plane drift is reviewable while the committed blobs
#      stay unreadable to the agent and the operators;
#   6. offers (interactively) to wire the host-wide PATH dedup into the operator's ~/.bashrc
#      and ~/.bash_profile, after their nvm init.
#
# @SANDBOX_USER@ gets NO sudo rights (see the generated sudoers): ownership handback goes
# through the handback socket, not sudo. Idempotent: a re-run reconciles operator.conf, the
# sudoers principal, and linger to the named operator and leaves a seeded allowlist in place.
#
# Run as root:
#       sudo ai-tools-enroll [user]        # default: $SUDO_USER
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-enroll.sh /usr/local/sbin/ai-tools/ai-tools-enroll

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly SANDBOX_HOME="/opt/ai-tools"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"
readonly SUDOERS="/etc/sudoers.d/ai-tools-claude"

die() { printf 'ai-tools-enroll: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-enroll: %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"

# Operator: the argument, else the sudo invoker. Never the sandbox account or root -- the
# operator is a normal login user whose home holds the allowlist and whose group co-owns
# project files.
OPERATOR="${1:-${SUDO_USER:-}}"
[[ -n "${OPERATOR}" ]] \
    || die "usage: ai-tools-enroll <user>  (or run via sudo so SUDO_USER is set)"
[[ "${OPERATOR}" != "${SANDBOX_USER}" ]] || die "operator must not be the sandbox account ${SANDBOX_USER}"
[[ "${OPERATOR}" != "root" ]]            || die "operator must be a normal login user, not root"
id "${OPERATOR}" &>/dev/null || die "no such user: ${OPERATOR}"

P_HOME="$(getent passwd "${OPERATOR}" | cut -d: -f6)"
P_GROUP="$(id -gn "${OPERATOR}")"
[[ -n "${P_HOME}" && -d "${P_HOME}" ]] || die "home directory not found for ${OPERATOR}: ${P_HOME:-<none>}"

# Bootstrap-first gate. ai-tools-bootstrap installs the agent's Node toolchain and launcher
# symlink; a host is usable only once they exist, and the git capture below reflects a populated
# tree. The nvm toolchain is the bootstrap signal -- refuse with the ordered steps when it is
# absent, before changing anything.
if [[ ! -s "${SANDBOX_HOME}/.nvm/nvm.sh" ]]; then
    log "the sandbox Node toolchain is not installed (${SANDBOX_HOME}/.nvm absent)."
    log "Run ai-tools-bootstrap before enrolling. Setup order:"
    log "  1. sudo ai-tools-bootstrap              # install nvm + Node + the agent package (network)"
    log "  2. sudo ai-tools-enroll ${OPERATOR}     # bind the operator"
    die "bootstrap not detected; nothing changed"
fi

# 1. Operator identity. 644 root:root: world-readable (the agent hooks and the root helpers
#    both read it; it carries no secret) and root-write-only (the agent cannot rewrite the
#    identity root hands files back to).
log "writing ${OPERATOR_CONF} (operator ${OPERATOR})"
install -d -o root -g root -m 755 /etc/ai-tools
tmp="$(mktemp)"
printf '%s\n' \
    "# ai-tools operator identity -- the human whose projects the sandbox works on." \
    "# Written by ai-tools-enroll; read at runtime by the root helpers and hooks." \
    "PROJECTS_USER=${OPERATOR}" \
    "PROJECTS_HOME=${P_HOME}" \
    "PROJECTS_GROUP=${P_GROUP}" > "${tmp}"
install -o root -g root -m 644 "${tmp}" "${OPERATOR_CONF}"
rm -f "${tmp}"

# 2. Sudoers drop-in. The three grants belong to the operator; the sandbox account holds none.
#    The first two DROP privilege to @SANDBOX_USER@; the third runs the fixed-path, no-argument
#    entrypoint relabel as root. visudo-checked off-line before activation so a parse error can
#    never break sudo. (The fully commented reference lives in the source sudoers template.)
log "writing ${SUDOERS}"
tmp="$(mktemp)"
{
    printf '# /etc/sudoers.d/ai-tools-claude -- generated by ai-tools-enroll for operator %s.\n' "${OPERATOR}"
    printf '# %s has NO sudo rights here; ownership handback goes through the handback socket.\n\n' "${SANDBOX_USER}"
    printf 'Defaults!/opt/ai-tools/bin/claude-run umask=0007,umask_override\n'
    printf 'Defaults!/opt/ai-tools/bin/claude-run env_keep += "CLAUDE_EXEC CLAUDE_PROJECT_DIR"\n'
    printf 'Defaults!/opt/ai-tools/bin/nvm-update.sh env_keep += "AI_TOOLS_GLOBAL_TOOLS NVM_NODE_MAJOR NVM_NODE_ALIAS"\n\n'
    printf '%s ALL=(%s:%s) NOPASSWD: /opt/ai-tools/bin/claude-run\n' "${OPERATOR}" "${SANDBOX_USER}" "${SANDBOX_GROUP}"
    printf '%s ALL=(%s:%s) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*.[0-9]*.[0-9]*\n' "${OPERATOR}" "${SANDBOX_USER}" "${SANDBOX_GROUP}"
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint\n' "${OPERATOR}"
} > "${tmp}"
visudo -cf "${tmp}" >/dev/null || { rm -f "${tmp}"; die "generated sudoers failed the visudo check"; }
install -o root -g root -m 0440 "${tmp}" "${SUDOERS}"
rm -f "${tmp}"

# 3. Linger, so both accounts keep a systemd --user instance without an interactive login --
#    the sandbox session runs in @SANDBOX_USER@'s instance, and the operator's nvm-update timer
#    runs in theirs. A failure is a warning, not fatal (the rest of enrollment still holds).
log "enabling linger for ${OPERATOR} and ${SANDBOX_USER}"
loginctl enable-linger "${OPERATOR}"     2>/dev/null || log "warn: could not enable linger for ${OPERATOR}"
loginctl enable-linger "${SANDBOX_USER}" 2>/dev/null || log "warn: could not enable linger for ${SANDBOX_USER}"

# 4. Seed the operator's allowlist (empty, header only) when absent; never clobber an existing
#    one (it holds the operator's approved projects). 700 .config/ai-tools, 600 allowlist:
#    @SANDBOX_USER@ -- not owner, not in the group, cannot enter the 700 dir -- cannot read it.
cfg="${P_HOME}/.config/ai-tools"
[[ -d "${P_HOME}/.config" ]] || install -d -o "${OPERATOR}" -g "${P_GROUP}" -m 700 "${P_HOME}/.config"
[[ -d "${cfg}" ]]            || install -d -o "${OPERATOR}" -g "${P_GROUP}" -m 700 "${cfg}"
allow="${cfg}/allowed-projects"
if [[ ! -f "${allow}" ]]; then
    log "seeding ${allow}"
    tmp="$(mktemp)"
    printf '%s\n' \
        "# Approved project directories for Claude Code (ai-tools)." \
        "# A plain path allows it (and its contents); a '!'-prefixed path excludes it." \
        "# Manage with the ai-tools CLI rather than by hand:" \
        "#   ai-tools --project-create <dir>   register a real project" \
        "#   ai-tools --sandbox-create <dir>   shallow-clone a repo into the sandbox area" \
        "" > "${tmp}"
    install -o "${OPERATOR}" -g "${P_GROUP}" -m 600 "${tmp}" "${allow}"
    rm -f "${tmp}"
fi

# 5. Capture the control plane's initial state in a git repo so drift is reviewable. The control
#    plane is root:ai-tools, so the repo is root-owned too: run AS root, and lock .git root:root
#    0700 so its committed blobs are unreadable to both the agent (group ai-tools) and the
#    operators. The .gitignore shipped above makes the repo default-deny, so auth tokens,
#    conversation logs, and nvm/npm churn are never staged. Idempotent: skipped when .git already
#    exists. Non-fatal: a missing git or a commit failure (e.g. no root git identity) warns and
#    leaves enrollment intact.
if [[ -d "${SANDBOX_HOME}" && ! -e "${SANDBOX_HOME}/.git" ]]; then
    if command -v git >/dev/null 2>&1; then
        log "capturing initial control-plane state in ${SANDBOX_HOME}/.git"
        _gitrun=(git -C "${SANDBOX_HOME}" -c user.name=ai-tools -c user.email="ai-tools@localhost")
        if "${_gitrun[@]}" init -q -b main \
           && "${_gitrun[@]}" add -A \
           && "${_gitrun[@]}" commit -q -m "Initial control-plane state (ai-tools-enroll)"; then
            log "captured initial control-plane commit"
        else
            log "warn: control-plane git capture incomplete"
        fi
        if [[ -d "${SANDBOX_HOME}/.git" ]]; then
            chown -R root:root "${SANDBOX_HOME}/.git"
            chmod 0700 "${SANDBOX_HOME}/.git"
        fi
    else
        log "warn: git not found; skipping control-plane state capture"
    fi
fi

# 6. Offer to wire the host-wide PATH dedup into the operator's interactive shells. path_dedup.sh
#    reorders PATH so ~/.local/bin (the claude wrapper) wins over the nvm shim, but /etc/profile.d
#    is sourced only by LOGIN shells; an interactive non-login shell (a new terminal tab) reads
#    ~/.bashrc only, so the guard is added to ~/.bashrc and ~/.bash_profile. It must run AFTER
#    nvm.sh (which prepends the shim dir), so it is appended at end-of-file, below any nvm block;
#    nvm's own init is only checked, never written (the operator manages their own nvm). The edit
#    touches the operator's home, so enroll asks first and never rewrites a file non-interactively
#    -- a piped/RPM run prints the manual line instead.
readonly DEDUP_GUARD='[[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh || true'
wire_dedup() {  # $1 = target file (created as the operator if absent)
    local f="$1"
    [[ -e "${f}" ]] || install -o "${OPERATOR}" -g "${P_GROUP}" -m 644 /dev/null "${f}"
    if grep -qF '/etc/profile.d/path_dedup.sh' "${f}"; then
        log "PATH dedup already present in ${f}"; return
    fi
    grep -qF 'NVM_DIR' "${f}" \
        || log "note: NVM_DIR not found in ${f} -- path_dedup still works, but it is meant to follow your nvm init"
    printf '\n# Added by ai-tools-enroll: source the host-wide PATH dedup (must follow nvm init).\n%s\n' \
        "${DEDUP_GUARD}" >> "${f}"
    log "wired PATH dedup into ${f}"
}
_bashrc="${P_HOME}/.bashrc"; _bashprof="${P_HOME}/.bash_profile"
if [[ -t 0 && -e /dev/tty ]]; then
    printf 'ai-tools-enroll: wire the host-wide PATH dedup into %s and %s? [Y]/n ' \
        "${_bashrc}" "${_bashprof}" > /dev/tty
    read -r _reply < /dev/tty || _reply=""
    case "${_reply}" in
        [Nn]*) log "skipped PATH dedup; add this line after your nvm init in ${_bashrc} and ${_bashprof}:"
               log "  ${DEDUP_GUARD}" ;;
        *)     wire_dedup "${_bashrc}"; wire_dedup "${_bashprof}" ;;
    esac
else
    log "non-interactive: not editing shell init. Add this line after your nvm init in ${_bashrc} and ${_bashprof}:"
    log "  ${DEDUP_GUARD}"
fi

log "enrolled ${OPERATOR}. Register projects with:  ai-tools --project-create <dir>"
