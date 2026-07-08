# shellcheck shell=bash
# /usr/local/lib/ai-tools/path-dedup.sh — deduplicates the existing PATH
# entries of an operator shell and orders them so the root-owned system tiers
# win first-match. That places /usr/local/bin/claude — the wrapper that
# launches claude restricted — ahead of any nvm-managed claude, so typing
# `claude` always enters the sandbox. Sourced per-account: `ai-tools-admin
# operator add` wires it into the operator's ~/.bashrc and ~/.bash_profile
# after their nvm init (it must follow anything that prepends to PATH), which
# scopes the reorder to the operators who need it — root and unrelated
# accounts keep their stock PATH. The sandbox session needs no sourcing:
# claude-run pins the session PATH as a unit property.
#
# PATH is first-match-wins: an early directory shadows every later one. The
# order below puts the least-writable directories first, so a user- or
# package-writable entry can never shadow a system binary:
#
#   Tier 1  /usr/local/sbin /usr/sbin /usr/local/bin /usr/bin   root-owned
#           /usr/lib64/dotnet                                   DNF-managed
#   Tier 2  ~/.local/bin      manually curated by the user
#   Tier 3  ~/.dotnet/tools   package-manager populated (NuGet) — curated
#                             outranks package-managed at equal user trust
#   Tier 4  rest of the inherited $PATH, order preserved (nvm, fzf, ...)
#
# Optional tiers are added only when the directory exists — a system without
# dotnet gets no dead entries, and the next shell ranks the directory in once
# it is created. Inherited entries are passed through as-is, existing or not:
# they belong to whatever added them (EL skel dotfiles add ~/bin and
# ~/.local/bin unconditionally). Dedup is first-seen-wins and idempotent.
#
# Debugging: PATH_DEDUP_WARN=1 reports missing final-PATH entries to stderr,
# once per shell (surfaces stale entries, e.g. a removed node version).

_dedup_path() {
    # Tier 1 core, present on any EL system -- unconditional.
    local candidate="/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin"

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

    # Opt-in: report missing directories, each at most once per shell process
    # (_PATH_DEDUP_WARNED is not exported, so every new shell starts clean).
    # `|| [[ -n ... ]]` keeps the last entry: tr emits no trailing newline.
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
