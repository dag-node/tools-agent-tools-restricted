#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-selinux-walks.sh
# Hermetic check of selinux/install-selinux.sh's walks over the trees the sandbox account can write: each runs only
# while the live-session reading is `none` (cli.rule.md, ref-section-e6c6), and a walk it leaves is named in one warning
# with the restorecon to run.
#
# The script loads policy and needs root and a whole host, so the functions are read out of the checkout as text
# (extract_function) and run in a fresh bash per reading, with restorecon stubbed as a recorder and the reading set
# to each of `live`, `unreadable` and `none`. _restore_home_state_labels names /opt/ai-tools in its body, which the case
# rewrites to a fixture root, so no host path is read. The script's text is then read for the two properties a function
# cannot show: the installed sandbox-exec.lib.sh is sourced ahead of the relabel library, and every restorecon outside
# the gate names a root-owned tree, held against a control line the reader must flag, and the remove action reads
# the live-session state ahead of its first policy-store write. verify_agent_labels is driven over a stubbed library
# line for a config directory whose walk was left, at the type the agent writes and at another.
#
# Unprivileged, and reads the checkout alone; skips outside one.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly INSTALLER="${ROOT}/selinux/install-selinux.sh"
section "install-selinux.sh: the account-writable walks wait for no live session (unit)"

if [[ ! -r "${INSTALLER}" ]]; then
    skip "install-selinux.sh walks" "not a source checkout (no ${INSTALLER})"
    finish; exit
fi
mktestdir

functions_text=""
for name in warn _restore_account_tree_labels _warn_left_trees _restore_home_state_labels _label_sandbox_clones; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    functions_text+="${body}"$'\n'
done
functions_text="${functions_text//\/opt\/ai-tools\//${TESTDIR}/home/}"

mkdir -p "${TESTDIR}/home/.npm" "${TESTDIR}/nvm" "${TESTDIR}/clones/acme-clone"
: > "${TESTDIR}/home/.gitconfig"

# run_walks <state>: run the walks under that reading; the recorder holds each restorecon call, one per line,
# and verified holds each clone the verify loop read. stderr is the warnings.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_walks() {
    : > "${TESTDIR}/recorder"; : > "${TESTDIR}/verified"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN=""
        restorecon() { printf "%s\n" "$*" >> "${stub_testdir}/recorder"; }
        ok() { :; }; log() { :; }
        ai_tools_relabel__is_available() { return 0; }
        ai_tools_relabel__is_project_labelled() { printf "%s\n" "$1" >> "${stub_testdir}/verified"; }
        stub_testdir="$2"
        _sandbox_session_state="$3"; _left_trees=()
        SANDBOX_EXEC_LIB=/usr/local/lib/ai-tools/sandbox-exec.lib.sh
        HOME_STATE=(.npm .gitconfig .absent)
        SANDBOX_PROJECTS="$2/clones"
        trap _warn_left_trees EXIT
        _restore_home_state_labels
        _label_sandbox_clones
        _restore_account_tree_labels "$2/nvm"
    ' _ "${functions_text}" "${TESTDIR}" "$1" 2>"${TESTDIR}/warnings"
}

walked_trees=("${TESTDIR}/home/.npm" "${TESTDIR}/home/.gitconfig" "${TESTDIR}/clones" "${TESTDIR}/nvm")

# `none` first: it is the control that the recorder records, so an empty recorder in the live and unreadable cases is
# a walk not made.
run_walks none
missing=""
for tree in "${walked_trees[@]}"; do
    grep -qxF -- "-FR ${tree}" "${TESTDIR}/recorder" || missing+=" ${tree}"
done
[[ -z "${missing}" ]] && pass "none: each account-writable tree is walked with restorecon -FR (the recorder control for the cases after it)" \
    || fail "none: not walked:${missing} (recorded: $(tr '\n' ';' <"${TESTDIR}/recorder"))"
grep -q '^MSG-U8U4$' "${TESTDIR}/warnings" && fail "none: the left-trees warning was printed" \
    || pass "none: no tree is reported left"
grep -qxF "${TESTDIR}/clones/acme-clone" "${TESTDIR}/verified" \
    && pass "none: the clone verify loop reads each clone (the control for the cases after it)" \
    || fail "none: the clone verify loop did not run"

