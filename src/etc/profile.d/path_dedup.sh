# /etc/profile.d/path_dedup.sh
#
# PURPOSE
#   Establish a single, security-ordered, deduplicated PATH for every login
#   shell on this host.  Sourced automatically by /etc/profile for all users.
#   Also sourced explicitly from ~/.bashrc for interactive non-login shells
#   (where /etc/profile.d/ is not processed by default on RHEL 9).
#
#   SCOPE NOTE: "user" / "normal user" / "user-tier" below mean ANY host login
#   account that sources this file, relative to its own $HOME and $USER -- the
#   generic POSIX sense. This script is host-wide and account-agnostic.
#
# SECURITY ORDERING RATIONALE
#   PATH resolution is first-match-wins.  A directory that appears early can
#   shadow every binary in directories that appear later.  The order below is
#   arranged so that the most privileged, least-writable directories win:
#
#   Tier 1 -- root-owned, DNF-managed, immutable to normal users
#     /usr/local/sbin  /usr/sbin      privileged admin tools (sudo, useradd, ...)
#     /usr/local/bin   /usr/bin       core system tools (ssh, git, openssl, ...)
#     /usr/lib64/dotnet              system .NET runtime/SDK shim, DNF-managed
#
#   Tier 2 -- user-owned, but manually curated (deliberate placements only)
#     ~/.local/bin                   explicit user wrappers (e.g. claude)
#                                    manually curated == highest user-tier trust
#
#   Tier 3 -- user-owned, package-manager populated (supply-chain exposure)
#     ~/.dotnet/tools                `dotnet tool install -g` output (NuGet feed)
#
#   Tier 4 -- remainder of inherited $PATH, order preserved
#     Includes: nvm/node, fzf, JetBrains Toolbox, anything else appended by
#     /etc/profile.d/ fragments or ~/.bash_profile before this script ran.
#     These are volatile (node version changes, Toolbox updates) so they are
#     not hardcoded here -- they fall in naturally via $PATH passthrough.
#
#   Why ~/.dotnet/tools ranks below ~/.local/bin:
#     ~/.local/bin is manually curated -- every binary there was placed by a
#     deliberate human action.  ~/.dotnet/tools is populated by a package
#     manager pulling from NuGet; a compromised or malicious package could
#     ship a binary with any name.  Manually curated always outranks
#     package-manager populated at the same user-trust level.
#
#   Why node/nvm is not pinned:
#     The active node version path changes with `nvm use`.  Hardcoding it
#     would fight nvm's own PATH management.  It belongs in Tier 4.
#
# DEDUPLICATION
#   awk first-seen-wins on the merged candidate string preserves intended
#   order while silently dropping any path that was already seen earlier.
#   This is idempotent: sourcing this file twice produces the same PATH.
#
# WARNINGS
#   Any PATH entry that does not exist as a directory on disk is reported
#   to stderr.  This surfaces stale entries (old node version, removed tool)
#   without aborting the shell.  Each missing entry is reported at most once per
#   shell process (tracked in _PATH_DEDUP_WARNED), so the several sourcings of this
#   file in one login shell -- /etc/profile, then ~/.bash_profile and ~/.bashrc --
#   re-run the dedup but do not repeat the same warning.
#
# DEPLOYMENT
#   sudo install -o root -g root -m 644 path_dedup.sh /etc/profile.d/path_dedup.sh
#
#   ~/.bashrc addition:
#     [[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh

_dedup_path() {
    # Tier 1: root-owned system directories, immutable to normal users.
    local -r _T1_SBIN="/usr/local/sbin:/usr/sbin"
    local -r _T1_BIN="/usr/local/bin:/usr/bin"
    local -r _T1_DOTNET="/usr/lib64/dotnet"

    # Tier 2: manually curated user bin -- highest user-tier trust.
    local -r _T2_USER_BIN="${HOME}/.local/bin"

    # Tier 3: package-manager populated user tools -- NuGet supply-chain exposure.
    local -r _T3_DOTNET_TOOLS="${HOME}/.dotnet/tools"

    # Tier 4: remainder of inherited PATH (nvm, fzf, JetBrains, etc.).
    # $PATH is NOT quoted in the candidate string intentionally -- it is already
    # a colon-separated list, not a value that needs quoting at this point.
    local candidate
    candidate="${_T1_SBIN}:${_T1_BIN}:${_T1_DOTNET}:${_T2_USER_BIN}:${_T3_DOTNET_TOOLS}:${PATH}"

    # Deduplicate: split on ':', drop blank tokens (from double colons or
    # trailing colon), first occurrence of each entry wins, rejoin.
    local deduped
    deduped="$(
        printf '%s' "${candidate}" \
            | tr ':' '\n' \
            | awk 'NF && !seen[$0]++' \
            | tr '\n' ':' \
            | sed 's/:$//'
    )"

    # Warn on missing directories so stale entries are visible at login. Each missing
    # entry is reported at most once per shell process: _PATH_DEDUP_WARNED accumulates the
    # entries already reported, so re-sourcing this file (from /etc/profile, then both
    # ~/.bash_profile and ~/.bashrc) re-runs the dedup without repeating a warning. It is a
    # plain shell variable, deliberately NOT exported, so each new shell starts with a
    # clean slate and warns once on its own.
    # `|| [[ -n "${entry}" ]]` processes the final element too: `tr` emits no trailing
    # newline, so a plain `read` would return false on -- and silently skip -- the last
    # PATH entry, the very position a stale appended path tends to occupy.
    local entry
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" ]] && continue
        [[ -d "${entry}" ]] && continue
        case ":${_PATH_DEDUP_WARNED-}:" in
            *":${entry}:"*) continue ;;
        esac
        _PATH_DEDUP_WARNED="${_PATH_DEDUP_WARNED-}:${entry}"
        printf 'WARNING: PATH entry does not exist: %s\n' "${entry}" >&2
    done < <(printf '%s' "${deduped}" | tr ':' '\n')

    export PATH="${deduped}"
}

_dedup_path

# Remove the function -- do not pollute the shell namespace of every user.
unset -f _dedup_path
