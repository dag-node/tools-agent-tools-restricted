#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/providers.lib.sh
# Resolve which sandboxed providers are enabled and how to provision each: the seam that keeps
# the toolchain and launch layers provider-agnostic. A provider's details live in the manifest its
# own package ships (/usr/local/lib/ai-tools/{agents,integrations}.d/<name>.conf, <name> being the
# token an operator writes in operator.conf's AI_TOOLS_AGENTS / AI_TOOLS_INTEGRATIONS), and that
# key gates which are enabled. The manifest fields and what reads each, the fail-closed enablement
# rules, and the trust predicate every input and its directory pass are in providers.rule.md; the
# values one agent declares are that manifest's own comments.
#
# Manifests and operator.conf are DATA, parsed through conf.lib.sh and never sourced, so a
# malformed or tampered file yields a bad value rather than code running in the scripts that read
# it. conf.lib.sh is therefore a hard dependency: a load failure leaves this file defining NO
# RESOLVER and returning non-zero, so a consumer falls back (Node-only bootstrap, npm-only update,
# no integration env) rather than guessing which providers it has. The pure verdicts
# (ai_tools_provider_is_enabled, ai_tools_agent_sweeps_at_exit, ai_tools_provider_gate) take no
# input but their arguments, so tests/unit/providers.sh drives them over the truth table; the
# resolvers around them read the files and print data-only stdout, with every refusal on stderr
# and in journald, naming the owner and mode the predicate read.

# Include guard: consumers may source this alongside libs that also pull it in. An if-statement,
# not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing shell's set -e.
if [[ -n "${_AI_TOOLS_PROVIDERS_LIB_LOADED:-}" ]]; then
    return 0
fi

# Shared KEY=value grammar + the trust predicate. REQUIRED: without it this file cannot parse a
# manifest or tell a trusted input from a planted one, and guessing either would be exactly the
# fail-open this seam exists to prevent. Return non-zero and define no resolver, so the consumer's
# `source ... && declare -F ...` guard then falls back.
# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_untrusted_reason >/dev/null 2>&1; then
    printf 'ai-tools: providers.lib.sh: conf.lib.sh missing or incomplete -- no providers resolved\n' >&2
    return 1
fi
# Logging is best-effort here (the refusals also go to stderr for the operator at the
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
#   the resolvers and any caller REPORTING the gating both read it, so what an operator is
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
            _ai_tools_provider_warn "ignoring ${AI_TOOLS_OPERATOR_CONF} for ${conf_key}: $(ai_tools_conf_untrusted_reason "${AI_TOOLS_OPERATOR_CONF}") -- using the default-enabled providers only" ;;
        allowlist)
            requested_active=yes
            ai_tools_conf_read "${AI_TOOLS_OPERATOR_CONF}" "${conf_key}" || true
            requested_list="${_ai_tools_conf_value}" ;;
    esac
    return 0
}

# _ai_tools_provider_dir_trusted <manifest-dir> <conf-key> : succeed when the manifest directory
#   may be read. A missing directory is "no providers installed" (silent); an existing but
#   untrusted one is a tamper signal and is reported, because a non-root writer there can plant a
#   manifest that enables a provider nobody installed.
_ai_tools_provider_dir_trusted() {
    local dir="$1" conf_key="$2"
    [[ -d "${dir}" ]] || return 1
    if ! ai_tools_conf_is_trusted "${dir}"; then
        _ai_tools_provider_warn "refusing every ${conf_key} provider: ${dir} $(ai_tools_conf_untrusted_reason "${dir}")"
        return 1
    fi
    return 0
}

# _ai_tools_warn_uninstalled <manifest-dir> <conf-key> <active> <list> : report each
#   explicitly-requested (allowlisted) name that has no <name>.conf in the manifest dir -- never
#   guessed into a package name. The baseline case (no allowlist) can only enable manifests that
#   exist, so it has no name to warn about.
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
                _ai_tools_provider_warn "skipping agent ${agent_name}: ${manifest_file} $(ai_tools_conf_untrusted_reason "${manifest_file}")"
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

