#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/shared-root.sh
# Unit test for the shared-root link (managed-assets.lib.sh): the step that points a path an agent reads a whole asset
# kind from -- codex's admin-scope skills directory, /etc/codex/skills -- at the live shared root, and its reverse
# for a package being erased. The path is one a host may already hold, so what gives the step teeth is what it leaves
# alone: each of the states the path can be in is driven, and every state but "absent" is asserted to leave
# what the host placed exactly as it was -- the entry, its target, the directory's own mode and entries --
# with the shared assets linked in only under a free name. The relabel is held to the same bound, against a stubbed
# restorecon: it covers the links placed, never the directory holding them. The reverse is asserted to remove our links
# alone.
#
# Pure: the shared root and the path are arguments, so the fixtures are a tree this file builds. Run without root:
# the function never re-owns or re-modes what it finds, so an unprivileged caller drives every state.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/src/usr/local/lib/ai-tools/managed-assets.lib.sh"
[[ -r "${LIB}" ]] || LIB="/usr/local/lib/ai-tools/managed-assets.lib.sh"

section "managed assets: the shared-root link and its reverse (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "shared-root link" "library not found at ${LIB}"; finish; exit
fi
# shellcheck source=../../src/usr/local/lib/ai-tools/managed-assets.lib.sh
if ! source "${LIB}" \
        || ! declare -F ai_tools_link_shared_root >/dev/null 2>&1 \
        || ! declare -F ai_tools_unlink_shared_root >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the shared-root link"; finish; exit
fi

mktestdir
SHARED="${TESTDIR}/opt/skills"
README="${TESTDIR}/share/README.md"
ETC="${TESTDIR}/etc/codex"
GROUP="$(id -gn)"

mkdir -p "${SHARED}/ai-tools-one" "${SHARED}/ai-tools-two" "${TESTDIR}/share" "${ETC}" "${TESTDIR}/elsewhere"
printf -- '---\nname: ai-tools-one\nx-ai-tools-managed: true\n---\n' > "${SHARED}/ai-tools-one/SKILL.md"
printf -- '---\nname: ai-tools-two\nx-ai-tools-managed: true\n---\n' > "${SHARED}/ai-tools-two/SKILL.md"
printf 'guide\n' > "${README}"
ln -s "${README}" "${SHARED}/README.md"

# run <path>: link the shared root at <path>, capturing the report.
run()   { ai_tools_link_shared_root "${SHARED}" "$1" "${GROUP}" "${README}" 2>&1; }
unrun() { ai_tools_unlink_shared_root "${SHARED}" "$1" "${README}" 2>&1; }

# ── absent -> a link to the shared root; a second run reports it current ─────────────────────
path="${ETC}/skills"
out="$(run "${path}")"
if [[ -L "${path}" && "$(readlink -- "${path}")" == "${SHARED}" ]] && grep -q 'skills linked ->' <<<"${out}"; then
    pass "absent: a symlink to the shared root is created and reported"
else
    fail "absent: expected a link to ${SHARED}, got '$(readlink -- "${path}" 2>/dev/null || echo none)': ${out}"
fi
out="$(run "${path}")"
[[ -L "${path}" && "$(readlink -- "${path}")" == "${SHARED}" ]] && grep -q 'skills current' <<<"${out}" \
    && pass "ours: a second run leaves the link and reports it current" \
    || fail "ours: the second run changed the link or did not report current: ${out}"
out="$(unrun "${path}")"
[[ ! -e "${path}" && ! -L "${path}" ]] && grep -q 'skills link removed' <<<"${out}" \
    && pass "reverse: our link to the shared root is removed" \
    || fail "reverse: the link to the shared root was not removed: ${out}"

# ── a symlink elsewhere -> the host's; left, reported, no link placed ─────────────────────────
ln -s "${TESTDIR}/elsewhere" "${path}"
out="$(run "${path}")"
if [[ -L "${path}" && "$(readlink -- "${path}")" == "${TESTDIR}/elsewhere" ]] \
        && [[ -z "$(ls -A "${TESTDIR}/elsewhere")" ]] && grep -q "skills kept (the host's own link" <<<"${out}"; then
    pass "a link elsewhere: left pointing where the host pointed it, nothing linked through it, reported"
