#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-selinux-walks.sh
# Hermetic check of selinux/install-selinux.sh's walks over the trees the sandbox account can write: each runs
# through the library's descriptor-pinned tree walk (ai_tools_relabel__relabel_tree) whatever a session of that account
# is doing (cli.rule.md, ref-section-e6c6), and a walk that did not label every entry is reported without stopping
# the run.
#
# The script loads policy and needs root and a whole host, so the functions are read out of the checkout as text
# (extract_function) and run in a fresh bash per walk status, with the tree walk and restorecon stubbed as recorders
# and the live-session reader stubbed to read `live` and record each call. _restore_home_state_labels names
# /opt/ai-tools in its body, which the case rewrites to a fixture root, so no host path is read. The walks run
# over fixture lists, so the script's own HOME_STATE and SHARED_TREES are held to the names under /opt/ai-tools
# the policy's .fc files type, in both directions, beside a control list missing one name. The script's text is then
# read for the properties a function cannot show: the installed sandbox-exec.lib.sh is sourced ahead of the relabel
# library, every restorecon names a root-owned tree or one file in the root-owned home, held against a control line
# the reader must flag, and the remove action reads the live-session state ahead of its first policy-store write. Each
# label arm walks the shared asset trees, the remove arm walks the control plane whole and the clone area, and remove
# reverts the root-owned trees with one restorecon each after the unload, a failed one warned and closing the action
# non-zero. verify_agent_labels is driven over stubbed library lines for an agent closed as failed, which fails
# the install, and a config directory walk that left hardlinked files; _label_project and _unlabel_project
# over the library's partial-walk and walker-missing statuses, and _unlabel_project over its absent-tree status.
# for_each_project is driven through the checkout's conf.lib.sh over a registry holding each sign, and does not yield
# an excluded path. _check_permissive_alignment is driven with the checkout's selinux-groups.lib.sh over a semodule stub
# printing module names alone, and the script's text is held to capturing that listing in _read_loaded_policy_modules
# alone, since the list-groups arm is not a function a case can run.
#
# Unprivileged, and reads the checkout alone; skips outside one.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly INSTALLER="${ROOT}/selinux/install-selinux.sh"
section "install-selinux.sh: the account-writable walks run through the tree walker (unit)"

if [[ ! -r "${INSTALLER}" ]]; then
    skip "install-selinux.sh walks" "not a source checkout (no ${INSTALLER})"
    finish; exit
fi
mktestdir

functions_text=""
for name in warn _resolve_walk_root _restore_account_tree_labels _revert_account_tree_labels _warn_walk_incomplete _report_skipped_walk_entries \
        _warn_walker_unavailable _restore_home_state_labels _restore_shared_tree_labels _revert_root_tree_labels \
        _warn_root_tree_left _label_sandbox_clones; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    functions_text+="${body}"$'\n'
done
functions_text="${functions_text//\/opt\/ai-tools\//${TESTDIR}/home/}"

mkdir -p "${TESTDIR}/home/.npm" "${TESTDIR}/nvm" "${TESTDIR}/clones/acme-clone" "${TESTDIR}/home/skills" \
    "${TESTDIR}/home/integrations"
: > "${TESTDIR}/home/.gitconfig"

# run_walks <status>: run the walks with the tree walk returning <status> and setting a diagnostic naming its tree.
#   The recorder holds each walk and each restorecon, one per line; verified holds each clone the verify loop read,
#   and readings each call of the live-session reader. stderr is the warnings and the log lines, closed by END
#   when the run reached its last walk.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_walks() {
    : > "${TESTDIR}/recorder"; : > "${TESTDIR}/verified"; : > "${TESTDIR}/readings"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN=""
        stub_testdir="$2" walk_status="$3"
        ai_tools_relabel__relabel_tree() {
            printf "walk %s\n" "$1" >> "${stub_testdir}/recorder"
            AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="walker line for $1"
            return "${walk_status}"
        }
        restorecon() { printf "restorecon %s\n" "$*" >> "${stub_testdir}/recorder"; }
        ai_tools_sessions__read_live_session_state() { printf "read\n" >> "${stub_testdir}/readings"; printf "live\n"; }
        ok() { :; }; log() { printf "LOG %s\n" "$*" >&2; }
        ai_tools_relabel__is_available() { return 0; }
        ai_tools_relabel__is_project_labelled() { printf "%s\n" "$1" >> "${stub_testdir}/verified"; }
        HOME_STATE=(.npm .gitconfig .absent)
        SHARED_TREES=(skills integrations .absent-shared)
        SANDBOX_PROJECTS="$2/clones"
        _restore_home_state_labels
        _restore_shared_tree_labels
        _label_sandbox_clones
        _restore_account_tree_labels "$2/nvm"
        echo END >&2
    ' _ "${functions_text}" "${TESTDIR}" "$1" 2>"${TESTDIR}/warnings" || true
}

walked_trees=("${TESTDIR}/home/.npm" "${TESTDIR}/home/skills" "${TESTDIR}/home/integrations" "${TESTDIR}/clones"
    "${TESTDIR}/nvm")

# Status 0 first: it is the control that the recorder records each walk, so the statuses after it are read against a run
# whose walks are known to happen.
run_walks 0
recorded="$(<"${TESTDIR}/recorder")"
missing=""
for tree in "${walked_trees[@]}"; do
    grep -qxF -- "walk ${tree}" <<<"${recorded}" || missing+=" ${tree}"
done
[[ -z "${missing}" ]] && pass "each account-writable tree goes through the tree walk (the recorder control for the cases after it)" \
    || fail "not walked:${missing} (recorded: ${recorded//$'\n'/ | })"
if grep -qxF -- "restorecon -F ${TESTDIR}/home/.gitconfig" <<<"${recorded}" \
        && ! grep -qF -- "walk ${TESTDIR}/home/.gitconfig" <<<"${recorded}"; then
    pass "a file in the home takes one restorecon -F, not the walk"
else
    fail "the home's file was not restored as one path: ${recorded//$'\n'/ | }"
fi
if [[ -n "$(grep -E '^restorecon ' <<<"${recorded}" | grep -vxF -- "restorecon -F ${TESTDIR}/home/.gitconfig")" ]]; then
    fail "a tree was restored by restorecon: $(grep '^restorecon ' <<<"${recorded}" | tr '\n' ';')"
else
    pass "no account-writable tree is restored by restorecon"
fi
grep -qF -- "${TESTDIR}/home/.absent" <<<"${recorded}" && fail "a path that does not exist was walked" \
    || pass "a path that does not exist is not walked"
[[ -s "${TESTDIR}/readings" ]] && fail "a walk read the live-session state ($(wc -l <"${TESTDIR}/readings") call(s))" \
    || pass "no walk reads the live-session state, which the stub reads as live"
grep -qxF "${TESTDIR}/clones/acme-clone" "${TESTDIR}/verified" \
    && pass "the clone verify loop reads each clone" \
    || fail "the clone verify loop did not run"
