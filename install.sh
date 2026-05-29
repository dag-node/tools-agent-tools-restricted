#!/usr/bin/env bash
# install.sh -- install, uninstall, or extend the ai-tools Claude Code sandbox
#
# Usage:
#   sudo ./install.sh install              deploy all files, enable timer
#   sudo ./install.sh uninstall            remove deployed files, disable timer
#   sudo ./install.sh add-project <dir>    add a project to the approved list
#
# RPM integration (future):
#   %post scriptlet   ->  ./install.sh install
#   %preun scriptlet  ->  ./install.sh uninstall
#
# Prerequisites (one-time manual steps before running install):
#   - ai-tools OS user created at /opt/ai-tools  (README step 2)
#   - nvm + Node v22 + claude installed as ai-tools  (README step 3)

set -euo pipefail
IFS=$'\n\t'

readonly ACTION="${1:-install}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Guards ─────────────────────────────────────────────────────────────────────

[[ "${EUID}" -eq 0 ]] \
    || { echo "error: run with sudo" >&2; exit 1; }

REAL_USER="${SUDO_USER:?error: SUDO_USER not set -- invoke via sudo, not as root directly}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
REAL_GROUP="$(id -gn "${REAL_USER}")"
[[ -d "${REAL_HOME}" ]] \
    || { echo "error: home directory ${REAL_HOME} not found" >&2; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { printf 'install: %s\n' "$*"; }
warn() { printf 'install: warn: %s\n' "$*" >&2; }
die()  { printf 'install: error: %s\n' "$*" >&2; exit 1; }

# Create a directory only if it does not already exist, preserving perms on
# existing dirs. Applies owner/mode only to newly created directories.
ensure_dir() {
    local mode="$1" owner="$2" group="$3" dir="$4"
    [[ -d "${dir}" ]] || install -d -o "${owner}" -g "${group}" -m "${mode}" "${dir}"
}

# Install a file after substituting @INSTALL_HOME@ -> REAL_HOME and @INSTALL_USER@ -> REAL_USER.
# Handles files that embed the deploying username (sudoers, chown script, hook).
install_subst() {
    local mode="$1" owner="$2" group="$3" src="$4" dst="$5"
    local tmp
    tmp="$(mktemp)"
    sed -e "s|@INSTALL_HOME@|${REAL_HOME}|g" \
        -e "s/@INSTALL_USER@/${REAL_USER}/g" \
        "${src}" > "${tmp}"
    install -o "${owner}" -g "${group}" -m "${mode}" "${tmp}" "${dst}"
    rm -f "${tmp}"
}

# Run systemctl --user as REAL_USER with the correct runtime environment.
# Emits a warning rather than aborting if the user session is not active.
user_systemctl() {
    local uid
    uid="$(id -u "${REAL_USER}")"
    sudo -u "${REAL_USER}" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        systemctl --user "$@" \
        || warn "systemctl --user $* failed -- run it manually as ${REAL_USER}"
}

# Create /opt/ai-tools/bin/claude -> versioned claude binary directly, without
# running nvm-update.service (which also prunes old Node versions).
# Emits a warning and returns when ai-tools nvm or claude is not yet installed.
bootstrap_claude_symlink() {
    local ai_nvm_dir="/opt/ai-tools/.nvm"
    local ai_tools_bin="/opt/ai-tools/bin"

    if [[ ! -s "${ai_nvm_dir}/nvm.sh" ]]; then
        warn "ai-tools: nvm not found at ${ai_nvm_dir}/nvm.sh -- symlink skipped"
        return
    fi

    local node_version
    node_version="$(sudo -u ai-tools bash -c \
        "source '${ai_nvm_dir}/nvm.sh' --no-use && nvm version default 2>/dev/null" \
        2>/dev/null || true)"

    if [[ -z "${node_version}" || "${node_version}" == "N/A" ]]; then
        warn "ai-tools: nvm 'default' alias not set -- symlink skipped"
        warn "         Install Node as ai-tools then re-run: sudo $0 install"
        return
    fi

    local versioned_claude="${ai_nvm_dir}/versions/node/${node_version}/bin/claude"
    if [[ ! -x "${versioned_claude}" ]]; then
        warn "ai-tools: claude not found at ${versioned_claude} -- symlink skipped"
        warn "         Install @anthropic-ai/claude-code as ai-tools then re-run: sudo $0 install"
        return
    fi

    ensure_dir 755 ai-tools ai-tools "${ai_tools_bin}"
    # Enforce ownership/mode even when the dir pre-existed (README step 3 creates
    # it). /opt/ai-tools/bin must not be group- or world-writable, or any member
    # of its group could swap the claude symlink the wrapper resolves and trust.
    chown ai-tools:ai-tools "${ai_tools_bin}"
    chmod 755 "${ai_tools_bin}"
    sudo -u ai-tools ln -sf "${versioned_claude}" "${ai_tools_bin}/claude"
    log "ai-tools: symlink ${ai_tools_bin}/claude -> ${versioned_claude}"
}

# Check that ~/.local/bin precedes nvm shims in the user's PATH and print a
# notice when it does not. Never modifies .bashrc automatically.
check_path_order() {
    local bashrc="${REAL_HOME}/.bashrc"
    local path_export='export PATH="${HOME}/.local/bin:${PATH}"'

    if grep -qF '.local/bin' "${bashrc}" 2>/dev/null; then
        local local_bin_line nvm_line
        local_bin_line="$(grep -n '.local/bin' "${bashrc}" | head -1 | cut -d: -f1)"
        nvm_line="$(      grep -n 'nvm\.sh'    "${bashrc}" | head -1 | cut -d: -f1)"
        if [[ -n "${nvm_line}" && -n "${local_bin_line}" && "${local_bin_line}" -gt "${nvm_line}" ]]; then
            warn "PATH: ~/.local/bin appears AFTER nvm.sh in ${bashrc}"
            warn "      The nvm shim will shadow ~/.local/bin/claude in new terminals."
            warn "      Move this line to BEFORE the 'source .../nvm.sh' line:"
            warn "        ${path_export}"
        fi
    else
        warn "PATH: ~/.local/bin not found in ${bashrc}"
        warn "      Add this line BEFORE the 'source .../nvm.sh' line so the wrapper"
        warn "      shadows the nvm-managed claude in new terminals:"
        warn "        ${path_export}"
    fi
}

# Restore SELinux file contexts for every path this script deploys.
# No-op when SELinux is disabled or restorecon is not installed.
do_selinux_restore() {
    if ! command -v restorecon &>/dev/null; then
        warn "restorecon not found -- skipping SELinux context restoration"
        return
    fi
    if [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        log "SELinux: disabled, skipping"
        return
    fi
    log "SELinux: restoring file contexts"
    restorecon \
        /usr/local/sbin/ai-tools-chown \
        /etc/sudoers.d/ai-tools-claude \
        /etc/profile.d/path_dedup.sh
    restorecon -R \
        /opt/ai-tools/bin/ \
        /opt/ai-tools/.claude/
    restorecon \
        "${REAL_HOME}/.local/bin/claude" \
        "${REAL_HOME}/.local/bin/nvm-update.sh" \
        "${REAL_HOME}/.config/systemd/user/nvm-update.service" \
        "${REAL_HOME}/.config/systemd/user/nvm-update.timer"
}

# Print a one-line summary row for a single file.
# Returns 1 (and prints MISSING) when the file does not exist.
_summary_row() {
    local file="$1"
    if [[ ! -e "${file}" ]]; then
        printf '  %-54s  MISSING\n' "${file}"
        return 1
    fi
    local owner perms setype
    owner="$(  stat -c '%U:%G' "${file}")"
    perms="$(  stat -c '%a'    "${file}")"
    setype="$( stat -c '%C'    "${file}" 2>/dev/null | cut -d: -f3)"
    [[ "${setype}" == "?" || -z "${setype}" ]] && setype="selinux-off"
    printf '  %-54s  %-22s  %4s  %s\n' "${file}" "${owner}" "${perms}" "${setype}"
}

# Print a summary table of every installed file with owner, mode, and SELinux
# type, then report how many are present vs missing.
do_summary() {
    local -i ok=0 missing=0
    local sep
    sep="$(printf '─%.0s' {1..90})"

    # (( var++ )) evaluates to the old value, which is 0 on the first call and
    # causes set -e to abort. Use plain assignment to avoid that trap.
    _chk() {
        if _summary_row "$1"; then
            ok=$(( ok + 1 ))
        else
            missing=$(( missing + 1 ))
        fi
    }

    printf '\n  %-54s  %-22s  %4s  %s\n' "FILE" "OWNER" "MODE" "SELINUX TYPE"
    printf '  %s\n' "${sep}"

    _chk /usr/local/sbin/ai-tools-chown
    _chk /etc/sudoers.d/ai-tools-claude
    _chk /etc/profile.d/path_dedup.sh
    _chk /opt/ai-tools/bin/nvm-update.sh
    _chk /opt/ai-tools/bin/claude
    _chk /opt/ai-tools/.claude/post-write-hook.sh
    _chk /opt/ai-tools/.claude/settings.json
    _chk "${REAL_HOME}/.local/bin/claude"
    _chk "${REAL_HOME}/.local/bin/nvm-update.sh"
    _chk "${REAL_HOME}/.config/systemd/user/nvm-update.service"
    _chk "${REAL_HOME}/.config/systemd/user/nvm-update.timer"

    printf '  %s\n' "${sep}"
    if (( missing == 0 )); then
        printf '  %d/%d files in place.\n\n' "${ok}" "$(( ok + missing ))"
    else
        printf '  %d/%d files in place -- %d MISSING, check above.\n\n' \
            "${ok}" "$(( ok + missing ))" "${missing}"
    fi
}

# ── add-project ─────────────────────────────────────────────────────────────────
#
# Registers a project directory so Claude Code is permitted to run there and
# the ownership-restoration hook is allowed to act on files within it.
#
# Two registrations are made, both idempotent:
#   ~/.config/ai-tools/allowed-projects  -- wrapper + chown hook allowlist
#   /opt/ai-tools/.gitconfig             -- git safe.directory for ai-tools
#
# git safe.directory does not support prefix matching, so each project needs
# its own entry. This subcommand makes that a single call per project.

add_project() {
    local dir="${1:?usage: add-project <absolute-path>}"
    [[ -d "${dir}" ]] || die "${dir} is not a directory"
    dir="$(realpath -e "${dir}")"

    local allowlist="${REAL_HOME}/.config/ai-tools/allowed-projects"
    [[ -f "${allowlist}" ]] \
        || die "allowlist not found at ${allowlist} -- run 'install' first"

    if ! grep -qxF "${dir}" "${allowlist}"; then
        echo "${dir}" >> "${allowlist}"
        log "allowlist: added ${dir}"
    else
        log "allowlist: ${dir} already listed"
    fi

    if ! git config --file /opt/ai-tools/.gitconfig \
            --get-all safe.directory 2>/dev/null | grep -qxF "${dir}"; then
        git config --file /opt/ai-tools/.gitconfig \
            --add safe.directory "${dir}"
        log "git safe.directory: added ${dir}"
    else
        log "git safe.directory: ${dir} already listed"
    fi
}

# ── install ────────────────────────────────────────────────────────────────────

do_install() {
    id ai-tools &>/dev/null \
        || die "ai-tools user not found -- create it first (README step 2)"

    # --- System files (root-owned) ---

    log "system: /usr/local/sbin/ai-tools-chown"
    install_subst 750 root root \
        "${SCRIPT_DIR}/scripts/ai-tools-chown.sh" \
        /usr/local/sbin/ai-tools-chown

    log "system: /etc/profile.d/path_dedup.sh"
    install -o root -g root -m 644 \
        "${SCRIPT_DIR}/scripts/path_dedup.sh" \
        /etc/profile.d/path_dedup.sh

    log "system: /etc/sudoers.d/ai-tools-claude"
    local tmp_sudoers
    tmp_sudoers="$(mktemp)"
    sed "s/@INSTALL_USER@/${REAL_USER}/g" \
        "${SCRIPT_DIR}/sudoers-ai-tools-claude" > "${tmp_sudoers}"
    visudo -c -f "${tmp_sudoers}" > /dev/null \
        || { rm -f "${tmp_sudoers}"; die "sudoers syntax check failed"; }
    install -o root -g root -m 0440 \
        "${tmp_sudoers}" /etc/sudoers.d/ai-tools-claude
    rm -f "${tmp_sudoers}"

    # --- ai-tools files ---

    log "ai-tools: /opt/ai-tools/bin/nvm-update.sh"
    install -o ai-tools -g ai-tools -m 750 \
        "${SCRIPT_DIR}/scripts/nvm-update-ai-tools.sh" \
        /opt/ai-tools/bin/nvm-update.sh

    log "ai-tools: /opt/ai-tools/.claude/"
    ensure_dir 750 ai-tools ai-tools /opt/ai-tools/.claude
    install_subst 750 ai-tools ai-tools \
        "${SCRIPT_DIR}/scripts/post-write-hook.sh" \
        /opt/ai-tools/.claude/post-write-hook.sh
    install -o ai-tools -g ai-tools -m 640 \
        "${SCRIPT_DIR}/scripts/claude-settings.json" \
        /opt/ai-tools/.claude/settings.json

    # --- User files ---

    log "user: ${REAL_HOME}/.local/bin/"
    ensure_dir 700 "${REAL_USER}" "${REAL_GROUP}" "${REAL_HOME}/.local"
    ensure_dir 700 "${REAL_USER}" "${REAL_GROUP}" "${REAL_HOME}/.local/bin"
    install -o "${REAL_USER}" -g "${REAL_GROUP}" -m 750 \
        "${SCRIPT_DIR}/scripts/claude-wrapper.sh" \
        "${REAL_HOME}/.local/bin/claude"
    install -o "${REAL_USER}" -g "${REAL_GROUP}" -m 750 \
        "${SCRIPT_DIR}/scripts/nvm-update.sh" \
        "${REAL_HOME}/.local/bin/nvm-update.sh"

    log "user: ${REAL_HOME}/.config/systemd/user/"
    ensure_dir 755 "${REAL_USER}" "${REAL_GROUP}" "${REAL_HOME}/.config"
    ensure_dir 755 "${REAL_USER}" "${REAL_GROUP}" "${REAL_HOME}/.config/systemd"
    ensure_dir 700 "${REAL_USER}" "${REAL_GROUP}" "${REAL_HOME}/.config/systemd/user"
    install -o "${REAL_USER}" -g "${REAL_GROUP}" -m 644 \
        "${SCRIPT_DIR}/services/nvm-update.service" \
        "${REAL_HOME}/.config/systemd/user/nvm-update.service"
    install -o "${REAL_USER}" -g "${REAL_GROUP}" -m 644 \
        "${SCRIPT_DIR}/services/nvm-update.timer" \
        "${REAL_HOME}/.config/systemd/user/nvm-update.timer"

    # --- Allowlist (create with format header if absent) ---

    ensure_dir 700 "${REAL_USER}" "${REAL_USER}" "${REAL_HOME}/.config/ai-tools"
    local allowlist="${REAL_HOME}/.config/ai-tools/allowed-projects"
    if [[ ! -f "${allowlist}" ]]; then
        log "config: creating ${allowlist}"
        printf '%s\n' \
            "# Approved project directories for Claude Code (ai-tools)." \
            "#" \
            "# Syntax:" \
            "#   /path/to/project      allow: Claude Code may run here; chown is active" \
            "#   !/path/to/file        exclude: this file's ownership is never changed" \
            "#   !/path/to/dir         exclude directory and all contents" \
            "#   !/path/to/*.ext       exclude by glob (* matches any characters)" \
            "#" \
            "# Exclusions (!) override allows and are checked first." \
            "# Plain paths cover their contents automatically; no trailing /* needed." \
            "" > "${allowlist}"
        chown "${REAL_USER}:${REAL_USER}" "${allowlist}"
        chmod 600 "${allowlist}"
    fi

    # Register this project in allowlist + git safe.directory
    add_project "${SCRIPT_DIR}"

    # --- Systemd ---

    log "systemd: enabling linger for ${REAL_USER}"
    loginctl enable-linger "${REAL_USER}"

    log "systemd: reload and enable nvm-update.timer"
    user_systemctl daemon-reload
    user_systemctl enable --now nvm-update.timer

    bootstrap_claude_symlink
    check_path_order

    do_selinux_restore
    do_summary

    printf 'Verify timer is scheduled:\n'
    printf '  systemctl --user list-timers nvm-update.timer\n\n'
    printf 'For each additional project:\n'
    printf '  sudo %s/install.sh add-project /path/to/project\n\n' "${SCRIPT_DIR}"
}

# ── uninstall ──────────────────────────────────────────────────────────────────

do_uninstall() {
    log "systemd: disable nvm-update.timer"
    user_systemctl disable --now nvm-update.timer 2>/dev/null || true
    user_systemctl daemon-reload 2>/dev/null || true

    log "removing system files"
    rm -f /usr/local/sbin/ai-tools-chown
    rm -f /etc/sudoers.d/ai-tools-claude
    rm -f /etc/profile.d/path_dedup.sh

    log "removing ai-tools files"
    rm -f /opt/ai-tools/bin/nvm-update.sh
    rm -f /opt/ai-tools/.claude/post-write-hook.sh
    rm -f /opt/ai-tools/.claude/settings.json

    log "removing user files"
    rm -f "${REAL_HOME}/.local/bin/claude"
    rm -f "${REAL_HOME}/.local/bin/nvm-update.sh"
    rm -f "${REAL_HOME}/.config/systemd/user/nvm-update.service"
    rm -f "${REAL_HOME}/.config/systemd/user/nvm-update.timer"

    # Optionally prune this project from the allowlist (default: keep)
    local allowlist="${REAL_HOME}/.config/ai-tools/allowed-projects"
    if [[ -f "${allowlist}" ]] && grep -qxF "${SCRIPT_DIR}" "${allowlist}"; then
        {
            printf '\nKeep in allowed-projects? (Enter = yes)\n'
            printf '  %s\n' "${SCRIPT_DIR}"
            printf '[Y/n]: '
        } > /dev/tty
        read -r _resp < /dev/tty
        if [[ "${_resp}" =~ ^[nN] ]]; then
            local escaped
            escaped="$(printf '%s' "${SCRIPT_DIR}" | sed 's/[\\|]/\\&/g')"
            sed -i "\|^${escaped}$|d" "${allowlist}"
            log "allowed-projects: removed"
        else
            log "allowed-projects: kept"
        fi
    fi

    # Optionally prune this project from git safe.directory (default: keep)
    local git_escaped
    git_escaped="$(printf '%s' "${SCRIPT_DIR}" | sed 's/[.^$*+?{|\\[()\]]/\\&/g')"
    if git config --file /opt/ai-tools/.gitconfig \
            --get-all safe.directory 2>/dev/null | grep -qxF "${SCRIPT_DIR}"; then
        {
            printf '\nKeep in git safe.directory? (Enter = yes)\n'
            printf '  %s\n' "${SCRIPT_DIR}"
            printf '[Y/n]: '
        } > /dev/tty
        read -r _resp < /dev/tty
        if [[ "${_resp}" =~ ^[nN] ]]; then
            git config --file /opt/ai-tools/.gitconfig \
                --unset-all safe.directory "^${git_escaped}$" 2>/dev/null || true
            log "git safe.directory: removed"
        else
            log "git safe.directory: kept"
        fi
    fi

    log "done"
    printf '\nAlways preserved:\n'
    printf '  /opt/ai-tools/.nvm/    nvm and Node installation\n'
    printf '  ~/.config/ai-tools/    allowlist and user configuration (unless n above)\n'
    printf '  git safe.directory     project registration (unless n above)\n\n'
}

# ── dispatch ───────────────────────────────────────────────────────────────────

case "${ACTION}" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    add-project)
        add_project "${2:?usage: sudo $0 add-project <directory>}"
        ;;
    *)
        printf 'usage: sudo %s [install|uninstall|add-project <dir>]\n' "$0" >&2
        exit 1
        ;;
esac
