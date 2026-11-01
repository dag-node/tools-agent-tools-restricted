#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout-reconcile-fields.sh
# Unit test for the layout reconcile's field repairs (layout.lib.sh): a run over a converged tree does not print a line,
# nor does a second run; each planted owner, mode and ACL drift converges in one run with its changed line and its log
# line at the level the rule states; a masked-off foreign entry is removed with no state in which it is effective;
# content drift beside owner and mode drift leaves every field under each state the content gate refuses; a package file
# at another owner, or writable beyond its row, is refused on that field with the remedy that replaces or restores it;
# and an exposed log names the restore by hand. Runs as root over a tree built from the layout table itself
# under AI_TOOLS_LAYOUT_ROOT (tests/lib/layout-fixture.sh, with the rpm collector stubbed), and skips, naming
# why, where the reconcile cannot run as root. The reconcile's root cases are split
# across the tests/unit/layout-reconcile-*.sh files so the runner's pool runs them at once; each file builds its own
# tree, and the unprivileged readers and decisions of the library are tests/unit/layout.sh's.

# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
# shellcheck disable=SC2034,SC2154  # an array handed to the library by name is written through its nameref
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/layout-fixture.sh"
# The fixtures `mkdir` and a redirection create take the modes umask 022 gives, whatever the invoker's umask.
umask 022
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

section "layout: the reconcile as root, fields (unit)"
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
STATE="${fixture_root}/var/opt/ai-tools/state"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] \
    && pass "a converged tree prints no line and exits 0" || fail "first run over the built tree: $(layout_fixture_brief "${out}")"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] \
    && pass "a second run prints no line and exits 0" || fail "second run: $(layout_fixture_brief "${out}")"
# A manual page rpm records as not installed, absent: not a finding, the run still clean.
MAN1="${fixture_root}/usr/local/share/man/man1/ai-tools.1"; rm -- "${MAN1}"
LAYOUT_FIXTURE_RPM_STATES[/usr/local/share/man/man1/ai-tools.1]="not installed"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] \
    && pass "an absent manual page rpm records as not installed prints no line and exits 0" || fail "not installed: $(layout_fixture_brief "${out}")"
