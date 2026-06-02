#!/usr/bin/env bash
# selinux/install-selinux.sh -- build, load, and label the ai_tools SELinux
# confinement. Separate from the main install.sh on purpose: this is an extra
# MAC layer, brought up independently via the audit2allow loop in README.md.
#
# The core module ships PERMISSIVE -- installing it BLOCKS NOTHING, it only
# starts logging what ai_tools_t does. Optional groups extend the surface but
# are still gated by the same `permissive ai_tools_t;` line in the core module
# until that line is removed. Graduate to enforcing only after the audit2allow
# loop reports only expected boundary denials.
#
# Usage:
#   sudo ./install-selinux.sh install              build core + prompt for groups
#   sudo ./install-selinux.sh relabel              re-apply labels (after Node upgrade)
#   sudo ./install-selinux.sh remove               unload all ai_tools* modules + labels
#   sudo ./install-selinux.sh enable-group <name>  build and load one policy group
#   sudo ./install-selinux.sh disable-group <name> unload one policy group
#   sudo ./install-selinux.sh list-groups          show group availability and state
#
# Prerequisite:  sudo dnf install selinux-policy-devel
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
REAL_USER="${SUDO_USER:?selinux: invoke via sudo, not as root directly}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
readonly ALLOWLIST="${REAL_HOME}/.config/ai-tools/allowed-projects"
# The user-owned ai-tools config dir (allowed-projects, secret-patterns). Labelled
# ai_tools_conf_t so the root ai-tools-chown helper -- which runs IN ai_tools_t with
# no transition -- can read the allowlist; without it the helper's getattr is denied
# (config_home_t:file is dontaudit'd) and ownership handback silently no-ops. The
# label is scoped to this one dir so the rest of ~/.config stays unreadable to the
# domain. Applied via semanage (dynamic home path), not ai_tools.fc (fixed paths).
readonly CONF_DIR="${REAL_HOME}/.config/ai-tools"

log()  { printf 'selinux: %s\n' "$*"; }
logx() { printf 'selinux: %s\n' "$*" >&2; }   # stderr -- safe inside subshells

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

require_devel() {
    command -v make >/dev/null && [[ -f /usr/share/selinux/devel/Makefile ]] \
        || { log "missing selinux-policy-devel (sudo dnf install selinux-policy-devel)" >&2; exit 1; }
}

build_pp() {
    local pp="$1"
    require_devel
    log "building ${pp}"
    make -C "${DIR}" -f /usr/share/selinux/devel/Makefile "${pp}"
    # The refpolicy Makefile creates *.fc stubs as root. Fix ownership so the
    # source file remains readable/commitable by the repo owner.
    local base="${DIR}/${pp%.pp}"
    [[ -f "${base}.fc" ]] \
        && chown "${REAL_USER}:ai-tools" "${base}.fc" 2>/dev/null \
        && chmod 664 "${base}.fc" 2>/dev/null \
        || true
}

is_group_loaded() {
    semodule -l 2>/dev/null | grep -q "^ai_tools_${1}[[:space:]]"
}

valid_group() {
    local name="$1" entry
    for entry in "${POLICY_GROUPS[@]}"; do
        [[ "$(_gname "${entry}")" == "${name}" ]] && return 0
    done
    return 1
}

########################################
# Interactive group prompt
#
# Prints everything to stderr so it doesn't contaminate stdout.
# Populates the caller's SELECTED_GROUPS array.
########################################
SELECTED_GROUPS=()

prompt_groups() {
    logx ""
    logx "=== Optional policy groups (all default: disabled) ==="
    logx "Core module alone covers: project/home/tmp files, git, coreutils,"
    logx "outbound HTTPS to the Anthropic API, sudo->chown/symlink helpers."
    logx "Enable groups only when tasks require reaching into system context."
    logx ""

    local entry name desc ans
    for entry in "${POLICY_GROUPS[@]}"; do
        name="$(_gname "${entry}")"
        desc="$(_gdesc "${entry}")"
        if [[ -t 0 ]]; then
            printf 'selinux:   [%s] %s\n' "${name}" "${desc}" >&2
            printf 'selinux:   Enable? [y/N] ' >&2
            read -r ans </dev/tty
            [[ "${ans,,}" == y* ]] && SELECTED_GROUPS+=("${name}")
        else
            logx "  [${name}] ${desc}  -> default: no (non-interactive)"
        fi
    done
    logx ""
}

########################################
# Label helpers
########################################

verify_entrypoint() {
    local exe ctx found=0
    for exe in /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe; do
        [[ -e "${exe}" ]] || continue
        found=1
        restorecon -Fv "${exe}" 2>/dev/null || true
        ctx="$(ls -Zd "${exe}" 2>/dev/null | awk '{print $1}')"
        if [[ "${ctx}" == *:ai_tools_exec_t:* ]]; then
            log "entrypoint OK: ${exe} -> ai_tools_exec_t"
        else
            log "WARNING: ${exe}"
            log "         is '${ctx}', NOT ai_tools_exec_t -- the transition will NOT fire and"
            log "         claude will run UNCONFINED. matchpathcon expects:"
            log "           $(matchpathcon "${exe}" 2>/dev/null | awk '{print $2}')"
            log "         Chase with: restorecon -nv '${exe}'  and  semanage fcontext -C -l"
        fi
    done
    [[ "${found}" -eq 1 ]] || log "WARNING: no claude.exe found under the nvm tree to label"
    log "REMINDER: a running claude keeps its OLD context -- exit and relaunch, then"
    log "          confirm with:  ps -eo label,cmd | grep '[c]laude'  (expect ai_tools_t)"
}

