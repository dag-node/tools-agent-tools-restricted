#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/lib/format-scope.sh -- the path patterns this repository formats, sourced by tools/format.sh
# and by tests/unit/prose-width.sh, so the formatter and the width gate read one scope. It holds the declarations alone;
# what each pattern covers, and why, is tools/format.sh's header. A pattern is matched against the path
# from the repository root, with `*` crossing a `/`.

AI_TOOLS_FORMAT_SCOPE__CONFIG_HEADERS='src/etc/*.conf'
# shellcheck disable=SC2034  # read by tools/format.sh and tests/unit/prose-width.sh
AI_TOOLS_FORMAT_SCOPE__PATTERNS=(
    '*.md'                                         # a page, for a person or for an agent
    '*.sh' '*.py' '*.el' '.githooks/*'             # a source file: its comment prose
    'selinux/policy/*.te' 'selinux/policy/*.if' 'selinux/policy/*.fc'   # a policy source: the same
    "${AI_TOOLS_FORMAT_SCOPE__CONFIG_HEADERS}"     # a config header, at 72
)
# shellcheck disable=SC2034  # read by tools/format.sh and tests/unit/prose-width.sh
AI_TOOLS_FORMAT_SCOPE__VENDORED=(
    'src/usr/local/lib/ai-tools/typesafe/*'        # the decide command, vendored from its signed release
)
