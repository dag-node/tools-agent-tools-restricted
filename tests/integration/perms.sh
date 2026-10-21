#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/perms.sh
# Integration: the single source of truth for deployed-artifact ownership/permissions, plus sudoers syntax. Every
# installed file and directory is one row of the layout table (layout.lib.sh), and the first section is that table's
# loop: each row the installed library lists for the packages on this host is read, and a finding on it -- the owner,
# the mode, the ACL, the SELinux type, the content of a package file -- fails here, so the rows' comments are
# the library's and adding or repermissioning an installed file edits that one table. What is not a row follows:
# the staged policy module set, the codex skills link, and each agent's links into the shared asset roots. Needs
# a completed install; run as root via sudo, or via `sudo ./install.sh check-perms`.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "File permissions"
# The loop over the installed layout. A row at its row passes with its owner and mode; a ghost or optional row that is
# absent skips, since the absence is permitted; every finding fails naming the field, the declared and the read value;
# and an input the enumeration could not read, or an enumeration that ended on a status its lines do not account
# for, fails naming it, so an untrusted agents directory or operator.conf does not read as a host with fewer rows.
# The library is the installed one: this suite asserts what the install deployed. The arrays it writes carry this file's
# prefix: its output-name check refuses one in its own `_layout_` prefix, since a nameref landing on one of its locals
# would report a read that reached no caller.
perms_layout_lib=/usr/local/lib/ai-tools/layout.lib.sh
# shellcheck source=/dev/null
if ! source "${perms_layout_lib}" 2>/dev/null || ! declare -F ai_tools_layout__read_entry_lines >/dev/null 2>&1; then
    fail "${perms_layout_lib} did not load, so the installed layout is not asserted -- reinstall ai-tools-base"
