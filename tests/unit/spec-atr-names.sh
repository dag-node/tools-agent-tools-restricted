#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/spec-atr-names.sh
# Hermetic check of the ai-tools-base %pre in packaging/ai-tools.spec: it reads each name the short command atr takes
# and exits 1 at the first one in none of this project's forms, ahead of the account creation, a page adding lines
# after the stub's request, a compressed stub that fails its tool's `-t`, a page past 4096 bytes and a gzip page
# whose text is past 4096 bytes among them. The stub in gzip, bzip2, xz and zstd passes, and one read with its tool
# absent from PATH exits 1 under MSG-V2H5. Another executable named atr in a command directory of the default PATHs
# exits 1 under MSG-E7B3, and this project's own entries there pass. The refusal does not start the relabel watcher
# or the relabel run %pretrans stopped, since rpm may still place the packages ordered after base, and names the check
# of the watcher and the start of both to run once the transaction ends.
#
# A scriptlet runs inside an rpm transaction as root, so its body is read out of the spec as RPM parses it, its host
# paths rewritten to a fixture tree, and run under /bin/sh with getent, groupadd, useradd and systemctl defined as shell
# functions ahead of it, each recording its call. The wrapper's marker line names /usr/local/bin/atr as content, so it
# is kept out of the rewrite, and the rewritten body is checked for that, and for a command run by its absolute path,
# which no stub intercepts, before any case runs.
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

# The shadowing check asks `[ -x ]` of each command directory's atr, so the fixture root takes a directory where a 0755
# file reads as executable: the testdir where it does, a directory beside the projects user's home otherwise,
# the fallback tests/unit/agent-installs.sh takes. With none, the shadowing cases are skip_required. x_bit_visible
# <dir>: succeed when a 0755 file created there reads as executable.
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
WRAPPER="${FX}/usr/local/bin/atr" LINK="${FX}/usr/sbin/atr"
MAN1="${FX}/usr/local/share/man/man1" MAN8="${FX}/usr/local/share/man/man8"
mkdir -p "${FX}/usr/local/bin" "${FX}/usr/sbin" "${FX}/usr/bin" "${FX}/usr/local/sbin" "${FX}/bin" "${FX}/sbin" \
    "${MAN1}" "${MAN8}"
chmod 0755 "${BASE}" "${FX}"

# The command directories the shadowing check reads are install.sh's ATR_COMMAND_DIRS, and become the fixture's.
command_dirs_line="_atr_command_dirs='/usr/local/sbin /usr/bin /usr/sbin /bin /sbin'"
installer_dirs="$(sed -n 's/^ATR_COMMAND_DIRS=(\(.*\))$/\1/p' "${ROOT}/install.sh")"
if grep -qxF "${command_dirs_line}" <<< "${body}" && [[ "${command_dirs_line}" == *"'${installer_dirs}'" ]]; then
    pass "the %pre reads the command directories install.sh's ATR_COMMAND_DIRS names"
else
    fail "the %pre's command directories and install.sh's (${installer_dirs:-not read}) differ, or the line moved"
    finish; exit
fi
body="${body//"${command_dirs_line}"/"_atr_command_dirs='${FX}/usr/local/sbin ${FX}/usr/bin ${FX}/usr/sbin ${FX}/bin ${FX}/sbin'"}"

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

# A stub is a shell function, which a command named by its absolute path bypasses, reaching the host's own tool as root.
# find_absolute_commands <script> prints each code line that runs a command from a system directory by its path:
# at the start of a command, after a separator or a keyword. A path passed as an argument or tested with `[ -x ]` is
# not a command. The reader runs over a control first, then over the body, which does not run when it finds one.
find_absolute_commands() {
    local start='(^|[;&|(`]|\$\(|(then|do|else|elif|if|while|until|!|exec|command)[[:space:]])'
    grep -nE "${start}[[:space:]]*/(usr/)?(s?bin|libexec)/[[:alnum:]]" <<< "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true
}
control=$'/usr/bin/systemctl start x\nif /usr/bin/systemctl is-active x; then :; fi\na && /bin/systemctl start x\n'
control+=$'y="$(/usr/sbin/foo)"\nsystemctl start x\nuseradd -s \'/sbin/nologin\' x\n'
control+=$'[ -x /usr/bin/systemctl ]\n# /usr/bin/x\n'
found="$(find_absolute_commands "${control}" | cut -d: -f1 | tr '\n' ' ')"
if [[ "${found}" == '1 2 3 4 ' ]]; then
    pass "control: the reader finds a system command run by its path, and not an argument, a test or a comment"
