#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/log.sh
# Unit test for the shared logger's input sanitization: the shell ai_tools_log_sanitize in
# log.lib.sh and the parallel _sanitize in the handback daemon. Both are a default-deny
# ALLOWLIST -- they keep only printable ASCII (0x20-0x7E) and replace every other byte/code
# point (ASCII controls, and the whole non-ASCII space incl. the Trojan-Source bidi class)
# with '?'. The security property is therefore simple and checkable directly: whatever the
# input, the output contains ONLY printable ASCII, so a crafted filename can never carry a
# terminal escape, a forged newline, or a bidi override into the audit trail; and clean ASCII
# is passed through unchanged (no false positives on ordinary paths). The daemon is exercised
# on the same bytes so the two trails share one contract. The deferred control/bidi *detector*
# (retained, unused) is pinned lightly so it does not rot before the quarantine sink is built.
# Run as root via sudo (the suite contract); needs no privilege of its own.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/log.lib.sh"
readonly DAEMON="/usr/local/libexec/ai-tools/ai-tools-handback"
section "logger: input sanitization allowlist (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "logger sanitizer" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}"; then
    skip "logger sanitizer" "could not source ${LIB}"; finish; exit
fi
if ! declare -F ai_tools_log_sanitize >/dev/null; then
    skip "logger sanitizer" "installed log.lib.sh predates ai_tools_log_sanitize"; finish; exit
fi

# is_printable_ascii <text>: true when every byte is in 0x20-0x7E (checked byte-wise under C).
is_printable_ascii() { local LC_ALL=C; [[ "$1" != *[^[:print:]]* ]]; }

# hx <value>: byte-exact hex rendering for a FAILURE message. A value this test reports on may,
# on a regression, still hold the very control/bidi byte the sanitizer was meant to remove;
# printing it straight to stderr (which run.sh tees to a terminal) would re-introduce the
# terminal injection this test exists to prevent -- and `printf %q` still passes a printable
# bidi code point through raw. od is safe and diagnostic, trusting nothing under test.
hx() { printf '%s' "$1" | od -An -tx1 | tr -s ' \n' ' '; }

# Vectors from raw bytes so construction is locale-independent. DANGER mixes ASCII controls,
# C1, the bidi overrides/isolates, zero-width, separators, BOM, and multi-byte UTF-8.
readonly DANGER=$'a\x1bb\xc2\x85c\xe2\x80\xaed\xe2\x81\xa6e\xe2\x80\x8bf\xe2\x80\xa8g\xef\xbb\xbfh\xc2\xadi caf\xc3\xa9'
readonly CLEAN='/proj/src/a-b_c.TAR.gz (v1.2) [ok] ~temp #3'

# (1) The allowlist property: any input reduces to printable-ASCII-only output.
out="$(ai_tools_log_sanitize "${DANGER}")"
if is_printable_ascii "${out}"; then
    pass "shell sanitizer output is printable-ASCII only (no escape/bidi/newline survives)"
else
    fail "shell sanitizer left a non-printable byte; output bytes: $(hx "${out}")"
fi

# (2) A specific reduction is exact and stable: ESC between a and b becomes '?'.
got="$(ai_tools_log_sanitize "$(printf 'a\x1bb')")"
if [[ "${got}" == 'a?b' ]]; then
    pass "shell sanitizer maps a control byte to '?'"
else
    fail "expected 'a?b', got bytes: $(hx "${got}")"
fi

# (3) No false positives: clean printable ASCII passes through unchanged.
out="$(ai_tools_log_sanitize "${CLEAN}")"
if [[ "${out}" == "${CLEAN}" ]]; then
    pass "shell sanitizer leaves clean printable ASCII unchanged"
else
    fail "shell sanitizer altered clean ASCII; output bytes: $(hx "${out}")"
fi

# (4) Deferred control/bidi detector (retained, unused): still defined, and still strips a
# control byte while preserving legitimate multi-byte UTF-8 -- pinned so it does not rot.
if ! declare -F ai_tools_log_sanitize_unicode_controlchars >/dev/null; then
    skip "deferred detector" "installed log.lib.sh predates ai_tools_log_sanitize_unicode_controlchars"
else
    det="$(ai_tools_log_sanitize_unicode_controlchars "$(printf 'x\x1by\xc3\xa9')")"
    if [[ "${det}" == "$(printf 'x?y\xc3\xa9')" ]]; then
        pass "deferred detector strips controls, keeps UTF-8 (retained for quarantine sink)"
    else
        fail "deferred detector changed behavior; output bytes: $(hx "${det}")"
    fi
fi

# (5) Daemon parity: the handback daemon's _sanitize is the same allowlist. Drive it on the
# same bytes; assert the same property (printable-ASCII output; clean input unchanged).
if ! command -v python3 >/dev/null 2>&1 || [[ ! -r "${DAEMON}" ]]; then
    skip "handback daemon _sanitize parity" "python3 or daemon unavailable"
elif python3 - "${DAEMON}" "${DANGER}" "${CLEAN}" <<'PY'
import sys
# The installed daemon has no .py suffix, so spec_from_file_location cannot guess a loader;
# compile+exec loads it from any path and bypasses the bytecode cache entirely, so a stale
# .pyc can never mislead this check. __name__ is set to a non-__main__ value so the module's
# `if __name__ == '__main__': main()` guard does not run the daemon.
path, danger, clean = sys.argv[1:4]
ns = {'__name__': 'ai_tools_handback_probe'}
with open(path) as f:
    exec(compile(f.read(), path, 'exec'), ns)
