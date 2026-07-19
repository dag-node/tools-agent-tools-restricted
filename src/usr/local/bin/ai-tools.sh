#!/usr/bin/env bash
# /usr/local/bin/ai-tools
# Project-lifecycle CLI for the ai-tools Claude Code sandbox. Runs AS the invoking operator (not
# as root, not as the sandbox account). It writes the operator-owned allowlist
# (~/.config/ai-tools/allowed-projects) directly, and reaches the root-owned bits
# -- the git safe.directory list in /opt/ai-tools/.gitconfig, the SELinux label, the ACL, and
# secret lockdown -- through the sudo root helpers (no NOPASSWD: the operator is prompted for a
# password; the sandbox account holds no grant).
#
# Commands (each confirms before applying and reports the result):
#   --project-claim   [path]  claim a real project in place (idempotent; default: cwd);
#                             -y/--yes pre-answers its proceed prompt (delegated claims)
#   --project-create  [path]  alias for --project-claim (kept for back-compat)
#   --project-unclaim [path]  unclaim a real project: drop the registries, revert the
#                             label, and hand the files back to a group with the agent's
#                             write access revoked (directory left on disk)
#   --project-remove  [path]  alias for --project-unclaim (kept for back-compat)
#   --sandbox-create [path]   shallow-clone a repo into the sandbox area (private,
#                             umask 077), lock down tip-commit secrets, then grant
#                             the agent access and register -- fail-closed: an
#                             unsecured clone stays private and unregistered; run
#                             again on the clone path to resume securing it
#   --sandbox-push   [path]   push the sandbox clone's commits to its branch
#   --sandbox-remove [path]   remove a sandbox clone and unregister it
#   --relabel                 relabel the claude entrypoint after a Node upgrade (sudo)
#   --list                    list registered projects (real vs sandbox)
#   --version                 print the installed ai-tools version
#   --help
#
# Sandbox model: the agent works in a shallow clone under SANDBOX_ROOT so it never
# reads the original repo's full git history. Work is pushed to a per-repo branch
# ai-tools/sandbox-<user>/<leaf> (default leaf: main). Only the projects user can
# push -- the sandbox account has no git credentials. Anyone with repo access then
# merges that branch back, preserving the agent's commits granularly. See
# /var/opt/ai-tools/README.md.
#
# Deploy: install -o root -g root -m 755 src/usr/local/bin/ai-tools.sh \
#         /usr/local/bin/ai-tools

set -euo pipefail
IFS=$'\n\t'

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
# Substituted at deploy time (install.sh from packaging/VERSION; the RPM from %{version});
# a raw source-tree run reports "dev".
AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_VERSION}" == @*@ ]] && AI_TOOLS_VERSION="dev"
readonly AI_TOOLS_VERSION
readonly GITCONFIG="/opt/ai-tools/.gitconfig"
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# Bootstrap's last load-bearing artifact -- the require_bootstrap gate keys on it (below).
# Same symlink the launch wrapper resolves; kept identical to claude.sh's CLAUDE_LINK.
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"
# Root-only secret lockdown helper. Invoked via sudo (NO NOPASSWD grant exists for
# it -- by design), so sudo prompts for the projects user's password.
readonly LOCKDOWN_BIN="/usr/local/sbin/ai-tools/ai-tools-lockdown"
# Root-only SELinux project-label helper, same sudo (no NOPASSWD) model as lockdown.
# Applies/reverts ai_tools_project_t so the confined agent can access a claimed,
# in-place tree; the per-project semanage fcontext rule it adds needs root, which
# this unprivileged CLI lacks. Sandbox clones do NOT use it (static rule + plain
# restorecon -- see relabel_clone).
readonly RELABEL_BIN="/usr/local/sbin/ai-tools/ai-tools-relabel"
# Root-only ACL helper, same sudo (no NOPASSWD) model as lockdown/relabel. Applies the
# project's group-permission ACL (default + access group:SANDBOX_GROUP:rwX, other denied)
# so files the projects user's git checkout/merge writes under a restrictive umask stay
# group-accessible to the agent. Needs root (CAP_FOWNER) to ACL files the projects user
# does not own; this unprivileged CLI lacks that.
readonly SETFACL_BIN="/usr/local/sbin/ai-tools/ai-tools-setfacl"
# Root-only setgid helper, same sudo (no NOPASSWD) model. Sets group SANDBOX_GROUP + the setgid
# bit on a claimed project's directories. The operator is not a SANDBOX_GROUP member
# (multi-operator), so the group change needs root; the helper carries its own allowlist + owner
# guard. Also invoked by the handback daemon for the SessionStart normalization pass.
readonly SETGID_BIN="/usr/local/sbin/ai-tools/ai-tools-setgid"
# Root-only unclaim helper, same sudo (no NOPASSWD) model. Reverses the filesystem side
# of a claim: clears the agent ACL + default ACL, regroups the tree to a target group, and
# removes group write. Needs root to chgrp to an arbitrary group and to act on files the
# projects user does not own.
readonly UNCLAIM_BIN="/usr/local/sbin/ai-tools/ai-tools-unclaim"
# Root-only entrypoint-relabel helper, same sudo (no NOPASSWD) model. Restores
# ai_tools_exec_t on the claude.exe entrypoint(s) after a Node auto-upgrade leaves them
# mislabelled; needs root (the projects user runs as unconfined_t, which can relabel, but
# only via sudo as the helper is 750 root:root). Invoked by --relabel and --postupgrade.
readonly RELABEL_ENTRYPOINT_BIN="/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint"
# Root-only git safe.directory helper, same sudo (no NOPASSWD) model as lockdown/relabel/
# setfacl/unclaim. /opt/ai-tools/.gitconfig is root-owned 644: world-readable (the agent reads
# safe.directory on startup) but root-write-only, so neither the operator nor the agent writes it
# directly -- the operator reaches the validated add/--remove through this helper.
readonly SAFEDIR_BIN="/usr/local/sbin/ai-tools/ai-tools-safedir"
# Root-only ownership-reclaim helper, same sudo (no NOPASSWD) model. Hands agent-written files
# under a project back to the operator via ai-tools-chown (the per-path trust boundary), needed for
# the .git tree the per-session sweeps skip; useful before an ACL-unaware backup.
readonly RECLAIM_BIN="/usr/local/sbin/ai-tools/ai-tools-reclaim"
# Sentinel in a guard CLAUDE.md (see drop_lockdown_guard) so the lockdown step can
# recognise and remove its own placeholder once secrets are secured.
readonly GUARD_MARKER="ai-tools-lockdown-guard"

# ── Invoker guards ───────────────────────────────────────────────────────────────
# This is a user tool. It must run as the projects user: never as root (it would
# write the registries with the wrong owner) and never as the sandbox account
# (the agent must not manage its own allowlist).
ME="$(id -un)"
[[ "${ME}" == "root" ]] \
    && { echo "ai-tools: do not run as root -- run as the projects user, without sudo" >&2
         echo "          (the CLI invokes sudo itself for the steps that need it)" >&2; exit 1; }
[[ "${ME}" == "${SANDBOX_USER}" ]] \
    && { echo "ai-tools: refusing to run as the sandbox account ${SANDBOX_USER}" >&2; exit 1; }

HOME_DIR="$(getent passwd "${ME}" | cut -d: -f6)"
[[ -d "${HOME_DIR}" ]] || { echo "ai-tools: cannot resolve home for ${ME}" >&2; exit 1; }
readonly ME HOME_DIR
readonly ALLOWLIST="${HOME_DIR}/.config/ai-tools/allowed-projects"

# ── Output / prompt helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RST=$'\033[0m'
else
    readonly C_BOLD='' C_DIM='' C_GRN='' C_YEL='' C_RST=''
fi