else
    fail "control: the reader found lines [${found}] of the control, expected [1 2 3 4]"
    finish; exit
fi
injected="$(find_absolute_commands "${body}"$'\n    /usr/bin/systemctl start ai-tools-relabel.path')"
[[ "${injected}" == *'/usr/bin/systemctl start ai-tools-relabel.path'* ]] \
    && pass "control: a call by path added to the body is found" \
    || fail "control: a call by path added to the body is not found, so the check below cannot fail"
absolute="$(find_absolute_commands "${body}")"
if [[ -z "${absolute}" ]]; then
    pass "the body runs no command from a system directory by its path, so every call reaches a stub"
else
    fail "the body runs a command by its path, which no stub intercepts, so it is not run: ${absolute//$'\n'/ | }"
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
mkdir -p "${TESTDIR}/bin-full" "${TESTDIR}/bin-nocompressors"
for tool in sed readlink cat head od tr wc gzip bzip2 xz zstd; do
    tool_path="$(type -P "${tool}")" || continue
    ln -s "${tool_path}" "${TESTDIR}/bin-full/${tool}"
    case "${tool}" in gzip|bzip2|xz|zstd) ;; *) ln -s "${tool_path}" "${TESTDIR}/bin-nocompressors/${tool}" ;; esac
done

# reset_names: remove every name the scriptlet reads, the other commands' included.
reset_names() {
    rm -rf "${WRAPPER}" "${LINK}" "${MAN1}"/atr.1* "${MAN8}"/atr.8* "${FX}/usr/bin/atr" "${FX}/usr/local/sbin/atr" \
        "${FX}/bin/atr" "${FX}/sbin/atr"
}
# run_base_pre_scriptlet [path-dir]: run the scriptlet; sets status, recorder and err.
run_base_pre_scriptlet() {
    : > "${TESTDIR}/recorder"
    status=0
    env -i PATH="${1:-${TESTDIR}/bin-full}" /bin/sh "${TESTDIR}/run.sh" > "${TESTDIR}/out" 2> "${TESTDIR}/err" || status=$?
    recorder="$(cat "${TESTDIR}/recorder")"; err="$(cat "${TESTDIR}/err")"
}
account_created() { grep -qE '^(groupadd|useradd) ' <<< "${recorder}"; }
systemctl_calls() { grep -c '^systemctl ' <<< "${recorder}" || true; }
RECOVERY='ai-tools-base: this refusal does not start the relabel watcher or the relabel run the transaction stopped --'
RECOVERY+=' once the transaction ends, check the watcher with systemctl is-active ai-tools-relabel.path, and where it'
readonly RECOVERY+=' should run, start both: systemctl start ai-tools-relabel.path ai-tools-relabel.service'

# ── Names absent, or in this project's forms, pass ──────────────────────────────────────────────
reset_names
run_base_pre_scriptlet
if (( status == 0 )) && account_created && [[ "$(systemctl_calls)" == 0 && -z "${err}" ]]; then
    pass "every name absent: exit 0, the account is created, the watcher is left to %posttrans"
else
    fail "every name absent: exit ${status}, stderr [${err}], calls [${recorder//$'\n'/; }]"
fi

cp "${WRAPPER_SRC}" "${WRAPPER}"
ln -s ../local/bin/atr "${LINK}"
cp "${PAGE1_SRC}" "${MAN1}/atr.1"; gzip -c "${PAGE1_SRC}" > "${MAN1}/atr.1.gz"
cp "${PAGE8_SRC}" "${MAN8}/atr.8"; gzip -c "${PAGE8_SRC}" > "${MAN8}/atr.8.gz"
run_base_pre_scriptlet
(( status == 0 )) && account_created && [[ -z "${err}" ]] \
    && pass "the shipped wrapper, the ln -sr link and both stubs plain and gzip-compressed pass" \
    || fail "this project's forms: exit ${status}, stderr [${err}]"

rm -f "${WRAPPER}" "${LINK}"; ln -s "${WRAPPER}" "${LINK}"
run_base_pre_scriptlet
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "the link by its absolute target, dangling, passes" \
    || fail "the absolute dangling link: exit ${status}, stderr [${err}]"

