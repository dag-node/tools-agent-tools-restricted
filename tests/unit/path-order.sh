#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only tests/unit/path-order.sh Hermetic unit test for path-order.lib.sh:
# where an operator's shell finds an agent launcher, the reading `ai-tools-admin operators add` asks
# with, ai-tools.status re-checks with, and `ai-tools-admin system bootstrap` reports from.
#
# What makes it worth pinning is the direction each answer sends an operator. A launcher resolving outside
# /usr/local/bin means typing its name starts an UNCONFINED agent, so a verdict that read that state as fine would turn
# the one question standing between an operator and an unsandboxed session into a formality -- while a verdict
# that cried shadow on an unreadable probe would teach them to ignore it. So the truth table is driven whole, in both
# directions, and the two inputs that reach a shell or a terminal -- the launcher name interpolated into a command run
# as another account, and the path that command prints back -- are driven through the shapes they must refuse.
#
# Pure: the decision takes its inputs as arguments and the probing is separate (the split confinement.lib.sh makes),
# so this file drives the table with no account to probe and without root. The two impure readers are driven with their
# own dependencies stubbed as shell functions, which is also how the publishing contract is asserted from a real caller
# under `set -u`.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/path-order.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/path-order.lib.sh"

section "path-order.lib.sh: where an operator's shell finds an agent launcher (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "path-order" "library not found at ${LIB}"; finish; exit
fi
# shellcheck source=../../src/usr/local/lib/ai-tools/path-order.lib.sh
source "${LIB}"

WRAPPER="${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}"

# verdict <expected-token> <expected-status> <what> <wired> <winner>...
verdict() {
    local want="$1" want_rc="$2" what="$3"; shift 3
    local got rc=0
    got="$(ai_tools_path_order_verdict "$@")" || rc=$?
    if [[ "${got}" == "${want}" && "${rc}" -eq "${want_rc}" ]]; then
        pass "${what}"
    else
        fail "${what} (got ${got}/${rc}, expected ${want}/${want_rc})"
    fi
}

# ── (A) The verdict, in both directions ─────────────────────────────────────────────────────── `shadowed` is
# the answer an operator must never miss and `clear`/`wired` the ones that must not cry wolf, so each is driven
# with the winner that produces it.
verdict clear 0 "a launcher reaching the wrapper with no line wired reads as clear" \
    no "claude=${WRAPPER}/claude"
verdict wired 0 "the same reading with the line wired reads as wired" \
    yes "claude=${WRAPPER}/claude"
verdict shadowed 1 "a launcher resolving elsewhere is shadowed" \
    no "claude=/home/op/.nvm/versions/node/v22.0.0/bin/claude"
# The one case a grep of the init files would get wrong, and the reason the reading is taken from a shell: the line is
# present AND something after it prepends to PATH. Appending the line again would edit the file and leave the ordering
# as it was, so this must not read as wired.
verdict shadowed 1 "a wired account whose launcher still resolves elsewhere is shadowed, not wired" \
    yes "claude=/home/op/.nvm/versions/node/v22.0.0/bin/claude"
# A directory whose name merely begins with the wrapper's holds a different binary, so it does not pass.
verdict shadowed 1 "a sibling directory sharing the wrapper's name prefix does not pass" \
    no "claude=${WRAPPER}-local/claude"
# The wrapper path is matched per launcher, so the right binary under the right directory is what passes -- not any path
# under it.
verdict shadowed 1 "the wrapper directory with another binary's name does not pass" \
    no "claude=${WRAPPER}/claude-old"
verdict unknown 2 "an unreadable reading is unknown, never a shadow and never a clean bill" \
    no "claude=?"
verdict clear 0 "a launcher with no wrapper installed is not a fault" \
    no "claude="
verdict unknown 2 "no launcher to name reads as unknown rather than as a clean bill" no
# Precedence: one shadowed launcher is a fact about the account whatever another probe did.
verdict shadowed 1 "a shadow outranks an unreadable sibling reading" \
    yes "claude=?" "codex=/opt/elsewhere/codex"
verdict unknown 2 "with no shadow, one unreadable reading carries the verdict" \
    yes "claude=${WRAPPER}/claude" "codex=?"

# ── (B) The two inputs that reach a shell or a terminal ───────────────────────────────────────
# The launcher name is interpolated into a command run as another account, so anything outside a launcher's own charset
# must not be probed at all.
admitted=""
for bad in 'cl;id' 'cl$(id)' 'cl aude' 'cl`id`' 'cl|id' '../claude' '' 'cl&id' 'cl>x'; do
    ai_tools_path_order_launcher_valid "${bad}" && { admitted="${bad}"; break; }
done
if [[ -z "${admitted}" ]]; then
    pass "a launcher name carrying shell syntax is refused before it reaches a command"
else
    fail "admitted a launcher name carrying shell syntax: ${admitted}"
