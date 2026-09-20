#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/ancestor-config.sh
# Unit test for the unreadable-ancestor-configuration reader (ancestor-config.lib.sh), which the claim CLI
# and the launch wrapper both print from. It reports and does not change any file, so what the assertions are about is
# the OPPOSITE direction from most of this suite: an under-report is the failure, since it leaves a build failing
# on a path outside the project with no mention of the sandbox boundary, while an over-report costs a notice.
#
# Three properties carry the weight:
#   * BOTH LAYERS decide readability. The case the reader exists for passes DAC and fails the label -- an ancestor
#     config group-readable to the sandbox account and still denied, the file being user_home_t -- so a check computed
#     from mode and group alone answers "readable" exactly where the report is needed. Each layer is driven on its own,
#     with getenforce stubbed as a shell function, since a /tmp fixture takes a tmp type.
#   * THE MANIFEST decides what is looked for. Base does not name any toolchain, so an item that is not one component
#     is refused: a name is joined to an ancestor path and a marker is expanded as a glob there.
#   * THE BACKSTOP bounds the walk, which scans a user home root and stops at the /home entry containing it. Every
#     system directory stops it too, so a report does not name a file under /etc or /usr.
#
# Run as root via sudo (the suite contract): the manifest fixtures are honoured only while root-owned.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/ancestor-config.lib.sh"
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
section "ancestor configuration: the unreadable-config reader (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "ancestor configuration" "library not readable at ${LIB}"; finish; exit
fi
# The backstop bounds the walk and the library probes for it rather than sourcing it, so the test loads it the way both
# consumers do: first, and before the reader.
# shellcheck source=/dev/null
if ! source "${SAFE_PATHS_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
    skip "ancestor configuration" "could not source ${SAFE_PATHS_LIB}"; finish; exit
fi

mktestdir
# A umask is process state the fixtures inherit, and the manifest reader honours a file only while it is not group-
# or other-writable.
umask 022
integrations_dir="${TESTDIR}/integrations.d"
mkdir -p "${integrations_dir}"
chown root:root "${integrations_dir}"; chmod 0755 "${integrations_dir}"
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${TESTDIR}/operator.conf"
chown root:root "${TESTDIR}/operator.conf"; chmod 0644 "${TESTDIR}/operator.conf"
export AI_TOOLS_INTEGRATIONS_DIR="${integrations_dir}"
export AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf"

# The fixture toolchain: two markers and two configuration names, plus four items that must be refused -- a path,
# a traversal, and a name carrying a character outside each key's charset.
printf 'default_enable=no\nproject_markers=*.tfx sub/dir ../up\nancestor_config_files=.tfxrc Build.props ../up etc/passwd a|b\n' \
    > "${integrations_dir}/fixture.conf"
chown root:root "${integrations_dir}/fixture.conf"; chmod 0644 "${integrations_dir}/fixture.conf"

# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_unreadable_ancestor_configs >/dev/null 2>&1 \
        || ! declare -F ai_tools_session_can_read >/dev/null 2>&1 \
        || ! declare -F ai_tools_project_has_marker >/dev/null 2>&1 \
        || ! declare -F ai_tools_ancestor_scan_allowed >/dev/null 2>&1 \
        || ! declare -F ai_tools_ancestor_config_names >/dev/null 2>&1 \
        || ! declare -F ai_tools_project_markers >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the reader functions"; finish; exit
fi

# ── What the manifest declares, and what the charset refuses ─────────────────
names="$(ai_tools_ancestor_config_names | tr '\n' ' ')"
if [[ "${names}" == ".tfxrc Build.props " ]]; then
    pass "the declared configuration names are read, C-sorted, from an installed manifest"
else
    fail "declared names read as '${names}' (expected '.tfxrc Build.props ')"
fi

markers="$(ai_tools_project_markers | tr '\n' ' ')"
if [[ "${markers}" == "*.tfx " ]]; then
    pass "a marker that is a path or a traversal is refused, so a manifest names one directory"
else
    fail "declared markers read as '${markers}' (expected '*.tfx ')"
fi

# ── The walk's bound ─────────────────────────────────────────────────────────
bound_ok=true
for p in / /etc /usr /var /home /opt/ai-tools /tmp; do
    if ai_tools_ancestor_scan_allowed "${p}"; then
        fail "the walk would scan a protected directory: ${p}"; bound_ok=false
    fi
done
${bound_ok} && pass "every system directory, and /home itself, stops the walk"