for state in live unreadable; do
    run_walks "${state}"
    if [[ -s "${TESTDIR}/recorder" ]]; then
        fail "${state}: a walk ran: $(tr '\n' ';' <"${TESTDIR}/recorder")"
    else
        pass "${state}: no account-writable tree is walked"
    fi
    warnings="$(<"${TESTDIR}/warnings")"
    assert_msg MSG-U8U4 "${warnings}" "${state}: the trees left are named under one warning"
    missing=""
    for tree in "${walked_trees[@]}"; do
        grep -qF "sudo restorecon -FR ${tree}" <<<"${warnings}" || missing+=" ${tree}"
    done
    [[ -z "${missing}" ]] && pass "${state}: the warning gives the restorecon for each tree left" \
        || fail "${state}: the warning does not name:${missing}"
    grep -qF "${TESTDIR}/home/.absent" <<<"${warnings}" \
        && fail "${state}: the warning names a path that does not exist" \
        || pass "${state}: a path that does not exist is not named"
    if [[ -s "${TESTDIR}/verified" ]]; then
        fail "${state}: the clone verify loop reported a walk it left: $(tr '\n' ';' <"${TESTDIR}/verified")"
    else
        pass "${state}: the clone verify loop does not run over a walk it left"
    fi
done
grep -qF 'sudo ./install.sh install' <<<"${warnings}" \
    && pass "unreadable: the warning names the install that deploys the library the reading needs" \
    || fail "unreadable: the warning does not name sudo ./install.sh install: ${warnings}"

# ── verify_agent_labels: a config directory's walk left under a live session ───────────────────
# The relabel library prints `live <agent> its config directory` when it left that walk. The renderer must name it
# under its own code and list the directory with the trees the run left, and must not read it as an unrecognized result,
# which would report an unconfirmed entrypoint. The library is stubbed to print that line and the closing per-agent
# verdict, and the manifest reader to name the config directory.
section "install-selinux.sh: a config directory walk the reading left is reported as left (unit)"
agent_text=""
for name in warn _record_left_agent_config _warn_left_trees verify_agent_labels; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    agent_text+="${body}"$'\n'
done
# agent_run <verdict> <type> : verify_agent_labels over a `live` line for acme's config directory at <type>
#   and the agent line closing it with <verdict>; prints both streams of the run.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
agent_run() {
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN=""
        ok() { :; }; log() { :; }
        die() { printf "DIED %s\n" "$*" >&2; exit 1; }
        stub_lines="live acme $4 its config directory"$'"'"'\n'"'"'"agent acme $3"
        ai_tools_relabel__label_agent_paths() { printf "%s\n" "${stub_lines}"; }
        ai_tools_providers__read_agent_manifest_field() { [[ "$2" == config_dir ]] && printf ".acme\n"; }
        CP_HOME="$2"; _sandbox_session_state=live; _left_trees=()
        SANDBOX_EXEC_LIB=/usr/local/lib/ai-tools/sandbox-exec.lib.sh
        trap _warn_left_trees EXIT
        verify_agent_labels
    ' _ "${agent_text}" "${TESTDIR}/home" "$1" "$2" 2>&1 || true
}
for verdict in live-session-mislabelled live-session; do
    type=usr_t; [[ "${verdict}" == live-session ]] && type=ai_tools_home_t
    agent_warnings="$(agent_run "${verdict}" "${type}")"
    assert_msg MSG-S7C2 "${agent_warnings}" "${verdict}: the config directory's walk is named as left"
    if grep -qF "sudo restorecon -FR ${TESTDIR}/home/.acme" <<<"${agent_warnings}"; then
        pass "${verdict}: the config directory is in the closing list of trees left"
    else
        fail "${verdict}: the closing warning does not name ${TESTDIR}/home/.acme: ${agent_warnings//$'\n'/ | }"
    fi
    if grep -q '^MSG-K2W4$\|^DIED' <<<"${agent_warnings}"; then
        fail "${verdict}: the left walk read as an unrecognized result or a failed install: ${agent_warnings//$'\n'/ | }"
    else
        pass "${verdict}: the left walk is neither an unrecognized result nor a failure"
    fi
done
# The directory at a type the agent cannot write is named as such, with the type; at its own type, the control, it is
# not.
agent_warnings="$(agent_run live-session-mislabelled usr_t)"
assert_msg MSG-T7X3 "${agent_warnings}" "live-session-mislabelled: the directory is named as one the agent cannot write"
if grep -qF 'the config directory of acme carries usr_t' <<<"${agent_warnings}"; then
    pass "live-session-mislabelled: the warning names the type the directory carries"
else
    fail "live-session-mislabelled: the warning does not name usr_t: ${agent_warnings//$'\n'/ | }"
fi
agent_warnings="$(agent_run live-session ai_tools_home_t)"
if grep -qx 'MSG-T7X3' <<<"${agent_warnings}"; then
    fail "live-session: a directory at its own type is named as one the agent cannot write"
else
    pass "live-session: a directory at its own type is not named as one the agent cannot write (control)"
fi

