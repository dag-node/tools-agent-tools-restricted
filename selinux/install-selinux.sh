#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
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
# recompile the core or a group after editing its .te/.fc. The core AND every optional
# group ship prebuilt (ai_tools.pp, ai_tools_<group>.pp), so a normal install and a
# plain enable-group need no toolchain. Install it only when rebuilding from source:
#   sudo dnf install selinux-policy-devel
#
# Policy groups (all DISABLED by default; core alone covers repo-only work):
#   systemd   systemctl, journalctl, unit file reads
#   pkgmgmt   rpm (rpm_exec_t), RPM database (rpm_var_lib_t)
#   netadmin  firewall-cmd D-Bus (firewalld_t), nmcli D-Bus (NetworkManager_t)
#   podman    container runtime exec, image/layer storage reads
#   tmpmap    mmap of the agent's own /tmp files (dotnet build, git/SQLite in /tmp)
#   apphost   map+execute of tmpfs/memfd files (.NET apphost/JIT: dotnet run, ASP.NET Core, xunit.v3)
#   netcore   .NET runtime IPC (dotnet test / MSBuild pipes) + running a project's built executable

set -euo pipefail
IFS=$'\n\t'

readonly ACTION="${1:-install}"
readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Policy source + prebuilt packages live under policy/; the build (make -C) and every
# .te/.fc/.pp reference resolve there. install-selinux.sh, README.md, and ../src stay at DIR.
readonly POLICY_DIR="${DIR}/policy"
readonly MODULE="ai_tools"

# Shared message formatter (source tree first, installed copy second): frames the
# interactive confirmations below in the '#' box and carries the yes/no prompts
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
# lib fails the run. Same source-tree-first, installed-second resolution as MSG_LIB above.
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
# ai_tools_conf_t so the root ai-tools-chown helper -- which runs IN ai_tools_t with
# no transition -- can read the allowlist; without it the helper's getattr is denied
# (config_home_t:file is dontaudit'd) and ownership handback silently no-ops. The
# label is scoped to this one dir so the rest of ~/.config stays unreadable to the
# domain. Applied via semanage (dynamic home path), not ai_tools.fc (fixed paths).
readonly CONF_DIR="${PROJECTS_HOME}/.config/ai-tools"
# Root-helper operation logs. Labelled ai_tools_log_t (static rule in ai_tools.fc) so
# the helpers that run IN ai_tools_t (chown, setgid, launcher-symlink) may append under
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

# _list <item...>: render a set as [a, b] -- a name list reads as one value that way, where
# space-separated names blur into the prose around them and hide how many there are. Joined by
# hand rather than through IFS: "$*" uses only the FIRST character of IFS, so a ", " separator
# silently loses its space.
_list() {
    local joined="" item
    for item in "$@"; do joined+="${joined:+, }${item}"; done
    printf '[%s]' "${joined}"
}

# _group_cmd <verb>: the command an operator on THIS host should run to manage a policy group.
# ai-tools-admin is the shipped entry point and is on PATH once the package is installed, so
# prefer it; a source checkout with nothing installed yet falls back to this script's own path.
_group_cmd() {
    if command -v ai-tools-admin >/dev/null 2>&1; then
        printf 'sudo ai-tools-admin selinux %s' "$1"
    else
        printf 'sudo %s %s' "$0" "$1"
    fi
}
sayx()    { printf '%s\n' "$*" >&2; }

[[ "$(getenforce 2>/dev/null)" != "Disabled" ]] \
    || { log "SELinux is disabled -- nothing to do"; exit 0; }

# The optional policy-group registry (AI_TOOLS_SELINUX_GROUPS) and its accessors
# (ai_tools_selinux_group_{name,desc,reason,valid,loaded}) come from the shared
# selinux-groups.lib.sh sourced above -- the single source shared with ai-tools-admin.

########################################
# Build helpers
########################################

# require_devel <pp>: exit with install guidance unless the refpolicy devel
# toolchain (make + /usr/share/selinux/devel/Makefile from selinux-policy-devel) is
# present. Only reached when a module must be COMPILED from source -- the core and the
# STABLE groups ship prebuilt, so a normal install and enabling a stable group never land
# here; building an EXPERIMENTAL group (which never ships prebuilt), or a rebuild after
# editing a .te/.fc, is what requires the toolchain.
require_devel() {
    command -v make >/dev/null && [[ -f /usr/share/selinux/devel/Makefile ]] && return 0
    warn "building ${1:-this policy module} needs the selinux-policy-devel toolchain,"
    warn "  which is not installed. The shipped modules (core + stable groups) are prebuilt"
    warn "  and need no toolchain; an experimental group or an edited-source rebuild does."
    warn "      sudo dnf install selinux-policy-devel"
    warn "  then re-run. See ${DIR}/README.md for the policy build/bring-up workflow."
    exit 1
}