unset 'LAYOUT_FIXTURE_RPM_STATES[/usr/local/share/man/man1/ai-tools.1]'; install -o root -g root -m 0644 /dev/null "${MAN1}"
LOG="${AI_TOOLS_LOG_DIR}/layout.log"
operator_conf="${OPERATOR_CONF}"
PROMPTS="${fixture_root}/etc/ai-tools/prompts"
chown nobody:nobody "${PROMPTS}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${PROMPTS}" owner "nobody:nobody	root:root" && [[ "$(stat -c '%U:%G' "${PROMPTS}")" == root:root && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "an owner drift on a directory converges with its changed line" || fail "owner drift: $(layout_fixture_brief "${out}")"
grep -q "INFO.*${PROMPTS} owner nobody:nobody -> root:root" "${LOG}" && pass "an owner moving to root is logged at info" || fail "owner log line: $(grep "${PROMPTS} owner" "${LOG}" | tail -n1)"
# A regular file at another owner is refused and left: its bytes were that account's to write. operator.conf at another
# owner is also an untrusted discovery input, so its rows are an error line and the run exits 5.
chown nobody:nobody "${operator_conf}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${operator_conf}" owner "the owner nobody:nobody is not the row's root:root; so another account may have written the bytes; review its content, then restore it by hand: sudo setfacl -b -- ${operator_conf}; sudo chown root:root -- ${operator_conf}; sudo chmod 0644 -- ${operator_conf}" \
    && [[ "$(stat -c '%U:%G' "${operator_conf}")" == nobody:nobody && "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "operator.conf at another owner is refused and left, naming the review and the restore by hand" || fail "owner refused: $(layout_fixture_brief "${out}")"
chown root:root "${operator_conf}"
chmod 0600 "${operator_conf}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${operator_conf}" mode "0600	0644" && [[ "$(stat -c '%a' "${operator_conf}")" == 644 ]] \
    && pass "a mode drift on operator.conf converges" || fail "mode drift: $(layout_fixture_brief "${out}")"
grep -q "NOTICE.*${operator_conf} mode 0600 -> 0644" "${LOG}" && pass "the widening is logged at notice" || fail "mode log line: $(grep "${operator_conf} mode" "${LOG}" | tail -n1)"
STATE="${fixture_root}/var/opt/ai-tools/state"
setfacl -m "g:nobody:r-x" -d -m "g:ai-ops:r-x" "${STATE}"
out="$(layout_fixture_reconcile)"
live="$(getfacl --omit-header -P -- "${STATE}")"
layout_fixture_has_observation "${out}" changed "${STATE}" acl && [[ "${live}" != *"group:nobody"* && "${live}" != *default:* && "${live}" == *"group:ai-ops:r-x"* ]] \
    && pass "a foreign entry and an undeclared default block are removed, the declared entry kept" || fail "acl drift: $(layout_fixture_brief "${out}") / $(tr '\n' '|' <<< "${live}")"
projects_dir="${fixture_root}/var/opt/ai-tools/sandbox-projects"
setfacl -m "g:nobody:rwx" "${projects_dir}"; chmod g= "${projects_dir}"
# A watcher samples the ACL while the reconcile runs: it signals readiness after its first read and counts its reads,
# so the case fails where it never read. Polling can miss an interval between two writes, so the result is sampled
# evidence of the one `setfacl --set-file` replacement.
activated="${TESTDIR}/activated" observations="${TESTDIR}/observations" ready="${TESTDIR}/ready"
rm -f "${activated}" "${observations}" "${ready}"
( while [[ ! -e "${TESTDIR}/stop-watch" ]]; do
      watch_acl="$(getfacl -e --omit-header -P -- "${projects_dir}" 2>/dev/null)" || continue
      printf . >> "${observations}"; [[ -e "${ready}" ]] || : > "${ready}"
      watch_line="$(grep '^group:nobody:rwx' <<< "${watch_acl}" || true)"
      [[ -z "${watch_line}" || "${watch_line}" == *'#effective:---'* ]] || : > "${activated}"
  done ) &
watcher=$!
for (( ready_wait = 0; ready_wait < 50; ready_wait++ )); do [[ -e "${ready}" ]] && break; sleep 0.1; done
if [[ ! -e "${ready}" ]]; then
    : > "${TESTDIR}/stop-watch"; wait "${watcher}" 2>/dev/null || true; rm -f "${TESTDIR}/stop-watch"
    fail "masked entry: the ACL watcher did not read ${projects_dir} within 5s, so the run is not observed"
else
    out="$(layout_fixture_reconcile)"
    : > "${TESTDIR}/stop-watch"; wait "${watcher}" 2>/dev/null || true; rm -f "${TESTDIR}/stop-watch"
    live="$(getfacl --omit-header -P -- "${projects_dir}")"
    sampled="$(stat -c '%s' "${observations}" 2>/dev/null || printf 0)"
    [[ "${live}" != *"group:nobody"* && "$(stat -c '%a' "${projects_dir}")" == 2770 && ! -e "${activated}" ]] && (( sampled > 0 )) \
        && pass "a masked-off foreign entry is removed as the group bits widen, effective in none of ${sampled} sampled ACL reads" \
        || fail "masked entry: $(tr '\n' '|' <<< "${live}") mode $(stat -c '%a' "${projects_dir}") sampled=${sampled} activated=$([[ -e "${activated}" ]] && echo yes || echo no)"
fi
LINK="${fixture_root}/usr/sbin/ai-tools"
chown --no-dereference nobody:nobody "${LINK}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${LINK}" owner "nobody:nobody	root:root" && [[ "$(stat -c '%U' "${LINK}")" == root ]] \
    && pass "a link's owner converges by name" || fail "link owner: $(layout_fixture_brief "${out}")"
# Content drift beside owner, mode and ACL drift leaves every field, under each state the content gate refuses.
CLI="${fixture_root}/usr/local/bin/ai-tools"
chown nobody:nobody "${CLI}"; chmod 0600 "${CLI}"
LAYOUT_FIXTURE_RPM_FLAGS[/usr/local/bin/ai-tools]='..5......'
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "drifted content refuses the entry whole at exit 4: owner and mode are left" || fail "content drift: $(layout_fixture_brief "${out}") / $(stat -c '%U %a' "${CLI}")"
LAYOUT_FIXTURE_RPM_FLAGS[/usr/local/bin/ai-tools]='..?......'
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(layout_fixture_status "${out}")" == rc=5 ]] \
    && pass "an unreadable digest is an error at exit 5, the entry left whole" || fail "unreadable digest: $(layout_fixture_brief "${out}")"
unset 'LAYOUT_FIXTURE_RPM_FLAGS[/usr/local/bin/ai-tools]'; LAYOUT_FIXTURE_RPM_STATUS=3
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" error "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" ]] \
    && pass "a failing collector leaves every package file whole" || fail "failing collector: $(layout_fixture_brief "${out}")"
LAYOUT_FIXTURE_RPM_STATUS=0
out="$(layout_fixture_reconcile 1)"
layout_fixture_has_observation "${out}" refused "${CLI}" owner "left as it is: the content is unverified" && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a pass without rpm reports the drifted package file per field and leaves it" || fail "without rpm: $(layout_fixture_brief "${out}")"
# Verified content does not bless bytes another account owned: the owner is refused, naming the reinstall.
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${CLI}" owner "the owner nobody:nobody is not the row's root:root; so another account may have written the bytes; sudo dnf reinstall ai-tools-base" \
    && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "with the content verified, a package file at another owner is refused on its owner and left" || fail "verified, other owner: $(layout_fixture_brief "${out}")"
chown root:root "${CLI}"
out="$(layout_fixture_reconcile)"
[[ "$(stat -c '%U %a' "${CLI}")" == "root 755" && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "with the owner restored by hand, the verified file's mode drift converges" || fail "verified: $(layout_fixture_brief "${out}")"
# The payload file a sandbox-writable parent holds, replaced by the projects user with the package's bytes (the rpm stub
# reports them verified): refused on its owner and left at that owner.
HOOK="${fixture_root}/opt/ai-tools/.claude/post-tool-hook.sh"
cp -- "${HOOK}" "${HOOK}.planted"; chown "${PROJECTS_USER}" "${HOOK}.planted"; mv -f -- "${HOOK}.planted" "${HOOK}"
hook_owner="$(stat -c '%U:%G' -- "${HOOK}")"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${HOOK}" owner "the owner ${hook_owner} is not the row's root:${SANDBOX_GROUP}; so another account may have written the bytes; sudo dnf reinstall ai-tools-agents-claude-code-restricted" \
    && [[ "$(stat -c '%U' "${HOOK}")" == "${PROJECTS_USER}" && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a hook with the package's bytes at the projects user's owner is refused and left at that owner" || fail "planted hook: $(layout_fixture_brief "${out}")"
chown "root:${SANDBOX_GROUP}" "${HOOK}"; chmod 0750 "${HOOK}"
# A root-owned package file at group write, then with a masked foreign entry carrying write: each refused on the field
# that widened it and left. At 0600 the same file converges, since no account but root could write it.
CONF_LIB="${fixture_root}/usr/local/lib/ai-tools/conf.lib.sh"
chmod 0664 "${CONF_LIB}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${CONF_LIB}" mode "the mode 0664 grants write beyond the row's 0644; so another account may have written the bytes; sudo dnf reinstall ai-tools-base" \
    && [[ "$(stat -c '%a' "${CONF_LIB}")" == 664 && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a package file at group write is refused on its mode and left" || fail "group write: $(layout_fixture_brief "${out}")"
chmod 0644 "${CONF_LIB}"; setfacl -m g:nobody:rw-,m::r-- "${CONF_LIB}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${CONF_LIB}" acl "the entry group:nobody:rw- grants write beyond the row; so another account may have written the bytes; sudo dnf reinstall ai-tools-base" \
    && getfacl --omit-header -P -- "${CONF_LIB}" | grep -q '^group:nobody:rw-' && [[ "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a package file with a masked foreign entry carrying write is refused on its ACL and left" || fail "foreign entry: $(layout_fixture_brief "${out}")"
setfacl -b "${CONF_LIB}"; chmod 0600 "${CONF_LIB}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${CONF_LIB}" mode "0600	0644" && [[ "$(stat -c '%a' "${CONF_LIB}")" == 644 && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "the same file at 0600 converges" || fail "0600: $(layout_fixture_brief "${out}")"
# A payload row with named entries is reinstalled whatever its ACL carries, the entry named as observed.
README="${fixture_root}/var/opt/ai-tools/README.md"
setfacl -m g:nobody:rw-,m::r-- "${README}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${README}" acl "the entry group:nobody:rw- grants write beyond the row; so another account may have written the bytes; sudo dnf reinstall ai-tools-base" \
    && getfacl --omit-header -P -- "${README}" | grep -q '^group:nobody:rw-' && [[ "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "README.md with a foreign entry carrying write is refused naming that entry and left" || fail "README foreign entry: $(layout_fixture_brief "${out}")"
setfacl -x g:nobody "${README}"; setfacl -m m::r-- "${README}"
# A log is a ghost, so an exposed one names the restore by hand: a reinstall does not write a %ghost, and removing
# the log would remove the evidence it holds. Restored as printed, the next run is clean.
LAYOUT_LOG="${fixture_root}/var/log/ai-tools/layout.log"
[[ -e "${LAYOUT_LOG}" ]] || : > "${LAYOUT_LOG}"
chown root:root "${LAYOUT_LOG}"; chmod 0660 "${LAYOUT_LOG}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${LAYOUT_LOG}" mode "the mode 0660 grants write beyond the row's 0600; so another account may have written the bytes; review its content, then restore it by hand: sudo setfacl -b -- ${LAYOUT_LOG}; sudo chown root:root -- ${LAYOUT_LOG}; sudo chmod 0600 -- ${LAYOUT_LOG}" \
    && [[ "$(stat -c '%a' "${LAYOUT_LOG}")" == 660 && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "layout.log at group write is refused naming the restore by hand, and left" || fail "exposed log: $(layout_fixture_brief "${out}")"
setfacl -b -- "${LAYOUT_LOG}"; chown root:root -- "${LAYOUT_LOG}"; chmod 0600 -- "${LAYOUT_LOG}"
out="$(layout_fixture_reconcile)"
[[ "$(layout_fixture_status "${out}")" == rc=0 ]] && pass "the log restored as the remedy prints converges with no line" \
    || fail "restored log: $(layout_fixture_brief "${out}")"
skip "a label drift converging" "every fixture is under /tmp, where the policy declares no label expectation; the label field is driven on a packaged host"

finish