fi
if ai_tools_path_order_launcher_valid claude && ai_tools_path_order_launcher_valid node-22 \
        && ai_tools_path_order_launcher_valid gemini.cli; then
    pass "an ordinary launcher name is admitted"
else
    fail "refused a launcher name in the shape a launcher has"
fi

# The probe's answer is rendered to a terminal and compared against the wrapper path, so a relative path, an empty
# answer, and one carrying whitespace or an escape sequence are each refused.
if ai_tools_path_order_readable "${WRAPPER}/claude" \
        && ! ai_tools_path_order_readable "bin/claude" \
        && ! ai_tools_path_order_readable "" \
        && ! ai_tools_path_order_readable "/usr/local/bin/cl aude" \
        && ! ai_tools_path_order_readable "$(printf '/usr/local/bin/\033[2Kclaude')"; then
    pass "only an absolute path with no whitespace or control byte is read as an answer"
else
    fail "admitted a probe answer that is not a path this report can compare or print"
fi

# ── (C) The wiring flag, over real files ─────────────────────────────────────────────────────
mktestdir
printf '# nothing here\n' > "${TESTDIR}/bashrc.plain"
printf 'export NVM_DIR="$HOME/.nvm"\n%s\n' "${AI_TOOLS_PATH_ORDER_GUARD}" > "${TESTDIR}/bashrc.wired"
# An operator who wrote the line themselves, in their own spelling: matched on the fragment path, so their file counts
# as wired and the enrolment does not append a second copy.
printf 'source %s\n' "${AI_TOOLS_PATH_ORDER_FRAGMENT}" > "${TESTDIR}/bashrc.byhand"

if [[ "$(ai_tools_path_order_guard_present "${TESTDIR}/bashrc.plain")" == no \
   && "$(ai_tools_path_order_guard_present "${TESTDIR}/bashrc.wired")" == yes \
   && "$(ai_tools_path_order_guard_present "${TESTDIR}/bashrc.byhand")" == yes \
   && "$(ai_tools_path_order_guard_present "${TESTDIR}/absent" "${TESTDIR}/bashrc.wired")" == yes \
   && "$(ai_tools_path_order_guard_present "${TESTDIR}/absent")" == no ]]; then
    pass "the fragment is found however the line is spelled, and a missing file is not an error"
else
    fail "the wiring flag misread one of its files"
fi

# ── (C2) The repoint an upgrade owes a host wired to the former fragment name ──────────────────
# The guard line succeeds when the file is absent, so a rename that left it naming the old path would stop the ordering
# applying with no message on screen -- the silent state the rest of this library exists to catch. The bound on the edit
# is asserted with it: one path token inside a line this project wrote, and the rest of the file byte-identical.
printf 'export NVM_DIR="$HOME/.nvm"\n%s\n# a line of the operator own\n' \
    "[[ -f ${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER} ]] && source ${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER} || true" \
    > "${TESTDIR}/.bashrc.former"
chmod 600 "${TESTDIR}/.bashrc.former"
printf '# an account that never had the line\n' > "${TESTDIR}/.bashrc.none"
cp -p "${TESTDIR}/.bashrc.none" "${TESTDIR}/none.before"

repointed="$(ai_tools_path_order_repoint "${TESTDIR}/.bashrc.former" "${TESTDIR}/.bashrc.none" \
    "${TESTDIR}/absent")"
if [[ "${repointed}" == "${TESTDIR}/.bashrc.former" ]]; then
    pass "only the file naming the former fragment is rewritten, and a missing file is no error"
else
    fail "the repoint reported the wrong set of files (${repointed})"
fi
if [[ "$(ai_tools_path_order_guard_present "${TESTDIR}/.bashrc.former")" == yes ]] \
        && ! grep -qF "${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER}" "${TESTDIR}/.bashrc.former" \
        && grep -qF 'export NVM_DIR' "${TESTDIR}/.bashrc.former" \
        && grep -qF '# a line of the operator own' "${TESTDIR}/.bashrc.former"; then
    pass "the guard line now names the current fragment and the rest of the file is untouched"
else
    fail "the repoint did not rewrite the guard line, or rewrote more than it"
fi
if cmp -s "${TESTDIR}/.bashrc.none" "${TESTDIR}/none.before"; then
    pass "an account that never had the line does not acquire one"
else
    fail "wrote a guard line into a file that named neither fragment"
fi
# The file is rewritten through its own inode, because this runs as root against an account's dotfile: a fresh file
# would land root-owned and readable by nobody who needs it.
if [[ "$(perm "${TESTDIR}/.bashrc.former")" == 600 ]]; then
    pass "the file keeps the mode its account gave it"
else
    fail "the repoint changed the file's mode ($(perm "${TESTDIR}/.bashrc.former"))"
