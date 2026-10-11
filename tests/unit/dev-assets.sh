#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/dev-assets.sh
# Unit test for tools/lib/assets.sh, which resolves this repository's prose checker, reftags tool and formatters
# from two pinned, signed releases into a per-user cache. What it holds is that a tool is read from the pin alone: every
# way an archive can differ from what its pin and its signature say -- a sha256 other than the pin's, a published sha256
# other than the pin's, a signature by a key the package-signing primary is not, a tree that no longer matches its
# inventory, a pin carrying a line outside its keys -- refuses with the reason and does not leave a cache directory
# a later `path` would read, while `path` prints nothing and exits 1 for a pin not in the cache. And the callers do not
# read a fallback: with the cache empty the git hooks name the fetch command and let the commit through, while
# the formatter front door and the reftags wrapper exit 1 with it.
#
# Hermetic: the cache is under a home in the testdir, the download is a stub serving files from the testdir, and a pin
# is read from the testdir. The control archives are the ones `bash tools/lib/assets.sh fetch` placed in the invoking
# user's own cache, copied and never written; without them the cases that need a genuine release skip naming
# the command. The throwaway-key case needs gpg. Runs unprivileged.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/tools/lib/assets.sh"
section "dev assets: the development tools are read from their pins alone (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "dev assets" "${LIB} is absent"; finish; exit
fi
for tool in python3 gpgv sha256sum tar git; do
    command -v "${tool}" >/dev/null 2>&1 || { skip "dev assets" "${tool} is not installed"; finish; exit; }
done

mktestdir
HOME_DIR="${TESTDIR}/home"; PINS="${TESTDIR}/pins"; RELEASE="${TESTDIR}/release"
mkdir -p "${HOME_DIR}" "${PINS}" "${RELEASE}"

# The control archives, from the invoking user's cache, each found by its pin.
# shellcheck source=SCRIPTDIR/../../tools/lib/assets.sh
source "${LIB}"
CONTROL=1
for name in core tools; do
    ai_tools_dev_assets__read_pin "${name}"
    cached="$(ai_tools_dev_assets__get_cache_root)/${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}.${AI_TOOLS_DEV_ASSETS__PIN_SHA256:0:16}"
    for suffix in "" .sha256 .asc; do
        cp "${cached}/${AI_TOOLS_DEV_ASSETS__PIN_ARCHIVE}${suffix}" "${RELEASE}/" 2>/dev/null || CONTROL=0
    done
    cp "$(ai_tools_dev_assets__get_pin_path "${name}")" "${PINS}/assets-${name}.pin"
done

# dev <words>... : run the library's command form in a shell of its own, with the home and the pins in the testdir
# and a download that serves the testdir's release files; stdout in OUT, stderr in ERR, the status in RC. STUB,
# when set, replaces the download stub.
OUT=""; ERR=""; RC=0; STUB=""
dev() {
    local err="${TESTDIR}/err"
    RC=0
    # shellcheck disable=SC2016  # the inner shell's own expansions
    OUT="$(env -u XDG_CACHE_HOME HOME="${HOME_DIR}" bash -c 'lib="$1"; pins="$2"; release="$3"; stub="$4"; shift 4
        source "${lib}"
        ai_tools_dev_assets__get_pin_path() { case "$1" in core|tools) printf "%s/assets-%s.pin" "${pins}" "$1" ;; *) return 1 ;; esac; }
        _ai_tools_dev_assets__fetch_file() { cp -- "${release}/${1##*/}" "$2" 2>/dev/null; }
        eval "${stub}"
        _ai_tools_dev_assets__main "$@"' _ "${LIB}" "${PINS}" "${RELEASE}" "${STUB:-:}" "$@" 2>"${err}")" || RC=$?
    ERR="$(<"${err}")"
}
cache_dirs() { find "${HOME_DIR}/.cache/ai-tools-dev" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort; }
# reset_cache : remove the fixture cache; its trees are read-only, which an unprivileged run must undo first.
reset_cache() { chmod -R u+w "${HOME_DIR}/.cache" 2>/dev/null || true; rm -rf "${HOME_DIR}/.cache"; }
# set_pin <name> <key> <value> : rewrite one key of a fixture pin.
set_pin() { sed -i "s|^$2=.*|$2=$3|" "${PINS}/assets-$1.pin"; }
restore_pins() { local name; for name in core tools; do cp "$(ai_tools_dev_assets__get_pin_path "${name}")" "${PINS}/assets-${name}.pin"; done; }

