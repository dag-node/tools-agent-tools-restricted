#!/usr/bin/env bash
# test.sh -- verify the ai-tools Claude Code sandbox installation
#
# Tests security boundaries (what should be blocked) and verifies that installed
# files have the correct ownership and permissions. Makes no permanent changes.
#
# Usage: sudo ./test.sh

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }

PROJECTS_USER="${SUDO_USER:?error: invoke via sudo, not as root directly}"
PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" | cut -d: -f6)"
PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}")"
PROJECTS_UID="$(id -u "${PROJECTS_USER}")"
readonly SANDBOX_USER="ai-tools"
readonly SANDBOX_GROUP="ai-tools"

# ── Harness ───────────────────────────────────────────────────────────────────

declare -i _pass=0 _fail=0 _skip=0

pass() { printf '  PASS  %s\n' "$*";                         _pass=$(( _pass + 1 )); }
fail() { printf '  FAIL  %s\n' "$*" >&2;                     _fail=$(( _fail + 1 )); }
skip() { printf '  SKIP  %s  (%s)\n' "$1" "$2";              _skip=$(( _skip + 1 )); }
section() { printf '\n── %s\n' "$*"; }

# perm <path>  -- the rwx permission bits only (masks setgid/setuid/sticky). Scratch
# dirs created under a claimed project root inherit its setgid bit, and GNU coreutils
# `chmod` with an octal mode does NOT clear setgid on a directory, so assertions on the
# plain mode must compare the low 3 octal digits, not the raw `stat %a`.
perm() { local m; m="$(stat -c '%a' "$1" 2>/dev/null)"; printf '%o' "$(( 8#${m:-0} & 8#777 ))"; }

# Temporary files/dirs to remove on exit
declare -a _cleanup=()
cleanup() { for f in "${_cleanup[@]+"${_cleanup[@]}"}"; do rm -rf "${f}"; done; }
trap cleanup EXIT

# Invoke the deployed validator the way the hook does: detached from any
# controlling tty (setsid) with stdin from /dev/null, so it takes its
# non-interactive apply branch instead of prompting on /dev/tty.
run_chown() { setsid /usr/local/sbin/ai-tools/ai-tools-chown "$1" < /dev/null > /dev/null 2>&1 || true; }

# ── File permission checks ────────────────────────────────────────────────────

# check_file <path> <owner> <group> <mode>: PASS when the file's actual owner,
# group, and octal mode all match; FAIL (with the mismatch) otherwise, or when absent.
check_file() {
    local file="$1" exp_owner="$2" exp_group="$3" exp_mode="$4"
    if [[ ! -e "${file}" ]]; then
        fail "${file}: MISSING"
        return
    fi
    local act_owner act_group act_mode ok=true
    act_owner="$( stat -c '%U' "${file}")"
    act_group="$(stat -c '%G' "${file}")"
    act_mode="$( stat -c '%a' "${file}")"
    [[ "${act_owner}"  == "${exp_owner}"  ]] || ok=false
    [[ "${act_group}" == "${exp_group}" ]] || ok=false
    [[ "${act_mode}"  == "${exp_mode}"  ]] || ok=false
    if ${ok}; then
        pass "${file}  (${exp_owner}:${exp_group} ${exp_mode})"
    else
        fail "${file}: expected ${exp_owner}:${exp_group} ${exp_mode}, got ${act_owner}:${act_group} ${act_mode}"
    fi
}