for_each_project() {
    local fn="$1" entry dir
    [[ -f "${ALLOWLIST}" ]] || return 0
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* || "${entry}" == '!'* ]] && continue
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        "${fn}" "${dir}"
    done < "${ALLOWLIST}"
}

_home_state()  { local p; for p in "${HOME_STATE[@]}"; do
                   restorecon -RF "/opt/ai-tools/${p}" 2>/dev/null || true
                 done; }
_label_one()   { semanage fcontext -a -t ai_tools_project_t "$1(/.*)?" 2>/dev/null \
                 || semanage fcontext -m -t ai_tools_project_t "$1(/.*)?" 2>/dev/null || true
                 restorecon -RF "$1" 2>/dev/null || true
                 log "labelled project ai_tools_project_t: $1"; }
_unlabel_one() { semanage fcontext -d "$1(/.*)?" 2>/dev/null || true; }
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
                      logx "WARN: could not set ai_tools_conf_t fcontext on ${CONF_DIR}"
                      logx "      type undefined? the module must be LOADED first --"
                      logx "      run 'install' (build_pp + semodule -i), not just 'relabel'."
                  fi; }
_unlabel_conf() { semanage fcontext -d "${CONF_DIR}(/.*)?" 2>/dev/null || true
                  restorecon -RF "${CONF_DIR}" 2>/dev/null || true; }

########################################
# Actions
########################################

case "${ACTION}" in

  install)
    build_pp "${MODULE}.pp"
    if grep -qE '^[[:space:]]*permissive[[:space:]]+ai_tools_t[[:space:]]*;' "${DIR}/${MODULE}.te"; then
        _mode="PERMISSIVE"
    else
        _mode="ENFORCING"
    fi
    log "loading core module (${_mode})"
    semodule -i "${DIR}/${MODULE}.pp"

    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    _home_state
    verify_entrypoint
    _label_conf
    for_each_project _label_one

    prompt_groups
    for name in "${SELECTED_GROUPS[@]+"${SELECTED_GROUPS[@]}"}"; do
        build_pp "ai_tools_${name}.pp"
        log "loading group: ai_tools_${name}"
        semodule -i "${DIR}/ai_tools_${name}.pp"
        log "group '${name}' enabled."
    done

    if [[ "${_mode}" == PERMISSIVE ]]; then
        log "done. Core module PERMISSIVE -- nothing is blocked yet."
        log "NEXT: follow README.md (audit2allow) before removing 'permissive ai_tools_t;'."
    else
        log "done. Core module ENFORCING -- denials are now active."
    fi
    if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
        log "Groups enabled: ${SELECTED_GROUPS[*]}"
        if [[ "${_mode}" == PERMISSIVE ]]; then
            log "Re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to cover"
            log "the expanded surface before removing 'permissive ai_tools_t;'."
        fi
    fi
    log "verify:  semodule -l | grep ai_tools;  matchpathcon ${HOME_DIR}"
    log "after launching claude:  ps -eo label,cmd | grep -m1 claude   (expect ai_tools_t)"
    ;;

  relabel)
    log "re-applying labels"
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    _home_state
    verify_entrypoint
    _label_conf
    for_each_project _label_one
    log "relabel done"
    ;;

  remove)
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
    log "removed."
    ;;

  enable-group)
    name="${2:?usage: sudo $0 enable-group <name>}"
    if ! valid_group "${name}"; then
        log "unknown group '${name}'. Available groups:" >&2
        for entry in "${POLICY_GROUPS[@]}"; do
            printf 'selinux:   %-10s %s\n' "$(_gname "${entry}")" "$(_gdesc "${entry}")" >&2
        done
        exit 1
    fi
    build_pp "ai_tools_${name}.pp"
    log "loading group: ai_tools_${name}"
    semodule -i "${DIR}/ai_tools_${name}.pp"
    log "group '${name}' enabled."
    log "Re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to catch any"
    log "new denials from the expanded surface before going enforcing."
    ;;

  disable-group)
    name="${2:?usage: sudo $0 disable-group <name>}"
    if is_group_loaded "${name}"; then
        semodule -r "ai_tools_${name}"
        log "group '${name}' disabled."
    else
        log "group 'ai_tools_${name}' is not currently loaded -- nothing to do."
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
    log "Core module (${MODULE}): ${core_state}"
    log "Optional policy groups:"
    for entry in "${POLICY_GROUPS[@]}"; do
        gname="$(_gname "${entry}")"
        gdesc="$(_gdesc "${entry}")"
        if is_group_loaded "${gname}"; then
            printf 'selinux:   [LOADED]   %-10s -- %s\n' "${gname}" "${gdesc}"
        else
            printf 'selinux:   [disabled] %-10s -- %s\n' "${gname}" "${gdesc}"
        fi
    done
    log ""
    log "Toggle:  sudo $0 enable-group <name>  |  sudo $0 disable-group <name>"
    ;;

  *)
    cat >&2 <<EOF
selinux: usage: sudo $0 <action> [args]

  install              build core + prompt for optional groups
  relabel              re-apply labels (run after a Node upgrade)
  remove               unload all ai_tools* modules and revert labels
  enable-group <name>  build and load one optional policy group
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
