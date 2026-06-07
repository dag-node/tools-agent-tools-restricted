#!/usr/bin/env bash
# selinux/install-selinux.sh -- load and label the ai_tools SELinux confinement.
# Separate from the main install.sh on purpose: this is an extra MAC layer, brought
# up independently and refined via the audit2allow loop in README.md.
#
# The core module ships PREBUILT (ai_tools.pp) and ENFORCING, so a normal install
# needs no toolchain -- it loads the shipped package and labels the tree. To go
# permissive instead (to observe before blocking), uncomment `permissive
# ai_tools_t;` in ai_tools.te and recompile; the installer detects the mode from
# the source and reports it.
#
# Usage:
#   sudo ./install-selinux.sh install              load prebuilt core (opt. recompile) + prompt for groups
#   sudo ./install-selinux.sh rebuild              recompile core from source (.te/.fc) + reload + relabel
#   sudo ./install-selinux.sh relabel              re-apply labels (after Node upgrade)
#   sudo ./install-selinux.sh remove               unload all ai_tools* modules + labels
#   sudo ./install-selinux.sh enable-group <name>  load one optional policy group
#   sudo ./install-selinux.sh disable-group <name> unload one policy group
#   sudo ./install-selinux.sh list-groups          show group availability and state
#
# selinux-policy-devel is required ONLY to COMPILE a module from source -- i.e. to
# recompile the core or build an optional group (the groups are not shipped
# prebuilt). The shipped core needs no toolchain. Install when needed:
#   sudo dnf install selinux-policy-devel
#
# Policy groups (all DISABLED by default; core alone covers repo-only work):
#   systemd   systemctl, journalctl, unit file reads
#   pkgmgmt   rpm (rpm_exec_t), RPM database (rpm_var_lib_t)
#   netadmin  firewall-cmd D-Bus (firewalld_t), nmcli D-Bus (NetworkManager_t)
#   podman    container runtime exec, image/layer storage reads

set -euo pipefail
IFS=$'\n\t'

readonly ACTION="${1:-install}"
readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE="ai_tools"
readonly HOME_DIR="/opt/ai-tools/.claude"
readonly NVM_DIR="/opt/ai-tools/.nvm"
HOME_STATE=(.claude.json .npm .cache .local .config .gitconfig)

[[ "${EUID}" -eq 0 ]] || { echo "selinux: run with sudo" >&2; exit 1; }
PROJECTS_USER="${SUDO_USER:?selinux: invoke via sudo, not as root directly}"
PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" | cut -d: -f6)"
readonly ALLOWLIST="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
# Sandbox clones live here and are labelled ai_tools_project_t by the STATIC rule in
# ai_tools.fc, so the per-project semanage loop skips them (a duplicate local rule
# would be redundant). A plain restorecon of this tree applies the static label.
readonly SANDBOX_PROJECTS="/var/opt/ai-tools/sandbox-projects"
# The user-owned ai-tools config dir (allowed-projects, secret-patterns). Labelled
# ai_tools_conf_t so the root ai-tools-chown helper -- which runs IN ai_tools_t with
# no transition -- can read the allowlist; without it the helper's getattr is denied
# (config_home_t:file is dontaudit'd) and ownership handback silently no-ops. The
# label is scoped to this one dir so the rest of ~/.config stays unreadable to the
# domain. Applied via semanage (dynamic home path), not ai_tools.fc (fixed paths).
readonly CONF_DIR="${PROJECTS_HOME}/.config/ai-tools"
# Root-helper operation logs. Labelled ai_tools_log_t (static rule in ai_tools.fc) so
# the helpers that run IN ai_tools_t (chown, setgid, claude-symlink) may append under
# enforcing. A plain restorecon applies the label; created by install.sh.
readonly LOG_DIR="/var/log/ai-tools"
# The handback socket runtime dir. /run is tmpfs, so systemd recreates this via
# RuntimeDirectory=ai-tools at every ai-tools-handback.socket activation, labelling it
# from PID1's CACHED file_contexts DB. A policy update that adds/changes the
# /run/ai-tools fcontext (ai_tools_run_t) leaves that cache stale, so the dir -- and the
# handback.sock inside it -- are recreated var_run_t, which ai_tools_t may not write
# (ai_tools.te grants only ai_tools_run_t:sock_file write), breaking every hook handback.
# _relabel_runtime() repairs this; a fresh boot reads the current fcontext correctly.
readonly RUN_DIR="/run/ai-tools"

