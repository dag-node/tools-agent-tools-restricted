#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/records.sh
# Unit test for the record stream libraries (records-base.lib.sh, records-tsv.lib.sh) and the page that states their
# contract, ai-tools-records(5). What it pins, in the order the file runs:
#   * the schema: the exact header, unique names, the class order, and the page's COLUMNS section against the
#     library's registry, since a consumer is written from the page alone;
#   * the output-variable convention: a `printf -v` write lands in the caller's variable through a nested call, keeps
#     a value that ends in line feeds (a command substitution would strip them), and a name the libraries could shadow
#     is refused;
#   * the escape, byte for byte: every value 0x01-0xff against known answers a python3 snippet writes from the page's
#     rules, independently of the encoder (a round trip alone would share the encoder's defect); the byte-versus-code-
#     point trap under a UTF-8 caller locale; and every field the decoder must reject;
#   * decoder parity: the Python block the page carries, extracted between its two marker comments, rendered without
#     a pager or styling, and run over the same fixtures as the shell decoder, with the two outputs compared line for
#     line;
#   * the reader rules a consumer applies to a whole stream, driven through that same rendered decoder;
#   * the item framing, where the property is that two different component lists cannot give one field;
#   * the identity: the page's published vectors, what leaves the id alone and what moves it, and the fail direction
#     when sha256sum is missing -- no row, exit 5;
#   * the report state: every severity fold, an unknown token, an invalid row under `set -euo pipefail` (the script
#     must reach its exit and return 5), the reset between two reports, and a write to a closed pipe;
#   * the collector rules a report follows: the saved PID reporting a collector's exit where a bare `wait $!` reports
#     the wrong process, a collector failing before and after a row, the cap that keeps a deliberate stop apart from a
#     failure, and a path holding a tab and one holding a line feed carried end to end.
#
# It loads the CHECKOUT's libraries by path, not the installed copies, and prints the two paths as its first output:
# after an install the installed copy would otherwise pass while the checkout's code changes. The installed copy is
# covered by tests/integration/perms.sh and by the consumer suites. groff, python3 and sha256sum are dependencies:
# a missing one fails rather than skips, so the page's decoder is checked on every platform the suite runs on (the
# container selftest images install groff-base for it). Runs unprivileged.

# shellcheck disable=SC2154  # every output variable in this file is assigned by a library's `printf -v`
# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_LIB="${ROOT}/src/usr/local/lib/ai-tools/records-base.lib.sh"
TSV_LIB="${ROOT}/src/usr/local/lib/ai-tools/records-tsv.lib.sh"
PAGE="${ROOT}/src/usr/local/share/man/man5/ai-tools-records.5"
printf 'records-base: %s\nrecords-tsv:  %s\n' "${BASE_LIB}" "${TSV_LIB}"

section "records: loading the checkout's libraries (unit)"
if [[ ! -r "${BASE_LIB}" || ! -r "${TSV_LIB}" ]]; then
    fail "the checkout's records libraries are not readable"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${TSV_LIB}" \
        || ! declare -F ai_tools_records_begin_report >/dev/null 2>&1 \
        || ! declare -F ai_tools_records_tsv_write_record >/dev/null 2>&1; then
    fail "could not source ${TSV_LIB} or it does not define its functions"; finish; exit
fi
pass "records-tsv.lib.sh sources records-base.lib.sh and both define their functions"
for tool in groff python3 sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || { fail "${tool} is a dependency of this test and is not installed"; finish; exit; }
done
mktestdir

# The code every fixture row carries. It does not name a shipped message, so the index does not read it as a citation.
readonly TEST_CODE="MSG-A1B2"  # ref-index: ignore

# hex <value>: the value's bytes as lowercase hex, one line, for a result message or a comparison.
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }

# ── Schema ───────────────────────────────────────────────────────────────────────────────────────
section "records: the schema (unit)"
EXPECTED_HEADER="observed-at occurred-at code record-id severity finding subject-type operator item subject detail"
names=""
classes=""
for column in "${AI_TOOLS_RECORDS_COLUMNS[@]}"; do
    names+="${column%%:*} "
    classes+="${column#*:} "
done
if [[ "${names% }" == "${EXPECTED_HEADER}" ]]; then
    pass "AI_TOOLS_RECORDS_COLUMNS names the header in stream order"
else
    fail "AI_TOOLS_RECORDS_COLUMNS names '${names% }', expected '${EXPECTED_HEADER}'"
fi
if [[ "$(tr ' ' '\n' <<<"${names% }" | sort | uniq -d)" == "" ]]; then
    pass "every column name is unique"
else
    fail "a column name repeats: $(tr ' ' '\n' <<<"${names% }" | sort | uniq -d | tr '\n' ' ')"
