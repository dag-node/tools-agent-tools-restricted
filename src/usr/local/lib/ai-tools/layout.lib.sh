#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/layout.lib.sh
# The installed layout as one table: every path this project installs or creates on a host, with the owner, mode and ACL
# each is expected to carry, the reader that says what each carries now, and the record stream
# `ai-tools-admin system layout --check` writes from it. Sourced (never executed) by ai-tools-admin
# and tests/integration/perms.sh, as root. The entry grammar, the reading per field, and the guarantees the reconcile
# rests on are layout.rule.md's.
#
# A declared entry is one line of _AI_TOOLS_LAYOUT__STATIC_ENTRIES, seven TAB-separated fields:
#
#     <path> <subject-type> <owner> <mode> <acl> <package> <flags>
#
# validated whole at load (_ai_tools_layout__is_entry_valid and the duplicate check). A table that does not validate
# leaves AI_TOOLS_LAYOUT__DECLARATION_ERROR set: the source still succeeds, so the command can name the refused row,
# and every public reader then returns 2 without output, except ai_tools_layout__write_check_records, which writes
# the one `error` row that is the command's refusal.
#
# One pass owns its observations: ai_tools_layout__begin_pass resets the SELinux applicability and the content
# collector's results, so a second report or a repair that re-reads an entry does not reuse what an earlier pass
# recorded, and a pass that skips rpm cannot read a `verified` an earlier pass left. The public surface is begin_pass,
# ai_tools_layout__list_entries (the entries that apply on this host, in the records framing, sorted by path
# over the static and the dynamic rows together, then an `error` line per input it could not read; returns 1 when it
# printed one), ai_tools_layout__read_entry_state (one entry into the caller's arrays), write_check_records,
# and ai_tools_layout__reconcile, which brings each entry to its row under the rules its own section states.
#
# The library depends on control-plane.lib.sh (the /opt/ai-tools modes stay declared there), operator.lib.sh,
# records-tsv.lib.sh, project-permissions.lib.sh and log.lib.sh, each beside it. Every public function it calls is
# checked with `declare -F` once they are sourced, and a missing one makes the source return 1 rather than leave
# a reader that reads an empty set. It does not source msg.lib.sh: every message is the command's.
#
# Every function that takes a caller's variable name prefixes its own locals `_layout_`, the helpers it calls while
# the nameref is live included, since bash resolves a nameref through the dynamic scope; the output-name check refuses
# that prefix and this module's globals. AI_TOOLS_LAYOUT_ROOT, a root-only test hook (tests.rule.md), prefixes every row
# path and every sentinel, so tests/unit/layout.sh drives the real library over a fixture tree. Unset in production.

# shellcheck disable=SC2034  # include guard, read on the next source of this lib
if [[ -n "${_AI_TOOLS_LAYOUT__LOADED:-}" ]]; then return 0; fi

_ai_tools_layout__library_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=SCRIPTDIR/control-plane.lib.sh
source "${_ai_tools_layout__library_dir}/control-plane.lib.sh" || return 1
# shellcheck source=SCRIPTDIR/operator.lib.sh
source "${_ai_tools_layout__library_dir}/operator.lib.sh" || return 1
# shellcheck source=SCRIPTDIR/records-tsv.lib.sh
source "${_ai_tools_layout__library_dir}/records-tsv.lib.sh" || return 1
# shellcheck source=SCRIPTDIR/project-permissions.lib.sh
source "${_ai_tools_layout__library_dir}/project-permissions.lib.sh" || return 1
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${_ai_tools_layout__library_dir}/log.lib.sh" || return 1
unset _ai_tools_layout__library_dir
for _ai_tools_layout__required in ai_tools_conf__is_trusted ai_tools_conf__read_list \
        ai_tools_conf__read_untrusted_reason ai_tools_conf__read_unreadable_reason \
        ai_tools_providers__read_agent_manifest_field ai_tools_control_plane__is_agent_config_dir_valid \
        ai_tools_records_base__read_subject_type ai_tools_records_tsv__encode_field ai_tools_records_tsv__decode_field \
        ai_tools_records_tsv__frame_item_components ai_tools_records_tsv__write_record \
        ai_tools_project_permissions__get_context_type ai_tools_log__sanitize; do
    declare -F "${_ai_tools_layout__required}" >/dev/null 2>&1 || { unset _ai_tools_layout__required; return 1; }
done
unset _ai_tools_layout__required
readonly _AI_TOOLS_LAYOUT__LOADED=1

readonly _AI_TOOLS_LAYOUT__SANDBOX_USER="@SANDBOX_USER@"
readonly _AI_TOOLS_LAYOUT__SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly _AI_TOOLS_LAYOUT__OPERATORS_GROUP="ai-ops"

# Each package and two `files` paths of its own, space-separated: the package is on this host while either exists,
# so one of them deleted is a `missing` row with its remedy instead of a package that vanished from the table with every
# row it places. A sentinel is a filesystem read, so it answers inside a transaction and on a source install alike;
# an rpm query is not part of applicability. A package with both sentinels gone reads as absent (layout.rule.md).
readonly -A _AI_TOOLS_LAYOUT__PACKAGE_SENTINELS=(
    [ai-tools-base]="/usr/local/libexec/ai-tools/ai-tools-admin /usr/local/lib/ai-tools/conf.lib.sh"
    [ai-tools-integration-nodejs]="/usr/local/libexec/ai-tools/ai-tools-bootstrap /usr/lib/systemd/user/nvm-update.service"
    [ai-tools-agents-claude-code-restricted]="/usr/local/lib/ai-tools/agents.d/claude-code.conf /usr/local/lib/ai-tools/launch.d/claude-code.sh"
    [ai-tools-agents-codex-restricted]="/usr/local/lib/ai-tools/agents.d/codex.conf /usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh"
    [ai-tools-integration-dotnet]="/usr/local/lib/ai-tools/integrations.d/dotnet.conf /usr/local/lib/ai-tools/admin-commands.d/dotnet"
    [ai-tools-integration-typesafe]="/usr/local/lib/ai-tools/integrations.d/typesafe.conf /usr/local/lib/ai-tools/typesafe/decide.mjs"
    [ai-tools-selinux]="/usr/share/selinux/packages/ai-tools /usr/share/selinux/devel/include/distributed/ai_tools.if"
)

# The flags a row may carry (layout.rule.md states what each means).
readonly -a _AI_TOOLS_LAYOUT__FLAGS=( files config ghost optional boundary compressed )

# Set at load when the table does not validate: the first declaration refused and why. Every public reader returns 2
# while it is set.
AI_TOOLS_LAYOUT__DECLARATION_ERROR=""

_AI_TOOLS_LAYOUT__STATIC_ENTRIES=()

# _ai_tools_layout__declare <path> <subject-type> <owner> <mode> <acl> <package> <flags> : append one row.
_ai_tools_layout__declare() {
    local IFS=$'\t'
    _AI_TOOLS_LAYOUT__STATIC_ENTRIES+=( "$*" )
}

