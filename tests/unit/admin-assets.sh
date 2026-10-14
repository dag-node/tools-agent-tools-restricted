#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-assets.sh
# Unit test for the `assets` domain of ai-tools-admin and the Assets section of its `status`: every verb refuses
# before it writes, writes AI_TOOLS_ASSETS through the shared writer with a backup, and exits by the fold
# ai-tools-records(5) states for a command that changes the host -- 1 for a refused or failed write, else 5
# for a library that did not load, else 4 for an attention row, else 0. The helper is SOURCED (its root check and its
# dispatch are guarded for that), in a fresh shell per case because the helper and the harness both declare SANDBOX_USER
# readonly, with the resolver's hooks at fixtures in the testdir and sets signed in the run
# (tests/lib/asset-signing.sh). It drives the installed helper: the checkout's copy carries the sandbox group
# unsubstituted, and a link's chown to that name fails. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
LIB_DIR="/usr/local/lib/ai-tools"
section "ai-tools-admin assets: the verbs and the status section (unit)"
# shellcheck disable=SC2016  # the $1 is the inner shell's
if [[ ! -r "${HELPER}" ]] || ! bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1; declare -F assets_dispatch status_assets >/dev/null' _ "${HELPER}"; then
    fail "${HELPER} is absent or lacks the assets domain; reinstall from this checkout (sudo ./install.sh)"
    finish; exit 1
fi
for tool in gpg gpgv flock; do
    command -v "${tool}" >/dev/null 2>&1 || { skip "admin assets" "${tool} is not installed"; finish; exit 0; }
done
# shellcheck source=/dev/null
source "${LIB_DIR}/assets-verify.lib.sh"

mktestdir
PKG="${TESTDIR}/pkg"; KEYS="${TESTDIR}/keys"; BINDINGS="${TESTDIR}/bindings.d"; HOME_DIR="${TESTDIR}/home"
AGENTS_D="${TESTDIR}/agents.d"; INTEG_D="${TESTDIR}/integrations.d"; CONF="${TESTDIR}/operator.conf"
mkdir -p "${TESTDIR}/local" "${PKG}" "${TESTDIR}/base" "${KEYS}" "${BINDINGS}" "${AGENTS_D}" "${INTEG_D}" "${HOME_DIR}/.acme"
chmod 0755 "${TESTDIR}/local" "${PKG}" "${TESTDIR}/base" "${KEYS}" "${BINDINGS}" "${AGENTS_D}" "${INTEG_D}" "${HOME_DIR}" \
    "${HOME_DIR}/.acme"
export ASSET_KEYS_DIR="${KEYS}" ASSET_BINDINGS_DIR="${BINDINGS}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/asset-signing.sh"
HOOKS=( "AI_TOOLS_ASSETS_ROOTS=${TESTDIR}/local ${PKG} ${TESTDIR}/base" "AI_TOOLS_ASSETS_BINDINGS_DIR=${BINDINGS}"
        "AI_TOOLS_ASSETS_LOCK=${TESTDIR}/lock/assets.lock" "AI_TOOLS_ASSETS_HOME=${HOME_DIR}" "AI_TOOLS_OPERATOR_CONF=${CONF}"
        "AI_TOOLS_AGENTS_DIR=${AGENTS_D}" "AI_TOOLS_INTEGRATIONS_DIR=${INTEG_D}" )
printf 'npm_package=@fixture/acme\nlauncher=acme\nconfig_dir=.acme\nskills_dir=skills\nsubagents_dir=agents\ndefault_enable=no\n' \
    > "${AGENTS_D}/acme.conf"
chmod 0644 "${AGENTS_D}/acme.conf"
asset_signing_gen_key SIGNER signer
asset_signing_write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
asset_signing_write_binding acme-two "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
SKILL="acme/skills/acme-pdf"; SUB="acme/subagents/acme-reviewer"