fi
# The class order fixed -> enum -> id -> path -> text: each class's rank is at least the rank of the one before it.
rank_of() { case "$1" in fixed) echo 1;; enum) echo 2;; id) echo 3;; path) echo 4;; text) echo 5;; *) echo 0;; esac; }
previous=0; ordered=1
for class in ${classes}; do
    rank="$(rank_of "${class}")"
    (( rank >= previous && rank > 0 )) || ordered=0
    previous="${rank}"
done
(( ordered )) && pass "the columns are declared in class order (fixed, enum, id, path, text)" \
              || fail "the columns are not in class order: ${classes% }"
# The page's COLUMNS section, read as a `.SS <Class> columns` heading followed by `.TP` tags, against the registry.
# The page spells a class out for the reader (Enumerated, Identifier) where the registry holds its token.
page_columns="$(awk '
    $0==".SH COLUMNS"{on=1; next} /^\.SH /{on=0}
    on && /^\.SS /{ cls=tolower($2); sub(/^enumerated$/, "enum", cls); sub(/^identifier$/, "id", cls) }
    on && prev==".TP" && /^\.B /{ print $2 ":" cls }
    { prev=$0 }' "${PAGE}" | tr '\n' ' ')"
lib_columns="$(printf '%s ' "${AI_TOOLS_RECORDS_COLUMNS[@]}")"
if [[ "${page_columns}" == "${lib_columns}" ]]; then
    pass "ai-tools-records(5) COLUMNS lists the registry's columns, each under its class, in stream order"
else
    fail "ai-tools-records(5) COLUMNS reads '${page_columns% }', the registry '${lib_columns% }'"
fi
if [[ "$(sed -n '/^\.SH SYNOPSIS/,/^\.SH /p' "${PAGE}" | grep -x "${EXPECTED_HEADER}")" == "${EXPECTED_HEADER}" ]]; then
    pass "ai-tools-records(5) SYNOPSIS shows the header row"
else
    fail "ai-tools-records(5) SYNOPSIS does not show the header row as one line"
fi
if [[ "${AI_TOOLS_EXIT_FINDINGS}" == 4 && "${AI_TOOLS_EXIT_UNREADABLE}" == 5 ]]; then
    pass "AI_TOOLS_EXIT_FINDINGS is 4 and AI_TOOLS_EXIT_UNREADABLE is 5"
else
    fail "the exit constants read ${AI_TOOLS_EXIT_FINDINGS}/${AI_TOOLS_EXIT_UNREADABLE}"
fi

# ── Output variables ─────────────────────────────────────────────────────────────────────────────
section "records: output variables and dynamic scope (unit)"
plain=""
ai_tools_records_tsv_encode_field plain 'x'
[[ "${plain}" == "x" ]] && pass "a plain output name receives the encoding" || fail "plain name got '${plain}'"
# A caller whose own local carries the name of a lib-internal variable in a nested call (encode inside frame inside this
# function): the write must land here, not in the callee's local.
caller_with_locals() {
    local _records_frame_encoded="untouched" result=""
    ai_tools_records_tsv_frame_item_components result "a" "b"
    [[ "${result}" == $'a\tb' && "${_records_frame_encoded}" == "untouched" ]]
}
caller_with_locals && pass "a nested call writes the caller's variable and leaves the caller's same-named local alone" \
                   || fail "a nested call misdirected its write"
empty="stale"
ai_tools_records_tsv_encode_field empty ''
[[ "${empty}" == "" ]] && pass "an empty value encodes to the empty string" || fail "empty value got '${empty}'"
ai_tools_records_tsv_decode_field trailing 'a\n'
[[ "${trailing}" == $'a\n' ]] && pass "a value ending in a line feed keeps it (printf -v, not a command substitution)" \
                              || fail "trailing line feed lost: $(hex "${trailing}")"
ai_tools_records_tsv_decode_field trailing 'a\n\n\n'
[[ "${trailing}" == $'a\n\n\n' ]] && pass "a value ending in several line feeds keeps all of them" \
                                  || fail "trailing line feeds lost: $(hex "${trailing}")"
for refused in _records_x _AI_TOOLS_RECORDS_STATUS LC_ALL 'not a name' '1abc' ''; do
    if ai_tools_records_tsv_encode_field "${refused}" 'x' 2>/dev/null; then
        fail "output name '${refused}' was accepted"
    else
        pass "output name '${refused}' is refused"
    fi
done
[[ "${_AI_TOOLS_RECORDS_STATUS}" == ok ]] && pass "the refused state name was not written" \
                                          || fail "the refused write reached the report state"

# ── Encoding, known answers ──────────────────────────────────────────────────────────────────────
section "records: the escape against known answers (unit)"
# The answers are written from the page's three rules by python3, not by the encoder under test.
python3 - > "${TESTDIR}/known-answers" <<'EOF'
for b in range(1, 256):
    if b == 0x5c:
        e = '\\\\'
    elif b == 0x09:
        e = '\\t'
    elif b == 0x0a:
        e = '\\n'
    elif b == 0x0d:
        e = '\\r'
    elif 0x20 <= b <= 0x7e:
        e = chr(b)
    else:
        e = '\\x%02x' % b
    print('%02x\t%s' % (b, e))
