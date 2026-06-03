#!/usr/bin/env bash
# /usr/local/bin/ai-tools
# Project-lifecycle CLI for the ai-tools Claude Code sandbox. Runs AS the projects
# user (never root, never the sandbox account) and needs no privilege: the two
# registries it edits -- @PROJECTS_HOME@/.config/ai-tools/allowed-projects and the
# git safe.directory list in /opt/ai-tools/.gitconfig -- are both writable by the
# projects user.
#
# Commands (each confirms before applying and reports the result):
#   --project-create [path]   register a real project (default: cwd)
#   --project-remove [path]   unregister a real project (directory left on disk)
#   --sandbox-create [path]   shallow-clone a repo into the sandbox area and
#                             register it; pushes a dedicated branch first
#   --sandbox-push   [path]   push the sandbox clone's commits to its branch
#   --sandbox-remove [path]   remove a sandbox clone and unregister it
#   --list                    list registered projects (real vs sandbox)
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
readonly GITCONFIG="/opt/ai-tools/.gitconfig"
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# Root-only secret lockdown helper. Invoked via sudo (NO NOPASSWD grant exists for
# it -- by design), so sudo prompts for the projects user's password.
readonly LOCKDOWN_BIN="/usr/local/sbin/ai-tools/ai-tools-lockdown"
# Sentinel in a guard CLAUDE.md (see drop_lockdown_guard) so the lockdown step can
# recognise and remove its own placeholder once secrets are secured.
readonly GUARD_MARKER="ai-tools-lockdown-guard"

