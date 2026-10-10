#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/records-tsv.lib.sh
# The TSV wire format of a record stream: the canonical byte escape, its strict decoder, the item framing, the record
# identity and the row writer. The model and the report state are records-base.lib.sh, sourced here; what a consumer may
# rely on is stated once in ai-tools-records(5), which carries the same escape, the same identity recipe and a reference
# decoder in Python that tests/unit/records.sh runs over the same fixtures as _ai_tools_records_tsv__decode_into.
#
# The escape is total and canonical, so every path byte survives from the collector to the reader and one value has one
# encoding: a byte 0x20-0x7e other than `\` is written as itself; `\`, TAB, LF and CR as `\\`, `\t`, `\n` and `\r`;
# every other byte as `\x` and two lowercase hex digits. The encoder runs under `local LC_ALL=C`, which makes bash index
# a string by bytes for that one function (a UTF-8 caller locale would index by code point and print `e9` for the byte
# pair of an e-acute), and takes a fast path for a value of printable ASCII without `\`, which is what most fields hold.
# The decoder rejects a field the encoder could not have written -- a raw byte outside 0x20-0x7e, an unknown
# or truncated escape, uppercase hex, `\x00`, and a `\x` form for a byte that has a literal or named form --
# so the encoding stays one-to-one and a forged or damaged field is refused rather than read.
#
# `item` is a list of components framed so the list is recoverable: each component encoded on its own, the results
# joined with one raw TAB, and the joined value encoded again when the row is written like every field.
# _ai_tools_records_tsv__frame_into refuses an empty component, which is what keeps `[]` (the empty field) and `[""]`
# apart. `record-id` is the first 16 hex digits of SHA-256 over exactly `ENC(code) TAB ENC(subject) TAB ENC(item)`,
# so it survives a change to `detail`, `severity` or a timestamp and moves when the situation, the subject
# or a component does.
#
# The writer validates, encodes and hashes before it prints anything; a defect there is noted as `unreadable`
# in the report state and the function returns 0 with no row, so a consumer under `set -e` reaches its exit status
# and reports 5. The header goes out with the first row and only then, so a clean run prints nothing. A failed write (a
# closed pipe) is the one non-zero return, and the command then exits non-zero.
#
# Output-variable convention: as records-base.lib.sh states -- every local here starts with `_records_`
# and a per-function stem, and a public function refuses an output name it could shadow. The public functions check
# the name and delegate to an `_into` helper, which is what the libraries call among themselves with their own
# `_records_`
# names.

# shellcheck disable=SC2034  # include guard, read on the next source of this lib
if [[ -n "${_AI_TOOLS_RECORDS_TSV__LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_RECORDS_TSV__LOADED=1

# shellcheck source=SCRIPTDIR/records-base.lib.sh
source "${BASH_SOURCE[0]%/*}/records-base.lib.sh"

# _ai_tools_records_tsv__encode_into <name> <value>: the canonical encoding of <value>, `printf -v` into <name>.
_ai_tools_records_tsv__encode_into() {
    local LC_ALL=C
    local _records_enc_value="$2" _records_enc_out="" _records_enc_byte _records_enc_hex _records_enc_i
    if [[ "${_records_enc_value}" != *[![:print:]]* && "${_records_enc_value}" != *"\\"* ]]; then
        printf -v "$1" '%s' "${_records_enc_value}"
        return 0
    fi
    for (( _records_enc_i = 0; _records_enc_i < ${#_records_enc_value}; _records_enc_i++ )); do
        _records_enc_byte="${_records_enc_value:_records_enc_i:1}"
        case "${_records_enc_byte}" in
            "\\")         _records_enc_out+="\\\\" ;;
            $'\t')        _records_enc_out+='\t' ;;
            $'\n')        _records_enc_out+='\n' ;;
            $'\r')        _records_enc_out+='\r' ;;
            [[:print:]])  _records_enc_out+="${_records_enc_byte}" ;;
            *)
                printf -v _records_enc_hex '%02x' "'${_records_enc_byte}"
                _records_enc_out+="\\x${_records_enc_hex}" ;;
        esac
    done
    printf -v "$1" '%s' "${_records_enc_out}"
}

