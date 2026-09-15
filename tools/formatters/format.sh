#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/formatters/format.sh -- the front door of the width policy.
#
# ```bash
# bash tools/formatters/format.sh [--files | --all] [--width N] [--] [<file>...]
# ```
#
# It asks the checker for each file's column and kind (`prose-check.py --print-width`) and dispatches to the filler
# for that kind -- `tools/formatters/fill-comments.sh` for a source comment or a config header,
# `tools/formatters/fill-markdown.py` for a page -- so the formatter does not hold a copy of the rule the checker
# resolves; a kind it has no filler for is reported and left. It closes by re-running the checker's width modes
# over what it touched, so what it could not fix is reported, and exits 1 while any of that remains, while a filler
# refused a file, or where the checker itself could not run -- a report that read an aborted run as a clean one would
# exit 0 over lines it never measured.
#
# Scope: with no file, the paragraphs a diff touched -- `git diff -U0 HEAD` over the working tree and the index, each
# filler filling only a block meeting an added line -- so the diff it produces is bounded by what was edited. `--files`
# widens that to the whole of each changed file, `--all` to every tracked file after a warning, and a named file is
# filled whole. The tree formatted is the repository of the current directory; the checker and the fillers are this
# repository's, so a sibling checkout is formatted with the same tools.
#
# What it formats is `FORMAT_SCOPE`, a list of path patterns this repository owns: a page, a source file's comment
# prose, a policy source's, a config header. A tracked file outside it -- a systemd unit, the spec, a Containerfile,
# a Makefile, a filter rules file, the sudoers drop-in, a gitignore, a licence text, a signing key, a lockfile,
# a capture or a log -- is data another program parses, and a fill would rewrap what that program reads, so every scope
# leaves it as written: `--all` and the diff scope count what they left, and a file named on the command line is
# reported and skipped. The checker's own kinds sit inside the scope: a man page, a binary and a generated file (one
# carrying the ignore-file marker) pass the pattern and are left by the dispatch. A pattern matches the path
# from the repository root, and `*` crosses a `/`.
#
# A `.conf` under `src/etc/` is a config header, read at 72 through `--config-header`: that is this repository's layout,
# the one fact the checker cannot resolve from a path alone. The sudoers drop-in beside them is not one: its rule lines
# are read by sudo, not wrapped.
#
# The body is one function, called on the last line: bash parses a function whole before running it, so this file is
# among the files `--all` fills. Read a command at a time, a script that is rewritten under a running bash is read
# on from the old offset, into the middle of a line.
set -euo pipefail

usage() {
    printf 'usage: bash tools/formatters/format.sh [--files | --all] [--width N] [--] [<file>...]\n' >&2
    exit 2
}

CONFIG_HEADERS='src/etc/*.conf'
FORMAT_SCOPE=(
    '*.md'                                         # a page, for a person or for an agent
    '*.sh' '*.py' '*.el' '.githooks/*'             # a source file: its comment prose
    'selinux/policy/*.te' 'selinux/policy/*.if' 'selinux/policy/*.fc'   # a policy source: the same
    "${CONFIG_HEADERS}"                            # a config header, at 72
)

# in_scope <path>: 0 when the root-relative <path> matches a pattern in FORMAT_SCOPE.
in_scope() {
    local pattern
    for pattern in "${FORMAT_SCOPE[@]}"; do
        # shellcheck disable=SC2053  # the pattern side is the tool's own glob
        [[ "$1" == ${pattern} ]] && return 0
    done
    return 1
}

# added_ranges <file>: the ranges of lines the working tree adds against HEAD, from the hunk headers of a zero-context
# diff; a hunk that only removes lines adds none.
added_ranges() {
    git diff -U0 HEAD -- "$1" 2>/dev/null | awk '
        /^@@/ { split($3, plus, ","); start = substr(plus[1], 2); count = (plus[2] == "" ? 1 : plus[2])
                if (count > 0) out = out (out == "" ? "" : ",") start "-" (start + count - 1) }
        END { printf "%s", out }'
}

