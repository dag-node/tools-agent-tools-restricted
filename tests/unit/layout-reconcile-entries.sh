#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout-reconcile-entries.sh
# Unit test for the layout reconcile's missing and replaced entries (layout.lib.sh): a missing directory is created
# owner-only under an existing parent and brought to its row through the pin, at a non-root owner included; a link
# planted at a sandbox-group-writable row is refused and the directory it names left, with dotnet bootstrap's own row
# check read over the same tree; a missing file and a dangling link are refused with their remedies; a type mismatch
# either way is refused, and the rows under a replaced directory or a symlinked one are refused unread; and a missing
# directory under a missing parent is refused with no component created. Runs as root over a tree built from the layout
# table itself under AI_TOOLS_LAYOUT_ROOT (tests/lib/layout-fixture.sh, with the rpm collector stubbed), and skips,
# naming why, where the reconcile cannot run as root. The reconcile's root cases are split
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

section "layout: the reconcile as root, entries (unit)"
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
LINK="${fixture_root}/usr/sbin/ai-tools"
out="$(layout_fixture_reconcile)"
layout_fixture_is_clean "${out}" && pass "the built tree is converged: a run prints no line and exits 0 (control)" \
    || fail "the built tree is not converged: $(layout_fixture_brief "${out}")"
# Missing entries: a directory is created, a file and a dangling link are refused with their remedies.
PIN="${STATE}/entrypoint-pin.d"; rm -r "${PIN}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${PIN}" type "absent	directory" && layout_fixture_has_observation "${out}" changed "${PIN}" mode "0700	0755" \
    && ! layout_fixture_has_observation "${out}" changed "${PIN}" owner && [[ "$(stat -c '%U:%G %a' "${PIN}")" == "root:root 755" ]] \
    && pass "a missing root-owned directory is created owner-only and brought to its mode, with no owner line" \
    || fail "create: $(layout_fixture_brief "${out}")"
