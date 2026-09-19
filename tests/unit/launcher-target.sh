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
# re-linked on the next run, so the step is idempotent across installs rather than once. The declared pattern is held
# to the containment the relabel holds it to before it is matched, so a pattern the relabel would refuse --
# an alternation, a group, no literal head -- is refused at the write rather than one launch later; that predicate lives
# beside the re-link, and its truth table is driven here against the shipped toolchain root.
#
# The order the two provisioning paths write that chain in is a property of the SCRIPTS rather than of any function --
# the repoint fires the relabel watcher, and the pin records what the stable link resolves to -- so it is read here
# as source order, and placed ahead of the fixture cases so it still runs where those skip.
#
# Pure: the three functions take the version directory, the launcher, the target, the pattern and the root as arguments,
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

# ── The containment predicate the re-link shares with the relabel ─────────────────────────────
# A declared entrypoint_fcontext becomes a `semanage fcontext` rule granting ai_tools_exec_t, the confined domain's exec
# entrypoint, so every way a pattern could name something outside the root it is checked against -- a traversal,
# an alternation, a group, a foreign or absent literal head -- must be refused. The root is an argument: relabel.lib.sh
# passes the toolchain root it pins, the re-link passes the directory the version directory sits in, and the table is
# driven here against the shipped root, so the fixture root this file's re-link cases use is not what containment is
# asserted on.
readonly TOOLCHAIN_ROOT=/opt/ai-tools/.nvm/versions/node
# accepts/rejects <pattern> [why]
accepts() {
    if ai_tools_entrypoint_fcontext_valid "$1" "${TOOLCHAIN_ROOT}"; then pass "accepts ${1:-<empty>}"
    else fail "rejected a valid entrypoint pattern: $1"; fi
}
rejects() {
    if ai_tools_entrypoint_fcontext_valid "$1" "${TOOLCHAIN_ROOT}"; then fail "ACCEPTED ${2}: ${1:-<empty>}"
    else pass "rejects ${2}"; fi
}

# The shipped shape, and the same path written without the SELinux backslash escapes.
accepts '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@anthropic-ai/claude-code/bin/claude\.exe'
accepts '/opt/ai-tools/.nvm/versions/node/[^/]+/bin/some-agent'

# Containment: every way a pattern could name something outside the root.
rejects ''                                              "an empty pattern"
rejects '/etc/shadow'                                   "a path outside the toolchain root"
rejects '/usr/bin/sudo'                                 "a host binary"
rejects '/opt/ai-tools/.nvm/versions/node/../../../usr/bin/sudo' "a parent-directory traversal"
rejects '/opt/ai-tools/.nvm/versions/node/x|/usr/bin/sudo'       "an alternation escaping the root"
rejects '(/usr/bin/sudo|/opt/ai-tools/.nvm/versions/node/x)'     "a group whose first branch is foreign"
rejects '(/opt/ai-tools/.nvm/versions/node/[^/]+/bin/x)'         "a group around a contained pattern"
rejects '.*'                                            "a match-anything pattern"
rejects '.*/bin/some-agent'                             "a pattern with no literal head"
# shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
rejects '/opt/ai-tools/.nvm/versions/node/$(id)/bin/x'  "a shell-substitution character"
rejects '/opt/ai-tools/.nvm/versions/node/a b/bin/x'    "whitespace in the pattern"

# The root is what the head is held to: a pattern contained under one root is refused under another, and an empty root
# refuses every pattern rather than anchoring the head at `/`.
if ai_tools_entrypoint_fcontext_valid '/opt/ai-tools/.nvm/versions/node/[^/]+/bin/x' /opt/other; then
    fail "ACCEPTED a pattern whose head is not the root it was checked against"
else pass "rejects a pattern whose head is another root"; fi
if ai_tools_entrypoint_fcontext_valid '/opt/ai-tools/.nvm/versions/node/[^/]+/bin/x' ''; then
    fail "ACCEPTED a pattern under an empty root"
else pass "rejects every pattern under an empty root"; fi

