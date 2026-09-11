#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# selinux/install-selinux.sh -- load and label the ai_tools SELinux confinement.
# Separate from the main install.sh on purpose: this is an extra MAC layer, brought
# up independently and refined via the audit2allow loop in README.md.
#
# Every module this script loads is COMPILED from the .te/.fc/.if under policy/ on this host:
# the checkout carries no compiled module (the RPM compiles its own at build time, per
# distribution). The core loads ENFORCING; to go permissive instead (to observe before
# blocking), uncomment `permissive ai_tools_t;` in ai_tools.te and rebuild; the installer
# detects the mode from the source and reports it.
#
# Usage:
#   sudo ./install-selinux.sh install              compile + load core, stage the shipped set, prompt for groups
#   sudo ./install-selinux.sh build                compile + stage the shipped set (what install.sh runs)
#   sudo ./install-selinux.sh rebuild              recompile core from source (.te/.fc) + reload + relabel
#   sudo ./install-selinux.sh relabel              re-apply labels (after Node upgrade)
#   sudo ./install-selinux.sh remove               unload all ai_tools* modules + labels
#   sudo ./install-selinux.sh enable-group <name>  compile + load one optional policy group
#   sudo ./install-selinux.sh disable-group <name> unload one policy group
#   sudo ./install-selinux.sh list-groups          show group availability and state
#
# selinux-policy-devel is required by every action that compiles -- install, build, rebuild,
# enable-group -- and by nothing else here:
#   sudo dnf install selinux-policy-devel
#
# The "shipped set" is the core, each STABLE group, and each integration's layout module,
# derived by shipped-modules.sh from the group registry and the integration manifests -- the
# same list the RPM build compiles. `build` and `install` stage it compiled under
# /usr/share/selinux/packages/ai-tools, where the installed ai-tools-admin loads a group from
# with no checkout and no toolchain, as it does on an RPM host.
#
# The optional policy groups are all DISABLED by default (the core alone covers repo-only
# work) and are declared once, in selinux-groups.lib.sh -- name, description, why it is
# off, and the stability that decides whether it is on the shipped set. This script reads that
# registry, as ai-tools-admin does, so the two cannot disagree on which groups exist.

set -euo pipefail
IFS=$'\n\t'

readonly ACTION="${1:-install}"
readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Policy source, the script naming the shipped set, and the modules compiled from the source
# live under policy/; the build (make -C) and every .te/.fc/.pp reference resolve there.
# install-selinux.sh, README.md, and ../src stay at DIR.
readonly POLICY_DIR="${DIR}/policy"
readonly MODULE="ai_tools"

# Shared message formatter (source tree first, installed copy second): frames the
# interactive confirmations in the '#' box and carries the yes/no prompts
# (ai_tools_msg_confirm). REQUIRED -- the prompts gate decisions, so a missing lib fails
# the run instead of degrading; one of the two locations exists on any host this script
# runs on (the repo checkout or an installed system).
MSG_LIB="${DIR}/../src/usr/local/lib/ai-tools/msg.lib.sh"
[[ -r "${MSG_LIB}" ]] || MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=/dev/null
source "${MSG_LIB}" \
    || { printf 'selinux: cannot source required library %s\n' "${MSG_LIB}" >&2; exit 1; }
# One fixed 80-column frame for the whole install flow's boxes, so consecutive prompts align.
export AI_TOOLS_MSG_FULLWIDTH=1

# Optional policy-group registry (names/descriptions/reasons + predicates), single-sourced
# so this authoring tool and the installed ai-tools-admin never disagree on the group set.
# REQUIRED -- the enable/disable/list actions and the install prompt all read it; a missing
# lib fails the run. Same source-tree-first, installed-second resolution as MSG_LIB.
GROUPS_LIB="${DIR}/../src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
[[ -r "${GROUPS_LIB}" ]] || GROUPS_LIB="/usr/local/lib/ai-tools/selinux-groups.lib.sh"
# shellcheck source=/dev/null
source "${GROUPS_LIB}" \
    || { printf 'selinux: cannot source required library %s\n' "${GROUPS_LIB}" >&2; exit 1; }
readonly NVM_DIR="/opt/ai-tools/.nvm"
HOME_STATE=(.npm .cache .local .config .gitconfig)

[[ "${EUID}" -eq 0 ]] || { echo "selinux: run with sudo" >&2; exit 1; }
PROJECTS_USER="${SUDO_USER:?selinux: invoke via sudo, not as root directly}"
PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" | cut -d: -f6)"
readonly ALLOWLIST="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
# Sandbox clones live here and are labelled ai_tools_project_t by the STATIC rule in
# ai_tools.fc, so the per-project semanage loop skips them (a duplicate local rule
# would be redundant). A plain restorecon of this tree applies the static label.
readonly SANDBOX_PROJECTS="/var/opt/ai-tools/sandbox-projects"
# The user-owned ai-tools config dir (allowed-projects, secret-patterns). Labelled
# ai_tools_conf_t so the root helpers -- which run IN ai_tools_handback_t, inherited from the
# handback daemon -- can read the allowlist; without it their getattr is denied
# (config_home_t:file is dontaudit'd) and ownership handback silently no-ops. The narrow type is
# what keeps that grant off the rest of ~/.config. The confined session is granted the same type,
# which the 700/600 modes then gate -- see the ai_tools_conf_t block in ai_tools.te. Applied via
# semanage (dynamic home path), not ai_tools.fc (fixed paths).
#
# The label belongs to an ACCOUNT, so the sweep covers every operator this host has
# (_operator_conf_dirs). It repairs an account enrolled while the policy was absent:
# `ai-tools-admin operators add` registers the rule for each account it enrols, and there is no
# type to assign until the module is loaded.
readonly CONF_TAIL=".config/ai-tools"
# Root-helper operation logs. Labelled ai_tools_log_t (static rule in ai_tools.fc) so
# the helpers that run IN ai_tools_handback_t (chown, setgid, launcher-symlink) may append
# under enforcing. A plain restorecon applies the label; created by install.sh.
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

