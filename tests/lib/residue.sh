#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/residue.sh
# The pre-run residue sweep run.sh runs before dispatching a category: finds what an earlier run
# left behind and removes it, so a run starts from a host that carries none of this suite's
# fixtures. Sourced by run.sh as root; it does not source harness.sh (which sets traps and
# derives a project user) and takes the project user's home as an argument instead.
#
# What it finds is decided by the name rule in harness.sh: every path a test creates outside its
# testdir is `.ai-tools-test-<group>-<thing>-XXXXXX`, so one pattern over the directories fixtures
# are born in (AI_TEST_RESIDUE_SITES, scanned one level deep, never recursively) is the whole
# search. The one path that cannot carry the rule is listed by name: ai-tools-run accepts an
# entrypoint only at a bare semver version directory, so integration/ai-tools-run.sh probes it
# in `v0.0.1` inside the live toolchain tree (a version Node never shipped).
#
# Removal is rm -rf for a file or directory, and for a fixture cgroup (integration/stop.sh makes
# one at the cgroup v2 root) a cgroup.kill over the subtree and then rmdir, deepest first. A path
# that survives removal is reported and fails the sweep, so run.sh refuses to run rather than
# start a suite on a host it could not clean. The suite is run one at a time: a second run
# started while one is live would sweep the first run's fixtures.

readonly AI_TEST_RESIDUE_GLOB='.ai-tools-test-*'
readonly AI_TEST_RESIDUE_FIXED=(/opt/ai-tools/.nvm/versions/node/v0.0.1)

# ai_test_residue_sites <projects-home>: PRINT the directories fixtures are born in, one per
# line, existing ones only. The operator's home holds the noexec-/tmp fallback dirs and the
# manual suite's workspace fixtures; the clone area holds the manual --for drill's tree beside
# the label probes. The cgroup v2 root is read from /proc/mounts, the way the stop helper reads it.
ai_test_residue_sites() {
    local home="$1" d mount_point fstype
    local -a sites=(
        /tmp
        "${home}"
        /var/opt/ai-tools
        /var/opt/ai-tools/sandbox-projects
        /opt/ai-tools
        /opt/ai-tools/.claude
        /opt/ai-tools/.config/systemd/user
        /opt/ai-tools/.config/systemd/user/timers.target.wants
        /var/log/journal
    )
    while read -r _ mount_point fstype _; do
        [[ "${fstype}" == "cgroup2" ]] && { sites+=("${mount_point}"); break; }
    done < /proc/mounts
    for d in "${sites[@]}"; do
        [[ -n "${d}" && -d "${d}" ]] && printf '%s\n' "${d}"
    done
    return 0
}

# ai_test_residue_find <projects-home>: PRINT every leftover, one absolute path per line -- each
# entry under a site matching the name rule, and each fixed path that exists.
ai_test_residue_find() {
    local site p
    while IFS= read -r site; do
        find "${site}" -mindepth 1 -maxdepth 1 -name "${AI_TEST_RESIDUE_GLOB}" 2>/dev/null
    done < <(ai_test_residue_sites "$1")
    for p in "${AI_TEST_RESIDUE_FIXED[@]}"; do
        [[ -e "${p}" ]] && printf '%s\n' "${p}"
    done
    return 0
}

# ai_test_residue_is_cgroup <path>: the path is a directory on a cgroup2 filesystem.
ai_test_residue_is_cgroup() {
    [[ -d "$1" && "$(stat -f -c '%T' "$1" 2>/dev/null)" == "cgroup2fs" ]]
}

# ai_test_residue_remove <path>: remove one leftover; 0 when it is gone afterwards.
ai_test_residue_remove() {
    local p="$1" dir _attempt
    if ai_test_residue_is_cgroup "${p}"; then
        while IFS= read -r dir; do
            [[ -e "${dir}/cgroup.kill" ]] && printf '1' > "${dir}/cgroup.kill" 2>/dev/null
        done < <(find "${p}" -type d 2>/dev/null)
        for _attempt in 1 2 3 4 5 6 7 8 9 10; do
            find "${p}" -depth -type d -exec rmdir {} + 2>/dev/null
            [[ -d "${p}" ]] || return 0
            sleep 0.5
        done
    else
        rm -rf -- "${p}" 2>/dev/null
    fi
    [[ ! -e "${p}" ]]
}

# ai_test_residue_sweep <projects-home>: find, remove, and report every leftover. Silent when
# there is none; each removal is one line, so the run log says what an earlier run left.
# Returns non-zero when a path could not be removed.
ai_test_residue_sweep() {
    local p rc=0 found=0
    while IFS= read -r p; do
        [[ -n "${p}" ]] || continue
        found=1
        if ai_test_residue_remove "${p}"; then
            printf '  residue  removed %s (left by an earlier run)\n' "${p}"
        else
            printf '  residue  could not remove %s -- remove it and rerun\n' "${p}" >&2
            rc=1
        fi
    done < <(ai_test_residue_find "$1")
    (( found )) && printf '\n'
    return "${rc}"
}
