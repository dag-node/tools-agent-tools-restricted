#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/format.sh -- the front door of the width policy: `bash tools/format.sh [--files | --all]
# [--width N] [<file>...]`. It asks the checker for each file's column and kind
# (`prose-check.py --print-width`) and dispatches to the filler for that kind -- tools/fill-comments.sh
# for a source comment or a config header, tools/fill-markdown.py for a page -- so the formatter
# does not hold a copy of the rule the checker resolves; a kind it has no filler for is reported
# and left.
# It closes by re-running the checker's width modes over what it touched, so what it could not fix
# is reported, and exits 1 while any of that remains.
#
# Scope: with no file, the paragraphs a diff touched -- `git diff -U0 HEAD` over the working tree
# and the index, each filler filling only a block meeting an added line -- so the diff it produces
# is bounded by what was edited. `--files` widens that to the whole of each changed file, `--all` to
# every tracked file after a warning, and a named file is filled whole. The tree formatted is the
# repository of the current directory; the checker and the fillers are this repository's, so a
# sibling checkout is formatted with the same tools.
#
# A `.conf` under src/etc/ is a config header, read at 72 through `--config-header`: that is this
# repository's layout, the one fact the checker cannot resolve from a path alone. The sudoers
# drop-in beside them is not one: its rule lines are read by sudo, not wrapped.
set -euo pipefail

usage() {
    printf 'usage: bash tools/format.sh [--files | --all] [--width N] [<file>...]\n' >&2
    exit 2
}

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${TOOLS}/../src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
CONFIG_HEADERS='src/etc/*.conf'

scope=touched
width=()
declare -a named=()
while (( $# )); do
    case "$1" in
        --files) scope=files; shift ;;
        --all) scope=all; shift ;;
        --width) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; width=(--width "$2"); shift 2 ;;
        -h|--help) usage ;;
        --) shift; named+=("$@"); break ;;
        -*) usage ;;
        *) named+=("$1"); shift ;;
    esac
done
command -v python3 >/dev/null 2>&1 || { printf 'format: python3 is not installed\n' >&2; exit 1; }
[[ -r "${CHECKER}" ]] || { printf 'format: the checker is not at %s\n' "${CHECKER}" >&2; exit 1; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'format: not inside a git repository\n' >&2; exit 1; }
cd "${root}"

# ── Scope: which files, and which of their lines ──────────────────────────────────────────────
# `ranges[<file>]` holds the added-line ranges of a touched file as `A-B,C-D`, or is unset where the
# file is filled whole.
declare -A ranges=()
declare -a files=()
has_head() { git rev-parse --verify -q HEAD >/dev/null 2>&1; }

# added_ranges <file>: the ranges of lines the working tree adds against HEAD, from the hunk
# headers of a zero-context diff; a hunk that only removes lines adds none.
added_ranges() {
    git diff -U0 HEAD -- "$1" 2>/dev/null | awk '
        /^@@/ { split($3, plus, ","); start = substr(plus[1], 2); count = (plus[2] == "" ? 1 : plus[2])
                if (count > 0) out = out (out == "" ? "" : ",") start "-" (start + count - 1) }
        END { printf "%s", out }'
}

if (( ${#named[@]} )); then
    files=("${named[@]}")
elif [[ "${scope}" == all ]]; then
    printf 'format: --all reflows every tracked file; review the diff by domain\n' >&2
    mapfile -t files < <(git ls-files)
else
    # The changed tracked files and the untracked ones; an untracked file is filled whole either way.
    declare -a changed=() untracked=()
    if has_head; then
        mapfile -t changed < <(git diff --name-only HEAD --diff-filter=AM)
    fi
    mapfile -t untracked < <(git ls-files --others --exclude-standard)
    for f in "${changed[@]}"; do
        [[ -f "${f}" ]] || continue
        files+=("${f}")
        if [[ "${scope}" == touched ]]; then
            r="$(added_ranges "${f}")"
            [[ -n "${r}" ]] && ranges["${f}"]="${r}"
        fi
    done
    files+=("${untracked[@]}")
fi
(( ${#files[@]} )) || { printf 'format: no file to format\n'; exit 0; }

# ── Dispatch: the checker names the column and the kind, the filler for the kind fills ─────────
declare -a documents=() sources=() headers=()
status=0
for f in "${files[@]}"; do
    header=()
    # shellcheck disable=SC2053  # the pattern side is the tool's own glob
    [[ "${f}" == ${CONFIG_HEADERS} ]] && header=(--config-header)
    IFS=$'\t' read -r _ column kind < <(python3 "${CHECKER}" --print-width "${header[@]}" "${width[@]}" -- "${f}" 2>/dev/null || true)
    lines=()
    [[ -n "${ranges[${f}]:-}" ]] && lines=(--lines "${ranges[${f}]}")
    case "${kind:-missing}" in
        document)
            python3 "${TOOLS}/fill-markdown.py" --width "${column}" "${lines[@]}" -- "${f}" || status=1
            documents+=("${f}") ;;
        source|header)
            # Emacs reports each file on stderr; a filler that could not run is reported there
            # too, and the lines it left are counted by the closing report.
            bash "${TOOLS}/fill-comments.sh" --width "${column}" "${lines[@]}" -- "${f}" || status=1
            if [[ "${kind}" == header ]]; then headers+=("${f}"); else sources+=("${f}"); fi ;;
        *)
            printf 'format: skipped %s (%s)\n' "${f}" "${kind:-missing}" ;;
    esac
done

# ── Report: what the fillers could not fix, measured by the checker ──────────────────────────
# The width findings alone, each with the line it names; `--wrap` also runs the default checks,
# which are a writing matter and not the formatter's.
report=""
if (( ${#documents[@]} + ${#sources[@]} )); then
    report+="$(python3 "${CHECKER}" --wrap "${width[@]}" -- "${documents[@]}" "${sources[@]}" \
        | grep -A1 -- '-width \[' || true)"
fi
if (( ${#headers[@]} )); then
    report+="${report:+$'\n'}$(python3 "${CHECKER}" --config-header "${width[@]}" -- "${headers[@]}" \
        | grep -A1 'header-width' || true)"
fi
remaining="$(grep -c -- '-width \[' <<< "${report}" || true)"
[[ -n "${report}" ]] && printf '%s\n' "${report}"
printf 'format: %d file(s) read, %d over-width line(s) left\n' "${#files[@]}" "${remaining}"
(( remaining == 0 && status == 0 )) || exit 1
