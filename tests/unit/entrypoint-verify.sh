#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/entrypoint-verify.sh
# Unit test for the entrypoint verifier (entrypoint-verify.lib.sh). Drives its PURE decisions --
# the pin verdict, the platform-key mapping, the release-manifest URL builder, and the checksum
# extractor -- over their truth tables. None of them fetches, hashes, or needs privilege, so this
# runs with no network and no vendor.
#
# The properties that must not regress, each one a way the verifier could fail OPEN:
#   * an ABSENT pin must never read as a mismatch. A fresh install and a modified binary are
#     different facts with different remedies, and collapsing them reports a clean host as tamper
#     (or, inverted, blesses a tampered one).
#   * a checksum must be admitted only in exact 64-hex shape. Malformed JSON, an absent platform,
#     or a crafted value must yield NOTHING -- a partial or attacker-shaped value that compares
#     equal to a partial observation is the fail-open this gate exists to prevent.
#   * a URL template with no {version} slot must be REFUSED, not fetched as-is: one manifest for
#     every version reads as "verified" while checking the wrong release.
#   * only https, and only a character set that cannot carry a shell metacharacter into curl.
#
# The impure half (ai_tools_entrypoint_release_verify) needs the vendor's live endpoint, gpgv, and
# a 300 MB hash, so it is not driven here; its status contract is exercised where it is wired in.
# Run as root via sudo (the suite's convention), though nothing here needs it.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
section "entrypoint-verify: pure verdicts (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "entrypoint-verify" "not installed at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}"

# The stamp accessors, which is how `ai-tools --status` reads the label record this library writes.
# Loaded here so the round-trip below is asserted through the REAL reader rather than a local one:
# the record and the reader are only worth anything if they agree on the grammar.
readonly SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"
# shellcheck source=/dev/null
source "${SERVICES_LIB}" 2>/dev/null || true

readonly SHA_A="55d281096f57d411ebbdd94dbf5e9ff3accb7c05713e37348c2c11d4b83bf9d9"
readonly SHA_B="0000000000000000000000000000000000000000000000000000000000000000"

# ── The pin verdict ──────────────────────────────────────────────────────────────────────────
# <expected> <observed> <want-token> <want-status> <why>
while IFS='|' read -r expected observed want_token want_status why; do
    [[ -n "${expected}${observed}${want_token}" ]] || continue
    got_token="$(ai_tools_entrypoint_pin_verdict "${expected}" "${observed}")" && got_status=0 || got_status=$?
    if [[ "${got_token}" == "${want_token}" && "${got_status}" == "${want_status}" ]]; then
        pass "pin verdict: ${why} -> ${want_token} (${want_status})"
    else
        fail "pin verdict: ${why} -> got ${got_token} (${got_status}), want ${want_token} (${want_status})"
    fi
done <<EOF
${SHA_A}|${SHA_A}|ok|0|matching checksums
${SHA_A}|${SHA_B}|mismatch|1|different checksums are the tamper signal
|${SHA_A}|unpinned|2|nothing has verified this entrypoint yet
${SHA_A}||unreadable|2|the entrypoint could not be hashed
|||unpinned|2|neither side present errs toward unpinned, never mismatch
notahash|${SHA_A}|unpinned|2|a malformed pin reads as absent, not as a checksum
${SHA_A}|notahash|unreadable|2|a malformed observation never compares equal
${SHA_A^^}|${SHA_A}|unpinned|2|uppercase is not the canonical shape, so it is not trusted as one
EOF

# ── Platform key ─────────────────────────────────────────────────────────────────────────────
while IFS='|' read -r machine libc want why; do
    [[ -n "${machine}" ]] || continue
    got="$(ai_tools_entrypoint_platform_key "${machine}" "${libc}" 2>/dev/null || printf '')"
    if [[ "${got}" == "${want}" ]]; then
        pass "platform key: ${why} -> '${want}'"
    else
        fail "platform key: ${why} -> got '${got}', want '${want}'"
    fi
done <<'EOF'
x86_64||linux-x64|x86_64 glibc
aarch64||linux-arm64|aarch64 glibc
amd64||linux-x64|the amd64 spelling maps to the same key
x86_64|musl|linux-x64-musl|x86_64 musl
aarch64|musl|linux-arm64-musl|aarch64 musl
riscv64|||an unmapped architecture yields nothing rather than a guess
EOF

