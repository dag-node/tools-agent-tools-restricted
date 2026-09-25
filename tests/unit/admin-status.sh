#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-status.sh
# Unit test for the Version section of `ai-tools-admin status`: its Node line reads the enabled agents' stable launcher
# links through the same verdict `ai-tools status` renders (ai_tools_node_version_verdict, toolchain.lib.sh), so the two
# reports name one version for one host. What is asserted is the root report's rendering of that verdict against fixture
# links -- the version a link points into, the split line where two links disagree, and no claimed version where no link
# names one -- with the updater's stamp being the host's own and read alongside.
#
# The helper is SOURCED rather than run (its root check and its dispatch are guarded for that), in a fresh shell
# per case because the helper and the harness both declare SANDBOX_USER readonly, with the resolver's two hooks
# and AI_TOOLS_LAUNCHER_DIR pointed at fixtures in the testdir. Fixtures are root-owned 0644 in a 0755 directory,
# which the trust predicate admits, so this runs as root via sudo (suite contract); no agent package needs to be
# installed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"

section "ai-tools-admin status: the Node line reads the launcher links (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "admin status node line" "helper not readable (neither installed nor in a checkout)"; finish; exit
fi
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if ! bash -c 'set --; source "$1" >/dev/null 2>&1; declare -F status_node_version >/dev/null 2>&1' _ "${HELPER}"; then
    skip "admin status node line" "helper not sourceable or status_node_version absent (older helper?)"; finish; exit
fi

mktestdir
AGENTS_DIR="${TESTDIR}/agents.d"; CONF="${TESTDIR}/operator.conf"; LINKS="${TESTDIR}/bin"
mkdir -m 0755 "${AGENTS_DIR}" "${LINKS}"

# manifest <name> <launcher> : one agent manifest, root-owned 0644, enabled by default.
manifest() {
    printf 'npm_package=@fixture/%s\nlauncher=%s\ndefault_enable=yes\n' "$1" "$2" > "${AGENTS_DIR}/$1.conf"
    chmod 0644 "${AGENTS_DIR}/$1.conf"
}
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${CONF}"; chmod 0644 "${CONF}"
# vlink <launcher> <version> : a stable link in the shape ai-tools-launcher-symlink writes, dangling on purpose.
vlink() { ln -sfn "/nonexistent/.nvm/versions/node/${2}/bin/${1}" "${LINKS}/${1}"; }
reset_fixtures() { rm -f "${AGENTS_DIR}"/*.conf "${LINKS}"/*; }

# call : source the helper with the hooks set and run status_node_version; both streams on stdout. The services library
# is sourced beside it, as status() does before the section runs, so the stamp branch is exercised too.
# shellcheck disable=SC2016  # the $1/$2 are for the inner `bash -c`, not this shell -- do not expand here
call() {
    env AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        bash -c 'helper="$1"; lib="$2"; set --; source "${helper}" >/dev/null 2>&1 || exit 99
                 source "${lib}" 2>/dev/null || true; status_node_version' _ "${HELPER}" "${SERVICES_LIB}" 2>&1
}

reset_fixtures; manifest alpha la; vlink la v9.9.9
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qE '^ +node +v9\.9\.9' <<<"${out}"; then
    pass "the Node line names the version the enabled agent's launcher link points into"
else
    fail "Node line from one link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

reset_fixtures; manifest alpha la; manifest beta lb; vlink la v9.9.9; vlink lb v9.9.8
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qF 'alpha=v9.9.9 beta=v9.9.8' <<<"${out}" && grep -q 'different Node versions' <<<"${out}"; then
    pass "links naming different versions are reported as such, each agent named"
else
    fail "Node line from disagreeing links (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

reset_fixtures; manifest alpha la; ln -s /nonexistent/la "${LINKS}/la"
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && ! grep -q 'v9' <<<"${out}" && ! grep -q 'active' <<<"${out}"; then
    pass "a link outside the versioned shape names no version, and the line does not claim one"
else
    fail "Node line from an unversioned link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

finish
