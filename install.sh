#!/usr/bin/env bash
# install.sh -- install, uninstall, or extend the ai-tools Claude Code sandbox
#
# Usage:
#   sudo ./install.sh install              deploy all files, enable timer
#   sudo ./install.sh uninstall            remove deployed files, disable timer
#   sudo ./install.sh check-perms          run the permissions test (tests/integration/perms.sh; also part of the suite offered at the end of an interactive install)
#
# Project registration lives in the `ai-tools` CLI (/usr/local/bin/ai-tools), run
# as the projects user, not in install.sh:
#   ai-tools --project-create <dir>        register a real project
#   ai-tools --sandbox-create <dir>        shallow-clone a repo into the sandbox area
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
VERSION="$(git -C "${SCRIPT_DIR}" describe --tags --always 2>/dev/null || echo 'dev')"
readonly VERSION

# ── Guards ─────────────────────────────────────────────────────────────────────

[[ "${EUID}" -eq 0 ]] \
    || { echo "error: run with sudo" >&2; exit 1; }

PROJECTS_USER="${SUDO_USER:?error: SUDO_USER not set -- invoke via sudo, not as root directly}"
PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" | cut -d: -f6)"
PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}")"
[[ -d "${PROJECTS_HOME}" ]] \
    || { echo "error: home directory ${PROJECTS_HOME} not found" >&2; exit 1; }

# Sandbox service account the agent runs as. This is only a PARTIAL knob: owner
# strings and the sudoers principal/runas spec (the @SANDBOX_USER@/@SANDBOX_GROUP@
# tokens and the -g/-o/-u arguments below) follow these vars, but the account name
# is also baked into paths (/opt/ai-tools), SELinux types (ai_tools_t), and helper
# binary names (ai-tools-chown), which stay literal. Renaming the account in full
# requires changing those too. See docs/naming-conventions.md.
readonly SANDBOX_USER="ai-tools"
readonly SANDBOX_GROUP="ai-tools"

# ── Helpers ────────────────────────────────────────────────────────────────────

# Styled output, mirroring the ai-tools CLI so install and day-to-day management
# read the same. Colours only on a TTY; piped/redirected output stays plain.
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RED=$'\033[31m' C_RST=$'\033[0m'
else
    readonly C_BOLD='' C_DIM='' C_GRN='' C_YEL='' C_RED='' C_RST=''
fi