say()     { printf '%s\n' "$*"; }
section() { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RST}"; }
ok()      { printf '  %s✓%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
warn()    { ai_tools_msg_warn "$@"; }
die()     { ai_tools_log_error "$*"; ai_tools_msg_error "ai-tools: $*"; exit 1; }
# The claim/sandbox flows are sequences of SELF-CONTAINED blocks, each opened by a wide
# headline box (title + summary prose), with details, prompts, and results printed plain
# below it and a closing ✓ (or a fail-closed error) ending the block -- see
# messaging.rule.md. headline() narrates to stdout; headline_warn() carries a
# "WARNING: ..."-titled block on stderr.
headline()      { ai_tools_msg_headline "$1" 1 "${@:2}"; }
headline_warn() { ai_tools_msg_headline "$1" 2 "${@:2}"; }

# Shared leveled logger -- journald only (this CLI runs as the projects user, not root,
# so it cannot write the root-only /var/log/ai-tools files). Records workflow
# milestones (project/sandbox created, pushed, removed, locked down) at INFO under the
# tag "ai-tools". Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared message formatter -- die()/warn() above frame their text in the paste-safe
# '#' alert box (50 columns) and headline()/headline_warn() open the wide (80-column)
# flow blocks on a terminal, plain text otherwise, and
# ai_tools_msg_confirm carries every yes/no prompt. REQUIRED, like safe-paths.lib.sh
# below: the confirms gate real decisions, so a missing lib fails closed instead of
# running through a private fallback (see messaging.rule.md).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/msg.lib.sh
if ! source "${MSG_LIB}" 2>/dev/null; then
    command -v logger >/dev/null 2>&1 \
        && logger -t ai-tools -p user.err \
            "required library ${MSG_LIB} unavailable -- ai-tools refused (fail closed)"
    printf 'ai-tools: cannot load required library %s\n' "${MSG_LIB}" >&2
    printf '  the install is incomplete or /usr/local/lib/ai-tools is not traversable;\n' >&2
    printf '  refusing (fail closed) -- reinstall the ai-tools package, then retry.\n' >&2
    exit 3
fi
# One fixed 80-column frame for every box this CLI shows: a claim/reclaim run emits a
# SEQUENCE of boxes, which aligns instead of each sizing to its own text.
export AI_TOOLS_MSG_FULLWIDTH=1

# Protected-paths backstop (safe-paths.lib.sh): refuse to claim a system directory, and vet
# ancestors for the reachability grant (reg_reach -> grantable_ancestor). It is REQUIRED:
# FAIL CLOSED if it cannot be sourced (missing, unreadable, or the lib dir is not traversable)
# or does not define its guard. A broken install is not a state to run through with the guard
# disabled -- a stubbed no-op would skip the system-dir refusal AND silently never grant
# ancestor traversal (a claimed project the agent cannot reach). Log to journald (via logger,
# independent of log.lib which may share the broken dir) and warn the user, then exit.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/safe-paths.lib.sh
if ! source "${SAFE_PATHS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_assert_safe_target  >/dev/null 2>&1 \
        || ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
    command -v logger >/dev/null 2>&1 \
        && logger -t ai-tools -p user.err \
            "required safety library ${SAFE_PATHS_LIB} unavailable -- ai-tools refused (fail closed)"
    ai_tools_msg_error "ai-tools: cannot load required safety library ${SAFE_PATHS_LIB}" \
        "the install is incomplete or /usr/local/lib/ai-tools is not traversable (expected 0751);" \
        "refusing (fail closed) -- reinstall the ai-tools package, then retry."
    exit 3
fi

# Skip-dir selector (the single skip source shared with the sweeps and the claim helpers).
# The claim drift scan uses it to tell repairable hits from skip-listed ones. Fail-soft: a
# missing lib classifies nothing as skip-listed -- a noisier report, never a wrong repair
# (the root helpers load their own copy for the walks).
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_NAMES=(); AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# confirm <prompt> <y|n>  -- the shared yes/no prompt (ai_tools_msg_confirm; see
# msg.lib.sh): the explicit default decides the Enter answer and the no-tty answer, so
# each caller states the default whose unattended answer is the safe outcome for its
# question. AI_TOOLS_ASSUME_YES=1 fast-tracks only default-YES prompts (the lib's rule);
# a default-NO prompt is answered ahead of time only by the CLI's own --yes flag -- the
# launch wrapper passes it for a delegated --project-claim after taking its own
# confirmation, so the claim's proceed prompt does not ask a second time.
# have_tty: true only when a controlling terminal can actually be opened. `[[ -r /dev/tty ]]`
# tests the node's permission bits (crw-rw-rw-), not openability, so it reads true even with no
# controlling terminal (e.g. a systemd unit or under setsid); opening /dev/tty is the only honest
# probe -- with no controlling tty the open fails ENXIO, so the prompt guards skip cleanly instead
# of writing to /dev/tty and aborting. Mirrors claude.sh's have_tty.
have_tty() { { : > /dev/tty; } 2>/dev/null; }

confirm() { ai_tools_msg_confirm "$@"; }

# ask <prompt> <default>  -- echo the chosen value on stdout; prompt to the tty.
ask() {
    local prompt="$1" def="$2" resp
    if have_tty; then
        printf '%s %s[%s]%s: ' "${prompt}" "${C_DIM}" "${def}" "${C_RST}" > /dev/tty
        read -r resp < /dev/tty || resp=""
    else
        resp=""
    fi
    printf '%s' "${resp:-$def}"
}

# ── Path helpers ─────────────────────────────────────────────────────────────────

# resolve_dir <path>  -- canonicalize <path> (realpath -e) to stdout; die if absent.
resolve_dir() {
    local p
    p="$(realpath -e "$1" 2>/dev/null)" || die "path not found: $1"
    printf '%s' "${p}"
}

# require_sandbox <path>  -- die unless <path> lies under SANDBOX_ROOT.
require_sandbox() {
    case "$1/" in
        "${SANDBOX_ROOT}"/*) ;;
        *) die "not a sandbox project (must be under ${SANDBOX_ROOT}): $1" ;;
    esac
}

# ── Registry helpers (the only mutating filesystem writes besides clones) ─────────
# allowed-projects: one absolute path per line; '!'-prefixed lines are exclusions.
# safe.directory: git refuses to operate in a dir it does not own, and the clone is
# owned by the projects user, so the sandbox account (which runs git as the agent)
# needs an explicit entry per registered path.

reg_allow() {
    local dir="$1"
    [[ -f "${ALLOWLIST}" ]] || die "allowlist not found at ${ALLOWLIST} -- run install first"
    if grep -qxF "${dir}" "${ALLOWLIST}"; then
        say "    allowed-projects: already listed"
    else
        printf '%s\n' "${dir}" >> "${ALLOWLIST}"
        say "    allowed-projects: added"
    fi
}

unreg_allow() {
    local dir="$1" esc
    [[ -f "${ALLOWLIST}" ]] || return 0
    if grep -qxF "${dir}" "${ALLOWLIST}"; then
        esc="$(printf '%s' "${dir}" | sed 's/[\\|]/\\&/g')"
        sed -i "\|^${esc}$|d" "${ALLOWLIST}"
        say "    allowed-projects: removed"
    else
        say "    allowed-projects: not listed"
    fi
}

# reg_safedir <dir>  -- register <dir> in the agent's git safe.directory list: read unprivileged
# for idempotency, then write via the SAFEDIR_BIN root helper (see its declaration for the
# sudo/644 rationale). The entry lets the agent's git trust this tree, so the step is
# best-effort: when sudo is absent or the helper does not complete, it prints the manual command
# as a hint and lets the claim carry on.
reg_safedir() {
    local dir="$1"
    if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        say "    git safe.directory: already listed"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot register git safe.directory automatically"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} ${dir}${C_RST}"
        return 0
    fi
    if sudo "${SAFEDIR_BIN}" "${dir}"; then
        say "    git safe.directory: added"
    else
        warn "could not register git safe.directory -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} ${dir}${C_RST}"
    fi
}

# unreg_safedir <dir>  -- the unclaim counterpart to reg_safedir: drop <dir> via SAFEDIR_BIN
# --remove. Called after unreg_allow, so the helper's --remove is lenient about allowlist
# membership. Best-effort like reg_safedir: warns with the manual command and lets the unclaim
# carry on.
unreg_safedir() {
    local dir="$1"
    if ! git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        say "    git safe.directory: not listed"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot remove git safe.directory automatically"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} --remove ${dir}${C_RST}"
        return 0
    fi
    if sudo "${SAFEDIR_BIN}" --remove "${dir}"; then
        say "    git safe.directory: removed"
    else
        warn "could not remove git safe.directory -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SAFEDIR_BIN} --remove ${dir}${C_RST}"
    fi
}

# reg_filemode <dir>  -- pin core.filemode=true in the project's own .git/config so
# git tracks the executable bit deterministically for BOTH co-writers, regardless of
# either user's global git config. Repo-LOCAL (not the shared /opt/ai-tools/.gitconfig,
# which is the agent's global): the setting must be shared by the projects user and the
# agent, and .git is reclaimed to the projects user, who can write it. Idempotent and
# quiet when already set; a no-op (with a note) when <dir> is not a git work tree.
# Orthogonal to the ACL hardening -- filemode governs only the exec bit, never group/
# other permission bits -- but claimed in the same git-config step as safe.directory.
reg_filemode() {
    local dir="$1"
    if ! git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        say "    git core.filemode: not a git work tree -- skipped"
        return 0
    fi
    if [[ "$(git -C "${dir}" config --local --get core.filemode 2>/dev/null)" == "true" ]]; then
        say "    git core.filemode: already true"
    else
        if git -C "${dir}" config --local core.filemode true; then
            say "    git core.filemode: set true"
        else
            warn "git core.filemode: could not set (continuing)"
        fi
    fi
}

# acl_gap <dir>  -- true (0) when the project's group-permission ACL is NOT yet in
# place: <dir>'s root carries no `default:group:SANDBOX_GROUP:` entry. Read-only and
# unprivileged. Returns false (1) when the ACL is present, and ALSO when ACLs cannot be
# inspected at all (getfacl missing) -- there is then no gap we can act on, so claim
# does not perpetually re-prompt for a step that cannot run. Mirrors the dir_owngap /
# project_state "na when unavailable" convention.
acl_gap() {
    local dir="$1"
    command -v getfacl >/dev/null 2>&1 || return 1
    getfacl -p "${dir}" 2>/dev/null \
        | grep -qE "^default:group:${SANDBOX_GROUP}:" && return 1
    return 0
}

# git_gap <dir>  -- true (0) when <dir> has a .git tree NOT yet normalized for agent
# git-history access: its .git root lacks group SANDBOX_GROUP, the setgid bit, or the
# default group ACL. Read-only and unprivileged. Returns false (1) when there is no .git
# tree (none, or a submodule/worktree .git FILE), when .git is already normalized, and when
# ACLs cannot be inspected (getfacl missing) -- there is then no gap we can act on, so claim
# does not perpetually re-offer a step that cannot run. Mirrors the acl_gap / dir_owngap
# "na when unavailable" convention. Unlike the other gaps, normalizing .git is opt-in (the
# operator is asked, default yes), so this only DETECTS the gap; cmd_project_claim decides.
git_gap() {
    local dir="$1" grp mode
    [[ -d "${dir}/.git" ]] || return 1
    command -v getfacl >/dev/null 2>&1 || return 1
    # IFS pinned to a space: the script's global IFS ($'\n\t') would land the whole
    # stat line in grp and leave mode empty -- the same pitfall project_state's reader
    # documents.
    IFS=' ' read -r grp mode < <(stat -c '%G %a' "${dir}/.git" 2>/dev/null) || return 1
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] \
        && (( (0${mode} & 02000) != 0 )) \
        && getfacl -p "${dir}/.git" 2>/dev/null | grep -qE "^default:group:${SANDBOX_GROUP}:" \
        && return 1
    return 0
}

# dir_owngap <dir>  -- true (0) when <dir> is NOT group-accessible to the sandbox
# account: group is not SANDBOX_GROUP, or the group-execute bit is clear. The
# sandbox user runs with the project as its cwd, and Node's posix_spawn needs
# group-execute there to launch ANY child (hooks, the Bash tool). This is the exact
# gap the launch wrapper refuses to start on, factored here so both agree.
dir_owngap() {
    local dir="$1" grp mode
    grp="$(stat -c '%G' "${dir}" 2>/dev/null)" || return 0
    mode="$(stat -c '%a' "${dir}" 2>/dev/null)" || return 0
    [[ "${grp}" == "${SANDBOX_GROUP}" ]] && (( (0${mode} & 010) != 0 )) && return 1
    return 0
}

# acl_drift_scan <dir>  -- list paths inside a claimed tree that look shared but carry the
# wrong group: owned by the operator or the sandbox account, group not SANDBOX_GROUP, yet
# with group/other permission bits set. Creation under a claimed tree inherits the group
# (setgid) and the ACLs (default entries); a path lacking both arrived by rename(2) -- mv
# from outside the tree preserves the old group and inherits nothing -- and the agent gets
# EACCES on it deep inside an allowlisted project. Owner-only paths (600/700: locked-down
# secrets, deliberately private files) and '!'-excluded subtrees are not reported -- out of
# the agent's reach by intent. Read-only and unprivileged, detection only: the repair runs
# behind the claim confirm + secret gate, and the helper walks keep their own secret-name/
# exclusion/foreign-owner skips, so reporting a path here never by itself widens access.
acl_drift_scan() {
    local dir="$1" excl
    local -a skip=( -name .git -prune )
    # Leave this project's '!'-excluded subtrees out of the walk: an intentional
    # carve-out stays unreported.
    while IFS= read -r excl; do
        excl="${excl#!}"
        [[ "${excl}" == "${dir}"/* ]] && skip+=( -o -path "${excl}" -prune )
    done < <(grep '^!' "${ALLOWLIST}" 2>/dev/null || true)
    find "${dir}" -xdev \( "${skip[@]}" \) -o \
        \( -user "${ME}" -o -user "${SANDBOX_USER}" \) \
        ! -group "${SANDBOX_GROUP}" -perm /077 -print 2>/dev/null
}

# reg_ownership <dir>  -- make <dir> usable by the sandbox account: group SANDBOX_GROUP + the
# setgid bit on the project's directories, via the root ai-tools-setgid helper, so the agent can
# enter the tree and files born there inherit the group. Without it a path can be allowlisted yet
# fail every posix_spawn -- the session starts but cannot enter the tree or run a child. The
# operator is not a SANDBOX_GROUP member (multi-operator), so it cannot chgrp to that group
# unprivileged; the helper does it as root and carries its own allowlist + owner guard (a dir owned
# by a third party is left untouched). Pre-existing FILES become agent-accessible through the group
# ACL claim_setfacl applies next -- not a recursive chgrp: only a DRIFTED file (group-accessible
# yet foreign group, per acl_drift_scan) gets its primary group normalized there, which is what
# settles the drift report instead of re-flagging the same paths on every claim.
#
# CALLER MUST run secret_gate "${dir}" first: claim_setfacl then grants the agent group access to
# existing files, so a group-readable secret left un-locked (e.g. appsettings.json 640) would
# become readable by the agent. secret_gate locks secrets to 600/700 first.
reg_ownership() {
    local dir="$1" force="${2:-}"
    # 'force' runs the helper walk even when the project root already matches -- the
    # interior-drift repair, where the gap sits below the root.
    if [[ "${force}" != force ]] && ! dir_owngap "${dir}"; then
        say "    ownership: already group ${SANDBOX_GROUP}, setgid"
        return 0
    fi
    if sudo "${SETGID_BIN}" "${dir}"; then
        say "    ownership: set group ${SANDBOX_GROUP} + setgid on the project directories"
    else
        warn "ownership: could not set group/setgid on ${dir} -- run: sudo ${SETGID_BIN} ${dir}"
    fi
}

# agent_can_traverse <dir>  -- 0 if the sandbox account (SANDBOX_USER, a SANDBOX_GROUP member) can
# ENTER <dir>: world-execute, or group-execute with the directory in group SANDBOX_GROUP, or an
# explicit user:SANDBOX_USER ACL carrying execute.
agent_can_traverse() {
    local d="$1" m grp
    m="$(stat -c '%a' "${d}" 2>/dev/null)" || return 1
    if (( 8#${m} & 0001 )); then return 0; fi
    grp="$(stat -c '%G' "${d}" 2>/dev/null || true)"
    if [[ "${grp}" == "${SANDBOX_GROUP}" ]] && (( 8#${m} & 0010 )); then return 0; fi
    if command -v getfacl >/dev/null 2>&1 \
            && getfacl -p "${d}" 2>/dev/null | grep -qE "^user:${SANDBOX_USER}:..x"; then
        return 0
    fi
    return 1
}

# grantable_ancestor <dir>  -- 0 if reg_reach may grant traverse on <dir>: the operator OWNS it and
# it is not a protected system directory (the safe-paths backstop). Fail-closed when the predicate
# is unavailable, so a broken install never widens a directory it cannot vet.
grantable_ancestor() {
    local p="$1"
    declare -F ai_tools_protected_path_match >/dev/null 2>&1 || return 1
    if ai_tools_protected_path_match "${p}" >/dev/null 2>&1; then return 1; fi
    [[ "$(stat -c '%U' "${p}" 2>/dev/null || true)" == "${ME}" ]]
}

# reach_scan <dir>  -- detect the traverse gap between the sandbox account and <dir>:
# fills REACH_GRANT (each blocking ancestor a grant may cover: operator-owned, not a
# protected system directory) and REACH_BLOCKED (the first blocking ancestor no grant may
# cover, empty when none). Read-only and unprivileged; reg_reach acts on the result, and
# the claim's pending overview reads it so the traverse opt-in is announced up front.
reach_scan() {
    local dir="$1" anc
    REACH_GRANT=(); REACH_BLOCKED=""
    anc="$(dirname "${dir}")"
    while [[ "${anc}" != / && "${anc}" != . ]]; do
        if agent_can_traverse "${anc}"; then break; fi
        if grantable_ancestor "${anc}"; then
            REACH_GRANT+=("${anc}")
        else
            REACH_BLOCKED="${anc}"; break
        fi
        anc="$(dirname "${anc}")"
    done
}

# reg_reach <dir>  -- the reachability block: ensure the sandbox account can TRAVERSE the
# path to <dir>, acting on reach_scan's result (the CALLER runs reach_scan first). The
# confined session runs as the sandbox account; a project nested under a directory it
# cannot enter (a private home, 700) is unreachable, so claude-run reports it missing even
# after a clean claim. Grant traverse-only (execute, no read -- u:SANDBOX_USER:--x) on
# each blocking ancestor the operator owns and that is not a protected system directory:
# enough to enter and reach the project, never to list or read it, and unprivileged
# because the operator owns those directories. A blocking ancestor that is a system
# directory or someone else's is left untouched -- there an isolated sandbox clone (under
# /var/opt/ai-tools, already agent-traversable) is the way in. Default-NO: it widens
# access ABOVE the project, so it is a separate, explicit opt-in.
reg_reach() {
    local dir="$1" a
    if [[ -n "${REACH_BLOCKED}" ]]; then
        local why
        if ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
            why="the safe-paths backstop is not loaded, so ancestors cannot be vetted"
        elif ai_tools_protected_path_match "${REACH_BLOCKED}" >/dev/null 2>&1; then
            why="a protected system directory"
        else
            why="owned by $(stat -c '%U' "${REACH_BLOCKED}" 2>/dev/null || echo '?'), not by ${ME}"
        fi
        headline_warn "WARNING: project unreachable for the sandbox account" \
            "the sandbox account cannot traverse ${REACH_BLOCKED} (${why}), so it cannot reach ${dir}; an isolated clone under the sandbox area is the way in:"
        say "      ${C_BOLD}ai-tools --sandbox-create ${dir}${C_RST}"
        return 0
    fi
    if (( ${#REACH_GRANT[@]} == 0 )); then return 0; fi
    headline_warn "WARNING: parent directories block the agent" \
        "the sandbox account must be able to traverse every parent directory to reach the project; the grant below is traverse-only (enter, never list or read): u:${SANDBOX_USER}:--x"
    for a in "${REACH_GRANT[@]}"; do say "      ${a}"; done
    if confirm "Grant the sandbox account traverse-only access on them?" n; then
        local failed=false
        for a in "${REACH_GRANT[@]}"; do
            if setfacl -m "u:${SANDBOX_USER}:--x" "${a}" 2>/dev/null; then
                say "    reach: u:${SANDBOX_USER}:--x ${a}"
            else
                failed=true
                warn "reach: could not grant on ${a} -- run: setfacl -m u:${SANDBOX_USER}:--x ${a}"
            fi
        done
        ${failed} || ok "parent directories traversable by the sandbox account"
    else
        say "    reach: left as-is -- the agent may be unable to enter ${dir}"
    fi
}

# normalize_clone <dir> [locked-path...]  -- make a freshly created clone
# agent-accessible. The clone is born in group SANDBOX_GROUP via the setgid SANDBOX_ROOT
# but cloned under umask 077 (see cmd_sandbox_create), so nothing in it is
# group-readable until this step. Add group rwX and the setgid bit on every directory
# (owner stays the projects user); the SessionStart ai-tools-setgid pass keeps it
# normalized thereafter. Every <locked-path> (the secret gate's finds, locked to
# owner-only by ai-tools-lockdown) is PRUNED from both walks -- re-opening one here
# would undo the lockdown this step is sequenced after.
normalize_clone() {
    local d="$1"; shift
    local -a prune=() p
    for p in "$@"; do prune+=( -path "${p}" -prune -o ); done
    find "${d}" "${prune[@]}" -exec chmod g+rwX {} +
    find "${d}" "${prune[@]}" -type d -exec chmod g+s {} +
}

# relabel_clone <dir>  -- apply the SELinux project label so the agent (ai_tools_t)
# can read/write the clone. A static fcontext rule in selinux/policy/ai_tools.fc maps every
# directory under sandbox-projects/ to ai_tools_project_t, so a plain restorecon
# labels it -- no per-project semanage and no root: the projects user runs as
# unconfined_t, which the policy grants relabel to ai_tools_project_t. No-op when
# SELinux is disabled (or the module is not loaded, in which case the label stays
# the default and the operator must run selinux/install-selinux.sh install).
relabel_clone() {
    local d="$1"
    command -v restorecon >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 0
    if restorecon -RF "${d}" 2>/dev/null; then
        ok "labelled clone ai_tools_project_t (SELinux)"
    else
        warn "could not relabel ${d} for SELinux; if enforcing, run: sudo restorecon -RF ${d}"
    fi
}

# ── Lockdown helpers ───────────────────────────────────────────────────────────
# ai-tools-lockdown revokes ai-tools' read access to secret-named files under a
# project. It is root-only and reads its target from the working directory, so we
# cd there and sudo it; there is no NOPASSWD grant, so sudo prompts for a password.

# run_lockdown <dir> [extra-args...]  -- run the helper on <dir>; returns its status.
run_lockdown() {
    local d="$1"; shift
    ( cd "${d}" && sudo "${LOCKDOWN_BIN}" "$@" )
}

# run_relabel <dir> [--remove]  -- apply (or revert) the SELinux project label on
# <dir> via the root helper (sudo, password); returns its status. The helper parses
# the path and the optional flag in any order.
run_relabel() {
    local d="$1"; shift
    sudo "${RELABEL_BIN}" "$@" "${d}"
}

# run_reclaim <dir> [--full]  -- hand agent-written files under <dir> back to the operator via
# the root helper (sudo, password); returns its status. The helper parses the path and --full in
# any order.
run_reclaim() {
    local d="$1"; shift
    sudo "${RECLAIM_BIN}" "$@" "${d}"
}

# run_setfacl <dir> <with_git>  -- apply the project's group-permission ACL on <dir> via
# the root helper (sudo, password); when <with_git> is true, also pass --with-git so the
# helper normalizes the .git tree too. Returns its status.
run_setfacl() {
    local d="$1" with_git="${2:-false}"
    if ${with_git}; then
        sudo "${SETFACL_BIN}" --with-git "${d}"
    else
        sudo "${SETFACL_BIN}" "${d}"
    fi
}

# run_unclaim <dir> <target-group>  -- clear the agent ACL, regroup <dir> to
# <target-group>, and remove group write, via the root helper (sudo, password); returns
# its status.
run_unclaim() {
    local d="$1" g="$2"
    sudo "${UNCLAIM_BIN}" "${d}" "${g}"
}

# secret_gate <dir>  -- the secret-lockdown block: before ANY step grants the agent
# access to <dir> (the group ACL, the setgid group change, .git normalization, the
# clone normalize), make sure no group-readable secret would be exposed. The CLI cannot
# read the root-only secret-pattern library, so detection is delegated to
# ai-tools-lockdown --dry-run (sudo, password -- the first sudo prompt of a claim, so it
# lands right under this block's headline). Found secrets are listed and the user is
# asked to lock them down (--yes apply); the helper's own interactive mode is NOT used
# for this because it exits 0 whether the user applies or aborts, which would let an
# un-locked tree through. Fills SECRET_GATE_LOCKED with the found paths so
# normalize_clone can prune them. Returns 0 only when the tree is safe to expose (no
# secrets found, or all locked down); non-zero means the caller must fail closed.
secret_gate() {
    local dir="$1" out
    SECRET_GATE_LOCKED=()
    headline "Secret lockdown" \
        "scanning ${dir} for secret-named files before the agent is granted access"
    if ! out="$(run_lockdown "${dir}" --dry-run 2>&1)"; then
        warn "secret scan failed -- not granting access:"
        printf '%s\n' "${out}" >&2
        ai_tools_log_error "secret pre-check: scan failed for ${dir}, access not granted"
        return 1
    fi
    # "N secret-matching path(s)" when any are found vs "no secret-matching paths"
    # when clean -- match the count form to tell them apart.
    if ! grep -qE 'ai-tools-lockdown: [0-9]+ secret-matching' <<<"${out}"; then
        ok "no secret-matching paths found"
        ai_tools_log_info "secret pre-check: clean, no secret-matching paths under ${dir}"
        return 0                                   # clean tree: safe to expose
    fi

    # The helper has already logged the count and each path (journald + lockdown.log);
    # record the operator-side decision here too.
    mapfile -t SECRET_GATE_LOCKED < <(printf '%s\n' "${out}" \
        | sed -n 's/^[[:space:]]*\[\(file\|dir\)\][[:space:]]*//p')
    say ""
    say "  found ${#SECRET_GATE_LOCKED[@]} secret-matching path(s):"
    printf '%s\n' "${out}" | grep -E '\[(file|dir)\]' >&2 || true
    warn "lockdown is best effort, matching only known secret patterns -- handle any secret it misses yourself first"
    ai_tools_log_warn "secret pre-check: secrets present under ${dir} (see lockdown.log for paths)"
    # Default YES: locking down is the safe direction and the list above may be long,
    # so Enter -- and an unattended run -- proceeds to lock down.
    if ! confirm "Lock down these secrets now?" y; then
        warn "declined -- access will not be granted while secrets are exposed"
        ai_tools_log_warn "secret pre-check: lockdown declined for ${dir}, access not granted"
        return 1
    fi
    if run_lockdown "${dir}" --yes; then
        say ""
        ok "secrets locked down"
        ai_tools_log_info "secret pre-check: secrets locked down under ${dir}"
        return 0
    fi
    warn "lockdown did not complete -- not granting access"
    ai_tools_log_error "secret pre-check: lockdown failed under ${dir}, access not granted"
    return 1
}

# drop_lockdown_guard <dir>  -- write a placeholder CLAUDE.md telling the agent to
# do nothing until lockdown runs, used when a fresh sandbox clone's tip-commit
# secrets are still readable. An existing CLAUDE.md is preserved as CLAUDE.md.bak
# (via git mv, falling back to a plain mv) and restored by clear_lockdown_guard.
drop_lockdown_guard() {
    local d="$1"; local md="${d}/CLAUDE.md"
    if [[ -f "${md}" ]] && grep -q "${GUARD_MARKER}" "${md}" 2>/dev/null; then
        return 0                                   # already guarded (re-run)
    fi
    if [[ -e "${md}" ]]; then
        if [[ -e "${d}/CLAUDE.md.bak" ]]; then
            warn "CLAUDE.md.bak already exists in ${d}; not overwriting -- guard skipped"
            return 0
        fi
        git -C "${d}" mv CLAUDE.md CLAUDE.md.bak 2>/dev/null \
            || mv "${md}" "${d}/CLAUDE.md.bak"
        say "    preserved existing CLAUDE.md as CLAUDE.md.bak"
    fi
    cat > "${md}" <<EOF
<!-- ${GUARD_MARKER} -->
# STOP — this sandbox is not secured yet

\`ai-tools-lockdown\` has **not** been run on this shallow clone, so credential
files in its tip commit (\`.env\`, \`appsettings.*.json\`, \`*.key\`, …) may still be
readable by the agent.

Until lockdown is performed:

- **Do not read, open, copy, or transmit any file in this project.**
- **Do not run any command.**
- Ask the operator to secure it first by running, as the projects user:

      ai-tools --lockdown ${d}

Only paths approved in the operator's \`allowed-projects\` allowlist are ever in
scope, and only after lockdown has revoked the agent's read access to secrets.

This file is a temporary guard. It is removed automatically once lockdown runs,
and any original CLAUDE.md is restored from CLAUDE.md.bak.
EOF
    ok "wrote a guard CLAUDE.md (agent told to wait for lockdown)"
}

# clear_lockdown_guard <dir>  -- remove a guard CLAUDE.md and restore any
# CLAUDE.md.bak it set aside. No-op unless the guard sentinel is present. Called
# after a successful (non-dry-run) lockdown.
clear_lockdown_guard() {
    local d="$1"; local md="${d}/CLAUDE.md"
    [[ -f "${md}" ]] || return 0
    grep -q "${GUARD_MARKER}" "${md}" 2>/dev/null || return 0
    rm -f "${md}"
    if [[ -e "${d}/CLAUDE.md.bak" ]]; then
        git -C "${d}" mv CLAUDE.md.bak CLAUDE.md 2>/dev/null \
            || mv "${d}/CLAUDE.md.bak" "${md}"
        say "    restored original CLAUDE.md from CLAUDE.md.bak"
    fi
    ok "removed the lockdown guard from ${d}"
}

# ── Commands ─────────────────────────────────────────────────────────────────────

# project_state <dir>  -- print the claim state of <dir> as seven space-separated
# tokens: "<listed> <safedir> <filemode> <owngap> <acl> <labelled> <git>". listed/safedir
# reflect the two registries; filemode is true when repo-local core.filemode is already
# true ("na" when <dir> is not a git work tree); owngap is true when the agent still
# lacks group access (see dir_owngap); acl is true when the group-permission ACL still
# needs applying (see acl_gap); labelled is the live SELinux type check -- true/false
# when SELinux is active, "na" when it is disabled (no label needed); git is true when a
# .git tree is present but not yet normalized for agent history sharing (see git_gap),
# false otherwise -- it gates the opt-in .git prompt, not a mandatory claim step. Read-only,
# no privilege. The ai_tools_project_t string is the single fact mirrored from the root
# labelling lib; the authoritative semanage/restorecon logic is NOT duplicated here.
project_state() {
    local dir="$1" listed=false safedir=false filemode=na owngap=true acl=false labelled=na git=false
    grep -qxF "${dir}" "${ALLOWLIST}" 2>/dev/null && listed=true
    git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
        | grep -qxF "${dir}" && safedir=true
    if git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        [[ "$(git -C "${dir}" config --local --get core.filemode 2>/dev/null)" == "true" ]] \
            && filemode=true || filemode=false
    fi
    dir_owngap "${dir}" || owngap=false
    acl_gap "${dir}" && acl=true
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        if ls -Zd "${dir}" 2>/dev/null | grep -q ':ai_tools_project_t:'; then
            labelled=true
        else
            labelled=false
        fi
    fi
    git_gap "${dir}" && git=true
    printf '%s %s %s %s %s %s %s\n' \
        "${listed}" "${safedir}" "${filemode}" "${owngap}" "${acl}" "${labelled}" "${git}"
}

# claim_relabel <dir>  -- apply the SELinux project label via the root helper so the
# confined agent can access the tree. Best-effort, mirroring lockdown: warns with the
# manual command (never dies) when sudo is missing or the helper fails.
claim_relabel() {
    local d="$1"
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot apply the SELinux label automatically"
        say  "      ${C_BOLD}sudo ${RELABEL_BIN} ${d}${C_RST}"
        return 0
    fi
    if run_relabel "${d}"; then
        say "    SELinux label: ai_tools_project_t applied"
    else
        warn "could not apply the SELinux label -- run it by hand:"
        say  "      ${C_BOLD}sudo ${RELABEL_BIN} ${d}${C_RST}"
    fi
}

# claim_setfacl <dir> <with_git>  -- apply the group-permission ACL via the root helper so
# files the projects user's git checkout/merge writes under a restrictive umask stay group-
# accessible; when <with_git> is true the helper also normalizes the .git tree (group +
# setgid + ACL) so the operator's commits stay agent-accessible. Best-effort, mirroring
# claim_relabel: warns with the manual command (never dies) when sudo is missing or fails.
claim_setfacl() {
    local d="$1" with_git="${2:-false}" flag="" note=""
    ${with_git} && { flag=" --with-git"; note=" (incl. .git)"; }
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot apply the project ACL automatically"
        say  "      ${C_BOLD}sudo ${SETFACL_BIN}${flag} ${d}${C_RST}"
        return 0
    fi
    if run_setfacl "${d}" "${with_git}"; then
        say "    group-permission ACL: applied${note}"
    else
        warn "could not apply the project ACL -- run it by hand:"
        say  "      ${C_BOLD}sudo ${SETFACL_BIN}${flag} ${d}${C_RST}"
    fi
}

# cmd_project_claim [path]  -- idempotently bring a real, IN-PLACE project (default:
# cwd) to a fully claimed state: allowlist + git safe.directory + git core.filemode +
# secret lockdown + recursive ownership + group-permission ACL + SELinux
# ai_tools_project_t label, so the agent can work the REAL tree. Inspects current state
# first and performs ONLY the missing steps, so a re-run is quiet and a fully-claimed
# project is a clean no-op (no prompt, no sudo).
#
# The flow is a sequence of SELF-CONTAINED blocks, each opened by a headline box and
# closed by its own confirm/result, in this order:
#   1. Review    -- the pending-step overview (every later block announced), the drift
#                   reports, and -- when a heavy step (chgrp, ACL, relabel, drift repair)
#                   is pending -- the default-NO proceed confirm that covers exactly the
#                   steps listed.
#   2. Secret lockdown -- BEFORE any access-granting step, whenever one is pending or
#                   this is a first claim (see secret_gate); fails the claim closed.
#   3. .git history  -- separate default-YES opt-in (ai-tools-setfacl --with-git).
#   4. Reachability  -- separate default-NO opt-in for traverse-only ancestor ACLs.
#   5. Apply     -- the approved steps back to back, one result line each, closed by
#                   the final "claimed" ✓.
# A re-claim with ownership in place also scans for interior drift (acl_drift_scan:
# shared-looking paths brought into the tree without inheriting the group/ACL) and folds
# the group+ACL re-apply into the proceed confirm and secret gate -- repair never runs
# unconfirmed. A first claim skips the report: its normal walk repairs the whole tree.
cmd_project_claim() {
    # -y/--yes pre-answers the claim's own proceed prompt ("Apply the pending steps IN
    # PLACE?", default NO) -- an explicit per-invocation flag, passed by a caller that
    # already confirmed the same decision (the launch wrapper's delegated claim). The
    # scoped opt-ins (secret lockdown, .git history, ancestor traversal) are separate
    # questions it does not answer.
    local a path="" ASSUME_YES=false
    for a in "$@"; do
        case "${a}" in
            -y|--yes) ASSUME_YES=true ;;
            -*) die "unknown --project-claim option: ${a} (allowed: -y/--yes)" ;;
            *)  if [[ -z "${path}" ]]; then path="${a}"
                else die "--project-claim takes a single path"; fi ;;
        esac
    done
    local d; d="$(resolve_dir "${path:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    # Refuse to claim a protected system directory before it ever reaches the allowlist. The
    # safe-paths guard is guaranteed loaded (the top-level source fails closed otherwise).
    ai_tools_assert_safe_target "${d}" "project claim" || exit 3

    local listed safedir filemode owngap acl labelled git
    # project_state prints seven SPACE-separated tokens; this script's global IFS is
    # $'\n\t' (no space), so a bare read would collapse the whole line into the first
    # field and leave the rest empty -- silently skipping the label/ACL/ownership steps.
    # Pin IFS=' ' for this read so the tokens split as intended.
    IFS=' ' read -r listed safedir filemode owngap acl labelled git < <(project_state "${d}")
    local need_label=false; [[ "${labelled}" == false ]] && need_label=true
    local need_filemode=false; [[ "${filemode}" == false ]] && need_filemode=true
    local need_acl=false; [[ "${acl}" == true ]] && need_acl=true
    local need_git=false; [[ "${git}" == true ]] && need_git=true

    # Interior drift: the root-level state says nothing about paths brought INTO a claimed
    # tree without inheriting the group/ACL (mv keeps the old group). Detect them here;
    # the repair applies further down behind the same confirm + secret gate as the other
    # in-place steps. Scanned only on a RE-CLAIM whose ownership is already in place: a
    # first claim (or one with the setgid step still pending) walks and repairs the whole
    # tree anyway, and its every path would trivially match the drift predicate -- a
    # 200-line report of what the claim is about to fix is noise, not signal.
    local -a drift=()
    if [[ "${listed}" == true && "${owngap}" == false ]]; then
        mapfile -t drift < <(acl_drift_scan "${d}" | head -n 200)
    fi

    # Split the hits on the shared skip list: the sweeps AND the claim walks leave a
    # skip-listed directory's contents alone (one skip contract), so a re-claim cannot
    # repair a hit under one -- it gets its own report with the remedies that can.
    local -a drift_skipped=()
    if ai_tools_skip_find_expr sweep 2>/dev/null && (( ${#AI_TOOLS_SKIP_NAMES[@]} )); then
        local -a _keep=()
        local _hit _rel _seg _name _under _s _x
        for _hit in "${drift[@]}"; do
            _under=false
            _rel="${_hit#"${d}"/}"
            IFS=/ read -ra _seg <<< "${_rel}"
            for _name in "${AI_TOOLS_SKIP_NAMES[@]}"; do
                for _s in "${_seg[@]}"; do
                    [[ "${_s}" == "${_name}" ]] && { _under=true; break 2; }
                done
            done
            # A relative artifact exclusion re-opens its subtree to the walks, so a hit
            # under one is repairable, not skip-listed.
            if ${_under}; then
                for _x in "${AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE[@]:-}"; do
                    [[ -z "${_x}" ]] && continue
                    _x="${_x%/}"
                    [[ "${_rel}" == "${_x}" || "${_rel}" == "${_x}"/* ]] && { _under=false; break; }
                done
            fi
            if ${_under}; then drift_skipped+=("${_hit}"); else _keep+=("${_hit}"); fi
        done
        drift=("${_keep[@]}")
    fi

    # _drift_lines <path...>: print each path prefixed with its owner:group and mode --
    # the columns that show at a glance why the path is flagged (the foreign group) and
    # whether the mode is what the operator expects.
    _drift_lines() {
        local _p _og _m
        for _p in "$@"; do
            IFS=' ' read -r _og _m < <(stat -c '%U:%G %a' "${_p}" 2>/dev/null) \
                || { _og='?'; _m='?'; }
            printf '        %s%-18s %-4s %s%s\n' "${C_DIM}" "${_og}" "${_m}" "${_p}" "${C_RST}"
        done
    }

    # _drift_list_all <label> <path...>: after a truncated sample, offer the full list
    # (owner/group/mode columns). Default yes: it is read-only and the point of asking is
    # a long list, so Enter shows it; a piped/delegated run prints it too (grep-able).
    _drift_list_all() {
        local _label="$1"; shift
        confirm "      List all $# ${_label} with ownership and mode?" y || return 0
        _drift_lines "$@"
    }

    # skip_listed_note: the skip-listed hits are informational either way -- shown both on
    # the fully-claimed early return and in the pending flow.
    skip_listed_note() {
        (( ${#drift_skipped[@]} )) || return 0
        headline_warn "NOTICE: drift under skip-listed directories" \
            "${#drift_skipped[@]} path(s) with a foreign group sit under skip-listed directory names (build output, dependencies, caches); claim leaves those trees untouched."
        _drift_lines "${drift_skipped[@]:0:3}"
        if (( ${#drift_skipped[@]} > 3 )); then
            say "        ${C_DIM}... and $(( ${#drift_skipped[@]} - 3 )) more${C_RST}"
            _drift_list_all "path(s)" "${drift_skipped[@]}"
        fi
        say "      ${C_DIM}if one is source in this project, exempt it in /etc/ai-tools/operator.conf --${C_RST}"
        say "      ${C_DIM}narrow the category (SKIP_ARTIFACT_DIRS=...) or list the path relative to the${C_RST}"
        say "      ${C_DIM}project root in SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE -- then re-claim;${C_RST}"
        say "      ${C_DIM}ownership only: ai-tools --reclaim --full${C_RST}"
    }

    # ── Review block: the flow headline, the pending-step overview, and the drift
    # reports, so the proceed confirm that closes it covers exactly what was just
    # shown. Every later block is announced here with a "you will be asked" marker. ──
    local heavy=false
    local -a head=("${d}")
    if [[ "${owngap}" == true ]] || ${need_acl} || ${need_label} || (( ${#drift[@]} )); then
        heavy=true
        head+=("claiming in place grants the agent group access to this whole tree")
    fi
    headline "Claim project (in place)" "${head[@]}"

    reach_scan "${d}"

    if [[ "${listed}" == true && "${safedir}" == true && "${owngap}" == false ]] \
            && ! ${need_filemode} && ! ${need_acl} && ! ${need_label} && ! ${need_git} \
            && (( ${#drift[@]} == 0 )); then
        skip_listed_note
        # A claimed project can still sit under a non-traversable parent (a later
        # chmod 700 above it), so the reachability block runs on the no-op path too.
        reg_reach "${d}"
        ok "already fully claimed -- nothing to do"
        return 0
    fi

    # The gate runs whenever any pending step widens the agent's access -- the setgid
    # group change, the group ACL, drift repair, .git normalization, the SELinux label --
    # and on every first claim (a tree can be group-accessible by setgid inheritance yet
    # never scanned). Only pure registry additions (safedir, filemode) skip it.
    local need_gate=false
    if [[ "${listed}" != true || "${owngap}" == true ]] \
            || ${need_acl} || ${need_git} || ${need_label} || (( ${#drift[@]} )); then
        need_gate=true
    fi

    say ""
    say "  pending:"
    [[ "${listed}"  == true  ]] || say "    - add to allowed-projects"
    [[ "${safedir}" == true  ]] || say "    - add git safe.directory"
    ${need_filemode} && say "    - set git core.filemode true"
    [[ "${owngap}"  == true  ]] && say "    - set group ${SANDBOX_GROUP} + setgid on the project directories"
    ${need_acl} && say "    - apply group-permission ACL (default + access g:${SANDBOX_GROUP}:rwX)"
    ${need_label} && say "    - apply SELinux ai_tools_project_t label"
    (( ${#drift[@]} )) && say "    - re-apply group ${SANDBOX_GROUP} + ACL to ${#drift[@]} drifted path(s) -- details below"
    ${need_gate} && say "    - scan for secret-named files and lock them down -- you will confirm"
    ${need_git} && say "    - normalize .git so the agent can access git history -- you will be asked"
    (( ${#REACH_GRANT[@]} )) && say "    - grant traverse-only access on ${#REACH_GRANT[@]} parent path(s) -- you will be asked"

    if (( ${#drift[@]} )); then
        headline_warn "WARNING: interior permission drift" \
            "${#drift[@]} path(s) inside the tree carry a foreign group yet stay group-accessible (they arrived without inheriting the project group or ACL)."
        _drift_lines "${drift[@]:0:3}"
        if (( ${#drift[@]} > 3 )); then
            say "        ${C_DIM}... and $(( ${#drift[@]} - 3 )) more$( (( ${#drift[@]} >= 200 )) && printf ' (list capped at 200)' )${C_RST}"
            _drift_list_all "path(s)" "${drift[@]}"
        fi
    fi
    skip_listed_note

    # Heavy steps (recursive chgrp; sudo relabel/ACL; drift repair) close the Review
    # block behind the proceed confirm; pure registry additions do not. --yes pre-answers
    # exactly this prompt: the launch wrapper passes it after taking its own "Claim it in
    # place now?" confirmation, so a delegated claim does not ask the same question
    # twice. The scoped opt-ins below (secret lockdown, .git history, ancestor traversal)
    # still ask on their own terms.
    if ${heavy}; then
        ${ASSUME_YES} || confirm "Apply the pending steps above IN PLACE?" n \
            || die "aborted"
    fi

    # Allowlist first: ai-tools-lockdown only scans an allowlisted path. Rolled back on
    # a failed gate.
    [[ "${listed}" == true ]] || reg_allow "${d}"

    if ${need_gate}; then
        if ! secret_gate "${d}"; then
            [[ "${listed}" == true ]] || unreg_allow "${d}"
            say "    lock down secrets first, then re-run the claim:"
            say "      ${C_BOLD}ai-tools --lockdown ${d}${C_RST}"
            die "claim stopped -- secrets not locked down"
        fi
    fi

    # .git access is opt-in (default yes), asked separately from the proceed prompt --
    # which --yes covers; this one it does not, so a wrapper-delegated claim still asks
    # before exposing the repo's full git history.
    local do_git=false
    if ${need_git}; then
        headline_warn "WARNING: git history exposure" \
            "normalizing .git lets the agent read this repo's full git history"
        if confirm "Normalize .git so the agent can access git history here?" y; then
            do_git=true
        else
            say "    .git: left as-is (history not accessible to the agent)"
        fi
    fi

    reg_reach "${d}"

    # ── Apply block: the approved steps run back to back, each reporting one result
    # line; the closing ✓ is the claim's completion. ──
    headline "Applying claim steps" "${d}"
    [[ "${safedir}" == true  ]] || reg_safedir "${d}"
    ${need_filemode} && reg_filemode "${d}"
    if [[ "${owngap}" == true ]]; then
        reg_ownership "${d}"
    elif (( ${#drift[@]} )); then
        reg_ownership "${d}" force
    fi
    { ${need_acl} || ${do_git} || (( ${#drift[@]} )); } && claim_setfacl "${d}" "${do_git}"
    ${need_label} && claim_relabel "${d}"
    say ""
    ok "claimed ${d}"
    ai_tools_log_info "claimed project ${d}"
}

# cmd_project_create [path]  -- back-compat alias for cmd_project_claim. Claiming is
# idempotent now, so "create" and "claim" are the same operation.
cmd_project_create() { cmd_project_claim "$@"; }

# cmd_project_unclaim [path]  -- undo an in-place claim (default: cwd): revert the
# SELinux label, drop both registries, and (default-yes confirm) hand the tree's
# filesystem back to a target group with the agent's write access revoked. The directory
# itself is left on disk. The filesystem hand-back (ai-tools-unclaim) clears the agent
# ACL + default ACL, regroups every eligible file to the target group, and removes group
# write (660->640, 770->750, 400 stays 400) -- so the agent loses access via both the
# group owner and the named ACL entry. The target group defaults to the invoking user's
# own group; any other system user can be named (the tree is handed to that user's group).
cmd_project_unclaim() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    section "Unclaim project"
    say "  ${d}"
    say "  ${C_DIM}(the directory itself is left on disk)${C_RST}"
    confirm "Unclaim this project?" n || die "aborted"
    # Revert the SELinux label before dropping the registries. The helper's --remove is
    # lenient about allowlist membership, but reverting first keeps the invariant
    # "labelled => allowlisted". Best-effort: warn, never fail the unclaim. Skipped
    # for sandbox paths (handled by cmd_sandbox_remove) and when SELinux is inactive.
    if command -v sudo >/dev/null 2>&1 \
            && command -v getenforce >/dev/null 2>&1 \
            && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        run_relabel "${d}" --remove \
            || warn "could not revert SELinux label -- run: sudo ${RELABEL_BIN} --remove ${d}"
    fi
    unreg_allow "${d}"
    unreg_safedir "${d}"

    # Filesystem hand-back: revoke the agent and return the tree to a real group. Default
    # YES (it is the natural completion of an unclaim) but confirmed, since it rewrites
    # ownership/permissions across the tree.
    if confirm "Hand the files back to a group and remove the agent's write access?" y; then
        local target_user target_group
        target_user="$(ask "  Hand the files to which user's group?" "${ME}")"
        if ! target_group="$(id -gn "${target_user}" 2>/dev/null)"; then
            warn "no such user '${target_user}' -- skipping the filesystem hand-back"
            say  "      run it later with: ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} <group>${C_RST}"
        elif ! command -v sudo >/dev/null 2>&1; then
            warn "sudo not found -- cannot hand the files back automatically"
            say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${target_group}${C_RST}"
        elif run_unclaim "${d}" "${target_group}"; then
            ok "handed ${d} back to group ${target_group}, agent write access removed"
        else
            warn "could not hand the files back -- run it by hand:"
            say  "      ${C_BOLD}sudo ${UNCLAIM_BIN} ${d} ${target_group}${C_RST}"
        fi
    fi

    ok "unclaimed ${d}"
    ai_tools_log_info "unclaimed project ${d}"
}

# sandbox_finalize <dst>  -- the access-granting tail of every sandbox create, run only
# AFTER the clone exists: allowlist (the lockdown scan acts only on an allowlisted path;
# rolled back on a failed gate), the secret-lockdown gate, then -- strictly past the
# gate -- normalize (pruning the locked paths), relabel, and register. FAIL CLOSED: a
# declined or failed gate leaves the clone on disk but private to the operator -- cloned
# under umask 077, so nothing in it is group-readable -- not normalized, not relabelled,
# not registered, with a guard CLAUDE.md dropped and the resume command printed.
# Re-running --sandbox-create on the existing clone path resumes here.
sandbox_finalize() {
    local dst="$1"
    reg_allow "${dst}"
    if ! secret_gate "${dst}"; then
        unreg_allow "${dst}"
        drop_lockdown_guard "${dst}"
        warn "sandbox not secured -- the clone stays private to you:" \
             "not group-accessible, not registered; the agent has no access to it"
        say  "    handle the secrets, then finish the create:"
        say  "      ${C_BOLD}ai-tools --sandbox-create ${dst}${C_RST}"
        die "sandbox create stopped -- secrets not locked down"
    fi
    clear_lockdown_guard "${dst}"
    normalize_clone "${dst}" "${SECRET_GATE_LOCKED[@]}"
    say "    access: group ${SANDBOX_GROUP} rwX + setgid dirs (locked secrets stay private)"
    relabel_clone "${dst}"
    reg_safedir "${dst}"
    say ""
    ok "sandbox ready: ${dst}"
    ai_tools_log_info "sandbox secured and registered: ${dst}"

    section "Next"
    say "  run the agent  : ${C_BOLD}cd ${dst} && claude${C_RST}"
    say "  push its work  : ${C_BOLD}ai-tools --sandbox-push ${dst}${C_RST}"
    say "  ${C_YEL}shallow${C_RST}        : push-only -- never git pull/fetch here, or you pull the full history"
}

# cmd_sandbox_create [path]  -- create or reuse the per-repo branch
# ai-tools/sandbox-<user>/<leaf>, shallow-clone it PRIVATELY (umask 077) into
# SANDBOX_ROOT, then hand off to sandbox_finalize: secret lockdown first, and only past
# that gate normalize + relabel + register (fail-closed otherwise). Pointed at an
# EXISTING clone under SANDBOX_ROOT, it resumes sandbox_finalize on it -- the recovery
# path for a create whose gate was declined or failed.
cmd_sandbox_create() {
    local src; src="$(resolve_dir "${1:-$PWD}")"

    case "${src}/" in
        "${SANDBOX_ROOT}"/*)
            git -C "${src}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
                || die "not a git clone: ${src}"
            headline "Resume sandbox project" "${src}" \
                "securing and registering an existing clone"
            sandbox_finalize "${src}"
            return 0 ;;
    esac
    git -C "${src}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git repository: ${src}"
    local top; top="$(git -C "${src}" rev-parse --show-toplevel)"
    local cur
    cur="$(git -C "${top}" symbolic-ref --short HEAD 2>/dev/null)" \
        || die "repository is in detached HEAD; check out a branch first: ${top}"

    local remote
    if git -C "${top}" remote | grep -qx "origin"; then
        remote="origin"
    else
        remote="$(git -C "${top}" remote | head -1)"
    fi
    [[ -n "${remote}" ]] || die "repository has no remote; the sandbox workflow needs one: ${top}"
    local remote_url; remote_url="$(git -C "${top}" remote get-url "${remote}")"

    headline "Create sandbox project" \
        "an isolated shallow clone of this repo, registered for the agent; work is pushed to a dedicated branch that you merge back"
    say "  source repo    : ${top}"
    say "  current branch : ${cur}"
    say "  remote         : ${remote}  ${C_DIM}${remote_url}${C_RST}"

    local leaf; leaf="$(ask "Branch leaf under ai-tools/sandbox-${ME}/" "main")"
    leaf="${leaf#/}"; leaf="${leaf%/}"
    [[ -n "${leaf}" ]] || die "branch leaf cannot be empty"
    local br="ai-tools/sandbox-${ME}/${leaf}"

    local name; name="$(ask "Sandbox directory name under ${SANDBOX_ROOT}" "$(basename "${top}")")"
    [[ -n "${name}" && "${name}" != */* ]] || die "invalid directory name: ${name}"
    local dst="${SANDBOX_ROOT}/${name}"
    if [[ -e "${dst}" ]]; then
        say "    to finish securing/registering an earlier clone of this name:"
        say "      ${C_BOLD}ai-tools --sandbox-create ${dst}${C_RST}"
        die "destination already exists: ${dst}"
    fi
    [[ -d "${SANDBOX_ROOT}" ]] || die "sandbox area missing: ${SANDBOX_ROOT} -- run install first"

    # If the branch already exists on the remote (a prior sandbox of this repo),
    # reuse it rather than force-pushing over it -- this resumes earlier work and
    # never discards commits. To reset it, delete the remote branch or pick a new leaf.
    local br_exists=false
    [[ -n "$(git -C "${top}" ls-remote --heads "${remote}" "${br}" 2>/dev/null)" ]] \
        && br_exists=true

    say ""
    say "  will:"
    if ${br_exists}; then
        say "    1. ${C_YEL}reuse existing remote branch${C_RST} ${C_BOLD}${br}${C_RST} (your current ${cur} is NOT pushed over it)"
    else
        say "    1. create branch ${C_BOLD}${br}${C_RST} from ${cur} and push it to ${remote}"
    fi
    say "    2. shallow-clone that branch into ${C_BOLD}${dst}${C_RST}, private to you"
    say "    3. lock down tip-commit secrets, then grant the agent access and register the clone"
    confirm "Create the sandbox clone?" y || die "aborted"

    if ${br_exists}; then
        ok "reusing existing remote branch ${br}"
    else
        git -C "${top}" branch -f "${br}" HEAD
        git -C "${top}" push "${remote}" "${br}"
        ok "pushed ${br} to ${remote}"
    fi

    # git silently ignores --depth for a clone from a local path, which would copy
    # the FULL history into the sandbox and defeat the isolation. Force the file://
    # transport for local-path remotes so depth=1 is honored; network remotes
    # (ssh/https) honor it natively and keep their original URL.
    local clone_url="${remote_url}"
    case "${remote_url}" in
        /*|./*|../*) clone_url="file://$(realpath -m "${remote_url}")" ;;
    esac
    # umask 077: the clone is born OWNER-ONLY, so the tip commit's files -- possibly
    # checked-in credentials -- are unreadable to the sandbox account (the setgid
    # SANDBOX_ROOT already puts them in group SANDBOX_GROUP) until the secret gate has
    # run and normalize_clone deliberately opens the non-secret paths.
    ( umask 077 && git clone --depth=1 -b "${br}" "${clone_url}" "${dst}" )
    ok "shallow-cloned into ${dst} (private until secured)"
    ai_tools_log_info "created sandbox clone ${dst} (branch ${br}, remote ${remote})"

    sandbox_finalize "${dst}"
}

# cmd_sandbox_push [path]  -- push the sandbox clone's commits ahead of its upstream
# branch, after listing them and confirming. No-op when already up to date.
cmd_sandbox_push() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    require_sandbox "${d}"
    git -C "${d}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git repository: ${d}"
    local up
    up="$(git -C "${d}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
        || die "no upstream configured for the current branch in ${d}"
    local n; n="$(git -C "${d}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"

    section "Push sandbox work"
    say "  sandbox  : ${d}"
    say "  upstream : ${up}"
    if [[ "${n}" == "0" ]]; then
        ok "nothing to push (already up to date with ${up})"
        return 0
    fi
    say "  ${n} commit(s) to push:"
    git -C "${d}" --no-pager log --oneline '@{u}..HEAD' | sed 's/^/      /'
    confirm "Push ${n} commit(s) to ${up}?" y || die "aborted"
    git -C "${d}" push
    ok "pushed ${n} commit(s) to ${up}"
    ai_tools_log_info "pushed ${n} commit(s) from sandbox ${d} to ${up}"
}

# cmd_sandbox_remove [path]  -- delete a sandbox clone and unregister it, warning
# first about any unpushed commits. The remote branch is left intact.
cmd_sandbox_remove() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    require_sandbox "${d}"
    section "Remove sandbox project"
    say "  ${d}"

    local n=0
    if git -C "${d}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        n="$(git -C "${d}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    fi
    if [[ "${n}" != "0" ]]; then
        warn "${n} unpushed commit(s) will be lost (already-pushed work stays on the remote)"
        confirm "Discard ${n} unpushed commit(s) and remove ${d}?" n || die "aborted"
    else
        confirm "Remove ${d} and unregister it?" n || die "aborted"
    fi

    rm -rf "${d}"
    unreg_allow "${d}"
    unreg_safedir "${d}"
    ok "removed ${d} and unregistered it"
    ai_tools_log_info "removed sandbox ${d} and unregistered it"
    say "  ${C_DIM}remote branch left intact -- others may still merge it${C_RST}"
}

# cmd_lockdown [path] [-n|-y]  -- run ai-tools-lockdown (via sudo) on the project to
# revoke ai-tools' read access to secret files; clears any guard CLAUDE.md on a real
# (non-dry-run) success. -n/--dry-run and -y/--yes pass through to the helper.
cmd_lockdown() {
    local d="" a dry=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            -n|--dry-run) passthru+=("${a}"); dry=true ;;
            -y|--yes)     passthru+=("${a}") ;;
            -*)           die "unknown --lockdown option: ${a} (allowed: --dry-run, --yes)" ;;
            *)            if [[ -z "${d}" ]]; then d="${a}"; else die "--lockdown takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    # No readable-path pre-check: /usr/local/sbin/ai-tools is 750 root:root, so the
    # projects user cannot even stat the helper -- only sudo (as root) can reach it.
    # If it is genuinely missing, sudo reports it and run_lockdown returns non-zero.
    section "Lock down project secrets"
    say "  ${d}"
    say "  ${C_DIM}secret-matching files -> 600, dirs -> 700, owner ${ME}:${SANDBOX_GROUP}${C_RST}"
    if run_lockdown "${d}" "${passthru[@]}"; then
        ${dry} || clear_lockdown_guard "${d}"
        ok "lockdown done: ${d}"
        ${dry} || ai_tools_log_info "locked down secrets in ${d}"
    else
        die "lockdown failed for ${d}"
    fi
}

# cmd_reclaim [--full] [path]  -- hand agent-written files under the project (default: cwd) back to
# ${ME}:${SANDBOX_GROUP} via ai-tools-reclaim (sudo). Reclaims the .git tree the per-session sweeps
# skip; run it before an ACL-unaware backup so ownership (not the per-project ACL) carries the
# operator's access into the copy. --full also reclaims the heavy trees the default run skips
# (node_modules, .venv, ...).
cmd_reclaim() {
    local d="" a full=false; local -a passthru=()
    for a in "$@"; do
        case "${a}" in
            --full) passthru+=("${a}"); full=true ;;
            -*)     die "unknown --reclaim option: ${a} (allowed: --full)" ;;
            *)      if [[ -z "${d}" ]]; then d="${a}"; else die "--reclaim takes a single path"; fi ;;
        esac
    done
    d="$(resolve_dir "${d:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    section "Reclaim agent-written files"
    say "  ${d}${C_DIM}$(${full} && printf ' (--full: incl. node_modules, .venv, ...)')${C_RST}"
    say "  ${C_DIM}-> ${ME}:${SANDBOX_GROUP} (secret-named files stay ${ME}:${ME} 600)${C_RST}"
    # The helper reports the outcome itself -- the pre-scan count, the one whole-set
    # confirm, then "handed back N" / "nothing to reclaim" / "declined" -- so no blanket
    # success line here: the CLI states only what actually happened.
    run_reclaim "${d}" "${passthru[@]}" || die "reclaim failed for ${d}"
    ai_tools_log_info "reclaim run for ${d}$(${full} && printf ' (full)')"
}

# cmd_relabel  -- restore the ai_tools_exec_t SELinux label on the claude entrypoint(s)
# after a Node auto-upgrade, via the root helper (sudo, password). A nvm-update installs a
# fresh claude binary that npm leaves mislabelled (bin_t), so the agent's domain transition
# stops firing and claude-run refuses to launch (fail-closed) until the label is restored.
# Takes no path -- the helper acts only on the fixed nvm-tree entrypoint(s).
#
# Design note: if post-upgrade maintenance ever grows beyond this one step, fold the steps
# under a `--postupgrade` umbrella verb that runs them in sequence; while relabel is the
# only step, the explicit `--relabel` is clearer in the UX, so there is no umbrella yet.
cmd_relabel() {
    [[ "$#" -eq 0 ]] || die "--relabel takes no arguments"
    section "Relabel the claude entrypoint (after a Node upgrade)"
    say "  A Node auto-upgrade installs a new claude binary that must be relabelled so"
    say "  the sandbox can confine the session; until then claude refuses to launch."
    command -v sudo >/dev/null 2>&1 \
        || die "sudo not found -- cannot relabel; run as root: ${RELABEL_ENTRYPOINT_BIN}"
    # Reaches the helper through the dedicated fixed-path NOPASSWD rule (the same one the
    # nvm-update timer uses), so this runs as root without a password prompt.
    if sudo "${RELABEL_ENTRYPOINT_BIN}"; then
        ok "entrypoint relabelled -- exit any running claude and relaunch"
        ai_tools_log_info "relabelled claude entrypoint (post-upgrade)"
    else
        die "relabel failed -- see the message above"
    fi
}

# cmd_list  -- print each allowlist entry as project, sandbox, or exclude, with its
# git safe.directory status.
cmd_list() {
    [[ -f "${ALLOWLIST}" ]] || { say "no allowlist at ${ALLOWLIST}"; return 0; }
    section "Registered projects"
    local entry kind safe shown=0
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
        shown=1
        if [[ "${entry}" == '!'* ]]; then
            printf '  %-8s %s\n' "exclude" "${entry:1}"
            continue
        fi
        case "${entry}/" in
            "${SANDBOX_ROOT}"/*) kind="sandbox" ;;
            *)                   kind="project" ;;
        esac
        if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
                | grep -qxF "${entry}"; then
            safe="safe.dir:yes"
        else
            safe="safe.dir:${C_YEL}NO${C_RST}"
        fi
        printf '  %-8s %-50s %s\n' "${kind}" "${entry}" "${safe}"
    done < "${ALLOWLIST}"
    (( shown )) || say "  (none)"
}

# usage() is paired with the ai-tools(1) man page (src/usr/local/share/man/man1/
# ai-tools.1): tests/unit/man.sh asserts the two long-option sets match, so an option
# added, renamed, or removed here changes the man page in the same commit.
usage() {
    cat <<EOF
ai-tools -- manage Claude Code sandbox projects (run as the projects user)

  ai-tools --project-claim [-y] [path]  claim a real project in place (idempotent; default: cwd)
  ai-tools --project-create  [path]  alias for --project-claim (back-compat)
  ai-tools --project-unclaim [path]  unclaim a real project (hand files back, revoke agent)
  ai-tools --project-remove  [path]  alias for --project-unclaim (back-compat)
  ai-tools --sandbox-create [path]   shallow-clone a repo into the sandbox area
  ai-tools --sandbox-push   [path]   push the sandbox clone's commits to its branch
  ai-tools --sandbox-remove [path]   remove a sandbox clone and unregister it
  ai-tools --lockdown [path] [-n|-y] lock down secret files (sudo; default: cwd)
  ai-tools --reclaim [--full] [path] hand agent-written files back to you (sudo; default: cwd)
  ai-tools --relabel                 relabel the claude entrypoint after a Node upgrade (sudo)
  ai-tools --list                    list registered projects
  ai-tools --version
  ai-tools --help

  --project-claim options: -y/--yes (pre-answer the proceed prompt; the secret-lockdown,
                      .git-history, and ancestor-traversal questions still ask)
  --lockdown options: -n/--dry-run (preview only), -y/--yes (skip confirmation)
  --reclaim options:  --full (also reclaim node_modules, .venv, ... not just the work tree + .git)

Sandbox workflow: /var/opt/ai-tools/README.md
EOF
}

# Refuse early on an unprovisioned install. CLAUDE_LINK is bootstrap's last load-bearing
# artifact -- written after the account, Node, and the agent package all succeed -- so
# its presence means provisioning finished. Gate before dispatch so a broken install stops
# here, not mid-operation in a root helper. -L avoids dereferencing the 700 package dir the
# operator cannot traverse. See cli.rule.md (Bootstrap preflight).
require_bootstrap() {
    [[ -L "${CLAUDE_LINK}" ]] && return 0
    die "the sandbox is not provisioned (no ${CLAUDE_LINK}) -- provision it with:" \
        "       sudo ai-tools-bootstrap"
}
require_bootstrap

# ── Dispatch ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --project-claim)   shift; cmd_project_claim   "$@" ;;
    --project-create)  shift; cmd_project_create  "$@" ;;
    --project-unclaim) shift; cmd_project_unclaim "${1:-}" ;;
    --project-remove)  shift; cmd_project_unclaim "${1:-}" ;;
    --sandbox-create) shift; cmd_sandbox_create "${1:-}" ;;
    --sandbox-push)   shift; cmd_sandbox_push   "${1:-}" ;;
    --sandbox-remove) shift; cmd_sandbox_remove "${1:-}" ;;
    --lockdown)       shift; cmd_lockdown "$@" ;;
    --reclaim)        shift; cmd_reclaim "$@" ;;
    --relabel)        shift; cmd_relabel "$@" ;;
    --list)           cmd_list ;;
    --version|-V)     printf 'ai-tools %s\n' "${AI_TOOLS_VERSION}" ;;
    --help|-h|"")     usage ;;
    *) printf 'ai-tools: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
