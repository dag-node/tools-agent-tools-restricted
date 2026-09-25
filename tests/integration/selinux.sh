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
# one inode per agent package carries the domain entry type; and every enrolled operator's config subtree carries
# ai_tools_conf_t, the type the root helpers read that account's allowlist through.
#
# The layer is OPTIONAL -- the policy is its own subpackage, and a host may run DAC-only -- so with the module absent
# the whole file SKIPS instead of demanding SELinux on a host that does not ship it. Run as root.

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
        # pipefail reports as "module absent" -- see the note on ai_tools_selinux_group_loaded (selinux-groups.lib.sh).
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
                && declare -F ai_tools_confinement_module_present >/dev/null 2>&1; then
            if [[ "$(ai_tools_confinement_module_present "${probe_type}")" == yes ]]; then
                pass "ai_tools_confinement_module_present(${probe_type}) -> yes"
            else
                fail "classifier rejected a live core type ${probe_type}"
            fi
        fi
    else
        fail "module loaded but matchpathcon /opt/ai-tools/.config -> ${probe_type:-none} (not ai_tools_*) -- the sandbox-side probe would read module=no and fail OPEN"
    fi
fi

# (5) Sandbox clones must LABEL as ai_tools_project_t. Their on-disk path is under /var/opt/ai-tools/sandbox-projects,
# which the base file_contexts.subs_dist alias `/var/opt /opt` canonicalizes to /opt/... BEFORE file-context matching,
# so the clone rule is authored under /opt (ai_tools.fc). This asserts the rule is REACHABLE through that alias:
# a synthetic clone path resolves to ai_tools_project_t. A rule keyed on the aliased /var/opt prefix resolves to usr_t
# here instead -- the exact regression this catches. matchpathcon reads the loaded policy, so the path need not exist.
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "sandbox clone label" "matchpathcon not available"
else
    sbx_type="$(matchpathcon -n "${SANDBOX_ROOT}/_probe-$$" 2>/dev/null | awk -F: '{print $3}' || true)"
    if [[ "${sbx_type}" == "ai_tools_project_t" ]]; then
        pass "sandbox clone path resolves to ai_tools_project_t (subs_dist /var/opt->/opt alias honoured)"
    else
        fail "sandbox clone path -> ${sbx_type:-none}, not ai_tools_project_t -- the clone fcontext rule is unreachable (authored on the aliased /var/opt prefix instead of /opt?)"
    fi
fi

# (6) The label primitives on a sandbox clone, the branch that does not mutate policy. relabel.lib.sh splits
# on _ai_tools_is_sandbox: a clone is covered by the STATIC ai_tools.fc rule, so the helper does not add a per-path
# `semanage fcontext` entry and has none to remove. ai_tools_label_project still verifies the achieved label rather than
# trusting restorecon's exit status, so a mislabel is a hard failure -- the regression that let a usr_t clone report
# success. After an unlabel a clone is still labelled, which is what keeps it reachable by the confined agent: the way
# to un-label a clone is to delete it (ai-tools.projects.remove.clone).
#
# The other branch -- a claimed project, where the helper adds and then removes a per-path fcontext rule -- is
# deliberately NOT exercised. Driving it would mutate the host's local SELinux policy to test a helper, which no test
# here does, and a teardown that can leave a policy entry behind is worse than the coverage it buys. That leaves
# ai_tools_unlabel_project's revert path (the one ai-tools.projects.unclaim drives) uncovered: a known gap, recorded
# rather than papered over.
RELABEL_LIB=/usr/local/lib/ai-tools/relabel.lib.sh
if [[ ! -d "${SANDBOX_ROOT}" ]]; then
    skip "sandbox clone label" "sandbox area ${SANDBOX_ROOT} not present"
elif [[ ! -r "${RELABEL_LIB}" ]] || ! source "${RELABEL_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_label_project >/dev/null 2>&1; then
    skip "sandbox clone label" "relabel.lib.sh not available at ${RELABEL_LIB}"
else
    # A real clone-area path, since the static rule is keyed on that prefix; named and registered through the harness
    # so the sweep finds what an aborted run leaves.
    sprobe=""; mk_fixture_dir sprobe "${SANDBOX_ROOT}" relabel
    if ai_tools_label_project "${sprobe}" && ai_tools_project_labelled "${sprobe}"; then
        pass "ai_tools_label_project applies AND verifies ai_tools_project_t on a sandbox clone"
    else
        fail "sandbox clone ${sprobe} is not ai_tools_project_t ($(ls -Zd "${sprobe}" 2>/dev/null))"
    fi
    ai_tools_unlabel_project "${sprobe}" >/dev/null 2>&1 || true
    if ai_tools_project_labelled "${sprobe}"; then
        pass "an unlabel leaves a sandbox clone labelled (the static rule is authoritative)"
    else
        fail "unlabel stripped ai_tools_project_t from a sandbox clone -- the agent loses access to every clone"
    fi
    rmdir "${sprobe}" 2>/dev/null || true
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

