#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/selinux.sh
# Integration: the SELinux confinement layer is enforcing, rather than loaded and silently inert. Trust-chain step 4
# in CLAUDE.md rests on ai_tools_t / ai_tools_handback_t type enforcement, and a `setenforce 0` or a stray
# `semanage permissive -a ai_tools_t` -- the kind of "temporary debug" that never gets reverted -- drops that boundary
# while every DAC test stays green. This file is the signal that would otherwise be missing. With the module loaded it
# asserts: the system is Enforcing and neither domain is individually permissive; the module-presence probe ai-tools-run
# reads resolves the way the shim expects; a sandbox clone takes ai_tools_project_t; each agent's declared entrypoint
# rule still covers what its package installed; no link in the exec chain carries a type the confined domain may write;
# one inode per agent package carries the domain entry type; every enrolled operator's config subtree carries
# ai_tools_conf_t, the type the root helpers read that account's allowlist through; and the descriptor-pinned walk
# labels a fixture tree as its rules give it, while a process of the sandbox account runs.
#
# The layer is OPTIONAL -- the policy is its own subpackage, and a host may run DAC-only -- so with the module absent
# the whole file SKIPS instead of demanding SELinux on a host that does not ship it. Run as root.
#
# run.sh: serial
#
# Serial under `run.sh -j`: the walk rows add and delete `semanage fcontext` rules, and each change rebuilds
# the policy that every other file's label reads see.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "SELinux confinement is enforcing (integration)"

# selinux_note: printed with the layer-absent skips so a DAC-only run states its posture and the recommendation once:
# DAC is the enforced boundary either way; the SELinux layer is the recommended second one on hosts that support it.
# A container (e.g. podman) has no policy of its own -- the layer belongs to the host running it.
selinux_note() {
    printf '  NOTE  running on DAC alone -- the filesystem boundary holds; the optional SELinux layer is not active\n'
    printf '        recommended on SELinux-capable hosts:  sudo %s install\n' \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/selinux/install-selinux.sh"
    printf '        (inside a container, e.g. podman, the layer is provided by the host)\n'
}

# (0) SELinux must be present and not globally disabled, or the confinement layer is moot.
if ! command -v getenforce >/dev/null 2>&1; then
    skip "SELinux enforcing" "getenforce not installed (SELinux userspace absent)"
    selinux_note; finish; exit
fi
mode="$(getenforce 2>/dev/null || true)"
if [[ -z "${mode}" || "${mode}" == "Disabled" ]]; then
    skip "SELinux enforcing" "SELinux is ${mode:-unavailable} (no policy loaded on this host)"
    selinux_note; finish; exit
fi

# (1) Is the ai_tools confinement module loaded? Prefer semodule; fall back to seinfo (setools). When neither tool is
# present we cannot tell, so the whole check skips rather than guess.
module_loaded() {
    if command -v semodule >/dev/null 2>&1; then
        # Captured, not piped into `grep -q`: an early-exiting reader makes semodule die of SIGPIPE, which this file's
        # pipefail reports as "module absent" -- see the note on ai_tools_selinux_groups__is_loaded
        # (selinux-groups.lib.sh).
        local modules
        modules="$(semodule -l 2>/dev/null || true)"
        grep -qx 'ai_tools' <<<"${modules}"
    elif command -v seinfo >/dev/null 2>&1; then
        seinfo -t ai_tools_t >/dev/null 2>&1
    else
        return 2
    fi
}
module_loaded; ml=$?
if [[ ${ml} -eq 2 ]]; then
    skip "SELinux enforcing" "neither semodule nor seinfo available to detect the ai_tools module"; finish; exit
elif [[ ${ml} -ne 0 ]]; then
    skip "SELinux enforcing" "ai_tools SELinux module not loaded (confinement layer not installed on this host)"
    selinux_note; finish; exit
fi

# (2) Module IS loaded: global mode must be Enforcing. Permissive here means the confined session runs with type
# enforcement disabled -- a full confinement bypass this test exists to catch. (A deliberate permissive bring-up is
# expected to fail this; that is the signal.)
if [[ "${mode}" == "Enforcing" ]]; then
    pass "global SELinux mode is Enforcing (ai_tools module loaded)"
else
    fail "ai_tools module is loaded but SELinux is ${mode} -- the session runs unconfined. Fix: setenforce 1 (and check /etc/selinux/config)"
fi

# (3) Neither confinement domain may be individually marked permissive -- that exempts the domain from enforcement even
# while the system is globally Enforcing (same bypass, narrower blast radius). Prefer `semanage permissive -l`; fall
# back to `seinfo --permissive`.
list_permissive() {
    if command -v semanage >/dev/null 2>&1; then
        semanage permissive -l 2>/dev/null
    elif command -v seinfo >/dev/null 2>&1; then
        seinfo --permissive 2>/dev/null
    else
        return 2
    fi
}
perm_list="$(list_permissive)"; pl=$?
if [[ ${pl} -eq 2 ]]; then
    skip "confinement domains not permissive" "neither semanage nor seinfo available to list permissive types"
else
    perm_hit="$(printf '%s\n' "${perm_list}" | grep -Ew 'ai_tools_t|ai_tools_handback_t' || true)"
    if [[ -z "${perm_hit}" ]]; then
        pass "neither ai_tools_t nor ai_tools_handback_t is marked permissive"
    else
        fail "a confinement domain is permissive (exempt from enforcement): ${perm_hit//$'\n'/ }. Fix: semanage permissive -d <domain>"
    fi
fi

# (4) The module-presence probe ai-tools-run relies on. The shim runs as the SANDBOX account, which cannot read
# the root-only module store, so it derives the `module` verdict input from matchpathcon on a CORE-owned path.
# With the module loaded here, that path MUST resolve to an ai_tools_* type -- otherwise the probe would read module=no
# and the fail-closed "unverifiable" refusal would silently downgrade to a DAC-only launch (the fail-open this fix
# closes). This is the runtime end of that guarantee; the agent cannot forge it (file-contexts + the shim are root-owned
# -- boundary/access.sh).
if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "module-presence probe" "matchpathcon not available"
else
    probe_type="$(matchpathcon -n /opt/ai-tools/.config 2>/dev/null | awk -F: '{print $3}' || true)"
    if [[ "${probe_type}" == ai_tools_* ]]; then
        pass "module-presence probe: matchpathcon /opt/ai-tools/.config -> ${probe_type} (module seen without the root-only store)"
        # Tie the real input to the deployed classifier, when it is present (skips on a pre-fix install).
        lib=/usr/local/lib/ai-tools/confinement.lib.sh
        if [[ -r "${lib}" ]] && source "${lib}" 2>/dev/null \
                && declare -F ai_tools_confinement__evaluate_module_present >/dev/null 2>&1; then
            if [[ "$(ai_tools_confinement__evaluate_module_present "${probe_type}")" == yes ]]; then
                pass "ai_tools_confinement__evaluate_module_present(${probe_type}) -> yes"
            else
                fail "classifier rejected a live core type ${probe_type}"
            fi
        fi
    else
        fail "module loaded but matchpathcon /opt/ai-tools/.config -> ${probe_type:-none} (not ai_tools_*) -- the sandbox-side probe would read module=no and fail OPEN"
    fi
