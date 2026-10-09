#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/managed-assets.sh
# Unit test for the shipped-asset seeder and the withdrawal pass (managed-assets.lib.sh), which decide what skills
# and subagents every session on the host reads. Each runs unattended in a package scriptlet with its output scrolling
# past in a dnf transaction, so every way either can go wrong is quiet, and each property is one an operator would only
# discover much later:
#
#   1. THE MARKER IS THE CLAIM. An asset without `x-ai-tools-managed: true` is the operator's own
#      and is never overwritten by the seeder nor moved by the withdrawal. This is the whole of
#      what separates "this project's content" from "yours" -- both passes gate on it, so each
#      is driven against an unmanaged fixture.
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
#   6. THE ORIENTATION LINK IS NON-DISPLACING, and links under a name that is not the source's.
#      It lands on the one path each agent reads as user-scope instructions, so a link placed over
#      an operator's own file there would silently replace what every session on the host loads.
#   7. AN ASSET BOUND TO AN INTEGRATION FOLLOWS ITS MANIFEST (shipped-assets.rule.md), whatever
#      the source root holds. Driven with the manifest absent, present, untrusted, and removed after
#      a seed, since an absent gate leaves every session listing a skill whose command the host lacks.
#
# Drives the INSTALLED library against fixtures in its own /tmp testdir: every root is an argument, so no case reads
# or writes /usr/share/ai-tools, /opt/ai-tools, or any live asset. Needs root -- the seeder chowns what it places
# and the withdrawal creates a 0700 root:root directory.

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

# A withdrawn name has to come from the real AI_TOOLS_RETIRED_ASSETS list, which is `readonly` -- so these fixtures pin
# the shipped list itself, not a copy of it.
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

# write_subagent <root> <name> <version>  -- the FILE-per-asset kind, so the other branch of the seeder's
# directory-vs-file split is exercised too.
write_subagent() {
    local root="$1" name="$2" version="$3"
    mkdir -p "${root}/subagents"
    printf -- '---\nname: %s\nx-ai-tools-managed: true\nx-ai-tools-version: %s\n---\nbody\n' \
        "${name}" "${version}" > "${root}/subagents/${name}.md"
}

# write_orientation <root> <version>  -- the fixed-name kind. Its marker rides in an HTML comment rather than YAML
# frontmatter, because every byte of this file is read by the model in every session; the seeder's line-anchored greps
# see it either way, which is what this fixture pins.
write_orientation() {
    local root="$1" version="$2"
    mkdir -p "${root}/orientation"
    printf -- '<!--\nx-ai-tools-managed: true\nx-ai-tools-version: %s\n-->\n\n# Sandbox boundaries\n' \
        "${version}" > "${root}/orientation/AGENTS.md"
}

asset_version() { ai_tools_asset_version "$1"; }

reset_roots() { rm -rf "${SHIPPED}" "${LIVE}"; mkdir -p "${SHIPPED}" "${LIVE}"; }

# seed [env...] -- run the seeder over both kinds, capturing its report.
seed() { ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills subagents; }

# ── Seeding ──────────────────────────────────────────────────────────────────────

reset_roots
# Alphabetical order is glob order, so `aaa` (an UPDATE, which reads a version) runs before `zzz` (a fresh SEED,
# which reports one). That is the order in which a version read on only the update path leaks into the seed report.
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
# Property 4: the seed report must name 7, the asset's own version -- not 2, the one the update immediately before it
# read.
if grep -q 'ai-tools-zzz-seeded seeded (v7)' <<<"${out}"; then
    pass "a seeded asset reports its OWN version, not the previous iteration's"
else
    fail "the seed report carried the wrong version (expected v7): ${out}"
fi

# ── The update default, with no terminal ─────────────────────────────────────────
# Property 2. Driven WITHOUT AI_TOOLS_ASSUME_YES and under setsid, so there is no controlling terminal:
# ai_tools_msg_confirm cannot open /dev/tty and takes its default. That default must be UPDATE. setsid is also
# what keeps this from blocking -- the same call on a terminal would read /dev/tty and wait for an answer no test can
# give.
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