san = ns.get('_sanitize')
if san is None:
    sys.exit(2)  # installed daemon predates _sanitize -> report as skip
ok = all(0x20 <= ord(c) <= 0x7e for c in san(danger)) and san(clean) == clean
sys.exit(0 if ok else 1)
PY
then
    pass "daemon _sanitize shares the allowlist contract (printable-ASCII out, clean in unchanged)"
elif [[ $? -eq 2 ]]; then
    skip "handback daemon _sanitize parity" "installed daemon predates _sanitize"
else
    fail "daemon _sanitize violated the allowlist contract on the shared vectors"
fi

# ── structured journal fields ────────────────────────────────────────────────────────────────
# ai_tools_log_structured carries the machine-readable half of a record (logging.rule.md). Its
# security claim is narrow and worth pinning exactly: a FIELD cannot forge a sibling field, and
# a caller cannot claim journald's trusted namespace. logger(1) is stubbed as a shell function
# so the entry is captured instead of sent; the stub writes to a file because the real call is
# the tail of a pipeline and therefore runs in a subshell.
section "logger: structured journal fields (unit)"
if ! declare -F ai_tools_log_structured >/dev/null; then
    skip "structured logging" "installed log.lib.sh predates ai_tools_log_structured"
else
    _cap="$(mktemp)"; _cleanup+=("${_cap}")
    logger() {
        if [[ "${1:-}" == "--journald" ]]; then cat > "${_cap}"; return 0; fi
        { printf 'PLAIN-FALLBACK'; printf ' %s' "$@"; printf '\n'; } > "${_cap}"; return 0
    }

    AI_TOOLS_LOG_TAG="ai-tools-unit-test"
    # A newline inside a value is the forgery vector the newline-delimited protocol invites: if
    # it survived, the text after it would parse as a field of its own.
    ai_tools_log_structured info "a structured message" \
        AI_TOOLS_TOOL=Bash \
        AI_TOOLS_CMD="$(printf 'evil\nAI_TOOLS_TOOL=forged')" \
        _UID=0 _SYSTEMD_USER_UNIT=forged.service \
        lowercase=x "BAD NAME=y" NOEQUALSSIGN
    _entry="$(cat "${_cap}")"

    # (1) The envelope and a well-formed field arrive.
    if grep -qx 'MESSAGE=a structured message' <<<"${_entry}" \
            && grep -qx 'SYSLOG_IDENTIFIER=ai-tools-unit-test' <<<"${_entry}" \
            && grep -qx 'PRIORITY=6' <<<"${_entry}" \
            && grep -qx 'AI_TOOLS_TOOL=Bash' <<<"${_entry}"; then
        pass "a structured record carries its MESSAGE, identifier, priority and fields"
    else
        fail "the structured entry lost its envelope or a valid field: $(hx "${_entry}")"
    fi

    # (2) THE CLAIM. A newline in a value must not become a second field. Asserted as an
    #     anchored line match, which is exactly how a journal consumer would read a forged one.
    if grep -qx 'AI_TOOLS_TOOL=forged' <<<"${_entry}"; then
        fail "a newline inside a field value forged a sibling field -- the structured record's shape is not safe"
    else
        pass "a newline inside a field value cannot forge a sibling field"
    fi

    # (3) journald's trusted namespace is refused. A sender cannot set _UID or
    #     _SYSTEMD_USER_UNIT in any case -- they are what makes a line attributable -- so the
    #     point of refusing here is that a caller never believes it set one.
    if grep -qE '^_(UID|SYSTEMD_USER_UNIT)=' <<<"${_entry}"; then
        fail "a leading-underscore field reached the entry -- the trusted-field namespace is not refused"
    else
        pass "fields in journald's trusted _-namespace are refused, never emitted"
    fi

    # (4) A malformed name drops that field and keeps the rest: a bad label must not cost the
    #     record. (1) already asserted the valid field survived alongside these.
    if grep -qE '^(lowercase|BAD|NOEQUALSSIGN)' <<<"${_entry}"; then
        fail "a malformed field name was emitted: $(hx "${_entry}")"
    else
        pass "a malformed field name is dropped without costing the record"
    fi

    # (5) A host whose logger(1) predates --journald must still get the line, through the plain
    #     path. Structured logging is an enhancement; losing it must never lose the record.
    logger() {
        if [[ "${1:-}" == "--journald" ]]; then return 1; fi
        { printf 'PLAIN-FALLBACK'; printf ' %s' "$@"; printf '\n'; } > "${_cap}"; return 0
    }
    ai_tools_log_structured warning "fallback message" AI_TOOLS_TOOL=Bash
    if grep -q 'PLAIN-FALLBACK' "${_cap}" && grep -q 'fallback message' "${_cap}"; then
        pass "a logger(1) without --journald falls back to the plain path, keeping the record"
    else
        fail "the record was lost when --journald was unavailable: $(hx "$(cat "${_cap}")")"
    fi

    unset -f logger
fi

finish