# ── remove: the rules outside the registries, and an unload that reads the store back ────────
# A local rule naming an ai_tools type that no registry walk dropped keeps every module loaded, and the unload's exit
# status once reported `removed` over three. semanage, semodule and restorecon are recorders; the listing is fixture
# rows.
section "install-selinux.sh: remove drops every rule naming a policy type and reports an unload that left a module (unit)"
remove_text=""
for name in warn die _restore_account_tree_labels _warn_left_trees _read_pattern_tree _drop_remaining_policy_type_rules _unload_modules; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install-selinux.sh does not define ${name}() in the form this file reads"
        finish; exit
    fi
    remove_text+="${body}"$'\n'
done
mkdir -p "${TESTDIR}/drop/gone" "${TESTDIR}/drop/app.v1"
# run_drop <state> [nobackstop] : the sweep under that reading over the fixture rows; the recorder holds each semanage
#   delete and each restorecon, one per line, and both streams of the run are printed. The backstop is a stub refusing
#   `/` and a home root, or absent under `nobackstop`.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_drop() {
    : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN="" C_RED="" C_DIM=""
        ok() { printf "ok %s\n" "$*"; }; log() { printf "+ %s\n" "$*"; }
        stub_testdir="$2"; _sandbox_session_state="$3"; _left_trees=()
        SANDBOX_EXEC_LIB=/usr/local/lib/ai-tools/sandbox-exec.lib.sh
        restorecon() { printf "restorecon %s\n" "$*" >> "${stub_testdir}/recorder"; }
        semanage() { [[ "$*" == *"/stuck("* ]] && return 1; printf "semanage %s\n" "$*" >> "${stub_testdir}/recorder"; }
        _locked() { "$@"; }
        [[ "$4" == nobackstop ]] || ai_tools_safe_paths__match_protected_path() { [[ "$1" == / || "$1" =~ ^/home/[^/]+$ ]]; }
        ai_tools_relabel__list_local_rules_naming_policy_types() {
            printf "%s\t%s\t%s\n" \
                "${stub_testdir}/drop/gone(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/gone(/.*)?/(bin|obj)(/.*)?" a ai_tools_project_build_t \
                "/opt/ai-tools/\\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\\.exe" f ai_tools_exec_t \
                "${stub_testdir}/drop/app\\.v1(/.*)?" a ai_tools_project_t \
                "${stub_testdir}/drop/absent(/.*)?" a ai_tools_project_t \
                "/(/.*)?" a ai_tools_project_t \
                "/stuck(/.*)?" a ai_tools_conf_t
        }
        trap _warn_left_trees EXIT
        _drop_remaining_policy_type_rules
    ' _ "${remove_text}" "${TESTDIR}" "$1" "${2:-}" 2>&1 || true
}
drop_out="$(run_drop none)"
recorded="$(<"${TESTDIR}/recorder")"
for want in "semanage fcontext -d -f a -- ${TESTDIR}/drop/gone(/.*)?" \
            "semanage fcontext -d -f a -- ${TESTDIR}/drop/gone(/.*)?/(bin|obj)(/.*)?" \
            'semanage fcontext -d -f f -- /opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/cli/bin/acme\.exe' \
            "semanage fcontext -d -f a -- ${TESTDIR}/drop/absent(/.*)?"; do
    grep -qxF -- "${want}" <<<"${recorded}" && pass "none: dropped under its file-type letter: ${want#semanage fcontext -d -f }" \
        || fail "none: not dropped: ${want} (recorded: ${recorded//$'\n'/ | })"
done
if [[ "$(grep -c '^restorecon ' <<<"${recorded}")" -eq 2 ]] \
        && grep -qxF -- "restorecon -FR ${TESTDIR}/drop/gone" <<<"${recorded}" \
        && grep -qxF -- "restorecon -FR ${TESTDIR}/drop/app.v1" <<<"${recorded}"; then
    pass "none: the tree a project-shaped rule covers is restored, its escaping removed, and a build rule, an entrypoint rule, a tree that is gone and a protected path are not walked"
else
    fail "none: restorecon calls: $(grep '^restorecon ' <<<"${recorded}" | tr '\n' ';')"
fi
# The backstop guards the walk, not the drop: a local rule mapping / to the policy's own type is what the unload refuses
# on, and removing the mapping relabels nothing.
grep -qxF -- "semanage fcontext -d -f a -- /(/.*)?" <<<"${recorded}" \
    && pass "none: a local rule mapping a protected path to the policy's type is dropped (the unload refuses on it) while its tree is not walked" \
    || fail "none: the local ai_tools_project_t rule on / was not dropped"
run_drop none nobackstop >/dev/null
grep -q '^restorecon ' "${TESTDIR}/recorder" && fail "nobackstop: a tree was walked with the backstop absent: $(grep '^restorecon ' "${TESTDIR}/recorder" | tr '\n' ';')" \
    || pass "none, backstop absent: no tree is walked (the backstop fails closed)"