fi

# (5) Sandbox clones must LABEL as ai_tools_project_t. Their on-disk path is under /var/opt/ai-tools/sandbox-projects.
# Whether libselinux looks that path up as /opt/... depends on the host's file_contexts.subs_dist (`/var/opt /opt` is
# in EL10's and not in EL9's), so ai_tools.fc carries the clone rule under both prefixes. This asserts the one this host
# reaches is there: a synthetic clone path resolves to ai_tools_project_t. The note says which prefix answered, so a run
# on each EL shows the twin it relies on. matchpathcon reads the loaded policy, so the path need not exist.
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "sandbox clone label" "matchpathcon not available"
else
    sbx_type="$(matchpathcon -n "${SANDBOX_ROOT}/_probe-$$" 2>/dev/null | awk -F: '{print $3}' || true)"
    sbx_alias=no
    grep -qE '^[[:space:]]*/var/opt[[:space:]]+/opt[[:space:]]*$' \
        /etc/selinux/targeted/contexts/files/file_contexts.subs_dist 2>/dev/null && sbx_alias=yes
    if [[ "${sbx_type}" == "ai_tools_project_t" ]]; then
        pass "sandbox clone path resolves to ai_tools_project_t (/var/opt alias on this host: ${sbx_alias})"
    else
        fail "sandbox clone path -> ${sbx_type:-none}, not ai_tools_project_t (/var/opt alias on this host: ${sbx_alias}) -- the loaded ai_tools module lacks the clone rule under the prefix this host matches; reload it: sudo selinux/install-selinux.sh install"
    fi
fi

# (6) The label primitives on a sandbox clone, the branch that does not mutate policy. relabel.lib.sh splits
# on _ai_tools_relabel__is_under_sandbox_root: a clone is covered by the STATIC ai_tools.fc rule, so the helper does not
# add a per-path `semanage fcontext` entry and has none to remove. ai_tools_relabel__label_project still verifies
# the achieved label rather than trusting restorecon's exit status, so a mislabel is a hard failure -- the regression
# that let a usr_t clone report success. After an unlabel a clone is still labelled, which is what keeps it reachable
# by the confined agent: the way to un-label a clone is to delete it (ai-tools.projects.remove.clone).
#
# The other branch -- a claimed project, where the helper adds and then removes a per-path fcontext rule -- is
# deliberately NOT exercised. Driving it would mutate the host's local SELinux policy to test a helper, which no test
# here does, and a teardown that can leave a policy entry behind is worse than the coverage it buys. That leaves
# ai_tools_relabel__unlabel_project's revert path (the one ai-tools.projects.unclaim drives) uncovered: a known gap,
# recorded rather than papered over.
#
# The label is a recursive walk through the descriptor-pinned tree walker, which does not gate on a live session of
# the sandbox account (relabel.lib.sh), so the cases run whatever that account is doing.
RELABEL_LIB=/usr/local/lib/ai-tools/relabel.lib.sh
if [[ ! -d "${SANDBOX_ROOT}" ]]; then
    skip "sandbox clone label" "sandbox area ${SANDBOX_ROOT} not present"
elif [[ ! -r "${RELABEL_LIB}" ]] || ! source "${RELABEL_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_relabel__label_project >/dev/null 2>&1; then
    skip "sandbox clone label" "relabel.lib.sh not available at ${RELABEL_LIB}"
else
    # A real clone-area path, since the static rule is keyed on that prefix; named and registered through the harness
    # so the sweep finds what an aborted run leaves.
    sandbox_probe_dir=""; mk_fixture_dir sandbox_probe_dir "${SANDBOX_ROOT}" relabel
fi
if [[ -n "${sandbox_probe_dir:-}" ]]; then
    if ai_tools_relabel__label_project "${sandbox_probe_dir}" && ai_tools_relabel__is_project_labelled "${sandbox_probe_dir}"; then
        pass "ai_tools_relabel__label_project applies AND verifies ai_tools_project_t on a sandbox clone"
    else
        fail "sandbox clone ${sandbox_probe_dir} is not ai_tools_project_t ($(ls -Zd "${sandbox_probe_dir}" 2>/dev/null))"
    fi
    ai_tools_relabel__unlabel_project "${sandbox_probe_dir}" >/dev/null 2>&1 || true
    if ai_tools_relabel__is_project_labelled "${sandbox_probe_dir}"; then
        pass "an unlabel leaves a sandbox clone labelled (the static rule is authoritative)"
    else
        fail "unlabel stripped ai_tools_project_t from a sandbox clone -- the agent loses access to every clone"
    fi
    rmdir "${sandbox_probe_dir}" 2>/dev/null || true
fi

# (7) The declared entrypoint rule still describes where each enabled agent's package installs its executable. This is
# the live half of unit/relabel.sh's pure reconciliation: the resolution needs a provisioned toolchain (and root,
# to traverse the 0750 nvm tree), so only a real host can drive it.
#
# What it catches is upstream repackaging. The agent's executable is delivered through a nested, platform-specific
# optional dependency and hardlinked into the path the manifest declares -- so the declaration holds only while
# that postinstall hardlink does. A release that stops creating it leaves the entrypoint installed, unlabelled,
# and every launch fail-closing. This assertion turns that into a test failure at the next suite run instead
# of a refused launch for an operator.
#
# Read-only: it resolves and compares, and does not mutate policy.
section "SELinux: each enabled agent's declared entrypoint rule matches what is installed"

if ! declare -F ai_tools_relabel__evaluate_entrypoint_reconcile >/dev/null 2>&1 \
        || ! declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1; then
    skip "entrypoint declaration reconciliation" "relabel.lib.sh/providers.lib.sh not loaded"
else
    agents_seen=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        agents_seen=$(( agents_seen + 1 ))
        installed="$(ai_tools_relabel__resolve_agent_entrypoint_path "${agent}" || true)"
        if [[ -z "${installed}" ]]; then
            skip "${agent} entrypoint declaration" "its launcher does not resolve (not provisioned)"
            continue
        fi
        pattern="$(ai_tools_providers__read_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
        covered=no matched=no copy=no
        matches=()
        while IFS= read -r p; do
            matched=yes
            matches+=("${p}")
            [[ "${p}" == "${installed}" ]] && covered=yes
        done < <(_ai_tools_relabel__find_entrypoint_paths "${pattern}")
        # The same copy reading the relabel makes, so the failure names the cause the relabel will.
        if [[ "${covered}" != yes && -f "${installed}" && ! -L "${installed}" ]]; then
            for p in "${matches[@]}"; do cmp -s -- "${installed}" "${p}" && { copy=yes; break; }; done
        fi
        case "$(ai_tools_relabel__evaluate_entrypoint_reconcile "${installed}" "${covered}" "${matched}" "${copy}")" in
            ok) pass "${agent}: its declared entrypoint rule covers ${installed}" ;;
            copied) fail "${agent}: its launcher resolves to ${installed}, a copy of the entrypoint its manifest declares where the toolchain keeps a symlink -- every launch will fail closed; restore the links: sudo ai-tools-admin system bootstrap" ;;
            incomplete) fail "${agent}: installed at ${installed}, and no file matches the entrypoint its manifest declares -- every launch will fail closed; reinstall: sudo ai-tools-admin system bootstrap" ;;
            *)  fail "${agent}: installed at ${installed}, which its declared entrypoint_fcontext does not cover -- every launch will fail closed; the manifest is stale" ;;
        esac
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    (( agents_seen > 0 )) || skip "entrypoint declaration reconciliation" "no enabled agent resolved"
fi