else
    fail "a link elsewhere was changed or followed: target '$(readlink -- "${path}")', elsewhere holds '$(ls -A "${TESTDIR}/elsewhere")': ${out}"
fi
out="$(unrun "${path}")"
[[ -L "${path}" && "$(readlink -- "${path}")" == "${TESTDIR}/elsewhere" ]] \
    && pass "reverse: the host's link elsewhere is left alone" \
    || fail "reverse: the host's link elsewhere was removed"
rm -f "${path}"

# ── a regular file -> kept, reported ──────────────────────────────────────────────────────────
printf 'mine\n' > "${path}"
out="$(run "${path}")"
[[ -f "${path}" && ! -L "${path}" && "$(cat "${path}")" == "mine" ]] && grep -q 'skills kept (a file here wins' <<<"${out}" \
    && pass "a regular file: kept with its content, reported" \
    || fail "a regular file was displaced: ${out}"
rm -f "${path}"

# ── the parent absent -> no directory created, reported ─────────────────────────────────────
out="$(run "${TESTDIR}/no-such-dir/skills")"
[[ ! -e "${TESTDIR}/no-such-dir" ]] && grep -q 'skills not linked (' <<<"${out}" \
    && pass "an absent parent: no directory is created, reported" \
    || fail "an absent parent was created or not reported: ${out}"

# ── the shared root absent -> a no-op ────────────────────────────────────────────────────────
out="$(ai_tools_link_shared_root "${TESTDIR}/no-such-root" "${path}" "${GROUP}" 2>&1)"
[[ ! -e "${path}" && ! -L "${path}" && -z "${out}" ]] \
    && pass "an absent shared root: nothing is placed and nothing is reported" \
    || fail "an absent shared root placed or reported something: ${out}"

# ── a real directory -> kept as it is, the shared assets linked in one per free name ─────────
mkdir -p "${path}/ai-tools-one" "${path}/host-skill"
printf 'the host'"'"'s own\n' > "${path}/ai-tools-one/SKILL.md"
ln -s "${TESTDIR}/elsewhere" "${path}/ai-tools-two"          # a host link under a shipped name
ln -s "${SHARED}/ai-tools-gone" "${path}/ai-tools-gone"       # our link, its asset withdrawn
ln -s "${TESTDIR}/elsewhere/gone" "${path}/host-dangling"     # a host link, dangling
chmod 0711 "${path}"
out="$(run "${path}")"
[[ -d "${path}" && ! -L "${path}" && "$(perm "${path}")" == "711" ]] \
    && pass "a real directory: kept, its mode untouched (711 stays 711)" \
    || fail "a real directory was replaced or re-moded: $(stat -c '%F %a' "${path}" 2>/dev/null)"
[[ -f "${path}/ai-tools-one/SKILL.md" && "$(cat "${path}/ai-tools-one/SKILL.md")" == "the host's own" ]] \
    && grep -q 'ai-tools-one kept (a real entry here wins' <<<"${out}" \
    && pass "a real entry under a shipped name is kept and reported" \
    || fail "a real entry under a shipped name was displaced: ${out}"
[[ -L "${path}/ai-tools-two" && "$(readlink -- "${path}/ai-tools-two")" == "${TESTDIR}/elsewhere" ]] \
    && grep -q "ai-tools-two kept (the host's own link" <<<"${out}" \
    && pass "a host link under a shipped name is left pointing where it pointed, reported" \
    || fail "a host link under a shipped name was repointed: $(readlink -- "${path}/ai-tools-two"): ${out}"
[[ -d "${path}/host-skill" ]] \
    && pass "the host's own entry under its own name is untouched" \
    || fail "the host's own entry was removed"
[[ ! -L "${path}/ai-tools-gone" && ! -e "${path}/ai-tools-gone" ]] && grep -q 'ai-tools-gone link removed' <<<"${out}" \
    && pass "our link whose asset no longer ships is removed" \
    || fail "our dangling link into the shared root was left: ${out}"
[[ -L "${path}/host-dangling" ]] \
    && pass "a host link that dangles is left alone (it is not into the shared root)" \
    || fail "a host's dangling link was removed"
