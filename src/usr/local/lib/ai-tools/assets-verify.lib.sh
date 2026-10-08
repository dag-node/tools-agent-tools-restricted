#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/assets-verify.lib.sh
# Verify that an installed asset set is the one its publisher signed: `SHA256SUMS.asc` is a signature, by a key
# the root-owned binding for that set name pins, over a `SHA256SUMS` that lists every file of the set once with its
# hash. Sourced as root by the assets resolver, which does not link any asset of a set this library refuses; the roots,
# the binding directory and the reason tokens are in shipped-assets.rule.md.
#
# Status contract, shared with entrypoint-verify.lib.sh:
#   0  verified; the signer's primary fingerprint is printed on stdout
#   1  MISMATCH (MSG-T3M3) -- gpgv rejects the signature, or the inventory does not describe the tree: a listed hash
#      differs, a file is listed and absent, present and unlisted, listed twice, or a line outside the inventory shape
#   2  unable to verify (MSG-Q6Y8) -- SHA256SUMS or SHA256SUMS.asc absent or over its bound, a walk of the tree that
#      did not complete, a file over the format's per-file bound or a set over its file-count or payload bound, gpgv
#      absent or exiting other than 0 or 1, no binding for the name, a binding or keyring that fails
#      ai_tools_conf_is_trusted or does not parse, or a VALIDSIG primary no `signers` item names
# Both refuse: the resolver reads 1 as set-tampered and 2 as set-unverified. The signature is checked before the
# inventory is parsed, so a tree whose signature fails is not read further; a signed inventory that does not describe
# the tree is a mismatch, since the signed file and the tree cannot both be what the publisher built. A file name
# holding a newline or a backslash is a mismatch too: sha256sum prints such a name escaped, so one inventory line cannot
# name it, and the format's file-name rule refuses it at build.
#
# A binding is AI_TOOLS_ASSETS_BINDINGS_DIR/<set>.conf in the shared KEY=value grammar, read line by line
# through conf.lib.sh and not sourced: `set` equals the file's stem, `signers` lists primary fingerprints as openpgp:<40
# hex digits>, and `keyring` names the binary keyring gpgv reads. A key outside those three refuses the binding: every
# key of a binding decides trust, so a key this reader does not define is not read past. The keyring is written at build
# time from the armored key beside it by ai_tools_assets_keyring_dearmor, since gpgv on EL9 does not read an armored
# keyring. The directory, the binding and the keyring are root-owned and not group- or other-writable, the predicate
# conf.lib.sh states, so a write to them needs root, which tests/boundary/assets.sh asserts from the sandbox account's
# vantage.

# Sourced more than once in a single shell: the readonly constants would abort under `set -e` on the second pass.
# An if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_ASSETS_VERIFY_LIB_LOADED:-}" ]]; then
    return 0
fi

# conf.lib.sh is REQUIRED: without the trust predicate a binding cannot be told from a planted file and a list cannot be
# read, so this library does not define its verifier without it. A caller loads it
# as `source … && declare -F ai_tools_assets_verify_set` and refuses every set when that fails.
# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1; then
    printf 'assets-verify: conf.lib.sh did not load, so the set verifier is not defined\n' >&2
    return 1
fi
_AI_TOOLS_ASSETS_VERIFY_LIB_LOADED=1

# The shipped bindings, redirected by a root-only test hook with the standing of AI_TOOLS_ENTRYPOINT_PIN_DIR: `sudo`
# strips the name, and every consumer runs as root. I7b's operator bindings under /etc/ai-tools/assets-bindings.d/ are
# not read by this release.
: "${AI_TOOLS_ASSETS_BINDINGS_DIR:=/usr/local/lib/ai-tools/assets-bindings.d}"
readonly AI_TOOLS_ASSETS_INVENTORY=SHA256SUMS
readonly AI_TOOLS_ASSETS_SIGNATURE=SHA256SUMS.asc
# The bound each read takes: a file of the set, the inventory among them, at the format's per-file bound; the signature
# and a binding at 64 KiB; the set at the format's file count and payload bound. A set past a bound is not read further.
readonly AI_TOOLS_ASSETS_FILE_MAX_BYTES=1048576
readonly AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES=65536
readonly AI_TOOLS_ASSETS_FILE_MAX_COUNT=2000
readonly AI_TOOLS_ASSETS_SET_MAX_BYTES=67108864