# _ai_tools_records_tsv__decode_into <name> <field>: the bytes <field> encodes, `printf -v` into <name>; returns 1
# and empties <name> when <field> the encoder could not have written.
_ai_tools_records_tsv__decode_into() {
    local LC_ALL=C
    local _records_dec_rest="$2" _records_dec_out="" _records_dec_plain _records_dec_hex _records_dec_byte
    if [[ "${_records_dec_rest}" == *[![:print:]]* ]]; then
        printf -v "$1" ''
        return 1
    fi
    while [[ -n "${_records_dec_rest}" ]]; do
        _records_dec_plain="${_records_dec_rest%%\\*}"
        _records_dec_out+="${_records_dec_plain}"
        _records_dec_rest="${_records_dec_rest:${#_records_dec_plain}}"
        [[ -n "${_records_dec_rest}" ]] || break
        case "${_records_dec_rest:1:1}" in
            "\\") _records_dec_out+="\\";  _records_dec_rest="${_records_dec_rest:2}" ;;
            t)   _records_dec_out+=$'\t'; _records_dec_rest="${_records_dec_rest:2}" ;;
            n)   _records_dec_out+=$'\n'; _records_dec_rest="${_records_dec_rest:2}" ;;
            r)   _records_dec_out+=$'\r'; _records_dec_rest="${_records_dec_rest:2}" ;;
            x)
                _records_dec_hex="${_records_dec_rest:2:2}"
                [[ "${_records_dec_hex}" =~ ^[0-9a-f]{2}$ ]] || { printf -v "$1" ''; return 1; }
                # A byte with a literal or named form, and NUL, have no `\x` form.
                case "${_records_dec_hex}" in
                    00|09|0a|0d) printf -v "$1" ''; return 1 ;;
                esac
                if (( 16#${_records_dec_hex} >= 0x20 && 16#${_records_dec_hex} <= 0x7e )); then
                    printf -v "$1" ''; return 1
                fi
                printf -v _records_dec_byte '%b' "\\x${_records_dec_hex}"
                _records_dec_out+="${_records_dec_byte}"
                _records_dec_rest="${_records_dec_rest:4}" ;;
            *) printf -v "$1" ''; return 1 ;;
        esac
    done
    printf -v "$1" '%s' "${_records_dec_out}"
}

# _ai_tools_records_tsv__frame_into <name> [<component>...]: the framed item, `printf -v` into <name>; returns 1
# and empties <name> when a component is empty.
_ai_tools_records_tsv__frame_into() {
    local _records_frame_name="$1" _records_frame_component _records_frame_encoded _records_frame_joined=""
    local _records_frame_first=1
    shift
    for _records_frame_component in "$@"; do
        if [[ -z "${_records_frame_component}" ]]; then
            printf -v "${_records_frame_name}" ''
            return 1
        fi
        _ai_tools_records_tsv__encode_into _records_frame_encoded "${_records_frame_component}"
        if (( _records_frame_first )); then
            _records_frame_joined="${_records_frame_encoded}"
            _records_frame_first=0
        else
            _records_frame_joined+=$'\t'"${_records_frame_encoded}"
        fi
    done
    printf -v "${_records_frame_name}" '%s' "${_records_frame_joined}"
}

# _ai_tools_records_tsv__calculate_record_id_into <name> <code> <subject> <item>: the record id, `printf -v`
# into <name>; returns 1 and empties <name> when sha256sum fails or does not yield 64 hex digits.
_ai_tools_records_tsv__calculate_record_id_into() {
    local _records_id_code _records_id_subject _records_id_item _records_id_hash
    _ai_tools_records_tsv__encode_into _records_id_code "$2"
    _ai_tools_records_tsv__encode_into _records_id_subject "$3"
    _ai_tools_records_tsv__encode_into _records_id_item "$4"
    if ! _records_id_hash="$(printf '%s\t%s\t%s' "${_records_id_code}" "${_records_id_subject}" \
            "${_records_id_item}" | sha256sum 2>/dev/null)"; then
        printf -v "$1" ''
        return 1
    fi
    if [[ ! "${_records_id_hash}" =~ ^[0-9a-f]{64}[[:space:]] ]]; then
        printf -v "$1" ''
        return 1
    fi
    printf -v "$1" '%s' "${_records_id_hash:0:16}"
}