# The timer-stamp directory belongs to the sandbox account: its owner arrives through the pin, after the create.
STAMP_DIR="${fixture_root}${CP_HOME}/${CP_TIMER_STAMP_DIR}"; rmdir "${STAMP_DIR}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${STAMP_DIR}" type "absent	directory" && layout_fixture_has_observation "${out}" changed "${STAMP_DIR}" owner \
    && [[ "$(stat -c '%U:%G %a' "${STAMP_DIR}")" == "${SANDBOX_USER}:${SANDBOX_GROUP} $(( 10#${CP_TIMER_STAMP_DIR_MODE} ))" \
          && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "a missing directory at a non-root owner takes that owner through the pin, with its owner line" \
    || fail "stamp directory: $(layout_fixture_brief "${out}") / $(stat -c '%U:%G %a' "${STAMP_DIR}")"
# A dotnet state directory, which no %files line places: created as root's under the state root, which is not setgid,
# so its group arrives through the pin with an owner line.
DOTNET_CLI="${fixture_root}${CP_INTEGRATIONS}/dotnet/cli"; rmdir "${DOTNET_CLI}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${DOTNET_CLI}" type "absent	directory" \
    && layout_fixture_has_observation "${out}" changed "${DOTNET_CLI}" mode "0700	2770" \
    && layout_fixture_has_observation "${out}" changed "${DOTNET_CLI}" owner "root:root	root:${SANDBOX_GROUP}" \
    && [[ "$(stat -c '%U:%G %a' "${DOTNET_CLI}")" == "root:${SANDBOX_GROUP} 2770" && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "a missing dotnet state directory is created and brought to its row through the pin" \
    || fail "dotnet cli: $(layout_fixture_brief "${out}") / $(stat -c '%U:%G %a' "${DOTNET_CLI}")"
# The NuGet cache is sandbox-group-writable, so the account can rename `packages` aside and plant a link of its name.
# `dotnet bootstrap` runs this reconcile, which refuses the link and leaves the directory it names alone.
DOTNET_PACKAGES="${fixture_root}${CP_INTEGRATIONS}/dotnet/nuget/packages"; OUTSIDE="${TESTDIR}/outside-packages"
install -d -o nobody -g nobody -m 0700 "${OUTSIDE}"; rmdir "${DOTNET_PACKAGES}"; ln -s "${OUTSIDE}" "${DOTNET_PACKAGES}"
outside_before="$(stat -c '%U:%G %a' "${OUTSIDE}")"
[[ -L "${DOTNET_PACKAGES}" && "${outside_before}" == "nobody:nobody 700" ]] \
    || fail "planted packages link: setup did not take ($(stat -c '%F' "${DOTNET_PACKAGES}") / ${outside_before})"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${DOTNET_PACKAGES}" type \
    && [[ -L "${DOTNET_PACKAGES}" && "$(stat -c '%U:%G %a' "${OUTSIDE}")" == "${outside_before}" \
          && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a link planted at the NuGet cache is refused, and the directory it names keeps its owner and mode" \
    || fail "planted packages link: $(layout_fixture_brief "${out}") / $(stat -c '%U:%G %a' "${OUTSIDE}")"
rm "${DOTNET_PACKAGES}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" changed "${DOTNET_PACKAGES}" type "absent	directory" \
    && [[ "$(stat -c '%U:%G %a' "${DOTNET_PACKAGES}")" == "root:${SANDBOX_GROUP} 2770" && "$(layout_fixture_status "${out}")" == rc=0 ]] \
    && pass "the link removed, the NuGet cache is created at its row" \
    || fail "packages recreated: $(layout_fixture_brief "${out}") / $(stat -c '%U:%G %a' "${DOTNET_PACKAGES}" 2>&1)"
rmdir "${OUTSIDE}"
# `dotnet bootstrap`'s own check after its reconcile, read out of the checkout's command and run over this tree: a link
# planted at `nuget`, with a real `packages` under its target, passes a type test on `nuget/packages`, and the row read
# refuses it at `nuget`. The converged tree is the control the same check passes.
DOTNET_COMMAND="${ROOT}/src/usr/local/lib/ai-tools/admin-commands.d/dotnet.sh"
DOTNET_STATE="${fixture_root}${CP_INTEGRATIONS}/dotnet"; DOTNET_NUGET="${DOTNET_STATE}/nuget"
OUTSIDE="${TESTDIR}/outside-nuget"
# dotnet_state_check: run read_state_rows_refusal over the fixture's state tree; prints its refusal, or `passed`.
dotnet_state_check() {
    ( STATE_DIR="${DOTNET_STATE}" NUGET_DIR="${DOTNET_NUGET}" CLI_HOME_DIR="${DOTNET_STATE}/cli"
      TOOLS_DIR="${DOTNET_STATE}/tools" LAYOUT_LIB="${TESTDIR}/lib/layout.lib.sh"
      eval "$(extract_function "${DOTNET_COMMAND}" read_state_rows_refusal)"
      read_state_rows_refusal && printf 'passed\n' ) 2>&1 || true
}
out="$(dotnet_state_check)"
[[ "${out}" == passed ]] && pass "dotnet bootstrap's row check passes the converged state tree (control)" \
    || fail "dotnet row check on the converged tree: $(layout_fixture_brief "${out}")"
install -d -o nobody -g nobody -m 0700 "${OUTSIDE}" "${OUTSIDE}/packages"
mv "${DOTNET_NUGET}" "${TESTDIR}/nuget-aside"; ln -s "${OUTSIDE}" "${DOTNET_NUGET}"
outside_before="$(stat -c '%U:%G %a' "${OUTSIDE}" "${OUTSIDE}/packages" | tr '\n' ' ')"
if [[ -L "${DOTNET_NUGET}" && -d "${DOTNET_NUGET}/packages" && ! -L "${DOTNET_NUGET}/packages" ]]; then
    pass "a link planted at nuget passes a type test on nuget/packages (setup)"
else
    fail "planted nuget link: setup did not take ($(stat -c '%F' "${DOTNET_NUGET}" "${DOTNET_NUGET}/packages" 2>&1 | tr '\n' ' '))"
fi
out="$(layout_fixture_reconcile)"
check_out="$(dotnet_state_check)"
if layout_fixture_has_observation "${out}" refused "${DOTNET_NUGET}" type \
        && [[ "${check_out}" == "${DOTNET_NUGET} is not at its layout row (type-mismatch on its type)" ]] \
        && [[ "$(stat -c '%U:%G %a' "${OUTSIDE}" "${OUTSIDE}/packages" | tr '\n' ' ')" == "${outside_before}" ]]; then
    pass "a link planted at nuget fails dotnet bootstrap's row check at nuget, the directories it names left as they were"
else
    fail "planted nuget link: $(layout_fixture_brief "${out}") / check $(layout_fixture_brief "${check_out}") / $(stat -c '%U:%G %a' "${OUTSIDE}" "${OUTSIDE}/packages" | tr '\n' ' ')"
fi
rm "${DOTNET_NUGET}"; mv "${TESTDIR}/nuget-aside" "${DOTNET_NUGET}"; rm -r "${OUTSIDE}"
LAUNCH="${fixture_root}/usr/local/bin/ai-tools-launch"; rm "${LAUNCH}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${LAUNCH}" type && [[ "${out}" == *"dnf reinstall ai-tools-base"* && ! -e "${LAUNCH}" && "$(layout_fixture_status "${out}")" == rc=4 ]] \
    && pass "a missing file is refused naming the package, at exit 4" || fail "missing file: $(layout_fixture_brief "${out}")"
install -o root -g root -m 0755 /dev/null "${LAUNCH}"
ln -sfn "${fixture_root}/nonexistent" "${LINK}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${LINK}" type && [[ "${out}" == *"target does not exist"* ]] \
    && pass "a dangling link is refused" || fail "dangling: $(layout_fixture_brief "${out}")"
ln -sfn /dev/null "${LINK}"
# Type mismatch, both ways, and the rows under a replaced directory refused unread.
KEYS="${fixture_root}/usr/local/lib/ai-tools/keys"; ASC="${KEYS}/dag-node-package-signing.asc"
rm "${ASC}"; mkdir "${ASC}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${ASC}" type && [[ -d "${ASC}" ]] && pass "a directory where a file belongs is refused and left" || fail "dir for file: $(layout_fixture_brief "${out}")"
rmdir "${ASC}"; install -o root -g root -m 0644 /dev/null "${ASC}"
mv "${KEYS}" "${KEYS}.aside"; : > "${KEYS}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${KEYS}" type && layout_fixture_has_observation "${out}" refused "${ASC}" ancestor "not read: ${KEYS} is not at its row" \
    && pass "a file where a directory belongs is refused, and the rows under it refused unread naming it" || fail "file for dir: $(layout_fixture_brief "${out}")"
rm "${KEYS}"; mv "${KEYS}.aside" "${KEYS}"
ELSEWHERE="${TESTDIR}/elsewhere"; mkdir -p "${ELSEWHERE}"
mv "${STATE}" "${STATE}.aside"; ln -s "${ELSEWHERE}" "${STATE}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${STATE}" type && layout_fixture_has_observation "${out}" refused "${PIN}" ancestor && [[ ! -e "${ELSEWHERE}/entrypoint-pin.d" ]] \
    && pass "a symlink at a directory row refuses the rows under it, with no directory created at the target" \
    || fail "symlink at a directory row: $(layout_fixture_brief "${out}") / $(ls -A "${ELSEWHERE}" | tr '\n' ' ')"
rm "${STATE}"; mv "${STATE}.aside" "${STATE}"
PKGS="${fixture_root}/usr/share/selinux/packages"; rm -r "${PKGS}"
out="$(layout_fixture_reconcile)"
layout_fixture_has_observation "${out}" refused "${PKGS}/ai-tools" type && [[ "${out}" == *"${PKGS} is not a directory"* && ! -e "${PKGS}" ]] \
    && pass "a missing directory under a missing parent outside the table is refused, and no component is created" \
    || fail "missing parent: $(layout_fixture_brief "${out}")"
install -d -o root -g root -m 0755 "${PKGS}" "${PKGS}/ai-tools"

finish
