#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/providers.lib.sh
# Resolve which sandboxed providers are enabled and how to provision each: the seam that keeps the toolchain and launch
# layers provider-agnostic. A provider's details live in the manifest its own package ships
# (/usr/local/lib/ai-tools/{agents,integrations}.d/<name>.conf, an operator writing <name> with its kind prefix
# in operator.conf's AI_TOOLS_AGENTS / AI_TOOLS_INTEGRATIONS: agent-<name>, integration-<name>), and that key gates
# which are enabled. The list reader strips the prefix (ai_tools_conf_kind_list, conf.lib.sh), so every name this file
# prints is the bare manifest name. The manifest fields and what reads each, the fail-closed enablement rules,
# and the trust predicate every input and its directory pass are in providers.rule.md; the values one agent declares are
# that manifest's own comments.
#
# Manifests and operator.conf are DATA, parsed through conf.lib.sh and never sourced, so a malformed or tampered file
# yields a bad value rather than code running in the scripts that read it. conf.lib.sh is therefore a hard dependency:
# a load failure leaves this file defining NO RESOLVER and returning non-zero, so a consumer falls back (Node-only
# bootstrap, npm-only update, no integration env) rather than guessing which providers it has. The pure verdicts
# (ai_tools_provider_is_enabled, ai_tools_agent_sweeps_at_exit, ai_tools_provider_gate) take no input but their
# arguments, so tests/unit/providers.sh drives them over the truth table; the resolvers around them read the files
# and print data-only stdout, with every refusal on stderr and in journald, naming the owner and mode the predicate
# read. The one write this file makes is the versioned launcher re-link an agent's `launcher_target` asks for (the
# launcher target section), driven by the toolchain provisioning and the updater.

# Include guard: consumers may source this alongside libs that also pull it in. An if-statement, not `[[ ]] && return`,
# which returns 1 for an unset guard and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_PROVIDERS_LIB_LOADED:-}" ]]; then
    return 0
fi

# _ai_tools_provider_warn [code] <message...> : report to stderr (the operator at the terminal)
#   and, when log.lib.sh loaded, to journald (the durable trail a tamper refusal belongs in). A
#   leading message code (msg.lib.sh states the form) goes on its own line ahead of the message,
#   the shape tests/lib/harness.sh's assert_msg reads; matched inline, since this library takes no
#   dependency it could read the form from. stderr for every line: this library's STDOUT is a wire
#   format its callers read with `$(...)`, so nothing a reader parses may land there.
#
#   Defined ahead of the loads below, so the refusal that reports an unusable conf.lib.sh carries a
#   code like every other. It is pure printf until log.lib.sh is loaded, which the `declare -F` guard
#   already tolerates.
_ai_tools_provider_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "providers: $*"
    return 0
}

# Shared KEY=value grammar + the trust predicate. REQUIRED: without it this file cannot parse a manifest or tell
# a trusted input from a planted one, and guessing either would be exactly the fail-open this seam exists to prevent.
# Return non-zero and define no resolver, so the consumer's `source ... && declare -F ...` guard then falls back.
# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_untrusted_reason >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_kind_list >/dev/null 2>&1; then
    _ai_tools_provider_warn MSG-P4M9 \
        "providers.lib.sh: conf.lib.sh missing or incomplete -- no providers resolved"
    return 1
fi
# Logging is best-effort here (the refusals also go to stderr for the operator at the terminal); journald is
# where a tamper signal is durable. Mirrors msg.lib.sh's optional load.
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true

_AI_TOOLS_PROVIDERS_LIB_LOADED=1