# ── The order both provisioning paths write the chain in ──────────────────────────────────────
# The re-link must precede the stable symlink's repoint, in the updater and in the bootstrap alike. The repoint is
# what fires the relabel watcher, and what the watcher pins is the file the stable link resolves to -- so a repoint made
# while the versioned launcher still pointed at npm's own entry file would pin the shim, and the next launch would
# refuse the toolchain the updater had just installed correctly. That ordering belongs to the two SCRIPTS, where no
# function holds it, so it is read as source order: driving it would take a real npm install of a shim-shaped package
# and a live handback socket, while each half of what the order protects is already covered on its own
# (integration/symlink-helper.sh for what the repoint accepts, integration/entrypoint-pin.sh for what the pin records).
# A file whose anchors are not found FAILS rather than skips -- a refactor that moved either call is exactly when this
# invariant needs asserting again -- and outside a checkout the whole section skips, there being no repository to read
# the scripts from.
#
# order_case <what> <repo-relative file> <relink-pattern> <repoint-pattern>
order_case() {
    local what="$1" file="${REPO_ROOT}/$2" relink="$3" repoint="$4" relink_line repoint_line
    if [[ ! -r "${file}" ]]; then
        fail "${what}: ${file} is not readable"
        return
    fi
    relink_line="$(grep -n -m1 -E -- "${relink}" "${file}" | cut -d: -f1)"
    repoint_line="$(grep -n -m1 -E -- "${repoint}" "${file}" | cut -d: -f1)"
    if [[ -z "${relink_line}" || -z "${repoint_line}" ]]; then
        fail "${what}: the re-link or the repoint is no longer where this reads it (re-link -> ${relink_line:-none}, repoint -> ${repoint_line:-none}) -- re-assert the order against the new shape"
    elif (( relink_line < repoint_line )); then
        pass "${what}: the versioned launcher is re-linked before the stable symlink is repointed"
    else
        fail "${what}: the stable symlink is repointed at line ${repoint_line}, ahead of the re-link at ${relink_line} -- the pin would record npm's own entry file"
    fi
}
if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    skip "the re-link precedes the repoint" "not a checkout, so the provisioning scripts cannot be read from the repository"
else
    order_case "the updater" src/opt/ai-tools/bin/nvm-update.sh \
        '^[[:space:]]+relink_agent_launchers ' 'ai-tools-handback-client SYMLINK "'
    order_case "the bootstrap" src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh \
        'ai_tools_relink_launcher "\$@"' 'ln -sfn "\$\{_launcher_bin\}"'
fi

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

relink "${ELF_TARGET}" "${VERSIONS_RE}/[^/]+/lib/[codex"
refused "a pattern bash cannot parse (an unclosed bracket, which the containment's charset admits)" MSG-F5U2

# The containment the relabel applies, applied at the write: each of these covers the resolved path as a raw regex,
# so a match alone would write the link and leave the refusal to the label preflight, one launch later.
relink "${ELF_TARGET}" "${FCONTEXT}|/nowhere/[^/]+/bin/codex"
refused "a pattern carrying an alternation whose first branch covers the target" MSG-F5U2
relink "${ELF_TARGET}" "(${FCONTEXT})"
refused "a pattern carrying a group around the covering pattern" MSG-F5U2
relink "${ELF_TARGET}" ".*/bin/codex"
refused "a pattern with no literal head" MSG-F5U2
relink "${ELF_TARGET}" "[^/]*${FCONTEXT}"
refused "a pattern whose head is a class, not the directory the version directory sits in" MSG-F5U2

# Two shapes the resolution already handles, pinned so a change to it is a decision rather than a drift: a version
# directory that is itself a symlink is resolved before the target is contained in it, and a symlink inside the version
# directory that resolves to another file inside it is followed and linked.
ln -sfn "${VERSION_DIR}" "${FIXTURE_ROOT}/versions/node/current"
RC=0; OUT="$(ai_tools_relink_launcher "${FIXTURE_ROOT}/versions/node/current" "${LAUNCHER}" "${ELF_TARGET}" "${FCONTEXT}" 2>"${TESTDIR}/err")" || RC=$?
ERR="$(<"${TESTDIR}/err")"
if [[ "${RC}" -eq 0 && "${OUT}" == linked && "$(realpath -e "${LINK}")" == "$(realpath -e "${ELF}")" ]]; then
    pass "a version directory that is itself a symlink: resolved, and the target linked inside the real one"