[[ -L "${path}/README.md" && "$(readlink -- "${path}/README.md")" == "${README}" ]] \
    && pass "the kind's README is linked under the free name" \
    || fail "README.md was not linked: $(readlink -- "${path}/README.md" 2>/dev/null || echo absent)"
before="$(find "${path}" -mindepth 1 -printf '%p %y %l\n' | sort)"
out="$(run "${path}")"
after="$(find "${path}" -mindepth 1 -printf '%p %y %l\n' | sort)"
[[ "${before}" == "${after}" ]] \
    && pass "a second run over the same directory changes nothing" \
    || fail "a second run changed the directory: $(diff <(echo "${before}") <(echo "${after}") | head -5 | tr '\n' '|')"
# The one shipped name that was free is now our link into the shared root.
[[ -L "${path}/ai-tools-one" ]] && fail "ai-tools-one became a link over the host's directory" || :
# A shipped asset whose name was free: add one and link it on the refresh.
mkdir -p "${SHARED}/ai-tools-three"; printf -- '---\nname: ai-tools-three\n---\n' > "${SHARED}/ai-tools-three/SKILL.md"
out="$(run "${path}")"
[[ -L "${path}/ai-tools-three" && "$(readlink -- "${path}/ai-tools-three")" == "${SHARED}/ai-tools-three" ]] \
    && grep -q 'ai-tools-three linked ->' <<<"${out}" \
    && pass "a shipped asset under a free name is linked into the host's directory" \
    || fail "a shipped asset under a free name was not linked: ${out}"
# A README the host already holds is not replaced.
rm -f "${path}/README.md"; printf 'host readme\n' > "${path}/README.md"
run "${path}" >/dev/null
[[ -f "${path}/README.md" && ! -L "${path}/README.md" ]] \
    && pass "a README the host holds is not replaced by the link" \
    || fail "the host's README was replaced"
rm -f "${path}/README.md"; ln -s "${README}" "${path}/README.md"

# ── the relabel covers the links placed, never the host's directory ─────────────────────────
# A relabel needs root and a labelled host, so `restorecon` is stubbed as a shell function and what is asserted is
# the argument list -- which is where this can go wrong: a `-R` over a host-owned directory relabels every entry
# the host put there, in the one branch whose contract is to leave them exactly as they are.
probe="${ETC}/probe-skills"
mkdir -p "${probe}/ai-tools-one"                              # one shipped name taken, so the placed set is a subset
args="${TESTDIR}/restorecon.args"
: > "${args}"
restorecon() { printf '%s\n' "$@" >> "${args}"; }
run "${probe}" >/dev/null
unset -f restorecon
got="$(sort "${args}")"
want="$(printf '%s\n' "${probe}/ai-tools-two" "${probe}/ai-tools-three" "${probe}/README.md" | sort)"
[[ "${got}" == "${want}" ]] \
    && pass "the relabel is given the links this run placed, one argument each" \
    || fail "restorecon was called with '$(tr '\n' ' ' <"${args}")', expected '$(tr '\n' ' ' <<<"${want}")'"
if ! grep -qxF -- '-R' "${args}" && ! grep -qxF -- "${probe}" "${args}"; then
    pass "neither the host's directory nor a recursive sweep of it reaches the relabel"
else
    fail "the host's directory was relabelled: $(tr '\n' ' ' <"${args}")"
fi

# ── reverse over the host's directory: our links go, the host's entries stay ────────────────
out="$(unrun "${path}")"
[[ -d "${path}" && -d "${path}/ai-tools-one" && -d "${path}/host-skill" && -L "${path}/ai-tools-two" && -L "${path}/host-dangling" ]] \
    && [[ ! -L "${path}/ai-tools-three" && ! -L "${path}/README.md" ]] \
    && grep -q 'ai-tools-three link removed' <<<"${out}" && grep -q 'README.md link removed' <<<"${out}" \
    && pass "reverse: our links into the shared root and the README link are removed; the directory and the host's entries stay" \
    || fail "reverse over the host's directory: $(find "${path}" -mindepth 1 -printf '%f %y\n' | sort | tr '\n' '|'): ${out}"

finish
