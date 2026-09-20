#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/audit.sh
# Unit test for the kernel-record section of the audit reader (ai-tools-audit) and for the policy rule that feeds it.
# What it pins is the half no host can demonstrate on demand: the records come from a trail only the kernel writes,
# which is the whole basis for reporting them as evidence, so there is no way for a test to produce one. Fixture records
# and stubbed tools are therefore not a convenience here -- they are the only way to drive this code at all, and every
# assertion in this file is about a decision the helper makes.
#
#   1. THE POLICY SAYS WHAT THE READER LOOKS FOR. The core module's `auditallow` names the confined domain as SUBJECT,
#      the exec entrypoint type as OBJECT and execute_no_trans as the permission, and the reader holds a record
#      to the same three. A policy that drifted from any of them would record something other than an in-session
#      entrypoint exec, or no record at all, while the section went on reporting a clean window.
#   2. THE AVC LINE IS THE PREDICATE. A block is a record only where one of its AVC lines is the auditallow's own:
#      `granted`, the permission, both types. Another domain's denial, a grant of another permission, and the same
#      permission on another object type in the same window are each dropped, and a block the AVC admits is kept
#      whatever its syscall number, so an exec through execveat(2) is not a way past the report.
#   3. THE CLASSIFICATION IS AGENT-AGNOSTIC AND DIRECTIONAL. Driven over a SYNTHETIC pair of manifests, so a literal
#      agent name in the code path fails the fixture. What is folded is read from the record -- a bare argv0 for
#      an agent's dispatch of a tool it bundles -- and an exec naming a PATH is a finding, which is what keeps
#      the cross-agent direction, one agent's session starting another's entrypoint, reported.
#   4. THE FOLDED FIELD IS THE CALLER'S, AND THE REPORT SAYS SO. A borrowed argv0 lands in the counted class;
#      the record is still written, and the count names what it folded.
#   5. A RECORD'S FIELDS ARE UNTRUSTED INPUT. argv0 and the exec'd path are an agent's to choose, so a value carrying
#      the record separator cannot fabricate a column in the rendered table.
#   6. A READ THAT FAILS IS NOT AN ANSWER. The module list is captured rather than piped (a `grep -q` on a pipe loses
#      the match to SIGPIPE on a host with many modules).
#   7. EACH HOST STATE REPORTS AS ITSELF. No audit daemon, no policy, a policy without the rule, and the rule
#      in force are different readings, and only the last makes an empty window mean "no such exec happened".
#
# The helper is SOURCED, which is inert by construction (it does not parse an argument or read a trail at file scope),
# and `ausearch`, `auditctl`, `getenforce`, `semodule` and `sesearch` are stubbed as shell FUNCTIONS --
# which `command -v` resolves ahead of any file, so no stub needs an executable bit or an exec mount. No policy is
# loaded, no host audit state is read, and no process is signalled. Run as root with the rest of the suite;
# the manifest-backed section needs root, since the trust predicate requires a root-owned manifest, and it says
# so where it skips.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

section "audit reader: the kernel record of an in-session entrypoint exec (unit)"

# ── The helper, sourced ───────────────────────────────────────────────────────────────────────
# The deployed helper is preferred (it is the token-substituted artifact the operator runs); the repo source is
# the fallback, so the suite covers it before the first install of a host.
AUDIT_HELPER="/usr/local/libexec/ai-tools/ai-tools-audit"
if [[ ! -r "${AUDIT_HELPER}" ]]; then
    AUDIT_HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-audit.sh"
fi
if [[ ! -r "${AUDIT_HELPER}" ]]; then
    skip "audit reader" "helper not readable at either the installed or the source path"
    finish; exit
fi

mktestdir

# The harness and the helper both name the sandbox account SANDBOX_USER and both declare it readonly, so that one
# failure is expected on source; every other byte on stderr is not, and is asserted to be absent rather than discarded
# with it.
source_errors="${TESTDIR}/source-stderr"
# shellcheck source=/dev/null
source "${AUDIT_HELPER}" 2>"${source_errors}" || true

if ! declare -F parse_entrypoint_exec_records >/dev/null 2>&1 \
        || ! declare -F classify_entrypoint_exec >/dev/null 2>&1; then
    fail "sourcing ${AUDIT_HELPER} defined no parser -- the helper is not inert on source:"$'\n'"$(cat "${source_errors}")"
    finish; exit
fi
pass "sourcing the helper is inert: it defines the parser and reads no trail"
unexpected="$(grep -v 'SANDBOX_USER: readonly variable' "${source_errors}" || true)"
if [[ -z "${unexpected}" ]]; then
    pass "sourcing the helper writes nothing to stderr but the expected readonly collision"
else
    fail "sourcing the helper wrote to stderr: ${unexpected}"