# ai_tools_agents_empty_verdict : for a caller whose ai_tools_enabled_agents printed an empty
#   set, print one line, "<verdict><TAB><reason>", classifying it:
#     fault  an input was refused by the trust predicate (operator.conf, the manifest directory, a
#            manifest), or AI_TOOLS_AGENTS names agents and none of them resolved. A retry reads
#            the same inputs, so a caller maintaining the toolchain ends the run as a failure
#            rather than treating npm alone as the managed set.
#     none   the configuration asks for no agent: AI_TOOLS_AGENTS is set and empty, no manifest is
#            installed, or every installed manifest is default_enable=no with the key unset.
#   The reason carries each refused path with what the predicate read
#   (ai_tools_conf_untrusted_reason), so the caller's one line names every cause. TAB-separated
#   because the callers run under IFS=$'\n\t'. Any output shape the caller does not recognize is
#   its cue to treat the set as a fault.
ai_tools_agents_empty_verdict() {
    local gate manifest_file installed=0 joined
    local -a refused=() requested_names=()
    gate="$(ai_tools_provider_gate AI_TOOLS_AGENTS)"
    [[ "${gate}" == untrusted ]] \
        && refused+=("${AI_TOOLS_OPERATOR_CONF}: $(ai_tools_conf_untrusted_reason "${AI_TOOLS_OPERATOR_CONF}")")
    if [[ -d "${AI_TOOLS_AGENTS_DIR}" ]]; then
        ai_tools_conf_is_trusted "${AI_TOOLS_AGENTS_DIR}" \
            || refused+=("${AI_TOOLS_AGENTS_DIR}: $(ai_tools_conf_untrusted_reason "${AI_TOOLS_AGENTS_DIR}")")
        for manifest_file in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
            [[ -e "${manifest_file}" ]] || continue
            installed=$(( installed + 1 ))
            ai_tools_conf_is_trusted "${manifest_file}" \
                || refused+=("${manifest_file}: $(ai_tools_conf_untrusted_reason "${manifest_file}")")
        done
    fi
    if (( ${#refused[@]} > 0 )); then
        printf -v joined '%s; ' "${refused[@]}"
        printf 'fault\t%d input(s) failed the trust check: %s\n' "${#refused[@]}" "${joined%; }"
        return 0
    fi
    if [[ "${gate}" == allowlist ]]; then
        ai_tools_conf_read "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_AGENTS || true
        ai_tools_conf_split requested_names "${_ai_tools_conf_value}"
        if (( ${#requested_names[@]} > 0 )); then
            printf -v joined '%s ' "${requested_names[@]}"
            printf 'fault\tAI_TOOLS_AGENTS in %s names %sbut no agent resolved: no trusted manifest under %s carries one of those names with an npm_package\n' \
                "${AI_TOOLS_OPERATOR_CONF}" "${joined}" "${AI_TOOLS_AGENTS_DIR}"
        else
            printf 'none\tAI_TOOLS_AGENTS in %s is set and empty, so the operator enabled no agent\n' \
                "${AI_TOOLS_OPERATOR_CONF}"
        fi
        return 0
    fi
    if (( installed == 0 )); then
        printf 'none\tno agent manifest is installed under %s\n' "${AI_TOOLS_AGENTS_DIR}"
    else
        printf 'none\t%d agent manifest(s) under %s and none is default_enable=yes, with AI_TOOLS_AGENTS unset\n' \
            "${installed}" "${AI_TOOLS_AGENTS_DIR}"
    fi
    return 0
}

# _ai_tools_manifest_field <manifest-dir> <name> <key> : print one field of a trusted manifest in
#   <manifest-dir>, empty (and non-zero) when the manifest is absent or untrusted or the key is not
#   there. Shared by the two public readers so both allowlist the name the same way and both
#   apply the trust predicate before reading.
_ai_tools_manifest_field() {
    local manifest_dir="$1" provider_name="$2" wanted_key="$3"
    # Allowlist the name before it becomes a path: manifest basenames are plain identifiers, so
    # anything else -- a separator, a traversal -- cannot address a file outside the manifest dir.
    [[ "${provider_name}" =~ ^[A-Za-z0-9._-]+$ && "${provider_name}" != *..* ]] || return 1
    local manifest_file="${manifest_dir}/${provider_name}.conf"
    ai_tools_conf_is_trusted "${manifest_file}" || return 1
    ai_tools_conf_get "${manifest_file}" "${wanted_key}"
}

# ai_tools_agent_manifest_field <agent-name> <key> : print one field of an installed agent's
#   manifest, empty when the agent has no manifest, the manifest is untrusted, or the key is
#   absent. For a caller that already knows which agent it resolved and needs a further
#   declarative field (the launcher's display name) without re-listing every agent.
ai_tools_agent_manifest_field() {
    _ai_tools_manifest_field "${AI_TOOLS_AGENTS_DIR}" "$@"
}

# ai_tools_provider_manifest_field <name> <key> : the same read across BOTH manifest kinds, for a
#   caller holding a provider name with no reason to care which kind carries it -- ai-tools-admin
#   reads admin_summary this way, a contributed command domain being either kind. The provider
#   namespace is flat (providers.rule.md), so at most one kind holds the name; integrations are
#   tried first because every contributed domain today is one.
ai_tools_provider_manifest_field() {
    _ai_tools_manifest_field "${AI_TOOLS_INTEGRATIONS_DIR}" "$@" && return 0
    _ai_tools_manifest_field "${AI_TOOLS_AGENTS_DIR}" "$@"
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
                _ai_tools_provider_warn "skipping integration ${integration_name}: ${manifest_file} $(ai_tools_conf_untrusted_reason "${manifest_file}")"
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

# ai_tools_installed_integrations_declaring <key> : print "name<TAB>value" for every INSTALLED
#   integration whose trusted manifest carries <key>, in manifest-filename order, enabled or not.
#   For a manifest field that describes a toolchain present on the host rather than what a session
#   receives: relabel.lib.sh reads build_output_dirs this way, because a project's SELinux label is
#   a property of the tree, applied at claim time, and it stays correct whichever integrations a
#   later session enables. The same trust rules as ai_tools_enabled_integrations: an untrusted
#   directory yields an empty set and an untrusted manifest is skipped, each reported on stderr.
ai_tools_installed_integrations_declaring() {
    local wanted_key="$1" manifest_file integration_name value
    _ai_tools_provider_dir_trusted "${AI_TOOLS_INTEGRATIONS_DIR}" AI_TOOLS_INTEGRATIONS || return 0
    for manifest_file in "${AI_TOOLS_INTEGRATIONS_DIR}"/*.conf; do
        [[ -e "${manifest_file}" ]] || continue
        integration_name="${manifest_file##*/}"; integration_name="${integration_name%.conf}"
        if ! ai_tools_conf_is_trusted "${manifest_file}"; then
            _ai_tools_provider_warn "skipping integration ${integration_name}: ${manifest_file} $(ai_tools_conf_untrusted_reason "${manifest_file}")"
            continue
        fi
        value="$(ai_tools_conf_get "${manifest_file}" "${wanted_key}")" || continue
        printf '%s\t%s\n' "${integration_name}" "${value}"
    done
    return 0
}