# ── Release-manifest URL ─────────────────────────────────────────────────────────────────────
readonly TEMPLATE='https://downloads.claude.ai/claude-code-releases/{version}/manifest.json'
url="$(ai_tools_release_manifest_url "${TEMPLATE}" 2.1.233 2>/dev/null || printf '')"
if [[ "${url}" == "https://downloads.claude.ai/claude-code-releases/2.1.233/manifest.json" ]]; then
    pass "release URL: the {version} slot is substituted"
else
    fail "release URL: got '${url}'"
fi

# Each of these must be refused. A template with no slot is the important one: it would pin every
# version to one manifest and report "verified" for a release it never checked.
while IFS='|' read -r template version why; do
    [[ -n "${template}" ]] || continue
    if ai_tools_release_manifest_url "${template}" "${version}" >/dev/null 2>&1; then
        fail "release URL: ${why} was NOT refused"
    else
        pass "release URL refused: ${why}"
    fi
done <<'EOF'
https://x.example/manifest.json|2.1.233|a template with no {version} slot
http://x.example/{version}/manifest.json|2.1.233|a non-https template
https://x.example/{version}/manifest.json|2.1|a version that is not semver
https://x.example/{version}/manifest.json|../../etc/passwd|a traversal in place of a version
https://x.example/{version}/manifest.json|2.1.233; id|a shell metacharacter in the version
https://x.example/../{version}/m.json|2.1.233|a traversal in the template itself
EOF

# ── Checksum extraction ──────────────────────────────────────────────────────────────────────
readonly GOOD_JSON="{\"version\":\"2.1.233\",\"platforms\":{\"linux-x64\":{\"binary\":\"claude\",\"checksum\":\"${SHA_A}\",\"size\":324598064}}}"
if [[ "$(ai_tools_release_manifest_checksum "${GOOD_JSON}" linux-x64 2>/dev/null || printf '')" == "${SHA_A}" ]]; then
    pass "checksum extraction: the platform's checksum is read from a well-formed manifest"
else
    skip "checksum extraction" "jq unavailable or manifest shape changed"
fi

while IFS='|' read -r json platform why; do
    [[ -n "${json}" ]] || continue
    if ai_tools_release_manifest_checksum "${json}" "${platform}" >/dev/null 2>&1; then
        fail "checksum extraction: ${why} yielded a checksum"
    else
        pass "checksum extraction yields nothing: ${why}"
    fi
