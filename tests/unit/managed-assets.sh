#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/managed-assets.sh
# Unit test for the shipped-asset seeder and the withdrawal pass (managed-assets.lib.sh) -- the
# two passes that decide what skills and subagents every session on the host reads. Both run
# unattended in a package scriptlet with their output scrolling past in a dnf transaction, so
# every way either can go wrong is quiet, and each property below is one an operator would only
# discover much later:
#
#   1. THE MARKER IS THE CLAIM. An asset without `x-ai-tools-managed: true` is the operator's own
#      and is never overwritten by the seeder nor moved by the withdrawal. This is the whole of
#      what separates "this project's content" from "yours" -- both passes gate on it, so both
#      are driven against an unmanaged fixture.
#   2. THE UPDATE DEFAULT IS *UPDATE*, including with no terminal. A scriptlet has no tty, so the
#      default is what every packaged upgrade takes; when it was "keep", a host stayed on whatever
#      version it first seeded and was never told. Driven under `setsid` (no controlling terminal)
#      so a regression to keep fails here rather than on an operator's host months later.
#   3. A WITHDRAWN NAME IS NEVER SEEDED, whatever the source root holds. The root is not final when
#      seeding runs: rpm installs the new package's files first and removes the old package's only
#      at the end of the transaction, so the seeder sees the previous version's copy of an asset
#      this version withdrew. The fixtures reproduce exactly that state.
#   4. A REPORTED VERSION IS THE ASSET'S OWN. The version is read once and reported by two
#      branches, so a value read on only one path carries the previous asset's number into the
#      other -- right often enough to look correct. Asserted with an updated asset sorting BEFORE
#      a freshly seeded one, which is the order that reproduces it.
#   5. WITHDRAWAL PRESERVES. It moves rather than deletes, because a withdrawn asset has no shipped
#      counterpart left to compare an operator's edit against.
#
# Drives the INSTALLED library against fixtures in its own /tmp testdir: every root is an argument,
# so no case reads or writes /usr/share/ai-tools, /opt/ai-tools, or any live asset. Needs root --
# the seeder chowns what it places and the withdrawal creates a 0700 root:root directory.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB_DIR="/usr/local/lib/ai-tools"
section "managed assets: seeding + withdrawal (unit)"

for _lib in msg.lib.sh conf.lib.sh managed-assets.lib.sh; do
    if [[ ! -r "${LIB_DIR}/${_lib}" ]]; then
        skip "managed assets" "library not readable at ${LIB_DIR}/${_lib}"; finish; exit
    fi
done
# shellcheck source=/dev/null
if ! source "${LIB_DIR}/msg.lib.sh" \
        || ! source "${LIB_DIR}/conf.lib.sh" \
        || ! source "${LIB_DIR}/managed-assets.lib.sh" \
        || ! declare -F ai_tools_seed_managed_assets >/dev/null 2>&1 \
        || ! declare -F ai_tools_remove_retired_assets >/dev/null 2>&1; then
    fail "could not source the asset libraries or they do not define the seeder"; finish; exit
fi

mktestdir
SHIPPED="${TESTDIR}/shipped"
LIVE="${TESTDIR}/live"

# A withdrawn name has to come from the real AI_TOOLS_RETIRED_ASSETS list, which is `readonly` --
# so these fixtures pin the shipped list itself, not a copy of it.
readonly WITHDRAWN_SKILL="ai-tools-docs-reference"

# write_skill <root> <name> <version> [managed]  -- a directory asset with its SKILL.md marker.
write_skill() {
    local root="$1" name="$2" version="$3" managed="${4:-true}"
    mkdir -p "${root}/skills/${name}"
    {
        printf -- '---\n'
        printf 'name: %s\n' "${name}"
        [[ "${managed}" == "true" ]] && printf 'x-ai-tools-managed: true\n'
        printf 'x-ai-tools-version: %s\n' "${version}"
        printf -- '---\nbody of %s v%s\n' "${name}" "${version}"
    } > "${root}/skills/${name}/SKILL.md"
}

# write_subagent <root> <name> <version>  -- the FILE-per-asset kind, so the other branch of the
# seeder's directory-vs-file split is exercised too.
write_subagent() {
    local root="$1" name="$2" version="$3"
    mkdir -p "${root}/subagents"
    printf -- '---\nname: %s\nx-ai-tools-managed: true\nx-ai-tools-version: %s\n---\nbody\n' \
        "${name}" "${version}" > "${root}/subagents/${name}.md"
}