# _ai_tools_av_warn [code] <message...> : this library's one report, on stderr and, when log.lib.sh is loaded by the
#   caller, in journald. A leading message code goes on its own line ahead of the message, the shape
#   tests/lib/harness.sh's assert_msg reads. Never alters a verdict.
_ai_tools_av_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'assets-verify: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "assets-verify: $*"
    return 0
}

# _ai_tools_av_mismatch <detail...> : report a status-1 refusal under its code. The caller returns 1.
_ai_tools_av_mismatch() {
    _ai_tools_av_warn MSG-T3M3 "the set is refused as tampered -- $*"
}

# _ai_tools_av_unverifiable <detail...> : report a status-2 refusal under its code. The caller returns 2.
_ai_tools_av_unverifiable() {
    _ai_tools_av_warn MSG-Q6Y8 "the set is refused as unverified -- $*"
}

# _ai_tools_av_regular_file <path> <max-bytes> : succeed when <path> is a readable regular file, not a symlink, of at
#   most <max-bytes>. Every file this library opens passes it first, so a link or a special file swapped into a name
#   is refused before a read.
_ai_tools_av_regular_file() {
    local path="${1:-}" max_bytes="${2:-0}" size_bytes
    [[ -n "${path}" && ! -L "${path}" && -f "${path}" && -r "${path}" ]] || return 1
    size_bytes="$(stat -c '%s' "${path}" 2>/dev/null)" || return 1
    [[ "${size_bytes}" =~ ^[0-9]+$ ]] && (( size_bytes <= max_bytes ))
}

# ai_tools_assets_set_name_valid <name> : succeed when <name> follows the set-name grammar of the assets format:
#   1 to 64 characters of a-z, 0-9 and single hyphens, starting and ending with a letter or digit. A name becomes
#   a path component of the binding, so an invalid one is refused before it is joined to a path.
ai_tools_assets_set_name_valid() {
    [[ "${1-}" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ && "${1-}" != *--* ]]
}

# ai_tools_assets_signer_valid <item> : succeed when <item> is a typed primary fingerprint, `openpgp:` then 40 hex
#   digits. The type is a prefix so a later signature scheme is a new prefix and not a new key of the binding.
ai_tools_assets_signer_valid() {
    [[ "${1-}" =~ ^openpgp:[0-9A-Fa-f]{40}$ ]]
}