# The rows, by package. A comment beside a row states why the mode is what it is where the mode is a decision rather
# than the shape every row of its kind takes.
_ai_tools_layout__declare_static_entries() {
    local su="${_AI_TOOLS_LAYOUT__SANDBOX_USER}" sg="${_AI_TOOLS_LAYOUT__SANDBOX_GROUP}"
    local og="${_AI_TOOLS_LAYOUT__OPERATORS_GROUP}" lib=/usr/local/lib/ai-tools libexec=/usr/local/libexec/ai-tools
    local man=/usr/local/share/man base=ai-tools-base helper library page log relative
    local -a man_pages=(
        man1/ai-tools.1 man5/ai-tools-operator.conf.5 man5/ai-tools-providers.5 man5/ai-tools-allowed-projects.5
        man5/ai-tools-secret-patterns.5 man5/ai-tools-custom-claude-endpoint.conf.5 man5/ai-tools-records.5
        man5/ai-tools-assets.5 man7/ai-tools-messages.7 man8/ai-tools-admin.8
    )

    # ── ai-tools-base ── The root helpers: 0750 root:root, so a non-root account cannot list the directory or run
    # a helper; the CLI and the handback daemon reach each one at its fixed path as root.
    _ai_tools_layout__declare "${libexec}"                 directory root:root 0750 - "${base}" files
    for helper in chown setgid setfacl unclaim lockdown relabel safedir reclaim allowlist audit stop admin handback; do
        _ai_tools_layout__declare "${libexec}/ai-tools-${helper}" file root:root 0750 - "${base}" files
    done
    # The sudo-PATH links: sudoers secure_path on stock EL excludes /usr/local/sbin, so `sudo <name>` resolves here.
    _ai_tools_layout__declare /usr/sbin/ai-tools-admin     link root:root 0777 - "${base}" files
    _ai_tools_layout__declare /usr/sbin/ai-tools           link root:root 0777 - "${base}" files
    # The CLI and the launch wrapper run as the invoking operator; root-owned so the agent cannot rewrite either.
    _ai_tools_layout__declare /usr/local/bin/ai-tools        file root:root 0755 - "${base}" files
    _ai_tools_layout__declare /usr/local/bin/ai-tools-launch file root:root 0755 - "${base}" files
    # Group-executable so the sandbox account runs it from the hooks; no world bit, so no other account reaches
    # the bridge.
    _ai_tools_layout__declare /usr/local/bin/ai-tools-handback-client file root:"${sg}" 0750 - "${base}" files
    for page in "${man_pages[@]}"; do
        _ai_tools_layout__declare "${man}/${page}" file root:root 0644 - "${base}" files,compressed
    done
    # The library directory: world-execute lets an operator outside the sandbox group source a library by path without
    # listing the directory. Every library is 0644: shipped logic, so read is open and root-only write is the boundary.
    _ai_tools_layout__declare "${lib}"                     directory root:"${sg}" 0751 - "${base}" files
    for library in log msg skip-dirs owner-only project-permissions relabel secret-patterns operator control-plane \
            managed-assets safe-paths launch-wrapper confinement npm-verify openpgp entrypoint-verify assets-verify \
            assets conf settings-merge providers ancestor-config sandbox-exec toolchain cache-cleanup selinux-groups \
            filters services path-order agent-installs records-base records-tsv layout; do
        _ai_tools_layout__declare "${lib}/${library}.lib.sh" file root:root 0644 - "${base}" files
    done
    _ai_tools_layout__declare "${lib}/path-order.sh"       file root:root 0644 - "${base}" files
    # The keys and bindings that decide which signer the verifiers accept.
    _ai_tools_layout__declare "${lib}/keys"                directory root:root 0755 - "${base}" files
    _ai_tools_layout__declare "${lib}/keys/dag-node-package-signing.asc" file root:root 0644 - "${base}" files,boundary
    _ai_tools_layout__declare "${lib}/keys/dag-node-package-signing.gpg" file root:root 0644 - "${base}" files,boundary
    _ai_tools_layout__declare "${lib}/assets-bindings.d"   directory root:root 0755 - "${base}" files
    _ai_tools_layout__declare "${lib}/assets-bindings.d/core.conf"     file root:root 0644 - "${base}" files,boundary
    _ai_tools_layout__declare "${lib}/assets-bindings.d/ai-tools.conf" file root:root 0644 - "${base}" files,boundary
    # The provider directories: a group- or other-writable one would let a non-root writer replace a root-owned manifest
    # or fragment inside it, which the trust predicate refuses (providers.rule.md).
    for relative in agents.d integrations.d session-env.d launch.d admin-commands.d filters.d; do
        _ai_tools_layout__declare "${lib}/${relative}"     directory root:root 0755 - "${base}" files,boundary
    done
    _ai_tools_layout__declare "${lib}/filters.d/base.rules" file root:root 0644 - "${base}" files,boundary
    # The confinement shim: the sandbox account executes it and can neither modify nor replace it.
    _ai_tools_layout__declare /opt/ai-tools/bin/ai-tools-run file root:"${sg}" 0550 - "${base}" files,boundary
    _ai_tools_layout__declare /usr/lib/systemd/system/ai-tools-handback.socket   file root:root 0644 - "${base}" files
    _ai_tools_layout__declare /usr/lib/systemd/system/ai-tools-handback@.service file root:root 0644 - "${base}" files
    _ai_tools_layout__declare /usr/lib/systemd/system-preset/85-ai-tools.preset  file root:root 0644 - "${base}" files
    _ai_tools_layout__declare /usr/lib/sysusers.d/ai-tools.conf                  file root:root 0644 - "${base}" files
    _ai_tools_layout__declare /etc/sudoers.d/ai-tools      file root:root 0440 - "${base}" files,config,boundary
    _ai_tools_layout__declare /etc/ai-tools                directory root:root 0755 - "${base}" files
    # World-readable (the agent hooks and the root helpers read it), root-write-only (the agent cannot rewrite
    # the identity root hands files back to).
    _ai_tools_layout__declare /etc/ai-tools/operator.conf  file root:root 0644 - "${base}" files,config,boundary
    _ai_tools_layout__declare /etc/ai-tools/assets-bindings.d directory root:root 0755 - "${base}" files,boundary
    # The sandbox area: the setgid bit makes a clone born in the sandbox group, and the ai-ops entries let an operator
    # outside that group traverse the area, work in a clone, and read the state stamps.
    _ai_tools_layout__declare /var/opt/ai-tools            directory root:"${sg}" 2750 "group:${og}:r-x" \
        "${base}" files
    _ai_tools_layout__declare /var/opt/ai-tools/sandbox-projects directory root:"${sg}" 2770 \
        "group:${og}:rwx,default:group:${og}:rwx" "${base}" files
    _ai_tools_layout__declare /var/opt/ai-tools/README.md  file root:"${sg}" 0640 "group:${og}:r--" "${base}" files
    # Root-owned and not group-writable: the sandbox account traverses and rewrites the stamps it owns in place,
    # and cannot add, unlink, rename or swap anything here.
    _ai_tools_layout__declare /var/opt/ai-tools/state      directory root:"${sg}" 0750 "group:${og}:r-x" \
        "${base}" files
    # The entrypoint pins and the records beside them: root:root, since a pin decides whether a session launches.
    for relative in entrypoint-pin.d entrypoint-label.d entrypoint-stale.d; do
        _ai_tools_layout__declare "/var/opt/ai-tools/state/${relative}" directory root:root 0755 - "${base}" \
            files,boundary
    done
    _ai_tools_layout__declare /var/opt/ai-tools/state/cache-cleanup.status file "${su}:${og}" 0640 - "${base}" \
        files,ghost
    _ai_tools_layout__declare /var/opt/ai-tools/state/cache-cleanup.lock   file root:"${sg}" 0440 - "${base}" \
        files,ghost
    # The operation logs: the sandbox account can neither read nor tamper with the trail.
    _ai_tools_layout__declare /var/log/ai-tools            directory root:root 0700 - "${base}" files
    for log in chown setgid setfacl symlink lockdown relabel handback install layout; do
        _ai_tools_layout__declare "/var/log/ai-tools/${log}.log" file root:root 0600 - "${base}" files,ghost
    done
    # The control plane, at the modes control-plane.lib.sh declares.
    _ai_tools_layout__declare "${CP_HOME}"                 directory root:"${sg}" "${CP_HOME_MODE}" - "${base}" files
    for relative in bin skills subagents orientation integrations; do
        _ai_tools_layout__declare "${CP_HOME}/${relative}" directory root:"${sg}" "${CP_DIR_MODES[${relative}]}" - \
            "${base}" files
    done
    _ai_tools_layout__declare /usr/share/ai-tools          directory root:root 0755 - "${base}" files
    _ai_tools_layout__declare /usr/share/ai-tools/audit    directory root:root 0755 - "${base}" files,optional
    _ai_tools_layout__declare /usr/share/ai-tools/audit/ai-tools-cmd.rules.example file root:root 0644 - "${base}" \
        files,optional
    # Created at runtime by the scriptlet and the installer, not rpm-owned, so an erase keeps them.
    _ai_tools_layout__declare "${CP_HOME}/.gitconfig"      file root:"${sg}" 0644 - "${base}" -
    _ai_tools_layout__declare "${CP_HOME}/.gitignore"      file root:"${sg}" 0640 - "${base}" -
    # The sandbox account's systemd unit search path, root-owned on the way to it (ownership-and-hooks.rule.md);
    # the timer-stamp directory at the end stays the account's, since its manager writes the Persistent= stamps.
    for relative in "${CP_UNIT_SEARCH_PATH_CHAIN[@]}"; do
        _ai_tools_layout__declare "${CP_HOME}/${relative}" directory root:"${sg}" \
            "${CP_UNIT_SEARCH_PATH_MODES[${relative}]}" - "${base}" -
    done
    _ai_tools_layout__declare "${CP_HOME}/${CP_TIMER_STAMP_DIR}" directory "${su}:${sg}" "${CP_TIMER_STAMP_DIR_MODE}" - \
        "${base}" -
    _ai_tools_layout__declare "${CP_SHARED_ORIENTATION}/AGENTS.md" file root:"${sg}" 0640 - "${base}" optional

    # ── ai-tools-integration-nodejs ──
    for helper in launcher-symlink relabel-agent bootstrap; do
        _ai_tools_layout__declare "${libexec}/ai-tools-${helper}" file root:root 0750 - ai-tools-integration-nodejs files
    done
    _ai_tools_layout__declare /opt/ai-tools/bin/nvm-update.sh file root:"${sg}" 0550 - ai-tools-integration-nodejs \
        files,boundary
    _ai_tools_layout__declare /var/opt/ai-tools/state/nvm-update.status file "${su}:${og}" 0640 - \
        ai-tools-integration-nodejs files,ghost,optional
    _ai_tools_layout__declare /usr/lib/systemd/user/nvm-update.service      file root:root 0644 - \
        ai-tools-integration-nodejs files
    _ai_tools_layout__declare /usr/lib/systemd/user/nvm-update.timer        file root:root 0644 - \
        ai-tools-integration-nodejs files
    _ai_tools_layout__declare /usr/lib/systemd/system/ai-tools-relabel.path    file root:root 0644 - \
        ai-tools-integration-nodejs files
    _ai_tools_layout__declare /usr/lib/systemd/system/ai-tools-relabel.service file root:root 0644 - \
        ai-tools-integration-nodejs files
    # The account's `--user` unit configuration: root-owned, so a confined session cannot register a unit the account's
    # unconfined manager runs.
    _ai_tools_layout__declare "${CP_HOME}/.config/systemd/user" directory root:"${sg}" 2750 - \
        ai-tools-integration-nodejs -
    _ai_tools_layout__declare "${CP_HOME}/.config/systemd/user/timers.target.wants" directory root:"${sg}" 2750 - \
        ai-tools-integration-nodejs -

    # ── ai-tools-agents-claude-code-restricted ──
    local claude=ai-tools-agents-claude-code-restricted
    for relative in agents.d/claude-code.conf keys/claude-code.asc session-env.d/claude-code.pins.env.sh \
            session-env.d/claude-code.env.sh claude-prompt.lib.sh claude-endpoint.lib.sh launch.d/claude-code.sh; do
        _ai_tools_layout__declare "${lib}/${relative}"     file root:root 0644 - "${claude}" files,boundary
    done
    _ai_tools_layout__declare /usr/local/bin/claude        link root:root 0777 - "${claude}" files
    _ai_tools_layout__declare /etc/ai-tools/prompts        directory root:root 0755 - "${claude}" files
    _ai_tools_layout__declare /etc/ai-tools/prompts/claude-system-prompt.md file root:"${sg}" 0640 - "${claude}" \
        files,config
    # Owned by either package that installs a file in it, on the same attributes.
    _ai_tools_layout__declare /etc/ai-tools/endpoints      directory root:root 0755 - \
        "${claude},ai-tools-integration-typesafe" files
    # 0640: the file may hold a bearer token, which the sandbox account needs and an operator does not.
    _ai_tools_layout__declare /etc/ai-tools/endpoints/custom-claude-endpoint.conf file root:"${sg}" 0640 - "${claude}" \
        files,config
    for relative in post-tool-hook.sh session-hook.sh filter-hook.sh; do
        _ai_tools_layout__declare "${CP_HOME}/.claude/${relative}" file root:"${sg}" 0750 - "${claude}" files,boundary
    done
    _ai_tools_layout__declare "${CP_HOME}/.claude/settings.json" file root:"${sg}" 0640 - "${claude}" \
        files,config,boundary

    # ── ai-tools-agents-codex-restricted ──
    local codex=ai-tools-agents-codex-restricted
    for relative in post-tool-hook.sh session-hook.sh; do
        _ai_tools_layout__declare "${CP_HOME}/.codex/${relative}" file root:"${sg}" 0750 - "${codex}" files,boundary
    done
    _ai_tools_layout__declare "${lib}/agents.d/codex.conf" file root:root 0644 - "${codex}" files,boundary
    _ai_tools_layout__declare "${lib}/session-env.d/codex.pins.env.sh" file root:root 0644 - "${codex}" files,boundary
    _ai_tools_layout__declare /usr/local/bin/codex         link root:root 0777 - "${codex}" files
    _ai_tools_layout__declare /etc/codex                   directory root:root 0755 - "${codex}" files
    _ai_tools_layout__declare /etc/codex/requirements.toml   file root:root 0644 - "${codex}" files,config
    _ai_tools_layout__declare /etc/codex/managed_config.toml file root:root 0644 - "${codex}" files,config
    _ai_tools_layout__declare /usr/share/ai-tools/codex    directory root:root 0755 - "${codex}" files
    _ai_tools_layout__declare /usr/share/ai-tools/codex/requirements.toml   file root:root 0644 - "${codex}" files
    _ai_tools_layout__declare /usr/share/ai-tools/codex/managed_config.toml file root:root 0644 - "${codex}" files

    # ── ai-tools-integration-dotnet ──
    local dotnet=ai-tools-integration-dotnet
    for relative in session-env.d/dotnet.env.sh integrations.d/dotnet.conf filters.d/dotnet.rules; do
        _ai_tools_layout__declare "${lib}/${relative}"     file root:root 0644 - "${dotnet}" files,boundary
    done
    # A command ai-tools-admin executes as root, so 0750 like every root helper.
    _ai_tools_layout__declare "${lib}/admin-commands.d/dotnet" file root:root 0750 - "${dotnet}" files,boundary
    _ai_tools_layout__declare /var/log/ai-tools/dotnet.log file root:root 0600 - "${dotnet}" files,ghost

    # ── ai-tools-integration-typesafe ──
    local typesafe=ai-tools-integration-typesafe
    # Read by node as the sandbox account and written by root alone, so the agent cannot change what a call sends.
    _ai_tools_layout__declare "${lib}/typesafe"            directory root:root 0755 - "${typesafe}" files
    for relative in decide.mjs transport.mjs LICENSE; do
        _ai_tools_layout__declare "${lib}/typesafe/${relative}" file root:root 0644 - "${typesafe}" files
    done
    for relative in session-env.d/typesafe.env.sh integrations.d/typesafe.conf; do
        _ai_tools_layout__declare "${lib}/${relative}"     file root:root 0644 - "${typesafe}" files,boundary
    done
    # An API key: the same 0640 root:<sandbox group> as the endpoint file.
    _ai_tools_layout__declare /etc/ai-tools/endpoints/typesafe.conf file root:"${sg}" 0640 - "${typesafe}" files,config
    _ai_tools_layout__declare "${man}/man5/ai-tools-typesafe.conf.5" file root:root 0644 - "${typesafe}" \
        files,compressed
    # The one path a call writes: agent-writable, setgid so its log is group-owned.
    _ai_tools_layout__declare "${CP_INTEGRATIONS}/typesafe" directory root:"${sg}" 2770 - "${typesafe}" files

    # ── ai-tools-selinux ──
    _ai_tools_layout__declare /usr/share/selinux/packages/ai-tools directory root:root 0755 - ai-tools-selinux files
    _ai_tools_layout__declare /usr/share/selinux/devel/include/distributed/ai_tools.if file root:root 0644 - \
        ai-tools-selinux files
}

# ── Validation ───────────────────────────────────────────────────────────────────────────────

# _ai_tools_layout__get_mode_bits <mode> <class> <out-var> : the rwx string of one class of a four-digit mode,
# where <class> is u, g or o.
_ai_tools_layout__get_mode_bits() {
    local -n _layout_bits_out="$3"
    local _layout_bits_digit _layout_bits_perms=""
    case "$2" in
        u) _layout_bits_digit="${1:1:1}" ;;
        g) _layout_bits_digit="${1:2:1}" ;;
        *) _layout_bits_digit="${1:3:1}" ;;
    esac
    (( _layout_bits_digit & 4 )) && _layout_bits_perms+=r || _layout_bits_perms+=-
    (( _layout_bits_digit & 2 )) && _layout_bits_perms+=w || _layout_bits_perms+=-
    (( _layout_bits_digit & 1 )) && _layout_bits_perms+=x || _layout_bits_perms+=-
    _layout_bits_out="${_layout_bits_perms}"
}

# _ai_tools_layout__is_permission_within <perm> <limit> : 0 when every bit <perm> sets is set in <limit>, both rwx
# strings.
_ai_tools_layout__is_permission_within() {
    local i
    for (( i = 0; i < 3; i++ )); do
        [[ "${1:i:1}" == - || "${2:i:1}" != - ]] || return 1
    done
    return 0
}

