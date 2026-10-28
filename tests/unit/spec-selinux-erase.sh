#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/spec-selinux-erase.sh
# Hermetic check of the ai-tools-selinux %postun in packaging/ai-tools.spec: on final erase it does not write the policy
# store while the sandbox account's sessions read `live` or `unreadable` (cli.rule.md, ref-section-e6c6),
# and under `none` it drops every local rule naming a policy type, unloads the modules, names each project tree
# a dropped rule covered with the restorecon that resets it, and restores the control-plane and sandbox trees once
# the store shows every ai_tools module gone (confinement.rule.md, "How the policy ships").
#
# A scriptlet runs inside an rpm transaction as root, so its body is read out of the spec as text, its macros and host
# paths rewritten to fixture trees, and run under /bin/sh with the session reader, semanage, semodule, restorecon
# and flock defined as shell functions ahead of it: each records its call, and a file in the fixture makes one of them
# fail. The printed restore command is run through the same stub and its argument read back, so a path carrying a space
# is held to reach restorecon as one argument. The gate itself is shown by a mutation: with its test rewritten, a live
# reading writes the store, which the live and unreadable cases refuse.
#
# Unprivileged, and reads the checkout alone; skips outside one.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="${ROOT}/packaging/ai-tools.spec"
RELABEL_LIB="${ROOT}/src/usr/local/lib/ai-tools/relabel.lib.sh"
section "ai-tools-selinux %postun: the erase waits for no live session and names what it leaves (unit)"

if [[ ! -r "${SPEC}" || ! -r "${RELABEL_LIB}" ]]; then
    skip "selinux %postun" "not a source checkout (no ${SPEC})"
    finish; exit
fi
mktestdir

body="$(awk '/^%postun -n ai-tools-selinux$/{open=1; next} /^%[a-z]/{open=0} open' "${SPEC}")"
if [[ -z "${body}" ]]; then
    fail "the spec has no %postun -n ai-tools-selinux section in the form this file reads"
    finish; exit
fi
escaper="$(extract_function "${RELABEL_LIB}" ai_tools_relabel__get_fcontext_literal)"
if [[ -z "${escaper}" ]]; then
    fail "relabel.lib.sh does not define ai_tools_relabel__get_fcontext_literal() in the form this file reads"
    finish; exit
fi
eval "${escaper}"

# The fixture trees, standing in for the five the scriptlet restores (the log directory is left absent, the case a host
# erased it on) and for the trees local rules name.
libexec="${TESTDIR}/libexec"; lib="${TESTDIR}/lib"; log="${TESTDIR}/log"; home="${TESTDIR}/home"; clones="${TESTDIR}/clones"
project="${TESTDIR}/proj with spaces"; raw="${TESTDIR}/raw[0-9]+"; absent="${TESTDIR}/absent"; conf="${TESTDIR}/conf"
legacy="${TESTDIR}/legacy.v1"
mkdir -p "${libexec}" "${lib}" "${home}/.nvm" "${clones}" "${project}" "${raw}" "${conf}" "${legacy}"

body="${body//\/var\/opt\/ai-tools\/sandbox-projects/${clones}}"
body="${body//\/opt\/ai-tools/${home}}"
body="${body//\/var\/log\/ai-tools/${log}}"
body="${body//%\{ai_libexecdir\}/${libexec}}"
body="${body//%\{ai_libdir\}/${lib}}"
body="${body//\/run\/lock\/ai-tools-relabel.lock/${TESTDIR}/relabel.lock}"

# The store the stubs serve: a rule per shape the sweep meets. The raw rule holds a metacharacter no label writes,
# over a directory that exists under that name, so the literal check and not the directory test decides its line.
printf '%s(/.*)?    all files    system_u:object_r:ai_tools_project_t:s0\n' \
    "$(ai_tools_relabel__get_fcontext_literal "${project}")" \
    "${raw}" \
    "${legacy}" \
    "$(ai_tools_relabel__get_fcontext_literal "${absent}")" > "${TESTDIR}/rules.base"
printf '%s(/.*)?    all files    system_u:object_r:ai_tools_conf_t:s0\n' \
    "$(ai_tools_relabel__get_fcontext_literal "${conf}")" >> "${TESTDIR}/rules.base"
printf '%s/bin/claude\\.exe    regular file    system_u:object_r:ai_tools_exec_t:s0\n' "${home}" >> "${TESTDIR}/rules.base"
printf 'zebra\nai_tools\nai_tools_tmpmap\n' > "${TESTDIR}/modules.base"

