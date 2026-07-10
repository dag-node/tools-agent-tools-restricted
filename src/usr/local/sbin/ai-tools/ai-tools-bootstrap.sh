#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-bootstrap
# Provision the sandbox account's Node toolchain: create the @SANDBOX_USER@ system account
# and its /opt/ai-tools home (if absent), then install nvm, Node, and the agent's npm package
# AS @SANDBOX_USER@, and point /opt/ai-tools/bin/<tool> at the freshly installed binary. This
# is the one step that reaches the network (nvm from GitHub, packages from npm), so it is a
# command run once by the operator -- never an RPM scriptlet, which must succeed offline and
# inside build chroots. The scheduled nvm-update timer maintains the tree afterwards.
#
# Provider-generic: the npm package is an argument (default @anthropic-ai/claude-code), so the
# same command serves other AI tools. The /opt/ai-tools/bin/<tool> symlink is created only for
# a package that ships a matching launcher.
#
# Idempotent: an existing account, nvm install, or Node version is reused, not rebuilt.
#
# Run as root (it creates a user and execs npm as @SANDBOX_USER@):
#       sudo ai-tools-bootstrap [npm-package]
# nvm defaults to its latest GitHub release (resolved at run time, so it does not rot); set
# AI_TOOLS_NVM_VERSION=vX.Y.Z to pin it, or AI_TOOLS_NODE_MAJOR to choose the Node line.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-bootstrap.sh /usr/local/sbin/ai-tools/ai-tools-bootstrap

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly SANDBOX_HOME="/opt/ai-tools"
readonly NVM_DIR="${SANDBOX_HOME}/.nvm"
# nvm version is resolved at run time (latest release, unless pinned); see resolve_nvm_version.
# The fallback is used only when the GitHub API cannot be reached and no pin is set.
readonly NVM_FALLBACK_VERSION="v0.40.3"
readonly NODE_MAJOR="${AI_TOOLS_NODE_MAJOR:-22}"
readonly PKG="${1:-@anthropic-ai/claude-code}"
# The launcher name a package installs into the Node bin dir, symlinked at
# /opt/ai-tools/bin/<launcher> for the wrapper to resolve. Only the Claude Code package is
# mapped; an unknown package installs the toolchain without a bin symlink.
case "${PKG}" in
    @anthropic-ai/claude-code) readonly LAUNCHER="claude" ;;
    *)                         readonly LAUNCHER="" ;;
esac

die() { printf 'ai-tools-bootstrap: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-bootstrap: %s\n' "$*"; }

# resolve_nvm_version: echo the nvm release tag to install. An explicit AI_TOOLS_NVM_VERSION
# pin wins; otherwise query the GitHub API for the latest release tag, falling back to the
# pinned default on any failure (offline, rate-limited, unparseable) so bootstrap stays robust
# without carrying a version that rots. The caller validates the result before it is used.
resolve_nvm_version() {
    if [[ -n "${AI_TOOLS_NVM_VERSION:-}" ]]; then
        printf '%s' "${AI_TOOLS_NVM_VERSION}"
        return
    fi
    local tag
    tag="$(curl -fsSL --max-time 10 \
            https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || true
    if [[ "${tag}" == v[0-9]* ]]; then
        printf '%s' "${tag}"
    else
        printf '%s' "${NVM_FALLBACK_VERSION}"
    fi
}

