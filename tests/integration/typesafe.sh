#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/typesafe.sh
# Integration: the installed decide command of the typesafe integration (typesafe.rule.md). Three sections:
#
#   1. The installed tree is the vendored release: every file tools/generators/typesafe-client.pin lists is installed
#      with its pinned sha256 at 644 root:root, and the directory does not hold a file the pin does not list -- so
#      a module a release adds reaches the host and one a release drops does not linger. `--version` names the pinned
#      tag.
#   2. Every refusal the command makes before a request, driven as the sandbox account against fixture credential
#      files: the configuration class (exit 3) and the input class (exit 2), and the provider class (exit 4) for a host
#      that cannot resolve. The fixtures name `typesafe.invalid` (RFC 2606, never resolves), so no case in this section
#      sends a byte off the host whatever the command does.
#   3. Live calls, run only with AI_TOOLS_TEST_TYPESAFE_LIVE=1, since each sends its listing and task to TypeSafe with
#      the host's key. The listings are synthetic, never project content. Each asserts the exit status, the summary
#      line naming the concrete model version that answered, and the usage line the call appended; which lines were
#      kept is reported as a NOTE, since that is the classifier's answer and not the integration's contract.
#
# Run as root via sudo; drops to the sandbox account per call. SKIPs where the package or node is not installed.

set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${ROOT}/tools/generators/typesafe-client.pin"
LIB=/usr/local/lib/ai-tools/typesafe
CLI="${LIB}/decide.mjs"
CONF=/etc/ai-tools/endpoints/typesafe.conf

section "typesafe: the installed decide command (integration)"

if [[ ! -r "${CLI}" ]]; then
    skip "typesafe integration" "ai-tools-integration-typesafe is not installed"; finish; exit
fi

# The node a session runs: the system one where root's PATH has it, else the newest in the sandbox toolchain.
NODE="$(command -v node || true)"
if [[ -z "${NODE}" ]]; then
    NODE="$(printf '%s\n' /opt/ai-tools/.nvm/versions/node/v*/bin/node | sort -V | tail -n 1)"
    [[ -x "${NODE}" ]] || NODE=""
fi

# as_agent_decide <stdin-file> <args>...: run the installed command as the sandbox account, stdin from the file. stdout
# lands in ${TESTDIR}/out and stderr in ${TESTDIR}/err; the exit status is the function's.
as_agent_decide() {
    local input="$1"; shift
    runuser -u "${SANDBOX_USER}" -- "${NODE}" "${CLI}" "$@" <"${input}" >"${TESTDIR}/out" 2>"${TESTDIR}/err"
}

mktestdir
chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${TESTDIR}"

# ── 1. The installed tree is the vendored release ────────────────────────────────────────────────
if [[ ! -r "${PIN}" ]]; then
    skip "installed files against the pin" "not a checkout (no ${PIN})"
else
    listed="$(sed -n 's/^file=\([0-9a-f]\{64\}\) \(.*\)$/\2/p' "${PIN}" | LC_ALL=C sort)"
    installed="$(find "${LIB}" -mindepth 1 -printf '%P\n' | LC_ALL=C sort)"
    if [[ -n "${listed}" && "${installed}" == "${listed}" ]]; then
        pass "${LIB} holds exactly the $(wc -l <<<"${listed}") files the pin lists"
    else
        fail "${LIB} differs from the pin: $(diff <(printf '%s\n' "${listed}") <(printf '%s\n' "${installed}") \
            | grep '^[<>]' | tr '\n' ' ')"
    fi
    while read -r sum name; do
        if [[ ! -f "${LIB}/${name}" ]]; then
            continue    # reported by the set comparison above
        fi
        if [[ "$(sha256sum "${LIB}/${name}" | cut -d' ' -f1)" != "${sum}" ]]; then
            fail "${LIB}/${name} is not the pinned file"
        fi
        check_file "${LIB}/${name}" root root 644
    done < <(sed -n 's/^file=\([0-9a-f]\{64\}\) \(.*\)$/\1 \2/p' "${PIN}")
    tag="$(sed -n 's/^tag=v//p' "${PIN}")"
    if [[ -n "${NODE}" ]]; then
        if [[ "$("${NODE}" "${CLI}" --version 2>&1)" == "typesafe-client-js ${tag}" ]]; then
            pass "the installed command reports the pinned release ${tag}"
        else
            fail "the installed command reports '$("${NODE}" "${CLI}" --version 2>&1)', the pin names ${tag}"
        fi
    fi
fi

