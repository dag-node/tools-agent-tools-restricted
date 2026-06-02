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

# ── Harness ───────────────────────────────────────────────────────────────────

declare -i _pass=0 _fail=0 _skip=0

pass() { printf '  PASS  %s\n' "$*";                         _pass=$(( _pass + 1 )); }
fail() { printf '  FAIL  %s\n' "$*" >&2;                     _fail=$(( _fail + 1 )); }
skip() { printf '  SKIP  %s  (%s)\n' "$1" "$2";              _skip=$(( _skip + 1 )); }
section() { printf '\n── %s\n' "$*"; }

# Temporary files/dirs to remove on exit
declare -a _cleanup=()
cleanup() { for f in "${_cleanup[@]+"${_cleanup[@]}"}"; do rm -rf "${f}"; done; }
trap cleanup EXIT

# Invoke the deployed validator the way the hook does: detached from any
# controlling tty (setsid) with stdin from /dev/null, so it takes its
# non-interactive apply branch instead of prompting on /dev/tty.
run_chown() { setsid /usr/local/sbin/ai-tools/chown "$1" < /dev/null > /dev/null 2>&1 || true; }

# ── File permission checks ────────────────────────────────────────────────────

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
check_file /usr/local/sbin/ai-tools/chown            root              root              750
check_file /usr/local/sbin/ai-tools/setgid           root              root              750
check_file /usr/local/sbin/ai-tools/claude-symlink   root              root              750
check_file /usr/local/sbin/ai-tools/lockdown         root              root              750
# Lib dir: root-owned, group ai-tools, 750 (no world). The agent enters via group
# to read the prune list, but has no write, so it cannot alter the rules.
check_file /usr/local/lib/ai-tools                         root          ai-tools          750
# Secret-pattern matcher: read only by the root helpers, so 640 root:root -- no
# group/world surface. The agent (group ai-tools) cannot read it.
check_file /usr/local/lib/ai-tools/secret-patterns.lib.sh  root          root              640
# Prune-dir list: also sourced by sandbox-sweep (runs as the agent), so 640
# root:ai-tools -- agent reads via group, no world.
check_file /usr/local/lib/ai-tools/prune-dirs.lib.sh       root          ai-tools          640
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
check_file /opt/ai-tools/.claude/sandbox-sweep.sh  "${PROJECTS_USER}"    ai-tools          750
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

    # Run wrapper from a directory that is not in the approved list
    output="$(cd "${tmpdir}" && sudo -u "${PROJECTS_USER}" HOME="${PROJECTS_HOME}" \
        "${PROJECTS_HOME}/.local/bin/claude" --version 2>&1 || true)"

    if printf '%s' "${output}" | grep -qE "not in approved|allowlist not found"; then
        pass "wrapper blocks execution from unapproved directory"
    else
        fail "wrapper did NOT block unapproved directory (output: ${output})"
    fi

    # Verify wrapper allows execution from approved project directory
    output2="$(cd "${SCRIPT_DIR}" && sudo -u "${PROJECTS_USER}" HOME="${PROJECTS_HOME}" \
        "${PROJECTS_HOME}/.local/bin/claude" --version 2>&1 || true)"
    if ! printf '%s' "${output2}" | grep -qE "not in approved|allowlist not found"; then
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

# ── ai-tools-chown: outside allowlist ────────────────────────────────────────

section "ai-tools-chown: outside allowlist"

tmpfile="$(mktemp)"
_cleanup+=("${tmpfile}")

if ! /usr/local/sbin/ai-tools/chown "${tmpfile}" 2>/dev/null; then
    pass "refuses to act on file outside allowlist (exit 1)"
else
    fail "acted on file outside allowlist -- should have refused"
fi

# ── ai-tools-chown: secret-named files (revoke access + notify) ──────────────
#
# Secret-named files the agent writes are chowned to the user's PRIVATE group
# with group+world bits stripped (-> PROJECTS_USER:PROJECTS_GROUP 600), which removes
# ai-tools' read access to the contents, and a NOTICE is emitted on stderr (the
# hook relays it to the session) and the audit log. The list is a global net;
# per-project secrets use ! in the allowlist (tested separately below).
#
# Invoked via setsid </dev/null to reach the non-interactive apply branch as the
# hook does -- otherwise ai-tools-chown would prompt on /dev/tty mid-suite.

