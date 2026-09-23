// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/decide.mts -- the command, run as
//
//     ```text
//     <listing> | node decide.mjs filter --task "<one sentence>" --config <file>
//                   [--format lines|prose-check|msbuild] [--threshold 0.5] [--usage-log <file>]
//     ```
//
// Reads a line-oriented listing on stdin, hands it to TypeSafe's System One API with one bounded question per line,
// and prints the lines that bear on the task in full, the rest as ids on one summary line. A caller invokes it
// explicitly, and its result does not stand in for a deterministic check the caller owes.
//
// `--config` is required and is the only way a key reaches the process: it names the file config.mts reads and
// validates, so the key is read at call time and passes neither through argv nor through the environment. The
// command does not read any environment variable -- `--usage-log` names the file each invocation appends its
// counts to (items, model, tokens, elapsed, outcome; no content); omitted, the command does not write at all.
//
// Exit status: 0 a result was printed; 2 input (arguments, an empty or over-bound listing, a template not in
// scope); 3 configuration (the file is missing, unreadable, or holds a value outside its form); 4 the provider
// refused or was unreachable; 5 the answer did not hold the documented shape; 6 the deadline passed; 1 an
// unexpected error. On every non-zero status the one stderr line is all that is printed, so the caller's fallback
// is the listing it already holds. A reader that closes stdout before the output is complete ends the command
// with status 0 and nothing on stderr.
//
// The triage template is deferred; asking for it exits 2 with the reason.
import { appendFileSync, readSync } from "node:fs";
import { readConfig } from "./config.mjs";
import { decideFilter, LIMITS, makeClient } from "./core.mjs";
import { DecideError, inputError, configurationError, oneLine } from "./errors.mjs";
import { USAGE, VERSION } from "./help.mjs";
import { FORMATS, parse } from "./parsers.mjs";
import { filter, MAX_TASK_CHARS, TEMPLATE_VERSION } from "./templates.mjs";
function parseArgs(argv) {
    let template = "";
    let task = "";
    let format = "lines";
    let threshold;
    let config;
    let usageLog;
    let help = false;
    let version = false;
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
            case "--version":
            case "-v":
                version = true;
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
            case "--usage-log":
                usageLog = next(arg, i++);
                break;
            default:
                if (arg.startsWith("-"))
                    throw inputError(`unknown option '${arg}'`);
                if (template !== "")
                    throw inputError(`one template only, got '${template}' and '${arg}'`);
                template = arg;
        }
    }
    return { template, task, format, threshold, config, usageLog, help, version };
}
/**
 * stdin as text, read in chunks and refused the moment it passes the input bound, so a stream far over it is not
 * buffered whole first. The bound is applied here to bytes, of which a character is at least one; the parser
 * applies it to characters again.
 */
