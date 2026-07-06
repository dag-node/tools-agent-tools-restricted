#!/usr/bin/env bash
# /usr/local/lib/ai-tools/skip-dirs.lib.sh
# Single source of truth for the directory NAMES omitted from the recursive walks in the
# ai-tools helpers, and the per-consumer selector that combines them.
#
# "Skip" here means OMITTED FROM A WALK -- it is NOT an access boundary. These directories
# stay fully accessible to the agent and everyone else; the helpers simply do not descend
# into them when sweeping, because they are heavy or transient trees (dependencies, build
# output, caches, .git) and not where shared hand-authored files live, so walking them every
# pass is wasteful. The consequence is per walk:
#   - handback sweeps: a skipped tree's files are NOT reclaimed, so they stay agent-owned
#     (harmless -- world-readable and regenerable). To have a tree's contents handed back to
#     the operator, remove it from the skip list (or run `ai-tools --reclaim --full`).
#   - setgid/ACL normalization: a skipped tree receives no setgid bit or ACL.
#   - secret lockdown: a skipped tree is not scanned for secret-named files.
#
# Sourced, not executed. Deployed 644 root:root -- it carries no secrets (the names are
# documented) and three principals source it: the root helpers, the hooks (as the agent),
# and the unprivileged CLI (the claim drift scan classifies hits under these names).
# The matcher skips DIRECTORIES only
# (find -type d), so a file that merely shares a name (a git object named "obj") is walked
# normally. Names are grouped into categories an operator can override in
# /etc/ai-tools/operator.conf (parsed, never sourced -- a space-separated list per key,
# REPLACING that category's default).

# Category defaults -- the authoritative reference for the skip categories
# (/etc/ai-tools/operator.conf points here). Override per category in operator.conf with a
# space-separated list that REPLACES that category's default, e.g.
# SKIP_PACKAGE_DIRS="node_modules vendor". A name matches by bare directory name ANYWHERE
# in a project, so a name that doubles as source in some ecosystem belongs in a
# per-host override, never in these defaults.
AI_TOOLS_SKIP_VCS_DIRS=(.git)
AI_TOOLS_SKIP_PACKAGE_DIRS=(node_modules .venv packages)   # restorable dependency trees
# Build-output names ship UNSKIPPED: a skipped tree is not handed back by the sweeps, and
# bin/ is a regular source directory in many codebases (not a .NET build dir). On a large
# project where walking real build output is a performance issue, skip it per host --
# candidates: SKIP_ARTIFACT_DIRS="bin obj" (.NET), "target" (Rust/Maven), "dist build"
# (JS bundlers) -- and exempt any same-named source dir via the relative exclusions below.
AI_TOOLS_SKIP_ARTIFACT_DIRS=()
# Project-root-relative paths walked even when their basename is in SKIP_ARTIFACT_DIRS
# (explicit exclusions from the artifact-name skip), e.g. "src/usr/local/bin". Applied by
# every walk that passes its root to ai_tools_skip_find_expr. Empty by default.
AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE=()
AI_TOOLS_SKIP_CACHE_DIRS=(__pycache__)                     # regenerable caches

# Apply operator.conf overrides. Parsed exactly like operator.lib.sh reads OPERATORS (never
# sourced, so a malformed/tampered config cannot execute code in the privileged helpers);
# AI_TOOLS_OPERATOR_CONF is the same root-only test hook. A present key replaces its default.
_ai_tools_skip_load_overrides() {
    local operator_conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}" line key value
    [[ -r "${operator_conf}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        key="${line%%=*}"; value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        value="${value#[\"\']}"; value="${value%[\"\']}"
        case "${key}" in
            SKIP_VCS_DIRS)      read -ra AI_TOOLS_SKIP_VCS_DIRS      <<< "${value}" ;;
            SKIP_PACKAGE_DIRS)  read -ra AI_TOOLS_SKIP_PACKAGE_DIRS  <<< "${value}" ;;
            SKIP_ARTIFACT_DIRS) read -ra AI_TOOLS_SKIP_ARTIFACT_DIRS <<< "${value}" ;;
            SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE)
                read -ra AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE <<< "${value}" ;;
            SKIP_CACHE_DIRS)    read -ra AI_TOOLS_SKIP_CACHE_DIRS    <<< "${value}" ;;
        esac
    done < "${operator_conf}"
}
_ai_tools_skip_load_overrides

