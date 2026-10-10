#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/assets-verify.lib.sh
# Verify that an installed asset set is the one its publisher signed: `SHA256SUMS.asc` is a signature, by a key
# the root-owned binding for that set name pins, over a `SHA256SUMS` that lists every file of the set once with its
# hash. Sourced as root by the assets resolver, which does not link any asset of a set this library refuses; the roots,
# the binding directory and the reason tokens are in shipped-assets.rule.md.
#
# Status contract ref-section-b8h3, shared with entrypoint-verify.lib.sh and npm-verify.lib.sh; here a 2 refuses
# as a 1 does:
#   0  verified; the signer's primary fingerprint is printed on stdout
#   1  MISMATCH (MSG-T3M3) -- the signed inventory and the tree cannot both be what the publisher built: gpgv rejects
#      the signature, or the inventory does not describe the tree
#   2  unable to verify (MSG-Q6Y8) -- an input the check could not read, over its bound, untrusted, or a signer
#      no binding names
# The resolver reads 1 as set-tampered and 2 as set-unverified. The signature is checked before the inventory is
# parsed, so a tree whose signature fails is not read further; each function's doc names the inputs it maps to each
# status. A path, listed or found, is held to ai_tools_conf_portable_name_valid (conf.lib.sh) per component, and
# a name outside that set is a mismatch: the format's `file.name` rule refuses one at build, so a signed set does not
# carry one. Every name, line and tool message a diagnostic carries passes log.lib.sh's allowlist sanitizer first,
# since a refused set's bytes are whoever wrote them.
#
# A binding is AI_TOOLS_ASSETS_BINDINGS_DIR/<set>.conf in the shared KEY=value grammar, read line by line
# through conf.lib.sh and not sourced; ai_tools_assets_read_binding states its keys and every refusal. The keyring it
# names is binary, written at build time by ai_tools_assets_write_binary_keyring from the armored key beside it.

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
# log.lib.sh is REQUIRED for the same reason: it carries the allowlist sanitizer every diagnostic's untrusted part
# passes, and a library that printed a set's bytes raw to a terminal or the journal would be the defect the sanitizer
# exists for.
# shellcheck source=SCRIPTDIR/log.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || ! declare -F ai_tools_log_sanitize >/dev/null 2>&1; then
    printf 'assets-verify: log.lib.sh did not load, so the set verifier is not defined\n' >&2
    return 1
fi
_AI_TOOLS_ASSETS_VERIFY_LIB_LOADED=1

# The shipped bindings, redirected by a root-only test hook with the standing of AI_TOOLS_ENTRYPOINT_PIN_DIR: `sudo`
# strips the name, and every consumer runs as root. An operator binding under /etc/ai-tools/assets-bindings.d/ is not
# read by this release.
: "${AI_TOOLS_ASSETS_BINDINGS_DIR:=/usr/local/lib/ai-tools/assets-bindings.d}"
readonly AI_TOOLS_ASSETS_INVENTORY=SHA256SUMS
readonly AI_TOOLS_ASSETS_SIGNATURE=SHA256SUMS.asc
# The bound each read takes: a file of the set, the inventory among them, at the format's per-file bound; the signature
# and a binding at 64 KiB; the set at the format's file count and payload bound. A set past a bound is not read further.
readonly AI_TOOLS_ASSETS_FILE_MAX_BYTES=1048576
readonly AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES=65536
readonly AI_TOOLS_ASSETS_FILE_MAX_COUNT=2000
readonly AI_TOOLS_ASSETS_SET_MAX_BYTES=67108864

# _ai_tools_assets_verify_warn [code] <message...> : this library's one report, on stderr and, when log.lib.sh is loaded
#   by the caller, in journald. A leading message code goes on its own line ahead of the message, the shape
#   tests/lib/harness.sh's assert_msg reads. Returns 0, so a report does not change a verdict.
_ai_tools_assets_verify_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'assets-verify: %s\n' "$*" >&2
    ai_tools_log_warn "assets-verify: $*"
    return 0
}

# _ai_tools_assets_verify_sanitize_for_display <text> : print <text> as a diagnostic carries it: at most 80 characters,
#   through the allowlist sanitizer, so a name or a line read from a set does not reach a terminal or the journal raw.
_ai_tools_assets_verify_sanitize_for_display() {
    ai_tools_log_sanitize "${1:0:80}"
}