elif [[ -n "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]]; then
    fail "the layout table did not validate: ${AI_TOOLS_LAYOUT__DECLARATION_ERROR}"
else
    ai_tools_layout__begin_pass 0
    declare -a perms_lines=() perms_fields=() perms_findings=() perms_finding=()
    declare -A perms_state=()
    perms_rows=0
    ai_tools_layout__read_entry_lines perms_lines || :
    for perms_line in "${perms_lines[@]}"; do
        if [[ "${perms_line}" == error$'\t'* ]]; then
            ai_tools_layout__parse_line "${perms_line}" perms_fields \
                || perms_fields=( error host layout.lib.sh entries "a line of the entry set did not decode" )
            fail "layout: ${perms_fields[2]:-?} (${perms_fields[3]:-?}): ${perms_fields[4]:-}"
            continue
        fi
        perms_state=(); perms_findings=(); perms_status=0
        ai_tools_layout__read_entry_state "${perms_line}" perms_state perms_findings || perms_status=$?
        if (( perms_status != 0 )); then
            # The reader refuses an output name or a row that does not decode, which is this file's call
            # or the library's own line, not one row's state: reported once, and the rows after it are not read.
            ai_tools_layout__parse_line "${perms_line}" perms_fields || perms_fields=()
            fail "layout: the reader returned ${perms_status} on the row ${perms_fields[0]:-?}; the rows after it are not read"
            break
        fi
        perms_rows=$(( perms_rows + 1 ))
        perms_label="${perms_state[operator]:+${perms_state[operator]}: }${perms_state[path]}"
        if (( ${#perms_findings[@]} == 0 )); then
            if [[ "${perms_state[type]:-}" == absent ]]; then
                skip "${perms_label}" "${perms_state[absent_detail]:-absent until created on demand}"
            else
                pass "${perms_label}  (${perms_state[expected_owner]} ${perms_state[expected_mode]})"
            fi
            continue
        fi
        perms_detail=""
        for perms_finding_line in "${perms_findings[@]}"; do
            ai_tools_layout__parse_line "${perms_finding_line}" perms_finding || perms_finding=( error )
            perms_expected="${perms_finding[2]:-}"; perms_observed="${perms_finding[3]:-?}"
            perms_detail+="${perms_detail:+; }${perms_finding[0]}"
            [[ -z "${perms_finding[1]:-}" ]] || perms_detail+=" ${perms_finding[1]}"
            [[ -z "${perms_expected}" || "${perms_expected}" == - ]] \
                || perms_detail+=": declared ${perms_expected//$'\n'/,}, read ${perms_observed//$'\n'/,}"
            [[ -z "${perms_finding[4]:-}" ]] || perms_detail+=" (${perms_finding[4]})"
        done
        fail "${perms_label}: ${perms_detail}"
    done
    if (( perms_rows > 100 )); then
        pass "the installed layout was read row by row (${perms_rows} rows)"
    else
        fail "the installed layout listed ${perms_rows} rows"
    fi
fi

# The compiled policy modules ai-tools-admin loads a stable group from: 644 root:root in a 755 root:root directory,
# and the SET is asserted with the modes -- exactly the modules selinux/policy/shipped-modules.sh derives
# from the registry and the integration manifests, which is the list the RPM build and install.sh compile. A module
# missing from it is a stable group with no module for `selinux groups enable` to load; one beyond it was not built
# by this release. The directory exists only where the SELinux layer was staged (the RPM ships it everywhere; a source
# install stages it on a host with SELinux active), so its absence is a skip, not a failure. The directory
# and the interface file beside the modules are rows of the table; the module set is not.
_pkg_dir=/usr/share/selinux/packages/ai-tools
_shipped="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/selinux/policy/shipped-modules.sh"
if [[ -d "${_pkg_dir}" ]]; then
    if [[ -f "${_shipped}" ]] && _want="$(bash "${_shipped}" | sort)" && [[ -n "${_want}" ]]; then
        _have="$(find "${_pkg_dir}" -maxdepth 1 -name '*.pp' -printf '%f\n' | sed 's/\.pp$//' | sort)"
        if [[ "${_have}" == "${_want}" ]]; then
            pass "staged policy modules match the derived shipped set: $(tr '\n' ' ' <<<"${_want}")"
        else
            fail "staged policy modules differ from the shipped set (have: $(tr '\n' ' ' <<<"${_have}"); want: $(tr '\n' ' ' <<<"${_want}"))"
        fi
        while IFS= read -r _mod; do
            check_file "${_pkg_dir}/${_mod}.pp" root root 644
        done <<<"${_want}"
    else
        skip "staged policy module set" "shipped-modules.sh not in a checkout beside this suite"
    fi
else
    skip "staged policy modules" "${_pkg_dir} absent (SELinux layer not staged on this host)"
fi

# The shared skills reach codex through its admin scope, /etc/codex/skills. The package places a symlink to the shared
# root when the path is free, and keeps what a host already holds there (a directory of its own, a link elsewhere)
# with the shared assets linked inside a host directory one per free name -- so the kept shapes read as the coexistence
# they are, and only an absent path fails: the shared skills then do not reach codex.
if [[ -L /etc/codex/skills && "$(readlink /etc/codex/skills)" == /opt/ai-tools/skills ]]; then
    pass "/etc/codex/skills is the symlink to the shared root /opt/ai-tools/skills"
elif [[ -L /etc/codex/skills ]]; then
    skip "/etc/codex/skills" "a link the host placed elsewhere is kept ($(readlink /etc/codex/skills))"
elif [[ -d /etc/codex/skills ]]; then
    _codex_link=""
    for _link in /etc/codex/skills/ai-tools-*; do
        [[ -L "${_link}" && "$(readlink "${_link}")" == /opt/ai-tools/skills/* ]] && { _codex_link="${_link}"; break; }
    done
    if [[ -n "${_codex_link}" ]]; then
        pass "/etc/codex/skills is the host's own directory, kept, with the shared assets linked inside it (${_codex_link##*/})"
    elif [[ -z "$(find /opt/ai-tools/skills -mindepth 1 -maxdepth 1 -name 'ai-tools-*' -print -quit 2>/dev/null)" ]]; then
        skip "/etc/codex/skills" "the host's own directory, kept; the view holds no ai-tools-* skill to link inside it"
    else
        fail "/etc/codex/skills is the host's own directory and the shared assets are not linked inside it -- re-run the install"
    fi
else
    fail "/etc/codex/skills: MISSING -- codex finds no shared skill"
fi

# Each agent's asset directories carry SYMLINKS into the shared roots, not copies -- that is what keeps an asset
# authored in one place. The set of agents comes from the manifests (control-plane.lib.sh), so a second agent is covered
# here without editing this file; a host with none skips and says so.
_cp_lib=/usr/local/lib/ai-tools/control-plane.lib.sh
# shellcheck source=/dev/null
if source "${_cp_lib}" 2>/dev/null && declare -F ai_tools_control_plane__list_agent_asset_dirs >/dev/null 2>&1; then
    # Per kind, the first ai-tools-* link resolving into the view is the evidence, and any ai-tools-managed copy beside
    # it is a regression to per-agent copies (silently forking the content), which fails. Which assets a host links is
    # its AI_TOOLS_ASSETS, so a kind without one skips with the reason. The pairs are <manifest field>:<shared root>.
    for _spec in "skills_dir:/opt/ai-tools/skills" "subagents_dir:/opt/ai-tools/subagents"; do
        _field="${_spec%%:*}"; _root="${_spec#*:}"
        while IFS=$'\t' read -r _agent _dir; do
            [[ -d "${_dir}" ]] || { skip "${_dir}" "not deployed on this host"; continue; }
            _linked=""; _forked=""
            for _link in "${_dir}"/ai-tools-*; do
                [[ -e "${_link}" || -L "${_link}" ]] || continue
                if [[ -L "${_link}" ]]; then
                    [[ -z "${_linked}" && "$(readlink "${_link}")" == "${_root}"/* ]] && _linked="${_link}"
                    continue
                fi
                _marker="${_link}"; [[ -d "${_link}" ]] && _marker="${_link}/SKILL.md"
                # A real entry that is NOT ai-tools-managed is the operator's own override, which the linker is
                # contracted to leave alone -- the feature, not a regression.
                if grep -qE '^x-ai-tools-managed:[[:space:]]*true' "${_marker}" 2>/dev/null; then
                    _forked="${_link}"; break
                fi
            done
            if [[ -n "${_forked}" ]]; then
                fail "${_forked} is a managed COPY, not a symlink into ${_root} -- the shared asset forks per agent. An identical copy is converted on the next install/bootstrap; one that differs is kept, so reconcile or remove it"
            elif [[ -n "${_linked}" ]]; then
                pass "${_linked} is a symlink into ${_root}"
            else
                skip "${_dir}" "no ai-tools-* asset of this kind is linked on this host (AI_TOOLS_ASSETS decides which)"
            fi
        done < <(ai_tools_control_plane__list_agent_asset_dirs "${_field}")
    done
    # The orientation text arrives the same way, but at a name the manifest supplies rather than the asset's own --
    # and at the one path each agent reads as user-scope instructions. A COPY here is the same fork the asset kinds
    # guard against; a real file that is not ours is an operator's own instructions, which the linker is contracted
    # to keep.
    if declare -F ai_tools_control_plane__list_agent_memory_targets >/dev/null 2>&1; then
        _memory_found=0
        check_memory_link() {
            local _memory="$1"
            if [[ ! -e "${_memory}" ]]; then
                skip "${_memory}" "shipped orientation not linked on this host"
            elif [[ -L "${_memory}" && "$(readlink "${_memory}")" == /opt/ai-tools/orientation/* ]]; then
                pass "${_memory} is a symlink into /opt/ai-tools/orientation"
            elif ! grep -qE '^x-ai-tools-managed:[[:space:]]*true' "${_memory}" 2>/dev/null; then
                skip "${_memory}" "an operator's own instructions sit here (not ai-tools-managed)"
            else
                fail "${_memory} is a managed COPY, not a symlink into /opt/ai-tools/orientation -- the orientation text forks per agent"
            fi
        }
        _codex_memory_walked=0
        while IFS=$'\t' read -r _agent _memory; do
            _memory_found=1
            [[ "${_memory}" == /opt/ai-tools/.codex/AGENTS.md ]] && _codex_memory_walked=1
            check_memory_link "${_memory}"
        done < <(ai_tools_control_plane__list_agent_memory_targets)
        (( _memory_found )) || skip "agent orientation link" "no enabled agent declares a memory_file"
        # Codex's link, by name while the agent is disabled (the walk covers enabled agents): its manifest names
        # AGENTS.md at the root of its config directory, the global scope codex reads first.
        (( _codex_memory_walked )) || check_memory_link /opt/ai-tools/.codex/AGENTS.md
    else
        fail "${_cp_lib} does not resolve the agents' memory targets"
    fi
else
    skip "agent asset links" "${_cp_lib} does not resolve the agents' asset directories"
fi

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools parses OK"
else
    fail "/etc/sudoers.d/ai-tools has syntax errors"
fi

# env_keep surface: ai-tools-run re-validates AI_TOOLS_AGENT_EXEC/AI_TOOLS_PROJECT_DIR (ai-tools-run.sh test), which is
# the real defense, but the drop-in's per-command env_keep should pass through ONLY those two -- a widened list would
# smuggle attacker-influenced env into the launch path. Pin it: every env_keep in the file names exactly
# AI_TOOLS_AGENT_EXEC and AI_TOOLS_PROJECT_DIR, and no other name.
if [[ -r /etc/sudoers.d/ai-tools ]]; then
    ek_extra="$(grep -oE 'env_keep[[:space:]]*\+?=[[:space:]]*"[^"]*"' /etc/sudoers.d/ai-tools \
        | grep -oE '"[^"]*"' | tr -d '"' | tr ' ' '\n' \
        | grep -vE '^[[:space:]]*$' | grep -vxE 'AI_TOOLS_AGENT_EXEC|AI_TOOLS_PROJECT_DIR' || true)"
    if [[ -z "${ek_extra}" ]]; then
        pass "sudoers env_keep passes only AI_TOOLS_AGENT_EXEC + AI_TOOLS_PROJECT_DIR"
    else
        fail "sudoers env_keep names unexpected variable(s): ${ek_extra//$'\n'/ } -- widened launch env surface"
    fi

    # The root rule must be pinned to its helper's ZERO-ARGUMENT form. The trailing "" is what keeps it a grant to run
    # one program one way: sudoers(5) reads a command listed with no arguments at all as permitting ANY, so a dropped ""
    # silently turns a narrow root rule into `--force` without a password. tests/unit/helper-path.sh pins the same line
    # in the SOURCE; this asserts what the install actually deployed.
    if grep -qE "^%ai-ops[[:space:]]+.*NOPASSWD:[[:space:]]*/usr/local/libexec/ai-tools/ai-tools-stop[[:space:]]+\"\"[[:space:]]*$" \
            /etc/sudoers.d/ai-tools; then
        pass "sudoers grants ai-tools-stop in its zero-argument form only"
    else
        fail "sudoers rule for ai-tools-stop is missing or not pinned to the zero-argument form"
    fi

    # And the drop-in holds the session lifecycle ALONE. The entrypoint relabel is an ai-tools-admin command reached
    # through the host's own general sudo grant, so a %ai-ops rule naming its helper would hand every operator
    # a passwordless root command the model no longer accounts for.
    if grep -qE "^%ai-ops.*ai-tools-relabel-agent" /etc/sudoers.d/ai-tools; then
        fail "sudoers grants %ai-ops a rule for ai-tools-relabel-agent -- the drop-in holds the session lifecycle only"
    else
        pass "sudoers grants %ai-ops no rule for ai-tools-relabel-agent"
    fi
fi

finish