section "ai-tools-chown: secret-named files (revoke ai-tools access + notify)"

for name in \
    ".env.local"      \
    ".env.production" \
    "id_ed25519"      \
    "server.key"      \
    "cert.pem"        \
    "app.jks"         \
    ".pgpass"         \
    "kubeconfig"      \
    ".npmrc"          \
    "credentials"
do
    secret="${SCRIPT_DIR}/${name}"
    # Never touch a pre-existing path: a real secret in the project root would
    # otherwise be modified here and rm -rf'd by cleanup, destroying data.
    if [[ -e "${secret}" ]]; then
        skip "${name}" "already exists in project -- not overwriting real file"
        continue
    fi
    printf 'x' > "${secret}"
    chown ai-tools:ai-tools "${secret}"       # as if the agent just wrote it
    chmod 0644 "${secret}"                     # world-readable on purpose
    _cleanup+=("${secret}")

    err="$(mktemp)"; _cleanup+=("${err}")
    setsid /usr/local/sbin/ai-tools/chown "${secret}" < /dev/null > /dev/null 2>"${err}" || true

    owner="$(stat -c '%U:%G' "${secret}")"
    mode="$( stat -c '%a'    "${secret}")"
    if [[ "${owner}" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "${mode}" == "600" ]] \
       && grep -q 'NOTICE' "${err}"; then
        pass "${name}: -> ${PROJECTS_USER}:${PROJECTS_GROUP} 600 (ai-tools access removed) + NOTICE"
    else
        fail "${name}: got ${owner} ${mode}, notice='$(tr -d '\n' < "${err}")' (want ${PROJECTS_USER}:${PROJECTS_GROUP} 600 + NOTICE)"
    fi
done

# Ordinary (non-secret) file: normalized to PROJECTS_USER:ai-tools 640 (group
# ai-tools retained, world bits stripped) and NO notice emitted.
ord="${SCRIPT_DIR}/.test_plain_$$"
printf 'x' > "${ord}"; chown ai-tools:ai-tools "${ord}"; chmod 0644 "${ord}"
_cleanup+=("${ord}")
oerr="$(mktemp)"; _cleanup+=("${oerr}")
setsid /usr/local/sbin/ai-tools/chown "${ord}" < /dev/null > /dev/null 2>"${oerr}" || true
if [[ "$(stat -c '%U:%G' "${ord}")" == "${PROJECTS_USER}:ai-tools" && "$(stat -c '%a' "${ord}")" == "640" ]] \
   && ! grep -q 'NOTICE' "${oerr}"; then
    pass "ordinary file: -> ${PROJECTS_USER}:ai-tools 640, no NOTICE"
else
    fail "ordinary file: got $(stat -c '%U:%G' "${ord}") $(stat -c '%a' "${ord}"), notice='$(tr -d '\n' < "${oerr}")'"
fi

# A secret-named file the agent did NOT write (owned by PROJECTS_USER, not ai-tools)
# is NOT a breach: ai-tools never had write access to it. It must be left
# completely untouched, with NO 'breached' NOTICE -- otherwise the user gets a
# false alarm to rotate a secret the agent could not have read or modified.
usecret="${SCRIPT_DIR}/.env.user_owned_$$"
if [[ -e "${usecret}" ]]; then
    skip ".env.user_owned" "already exists in project -- not overwriting real file"