if ai_tools_ancestor_scan_allowed "${TESTDIR}"; then
    pass "an ordinary directory is scanned"
else
    fail "an ordinary directory was refused: ${TESTDIR}"
fi

# The walk scans a user home root and stops at the /home entry that contains it. A toolchain walks through a home like
# any other directory, and reading one is not the tree-rewriting operation the backstop refuses a target for.
if [[ "${PROJECTS_HOME}" =~ ^/home/[^/]+$ ]]; then
    if ai_tools_ancestor_scan_allowed "${PROJECTS_HOME}"; then
        pass "a user home root is scanned, while /home above it stops the walk"
    else
        fail "a user home root was refused: ${PROJECTS_HOME}"
    fi
else
    skip "home root scanned" "${PROJECTS_HOME} is not a /home/<user> home root"
fi

# Fail closed without the backstop: an unbounded walk would read directories outside the window it defines. Driven
# in a subshell so the function stays defined for every later case.
if ( unset -f ai_tools_protected_path_match; ai_tools_ancestor_scan_allowed "${TESTDIR}" ); then
    fail "the walk proceeded with the protected-paths backstop unavailable"
else
    pass "the walk stops when the backstop that bounds it is not loaded"
fi

# ── Readability: the DAC layer ───────────────────────────────────────────────
# getenforce is stubbed Permissive, so the label half returns early and each case is about mode, group and ACL alone.
section "ancestor configuration: what the sandbox account can read"
getenforce() { printf 'Permissive\n'; }

