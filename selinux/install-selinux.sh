#!/usr/bin/env bash
# selinux/install-selinux.sh -- build, load, and label the optional ai_tools
# SELinux confinement. Separate from the main install.sh on purpose: this is an
# extra MAC layer, brought up independently.
#
# The module ships PERMISSIVE -- installing it BLOCKS NOTHING, it only starts
# logging what ai_tools_t does. Graduate to enforcing only after the audit2allow
# bring-up pass in README.md.
#
# Usage:
#   sudo ./install-selinux.sh install     build .pp, load module, label home + projects
#   sudo ./install-selinux.sh relabel     re-apply labels (run after a Node upgrade)
#   sudo ./install-selinux.sh remove      unload module, drop labels, revert contexts
#
# Prerequisite:  sudo dnf install selinux-policy-devel

set -euo pipefail
IFS=$'\n\t'

readonly ACTION="${1:-install}"
readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE="ai_tools"
readonly HOME_DIR="/opt/ai-tools/.claude"
readonly NVM_DIR="/opt/ai-tools/.nvm"

[[ "${EUID}" -eq 0 ]] || { echo "selinux: run with sudo" >&2; exit 1; }
REAL_USER="${SUDO_USER:?selinux: invoke via sudo, not as root directly}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
readonly ALLOWLIST="${REAL_HOME}/.config/ai-tools/allowed-projects"

log() { printf 'selinux: %s\n' "$*"; }

[[ "$(getenforce 2>/dev/null)" != "Disabled" ]] \
    || { log "SELinux is disabled -- nothing to do"; exit 0; }

# For each allow (non-#, non-!) entry in the allowlist, run FN with the resolved
# absolute project dir.
for_each_project() {
    local fn="$1" entry dir
    [[ -f "${ALLOWLIST}" ]] || return 0
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* || "${entry}" == '!'* ]] && continue
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        "${fn}" "${dir}"
    done < "${ALLOWLIST}"
}

_label_one()   { semanage fcontext -a -t ai_tools_project_t "$1(/.*)?" 2>/dev/null \
                 || semanage fcontext -m -t ai_tools_project_t "$1(/.*)?" 2>/dev/null || true
                 restorecon -RF "$1" 2>/dev/null || true
                 log "labelled project ai_tools_project_t: $1"; }
_unlabel_one() { semanage fcontext -d "$1(/.*)?" 2>/dev/null || true; }
_restore_one() { restorecon -RF "$1" 2>/dev/null || true; }

case "${ACTION}" in
  install)
    command -v make >/dev/null && [[ -f /usr/share/selinux/devel/Makefile ]] \
        || { echo "selinux: missing selinux-policy-devel (sudo dnf install selinux-policy-devel)" >&2; exit 1; }
    log "building ${MODULE}.pp"
    make -C "${DIR}" -f /usr/share/selinux/devel/Makefile "${MODULE}.pp"
    log "loading module (PERMISSIVE)"
    semodule -i "${DIR}/${MODULE}.pp"
    # claude.exe entrypoint + .claude home contexts come from ai_tools.fc; apply
    # them to the live tree. Project dirs are dynamic -> semanage fcontext below.
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true
    for_each_project _label_one
    log "done. The module is loaded PERMISSIVE -- nothing is blocked yet."
    log "verify:  semodule -l | grep ${MODULE};  matchpathcon ${HOME_DIR}"
    log "after launching claude:  ps -eo label,cmd | grep -m1 claude   (expect ai_tools_t)"
    log "NEXT: follow README.md (audit2allow) before removing 'permissive ai_tools_t;'."
    ;;
  relabel)
    log "re-applying labels"
    restorecon -RF "${HOME_DIR}" 2>/dev/null || true
    restorecon -RF "${NVM_DIR}"  2>/dev/null || true   # picks up a new claude.exe after upgrade
    for_each_project _label_one
    log "relabel done"
    ;;
  remove)
    log "dropping project fcontext rules"
    for_each_project _unlabel_one
    log "unloading module (also removes its home/entrypoint fcontext rules)"
    semodule -r "${MODULE}" 2>/dev/null || true
    log "reverting contexts to defaults"
    _restore_one "${HOME_DIR}"
    _restore_one "${NVM_DIR}"
    for_each_project _restore_one
    log "removed."
    ;;
  *)
    echo "usage: sudo $0 [install|relabel|remove]" >&2; exit 1 ;;
esac
