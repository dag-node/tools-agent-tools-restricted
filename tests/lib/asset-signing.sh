#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/asset-signing.sh
# The signing recipe the asset tests share, so no signed fixture is committed: a throwaway key made in the run, a set's
# inventory written in build-set's shape, a detached armored signature over it as release-steps.sh makes one,
# and a binding naming the key. gpg makes the keys and the signatures; gpgv alone verifies, as on a host. Sourced
# after harness.sh and the set verifier (whose ai_tools_assets_write_binary_keyring writes each keyring)
# by tests/unit/assets-verify.sh, tests/unit/assets.sh and tests/unit/admin-assets.sh. The caller sets ASSET_KEYS_DIR
# (each key's armored export and keyring, and its GNUPGHOME beside them) and ASSET_BINDINGS_DIR, both root-owned 0755,
# before the first call; every file written here is 0644.

# asset_signing_gen_key <var> <name> : make a throwaway key <name> in its own GNUPGHOME, write its armored public key
# and the binary keyring gpgv reads as <name>.asc and <name>.gpg, and assign its primary fingerprint to <var>.
asset_signing_gen_key() {
    local -n _asset_signing_fpr="$1"
    local name="$2" home="${ASSET_KEYS_DIR}/gnupg-$2"
    mkdir -p "${home}"; chmod 0700 "${home}"
    GNUPGHOME="${home}" gpg --batch --quiet --passphrase '' --quick-gen-key "ai-tools test ${name} <${name}@acme.example>" \
        default default never 2>/dev/null
    _asset_signing_fpr="$(GNUPGHOME="${home}" gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    GNUPGHOME="${home}" gpg --batch --armor --export "${_asset_signing_fpr}" > "${ASSET_KEYS_DIR}/${name}.asc"
    ai_tools_assets_write_binary_keyring "${ASSET_KEYS_DIR}/${name}.asc" "${ASSET_KEYS_DIR}/${name}.gpg"
    chmod 0644 "${ASSET_KEYS_DIR}/${name}.asc" "${ASSET_KEYS_DIR}/${name}.gpg"
}

# asset_signing_write_inventory <set-dir> : SHA256SUMS as build-set writes it, every file but the inventory and its
# signature, relative paths in byte order, two spaces. Each file is hashed through stdin: given a name, sha256sum
# escapes a backslash and opens the line with one, which the producer does not.
asset_signing_write_inventory() {
    local set_dir="$1" file digest
    rm -f "${set_dir}/SHA256SUMS"
    while IFS= read -r file; do
        digest="$(sha256sum < "${set_dir}/${file}" | cut -c1-64)"
        printf '%s  %s\n' "${digest}" "${file}"
    done < <(cd "${set_dir}" && find . -mindepth 1 ! -type d ! -name SHA256SUMS ! -name SHA256SUMS.asc -printf '%P\n' | LC_ALL=C sort) \
        > "${set_dir}/SHA256SUMS"
    chmod 0644 "${set_dir}/SHA256SUMS"
}

# asset_signing_sign <set-dir> <key-name> : sign the set's inventory with the key <key-name>, armored and detached.
asset_signing_sign() {
    rm -f "$1/SHA256SUMS.asc"
    GNUPGHOME="${ASSET_KEYS_DIR}/gnupg-$2" gpg --batch --quiet --armor --detach-sign --output "$1/SHA256SUMS.asc" "$1/SHA256SUMS"
    chmod 0644 "$1/SHA256SUMS.asc"
}

# asset_signing_write_binding <set> <keyring-file> <signer>... : a binding naming the keyring and the signers,
# root-owned 0644 in ASSET_BINDINGS_DIR.
asset_signing_write_binding() {
    local set_name="$1" keyring="$2" signers="" item
    shift 2
    for item in "$@"; do signers+="${signers:+, }${item}"; done
    printf 'set=%s\nsigners=[%s]\nkeyring=%s\n' "${set_name}" "${signers}" "${keyring}" > "${ASSET_BINDINGS_DIR}/${set_name}.conf"
    chown root:root "${ASSET_BINDINGS_DIR}/${set_name}.conf"
    chmod 0644 "${ASSET_BINDINGS_DIR}/${set_name}.conf"
}