# ai_tools_assets_keyring_dearmor <armored-key> <keyring> : write the binary keyring gpgv reads from an ASCII-armored
#   public key file. The armor is base64 between the PUBLIC KEY BLOCK markers, with header lines and a `=` CRC line,
#   so dropping those and decoding is the whole conversion -- which keeps gpgv, the verify-only half of gnupg2,
#   the one dependency rather than a gpg with a homedir per call. Several armored blocks in one file decode to one
#   keyring. A partial output is removed; returns 1 when the input does not hold a key.
ai_tools_assets_keyring_dearmor() {
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

# ai_tools_assets_binding_read <set-name> : read the binding for <set-name> into _ai_tools_av_signers (the primary
#   fingerprints, upper-case, without their type) and _ai_tools_av_keyring (the keyring path). Returns 0, or 2 under
#   MSG-Q6Y8 for a name outside the grammar, a bindings directory or binding file ai_tools_conf_is_trusted refuses,
#   an absent binding, a line outside `set`, `signers` and `keyring`, a `set` other than the name, an empty or invalid
#   signers list, a signer outside its shape, or a keyring that is not an absolute path to a trusted, non-empty regular
#   file in a trusted directory. Every failure leaves both outputs empty.
ai_tools_assets_binding_read() {
    local set_name="${1:-}" dir="${AI_TOOLS_ASSETS_BINDINGS_DIR}" binding line key item keyring
    local -a signers=() parsed_signers=()
    _ai_tools_av_signers=()
    _ai_tools_av_keyring=""
    ai_tools_assets_set_name_valid "${set_name}" \
        || { _ai_tools_av_unverifiable "'${set_name:0:80}' is not a set name"; return 2; }
    binding="${dir}/${set_name}.conf"
    ai_tools_conf_is_trusted "${dir}" \
        || { _ai_tools_av_unverifiable "bindings directory ${dir} is not trusted ($(ai_tools_conf_untrusted_reason "${dir}"))"; return 2; }
    [[ -e "${binding}" || -L "${binding}" ]] \
        || { _ai_tools_av_unverifiable "set ${set_name} has no binding at ${binding}, so no key is pinned for it"; return 2; }
    ai_tools_conf_is_trusted "${binding}" \
        || { _ai_tools_av_unverifiable "binding ${binding} is not trusted ($(ai_tools_conf_untrusted_reason "${binding}"))"; return 2; }
    _ai_tools_av_regular_file "${binding}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" \
        || { _ai_tools_av_unverifiable "binding ${binding} is not a regular file of at most ${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES} bytes"; return 2; }
    # Every live line is one of the three keys: a key this reader does not define decides neither a signer nor a keyring
    # here, and a binding that carries one is read by a reader that defines it, not past by this one.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "${line}" == *=* && "${key}" =~ ^(set|signers|keyring)$ ]] \
            || { _ai_tools_av_unverifiable "binding ${binding} holds a line this reader does not define: ${line:0:80}"; return 2; }
    done < "${binding}"
    [[ "$(ai_tools_conf_get "${binding}" set)" == "${set_name}" ]] \
        || { _ai_tools_av_unverifiable "binding ${binding} does not name set ${set_name} in its set= line"; return 2; }
    ai_tools_conf_list signers "${binding}" signers \
        || { _ai_tools_av_unverifiable "binding ${binding} has no signers= line"; return 2; }
    (( ${#signers[@]} > 0 )) \
        || { _ai_tools_av_unverifiable "binding ${binding} names no signer"; return 2; }
    for item in "${signers[@]}"; do
        ai_tools_assets_signer_valid "${item}" \
            || { _ai_tools_av_unverifiable "binding ${binding} signer '${item:0:80}' is not openpgp:<40 hex digits>"; return 2; }
        parsed_signers+=("${item#openpgp:}")
    done
    keyring="$(ai_tools_conf_get "${binding}" keyring)"
    if [[ "${keyring}" != /* || "${keyring}" == *..* ]] \
        || ! ai_tools_conf_is_trusted "${keyring%/*}" || ! ai_tools_conf_is_trusted "${keyring}" \
        || ! _ai_tools_av_regular_file "${keyring}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" || [[ ! -s "${keyring}" ]]; then
        _ai_tools_av_unverifiable "binding ${binding} keyring '${keyring:0:120}' is not an absolute path to a trusted, non-empty regular file in a trusted directory"
        return 2
    fi
    # The outputs are assigned once, after every check, so a binding refused at any line publishes neither.
    _ai_tools_av_signers=("${parsed_signers[@]^^}")
    _ai_tools_av_keyring="${keyring}"
    return 0
}

# _ai_tools_av_inventory_path_valid <path> : succeed when <path> is a relative path inside a set: no leading `/`,
#   no empty, `.` or `..` component, no backslash (sha256sum's escape for a name it cannot print plainly), and not
#   the inventory or its signature, which list themselves nowhere.
_ai_tools_av_inventory_path_valid() {
    local path="${1-}" component
    [[ -n "${path}" && "${path}" != /* && "${path}" != *\\* ]] || return 1
    [[ "${path}" != "${AI_TOOLS_ASSETS_INVENTORY}" && "${path}" != "${AI_TOOLS_ASSETS_SIGNATURE}" ]] || return 1
    local IFS=/
    for component in ${path}; do
        [[ -n "${component}" && "${component}" != . && "${component}" != .. ]] || return 1
    done
    return 0
}

# ai_tools_assets_check_inventory <set-directory> : the inventory half, callable alone for the conformance job:
#   SHA256SUMS under <set-directory> lists every file of the set other than itself and SHA256SUMS.asc exactly once,
#   as `<sha256>  <relative path>`, and each hash matches. Returns 0; 1 under MSG-T3M3 for a line outside that shape,
#   a path outside the set, a path listed twice, a file listed and absent, present and unlisted, not a regular file,
#   or whose hash differs; 2 under MSG-Q6Y8 for a directory or inventory the bounded read refuses, a walk that did not
#   complete, a file over the per-file bound, a set over the file-count or payload bound, or no sha256sum. Prints
#   nothing. The walk is written to a file of its own so its exit status is read: an enumeration that ended early
#   leaves a tree whose listed files match and whose unlisted ones were never seen, which no count would show. The tree
#   is then hashed in one sha256sum call over the names the walk found.
ai_tools_assets_check_inventory() {
    local set_dir="${1:-}" inventory line digest path size_bytes checksum_output hashed_count=0 total_bytes=0
    local listing walk_error walk_status=0
    local line_shape='^([0-9a-f]{64}) [ *](.+)$'
    local -A expected_digests_by_path=()
    local -a discovered_file_paths=()
    [[ -n "${set_dir}" && ! -L "${set_dir}" && -d "${set_dir}" ]] \
        || { _ai_tools_av_unverifiable "'${set_dir:0:120}' is not a directory"; return 2; }
    inventory="${set_dir}/${AI_TOOLS_ASSETS_INVENTORY}"
    _ai_tools_av_regular_file "${inventory}" "${AI_TOOLS_ASSETS_FILE_MAX_BYTES}" \
        || { _ai_tools_av_unverifiable "${inventory} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"; return 2; }
    command -v sha256sum >/dev/null 2>&1 \
        || { _ai_tools_av_unverifiable "sha256sum not found"; return 2; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ${line_shape} ]] \
            || { _ai_tools_av_mismatch "${inventory}: a line is not <sha256>  <path>: ${line:0:80}"; return 1; }
        digest="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
        _ai_tools_av_inventory_path_valid "${path}" \
            || { _ai_tools_av_mismatch "${inventory}: '${path:0:80}' is not a relative path inside the set"; return 1; }
        [[ -z "${expected_digests_by_path[${path}]+x}" ]] \
            || { _ai_tools_av_mismatch "${inventory}: '${path:0:80}' is listed twice"; return 1; }
        expected_digests_by_path["${path}"]="${digest}"
        (( ${#expected_digests_by_path[@]} <= AI_TOOLS_ASSETS_FILE_MAX_COUNT )) \
            || { _ai_tools_av_unverifiable "${inventory}: lists more than ${AI_TOOLS_ASSETS_FILE_MAX_COUNT} files"; return 2; }
    done < "${inventory}"
    listing="$(mktemp 2>/dev/null)" \
        || { _ai_tools_av_unverifiable "${set_dir}: no temporary file for the walk"; return 2; }
    # shellcheck disable=SC2064  # the name is expanded now, so the trap removes the file this call made
    trap "rm -f -- '${listing}'" RETURN
    walk_error="$( (cd "${set_dir}" && find . -mindepth 1 ! -type d -printf '%s\t%P\0' > "${listing}") 2>&1 )" \
        || walk_status=$?
    (( walk_status == 0 )) \
        || { _ai_tools_av_unverifiable "${set_dir}: the walk did not complete (find exit ${walk_status}): ${walk_error%%$'\n'*}"; return 2; }
    # Every file of the tree is a listed regular file within the bounds. A name holding a newline or a backslash,
    # which sha256sum prints escaped, a link or a special file is a mismatch here, as the file-shape rules refuse it
    # at the resolver.
    while IFS=$'\t' read -r -d '' size_bytes path; do
        [[ "${path}" == "${AI_TOOLS_ASSETS_INVENTORY}" || "${path}" == "${AI_TOOLS_ASSETS_SIGNATURE}" ]] && continue
        [[ "${path}" != *$'\n'* && "${path}" != *\\* ]] \
            || { _ai_tools_av_mismatch "${set_dir}: a file name holds a newline or a backslash, which the inventory cannot list"; return 1; }
        [[ ! -L "${set_dir}/${path}" && -f "${set_dir}/${path}" ]] \
            || { _ai_tools_av_mismatch "${set_dir}: '${path:0:80}' is not a regular file"; return 1; }
        if ! [[ "${size_bytes}" =~ ^[0-9]+$ ]] || (( size_bytes > AI_TOOLS_ASSETS_FILE_MAX_BYTES )); then
            _ai_tools_av_unverifiable "${set_dir}: '${path:0:80}' is over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"
            return 2
        fi
        total_bytes=$(( total_bytes + size_bytes ))
        (( total_bytes <= AI_TOOLS_ASSETS_SET_MAX_BYTES && ${#discovered_file_paths[@]} < AI_TOOLS_ASSETS_FILE_MAX_COUNT )) \
            || { _ai_tools_av_unverifiable "${set_dir}: holds more than ${AI_TOOLS_ASSETS_FILE_MAX_COUNT} files or ${AI_TOOLS_ASSETS_SET_MAX_BYTES} bytes"; return 2; }
        [[ -n "${expected_digests_by_path[${path}]+x}" ]] \
            || { _ai_tools_av_mismatch "${set_dir}: '${path:0:80}' is in the set and not in ${AI_TOOLS_ASSETS_INVENTORY}"; return 1; }
        discovered_file_paths+=("${path}")
    done < "${listing}"
    if (( ${#discovered_file_paths[@]} != ${#expected_digests_by_path[@]} )); then
        for path in "${!expected_digests_by_path[@]}"; do
            [[ -e "${set_dir}/${path}" ]] \
                || { _ai_tools_av_mismatch "${inventory}: '${path:0:80}' is listed and not in the set"; return 1; }
        done
        _ai_tools_av_mismatch "${inventory}: lists ${#expected_digests_by_path[@]} files, the set holds ${#discovered_file_paths[@]}"
        return 1
    fi
    (( ${#discovered_file_paths[@]} > 0 )) \
        || { _ai_tools_av_mismatch "${set_dir}: holds no file beside ${AI_TOOLS_ASSETS_INVENTORY}"; return 1; }
    checksum_output="$(cd "${set_dir}" && sha256sum -- "${discovered_file_paths[@]}" 2>/dev/null)" \
        || { _ai_tools_av_unverifiable "${set_dir}: a file could not be hashed"; return 2; }
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        digest="${line%% *}"
        path="${line#* }"
        path="${path# }"
        [[ "${expected_digests_by_path[${path}]-}" == "${digest}" ]] \
            || { _ai_tools_av_mismatch "${set_dir}: '${path:0:80}' does not match its ${AI_TOOLS_ASSETS_INVENTORY} line"; return 1; }
        hashed_count=$(( hashed_count + 1 ))
    done <<< "${checksum_output}"
    (( hashed_count == ${#discovered_file_paths[@]} )) \
        || { _ai_tools_av_unverifiable "${set_dir}: sha256sum reported ${hashed_count} files of ${#discovered_file_paths[@]}"; return 2; }
    return 0
}

# ai_tools_assets_verify_set <set-directory> <set-name> : the verifier the resolver calls. SHA256SUMS.asc under
#   <set-directory> verifies through gpgv against the keyring the binding for <set-name> names, by a key whose
#   VALIDSIG primary the binding's signers list, and SHA256SUMS describes the tree (ai_tools_assets_check_inventory).
#   Prints the signer's primary fingerprint and returns 0; returns 1 under MSG-T3M3 for a signature gpgv rejects
#   or an inventory mismatch, 2 under MSG-Q6Y8 for an input the checks refuse: absent, over its bound, untrusted, or
#   unmatched by the binding.
#   gpgv reads the keyring named and no default one, and its exit status separates the two refusals as the contract
#   does: 1 for a signature it rejects, 2 for a key the keyring does not hold.
ai_tools_assets_verify_set() {
    local set_dir="${1:-}" set_name="${2:-}" inventory signature gpgv_status_output gpgv_exit_status=0
    local signer_primary allowed_primary matched=no
    [[ -n "${set_dir}" && ! -L "${set_dir}" && -d "${set_dir}" ]] \
        || { _ai_tools_av_unverifiable "'${set_dir:0:120}' is not a directory"; return 2; }
    ai_tools_assets_set_name_valid "${set_name}" \
        || { _ai_tools_av_unverifiable "'${set_name:0:80}' is not a set name"; return 2; }
    inventory="${set_dir}/${AI_TOOLS_ASSETS_INVENTORY}"
    signature="${set_dir}/${AI_TOOLS_ASSETS_SIGNATURE}"
    _ai_tools_av_regular_file "${inventory}" "${AI_TOOLS_ASSETS_FILE_MAX_BYTES}" \
        || { _ai_tools_av_unverifiable "set ${set_name}: ${inventory} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"; return 2; }
    _ai_tools_av_regular_file "${signature}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" \
        || { _ai_tools_av_unverifiable "set ${set_name}: ${signature} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES} bytes"; return 2; }
    command -v gpgv >/dev/null 2>&1 \
        || { _ai_tools_av_unverifiable "set ${set_name}: gpgv not found; install gnupg2"; return 2; }
    ai_tools_assets_binding_read "${set_name}" || return 2
    gpgv_status_output="$(gpgv --status-fd 1 --keyring "${_ai_tools_av_keyring}" "${signature}" "${inventory}" 2>/dev/null)" \
        || gpgv_exit_status=$?
    if (( gpgv_exit_status == 1 )); then
        _ai_tools_av_mismatch "set ${set_name}: gpgv rejects the signature ${signature} over ${inventory}"
        return 1
    fi
    if (( gpgv_exit_status != 0 )); then
        _ai_tools_av_unverifiable "set ${set_name}: gpgv could not verify ${signature} (exit ${gpgv_exit_status}): the signing key is not in ${_ai_tools_av_keyring}, or a file could not be read"
        return 2
    fi
    signer_primary="$(printf '%s\n' "${gpgv_status_output}" | awk '/^\[GNUPG:\] VALIDSIG / { print $NF; exit }')"
    [[ "${signer_primary}" =~ ^[0-9A-F]{40}$ ]] \
        || { _ai_tools_av_unverifiable "set ${set_name}: gpgv accepted ${signature} without a VALIDSIG line"; return 2; }
    for allowed_primary in "${_ai_tools_av_signers[@]}"; do
        [[ "${allowed_primary}" == "${signer_primary}" ]] && { matched=yes; break; }
    done
    if [[ "${matched}" != yes ]]; then
        _ai_tools_av_unverifiable "set ${set_name}: ${signature} is signed by primary ${signer_primary}, which the binding for ${set_name} does not name"
        return 2
    fi
    ai_tools_assets_check_inventory "${set_dir}" || return $?
    printf '%s' "${signer_primary}"
    return 0
}
