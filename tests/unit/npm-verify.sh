#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/npm-verify.sh
# Unit test for the npm signature verifier (npm-verify.lib.sh). Drives the PURE decision
# ai_tools_npm_verify__evaluate_audit over a truth table of `npm audit signatures --json` shapes -- the fail-closed
# contract nvm-update.sh and ai-tools-bootstrap gate the stable-launcher repoint on. The pure verdict touches neither
# npm nor the filesystem, and does not need privilege, so this runs with no registry, no network, and no root risk:
# a regression in the verdict (a tamper read as "unable to verify", an inverted gate, a format change read as a false
# OK) fails here. The report the verdict prints is held too: each package name, and each invalid entry's code, keyid
# and integrity, reaches stderr through the allowlist, and the detail stops at 20 entries.
#
# It deliberately does NOT exercise the impure ai_tools_npm_verify__verify_signatures over a real tree: that function
# operates on the SANDBOX-owned (agent-writable) global npm tree and must run as the sandbox account, never root --
# and this suite runs as root. Instead it asserts the function's fail-closed root-refusal backstop (as root it returns
# "unable to verify" and does not touch a path). The real end-to-end audit is covered as the sandbox account,
# out of this root-run unit suite.
#
# The pure verdict's JSON parser is the host's /usr/bin/python3 in isolated mode, so the verdict does not execute a file
# of the sandbox toolchain and runs under whatever account the suite has. Run as root via sudo for the identity cases
# and the probe that runs as the sandbox account.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/npm-verify.lib.sh"
section "npm-verify: signature-verification verdict truth table (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "npm-verify" "library not readable at ${LIB}"; finish; exit
fi
# as_verdict_account <json>: ai_tools_npm_verify__evaluate_audit in a shell of its own, so the token goes to stdout
# and the verdict's status is the function's.
as_verdict_account() {
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    bash -c 'source "$1" && ai_tools_npm_verify__evaluate_audit "$2"' _ "${LIB}" "$1"
}
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_npm_verify__evaluate_audit >/dev/null 2>&1 \
        || ! declare -F ai_tools_npm_verify__verify_signatures >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the verify functions"; finish; exit
fi

