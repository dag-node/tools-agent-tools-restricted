#!/usr/bin/env bash
# tests/lib/harness.sh
# Shared harness sourced by every test file. Provides the result counters, a /tmp testdir
# boundary with automatic teardown, a dummy-allowlist fixture, and the permission helper.
#
# Hermeticity contract (see .claude/rules/tests.rule.md): a test works ONLY inside its own
# /tmp testdir, builds its fixtures there with known content, never reads or writes the
# operator's real files, and removes everything it created on exit.

set -euo pipefail

declare -i _pass=0 _fail=0 _skip=0
pass()    { printf '  PASS  %s\n' "$*";            _pass=$(( _pass + 1 )); }
fail()    { printf '  FAIL  %s\n' "$*" >&2;        _fail=$(( _fail + 1 )); }
skip()    { printf '  SKIP  %s  (%s)\n' "$1" "$2"; _skip=$(( _skip + 1 )); }
section() { printf '\n── %s\n' "$*"; }

# perm <path>: the rwx permission bits only, as octal (masks setgid/setuid/sticky). GNU
# coreutils `chmod` with a numeric mode does NOT clear a directory's setgid bit, and a
# testdir created under a setgid parent inherits it, so mode assertions compare the low 3
# octal digits via this helper, not the raw `stat %a`. `8#` keeps it base-8 in any shell.
perm() { local m; m="$(stat -c '%a' "$1" 2>/dev/null)"; printf '%o' "$(( 8#${m:-0} & 8#777 ))"; }

# require_root: abort unless run as root. Helper tests set arbitrary ownership/ACLs and
# create third-party-owned fixtures, which needs root; the suites are invoked via sudo.
require_root() {
    [[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }
}

# The unprivileged project user (and the sandbox account) the helpers collaborate with,
# derived from the sudo invocation -- never hard-coded.
PROJECTS_USER="${SUDO_USER:?error: invoke via sudo, not as root directly}"
PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}")"
readonly PROJECTS_USER PROJECTS_GROUP
readonly SANDBOX_USER="ai-tools"
readonly SANDBOX_GROUP="ai-tools"

# Teardown removes every artifact a test registered, on any exit. Nothing outside these
# paths is ever touched.
declare -a _cleanup=()
_teardown() { local p; for p in "${_cleanup[@]:-}"; do [[ -n "${p}" ]] && rm -rf "${p}"; done; }
trap _teardown EXIT

# mktestdir: create THE dedicated /tmp boundary for this test and register it for teardown.
# Mode 0755 so an `sudo -u ai-tools` boundary check can traverse in to a fixture (the
# fixture's own mode is what the check exercises). Sets the global TESTDIR.
mktestdir() {
    TESTDIR="$(mktemp -d /tmp/ai-tools-test.XXXXXX)"
    _cleanup+=("${TESTDIR}")
    chmod 0755 "${TESTDIR}"
}

# mk_allowlist <line>...: write a dummy allowed-projects in TESTDIR with the given KNOWN
# content (one entry per line; '!'-prefixed lines are exclusions, exactly as in production)
# and point the deployed helpers at it via the AI_TOOLS_ALLOWLIST test hook. Exported so a
# helper run as a child process inherits it.
mk_allowlist() {
    printf '%s\n' "$@" > "${TESTDIR}/allowed-projects"
    export AI_TOOLS_ALLOWLIST="${TESTDIR}/allowed-projects"
}

# finish: print the per-file summary and exit non-zero if anything failed (so a runner can
# aggregate by exit status).
finish() {
    printf '\n%s\n  %d passed, %d failed, %d skipped\n' \
        "──────────────────────────────────────────" "${_pass}" "${_fail}" "${_skip}"
    [[ "${_fail}" -eq 0 ]]
}
