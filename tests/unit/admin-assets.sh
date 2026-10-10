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
        (( unload )) && unset -f ai_tools_assets_reconcile
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
[[ "$(finding_of "${SKILL}")" == linked ]] && pass "the record stream carries the entry linked" || fail "rows: ${OUT:0:300}"
admin assets enable "${SKILL}"
[[ "$(listed)" == "AI_TOOLS_ASSETS=[${SKILL}, ${SUB}]" ]] && pass "an identifier already listed is not added twice" \
    || fail "a second enable wrote '$(listed)'"
admin assets enable acme-two/skills/acme-two-pdf
if [[ "${RC}" == 4 && "$(finding_of acme-two/skills/acme-two-pdf)" == set-absent && "$(listed)" == *acme-two/skills/acme-two-pdf* ]]; then
    pass "a pending identifier of a bound set is accepted, reported set-absent, exit 4"
else
    fail "a pending identifier: rc ${RC}, '$(finding_of acme-two/skills/acme-two-pdf)', '$(listed)'"
fi

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
admin assets
refused MSG-E5Z8 2 "a bare assets"
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
[[ "$(snapshot)" == "${before}" ]] && pass "the status section does not write: the view is as it was" || fail "status changed the view"
chmod 0664 "${CONF}"; admin status_assets
grep -q 'enable-list-untrusted' <<< "${OUT}" && pass "an untrusted operator.conf renders enable-list-untrusted" || fail "untrusted: ${OUT:0:300}"
chmod 0644 "${CONF}"
PRELUDE='ai_tools_enabled_agents() { return 2; }'; admin status_assets; PRELUDE=""
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
# The status section's own probe is ai_tools_assets_plan, which `unload` leaves; drive the missing library through it.
# shellcheck disable=SC2016
OUT="$(env "${HOOKS[@]}" bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1
    source /usr/local/lib/ai-tools/assets.lib.sh 2>/dev/null; unset -f ai_tools_assets_plan
    STATUS_PROBLEMS=0; STATUS_UNREADABLE=0; status_assets; printf "unreadable=%s\n" "${STATUS_UNREADABLE}"' _ "${HELPER}" 2>&1)"
[[ "${OUT}" == *UNREADABLE* && "${OUT}" == *unreadable=1* ]] && pass "a library that did not load is a reading the section could not make" \
    || fail "an unloaded library: ${OUT:0:300}"

finish
