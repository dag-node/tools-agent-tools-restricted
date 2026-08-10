#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/providers.lib.sh
# Resolve which sandboxed providers are enabled and how to provision each. This is the seam that
# keeps the toolchain and launch layers provider-agnostic: a provider's details live in a
# per-package manifest the provider's own package ships, and operator.conf gates which are
# enabled. Two provider kinds share the mechanism:
#   * AGENTS -- the AI coding agents (ai-tools-agents-*). ai-tools-bootstrap / nvm-update install
#     each enabled agent's npm package and symlink its launcher.
#   * INTEGRATIONS -- host-toolchain layers (ai-tools-integration-*). ai-tools-run sources each
#     enabled integration's session-env fragment (session-env.d/<name>.env.sh).
# Both inputs are DATA -- parsed via conf.lib.sh, never sourced -- so a malformed or tampered file
# cannot execute code in the scripts that read it (the same posture as operator.lib.sh /
# skip-dirs.lib.sh). conf.lib.sh also carries the KEY=value grammar, so a manifest and
# operator.conf read identically; a load failure there leaves this file defining NOTHING and
# returning non-zero, so a consumer resolves no providers rather than guessing.
#
# Manifest -- /usr/local/lib/ai-tools/{agents,integrations}.d/<name>.conf, one per installed
# member package. <name> (the basename) is the token an operator writes in AI_TOOLS_AGENTS /
# AI_TOOLS_INTEGRATIONS:
#   agents:        npm_package=<registry package>  launcher=<bin name>  display_name=<label>
#                  handback=hooks|none          default_enable=yes|no
#   integrations:  default_enable=yes|no       (its env fragment is session-env.d/<name>.env.sh)
#
# ── Enablement is FAIL-CLOSED ────────────────────────────────────────────────────────────────
# operator.conf: AI_TOOLS_AGENTS / AI_TOOLS_INTEGRATIONS = "<name> ..." (commas and whitespace
# both separate; see conf.lib.sh for the grammar):
#   key present  -> enabled = exactly the listed names (an allowlist; an empty value = none)
#   key absent   -> enabled = installed providers with default_enable=yes (the safe baseline)
#   conf unreadable/malformed/UNTRUSTED -> treated as absent (safe baseline, never "enable all")
#   a listed name with no installed manifest -> reported and skipped, never guessed
# A default_enable=yes on a manifest is the shipping package's claim that its provider widens no
# host surface beyond the sandbox; a surface-widening one ships default_enable=no and is enabled
# only when an operator names it. The operator's explicit list always overrides the default.
#
# ── The sandbox cannot widen its own surface ─────────────────────────────────────────────────
# Every input that decides what a session gets is honored only while it is root-owned and not
# group- or other-writable (ai_tools_conf_is_trusted), and so is the DIRECTORY holding it -- a
# group-writable directory lets a non-root writer unlink and replace the file inside it. So:
#   * an untrusted manifest directory disables that whole provider kind
#   * an untrusted manifest disables that one provider
#   * an untrusted operator.conf is ignored, falling back to the baseline (which can only ever
#     enable a provider its own package marked default_enable=yes)
# Each refusal is reported, so a tamper is loud rather than silent. The agent account can
# therefore neither enable a disabled provider nor introduce a new one, whatever it can write.

# Include guard: consumers may source this alongside libs that also pull it in. An if-statement,
# not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing shell's set -e.
if [[ -n "${_AI_TOOLS_PROVIDERS_LIB_LOADED:-}" ]]; then
    return 0
fi

# Shared KEY=value grammar + the trust predicate. REQUIRED: without it this file cannot parse a
# manifest or tell a trusted input from a planted one, and guessing either would be exactly the
# fail-open this seam exists to prevent. Return non-zero and define nothing, so the consumer's
# `source ... && declare -F ...` guard resolves no providers.
# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1; then
    printf 'ai-tools: providers.lib.sh: conf.lib.sh missing or incomplete -- no providers resolved\n' >&2
    return 1
fi
# Logging is best-effort here (the refusals below also go to stderr for the operator at the
# terminal); journald is where a tamper signal is durable. Mirrors msg.lib.sh's optional load.
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true

_AI_TOOLS_PROVIDERS_LIB_LOADED=1

# Deployed paths; all overridable as root-only test hooks (mirrors AI_TOOLS_OPERATOR_CONF in
# skip-dirs.lib.sh), so tests point them at a fixture tree without touching the real host.
: "${AI_TOOLS_AGENTS_DIR:=/usr/local/lib/ai-tools/agents.d}"
: "${AI_TOOLS_INTEGRATIONS_DIR:=/usr/local/lib/ai-tools/integrations.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"