# ── A pin is data, read whole ────────────────────────────────────────────────────────────────────────────────────────
section "dev assets: a pin outside its three keys refuses"
# pin_refused <what> <reason> : the last run refused naming <reason>, and did not create a cache directory.
pin_refused() {
    if [[ "${RC}" != 0 && -z "${OUT}" && "${ERR}" == *"$2"* && -z "$(cache_dirs)" ]]; then
        pass "$1: refused, naming it"
    else
        fail "$1: rc ${RC}, out '${OUT}', err '${ERR:0:200}'"
    fi
}
reset_cache
printf 'command=curl evil\n' >> "${PINS}/assets-core.pin"; dev path core
pin_refused "a line outside tag, archive and archive_sha256" "a line outside"
restore_pins; printf 'tag=core/v9.9.9\n' >> "${PINS}/assets-core.pin"; dev path core
pin_refused "a key set twice" "set twice"
restore_pins; set_pin core archive_sha256 "D1B5"; dev path core
pin_refused "a sha256 that is not 64 lowercase hex digits" "archive_sha256"
restore_pins; set_pin tools archive "../../etc/passwd"; dev path tools
pin_refused "an archive outside the release's naming" "archive is absent or outside"
restore_pins

# ── path reads the cache alone ───────────────────────────────────────────────────────────────────────────────────────
section "dev assets: path resolves from the cache alone"
reset_cache; dev path core
if [[ "${RC}" == 1 && -z "${OUT}" ]]; then
    pass "a pin not in the cache: path prints no line and exits 1"
else
    fail "path over an empty cache: rc ${RC}, out '${OUT}'"
fi
mkdir -p "${TESTDIR}/a-checkout/sets/core" "${TESTDIR}/t-checkout/formatters"; : > "${TESTDIR}/a-checkout/sets/core/set.conf"
RC=0; OUT="$(AI_TOOLS_DEV_ASSETS_CORE="${TESTDIR}/a-checkout" HOME="${HOME_DIR}" bash "${LIB}" path core 2>"${TESTDIR}/err")" || RC=$?
ERR="$(<"${TESTDIR}/err")"
if [[ "${RC}" == 0 && "${OUT}" == "${TESTDIR}/a-checkout/sets/core" && "${ERR}" == *BYPASS*"${TESTDIR}/a-checkout"* ]]; then
    pass "AI_TOOLS_DEV_ASSETS_CORE: the checkout's sets/core, with a BYPASS line naming it"
else
    fail "the core bypass: rc ${RC}, out '${OUT}', err '${ERR}'"
fi
RC=0; OUT="$(AI_TOOLS_DEV_ASSETS_TOOLS="${TESTDIR}/t-checkout" HOME="${HOME_DIR}" bash "${LIB}" path tools 2>"${TESTDIR}/err")" || RC=$?
ERR="$(<"${TESTDIR}/err")"
if [[ "${RC}" == 0 && "${OUT}" == "${TESTDIR}/t-checkout" && "${ERR}" == *BYPASS* ]]; then
    pass "AI_TOOLS_DEV_ASSETS_TOOLS: the checkout, with a BYPASS line"
else
    fail "the tools bypass: rc ${RC}, out '${OUT}', err '${ERR}'"
fi
RC=0; OUT="$(AI_TOOLS_DEV_ASSETS_TOOLS="${TESTDIR}/a-checkout" HOME="${HOME_DIR}" bash "${LIB}" path tools 2>/dev/null)" || RC=$?
if [[ "${RC}" == 1 && -z "${OUT}" ]]; then
    pass "a bypass naming a directory that is not a checkout of that repository resolves nothing"
else
    fail "a wrong checkout: rc ${RC}, out '${OUT}'"
fi

