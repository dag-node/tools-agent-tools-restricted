#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/spec-atr-names.sh
# Hermetic check of the ai-tools-base %pre in packaging/ai-tools.spec: it reads each name the short command atr takes
# and exits 1 at the first one in none of this project's forms, ahead of the account creation, a gzip stub that fails
# `gzip -t`, a page past 4096 bytes and a gzip page whose text is past 4096 bytes among them. The refusal does not start
# the relabel watcher %pretrans stopped, since rpm may still place the packages ordered after base, and names the check
# and the start to run once the transaction ends.
#
# A scriptlet runs inside an rpm transaction as root, so its body is read out of the spec as RPM parses it, its host
# paths rewritten to a fixture tree, and run under /bin/sh with getent, groupadd, useradd and systemctl defined as shell
# functions ahead of it, each recording its call. The wrapper's marker line names /usr/local/bin/atr as content, so it
# is kept out of the rewrite, and the rewritten body is checked for that before any case runs.
#
# Unprivileged, and reads the checkout alone; skips outside one.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="${ROOT}/packaging/ai-tools.spec"
WRAPPER_SRC="${ROOT}/src/usr/local/bin/atr.sh"
PAGE1_SRC="${ROOT}/src/usr/local/share/man/man1/atr.1"
PAGE8_SRC="${ROOT}/src/usr/local/share/man/man8/atr.8"
section "ai-tools-base %pre: a name atr takes is refused unless it is this project's, and the refusal leaves the relabel watcher alone (unit)"

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

FX="${TESTDIR}/root"
WRAPPER="${FX}/usr/local/bin/atr" LINK="${FX}/usr/sbin/atr"
MAN1="${FX}/usr/local/share/man/man1" MAN8="${FX}/usr/local/share/man/man8"
mkdir -p "${FX}/usr/local/bin" "${FX}/usr/sbin" "${MAN1}" "${MAN8}"

# The host paths become the fixture's; the marker is content, so it is set aside first and put back after.
marker='# /usr/local/bin/atr --'
body="${body//"${marker}"/"# @ATR-MARKER@ --"}"
body="${body//"/usr/local/bin/atr"/"${FX}/usr/local/bin/atr"}"
body="${body//"/usr/sbin/atr"/"${FX}/usr/sbin/atr"}"
body="${body//"/usr/local/share/man/"/"${FX}/usr/local/share/man/"}"
body="${body//"# @ATR-MARKER@ --"/"${marker}"}"
leftover="$(grep -nE '(^|[^[:alnum:]_/.-])/usr/(local/bin/atr|sbin/atr|local/share/man/)' <<< "${body}" \
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
systemctl() { printf "systemctl %s\n" "$*" >> "${STUB}/recorder"; }
'
stubs="${stubs//__STUB__/${TESTDIR}}"
printf '%s\n%s\n' "${stubs}" "${body}" > "${TESTDIR}/run.sh"
printf '  rewritten %%pre under test: %s\n' "${TESTDIR}/run.sh"

# The scriptlet's tools reach it through a PATH of links, so a case can leave one out.
mkdir -p "${TESTDIR}/bin-full" "${TESTDIR}/bin-nozcat"
for tool in sed readlink zcat gzip cat head od tr wc; do
    ln -s "$(type -P "${tool}")" "${TESTDIR}/bin-full/${tool}"
    [[ "${tool}" == zcat || "${tool}" == gzip ]] || ln -s "$(type -P "${tool}")" "${TESTDIR}/bin-nozcat/${tool}"
done

# reset_names: remove every name the scriptlet reads.
reset_names() { rm -rf "${WRAPPER}" "${LINK}" "${MAN1}"/atr.1* "${MAN8}"/atr.8*; }
# run_pre [path-dir]: run the scriptlet; sets status, recorder and err.
run_pre() {
    : > "${TESTDIR}/recorder"
    status=0
    env -i PATH="${1:-${TESTDIR}/bin-full}" /bin/sh "${TESTDIR}/run.sh" > "${TESTDIR}/out" 2> "${TESTDIR}/err" || status=$?
    recorder="$(cat "${TESTDIR}/recorder")"; err="$(cat "${TESTDIR}/err")"
}
account_created() { grep -qE '^(groupadd|useradd) ' <<< "${recorder}"; }
systemctl_calls() { grep -c '^systemctl ' <<< "${recorder}" || true; }
RECOVERY='ai-tools-base: this refusal does not start the relabel watcher the transaction stopped -- once the transaction'
RECOVERY+=' ends, check it with systemctl is-active ai-tools-relabel.path, and start it if it should run:'
readonly RECOVERY+=' systemctl start ai-tools-relabel.path'

