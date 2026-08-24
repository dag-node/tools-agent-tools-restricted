#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/managed-assets.lib.sh
# Seeds the ai-tools-managed agents and skills, and links the SHARED skills into each agent.
#
# Skills are agent-agnostic content, so they are seeded ONCE into /opt/ai-tools/skills and each
# agent's own skills directory carries a SYMLINK per skill; agents are Claude Code-format files
# and are copied into that agent's config directory. Authoring or updating a skill is therefore
# one edit in one place, whatever number of agents read it.
# A managed asset is one whose name is `ai-tools-*` AND whose frontmatter carries
# `x-ai-tools-managed: true`; the seeder acts only on those, so an asset the operator authored
# themselves is never claimed or overwritten. Seeded copies are root:SANDBOX_GROUP (files 640,
# dirs 750) in their shared root -- locked from the agent, updated only through the root-run
# installer or `ai-tools-bootstrap`. Versioning is RFC-draft: the marker
# `x-ai-tools-version` is a monotonic integer bumped on every change, and a newer shipped version
# is what drives the update offer. This file is *sourced* (never executed); its consumers
# (install.sh, ai-tools-bootstrap) run as root and have already sourced msg.lib.sh. See
# shipped-assets.rule.md.

# Withdrawing an asset needs its own step: the seeder only adds and updates, and the live roots are
# not rpm-owned, so a name this project stops shipping stays live on an upgraded host until it is
# named here. `ai_tools_remove_retired_assets` reads this list; the linker then drops each agent's
# now-dangling symlink on its next run.
#
# Sourced more than once in a single shell: return early so the second pass is a no-op (an
# if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips set -e).
if [[ -n "${_AI_TOOLS_MANAGED_ASSETS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_MANAGED_ASSETS_LIB=1

# One plain progress line (captured into the install log / bootstrap output); the box is reserved
# for attention messages, so routine seed progress stays unframed.
# Per-asset status, printed under the directory heading its caller emitted: indented one level
# further and naming the asset alone, so the listing reads as entries of that directory rather
# than as a flat list that repeats the directory on every line.
_ai_tools_ma_say() { printf '      %s\n' "$*"; }

# Assets this project has withdrawn, as `<kind>/<name>` entries. An entry stays listed for as long
# as a host may still carry it from an older package.
# shellcheck disable=SC2034  # read by ai_tools_remove_retired_assets below
readonly AI_TOOLS_RETIRED_ASSETS=(
    "skills/ai-tools-docs-reference"
    "skills/ai-tools-docs-usage"
    "skills/ai-tools-docs-comments"
    "skills/ai-tools-docs-changelog"
)

# Print the integer x-ai-tools-version from a managed asset's marker file; empty if absent.
ai_tools_asset_version() {
    grep -m1 -E '^x-ai-tools-version:' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -n1
}

# True when the marker file declares this asset ai-tools-managed.
ai_tools_asset_is_managed() {
    grep -qE '^x-ai-tools-managed:[[:space:]]*true[[:space:]]*$' "$1" 2>/dev/null
}

# Copy one asset from source to live, owned root:<group>, files 640 / dirs 750. A file (agent)
# installs directly; a directory (skill) is replaced whole so a removed source file cannot linger.
# $1 src (file|dir)  $2 dst (file|dir)  $3 group
_ai_tools_place_asset() {
    local src="$1" dst="$2" group="$3"
    if [[ -d "${src}" ]]; then
        rm -rf "${dst}"
        cp -rT "${src}" "${dst}"
        chown -R "root:${group}" "${dst}"
        find "${dst}" -type d -exec chmod 750 {} +
        find "${dst}" -type f -exec chmod 640 {} +
    else
        install -o root -g "${group}" -m 640 "${src}" "${dst}"
    fi
    restorecon -R "${dst}" >/dev/null 2>&1 || :
}

# Seed every managed asset of the named kinds from a pristine source root into a live root. The
# source root holds one directory per kind -- `skills/ai-tools-*/` (a directory per asset),
# `subagents/ai-tools-*.md` (a file per asset); the live root is the caller's.
# Absent live asset -> seeded. Present + managed + a newer shipped version -> a keep/update prompt
# defaulting to keep (so Enter and any non-interactive run never clobber an operator-tuned copy).
# Present + unmanaged (no marker) -> left untouched and logged: it is the operator's own file.
# Present + same-or-older version -> no-op.
# $1 src_root  $2 live_root (resolved by the caller)  $3 group  $4.. kinds (default: both)
ai_tools_seed_managed_assets() {
    local src_root="$1" live_root="$2" group="$3"; shift 3
    local -a kinds=( "$@" ); (( ${#kinds[@]} )) || kinds=( agents skills )
    local kind src_glob src marker name dst dst_marker cur new
    for kind in "${kinds[@]}"; do
        [[ -d "${src_root}/${kind}" ]] || continue
        install -d -o root -g "${group}" -m 750 "${live_root}/${kind}"
        # A kind is carried either as one FILE per asset or as one DIRECTORY per asset, and the
        # glob has to match: subagents are files (ai-tools-*.md), skills are directories
        # (ai-tools-*/). README.md and any non-ai-tools- entry fall outside both globs, so they
        # are never seeded.
        case "${kind}" in
            subagents) src_glob="${src_root}/${kind}/ai-tools-*.md" ;;
            *)         src_glob="${src_root}/${kind}/ai-tools-*/"  ;;
        esac
        for src in ${src_glob}; do
            [[ -e "${src}" ]] || continue                    # no matches -> literal pattern, skip
            name="$(basename "${src}")"
            # marker file carries the frontmatter: the agent file itself, or a skill's SKILL.md
            if [[ -d "${src}" ]]; then marker="${src%/}/SKILL.md"; else marker="${src}"; fi
            if ! ai_tools_asset_is_managed "${marker}"; then
                _ai_tools_ma_say "${name} skipped (source not ai-tools-managed)"
                continue
            fi
            dst="${live_root}/${kind}/${name}"
            if [[ -d "${src}" ]]; then dst_marker="${dst}/SKILL.md"; else dst_marker="${dst}"; fi
            if [[ -e "${dst}" ]]; then
                if ! ai_tools_asset_is_managed "${dst_marker}"; then
                    _ai_tools_ma_say "${name} kept (operator's own, not ai-tools-managed)"
                    continue
                fi
                cur="$(ai_tools_asset_version "${dst_marker}")"; new="$(ai_tools_asset_version "${marker}")"
                if [[ -n "${new}" && -n "${cur}" && "${new}" -gt "${cur}" ]]; then
                    if ai_tools_msg_confirm "Update ${name} (v${cur} -> v${new})?" n; then
                        _ai_tools_place_asset "${src%/}" "${dst}" "${group}"
                        _ai_tools_ma_say "${name} updated (v${cur} -> v${new})"
                    else
                        _ai_tools_ma_say "${name} kept (v${cur}; v${new} available)"
                    fi
                else
                    _ai_tools_ma_say "${name} up to date (v${cur})"
                fi
            else
                _ai_tools_place_asset "${src%/}" "${dst}" "${group}"
                _ai_tools_ma_say "${name} seeded (v${new:-?})"
            fi
        done
    done
}

# ai_tools_remove_retired_assets <live_root> [kinds...]
# Remove the assets in AI_TOOLS_RETIRED_ASSETS from a live shared root, so a host upgraded from a
# package that still shipped them stops offering them. Restricted to the named kinds when given.
#
# Removal requires the x-ai-tools-managed marker, so an asset the operator authored under the same
# name is kept and reported -- the same predicate the seeder uses to decide what it may claim.
# Each agent's symlink is left to `ai_tools_link_shared_assets`, which drops a link into the shared
# root once its target is gone.
# $1 live_root  $2.. kinds (default: every kind named in the list)
ai_tools_remove_retired_assets() {
    local live_root="$1"; shift
    local -a kinds=( "$@" )
    local entry kind name path marker
    for entry in "${AI_TOOLS_RETIRED_ASSETS[@]}"; do
        kind="${entry%%/*}"; name="${entry#*/}"
        if (( ${#kinds[@]} )); then
            local wanted match=0
            for wanted in "${kinds[@]}"; do
                [[ "${wanted}" == "${kind}" ]] && { match=1; break; }
            done
            (( match )) || continue
        fi
        path="${live_root}/${kind}/${name}"
        [[ -e "${path}" ]] || continue
        marker="${path}"; [[ -d "${path}" ]] && marker="${path}/SKILL.md"
        if ! ai_tools_asset_is_managed "${marker}"; then
            _ai_tools_ma_say "${name} kept (operator's own, not ai-tools-managed)"
            continue
        fi
        rm -rf "${path}"
        _ai_tools_ma_say "${name} removed (no longer shipped)"
    done
}

# _ai_tools_asset_is_stale_copy <shared> <live> : true when <live> is a copy this project placed
# under the pre-shared layout and is byte-identical to <shared> -- i.e. replacing it with a link
# loses nothing. Requires BOTH the ai-tools-managed marker (so an operator's own asset is never
# touched) and identical content (so an edited or drifted copy is never discarded). Without the
# comparison tools it answers false, keeping the copy.
_ai_tools_asset_is_stale_copy() {
    local shared="$1" live="$2" marker="$2"
    [[ -d "${live}" ]] && marker="${live}/SKILL.md"
    ai_tools_asset_is_managed "${marker}" || return 1
    if [[ -d "${shared}" && -d "${live}" ]]; then
        command -v diff >/dev/null 2>&1 || return 1
        diff -rq "${shared}" "${live}" >/dev/null 2>&1
    elif [[ -f "${shared}" && -f "${live}" ]]; then
        cmp -s "${shared}" "${live}"
    else
        return 1
    fi
}

# ai_tools_link_shared_assets <shared_root> <agent_dir> <group> [readme_source]
# Point an agent at a shared asset kind (skills, subagents): one symlink per entry under
# <shared_root>, so every agent reads the same file and an asset is updated in one place.
# Best-effort and idempotent, and it never displaces anything real:
#   * a name that does not exist in the agent's dir      -> symlink created
#   * a symlink already pointing at the shared asset      -> left alone
#   * a symlink into the shared root whose asset is gone  -> removed (a dropped shipped asset)
#   * anything else (a real directory or file)            -> KEPT and reported: it is either an
#                                                            agent-specific asset or the
#                                                            operator's own, and it wins
# The links are root-owned inside the agent's setgid+sticky config directory, so the agent reads
# and invokes them but cannot repoint one at a file of its choosing.
ai_tools_link_shared_assets() {
    local shared_root="$1" agent_dir="$2" group="$3" readme_source="${4:-}"
    [[ -d "${shared_root}" ]] || return 0
    install -d -o root -g "${group}" -m 750 "${agent_dir}"

    # Every entry, whatever shape the kind uses: a skill is a directory, a subagent is a file.
    # The kind's README is linked separately (below), so it is not treated as an asset.
    local src name dst linked=0
    for src in "${shared_root}"/*; do
        [[ -e "${src}" ]] || continue                    # no matches -> literal pattern, skip
        name="${src##*/}"
        [[ "${name}" == README.md ]] && continue
        dst="${agent_dir}/${name}"
        if [[ -L "${dst}" ]]; then
            [[ "$(readlink -- "${dst}")" == "${src}" ]] && continue
            ln -sfn "${src}" "${dst}"
            _ai_tools_ma_say "${name} link repointed at ${src}"
        elif [[ -e "${dst}" ]]; then
            # Something real sits here. It is either the operator's own (or agent-specific)
            # asset, which always wins -- or OUR copy from the layout before these assets were
            # shared, which should become a link so the shared file is the only one to maintain.
            # Convert only when it is BOTH ai-tools-managed and byte-identical to the shared
            # copy: same provenance, nothing to lose. A managed copy that differs is left alone
            # and reported, because the difference is either an operator edit or version drift,
            # and this is not the place to resolve either.
            if _ai_tools_asset_is_stale_copy "${src}" "${dst}"; then
                rm -rf "${dst}"
                ln -s "${src}" "${dst}"
                _ai_tools_ma_say "${name} converted to a link (was an identical managed copy)"
            else
                _ai_tools_ma_say "${name} kept (a real entry here wins over the shared one)"
                continue
            fi
        else
            ln -s "${src}" "${dst}"
            _ai_tools_ma_say "${name} linked -> ${src}"
        fi
        chown -h "root:${group}" "${dst}" 2>/dev/null || :
        linked=$(( linked + 1 ))
    done

    # Drop links into the shared root whose skill no longer ships, so a removed skill does not
    # leave a dangling entry the agent would try to read. A link pointing anywhere else is not
    # ours and is left alone.
    for dst in "${agent_dir}"/*; do
        [[ -L "${dst}" ]] || continue
        src="$(readlink -- "${dst}")"
        [[ "${src}" == "${shared_root}/"* && ! -e "${src}" ]] || continue
        rm -f "${dst}"
        _ai_tools_ma_say "${dst##*/} link removed (no longer shipped)"
    done

    ai_tools_link_asset_readme "${readme_source}" "${agent_dir}" "${group}"
    restorecon -R "${agent_dir}" >/dev/null 2>&1 || :
    return 0
}

# ai_tools_link_asset_readme <readme_source> <target_dir> <group>
# Point <target_dir>/README.md at the shipped guide for that asset kind, so the documentation is
# found where the assets are rather than only in the datadir. A link, never a copy, so there is
# one file to keep current. Silent no-op when either end is absent.
ai_tools_link_asset_readme() {
    local readme_source="$1" target_dir="$2" group="$3"
    [[ -n "${readme_source}" && -e "${readme_source}" && -d "${target_dir}" ]] || return 0
    ln -sfn "${readme_source}" "${target_dir}/README.md"
    chown -h "root:${group}" "${target_dir}/README.md" 2>/dev/null || :
    return 0
}
