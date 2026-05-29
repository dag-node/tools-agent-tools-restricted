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

REAL_USER="${SUDO_USER:?error: invoke via sudo, not as root directly}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
REAL_GROUP="$(id -gn "${REAL_USER}")"
REAL_UID="$(id -u "${REAL_USER}")"

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

# ── File permission checks ────────────────────────────────────────────────────

check_file() {
    local file="$1" exp_user="$2" exp_group="$3" exp_mode="$4"
    if [[ ! -e "${file}" ]]; then
        fail "${file}: MISSING"
        return
    fi
    local act_user act_group act_mode ok=true
    act_user="$( stat -c '%U' "${file}")"
    act_group="$(stat -c '%G' "${file}")"
    act_mode="$( stat -c '%a' "${file}")"
    [[ "${act_user}"  == "${exp_user}"  ]] || ok=false
    [[ "${act_group}" == "${exp_group}" ]] || ok=false
    [[ "${act_mode}"  == "${exp_mode}"  ]] || ok=false
    if ${ok}; then
        pass "${file}  (${exp_user}:${exp_group} ${exp_mode})"
    else
        fail "${file}: expected ${exp_user}:${exp_group} ${exp_mode}, got ${act_user}:${act_group} ${act_mode}"
    fi
}

section "File permissions"
check_file /usr/local/sbin/ai-tools-chown            root              root              750
check_file /etc/sudoers.d/ai-tools-claude             root              root              440
check_file /etc/profile.d/path_dedup.sh               root              root              644
check_file /opt/ai-tools/bin/nvm-update.sh            ai-tools          ai-tools          750
check_file /opt/ai-tools/.claude/post-write-hook.sh   ai-tools          ai-tools          750
check_file /opt/ai-tools/.claude/settings.json        ai-tools          ai-tools          640
check_file "${REAL_HOME}/.local/bin/claude"            "${REAL_USER}"    "${REAL_GROUP}"   750
check_file "${REAL_HOME}/.local/bin/nvm-update.sh"     "${REAL_USER}"    "${REAL_GROUP}"   750
check_file "${REAL_HOME}/.config/systemd/user/nvm-update.service" \
                                                       "${REAL_USER}"    "${REAL_GROUP}"   644
check_file "${REAL_HOME}/.config/systemd/user/nvm-update.timer" \
                                                       "${REAL_USER}"    "${REAL_GROUP}"   644

# ── Sudoers syntax ────────────────────────────────────────────────────────────

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools-claude > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools-claude parses OK"
else
    fail "/etc/sudoers.d/ai-tools-claude has syntax errors"
fi

# ── Wrapper allowlist guard ───────────────────────────────────────────────────

section "Wrapper allowlist guard"

if [[ ! -x "${REAL_HOME}/.local/bin/claude" ]]; then
    skip "wrapper guard" "claude wrapper not found at ${REAL_HOME}/.local/bin/claude"
else
    tmpdir="$(mktemp -d)"
    _cleanup+=("${tmpdir}")

    # Run wrapper from a directory that is not in the approved list
    output="$(cd "${tmpdir}" && sudo -u "${REAL_USER}" HOME="${REAL_HOME}" \
        "${REAL_HOME}/.local/bin/claude" --version 2>&1 || true)"

    if printf '%s' "${output}" | grep -qE "not in approved|allowlist not found"; then
        pass "wrapper blocks execution from unapproved directory"
    else
        fail "wrapper did NOT block unapproved directory (output: ${output})"
    fi

    # Verify wrapper allows execution from approved project directory
    output2="$(cd "${SCRIPT_DIR}" && sudo -u "${REAL_USER}" HOME="${REAL_HOME}" \
        "${REAL_HOME}/.local/bin/claude" --version 2>&1 || true)"
    if ! printf '%s' "${output2}" | grep -qE "not in approved|allowlist not found"; then
        pass "wrapper allows execution from approved project directory"
    else
        fail "wrapper incorrectly blocked approved directory (output: ${output2})"
    fi