# ai_tools_skip_find_expr <consumer> [skip_git] [root]
# Build the skip set for a consumer from the LIB-OWNED per-consumer defaults below, and
# expose it two ways: AI_TOOLS_SKIP_NAMES (the flat directory-name list) and
# AI_TOOLS_SKIP_FIND_EXPR (a find fragment "( -type d ( -name a -o -name b ) ) -prune -o",
# empty when nothing is skipped). Splice the fragment into a find between the start dir and
# the action predicates. The consumer only names itself -- the lib supplies the categories
# AND whether .git is skipped. The optional second arg (true|false) overrides the .git
# default for that one call; consumers do not normally pass it ('' keeps the default).
# The optional third arg is the WALK ROOT (the directory the caller hands to find): with it,
# the artifact-name group honors AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE --
# root-relative paths walked despite their skipped basename. Entries must be relative and
# ..-free; anything else is ignored. Without a root the exclusions cannot anchor, so the
# plain name skip applies.
#
# Defaults per consumer, with why (the heavy/build base is PACKAGE + ARTIFACT + CACHE,
# omitted so the walk stays fast; their files staying agent-owned is harmless):
#   sweep         heavy + .git.  Per-turn + boundary handback; .git is reclaimed by the
#                 dedicated boundary pass and the user:<operator> ACL, not the per-turn walk.
#   setgid        heavy + .git.  Claim-time normalization; .git normalized separately by
#   setfacl       setfacl --with-git.
#   unclaim       heavy + .git.  Unclaim reversal; .git reverted in its own pass.
#   lockdown      heavy + .git.  Secret sweep; .git object names are hashes -- nothing to match.
#   reclaim       heavy only.    On-demand reclaim WALKS .git (the one tree the per-session
#                 sweeps leave behind).
#   reclaim-full  nothing.       Reclaim the entire tree, heavy trees and .git included.
ai_tools_skip_find_expr() {
    local consumer="${1:?ai_tools_skip_find_expr: consumer required}" skip_git_arg="${2:-}"
    local root="${3:-}"
    local base skip_git
    case "${consumer}" in
        sweep|setgid|setfacl|unclaim|lockdown) base=heavy; skip_git=true  ;;
        reclaim)                               base=heavy; skip_git=false ;;  # WALKS .git
        reclaim-full)                          base=none;  skip_git=false ;;  # skips nothing
        *) printf 'skip-dirs: unknown consumer: %s\n' "${consumer}" >&2; return 2 ;;
    esac
    [[ -n "${skip_git_arg}" ]] && skip_git="${skip_git_arg}"   # optional per-call override
    root="${root%/}"

    # Plain-skip names (no exemption mechanism) and artifact names (exemptable) build
    # separate prune groups; the flat NAMES list stays their union, as before.
    local -a names=() artifact=()
    [[ "${base}" == heavy ]] && names=( "${AI_TOOLS_SKIP_PACKAGE_DIRS[@]}" \
                                        "${AI_TOOLS_SKIP_CACHE_DIRS[@]}" )
    [[ "${base}" == heavy ]] && artifact=( "${AI_TOOLS_SKIP_ARTIFACT_DIRS[@]}" )
    [[ "${skip_git}" == true ]] && names=( "${AI_TOOLS_SKIP_VCS_DIRS[@]}" "${names[@]}" )
    # shellcheck disable=SC2034  # public lib output, read by the test suite
    AI_TOOLS_SKIP_NAMES=( "${names[@]}" "${artifact[@]}" )

    # Root-anchored artifact exclusions: only well-formed relative entries anchor.
    local -a excl=()
    local rel
    if [[ -n "${root}" ]]; then
        for rel in "${AI_TOOLS_SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE[@]}"; do
            [[ -z "${rel}" || "${rel}" == /* || "${rel}" == *..* ]] && continue
            excl+=( "${root}/${rel%/}" )
        done
    fi

    # _skip_group <out-name-suppressed> -- append one "( -type d ( -name .. ) [! ( -path .. )] ) -prune -o"
    # group to AI_TOOLS_SKIP_FIND_EXPR from the given name list and optional -path exemptions.
    _ai_tools_skip_group() {  # $1 = "names" | "artifact"
        local -n _grp_names="$1"
        local -a _grp_excl=(); [[ "$1" == artifact ]] && _grp_excl=( "${excl[@]}" )
        (( ${#_grp_names[@]} )) || return 0
        AI_TOOLS_SKIP_FIND_EXPR+=( '(' -type d '(' )
        local i
        for i in "${!_grp_names[@]}"; do
            (( i > 0 )) && AI_TOOLS_SKIP_FIND_EXPR+=( -o )
            AI_TOOLS_SKIP_FIND_EXPR+=( -name "${_grp_names[i]}" )
        done
        AI_TOOLS_SKIP_FIND_EXPR+=( ')' )
        if (( ${#_grp_excl[@]} )); then
            AI_TOOLS_SKIP_FIND_EXPR+=( '!' '(' )
            for i in "${!_grp_excl[@]}"; do
                (( i > 0 )) && AI_TOOLS_SKIP_FIND_EXPR+=( -o )
                AI_TOOLS_SKIP_FIND_EXPR+=( -path "${_grp_excl[i]}" )
            done
            AI_TOOLS_SKIP_FIND_EXPR+=( ')' )
        fi
        AI_TOOLS_SKIP_FIND_EXPR+=( ')' -prune -o )
    }

    AI_TOOLS_SKIP_FIND_EXPR=()
    _ai_tools_skip_group names
    _ai_tools_skip_group artifact
}