# _list <item...>: render a set as [a, b] -- a name list reads as one value that way, where
# space-separated names blur into the prose around them and hide how many there are. Joined by
# hand rather than through IFS: "$*" uses only the FIRST character of IFS, so a ", " separator
# silently loses its space.
_list() {
    local joined="" item
    for item in "$@"; do joined+="${joined:+, }${item}"; done
    printf '[%s]' "${joined}"
}

# _group_cmd <enable|disable> [name]: the command an operator on THIS host should run to manage a
# policy group. ai-tools-admin is the shipped entry point and is on PATH once the package is
# installed, so prefer it; a source checkout with no install yet falls back to this
# script's own path. The two front doors spell the action differently -- the shipped one follows
# the command grammar (.claude/rules/cli-grammar.rule.md) while this developer-only script keeps
# its hyphenated verb -- so each branch renders its own spelling from the same action.
_group_cmd() {
    local verb="$1" name="${2:-<name>}"
    if command -v ai-tools-admin >/dev/null 2>&1; then
        printf 'sudo ai-tools-admin selinux groups %s %s' "${verb}" "${name}"
    else
        printf 'sudo %s %s-group %s' "$0" "${verb}" "${name}"
    fi
}
sayx()    { printf '%s\n' "$*" >&2; }

[[ "$(getenforce 2>/dev/null)" != "Disabled" ]] \
    || { log "SELinux is disabled -- nothing to do"; exit 0; }

# The optional policy-group registry (AI_TOOLS_SELINUX_GROUPS) and its accessors
# (ai_tools_selinux_group_{name,desc,reason,valid,loaded}) come from the shared
# selinux-groups.lib.sh this script sources -- the single source shared with ai-tools-admin.

########################################
# Build helpers
########################################

# require_devel <pp>: exit with install guidance unless the refpolicy devel toolchain (make +
# /usr/share/selinux/devel/Makefile from selinux-policy-devel) is present. Reached by every
# action that compiles: a checkout carries no compiled module, so the first install builds each
# one, and a rebuild after editing a .te/.fc builds it again.
require_devel() {
    command -v make >/dev/null && [[ -f /usr/share/selinux/devel/Makefile ]] && return 0
    warn "building ${1:-this policy module} needs the selinux-policy-devel toolchain,"
    warn "  which is not installed. A checkout compiles every module it loads (the RPM"
    warn "  ships them compiled), so install it and re-run:"
    warn "      sudo dnf install selinux-policy-devel"
    warn "  See ${DIR}/README.md for the policy build/bring-up workflow."
    exit 1
}

# ensure_pp <module.pp>: guarantee the compiled package ${POLICY_DIR}/<module.pp> exists.
# Reuses a module an earlier run compiled and compiles it otherwise (requiring
# selinux-policy-devel); an edited .te/.fc takes effect through build_pp, which always compiles.
ensure_pp() {
    local pp="$1"
    if [[ -f "${POLICY_DIR}/${pp}" ]]; then
        log "using the compiled ${pp} from an earlier build"
    else
        build_pp "${pp}"
    fi
}

# _shipped_modules: print the shipped set, one module name per line -- the derivation in
# shipped-modules.sh, read from this checkout's registry and manifests. A derivation that fails
# aborts the run: staging a guessed set would leave ai-tools-admin a package directory that does
# not match what the registry calls stable.
_shipped_modules() {
    bash "${POLICY_DIR}/shipped-modules.sh" || die "could not derive the shipped module set (policy/shipped-modules.sh)"
}

