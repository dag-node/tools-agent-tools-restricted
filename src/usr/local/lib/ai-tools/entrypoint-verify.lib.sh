#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/entrypoint-verify.lib.sh
# Verify that an agent's entrypoint is the binary its vendor published, and carry that verdict to the launch in a record
# the sandbox account cannot write.
#
# It is agent-agnostic: the release manifest, the signing key, and its fingerprint are optional fields on the agent's
# own manifest (providers.rule.md). Why the check exists, which caller runs which half, what each outcome means,
# and where the pin lives are in updater.rule.md; this header covers only what a reader of this file needs.
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

# Include guard: an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing
# shell's `set -e`.
if [[ -n "${_AI_TOOLS_ENTRYPOINT_VERIFY_LIB_LOADED:-}" ]]; then
    return 0
fi
_AI_TOOLS_ENTRYPOINT_VERIFY_LIB_LOADED=1

# The shared KEY=value grammar, for the strictness switch and the fingerprint list. Best-effort, NOT required:
# the launch-side check (the hot path) needs neither, and every consumer that does has already loaded conf.lib.sh
# through providers.lib.sh -- so a failure here degrades the two functions that use it in their permissive/refusing
# directions rather than leaving them undefined. Both guard on `declare -F` before calling into it.
# shellcheck source=SCRIPTDIR/conf.lib.sh
source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null || true

# Deployed paths, overridable as root-only test hooks (the same posture as providers.lib.sh's manifest directories:
# every consumer runs under sudo, which scrubs the environment, and no sudoers rule keeps these names).
: "${AI_TOOLS_ENTRYPOINT_PIN_DIR:=/var/opt/ai-tools/state/entrypoint-pin.d}"
# The labelling half of the same reconciliation records its outcome beside the pin, in the same grammar
# and with the same ownership. It lives HERE, next to the pin, rather than in relabel.lib.sh which performs
# the labelling: `ai-tools status` reads both records through this library and does not load the labelling one,
# whose functions are root-only. One record the report can read is worth more than a record filed next to the code
# that writes it.
: "${AI_TOOLS_ENTRYPOINT_LABEL_DIR:=/var/opt/ai-tools/state/entrypoint-label.d}"
# The third record, and the only one written by a REFUSAL: a reconciliation that would not re-record an entrypoint
# leaves the pin as it was, which is exactly what makes the next launch refuse -- and a pin left standing still reads
# green in both status reports. The mark is what turns that silent state into a reported one.
: "${AI_TOOLS_ENTRYPOINT_STALE_DIR:=/var/opt/ai-tools/state/entrypoint-stale.d}"

# _ai_tools_ev_warn <message...> : report to stderr and, when log.lib.sh is loaded by the caller,
#   to journald. Never alters a verdict.
_ai_tools_ev_warn() {
    printf 'entrypoint-verify: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "entrypoint-verify: $*"
    return 0
}

# ── Pure decisions (no I/O, no privilege, no network) ────────────────────────────────────────

