#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/assets-verify.sh
# Unit test for the set verifier (assets-verify.lib.sh): the runtime half of the guarantee that a set links only
# under a signature a shipped binding names. Drives the INSTALLED library over a set signed in this run by a throwaway
# key, through the root-only hook AI_TOOLS_ASSETS_BINDINGS_DIR, and asserts every refusal of the status contract:
#   * status 1, MSG-T3M3, for a bad or expired signature, a signature by a key the keyring holds as expired or revoked,
#     and every way the inventory stops describing the tree;
#   * status 2, MSG-Q6Y8, for every input that is absent, untrusted or names a signer the binding does not, and for
#     a signature file holding two signatures;
#   * status 0 for the control set, printing the signer's primary.
# The boundary half, that the key, the binding and the keyring are not writable by the sandbox account, is
# tests/boundary/assets.sh. The key is made in the run, so the tree does not hold any secret, and the "signed
# by a key the binding does not name" case takes a second key the same way. gpg makes the keys and the signatures;
# gpgv alone verifies, as on a host. Run as root via sudo: a binding and a keyring are trusted only root-owned,
# so the fixtures are born root's.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/assets-verify.lib.sh"
section "assets-verify: the set verifier (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "assets-verify" "not installed at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}"
# Every function this file calls, checked before the first case: an absent one exits 127, which a refusal case would
# read as a correct refusal, so an installed library older than this test stops here instead of reporting
# verdicts.
for function_name in ai_tools_assets_verify__verify_set ai_tools_assets_verify__verify_inventory ai_tools_assets_verify__read_binding \
    ai_tools_assets_verify__find_binding \
    ai_tools_openpgp__write_binary_keyring ai_tools_assets_verify__is_valid_set_name \
    ai_tools_assets_verify__is_valid_signer_fingerprint; do
    if ! declare -F "${function_name}" >/dev/null; then
        fail "${LIB} does not define ${function_name}; reinstall from this checkout (sudo ./install.sh)"
        finish; exit 1
    fi
done

mktestdir
umask 022

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
# A keyring per key, the throwaway set, and a bindings directory, every trusted path root-owned 0644 under 0755.
readonly KEYS="${TESTDIR}/keys"
readonly BINDINGS="${TESTDIR}/bindings.d"
readonly OPERATOR_BINDINGS="${TESTDIR}/etc-bindings.d"
readonly SET="${TESTDIR}/sets/acme"
mkdir -p "${KEYS}" "${BINDINGS}" "${OPERATOR_BINDINGS}" "${TESTDIR}/sets"
chmod 0755 "${KEYS}" "${BINDINGS}" "${OPERATOR_BINDINGS}"
export AI_TOOLS_ASSETS_BINDINGS_DIR="${BINDINGS}" AI_TOOLS_ASSETS_OPERATOR_BINDINGS_DIR="${OPERATOR_BINDINGS}"

have_gpg=yes
command -v gpg >/dev/null 2>&1 || have_gpg=no
command -v gpgv >/dev/null 2>&1 || have_gpg=no

# The shared signing recipe (tests/lib/asset-signing.sh), bound to this test's set and directories.
export ASSET_KEYS_DIR="${KEYS}" ASSET_BINDINGS_DIR="${BINDINGS}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/asset-signing.sh"
gen_key() { asset_signing_gen_key "$@"; }
write_inventory() { asset_signing_write_inventory "${SET}"; }
sign_set() { asset_signing_sign "${SET}" "$@"; }
write_binding() { asset_signing_write_binding "$@"; }

# write_set: the throwaway set, with its inventory in build-set's shape.
write_set() {
    rm -rf "${SET}"
    mkdir -p "${SET}/.claude-plugin" "${SET}/skills/acme-pdf" "${SET}/agents"
    printf 'format=1\nname=acme\nversion=0.1.0\n' > "${SET}/set.conf"
    printf '{"name": "acme"}\n' > "${SET}/.claude-plugin/plugin.json"
    printf -- '---\nname: acme-pdf\n---\nA fixture skill.\n' > "${SET}/skills/acme-pdf/SKILL.md"
    printf -- '---\nname: acme-reviewer\n---\nA fixture subagent.\n' > "${SET}/agents/acme-reviewer.md"
    write_inventory
}