# ensure_pp <module.pp>: guarantee the compiled package ${POLICY_DIR}/<module.pp> exists.
# Prefers the prebuilt package shipped in the repo so a normal install and enabling a stable
# group need no toolchain; compiles from source (requiring selinux-policy-devel) when the
# package is absent -- an experimental group (never shipped prebuilt), or after editing the
# .te/.fc source.
ensure_pp() {
    local pp="$1"
    if [[ -f "${POLICY_DIR}/${pp}" ]]; then
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
    # tolerate an empty result (the -z checks below are the intended empty-path).
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
                    semodule -r "${stale_mod}"
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

    # State what is already loaded BEFORE the gate below, because the default answer skips this
    # section without listing anything: this step only ever ADDS modules, so a group enabled by
    # an earlier install survives the skip, and silence here reads as if it might not.
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        ai_tools_selinux_group_loaded "${name}" && loaded_groups+=("${name}")
    done
    # Header and explanation FIRST, so the skip gate below is a prompt that FOLLOWS what it
    # decides about rather than preceding it. The groups are a mix of stability -- some stable,
    # some experimental -- so the caveat names the experimental subset instead of the whole set.
    section "Optional policy groups (all default: disabled)" >&2
    sayx "  Core alone covers project/home/tmp files, git, coreutils, HTTPS to the"
    sayx "  Anthropic API, and the sudo->helper calls. Enable a group only when a task"
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
        sayx "      ${C_DIM}$(_group_cmd 'disable-group <name>')${C_RST}"
    fi
    sayx ""

    # The gate FOLLOWS the explanation. Default skips (core module alone); a non-interactive run
    # takes that default through the confirm's no-tty behaviour.
    ai_tools_msg_confirm "Skip the optional (non-core) policy modules?" y && return 0

    sayx ""

    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        desc="$(ai_tools_selinux_group_desc "${entry}")"
        stability="$(ai_tools_selinux_group_stability "${entry}")"
        # A group loaded by an earlier install stays loaded whatever is answered here: this step
        # only ADDS modules. Show that state in the same vocabulary list-groups uses, and name
        # the verb that actually removes one -- an unmarked "Enable? [n]" beside a loaded group
        # reads as "off, and staying off", which is the opposite of what the answer does. The
        # (stability) tag matches list-groups so the stable/experimental split is visible per row.
        if ai_tools_selinux_group_loaded "${name}"; then
            printf '    %s[LOADED]%s %s %s(%s)%s -- %s\n' "${C_GRN}" "${C_RST}" "${name}" "${C_DIM}" "${stability}" "${C_RST}" "${desc}" >&2
            sayx "        already enabled; to remove it: $(_group_cmd "disable-group ${name}")"
            # A loaded group is still offered, because from a source checkout the operator may be
            # iterating on its .te/.fc and want to rebuild + reload it in place. A yes recompiles
            # FROM SOURCE (build_pp below), not a prebuilt reuse -- that is the point of offering
            # a loaded group -- and needs the selinux-policy-devel toolchain.
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

# verify_agent_labels: apply each enabled agent's declared file-context rules -- its entrypoint
# (-> ai_tools_exec_t, without which the domain transition never fires and the agent would run
# UNCONFINED) and its config directory (-> ai_tools_home_t, without which the confined session
# cannot write its own state) -- and confirm what they match took the type. The work is
# ai_tools_label_agent_paths (relabel.lib.sh), the same body the always-installed
# ai-tools-relabel-agent helper runs, so this sweep and the post-upgrade relabel cannot drift;
# this wrapper only renders the report in the installer's voice. It names no agent: the paths
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
        # ${verdict} and every case below misses -- including `bad`, which is what sets the
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
                none) warn "${subject}: ${detail} is not installed -- nothing to label" ;;
                skip) warn "${subject}: labelling skipped -- ${detail} ${wanted}" ;;
                # A verdict this renderer does not know is REPORTED, not dropped. Silently
                # ignoring one turns a labelling result into no output at all, which reads as
                # "nothing happened" for the one path whose label decides whether a session is
                # confined -- and leaves nothing to diagnose from.
                *)    warn "unrecognized labelling result: ${verdict} ${subject} ${detail} ${wanted}"
                      warn "    the entrypoint label is unconfirmed; check: sudo ai-tools --relabel" ;;
            esac
        done <<< "${report}"
    fi
    # A path that restorecon left mislabelled is an unrecoverable gap (the module is loaded but
    # the transition would not fire, or the agent cannot write its state), so fail the install
    # here rather than proceed to the optional groups with a broken core. A missing path
    # (toolchain not provisioned yet) stays a warning -- there is nothing to label.
    [[ "${bad}" -eq 0 ]] \
        || die "an agent path did not take its type (see above) -- the agent would run UNCONFINED"
    # Nothing labelled has two very different causes, and the bare message named neither. An
    # EMPTY report means no enabled agent was iterated at all -- the manifests resolved to
    # nothing -- which is a configuration problem: the entrypoint keeps whatever type it has, and
    # a launch fail-closes at ai-tools-run's transition preflight. A non-empty report that
    # labelled nothing has already printed its own per-path none/skip reason above.
    if [[ "${labelled}" -eq 0 ]]; then
        if [[ -z "${report}" ]]; then
            warn "no agent resolved from the manifests, so no entrypoint was labelled."
            warn "  Nothing here grants ai_tools_exec_t, so a session refuses to launch until it is."
            warn "  Check which agents are enabled:  ai-tools --providers"
            warn "  and that a manifest is installed: ls -l /usr/local/lib/ai-tools/agents.d/"
            warn "  Re-apply once one resolves:      sudo ai-tools --relabel"
        else
            warn "no agent path took a label this run -- see the per-path reason above"
        fi
    fi
    # Printed while the install is still running, so it states WHEN it applies: an operator who
    # reads "exit and relaunch" mid-install has nothing to relaunch yet.
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
# Label / unlabel ~/.config/ai-tools as ai_tools_conf_t (see CONF_DIR comment).
_label_conf()   { [[ -d "${CONF_DIR}" ]] || { log "config dir absent, skip label: ${CONF_DIR}"; return 0; }
                  # ai_tools_conf_t must already exist in the LOADED policy for
                  # semanage to accept it. 'relabel' never loads the module, so on a
                  # first run (or after a version bump) the type may be undefined --
                  # report honestly instead of logging a false success.
                  # Both streams are dropped: semanage announces an existing entry on stdout
                  # ("already defined, modifying instead"), which reads as an error beside our
                  # own status lines. Which branch fired is the useful part, so say that in this
                  # script's own words instead.
                  local _verb="labelled"
                  if semanage fcontext -a -t ai_tools_conf_t "${CONF_DIR}(/.*)?" >/dev/null 2>&1 \
                     || { _verb="re-applied"
                          semanage fcontext -m -t ai_tools_conf_t "${CONF_DIR}(/.*)?" >/dev/null 2>&1; }; then
                      restorecon -FR "${CONF_DIR}" 2>/dev/null || true
                      ok "${_verb} config ai_tools_conf_t: ${CONF_DIR}"
                  else
                      warn "could not set ai_tools_conf_t fcontext on ${CONF_DIR}"
                      warn "    type undefined? the module must be LOADED first --"
                      warn "    run 'install' (loads the module), not just 'relabel'."
                  fi; }
