#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/generators/typesafe-client.sh -- vendor the typesafe integration's decide command from a signed release
# of dag-node/typesafe-client-js. The committed src/usr/local/lib/ai-tools/typesafe/*.mjs are that release's dist/
# modules, unmodified, beside the LICENSE and CHANGELOG.md the release tarball carries with them,
# and tools/generators/typesafe-client.pin records which release they are: the tag, the commit it names, the release
# tarball's sha256, and each vendored file's sha256.
#
#     bash tools/generators/typesafe-client.sh generate <tag>   fetch and verify the release, replace the modules,
#                                                               rewrite the pin
#     bash tools/generators/typesafe-client.sh verify           fetch the pinned release again and exit 1 unless it
#                                                               verifies and matches the pin (network; CI runs it)
#     bash tools/generators/typesafe-client.sh stale            exit 1 when the committed modules differ from the
#                                                               pin (offline; the unit suite runs it)
#
# A release verifies when the tarball matches the sha256 the release publishes, its detached signature is made by a key
# whose primary fingerprint is ASSET_SIGNING_PRIMARY_FPR, and the tag is an annotated tag signed by a key whose primary
# fingerprint is TAG_SIGNING_PRIMARY_FPR. The fingerprints are the trust anchors; the key URLs are transport, so a key
# served from a compromised account does not match. The pin is matched against the primary rather than the signing
# subkey, so rotating a subkey leaves this file alone. The client's release job verifies the tag before it signs
# the tarball, and the tag check here repeats that against the tag author's key, so a pinned commit does not rest
# on the org key alone.
#
# `stale` alone cannot tell a hand-edited module from a hand-edited pin committed with it; `verify` can, because it
# re-derives every hash from the signed release. Signatures are checked with gpgv, which verifies and does not read
# a secret key or an agent, against a keyring built from the fetched key for the one call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="tools/generators/typesafe-client.pin"
DEST="src/usr/local/lib/ai-tools/typesafe"
REPO_URL="https://github.com/dag-node/typesafe-client-js"
ASSET_SIGNING_PRIMARY_FPR="67F42DC18BF764B42D82F14256D2F802CF9832E4"   # DagNode Package Signing
ASSET_SIGNING_KEY_URL="https://rpm.dagnode.com/RPM-GPG-KEY-dag-node"
TAG_SIGNING_PRIMARY_FPR="225DFF22D0221D3DD68CCEFFFABAF500E7D90733"     # the client's release tags
TAG_SIGNING_KEY_URL="https://github.com/p4nda.gpg"
# The files a release tarball carries beside its modules, vendored with them: MIT requires the notice to travel
# with the code it covers.
NOTICES=(LICENSE CHANGELOG.md)
cd "${ROOT}"

die() { printf 'typesafe-client: %s\n' "$*" >&2; exit 1; }

# pin_value <key>: print the value of `<key>=` in the pin; exit 1 when the pin does not carry it.
pin_value() {
    local line
    line="$(grep -E "^$1=" "${PIN}")" || die "${PIN} does not carry $1"
    printf '%s\n' "${line#*=}"
}

# pin_files: print the pin's file lines as `<sha256>  <name>`, the form `sha256sum --check` reads.
pin_files() {
    sed -n 's/^file=\([0-9a-f]\{64\}\) \([a-z]*\.mjs\|LICENSE\|CHANGELOG\.md\)$/\1  \2/p' "${PIN}"
}

# keyring <url> <out>: fetch an ASCII-armored key and write it as the binary keyring gpgv reads.
keyring() {
    curl -fsSL --proto '=https' "$1" | python3 -c '
import base64, re, sys
armored = sys.stdin.read()
blocks = re.findall(r"-----BEGIN PGP PUBLIC KEY BLOCK-----\n(.*?)-----END PGP PUBLIC KEY BLOCK-----", armored, re.S)
if not blocks:
    sys.exit("no public key block")
out = bytearray()
for block in blocks:
    body = block.split("\n\n", 1)[1] if "\n\n" in block else block
    out += base64.b64decode("".join(l for l in body.split() if not l.startswith("=")))
sys.stdout.buffer.write(out)
' >"$2" || die "cannot read a public key from $1"
}

# signed_by <keyring> <primary-fpr> <sig> <data>: exit 0 when gpgv reports a valid signature over <data> by a key
# whose primary fingerprint is <primary-fpr>, the last field of gpgv's VALIDSIG status line.
signed_by() {
    local status
    status="$(gpgv --status-fd 1 --keyring "$1" "$3" "$4" 2>/dev/null)" || return 1
    grep -qE "^\[GNUPG:\] VALIDSIG .* $2$" <<<"${status}"
}

