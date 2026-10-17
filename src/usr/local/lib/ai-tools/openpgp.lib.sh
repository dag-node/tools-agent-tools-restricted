#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/openpgp.lib.sh
# The OpenPGP members the signature verifiers share: the armor-to-keyring conversion gpgv needs, the fingerprint
# predicate, and the reader that turns a gpgv run into the status contract (ref-section-b8h3 in updater.rule.md).
# Sourced by assets-verify.lib.sh at load and by entrypoint-verify.lib.sh when it verifies a release, so each verifier
# holds one copy of the policy. It is pure bash, does not source any library, and does not run gpgv: a caller runs
# `gpgv --status-fd 1` itself and hands this library the exit status and the status text.
#
# The tools' tools/lib/openpgp.py (ai-tools-assets-tools) is the twin, member by member: dearmor, FINGERPRINT_PATTERN
# and check_signature decide what write_binary_keyring, is_fingerprint and classify_gpgv_status decide here, so a set
# verify-set accepts is a set this host accepts. The one parameter the twin does not have is the status for a key
# the keyring holds as expired or revoked, which each caller states (classify_gpgv_status).

# Include guard: an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing
# shell's `set -e`.
if [[ -n "${_AI_TOOLS_OPENPGP__LOADED:-}" ]]; then
    return 0
fi
_AI_TOOLS_OPENPGP__LOADED=1

# The status lines gpgv prints once per signature, each closing that signature's check; a second one is a second
# signature.
readonly -a _AI_TOOLS_OPENPGP__SIGNATURE_RESULTS=(GOODSIG BADSIG EXPSIG EXPKEYSIG REVKEYSIG ERRSIG)
# The fields VALIDSIG carries after its keyword: the first is the signing key, the tenth, where present, the primary.
readonly _AI_TOOLS_OPENPGP__VALIDSIG_FIELDS=9

# ai_tools_openpgp__write_binary_keyring <armored-key> <keyring> : write the binary keyring gpgv reads
#   from an ASCII-armored public key file. gpgv on EL9 exits 2 on an armored keyring, so the keyring is written binary.
#   The armor is base64 between the PUBLIC KEY BLOCK markers, with header lines and a `=` CRC line, so dropping those
#   and decoding is the whole conversion, and gpgv, the verify-only half of gnupg2, stays the one dependency: no gpg
#   homedir is made per call. Several armored blocks in one file decode to one keyring. A partial output is removed;
#   returns 1 when the input does not hold a key.
ai_tools_openpgp__write_binary_keyring() {
    local armored="${1:-}" keyring="${2:-}"
    [[ -n "${armored}" && -r "${armored}" && -n "${keyring}" ]] || return 1
    if ! awk '/^-----BEGIN PGP PUBLIC KEY BLOCK-----/ { f = 1; next }
              /^-----END PGP PUBLIC KEY BLOCK-----/   { f = 0; next }
              f && !/^[A-Za-z-]+:/ && !/^=/ && NF' "${armored}" | base64 -d > "${keyring}" 2>/dev/null \
        || [[ ! -s "${keyring}" ]]; then
        rm -f -- "${keyring}"
        return 1
    fi
    return 0
}

# ai_tools_openpgp__is_fingerprint <item> : succeed when <item> is 40 hex digits, either case: a v4 key fingerprint.
ai_tools_openpgp__is_fingerprint() {
    [[ "${1-}" =~ ^[0-9A-Fa-f]{40}$ ]]
}