# shellcheck disable=SC2016  # the stubs expand these when the scriptlet runs, not this shell
stubs='
STUB="__STUB__"
bash() { printf "read-session\n" >> "${STUB}/recorder"; cat "${STUB}/session"; }
flock() {
    printf "flock %s\n" "$*" >> "${STUB}/recorder"
    [ -f "${STUB}/flock_flips" ] && printf "live\n" > "${STUB}/session"
    [ -f "${STUB}/flock_fails" ] && return 1
    return 0
}
semanage() {
    if [ "$1 $2 $3" = "fcontext -l -C" ]; then cat "${STUB}/rules"; return 0; fi
    printf "semanage %s\n" "$*" >> "${STUB}/recorder"
    [ -f "${STUB}/delete_fails" ] && return 1
    return 0
}
semodule() {
    case "$1" in
        -l) if [ -f "${STUB}/list_fails" ]; then echo "libsemanage.semanage_direct_list: the store refused" >&2; return 1; fi
            cat "${STUB}/modules"; return 0 ;;
        -r) printf "semodule %s\n" "$*" >> "${STUB}/recorder"
            if [ -f "${STUB}/unload_fails" ]; then echo "libsemanage.semanage_direct_remove: a rule still names a type" >&2; return 1; fi
            grep -vE "^ai_tools(_|$)" "${STUB}/modules" > "${STUB}/modules.next" || :
            mv "${STUB}/modules.next" "${STUB}/modules"; return 0 ;;
    esac
}
restorecon() {
    printf "restorecon %s\n" "$*" >> "${STUB}/recorder"
    printf "%s\n" "$#" "$@" > "${STUB}/last_args"
    [ -f "${STUB}/restore_fails" ] && [ "$2" = "$(cat "${STUB}/restore_fails")" ] && return 1
    return 0
}
'
stubs="${stubs//__STUB__/${TESTDIR}}"
printf '%s\n%s\n' "${stubs}" "${body}" > "${TESTDIR}/run.sh"

# run_erase <state> [fail-marker...]: run the scriptlet as a final erase under that reading, with each marker file
# placed for the stubs; the recorder holds every store write and restore, out and err the two streams.
run_erase() {
    local state="$1"; shift
    printf '%s\n' "${state}" > "${TESTDIR}/session"
    cp "${TESTDIR}/rules.base" "${TESTDIR}/rules"; cp "${TESTDIR}/modules.base" "${TESTDIR}/modules"
    rm -f "${TESTDIR}/recorder" "${TESTDIR}/list_fails" "${TESTDIR}/unload_fails" "${TESTDIR}/delete_fails" \
          "${TESTDIR}/restore_fails" "${TESTDIR}/flock_flips" "${TESTDIR}/flock_fails" "${TESTDIR}/last_args" \
          "${TESTDIR}/relabel.lock"
    : > "${TESTDIR}/recorder"
    local marker; for marker in "$@"; do case "${marker}" in restore_fails=*) printf '%s' "${marker#*=}" > "${TESTDIR}/restore_fails" ;; *) : > "${TESTDIR}/${marker}" ;; esac; done
    status=0
    sh "${TESTDIR}/run.sh" 0 > "${TESTDIR}/out" 2> "${TESTDIR}/err" || status=$?
    recorder="$(cat "${TESTDIR}/recorder")"; err="$(cat "${TESTDIR}/err")"
}

# ── A live or unreadable reading writes nothing and names the re-run ────────────────────────────
for state in live unreadable; do
    run_erase "${state}"
    if ! grep -qE '^(semanage|semodule|restorecon) ' <<< "${recorder}" && [[ "${status}" -eq 0 ]]; then
        pass "${state}: no store write, no restore, exit 0"
    else
        fail "${state}: the scriptlet wrote or walked (exit ${status}): ${recorder//$'\n'/; }"
    fi
    if grep -q 'WARNING left the policy loaded' <<< "${err}" \
            && grep -qF 'sudo dnf install ai-tools-selinux && sudo dnf remove ai-tools-selinux' <<< "${err}" \
            && grep -qF "then restore the labels: sudo restorecon -R ${libexec} ${lib} ${log} ${home} ${clones}" <<< "${err}" \
            && grep -qF 'sudo semodule -r ai_tools ai_tools_tmpmap' <<< "${err}"; then
        pass "${state}: the warning names the stop, the package re-run, and the by-hand steps through the label restore"
    else
        fail "${state}: the warning lacks the re-run or the label restore: ${err//$'\n'/; }"
    fi
    if [[ "${recorder}" == "flock -w 120 9"$'\n'"read-session" ]]; then
        pass "${state}: the sessions are read once the lock is held, and nothing else runs"
    else
        fail "${state}: the lock and the reading are not the run's two steps in that order: ${recorder//$'\n'/; }"
    fi
done