EOF
[[ "$(wc -l < "${TESTDIR}/known-answers")" == 255 ]] || { fail "the known-answer fixture holds $(wc -l < "${TESTDIR}/known-answers") lines"; }
bad_encode=0; bad_decode=0
while IFS=$'\t' read -r code expected; do
    printf -v raw '%b' "\\x${code}"
    ai_tools_records_tsv_encode_field got "${raw}"
    [[ "${got}" == "${expected}" ]] || { bad_encode=1; fail "byte 0x${code} encodes as '${got}', expected '${expected}'"; }
    ai_tools_records_tsv_decode_field back "${expected}"
    [[ "${back}" == "${raw}" ]] || { bad_decode=1; fail "'${expected}' decodes to $(hex "${back}"), expected ${code}"; }
done < "${TESTDIR}/known-answers"
(( bad_encode )) || pass "every byte 0x01-0xff encodes as the page's rules state (255 known answers)"
(( bad_decode )) || pass "every known answer decodes back to its byte"
ai_tools_records_tsv_encode_field got $'\xff\xfe'
[[ "${got}" == '\xff\xfe' ]] && pass "invalid UTF-8 encodes byte by byte" || fail "invalid UTF-8 encoded as '${got}'"
ai_tools_records_tsv_encode_field got 'plain ASCII with spaces, punctuation ~ and [brackets]'
[[ "${got}" == 'plain ASCII with spaces, punctuation ~ and [brackets]' ]] \
    && pass "printable ASCII without a backslash is written as itself" || fail "printable ASCII changed: '${got}'"
