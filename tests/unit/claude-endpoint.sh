#!/usr/bin/env bash
# tests/unit/claude-endpoint.sh
# Unit test for the custom-endpoint resolver (claude-endpoint.lib.sh), the sandbox-side logic the
# claude-code session-env fragment applies to route a session at a non-default ANTHROPIC_BASE_URL.
# What it pins:
#   * only valid, present options are injected; a configured-but-invalid option (malformed URL,
#     model with whitespace, token with control bytes, options with no base URL, a missing/untrusted
#     file) REFUSES the launch (return 1), never a partial or wrong endpoint;
#   * only the four recognised keys are read -- an arbitrary key in the file never becomes session
#     environment;
#   * the auth token is imported BY NAME (--setenv=ANTHROPIC_AUTH_TOKEN, value not on the command
#     line) and exported for that name-only import, and a non-local endpoint with no token warns but
#     still applies while a localhost one does not.
# The agent-side half (the endpoint file is not agent-writable) lives in tests/boundary/access.sh.
#
# Hermetic: /tmp fixtures with a root-only AI_TOOLS_ENDPOINT_BASE_DIR override. Run as root (needed
# to create root-owned fixtures the trust predicate accepts).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/claude-endpoint.lib.sh"
section "claude-endpoint: custom API endpoint resolution (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "claude-endpoint" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_claude_resolve_endpoint_setenv >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the resolver"; finish; exit
fi

mktestdir
base="${TESTDIR}/endpoints"
install -d -o root -g root -m 755 "${base}"
conf="${TESTDIR}/operator.conf"
epfile="${base}/custom-claude-endpoint.conf"
export AI_TOOLS_ENDPOINT_BASE_DIR="${base}"

_resolve() {
    RESULT=()
    unset ANTHROPIC_AUTH_TOKEN
    if ai_tools_claude_resolve_endpoint_setenv RESULT "${conf}" 2>"${TESTDIR}/err"; then RET=0; else RET=1; fi
    ARGS="${RESULT[*]:-}"
    ERR="$(cat "${TESTDIR}/err" 2>/dev/null || true)"
    TOKEN_EXPORTED="${ANTHROPIC_AUTH_TOKEN:-<unset>}"
}
_ep() { printf '%s\n' "$@" > "${epfile}"; chown root:root "${epfile}"; chmod 640 "${epfile}"; }
_reset() {
    install -d -o root -g root -m 755 "${base}"
    _ep '#ANTHROPIC_BASE_URL=x'                                   # inert by default
    printf 'CLAUDE_BASE_URL_FILE=%s\n' "${epfile}" > "${conf}"; chown root:root "${conf}"; chmod 644 "${conf}"
}

expect() {  # <desc> <want-ret> <want-args-substr-or-empty> [want-err-substr]
    local desc="$1" wret="$2" wargs="$3" werr="${4:-}"
    if [[ "${RET}" != "${wret}" ]]; then fail "${desc}: ret ${RET} != ${wret} (args='${ARGS}' err='${ERR}')"; return; fi
    if [[ -n "${wargs}" && "${ARGS}" != *"${wargs}"* ]]; then fail "${desc}: args '${ARGS}' lacks '${wargs}'"; return; fi
    if [[ -z "${wargs}" && -n "${ARGS}" ]]; then fail "${desc}: expected no args, got '${ARGS}'"; return; fi
    if [[ -n "${werr}" && "${ERR}" != *"${werr}"* ]]; then fail "${desc}: err '${ERR}' lacks '${werr}'"; return; fi
    pass "${desc}"
}

# 1) Not configured: pointer absent -> default endpoint, no injection.
_reset; : > "${conf}"; _resolve
expect "unconfigured -> no args" 0 ""

# 2) Inert endpoint file (nothing uncommented) -> no injection, launch.
_reset; _resolve
expect "inert file -> no args" 0 ""

# 3) Full valid config -> base URL + models injected, token imported BY NAME and exported.
_reset; _ep \
    'ANTHROPIC_BASE_URL=https://chat.example.tld' \
    'ANTHROPIC_AUTH_TOKEN=sk-secret-123' \
    'ANTHROPIC_MODEL=claude-sonnet-4-5-20250929' \
    'ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001'