{ sed -n '1,3p' "${WRAPPER_SRC}"; printf 'echo other content\n'; } > "${WRAPPER}"
run_base_pre_scriptlet
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "a marked wrapper with other content passes, as this project's name" \
    || fail "the marked wrapper: exit ${status}, stderr [${err}]"

# ── Each foreign entry refuses ahead of the account, and the watcher is left to the transaction's end ──
# create_foreign_entry <what>: put one foreign entry in a tree otherwise empty, and print its path.
create_foreign_entry() {
    reset_names
    case "$1" in
        unmarked) printf '#!/bin/sh\necho another tool\n' > "${WRAPPER}"; printf '%s' "${WRAPPER}" ;;
        directory) mkdir "${WRAPPER}"; printf '%s' "${WRAPPER}" ;;
        link-elsewhere) ln -s /usr/bin/at "${LINK}"; printf '%s' "${LINK}" ;;
        file-at-link) : > "${LINK}"; printf '%s' "${LINK}" ;;
        gz-without-so) printf '.TH ATR 1\n.SH NAME\natr \\- another tool\n' | gzip -c > "${MAN1}/atr.1.gz"; printf '%s' "${MAN1}/atr.1.gz" ;;
        wrong-section) cp "${PAGE1_SRC}" "${MAN8}/atr.8"; printf '%s' "${MAN8}/atr.8" ;;
        xz-without-so) printf '.TH ATR 8\n' | xz -c > "${MAN8}/atr.8.xz"; printf '%s' "${MAN8}/atr.8.xz" ;;
        added-lines) { cat "${PAGE1_SRC}"; printf '.SH LOCAL NOTES\nadded on this host\n'; } > "${MAN1}/atr.1"
                     printf '%s' "${MAN1}/atr.1" ;;
        gz-added-lines) { cat "${PAGE1_SRC}"; printf '.SH LOCAL NOTES\nadded on this host\n'; } | gzip -c \
                            > "${MAN1}/atr.1.gz"
                        printf '%s' "${MAN1}/atr.1.gz" ;;
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
    path="$(create_foreign_entry "${kind}")"
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
    [xz-without-so]="an xz page without the .so line"
    [added-lines]="the man1 stub with lines added after the .so request"
    [gz-added-lines]="the same page, gzip-compressed" [gz-crc]="a gzip stub whose CRC does not match"
    [gz-cut]="a gzip stub cut before its trailer" [oversized]="a page opening with the stub's .so line, past 4096 bytes"
    [gz-expands]="a gzip page under 4096 bytes whose text opens with the .so line and is past 4096 bytes"
)
for kind in unmarked directory link-elsewhere file-at-link gz-without-so wrong-section xz-without-so added-lines \
        gz-added-lines gz-crc gz-cut oversized \
        gz-expands; do
    what="${FOREIGN_WHAT[${kind}]}"
    path="$(create_foreign_entry "${kind}")"
    run_base_pre_scriptlet
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

# ── Another program named atr on the default PATHs refuses, and this project's own entries do not ───
if (( XBIT == 0 )); then
    skip_required "the shadowing cases" "no directory here reports a 0755 file as executable (a noexec mount)"
else
    reset_names
    cp "${WRAPPER_SRC}" "${WRAPPER}"; chmod 0755 "${WRAPPER}"
    ln -s ../local/bin/atr "${LINK}"; ln -s ../bin/atr "${FX}/usr/local/sbin/atr"
    run_base_pre_scriptlet
    (( status == 0 )) && [[ -z "${err}" ]] \
        && pass "the link at /usr/sbin and a merged /usr/local/sbin, each the wrapper, are this project's and pass" \
        || fail "this project's own command entries: exit ${status}, stderr [${err}]"
    for dir in usr/bin bin sbin usr/local/sbin; do
        reset_names
        cp "${WRAPPER_SRC}" "${WRAPPER}"; chmod 0755 "${WRAPPER}"
        printf '#!/bin/sh\necho another atr\n' > "${FX}/${dir}/atr"; chmod 0755 "${FX}/${dir}/atr"
        run_base_pre_scriptlet
        assert_msg MSG-E7B3 "${err}" "another atr at /${dir}: refused under its code"
        if (( status == 1 )) && grep -qF "another program answers to atr at ${FX}/${dir}/atr" <<< "${err}" \
                && grep -qxF "${RECOVERY}" <<< "${err}" && ! account_created && [[ "$(systemctl_calls)" == 0 ]]; then
            pass "another atr at /${dir}: exit 1 naming it, ahead of the account creation, with the recovery line"
        else
            fail "another atr at /${dir}: exit ${status}, stderr [${err}]"
        fi
    done
    reset_names
    printf 'not a program\n' > "${FX}/usr/bin/atr"; chmod 0644 "${FX}/usr/bin/atr"
    mkdir "${FX}/bin/atr"
    run_base_pre_scriptlet
    (( status == 0 )) && [[ -z "${err}" ]] \
        && pass "a file without an execute bit and a directory named atr are not commands, and pass" \
        || fail "a non-command named atr: exit ${status}, stderr [${err}]"
    rmdir "${FX}/bin/atr"
