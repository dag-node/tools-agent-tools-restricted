#!/usr/bin/env bash
# Sign release RPMs with the dag-node org signing key and export the matching public key.
# Runs INSIDE the matching-EL build container (ai-tools-rpmbase:elN) so the rpm/gnupg
# toolchain that signs is the same one that built the packages -- see the org playbook in
# github-org-dag-node/GPG-HINTS.md and docs/rpm-packaging.md. The release workflow invokes
# it over the freshly built RPMs before publishing, so every published package carries a
# header signature an operator verifies with `rpm --import RPM-GPG-KEY-dag-node`.
#
# Usage (rpm-sign + gnupg2 + rpm-build must be present in the container):
#   packaging/sign-rpms.sh <pubkey-out-path> <rpm>...   sign and verify the given RPMs
#   packaging/sign-rpms.sh --selftest                   prove the whole chain on a throwaway RPM
#
# --selftest builds a disposable package, signs it, and verifies it through the identical code
# path, so the release workflow can prove the key, passphrase, rpmsign, and verification all
# work in this exact container BEFORE any real RPM is built or published. It leaves nothing
# behind.
#
# Environment (from the dag-node org CI secrets):
#   GPG_SIGNING_KEY         ASCII-armored private signing key           (required)
#   GPG_SIGNING_PASSPHRASE  its passphrase                              (required; org key has one)
#
# Fail-closed: a missing key or passphrase, a signing failure, or an RPM that does not carry a
# signature that verifies exits non-zero, so a release never publishes an unsigned or wrongly
# signed package. Verification asserts a cryptographic signature LINE validates -- `rpmkeys
# --checksig` exits 0 for an unsigned package (nothing to fail), so a return-code-only test
# passes a silent rpmsign no-op; the 0.6.1 assets shipped unsigned that way. Errors use the
# ::error:: prefix so GitHub Actions surfaces them as annotations; the text reads plainly on a
# local terminal too. Every secret (imported private key, passphrase) lives in a tmpfs (RAM)
# scratch tree wiped on exit -- never persistent disk, never the container's real keyring or
# rpmdb.
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
#
# %{__gpg} is the ONLY binary token. rpm's stock %__gpg_sign_cmd is `%{__gpg} gpg ...`, which on
# EL10 (where %__gpg is defined as /usr/bin/gpg) expands to `/usr/bin/gpg gpg ...` -- gpg invoked
# with argv[1]="gpg", a bogus input filename, so it signs nothing. Copying that literal `gpg`
# into the override is why the 0.6.1 el10 RPMs shipped unsigned; here %{__gpg} stands alone.
write_rpm_macros() {
    local home="$1" fpr="$2" passfile="$3"
    cat > "${home}/.rpmmacros" <<EOF
%_gpg_name ${fpr}
%__gpg_sign_cmd %{__gpg} --batch --no-verbose --no-armor --pinentry-mode loopback --passphrase-file ${passfile} --digest-algo sha256 -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
EOF
}

# Verify each RPM carries a signature that validates against <pubkey>. Import the key into a
# throwaway rpmdb, then require `rpmkeys -Kv` to print a cryptographic "Signature ... OK" line:
# that line appears ONLY when a signature is present AND checks out. An unsigned package has no
# signature line (only digests) yet still exits 0, so asserting the line -- not the exit code --
# is what stops a silent signing no-op from shipping.
verify_signatures() {
    local pubkey="$1"; shift
    local verifydb rpm out
    verifydb="$(mktemp -d)"
    rpmkeys --dbpath "${verifydb}" --import "${pubkey}" \
        || die "could not import the exported public key for verification"
    for rpm in "$@"; do
        # A non-zero exit means a signature is present but BAD/NOKEY; the grep afterwards catches
        # the unsigned case, which exits 0 with no signature line.
        out="$(rpmkeys --dbpath "${verifydb}" -Kv "${rpm}" 2>&1)" \
            || die "signature check failed for ${rpm}: ${out}"
        grep -Eqi 'signature[^:]*:[[:space:]]*OK' <<<"${out}" \
            || die "no valid signature on ${rpm} -- rpmsign produced an unsigned or unverifiable package"
    done
}

# Sign the given RPMs with the already-imported key + macros, export the public key to
# <pubkey_out>, and verify every signature. Assumes GNUPGHOME/HOME/.rpmmacros are set up.
sign_and_verify() {
    local pubkey_out="$1"; shift
    rpmsign --addsign "$@" || die "rpmsign failed"
    gpg --batch --armor --export "${SIGNER_FPR}" > "${pubkey_out}" \
        || die "could not export the public key"
    verify_signatures "${pubkey_out}" "$@"
}

# Build a disposable noarch RPM under <dir> and echo its path. Used by --selftest to exercise the
# real sign+verify path without touching a release artifact.
build_selftest_rpm() {
    local dir="$1"
    command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild not found (install rpm-build) -- needed for --selftest"
    install -d "${dir}"
    cat > "${dir}/selftest.spec" <<'EOF'
Name: ai-tools-sign-selftest
Version: 0
Release: 0
Summary: throwaway package proving the release signing chain end-to-end
License: AGPL-3.0-or-later
BuildArch: noarch
%description
Built and discarded by sign-rpms.sh --selftest to prove that the signing key, its passphrase,
rpmsign, and signature verification all work before any real release RPM is signed.
%files
EOF
    rpmbuild --define "_topdir ${dir}/rpmbuild" -bb "${dir}/selftest.spec" >/dev/null 2>&1 \
        || die "could not build the selftest RPM"
    # Exactly one spec is built into a fresh _topdir, so this names the single resulting RPM.
    find "${dir}/rpmbuild/RPMS" -name '*.rpm'
}

main() {
    local selftest=0
    if [[ "${1:-}" == --selftest ]]; then
        selftest=1; shift
    fi

    local pubkey_out=""
    if (( ! selftest )); then
        pubkey_out="${1:-}"
        shift || true
        [[ -n "${pubkey_out}" ]] || die "usage: sign-rpms.sh <pubkey-out-path> <rpm>...  |  sign-rpms.sh --selftest"
        [[ "$#" -ge 1 ]]         || die "no RPMs given to sign"
    fi

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
    # as the unavoidable keyring adds no disk exposure. The runner VM is ephemeral.
    # Script-global, not local: the EXIT trap fires after main returns, where a local is out of
    # scope -- an unbound reference under set -u -- and the wipe must still run.
    workdir="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)"
    trap 'rm -rf "${workdir}"' EXIT

    SIGNER_FPR="$(import_signing_key "${workdir}/gnupg")"
    export GNUPGHOME="${workdir}/gnupg"

    local passfile="${workdir}/passphrase"
    ( umask 077; printf '%s' "${GPG_SIGNING_PASSPHRASE}" > "${passfile}" )
    write_rpm_macros "${workdir}" "${SIGNER_FPR}" "${passfile}"
    export HOME="${workdir}"   # rpm reads ~/.rpmmacros; point HOME at the scratch tree

    if (( selftest )); then
        local rpm
        rpm="$(build_selftest_rpm "${workdir}/selftest")"
        [[ -n "${rpm}" ]] || die "selftest RPM was not produced"
        sign_and_verify "${workdir}/selftest.pub" "${rpm}"
        echo "sign-rpms: --selftest OK -- key ${SIGNER_FPR} signs and verifies in this container"
        return 0
    fi

    sign_and_verify "${pubkey_out}" "$@"
    echo "sign-rpms: signed and verified $# RPM(s) with key ${SIGNER_FPR}; public key at ${pubkey_out}"
}

main "$@"
