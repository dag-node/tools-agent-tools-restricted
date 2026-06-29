#!/usr/bin/env bash
# /usr/local/lib/ai-tools/operator.lib.sh
# Shared operator-identity resolver for the ai-tools sandbox. This file is *sourced*
# (never executed) by the root helpers (ai-tools-chown, -setgid, -setfacl, -unclaim,
# -lockdown, -relabel), ai-tools-admin, and the agent hooks (session-hook.sh), so every
# component reads the SAME operator list from the SAME source and the matcher cannot drift
# between them.
#
# The operators -- the login users (a human plus rootless service accounts) whose projects
# the sandbox works on -- are resolved at runtime from /etc/ai-tools/operator.conf, written
# by ai-tools-admin, not substituted into file contents at build time. The helpers therefore
# ship identical on every host and carry no per-operator value. The config holds one line:
#     OPERATORS="alice bob svc-ci"
# a space-separated list naming every operator. Home and primary group are derived per name
# via getent/id. It is root-owned 644 (etc_t): world-readable so both the agent hooks
# (ai_tools_t) and the root helpers (ai_tools_handback_t) read it -- files_read_etc_files
# covers both domains -- and root-write-only, so the agent cannot rewrite the identity root
# chowns files back to.
#
# The value is PARSED, never sourced, so a malformed or tampered file cannot execute code in
# the privileged helpers.
#
# Two resolution modes share the PROJECTS_USER/HOME/GROUP/UID globals:
#   - ai_tools_load_operator   -> the PRIMARY operator (OPERATORS[0]); for components that need
#                                 "an operator" (the launch path, the CLI, the symlink/relabel
#                                 helpers), not a per-path owner.
#   - ai_tools_resolve_owner   -> the operator who owns a given path (their allowlist covers it,
#                                 nearest-ancestor-owner tie-break); for the handback helpers that
#                                 restore ownership of agent-written project files.
#
# The handback helpers (ai-tools-chown/-setgid/-setfacl/-lockdown/-unclaim) source this lib
# best-effort and, when it is absent, define a fail-closed ai_tools_resolve_owner stub that
# resolves no owner -- so a missing lib skips the handback (the path stays sandbox-owned) rather
# than acting on the wrong identity. Each calls resolve_owner on the path it acts on, then restores
# to that owner; a path no operator's allowlist covers is left untouched.