section "File permissions"
check_file /usr/local/sbin/ai-tools/ai-tools-chown            root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-setgid           root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-setfacl          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-unclaim          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-claude-symlink   root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-lockdown         root              root              750
# SELinux project-label helper: 750 root:root -- user-run via sudo, never by the
# agent (no SANDBOX_USER grant); same surface as lockdown.
check_file /usr/local/sbin/ai-tools/ai-tools-relabel          root              root              750
# Lib dir: root-owned, group ai-tools, 750 (no world). The agent enters via group
# to read the prune list, but has no write, so it cannot alter the rules.
check_file /usr/local/lib/ai-tools                         root          ai-tools          750
# Secret-pattern matcher: read only by the root helpers, so 640 root:root -- no
# group/world surface. The agent (group ai-tools) cannot read it.
check_file /usr/local/lib/ai-tools/secret-patterns.lib.sh  root          root              640
# Prune-dir list: also sourced by sandbox-sweep (runs as the agent), so 640
# root:ai-tools -- agent reads via group, no world.
check_file /usr/local/lib/ai-tools/prune-dirs.lib.sh       root          ai-tools          640
# Logger library: 644 root:root -- world-readable, sourced by the root helpers, the
# hooks (run as ai-tools), and the CLI (run as the projects user, not in ai-tools).
check_file /usr/local/lib/ai-tools/log.lib.sh             root          root              644
# Project-label library: 640 root:root -- read only by root principals (the
# ai-tools-relabel helper and install-selinux.sh). No group/world surface; the
# unprivileged CLI inlines its read-only label check instead of sourcing it.
check_file /usr/local/lib/ai-tools/relabel.lib.sh         root          root              640
# Secret-pattern config: user-owned 600. ai-tools (not owner/group, cannot enter
# the 700 .config/ai-tools dir) can neither read nor write it; root helpers read it.
check_file "${PROJECTS_HOME}/.config/ai-tools/secret-patterns" "${PROJECTS_USER}"  "${PROJECTS_GROUP}"  600
check_file /etc/sudoers.d/ai-tools-claude             root              root              440
check_file /etc/profile.d/path_dedup.sh               root              root              644
# /opt/ai-tools/bin is locked: owned by the projects user (NOT ai-tools), 550, so
# ai-tools has group r-x but no write. The agent can execute nvm-update.sh and
# resolve the claude symlink, but cannot edit the updater or swap the symlink --
# only root (via ai-tools-claude-symlink) writes here.
check_file /opt/ai-tools/bin                          "${PROJECTS_USER}"    ai-tools          550
# Control-plane files: owned by the projects user, group ai-tools. The agent
# (running as ai-tools) gets group read/exec but no write, so it cannot rewrite
# its own updater, hook, or hook config.
check_file /opt/ai-tools/bin/nvm-update.sh            "${PROJECTS_USER}"    ai-tools          550
check_file /opt/ai-tools/.claude/post-tool-hook.sh   "${PROJECTS_USER}"    ai-tools          750
check_file /opt/ai-tools/.claude/session-hook.sh  "${PROJECTS_USER}"    ai-tools          750
check_file /opt/ai-tools/.claude/settings.json        "${PROJECTS_USER}"    ai-tools          640
# .claude must be install-user-owned (not ai-tools) with setgid+sticky (3770):
# ai-tools is a group-writer for its own state but cannot unlink/replace the
# install-user-owned control files above. Owned by ai-tools, or without the
# sticky bit, the agent could delete and recreate them.
check_file /opt/ai-tools/.claude                      "${PROJECTS_USER}"    ai-tools          3770
check_file "${PROJECTS_HOME}/.local/bin/claude"            "${PROJECTS_USER}"    "${PROJECTS_GROUP}"   750
check_file "${PROJECTS_HOME}/.local/bin/nvm-update.sh"     "${PROJECTS_USER}"    "${PROJECTS_GROUP}"   750
check_file "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service" \
                                                       "${PROJECTS_USER}"    "${PROJECTS_GROUP}"   640
check_file "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer" \
                                                       "${PROJECTS_USER}"    "${PROJECTS_GROUP}"   640

# ── Sudoers syntax ────────────────────────────────────────────────────────────

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools-claude > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools-claude parses OK"
else
    fail "/etc/sudoers.d/ai-tools-claude has syntax errors"
fi

# ── Wrapper allowlist guard ───────────────────────────────────────────────────

section "Wrapper allowlist guard"

if [[ ! -x "${PROJECTS_HOME}/.local/bin/claude" ]]; then
    skip "wrapper guard" "claude wrapper not found at ${PROJECTS_HOME}/.local/bin/claude"
else
    tmpdir="$(mktemp -d)"
    _cleanup+=("${tmpdir}")

    # Run wrapper from a directory that is not in the approved list. setsid detaches the
    # controlling tty so the wrapper's "claim it now?" prompt finds no /dev/tty and takes
    # its default (no claim) -- otherwise an interactive run would let the operator claim
    # the temp dir mid-test. (The wrapper reads /dev/tty, not stdin, so </dev/null alone
    # is not enough; setsid is what makes this non-interactive.)
    output="$(cd "${tmpdir}" && setsid sudo -u "${PROJECTS_USER}" HOME="${PROJECTS_HOME}" \
        "${PROJECTS_HOME}/.local/bin/claude" --version < /dev/null 2>&1 || true)"

    if printf '%s' "${output}" | grep -qE "approved projects list|allowlist not found"; then
        pass "wrapper blocks execution from unapproved directory"
    else
        fail "wrapper did NOT block unapproved directory (output: ${output})"
    fi

    # Verify wrapper allows execution from approved project directory
    output2="$(cd "${SCRIPT_DIR}" && setsid sudo -u "${PROJECTS_USER}" HOME="${PROJECTS_HOME}" \
        "${PROJECTS_HOME}/.local/bin/claude" --version < /dev/null 2>&1 || true)"
    if ! printf '%s' "${output2}" | grep -qE "approved projects list|allowlist not found"; then
        pass "wrapper allows execution from approved project directory"
    else
        fail "wrapper incorrectly blocked approved directory (output: ${output2})"
    fi
fi

# ── Wrapper symlink check (unreadable final target) ───────────────────────────
#
# Pins the wrapper's link-existence check to `[[ -L ]]`, not `[[ -e ]]`. `[[ -e ]]`
# dereferences the FULL chain (bin/claude -> versioned bin/claude ->
# .../claude-code/bin/claude.exe); claude.exe lives in the package dir (mode 700,
# ai-tools), so the invoking user cannot stat the final target (EACCES) and -e
# reports a valid link as missing. `[[ -L ]]` tests the link itself and does not
# traverse past the first hop.