# _ai_tools_assets_verify_report_mismatch <detail...> : report a status-1 refusal under its code. The caller returns 1.
_ai_tools_assets_verify_report_mismatch() {
    _ai_tools_assets_verify_warn MSG-T3M3 "the set is refused as tampered -- $*"
}

# _ai_tools_assets_verify_report_unverifiable <detail...> : report a status-2 refusal under its code. The caller returns
# 2.
_ai_tools_assets_verify_report_unverifiable() {
    _ai_tools_assets_verify_warn MSG-Q6Y8 "the set is refused as unverified -- $*"
}

# _ai_tools_assets_verify_is_bounded_regular_file <path> <max-bytes> : succeed when <path> is a readable regular file,
#   not a symlink, of at most <max-bytes>. Every file this library opens passes it first, so a link or a special file
#   swapped into a name is refused before a read.
_ai_tools_assets_verify_is_bounded_regular_file() {
    local path="${1:-}" max_bytes="${2:-0}" size_bytes
    [[ -n "${path}" && ! -L "${path}" && -f "${path}" && -r "${path}" ]] || return 1
    size_bytes="$(stat -c '%s' "${path}" 2>/dev/null)" || return 1
    [[ "${size_bytes}" =~ ^[0-9]+$ ]] && (( size_bytes <= max_bytes ))
}

# ai_tools_assets_is_valid_set_name <name> : succeed when <name> follows the set-name grammar of the assets format:
#   1 to 64 characters of a-z, 0-9 and single hyphens, starting and ending with a letter or digit. A name becomes
#   a path component of the binding, so an invalid one is refused before it is joined to a path.
ai_tools_assets_is_valid_set_name() {
    [[ "${1-}" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ && "${1-}" != *--* ]]
}

# ai_tools_assets_is_valid_signer_fingerprint <item> : succeed when <item> is a typed primary fingerprint,
#   `openpgp:` then 40 hex digits. The type is a prefix so a later signature scheme is a new prefix and not a new key
#   of the binding.
ai_tools_assets_is_valid_signer_fingerprint() {
    [[ "${1-}" =~ ^openpgp:[0-9A-Fa-f]{40}$ ]]
}

