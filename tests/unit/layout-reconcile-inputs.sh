#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout-reconcile-inputs.sh
# Unit test for the layout reconcile's discovery inputs and its exit status (layout.lib.sh): an untrusted agents
# directory or operator.conf directory and the drift in the dynamic rows it hides converge in one invocation;
# an operator.conf writable by other accounts is refused and its rows stay unread at exit 5 until it is restored;
# an invalid manifest and an unresolved account stay visible at exit 5; an operator home carrying a backslash keeps
# the ancestor rule; a held lock is an error with no write; the exit order 1, 5, 4 holds, the postcondition branch
# and a lost entry set included; and a non-root caller is refused. Runs as root over a tree built from the layout table
# itself under AI_TOOLS_LAYOUT_ROOT (tests/lib/layout-fixture.sh, with the rpm collector stubbed), and skips, naming
# why, where the reconcile cannot run as root. The reconcile's root cases are split
# across the tests/unit/layout-reconcile-*.sh files so the runner's pool runs them at once; each file builds its own
# tree, and the unprivileged readers and decisions of the library are tests/unit/layout.sh's.

# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
# shellcheck disable=SC2034,SC2154  # an array handed to the library by name is written through its nameref
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/layout-fixture.sh"
# The fixtures `mkdir` and a redirection create take the modes umask 022 gives, whatever the invoker's umask,
# and the non-root case reads the library copy as the projects user through them.
umask 022
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

section "layout: the reconcile as root, inputs (unit)"
layout_fixture_prepare
# shellcheck source=/dev/null
if ! source "${LAYOUT_FIXTURE_LIB}" || ! declare -F ai_tools_layout__reconcile >/dev/null 2>&1 \
        || ! source "${TESTDIR}/lib/safe-paths.lib.sh"; then
    fail "could not source the library copy or it does not define its functions"; finish; exit
fi
skip_reason="$(layout_fixture_read_root_skip_reason)"
if [[ -n "${skip_reason}" ]]; then
    skip "the reconcile as root" "${skip_reason}"; finish; exit
fi
layout_fixture_build_tree
fixture_root="${FIXTURE_ROOT}"
operator_conf="${OPERATOR_CONF}"
LOG="${AI_TOOLS_LOG_DIR}/layout.log"
LAUNCH="${fixture_root}/usr/local/bin/ai-tools-launch"
out="$(layout_fixture_reconcile)"
layout_fixture_is_clean "${out}" && pass "the built tree is converged: a run prints no line and exits 0 (control)" \
    || fail "the built tree is not converged: $(layout_fixture_brief "${out}")"