fi

# ── 1. The policy rule and the reader agree ───────────────────────────────────────────────────
# The three labels the reader holds a record to are read from the helper it sourced, and the rule is read
# from the policy source, so what is asserted is their lockstep and not a literal this file spells twice.
section "the auditallow the policy declares is the record the reader keeps"

POLICY_SOURCE="${ROOT}/selinux/policy/ai_tools.te"
if [[ ! -r "${POLICY_SOURCE}" ]]; then
    skip "policy rule" "not a source checkout (no ${POLICY_SOURCE})"
else
    want_rule="auditallow ${ENTRYPOINT_EXEC_SUBJECT_TYPE} ${ENTRYPOINT_EXEC_OBJECT_TYPE}:file ${ENTRYPOINT_EXEC_PERMISSION};"
    # Captured, then matched: a `grep -q` at the end of a pipe exits at the match and leaves the writer to SIGPIPE,
    # which pipefail reports as no match.
    policy_rules="$(grep -v '^[[:space:]]*#' "${POLICY_SOURCE}" || true)"
    rule_lines="$(grep -F "${want_rule}" <<<"${policy_rules}" || true)"
    if [[ "$(grep -c . <<<"${rule_lines}")" == 1 ]]; then
        pass "the core module declares exactly one uncommented ${want_rule}"
    else
        fail "the core module declares $(grep -c . <<<"${rule_lines}") uncommented lines matching ${want_rule}, expected 1"
    fi
    # The audited access must be an access the domain holds, or the auditallow records an exec that is refused.
    if grep -qE "^allow ${ENTRYPOINT_EXEC_SUBJECT_TYPE} ${ENTRYPOINT_EXEC_OBJECT_TYPE}:file ${ENTRYPOINT_EXEC_PERMISSION};" <<<"${policy_rules}"; then
        pass "the same access is allowed, so the audited record is of an exec that ran"
    else
        fail "no allow beside the auditallow: the record would be of a refused exec"
    fi
fi

# ── 2. The AVC line ───────────────────────────────────────────────────────────────────────────
section "the AVC line: which record is the auditallow's own"

ACME_EXE='/opt/ai-tools/.nvm/versions/node/v9.9.9/lib/node_modules/@acme/experimental/bin/acme'
BETA_EXE='/opt/ai-tools/.nvm/versions/node/v9.9.9/lib/node_modules/@beta/agent/bin/beta.bin'
SESSION_CONTEXT='unconfined_u:unconfined_r:ai_tools_t:s0-s0:c0.c1023'
ENTRYPOINT_CONTEXT='system_u:object_r:ai_tools_exec_t:s0'

# avc_line <verb> <perms> <path> <scontext> <tcontext> [<tclass>] : PRINT one raw AVC line in the shape the kernel
# writes and ausearch prints without `-i`.
avc_line() {
    printf 'type=AVC msg=audit(1758279723.221:914): avc:  %s  { %s } for  pid=8842 comm="acme" path="%s" dev="dm-1" ino=25173942 scontext=%s tcontext=%s tclass=%s permissive=0\n' \
        "$1" "$2" "$3" "$4" "$5" "${6:-file}"
}
assert_avc() {
    local desc="$1" expected="$2" line="$3"
    if avc_line_records_entrypoint_exec "${line}"; then got=kept; else got=dropped; fi
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: ${got}, expected ${expected}"; fi
}
assert_avc "a granted execute_no_trans by the session domain on the entry type is kept" kept \
    "$(avc_line granted execute_no_trans "${ACME_EXE}" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}")"
assert_avc "the type is read as the context's type component, so a system_u subject is the same domain" kept \
    "$(avc_line granted execute_no_trans "${ACME_EXE}" "system_u:system_r:ai_tools_t:s0" "${ENTRYPOINT_CONTEXT}")"
assert_avc "a grant of several permissions holding the audited one is kept" kept \
    "$(avc_line granted "read execute_no_trans" "${ACME_EXE}" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}")"
assert_avc "a denial is not the auditallow's record" dropped \
    "$(avc_line denied execute_no_trans "${ACME_EXE}" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}")"
assert_avc "a grant of another permission on the same pair is dropped" dropped \
    "$(avc_line granted read "${ACME_EXE}" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}")"
assert_avc "the same permission on the agent's home type (a hook script) is dropped" dropped \
    "$(avc_line granted execute_no_trans /opt/ai-tools/.claude/hook.sh "${SESSION_CONTEXT}" "system_u:object_r:ai_tools_home_t:s0")"
assert_avc "the same pair from another subject domain is dropped" dropped \
    "$(avc_line granted execute_no_trans "${ACME_EXE}" "system_u:system_r:init_t:s0" "${ENTRYPOINT_CONTEXT}")"