if [[ -z "${NODE}" ]]; then
    skip "the command's refusals and live calls" "no node on root's PATH or in the sandbox toolchain"; finish; exit
fi

# ── 2. Refusals before a request, as the sandbox account ─────────────────────────────────────────
# conf_fixture <name> [KEY=value]...: a credential file the sandbox account owns at 0600, with a key of the issued shape
# and the unresolvable host, each extra argument appended as a line (a later line overrides an earlier one).
conf_fixture() {
    local path="${TESTDIR}/$1"; shift
    printf '%s\n' "TYPESAFE_API_KEY=apikey_0123456789abcdef0123456789abcdef" \
        "TYPESAFE_BASE_URL=https://typesafe.invalid" "TYPESAFE_ENDPOINT_HOST=typesafe.invalid" \
        "TYPESAFE_TIMEOUT_MS=3000" "$@" >"${path}"
    chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${path}"
    chmod 0600 "${path}"
}
printf 'src/a.sh:1: one\nsrc/b.sh:2: two\n' >"${TESTDIR}/listing"
printf 'a\0b\n' >"${TESTDIR}/binary"
: >"${TESTDIR}/empty"
printf 'src/a.sh:1: x\xf3\xa0\x80\x81y\n' >"${TESTDIR}/tagged"
conf_fixture ok.conf
conf_fixture mismatch.conf "TYPESAFE_ENDPOINT_HOST=api.typesafe.ai"
conf_fixture placeholder.conf "TYPESAFE_API_KEY=replace-with-your-key-000000000000"
conf_fixture threshold.conf "TYPESAFE_THRESHOLD=1.5"
conf_fixture band.conf "TYPESAFE_UNCERTAIN_BAND=0.65,0.35"
for value in 0 0.7 1; do conf_fixture "threshold-${value}.conf" "TYPESAFE_THRESHOLD=${value}"; done
conf_fixture band-ok.conf "TYPESAFE_UNCERTAIN_BAND=0.3,0.7"
conf_fixture model.conf "TYPESAFE_MODEL=jev latest"
conf_fixture world.conf; chmod 0604 "${TESTDIR}/world.conf"
ln -s "${TESTDIR}/ok.conf" "${TESTDIR}/link.conf"
chmod 0644 "${TESTDIR}"/{listing,binary,empty,tagged}

# expect_refusal <status> <class> <what> <stdin-file> <args>...: the command exits <status>, does not print a result,
# and writes one stderr line naming <class>.
expect_refusal() {
    local want="$1" class="$2" what="$3" input="$4" rc=0; shift 4
    as_agent_decide "${input}" "$@" || rc=$?
    local err; err="$(cat "${TESTDIR}/err")"
    if [[ ${rc} -eq ${want} && ! -s "${TESTDIR}/out" \
            && "${err}" == "decide: ${class}: "* && "${err}" != *$'\n'* ]]; then
        pass "${what}: exit ${want} (${class}), no result, one stderr line"
    else
        fail "${what}: exit ${rc}, stdout '$(head -c 120 "${TESTDIR}/out")', stderr '$(head -c 200 <<<"${err}")'"
    fi
}
C="${TESTDIR}"
# conf_refused <what> <args>...: the two-line listing with a task, refused with the configuration status.
conf_refused() { expect_refusal 3 configuration "$1" "${C}/listing" filter --task t "${@:2}"; }
# input_refused <what> <stdin-name> <args>...: a fixture listing under TESTDIR, refused with the input status.
input_refused() { expect_refusal 2 input "$1" "${C}/$2" "${@:3}"; }
conf_refused "no --config"
conf_refused "an empty --config (a session without the integration)" --config ""
conf_refused "a credential file readable by other"                   --config "${C}/world.conf"
conf_refused "a credential file behind a symlink"                    --config "${C}/link.conf"
conf_refused "a base URL whose host the file does not name twice"    --config "${C}/mismatch.conf"
conf_refused "the template's placeholder key"                        --config "${C}/placeholder.conf"
conf_refused "a threshold outside 0..1"                              --config "${C}/threshold.conf"
conf_refused "an uncertain band whose low end is above its high end" --config "${C}/band.conf"
conf_refused "a model that is not one token"                         --config "${C}/model.conf"
if [[ -r "${CONF}" ]] && ! grep -qE '^[[:space:]]*TYPESAFE_API_KEY=' "${CONF}"; then
    conf_refused "the shipped credential file with its key commented" --config "${CONF}"