# Sourced more than once in a single shell: the readonly below would abort under set -e on
# the second pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for
# an unset guard and trips the sourcing shell's set -e).
if [[ -n "${_AI_TOOLS_OPERATOR_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_OPERATOR_LIB=1

# Config path. AI_TOOLS_OPERATOR_CONF overrides the installed path when set -- a root-only
# test hook, identical in spirit to AI_TOOLS_ALLOWLIST: sudo strips it (env_reset, not in
# env_keep) and the handback daemon execs the helpers with its own environment, so neither
# the operator nor the agent can inject it in production.
readonly AI_TOOLS_OPERATOR_CONF="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"

# ai_tools_load_operators: parse the OPERATORS list from AI_TOOLS_OPERATOR_CONF into the
# global array AI_TOOLS_OPERATORS (one element per operator, order preserved). Returns 0 when
# at least one operator is configured, 1 when unenrolled -- callers treat the unenrolled case
# as "nothing to do" (fail-closed: no operator means no ownership to restore). Idempotent.
ai_tools_load_operators() {
    AI_TOOLS_OPERATORS=()
    local line key val
    if [[ -r "${AI_TOOLS_OPERATOR_CONF}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"          # trim leading whitespace
            [[ -z "${line}" || "${line}" == '#'* ]] && continue
            [[ "${line}" == *=* ]] || continue
            key="${line%%=*}"
            val="${line#*=}"
            key="${key%"${key##*[![:space:]]}"}"             # trim trailing ws from the key
            val="${val#"${val%%[![:space:]]*}"}"             # trim surrounding ws from the value
            val="${val%"${val##*[![:space:]]}"}"
            val="${val#[\"\']}"; val="${val%[\"\']}"         # strip one optional quote layer
            if [[ "${key}" == OPERATORS ]]; then
                # Space-separated list; split on IFS whitespace into the array.
                read -ra AI_TOOLS_OPERATORS <<< "${val}"
            fi
        done < "${AI_TOOLS_OPERATOR_CONF}"
    fi
    [[ "${#AI_TOOLS_OPERATORS[@]}" -gt 0 ]]
}

# ai_tools_load_operator: resolve the PRIMARY operator (the first in the list) into the globals
# PROJECTS_USER, PROJECTS_HOME, PROJECTS_GROUP, and the derived PROJECTS_UID (numeric, -1 when
# unresolved so an owner-guard compare matches nothing). The single-operator identity contract
# the components that need "an operator" rely on (the launch path, the CLI, the symlink/relabel
# helpers); the per-path owner of a multi-operator host is resolved separately. Home and group
# are derived from the name via getent/id. Returns 0 when an operator is configured, 1 when
# unenrolled. Idempotent.
ai_tools_load_operator() {
    PROJECTS_USER=''
    PROJECTS_HOME=''
    PROJECTS_GROUP=''
    PROJECTS_UID=-1
    ai_tools_load_operators || return 1
    PROJECTS_USER="${AI_TOOLS_OPERATORS[0]}"
    PROJECTS_HOME="$(getent passwd "${PROJECTS_USER}" 2>/dev/null | cut -d: -f6)"
    PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}" 2>/dev/null || true)"
    PROJECTS_UID="$(id -u "${PROJECTS_USER}" 2>/dev/null || echo -1)"
    [[ -n "${PROJECTS_USER}" ]]
}

# _ai_tools_operator_allowlist <operator> <is-primary>: echo the allowlist path for an operator.
# AI_TOOLS_ALLOWLIST overrides the PRIMARY operator's path -- the single-allowlist test hook (a
# multi-operator host has one allowlist per operator home, which a single override cannot model),
# carrying the same root-only-injection rationale as the other AI_TOOLS_* hooks.
_ai_tools_operator_allowlist() {
    if [[ -n "${AI_TOOLS_ALLOWLIST:-}" && "$2" == primary ]]; then
        printf '%s' "${AI_TOOLS_ALLOWLIST}"
    else
        printf '%s/.config/ai-tools/allowed-projects' "$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    fi
}

# ai_tools_allowlist_covers <allowlist-file> <canonical-path>: succeed when the allowlist allows
# the path and no '!' exclusion overrides it. Exclusions are checked first and win; a plain (non
# -glob) allow/exclude path also covers its contents. Allow entries are realpath-resolved so a
# symlinked project root matches its canonical target. This is the one allow/exclude matcher the
# resolver and the helpers' per-subpath walks share, so coverage cannot drift between them.
ai_tools_allowlist_covers() {
    local file="$1" path="$2" entry dir pat
    [[ -f "${file}" ]] || return 1
    local -a allowed=() excluded=()
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
        if [[ "${entry}" == '!'* ]]; then
            excluded+=("${entry:1}")                       # strip '!', keep raw (may glob)
        else
            dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
            allowed+=("${dir}")
        fi
    done < "${file}"
    for pat in "${excluded[@]}"; do
        pat="${pat%/}"
        [[ "${path}" == ${pat} ]] && return 1
        [[ "${pat}" != *'*'* && "${path}" == "${pat}/"* ]] && return 1
    done
    for dir in "${allowed[@]}"; do
        [[ "${path}" == "${dir}" || "${path}" == "${dir}/"* ]] && return 0
    done
    return 1
}

# ai_tools_resolve_owner <canonical-path>: resolve which operator owns a path and load that
# operator into the same globals ai_tools_load_operator sets (PROJECTS_USER/HOME/GROUP/UID), plus
# AI_TOOLS_RESOLVED_ALLOWLIST (the owner's allowlist, for the caller's per-subpath walk). The owner
# is the operator whose allowlist covers the path. When several operators list the same path, the
# tie-break is the nearest ancestor directory whose on-disk owner is one of those operators (the
# project's owner on disk wins); failing any such ancestor, the first matching operator, so the
# result is deterministic. Returns 1 when no operator covers the path -- the caller treats that as
# "not an allowed project for anyone" and leaves the path untouched (fail-closed).
# shellcheck disable=SC2034  # PROJECTS_*/AI_TOOLS_RESOLVED_ALLOWLIST are this resolver's globals, read by callers and the test suite
ai_tools_resolve_owner() {
    local path="$1" op home tag idx=0 p owner i
    PROJECTS_USER=''; PROJECTS_HOME=''; PROJECTS_GROUP=''; PROJECTS_UID=-1
    AI_TOOLS_RESOLVED_ALLOWLIST=''
    ai_tools_load_operators || return 1
    local -a cand=() cand_home=() cand_allow=()
    for op in "${AI_TOOLS_OPERATORS[@]}"; do
        [[ "${op}" == "${AI_TOOLS_OPERATORS[0]}" ]] && tag=primary || tag=secondary
        local allowfile; allowfile="$(_ai_tools_operator_allowlist "${op}" "${tag}")"
        if ai_tools_allowlist_covers "${allowfile}" "${path}"; then
            home="$(getent passwd "${op}" 2>/dev/null | cut -d: -f6)"
            cand+=("${op}"); cand_home+=("${home}"); cand_allow+=("${allowfile}")
        fi
    done
    [[ "${#cand[@]}" -gt 0 ]] || return 1
    if [[ "${#cand[@]}" -gt 1 ]]; then
        # Nearest ancestor owned by a candidate operator wins; default to the first candidate.
        p="${path}"
        while :; do
            owner="$(stat -c '%U' "${p}" 2>/dev/null || true)"
            for i in "${!cand[@]}"; do
                [[ "${owner}" == "${cand[i]}" ]] && { idx="${i}"; break 2; }
            done
            [[ "${p}" == "/" ]] && break
            p="$(dirname "${p}")"
        done
    fi
    PROJECTS_USER="${cand[idx]}"
    PROJECTS_HOME="${cand_home[idx]}"
    PROJECTS_GROUP="$(id -gn "${PROJECTS_USER}" 2>/dev/null || true)"
    PROJECTS_UID="$(id -u "${PROJECTS_USER}" 2>/dev/null || echo -1)"
    AI_TOOLS_RESOLVED_ALLOWLIST="${cand_allow[idx]}"
    [[ -n "${PROJECTS_USER}" ]]
}