section "Wrapper symlink check (unreadable final target)"

wrapper="${PROJECTS_HOME}/.local/bin/claude"

# (A) Reproduce the hazard hermetically: a symlink chain whose final target sits
#     behind a dir the invoking user cannot enter. -L must still see the link
#     even though -e cannot stat through to the target.
fx="$(mktemp -d)"
_cleanup+=("${fx}")
chmod 755 "${fx}"                                 # let PROJECTS_USER traverse to the link
mkdir "${fx}/pkg"
chmod 700 "${fx}/pkg"                             # root-owned 700: blocks the final stat
: > "${fx}/pkg/claude.exe"
ln -s "${fx}/pkg/claude.exe" "${fx}/versioned"    # npm symlink analogue
ln -s "${fx}/versioned"      "${fx}/link"         # stable link -> versioned -> pkg/claude.exe

l_ok=false; e_ok=false
sudo -u "${PROJECTS_USER}" test -L "${fx}/link" && l_ok=true
sudo -u "${PROJECTS_USER}" test -e "${fx}/link" && e_ok=true

if ${l_ok} && ! ${e_ok}; then
    pass "symlink with unreadable target: -L detects it, -e does not"
elif ! ${l_ok}; then
    fail "fixture broken: -L failed to detect the symlink as ${PROJECTS_USER}"
else
    skip "hazard demo" "final target is readable to ${PROJECTS_USER}; EACCES path not exercised"
fi

# (B) Pin the deployed wrapper to -L: a revert to -e reintroduces the bug.
if [[ -r "${wrapper}" ]]; then
    if grep -Eq '!\s*-L\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
        pass "wrapper guards CLAUDE_LINK with -L"
    elif grep -Eq '!\s*-e\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
        fail "wrapper uses -e on CLAUDE_LINK -- reintroduces false 'symlink not found' bug"
    else
        fail "wrapper has no recognisable CLAUDE_LINK existence guard"
    fi
else
    skip "wrapper -L guard" "cannot read ${wrapper}"
fi

# (C) End-to-end: the real wrapper, run as the user against the real
#     /opt/ai-tools/bin/claude (whose final target IS unreadable to the user),
#     must not falsely report the link missing.
if [[ -x "${wrapper}" && -L /opt/ai-tools/bin/claude ]]; then
    out="$(cd "${SCRIPT_DIR}" && sudo -u "${PROJECTS_USER}" HOME="${PROJECTS_HOME}" \
        "${wrapper}" --version 2>&1 || true)"
    if printf '%s' "${out}" | grep -q "symlink not found"; then
        fail "wrapper falsely reports symlink missing (output: ${out})"
    else
        pass "wrapper does not falsely report symlink missing"
    fi
else
    skip "wrapper symlink integration" "wrapper not installed or /opt/ai-tools/bin/claude is not a symlink"
fi

# ── PostToolUse hook: ownership hand-back end-to-end ──────────────────────────
#
# Pins the hook's invariant: it MUST NOT pre-check the allowlist with
# `[[ -f "${ALLOWLIST}" ]]`. The allowlist lives under the projects user's
# ~/.config (mode 700), which ai-tools cannot traverse, so that test is always
# false and disables the hook (files stay ai-tools:ai-tools, not handed back).
# Allowlist enforcement belongs to ai-tools-chown, which runs as root and reads
# it.
#
# These exercise the hook the way Claude Code does: JSON on stdin, run as
# ai-tools, detached from the controlling tty via setsid so ai-tools-chown takes
# its non-interactive branch (otherwise it would prompt on /dev/tty mid-suite).

section "PostToolUse hook: ownership hand-back end-to-end"

hook="/opt/ai-tools/.claude/post-tool-hook.sh"

run_hook() {
    printf '{"tool_input":{"file_path":"%s"}}' "$1" \
        | timeout 15 setsid sudo -u ai-tools -g ai-tools "${hook}" \
            > /dev/null 2>&1 || true
}

if [[ ! -x "${hook}" ]]; then
    skip "hook end-to-end" "hook not installed at ${hook}"