# configure_git_identity: offer to set the sandbox git identity -- the name/email the agent
# authors commits with -- in the shared control-plane gitconfig. install.sh / the RPM %post
# seed a safe default (ai-tools@<domain-or-hostname>); this is the one interactive point both
# install flows share (an RPM %post cannot prompt), so the operator can adopt their own git
# identity, keep the default, or edit the file by hand. Runs only when the control plane is
# present (gitconfig + msg.lib both deployed -- a bootstrap that precedes install.sh skips it);
# an unattended run keeps the default via msg.lib's no-tty path. Never fatal: any gap logs a
# hint and returns.
configure_git_identity() {
    local gc="${SANDBOX_HOME}/.gitconfig"
    command -v git >/dev/null 2>&1 \
        || { log "git not found -- set the sandbox commit identity in ${gc} by hand"; return 0; }
    [[ -f "${gc}" ]] \
        || { log "git identity: ${gc} not present yet -- install the control plane, then re-run to set it"; return 0; }

    local msglib=/usr/local/lib/ai-tools/msg.lib.sh
    # shellcheck source=/dev/null
    if ! { [[ -r "${msglib}" ]] && source "${msglib}"; } 2>/dev/null; then
        log "git identity: review ${gc} and set the agent's commit name/email"
        return 0
    fi

    local cur_name cur_email
    cur_name="$(git config --file "${gc}" user.name  2>/dev/null || true)"
    cur_email="$(git config --file "${gc}" user.email 2>/dev/null || true)"

    # The operator who invoked sudo; their personal git identity is the adopt-able option.
    local op="${SUDO_USER:-}" op_home op_name="" op_email=""
    if [[ -n "${op}" ]]; then
        op_home="$(getent passwd "${op}" | cut -d: -f6 || true)"
        if [[ -n "${op_home}" && -r "${op_home}/.gitconfig" ]]; then
            op_name="$(git config --file "${op_home}/.gitconfig" user.name  2>/dev/null || true)"
            op_email="$(git config --file "${op_home}/.gitconfig" user.email 2>/dev/null || true)"
        fi
    fi

    ai_tools_msg_block "Sandbox git identity" \
        "The sandbox account authors git commits in your projects with this identity." \
        "" \
        "  current: ${cur_name:-?} <${cur_email:-?}>"

    # Default is always Keep, so an unattended/piped run (no tty) leaves the seeded identity.
    local sel adopt=""
    [[ -n "${op_email}" ]] && adopt="Use your identity: ${op_name:-${op}} <${op_email}>"
    if [[ -n "${adopt}" ]]; then
        sel="$(ai_tools_msg_pick 2 "${adopt}" "Keep the current identity" "Edit ${gc} by hand")"
    else
        # No operator identity to adopt: keep-or-edit only; option 1 is the default.
        sel="$(ai_tools_msg_pick 1 "Keep the current identity" "Edit ${gc} by hand")"
        # Shift so the branches below read the same in both shapes (1=adopt, 2=keep, 3=edit).
        (( sel += 1 ))
    fi

    case "${sel}" in
        1)  git config --file "${gc}" user.name  "${op_name:-${op}}"
            git config --file "${gc}" user.email "${op_email}"
            chown "root:${SANDBOX_GROUP}" "${gc}"; chmod 0644 "${gc}"
            log "sandbox git identity set to ${op_name:-${op}} <${op_email}>" ;;
        3)  log "left ${gc} unchanged -- edit it to set the agent's commit identity" ;;
        *)  log "kept the current sandbox git identity: ${cur_name:-?} <${cur_email:-?}>" ;;
    esac
    log "verify the result in ${gc}"
}

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
command -v curl >/dev/null 2>&1 || die "curl is required to fetch nvm"

# Concrete tag (latest, pinned, or fallback). Constrained to v + digits/dots before it reaches
# the download URL piped to bash, so a resolved value can never inject shell or URL.
NVM_VERSION="$(resolve_nvm_version)"
[[ "${NVM_VERSION}" =~ ^v[0-9][0-9.]*$ ]] \
    || die "invalid nvm version '${NVM_VERSION}' (expected vMAJOR.MINOR.PATCH)"
readonly NVM_VERSION

# 1. Sandbox account + home. --system: no aging, low uid; /sbin/nologin + locked password:
#    the agent account has no interactive login. /opt (not /home) because /home is nosuid,
#    which would defeat the sudo UID-switch the launch path relies on.
if ! id "${SANDBOX_USER}" &>/dev/null; then
    log "creating system user ${SANDBOX_USER} (home ${SANDBOX_HOME})"
    useradd --system --shell /sbin/nologin --home-dir "${SANDBOX_HOME}" \
        --no-create-home --comment "AI tools sandbox user" "${SANDBOX_USER}"
    passwd -l "${SANDBOX_USER}" >/dev/null 2>&1 || true