# ai_tools_openpgp__classify_gpgv_status <gpgv-exit> <status-text> <expired-or-revoked-key-status> : decide one gpgv
#   run over one detached signature. Prints one line, `<status> <signing-key> <primary> <reason>`, and returns
#   <status>: 0, 1 or 2 of the status contract. The two fingerprints are 40 upper-case hex digits at 0 and `-`
#   otherwise; <reason> is `-` at 0 and the text of the row that decided otherwise. A line of <status-text> is
#   a status line when its first whitespace-separated field is `[GNUPG:]`, and its second field is the keyword;
#   every other line is ignored. The first row that matches decides:
#     1. BADSIG, whatever the exit: 1, the signature does not match the file
#     2. EXPSIG: 1, the signature is expired
#     3. EXPKEYSIG, REVKEYSIG or KEYREVOKED: <expired-or-revoked-key-status>, the signing key is expired or revoked
#     4. a second NEWSIG, a second VALIDSIG, or a second result line (GOODSIG, BADSIG, EXPSIG, EXPKEYSIG,
#        REVKEYSIG, ERRSIG): 2, the signature file holds more than one signature
#     5. NO_PUBKEY: 2, the signing key is not in the keyring
#     6. ERRSIG, or a non-zero exit: 2, gpgv could not check the signature (exit N)
#     7. GOODSIG and a VALIDSIG of nine fields or more whose first field and tenth (the first where there is no tenth)
#        are each 40 hex digits: 0; the first is the signing key, the tenth the primary
#     8. anything else, a zero exit included: 2, gpgv did not report a complete good signature
#   Rows 1 to 3 test for a keyword's presence and precede every row that decides 2, so a line added to a stream that
#   decides 1 leaves it at 1. gpgv exits 0 for a good signature by a key the keyring holds as expired or revoked and reports it on the status
#   stream alone, which is why the exit status is one input and not the verdict. KEYEXPIRED alone does not change
#   the outcome, since gpgv prints it for an expired subkey the signature does not use. <expired-or-revoked-key-status>
#   is 1 or 2, and <gpgv-exit> a number; any other value decides 2, with the argument named as the reason.
ai_tools_openpgp__classify_gpgv_status() {
    local gpgv_exit="${1-}" status_text="${2-}" key_refusal_status="${3-}"
    local line keyword result signing_key primary
    local new_signatures=0 valid_signatures=0 results=0
    local -a fields=() validsig_fields=()
    local -A seen=()
    if [[ ! "${gpgv_exit}" =~ ^[0-9]+$ ]]; then
        printf '2 - - the gpgv exit status is not a number\n'; return 2
    fi
    if [[ "${key_refusal_status}" != 1 && "${key_refusal_status}" != 2 ]]; then
        printf '2 - - the status for an expired or revoked key is neither 1 nor 2\n'; return 2
    fi
    # The split pins IFS, since a caller may have set its own (the launch wrapper's does not hold a space).
    while IFS= read -r line; do
        IFS=$' \t' read -r -a fields <<< "${line}"
        if (( ${#fields[@]} < 2 )) || [[ "${fields[0]}" != '[GNUPG:]' ]]; then
            continue
        fi
        keyword="${fields[1]}"
        seen["${keyword}"]=1
        case "${keyword}" in
            NEWSIG)   new_signatures=$(( new_signatures + 1 )) ;;
            VALIDSIG) valid_signatures=$(( valid_signatures + 1 )); validsig_fields=("${fields[@]:2}") ;;
        esac
        for result in "${_AI_TOOLS_OPENPGP__SIGNATURE_RESULTS[@]}"; do
            [[ "${keyword}" == "${result}" ]] && results=$(( results + 1 ))
        done
    done <<< "${status_text}"
    if [[ -n "${seen[BADSIG]+x}" ]]; then
        printf '1 - - the signature does not match the file\n'; return 1
    fi
    if [[ -n "${seen[EXPSIG]+x}" ]]; then
        printf '1 - - the signature is expired\n'; return 1
    fi
    if [[ -n "${seen[EXPKEYSIG]+x}" || -n "${seen[REVKEYSIG]+x}" || -n "${seen[KEYREVOKED]+x}" ]]; then
        printf '%s - - the signing key is expired or revoked\n' "${key_refusal_status}"; return "${key_refusal_status}"
    fi
    if (( new_signatures > 1 || valid_signatures > 1 || results > 1 )); then
        printf '2 - - the signature file holds more than one signature\n'; return 2
    fi
    if [[ -n "${seen[NO_PUBKEY]+x}" ]]; then
        printf '2 - - the signing key is not in the keyring\n'; return 2
    fi
    if [[ -n "${seen[ERRSIG]+x}" ]] || (( gpgv_exit != 0 )); then
        printf '2 - - gpgv could not check the signature (exit %s)\n' "${gpgv_exit}"; return 2
    fi
    if [[ -n "${seen[GOODSIG]+x}" ]] && (( ${#validsig_fields[@]} >= _AI_TOOLS_OPENPGP__VALIDSIG_FIELDS )); then
        signing_key="${validsig_fields[0]^^}"
        primary="${signing_key}"
        (( ${#validsig_fields[@]} > _AI_TOOLS_OPENPGP__VALIDSIG_FIELDS )) \
            && primary="${validsig_fields[_AI_TOOLS_OPENPGP__VALIDSIG_FIELDS]^^}"
        if [[ "${signing_key}" =~ ^[0-9A-F]{40}$ && "${primary}" =~ ^[0-9A-F]{40}$ ]]; then
            printf '0 %s %s -\n' "${signing_key}" "${primary}"; return 0
        fi
    fi
    printf '2 - - gpgv did not report a complete good signature\n'; return 2
}