fi
input_refused "a stream holding a NUL byte"      binary  filter --task t --config "${C}/ok.conf"
input_refused "an empty listing"                 empty   filter --task t --config "${C}/ok.conf"
input_refused "no --task"                        listing filter --config "${C}/ok.conf"
input_refused "an unknown --format"              listing filter --task t --format nope --config "${C}/ok.conf"
input_refused "the deferred triage template"     listing triage --task t --config "${C}/ok.conf"
input_refused "an item carrying a Unicode tag character" tagged filter --task t --config "${C}/ok.conf"

# The provider class: a file every configuration check accepts reaches the request, which fails on the unresolvable
# host. The in-range threshold values and band pair the out-of-range ones, so the refusals are about the range.
for value in 0 0.7 1; do
    expect_refusal 4 provider "a threshold of ${value} passes the configuration check" \
        "${C}/listing" filter --task t --config "${C}/threshold-${value}.conf"
done
expect_refusal 4 provider "an uncertain band of 0.3,0.7 passes the configuration check" \
    "${C}/listing" filter --task t --config "${C}/band-ok.conf"

# What the usage log records of a provider failure: counts and the outcome, never the task.
usage="${TESTDIR}/usage.log"
expect_refusal 4 provider "a host that does not resolve" "${C}/listing" \
    filter --task "a task sentence the log must not hold" --config "${C}/ok.conf" --usage-log "${usage}"
if [[ -s "${usage}" ]] && jq -e '.outcome == "provider" and .items == 2' <"${usage}" >/dev/null 2>&1 \
        && ! grep -q 'must not hold' "${usage}"; then
    pass "the usage log records the provider outcome and the item count, without the task"
else
    fail "the usage log after the provider refusal reads '$(head -c 300 "${usage}" 2>/dev/null)'"
fi

# ── 3. Live calls (opt-in) ───────────────────────────────────────────────────────────────────────
if [[ "${AI_TOOLS_TEST_TYPESAFE_LIVE:-}" != 1 ]]; then
    skip "live calls" "set AI_TOOLS_TEST_TYPESAFE_LIVE=1 to send synthetic listings to TypeSafe with the host's key"
    finish; exit
fi
if [[ ! -r "${CONF}" ]] || ! grep -qE '^[[:space:]]*TYPESAFE_API_KEY=' "${CONF}"; then
    skip "live calls" "${CONF} does not set TYPESAFE_API_KEY"; finish; exit
fi
live_log="${TESTDIR}/live-usage.log"
: >"${live_log}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${live_log}"

# expect_answer <what> <items> <format> <stdin-file> <task>: exit 0, a summary line over <items> items naming
# a versioned model, and one new usage line with outcome ok and the format. Returns 1 when the call did not answer,
# so a check that reads the answer is not run on a failed call.
expect_answer() {
    local what="$1" items="$2" format="$3" input="$4" task="$5" rc=0 before summary
    before="$(wc -l <"${live_log}")"
    as_agent_decide "${input}" filter --format "${format}" --task "${task}" \
        --config "${CONF}" --usage-log "${live_log}" || rc=$?
    summary="$(tail -n 1 "${TESTDIR}/out")"
    local shape="^decide: kept [0-9]+/${items}[^0-9].* (jev-[0-9]+\\.[0-9]+\\.[0-9]+), [0-9]+ request"
    if [[ ${rc} -eq 0 && "${summary}" =~ ${shape} ]]; then
        pass "${what}: exit 0, the summary names the version that answered (${BASH_REMATCH[1]})"
    else
        fail "${what}: exit ${rc}, summary '${summary}', stderr '$(head -c 300 "${TESTDIR}/err")'"
        return 1
    fi
    # shellcheck disable=SC2016  # $f is jq's variable, bound by --arg
    local line_ok='.outcome == "ok" and .format == $f and (.model | test("^jev-[0-9]+\\.[0-9]+\\.[0-9]+$"))'
    if [[ "$(wc -l <"${live_log}")" -eq $(( before + 1 )) ]] \
            && tail -n 1 "${live_log}" | jq -e --arg f "${format}" "${line_ok}" >/dev/null; then
        pass "${what}: one usage line, outcome ok, format ${format}, a versioned model"
    else
        fail "${what}: the usage log gained '$(tail -n 1 "${live_log}")'"
    fi
    note "${what}: kept" "$(head -n -1 "${TESTDIR}/out" | tr '\n' '|')"
}

printf '%s\n' "basket.txt:1: apple" "basket.txt:2: hammer" "basket.txt:3: banana" \
    "basket.txt:4: screwdriver" "basket.txt:5: cherry" "basket.txt:6: wrench" >"${TESTDIR}/fruit"
