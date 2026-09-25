# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/path-order.sh
#
# Removes duplicate PATH entries and orders the rest; the first match wins:
#
#   1  /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin   always
#      /usr/lib64/dotnet                                   if it exists
#   2  ~/.local/bin                                        if it exists
#   3  ~/.dotnet/tools                                     if it exists
#   4  every other inherited entry, in its original order
#
# Root-owned directories come first, so a user-writable directory does not resolve a name ahead of a system binary.
# An inherited entry is kept whether or not it exists. Sourcing again gives the same PATH. Source it after anything else
# that prepends to PATH. With PATH_DEDUP_WARN=1, each entry of the result that does not exist is reported on stderr,
# once per shell.

_dedup_path() {
    # Tier 1, added whether or not each directory exists.
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