warnings="$(<"${TESTDIR}/warnings")"
grep -q '^MSG-' <<<"${warnings}" && fail "status 0: a warning was printed: ${warnings//$'\n'/ | }" \
    || pass "status 0: no warning is printed"

run_walks 4
warnings="$(<"${TESTDIR}/warnings")"
if grep -qxF "LOG   the walk over ${TESTDIR}/nvm left these entries at their type: walker line for ${TESTDIR}/nvm" \
        <<<"${warnings}" && ! grep -q '^MSG-' <<<"${warnings}"; then
    pass "status 4: the walk's hardlinked entries are a note naming the tree, not a warning"
else
    fail "status 4 printed: ${warnings//$'\n'/ | }"
fi

for status in 6 1; do
    run_walks "${status}"
    warnings="$(<"${TESTDIR}/warnings")"
    case "${status}" in
        6) assert_msg MSG-G6X4 "${warnings}" "status 6: a walker that could not run is warned under its code" ;;
        1) assert_msg MSG-D6B7 "${warnings}" "status 1: a walk that could not label an entry is warned under its code" ;;
    esac
    grep -qF "walker line for ${TESTDIR}/nvm" <<<"${warnings}" \
        && pass "status ${status}: the warning carries the walker's line" \
        || fail "status ${status}: the warning does not carry the walker's line: ${warnings//$'\n'/ | }"
    recorded="$(<"${TESTDIR}/recorder")"
    if grep -qxF END <<<"${warnings}" && [[ "$(grep -c '^walk ' <<<"${recorded}")" -eq "${#walked_trees[@]}" ]]; then
        pass "status ${status}: the warning does not stop the run, and every tree is still walked"
    else
        fail "status ${status}: the run stopped or skipped a walk: ${recorded//$'\n'/ | }"
    fi
done

# ── The walked names are the policy's ────────────────────────────────────────────────────────
# The walks above run over fixture lists. What a host walks is the script's own HOME_STATE and SHARED_TREES, so those
# declarations are held to the names under /opt/ai-tools that the policy's .fc files type, in both directions; the clone
# area is walked through SANDBOX_PROJECTS and is left out. The comparison is first run over the policy with one name
# taken off the list, as the control that it reports a name the walks would miss.
fc_names="$(cat "${ROOT}"/selinux/policy/*.fc | sed -nE 's#^/opt/ai-tools/([^/([:space:]]+).*#\1#p' | sed 's#\\\.#.#g' \
    | grep -vxF sandbox-projects | sort -u)"
declared_text="$(grep -E '^(HOME_STATE|SHARED_TREES)=\(' "${INSTALLER}" || true)"
declared_names="$(bash -c 'eval "$1"; printf "%s\n" "${HOME_STATE[@]}" "${SHARED_TREES[@]}"' _ "${declared_text}" | sort -u)"
# compare_walked_names <declared>: print each name the policy types and <declared> lacks as `missing <name>`,
#   and each name <declared> holds and the policy does not type as `untyped <name>`.
compare_walked_names() {
    comm -23 <(printf '%s\n' "${fc_names}") <(printf '%s\n' "$1") | sed 's/^/missing /'
    comm -13 <(printf '%s\n' "${fc_names}") <(printf '%s\n' "$1") | sed 's/^/untyped /'
}
if grep -qxF skills <<<"${fc_names}" && [[ "$(compare_walked_names "$(grep -vxF subagents <<<"${fc_names}")")" == "missing subagents" ]]; then
    pass "the policy's names under /opt/ai-tools are read, and a list without one of them is reported (the control)"
else
    fail "the .fc reader or the comparison does not report a missing name: read '${fc_names//$'\n'/ }'"
fi
walked_diff="$(compare_walked_names "${declared_names}")"
if [[ "$(grep -c '' <<<"${declared_text}")" -eq 2 && -z "${walked_diff}" ]]; then
    pass "HOME_STATE and SHARED_TREES name each tree the policy types under /opt/ai-tools, and no other"
else
    fail "the walked names and the policy's disagree: ${walked_diff//$'\n'/; } (declared: ${declared_names//$'\n'/ })"
fi

# ── verify_agent_labels ───────────────────────────────────────────────────────────────────────
# The renderer reads the relabel library's lines, stubbed here to print them, with the manifest reader stubbed to name
# the config directory.
agent_text=""
for name in warn verify_agent_labels; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    agent_text+="${body}"$'\n'
done

# ── verify_agent_labels: a failed agent and a walk that left hardlinked files ─────────────────
# An agent the library closes as `failed` fails the install, as a `bad` path does; a `partial` line, a config directory
# whose walk left hardlinked files, is named under its own code and does not fail it.
section "install-selinux.sh: a failed agent fails the install and a partial walk is named (unit)"
# verdict_run <lines> : verify_agent_labels over the stubbed library <lines>; prints both streams of the run.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
verdict_run() {
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN=""
        ok() { :; }; log() { :; }
        die() { printf "DIED %s\n" "$*" >&2; exit 1; }
        stub_lines="$3"
        ai_tools_relabel__label_agent_paths() { printf "%s\n" "${stub_lines}"; }
        ai_tools_providers__read_agent_manifest_field() { [[ "$2" == config_dir ]] && printf ".acme\n"; }
        CP_HOME="$2"
        SANDBOX_EXEC_LIB=/usr/local/lib/ai-tools/sandbox-exec.lib.sh
        verify_agent_labels
    ' _ "${agent_text}" "${TESTDIR}/home" "$1" 2>&1 || true
}
verdict_out="$(verdict_run $'ok /x/.acme\nagent acme ok')"
if grep -q '^DIED' <<<"${verdict_out}"; then
    fail "control: an agent closed ok fails the install: ${verdict_out//$'\n'/ | }"
else
    pass "control: an agent closed ok does not fail the install"
fi
verdict_out="$(verdict_run $'skip acme could not register its config-directory file-context rule -- held\nagent acme failed')"
assert_msg MSG-E6C4 "${verdict_out}" "an agent closed failed is named"
if grep -q '^DIED' <<<"${verdict_out}"; then
    pass "an agent closed failed fails the install"
else
    fail "an agent closed failed does not fail the install: ${verdict_out//$'\n'/ | }"
fi
verdict_out="$(verdict_run $'ok /x/.acme\npartial acme 2\nagent acme ok')"
assert_msg MSG-A5V5 "${verdict_out}" "a config directory walk that left hardlinked files is named"
if grep -qF "left 2 hardlinked path(s) at their current type" <<<"${verdict_out}" \
        && grep -qF "find ${TESTDIR}/home/.acme -not -type d -links +1" <<<"${verdict_out}"; then
    pass "the partial walk names its count and the find that lists the files"
else
    fail "the partial walk does not name its count and the find: ${verdict_out//$'\n'/ | }"
