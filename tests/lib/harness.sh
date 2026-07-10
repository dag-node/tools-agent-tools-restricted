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

# check_file <path> <owner> <group> <mode>: PASS when the file's actual owner, group, and
# octal mode all match; FAIL (naming the mismatch) otherwise, or when the path is absent.
# Used by the integration suite to assert deployed-artifact ownership/permissions.
check_file() {
    local file="$1" exp_owner="$2" exp_group="$3" exp_mode="$4"
    if [[ ! -e "${file}" ]]; then
        fail "${file}: MISSING"
        return
    fi
    local act_owner act_group act_mode ok=true
    act_owner="$(stat -c '%U' "${file}")"
    act_group="$(stat -c '%G' "${file}")"
    act_mode="$( stat -c '%a' "${file}")"
    [[ "${act_owner}" == "${exp_owner}" ]] || ok=false
    [[ "${act_group}" == "${exp_group}" ]] || ok=false
    [[ "${act_mode}"  == "${exp_mode}"  ]] || ok=false
    if ${ok}; then
        pass "${file}  (${exp_owner}:${exp_group} ${exp_mode})"
    else
        fail "${file}: expected ${exp_owner}:${exp_group} ${exp_mode}, got ${act_owner}:${act_group} ${act_mode}"
    fi
}

# check_file_optional <path> <owner> <group> <mode>: like check_file, but a missing path is a
# SKIP, not a FAIL -- for artifacts created on demand (a per-operator override file, a %ghost log
# written on first use) that are legitimately absent on a fresh install yet, when present, must
# still match the model.
check_file_optional() {
    [[ -e "$1" ]] || { skip "$1" "absent until created on demand"; return; }
    check_file "$@"
}

# require_root: abort unless run as root. Helper tests set arbitrary ownership/ACLs and
# create third-party-owned fixtures, which needs root; the suites are invoked via sudo.
require_root() {
    [[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }
}

# The unprivileged project user (and the sandbox account) the helpers collaborate with,
# derived from the sudo invocation -- never hard-coded.
PROJECTS_USER="${SUDO_USER:?error: invoke via sudo, not as root directly}"
PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}")"
PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" | cut -d: -f6)"
PROJECTS_UID="$(id -u "${PROJECTS_USER}")"
readonly PROJECTS_USER PROJECTS_GROUP PROJECTS_HOME PROJECTS_UID
readonly SANDBOX_USER="ai-tools"
readonly SANDBOX_GROUP="ai-tools"

# Teardown removes every artifact a test registered, on any exit. Nothing outside these
# paths is ever touched. It returns success unconditionally: it runs in the EXIT trap, and
# under `set -e` a non-zero teardown status -- e.g. the empty-_cleanup loop where the final
# `[[ -n "" ]]` is false, or an `rm` of an already-gone path -- would otherwise become the
# script's exit status and mask an all-PASS run as a failure. The result comes from finish.
#
# _teardown_cmd holds one non-path cleanup command -- state that is not a file to unlink --
# registered with on_teardown and run directly (no eval; best-effort, output discarded) after
# the path sweep. The live case is a bridge integration test clearing the transient
# `ai-tools-handback@*` instances its negative cases leave FAILED, so the manager's
# failed-unit list reflects only real faults, not test-induced rejections. Quote a glob you
# want passed to the command literally (systemd does its own unit-name matching):
# on_teardown systemctl reset-failed 'ai-tools-handback@*'.
declare -a _cleanup=() _teardown_cmd=()
on_teardown() { _teardown_cmd=("$@"); }
_teardown() {
    local p
    for p in "${_cleanup[@]:-}"; do [[ -n "${p}" ]] && rm -rf "${p}"; done
    [[ ${#_teardown_cmd[@]} -gt 0 ]] && "${_teardown_cmd[@]}" >/dev/null 2>&1
    return 0
}
trap _teardown EXIT

# Redirect the helpers' root-only file logs (chown.log, setgid.log, setfacl.log, ...) away
# from the production /var/log/ai-tools into a throwaway dir, so a test run never appends
# to -- or raises spurious ERROR lines in (a negative-path test feeds a helper /etc/passwd,
# a missing group, a bogus version) -- the real operation trail. AI_TOOLS_LOG_DIR is a
# root-only hook, exactly like AI_TOOLS_ALLOWLIST / AI_TOOLS_OPERATOR_CONF: sudo strips it
# and the live handback daemon execs helpers with its own environment, so only a root
# caller execing a helper directly (this suite) redirects it. The journald sink still
# carries every line under its per-component tag, so nothing is lost. A helper the LIVE
# daemon execs (integration/handback.sh) keeps the real dir -- the daemon does not inherit
# this -- matching the AI_TOOLS_ALLOWLIST limitation. Registered for teardown.
_test_logdir="$(mktemp -d /tmp/ai-tools-testlog.XXXXXX)"
_cleanup+=("${_test_logdir}")
export AI_TOOLS_LOG_DIR="${_test_logdir}"

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
# and point the deployed helpers at it via the AI_TOOLS_ALLOWLIST test hook. Also seeds a
# matching operator.conf fixture (mk_operator) so the helpers resolve the same identity the
# fixtures are owned by. Exported so a helper run as a child process inherits both.
mk_allowlist() {
    printf '%s\n' "$@" > "${TESTDIR}/allowed-projects"
    export AI_TOOLS_ALLOWLIST="${TESTDIR}/allowed-projects"
    mk_operator
}

# mk_operator: write a dummy operator.conf in TESTDIR naming the test's projects user (the
# real SUDO_USER the fixtures are owned by) as the sole operator, and point the deployed
# helpers at it via the AI_TOOLS_OPERATOR_CONF test hook -- the operator-identity counterpart
# to AI_TOOLS_ALLOWLIST, carrying the same root-only-injection rationale. Home and group are
# derived from the name at runtime (getent/id), so only the OPERATORS list is written.
# Exported so a child helper inherits it.
mk_operator() {
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${TESTDIR}/operator.conf"
    export AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf"
}

# finish: print the per-file summary and exit non-zero if anything failed (so a runner can
# aggregate by exit status).
finish() {
    printf '\n%s\n  %d passed, %d failed, %d skipped\n' \
        "──────────────────────────────────────────" "${_pass}" "${_fail}" "${_skip}"
    [[ "${_fail}" -eq 0 ]]
}
