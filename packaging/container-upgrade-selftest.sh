#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/bin/ai-tools-upgrade-selftest  (test image only) The upgrade transaction of a release that withdraws base's
# shipped skills in favour of the asset set core, from the published FROM_VERSION to this tree's build, run once on boot
# by ai-tools-upgrade-selftest.service under a live systemd. packaging/Upgrade.Containerfile installs the published
# release and writes /etc/ai-tools-upgrade-selftest.conf, which names the scenario:
#
#   key-first      ai-tools-assets-core installed and AI_TOOLS_ASSETS written in operator.conf before the upgrade:
#                  the upgrade's %post moves base's copies aside and links every core asset in the same transaction,
#                  and the Assets section does not report a notice. At a name core reuses, the view holds core's link
#                  and an agent's existing link to it is kept. A 0.23 host has no `assets` verb, so the key is
#                  written by hand, which that release ignores.
#   without-core   the set absent at the upgrade: base's copies leave the view and the agents' directories, no core
#                  link exists, and the Assets section carries one successor-unenabled line; installing and enabling
#                  the set links every core asset and ends the line, and a second reconcile does not place or remove
#                  a link.
#
# The checks read the withdrawn entries the installed release seeded, since a release ships some of them alone.
#
# Each phase is reported and the run goes on; the aggregate status stops the container through `systemctl exit`. SELinux
# is disabled in a container, so a label is not read.
set -uo pipefail

# shellcheck source=/dev/null
source /etc/ai-tools-upgrade-selftest.conf
ADMIN=/usr/sbin/ai-tools-admin
CONF=/etc/ai-tools/operator.conf
HOME_DIR=/opt/ai-tools
CORE_ROOT=/usr/share/ai-tools-assets/core
# The entries base withdraws, as <kind>/<name>, and the core assets that succeed them, as <set>/<kind>/<name>.
WITHDRAWN=( skills/ai-tools-technical-docs skills/ai-tools-capable-systems-governance
            skills/ai-tools-engineering-principles skills/ai-tools-reftags subagents/ai-tools-reference-architect.md )
CORE_IDS=( core/skills/ai-tools-technical-writing core/skills/ai-tools-agent-governance
           core/skills/ai-tools-engineering-principles core/skills/ai-tools-reftags
           core/subagents/ai-tools-reference-docs-maintainer )
# The withdrawn entries whose successor takes the same view name: where core is enabled, the view name holds core's link
# and an agent's existing link to it is kept.
SHARED=( skills/ai-tools-engineering-principles skills/ai-tools-reftags )
# The withdrawn entries the installed release seeded, read before the upgrade: a release ships some of them alone
# (0.23.2 predates ai-tools-reftags).
SEEDED=()
# The enabled agent's kind directories, read from the manifest the agent package installs.
AGENT_DIRS=( "${HOME_DIR}/.claude/skills" "${HOME_DIR}/.claude/agents" )

declare -a RESULTS=()
rc_total=0
banner() { printf '\n══════════════════════════════════════════════════════════════\n# %s\n══════════════════════════════════════════════════════════════\n' "$*"; }

# phase <label> <command...> : run, record PASS/FAIL, and go on to the next phase whatever the status.
phase() {
    local label="$1"; shift
    banner "${label}"
    if "$@"; then
        RESULTS+=("PASS        ${label}")
    else
        local status=$?
        RESULTS+=("FAIL(${status})  ${label}")
        rc_total=1
    fi
}

# view_path <kind>/<name> : the view path of a withdrawn entry. view_id <set>/<kind>/<name> : the view path of a core
# asset, the subagent with its .md.
view_path() { printf '%s/%s' "${HOME_DIR}" "$1"; }
view_id() {
    local kind="${1#*/}" name="${1##*/}"; kind="${kind%%/*}"
    [[ "${kind}" == subagents ]] && name+=.md
    printf '%s/%s/%s' "${HOME_DIR}" "${kind}" "${name}"
}

# assets_section : the Assets section of `ai-tools-admin status`, its heading excluded.
assets_section() {
    "${ADMIN}" status 2>/dev/null | awk '/^  Assets$/ { inside = 1; next } inside && /^  [^ ]/ { exit } inside'
}

# is_shared <kind>/<name> : succeed for an entry whose successor takes the same view name.
is_shared() { [[ " ${SHARED[*]} " == *" $1 "* ]]; }
# core_link_at <path> : succeed when <path> is a link into the set core's copy.
core_link_at() { [[ -L "$1" && "$(readlink "$1")" == "${CORE_ROOT}/"* ]]; }