# ai_tools_records_tsv__encode_field <var> <value>: the canonical encoding of <value> into <var>. Returns 1 without
# writing when <var> is a name these libraries refuse.
ai_tools_records_tsv__encode_field() {
    ai_tools_records_base__is_output_name_valid "$1" || return 1
    _ai_tools_records_tsv__encode_into "$1" "$2"
}

# ai_tools_records_tsv__decode_field <var> <field>: the bytes <field> encodes into <var>; returns 1 and empties <var>
# on a field that the encoder could not have written, and returns 1 without writing on a refused name.
ai_tools_records_tsv__decode_field() {
    ai_tools_records_base__is_output_name_valid "$1" || return 1
    _ai_tools_records_tsv__decode_into "$1" "$2"
}

# ai_tools_records_tsv__frame_item_components <var> [<component>...]: the framed item into <var>; no components give
# the empty string. Returns 1 and empties <var> when any component is empty, and returns 1 without writing on a refused
# name.
ai_tools_records_tsv__frame_item_components() {
    ai_tools_records_base__is_output_name_valid "$1" || return 1
    _ai_tools_records_tsv__frame_into "$@"
}

# ai_tools_records_tsv__calculate_record_id <var> <code> <subject> <item>: the record id into <var>, <item> already
# framed. Returns 1 and empties <var> when sha256sum fails or does not yield 64 hex digits, and returns 1 without
# writing on a refused name.
ai_tools_records_tsv__calculate_record_id() {
    ai_tools_records_base__is_output_name_valid "$1" || return 1
    _ai_tools_records_tsv__calculate_record_id_into "$@"
}

# ai_tools_records_tsv__write_record <occurred-at> <code> <severity> <finding> <subject-type> <operator> <item>
# <subject> <detail>: validate, encode and hash the row, then print the header (once) and the row, and note the row's
# severity. A model defect notes `unreadable`, prints nothing and returns 0; a failed write notes `unreadable`
# and returns 1. <item> is a value ai_tools_records_tsv__frame_item_components framed.
ai_tools_records_tsv__write_record() {
    local _records_write_id _records_write_field _records_write_encoded _records_write_row="" _records_write_out
    local _records_write_header="" _records_write_column
    if ! ai_tools_records_base__is_valid_record "$@"; then
        ai_tools_records_base__accumulate_severity unreadable
        return 0
    fi
    if ! _ai_tools_records_tsv__calculate_record_id_into _records_write_id "$2" "$8" "$7"; then
        ai_tools_records_base__accumulate_severity unreadable
        return 0
    fi
    # Stream order: observed-at occurred-at code record-id severity finding subject-type operator item subject detail.
    for _records_write_field in "${AI_TOOLS_RECORDS_BASE__OBSERVED_AT}" "$1" "$2" "${_records_write_id}" "$3" "$4" "$5" \
            "$6" "$7" "$8" "$9"; do
        _ai_tools_records_tsv__encode_into _records_write_encoded "${_records_write_field}"
        _records_write_row+="${_records_write_encoded}"$'\t'
    done
    _records_write_row="${_records_write_row%$'\t'}"
    _records_write_out="${_records_write_row}"$'\n'
    if (( ! AI_TOOLS_RECORDS_BASE__HEADER_PRINTED )); then
        for _records_write_column in "${AI_TOOLS_RECORDS_BASE__COLUMNS[@]}"; do
            _records_write_header+="${_records_write_column%%:*}"$'\t'
        done
        _records_write_out="${_records_write_header%$'\t'}"$'\n'"${_records_write_out}"
    fi
    if ! printf '%s' "${_records_write_out}"; then
        ai_tools_records_base__accumulate_severity unreadable
        return 1
    fi
    AI_TOOLS_RECORDS_BASE__HEADER_PRINTED=1
    ai_tools_records_base__accumulate_severity "$3"
}