fi
# No sidecar: the rename does not change what the line does, so the repointed line behaves as the old one did
# and a backup would only preserve a path resolving to a file that is gone.
shopt -s nullglob
sidecars=( "${TESTDIR}/.bashrc.former".* )
shopt -u nullglob
if [[ ${#sidecars[@]} -eq 0 ]]; then
    pass "the repoint leaves no sidecar beside the file it rewrote"
else
    fail "the repoint wrote ${#sidecars[@]} sidecar(s): ${sidecars[*]}"
fi
if [[ -z "$(ai_tools_path_order_repoint "${TESTDIR}/.bashrc.former")" ]]; then
    pass "a second pass rewrites nothing -- the repoint is idempotent"
else
    fail "the repoint rewrote a file that already names the current fragment"
fi

# ── (D) The reading this shell can take of itself ──────────────────────────────────────────── ai-tools.status
# resolves the launcher on its own PATH, which is the operator's. Only the answers that do not depend on this host's
# PATH are asserted: a name outside the charset, and a launcher whose wrapper is not installed -- both of which must
# resolve to no probe at all.
if [[ "$(ai_tools_path_order_winner_here 'cl;id')" == '?' ]]; then
    pass "a launcher name that cannot be probed reads as unreadable, not as resolved"
else
    fail "probed a launcher name that must never reach a command"
fi
missing="ai-tools-no-such-launcher"
if [[ -e "${WRAPPER}/${missing}" ]]; then
    skip "no-wrapper reading" "${WRAPPER}/${missing} exists on this host"
elif [[ -z "$(ai_tools_path_order_winner_here "${missing}")" ]]; then
    pass "a launcher with no wrapper installed reads as nothing to order"
else
    fail "reported an ordering for a launcher this host ships no wrapper for"
fi

# ── (E) What a caller is handed ──────────────────────────────────────────────────────────────
# The read publishes four names in its caller's shell rather than printing them, so the assertion is made from a real
# caller under `set -u`: a name it fails to publish aborts this file the same way it would abort an enrolment. The two
# dependencies are stubbed, so no account is probed.
ai_tools_path_order_launchers() { printf 'claude\ncodex\n'; }
ai_tools_path_order_winner_here() {
    case "$1" in
        claude) printf '%s\n' "/home/op/.nvm/versions/node/v22.0.0/bin/claude" ;;
        *)      printf '%s/%s\n' "${WRAPPER}" "$1" ;;
    esac
}
HOME="${TESTDIR}" ai_tools_path_order_read_here || true
if [[ "${AI_TOOLS_PATH_ORDER_STATE}" == shadowed \
   && "${AI_TOOLS_PATH_ORDER_SHADOW}" == "/home/op/.nvm/versions/node/v22.0.0/bin/claude" \
   && "${AI_TOOLS_PATH_ORDER_WIRED}" == no \
   && "${#AI_TOOLS_PATH_ORDER_WINNERS[@]}" -eq 2 ]]; then
    pass "the read publishes the verdict, the shadowing binary, the wiring flag and every winner"
else
    fail "the read did not publish what its callers report from"
fi

# The shadowing binary is what a message names, so the pair it came from decides which launcher the message is about --
# not whichever launcher happened to be read first.
ai_tools_path_order_read_user() {
    AI_TOOLS_PATH_ORDER_STATE=shadowed
    AI_TOOLS_PATH_ORDER_SHADOW="/home/$1/.nvm/versions/node/v22.0.0/bin/codex"
    AI_TOOLS_PATH_ORDER_WINNERS=( "claude=${WRAPPER}/claude" "codex=${AI_TOOLS_PATH_ORDER_SHADOW}" )
    return 1
}
out="$(ai_tools_path_order_shadowed_operators op)"
if [[ "${out}" == "op"$'\t'"codex"$'\t'"/home/op/.nvm/versions/node/v22.0.0/bin/codex" ]]; then
    pass "a shadowed account is reported as user, launcher and the binary that wins"
else
    fail "the per-operator report named the wrong launcher or the wrong binary (${out})"
fi

# Every other state is silence: a report that named an account it could not read would nag a host whose ordering is
# fine.
for state in wired clear unknown; do
    eval "ai_tools_path_order_read_user() {
        AI_TOOLS_PATH_ORDER_STATE=${state}
        AI_TOOLS_PATH_ORDER_SHADOW=''
        AI_TOOLS_PATH_ORDER_WINNERS=( \"claude=\${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/claude\" )
        return 0
    }"
    if [[ -n "$(ai_tools_path_order_shadowed_operators op)" ]]; then
        fail "named an operator whose ordering read as ${state}"
        break
    fi
done
if [[ -z "$(ai_tools_path_order_shadowed_operators op)" ]]; then
    pass "an account that is not shadowed is not named, whatever its state"
fi
if [[ -z "$(ai_tools_path_order_shadowed_operators)" ]]; then
    pass "a host with no operators reports nothing"
fi

finish