# Styled output mirroring install.sh so the two installers read the same. Colours
# only on a TTY. stdout carries status; warnings and the group prompt go to stderr
# (warn/logx/sayx) so they never contaminate stdout.
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RED=$'\033[31m' C_RST=$'\033[0m'
else
    readonly C_BOLD='' C_DIM='' C_GRN='' C_YEL='' C_RED='' C_RST=''
fi

say()     { printf '%s\n' "$*"; }
section() { printf '\n%s── %s ──%s\n' "${C_BOLD}" "$*" "${C_RST}"; }
ok()      { printf '  %s✓%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
log()     { printf '  %s+%s %s\n' "${C_DIM}" "${C_RST}" "$*"; }
warn()    { printf '  %s!%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()     { printf '%sselinux: error:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }
# logx/sayx: stderr variants -- safe inside subshells, and used for the group
# prompt, which must not contaminate stdout.
logx()    { printf '  %s+%s %s\n' "${C_DIM}" "${C_RST}" "$*" >&2; }
sayx()    { printf '%s\n' "$*" >&2; }

[[ "$(getenforce 2>/dev/null)" != "Disabled" ]] \
    || { log "SELinux is disabled -- nothing to do"; exit 0; }

########################################
# Optional policy group registry
#
# Each entry is a pipe-delimited record:
#   name | install-prompt description | agent-facing reason (surfaced when needed)
#
# The reason text is what the agent quotes when a task needs a group that is not
# loaded: it explains WHY in terms of the SELinux type mismatch, then gives the
# exact command to run.
########################################
POLICY_GROUPS=(
    "systemd\
|System inspection (systemctl, journalctl, unit files)\
|systemctl is labelled systemd_systemctl_exec_t; ai_tools_t needs execute +\
 D-Bus access to query PID 1. journalctl is journalctl_exec_t."
    "pkgmgmt\
|Package management (rpm, dnf, RPM database)\
|/usr/bin/rpm is labelled rpm_exec_t (not bin_t); the RPM database is\
 rpm_var_lib_t. Both need explicit allow rules. dnf is bin_t (already\
 executable) but also reads rpm_var_lib_t."
    "netadmin\
|Network administration (firewall-cmd D-Bus, nmcli D-Bus)\
|firewall-cmd and nmcli are bin_t (already executable) but send commands\
 to firewalld_t and NetworkManager_t via D-Bus; ai_tools_t lacks the\
 dbus send_msg permission those daemons require."
    "podman\
|Container operations (podman/buildah exec, image storage reads)\
|/usr/bin/podman is labelled container_runtime_exec_t; ai_tools_t cannot\
 execute it without this group. Container image storage (container_file_t)\
 is dontaudit'd in the core module and needs explicit read here."
)

# Parse record fields from a POLICY_GROUPS entry.
_gname()   { printf '%s' "${1%%|*}"; }
_gdesc()   { local s="${1#*|}"; printf '%s' "${s%%|*}"; }
_greason() { printf '%s' "${1##*|}"; }

########################################
# Build helpers
########################################

# require_devel <pp>: exit with install guidance unless the refpolicy devel
# toolchain (make + /usr/share/selinux/devel/Makefile from selinux-policy-devel) is
# present. Only reached when a module must be COMPILED from source -- the core
# module ships prebuilt, so a normal install never lands here; it is the optional
# (non-core) groups, which are not shipped prebuilt, that require the toolchain.
require_devel() {
    command -v make >/dev/null && [[ -f /usr/share/selinux/devel/Makefile ]] && return 0
    warn "building ${1:-this policy module} needs the selinux-policy-devel toolchain,"
    warn "  which is not installed. The core module ships prebuilt and needs no"
    warn "  toolchain; only the optional groups must be compiled. Install it with:"
    warn "      sudo dnf install selinux-policy-devel"
    warn "  then re-run. See ${DIR}/README.md for the policy build/bring-up workflow."
    exit 1
}

# ensure_pp <module.pp>: guarantee the compiled package ${DIR}/<module.pp> exists.
# Prefers the prebuilt package shipped in the repo so a normal install needs no
# toolchain; compiles from source (requiring selinux-policy-devel) only when the
# package is absent -- i.e. an optional group, or after editing the .te/.fc source.
ensure_pp() {
    local pp="$1"
    if [[ -f "${DIR}/${pp}" ]]; then
        log "using prebuilt ${pp}"
    else
        build_pp "${pp}"
    fi
}

# build_pp <module.pp>: compile the named policy module from its .te/.fc source via
# the refpolicy Makefile, then restore the .fc stub's ownership to the repo owner
# (the Makefile creates it as root).
build_pp() {
    local pp="$1"
    require_devel "${pp}"
    log "building ${pp}"
    make -C "${DIR}" -f /usr/share/selinux/devel/Makefile "${pp}"
    # The refpolicy Makefile creates *.fc stubs as root. Fix ownership so the
    # source file remains readable/commitable by the repo owner.
    local base="${DIR}/${pp%.pp}"
    [[ -f "${base}.fc" ]] \
        && chown "${PROJECTS_USER}:ai-tools" "${base}.fc" 2>/dev/null \
        && chmod 664 "${base}.fc" 2>/dev/null \
        || true
}

# is_group_loaded <name>: return 0 if the optional policy group ai_tools_<name> is
# currently loaded in the kernel (semodule -l).
is_group_loaded() {
    semodule -l 2>/dev/null | grep -q "^ai_tools_${1}[[:space:]]"
}

# valid_group <name>: return 0 if <name> is a known group in POLICY_GROUPS.
valid_group() {
    local name="$1" entry
    for entry in "${POLICY_GROUPS[@]}"; do
        [[ "$(_gname "${entry}")" == "${name}" ]] && return 0
    done
    return 1
}

# _mode_label: read ai_tools.te and return a human-readable enforcement label.
# If every permissive line is commented out -> "ENFORCING".
# Otherwise -> "PERMISSIVE (<dom> ...)" listing the still-permissive domains.
_mode_label() {
    local doms
    doms=$(grep -E '^[[:space:]]*permissive[[:space:]]+ai_tools_[^[:space:]]+[[:space:]]*;' \
               "${DIR}/${MODULE}.te" 2>/dev/null \
           | awk '{gsub(/;/,""); print $2}' | paste -sd ' ')
    if [[ -n "${doms}" ]]; then
        printf 'PERMISSIVE (%s)' "${doms}"
    else
        printf 'ENFORCING'
    fi
}

# _check_permissive_alignment: after semodule -i, verify that no stale
# semanage-managed permissive_<domain> module is keeping a domain permissive
# despite the compiled .te expecting it to be enforcing.  Warns and offers to
# remove the stale module interactively; prints the fix command otherwise.
_check_permissive_alignment() {
    # Domains the compiled .te expects permissive (non-commented permissive lines).
    local expected_permissive
    expected_permissive=$(grep -E '^[[:space:]]*permissive[[:space:]]+ai_tools_[^[:space:]]+[[:space:]]*;' \
                          "${DIR}/${MODULE}.te" 2>/dev/null \
                          | awk '{gsub(/;/,""); print $2}')

    # All ai_tools_* domains currently permissive in the running kernel.
    local active_permissive
    active_permissive=$(seinfo --permissive 2>/dev/null | grep -E '^\s+ai_tools_' | tr -d ' ')

    [[ -z "${active_permissive}" ]] && return 0

    local dom stale_mod ans misaligned=()
    while IFS= read -r dom; do
        [[ -z "${dom}" ]] && continue
        echo "${expected_permissive}" | grep -qx "${dom}" && continue   # expected
        misaligned+=("${dom}")
    done <<< "${active_permissive}"

    [[ ${#misaligned[@]} -eq 0 ]] && return 0

    warn "ENFORCING MISMATCH -- domain(s) are permissive but .te expects enforcing:"
    for dom in "${misaligned[@]}"; do
        stale_mod="permissive_${dom}"
        if semodule -l 2>/dev/null | grep -q "^${stale_mod}[[:space:]]"; then
            warn "  ${dom}: stale semodule '${stale_mod}' overrides compiled policy"
            if [[ -t 0 ]]; then
                printf '  %s!%s  Remove stale module %s? [Y/n] ' "${C_YEL}" "${C_RST}" "${stale_mod}" >&2
                read -r ans </dev/tty
                case "${ans,,}" in
                    n*) warn "  leaving '${stale_mod}' -- ${dom} will remain PERMISSIVE" ;;
                    *)  semodule -r "${stale_mod}"
                        ok "removed '${stale_mod}' -- ${dom} is now ENFORCING" ;;
                esac
            else
                warn "  fix: sudo semodule -r ${stale_mod}"
            fi
        else
            warn "  ${dom}: no permissive_${dom} module found -- check semanage permissive -l"
            warn "  fix:  sudo semanage permissive -d ${dom}"
        fi
    done
}

########################################
# Interactive group prompt
#
# Prints everything to stderr so it doesn't contaminate stdout.
# Populates the caller's SELECTED_GROUPS array.
########################################
SELECTED_GROUPS=()

prompt_groups() {
    section "Optional policy groups (all default: disabled)" >&2
    sayx "  Core alone covers project/home/tmp files, git, coreutils, HTTPS to the"
    sayx "  Anthropic API, and the sudo->helper calls. Enable a group only when a task"
    sayx "  must reach into system context."
    warn "These groups are EXPERIMENTAL drafts -- audit each under permissive before"
    warn "  relying on it (see the avc-denials harness)."
    sayx ""

    local entry name desc ans
    for entry in "${POLICY_GROUPS[@]}"; do
        name="$(_gname "${entry}")"
        desc="$(_gdesc "${entry}")"
        if [[ -t 0 ]]; then
            printf '    %s[%s]%s %s\n' "${C_DIM}" "${name}" "${C_RST}" "${desc}" >&2
            printf '    Enable? [y/N] ' >&2
            read -r ans </dev/tty
            [[ "${ans,,}" == y* ]] && SELECTED_GROUPS+=("${name}")
        else
            sayx "    [${name}] ${desc}  -> default: no (non-interactive)"
        fi
    done
    sayx ""
}

########################################
# Label helpers
########################################

# The per-project label primitive (semanage fcontext + restorecon) lives in the
# shared relabel.lib.sh -- the SAME body the ai-tools-relabel root helper runs, so
# --project-create/--project-claim and this sweep cannot drift. Prefer the repo
# copy alongside this script; fall back to the deployed lib.
RELABEL_LIB="${DIR}/../src/usr/local/lib/ai-tools/relabel.lib.sh"
[[ -r "${RELABEL_LIB}" ]] || RELABEL_LIB="/usr/local/lib/ai-tools/relabel.lib.sh"
# shellcheck source=/dev/null
source "${RELABEL_LIB}" || die "missing label library: ${RELABEL_LIB}"

# verify_entrypoint: relabel the claude.exe entrypoint under the nvm tree and
# confirm it carries ai_tools_exec_t. Logs a WARNING for any entrypoint that does
# not -- without that label the unconfined_t -> ai_tools_t transition never fires
# and claude runs unconfined.
verify_entrypoint() {
    local exe ctx found=0
    for exe in /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe; do
        [[ -e "${exe}" ]] || continue
        found=1
        restorecon -Fv "${exe}" 2>/dev/null || true
        ctx="$(ls -Zd "${exe}" 2>/dev/null | awk '{print $1}')"
        if [[ "${ctx}" == *:ai_tools_exec_t:* ]]; then
            ok "entrypoint labelled ai_tools_exec_t: ${exe}"
        else
            warn "${exe}"
            warn "    is '${ctx}', NOT ai_tools_exec_t -- the transition will NOT fire and"
            warn "    claude will run UNCONFINED. matchpathcon expects:"
            warn "      $(matchpathcon "${exe}" 2>/dev/null | awk '{print $2}')"
            warn "    chase with: restorecon -nv '${exe}'  and  semanage fcontext -C -l"
        fi
    done
    [[ "${found}" -eq 1 ]] || warn "no claude.exe found under the nvm tree to label"
    log "reminder: a running claude keeps its OLD context -- exit and relaunch, then"
    log "          confirm with:  ps -eo label,cmd | grep '[c]laude'  (expect ai_tools_t)"
}

# for_each_project <fn>: call <fn> once with each allowlisted project directory,
# skipping blank/comment/'!'-exclusion lines and sandbox clones (labelled
# statically by ai_tools.fc). No-op when the allowlist is absent.
for_each_project() {
    local fn="$1" entry dir
    [[ -f "${ALLOWLIST}" ]] || return 0
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* || "${entry}" == '!'* ]] && continue
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        # Sandbox clones are labelled statically (ai_tools.fc); skip the dynamic loop.
        [[ "${dir}/" == "${SANDBOX_PROJECTS}/"* ]] && continue
        "${fn}" "${dir}"
    done < "${ALLOWLIST}"
}