fi

# ── Wrapper symlink check (unreadable final target) ───────────────────────────
#
# Regression guard. The wrapper once tested the stable link with `[[ -e ]]`,
# which dereferences the FULL chain (bin/claude -> versioned bin/claude ->
# .../claude-code/bin/claude.exe). claude.exe lives in the package dir, mode 700
# owned ai-tools, so the invoking user cannot stat the final target (EACCES) and
# -e falsely reported the link as missing -- the wrapper bailed with "claude
# symlink not found" on a perfectly valid link. The fix tests the link itself
# with `[[ -L ]]`, which does not traverse past the first hop.

section "Wrapper symlink check (unreadable final target)"

wrapper="${REAL_HOME}/.local/bin/claude"

# (A) Reproduce the hazard hermetically: a symlink chain whose final target sits
#     behind a dir the invoking user cannot enter. -L must still see the link
#     even though -e cannot stat through to the target.
fx="$(mktemp -d)"
_cleanup+=("${fx}")
chmod 755 "${fx}"                                 # let REAL_USER traverse to the link
mkdir "${fx}/pkg"
chmod 700 "${fx}/pkg"                             # root-owned 700: blocks the final stat
: > "${fx}/pkg/claude.exe"
ln -s "${fx}/pkg/claude.exe" "${fx}/versioned"    # npm symlink analogue
ln -s "${fx}/versioned"      "${fx}/link"         # stable link -> versioned -> pkg/claude.exe

l_ok=false; e_ok=false
sudo -u "${REAL_USER}" test -L "${fx}/link" && l_ok=true
sudo -u "${REAL_USER}" test -e "${fx}/link" && e_ok=true

if ${l_ok} && ! ${e_ok}; then
    pass "symlink with unreadable target: -L detects it, -e does not"
elif ! ${l_ok}; then
    fail "fixture broken: -L failed to detect the symlink as ${REAL_USER}"
else
    skip "hazard demo" "final target is readable to ${REAL_USER}; EACCES path not exercised"
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
    out="$(cd "${SCRIPT_DIR}" && sudo -u "${REAL_USER}" HOME="${REAL_HOME}" \
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

if ! /usr/local/sbin/ai-tools-chown "${tmpfile}" 2>/dev/null; then
    pass "refuses to act on file outside allowlist (exit 1)"
else
    fail "acted on file outside allowlist -- should have refused"
fi

# ── ai-tools-chown: hardcoded protections ────────────────────────────────────

section "ai-tools-chown: hardcoded credential/secret file protections"

# These files are inside the approved project directory but must never be chowned.
# The test verifies the script exits 0 silently without changing ownership.
for name in \
    ".env"            \
    ".env.local"      \
    ".env.production" \
    "server.key"      \
    "cert.pem"        \
    ".npmrc"          \
    ".aiignore"       \
    "credentials"
do
    protected="${SCRIPT_DIR}/${name}"
    # Never touch a pre-existing path: a real .env (etc.) in the project root
    # would otherwise be modified here and rm -rf'd by cleanup, destroying data.
    if [[ -e "${protected}" ]]; then
        skip "${name}" "already exists in project -- not overwriting real file"
        continue
    fi
    touch "${protected}"
    chown "${REAL_USER}:${REAL_USER}" "${protected}"
    _cleanup+=("${protected}")

    before="$(stat -c '%U:%G' "${protected}")"
    exit_code=0
    /usr/local/sbin/ai-tools-chown "${protected}" 2>/dev/null || exit_code=$?
    after="$(stat -c '%U:%G' "${protected}")"

    if [[ "${before}" == "${after}" && "${exit_code}" -eq 0 ]]; then
        pass "${name}: skipped silently, ownership preserved"
    elif [[ "${before}" != "${after}" ]]; then
        fail "${name}: ownership changed from ${before} to ${after} -- protection missing"
    else
        fail "${name}: unexpected exit code ${exit_code}"
    fi