# (7b) The loaded core module audits an entrypoint exec made from inside a session. `ai-tools audit`'s kernel-record
# section reads the AVC `granted` records that `auditallow ai_tools_t ai_tools_exec_t:file execute_no_trans;` writes,
# and reports the rule as not in force where sesearch finds none; this is the live half of unit/audit.sh's lockstep
# between the policy source and the reader. What it catches is a host whose loaded module predates the rule -- a policy
# package not upgraded beside the base -- which the reader reports as a diagnostic on every run until it is. Read-only:
# sesearch reads the loaded policy. Skips without setools, which the reader itself treats the same way.
section "SELinux: the core module audits an in-session entrypoint exec"

if ! command -v sesearch >/dev/null 2>&1; then
    skip "auditallow on the entrypoint exec" "sesearch (setools-console) not installed"
else
    # Captured, then matched: a `grep -q` at the end of a pipe exits at the match and leaves sesearch to SIGPIPE.
    exec_audit_rules="$(sesearch --auditallow -s ai_tools_t -t ai_tools_exec_t -c file -p execute_no_trans 2>/dev/null || true)"
    if [[ "$(grep -c '^auditallow ' <<<"${exec_audit_rules}")" == 1 ]]; then
        pass "the loaded policy carries one auditallow ai_tools_t ai_tools_exec_t:file execute_no_trans"
    else
        fail "the loaded policy carries $(grep -c '^auditallow ' <<<"${exec_audit_rules}") auditallow rule(s) for the entrypoint exec, expected 1 -- ai-tools audit cannot read an in-session exec; rebuild: sudo selinux/install-selinux.sh rebuild"
    fi
fi

# (7c) The handback domain opens the agent's temp type and does not hold a relabel right. A file the session made
# in /tmp and moved into a project keeps ai_tools_tmp_t, and the helper opens it to pin it before the chown,
# so the loaded policy must grant ai_tools_handback_t `open` on that type. The same domain must not hold `relabelfrom`
# on any type: the type of a moved-in path stays until a re-claim relabels it, and a relabel right in an agent-reachable
# domain is a decision this assertion makes visible. Read-only, as (7b).
section "SELinux: the handback domain opens the agent's temp files and holds no relabel right"

if ! command -v sesearch >/dev/null 2>&1; then
    skip "handback domain grants" "sesearch (setools-console) not installed"
else
    tmp_open_rules="$(sesearch --allow -s ai_tools_handback_t -t ai_tools_tmp_t -c file -p open 2>/dev/null || true)"
    if [[ "$(grep -c '^allow ' <<<"${tmp_open_rules}")" -ge 1 ]]; then
        pass "the loaded policy lets ai_tools_handback_t open ai_tools_tmp_t files"
    else
        fail "the loaded policy does not let ai_tools_handback_t open ai_tools_tmp_t files -- a file moved in from /tmp stays sandbox-owned; rebuild: sudo selinux/install-selinux.sh rebuild"
    fi
    relabel_rules="$(sesearch --allow -s ai_tools_handback_t -p relabelfrom 2>/dev/null || true)"
    if [[ "$(grep -c '^allow ' <<<"${relabel_rules}")" == 0 ]]; then
        pass "ai_tools_handback_t does not hold relabelfrom on any type"
    else
        fail "ai_tools_handback_t holds relabelfrom: $(grep -m1 '^allow ' <<<"${relabel_rules}")"
    fi
fi

# (7d) The confined domain cannot write a cgroup file or create a cgroup. The relabel gate exempts the account's
# user-manager plumbing by unit name (sessions.lib.sh), which holds only while a session can neither move a task
# into a cgroup it names nor make one; both are writes on cgroup_t. Read-only, as (7b): the loaded policy is asked,
# and selinux/avc/avc-denials.sh section Y makes the same writes from inside a session.
section "SELinux: the confined domain cannot write a cgroup file or create a cgroup"

if ! command -v sesearch >/dev/null 2>&1; then
    skip "cgroup writes" "sesearch (setools-console) not installed"
else
    cgroup_file_rules="$(sesearch --allow -s ai_tools_t -t cgroup_t -c file -p write,append 2>/dev/null || true)"
    cgroup_dir_rules="$(sesearch --allow -s ai_tools_t -t cgroup_t -c dir -p add_name,create,write 2>/dev/null || true)"
    # The control: the same query over a type the domain does write returns a rule, so an empty answer for cgroup_t
    # is a reading of the policy and not a query that read no rule at all.
    control_rules="$(sesearch --allow -s ai_tools_t -t ai_tools_project_t -c file -p write 2>/dev/null || true)"
    if [[ "$(grep -c '^allow ' <<<"${control_rules}")" -eq 0 ]]; then
        fail "sesearch returns no write rule for ai_tools_t on ai_tools_project_t either -- the query reads nothing on this host"
    elif [[ "$(grep -c '^allow ' <<<"${cgroup_file_rules}")" -eq 0 \
            && "$(grep -c '^allow ' <<<"${cgroup_dir_rules}")" -eq 0 ]]; then
        pass "ai_tools_t holds no write on a cgroup_t file and no create in a cgroup_t directory (control: it writes ai_tools_project_t)"
    else
        fail "ai_tools_t can write cgroup_t: $(grep -m1 '^allow ' <<<"${cgroup_file_rules}${cgroup_dir_rules}") -- the relabel gate's plumbing exemption no longer holds"
    fi
fi

# (8) The build-output type, where the dotnet layout module is loaded. Its static rule must win over the clone rule
# for a path under one of the named directories and lose everywhere else -- the precedence the narrowing rests
# on, decided by libselinux from the two rules' stems, which no unit test can read. matchpathcon reads the loaded file
# contexts, so the paths need not exist; the live half creates a bin/ directory in the sandbox area as root, which runs
# in unconfined_t, the shipped operator domain, and asserts the module's named transition put it on the build type
# without a restorecon. The ai_tools_t transition and the execute grant need a session and are exercised
# by selinux/avc/avc-testsuite.sh. Skips when the layout module is not loaded: the base carries the type, the module
# the mapping.
section "SELinux: the dotnet layout module types build output and only build output"

# type_of <path> : PRINT the SELinux type, or an empty string. Shared with the exec-chain section.
type_of() { stat -c '%C' -- "$1" 2>/dev/null | awk -F: '{print $3}'; }

if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "build-output labelling" "matchpathcon not available"
elif ! grep -qx 'ai_tools_dotnet' <<<"$(semodule -l 2>/dev/null || true)"; then
    skip "build-output labelling" "the ai_tools_dotnet layout module is not loaded"