asset_version() { ai_tools_asset_version "$1"; }

reset_roots() { rm -rf "${SHIPPED}" "${LIVE}"; mkdir -p "${SHIPPED}" "${LIVE}"; }

# seed [env...] -- run the seeder over both kinds, capturing its report.
seed() { ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills subagents; }

# ── Seeding ──────────────────────────────────────────────────────────────────────

reset_roots
# Alphabetical order is glob order, so `aaa` (an UPDATE, which reads a version) runs before `zzz`
# (a fresh SEED, which reports one). That is the order in which a version read on only the update
# path leaks into the seed report.
write_skill "${SHIPPED}" ai-tools-aaa-updated 2
write_skill "${LIVE}"    ai-tools-aaa-updated 1
write_skill "${SHIPPED}" ai-tools-zzz-seeded  7
write_subagent "${SHIPPED}" ai-tools-sub-seeded 4

out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true

if [[ "$(asset_version "${LIVE}/skills/ai-tools-aaa-updated/SKILL.md")" == "2" ]]; then
    pass "an older live asset is updated to the shipped version"
else
    fail "the older live asset was not updated: ${out}"
fi
if [[ -f "${LIVE}/skills/ai-tools-zzz-seeded/SKILL.md" ]]; then
    pass "an absent asset is seeded"
else
    fail "the absent asset was not seeded: ${out}"
fi
if [[ -f "${LIVE}/subagents/ai-tools-sub-seeded.md" ]]; then
    pass "the file-per-asset kind (subagents) is seeded too"
else
    fail "the subagent file was not seeded: ${out}"
fi
# Property 4: the seed report must name 7, the asset's own version -- not 2, the one the update
# immediately before it read.
if grep -q 'ai-tools-zzz-seeded seeded (v7)' <<<"${out}"; then
    pass "a seeded asset reports its OWN version, not the previous iteration's"
else
    fail "the seed report carried the wrong version (expected v7): ${out}"
fi

# ── The update default, with no terminal ─────────────────────────────────────────
# Property 2. Driven WITHOUT AI_TOOLS_ASSUME_YES and under setsid, so there is no controlling
# terminal: ai_tools_msg_confirm cannot open /dev/tty and takes its default. That default must be
# UPDATE. setsid is also what keeps this from blocking -- the same call on a terminal would read
# /dev/tty and wait for an answer no test can give.
reset_roots
write_skill "${SHIPPED}" ai-tools-aaa-updated 5
write_skill "${LIVE}"    ai-tools-aaa-updated 4
setsid bash -c "
    source '${LIB_DIR}/msg.lib.sh'
    source '${LIB_DIR}/conf.lib.sh'
    source '${LIB_DIR}/managed-assets.lib.sh'
    ai_tools_seed_managed_assets '${SHIPPED}' '${LIVE}' root skills
" </dev/null >/dev/null 2>&1 || true
if [[ "$(asset_version "${LIVE}/skills/ai-tools-aaa-updated/SKILL.md")" == "5" ]]; then
    pass "with no terminal the update confirm defaults to UPDATE (a scriptlet takes the new version)"
else
    fail "a no-terminal run did not update -- the default has regressed to keep"
fi

# ── The marker gates the seeder ──────────────────────────────────────────────────
reset_roots
write_skill "${SHIPPED}" ai-tools-aaa-updated 9
write_skill "${LIVE}"    ai-tools-aaa-updated 1 notmanaged
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ "$(asset_version "${LIVE}/skills/ai-tools-aaa-updated/SKILL.md")" == "1" ]] \
   && grep -q "kept (operator's own" <<<"${out}"; then
    pass "an unmanaged live asset is left untouched and reported as the operator's own"
else
    fail "an unmanaged live asset was overwritten or not reported: ${out}"
fi

# A same-or-older shipped version is a no-op, so an operator is not told about a non-event.
reset_roots
write_skill "${SHIPPED}" ai-tools-aaa-updated 3
write_skill "${LIVE}"    ai-tools-aaa-updated 3
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if grep -q 'ai-tools-aaa-updated up to date (v3)' <<<"${out}"; then
    pass "a same-version asset is reported up to date and not replaced"