# ── fetch and verify over a genuine release ──────────────────────────────────────────────────────────────────────────
section "dev assets: an archive is accepted on its pin and its signature alone"
if (( ! CONTROL )); then
    skip "fetch and verify" "the pinned releases are not in this user's cache; run: ${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}"
else
    reset_cache; dev fetch
    if [[ "${RC}" == 0 && "$(cache_dirs | wc -l)" == 2 ]]; then
        pass "control: both pins fetch, verify and unpack"
    else
        fail "control fetch: rc ${RC}, ${ERR:0:300}"
    fi
    if [[ "$(stat -c '%a' "${HOME_DIR}/.cache/ai-tools-dev")" == 700 ]] \
            && [[ -z "$(find "${HOME_DIR}/.cache/ai-tools-dev" -mindepth 1 -maxdepth 1 ! -perm 0700)" ]]; then
        pass "the cache and each pin's directory are 0700, under the user's own home"
    else
        fail "the cache modes: $(find "${HOME_DIR}/.cache/ai-tools-dev" -maxdepth 1 -printf '%m %p\n')"
    fi
    dev path core
    if [[ "${RC}" == 0 && -f "${OUT}/skills/ai-tools-technical-writing/scripts/prose-check.py" ]]; then
        pass "path prints the unpacked tree, holding the checker"
    else
        fail "path after a fetch: rc ${RC}, out '${OUT}'"
    fi
    dev verify
    [[ "${RC}" == 0 ]] && pass "control: verify accepts both cached archives" || fail "control verify: rc ${RC}, ${ERR:0:300}"
    # A tool run or imported from the cache leaves the tree as it was: Python writes a module's byte-code beside it only
    # where the directory takes a write, which a read-only tree does not.
    tree="$(env -u XDG_CACHE_HOME HOME="${HOME_DIR}" bash "${LIB}" path core 2>/dev/null)" || tree=""
    python3 "${tree}/skills/ai-tools-technical-writing/scripts/prose-check.py" "${tree}/skills/ai-tools-reftags/SKILL.md" >/dev/null 2>&1 || true
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import importlib.util as u
s = u.spec_from_file_location("prose_check", sys.argv[1] + "/prose-check.py"); m = u.module_from_spec(s); s.loader.exec_module(m)' \
        "${tree}/skills/ai-tools-technical-writing/scripts" >/dev/null 2>&1 || true
    dev verify
    if [[ "${RC}" == 0 && -z "$(find "${tree}" -name __pycache__ -print -quit)" ]] \
            && [[ -z "$(find "${tree}" ! -type l -perm /222 -print -quit)" ]]; then
        pass "the unpacked tree is read-only, so a tool run and imported from it leaves the inventory whole"
    else
        fail "a tool run from the cache changed the tree: rc ${RC}, ${ERR:0:200}"
    fi

    # refused <what> <reason> : the last fetch of core refused naming <reason> and left no cache directory for core
    # and no staging directory behind.
    refused() {
        if [[ "${RC}" != 0 && "${ERR}" == *"$2"* && "$(cache_dirs)" != *core* && "$(cache_dirs)" != *.fetch.* ]]; then
            pass "$1: refused, naming it, and nothing left in the cache"
        else
            fail "$1: rc ${RC}, cache '$(cache_dirs | tr '\n' ' ')', err '${ERR:0:300}'"
        fi
    }
    reset_cache; restore_pins
    set_pin core archive_sha256 "$(sed -n 's/^archive_sha256=//p' "${PINS}/assets-core.pin" | tr '0-9a-f' '1-9a-f0')"
    sed "s/^[0-9a-f]*/$(sed -n 's/^archive_sha256=//p' "${PINS}/assets-core.pin")/" "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256" \
        > "${TESTDIR}/published"
    cp "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256" "${TESTDIR}/published.orig"
    cp "${TESTDIR}/published" "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256"
    dev fetch
    refused "an archive whose sha256 is not the pin's, though the release publishes the pin's" "does not match the pin's sha256"
    cp "${TESTDIR}/published.orig" "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256"; restore_pins
    printf '%064d  ai-tools-assets-core-0.1.0.zip\n' 0 > "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256"
    reset_cache; dev fetch
    refused "a release whose published sha256 is not the pin's" "the release publishes"
    cp "${TESTDIR}/published.orig" "${RELEASE}/ai-tools-assets-core-0.1.0.zip.sha256"
    STUB='_ai_tools_dev_assets__fetch_file() { [[ "$1" != *.asc ]] && cp -- "${release}/${1##*/}" "$2"; }'
    reset_cache; dev fetch; STUB=""
    refused "a release without its signature" "cannot download"

    if command -v gpg >/dev/null 2>&1; then
        gnupg="${TESTDIR}/gnupg"; mkdir -m 0700 "${gnupg}"
        GNUPGHOME="${gnupg}" gpg --batch --quiet --passphrase '' --quick-gen-key 'ai-tools test <t@acme.example>' default default never 2>/dev/null
        cp "${RELEASE}/ai-tools-assets-core-0.1.0.zip.asc" "${TESTDIR}/asc.orig"
        GNUPGHOME="${gnupg}" gpg --batch --yes --armor --detach-sign -o "${RELEASE}/ai-tools-assets-core-0.1.0.zip.asc" \
            "${RELEASE}/ai-tools-assets-core-0.1.0.zip" 2>/dev/null
        reset_cache; dev fetch
        refused "an archive signed by a throwaway key, not the package-signing primary" "gpgv refuses the signature"
        cp "${TESTDIR}/asc.orig" "${RELEASE}/ai-tools-assets-core-0.1.0.zip.asc"
    else
        skip "a signature by a throwaway key" "gpg is not installed"
    fi

    reset_cache; dev fetch
    tree="$(env -u XDG_CACHE_HOME HOME="${HOME_DIR}" bash "${LIB}" path core 2>/dev/null)" || tree=""
    chmod u+w "${tree}/skills/ai-tools-technical-writing/SKILL.md"
    printf '\nan added line\n' >> "${tree}/skills/ai-tools-technical-writing/SKILL.md"
    dev verify
    if [[ "${RC}" == 1 && "${ERR}" == *"does not match its SHA256SUMS"* ]]; then
        pass "a cached tree edited after the unpack: verify refuses it against its inventory"
    else
        fail "an edited cached tree: rc ${RC}, ${ERR:0:300}"
    fi
    dev fetch
    if [[ "${RC}" == 0 ]] && ! grep -q 'an added line' "${tree}/skills/ai-tools-technical-writing/SKILL.md"; then
        pass "fetch replaces a cached tree that fails its inventory"
    else
        fail "fetch over an edited tree: rc ${RC}, ${ERR:0:300}"
    fi