else
    for probe in "_p$$/bin/x:ai_tools_project_build_t" "_p$$/src/Proj/obj/x.dll:ai_tools_project_build_t" \
                 "_p$$/tests/T.Tests/bin/Release/T:ai_tools_project_build_t" "_p$$/artifacts/publish/App:ai_tools_project_build_t" \
                 "_p$$/.githooks/pre-commit:ai_tools_project_t" "_p$$/binary/x:ai_tools_project_t" "_p$$:ai_tools_project_t"; do
        path="${SANDBOX_ROOT}/${probe%%:*}"; want="${probe##*:}"
        got="$(matchpathcon -n "${path}" 2>/dev/null | awk -F: '{print $3}' || true)"
        if [[ "${got}" == "${want}" ]]; then pass "${probe%%:*} -> ${want}"
        else fail "${probe%%:*} -> ${got:-none}, expected ${want} (rule precedence between the clone rule and the layout module's rule)"; fi
    done
    if [[ -d "${SANDBOX_ROOT}" ]]; then
        tprobe=""; mk_fixture_dir tprobe "${SANDBOX_ROOT}" build
        restorecon -F "${tprobe}" 2>/dev/null || true
        mkdir "${tprobe}/bin" "${tprobe}/src" 2>/dev/null || true
        bt="$(type_of "${tprobe}/bin")"; st="$(type_of "${tprobe}/src")"
        if [[ "${bt}" == ai_tools_project_build_t && "${st}" == ai_tools_project_t ]]; then
            pass "a bin/ directory created by an operator domain is born ai_tools_project_build_t; a sibling stays ai_tools_project_t (named transition, no restorecon)"
        else
            fail "created bin/ is ${bt:-none} and src/ is ${st:-none} -- the layout module's operator-domain transition did not fire"
        fi
        rm -rf "${tprobe}" 2>/dev/null || true
    fi
fi

# The exec chain is READ-ONLY to the confined domain, which is what makes a tampered entrypoint unreachable rather than
# merely detected (see confinement.rule.md). DAC alone permits the write -- the sandbox account owns this whole tree --
# so the type layout is the only thing refusing it, and it is asserted HERE rather than in tests/boundary, whose probes
# run as the sandbox *user* but outside ai_tools_t and therefore see DAC only.
#
# Asserted as the layout rather than by driving a denial: querying the allow rules needs setools (not installed
# on a minimal host) and provoking a real AVC would mean writing into the production toolchain, which this file's header
# rules out. What is checked is the property the policy rests on -- no link in the chain carries a type ai_tools_t holds
# a manage rule for. Those three types are the whole manage set in ai_tools.te; a fourth added there without a matching
# entry here is exactly the regression worth failing on.
section "SELinux: the agent's exec chain carries no type the confined domain may write"

readonly AI_TOOLS_MANAGED_TYPES="ai_tools_project_t ai_tools_project_build_t ai_tools_home_t ai_tools_tmp_t"

if ! declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1; then
    skip "exec chain type containment" "providers.lib.sh not loaded"
else
    chain_seen=0
    while IFS=$'\t' read -r agent _ launcher; do
        [[ -n "${agent}" && -n "${launcher}" ]] || continue
        entry="$(ai_tools_relabel__resolve_agent_entrypoint_path "${agent}" || true)"
        [[ -n "${entry}" ]] || continue
        chain_seen=$(( chain_seen + 1 ))
        # One link per swap vector: an in-place write to the entrypoint, a rename-over in its directory, a repoint
        # of the versioned launcher symlink's directory.
        versioned="$(readlink -- "/opt/ai-tools/bin/${launcher}" 2>/dev/null || true)"
        for link in "${entry}" "${entry%/*}" "${versioned%/*}"; do
            [[ -n "${link}" && -e "${link}" ]] || continue
            t="$(type_of "${link}")"
            if [[ -z "${t}" ]]; then
                skip "${agent} exec chain" "no SELinux type readable on ${link}"
            elif [[ " ${AI_TOOLS_MANAGED_TYPES} " == *" ${t} "* ]]; then
                fail "${agent}: ${link} is ${t}, a type ai_tools_t may manage -- the confined agent could tamper with its own entrypoint and the tamper would persist across sessions and operators"
            else
                pass "${agent}: ${link} is ${t}, outside the domain's manage set"
            fi
        done
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    (( chain_seen > 0 )) || skip "exec chain type containment" "no enabled agent's entrypoint resolved"
fi

# Every executable in an agent's package tree, by type. ai_tools_exec_t is the domain's ENTRY type -- the label
# the manager transitions on -- so exactly one file in a package may carry it: the one the manifest declares and the pin
# covers. A vendor shipping a second executable beside the entrypoint, or a file-context pattern that widened, would
# otherwise add a domain entrypoint no manifest claims, no pin checksums, and no operator knows about.
#
# The rest of the tree is enumerated and REPORTED rather than asserted, because the count is what moves when a release
# adds a helper. Their lib_t does not mean unexecutable: ai_tools_t executes lib_t through libs_read_lib_files and every
# bin_t file through corecmd_exec_bin, and codex's vendored rg, zsh and bwrap each start inside a session. What a type
# decides here is whether a file can be an entrypoint, which is why that is the assertion and the rest is a tally.
#
# Read-only: it stats live labels and runs no relabel. Root, to traverse the 0750 nvm tree.
section "SELinux: one executable per agent package carries the domain entry type"

if ! declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 \
        || ! declare -F ai_tools_providers__read_agent_manifest_field >/dev/null 2>&1; then
    skip "package entry-type enumeration" "providers.lib.sh not loaded"
