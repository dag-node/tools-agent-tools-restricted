#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/lib/assets.sh -- resolve this repository's development tools from two pinned, signed releases: the asset set
# `core` of dag-node/ai-tools-assets (the prose checker and the reftags tool, inside its skills)
# and dag-node/ai-tools-assets-tools (the formatters and the conformance fixtures). Sourced by the hooks, the formatter
# front door, tools/generators/ref-index.sh, the conformance checker and the unit tests; run as a command:
#
#     ```bash
#     bash tools/lib/assets.sh fetch              # fetch, verify and unpack both pins into the cache
#     bash tools/lib/assets.sh verify             # exit 1 unless both cached archives match their pins and signatures
#     bash tools/lib/assets.sh path core|tools    # print the unpacked directory of one pin
#     ```
#
# A pin is `tools/lib/assets-<name>.pin`, data read line by line: `tag`, `archive` and `archive_sha256`, each once,
# comments and blank lines beside them, and a line outside those keys refuses the pin. An archive is accepted when its
# sha256 equals the pin's and the one its release publishes, and `gpgv` reports a VALIDSIG whose primary is the dag-node
# package-signing primary, read through the key base itself ships, so the anchor is the one every set binding names.
# The `core` tree is held to its own inventory after the unpack (ai_tools_assets_verify__verify_inventory), so a tree
# that is not whole is refused as well.
#
# The cache is per user and outside the tree, `${XDG_CACHE_HOME:-$HOME/.cache}/ai-tools-dev/<archive>.<sha256-prefix>/`
# at 0700, holding the archive, its .sha256 and .asc, and the unpacked `tree/`. The project tree is collaborative:
# a cache inside it would be a directory the sandbox account writes and the operator's commit hook executes. The name
# carries the archive's sha256, so a pin bump does not reuse a stale unpack. `path` reads the cache alone; `fetch` is
# the one network step. A fetch is staged in a directory of its own under the cache and renamed into place only
# after every check passed.
#
# A checkout stands in for a pin, reported: AI_TOOLS_DEV_ASSETS_CORE names a checkout of ai-tools-assets (its
# `sets/core` is the tree) and AI_TOOLS_DEV_ASSETS_TOOLS one of ai-tools-assets-tools (holding `formatters/`
# and `fixtures/`); `path` then prints a BYPASS line on stderr naming the checkout and its commit.
#
# The module name is `dev_assets`, since `assets` is assets.lib.sh's and the conformance checker loads both.

if [[ -n "${_AI_TOOLS_DEV_ASSETS__LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_AI_TOOLS_DEV_ASSETS__LOADED=1

_AI_TOOLS_DEV_ASSETS__ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_AI_TOOLS_DEV_ASSETS__LIB_DIR="${_AI_TOOLS_DEV_ASSETS__ROOT}/src/usr/local/lib/ai-tools"
_AI_TOOLS_DEV_ASSETS__SIGNING_KEY="${_AI_TOOLS_DEV_ASSETS__LIB_DIR}/keys/dag-node-package-signing.asc"
_AI_TOOLS_DEV_ASSETS__SIGNING_PRIMARY="67F42DC18BF764B42D82F14256D2F802CF9832E4"   # DagNode Package Signing

# The command a reader is told to run when a pin is not in the cache.
AI_TOOLS_DEV_ASSETS__FETCH_COMMAND="bash tools/lib/assets.sh fetch"

# _ai_tools_dev_assets__refuse <message> : the reason on stderr; returns 1.
_ai_tools_dev_assets__refuse() { printf 'assets: %s\n' "$1" >&2; return 1; }

# ai_tools_dev_assets__get_pin_path <core|tools> : print the pin file of <name>; returns 1 for any other name.
ai_tools_dev_assets__get_pin_path() {
    case "$1" in
        core|tools) printf '%s/tools/lib/assets-%s.pin' "${_AI_TOOLS_DEV_ASSETS__ROOT}" "$1" ;;
        *) return 1 ;;
    esac
}