# _ai_tools_provider_warn <message...> : report to stderr (the operator at the terminal) and, when
#   log.lib.sh loaded, to journald (the durable trail a tamper refusal belongs in).
_ai_tools_provider_warn() {
    printf 'ai-tools: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "providers: $*"
    return 0
}

# ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <allowlist>
#   Pure enablement verdict for either provider kind, no I/O -- unit-tested over the truth table.
#   allowlist_active is "yes" when operator.conf named the gating key (then <allowlist> is the
#   requested names, comma- or whitespace-separated), "no" for the baseline case. Returns
#   0 (enabled) / 1 (not).
ai_tools_provider_is_enabled() {
    local provider_name="$1" default_enable="$2" allowlist_active="$3" allowlist="$4"
    if [[ "${allowlist_active}" == yes ]]; then
        local -a requested_names=()
        ai_tools_conf_split requested_names "${allowlist}"
        local requested_name
        for requested_name in "${requested_names[@]}"; do
            [[ "${requested_name}" == "${provider_name}" ]] && return 0
        done
        return 1
    fi
    [[ "${default_enable}" == yes ]]
}

# ai_tools_agent_sweeps_at_exit <handback-declaration> : pure verdict, no I/O -- succeed when the
#   launcher must run the ownership sweep itself at session end. Ownership handback needs a driver:
#   an agent that declares handback=hooks carries its own (Claude Code's PostToolUse/Stop hooks
#   converge the tree per turn), and anything else -- handback=none, an unrecognized value, an
#   absent key -- gets the launcher's session-end sweep. Only the exact literal disables it, so an
#   unknown declaration errs toward sweeping: a redundant walk, never a project tree left
#   sandbox-owned. Unit-tested over that truth table.
ai_tools_agent_sweeps_at_exit() {
    [[ "${1:-}" != hooks ]]
}

# ai_tools_provider_gate <conf_key> : print how the enabled set for <conf_key> is decided --
#   "allowlist" (operator.conf names the key, so its value is the exact enabled set), "baseline"
#   (it does not, so default_enable governs), or "untrusted" (operator.conf exists but fails the
#   trust predicate, so it is ignored and the baseline applies). Read-only and side-effect free:
#   the resolvers below and any caller REPORTING the gating both read it, so what an operator is
#   told matches what a session gets.
ai_tools_provider_gate() {
    local conf_key="$1"
    [[ -e "${AI_TOOLS_OPERATOR_CONF}" ]] || { printf 'baseline'; return 0; }
    ai_tools_conf_is_trusted "${AI_TOOLS_OPERATOR_CONF}" || { printf 'untrusted'; return 0; }
    if ai_tools_conf_read "${AI_TOOLS_OPERATOR_CONF}" "${conf_key}"; then
        printf 'allowlist'
    else
        printf 'baseline'
    fi
    return 0
}

# _ai_tools_provider_requested <conf_key> : set requested_active (yes|no) and requested_list from
#   operator.conf for the given gating key. "yes" means the key was present (its value, possibly
#   empty, is the allowlist); "no" means absent, unreadable, or UNTRUSTED -- all of which fall
#   back to the baseline, so a config the agent could have written cannot enable anything its own
#   package did not already mark default_enable=yes. An untrusted config is reported here rather
#   than in the pure gate, which stays side-effect free.
_ai_tools_provider_requested() {
    local conf_key="$1"
    requested_active=no; requested_list=""
    case "$(ai_tools_provider_gate "${conf_key}")" in
        untrusted)
            _ai_tools_provider_warn "ignoring ${AI_TOOLS_OPERATOR_CONF} for ${conf_key}: not root-owned or writable by group/other -- using the default-enabled providers only" ;;
        allowlist)
            requested_active=yes
            ai_tools_conf_read "${AI_TOOLS_OPERATOR_CONF}" "${conf_key}" || true
            requested_list="${_ai_tools_conf_value}" ;;
    esac
    return 0
}

# _ai_tools_provider_dir_trusted <manifest-dir> <conf-key> : succeed when the manifest directory
#   may be read. A missing directory is simply "no providers installed" (silent); an existing but
#   untrusted one is a tamper signal and is reported, because a non-root writer there can plant a
#   manifest that enables a provider nobody installed.
_ai_tools_provider_dir_trusted() {
    local dir="$1" conf_key="$2"
    [[ -d "${dir}" ]] || return 1
    if ! ai_tools_conf_is_trusted "${dir}"; then
        _ai_tools_provider_warn "refusing every ${conf_key} provider: ${dir} is not root-owned or is writable by group/other"
        return 1
    fi
    return 0
}