# ── Invoker guards ───────────────────────────────────────────────────────────────
# This is a user tool. It must run as the projects user: never as root (it would
# write the registries with the wrong owner) and never as the sandbox account
# (the agent must not manage its own allowlist).
ME="$(id -un)"
[[ "${ME}" == "root" ]] \
    && { echo "ai-tools: do not run as root -- run as the projects user" >&2; exit 1; }
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
warn()    { printf '  %s!%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()     { printf 'ai-tools: error: %s\n' "$*" >&2; exit 1; }

# confirm <prompt> [y|n]  -- default decides the Enter answer and the no-tty answer.
# A destructive caller passes 'n' so an unattended/piped run aborts safely.
confirm() {
    local prompt="$1" def="${2:-y}" resp hint
    if [[ "${def}" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf '%s %s ' "${prompt}" "${hint}" > /dev/tty
        read -r resp < /dev/tty || resp=""
    else
        resp=""
    fi
    resp="${resp:-$def}"
    [[ "${resp}" =~ ^[yY] ]]
}

# ask <prompt> <default>  -- echo the chosen value on stdout; prompt to the tty.
ask() {
    local prompt="$1" def="$2" resp
    if [[ -r /dev/tty && -w /dev/tty ]]; then
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

reg_safedir() {
    local dir="$1"
    if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        say "    git safe.directory: already listed"
    else
        git config --file "${GITCONFIG}" --add safe.directory "${dir}"
        say "    git safe.directory: added"
    fi
}

unreg_safedir() {
    local dir="$1" esc
    if git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${dir}"; then
        esc="$(printf '%s' "${dir}" | sed 's/[.^$*+?{|\\[()]/\\&/g')"
        git config --file "${GITCONFIG}" --unset-all safe.directory "^${esc}$" 2>/dev/null || true
        say "    git safe.directory: removed"
    else
        say "    git safe.directory: not listed"
    fi
}

# normalize_clone <dir>  -- make a freshly created clone agent-accessible. The clone
# is born in group SANDBOX_GROUP via the setgid SANDBOX_ROOT, but git creates it
# with the projects user's umask, which may withhold group-write and lock the agent
# out. Add group rwX and the setgid bit on every directory (owner stays the projects
# user); the SessionStart ai-tools-setgid pass keeps it normalized thereafter.
normalize_clone() {
    local d="$1"
    chmod -R g+rwX "${d}"
    find "${d}" -type d -exec chmod g+s {} +
}

# relabel_clone <dir>  -- apply the SELinux project label so the agent (ai_tools_t)
# can read/write the clone. A static fcontext rule in selinux/ai_tools.fc maps every
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

# print_manual_lockdown <dir>  -- tell the user how to lock down <dir> by hand when
# it was not done automatically (sudo missing, declined, or failed).
print_manual_lockdown() {
    local d="$1"
    warn "secrets under this clone are NOT locked down yet"
    say  "    secure it before running the agent (you will be asked for your password):"
    say  "      ${C_BOLD}ai-tools --lockdown ${d}${C_RST}"
    say  "    or directly:"
    say  "      ${C_BOLD}cd ${d} && sudo ai-tools-lockdown${C_RST}"
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

# cmd_project_create [path]  -- register a real project (default: cwd) in
# allowed-projects and git safe.directory, after confirmation.
cmd_project_create() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    [[ -d "${d}" ]] || die "not a directory: ${d}"
    section "Register project"
    say "  ${d}"
    confirm "Register this project (allowed-projects + git safe.directory)?" y \
        || die "aborted"
    reg_allow "${d}"
    reg_safedir "${d}"
    ok "registered ${d}"
}

# cmd_project_remove [path]  -- unregister a real project (default: cwd) from both
# registries; the directory itself is left on disk.
cmd_project_remove() {
    local d; d="$(resolve_dir "${1:-$PWD}")"
    section "Unregister project"
    say "  ${d}"
    say "  ${C_DIM}(the directory itself is left on disk)${C_RST}"
    confirm "Unregister this project?" n || die "aborted"
    unreg_allow "${d}"
    unreg_safedir "${d}"
    ok "unregistered ${d}"
}

# cmd_sandbox_create [path]  -- create or reuse the per-repo branch
# ai-tools/sandbox-<user>/<leaf>, shallow-clone it into SANDBOX_ROOT, normalize and
# relabel the clone for agent access, register it, then lock down tip-commit secrets
# (or drop a guard CLAUDE.md when lockdown is skipped).
cmd_sandbox_create() {
    local src; src="$(resolve_dir "${1:-$PWD}")"
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

    section "Create sandbox project"
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
    [[ -e "${dst}" ]] && die "destination already exists: ${dst}"
    [[ -d "${SANDBOX_ROOT}" ]] || die "sandbox area missing: ${SANDBOX_ROOT} -- run install first"

    # If the branch already exists on the remote (a prior sandbox of this repo),
    # reuse it rather than force-pushing over it -- this resumes earlier work and
    # never discards commits. To reset it, delete the remote branch or pick a new leaf.
    local br_exists=false
    [[ -n "$(git -C "${top}" ls-remote --heads "${remote}" "${br}" 2>/dev/null)" ]] \
        && br_exists=true

    say ""
    say "Will:"
    if ${br_exists}; then
        say "  1. ${C_YEL}reuse existing remote branch${C_RST} ${C_BOLD}${br}${C_RST} (your current ${cur} is NOT pushed over it)"
    else
        say "  1. create branch ${C_BOLD}${br}${C_RST} from ${cur} and push it to ${remote}"
    fi
    say "  2. shallow-clone that branch into ${C_BOLD}${dst}${C_RST}"
    say "  3. register ${dst} (allowed-projects + git safe.directory)"
    confirm "Proceed?" y || die "aborted"

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
    git clone --depth=1 -b "${br}" "${clone_url}" "${dst}"
    ok "shallow-cloned into ${dst}"

    normalize_clone "${dst}"
    ok "normalized clone for agent access (group ${SANDBOX_GROUP}, group-writable, setgid dirs)"

    relabel_clone "${dst}"

    reg_allow "${dst}"
    reg_safedir "${dst}"
    ok "registered ${dst}"

    # A shallow clone drops the history but keeps the tip commit, which may carry
    # checked-in credential files the agent could read. Lock them down now; if we
    # cannot (no sudo, declined, or it failed), drop a guard CLAUDE.md so the agent
    # does nothing until the user runs lockdown by hand.
    section "Secure tip-commit secrets"
    say "  The tip commit may contain credential files (${C_DIM}appsettings.json, .env, *.key${C_RST})"
    say "  the agent could read. Lock them down before running the agent."

    local locked=false
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- cannot lock down automatically"
        drop_lockdown_guard "${dst}"
        print_manual_lockdown "${dst}"
    elif confirm "Run lockdown now (sudo will prompt for your password)?" y; then
        if run_lockdown "${dst}"; then
            locked=true
            ok "secrets locked down in ${dst}"
        else
            warn "lockdown did not complete"
            drop_lockdown_guard "${dst}"
            print_manual_lockdown "${dst}"
        fi
    else
        drop_lockdown_guard "${dst}"
        print_manual_lockdown "${dst}"
    fi

    section "Next"
    say "  run the agent  : ${C_BOLD}cd ${dst} && claude${C_RST}"
    say "  push its work  : ${C_BOLD}ai-tools --sandbox-push ${dst}${C_RST}"
    say "  ${C_YEL}shallow${C_RST}        : push-only -- never git pull/fetch here, or you pull the full history"
    ${locked} || say "  ${C_YEL}secrets${C_RST}        : NOT locked down -- run ${C_BOLD}ai-tools --lockdown ${dst}${C_RST}"
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
            *)            [[ -z "${d}" ]] && d="${a}" || die "--lockdown takes a single path" ;;
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
    warn "this needs root; sudo will prompt for your password"
    if run_lockdown "${d}" "${passthru[@]}"; then
        ${dry} || clear_lockdown_guard "${d}"
        ok "lockdown done: ${d}"
    else
        die "lockdown failed for ${d}"
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

usage() {
    cat <<EOF
ai-tools -- manage Claude Code sandbox projects (run as the projects user)

  ai-tools --project-create [path]   register a real project (default: cwd)
  ai-tools --project-remove [path]   unregister a real project
  ai-tools --sandbox-create [path]   shallow-clone a repo into the sandbox area
  ai-tools --sandbox-push   [path]   push the sandbox clone's commits to its branch
  ai-tools --sandbox-remove [path]   remove a sandbox clone and unregister it
  ai-tools --lockdown [path] [-n|-y] lock down secret files (sudo; default: cwd)
  ai-tools --list                    list registered projects
  ai-tools --help

  --lockdown options: -n/--dry-run (preview only), -y/--yes (skip confirmation)

Sandbox workflow: /var/opt/ai-tools/README.md
EOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --project-create) shift; cmd_project_create "${1:-}" ;;
    --project-remove) shift; cmd_project_remove "${1:-}" ;;
    --sandbox-create) shift; cmd_sandbox_create "${1:-}" ;;
    --sandbox-push)   shift; cmd_sandbox_push   "${1:-}" ;;
    --sandbox-remove) shift; cmd_sandbox_remove "${1:-}" ;;
    --lockdown)       shift; cmd_lockdown "$@" ;;
    --list)           cmd_list ;;
    --help|-h|"")     usage ;;
    *) printf 'ai-tools: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
