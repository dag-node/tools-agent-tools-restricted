#!/usr/bin/env bash
# Sign release RPMs with the dag-node org signing key and export the matching public key.
# Runs INSIDE the matching-EL build container (ai-tools-rpmbase:elN) so the rpm/gnupg
# toolchain that signs is the same one that built the packages -- see the org playbook in
# github-org-dag-node/GPG-HINTS.md and docs/rpm-packaging.md. The release workflow invokes
# it over the freshly built RPMs before publishing, so every published package carries a
# header signature an operator verifies with `rpm --import RPM-GPG-KEY-dag-node` (dropping the
# `--nogpgcheck` install flag).
#
# Usage (rpm-sign + gnupg2 must be present in the container):
#   packaging/sign-rpms.sh <pubkey-out-path> <rpm>...
#
# Environment (from the dag-node org CI secrets):
#   GPG_SIGNING_KEY         ASCII-armored private signing key           (required)
#   GPG_SIGNING_PASSPHRASE  its passphrase                              (required; org key has one)
#
# Fail-closed: a missing key or passphrase, a signing failure, or an RPM that does not verify
# after signing exits non-zero, so a release never publishes an unsigned or wrongly signed
# package. Errors use the ::error:: prefix so GitHub Actions surfaces them as annotations; the
# text reads plainly on a local terminal too. Every secret (imported private key, passphrase)
# lives in a tmpfs (RAM) scratch tree wiped on exit -- never persistent disk, never the
# container's real keyring or rpmdb. All logic is in functions with locals, so nothing leaks
# beyond the GNUPGHOME/HOME the tools require.
set -euo pipefail

err() { echo "::error::sign-rpms: $*" >&2; }
die() { err "$*"; exit 1; }

# Import GPG_SIGNING_KEY into <gnupghome> and echo the signer fingerprint (%_gpg_name).
import_signing_key() {
    local gnupghome="$1" fpr
    install -d -m 0700 "${gnupghome}"
    printf '%s\n' "${GPG_SIGNING_KEY}" \
        | GNUPGHOME="${gnupghome}" gpg --batch --quiet --import \
        || die "could not import GPG_SIGNING_KEY"
    fpr="$(GNUPGHOME="${gnupghome}" gpg --batch --with-colons --list-secret-keys \
            | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ -n "${fpr}" ]] || die "no secret key present after import"
    printf '%s\n' "${fpr}"
}

# Write <home>/.rpmmacros so rpmsign drives gpg non-interactively: loopback pinentry and the
# passphrase from a 0600 file, never argv (world-readable via /proc).
write_rpm_macros() {
    local home="$1" fpr="$2" passfile="$3"
    cat > "${home}/.rpmmacros" <<EOF
%_gpg_name ${fpr}
%__gpg_sign_cmd %{__gpg} gpg --batch --no-verbose --no-armor --pinentry-mode loopback --passphrase-file ${passfile} --digest-algo sha256 -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
EOF
}

# Verify each RPM against a throwaway rpmdb seeded with only <pubkey>; a bad signature is fatal,
# so a silent signing no-op cannot ship.
verify_signatures() {
    local pubkey="$1"; shift
    local verifydb rpm
    verifydb="$(mktemp -d)"
    rpmkeys --dbpath "${verifydb}" --import "${pubkey}" \
        || die "could not import the exported public key for verification"
    for rpm in "$@"; do
        rpmkeys --dbpath "${verifydb}" --checksig "${rpm}" | grep -q ': digests signatures OK' \
            || die "signature verification failed for ${rpm}"
    done
}

main() {
    local pubkey_out="${1:-}"
    shift || true
    [[ -n "${pubkey_out}" ]] || die "usage: sign-rpms.sh <pubkey-out-path> <rpm>..."
    [[ "$#" -ge 1 ]]         || die "no RPMs given to sign"
    [[ -n "${GPG_SIGNING_KEY:-}" ]] \
        || die "GPG_SIGNING_KEY is empty -- set the dag-node org signing key as a CI secret (GPG-HINTS.md)"
    [[ -n "${GPG_SIGNING_PASSPHRASE:-}" ]] \
        || die "GPG_SIGNING_PASSPHRASE is empty -- the org signing key is passphrase-protected (GPG-HINTS.md)"
    command -v gpg     >/dev/null 2>&1 || die "gpg not found (install gnupg2)"
    command -v rpmsign >/dev/null 2>&1 || die "rpmsign not found (install rpm-sign)"
    command -v rpmkeys >/dev/null 2>&1 || die "rpmkeys not found (install rpm-sign)"

    # One scratch tree holds every secret (imported private keyring, passphrase file). Prefer
    # tmpfs (/dev/shm, RAM) so key material never lands on persistent disk; fall back to the
    # default TMPDIR where /dev/shm is absent. gpg needs the private key in a keyring DIRECTORY
    # (it cannot sign from a variable), and rpmsign forks gpg once per package, so the passphrase
    # must stay re-readable here rather than a one-shot stream -- keeping it on the same RAM tree
    # as the unavoidable keyring adds no disk exposure. Wiped on exit; the runner VM is ephemeral.
    local workdir
    workdir="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)"
    trap 'rm -rf "${workdir}"' EXIT

    local fpr
    fpr="$(import_signing_key "${workdir}/gnupg")"
    export GNUPGHOME="${workdir}/gnupg"

    local passfile="${workdir}/passphrase"
    ( umask 077; printf '%s' "${GPG_SIGNING_PASSPHRASE}" > "${passfile}" )
    write_rpm_macros "${workdir}" "${fpr}" "${passfile}"
    export HOME="${workdir}"   # rpm reads ~/.rpmmacros; point HOME at the scratch tree

    rpmsign --addsign "$@" || die "rpmsign failed"
    gpg --batch --armor --export "${fpr}" > "${pubkey_out}" \
        || die "could not export the public key"
    verify_signatures "${pubkey_out}" "$@"

    echo "sign-rpms: signed and verified $# RPM(s) with key ${fpr}; public key at ${pubkey_out}"
}

main "$@"