# expect <desc> <exp_tok> <exp_rc> <audit-json>: drive the pure verdict and assert BOTH the echoed token
# and the 0=verified / 1=tamper / 2=unable return. '|| rc=$?' keeps a non-zero return non-fatal under `set -e`.
expect() {
    local desc="$1" exp_tok="$2" exp_rc="$3" json="$4" tok rc
    tok="$(as_verdict_account "${json}" 2>/dev/null)" && rc=0 || rc=$?
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
# Valid JSON in another shape than npm's report is a format change too: a document with neither array, a number,
# an array, and fields that are not arrays each read as "could not verify", never as a clean audit.
expect "an empty object"              UNKNOWN 2 '{}'
expect "a number"                     UNKNOWN 2 '42'
expect "an array"                     UNKNOWN 2 '[]'
expect "null"                         UNKNOWN 2 'null'
expect "fields that are not arrays"   UNKNOWN 2 '{"invalid":{},"missing":{}}'
expect "one array missing"            UNKNOWN 2 '{"invalid":[]}'

# The package names in the verdict's report come from npm's JSON, so they pass the same allowlist: a name carrying
# an escape byte reaches stderr with a `?` in its place.
crafted='{"invalid":[{"name":"evil\u001b[2Jname","version":"1.0.0"}],"missing":[]}'
verdict_err="$(as_verdict_account "${crafted}" 2>&1 >/dev/null || true)"
if [[ "${verdict_err}" == *"evil?[2Jname@1.0.0"* && "${verdict_err}" != *$'\033'* ]]; then
    pass "a package name from npm's JSON reaches the report through the allowlist"
else
    fail "the verdict printed a package name unsanitized: $(printf '%q' "${verdict_err}")"
fi

# An invalid entry is reported with npm's own code, keyid, integrity and message, the fields verify-signatures.js
# writes, on a line of its own under the package; a field npm left out reads as `?`. The verdict is unchanged
# by the detail.
expect "an invalid entry carrying npm's detail" INVALID 1 \
    '{"invalid":[{"name":"corepack","version":"0.36.0","code":"EINTEGRITYSIGNATURE","keyid":"SHA256:abc","integrity":"sha512-xyz"}],"missing":[]}'
detail_err="$(as_verdict_account '{"invalid":[{"name":"corepack","version":"0.36.0","code":"EINTEGRITYSIGNATURE","keyid":"SHA256:abc","integrity":"sha512-xyz"},{"name":"b","version":"1.0.0","code":"EINTEGRITYSIGNATURE"}],"missing":[]}' 2>&1 >/dev/null || true)"
if [[ "${detail_err}" == *$'\nnpm-verify:   corepack@0.36.0: code=EINTEGRITYSIGNATURE keyid=SHA256:abc integrity=sha512-xyz message=?\n'* ]]; then
    pass "an invalid entry is reported with its code, keyid and integrity, and an absent message as ?"
else
    fail "the invalid entry's detail line is not as npm wrote it: $(printf '%q' "${detail_err}")"
fi
if [[ "${detail_err}" == *$'\nnpm-verify:   b@1.0.0: code=EINTEGRITYSIGNATURE keyid=? integrity=?'* ]]; then
    pass "a detail field npm left out reads as ?"
else
    fail "an absent detail field did not read as ?: $(printf '%q' "${detail_err}")"
fi

# A detail field takes the allowlist without the space, so a value cannot carry a second key= into the line, and is cut
# at 160 characters.
long="$(printf 'A%.0s' {1..200})"
crafted_detail="{\"invalid\":[{\"name\":\"p\",\"version\":\"1.0.0\",\"code\":\"E\\u001b[2J\",\"keyid\":\"k code=FORGED\",\"integrity\":\"${long}\"}],\"missing\":[]}"
detail_err="$(as_verdict_account "${crafted_detail}" 2>&1 >/dev/null || true)"
if [[ "${detail_err}" == *"code=E?[2J keyid=k?code=FORGED integrity=$(printf 'A%.0s' {1..160})..."* \
       && "${detail_err}" != *$'\033'* && "${detail_err}" != *" code=FORGED"* ]]; then
    pass "a detail field from npm's JSON keeps no space or escape byte and is cut at 160 characters"
else
    fail "a crafted detail field reached the report: $(printf '%q' "${detail_err}")"
fi

# The detail lines stop at 20 entries, with the rest counted; the summary line still names every package.
many=""
for i in $(seq 1 21); do many+="${many:+,}{\"name\":\"p${i}\",\"version\":\"1.0.0\",\"code\":\"E\"}"; done
detail_err="$(as_verdict_account "{\"invalid\":[${many}],\"missing\":[]}" 2>&1 >/dev/null || true)"
detail_lines="$(grep -c '^npm-verify:   p' <<<"${detail_err}" || true)"
if [[ "${detail_lines}" == 20 && "${detail_err}" == *$'\nnpm-verify:   and 1 more'* && "${detail_err}" == *"p21@1.0.0"* ]]; then
    pass "the detail stops at 20 entries and counts the rest, the summary naming all 21"
else
    fail "the detail for 21 entries printed ${detail_lines} line(s): $(printf '%q' "${detail_err}")"
fi

# npm's message is prose, so it keeps its spaces, closes the line, and is quoted with every quote inside it replaced:
# a message cannot end the quoting early or carry an escape byte.
detail_err="$(as_verdict_account '{"invalid":[{"name":"p","version":"1.0.0","code":"EATTESTATIONVERIFY","message":"attestation \"x\" did not verify\u001b[2J"}],"missing":[]}' 2>&1 >/dev/null || true)"
if [[ "${detail_err}" == *'integrity=? message="attestation ?x? did not verify?[2J"'* && "${detail_err}" != *$'\033'* ]]; then
    pass "npm's message closes the detail line, quoted, with its quotes and escape byte replaced"
else
    fail "npm's message reached the report as: $(printf '%q' "${detail_err}")"
fi

# Fail-closed backstop: the impure verifier refuses to run as root (this suite is root), so it returns "unable
# to verify" (2) without discovering or touching the tree.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    rc=0; ai_tools_npm_verify__verify_signatures >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        pass "verifier refuses to run as root (rc 2, no tree access)"
    else
        fail "verifier as root returned rc ${rc}; expected 2 (root refusal)"
    fi
    # An operator account is refused the same way: the identity required is the sandbox account's, not "not root".
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    rc=0; runuser -u "${PROJECTS_USER}" -- bash -c 'source "$1"; ai_tools_npm_verify__verify_signatures' _ "${LIB}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        pass "verifier refuses to run as the projects user (rc 2, no tree access)"
    else
        fail "verifier as the projects user returned rc ${rc}; expected 2"
    fi
else
    skip "root-refusal backstop" "suite not running as root"
fi

