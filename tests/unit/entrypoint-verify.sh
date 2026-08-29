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

# ── Pin reuse: answering from the pin instead of refetching the signed manifest ───────────────
# The unattended callers (the relabel watcher, the agent package's %post) may skip the fetch and
# the gpgv when nothing that decides the verdict has changed. Every assertion below targets a way
# that shortcut could answer a question it was not asked -- which is the only way it can fail
# open, since a reused verdict is indistinguishable from a fresh one to everything downstream.
section "entrypoint-verify: pin reuse (unit)"

# Asserted only when the deployed library actually carries the predicate. Without this guard an
# absent function exits 127, which every negative case below would read as a correct refusal --
# the section would report green while testing nothing at all.
if ! declare -F ai_tools_entrypoint_pin_reusable >/dev/null 2>&1 \
        || ! declare -F ai_tools_entrypoint_inputs_digest >/dev/null 2>&1; then
    skip "pin reuse" "the installed ${LIB} carries no pin-reuse predicate -- reinstall to cover it"
    finish; exit
fi

mktestdir
AI_TOOLS_ENTRYPOINT_PIN_DIR="${TESTDIR}/pins"
mkdir -p "${AI_TOOLS_ENTRYPOINT_PIN_DIR}"
printf 'key-one\n' > "${TESTDIR}/key-one.asc"
printf 'key-two\n' > "${TESTDIR}/key-two.asc"

DIGEST="$(ai_tools_entrypoint_inputs_digest "https://v/{version}/m.json" "${TESTDIR}/key-one.asc" "AAAA" || true)"
if [[ "${DIGEST}" =~ ^[0-9a-f]{64}$ ]]; then
    pass "the inputs digest is a 64-hex value"
else
    fail "the inputs digest was not 64 hex: '${DIGEST}'"
fi

# Each declared input must move the digest, or a change to it would be invisible to the reuse
# check and the pin would answer for a verification nobody performed under the new inputs. The
# key's CONTENT is included, not just its path, so a rotation that ships a new key at the same
# path still forces a full verification.
printf 'key-one-modified\n' > "${TESTDIR}/key-one-rotated.asc"
for variant in \
        "https://OTHER/{version}/m.json|${TESTDIR}/key-one.asc|AAAA|url template" \
        "https://v/{version}/m.json|${TESTDIR}/key-two.asc|AAAA|key path" \
        "https://v/{version}/m.json|${TESTDIR}/key-one-rotated.asc|AAAA|key content" \
        "https://v/{version}/m.json|${TESTDIR}/key-one.asc|BBBB|fingerprints"; do
    IFS='|' read -r v_url v_key v_fpr v_what <<< "${variant}"
    if [[ "$(ai_tools_entrypoint_inputs_digest "${v_url}" "${v_key}" "${v_fpr}" || true)" == "${DIGEST}" ]]; then
        fail "the inputs digest ignored a change of ${v_what}"
    else
        pass "the inputs digest changes with the ${v_what}"
    fi
done

if ai_tools_entrypoint_inputs_digest "https://v/{version}/m.json" "${TESTDIR}/absent.asc" "AAAA" >/dev/null 2>&1; then
    fail "the inputs digest was produced for an unreadable key file"
else
    pass "an unreadable key file yields no digest, so the run verifies in full"
fi

# The pin files are written by hand rather than through pin_write, which is root-only: what is
# under test is the DECISION, and driving it from fixtures keeps the truth table root-free.
write_pin() {   # write_pin <agent> <version> <sha256> <inputs>
    { printf 'AGENT=%s\nVERSION=%s\nSHA256=%s\nVERIFIED=2026-01-01T00:00:00Z\n' "$1" "$2" "$3"
      if [[ -n "${4:-}" ]]; then printf 'INPUTS=%s\n' "$4"; fi
    } > "${AI_TOOLS_ENTRYPOINT_PIN_DIR}/$1"
}

write_pin claude-code 1.2.3 "${SHA_A}" "${DIGEST}"
if ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_A}"; then
    pass "an unchanged version, inputs and entrypoint reuse the pin"
else
    fail "a pin matching on every field was not reusable"
fi

# The three fields that must each veto reuse on their own. A changed SHA256 is a changed binary,
# which is the tamper case the pin exists for; a changed VERSION or INPUTS means the recorded
# verdict answers a different question.
if ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_B}"; then
    fail "a pin was reused for an entrypoint whose checksum had changed"
else
    pass "a changed entrypoint checksum forces a full verification"
fi
if ai_tools_entrypoint_pin_reusable claude-code 9.9.9 "${DIGEST}" "${SHA_A}"; then
    fail "a pin was reused across a version change"
else
    pass "a changed installed version forces a full verification"
fi
if ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${SHA_B}" "${SHA_A}"; then
    fail "a pin was reused after its verification inputs changed"
else
    pass "changed verification inputs force a full verification"
fi

# A pin carrying no INPUTS cannot state which inputs produced it, so it is never reusable. This
# is also what makes the field safe to introduce: an existing pin simply verifies once more.
write_pin claude-code 1.2.3 "${SHA_A}" ""
if ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_A}"; then
    fail "a pin with no INPUTS field was reused"
else
    pass "a pin recording no inputs is never reused"
fi

# Absent, unhashable and malformed values all land on a full verification rather than on reuse.
rm -f "${AI_TOOLS_ENTRYPOINT_PIN_DIR}/claude-code"
if ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_A}"; then
    fail "a missing pin was treated as reusable"
else
    pass "a missing pin is never reusable"
fi
write_pin claude-code 1.2.3 "${SHA_A}" "${DIGEST}"
refuses_reuse() {   # refuses_reuse <what> <version> <inputs> <observed>
    if ai_tools_entrypoint_pin_reusable claude-code "$2" "$3" "$4"; then
        fail "the pin was reused with $1"
    else
        pass "reuse is refused with $1"
    fi
}
refuses_reuse "no version, digest or checksum" "" "" ""
refuses_reuse "no inputs digest"               1.2.3 "" "${SHA_A}"
refuses_reuse "no observed checksum"           1.2.3 "${DIGEST}" ""
refuses_reuse "a malformed observed checksum"  1.2.3 "${DIGEST}" "not-a-sha"

# The written pin and the reuse check must agree on the grammar, so the round trip runs through
# the real writer. Root-only, like every other pin write.
if [[ "${EUID}" -ne 0 ]]; then
    skip "pin write records its inputs digest" "needs root to write into the pin directory"
else
    rm -f "${AI_TOOLS_ENTRYPOINT_PIN_DIR}/claude-code"
    if ai_tools_entrypoint_pin_write claude-code 1.2.3 "${SHA_A}" "https://v/{version}/m.json" "${DIGEST}" \
       && ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_A}"; then
        pass "a pin written with its inputs digest reads back as reusable"
    else
        fail "a pin written through pin_write did not read back as reusable"
    fi
    # A pin written without a digest stays non-reusable, so an unrecordable digest costs a
    # re-verification instead of granting an unconditional shortcut.
    rm -f "${AI_TOOLS_ENTRYPOINT_PIN_DIR}/claude-code"
    if ai_tools_entrypoint_pin_write claude-code 1.2.3 "${SHA_A}" "https://v/{version}/m.json" \
       && ! ai_tools_entrypoint_pin_reusable claude-code 1.2.3 "${DIGEST}" "${SHA_A}"; then
        pass "a pin written without a digest is not reusable"
    else
        fail "a pin written without an inputs digest was reusable"
    fi
fi

finish
