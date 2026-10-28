#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/spec-atr-names.sh
# Hermetic check of the ai-tools-base %pre in packaging/ai-tools.spec: it reads each name the short command atr takes
# and exits 1 at the first one in none of this project's forms, ahead of the account creation, and on that refusal
# starts the relabel watcher %pretrans stopped, since %posttrans does not run after a failed %pre. Where the watcher
# cannot be started, the refusal names the line that starts it.
#
# A scriptlet runs inside an rpm transaction as root, so its body is read out of the spec as RPM parses it, its host
# paths rewritten to a fixture tree, and run under /bin/sh with getent, groupadd, useradd and systemctl defined as shell
# functions ahead of it: each records its call, and a file in the fixture makes systemctl fail. The wrapper's marker
# line names /usr/local/bin/atr as content, so it is kept out of the rewrite, and the rewritten body is checked
# for that before any case runs. The scriptlet reads /usr/bin/systemctl with `[ -x ]`, so the fixture takes a directory
# where a 0755 file reads as executable, as tests/unit/agent-installs.sh does; with none, the cases that need a running
# watcher skip and the rest run.
#
# Unprivileged, and reads the checkout alone; skips outside one.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="${ROOT}/packaging/ai-tools.spec"
WRAPPER_SRC="${ROOT}/src/usr/local/bin/atr.sh"
PAGE1_SRC="${ROOT}/src/usr/local/share/man/man1/atr.1"
PAGE8_SRC="${ROOT}/src/usr/local/share/man/man8/atr.8"
section "ai-tools-base %pre: a name atr takes is refused unless it is this project's, and the refusal restarts the relabel watcher (unit)"

if [[ ! -r "${SPEC}" || ! -r "${WRAPPER_SRC}" ]]; then
    skip "base %pre" "not a source checkout (no ${SPEC})"
    finish; exit
fi
mktestdir

# The body the package ships is the one RPM's macro expansion leaves. Without rpmspec, the doubled percents are halved
# and the sysusers macro takes a stand-in that calls the same account tools.
if command -v rpmspec >/dev/null 2>&1 \
        && parsed="$(rpmspec -P --define "_sourcedir ${ROOT}/packaging" "${SPEC}" 2>/dev/null)"; then
    note "spec" "the %pre is read from rpmspec -P, as the package ships it"
else
    parsed="$(cat "${SPEC}")"
    parsed="${parsed//'%sysusers_create_compat %{SOURCE1}'/"getent passwd 'ai-tools' >/dev/null || useradd -r 'ai-tools' || :"}"
    parsed="${parsed//%%/%}"
    note "spec" "rpmspec is absent; the %pre is read from the source with its doubled percents halved"
fi
body="$(awk '/^%pre -n ai-tools-base$/{open=1; next} /^%[a-z]/{open=0} open' <<< "${parsed}")"
if [[ -z "${body}" ]]; then
    fail "the spec has no %pre -n ai-tools-base section in the form this file reads"
    finish; exit
fi

# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable.
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}
BASE="${TESTDIR}" XBIT=1
if ! x_bit_visible "${BASE}"; then
    alt=""
    mk_fixture_dir alt "${PROJECTS_HOME}" spec-atr 2>/dev/null || alt=""
    if [[ -n "${alt}" ]] && x_bit_visible "${alt}"; then BASE="${alt}"; else XBIT=0; fi
fi
FX="${BASE}/root"
WRAPPER="${FX}/usr/local/bin/atr" LINK="${FX}/usr/sbin/atr" SYSTEMCTL="${FX}/usr/bin/systemctl"
MAN1="${FX}/usr/local/share/man/man1" MAN8="${FX}/usr/local/share/man/man8"
mkdir -p "${FX}/usr/local/bin" "${FX}/usr/sbin" "${FX}/usr/bin" "${MAN1}" "${MAN8}"

# The host paths become the fixture's; the marker is content, so it is set aside first and put back after.
marker='# /usr/local/bin/atr --'
body="${body//"${marker}"/"# @ATR-MARKER@ --"}"
body="${body//"/usr/local/bin/atr"/"${FX}/usr/local/bin/atr"}"
body="${body//"/usr/sbin/atr"/"${FX}/usr/sbin/atr"}"
body="${body//"/usr/local/share/man/"/"${FX}/usr/local/share/man/"}"
body="${body//"/usr/bin/systemctl"/"${SYSTEMCTL}"}"
body="${body//"# @ATR-MARKER@ --"/"${marker}"}"
leftover="$(grep -nE '(^|[^[:alnum:]_/.-])/usr/(local/bin/atr|sbin/atr|local/share/man/|bin/systemctl)' <<< "${body}" \
    | grep -vF "${marker}" || true)"
if [[ -z "${leftover}" && "$(grep -cF "'${marker}'" <<< "${body}")" == 1 ]]; then
    pass "the body's host paths point at the fixture and the wrapper's marker is kept as content"