else
    pkg_seen=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        entry="$(ai_tools_relabel__resolve_agent_entrypoint_path "${agent}" || true)"
        pkg="$(ai_tools_providers__read_agent_manifest_field "${agent}" npm_package || true)"
        [[ -n "${entry}" && -n "${pkg}" ]] || continue
        # The package root is the path up to the FIRST /lib/node_modules/<npm_package>/, which is where npm installs it;
        # an entrypoint nested under a platform-specific dependency (codex) sits further down the same prefix.
        # An entrypoint outside that prefix has no package root to enumerate; the declared-rule section reports it.
        if [[ "${entry}" != */lib/node_modules/"${pkg}"/* ]]; then
            skip "${agent} package entry-type enumeration" "the launcher resolves to ${entry}, outside ${pkg}'s package tree"
            continue
        fi
        root="${entry%%/lib/node_modules/"${pkg}"/*}/lib/node_modules/${pkg}"
        if [[ ! -d "${root}" ]]; then
            skip "${agent} package entry-type enumeration" "no package tree at ${root}"
            continue
        fi
        pkg_seen=$(( pkg_seen + 1 ))
        # Counted by INODE, not by path. An agent's platform-specific dependency is HARDLINKED into the path
        # the manifest declares, so the entrypoint answers to two names that share one inode and therefore one label --
        # the same distinction that made a path-wise entrypoint reconciliation report a false positive. What would be
        # a second entrypoint is a second inode.
        entry_names=(); entry_inodes=""; types=""
        while IFS= read -r f; do
            t="$(type_of "${f}")"
            if [[ "${t}" == ai_tools_exec_t ]]; then
                entry_names+=("${f}")
                entry_inodes+="$(stat -c '%d:%i' -- "${f}" 2>/dev/null || echo unreadable)"$'\n'
            fi
            types+="${t:-unreadable}"$'\n'
        done < <(find "${root}" -type f -perm -u+x 2>/dev/null)
        distinct="$(printf '%s' "${entry_inodes}" | sort -u | grep -c '^.' || true)"
        entry_inode="$(stat -c '%d:%i' -- "${entry}" 2>/dev/null || true)"
        if [[ "${distinct}" -eq 1 && -n "${entry_inode}" ]] \
                && grep -qxF "${entry_inode}" <<<"${entry_inodes}"; then
            pass "${agent}: one inode in ${pkg} carries ai_tools_exec_t, and it is the declared entrypoint (${#entry_names[@]} name(s): ${entry_names[*]})"
        elif [[ "${distinct}" -eq 0 ]]; then
            fail "${agent}: no file under ${root} carries ai_tools_exec_t -- the manager has nothing to transition on and every launch fail-closes. Fix: sudo ai-tools-admin system entrypoints relabel"
        elif [[ "${distinct}" -eq 1 ]]; then
            fail "${agent}: the one inode carrying ai_tools_exec_t (${entry_names[*]}) is not the declared entrypoint ${entry} -- a binary no manifest claims is the domain's entry point"
        else
            fail "${agent}: ${distinct} distinct inodes carry ai_tools_exec_t (${entry_names[*]}) -- each is a domain entrypoint the manifest does not declare and the pin does not cover"
        fi
        # A name-wise breakdown beside the inode-wise verdict: the entrypoint's hardlinked names count twice here
        # and once there, so the two agree on a healthy package.
        by_type="$(printf '%s' "${types}" | sort | uniq -c | awk '{printf "%s%s(%s)", (NR > 1 ? " " : ""), $2, $1}')"
        note "${agent}: $(printf '%s' "${types}" | grep -c '^.' || true) executable file(s) under ${pkg}, by type: ${by_type}" \
            "counted by name; the check above counts inodes, so hardlinked names of the entrypoint count once there"
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    (( pkg_seen > 0 )) || skip "package entry-type enumeration" "no enabled agent's package tree resolved"
fi

# EVERY enrolled operator's config subtree must carry ai_tools_conf_t, not only the account that ran the installer.
# The root helpers run in ai_tools_handback_t, which holds that narrow type alone under ~/.config, so an unlabelled
# subtree denies their getattr on that operator's allowlist, no owner resolves, and the ownership handback no-ops
# for every project the account owns. Every DAC test stays green through that, and dontaudit suppresses the session's
# own denial on the same path, which leaves an unattributed handback-domain AVC as the only signal an enforcing host
# gives.
#
# Read-only: it stats the live label and does not register a rule, the same line this file draws
# for ai_tools_relabel__unlabel_project. What repairs a failure is `ai-tools-admin operators add <user>`,
# which registers the rule per account, or a full `install-selinux.sh relabel`, which sweeps the list.
section "SELinux: every enrolled operator's config subtree is ai_tools_conf_t"

if ! declare -F ai_tools_operator__load_operators >/dev/null 2>&1 \
        && ! source /usr/local/lib/ai-tools/operator.lib.sh 2>/dev/null; then
    skip "operator config labelling" "operator.lib.sh not readable -- cannot resolve the operator list"
elif ! ai_tools_operator__load_operators; then
    skip "operator config labelling" "no operator is enrolled in operator.conf"
else
    for op_name in "${AI_TOOLS_OPERATOR__OPERATORS[@]}"; do
        op_home="$(getent passwd "${op_name}" 2>/dev/null | cut -d: -f6 || true)"
        op_conf="${op_home}/.config/ai-tools"
        if [[ -z "${op_home}" || ! -d "${op_conf}" ]]; then
            skip "${op_name} config labelling" "no ${op_conf} on this host"
            continue
        fi
        op_type="$(type_of "${op_conf}")"
        if [[ "${op_type}" == ai_tools_conf_t ]]; then
            pass "${op_name}: ${op_conf} is ai_tools_conf_t"
        else
            fail "${op_name}: ${op_conf} is ${op_type:-none}, not ai_tools_conf_t -- the root helpers cannot read that operator's allowlist, so ownership handback no-ops for every project they own. Fix: sudo ai-tools-admin operators add ${op_name}"
        fi
    done
fi

# The launch attestation reads selinuxfs itself, and the one claim a fixture cannot prove is that the live kernel
# answers: the access query carries ai_tools_t under unconfined_r, which the loaded policy must accept
# (`role unconfined_r types ai_tools_t;` in ai_tools.te), and each gating Boolean file holds the value getsebool prints.
# A policy that stopped accepting the context would turn every launch under AI_TOOLS_REQUIRE_SELINUX into an unattested
# refusal with no unit test failing. Read-only.
section "SELinux: the launch attestation reads the live selinuxfs"

if ! module_loaded; then
    skip "live attestation read" "the ai_tools module is not loaded"
elif ! source /usr/local/lib/ai-tools/conf.lib.sh 2>/dev/null \
        || ! source /usr/local/lib/ai-tools/confinement.lib.sh 2>/dev/null \
        || ! declare -F ai_tools_confinement__read_attestation_records >/dev/null 2>&1; then
    skip "live attestation read" "confinement.lib.sh predates the attestation reader"
else
    live_records="$(ai_tools_confinement__read_attestation_records /sys/fs/selinux)"
    live_permissive="$(awk -F'\t' '$1=="permissive"{print $2}' <<<"${live_records}")"
    # Cross-checked where a tool can say: seinfo lists permissive types; semodule lists the module
    # `semanage permissive -a` installs. Captured, not piped into grep -q, for the SIGPIPE reason module_loaded states.
    expected_permissive=""
    if command -v seinfo >/dev/null 2>&1; then
        permissive_types="$(seinfo --permissive 2>/dev/null || true)"
        if grep -qw ai_tools_t <<<"${permissive_types}"; then expected_permissive=yes; else expected_permissive=no; fi
    elif command -v semodule >/dev/null 2>&1; then
        loaded_modules="$(semodule -l 2>/dev/null || true)"
        if grep -qx permissive_ai_tools_t <<<"${loaded_modules}"; then expected_permissive=yes; else expected_permissive=no; fi
    fi
    if [[ -z "${live_permissive}" ]]; then
        fail "the access query for ai_tools_t went unanswered -- every launch under AI_TOOLS_REQUIRE_SELINUX refuses as unattested"
    elif [[ -z "${expected_permissive}" ]]; then
        pass "the kernel answers the per-domain mode for ai_tools_t: permissive=${live_permissive} (no seinfo or semodule to cross-check)"
    elif [[ "${live_permissive}" == "${expected_permissive}" ]]; then
        pass "the kernel answers the per-domain mode for ai_tools_t: permissive=${live_permissive}, as the policy tools say"
    else
        fail "the per-domain mode reads permissive=${live_permissive}; the policy tools say ${expected_permissive}"
    fi
    while IFS=$'\t' read -r boolean_name boolean_class _; do
        [[ "${boolean_class}" == gating ]] || continue
        live_value="$(awk -F'\t' -v n="${boolean_name}" '$1=="boolean" && $2==n {print $3}' <<<"${live_records}")"
        getsebool_value="$(getsebool "${boolean_name}" 2>/dev/null | awk '{print $3}' || true)"
        if [[ -n "${live_value}" && "${live_value}" == "${getsebool_value}" ]]; then
            pass "${boolean_name} reads ${live_value}, the value getsebool prints"
        else
            fail "${boolean_name}: the reader says '${live_value:-unread}', getsebool says '${getsebool_value:-nothing}'"
        fi
    done < <(ai_tools_confinement__list_known_booleans)
fi

# ── The descriptor-pinned walk ───────────────────────────────────────────────────────────────
# ai-tools-relabel-tree is the recursive relabel of every tree the sandbox account can write (cli.rule.md,
# ref-section-e6c6). tests/unit/relabel-tree.sh drives it over an injected label store; these rows drive it over
# the loaded policy: (W1) each entry takes the type its own rule gives, a symlink as itself, and what a link points
# at outside the tree keeps its type; (W2, W3) the host facts the walker's invariant rests on, the kernel's hardlink
# restriction and the policy's rename and link set; (W4) a walk exits 0 while a process of the sandbox account runs;
# (W5) a revert leaves a hardlinked file at its type and exits 4; (W6) a name carrying an invalid UTF-8 byte takes its
# rule's type; (W7) a path a `<<none>>` rule covers keeps the label it had.
#
# W1, W4, W6 and W7 share one tmpfs fixture under three per-run `semanage fcontext` rules, W5 a fixture of its own under
# two, and teardown deletes each rule. Both sit under /tmp, whose base rule is `<<none>>`, so a type an entry carries
# after a walk is one a per-run rule gave it.
section "SELinux: the descriptor-pinned walk"
readonly WALKER=/usr/local/libexec/ai-tools/ai-tools-relabel-tree
readonly RELABEL_HELPER=/usr/local/libexec/ai-tools/ai-tools-relabel

# type_of <path>: print the type field of <path>'s own context (stat does not follow a symlink), empty when unread.
type_of() {
    local context type
    context="$(stat -c '%C' -- "$1" 2>/dev/null || true)"
    IFS=: read -r _ _ type _ <<<"${context}"
    printf '%s' "${type}"
}
# fcontext_literal <path>: <path> with each regex metacharacter escaped, the encoding ai_tools_relabel__label_project
# writes a project's rule in, so ai-tools-relabel --remove deletes the rule W5 adds.
fcontext_literal() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }
# expect_types <row> <path:type>...: one pass or fail per pair, naming the path and the type it carries.
expect_types() {
    local row="$1" pair path want got
    shift
    for pair in "$@"; do
        path="${pair%:*}"; want="${pair##*:}"
        got="$(type_of "${path}")"
        if [[ "${got}" == "${want}" ]]; then
            pass "${row}: $(printf '%q' "${path##*/}") carries ${want}"
        else
            fail "${row}: $(printf '%q' "${path}") carries '${got:-unread}', not ${want}"
        fi
    done
}

