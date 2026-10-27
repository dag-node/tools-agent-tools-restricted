#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-selinux-walks.sh
# Hermetic check of selinux/install-selinux.sh's walks over the trees the sandbox account can write: each runs only
# while the live-session reading is `none` (cli.rule.md, ref-section-e6c6), and a walk it leaves is named in one warning
# with the restorecon to run.
#
# The script loads policy and needs root and a whole host, so the functions are read out of the checkout as text
# (extract_function) and run in a fresh bash per reading, with restorecon stubbed as a recorder and the reading set
# to each of `live`, `unreadable` and `none`. _home_state names /opt/ai-tools in its body, which the case rewrites
# to a fixture root, so no host path is read. The script's text is then read for the two properties a function cannot
# show: the installed sandbox-exec.lib.sh is sourced ahead of the relabel library, and every restorecon outside the gate
# names a root-owned tree, held against a control line the reader must flag.
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
for name in warn _restore_account_tree _report_left_trees _home_state _label_sandbox_clones; do
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
        ok() { :; }
        ai_tools_relabel__is_available() { return 0; }
        ai_tools_relabel__is_project_labelled() { printf "%s\n" "$1" >> "${stub_testdir}/verified"; }
        stub_testdir="$2"
        _sessions_state="$3"; _left_trees=()
        SANDBOX_EXEC_LIB=/usr/local/lib/ai-tools/sandbox-exec.lib.sh
        HOME_STATE=(.npm .gitconfig .absent)
        SANDBOX_PROJECTS="$2/clones"
        trap _report_left_trees EXIT
        _home_state
        _label_sandbox_clones
        _restore_account_tree "$2/nvm"
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
    grep -qxF "${TESTDIR}/clones/acme-clone" "${TESTDIR}/verified" \
        && pass "${state}: the clone verify loop still reads each clone" \
        || fail "${state}: the clone verify loop did not run"
done
grep -qF 'sudo ./install.sh install' <<<"${warnings}" \
    && pass "unreadable: the warning names the install that deploys the library the reading needs" \
    || fail "unreadable: the warning does not name sudo ./install.sh install: ${warnings}"

# ── the script's text ─────────────────────────────────────────────────────────────────────────
section "the installed library is read first, and no other walk crosses an account-writable tree"

line_of() { grep -n -m1 -F -- "$1" "${INSTALLER}" | cut -d: -f1; }
exec_lib_line="$(line_of 'source "${SANDBOX_EXEC_LIB}"')"
relabel_lib_line="$(line_of 'source "${RELABEL_LIB}"')"
sessions_lib_line="$(line_of 'source "${SESSIONS_LIB}"')"
if grep -qxF 'SANDBOX_EXEC_LIB="/usr/local/lib/ai-tools/sandbox-exec.lib.sh"' "${INSTALLER}" \
        && [[ -n "${exec_lib_line}" && -n "${relabel_lib_line}" && "${exec_lib_line}" -lt "${relabel_lib_line}" ]]; then
    pass "the installed sandbox-exec.lib.sh is sourced ahead of the relabel library"
else
    fail "the installed sandbox-exec.lib.sh is not sourced ahead of RELABEL_LIB (lines ${exec_lib_line:-none}, ${relabel_lib_line:-none})"
fi
[[ -n "${sessions_lib_line}" && "${sessions_lib_line}" -gt "${relabel_lib_line}" ]] \
    && pass "sessions.lib.sh is sourced beside the relabel library, after it" \
    || fail "sessions.lib.sh is not sourced after RELABEL_LIB (line ${sessions_lib_line:-none})"

# ungated_walks <file>: print each code line calling restorecon that is neither the gate's own call nor a walk
# of a root-owned tree, nor a command a warning prints.
# shellcheck disable=SC2016  # the patterns match the literal ${...} text
ungated_walks() {
    grep -nE '(^|[^[:alnum:]_-])restorecon[[:space:]]' "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vE 'warn |restorecon -FR "\$1" 2>/dev/null' \
        | grep -vE '"\$\{(LOG_DIR|RUN_DIR)\}"|/usr/local/libexec/ai-tools' || true
}
printf '%s\n' '_restore_one() { restorecon -FR "$1"; }' '    restorecon -FR "${NVM_DIR}"  2>/dev/null || true' \
    > "${TESTDIR}/control.sh"
if [[ "$(ungated_walks "${TESTDIR}/control.sh" | grep -c .)" -eq 2 ]]; then
    pass "the reader flags a restorecon of an account-writable tree (control)"
else
    fail "control: the reader does not flag an ungated restorecon -- the check below is vacuous"
fi
found="$(ungated_walks "${INSTALLER}")"
[[ -z "${found}" ]] && pass "every restorecon outside the gate names a root-owned tree" \
    || fail "a restorecon crosses a tree the gate does not cover: ${found//$'\n'/ | }"

finish
