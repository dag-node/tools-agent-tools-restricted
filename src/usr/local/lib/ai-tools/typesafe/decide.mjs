// SPDX-License-Identifier: AGPL-3.0-only
// clients/typesafe/src/decide.mts -- installed as /usr/local/lib/ai-tools/typesafe/decide.mjs, run as
//
//     ```text
//     <listing> | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "<one sentence>"
//                   [--format lines|prose-check|msbuild] [--threshold 0.5] [--config <file>]
//     ```
//
// Reads a line-oriented listing on stdin, hands it to TypeSafe's System One API with one bounded question per line,
// prints the lines that bear on the task in full and the rest as ids on one summary line, and appends one usage line
// (counts, model, tokens, elapsed, outcome; no content) to the integration's state root. The agent invokes it
// explicitly: no hook rewrites a command into it, and its result never stands in for the check a task owes.
//
// Where the credential comes from: the file AI_TOOLS_TYPESAFE_CONF names, which the integration's session-env
// fragment sets for a session of an enabled integration. Without the variable the command reports that the
// integration is not enabled and exits 3; the file's own refusals are config.mts's. The key is read at call time and
// is never placed in the environment.
//
// Exit status: 0 a result was printed; 2 input (arguments, an empty or over-bound listing, a template not in
// scope); 3 configuration (not enabled, or the file is missing or invalid); 4 the provider refused or was
// unreachable; 5 the answer did not hold the documented shape; 6 the deadline passed; 1 an unexpected error. On
// every non-zero status the one stderr line is all that is printed, so the caller's fallback is the listing it
// already holds.
//
// The triage template is deferred (typesafe.rule.md); asking for it exits 2 with the reason.
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { readConfig } from "./config.mjs";
import { decideFilter, LIMITS, makeClient } from "./core.mjs";
import { DecideError, inputError, configurationError } from "./errors.mjs";
import { FORMATS, parse } from "./parsers.mjs";
import { filter, MAX_TASK_CHARS, TEMPLATE_VERSION } from "./templates.mjs";
const USAGE = `usage: <listing> | node decide.mjs filter --task "<one sentence>" [--format lines|prose-check|msbuild] [--threshold 0.5] [--config <file>]
  filter    keep the lines that bear on the task; the rest are listed by id on the summary line
  --format  lines (default), prose-check, or msbuild (a build log's diagnostics; the rest set aside)
  triage    deferred -- not dispatched in this release
exit: 0 result, 2 input, 3 configuration, 4 provider, 5 contract, 6 deadline, 1 unexpected`;
function parseArgs(argv) {
    let template = "";
    let task = "";
    let format = "lines";
    let threshold;
    let config;
    let help = false;
    const next = (flag, i) => {
        const v = argv[i + 1];
        if (v === undefined)
            throw inputError(`${flag} needs a value`);
        return v;
    };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        switch (arg) {
            case "--help":
            case "-h":
                help = true;
                break;
            case "--task":
                task = next(arg, i++);
                break;
            case "--format": {
                const v = next(arg, i++);
                if (!FORMATS.includes(v))
                    throw inputError(`--format must be one of ${FORMATS.join(", ")}, got '${v}'`);
                format = v;
                break;
            }
            case "--threshold": {
                const v = Number(next(arg, i++));
                if (!Number.isFinite(v) || v < 0 || v > 1)
                    throw inputError("--threshold must be a number between 0 and 1");
                threshold = v;
                break;
            }
            case "--config":
                config = next(arg, i++);
                break;
            default:
                if (arg.startsWith("-"))
                    throw inputError(`unknown option '${arg}'`);
                if (template !== "")
                    throw inputError(`one template only, got '${template}' and '${arg}'`);
                template = arg;
        }
    }
    return { template, task, format, threshold, config, help };
}
function readStdin() {
    try {
        return readFileSync(0, "utf8");
    }
    catch (err) {
        throw inputError(`stdin is not readable (${err instanceof Error ? err.message : String(err)}) -- pipe a listing in`);
    }
}
function summary(decision, setAside, format) {
    const tokens = decision.requests.reduce((n, r) => n + r.inputTokens, 0);
    const elapsed = decision.requests.reduce((n, r) => n + r.elapsedMs, 0);
    const models = [...new Set(decision.requests.map((r) => r.model))].join(",");
    const uncertain = decision.uncertain.length === 0 ? "" : ` (uncertain: ${decision.uncertain.map((r) => r.id).join(" ")})`;
    const dropped = decision.dropped.length === 0 ? "none" : decision.dropped.map((r) => r.id).join(" ");
    // A cut item and a set-aside line are evidence the model did not see, so the summary names each count.
    const bounded = [decision.cut === 0 ? "" : `${decision.cut} item(s) cut at ${LIMITS.maxItemChars} chars`, setAside === 0 ? "" : `${setAside} line(s) set aside by --format ${format}`]
        .filter((part) => part !== "")
        .join(", ");
    return `decide: kept ${decision.kept.length}/${decision.total}${uncertain}; dropped: ${dropped}${bounded === "" ? "" : `; ${bounded}`}; ${models}, ${decision.requests.length} request(s), ${(elapsed / 1000).toFixed(1)}s, ${tokens} tokens`;
}
function usageLine(fields) {
    const root = process.env["AI_TOOLS_TYPESAFE_STATE"];
    if (root === undefined || root === "")
        return;
    try {
        appendFileSync(join(root, "usage.log"), `${JSON.stringify({ ts: new Date().toISOString(), templateVersion: TEMPLATE_VERSION, ...fields })}\n`);
    }
    catch {
        // The usage log is cost accounting, not a gate: a state root the session cannot write costs the line, not the result.
    }
}
async function main(argv) {
    const args = parseArgs(argv);
    if (args.help) {
        process.stdout.write(`${USAGE}\n`);
        return 0;
    }
    if (args.template === "")
        throw inputError(`a template is required\n${USAGE}`);
    if (args.template === "triage")
        throw inputError("the triage template is deferred and not dispatched in this release; use the checker's full output");
    if (args.template !== "filter")
        throw inputError(`unknown template '${args.template}'\n${USAGE}`);
    if (args.task.trim() === "")
        throw inputError("filter needs --task \"<one sentence>\"");
    if (args.task.length > MAX_TASK_CHARS)
        throw inputError(`--task is ${args.task.length} chars; the bound is ${MAX_TASK_CHARS}`);
    const configPath = args.config ?? process.env["AI_TOOLS_TYPESAFE_CONF"];
    if (configPath === undefined || configPath === "") {
        throw configurationError("the typesafe integration is not enabled in this session (AI_TOOLS_TYPESAFE_CONF is unset); enable it in /etc/ai-tools/operator.conf AI_TOOLS_INTEGRATIONS and start a new session");
    }
    const config = readConfig(configPath);
    const { items, setAside } = parse(args.format, readStdin());
    if (items.length === 0)
        throw inputError("the listing on stdin is empty");
    if (items.length > LIMITS.maxItems) {
        throw inputError(`${items.length} items exceeds the bound of ${LIMITS.maxItems}. A listing within the bound is split across requests of ${LIMITS.maxItemsPerRequest} on its own; past it, narrow the listing at its source or pre-filter it (--format msbuild for a build log)`, { items: items.length });
    }
    const client = makeClient(config);
    const started = Date.now();
    let decision;
    try {
        decision = await decideFilter(client, filter, items, args.threshold === undefined ? { task: args.task } : { task: args.task, threshold: args.threshold });
    }
    catch (err) {
        const failure = err instanceof DecideError ? err : null;
        usageLine({ template: "filter", items: items.length, outcome: failure ? failure.code : "unexpected", elapsedMs: Date.now() - started });
        throw err;
    }
    const byId = new Map(items.map((i) => [i.id, i.text]));
    for (const row of decision.kept)
        process.stdout.write(`${byId.get(row.id) ?? row.id}\n`);
    process.stdout.write(`${summary(decision, setAside, args.format)}\n`);
    usageLine({
        template: "filter",
        items: decision.total,
        kept: decision.kept.length,
        cut: decision.cut,
        setAside,
        format: args.format,
        requests: decision.requests.length,
        model: [...new Set(decision.requests.map((r) => r.model))].join(","),
        inputTokens: decision.requests.reduce((n, r) => n + r.inputTokens, 0),
        elapsedMs: Date.now() - started,
        outcome: "ok",
        requestIds: decision.requests.map((r) => r.requestId ?? "-"),
    });
    return 0;
}
try {
    process.exitCode = await main(process.argv.slice(2));
}
catch (err) {
    if (err instanceof DecideError) {
        process.stderr.write(`${err.describe()}\n`);
        process.exitCode = err.exitStatus;
    }
    else {
        process.stderr.write(`decide: unexpected: ${err instanceof Error ? err.message : String(err)}\n`);
        process.exitCode = 1;
    }
}