say()     { printf '%s\n' "$*"; }
section() { printf '\n%s── %s ──%s\n' "${C_BOLD}" "$*" "${C_RST}"; }
ok()      { printf '  %s✓%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
# log: a dim checklist bullet for each deployed file / action.
log()     { printf '  %s+%s %s\n' "${C_DIM}" "${C_RST}" "$*"; }
warn()    { printf '  %s!%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()     { printf '%sinstall: error:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

# Shared message formatter, sourced from the SOURCE TREE (the installed copy may not exist
# yet -- this script installs it). Frames interactive prompts in the '#' box. Best-effort:
# a plain fallback keeps the installer working if the file is missing.
readonly MSG_LIB="${SCRIPT_DIR}/src/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=/dev/null
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg_block() { shift; printf '%s\n' "$@" >&2; }
fi

# ask <title> <question> <context-line...> -- the one interactive prompt shape, so every
# prompt in the install flow looks the same:
#   * a FIXED 80-column box (AI_TOOLS_MSG_FULLWIDTH) titled <title>, framing the context,
#   * the inline <question> (carry its own [Y/n]/[y/N] hint),
# all on the controlling terminal, BYPASSING the do_install log tee that captures
# stdout+stderr. msg.lib.sh prints a blank line BEFORE every box, so prompts self-separate.
# Echoes the raw reply on stdout (empty when non-interactive, so the caller picks the
# default). Read it with resp="$(ask ...)".
ask() {
    local title="$1" question="$2"; shift 2
    local reply=''
    if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
        AI_TOOLS_MSG_FULLWIDTH=1 ai_tools_msg_block "${title}" "$@" 2>/dev/tty
        printf '%s ' "${question}" > /dev/tty
        read -r reply < /dev/tty
    fi
    printf '%s' "${reply}"
}

# Decide what to do with an existing user config file. Interactive: ask whether
# to keep it (default) or overwrite. When warn is non-empty a second confirmation
# is required before overwriting (use for destructive cases). Non-interactive:
# always keep, so an unattended re-install never clobbers user edits. Returns 0
# to KEEP the existing file, 1 to (re)write it.
# $1 path      file to check
# $2 overwrite short label for the "n =" branch (default: "overwrite with shipped default")
# $3 warn      if non-empty, printed before a second prompt; overwrite is cancelled
#              unless the user explicitly types y/Y
keep_existing() {
    local path="$1" overwrite="${2:-overwrite with shipped default}" warn="${3:-}" resp confirm
    [[ -f "${path}" ]] || return 1            # absent: caller writes a fresh copy
    resp="$(ask "Awaiting input" "Keep it? (Enter = keep, n = ${overwrite}) [Y/n]" \
                "${path} already exists.")"
    if [[ "${resp}" =~ ^[nN] ]]; then
        if [[ -n "${warn}" ]]; then
            confirm="$(ask "Warning" "Confirm overwrite? (y = overwrite, Enter/N = cancel) [y/N]" \
                           "${warn}")"
            [[ "${confirm}" =~ ^[yY] ]] || return 0   # cancelled: keep
        fi
        return 1
    fi
    return 0                                   # non-interactive or Enter: keep
}

# Create a directory only if it does not already exist, preserving perms on
# existing dirs. Applies owner/mode only to newly created directories.
ensure_dir() {
    local mode="$1" owner="$2" group="$3" dir="$4"
    [[ -d "${dir}" ]] || install -d -o "${owner}" -g "${group}" -m "${mode}" "${dir}"
}

# Install a file after substituting the projects-user tokens (@PROJECTS_HOME@,
# @PROJECTS_USER@, @PROJECTS_GROUP@) and the sandbox-account tokens
# (@SANDBOX_USER@, @SANDBOX_GROUP@) with their resolved values. Handles files that
# embed the projects user's home, name, or primary group, or the sandbox account
# name (sudoers, chown script, hook).
install_subst() {
    local mode="$1" owner="$2" group="$3" src="$4" dst="$5"
    local tmp
    tmp="$(mktemp)"
    sed -e "s|@PROJECTS_HOME@|${PROJECTS_HOME}|g" \
        -e "s/@PROJECTS_USER@/${PROJECTS_USER}/g" \
        -e "s/@PROJECTS_GROUP@/${PROJECTS_GROUP}/g" \
        -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" \
        -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" \
        "${src}" > "${tmp}"
    install -o "${owner}" -g "${group}" -m "${mode}" "${tmp}" "${dst}"
    rm -f "${tmp}"
}

# Run systemctl --user as PROJECTS_USER with the correct runtime environment.
# Emits a warning rather than aborting if the user session is not active.
user_systemctl() {
    local uid
    uid="$(id -u "${PROJECTS_USER}")"
    sudo -u "${PROJECTS_USER}" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        systemctl --user "$@" \
        || warn "systemctl --user $* failed -- run it manually as ${PROJECTS_USER}"
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
    node_version="$(sudo -u "${SANDBOX_USER}" bash -c \
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

    # Lock /opt/ai-tools/bin to 550, owned by the projects user (NOT ai-tools):
    # ai-tools gets group r-x (it must execute nvm-update.sh and resolve the
    # claude symlink) but no write, so the agent can neither tamper with the
    # updater nor swap the symlink the wrapper resolves and trusts. Enforce even
    # when the dir pre-existed (README step 3 creates it ai-tools-owned).
    ensure_dir 550 "${PROJECTS_USER}" "${SANDBOX_GROUP}" "${ai_tools_bin}"
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${ai_tools_bin}"
    chmod 550 "${ai_tools_bin}"
    # Create the symlink via the root helper -- the only writer of the locked dir,
    # and the same validating path the sandbox updater uses on every Node upgrade.
    /usr/local/sbin/ai-tools/ai-tools-claude-symlink "${versioned_claude}" \
        || warn "ai-tools: failed to create ${ai_tools_bin}/claude symlink"
    log "symlink ${ai_tools_bin}/claude -> ${versioned_claude}"
}

# Check that ~/.local/bin precedes nvm shims in the user's PATH and print a
# notice when it does not. Never modifies .bashrc automatically.
check_path_order() {
    local bashrc="${PROJECTS_HOME}/.bashrc"
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
        /etc/sudoers.d/ai-tools-claude \
        /etc/profile.d/path_dedup.sh
    restorecon -R \
        /usr/local/sbin/ai-tools/ \
        /usr/local/lib/ai-tools/ \
        /opt/ai-tools/bin/ \
        /opt/ai-tools/.claude/ \
        /var/log/ai-tools/
    restorecon \
        "${PROJECTS_HOME}/.local/bin/claude" \
        "${PROJECTS_HOME}/.local/bin/nvm-update.sh" \
        "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service" \
        "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer"
}

# Offer to bring up the optional SELinux confinement layer. install-selinux.sh is
# a deliberately decoupled installer, so this only SUGGESTS it and runs it on
# explicit consent. We are already root with SUDO_USER set -- exactly what that
# script requires -- so it runs in-place when accepted. Skips cleanly when the
# script is absent or SELinux is disabled. Defaults to install when SELinux is
# active (Enter = install). A child failure is tolerated so it never aborts an
# otherwise-complete install. selinux-policy-devel is only needed when the user
# later chooses to recompile the policy from source.
offer_selinux() {
    local selinux_script="${SCRIPT_DIR}/selinux/install-selinux.sh"
    [[ -f "${selinux_script}" ]] || return 0

    if [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        log "SELinux disabled -- skipping the optional confinement layer"
        return 0
    fi

    say "  SELinux is active. An optional confinement layer locks the agent"
    say "  to domain ${C_BOLD}ai_tools_t${C_RST} (ships prebuilt; loads ${C_BOLD}ENFORCING${C_RST})."
    say ""

    local resp run_it=1
    resp="$(ask "Awaiting input" "(Enter = install, n = skip) [Y/n]" \
                "Build and load the SELinux policy module now?")"
    [[ "${resp}" =~ ^[nN] ]] && run_it=0

    if (( run_it )); then
        if "${selinux_script}" install; then
            ok "SELinux confinement installed"
        else
            warn "SELinux install did not complete -- bring it up later with:"
            warn "  sudo ${selinux_script} install"
        fi
    else
        log "skipped -- bring it up later with:"
        say "    ${C_BOLD}sudo ${selinux_script} install${C_RST}"
    fi
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

    _chk /usr/local/sbin/ai-tools/ai-tools-chown
    _chk /usr/local/sbin/ai-tools/ai-tools-setgid
    _chk /usr/local/sbin/ai-tools/ai-tools-setfacl
    _chk /usr/local/sbin/ai-tools/ai-tools-unclaim
    _chk /usr/local/sbin/ai-tools/ai-tools-claude-symlink
    _chk /usr/local/sbin/ai-tools/ai-tools-lockdown
    _chk /usr/local/sbin/ai-tools/ai-tools-relabel
    _chk /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint
    _chk /usr/local/sbin/ai-tools/ai-tools-handback
    _chk /usr/local/bin/ai-tools-handback-client
    _chk /usr/lib/systemd/system/ai-tools-handback.socket
    _chk /usr/lib/systemd/system/ai-tools-handback@.service
    _chk /usr/local/bin/ai-tools
    _chk /var/opt/ai-tools
    _chk /var/opt/ai-tools/sandbox-projects
    _chk /var/opt/ai-tools/README.md
    _chk /usr/local/lib/ai-tools/secret-patterns.lib.sh
    _chk /usr/local/lib/ai-tools/prune-dirs.lib.sh
    _chk /usr/local/lib/ai-tools/log.lib.sh
    _chk /usr/local/lib/ai-tools/msg.lib.sh
    _chk /usr/local/lib/ai-tools/relabel.lib.sh
    _chk /etc/sudoers.d/ai-tools-claude
    _chk /etc/profile.d/path_dedup.sh
    _chk /opt/ai-tools/bin/nvm-update.sh
    _chk /opt/ai-tools/bin/claude-run
    _chk /opt/ai-tools/bin/claude
    _chk /opt/ai-tools/.claude/post-tool-hook.sh
    _chk /opt/ai-tools/.claude/session-hook.sh
    _chk /opt/ai-tools/.claude/settings.json
    _chk "${PROJECTS_HOME}/.local/bin/claude"
    _chk "${PROJECTS_HOME}/.local/bin/nvm-update.sh"
    _chk "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service"
    _chk "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer"

    printf '  %s\n' "${sep}"
    if (( missing == 0 )); then
        printf '  %d/%d files in place.\n\n' "${ok}" "$(( ok + missing ))"
    else
        printf '  %d/%d files in place -- %d MISSING, check above.\n\n' \
            "${ok}" "$(( ok + missing ))" "${missing}"
    fi
}

print_banner() {
    printf '\n'
    printf '%s%s%s\n' "${C_BOLD}" '  ____ _      _    _   _ ____   _____    ____ ____ '     "${C_RST}"
    printf '%s%s%s\n' "${C_BOLD}" ' / ___| |    / \  | | | |  _ \ | ____|  /  __|    \ '    "${C_RST}"
    printf '%s%s%s\n' "${C_BOLD}" '| |     |   / _ \ | | | | | |  |  _|   |  |  | __) | '   "${C_RST}"
    printf '%s%s%s\n' "${C_BOLD}" '| |___| |_ / ___ \| |_|   |_|   |___   |  |__|   _ < '   "${C_RST}"
    printf '%s%s%s\n' "${C_BOLD}" ' \____|______/  __\_____/|____/|_____|  \____|_| \__\ '  "${C_RST}"
    printf '\n'
    printf '  Claude Code Restricted, run sessions as sandboxed user.  %s(v%s)%s\n' \
        "${C_DIM}" "${VERSION}" "${C_RST}"
    printf '\n'
}

# ── install ────────────────────────────────────────────────────────────────────

# Deploy every sandbox file with its intended owner and mode (root helpers, libs,
# hooks, the wrapper, the CLI, systemd units), seed user config without clobbering
# edits, bootstrap the claude symlink, enable the nvm-update timer, restore SELinux
# contexts, offer the optional SELinux bring-up, and -- if confirmed at the end --
# run the installed-files summary and the test suite (which includes the permissions
# check). Aborts if the sandbox user is absent.
do_install() {
    id "${SANDBOX_USER}" &>/dev/null \
        || die "${SANDBOX_USER} user not found -- create it first (README step 2)"

    # Capture the full install transcript to /var/log/ai-tools/install.log. tee keeps
    # colour on the terminal and writes a colour-stripped copy to the file; stderr is
    # folded in so warnings land in the log too. The dir is created 700 root:root now so
    # the target exists; the block below re-enforces perms and the SELinux relabel
    # applies ai_tools_log_t. A logger marker brackets the run in journald.
    install -d -o root -g root -m 700 /var/log/ai-tools 2>/dev/null || true
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> /var/log/ai-tools/install.log)) 2>&1
    # The >> open above *creates* install.log honouring the install umask (027 -> 640), and
    # the pre-create loop further down skips it (its [[ ! -e ]] guard sees it already exists),
    # so enforce 600 here -- install.log is the one log that must be born before that loop.
    # The other four are created 600 by that loop and are never written before it, so this
    # block leaves them alone (no umask-dependent touch, single creation path).
    chmod 600 /var/log/ai-tools/install.log 2>/dev/null || true
    logger -t ai-tools-install -p daemon.notice -- \
        "install started (projects user ${PROJECTS_USER}, sandbox ${SANDBOX_USER}:${SANDBOX_GROUP})" \
        2>/dev/null || true

    print_banner
    say "  projects user : ${PROJECTS_USER} (${PROJECTS_HOME})"
    say "  sandbox user  : ${SANDBOX_USER}:${SANDBOX_GROUP}"

    section "System files (root-owned)"

    # All ai-tools sudo-helpers live under one dir (parallels /usr/local/lib/ai-tools).
    # `install` does not create parents, so make it first. 750 root:root -- no world
    # bit, preventing non-root users from listing the helper names. The helpers run in
    # ai_tools_t via sudo with no domain transition; bin_t is the correct context for
    # /usr/local/sbin. Enforce on re-install even when the dir pre-exists.
    log "/usr/local/sbin/ai-tools/"
    ensure_dir 750 root root /usr/local/sbin/ai-tools
    chown root:root /usr/local/sbin/ai-tools
    chmod 750 /usr/local/sbin/ai-tools

    log "/usr/local/sbin/ai-tools/ai-tools-chown"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-chown.sh" \
        /usr/local/sbin/ai-tools/ai-tools-chown

    log "/usr/local/sbin/ai-tools/ai-tools-setgid"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-setgid.sh" \
        /usr/local/sbin/ai-tools/ai-tools-setgid

    log "/usr/local/sbin/ai-tools/ai-tools-setfacl"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-setfacl.sh" \
        /usr/local/sbin/ai-tools/ai-tools-setfacl

    log "/usr/local/sbin/ai-tools/ai-tools-unclaim"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-unclaim.sh" \
        /usr/local/sbin/ai-tools/ai-tools-unclaim

    log "/usr/local/sbin/ai-tools/ai-tools-claude-symlink"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh" \
        /usr/local/sbin/ai-tools/ai-tools-claude-symlink

    # Shared libraries, sourced by the helpers. The dir is root-owned, group
    # SANDBOX_GROUP, 750 -- no world bit: the agent enters via group to read the
    # prune list, but has no write, so it cannot alter the rules. Enforce on
    # re-install even when the dir pre-exists.
    log "/usr/local/lib/ai-tools/"
    ensure_dir 750 root "${SANDBOX_GROUP}" /usr/local/lib/ai-tools
    chown root:"${SANDBOX_GROUP}" /usr/local/lib/ai-tools
    chmod 750 /usr/local/lib/ai-tools

    # Secret-name matcher: read ONLY by the root helpers (ai-tools-chown,
    # ai-tools-lockdown), so 640 root:root -- no group or world surface; the agent
    # (not root, group SANDBOX_GROUP) cannot read it at all.
    log "/usr/local/lib/ai-tools/secret-patterns.lib.sh"
    install_subst 640 root root \
        "${SCRIPT_DIR}/src/usr/local/lib/ai-tools/secret-patterns.lib.sh" \
        /usr/local/lib/ai-tools/secret-patterns.lib.sh

    # Prune-dir list: ALSO sourced by session-hook.sh, which runs AS the agent, so
    # it needs group read -- 640 root:SANDBOX_GROUP (no world). No tokens to substitute.
    log "/usr/local/lib/ai-tools/prune-dirs.lib.sh"
    install -o root -g "${SANDBOX_GROUP}" -m 640 \
        "${SCRIPT_DIR}/src/usr/local/lib/ai-tools/prune-dirs.lib.sh" \
        /usr/local/lib/ai-tools/prune-dirs.lib.sh

    # Logger library: 644 root:root -- world-readable. Sourced by the root helpers, by
    # the hooks (run as ai-tools), and by the CLI (run as the projects user, NOT in
    # SANDBOX_GROUP), so every principal must read it; it holds no secrets. No tokens.
    log "/usr/local/lib/ai-tools/log.lib.sh"
    install -o root -g root -m 644 \
        "${SCRIPT_DIR}/src/usr/local/lib/ai-tools/log.lib.sh" \
        /usr/local/lib/ai-tools/log.lib.sh

    # Message formatter: 644 root:root -- world-readable. Sourced by the operator wrapper
    # and CLI, by the hooks (run as ai-tools), and by claude-run, so every principal must
    # read it; it holds no secrets. No tokens to substitute.
    log "/usr/local/lib/ai-tools/msg.lib.sh"
    install -o root -g root -m 644 \
        "${SCRIPT_DIR}/src/usr/local/lib/ai-tools/msg.lib.sh" \
        /usr/local/lib/ai-tools/msg.lib.sh

    # Project-label library: 640 root:root -- read ONLY by root principals (the
    # ai-tools-relabel helper and selinux/install-selinux.sh's sweep). No group or
    # world surface: the unprivileged CLI does not source it (it inlines its read-only
    # label check), and the agent never needs it. No tokens to substitute.
    log "/usr/local/lib/ai-tools/relabel.lib.sh"
    install -o root -g root -m 640 \
        "${SCRIPT_DIR}/src/usr/local/lib/ai-tools/relabel.lib.sh" \
        /usr/local/lib/ai-tools/relabel.lib.sh

    # Manual pre-flight lockdown sweep. Run by the user (sudo), never by ai-tools.
    log "/usr/local/sbin/ai-tools/ai-tools-lockdown"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-lockdown.sh" \
        /usr/local/sbin/ai-tools/ai-tools-lockdown

    # SELinux project-label helper. 750 root:root -- root-owned, root-only-executable:
    # run by the user via sudo (no SANDBOX_USER grant), never by ai-tools. install_subst
    # substitutes @PROJECTS_HOME@ (the allowlist path it validates a target against).
    log "/usr/local/sbin/ai-tools/ai-tools-relabel"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-relabel.sh" \
        /usr/local/sbin/ai-tools/ai-tools-relabel

    # SELinux entrypoint-relabel helper. 750 root:root -- run AS root via sudo (the third
    # @PROJECTS_USER@ NOPASSWD rule), by the nvm-update timer after a Node upgrade and by
    # `ai-tools --relabel`; never by ai-tools. No @-substitution needed (no placeholders),
    # but install_subst keeps the deploy path uniform with the other helpers.
    log "/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh" \
        /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint

    # Handback privilege bridge daemon.  750 root:root -- root-owned and only
    # root-executable: this is the privileged endpoint; the SANDBOX_USER reaches it
    # via the socket, never by exec'ing it directly.  install_subst substitutes
    # @SANDBOX_USER@ in the Python source before deployment.
    log "/usr/local/sbin/ai-tools/ai-tools-handback"
    install_subst 750 root root \
        "${SCRIPT_DIR}/src/usr/local/sbin/ai-tools/ai-tools-handback.py" \
        /usr/local/sbin/ai-tools/ai-tools-handback

    # Handback client.  750 root:SANDBOX_GROUP -- root-owned but group-executable so
    # SANDBOX_USER (a member of SANDBOX_GROUP) can run it from the hooks and the
    # updater; world cannot.  install_subst substitutes @SANDBOX_GROUP@.
    log "/usr/local/bin/ai-tools-handback-client"
    install_subst 750 root "${SANDBOX_GROUP}" \
        "${SCRIPT_DIR}/src/usr/local/bin/ai-tools-handback-client.py" \
        /usr/local/bin/ai-tools-handback-client

    # Systemd socket and service template for the handback bridge.  644 root:root --
    # systemd reads them as root; no world write.  install_subst substitutes
    # @SANDBOX_GROUP@ in the socket unit (SocketGroup=).
    log "/usr/lib/systemd/system/ai-tools-handback.socket"
    install_subst 644 root root \
        "${SCRIPT_DIR}/src/usr/lib/systemd/system/ai-tools-handback.socket" \
        /usr/lib/systemd/system/ai-tools-handback.socket
    log "/usr/lib/systemd/system/ai-tools-handback@.service"
    install -o root -g root -m 644 \
        "${SCRIPT_DIR}/src/usr/lib/systemd/system/ai-tools-handback@.service" \
        /usr/lib/systemd/system/ai-tools-handback@.service

    # Project-lifecycle CLI. Runs AS the projects user (never root, never ai-tools)
    # and needs no privilege: it only edits allowed-projects and the git
    # safe.directory list, both writable by the projects user. 755 root:root --
    # world-executable (the in-script guard refuses to run as root or ai-tools),
    # root-owned so the agent cannot tamper with it.
    log "/usr/local/bin/ai-tools"
    install_subst 755 root root \
        "${SCRIPT_DIR}/src/usr/local/bin/ai-tools.sh" \
        /usr/local/bin/ai-tools

    # Sandbox project area. /var/opt is FHS-correct for variable data paired with an
    # /opt install. Owned by the projects user, group SANDBOX_GROUP; the inner
    # sandbox-projects dir is setgid (clones born group SANDBOX_GROUP) and
    # group-writable (the agent works in the clones). The projects user is NOT in
    # SANDBOX_GROUP -- setgid is what lets both share the clone files. Enforce
    # ownership/mode on re-install even when the dirs pre-exist.
    log "/var/opt/ai-tools/"
    ensure_dir 2750 "${PROJECTS_USER}" "${SANDBOX_GROUP}" /var/opt/ai-tools
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /var/opt/ai-tools
    chmod 2750 /var/opt/ai-tools
    log "/var/opt/ai-tools/sandbox-projects/"
    ensure_dir 2770 "${PROJECTS_USER}" "${SANDBOX_GROUP}" /var/opt/ai-tools/sandbox-projects
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /var/opt/ai-tools/sandbox-projects
    chmod 2770 /var/opt/ai-tools/sandbox-projects

    # Sandbox workflow doc. Shipped documentation (not user-edited config), so it is
    # refreshed on every re-install. 640 PROJECTS_USER:SANDBOX_GROUP.
    log "/var/opt/ai-tools/README.md"
    install_subst 640 "${PROJECTS_USER}" "${SANDBOX_GROUP}" \
        "${SCRIPT_DIR}/src/var/opt/ai-tools/README.md" \
        /var/opt/ai-tools/README.md

    # Operation-log directory for the root helpers. Dir 700 root:root, each file 600
    # root:root -- the helpers append as root; ai-tools cannot read or tamper with the
    # trail (secret filenames recorded by ai-tools-chown are not exposed). journald is
    # the parallel sink for every component (see log.lib.sh). Pre-create each file so
    # the SELinux relabel can apply ai_tools_log_t and appends are pure appends; never
    # truncate an existing log.
    log "/var/log/ai-tools/"
    ensure_dir 700 root root /var/log/ai-tools
    chown root:root /var/log/ai-tools
    chmod 700 /var/log/ai-tools
    for _logfile in chown setgid symlink lockdown relabel handback install; do
        if [[ ! -e "/var/log/ai-tools/${_logfile}.log" ]]; then
            install -o root -g root -m 600 /dev/null "/var/log/ai-tools/${_logfile}.log"
        fi
    done

    log "/etc/profile.d/path_dedup.sh"
    install -o root -g root -m 644 \
        "${SCRIPT_DIR}/src/etc/profile.d/path_dedup.sh" \
        /etc/profile.d/path_dedup.sh

    log "/etc/sudoers.d/ai-tools-claude"
    local tmp_sudoers
    tmp_sudoers="$(mktemp)"
    sed -e "s/@PROJECTS_USER@/${PROJECTS_USER}/g" \
        -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" \
        -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" \
        "${SCRIPT_DIR}/src/etc/sudoers.d/ai-tools-claude" > "${tmp_sudoers}"
    visudo -c -f "${tmp_sudoers}" > /dev/null \
        || { rm -f "${tmp_sudoers}"; die "sudoers syntax check failed"; }
    install -o root -g root -m 0440 \
        "${tmp_sudoers}" /etc/sudoers.d/ai-tools-claude
    rm -f "${tmp_sudoers}"

    section "ai-tools control plane (/opt/ai-tools)"

    # Root of the control plane: PROJECTS_USER:SANDBOX_GROUP 2750. setgid propagates
    # group SANDBOX_GROUP to every file born here -- including the .lock file git-config
    # writes then renames to .gitconfig -- so the projects user never needs a post-write
    # chown after `ai-tools --project-create`. Group gets r-x only; the agent cannot
    # create or delete files here. Enforce even when the dir pre-exists.
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /opt/ai-tools
    chmod 2750 /opt/ai-tools

    # Control-plane files are owned by the projects user, group ai-tools: the
    # agent (which runs AS ai-tools) gets group read/exec but can never write
    # them, so it cannot rewrite its own updater, hook, or hook config.
    log "/opt/ai-tools/bin/nvm-update.sh"
    install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 550 \
        "${SCRIPT_DIR}/src/opt/ai-tools/bin/nvm-update.sh" \
        /opt/ai-tools/bin/nvm-update.sh

    log "/opt/ai-tools/bin/claude-run"
    install_subst 550 "${PROJECTS_USER}" "${SANDBOX_GROUP}" \
        "${SCRIPT_DIR}/src/opt/ai-tools/bin/claude-run.sh" \
        /opt/ai-tools/bin/claude-run

    # /opt/ai-tools/.claude holds both mutable agent state (sessions/, history,
    # credentials -- ai-tools-owned) AND the root-of-trust control files
    # (settings.json, post-tool-hook.sh). Owning the control files as the install
    # user is not enough on its own: a group-writer can unlink+recreate any file
    # in a dir it can write. So the dir is owned by the projects user (NOT ai-tools)
    # with setgid+sticky (3770): ai-tools stays a group-writer -- it can create and
    # manage its own state files -- but the sticky bit forbids it from deleting or
    # replacing files it does not own, and it is not the dir owner, so it cannot
    # bypass that. setgid keeps new entries in group ai-tools. Enforce on
    # re-install even when the dir pre-exists.
    log "/opt/ai-tools/.claude/"
    ensure_dir 3770 "${PROJECTS_USER}" "${SANDBOX_GROUP}" /opt/ai-tools/.claude
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /opt/ai-tools/.claude
    chmod 3770 /opt/ai-tools/.claude
    install_subst 750 "${PROJECTS_USER}" "${SANDBOX_GROUP}" \
        "${SCRIPT_DIR}/src/opt/ai-tools/.claude/post-tool-hook.sh" \
        /opt/ai-tools/.claude/post-tool-hook.sh
    install_subst 750 "${PROJECTS_USER}" "${SANDBOX_GROUP}" \
        "${SCRIPT_DIR}/src/opt/ai-tools/.claude/session-hook.sh" \
        /opt/ai-tools/.claude/session-hook.sh
    install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 640 \
        "${SCRIPT_DIR}/src/opt/ai-tools/.claude/settings.json" \
        /opt/ai-tools/.claude/settings.json

    # .gitconfig: PROJECTS_USER:SANDBOX_GROUP 640. SANDBOX_USER reads safe.directory
    # on startup; PROJECTS_USER edits it via `ai-tools --project-create`. setgid on
    # /opt/ai-tools (above) keeps the group correct across git-config lock→rename
    # rewrites. Ownership is enforced even when keeping existing content so a wrong-
    # group file does not silently block the agent. keep_existing preserves safe.directory
    # entries (and any user customisations) on re-install.
    log "/opt/ai-tools/.gitconfig"
    local _gitconfig="/opt/ai-tools/.gitconfig"
    if keep_existing "${_gitconfig}" "reseed with shipped defaults"; then
        log "keeping existing ${_gitconfig}"
        chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${_gitconfig}"
        chmod 640 "${_gitconfig}"
    else
        # Derive the sandbox email domain from the projects user's git user.email;
        # fall back to the machine's fully-qualified hostname.
        local _projects_email _domain
        _projects_email="$(git config --file "${PROJECTS_HOME}/.gitconfig" \
                               user.email 2>/dev/null || \
                           git config --file "${PROJECTS_HOME}/.config/git/config" \
                               user.email 2>/dev/null || true)"
        if [[ -n "${_projects_email}" && "${_projects_email}" == *@* ]]; then
            _domain="${_projects_email#*@}"
        else
            _domain="$(hostname -f 2>/dev/null || hostname)"
        fi
        install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 640 \
            /dev/null "${_gitconfig}"
        printf '[user]\n\tname = %s\n\temail = %s\n\n[core]\n\tfileMode = true\n\tautocrlf = input\n\n[init]\n\tdefaultBranch = main\n\n[pull]\n\trebase = false\n' \
            "${SANDBOX_USER}" "ai-tools@${_domain}" > "${_gitconfig}"
        log "created ${_gitconfig} (ai-tools@${_domain})"
    fi

    section "User files (${PROJECTS_HOME})"

    log "${PROJECTS_HOME}/.local/bin/"
    ensure_dir 700 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.local"
    ensure_dir 700 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.local/bin"
    install -o "${PROJECTS_USER}" -g "${PROJECTS_GROUP}" -m 750 \
        "${SCRIPT_DIR}/src/home/user/.local/bin/claude.sh" \
        "${PROJECTS_HOME}/.local/bin/claude"
    install -o "${PROJECTS_USER}" -g "${PROJECTS_GROUP}" -m 750 \
        "${SCRIPT_DIR}/src/home/user/.local/bin/nvm-update.sh" \
        "${PROJECTS_HOME}/.local/bin/nvm-update.sh"

    log "${PROJECTS_HOME}/.config/systemd/user/"
    ensure_dir 755 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.config"
    ensure_dir 755 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.config/systemd"
    ensure_dir 700 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.config/systemd/user"
    # 640: systemd --user reads them as the owner; no world bit needed.
    install -o "${PROJECTS_USER}" -g "${PROJECTS_GROUP}" -m 640 \
        "${SCRIPT_DIR}/src/home/user/.config/systemd/user/nvm-update.service" \
        "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service"
    install -o "${PROJECTS_USER}" -g "${PROJECTS_GROUP}" -m 640 \
        "${SCRIPT_DIR}/src/home/user/.config/systemd/user/nvm-update.timer" \
        "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer"

    section "Configuration (allowlist & secret patterns)"

    # --- Allowlist (create with format header if absent; keep on re-install) ---
    #
    # An existing allowlist holds the user's approved projects. A re-install keeps
    # it by default; overwriting removes all approved projects (destructive), so
    # keep_existing requires an explicit second confirmation before doing so.
    # The install dir is never added: it is a control-plane repo and registering it
    # would let the sandbox modify future installs undetected.

    ensure_dir 700 "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${PROJECTS_HOME}/.config/ai-tools"
    local allowlist="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
    local allowlist_existed=0; [[ -f "${allowlist}" ]] && allowlist_existed=1
    local allowlist_action
    if keep_existing "${allowlist}" \
            "clear all approved projects" \
            "all entries will be removed from the allowlist (project directories themselves are untouched)"; then
        log "keeping existing ${allowlist}"
        allowlist_action="kept existing"
    else
        log "writing ${allowlist}"
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
            "#" \
            "# Manage entries with the ai-tools CLI (run as the projects user) rather" \
            "# than editing by hand:" \
            "#   ai-tools --project-create <dir>   register a real project" \
            "#   ai-tools --sandbox-create <dir>   shallow-clone a repo into the sandbox area" \
            "#" \
            "# For repos whose git history may hold secrets, prefer a sandboxed clone" \
            "# under /var/opt/ai-tools/sandbox-projects/ so the agent never reads the" \
            "# original history. See /var/opt/ai-tools/README.md." \
            "" > "${allowlist}"
        chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${allowlist}"
        chmod 600 "${allowlist}"
        (( allowlist_existed )) \
            && allowlist_action="cleared (all entries removed)" \
            || allowlist_action="created fresh"
    fi
    # Remove the install dir if a previous install added it.
    if grep -qxF "${SCRIPT_DIR}" "${allowlist}" 2>/dev/null; then
        local _esc; _esc="$(printf '%s' "${SCRIPT_DIR}" | sed 's/[\\|]/\\&/g')"
        sed -i "\|^${_esc}$|d" "${allowlist}"
        log "removed install dir from allowlist: ${SCRIPT_DIR}"
    fi

    # Secret-name patterns: user-owned 600 (ai-tools can neither read nor write it;
    # the root helpers read it). An existing file holds the user's edits, so a
    # re-install keeps it by default and only re-seeds the shipped default on
    # explicit consent. Both ai-tools-chown and ai-tools-lockdown read this file;
    # if it is removed they fall back to the built-in defaults baked into the
    # shared library.
    local patternfile="${PROJECTS_HOME}/.config/ai-tools/secret-patterns"
    local secret_existed=0; [[ -f "${patternfile}" ]] && secret_existed=1
    local secret_action
    if keep_existing "${patternfile}"; then
        log "keeping existing ${patternfile}"
        secret_action="kept existing"
    else
        log "writing ${patternfile}"
        install -o "${PROJECTS_USER}" -g "${PROJECTS_GROUP}" -m 600 \
            "${SCRIPT_DIR}/src/home/user/.config/ai-tools/secret-patterns" "${patternfile}"
        (( secret_existed )) \
            && secret_action="reseeded from shipped default" \
            || secret_action="created fresh"
    fi

    say ""
    say "  ${C_DIM}allowed-projects :${C_RST} ${allowlist_action}"
    say "  ${C_DIM}secret-patterns  :${C_RST} ${secret_action}"

    section "Systemd (auto-update timer)"

    log "enabling linger for ${PROJECTS_USER}"
    loginctl enable-linger "${PROJECTS_USER}"

    # The sandbox launch (claude-run) runs `systemd-run --user` as ${SANDBOX_USER} to wrap
    # each session in a transient service unit, which needs ${SANDBOX_USER}'s own systemd
    # user instance (its /run/user/<uid>/bus). ${SANDBOX_USER} has no login shell, so only
    # linger keeps that instance alive; without it claude-run aborts at its bus-socket
    # preflight ("user instance not reachable").
    log "enabling linger for ${SANDBOX_USER}"
    loginctl enable-linger "${SANDBOX_USER}"

    log "reload and enable nvm-update.timer"
    user_systemctl daemon-reload
    user_systemctl enable --now nvm-update.timer

    log "reload systemd and enable ai-tools-handback.socket"
    systemctl daemon-reload
    systemctl enable --now ai-tools-handback.socket

    section "Finalising (claude symlink, PATH, SELinux)"
    bootstrap_claude_symlink
    check_path_order
    do_selinux_restore

    section "SELinux confinement (optional)"
    offer_selinux

    section "Install complete -- next steps"
    say "  verify the timer:"
    say "    ${C_BOLD}systemctl --user list-timers nvm-update.timer${C_RST}"
    say ""
    say "  register projects with the ai-tools CLI (run as ${PROJECTS_USER}, no sudo):"
    say "    ${C_BOLD}ai-tools --project-create /path/to/project${C_RST}    ${C_DIM}# a real project${C_RST}"
    say "    ${C_BOLD}ai-tools --sandbox-create /path/to/repo${C_RST}       ${C_DIM}# an isolated shallow clone${C_RST}"
    say "    ${C_BOLD}ai-tools --lockdown /path/to/project${C_RST}          ${C_DIM}# revoke agent access to secrets${C_RST}"
    say "  see ${C_DIM}/var/opt/ai-tools/README.md${C_RST}"
    say ""

    # Optional post-install verification, run LAST -- after the optional SELinux setup -- so
    # the installed-files summary and the full test suite both see the final, labelled state.
    # The permissions check lives in the suite (tests/integration/perms.sh, the single source).
    # Interactive only and gated behind one confirm (defaults to run); a non-interactive install
    # skips all of it (a surprising, heavy default), leaving `install.sh check-perms` and
    # `tests/run.sh` available on demand.
    if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
        section "Verify"
        if [[ ! "$(ask "Run test suite" "(Enter = run, n = skip) [Y/n]" \
                "Run the full test suite (incl. the permissions check) now to verify the install?")" =~ ^[nN] ]]; then
            section "Installed files"
            do_summary
            "${SCRIPT_DIR}/tests/run.sh" all \
                || warn "test suite reported failures -- review the output above"
        fi
    fi

    logger -t ai-tools-install -p daemon.notice -- "install complete" 2>/dev/null || true
}

# ── uninstall ──────────────────────────────────────────────────────────────────

# Disable the nvm-update timer and remove every deployed system, control-plane, and
# user file. Leaves user-owned config (allowed-projects, secret-patterns) and the
# ai-tools account itself in place; allowlist pruning is offered interactively.
do_uninstall() {
    printf '\n%sUninstalling the ai-tools Claude Code sandbox%s\n' "${C_BOLD}" "${C_RST}"

    section "Systemd"
    log "disable nvm-update.timer"
    user_systemctl disable --now nvm-update.timer 2>/dev/null || true
    user_systemctl daemon-reload 2>/dev/null || true
    log "disable ai-tools-handback.socket"
    systemctl disable --now ai-tools-handback.socket 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    section "Removing files"
    log "system files"
    rm -f /usr/local/sbin/ai-tools/ai-tools-chown
    rm -f /usr/local/sbin/ai-tools/ai-tools-setgid
    rm -f /usr/local/sbin/ai-tools/ai-tools-setfacl
    rm -f /usr/local/sbin/ai-tools/ai-tools-unclaim
    rm -f /usr/local/sbin/ai-tools/ai-tools-claude-symlink
    rm -f /usr/local/sbin/ai-tools/ai-tools-lockdown
    rm -f /usr/local/sbin/ai-tools/ai-tools-handback
    rmdir /usr/local/sbin/ai-tools 2>/dev/null || true
    rm -f /usr/local/bin/ai-tools-handback-client
    rm -f /usr/lib/systemd/system/ai-tools-handback.socket
    rm -f /usr/lib/systemd/system/ai-tools-handback@.service
    rm -f /usr/local/bin/ai-tools
    rm -f /usr/local/lib/ai-tools/secret-patterns.lib.sh
    rm -f /usr/local/lib/ai-tools/prune-dirs.lib.sh
    rm -f /usr/local/lib/ai-tools/log.lib.sh
    rm -f /usr/local/lib/ai-tools/msg.lib.sh
    rmdir /usr/local/lib/ai-tools 2>/dev/null || true
    rm -f /etc/sudoers.d/ai-tools-claude
    rm -f /etc/profile.d/path_dedup.sh

    log "ai-tools control-plane files"
    rm -f /opt/ai-tools/bin/nvm-update.sh
    rm -f /opt/ai-tools/bin/claude-run
    rm -f /opt/ai-tools/.claude/post-tool-hook.sh
    rm -f /opt/ai-tools/.claude/session-hook.sh
    rm -f /opt/ai-tools/.claude/settings.json

    log "user files"
    rm -f "${PROJECTS_HOME}/.local/bin/claude"
    rm -f "${PROJECTS_HOME}/.local/bin/nvm-update.sh"
    rm -f "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service"
    rm -f "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer"

    section "Registration"
    # Optionally prune this project from the allowlist (default: keep)
    local allowlist="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
    if [[ -f "${allowlist}" ]] && grep -qxF "${SCRIPT_DIR}" "${allowlist}"; then
        _resp="$(ask "Awaiting input" "[Y/n]:" \
                     "Keep this project in allowed-projects?" "  ${SCRIPT_DIR}")"
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
        _resp="$(ask "Awaiting input" "[Y/n]:" \
                     "Keep this project in git safe.directory?" "  ${SCRIPT_DIR}")"
        if [[ "${_resp}" =~ ^[nN] ]]; then
            git config --file /opt/ai-tools/.gitconfig \
                --unset-all safe.directory "^${git_escaped}$" 2>/dev/null || true
            log "git safe.directory: removed"
        else
            log "git safe.directory: kept"
        fi
    fi

    section "Uninstall complete -- always preserved"
    say "  ${C_DIM}/opt/ai-tools/.nvm/${C_RST}    nvm and Node installation"
    say "  ${C_DIM}/var/opt/ai-tools/${C_RST}     sandbox project clones and README"
    say "  ${C_DIM}~/.config/ai-tools/${C_RST}    allowlist and user configuration (unless n above)"
    say "  ${C_DIM}git safe.directory${C_RST}     project registration (unless n above)"
    say ""
}

# ── dispatch ───────────────────────────────────────────────────────────────────

case "${ACTION}" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    check-perms)
        # The permissions check lives in the test suite (the single source). Run the perms
        # integration test directly; it reads SUDO_USER for the projects user, so no extra
        # setup is needed here.
        exec bash "${SCRIPT_DIR}/tests/integration/perms.sh"
        ;;
    *)
        printf 'usage: sudo %s [install|uninstall|check-perms]\n' "$0" >&2
        printf '       (register projects with the ai-tools CLI, not install.sh)\n' >&2
        exit 1
        ;;
esac