assert_msg MSG-N5W8 "${drop_out}" "none: a rule semanage will not delete is named"
grep -qF -- "semanage fcontext -d -f a -- /stuck" <<<"${drop_out}" \
    && pass "none: the warning gives the delete to run for the rule left" \
    || fail "none: the warning does not give the delete: ${drop_out//$'\n'/ | }"
grep -qF -- "${TESTDIR}/drop/absent" <<<"${drop_out}" && pass "none: each dropped rule is named in the transcript" \
    || fail "none: the dropped rule is not named: ${drop_out//$'\n'/ | }"
drop_out="$(run_drop live)"
recorded="$(<"${TESTDIR}/recorder")"
grep -q '^restorecon ' <<<"${recorded}" && fail "live: a dropped rule's tree was walked: ${recorded//$'\n'/ | }" \
    || pass "live: no tree is walked under a live reading"
assert_msg MSG-U8U4 "${drop_out}" "live: the trees left are named under the closing warning"
grep -qF -- "sudo restorecon -FR ${TESTDIR}/drop/gone" <<<"${drop_out}" && pass "live: the closing warning names a dropped rule's tree" \
    || fail "live: the closing warning does not name ${TESTDIR}/drop/gone: ${drop_out//$'\n'/ | }"

# run_unload <loaded...> : _unload_modules over a store listing the given modules; the stub's `-r` prints libsemanage's
#   progress on stdout, refuses with the content of the refuse file on stderr where one is set, and otherwise clears
#   the store unless UNLOAD_KEEPS is set, which models an exit 0 that left the modules in place. Prints both streams
#   and then `exit=<status>`.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_unload() {
    printf '%s\n' "$@" > "${TESTDIR}/loaded"; : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        eval "$1"
        C_YEL="" C_RST="" C_GRN="" C_RED="" C_DIM=""
        ok() { printf "ok %s\n" "$*"; }; log() { printf "+ %s\n" "$*"; }
        stub_testdir="$2"; _sandbox_session_state=none; _left_trees=()
        _locked() { "$@"; }
        semodule() {
            case "$1" in
                -l) cat "${stub_testdir}/loaded" ;;
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
grep -qF 'left loaded: ai_tools ai_tools_dotnet ai_tools_tmpmap' <<<"${unload_out}" && pass "the refusal names each module left loaded" \
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

# ── the script's text ─────────────────────────────────────────────────────────────────────────
section "the installed library is read first, and no other walk crosses an account-writable tree"

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

# find_ungated_walks <file>: print each code line calling restorecon that is neither the gate's own call nor a walk
# of a root-owned tree, nor a command a warning prints.
# shellcheck disable=SC2016  # the patterns match the literal ${...} text
find_ungated_walks() {
    grep -nE '(^|[^[:alnum:]_-])restorecon[[:space:]]' "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vE 'warn |restorecon -FR "\$1" 2>/dev/null' \
        | grep -vE '"\$\{(LOG_DIR|RUN_DIR)\}"|/usr/local/libexec/ai-tools' || true
}
printf '%s\n' '_restore_one() { restorecon -FR "$1"; }' '    restorecon -FR "${NVM_DIR}"  2>/dev/null || true' \
    > "${TESTDIR}/control.sh"
if [[ "$(find_ungated_walks "${TESTDIR}/control.sh" | grep -c .)" -eq 2 ]]; then
    pass "the reader flags a restorecon of an account-writable tree (control)"
else
    fail "control: the reader does not flag an ungated restorecon, so the check below cannot fail"
fi
found="$(find_ungated_walks "${INSTALLER}")"
[[ -z "${found}" ]] && pass "every restorecon outside the gate names a root-owned tree" \
    || fail "a restorecon crosses a tree the gate does not cover: ${found//$'\n'/ | }"

# remove_guard_order <file>: print `guarded` when the remove action reads the live-session state ahead of its first
# store write (_labels_drop), and `unguarded` otherwise. The action is read from its `remove)` arm to the next `;;`.
remove_guard_order() {
    awk '
        /^  remove\)/ { inside = 1; next }
        inside && /^    ;;/ { exit }
        inside && /_sandbox_session_state/ && /== none/ && !dropped { guard = 1 }
        inside && /_labels_drop/ { dropped = 1; print (guard ? "guarded" : "unguarded"); exit }
    ' "$1"
}
printf '%s\n' '  remove)' '    _locked _labels_drop' '    [[ "${_sandbox_session_state}" == none ]] || die x' '    ;;' \
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
grep -nE 'semodule -r .*2>/dev/null.*\|\| true' "${INSTALLER}" | grep -q . \
    && fail "a semodule -r still nulls its stderr and drops its status: $(grep -nE 'semodule -r .*2>/dev/null.*\|\| true' "${INSTALLER}" | tr '\n' ';')" \
    || pass "no semodule -r in the installer nulls its stderr and drops its status"

finish