fi
if grep -q '^DIED\|^MSG-K2W4$' <<<"${verdict_out}"; then
    fail "a partial walk fails the install or reads as an unrecognized result: ${verdict_out//$'\n'/ | }"
else
    pass "a partial walk is neither a failure nor an unrecognized result"
fi

# ── _label_project / _unlabel_project: the statuses beside the gate's ─────────────────────────
section "install-selinux.sh: the project walks read a partial walk, a walker that could not run and an absent tree (unit)"
project_text=""
for name in warn _label_project _unlabel_project _report_skipped_walk_entries _warn_walker_unavailable; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    project_text+="${body}"$'\n'
done
# project_run <function> <status> <diagnostics> : <function> over /p with the library returning <status> and setting
#   the diagnostics; prints both streams, `ok` and `log` lines included.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
project_run() {
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN=""
        ok() { printf "OK %s\n" "$*"; }; log() { printf "LOG %s\n" "$*"; }
        lib_status="$3" lib_diagnostics="$4"
        ai_tools_relabel__label_project()   { AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${lib_diagnostics}"; return "${lib_status}"; }
        ai_tools_relabel__unlabel_project() { AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="${lib_diagnostics}"; return "${lib_status}"; }
        "$2" /p
    ' _ "${project_text}" "$1" "$2" "$3" 2>&1 || true
}
project_out="$(project_run _label_project 0 "")"
if [[ "${project_out}" == "OK labelled project ai_tools_project_t: /p" ]]; then
    pass "control: a label at status 0 reports the project labelled and nothing else"
else
    fail "control: a label at status 0 printed: ${project_out//$'\n'/ | }"
fi
for fn in _label_project _unlabel_project; do
    project_out="$(project_run "${fn}" 4 "skipped hardlinked path /p/x (link count 2)")"
    if grep -qF "LOG   the walk over /p left these entries at their type: skipped hardlinked path /p/x (link count 2)" \
            <<<"${project_out}" && ! grep -q '^MSG-' <<<"${project_out}"; then
        pass "${fn} at status 4 notes the walker's list without a warning"
    else
        fail "${fn} at status 4 printed: ${project_out//$'\n'/ | }"
    fi
    project_out="$(project_run "${fn}" 6 "ai-tools-relabel-tree: libselinux.so.1 does not load")"
    assert_msg MSG-G6X4 "${project_out}" "${fn} at status 6 warns that the walker could not run"
    if grep -qF "libselinux.so.1 does not load" <<<"${project_out}"; then
        pass "${fn} at status 6 carries the walker's reason"
    else
        fail "${fn} at status 6 does not carry the reason: ${project_out//$'\n'/ | }"
    fi
done
# The library's 3 is a registered path with no tree at it: the rules are dropped and no tree is walked, which the sweep
# reads as done; a status it does not know, the control, warns.
project_out="$(project_run _unlabel_project 3 "")"
if [[ -z "${project_out}" ]]; then
    pass "an unlabel at status 3 reads as a path with no tree to walk, silently"
else
    fail "an unlabel at status 3 printed: ${project_out//$'\n'/ | }"
fi
project_out="$(project_run _unlabel_project 7 "")"
assert_msg MSG-W8J4 "${project_out}" "control: an unlabel at a status it does not know warns"
project_out="$(project_run _label_project 4 "x")"
if grep -qF "OK labelled project ai_tools_project_t: /p" <<<"${project_out}"; then
    pass "a label at status 4 reports the project labelled"
else
    fail "a label at status 4 does not report the project labelled: ${project_out//$'\n'/ | }"
fi
# The agent unlabel loop in _labels_drop reads the same two statuses; it walks the host's manifest directory, so its
# text is read for the arms.
drop_text="$(extract_function "${INSTALLER}" _labels_drop)"
if grep -qE '^ +4\) _report_skipped_walk_entries ' <<<"${drop_text}" && grep -qE '^ +6\) _warn_walker_unavailable ' <<<"${drop_text}"; then
    pass "the agent unlabel loop reads status 4 and status 6"
else
    fail "the agent unlabel loop does not read status 4 and status 6"
fi
if grep -qF 'MSG-B8Q9' <<<"$(grep -E '^ +5\) warn ' <<<"${drop_text}")" \
        && ! grep -q 'TREE_DIAGNOSTICS:-}" ]]' <<<"${drop_text}"; then
    pass "the agent unlabel loop reads a failed config walk by its status, not by the walker's lines"
else
    fail "the agent unlabel loop does not read status 5, or still reads the walker's lines for it"
fi
# The loop runs only in remove, and no later walk revisits an agent's config directory, so each status that leaves
# a path on a removed type sets the flag the action exits 1 on. arm_sets_flag <status>: 0 when that status's arm,
# from its label to its `;;`, assigns REMOVE_LEFT_PATHS=1.
arm_sets_flag() {
    grep -qF 'REMOVE_LEFT_PATHS=1' \
        <<<"$(awk -v s="$1" '$0 ~ "^ +" s "\\) " { a = 1 } a { print } a && /;;/ { exit }' <<<"${drop_text}")"
}
if ! arm_sets_flag 0 && ! arm_sets_flag '\\*'; then
    if arm_sets_flag 4 && arm_sets_flag 5 && arm_sets_flag 6; then
        pass "the agent unlabel loop counts statuses 4, 5 and 6 toward remove's exit 1, and 0 and no rules not"
    else
        fail "an agent unlabel status that leaves a path on a removed type does not set REMOVE_LEFT_PATHS"
    fi
else
    fail "control: status 0 or the no-rules arm sets REMOVE_LEFT_PATHS, so the reader cannot tell the arms apart"
fi

# ── remove: the rules outside the registries, and an unload that reads the store back ────────
# A local rule naming an ai_tools type that no registry walk dropped keeps every module loaded, and the unload's exit
# status once reported `removed` over three. semanage, semodule and the tree walk are recorders; the listing is fixture
# rows.
section "install-selinux.sh: remove drops every rule naming a policy type and reports an unload that left a module (unit)"
remove_text=""
for name in warn die _list _resolve_walk_root _restore_account_tree_labels _revert_account_tree_labels _warn_walk_incomplete \
        _report_skipped_walk_entries _warn_walker_unavailable \
        _resolve_pattern_tree _drop_remaining_policy_type_rules _read_loaded_policy_modules _unload_modules; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    remove_text+="${body}"$'\n'