if ! declare -F ai_tools_entrypoint_reconcile_verdict >/dev/null 2>&1 \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    skip "entrypoint declaration reconciliation" "relabel.lib.sh/providers.lib.sh not loaded"
else
    agents_seen=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        agents_seen=$(( agents_seen + 1 ))
        installed="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
        if [[ -z "${installed}" ]]; then
            skip "${agent} entrypoint declaration" "its launcher does not resolve (not provisioned)"
            continue
        fi
        pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
        covered=no matched=no
        while IFS= read -r p; do
            matched=yes
            [[ "${p}" == "${installed}" ]] && covered=yes
        done < <(_ai_tools_entrypoint_paths "${pattern}")
        case "$(ai_tools_entrypoint_reconcile_verdict "${installed}" "${covered}" "${matched}")" in
            ok) pass "${agent}: its declared entrypoint rule covers ${installed}" ;;
            *)  fail "${agent}: installed at ${installed}, which its declared entrypoint_fcontext does not cover -- every launch will fail closed; the manifest is stale" ;;
        esac
    done < <(ai_tools_enabled_agents 2>/dev/null)
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

# (8) The build-output type, where the dotnet layout module is loaded. Its static rule must win over the clone rule
# for a path under one of the named directories and lose everywhere else -- the precedence the narrowing rests
# on, decided by libselinux from the two rules' stems, which no unit test can read. matchpathcon reads the loaded file
# contexts, so the paths need not exist; the live half creates a bin/ directory as unconfined_t in the sandbox area
# and asserts the module's named transition put it on the build type without a restorecon. The ai_tools_t transition
# and the execute grant need a session and are exercised by selinux/avc/avc-testsuite.sh. Skips when the layout module
# is not loaded: the base carries the type, the module the mapping.
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
            pass "a bin/ directory created by unconfined_t is born ai_tools_project_build_t; a sibling stays ai_tools_project_t (named transition, no restorecon)"
        else
            fail "created bin/ is ${bt:-none} and src/ is ${st:-none} -- the layout module's unconfined_t transition did not fire"
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

if ! declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    skip "exec chain type containment" "providers.lib.sh not loaded"
else
    chain_seen=0
    while IFS=$'\t' read -r agent _ launcher; do
        [[ -n "${agent}" && -n "${launcher}" ]] || continue
        entry="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
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
    done < <(ai_tools_enabled_agents 2>/dev/null)
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

if ! declare -F ai_tools_enabled_agents >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_manifest_field >/dev/null 2>&1; then
    skip "package entry-type enumeration" "providers.lib.sh not loaded"
else
    pkg_seen=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        entry="$(ai_tools_agent_entrypoint_path "${agent}" || true)"
        pkg="$(ai_tools_agent_manifest_field "${agent}" npm_package || true)"
        [[ -n "${entry}" && -n "${pkg}" ]] || continue
        # The package root is the path up to the FIRST /lib/node_modules/<npm_package>/, which is where npm installs it;
        # an entrypoint nested under a platform-specific dependency (codex) sits further down the same prefix.
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
        # A name-wise breakdown beside the inode-wise verdict: the entrypoint's hardlinked names count twice here and once
        # there, so the two agree on a healthy package.
        by_type="$(printf '%s' "${types}" | sort | uniq -c | awk '{printf "%s%s(%s)", (NR > 1 ? " " : ""), $2, $1}')"
        note "${agent}: $(printf '%s' "${types}" | grep -c '^.' || true) executable file(s) under ${pkg}, by type: ${by_type}" \
            "counted by name; the check above counts inodes, so hardlinked names of the entrypoint count once there"
    done < <(ai_tools_enabled_agents 2>/dev/null)
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
# for ai_tools_unlabel_project. What repairs a failure is `ai-tools-admin operators add <user>`, which registers
# the rule per account, or a full `install-selinux.sh relabel`, which sweeps the list.
section "SELinux: every enrolled operator's config subtree is ai_tools_conf_t"

if ! declare -F ai_tools_load_operators >/dev/null 2>&1 \
        && ! source /usr/local/lib/ai-tools/operator.lib.sh 2>/dev/null; then
    skip "operator config labelling" "operator.lib.sh not readable -- cannot resolve the operator list"
elif ! ai_tools_load_operators; then
    skip "operator config labelling" "no operator is enrolled in operator.conf"
else
    for op_name in "${AI_TOOLS_OPERATORS[@]}"; do
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

finish