_home_state()  { local p; for p in "${HOME_STATE[@]}"; do
                   restorecon -RF "/opt/ai-tools/${p}" 2>/dev/null || true
                 done; }
# _label_one/_unlabel_one: thin wrappers over the shared lib so this sweep and the
# ai-tools-relabel helper share one implementation. Non-zero is swallowed (warn,
# don't die) so one bad project never aborts a whole relabel. _unlabel_one already
# restorecons via the lib; the remove action's later _restore_one pass is a
# harmless belt-and-suspenders.
_label_one()   { if ai_tools_label_project "$1"; then log "labelled project ai_tools_project_t: $1"
                 else warn "could not label $1 -- is the ai_tools module loaded?"; fi; }
_unlabel_one() { ai_tools_unlabel_project "$1" || warn "could not unlabel $1"; }
_restore_one() { restorecon -RF "$1" 2>/dev/null || true; }
# Label / unlabel ~/.config/ai-tools as ai_tools_conf_t (see CONF_DIR comment).
_label_conf()   { [[ -d "${CONF_DIR}" ]] || { log "config dir absent, skip label: ${CONF_DIR}"; return 0; }
                  # ai_tools_conf_t must already exist in the LOADED policy for
                  # semanage to accept it. 'relabel' never loads the module, so on a
                  # first run (or after a version bump) the type may be undefined --
                  # report honestly instead of logging a false success.
                  if semanage fcontext -a -t ai_tools_conf_t "${CONF_DIR}(/.*)?" 2>/dev/null \
                     || semanage fcontext -m -t ai_tools_conf_t "${CONF_DIR}(/.*)?" 2>/dev/null; then
                      restorecon -RF "${CONF_DIR}" 2>/dev/null || true
                      log "labelled config ai_tools_conf_t: ${CONF_DIR}"
                  else
                      warn "could not set ai_tools_conf_t fcontext on ${CONF_DIR}"
                      warn "    type undefined? the module must be LOADED first --"
                      warn "    run 'install' (loads the module), not just 'relabel'."
                  fi; }
