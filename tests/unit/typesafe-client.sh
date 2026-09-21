#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/typesafe-client.sh
# Unit test for the typesafe integration's decide command under src/usr/local/lib/ai-tools/typesafe (falling back
# to the installed copy) -- the JavaScript a host runs. What it proves without a network: every refusal the command
# makes before a request leaves the process with the exit status its header documents and one stderr line naming
# the class; the credential file's refusals fail closed on the world bits and on a symlink; the request carries
# the file's own origin, key and model rather than any environment value; the two stdin parsers keep a `path:line` id
# and refuse a record they cannot place; and the answer contract rejects each malformed body it is driven with.
# The provider itself is exercised by the wip verification (typesafe.rule.md); no case here opens a connection.
#
# Hermetic: fixtures under the test's own /tmp testdir; the only environment it sets is on the child it runs.
set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "typesafe-client: the decide command, offline (unit)"

DIR="${ROOT}/src/usr/local/lib/ai-tools/typesafe"
[[ -r "${DIR}/decide.mjs" ]] || DIR="/usr/local/lib/ai-tools/typesafe"
if [[ ! -r "${DIR}/decide.mjs" ]]; then
    skip "typesafe-client" "decide.mjs not found in the checkout or installed"; finish; exit
fi
if ! command -v node >/dev/null 2>&1; then
    skip "typesafe-client" "node is not on PATH"; finish; exit
fi
CLI="${DIR}/decide.mjs"

mktestdir
# run <stdin-text> <args...>: run the command with the given stdin and NO integration variables inherited; sets
# out, err, rc.
run() {
    local input="$1"; shift
    set +e
    out="$(printf '%s' "${input}" | env -u AI_TOOLS_TYPESAFE_CONF -u AI_TOOLS_TYPESAFE_STATE node "${CLI}" "$@" 2>"${TESTDIR}/err")"
    rc=$?
    set -e
    err="$(cat "${TESTDIR}/err")"
}
expect_refusal() {
    local what="$1" want_rc="$2" class="$3"
    if [[ ${rc} -eq ${want_rc} && "${out}" == "" && "${err}" == "decide: ${class}: "* && "$(wc -l <<<"${err}")" -le 6 ]]; then
        pass "${what}: exit ${want_rc}, one '${class}' line on stderr, nothing on stdout"
    else
        fail "${what}: rc=${rc} stdout='$(head -c 80 <<<"${out}")' stderr='$(head -c 160 <<<"${err}" | tr '\n' '|')'"
    fi
}

# ── refusals before any request ───────────────────────────────────────────────────────────────────────────────
run "" --help
if [[ ${rc} -eq 0 && "${out}" == usage:* && "${out}" == *"exit: 0 result, 2 input, 3 configuration, 4 provider, 5 contract, 6 deadline, 1 unexpected"* ]]; then
    pass "--help prints the usage with the exit-status table and exits 0"
else
    fail "--help: rc=${rc} out='$(head -c 120 <<<"${out}")'"
fi
run "x" ; expect_refusal "no template" 2 input
run "x" triage; expect_refusal "the deferred triage template" 2 input
run "x" nonsense; expect_refusal "an unknown template" 2 input
run "x" filter; expect_refusal "filter without --task" 2 input
run "x" filter --task t --format wat; expect_refusal "an unknown --format" 2 input
run "x" filter --task t --threshold 7; expect_refusal "a threshold outside 0..1" 2 input
run "x" filter --task t --bogus; expect_refusal "an unknown option" 2 input
run "x" filter --task "$(printf 'a%.0s' {1..401})"; expect_refusal "a --task over the bound" 2 input
run "x" filter --task t; expect_refusal "the integration not enabled (no AI_TOOLS_TYPESAFE_CONF, no --config)" 3 configuration