else
    printf 'x' > "${usecret}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${usecret}"; chmod 0600 "${usecret}"
    _cleanup+=("${usecret}")
    uerr="$(mktemp)"; _cleanup+=("${uerr}")
    setsid /usr/local/sbin/ai-tools/chown "${usecret}" < /dev/null > /dev/null 2>"${uerr}" || true
    if [[ "$(stat -c '%U:%G' "${usecret}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(stat -c '%a' "${usecret}")" == "600" ]] \
       && ! grep -q 'NOTICE' "${uerr}"; then
        pass "user-owned secret left untouched, no false breach NOTICE"
    else
        fail "user-owned secret: got $(stat -c '%U:%G' "${usecret}") $(stat -c '%a' "${usecret}"), notice='$(tr -d '\n' < "${uerr}")' (must be unchanged + no NOTICE)"
    fi
fi

# Security OUTCOME, not just mode bits: after quarantine, ai-tools (neither owner
# nor group of an <you>:<you> 600 file) must actually be UNABLE to read the contents.
# Asserts the threat-model goal directly. runuser drops to ai-tools as root with
# no sudoers/PAM dance.
csecret="${SCRIPT_DIR}/.env.unreadable_$$"
if [[ -e "${csecret}" ]] || ! command -v runuser >/dev/null; then
    skip "quarantined secret unreadable" "pre-existing file, or runuser unavailable"
else
    printf 'top-secret-value' > "${csecret}"; chown ai-tools:ai-tools "${csecret}"; chmod 0600 "${csecret}"
    _cleanup+=("${csecret}")
    run_chown "${csecret}"
    if [[ "$(stat -c '%U:%G' "${csecret}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]] \
       && ! runuser -u ai-tools -- cat "${csecret}" >/dev/null 2>&1; then
        pass "ai-tools genuinely cannot read the quarantined secret (EACCES)"
    else
        fail "ai-tools could still read the quarantined secret -- read access NOT revoked"
    fi
fi

# The quarantine must leave a durable, root-owned audit record naming the path.
asecret="${SCRIPT_DIR}/.env.audited_$$"
readonly AUDIT_LOG=/var/log/ai-tools-chown.log
if [[ -e "${asecret}" ]]; then
    skip "audit log entry" "pre-existing file -- not overwriting"
else
    printf 'x' > "${asecret}"; chown ai-tools:ai-tools "${asecret}"; chmod 0600 "${asecret}"
    _cleanup+=("${asecret}")
    run_chown "${asecret}"
    if [[ -f "${AUDIT_LOG}" ]] && grep -Fq "${asecret}" "${AUDIT_LOG}" \
       && [[ "$(stat -c '%U:%G %a' "${AUDIT_LOG}")" == "root:root 600" ]]; then
        pass "secret quarantine appends a NOTICE to the root:root 600 audit log"
    else
        fail "audit log missing entry for ${asecret}, or log not root:root 600 ($(stat -c '%U:%G %a' "${AUDIT_LOG}" 2>/dev/null))"
    fi
fi

# Case-insensitive secret matching (regression guard for the nocasematch path --
# the same block whose `shopt -p` once aborted the whole script under set -e).
# basename must match a secret pattern exactly (modulo case), so use a clean
# upper-cased name matching id_ed25519; an upper-cased secret must still quarantine.
ucsecret="${SCRIPT_DIR}/ID_ED25519"
if [[ -e "${ucsecret}" ]]; then
    skip "case-insensitive secret" "ID_ED25519 exists in project -- not overwriting"
else
    printf 'x' > "${ucsecret}"; chown ai-tools:ai-tools "${ucsecret}"; chmod 0644 "${ucsecret}"
    _cleanup+=("${ucsecret}")
    ucerr="$(mktemp)"; _cleanup+=("${ucerr}")
    setsid /usr/local/sbin/ai-tools/chown "${ucsecret}" < /dev/null > /dev/null 2>"${ucerr}" || true
    if [[ "$(stat -c '%U:%G' "${ucsecret}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(stat -c '%a' "${ucsecret}")" == "600" ]] \
       && grep -q 'NOTICE' "${ucerr}"; then
        pass "upper-case secret name (ID_ED25519) matched case-insensitively + quarantined"
    else
        fail "ID_ED25519 not treated as secret: got $(stat -c '%U:%G' "${ucsecret}") $(stat -c '%a' "${ucsecret}"), notice='$(tr -d '\n' < "${ucerr}")'"
    fi
fi

# ── ai-tools-chown: allowlist ! exclusion ────────────────────────────────────

section "ai-tools-chown: allowlist ! exclusion"

allowlist="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
if [[ ! -f "${allowlist}" ]]; then
    skip "! exclusion" "allowlist not found at ${allowlist}"
else
    excl_dir="${SCRIPT_DIR}/.test_excl_$$"
    excl_file="${excl_dir}/sensitive.txt"
    mkdir -p "${excl_dir}"
    touch "${excl_file}"
    chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${excl_file}"
    _cleanup+=("${excl_dir}")

    # Add exclusion, run test, remove exclusion
    printf '!%s\n' "${excl_dir}" >> "${allowlist}"
    before="$(stat -c '%U:%G' "${excl_file}")"
    /usr/local/sbin/ai-tools/chown "${excl_file}" 2>/dev/null || true
    after="$(stat -c '%U:%G' "${excl_file}")"
    # Remove the test exclusion entry from the allowlist
    escaped="$(printf '%s' "!${excl_dir}" | sed 's/[\\|]/\\&/g')"
    sed -i "\|^${escaped}$|d" "${allowlist}"

    if [[ "${before}" == "${after}" ]]; then
        pass "! exclusion: ownership preserved for excluded subdirectory"
    else
        fail "! exclusion: ownership changed from ${before} to ${after} -- exclusion not honoured"
    fi
fi

# ── ai-tools-chown: TOCTOU-safe apply ────────────────────────────────────────
#
# Exercises the success path (the only branch that actually chowns/chmods) and
# the hardlink guard. ai-tools-chown pins the validated inode via an open fd and
# acts through /proc/self/fd, refusing anything that is not a regular file with
# link count 1 -- so a symlink or hardlink swapped in cannot redirect the
# root-privileged chown/chmod at a file outside the approved tree.
#
# Invoked via setsid with stdin from /dev/null to reach the non-interactive
# branch (no controlling tty -> the /dev/tty probe fails), as the hook does.

section "ai-tools-chown: TOCTOU-safe apply"

# (1) Regular world-readable file the agent just wrote (ai-tools:ai-tools):
#     chowned to PROJECTS_USER:ai-tools + world bits gone.
ap="${SCRIPT_DIR}/.test_apply_$$"
printf 'x' > "${ap}"; chown ai-tools:ai-tools "${ap}"; chmod 0644 "${ap}"
_cleanup+=("${ap}")
run_chown "${ap}"
if [[ "$(stat -c '%U:%G' "${ap}")" == "${PROJECTS_USER}:ai-tools" && "$(stat -c '%a' "${ap}")" == "640" ]]; then
    pass "regular file: chowned to ${PROJECTS_USER}:ai-tools, world bits stripped (644 -> 640)"
else
    fail "regular file: expected ${PROJECTS_USER}:ai-tools 640, got $(stat -c '%U:%G' "${ap}") $(stat -c '%a' "${ap}")"
fi

# (2) Empty file ("regular empty file" in stat %F) must still be handled.
ep="${SCRIPT_DIR}/.test_empty_$$"
: > "${ep}"; chown ai-tools:ai-tools "${ep}"; chmod 0666 "${ep}"
_cleanup+=("${ep}")
run_chown "${ep}"
if [[ "$(stat -c '%U:%G' "${ep}")" == "${PROJECTS_USER}:ai-tools" && "$(stat -c '%a' "${ep}")" == "660" ]]; then
    pass "empty file: chowned and world bits stripped (666 -> 660)"
else
    fail "empty file: expected ${PROJECTS_USER}:ai-tools 660, got $(stat -c '%U:%G' "${ep}") $(stat -c '%a' "${ep}")"
fi

# (2b) A file the agent did NOT write (owned by PROJECTS_USER, not ai-tools) must be
#      left untouched -- ai-tools-chown only acts on agent-written paths.
np="${SCRIPT_DIR}/.test_noown_$$"
printf 'x' > "${np}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${np}"; chmod 0644 "${np}"
_cleanup+=("${np}")
run_chown "${np}"
if [[ "$(stat -c '%U:%G' "${np}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(stat -c '%a' "${np}")" == "644" ]]; then
    pass "non-agent-written file left untouched (owner/mode unchanged)"
else
    fail "non-agent-written file was modified to $(stat -c '%U:%G' "${np}") $(stat -c '%a' "${np}") -- agent-owned guard missing"
fi

# (3) Hardlinked file (nlink > 1) under an approved dir must be left untouched:
#     a freshly written file is never hardlinked, and a hardlink could point at
#     a sensitive file outside the tree.
hp="${SCRIPT_DIR}/.test_hard_$$"; hl="${SCRIPT_DIR}/.test_hard_link_$$"
printf 'x' > "${hp}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${hp}"; chmod 0644 "${hp}"
ln "${hp}" "${hl}"                        # link count now 2
_cleanup+=("${hp}" "${hl}")
run_chown "${hp}"
after_owner="$(stat -c '%U:%G' "${hp}")"
if [[ "${after_owner}" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
    pass "hardlinked file (nlink>1) left untouched"
else
    fail "hardlinked file was modified to ${after_owner} -- nlink>1 guard missing (TOCTOU hardlink vector)"
fi

# (4) Directory the agent created: chowned to PROJECTS_USER:ai-tools with world bits
#     stripped but group rwx preserved (the agent must keep writing into a dir it
#     made). 755 (world-traversable, ai-tools-owned) -> 770. nlink >= 2 must NOT
#     trip the hardlink guard, which applies to regular files only.
dp="${SCRIPT_DIR}/.test_dir_$$"
mkdir "${dp}"; chown ai-tools:ai-tools "${dp}"; chmod 0755 "${dp}"
_cleanup+=("${dp}")
run_chown "${dp}"
if [[ "$(stat -c '%U:%G' "${dp}")" == "${PROJECTS_USER}:ai-tools" && "$(stat -c '%a' "${dp}")" == "770" ]]; then
    pass "directory: chowned to ${PROJECTS_USER}:ai-tools, world bits stripped, group rwx kept (755 -> 770)"
else
    fail "directory: expected ${PROJECTS_USER}:ai-tools 770, got $(stat -c '%U:%G' "${dp}") $(stat -c '%a' "${dp}")"
fi

# (5) A directory the agent did NOT create (owned by PROJECTS_USER, not ai-tools)
#     must be left completely untouched: normalizing it would grant ai-tools the
#     group rwx it never had. Pins the dir-owner guard against regression.
up="${SCRIPT_DIR}/.test_userdir_$$"
mkdir "${up}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${up}"; chmod 0700 "${up}"
_cleanup+=("${up}")
run_chown "${up}"
if [[ "$(stat -c '%U:%G' "${up}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(stat -c '%a' "${up}")" == "700" ]]; then
    pass "user-owned directory left untouched (no group access granted to ai-tools)"
else
    fail "user-owned directory was modified to $(stat -c '%U:%G' "${up}") $(stat -c '%a' "${up}") -- dir-owner guard missing (ai-tools gained access)"
fi

# (6) Symlink redirection: the scariest vector. An agent-planted symlink inside
#     the project pointing AT a sensitive file OUTSIDE it must never let the
#     root-run chown/chmod follow it onto the victim. ai-tools-chown canonicalises
#     with realpath, so the target resolves outside the allowlist and is refused;
#     the victim must be byte-for-byte untouched (owner, mode, and link count).
victim="$(mktemp /tmp/ait_victim.XXXXXX)"; _cleanup+=("${victim}")
chown root:root "${victim}"; chmod 0600 "${victim}"
vbefore="$(stat -c '%U:%G %a' "${victim}")"
sl="${SCRIPT_DIR}/.test_symlink_$$"; ln -s "${victim}" "${sl}"; _cleanup+=("${sl}")
run_chown "${sl}"
if [[ "$(stat -c '%U:%G %a' "${victim}")" == "${vbefore}" && -L "${sl}" ]]; then
    pass "symlink to an outside victim is refused; victim untouched (${vbefore})"
else
    fail "symlink redirection modified the outside victim: now $(stat -c '%U:%G %a' "${victim}") (was ${vbefore}) -- root chown followed a symlink out of the tree"
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
    if [[ "$(stat -c '%U:%G' "${hd}")" == "${PROJECTS_USER}:ai-tools" && "$(stat -c '%a' "${hd}")" == "770" ]]; then
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

sweep="/opt/ai-tools/.claude/sandbox-sweep.sh"

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

# ── ai-tools-setgid: project setgid normalization ───────────────────────────
#
# The SessionStart hook calls this root helper to give the project's dirs group
# ai-tools + setgid, so files the projects user creates inherit the shared group
# (letting the projects user be a non-member of it). It re-validates the path
# against the allowlist and acts only at/under an allowed project. Invoked directly
# as root here, the way the helper runs after sudo (cf. run_chown).

section "ai-tools-setgid: project setgid normalization"

setgid_helper="/usr/local/sbin/ai-tools/setgid"
if [[ ! -x "${setgid_helper}" ]]; then
    skip "setgid normalization" "not installed at ${setgid_helper}"
else
    # (A) A dir under an allowed project (SCRIPT_DIR) gets group ai-tools + setgid.
    #     Start from a non-setgid, projects-group state to prove the helper changes it.
    sgroot="${SCRIPT_DIR}/.test_setgid_$$"
    mkdir -p "${sgroot}/sub" "${sgroot}/.env/inside"
    _cleanup+=("${sgroot}")
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${sgroot}"
    chmod -R 0770 "${sgroot}"                       # 770, no setgid, group = projects group
    setsid "${setgid_helper}" "${sgroot}" < /dev/null > /dev/null 2>&1 || true
    sg_group="$(stat -c '%G' "${sgroot}/sub")"
    sg_mode="$( stat -c '%a' "${sgroot}/sub")"
    if [[ "${sg_group}" == "ai-tools" ]] && (( (0${sg_mode} & 02000) != 0 )); then
        pass "setgid: dir under an allowed project gets group ai-tools + setgid"
    else
        fail "setgid: ${sgroot}/sub is ${sg_group} ${sg_mode} (want group ai-tools, setgid set)"
    fi

    # (A2) A secret-named dir (.env) and its whole subtree are skipped -- never
    #      flipped to the agent group, even without an explicit '!' exclusion.
    env_group="$(stat -c '%G' "${sgroot}/.env")"
    envsub_group="$(stat -c '%G' "${sgroot}/.env/inside")"
    if [[ "${env_group}" != "ai-tools" && "${envsub_group}" != "ai-tools" ]]; then
        pass "setgid: a secret-named dir (.env) and its subtree are left untouched"
    else
        fail "setgid: .env exposed (.env=${env_group} .env/inside=${envsub_group}, want not ai-tools)"
    fi

    # (B) A path NOT under any allowed project is rejected and left untouched.
    sgout="$(mktemp -d /tmp/ai-tools-setgid-XXXXXX)"
    mkdir -p "${sgout}/sub"
    chmod 0770 "${sgout}" "${sgout}/sub"            # no setgid
    _cleanup+=("${sgout}")
    setsid "${setgid_helper}" "${sgout}" < /dev/null > /dev/null 2>&1 || true
    sgo_mode="$(stat -c '%a' "${sgout}/sub")"
    if (( (0${sgo_mode} & 02000) == 0 )); then
        pass "setgid: a non-allowlisted path is left untouched"
    else
        fail "setgid: non-allowlisted ${sgout}/sub gained setgid (mode ${sgo_mode})"
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

helper="/usr/local/sbin/ai-tools/claude-symlink"
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

# ── Summary ───────────────────────────────────────────────────────────────────

sep="$(printf '─%.0s' {1..50})"
printf '\n%s\n' "${sep}"
printf 'Tests: %d passed' "${_pass}"
(( _fail > 0 )) && printf ', %d FAILED' "${_fail}"
(( _skip > 0 )) && printf ', %d skipped' "${_skip}"
printf '\n%s\n\n' "${sep}"

(( _fail == 0 ))
