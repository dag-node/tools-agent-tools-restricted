#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Reflow the plain comment paragraphs of each file in place.
#
# ```bash
# bash tools/fill-comments.sh [--width N] [--lines A-B,C-D] [--] <file>...
# ```
#
# Each paragraph is wrapped at `--width`, or at the column `.dir-locals.el` gives the file's mode, and no line ends
# on a tie word (the `fill-nobreak-predicate` hook in `tools/emacs/ai-tools-fill.el`, which also states what is left
# as written). `--lines` names 1-based inclusive line ranges and fills only a paragraph meeting one. It is the comment
# half of the formatter `tools/format.sh` fronts, which passes the column and the ranges. Needs Emacs and python3.
#
# Each file is vetted through `tools/text_file.py` before Emacs sees it: one that is not plain text -- a symlink,
# a binary, a control or a bidi character -- is reported and left as it is, the others are filled, and the run exits 1.
# Emacs takes the files after `--`, so a name that reads as one of its own options (`-Q`, `-chdir`) is a file to fill
# rather than an option to obey.
#
# The body is one function, called on the last line: bash parses a function whole before running it, so this file may be
# among the files a run fills. Read a command at a time, a script that is rewritten under a running bash is read
# on from the old offset, into the middle of a line.
set -euo pipefail

usage() {
    printf 'usage: bash tools/fill-comments.sh [--width N] [--lines A-B,C-D] [--] <file>...\n' >&2
    exit 2
}

main() {
    local width=nil ranges=nil status=0 f reason lib
    local -a files=() accepted=() parts=()
    while (( $# )); do
        case "$1" in
            --width) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; width="$2"; shift 2 ;;
            --lines)
                [[ "${2:-}" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || usage
                # `A-B,C-D` as the elisp list ((A . B) (C . D)); a lone A is the pair (A . A).
                ranges="'("
                IFS=, read -ra parts <<< "$2"
                for part in "${parts[@]}"; do
                    ranges+="(${part%%-*} . ${part##*-}) "
                done
                ranges+=")"
                shift 2 ;;
            -h|--help) usage ;;
            --) shift; files+=("$@"); break ;;
            -*) usage ;;
            *) files+=("$1"); shift ;;
        esac
    done
    (( ${#files[@]} )) || usage
    command -v emacs >/dev/null 2>&1 || { printf 'fill-comments: emacs is not installed\n' >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { printf 'fill-comments: python3 is not installed\n' >&2; exit 1; }

    local tools
    tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    lib="${tools}/emacs/ai-tools-fill.el"

    for f in "${files[@]}"; do
        if reason="$(python3 "${tools}/text_file.py" -- "${f}" 2>&1)"; then
            accepted+=("${f}")
        else
            printf 'fill-comments: %s\n' "${reason}" >&2
            status=1
        fi
    done
    (( ${#accepted[@]} )) || exit "${status}"

    # The files ride in command-line-args-left after the `--`, which the form drains so Emacs does not visit them itself
    # afterwards.
    emacs --batch -Q -l "${lib}" \
        --eval "(progn (dolist (f (cdr (member \"--\" command-line-args-left))) (ai-tools-fill-comments-file f ${width} ${ranges})) (setq command-line-args-left nil))" \
        -- "${accepted[@]}" || status=1
    exit "${status}"
}

main "$@"
