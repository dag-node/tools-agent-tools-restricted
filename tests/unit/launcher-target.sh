#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/launcher-target.sh
# Unit test for the launcher-target re-link (providers.lib.sh): the write that points an agent's versioned launcher,
# <version-dir>/bin/<launcher>, at the executable its manifest declares, which the toolchain provisioning
# and the updater run after every install and before the stable symlink is repointed.
#
# What gives it teeth is where the link ends: the file the chain resolves to is the one execve transitions
# on, so a re-link that followed a target out of the version directory, onto a file the declared entrypoint pattern does
# not cover, or onto a file without the executable bit would hand the launch a chain the label preflight refuses --
# or, on a DAC-only host, an executable the manifest never named. Each refusal is therefore driven and asserted to leave
# npm's own link exactly as it was, printing nothing on stdout and its code on stderr; the accepted case is asserted
# through the same chain a launch reads (realpath), and a reinstall -- npm rewriting its link -- is asserted to be
# re-linked on the next run, so the step is idempotent across installs rather than once.
#
# Pure: the two functions take the version directory, the launcher, the target and the pattern as arguments,
# so the fixtures are a tree this file builds and no manifest is read. Run without root. The fixtures carry
# the executable bit, which the resolver asks about with `-x`, so they need a directory where that bit is VISIBLE:
# a noexec mount answers false whatever the mode says, so the testdir is used when it qualifies and a directory beside
# the operator's home otherwise, the fallback unit/agent-installs.sh takes for the same reason.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/providers.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/providers.lib.sh"

section "providers: the launcher target and the versioned launcher re-link (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "launcher target" "library not found at ${LIB}"; finish; exit
fi
# shellcheck source=../../src/usr/local/lib/ai-tools/providers.lib.sh
if ! source "${LIB}" \
        || ! declare -F ai_tools_launcher_target_valid >/dev/null 2>&1 \
        || ! declare -F ai_tools_relink_launcher >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the re-link functions"; finish; exit
fi