# expect <status> <what> <command...>: run the verifier call, assert its status, keep its output in `out` and its stderr
# in `err` for the assertions that follow.
out=""; err=""
expect() {
    local want="$1" what="$2" got=0
    shift 2
    out="$("$@" 2>"${TESTDIR}/err")" || got=$?
    err="$(<"${TESTDIR}/err")"
    if [[ "${got}" == "${want}" ]]; then
        pass "${what} -> ${want}"
    else
        fail "${what} -> got ${got}, want ${want}: $(head -c 300 <<<"${err}" | tr '\n' '|')"
    fi
}

# ── Pure predicates ──────────────────────────────────────────────────────────────────────────────
while IFS='|' read -r name want why; do
    [[ -n "${why}" ]] || continue
    got=0; ai_tools_assets_verify__is_valid_set_name "${name}" || got=$?
    if [[ "${got}" == "${want}" ]]; then pass "set name: ${why}"; else fail "set name: ${why} -> got ${got}, want ${want}"; fi
done <<'EOF'
core|0|a plain name
dag-node-probe|0|hyphens inside
Core|1|an upper-case letter
a--b|1|two hyphens together
-a|1|a leading hyphen
../x|1|a traversal
|1|the empty string
EOF
if ai_tools_assets_verify__is_valid_set_name "$(printf 'a%.0s' {1..64})"; then pass "set name: 64 characters"; else fail "set name: 64 characters refused"; fi
if ai_tools_assets_verify__is_valid_set_name "$(printf 'a%.0s' {1..65})"; then fail "set name: 65 characters accepted"; else pass "set name: 65 characters refused"; fi

while IFS='|' read -r item want why; do
    [[ -n "${why}" ]] || continue
    got=0; ai_tools_assets_verify__is_valid_signer_fingerprint "${item}" || got=$?
    if [[ "${got}" == "${want}" ]]; then pass "signer: ${why}"; else fail "signer: ${why} -> got ${got}, want ${want}"; fi
done <<'EOF'
openpgp:67F42DC18BF764B42D82F14256D2F802CF9832E4|0|openpgp: and 40 hex digits
openpgp:67f42dc18bf764b42d82f14256d2f802cf9832e4|0|lower-case hex
67F42DC18BF764B42D82F14256D2F802CF9832E4|1|no type prefix
openpgp:67F42DC18BF764B42D82F14256D2F802CF9832E|1|39 digits
x509:67F42DC18BF764B42D82F14256D2F802CF9832E4|1|a type this release does not define
EOF

# ── The shipped keyring and bindings agree with each other ────────────────────────────────────────
# The deployed artifacts, read as data: each shipped binding names the primary of the key the shipped keyring holds,
# and the keyring is the dearmored form of the armored key beside it. The fingerprint is computed from the key packet
# (RFC 4880 v4: SHA-1 over 0x99, a two-byte length and the packet body), so the check does not need gpg.
readonly SHIPPED_KEY=/usr/local/lib/ai-tools/keys/dag-node-package-signing
readonly SHIPPED_BINDINGS=/usr/local/lib/ai-tools/assets-bindings.d
if [[ -r "${SHIPPED_KEY}.asc" && -r "${SHIPPED_KEY}.gpg" && -d "${SHIPPED_BINDINGS}" ]]; then
    ai_tools_openpgp__write_binary_keyring "${SHIPPED_KEY}.asc" "${TESTDIR}/shipped.gpg"
    if cmp -s "${TESTDIR}/shipped.gpg" "${SHIPPED_KEY}.gpg"; then
        pass "the shipped keyring is the dearmored form of the shipped armored key"
    else
        fail "the shipped keyring differs from the dearmored form of ${SHIPPED_KEY}.asc"
    fi
    shipped_primary="$(python3 - "${SHIPPED_KEY}.gpg" <<'PY'
import hashlib, sys
data = open(sys.argv[1], "rb").read()
i = 0
while i < len(data):
    c = data[i]; i += 1
    if c & 0x40:
        tag = c & 0x3f; l = data[i]; i += 1
        if l < 192: length = l
        elif l < 224: length = ((l - 192) << 8) + data[i] + 192; i += 1
        elif l == 255: length = int.from_bytes(data[i:i + 4], "big"); i += 4
        else: sys.exit(1)
    else:
        tag = (c >> 2) & 0x0f; lt = c & 3
        if lt == 0: length = data[i]; i += 1
        elif lt == 1: length = int.from_bytes(data[i:i + 2], "big"); i += 2
        elif lt == 2: length = int.from_bytes(data[i:i + 4], "big"); i += 4
        else: sys.exit(1)
    body = data[i:i + length]; i += length
    if tag == 6:
        print(hashlib.sha1(b"\x99" + length.to_bytes(2, "big") + body).hexdigest().upper())
        break
