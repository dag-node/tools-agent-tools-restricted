#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-writes.sh
# Hermetic check of the root writes install.sh does not make: a root process does not write through a path component
# the sandbox account can replace (CLAUDE.md), so a name the account owns or could have placed is written
# by the account, or read through its layout row before root writes it.
#
# The writes under test run inside do_install, which needs root and a whole host, so the file reads the source rather
# than driving it, the shape tests/unit/admin-commands.sh takes for the dotnet command. Each reader joins
# backslash-continued lines first, since a command and the path it writes are often on different lines, drops comment
# lines, and runs over a control fixture carrying the form it must find before it reads install.sh, so a reader gone
# blind fails rather than passing. The settings.json keep decision is a function, so it is also driven: read
# out of install.sh as text (extract_function) and run over a fixture tree through the checkout's layout library
# under AI_TOOLS_LAYOUT_ROOT. A file at its row needs a root-owned fixture, so that half runs as root and skips
# otherwise.
#
# The ACL tools check, require_acl_tools, is driven the same way under a PATH without the tools, and do_install's text
# is read for the call's place ahead of the first write. ensure_dir is driven over fixtures: a name that is not
# a directory is refused with the link's target untouched, beside `install -d` following the link as the control;
# and do_install's text is read for the home, then bin, brought to their rows ahead of the first file written
# under them. The sysusers fragment the layout declares a payload file of base is read the same way: do_install places
# it from packaging/ai-tools.sysusers and do_uninstall removes it.
#
# No install and no command of install.sh's but the extracted functions. Skips outside a checkout.

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

# ── settings.json is kept only at its row ───────────────────────────────────────────────────
# .claude is sticky and sandbox-group-writable, so the account can place settings.json before the file exists; a by-path
# chown or chmod there makes root bless what it placed. The file is kept only when its layout row reads clean,
# and the by-path writes are gone.
settings_writes="$(code_lines "${INSTALLER}" | grep -E '(^|[^[:alnum:]_])(chown|chmod)[[:space:]]' \
    | grep -F '${settings}' || true)"
settings_reader="$(code_lines "${INSTALLER}" | grep -F 'read_settings_keep_refusal "${settings}"' || true)"
if [[ -n "${settings_writes}" ]]; then
    fail "install.sh changes settings.json's owner or mode by path: $(_san "${settings_writes}")"
elif [[ -z "${settings_reader}" ]]; then
    fail "install.sh does not read settings.json's layout row before keeping it"
else
    pass "install.sh reads settings.json's layout row before keeping it and does not chown or chmod it by path"
fi