_unlabel_conf() { semanage fcontext -d "${CONF_DIR}(/.*)?" 2>/dev/null || true
                  restorecon -FR "${CONF_DIR}" 2>/dev/null || true; }
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
    # The core module ships prebuilt, so a normal install needs no toolchain. Offer
    # a from-source rebuild (needs selinux-policy-devel) for anyone who edited the
    # .te/.fc -- default no. With no prebuilt package present we must build anyway.
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
    semodule -i "${POLICY_DIR}/${MODULE}.pp"
    ok "core module loaded (${_mode})"
    _check_permissive_alignment

    section "Labelling"
    restorecon -FR "${NVM_DIR}"  2>/dev/null || true
    # Apply the static sandbox-clone label (ai_tools.fc) to any existing clones.
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -FR "${SANDBOX_PROJECTS}" 2>/dev/null || true
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    verify_agent_labels
    _label_conf
    for_each_project _label_one

    # Core is loaded and labelled -- a clear checkpoint before the optional groups. Reaching
    # here means the steps above succeeded (a hard failure aborts under set -e; a mislabelled
    # path dies in verify_agent_labels), so the optional section is purely additive.
    ok "SELinux core module installed"

    prompt_groups
    if (( ${#SELECTED_GROUPS[@]} || ${#RECOMPILE_GROUPS[@]} )); then
        section "Optional groups"
        for name in "${SELECTED_GROUPS[@]}"; do
            ensure_pp "ai_tools_${name}.pp"
            log "loading group: ai_tools_${name}"
            semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
            ok "group '${name}' enabled"
        done
        # Recompile-and-reload a loaded group from its current source: build_pp (unlike
        # ensure_pp) never reuses a stale prebuilt, so an edited .te/.fc takes effect.
        for name in "${RECOMPILE_GROUPS[@]}"; do
            build_pp "ai_tools_${name}.pp"
            log "reloading from source: ai_tools_${name}"
            semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
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
    # Apply the static sandbox-clone label (ai_tools.fc) to any existing clones.
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -FR "${SANDBOX_PROJECTS}" 2>/dev/null || true
    # Apply ai_tools_log_t to the root-helper operation logs (ai_tools.fc).
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    verify_agent_labels
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
    semodule -i "${POLICY_DIR}/${MODULE}.pp"
    ok "core module rebuilt and reloaded (${_mode})"
    _check_permissive_alignment

    section "Re-applying labels"
    restorecon -FR "${NVM_DIR}"  2>/dev/null || true
    [[ -d "${SANDBOX_PROJECTS}" ]] && restorecon -FR "${SANDBOX_PROJECTS}" 2>/dev/null || true
    [[ -d "${LOG_DIR}" ]] && restorecon -FR "${LOG_DIR}" 2>/dev/null || true
    # Label the handback daemon first: the socket restart in _relabel_runtime derives
    # the listener's context from the daemon binary's on-disk label at bind time.
    _relabel_helpers
    # Fix ai_tools_run_t on the tmpfs handback socket dir (see _relabel_runtime).
    _relabel_runtime
    _home_state
    verify_agent_labels
    _label_conf
    for_each_project _label_one
    ok "rebuild done"
    ;;

  remove)
    section "Removing SELinux confinement"
    log "dropping project fcontext rules"
    for_each_project _unlabel_one
    _unlabel_conf
    # The agents' path rules are local fcontexts naming types the module unload below removes.
    # Drop them here, while those types still exist, for EVERY installed agent manifest (not just
    # the enabled ones -- a disabled agent may still hold a rule from when it was on).
    log "dropping the agents' fcontext rules"
    for manifest in /usr/local/lib/ai-tools/agents.d/*.conf; do
        [[ -e "${manifest}" ]] || continue
        agent="${manifest##*/}"; agent="${agent%.conf}"
        ai_tools_unlabel_agent_paths "${agent}" \
            || log "  ${agent}: no file-context rules to drop"
    done
    log "unloading all ai_tools* modules"
    # Collect all loaded ai_tools modules then remove in one semodule call.
    mapfile -t loaded < <(semodule -l 2>/dev/null | awk '/^ai_tools/{print $1}')
    if [[ ${#loaded[@]} -gt 0 ]]; then
        semodule -r "${loaded[@]}" 2>/dev/null || true
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
    section "Enabling group: ${name}"
    ensure_pp "ai_tools_${name}.pp"
    log "loading group: ai_tools_${name}"
    semodule -i "${POLICY_DIR}/ai_tools_${name}.pp"
    ok "group '${name}' enabled"
    log "re-run the bring-up loop (avc-testsuite.sh + avc-analyze.sh) to catch any"
    log "new denials from the expanded surface before going enforcing"
    ;;

  disable-group)
    name="${2:?usage: sudo $0 disable-group <name>}"
    if ai_tools_selinux_group_loaded "${name}"; then
        semodule -r "ai_tools_${name}"
        ok "group '${name}' disabled"
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

  install              load prebuilt core (opt. recompile) + prompt for optional groups
  rebuild              recompile the core module from source (.te/.fc), reload, relabel
  relabel              re-apply labels (run after a Node upgrade)
  remove               unload all ai_tools* modules and revert labels
  enable-group <name>  load one optional policy group (compiles it; needs selinux-policy-devel)
  disable-group <name> unload one optional policy group
  list-groups          show which groups are available and their current state

Optional groups (all disabled by default):
EOF
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        printf '  %-10s %s\n' "$(ai_tools_selinux_group_name "${entry}")" "$(ai_tools_selinux_group_desc "${entry}")" >&2
    done
    exit 1
    ;;
esac