# ai_tools_entrypoint_platform_key <machine> [libc] : print the key a vendor release manifest
#   lists this host's binary under, or an empty string for an architecture with no mapping. <machine> is
#   `uname -m`; <libc> is `musl` or empty. Pure, so the mapping is unit-tested without needing the
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
    # Held in a variable: a bracket expression carrying `&` and braces cannot be written inline in `[[ =~ ]]` -- bash
    # parses those as operators before the regex is ever assembled. `-` closes the set, the POSIX way to include it
    # literally.
    local allowed='^[A-Za-z0-9:/._~%?=&{}-]+$'
    local url="${1:-}"
    [[ "${url}" == https://* ]] || return 1
    [[ "${url}" != *..* ]] || return 1
    [[ "${url}" =~ ${allowed} ]]
}

# ai_tools_release_manifest_url <template> <version> : print the fetchable URL for <version>, by
#   substituting the template's single {version} slot. A template without the slot is refused
#   rather than fetched as-is: it would pin every version to one manifest, which reads as "verified"
#   while checking the wrong release. The version is admitted only in semver shape, so no value a
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
#   absent platform, or a crafted value yields an EMPTY STRING rather than a checksum that could match a
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
#   Echoes a verdict token and returns this library's status contract:
#     ok         both present and equal
#     mismatch   both present and different -- the tamper signal, status 1
#     unpinned   no expected value: no run has verified this entrypoint yet, status 2
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

# ai_tools_entrypoint_observe_decision <pinned-version> <pinned-sha> <installed-version> <installed-sha> :
#   whether root may record an OBSERVED pin for an agent whose vendor publishes no signed manifest.
#   Echoes a token and returns the status contract:
#     pin     no usable pin yet, or a different version is installed -- record what is there, status 0
#     keep    the pin already describes this file, status 0
#     tamper  the SAME version now hashes differently -- status 1, and the pin is LEFT AS IT IS
#
#   The last row is what makes an observed pin worth having. A release the updater installed brings a
#   new version with it, so a changed binary under an unchanged version is the one thing no update
#   explains; re-recording it would bless exactly what the pin exists to catch. The launch gate needs
#   no part of this: the stale pin it keeps is what makes the next launch read `mismatch`.
ai_tools_entrypoint_observe_decision() {
    local pinned_version="${1:-}" pinned_sha="${2:-}" installed_version="${3:-}" installed_sha="${4:-}"
    [[ "${installed_sha}" =~ ^[0-9a-f]{64}$ ]] || { printf 'unreadable'; return 2; }
    [[ "${pinned_sha}" =~ ^[0-9a-f]{64}$ ]]    || { printf 'pin';        return 0; }
    # A pin whose version the reader does not return (an empty first argument) is decided by its bytes alone: with no
    # version to tell a release from a rewrite, a different checksum is refused. Reading it as a new version would
    # re-record any change.
    if [[ -n "${pinned_version}" && "${pinned_version}" != "${installed_version}" ]]; then
        printf 'pin'; return 0
    fi
    [[ "${pinned_sha}" == "${installed_sha}" ]] && { printf 'keep';      return 0; }
    printf 'tamper'; return 1
}

# ── Impure: hashing, the pin, and the signed-manifest probe ──────────────────────────────────

# ai_tools_entrypoint_sha256 <path> : print the file's SHA-256, or an empty string. Bounded to a regular
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

# ai_tools_entrypoint_inputs_digest <url-template> <key-file> <fingerprints> : print a SHA-256 over
#   everything that decides a verification verdict besides the entrypoint itself -- the manifest URL
#   template, the signing key's path AND its content, and the declared fingerprints. A pin records
#   this digest so a later run can tell "the same question, asked the same way" from a question that
#   has changed (a vendor key rotation, a repointed manifest host) without refetching anything.
#   Prints an empty string when any input is unusable, which resolves to a full verification.
ai_tools_entrypoint_inputs_digest() {
    local url_template="${1:-}" key_file="${2:-}" fingerprints="${3:-}" key_digest line
    [[ -n "${url_template}" ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    key_digest="$(ai_tools_entrypoint_sha256 "${key_file}")" || return 1
    line="$(printf '%s\n%s\n%s\n%s\n' \
                "${url_template}" "${key_file}" "${key_digest}" "${fingerprints}" \
            | sha256sum 2>/dev/null)" || return 1
    line="${line%% *}"
    [[ "${line}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${line}"
}

# ai_tools_entrypoint_pin_path <agent> : print the pin path for an agent. The name is allowlisted to
#   one plain identifier before it becomes a path -- the same guard ai_tools_agent_manifest_field
#   applies -- so no declaration can address a file outside the pin directory. Public because the
#   CLI's status report reads the pin through the shared stamp accessors (services.lib.sh) and must
#   not hardcode where it lives.
ai_tools_entrypoint_pin_path() {
    _ai_tools_ev_record_path "${AI_TOOLS_ENTRYPOINT_PIN_DIR}" "${1:-}"
}

# ai_tools_entrypoint_label_path <agent> : print the path of the record holding what the last
#   reconciliation could do about that agent's SELinux labels. Public for the same reason the pin
#   path is: `ai-tools status` reports it and must not hardcode where it lives.
ai_tools_entrypoint_label_path() {
    _ai_tools_ev_record_path "${AI_TOOLS_ENTRYPOINT_LABEL_DIR}" "${1:-}"
}

# ai_tools_entrypoint_stale_path <agent> : print the path of the record saying that the last
#   reconciliation REFUSED to re-record this agent's pin, so the pin standing beside it describes
#   a binary that is no longer installed. Public for the same reason the other two are.
ai_tools_entrypoint_stale_path() {
    _ai_tools_ev_record_path "${AI_TOOLS_ENTRYPOINT_STALE_DIR}" "${1:-}"
}

# _ai_tools_ev_record_path <dir> <agent> : print <dir>/<agent> for an agent name that is one plain
#   identifier -- the same guard ai_tools_agent_manifest_field applies -- so no declaration can
#   address a file outside the record directory. One implementation, because a name allowlist that
#   exists twice is a name allowlist that can differ.
_ai_tools_ev_record_path() {
    local dir="${1:-}" agent="${2:-}"
    [[ "${agent}" =~ ^[A-Za-z0-9._-]+$ && "${agent}" != *..* ]] || return 1
    printf '%s/%s' "${dir}" "${agent}"
}

# _ai_tools_ev_write_record <path> <dir> : write stdin to <path>, creating <dir> if absent. ROOT
#   ONLY, and refused rather than left to fail on EACCES, so a caller can tell "not permitted" from
#   "the directory is missing". Written to a temp file and renamed, so a reader never sees a partial
#   record. World-readable: what these records hold is a published checksum and a label outcome,
#   neither a secret, and the launch shim reads the pin as the sandbox account. The 0750 directory
#   is the boundary, not the file mode.
_ai_tools_ev_write_record() {
    local path="${1:-}" dir="${2:-}" tmp
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || { _ai_tools_ev_warn "refusing to write ${path} as non-root"; return 1; }
    [[ -d "${dir}" ]] \
        || install -d -m 0750 -o root -g root "${dir}" 2>/dev/null \
        || { _ai_tools_ev_warn "cannot create ${dir}"; return 1; }
    tmp="$(mktemp "${path}.XXXXXX" 2>/dev/null)" || return 1
    cat > "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
    chmod 0644 "${tmp}" 2>/dev/null || true
    mv -f -- "${tmp}" "${path}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
    return 0
}

# ai_tools_entrypoint_label_write <agent> <ok|failed|skipped> [reason-token] : record what the last
#   reconciliation could do about <agent>'s labels. ROOT ONLY.
#
#   `skipped` is the SELinux layer being inactive -- a DAC-only host, where there is no
#   ai_tools_exec_t to assign and no fault to fix. The reason is a short TOKEN, not prose: every
#   field here is read back through the stamp accessors' charset clamp, which excludes spaces, and
#   the operator-facing detail (semanage's own message) belongs in the log the refusal already
#   writes. This says which class of failure, so the report can name the remedy.
ai_tools_entrypoint_label_write() {
    local agent="${1:-}" result="${2:-}" reason="${3:-}" record
    record="$(ai_tools_entrypoint_label_path "${agent}")" || return 1
    case "${result}" in ok|failed|skipped) ;; *) return 1 ;; esac
    [[ -z "${reason}" || "${reason}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || reason=""
    {
        printf '# ai-tools entrypoint label record -- written as root, read by ai-tools status.\n'
        printf 'AGENT=%s\nRESULT=%s\nLABELLED=%s\n' \
            "${agent}" "${result}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # See the pin write: the last command's status is the group's, and most records carry no reason -- so an `ok`
        # outcome would report itself as unrecordable.
        if [[ -n "${reason}" ]]; then printf 'REASON=%s\n' "${reason}"; fi
    } | _ai_tools_ev_write_record "${record}" "${AI_TOOLS_ENTRYPOINT_LABEL_DIR}"
}

# ai_tools_entrypoint_stale_write <agent> <version> <reason-token> : record that this run refused to
#   re-record <agent>'s pin, so the pin left standing no longer describes the installed binary and
#   the next launch will refuse. ROOT ONLY, same record and same atomic write as the other two.
#
#   It exists because a refusal is otherwise the one outcome that does not leave a trace a report can read:
#   the pin is deliberately left as it was -- that staleness IS the gate -- and both status reports
#   then renders it green from its own VERSION and VERIFIED. The mark carries `STATE=stale`
#   and `DETECTED` in the label record's grammar, so the reports read it through the same stamp
#   accessors, and `VERSION` names the installed version the refusal was about (which the pin, by
#   construction, does not hold).
ai_tools_entrypoint_stale_write() {
    local agent="${1:-}" version="${2:-}" reason="${3:-}" record
    record="$(ai_tools_entrypoint_stale_path "${agent}")" || return 1
    _ai_tools_ev_field_ok "${version}" || version=unknown
    [[ "${reason}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || reason=unknown
    {
        printf '# ai-tools entrypoint stale-pin mark -- written as root, read by ai-tools status.\n'
        printf 'AGENT=%s\nSTATE=stale\nVERSION=%s\nREASON=%s\nDETECTED=%s\n' \
            "${agent}" "${version}" "${reason}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } | _ai_tools_ev_write_record "${record}" "${AI_TOOLS_ENTRYPOINT_STALE_DIR}"
}

# ai_tools_entrypoint_stale_clear <agent> : drop the mark, for a run whose reconciliation of <agent>
#   came out clean. ROOT ONLY and best-effort -- a mark `rm` does not remove leaves a report saying
#   the entrypoint needs attention, which is the direction that costs an operator a look rather than
#   a refusal they never hear about. Succeeds when there is no mark to clear.
ai_tools_entrypoint_stale_clear() {
    local record
    record="$(ai_tools_entrypoint_stale_path "${1:-}")" || return 1
    [[ -e "${record}" ]] || return 0
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || { _ai_tools_ev_warn "refusing to clear ${record} as non-root"; return 1; }
    rm -f -- "${record}" 2>/dev/null
}

# _ai_tools_ev_pin_field <pin-file> <key> : read one field defensively. A symlink is refused (the
#   pin directory is root-owned, so one is a tamper attempt, not a layout), the read is bounded,
#   and the value must match the key's own shape or it reads as absent. Same discipline as
#   ai_tools_service_stamp_field, kept local because this file is sourced by the launch path and
#   should not pull in the systemd-unit registry to read one line.
_ai_tools_ev_pin_field() {
    local pin="${1:-}" key="${2:-}" line
    [[ -n "${pin}" && ! -L "${pin}" && -f "${pin}" && -r "${pin}" ]] || return 1
    line="$(head -c 4096 -- "${pin}" 2>/dev/null | grep -m1 -E "^${key}=" 2>/dev/null)" || return 1
    _ai_tools_ev_field_ok "${line#*=}" || return 1
    printf '%s' "${line#*=}"
}

# _ai_tools_ev_field_ok <value> : succeed when <value> has the shape one pin field admits -- alphanumerics and
#   `:+._-`, 1 to 64 characters. The writers clamp to this same shape (a version outside it is recorded as
#   `unknown`), so every value a pin holds is one its readers return: a recorded version the reader could not return
#   would compare as absent and turn every later reconcile into a re-pin.
_ai_tools_ev_field_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9:+._-]{1,64}$ ]]; }

# ai_tools_entrypoint_pin_read <agent> : print the SHA-256 recorded for that agent, or an empty string.
ai_tools_entrypoint_pin_read() {
    local pin checksum
    pin="$(ai_tools_entrypoint_pin_path "${1:-}")" || return 1
    checksum="$(_ai_tools_ev_pin_field "${pin}" SHA256)" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${checksum}"
}

# ai_tools_entrypoint_pin_write <agent> <version> <sha256> <source-url> [inputs-digest] : record a
#   verified entrypoint. ROOT ONLY (see _ai_tools_ev_write_record, which also makes the write
#   atomic). A checksum is admitted only in exact 64-hex shape, so a partial observation never lands
#   as a pin. <inputs-digest> is what ai_tools_entrypoint_pin_reusable compares against; a pin
#   written without one is never reusable, so an unrecordable digest costs a re-verification.
ai_tools_entrypoint_pin_write() {
    local agent="${1:-}" version="${2:-}" checksum="${3:-}" source_url="${4:-}" inputs="${5:-}" pin
    pin="$(ai_tools_entrypoint_pin_path "${agent}")" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    _ai_tools_ev_field_ok "${version}" || version=unknown
    {
        printf '# ai-tools entrypoint pin -- written as root, read by the launch shim.\n'
        printf 'AGENT=%s\nVERSION=%s\nSHA256=%s\nKIND=verified\nVERIFIED=%s\n' \
            "${agent}" "${version}" "${checksum}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ "${inputs}" =~ ^[0-9a-f]{64}$ ]]; then printf 'INPUTS=%s\n' "${inputs}"; fi
        # An `if`, not `[[ ]] && printf`: this is the group's LAST command, so its status is the group's, and a pin
        # written without a source URL would fail the pipeline that writes it.
        if [[ -n "${source_url}" ]]; then printf 'SOURCE=%s\n' "${source_url}"; fi
    } | _ai_tools_ev_write_record "${pin}" "${AI_TOOLS_ENTRYPOINT_PIN_DIR}"
}

# ai_tools_entrypoint_installed_version <entrypoint> : print the version the package around <entrypoint> declares,
#   or an empty string. Walks up from the entrypoint's own directory to the nearest `package.json` and reads
#   the `version` field out of a bounded read of it.
#
#   The value comes from a file the SANDBOX account owns and reaches the operator's terminal, the journal and a pin
#   record, so it is admitted only in a clamped shape: `MAJOR.MINOR.PATCH`, optionally with a `-`/`+` suffix
#   of alphanumerics, dots and hyphens, never containing `..`, and within the length a pin field admits
#   (_ai_tools_ev_field_ok). That admits a platform package's own spelling
#   (`0.154.0-linux-x64`) while excluding every character an escape sequence or a path traversal needs -- the suffix
#   matters because the version also fills the `{version}` slot of a release-manifest URL.
#
#   The walk is bounded and deeper than the package layout of a single agent, because an entrypoint can sit several
#   directories inside its package: Claude Code's is `<pkg>/bin/claude.exe`, while codex's vendored binary is
#   `<pkg>/vendor/<target-triple>/bin/codex`. One reader serves both, so the two callers -- the pin and the launch
#   banner -- cannot disagree about what version an entrypoint is.
ai_tools_entrypoint_installed_version() {
    local dir="${1:-}" declared
    [[ -n "${dir}" ]] || return 0
    dir="${dir%/*}"
    local _hop
    for _hop in 1 2 3 4 5 6; do
        [[ -n "${dir}" ]] || break
        if [[ -f "${dir}/package.json" && -r "${dir}/package.json" ]]; then
            # Bounded read of a regular file: the version sits in the first bytes, and a fifo swapped into the path must
            # never block a launch.
            declared="$(head -c 65536 -- "${dir}/package.json" 2>/dev/null \
                | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
            if [[ "${declared}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ && "${declared}" != *..* ]] \
                    && _ai_tools_ev_field_ok "${declared}"; then
                printf '%s' "${declared}"
                return 0
            fi
        fi
        dir="${dir%/*}"
    done
    return 0
}

# ai_tools_entrypoint_package_dir <entrypoint> <npm-package> : print the installed package directory
#   a forced reinstall of <npm-package> has to remove first, or return non-zero when the entrypoint
#   does not sit inside one.
#
#   It exists because the remedy for a changed binary is not the provisioning command: `npm install -g`
#   is a no-op at an already-installed version, so reprovisioning leaves the modified file exactly where it is
#   and the host goes on refusing with no explanation. Removing this directory is what makes the next
#   `ai-tools-admin system bootstrap` fetch the package again. One reader, so the launch refusal and the relabel
#   helper name the same path.
#
#   The entrypoint path and the package name reach a terminal inside a command carrying `rm -rf`, so each is
#   clamped: the version directory must be absolute and `..`-free, and the package name only to the shape npm gives one.
ai_tools_entrypoint_package_dir() {
    local entrypoint="${1:-}" package="${2:-}" version_dir
    [[ -n "${entrypoint}" && -n "${package}" ]] || return 1
    [[ "${entrypoint}" == */lib/node_modules/* ]] || return 1
    version_dir="${entrypoint%%/lib/node_modules/*}"
    [[ "${version_dir}" == /* && "${version_dir}" != *..* ]] || return 1
    [[ "${package}" =~ ^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s/lib/node_modules/%s' "${version_dir}" "${package}"
}

# ai_tools_entrypoint_pin_write_observed <agent> <version> <sha256> : record what is installed, for an agent whose
#   vendor publishes no signed release manifest to check it against. ROOT ONLY, same record and same atomic write as
#   the verified pin, and distinguished from it by `KIND=observed` -- so every reader can say which of the two a host
#   holds, and none of them has to infer it from an absent SOURCE. What the two tiers claim is in updater.rule.md;
#   the short of it is that this one detects a later change to the file and makes no statement about its origin.
#
#   The caller decides WHETHER to write: ai_tools_entrypoint_observe_decision holds that rule, so the guard against
#   re-recording a tampered binary is one testable function rather than a condition at each call site.
ai_tools_entrypoint_pin_write_observed() {
    local agent="${1:-}" version="${2:-}" checksum="${3:-}" pin
    pin="$(ai_tools_entrypoint_pin_path "${agent}")" || return 1
    [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    _ai_tools_ev_field_ok "${version}" || version=unknown
    {
        printf '# ai-tools entrypoint pin -- written as root, read by the launch shim.\n'
        printf '# KIND=observed: the checksum of the binary as installed, not one verified against a vendor signature.\n'
        printf 'AGENT=%s\nVERSION=%s\nSHA256=%s\nKIND=observed\nVERIFIED=%s\n' \
            "${agent}" "${version}" "${checksum}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } | _ai_tools_ev_write_record "${pin}" "${AI_TOOLS_ENTRYPOINT_PIN_DIR}"
}

# ai_tools_entrypoint_pin_kind <agent> : print `verified`, `observed`, or `unknown` for the pin this host holds,
#   or an empty string when there is no pin.
#
#   A record carrying NO KIND reads as `verified`: the field was added with the observed tier, and every pin written
#   before it came from the signed-manifest path. A record carrying a KIND this library does not define reads
#   as `unknown` -- rendering it as either tier would state a claim about the binary's origin that no writer here made.
#   The two cases are told apart by the field reader's own status, so an absent field and an unreadable one do not
#   collapse into the same answer.
ai_tools_entrypoint_pin_kind() {
    local pin kind
    pin="$(ai_tools_entrypoint_pin_path "${1:-}")" || return 1
    [[ -f "${pin}" ]] || return 1
    kind="$(_ai_tools_ev_pin_field "${pin}" KIND 2>/dev/null)" || { printf 'verified'; return 0; }
    case "${kind}" in
        observed|verified) printf '%s' "${kind}" ;;
        *)                 printf 'unknown'    ;;
    esac
}

# ai_tools_entrypoint_pin_version <agent> : print the version the pin records, or an empty string. The observing
#   caller compares it with what is installed, which is how a new release is told from a changed binary.
ai_tools_entrypoint_pin_version() {
    local pin
    pin="$(ai_tools_entrypoint_pin_path "${1:-}")" || return 1
    _ai_tools_ev_pin_field "${pin}" VERSION
}

# ai_tools_entrypoint_pin_reusable <agent> <version> <inputs-digest> <observed-sha256> : succeed
#   when the recorded pin already answers exactly this question -- same installed version, same
#   declared verification inputs, same bytes on disk. The caller may then skip the manifest fetch
#   and the signature check, because re-running them over unchanged inputs re-derives the verdict
#   the pin holds.
#
#   What it gives up is narrow and deliberate: a vendor REPUBLISHING or withdrawing a release it
#   already signed goes unnoticed until something else changes. Everything that makes the pin a
#   tamper gate is intact -- a modified entrypoint changes <observed-sha256>, a rotated key or
#   repointed manifest changes <inputs-digest>, and either takes the full path.
#
#   Every unreadable, absent, or malformed field returns 1, so the failure direction is a full
#   verification rather than a reused verdict.
ai_tools_entrypoint_pin_reusable() {
    local agent="${1:-}" version="${2:-}" inputs="${3:-}" observed="${4:-}" pin
    [[ "${observed}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "${inputs}"   =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -n "${version}" ]] || return 1
    pin="$(ai_tools_entrypoint_pin_path "${agent}")" || return 1
    [[ "$(_ai_tools_ev_pin_field "${pin}" VERSION || true)" == "${version}"  ]] || return 1
    [[ "$(_ai_tools_ev_pin_field "${pin}" INPUTS  || true)" == "${inputs}"   ]] || return 1
    [[ "$(_ai_tools_ev_pin_field "${pin}" SHA256  || true)" == "${observed}" ]] || return 1
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
#   Returns this library's status contract and prints the verified checksum on success.
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

    # A LIST, in the shared KEY=value grammar -- the rotation overlap it exists for is in providers.rule.md. Every entry
    # must be a 40-hex fingerprint or the whole declaration is unusable: a partially-parsed pin is one that might accept
    # a key nobody meant to trust.
    local -a accepted_fingerprints=()
    if declare -F ai_tools_conf_list_value >/dev/null 2>&1; then
        ai_tools_conf_list_value accepted_fingerprints "${fingerprint}" 0 "release_fingerprint"
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

    # Both objects before the comparison, so an unpublished manifest is "unable to verify" and never reaches it.
    # `--connect-timeout` is what keeps an air-gapped host from waiting out a blackholed route: this runs inside an rpm
    # %post that must succeed offline.
    curl -fsSL --connect-timeout 5 --max-time 30 -o "${workdir}/manifest.json" -- "${url}" 2>/dev/null \
        || { _ai_tools_ev_warn "no release manifest published at ${url} (or the host is offline)"; return 2; }
    curl -fsSL --connect-timeout 5 --max-time 30 -o "${workdir}/manifest.sig" -- "${url}.sig" 2>/dev/null \
        || { _ai_tools_ev_warn "no detached signature published at ${url}.sig"; return 2; }
    _ai_tools_ev_dearmor "${key_file}" "${workdir}/key.gpg" \
        || { _ai_tools_ev_warn "could not read the release signing key at ${key_file}"; return 2; }

    # gpgv's exit status already separates the two failures that must not collapse, and separates them exactly
    # as the status contract does: 1 = a signature it rejects (tamper), 2 = a key it does not hold (a vendor key
    # rotation, not evidence about the binary). Anything else is likewise unable-to-verify -- only a signature gpgv
    # positively rejects earns verdict 1.
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

    # The signature verified against SOME key in the keyring; assert it was a declared one. This only bites once
    # the keyring holds more than one key (a rotation overlap), which is exactly when an un-asserted keyring would
    # silently widen what may sign a release.
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
    ai_tools_conf_yes "${operator_conf}" AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY
}

# ai_tools_entrypoint_check <agent> <entrypoint> : the launch-side gate. Hash the entrypoint and
#   compare it to the agent's pin. Echoes the verdict token and returns the status contract. It does not
#   reach the network, read a key, or need privilege, so it runs as the sandbox account on the
#   launch path.
ai_tools_entrypoint_check() {
    local agent="${1:-}" entrypoint="${2:-}" expected observed
    expected="$(ai_tools_entrypoint_pin_read "${agent}" || true)"
    observed="$(ai_tools_entrypoint_sha256 "${entrypoint}" || true)"
    ai_tools_entrypoint_pin_verdict "${expected}" "${observed}"
}