# An npm that does not start -- a copy of the tree that replaced npm's bin/ symlink with its target, whose relative
# require then resolves from bin/ -- is reported as that, with npm's own error line, rather than as an empty tree.
# Driven as the sandbox account, the identity the verifier requires, with npm a shell function: `command -v` finds it,
# so no stub file needs an exec-capable directory. The error carries an escape byte, which the report must not.
npm_error_probe() {
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    bash -c 'npm() { printf "node:internal/modules/cjs/loader:1433\n  throw err;\n\nError: Cannot find module '"'"'../lib/cli.js'"'"'\033[0m\n" >&2; return 1; }
             node() { :; }
             source "$1"; ai_tools_npm_verify__verify_signatures' _ "${LIB}"
}
# The verifier requires the sandbox identity, so the probe runs through as_sandbox as root, directly where the suite
# itself runs as that account, and skips from any other account.
probe_ran=0
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    rc=0; out="$(as_sandbox bash -c "$(declare -f npm_error_probe); LIB='${LIB}' npm_error_probe" 2>&1)" || rc=$?
    probe_ran=1
elif ai_tools_sandbox_exec__is_sandbox_account 2>/dev/null; then
    rc=0; out="$(npm_error_probe 2>&1)" || rc=$?
    probe_ran=1
else
    skip "an npm that does not start" "the probe runs as the sandbox account, which needs root or that account"
fi
if (( ! probe_ran )); then
    :
elif [[ "${rc}" -eq 2 && "${out}" == *"npm does not start (Error: Cannot find module '../lib/cli.js'?[0m)"* ]]; then
    pass "an npm that does not start is named with its own error line, at rc 2, the escape byte replaced by ?"
else
    fail "an npm that does not start read as rc ${rc}: $(tr '\n\033' '|?' <<<"${out}")"
fi

# An invalid signature is audited once more, and only a second OK clears it. npm is a shell function answering each
# `audit signatures` call with the next answer given and counting the calls, and `sleep` is a no-op, so the pause does
# not slow the run. The probe prints the count after the verifier returns.
audit_retry_probe() {
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    bash -c 'first="$2" second="$3"
             state="$(mktemp -d)"; trap "rm -rf -- \"${state}\"" EXIT
             mkdir "${state}/global"; printf 0 > "${state}/audits"
             npm() {
                 case "$1" in
                     --version) printf "10.0.0\n" ;;
                     root) printf "%s\n" "${state}/global" ;;
                     ls) printf "{}" ;;
                     audit) local n; n=$(( $(<"${state}/audits") + 1 )); printf "%s" "${n}" > "${state}/audits"
                            if (( n == 1 )); then printf "%s" "${first}"; else printf "%s" "${second}"; fi ;;
                 esac
             }
             node() { printf "{\"p\":\"1.0.0\"}"; }
             sleep() { :; }
             source "$1"; rc=0; ai_tools_npm_verify__verify_signatures || rc=$?
             printf "audits=%s\n" "$(<"${state}/audits")"; exit "${rc}"' _ "${LIB}" "$1" "$2"
}
invalid_audit='{"invalid":[{"name":"p","version":"1.0.0","code":"EINTEGRITYSIGNATURE"}],"missing":[]}'
clean_audit='{"invalid":[],"missing":[]}'
# expect_retry <desc> <first-answer> <second-answer> <exp-rc> <exp-audits> [<text the report carries>]
expect_retry() {
    local desc="$1" first="$2" second="$3" exp_rc="$4" exp_audits="$5" text="${6:-}" rc=0 out
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        out="$(as_sandbox bash -c "$(declare -f audit_retry_probe); LIB=$(printf '%q' "${LIB}") audit_retry_probe $(
            printf '%q' "${first}") $(printf '%q' "${second}")" 2>&1)" || rc=$?
    elif ai_tools_sandbox_exec__is_sandbox_account 2>/dev/null; then
        out="$(audit_retry_probe "${first}" "${second}" 2>&1)" || rc=$?
    else
        skip "${desc}" "the probe runs as the sandbox account, which needs root or that account"; return 0
    fi
    if [[ "${rc}" -eq "${exp_rc}" && "${out}" == *"audits=${exp_audits}"* && "${out}" == *"${text}"* ]]; then
        pass "${desc} (rc ${rc}, ${exp_audits} audit(s))"
    else
        fail "${desc}: rc ${rc}, expected ${exp_rc} after ${exp_audits} audit(s): $(tr '\n\033' '|?' <<<"${out}")"
    fi
}
expect_retry "a clean first audit is not repeated" "${clean_audit}" "${invalid_audit}" 0 1
expect_retry "an invalid signature a second audit verifies is cleared" "${invalid_audit}" "${clean_audit}" 0 2 \
    "the second audit verified every signature"
expect_retry "an invalid signature a second audit repeats stays a tamper" "${invalid_audit}" "${invalid_audit}" 1 2 \
    "the second audit did not verify every signature"
expect_retry "an invalid signature a second audit cannot read stays a tamper, not unable to verify" \
    "${invalid_audit}" "" 1 2 "the second audit did not verify every signature"

finish