# The code-point trap: under a UTF-8 caller locale bash indexes a string by code point, and the encoder must still see
# the two bytes of an e-acute. The locale is asserted to be in force before the case is read.
utf8_locale=""
for candidate in C.UTF-8 C.utf8 en_US.UTF-8; do
    if [[ "$(LC_ALL="${candidate}" bash -c 'v=$'"'"'\xc3\xa9'"'"'; printf %s "${#v}"' 2>/dev/null)" == 1 ]]; then
        utf8_locale="${candidate}"; break
    fi
done
if [[ -z "${utf8_locale}" ]]; then
    skip "encoding under a UTF-8 caller locale" "no UTF-8 locale takes effect on this host"
else
    got="$(LC_ALL="${utf8_locale}" bash -c 'source "$1"; ai_tools_records_tsv_encode_field o "caf$2"; printf %s "$o"' _ "${TSV_LIB}" $'\xc3\xa9')"
    [[ "${got}" == 'caf\xc3\xa9' ]] && pass "under ${utf8_locale} the encoder still writes the two bytes of an e-acute" \
                                    || fail "under ${utf8_locale} the encoder wrote '${got}'"
fi

# ── Decoder rejections and parity with the page ──────────────────────────────────────────────────
section "records: the strict decoder, and its parity with the page's Python decoder (unit)"
# One fixture file drives both decoders: every known answer, the fields each must reject, and a few compound values.
{
    cut -f2 "${TESTDIR}/known-answers"
    printf '%s\n' '\x41' '\x0a' '\x09' '\x0d' '\x00' '\xC3' '\xc' '\x' '\q' "a\\" 'a\tb\\c\xc3\xa9' 'plain' '' 'a\\\\b'
    printf 'a\tb\n'
    printf '\x01\n'
    printf '\x1b[31m\n'
    printf 'caf\xc3\xa9\n'
} > "${TESTDIR}/decoder-fixtures"
bad=0
for rejected in '\x41' '\x0a' '\x09' '\x0d' '\x00' '\xC3' '\xc' '\x' '\q' "a\\" $'a\tb' $'\x01' $'\x1b' $'caf\xc3\xa9'; do
    out="set"
    if ai_tools_records_tsv_decode_field out "${rejected}"; then
        bad=1; fail "the decoder accepted '$(hex "${rejected}")'"
    elif [[ "${out}" != "" ]]; then
        bad=1; fail "the decoder rejected '$(hex "${rejected}")' but left '${out}' in the output variable"
    fi
done
(( bad )) || pass "the decoder rejects a raw control, ESC, a raw tab, raw UTF-8, \\x41, \\x0a, \\x09, \\x0d, \\x00, uppercase hex, and each truncated or unknown escape, emptying the output"
ai_tools_records_tsv_decode_field out 'a\tb\\c\xc3\xa9'
[[ "${out}" == $'a\tb\\c\xc3\xa9' ]] && pass "a compound field decodes to its bytes" || fail "compound field decoded to $(hex "${out}")"

# The page's decoder: exactly one marked block, rendered alone, non-empty, defining decode_field.
begins="$(grep -c '^\.\\" records-decoder-begin$' "${PAGE}")"
ends="$(grep -c '^\.\\" records-decoder-end$' "${PAGE}")"
if [[ "${begins}" == 1 && "${ends}" == 1 ]]; then
    pass "ai-tools-records(5) carries exactly one marked decoder block"
else
    fail "ai-tools-records(5) carries ${begins} begin and ${ends} end markers"
fi
awk '/^\.\\" records-decoder-begin$/{f=1; next} /^\.\\" records-decoder-end$/{f=0} f' "${PAGE}" > "${TESTDIR}/decoder.roff"
groff -man -Tascii -P-cbou "${TESTDIR}/decoder.roff" 2>"${TESTDIR}/groff.err" > "${TESTDIR}/decoder.rendered" || true
python3 - "${TESTDIR}/decoder.rendered" "${TESTDIR}/decoder.py" <<'EOF'
import sys, textwrap
src = textwrap.dedent(open(sys.argv[1]).read())
open(sys.argv[2], 'w').write(src)
EOF
if [[ -s "${TESTDIR}/decoder.py" ]] && grep -q '^def decode_field' "${TESTDIR}/decoder.py"; then
    pass "the rendered decoder is non-empty and defines decode_field"
else
    fail "the rendered decoder is empty or does not define decode_field ($(head -c 200 "${TESTDIR}/groff.err"))"
fi
# Both decoders over the fixture file: one line per fixture, the decoded bytes as hex or REJECT.
{
    while IFS= read -r line; do
        if ai_tools_records_tsv_decode_field out "${line}"; then hex "${out}"; printf '\n'; else printf 'REJECT\n'; fi
    done < "${TESTDIR}/decoder-fixtures"
} > "${TESTDIR}/decoded.bash"
python3 - "${TESTDIR}/decoder.py" "${TESTDIR}/decoder-fixtures" > "${TESTDIR}/decoded.python" <<'EOF'
import sys
ns = {}
exec(open(sys.argv[1]).read(), ns)
for line in open(sys.argv[2], 'rb').read().split(b'\n')[:-1]:
    try:
        print(ns['decode_field'](line).hex())
    except ValueError:
        print('REJECT')
EOF
if [[ "$(wc -l < "${TESTDIR}/decoded.bash")" -gt 250 ]] && cmp -s "${TESTDIR}/decoded.bash" "${TESTDIR}/decoded.python"; then
    pass "the shell decoder and the page's Python decoder agree on every fixture ($(wc -l < "${TESTDIR}/decoded.bash") fields)"
else
    fail "the two decoders disagree:"$'\n'"$(diff "${TESTDIR}/decoded.bash" "${TESTDIR}/decoded.python" | head -n 10)"
fi

# ── The reader over a stream ─────────────────────────────────────────────────────────────────────
section "records: the reader rules over a whole stream (unit)"
# stream_case <label> <expect: ok|reject> <python expression on rows> <stream bytes as printf format>: drive read_stream
# over one stream and assert the outcome.
stream_case() {
    local label="$1" expect="$2" check="$3" fmt="$4" result
    # shellcheck disable=SC2059  # the fixture is a printf format by design: it carries \t and \n as written
    printf "${fmt}" > "${TESTDIR}/stream"
    result="$(python3 - "${TESTDIR}/decoder.py" "${TESTDIR}/stream" "${check}" <<'EOF'
import sys
ns = {}
exec(open(sys.argv[1]).read(), ns)
try:
    rows = ns['read_stream'](open(sys.argv[2], 'rb').read())
except ValueError as e:
    print('reject:', e)
else:
    print('ok' if eval(sys.argv[3], {'rows': rows, 'exit_status': ns['exit_status']}) else 'check failed: ' + repr(rows))
EOF
)"
    if [[ "${expect}" == reject && "${result}" == reject:* ]] || [[ "${expect}" == ok && "${result}" == ok ]]; then
        pass "${label} (${result})"
    else
        fail "${label}: got '${result}'"
    fi
}
H='observed-at\tocurred-at\tcode\trecord-id\tseverity\tfinding\tsubject-type\toperator\titem\tsubject\tdetail'
H="${H/ocurred/occurred}"
stream_case "empty stdout is the clean result" ok 'rows == [] and exit_status(rows) == 0' ''
stream_case "an appended unknown column is kept" ok "rows[0]['extra'] == b'x' and rows[0]['detail'] == b'd'" \
    "${H}\\textra\\nt\\t\\tc\\ti\\tinfo\\tf\\tfile\\top\\t\\t/p\\td\\tx\\n"
stream_case "a missing canonical column rejects the stream" reject '' \
    "${H/\\tdetail/}\\nt\\t\\tc\\ti\\tinfo\\tf\\tfile\\top\\t\\t/p\\n"
stream_case "a duplicate column rejects the stream" reject '' "${H}\\tcode\\n"
stream_case "a first row that is not a header rejects the stream" reject '' 'x\ty\tz\n'
stream_case "a row whose field count differs from the header's rejects the stream" reject '' "${H}\\na\\tb\\n"
stream_case "a truncated final line rejects the stream" reject '' "${H}"
stream_case "leading, adjacent and trailing empty fields keep their positions" ok \
    "rows[0]['observed-at'] == b'' and rows[0]['record-id'] == b'r' and rows[0]['detail'] == b''" \
    "${H}\\n\\t\\t\\tr\\tinfo\\t\\t\\t\\t\\t\\t\\n"
stream_case "a raw byte in a row rejects the row" reject '' "${H}\\nt\\t\\tc\\ti\\tinfo\\tf\\tfile\\top\\t\\t/p\\x01\\td\\n"
stream_case "an unknown severity reads as attention and a known unreadable wins over it" ok \
    "exit_status(rows) == 5 and exit_status(rows[:1]) == 4" \
    "${H}\\nt\\t\\tc\\ti\\tweird\\tf\\tfile\\top\\t\\t/p\\td\\nt\\t\\tc\\ti\\tunreadable\\tf\\tfile\\top\\t\\t/p\\td\\n"

# ── Item framing ─────────────────────────────────────────────────────────────────────────────────
section "records: the item framing (unit)"
ai_tools_records_tsv_frame_item_components one $'a\tb' "c"
ai_tools_records_tsv_frame_item_components two "a" $'b\tc'
if [[ "${one}" == $'a\\tb\tc' && "${two}" == $'a\tb\\tc' && "${one}" != "${two}" ]]; then
    pass '["a<TAB>b", "c"] and ["a", "b<TAB>c"] frame to different fields'
else
    fail "the two lists framed as '$(hex "${one}")' and '$(hex "${two}")'"
fi
ai_tools_records_tsv_calculate_record_id id_one "${TEST_CODE}" /p "${one}"
ai_tools_records_tsv_calculate_record_id id_two "${TEST_CODE}" /p "${two}"
[[ "${id_one}" != "${id_two}" ]] && pass "the two lists give different record ids" || fail "the two lists share an id"
ai_tools_records_tsv_frame_item_components single $'a\tb'
ai_tools_records_tsv_frame_item_components pair "a" "b"
[[ "${single}" == 'a\tb' && "${pair}" == $'a\tb' && "${single}" != "${pair}" ]] \
    && pass "a single component equal to a joined pair does not collide with the pair" \
    || fail "single '$(hex "${single}")' against pair '$(hex "${pair}")'"
ai_tools_records_tsv_frame_item_components with_backslash 'a\b' 'c'
ai_tools_records_tsv_decode_field back "${with_backslash%%$'\t'*}"
[[ "${with_backslash}" == $'a\\\\b\tc' && "${back}" == 'a\b' ]] \
    && pass "a component holding a backslash round-trips" || fail "backslash component framed as '${with_backslash}'"
ai_tools_records_tsv_frame_item_components none
[[ "${none}" == "" ]] && pass "no components give the empty field" || fail "no components gave '${none}'"
for refused_list in '""' '"a" ""'; do
    out="stale"
    if eval "ai_tools_records_tsv_frame_item_components out ${refused_list}"; then
        fail "the list [${refused_list}] was framed as '${out}'"
    elif [[ "${out}" == "" ]]; then
        pass "the list [${refused_list}] is refused and the output emptied"
    else
        fail "the list [${refused_list}] was refused but left '${out}'"
    fi
done
result="$(python3 - "${TESTDIR}/decoder.py" <<'EOF'
import sys
ns = {}
exec(open(sys.argv[1]).read(), ns)
try:
    ns['decode_item'](b'a\\t')
    print('accepted')
except ValueError:
    print(ns['decode_item'](b'a\\\\tb\\tc'), ns['decode_item'](b''))
EOF
)"
[[ "${result}" == "[b'a\\tb', b'c'] []" ]] && pass "the page's reader rejects an item with an empty part and reads the others" \
                                          || fail "the page's item reader printed '${result}'"

# ── Identity ─────────────────────────────────────────────────────────────────────────────────────
section "records: the record identity (unit)"
# The vectors ai-tools-records(5) publishes, computed from the recipe with hashlib and pinned here.
check_vector() {
    local label="$1" expected="$2" code="$3" subject="$4" got; shift 4
    ai_tools_records_tsv_frame_item_components item "$@"
    ai_tools_records_tsv_calculate_record_id got "${code}" "${subject}" "${item}"
    [[ "${got}" == "${expected}" ]] && pass "vector ${label}: ${expected}" || fail "vector ${label}: got '${got}', expected ${expected}"
    grep -q "${expected}" "${PAGE}" && pass "ai-tools-records(5) publishes vector ${label}" \
                                     || fail "ai-tools-records(5) does not carry ${expected}"
}
check_vector "empty item" d2b6a0f255f321d9 "${TEST_CODE}" /srv/project/app.conf
check_vector "one component" 6bc5171e35197c4f "${TEST_CODE}" /srv/project/app.conf key
check_vector "a tab in the subject, two components" 142b7f86fe379965 "${TEST_CODE}" $'/srv/project/a\tb' hooks x
ai_tools_records_tsv_calculate_record_id base_id "${TEST_CODE}" /p "key"
ai_tools_records_tsv_calculate_record_id same_id "${TEST_CODE}" /p "key"
[[ "${base_id}" == "${same_id}" && "${base_id}" =~ ^[0-9a-f]{16}$ ]] \
    && pass "the id is 16 lowercase hex digits and repeats for the same inputs" || fail "id '${base_id}' vs '${same_id}'"
ai_tools_records_tsv_calculate_record_id other "${TEST_CODE}" /q "key"
[[ "${other}" != "${base_id}" ]] && pass "a changed subject moves the id" || fail "a changed subject kept the id"
ai_tools_records_tsv_calculate_record_id other "MSG-C3D4" /p "key"  # ref-index: ignore
[[ "${other}" != "${base_id}" ]] && pass "a changed code moves the id" || fail "a changed code kept the id"
ai_tools_records_tsv_calculate_record_id other "${TEST_CODE}" /p "kex"
[[ "${other}" != "${base_id}" ]] && pass "a changed item component moves the id" || fail "a changed component kept the id"
# Through the writer: detail, severity and the timestamps change, the id column does not.
ai_tools_records_begin_report
stream="$(ai_tools_records_tsv_write_record "2026-01-01T00:00:00Z" "${TEST_CODE}" info f file op key /p "one"
          ai_tools_records_tsv_write_record "2026-02-02T00:00:00Z" "${TEST_CODE}" attention g directory op key /p "two")"