# _ai_tools_warn_uninstalled <manifest-dir> <conf-key> <active> <list> : report each
#   explicitly-requested (allowlisted) name that has no <name>.conf in the manifest dir -- never
#   guessed into a package name. The baseline case (no allowlist) can only enable manifests that
#   exist, so it has nothing to warn.
_ai_tools_warn_uninstalled() {
    local dir="$1" conf_key="$2" active="$3" list="$4"
    [[ "${active}" == yes ]] || return 0
    local -a requested_names=(); ai_tools_conf_split requested_names "${list}"
    local requested_name
    for requested_name in "${requested_names[@]}"; do
        [[ -f "${dir}/${requested_name}.conf" ]] || \
            _ai_tools_provider_warn "$(printf '%q' "${requested_name}") is enabled in operator.conf (${conf_key}) but no manifest is installed under ${dir} -- install its ai-tools package or remove it; skipping"
    done
    return 0
}

# ai_tools_enabled_agents : print one TAB-separated "name<TAB>npm_package<TAB>launcher" line per
#   enabled AND installed agent, in manifest-filename order. Data-only stdout (safe in `$(...)`);
#   an enabled-but-uninstalled agent, and any refusal, is reported on stderr.
ai_tools_enabled_agents() {
    local requested_active requested_list
    _ai_tools_provider_requested AI_TOOLS_AGENTS
    local manifest_file agent_name npm_package launcher default_enable
    if _ai_tools_provider_dir_trusted "${AI_TOOLS_AGENTS_DIR}" AI_TOOLS_AGENTS; then
        for manifest_file in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            agent_name="${manifest_file##*/}"; agent_name="${agent_name%.conf}"
            if ! ai_tools_conf_is_trusted "${manifest_file}"; then
                _ai_tools_provider_warn "skipping agent ${agent_name}: ${manifest_file} is not root-owned or is writable by group/other"
                continue
            fi
            npm_package="$(ai_tools_conf_get "${manifest_file}" npm_package || true)"
            launcher="$(ai_tools_conf_get "${manifest_file}" launcher || true)"
            default_enable="$(ai_tools_conf_get "${manifest_file}" default_enable || true)"
            [[ -n "${npm_package}" ]] || continue   # a manifest naming no package provisions nothing
            if ai_tools_provider_is_enabled "${agent_name}" "${default_enable}" \
                                            "${requested_active}" "${requested_list}"; then
                printf '%s\t%s\t%s\n' "${agent_name}" "${npm_package}" "${launcher}"
            fi
        done
    fi
    _ai_tools_warn_uninstalled "${AI_TOOLS_AGENTS_DIR}" AI_TOOLS_AGENTS \
        "${requested_active}" "${requested_list}"
    return 0
}

# ai_tools_agent_manifest_field <agent-name> <key> : print one field of an installed agent's
#   manifest, empty when the agent has no manifest, the manifest is untrusted, or the key is
#   absent. For a caller that already knows which agent it resolved and needs a further
#   declarative field (the launcher's display name) without re-listing every agent.
ai_tools_agent_manifest_field() {
    local agent_name="$1" wanted_key="$2"
    # Allowlist the name before it becomes a path: manifest basenames are plain identifiers, so
    # anything else -- a separator, a traversal -- cannot address a file outside the manifest dir.
    [[ "${agent_name}" =~ ^[A-Za-z0-9._-]+$ && "${agent_name}" != *..* ]] || return 1
    local manifest_file="${AI_TOOLS_AGENTS_DIR}/${agent_name}.conf"
    ai_tools_conf_is_trusted "${manifest_file}" || return 1
    ai_tools_conf_get "${manifest_file}" "${wanted_key}"
}

# ai_tools_enabled_integrations : print one enabled AND installed integration name per line, in
#   manifest-filename order. An integration carries only default_enable; its session env lives in
#   session-env.d/<name>.env.sh, which ai-tools-run sources by name -- after applying the same trust
#   check to that fragment and its directory. An enabled-but-uninstalled integration, and any
#   refusal, is reported on stderr.
ai_tools_enabled_integrations() {
    local requested_active requested_list
    _ai_tools_provider_requested AI_TOOLS_INTEGRATIONS
    local manifest_file integration_name default_enable
    if _ai_tools_provider_dir_trusted "${AI_TOOLS_INTEGRATIONS_DIR}" AI_TOOLS_INTEGRATIONS; then
        for manifest_file in "${AI_TOOLS_INTEGRATIONS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            integration_name="${manifest_file##*/}"; integration_name="${integration_name%.conf}"
            if ! ai_tools_conf_is_trusted "${manifest_file}"; then
                _ai_tools_provider_warn "skipping integration ${integration_name}: ${manifest_file} is not root-owned or is writable by group/other"
                continue
            fi
            default_enable="$(ai_tools_conf_get "${manifest_file}" default_enable || true)"
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