printf '%s\n' "docs/a.md:3: filler [basically] -- cut it" "    it is basically done" \
    "docs/b.md:9: absolute [never] -- name the guard" "    the file is never written" >"${TESTDIR}/prose"
printf '%s\n' "Build started 9/23/2026 10:00:00 AM." \
    "/src/App/Program.cs(12,5): error CS0103: The name 'Execute' does not exist [/src/App/App.csproj]" \
    "  App -> /src/App/bin/Debug/net9.0/App.dll" \
    "/src/Lib/Util.cs(4,1): warning CS8618: Non-nullable property 'Name' is uninitialized [/src/Lib/Lib.csproj]" \
    "Build FAILED." "Time Elapsed 00:00:02.13" >"${TESTDIR}/msbuild"
chmod 0644 "${TESTDIR}"/{fruit,prose,msbuild}

# A key the provider never issued, sent to the host's own endpoint with a one-line listing: the provider must refuse
# it, and the command must report that as the provider class with the status. An answer here is the failure.
conf_value() { sed -n "s/^[[:space:]]*$1=[\"']\\{0,1\\}\\([^\"' ]*\\).*/\\1/p" "${CONF}" | tail -n 1; }
base_url="$(conf_value TYPESAFE_BASE_URL)"; endpoint_host="$(conf_value TYPESAFE_ENDPOINT_HOST)"
conf_fixture forged.conf "TYPESAFE_API_KEY=apikey_$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
    "TYPESAFE_BASE_URL=${base_url:-https://api.typesafe.ai}" \
    "TYPESAFE_ENDPOINT_HOST=${endpoint_host:-api.typesafe.ai}" "TYPESAFE_TIMEOUT_MS=15000"
printf 'basket.txt:1: apple\n' >"${TESTDIR}/one"; chmod 0644 "${TESTDIR}/one"
rc=0; as_agent_decide "${TESTDIR}/one" filter --task "which lines name a fruit" --config "${C}/forged.conf" || rc=$?
if [[ ${rc} -eq 4 && ! -s "${TESTDIR}/out" && "$(cat "${TESTDIR}/err")" =~ status=40[13] ]]; then
    pass "a key the provider never issued: refused ($(grep -oE 'status=40[13]' "${TESTDIR}/err")), exit 4, no result"
elif [[ ${rc} -eq 0 ]]; then
    fail "a key the provider never issued was answered: '$(head -c 200 "${TESTDIR}/out")'"
else
    fail "a key the provider never issued: exit ${rc}, stderr '$(head -c 300 "${TESTDIR}/err")'"
fi

# The host's key: the first call tells a refused key apart from a per-format defect, and a refused key ends the live
# calls there, since each one after it would send its listing for the same refusal.
if ! expect_answer "lines"  6 lines       "${TESTDIR}/fruit"   "which lines name a fruit" \
        && grep -qE 'status=40[13]' "${TESTDIR}/err"; then
    skip "the remaining live calls" "the provider refused the host's key -- set a key issued for ${base_url} in ${CONF}"
    finish; exit
fi
expect_answer "prose-check" 2 prose-check "${TESTDIR}/prose"   "which findings are about an absolute claim" || :
if expect_answer "msbuild"  2 msbuild     "${TESTDIR}/msbuild" "which diagnostics are errors rather than warnings"; then
    if tail -n 1 "${live_log}" | jq -e '.setAside > 0' >/dev/null 2>&1; then
        pass "msbuild: the usage line counts the log lines set aside"
    else
        fail "msbuild: the usage line does not count a set-aside line: '$(tail -n 1 "${live_log}")'"
    fi
fi

# A reader that closes stdout early ends the command with status 0 and an empty stderr.
rc=0
# stdin and stderr are opened here, as root, like every other call's: a root-created file is not one the sandbox
# account may open for writing.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
runuser -u "${SANDBOX_USER}" -- bash -c '"$1" "$2" filter --task "which lines name a fruit" --config "$3" \
    | head -c 0; exit "${PIPESTATUS[0]}"' _ "${NODE}" "${CLI}" "${CONF}" \
    <"${TESTDIR}/fruit" 2>"${TESTDIR}/err" || rc=$?
if [[ ${rc} -eq 0 && ! -s "${TESTDIR}/err" ]]; then
    pass "a reader closing stdout early: exit 0, an empty stderr"
else
    fail "a reader closing stdout early: exit ${rc}, stderr '$(head -c 200 "${TESTDIR}/err")'"
fi

finish
