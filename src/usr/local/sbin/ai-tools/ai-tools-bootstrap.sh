#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-bootstrap
# Provision the sandbox account's Node toolchain: create the @SANDBOX_USER@ system account
# and its /opt/ai-tools home (if absent), then install nvm, Node, and the enabled agents' npm
# packages AS @SANDBOX_USER@, and point /opt/ai-tools/bin/<launcher> at each freshly installed
# binary. This is the one step that reaches the network (nvm from GitHub, packages from npm),
# so it is a command run once by the operator -- never an RPM scriptlet, which must succeed
# offline and inside build chroots. The scheduled nvm-update timer maintains the tree afterwards.
#
# Agent-agnostic: it installs no hardcoded agent. Which agents to provision -- their npm package
# and launcher name -- comes from the per-package manifests under
# /usr/local/lib/ai-tools/agents.d, gated by operator.conf AI_TOOLS_AGENTS (providers.lib.sh).
# With no manifests deployed yet it provisions Node alone; a re-run after an ai-tools-agents-*
# package is installed provisions that agent.
#
# Idempotent: an existing account, nvm install, or Node version is reused, not rebuilt.
#
# Run as root (it creates a user and execs npm as @SANDBOX_USER@):
#       sudo ai-tools-bootstrap
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
# present (the gitconfig exists) -- a bootstrap that precedes install.sh has nothing to
# configure and skips. Past that gate msg.lib is deployed, so it is REQUIRED like every other
# prompting consumer (a missing lib is a broken install and dies, not a silent skip); an
# unattended run keeps the default via msg.lib's no-tty path.
configure_git_identity() {
    local gc="${SANDBOX_HOME}/.gitconfig"
    command -v git >/dev/null 2>&1 \
        || { log "git not found -- set the sandbox commit identity in ${gc} by hand"; return 0; }
    [[ -f "${gc}" ]] \
        || { log "git identity: ${gc} not present yet -- install the control plane, then re-run to set it"; return 0; }

    # The control plane is present (gitconfig above), so its msg.lib is deployed too; require it
    # like every other prompting consumer -- a missing lib is a broken install, not a skip.
    local msglib=/usr/local/lib/ai-tools/msg.lib.sh
    [[ -r "${msglib}" ]] || die "control plane present but ${msglib} missing -- reinstall ai-tools"
    # shellcheck source=/dev/null
    source "${msglib}"

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

# seed_managed_assets_step: (re)seed the ai-tools-managed agents/skills from the pristine datadir
# copies into the config directory of each agent that uses that asset format. The directories come
# from the manifests (control-plane.lib.sh), so this names no path of its own. Runs only when the
# control plane is present (a config dir and the /usr/share/ai-tools pristine copies exist) and
# the seeder lib is deployed; a bootstrap that precedes install.sh has nothing to seed and skips.
# Past that gate msg.lib is deployed, so the update confirm requires it like every other prompting
# consumer. Same non-overwrite and version rules as install.sh -- only ai-tools-* assets carrying
# x-ai-tools-managed are touched, and an existing one updates only on confirm (default keep). See
# managed-assets.lib.sh.
seed_managed_assets_step() {
    local pristine=/usr/share/ai-tools
    local lib=/usr/local/lib/ai-tools/managed-assets.lib.sh msglib=/usr/local/lib/ai-tools/msg.lib.sh
    local cplib=/usr/local/lib/ai-tools/control-plane.lib.sh
    [[ -d "${pristine}/agents" && -r "${cplib}" ]] \
        || { log "managed assets: control plane not present yet -- install it, then re-run to seed agents/skills"; return 0; }
    [[ -r "${lib}" && -r "${msglib}" ]] \
        || die "control plane present but the managed-asset libs are missing -- reinstall ai-tools"
    # shellcheck source=/dev/null
    source "${msglib}"
    # shellcheck source=/dev/null
    source "${lib}"
    # shellcheck source=/dev/null
    source "${cplib}"
    declare -F ai_tools_agent_config_dirs >/dev/null 2>&1 \
        || die "control plane present but ${cplib} does not resolve the agents' config dirs"
    # The SHARED kinds first, into their own roots: skills and subagent definitions are
    # agent-agnostic, so they live in one place and each agent gets symlinks to them. The pairs
    # are <shared kind>:<the manifest field naming where that agent keeps it>.
    local spec kind shared asset_dir seeded=0
    for spec in skills:skills_dir subagents:subagents_dir; do
        kind="${spec%%:*}"; shared="${CP_HOME}/${kind}"
        install -d -o root -g "${SANDBOX_GROUP}" -m "${CP_DIR_MODES[${kind}]}" "${shared}"
        log "seeding ai-tools-managed ${kind} into ${shared}"
        ai_tools_seed_managed_assets "${pristine}" "${CP_HOME}" "${SANDBOX_GROUP}" "${kind}"
        ai_tools_link_asset_readme "${pristine}/${kind}/README.md" "${shared}" "${SANDBOX_GROUP}"
        while IFS=$'\t' read -r _ asset_dir; do
            log "linking the shared ${kind} into ${asset_dir}"
            ai_tools_link_shared_assets "${shared}" "${asset_dir}" \
                "${SANDBOX_GROUP}" "${pristine}/${kind}/README.md"
            seeded=1
        done < <(ai_tools_agent_asset_dirs "${spec#*:}")
    done
    (( seeded )) || log "managed assets: no agent config directory to seed yet"
}

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
command -v curl >/dev/null 2>&1 || die "curl is required to fetch nvm"

# Run from a neutral, world-traversable directory. The sudo -u ${SANDBOX_USER} steps below
# inherit this process's CWD; invoked from an operator's private dir (e.g. ~/Downloads, mode
# 0700) the sandbox account cannot traverse back into it, so nvm/npm's internal `find` warns
# "Failed to restore initial working directory". Nothing here depends on CWD (every path is
# absolute), and / is always reachable, so move off the caller's directory up front.
cd /

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

# Resolve which agents to provision from the installed manifests (agents.d) gated by
# operator.conf AI_TOOLS_AGENTS -- providers.lib.sh, the seam that keeps this toolchain step
# agent-agnostic. Each enabled line is "name<TAB>npm_package<TAB>launcher"; collect the packages
# (installed in step 2) and launchers (symlinked in step 3). The lib is control-plane, so a
# bootstrap that PRECEDES control-plane install has none yet: Node is provisioned bare and a
# re-run picks up the agents. Its stderr warns of an enabled-but-uninstalled agent.
_providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
_agent_packages=(); _agent_launchers=()
# Guarded load: providers.lib.sh returns non-zero and defines nothing when its own dependency
# (conf.lib.sh, the shared KEY=value grammar) is missing, so probe the resolver rather than assume
# the source succeeded -- a bare `source` under set -e would abort the provision instead of falling
# back to Node-only.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/providers.lib.sh
if source "${_providers_lib}" 2>/dev/null \
        && declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    while IFS=$'\t' read -r _ manifest_package manifest_launcher; do
        [[ -n "${manifest_package}" ]]  && _agent_packages+=("${manifest_package}")
        [[ -n "${manifest_launcher}" ]] && _agent_launchers+=("${manifest_launcher}")
    done < <(ai_tools_enabled_agents)
else
    log "provider resolver unavailable -- provisioning Node only; re-run after the control plane and an ai-tools-agents-* package are installed to provision agents"
fi

# 2. nvm + Node + the enabled agents' npm packages, installed AS the sandbox account (network).
#    The heredoc is single-quoted, so the variables are expanded by the inner shell from the env
#    passed via `env`, never by this script. PROFILE=/dev/null directs nvm's installer to append
#    its init lines to a discard sink instead of the root-owned home profile. Existing nvm/Node
#    are reused (idempotent); all writes land within the pre-created .nvm/.npm subtrees.
if [[ ${#_agent_packages[@]} -gt 0 ]]; then
    log "installing nvm ${NVM_VERSION} + Node ${NODE_MAJOR} + ${_agent_packages[*]} as ${SANDBOX_USER} (network)"
else
    log "installing nvm ${NVM_VERSION} + Node ${NODE_MAJOR} (no agents enabled) as ${SANDBOX_USER} (network)"
fi
sudo -u "${SANDBOX_USER}" env \
    NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" PROFILE=/dev/null \
    NVM_VERSION="${NVM_VERSION}" NODE_MAJOR="${NODE_MAJOR}" \
    AGENT_PACKAGES="${_agent_packages[*]}" \
    bash -s <<'EOSU'
set -euo pipefail
if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"
nvm install "${NODE_MAJOR}"
nvm alias default "${NODE_MAJOR}"
# Install each enabled agent's npm package. npm 11.5+ gates preinstall/install/postinstall
# behind an allowScripts allowlist, so a bare `npm install -g` BLOCKS the postinstall --
# @anthropic-ai/claude-code fetches and wires its platform-native binary there (node
# install.cjs); blocked, the JS launcher installs but exits "native binary not installed" at
# every launch. npm re-scans the WHOLE global tree on each install, so the allowlist must cover
# the full set on every call (mirrors nvm-update.sh's install_packages) -- scoped to our named
# agents, never --dangerously-allow-all-scripts. With no agents enabled, Node is provisioned bare.
read -ra agent_packages <<< "${AGENT_PACKAGES}"
if [ "${#agent_packages[@]}" -gt 0 ]; then
    allow_scripts="$(IFS=,; printf '%s' "${agent_packages[*]}")"
    for agent_package in "${agent_packages[@]}"; do
        npm install -g --allow-scripts="${allow_scripts}" "${agent_package}"
    done
fi
EOSU

# 2b. Verify the installed toolchain's npm registry signatures BEFORE wiring the launcher, so a
#     compromised registry serving a tampered package is caught before the first launch can use
#     it. Runs as ${SANDBOX_USER} (the verifier refuses root: it audits the sandbox-owned global
#     tree and as root would resolve the wrong prefix). nvm is re-sourced so npm/node are on
#     PATH. Gated on the lib being deployed: a bootstrap that precedes the control plane has no
#     lib yet -- the nvm-update timer verifies on its first run instead. A tamper aborts the
#     bootstrap before the symlink/relabel, leaving the tampered tree unwired; an inability to
#     verify (offline/unsupported) warns and proceeds, matching the check's best-effort posture.
_verify_lib=/usr/local/lib/ai-tools/npm-verify.lib.sh
if [[ -r "${_verify_lib}" ]]; then
    _vrc=0
    sudo -u "${SANDBOX_USER}" env \
        NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" VERIFY_LIB="${_verify_lib}" \
        bash -c '
            set -euo pipefail
            . "${NVM_DIR}/nvm.sh" >/dev/null 2>&1
            nvm use default >/dev/null 2>&1 || true
            . "${VERIFY_LIB}"
            ai_tools_verify_npm_signatures
        ' || _vrc=$?
    case "${_vrc}" in
        0) log "npm registry signatures verified for the installed toolchain" ;;
        1) die "npm signature verification FAILED (possible registry tampering) -- aborting before wiring the launcher; the installed package is left unactivated" ;;
        *) log "warn: could not verify npm signatures (offline or unsupported) -- proceeding; the toolchain is installed but unverified" ;;
    esac
else
    log "warn: signature-verification library not deployed yet -- skipping the check; the nvm-update timer verifies on its first run"
fi

# 3. Point /opt/ai-tools/bin/<launcher> at the versioned binary, once per enabled agent whose
#    launcher is present. Runs as root: the agent cannot create top-level entries in the home
#    root. bin is the locked control-plane dir (0551 root:ai-tools); root writes the symlinks
#    here, and install.sh / the RPM repoint them through the root symlink helper afterwards.
#    Agent runtime state needs no seeding: ai-tools-run pins CLAUDE_CONFIG_DIR to the
#    group-writable .claude dir, where claude creates its own state files (.claude.json
#    included).
if [[ ${#_agent_launchers[@]} -gt 0 ]]; then
    _node_version="$(sudo -u "${SANDBOX_USER}" env NVM_DIR="${NVM_DIR}" HOME="${SANDBOX_HOME}" \
            bash -c '. "${NVM_DIR}/nvm.sh"; nvm version default' 2>/dev/null || true)"
    if [[ -n "${_node_version}" ]]; then
        install -d -o root -g "${SANDBOX_GROUP}" -m 0551 "${SANDBOX_HOME}/bin"
        for _launcher in "${_agent_launchers[@]}"; do
            _launcher_bin="${NVM_DIR}/versions/node/${_node_version}/bin/${_launcher}"
            [[ -x "${_launcher_bin}" ]] && ln -sfn "${_launcher_bin}" "${SANDBOX_HOME}/bin/${_launcher}"
        done
    fi
fi

# 3b. Relabel the freshly installed entrypoint for the SELinux domain transition. A fresh
#     claude.exe is born bin_t/lib_t, so the -> ai_tools_t transition does not fire and
#     ai-tools-run refuses to launch (it would run UNCONFINED) until the entrypoint carries
#     ai_tools_exec_t. Bootstrap runs as root (a domain that holds relabel) and has just minted
#     the entrypoint, so it relabels here rather than leaving the first launch to fail with a
#     manual `ai-tools --relabel`. Gated on the helper being deployed: a bootstrap that precedes
#     the control plane has no helper yet (install.sh / the RPM relabel then). The helper is
#     idempotent and no-ops when SELinux or the ai_tools module is inactive, so this is safe on a
#     DAC-only host; best-effort -- a relabel gap degrades to ai-tools-run's refusal, not a failed
#     bootstrap. See .claude/rules/updater.rule.md.
_relabel_helper=/usr/local/sbin/ai-tools/ai-tools-relabel-agent
if [[ -x "${_relabel_helper}" ]]; then
    "${_relabel_helper}" \
        || log "warn: entrypoint relabel did not complete -- run 'ai-tools --relabel' before launching claude"
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

# Pre-seed the timer's Persistent run-stamp so starting it begins on the next scheduled window
# rather than an immediate catch-up run. nvm-update.timer is Persistent=true with a daily
# OnCalendar; started (or reached via timers.target) after that time has passed with no prior
# stamp, systemd runs nvm-update.service at once. That run reinstalls the agent package -- reminting claude.exe at lib_t (a freshly
# written entrypoint is born the default type; only restorecon applies ai_tools_exec_t) -- and
# its async repoint -> relabel chain races the operator's first launch, so the first `claude`
# refuses on a mislabelled entrypoint. Bootstrap has just installed the latest toolchain, so
# "last run = now" is truthful: record it (mtime is all systemd reads), and the next run is the
# next scheduled window. Written AS the sandbox account into its XDG_DATA_HOME, the path the
# --user manager reads and later updates itself. See .claude/rules/updater.rule.md.
_stampdir="${SANDBOX_HOME}/.local/share/systemd/timers"
sudo -u "${SANDBOX_USER}" mkdir -p "${_stampdir}"
sudo -u "${SANDBOX_USER}" touch "${_stampdir}/stamp-nvm-update.timer"

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

# Managed agents/skills (control-plane .claude). Seeded/updated here from the pristine datadir
# copies; skipped cleanly when the control plane is not yet in place.
seed_managed_assets_step

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