# An empty directory at a skill's name holds nothing an operator wrote: it is seeded into, where reading it
# as the operator's own left the skill missing from every session with nothing to fill it. A directory holding any entry
# without the marker is still theirs.
reset_roots
write_skill "${SHIPPED}" ai-tools-aaa-updated 6
mkdir -p "${LIVE}/skills/ai-tools-aaa-updated"
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ "$(asset_version "${LIVE}/skills/ai-tools-aaa-updated/SKILL.md")" == "6" ]] \
   && grep -q 'ai-tools-aaa-updated seeded (v6) into an empty directory' <<<"${out}"; then
    pass "an empty live directory at a skill's name is seeded into and reported as such"
else
    fail "an empty live skill directory was not seeded: ${out}"
fi
reset_roots
write_skill "${SHIPPED}" ai-tools-aaa-updated 6
mkdir -p "${LIVE}/skills/ai-tools-aaa-updated"
printf 'mine\n' > "${LIVE}/skills/ai-tools-aaa-updated/notes.md"
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ ! -e "${LIVE}/skills/ai-tools-aaa-updated/SKILL.md" && -f "${LIVE}/skills/ai-tools-aaa-updated/notes.md" ]] \
   && grep -q "kept (operator's own" <<<"${out}"; then
    pass "a live directory holding a file without the marker is still the operator's own"
else
    fail "a non-empty unmarked live directory was claimed: ${out}"
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

# A marker with no version line reads as an empty version and returns 0: the seeder assigns the result under `set -e`,
# where a non-zero status from the grep pipeline would end the whole provisioning run on that one asset. The read is
# driven in a fresh strict-mode shell, which is where the status counts.
reset_roots
mkdir -p "${LIVE}/skills/ai-tools-unversioned"
printf -- '---\nname: ai-tools-unversioned\nx-ai-tools-managed: true\n---\nbody\n' \
    > "${LIVE}/skills/ai-tools-unversioned/SKILL.md"
out="$(bash -c 'set -euo pipefail; . "$1"; v="$(ai_tools_asset_version "$2")"; printf "version=[%s] survived" "${v}"' \
    _ "${LIB_DIR}/managed-assets.lib.sh" "${LIVE}/skills/ai-tools-unversioned/SKILL.md" 2>&1)" || true
if [[ "${out}" == "version=[] survived" ]]; then
    pass "a marker with no version line reads as empty under set -e without ending the shell"
else
    fail "reading a marker with no version line ended the shell or printed a version: ${out}"
fi

# ── A link at the name, a hard-linked copy ───────────────────────────────────────
# The view holds the assets resolver's links beside the seeded copies: a link at a seeded name is a set's copy
# of the asset, which the seeder neither reads a marker through nor replaces. And a copy whose file has a second hard
# link is not re-owned or re-moded, since the inode is reached from outside the copy.
reset_roots
write_skill "${SHIPPED}" ai-tools-linked 3
write_skill "${TESTDIR}/a-set" ai-tools-linked 1
mkdir -p "${LIVE}/skills"; ln -s "${TESTDIR}/a-set/skills/ai-tools-linked" "${LIVE}/skills/ai-tools-linked"
set_before="$(cat "${TESTDIR}/a-set/skills/ai-tools-linked/SKILL.md")"
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ "$(readlink "${LIVE}/skills/ai-tools-linked")" == "${TESTDIR}/a-set/skills/ai-tools-linked" \
        && "$(cat "${TESTDIR}/a-set/skills/ai-tools-linked/SKILL.md")" == "${set_before}" ]] \
        && grep -q 'ai-tools-linked skipped (a link stands at the name' <<<"${out}"; then
    pass "a link at a seeded name is skipped: neither replaced nor read through"
else
    fail "a link at a seeded name: $(ls -la "${LIVE}/skills" | tr '\n' '|') ${out}"
fi
reset_roots
write_skill "${SHIPPED}" ai-tools-hardlinked 2
write_skill "${LIVE}"    ai-tools-hardlinked 2
printf 'outside\n' > "${TESTDIR}/hardlink-sentinel"; chmod 0604 "${TESTDIR}/hardlink-sentinel"
ln "${TESTDIR}/hardlink-sentinel" "${LIVE}/skills/ai-tools-hardlinked/extra.md"
sentinel_before="$(stat -c '%U:%G %a %h' "${TESTDIR}/hardlink-sentinel")"
out="$(AI_TOOLS_ASSUME_YES=1 seed 2>&1)" || true
if [[ "$(stat -c '%U:%G %a %h' "${TESTDIR}/hardlink-sentinel")" == "${sentinel_before}" ]] \
        && grep -q 'has a second hard link' <<<"${out}"; then
    pass "a copy holding a hard-linked file keeps its owner and modes, and the report says why"