fi
# Home root owned root:ai-tools, mode 2751: root owns the control plane and the agent reaches it
# through group ai-tools; the o+x search bit lets an operator readlink the launcher. The agent
# cannot create entries in this dir, so the agent-owned subtrees it must write are pre-created
# here, as root, and chowned to the account: .nvm holds the toolchain, .cache the
# NODE_COMPILE_CACHE, .npm the npm cache, .local XDG state. nvm/npm below then write only within
# these, never the home root.
install -d "${SANDBOX_HOME}"
chown "root:${SANDBOX_GROUP}" "${SANDBOX_HOME}"
chmod 2751 "${SANDBOX_HOME}"
for _sub in .nvm .cache .npm .local; do
    install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${SANDBOX_HOME}/${_sub}"
done

# 2. nvm + Node + the npm package, installed AS the sandbox account (network). The heredoc
#    is single-quoted, so the variables are expanded by the inner shell from the env passed
#    via `env`, never by this script. PROFILE=/dev/null directs nvm's installer to append its
#    init lines to a discard sink instead of the root-owned home profile. Existing nvm/Node are
#    reused (idempotent); all writes land within the pre-created .nvm/.npm subtrees.
log "installing nvm ${NVM_VERSION} + Node ${NODE_MAJOR} + ${PKG} as ${SANDBOX_USER} (network)"
sudo -u "${SANDBOX_USER}" env \
    NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" PROFILE=/dev/null \
    NVM_VERSION="${NVM_VERSION}" NODE_MAJOR="${NODE_MAJOR}" \
    PKG="${PKG}" \
    bash -s <<'EOSU'
set -euo pipefail
if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"
nvm install "${NODE_MAJOR}"
nvm alias default "${NODE_MAJOR}"
npm install -g "${PKG}"
EOSU

# 3. Point /opt/ai-tools/bin/<launcher> at the versioned binary, for a package whose launcher
#    is known and present. Runs as root: the agent cannot create top-level entries in the home
#    root. bin is the locked control-plane dir (0551 root:ai-tools); root writes the symlink
#    here, and install.sh / the RPM repoint it through the root symlink helper afterwards.
#    Agent runtime state needs no seeding: claude-run pins CLAUDE_CONFIG_DIR to the
#    group-writable .claude dir, where claude creates its own state files (.claude.json
#    included).
if [[ -n "${LAUNCHER}" ]]; then
    _ver="$(sudo -u "${SANDBOX_USER}" env NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" \
            bash -c '. "${NVM_DIR}/nvm.sh"; nvm version default' 2>/dev/null || true)"
    _bin="${NVM_DIR}/versions/node/${_ver}/bin/${LAUNCHER}"
    if [[ -n "${_ver}" && -x "${_bin}" ]]; then
        install -d -o root -g "${SANDBOX_GROUP}" -m 0551 "${SANDBOX_HOME}/bin"
        ln -sfn "${_bin}" "${SANDBOX_HOME}/bin/${LAUNCHER}"
    fi
fi

# 4. Capture the control plane's initial state in a root-private git repo so drift is reviewable.
#    The control plane is root:ai-tools, so the repo is root-owned: run AS root, and lock .git
#    root:root 0700 so committed blobs are unreadable to the agent (group ai-tools) and the
#    operators. The shipped .gitignore makes the repo default-deny, so auth tokens, conversation
#    logs, and nvm/npm churn are never staged -- so the capture runs ONLY when that denylist is
#    present (a populated control plane, e.g. after package install). Idempotent (skipped when
#    .git exists); non-fatal: a missing git or a commit failure warns and leaves the tree intact.
if [[ ! -e "${SANDBOX_HOME}/.git" && -e "${SANDBOX_HOME}/.gitignore" ]] && command -v git >/dev/null 2>&1; then
    log "capturing initial control-plane state in ${SANDBOX_HOME}/.git"
    _gitrun=(git -C "${SANDBOX_HOME}" -c user.name=ai-tools -c user.email="ai-tools@localhost")
    if "${_gitrun[@]}" init -q -b main \
       && "${_gitrun[@]}" add -A \
       && "${_gitrun[@]}" commit -q -m "Initial control-plane state (ai-tools-bootstrap)"; then
        log "captured initial control-plane commit"
    else
        log "warn: control-plane git capture incomplete"
    fi
    if [[ -d "${SANDBOX_HOME}/.git" ]]; then
        chown -R root:root "${SANDBOX_HOME}/.git"
        chmod 0700 "${SANDBOX_HOME}/.git"
    fi