else
    fail "the rewrite left a host path or lost the marker: ${leftover//$'\n'/ | }"
    finish; exit
fi

# shellcheck disable=SC2016  # the stubs expand these when the scriptlet runs, not this shell
stubs='
STUB="__STUB__"
getent() { printf "getent %s\n" "$*" >> "${STUB}/recorder"; return 2; }
groupadd() { printf "groupadd %s\n" "$*" >> "${STUB}/recorder"; }
useradd() { printf "useradd %s\n" "$*" >> "${STUB}/recorder"; }
systemctl() { printf "systemctl %s\n" "$*" >> "${STUB}/recorder"; [ ! -f "${STUB}/systemctl_fails" ]; }
'
stubs="${stubs//__STUB__/${TESTDIR}}"
printf '%s\n%s\n' "${stubs}" "${body}" > "${TESTDIR}/run.sh"
printf '  rewritten %%pre under test: %s\n' "${TESTDIR}/run.sh"

# The scriptlet's tools reach it through a PATH of links, so a case can leave one out.
mkdir -p "${TESTDIR}/bin-full" "${TESTDIR}/bin-nozcat"
for tool in sed readlink zcat gzip cat; do
    ln -s "$(type -P "${tool}")" "${TESTDIR}/bin-full/${tool}"
    [[ "${tool}" == zcat || "${tool}" == gzip ]] || ln -s "$(type -P "${tool}")" "${TESTDIR}/bin-nozcat/${tool}"
done

# reset_names: remove every name the scriptlet reads, and the systemctl failure marker; place the systemctl file.
reset_names() {
    rm -rf "${WRAPPER}" "${LINK}" "${MAN1}"/atr.1* "${MAN8}"/atr.8* "${TESTDIR}/systemctl_fails"
    printf '#!/bin/sh\n' > "${SYSTEMCTL}"; chmod 0755 "${SYSTEMCTL}"
}
# run_pre [path-dir]: run the scriptlet; sets status, recorder and err.
run_pre() {
    : > "${TESTDIR}/recorder"
    status=0
    env -i PATH="${1:-${TESTDIR}/bin-full}" /bin/sh "${TESTDIR}/run.sh" > "${TESTDIR}/out" 2> "${TESTDIR}/err" || status=$?
    recorder="$(cat "${TESTDIR}/recorder")"; err="$(cat "${TESTDIR}/err")"
}
account_created() { grep -qE '^(groupadd|useradd) ' <<< "${recorder}"; }
watcher_starts() { grep -cxF 'systemctl start ai-tools-relabel.path' <<< "${recorder}" || true; }
readonly RUNNING='ai-tools-base: the relabel watcher %pretrans stopped is running again'
readonly BY_HAND='ai-tools-base: start the relabel watcher by hand: systemctl start ai-tools-relabel.path'

# ── Names absent, or in this project's forms, pass ──────────────────────────────────────────────
reset_names
run_pre
if (( status == 0 )) && account_created && [[ "$(watcher_starts)" == 0 && -z "${err}" ]]; then
    pass "every name absent: exit 0, the account is created, the watcher is left to %posttrans"
else
    fail "every name absent: exit ${status}, stderr [${err}], calls [${recorder//$'\n'/; }]"
fi

cp "${WRAPPER_SRC}" "${WRAPPER}"
ln -s ../local/bin/atr "${LINK}"
cp "${PAGE1_SRC}" "${MAN1}/atr.1"; gzip -c "${PAGE1_SRC}" > "${MAN1}/atr.1.gz"
cp "${PAGE8_SRC}" "${MAN8}/atr.8"; gzip -c "${PAGE8_SRC}" > "${MAN8}/atr.8.gz"
run_pre
(( status == 0 )) && account_created && [[ -z "${err}" ]] \
    && pass "the shipped wrapper, the ln -sr link and both stubs plain and gzip-compressed pass" \
    || fail "this project's forms: exit ${status}, stderr [${err}]"

rm -f "${WRAPPER}" "${LINK}"; ln -s "${WRAPPER}" "${LINK}"
run_pre
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "the link by its absolute target, dangling, passes" \
    || fail "the absolute dangling link: exit ${status}, stderr [${err}]"

{ sed -n '1,3p' "${WRAPPER_SRC}"; printf 'echo other content\n'; } > "${WRAPPER}"
run_pre
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "a marked wrapper with other content passes, as this project's name" \
    || fail "the marked wrapper: exit ${status}, stderr [${err}]"