# _ai_tools_layout__is_entry_valid <entry> static|dynamic : pure. 0 when <entry> is a well-formed row
# of that provenance: seven TAB-separated fields; an absolute normalized path (a static one of printable ASCII without
# whitespace, `\` or a glob character; a dynamic one carries an operator's home as the account database spells it);
# a subject-type of file, directory or link; an owner `user:group`; a four-digit octal mode, 0777 on a link; an ACL
# of named entries whose bits do not exceed the mode's group bits, at most one named user and one named group per block
# (so the text compares in getfacl's order), a default block on a directory alone, `-` on a link; a static package
# with a sentinel, or a comma list of them on a directory alone, and `-` for a dynamic row; flags `-` or a non-empty
# list from the set, config or ghost beside files alone, compressed on a file alone. Prints the reason on stdout
# and returns 1 otherwise.
_ai_tools_layout__is_entry_valid() {
    local entry="$1" provenance="$2" path subject_type owner mode acl packages flags rest acl_entry flag package
    local group_bits perm tag candidate known
    local -a fields=() acl_entries=() flag_list=() package_list=()
    local -A acl_seen=()
    rest="${entry}"
    while [[ "${rest}" == *$'\t'* ]]; do fields+=( "${rest%%$'\t'*}" ); rest="${rest#*$'\t'}"; done
    fields+=( "${rest}" )
    (( ${#fields[@]} == 7 )) || { printf 'expected 7 fields, found %s' "${#fields[@]}"; return 1; }
    path="${fields[0]}" subject_type="${fields[1]}" owner="${fields[2]}" mode="${fields[3]}" acl="${fields[4]}"
    packages="${fields[5]}" flags="${fields[6]}"
    local LC_ALL=C
    if [[ "${path}" != /?* || "${path}" == */ || "${path}" == *//* || "${path}" == */./* || "${path}" == */../* \
            || "${path}" == */. || "${path}" == */.. || "${path}" == *$'\n'* ]]; then
        printf 'path %s is not an absolute normalized path' "${path}"; return 1
    fi
    if [[ "${provenance}" == static ]] \
            && [[ ! "${path}" =~ ^/[!-~]+$ || "${path}" == *\\* || "${path}" == *[\*\?\[]* ]]; then
        printf 'path %s is not printable ASCII without whitespace, a backslash or a glob character' "${path}"; return 1
    fi
    case "${subject_type}" in
        file|directory|link) ;;
        *) printf '%s: subject-type %s is not file, directory or link' "${path}" "${subject_type}"; return 1 ;;
    esac
    [[ "${owner}" =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] \
        || { printf '%s: owner %s is not user:group' "${path}" "${owner}"; return 1; }
    [[ "${mode}" =~ ^[0-7]{4}$ ]] || { printf '%s: mode %s is not four octal digits' "${path}" "${mode}"; return 1; }
    if [[ "${subject_type}" == link ]]; then
        [[ "${mode}" == 0777 ]] || { printf '%s: a link row carries mode 0777' "${path}"; return 1; }
        [[ "${acl}" == - ]] || { printf '%s: a link row carries no ACL' "${path}"; return 1; }
    fi
    if [[ "${acl}" != - ]]; then
        _ai_tools_layout__get_mode_bits "${mode}" g group_bits
        IFS=, read -ra acl_entries <<< "${acl}"
        for acl_entry in "${acl_entries[@]}"; do
            [[ "${acl_entry}" =~ ^(default:)?(user|group):[a-z_][a-z0-9_-]*:([r-][w-][x-])$ ]] \
                || { printf '%s: ACL entry %s is not a named entry' "${path}" "${acl_entry}"; return 1; }
            tag="${BASH_REMATCH[1]}${BASH_REMATCH[2]}" perm="${BASH_REMATCH[3]}"
            if [[ -n "${BASH_REMATCH[1]}" && "${subject_type}" != directory ]]; then
                printf '%s: a default ACL entry applies to a directory row alone' "${path}"; return 1
            fi
            if [[ -n "${acl_seen[${tag}]+x}" ]]; then
                printf '%s: a second %s entry; one named user and one named group per ACL block' "${path}" "${tag}"
                return 1
            fi
            acl_seen["${tag}"]=1
            _ai_tools_layout__is_permission_within "${perm}" "${group_bits}" \
                || { printf '%s: ACL entry %s exceeds the mode group bits %s' "${path}" "${acl_entry}" "${group_bits}"
                     return 1; }
        done
    fi
    if [[ "${provenance}" == dynamic ]]; then
        [[ "${packages}" == - ]] || { printf '%s: a dynamic row carries package -' "${path}"; return 1; }
    else
        IFS=, read -ra package_list <<< "${packages}"
        (( ${#package_list[@]} > 0 )) || { printf '%s: no package' "${path}"; return 1; }
        if (( ${#package_list[@]} > 1 )) && [[ "${subject_type}" != directory ]]; then
            printf '%s: a package list applies to a directory row alone' "${path}"; return 1
        fi
        for package in "${package_list[@]}"; do
            [[ -n "${_AI_TOOLS_LAYOUT__PACKAGE_SENTINELS[${package}]+x}" ]] \
                || { printf '%s: package %s has no sentinel' "${path}" "${package}"; return 1; }
        done
    fi
    if [[ "${flags}" != - ]]; then
        [[ -n "${flags}" ]] || { printf '%s: flags is - or a list' "${path}"; return 1; }
        IFS=, read -ra flag_list <<< "${flags}"
        for flag in "${flag_list[@]}"; do
            known=0
            for candidate in "${_AI_TOOLS_LAYOUT__FLAGS[@]}"; do
                [[ "${flag}" == "${candidate}" ]] && { known=1; break; }
            done
            (( known )) || { printf '%s: flag %s is not one of %s' "${path}" "${flag}" "${_AI_TOOLS_LAYOUT__FLAGS[*]}"
                             return 1; }
        done
        if [[ ",${flags}," == *,config,* || ",${flags}," == *,ghost,* ]] && [[ ",${flags}," != *,files,* ]]; then
            printf '%s: config and ghost apply to a files row alone' "${path}"; return 1
        fi
        if [[ ",${flags}," == *,compressed,* && "${subject_type}" != file ]]; then
            printf '%s: compressed applies to a file row alone' "${path}"; return 1
        fi
    fi
    return 0
}

# _ai_tools_layout__validate_table : set AI_TOOLS_LAYOUT__DECLARATION_ERROR to the first declaration refused, or a path
# declared twice; leave it empty when every row validates.
_ai_tools_layout__validate_table() {
    local entry reason path
    local -A seen=()
    AI_TOOLS_LAYOUT__DECLARATION_ERROR=""
    for entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do
        if ! reason="$(_ai_tools_layout__is_entry_valid "${entry}" static)"; then
            AI_TOOLS_LAYOUT__DECLARATION_ERROR="${reason}"; return 1
        fi
        path="${entry%%$'\t'*}"
        if [[ -n "${seen[${path}]+x}" ]]; then
            AI_TOOLS_LAYOUT__DECLARATION_ERROR="${path} is declared twice"; return 1
        fi
        seen["${path}"]=1
    done
    return 0
}

_ai_tools_layout__declare_static_entries
readonly -a _AI_TOOLS_LAYOUT__STATIC_ENTRIES
_ai_tools_layout__validate_table || true

# ── The entry set ────────────────────────────────────────────────────────────────────────────
# A line of ai_tools_layout__list_entries is one of two shapes, every field through ai_tools_records_tsv__encode_field:
#
#     <path> <subject-type> <owner> <mode> <acl> <package> <flags> <operator>   an entry; operator empty host-wide
#     error <subject-type> <subject> <source> <reason>                           an input that could not be read
#
# A path is absolute, so a first field `error` names the second shape.

# _ai_tools_layout__get_root : print the test hook's prefix, empty in production.
_ai_tools_layout__get_root() { printf '%s' "${AI_TOOLS_LAYOUT_ROOT:-}"; }

# _ai_tools_layout__encode_line <out-var> <field>... : one line into <out-var>, each field encoded, TAB-separated.
_ai_tools_layout__encode_line() {
    local -n _layout_encode_out="$1"
    local _layout_encode_field _layout_encode_encoded _layout_encode_line="" _layout_encode_first=1
    shift
    for _layout_encode_field in "$@"; do
        ai_tools_records_tsv__encode_field _layout_encode_encoded "${_layout_encode_field}"
        if (( _layout_encode_first )); then
            _layout_encode_line="${_layout_encode_encoded}"; _layout_encode_first=0
        else
            _layout_encode_line+=$'\t'"${_layout_encode_encoded}"
        fi
    done
    _layout_encode_out="${_layout_encode_line}"
}

# ai_tools_layout__parse_line <line> <array-var> : decode one line into the caller's array, one element per field.
# Splits on TAB by hand, since `IFS=$'\t' read` collapses empty fields. Returns 1 and empties the array when a field
# does not decode.
ai_tools_layout__parse_line() {
    local -n _layout_parse_out="$2"
    local _layout_parse_rest="$1" _layout_parse_field _layout_parse_decoded
    _layout_parse_out=()
    while :; do
        _layout_parse_field="${_layout_parse_rest%%$'\t'*}"
        if ! ai_tools_records_tsv__decode_field _layout_parse_decoded "${_layout_parse_field}"; then
            _layout_parse_out=(); return 1
        fi
        _layout_parse_out+=( "${_layout_parse_decoded}" )
        [[ "${_layout_parse_rest}" == *$'\t'* ]] || break
        _layout_parse_rest="${_layout_parse_rest#*$'\t'}"
    done
    return 0
}

# _ai_tools_layout__is_package_present <package> : 0 when one of the package's sentinels exists under the root (lstat).
_ai_tools_layout__is_package_present() {
    local sentinel root
    local -a sentinels=()
    root="$(_ai_tools_layout__get_root)"
    read -ra sentinels <<< "${_AI_TOOLS_LAYOUT__PACKAGE_SENTINELS[$1]:-}"
    for sentinel in "${sentinels[@]}"; do
        [[ -e "${root}${sentinel}" || -L "${root}${sentinel}" ]] && return 0
    done
    return 1
}

# _ai_tools_layout__append_static_entries <entries-var> : append the static rows that apply on this host to the caller's
# indexed array, the root prefixed, a compressed row resolved to the `.gz` where one exists. Unsorted.
_ai_tools_layout__append_static_entries() {
    local -n _layout_static_out="$1"
    local _layout_static_entry _layout_static_path _layout_static_type _layout_static_owner _layout_static_mode
    local _layout_static_acl _layout_static_packages _layout_static_flags _layout_static_package _layout_static_applies
    local _layout_static_root _layout_static_line
    local -a _layout_static_package_list=()
    _layout_static_root="$(_ai_tools_layout__get_root)"
    for _layout_static_entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do
        IFS=$'\t' read -r _layout_static_path _layout_static_type _layout_static_owner _layout_static_mode \
            _layout_static_acl _layout_static_packages _layout_static_flags <<< "${_layout_static_entry}"
        _layout_static_applies=0
        IFS=, read -ra _layout_static_package_list <<< "${_layout_static_packages}"
        for _layout_static_package in "${_layout_static_package_list[@]}"; do
            if _ai_tools_layout__is_package_present "${_layout_static_package}"; then _layout_static_applies=1; break; fi
        done
        (( _layout_static_applies )) || continue
        _layout_static_path="${_layout_static_root}${_layout_static_path}"
        if [[ ",${_layout_static_flags}," == *,compressed,* ]] \
                && [[ -e "${_layout_static_path}.gz" || -L "${_layout_static_path}.gz" ]]; then
            _layout_static_path+=.gz
        fi
        _ai_tools_layout__encode_line _layout_static_line "${_layout_static_path}" "${_layout_static_type}" \
            "${_layout_static_owner}" "${_layout_static_mode}" "${_layout_static_acl}" "${_layout_static_packages}" \
            "${_layout_static_flags}" ""
        _layout_static_out+=( "${_layout_static_line}" )
    done
}

# _ai_tools_layout__append_dynamic_entries <entries-var> <errors-var> : append one row per installed agent config
# directory and three per enrolled operator to the caller's entries array, and an `error` line to the errors array
# for each input that could not be read. Each input is read through ai_tools_records_base__read_subject_type
# and ai_tools_conf__is_trusted before anything in it: an absent input does not contribute a row (the static row for it
# reports the absence), and an input that is present but unreadable, untrusted, of another type, or not parsed whole is
# an `error` line rather than an empty set. Unsorted.
_ai_tools_layout__append_dynamic_entries() {
    local -n _layout_dynamic_out="$1" _layout_dynamic_errors="$2"
    local _layout_dynamic_root _layout_dynamic_status _layout_dynamic_type _layout_dynamic_manifest _layout_dynamic_agent
    local _layout_dynamic_config_dir _layout_dynamic_path _layout_dynamic_operator _layout_dynamic_home
    local _layout_dynamic_group _layout_dynamic_entry _layout_dynamic_line _layout_dynamic_index
    local -a _layout_dynamic_operators=()
    local -a _layout_dynamic_relative=( "" /allowed-projects /secret-patterns )
    local -a _layout_dynamic_types=( directory file file )
    local -a _layout_dynamic_modes=( 0700 0600 0600 )
    local -a _layout_dynamic_flags=( boundary boundary 'optional,boundary' )
    local -A _layout_dynamic_homes=() _layout_dynamic_declared=()
    _layout_dynamic_root="$(_ai_tools_layout__get_root)"
    for _layout_dynamic_entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do
        _layout_dynamic_declared["${_layout_dynamic_root}${_layout_dynamic_entry%%$'\t'*}"]=1
    done

    # One directory row per installed agent manifest with a valid config_dir: installation decides, as the package's
    # %dir does.
    _layout_dynamic_status=0
    _layout_dynamic_type="$(ai_tools_records_base__read_subject_type "${AI_TOOLS_AGENTS_DIR}")" \
        || _layout_dynamic_status=$?
    if (( _layout_dynamic_status == 0 )) && [[ "${_layout_dynamic_type}" == directory ]]; then
        if ! ai_tools_conf__is_trusted "${AI_TOOLS_AGENTS_DIR}"; then
            _ai_tools_layout__encode_line _layout_dynamic_line error directory "${AI_TOOLS_AGENTS_DIR}" agents \
                "$(ai_tools_conf__read_untrusted_reason "${AI_TOOLS_AGENTS_DIR}")"
            _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
        else
            for _layout_dynamic_manifest in "${AI_TOOLS_AGENTS_DIR}"/*.conf; do
                [[ -e "${_layout_dynamic_manifest}" || -L "${_layout_dynamic_manifest}" ]] || continue
                if ! ai_tools_conf__is_trusted "${_layout_dynamic_manifest}"; then
                    _ai_tools_layout__encode_line _layout_dynamic_line error file "${_layout_dynamic_manifest}" agents \
                        "$(ai_tools_conf__read_untrusted_reason "${_layout_dynamic_manifest}")"
                    _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                    continue
                fi
                _layout_dynamic_agent="${_layout_dynamic_manifest##*/}"
                _layout_dynamic_agent="${_layout_dynamic_agent%.conf}"
                # Status 1 is a manifest without the key (no config directory); 2 is a manifest not read whole
                # as trusted data, which is not an empty value.
                _layout_dynamic_status=0
                _layout_dynamic_config_dir="$(ai_tools_providers__read_agent_manifest_field "${_layout_dynamic_agent}" \
                    config_dir 2>/dev/null)" || _layout_dynamic_status=$?
                (( _layout_dynamic_status != 1 )) || continue
                if (( _layout_dynamic_status != 0 )) \
                        || ! ai_tools_control_plane__is_agent_config_dir_valid "${_layout_dynamic_config_dir}"; then
                    _ai_tools_layout__encode_line _layout_dynamic_line error file "${_layout_dynamic_manifest}" agents \
                        "config_dir was not read as one path component under ${CP_HOME}"
                    _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                    continue
                fi
                _layout_dynamic_path="${_layout_dynamic_root}${CP_HOME}/${_layout_dynamic_config_dir}"
                if [[ -n "${_layout_dynamic_declared[${_layout_dynamic_path}]+x}" ]]; then
                    _ai_tools_layout__encode_line _layout_dynamic_line error directory "${_layout_dynamic_path}" \
                        agents "the manifest's config_dir is a path the table declares"
                    _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                    continue
                fi
                _layout_dynamic_declared["${_layout_dynamic_path}"]=1
                _ai_tools_layout__encode_line _layout_dynamic_line "${_layout_dynamic_path}" directory \
                    "root:${_AI_TOOLS_LAYOUT__SANDBOX_GROUP}" "${CP_AGENT_CONFIG_MODE}" - - - ""
                _layout_dynamic_out+=( "${_layout_dynamic_line}" )
            done
        fi
    elif (( _layout_dynamic_status != 2 )); then
        _ai_tools_layout__encode_line _layout_dynamic_line error directory "${AI_TOOLS_AGENTS_DIR}" agents \
            "the entry is not a directory, or its type could not be read"
        _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
    fi

    # Three rows per enrolled operator. The list reader's status 1 is the complete empty set (no OPERATORS key); 2
    # and an untrusted file are an `error` line, as is a value the reader does not parse as a list, which it reports
    # as an empty array with ai_tools_conf__list_invalid set.
    _layout_dynamic_status=0
    _layout_dynamic_type="$(ai_tools_records_base__read_subject_type "${AI_TOOLS_OPERATOR_CONF}")" \
        || _layout_dynamic_status=$?
    if (( _layout_dynamic_status == 0 )) && [[ "${_layout_dynamic_type}" == file ]]; then
        if ! ai_tools_conf__is_trusted "${AI_TOOLS_OPERATOR_CONF}"; then
            _ai_tools_layout__encode_line _layout_dynamic_line error file "${AI_TOOLS_OPERATOR_CONF}" operators \
                "$(ai_tools_conf__read_untrusted_reason "${AI_TOOLS_OPERATOR_CONF}")"
            _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
        else
            _layout_dynamic_status=0
            ai_tools_conf__read_list _layout_dynamic_operators "${AI_TOOLS_OPERATOR_CONF}" OPERATORS 2>/dev/null \
                || _layout_dynamic_status=$?
            if (( _layout_dynamic_status == 2 )); then
                _ai_tools_layout__encode_line _layout_dynamic_line error file "${AI_TOOLS_OPERATOR_CONF}" operators \
                    "$(ai_tools_conf__read_unreadable_reason "${AI_TOOLS_OPERATOR_CONF}")"
                _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                _layout_dynamic_operators=()
            elif (( _layout_dynamic_status != 0 )); then
                _layout_dynamic_operators=()
            elif (( ${ai_tools_conf__list_invalid:-0} )); then
                _ai_tools_layout__encode_line _layout_dynamic_line error file "${AI_TOOLS_OPERATOR_CONF}" operators \
                    "OPERATORS does not parse as a list"
                _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                _layout_dynamic_operators=()
            fi
            for _layout_dynamic_operator in "${_layout_dynamic_operators[@]}"; do
                # The enrolment placeholder the package ships is not an account.
                [[ "${_layout_dynamic_operator}" == @*@ ]] && continue
                _layout_dynamic_home="$(getent passwd "${_layout_dynamic_operator}" 2>/dev/null | cut -d: -f6)" \
                    || _layout_dynamic_home=""
                _layout_dynamic_group="$(id -gn "${_layout_dynamic_operator}" 2>/dev/null)" || _layout_dynamic_group=""
                if [[ -z "${_layout_dynamic_home}" || -z "${_layout_dynamic_group}" \
                        || ! -d "${_layout_dynamic_home}" ]]; then
                    _ai_tools_layout__encode_line _layout_dynamic_line error operator "${_layout_dynamic_operator}" \
                        operators "the account does not resolve to a home directory"
                    _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                    continue
                fi
                # An operator whose home another operator shares yields its rows once, under the first name.
                [[ -z "${_layout_dynamic_homes[${_layout_dynamic_home}]+x}" ]] || continue
                _layout_dynamic_homes["${_layout_dynamic_home}"]="${_layout_dynamic_operator}"
                for _layout_dynamic_index in 0 1 2; do
                    _layout_dynamic_path="${_layout_dynamic_root}${_layout_dynamic_home}/.config/ai-tools"
                    _layout_dynamic_path+="${_layout_dynamic_relative[${_layout_dynamic_index}]}"
                    if [[ -n "${_layout_dynamic_declared[${_layout_dynamic_path}]+x}" ]]; then
                        _ai_tools_layout__encode_line _layout_dynamic_line error \
                            "${_layout_dynamic_types[${_layout_dynamic_index}]}" "${_layout_dynamic_path}" operators \
                            "an operator path is a path the table declares"
                        _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
                        continue
                    fi
                    _layout_dynamic_declared["${_layout_dynamic_path}"]=1
                    _ai_tools_layout__encode_line _layout_dynamic_line "${_layout_dynamic_path}" \
                        "${_layout_dynamic_types[${_layout_dynamic_index}]}" \
                        "${_layout_dynamic_operator}:${_layout_dynamic_group}" \
                        "${_layout_dynamic_modes[${_layout_dynamic_index}]}" - - \
                        "${_layout_dynamic_flags[${_layout_dynamic_index}]}" "${_layout_dynamic_operator}"
                    _layout_dynamic_out+=( "${_layout_dynamic_line}" )
                done
            done
        fi
    elif (( _layout_dynamic_status != 2 )); then
        _ai_tools_layout__encode_line _layout_dynamic_line error file "${AI_TOOLS_OPERATOR_CONF}" operators \
            "the entry is not a regular file, or its type could not be read"
        _layout_dynamic_errors+=( "${_layout_dynamic_line}" )
    fi
}

# ai_tools_layout__list_entries : print every entry that applies on this host, the static and the dynamic rows sorted
# together by path in the C locale so a parent precedes every path under it, then an `error` line for each input
# that could not be read. Returns 0 when discovery was complete, 1 when it printed an `error` line, and 2 without
# printing when the table did not validate.
ai_tools_layout__list_entries() {
    [[ -z "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]] || return 2
    local _layout_list_sorted _layout_list_line
    local -a _layout_list_entries=() _layout_list_errors=()
    _ai_tools_layout__append_static_entries _layout_list_entries
    _ai_tools_layout__append_dynamic_entries _layout_list_entries _layout_list_errors
    if (( ${#_layout_list_entries[@]} > 0 )); then
        if _layout_list_sorted="$(printf '%s\n' "${_layout_list_entries[@]}" | LC_ALL=C sort -t $'\t' -k1,1)"; then
            printf '%s\n' "${_layout_list_sorted}"
        else
            _ai_tools_layout__encode_line _layout_list_line error host layout.lib.sh entries "sort did not complete"
            _layout_list_errors+=( "${_layout_list_line}" )
        fi
    fi
    (( ${#_layout_list_errors[@]} == 0 )) && return 0
    printf '%s\n' "${_layout_list_errors[@]}"
    return 1
}

# ── The pass ─────────────────────────────────────────────────────────────────────────────────
# What one pass observes once and every entry read in it shares: whether SELinux labels apply, and what `rpm -V` said
# per package and per path. ai_tools_layout__begin_pass resets them. Every map here and below is `declare -gA`:
# ai-tools-admin sources this file inside a function, where a bare `declare` makes the map that function's local,
# and the reset after it returns recreates the name as an indexed array whose subscript is arithmetic.
_AI_TOOLS_LAYOUT__PASS_WITHOUT_RPM=0
_AI_TOOLS_LAYOUT__SELINUX=""
declare -gA _AI_TOOLS_LAYOUT__PACKAGE_VERIFY=()
declare -gA _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON=()
declare -gA _AI_TOOLS_LAYOUT__CONTENT_FLAGS=()

# ai_tools_layout__begin_pass <without-rpm> : start one pass -- forget every observation an earlier pass recorded,
# and record whether this one reads rpm (0) or leaves every package file `unverified` (1). Called once before the first
# read_entry_state of a report or a repair.
ai_tools_layout__begin_pass() {
    _AI_TOOLS_LAYOUT__PASS_WITHOUT_RPM="${1:-0}"
    _AI_TOOLS_LAYOUT__SELINUX=""
    _AI_TOOLS_LAYOUT__PACKAGE_VERIFY=()
    _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON=()
    _AI_TOOLS_LAYOUT__CONTENT_FLAGS=()
}

# _ai_tools_layout__read_selinux_state : set the label applicability, `n/a` where /sys/fs/selinux/enforce does not exist
# or getenforce prints Disabled, `active` otherwise.
_ai_tools_layout__read_selinux_state() {
    if [[ ! -e /sys/fs/selinux/enforce ]] || [[ "$(getenforce 2>/dev/null || true)" == Disabled ]]; then
        _AI_TOOLS_LAYOUT__SELINUX=n/a
    else
        _AI_TOOLS_LAYOUT__SELINUX=active
    fi
}

# _ai_tools_layout__clamp_reason <text> : the first 120 bytes of <text> through ai_tools_log__sanitize, for a line
# another program wrote that a record carries.
_ai_tools_layout__clamp_reason() { ai_tools_log__sanitize "${1:0:120}"; }

# _ai_tools_layout__list_package_verify_results <package> : the rpm -V collector for one package, verbose so every
# payload file prints a line (`.........` for one that passed), which is the positive evidence a `verified` state rests
# on. Prints one line per path, `<flags><TAB><path>` with the root prefixed, and `error<TAB><reason>` for a line it does
# not recognize; exits with rpm's status. Dependencies and %verifyscript are left out: a line of theirs would read
# as an unrecognized one, and the collector does not run package-defined code. Stderr is merged, so an rpm warning is
# an unrecognized line too. The attribute marker is one lowercase letter: the path begins with `/`, so the parse stays
# unambiguous across the marker sets rpm versions document.
_ai_tools_layout__list_package_verify_results() {
    # The C locale for the match as for the command: the path range collates differently under UTF-8.
    local LC_ALL=C root line fd pid status=0
    root="$(_ai_tools_layout__get_root)"
    exec {fd}< <(LC_ALL=C rpm -Vv --nodeps --noscripts --nouser --nogroup --nomode --nomtime --nordev --nocaps \
        --nolinkto -- "$1" 2>&1); pid=$!
    while IFS= read -r -u "${fd}" line; do
        if [[ "${line}" =~ ^([SM5DLUGTP.?]{9})\ +([a-z]\ )?(/[!-~]+)$ ]]; then
            printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${root}${BASH_REMATCH[3]}"
        elif [[ "${line}" =~ ^missing\ +([a-z]\ )?(/[!-~]+)$ ]]; then
            printf 'missing\t%s\n' "${root}${BASH_REMATCH[2]}"
        else
            printf 'error\t%s\n' "$(_ai_tools_layout__clamp_reason "${line}")"
        fi
    done
    exec {fd}<&-
    wait "${pid}" || status=$?
    return "${status}"
}

# _ai_tools_layout__read_content_states <package> : run the content collector for one package the pass has no result
# for, into _AI_TOOLS_LAYOUT__PACKAGE_VERIFY (verified, unverified, error), _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON
# and _AI_TOOLS_LAYOUT__CONTENT_FLAGS (the flags rpm printed per path). `unverified` where the pass skips rpm, where rpm
# is not installed, and where rpm reports the package not installed (a source install); `error` where the query failed
# in another way, where the collector printed a line it did not recognize, or where it exited 1 (differences found)
# without a difference line, or with any other status. Runs in the caller's shell, so the arrays it fills are the
# pass's.
_ai_tools_layout__read_content_states() {
    local package="$1" flags path fd pid status=0 query reason="" differences=0
    [[ -z "${_AI_TOOLS_LAYOUT__PACKAGE_VERIFY[${package}]+x}" ]] || return 0
    if (( _AI_TOOLS_LAYOUT__PASS_WITHOUT_RPM )); then
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=unverified
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON["${package}"]="the pass did not read rpm"
        return 0
    fi
    if ! command -v rpm >/dev/null 2>&1; then
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=unverified
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON["${package}"]="rpm is not installed"
        return 0
    fi
    if ! query="$(LC_ALL=C rpm -q -- "${package}" 2>&1)"; then
        if [[ "${query}" == *"is not installed"* ]]; then
            _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=unverified
            _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON["${package}"]="rpm does not report the package installed"
        else
            _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=error
            _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON["${package}"]="rpm -q ${package} failed: $(_ai_tools_layout__clamp_reason "${query}")"
        fi
        return 0
    fi
    exec {fd}< <(_ai_tools_layout__list_package_verify_results "${package}"); pid=$!
    while IFS=$'\t' read -r -u "${fd}" flags path; do
        if [[ "${flags}" == error ]]; then
            [[ -n "${reason}" ]] || reason="rpm -V ${package} printed a line the reader does not recognize: ${path}"
            continue
        fi
        [[ "${flags}" == missing || "${flags}" == *[^.]* ]] && differences=1
        _AI_TOOLS_LAYOUT__CONTENT_FLAGS["${path}"]="${flags}"
    done
    exec {fd}<&-
    wait "${pid}" || status=$?
    if [[ -z "${reason}" ]]; then
        case "${status}" in
            0) ;;
            1) (( differences )) || reason="rpm -V ${package} exited 1 without a difference line" ;;
            *) reason="rpm -V ${package} exited ${status}" ;;
        esac
    fi
    if [[ -n "${reason}" ]]; then
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=error
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON["${package}"]="${reason}"
    else
        _AI_TOOLS_LAYOUT__PACKAGE_VERIFY["${package}"]=verified
    fi
}

# _ai_tools_layout__evaluate_content <package> <path> : print the content state of one package file and its reason,
# TAB-separated, from what the collector recorded: `verified` for a line whose digest test passed; `drift` for a `5`;
# `unreadable` for a `?` at the digest position, for a path rpm reported missing (the entry there now is not the one rpm
# compared), and for a package whose collector failed; `unverified` for a package the pass did not verify and for a path
# the installed package does not print a line for.
_ai_tools_layout__evaluate_content() {
    local package="$1" flags
    case "${_AI_TOOLS_LAYOUT__PACKAGE_VERIFY[${package}]:-unverified}" in
        verified) ;;
        error) printf 'unreadable\t%s' "${_AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON[${package}]:-}"; return 0 ;;
        *) printf 'unverified\t%s' "${_AI_TOOLS_LAYOUT__PACKAGE_VERIFY_REASON[${package}]:-rpm did not compare the bytes}"
           return 0 ;;
    esac
    flags="${_AI_TOOLS_LAYOUT__CONTENT_FLAGS[$2]:-}"
    if [[ -z "${flags}" ]]; then printf 'unverified\tthe installed package does not list the path'
    elif [[ "${flags}" == missing ]]; then printf 'unreadable\trpm reported the file missing when it verified the package'
    elif [[ "${flags:2:1}" == 5 ]]; then printf 'drift\tthe digest differs from the package'"'"'s'
    elif [[ "${flags:2:1}" == '?' ]]; then printf 'unreadable\trpm could not compute the digest of the file'
    else printf 'verified\t'
    fi
}

# ── How each entry is read ───────────────────────────────────────────────────────────────────

# _ai_tools_layout__is_payload_file <subject-type> <flags> : 0 for a row whose bytes rpm owns -- a `file` row
# with `files` and neither `config` nor `ghost` -- so its content is read.
_ai_tools_layout__is_payload_file() {
    [[ "$1" == file && ",$2," == *,files,* && ",$2," != *,config,* && ",$2," != *,ghost,* ]]
}

# _ai_tools_layout__get_refusal_remedy <flags> <package> <operator> : the command that places a row the reconcile does
# not create -- a missing file or link, and a package file whose content drifted.
_ai_tools_layout__get_refusal_remedy() {
    if [[ -n "$3" ]]; then
        printf 'sudo ai-tools-admin operators add %s' "$3"
    elif [[ ",$1," == *,files,* || ",$1," == *,config,* ]]; then
        printf 'sudo dnf reinstall %s, or sudo ./install.sh install on a source install' "${2%%,*}"
    else
        printf 'sudo ai-tools-admin system bootstrap'
    fi
}

# _ai_tools_layout__get_expected_acl <mode> <acl> <out-var> : pure. The full ACL text a row's mode and named entries
# give, in getfacl's order, one entry per line: the base entries, the named access entries, the mask where a named
# access entry exists, then the default block where a named default entry exists. The mask is the mode's group bits,
# which the load-time rule holds every named entry within.
_ai_tools_layout__get_expected_acl() {
    local -n _layout_acl_out="$3"
    local _layout_acl_mode="$1" _layout_acl_spec="$2" _layout_acl_entry _layout_acl_owner_bits _layout_acl_group_bits
    local _layout_acl_other_bits
    local -a _layout_acl_access_users=() _layout_acl_access_groups=() _layout_acl_default_users=()
    local -a _layout_acl_default_groups=() _layout_acl_entries=() _layout_acl_text=()
    _ai_tools_layout__get_mode_bits "${_layout_acl_mode}" u _layout_acl_owner_bits
    _ai_tools_layout__get_mode_bits "${_layout_acl_mode}" g _layout_acl_group_bits
    _ai_tools_layout__get_mode_bits "${_layout_acl_mode}" o _layout_acl_other_bits
    if [[ "${_layout_acl_spec}" != - ]]; then
        IFS=, read -ra _layout_acl_entries <<< "${_layout_acl_spec}"
        for _layout_acl_entry in "${_layout_acl_entries[@]}"; do
            case "${_layout_acl_entry}" in
                default:user:*)  _layout_acl_default_users+=( "${_layout_acl_entry#default:}" ) ;;
                default:group:*) _layout_acl_default_groups+=( "${_layout_acl_entry#default:}" ) ;;
                user:*)          _layout_acl_access_users+=( "${_layout_acl_entry}" ) ;;
                group:*)         _layout_acl_access_groups+=( "${_layout_acl_entry}" ) ;;
            esac
        done
    fi
    _layout_acl_text+=( "user::${_layout_acl_owner_bits}" "${_layout_acl_access_users[@]}" \
        "group::${_layout_acl_group_bits}" "${_layout_acl_access_groups[@]}" )
    (( ${#_layout_acl_access_users[@]} + ${#_layout_acl_access_groups[@]} == 0 )) \
        || _layout_acl_text+=( "mask::${_layout_acl_group_bits}" )
    _layout_acl_text+=( "other::${_layout_acl_other_bits}" )
    if (( ${#_layout_acl_default_users[@]} + ${#_layout_acl_default_groups[@]} > 0 )); then
        _layout_acl_text+=( "default:user::${_layout_acl_owner_bits}" )
        for _layout_acl_entry in "${_layout_acl_default_users[@]}"; do
            _layout_acl_text+=( "default:${_layout_acl_entry}" )
        done
        _layout_acl_text+=( "default:group::${_layout_acl_group_bits}" )
        for _layout_acl_entry in "${_layout_acl_default_groups[@]}"; do
            _layout_acl_text+=( "default:${_layout_acl_entry}" )
        done
        _layout_acl_text+=( "default:mask::${_layout_acl_group_bits}" "default:other::${_layout_acl_other_bits}" )
    fi
    local IFS=$'\n'
    _layout_acl_out="${_layout_acl_text[*]}"
}

# _ai_tools_layout__append_entry_findings <expected-var> <observed-var> <findings-var> : pure. Compare the expected
# state of one entry with the observed one, both associative arrays, and append to the indexed findings array one
# encoded line per finding, five fields: <token> <field> <expected> <observed> <detail>. The fields are read in order --
# type, owner, mode, ACL, label, content -- and a field whose reading did not complete is an `unreadable` finding
# that ends the comparison, with every finding made before it kept.
#
#   expected: type owner mode acl label (a type, `n/a` on a host without SELinux, empty for a path with no
#             expectation) label_error (why the expectation could not be read) content_checked (1 for a package file
#             whose bytes rpm owns) absent_ok (1 for a ghost or optional row) flags package operator
#   observed: type (file, directory, link, absent, other, unreadable) link_target (dangling when a link's target does
#             not exist) owner mode acl label, each with <field>_error set where its reading did not complete,
#             content (verified, drift, unreadable, unverified) and content_reason
_ai_tools_layout__append_entry_findings() {
    local -n _layout_expected="$1" _layout_observed="$2" _layout_findings="$3"
    local _layout_field _layout_line _layout_remedy
    local -a _layout_fields=( owner )
    _layout_remedy="$(_ai_tools_layout__get_refusal_remedy "${_layout_expected[flags]:-}" \
        "${_layout_expected[package]:-}" "${_layout_expected[operator]:-}")"
    case "${_layout_observed[type]:-unreadable}" in
        absent)
            (( ${_layout_expected[absent_ok]:-0} )) && return 0
            if [[ "${_layout_expected[type]}" == directory ]]; then
                _ai_tools_layout__encode_line _layout_line missing type "${_layout_expected[type]}" absent \
                    "no entry at the path"
            else
                _ai_tools_layout__encode_line _layout_line missing type "${_layout_expected[type]}" absent \
                    "no entry at the path: ${_layout_remedy}"
            fi
            _layout_findings+=( "${_layout_line}" )
            return 0 ;;
        unreadable|other)
            _ai_tools_layout__encode_line _layout_line unreadable type "${_layout_expected[type]}" \
                "${_layout_observed[type]:-unreadable}" \
                "${_layout_observed[type_error]:-the type of the entry could not be read}"
            _layout_findings+=( "${_layout_line}" )
            return 0 ;;
    esac
    if [[ "${_layout_observed[type]}" != "${_layout_expected[type]}" ]]; then
        _ai_tools_layout__encode_line _layout_line type-mismatch type "${_layout_expected[type]}" \
            "${_layout_observed[type]}" \
            "a ${_layout_observed[type]} is where a ${_layout_expected[type]} belongs: move it aside"
        _layout_findings+=( "${_layout_line}" )
        return 0
    fi
    if [[ "${_layout_expected[type]}" == link && "${_layout_observed[link_target]:-}" == dangling ]]; then
        _ai_tools_layout__encode_line _layout_line missing type link dangling \
            "the link's target does not exist: ${_layout_remedy}"
        _layout_findings+=( "${_layout_line}" )
        return 0
    fi
    [[ "${_layout_expected[type]}" == link ]] || _layout_fields+=( mode acl label )
    for _layout_field in "${_layout_fields[@]}"; do
        if [[ "${_layout_field}" == label ]]; then
            if [[ -n "${_layout_expected[label_error]:-}" ]]; then
                _ai_tools_layout__encode_line _layout_line unreadable label - - "${_layout_expected[label_error]}"
                _layout_findings+=( "${_layout_line}" )
                return 0
            fi
            [[ -n "${_layout_expected[label]:-}" && "${_layout_expected[label]}" != n/a ]] || continue
        fi
        if [[ -n "${_layout_observed[${_layout_field}_error]:-}" ]]; then
            _ai_tools_layout__encode_line _layout_line unreadable "${_layout_field}" - - \
                "${_layout_observed[${_layout_field}_error]}"
            _layout_findings+=( "${_layout_line}" )
            return 0
        fi
        [[ "${_layout_observed[${_layout_field}]:-}" == "${_layout_expected[${_layout_field}]:-}" ]] && continue
        _ai_tools_layout__encode_line _layout_line "${_layout_field}-drift" "${_layout_field}" \
            "${_layout_expected[${_layout_field}]:-}" "${_layout_observed[${_layout_field}]:-}" \
            "the ${_layout_field} is not the one this row declares"
        _layout_findings+=( "${_layout_line}" )
    done
    if (( ${_layout_expected[content_checked]:-0} )); then
        case "${_layout_observed[content]:-unverified}" in
            drift)
                _ai_tools_layout__encode_line _layout_line content-drift content "${_layout_expected[package]:--}" \
                    differs "the file's bytes are not the package's: ${_layout_remedy}" ;;
            unreadable)
                _ai_tools_layout__encode_line _layout_line unreadable content - - \
                    "${_layout_observed[content_reason]:-the package digest could not be compared}" ;;
            *) return 0 ;;
        esac
        _layout_findings+=( "${_layout_line}" )
    fi
    return 0
}

# _ai_tools_layout__is_output_name_valid <name> map|list : 0 when <name> may receive a write from this library:
# an identifier outside this module's prefixes and LC_ALL, declared by the caller as an associative (map) or indexed
# (list) array.
_ai_tools_layout__is_output_name_valid() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    case "$1" in
        _layout_*|_AI_TOOLS_LAYOUT_*|AI_TOOLS_LAYOUT_*|LC_ALL) return 1 ;;
    esac
    case "$2" in
        map)  [[ "$(declare -p "$1" 2>/dev/null)" == "declare -A "* ]] ;;
        list) [[ "$(declare -p "$1" 2>/dev/null)" == "declare -a "* ]] ;;
        *)    return 1 ;;
    esac
}

# ai_tools_layout__read_entry_state <encoded-entry> <state-var> <findings-var> : read one entry into the caller's
# associative array -- path, operator, package, flags, the expected type, owner, mode, ACL and label, and the observed
# type, owner, mode, ACL, label and content, a field whose reading did not complete carrying `<field>_error` --
# and append its findings to the caller's indexed array. The state array is replaced; the findings array is appended to.
# Reads and does not write; the content collector runs for the entry's package when the pass does not hold a result
# for it. Returns 2 when the table did not validate, and 1 when an output name is refused, the two names are one,
# or the entry does not decode, without writing.
ai_tools_layout__read_entry_state() {
    [[ -z "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]] || return 2
    _ai_tools_layout__is_output_name_valid "$2" map && _ai_tools_layout__is_output_name_valid "$3" list \
        && [[ "$2" != "$3" ]] || return 1
    local -n _layout_state="$2" _layout_out_findings="$3"
    local -a _layout_fields=()
    ai_tools_layout__parse_line "$1" _layout_fields || return 1
    (( ${#_layout_fields[@]} == 8 )) || return 1
    local _layout_path="${_layout_fields[0]}" _layout_subject_type="${_layout_fields[1]}"
    local _layout_owner="${_layout_fields[2]}" _layout_mode="${_layout_fields[3]}" _layout_acl="${_layout_fields[4]}"
    local _layout_package="${_layout_fields[5]}" _layout_flags="${_layout_fields[6]}"
    local _layout_operator="${_layout_fields[7]}" _layout_observed_type _layout_status _layout_key _layout_content
    local -A _layout_expected_state=() _layout_observed_state=()
    _layout_state=()
    _layout_state["path"]="${_layout_path}"; _layout_state["operator"]="${_layout_operator}"
    _layout_state["package"]="${_layout_package}"; _layout_state["flags"]="${_layout_flags}"
    _layout_state["expected_type"]="${_layout_subject_type}"; _layout_state["expected_owner"]="${_layout_owner}"
    _layout_state["expected_mode"]="${_layout_mode}"
    _layout_expected_state["type"]="${_layout_subject_type}"; _layout_expected_state["owner"]="${_layout_owner}"
    _layout_expected_state["mode"]="${_layout_mode}"; _layout_expected_state["package"]="${_layout_package}"
    _layout_expected_state["flags"]="${_layout_flags}"; _layout_expected_state["operator"]="${_layout_operator}"
    _ai_tools_layout__get_expected_acl "${_layout_mode}" "${_layout_acl}" '_layout_expected_state[acl]'
    _layout_state["expected_acl"]="${_layout_expected_state[acl]}"
    [[ ",${_layout_flags}," == *,ghost,* || ",${_layout_flags}," == *,optional,* ]] \
        && _layout_expected_state["absent_ok"]=1
    _ai_tools_layout__is_payload_file "${_layout_subject_type}" "${_layout_flags}" \
        && _layout_expected_state["content_checked"]=1

    _layout_status=0
    _layout_observed_type="$(ai_tools_records_base__read_subject_type "${_layout_path}")" || _layout_status=$?
    case "${_layout_status}" in
        0) _layout_observed_state["type"]="${_layout_observed_type}" ;;
        2) _layout_observed_state["type"]=absent ;;
        *) _layout_observed_state["type"]=unreadable
           _layout_observed_state["type_error"]="the entry is not a file, directory or link, or its type could not be read" ;;
    esac
    if [[ "${_layout_observed_state[type]}" == "${_layout_subject_type}" ]]; then
        if [[ "${_layout_subject_type}" == link ]]; then
            [[ -e "${_layout_path}" ]] || _layout_observed_state["link_target"]=dangling
        fi
        _layout_observed_state["owner"]="$(LC_ALL=C stat -c '%U:%G' -- "${_layout_path}" 2>/dev/null)" \
            || _layout_observed_state["owner_error"]="stat could not read the owner"
        if [[ "${_layout_subject_type}" != link ]]; then
            if _layout_observed_state["mode"]="$(LC_ALL=C stat -c '%a' -- "${_layout_path}" 2>/dev/null)"; then
                printf -v '_layout_observed_state[mode]' '%04d' "${_layout_observed_state[mode]}"
            else
                _layout_observed_state["mode_error"]="stat could not read the mode"
            fi
            _ai_tools_layout__read_acl "${_layout_path}" _layout_observed_state
            _ai_tools_layout__read_labels "${_layout_path}" _layout_expected_state _layout_observed_state
            if (( ${_layout_expected_state[content_checked]:-0} )); then
                _ai_tools_layout__read_content_states "${_layout_package%%,*}"
                _layout_content="$(_ai_tools_layout__evaluate_content "${_layout_package%%,*}" "${_layout_path}")"
                _layout_observed_state["content"]="${_layout_content%%$'\t'*}"
                _layout_observed_state["content_reason"]="${_layout_content#*$'\t'}"
            fi
        fi
    fi
    for _layout_key in "${!_layout_observed_state[@]}"; do
        _layout_state["${_layout_key}"]="${_layout_observed_state[${_layout_key}]}"
    done
    _layout_state["expected_label"]="${_layout_expected_state[label]:-}"
    _layout_state["content"]="${_layout_observed_state[content]:-}"
    _ai_tools_layout__append_entry_findings _layout_expected_state _layout_observed_state _layout_out_findings
    return 0
}

# _ai_tools_layout__read_acl <path> <observed-var> : the full ACL text getfacl prints for the entry itself (`-P`),
# in one observation, into <observed-var>[acl]; `acl_error` where getfacl is missing, exited non-zero, or printed a line
# outside the ACL grammar (stderr is merged, so a warning is such a line).
_ai_tools_layout__read_acl() {
    local -n _layout_acl_observed="$2"
    local _layout_acl_line _layout_acl_fd _layout_acl_pid _layout_acl_status=0 _layout_acl_bad=""
    local -a _layout_acl_lines=()
    if ! command -v getfacl >/dev/null 2>&1; then
        _layout_acl_observed["acl_error"]="getfacl is not installed"; return 0
    fi
    exec {_layout_acl_fd}< <(LC_ALL=C getfacl --absolute-names --omit-header --no-effective -P -- "$1" 2>&1)
    _layout_acl_pid=$!
    while IFS= read -r -u "${_layout_acl_fd}" _layout_acl_line; do
        [[ -n "${_layout_acl_line}" ]] || continue
        if [[ "${_layout_acl_line}" =~ ^(default:)?(user|group|mask|other):[^:]*:[rwx-]{3}$ ]]; then
            _layout_acl_lines+=( "${_layout_acl_line}" )
        else
            [[ -n "${_layout_acl_bad}" ]] || _layout_acl_bad="${_layout_acl_line}"
        fi
    done
    exec {_layout_acl_fd}<&-
    wait "${_layout_acl_pid}" || _layout_acl_status=$?
    if [[ -n "${_layout_acl_bad}" ]]; then
        _layout_acl_observed["acl_error"]="getfacl wrote: $(_ai_tools_layout__clamp_reason "${_layout_acl_bad}")"
    elif (( _layout_acl_status != 0 )); then
        _layout_acl_observed["acl_error"]="getfacl exited ${_layout_acl_status}"
    else
        local IFS=$'\n'
        _layout_acl_observed["acl"]="${_layout_acl_lines[*]}"
    fi
}

# _ai_tools_layout__read_labels <path> <expected-var> <observed-var> : the type matchpathcon gives the path
# into <expected-var>[label] and the type the entry carries into <observed-var>[label]. `n/a` for both where SELinux
# does not apply; no expectation where matchpathcon prints <<none>>; `label_error` on either side where a tool is
# missing, a lookup fails or a context does not validate. The command owns the type alone, so user, role and range are
# not read.
_ai_tools_layout__read_labels() {
    local -n _layout_label_expected="$2" _layout_label_observed="$3"
    local _layout_label_context _layout_label_type
    [[ -n "${_AI_TOOLS_LAYOUT__SELINUX}" ]] || _ai_tools_layout__read_selinux_state
    if [[ "${_AI_TOOLS_LAYOUT__SELINUX}" == n/a ]]; then
        _layout_label_expected["label"]=n/a; _layout_label_observed["label"]=n/a; return 0
    fi
    if ! command -v matchpathcon >/dev/null 2>&1; then
        _layout_label_expected["label_error"]="matchpathcon is not installed"; return 0
    fi
    _layout_label_context="$(LC_ALL=C matchpathcon -n -- "$1" 2>/dev/null)" \
        || { _layout_label_expected["label_error"]="matchpathcon could not look the path up"; return 0; }
    if [[ "${_layout_label_context}" == '<<none>>' ]]; then
        _layout_label_expected["label"]=""
    elif ai_tools_project_permissions__get_context_type _layout_label_type "${_layout_label_context}"; then
        _layout_label_expected["label"]="${_layout_label_type}"
    else
        _layout_label_expected["label_error"]="matchpathcon printed a context that does not validate"; return 0
    fi
    _layout_label_context="$(LC_ALL=C stat -c '%C' -- "$1" 2>/dev/null)" \
        || { _layout_label_observed["label_error"]="stat could not read the context"; return 0; }
    if ai_tools_project_permissions__get_context_type _layout_label_type "${_layout_label_context}"; then
        _layout_label_observed["label"]="${_layout_label_type}"
    else
        _layout_label_observed["label_error"]="the entry's context does not validate"
    fi
}

# ── The record stream ────────────────────────────────────────────────────────────────────────
# One code per finding token. The words that read as a severity map each line to the message catalog.
_ai_tools_layout__attention()  { _AI_TOOLS_LAYOUT__CODE="$1"; _AI_TOOLS_LAYOUT__SEVERITY=attention; }
_ai_tools_layout__unreadable() { _AI_TOOLS_LAYOUT__CODE="$1"; _AI_TOOLS_LAYOUT__SEVERITY=unreadable; }
_ai_tools_layout__info()       { _AI_TOOLS_LAYOUT__CODE="$1"; _AI_TOOLS_LAYOUT__SEVERITY=ok; }
_AI_TOOLS_LAYOUT__CODE=""
_AI_TOOLS_LAYOUT__SEVERITY=""

# _ai_tools_layout__select_finding <token> : set _AI_TOOLS_LAYOUT__CODE and _AI_TOOLS_LAYOUT__SEVERITY for a finding
# token. Returns 1 for a token the table does not carry.
_ai_tools_layout__select_finding() {
    case "$1" in
        owner-drift)   _ai_tools_layout__attention MSG-K7Y7 "owner-drift" ;;
        mode-drift)    _ai_tools_layout__attention MSG-A7Z4 "mode-drift" ;;
        acl-drift)     _ai_tools_layout__attention MSG-P3W4 "acl-drift" ;;
        label-drift)   _ai_tools_layout__attention MSG-G2B3 "label-drift" ;;
        content-drift) _ai_tools_layout__attention MSG-A3J4 "content-drift" ;;
        missing)       _ai_tools_layout__attention MSG-C6Y6 "missing" ;;
        type-mismatch) _ai_tools_layout__attention MSG-Z5D2 "type-mismatch" ;;
        unreadable)    _ai_tools_layout__unreadable MSG-Q6A4 "unreadable" ;;
        error)         _ai_tools_layout__unreadable MSG-U7U5 "error" ;;
        ok)            _ai_tools_layout__info MSG-P7W4 "ok" ;;
        *) return 1 ;;
    esac
}

