#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/format.sh -- this repository's front door to the width policy: the formatter of the pinned ai-tools-assets-tools
# release, run with the prose checker of the pinned asset set core and this repository's scope.
#
#     ```bash
#     bash tools/format.sh [--files | --all] [--width N] [--] [<file>...]
#     ```
#
# The formatter, its fillers and the checker are resolved through tools/lib/assets.sh, so no copy of either lives
# in this tree; with a pin not in the cache it exits 1 naming the fetch command. What the formatter does
# with the options is its own header's. tools/lib/format-scope.sh declares the three facts the formatter does not
# resolve from a path, each as `AI_TOOLS_FORMAT_SCOPE__<NAME>`, and tests/unit/prose-width.sh reads the same
# declarations, so the width gate measures the files this front door formats:
#
# - `PATTERNS`, the path patterns this repository owns: a page, a source file's comment prose, a policy source's,
#   a config header. A tracked file outside them -- a systemd unit, the spec, a Containerfile, a Makefile, a filter
#   rules file, the sudoers drop-in, a gitignore, a licence text, a signing key, a lockfile, a capture or a log -- is
#   data another program parses, and is left as written.
# - `CONFIG_HEADERS`: a `.conf` under `src/etc/` is a config header, read at 72. The sudoers drop-in beside them is
#   not one: its rule lines are read by sudo, not wrapped.
# - `VENDORED`: the decide command is a release another project signs, held byte for byte to
#   tools/generators/typesafe-client.pin, so it is out of every scope.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib/assets.sh
source "${ROOT}/tools/lib/assets.sh"
# shellcheck source=SCRIPTDIR/lib/format-scope.sh
source "${ROOT}/tools/lib/format-scope.sh"

if ! formatters="$(ai_tools_dev_assets__resolve_tool formatters)" \
        || ! checker="$(ai_tools_dev_assets__resolve_tool prose-check)"; then
    printf 'format: the formatter or the checker is not in the cache; run: %s\n' "${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}" >&2
    exit 1
fi

options=( --checker "${checker}" --config-header "${AI_TOOLS_FORMAT_SCOPE__CONFIG_HEADERS}" )
for pattern in "${AI_TOOLS_FORMAT_SCOPE__PATTERNS[@]}"; do options+=( --scope "${pattern}" ); done
for pattern in "${AI_TOOLS_FORMAT_SCOPE__VENDORED[@]}"; do options+=( --skip "${pattern}" ); done
exec bash "${formatters}/format.sh" "${options[@]}" "$@"