else
    fail "a hard-linked copy: the sentinel is now $(stat -c '%U:%G %a %h' "${TESTDIR}/hardlink-sentinel"): ${out}"
fi

# ── A withdrawn name is never seeded ─────────────────────────────────────────────
# Property 3, in the state that occurs: the source root STILL CARRIES the withdrawn asset, because rpm has not
# yet removed the previous package's files. Both directions are driven -- the live root missing it (which is
# where seeding it would be a real regression) and holding it (where reporting on it is the misleading half).
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
# Property 5, and the marker gate on this side. The live copy from the seeding run is still in place.
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
# The copy is the operator's recovery material, so the directory holding it must be out of the sandbox account's reach.
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

# ── An asset bound to an integration ─────────────────────────────────────────────
# Property 7. The marker names the integration; its manifest in the integrations directory is what "installed" means,
# and the directory is the resolver's own root-only hook, so a fixture directory stands in for the host's. A manifest
# the trust predicate refuses reads as not installed, the direction every other provider input takes.
if ! declare -F ai_tools_asset_integration >/dev/null 2>&1; then
    skip "integration-bound asset" "the installed library predates x-ai-tools-integration"
else
    INTEGRATIONS="${TESTDIR}/integrations.d"
    # write_bound_skill <root> <name> <version> <integration> [managed] -- a skill whose marker binds it
    # to an integration.
    write_bound_skill() {
        local root="$1" name="$2" version="$3" integration="$4" managed="${5:-true}"
        mkdir -p "${root}/skills/${name}"
        {
            printf -- '---\n'
            printf 'name: %s\n' "${name}"
            [[ "${managed}" == "true" ]] && printf 'x-ai-tools-managed: true\n'
            printf 'x-ai-tools-integration: %s\n' "${integration}"
            printf 'x-ai-tools-version: %s\n' "${version}"
            printf -- '---\nbody of %s v%s\n' "${name}" "${version}"
        } > "${root}/skills/${name}/SKILL.md"
    }
    # seed_bound -- the seeder over skills alone, reading the fixture integrations directory.
    seed_bound() { AI_TOOLS_INTEGRATIONS_DIR="${INTEGRATIONS}" AI_TOOLS_ASSUME_YES=1 \
        ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills; }

    reset_roots
    rm -rf "${INTEGRATIONS}"; mkdir -m 755 "${INTEGRATIONS}"
    write_bound_skill "${SHIPPED}" ai-tools-bound 1 acme
    write_skill "${SHIPPED}" ai-tools-unbound 1
    out="$(seed_bound 2>&1)" || true
    if [[ ! -e "${LIVE}/skills/ai-tools-bound" ]] && grep -q "ai-tools-bound skipped (integration acme not installed)" <<<"${out}"; then
        pass "a bound asset is not seeded while its integration's manifest is absent, and the skip names the integration"
    else
        fail "a bound asset was seeded without its integration, or the skip was not reported: ${out}"
    fi
    if [[ -f "${LIVE}/skills/ai-tools-unbound/SKILL.md" ]]; then
        pass "an unbound asset beside it is seeded as before"
    else
        fail "the gate stopped an unbound asset: ${out}"
    fi

    printf 'default_enable=no\n' > "${INTEGRATIONS}/acme.conf"; chmod 644 "${INTEGRATIONS}/acme.conf"
    out="$(seed_bound 2>&1)" || true
    if [[ "$(asset_version "${LIVE}/skills/ai-tools-bound/SKILL.md")" == "1" ]]; then
        pass "a bound asset is seeded once its integration's manifest is installed"
    else
        fail "a bound asset was not seeded with the manifest present: ${out}"
    fi

    chmod 664 "${INTEGRATIONS}/acme.conf"
    out="$(seed_bound 2>&1)" || true
    if [[ ! -e "${LIVE}/skills/ai-tools-bound" ]] && grep -q "ai-tools-bound withdrawn (integration acme not installed)" <<<"${out}"; then
        pass "a group-writable manifest reads as not installed, and the live copy is moved aside with the reason"
    else
        fail "an untrusted manifest kept the bound asset live: ${out}"
    fi
    mapfile -t retired < <(find "${LIVE}/retired" -maxdepth 1 -name "ai-tools-bound.*.retired" 2>/dev/null)
    if (( ${#retired[@]} == 1 )) && [[ -f "${retired[0]}/SKILL.md" ]]; then
        pass "the copy moved aside is preserved under retired/, as a withdrawal's is"
    else
        fail "the bound asset's live copy was not preserved: ${out}"
    fi

    chmod 644 "${INTEGRATIONS}/acme.conf"
    out="$(seed_bound 2>&1)" || true
    rm -f "${INTEGRATIONS}/acme.conf"
    out="$(seed_bound 2>&1)" || true
    if [[ ! -e "${LIVE}/skills/ai-tools-bound" ]] && grep -q "ai-tools-bound withdrawn (integration acme not installed)" <<<"${out}"; then
        pass "a live copy is moved aside once the manifest is removed, so an erased integration takes its skill with it"
    else
        fail "the live copy outlived its integration's manifest: ${out}"
    fi

    reset_roots
    write_bound_skill "${SHIPPED}" ai-tools-bound 1 acme
    write_bound_skill "${LIVE}" ai-tools-bound 1 acme notmanaged
    out="$(seed_bound 2>&1)" || true
    if [[ -f "${LIVE}/skills/ai-tools-bound/SKILL.md" ]] && grep -q "kept (operator's own" <<<"${out}"; then
        pass "an operator's own asset under a bound name is kept and reported when the integration is absent"
    else
        fail "an unmanaged asset under a bound name was moved: ${out}"
    fi
fi

# ── Orientation: a fixed-name asset, linked under each agent's own filename ──────
# Property 6. The seeding half first: the kind carries ONE file at a name the seeder knows, so the ai-tools-* namespace
# does not apply to it and the managed marker is the whole of what it claims by.
reset_roots
write_orientation "${SHIPPED}" 3
out="$(AI_TOOLS_ASSUME_YES=1 ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root orientation 2>&1)" || true
if [[ -f "${LIVE}/orientation/AGENTS.md" ]] \
   && [[ "$(asset_version "${LIVE}/orientation/AGENTS.md")" == "3" ]]; then
    pass "the fixed-name kind (orientation) is seeded, and its marker reads out of an HTML comment"
else
    fail "the orientation asset was not seeded: ${out}"
fi

# A managed asset the seeder keeps is still its to own: a copy of the tree, or a root edit, leaves one at an owner
# or mode the sessions cannot read it under, and the next run brings it back and says so. Driven over a file asset
# and a directory asset whose subdirectory carries an inherited setgid, since a four-digit chmod would leave that bit.
if ! id nobody >/dev/null 2>&1; then
    skip "ownership restored on a kept asset" "no 'nobody' account to drift the fixture to"
else
    write_skill "${SHIPPED}" ai-tools-owned 1
    out="$(AI_TOOLS_ASSUME_YES=1 ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills 2>&1)" || true
    chown nobody:nobody "${LIVE}/orientation/AGENTS.md"; chmod 600 "${LIVE}/orientation/AGENTS.md"
    mkdir -p "${LIVE}/skills/ai-tools-owned/references"; chmod 2775 "${LIVE}/skills/ai-tools-owned/references"
    chown nobody "${LIVE}/skills/ai-tools-owned/SKILL.md"
    out="$(AI_TOOLS_ASSUME_YES=1 ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills orientation 2>&1)" || true
    if [[ "$(stat -c '%a %U:%G' "${LIVE}/orientation/AGENTS.md")" == "640 root:root" ]] \
       && [[ "$(stat -c '%a %U:%G' "${LIVE}/skills/ai-tools-owned/SKILL.md")" == "640 root:root" ]] \
       && [[ "$(stat -c '%a' "${LIVE}/skills/ai-tools-owned/references")" == "750" ]] \
       && [[ "$(asset_version "${LIVE}/orientation/AGENTS.md")" == "3" ]]; then
        pass "a kept managed asset is brought back to root:group 640/750, an inherited setgid cleared, its content untouched"
    else
        fail "a kept asset's ownership was not restored: $(stat -c '%a %U:%G' "${LIVE}/orientation/AGENTS.md") / $(stat -c '%a %U:%G' "${LIVE}/skills/ai-tools-owned/SKILL.md") / $(stat -c '%a' "${LIVE}/skills/ai-tools-owned/references") (${out})"
    fi
    if [[ "$(grep -c 'ownership and modes restored' <<<"${out}")" -eq 2 ]]; then
        pass "each asset brought back is reported, and one already right is not"
    else
        fail "the restore report: ${out}"
    fi
    out="$(AI_TOOLS_ASSUME_YES=1 ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root skills orientation 2>&1)" || true
    if ! grep -q 'ownership and modes restored' <<<"${out}"; then
        pass "a second run over assets already at their ownership reports no restore"
    else
        fail "a clean run reported a restore: ${out}"
    fi
    # The linker's own fixture for the next section starts from a seeded orientation, which this left as seeded.
fi

if ! declare -F ai_tools_link_agent_memory >/dev/null 2>&1; then
    fail "the asset library does not define ai_tools_link_agent_memory"
else
    AGENT_DIR="${TESTDIR}/agent"; rm -rf "${AGENT_DIR}"; mkdir -p "${AGENT_DIR}"
    SHARED_FILE="${LIVE}/orientation/AGENTS.md"

    # The link's name comes from the agent's manifest, not from the source file, which is the whole reason this is not
    # one of the per-asset links: Claude Code reads CLAUDE.md and no other file at user scope, so a link named
    # for the source would never be loaded.
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ -L "${AGENT_DIR}/CLAUDE.md" ]] \
       && [[ "$(readlink -- "${AGENT_DIR}/CLAUDE.md")" == "${SHARED_FILE}" ]]; then
        pass "the shared orientation is linked under the name the agent reads (CLAUDE.md)"
    else
        fail "the orientation link was not placed under the manifest's name: ${out}"
    fi

    # Idempotent: a second run over a correct link neither replaces it nor reports anything.
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ -z "${out}" ]] && [[ -L "${AGENT_DIR}/CLAUDE.md" ]]; then
        pass "a link already pointing at the shared file is left alone and reported as nothing"
    else
        fail "a correct link was acted on or reported: ${out}"
    fi

    # A link left by an earlier layout points somewhere else; it is repointed rather than kept, or the agent goes
    # on loading a file this project no longer maintains.
    ln -sfn "${TESTDIR}/gone.md" "${AGENT_DIR}/CLAUDE.md"
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ "$(readlink -- "${AGENT_DIR}/CLAUDE.md")" == "${SHARED_FILE}" ]] \
       && grep -q 'repointed' <<<"${out}"; then
        pass "a stale link is repointed at the shared file and the change is reported"
    else
        fail "a stale orientation link was not repointed: ${out}"
    fi

    # The property that matters most: this path is the operator's user-scope instructions for every session on the host,
    # so anything REAL there wins and is reported, never displaced by a link.
    rm -f "${AGENT_DIR}/CLAUDE.md"
    printf 'the operator wrote this\n' > "${AGENT_DIR}/CLAUDE.md"
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ ! -L "${AGENT_DIR}/CLAUDE.md" ]] \
       && grep -q 'the operator wrote this' "${AGENT_DIR}/CLAUDE.md" \
       && grep -q 'kept (a real entry here wins' <<<"${out}"; then
        pass "a real file at the agent's memory path is kept and reported, never replaced by a link"
    else
        fail "an operator's own memory file was displaced by the shared link: ${out}"
    fi

    # The one real file that does not win: a byte-identical copy carrying the managed marker is this project's own text
    # -- a tree copied with its links dereferenced leaves one -- so it becomes the link with no content lost. A managed
    # copy that differs is an edit or version drift, and stays.
    rm -f "${AGENT_DIR}/CLAUDE.md"
    cp "${SHARED_FILE}" "${AGENT_DIR}/CLAUDE.md"
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ -L "${AGENT_DIR}/CLAUDE.md" ]] \
       && [[ "$(readlink -- "${AGENT_DIR}/CLAUDE.md")" == "${SHARED_FILE}" ]] \
       && grep -q 'converted to a link (was an identical managed copy)' <<<"${out}"; then
        pass "a managed, byte-identical copy at the memory path is converted to the link and reported"
    else
        fail "an identical managed copy was not converted to the link: ${out}"
    fi
    rm -f "${AGENT_DIR}/CLAUDE.md"
    { cat "${SHARED_FILE}"; printf 'an operator edit\n'; } > "${AGENT_DIR}/CLAUDE.md"
    out="$(ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" CLAUDE.md root 2>&1)" || true
    if [[ ! -L "${AGENT_DIR}/CLAUDE.md" ]] \
       && grep -q 'an operator edit' "${AGENT_DIR}/CLAUDE.md" \
       && grep -q 'kept (a real entry here wins' <<<"${out}"; then
        pass "a managed copy that differs from the shared text is kept, edit and all"
    else
        fail "a managed copy carrying an edit was displaced: ${out}"
    fi

    # An agent that does not declare a memory_file reaches the linker with an empty name (the resolver skips it,
    # but the guard is what keeps a bad manifest from writing to the directory itself).
    rm -f "${AGENT_DIR}/CLAUDE.md"
    ai_tools_link_agent_memory "${SHARED_FILE}" "${AGENT_DIR}" "" root >/dev/null 2>&1 || true
    if [[ -z "$(ls -A "${AGENT_DIR}")" ]]; then
        pass "no memory filename means no link, rather than a link under an empty name"
    else
        fail "the linker placed something for an agent that declares no memory file"
    fi
