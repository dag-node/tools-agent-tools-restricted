#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/openpgp.sh
# Unit test for openpgp.lib.sh, the OpenPGP members the set verifier and the release verifier share: the armor
# conversion, the fingerprint predicate, and the reader that decides a gpgv run. The reader is driven with status
# streams built from the keyword sequences gpgv 2.3.3 printed for each case in the EL9 image (expired and revoked keys,
# an expired signature, two signatures, a signing subkey), so the test does not need gpg and runs as any user. Each
# refusal runs beside the control it departs from. The library is read from this checkout where it is present, else
# the installed copy, as tests/unit/msg.sh reads msg.lib.sh: it does not source another library, so the checkout's copy
# is the one under test. The runtime cases that sign with a real key are tests/unit/assets-verify.sh
# and tests/unit/entrypoint-verify.sh.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/lib/ai-tools/openpgp.lib.sh"
[[ -r "${LIB}" ]] || LIB="/usr/local/lib/ai-tools/openpgp.lib.sh"
section "openpgp: the shared OpenPGP members (unit)"
if [[ ! -r "${LIB}" ]]; then
    skip "openpgp" "not installed at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}"
# Every function this file calls, checked before the first case: an absent one exits 127, which a refusal case would
# read as a correct refusal.
for function_name in ai_tools_openpgp__write_binary_keyring ai_tools_openpgp__is_fingerprint \
    ai_tools_openpgp__classify_gpgv_status; do
    if ! declare -F "${function_name}" >/dev/null; then
        fail "${LIB} does not define ${function_name}"
        finish; exit 1
    fi
done
mktestdir

# ── The fingerprint predicate ────────────────────────────────────────────────────────────────────
while IFS='|' read -r item want why; do
    [[ -n "${why}" ]] || continue
    got=0; ai_tools_openpgp__is_fingerprint "${item}" || got=$?
    if [[ "${got}" == "${want}" ]]; then pass "fingerprint: ${why}"; else fail "fingerprint: ${why} -> got ${got}, want ${want}"; fi
done <<'EOF'
67F42DC18BF764B42D82F14256D2F802CF9832E4|0|40 hex digits
67f42dc18bf764b42d82f14256d2f802cf9832e4|0|lower-case hex
67F42DC18BF764B42D82F14256D2F802CF9832E|1|39 digits
67F42DC18BF764B42D82F14256D2F802CF9832E41|1|41 digits
67F42DC18BF764B42D82F14256D2F802CF9832EG|1|a digit that is not hex
openpgp:67F42DC18BF764B42D82F14256D2F802CF9832E4|1|the openpgp: type prefix
|1|the empty string
EOF

# ── The armor conversion ─────────────────────────────────────────────────────────────────────────
# Armor is base64 between the markers, after header lines and before a `=` CRC line, so a block whose body is the base64
# of known bytes decodes to those bytes; the shipped key's round trip is tests/unit/assets-verify.sh's.
armor_block() { # armor_block <payload> : one PUBLIC KEY BLOCK armoring <payload>
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: fixture\n\n%s\n=AbCd\n-----END PGP PUBLIC KEY BLOCK-----\n' \
        "$(printf '%s' "$1" | base64 -w 0)"
}
armor_block 'first-key' > "${TESTDIR}/one.asc"
{ armor_block 'first-key'; printf 'text between the blocks\n'; armor_block 'second-key'; } > "${TESTDIR}/two.asc"
printf 'not an armored key\n' > "${TESTDIR}/none.asc"

if ai_tools_openpgp__write_binary_keyring "${TESTDIR}/one.asc" "${TESTDIR}/one.gpg" \
    && [[ "$(cat "${TESTDIR}/one.gpg")" == first-key ]]; then
    pass "conversion: one block decodes to its packets, the header and CRC lines dropped"
else
    fail "conversion: one block did not decode to its packets"
fi
if ai_tools_openpgp__write_binary_keyring "${TESTDIR}/two.asc" "${TESTDIR}/two.gpg" \
    && [[ "$(cat "${TESTDIR}/two.gpg")" == first-keysecond-key ]]; then
    pass "conversion: two blocks decode to one keyring, the text between them ignored"
else
    fail "conversion: two blocks did not decode to one keyring"
fi
printf 'stale\n' > "${TESTDIR}/none.gpg"
got=0; ai_tools_openpgp__write_binary_keyring "${TESTDIR}/none.asc" "${TESTDIR}/none.gpg" || got=$?
if [[ "${got}" == 1 && ! -e "${TESTDIR}/none.gpg" ]]; then
    pass "conversion: a file without a key block returns 1 and leaves no keyring"
