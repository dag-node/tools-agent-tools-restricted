#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-writes.sh
# Hermetic read of install.sh's text for the root writes it does not make: a root process does not write through a path
# component the sandbox account can replace (CLAUDE.md), so a name the account owns or could have placed is written
# by the account, or read through its layout row before root writes it.
#
# The writes under test run inside do_install, which needs root and a whole host, so the file reads the source rather
# than driving it, the shape tests/unit/admin-commands.sh takes for the dotnet command. Each reader joins
# backslash-continued lines first, since a command and the path it writes are often on different lines, drops comment
# lines, and runs over a control fixture carrying the form it must find before it reads install.sh, so a reader gone
# blind fails rather than passing.
#
# Pure text: no root, no install, no command executed. Skips outside a checkout.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly INSTALLER="${ROOT}/install.sh"
section "install.sh: root does not write a name the sandbox account placed (unit)"

if [[ ! -r "${INSTALLER}" ]]; then
    skip "install.sh root writes" "not a source checkout (no ${INSTALLER})"
    finish; exit
fi
mktestdir

# code_lines <file>: print each code line with its backslash continuations joined, prefixed by the line number
# the command starts on. Comment lines are not code.
code_lines() {
    awk '
        /^[[:space:]]*#/ && joined == "" { next }
        {
            if (joined == "") { start = NR; joined = $0 } else { joined = joined " " $0 }
            if (joined ~ /\\$/) { sub(/\\$/, "", joined); next }
            print start ":" joined; joined = ""
        }
        END { if (joined != "") print start ":" joined }
    ' "$1"
}

# ── the timer stamp is written as the sandbox account ───────────────────────────────────────
# The stamp directory is the account's (its `--user manager` writes the Persistent= stamps there), so a root `install`,
# `touch` or redirection into it follows a name the account placed. The one write is `sudo -u` the account.
# find_stamp_writes <file> <root|account>: print each code line writing under CP_TIMER_STAMP_DIR by that principal.
find_stamp_writes() {
    local lines
    # shellcheck disable=SC2016  # matching the literal ${CP_TIMER_STAMP_DIR}, not expanding it
    lines="$(code_lines "$1" | grep -F '${CP_TIMER_STAMP_DIR}' || true)"
    [[ -n "${lines}" ]] || return 0
    local writes
    writes="$(grep -E '(^|[^[:alnum:]_-])(install|touch|cp|mv|ln|tee|mkdir)[[:space:]]|>' <<<"${lines}" || true)"
    [[ -n "${writes}" ]] || return 0
    # shellcheck disable=SC2016  # matching the literal ${SANDBOX_USER}
    case "$2" in
        account) grep -F 'sudo -u "${SANDBOX_USER}"' <<<"${writes}" || true ;;
        root)    grep -vF 'sudo -u "${SANDBOX_USER}"' <<<"${writes}" || true ;;
    esac
}
control="${TESTDIR}/stamp-control.sh"
# shellcheck disable=SC2016,SC1003  # the fixture is code text: its expansions and trailing backslashes stay literal
printf '%s\n' '    # install -o x /dev/null "${CP_TIMER_STAMP_DIR}" in a comment is not code' \
    '    install -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0644 /dev/null \' \
    '        "/opt/ai-tools/${CP_TIMER_STAMP_DIR}/${CP_UPDATE_TIMER_STAMP}"' \
    '    (cd / && sudo -u "${SANDBOX_USER}" touch "/opt/ai-tools/${CP_TIMER_STAMP_DIR}/${CP_UPDATE_TIMER_STAMP}") \' \
    '        || warn "the timer stamp was not written"' > "${control}"
control_root="$(find_stamp_writes "${control}" root)"
control_account="$(find_stamp_writes "${control}" account)"
root_writes="$(find_stamp_writes "${INSTALLER}" root)"
account_writes="$(find_stamp_writes "${INSTALLER}" account)"
if [[ "${control_root}" != 2:* || "${control_account}" != 4:* ]]; then
    fail "the stamp write reader missed its control: root=$(_san "${control_root:-no line}") account=$(_san "${control_account:-no line}")"
elif [[ -n "${root_writes}" ]]; then
    fail "install.sh writes into the account's timer-stamp directory as root: $(_san "${root_writes}")"
elif [[ -z "${account_writes}" ]]; then
    fail "install.sh does not seed the timer stamp as the sandbox account"
else
    pass "install.sh seeds the timer stamp as the sandbox account and writes nothing there as root"
fi

finish