assert_avc "a type that merely starts with the domain's name is not the domain" dropped \
    "$(avc_line granted execute_no_trans "${ACME_EXE}" "system_u:system_r:ai_tools_t_other:s0" "${ENTRYPOINT_CONTEXT}")"
assert_avc "a class other than file is dropped" dropped \
    "$(avc_line granted execute_no_trans "${ACME_EXE}" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}" dir)"

# ── 3/4. Classification, over a synthetic pair of agents ──────────────────────────────────────
# Neither agent here is one this project ships: an agent name reaching the code path from anywhere but a manifest would
# fail every case in this section.
section "classification: which record is expected, which is a finding"

AGENT_NAMES=(acme beta)
AGENT_PATTERNS=(
    '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/experimental/bin/acme'
    '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@beta/agent/bin/beta\.bin'
)

assert_class() {
    local desc="$1" expected="$2" exe="$3" argv0="$4" got
    got="$(classify_entrypoint_exec "${exe}" "${argv0}")"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: got '${got}', expected '${expected}'"; fi
}

assert_class "an entrypoint exec'd at its real path is a finding naming the agent" \
    "finding acme" "${ACME_EXE}" "${ACME_EXE}"
assert_class "a bare argv0 into the agent's own entrypoint is its dispatch of a tool it bundles" \
    "self acme" "${ACME_EXE}" acme-apply
assert_class "an agent declaring nothing needs no declaration to have its dispatch counted" \
    "self beta" "${BETA_EXE}" beta-apply
assert_class "a dispatch is told by the bare name, so a path is a finding whichever agent's it is" \
    "finding beta" "${BETA_EXE}" "${ACME_EXE}"
assert_class "an empty argv0 is not a bare name, and is reported" \
    "finding acme" "${ACME_EXE}" ""
assert_class "a file no manifest claims is a finding naming no agent" \
    "finding " /usr/bin/env env
# An unclaimed exe is a finding under EVERY argv0: a fold that read the bare name alone would hand a session a way
# to have an unknown binary counted rather than reported.
assert_class "a file no manifest claims is a finding even under a bare argv0" \
    "finding " /usr/bin/env env
# The version directory is the one variable part of an entrypoint pattern, and a launch resolves through it, so a record
# from any installed toolchain version must classify.
assert_class "the pattern spans the Node version directory" \
    "self acme" "${ACME_EXE/v9.9.9/v10.0.1}" acme-exec-wrapper

# ── The map, built through the real resolver over root-owned fixture manifests ────────────────
section "the agent map comes from the installed manifests, not from the code"

if [[ "${EUID}" -ne 0 ]]; then
    skip "agent map" "the manifest trust predicate requires a root-owned manifest; run as root with the suite"
