#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/man-messages.sh -- generate ai-tools-messages(7) from the cross-reference index. The page is derived, never
# authored: every code, its severity, the command that emits it and the message text come from .claude/references.md,
# so the message keeps one home in the source that emits it.  The two maps this file holds -- emitting function
# to severity, source file to installed command -- are repository knowledge and stay here rather than in the shipped
# ref-index.py.
#
#     bash tools/man-messages.sh generate          rewrite the page from the index
#     bash tools/man-messages.sh print [<index>]   write the page to stdout, from the index given
#                                                  (default: the committed one); `tests/unit/man.sh`
#                                                  renders a fixture catalog through it
#     bash tools/man-messages.sh stale             exit 1 when the committed page differs from the index
#
# An emitting function the severity map does not name is a hard error: a new emitter is a decision about how its
# messages are classified, not something to guess at generation time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX=".claude/references.md"
# The page is excluded from the index's own inputs (tools/ref-index.sh `files`), so listing a code here does not count
# as citing it and the "documented in" pointer keeps meaning what it says.
PAGE="src/usr/local/share/man/man7/ai-tools-messages.7"
cd "${ROOT}"

# ── The two maps ──────────────────────────────────────────────────────────────────────────────
# Emitter to severity, over the emitting functions the tree uses today. ERROR is a refusal or a failure, WARNING
# a condition the operator acts on while the component continues, NOTICE progress. Read the live set off the index's
# emitter column with `awk -F'|' '/MSG-/ {print $7}' .claude/references.md | sort -u`.
SEVERITY_MAP='
die=ERROR reject=ERROR refuse=ERROR refuse_early=ERROR err=ERROR say_error=ERROR
ai_tools_msg_error=ERROR die_stop_usage=ERROR reject_with_usage=ERROR coded_refusal=ERROR
warn=WARNING _ai_tools_provider_warn=WARNING _ai_tools_conf_warn=WARNING say_warn=WARNING
ai_tools_msg_warn=WARNING
note=NOTICE say_notice=NOTICE
'

# Source file to the component an operator names it by: the four commands that are spelled differently from their file,
# the two installers, and otherwise the installed basename -- a libexec helper without its .sh, a shared library as it
# is installed.
COMPONENT_MAP='
src/usr/local/bin/ai-tools.sh=ai-tools
src/usr/local/libexec/ai-tools/ai-tools-admin.sh=ai-tools-admin
src/usr/local/lib/ai-tools/admin-commands.d/dotnet.sh=ai-tools-admin dotnet
src/usr/local/bin/claude.sh=claude
src/opt/ai-tools/bin/ai-tools-run.sh=ai-tools-run
install.sh=install.sh
selinux/install-selinux.sh=install-selinux.sh
'