done
# Two trees a pattern can reach without naming them: `outside` through a `..` in the literal, `elsewhere/sub`
# through a symlinked ancestor. Each exists and is a directory, so only the canonical-path test refuses it.
mkdir -p "${TESTDIR}/drop/gone" "${TESTDIR}/drop/app.v1" "${TESTDIR}/drop/climb" "${TESTDIR}/outside" "${TESTDIR}/elsewhere/sub"
ln -s "${TESTDIR}/elsewhere" "${TESTDIR}/drop/link"
# run_drop [nobackstop] : the sweep over the fixture rows; the recorder holds each semanage delete and each walk, one
#   per line, and both streams of the run are printed. The backstop is a stub refusing `/` and a home root, or absent
#   under `nobackstop`.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_drop() {
    : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN="" C_RED="" C_DIM=""
        ok() { printf "ok %s\n" "$*"; }; log() { printf "+ %s\n" "$*"; }
        stub_testdir="$2"
        ai_tools_relabel__relabel_tree() { printf "walk %s\n" "$1" >> "${stub_testdir}/recorder"; }
        restorecon() { printf "restorecon %s\n" "$*" >> "${stub_testdir}/recorder"; }
        semanage() { [[ "$*" == *"/stuck("* ]] && return 1; printf "semanage %s\n" "$*" >> "${stub_testdir}/recorder"; }
        _locked() { "$@"; }
        [[ "$3" == nobackstop ]] || ai_tools_safe_paths__match_protected_path() { [[ "$1" == / || "$1" =~ ^/home/[^/]+$ ]]; }
        ai_tools_relabel__list_local_rules_naming_policy_types() {
            printf "%s\t%s\t%s\n" \
                "${stub_testdir}/drop/gone(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/gone(/.*)?/(bin|obj)(/.*)?" a ai_tools_project_build_t \
                "/opt/ai-tools/\\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\\.exe" f ai_tools_exec_t \
                "${stub_testdir}/drop/app\\.v1(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/absent(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/climb/\\.\\./\\.\\./outside(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/link/sub(/.*)?" a ai_tools_project_t \
                "/(/.*)?" a ai_tools_project_t \
                "/stuck(/.*)?" a ai_tools_conf_t
        }
        _drop_remaining_policy_type_rules
    ' _ "${remove_text}" "${TESTDIR}" "${1:-}" 2>&1 || true
}
drop_out="$(run_drop)"
recorded="$(<"${TESTDIR}/recorder")"
for want in "semanage fcontext -d -f a -- ${TESTDIR}/drop/gone(/.*)?" \
            "semanage fcontext -d -f a -- ${TESTDIR}/drop/gone(/.*)?/(bin|obj)(/.*)?" \
            'semanage fcontext -d -f f -- /opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\.exe' \
            "semanage fcontext -d -f a -- ${TESTDIR}/drop/absent(/.*)?"; do
    grep -qxF -- "${want}" <<<"${recorded}" && pass "dropped under its file-type letter: ${want#semanage fcontext -d -f }" \
        || fail "not dropped: ${want} (recorded: ${recorded//$'\n'/ | })"
done
if [[ "$(grep -c '^walk ' <<<"${recorded}")" -eq 2 ]] \
        && grep -qxF -- "walk ${TESTDIR}/drop/gone" <<<"${recorded}" \
        && grep -qxF -- "walk ${TESTDIR}/drop/app.v1" <<<"${recorded}" \
        && ! grep -q '^restorecon ' <<<"${recorded}"; then
    pass "the tree a project-shaped rule covers goes through the tree walk, its escaping removed, and a build rule, an entrypoint rule, a tree that is gone and a protected path are not walked"
else
    fail "walks: $(grep -E '^(walk|restorecon) ' <<<"${recorded}" | tr '\n' ';')"
fi
# A literal that exists and resolves elsewhere is dropped and not walked: the rule names a string, the walk a tree.
for climbing in "${TESTDIR}/drop/climb/\\.\\./\\.\\./outside(/.*)?" "${TESTDIR}/drop/link/sub(/.*)?"; do
    grep -qxF -- "semanage fcontext -d -f a -- ${climbing}" <<<"${recorded}" \
        && ! grep -qE -- "^(walk|restorecon) .*(outside|elsewhere|/drop/link|/drop/climb)" <<<"${recorded}" \
        && pass "a pattern reaching a tree it does not name is dropped and its tree not walked: ${climbing##*/drop/}" \
        || fail "pattern ${climbing}: recorded ${recorded//$'\n'/ | }"
done
# The backstop guards the walk, not the drop: a local rule mapping / to the policy's own type is what the unload refuses
# on, and removing the mapping relabels nothing.
grep -qxF -- "semanage fcontext -d -f a -- /(/.*)?" <<<"${recorded}" \
    && pass "a local rule mapping a protected path to the policy's type is dropped (the unload refuses on it) while its tree is not walked" \
    || fail "the local ai_tools_project_t rule on / was not dropped"
run_drop nobackstop >/dev/null
grep -qE '^(walk|restorecon) ' "${TESTDIR}/recorder" && fail "nobackstop: a tree was walked with the backstop absent: $(grep -E '^(walk|restorecon) ' "${TESTDIR}/recorder" | tr '\n' ';')" \
    || pass "backstop absent: no tree is walked (the backstop fails closed)"
assert_msg MSG-N5W8 "${drop_out}" "a rule semanage will not delete is named"
grep -qF -- "semanage fcontext -d -f a -- /stuck" <<<"${drop_out}" \
    && pass "the warning gives the delete to run for the rule left" \
    || fail "the warning does not give the delete: ${drop_out//$'\n'/ | }"
grep -qF -- "${TESTDIR}/drop/absent" <<<"${drop_out}" && pass "each dropped rule is named in the transcript" \
    || fail "the dropped rule is not named: ${drop_out//$'\n'/ | }"

# run_unload <loaded...> : _unload_modules over a store listing the given modules; the stub's `-r` prints libsemanage's
#   progress on stdout, refuses with the content of the refuse file on stderr where one is set, and otherwise clears
#   the store unless UNLOAD_KEEPS is set, which models an exit 0 that left the modules in place. LIST_FAILS=<n> makes
#   the n-th `-l` exit 1 with a line on stderr and nothing on stdout, a store that cannot be read. Prints both streams
#   and then `exit=<status>`.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_unload() {
    printf '%s\n' "$@" > "${TESTDIR}/loaded"; : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN="" C_RED="" C_DIM=""
        ok() { printf "ok %s\n" "$*"; }; log() { printf "+ %s\n" "$*"; }
        stub_testdir="$2"
        _locked() { "$@"; }
        : > "${stub_testdir}/list_calls"
        semodule() {
            case "$1" in
                -l) printf . >> "${stub_testdir}/list_calls"   # a file: the call runs inside a $(...) subshell
                    if [[ "${LIST_FAILS:-0}" == "$(wc -c < "${stub_testdir}/list_calls")" ]]; then
                        echo "semodule: SELinux policy is not managed or store cannot be accessed." >&2; return 1
                    fi
                    cat "${stub_testdir}/loaded" ;;
                -r) shift; printf "semodule -r %s\n" "$*" >> "${stub_testdir}/recorder"
                    printf "libsemanage.semanage_direct_remove_key: Removing last %s module\n" "$@"
                    if [[ -s "${stub_testdir}/refuse" ]]; then cat "${stub_testdir}/refuse" >&2; return 1; fi
                    [[ -n "${UNLOAD_KEEPS:-}" ]] || : > "${stub_testdir}/loaded" ;;
            esac
        }
        _unload_modules
    ' _ "${remove_text}" "${TESTDIR}" 2>&1; printf 'exit=%s\n' "$?"
}
: > "${TESTDIR}/refuse"
unload_out="$(run_unload ai_tools ai_tools_dotnet ai_tools_tmpmap zebra_t)"
grep -qx 'exit=0' <<<"${unload_out}" && ! grep -qx 'MSG-R6M2' <<<"${unload_out}" \
    && pass "an unload the store confirms exits 0 without the code (control)" \
    || fail "clean unload: ${unload_out//$'\n'/ | }"