# (W2) The kernel lets an account link only a file it owns or can read and write, so a hardlink the sandbox account
# makes into a tree reaches an inode its own access already covers.
protected_hardlinks="$(cat /proc/sys/fs/protected_hardlinks 2>/dev/null || true)"
if [[ "${protected_hardlinks}" == 1 ]]; then
    pass "W2: fs.protected_hardlinks is 1"
else
    fail "W2: fs.protected_hardlinks reads '${protected_hardlinks:-unread}', not 1 -- the sandbox account can link a file it cannot write into a tree a walk labels"
fi

# (W3) The walker reaches only an inode the account could rename or link into the tree, so the rename and link grants
# to ai_tools_t bound what a walk can write. sesearch reads the loaded policy, the optional groups included, and the row
# holds each (type, class, permission) it lists for those two permissions to a reviewed table: any file class
# of the four types the module declares for the account's own trees, and the base-policy grants in W3_INHERITED, each
# matched on the rule's source and condition as well. Any other tuple fails the row. The classifier first runs
# over synthetic rules, so a table that accepted every rule fails its control before the policy's listing is read.
W3_MODULE_TYPES=" ai_tools_project_t ai_tools_project_build_t ai_tools_home_t ai_tools_tmp_t "
# source|target|class|permission|condition, the condition `<boolean>:<branch>` as sesearch prints it, or `-`.
W3_INHERITED=(
    # auth_use_nsswitch makes ai_tools_t an nsswitch_domain, which the base policy lets manage the Kerberos replay
    # cache.
    'nsswitch_domain|krb5_host_rcache_t|file|link|-'
    'nsswitch_domain|krb5_host_rcache_t|file|rename|-'
    # Under fips_mode the base policy lets every domain manage FIFOs of its own type; a pipe carries that type
    # in pipefs, and avc-denials.sh probes for a named one on a project's filesystem (WLK-001).
    'ai_tools_t|ai_tools_t|fifo_file|link|fips_mode:True'
    'ai_tools_t|ai_tools_t|fifo_file|rename|fips_mode:True'
)
# w3_classify <sesearch-line>: print `module|inherited|unexpected <source> <target>:<class> <permission> <condition>`
#   for each of rename and link the rule grants; a line that does not parse as an allow rule prints `unparsed <line>`.
w3_classify() {
    local line="$1" source target class perms condition perm kind entry
    local rule_pattern='^allow ([^ ]+) ([^ :]+):([^ ]+) (\{ ([^}]*) \}|([^ ;{]+));( \[ (.*) \]:(True|False))?$'
    [[ -n "${line}" ]] || return 0
    if [[ ! "${line}" =~ ${rule_pattern} ]]; then
        printf 'unparsed %s\n' "${line}"
        return 0
    fi
    source="${BASH_REMATCH[1]}"; target="${BASH_REMATCH[2]}"; class="${BASH_REMATCH[3]}"
    perms=" ${BASH_REMATCH[5]:-${BASH_REMATCH[6]}} "
    condition="-"
    [[ -n "${BASH_REMATCH[8]}" ]] && condition="${BASH_REMATCH[8]// /}:${BASH_REMATCH[9]}"
    for perm in link rename; do
        [[ "${perms}" == *" ${perm} "* ]] || continue
        kind=unexpected
        if [[ "${W3_MODULE_TYPES}" == *" ${target} "* ]]; then
            kind=module
        else
            for entry in "${W3_INHERITED[@]}"; do
                [[ "${entry}" == "${source}|${target}|${class}|${perm}|${condition}" ]] && kind=inherited
            done
        fi
        printf '%s %s %s:%s %s %s\n' "${kind}" "${source}" "${target}" "${class}" "${perm}" "${condition}"
    done
}
# w3_classify_all <rules>: w3_classify over each line of <rules>.
w3_classify_all() {
    local rule
    while IFS= read -r rule; do w3_classify "${rule}"; done <<<"$1"
}

