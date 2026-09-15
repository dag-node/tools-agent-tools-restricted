# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/path-order.sh — deduplicates the sourcing shell's PATH and orders it system-first,
# on the order EL ships: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin. That is the whole of it. It does not read
# any configuration or name any agent, and leaves every entry it did not rank where the shell had it.
#
# PATH is first-match-wins, so the tier order runs least-writable first, which keeps a user- or package-writable entry
# from resolving a name ahead of a system binary. Inside Tier 1 the /usr/local pair leads, as EL's own order has it:
# where /usr/sbin is a symlink to /usr/bin, any other arrangement resolves a distro-packaged binary before one
# of the same name in /usr/local/bin.
#
# What this project gets from that ordering is a consequence of where its wrappers live: /usr/local/bin ranks ahead
# of the nvm bin an operator's init prepends, so a launcher name reaches the wrapper. `ai-tools-admin operators add`
# adds the source line to the operator's ~/.bashrc and ~/.bash_profile, after their nvm init — it must follow anything
# that prepends to PATH. Where that line goes for a non-bash login shell, and why the fragment is per-account rather
# than in /etc/profile.d, are in launch.rule.md.
#
#   Tier 1  /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin   root-owned
#           /usr/lib64/dotnet                                   DNF-managed
#   Tier 2  ~/.local/bin      manually curated by the user
#   Tier 3  ~/.dotnet/tools   package-manager populated (NuGet) — curated
#                             outranks package-managed at equal user trust
#   Tier 4  rest of the inherited $PATH, order preserved (nvm, fzf, ...)
#
# A tier joins the list only when its directory exists, and the next shell ranks in one created since. Inherited entries
# pass through whether they exist or not: they belong to whatever added them (EL skel adds ~/bin and ~/.local/bin
# unconditionally). Re-sourcing yields the same PATH.
#
# Debugging: PATH_DEDUP_WARN=1 reports missing final-PATH entries to stderr, once per shell (surfaces stale entries,
# e.g. a removed node version).

_dedup_path() {
    # Tier 1 core, present on any EL system -- unconditional.
    local candidate="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

    # Optional tiers, in rank order -- only when present.
    local tier_dir
    for tier_dir in /usr/lib64/dotnet "${HOME}/.local/bin" "${HOME}/.dotnet/tools"; do
        [[ -d "${tier_dir}" ]] && candidate="${candidate}:${tier_dir}"
    done

    # Tier 4: inherited PATH, then first-seen-wins dedup (blank tokens dropped).
    candidate="${candidate}:${PATH}"
    local deduped
    deduped="$(
        printf '%s' "${candidate}" \
            | tr ':' '\n' \
            | awk 'NF && !seen[$0]++' \
            | tr '\n' ':' \
            | sed 's/:$//'
    )"

    # Opt-in: report missing directories, each at most once per shell process (_PATH_DEDUP_WARNED is not exported,
    # so every new shell starts clean). `|| [[ -n ... ]]` keeps the last entry: tr leaves off the trailing newline.
    if [[ "${PATH_DEDUP_WARN-}" == "1" ]]; then
        local entry
        while IFS= read -r entry || [[ -n "${entry}" ]]; do
            [[ -z "${entry}" || -d "${entry}" ]] && continue
            case ":${_PATH_DEDUP_WARNED-}:" in
                *":${entry}:"*) continue ;;
            esac
            _PATH_DEDUP_WARNED="${_PATH_DEDUP_WARNED-}:${entry}"
            printf 'WARNING: PATH entry does not exist: %s\n' "${entry}" >&2
        done < <(printf '%s' "${deduped}" | tr ':' '\n')
    fi

    export PATH="${deduped}"
}

_dedup_path

# Keep the sourcing shell's namespace clean.
unset -f _dedup_path