ids="$(sed -n '2,3p' <<<"${stream}" | cut -f4 | sort -u | wc -l)"
[[ "${ids}" == 1 ]] && pass "detail, severity, finding, subject-type and the timestamps leave the id alone" \
                    || fail "the two rows carry $(sed -n '2,3p' <<<"${stream}" | cut -f4 | tr '\n' ' ')"
result="$(bash -c 'set -euo pipefail; source "$1"; PATH=/nonexistent
    ai_tools_records_begin_report
    ai_tools_records_tsv_write_record "" "$2" info f file op "" /p d
    ai_tools_records_get_exit_status || exit $?' _ "${TSV_LIB}" "${TEST_CODE}" 2>/dev/null; echo "rc=$?")"
[[ "${result}" == "rc=5" ]] && pass "sha256sum missing from PATH: no row, exit 5" || fail "without sha256sum: '${result}'"

# ── State ────────────────────────────────────────────────────────────────────────────────────────
section "records: the report state and the exit fold (unit)"
fold_case() {
    local expected="$1" label="$2" rc=0; shift 2
    ai_tools_records_begin_report
    local severity
    for severity in "$@"; do ai_tools_records_accumulate_severity "${severity}"; done
    ai_tools_records_get_exit_status || rc=$?
    [[ "${rc}" == "${expected}" ]] && pass "${label} -> ${expected}" || fail "${label} -> ${rc}, expected ${expected}"
}
fold_case 0 "no severity"
fold_case 0 "ok, info" ok info
fold_case 4 "info, attention, ok" info attention ok
fold_case 5 "attention, unreadable" attention unreadable
fold_case 5 "unreadable, attention (order does not lower it)" unreadable attention
fold_case 5 "ok, unreadable, ok" ok unreadable ok
fold_case 5 "an unknown severity" ok bogus
fold_case 5 "an empty severity" ""
if ai_tools_records_is_valid_record "" "${TEST_CODE}" info f file op "" /p d \
        && ! ai_tools_records_is_valid_record "" "${TEST_CODE}" bogus f file op "" /p d \
        && ! ai_tools_records_is_valid_record "" "${TEST_CODE}" info f bogus op "" /p d \
        && ! ai_tools_records_is_valid_record "" "${TEST_CODE}" info f file op "" /p \
        && ! ai_tools_records_is_valid_record "" "${TEST_CODE}" info f file op "" /p d extra; then
    pass "is_valid_record accepts nine fields with known tokens and refuses a bad severity, subject-type or arity"
