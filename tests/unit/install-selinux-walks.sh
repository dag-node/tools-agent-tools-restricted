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
for name in warn _note_left_agent_config _warn_left_trees verify_agent_labels; do
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
    fail "control: the reader does not flag an ungated restorecon -- the check below is vacuous"
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
    fail "control: the reader does not flag a late guard -- the check below is vacuous"
fi
[[ "$(remove_guard_order "${INSTALLER}")" == guarded ]] \
    && pass "remove refuses on a live-session reading before its first store write" \
    || fail "remove does not read the live-session state ahead of _labels_drop"
grep -qF 'die MSG-H7Q2' "${INSTALLER}" \
    && pass "the remove refusal carries its code" \
    || fail "the remove refusal does not carry MSG-H7Q2"

finish
