#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-paths.sh
# Hermetic check that every source path the installers read actually exists in the checkout.
#
# The gap this closes: a file moved inside src/ is caught for the RPM by rpmbuild (an unpackaged
# or missing source fails the build) and for the shell by shellcheck -- but install.sh and
# selinux/install-selinux.sh only *reference* their sources as strings, so a stale path is
# invisible until an operator runs the installer and it dies halfway through, having already
# written part of the system. That is the worst place to find out, so it is asserted here.
#
# Two shapes are checked, because both appear:
#   ${SCRIPT_DIR}/src/...      install.sh
#   ${DIR}/../src/...          selinux/install-selinux.sh
# A path carrying a shell variable (a loop over asset kinds) cannot be resolved statically; its
# longest literal prefix directory is checked instead, which still catches a whole tree moving.
#
# Pure text + filesystem: no root, no install, no command executed. Validates the repo sources; it
# skips outside a checkout, where there is no src/ to compare against.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "installers reference source paths that exist (unit)"

if [[ ! -d "${ROOT}/src" ]]; then
    skip "installer source paths" "not a source checkout (no ${ROOT}/src)"
    finish; exit
fi

# check_paths <file> <extractor-regex>: every match, minus its variable prefix, must exist.
check_paths() {
    local file="$1" pattern="$2" rel path literal missing=0 checked=0
    rel="${file#"${ROOT}/"}"
    if [[ ! -r "${file}" ]]; then
        skip "${rel}" "not readable"
        return
    fi
    while IFS= read -r path; do
        # Strip the leading variable reference to get a repo-relative path.
        path="${path#*src/}"; path="src/${path}"
        checked=$(( checked + 1 ))
        # shellcheck disable=SC2016  # matching a literal ${, not expanding one
        if [[ "${path}" == *'${'* ]]; then
            # Variable-bearing (a loop over kinds): assert the literal prefix directory instead.
            literal="${path%%\$\{*}"; literal="${literal%/}"
            [[ -d "${ROOT}/${literal}" ]] && continue
            fail "${rel}: ${literal}/ does not exist (from ${path})"
            missing=$(( missing + 1 ))
            continue
        fi
        [[ -e "${ROOT}/${path}" ]] && continue
        fail "${rel}: ${path} does not exist -- the installer would die mid-run"
        missing=$(( missing + 1 ))
    done < <(grep -oE "${pattern}" "${file}" | sort -u)
    if (( checked == 0 )); then
        fail "${rel}: no source paths matched the extractor -- the check has gone blind"
    elif (( missing == 0 )); then
        pass "${rel}: all ${checked} referenced source paths exist"
    fi
}

check_paths "${ROOT}/install.sh"                 '\$\{SCRIPT_DIR\}/src/[^"]+'
check_paths "${ROOT}/selinux/install-selinux.sh" '\$\{DIR\}/\.\./src/[^"]+'

finish