fi

# 5. Enable the maintenance timer in the sandbox account's own systemd --user instance, which
#    keeps Node and the agent package current. The home is root-owned (2751), so the account
#    cannot write ~/.config; root provisions the XDG config tree (root:group 2750 -- the account
#    reads its units via the group) and the timers.target.wants symlink that enables the timer.
#    Order matters: the symlink is laid down before linger brings the manager up, so the manager
#    reaches timers.target with the enablement already in place and starts the timer itself. The
#    explicit start that follows covers a manager that was already running. Best-effort: a tree
#    that ships the unit later (the dev install.sh flow) warns rather than failing bring-up.
_uid="$(id -u "${SANDBOX_USER}")"
install -d -o root -g "${SANDBOX_GROUP}" -m 2750 \
    "${SANDBOX_HOME}/.config" \
    "${SANDBOX_HOME}/.config/systemd" \
    "${SANDBOX_HOME}/.config/systemd/user" \
    "${SANDBOX_HOME}/.config/systemd/user/timers.target.wants"
ln -sfn /usr/lib/systemd/user/nvm-update.timer \
    "${SANDBOX_HOME}/.config/systemd/user/timers.target.wants/nvm-update.timer"

# Linger keeps the --user manager running without an interactive login, so the timer it holds
# stays active. Surface a failure so an instance that does not engage linger is visible.
if command -v loginctl >/dev/null 2>&1; then
    _linger_out="$(loginctl enable-linger "${SANDBOX_USER}" 2>&1)" \
        || log "warn: could not enable linger for ${SANDBOX_USER} (${_linger_out:-no output})"
fi
# Wait for the manager to come up before driving it; XDG_RUNTIME_DIR alone lets systemctl --user
# reach the user manager over its bus, so DBUS_SESSION_BUS_ADDRESS need not be pinned.
for _i in $(seq 1 30); do
    systemctl is-active "user@${_uid}.service" >/dev/null 2>&1 && break
    sleep 0.5
done
# Start the timer now to cover a manager that was already running: the wants symlink alone
# starts it when the manager next reaches timers.target. Capture the output so the warn on a
# failed start carries systemctl's own error text.
if _start_out="$(sudo -u "${SANDBOX_USER}" \
        XDG_RUNTIME_DIR="/run/user/${_uid}" \
        bash -c 'systemctl --user daemon-reload && systemctl --user start nvm-update.timer' 2>&1)"; then
    log "started nvm-update.timer in ${SANDBOX_USER}'s --user instance"
else
    log "warn: could not start nvm-update.timer (${_start_out:-no output}) -- start it after the control plane is installed"
fi

log "toolchain ready under ${SANDBOX_HOME}"

# Sandbox git commit identity (control-plane gitconfig). Offered here as the shared interactive
# step; skipped cleanly when the control plane is not yet in place.
configure_git_identity

# Bootstrap runs in either order relative to the control plane: after a package/install.sh
# deploy (the common flow -- the wrapper is already present), or before it on a from-source
# host. Name the step that is actually still outstanding rather than assuming one order.
if [[ -x /usr/local/bin/claude ]]; then
    log "next: enrol an operator -- sudo ai-tools-admin operator add <user>"
else
    log "next: deploy the control plane -- sudo ./install.sh install   (or install the RPM)"
fi