else fail "a symlinked version directory: rc ${RC}, stdout '${OUT}', stderr '${ERR}'"; fi
rm -f "${FIXTURE_ROOT}/versions/node/current"; reset_npm_link
ln -sfn codex "${VERSION_DIR}/${ELF_TARGET%/*}/codex-alias"
relink "${ELF_TARGET%/*}/codex-alias" "${FCONTEXT}"
if [[ "${RC}" -eq 0 && "${OUT}" == linked && "$(realpath -e "${LINK}")" == "$(realpath -e "${ELF}")" ]]; then
    pass "a symlink inside the version directory resolving to a file inside it: followed and linked"
else fail "an internal symlink target: rc ${RC}, stdout '${OUT}', stderr '${ERR}'"; fi
rm -f "${VERSION_DIR}/${ELF_TARGET%/*}/codex-alias"; reset_npm_link

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
#
# Driven AS THE PROJECTS USER when this suite runs as root, which it does for a full install: root ignores a directory's
# write bit, so the very write the case is about would succeed and the case would assert none of what it exists for.
# That is a vantage, not a state the host is in, so it is a `runuser` and not a skip (tests.rule.md). Unprivileged, this
# process is already the vantage the assertion is about and drives the library directly. The library is sourced fresh
# in the inner shell, since what is under test is the caller's own credentials against the directory mode.
if [[ "${EUID}" -ne 0 ]]; then
    chmod 0555 "${VERSION_DIR}/bin"
    relink "${ELF_TARGET}" "${FCONTEXT}"
    chmod 0755 "${VERSION_DIR}/bin"
    refused "an unwritable bin directory" MSG-A3S3
elif ! command -v runuser >/dev/null 2>&1; then
    skip "an unwritable bin directory" "runuser unavailable"
else
    # The fixture is built by root, so its directories carry root's umask and `mktemp -d` gives the fixture root 0700 --
    # neither of which the projects user can traverse. Every other case in this file is driven by root, which traverses
    # regardless, so the tree is opened for reading HERE, immediately before the one case that reads it as somebody
    # else. `a+rX` adds execute on directories alone, so the vendor binary keeps the mode the resolver asks about and no
    # plain file gains one.
    chmod -R a+rX "${FIXTURE_ROOT}"
    chmod 0555 "${VERSION_DIR}/bin"
    # The precondition, asserted rather than assumed: the resolver refuses a target it cannot resolve with the SAME code
    # it uses for one that is not executable, so a tree this account cannot read would report a refusal that looks like
    # the case passing for the wrong reason (MSG-C4F6 where MSG-A3S3 is the claim).
    if ! runuser -u "${PROJECTS_USER}" -- test -x "${VERSION_DIR}/${ELF_TARGET}"; then
        chmod 0755 "${VERSION_DIR}/bin"
        skip "an unwritable bin directory" \
             "${PROJECTS_USER} cannot read the fixture as executable, so the write is not what would refuse"
    else
        UNWRITABLE_ERR="${TESTDIR}/relink-unwritable.err"
        RC=0
        # shellcheck disable=SC2016  # $1..$5 are the inner shell's positionals, passed after `_`
        OUT="$(runuser -u "${PROJECTS_USER}" -- bash -c '
            source "$1" || exit 9
            ai_tools_relink_launcher "$2" "$3" "$4" "$5"' _ \
            "${LIB}" "${VERSION_DIR}" "${LAUNCHER}" "${ELF_TARGET}" "${FCONTEXT}" 2>"${UNWRITABLE_ERR}")" || RC=$?
        ERR="$(<"${UNWRITABLE_ERR}")"
        chmod 0755 "${VERSION_DIR}/bin"
        refused "an unwritable bin directory" MSG-A3S3
    fi
fi

finish