# ── Each foreign occupant refuses ahead of the account, and the watcher is started again ─────────
# place_foreign <what>: put one foreign occupant in a tree otherwise empty, and print its path.
place_foreign() {
    reset_names
    case "$1" in
        unmarked) printf '#!/bin/sh\necho another tool\n' > "${WRAPPER}"; printf '%s' "${WRAPPER}" ;;
        directory) mkdir "${WRAPPER}"; printf '%s' "${WRAPPER}" ;;
        link-elsewhere) ln -s /usr/bin/at "${LINK}"; printf '%s' "${LINK}" ;;
        file-at-link) : > "${LINK}"; printf '%s' "${LINK}" ;;
        gz-without-so) printf '.TH ATR 1\n.SH NAME\natr \\- another tool\n' | gzip -c > "${MAN1}/atr.1.gz"; printf '%s' "${MAN1}/atr.1.gz" ;;
        wrong-section) cp "${PAGE1_SRC}" "${MAN8}/atr.8"; printf '%s' "${MAN8}/atr.8" ;;
        xz) xz -c "${PAGE8_SRC}" > "${MAN8}/atr.8.xz"; printf '%s' "${MAN8}/atr.8.xz" ;;
    esac
}
declare -A FOREIGN_WHAT=(
    [unmarked]="an unmarked regular file at the wrapper name" [directory]="a directory at the wrapper name"
    [link-elsewhere]="a symlink elsewhere at the link name" [file-at-link]="a regular file at the link name"
    [gz-without-so]="a gzip page without the .so line" [wrong-section]="a man8 page pointing at the man1 page"
    [xz]="an xz page, read as bytes"
)
for kind in unmarked directory link-elsewhere file-at-link gz-without-so wrong-section xz; do
    what="${FOREIGN_WHAT[${kind}]}"
    path="$(place_foreign "${kind}")"
    run_pre
    assert_msg MSG-W5Z8 "${err}" "${what}: refused under its code"
    if (( status == 1 )) && grep -qF "the name ${path} holds an entry" <<< "${err}" && ! account_created \
            && ! grep -q '^getent ' <<< "${recorder}"; then
        pass "${what}: exit 1 naming the path, ahead of the account creation"
    else
        fail "${what}: exit ${status}, stderr [${err}], calls [${recorder//$'\n'/; }]"
    fi
    if (( XBIT == 0 )); then
        continue
    fi
    if [[ "$(watcher_starts)" == 1 ]] && grep -qxF "${RUNNING}" <<< "${err}" && ! grep -qxF "${BY_HAND}" <<< "${err}"; then
        pass "${what}: the watcher is started once and the refusal says it runs again"
    else
        fail "${what}: watcher starts $(watcher_starts), stderr [${err}]"
    fi
done
(( XBIT == 1 )) || skip "the watcher restart" "no directory here reports a 0755 file as executable (a noexec mount)"

# ── A watcher that cannot be started is named with the line that starts it ───────────────────────
if (( XBIT == 1 )); then
    place_foreign unmarked >/dev/null; : > "${TESTDIR}/systemctl_fails"
    run_pre
    if (( status == 1 )) && [[ "$(watcher_starts)" == 1 ]] && grep -qxF "${BY_HAND}" <<< "${err}" \
            && ! grep -qxF "${RUNNING}" <<< "${err}"; then
        pass "a failed start: the refusal names the line that starts the watcher by hand"
    else
        fail "a failed start: exit ${status}, watcher starts $(watcher_starts), stderr [${err}]"
    fi
fi
place_foreign unmarked >/dev/null; rm -f "${SYSTEMCTL}"
run_pre
if (( status == 1 )) && [[ "$(watcher_starts)" == 0 ]] && grep -qxF "${BY_HAND}" <<< "${err}"; then
    pass "no systemctl: the refusal names the line that starts the watcher by hand, with no start attempted"
else
    fail "no systemctl: exit ${status}, watcher starts $(watcher_starts), stderr [${err}]"
fi

# ── The tools the %pre reads with are ordered ahead of it ────────────────────────────────────────
# The scriptlet reads a page through zcat and sed before base's files are placed, so without zcat this project's own
# gzip stub is refused; the Requires(pre) lines are what keep that state off a package host.
reset_names
gzip -c "${PAGE1_SRC}" > "${MAN1}/atr.1.gz"
run_pre "${TESTDIR}/bin-nozcat"
if (( status == 1 )) && grep -qF "the name ${MAN1}/atr.1.gz holds an entry" <<< "${err}"; then
    pass "with no zcat on PATH the scriptlet refuses this project's own gzip stub"
else
    fail "no zcat: exit ${status}, stderr [${err}]"
fi
preamble="$(awk '/^%package -n ai-tools-base$/{open=1; next} /^%(package|description)/{open=0} open' "${SPEC}")"
missing=""
for package in coreutils gzip sed; do
    grep -qE "^Requires\(pre\):[[:space:]]+${package}$" <<< "${preamble}" || missing+=" ${package}"
done
[[ -n "${preamble}" && -z "${missing}" ]] \
    && pass "ai-tools-base declares coreutils, gzip and sed under Requires(pre)" \
    || fail "ai-tools-base lacks Requires(pre) for:${missing:- (the preamble was not read)}"

finish