else
    fail "conversion: a file without a key block -> got ${got}, keyring $( [[ -e "${TESTDIR}/none.gpg" ]] && echo left || echo removed)"
fi
got=0; ai_tools_openpgp__write_binary_keyring "${TESTDIR}/absent.asc" "${TESTDIR}/absent.gpg" || got=$?
if [[ "${got}" == 1 && ! -e "${TESTDIR}/absent.gpg" ]]; then
    pass "conversion: an unreadable input returns 1"
else
    fail "conversion: an unreadable input -> got ${got}"
fi

# ── The reader ───────────────────────────────────────────────────────────────────────────────────
# One primary, one signing subkey, and the fields gpgv prints around them. VALIDSIG carries ten fields after its
# keyword: the signing key, three dates, the signature version, a reserved field, the algorithms, the class,
# and the primary.
readonly PRIMARY=67F42DC18BF764B42D82F14256D2F802CF9832E4
readonly SUBKEY=0123456789ABCDEF0123456789ABCDEF01234567
validsig_fields() { printf '%s 2026-10-17 1760659200 0 4 0 1 10 00 %s' "$1" "$2"; }

# stream <keyword|keyword:fields>... : a gpgv status stream, one `[GNUPG:]` line per keyword. A bare keyword takes
# the fields gpgv prints for it on a signature by PRIMARY; `keyword:fields` writes the fields given.
stream() {
    local item keyword fields
    for item in "$@"; do
        keyword="${item%%:*}"
        if [[ "${item}" == *:* ]]; then
            fields="${item#*:}"
        else
            case "${keyword}" in
                NEWSIG)          fields="" ;;
                KEY_CONSIDERED)  fields="${PRIMARY} 0" ;;
                KEYEXPIRED)      fields="1760745600" ;;
                SIG_ID)          fields="FgOT0CS1vWXl0Tp8z3c8pkZEh4o 2026-10-17 1760659200" ;;
                GOODSIG|BADSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) fields="56D2F802CF9832E4 ai-tools test <acme@acme.example>" ;;
                VALIDSIG)        fields="$(validsig_fields "${PRIMARY}" "${PRIMARY}")" ;;
                ERRSIG)          fields="0011223344556677 1 10 00 1760659200 9 -" ;;
                NO_PUBKEY)       fields="0011223344556677" ;;
                KEYREVOKED)      fields="" ;;
                *)               fields="" ;;
            esac
        fi
        printf '[GNUPG:] %s%s\n' "${keyword}" "${fields:+ ${fields}}"
    done
}

# expect <label> <want-status> <want-signing-key> <want-primary> <exit> <key-status> <stream> : run the reader once
# and compare its status, its returned value and both fingerprints with the expected ones.
expect() {
    local label="$1" want="$2" want_key="$3" want_primary="$4" exit_status="$5" key_status="$6" text="$7"
    local line status rc=0 signing_key primary reason
    line="$(ai_tools_openpgp__classify_gpgv_status "${exit_status}" "${text}" "${key_status}")" || rc=$?
    IFS=' ' read -r status signing_key primary reason <<< "${line}"
    if [[ "${status}" == "${want}" && "${rc}" == "${want}" && "${signing_key}" == "${want_key}" \
        && "${primary}" == "${want_primary}" ]]; then
        pass "reader: ${label} -> ${want}${reason:+ (${reason})}"
    else
        fail "reader: ${label} -> printed '${line}', returned ${rc}; want ${want} ${want_key} ${want_primary}"
    fi
}

CONTROL="$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED GOODSIG VALIDSIG)"

# The cases gpgv printed, each at its recorded exit status.
expect "control, a valid key" 0 "${PRIMARY}" "${PRIMARY}" 0 1 "${CONTROL}"
expect "a byte appended to the file (BADSIG)" 1 - - 1 1 \
    "$(stream NEWSIG KEY_CONSIDERED KEY_CONSIDERED BADSIG)"
expired_key="$(stream NEWSIG KEY_CONSIDERED KEYEXPIRED SIG_ID KEY_CONSIDERED EXPKEYSIG VALIDSIG)"
expect "an expired key at exit 0, the caller's status 1" 1 - - 0 1 "${expired_key}"
expect "an expired key at exit 0, the caller's status 2" 2 - - 0 2 "${expired_key}"
revoked_key="$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED REVKEYSIG VALIDSIG)"
expect "a revoked key at exit 0, the caller's status 1" 1 - - 0 1 "${revoked_key}"
expect "a revoked key at exit 0, the caller's status 2" 2 - - 0 2 "${revoked_key}"
expect "an expired signature (EXPSIG)" 1 - - 1 2 \
    "$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED EXPSIG VALIDSIG)"