readable() {
    local desc="$1" path="$2" expect="$3" rc=0
    ai_tools_session_can_read "${path}" || rc=$?
    if [[ "${expect}" == yes && "${rc}" -eq 0 ]] || [[ "${expect}" == no && "${rc}" -ne 0 ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, expected ${expect}"
    fi
}

: > "${TESTDIR}/world"; chmod 0644 "${TESTDIR}/world"
readable "a world-readable file is readable" "${TESTDIR}/world" yes

: > "${TESTDIR}/owner-only"; chmod 0600 "${TESTDIR}/owner-only"
readable "an owner-only file is not readable" "${TESTDIR}/owner-only" no

: > "${TESTDIR}/grouped"; chmod 0640 "${TESTDIR}/grouped"
if chgrp "${AI_TOOLS_SESSION_GROUP}" "${TESTDIR}/grouped" 2>/dev/null; then
    readable "0640 in the sandbox group is readable" "${TESTDIR}/grouped" yes
else
    skip "sandbox-group read" "group ${AI_TOOLS_SESSION_GROUP} is not present on this host"
fi

: > "${TESTDIR}/othergroup"; chmod 0640 "${TESTDIR}/othergroup"
chgrp "${PROJECTS_GROUP}" "${TESTDIR}/othergroup"
readable "0640 in another group is not readable" "${TESTDIR}/othergroup" no

if command -v setfacl >/dev/null 2>&1 && id "${AI_TOOLS_SESSION_ACCOUNT}" >/dev/null 2>&1; then
    : > "${TESTDIR}/acl"; chmod 0600 "${TESTDIR}/acl"
    setfacl -m "u:${AI_TOOLS_SESSION_ACCOUNT}:r" "${TESTDIR}/acl"
    readable "a named-user read ACL is readable" "${TESTDIR}/acl" yes
    # A mask that clears the read bit leaves the entry with no effective permission, which getfacl reports
    # on the entry's own line -- an entry counted from its declared bits alone would read as a grant.
    setfacl -m "m::-" "${TESTDIR}/acl"
    readable "an ACL entry masked to nothing is not readable" "${TESTDIR}/acl" no
else
    skip "named-user ACL" "setfacl or the account ${AI_TOOLS_SESSION_ACCOUNT} is not present"
fi

readable "a path that is not a regular file is not readable" "${TESTDIR}" no
readable "a missing path is not readable" "${TESTDIR}/absent" no

# ── Readability: the label layer ─────────────────────────────────────────────
# This is the half the measured case turns on. A /tmp fixture takes a tmp type, so the context is supplied by stubbing
# `ls`: what the section pins is the matching rule in the library, and libselinux is left to integration/selinux.sh.
section "ancestor configuration: what the confined domain can read"
getenforce() { printf 'Enforcing\n'; }

label_case() {
    local desc="$1" ctx="$2" expect="$3" rc=0 probe
    # The context is baked into the stub's BODY rather than read from a variable of this function's.
    # _ai_tools_session_type_readable declares a local named `context`, and a bash local is visible to everything it
    # calls, so a stub reading `${context}` sees the library's own empty one by the time it runs. It then prints a line
    # that does not carry any type, under which every case reads as "not a project type" -- the two positive cases fail,
    # and the two negative ones pass on the empty context rather than on the matching rule.
    eval "ls() { printf '%s %s\n' '${ctx}' '${TESTDIR}/world'; }"
    # The stub IS the fixture here, so its output is asserted before any verdict is read off it.
    probe="$(ls -Zd -- "${TESTDIR}/world")"
    if [[ "${probe}" != *"${ctx}"* ]]; then
        unset -f ls
        fail "${desc}: the ls stub did not supply the context (printed '${probe}')"
        return 0
    fi
    ai_tools_session_can_read "${TESTDIR}/world" || rc=$?
    unset -f ls
    if [[ "${expect}" == yes && "${rc}" -eq 0 ]] || [[ "${expect}" == no && "${rc}" -ne 0 ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, expected ${expect}"
    fi
}

label_case "a project-labelled file is readable under enforcing" \
    "system_u:object_r:ai_tools_project_t:s0" yes
label_case "a build-output-labelled file is readable under enforcing" \
    "system_u:object_r:ai_tools_project_build_t:s0" yes
label_case "a home-labelled file is not readable under enforcing, whatever its mode" \
    "unconfined_u:object_r:user_home_t:s0" no
label_case "an unlabelled host data file is not readable under enforcing" \
    "system_u:object_r:default_t:s0" no

getenforce() { printf 'Permissive\n'; }
readable "the label decides nothing where SELinux is not enforcing" "${TESTDIR}/world" yes

# ── The reader ───────────────────────────────────────────────────────────────
section "ancestor configuration: the reader"

project="${TESTDIR}/outer/inner/project"
mkdir -p "${project}"
: > "${project}/app.tfx"                                     # the marker that claims the project
: > "${TESTDIR}/outer/inner/.tfxrc";      chmod 0600 "${TESTDIR}/outer/inner/.tfxrc"
: > "${TESTDIR}/outer/Build.props";       chmod 0600 "${TESTDIR}/outer/Build.props"
: > "${TESTDIR}/outer/.tfxrc";            chmod 0644 "${TESTDIR}/outer/.tfxrc"
: > "${project}/.tfxrc";                  chmod 0600 "${project}/.tfxrc"

reported="$(ai_tools_unreadable_ancestor_configs "${project}" | tr '\n' ' ')"
if [[ "${reported}" == "${TESTDIR}/outer/inner/.tfxrc ${TESTDIR}/outer/Build.props " ]]; then
    pass "every unreadable declared file above the project is reported, nearest ancestor first"
else
    fail "the reader printed '${reported}'"
fi

if [[ "${reported}" != *"${TESTDIR}/outer/.tfxrc"* ]]; then
    pass "a readable ancestor file is not reported"
else
    fail "a readable ancestor file was reported"
fi

if [[ "${reported}" != *"${project}/.tfxrc"* ]]; then
    pass "a file inside the project is not reported -- the claim makes the tree readable"
else
    fail "a file inside the project was reported"
fi

# A project no installed toolchain's markers claim is not reported on, so a tree built with another toolchain stays
# silent.
unmarked="${TESTDIR}/outer/inner/other"
mkdir -p "${unmarked}"
reported="$(ai_tools_unreadable_ancestor_configs "${unmarked}")"
if [[ -z "${reported}" ]]; then
    pass "a project no declared marker claims reports nothing"
else
    fail "an unmarked project reported '${reported}'"
fi

# A host whose installed manifests declare neither key reports nothing, which is the state of a host with no integration
# installed.
rm -f "${integrations_dir}/fixture.conf"
reported="$(ai_tools_unreadable_ancestor_configs "${project}")"
if [[ -z "${reported}" ]]; then
    pass "a host declaring no marker and no configuration name reports nothing"
else
    fail "a host with no manifest reported '${reported}'"
fi

# An untrusted manifest does not yield any declaration, so the report shrinks: a file the sandbox account could write
# does not supply a name to it.
printf 'project_markers=*.tfx\nancestor_config_files=.tfxrc\n' > "${integrations_dir}/fixture.conf"
chmod 0666 "${integrations_dir}/fixture.conf"
reported="$(ai_tools_unreadable_ancestor_configs "${project}")"
if [[ -z "${reported}" ]]; then
    pass "a group-writable manifest declares nothing, so nothing is reported"
else
    fail "an untrusted manifest was read: '${reported}'"
fi

finish
