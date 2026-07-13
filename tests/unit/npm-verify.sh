#!/usr/bin/env bash
# tests/unit/npm-verify.sh
# Unit test for the npm signature verifier (npm-verify.lib.sh). Drives the PURE decision
# ai_tools_npm_verdict over a truth table of `npm audit signatures --json` shapes -- the
# fail-closed contract nvm-update.sh and ai-tools-bootstrap gate the stable-launcher repoint
# on. The pure verdict touches no npm, no filesystem, and no privilege, so this runs with no
# registry, no network, and no root risk: a regression in the verdict (a tamper read as
# "unable to verify", an inverted gate, a format change read as a false OK) fails here.
#
# It deliberately does NOT exercise the impure ai_tools_verify_npm_signatures over a real tree:
# that function operates on the SANDBOX-owned (agent-writable) global npm tree and must run as
# the sandbox account, never root -- and this suite runs as root. Instead it asserts the
# function's fail-closed root-refusal backstop (as root it returns "unable to verify" and
# touches nothing). The real end-to-end audit is covered as the sandbox account, out of this
# root-run unit suite. `node` (the pure verdict's JSON parser) is real. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/npm-verify.lib.sh"
section "npm-verify: signature-verification verdict truth table (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "npm-verify" "library not readable at ${LIB}"; finish; exit
fi
if ! command -v node >/dev/null 2>&1; then
    skip "npm-verify" "node not available (the pure verdict's JSON parser)"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_npm_verdict >/dev/null 2>&1 \
        || ! declare -F ai_tools_verify_npm_signatures >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the verify functions"; finish; exit
fi

# expect <desc> <exp_tok> <exp_rc> <audit-json>: drive the pure verdict and assert BOTH the
# echoed token and the 0=verified / 1=tamper / 2=unable return. '|| rc=$?' keeps a non-zero
# return non-fatal under set -e.
expect() {
    local desc="$1" exp_tok="$2" exp_rc="$3" json="$4" tok rc
    tok="$(ai_tools_npm_verdict "${json}" 2>/dev/null)" && rc=0 || rc=$?
    if [[ "${tok}" == "${exp_tok}" && "${rc}" -eq "${exp_rc}" ]]; then
        pass "${desc} -> ${tok} (rc ${rc})"
    else
        fail "${desc} -> ${tok} (rc ${rc}); expected ${exp_tok} (rc ${exp_rc})"
    fi
}

# Every signature verified -> activate the toolchain.
expect "all verified"                 OK      0 '{"invalid":[],"missing":[]}'
# A verified attestation count alongside is still just verified.
expect "verified with attestations"   OK      0 '{"invalid":[],"missing":[],"verified":42}'
# An INVALID signature is a tamper signal -> caller MUST fail closed.
expect "invalid signature (tamper)"   INVALID 1 '{"invalid":[{"name":"@anthropic-ai/claude-code","version":"2.1.0"}],"missing":[]}'
# Invalid dominates missing when both are present.
expect "invalid dominates missing"    INVALID 1 '{"invalid":[{"name":"evil","version":"9.9.9"}],"missing":[{"name":"x","version":"1.0.0"}]}'
# An unsigned (missing-signature) package is NOT tamper -> unable to fully verify (warn).
expect "unsigned package present"     MISSING 2 '{"invalid":[],"missing":[{"name":"x","version":"1.0.0"}]}'
# Empty audit output (registry unreachable / offline) -> unable to verify.
expect "audit no output (offline)"    EMPTY   2 ''
# Unparseable output -> unable to verify; never a false OK on a format change.
expect "unparseable audit output"     UNKNOWN 2 'this is not json'

# Fail-closed backstop: the impure verifier refuses to run as root (this suite is root), so it
# returns "unable to verify" (2) without discovering or touching the tree.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    rc=0; ai_tools_verify_npm_signatures >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        pass "verifier refuses to run as root (rc 2, no tree access)"
    else
        fail "verifier as root returned rc ${rc}; expected 2 (root refusal)"
    fi
else
    skip "root-refusal backstop" "suite not running as root"
fi

finish