grep -qxF 'semodule -r ai_tools ai_tools_dotnet ai_tools_tmpmap' "${TESTDIR}/recorder" \
    && pass "every ai_tools* module and no other goes in one semodule transaction" \
    || fail "unload call: $(tr '\n' ';' <"${TESTDIR}/recorder")"
grep -q 'Removing last' <<<"${unload_out}" && fail "libsemanage's progress lines reach the transcript" \
    || pass "libsemanage's progress on stdout is dropped"
printf '%s\n' 'libsepol.context_from_record: type ai_tools_conf_t is not defined (No such file or directory).' \
    'libsemanage.validate_handler: invalid context system_u:object_r:ai_tools_conf_t:s0 specified for /home/op/.config/ai-tools(/.*)? [all files] (Invalid argument).' \
    'semodule:  Failed!' > "${TESTDIR}/refuse"
unload_out="$(run_unload ai_tools ai_tools_dotnet ai_tools_tmpmap)"
assert_msg MSG-R6M2 "${unload_out}" "a refused unload dies under its code"
grep -qx 'exit=1' <<<"${unload_out}" && pass "a refused unload exits 1" || fail "refused unload exit: ${unload_out//$'\n'/ | }"
grep -qF 'left loaded: [ai_tools, ai_tools_dotnet, ai_tools_tmpmap]' <<<"${unload_out}" && pass "the refusal names each module left loaded as one list" \
    || fail "the refusal does not name the modules: ${unload_out//$'\n'/ | }"
grep -qF 'invalid context system_u:object_r:ai_tools_conf_t:s0 specified for /home/op/.config/ai-tools(/.*)?' <<<"${unload_out}" \
    && pass "the refusal carries semanage's reason, the rule it validated against" \
    || fail "the refusal does not carry the reason: ${unload_out//$'\n'/ | }"
grep -q 'removed' <<<"${unload_out}" && fail "a refused unload prints removed" || pass "a refused unload does not print removed"
: > "${TESTDIR}/refuse"
unload_out="$(UNLOAD_KEEPS=1 run_unload ai_tools)"
assert_msg MSG-R6M2 "${unload_out}" "an exit 0 that left a module loaded is read from the store, not the status"
unload_out="$(run_unload zebra_t)"
grep -qx 'exit=0' <<<"${unload_out}" && [[ ! -s "${TESTDIR}/recorder" ]] && grep -qF 'no ai_tools module is loaded' <<<"${unload_out}" \
    && pass "a store with no ai_tools module makes no semodule -r call and says so" \
    || fail "empty store: ${unload_out//$'\n'/ | } (calls: $(tr '\n' ';' <"${TESTDIR}/recorder"))"
# A listing that fails is a store that could not be read, not an empty one: the first read refuses before any unload,
# the second refuses rather than claiming the store empty after one.
unload_out="$(LIST_FAILS=1 run_unload ai_tools ai_tools_dotnet)"
assert_msg MSG-A3V5 "${unload_out}" "a store that cannot be listed before the unload dies under its code"
grep -qx 'exit=1' <<<"${unload_out}" && [[ ! -s "${TESTDIR}/recorder" ]] && ! grep -q 'removed\|no ai_tools module is loaded' <<<"${unload_out}" \
    && grep -qF 'store cannot be accessed' <<<"${unload_out}" \
    && pass "a failed first listing makes no semodule -r call, carries semodule's reason, and is not read as an empty store" \
    || fail "failed first listing: ${unload_out//$'\n'/ | } (calls: $(tr '\n' ';' <"${TESTDIR}/recorder"))"
unload_out="$(LIST_FAILS=2 run_unload ai_tools ai_tools_dotnet)"
assert_msg MSG-A3V5 "${unload_out}" "a store that cannot be listed after the unload dies under its code"
grep -qx 'exit=1' <<<"${unload_out}" && grep -qxF 'semodule -r ai_tools ai_tools_dotnet' "${TESTDIR}/recorder" \
    && ! grep -q 'removed' <<<"${unload_out}" && ! grep -qx 'MSG-R6M2' <<<"${unload_out}" \
    && pass "a failed read-back after the unload is reported as unread, neither as removed nor as left loaded" \
    || fail "failed read-back: ${unload_out//$'\n'/ | } (calls: $(tr '\n' ';' <"${TESTDIR}/recorder"))"

# ── for_each_project: the registry entries the label walks reach ──────────────────────────────
# Every label, unlabel and restore over the operators' projects goes through for_each_project, so an entry it yields is
# a tree that takes ai_tools_project_t. It is driven through the checkout's conf.lib.sh over a format 1.0 registry
# holding each sign, every path an existing directory, so the kind alone decides what is yielded.
# ── The canonical root, and the removal direction's reading of a walk left ─────────────────────
# Every walk is over the path realpath resolves, since the walker refuses a root whose path is not the one it reads
# back; a path realpath cannot resolve is warned and not walked. The remove action reads a walk that left hardlinked
# paths as a warning with the find for an inode's names and closes non-zero, where the label direction notes them.
section "install-selinux.sh: the walks resolve their root, and remove reads a walk left (unit)"
mkdir -p "${TESTDIR}/real/tree"
ln -s "${TESTDIR}/real" "${TESTDIR}/alias"
ln -s "${TESTDIR}/absent-target" "${TESTDIR}/dangling"
# run_walk <function> <walk-status> <path> [note-arg]: drive one walk function with the tree walk stubbed
#   to <walk-status>; prints both streams, then `left=<REMOVE_LEFT_PATHS>`; the recorder holds the walks.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_walk() {
    : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_DIM=""
        stub_testdir="$2" walk_status="$3"
        ai_tools_relabel__relabel_tree() {
            printf "walk %s\n" "$1" >> "${stub_testdir}/recorder"
            AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="skipped hardlinked path $1/x (link count 2, inode 4242)"
            return "${walk_status}"
        }
        log() { printf "LOG %s\n" "$*" >&2; }
        REMOVE_LEFT_PATHS=0
        "$4" "$5" ${6:+"$6"}
        printf "left=%s\n" "${REMOVE_LEFT_PATHS}" >&2
    ' _ "${functions_text}" "${TESTDIR}" "$2" "$1" "$3" "${4:-}" 2>&1 || true
}
out="$(run_walk _restore_account_tree_labels 0 "${TESTDIR}/alias/tree")"
if [[ "$(<"${TESTDIR}/recorder")" == "walk ${TESTDIR}/real/tree" ]]; then
    pass "a tree named through a symlinked ancestor is walked at its canonical path"