fi

# Property 7. THE KIND LIST IS THE TYPE. AI_TOOLS_ASSET_KINDS is the one declaration of what the project ships; a caller
# naming a kind outside it, or no kind at all, is refused with a reason rather than seeding less than it asked for.
# The seeder once defaulted to `agents`, a directory the tree never carried, so a caller relying on the default would
# have skipped the subagents and the orientation with no line saying so -- the quiet shape this refusal replaces.
write_skill "${SHIPPED}" ai-tools-kind-probe 1
out="$(ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root agents 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q 'agents is not an asset kind' <<<"${out}" \
   && [[ ! -e "${LIVE}/agents" ]]; then
    pass "a kind the project does not ship is refused by name, and nothing is seeded for it"
else
    fail "an unknown kind was not refused (rc=${rc}): ${out}"
fi
out="$(ai_tools_seed_managed_assets "${SHIPPED}" "${LIVE}" root 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q 'no asset kind named' <<<"${out}" \
   && [[ ! -e "${LIVE}/skills/ai-tools-kind-probe" ]]; then
    pass "an empty kind list is refused rather than defaulting to a set of the seeder's own"
else
    fail "an empty kind list was not refused (rc=${rc}): ${out}"
fi
out="$(ai_tools_remove_retired_assets "${LIVE}" agents 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q 'agents is not an asset kind' <<<"${out}"; then
    pass "the withdrawal pass holds the same kind list"
