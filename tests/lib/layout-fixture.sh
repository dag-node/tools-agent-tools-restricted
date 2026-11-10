#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/layout-fixture.sh
# The fixture the layout tests share: the checkout's layout library copied into the testdir with the sandbox tokens
# substituted, as install.sh and the spec substitute them, the two discovery inputs at their rows under a fixture root,
# and, for the files that drive the reconcile as root, a tree built from the table itself with the rpm collector
# stubbed. Sourced after harness.sh by tests/unit/layout.sh and the tests/unit/layout-reconcile-*.sh files, which split
# the reconcile's root cases so the runner's pool runs them at once. Each of those files builds its own tree, so a case
# depends on the cases of its own file alone.

# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
_LAYOUT_FIXTURE_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# layout_fixture_prepare: make the testdir, copy the checkout's library directory into it, and substitute the sandbox
# tokens into the layout library, since its owner grammar refuses the raw token; the siblings are copied beside it
# because the library sources them from its own directory, and the copy is opened to every account, since a root case
# sources it as the projects user. Write the agents directory and operator.conf at their rows under the fixture root,
# so the reconcile converges a discovery input and the dynamic rows it hides in one run (unprivileged they are
# the invoker's, which the trust predicate refuses), and export the hooks the enumeration reads, with the reconcile's
# lock in the testdir rather than /run/lock. Sets FIXTURE_ROOT, AGENTS_DIR, OPERATOR_CONF and LAYOUT_FIXTURE_LIB,
# the copy the caller sources at file scope next; the hooks are readonly once the libraries load, so they are set
# before it.
layout_fixture_prepare() {
    mktestdir
    cp -r "${_LAYOUT_FIXTURE_CHECKOUT}/src/usr/local/lib/ai-tools" "${TESTDIR}/lib"
    chmod -R u+rwX,go+rX "${TESTDIR}/lib"
    sed -i -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" \
        "${TESTDIR}/lib/layout.lib.sh"
    # shellcheck disable=SC2034  # read by the caller, which sources the copy at file scope
    LAYOUT_FIXTURE_LIB="${TESTDIR}/lib/layout.lib.sh"
    FIXTURE_ROOT="${TESTDIR}/root"
    AGENTS_DIR="${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d"
    OPERATOR_CONF="${FIXTURE_ROOT}/etc/ai-tools/operator.conf"
    mkdir -p "${FIXTURE_ROOT}" "${AGENTS_DIR}" "${OPERATOR_CONF%/*}"
    printf 'config_dir=.acme\nlauncher=acme\n' > "${AGENTS_DIR}/acme.conf"
    printf 'launcher=nodir\n' > "${AGENTS_DIR}/nodir.conf"
    chmod 0755 "${AGENTS_DIR}"; chmod 0644 "${AGENTS_DIR}"/*.conf
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${OPERATOR_CONF}"
    chmod 0644 "${OPERATOR_CONF}"
    export AI_TOOLS_LAYOUT_ROOT="${FIXTURE_ROOT}" AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}"
    export AI_TOOLS_OPERATOR_CONF="${OPERATOR_CONF}"
    export AI_TOOLS_LAYOUT_LOCK="${TESTDIR}/layout.lock" AI_TOOLS_LAYOUT_LOCK_WAIT=1
}

# layout_fixture_read_root_skip_reason: print why the reconcile cannot be driven as root on this host; the output is
# empty where it can be. Called after the library copy and its safe-paths sibling are sourced.
layout_fixture_read_root_skip_reason() {
    if (( EUID != 0 )); then
        printf 'runs unprivileged; sudo bash %s runs it' "$0"
    elif ! getent passwd "${SANDBOX_USER}" >/dev/null 2>&1 || ! getent group ai-ops >/dev/null 2>&1 \
            || ! getent passwd nobody >/dev/null 2>&1; then
        printf 'the sandbox account, ai-ops or nobody is not on this host'
    elif ! declare -F ai_tools_safe_paths__is_pinned_fd_at_path >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        printf 'safe-paths.lib.sh or flock is not available'
    fi
}

# The collector stub's state: per payload path, the verify flags it prints (LAYOUT_FIXTURE_RPM_FLAGS, `.........`
# where unset) and the file state it appends (LAYOUT_FIXTURE_RPM_STATES), and the status it returns where non-zero
# (LAYOUT_FIXTURE_RPM_STATUS). A case sets an entry for one run and unsets it after.
declare -A LAYOUT_FIXTURE_RPM_FLAGS=() LAYOUT_FIXTURE_RPM_STATES=()
LAYOUT_FIXTURE_RPM_STATUS=0
LAYOUT_FIXTURE_PAYLOAD_LIST=""

# layout_fixture_rpm: the collector stub. It prints every payload path verified, with the per-path flags and file states
# a case sets, then a line of each shape verbose verify prints for paths outside the table, as a host installed
# with tsflags=nodocs prints its documentation: every run therefore holds the parser to those shapes, since one it did
# not recognize would make each package file unreadable. As rpm does, it exits 1 once a line carries a difference
# or reads `missing`, and 0 otherwise.
layout_fixture_rpm() {
    local p flags status=0
    case "$1" in -q) return 0 ;; esac
    while IFS= read -r p; do
        flags="${LAYOUT_FIXTURE_RPM_FLAGS[${p}]:-.........}"
        printf '%s    %s%s\n' "${flags}" "${p}" "${LAYOUT_FIXTURE_RPM_STATES[${p}]:+ (${LAYOUT_FIXTURE_RPM_STATES[${p}]})}"
        [[ "${flags}" == missing || "${flags}" == *[^.]* ]] && status=1
    done < "${LAYOUT_FIXTURE_PAYLOAD_LIST}"
    printf '%s\n' '.........  d /usr/share/doc/ai-tools-base/README.md (not installed)' \
        '.........  d /usr/share/doc/ai-tools-base/docs/a.md (net shared)' \
        '.........  d /usr/share/doc/ai-tools-base/docs/b.md (replaced)' \
        '.........  d /usr/share/doc/ai-tools-base/docs/c.md (wrong color)' \
        '.........  d /usr/share/doc/ai-tools-base/docs/d.md (no state)' \
        '.........  d /usr/share/doc/ai-tools-base/docs/e.md (unknown state)' \
        'missing   d /usr/share/doc/ai-tools-base/docs/f.md (Permission denied)' \
        'missing   d /usr/share/doc/ai-tools-base/docs/g.md (Too many levels of symbolic links) (replaced)'
    status=1
    (( LAYOUT_FIXTURE_RPM_STATUS != 0 )) && return "${LAYOUT_FIXTURE_RPM_STATUS}"
    return "${status}"
}

# _layout_fixture_build_entry <path> <type> <owner> <mode> <acl> <flags> : one row of the tree at its owner, mode
# and ACL, a ghost row left absent, a payload path listed for the collector stub.
_layout_fixture_build_entry() {
    local path="$1" type="$2" owner="$3" mode="$4" acl="$5" flags="$6" acl_entry
    local -a acl_entries=()
    [[ ",${flags}," == *,ghost,* ]] && return 0
    mkdir -p "${path%/*}"
    case "${type}" in
        directory) install -d -o "${owner%%:*}" -g "${owner#*:}" -m "${mode}" -- "${path}"
                   ai_tools_control_plane__apply_mode "${mode}" "${path}" ;;
        file)      [[ -e "${path}" ]] || install -o root -g root -m 0644 /dev/null "${path}"
                   chown "${owner}" "${path}"; ai_tools_control_plane__apply_mode "${mode}" "${path}" ;;
        link)      ln -sfn /dev/null "${path}"; chown --no-dereference "${owner}" "${path}" ;;
    esac
    if [[ "${acl}" != - ]]; then
        IFS=, read -ra acl_entries <<< "${acl}"
        for acl_entry in "${acl_entries[@]}"; do setfacl -m "${acl_entry}" "${path}"; done
    fi
    _ai_tools_layout__is_content_verification_required "${type}" "${flags}" \
        && printf '%s\n' "${path#"${FIXTURE_ROOT}"}" >> "${LAYOUT_FIXTURE_PAYLOAD_LIST}"
    return 0
}

# layout_fixture_build_tree: build the tree from the table under FIXTURE_ROOT -- the sentinels of every package first,
# then each row the entry set yields, the shipped manifests' config directories among the dynamic rows -- replace rpm
# with layout_fixture_rpm, and assert that the build read no error line and that the dynamic rows are in the tree.
layout_fixture_build_tree() {
    local sentinel line build_errors=0
    local -a entry_lines=() row_fields=()
    for sentinel in /usr/local/libexec/ai-tools/ai-tools-admin /usr/local/libexec/ai-tools/ai-tools-bootstrap \
            /usr/local/lib/ai-tools/launch.d/claude-code.sh /usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh \
            /usr/local/lib/ai-tools/integrations.d/dotnet.conf /usr/local/lib/ai-tools/integrations.d/typesafe.conf \
            /usr/share/selinux/devel/include/distributed/ai_tools.if; do
        mkdir -p "${FIXTURE_ROOT}${sentinel%/*}"; : > "${FIXTURE_ROOT}${sentinel}"
    done
    printf 'config_dir=.claude\nlauncher=claude\n' > "${AGENTS_DIR}/claude-code.conf"
    printf 'config_dir=.codex\nlauncher=codex\n' > "${AGENTS_DIR}/codex.conf"
    chown -R root:root "${AGENTS_DIR}" "${OPERATOR_CONF}"; chmod 0755 "${AGENTS_DIR}"
    chmod 0644 "${AGENTS_DIR}"/*.conf "${OPERATOR_CONF}"
    LAYOUT_FIXTURE_PAYLOAD_LIST="${TESTDIR}/payload-paths"; : > "${LAYOUT_FIXTURE_PAYLOAD_LIST}"
    ai_tools_layout__read_entry_lines entry_lines || :
    for line in "${entry_lines[@]}"; do
        if [[ "${line}" == error$'\t'* ]]; then build_errors=$(( build_errors + 1 )); continue; fi
        ai_tools_layout__parse_stream_line "${line}" row_fields
        _layout_fixture_build_entry "${row_fields[0]}" "${row_fields[1]}" "${row_fields[2]}" "${row_fields[3]}" \
            "${row_fields[4]}" "${row_fields[6]}"
    done
    (( build_errors == 0 )) && pass "the tree is built from the entry set with no error line (${#entry_lines[@]} rows)" \
        || fail "the entry set carried ${build_errors} error line(s) while building: $(grep '^error' <<< "$(printf '%s\n' "${entry_lines[@]}")" | tr '\n\t' '| ')"
    [[ -d "${FIXTURE_ROOT}/opt/ai-tools/.claude" && -d "${FIXTURE_ROOT}${PROJECTS_HOME}/.config/ai-tools" ]] \
        && pass "the dynamic rows are in the tree: an agent config directory and an operator's config" \
        || fail "dynamic rows not built"
    rpm() { layout_fixture_rpm "$@"; }
}

# layout_fixture_reconcile [<without-rpm>] : the reconcile over the fixture root; prints its lines, then `rc=<status>`.
layout_fixture_reconcile() { local rc=0; ai_tools_layout__reconcile "${1:-0}" || rc=$?; printf 'rc=%s\n' "${rc}"; }
# layout_fixture_status <output> : the `rc=` line of a reconcile's output.
layout_fixture_status() { grep -o '^rc=.*' <<< "$1" | tail -n1; }
# layout_fixture_is_clean <output> : the run printed no line and exited 0.
layout_fixture_is_clean() { [[ "$(layout_fixture_status "$1")" == rc=0 && "$(grep -vc '^rc=' <<< "$1")" -eq 0 ]]; }
# layout_fixture_has_observation <output> <tag> <path> <field> [<rest>] : the output carries that tagged line.
layout_fixture_has_observation() { grep -q "^$2	$3	$4	${5:-}" <<< "$1"; }
# layout_fixture_brief <output> : a run's output for a failure line -- its first three lines, the count of the rest,
# and its last line (the `rc=`), tabs and newlines as `| `, so a run over the whole tree does not report every row.
# Where the last line is not `rc=0`, the `error` and `refused` lines among the rest follow the first three, ten at most,
# so a run that failed on one row names that row and its reason.
layout_fixture_brief() {
    local -a brief_lines=() brief_findings=()
    local brief_text brief_line brief_rest
    mapfile -t brief_lines <<< "$1"
    brief_text="$(printf '%s\n' "${brief_lines[@]:0:3}" | tr '\n\t' '| ')"
    brief_rest=$(( ${#brief_lines[@]} - 4 ))
    if (( brief_rest > 0 )) && [[ "${brief_lines[-1]}" != rc=0 ]]; then
        for brief_line in "${brief_lines[@]:3:brief_rest}"; do
            (( ${#brief_findings[@]} < 10 )) || break
            case "${brief_line}" in error$'\t'*|refused$'\t'*) brief_findings+=( "${brief_line}" ) ;; esac
        done
        if (( ${#brief_findings[@]} > 0 )); then
            brief_text+="$(printf '%s\n' "${brief_findings[@]}" | tr '\n\t' '| ')"
            brief_rest=$(( brief_rest - ${#brief_findings[@]} ))
        fi
    fi
    (( brief_rest > 0 )) && brief_text+="(+${brief_rest} more lines) "
    (( ${#brief_lines[@]} > 3 )) && brief_text+="${brief_lines[-1]}"
    printf '%s' "${brief_text}"
}