# The name stays plantable between the reader and the next step, so the keep prompt is reached only inside the branch
# the reader passed (a file planted after a set-aside is never offered to keep_existing), and the shipped file is
# installed with `-T`, which replaces a symlink planted at the name and refuses a directory there, where a plain install
# writes into the directory the link names. settings_keep_shape <file>: print `keep=<nested|flat|none>
# install=<T|plain|none>`, reading the keep call's indentation against the reader's `if` line as its nesting.
settings_keep_shape() {
    local lines reader_line keep_line install_line reader_indent keep_indent keep=none install=none
    lines="$(code_lines "$1")"
    reader_line="$(grep -F 'if settings_refusal="$(read_settings_keep_refusal "${settings}"' <<<"${lines}" | head -n1 || true)"
    keep_line="$(grep -F 'keep_existing "${settings}"' <<<"${lines}" | head -n1 || true)"
    install_line="$(grep -E '(^|[^[:alnum:]_-])install[[:space:]]' <<<"${lines}" \
        | grep -F 'agents/claude-code/settings.json" "${settings}"' | head -n1 || true)"
    if [[ -n "${reader_line}" && -n "${keep_line}" ]]; then
        reader_indent="${reader_line#*:}"; reader_indent="${reader_indent%%[^ ]*}"
        keep_indent="${keep_line#*:}"; keep_indent="${keep_indent%%[^ ]*}"
        if (( ${#keep_indent} > ${#reader_indent} )); then keep=nested; else keep=flat; fi
    fi
    if [[ -n "${install_line}" ]]; then
        if [[ "${install_line}" =~ install[[:space:]]+-T[[:space:]] ]]; then install=T; else install=plain; fi
    fi
    printf 'keep=%s install=%s\n' "${keep}" "${install}"
}
control_fixed="${TESTDIR}/keep-fixed.sh"; control_flat="${TESTDIR}/keep-flat.sh"
# shellcheck disable=SC2016,SC1003  # the fixtures are code text: expansions and trailing backslashes stay literal
printf '%s\n' '    if settings_refusal="$(read_settings_keep_refusal "${settings}" lib)"; then' \
    '        if keep_existing "${settings}" "prompt"; then settings_kept=1; fi' \
    '    fi' \
    '        install -T -o root -g "${SANDBOX_GROUP}" -m 640 \' \
    '            "${SCRIPT_DIR}/src/opt/ai-tools/agents/claude-code/settings.json" "${settings}"' > "${control_fixed}"
# shellcheck disable=SC2016,SC1003
printf '%s\n' '    if settings_refusal="$(read_settings_keep_refusal "${settings}" lib)"; then' \
    '        :' \
    '    fi' \
    '    if keep_existing "${settings}" "prompt"; then' \
    '        install -o root -g "${SANDBOX_GROUP}" -m 640 \' \
    '            "${SCRIPT_DIR}/src/opt/ai-tools/agents/claude-code/settings.json" "${settings}"' > "${control_flat}"
shape_fixed="$(settings_keep_shape "${control_fixed}")"; shape_flat="$(settings_keep_shape "${control_flat}")"
shape="$(settings_keep_shape "${INSTALLER}")"
if [[ "${shape_fixed}" != "keep=nested install=T" || "${shape_flat}" != "keep=flat install=plain" ]]; then
    fail "the keep-shape reader missed its controls: fixed=$(_san "${shape_fixed}") flat=$(_san "${shape_flat}")"
elif [[ "${shape}" != "keep=nested install=T" ]]; then
    fail "install.sh offers settings.json to keep outside the reader's branch, or installs the shipped file without -T: ${shape}"
else
    pass "install.sh offers settings.json to keep only inside the reader's branch and installs the shipped file with -T"
fi

# The checkout's library, the sandbox tokens substituted as install.sh substitutes them, with its siblings beside it;
# the agent package's sentinel under the fixture root, so the settings row applies.
cp -r "${ROOT}/src/usr/local/lib/ai-tools" "${TESTDIR}/lib"
chmod -R u+rwX,go+rX "${TESTDIR}/lib"
sed -i -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" "${TESTDIR}/lib/layout.lib.sh"
FIXTURE_ROOT="${TESTDIR}/root"
CLAUDE_DIR="${FIXTURE_ROOT}/opt/ai-tools/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
mkdir -p "${CLAUDE_DIR}" "${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d"
: > "${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d/claude-code.conf"
reader_text="$(extract_function "${INSTALLER}" read_settings_keep_refusal)"
# keep_refusal: run the extracted function over SETTINGS in a fresh shell under install.sh's strict mode, printing its
# reason and `status=<n>` on the last line.
keep_refusal() {
    AI_TOOLS_LAYOUT_ROOT="${FIXTURE_ROOT}" AI_TOOLS_AGENTS_DIR="${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d" \
        AI_TOOLS_OPERATOR_CONF="${FIXTURE_ROOT}/etc/ai-tools/operator.conf" bash -c '
        set -euo pipefail
        eval "$1"
        status=0; read_settings_keep_refusal "$2" "$3" || status=$?
        printf "\nstatus=%s\n" "${status}"' _ "${reader_text}" "${SETTINGS}" "${TESTDIR}/lib/layout.lib.sh" 2>&1
}
# refused_with <what> <reason-pattern> <output>
refused_with() {
    if [[ "$3" == *$'\n'status=1 && "$3" =~ $2 ]]; then
        pass "$1"
    else
        fail "$1: $(_san "$3")"
    fi
}

if [[ -z "${reader_text}" ]]; then
    fail "read_settings_keep_refusal is not defined in install.sh"
else
    printf '{}\n' > "${SETTINGS}"; chmod 0640 "${SETTINGS}"
    if (( EUID == 0 )); then chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${SETTINGS}"; fi
    out="$(keep_refusal)"; note "the reason the owner case reads" "${out%%$'\n'*}"
    refused_with "a settings.json at another owner is not kept" 'its owner is [^ ]+, not root:' "${out}"
    rm -f "${SETTINGS}"; printf '{}\n' > "${TESTDIR}/planted.json"; ln -s "${TESTDIR}/planted.json" "${SETTINGS}"
    refused_with "a settings.json that is a symlink is not kept" 'it is a link' "$(keep_refusal)"
    # Without the agent package's sentinel the row does not apply on this host.
    rm -f "${SETTINGS}" "${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d/claude-code.conf"; printf '{}\n' > "${SETTINGS}"
    refused_with "a settings.json the layout does not list is not kept" 'does not list it' "$(keep_refusal)"
    : > "${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d/claude-code.conf"; rm -f "${SETTINGS}"

    if (( EUID != 0 )); then
        skip "a settings.json at its row is kept" "needs root to make the fixture root-owned"
    else
        install -o root -g "${SANDBOX_GROUP}" -m 0640 /dev/null "${SETTINGS}"
        out="$(keep_refusal)"
        if [[ "${out}" == $'\n'status=0 ]]; then
            pass "a root:${SANDBOX_GROUP} 0640 settings.json is kept"
        else
            fail "a settings.json at its row was refused: $(_san "${out}")"
        fi
        chmod 0660 "${SETTINGS}"
        refused_with "a group-writable settings.json is not kept" 'its mode is 0660, not 0640' "$(keep_refusal)"
        chmod 0640 "${SETTINGS}"; setfacl -m "u:${SANDBOX_USER}:rw-" "${SETTINGS}"
        refused_with "a settings.json with a named ACL entry is not kept" 'its (ACL|mode) is' "$(keep_refusal)"
        setfacl -b "${SETTINGS}"; chmod 0640 "${SETTINGS}"; ln "${SETTINGS}" "${CLAUDE_DIR}/second-name"
        refused_with "a hardlinked settings.json is not kept" 'it has 2 hard links' "$(keep_refusal)"
    fi
fi


# ── do_selinux_restore walks only root-owned trees ahead of the live-session reading ──────────────
# A recursive restorecon resolves each path again before it writes, so a walk of a tree the sandbox account can write
# runs behind the reading (cli.rule.md, ref-section-e6c6). Every `restorecon -R` the function makes before the reading
# must name a root-owned tree from the set find_early_account_walks lists; a control fixture walking
# /opt/ai-tools/.config there must be flagged. find_early_account_walks <file>: print each `restorecon -R` code line
# ahead of the reading that names a path outside the root-owned set.
find_early_account_walks() {
    local line path
    while IFS= read -r line; do
        [[ "${line}" == *_sandbox_session_state=* ]] && break
        [[ "${line}" =~ restorecon[[:space:]]+-R ]] || continue
        for path in ${line#*restorecon}; do
            case "${path}" in
                -R|\\) ;;
                /usr/local/libexec/ai-tools/|/usr/local/lib/ai-tools/|/opt/ai-tools/bin/|/var/log/ai-tools/) ;;
                *) printf '%s\n' "${line}"; break ;;
            esac
        done
    done < <(code_lines "$1")
}
restore_text="$(extract_function "${INSTALLER}" do_selinux_restore)"
if [[ -z "${restore_text}" ]]; then
    fail "install.sh does not define do_selinux_restore() in the form this file reads"
else
    printf '%s\n' 'do_selinux_restore() {' '    restorecon -R \\' '        /opt/ai-tools/bin/ \\' \
        '        /opt/ai-tools/.config/' '    _sandbox_session_state="$(read)"' '}' > "${TESTDIR}/restore-control.sh"
    if [[ -n "$(find_early_account_walks "${TESTDIR}/restore-control.sh")" ]]; then
        pass "the reader flags a walk of an account-writable tree ahead of the reading (control)"
    else
        fail "control: the reader does not flag an early walk, so the check below cannot fail"
    fi
    printf '%s\n' "${restore_text}" > "${TESTDIR}/restore.sh"
    if ! grep -q '_sandbox_session_state=' "${TESTDIR}/restore.sh"; then
        fail "do_selinux_restore does not take the live-session reading this check splits on"
    else
        found="$(find_early_account_walks "${TESTDIR}/restore.sh")"
        [[ -z "${found}" ]] && pass "do_selinux_restore walks only root-owned trees ahead of the live-session reading" \
            || fail "do_selinux_restore walks a tree the account can write ahead of the reading: $(_san "${found}")"
    fi
fi

# ── a source install requires the ACL tools ──────────────────────────────────────────────────
# Every grant the ownership model makes is a POSIX ACL, so the install refuses a host without setfacl and getfacl,
# and does so ahead of its first write. require_acl_tools is driven out of install.sh as text with the real die,
# under a PATH holding neither tool; a shell function named for a tool answers `command -v` as a binary would,
# which stands for an installed tool without needing an executable fixture. Then do_install's text is read
# for the call's place: beside the account check, ahead of the install log's directory, the first path the install
# creates.
section "install.sh: a source install refuses a host without the ACL tools (unit)"
acl_text=""
for name in die require_acl_tools; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install.sh does not define ${name}() in the form this file reads"
        acl_text=""; break
    fi
    acl_text+="${body}"$'\n'
done
if [[ -n "${acl_text}" ]]; then
    # acl_run <tool-functions> : require_acl_tools under an empty PATH with the named tools defined as functions, run
    #   under the IFS install.sh sets.
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    acl_run() {
        env -i PATH="${TESTDIR}/no-bin" "${BASH}" -c '
            set -euo pipefail
            C_RED="" C_RST=""
            eval "$1"
            for tool in $2; do eval "${tool}() { :; }"; done
            IFS=$'"'"'\n\t'"'"'
            require_acl_tools
            printf "returned\n"
        ' _ "${acl_text}" "$1" 2>&1
    }
    mkdir -p "${TESTDIR}/no-bin"
    rc=0; out="$(acl_run "setfacl getfacl")" || rc=$?
    if (( rc == 0 )) && [[ "${out}" == returned ]]; then
        pass "with both tools present the check passes (control)"
    else
        fail "with both tools present the check exited ${rc}: ${out//$'\n'/ | }"
    fi
    rc=0; out="$(acl_run "")" || rc=$?
    assert_msg MSG-Q7E7 "${out}" "with neither tool the install is refused"
    if (( rc != 0 )) && [[ "${out}" == *"(setfacl and getfacl not found)"* && "${out}" == *"dnf install acl"* ]]; then
        pass "the refusal exits non-zero, names both tools and the acl package"
    else
        fail "the refusal with neither tool (exit ${rc}): ${out//$'\n'/ | }"
    fi
    rc=0; out="$(acl_run "setfacl")" || rc=$?
    if (( rc != 0 )) && [[ "${out}" == *"(getfacl not found)"* ]]; then
        pass "with getfacl alone missing the refusal names it alone"
    else
        fail "the refusal with getfacl missing (exit ${rc}): ${out//$'\n'/ | }"
    fi
fi

# call_precedes_first_write <file> : succeed when do_install's require_acl_tools call comes before its first
# `install -d` of /var/log/ai-tools, the first path the install creates.
call_precedes_first_write() {
    local body call_line write_line
    body="$(extract_function "$1" do_install)"
    call_line="$(grep -n -m1 -E '^[[:space:]]+require_acl_tools$' <<<"${body}" | cut -d: -f1 || true)"
    write_line="$(grep -n -m1 -E '^[[:space:]]+install -d .*/var/log/ai-tools' <<<"${body}" | cut -d: -f1 || true)"
    [[ -n "${call_line}" && -n "${write_line}" ]] && (( call_line < write_line ))
}
printf '%s\n' 'do_install() {' '    install -d -o root -g root -m 700 /var/log/ai-tools' '    require_acl_tools' '}' \
    > "${TESTDIR}/acl-order-control.sh"
if call_precedes_first_write "${TESTDIR}/acl-order-control.sh"; then
    fail "control: the reader accepts a check placed after the first write, so the check below cannot fail"
else
    pass "the reader flags a check placed after the first write (control)"
fi
if call_precedes_first_write "${INSTALLER}"; then
    pass "do_install refuses a host without the ACL tools ahead of its first write"
else
    fail "do_install does not call require_acl_tools ahead of its install log's directory"
fi

# ── ensure_dir sets an owner and a mode on a directory alone ─────────────────────────────────────
# `install -d`, chown and chmod each follow a symlink at the name, so ensure_dir reads the name first and refuses one
# that exists and is not a directory. It is driven extracted with the real die, over fixtures the test owns
# at the test's own owner and group; the control is `install -d` itself over a symlink, which changes the mode
# of the link's target.
section "install.sh: ensure_dir refuses a name that is not a directory (unit)"
ensure_text=""
for name in die ensure_dir; do
    body="$(extract_function "${INSTALLER}" "${name}")"
    if [[ -z "${body}" ]]; then
        fail "install.sh does not define ${name}() in the form this file reads"
        ensure_text=""; break
    fi
    ensure_text+="${body}"$'\n'
done
if [[ -n "${ensure_text}" ]]; then
    fixture_owner="$(stat -c '%U' "${TESTDIR}")"; fixture_group="$(stat -c '%G' "${TESTDIR}")"
    # ensure_run <mode> <dir> : ensure_dir out of install.sh, under the IFS install.sh sets, with log a no-op.
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    ensure_run() {
        env -i PATH=/usr/bin:/bin "${BASH}" -c '
            set -euo pipefail
            C_RED="" C_RST=""
            log() { :; }
            eval "$1"
            IFS=$'"'"'\n\t'"'"'
            ensure_dir "$2" "$3" "$4" "$5"
            printf "returned\n"
        ' _ "${ensure_text}" "$1" "${fixture_owner}" "${fixture_group}" "$2" 2>&1
    }
    mkdir -m 0755 "${TESTDIR}/target" "${TESTDIR}/home"
    ln -s "${TESTDIR}/target" "${TESTDIR}/home/link"
    install -d -m 0551 "${TESTDIR}/home/link"
    if [[ "$(stat -c '%a' "${TESTDIR}/target")" == 551 ]]; then
        pass "install -d over a symlink changes the mode of the link's target (control)"
    else
        fail "control: install -d over a symlink left the target at $(stat -c '%a' "${TESTDIR}/target"), so the refusal below guards against a write this host does not make"
    fi
    chmod 0755 "${TESTDIR}/target"
    rc=0; out="$(ensure_run 0551 "${TESTDIR}/home/link")" || rc=$?
    assert_msg MSG-W4A2 "${out}" "a symlink at the name is refused"
    if (( rc != 0 )) && [[ "$(stat -c '%a' "${TESTDIR}/target")" == 755 ]]; then
        pass "the refusal exits non-zero and the link's target keeps its mode"
    else
        fail "a symlink at the name (exit ${rc}, target now $(stat -c '%a' "${TESTDIR}/target")): ${out//$'\n'/ | }"
    fi
    : > "${TESTDIR}/home/file"
    rc=0; out="$(ensure_run 0551 "${TESTDIR}/home/file")" || rc=$?
    assert_msg MSG-W4A2 "${out}" "a regular file at the name is refused"
    chmod 0700 "${TESTDIR}/target"
    rc=0; out="$(ensure_run 0551 "${TESTDIR}/target")" || rc=$?
    if (( rc == 0 )) && [[ "${out}" == returned && "$(stat -c '%a' "${TESTDIR}/target")" == 551 ]]; then
        pass "an existing directory is brought to the mode"
    else
        fail "an existing directory (exit ${rc}, mode $(stat -c '%a' "${TESTDIR}/target")): ${out//$'\n'/ | }"
    fi
    rc=0; out="$(ensure_run 0551 "${TESTDIR}/home/new")" || rc=$?
    if (( rc == 0 )) && [[ -d "${TESTDIR}/home/new" && "$(stat -c '%a' "${TESTDIR}/home/new")" == 551 ]]; then
        pass "a missing directory is created at the mode"
    else
        fail "a missing directory (exit ${rc}): ${out//$'\n'/ | }"
    fi
    chmod -R u+rwx "${TESTDIR}/target" "${TESTDIR}/home"
fi

# ── the sandbox home, then bin, ahead of the first file written into bin ─────────────────────────
# useradd leaves the home the account's, so a name under it is the account's to place until the home is root-owned
# without group write; and the RPM owns /opt/ai-tools/bin and an erase removes it once empty, so a source install
# over a host that left the packages does not find the directory, and `install` of a file into an absent one fails.
# do_install's text is read for the order: the home's ensure_dir, then bin's, then the first `install` into bin, beside
# a control with the three inverted.
section "install.sh: the home, then bin, are brought to their rows ahead of the first file under them (unit)"
# home_then_bin_precede_first_file <file> : succeed when do_install's ensure_dir of /opt/ai-tools comes before its
# ensure_dir of /opt/ai-tools/bin, which comes before its first `install` or install_subst of a file under bin.
home_then_bin_precede_first_file() {
    local lines home_line dir_line file_line
    lines="$(extract_function "$1" do_install | code_lines /dev/stdin)"
    home_line="$(grep -E '^[0-9]+:[[:space:]]*ensure_dir .* /opt/ai-tools$' <<<"${lines}" | head -n 1 | cut -d: -f1)"
    dir_line="$(grep -E '^[0-9]+:[[:space:]]*ensure_dir .* /opt/ai-tools/bin$' <<<"${lines}" | head -n 1 | cut -d: -f1)"
    file_line="$(grep -E '^[0-9]+:[[:space:]]*install(_subst)? .* /opt/ai-tools/bin/' <<<"${lines}" | head -n 1 | cut -d: -f1)"
    [[ -n "${home_line}" && -n "${dir_line}" && -n "${file_line}" ]] \
        && (( home_line < dir_line )) && (( dir_line < file_line ))
}
printf '%s\n' 'do_install() {' '    install -o root -g ai-tools -m 550 \' '        src/nvm-update.sh /opt/ai-tools/bin/nvm-update.sh' \
    '    ensure_dir 0551 root ai-tools /opt/ai-tools/bin' '    ensure_dir 2751 root ai-tools /opt/ai-tools' '}' \
    > "${TESTDIR}/bin-order-control.sh"
if home_then_bin_precede_first_file "${TESTDIR}/bin-order-control.sh"; then
    fail "control: the reader accepts the home and bin brought to their rows after the first file, so the check below cannot fail"
else
    pass "the reader flags the home and bin brought to their rows after the first file (control)"
fi
if home_then_bin_precede_first_file "${INSTALLER}"; then
    pass "do_install brings the home, then bin, to their rows ahead of the first file it writes under them"
else
    fail "do_install does not bring /opt/ai-tools, then /opt/ai-tools/bin, to their rows ahead of its first install into bin"
fi
# The same rule for every other directory the install brings to a row under the home: each ensure_dir of a path
# under /opt/ai-tools follows the home's, and no `install -d` names a path under the home at all -- the reconcile
# and ensure_dir are the writers there, and `install -d` follows a link at the name.
# home_precedes_every_home_row <file> : succeed when every ensure_dir of /opt/ai-tools/<...> in do_install comes after
# the home's, and no install -d line names a path under /opt/ai-tools.
home_precedes_every_home_row() {
    local lines home_line row_line
    lines="$(extract_function "$1" do_install | code_lines /dev/stdin)"
    home_line="$(grep -E '^[0-9]+:[[:space:]]*ensure_dir .* /opt/ai-tools$' <<<"${lines}" | head -n 1 | cut -d: -f1)"
    [[ -n "${home_line}" ]] || return 1
    ! grep -qE '^[0-9]+:[[:space:]]*install -d .* /opt/ai-tools(/|$)' <<<"${lines}" || return 1
    while IFS= read -r row_line; do
        [[ -n "${row_line}" ]] || continue
        (( row_line > home_line )) || return 1
    done < <(grep -E '^[0-9]+:[[:space:]]*ensure_dir .* (/opt/ai-tools/[^[:space:]]+|"\$\{chain_dir\}")$' <<<"${lines}" | cut -d: -f1)
}
printf '%s\n' 'do_install() {' '    ensure_dir 2770 root ai-tools /opt/ai-tools/integrations' \
    '    ensure_dir 2751 root ai-tools /opt/ai-tools' '}' > "${TESTDIR}/home-rows-control.sh"
printf '%s\n' 'do_install() {' '    ensure_dir 2751 root ai-tools /opt/ai-tools' \
    '    install -d -o root -g ai-tools -m 2750 /opt/ai-tools/.config' '}' > "${TESTDIR}/home-installd-control.sh"
if home_precedes_every_home_row "${TESTDIR}/home-rows-control.sh" || home_precedes_every_home_row "${TESTDIR}/home-installd-control.sh"; then
    fail "control: the reader accepts a row under the home brought to it before the home, or an install -d under the home, so the check below cannot fail"
else
    pass "the reader flags a row under the home ahead of the home's, and an install -d under the home (control)"
fi
if home_precedes_every_home_row "${INSTALLER}"; then
    pass "do_install brings every directory under the home to its row after the home's, and writes none with install -d"
else
    fail "do_install brings a directory under /opt/ai-tools to its row ahead of the home's, or names one in an install -d"
fi

# ── the account declaration a source install places ──────────────────────────────────────────────
# layout.lib.sh declares /usr/lib/sysusers.d/ai-tools.conf a payload file of base and the RPM installs it
# from packaging/ai-tools.sysusers, so a source install places the same file, or every layout reconcile reports the row
# missing with a remedy a source install cannot meet. do_install's text is read for the install of that source
# at that path and do_uninstall's for its removal, each beside a control lacking the line; the row's declaration is read
# out of layout.lib.sh first, so a row that moves takes this check with it.
section "install.sh: a source install places the sysusers fragment the layout declares (unit)"
sysusers_path=/usr/lib/sysusers.d/ai-tools.conf
if grep -qE "append_static_entry[[:space:]]+${sysusers_path}[[:space:]]+file[[:space:]]+root:root" \
        "${ROOT}/src/usr/local/lib/ai-tools/layout.lib.sh"; then
    pass "layout.lib.sh declares ${sysusers_path} a root-owned payload file (control)"
else
    fail "control: layout.lib.sh does not declare ${sysusers_path} in the form this file reads, so the checks below guard a row that does not exist"
fi
# places_sysusers <file> : succeed when do_install installs packaging/ai-tools.sysusers at the fragment's path.
# The lines are captured before the match, so a match does not end the producer early under pipefail.
places_sysusers() {
    local lines
    lines="$(extract_function "$1" do_install | code_lines /dev/stdin)"
    grep -qE "install .*packaging/ai-tools\.sysusers\"? ${sysusers_path}$" <<<"${lines}"
}
# removes_sysusers <file> : succeed when do_uninstall removes the fragment.
removes_sysusers() {
    local lines
    lines="$(extract_function "$1" do_uninstall | code_lines /dev/stdin)"
    grep -qE "rm -f ${sysusers_path}$" <<<"${lines}"
}
# shellcheck disable=SC2016  # the fixture is code text: its expansion stays literal
printf '%s\n' 'do_install() {' '    install -o root -g root -m 644 "${SCRIPT_DIR}/src/x" /usr/lib/x' '}' \
    'do_uninstall() {' '    rm -f /usr/lib/x' '}' > "${TESTDIR}/sysusers-control.sh"
if places_sysusers "${TESTDIR}/sysusers-control.sh" || removes_sysusers "${TESTDIR}/sysusers-control.sh"; then
    fail "control: the readers accept an installer without the fragment, so the checks below cannot fail"
else
    pass "the readers flag an installer without the fragment's install and removal (control)"
fi
places_sysusers "${INSTALLER}" && pass "do_install places ${sysusers_path} from packaging/ai-tools.sysusers" \
    || fail "do_install does not install packaging/ai-tools.sysusers at ${sysusers_path}"
removes_sysusers "${INSTALLER}" && pass "do_uninstall removes ${sysusers_path}" \
    || fail "do_uninstall does not remove ${sysusers_path}"

finish