fi

# ── Each compression man reads is read, and a page whose tool is absent is not decided ──────────
# The stub recompressed in another format is this project's, and the same page read with no decompressor on PATH is
# refused under the unreadable code, naming the tool, beside a plain stub as the control. The Requires(pre) lines keep
# gzip on a package host; the other tools are named when a page needs one. A format whose tool this host lacks is
# skipped.
for tool in gzip:gz bzip2:bz2 xz:xz zstd:zst; do
    if ! command -v "${tool%%:*}" >/dev/null 2>&1; then
        skip "the ${tool%%:*} stub" "${tool%%:*} is not installed on this host"
        continue
    fi
    reset_names
    "${tool%%:*}" -c < "${PAGE8_SRC}" > "${MAN8}/atr.8.${tool#*:}"
    run_base_pre_scriptlet
    (( status == 0 )) && [[ -z "${err}" ]] \
        && pass "the man8 stub, ${tool%%:*}-compressed, passes" \
        || fail "the ${tool%%:*} stub: exit ${status}, stderr [${err}]"
    run_base_pre_scriptlet "${TESTDIR}/bin-nocompressors"
    assert_msg MSG-V2H5 "${err}" "the ${tool%%:*} stub with no ${tool%%:*} on PATH: refused as unreadable"
    if (( status == 1 )) && grep -qF "the name ${MAN8}/atr.8.${tool#*:} is a page in ${tool%%:*} compression and ${tool%%:*} is not on PATH" <<< "${err}" \
            && grep -qxF "${RECOVERY}" <<< "${err}" && ! account_created; then
        pass "the ${tool%%:*} stub with no ${tool%%:*} on PATH: exit 1 naming the tool, ahead of the account creation"
    else
        fail "the ${tool%%:*} stub with no ${tool%%:*}: exit ${status}, stderr [${err}]"
    fi
    whole_size="$(stat -c '%s' "${MAN8}/atr.8.${tool#*:}")"
    head -c "$(( whole_size - 4 ))" "${MAN8}/atr.8.${tool#*:}" > "${TESTDIR}/atr-cut"
    mv "${TESTDIR}/atr-cut" "${MAN8}/atr.8.${tool#*:}"
    run_base_pre_scriptlet
    assert_msg MSG-W5Z8 "${err}" "the ${tool%%:*} stub cut before its end: refused as another's"
done
reset_names
cp "${PAGE1_SRC}" "${MAN1}/atr.1"
run_base_pre_scriptlet "${TESTDIR}/bin-nocompressors"
(( status == 0 )) && [[ -z "${err}" ]] \
    && pass "with no decompressor on PATH a plain stub passes, read without one" \
    || fail "a plain stub with no decompressor: exit ${status}, stderr [${err}]"
preamble="$(awk '/^%package -n ai-tools-base$/{open=1; next} /^%(package|description)/{open=0} open' "${SPEC}")"
missing=""
for package in coreutils gzip sed; do
    grep -qE "^Requires\(pre\):[[:space:]]+${package}$" <<< "${preamble}" || missing+=" ${package}"
done
[[ -n "${preamble}" && -z "${missing}" ]] \
    && pass "ai-tools-base declares coreutils, gzip and sed under Requires(pre)" \
    || fail "ai-tools-base lacks Requires(pre) for:${missing:- (the preamble was not read)}"

finish