main() {
    local tools checker root scope=touched status=0 outside=0 f rel r header column kind
    local -a width=() named=() files=() tracked=() changed=() untracked=() present=()
    local -a documents=() sources=() headers=() lines=()
    tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    checker="${tools}/../../src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
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
    [[ -r "${checker}" ]] || { printf 'format: the checker is not at %s\n' "${checker}" >&2; exit 1; }
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'format: not inside a git repository\n' >&2; exit 1; }

    # ── Scope: which files, and which of their lines ──────────────────────────────────────────
    # `ranges[<file>]` holds the added-line ranges of a touched file as `A-B,C-D`, or is unset where the file is filled
    # whole. Every path in `files` is relative to the repository root.
    local -A ranges=()

    # scoped <path>...: the paths in FORMAT_SCOPE, appended to `files`; the others are counted.
    scoped() {
        local f
        for f in "$@"; do
            if in_scope "${f}"; then files+=("${f}"); else outside=$((outside + 1)); fi
        done
    }

    # A named path is read from where the command was run and taken to the root, without resolving a symlink:
    # the vetting in each filler refuses one, and a path it names must be the path it
    # read.
    for f in "${named[@]}"; do
        rel="$(realpath -s --relative-to="${root}" -- "${f}" 2>/dev/null)" || rel="${f}"
        if [[ "${rel}" == /* || "${rel}" == ../* || "${rel}" == .. ]]; then
            printf 'format: skipped %s (outside the repository)\n' "${f}"
        elif ! in_scope "${rel}"; then
            printf 'format: skipped %s (outside the scope)\n' "${f}"
        else
            files+=("${rel}")
        fi
    done
    cd "${root}"

    if (( ${#named[@]} )); then
        :
    elif [[ "${scope}" == all ]]; then
        printf 'format: --all reflows every tracked file in the scope; review the diff by domain\n' >&2
        mapfile -d '' -t tracked < <(git ls-files -z)
        scoped "${tracked[@]}"
    else
        # The changed tracked files and the untracked ones; an untracked file is filled whole either
        # way.
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
            mapfile -d '' -t changed < <(git diff --name-only -z HEAD --diff-filter=AM)
        fi
        mapfile -d '' -t untracked < <(git ls-files -z --others --exclude-standard)
        for f in "${changed[@]}"; do [[ -f "${f}" ]] && present+=("${f}"); done
        scoped "${present[@]}" "${untracked[@]}"
        if [[ "${scope}" == touched ]]; then
            for f in "${present[@]}"; do
                r="$(added_ranges "${f}")"
                [[ -n "${r}" ]] && ranges["${f}"]="${r}"
            done
        fi
    fi
    (( outside == 0 )) || printf 'format: %d file(s) outside the scope left as written\n' "${outside}"
    (( ${#files[@]} )) || { printf 'format: no file to format\n'; exit 0; }

    # ── Dispatch: the checker names the column and the kind, the filler for the kind fills ─────
    # A file a filler refused is counted in the exit status and kept out of the closing report, which measures only
    # what was read whole.
    for f in "${files[@]}"; do
        header=()
        # shellcheck disable=SC2053  # the pattern side is the tool's own glob
        [[ "${f}" == ${CONFIG_HEADERS} ]] && header=(--config-header)
        IFS=$'\t' read -r _ column kind < <(python3 "${checker}" --print-width "${header[@]}" "${width[@]}" -- "${f}" 2>/dev/null || true)
        lines=()
        [[ -n "${ranges[${f}]:-}" ]] && lines=(--lines "${ranges[${f}]}")
        case "${kind:-missing}" in
            document)
                if python3 "${tools}/fill-markdown.py" --width "${column}" "${lines[@]}" -- "${f}"; then
                    documents+=("${f}")
                else
                    status=1
                fi ;;
            source|header)
                # Emacs reports each file on stderr; a filler that could not run, or a file it refused, is reported
                # there too.
                if bash "${tools}/fill-comments.sh" --width "${column}" "${lines[@]}" -- "${f}"; then
                    if [[ "${kind}" == header ]]; then headers+=("${f}"); else sources+=("${f}"); fi
                else
                    status=1
                fi ;;
            *)
                printf 'format: skipped %s (%s)\n' "${f}" "${kind:-missing}" ;;
        esac
    done

    # ── Report: what the fillers could not fix, measured by the checker ──────────────────────
    # The width findings alone, each with the line it names; `--wrap` also runs the default checks, which are a writing
    # matter and not the formatter's.

    # checker_report <finding-pattern> <checker-argument>...: the findings matching the pattern, or a failure
    # where the checker could not run -- an exit other than 0 or 1 (its findings status), or anything on stderr.
    checker_report() {
        local pattern="$1" out rc=0 err
        shift
        err="$(mktemp)"
        out="$(python3 "${checker}" "$@" 2>"${err}")" || rc=$?
        if (( rc > 1 )) || [[ -s "${err}" ]]; then
            printf 'format: the checker failed (exit %d): %s\n' "${rc}" "$(head -c 300 "${err}")" >&2
            rm -f "${err}"
            return 1
        fi
        rm -f "${err}"
        grep -A1 -- "${pattern}" <<< "${out}" || true
    }
    local report="" part="" remaining
    if (( ${#documents[@]} + ${#sources[@]} )); then
        report+="$(checker_report '-width \[' --wrap "${width[@]}" -- "${documents[@]}" "${sources[@]}")" || status=1
    fi
    if (( ${#headers[@]} )); then
        part="$(checker_report 'header-width' --config-header "${width[@]}" -- "${headers[@]}")" || status=1
        report+="${report:+$'\n'}${part}"
    fi
    remaining="$(grep -c -- '-width \[' <<< "${report}" || true)"
    [[ -n "${report}" ]] && printf '%s\n' "${report}"
    printf 'format: %d file(s) read, %d over-width line(s) left\n' "${#files[@]}" "${remaining}"
    (( remaining == 0 && status == 0 )) || exit 1
    exit 0
}

main "$@"