# A session that starts during the lock wait is read: the flock stub flips the reading to live while it waits.
run_erase none flock_flips
if ! grep -qE '^(semanage|semodule|restorecon) ' <<< "${recorder}" && grep -q 'WARNING left the policy loaded' <<< "${err}"; then
    pass "none at the start, live once the lock is held: no store write, the warning printed"
else
    fail "none at the start, live once the lock is held: the stale reading wrote the store: ${recorder//$'\n'/; }"
fi

# A lock not taken is reported, and the erase proceeds as the %post does.
run_erase none flock_fails
if grep -qF "NOTE proceeding without the relabel lock -- the wait for ${TESTDIR}/relabel.lock ran out" <<< "${err}" \
        && grep -q '^semanage fcontext -d ' <<< "${recorder}" && [[ "${status}" -eq 0 ]]; then
    pass "none, lock wait ran out: the loss of serialization is reported and the erase proceeds"
else
    fail "none, lock wait ran out: ${err//$'\n'/; } / ${recorder//$'\n'/; }"
fi

# ── An idle reading sweeps, unloads and restores under the lock ────────────────────────────────
run_erase none
deletes="$(grep -c '^semanage fcontext -d ' <<< "${recorder}" || true)"
if (( deletes == 6 )) && grep -qF "semanage fcontext -d -f a -- $(ai_tools_relabel__get_fcontext_literal "${project}")(/.*)?" <<< "${recorder}" \
        && grep -qF "semanage fcontext -d -f f -- ${home}/bin/claude\\.exe" <<< "${recorder}"; then
    pass "none: every local rule naming a policy type is deleted with its file-type letter (${deletes})"
else
    fail "none: the sweep did not delete each rule with its letter: ${recorder//$'\n'/; }"
fi
first_write="$(grep -n '^semanage fcontext -d \|^semodule ' <<< "${recorder}" || true)"; first_write="${first_write%%:*}"
lock_line="$(grep -n '^flock -w 120 9$' <<< "${recorder}" || true)"; lock_line="${lock_line%%:*}"
read_line="$(grep -n '^read-session$' <<< "${recorder}" || true)"; read_line="${read_line%%:*}"
if [[ -n "${lock_line}" && -n "${read_line}" && -n "${first_write}" ]] && (( lock_line < read_line && read_line < first_write )) \
        && [[ -e "${TESTDIR}/relabel.lock" ]]; then
    pass "none: the relabel lock (line ${lock_line}), then the reading (line ${read_line}), then the first store write (line ${first_write})"
else
    fail "none: the lock, the reading and the first write are not in that order (lock '${lock_line}', read '${read_line}', write '${first_write}')"
fi
if grep -qF 'semodule -r ai_tools -r ai_tools_tmpmap' <<< "${recorder}"; then
    pass "none: every loaded ai_tools module is unloaded in one transaction"
else
    fail "none: the unload is missing or partial: ${recorder//$'\n'/; }"
fi
restores="$(grep '^restorecon ' <<< "${recorder}" || true)"
if [[ "${restores}" == "restorecon -R ${libexec}"$'\n'"restorecon -R ${lib}"$'\n'"restorecon -R ${home}"$'\n'"restorecon -R ${clones}" ]]; then
    pass "none: the four present trees are restored one call each after the unload, the absent one skipped"
else
    fail "none: the trees were not restored as four calls over the present trees: ${restores//$'\n'/; }"
fi
if [[ "${status}" -eq 0 ]]; then pass "none: exit 0"; else fail "none: exit ${status}"; fi

# The printed restore lines: one for the project tree and one for the config tree, none for the raw rule (its decoded
# literal does not re-escape to the pattern) and none for the absent tree.
restore_lines="$(grep 'restore its default types with: ' <<< "${err}" || true)"
if [[ "$(grep -c . <<< "${restore_lines}")" -eq 2 ]] \
        && grep -qF "${project} keeps labels of a type the policy no longer defines (ai_tools_project_t); restore its default types with: sudo restorecon -R '${project}'" <<< "${restore_lines}" \
        && grep -qF "sudo restorecon -R '${conf}'" <<< "${restore_lines}" \
        && ! grep -qF "${raw}" <<< "${restore_lines}" && ! grep -qF "${legacy}" <<< "${restore_lines}" \
        && ! grep -qF "${absent}" <<< "${restore_lines}"; then
    pass "none: the project and config trees are named with a single-quoted restorecon; the raw, legacy and absent rules are not"
else
    fail "none: the restore lines are not the two expected: ${restore_lines//$'\n'/; }"