_unlabel_conf() { semanage fcontext -d "${CONF_DIR}(/.*)?" 2>/dev/null || true
                  restorecon -RF "${CONF_DIR}" 2>/dev/null || true; }
# _relabel_runtime: fix the live ai_tools_run_t label on /run/ai-tools (see RUN_DIR).
# A plain restorecon of the other trees is enough because they live on persistent
# filesystems, but the handback runtime dir is tmpfs and recreated by systemd from
# PID1's cached label DB, so three steps are needed: (1) daemon-reexec re-execs PID1 so
# it reloads the now-current file_contexts (the root cause of the stale var_run_t label);
# (2) restart the socket so RuntimeDirectory is recreated with the refreshed context;
# (3) restorecon the live path as a belt-and-suspenders for the already-running dir.
# Each step is best-effort: if the socket unit is absent (handback not installed) the
# whole thing no-ops. A hook firing during the brief socket restart simply no-ops via
# its `|| true` and is recovered by the next sweep.
_relabel_runtime() {
    if systemctl list-unit-files ai-tools-handback.socket &>/dev/null; then
        systemctl daemon-reexec 2>/dev/null || true
        if systemctl is-active --quiet ai-tools-handback.socket; then
            systemctl restart ai-tools-handback.socket 2>/dev/null || true
        fi
    fi
    [[ -d "${RUN_DIR}" ]] && restorecon -RFv "${RUN_DIR}" 2>/dev/null || true
}