# _ai_tools_dev_assets__get_release_url <core|tools> <tag> : the download base of a release, the tag's `/` encoded.
_ai_tools_dev_assets__get_release_url() {
    local repository
    case "$1" in
        core)  repository=ai-tools-assets ;;
        tools) repository=ai-tools-assets-tools ;;
    esac
    printf 'https://github.com/dag-node/%s/releases/download/%s' "${repository}" "${2//\//%2F}"
}

# ai_tools_dev_assets__read_pin <core|tools> : read <name>'s pin into AI_TOOLS_DEV_ASSETS__PIN_TAG, _ARCHIVE
# and _SHA256. Returns 1, the reason on stderr, for an absent pin, a line outside the three keys, a key absent
# or repeated, a tag outside the charset, an archive outside its release's naming, or a sha256 that is not 64 lowercase
# hex digits.
ai_tools_dev_assets__read_pin() {
    local name="$1" pin line key value archive_pattern
    local -A seen=()
    AI_TOOLS_DEV_ASSETS__PIN_TAG=""; AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE=""; AI_TOOLS_DEV_ASSETS__PIN_SHA256=""
    pin="$(ai_tools_dev_assets__get_pin_path "${name}")" || { _ai_tools_dev_assets__refuse "no pin is named ${name}"; return 1; }
    [[ -f "${pin}" && -r "${pin}" ]] || { _ai_tools_dev_assets__refuse "${pin} is absent or unreadable"; return 1; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" == '#'* ]] && continue
        if [[ ! "${line}" =~ ^(tag|archive|archive_sha256)=(.+)$ ]]; then
            _ai_tools_dev_assets__refuse "${pin}: a line outside tag, archive and archive_sha256 refuses the pin"; return 1
        fi
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ -z "${seen[${key}]+x}" ]] || { _ai_tools_dev_assets__refuse "${pin}: ${key} is set twice"; return 1; }
        seen["${key}"]=1
        case "${key}" in
            tag)            AI_TOOLS_DEV_ASSETS__PIN_TAG="${value}" ;;
            archive)        AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE="${value}" ;;
            archive_sha256) AI_TOOLS_DEV_ASSETS__PIN_SHA256="${value}" ;;
        esac
    done < "${pin}"
    case "${name}" in
        core)  archive_pattern='^ai-tools-assets-core-[0-9][0-9A-Za-z.+-]*\.zip$' ;;
        tools) archive_pattern='^ai-tools-assets-tools-[0-9][0-9A-Za-z.+-]*\.tar\.gz$' ;;
    esac
    if [[ ! "${AI_TOOLS_DEV_ASSETS__PIN_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]]; then
        _ai_tools_dev_assets__refuse "${pin}: tag is absent or outside [A-Za-z0-9._/+-]"; return 1
    fi
    if [[ ! "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" =~ ${archive_pattern} ]]; then
        _ai_tools_dev_assets__refuse "${pin}: archive is absent or outside the release's naming"; return 1
    fi
    if [[ ! "${AI_TOOLS_DEV_ASSETS__PIN_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
        _ai_tools_dev_assets__refuse "${pin}: archive_sha256 is absent or not 64 lowercase hex digits"; return 1
    fi
    return 0
}

# ai_tools_dev_assets__get_cache_root : the directory every pin's cache lives in.
ai_tools_dev_assets__get_cache_root() { printf '%s/ai-tools-dev' "${XDG_CACHE_HOME:-${HOME}/.cache}"; }

# _ai_tools_dev_assets__get_cache_dir : the cache directory of the pin read last.
_ai_tools_dev_assets__get_cache_dir() {
    printf '%s/%s.%s' "$(ai_tools_dev_assets__get_cache_root)" "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" \
        "${AI_TOOLS_DEV_ASSETS__PIN_SHA256:0:16}"
}

# _ai_tools_dev_assets__fetch_file <url> <out> : download over HTTPS alone, retried, to a file.
_ai_tools_dev_assets__fetch_file() {
    curl -fsSL --proto '=https' --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 -o "$2" "$1" 2>/dev/null
}

# _ai_tools_dev_assets__verify_archive <dir> : hold the archive of the pin read last, in <dir> with its .sha256
# and .asc, to the pin's sha256, the published one and a VALIDSIG by the package-signing primary. Returns 1
# with the reason.
_ai_tools_dev_assets__verify_archive() {
    local dir="$1" archive="${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" want="${AI_TOOLS_DEV_ASSETS__PIN_SHA256}" got published status
    [[ -f "${dir}/${archive}" && -f "${dir}/${archive}.sha256" && -f "${dir}/${archive}.asc" ]] \
        || { _ai_tools_dev_assets__refuse "${archive}: the archive, its .sha256 or its .asc is absent"; return 1; }
    got="$(sha256sum < "${dir}/${archive}" | cut -c1-64)"
    [[ "${got}" == "${want}" ]] || { _ai_tools_dev_assets__refuse "${archive} does not match the pin's sha256"; return 1; }
    published="$(cut -c1-64 < "${dir}/${archive}.sha256")"
    [[ "${published}" == "${want}" ]] \
        || { _ai_tools_dev_assets__refuse "the release publishes ${published:-nothing} for ${archive}, the pin ${want}"; return 1; }
    bash -c '. "$1" >/dev/null 2>&1 && ai_tools_assets_verify__write_binary_keyring "$2" "$3"' _ \
        "${_AI_TOOLS_DEV_ASSETS__LIB_DIR}/assets-verify.lib.sh" "${_AI_TOOLS_DEV_ASSETS__SIGNING_KEY}" "${dir}/keyring.gpg" \
        || { _ai_tools_dev_assets__refuse "${archive}: the package-signing key did not dearmor into a keyring"; return 1; }
    status="$(gpgv --status-fd 1 --keyring "${dir}/keyring.gpg" "${dir}/${archive}.asc" "${dir}/${archive}" 2>/dev/null)" \
        || { rm -f -- "${dir}/keyring.gpg"; _ai_tools_dev_assets__refuse "gpgv refuses the signature over ${archive}"; return 1; }
    rm -f -- "${dir}/keyring.gpg"
    grep -qE "^\[GNUPG:\] VALIDSIG .* ${_AI_TOOLS_DEV_ASSETS__SIGNING_PRIMARY}$" <<< "${status}" \
        || { _ai_tools_dev_assets__refuse "${archive} is not signed by the primary ${_AI_TOOLS_DEV_ASSETS__SIGNING_PRIMARY}"; return 1; }
    return 0
}

# _ai_tools_dev_assets__unpack <name> <dir> : unpack the verified archive in <dir> into <dir>/tree -- the zip's root
# for core, the archive's one top directory for tools -- and, for core, hold the tree to its inventory. Returns 1
# with the reason.
_ai_tools_dev_assets__unpack() {
    local name="$1" dir="$2" archive="${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" top
    local -a tops=()
    if [[ "${name}" == core ]]; then
        python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
            "${dir}/${archive}" "${dir}/tree" 2>/dev/null \
            || { _ai_tools_dev_assets__refuse "${archive} did not unpack"; return 1; }
        bash -c '. "$1" >/dev/null 2>&1 && ai_tools_assets_verify__verify_inventory "$2"' _ \
            "${_AI_TOOLS_DEV_ASSETS__LIB_DIR}/assets-verify.lib.sh" "${dir}/tree" >/dev/null 2>&1 \
            || { _ai_tools_dev_assets__refuse "${archive}: the unpacked tree does not match its SHA256SUMS"; return 1; }
        return 0
    fi
    if ! mkdir "${dir}/unpack" || ! tar -xzf "${dir}/${archive}" -C "${dir}/unpack" --no-same-owner 2>/dev/null; then
        _ai_tools_dev_assets__refuse "${archive} did not unpack"; return 1
    fi
    mapfile -t tops < <(find "${dir}/unpack" -mindepth 1 -maxdepth 1)
    top="${tops[0]:-}"
    if (( ${#tops[@]} != 1 )) || [[ ! -d "${top}" || -L "${top}" ]]; then
        _ai_tools_dev_assets__refuse "${archive} does not hold one top directory"; return 1
    fi
    mv -- "${top}" "${dir}/tree" && rmdir -- "${dir}/unpack"
}

# _ai_tools_dev_assets__verify_cached <name> <dir> : hold a cached pin in <dir> to its pin and signature, and the core
# tree to its inventory. Returns 1 with the reason.
_ai_tools_dev_assets__verify_cached() {
    local name="$1" dir="$2"
    _ai_tools_dev_assets__verify_archive "${dir}" || return 1
    if [[ "${name}" == core ]] && ! bash -c '. "$1" >/dev/null 2>&1 && ai_tools_assets_verify__verify_inventory "$2"' _ \
            "${_AI_TOOLS_DEV_ASSETS__LIB_DIR}/assets-verify.lib.sh" "${dir}/tree" >/dev/null 2>&1; then
        _ai_tools_dev_assets__refuse "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}: the cached tree does not match its SHA256SUMS"
        return 1
    fi
    return 0
}

# ai_tools_dev_assets__fetch <core|tools> : download, verify and unpack one pin into the cache; a cache directory
# already present is verified again (_ai_tools_dev_assets__verify_cached) and kept, and replaced where it fails. Returns
# 1 with the reason and the archive name.
ai_tools_dev_assets__fetch() {
    local name="$1" cache_root final stage url
    ai_tools_dev_assets__read_pin "${name}" || return 1
    cache_root="$(ai_tools_dev_assets__get_cache_root)"; final="$(_ai_tools_dev_assets__get_cache_dir)"
    if [[ -d "${final}/tree" ]] && _ai_tools_dev_assets__verify_cached "${name}" "${final}" 2>/dev/null; then
        printf 'assets: %s is in the cache at %s\n' "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" "${final}"
        return 0
    fi
    if ! ( umask 077; mkdir -p -- "${cache_root}" ) || ! chmod 0700 -- "${cache_root}"; then
        _ai_tools_dev_assets__refuse "${cache_root} could not be created at 0700"; return 1
    fi
    stage="$(mktemp -d "${cache_root}/.fetch.XXXXXX")" || { _ai_tools_dev_assets__refuse "no staging directory under ${cache_root}"; return 1; }
    url="$(_ai_tools_dev_assets__get_release_url "${name}" "${AI_TOOLS_DEV_ASSETS__PIN_TAG}")"
    local suffix
    for suffix in "" .sha256 .asc; do
        if ! _ai_tools_dev_assets__fetch_file "${url}/${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}${suffix}" \
                "${stage}/${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}${suffix}"; then
            rm -rf -- "${stage}"
            _ai_tools_dev_assets__refuse "cannot download ${url}/${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}${suffix}"; return 1
        fi
    done
    if ! _ai_tools_dev_assets__verify_archive "${stage}" || ! _ai_tools_dev_assets__unpack "${name}" "${stage}"; then
        rm -rf -- "${stage}"; return 1
    fi
    rm -rf -- "${final}"
    if ! mv -T -- "${stage}" "${final}" || ! chmod 0700 -- "${final}"; then
        rm -rf -- "${stage}"; _ai_tools_dev_assets__refuse "${final} could not be put in place"; return 1
    fi
    printf 'assets: %s verified and unpacked at %s\n' "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}" "${final}"
}

# ai_tools_dev_assets__verify <core|tools> : hold the cached archive of one pin to the pin and its signature,
# and the core tree to its inventory, without a download. Returns 1 with the reason; a pin not in the cache names
# the fetch command.
ai_tools_dev_assets__verify() {
    local name="$1" final
    ai_tools_dev_assets__read_pin "${name}" || return 1
    final="$(_ai_tools_dev_assets__get_cache_dir)"
    [[ -d "${final}/tree" ]] \
        || { _ai_tools_dev_assets__refuse "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE} is not in the cache; run: ${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}"; return 1; }
    _ai_tools_dev_assets__verify_cached "${name}" "${final}" || return 1
    printf 'assets: %s verifies against the pin and the package-signing key\n' "${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}"
}

# ai_tools_dev_assets__resolve_path <core|tools> : print the directory one pin unpacked to, from the cache alone,
# or the checkout AI_TOOLS_DEV_ASSETS_CORE / AI_TOOLS_DEV_ASSETS_TOOLS names, with a BYPASS line on stderr. Returns 1
# without a line on stdout for a pin that does not read, a pin not in the cache, or a checkout that is not one.
ai_tools_dev_assets__resolve_path() {
    local name="$1" checkout="" tree final
    case "${name}" in
        core)  checkout="${AI_TOOLS_DEV_ASSETS_CORE:-}";  tree="${checkout}/sets/core" ;;
        tools) checkout="${AI_TOOLS_DEV_ASSETS_TOOLS:-}"; tree="${checkout}" ;;
        *) _ai_tools_dev_assets__refuse "no pin is named ${name} (core or tools)"; return 1 ;;
    esac
    if [[ -n "${checkout}" ]]; then
        if [[ "${name}" == core && ! -f "${tree}/set.conf" ]] || [[ "${name}" == tools && ! -d "${tree}/formatters" ]]; then
            _ai_tools_dev_assets__refuse "${checkout} is not a checkout of the ${name} pin's repository"; return 1
        fi
        printf 'assets: BYPASS -- %s resolved from the checkout %s at %s, not its pin\n' "${name}" "${checkout}" \
            "$(git -C "${checkout}" rev-parse --short HEAD 2>/dev/null || printf 'an unknown commit')" >&2
        printf '%s\n' "${tree}"
        return 0
    fi
    ai_tools_dev_assets__read_pin "${name}" || return 1
    final="$(_ai_tools_dev_assets__get_cache_dir)"
    [[ -d "${final}/tree" ]] || return 1
    printf '%s\n' "${final}/tree"
}

# ai_tools_dev_assets__resolve_tool <prose-check|ref-index|formatters|fixtures> : print the path of one tool inside
# the pin that carries it; returns 1 without a line where the pin does not resolve or the tree does not hold the tool.
ai_tools_dev_assets__resolve_tool() {
    local tree path
    case "$1" in
        prose-check) tree="$(ai_tools_dev_assets__resolve_path core)" || return 1
                     path="${tree}/skills/ai-tools-technical-writing/scripts/prose-check.py" ;;
        ref-index)   tree="$(ai_tools_dev_assets__resolve_path core)" || return 1
                     path="${tree}/skills/ai-tools-reftags/scripts/ref-index.py" ;;
        formatters)  tree="$(ai_tools_dev_assets__resolve_path tools)" || return 1
                     path="${tree}/formatters" ;;
        fixtures)    tree="$(ai_tools_dev_assets__resolve_path tools)" || return 1
                     path="${tree}/fixtures" ;;
        *) return 1 ;;
    esac
    [[ -e "${path}" ]] || return 1
    printf '%s\n' "${path}"
}

# _ai_tools_dev_assets__main <command> [name] : the command form.
_ai_tools_dev_assets__main() {
    local name status=0
    case "${1:-}" in
        fetch)  for name in core tools; do ai_tools_dev_assets__fetch "${name}" || status=1; done ;;
        verify) for name in core tools; do ai_tools_dev_assets__verify "${name}" || status=1; done ;;
        path)   [[ $# -eq 2 ]] || { printf 'usage: bash tools/lib/assets.sh path core|tools\n' >&2; return 2; }
                ai_tools_dev_assets__resolve_path "$2" || status=1 ;;
        *)      printf 'usage: bash tools/lib/assets.sh fetch | verify | path core|tools\n' >&2; return 2 ;;
    esac
    return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    _ai_tools_dev_assets__main "$@"
fi