fi
# A dropped rule whose pattern is not a literal this release writes -- the raw one, and the legacy one an earlier
# release wrote without escaping its dot -- is named for review with its pattern.
review_lines="$(grep 'whose pattern is not a literal path this release writes' <<< "${err}" || true)"
if [[ "$(grep -c . <<< "${review_lines}")" -eq 2 ]] \
        && grep -qF "dropped the rule ${raw}(/.*)? (ai_tools_project_t), whose pattern" <<< "${review_lines}" \
        && grep -qF "dropped the rule ${legacy}(/.*)? (ai_tools_project_t), whose pattern" <<< "${review_lines}" \
        && grep -qF 'restore each with: sudo restorecon -R <tree>' <<< "${review_lines}"; then
    pass "none: the raw and the legacy rule are each named for review with the restorecon to run"
else
    fail "none: the review lines are not the two expected: ${review_lines//$'\n'/; }"
fi
# The command as the operator pastes it, with the stub reading the arguments that reach restorecon, and the same command
# with its quotes removed as the control the argument count tells apart.
pasted="$(grep -F "'${project}'" <<< "${restore_lines}" | sed 's/.*restore its default types with: sudo //')"
run_pasted() {
    rm -f "${TESTDIR}/last_args"
    # shellcheck disable=SC2034  # the stub functions the eval defines read STUB
    ( STUB="${TESTDIR}"; eval "${stubs#*$'\n'}"; eval "$1" )
    cat "${TESTDIR}/last_args" 2>/dev/null || true
}
if [[ "$(run_pasted "${pasted}")" == $'2\n-R\n'"${project}" ]]; then
    pass "none: the pasted command hands the project path to restorecon as one argument"
else
    fail "none: the pasted command '${pasted}' reached restorecon as: $(run_pasted "${pasted}" | tr '\n' ';')"
fi
unquoted="${pasted//\'/}"
if [[ "$(run_pasted "${unquoted}" | head -n 1)" -gt 2 ]]; then
    pass "control: the same command without its quotes reaches restorecon as several arguments"
else
    fail "control: the unquoted command '${unquoted}' did not split; the argument count does not tell the two apart"
fi

# ── The restore waits for a read-back listing no module ─────────────────────────────────────────
run_erase none list_fails
if ! grep -q '^restorecon ' <<< "${recorder}" && ! grep -q '^semodule ' <<< "${recorder}" \
        && grep -q 'could not read the module store -- ' <<< "${err}"; then
    pass "none, listing refused: the store is reported, nothing is unloaded, no tree is restored"
else
    fail "none, listing refused: ${recorder//$'\n'/; } / ${err//$'\n'/; }"
fi
run_erase none unload_fails
if ! grep -q '^restorecon ' <<< "${recorder}" && grep -q 'left loaded: ai_tools ai_tools_tmpmap ' <<< "${err}"; then
    pass "none, unload refused: the modules left are named and no tree is restored"
else
    fail "none, unload refused: ${recorder//$'\n'/; } / ${err//$'\n'/; }"
fi
: > "${TESTDIR}/modules.base"
run_erase none
if grep -q "^restorecon -R ${home}$" <<< "${recorder}" && ! grep -q '^semodule ' <<< "${recorder}"; then
    pass "none, no module loaded: no unload is attempted and the trees are restored"
else
    fail "none, no module loaded: ${recorder//$'\n'/; }"
fi
printf 'zebra\nai_tools\nai_tools_tmpmap\n' > "${TESTDIR}/modules.base"

# ── A tree the walk could not restore is named with its retry ───────────────────────────────────
run_erase none "restore_fails=${lib}"
if grep -qF "could not restore the default types under ${lib}; run: sudo restorecon -R ${lib}" <<< "${err}" \
        && grep -q "^restorecon -R ${clones}$" <<< "${recorder}" && [[ "${status}" -eq 0 ]]; then
    pass "none, one restore fails: the tree is named with its retry, the later trees are restored, exit 0"
else
    fail "none, one restore fails: ${err//$'\n'/; } / ${recorder//$'\n'/; }"
fi

# ── The control: with the gate's test rewritten, a live reading writes the store ─────────────────
printf '%s\n%s\n' "${stubs}" "${body}" | sed 's/\[ "\${_sandbox_session_state}" != none \]/[ "${_sandbox_session_state}" = never ]/' > "${TESTDIR}/run.sh"
if ! grep -qF '!= none ]' "${TESTDIR}/run.sh" && grep -qF '= never ]' "${TESTDIR}/run.sh"; then
    run_erase live
    if grep -q '^semanage fcontext -d ' <<< "${recorder}"; then
        pass "control: without the gate a live reading deletes rules, which the live case above refuses"
    else
        fail "control: the mutated scriptlet did not write under a live reading; the stubs do not drive the sweep"
    fi
else
    fail "control: the gate's test was not found in the form this file rewrites"
fi

finish