# ── the credential file ───────────────────────────────────────────────────────────────────────────────────────
KEY="tsk_unit_0123456789abcdefghij"
conf="${TESTDIR}/typesafe.conf"
printf 'TYPESAFE_API_KEY=%s\n' "${KEY}" > "${conf}"; chmod 0644 "${conf}"
run "x" filter --task t --config "${conf}"; expect_refusal "a world-readable file" 3 configuration
chmod 0602 "${conf}"
run "x" filter --task t --config "${conf}"; expect_refusal "a world-writable file" 3 configuration
chmod 0660 "${conf}"
ln -s "${conf}" "${TESTDIR}/link.conf"
run "x" filter --task t --config "${TESTDIR}/link.conf"; expect_refusal "a symlink" 3 configuration
run "x" filter --task t --config "${TESTDIR}/absent.conf"; expect_refusal "a missing file" 3 configuration
printf 'TYPESAFE_API_KEY=replace-with-your-key\n' > "${conf}"
run "x" filter --task t --config "${conf}"; expect_refusal "the template placeholder" 3 configuration
printf 'TYPESAFE_API_KEY=%s\nTYPESAFE_BASE_URL=https://jev-ai.pro\n' "${KEY}" > "${conf}"
run "x" filter --task t --config "${conf}"; expect_refusal "another host not named in TYPESAFE_ENDPOINT_HOST" 3 configuration
printf 'TYPESAFE_API_KEY=%s\nTYPESAFE_BASE_URL=http://api.typesafe.ai\n' "${KEY}" > "${conf}"
run "x" filter --task t --config "${conf}"; expect_refusal "a non-https base URL" 3 configuration
# A valid file: the next refusal is the listing's, so the file was accepted (group-writable by ACL mask is fine).
printf 'TYPESAFE_API_KEY=%s\n' "${KEY}" > "${conf}"; chmod 0660 "${conf}"
run "" filter --task t --config "${conf}"; expect_refusal "a valid file, then an empty listing" 2 input
run "$(printf 'x:%d: y\n' {1..201})" filter --task t --config "${conf}"; expect_refusal "a listing over the item bound" 2 input
run "$(printf 'a:1: y\nb:2: z\nnot a finding\n')" filter --task t --format prose-check --config "${conf}"; expect_refusal "a prose-check record the parser cannot place" 2 input
if ! grep -qF "${KEY}" "${TESTDIR}/err"; then pass "no refusal line carries the key"; else fail "a refusal line carries the key"; fi