expect "two signatures, good then expired" 2 - - 1 1 \
    "$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED GOODSIG VALIDSIG NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED EXPSIG VALIDSIG)"
expect "two signatures, expired then good: gpgv stops at the first" 1 - - 1 1 \
    "$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED EXPSIG VALIDSIG)"
expect "two signatures, good then a key not held" 2 - - 2 1 \
    "$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED GOODSIG VALIDSIG NEWSIG ERRSIG NO_PUBKEY)"
expect "a key not held (NO_PUBKEY)" 2 - - 2 1 "$(stream NEWSIG ERRSIG NO_PUBKEY)"
expect "a certify-only primary with a signing subkey" 0 "${SUBKEY}" "${PRIMARY}" 0 1 \
    "$(stream NEWSIG KEY_CONSIDERED SIG_ID KEY_CONSIDERED GOODSIG "VALIDSIG:$(validsig_fields "${SUBKEY}" "${PRIMARY}")")"

# The rows' edges, each beside CONTROL.
expect "VALIDSIG of nine fields: the first is the primary" 0 "${SUBKEY}" "${SUBKEY}" 0 1 \
    "$(stream NEWSIG GOODSIG "VALIDSIG:${SUBKEY} 2026-10-17 1760659200 0 4 0 1 10 00")"
expect "VALIDSIG of eight fields" 2 - - 0 1 \
    "$(stream NEWSIG GOODSIG "VALIDSIG:${SUBKEY} 2026-10-17 1760659200 0 4 0 1 10")"
expect "a lower-case VALIDSIG fingerprint is upper-cased" 0 "${PRIMARY}" "${PRIMARY}" 0 1 \
    "$(stream NEWSIG GOODSIG "VALIDSIG:$(validsig_fields "${PRIMARY,,}" "${PRIMARY,,}")")"
expect "a VALIDSIG primary that is not 40 hex digits" 2 - - 0 1 \
    "$(stream NEWSIG GOODSIG "VALIDSIG:$(validsig_fields "${PRIMARY}" "${PRIMARY:0:39}")")"
expect "VALIDSIG without GOODSIG" 2 - - 0 1 "$(stream NEWSIG KEY_CONSIDERED SIG_ID VALIDSIG)"
expect "GOODSIG at exit 0 without VALIDSIG" 2 - - 0 1 "$(stream NEWSIG KEY_CONSIDERED SIG_ID GOODSIG)"
expect "BADSIG at exit 0" 1 - - 0 1 "$(stream NEWSIG BADSIG)"
expect "a good stream at exit 2" 2 - - 2 1 "${CONTROL}"
expect "two result lines without a second NEWSIG" 2 - - 0 1 "$(stream NEWSIG GOODSIG VALIDSIG GOODSIG)"
expect "two VALIDSIG lines" 2 - - 0 1 "$(stream NEWSIG GOODSIG VALIDSIG VALIDSIG)"
expect "KEYREVOKED beside a good signature, the caller's status 1" 1 - - 0 1 "${CONTROL}"$'\n'"$(stream KEYREVOKED)"
expect "KEYREVOKED beside a good signature, the caller's status 2" 2 - - 0 2 "${CONTROL}"$'\n'"$(stream KEYREVOKED)"
expect "KEYEXPIRED beside a good signature leaves it good" 0 "${PRIMARY}" "${PRIMARY}" 0 1 \
    "$(stream NEWSIG KEY_CONSIDERED KEYEXPIRED SIG_ID KEY_CONSIDERED GOODSIG VALIDSIG)"
expect "the empty stream at exit 0" 2 - - 0 1 ""
expect "a line that spells a keyword without the [GNUPG:] prefix is ignored" 0 "${PRIMARY}" "${PRIMARY}" 0 1 \
    "BADSIG 56D2F802CF9832E4 not a status line"$'\n'"gpgv: [GNUPG:] REVKEYSIG quoted"$'\n'"${CONTROL}"
expect "an exit status that is not a number" 2 - - x 1 "${CONTROL}"
expect "a key status that is neither 1 nor 2" 2 - - 0 0 "${CONTROL}"

saved_ifs="${IFS}"
IFS=$'\n\t'
expect "the control under a caller's IFS without a space" 0 "${PRIMARY}" "${PRIMARY}" 0 1 "${CONTROL}"
IFS="${saved_ifs}"

finish