# _ai_tools_layout__write_row <token> <subject-type> <operator> <subject> <detail> <component>... : write one record
# through the shared writer, in the report's own shell. Returns the writer's status, so a failed write reaches the
# caller.
_ai_tools_layout__write_row() {
    local token="$1" subject_type="$2" operator="$3" subject="$4" detail="$5" item
    shift 5
    if ! _ai_tools_layout__select_finding "${token}"; then
        detail="a finding token outside the table, ${token}: ${detail}"
        token=error
        _ai_tools_layout__select_finding error
    fi
    if ! ai_tools_records_tsv__frame_item_components item "$@"; then
        detail="an empty item component for ${token}: ${detail}"
        token=error
        _ai_tools_layout__select_finding error
        ai_tools_records_tsv__frame_item_components item 'finding-table' - - || item='finding-table'
    fi
    ai_tools_records_tsv__write_record "" "${_AI_TOOLS_LAYOUT__CODE}" "${_AI_TOOLS_LAYOUT__SEVERITY}" "${token}" \
        "${subject_type}" "${operator}" "${item}" "${subject}" "${detail}"
}

# _ai_tools_layout__write_error_line <encoded-error-line> : one `error` line of the entry set as a record.
_ai_tools_layout__write_error_line() {
    local -a fields=()
    if ! ai_tools_layout__parse_line "$1" fields || (( ${#fields[@]} != 5 )); then
        _ai_tools_layout__write_row error host "" layout.lib.sh "a line of the entry set did not decode" entries - -
        return
    fi
    _ai_tools_layout__write_row error "${fields[1]}" "" "${fields[2]}" "${fields[4]}" "${fields[3]}" - -
}

# _ai_tools_layout__get_record_subject_type <observed> <expected> : the subject-type a row takes -- the type read
# at the path where it is one the records name, and the expected type otherwise.
_ai_tools_layout__get_record_subject_type() {
    case "$1" in
        file|directory|link) printf '%s' "$1" ;;
        *) printf '%s' "$2" ;;
    esac
}

# _ai_tools_layout__write_entry_records <state-var> <findings-var> <all> : write the records of one read entry -- one
# per finding, or an `ok` row under <all> when it has none. A finding about the entry's type that the reader refused is
# followed by an `error` row about the same subject, as records.rule.md states. Returns 1 at the first write the shared
# writer reports failed.
_ai_tools_layout__write_entry_records() {
    local -n _layout_write_state="$1" _layout_write_findings="$2"
    local _layout_write_all="$3" _layout_write_line _layout_write_subject_type _layout_write_detail
    local -a _layout_write_finding=()
    _layout_write_subject_type="$(_ai_tools_layout__get_record_subject_type "${_layout_write_state[type]:-}" \
        "${_layout_write_state[expected_type]}")"
    if (( ${#_layout_write_findings[@]} == 0 )); then
        (( _layout_write_all )) || return 0
        if [[ "${_layout_write_state[type]:-}" == absent ]]; then
            _layout_write_detail="absent; the row is optional"
        else
            _layout_write_detail="at its row"
            if _ai_tools_layout__is_payload_file "${_layout_write_state[expected_type]}" \
                    "${_layout_write_state[flags]}" && [[ "${_layout_write_state[content]:-}" == unverified ]]; then
                _layout_write_detail+="; content unverified: ${_layout_write_state[content_reason]:-}"
            fi
        fi
        _ai_tools_layout__write_row ok "${_layout_write_subject_type}" "${_layout_write_state[operator]}" \
            "${_layout_write_state[path]}" "${_layout_write_detail}" all - -
        return
    fi
    for _layout_write_line in "${_layout_write_findings[@]}"; do
        if ! ai_tools_layout__parse_line "${_layout_write_line}" _layout_write_finding \
                || (( ${#_layout_write_finding[@]} != 5 )); then
            _layout_write_finding=( error entry - - "a finding did not decode" )
        fi
        case "${_layout_write_finding[0]}" in
            missing)
                _ai_tools_layout__write_row missing "${_layout_write_subject_type}" \
                    "${_layout_write_state[operator]}" "${_layout_write_state[path]}" "${_layout_write_finding[4]}" \
                    type "${_layout_write_finding[2]}" "${_layout_write_finding[3]}" || return 1 ;;
            unreadable)
                _ai_tools_layout__write_row unreadable "${_layout_write_subject_type}" \
                    "${_layout_write_state[operator]}" "${_layout_write_state[path]}" "${_layout_write_finding[4]}" \
                    "${_layout_write_finding[1]}" - - || return 1
                if [[ "${_layout_write_finding[1]}" == type ]]; then
                    _ai_tools_layout__write_row error "${_layout_write_subject_type}" \
                        "${_layout_write_state[operator]}" "${_layout_write_state[path]}" \
                        "the reader refused the entry at this path" type - - || return 1
                fi ;;
            *)
                _ai_tools_layout__write_row "${_layout_write_finding[0]}" "${_layout_write_subject_type}" \
                    "${_layout_write_state[operator]}" "${_layout_write_state[path]}" "${_layout_write_finding[4]}" \
                    "${_layout_write_finding[1]}" "${_layout_write_finding[2]:--}" "${_layout_write_finding[3]:--}" \
                    || return 1 ;;
        esac
    done
    return 0
}

# ai_tools_layout__write_check_records <all> : the `system layout --check` stream, written in the caller's shell
# after its ai_tools_records_base__begin_report: an `error` row and no other where the table did not validate;
# otherwise, in one pass that reads rpm, every entry's findings and an `error` row for each input the entry set could
# not read. The caller reads the outcome off the report state. Returns 1 at the first write the shared writer reports
# failed.
ai_tools_layout__write_check_records() {
    # The two arrays are handed to the readers by name, so they carry a name the output-name check accepts.
    local all="$1" line
    local -a lines=() check_findings=()
    local -A check_state=()
    if [[ -n "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]]; then
        _ai_tools_layout__write_row error host "" layout.lib.sh "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" declarations - -
        return
    fi
    ai_tools_layout__begin_pass 0
    # The entry set's status is carried by its lines: it returns 1 when and only when it printed an `error` line.
    mapfile -t lines < <(ai_tools_layout__list_entries)
    for line in "${lines[@]}"; do
        if [[ "${line}" == error$'\t'* ]]; then
            _ai_tools_layout__write_error_line "${line}" || return 1
            continue
        fi
        check_state=(); check_findings=()
        if ! ai_tools_layout__read_entry_state "${line}" check_state check_findings; then
            _ai_tools_layout__write_row error host "" layout.lib.sh "an entry did not decode" entries - - || return 1
            continue
        fi
        _ai_tools_layout__write_entry_records check_state check_findings "${all}" || return 1
    done
    return 0
}

# ── The reconcile ────────────────────────────────────────────────────────────────────────────
# ai_tools_layout__reconcile brings each entry to its row and prints one tagged line per observation, each field encoded
# as the entry set's lines are:
#
#     changed <path> <field> <from> <to>      a field this pass brought to its row, read back after the write
#     refused <path> <field> <reason>         an entry left as it is: a state the reconcile does not repair
#     error   <path> <field> <reason>         an observation that did not complete, or a write that failed
#
# The order is the discovery-input rows first (the agents directory, each manifest under it, operator.conf, and their
# ancestors in the table), then one pass over the union of the static and the dynamic rows, sorted so a parent precedes
# every path under it. A row is acted on while every ancestor row of it is at its row after that ancestor's own step;
# otherwise it is refused naming the ancestor and is not read through it. An ancestor outside the table is the host's.
#
# A file or directory row is repaired through a descriptor pinned to the inode the read observed, the sequence
# ai-tools-chown's apply block takes (safe-paths.rule.md): the identity read through the path, the open, the identity,
# type and link count read from the descriptor, ai_tools_safe_paths__is_pinned_fd_at_path, then each write
# through /proc/self/fd. The parents .claude, .codex, .local and .local/share are sandbox-group-writable and sticky,
# so a sandbox-owned entry under one can be renamed aside and a symlink planted between the read and the write,
# which a plain chmod would follow.
#
# The lock serializes two reconciles: two passes interleaving their `setfacl --set` calls is the one way this library
# could leave an entry at neither state, so a lock it cannot take is an `error` line and no write, where the relabel
# lock proceeds. AI_TOOLS_LAYOUT_LOCK and AI_TOOLS_LAYOUT_LOCK_WAIT are root-only test hooks (tests.rule.md).
: "${AI_TOOLS_LAYOUT_LOCK:=/run/lock/ai-tools-layout.lock}"
: "${AI_TOOLS_LAYOUT_LOCK_WAIT:=60}"
readonly _AI_TOOLS_LAYOUT__LIBRARY_DIR="${BASH_SOURCE[0]%/*}"
readonly _AI_TOOLS_LAYOUT__FULL_PASS_REMEDY="sudo ai-tools-admin system layout reconcile, or sudo ./install.sh install on a source install"

# What one reconcile accumulates: the outcome counts its exit status folds, the paths of the rows in the set,
# and the state each row reached after its own step, which the rows under it read.
_AI_TOOLS_LAYOUT__RECONCILE_WRITE_FAILED=0
_AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE=0
_AI_TOOLS_LAYOUT__RECONCILE_REFUSED=0
declare -gA _AI_TOOLS_LAYOUT__ROW_PATHS=()
declare -gA _AI_TOOLS_LAYOUT__ANCESTOR_STATES=()

# _ai_tools_layout__reset_reconcile_state : the counters and the maps of one reconcile, cleared.
_ai_tools_layout__reset_reconcile_state() {
    _AI_TOOLS_LAYOUT__RECONCILE_WRITE_FAILED=0
    _AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE=0
    _AI_TOOLS_LAYOUT__RECONCILE_REFUSED=0
    _AI_TOOLS_LAYOUT__ROW_PATHS=()
    _AI_TOOLS_LAYOUT__ANCESTOR_STATES=()
}

# _ai_tools_layout__log <level> <message> : one line to journald under the layout tag and to layout.log.
_ai_tools_layout__log() { AI_TOOLS_LOG_TAG=ai-tools-layout AI_TOOLS_LOG_FILE=layout.log ai_tools_log__write "$@"; }

# _ai_tools_layout__is_under <path> <ancestor> : 0 when <ancestor>/ is a prefix of <path> by path component,
# so a refusal of /a/b does not reach /a/bc.
_ai_tools_layout__is_under() { [[ "$1" == "$2"/* ]]; }

# _ai_tools_layout__evaluate_change_log_level <field> <from> <to> : pure. The level a `changed` line logs at: `notice`
# for a widening -- an owner or group moving to an account other than root, a mode bit set that was clear or a setgid
# or sticky bit cleared, an ACL entry added or one gaining a bit, and any label change, since what a type grants is
# the policy's -- and `info` otherwise. A value outside its grammar reads as a widening.
_ai_tools_layout__evaluate_change_log_level() {
    local field="$1" from="$2" to="$3" line tag perm
    local -A from_entries=()
    case "${field}" in
        owner)
            if [[ "${to%%:*}" != root && "${to%%:*}" != "${from%%:*}" ]] \
                    || [[ "${to#*:}" != root && "${to#*:}" != "${from#*:}" ]]; then
                printf notice
            else
                printf info
            fi ;;
        mode)
            if [[ ! "${from}" =~ ^[0-7]{4}$ || ! "${to}" =~ ^[0-7]{4}$ ]] \
                    || (( (8#${to} & ~8#${from} & 8#7777) != 0 || (8#${from} & ~8#${to} & 8#3000) != 0 )); then
                printf notice
            else
                printf info
            fi ;;
        acl)
            while IFS= read -r line; do
                [[ -n "${line}" ]] || continue
                from_entries["${line%:*}"]="${line##*:}"
            done <<< "${from}"
            while IFS= read -r line; do
                [[ -n "${line}" ]] || continue
                tag="${line%:*}" perm="${line##*:}"
                if [[ -z "${from_entries[${tag}]+x}" ]] \
                        || ! _ai_tools_layout__is_permission_within "${perm}" "${from_entries[${tag}]}"; then
                    printf notice; return 0
                fi
            done <<< "${to}"
            printf info ;;
        *) printf notice ;;
    esac
}

# _ai_tools_layout__report_change <path> <field> <from> <to> : one `changed` line, logged at the level the change earns,
# the ACL text's line feeds as commas in the log.
_ai_tools_layout__report_change() {
    local line level
    _ai_tools_layout__encode_line line changed "$1" "$2" "$3" "$4"
    printf '%s\n' "${line}"
    level="$(_ai_tools_layout__evaluate_change_log_level "$2" "$3" "$4")"
    _ai_tools_layout__log "${level}" "$1 $2 ${3//$'\n'/,} -> ${4//$'\n'/,}"
}

# _ai_tools_layout__report_refusal <path> <field> <reason> : one `refused` line, counted and logged at warning.
_ai_tools_layout__report_refusal() {
    local line
    _AI_TOOLS_LAYOUT__RECONCILE_REFUSED=$(( _AI_TOOLS_LAYOUT__RECONCILE_REFUSED + 1 ))
    _ai_tools_layout__encode_line line refused "$1" "$2" "$3"
    printf '%s\n' "${line}"
    _ai_tools_layout__log warning "refused $1 $2: $3"
}

# _ai_tools_layout__report_error <path> <field> <reason> : one `error` line, counted and logged at warning.
_ai_tools_layout__report_error() {
    local line
    _AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE=$(( _AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE + 1 ))
    _ai_tools_layout__encode_line line error "$1" "$2" "$3"
    printf '%s\n' "${line}"
    _ai_tools_layout__log warning "error $1 $2: $3"
}

# _ai_tools_layout__report_write_failure <path> <field> <tool> <status> : a write that returned non-zero, the error line
# and the exit the outcome table folds it to.
_ai_tools_layout__report_write_failure() {
    _AI_TOOLS_LAYOUT__RECONCILE_WRITE_FAILED=1
    _ai_tools_layout__report_error "$1" "$2" "$3 exited $4"
}

# _ai_tools_layout__lock <reason-var> : hold AI_TOOLS_LAYOUT_LOCK in the calling shell until _ai_tools_layout__unlock
# or the end of the process. Returns 0 while it is held, and 1 with the reason in <reason-var> where flock is absent,
# the lock file cannot be created, or the wait ran out. The file is created by a simple command and stderr is redirected
# before the create, for the two bash properties the relabel lock states.
_ai_tools_layout__lock() {
    local -n _layout_lock_reason="$1"
    _layout_lock_reason=""
    [[ -z "${_AI_TOOLS_LAYOUT__LOCK_FD:-}" ]] || return 0
    if ! command -v flock >/dev/null 2>&1; then _layout_lock_reason="flock is not installed"; return 1; fi
    if ! : 2>/dev/null >"${AI_TOOLS_LAYOUT_LOCK}"; then
        _layout_lock_reason="cannot write ${AI_TOOLS_LAYOUT_LOCK}"; return 1
    fi
    exec {_AI_TOOLS_LAYOUT__LOCK_FD}>"${AI_TOOLS_LAYOUT_LOCK}"
    if ! flock -w "${AI_TOOLS_LAYOUT_LOCK_WAIT}" "${_AI_TOOLS_LAYOUT__LOCK_FD}"; then
        _ai_tools_layout__unlock
        _layout_lock_reason="another reconcile held ${AI_TOOLS_LAYOUT_LOCK} for more than ${AI_TOOLS_LAYOUT_LOCK_WAIT}s"
        return 1
    fi
    return 0
}

# _ai_tools_layout__unlock : release the lock by closing its descriptor; a no-op while it is not held.
_ai_tools_layout__unlock() {
    [[ -n "${_AI_TOOLS_LAYOUT__LOCK_FD:-}" ]] || return 0
    exec {_AI_TOOLS_LAYOUT__LOCK_FD}>&-
    unset _AI_TOOLS_LAYOUT__LOCK_FD
    return 0
}

# _ai_tools_layout__is_discovery_input <path> : 0 for a row the dynamic enumeration reads before it can list a dynamic
# row -- the agents directory, a manifest under it, operator.conf -- or an ancestor of one of them.
_ai_tools_layout__is_discovery_input() {
    local path="$1" input
    for input in "${AI_TOOLS_AGENTS_DIR}" "${AI_TOOLS_OPERATOR_CONF}"; do
        [[ "${path}" == "${input}" ]] && return 0
        _ai_tools_layout__is_under "${input}" "${path}" && return 0
    done
    [[ "${path}" == "${AI_TOOLS_AGENTS_DIR}"/*.conf && "${path#"${AI_TOOLS_AGENTS_DIR}"/}" != */* ]]
}

# _ai_tools_layout__record_ancestor_state <state-var> : record whether the entry is at its row after its step --
# the observed type, owner and mode are the declared ones, or the entry is absent and the row allows that --
# for the rows under it to read.
_ai_tools_layout__record_ancestor_state() {
    local -n _layout_record_state="$1"
    local _layout_record_verdict=bad
    if [[ "${_layout_record_state[type]:-}" == "${_layout_record_state[expected_type]}" \
            && "${_layout_record_state[owner]:-}" == "${_layout_record_state[expected_owner]}" ]] \
            && { [[ "${_layout_record_state[expected_type]}" == link ]] \
                 || [[ "${_layout_record_state[mode]:-}" == "${_layout_record_state[expected_mode]}" ]]; }; then
        _layout_record_verdict=ok
    elif [[ "${_layout_record_state[type]:-}" == absent ]] \
            && [[ ",${_layout_record_state[flags]}," == *,ghost,* || ",${_layout_record_state[flags]}," == *,optional,* ]]; then
        _layout_record_verdict=ok
    fi
    _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${_layout_record_state[path]}"]="${_layout_record_verdict}"
}

# _ai_tools_layout__find_refusing_ancestor <path> : print the nearest ancestor row of <path> that is not at its row,
# or one the pass has not reached, and return 0; return 1 when every ancestor row is at its row.
_ai_tools_layout__find_refusing_ancestor() {
    local ancestor="$1"
    while [[ "${ancestor}" == */* ]]; do
        ancestor="${ancestor%/*}"
        [[ -n "${ancestor}" ]] || break
        [[ -n "${_AI_TOOLS_LAYOUT__ROW_PATHS[${ancestor}]+x}" ]] || continue
        if [[ "${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[${ancestor}]:-bad}" != ok ]]; then
            printf '%s' "${ancestor}"; return 0
        fi
    done
    return 1
}

# _ai_tools_layout__create_directory <state-var> : create a missing directory row with install -d at its owner and mode,
# then the exact mode, and only under a parent that exists as a directory (lstat): a missing parent is a refusal naming
# it, so install -d is never asked to create an intermediate component. Returns 0 when the directory was created, 1
# after a refusal or a failed write.
_ai_tools_layout__create_directory() {
    local -n _layout_create_state="$1"
    local _layout_create_path="${_layout_create_state[path]}" _layout_create_parent _layout_create_status=0
    _layout_create_parent="${_layout_create_path%/*}"
    [[ -n "${_layout_create_parent}" ]] || _layout_create_parent=/
    if [[ -L "${_layout_create_parent}" || ! -d "${_layout_create_parent}" ]]; then
        _ai_tools_layout__report_refusal "${_layout_create_path}" type \
            "the directory is not created: its parent ${_layout_create_parent} is not a directory"
        return 1
    fi
    install -d -o "${_layout_create_state[expected_owner]%%:*}" -g "${_layout_create_state[expected_owner]#*:}" \
        -m "${_layout_create_state[expected_mode]}" -- "${_layout_create_path}" 2>/dev/null \
        || _layout_create_status=$?
    if (( _layout_create_status != 0 )); then
        _ai_tools_layout__report_write_failure "${_layout_create_path}" type "install -d" "${_layout_create_status}"
        return 1
    fi
    ai_tools_control_plane__apply_mode "${_layout_create_state[expected_mode]}" "${_layout_create_path}" 2>/dev/null \
        || _layout_create_status=$?
    if (( _layout_create_status != 0 )); then
        _ai_tools_layout__report_write_failure "${_layout_create_path}" mode chmod "${_layout_create_status}"
        return 1
    fi
    return 0
}

# _ai_tools_layout__apply_pinned <state-var> <field>... : the writes for one file or directory row -- from owner, acl,
# mode and label, in that order -- through a descriptor pinned to the inode the read observed. The parent is resolved
# once (an ancestor outside the table is the host's and may be a symlink; one inside it is a directory at its row
# before this runs) and the leaf is not, since a symlink planted there is what the pin exists to catch: the identity is
# read through the path, the entry opened, and the descriptor must report the same identity, the row's type and link
# count 1 for a file, with the kernel's own name for it equal to the path. A mismatch is an `error` with no write.
# `setfacl` runs without `-P` on the magic link, which is what it follows; restorecon takes the path, after the checks
# held, since it derives the context from the path. Returns 0 when every write returned 0 and 1 after an error line.
_ai_tools_layout__apply_pinned() {
    local -n _layout_apply_state="$1"
    local _layout_apply_path="${_layout_apply_state[path]}" _layout_apply_parent _layout_apply_leaf _layout_apply_pinned
    local _layout_apply_identity _layout_apply_fd _layout_apply_got_identity _layout_apply_nlink _layout_apply_ftype
    local _layout_apply_type _layout_apply_field _layout_apply_status
    shift
    _layout_apply_parent="${_layout_apply_path%/*}" _layout_apply_leaf="${_layout_apply_path##*/}"
    [[ -n "${_layout_apply_parent}" ]] || _layout_apply_parent=/
    if ! _layout_apply_parent="$(realpath -e -- "${_layout_apply_parent}" 2>/dev/null)"; then
        _ai_tools_layout__report_error "${_layout_apply_path}" identity "the parent directory could not be resolved"
        return 1
    fi
    _layout_apply_pinned="${_layout_apply_parent%/}/${_layout_apply_leaf}"
    if ! _layout_apply_identity="$(LC_ALL=C stat -c '%d:%i' -- "${_layout_apply_pinned}" 2>/dev/null)"; then
        _ai_tools_layout__report_error "${_layout_apply_path}" identity "the entry could not be read before the repair"
        return 1
    fi
    if ! { exec {_layout_apply_fd}< "${_layout_apply_pinned}"; } 2>/dev/null; then
        _ai_tools_layout__report_error "${_layout_apply_path}" identity "the entry could not be opened"
        return 1
    fi
    if ! read -r _layout_apply_got_identity _layout_apply_nlink _layout_apply_ftype \
            < <(LC_ALL=C stat -L -c '%d:%i %h %F' "/proc/self/fd/${_layout_apply_fd}" 2>/dev/null); then
        exec {_layout_apply_fd}<&-
        _ai_tools_layout__report_error "${_layout_apply_path}" identity "the pinned entry could not be read"
        return 1
    fi
    case "${_layout_apply_ftype}" in
        "regular file"|"regular empty file") _layout_apply_type="file" ;;
        directory)                           _layout_apply_type=directory ;;
        *)                                   _layout_apply_type=other ;;
    esac
    if [[ "${_layout_apply_got_identity}" != "${_layout_apply_identity}" \
            || "${_layout_apply_type}" != "${_layout_apply_state[expected_type]}" ]] \
            || { [[ "${_layout_apply_type}" == file ]] && (( _layout_apply_nlink != 1 )); } \
            || ! ai_tools_safe_paths__is_pinned_fd_at_path "${_layout_apply_fd}" "${_layout_apply_pinned}"; then
        exec {_layout_apply_fd}<&-
        _ai_tools_layout__report_error "${_layout_apply_path}" identity "the entry changed during the repair"
        return 1
    fi
    for _layout_apply_field in owner acl mode label; do
        [[ " $* " == *" ${_layout_apply_field} "* ]] || continue
        _layout_apply_status=0
        case "${_layout_apply_field}" in
            owner)
                chown -- "${_layout_apply_state[expected_owner]}" "/proc/self/fd/${_layout_apply_fd}" 2>/dev/null \
                    || _layout_apply_status=$?
                (( _layout_apply_status == 0 )) || { _ai_tools_layout__report_write_failure "${_layout_apply_path}" \
                    owner chown "${_layout_apply_status}"; break; } ;;
            acl)
                # Where the row does not declare a default block and the entry carries one, `setfacl -k` removes it
                # first; `--set-file` then replaces the access ACL whole, base entries included, so a masked-off foreign
                # entry goes in the same operation that sets the mode bits and no intermediate state activates it.
                if [[ "${_layout_apply_state[expected_acl]}" != *default:* \
                        && "${_layout_apply_state[acl]:-}" == *default:* ]]; then
                    setfacl -k "/proc/self/fd/${_layout_apply_fd}" 2>/dev/null || _layout_apply_status=$?
                    (( _layout_apply_status == 0 )) || { _ai_tools_layout__report_write_failure \
                        "${_layout_apply_path}" acl "setfacl -k" "${_layout_apply_status}"; break; }
                fi
                printf '%s\n' "${_layout_apply_state[expected_acl]}" \
                    | setfacl --set-file=- "/proc/self/fd/${_layout_apply_fd}" 2>/dev/null || _layout_apply_status=$?
                (( _layout_apply_status == 0 )) || { _ai_tools_layout__report_write_failure "${_layout_apply_path}" \
                    acl "setfacl --set-file" "${_layout_apply_status}"; break; } ;;
            mode)
                ai_tools_control_plane__apply_mode "${_layout_apply_state[expected_mode]}" \
                    "/proc/self/fd/${_layout_apply_fd}" 2>/dev/null || _layout_apply_status=$?
                (( _layout_apply_status == 0 )) || { _ai_tools_layout__report_write_failure "${_layout_apply_path}" \
                    mode chmod "${_layout_apply_status}"; break; } ;;
            label)
                restorecon -- "${_layout_apply_pinned}" 2>/dev/null || _layout_apply_status=$?
                (( _layout_apply_status == 0 )) || { _ai_tools_layout__report_write_failure "${_layout_apply_path}" \
                    label restorecon "${_layout_apply_status}"; break; } ;;
        esac
    done
    exec {_layout_apply_fd}<&-
    (( _layout_apply_status == 0 ))
}