# ── Names absent, or in this project's forms, pass ──────────────────────────────────────────────
reset_names
run_pre
if (( status == 0 )) && account_created && [[ "$(systemctl_calls)" == 0 && -z "${err}" ]]; then
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

# ── Each foreign entry refuses ahead of the account, and the watcher is left to the transaction's end ──
# place_foreign <what>: put one foreign entry in a tree otherwise empty, and print its path.
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
        gz-crc) { head -c "$(( WHOLE_SIZE - 8 ))" "${WHOLE_GZ}"; printf '\0\0\0\0'; tail -c 4 "${WHOLE_GZ}"; } \
                    > "${MAN1}/atr.1.gz"; printf '%s' "${MAN1}/atr.1.gz" ;;
        gz-cut) head -c "$(( WHOLE_SIZE - 8 ))" "${WHOLE_GZ}" > "${MAN1}/atr.1.gz"; printf '%s' "${MAN1}/atr.1.gz" ;;
        oversized) { cat "${PAGE1_SRC}"; head -c 4096 /dev/zero | tr '\0' 'x'; printf '\n'; } > "${MAN1}/atr.1"
                   printf '%s' "${MAN1}/atr.1" ;;
        gz-expands) { cat "${PAGE1_SRC}"; head -c 65536 /dev/zero | tr '\0' 'x'; printf '\n'; } | gzip -9 -c \
                        > "${MAN1}/atr.1.gz"
                    printf '%s' "${MAN1}/atr.1.gz" ;;
    esac
}
# A gzip stub whose CRC does not match, and one cut before its trailer, each decompress to the stub's .so line, which is
# read first as the control that the integrity test and not the text decides them.
WHOLE_GZ="${TESTDIR}/atr.1.whole.gz"
gzip -c "${PAGE1_SRC}" > "${WHOLE_GZ}"
WHOLE_SIZE="$(stat -c '%s' "${WHOLE_GZ}")"
for kind in gz-crc gz-cut; do
    path="$(place_foreign "${kind}")"
    prefix="$(gzip -dc -- "${path}" 2>/dev/null | sed -n '/^\.\\"/d;p;q')" || true
    if ! gzip -t -- "${path}" 2>/dev/null && [[ "${prefix}" == '.so man1/ai-tools.1' ]]; then
        pass "control: the ${kind} page fails gzip -t and decompresses to the stub's .so line"
    else
        fail "control: the ${kind} page reads '${prefix}', or passes gzip -t, so its case below cannot fail"
    fi
done
declare -A FOREIGN_WHAT=(
    [unmarked]="an unmarked regular file at the wrapper name" [directory]="a directory at the wrapper name"
    [link-elsewhere]="a symlink elsewhere at the link name" [file-at-link]="a regular file at the link name"
    [gz-without-so]="a gzip page without the .so line" [wrong-section]="a man8 page pointing at the man1 page"
    [xz]="an xz page, read as bytes" [gz-crc]="a gzip stub whose CRC does not match"
    [gz-cut]="a gzip stub cut before its trailer" [oversized]="a page opening with the stub's .so line, past 4096 bytes"
    [gz-expands]="a gzip page under 4096 bytes whose text opens with the .so line and is past 4096 bytes"
)
for kind in unmarked directory link-elsewhere file-at-link gz-without-so wrong-section xz gz-crc gz-cut oversized \
        gz-expands; do
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
    if [[ "$(systemctl_calls)" == 0 ]] && grep -qxF "${RECOVERY}" <<< "${err}"; then
        pass "${what}: no systemctl call, and the refusal names the check and the start for the transaction's end"
    else
        fail "${what}: systemctl calls [$(grep '^systemctl ' <<< "${recorder}" | tr '\n' ';')], stderr [${err}]"
    fi
done

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
reset_names
cp "${PAGE1_SRC}" "${MAN1}/atr.1"
run_pre "${TESTDIR}/bin-nozcat"
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "with no zcat on PATH a plain stub passes, read without a decompressor" \
    || fail "a plain stub with no zcat: exit ${status}, stderr [${err}]"
preamble="$(awk '/^%package -n ai-tools-base$/{open=1; next} /^%(package|description)/{open=0} open' "${SPEC}")"
missing=""
for package in coreutils gzip sed; do
    grep -qE "^Requires\(pre\):[[:space:]]+${package}$" <<< "${preamble}" || missing+=" ${package}"
done
[[ -n "${preamble}" && -z "${missing}" ]] \
    && pass "ai-tools-base declares coreutils, gzip and sed under Requires(pre)" \
    || fail "ai-tools-base lacks Requires(pre) for:${missing:- (the preamble was not read)}"

finish