done

# ── ai-tools-chown: allowlist ! exclusion ────────────────────────────────────

section "ai-tools-chown: allowlist ! exclusion"

allowlist="${REAL_HOME}/.config/ai-tools/allowed-projects"
if [[ ! -f "${allowlist}" ]]; then
    skip "! exclusion" "allowlist not found at ${allowlist}"
else
    excl_dir="${SCRIPT_DIR}/.test_excl_$$"
    excl_file="${excl_dir}/sensitive.txt"
    mkdir -p "${excl_dir}"
    touch "${excl_file}"
    chown "${REAL_USER}:${REAL_USER}" "${excl_file}"
    _cleanup+=("${excl_dir}")

    # Add exclusion, run test, remove exclusion
    printf '!%s\n' "${excl_dir}" >> "${allowlist}"
    before="$(stat -c '%U:%G' "${excl_file}")"
    /usr/local/sbin/ai-tools-chown "${excl_file}" 2>/dev/null || true
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

run_chown() { setsid /usr/local/sbin/ai-tools-chown "$1" < /dev/null > /dev/null 2>&1 || true; }

# (1) Regular world-readable file under an approved dir: chowned + world bits gone.
ap="${SCRIPT_DIR}/.test_apply_$$"
printf 'x' > "${ap}"; chown "${REAL_USER}:${REAL_USER}" "${ap}"; chmod 0644 "${ap}"
_cleanup+=("${ap}")
run_chown "${ap}"
if [[ "$(stat -c '%U:%G' "${ap}")" == "${REAL_USER}:ai-tools" && "$(stat -c '%a' "${ap}")" == "640" ]]; then
    pass "regular file: chowned to ${REAL_USER}:ai-tools, world bits stripped (644 -> 640)"
else
    fail "regular file: expected ${REAL_USER}:ai-tools 640, got $(stat -c '%U:%G' "${ap}") $(stat -c '%a' "${ap}")"
fi

# (2) Empty file ("regular empty file" in stat %F) must still be handled.
ep="${SCRIPT_DIR}/.test_empty_$$"
: > "${ep}"; chown "${REAL_USER}:${REAL_USER}" "${ep}"; chmod 0666 "${ep}"
_cleanup+=("${ep}")
run_chown "${ep}"
if [[ "$(stat -c '%U:%G' "${ep}")" == "${REAL_USER}:ai-tools" && "$(stat -c '%a' "${ep}")" == "660" ]]; then
    pass "empty file: chowned and world bits stripped (666 -> 660)"
else
    fail "empty file: expected ${REAL_USER}:ai-tools 660, got $(stat -c '%U:%G' "${ep}") $(stat -c '%a' "${ep}")"
fi

# (3) Hardlinked file (nlink > 1) under an approved dir must be left untouched:
#     a freshly written file is never hardlinked, and a hardlink could point at
#     a sensitive file outside the tree.
hp="${SCRIPT_DIR}/.test_hard_$$"; hl="${SCRIPT_DIR}/.test_hard_link_$$"
printf 'x' > "${hp}"; chown "${REAL_USER}:${REAL_USER}" "${hp}"; chmod 0644 "${hp}"
ln "${hp}" "${hl}"                        # link count now 2
_cleanup+=("${hp}" "${hl}")
run_chown "${hp}"
after_owner="$(stat -c '%U:%G' "${hp}")"
if [[ "${after_owner}" == "${REAL_USER}:${REAL_USER}" ]]; then
    pass "hardlinked file (nlink>1) left untouched"
else
    fail "hardlinked file was modified to ${after_owner} -- nlink>1 guard missing (TOCTOU hardlink vector)"
fi

# ── Systemd timer ─────────────────────────────────────────────────────────────

section "Systemd"

if sudo -u "${REAL_USER}" \
    XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" \
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
