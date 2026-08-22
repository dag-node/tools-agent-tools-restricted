#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/entrypoint-verify.lib.sh
# Verify that an agent's entrypoint is the binary its vendor published, and carry that verdict to
# the launch in a record the sandbox account cannot write.
#
# It names no agent: the release manifest, the signing key, and its fingerprint are optional fields
# on the agent's own manifest (providers.rule.md). Why the check exists, which caller runs which
# half, what each outcome means, and where the pin lives are in updater.rule.md; this header covers
# only what a reader of this file needs.
#
# Two entry points, split by principal -- which is what keeps the network off the launch path:
#   ai_tools_entrypoint_release_verify  ROOT. Fetch the vendor's signed release manifest, verify it
#     against the pinned key, and compare the entrypoint's hash to the checksum it publishes.
#   ai_tools_entrypoint_check           SANDBOX. Hash the entrypoint, compare to the pin. No
#     network, no key, no JSON -- it runs on every launch.
# Between them, ai_tools_entrypoint_pin_write records a verified checksum (root only).
#
# Status contract, shared with npm-verify.lib.sh so the two gates in nvm-update read alike:
#   0  verified (or matches its pin)
#   1  MISMATCH -- the caller MUST fail closed
#   2  unable to verify -- NOT a tamper signal; the caller warns, or refuses only where the
#      operator required verification (ai_tools_entrypoint_verify_required)
# The pure decisions take no I/O and are unit-tested over their truth tables
# (tests/unit/entrypoint-verify.sh).

# Include guard: an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and
# trips the sourcing shell's set -e.
if [[ -n "${_AI_TOOLS_ENTRYPOINT_VERIFY_LIB_LOADED:-}" ]]; then
    return 0
fi
_AI_TOOLS_ENTRYPOINT_VERIFY_LIB_LOADED=1

# The shared KEY=value grammar, for the strictness switch and the fingerprint list. Best-effort,
# NOT required: the launch-side check (the hot path) needs neither, and every consumer that does
# has already loaded conf.lib.sh through providers.lib.sh -- so a failure here degrades the two
# functions that use it in their permissive/refusing directions rather than defining nothing. Both
# guard on `declare -F` before calling into it.
# shellcheck source=SCRIPTDIR/conf.lib.sh
source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null || true

# Deployed paths, overridable as root-only test hooks (the same posture as providers.lib.sh's
# manifest directories: every consumer runs under sudo, which scrubs the environment, and no
# sudoers rule keeps these names).
: "${AI_TOOLS_ENTRYPOINT_PIN_DIR:=/var/opt/ai-tools/state/entrypoint-pin.d}"

# _ai_tools_ev_warn <message...> : report to stderr and, when log.lib.sh is loaded by the caller,
#   to journald. Never alters a verdict.
_ai_tools_ev_warn() {
    printf 'entrypoint-verify: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "entrypoint-verify: $*"
    return 0
}

# ── Pure decisions (no I/O, no privilege, no network) ────────────────────────────────────────

# ai_tools_entrypoint_platform_key <machine> [libc] : print the key a vendor release manifest
#   lists this host's binary under, or nothing for an architecture with no mapping. <machine> is
#   uname -m; <libc> is `musl` or empty. Pure, so the mapping is unit-tested without needing the
#   architectures it maps.
ai_tools_entrypoint_platform_key() {
    local machine="${1:-}" libc="${2:-}" arch="" suffix=""
    case "${machine}" in
        x86_64|amd64)  arch=x64   ;;
        aarch64|arm64) arch=arm64 ;;
        *)             return 1   ;;
    esac
    [[ "${libc}" == musl ]] && suffix="-musl"
    printf 'linux-%s%s' "${arch}" "${suffix}"
}