function readStdin() {
    const cap = LIMITS.maxInputChars;
    const chunk = Buffer.alloc(64 * 1024);
    const chunks = [];
    let length = 0;
    for (;;) {
        let n;
        try {
            n = readSync(0, chunk, 0, chunk.length, null);
        }
        catch (err) {
            throw inputError(`stdin is not readable (${err instanceof Error ? err.message : String(err)}) -- pipe a listing in`);
        }
        if (n === 0)
            break;
        length += n;
        if (length > cap)
            throw inputError(`the input is over ${cap} bytes. Narrow the listing at its source`, { bytes: length });
        chunks.push(Buffer.from(chunk.subarray(0, n)));
    }
    return Buffer.concat(chunks, length).toString("utf8");
}
function summary(decision, setAside, format) {
    const tokens = decision.requests.reduce((n, r) => n + r.inputTokens, 0);
    const elapsed = decision.requests.reduce((n, r) => n + r.elapsedMs, 0);
    const models = [...new Set(decision.requests.map((r) => r.model))].join(",");
    const uncertain = decision.uncertain.length === 0 ? "" : ` (uncertain: ${decision.uncertain.map((r) => r.id).join(" ")})`;
    const dropped = decision.dropped.length === 0 ? "none" : decision.dropped.map((r) => r.id).join(" ");
    // A cut item and a set-aside line are evidence the model did not see, so the summary names each count.
    const bounded = [decision.cut === 0 ? "" : `${decision.cut} item(s) cut at ${LIMITS.maxItemChars} chars`, setAside === 0 ? "" : `${setAside} line(s) set aside by --format ${format}`, decision.invisible === 0 ? "" : `${decision.invisible} item(s) carry invisible formatting`]
        .filter((part) => part !== "")
        .join(", ");
    return `decide: kept ${decision.kept.length}/${decision.total}${uncertain}; dropped: ${dropped}${bounded === "" ? "" : `; ${bounded}`}; ${models}, ${decision.requests.length} request(s), ${(elapsed / 1000).toFixed(1)}s, ${tokens} tokens`;
}
function usageLine(path, fields) {
    if (path === undefined || path === "")
        return;
    try {
        appendFileSync(path, `${JSON.stringify({ ts: new Date().toISOString(), version: VERSION, templateVersion: TEMPLATE_VERSION, ...fields })}\n`);
    }
    catch {
        // The usage log is cost accounting. A path the command fails to open costs the line and leaves the result.
    }
}
async function main(argv) {
    const args = parseArgs(argv);
    // Before every other check: asking which build this is has to answer on a host where no
    // configuration exists, which is the state that raises the question.
    if (args.version) {
        process.stdout.write(`typesafe-client-js ${VERSION}\n`);
        return 0;
    }
    if (args.help) {
        process.stdout.write(`${USAGE}\n`);
        return 0;
    }
    if (args.template === "")
        throw inputError("a template is required -- the one dispatched is filter; run --help for the options");
    if (args.template === "triage")
        throw inputError("the triage template is deferred and not dispatched in this release; use the checker's full output");
    if (args.template !== "filter")
        throw inputError(`unknown template '${args.template}' -- the one dispatched is filter; run --help for the options`);
    if (args.task.trim() === "")
        throw inputError("filter needs --task \"<one sentence>\"");
    if (args.task.length > MAX_TASK_CHARS)
        throw inputError(`--task is ${args.task.length} chars; the bound is ${MAX_TASK_CHARS}`);
    if (args.config === undefined || args.config === "") {
        throw configurationError("--config <file> is required -- it names the file holding the API key; run --help for the options");
    }
    const config = readConfig(args.config);
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
        // `--threshold` is the per-call override of the file's value, which is itself the default's override.
        decision = await decideFilter(client, filter, items, { task: args.task, threshold: args.threshold ?? config.threshold, uncertainBand: config.uncertainBand }, { timeoutMs: config.timeoutMs });
    }
    catch (err) {
        const failure = err instanceof DecideError ? err : null;
        usageLine(args.usageLog, { template: "filter", items: items.length, outcome: failure ? failure.code : "unexpected", elapsedMs: Date.now() - started });
        throw err;
    }
    const byId = new Map(items.map((i) => [i.id, i.text]));
    for (const row of decision.kept)
        process.stdout.write(`${byId.get(row.id) ?? row.id}\n`);
    process.stdout.write(`${summary(decision, setAside, args.format)}\n`);
    usageLine(args.usageLog, {
        template: "filter",
        items: decision.total,
        kept: decision.kept.length,
        cut: decision.cut,
        invisible: decision.invisible,
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
// The caller pipes the output, and a reader that stops early (`| head -1`) closes the pipe under the writes still
// to come. Node reports that as an 'error' event on stdout; left unhandled, it prints a stack trace to stderr --
// into the caller's context, which the one-line rule exists to keep clear. The reader has what it asked for and
// the rest has no reader, so the process ends there, quietly, with the usage line already appended: every write
// to stdout is synchronous on a pipe, so the event fires after `main` has run past them.
process.stdout.on("error", (err) => {
    if (err.code === "EPIPE")
        process.exit(0);
    process.stderr.write(`${oneLine(`decide: unexpected: stdout ${err.message}`)}\n`);
    process.exit(1);
});
try {
    process.exitCode = await main(process.argv.slice(2));
}
catch (err) {
    if (err instanceof DecideError) {
        process.stderr.write(`${err.describe()}\n`);
        process.exitCode = err.exitStatus;
    }
    else {
        process.stderr.write(`${oneLine(`decide: unexpected: ${err instanceof Error ? err.message : String(err)}`)}\n`);
        process.exitCode = 1;
    }
}
