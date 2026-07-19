#!/usr/bin/env bash
# tests/unit/man.sh
# Hermetic sync test between ai-tools(1) and the CLI's own help: the set of long options
# named in ai-tools.sh's usage() heredoc must equal the set documented in the man page, in
# both directions, so neither surface can drift without failing the suite. Pure text
# comparison of the two source files -- no root, no install dependency, no CLI execution
# (the CLI's bootstrap gate fail-closes on an unprovisioned host, so it cannot be run for
# its help output here). Validates the repo sources directly, falling back to the
# installed CLI + man page outside a checkout (the man page may be gzipped there).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
MAN="${ROOT}/src/usr/local/share/man/man1/ai-tools.1"
[[ -r "${CLI}" ]] || CLI="/usr/local/bin/ai-tools"
if [[ ! -r "${MAN}" ]]; then
    MAN="/usr/local/share/man/man1/ai-tools.1"
    [[ -r "${MAN}" ]] || MAN="/usr/local/share/man/man1/ai-tools.1.gz"
fi
section "man page: ai-tools(1) in sync with the CLI help (unit)"

if [[ ! -r "${CLI}" || ! -r "${MAN}" ]]; then
    skip "ai-tools man sync" "CLI or man page not found in src/ or install paths"
    finish; exit
fi

# read_man: the page text, gunzipped when the installed copy is compressed.
read_man() {
    case "${MAN}" in
        *.gz) zcat "${MAN}" ;;
        *)    cat  "${MAN}" ;;
    esac
}

# Long options the CLI's usage() heredoc names. The heredoc is the single user-facing
# help text (usage() { cat <<EOF ... EOF }), so extraction is bounded to it.
help_opts="$(sed -n '/^usage() {/,/^EOF$/p' "${CLI}" 2>/dev/null \
    | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
# An installed CLI has no heredoc markers lost -- same extraction works; guard anyway.
if [[ -z "${help_opts}" ]]; then
    fail "could not extract long options from usage() in ${CLI}"
    finish; exit
fi

# Long options the man page documents. Troff escapes hyphens (\-\-project\-claim);
# strip the backslashes before matching.
man_opts="$(read_man | sed 's/\\-/-/g' \
    | grep -oE -- '--[a-z][a-z-]+' | sort -u)"

# (1) Every option the help names is documented in the man page.
missing="$(comm -23 <(printf '%s\n' "${help_opts}") <(printf '%s\n' "${man_opts}"))"
if [[ -z "${missing}" ]]; then
    pass "every usage() option is documented in ai-tools(1)"
else
    fail "option(s) in the CLI help but not the man page: $(tr '\n' ' ' <<<"${missing}")"
fi

# (2) Every option the man page documents exists in the help -- no stale entries.
stale="$(comm -13 <(printf '%s\n' "${help_opts}") <(printf '%s\n' "${man_opts}"))"
if [[ -z "${stale}" ]]; then
    pass "ai-tools(1) documents no option the CLI help lacks"
else
    fail "stale option(s) in the man page: $(tr '\n' ' ' <<<"${stale}")"
fi

# (3) The page carries the version slot the deploys substitute: the token in the repo
# source, a substituted version on an installed copy -- never an empty source field.
if read_man | grep -qE '^\.TH AI-TOOLS 1 .*(@AI_TOOLS_VERSION@|[0-9]+\.[0-9]+)'; then
    pass "man page .TH carries the version token/substitution"
else
    fail "man page .TH lost its version field"
fi

finish