else
    agents_dir="${TESTDIR}/agents.d"
    mkdir -p "${agents_dir}"; chmod 0755 "${agents_dir}"
    printf 'npm_package=@acme/experimental\nlauncher=acme\nentrypoint_fcontext=%s\n' \
        "${AGENT_PATTERNS[0]}" > "${agents_dir}/acme.conf"
    printf 'npm_package=@beta/agent\nlauncher=beta\nentrypoint_fcontext=%s\n' \
        "${AGENT_PATTERNS[1]}" > "${agents_dir}/beta.conf"
    # An agent with no entrypoint declaration: no pattern to match a record against, so it is not in the map at all.
    printf 'npm_package=@gamma/agent\nlauncher=gamma\n' > "${agents_dir}/gamma.conf"
    chmod 0644 "${agents_dir}"/*.conf

    AGENT_NAMES=(); AGENT_PATTERNS=()
    AI_TOOLS_AGENTS_DIR="${agents_dir}" build_agent_entrypoint_map
    if [[ "${AGENT_NAMES[*]}" == "acme beta" ]]; then
        pass "the map holds every installed agent declaring an entrypoint, in manifest order"
    else
        fail "the map holds '${AGENT_NAMES[*]}', expected 'acme beta'"
    fi
    # Read back through the map the resolver built, so what classifies a record is the pattern a manifest carries rather
    # than the one this file set by hand.
    assert_class "a record classifies against the pattern the built map holds" \
        "self acme" "${ACME_EXE}" acme-exec-wrapper
    assert_class "an agent with no entrypoint declaration matches nothing in the built map" \
        "finding " "/opt/ai-tools/.nvm/versions/node/v9.9.9/lib/node_modules/@gamma/agent/bin/gamma" gamma
fi

# ── 5. The record parser ──────────────────────────────────────────────────────────────────────
section "record parsing: one record per event, fields read from the lines that carry them"

AGENT_NAMES=(acme beta)
AGENT_PATTERNS=(
    '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/experimental/bin/acme'
    '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@beta/agent/bin/beta\.bin'
)

# Raw records, which is what the helper reads and is itself a security choice: auditd hex-encodes any untrusted string
# holding a space, a quote or a control byte, so every field is one token on one line. The `-i` form would decode those
# before the parser saw them, which is the injection the last case here drives. `-v` is load-bearing: without it od
# collapses a run of identical bytes to `*`, so a fixture of repeated bytes encodes to a token that is not the value it
# stands for.
hex_of() { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'; }
iso_of() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S'; }

# granted_avc <epoch> <serial> <pid> <path> : PRINT the auditallow's own AVC line for a fixture event.
granted_avc() {
    printf 'type=AVC msg=audit(%s.000:%s): avc:  granted  { execute_no_trans } for  pid=%s comm="acme" path=%s dev="dm-1" ino=25173942 scontext=%s tcontext=%s tclass=file permissive=0\n' \
        "$1" "$2" "$3" "$4" "${SESSION_CONTEXT}" "${ENTRYPOINT_CONTEXT}"
}

ACME_AT=1758279723
BETA_AT=1758282250
NODE_AT=1758283000
INJECT_AT=1758284000
DENIAL_AT=1758279000
HOOK_AT=1758278000
KEYED_AT=1758277000
EXECVEAT_AT=1758285500

# An argv0 whose bytes carry a newline and a counterfeit SYSCALL line naming a different exe. Under `-i` this would
# arrive as an extra LINE and the parser would read the counterfeit; hex-encoded, it is one token.
forged_argv0="$(printf 'evil\ntype=SYSCALL msg=audit(%s.000:999): ppid=0 pid=0 exe="/bin/sh"' "${INJECT_AT}")"

records="$(parse_entrypoint_exec_records <<REC
----
type=PROCTITLE msg=audit(${DENIAL_AT}.000:900): proctitle="bash"
type=SYSCALL msg=audit(${DENIAL_AT}.000:900): arch=c000003e syscall=59 success=no exit=-13 ppid=8801 pid=8810 uid=978 comm="bash" exe="/usr/bin/bash" subj=${SESSION_CONTEXT} key=(null)
type=AVC msg=audit(${DENIAL_AT}.000:900): avc:  denied  { execute } for  pid=8810 comm="bash" name="hostname" dev="dm-1" ino=25173 scontext=${SESSION_CONTEXT} tcontext=system_u:object_r:hostname_exec_t:s0 tclass=file permissive=0
----
type=EXECVE msg=audit(${HOOK_AT}.000:901): argc=1 a0="/opt/ai-tools/.claude/hook.sh"
type=SYSCALL msg=audit(${HOOK_AT}.000:901): arch=c000003e syscall=59 success=yes exit=0 ppid=8801 pid=8811 uid=978 comm="hook.sh" exe="/usr/bin/bash" subj=${SESSION_CONTEXT} key=(null)
type=AVC msg=audit(${HOOK_AT}.000:901): avc:  granted  { execute_no_trans } for  pid=8811 comm="bash" path="/opt/ai-tools/.claude/hook.sh" dev="dm-1" ino=25174 scontext=${SESSION_CONTEXT} tcontext=system_u:object_r:ai_tools_home_t:s0 tclass=file permissive=0
----
type=EXECVE msg=audit(${KEYED_AT}.000:902): argc=1 a0="${ACME_EXE}"
type=SYSCALL msg=audit(${KEYED_AT}.000:902): arch=c000003e syscall=59 success=yes exit=0 ppid=4242 pid=8790 uid=978 comm="acme" exe="${ACME_EXE}" subj=${SESSION_CONTEXT} key="ai-tools-exec"
----
type=PROCTITLE msg=audit(${ACME_AT}.000:914): proctitle="acme"
type=PATH msg=audit(${ACME_AT}.000:914): item=0 name="${ACME_EXE}" obj=${ENTRYPOINT_CONTEXT}
type=EXECVE msg=audit(${ACME_AT}.000:914): argc=2 a0="acme-apply" a1="--help"
type=SYSCALL msg=audit(${ACME_AT}.000:914): arch=c000003e syscall=59 success=yes exit=0 ppid=8801 pid=8842 uid=978 comm="acme" exe="${ACME_EXE}" subj=${SESSION_CONTEXT} key=(null)
$(granted_avc "${ACME_AT}" 914 8842 "\"${ACME_EXE}\"")
----
$(granted_avc "${BETA_AT}" 915 9001 "$(hex_of "${BETA_EXE}")")
type=EXECVE msg=audit(${BETA_AT}.000:915): argc=1 a0=$(hex_of "${BETA_EXE}")
type=SYSCALL msg=audit(${BETA_AT}.000:915): arch=c000003e syscall=59 success=yes ppid=8801 pid=9001 uid=978 comm="bash" exe="${BETA_EXE}" subj=${SESSION_CONTEXT} key=(null)
----
type=EXECVE msg=audit(${NODE_AT}.000:916): argc=1 a0="node"
type=SYSCALL msg=audit(${NODE_AT}.000:916): arch=c000003e syscall=59 success=yes ppid=1 pid=9100 uid=978 comm="x" exe="/opt/ai-tools/.nvm/versions/node/v9.9.9/bin/node" subj=${SESSION_CONTEXT} key=(null)
$(granted_avc "${NODE_AT}" 916 9100 "\"/opt/ai-tools/.nvm/versions/node/v9.9.9/bin/node\"")
----
type=EXECVE msg=audit(${INJECT_AT}.000:917): argc=1 a0=$(hex_of "${forged_argv0}")
type=SYSCALL msg=audit(${INJECT_AT}.000:917): arch=c000003e syscall=59 success=yes ppid=8801 pid=9200 uid=978 comm="acme" exe="${ACME_EXE}" subj=${SESSION_CONTEXT} key=(null)
$(granted_avc "${INJECT_AT}" 917 9200 "\"${ACME_EXE}\"")
----
type=EXECVE msg=audit(${EXECVEAT_AT}.000:918): argc=1 a0="${BETA_EXE}"
type=SYSCALL msg=audit(${EXECVEAT_AT}.000:918): arch=c000003e syscall=322 success=yes ppid=8801 pid=9300 uid=978 comm="beta.bin" exe="${BETA_EXE}" subj=${SESSION_CONTEXT} key=(null)
$(granted_avc "${EXECVEAT_AT}" 918 9300 "\"${BETA_EXE}\"")
----
type=PROCTITLE msg=audit(1758286000.000:919): proctitle="no-avc-line"
REC
)"

assert_records() {
    local desc="$1" pattern="$2"
    if grep -qE -- "${pattern}" <<<"${records}"; then pass "${desc}"; else fail "${desc}: no line matched ${pattern} in: $(tr '\n' '|' <<<"${records}")"; fi
}

if [[ "$(grep -c . <<<"${records}")" == 5 ]]; then
    pass "of nine events, the five carrying the auditallow's AVC line are records"
else
    fail "expected 5 records from 9 events, got $(grep -c . <<<"${records}"): $(tr '\n' '|' <<<"${records}")"
fi
if grep -q 'hostname\|/usr/bin/bash' <<<"${records}"; then
    fail "another domain's denial, or a hook script's exec, was read as a record: $(tr '\n' '|' <<<"${records}")"
else
    pass "a denial and a grant on another object type in the same window are not records"
fi
if grep -q "$(iso_of "${KEYED_AT}")" <<<"${records}"; then
    fail "a keyed SYSCALL event with no AVC line was read as a record: $(tr '\n' '|' <<<"${records}")"
else
    pass "an event with no AVC line records no exec, whatever key its SYSCALL line carries"
fi
assert_records "a self-dispatch is classed apart and names the argv0 it was counted for" \
    "^self\|exec\|$(iso_of "${ACME_AT}")\|WARNING\|acme exec.d its own entrypoint as acme-apply$"
assert_records "another agent's entrypoint is a finding naming the agent, the pids and the argv0" \
    "^finding\|exec\|$(iso_of "${BETA_AT}")\|WARNING\|beta entrypoint started from inside a session \(pid 9001, parent 8801, argv0 .*beta\.bin\)$"
assert_records "a hex-encoded field is decoded, so the argv0 reads as the caller passed it" \
    "argv0 ${BETA_EXE}\)$"
assert_records "an exe no manifest claims is a finding naming the file" \
    "^finding\|exec\|$(iso_of "${NODE_AT}")\|WARNING\|a file no installed manifest claims .*exe /opt/ai-tools/.*/bin/node, pid 9100, parent 1"