_resolve
expect "full config -> base url injected" 0 "--setenv=ANTHROPIC_BASE_URL=https://chat.example.tld"
if [[ "${ARGS}" == *"--setenv=ANTHROPIC_MODEL=claude-sonnet-4-5-20250929"* ]]; then
    pass "model injected"; else fail "model not injected: ${ARGS}"; fi
if [[ "${ARGS}" == *"--setenv=ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001"* ]]; then
    pass "haiku model injected"; else fail "haiku not injected: ${ARGS}"; fi
# The token appears as a NAME-ONLY setenv (no value on the command line) and is exported.
if [[ "${ARGS}" == *"--setenv=ANTHROPIC_AUTH_TOKEN"* && "${ARGS}" != *"ANTHROPIC_AUTH_TOKEN=sk-secret-123"* ]]; then
    pass "token imported by name, value off command line"; else fail "token value leaked onto args: ${ARGS}"; fi
if [[ "${TOKEN_EXPORTED}" == "sk-secret-123" ]]; then
    pass "token exported for name-only import"; else fail "token not exported: ${TOKEN_EXPORTED}"; fi

# 4) localhost with no token -> injected, no warning, no token.
_reset; _ep 'ANTHROPIC_BASE_URL=http://localhost:11434'; _resolve
expect "localhost no token -> injected" 0 "--setenv=ANTHROPIC_BASE_URL=http://localhost:11434"
if [[ "${ERR}" != *"may reject"* ]]; then
    pass "localhost no-token warning suppressed"; else fail "warned for localhost: ${ERR}"; fi

# 5) Remote with no token -> injected but warned.
_reset; _ep 'ANTHROPIC_BASE_URL=https://chat.example.tld'; _resolve
expect "remote no token -> injected + warn" 0 "--setenv=ANTHROPIC_BASE_URL=https://chat.example.tld" "may reject requests"

# 6) Only the four recognised keys are read; an arbitrary key is ignored.
_reset; _ep 'ANTHROPIC_BASE_URL=http://localhost:8080' 'EVIL_INJECT=whatever' 'PATH=/tmp/evil'; _resolve
expect "unknown keys ignored -> only base url" 0 "--setenv=ANTHROPIC_BASE_URL=http://localhost:8080"
if [[ "${ARGS}" != *"EVIL_INJECT"* && "${ARGS}" != *"/tmp/evil"* ]]; then
    pass "arbitrary keys not injected"; else fail "arbitrary key injected: ${ARGS}"; fi

# 7) Invalid URL -> refuse.
_reset; _ep 'ANTHROPIC_BASE_URL=not-a-url'; _resolve
expect "invalid url -> refuse" 1 "" "not a valid http(s) URL"

# 8) Options present with no base URL -> refuse.
_reset; _ep 'ANTHROPIC_AUTH_TOKEN=sk-x' 'ANTHROPIC_MODEL=foo'; _resolve
expect "no base url -> refuse" 1 "" "no ANTHROPIC_BASE_URL"

# 9) Malformed model label -> refuse.
_reset; _ep 'ANTHROPIC_BASE_URL=https://x.tld' 'ANTHROPIC_MODEL="has space"'; _resolve
expect "malformed model -> refuse" 1 "" "not a single printable token"

# 10) Token with whitespace -> refuse (never let it reach systemd-run).
_reset; _ep 'ANTHROPIC_BASE_URL=https://x.tld' 'ANTHROPIC_AUTH_TOKEN="sk with space"'; _resolve
expect "token with whitespace -> refuse" 1 "" "whitespace or control characters"

# 11) Missing endpoint file -> refuse (configured pointer, broken target).
_reset; printf 'CLAUDE_BASE_URL_FILE=%s\n' "${base}/nope.conf" > "${conf}"; chmod 644 "${conf}"; _resolve
expect "missing endpoint file -> refuse" 1 ""

# 12) Group/other-writable endpoint file -> refuse (untrusted; the token could be swapped).
_reset; _ep 'ANTHROPIC_BASE_URL=https://x.tld' 'ANTHROPIC_AUTH_TOKEN=sk-x'; chmod 660 "${epfile}"; _resolve
expect "group-writable endpoint file -> refuse" 1 ""

finish