PY
)"
    for binding in "${SHIPPED_BINDINGS}"/*.conf; do
        [[ -e "${binding}" ]] || continue
        stem="$(basename "${binding}" .conf)"
        # shellcheck disable=SC2154  # the two names are ai_tools_assets_verify__read_binding's outputs
        if AI_TOOLS_ASSETS_BINDINGS_DIR="${SHIPPED_BINDINGS}" ai_tools_assets_verify__read_binding "${stem}" 2>/dev/null \
            && [[ " ${_AI_TOOLS_ASSETS_VERIFY__SIGNERS[*]} " == *" ${shipped_primary} "* && "${_AI_TOOLS_ASSETS_VERIFY__KEYRING}" == "${SHIPPED_KEY}.gpg" ]]; then
            pass "shipped binding ${stem}: names the shipped key's primary ${shipped_primary} and the shipped keyring"
        else
            fail "shipped binding ${stem}: does not read as a binding for primary ${shipped_primary} and keyring ${SHIPPED_KEY}.gpg"
        fi
    done
else
    skip "shipped key and bindings" "not installed under /usr/local/lib/ai-tools"
fi

# ── The signed set ───────────────────────────────────────────────────────────────────────────────
if [[ "${have_gpg}" != yes ]]; then
    skip "signed-set cases" "gpg or gpgv not installed"; finish; exit
fi
gen_key SIGNER signer
gen_key OTHER other
cat "${KEYS}/signer.gpg" "${KEYS}/other.gpg" > "${KEYS}/both.gpg"; chmod 0644 "${KEYS}/both.gpg"
write_set; sign_set signer
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"

expect 0 "control: the signed set verifies" ai_tools_assets_verify__verify_set "${SET}" acme
if [[ "${out}" == "${SIGNER}" ]]; then pass "status 0 prints the signer's primary"; else fail "status 0 printed '${out}', not ${SIGNER}"; fi
expect 0 "control: the inventory half alone" ai_tools_assets_verify__verify_inventory "${SET}"
if [[ -z "${out}" ]]; then pass "the inventory half prints nothing"; else fail "the inventory half printed '${out}'"; fi
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER,,}"
expect 0 "a signer written in lower-case hex matches" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/both.gpg" "openpgp:${OTHER}" "openpgp:${SIGNER}"
expect 0 "a keyring holding two keys and a binding naming both" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"

# status 1: the tree stops matching the signed inventory, or the signature stops matching the inventory
printf 'x' >> "${SET}/set.conf"
expect 1 "an edited file" ai_tools_assets_verify__verify_set "${SET}" acme
assert_msg MSG-T3M3 "${err}" "an edited file is reported under MSG-T3M3"
write_set; sign_set signer
printf 'extra\n' > "${SET}/skills/acme-pdf/extra.md"
expect 1 "an added file" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer
rm "${SET}/agents/acme-reviewer.md"
expect 1 "a removed file" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer
printf 'x' >> "${SET}/set.conf"; write_inventory
expect 1 "an inventory rewritten after an edit: the signature no longer covers it" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer
first_line="$(head -1 "${SET}/SHA256SUMS")"; printf '%s\n' "${first_line}" >> "${SET}/SHA256SUMS"; sign_set signer
expect 1 "a file listed twice" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'not an inventory line\n' >> "${SET}/SHA256SUMS"; sign_set signer
expect 1 "a line outside the inventory shape" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sed -i 's|  set.conf$|  /etc/passwd|' "${SET}/SHA256SUMS"; sign_set signer
expect 1 "an absolute path in the inventory" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sed -i 's|  set.conf$|  ../set.conf|' "${SET}/SHA256SUMS"; sign_set signer
expect 1 "a traversal in the inventory" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer; ln -s set.conf "${SET}/link"
expect 1 "a symlink in the set" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer; mkfifo "${SET}/fifo" 2>/dev/null \
    && expect 1 "a special file in the set" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer; mkdir "${SET}/empty"
expect 0 "an empty directory is not a file and is not listed" ai_tools_assets_verify__verify_set "${SET}" acme

# status 2: an input is absent, untrusted or unmatched
write_set; sign_set signer
rm "${SET}/SHA256SUMS.asc"
expect 2 "no signature file" ai_tools_assets_verify__verify_set "${SET}" acme
assert_msg MSG-Q6Y8 "${err}" "an absent signature is reported under MSG-Q6Y8"
write_set; sign_set signer; rm "${SET}/SHA256SUMS"
expect 2 "no inventory file" ai_tools_assets_verify__verify_set "${SET}" acme
expect 2 "the inventory half with no inventory file" ai_tools_assets_verify__verify_inventory "${SET}"
write_set; sign_set signer; mv "${SET}/SHA256SUMS.asc" "${TESTDIR}/asc"; ln -s "${TESTDIR}/asc" "${SET}/SHA256SUMS.asc"
expect 2 "a signature file that is a symlink" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set other
expect 2 "signed by a key the keyring does not hold" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/both.gpg" "openpgp:${SIGNER}"
expect 2 "signed by a key in the keyring that the binding does not name" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
expect 2 "a set name with no binding" ai_tools_assets_verify__verify_set "${SET}" nobinding
expect 2 "a set name outside the grammar" ai_tools_assets_verify__verify_set "${SET}" "Acme"
expect 2 "a set directory that does not exist" ai_tools_assets_verify__verify_set "${TESTDIR}/absent" acme
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"; printf 'origin=https://example.com\n' >> "${BINDINGS}/acme.conf"
expect 2 "a binding carrying a key this release does not define" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/signer.gpg" "${SIGNER}"
expect 2 "a signer without its openpgp: type" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/signer.gpg"
expect 2 "a binding naming no signer" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding other "${KEYS}/signer.gpg" "openpgp:${SIGNER}"; mv "${BINDINGS}/other.conf" "${BINDINGS}/acme.conf"
expect 2 "a binding whose set= is not the file's stem" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/absent.gpg" "openpgp:${SIGNER}"
expect 2 "a binding naming an absent keyring" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "keys/signer.gpg" "openpgp:${SIGNER}"
expect 2 "a binding naming a relative keyring" ai_tools_assets_verify__verify_set "${SET}" acme
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"; chmod 0664 "${BINDINGS}/acme.conf"
expect 2 "a group-writable binding" ai_tools_assets_verify__verify_set "${SET}" acme
chmod 0644 "${BINDINGS}/acme.conf"; chown "${PROJECTS_USER}" "${BINDINGS}/acme.conf"
expect 2 "a binding not owned by root" ai_tools_assets_verify__verify_set "${SET}" acme
chown root:root "${BINDINGS}/acme.conf"
mv "${BINDINGS}/acme.conf" "${TESTDIR}/acme.conf"; ln -s "${TESTDIR}/acme.conf" "${BINDINGS}/acme.conf"
expect 2 "a binding that is a symlink" ai_tools_assets_verify__verify_set "${SET}" acme
rm "${BINDINGS}/acme.conf"; mv "${TESTDIR}/acme.conf" "${BINDINGS}/acme.conf"
chmod 0775 "${BINDINGS}"
expect 2 "a group-writable bindings directory" ai_tools_assets_verify__verify_set "${SET}" acme
chmod 0755 "${BINDINGS}"
chmod 0664 "${KEYS}/signer.gpg"
expect 2 "a group-writable keyring" ai_tools_assets_verify__verify_set "${SET}" acme
chmod 0644 "${KEYS}/signer.gpg"; chmod 0775 "${KEYS}"
expect 2 "a group-writable keyring directory" ai_tools_assets_verify__verify_set "${SET}" acme
chmod 0755 "${KEYS}"
expect 0 "control: the set verifies again once every input is restored" ai_tools_assets_verify__verify_set "${SET}" acme

# Signatures gpgv exits 0 or 1 for and reports on its status lines: a key the keyring holds as expired or revoked,
# an expired signature, and a signature file holding two signatures. Each setup is asserted from gpgv's own status lines
# before the verdict, since a key gpg did not expire would otherwise read as one that verifies. gpgv_keywords <keyring>
# : the status keywords gpgv prints for the set's signature, space-separated.
gpgv_keywords() {
    gpgv --status-fd 1 --keyring "$1" "${SET}/SHA256SUMS.asc" "${SET}/SHA256SUMS" 2>/dev/null | awk '{ print $2 }' | tr '\n' ' '
}
gen_key EXPIRED expired 1d 20200101T000000
write_set; sign_set expired
write_binding acme "${KEYS}/expired.gpg" "openpgp:${EXPIRED}"
if [[ " $(gpgv_keywords "${KEYS}/expired.gpg")" == *" EXPKEYSIG "* ]]; then
    expect 1 "signed, before its expiry, by a key the keyring holds as expired" ai_tools_assets_verify__verify_set "${SET}" acme
    assert_msg MSG-T3M3 "${err}" "a signature by an expired key is reported under MSG-T3M3"
    if [[ "${err}" == *"expired or revoked"* ]]; then pass "the refusal names the key as expired or revoked"; else fail "the refusal does not name the expired key: ${err}"; fi
else
    fail "setup: gpgv does not report EXPKEYSIG for the key made under faked-system-time with a one-day expiry"
fi
gen_key REVOKED revoked
write_set; sign_set revoked
if asset_signing_revoke_key revoked "${REVOKED}"; then
    write_binding acme "${KEYS}/revoked.gpg" "openpgp:${REVOKED}"
    if [[ " $(gpgv_keywords "${KEYS}/revoked.gpg")" == *" REVKEYSIG "* ]]; then
        expect 1 "signed by a key the keyring holds as revoked" ai_tools_assets_verify__verify_set "${SET}" acme
        assert_msg MSG-T3M3 "${err}" "a signature by a revoked key is reported under MSG-T3M3"
    else
        fail "setup: gpgv does not report REVKEYSIG once the revocation is in the keyring"
    fi
else
    fail "setup: gpg wrote no revocation certificate for the key it made"
fi
gen_key EXPSIG expsig never 20200101T000000
write_set; sign_set expsig --default-sig-expire 1d
write_binding acme "${KEYS}/expsig.gpg" "openpgp:${EXPSIG}"
if [[ " $(gpgv_keywords "${KEYS}/expsig.gpg")" == *" EXPSIG "* ]]; then
    expect 1 "an expired signature by a key that does not expire" ai_tools_assets_verify__verify_set "${SET}" acme
else
    fail "setup: gpgv does not report EXPSIG for a one-day signature made under faked-system-time"
fi
# Two binary detached signatures in one file, which gpgv reads without armor: the signer's and the other key's.
write_set
GNUPGHOME="${KEYS}/gnupg-signer" gpg --batch --quiet --detach-sign --output "${TESTDIR}/signer.sig" "${SET}/SHA256SUMS"
GNUPGHOME="${KEYS}/gnupg-other" gpg --batch --quiet --detach-sign --output "${TESTDIR}/other.sig" "${SET}/SHA256SUMS"
cat "${TESTDIR}/signer.sig" "${TESTDIR}/other.sig" > "${SET}/SHA256SUMS.asc"; chmod 0644 "${SET}/SHA256SUMS.asc"
write_binding acme "${KEYS}/both.gpg" "openpgp:${SIGNER}" "openpgp:${OTHER}"
if [[ "$(gpgv_keywords "${KEYS}/both.gpg" | tr ' ' '\n' | grep -c '^NEWSIG$')" == 2 ]]; then
    expect 2 "a signature file holding two signatures, both by keys the binding names" ai_tools_assets_verify__verify_set "${SET}" acme
    assert_msg MSG-Q6Y8 "${err}" "a second signature is reported under MSG-Q6Y8"
else
    fail "setup: gpgv does not read two signatures from the concatenated file"
fi
# The signer's signature followed by a copy with its last byte flipped: the mismatch decides, whatever signature
# precedes it.
python3 -I -c 'import sys
signature = bytearray(open(sys.argv[1], "rb").read()); signature[-1] ^= 0x01
open(sys.argv[2], "wb").write(signature)' "${TESTDIR}/signer.sig" "${TESTDIR}/signer-flipped.sig"
cat "${TESTDIR}/signer.sig" "${TESTDIR}/signer-flipped.sig" > "${SET}/SHA256SUMS.asc"; chmod 0644 "${SET}/SHA256SUMS.asc"
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
keywords="$(gpgv_keywords "${KEYS}/signer.gpg")"
if [[ " ${keywords}" == *" BADSIG "* && "$(tr ' ' '\n' <<< "${keywords}" | grep -c '^NEWSIG$')" == 2 ]]; then
    expect 1 "a signature file holding the signer's signature, then one that does not match" \
        ai_tools_assets_verify__verify_set "${SET}" acme
    assert_msg MSG-T3M3 "${err}" "a mismatch after a good signature is reported under MSG-T3M3"
else
    fail "setup: gpgv does not report two signatures and a BADSIG for the good-then-flipped file: ${keywords}"
fi
write_set; sign_set signer
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
expect 0 "control: the set verifies again once signed once by its key" ai_tools_assets_verify__verify_set "${SET}" acme

# A binding refused at a later line publishes neither output. The reader runs in this shell, not under `expect`,
# whose capture is a subshell that would leave the outputs of the last read made here in place.
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}" "not-a-signer"
read_status=0; ai_tools_assets_verify__read_binding acme 2>/dev/null || read_status=$?
if [[ "${read_status}" == 2 ]]; then pass "a binding whose second signer is invalid -> 2"; else fail "a binding whose second signer is invalid -> ${read_status}, want 2"; fi
if (( ${#_AI_TOOLS_ASSETS_VERIFY__SIGNERS[@]} == 0 )) && [[ -z "${_AI_TOOLS_ASSETS_VERIFY__KEYRING}" ]]; then
    pass "a refused binding leaves the signers and the keyring empty"
else
    fail "a refused binding published ${#_AI_TOOLS_ASSETS_VERIFY__SIGNERS[@]} signer(s) and keyring '${_AI_TOOLS_ASSETS_VERIFY__KEYRING}'"
fi
write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"

# ── The operator's bindings ──────────────────────────────────────────────────────────────────────
# A set name that has no shipped binding is the operator's to bind under AI_TOOLS_ASSETS_OPERATOR_BINDINGS_DIR;
# a shipped name is decided by the shipped file whatever lies beside it there, and the operator directory is held
# to the trust predicate only where its file is the one that decides.
write_set; sign_set signer
ASSET_BINDINGS_DIR="${OPERATOR_BINDINGS}" asset_signing_write_binding acme-op "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
found="$(ai_tools_assets_verify__find_binding acme-op)" || found=""
if [[ "${found}" == "${OPERATOR_BINDINGS}/acme-op.conf" ]]; then pass "find_binding: a name the shipped directory does not bind is found in the operator directory"; else fail "find_binding acme-op -> '${found}'"; fi
found="$(ai_tools_assets_verify__find_binding acme)" || found=""
if [[ "${found}" == "${BINDINGS}/acme.conf" ]]; then pass "find_binding: a shipped name is found in the shipped directory"; else fail "find_binding acme -> '${found}'"; fi
if found="$(ai_tools_assets_verify__find_binding nobinding)"; then fail "find_binding nobinding -> 0 with '${found}'"; else pass "find_binding: a name bound nowhere -> 1"; fi
expect 0 "a signed set verifies under its operator binding" ai_tools_assets_verify__verify_set "${SET}" acme-op
if [[ "${out}" == "${SIGNER}" ]]; then pass "the operator-bound set prints its signer's primary"; else fail "the operator-bound set printed '${out}'"; fi
ASSET_BINDINGS_DIR="${OPERATOR_BINDINGS}" asset_signing_write_binding acme "${KEYS}/other.gpg" "openpgp:${OTHER}"
read_status=0; ai_tools_assets_verify__read_binding acme 2>/dev/null || read_status=$?
if [[ "${read_status}" == 0 && " ${_AI_TOOLS_ASSETS_VERIFY__SIGNERS[*]} " == *" ${SIGNER} "* && " ${_AI_TOOLS_ASSETS_VERIFY__SIGNERS[*]} " != *" ${OTHER} "* ]]; then
    pass "a shipped name is decided by the shipped binding; the operator file beside it is not read"
else
    fail "a shipped name with an operator file beside it -> ${read_status}, signers '${_AI_TOOLS_ASSETS_VERIFY__SIGNERS[*]}'"
fi
rm -f "${OPERATOR_BINDINGS}/acme.conf"
chmod 0775 "${OPERATOR_BINDINGS}"
expect 2 "an operator-bound name under a group-writable operator directory" ai_tools_assets_verify__verify_set "${SET}" acme-op
assert_msg MSG-Q6Y8 "${err}" "the untrusted operator directory is reported under MSG-Q6Y8"
if [[ "${err}" == *"operator bindings directory ${OPERATOR_BINDINGS}"* ]]; then pass "the refusal names the operator directory"; else fail "the refusal does not name the operator directory: $(head -c 200 <<<"${err}")"; fi
expect 0 "a shipped name is unaffected by the untrusted operator directory" ai_tools_assets_verify__verify_set "${SET}" acme
chmod 0755 "${OPERATOR_BINDINGS}"
mv "${OPERATOR_BINDINGS}" "${OPERATOR_BINDINGS}.away"
expect 2 "an operator-bound name with no operator directory" ai_tools_assets_verify__verify_set "${SET}" acme-op
if [[ "${err}" == *"no binding under ${BINDINGS} or ${OPERATOR_BINDINGS}"* ]]; then pass "the refusal names both directories"; else fail "the refusal does not name both directories: $(head -c 200 <<<"${err}")"; fi
mv "${OPERATOR_BINDINGS}.away" "${OPERATOR_BINDINGS}"
rm -f "${OPERATOR_BINDINGS}/acme-op.conf"

# The walk's own status: an enumeration that ends early leaves a tree whose listed files match and whose unlisted ones
# were never seen, so a walk that did not complete is unverifiable. Driven by a find that prints its listing and then
# fails (a shell function in the inner shell, which a subshell inherits and a noexec /tmp cannot stop), and by a subtree
# the projects user cannot enter, which root walks through.
write_set; sign_set signer
# shellcheck disable=SC2016  # the inner shell expands $1 and $2 from the arguments after `_`
expect 2 "a walk that fails after printing its listing" /bin/bash -c 'source "$1"; find() { /usr/bin/find "$@"; return 1; }; ai_tools_assets_verify__verify_inventory "$2"' _ "${LIB}" "${SET}"
assert_msg MSG-Q6Y8 "${err}" "an incomplete walk is reported under MSG-Q6Y8"
mkdir "${SET}/skills/acme-pdf/hidden"; printf 'unlisted\n' > "${SET}/skills/acme-pdf/hidden/extra.md"; chmod 0300 "${SET}/skills/acme-pdf/hidden"
# shellcheck disable=SC2016
expect 2 "a subtree the walking account cannot enter, as the projects user" runuser -u "${PROJECTS_USER}" -- /bin/bash -c 'source "$1"; ai_tools_assets_verify__verify_inventory "$2"' _ "${LIB}" "${SET}"
chmod 0755 "${SET}/skills/acme-pdf/hidden"
expect 1 "the same subtree walked by root is an unlisted file" ai_tools_assets_verify__verify_inventory "${SET}"

# The bounds: a file over the per-file bound is not hashed.
write_set; head -c $(( AI_TOOLS_ASSETS_VERIFY__FILE_MAX_BYTES + 1 )) /dev/zero > "${SET}/skills/acme-pdf/large.bin"; write_inventory; sign_set signer
expect 2 "a file over the per-file bound, listed with a matching hash" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'x\n' > "${SET}/skills/acme-pdf/windows\\paths.md"; write_inventory; sign_set signer
expect 1 "a file name holding a backslash, which the inventory cannot list" ai_tools_assets_verify__verify_set "${SET}" acme
if grep -q "is not a relative path inside the set" <<<"${err}"; then pass "the backslash is refused at the path, not the digest"; else fail "the backslash case refused elsewhere: $(head -c 200 <<<"${err}")"; fi

# Each record of the walk is read whole: a name opening with a tab is not read as another file's, and a name is met
# once. The replacement keeps the inventory and the count: a file removed, a file named <tab><that name> added.
write_set; sign_set signer
rm "${SET}/agents/acme-reviewer.md"; printf 'replaced\n' > "${SET}/agents/$(printf '\t')acme-reviewer.md"
expect 1 "a removed file replaced by one whose name opens with a tab" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'x\n' > "${SET}/agents/trailing$(printf '\t')"; write_inventory; sign_set signer
expect 1 "a file name holding a tab" ai_tools_assets_verify__verify_set "${SET}" acme

# A path is read under the portable file-name predicate on both sides: a name outside it is refused whether
# the inventory lists it (signed, so a mismatch at the listing) or the walk alone finds it.
write_set; printf 'x\n' > "${SET}/agents/with space.md"; write_inventory; sign_set signer
expect 1 "a file name holding a space" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'x\n' > "${SET}/agents/r$(printf '\303\251')sum$(printf '\303\251').md"; write_inventory; sign_set signer
expect 1 "a file name holding a byte outside ASCII" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'x\n' > "${SET}/agents/-flag.md"; write_inventory; sign_set signer
expect 1 "a file name opening with a hyphen" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; printf 'x\n' > "${SET}/agents/a_b.c-d.v2.md"; write_inventory; sign_set signer
expect 0 "a file name of letters, digits, dots, underscores and inner hyphens" ai_tools_assets_verify__verify_set "${SET}" acme
write_set; sign_set signer; rm "${SET}/agents/acme-reviewer.md"; printf 'x\n' > "${SET}/agents/acme-reviewer.md*"
expect 1 "an unlisted file whose name holds a glob character is a mismatch, not a match" ai_tools_assets_verify__verify_set "${SET}" acme
if grep -q "outside the portable set" <<<"${err}"; then pass "the glob name is refused at the name"; else fail "the glob name refused elsewhere: $(head -c 200 <<<"${err}")"; fi
# A literal $'\n': a command substitution drops a trailing newline, so `$(printf '\n')` would name a file without one.
write_set; sign_set signer; rm "${SET}/agents/acme-reviewer.md"; printf 'x\n' > "${SET}/agents/acme-reviewer.md"$'\n'"x"
expect 1 "an unlisted file whose name holds a newline, which the walk alone can name" ai_tools_assets_verify__verify_set "${SET}" acme
if grep -q "outside the portable set" <<<"${err}"; then pass "the newline name is refused at the name"; else fail "the newline name refused elsewhere: $(head -c 200 <<<"${err}")"; fi

# The caller's RETURN trap survives a check, on success and on a refusal after the walk's file exists: the trap standing
# afterwards is the caller's own, which a trap set inside a function leaves in the shell, and never the walk file's
# removal.
caller_with_trap() { trap 'printf caller-cleanup-ran' RETURN; ai_tools_assets_verify__verify_inventory "${SET}"; }
write_set; sign_set signer
if [[ "$(caller_with_trap 2>/dev/null)" == "caller-cleanup-ran" && "$(trap -p RETURN)" != *"rm -f"* ]]; then
    pass "a caller's RETURN trap runs after a successful check and is not replaced"
else
    fail "a caller's RETURN trap was lost after a successful check: $(trap -p RETURN)"
fi
trap - RETURN
printf 'unlisted\n' > "${SET}/agents/extra.md"
if [[ "$(caller_with_trap 2>/dev/null)" == "caller-cleanup-ran" && "$(trap -p RETURN)" != *"rm -f"* ]]; then
    pass "a caller's RETURN trap runs after a refused check and is not replaced"
else
    fail "a caller's RETURN trap was lost after a refused check: $(trap -p RETURN)"
fi
trap - RETURN

# gpgv absent: a PATH holding every tool the verifier runs except gpgv; bash is named by its absolute path, since
# the restricted PATH cannot resolve it.
mkdir -p "${TESTDIR}/bin"
for tool in sha256sum find stat awk base64 head mktemp rm; do ln -s "$(command -v "${tool}")" "${TESTDIR}/bin/${tool}"; done
# shellcheck disable=SC2016  # the inner shell expands $1 and $2 from the arguments after `_`
expect 2 "gpgv absent from PATH" env PATH="${TESTDIR}/bin" /bin/bash -c 'source "$1"; ai_tools_assets_verify__verify_set "$2" acme' _ "${LIB}" "${SET}"
assert_msg MSG-Q6Y8 "${err}" "an absent gpgv is reported under MSG-Q6Y8"
if grep -q "gpgv not found" <<<"${err}"; then pass "the diagnostic names gpgv"; else fail "the diagnostic does not name gpgv: $(head -c 200 <<<"${err}")"; fi

finish