# ── Extract: one tab-separated record per code ────────────────────────────────────────────────
# A name may carry an escaped pipe (\|), so the row is split on its UNESCAPED pipes alone: the escape is parked
# on a byte no index row contains, the row is split, and the byte is restored.
extract() {
    awk -F'\t' -v severity_map="${SEVERITY_MAP}" -v component_map="${COMPONENT_MAP}" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function load(spec, target,   n, i, parts, kv) {
        n = split(spec, parts, /\n/)
        for (i = 1; i <= n; i++) {
            if (trim(parts[i]) == "") continue
            # A line holds one or more key=value pairs; a component value may contain a space, so a map whose values do
            # is written one pair per line.
            if (target == "severity") { split(parts[i], kv, / /); for (j in kv) if (kv[j] != "") {
                    split(kv[j], p, /=/); sev[p[1]] = p[2] } }
            else { split(parts[i], p, /=/); comp[trim(p[1])] = trim(p[2]) }
        }
    }
    function component(file,   base) {
        if (file in comp) return comp[file]
        base = file; sub(/.*\//, "", base)
        if (base ~ /\.lib\.sh$/) return base
        sub(/\.sh$/, "", base)
        return base
    }
    BEGIN { load(severity_map, "severity"); load(component_map, "component") }
    /MSG-/ {
        row = $0
        gsub(/\\\|/, "\001", row)
        n = split(row, f, /\|/)
        if (n < 7) next
        reftag = trim(f[3]); message = trim(f[4]); file = trim(f[5])
        cited = trim(f[6]); emitter = trim(f[7])
        if (emitter == "") next                      # a reserved id, defining no message
        if (match(reftag, /MSG-[A-Z][0-9][A-Z][0-9]/) == 0) next
        code = substr(reftag, RSTART, RLENGTH)
        if (!(emitter in sev)) {
            printf("man-messages: %s emits %s, which the severity map does not name\n",
                   emitter, code) > "/dev/stderr"
            bad = 1; next
        }
        gsub(/\001/, "|", message)
        printf("%s\t%s\t%s\t%s\t%s\n", component(file), code, sev[emitter], message, cited)
    }
    END { if (bad) exit 1 }
    ' "${INDEX}"
}

# ── Render: the page ──────────────────────────────────────────────────────────────────────────
# A citation becomes a pointer: a shipped man page renders as a .BR cross-reference, any other document as its path
# in italics. `pointers` keeps the citations from documents and drops the ones from tests and source files, since
# an operator reads about a code in a manual and the index's cited-by column lists both kinds.
render() {
    cat <<'ROFF'
.\" ai-tools-messages(7) -- every message code Agent Tools Restricted emits.
.\" GENERATED from .claude/references.md by tools/man-messages.sh; do not edit this file. Change
.\" a message in the source that emits it and run `bash tools/man-messages.sh generate`;
.\" tests/unit/man.sh regenerates the page and fails on a difference.
.\" @AI_TOOLS_VERSION@ is substituted at deploy time (install.sh install_subst and the RPM
.\" %prep), like ai-tools-providers(5).
.TH AI-TOOLS-MESSAGES 7 "" "ai-tools @AI_TOOLS_VERSION@" "Agent Tools Restricted"
.SH NAME
ai-tools-messages \- message codes emitted by Agent Tools Restricted
.SH DESCRIPTION
Every refusal, warning, and notice this project prints to an operator carries a
message code: the letters
.BR MSG ,
a dash, and a four-character id, which stays fixed when the message text is
reworded.
The code is printed with the message, and a component that logs the line records
it in the journal as the
.B AI_TOOLS_MSG
field, so one code selects the message in both places:
.PP
.in +4n
.EX
.RB $ " journalctl AI_TOOLS_MSG=\fICODE\fR"
.EE
.in
.PP
This page lists every code the tree emits, grouped by the component that emits
it and ordered by code within each group.
An entry carries the code, its severity, and the message as the emitting call
writes it, so a message that interpolates a value shows the interpolation
.RB ( $1 ", " ${scope} )
rather than a sample of what it prints.
.PP
Severity names the emitting call rather than judging the message.
.B ERROR
is a refusal or a failure, and the component stops or declines what it was
asked to do;
.B WARNING
is a condition to act on, and the component continues;
.B NOTICE
is progress or information.
.PP
An entry names a document only where one cites its code.
The message text itself is not explained here: it has one home, in the source
that emits it, and a code that needs more than its own text is explained in the
manual for the component that emits it.
.SH CODES
ROFF
    local component="" last=""
    while IFS=$'\t' read -r component code severity message cited; do
        if [[ "${component}" != "${last}" ]]; then
            printf '.SS %s\n' "${component}"
            last="${component}"
        fi
        printf '.TP\n.B %s\n%s.\n%s\n' "${code}" "${severity}" "$(roff_escape "${message}")"
        local pointer
        pointer="$(pointers "${cited}")"
        if [[ -n "${pointer}" ]]; then
            printf 'Documented in\n%s\n' "${pointer}"
        fi
    done < <(extract | sort -t$'\t' -k1,1 -k2,2)
    cat <<'ROFF'
.SH SEE ALSO
.BR ai-tools (1),
.BR ai-tools-admin (8),
.BR ai-tools-providers (5),
.BR journalctl (1),
.BR operator.conf (5)
ROFF
}

# roff_escape <text>: the message as roff body text -- a backslash becomes \e, a hyphen \-, and a line opening
# on a control character is protected with \&, so troff renders the string the component prints rather than reading part
# of it as a macro.
roff_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\e/g' -e 's/-/\\-/g' -e "s/^[.']/\\\\\&&/"
}

# pointers <cited-by>: the comma-separated citation list reduced to the documents in it, each rendered as a roff
# cross-reference. A test or a source file is not a document and is dropped: the page documents what the tree emits,
# and a reader reaches a code's explanation through a manual. The document locations are named one by one
# for that reason -- a `*.md` catch-all would admit a Markdown file written under `tests/`.
pointers() {
    local out="" entry name section
    local -a entries=()
    IFS=',' read -ra entries <<<"$1"
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -n "${entry}" ]] || continue
        case "${entry}" in
            src/usr/local/share/man/*)
                name="${entry##*/}"; section="${name##*.}"; name="${name%.*}"
                out+="${out:+,\n}.BR ${name} (${section})" ;;
            .claude/rules/*.md|docs/*.md|README.md)
                out+="${out:+,\n}.I ${entry}" ;;
            *) continue ;;
        esac
    done
    if [[ -n "${out}" ]]; then
        printf "%b.\n" "${out}"
    fi
}

command="${1:-print}"
case "${command}" in
    # `print` reads an index named on the command line, so the render is drivable against a fixture
    # catalog; `generate` and `stale` keep the committed one, the page being derived from it alone.
    print)    INDEX="${2:-${INDEX}}"; render ;;
    generate) mkdir -p "$(dirname "${PAGE}")"; render > "${PAGE}" ;;
    stale)
        if ! render | diff -q - "${PAGE}" >/dev/null; then
            echo "${PAGE} is stale; run: bash tools/man-messages.sh generate" >&2
            exit 1
        fi ;;
    *)
        echo "usage: bash tools/man-messages.sh generate|print|stale" >&2
        exit 2 ;;
esac