else
    fail "the withdrawal pass accepted an unknown kind (rc=${rc}): ${out}"
fi

# Property 8. THE FRONTMATTER IS YAML. A skill's and a subagent's frontmatter is read by the product that loads it
# and by a renderer that shows it, both as YAML, and the seeder's own greps are line-anchored and see the markers either
# way -- so a scalar broken by a continuation line at column one passes every other property here while the loader reads
# a truncated description. Parsed with PyYAML where the host has it; the name and the description must both survive
# the parse. Reads the repo source, falling back to the installed pristine copies, like the checker tests.
ASSET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/share/ai-tools"
[[ -d "${ASSET_ROOT}/skills" ]] || ASSET_ROOT="/usr/share/ai-tools"
if python3 -c 'import yaml' 2>/dev/null; then
    for asset in "${ASSET_ROOT}"/skills/*/SKILL.md "${ASSET_ROOT}"/subagents/ai-tools-*.md; do
        [[ -f "${asset}" ]] || continue
        if out="$(python3 - "${asset}" <<'EOF'
import re, sys, yaml
text = open(sys.argv[1]).read()
match = re.match(r"---\n(.*?)\n---\n", text, re.S)
if not match:
    sys.exit("no frontmatter")
data = yaml.safe_load(match.group(1))
for key in ("name", "description"):
    if not isinstance(data, dict) or not data.get(key):
        sys.exit(f"{key} missing after the parse")
EOF
        )"; then
            pass "frontmatter parses as YAML with name and description: ${asset##*/ai-tools/}"
        else
            fail "frontmatter of ${asset##*/ai-tools/}: ${out}"
        fi
    done
else
    skip "frontmatter YAML" "PyYAML not available to python3"
fi

finish