# ── the library, driven directly ──────────────────────────────────────────────────────────────────────────────
# The parsers, the contract and the request's pinning are asserted from node, where the fetch the transport makes is
# injected and records what it was handed. Every case prints one line: `ok <what>` or `FAIL <what>: <why>`.
cat > "${TESTDIR}/drive.mjs" <<EOF
import { parseLines, parseProseCheck } from "${DIR}/parsers.mjs";
import { contractProblems, makeClient, decideFilter, LIMITS, chunkItems, normalizeItems } from "${DIR}/core.mjs";
import { filter } from "${DIR}/templates.mjs";
import { readConfig } from "${DIR}/config.mjs";
const report = (cond, what, why = "") => console.log(cond ? \`ok \${what}\` : \`FAIL \${what}: \${why}\`);
const lines = parseLines("src/a.sh:12: foo()\\n\\nplain line\\nsrc/b.sh:3:bar\\n");
report(lines.length === 3 && lines[0].id === "src/a.sh:12" && lines[1].id === "L2" && lines[2].id === "src/b.sh:3" && lines[0].text === "src/a.sh:12: foo()", "lines: path:line ids, L<n> fallback, blank lines skipped", JSON.stringify(lines));
const pc = parseProseCheck("docs/x.md:5: unbacked-absolute [never] -- name the guard\\n    The account is never an admin.\\n\\n1 finding(s). See the skill\\n");
report(pc.length === 1 && pc[0].id === "docs/x.md:5" && pc[0].rule.startsWith("unbacked-absolute") && pc[0].text === "The account is never an admin.", "prose-check: id, rule and excerpt split, trailer skipped", JSON.stringify(pc));
const many = normalizeItems(Array.from({ length: 95 }, (_, i) => ({ id: \`i\${i}\`, text: "t" })));
report(chunkItems(many).map((c) => c.length).join("/") === "40/40/15", "chunking 95 items as 40/40/15");
const ids = ["a", "b"];
const good = { model: "jev-1.13.0", answers: { a: { type: "noul", noul: 0.9 }, b: { type: "noul", noul: 0.1 } }, usage: { input_tokens: 10, output_tokens: 0 } };
report(contractProblems(good, ids, "noul", null).length === 0, "contract: a valid noul body passes");
const cases = [
  ["missing answer", { ...good, answers: { a: good.answers.a } }, "missing"],
  ["extra answer", { ...good, answers: { ...good.answers, c: { type: "noul", noul: 0.5 } } }, "unexpected"],
  ["noul out of range", { ...good, answers: { ...good.answers, a: { type: "noul", noul: 1.5 } } }, "[0,1]"],
  ["wrong type", { ...good, answers: { ...good.answers, a: { type: "choice", noul: 0.5 } } }, "type"],
  ["no usage", { model: "m", answers: good.answers }, "usage"],
  ["text body", "<html>", "not an object"],
  ["empty body", undefined, "not an object"],
];
for (const [what, body, needle] of cases) {
  const p = contractProblems(body, ids, "noul", null);
  report(p.length > 0 && p.some((x) => x.includes(needle)), \`contract: \${what} is reported\`, p.join("; "));
}
const opts = { rewrite: "r", keep: "k", open: "o" };
const choiceGood = { model: "m", answers: { a: { type: "choice", choice: "keep", confidence: 0.8, probabilities: { rewrite: 0.1, keep: 0.8, open: 0.1 } } }, usage: { input_tokens: 1, output_tokens: 0 } };
report(contractProblems(choiceGood, ["a"], "choice", opts).length === 0, "contract: a valid choice body passes");
const badChoice = [
  ["choice outside the options", (b) => { b.answers.a.choice = "maybe"; }, "not an option"],
  ["probabilities not summing to 1", (b) => { b.answers.a.probabilities.keep = 0.3; }, "sum to"],
  ["choice not the argmax", (b) => { b.answers.a.probabilities = { rewrite: 0.8, keep: 0.1, open: 0.1 }; }, "highest-probability"],
  ["a missing option key", (b) => { delete b.answers.a.probabilities.open; b.answers.a.probabilities.keep = 0.9; }, "keys differ"],
  ["confidence out of range", (b) => { b.answers.a.confidence = 2; }, "confidence"],
];
for (const [what, mutate, needle] of badChoice) {
  const b = structuredClone(choiceGood); mutate(b);
  const p = contractProblems(b, ["a"], "choice", opts);
  report(p.length > 0 && p.some((x) => x.includes(needle)), \`contract: \${what} is reported\`, p.join("; "));
}
// Pinning: hostile SDK fallbacks in the environment do not change the origin, the bearer or the model.
process.env.TYPESAFE_API_KEY = "env_key_must_not_be_used_0123456789";
process.env.TYPESAFE_BASE_URL = "https://evil.invalid";
process.env.TYPESAFE_DEFAULT_MODEL = "env-model";
const config = readConfig("${conf}");
const calls = [];
const fetchImpl = async (url, init) => {
  calls.push({ url, auth: init.headers.Authorization ?? init.headers.authorization, body: JSON.parse(init.body) });
  return new Response(JSON.stringify({ model: "jev-1.13.0", answers: { "s:1": { type: "noul", noul: 0.9 }, "s:2": { type: "noul", noul: 0.2 } }, usage: { input_tokens: 5, output_tokens: 0 } }), { status: 200, headers: { "content-type": "application/json", "x-typesafe-request-id": "req_unit" } });
};
const client = makeClient(config, fetchImpl);
const d = await decideFilter(client, filter, [{ id: "s:1", text: "one" }, { id: "s:2", text: "two" }], { task: "t" });
const c = calls[0];
report(c.url === "https://api.typesafe.ai/v1/systemone", "pinning: the request goes to the configured origin, not TYPESAFE_BASE_URL", c.url);
report(c.auth === "Bearer ${KEY}", "pinning: the bearer is the file's key, not TYPESAFE_API_KEY");
report(c.body.model === "jev-1.13.0", "pinning: the model is the file's default, not TYPESAFE_DEFAULT_MODEL", c.body.model);
report(Object.keys(c.body.questions).join() === "s:1,s:2" && c.body.questions["s:1"].type === "noul" && c.body.state.task === "t", "request: one noul per item keyed by id, the task in the state");
report(d.kept.length === 1 && d.dropped.length === 1 && d.requests[0].requestId === "req_unit" && d.requests[0].inputTokens === 5, "decision: kept/dropped split, request id and usage reported", JSON.stringify(d));
const err401 = async () => { try { await decideFilter(makeClient(config, async () => new Response("{}", { status: 401, headers: { "content-type": "application/json" } })), filter, [{ id: "a", text: "x" }], { task: "t" }); return null; } catch (e) { return e; } };
const e = await err401();
report(e && e.code === "provider" && e.exitStatus === 4 && e.detail.status === 401 && !e.describe().includes("${KEY}"), "errors: a 401 maps to the provider class, exit 4, no key in the line", e ? e.describe() : "none");
EOF
set +e
drive_out="$(node "${TESTDIR}/drive.mjs" 2>&1)"; drive_rc=$?
set -e
if [[ ${drive_rc} -ne 0 ]]; then
    fail "the library driver crashed: $(head -c 300 <<<"${drive_out}" | tr '\n' '|')"
else
    while IFS= read -r line; do
        case "${line}" in
            "ok "*) pass "${line#ok }" ;;
            "FAIL "*) fail "${line#FAIL }" ;;
            *) fail "unexpected driver output: ${line}" ;;
        esac
    done <<<"${drive_out}"
fi

finish