else
    fail "a tree named through a symlinked ancestor: $(<"${TESTDIR}/recorder") / ${out//$'\n'/ | }"
fi
out="$(run_walk _restore_account_tree_labels 0 "${TESTDIR}/dangling")"
assert_msg MSG-X5F9 "${out}" "a path realpath cannot resolve is warned"
if [[ ! -s "${TESTDIR}/recorder" ]]; then
    pass "a path realpath cannot resolve is not walked"
else
    fail "a path realpath cannot resolve was walked: $(<"${TESTDIR}/recorder")"
fi
out="$(run_walk _restore_account_tree_labels 0 "${TESTDIR}/absent")"
if [[ ! -s "${TESTDIR}/recorder" && "${out}" != *MSG-X5F9* ]]; then
    pass "an absent path is neither walked nor warned"
else
    fail "an absent path: $(<"${TESTDIR}/recorder") / ${out//$'\n'/ | }"
fi
out="$(run_walk _restore_account_tree_labels 4 "${TESTDIR}/real/tree" agent-relabel)"
if grep -qF 'an agent entrypoint among them takes its type from the agent relabel that follows' <<<"${out}"; then
    pass "the toolchain's label walk notes that an entrypoint among the paths left takes the agent relabel"
else
    fail "the toolchain's label walk at status 4: ${out//$'\n'/ | }"
fi
out="$(run_walk _restore_account_tree_labels 4 "${TESTDIR}/real/tree")"
if ! grep -qF 'agent relabel that follows' <<<"${out}" && grep -qF 'left these entries at their type' <<<"${out}"; then
    pass "control: another tree's label walk notes the paths left without the agent-relabel line"
else
    fail "control: another tree's label walk at status 4: ${out//$'\n'/ | }"
fi
mount="$(stat -c '%m' -- "${TESTDIR}/real/tree")"
out="$(run_walk _revert_account_tree_labels 4 "${TESTDIR}/real/tree")"
assert_msg MSG-Q6V5 "${out}" "remove: a walk that left hardlinked paths warns that they keep a type the policy no longer defines"
if grep -qF "sudo find ${mount} -xdev -inum <inode> -ls" <<<"${out}" && grep -qF 'inode 4242' <<<"${out}" && grep -qx 'left=1' <<<"${out}"; then
    pass "remove: the warning carries the walker's line and the find for an inode's names, and the action closes non-zero"
else
    fail "remove: at status 4: ${out//$'\n'/ | }"
fi
out="$(run_walk _revert_account_tree_labels 0 "${TESTDIR}/real/tree")"
if grep -qx 'left=0' <<<"${out}" && ! grep -q 'MSG-' <<<"${out}"; then
    pass "control: remove over a walk that reverted every entry leaves the action's close clean"
else
    fail "control: remove at status 0: ${out//$'\n'/ | }"
fi
for pair in 1:MSG-D6B7 6:MSG-G6X4; do
    out="$(run_walk _revert_account_tree_labels "${pair%%:*}" "${TESTDIR}/real/tree")"
    assert_msg "${pair##*:}" "${out}" "remove: a walk returning ${pair%%:*} keeps its warning"
    if grep -qx 'left=1' <<<"${out}"; then
        pass "remove: a walk returning ${pair%%:*} closes the action non-zero"
    else
        fail "remove at status ${pair%%:*} did not set the close: ${out//$'\n'/ | }"
    fi
done
# The remove arm, read as text: the control plane whole, the clone area and each project take the removal direction's
# walk, and the close reads what they left.
remove_arm="$(awk '/^  remove\)/ { inside = 1; next } inside && /^    ;;/ { exit } inside' "${INSTALLER}")"
if grep -qF '_revert_account_tree_labels "${CP_HOME}"' <<<"${remove_arm}" \
        && grep -qF '_revert_account_tree_labels "${SANDBOX_PROJECTS}"' <<<"${remove_arm}" \
        && grep -qF 'for_each_project _revert_account_tree_labels' <<<"${remove_arm}" \
        && grep -qxE '[[:space:]]+_revert_root_tree_labels' <<<"${remove_arm}" \
        && ! grep -qF ' _restore_account_tree_labels ' <<<"${remove_arm}" \
        && grep -qF 'REMOVE_LEFT_PATHS' <<<"${remove_arm}" && grep -qE '^[[:space:]]+exit 1$' <<<"${remove_arm}"; then
    pass "the remove arm walks every tree in the removal direction and exits 1 over a walk left"
else
    fail "the remove arm: ${remove_arm//$'\n'/ | }"
fi

# Each label arm walks the shared asset trees after the policy load, which a source install's layout reconcile created
# ahead of it at the base policy's type.
for arm in install relabel rebuild; do
    arm_text="$(awk -v arm="${arm}" '$0 == "  " arm ")" { inside = 1; next } inside && /^    ;;/ { exit } inside' \
        "${INSTALLER}")"
    if [[ -z "${arm_text}" ]]; then
        fail "install-selinux.sh has no ${arm}) arm in the form this file reads"
    elif grep -qxE '[[:space:]]+_restore_shared_tree_labels' <<<"${arm_text}"; then
        pass "the ${arm} arm walks the shared asset trees in the label direction"
    else
        fail "the ${arm} arm does not walk the shared asset trees"
    fi
done

# The root-owned trees the policy types take one restorecon each after the unload; one that fails is warned and closes
# the action non-zero. run_root_revert <failing-dir|->: drive _revert_root_tree_labels with restorecon recorded
# and failing for <failing-dir>; prints both streams, then `left=<REMOVE_LEFT_PATHS>`.
mkdir -p "${TESTDIR}/root/log" "${TESTDIR}/root/libexec" "${TESTDIR}/root/run"
root_text="${functions_text//\/usr\/local\/libexec\/ai-tools/${TESTDIR}/root/libexec}"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_root_revert() {
    : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST=""
        stub_testdir="$2" failing="$3"
        restorecon() {
            printf "restorecon %s\n" "$*" >> "${stub_testdir}/recorder"
            [[ "${!#}" != "${failing}" ]]
        }
        LOG_DIR="$2/root/log" RUN_DIR="$2/root/run" REMOVE_LEFT_PATHS=0
        _revert_root_tree_labels
        printf "left=%s\n" "${REMOVE_LEFT_PATHS}" >&2
    ' _ "${root_text}" "${TESTDIR}" "$1" 2>&1 || true
}
out="$(run_root_revert -)"
expected="restorecon -FR ${TESTDIR}/root/log
restorecon -FR ${TESTDIR}/root/libexec
restorecon -FR ${TESTDIR}/root/run"
if [[ "$(<"${TESTDIR}/recorder")" == "${expected}" ]] && grep -qx 'left=0' <<<"${out}" && ! grep -q 'MSG-' <<<"${out}"; then
    pass "remove reverts the log, helper and runtime directories with one restorecon each, and closes clean"
