#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/license-texts.sh
# Holds each licence text under LICENSES/ to the SPDX License List's copy of it -- the text `reuse download <id>`
# writes, the variant the files' SPDX headers name -- by SHA-256, and the root LICENSE to LICENSES/AGPL-3.0-only.txt.
# REUSE lint checks that a licence file exists and does not read its text, so a copy taken from another publisher,
# a filled-in holder line or a reflow is reported here alone. The table pins one digest per identifier: a licence added
# under LICENSES/ without a pin fails until its digest is recorded, and a pin whose file is gone fails too. A copy
# with one byte changed is driven first, so the comparison shows it reports what it exists to report.
#
# Hermetic: the control copy is written in the test's own /tmp testdir. Pure text, no network, no privilege.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "license-texts: each licence text is the SPDX License List's copy (unit)"

if ! command -v sha256sum >/dev/null 2>&1; then
    skip "license-texts" "sha256sum not available"; finish; exit
fi
if [[ ! -d "${ROOT}/LICENSES" ]]; then
    skip "license-texts" "not a checkout (no ${ROOT}/LICENSES)"; finish; exit
fi

# The SHA-256 of spdx/license-list-data's text/<id>.txt, as `reuse download <id>` writes it.
declare -A SPDX_TEXT_SHA256=(
    [AGPL-3.0-only]=d8a6cc31abc16b6748c7a21f21611f5a1ec33f67d22ca23d7da1c19b95496bee
    [CC-BY-4.0]=d557539df68e771cc1eedcc91d13f70fca930e508d11eedcafa4b15db49e3744
    [CC0-1.0]=a2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499
    [GPL-2.0-or-later]=aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3
    [MIT]=b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5
)

calculate_sha256() { sha256sum -- "$1" | cut -d' ' -f1; }

mktestdir

# ── A changed byte is reported ────────────────────────────────────────────────────────────────
cp -- "${ROOT}/LICENSES/MIT.txt" "${TESTDIR}/MIT.txt"
printf ' ' >> "${TESTDIR}/MIT.txt"
if [[ "$(calculate_sha256 "${TESTDIR}/MIT.txt")" != "${SPDX_TEXT_SHA256[MIT]}" ]]; then
    pass "TEST-LT-01-control: a copy with one byte appended no longer matches its pin"
else
    fail "TEST-LT-01-control: a changed copy still matched the MIT pin"
fi

# ── Every licence text matches its pin, and every pin has its text ──────────────────────────────
mismatched="" unpinned=""
for file in "${ROOT}"/LICENSES/*; do
    id="$(basename -- "${file}" .txt)"
    if [[ -z "${SPDX_TEXT_SHA256[${id}]:-}" ]]; then
        unpinned+=" LICENSES/${file##*/}"
    elif [[ "$(calculate_sha256 "${file}")" != "${SPDX_TEXT_SHA256[${id}]}" ]]; then
        mismatched+=" LICENSES/${file##*/}"
    fi
done
if [[ -z "${mismatched}" ]]; then
    pass "TEST-LT-02-pristine: each pinned licence text is the SPDX copy"
else
    fail "TEST-LT-02-pristine: differs from the SPDX copy (replace it with reuse download <id>):${mismatched}"
fi
if [[ -z "${unpinned}" ]]; then
    pass "TEST-LT-03-pinned: each file under LICENSES/ has a pin"
else
    fail "TEST-LT-03-pinned: no pin in this file for:${unpinned}"
fi
missing=""
for id in "${!SPDX_TEXT_SHA256[@]}"; do
    [[ -f "${ROOT}/LICENSES/${id}.txt" ]] || missing+=" ${id}"
done
if [[ -z "${missing}" ]]; then
    pass "TEST-LT-04-present: each pin has its file under LICENSES/"
else
    fail "TEST-LT-04-present: pinned with no file:${missing}"
fi

# ── The root LICENSE is the project licence's text ───────────────────────────────────────────────
if cmp -s -- "${ROOT}/LICENSE" "${ROOT}/LICENSES/AGPL-3.0-only.txt"; then
    pass "TEST-LT-05-root: LICENSE is LICENSES/AGPL-3.0-only.txt byte for byte"
else
    fail "TEST-LT-05-root: LICENSE differs from LICENSES/AGPL-3.0-only.txt"
fi

finish