# ai_tools_assets_write_binary_keyring <armored-key> <keyring> : write the binary keyring gpgv reads from an
#   ASCII-armored public key file. gpgv on EL9 exits 2 on an armored keyring, so the keyring is written binary at build
#   time, by the spec's %install and by install.sh. The armor is base64 between the PUBLIC KEY BLOCK markers, with
#   header lines and a `=` CRC line, so dropping those and decoding is the whole conversion, and gpgv, the verify-only
#   half of gnupg2, stays the one dependency: no gpg homedir is made per call. Several armored blocks in one file decode
#   to one keyring. A partial output is removed; returns 1 when the input does not hold a key.
ai_tools_assets_write_binary_keyring() {
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

# ai_tools_assets_read_binding <set-name> : read the binding for <set-name> into _AI_TOOLS_ASSETS_VERIFY_SIGNERS (the
#   primary fingerprints, upper-case, without their type) and _AI_TOOLS_ASSETS_VERIFY_KEYRING (the keyring path).
#   Returns 0, or 2 under MSG-Q6Y8 for a name outside the grammar, a bindings directory or binding file
#   ai_tools_conf_is_trusted refuses, an absent binding, a line outside `set`, `signers` and `keyring`, a `set` other
#   than the name, an empty or invalid signers list, a signer outside its shape, or a keyring that is not an absolute
#   path to a trusted, non-empty regular file in a trusted directory. Every failure leaves both outputs empty.
ai_tools_assets_read_binding() {
    local set_name="${1:-}" directory="${AI_TOOLS_ASSETS_BINDINGS_DIR}" binding line key item keyring
    local -a signers=() parsed_signers=()
    _AI_TOOLS_ASSETS_VERIFY_SIGNERS=()
    _AI_TOOLS_ASSETS_VERIFY_KEYRING=""
    ai_tools_assets_is_valid_set_name "${set_name}" \
        || { _ai_tools_assets_verify_report_unverifiable "'$(_ai_tools_assets_verify_sanitize_for_display "${set_name}")' is not a set name"; return 2; }
    binding="${directory}/${set_name}.conf"
    ai_tools_conf_is_trusted "${directory}" \
        || { _ai_tools_assets_verify_report_unverifiable "bindings directory ${directory} is not trusted ($(ai_tools_conf_untrusted_reason "${directory}"))"; return 2; }
    [[ -e "${binding}" || -L "${binding}" ]] \
        || { _ai_tools_assets_verify_report_unverifiable "set ${set_name} has no binding at ${binding}, so no key is pinned for it"; return 2; }
    ai_tools_conf_is_trusted "${binding}" \
        || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} is not trusted ($(ai_tools_conf_untrusted_reason "${binding}"))"; return 2; }
    _ai_tools_assets_verify_is_bounded_regular_file "${binding}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" \
        || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} is not a regular file of at most ${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES} bytes"; return 2; }
    # Every live line is one of the three keys: a key this reader does not define decides neither a signer nor a keyring
    # here, and a binding that carries one is read by a reader that defines it, not past by this one.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "${line}" == *=* && "${key}" =~ ^(set|signers|keyring)$ ]] \
            || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} holds a line this reader does not define: $(_ai_tools_assets_verify_sanitize_for_display "${line}")"; return 2; }
    done < "${binding}"
    [[ "$(ai_tools_conf_get "${binding}" set)" == "${set_name}" ]] \
        || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} does not name set ${set_name} in its set= line"; return 2; }
    ai_tools_conf_list signers "${binding}" signers \
        || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} has no signers= line"; return 2; }
    (( ${#signers[@]} > 0 )) \
        || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} names no signer"; return 2; }
    for item in "${signers[@]}"; do
        ai_tools_assets_is_valid_signer_fingerprint "${item}" \
            || { _ai_tools_assets_verify_report_unverifiable "binding ${binding} signer '$(_ai_tools_assets_verify_sanitize_for_display "${item}")' is not openpgp:<40 hex digits>"; return 2; }
        parsed_signers+=("${item#openpgp:}")
    done
    keyring="$(ai_tools_conf_get "${binding}" keyring)"
    if [[ "${keyring}" != /* || "${keyring}" == *..* ]] \
        || ! ai_tools_conf_is_trusted "${keyring%/*}" || ! ai_tools_conf_is_trusted "${keyring}" \
        || ! _ai_tools_assets_verify_is_bounded_regular_file "${keyring}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" || [[ ! -s "${keyring}" ]]; then
        _ai_tools_assets_verify_report_unverifiable "binding ${binding} keyring '$(_ai_tools_assets_verify_sanitize_for_display "${keyring}")' is not an absolute path to a trusted, non-empty regular file in a trusted directory"
        return 2
    fi
    # The outputs are assigned once, after every check, so a binding refused at any line publishes neither.
    _AI_TOOLS_ASSETS_VERIFY_SIGNERS=("${parsed_signers[@]^^}")
    _AI_TOOLS_ASSETS_VERIFY_KEYRING="${keyring}"
    return 0
}

# _ai_tools_assets_verify_is_valid_inventory_path <path> : succeed when <path> is a relative path inside a set: no
#   leading or trailing `/`, every component one ai_tools_conf_portable_name_valid accepts, and not the inventory or its
#   signature, which list themselves nowhere. Read over a listed path and over a found one alike, so the two readers
#   accept one set of names. The components are split on `/` alone by `read -a`, which does not expand a glob character
#   on the way and stops at a newline, so a newline is refused ahead of the split.
_ai_tools_assets_verify_is_valid_inventory_path() {
    local path="${1-}" component
    local -a components=()
    [[ -n "${path}" && "${path}" != /* && "${path}" != */ && "${path}" != *$'\n'* ]] || return 1
    [[ "${path}" != "${AI_TOOLS_ASSETS_INVENTORY}" && "${path}" != "${AI_TOOLS_ASSETS_SIGNATURE}" ]] || return 1
    IFS=/ read -r -a components <<< "${path}"
    (( ${#components[@]} > 0 )) || return 1
    for component in "${components[@]}"; do
        ai_tools_conf_portable_name_valid "${component}" || return 1
    done
    return 0
}

# ai_tools_assets_verify_inventory <set-directory> : the inventory half, callable alone for the conformance job:
#   SHA256SUMS under <set-directory> lists every file of the set other than itself and SHA256SUMS.asc exactly once,
#   as `<sha256>  <relative path>`, and each hash matches. Returns 0; 1 under MSG-T3M3 for a line outside that shape,
#   a path outside the set, a path listed twice, a file listed and absent, present and unlisted, not a regular file,
#   or whose hash differs; 2 under MSG-Q6Y8 for a directory or inventory the bounded read refuses, a walk that did not
#   complete, a file over the per-file bound, a set over the file-count or payload bound, or no sha256sum. Prints
#   nothing. The walk is written to a file of its own so its exit status is read: an enumeration that ended early
#   leaves a tree whose listed files match and whose unlisted ones were never seen, which no count would show. The tree
#   is then hashed in one sha256sum call over the names the walk found. This function owns that file alone, made here
#   and removed after the check it wraps returns, so no trap of the caller's is replaced.
ai_tools_assets_verify_inventory() {
    local set_dir="${1:-}" listing status=0
    [[ -n "${set_dir}" && ! -L "${set_dir}" && -d "${set_dir}" ]] \
        || { _ai_tools_assets_verify_report_unverifiable "'$(_ai_tools_assets_verify_sanitize_for_display "${set_dir}")' is not a directory"; return 2; }
    listing="$(mktemp 2>/dev/null)" \
        || { _ai_tools_assets_verify_report_unverifiable "${set_dir}: no temporary file for the walk"; return 2; }
    _ai_tools_assets_verify_inventory_listing "${set_dir}" "${listing}" || status=$?
    rm -f -- "${listing}"
    return "${status}"
}

# _ai_tools_assets_verify_inventory_listing <set-directory> <listing-file> : ai_tools_assets_verify_inventory's check,
#   with the walk written to <listing-file>, which the caller made and removes. Each record of the listing is read whole
#   and split at its first tab, so a name is kept byte for byte: a tab in IFS is collapsed, and a name opening with one
#   would read as another file's and that file be hashed twice. Each name is met once.
_ai_tools_assets_verify_inventory_listing() {
    local set_dir="${1:-}" listing="${2:-}" inventory line digest path record size_bytes checksum_output
    local hashed_count=0 total_bytes=0 walk_error walk_status=0
    local line_shape='^([0-9a-f]{64}) [ *](.+)$'
    local -A expected_digests_by_path=() seen=()
    local -a discovered_file_paths=()
    inventory="${set_dir}/${AI_TOOLS_ASSETS_INVENTORY}"
    _ai_tools_assets_verify_is_bounded_regular_file "${inventory}" "${AI_TOOLS_ASSETS_FILE_MAX_BYTES}" \
        || { _ai_tools_assets_verify_report_unverifiable "${inventory} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"; return 2; }
    command -v sha256sum >/dev/null 2>&1 \
        || { _ai_tools_assets_verify_report_unverifiable "sha256sum not found"; return 2; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ${line_shape} ]] \
            || { _ai_tools_assets_verify_report_mismatch "${inventory}: a line is not <sha256>  <path>: $(_ai_tools_assets_verify_sanitize_for_display "${line}")"; return 1; }
        digest="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
        _ai_tools_assets_verify_is_valid_inventory_path "${path}" \
            || { _ai_tools_assets_verify_report_mismatch "${inventory}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is not a relative path inside the set"; return 1; }
        [[ -z "${expected_digests_by_path[${path}]+x}" ]] \
            || { _ai_tools_assets_verify_report_mismatch "${inventory}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is listed twice"; return 1; }
        expected_digests_by_path["${path}"]="${digest}"
        (( ${#expected_digests_by_path[@]} <= AI_TOOLS_ASSETS_FILE_MAX_COUNT )) \
            || { _ai_tools_assets_verify_report_unverifiable "${inventory}: lists more than ${AI_TOOLS_ASSETS_FILE_MAX_COUNT} files"; return 2; }
    done < "${inventory}"
    walk_error="$( (cd "${set_dir}" && find . -mindepth 1 ! -type d -printf '%s\t%P\0' > "${listing}") 2>&1 )" \
        || walk_status=$?
    (( walk_status == 0 )) \
        || { _ai_tools_assets_verify_report_unverifiable "${set_dir}: the walk did not complete (find exit ${walk_status}): $(_ai_tools_assets_verify_sanitize_for_display "${walk_error%%$'\n'*}")"; return 2; }
    # Every file of the tree is a listed regular file within the bounds. A name outside the portable set, a link
    # or a special file is a mismatch here, as the file-shape rules refuse it at the resolver; the name is held
    # before the path is joined or printed.
    while IFS= read -r -d '' record; do
        size_bytes="${record%%$'\t'*}"
        path="${record#*$'\t'}"
        [[ "${path}" == "${AI_TOOLS_ASSETS_INVENTORY}" || "${path}" == "${AI_TOOLS_ASSETS_SIGNATURE}" ]] && continue
        _ai_tools_assets_verify_is_valid_inventory_path "${path}" \
            || { _ai_tools_assets_verify_report_mismatch "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is a file name outside the portable set, which the inventory cannot list"; return 1; }
        [[ -z "${seen[${path}]+x}" ]] \
            || { _ai_tools_assets_verify_report_mismatch "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' was met twice in the walk"; return 1; }
        seen["${path}"]=1
        [[ ! -L "${set_dir}/${path}" && -f "${set_dir}/${path}" ]] \
            || { _ai_tools_assets_verify_report_mismatch "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is not a regular file"; return 1; }
        if ! [[ "${size_bytes}" =~ ^[0-9]+$ ]] || (( size_bytes > AI_TOOLS_ASSETS_FILE_MAX_BYTES )); then
            _ai_tools_assets_verify_report_unverifiable "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"
            return 2
        fi
        total_bytes=$(( total_bytes + size_bytes ))
        (( total_bytes <= AI_TOOLS_ASSETS_SET_MAX_BYTES && ${#discovered_file_paths[@]} < AI_TOOLS_ASSETS_FILE_MAX_COUNT )) \
            || { _ai_tools_assets_verify_report_unverifiable "${set_dir}: holds more than ${AI_TOOLS_ASSETS_FILE_MAX_COUNT} files or ${AI_TOOLS_ASSETS_SET_MAX_BYTES} bytes"; return 2; }
        [[ -n "${expected_digests_by_path[${path}]+x}" ]] \
            || { _ai_tools_assets_verify_report_mismatch "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is in the set and not in ${AI_TOOLS_ASSETS_INVENTORY}"; return 1; }
        discovered_file_paths+=("${path}")
    done < "${listing}"
    if (( ${#discovered_file_paths[@]} != ${#expected_digests_by_path[@]} )); then
        for path in "${!expected_digests_by_path[@]}"; do
            [[ -e "${set_dir}/${path}" ]] \
                || { _ai_tools_assets_verify_report_mismatch "${inventory}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' is listed and not in the set"; return 1; }
        done
        _ai_tools_assets_verify_report_mismatch "${inventory}: lists ${#expected_digests_by_path[@]} files, the set holds ${#discovered_file_paths[@]}"
        return 1
    fi
    (( ${#discovered_file_paths[@]} > 0 )) \
        || { _ai_tools_assets_verify_report_mismatch "${set_dir}: holds no file beside ${AI_TOOLS_ASSETS_INVENTORY}"; return 1; }
    checksum_output="$(cd "${set_dir}" && sha256sum -- "${discovered_file_paths[@]}" 2>/dev/null)" \
        || { _ai_tools_assets_verify_report_unverifiable "${set_dir}: a file could not be hashed"; return 2; }
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        digest="${line%% *}"
        path="${line#* }"
        path="${path# }"
        [[ "${expected_digests_by_path[${path}]-}" == "${digest}" ]] \
            || { _ai_tools_assets_verify_report_mismatch "${set_dir}: '$(_ai_tools_assets_verify_sanitize_for_display "${path}")' does not match its ${AI_TOOLS_ASSETS_INVENTORY} line"; return 1; }
        hashed_count=$(( hashed_count + 1 ))
    done <<< "${checksum_output}"
    (( hashed_count == ${#discovered_file_paths[@]} )) \
        || { _ai_tools_assets_verify_report_unverifiable "${set_dir}: sha256sum reported ${hashed_count} files of ${#discovered_file_paths[@]}"; return 2; }
    return 0
}

# ai_tools_assets_verify_set <set-directory> <set-name> : the verifier the resolver calls. SHA256SUMS.asc under
#   <set-directory> verifies through gpgv against the keyring the binding for <set-name> names, by a key whose
#   VALIDSIG primary the binding's signers list, and SHA256SUMS describes the tree (ai_tools_assets_verify_inventory).
#   Prints the signer's primary fingerprint and returns 0; returns 1 under MSG-T3M3 for a signature gpgv rejects
#   or an inventory mismatch, 2 under MSG-Q6Y8 for an input the checks refuse: absent, over its bound, untrusted, or
#   unmatched by the binding.
#   gpgv reads the keyring named and no default one, and its exit status separates the two refusals as the contract
#   does: 1 for a signature it rejects, 2 for a key the keyring does not hold.
ai_tools_assets_verify_set() {
    local set_dir="${1:-}" set_name="${2:-}" inventory signature gpgv_status_output gpgv_exit_status=0
    local signer_primary allowed_primary matched=no
    [[ -n "${set_dir}" && ! -L "${set_dir}" && -d "${set_dir}" ]] \
        || { _ai_tools_assets_verify_report_unverifiable "'$(_ai_tools_assets_verify_sanitize_for_display "${set_dir}")' is not a directory"; return 2; }
    ai_tools_assets_is_valid_set_name "${set_name}" \
        || { _ai_tools_assets_verify_report_unverifiable "'$(_ai_tools_assets_verify_sanitize_for_display "${set_name}")' is not a set name"; return 2; }
    inventory="${set_dir}/${AI_TOOLS_ASSETS_INVENTORY}"
    signature="${set_dir}/${AI_TOOLS_ASSETS_SIGNATURE}"
    _ai_tools_assets_verify_is_bounded_regular_file "${inventory}" "${AI_TOOLS_ASSETS_FILE_MAX_BYTES}" \
        || { _ai_tools_assets_verify_report_unverifiable "set ${set_name}: ${inventory} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_FILE_MAX_BYTES} bytes"; return 2; }
    _ai_tools_assets_verify_is_bounded_regular_file "${signature}" "${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES}" \
        || { _ai_tools_assets_verify_report_unverifiable "set ${set_name}: ${signature} is absent, not a regular file, unreadable, or over ${AI_TOOLS_ASSETS_SMALL_FILE_MAX_BYTES} bytes"; return 2; }
    command -v gpgv >/dev/null 2>&1 \
        || { _ai_tools_assets_verify_report_unverifiable "set ${set_name}: gpgv not found; install gnupg2"; return 2; }
    ai_tools_assets_read_binding "${set_name}" || return 2
    gpgv_status_output="$(gpgv --status-fd 1 --keyring "${_AI_TOOLS_ASSETS_VERIFY_KEYRING}" "${signature}" "${inventory}" 2>/dev/null)" \
        || gpgv_exit_status=$?
    if (( gpgv_exit_status == 1 )); then
        _ai_tools_assets_verify_report_mismatch "set ${set_name}: gpgv rejects the signature ${signature} over ${inventory}"
        return 1
    fi
    if (( gpgv_exit_status != 0 )); then
        _ai_tools_assets_verify_report_unverifiable "set ${set_name}: gpgv could not verify ${signature} (exit ${gpgv_exit_status}): the signing key is not in ${_AI_TOOLS_ASSETS_VERIFY_KEYRING}, or a file could not be read"
        return 2
    fi
    signer_primary="$(printf '%s\n' "${gpgv_status_output}" | awk '/^\[GNUPG:\] VALIDSIG / { print $NF; exit }')"
    [[ "${signer_primary}" =~ ^[0-9A-F]{40}$ ]] \
        || { _ai_tools_assets_verify_report_unverifiable "set ${set_name}: gpgv accepted ${signature} without a VALIDSIG line"; return 2; }
    for allowed_primary in "${_AI_TOOLS_ASSETS_VERIFY_SIGNERS[@]}"; do
        [[ "${allowed_primary}" == "${signer_primary}" ]] && { matched=yes; break; }
    done
    if [[ "${matched}" != yes ]]; then
        _ai_tools_assets_verify_report_unverifiable "set ${set_name}: ${signature} is signed by primary ${signer_primary}, which the binding for ${set_name} does not name"
        return 2
    fi
    ai_tools_assets_verify_inventory "${set_dir}" || return $?
    printf '%s' "${signer_primary}"
    return 0
}