assert_records "an exec through execveat(2) is the same record: the syscall number is not a way past the report" \
    "^finding\|exec\|$(iso_of "${EXECVEAT_AT}")\|WARNING\|beta entrypoint started from inside a session \(pid 9300"
if grep -qE "\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\|" <<<"${records}"; then
    pass "a raw record's epoch renders as the sortable date the table splits"
else
    fail "no record carries a sortable timestamp: $(tr '\n' '|' <<<"${records}")"
fi

# The injection. The forged text stays INSIDE the argv0 field of the event that carried it, so what is asserted is
# what it did not become: a record of its own, and a replacement for the exe the kernel recorded.
if grep -q 'exe /bin/sh' <<<"${records}"; then
    fail "a forged SYSCALL line inside argv0 became a record: $(tr '\n' '|' <<<"${records}")"
else
    pass "a counterfeit record line planted in argv0 is not parsed as a record of its own"
fi
assert_records "the event carrying the forged argv0 keeps the exe the kernel recorded, and stays a finding" \
    "^finding\|exec\|$(iso_of "${INJECT_AT}")\|WARNING\|acme entrypoint started from inside a session \(pid 9200, parent 8801, argv0 evil\?type=SYSCALL"
if [[ "$(grep -c . <<<"${records}")" == 5 ]]; then
    pass "the forged line did not add a record of its own"