w3_control="$(w3_classify_all 'allow ai_tools_t ai_tools_project_t:file { create link rename };
allow nsswitch_domain krb5_host_rcache_t:file { create link open rename write };
allow ai_tools_t ai_tools_t:fifo_file { create link rename }; [ fips_mode ]:True
allow ai_tools_t user_home_t:file { link rename };
allow ai_tools_t ai_tools_t:fifo_file { link }; [ fips_mode ]:False
allow ai_tools_t ai_tools_t:file rename;
allow nsswitch_domain krb5_host_rcache_t:file link; [ kerberos_enabled ]:True')"
w3_control_expected='module ai_tools_t ai_tools_project_t:file link -
module ai_tools_t ai_tools_project_t:file rename -
inherited nsswitch_domain krb5_host_rcache_t:file link -
inherited nsswitch_domain krb5_host_rcache_t:file rename -
inherited ai_tools_t ai_tools_t:fifo_file link fips_mode:True
inherited ai_tools_t ai_tools_t:fifo_file rename fips_mode:True
unexpected ai_tools_t user_home_t:file link -
unexpected ai_tools_t user_home_t:file rename -
unexpected ai_tools_t ai_tools_t:fifo_file link fips_mode:False
unexpected ai_tools_t ai_tools_t:file rename -
unexpected nsswitch_domain krb5_host_rcache_t:file link kerberos_enabled:True'
if [[ "${w3_control}" == "${w3_control_expected}" ]]; then
    pass "W3 control: the classifier reads a type, a class, a branch or a condition outside the table as unexpected"
else
    fail "W3 control: the classifier over synthetic rules: ${w3_control//$'\n'/ | }"
fi

if ! command -v sesearch >/dev/null 2>&1; then
    skip "W3: the policy's rename and link set" "sesearch (setools-console) not installed"
else
    move_status=0
    move_rules="$(sesearch -A -s ai_tools_t -c file,dir,lnk_file,fifo_file,sock_file,chr_file,blk_file -p rename,link 2>&1)" || move_status=$?
    move_tuples="$(w3_classify_all "${move_rules}")"
    move_module="$(grep -c '^module ' <<<"${move_tuples}" || true)"
    if [[ "${move_status}" -ne 0 ]] || ! grep -q '^module ai_tools_t ai_tools_project_t:file ' <<<"${move_tuples}"; then
        fail "W3: sesearch did not list the ai_tools_project_t grant (exit ${move_status}), so its listing was not read: $(head -c 200 <<<"${move_rules}" | tr '\n' '|')"
    else
        pass "W3: ${move_module} rename and link grant(s) on the four types the module declares"
        while read -r _ move_source move_target move_perm move_condition; do
            [[ -n "${move_target}" ]] || continue
            move_state=""
            if [[ "${move_condition}" != - ]]; then
                move_boolean="${move_condition%%:*}" move_branch="${move_condition##*:}"
                move_value="$(getsebool "${move_boolean}" 2>/dev/null | awk '{print $NF}')"
                case "${move_value}:${move_branch}" in
                    on:True|off:False) move_state=", in force (${move_boolean} ${move_value})" ;;
                    on:False|off:True) move_state=", not in force (${move_boolean} ${move_value})" ;;
                    *)                 move_state=", ${move_boolean} unread" ;;
                esac
            fi
            pass "W3: base-policy grant ${move_target} ${move_perm} through ${move_source}${move_state} -- reviewed"
        done < <(grep '^inherited ' <<<"${move_tuples}" || true)
        move_unexpected="$(grep -E '^(unexpected|unparsed) ' <<<"${move_tuples}" || true)"
        if [[ -n "${move_unexpected}" ]]; then
            while IFS= read -r move_line; do
                fail "W3: a rename or link grant outside the reviewed table: ${move_line#* }"
            done <<<"${move_unexpected}"
        else
            pass "W3: no rename or link grant outside the reviewed table"
        fi
    fi
fi

walk_ready=true
for walk_tool in semanage matchpathcon chcon mount umount; do
    if ! command -v "${walk_tool}" >/dev/null 2>&1; then
        skip "the descriptor-pinned walk" "${walk_tool} not installed"; walk_ready=false; break
    fi
done
if ${walk_ready} && [[ ! -x "${WALKER}" || ! -x "${RELABEL_HELPER}" ]]; then
    skip "the descriptor-pinned walk" "${WALKER} or ${RELABEL_HELPER} is not installed"; walk_ready=false
fi