# ai_tools_release_url_valid <url> : succeed when <url> may be fetched as a release manifest.
#   HTTPS only, and a character set that cannot carry a shell metacharacter, whitespace, or a
#   traversal into a URL that reaches curl. Allowlist, not blocklist.
ai_tools_release_url_valid() {
    # Held in a variable: a bracket expression carrying `&` and braces cannot be written inline in
    # `[[ =~ ]]` -- bash parses those as operators before the regex is ever assembled. `-` closes
    # the set, the POSIX way to include it literally.
    local allowed='^[A-Za-z0-9:/._~%?=&{}-]+$'
    local url="${1:-}"
    [[ "${url}" == https://* ]] || return 1
    [[ "${url}" != *..* ]] || return 1
    [[ "${url}" =~ ${allowed} ]]
}

# ai_tools_release_manifest_url <template> <version> : print the fetchable URL for <version>, by
#   substituting the template's single {version} slot. A template without the slot is refused
#   rather than fetched as-is: it would pin every version to one manifest, which reads as "verified"
#   while checking the wrong release. The version is admitted only in semver shape, so nothing a
#   package.json carries can inject a path segment into the URL.
ai_tools_release_manifest_url() {
    local template="${1:-}" version="${2:-}"
    [[ "${template}" == *'{version}'* ]] || return 1
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local url="${template//\{version\}/${version}}"
    ai_tools_release_url_valid "${url}" || return 1
    printf '%s' "${url}"
}

# ai_tools_release_manifest_checksum <manifest-json> <platform-key> : print the SHA-256 the
#   manifest lists for that platform. Reads the passed string only -- no filesystem, no network --
#   and admits the result only in exactly the 64-hex shape a SHA-256 has, so malformed JSON, an
#   absent platform, or a crafted value yields NOTHING rather than a checksum that could match a
#   crafted binary. jq is the parser (a hard dependency of the agent packages that declare these
#   fields); its absence is reported by the caller as "unable to verify", never as a mismatch.
ai_tools_release_manifest_checksum() {
    local manifest_json="${1:-}" platform_key="${2:-}" checksum
    [[ -n "${manifest_json}" && -n "${platform_key}" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    checksum="$(printf '%s' "${manifest_json}" \
        | jq -r --arg p "${platform_key}" '.platforms[$p].checksum // empty' 2>/dev/null)" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${checksum}"
}

# ai_tools_entrypoint_pin_verdict <expected> <observed> : the decision, given two checksums.
#   Echoes a verdict token and returns the status contract above:
#     ok         both present and equal
#     mismatch   both present and different -- the tamper signal, status 1
#     unpinned   no expected value: nothing has verified this entrypoint yet, status 2
#     unreadable no observed value: the entrypoint could not be hashed, status 2
#   Absence is never a mismatch: a missing pin and a modified binary are different facts with
#   different remedies. Unit-tested over the truth table.
ai_tools_entrypoint_pin_verdict() {
    local expected="${1:-}" observed="${2:-}"
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || { printf 'unpinned';   return 2; }
    [[ "${observed}" =~ ^[0-9a-f]{64}$ ]] || { printf 'unreadable'; return 2; }
    [[ "${expected}" == "${observed}" ]]  && { printf 'ok';         return 0; }
    printf 'mismatch'; return 1
}

# ── Impure: hashing, the pin, and the signed-manifest probe ──────────────────────────────────

# ai_tools_entrypoint_sha256 <path> : print the file's SHA-256, or nothing. Bounded to a regular
#   file so a fifo or device swapped into the path cannot block the caller forever.
ai_tools_entrypoint_sha256() {
    local path="${1:-}" line
    [[ -n "${path}" && ! -L "${path}" && -f "${path}" && -r "${path}" ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    line="$(sha256sum -- "${path}" 2>/dev/null)" || return 1
    line="${line%% *}"
    [[ "${line}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${line}"
}

# _ai_tools_ev_pin_file <agent> : print the pin path for an agent. The name is allowlisted to one
#   plain identifier before it becomes a path -- the same guard ai_tools_agent_manifest_field
#   applies -- so no declaration can address a file outside the pin directory.
_ai_tools_ev_pin_file() {
    local agent="${1:-}"
    [[ "${agent}" =~ ^[A-Za-z0-9._-]+$ && "${agent}" != *..* ]] || return 1
    printf '%s/%s' "${AI_TOOLS_ENTRYPOINT_PIN_DIR}" "${agent}"
}

# _ai_tools_ev_pin_field <pin-file> <key> : read one field defensively. A symlink is refused (the
#   pin directory is root-owned, so one is a tamper attempt, not a layout), the read is bounded,
#   and the value must match the key's own shape or it reads as absent. Same discipline as
#   ai_tools_service_stamp_field, kept local because this file is sourced by the launch path and
#   should not pull in the systemd-unit registry to read one line.
_ai_tools_ev_pin_field() {
    local pin="${1:-}" key="${2:-}" line
    [[ -n "${pin}" && ! -L "${pin}" && -f "${pin}" && -r "${pin}" ]] || return 1
    line="$(head -c 4096 -- "${pin}" 2>/dev/null \
                | grep -m1 -E "^${key}=[A-Za-z0-9:+._-]{1,64}$" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

# ai_tools_entrypoint_pin_read <agent> : print the SHA-256 recorded for that agent, or nothing.
ai_tools_entrypoint_pin_read() {
    local pin checksum
    pin="$(_ai_tools_ev_pin_file "${1:-}")" || return 1
    checksum="$(_ai_tools_ev_pin_field "${pin}" SHA256)" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${checksum}"
}

# ai_tools_entrypoint_pin_write <agent> <version> <sha256> <source-url> : record a verified
#   entrypoint. ROOT ONLY, and refused rather than left to fail on EACCES, so a caller can tell
#   "not permitted" from "the directory is missing". Written whole through a temp file and renamed,
#   so a reader never sees a partial pin.
ai_tools_entrypoint_pin_write() {
    local agent="${1:-}" version="${2:-}" checksum="${3:-}" source_url="${4:-}" pin tmp
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || { _ai_tools_ev_warn "refusing to write a pin as non-root"; return 1; }
    pin="$(_ai_tools_ev_pin_file "${agent}")" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -d "${AI_TOOLS_ENTRYPOINT_PIN_DIR}" ]] \
        || install -d -m 0750 -o root -g root "${AI_TOOLS_ENTRYPOINT_PIN_DIR}" 2>/dev/null \
        || { _ai_tools_ev_warn "cannot create ${AI_TOOLS_ENTRYPOINT_PIN_DIR}"; return 1; }
    tmp="$(mktemp "${pin}.XXXXXX" 2>/dev/null)" || return 1
    {
        printf '# ai-tools entrypoint pin -- written as root, read by the launch shim.\n'
        printf 'AGENT=%s\nVERSION=%s\nSHA256=%s\nVERIFIED=%s\n' \
            "${agent}" "${version:-unknown}" "${checksum}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ -n "${source_url}" ]] && printf 'SOURCE=%s\n' "${source_url}"
    } > "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
    # World-readable: a published checksum is not a secret, and the launch shim reads it as the
    # sandbox account. The 0750 directory above is the boundary, not this mode.
    chmod 0644 "${tmp}" 2>/dev/null || true
    mv -f -- "${tmp}" "${pin}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
    return 0
}

# _ai_tools_ev_dearmor <armored-key> <out> : convert a published ASCII-armored key to the binary
#   keyring gpgv wants, without gpg. The armor is base64 with an RFC 4880 header block and a `=`
#   CRC line, so stripping those and decoding is the whole conversion -- which keeps gnupg2's
#   verify-only half (gpgv) as the single dependency rather than a full gpg with a homedir and a
#   trustdb this would have to build per call.
_ai_tools_ev_dearmor() {
    local armored="${1:-}" out="${2:-}"
    [[ -r "${armored}" ]] || return 1
    awk '/^-----BEGIN/{f=1;next} /^-----END/{f=0} f && !/^[A-Za-z]+:/ && !/^=/ && NF' "${armored}" \
        | base64 -d > "${out}" 2>/dev/null || return 1
    [[ -s "${out}" ]]
}

# ai_tools_entrypoint_release_verify <entrypoint> <version> <url-template> <key> <fingerprint>
#   Fetch the vendor's release manifest for <version>, verify its detached signature against the
#   pinned <key>, and compare the checksum it publishes for this platform against <entrypoint>'s.
#   Returns the status contract above and prints the verified checksum on success.
#
#   Every input but the entrypoint comes from a root-owned agent manifest that already passed
#   ai_tools_conf_is_trusted, and the key is a file the agent package ships -- fetched from the
#   vendor, this would be npm's own weakness (a compromised source serving package, signature, and
#   key together). The fingerprint is declared separately and asserted against gpgv's output, so a
#   keyring swapped for another VALID key is still refused.
ai_tools_entrypoint_release_verify() {
    local entrypoint="${1:-}" version="${2:-}" url_template="${3:-}" key_file="${4:-}" fingerprint="${5:-}"
    local url workdir platform observed published

    command -v curl >/dev/null 2>&1 || { _ai_tools_ev_warn "curl not found -- cannot fetch the release manifest"; return 2; }
    command -v gpgv >/dev/null 2>&1 || { _ai_tools_ev_warn "gpgv not found -- cannot verify the release manifest signature; install gnupg2"; return 2; }
    [[ -r "${key_file}" ]] || { _ai_tools_ev_warn "release signing key unreadable: ${key_file}"; return 2; }

    # A LIST, in the shared KEY=value grammar -- the rotation overlap it exists for is in
    # providers.rule.md. Every entry must be a 40-hex fingerprint or the whole declaration is
    # unusable: a partially-parsed pin is one that might accept a key nobody meant to trust.
    local -a accepted_fingerprints=()
    if declare -F ai_tools_conf_split >/dev/null 2>&1; then
        ai_tools_conf_split accepted_fingerprints "${fingerprint}"
    else
        local _ifs="${IFS}"; IFS=$', \t\n'; read -ra accepted_fingerprints <<< "${fingerprint}"; IFS="${_ifs}"
    fi
    (( ${#accepted_fingerprints[@]} > 0 )) \
        || { _ai_tools_ev_warn "no release key fingerprint declared"; return 2; }
    local declared
    for declared in "${accepted_fingerprints[@]}"; do
        [[ "${declared}" =~ ^[0-9A-Fa-f]{40}$ ]] \
            || { _ai_tools_ev_warn "declared release key fingerprint '${declared}' is not 40 hex digits"; return 2; }
    done

    url="$(ai_tools_release_manifest_url "${url_template}" "${version}")" \
        || { _ai_tools_ev_warn "release manifest URL is not usable for version '${version}'"; return 2; }

    platform="$(ai_tools_entrypoint_platform_key "$(uname -m 2>/dev/null)" \
                    "$( [[ -e /lib/ld-musl-$(uname -m 2>/dev/null).so.1 ]] && printf musl )")" \
        || { _ai_tools_ev_warn "no release-manifest platform key for $(uname -m 2>/dev/null)"; return 2; }

    observed="$(ai_tools_entrypoint_sha256 "${entrypoint}")" \
        || { _ai_tools_ev_warn "cannot hash the entrypoint: ${entrypoint}"; return 2; }

    workdir="$(mktemp -d 2>/dev/null)" || return 2
    # shellcheck disable=SC2064
    trap "rm -rf -- '${workdir}'" RETURN

    # Both objects before the comparison, so an unpublished manifest is "unable to verify" and
    # never reaches it. --connect-timeout is what keeps an air-gapped host from waiting out a
    # blackholed route: this runs inside an rpm %post that must succeed offline.
    curl -fsSL --connect-timeout 5 --max-time 30 -o "${workdir}/manifest.json" -- "${url}" 2>/dev/null \
        || { _ai_tools_ev_warn "no release manifest published at ${url} (or the host is offline)"; return 2; }
    curl -fsSL --connect-timeout 5 --max-time 30 -o "${workdir}/manifest.sig" -- "${url}.sig" 2>/dev/null \
        || { _ai_tools_ev_warn "no detached signature published at ${url}.sig"; return 2; }
    _ai_tools_ev_dearmor "${key_file}" "${workdir}/key.gpg" \
        || { _ai_tools_ev_warn "could not read the release signing key at ${key_file}"; return 2; }

    # gpgv's exit status already separates the two failures that must not collapse, and separates
    # them exactly as the status contract does: 1 = a signature it rejects (tamper), 2 = a key it
    # does not hold (a vendor key rotation, not evidence about the binary). Anything else is
    # likewise unable-to-verify -- only a signature gpgv positively rejects earns verdict 1.
    local gpgv_output gpgv_status=0
    gpgv_output="$(gpgv --keyring "${workdir}/key.gpg" "${workdir}/manifest.sig" \
                        "${workdir}/manifest.json" 2>&1)" || gpgv_status=$?
    if (( gpgv_status == 1 )); then
        _ai_tools_ev_warn "release manifest for ${version} FAILED signature verification (BAD signature) -- refusing to trust its checksums"
        return 1
    fi
    if (( gpgv_status != 0 )); then
        _ai_tools_ev_warn "release manifest for ${version} is signed by a key the pinned keyring does not hold -- the vendor may have rotated it; update the agent package (dnf update 'ai-tools-agents-*')"
        return 2
    fi

    # The signature verified against SOME key in the keyring; assert it was a declared one. This
    # only bites once the keyring holds more than one key (a rotation overlap), which is exactly
    # when an un-asserted keyring would silently widen what may sign a release.
    local squeezed_output="${gpgv_output//[[:space:]]/}" matched=no
    for declared in "${accepted_fingerprints[@]}"; do
        [[ "${squeezed_output}" == *"${declared^^}"* ]] && { matched=yes; break; }
    done
    if [[ "${matched}" != yes ]]; then
        _ai_tools_ev_warn "release manifest is signed by a key in the shipped keyring that no declared fingerprint names -- refusing"
        return 1
    fi

    published="$(ai_tools_release_manifest_checksum "$(cat "${workdir}/manifest.json")" "${platform}")" \
        || { _ai_tools_ev_warn "the signed manifest for ${version} lists no ${platform} checksum"; return 2; }

    local token rc
    token="$(ai_tools_entrypoint_pin_verdict "${published}" "${observed}")" && rc=0 || rc=$?
    case "${token}" in
        ok) printf '%s' "${published}"; return 0 ;;
        mismatch)
            _ai_tools_ev_warn "entrypoint does NOT match the signed release ${version} (${platform}): ${entrypoint}"
            return 1 ;;
        *)  return "${rc}" ;;
    esac
}

# ai_tools_entrypoint_verify_required : succeed when operator.conf declares that this host must not
#   run an UNVERIFIED entrypoint. The updater and the launch both read it HERE, so they cannot
#   disagree about how strict the host is; what it governs and why its default is permissive are in
#   updater.rule.md. Honoured only while operator.conf passes ai_tools_conf_is_trusted, so the
#   sandbox account can neither set nor clear it; every other outcome yields NO.
ai_tools_entrypoint_verify_required() {
    local operator_conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
    declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 || return 1
    ai_tools_conf_is_trusted "${operator_conf}" 2>/dev/null || return 1
    ai_tools_conf_read "${operator_conf}" AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY 2>/dev/null || return 1
    case "${_ai_tools_conf_value,,}" in yes|true|1|on) return 0 ;; esac
    return 1
}

# ai_tools_entrypoint_check <agent> <entrypoint> : the launch-side gate. Hash the entrypoint and
#   compare it to the agent's pin. Echoes the verdict token and returns the status contract; takes
#   no network, no key, and no privilege, so it runs as the sandbox account on the launch path.
ai_tools_entrypoint_check() {
    local agent="${1:-}" entrypoint="${2:-}" expected observed
    expected="$(ai_tools_entrypoint_pin_read "${agent}" || true)"
    observed="$(ai_tools_entrypoint_sha256 "${entrypoint}" || true)"
    ai_tools_entrypoint_pin_verdict "${expected}" "${observed}"
}