else
    fail "record count changed under the forged argv0"
fi
# The sanitizer's allowlist is what neutralizes the newline; asserted here because it is the step that makes a decoded
# field safe to print at all.
if grep -q 'evil?type=SYSCALL' <<<"${records}"; then
    pass "a control byte in a decoded field is reduced to ? before it reaches the report"
else
    fail "the newline in argv0 was not neutralized: $(tr '\n' '|' <<<"${records}")"
fi

# The exec'd file is the AVC line's own `path=` -- the object whose label matched -- in whichever order the lines
# arrive, and the SYSCALL line's `exe=` stands in only where the AVC line carries none.
path_records="$(parse_entrypoint_exec_records <<REC
----
$(granted_avc "${ACME_AT}" 920 700 "\"${ACME_EXE}\"")
type=SYSCALL msg=audit(${ACME_AT}.000:920): arch=c000003e syscall=59 ppid=1 pid=700 exe="/usr/bin/other" subj=${SESSION_CONTEXT}
----
type=SYSCALL msg=audit(${ACME_AT}.000:921): arch=c000003e syscall=59 ppid=1 pid=701 exe="/usr/bin/other" subj=${SESSION_CONTEXT}
$(granted_avc "${ACME_AT}" 921 701 "\"${ACME_EXE}\"")
----
type=SYSCALL msg=audit(${ACME_AT}.000:922): arch=c000003e syscall=59 ppid=1 pid=702 exe="${BETA_EXE}" subj=${SESSION_CONTEXT}
type=AVC msg=audit(${ACME_AT}.000:922): avc:  granted  { execute_no_trans } for  pid=702 comm="x" dev="dm-1" ino=1 scontext=${SESSION_CONTEXT} tcontext=${ENTRYPOINT_CONTEXT} tclass=file permissive=0
----
type=AVC msg=audit(${ACME_AT}.000:923): avc:  granted  { execute_no_trans } for  pid=703 comm="x" dev="dm-1" ino=1 scontext=${SESSION_CONTEXT} tcontext=${ENTRYPOINT_CONTEXT} tclass=file permissive=0
REC
)"
if [[ "$(grep -c 'acme entrypoint started from inside a session (pid 70[01]' <<<"${path_records}")" == 2 ]]; then
    pass "the AVC line's path is the exec'd file whether it precedes or follows the SYSCALL line"
else
    fail "the AVC path did not decide the exe in both orders: $(tr '\n' '|' <<<"${path_records}")"
fi
if grep -q 'beta entrypoint started from inside a session (pid 702' <<<"${path_records}"; then
    pass "an AVC line carrying no path falls back to the SYSCALL line's exe"
else
    fail "the SYSCALL exe did not stand in for a missing AVC path: $(tr '\n' '|' <<<"${path_records}")"
fi
if grep -q 'exe ?, pid 703, parent ?' <<<"${path_records}"; then
    pass "an event the AVC line admits and no other line describes is still a finding, with its fields unknown"
else
    fail "a bare AVC event was dropped rather than reported: $(tr '\n' '|' <<<"${path_records}")"
fi