if ${walk_ready}; then
    # The mount point is named, not created by mk_fixture_dir: the path sweep runs ahead of the teardown commands,
    # and an rm over a mounted tmpfs fails on the mount point, so the unmount and the rmdir are teardown commands,
    # registered in the order they run.
    walk_root="/tmp/$(ai_test_name walk)"
    on_teardown umount "${walk_root}"
    on_teardown rmdir "${walk_root}"
    walk_outside=""; mk_fixture_dir walk_outside /tmp walk-outside
    mkdir -m 0755 "${walk_root}"
    mount -t tmpfs -o size=4m,mode=0755 tmpfs "${walk_root}"
    walk_literal="$(fcontext_literal "${walk_root}")"
    on_teardown semanage fcontext -d "${walk_literal}(/.*)?"
    on_teardown semanage fcontext -d "${walk_literal}/sub(/.*)?"
    on_teardown semanage fcontext -d "${walk_literal}/keep(/.*)?"
    semanage fcontext -a -t ai_tools_project_t "${walk_literal}(/.*)?"
    semanage fcontext -a -t ai_tools_project_build_t "${walk_literal}/sub(/.*)?"
    semanage fcontext -a -t '<<none>>' "${walk_literal}/keep(/.*)?"

    walk_bad_name="${walk_root}/bad-"$'\xff'
    mkdir "${walk_root}/dir" "${walk_root}/sub" "${walk_root}/keep" "${walk_outside}/markerdir"
    : > "${walk_root}/file"; : > "${walk_root}/sub/file"; : > "${walk_root}/keep/file"; : > "${walk_bad_name}"
    : > "${walk_outside}/target"; : > "${walk_outside}/markerdir/marker"
    ln -s "${walk_outside}/target" "${walk_root}/link-file"
    ln -s "${walk_outside}/markerdir" "${walk_root}/sub/link-dir"
    chcon -R -h -t user_tmp_t "${walk_root}"
    chcon -t ai_tools_tmp_t "${walk_outside}/markerdir/marker"
    walk_target_type="$(type_of "${walk_outside}/target")"

    # The setup: a tmpfs root, every rule in force, every entry on a type no rule gives, the marker on a third type.
    walk_setup=""
    [[ "$(stat -f -c '%T' "${walk_root}" 2>/dev/null)" == tmpfs ]] || walk_setup+=" the root is not a tmpfs;"
    [[ "$(matchpathcon -n "${walk_root}/file" 2>/dev/null)" == *:ai_tools_project_t:* ]] \
        || walk_setup+=" the tree rule is not in force;"
    [[ "$(matchpathcon -n "${walk_root}/sub/file" 2>/dev/null)" == *:ai_tools_project_build_t:* ]] \
        || walk_setup+=" the subdirectory rule is not in force;"
    [[ "$(matchpathcon -n "${walk_root}/keep/file" 2>/dev/null)" == '<<none>>' ]] \
        || walk_setup+=" the <<none>> rule is not in force;"
    for walk_path in "${walk_root}/file" "${walk_root}/sub/file" "${walk_root}/link-file" "${walk_bad_name}"; do
        [[ "$(type_of "${walk_path}")" == user_tmp_t ]] || walk_setup+=" $(printf '%q' "${walk_path##*/}") is not user_tmp_t;"
    done
    [[ "$(type_of "${walk_outside}/markerdir/marker")" == ai_tools_tmp_t ]] || walk_setup+=" the marker is not ai_tools_tmp_t;"
    if [[ -n "${walk_setup}" ]]; then
        fail "the walk fixture did not take its setup:${walk_setup}"
        walk_ready=false
    else
        pass "the walk fixture: a tmpfs root under three rules, every entry user_tmp_t, the marker ai_tools_tmp_t"
    fi
fi

if ${walk_ready}; then
    walk_rc=0; walk_errors="$("${WALKER}" -- "${walk_root}" 2>&1 >/dev/null)" || walk_rc=$?
    if [[ "${walk_rc}" -eq 0 ]]; then
        pass "W1: the walk over the fixture exits 0"
    else
        fail "W1: the walk over the fixture exited ${walk_rc}: $(head -c 300 <<<"${walk_errors}" | tr '\n' '|')"
    fi
    # A wrong logical path or a wrong mode in the lookup shows on the subdirectory's entries, whose rule differs.
    expect_types W1 "${walk_root}:ai_tools_project_t" "${walk_root}/dir:ai_tools_project_t" \
        "${walk_root}/file:ai_tools_project_t" "${walk_root}/link-file:ai_tools_project_t" \
        "${walk_root}/sub:ai_tools_project_build_t" "${walk_root}/sub/file:ai_tools_project_build_t" \
        "${walk_root}/sub/link-dir:ai_tools_project_build_t"
    expect_types "W1 (outside the tree)" "${walk_outside}/target:${walk_target_type}" \
        "${walk_outside}/markerdir/marker:ai_tools_tmp_t"
    expect_types W6 "${walk_bad_name}:ai_tools_project_t"
    expect_types W7 "${walk_root}/keep/file:user_tmp_t"

    # (W4) The overlap is proved by the order of the FIFOs: the sandbox process writes `started` once it runs and reads
    # `release` before it exits, and the walk runs between the two. Each FIFO open is bounded, so a run that does not
    # start ends the row.
    overlap_dir=""; mk_fixture_dir overlap_dir /tmp walk-overlap
    chmod 0755 "${overlap_dir}"
    mkfifo -m 0666 "${overlap_dir}/started" "${overlap_dir}/release"
    # shellcheck disable=SC2016  # $1 and $2 are the inner bash's arguments
    as_sandbox bash -c 'printf started > "$1"; read -r _ < "$2"' _ "${overlap_dir}/started" "${overlap_dir}/release" &
    overlap_pid=$!
    overlap_word="$(timeout 30 cat "${overlap_dir}/started" 2>/dev/null || true)"
    if [[ "${overlap_word}" != started ]]; then
        fail "W4: the process as the sandbox account did not report it started"
        kill "${overlap_pid}" 2>/dev/null || true
        wait "${overlap_pid}" 2>/dev/null || true
    else
        overlap_state="$(bash -c 'source /usr/local/lib/ai-tools/sessions.lib.sh && ai_tools_sessions__read_live_session_state' 2>/dev/null || true)"
        overlap_rc=0; overlap_errors="$("${WALKER}" -- "${walk_root}" 2>&1 >/dev/null)" || overlap_rc=$?
        # The line ends in a newline: the sandbox side's `read` returns non-zero at an end of input before one.
        # shellcheck disable=SC2016  # $1 is the inner bash's argument
        timeout 30 bash -c 'printf "release\n" > "$1"' _ "${overlap_dir}/release" 2>/dev/null || true
        overlap_sandbox_rc=0; wait "${overlap_pid}" || overlap_sandbox_rc=$?
        if [[ "${overlap_sandbox_rc}" -ne 0 ]]; then
            fail "W4: the process as the sandbox account exited ${overlap_sandbox_rc}, so it may not have run through the walk"
        elif [[ "${overlap_rc}" -eq 0 ]]; then
            pass "W4: the walk exits 0 while a process of the sandbox account runs (the live-session reader read '${overlap_state:-unread}')"
        else
            fail "W4: the walk exited ${overlap_rc} while a process of the sandbox account ran: $(head -c 300 <<<"${overlap_errors}" | tr '\n' '|')"
        fi
    fi

    # (W5) A revert: the tree's rule is dropped and the walk writes the parent's type, which a second per-run rule gives
    # in place of /tmp's <<none>>. The hardlinked file's other name is outside the tree, so the walk leaves the file
    # at its type and the helper exits 4 naming it.
    revert_parent=""; mk_fixture_dir revert_parent /tmp walk-revert
    revert_tree="${revert_parent}/tree"
    revert_parent_literal="$(fcontext_literal "${revert_parent}")"
    revert_tree_literal="$(fcontext_literal "${revert_tree}")"
    on_teardown semanage fcontext -d "${revert_tree_literal}(/.*)?"
    on_teardown semanage fcontext -d "${revert_parent_literal}(/.*)?"
    semanage fcontext -a -t user_tmp_t "${revert_parent_literal}(/.*)?"
    semanage fcontext -a -t ai_tools_project_t "${revert_tree_literal}(/.*)?"
    mkdir -p "${revert_tree}/sub"
    : > "${revert_tree}/file"; : > "${revert_tree}/sub/file"; : > "${revert_tree}/linked"
    ln "${revert_tree}/linked" "${revert_parent}/other-name"
    chcon -R -t ai_tools_project_t "${revert_tree}"
    if [[ "$(stat -c '%h' "${revert_tree}/linked")" != 2 \
            || "$(type_of "${revert_tree}/file")" != ai_tools_project_t \
            || "$(type_of "${revert_tree}/linked")" != ai_tools_project_t \
            || "$(matchpathcon -n "${revert_tree}/file" 2>/dev/null)" != *:ai_tools_project_t:* ]]; then
        fail "W5: the revert fixture did not take its setup (two links on the linked file, the tree ai_tools_project_t under its rule)"
    else
        pass "W5: the revert fixture: a tree ai_tools_project_t under its rule, one file with a second name outside it"
        revert_rc=0; revert_errors="$("${RELABEL_HELPER}" --remove "${revert_tree}" 2>&1 >/dev/null)" || revert_rc=$?
        if [[ "${revert_rc}" -eq 4 ]]; then
            pass "W5: ai-tools-relabel --remove exits 4 over a tree with a hardlinked file"
        else
            fail "W5: ai-tools-relabel --remove exited ${revert_rc}, not 4: $(head -c 300 <<<"${revert_errors}" | tr '\n' '|')"
        fi
        if grep -qF "${revert_tree}/linked" <<<"${revert_errors}"; then
            pass "W5: the revert names the hardlinked file"
        else
            fail "W5: the revert does not name ${revert_tree}/linked: $(head -c 300 <<<"${revert_errors}" | tr '\n' '|')"
        fi
        expect_types W5 "${revert_tree}:user_tmp_t" "${revert_tree}/file:user_tmp_t" \
            "${revert_tree}/sub/file:user_tmp_t" "${revert_tree}/linked:ai_tools_project_t"
    fi
fi

finish