# A discovery input the enumeration refuses, and the drift in the dynamic rows it hides, converge in one run.
agent_config_dir="${fixture_root}/opt/ai-tools/.acme"
chmod 0777 "${AGENTS_DIR}"; chmod 0700 "${agent_config_dir}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${AGENTS_DIR}" mode && layout_fixture_has_observation "${out}" changed "${agent_config_dir}" mode \
    && [[ "$(stat -c '%a' "${AGENTS_DIR}")" == 755 && "$(stat -c '%a' "${agent_config_dir}")" == 3770 && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "an untrusted agents directory and the drift in an agent config directory converge in one invocation" \
    || fail "agents.d then .acme: $(layout_fixture_brief "${out}")"
# operator.conf read untrusted through a group-writable directory: the directory is repaired first, so the operator rows
# the file names are read in the same run.
OPDIR="${fixture_root}${PROJECTS_HOME}/.config/ai-tools" ETC="${operator_conf%/*}"
chmod 0777 "${ETC}"; chmod 0755 "${OPDIR}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${ETC}" mode && layout_fixture_has_observation "${out}" changed "${OPDIR}" mode \
    && [[ "$(stat -c '%a' "${ETC}")" == 755 && "$(stat -c '%a' "${OPDIR}")" == 700 && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "operator.conf untrusted through its directory and the drift in an operator's config directory converge in one invocation" \
    || fail "/etc/ai-tools then the operator directory: $(layout_fixture_brief "${out}")"
# operator.conf itself writable by other accounts is refused and left, so the rows it names stay unread (exit 5) until
# the file is restored by hand; the next run then converges them.
chmod 0666 "${operator_conf}"; chmod 0755 "${OPDIR}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${operator_conf}" mode "the mode 0666 grants write beyond the row's 0644; so another account may have written the bytes; review its content, then restore it by hand" && layout_fixture_has_observation "${out}" error "${operator_conf}" operators \
    && [[ "$(stat -c '%a' "${operator_conf}")" == 666 && "$(stat -c '%a' "${OPDIR}")" == 755 && "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "operator.conf writable by other accounts is refused and left, and the rows it names stay unread at exit 5" \
    || fail "exposed operator.conf: $(layout_fixture_brief "${out}")"
chmod 0644 "${operator_conf}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${OPDIR}" mode && [[ "$(stat -c '%a' "${OPDIR}")" == 700 && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "once operator.conf is restored by hand the rows it names converge" || fail "after the restore: $(layout_fixture_brief "${out}")"
# An input the enumeration cannot use stays visible, at exit 5, run after run.
BAD="${AGENTS_DIR}/bad.conf"; printf 'config_dir=../x\n' > "${BAD}"; chmod 0644 "${BAD}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error "${BAD}" agents && [[ "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "an invalid manifest is an error at exit 5" || fail "invalid manifest: $(layout_fixture_brief "${out}")"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error "${BAD}" agents && [[ "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "and stays visible on the next run" || fail "invalid manifest, second run: $(layout_fixture_brief "${out}")"
rm "${BAD}"
printf 'OPERATORS="%s,no-such-user-zz"\n' "${PROJECTS_USER}" > "${operator_conf}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error no-such-user-zz operators && [[ "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "an account that does not resolve is an error at exit 5, the other operator's rows unaffected" || fail "unresolved account: $(layout_fixture_brief "${out}")"
# An operator whose home carries a backslash, for an account the host does not have (getent and id stubbed for that name
# alone): its ~/.config/ai-tools a symlink to a directory outside, the rows under it are refused naming it
# through the decoded keys, and the file behind the link is left.
stub_fake_home="${TESTDIR}/home/fix\\op"; mkdir -p "${stub_fake_home}"
FAKE_DIR="${fixture_root}${stub_fake_home}/.config/ai-tools" FAKE_VICTIM="${TESTDIR}/fake-victim"
mkdir -p "${FAKE_VICTIM}" "${FAKE_DIR%/*}"; install -o root -g root -m 0644 /dev/null "${FAKE_VICTIM}/allowed-projects"
ln -sfn "${FAKE_VICTIM}" "${FAKE_DIR}"
printf 'OPERATORS="%s,fixop"\n' "${PROJECTS_USER}" > "${operator_conf}"
# The shims are functions of their own, installed in the subshell the run takes, as the entry-set rows do.
stub_getent() {
    if [[ "$1" == passwd && "$2" == fixop ]]; then
        printf 'fixop:x:59999:59999::%s:/sbin/nologin\n' "${stub_fake_home}"
    else
        command getent "$@"
    fi
}
stub_id() { if [[ "$1" == -gn && "$2" == fixop ]]; then printf 'fixop\n'; else command id "$@"; fi; }
stub_run() { getent() { stub_getent "$@"; }; id() { stub_id "$@"; }; layout_fixture_reconcile; }
out="$(stub_run)"
unset -f stub_run stub_getent stub_id
_ai_tools_layout__encode_line wanted refused "${FAKE_DIR}/allowed-projects" ancestor "not read: ${FAKE_DIR} is not at its row"
grep -qxF -- "${wanted}" <<< "${out}" && [[ "$(stat -c '%U:%G %a' "${FAKE_VICTIM}/allowed-projects")" == "root:root 644" ]] \
    && pass "an operator home carrying a backslash keeps the ancestor rule: the rows under its link are refused, the file behind it left" \
    || fail "backslash home: $(layout_fixture_brief "${out}") / $(stat -c '%U:%G %a' "${FAKE_VICTIM}/allowed-projects")"
rm -f "${FAKE_DIR}"
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${operator_conf}"
# The lock held by another process: an error, exit 5, and no write.
chmod 0600 "${operator_conf}"
flock -x "${AI_TOOLS_LAYOUT_LOCK}" sleep 4 &
locker=$!
sleep 0.5
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error "${AI_TOOLS_LAYOUT_LOCK}" lock && [[ "$(layout_fixture_status "${out}")" == rc=5 && "$(stat -c '%a' "${operator_conf}")" == 600 ]] \
    && pass "a lock another process holds is an error at exit 5 with no write" || fail "held lock: $(layout_fixture_brief "${out}") / $(stat -c '%a' "${operator_conf}")"
wait "${locker}" 2>/dev/null || true
# The exit order: a failed write outranks an incomplete observation, which outranks a refusal.
printf 'config_dir=../x\n' > "${BAD}"; chmod 0644 "${BAD}"; rm "${LAUNCH}"
out="$(chmod() { return 1; }; layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=1 ]] && layout_fixture_has_observation "${out}" error "${operator_conf}" mode "chmod exited 1" \
    && pass "a failed write beside an error and a refusal exits 1" || fail "exit order 1: $(layout_fixture_brief "${out}")"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=5 ]] && pass "an error beside a refusal exits 5" || fail "exit order 5: $(layout_fixture_brief "${out}")"
rm "${BAD}"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=4 ]] && layout_fixture_has_observation "${out}" refused "${LAUNCH}" type && pass "a refusal alone exits 4" || fail "exit order 4: $(layout_fixture_brief "${out}")"
install -o root -g root -m 0755 /dev/null "${LAUNCH}"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] && pass "the tree converges again and exits 0" || fail "final: $(layout_fixture_brief "${out}")"
# The postcondition branch of the exit order: an apply that returns 0 without writing exits 1, the drift named
# as a repair that did not take.
chmod 0600 "${operator_conf}"
out="$(_ai_tools_layout__apply_entry_fields() { return 0; }; layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=1 ]] && layout_fixture_has_observation "${out}" error "${operator_conf}" mode "the change did not take" \
    && pass "a repair whose final read still carries the drift exits 1" || fail "exit order, postcondition: $(layout_fixture_brief "${out}")"
chmod 0644 "${operator_conf}"
# The union pass reads the entry set as a collector: an enumerator that exits 9 is an error line and exit 5.
out="$(ai_tools_layout__list_entries() { return 9; }; layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error layout.lib.sh entries "the entry set exited 9" && [[ "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "a lost entry set in the reconcile is an error at exit 5" || fail "lost set in the reconcile: $(layout_fixture_brief "${out}")"
unset -f rpm
if command -v runuser >/dev/null 2>&1; then
    chmod 0755 "${TESTDIR}"
    rc=0; err=""
    # shellcheck disable=SC2016  # the inner bash expands these
    err="$(runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_LAYOUT_ROOT="${fixture_root}" AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" \
        AI_TOOLS_OPERATOR_CONF="${operator_conf}" AI_TOOLS_LAYOUT_LOCK="${AI_TOOLS_LAYOUT_LOCK}" \
        bash -c 'source "$1" || exit 3; ai_tools_layout__reconcile 0' _ "${TESTDIR}/lib/layout.lib.sh" 2>&1 >/dev/null)" || rc=$?
    (( rc == 2 )) && pass "a non-root caller is refused with status 2" || fail "non-root reconcile: ${rc} ${err}"
else
    skip "a non-root caller" "runuser unavailable"
fi

finish