# Deployed paths; all overridable as root-only test hooks (mirrors AI_TOOLS_OPERATOR_CONF in skip-dirs.lib.sh), so tests
# point them at a fixture tree without touching the real host.
: "${AI_TOOLS_AGENTS_DIR:=/usr/local/lib/ai-tools/agents.d}"
: "${AI_TOOLS_INTEGRATIONS_DIR:=/usr/local/lib/ai-tools/integrations.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"
# The rule-set directory, read here only by the kind-prefix migration, which checks a filter name against it; the same
# default filters.lib.sh holds.
: "${AI_TOOLS_FILTERS_DIR:=/usr/local/lib/ai-tools/filters.d}"

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
#   than in the pure gate, which stays side-effect free. requested_list holds the bare names joined
#   by a space, read through the kind-prefixed list reader once here, so an invalid list -- one the
#   grammar refuses, or one holding an item without its kind prefix -- is reported once per read
#   and arrives as the empty allowlist: no provider of that kind enabled.
_ai_tools_provider_requested() {
    local conf_key="$1"
    local -a requested_names=()
    requested_active=no; requested_list=""
    case "$(ai_tools_provider_gate "${conf_key}")" in
        untrusted)
            _ai_tools_provider_warn MSG-C4F9 "ignoring ${AI_TOOLS_OPERATOR_CONF} for ${conf_key}: $(ai_tools_conf_untrusted_reason "${AI_TOOLS_OPERATOR_CONF}") -- using the default-enabled providers only" ;;
        allowlist)
            requested_active=yes
            ai_tools_conf_kind_list requested_names "${AI_TOOLS_OPERATOR_CONF}" "${conf_key}" || true
            local IFS=' '
            requested_list="${requested_names[*]-}" ;;
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
        _ai_tools_provider_warn MSG-W3Q3 "refusing every ${conf_key} provider: ${dir} $(ai_tools_conf_untrusted_reason "${dir}")"
        return 1
    fi
    return 0
}

# _ai_tools_skip_integration <name> <manifest-file> : report an integration manifest the trust
#   predicate refused. One situation met by both readers of that directory -- the enabled set and
#   the installed-declaring set -- so it is written once and each reader calls it.
_ai_tools_skip_integration() {
    _ai_tools_provider_warn MSG-N9X8 "skipping integration $1: $2 $(ai_tools_conf_untrusted_reason "$2")"
}

# _ai_tools_skip_agent <name> <manifest-file> : the same report for an agent manifest, met by the
#   enabled-set reader and the installed-set reader alike.
_ai_tools_skip_agent() {
    _ai_tools_provider_warn MSG-M3A5 "skipping agent $1: $2 $(ai_tools_conf_untrusted_reason "$2")"
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
            _ai_tools_provider_warn MSG-X8P4 "enabled with nothing installed: $(printf '%q' "${requested_name}") is enabled in operator.conf (${conf_key}) but no manifest is installed under ${dir} -- install its ai-tools package or remove it; skipping"
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
                _ai_tools_skip_agent "${agent_name}" "${manifest_file}"
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
#            manifest), AI_TOOLS_AGENTS is not a valid list, or it names agents and none of them resolved. A retry reads
#            the same inputs, so a caller maintaining the toolchain ends the run as a failure
#            rather than treating npm alone as the managed set.
#     none   the configuration asks for no agent: AI_TOOLS_AGENTS is set and empty, no manifest is
#            installed, or the key is unset (every agent manifest ships default_enable=no, so
#            an unset key is a host whose bootstrap has not yet enabled one).
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
        ai_tools_conf_kind_list requested_names "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_AGENTS 2>/dev/null || true
        if (( _ai_tools_conf_list_unprefixed )); then
            printf 'fault\tAI_TOOLS_AGENTS in %s holds a name not written as agent-<name>, so it enables no agent -- rewrite it: sudo ai-tools-admin system post-upgrade\n' \
                "${AI_TOOLS_OPERATOR_CONF}"
        elif (( _ai_tools_conf_list_invalid )); then
            printf 'fault\tAI_TOOLS_AGENTS in %s is not a valid list, so it enables no agent -- write it as [agent-<name>, agent-<name>]\n' \
                "${AI_TOOLS_OPERATOR_CONF}"
        elif (( ${#requested_names[@]} > 0 )); then
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
        printf 'none\t%d agent manifest(s) under %s and AI_TOOLS_AGENTS unset, so no agent is enabled -- sudo ai-tools-admin system bootstrap asks which one\n' \
            "${installed}" "${AI_TOOLS_AGENTS_DIR}"
    fi
    return 0
}

# ── The kind-prefix migration: the one rewrite of an earlier release's list values ───────────
# An earlier release wrote the items of AI_TOOLS_AGENTS, AI_TOOLS_INTEGRATIONS and AI_TOOLS_FILTERS as bare names,
# which ai_tools_conf_kind_list refuses (conf.lib.sh). `ai-tools-admin system post-upgrade` and `system bootstrap`
# rewrite them through ai_tools_conf_kind_migrate, a key at a time and only when every item the key holds maps
# onto a name this host installs, so a rewritten line always reads back whole, and a line holding a name no installed
# manifest or rule set matches stays as written and is named for the operator. The base package's %post and install.sh
# detect the same state through ai_tools_conf_kind_unmigrated and name that command; neither rewrites a config file.

# _ai_tools_conf_kind_migrate_item <KEY> <item> : print the spelling <item> takes in <KEY> -- itself
#   when it already carries the key's prefix around a plain name; the prefix and the name when the
#   bare name is installed as that kind (agents.d/<name>.conf, integrations.d/<name>.conf,
#   filters.d/<name>.rules), `core` in AI_TOOLS_FILTERS naming the base set, base.rules. Returns 1,
#   printing nothing, for any other item: a name not installed, another kind's prefix, a name
#   outside the manifest-basename charset.
_ai_tools_conf_kind_migrate_item() {
    local key="$1" item="$2" prefix name
    prefix="$(ai_tools_conf_kind_prefix "${key}")" || return 1
    if [[ "${item}" == "${prefix}"* ]]; then
        name="${item#"${prefix}"}"
    else
        name="${item}"
        [[ "${key}" == AI_TOOLS_FILTERS && "${name}" == core ]] && name=base
        case "${key}" in
            AI_TOOLS_AGENTS)       [[ -f "${AI_TOOLS_AGENTS_DIR}/${name}.conf" ]] || return 1 ;;
            AI_TOOLS_INTEGRATIONS) [[ -f "${AI_TOOLS_INTEGRATIONS_DIR}/${name}.conf" ]] || return 1 ;;
            AI_TOOLS_FILTERS)      [[ -f "${AI_TOOLS_FILTERS_DIR}/${name}.rules" ]] || return 1 ;;
            *)                     return 1 ;;
        esac
    fi
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ && "${name}" != *..* ]] || return 1
    printf '%s%s' "${prefix}" "${name}"
}