done <<EOF
${GOOD_JSON}|linux-arm64|a platform the manifest does not list
{ not json at all|linux-x64|malformed JSON
{"platforms":{"linux-x64":{"checksum":"short"}}}|linux-x64|a checksum that is not 64 hex digits
{"platforms":{"linux-x64":{"checksum":"\$(id)"}}}|linux-x64|a crafted non-hex checksum value
{"platforms":{}}|linux-x64|a manifest with no platforms
EOF

# ── The pin path ─────────────────────────────────────────────────────────────────────────────
# Public, because `ai-tools --status` reads the pin to report verification state and must not
# hardcode where it lives. The agent name becomes a path component, so it is allowlisted to one
# plain identifier first — the same guard ai_tools_agent_manifest_field applies — and a name that
# could escape the pin directory must yield NOTHING rather than a path outside it.
if [[ "$(ai_tools_entrypoint_pin_path claude-code 2>/dev/null || printf '')" \
      == "${AI_TOOLS_ENTRYPOINT_PIN_DIR:-/var/opt/ai-tools/state/entrypoint-pin.d}/claude-code" ]]; then
    pass "pin path: a plain agent name resolves inside the pin directory"
else
    fail "pin path: claude-code did not resolve to a pin inside the pin directory"
fi
for bad in "../../etc/passwd" "a/b" ".." "" "a b"; do
    if ai_tools_entrypoint_pin_path "${bad}" >/dev/null 2>&1; then
        fail "pin path: agent name '${bad}' was accepted -- it could address a file outside the pin directory"
    else
        pass "pin path refused: agent name '${bad}'"
    fi
done

# ── The pin is root-write-only ───────────────────────────────────────────────────────────────
# The whole value of the pin is that the account it constrains cannot write it. The library
# refuses a non-root write itself rather than letting it fail on EACCES, so a caller can tell
# "not permitted" from "the directory is missing". Probed as the sandbox account.
if ! command -v runuser >/dev/null 2>&1; then
    skip "pin write is root-only" "runuser unavailable"
elif runuser -u "${SANDBOX_USER}" -- bash -c "source '${LIB}'; ai_tools_entrypoint_pin_write probe 1.0.0 ${SHA_A} https://x" 2>/dev/null; then
    fail "the sandbox account was allowed to write an entrypoint pin -- it could bless its own binary"
else
    pass "the sandbox account cannot write an entrypoint pin (root-only by construction)"
fi

# ── The label record ─────────────────────────────────────────────────────────────────────────
# The labelling half of a reconciliation files its outcome beside the pin, and `ai-tools --status`
# reads it to report whether the last relabel could apply an agent's SELinux rules. Without it the
# report shows the verification half alone -- a fresh green line written by the same run whose
# labelling failed, which reads as an all-clear rather than as half a story.
#
# It shares the pin's path guard, so the same escapes are refused: an agent name becomes a path
# component here too.
if [[ "$(ai_tools_entrypoint_label_path claude-code 2>/dev/null || printf '')" \
      == "${AI_TOOLS_ENTRYPOINT_LABEL_DIR:-/var/opt/ai-tools/state/entrypoint-label.d}/claude-code" ]]; then
    pass "label path: a plain agent name resolves inside the label directory"
else
    fail "label path: claude-code did not resolve to a record inside the label directory"
fi
for bad in "../../etc/passwd" "a/b" ".." "" "a b"; do
    if ai_tools_entrypoint_label_path "${bad}" >/dev/null 2>&1; then
        fail "label path: agent name '${bad}' was accepted -- it could address a file outside the label directory"
    else
        pass "label path refused: agent name '${bad}'"
    fi
done

# A result outside the vocabulary is refused rather than filed: `ai-tools --status` reports an
# unrecognised RESULT as "no labelling recorded", so a typo would read as a host that has never
# relabelled instead of as the outcome it meant to record.
mktestdir
AI_TOOLS_ENTRYPOINT_LABEL_DIR="${TESTDIR}/labels"
for bad_result in "" "OK" "success" "failed;id"; do
    if ai_tools_entrypoint_label_write claude-code "${bad_result}" 2>/dev/null; then
        fail "label write accepted the result '${bad_result}'"
    else
        pass "label write refused the result '${bad_result:-<empty>}'"
    fi
done

# Root-only, for the same reason the pin is: it is a record about the sandbox account's own
# entrypoint, placed where that account cannot rewrite it.
if ! declare -F ai_tools_service_stamp_field >/dev/null 2>&1; then
    skip "label record round trip" "services.lib.sh not readable at ${SERVICES_LIB}"
elif [[ "${EUID}" -ne 0 ]]; then
    skip "label record round trip" "needs root to write into the record directory"
elif ! command -v runuser >/dev/null 2>&1; then
    skip "label write is root-only" "runuser unavailable"
else
    if runuser -u "${SANDBOX_USER}" -- bash -c \
        "AI_TOOLS_ENTRYPOINT_LABEL_DIR='${AI_TOOLS_ENTRYPOINT_LABEL_DIR}'; source '${LIB}'; ai_tools_entrypoint_label_write probe ok" 2>/dev/null; then
        fail "the sandbox account was allowed to write a label record -- it could report its own labels healthy"
    else
        pass "the sandbox account cannot write a label record (root-only by construction)"
    fi

    # Written in the stamp grammar, so --status reads it through the same accessors as the pin
    # rather than a second reader that could drift.
    if ai_tools_entrypoint_label_write claude-code failed rule-not-registered \
       && [[ "$(ai_tools_service_stamp_field "$(ai_tools_entrypoint_label_path claude-code)" RESULT)" == failed \
             && "$(ai_tools_service_stamp_field "$(ai_tools_entrypoint_label_path claude-code)" REASON)" == rule-not-registered \
             && -n "$(ai_tools_service_stamp_age "$(ai_tools_entrypoint_label_path claude-code)" LABELLED)" ]]; then
        pass "a written record reads back through the shared stamp accessors"
    else
        fail "the label record did not read back as RESULT=failed with its reason and a LABELLED age"
    fi

    # A reason is a token, never prose: the accessors' charset clamp admits no spaces, so a value
    # carrying any would read as absent and the record would lose the field silently. It is dropped
    # at write time instead, leaving a record whose every field can be read back.
    if ai_tools_entrypoint_label_write claude-code failed "rule not registered; id" \
       && [[ -z "$(grep -c '^REASON=' "$(ai_tools_entrypoint_label_path claude-code)" 2>/dev/null | grep -v '^0$')" ]]; then
        pass "a reason that is not a token is dropped rather than written unreadable"
    else
        fail "a non-token reason was written into the record"
    fi
fi

finish