# A field longer than the display limit is cut rather than pushing the table off the screen.
long_argv0="$(printf 'A%.0s' {1..600})"
long_record="$(parse_entrypoint_exec_records <<REC
----
type=EXECVE msg=audit(${NODE_AT}.000:930): argc=1 a0=$(hex_of "${long_argv0}")
type=SYSCALL msg=audit(${NODE_AT}.000:930): arch=c000003e syscall=59 ppid=1 pid=930 exe="${BETA_EXE}"
$(granted_avc "${NODE_AT}" 930 930 "\"${BETA_EXE}\"")
REC
)"
if [[ "${long_record}" == *"AAA..."* ]] && (( ${#long_record} < 450 )); then
    pass "an argv0 longer than the display limit is clamped and marked"
else
    fail "a 600-character argv0 rendered as ${#long_record} characters: ${long_record:0:120}"
fi

# ── 6. The host reads the section's honesty rests on ─────────────────────────────────────────
section "resolving the policy: a read that fails must not read as an answer"

# THE MODULE LIST IS CAPTURED, NOT PIPED. A host with a few hundred policy modules prints tens of kilobytes here,
# and `semodule -l | grep -q` under `pipefail` loses the answer on exactly that host: grep exits at the match, semodule
# dies of SIGPIPE writing the rest, and the non-zero pipeline reads as "the module is not loaded". The fixture puts
# the module on the FIRST line and pads past a pipe buffer, which is the shape that reproduces it every time.
ausearch() { return 0; }
auditctl() { [[ "${1:-}" == "-s" ]] && printf 'enabled 1 failure 1 pid 812\n'; return 0; }
getenforce() { printf 'Enforcing\n'; }
semodule() {
    printf 'ai_tools\n'
    # shellcheck disable=SC2046  # each padding module is its own line, which is the point
    printf 'pad_module_%04d\n' $(seq 1 600)
}
sesearch() { printf 'auditallow ai_tools_t ai_tools_exec_t:file { execute_no_trans };\n'; }
if (( $(semodule -l | wc -c) > 4096 )); then
    pass "the module-list fixture is longer than a pipe buffer, which is what makes this a test"
else
    fail "the module-list fixture is too short to reproduce the failure it is here to catch"
fi
if [[ "$(entrypoint_exec_state)" == loaded ]]; then
    pass "a loaded module reads as loaded however many other modules the host carries"
else
    fail "a loaded module read as '$(entrypoint_exec_state)' behind a long module list"
fi
semodule() { printf 'ai_tools\t0.7.0\n'; }
if [[ "$(entrypoint_exec_state)" == loaded ]]; then
    pass "a semodule printing a version column beside the name reads as loaded"
else
    fail "a version column made the module read as '$(entrypoint_exec_state)'"
fi
semodule() { printf 'ai_tools_dotnet\nai_tools_tmpmap\n'; }
if [[ "$(entrypoint_exec_state)" == no-selinux ]]; then
    pass "a module whose name merely starts with the core's is not the core"
else
    fail "a layout module read as the core: '$(entrypoint_exec_state)'"
fi
unset -f ausearch auditctl getenforce semodule sesearch

# ── 7. The host states ────────────────────────────────────────────────────────────────────────
# `command -v` resolves a shell function ahead of any file, so these stubs need no executable bit and no exec mount
# ([[test-fixtures-need-exec-mount]] is why that matters). Each state is driven through the same renderer the report
# calls, and asserted by MESSAGE CODE, so the wording stays free to change.
section "host states: what the section says when it cannot read, and when it can"

# The collector rebuilds the agent map from the host's installed manifests on every call, which is what makes a disabled
# agent's package visible to it and is driven for real in the manifest-backed section. Here that read is stubbed
# to the synthetic pair, so what follows is about the partition and the states, whatever agents this host happens
# to have installed. Asserted after the call rather than assumed: the first draft of it set the arrays directly
# and the real builder overwrote them, and every record then classified as unknown.
build_agent_entrypoint_map() {
    AGENT_NAMES=(acme beta)
    # shellcheck disable=SC2034  # read by classify_entrypoint_exec in the sourced helper
    AGENT_PATTERNS=(
        '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@acme/experimental/bin/acme'
        '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@beta/agent/bin/beta\.bin'
    )
}

# shellcheck disable=SC2034  # read by collect_entrypoint_execs in the sourced helper, which formats the search window
CUTOFF_EPOCH="$(date -d '2026-09-01' +%s)"
AI_TOOLS_MSG_PLAIN=1
export AI_TOOLS_MSG_PLAIN

state_output() { render_entrypoint_section 2>&1; }
assert_state() {
    local desc="$1" expected="$2"
    if [[ "${ENTRYPOINT_EXEC_STATE}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: read as '${ENTRYPOINT_EXEC_STATE}', expected ${expected}"; fi
}

getenforce() { printf 'Enforcing\n'; }
semodule() { printf 'ai_tools\n'; }
sesearch() { printf 'auditallow ai_tools_t ai_tools_exec_t:file { execute_no_trans };\n'; }

# No audit tooling that can answer. `command -v` resolves the stubs themselves, so absence is driven by the daemon's own
# answer instead: an auditctl reporting kernel auditing switched off is the same reading as no daemon, and is the state
# a container is in.
ausearch() { return 127; }
auditctl() { [[ "${1:-}" == "-s" ]] && { printf 'enabled 0 failure 1 pid 0\n'; return 0; }; return 0; }
collect_entrypoint_findings
assert_msg MSG-C6E6 "$(state_output)" "no audit daemon reports as itself, not as a clean window"
assert_state "kernel auditing switched off reads as no-auditd" no-auditd
# Kernel auditing on with no daemon: the records go to the kernel log, which is not the trail this helper reads.
auditctl() { [[ "${1:-}" == "-s" ]] && { printf 'enabled 1 failure 1 pid 0\n'; return 0; }; return 0; }
collect_entrypoint_findings
assert_state "kernel auditing with no daemon writing the log reads as no-auditd" no-auditd

# The daemon is there; the policy is not.
auditctl() { [[ "${1:-}" == "-s" ]] && { printf 'enabled 1 failure 1 pid 812 rate_limit 0\n'; return 0; }; return 0; }
getenforce() { printf 'Disabled\n'; }
collect_entrypoint_findings
assert_msg MSG-V8Z9 "$(state_output)" "SELinux disabled reports as the rule not in force"
assert_state "SELinux disabled reads as no-selinux" no-selinux
getenforce() { printf 'Enforcing\n'; }
semodule() { printf 'other_module\n'; }
collect_entrypoint_findings
assert_msg MSG-V8Z9 "$(state_output)" "a host without the core module reports as the rule not in force"
assert_state "the core module absent reads as no-selinux" no-selinux
if grep -q 'install-selinux.sh install' <<<"$(state_output)"; then
    pass "the remedy for a missing policy names the install"
else
    fail "the remedy for a missing policy does not name the install: $(tr '\n' '|' <<<"$(state_output)")"
fi

# The core module is loaded and predates the rule.
semodule() { printf 'ai_tools\n'; }
sesearch() { return 0; }
collect_entrypoint_findings
assert_msg MSG-V8Z9 "$(state_output)" "a loaded module without the rule reports as the rule not in force"
assert_state "a loaded module without the auditallow reads as no-rule" no-rule
if grep -q 'install-selinux.sh rebuild' <<<"$(state_output)"; then
    pass "the remedy for a module predating the rule names the rebuild"
else
    fail "the remedy for a module predating the rule does not name the rebuild: $(tr '\n' '|' <<<"$(state_output)")"
fi

# The rule is in force, on an enforcing host and on a permissive one: an auditallow records a granted access in either.
for mode in Enforcing Permissive; do
    eval "getenforce() { printf '${mode}\n'; }"
    sesearch() { printf 'auditallow ai_tools_t ai_tools_exec_t:file { execute_no_trans };\n'; }
    ausearch() { printf '<no matches>\n' >&2; return 1; }
    collect_entrypoint_findings
    assert_state "the rule in force under ${mode} reads as loaded" loaded
done

# A loaded rule and an empty window: the one state where an empty result means no such exec happened.
out="$(state_output)"
if grep -q 'no agent entrypoint was started from inside a session' <<<"${out}" \
        && ! grep -q '^MSG-' <<<"${out}"; then
    pass "the rule in force over an empty window reports no finding and no diagnostic"
else
    fail "an empty window under the rule in force reported: $(tr '\n' '|' <<<"${out}")"
fi

# The rule in force over a window holding one of each class: a dispatch, and the exec the section exists for.
ausearch() {
    cat <<REC
----
type=EXECVE msg=audit(1758279723.000:920): argc=1 a0=acme-apply
type=SYSCALL msg=audit(1758279723.000:920): arch=c000003e syscall=59 ppid=199 pid=200 exe=${ACME_EXE}
$(granted_avc 1758279723 920 200 "${ACME_EXE}")
----
type=EXECVE msg=audit(1758282250.000:921): argc=1 a0=${BETA_EXE}
type=SYSCALL msg=audit(1758282250.000:921): arch=c000003e syscall=59 ppid=199 pid=201 exe=${BETA_EXE}
$(granted_avc 1758282250 921 201 "${BETA_EXE}")
REC
    return 0
}
collect_entrypoint_findings
if [[ "${AGENT_NAMES[*]}" == "acme beta" ]]; then
    pass "the fixture agent map is what the collector classified against"
else
    fail "the fixture agent map was replaced by '${AGENT_NAMES[*]}' -- the partition below would test nothing"
fi
if (( ${#ENTRYPOINT_EXEC_FINDINGS[@]} == 1 && ENTRYPOINT_SELF_EXEC_COUNT == 1 )); then
    pass "a window of one dispatch and one finding is partitioned as such"
else
    fail "partition wrong: ${#ENTRYPOINT_EXEC_FINDINGS[@]} finding(s), ${ENTRYPOINT_SELF_EXEC_COUNT} dispatch(es)"
fi
out="$(state_output)"
assert_msg MSG-H2B5 "${out}" "an entrypoint started from inside a session is reported under its code"
if grep -q "acme exec.d its own entrypoint as acme-apply" <<<"${out}"; then
    pass "the counted class names what it folded away, so the count is not a hole"
else
    fail "the self-dispatch count does not name what it counted: $(tr '\n' '|' <<<"${out}")"
fi
if grep -q 'beta entrypoint started from inside a session' <<<"${out}"; then
    pass "the finding reaches the rendered table"
else
    fail "the finding is absent from the section: $(tr '\n' '|' <<<"${out}")"
fi

finish
