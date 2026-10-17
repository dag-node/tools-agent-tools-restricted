#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/openpgp.lib.sh
# The OpenPGP members the signature verifiers share: the armor-to-keyring conversion gpgv needs, the fingerprint
# predicate, and the reader that turns a gpgv run into the status contract (ref-section-b8h3 in updater.rule.md).
# Sourced by assets-verify.lib.sh at load and by entrypoint-verify.lib.sh when it verifies a release, so each verifier
# holds one copy of the policy. It does not source any library and does not run gpgv: a caller runs `gpgv --status-fd 1`
# itself and hands this library the exit status and the status text. The conversion runs awk and base64; the predicate
# and the reader use bash builtins alone.
#
# The tools' tools/lib/openpgp.py (ai-tools-assets-tools) holds the same three members: dearmor, FINGERPRINT_PATTERN
# and check_signature, for write_binary_keyring, is_valid_fingerprint and evaluate_gpgv_status here. The reader's rows
# are check_signature's, and on one status stream the two reach 0 together, so a set verify-set accepts carries
# a signature this host's reader accepts. They differ in three places. check_signature tests the multiple-signature row
# first, so a mismatch beside a second signature reads 2 there and 1 here. dearmor accepts CRLF line endings and refuses
# a block without its END line, where write_binary_keyring refuses the first and accepts the second.
# And is_valid_fingerprint accepts lower-case hex, which FINGERPRINT_PATTERN refuses; each reader upper-cases
# the VALIDSIG fields before the test, so the readers agree there. The one parameter check_signature does not have is
# the status for a key the keyring holds as expired or revoked, which each caller states (evaluate_gpgv_status).

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
# The minimum is a count of those fields, and the primary's position a zero-based index into them.
readonly _AI_TOOLS_OPENPGP__VALIDSIG_MINIMUM_FIELDS=9
readonly _AI_TOOLS_OPENPGP__VALIDSIG_PRIMARY_FIELD=9

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

# ai_tools_openpgp__is_valid_fingerprint <item> : succeed when <item> is 40 hex digits, either case: a v4 key
#   fingerprint.
ai_tools_openpgp__is_valid_fingerprint() {
    [[ "${1-}" =~ ^[0-9A-Fa-f]{40}$ ]]
}

# ai_tools_openpgp__evaluate_gpgv_status <gpgv-exit-status> <status-text> <expired-or-revoked-key-status>
#   Decide one gpgv run over one detached signature. Prints one line, `<status> <signing-key> <primary> <reason>`,
#   and returns <status>: 0, 1 or 2 of the status contract. The two fingerprints are 40 upper-case hex digits at 0
#   and `-` otherwise; <reason> is `-` at 0 and the text of the row that decided otherwise. A line of <status-text> is
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
#   decides 1 leaves it at 1. gpgv exits 0 for a good signature by a key the keyring holds as expired or revoked
#   and reports it on the status stream alone, which is why the exit status is one input and not the verdict.
#   KEYEXPIRED alone does not change the outcome, since gpgv prints it for an expired subkey the signature does not
#   use. <expired-or-revoked-key-status> is 1 or 2, and <gpgv-exit-status> a process exit status, 0 to 255 written
#   without a leading zero; any other value decides 2, with the argument named as the reason.
ai_tools_openpgp__evaluate_gpgv_status() {
    local gpgv_exit_status="${1-}" status_text="${2-}" expired_or_revoked_key_status="${3-}"
    local line keyword result_keyword signing_key primary
    local newsig_count=0 validsig_count=0 result_count=0
    local -a fields=() validsig_fields=()
    local -A seen=()
    # The regex bounds the argument to three digits before the one arithmetic on it, so a leading zero does not reach
    # bash's octal reading and a long decimal does not wrap to 0.
    if [[ ! "${gpgv_exit_status}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( gpgv_exit_status > 255 )); then
        printf '2 - - the gpgv exit status is not a process exit status\n'; return 2
    fi
    if [[ "${expired_or_revoked_key_status}" != 1 && "${expired_or_revoked_key_status}" != 2 ]]; then
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
            NEWSIG)   newsig_count=$(( newsig_count + 1 )) ;;
            VALIDSIG) validsig_count=$(( validsig_count + 1 )); validsig_fields=("${fields[@]:2}") ;;
        esac
        for result_keyword in "${_AI_TOOLS_OPENPGP__SIGNATURE_RESULTS[@]}"; do
            [[ "${keyword}" == "${result_keyword}" ]] && result_count=$(( result_count + 1 ))
        done
    done <<< "${status_text}"
    if [[ -n "${seen[BADSIG]+x}" ]]; then
        printf '1 - - the signature does not match the file\n'; return 1
    fi
    if [[ -n "${seen[EXPSIG]+x}" ]]; then
        printf '1 - - the signature is expired\n'; return 1
    fi
    if [[ -n "${seen[EXPKEYSIG]+x}" || -n "${seen[REVKEYSIG]+x}" || -n "${seen[KEYREVOKED]+x}" ]]; then
        printf '%s - - the signing key is expired or revoked\n' "${expired_or_revoked_key_status}"
        return "${expired_or_revoked_key_status}"
    fi
    if (( newsig_count > 1 || validsig_count > 1 || result_count > 1 )); then
        printf '2 - - the signature file holds more than one signature\n'; return 2
    fi
    if [[ -n "${seen[NO_PUBKEY]+x}" ]]; then
        printf '2 - - the signing key is not in the keyring\n'; return 2
    fi
    if [[ -n "${seen[ERRSIG]+x}" || "${gpgv_exit_status}" != 0 ]]; then
        printf '2 - - gpgv could not check the signature (exit %s)\n' "${gpgv_exit_status}"; return 2
    fi
    if [[ -n "${seen[GOODSIG]+x}" ]] && (( ${#validsig_fields[@]} >= _AI_TOOLS_OPENPGP__VALIDSIG_MINIMUM_FIELDS )); then
        signing_key="${validsig_fields[0]^^}"
        primary="${signing_key}"
        (( ${#validsig_fields[@]} > _AI_TOOLS_OPENPGP__VALIDSIG_PRIMARY_FIELD )) \
            && primary="${validsig_fields[_AI_TOOLS_OPENPGP__VALIDSIG_PRIMARY_FIELD]^^}"
        if ai_tools_openpgp__is_valid_fingerprint "${signing_key}" \
            && ai_tools_openpgp__is_valid_fingerprint "${primary}"; then
            printf '0 %s %s -\n' "${signing_key}" "${primary}"; return 0
        fi
    fi
    printf '2 - - gpgv did not report a complete good signature\n'; return 2
}
