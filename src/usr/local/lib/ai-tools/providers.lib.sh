#!/usr/bin/env bash
# /usr/local/lib/ai-tools/providers.lib.sh
# Resolve which sandboxed providers are enabled and how to provision each. This is the seam that
# keeps the toolchain and launch layers provider-agnostic: a provider's details live in a
# per-package manifest the provider's own package ships, and operator.conf gates which are
# enabled. Two provider kinds share the mechanism:
#   * AGENTS -- the AI coding agents (ai-tools-agents-*). ai-tools-bootstrap / nvm-update install
#     each enabled agent's npm package and symlink its launcher.
#   * INTEGRATIONS -- host-toolchain layers (ai-tools-integration-*). claude-run sources each
#     enabled integration's session-env fragment (claude-run.d/<name>.env.sh).
# Both inputs are DATA -- parsed, never sourced -- so a malformed or tampered file cannot execute
# code in the scripts that read it (the same posture as operator.lib.sh / skip-dirs.lib.sh).
#
# Manifest -- /usr/local/lib/ai-tools/{agents,integrations}.d/<name>.conf, one per installed
# member package, KEY=value per line (same grammar as operator.conf). <name> (the basename) is
# the token an operator writes in AI_TOOLS_AGENTS / AI_TOOLS_INTEGRATIONS:
#   agents:        npm_pkg=<registry package>  launcher=<bin name>  default_enable=yes|no
#   integrations:  default_enable=yes|no       (its env fragment is claude-run.d/<name>.env.sh)
#
# Enablement is FAIL-CLOSED (operator.conf: AI_TOOLS_AGENTS / AI_TOOLS_INTEGRATIONS = "<name> ..."):
#   key present  -> enabled = exactly the listed names (an allowlist; an empty value = none)
#   key absent   -> enabled = installed providers with default_enable=yes (the safe baseline)
#   conf unreadable/malformed  -> treated as absent (safe baseline, never "enable all")
#   a listed name with no installed manifest -> reported to stderr and skipped, never guessed
# A default_enable=yes on a manifest is the shipping package's claim that its provider widens no
# host surface beyond the sandbox; a surface-widening one ships default_enable=no and is enabled
# only when an operator names it. The operator's explicit list always overrides the default.

# Include guard: consumers may source this alongside libs that also pull it in.
[[ -n "${_AI_TOOLS_PROVIDERS_LIB_LOADED:-}" ]] && return 0
_AI_TOOLS_PROVIDERS_LIB_LOADED=1

# Deployed paths; all overridable as root-only test hooks (mirrors AI_TOOLS_OPERATOR_CONF in
# skip-dirs.lib.sh), so tests point them at a fixture tree without touching the real host.
: "${AI_TOOLS_AGENTS_DIR:=/usr/local/lib/ai-tools/agents.d}"
: "${AI_TOOLS_INTEGRATIONS_DIR:=/usr/local/lib/ai-tools/integrations.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"

# ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <allowlist>
#   Pure enablement verdict for either provider kind, no I/O -- unit-tested over the truth table.
#   allowlist_active is "yes" when operator.conf named the gating key (then <allowlist> is the
#   space-separated requested names), "no" for the baseline case. Returns 0 (enabled) / 1 (not).
ai_tools_provider_is_enabled() {
    local provider_name="$1" default_enable="$2" allowlist_active="$3" allowlist="$4"
    if [[ "${allowlist_active}" == yes ]]; then
        local -a requested_names
        read -ra requested_names <<< "${allowlist}"
        local requested_name
        for requested_name in "${requested_names[@]}"; do
            [[ "${requested_name}" == "${provider_name}" ]] && return 0
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

# _ai_tools_provider_requested <conf_key> : set requested_active (yes|no) and requested_list from
#   operator.conf for the given gating key. "yes" means the key was present (its value, possibly
#   empty, is the allowlist); "no" means absent/unreadable (the baseline case). The presence scan
#   distinguishes present-but-empty from absent, which _ai_tools_conf_field's empty return cannot.
_ai_tools_provider_requested() {
    local conf_key="$1"
    requested_active=no; requested_list=""
    [[ -r "${AI_TOOLS_OPERATOR_CONF}" ]] || return 0
    local line line_key
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        line_key="${line%%=*}"; line_key="${line_key%"${line_key##*[![:space:]]}"}"
        [[ "${line_key}" == "${conf_key}" ]] && requested_active=yes
    done < "${AI_TOOLS_OPERATOR_CONF}"
    [[ "${requested_active}" == yes ]] \
        && requested_list="$(_ai_tools_conf_field "${AI_TOOLS_OPERATOR_CONF}" "${conf_key}")"
    return 0
}

# _ai_tools_warn_uninstalled <manifest-dir> <conf-key> <active> <list> : report each
#   explicitly-requested (allowlisted) name that has no <name>.conf in the manifest dir -- never
#   guessed into a package name. The baseline case (no allowlist) can only enable manifests that
#   exist, so it has nothing to warn.
_ai_tools_warn_uninstalled() {
    local dir="$1" conf_key="$2" active="$3" list="$4"
    [[ "${active}" == yes ]] || return 0
    local -a requested_names; read -ra requested_names <<< "${list}"
    local requested_name
    for requested_name in "${requested_names[@]}"; do
        [[ -f "${dir}/${requested_name}.conf" ]] || \
            printf 'ai-tools: %q is enabled in operator.conf (%s) but no manifest is installed under %s -- install its ai-tools package or remove it; skipping\n' \
                "${requested_name}" "${conf_key}" "${dir}" >&2
    done
}

# ai_tools_enabled_agents : print one TAB-separated "name<TAB>npm_pkg<TAB>launcher" line per
#   enabled AND installed agent, in manifest-filename order. Data-only stdout (safe in `$(...)`);
#   an enabled-but-uninstalled agent is warned to stderr.
ai_tools_enabled_agents() {
    local requested_active requested_list
    _ai_tools_provider_requested AI_TOOLS_AGENTS
    local manifest_file agent_name npm_pkg launcher default_enable
    if [[ -d "${AI_TOOLS_AGENTS_DIR}" ]]; then
        for manifest_file in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            agent_name="${manifest_file##*/}"; agent_name="${agent_name%.conf}"
            npm_pkg="$(_ai_tools_conf_field "${manifest_file}" npm_pkg)"
            launcher="$(_ai_tools_conf_field "${manifest_file}" launcher)"
            default_enable="$(_ai_tools_conf_field "${manifest_file}" default_enable)"
            [[ -n "${npm_pkg}" ]] || continue   # a manifest naming no package provisions nothing
            if ai_tools_provider_is_enabled "${agent_name}" "${default_enable}" \
                                            "${requested_active}" "${requested_list}"; then
                printf '%s\t%s\t%s\n' "${agent_name}" "${npm_pkg}" "${launcher}"
            fi
        done
    fi
    _ai_tools_warn_uninstalled "${AI_TOOLS_AGENTS_DIR}" AI_TOOLS_AGENTS \
        "${requested_active}" "${requested_list}"
    return 0
}

# ai_tools_enabled_integrations : print one enabled AND installed integration name per line, in
#   manifest-filename order. An integration carries only default_enable; its session env lives in
#   claude-run.d/<name>.env.sh, which claude-run sources by name. An enabled-but-uninstalled
#   integration is warned to stderr.
ai_tools_enabled_integrations() {
    local requested_active requested_list
    _ai_tools_provider_requested AI_TOOLS_INTEGRATIONS
    local manifest_file integration_name default_enable
    if [[ -d "${AI_TOOLS_INTEGRATIONS_DIR}" ]]; then
        for manifest_file in "${AI_TOOLS_INTEGRATIONS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            integration_name="${manifest_file##*/}"; integration_name="${integration_name%.conf}"
            default_enable="$(_ai_tools_conf_field "${manifest_file}" default_enable)"
            if ai_tools_provider_is_enabled "${integration_name}" "${default_enable}" \
                                            "${requested_active}" "${requested_list}"; then
                printf '%s\n' "${integration_name}"
            fi
        done
    fi
    _ai_tools_warn_uninstalled "${AI_TOOLS_INTEGRATIONS_DIR}" AI_TOOLS_INTEGRATIONS \
        "${requested_active}" "${requested_list}"
    return 0
}