# write_conf <entry>... : operator.conf enabling the agent acme and listing the entries, root-owned 0644, every earlier
# backup beside it removed.
write_conf() {
    local entries="" entry
    for entry in "$@"; do entries+="${entries:+, }${entry}"; done
    rm -f "${CONF}".*.bak
    printf '# fixture\nAI_TOOLS_AGENTS=[agent-acme]\nAI_TOOLS_ASSETS=[%s]\n' "${entries}" > "${CONF}"
    chown root:root "${CONF}"; chmod 0644 "${CONF}"
}
# fresh : the set acme in the packaged root, the list empty, no view.
fresh() {
    rm -rf "${PKG:?}"/* "${HOME_DIR}/skills" "${HOME_DIR}/subagents" "${HOME_DIR}"/.acme/*
    asset_signing_build_set "${PKG}" acme
    write_conf
}

# admin <words>... : run `ai-tools-admin <words>` through the sourced helper's dispatch, with the hooks; the record
# stream in OUT, stderr in ERR, the exit in RC. `unload` as the first word removes the resolver after the helper loaded
# it, which the include guard keeps the verb's own load from restoring. PRELUDE, when set, is evaluated
# after the libraries load, to stub what a case drives; a case sets it for one call and clears it.
OUT=""; ERR=""; RC=0; PRELUDE=""
admin() {
    local unload=0 err
    [[ "${1:-}" == unload ]] && { unload=1; shift; }
    err="$(mktemp "${TESTDIR}/err.XXXXXX")"
    RC=0
    # shellcheck disable=SC2016
    OUT="$(env "${HOOKS[@]}" bash -c 'helper="$1"; lib="$2"; unload="$3"; prelude="$4"; shift 4; words=( "$@" ); set --
        source "${helper}" >/dev/null 2>&1 || exit 99
        source "${lib}" 2>/dev/null || true
        (( unload )) && unset -f ai_tools_assets__reconcile
        eval "${prelude}"
        case "${words[0]}" in
            status_assets) STATUS_PROBLEMS=0; STATUS_UNREADABLE=0; status_assets
                           printf "problems=%s unreadable=%s\n" "${STATUS_PROBLEMS}" "${STATUS_UNREADABLE}" ;;
            *)             assets_dispatch "${words[@]:1}" ;;
        esac' _ "${HELPER}" "${LIB_DIR}/assets.lib.sh" "${unload}" "${PRELUDE:-:}" "$@" 2>"${err}")" || RC=$?
    ERR="$(<"${err}")"
    rm -f -- "${err}"
}
# refused <code> <status> <what> : the last call exited <status> with <code> on its own line.
refused() {
    if [[ "${RC}" == "$2" ]]; then pass "$3 -> exit $2"; else fail "$3 -> exit ${RC}, want $2: ${ERR:0:300}"; fi
    assert_msg "$1" "${ERR}" "$3 is reported under $1"
}
# listed : the AI_TOOLS_ASSETS line as written.
listed() { grep -E '^AI_TOOLS_ASSETS=' "${CONF}" || true; }
# finding_of <id> : the finding of the first row whose item carries <id>.
finding_of() { awk -F'\t' -v id="$1" 'NR > 1 && index($9, id) { print $6; exit }' <<< "${OUT}"; }
# state_of <id> : the finding of the reconcile's row for the enable-list entry <id> (MSG-Z3P6, the item <id> alone),
# which the stream writes after the verb's own row for the same identifier.
state_of() { awk -F'\t' -v id="$1" 'NR > 1 && $3 == "MSG-Z3P6" && $9 == id { print $6; exit }' <<< "${OUT}"; }

# ── enable refuses before it writes ──────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets enable: every argument is checked before a write"
fresh
before="$(cat "${CONF}")"
for bad in "Bad/skills/x" "acme/agents/acme-reviewer" "acme/orientation/x" "acme/skills"; do
    admin assets enable "${SKILL}" "${bad}"
    refused MSG-E9D6 1 "enable with ${bad} among good identifiers"
    [[ "$(cat "${CONF}")" == "${before}" ]] && pass "${bad}: operator.conf is byte-identical" || fail "${bad}: operator.conf changed"
done
admin assets enable acme/agents/acme-reviewer
[[ "${ERR}" == *subagents* ]] && pass "acme/agents/... names the subagents spelling" || fail "the agents refusal does not name subagents: ${ERR:0:200}"
admin assets enable acme-free/skills/x
refused MSG-W6D7 1 "a set no shipped binding names"
[[ "$(cat "${CONF}")" == "${before}" ]] && pass "an unbound set: operator.conf is byte-identical" || fail "an unbound set: operator.conf changed"
chmod 0664 "${CONF}"; admin assets enable "${SKILL}"
refused MSG-K6K3 1 "an operator.conf the trust predicate refuses"
[[ "$(cat "${CONF}")" == "${before}" ]] && pass "an untrusted operator.conf is not written" || fail "an untrusted operator.conf was written"
chmod 0644 "${CONF}"
printf 'AI_TOOLS_ASSETS=[a, b\n' >> "${CONF}"; before="$(cat "${CONF}")"; admin assets enable "${SKILL}"
refused MSG-B4Z5 1 "an AI_TOOLS_ASSETS that is not a valid list"
[[ "$(cat "${CONF}")" == "${before}" ]] && pass "an invalid list is not rewritten" || fail "an invalid list was rewritten"
# The reader fails as for a file not read whole, for the verbs' own read alone: the set walk and the plan read normally.
READ_FAILS='eval "$(declare -f ai_tools_conf__read_list | sed "1s/^ai_tools_conf__read_list/_stub_read_list_real/")"
    ai_tools_conf__read_list() { [[ "${FUNCNAME[1]}" == assets_read_list ]] && return 2; _stub_read_list_real "$@"; }'
for words in "enable ${SUB}" "enable --set acme" "disable ${SKILL}"; do
    fresh
    write_conf "${SKILL}"
    before="$(cat "${CONF}")"
    PRELUDE="${READ_FAILS}"
    # shellcheck disable=SC2086  # the verb and its arguments split on purpose
    admin assets ${words}
    PRELUDE=""
    refused MSG-C7N4 1 "assets ${words} over a file the reader could not read whole"
    if [[ "$(cat "${CONF}")" == "${before}" ]] && ! compgen -G "${CONF}.*.bak" >/dev/null; then
        pass "assets ${words}: operator.conf is byte-identical and no backup was made"
    else
        fail "assets ${words}: operator.conf changed or a backup was made: '$(listed)'"
    fi
done
fresh
printf '# fixture\nAI_TOOLS_AGENTS=[agent-acme]\n' > "${CONF}"; chown root:root "${CONF}"; chmod 0644 "${CONF}"
admin assets enable "${SKILL}"
[[ "${RC}" == 0 && "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}]" ]] && pass "a file without the key still reads as the empty list and enables" \
    || fail "an enable over a file without the key: rc ${RC}, '$(listed)': ${ERR:0:300}"

# ── enable writes and links ──────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets enable: the write, the backup, the reconcile"
fresh
admin assets enable "${SKILL}" "${SUB}"
if [[ "${RC}" == 0 && "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, ${SUB}]" ]]; then
    pass "enable writes each identifier in order and exits 0"
else
    fail "enable: rc ${RC}, line '$(listed)': ${ERR:0:300}"
fi
compgen -G "${CONF}.*.bak" >/dev/null && pass "a dated .bak exists after the write" || fail "no .bak beside operator.conf"
[[ "$(readlink "${HOME_DIR}/skills/acme-pdf")" == "${PKG}/acme/skills/acme-pdf" ]] && pass "the reconcile linked the asset" \
    || fail "the view holds $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"
[[ "$(state_of "${SKILL}")" == linked ]] && pass "the record stream carries the entry linked" || fail "rows: ${OUT:0:300}"
admin assets enable "${SKILL}"
[[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, ${SUB}]" ]] && pass "an identifier already listed is not added twice" \
    || fail "a second enable wrote '$(listed)'"
admin assets enable acme-two/skills/acme-two-pdf
if [[ "${RC}" == 4 && "$(state_of acme-two/skills/acme-two-pdf)" == set-absent && "$(listed)" == *acme-two/skills/acme-two-pdf* ]]; then
    pass "a pending identifier of a bound set is accepted, reported set-absent, exit 4"
else
    fail "a pending identifier: rc ${RC}, '$(state_of acme-two/skills/acme-two-pdf)', '$(listed)'"
fi

# ── the line is written sorted ───────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets: AI_TOOLS_ASSETS is written sorted by kind, set and name"
fresh
admin assets enable "${SUB}"; admin assets enable "${SKILL}"; admin assets enable acme-two/skills/acme-two-pdf
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, acme-two/skills/acme-two-pdf, ${SUB}]" ]]; then
    pass "three enables write one line sorted by kind, then set, then name"
else
    fail "the sorted line: '$(listed)'"
fi
write_conf "${SUB}" acme-two/skills/acme-two-pdf "${SKILL}"
before="$(cat "${CONF}")"
admin assets enable "${SKILL}"
if [[ "$(cat "${CONF}")" == "${before}" ]] && ! compgen -G "${CONF}.*.bak" >/dev/null; then
    pass "an enable that adds no identifier leaves a hand-written order and does not write a .bak"
else
    fail "an enable of a listed identifier rewrote the file: '$(listed)'"
fi
admin assets disable acme-two/skills/acme-two-pdf
[[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, ${SUB}]" ]] && pass "a disable writes the kept entries sorted" \
    || fail "the line after a disable: '$(listed)'"

# ── enable, the set form ──────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets enable --set: a snapshot of the set"
fresh
mkdir -p "${PKG}/acme/skills/acme-bad"; printf -- '---\nname: acme-bad\n---\n' > "${PKG}/acme/skills/acme-bad/SKILL.md"
asset_signing_seal "${PKG}/acme"
admin assets enable --set acme
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, ${SUB}]" ]]; then
    pass "--set writes each valid asset of the set, and no other"
else
    fail "--set wrote '$(listed)': ${ERR:0:300}"
fi
[[ "$(finding_of acme/skills/acme-bad)" == asset-invalid ]] && pass "an invalid asset is reported and left out" || fail "rows: ${OUT:0:400}"
written="$(awk -F'\t' 'NR > 1 && $3 == "MSG-Z3P6" && $5 != "info" && $7 == "file" && index($9, "acme/") { print $9 }' <<< "${OUT}" | LC_ALL=C sort | tr '\n' ' ')"
[[ "${written}" == "${SKILL} ${SUB} " ]] && pass "the identifiers printed equal the identifiers written" || fail "printed '${written}'"
[[ "${RC}" == 4 ]] && pass "--set with an invalid asset exits 4" || fail "--set exit ${RC}"
fresh
rm "${PKG}/acme/SHA256SUMS.asc"; before="$(cat "${CONF}")"
admin assets enable --set acme
refused MSG-P9Z3 1 "--set over an unverified set"
[[ "$(cat "${CONF}")" == "${before}" ]] && pass "an unverified set: nothing written" || fail "an unverified set: operator.conf changed"
admin assets enable --set
refused MSG-Z7D4 2 "--set with no set name"

# ── disable ──────────────────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets disable"
fresh
admin assets enable "${SKILL}" "${SUB}"
admin assets disable "${SKILL}" acme/skills/acme-other
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[${SUB}]" && "${RC}" == 4 ]]; then
    pass "disable removes the named entry, reports one the list does not hold, exit 4"
else
    fail "disable: rc ${RC}, '$(listed)': ${ERR:0:300}"
fi
[[ "$(finding_of acme/skills/acme-other)" == not-enabled ]] && pass "the unknown identifier is reported not-enabled" || fail "rows: ${OUT:0:300}"
if [[ ! -e "${HOME_DIR}/skills/acme-pdf" && ! -L "${HOME_DIR}/skills/acme-pdf" && ! -L "${HOME_DIR}/.acme/skills/acme-pdf" ]]; then
    pass "the disabled asset leaves the view and the agent's directory in the same call"
else
    fail "a link is left after disable"
fi
[[ -L "${HOME_DIR}/subagents/acme-reviewer.md" ]] && pass "the other entry stays linked" || fail "the other entry lost its link"

# ── the list edit's own rows ─────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets: the list edit is named enabled and disabled"
# list_edit_rows <code> : the finding, subject and item of each row under <code>, one per line, tab-separated.
list_edit_rows() { awk -F'\t' -v code="$1" 'NR > 1 && $3 == code { print $6 "\t" $10 "\t" $9 }' <<< "${OUT}"; }
fresh
admin assets enable "${SKILL}"
admin assets enable "${SKILL}" "${SUB}"
rows="$(list_edit_rows MSG-N3M8)"
if [[ "${rows}" == "enabled"$'\t'"${CONF}"$'\t'*"${SUB}"* && "$(wc -l <<< "${rows}")" == 1 ]]; then
    pass "an enable writes one enabled row per identifier it added, subject operator.conf, and none for one listed"
else
    fail "the enable's list-edit rows: '${rows}'"
fi
admin assets disable "${SKILL}"
rows="$(list_edit_rows MSG-Q2C6)"
if [[ "${rows}" == "disabled"$'\t'"${CONF}"$'\t'*"${SKILL}"* ]]; then
    pass "a disable's list-edit row carries disabled"
else
    fail "the disable's list-edit row: '${rows}'"
fi
# code_rows <code> : how many rows of the last stream carry <code>.
code_rows() { awk -F'\t' -v code="$1" 'NR > 1 && $3 == code { n++ } END { print n + 0 }' <<< "${OUT}"; }
for shape in "${SKILL} ${SUB}" "${SKILL} ${SKILL} ${SUB}"; do
    fresh
    # shellcheck disable=SC2086  # the entries split on purpose
    write_conf ${shape}
    admin assets disable "${SKILL}" "${SKILL}"
    if [[ "$(code_rows MSG-Q2C6)" == 1 && "$(listed)" == "AI_TOOLS_ASSETS=[${SUB}]" ]]; then
        pass "disable naming an identifier twice over [${shape}]: one disabled row, every occurrence removed"
    else
        fail "disable twice over [${shape}]: $(code_rows MSG-Q2C6) disabled row(s), '$(listed)'"
    fi
done
admin assets disable acme/skills/acme-z acme/skills/acme-z
[[ "$(code_rows MSG-Q5T6)" == 1 ]] && pass "disable naming an absent identifier twice: one not-enabled row" \
    || fail "disable of an absent identifier twice: $(code_rows MSG-Q5T6) not-enabled row(s)"
fresh
admin assets enable "${SKILL}" "${SKILL}"
if [[ "$(code_rows MSG-N3M8)" == 1 && "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}]" ]]; then
    pass "enable naming an identifier twice: one enabled row, one entry"
else
    fail "enable twice: $(code_rows MSG-N3M8) enabled row(s), '$(listed)'"
fi

# ── The order of the stream ──────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets: the stream is sorted by kind, set and name"
# stream_labels : one `<finding> <subject>` per row of the last stream, in its order.
stream_labels() { awk -F'\t' 'NR > 1 { print $6 " " $10 }' <<< "${OUT}"; }
fresh
asset_signing_build_set "${PKG}" acme-two
write_conf acme-two/subagents/acme-two-reviewer "${SUB}" acme-two/skills/acme-two-pdf "${SKILL}"
admin assets reconcile
admin assets disable "${SKILL}"
want="disabled ${CONF}
unlinked ${HOME_DIR}/skills/acme-pdf
unlinked ${HOME_DIR}/.acme/skills/acme-pdf
linked ${HOME_DIR}/skills/acme-two-pdf
linked ${HOME_DIR}/subagents/acme-reviewer.md
linked ${HOME_DIR}/subagents/acme-two-reviewer.md"
if [[ "$(stream_labels)" == "${want}" ]]; then
    pass "a disable's rows: the list edit, the view link, the agent link adjacent, then kind, set and name order"
else
    fail "the disable's stream order: $(stream_labels | tr '\n' '|')"
fi
PRELUDE='ai_tools_providers__list_enabled_agents() { return 2; }'; admin assets disable "${SUB}"; PRELUDE=""
first="$(awk -F'\t' 'NR == 2 { print $6 }' <<< "${OUT}")"
[[ "${first}" == receivers-unknown ]] && pass "a row without a kind comes first" || fail "the first row is '${first}': $(stream_labels | tr '\n' '|')"
fresh
write_conf "${SKILL}"
PRELUDE='ai_tools_conf__set_list() { return 1; }'; admin assets disable "${SKILL}" acme/skills/acme-other; PRELUDE=""
refused MSG-Q8E5 1 "a write that fails"
[[ "$(finding_of acme/skills/acme-other)" == not-enabled ]] && pass "a write that fails still writes the rows the verb recorded" \
    || fail "rows after a failed write: ${OUT:0:300}"
fresh
write_conf "${SUB}" "${SKILL}"
# The stub fails the record stream's sort, keyed from the first field, and leaves the set walk's.
PRELUDE='sort() { case " $* " in *" -k1,1 "*) return 1 ;; esac; command sort "$@"; }'
admin assets enable acme/skills/acme-other-pdf; PRELUDE=""
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[acme/skills/acme-other-pdf, ${SKILL}, ${SUB}]" ]]; then
    pass "a sort process that fails does not reach AI_TOOLS_ASSETS, which is written sorted"
else
    fail "with sort failing, the enable wrote '$(listed)'"
fi
assert_msg MSG-Y8T3 "${ERR}" "a row sort that fails is reported under MSG-Y8T3"
[[ "$(finding_of acme/skills/acme-other-pdf)" == enabled && "$(state_of "${SUB}")" == linked ]] \
    && pass "a row sort that fails still writes every row" || fail "rows after a failed sort: $(stream_labels | tr '\n' '|')"
# row_identities : `<code> <finding> <subject> <item>` of each row of the last stream, sorted, so two streams compare
# as sets with their multiplicities.
row_identities() { awk -F'\t' 'NR > 1 { print $3 " " $6 " " $10 " " $9 }' <<< "${OUT}" | LC_ALL=C sort; }
# A sort whose output is not each row once: each stub runs the real sort on the record stream's keys, keyed
# from the first field, then repeats a line in place of the next, puts a reference to no row in place of one, or adds
# a line.
for corruption in 'NR == 1 { first = $0 } NR == 2 { print first; next } { print }' \
                  'NR == 2 { print "x\tx\tx\t0\tx\t0\trecorded\t99"; next } { print }' \
                  '{ print; last = $0 } END { print last }'; do
    fresh
    write_conf "${SUB}" "${SKILL}"
    admin assets reconcile
    admin assets disable "${SKILL}" acme/skills/acme-other
    want="$(row_identities)"
    fresh
    write_conf "${SUB}" "${SKILL}"
    admin assets reconcile
    printf -v PRELUDE 'sort() { case " $* " in *" -k1,1 "*) command sort "$@" | awk %q ;; *) command sort "$@" ;; esac; }' "${corruption}"
    admin assets disable "${SKILL}" acme/skills/acme-other; PRELUDE=""
    if [[ "${RC}" == 4 && -n "${want}" && "$(row_identities)" == "${want}" ]]; then
        pass "a sort printing '${corruption:0:24}...': every row written once, the attention row folding to exit 4"
    else
        fail "a sort printing '${corruption:0:24}...': rc ${RC}, rows $(row_identities | tr '\n' '|') want $(tr '\n' '|' <<< "${want}")"
    fi
    assert_msg MSG-Y8T3 "${ERR}" "that sort is reported under MSG-Y8T3"
done
# A list edit that loses an entry before the write: the identifier sort stubbed to drop the first one it holds.
for verb in enable disable; do
    fresh
    write_conf "${SUB}" "${SKILL}"
    before="$(cat "${CONF}")"
    PRELUDE='assets_sort_identifiers() { local -n _stub_ids="$1"; _stub_ids=( "${_stub_ids[@]:1}" ); }'
    if [[ "${verb}" == enable ]]; then admin assets enable acme/skills/acme-other-pdf; else admin assets disable acme/skills/acme-gone "${SKILL}"; fi
    PRELUDE=""
    refused MSG-S4M7 1 "${verb}: a list that lost an entry before the write"
    backups=( "${CONF}".*.bak )
    if [[ "$(cat "${CONF}")" == "${before}" && ! -e "${backups[0]}" ]]; then
        pass "${verb}: operator.conf is byte-identical and no backup was made"
    else
        fail "${verb}: operator.conf changed or a backup was made: '$(listed)'"
    fi
done
[[ "$(finding_of acme/skills/acme-gone)" == not-enabled ]] && pass "the refusal still writes the rows the verb recorded" \
    || fail "rows beside the refusal: ${OUT:0:300}"

# ── Two verbs at once ────────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets: two verbs at once each read the list the other wrote"
# PAUSE holds a verb for two seconds after it read AI_TOOLS_ASSETS: under the lock taken before the read, the other verb
# waits and then reads the list this one wrote.
PAUSE='eval "$(declare -f assets_read_list | sed "1s/^assets_read_list/_assets_read_list_unpaused/")"
    assets_read_list() { _assets_read_list_unpaused "$@"; sleep 2; }'
fresh
asset_signing_build_set "${PKG}" acme-two
( PRELUDE="${PAUSE}"; admin assets enable "${SKILL}"; printf '%s\n' "${RC}" > "${TESTDIR}/rc-first" ) &
first=$!
sleep 0.5
admin assets enable acme-two/skills/acme-two-pdf
wait "${first}" || true
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, acme-two/skills/acme-two-pdf]" ]]; then
    pass "two enables at once: the list holds both, in the order the lock gave them"
else
    fail "two enables at once wrote '$(listed)' (rc $(cat "${TESTDIR}/rc-first") and ${RC})"
fi
backups=( "${CONF}".*.bak )
if (( ${#backups[@]} == 2 )) && [[ "${backups[0]}" != "${backups[1]}" ]]; then
    pass "two enables at once: two distinct backups"
else
    fail "two enables at once left ${#backups[@]} backup(s): ${backups[*]}"
fi
fresh
asset_signing_build_set "${PKG}" acme-two
admin assets enable "${SKILL}" "${SUB}"
( PRELUDE="${PAUSE}"; admin assets disable "${SUB}" ) &
first=$!
sleep 0.5
admin assets enable acme-two/skills/acme-two-pdf
wait "${first}" || true
if [[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, acme-two/skills/acme-two-pdf]" ]]; then
    pass "a disable beside an enable: the disabled entry stays removed and the enabled one is added"
else
    fail "a disable beside an enable wrote '$(listed)'"
fi

# ── No set asset enabled ─────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets reconcile: a host that enables no set asset keeps base's seeded copies"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/etc/ai-tools/operator.conf"
for shape in "a trusted file without the key" "the shipped template" "AI_TOOLS_ASSETS=[]"; do
    fresh
    case "${shape}" in
        "a trusted file without the key") printf '# fixture\nAI_TOOLS_AGENTS=[agent-acme]\n' > "${CONF}" ;;
        "the shipped template")
            if [[ ! -r "${TEMPLATE}" ]]; then skip "${shape}" "no checkout holds ${TEMPLATE}"; continue; fi
            sed 's/@PROJECTS_USER@/root/' "${TEMPLATE}" > "${CONF}" ;;
        *) write_conf ;;
    esac
    chown root:root "${CONF}"; chmod 0644 "${CONF}"
    mkdir -p "${HOME_DIR}/skills/ai-tools-seeded"
    printf -- '---\nname: ai-tools-seeded\nx-ai-tools-managed: true\n---\n' > "${HOME_DIR}/skills/ai-tools-seeded/SKILL.md"
    admin assets reconcile
    attention="$(awk -F'\t' 'NR > 1 && ($5 == "attention" || $5 == "unreadable")' <<< "${OUT}")"
    if [[ "${RC}" == 0 && -z "${attention}" && -d "${HOME_DIR}/skills/ai-tools-seeded" ]]; then
        pass "${shape}: exit 0, no row needing attention, the seeded copy kept"
    else
        fail "${shape}: rc ${RC}: ${attention:-${ERR:0:300}}"
    fi
    if [[ "${shape}" != "the shipped template" ]]; then
        [[ "$(readlink "${HOME_DIR}/.acme/skills/ai-tools-seeded")" == "${HOME_DIR}/skills/ai-tools-seeded" ]] \
            && pass "${shape}: the enabled agent links the seeded copy" || fail "${shape}: the seeded copy is not linked for acme"
    fi
done

# ── The exit fold, the usage refusals ────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets: the exit fold and the usage refusals"
fresh
admin unload assets reconcile
refused MSG-P8M5 5 "a resolver that did not load"
admin assets list extra
refused MSG-F3D9 2 "list with an argument"
admin assets bogus
refused MSG-D4S7 2 "an unknown assets verb"
admin assets reconcile extra
refused MSG-M7S5 2 "reconcile with an argument"
admin assets enable
refused MSG-N5U6 2 "enable with no identifier"
admin assets disable
refused MSG-H7A8 2 "disable with no identifier"
write_conf "${SKILL}"
admin assets reconcile
[[ "${RC}" == 0 ]] && pass "a reconcile with every entry linked exits 0" || fail "reconcile exit ${RC}: ${ERR:0:200}"

# ── assets list ──────────────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin assets list: the state and each pending change, without a write"
# rows_without_times : the last stream without its observed-at column, which differs between two runs.
rows_without_times() { cut -f2- <<< "${OUT}"; }
# pending_rows : `<finding> <subject> <severity>` of each pending row of the last stream.
pending_rows() { awk -F'\t' 'NR > 1 && $6 ~ /-pending$/ { print $6 " " $10 " " $5 }' <<< "${OUT}"; }
fresh
write_conf "${SKILL}" "${SUB}"
admin assets reconcile
admin assets list; listed_stream="$(rows_without_times)"; list_rc="${RC}"
admin assets; bare_stream="$(rows_without_times)"
[[ "${bare_stream}" == "${listed_stream}" && -n "${listed_stream}" ]] && pass "a bare assets prints the stream assets list prints" \
    || fail "a bare assets and assets list differ: ${bare_stream:0:200} / ${listed_stream:0:200}"
linked_rows="$(awk -F'\t' 'NR > 1 && $3 == "MSG-W5Q3" && $5 == "ok" && $6 == "linked"' <<< "${OUT}" | wc -l)"
if [[ "${list_rc}" == 0 && "${linked_rows}" == 2 && -z "$(pending_rows)" ]]; then
    pass "after a clean reconcile: exit 0, one ok linked row per entry, no pending row"
else
    fail "after a clean reconcile: rc ${list_rc}, ${linked_rows} linked row(s), pending '$(pending_rows)'"
fi
snapshot() { find "${HOME_DIR}" "${CONF}" -printf '%p %y %l %m %s\n' | LC_ALL=C sort; }
rm -f "${HOME_DIR}/.acme/skills/acme-pdf"
before="$(snapshot)"
admin assets list
if [[ "${RC}" == 4 && "$(pending_rows)" == "link-pending ${HOME_DIR}/.acme/skills/acme-pdf attention" \
        && "$(awk -F'\t' -v id="${SKILL}" 'NR > 1 && $3 == "MSG-W5Q3" && $9 == id { print $6; exit }' <<< "${OUT}")" == linked ]]; then
    pass "an agent link removed by hand: exit 4, one link-pending row for its path, the entry still linked"
else
    fail "a missing agent link: rc ${RC}, pending '$(pending_rows)'"
fi
# The item's components are the identifier and the agent, joined by a tab the stream writes as `\t`.
[[ "$(awk -F'\t' '$6 == "link-pending" { print $9 }' <<< "${OUT}")" == "${SKILL}"'\tacme' ]] && pass "the link-pending row names the agent" \
    || fail "the link-pending row's item: $(awk -F'\t' '$6 == "link-pending" { print $9 }' <<< "${OUT}")"
[[ "$(snapshot)" == "${before}" ]] && pass "list does not write: the view, the agent's directory and operator.conf are as they were" \
    || fail "list changed the host"
admin assets reconcile; admin assets list
[[ "${RC}" == 0 && -z "$(pending_rows)" ]] && pass "a reconcile places the link and list returns to exit 0" \
    || fail "after the reconcile: rc ${RC}, pending '$(pending_rows)'"
ln -s "${PKG}/acme/skills/acme-pdf" "${HOME_DIR}/skills/acme-stray"
admin assets list
[[ "${RC}" == 4 && "$(pending_rows)" == "unlink-pending ${HOME_DIR}/skills/acme-stray attention" ]] \
    && pass "a resolver link no entry justifies: unlink-pending, exit 4" || fail "a stray link: rc ${RC}, pending '$(pending_rows)'"
rm -f "${HOME_DIR}/skills/acme-stray"
mkdir -p "${TESTDIR}/lock"
( flock 9; sleep 6 ) 9>>"${TESTDIR}/lock/assets.lock" &
holder=$!
sleep 0.5
started="${SECONDS}"; admin assets list; elapsed=$(( SECONDS - started ))
wait "${holder}" || true
[[ "${RC}" == 0 ]] && (( elapsed < 4 )) && pass "list beside a held lock returns without waiting (${elapsed}s)" \
    || fail "list beside a held lock: rc ${RC} after ${elapsed}s: ${ERR:0:200}"

# ── The status section ───────────────────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin status: the Assets section"
fresh
admin status_assets
if grep -qE '\[OK\] +0 asset\(s\) enabled in AI_TOOLS_ASSETS, 0 linked' <<< "${OUT}" && [[ "${OUT}" == *problems=0* ]]; then
    pass "a host with no entry prints the OK line with a count of zero"
else
    fail "zero entries: ${OUT:0:300}"
fi
write_conf "${SKILL}" acme-two/skills/acme-two-pdf "acme/agents/x"
admin assets reconcile
printf 'tampered\n' >> "${PKG}/acme/README.md"
snapshot() { find "${HOME_DIR}" -printf '%p %y %l %m\n' | LC_ALL=C sort; }
before="$(snapshot)"
admin status_assets
for token in set-tampered set-absent kind-unknown; do
    grep -qE "\[ATTENTION\] +[^ ]+ +${token}" <<< "${OUT}" && pass "status renders ${token} as an ATTENTION line" \
        || fail "status: no ATTENTION line for ${token}: ${OUT:0:400}"
done
[[ "${OUT}" == *problems=3* ]] && pass "each such line counts toward the exit" || fail "status counted: ${OUT##*problems=}"
mkdir -p "${HOME_DIR}/skills/foreign"; admin status_assets; rmdir "${HOME_DIR}/skills/foreign"
order="$(grep -oE '\[ATTENTION\] +[^ ]+ +[^ ]+' <<< "${OUT}" | awk '{ print $2 " " $3 }')"
want="acme/agents/x kind-unknown
view-foreign ${HOME_DIR}/skills/foreign
${SKILL} set-tampered
acme-two/skills/acme-two-pdf set-absent"
[[ "${order}" == "${want}" ]] && pass "the Assets section's lines come in the stream's order" \
    || fail "the Assets section's order: $(tr '\n' '|' <<< "${order}")"
[[ "$(snapshot)" == "${before}" ]] && pass "the status section does not write: the view is as it was" || fail "status changed the view"
chmod 0664 "${CONF}"; admin status_assets
grep -q 'enable-list-untrusted' <<< "${OUT}" && pass "an untrusted operator.conf renders enable-list-untrusted" || fail "untrusted: ${OUT:0:300}"
chmod 0644 "${CONF}"
PRELUDE='ai_tools_providers__list_enabled_agents() { return 2; }'; admin status_assets; PRELUDE=""
if grep -qE '\[UNREADABLE\] +receivers-unknown' <<< "${OUT}" && [[ "${OUT}" == *unreadable=1* ]]; then
    pass "a provider reader that fails renders an UNREADABLE line, counted as a reading the section could not make"
else
    fail "a failed provider reader: ${OUT:0:400}"
fi
fresh
printf 'skills_root=%s\n' "${TESTDIR}/etc-acme/skills" >> "${AGENTS_D}/acme.conf"
mkdir -p "${TESTDIR}/etc-acme"
admin status_assets
if ! grep -q 'agent-root' <<< "${OUT}" && [[ "${OUT}" == *problems=0* ]]; then
    pass "an absent skills_root is an info row, which the section does not print or count"
else
    fail "an absent skills_root: ${OUT:0:400}"
fi
mkdir "${TESTDIR}/etc-acme/skills"; admin status_assets
if grep -qE "\[ATTENTION\] +agent-root-foreign +${TESTDIR}/etc-acme/skills" <<< "${OUT}" && [[ "${OUT}" == *problems=1* ]]; then
    pass "a real directory at skills_root renders agent-root-foreign as an ATTENTION line, counted"
else
    fail "a real directory at skills_root: ${OUT:0:400}"
fi
sed -i '/^skills_root=/d' "${AGENTS_D}/acme.conf"
# The status section's own probe is ai_tools_assets__plan, which `unload` leaves; drive the missing library through it.
# shellcheck disable=SC2016
OUT="$(env "${HOOKS[@]}" bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1
    source /usr/local/lib/ai-tools/assets.lib.sh 2>/dev/null; unset -f ai_tools_assets__plan
    STATUS_PROBLEMS=0; STATUS_UNREADABLE=0; status_assets; printf "unreadable=%s\n" "${STATUS_UNREADABLE}"' _ "${HELPER}" 2>&1)"
[[ "${OUT}" == *UNREADABLE* && "${OUT}" == *unreadable=1* ]] && pass "a library that did not load is a reading the section could not make" \
    || fail "an unloaded library: ${OUT:0:300}"

# ── The withdrawn-successor notice ───────────────────────────────────────────────────────────────────────────────────
section "ai-tools-admin status: successor-unenabled, the notice an upgrade leaves"
# write_conf_unset : operator.conf enabling the agent acme without an AI_TOOLS_ASSETS line, as a pre-0.24.0 file reads.
write_conf_unset() {
    rm -f "${CONF}".*.bak
    printf '# fixture\nAI_TOOLS_AGENTS=[agent-acme]\n' > "${CONF}"
    chown root:root "${CONF}"; chmod 0644 "${CONF}"
}
# retire <name> : a withdrawn copy under the fixture view's retired directory, as the withdrawal pass names it.
retire() { install -d -o root -g root -m 0700 "${HOME_DIR}/retired"; mkdir -p "${HOME_DIR}/retired/$1.20261011-1.retired"; }
# summary_line : the line status_assets printed last, ahead of the counts the driver appends.
summary_line() { tail -n 2 <<< "${OUT}" | head -n 1; }
notice_row() { grep -E '\[ATTENTION\] +successor-unenabled +core -- ' <<< "${OUT}" || true; }

fresh; rm -rf "${HOME_DIR}/retired"; write_conf_unset; retire ai-tools-technical-docs; retire ai-tools-reftags
admin status_assets
row="$(notice_row)"
if [[ "${row}" == *"ai-tools-technical-docs, ai-tools-reftags withdrawn"* && "${row}" == *"AI_TOOLS_ASSETS is not set"* \
        && "${OUT}" == *"sudo dnf install ai-tools-assets-core && sudo ai-tools-admin assets enable --set core"* \
        && "${OUT}" == *"AI_TOOLS_ASSETS=[] in ${CONF}"* && "${OUT}" == *"problems=1 unreadable=0"* ]]; then
    pass "a retired copy with a successor and no AI_TOOLS_ASSETS line: one successor-unenabled row naming both, counted"
else
    fail "the notice: ${OUT:0:600}"
fi
if [[ "$(summary_line)" == "    Summary: 1 finding needs attention in this section (exit 4)" ]]; then
    pass "the section closes with the summary line, its last line, naming the one finding and exit 4"
else
    fail "the closing line: '$(summary_line)'"
fi
install -d -m 0755 "${PKG}/core"; : > "${PKG}/core/set.conf"; admin status_assets
if [[ -n "$(notice_row)" && "${OUT}" != *"dnf install"* && "${OUT}" == *"sudo ai-tools-admin assets enable --set core"* ]]; then
    pass "where the set is on the host the command drops the package install"
else
    fail "the notice with core installed: ${OUT:0:500}"
fi
rm -rf "${PKG}/core"
write_conf; admin status_assets
if [[ -z "$(notice_row)" && "${OUT}" == *"problems=0 unreadable=0"* ]] && ! grep -q 'Summary:' <<< "${OUT}"; then
    pass "AI_TOOLS_ASSETS=[] ends the notice, and a clean section prints no summary line"
else
    fail "AI_TOOLS_ASSETS=[]: ${OUT:0:400}"
fi
write_conf core/skills/ai-tools-technical-writing; admin status_assets
if [[ -z "$(notice_row)" ]] && grep -qE '\[ATTENTION\] +core/skills/ai-tools-technical-writing +set-(absent|unbound)' <<< "${OUT}"; then
    pass "a listed successor that does not link is reported by its own row, not by the notice"
else
    fail "a listed successor: ${OUT:0:400}"
fi
write_conf_unset; rm -rf "${HOME_DIR}/retired"; admin status_assets
if [[ -z "$(notice_row)" && "${OUT}" == *"problems=0 unreadable=0"* ]]; then
    pass "a host without a retired copy, a fresh install among them, does not print the notice"
else
    fail "no retired directory: ${OUT:0:400}"
fi
# The notice's reader is the seeder library's; a library that did not load is a reading the section could not make, told
# apart from a host the notice does not apply to.
retire ai-tools-reftags; PRELUDE='unset -f ai_tools_managed_assets__list_withdrawn_successors'; admin status_assets; PRELUDE=""
if grep -qE '\[UNREADABLE\] +error +the seeder library' <<< "${OUT}" && [[ -z "$(notice_row)" && "${OUT}" == *"problems=0 unreadable=1"* ]]; then
    pass "a seeder library that did not load is an UNREADABLE row, not a host without the notice"
else
    fail "an unloaded seeder library: ${OUT:0:400}"
fi
rm -rf "${HOME_DIR}/retired"
# The write says where it placed the key where that matters: a file written before the key takes the line at its end,
# with the merge that carries it under its header named; a file carrying the commented slot takes it there, with no
# notice.
write_conf_unset; admin assets enable "${SKILL}"
if [[ "${RC}" == 0 && "$(tail -n1 "${CONF}")" == "AI_TOOLS_ASSETS=[${SKILL}]" ]]; then
    pass "an enable on a file written before the key appends the line"
else
    fail "an enable on a file without the key: rc ${RC}, $(tr '\n' '|' < "${CONF}") ${ERR:0:300}"
fi
assert_msg MSG-T3X4 "${ERR}" "the enable says the line was appended and names system post-upgrade"
write_conf_unset; printf '# the slot\n#AI_TOOLS_ASSETS=[]\n' >> "${CONF}"; admin assets enable "${SKILL}"
if [[ "${RC}" == 0 && "$(grep -c '^AI_TOOLS_ASSETS=' "${CONF}")" == 1 ]] && ! grep -q '^#AI_TOOLS_ASSETS=' "${CONF}" \
        && ! grep -qxF MSG-T3X4 <<< "${ERR}"; then
    pass "an enable on a file carrying the commented slot writes there, with no notice"
else
    fail "an enable over the commented slot: rc ${RC}, $(tr '\n' '|' < "${CONF}") ${ERR:0:300}"
fi
write_conf_unset
printf 'not a directory\n' > "${HOME_DIR}/retired"; admin status_assets
if grep -qE "\[UNREADABLE\] +error +${HOME_DIR}/retired" <<< "${OUT}" && [[ "${OUT}" == *"problems=0 unreadable=1"* ]] \
        && [[ "$(summary_line)" == "    Summary: 1 reading is unavailable in this section (exit 5)" ]]; then
    pass "a retired directory that cannot be listed is an UNREADABLE row, and the summary says exit 5"
else
    fail "an unlistable retired directory: ${OUT:0:400} / '$(summary_line)'"
fi
install -d -o root -g root -m 0750 "${HOME_DIR}/.acme/skills"; mkdir "${HOME_DIR}/.acme/skills/stray"
chown -R "${SANDBOX_USER}" "${HOME_DIR}/.acme/skills/stray"; admin status_assets
if [[ "$(summary_line)" == "    Summary: 1 finding needs attention and 1 reading is unavailable in this section (exit 5)" \
        && "${OUT}" == *"problems=1 unreadable=1"* ]]; then
    pass "a finding beside an unavailable reading: both counts named, exit 5"
else
    fail "attention and unreadable together: '$(summary_line)' ${OUT:0:400}"
fi
rm -rf "${HOME_DIR}/retired" "${HOME_DIR}/.acme/skills/stray"
# A count another section added before this one does not reach this section's line.
# shellcheck disable=SC2016
OUT="$(env "${HOOKS[@]}" bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1
    STATUS_PROBLEMS=2; STATUS_UNREADABLE=1; status_assets; printf "problems=%s unreadable=%s\n" "${STATUS_PROBLEMS}" "${STATUS_UNREADABLE}"' \
    _ "${HELPER}" 2>&1)"
if ! grep -q 'Summary:' <<< "${OUT}" && [[ "${OUT}" == *"problems=2 unreadable=1"* ]]; then
    pass "a finding in another section alone leaves the Assets section without the summary line"
else
    fail "another section's counts: ${OUT:0:400}"
fi

finish
