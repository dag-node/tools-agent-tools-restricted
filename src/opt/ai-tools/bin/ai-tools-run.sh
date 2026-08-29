#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/bin/ai-tools-run
# Confinement shim: runs one sandboxed agent session as @SANDBOX_USER@, inside a transient
# systemd --user service whose properties are the session's security boundary.
#
# Invoked only by an agent's launch wrapper, which resolves and validates the versioned
# executable and drops privilege:
#
#   sudo -u @SANDBOX_USER@ -g @SANDBOX_GROUP@ -- /opt/ai-tools/bin/ai-tools-run [args...]
#
# with AI_TOOLS_AGENT_EXEC (the versioned executable) and AI_TOOLS_PROJECT_DIR (the session's
# working directory) carried through sudo's env_keep. Both are re-validated here, so neither
# side is a single point of trust.
#
# What is CHECKED is what is EXEC'd. AI_TOOLS_AGENT_EXEC names the versioned launcher symlink; this
# shim resolves it once, contains the target to the same semver version directory, and uses that
# single path for the SELinux label preflight, the entrypoint pin, and the unit's ExecStart -- then
# re-resolves it immediately before the launch. What that window is, and why it is a DAC-only
# concern, are in launch.rule.md.
#
# It names no agent. Which executables may launch, what environment each session gets, and
# whether the session's ownership handback needs driving from here come from the root-owned
# provider manifests under /usr/local/lib/ai-tools/agents.d and the session-env fragments under
# /usr/local/lib/ai-tools/session-env.d.
#
# Operating notes:
#   * The session appears as @SANDBOX_USER@-<agent>-<pid>.service in `systemctl --user`. Its
#     stdout/stderr go to the terminal (--pty), so the per-unit journal is empty on a clean run.
#   * Every launch logs its confinement inputs, the toolchain versions, and any refusal under the
#     `ai-tools-run` syslog tag -- where the useful records are:
#         sudo journalctl -t ai-tools-run _UID=<sandbox uid> -n 50 --no-pager
#   * A refusal names the fix. The common ones are a stale SELinux label after a Node upgrade
#     (`ai-tools --relabel`) and a stopped user manager (`loginctl enable-linger`).
#   * The ownership handback socket is checked before launch: if it is down the session still
#     starts (it is a data-ownership convenience, not a confinement boundary) but a NOTICE names
#     the fix, and the session-end sweep skips its walk rather than tallying failed hand-backs.
#
# Reference: launch.rule.md (launch mechanics, the wrapper contract, PATH and env pinning),
# confinement.rule.md (namespaces, SELinux transition, /tmp), providers.rule.md (manifests,
# enablement, the session-env seam).
#
# Ownership: 0550 root:@SANDBOX_GROUP@ inside the 0551 /opt/ai-tools/bin, so @SANDBOX_USER@
# executes it but cannot modify, unlink, or replace it.

set -euo pipefail

readonly AI_TOOLS_LIB_DIR="/usr/local/lib/ai-tools"
readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"
readonly SESSION_ENV_DIR="${AI_TOOLS_LIB_DIR}/session-env.d"
readonly SANDBOX_HOME="/opt/ai-tools"