# stage_shipped_modules [rebuild]: compile the shipped set -- every module with ensure_pp, or
# with build_pp when `rebuild` is given -- and install each compiled module 644 root:root under
# AI_TOOLS_SELINUX_PACKAGE_DIR, the directory the installed ai-tools-admin loads a group from.
# This is the from-source counterpart of the RPM's %install, so a checkout host and an RPM host
# hold the same package directory; a group staged here still stays OFF until enabled.
stage_shipped_modules() {
    local how="${1:-reuse}" module
    local -a modules=()
    mapfile -t modules < <(_shipped_modules)
    (( ${#modules[@]} )) || die "the shipped module set is empty -- is the group registry readable?"
    for module in "${modules[@]}"; do
        if [[ "${how}" == rebuild ]]; then build_pp "${module}.pp"; else ensure_pp "${module}.pp"; fi
    done
    install -d -o root -g root -m 755 "${AI_TOOLS_SELINUX_PACKAGE_DIR}"
    for module in "${modules[@]}"; do
        install -o root -g root -m 644 "${POLICY_DIR}/${module}.pp" "${AI_TOOLS_SELINUX_PACKAGE_DIR}/${module}.pp"
    done
    ok "staged $(_list "${modules[@]}") under ${AI_TOOLS_SELINUX_PACKAGE_DIR}"
}

# _replace_former_group_modules: for every former module the registry records
# (AI_TOOLS_SELINUX_GROUP_FORMER_MODULES) that is loaded, replace it with every current group
# whose rules it carried. The new .pp files are built FIRST and the swap is one semodule
# transaction (`-r old -i new...`), so a build or load failure leaves the old module in place and
# the workload it served running, and the message says what to do. Runs after the core module is
# loaded -- a current group may require a type the old core did not declare -- and before a
# group is enabled or disabled, so every path that loads policy from this checkout migrates the
# host.
_replace_former_group_modules() {
    local entry former name
    local -a formers=() loads
    for entry in "${AI_TOOLS_SELINUX_GROUP_FORMER_MODULES[@]}"; do
        former="${entry#*|}"
        printf '%s\n' "${formers[@]}" | grep -qx "${former}" 2>/dev/null && continue
        formers+=( "${former}" )
    done
    for former in "${formers[@]}"; do
        ai_tools_selinux_module_loaded "${former}" || continue
        section "Replacing the loaded '${former}' module with the group(s) its rules became"
        loads=()
        while IFS= read -r name; do
            [[ -n "${name}" ]] || continue
            ensure_pp "ai_tools_${name}.pp"
            loads+=( -i "${POLICY_DIR}/ai_tools_${name}.pp" )
        done < <(ai_tools_selinux_groups_from_former_module "${former}")
        if _locked semodule -r "${former}" "${loads[@]}"; then
            ok "'${former}' unloaded; $(ai_tools_selinux_groups_from_former_module "${former}" | tr '\n' ' ')loaded in its place"
        else
            warn "could not replace '${former}' -- it stays loaded with its former rule set;"
            warn "    fix the cause above and re-run: sudo $0 rebuild"
        fi
    done
}

# _load_layout_modules: load the layout module of every installed integration that declares one
# (selinux_layout_module in its manifest, read through providers.lib.sh with its trust rules).
# A layout module types an integration's build-output directories and does not add any
# permission, so it is not a group an operator enables: it loads whenever the policy is
# (re)installed here, and
# `ai-tools-admin <integration> bootstrap` loads it too. Compiled from source like a group.
_load_layout_modules() {
    declare -F ai_tools_installed_integrations_declaring >/dev/null 2>&1 || return 0
    local integration module found=0
    while IFS=$'\t' read -r integration module; do
        [[ -n "${module}" ]] || continue
        found=1
        [[ "${module}" =~ ^ai_tools_[a-z][a-z0-9_]*$ ]] \
            || { warn "integration ${integration} declares a layout module name that is not ai_tools_<name>: ${module}"; continue; }
        [[ -f "${POLICY_DIR}/${module}.te" ]] \
            || { warn "integration ${integration} declares layout module ${module}, which has no source under ${POLICY_DIR}"; continue; }
        ensure_pp "${module}.pp"
        log "loading layout module: ${module} (integration ${integration})"
        if _locked semodule -i "${POLICY_DIR}/${module}.pp"; then
            ok "layout module ${module} loaded"
        else
            warn "could not load layout module ${module}; build output is typed at relabel time only"
        fi
    done < <(ai_tools_installed_integrations_declaring selinux_layout_module 2>/dev/null)
    # Said out loud, because the usual cause is ordering: the INSTALLED manifests are read, so a
    # checkout whose install.sh has not run yet declares none and the output would otherwise be
    # silent on why a bin/ directory still types ai_tools_project_t.
    (( found )) || log "no installed integration manifest declares a layout module (run install.sh first if one should)"
}

# _layout_modules_loaded: print the loaded layout modules the installed manifests declare, one
# per line, for the closing summary.
_layout_modules_loaded() {
    declare -F ai_tools_installed_integrations_declaring >/dev/null 2>&1 || return 0
    local integration module
    while IFS=$'\t' read -r integration module; do
        [[ "${module}" =~ ^ai_tools_[a-z][a-z0-9_]*$ ]] || continue
        ai_tools_selinux_module_loaded "${module}" && printf '%s\n' "${module}"
    done < <(ai_tools_installed_integrations_declaring selinux_layout_module 2>/dev/null)
    return 0
}

# _groups_needed_by <group>: print the installed integrations whose manifests list <group> in
# selinux_groups, space-separated, so the prompt can say what a group is for on this host.
_groups_needed_by() {
    declare -F ai_tools_installed_integrations_declaring >/dev/null 2>&1 || return 0
    local integration declared name out=""
    local -a names
    while IFS=$'\t' read -r integration declared; do
        names=(); ai_tools_conf_split names "${declared}"
        for name in "${names[@]}"; do
            [[ "${name}" == "$1" ]] && { out+="${out:+ }${integration}"; break; }
        done
    done < <(ai_tools_installed_integrations_declaring selinux_groups 2>/dev/null)
    printf '%s' "${out}"
}

# build_pp <module.pp>: compile the named policy module from its .te/.fc source via
# the refpolicy Makefile, then restore the .fc stub's ownership to the repo owner
# (the Makefile creates it as root).
build_pp() {
    local pp="$1"
    require_devel "${pp}"
    log "building ${pp}"
    make -C "${POLICY_DIR}" -f /usr/share/selinux/devel/Makefile "${pp}"
    # The refpolicy Makefile creates *.fc stubs as root. Fix ownership so the
    # source file remains readable/commitable by the repo owner.
    local base="${POLICY_DIR}/${pp%.pp}"
    [[ -f "${base}.fc" ]] \
        && chown "${PROJECTS_USER}:ai-tools" "${base}.fc" 2>/dev/null \
        && chmod 664 "${base}.fc" 2>/dev/null \
        || true
}

# Group validity/loaded predicates (ai_tools_selinux_group_valid / _loaded) come from
# selinux-groups.lib.sh, shared with ai-tools-admin.

# _mode_label: read ai_tools.te and return a human-readable enforcement label.
# If every permissive line is commented out -> "ENFORCING".
# Otherwise -> "PERMISSIVE (<dom> ...)" listing the still-permissive domains.
_mode_label() {
    local doms
    doms=$(grep -E '^[[:space:]]*permissive[[:space:]]+ai_tools_[^[:space:]]+[[:space:]]*;' \
               "${POLICY_DIR}/${MODULE}.te" 2>/dev/null \
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
    # A no-match grep exits 1, which pipefail propagates to the assignment and set -e
    # would abort on -- the normal ENFORCING case has zero permissive lines here, so
    # tolerate an empty result (the -z checks are the intended empty-path).
    local expected_permissive
    expected_permissive=$(grep -E '^[[:space:]]*permissive[[:space:]]+ai_tools_[^[:space:]]+[[:space:]]*;' \
                          "${POLICY_DIR}/${MODULE}.te" 2>/dev/null \
                          | awk '{gsub(/;/,""); print $2}') || true

    # All ai_tools_* domains currently permissive in the running kernel.
    local active_permissive
    active_permissive=$(seinfo --permissive 2>/dev/null | grep -E '^\s+ai_tools_' | tr -d ' ') || true

    [[ -z "${active_permissive}" ]] && return 0

    local dom stale_mod misaligned=()
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
                if ai_tools_msg_confirm "Remove stale semodule '${stale_mod}'?" y; then
                    _locked semodule -r "${stale_mod}"
                    ok "removed '${stale_mod}' -- ${dom} is now ENFORCING"
                else
                    warn "  leaving '${stale_mod}' -- ${dom} will remain PERMISSIVE"
                fi
            else
                warn "  fix: sudo semodule -r ${stale_mod}"
            fi
        else
            warn "  ${dom}: no permissive_${dom} module found -- check: sudo semanage permissive -l"
            warn "  fix:  sudo semanage permissive -d ${dom}"
        fi
    done
}

########################################
# Interactive group prompt
#
# Prints everything to stderr so it doesn't contaminate stdout. Populates SELECTED_GROUPS
# (not-loaded groups to enable) and RECOMPILE_GROUPS (loaded groups to rebuild + reload).
########################################
SELECTED_GROUPS=()
RECOMPILE_GROUPS=()

prompt_groups() {
    local entry name desc stability
    local -a loaded_groups=()

    # State what is already loaded BEFORE the skip gate, because the default answer skips this
    # section without listing anything: this step only ever ADDS modules, so a group enabled by
    # an earlier install survives the skip, and silence here reads as if it might not.
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        ai_tools_selinux_group_loaded "${name}" && loaded_groups+=("${name}")
    done
    # Header and explanation FIRST, so the skip gate is a prompt that FOLLOWS what it
    # decides about rather than preceding it. The groups are a mix of stability -- some stable,
    # some experimental -- so the caveat names the experimental subset instead of the whole set.
    section "Optional policy groups (all default: disabled)" >&2
    sayx "  Core alone covers project/home/tmp files, git, coreutils, HTTPS to the"
    sayx "  Anthropic API, and the handback socket. Enable a group only when a task"
    sayx "  must reach into system context. Each is tagged stable or experimental below;"
    sayx "  an experimental group is an unaudited draft -- audit it under permissive (the"
    sayx "  avc-denials harness) before relying on it."
    # State what is already loaded before the gate: the skip path only ADDS or REBUILDS modules,
    # so a group an earlier install enabled survives a skip -- silence would read as if it might
    # not.
    if (( ${#loaded_groups[@]} )); then
        sayx ""
        logx "already loaded and kept: ${C_BOLD}$(_list "${loaded_groups[@]}")${C_RST}"
        # Two calls, not one with a line-continuation: sayx joins its args through "$*", which
        # under this script's IFS=$'\n\t' glues them with a NEWLINE -- so the command would land
        # unindented on its own line. Keep the note and its (indented) command as separate lines.
        sayx "    ${C_DIM}this step only adds or rebuilds modules; remove one with:${C_RST}"
        sayx "      ${C_DIM}$(_group_cmd disable)${C_RST}"
    fi
    sayx ""

    # The gate FOLLOWS the explanation. Default skips (core module alone); a non-interactive run
    # takes that default through the confirm's no-tty behaviour.
    ai_tools_msg_confirm "Skip the optional (non-core) policy modules?" y && return 0

    sayx ""

    # Stable groups are offered first, experimental ones after: the stable set is what an
    # operator enables without an audit, so it is what the prompt leads with, and
    # the registry's own order (which groups an integration's declaration) is kept within each
    # half. A group an installed integration declares (selinux_groups in its manifest) says so
    # on its row, so the reason to enable it is on the line where it is answered.
    local -a ordered=() needed
    for stability in stable experimental; do
        for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
            [[ "$(ai_tools_selinux_group_stability "${entry}")" == "${stability}" ]] && ordered+=("${entry}")
        done
    done
    for entry in "${ordered[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        desc="$(ai_tools_selinux_group_desc "${entry}")"
        stability="$(ai_tools_selinux_group_stability "${entry}")"
        needed="$(_groups_needed_by "${name}")"
        [[ -z "${needed}" ]] || desc+=" ${C_DIM}[needed by: ${needed}]${C_RST}"
        # A group loaded by an earlier install stays loaded whatever is answered here: this step
        # only ADDS modules. Show that state in the same vocabulary list-groups uses, and name
        # the verb that actually removes one -- an unmarked "Enable? [n]" beside a loaded group
        # reads as "off, and staying off", which is the opposite of what the answer does. The
        # (stability) tag matches list-groups so the stable/experimental split is visible per row.
        if ai_tools_selinux_group_loaded "${name}"; then
            printf '    %s[LOADED]%s %s %s(%s)%s -- %s\n' "${C_GRN}" "${C_RST}" "${name}" "${C_DIM}" "${stability}" "${C_RST}" "${desc}" >&2
            sayx "        already enabled; to remove it: $(_group_cmd disable "${name}")"
            # A loaded group is still offered, because from a source checkout the operator may be
            # iterating on its .te/.fc and want to rebuild + reload it in place. A yes recompiles
            # FROM SOURCE (build_pp), never reusing an earlier build -- that is the point of
            # offering a loaded group -- and needs the selinux-policy-devel toolchain.
            ai_tools_msg_confirm "    Recompile from source and reload?" n && RECOMPILE_GROUPS+=("${name}")
            continue
        fi
        printf '    %s[%s]%s %s(%s)%s %s\n' "${C_DIM}" "${name}" "${C_RST}" "${C_DIM}" "${stability}" "${C_RST}" "${desc}" >&2
        ai_tools_msg_confirm "    Enable?" n && SELECTED_GROUPS+=("${name}")
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

# _locked <command...>: run one store-writing command under ai_tools_relabel_lock, released when
# it returns. semanage and semodule report an error to whichever process finds the policy store
# held, and ai-tools-relabel.path fires ai-tools-relabel.service into this script's run (the
# install that runs it rewrites /opt/ai-tools/bin), so every semodule load and every fcontext
# section here takes the lock the root helpers take. Per command rather than for the whole run:
# the install action prompts between its loads, and a lock held across a prompt makes the
# watcher's run wait out AI_TOOLS_RELABEL_LOCK_WAIT and then proceed unserialized. An untaken
# lock is reported once and the command runs anyway, the library's own fail-soft.
_locked_note_shown=0
_locked() {
    local rc=0
    ai_tools_relabel_lock
    if [[ -n "${AI_TOOLS_RELABEL_LOCK_NOTE}" && "${_locked_note_shown}" -eq 0 ]]; then
        warn "policy-store writes are not serialized on this host -- ${AI_TOOLS_RELABEL_LOCK_NOTE}"
        _locked_note_shown=1
    fi
    "$@" || rc=$?
    ai_tools_relabel_unlock
    return "${rc}"
}

# _labels_apply / _labels_drop: the fcontext sections, one _locked call each. Apply registers and
# verifies every enabled agent's rules, the enrolled operators' config rules, and each registered
# project's rule; drop removes them in the reverse order, while the module still declares their
# types.
_labels_apply() { verify_agent_labels; _label_conf; for_each_project _label_one; }
_labels_drop() {
    local manifest agent
    for_each_project _unlabel_one
    _unlabel_conf
    # The agents' path rules are local fcontexts naming types the module unload removes. Dropped
    # for EVERY installed agent manifest, not just the enabled ones: a disabled agent may still
    # hold a rule from when it was on.
    log "dropping the agents' fcontext rules"
    for manifest in /usr/local/lib/ai-tools/agents.d/*.conf; do
        [[ -e "${manifest}" ]] || continue
        agent="${manifest##*/}"; agent="${agent%.conf}"
        ai_tools_unlabel_agent_paths "${agent}" \
            || log "  ${agent}: no file-context rules to drop"
    done
}

# The OPERATORS list, parsed through the shared grammar so this sweep reads operator.conf exactly
# as every other consumer does. Best-effort and only the plural loader is called: an unenrolled
# host (or a missing lib) leaves the set empty, which _operator_conf_dirs answers with the invoking
# user alone -- the set this script covered before. `ai_tools_load_operator`, the SINGULAR one, is
# deliberately not used: it writes PROJECTS_USER/PROJECTS_HOME, which are this script's own.
OPERATOR_LIB="${DIR}/../src/usr/local/lib/ai-tools/operator.lib.sh"
[[ -r "${OPERATOR_LIB}" ]] || OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
source "${OPERATOR_LIB}" 2>/dev/null \
    || warn "could not read the operator list (${OPERATOR_LIB}); labelling ${PROJECTS_USER}'s config only"

# verify_agent_labels: apply each enabled agent's declared file-context rules -- its entrypoint
# (-> ai_tools_exec_t, without which the domain transition never fires and the agent would run
# UNCONFINED) and its config directory (-> ai_tools_home_t, without which the confined session
# cannot write its own state) -- and confirm what they match took the type. The work is
# ai_tools_label_agent_paths (relabel.lib.sh), the same body the always-installed
# ai-tools-relabel-agent helper runs, so this sweep and the post-upgrade relabel cannot drift;
# this wrapper only renders the report in the installer's voice. It is agent-agnostic: the paths
# come from the manifests under /usr/local/lib/ai-tools/agents.d.
verify_agent_labels() {
    local report="" status=0 verdict subject detail wanted bad=0 labelled=0
    report="$(ai_tools_label_agent_paths)" || status=$?
    if [[ "${status}" -eq 2 ]]; then
        warn "SELinux or the ai_tools module is not active -- no agent paths to label"
        return 0
    fi
    if [[ -n "${report}" ]]; then
        # Pin IFS for this read: the script runs under the strict-mode IFS=$'\n\t', and the
        # report's fields are SPACE-separated, so an inherited IFS puts the whole line in
        # ${verdict} and every case arm misses -- including `bad`, which is what sets the
        # flag that aborts the install when an entrypoint did not take ai_tools_exec_t. The
        # guard against launching unconfined depends on this splitting correctly.
        while IFS=$' \t\n' read -r verdict subject detail wanted; do
            case "${verdict}" in
                ok)   labelled=$(( labelled + 1 ))
                      ok "labelled: ${subject}" ;;
                bad)  bad=1
                      warn "${subject}"
                      warn "    is '${detail}', NOT ${wanted} -- the session would run unconfined"
                      warn "    or fail to write its own state. matchpathcon expects:"
                      warn "      $(matchpathcon "${subject}" 2>/dev/null | awk '{print $2}')"
                      warn "    chase with: sudo restorecon -nv '${subject}'" 
                      warn "            and: sudo semanage fcontext -C -l" ;;
                # The declared rule does not cover the entrypoint the agent's launcher actually
                # resolves to, so no rule this sweep applies can label it and the session would
                # be refused. Counted as `bad`: the install must not report a confined host.
                stale) bad=1
                      warn "${subject}: its installed entrypoint is"
                      warn "    ${detail}"
                      warn "    -- not covered by the file-context rule its manifest declares,"
                      warn "    so no relabel can label it and every launch will fail closed."
                      warn "    Update the agent package; its manifest is stale." ;;
                none) warn "${subject}: ${detail} is not installed -- nothing to label" ;;
                skip) warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
                # The per-agent verdict closing that agent's lines: `ok` and `none` restate the
                # per-path arms, so only `failed` prints, naming the agent those lines omit.
                agent)
                    if [[ "${detail}" == failed ]]; then
                        warn "${subject}: labelling did not complete -- see its lines above"
                    fi ;;
                # A verdict this renderer does not know is REPORTED, not dropped. Silently
                # ignoring one turns a labelling result into no output at all, which reads as
                # "no change" for the one path whose label decides whether a session is
                # confined -- and leaves the operator no detail to diagnose from.
                *)    warn "unrecognized labelling result: ${verdict} ${subject} ${detail} ${wanted}"
                      warn "    the entrypoint label is unconfirmed; check: sudo ai-tools-admin system entrypoints relabel" ;;
            esac
        done <<< "${report}"
    fi
    # A path that restorecon left mislabelled is an unrecoverable gap (the module is loaded but
    # the transition would not fire, or the agent cannot write its state), so fail the install
    # here rather than proceed to the optional groups with a broken core. A missing path
    # (toolchain not provisioned yet) stays a warning -- there is no entrypoint to label.
    [[ "${bad}" -eq 0 ]] \
        || die "an agent path is not correctly labelled (see above) -- the session would be refused, or run UNCONFINED"
    # Nothing labelled has two very different causes, and the bare message named neither. An
    # EMPTY report means no enabled agent was iterated at all -- the manifests resolved to
    # no file -- which is a configuration problem: the entrypoint keeps whatever type it has, and
    # a launch fail-closes at ai-tools-run's transition preflight. A non-empty report that
    # labelled no file has already printed its own per-path none/skip reason.
    if [[ "${labelled}" -eq 0 ]]; then
        if [[ -z "${report}" ]]; then
            warn "no agent resolved from the manifests, so no entrypoint was labelled."
            warn "  Nothing here grants ai_tools_exec_t, so a session refuses to launch until it is."
            warn "  Check which agents are enabled:  ai-tools --providers"
            warn "  and that a manifest is installed: ls -l /usr/local/lib/ai-tools/agents.d/"
            warn "  Re-apply once one resolves:      sudo ai-tools-admin system entrypoints relabel"
        else
            warn "no agent path took a label this run -- see the per-path reason above"
        fi
    fi
    # Printed while the install is still running, so it states WHEN it applies: an operator who
    # reads "exit and relaunch" mid-install has no session to relaunch yet.
    log "once this install finishes: a session already running keeps its OLD context, so exit"
    log "  and relaunch it, then confirm with:  ps -eo label,cmd | grep '[c]laude'  (expect ai_tools_t)"
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
                   restorecon -FR "/opt/ai-tools/${p}" 2>/dev/null || true
                 done; }