# _relabel_helpers: apply ai_tools_handback_exec_t to the handback daemon entrypoint
# (/usr/local/sbin/ai-tools/ai-tools-handback, ai_tools.fc). Without this the daemon
# keeps a generic label, the init_t -> ai_tools_handback_t transition never fires, the
# per-connection handler runs in unconfined_service_t, and ai_tools_t's connectto
# (granted only to ai_tools_handback_t) is denied -- every hook handback fails with
# EACCES. The sibling root helpers and the /usr/local/bin client are bin_t (no special
# label). restorecon is idempotent and no-ops when handback is not installed.
_relabel_helpers() { restorecon -RF /usr/local/sbin/ai-tools 2>/dev/null || true; }

########################################
# Actions
########################################

case "${ACTION}" in

  install)
    section "Core module"
    # The core module ships prebuilt, so a normal install needs no toolchain. Offer
    # a from-source rebuild (needs selinux-policy-devel) for anyone who edited the
    # .te/.fc -- default no. With no prebuilt package present we must build anyway.
    _recompile=0
    if [[ -f "${DIR}/${MODULE}.pp" && -t 0 ]]; then
        printf '  Recompile core module from source? (needs selinux-policy-devel) [y/N] ' >&2
        read -r _ans </dev/tty
        [[ "${_ans,,}" == y* ]] && _recompile=1
    fi
    if (( _recompile )); then
        build_pp "${MODULE}.pp"
    else
        ensure_pp "${MODULE}.pp"
    fi

    _mode="$(_mode_label)"
    log "loading core module (${_mode})"
    semodule -i "${DIR}/${MODULE}.pp"
    ok "core module loaded (${_mode})"
    _check_permissive_alignment

    section "Labelling"
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    # Apply the static sandbox-clone label (ai_tools.fc) to any existing clones.
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -RF "${SANDBOX_PROJECTS}" 2>/dev/null || true
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -RF "${LOG_DIR}" 2>/dev/null || true
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _relabel_helpers
    _home_state
    verify_entrypoint
    _label_conf
    for_each_project _label_one

    prompt_groups
    if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
        section "Optional groups"
        for name in "${SELECTED_GROUPS[@]}"; do
            ensure_pp "ai_tools_${name}.pp"
            log "loading group: ai_tools_${name}"
            semodule -i "${DIR}/ai_tools_${name}.pp"
            ok "group '${name}' enabled"
        done
    fi

    section "SELinux confinement ready"
    if [[ "${_mode}" == PERMISSIVE ]]; then
        ok "core module loaded PERMISSIVE -- nothing is blocked yet"
        log "next: follow README.md (audit2allow) before removing 'permissive ai_tools_t;'"
    else
        ok "core module loaded ENFORCING -- denials are now active"
    fi
    if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
        log "groups enabled: ${SELECTED_GROUPS[*]}"
        if [[ "${_mode}" == PERMISSIVE ]]; then
            log "re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to cover"
            log "the expanded surface before removing 'permissive ai_tools_t;'"
        fi
    fi
    log "verify:  semodule -l | grep ai_tools;  matchpathcon ${HOME_DIR}"
    log "after launching claude:  ps -eo label,cmd | grep -m1 claude  (expect ai_tools_t)"
    ;;

  relabel)
    section "Re-applying labels"
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    # Apply the static sandbox-clone label (ai_tools.fc) to any existing clones.
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -RF "${SANDBOX_PROJECTS}" 2>/dev/null || true
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -RF "${LOG_DIR}" 2>/dev/null || true
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _relabel_helpers
    _home_state
    verify_entrypoint
    _label_conf
    for_each_project _label_one
    ok "relabel done"
    ;;

  rebuild)
    # Recompile the core module from source (.te/.fc) and reload it, then re-apply
    # labels. This is the "rebuild core module" path: use it after editing ai_tools.te
    # or ai_tools.fc so the loaded policy and the shipped ai_tools.pp match the source.
    # Needs the selinux-policy-devel toolchain (build_pp checks and guides if absent).
    section "Rebuilding core module"
    build_pp "${MODULE}.pp"
    _mode="$(_mode_label)"
    log "reloading core module (${_mode})"
    semodule -i "${DIR}/${MODULE}.pp"
    ok "core module rebuilt and reloaded (${_mode})"
    _check_permissive_alignment

    section "Re-applying labels"
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -RF "${SANDBOX_PROJECTS}" 2>/dev/null || true
    [[ -d "${LOG_DIR}" ]] && restorecon -RF "${LOG_DIR}" 2>/dev/null || true
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _relabel_helpers
    _home_state
    verify_entrypoint
    _label_conf
    for_each_project _label_one
    ok "rebuild done"
    ;;

  remove)
    section "Removing SELinux confinement"
    log "dropping project fcontext rules"
    for_each_project _unlabel_one
    _unlabel_conf
    log "unloading all ai_tools* modules"
    # Collect all loaded ai_tools modules then remove in one semodule call.
    mapfile -t loaded < <(semodule -l 2>/dev/null | awk '/^ai_tools/{print $1}')
    if [[ ${#loaded[@]} -gt 0 ]]; then
        semodule -r "${loaded[@]}" 2>/dev/null || true
    fi
    log "reverting contexts to defaults"
    _restore_one "${HOME_DIR}"
    _restore_one "${NVM_DIR}"
    _home_state
    for_each_project _restore_one
    ok "removed"
    ;;

  enable-group)
    name="${2:?usage: sudo $0 enable-group <name>}"
    if ! valid_group "${name}"; then
        warn "unknown group '${name}'. Available groups:"
        for entry in "${POLICY_GROUPS[@]}"; do
            printf '    %-10s %s\n' "$(_gname "${entry}")" "$(_gdesc "${entry}")" >&2
        done
        exit 1
    fi
    section "Enabling group: ${name}"
    ensure_pp "ai_tools_${name}.pp"
    log "loading group: ai_tools_${name}"
    semodule -i "${DIR}/ai_tools_${name}.pp"
    ok "group '${name}' enabled"
    log "re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to catch any"
    log "new denials from the expanded surface before going enforcing"
    ;;

  disable-group)
    name="${2:?usage: sudo $0 disable-group <name>}"
    if is_group_loaded "${name}"; then
        semodule -r "ai_tools_${name}"
        ok "group '${name}' disabled"
    else
        log "group 'ai_tools_${name}' is not currently loaded -- nothing to do"
    fi
    ;;

  list-groups)
    if semodule -l 2>/dev/null | grep -q "^${MODULE}[[:space:]]"; then
        if grep -qE '^[[:space:]]*permissive[[:space:]]+ai_tools_t[[:space:]]*;' "${DIR}/${MODULE}.te"; then
            core_state="loaded (PERMISSIVE)"
        else
            core_state="loaded (ENFORCING)"
        fi
    else
        core_state="NOT loaded"
    fi
    section "SELinux policy state"
    log "core module (${MODULE}): ${core_state}"
    say ""
    say "  Optional policy groups:"
    for entry in "${POLICY_GROUPS[@]}"; do
        gname="$(_gname "${entry}")"
        gdesc="$(_gdesc "${entry}")"
        if is_group_loaded "${gname}"; then
            printf '    %s[LOADED]%s   %-10s -- %s\n' "${C_GRN}" "${C_RST}" "${gname}" "${gdesc}"
        else
            printf '    %s[disabled]%s %-10s -- %s\n' "${C_DIM}" "${C_RST}" "${gname}" "${gdesc}"
        fi
    done
    say ""
    log "toggle:  sudo $0 enable-group <name>  |  sudo $0 disable-group <name>"
    ;;

  *)
    cat >&2 <<EOF
selinux: usage: sudo $0 <action> [args]

  install              load prebuilt core (opt. recompile) + prompt for optional groups
  rebuild              recompile the core module from source (.te/.fc), reload, relabel
  relabel              re-apply labels (run after a Node upgrade)
  remove               unload all ai_tools* modules and revert labels
  enable-group <name>  load one optional policy group (compiles it; needs selinux-policy-devel)
  disable-group <name> unload one optional policy group
  list-groups          show which groups are available and their current state

Optional groups (all disabled by default):
EOF
    for entry in "${POLICY_GROUPS[@]}"; do
        printf '  %-10s %s\n' "$(_gname "${entry}")" "$(_gdesc "${entry}")" >&2
    done
    exit 1
    ;;
esac