else
    fail "remove's root-tree revert: $(tr '\n' ';' <"${TESTDIR}/recorder") / ${out//$'\n'/ | }"
fi
out="$(run_root_revert "${TESTDIR}/root/libexec")"
assert_msg MSG-A3F7 "${out}" "remove: a root-owned tree restorecon could not revert is warned"
if grep -qF "sudo restorecon -FR ${TESTDIR}/root/libexec" <<<"${out}" && grep -qx 'left=1' <<<"${out}" \
        && grep -qxF "restorecon -FR ${TESTDIR}/root/run" "${TESTDIR}/recorder"; then
    pass "remove: the warning names the tree and its restorecon, the later trees still run, and the action closes non-zero"
else
    fail "remove with a failing restorecon: ${out//$'\n'/ | }"
fi

section "install-selinux.sh: the project walk yields @ and % entries and no excluded path (unit)"
walk_text="$(extract_function "${INSTALLER}" for_each_project)"
if [[ -z "${walk_text}" ]]; then
    fail "install-selinux.sh does not define for_each_project() in the form this file reads"
    finish; exit
fi
reg_root="${TESTDIR}/registry"
mkdir -p "${reg_root}/proj/carved" "${reg_root}/parked" "${reg_root}/outside" "${reg_root}/globbed-1"
printf '%s\n' '# ai-tools-project-registry-format: 1.0' "@ ${reg_root}/proj" "  ! ${reg_root}/proj/carved" \
    "! ${reg_root}/globbed-*" "! ${reg_root}/outside" "% ${reg_root}/parked" > "${reg_root}/project-registry"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
walked="$(bash -c '
    set -euo pipefail
    source "$2"
    eval "$1"
    warn() { printf "WARN %s\n" "$*"; }
    ALLOWLIST="$3"; SANDBOX_PROJECTS="$4"
    for_each_project echo
' _ "${walk_text}" "${ROOT}/src/usr/local/lib/ai-tools/conf.lib.sh" "${reg_root}/project-registry" \
    "${TESTDIR}/clones" 2>&1)" || true
if [[ "${walked}" == "${reg_root}/proj"$'\n'"${reg_root}/parked" ]]; then
    pass "the project and the disabled project are walked (the control for the exclusions)"
else
    fail "the walk yielded: ${walked//$'\n'/ | }"
fi
for excluded in proj/carved outside globbed-1; do
    grep -qxF -- "${reg_root}/${excluded}" <<<"${walked}" \
        && fail "an excluded path is walked: ${excluded}" \
        || pass "an excluded path is not walked: ${excluded}"
done

section "install-selinux.sh: a loaded module is read from a listing of names alone (unit)"
alignment_text=""
for name in warn _check_permissive_alignment; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    alignment_text+="${body}"$'\n'
done
mkdir -p "${TESTDIR}/policy"
printf 'policy_module(ai_tools, 1.0)\n' > "${TESTDIR}/policy/ai_tools.te"
# run_alignment <module>...: the report over a host where ai_tools_t is permissive in the kernel, the .te expects
#   enforcing, and `semodule -l` prints the given names among 600 others, one per line with no second column,
#   which is the listing every supported release prints. The predicate is the checkout library's. stdin is not
#   a terminal, so the stale-module branch prints its command and does not ask.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_alignment() {
    bash -c '
        set -euo pipefail
        eval "$1"
        source "$2"
        C_YEL="" C_RST=""
        POLICY_DIR="$3" MODULE=ai_tools
        shift 3
        stub_modules=("$@")
        seinfo() { printf "\nPermissive Types: 1\n   ai_tools_t\n"; }
        semodule() {
            printf "%s\n" abrt "${stub_modules[@]}"
            # shellcheck disable=SC2046  # each padding module is its own line
            printf "pad_module_%04d\n" $(seq 1 600)
        }
        _check_permissive_alignment
    ' _ "${alignment_text}" "${ROOT}/src/usr/local/lib/ai-tools/selinux-groups.lib.sh" "${TESTDIR}/policy" "$@" \
        2>&1 </dev/null || true
}
alignment_out="$(run_alignment ai_tools permissive_ai_tools_t)"
if grep -qF "stale semodule 'permissive_ai_tools_t' overrides compiled policy" <<<"${alignment_out}" \
        && grep -qF 'fix: sudo semodule -r permissive_ai_tools_t' <<<"${alignment_out}"; then
    pass "a stale permissive module in a listing of names alone is named with its removal"
else
    fail "a loaded permissive_ai_tools_t was not read from a listing of names alone: ${alignment_out//$'\n'/ | }"
fi
alignment_out="$(run_alignment ai_tools permissive_ai_tools_t_other)"
if grep -qF 'no permissive_ai_tools_t module found' <<<"${alignment_out}" \
        && ! grep -qF 'stale semodule' <<<"${alignment_out}"; then
    pass "a module whose name starts with the stale module's is not it, and the semanage remedy is printed (control)"
else
    fail "control: a longer module name read as the stale module: ${alignment_out//$'\n'/ | }"
fi

# find_listing_captures <file>: print each code line that captures `semodule -l`. The script matches the listing
# in _read_loaded_policy_modules alone, which keeps semodule's status; every other reading is the library predicate's.
# shellcheck disable=SC2016  # the pattern matches the literal $( text
find_listing_captures() {
    grep -nF '$(semodule -l' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' || true
}
printf '%s\n' 'modules="$(semodule -l 2>/dev/null || true)"' '# listing="$(semodule -l)" in a comment' \
    '    listing="$(semodule -l 2>&1)" \' > "${TESTDIR}/listing-control.sh"
if [[ "$(find_listing_captures "${TESTDIR}/listing-control.sh" | grep -c .)" -eq 2 ]]; then
    pass "the reader flags each capture of the module listing and no comment (control)"
else
    fail "control: the reader does not flag a capture of the module listing, so the check below cannot fail"
fi
captures="$(find_listing_captures "${INSTALLER}")"
store_reader="$(extract_function "${INSTALLER}" _read_loaded_policy_modules)"
# shellcheck disable=SC2016  # the pattern matches the literal $( text
if [[ "$(grep -c . <<<"${captures}")" -eq 1 ]] && grep -qF '$(semodule -l' <<<"${store_reader}"; then
    pass "the script captures the module listing in _read_loaded_policy_modules alone"
else
    fail "the script captures the module listing outside _read_loaded_policy_modules: ${captures//$'\n'/ | }"
