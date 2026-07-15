#!/usr/bin/env bash
# /usr/local/lib/ai-tools/managed-assets.lib.sh
# Seeds the ai-tools-managed agents and skills into the live control plane (/opt/ai-tools/.claude).
# A managed asset is one whose name is `ai-tools-*` AND whose frontmatter carries
# `x-ai-tools-managed: true`; the seeder acts only on those, so an agent or skill the operator
# authored themselves is never claimed or overwritten. Seeded copies are root:SANDBOX_GROUP
# (files 640, dirs 750) under the setgid+sticky .claude -- locked from the agent, updated only
# through the root-run installer or `ai-tools-bootstrap`. Versioning is RFC-draft: the marker
# `x-ai-tools-version` is a monotonic integer bumped on every change, and a newer shipped version
# is what drives the update offer. This file is *sourced* (never executed); its consumers
# (install.sh, ai-tools-bootstrap) run as root and have already sourced msg.lib.sh. See
# shipped-claude-assets.rule.md.

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
# root holds `agents/ai-tools-*.md` and `skills/ai-tools-*/`; the live root is /opt/ai-tools/.claude.
# Absent live asset -> seeded. Present + managed + a newer shipped version -> a keep/update prompt
# defaulting to keep (so Enter and any non-interactive run never clobber an operator-tuned copy).
# Present + unmanaged (no marker) -> left untouched and logged: it is the operator's own file.
# Present + same-or-older version -> no-op.
# $1 src_root  $2 live_root(/opt/ai-tools/.claude)  $3 group
ai_tools_seed_managed_assets() {
    local src_root="$1" live_root="$2" group="$3"
    local kind src_glob src marker name dst dst_marker cur new
    for kind in agents skills; do
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