# Everything below is sourced from AI_TOOLS_LIB_DIR while running as @SANDBOX_USER@, so that
# directory is the root of trust for this script. Verify it before sourcing anything out of it:
# root-owned, not a symlink, not group/other-writable. ai_tools_conf_is_trusted applies the same
# test to every later input, but it lives in the directory this gate protects.
lib_dir_metadata="$(stat -c '%u %a' "${AI_TOOLS_LIB_DIR}" 2>/dev/null || true)"
if [[ -L "${AI_TOOLS_LIB_DIR}" || "${lib_dir_metadata%% *}" != 0 \
      || ! "${lib_dir_metadata##* }" =~ ^[0-7]+$ ]] \
   || (( (0${lib_dir_metadata##* } & 022) != 0 )); then
    printf 'ai-tools-run: %s is not root-owned or is writable by group/other -- refusing to launch\n' \
        "${AI_TOOLS_LIB_DIR}" >&2
    exit 1
fi

# Four required libraries. Each is a gate, not an output path, so a bare source under set -e is
# the fail-closed load: a missing one is a broken install and refuses the launch rather than
# skipping a check (see shellcheck.rule.md).
#   msg          the framed refusals and the launch banner
#   conf         the KEY=value grammar and ai_tools_conf_is_trusted
#   providers    which agents may launch, which integrations contribute session env
#   confinement  the pure SELinux launch verdict
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/msg.lib.sh
source "${AI_TOOLS_LIB_DIR}/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/conf.lib.sh
source "${AI_TOOLS_LIB_DIR}/conf.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/providers.lib.sh
source "${AI_TOOLS_LIB_DIR}/providers.lib.sh"
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/confinement.lib.sh
source "${AI_TOOLS_LIB_DIR}/confinement.lib.sh"

# refuse <headline> [detail...] : frame the refusal and stop. Every call names the fix, so a
# refused launch is self-explaining at the terminal.
refuse() {
    local headline="ai-tools-run: $1"; shift
    ai_tools_msg_error "${headline}" "$@"
    exit 1
}
# audit <syslog-level> <message> : one journal line under the ai-tools-run tag, the durable
# record of what a session was launched with and why one was refused.
audit() {
    if command -v logger >/dev/null 2>&1; then
        logger -t ai-tools-run -p "authpriv.$1" "$2" 2>/dev/null || true
    fi
}

# ── Principal guards ─────────────────────────────────────────────────────────────────────────
# The session must run AS @SANDBOX_USER@: the transient unit, the SELinux transition, and the
# umask are all built around that account. Running as root or any other user would launch the
# agent unconfined with that user's privileges.
current_user_name="$(id -un 2>/dev/null || true)"
if [[ "${EUID}" -eq 0 || "${current_user_name}" != "@SANDBOX_USER@" ]]; then
    refuse "must run as @SANDBOX_USER@, not ${current_user_name:-?} -- launch through the agent's wrapper" \
           'the launch path runs:  sudo -u @SANDBOX_USER@ -g @SANDBOX_GROUP@ -- /opt/ai-tools/bin/ai-tools-run'
fi

# ai-ops membership carries the sudoers grant that drops into @SANDBOX_USER@ and starts a
# session. The sandbox account holding it would let the agent drive a session as an operator.
# This runs as @SANDBOX_USER@, so it reads its own membership authoritatively.
if [[ " $(id -nG "@SANDBOX_USER@" 2>/dev/null) " == *" ai-ops "* ]]; then
    refuse '@SANDBOX_USER@ is a member of the ai-ops operators group -- refusing to launch' \
           'remove it:  sudo gpasswd -d @SANDBOX_USER@ ai-ops'
fi

# ── Agent resolution and executable validation ───────────────────────────────────────────────
# The executable is accepted only when it is the launcher of an ENABLED, installed agent, at a
# semver-shaped version directory inside the sandbox's own Node toolchain. The launcher set is an
# allowlist built from root-owned manifests, so an executable no manifest claims cannot launch --
# and the agent identity follows from the path rather than from a separate variable crossing sudo.
declare -A agent_name_by_launcher=()
while IFS=$'\t' read -r manifest_agent_name _ manifest_launcher; do
    [[ -n "${manifest_launcher}" ]] && agent_name_by_launcher["${manifest_launcher}"]="${manifest_agent_name}"
done < <(ai_tools_enabled_agents 2>/dev/null)
(( ${#agent_name_by_launcher[@]} > 0 )) \
    || refuse 'no agent is enabled on this host -- nothing can launch' \
              'enable one in /etc/ai-tools/operator.conf (AI_TOOLS_AGENTS), then: sudo ai-tools-bootstrap'

agent_executable_path="${AI_TOOLS_AGENT_EXEC:-}"
[[ "${agent_executable_path}" != *"/../"* ]] \
    || refuse 'AI_TOOLS_AGENT_EXEC contains parent-directory references'
# Anchored to the sandbox's own Node toolchain, an exact semver version directory, and a single
# path component for the launcher -- so the version component cannot be an arbitrary directory
# name and the launcher cannot carry a separator.
executable_suffix="${agent_executable_path#"${AI_TOOLS_NVM_DIR}/versions/node/"}"
[[ "${executable_suffix}" != "${agent_executable_path}" \
   && "${executable_suffix}" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)/bin/([A-Za-z0-9._-]+)$ ]] \
    || refuse 'invalid or absent AI_TOOLS_AGENT_EXEC -- cannot launch'
node_version="${BASH_REMATCH[1]}"
launcher_name="${BASH_REMATCH[2]}"

agent_name="${agent_name_by_launcher[${launcher_name}]:-}"
[[ -n "${agent_name}" ]] \
    || refuse "no enabled agent provides the launcher \"${launcher_name}\" -- refusing to launch"
# The name becomes a systemd unit name below; keep it to characters a unit name accepts.
[[ "${agent_name}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || refuse "agent manifest name \"${agent_name}\" is not a valid unit-name component"

agent_display_name="$(ai_tools_agent_manifest_field "${agent_name}" display_name || true)"
[[ -n "${agent_display_name}" ]] || agent_display_name="${agent_name}"
# Which side converges ownership after the agent writes a file. An agent that declares
# handback=hooks drives it from its own tool/turn hooks; every other declaration gets the
# session-end sweep below (see the sweep section).
agent_handback="$(ai_tools_agent_manifest_field "${agent_name}" handback || true)"

# ── Entrypoint resolution: verify and exec the same inode ────────────────────────────────────
# The path validated above is the versioned launcher SYMLINK; the file execve actually transitions
# on is what it resolves to. Resolve it ONCE here and use that single path for both the SELinux
# label preflight and the unit's ExecStart, so the file this shim checks is the file the manager
# runs -- rather than checking one path and handing systemd another to re-resolve at exec time.
#
# Containment: the resolved path must stay inside the SAME semver version directory the launcher
# was accepted at -- a property string-matching cannot carry across a symlink, so a link repointed
# at another version's tree, or out of the toolchain, is refused rather than exec'd.
#
# Frozen at the validated version: node_version is re-assigned to "n/a" further down when it fails
# the banner's display pattern, and the pre-launch re-check must resolve against the SAME root the
# first resolution used, not a display value.
readonly entrypoint_version_root="${AI_TOOLS_NVM_DIR}/versions/node/${node_version}/"

# resolve_entrypoint : print the launcher's resolved, contained, executable target; non-zero when
#   it does not resolve or leaves that root. Called twice -- once here, once immediately before the
#   launch -- so the check and the re-check cannot drift.
resolve_entrypoint() {
    local resolved
    resolved="$(realpath -e "${agent_executable_path}" 2>/dev/null)" || return 1
    [[ "${resolved}" == "${entrypoint_version_root}"* && "${resolved}" != *"/../"* ]] || return 1
    [[ -f "${resolved}" && -x "${resolved}" ]] || return 1
    printf '%s' "${resolved}"
}

# entrypoint_identity <path> : print a change-detecting identity for the file -- device, inode,
#   size, and ctime at nanosecond precision. Each of the three ways a same-uid process can swap an
#   entrypoint moves it: a symlink repoint and a rename-over both land a different inode, and an
#   in-place write bumps ctime (which no unprivileged caller can roll back -- utimes(2) sets atime
#   and mtime, never ctime). Prints nothing when the path cannot be stat'd, which compares unequal.
entrypoint_identity() {
    stat -c '%d:%i:%s:%z' -- "$1" 2>/dev/null || true
}

session_exec_path="$(resolve_entrypoint)" \
    || refuse "the launcher does not resolve to an executable inside ${entrypoint_version_root}" \
              "resolved from:  ${agent_executable_path}" \
              'reprovision the toolchain:  sudo ai-tools-bootstrap'
session_exec_identity="$(entrypoint_identity "${session_exec_path}")"

# ── Session working directory ────────────────────────────────────────────────────────────────
# A transient unit does not inherit the caller's cwd, so the wrapper's validated project
# directory is passed through and re-validated here before it becomes --working-directory.
# Absent (a direct diagnostic run outside a wrapper) leaves the systemd default.
session_working_directory=""
if [[ -n "${AI_TOOLS_PROJECT_DIR:-}" ]]; then
    [[ "${AI_TOOLS_PROJECT_DIR}" == /* ]] \
        || refuse 'AI_TOOLS_PROJECT_DIR must be an absolute path'
    [[ "${AI_TOOLS_PROJECT_DIR}" != *"/../"* && "${AI_TOOLS_PROJECT_DIR}" != *"/.." ]] \
        || refuse 'AI_TOOLS_PROJECT_DIR contains parent-directory references'
    [[ -d "${AI_TOOLS_PROJECT_DIR}" ]] \
        || refuse "AI_TOOLS_PROJECT_DIR is not an existing directory: ${AI_TOOLS_PROJECT_DIR}"
    session_working_directory="${AI_TOOLS_PROJECT_DIR}"
fi

# $UID is a bash built-in read from the real UID at startup -- no external command, no PATH
# dependency -- so after the sudo drop this resolves to @SANDBOX_USER@'s runtime directory.
export XDG_RUNTIME_DIR="/run/user/${UID}"
[[ -S "${XDG_RUNTIME_DIR}/bus" ]] \
    || refuse "@SANDBOX_USER@ user instance not reachable (bus socket absent: ${XDG_RUNTIME_DIR}/bus)" \
              "ensure linger is enabled:  loginctl enable-linger @SANDBOX_USER@"

# ── Fail-closed SELinux preflight ────────────────────────────────────────────────────────────
# A session that does not transition into ai_tools_t runs UNCONFINED, and a wrapper cannot
# observe its successor's post-exec domain -- so the transition's inputs are verified here,
# before launch, and logged on every launch. The launch/refuse decision is the pure
# ai_tools_confinement_verdict; this block owns only the probing and the reporting.
if command -v getenforce >/dev/null 2>&1; then
    selinux_mode="$(getenforce 2>/dev/null || echo unknown)"
    # The already-resolved and contained entrypoint -- the same inode this shim hands systemd as
    # ExecStart, so the label checked here is the label the transitioning execve reads.
    entrypoint_path="${session_exec_path}"
    expected_label="" actual_label="" manager_domain="" module_present=no
    if command -v matchpathcon >/dev/null 2>&1; then
        expected_label="$(matchpathcon -n "${entrypoint_path}" 2>/dev/null | awk -F: '{print $3}' || true)"
        actual_label="$(stat -c '%C' -- "${entrypoint_path}" 2>/dev/null | awk -F: '{print $3}' || true)"
        # Module presence for the verdict, WITHOUT reading the root-only module store: this runs as
        # @SANDBOX_USER@, so `semodule -l` returns nothing -- a systematic false "no" that, on the
        # unresolved-label branch, would fail OPEN (launch DAC-only where a half-installed host must
        # refuse). A CORE-owned path resolves to an ai_tools_* type IFF the core module's
        # file-contexts are live, and matchpathcon reads the world-readable file-contexts from the
        # path string, so the probe needs no privilege and the agent cannot influence it. This
        # distinguishes a half-installed host (module live, entrypoint unlabelled -> refuse) from a
        # DAC-only host (module absent -> launch), which the store read could not from this account.
        module_present="$(ai_tools_confinement_module_present \
            "$(matchpathcon -n /opt/ai-tools/.config 2>/dev/null | awk -F: '{print $3}' || true)")"
    fi
    # The manager is the systemd --user process that execs the entrypoint; same uid, so its
    # domain is readable.
    manager_pid="$(pgrep -u "${UID}" -f 'systemd --user' 2>/dev/null | head -n1 || true)"
    [[ -n "${manager_pid}" ]] && manager_domain="$(tr -d '\000' < "/proc/${manager_pid}/attr/current" 2>/dev/null | awk -F: '{print $3}' || true)"

    # AI_TOOLS_REQUIRE_SELINUX: the operator's declaration, from the trusted root-owned operator.conf,
    # that confinement is mandatory here -- when set it turns the two DAC-only LAUNCH exits into
    # refusals (require-not-enforcing / require-inactive). The agent cannot set it: operator.conf is
    # root-owned and this reads it only while ai_tools_conf_is_trusted holds, so an untrusted or
    # absent file yields "no" (the DAC-capable default), never a dropped requirement.
    require_selinux=no
    operator_conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    if ai_tools_conf_is_trusted "${operator_conf}" 2>/dev/null \
            && ai_tools_conf_read "${operator_conf}" AI_TOOLS_REQUIRE_SELINUX 2>/dev/null; then
        case "${_ai_tools_conf_value,,}" in yes|true|1|on) require_selinux=yes ;; esac
    fi

    audit info "launch: agent=${agent_name} selinux=${selinux_mode} module=${module_present} exec_label=${actual_label:-none} expected=${expected_label:-none} manager_domain=${manager_domain:-unknown} require=${require_selinux}"

    case "$(ai_tools_confinement_verdict "${selinux_mode}" "${module_present}" \
                                         "${expected_label}" "${actual_label}" "${manager_domain}" \
                                         "${require_selinux}")" in
        mislabel)
            audit warning "REFUSED: entrypoint mislabelled (${actual_label:-none}, want ai_tools_exec_t)"
            refuse "refusing to launch -- ${entrypoint_path} is mislabelled \"${actual_label:-none}\"" \
                   "(expected ai_tools_exec_t), so no domain transition fires and the session would run UNCONFINED (relabel is required after upgrade)." \
                   "Fix:  ai-tools --relabel" ;;
        manager-domain)
            audit warning "REFUSED: manager domain ${manager_domain} has no domtrans to ai_tools_t"
            refuse "refusing to launch -- the systemd --user manager runs in domain \"${manager_domain}\", which no domtrans_pattern in ai_tools.te covers, so the session would run UNCONFINED.  Add the source and rebuild:" \
                   "  domtrans_pattern(${manager_domain}, ai_tools_exec_t, ai_tools_t)   # in selinux/policy/ai_tools.te" \
                   "  sudo selinux/install-selinux.sh rebuild" ;;
        unverifiable)
            audit warning "REFUSED: ai_tools module present but file-contexts inactive (expected=${expected_label:-none})"
            refuse "refusing to launch -- the ai_tools SELinux module is installed but no file-context maps ${entrypoint_path} to ai_tools_exec_t, so the transition cannot be verified and the session would run UNCONFINED (fail closed on a half-installed host)." \
                   "The agent's entrypoint rule comes from its own manifest; register it:  ai-tools --relabel" \
                   "Or bring the whole layer up:  sudo selinux/install-selinux.sh install" \
                   "Or make this a DAC-only host:  sudo semodule -r ai_tools   (or run SELinux permissive)" ;;
        require-not-enforcing)
            audit warning "REFUSED: AI_TOOLS_REQUIRE_SELINUX set but SELinux is ${selinux_mode}, not Enforcing"
            refuse "refusing to launch -- AI_TOOLS_REQUIRE_SELINUX is set in operator.conf, but SELinux is \"${selinux_mode}\", not Enforcing, so the session would run without the ai_tools_t confinement the operator requires." \
                   "Enforce it:  sudo setenforce 1   (and check /etc/selinux/config so it survives a reboot)" \
                   "Or drop the requirement:  unset AI_TOOLS_REQUIRE_SELINUX in /etc/ai-tools/operator.conf" ;;
        require-inactive)
            audit warning "REFUSED: AI_TOOLS_REQUIRE_SELINUX set but the ai_tools module is not active"
            refuse "refusing to launch -- AI_TOOLS_REQUIRE_SELINUX is set in operator.conf, but the ai_tools SELinux module is not active on this enforcing host, so the session would run without the ai_tools_t confinement the operator requires." \
                   "Install the confinement policy package (its scriptlet loads the module):  sudo dnf install ai-tools-selinux" \
                   "On a source checkout instead:  sudo selinux/install-selinux.sh install" \
                   "Or drop the requirement:  unset AI_TOOLS_REQUIRE_SELINUX in /etc/ai-tools/operator.conf" ;;
    esac
fi

# The podman policy group grants the SELinux access rootless containers need, but the session's
# RestrictNamespaces=yes still blocks the user namespace they create. Surface that pairing as an
# actionable notice rather than a cryptic EPERM inside a later build. Best-effort probe.
if command -v semodule >/dev/null 2>&1; then
    # The listing is captured, not piped into `grep -q`: an early-exiting reader makes semodule
    # die of SIGPIPE, which pipefail reports as a failed probe -- see the note on
    # ai_tools_selinux_group_loaded (selinux-groups.lib.sh).
    loaded_modules="$(semodule -l 2>/dev/null || true)"
    if grep -qE '^ai_tools_podman([[:space:]]|$)' <<<"${loaded_modules}"; then
        ai_tools_msg_notice \
            "ai-tools-run: the \"podman\" SELinux group is enabled, but RestrictNamespaces=yes blocks the user namespace rootless podman/buildah require -- they will fail with EPERM on clone(CLONE_NEWUSER).  To allow containers, relax RestrictNamespaces in ${0} -- note that permitting the user namespace reopens ESC-001."
    fi
fi

# ── Handback socket preflight (warn, do not block) ───────────────────────────────────────────
# The ownership handback -- the per-turn hooks (handback=hooks) and this shim's session-end sweep
# alike -- reaches ai-tools-chown as root over the handback socket. If it is down, every CHOWN
# fails and files this session writes stay @SANDBOX_USER@-owned, surfacing later as git "dubious
# ownership". This is NOT a confinement boundary -- DAC, the ai_tools_t type, and the project's
# user:<operator> ACL keep the operator's access intact regardless -- so a down socket WARNS and
# proceeds rather than refusing the launch (a refusal would trade availability for a non-security
# convenience). Skipped for a diagnostic run with no project directory, which writes nothing to
# hand back. The reconcile commands are printed plain, below the frame, so they stay paste-safe.
readonly HANDBACK_SOCKET="/run/ai-tools/handback.sock"
if [[ -n "${session_working_directory}" && ! -S "${HANDBACK_SOCKET}" ]]; then
    audit warning "handback socket ${HANDBACK_SOCKET} absent at launch -- ownership handback will not run this session"
    ai_tools_msg_notice \
        "ai-tools-run: the ownership handback socket is down (${HANDBACK_SOCKET}), so files this session writes stay ai-tools-owned until it is restored -- git may then report \"dubious ownership\".  Bring it up, then reclaim the tree:"
    printf '  sudo systemctl enable --now ai-tools-handback.socket\n' >&2
    printf '  ai-tools --reclaim %s\n' "${session_working_directory}" >&2
fi

# ── Session environment ──────────────────────────────────────────────────────────────────────
# A service unit is spawned by the user manager with ITS OWN environment, so nothing crosses
# into the session unless named here. Only terminal-, locale-, and connectivity-shaping
# variables are forwarded by name; the operator's API keys, tokens, SSH_AUTH_SOCK, and cloud
# credentials stay out by construction, independent of sudo's env_reset/env_keep.
# --setenv=NAME imports NAME by name, so a value never reaches the command line.
readonly FORWARDED_ENVIRONMENT_VARIABLES=(
    TERM COLORTERM                                  # TUI rendering
    LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES       # locale / UTF-8 handling
    LC_COLLATE LC_NUMERIC LC_TIME LC_MONETARY
    XDG_RUNTIME_DIR                                 # user bus / runtime dir
    HTTP_PROXY HTTPS_PROXY NO_PROXY                 # outbound to the agent's API
    http_proxy https_proxy no_proxy
)
declare -a session_environment_options=()
for forwarded_variable_name in "${FORWARDED_ENVIRONMENT_VARIABLES[@]}"; do
    [[ -n "${!forwarded_variable_name:-}" ]] \
        && session_environment_options+=( "--setenv=${forwarded_variable_name}" )
done

# HOME and SHELL are pinned rather than inherited, so the session's identity and shell tooling
# are the sandbox's and not whatever the operator's login carries.
session_environment_options+=( "--setenv=HOME=${SANDBOX_HOME}" )
session_environment_options+=( "--setenv=SHELL=/usr/bin/bash" )

# PATH is assembled now and emitted after the session-env fragments run, so a fragment can extend
# its tail. The base tiers mirror path-dedup.sh's ordering -- root-owned, least-writable
# directories first so they win first-match -- with the versioned Node bin LAST. That directory is
# dirname(AI_TOOLS_AGENT_EXEC), the same validated path the launcher symlink resolved to, which
# keeps node/npm on the same trusted resolution chain as the entrypoint and follows Node upgrades
# without routing through the agent-writable "default" symlink in the .nvm tree.
session_path="/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin:${agent_executable_path%/*}"
declare -a session_path_entries=()

# ── Session-env fragments ────────────────────────────────────────────────────────────────────
# Each enabled provider may ship /usr/local/lib/ai-tools/session-env.d/<name>.env.sh, appending to
# session_environment_options and session_path_entries. Integrations are sourced first and the
# agent last, so the agent's own pins are authoritative over an integration's.
#
# This runs as @SANDBOX_USER@ and decides what the agent's own session gets, so every fragment --
# and the directory holding it, since a group-writable directory lets a non-root writer replace a
# root-owned file inside it -- must pass ai_tools_conf_is_trusted. A failing fragment is skipped
# and logged, never sourced. Fragments are additive, so skipping one costs the session that
# provider's environment and leaves every property below intact.
source_session_env_fragment() {
    local provider_name="$1" fragment_path="${SESSION_ENV_DIR}/$1.env.sh"
    [[ -e "${fragment_path}" ]] || return 0
    if ! ai_tools_conf_is_trusted "${fragment_path}"; then
        ai_tools_msg_warn "ai-tools-run: skipping session env for ${provider_name} -- ${fragment_path} is not root-owned or is writable by group/other"
        audit warning "session-env fragment skipped: ${fragment_path}"
        return 0
    fi
    # shellcheck source=/dev/null
    source "${fragment_path}"
}
if ai_tools_conf_is_trusted "${SESSION_ENV_DIR}"; then
    while IFS= read -r enabled_integration_name; do
        [[ -n "${enabled_integration_name}" ]] && source_session_env_fragment "${enabled_integration_name}"
    done < <(ai_tools_enabled_integrations 2>/dev/null)
    source_session_env_fragment "${agent_name}"
elif [[ -e "${SESSION_ENV_DIR}" ]]; then
    ai_tools_msg_warn "ai-tools-run: skipping all session env -- ${SESSION_ENV_DIR} is not root-owned or is writable by group/other"
    audit warning "session-env directory untrusted: ${SESSION_ENV_DIR}"
fi

(( ${#session_path_entries[@]} > 0 )) && session_path+=":$(IFS=:; printf '%s' "${session_path_entries[*]}")"
session_environment_options+=( "--setenv=PATH=${session_path}" )

# ── Session-end ownership sweep (agents that carry no handback hooks) ────────────────────────
# Files the agent writes are born @SANDBOX_USER@-owned and are returned to the operator by the
# ownership handback. An agent whose manifest declares handback=hooks drives that itself, per
# turn (Claude Code's PostToolUse/Stop/SessionStart hooks); an agent that declares anything else
# has no driver, and the operator's tree would silently stay sandbox-owned. For those the shim
# sweeps once, after the session ends -- slower to converge than per-turn hooks, same end state.
#
# The walk only chooses which paths to OFFER: each one goes through the handback socket to
# ai-tools-chown, which re-validates the allowlist, the exclusions, and the born-owner guard as
# root, so this reaches nothing the hooks could not.
readonly HANDBACK_CLIENT="/usr/local/bin/ai-tools-handback-client"

# Directory-skip selector, shared with the hooks and the root helpers. Fail-SOFT by its own
# design -- a skip list is walk cost, not an access boundary -- so a missing lib leaves a stub
# that skips nothing: a slower, more thorough sweep, never a narrower one.
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/skip-dirs.lib.sh
source "${AI_TOOLS_LIB_DIR}/skip-dirs.lib.sh" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# sweep_project_ownership : hand every @SANDBOX_USER@-owned path under the session's project
# directory to ai-tools-chown through the handback socket. No project directory (a diagnostic
# run outside a wrapper) or no client leaves it a no-op.
sweep_project_ownership() {
    [[ -n "${session_working_directory}" && -d "${session_working_directory}" ]] || return 0
    [[ -x "${HANDBACK_CLIENT}" ]] || return 0
    # A down socket fails every CHOWN, so skip the walk and record that once, rather than logging
    # a reassuring count of calls that changed nothing (the failure mode this whole change fixes).
    if [[ ! -S "${HANDBACK_SOCKET}" ]]; then
        audit warning "session-end sweep skipped: handback socket ${HANDBACK_SOCKET} is down -- files under ${session_working_directory} stay @SANDBOX_USER@-owned (reclaim with: ai-tools --reclaim ${session_working_directory})"
        return 0
    fi
    # The "reclaim" consumer omits the heavy dependency/build trees but WALKS .git -- the tree
    # the per-turn hooks skip, and which nothing else on this path would reach.
    ai_tools_skip_find_expr reclaim '' "${session_working_directory}"
    # Count CONFIRMED handbacks (client exit 0), not attempts, so the audit line reflects what
    # actually changed owner; a non-zero exit is either a routine skip (a path the root helper
    # refused) or a mid-sweep socket loss, both surfaced as a failed tally rather than success.
    local confirmed=0 failed=0 path
    while IFS= read -r -d '' path; do
        if "${HANDBACK_CLIENT}" CHOWN "${path}" >/dev/null 2>&1; then
            confirmed=$(( confirmed + 1 ))
        else
            failed=$(( failed + 1 ))
        fi
    done < <(find "${session_working_directory}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -user '@SANDBOX_USER@' '(' -type f -o -type d ')' -print0 ')' 2>/dev/null)
    if (( failed > 0 )); then
        audit warning "session-end sweep: handed back ${confirmed} path(s), ${failed} not handed back under ${session_working_directory} (agent=${agent_name}); reclaim with: ai-tools --reclaim ${session_working_directory}"
    elif (( confirmed > 0 )); then
        audit info "session-end sweep: handed back ${confirmed} path(s) under ${session_working_directory} (agent=${agent_name})"
    fi
    return 0
}

# ── Launch ───────────────────────────────────────────────────────────────────────────────────
# Three versions are reported and logged: Node from the validated executable path, the agent from
# its npm package.json, and ai-tools from the value stamped at install (@*@ means an
# unsubstituted source tree). The agent version is read from a file the sandbox account OWNS, so
# it is accepted only in MAJOR.MINOR.PATCH shape -- untrusted input reaching the operator's
# terminal and journal, where a crafted value could otherwise inject terminal escapes.
readonly VERSION_PATTERN='^v?[0-9]+\.[0-9]+\.[0-9]+$'
ai_tools_version="@AI_TOOLS_VERSION@"; [[ "${ai_tools_version}" == @*@ ]] && ai_tools_version="dev"
[[ "${node_version}" =~ ${VERSION_PATTERN} ]] || node_version="n/a"

agent_version="n/a"
package_directory="${session_exec_path}"
for _ in 1 2 3; do
    package_directory="${package_directory%/*}"
    [[ -n "${package_directory}" && -f "${package_directory}/package.json" ]] && break
done
if [[ -n "${package_directory}" && -r "${package_directory}/package.json" ]]; then
    # Bounded read of a regular file: the version sits in the first bytes, and a fifo swapped in
    # must never block the launch.
    declared_version="$(head -c 65536 -- "${package_directory}/package.json" 2>/dev/null \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    [[ "${declared_version}" =~ ${VERSION_PATTERN} ]] && agent_version="${declared_version}"
fi
audit info "versions: ${agent_name}=${agent_version} node=${node_version} ai-tools=${ai_tools_version}"

show_banner=1
[[ $# -eq 1 ]] && case "$1" in --version|-v|--help|-h) show_banner=0 ;; esac
if (( show_banner )); then
    printf -v banner_agent_line '%-13s%s' "${agent_display_name}" "$(ai_tools_msg_version "${agent_version}")"
    printf -v banner_node_line  '%-13s%s' 'Node'                  "$(ai_tools_msg_version "${node_version}")"
    printf -v banner_tools_line '%-13s%s' 'ai-tools'              "$(ai_tools_msg_version "${ai_tools_version}")"
    ai_tools_msg_banner 'Agent Tools Restricted — Starting sandboxed session...' \
        "${banner_agent_line}" "${banner_node_line}" "${banner_tools_line}"
fi

# The unit name identifies the session in `systemctl --user list-units` and the journal; the pid
# suffix keeps concurrent sessions from colliding.
session_unit_name="@SANDBOX_USER@-${agent_name}-$$.service"
declare -a working_directory_option=()
[[ -n "${session_working_directory}" ]] \
    && working_directory_option=( "--working-directory=${session_working_directory}" )

# The session's own stdout/stderr are the terminal (--pty), so the per-unit journal is empty on a
# clean run -- filtering by _SYSTEMD_USER_UNIT shows "No entries". The launch diagnostics (versions,
# confinement inputs, refusals) are logged under the `ai-tools-run` tag as root: the sandbox account
# is deliberately not in systemd-journal, so an operator reads them via sudo. Point at that tag,
# where the records actually are, rather than the empty per-unit filter. `-n 50 --no-pager` shows the
# recent records plainly -- `-e` (jump to end) leaves the pager padding the screen above short output
# with `~`, which reads as confusing blank lines.
if [[ -t 1 ]]; then
    printf 'Running as unit: %s\n' "${session_unit_name}"
    printf '%s  launch log: sudo journalctl -t ai-tools-run _UID=%s -n 50 --no-pager%s\n\n' \
        $'\033[2m' "${EUID}" $'\033[0m'
fi

# An EXIT trap rather than a call after the run, so an interrupted shim (Ctrl-C, SIGTERM) still
# converges the tree; a SIGKILL leaves it to the next session's sweep or `ai-tools --reclaim`.
if ai_tools_agent_sweeps_at_exit "${agent_handback}"; then
    trap 'sweep_project_ownership || true' EXIT
fi

# ── Last-moment entrypoint re-validation ─────────────────────────────────────────────────────
# Everything between resolving the entrypoint and starting the unit -- the label probe, the version
# reads, the session-env fragments, the banner -- is time in which a concurrent process running as
# this same account could swap the file out from under the check. Re-resolve and re-stat here, at
# the last instruction before the launch, so the window such a process would have to win is the
# systemd-run round trip rather than the whole preflight.
#
# This NARROWS the race; it does not close it. Only an exec root the agent cannot write removes it,
# which is exactly what the SELinux types give: on an enforcing host with the module loaded the nvm
# tree is read-only to ai_tools_t and there is no move to make, so this check is for the DAC-only
# deployment, where it is the only observer of a swap. Both the path and the identity are compared:
# a repoint changes the path, a rename-over keeps it and changes the inode, an in-place write keeps
# both and changes ctime.
# The pin is checked in the same breath, this being the one place where hashing the file and
# starting it are adjacent. A MISMATCH means the binary changed after root verified it, and refuses;
# an UNPINNED entrypoint launches unless the operator required otherwise. Why those two outcomes
# differ, and what each costs, are in updater.rule.md.
entrypoint_pin_verdict=unchecked
# Guarded, not bare: the pin is a check the launch tightens with, and a missing library is a broken
# install rather than agent action -- it degrades to "unchecked", which the require switch below
# turns into a refusal on a host that declared verification mandatory.
# shellcheck source=SCRIPTDIR/../../../usr/local/lib/ai-tools/entrypoint-verify.lib.sh
if source "${AI_TOOLS_LIB_DIR}/entrypoint-verify.lib.sh" 2>/dev/null \
        && declare -F ai_tools_entrypoint_check >/dev/null 2>&1; then
    entrypoint_pin_verdict="$(ai_tools_entrypoint_check "${agent_name}" "${session_exec_path}")" || true
fi
# Through the library's own accessor, so this launch and the updater's activation gate cannot
# disagree about how strict the host is.
require_entrypoint_verify=no
declare -F ai_tools_entrypoint_verify_required >/dev/null 2>&1 \
    && ai_tools_entrypoint_verify_required && require_entrypoint_verify=yes
audit info "entrypoint: agent=${agent_name} pin=${entrypoint_pin_verdict} require=${require_entrypoint_verify}"

case "${entrypoint_pin_verdict}" in
    mismatch)
        audit warning "REFUSED: entrypoint does not match its pin (${session_exec_path})"
        refuse 'the agent entrypoint does not match the checksum its vendor signed for the installed version -- refusing to start the session' \
               "entrypoint:  ${session_exec_path}" \
               'The binary changed after it was verified. Treat this toolchain as tampered and reprovision it:' \
               '  sudo ai-tools-bootstrap' ;;
    ok) ;;
    *)  if [[ "${require_entrypoint_verify}" == yes ]]; then
            audit warning "REFUSED: entrypoint unverified (${entrypoint_pin_verdict}) and AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY is set"
            refuse 'refusing to launch -- AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY is set in operator.conf, but this entrypoint carries no verified checksum.' \
                   'Pin it (this fetches the vendor'"'"'s signed release manifest, so the host must be online):' \
                   '  ai-tools --relabel'
        fi ;;
esac

if [[ "$(resolve_entrypoint || true)" != "${session_exec_path}" \
      || "$(entrypoint_identity "${session_exec_path}")" != "${session_exec_identity}" ]]; then
    audit warning "REFUSED: entrypoint changed between preflight and launch (${session_exec_path})"
    refuse 'the agent entrypoint changed while this launch was being prepared -- refusing to start the session' \
           "entrypoint:  ${session_exec_path}" \
           'A toolchain update running at the same moment explains this: rerun the launch.' \
           'If it repeats with no update running, treat the toolchain as untrusted:' \
           'reprovision it:  sudo ai-tools-bootstrap'
fi

# ExecStart is the RESOLVED entrypoint, not the launcher symlink: the manager's execve performs the
# domain transition on the same inode this shim verified, with no link left for it to re-resolve.
# Run rather than exec: --pty implies --wait and returns the payload's status, which a fast failure
# below turns into an actionable breadcrumb.
session_start_seconds=${SECONDS}
session_exit_status=0
systemd-run --user --pty --quiet \
    --unit="${session_unit_name}" \
    --description="${agent_display_name} @SANDBOX_USER@ session" \
    "${session_environment_options[@]}" \
    "${working_directory_option[@]}" \
    --property=RestrictNamespaces=yes \
    --property=NoNewPrivileges=yes \
    --property=UMask=0007 \
    -- "${session_exec_path}" "$@" || session_exit_status=$?

if (( session_exit_status != 0 && SECONDS - session_start_seconds < 5 )); then
    audit warning "session unit ${session_unit_name} exited with status ${session_exit_status} at startup"
    ai_tools_msg_warn \
        "ai-tools-run: the session exited with status ${session_exit_status} almost immediately." \
        "If it ended with no output, the sandbox toolchain may be incompletely" \
        "installed -- reprovision it as root, then relaunch:"
    printf '  sudo ai-tools-bootstrap\n' >&2
fi
exit "${session_exit_status}"