# ai_tools_conf_kind_plan <file> : read-only -- print what ai_tools_conf_kind_migrate would do, one
#   line per key holding an unmigrated item (ai_tools_conf_kind_unmigrated), in table order:
#     migrate<TAB>KEY<TAB>old items<TAB>new items   every item maps, items space-joined
#     blocked<TAB>KEY<TAB>item                      one line per item that does not, and no
#                                                   migrate line for that key
#   Prints nothing for a migrated, missing or untrusted file.
ai_tools_conf_kind_plan() {
    local file="$1" key item new IFS=$' \t\n'
    local -a items=() mapped=() blocked=()
    local -A planned=()
    while IFS=$'\t' read -r key _; do
        [[ -n "${key}" && -z "${planned[${key}]:-}" ]] || continue
        planned["${key}"]=1
        ai_tools_conf_list items "${file}" "${key}" 2>/dev/null || continue
        mapped=(); blocked=()
        for item in "${items[@]}"; do
            if new="$(_ai_tools_conf_kind_migrate_item "${key}" "${item}")"; then
                mapped+=("${new}")
            else
                blocked+=("${item}")
            fi
        done
        if (( ${#blocked[@]} > 0 )); then
            for item in "${blocked[@]}"; do printf 'blocked\t%s\t%s\n' "${key}" "${item}"; done
        else
            printf 'migrate\t%s\t%s\t%s\n' "${key}" "${items[*]}" "${mapped[*]}"
        fi
    done < <(ai_tools_conf_kind_unmigrated "${file}")
    return 0
}

# ai_tools_conf_kind_migrate <file> : rewrite each key ai_tools_conf_kind_plan maps, through
#   ai_tools_conf_set_list, after one dated .bak of <file> (ai_tools_conf_backup) taken before
#   the first write. Prints one line per outcome, in plan order:
#     backup<TAB>path                               the copy of the file as it was
#     rewritten<TAB>KEY<TAB>old items<TAB>new items the key now holds the new items
#     blocked<TAB>KEY<TAB>item                      left as written: the item maps onto no installed name
#     failed<TAB>KEY<TAB>old items<TAB>reason       left as written: the backup or the write failed
#   Returns 0 when every key read back migrated, 1 when a line was blocked or failed. A key is
#   rewritten whole or not at all, so the file never holds a half-migrated list.
ai_tools_conf_kind_migrate() {
    local file="$1" verdict key old new backup="" backup_failed=0 rc=0 IFS=$' \t\n'
    local -a new_items=()
    while IFS=$'\t' read -r verdict key old new; do
        case "${verdict}" in
            blocked)
                printf 'blocked\t%s\t%s\n' "${key}" "${old}"; rc=1 ;;
            migrate)
                if [[ -z "${backup}" ]] && (( ! backup_failed )); then
                    if backup="$(ai_tools_conf_backup "${file}")"; then
                        printf 'backup\t%s\n' "${backup}"
                    else
                        backup=""; backup_failed=1
                    fi
                fi
                if (( backup_failed )); then
                    printf 'failed\t%s\t%s\t%s\n' "${key}" "${old}" "no backup of ${file} could be written"; rc=1
                    continue
                fi
                read -ra new_items <<< "${new}"
                if ai_tools_conf_set_list "${file}" "${key}" "${new_items[@]}"; then
                    printf 'rewritten\t%s\t%s\t%s\n' "${key}" "${old}" "${new}"
                else
                    printf 'failed\t%s\t%s\t%s\n' "${key}" "${old}" "the line was not written, or did not read back"; rc=1
                fi ;;
        esac
    done < <(ai_tools_conf_kind_plan "${file}")
    return "${rc}"
}

# _ai_tools_manifest_field <manifest-dir> <name> <key> : print one field of a trusted manifest in
#   <manifest-dir>, empty (and non-zero) when the manifest is absent or untrusted or the key is not
#   there. Shared by the two public readers so both allowlist the name the same way and both
#   apply the trust predicate before reading.
_ai_tools_manifest_field() {
    local manifest_dir="$1" provider_name="$2" wanted_key="$3"
    # Allowlist the name before it becomes a path: manifest basenames are plain identifiers, so anything else --
    # a separator, a traversal -- cannot address a file outside the manifest dir.
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

# Managed files: the configuration an agent's own product reads from a fixed path outside the control plane (codex's
# /etc/codex/*.toml), shipped kept-across-upgrade so a host's edit survives. A manifest names them in `managed_files`,
# and the package ships a pristine copy of each under <reference dir>/<agent>/<basename>, so the two status reports can
# say whether the live file is the shipped one. The live file sits directly under /etc/<agent>/, the same name
# the reference carries: the reader recomposes each declared path from its own basename under that root, so root `cmp`s
# one agent's own configuration and never a path of the manifest's choosing. Reported and never enforced: no such file
# holds a guarantee, so a host copy can only reduce what a session does. The reference directory is overridable
# for the unit test alone; a caller who could set it may already read every file it names.
: "${AI_TOOLS_MANAGED_REFERENCE_DIR:=/usr/share/ai-tools}"

# ai_tools_managed_file_state <live> <reference> : print one word for how a managed file relates to
#   the pristine copy its package ships: `shipped` (byte-identical), `edited` (both readable and
#   they differ), `missing` (the live file is absent), `unknown` (the reference cannot be read,
#   either path is a symlink, or either is not a regular file -- a report that cannot compare says
#   so rather than guessing). Pure: two paths in, one token out.
ai_tools_managed_file_state() {
    local live="$1" reference="$2"
    [[ -e "${live}" ]] || { printf 'missing'; return 0; }
    # A directory (or any other non-regular file) at either end has no content to compare: `cmp` fails, and that failure
    # read as `edited` -- a verdict about content over a path that does not hold any.
    if [[ -L "${live}" || -L "${reference}" || ! -f "${live}" || ! -f "${reference}" \
            || ! -r "${live}" || ! -r "${reference}" ]]; then
        printf 'unknown'; return 0
    fi
    if cmp -s -- "${live}" "${reference}"; then printf 'shipped'; else printf 'edited'; fi
    return 0
}

# ai_tools_managed_file_retire <live> <reference> : remove a managed file whose package is being
#   uninstalled, keeping what the host made of it. Prints one word, and the sidecar path with it
#   where one was written: `absent` (no file at <live>), `removed` (the live file is byte-identical
#   to <reference>, so the shipped copy is all that is deleted), `kept <sidecar>` (every other state -- an
#   edit, or a comparison that cannot be made -- moved aside as <live>.<YYYYMMDD>-<N>.retired, the
#   token this tree gives a file moved rather than deleted, and the treatment rpm gives an edited
#   %config(noreplace) file on erase). Moving rather than leaving is what keeps a live managed file
#   from naming hooks this uninstall removed. When the move or the removal fails it
#   prints nothing, leaves the file where it is, and returns 1 under MSG-X7C4. Only a file
#   proven to be the shipped one is deleted, so the fail direction is keeping.
ai_tools_managed_file_retire() {
    local live="$1" reference="$2" sidecar
    [[ -e "${live}" || -L "${live}" ]] || { printf 'absent'; return 0; }
    # The remover's and the mover's own stderr is dropped: either failure takes the MSG-X7C4 refusal, and an uninstall's
    # transcript carries one line for it rather than two saying the same thing in two voices.
    if [[ "$(ai_tools_managed_file_state "${live}" "${reference}")" == shipped ]]; then
        if rm -f -- "${live}" 2>/dev/null; then
            printf 'removed'
            return 0
        fi
    elif sidecar="$(ai_tools_conf_sidecar_path "${live}" retired)" && [[ -n "${sidecar}" ]] \
            && mv -f -- "${live}" "${sidecar}" 2>/dev/null; then
        printf 'kept %s' "${sidecar}"
        return 0
    fi
    _ai_tools_provider_warn MSG-X7C4 "could not retire the managed file ${live} -- leaving it as it is"
    return 1
}

# ai_tools_agent_managed_files <agent> : print "<live>\t<reference>" per file the agent's trusted
#   manifest names in managed_files -- the live path directly under /etc/<agent>/, the reference
#   the pristine copy at AI_TOOLS_MANAGED_REFERENCE_DIR/<agent>/ under the same name, so the two
#   differ only in their root. An entry naming anything else, and a second entry repeating
#   a name already paired, is skipped with a refusal on stderr; empty output for an agent declaring
#   none.
ai_tools_agent_managed_files() {
    local agent="$1" value path base root reason seen=" "
    local -a paths=()
    value="$(ai_tools_agent_manifest_field "${agent}" managed_files 2>/dev/null || true)"
    [[ -n "${value}" ]] || return 0
    root="/etc/${agent}"
    ai_tools_conf_list_value paths "${value}" 0 "managed_files in the ${agent} manifest"
    for path in "${paths[@]}"; do
        # The (live, reference) pair is composed rather than declared, so the live path is held to the directory
        # that describes: a plain name directly under /etc/<agent>/. Recomposing the path from its own basename is
        # what refuses a relative path, a nested one, a traversal, and a file of another package's in one comparison,
        # and the charset refuses `.` and `..` before they reach it. A name declared twice is two live paths against one
        # reference copy -- here, one live path reported twice -- so the second is a refusal rather than a line.
        base="${path##*/}"
        if [[ "${path}" != "${root}/${base}" || ! "${base}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.+-]*$ ]]; then
            reason="not a plain filename directly under ${root}/"
        elif [[ "${seen}" == *" ${base} "* ]]; then
            reason="${base} is already paired with a reference copy"
        else
            reason=""
        fi
        if [[ -n "${reason}" ]]; then
            _ai_tools_provider_warn MSG-N4W6 "skipping the managed file $(printf '%q' "${path}") of ${agent}: ${reason}"
            continue
        fi
        seen+="${base} "
        printf '%s\t%s/%s/%s\n' "${path}" "${AI_TOOLS_MANAGED_REFERENCE_DIR}" "${agent}" "${base}"
    done
    return 0
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
                _ai_tools_skip_integration "${integration_name}" "${manifest_file}"
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

# ai_tools_installed_agents : print one "name<TAB>npm_package<TAB>launcher" line per INSTALLED
#   agent, enabled or not, in manifest-filename order -- every trusted manifest that names an
#   npm_package. The set the toolchain provisioning offers an operator to choose from, and the set
#   a name given on its command line is checked against, before any is enabled. The same trust
#   rules as ai_tools_enabled_agents: an untrusted directory yields an empty set and an untrusted
#   manifest is skipped, each reported on stderr. Data-only stdout.
ai_tools_installed_agents() {
    local manifest_file agent_name npm_package launcher
    _ai_tools_provider_dir_trusted "${AI_TOOLS_AGENTS_DIR}" AI_TOOLS_AGENTS || return 0
    for manifest_file in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
        [[ -e "${manifest_file}" ]] || continue
        agent_name="${manifest_file##*/}"; agent_name="${agent_name%.conf}"
        if ! ai_tools_conf_is_trusted "${manifest_file}"; then
            _ai_tools_skip_agent "${agent_name}" "${manifest_file}"
            continue
        fi
        npm_package="$(ai_tools_conf_get "${manifest_file}" npm_package || true)"
        launcher="$(ai_tools_conf_get "${manifest_file}" launcher || true)"
        [[ -n "${npm_package}" ]] || continue
        printf '%s\t%s\t%s\n' "${agent_name}" "${npm_package}" "${launcher}"
    done
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
            _ai_tools_skip_integration "${integration_name}" "${manifest_file}"
            continue
        fi
        value="$(ai_tools_conf_get "${manifest_file}" "${wanted_key}")" || continue
        printf '%s\t%s\n' "${integration_name}" "${value}"
    done
    return 0
}

# ── The launcher target: where an agent's versioned launcher points ──────────────────────────
# npm links <version-dir>/bin/<launcher> at the package's own entry file. For an agent whose package starts from a shim
# -- a JavaScript file that spawns the vendor's binary -- that file is not the executable the session runs,
# so the manifest declares `launcher_target`, the path of that executable relative to the version directory,
# and the toolchain provisioning (ai-tools-bootstrap) and the updater (nvm-update) re-link the versioned launcher at it
# after every install and before the stable symlink is repointed. The chain a launch resolves --
# /opt/ai-tools/bin/<launcher> -> <version-dir>/bin/<launcher> -> the target -- then ends at the file the manifest's
# entrypoint_fcontext labels. The pattern is held to the containment the relabel holds it to before it is matched
# (ai_tools_entrypoint_fcontext_valid, defined here because the relabel library sources this one and the confined shim
# sources this one alone), so a manifest the relabel would refuse is refused at the write, with the reason, and not one
# step later at the launch preflight. ai_tools_relink_launcher refuses, leaving npm's own link in place, on every input
# it cannot honour; the launch then fails closed at the label preflight, since no rule labels the file npm's link
# resolves to. The callers read the key as any other field (ai_tools_agent_manifest_field); the functions here take
# the values as arguments, so tests/unit/launcher-target.sh drives the write against fixtures with no manifest.

# ai_tools_launcher_target_valid <value> : pure check, no I/O -- succeed when <value> is a path
#   that can only name a file inside the version directory it is joined to: relative, free of
#   `..`, and drawn from the path characters a declared entrypoint pattern is allowed (letters,
#   digits, `_ . / @ + -`). ai_tools_relink_launcher checks what the join resolves to, symlinks
#   followed.
ai_tools_launcher_target_valid() {
    local value="${1:-}"
    [[ -n "${value}" ]] || return 1
    [[ "${value}" != /* ]] || return 1
    [[ "${value}" =~ ^[A-Za-z0-9_./@+-]+$ ]] || return 1
    [[ "${value}" != *..* ]]
}

# ai_tools_entrypoint_fcontext_valid <pattern> <containment-root> : pure check, no I/O -- succeed
#   when <pattern> is a file-context regex that can only ever match inside <containment-root>. Two
#   conditions, both required, because the type the relabel gives what it matches is an exec
#   entrypoint of the confined domain: with its backslash escapes removed the pattern must start
#   with <containment-root> (so the literal head is anchored there), and it must contain no `|`,
#   `(`, or other metacharacter that could match a path outside that head. Character classes, `*`,
#   `+`, `.`, and escapes are what a path pattern needs and all it gets. An empty pattern or an empty
#   root is refused. relabel.lib.sh passes the Node versions root it pins
#   (AI_TOOLS_NODE_VERSIONS_ROOT); the two writers of the launcher chain pass the directory
#   the resolved version directory sits in, which on the toolchain is that same root and on a test
#   fixture is the fixture's.
ai_tools_entrypoint_fcontext_valid() {
    # Path characters, character classes, `*`, `+`, `.` and escapes -- no `|`, no `(`, no `$`, no whitespace. `]` leads
    # the set and `-` closes it, the POSIX way to include both.
    local allowed='^[]A-Za-z0-9_./@+*^[\-]+$'
    local pattern="${1:-}" containment_root="${2:-}" plain="${1//\\/}"
    [[ -n "${pattern}" && -n "${containment_root}" ]] || return 1
    [[ "${pattern}" =~ ${allowed} ]] || return 1
    [[ "${pattern}" != *..* ]] || return 1
    [[ "${plain}" == "${containment_root}/"* ]]
}

# ai_tools_relink_launcher <version-dir> <launcher> <target> <entrypoint-fcontext> : point
#   <version-dir>/bin/<launcher> at <version-dir>/<target> -- a symlink written under a temporary
#   name and renamed over the link, so the launcher is never absent -- and print one word:
#   `linked` when the link was written, `current` when it already pointed there. Refuses, printing
#   nothing, returning 1, and reporting the reason on stderr under its code, when <target> fails
#   ai_tools_launcher_target_valid, when it does not resolve (symlinks followed) to a regular
#   executable file inside <version-dir>, when <entrypoint-fcontext> is empty, is not a plain path
#   pattern anchored under the directory the resolved <version-dir> sits in
#   (ai_tools_entrypoint_fcontext_valid), or does not match the resolved path (the file would carry
#   no ai_tools_exec_t, and the launch would refuse it), when the launcher path exists and is not
#   a symlink, or when the write fails. A refusal leaves whatever is at the launcher path as it
#   was. The link is relative (`../<target>`), the form npm writes its own in.
ai_tools_relink_launcher() {
    local version_dir="${1:-}" launcher="${2:-}" target="${3:-}" fcontext="${4:-}"
    local link="${version_dir}/bin/${launcher}" real_version_dir="" resolved="" containment_root pattern reason tmp
    if ! ai_tools_launcher_target_valid "${target}"; then
        _ai_tools_provider_warn MSG-J5C3 "refusing the launcher target for ${launcher}: $(printf '%q' "${target}") is not a relative path inside the version directory -- leaving ${link} as it is"
        return 1
    fi
    if real_version_dir="$(realpath -e -- "${version_dir}" 2>/dev/null)"; then
        resolved="$(realpath -e -- "${version_dir}/${target}" 2>/dev/null)" || resolved=""
    fi
    if [[ -z "${resolved}" || "${resolved}" != "${real_version_dir}/"* || ! -f "${resolved}" || ! -x "${resolved}" ]]; then
        _ai_tools_provider_warn MSG-C4F6 "refusing the launcher target for ${launcher}: ${target} does not resolve to an executable file inside ${version_dir}${resolved:+ (it resolves to ${resolved})} -- leaving ${link} as it is"
        return 1
    fi
    # The pattern is held to the relabel's containment first -- a plain path pattern anchored under the directory
    # the resolved version directory sits in -- and then matched whole, as the manifest's own regex,
    # against the resolved path. An invalid regex that passes the containment's charset (an unclosed bracket) makes `=~`
    # return 2, which the `!` reads as no match, and no match is a refusal.
    pattern="^${fcontext}\$"
    containment_root="${real_version_dir%/*}"
    if [[ -z "${fcontext}" ]]; then
        reason="the manifest declares no entrypoint_fcontext to cover ${resolved}"
    elif ! ai_tools_entrypoint_fcontext_valid "${fcontext}" "${containment_root}"; then
        reason="the manifest's entrypoint_fcontext ${fcontext} is not a plain path pattern under ${containment_root}"
    elif ! [[ "${resolved}" =~ ${pattern} ]]; then
        reason="the manifest's entrypoint_fcontext ${fcontext} does not cover ${resolved}"
    else
        reason=""
    fi
    if [[ -n "${reason}" ]]; then
        _ai_tools_provider_warn MSG-F5U2 "refusing the launcher target for ${launcher}: ${reason}, so the file would carry no entrypoint label -- leaving ${link} as it is"
        return 1
    fi
    if [[ -e "${link}" && ! -L "${link}" ]]; then
        _ai_tools_provider_warn MSG-W4H3 "refusing to re-link ${link}: it is not a symlink -- leaving it as it is"
        return 1
    fi
    if [[ "$(readlink -- "${link}" 2>/dev/null)" == "../${target}" ]]; then
        printf 'current'
        return 0
    fi
    tmp="$(mktemp -u "${version_dir}/bin/.${launcher}.XXXXXX" 2>/dev/null)" || tmp=""
    if [[ -z "${tmp}" ]] || ! ln -s "../${target}" "${tmp}" 2>/dev/null || ! mv -Tf "${tmp}" "${link}" 2>/dev/null; then
        [[ -n "${tmp}" ]] && rm -f -- "${tmp}" 2>/dev/null
        _ai_tools_provider_warn MSG-A3S3 "could not write ${link} -> ../${target} -- leaving the launcher as it was"
        return 1
    fi
    printf 'linked'
}