else
    fail "is_valid_record's verdicts are off"
fi
# An invalid row under the consumers' own mode: the script must reach its exit and return 5, printing nothing.
result="$(bash -c 'set -euo pipefail; source "$1"
    ai_tools_records_begin_report
    ai_tools_records_tsv_write_record "" "$2" bogus f file op "" /p d
    ai_tools_records_get_exit_status || exit $?
    echo "reached the end at 0"' _ "${TSV_LIB}" "${TEST_CODE}" 2>&1; echo "rc=$?")"
[[ "${result}" == "rc=5" ]] && pass "an invalid row under set -euo pipefail prints nothing and the script exits 5" \
                            || fail "an invalid row under strict mode: '${result}'"
ai_tools_records_begin_report
ai_tools_records_accumulate_severity unreadable
first_observed="${_AI_TOOLS_RECORDS_OBSERVED_AT}"
out="$(ai_tools_records_tsv_write_record "" "${TEST_CODE}" info f file op "" /p d)"
ai_tools_records_begin_report
rc=0; ai_tools_records_get_exit_status || rc=$?
out2="$(ai_tools_records_tsv_write_record "" "${TEST_CODE}" info f file op "" /p d)"
if [[ "${rc}" == 0 && "$(head -n 1 <<<"${out}")" == "$(head -n 1 <<<"${out2}")" && "${first_observed}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "begin_report resets the status and the header between two reports in one shell, and observed-at is UTC"
else
    fail "begin_report did not reset: rc=${rc}, observed-at='${first_observed}'"
fi
[[ "$(sed -n 2p <<<"${out}" | head -c 20)" == "${first_observed}" ]] \
    && pass "the row carries the report's observed-at" \
    || fail "the row's observed-at is not the report's: $(sed -n 2p <<<"${out}" | head -c 20)"
# The header goes out with the first row alone: two rows, one header; a report with no row prints nothing.
ai_tools_records_begin_report
stream="$(ai_tools_records_tsv_write_record "" "${TEST_CODE}" info f file op "" /p d
          ai_tools_records_tsv_write_record "" "${TEST_CODE}" info f file op "" /q d)"
if [[ "$(wc -l <<<"${stream}")" == 3 && "$(head -n 1 <<<"${stream}")" == "${EXPECTED_HEADER// /$'\t'}" ]]; then
    pass "the header is printed once, before the first row, with the columns tab-separated"
else
    fail "two rows produced: $(head -c 300 <<<"${stream}" | tr '\t\n' '|/')"
fi
ai_tools_records_begin_report
[[ "$(ai_tools_records_tsv_write_record "" "${TEST_CODE}" bogus f file op "" /p d)" == "" ]] \
    && pass "a report whose only row is invalid prints nothing" || fail "an invalid row printed something"
# A write to a closed pipe: the reader is waited for before the write, so the pipe has no reader for certain.
result="$(bash -c 'set -uo pipefail; source "$1"; trap "" PIPE
    exec {fd}> >(exit 0); pid=$!; wait "${pid}"
    ai_tools_records_begin_report
    ai_tools_records_tsv_write_record "" "$2" info f file op "" /p d >&"${fd}" 2>/dev/null; rc=$?
    ai_tools_records_get_exit_status; printf "write=%s exit=%s" "${rc}" "$?"' _ "${TSV_LIB}" "${TEST_CODE}")"
[[ "${result}" == "write=1 exit=5" ]] && pass "a write to a closed pipe returns 1 and the report reads unreadable" \
                                       || fail "closed pipe: '${result}'"

# ── Collectors ───────────────────────────────────────────────────────────────────────────────────
section "records: the collector rules -- saved PID, failure, cap, exact bytes (unit)"
# The saved PID reports the collector's exit; a bare `wait $!` after a loop body that opened another substitution
# reports that inner process instead. The control shows the trap, the case shows the rule.
outer_saved=0; outer_bare=0
exec {fd}< <(printf 'a\nb\n'; exit 9); pid=$!
while IFS= read -r -u "${fd}" _; do : < <(true); done
exec {fd}<&-
wait "${pid}" || outer_saved=$?
exec {fd}< <(printf 'a\nb\n'; exit 9)
while IFS= read -r -u "${fd}" _; do : < <(true); done
exec {fd}<&-
wait $! || outer_bare=$?
if [[ "${outer_saved}" == 9 && "${outer_bare}" == 0 ]]; then
    pass "the PID saved when the collector was opened reports its exit 9; a bare wait \$! after the loop reports 0"
else
    fail "saved-PID wait gave ${outer_saved}, bare wait gave ${outer_bare}"
fi

# fixture_upstream <count> [<exit>]: <count> NUL-separated paths, then exit <exit> (default 0). Two of the paths carry
# a tab and a line feed, so they cross every stage in the raw.
fixture_upstream() {
    local count="$1" status="${2:-0}" i
    for (( i = 1; i <= count; i++ )); do
        case "${i}" in
            2) printf '%s\0' $'/proj/tab\there' ;;
            3) printf '%s\0' $'/proj/line\nfeed' ;;
            *) printf '/proj/path-%d\0' "${i}" ;;
        esac
    done
    return "${status}"
}
# fixture_collector <cap> <upstream args...>: the collector rule -- at most cap+1 records in the internal framing (each
# field encoded, one record per line), the upstream's PID saved and waited for, 141/143 accepted only after a deliberate
# stop, exit 0 after one.
fixture_collector() {
    local cap="$1" fd pid n=0 path encoded rc=0 stopped=0
    shift
    exec {fd}< <(fixture_upstream "$@"); pid=$!
    while IFS= read -r -d '' -u "${fd}" path; do
        ai_tools_records_tsv_encode_field encoded "${path}"
        printf '%s\n' "${encoded}"
        n=$(( n + 1 ))
        if (( n > cap )); then stopped=1; break; fi
    done
    exec {fd}<&-
    wait "${pid}" || rc=$?
    if (( stopped )); then
        case "${rc}" in 0|141|143) return 0 ;; esac
    fi
    return "${rc}"
}
# fixture_report <cap> <upstream args...>: the consumer -- decodes each record, keeps the first cap, emits scan-capped
# at cap+1, and an error row when a record does not decode or the collector exits non-zero. Prints the stream.
fixture_report() {
    local cap="$1" fd pid line path n=0 rc=0 item
    shift
    ai_tools_records_begin_report
    exec {fd}< <(fixture_collector "${cap}" "$@"); pid=$!
    while IFS= read -r -u "${fd}" line; do
        n=$(( n + 1 ))
        if (( n > cap )); then
            ai_tools_records_tsv_frame_item_components item "${cap}"
            ai_tools_records_tsv_write_record "" "${TEST_CODE}" attention scan-capped project op "${item}" /proj "capped"
            break
        fi
        if ! ai_tools_records_tsv_decode_field path "${line}"; then
            ai_tools_records_tsv_write_record "" "${TEST_CODE}" unreadable error project op "" /proj "unparsed record"
            continue
        fi
        ai_tools_records_tsv_write_record "" "${TEST_CODE}" info hit file op "" "${path}" "a hit"
    done
    exec {fd}<&-
    wait "${pid}" || rc=$?
    if (( rc )); then
        ai_tools_records_tsv_write_record "" "${TEST_CODE}" unreadable error project op "" /proj "collector exited ${rc}"
    fi
}
# report_case <label> <expected exit> <expected rows> <expected scan-capped rows> <cap> <upstream args...>
report_case() {
    local label="$1" want_exit="$2" want_rows="$3" want_capped="$4" rc=0 rows capped
    shift 4
    stream="$(fixture_report "$@"; ai_tools_records_get_exit_status || printf 'EXIT=%s' "$?")"
    rc="${stream##*EXIT=}"; [[ "${rc}" == "${stream}" ]] && rc=0
    stream="${stream%EXIT=*}"; stream="${stream%$'\n'}"
    if [[ -z "${stream}" ]]; then rows=0; else rows="$(( $(wc -l <<<"${stream}") - 1 ))"; fi
    capped="$(cut -f6 <<<"${stream}" | grep -cx scan-capped || true)"
    if [[ "${rc}" == "${want_exit}" && "${rows}" == "${want_rows}" && "${capped}" == "${want_capped}" ]]; then
        pass "${label}: ${rows} rows, ${capped} scan-capped, exit ${rc}"
    else
        fail "${label}: ${rows} rows, ${capped} scan-capped, exit ${rc}; expected ${want_rows}/${want_capped}/${want_exit}"
    fi
}
report_case "a collector failing before any row" 5 1 0 10 0 7
report_case "a collector failing after a valid row" 5 2 0 10 1 7
report_case "exactly N hits" 0 4 0 4 4
report_case "N+1 hits: N rows, scan-capped, exit 4, no exit 5 from the truncation" 4 5 1 4 5
report_case "many more than N hits: the same" 4 5 1 4 200
report_case "an upstream failing before the cap" 5 3 0 4 2 3
# The fail direction of the collector's own acceptance: 141 without a deliberate stop is a failure.
rc=0; fixture_collector 10 3 141 >/dev/null || rc=$?
[[ "${rc}" == 141 ]] && pass "a 141 from an upstream the collector did not stop is reported as the failure it is" \
                     || fail "an unprompted 141 read as ${rc}"
# Exact bytes end to end: the tab path and the line-feed path from the upstream to the decoded subject field.
stream="$(fixture_report 10 3)"
subjects="$(sed -n '2,$p' <<<"${stream}" | cut -f10)"
bad=0
while IFS= read -r encoded; do
    ai_tools_records_tsv_decode_field path "${encoded}"
    case "${path}" in
        /proj/path-1|$'/proj/tab\there'|$'/proj/line\nfeed') ;;
        *) bad=1; fail "an unexpected subject arrived: $(hex "${path}")" ;;
    esac
done <<<"${subjects}"
if (( ! bad )) && [[ "${subjects}" == $'/proj/path-1\n/proj/tab\\there\n/proj/line\\nfeed' ]]; then
    pass "a path holding a tab and one holding a line feed arrive in order, escaped on the wire and exact after the decoder"
else
    fail "the subjects read: $(tr '\n' '|' <<<"${subjects}")"
fi

finish