# _ai_tools_layout__reconcile_entry <encoded-entry> : one row, through the ancestor rule, the preconditions
# and the repair, with the lines it earns printed and its state recorded for the rows under it. A row under an ancestor
# that is not at its row is refused unread. A finding the reader could not complete is an `error` and no write.
# A missing directory is created under an existing parent; a missing file or link, an entry of another type,
# and a package file whose content differs are refused with the remedy the finding carries. A drifted package file
# whose content is unverified is left as it is, each drifted field named. Otherwise the drifted fields are written --
# a link's owner by name, the rest through the pinned descriptor -- and the entry read again: `changed` per field
# from the two reads, and `error` for a field that still reports its finding.
_ai_tools_layout__reconcile_entry() {
    # The arrays are handed to the reader by name, so they carry a name the output-name check accepts.
    local entry="$1" ancestor path field token detail line content_reason refusal_detail="" link_status
    local -A first=() current=() final=()
    local -a first_findings=() current_findings=() final_findings=() finding=() drifted=() apply_fields=()
    local is_missing=0 is_mismatch=0 content_drift=0 unreadable=0 created=0
    ai_tools_layout__parse_line "${entry}" finding || finding=()
    path="${finding[0]:-}"
    if [[ -n "${path}" ]] && ancestor="$(_ai_tools_layout__find_refusing_ancestor "${path}")"; then
        _ai_tools_layout__report_refusal "${path}" ancestor "not read: ${ancestor} is not at its row"
        _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${path}"]=bad
        return 0
    fi
    if ! ai_tools_layout__read_entry_state "${entry}" first first_findings; then
        _ai_tools_layout__report_error "${path:-layout.lib.sh}" entry "the entry did not decode"
        [[ -z "${path}" ]] || _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${path}"]=bad
        return 0
    fi
    path="${first[path]}"
    for line in "${first_findings[@]}"; do
        ai_tools_layout__parse_line "${line}" finding || continue
        token="${finding[0]}" field="${finding[1]:-}" detail="${finding[4]:-}"
        case "${token}" in
            unreadable)    unreadable=1; _ai_tools_layout__report_error "${path}" "${field}" "${detail}" ;;
            missing)       is_missing=1; refusal_detail="${detail}" ;;
            type-mismatch) is_mismatch=1; refusal_detail="${detail}" ;;
            content-drift) content_drift=1; refusal_detail="${detail}" ;;
            *-drift)       drifted+=( "${field}" ) ;;
        esac
    done
    if (( unreadable )); then
        _ai_tools_layout__record_ancestor_state first; return 0
    fi
    if (( ${#first_findings[@]} == 0 )); then
        _ai_tools_layout__record_ancestor_state first; return 0
    fi
    if (( is_mismatch )); then
        _ai_tools_layout__report_refusal "${path}" type "${refusal_detail}"
        _ai_tools_layout__record_ancestor_state first; return 0
    fi
    if (( content_drift )); then
        _ai_tools_layout__report_refusal "${path}" content "${refusal_detail}"
        _ai_tools_layout__record_ancestor_state first; return 0
    fi
    current=(); for field in "${!first[@]}"; do current["${field}"]="${first[${field}]}"; done
    if (( is_missing )); then
        if [[ "${first[expected_type]}" != directory || -n "${first[link_target]:-}" ]]; then
            _ai_tools_layout__report_refusal "${path}" type "${refusal_detail}"
            _ai_tools_layout__record_ancestor_state first; return 0
        fi
        if ! _ai_tools_layout__create_directory first; then
            _ai_tools_layout__record_ancestor_state first; return 0
        fi
        created=1
        current=(); current_findings=()
        if ! ai_tools_layout__read_entry_state "${entry}" current current_findings; then
            _ai_tools_layout__report_error "${path}" entry "the created directory could not be read back"
            _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${path}"]=bad; return 0
        fi
        drifted=()
        for line in "${current_findings[@]}"; do
            ai_tools_layout__parse_line "${line}" finding || continue
            case "${finding[0]}" in
                unreadable) _ai_tools_layout__report_error "${path}" "${finding[1]:-}" "${finding[4]:-}"
                            _ai_tools_layout__record_ancestor_state current; return 0 ;;
                *-drift)    drifted+=( "${finding[1]}" ) ;;
            esac
        done
    fi
    if (( ${#drifted[@]} > 0 )); then
        # A package file is repaired only on verified content; one the pass could not verify is reported and left whole,
        # since a mode fixed on unverified bytes would re-bless them.
        if _ai_tools_layout__is_payload_file "${current[expected_type]}" "${current[flags]}" \
                && [[ "${current[content]:-}" != verified ]]; then
            content_reason="${current[content_reason]:-the content was not verified}"
            for field in "${drifted[@]}"; do
                _ai_tools_layout__report_refusal "${path}" "${field}" \
                    "left as it is: the content is ${current[content]:-unverified} (${content_reason}); run ${_AI_TOOLS_LAYOUT__FULL_PASS_REMEDY}"
            done
            _ai_tools_layout__record_ancestor_state current; return 0
        fi
        if [[ "${current[expected_type]}" == link ]]; then
            link_status=0
            chown --no-dereference -- "${current[expected_owner]}" "${path}" 2>/dev/null || link_status=$?
            (( link_status == 0 )) \
                || _ai_tools_layout__report_write_failure "${path}" owner "chown --no-dereference" "${link_status}"
        else
            apply_fields=()
            for field in owner acl mode label; do
                [[ " ${drifted[*]} " == *" ${field} "* ]] && apply_fields+=( "${field}" )
                # The mode is re-asserted after an ACL write, for the special bits and the base bits setfacl set.
                [[ "${field}" == mode && " ${drifted[*]} " == *" acl "* && " ${apply_fields[*]} " != *" mode "* ]] \
                    && apply_fields+=( mode )
            done
            _ai_tools_layout__apply_pinned current "${apply_fields[@]}" || true
        fi
    fi
    final=(); final_findings=()
    if ! ai_tools_layout__read_entry_state "${entry}" final final_findings; then
        _ai_tools_layout__report_error "${path}" entry "the entry could not be read back after the repair"
        _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${path}"]=bad; return 0
    fi
    (( created )) && _ai_tools_layout__report_change "${path}" type absent "${final[type]:-}"
    for field in owner mode acl label; do
        [[ -n "${first[${field}]:-}" ]] || continue
        [[ "${first[${field}]}" != "${final[${field}]:-}" ]] || continue
        _ai_tools_layout__report_change "${path}" "${field}" "${first[${field}]}" "${final[${field}]:-}"
    done
    for line in "${final_findings[@]}"; do
        ai_tools_layout__parse_line "${line}" finding || continue
        case "${finding[0]}" in
            *-drift) [[ " ${drifted[*]} " == *" ${finding[1]} "* ]] \
                         && _ai_tools_layout__report_error "${path}" "${finding[1]}" "the change did not take" ;;
            unreadable) _ai_tools_layout__report_error "${path}" "${finding[1]:-}" "${finding[4]:-}" ;;
        esac
    done
    _ai_tools_layout__record_ancestor_state final
    return 0
}

# _ai_tools_layout__reconcile_lines <lines-var> : run _ai_tools_layout__reconcile_entry over the entry lines
# of the caller's array in path order, an `error` line of the set reported as it is, and mark each path handled
# in _AI_TOOLS_LAYOUT__ROW_PATHS so a later phase does not act on it again.
_ai_tools_layout__reconcile_lines() {
    local -n _layout_run_lines="$1"
    local _layout_run_line _layout_run_path
    local -a _layout_run_fields=()
    for _layout_run_line in "${_layout_run_lines[@]}"; do
        if [[ "${_layout_run_line}" == error$'\t'* ]]; then
            ai_tools_layout__parse_line "${_layout_run_line}" _layout_run_fields \
                || _layout_run_fields=( error host layout.lib.sh entries "a line of the entry set did not decode" )
            _ai_tools_layout__report_error "${_layout_run_fields[2]:-layout.lib.sh}" "${_layout_run_fields[3]:-entries}" \
                "${_layout_run_fields[4]:-}"
            continue
        fi
        _layout_run_path="${_layout_run_line%%$'\t'*}"
        [[ "${_AI_TOOLS_LAYOUT__ROW_PATHS[${_layout_run_path}]:-}" != handled ]] || continue
        _ai_tools_layout__reconcile_entry "${_layout_run_line}"
        _AI_TOOLS_LAYOUT__ROW_PATHS["${_layout_run_path}"]=handled
    done
}

# ai_tools_layout__reconcile <without-rpm> : bring every entry that applies on this host to its row, printing the tagged
# lines the section header states. Returns 2 without output for a caller that is not root and while the table did not
# validate; 5 after an `error` line for the lock, the safe-paths library or the enumeration, and otherwise the outcome
# ai-tools-records(5) folds -- 1 where a write failed or a repaired field did not take, 5 where an observation was
# incomplete, 4 where a refusal remains, 0 otherwise. The unattended callers ignore the status.
ai_tools_layout__reconcile() {
    [[ -z "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]] || return 2
    [[ "${EUID}" -eq 0 ]] || return 2
    local without_rpm="${1:-0}" reason="" line path sorted
    local -a static_lines=() phase_lines=() union_lines=()
    _ai_tools_layout__reset_reconcile_state
    if ! declare -F ai_tools_safe_paths__is_pinned_fd_at_path >/dev/null 2>&1; then
        # shellcheck source=SCRIPTDIR/safe-paths.lib.sh
        source "${_AI_TOOLS_LAYOUT__LIBRARY_DIR}/safe-paths.lib.sh" 2>/dev/null || true
    fi
    if ! declare -F ai_tools_safe_paths__is_pinned_fd_at_path >/dev/null 2>&1; then
        _ai_tools_layout__report_error "${_AI_TOOLS_LAYOUT__LIBRARY_DIR}/safe-paths.lib.sh" load \
            "the library did not load or does not define the pinned-descriptor predicate; reinstall ai-tools-base"
        return "${AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE}"
    fi
    if ! _ai_tools_layout__lock reason; then
        _ai_tools_layout__report_error "${AI_TOOLS_LAYOUT_LOCK}" lock "${reason}"
        return "${AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE}"
    fi
    ai_tools_layout__begin_pass "${without_rpm}"
    # The discovery-input rows first, parent-first, so the dynamic enumeration reads inputs at their rows.
    _ai_tools_layout__append_static_entries static_lines
    for line in "${static_lines[@]}"; do
        path="${line%%$'\t'*}"
        _AI_TOOLS_LAYOUT__ROW_PATHS["${path}"]=row
        _ai_tools_layout__is_discovery_input "${path}" && phase_lines+=( "${line}" )
    done
    if (( ${#phase_lines[@]} > 0 )); then
        if sorted="$(printf '%s\n' "${phase_lines[@]}" | LC_ALL=C sort -t $'\t' -k1,1)"; then
            mapfile -t phase_lines <<< "${sorted}"
            _ai_tools_layout__reconcile_lines phase_lines
        else
            _ai_tools_layout__report_error layout.lib.sh entries "sort did not complete"
        fi
    fi
    # Then one pass over the union, the rows the first phase handled taking no step.
    mapfile -t union_lines < <(ai_tools_layout__list_entries)
    for line in "${union_lines[@]}"; do
        [[ "${line}" == error$'\t'* ]] && continue
        path="${line%%$'\t'*}"
        [[ -n "${_AI_TOOLS_LAYOUT__ROW_PATHS[${path}]+x}" ]] || _AI_TOOLS_LAYOUT__ROW_PATHS["${path}"]=row
    done
    _ai_tools_layout__reconcile_lines union_lines
    _ai_tools_layout__unlock
    (( _AI_TOOLS_LAYOUT__RECONCILE_WRITE_FAILED == 0 )) || return 1
    (( _AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE == 0 )) || return "${AI_TOOLS_RECORDS_BASE__EXIT_UNREADABLE}"
    (( _AI_TOOLS_LAYOUT__RECONCILE_REFUSED == 0 )) || return "${AI_TOOLS_RECORDS_BASE__EXIT_FINDINGS}"
    return 0
}