fi

# ── The callers do not read a fallback ───────────────────────────────────────────────────────────────────────────────
section "dev assets: with the cache empty the hooks name fetch and let a commit through; the tools exit 1"
if ! git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    skip "the callers" "not a git checkout"
else
    empty="${TESTDIR}/empty-home"; mkdir -p "${empty}"
    # caller <what> <want-status> <command>... : run a caller from the checkout with an empty cache, the user's home
    # kept, since git reads its safe.directory list there.
    caller() {
        local what="$1" want="$2" rc=0 out
        shift 2
        out="$(cd "${ROOT}" && env -u AI_TOOLS_DEV_ASSETS_CORE -u AI_TOOLS_DEV_ASSETS_TOOLS \
            XDG_CACHE_HOME="${empty}" "$@" 2>&1)" || rc=$?
        if [[ "${rc}" == "${want}" && "${out}" == *"bash tools/lib/assets.sh fetch"* ]]; then
            pass "${what}: exit ${want}, naming the fetch command"
        else
            fail "${what}: exit ${rc}, want ${want}: ${out:0:300}"
        fi
    }
    printf 'test: a message\n' > "${TESTDIR}/message"
    caller "pre-commit" 0 bash .githooks/pre-commit
    caller "commit-msg" 0 bash .githooks/commit-msg "${TESTDIR}/message"
    caller "tools/format.sh" 1 bash tools/format.sh
    caller "tools/generators/ref-index.sh check" 1 bash tools/generators/ref-index.sh check
fi

# The testdir sweep runs ahead of every teardown command, so the read-only cache is opened here.
reset_cache
finish