# withdrawn_in_view : each withdrawn entry the installed release ships (its pristine copy) stands in the view
# as a seeded copy; records them in SEEDED.
withdrawn_in_view() {
    local entry status=0
    SEEDED=()
    for entry in "${WITHDRAWN[@]}"; do
        [[ -e "/usr/share/ai-tools/${entry}" ]] || { echo "not shipped by ${FROM_VERSION}: ${entry}"; continue; }
        if [[ -e "$(view_path "${entry}")" && ! -L "$(view_path "${entry}")" ]]; then
            SEEDED+=( "${entry}" )
        else
            echo "shipped and not seeded: ${entry}"; status=1
        fi
    done
    (( ${#SEEDED[@]} > 0 )) || { echo "no withdrawn entry was seeded"; status=1; }
    return "${status}"
}
# withdrawn_retired : each seeded entry has a copy under retired/, and no withdrawn name holds a real entry; a name
# holds a link only where it is shared and the link reaches core's copy.
withdrawn_retired() {
    local entry status=0 path
    for entry in "${SEEDED[@]}"; do
        compgen -G "${HOME_DIR}/retired/${entry#*/}.*.retired" >/dev/null || { echo "not under retired/: ${entry}"; status=1; }
    done
    for entry in "${WITHDRAWN[@]}"; do
        path="$(view_path "${entry}")"
        if [[ -L "${path}" ]]; then
            if ! is_shared "${entry}" || ! core_link_at "${path}"; then
                echo "a link at a withdrawn name: ${path} -> $(readlink "${path}")"; status=1
            fi
        elif [[ -e "${path}" ]]; then
            echo "a real entry still in the view: ${path}"; status=1
        fi
    done
    return "${status}"
}
# no_agent_link_to_withdrawn : an agent keeps a link at a withdrawn name only where the name is shared and its view path
# is core's link.
no_agent_link_to_withdrawn() {
    local dir entry status=0 link
    for dir in "${AGENT_DIRS[@]}"; do
        for entry in "${WITHDRAWN[@]}"; do
            link="${dir}/${entry#*/}"
            [[ -e "${link}" || -L "${link}" ]] || continue
            if is_shared "${entry}" && [[ "$(readlink "${link}")" == "$(view_path "${entry}")" ]] \
                    && core_link_at "$(view_path "${entry}")"; then
                continue
            fi
            echo "left: ${link}"; status=1
        done
    done
    return "${status}"
}
core_linked() {
    local id path status=0 kind
    for id in "${CORE_IDS[@]}"; do
        path="$(view_id "${id}")"; kind="${id#*/}"; kind="${kind%%/*}"
        [[ -L "${path}" && "$(readlink "${path}")" == "${CORE_ROOT}/"* ]] || { echo "not linked to core: ${path}"; status=1; }
        if [[ "${kind}" == skills ]]; then
            [[ "$(readlink "${AGENT_DIRS[0]}/${path##*/}" 2>/dev/null)" == "${path}" ]] || { echo "no agent link: ${path##*/}"; status=1; }
        else
            [[ "$(readlink "${AGENT_DIRS[1]}/${path##*/}" 2>/dev/null)" == "${path}" ]] || { echo "no agent link: ${path##*/}"; status=1; }
        fi
    done
    return "${status}"
}
core_unlinked() {
    local id
    for id in "${CORE_IDS[@]}"; do
        [[ ! -L "$(view_id "${id}")" ]] || { echo "linked: ${id}"; return 1; }
    done
}
notice_absent() {
    local section
    section="$(assets_section)"
    printf '%s\n' "${section}"
    ! grep -qE 'successor-unenabled|view-occupied' <<< "${section}"
}
notice_names_all() {
    local section row entry
    section="$(assets_section)"
    printf '%s\n' "${section}"
    row="$(grep -E '\[ATTENTION\] +successor-unenabled +core -- ' <<< "${section}")" || return 1
    [[ "$(grep -c successor-unenabled <<< "${section}")" == 1 ]] || return 1
    for entry in "${SEEDED[@]}"; do
        [[ "${row}" == *"${entry#*/}"* ]] || { echo "the line does not name ${entry#*/}"; return 1; }
    done
    grep -qE 'Summary: .* \(exit [45]\)$' <<< "${section}"
}
# relabel_ran_once_after : ai-tools-relabel.service ran exactly once since the cursor taken before the upgrade,
# and that run succeeded. Base's pretrans stops the watcher before the first file is placed, so no run starts inside
# the transaction, and its posttrans starts the service once every package is placed; the run is queued without waiting,
# so the check first waits for its job to leave the queue and the unit to leave `activating`. A run is read
# from the manager's own lines for the unit, one `Finished` or `Failed to start` per run.
relabel_ran_once_after() {
    local lines runs
    [[ -n "${RELABEL_CURSOR}" ]] || { echo "no journal cursor was taken before the upgrade"; return 1; }
    # shellcheck disable=SC2016  # the inner shell's own expansions
    timeout 600 bash -c 'while systemctl list-jobs --no-legend 2>/dev/null | grep -q ai-tools-relabel.service \
            || [[ "$(systemctl show -p ActiveState --value ai-tools-relabel.service)" == activating ]]; do sleep 1; done' \
        || { echo "the relabel run did not finish within the wait"; return 1; }
    lines="$(journalctl -q -u ai-tools-relabel.service --after-cursor="${RELABEL_CURSOR}" -o cat 2>/dev/null)"
    printf '%s\n' "${lines}"
    runs="$(grep -cE '^(Finished|Failed to start) ' <<< "${lines}")"
    [[ "${runs}" == 1 ]] || { echo "runs since the upgrade began: ${runs}, want 1"; return 1; }
    grep -q '^Finished ' <<< "${lines}" || { echo "the one run did not finish successfully"; return 1; }
    [[ "$(systemctl show -p Result --value ai-tools-relabel.service)" == success ]] \
        || { echo "the unit's result is $(systemctl show -p Result --value ai-tools-relabel.service)"; return 1; }
}
second_reconcile_quiet() {
    local stream
    stream="$("${ADMIN}" assets reconcile 2>/dev/null)" || true
    ! awk -F'\t' 'NR > 1 && $5 == "info" && ($6 == "linked" || $6 == "unlinked") { found = 1 } END { exit !found }' <<< "${stream}"
}

banner "upgrade selftest: ${UPGRADE_SCENARIO}, from ${FROM_VERSION}"
rpm -qa 'ai-tools*' | sort
phase "the host runs ${FROM_VERSION}" rpm -q "ai-tools-base-${FROM_VERSION}"
phase "base's copies stand in the view before the upgrade" withdrawn_in_view
# An enabled agent, so its kind directories are planned; 0.23 spells the list the way 0.24 reads it.
printf 'AI_TOOLS_AGENTS=[agent-claude-code]\n' >> "${CONF}"

if [[ "${UPGRADE_SCENARIO}" == key-first ]]; then
    phase "ai-tools-assets-core installs beside ${FROM_VERSION}" dnf -y install ai-tools-assets-core
    printf 'AI_TOOLS_ASSETS=[%s]\n' "$(IFS=,; printf '%s' "${CORE_IDS[*]}" | sed 's/,/, /g')" >> "${CONF}"
fi

RELABEL_CURSOR="$(journalctl -q -n0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')"
# shellcheck disable=SC2016  # PIPESTATUS is the inner shell's
phase "dnf upgrade to this tree's build" \
    bash -c 'dnf -y --repo=ai-tools-local upgrade "ai-tools*" 2>&1 | tee /tmp/upgrade.log; exit "${PIPESTATUS[0]}"'
phase "the base package is this tree's build" bash -c "! rpm -q 'ai-tools-base-${FROM_VERSION}' >/dev/null"
phase "ai-tools-relabel.service ran exactly once, after every package was placed, and succeeded" relabel_ran_once_after
phase "each withdrawn copy is moved under retired/" withdrawn_retired
phase "no agent keeps a link to a withdrawn name" no_agent_link_to_withdrawn

case "${UPGRADE_SCENARIO}" in
    key-first)
        phase "the upgrade's transaction links every core asset, in the view and for the agent" core_linked
        phase "the Assets section reports no successor notice and no view-occupied" notice_absent
        phase "the transaction output names the successor set" \
            grep -q 'their successors are in the asset set core (package ai-tools-assets-core)' /tmp/upgrade.log ;;
    without-core)
        phase "no core asset is linked" core_unlinked
        phase "one successor-unenabled line names every withdrawn entry, and the section closes with its summary" \
            notice_names_all
        phase "ai-tools-assets-core installs" dnf -y install ai-tools-assets-core
        phase "assets enable --set core" "${ADMIN}" assets enable --set core
        phase "every core asset is linked, in the view and for the agent" core_linked
        phase "the notice has ended" notice_absent
        phase "a second reconcile places and removes no link" second_reconcile_quiet ;;
    *)
        RESULTS+=("FAIL        an unknown scenario: ${UPGRADE_SCENARIO}"); rc_total=1 ;;
esac

banner "UPGRADE SELFTEST SUMMARY (${UPGRADE_SCENARIO})"
printf '%s\n' "${RESULTS[@]}"
systemctl exit "${rc_total}" 2>/dev/null || { systemctl halt --no-block; exit "${rc_total}"; }
