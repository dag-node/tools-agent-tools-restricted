#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/fill-comments.sh [--width N] <file>...
# Reflow the plain comment paragraphs of each file in place, at the column the repository's
# .dir-locals.el gives the file's mode (72 for a config file, 120 for a source file) or at
# --width, so no comment line ends on a tie word and none runs past the column. It is the
# formatter for what `prose-check.py --wrap` reports; the rule and what is left untouched are in
# tools/emacs/ai-tools-fill.el. Needs Emacs. Run it as `bash tools/fill-comments.sh`.
set -euo pipefail

usage() { printf 'usage: bash tools/fill-comments.sh [--width N] <file>...\n' >&2; exit 2; }

width=nil
declare -a files=()
while (( $# )); do
    case "$1" in
        --width) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; width="$2"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; files+=("$@"); break ;;
        -*) usage ;;
        *) files+=("$1"); shift ;;
    esac
done
(( ${#files[@]} )) || usage
command -v emacs >/dev/null 2>&1 || { printf 'fill-comments: emacs is not installed\n' >&2; exit 1; }

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/emacs/ai-tools-fill.el"
# The files ride in command-line-args-left, which the form drains so Emacs does not visit them
# itself afterwards.
emacs --batch -Q -l "${lib}" \
    --eval "(progn (dolist (f command-line-args-left) (ai-tools-fill-comments-file f ${width})) (setq command-line-args-left nil))" \
    "${files[@]}"