# _label_one/_unlabel_one: thin wrappers over the shared lib so this sweep and the
# ai-tools-relabel helper share one implementation. Non-zero is swallowed (warn,
# don't die) so one bad project never aborts a whole relabel. _unlabel_one already
# restorecons via the lib; the remove action's later _restore_one pass is a
# harmless belt-and-suspenders.
# Re-asserts the label on every registered project each run. The relabel is idempotent (restorecon
# writes only a file whose context differs), so a clean tree costs a walk and no writes; a file that
# drifted in with a foreign context -- a customizable type a plain restorecon would preserve -- is
# forced back to ai_tools_project_t by the lib's `-F`, which is the whole point of the sweep.
_label_one()   { if ai_tools_label_project "$1"; then ok "labelled project ai_tools_project_t: $1"
                 else warn "could not label $1 -- is the ai_tools module loaded?"; fi; }
_unlabel_one() { ai_tools_unlabel_project "$1" || warn "could not unlabel $1"; }
_restore_one() { restorecon -FR "$1" 2>/dev/null || true; }
# _label_sandbox_clones: apply the static ai_tools_project_t label (ai_tools.fc) to every existing
# sandbox clone, then REPORT and VERIFY each one. The per-project loop skips sandbox paths
# (they carry no dynamic semanage rule -- the static rule covers them), so without this an operator
# is shown no evidence the clones were relabelled even though they are the trees the agent runs in.
# The label is verified, not assumed: restorecon exits 0 even when it writes the WRONG type -- e.g.
# an fcontext rule made unreachable because libselinux aliases its path prefix away
# (file_contexts.subs_dist `/var/opt /opt`) -- so each clone's achieved label is checked and a
# mismatch warns rather than passing silently. Best-effort and SELinux-gated like the rest of the
# sweep: on a host without SELinux the restorecon no-ops and the verify/report is skipped.
_label_sandbox_clones() {
    [[ -d "${SANDBOX_PROJECTS}" ]] || return 0
    restorecon -FR "${SANDBOX_PROJECTS}" 2>/dev/null || true
    ai_tools_relabel_available || return 0
    local clone
    for clone in "${SANDBOX_PROJECTS}"/*/; do
        [[ -d "${clone}" ]] || continue           # no clones: the glob stays literal, -d fails
        clone="${clone%/}"
        if ai_tools_project_labelled "${clone}"; then
            ok "labelled sandbox clone ai_tools_project_t: ${clone}"
        else
            warn "sandbox clone NOT labelled ai_tools_project_t: ${clone}"
            warn "    is the ai_tools module loaded, and the clone fcontext rule under /opt"
            warn "    (base file_contexts.subs_dist aliases /var/opt -> /opt before matching)?"
        fi
    done
}
# _operator_conf_dirs: print the ai-tools config directory of every account this host treats as an
# operator, one per line, deduplicated in first-seen order. That set is the OPERATORS list in
# operator.conf plus the invoking user, who is an operator by having run this and who on a first
# install is absent from the list, operator.conf being written by `ai-tools-admin operators add`.
# So an unenrolled host still labels the config of the account installing the policy.
_operator_conf_dirs() {
    local name home
    {
        printf '%s\n' "${PROJECTS_USER}"
        if declare -F ai_tools_load_operators >/dev/null 2>&1 && ai_tools_load_operators; then
            printf '%s\n' "${AI_TOOLS_OPERATORS[@]}"
        fi
    } | while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        home="$(getent passwd "${name}" 2>/dev/null | cut -d: -f6)" || continue
        [[ -n "${home}" ]] || continue
        printf '%s/%s\n' "${home}" "${CONF_TAIL}"
    done | awk '!seen[$0]++'
}

# Label / unlabel every operator's ~/.config/ai-tools as ai_tools_conf_t (see CONF_TAIL comment).
# The rule registration and the restorecon live in relabel.lib.sh, so this sweep and the
# per-account registration in ai-tools-admin apply one implementation.
_label_conf() {
    local dir status
    while IFS= read -r dir; do
        [[ -d "${dir}" ]] || { log "config dir absent, skip label: ${dir}"; continue; }
        status=0
        ai_tools_label_operator_conf "${dir}" || status=$?
        case "${status}" in
            0) ok "labelled config ai_tools_conf_t: ${dir}" ;;
            2) log "SELinux inactive, nothing to label: ${dir}" ;;
            # ai_tools_conf_t must already exist in the LOADED policy for semanage to accept it.
            # 'relabel' never loads the module, so on a first run (or after a version bump) the
            # type may be undefined -- report honestly instead of logging a false success. The
            # reason semanage gave is what tells that apart from a store another transaction held.
            *) warn "could not set ai_tools_conf_t on ${dir}${AI_TOOLS_FCONTEXT_ERROR:+ -- ${AI_TOOLS_FCONTEXT_ERROR}}"
               warn "    type undefined? the module must be LOADED first --"
               warn "    run 'install' (loads the module), not just 'relabel'." ;;
        esac
    done < <(_operator_conf_dirs)
}
_unlabel_conf() {
    local dir
    while IFS= read -r dir; do
        ai_tools_unlabel_operator_conf "${dir}" || true
    done < <(_operator_conf_dirs)
}
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
# Callers run _relabel_helpers first: the restart makes systemd derive the listening
# socket's context from the daemon binary's on-disk label, so the daemon must already
# carry ai_tools_handback_exec_t when the socket rebinds.
_relabel_runtime() {
    if systemctl list-unit-files ai-tools-handback.socket &>/dev/null; then
        systemctl daemon-reexec 2>/dev/null || true
        if systemctl is-active --quiet ai-tools-handback.socket; then
            systemctl restart ai-tools-handback.socket 2>/dev/null || true
        fi
    fi
    [[ -d "${RUN_DIR}" ]] && restorecon -FRv "${RUN_DIR}" 2>/dev/null || true
}

# _relabel_helpers: apply ai_tools_handback_exec_t to the handback daemon entrypoint
# (/usr/local/libexec/ai-tools/ai-tools-handback, ai_tools.fc). Without this the daemon
# keeps a generic label, the init_t -> ai_tools_handback_t transition never fires, the
# per-connection handler runs in unconfined_service_t, and ai_tools_t's connectto
# (granted only to ai_tools_handback_t) is denied -- every hook handback fails with
# EACCES. The sibling root helpers and the /usr/local/bin client are bin_t (no special
# label). restorecon is idempotent and no-ops when handback is not installed.
# Runs before _relabel_runtime's socket restart, which reads this label (see there).
_relabel_helpers() { restorecon -FR /usr/local/libexec/ai-tools 2>/dev/null || true; }

########################################
# Actions
########################################

case "${ACTION}" in

  install)
    section "Core module"
    # A fresh checkout holds no compiled module, so the first install compiles the core. A later
    # run finds the earlier build and offers to recompile it (for an edited .te/.fc) -- default
    # no, so an unattended re-run reuses what it has.
    _recompile=0
    if [[ -f "${POLICY_DIR}/${MODULE}.pp" && -t 0 ]]; then
        ai_tools_msg_confirm \
            "Recompile the core policy module from source? (needs selinux-policy-devel)" n \
            && _recompile=1
    fi
    if (( _recompile )); then
        build_pp "${MODULE}.pp"
    else
        ensure_pp "${MODULE}.pp"
    fi

    _mode="$(_mode_label)"
    log "loading core module (${_mode})"
    _locked semodule -i "${POLICY_DIR}/${MODULE}.pp"
    ok "core module loaded (${_mode})"
    _check_permissive_alignment
    _replace_former_group_modules
    _load_layout_modules
    # The shipped set, compiled and staged where the installed ai-tools-admin loads a stable
    # group from; rebuilt with the core when the operator asked for that.
    section "Shipped modules"
    if (( _recompile )); then stage_shipped_modules rebuild; else stage_shipped_modules; fi

    section "Labelling"
    restorecon -FR "${NVM_DIR}"  2>/dev/null || true
    # Apply and verify the static sandbox-clone label (ai_tools.fc) on any existing clones.
    _label_sandbox_clones
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    _locked _labels_apply

    # Core is loaded and labelled -- a clear checkpoint before the optional groups. Reaching
    # here means the preceding steps succeeded (a hard failure aborts under set -e; a mislabelled
    # path dies in verify_agent_labels), so the optional section is purely additive.
    ok "SELinux core module installed"

    prompt_groups
    if (( ${#SELECTED_GROUPS[@]} || ${#RECOMPILE_GROUPS[@]} )); then
        section "Optional groups"
        for name in "${SELECTED_GROUPS[@]}"; do
            ensure_pp "ai_tools_${name}.pp"
            log "loading group: ai_tools_${name}"
            _locked semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
            ok "group '${name}' enabled"
        done
        # Recompile-and-reload a loaded group from its current source: build_pp (unlike
        # ensure_pp) never reuses an earlier build, so an edited .te/.fc takes effect.
        for name in "${RECOMPILE_GROUPS[@]}"; do
            build_pp "ai_tools_${name}.pp"
            log "reloading from source: ai_tools_${name}"
            _locked semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
            ok "group '${name}' recompiled and reloaded"
        done
    fi

    section "SELinux confinement ready"
    if [[ "${_mode}" == PERMISSIVE ]]; then
        ok "core module loaded PERMISSIVE -- nothing is blocked yet"
        log "next: follow README.md (audit2allow) before removing 'permissive ai_tools_t;'"
    else
        ok "core module loaded ENFORCING -- denials are now active"
    fi
    # Report what THIS run changed separately from the full loaded set: a group an earlier
    # install enabled is kept unless the operator re-selected it here, so naming only the
    # changes would read as if a kept group had become disabled.
    # _list, not "${arr[*]}": this script runs IFS=$'\n\t', so [*] joins the names with a
    # NEWLINE and each lands on its own unindented line. _list renders them as [a, b].
    if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
        log "newly enabled this run: $(_list "${SELECTED_GROUPS[@]}")"
    fi
    if [[ ${#RECOMPILE_GROUPS[@]} -gt 0 ]]; then
        log "recompiled + reloaded this run: $(_list "${RECOMPILE_GROUPS[@]}")"
    fi
    _loaded_groups=()
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        gname="$(ai_tools_selinux_group_name "${entry}")"
        ai_tools_selinux_group_loaded "${gname}" && _loaded_groups+=("${gname}")
    done
    if (( ${#_loaded_groups[@]} )); then
        log "optional groups now loaded: $(_list "${_loaded_groups[@]}")"
    else
        log "no optional groups loaded (core only)"
    fi
    # Layout modules are reported apart from the groups: they load with an integration, not by
    # an answer to this prompt, and a missing one is why fresh build output types ai_tools_project_t.
    mapfile -t _layouts < <(_layout_modules_loaded)
    if (( ${#_layouts[@]} )); then
        log "layout modules loaded (with their integrations): $(_list "${_layouts[@]}")"
    fi
    if [[ "${_mode}" == PERMISSIVE ]] && (( ${#SELECTED_GROUPS[@]} || ${#RECOMPILE_GROUPS[@]} )); then
        log "re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to cover"
        log "the expanded surface before removing 'permissive ai_tools_t;'"
    fi
    log "verify:  semodule -l | grep ai_tools;  ai-tools --providers"
    log "after launching claude:  ps -eo label,cmd | grep -m1 claude  (expect ai_tools_t)"
    ;;

  relabel)
    section "Re-applying labels"
    restorecon -FR "${NVM_DIR}"  2>/dev/null || true
    # Apply and verify the static sandbox-clone label (ai_tools.fc) on any existing clones.
    _label_sandbox_clones
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    _locked _labels_apply
    ok "relabel done"
    ;;

  build)
    # Compile the shipped set from source and stage it under the package directory, loading
    # nothing: the step install.sh runs so an installed ai-tools-admin can enable a stable group,
    # and the from-source twin of the RPM's %build + %install. Needs selinux-policy-devel.
    section "Compiling and staging the shipped modules"
    stage_shipped_modules rebuild
    ;;

  rebuild)
    # Recompile the core module from source (.te/.fc) and reload it, then re-apply
    # labels. This is the "rebuild core module" path: use it after editing ai_tools.te
    # or ai_tools.fc so the loaded policy matches the source. The shipped set is recompiled
    # and re-staged with it, so the package directory matches the source too.
    # Needs the selinux-policy-devel toolchain (build_pp checks and guides if absent).
    section "Rebuilding core module"
    build_pp "${MODULE}.pp"
    _mode="$(_mode_label)"
    log "reloading core module (${_mode})"
    _locked semodule -i "${POLICY_DIR}/${MODULE}.pp"
    ok "core module rebuilt and reloaded (${_mode})"
    _check_permissive_alignment
    _replace_former_group_modules
    _load_layout_modules
    section "Shipped modules"
    stage_shipped_modules rebuild

    section "Re-applying labels"
    restorecon -FR "${NVM_DIR}"  2>/dev/null || true
    # Apply and verify the static sandbox-clone label (ai_tools.fc) on any existing clones.
    _label_sandbox_clones
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    _locked _labels_apply
    ok "rebuild done"
    ;;

  remove)
    section "Removing SELinux confinement"
    log "dropping project fcontext rules"
    _locked _labels_drop
    log "unloading all ai_tools* modules"
    # Collect all loaded ai_tools modules then remove in one semodule call.
    mapfile -t loaded < <(semodule -l 2>/dev/null | awk '/^ai_tools/{print $1}')
    if [[ ${#loaded[@]} -gt 0 ]]; then
        _locked semodule -r "${loaded[@]}" 2>/dev/null || true
    fi
    log "reverting contexts to defaults"
    _restore_one "${NVM_DIR}"
    _home_state
    for_each_project _restore_one
    ok "removed"
    ;;

  enable-group)
    name="${2:?usage: sudo $0 enable-group <name>}"
    if ! ai_tools_selinux_group_valid "${name}"; then
        warn "unknown group '${name}'. Available groups:"
        for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
            printf '    %-10s %s\n' "$(ai_tools_selinux_group_name "${entry}")" "$(ai_tools_selinux_group_desc "${entry}")" >&2
        done
        exit 1
    fi
    _replace_former_group_modules
    section "Enabling group: ${name}"
    ensure_pp "ai_tools_${name}.pp"
    log "loading group: ai_tools_${name}"
    _locked semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
    ok "group '${name}' enabled"
    # A group may ship file contexts of its own (dotnet maps a clone's build output), so the
    # labels are re-applied after the load: the project sweep re-asserts each project's rules,
    # and the clone restorecon picks up any static rule the group added.
    log "re-applying labels for the expanded rule set"
    _locked for_each_project _label_one
    _label_sandbox_clones
    log "re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to catch any"
    log "new denials from the expanded surface before going enforcing"
    ;;

  disable-group)
    name="${2:?usage: sudo $0 disable-group <name>}"
    _replace_former_group_modules
    if ai_tools_selinux_group_loaded "${name}"; then
        _locked semodule -r "ai_tools_${name}"
        ok "group '${name}' disabled"
        # The inverse of the enable sweep: a path a static rule of the group mapped falls back
        # to the base's rule for it. Every type the groups name is declared in the base, so a
        # per-project rule outlives the group unchanged.
        log "re-applying labels for the reduced rule set"
        _locked for_each_project _label_one
        _label_sandbox_clones
    else
        log "group 'ai_tools_${name}' is not currently loaded -- nothing to do"
    fi
    ;;

  list-groups)
    if semodule -l 2>/dev/null | grep -q "^${MODULE}[[:space:]]"; then
        if grep -qE '^[[:space:]]*permissive[[:space:]]+ai_tools_t[[:space:]]*;' "${POLICY_DIR}/${MODULE}.te"; then
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
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        gname="$(ai_tools_selinux_group_name "${entry}")"
        gdesc="$(ai_tools_selinux_group_desc "${entry}")"
        if ai_tools_selinux_group_loaded "${gname}"; then
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

  install              compile + load the core, stage the shipped set, prompt for optional groups
  build                compile + stage the shipped set under /usr/share/selinux/packages/ai-tools
  rebuild              recompile the core module from source (.te/.fc), reload, relabel
  relabel              re-apply labels (run after a Node upgrade)
  remove               unload all ai_tools* modules and revert labels
  enable-group <name>  load one optional policy group (compiles it)
  disable-group <name> unload one optional policy group
  list-groups          show which groups are available and their current state

  install, build, rebuild, and enable-group compile from source: sudo dnf install selinux-policy-devel

Optional groups (all disabled by default):
EOF
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        printf '  %-10s %s\n' "$(ai_tools_selinux_group_name "${entry}")" "$(ai_tools_selinux_group_desc "${entry}")" >&2
    done
    exit 1
    ;;
esac