# ── The pure predicate ────────────────────────────────────────────────────────────────────────
valid() {
    local desc="$1" exp_rc="$2" value="${3-}"
    local rc=0; ai_tools_launcher_target_valid "${value}" || rc=$?
    if [[ "${rc}" -eq "${exp_rc}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${exp_rc}"; fi
}
valid "a relative path in the allowed charset"   0 "lib/node_modules/@x/codex/node_modules/@x/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
valid "empty -> refused"                          1 ""
valid "absolute -> refused"                       1 "/usr/bin/codex"
valid "a parent-directory component -> refused"   1 "lib/../../etc/passwd"
valid "a dotted run anywhere -> refused"          1 "lib/a..b/codex"
valid "a shell metacharacter -> refused"          1 "lib/x;rm"
valid "whitespace -> refused"                     1 "lib/x y"
valid "a glob character -> refused"               1 "lib/*/codex"
valid "a regex bracket -> refused"                1 "lib/[a]/codex"

# ── Fixtures: a version directory shaped like npm leaves it ───────────────────────────────────
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}

readonly LAUNCHER=codex
readonly SHIM_TARGET="../lib/node_modules/@x/codex/bin/codex.js"
readonly ELF_TARGET="lib/node_modules/@x/codex/node_modules/@x/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"

# build_tree <root>: <root>/versions/node/v1.2.3 holding npm's shim link, the shim, the vendor binary, and an executable
# outside the version directory for the escape case.
build_tree() {
    local ver="$1/versions/node/v1.2.3"
    mkdir -p "${ver}/bin" "${ver}/lib/node_modules/@x/codex/bin" "${ver}/${ELF_TARGET%/*}" "$1/outside"
    printf '#!/bin/sh\n' > "${ver}/lib/node_modules/@x/codex/bin/codex.js"; chmod 0755 "${ver}/lib/node_modules/@x/codex/bin/codex.js"
    printf '#!/bin/sh\n' > "${ver}/${ELF_TARGET}";                          chmod 0755 "${ver}/${ELF_TARGET}"
    printf '#!/bin/sh\n' > "$1/outside/tool";                                chmod 0755 "$1/outside/tool"
    ln -s "${SHIM_TARGET}" "${ver}/bin/${LAUNCHER}"
}

mktestdir
FIXTURE_ROOT="${TESTDIR}"
build_tree "${FIXTURE_ROOT}"
if ! x_bit_visible "${FIXTURE_ROOT}/outside"; then
    mk_fixture_dir FIXTURE_ROOT "${PROJECTS_HOME}" launchertarget 2>/dev/null || FIXTURE_ROOT=""
    if [[ -n "${FIXTURE_ROOT}" ]]; then
        chmod 0755 "${FIXTURE_ROOT}"
        build_tree "${FIXTURE_ROOT}"
    fi
fi
if [[ -z "${FIXTURE_ROOT}" ]] || ! x_bit_visible "${FIXTURE_ROOT}/outside"; then
    skip "launcher re-link" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi
VERSION_DIR="${FIXTURE_ROOT}/versions/node/v1.2.3"
LINK="${VERSION_DIR}/bin/${LAUNCHER}"
ELF="${VERSION_DIR}/${ELF_TARGET}"
# The declared pattern, written for the fixture root the way a manifest writes it for the toolchain: the literal head
# with its dots escaped, the version component as a class.
VERSIONS_RE="$(realpath -e "${FIXTURE_ROOT}/versions/node" | sed 's/\./\\./g')"
FCONTEXT="${VERSIONS_RE}/[^/]+/lib/node_modules/@x/codex/node_modules/@x/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"

# relink <target> <fcontext>: run the re-link, capturing stdout in OUT, stderr in ERR, the status in RC.
relink() {
    local err_file="${TESTDIR}/err"
    RC=0; OUT="$(ai_tools_relink_launcher "${VERSION_DIR}" "${LAUNCHER}" "$1" "$2" 2>"${err_file}")" || RC=$?
    ERR="$(<"${err_file}")"
}
# refused <what> <code>: the last relink returned 1, printed nothing on stdout and the code on stderr, left npm's link
# untouched, and left no temporary link beside it.
refused() {
    local what="$1" code="$2"
    if [[ "${RC}" -eq 1 && -z "${OUT}" ]]; then pass "${what}: refused (rc 1, empty stdout)"
    else fail "${what}: rc ${RC}, stdout '${OUT}'"; fi
    assert_msg "${code}" "${ERR}" "${what}: reports its code"
    if [[ "$(readlink -- "${LINK}")" == "${SHIM_TARGET}" ]]; then pass "${what}: npm's link is left in place"
    else fail "${what}: the launcher now reads $(readlink -- "${LINK}" || echo '<gone>')"; fi
    if compgen -G "${VERSION_DIR}/bin/.${LAUNCHER}.*" >/dev/null; then fail "${what}: a temporary link was left behind"
    else pass "${what}: no temporary link left behind"; fi
    reset_npm_link   # a case that wrongly linked is reported once, not by every case after it
}
# reset_npm_link: what `npm install -g` leaves -- the shim link, whatever was there before.
reset_npm_link() { ln -sfn "${SHIM_TARGET}" "${LINK}"; }

# ── (A) A target inside the version directory is linked, through the chain a launch reads ────
relink "${ELF_TARGET}" "${FCONTEXT}"
if [[ "${RC}" -eq 0 && "${OUT}" == linked ]]; then pass "a target inside the version directory: linked"
else fail "a target inside the version directory: rc ${RC}, stdout '${OUT}', stderr '${ERR}'"; fi
if [[ "$(readlink -- "${LINK}")" == "../${ELF_TARGET}" ]]; then pass "the link is relative, npm's own form"
else fail "the link reads $(readlink -- "${LINK}")"; fi
if [[ "$(realpath -e "${LINK}")" == "$(realpath -e "${ELF}")" ]]; then pass "the launcher resolves to the declared executable"
else fail "the launcher resolves to $(realpath -e "${LINK}" || echo '<unresolvable>')"; fi
if [[ -z "${ERR}" ]]; then pass "an accepted target reports no refusal"; else fail "stderr on the accepted case: ${ERR}"; fi

# ── (B) Idempotent on the same state, and again after a reinstall ─────────────────────────────
relink "${ELF_TARGET}" "${FCONTEXT}"
if [[ "${RC}" -eq 0 && "${OUT}" == current ]]; then pass "a link already at the target: current, not rewritten"
else fail "second run: rc ${RC}, stdout '${OUT}'"; fi
reset_npm_link
relink "${ELF_TARGET}" "${FCONTEXT}"
if [[ "${RC}" -eq 0 && "${OUT}" == linked && "$(readlink -- "${LINK}")" == "../${ELF_TARGET}" ]]; then
    pass "after npm rewrote its link, the next run re-links"
else fail "after a reinstall: rc ${RC}, stdout '${OUT}', link $(readlink -- "${LINK}")"; fi
reset_npm_link

# ── (C) Every refusal leaves npm's link in place ──────────────────────────────────────────────
relink "../outside/tool" "${FCONTEXT}"
refused "a target with a parent-directory component" MSG-J5C3

ln -s "../../../../../outside/tool" "${VERSION_DIR}/lib/escape"
relink "lib/escape" "${FCONTEXT}"
refused "a target that resolves outside the version directory through a symlink" MSG-C4F6
rm -f "${VERSION_DIR}/lib/escape"

relink "lib/node_modules/@x/codex/bin/missing" "${FCONTEXT}"
refused "a target that does not exist" MSG-C4F6

chmod 0644 "${ELF}"
relink "${ELF_TARGET}" "${FCONTEXT}"
refused "a target without the executable bit" MSG-C4F6
chmod 0755 "${ELF}"

mkdir -p "${VERSION_DIR}/lib/dir"
relink "lib/dir" "${FCONTEXT}"
refused "a target that is a directory" MSG-C4F6

relink "${ELF_TARGET}" "${VERSIONS_RE}/[^/]+/lib/node_modules/@x/codex/bin/codex\\.js"
refused "a target the declared entrypoint pattern does not cover" MSG-F5U2

relink "${ELF_TARGET}" ""
refused "a manifest declaring no entrypoint pattern" MSG-F5U2

relink "${ELF_TARGET}" "${VERSIONS_RE}/[^/]+/lib/node_modules/@x/codex/("
refused "a pattern bash cannot parse" MSG-F5U2

# A regular file where the launcher belongs is a hand-edited tree, and the write stops ahead of the rename.
rm -f "${LINK}"; printf 'kept\n' > "${LINK}"
relink "${ELF_TARGET}" "${FCONTEXT}"
if [[ "${RC}" -eq 1 && -z "${OUT}" && "$(<"${LINK}")" == kept ]]; then pass "a regular file at the launcher path: refused, file intact"
else fail "a regular file at the launcher path: rc ${RC}, stdout '${OUT}', content '$(<"${LINK}" 2>/dev/null)'"; fi
assert_msg MSG-W4H3 "${ERR}" "a regular file at the launcher path: reports its code"
rm -f "${LINK}"; reset_npm_link

# A dangling link is npm's link to a file the install did not leave, and is replaced like any other symlink.
ln -sfn "../lib/node_modules/@x/codex/bin/gone" "${LINK}"
relink "${ELF_TARGET}" "${FCONTEXT}"
if [[ "${RC}" -eq 0 && "${OUT}" == linked && "$(realpath -e "${LINK}")" == "$(realpath -e "${ELF}")" ]]; then
    pass "a dangling launcher link is replaced"
else fail "a dangling launcher link: rc ${RC}, stdout '${OUT}'"; fi
reset_npm_link

# A bin directory this account has no write permission on refuses at the write, reporting it, with the link as it was.
# Root writes anywhere, so the case is driven only where the mode holds.
chmod 0555 "${VERSION_DIR}/bin"
if touch "${VERSION_DIR}/bin/.probe" 2>/dev/null; then
    rm -f "${VERSION_DIR}/bin/.probe"; chmod 0755 "${VERSION_DIR}/bin"
    skip "an unwritable bin directory" "this account writes a 0555 directory (root)"
else
    relink "${ELF_TARGET}" "${FCONTEXT}"
    chmod 0755 "${VERSION_DIR}/bin"
    refused "an unwritable bin directory" MSG-A3S3
fi

finish
