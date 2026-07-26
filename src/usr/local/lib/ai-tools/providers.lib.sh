#!/usr/bin/env bash
# /usr/local/lib/ai-tools/providers.lib.sh
# Resolve which sandboxed AI agents are enabled and how to provision each. This is the seam
# that keeps the toolchain layer (ai-tools-bootstrap, nvm-update) agent-agnostic: an agent's
# npm package and launcher name live in a per-package manifest the agent's own package ships,
# and operator.conf gates which agents are provisioned. Both inputs are DATA -- parsed, never
# sourced -- so a malformed or tampered file cannot execute code in the scripts that read it
# (the same posture as operator.lib.sh / skip-dirs.lib.sh).
#
# Agent manifest -- /usr/local/lib/ai-tools/agents.d/<name>.conf, one per installed
# ai-tools-agents-* package, KEY=value per line (same grammar as operator.conf):
#     npm_pkg=<registry package>     the npm package the toolchain installs and updates
#     launcher=<bin name>            the bin symlinked at /opt/ai-tools/bin/<launcher>
#     default_enable=yes|no          provisioned when operator.conf names no explicit agent set
# <name> (the manifest basename) is the token an operator writes in AI_TOOLS_AGENTS.
#
# Enablement is FAIL-CLOSED (operator.conf: AI_TOOLS_AGENTS="<name> ..."):
#     key present  -> enabled = exactly the listed names (an allowlist; an empty value = none)
#     key absent   -> enabled = installed agents with default_enable=yes (the safe baseline)
#     conf unreadable/malformed  -> treated as absent (safe baseline, never "enable all")
#     a listed name with no installed manifest -> reported to stderr and skipped, never guessed
# The surface-widening default (a new default_enable=yes agent) is a deliberate per-manifest
# choice the shipping package makes; the operator's explicit list always overrides it.

# Include guard: consumers may source this alongside libs that also pull it in.
[[ -n "${_AI_TOOLS_PROVIDERS_LIB_LOADED:-}" ]] && return 0
_AI_TOOLS_PROVIDERS_LIB_LOADED=1

# Deployed paths; both overridable as root-only test hooks (mirrors AI_TOOLS_OPERATOR_CONF in
# skip-dirs.lib.sh), so tests point them at a fixture tree without touching the real host.
: "${AI_TOOLS_AGENTS_DIR:=/usr/local/lib/ai-tools/agents.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"

# ai_tools_agent_is_enabled <name> <default_enable> <allowlist_active> <allowlist>
#   Pure enablement verdict, no I/O -- unit-tested over the truth table. allowlist_active is
#   "yes" when operator.conf named AI_TOOLS_AGENTS (then <allowlist> is the space-separated
#   requested names), "no" for the baseline case. Returns 0 (enabled) / 1 (not).
ai_tools_agent_is_enabled() {
    local agent_name="$1" default_enable="$2" allowlist_active="$3" allowlist="$4"
    if [[ "${allowlist_active}" == yes ]]; then
        local -a requested_names
        read -ra requested_names <<< "${allowlist}"
        local requested_name
        for requested_name in "${requested_names[@]}"; do
            [[ "${requested_name}" == "${agent_name}" ]] && return 0
        done
        return 1
    fi
    [[ "${default_enable}" == yes ]]
}

# _ai_tools_conf_field <file> <key> : echo the quote-stripped value of the LAST uncommented
#   KEY=value line in <file>, empty if absent. The shared parse grammar (leading/trailing
#   whitespace trimmed, comment and non-assignment lines skipped, one layer of surrounding
#   quotes removed), matching skip-dirs.lib.sh so every KEY=value file in the project reads the
#   same way. Never sources the file.
_ai_tools_conf_field() {
    local conf_file="$1" wanted_key="$2" line line_key line_value field_value=""
    [[ -r "${conf_file}" ]] || { printf '%s' ""; return 0; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        line_key="${line%%=*}"; line_value="${line#*=}"
        line_key="${line_key%"${line_key##*[![:space:]]}"}"
        [[ "${line_key}" == "${wanted_key}" ]] || continue
        line_value="${line_value#"${line_value%%[![:space:]]*}"}"; line_value="${line_value%"${line_value##*[![:space:]]}"}"
        line_value="${line_value#[\"\']}"; line_value="${line_value%[\"\']}"
        field_value="${line_value}"
    done < "${conf_file}"
    printf '%s' "${field_value}"
}

# _ai_tools_agents_requested : set agents_allowlist_active (yes|no) and agents_allowlist from
#   operator.conf. "yes" means AI_TOOLS_AGENTS was present (its value, possibly empty, is the
#   allowlist); "no" means absent/unreadable (the baseline case). The presence scan distinguishes
#   present-but-empty from absent, which _ai_tools_conf_field's empty return cannot.
_ai_tools_agents_requested() {
    agents_allowlist_active=no; agents_allowlist=""
    [[ -r "${AI_TOOLS_OPERATOR_CONF}" ]] || return 0
    local line line_key
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        line_key="${line%%=*}"; line_key="${line_key%"${line_key##*[![:space:]]}"}"
        [[ "${line_key}" == AI_TOOLS_AGENTS ]] && agents_allowlist_active=yes
    done < "${AI_TOOLS_OPERATOR_CONF}"
    [[ "${agents_allowlist_active}" == yes ]] \
        && agents_allowlist="$(_ai_tools_conf_field "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_AGENTS)"
    return 0
}

# ai_tools_enabled_agents : print one TAB-separated "name<TAB>npm_pkg<TAB>launcher" line per
#   enabled AND installed agent, in manifest-filename order. A requested (allowlisted) name with
#   no installed manifest is reported to stderr and skipped -- never guessed into a package name.
#   The caller reads the lines; stdout carries only data so it is safe in `$(...)`.
ai_tools_enabled_agents() {
    local agents_allowlist_active agents_allowlist
    _ai_tools_agents_requested
    local -A installed_names=()
    local manifest_file agent_name npm_pkg launcher default_enable
    if [[ -d "${AI_TOOLS_AGENTS_DIR}" ]]; then
        for manifest_file in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            agent_name="${manifest_file##*/}"; agent_name="${agent_name%.conf}"
            installed_names["${agent_name}"]=1
            npm_pkg="$(_ai_tools_conf_field "${manifest_file}" npm_pkg)"
            launcher="$(_ai_tools_conf_field "${manifest_file}" launcher)"
            default_enable="$(_ai_tools_conf_field "${manifest_file}" default_enable)"
            [[ -n "${npm_pkg}" ]] || continue   # a manifest naming no package provisions nothing
            if ai_tools_agent_is_enabled "${agent_name}" "${default_enable}" \
                                         "${agents_allowlist_active}" "${agents_allowlist}"; then
                printf '%s\t%s\t%s\n' "${agent_name}" "${npm_pkg}" "${launcher}"
            fi
        done
    fi
    # Report each explicitly-requested name that has no installed manifest (allowlist case only;
    # the baseline case can only ever enable manifests that exist).
    if [[ "${agents_allowlist_active}" == yes ]]; then
        local -a requested_names; read -ra requested_names <<< "${agents_allowlist}"
        local requested_name
        for requested_name in "${requested_names[@]}"; do
            [[ -n "${installed_names[${requested_name}]:-}" ]] || \
                printf 'ai-tools: agent %q is enabled in operator.conf but no manifest is installed under %s -- install its ai-tools-agents-* package or remove it from AI_TOOLS_AGENTS; skipping\n' \
                    "${requested_name}" "${AI_TOOLS_AGENTS_DIR}" >&2
        done
    fi
    return 0
}