else
    fail "a same-version asset was not reported up to date: ${out}"
fi

# ── A withdrawn name is never seeded ─────────────────────────────────────────────
# Property 3, in the state that actually occurs: the source root STILL CARRIES the withdrawn asset,
# because rpm has not yet removed the previous package's files. Both directions are driven -- the
# live root missing it (which is where seeding it would be a real regression) and holding it (where
# reporting on it is the misleading half).
reset_roots
write_skill "${SHIPPED}" "${WITHDRAWN_SKILL}" 1
write_skill "${SHIPPED}" ai-tools-zzz-seeded  2
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ ! -e "${LIVE}/skills/${WITHDRAWN_SKILL}" ]]; then
    pass "a withdrawn asset in the source root is not seeded into a live root that lacks it"
else
    fail "the seeder placed a withdrawn asset: ${out}"
fi
if ! grep -q "${WITHDRAWN_SKILL}" <<<"${out}"; then
    pass "the seeder reports nothing at all for a withdrawn name"
else
    fail "the seeder reported a withdrawn asset it does not act on: ${out}"
fi
if [[ -f "${LIVE}/skills/ai-tools-zzz-seeded/SKILL.md" ]]; then
    pass "a withdrawn name does not stop the rest of the kind being seeded"
else
    fail "seeding stopped at the withdrawn name: ${out}"
fi

reset_roots
write_skill "${SHIPPED}" "${WITHDRAWN_SKILL}" 2
write_skill "${LIVE}"    "${WITHDRAWN_SKILL}" 1
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if ! grep -q "${WITHDRAWN_SKILL}" <<<"${out}" \
   && [[ "$(asset_version "${LIVE}/skills/${WITHDRAWN_SKILL}/SKILL.md")" == "1" ]]; then
    pass "a withdrawn name is neither updated nor reported, though a newer copy is shipped"
else
    fail "the seeder acted on or reported a withdrawn asset: ${out}"
fi

# ── Withdrawal ───────────────────────────────────────────────────────────────────
# Property 5, and the marker gate on this side. The live copy from the run above is still in place.
out="$(ai_tools_remove_retired_assets "${LIVE}" skills 2>&1)" || true
if [[ ! -e "${LIVE}/skills/${WITHDRAWN_SKILL}" ]]; then
    pass "a withdrawn asset is removed from the live root"
else
    fail "the withdrawn asset is still live: ${out}"
fi
mapfile -t retired < <(find "${LIVE}/retired" -maxdepth 1 -name "${WITHDRAWN_SKILL}.*.retired" 2>/dev/null)
if (( ${#retired[@]} == 1 )) && [[ -f "${retired[0]}/SKILL.md" ]]; then
    pass "it is MOVED to retired/, contents intact -- withdrawal preserves rather than deletes"
else
    fail "the withdrawn asset was not preserved under retired/: ${out}"
fi
# The copy is the operator's recovery material, so the directory holding it must be out of the
# sandbox account's reach.
if [[ "$(stat -c '%a %U' "${LIVE}/retired")" == "700 root" ]]; then
    pass "retired/ is 0700 root-owned (operator recovery material, unreachable from the sandbox)"
else
    fail "retired/ is $(stat -c '%a %U' "${LIVE}/retired"), expected 700 root"
fi

reset_roots
write_skill "${LIVE}" "${WITHDRAWN_SKILL}" 1 notmanaged
out="$(ai_tools_remove_retired_assets "${LIVE}" skills 2>&1)" || true
if [[ -f "${LIVE}/skills/${WITHDRAWN_SKILL}/SKILL.md" ]] \
   && grep -q "kept (operator's own" <<<"${out}"; then
    pass "an unmanaged asset under a withdrawn name is kept and reported, never moved"
else
    fail "an unmanaged asset under a withdrawn name was moved: ${out}"
fi

reset_roots
write_skill "${LIVE}" ai-tools-zzz-seeded 1
out="$(ai_tools_remove_retired_assets "${LIVE}" skills 2>&1)" || true
if [[ -f "${LIVE}/skills/ai-tools-zzz-seeded/SKILL.md" ]] && [[ ! -d "${LIVE}/retired" ]]; then
    pass "an asset that is not withdrawn is untouched, and retired/ is not created for nothing"
else
    fail "the withdrawal pass acted on an asset that is not withdrawn: ${out}"
fi

finish
