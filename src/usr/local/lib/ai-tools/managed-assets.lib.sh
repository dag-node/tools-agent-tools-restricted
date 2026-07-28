#!/usr/bin/env bash
# /usr/local/lib/ai-tools/managed-assets.lib.sh
# Seeds the ai-tools-managed agents and skills, and links the SHARED skills into each agent.
#
# Skills are agent-agnostic content, so they are seeded ONCE into /opt/ai-tools/skills and each
# agent's own skills directory carries a SYMLINK per skill; agents are Claude Code-format files
# and are copied into that agent's config directory. Authoring or updating a skill is therefore
# one edit in one place, whatever number of agents read it.
# A managed asset is one whose name is `ai-tools-*` AND whose frontmatter carries
# `x-ai-tools-managed: true`; the seeder acts only on those, so an agent or skill the operator
# authored themselves is never claimed or overwritten. Seeded copies are root:SANDBOX_GROUP
# (files 640, dirs 750) under the setgid+sticky .claude -- locked from the agent, updated only
# through the root-run installer or `ai-tools-bootstrap`. Versioning is RFC-draft: the marker
# `x-ai-tools-version` is a monotonic integer bumped on every change, and a newer shipped version
# is what drives the update offer. This file is *sourced* (never executed); its consumers
# (install.sh, ai-tools-bootstrap) run as root and have already sourced msg.lib.sh. See
# shipped-assets.rule.md.

# Sourced more than once in a single shell: return early so the second pass is a no-op (an
# if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips set -e).
if [[ -n "${_AI_TOOLS_MANAGED_ASSETS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_MANAGED_ASSETS_LIB=1

# One plain progress line (captured into the install log / bootstrap output); the box is reserved
# for attention messages, so routine seed progress stays unframed.
_ai_tools_ma_say() { printf '  %s\n' "$*"; }

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

# Seed every managed agent/skill from a pristine source root into the live .claude. The source
# root holds `agents/ai-tools-*.md` and `skills/ai-tools-*/`; the live root is the caller/ai-tools/.claude.
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
        # agents are files (ai-tools-*.md); skills are directories (ai-tools-*/). README.md and any
        # non-ai-tools- entry are excluded by the glob, so they are never seeded.
        if [[ "${kind}" == agents ]]; then src_glob="${src_root}/agents/ai-tools-*.md"
        else src_glob="${src_root}/skills/ai-tools-*/"; fi
        for src in ${src_glob}; do
            [[ -e "${src}" ]] || continue                    # no matches -> literal pattern, skip
            name="$(basename "${src}")"
            # marker file carries the frontmatter: the agent file itself, or a skill's SKILL.md
            if [[ -d "${src}" ]]; then marker="${src%/}/SKILL.md"; else marker="${src}"; fi
            if ! ai_tools_asset_is_managed "${marker}"; then
                _ai_tools_ma_say "${kind}/${name} skipped (source not ai-tools-managed)"
                continue
            fi
            dst="${live_root}/${kind}/${name}"
            if [[ -d "${src}" ]]; then dst_marker="${dst}/SKILL.md"; else dst_marker="${dst}"; fi
            if [[ -e "${dst}" ]]; then
                if ! ai_tools_asset_is_managed "${dst_marker}"; then
                    _ai_tools_ma_say "${kind}/${name} kept (operator's own, not ai-tools-managed)"
                    continue
                fi
                cur="$(ai_tools_asset_version "${dst_marker}")"; new="$(ai_tools_asset_version "${marker}")"
                if [[ -n "${new}" && -n "${cur}" && "${new}" -gt "${cur}" ]]; then
                    if ai_tools_msg_confirm "Update ${name} (v${cur} -> v${new})?" n; then
                        _ai_tools_place_asset "${src%/}" "${dst}" "${group}"
                        _ai_tools_ma_say "${kind}/${name} updated (v${cur} -> v${new})"
                    else
                        _ai_tools_ma_say "${kind}/${name} kept (v${cur}; v${new} available)"
                    fi
                else
                    _ai_tools_ma_say "${kind}/${name} up to date (v${cur})"
                fi
            else
                _ai_tools_place_asset "${src%/}" "${dst}" "${group}"
                _ai_tools_ma_say "${kind}/${name} seeded (v${new:-?})"
            fi
        done
    done
}

# ai_tools_link_shared_skills <shared_root> <agent_skills_dir> <group> [readme_source]
# Point an agent at the shared skills: one symlink per skill directory under <shared_root>, so
# every agent reads the same file and a skill is updated in one place. Best-effort and
# idempotent, and it never displaces anything real:
#   * a name that does not exist in the agent's dir      -> symlink created
#   * a symlink already pointing at the shared skill      -> left alone
#   * a symlink into the shared root whose skill is gone  -> removed (a dropped shipped skill)
#   * anything else (a real directory or file)            -> KEPT and reported: it is either an
#                                                            agent-specific skill or the
#                                                            operator's own, and it wins
# The links are root-owned inside the agent's setgid+sticky config directory, so the agent reads
# and invokes them but cannot repoint one at a file of its choosing.
ai_tools_link_shared_skills() {
    local shared_root="$1" agent_skills_dir="$2" group="$3" readme_source="${4:-}"
    [[ -d "${shared_root}" ]] || return 0
    install -d -o root -g "${group}" -m 750 "${agent_skills_dir}"

    local src name dst linked=0
    for src in "${shared_root}"/*/; do
        [[ -d "${src}" ]] || continue                    # no matches -> literal pattern, skip
        src="${src%/}"; name="${src##*/}"
        dst="${agent_skills_dir}/${name}"
        if [[ -L "${dst}" ]]; then
            [[ "$(readlink -- "${dst}")" == "${src}" ]] && continue
            ln -sfn "${src}" "${dst}"
            _ai_tools_ma_say "skills/${name} link repointed at ${src}"
        elif [[ -e "${dst}" ]]; then
            _ai_tools_ma_say "skills/${name} kept (a real directory here wins over the shared skill)"
            continue
        else
            ln -s "${src}" "${dst}"
            _ai_tools_ma_say "skills/${name} linked -> ${src}"
        fi
        chown -h "root:${group}" "${dst}" 2>/dev/null || :
        linked=$(( linked + 1 ))
    done

    # Drop links into the shared root whose skill no longer ships, so a removed skill does not
    # leave a dangling entry the agent would try to read. A link pointing anywhere else is not
    # ours and is left alone.
    for dst in "${agent_skills_dir}"/*; do
        [[ -L "${dst}" ]] || continue
        src="$(readlink -- "${dst}")"
        [[ "${src}" == "${shared_root}/"* && ! -e "${src}" ]] || continue
        rm -f "${dst}"
        _ai_tools_ma_say "skills/${dst##*/} link removed (no longer shipped)"
    done

    ai_tools_link_asset_readme "${readme_source}" "${agent_skills_dir}" "${group}"
    restorecon -R "${agent_skills_dir}" >/dev/null 2>&1 || :
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