else
    # (A) An ai-tools-owned file in this approved project must be handed back.
    hk="${SCRIPT_DIR}/.test_hook_$$"
    : > "${hk}"; chown ai-tools:ai-tools "${hk}"; chmod 0600 "${hk}"
    _cleanup+=("${hk}")
    run_hook "${hk}"
    if [[ "$(stat -c '%U:%G' "${hk}")" == "${PROJECTS_USER}:ai-tools" ]]; then
        pass "hook hands ai-tools-owned file back to ${PROJECTS_USER}:ai-tools"
    else
        fail "hook did not hand back ${hk}: $(stat -c '%U:%G' "${hk}") (want ${PROJECTS_USER}:ai-tools)"
    fi

    # (B) A secret-named file routed through the hook reaches ai-tools-chown's
    #     secret path: chowned to the user's private group (PROJECTS_USER:PROJECTS_GROUP
    #     600), revoking ai-tools access.
    hs="${SCRIPT_DIR}/.env.test_hook_$$"
    : > "${hs}"; chown ai-tools:ai-tools "${hs}"; chmod 0600 "${hs}"
    _cleanup+=("${hs}")
    run_hook "${hs}"
    if [[ "$(stat -c '%U:%G' "${hs}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
        pass "hook routes secret-named file to ${PROJECTS_USER}:${PROJECTS_GROUP} (ai-tools access revoked)"
    else
        fail "secret-named file ended $(stat -c '%U:%G' "${hs}") (want ${PROJECTS_USER}:${PROJECTS_GROUP})"
    fi

    # (C) A directory the write newly created is handed back too. The hook walks
    #     up from the written file's dir, handing back each ai-tools-owned
    #     ancestor and stopping at the pre-existing (PROJECTS_USER-owned) tree. Here
    #     the new dir's parent is the project root (PROJECTS_USER-owned), so exactly
    #     the new dir is normalized -- to PROJECTS_USER:ai-tools, world bits stripped.
    hd="${SCRIPT_DIR}/.test_hookdir_$$"
    mkdir "${hd}"; chown ai-tools:ai-tools "${hd}"; chmod 0755 "${hd}"
    hdf="${hd}/file"
    : > "${hdf}"; chown ai-tools:ai-tools "${hdf}"; chmod 0600 "${hdf}"
    _cleanup+=("${hd}")
    run_hook "${hdf}"
    if [[ "$(stat -c '%U:%G' "${hd}")" == "${PROJECTS_USER}:ai-tools" && "$(perm "${hd}")" == "770" ]]; then
        pass "hook normalizes a newly-created parent dir to ${PROJECTS_USER}:ai-tools 770"
    else
        fail "hook did not normalize new dir ${hd}: $(stat -c '%U:%G' "${hd}") $(stat -c '%a' "${hd}") (want ${PROJECTS_USER}:ai-tools 770)"
    fi

    # (D) Static pin: an allowlist pre-check in code (which ai-tools cannot
    #     satisfy) disables hand-back, so the hook keeps no ALLOWLIST in code --
    #     enforcement belongs to root-side ai-tools-chown. Comment lines are
    #     stripped first so the rationale comment (which names ALLOWLIST) does not
    #     trip the guard.
    if grep -vE '^[[:space:]]*#' "${hook}" | grep -q 'ALLOWLIST'; then
        fail "hook has a non-comment ALLOWLIST reference -- the silently-disabling pre-check may be back"
    else
        pass "hook code has no ALLOWLIST pre-check (delegates enforcement to ai-tools-chown)"
    fi
fi

# ── Stop hook: turn-end sweep of Bash-created files ──────────────────────────
#
# The Stop sweep catches files the precise Write|Edit hook cannot: those created
# via the Bash tool (no file_path). It reads .cwd from the hook JSON, finds
# ai-tools-owned paths under it, and hands each to ai-tools-chown. Run as ai-tools
# (as Claude runs it), detached via setsid so the inner sudo ai-tools-chown takes
# its non-interactive branch.

section "Stop hook: turn-end sweep of Bash-created files"

sweep="/opt/ai-tools/.claude/session-hook.sh"

run_sweep() {
    printf '{"cwd":"%s"}' "$1" \
        | timeout 30 setsid sudo -u ai-tools -g ai-tools "${sweep}" \
            > /dev/null 2>&1 || true
}

if [[ ! -x "${sweep}" ]]; then
    skip "stop sweep" "not installed at ${sweep}"
else
    # Force a full scan (no marker) so the freshly-created file is found
    # deterministically regardless of prior sweep state.
    rm -f /opt/ai-tools/.claude/.sweep-marker 2>/dev/null || true
    sw="${SCRIPT_DIR}/.test_sweep_$$"
    : > "${sw}"; chown ai-tools:ai-tools "${sw}"; chmod 0644 "${sw}"
    _cleanup+=("${sw}")
    run_sweep "${SCRIPT_DIR}"
    if [[ "$(stat -c '%U:%G' "${sw}")" == "${PROJECTS_USER}:ai-tools" ]]; then
        pass "Stop sweep hands back a Bash-created (ai-tools-owned) file"
    else
        fail "Stop sweep did not hand back ${sw}: $(stat -c '%U:%G' "${sw}") (want ${PROJECTS_USER}:ai-tools)"
    fi
fi

# ── SessionStart hook: unbounded reclaim of interrupted-session leftovers ────
#
# Same script as the Stop sweep, invoked with the "session-start" argument. It is
# UNBOUNDED (ignores .sweep-marker) so it reclaims an ai-tools-owned file left by a
# session that was killed before its Stop sweep ran -- even one OLDER than the
# marker, which the bounded Stop pass would skip. The unbounded pass is gated on
# the hook's .source: startup/resume trigger it; clear/compact are a no-op (the
# live process's Stop sweeps already cover the tree).

section "SessionStart hook: unbounded reclaim of interrupted-session leftovers"

if [[ ! -x "${sweep}" ]]; then
    skip "session-start sweep" "not installed at ${sweep}"
else
    run_sweep_ss() {  # $1=cwd  $2=source
        printf '{"cwd":"%s","source":"%s"}' "$1" "$2" \
            | timeout 30 setsid sudo -u ai-tools -g ai-tools "${sweep}" session-start \
                > /dev/null 2>&1 || true
    }

    # (A) Unbounded: a marker NEWER than the leftover must NOT stop the reclaim.
    #     Stamp the marker to "now" first, then create the file older than it so a
    #     bounded (-newer) pass would skip it -- only an unbounded pass reclaims it.
    : > /opt/ai-tools/.claude/.sweep-marker 2>/dev/null || true
    sleep 1
    ssf="${SCRIPT_DIR}/.test_ss_$$"
    : > "${ssf}"; chown ai-tools:ai-tools "${ssf}"; chmod 0644 "${ssf}"
    touch -d '1 hour ago' "${ssf}"            # older than the marker
    _cleanup+=("${ssf}")
    run_sweep_ss "${SCRIPT_DIR}" startup
    if [[ "$(stat -c '%U:%G' "${ssf}")" == "${PROJECTS_USER}:ai-tools" ]]; then
        pass "SessionStart (startup) reclaims a leftover older than the marker (unbounded)"
    else
        fail "SessionStart did not reclaim ${ssf}: $(stat -c '%U:%G' "${ssf}") (want ${PROJECTS_USER}:ai-tools)"
    fi

    # (B) Source gating: compact/clear stay within a live process, so the pass is a
    #     no-op -- a fresh ai-tools-owned file is left for the Stop sweep to handle.
    ssf2="${SCRIPT_DIR}/.test_ss2_$$"
    : > "${ssf2}"; chown ai-tools:ai-tools "${ssf2}"; chmod 0644 "${ssf2}"
    _cleanup+=("${ssf2}")
    run_sweep_ss "${SCRIPT_DIR}" compact
    if [[ "$(stat -c '%U:%G' "${ssf2}")" == "ai-tools:ai-tools" ]]; then
        pass "SessionStart (compact) is a no-op (leaves live-session writes to Stop)"
    else
        fail "SessionStart (compact) unexpectedly changed ${ssf2}: $(stat -c '%U:%G' "${ssf2}")"
    fi
fi

# ── ai-tools-claude-symlink: validation + idempotent repoint ─────────────────
#
# The root helper is the only writer of the locked /opt/ai-tools/bin. It must
# repoint the stable symlink ONLY at a path matching the versioned claude shape
# (it cannot trust the sudoers glob, whose argument wildcard can match '/'), and
# must refuse anything else. Refusal cases below touch nothing; the happy-path
# case repoints to the symlink's CURRENT target, so it is idempotent.

section "ai-tools-claude-symlink: validation + idempotent repoint"

helper="/usr/local/sbin/ai-tools/ai-tools-claude-symlink"
if [[ ! -x "${helper}" ]]; then
    skip "symlink helper" "not installed at ${helper}"
else
    # (A) Refuse paths outside the versioned-claude shape (no write, exit != 0).
    for bogus in \
        "/etc/passwd" \
        "/opt/ai-tools/.nvm/versions/node/v22.0.0/../../../../bin/sh" \
        "/opt/ai-tools/.nvm/versions/node/v22.0.0/bin/node"
    do
        if "${helper}" "${bogus}" >/dev/null 2>&1; then
            fail "helper accepted a non-versioned-claude target: ${bogus}"
        else
            pass "helper refuses non-versioned-claude target: ${bogus}"
        fi
    done

    # (B) Refuse a correctly-shaped but non-existent version.
    if "${helper}" "/opt/ai-tools/.nvm/versions/node/v0.0.0/bin/claude" >/dev/null 2>&1; then
        fail "helper accepted a versioned path that does not exist (v0.0.0)"
    else
        pass "helper refuses a versioned path that does not exist"
    fi

    # (C) Idempotent happy path: repoint to the link's current versioned target.
    cur="$(readlink /opt/ai-tools/bin/claude 2>/dev/null || true)"
    if [[ "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ && -e "${cur}" ]]; then
        if "${helper}" "${cur}" >/dev/null 2>&1 \
           && [[ "$(readlink /opt/ai-tools/bin/claude)" == "${cur}" ]]; then
            pass "helper repoints the symlink at a valid versioned target (idempotent)"
        else
            fail "helper failed to repoint the symlink at its current valid target ${cur}"
        fi
    else
        skip "helper happy path" "current symlink target is not a resolvable versioned claude path"
    fi
fi

# ── Sandbox access boundaries ─────────────────────────────────────────────────
#
# Probes what the ai-tools process can and cannot actually reach at runtime.
# Each check names the threat that the boundary prevents. "can" checks confirm
# intended access that the sandbox requires to function; "cannot" checks confirm
# that control-plane integrity and secret isolation hold.
#
# Uses runuser to drop to ai-tools without sudoers (root → ai-tools, clean).
# Uses test -r/-w/-x for non-destructive permission probes; uses a DECOY file
# (owned by PROJECTS_USER in the sticky .claude dir) for unlink-attempt tests
# so the real control-plane files are never at risk.

section "Sandbox access boundaries"

if ! command -v runuser >/dev/null; then
    skip "sandbox access boundaries" "runuser not available"
else

    # ── Config dir traversal ─────────────────────────────────────────────────
    #
    # The allowlist (allowed-projects) and secret-pattern config live under
    # ~/.config/ai-tools (700 PROJECTS_USER:PROJECTS_GROUP). If the agent could
    # traverse this dir, it could read the allowlist to understand scope limits,
    # read secret-patterns to learn what triggers quarantine, and potentially
    # write forged entries -- all via ordinary file I/O, without any sudo call.

    confdir="${PROJECTS_HOME}/.config/ai-tools"
    if ! runuser -u ai-tools -- test -x "${confdir}" 2>/dev/null; then
        pass "cannot traverse ${confdir} (700 ${PROJECTS_USER}:${PROJECTS_GROUP}): allowlist + secret config unreachable to agent"
    else
        fail "can traverse ${confdir} -- agent could read/tamper with the allowlist or secret-pattern config"
    fi

    # ── Secret-pattern library ───────────────────────────────────────────────
    #
    # secret-patterns.lib.sh (640 root:root) defines what filenames trigger
    # quarantine. The lib dir (750 root:ai-tools) is traversable by the agent,
    # but the file's group is root, not ai-tools -- so traversal access does not
    # imply read access. If readable, the agent could inspect and selectively
    # route secrets through a name not in the list.

    splib=/usr/local/lib/ai-tools/secret-patterns.lib.sh
    if ! runuser -u ai-tools -- test -r "${splib}" 2>/dev/null; then
        pass "cannot read ${splib} (640 root:root): secret classifier is opaque to the agent"
    else
        fail "can read ${splib} -- agent can inspect the secret-pattern matcher and avoid triggering it"
    fi

    # ── Prune-dir library (intended read) ────────────────────────────────────
    #
    # prune-dirs.lib.sh (640 root:ai-tools) is sourced by session-hook.sh while
    # it runs AS the agent. Group read on this file is intentional and required;
    # the content (a list of directory names to prune) is not sensitive.

    pdlib=/usr/local/lib/ai-tools/prune-dirs.lib.sh
    if runuser -u ai-tools -- test -r "${pdlib}" 2>/dev/null; then
        pass "can read ${pdlib} (640 root:ai-tools): required by session-hook.sh at runtime"
    else
        fail "cannot read ${pdlib} -- session-hook.sh will fail to source the prune list"
    fi

    # ── sbin helper directory listing ────────────────────────────────────────
    #
    # /usr/local/sbin/ai-tools (750 root:root) holds the root helpers.
    # Listing the directory lets the agent enumerate helper names and probe for
    # discrepancies between what is on disk and what sudoers authorises.

    sbindir=/usr/local/sbin/ai-tools
    if ! runuser -u ai-tools -- test -r "${sbindir}" 2>/dev/null; then
        pass "cannot list ${sbindir} (750 root:root): helper names not enumerable by agent"
    else
        fail "can list ${sbindir} -- agent can enumerate root helper names"
    fi

    # ── settings.json: no write ──────────────────────────────────────────────
    #
    # settings.json (640 PROJECTS_USER:ai-tools) declares the PostToolUse,
    # Stop, and SessionStart hooks, and the permissions.allow / .deny lists.
    # If the agent could write it, it could add entries to permissions.allow
    # (silently expanding the tool set it can use), remove entries from
    # permissions.deny (re-enabling blocked operations), or remove hooks
    # entirely (disabling hand-back and secret quarantine) -- all without
    # any external observable signal.

    sf=/opt/ai-tools/.claude/settings.json
    if ! runuser -u ai-tools -- test -w "${sf}" 2>/dev/null; then
        pass "cannot write ${sf} (640 no group-write): agent cannot extend its own allowed tool scope"
    else
        fail "can write ${sf} -- agent could add permissions.allow rules, remove deny rules, or drop hooks"
    fi

    # ── settings.json / hooks: no unlink (sticky) ────────────────────────────
    #
    # Even if write access to a file is blocked, a process with group write
    # access to the DIRECTORY could unlink the file and create a replacement.
    # The sticky bit on .claude (3770 PROJECTS_USER:ai-tools) prevents that:
    # you can only unlink a file if you own it OR own the directory. The agent
    # owns neither settings.json nor the .claude dir (both owned by PROJECTS_USER).
    # Test with a decoy file (same ownership, same dir) so the real files are safe.

    _decoy=""
    _decoy="$(mktemp /opt/ai-tools/.claude/.test_sticky_XXXXXX)"
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${_decoy}"
    chmod 640 "${_decoy}"
    _cleanup+=("${_decoy}")
    runuser -u ai-tools -- rm -f "${_decoy}" 2>/dev/null || true
    if [[ -e "${_decoy}" ]]; then
        pass "sticky .claude: agent cannot unlink ${PROJECTS_USER}-owned files (replacement attack blocked)"
    else
        fail "sticky .claude FAILED: agent deleted a ${PROJECTS_USER}-owned file -- settings.json and hooks can be replaced"
    fi

    # ── post-tool-hook.sh: no write ──────────────────────────────────────────
    #
    # post-tool-hook.sh (750 PROJECTS_USER:ai-tools) is invoked by Claude Code
    # after every Write/Edit. If the agent could overwrite it with an empty
    # script, all subsequent file writes in the session would skip hand-back and
    # secret quarantine until the session ends or the hook is reinstalled.

    hook=/opt/ai-tools/.claude/post-tool-hook.sh
    if ! runuser -u ai-tools -- test -w "${hook}" 2>/dev/null; then
        pass "cannot write ${hook} (750 no group-write): hand-back and quarantine hooks protected"
    else
        fail "can write ${hook} -- agent could empty the hook and disable hand-back / secret quarantine"
    fi

    # ── session-hook.sh: no write ────────────────────────────────────────────
    #
    # session-hook.sh (750 PROJECTS_USER:ai-tools) runs the Stop sweep (catches
    # Bash-tool files) and the SessionStart reclaim. If the agent could overwrite
    # it, it could disable the sweep -- leaving ai-tools-owned files permanently
    # in the project tree and skipping the setgid normalisation that keeps shared-
    # group collaboration working.

    shook=/opt/ai-tools/.claude/session-hook.sh
    if ! runuser -u ai-tools -- test -w "${shook}" 2>/dev/null; then
        pass "cannot write ${shook} (750 no group-write): stop-sweep and session-start protected"
    else
        fail "can write ${shook} -- agent could disable the stop-sweep or session-start reclaim"
    fi

    # ── nvm-update.sh: no write ──────────────────────────────────────────────
    #
    # /opt/ai-tools/bin/nvm-update.sh (550 PROJECTS_USER:ai-tools) is run by
    # the daily systemd timer AS the projects user (with the user's environment).
    # If the agent could inject into it, arbitrary commands would execute in the
    # projects user's context the next time the timer fires -- persistent privilege
    # that outlasts the current session.

    updater=/opt/ai-tools/bin/nvm-update.sh
    if ! runuser -u ai-tools -- test -w "${updater}" 2>/dev/null; then
        pass "cannot write ${updater} (550 no group-write): scheduled updater protected from code injection"
    else
        fail "can write ${updater} -- agent could inject commands run as ${PROJECTS_USER} by the daily timer"
    fi

    # ── Hooks: intended exec (must be reachable) ─────────────────────────────
    #
    # Claude Code launches hooks by path. If the agent cannot execute them, the
    # hook silently fails to fire and the entire hand-back / quarantine system
    # stops working -- no error, no warning, just no enforcement.

    if runuser -u ai-tools -- test -x "${hook}" 2>/dev/null; then
        pass "can execute ${hook} (750 group-exec): PostToolUse hook will fire"
    else
        fail "cannot execute ${hook} -- hook will be silently skipped by Claude Code"
    fi

    if runuser -u ai-tools -- test -x "${shook}" 2>/dev/null; then
        pass "can execute ${shook} (750 group-exec): Stop and SessionStart hooks will fire"
    else
        fail "cannot execute ${shook} -- stop-sweep / session-start silently skipped"
    fi

fi

# ── Systemd timer ─────────────────────────────────────────────────────────────

section "Systemd"

if sudo -u "${PROJECTS_USER}" \
    XDG_RUNTIME_DIR="/run/user/${PROJECTS_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PROJECTS_UID}/bus" \
    systemctl --user is-active nvm-update.timer > /dev/null 2>&1; then
    pass "nvm-update.timer is active"
else
    fail "nvm-update.timer is not active -- run: systemctl --user start nvm-update.timer"
fi

section "Handback bridge + entrypoint (regression guards)"

# (1) claude.exe must carry ai_tools_exec_t, or the unconfined_t/init_t -> ai_tools_t
# transition never fires and claude-run's preflight refuses to launch. It is a HARD LINK
# to the platform-package ELF, so a bulk restorecon can demote the shared inode to lib_t;
# install-selinux.sh's verify_entrypoint relabels it LAST to prevent that. Only meaningful
# when the ai_tools module is installed (matchpathcon resolves the entrypoint type).
_exe="$(ls -1 /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe 2>/dev/null | head -1)"
if [[ -z "${_exe}" ]]; then
    skip "claude.exe entrypoint label" "no claude.exe under the nvm tree"
elif ! command -v matchpathcon >/dev/null 2>&1 || [[ "$(matchpathcon -n "${_exe}" 2>/dev/null)" != *ai_tools_exec_t* ]]; then
    skip "claude.exe entrypoint label" "ai_tools SELinux module not installed"
elif [[ "$(stat -c '%C' "${_exe}" 2>/dev/null)" == *:ai_tools_exec_t:* ]]; then
    pass "claude.exe labelled ai_tools_exec_t (entrypoint transition fires)"
else
    fail "claude.exe is '$(stat -c '%C' "${_exe}" 2>/dev/null)', NOT ai_tools_exec_t -- claude-run will refuse to launch. Fix: install-selinux.sh relabel"
fi

# (2) Handback socket file is 0660 root:SANDBOX_GROUP, and /run/ai-tools is traversable by
# the sandbox user. The systemd-252 RuntimeDirectoryGroup= trap left the dir root:root and
# un-traversable; the fix is RuntimeDirectoryMode=0711 (world --x, contents unlistable).
_sock="/run/ai-tools/handback.sock"
if [[ ! -S "${_sock}" ]]; then
    skip "handback socket DAC" "${_sock} not present (service not started?)"
else
    check_file "${_sock}" root "${SANDBOX_GROUP}" 660
    if command -v runuser >/dev/null 2>&1 && runuser -u "${SANDBOX_USER}" -- test -x /run/ai-tools 2>/dev/null; then
        pass "/run/ai-tools traversable by ${SANDBOX_USER} (can reach the socket)"
    else
        fail "/run/ai-tools NOT traversable by ${SANDBOX_USER} -- RuntimeDirectoryMode regressed? (want 0711)"
    fi
fi

# (3) Deployed socket unit must NOT use RuntimeDirectoryGroup= (unknown key on systemd 252,
# silently ignored -> dir root:root) and MUST set RuntimeDirectoryMode=0711.
_unit="/usr/lib/systemd/system/ai-tools-handback.socket"
if [[ ! -f "${_unit}" ]]; then
    skip "handback socket unit directives" "${_unit} missing"
else
    if grep -qE '^[[:space:]]*RuntimeDirectoryGroup=' "${_unit}"; then
        fail "${_unit}: has RuntimeDirectoryGroup= -- unknown key on systemd 252, dir falls back to root:root. Use RuntimeDirectoryMode=0711"
    else
        pass "socket unit: no invalid RuntimeDirectoryGroup="
    fi
    if grep -qE '^[[:space:]]*RuntimeDirectoryMode=0711[[:space:]]*$' "${_unit}"; then
        pass "socket unit: RuntimeDirectoryMode=0711"
    else
        fail "${_unit}: RuntimeDirectoryMode is not 0711 -- ${SANDBOX_USER} may not traverse /run/ai-tools"
    fi
fi

# (4) Live SYMLINK verb end-to-end, idempotent (repoint to the CURRENT target). Exercises
# the full bridge as ${SANDBOX_USER}: socket reach (0711) + SO_PEERCRED + the daemon's
# getattr on the ai_tools_exec_t entrypoint -- without that grant the helper's [[ -e ]]
# fails closed with "target does not exist". No net change: the target is unchanged.
_client="/usr/local/bin/ai-tools-handback-client"
_tgt="$(readlink /opt/ai-tools/bin/claude 2>/dev/null || true)"
if ! command -v runuser >/dev/null 2>&1; then
    skip "handback SYMLINK verb end-to-end" "runuser unavailable"
elif [[ ! -x "${_client}" || ! -S "${_sock}" ]]; then
    skip "handback SYMLINK verb end-to-end" "client or socket unavailable"
elif [[ -z "${_tgt}" ]]; then
    skip "handback SYMLINK verb end-to-end" "cannot read /opt/ai-tools/bin/claude target"
elif runuser -u "${SANDBOX_USER}" -- "${_client}" SYMLINK "${_tgt}" >/dev/null 2>&1; then
    pass "handback SYMLINK verb OK (socket reach + getattr on entrypoint)"
else
    fail "handback SYMLINK verb FAILED -- check /run/ai-tools (0711) reachable and ai_tools_handback_t getattr on ai_tools_exec_t"
fi

# (5) claude-run pins DISABLE_AUTOUPDATER=1: the node tree is read-only to the agent, so
# the in-session auto-updater would fail every launch (+ AVC). Updates are the timer's job.
_crun="/opt/ai-tools/bin/claude-run"
if [[ ! -r "${_crun}" ]]; then
    skip "claude-run disables auto-updater" "${_crun} unreadable"
elif grep -qE 'setenv=DISABLE_AUTOUPDATER=1' "${_crun}"; then
    pass "claude-run pins DISABLE_AUTOUPDATER=1 (no in-session self-update)"
else
    fail "claude-run does not pin DISABLE_AUTOUPDATER=1 -- agent will attempt the denied npm self-update"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

sep="$(printf '─%.0s' {1..50})"
printf '\n%s\n' "${sep}"
printf 'Tests: %d passed' "${_pass}"
(( _fail > 0 )) && printf ', %d FAILED' "${_fail}"
(( _skip > 0 )) && printf ', %d skipped' "${_skip}"
printf '\n%s\n\n' "${sep}"

(( _fail == 0 ))