# fetch_release <tag> <workdir>: download and verify the release, unpack it into <workdir>/dist, and print
# `commit=<sha>` and `asset_sha256=<hex>` for the pin.
fetch_release() {
    local tag="$1" work="$2" asset sum commit
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'${tag}' is not a release tag (vX.Y.Z)"
    asset="typesafe-client-js-dist-${tag}.tar.gz"
    for f in "${asset}" "${asset}.sha256" "${asset}.asc"; do
        curl -fsSL --proto '=https' -o "${work}/${f}" "${REPO_URL}/releases/download/${tag}/${f}" \
            || die "cannot download ${f} from the ${tag} release"
    done
    (cd "${work}" && sha256sum --quiet --check "${asset}.sha256") \
        || die "${asset} does not match the sha256 the release publishes"

    keyring "${ASSET_SIGNING_KEY_URL}" "${work}/asset-key.gpg"
    signed_by "${work}/asset-key.gpg" "${ASSET_SIGNING_PRIMARY_FPR}" "${work}/${asset}.asc" "${work}/${asset}" \
        || die "${asset} is not signed by ${ASSET_SIGNING_PRIMARY_FPR}"

    git init --quiet --bare "${work}/tag.git"
    git -C "${work}/tag.git" fetch --quiet --depth=1 --no-tags "${REPO_URL}" "+refs/tags/${tag}:refs/tags/${tag}" \
        || die "cannot fetch tag ${tag} from ${REPO_URL}"
    git -C "${work}/tag.git" cat-file tag "${tag}" >"${work}/tag.raw" 2>/dev/null \
        || die "${tag} is not an annotated tag, so it carries no signature"
    python3 - "${work}/tag.raw" <<'PY' || die "${tag} carries no signature"
import sys
raw = open(sys.argv[1], "rb").read()
marker = b"-----BEGIN PGP SIGNATURE-----"
if marker not in raw:
    sys.exit(1)
cut = raw.index(marker)
open(sys.argv[1] + ".payload", "wb").write(raw[:cut])
open(sys.argv[1] + ".sig", "wb").write(raw[cut:])
PY
    keyring "${TAG_SIGNING_KEY_URL}" "${work}/tag-key.gpg"
    signed_by "${work}/tag-key.gpg" "${TAG_SIGNING_PRIMARY_FPR}" "${work}/tag.raw.sig" "${work}/tag.raw.payload" \
        || die "tag ${tag} is not signed by ${TAG_SIGNING_PRIMARY_FPR}"
    commit="$(sed -n 's/^object \([0-9a-f]\{40\}\)$/\1/p' "${work}/tag.raw.payload")"
    [[ -n "${commit}" ]] || die "tag ${tag} does not name a commit"

    mkdir "${work}/dist"
    tar -xzf "${work}/${asset}" -C "${work}/dist" --no-same-owner --no-same-permissions
    compgen -G "${work}/dist/*.mjs" >/dev/null || die "${asset} does not hold any .mjs module"
    for f in "${NOTICES[@]}"; do
        [[ -f "${work}/dist/${f}" ]] || die "${asset} does not carry ${f}"
    done
    sum="$(sha256sum "${work}/${asset}")"
    printf 'commit=%s\nasset_sha256=%s\n' "${commit}" "${sum%% *}"
}

# vendored_lines <dir>: print a `file=<sha256> <name>` line per .mjs module and notice in <dir>, sorted by name.
vendored_lines() {
    (cd "$1" && sha256sum -- *.mjs "${NOTICES[@]}") | LC_ALL=C sort -k2 | sed 's/^\([0-9a-f]*\)  /file=\1 /'
}

# check_stale: exit 1 unless the committed files are exactly the ones the pin lists, each with its pinned sha256.
check_stale() {
    local listed committed
    listed="$(pin_files)"
    [[ -n "${listed}" ]] || die "${PIN} lists no file"
    committed="$(cd "${DEST}" && ls -- *.mjs "${NOTICES[@]}" 2>/dev/null | LC_ALL=C sort)"
    [[ "${committed}" == "$(awk '{print $2}' <<<"${listed}" | LC_ALL=C sort)" ]] \
        || die "${DEST} holds a different set of files than ${PIN} lists -- run generate, never edit a vendored file"
    (cd "${DEST}" && sha256sum --quiet --check --strict <<<"${listed}") >/dev/null 2>&1 \
        || die "a file in ${DEST} differs from ${PIN} -- run generate, never edit a vendored file"
}

case "${1:-}" in
    generate)
        tag="${2:-}"; [[ -n "${tag}" ]] || die "usage: bash ${PIN%.pin}.sh generate <tag>"
        work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
        release="$(fetch_release "${tag}" "${work}")"
        (cd "${DEST}" && rm -f -- *.mjs "${NOTICES[@]}")
        (cd "${work}/dist" && install -m 0644 -- *.mjs "${NOTICES[@]}" "${ROOT}/${DEST}/")
        {
            printf '# Written by tools/generators/typesafe-client.sh generate -- do not edit.\n'
            printf '# The release the files under %s are vendored from.\n' "${DEST}"
            printf 'tag=%s\n%s\n' "${tag}" "${release}"
            vendored_lines "${work}/dist"
        } >"${PIN}"
        echo "typesafe-client: vendored ${tag} into ${DEST}"
        ;;
    verify)
        tag="$(pin_value tag)"
        work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
        release="$(fetch_release "${tag}" "${work}")"
        [[ "${release}" == "commit=$(pin_value commit)"$'\n'"asset_sha256=$(pin_value asset_sha256)" ]] \
            || die "the ${tag} release does not match ${PIN}: $(tr '\n' ' ' <<<"${release}")"
        [[ "$(vendored_lines "${work}/dist")" == "$(grep '^file=' "${PIN}")" ]] \
            || die "the ${tag} release's files differ from the ones ${PIN} lists"
        check_stale
        echo "typesafe-client: ${tag} verifies, and ${DEST} and ${PIN} match it"
        ;;
    stale)
        check_stale
        ;;
    *)
        echo "usage: bash tools/generators/typesafe-client.sh generate <tag>|verify|stale" >&2
        exit 2
        ;;
esac
