#!/usr/bin/env bash
# /usr/local/lib/ai-tools/operator.lib.sh
# Shared operator-identity resolver for the ai-tools sandbox. This file is *sourced*
# (never executed) by the root helpers (ai-tools-chown, -setgid, -setfacl, -unclaim,
# -lockdown, -relabel) and the agent hooks (session-hook.sh), so every component reads
# the SAME operator identity from the SAME source and the matcher cannot drift between
# them.
#
# The operator -- the human whose projects the sandbox works on -- is resolved at runtime
# from /etc/ai-tools/operator.conf, written by the installer/enrollment, not substituted
# into file contents at build time. The helpers therefore ship identical on every host and
# carry no per-operator value. The config holds KEY=VALUE lines:
#     PROJECTS_USER=<login name>
#     PROJECTS_HOME=<home directory>
#     PROJECTS_GROUP=<primary group>
# It is root-owned 644 (etc_t): world-readable so both the agent hooks (ai_tools_t) and the
# root helpers (ai_tools_handback_t) read it -- files_read_etc_files covers both domains --
# and root-write-only, so the agent cannot rewrite the identity root chowns files back to.
#
# The values are PARSED, never sourced, so a malformed or tampered file cannot execute code
# in the privileged helpers.

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

# ai_tools_load_operator: parse the operator identity from AI_TOOLS_OPERATOR_CONF into the
# globals PROJECTS_USER, PROJECTS_HOME, PROJECTS_GROUP, and the derived PROJECTS_UID (numeric,
# -1 when unresolved so an owner-guard compare matches nothing). Returns 0 when an operator is
# configured (PROJECTS_USER non-empty), 1 when unenrolled -- callers treat the unenrolled case
# as "nothing to do" (fail-closed: no operator means no ownership to restore). Idempotent.
ai_tools_load_operator() {
    PROJECTS_USER=''
    PROJECTS_HOME=''
    PROJECTS_GROUP=''
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
            case "${key}" in
                PROJECTS_USER)  PROJECTS_USER="${val}"  ;;
                PROJECTS_HOME)  PROJECTS_HOME="${val}"  ;;
                PROJECTS_GROUP) PROJECTS_GROUP="${val}" ;;
            esac
        done < "${AI_TOOLS_OPERATOR_CONF}"
    fi
    if [[ -n "${PROJECTS_USER}" ]]; then
        PROJECTS_UID="$(id -u "${PROJECTS_USER}" 2>/dev/null || echo -1)"
    else
        PROJECTS_UID=-1
    fi
    [[ -n "${PROJECTS_USER}" ]]
}