fi
# shellcheck disable=SC2016  # the pattern matches the literal ${MODULE} text
list_groups_arm="$(awk '/^  list-groups\)/ { inside = 1; next } inside && /^    ;;/ { exit } inside' "${INSTALLER}")"
# shellcheck disable=SC2016
if grep -qF 'if ai_tools_selinux_groups__is_module_loaded "${MODULE}"; then' <<<"${list_groups_arm}"; then
    pass "list-groups reads the core module through the library predicate"
else
    fail "list-groups does not read the core module through ai_tools_selinux_groups__is_module_loaded"
fi

# ── the script's text ─────────────────────────────────────────────────────────────────────────
section "the installed library is read first, and no restorecon crosses an account-writable tree"

read_line_number() { grep -n -m1 -F -- "$1" "${INSTALLER}" | cut -d: -f1; }
exec_lib_line="$(read_line_number 'source "${SANDBOX_EXEC_LIB}"')"
relabel_lib_line="$(read_line_number 'source "${RELABEL_LIB}"')"
sessions_lib_line="$(read_line_number 'source "${SESSIONS_LIB}"')"
if grep -qxF 'SANDBOX_EXEC_LIB="/usr/local/lib/ai-tools/sandbox-exec.lib.sh"' "${INSTALLER}" \
        && [[ -n "${exec_lib_line}" && -n "${relabel_lib_line}" && "${exec_lib_line}" -lt "${relabel_lib_line}" ]]; then
    pass "the installed sandbox-exec.lib.sh is sourced ahead of the relabel library"
else
    fail "the installed sandbox-exec.lib.sh is not sourced ahead of RELABEL_LIB (lines ${exec_lib_line:-none}, ${relabel_lib_line:-none})"
fi
[[ -n "${sessions_lib_line}" && "${sessions_lib_line}" -gt "${relabel_lib_line}" ]] \
    && pass "sessions.lib.sh is sourced beside the relabel library, after it" \
    || fail "sessions.lib.sh is not sourced after RELABEL_LIB (line ${sessions_lib_line:-none})"

# find_account_tree_restorecons <file>: print each code line calling restorecon that is neither a walk of a root-owned
# tree, nor the one-path restore of a file in the root-owned home (_restore_home_state_labels), nor a command a warning
# prints.
# shellcheck disable=SC2016  # the patterns match the literal ${...} text
find_account_tree_restorecons() {
    grep -nE '(^|[^[:alnum:]_-])restorecon[[:space:]]' "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vE 'warn |restorecon -F "\$\{path\}" 2>/dev/null' \
        | grep -vE '"\$\{(LOG_DIR|RUN_DIR)\}"|/usr/local/libexec/ai-tools' || true
}
printf '%s\n' '_restore_one() { restorecon -FR "$1"; }' '    restorecon -FR "${NVM_DIR}"  2>/dev/null || true' \
    '            restorecon -FR "${path}" 2>/dev/null || true' > "${TESTDIR}/control.sh"
if [[ "$(find_account_tree_restorecons "${TESTDIR}/control.sh" | grep -c .)" -eq 3 ]]; then
    pass "the reader flags a restorecon of an account-writable tree, the home's path recursive among them (control)"
else
    fail "control: the reader does not flag a restorecon of an account-writable tree, so the check below cannot fail"
fi
found="$(find_account_tree_restorecons "${INSTALLER}")"
[[ -z "${found}" ]] && pass "every restorecon names a root-owned tree or one file in the root-owned home" \
    || fail "a restorecon crosses a tree the sandbox account can write: ${found//$'\n'/ | }"

# remove_guard_order <file>: print `guarded` when the remove action reads the live-session state ahead of its first
# store write (_labels_drop), and `unguarded` otherwise. The action is read from its `remove)` arm to the next `;;`.
remove_guard_order() {
    awk '
        /^  remove\)/ { inside = 1; next }
        inside && /^    ;;/ { exit }
        inside && /ai_tools_sessions__read_live_session_state/ && /== none/ && !dropped { guard = 1 }
        inside && /_labels_drop/ { dropped = 1; print (guard ? "guarded" : "unguarded"); exit }
    ' "$1"
}
printf '%s\n' '  remove)' '    _locked _labels_drop' '    [[ "$(ai_tools_sessions__read_live_session_state)" == none ]] || die x' '    ;;' \
    > "${TESTDIR}/remove-control.sh"
if [[ "$(remove_guard_order "${TESTDIR}/remove-control.sh")" == unguarded ]]; then
    pass "the reader flags a remove whose guard follows its first store write (control)"
else
    fail "control: the reader does not flag a late guard, so the check below cannot fail"
fi
[[ "$(remove_guard_order "${INSTALLER}")" == guarded ]] \
    && pass "remove refuses on a live-session reading before its first store write" \
    || fail "remove does not read the live-session state ahead of _labels_drop"
grep -qF 'die MSG-H7Q2' "${INSTALLER}" \
    && pass "the remove refusal carries its code" \
    || fail "the remove refusal does not carry MSG-H7Q2"

# remove_step_order <file>: print the remove action's steps in the order its arm runs them -- the registry drop,
# the sweep over the rules outside the registries, the unload, and the closing `removed` -- one token per line.
remove_step_order() {
    awk '
        /^  remove\)/ { inside = 1; next }
        inside && /^    ;;/ { exit }
        inside && /_labels_drop/ { print "labels_drop" }
        inside && /_drop_remaining_policy_type_rules/ { print "sweep" }
        inside && /_unload_modules/ { print "unload" }
        inside && /ok "removed"/ { print "removed" }
    ' "$1" | tr '\n' ' '
}
printf '%s\n' '  remove)' '    _unload_modules' '    _locked _labels_drop' '    ok "removed"' '    ;;' > "${TESTDIR}/remove-order-control.sh"
[[ "$(remove_step_order "${TESTDIR}/remove-order-control.sh")" == "unload labels_drop removed " ]] \
    && pass "the reader prints the remove's steps in the order the arm runs them (control)" \
    || fail "control: the step reader printed '$(remove_step_order "${TESTDIR}/remove-order-control.sh")'"
[[ "$(remove_step_order "${INSTALLER}")" == "labels_drop sweep unload removed " ]] \
    && pass "remove drops the registry rules, then every rule naming a policy type, unloads, and reports removed last" \
    || fail "remove's step order: '$(remove_step_order "${INSTALLER}")'"
# The shape that reported `removed` over a loaded module: semanage's stderr nulled and the status dropped on one line.
[[ -n "$(grep -nE 'semodule -r .*2>/dev/null.*\|\| true' "${INSTALLER}")" ]] \
    && fail "a semodule -r still nulls its stderr and drops its status: $(grep -nE 'semodule -r .*2>/dev/null.*\|\| true' "${INSTALLER}" | tr '\n' ';')" \
    || pass "no semodule -r in the installer nulls its stderr and drops its status"

finish
