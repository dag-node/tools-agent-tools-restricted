// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/core.mts
// The bounded request loop: items are checked and cut, chunked to a request size, sent one request at a time
// under one deadline, and every answer is held to the documented shape before anything is returned. A failure in
// any chunk fails the whole invocation -- the caller falls back to the full listing -- since a partial result would
// read as a complete one. transport.mjs drops everything the documented shape does not name before returning a body;
// `contractProblems` then reports what the projection could not fill, so a dropped field reads as a missing one.
import { makeTransport, send } from "./transport.mjs";
import { DecideError, ErrorCode, inputError } from "./errors.mjs";
/**
 * Every bound one invocation obeys. They are values in this file rather than configuration keys: a bound guards
 * work and cost, not access, and it is read on every call.
 *
 * Local capacity and request payload are separate: `maxInputChars` and `maxParseLineChars` bound work this process
 * does and do not reach the provider; the rest bound what is sent, and sit inside the documented request limits
 * (64k tokens for the state and all questions, 32k for the state and the longest question). Those are a ceiling
 * and not a target: a state carrying unrelated material costs accuracy. `chunkItems` enforces the item
 * count and the state size together and starts another request instead of truncating a state.
 */
export const LIMITS = Object.freeze({
    /** stdin as a whole. A log over this is refused; the parser does not read a prefix of it. */
    maxInputChars: 4_000_000,
    /** The whole invocation, split across requests. A listing past it is refused rather than partly classified. */
    maxItems: 1000,
    /** One request, with maxStateChars; whichever binds first closes the chunk. */
    maxItemsPerRequest: 32,
    /** One item's text, rule or context. A cut item is counted and reported: cut evidence reads as absent evidence. */
    maxItemChars: 2_000,
    /** The state one request carries. */
    maxStateChars: 16_000,
    /** The longest line a pattern is run over. Parsing tolerates a longer line than is ever sent. */
    maxParseLineChars: 16_000,
    /** One attempt. */
    timeoutMs: 15_000,
    maxRetries: 1,
    /** The whole invocation, sized so a listing at maxItems completes rather than being cancelled at the deadline. */
    totalBudgetMs: 180_000,
});
// The id is a key in the question map this loop builds and matches answers back by, and is used for no
// filesystem access. A leading "/" is admitted because a compiler reports an absolute path, and an id that
// names the file beats an L<n> in the summary line the agent reads.
const ID_RE = /^[A-Za-z0-9/][A-Za-z0-9._:/@+-]{0,199}$/;
// The two names the grammar admits that the reviver in transport.mts drops from every body: an item so named
// could never be answered, so it is not an id.
const RESERVED_IDS = new Set(["constructor", "prototype"]);
// Two classes of character with no visible glyph, handled differently because they deceive different readers.
//
// A TAG character is invisible to a reader and ordinary text to a tokenizer, so a listing carrying one sends the
// model instructions its caller cannot see. Sending it is the harm, and a count on the summary line does not undo
// it, so an item carrying one is refused.
//
// The rest -- zero-width, the word joiners, and the bidirectional embeddings, overrides and isolates -- reorder or
// hide what a READER sees and leave the model's input unchanged. They are counted and sent: a caller asking which
// lines carry a bidirectional override needs them to arrive intact, which is the case this check exists to serve
// rather than to break.
//
// Bidirectional text is legitimate infrastructure, and the count targets the control characters, not right-to-left
// content: a line of Arabic or Hebrew is not counted. The marks U+200E and U+200F are out of the class for the same
// reason -- they are ordinary formatting wherever a script mixes with digits, so counting them would report correct
// text, and a signal that fires on correct content erodes.
//
// Private use (U+E000-U+F8FF) is deliberately out of the refusal and the count: an icon font puts those in
// ordinary terminal output, so counting them would report a listing piped in from a themed shell. Confusable
// scripts are out too -- telling Cyrillic a from Latin a needs the Unicode confusables table, a dependency this
// project does not carry.
const TAG_CHARACTER = /[\u{E0000}-\u{E007F}]/u;
const INVISIBLE_FORMATTING = /[\u200b-\u200d\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/u;
/** Whether `id` is an item id this loop accepts; parsers.mts derives an id only where this holds. */
export function isItemId(id) {
    return ID_RE.test(id) && !RESERVED_IDS.has(id);
}
const cut = (text, max) => (text.length <= max ? text : `${text.slice(0, max)} [...cut at ${max} chars]`);
/** Checks ids unique and well-formed, text present, and cuts each field to the item bound. */
export function normalizeItems(items) {
    if (items.length === 0)
        throw inputError("the listing is empty");
    if (items.length > LIMITS.maxItems)
        throw inputError(`${items.length} items exceeds the bound of ${LIMITS.maxItems}`, { items: items.length });
    const seen = new Set();
    let cutCount = 0;
    let invisibleCount = 0;
    const out = items.map((item, index) => {
        if (!isItemId(item.id))
            throw inputError(`item ${index} has an invalid id '${item.id.slice(0, 40)}'`);
        if (seen.has(item.id))
            throw inputError(`item id '${item.id}' repeats`);
        seen.add(item.id);
        if (item.text.trim() === "")
            throw inputError(`item '${item.id}' has no text`);
        const fields = [item.text, item.rule ?? "", item.context ?? ""];
        if (fields.some((field) => TAG_CHARACTER.test(field))) {
            throw inputError(`item '${item.id}' carries a Unicode tag character -- invisible to a reader and text to the model`, { id: item.id });
        }
        if (fields.some((field) => INVISIBLE_FORMATTING.test(field)))
            invisibleCount++;
        if (item.text.length > LIMITS.maxItemChars || (item.rule?.length ?? 0) > LIMITS.maxItemChars || (item.context?.length ?? 0) > LIMITS.maxItemChars)
            cutCount++;
        const row = { id: item.id, text: cut(item.text, LIMITS.maxItemChars) };
        if (item.rule !== undefined && item.rule !== "")
            row.rule = cut(item.rule, LIMITS.maxItemChars);
        if (item.context !== undefined && item.context !== "")
            row.context = cut(item.context, LIMITS.maxItemChars);
        return row;
    });
    return { items: out, cut: cutCount, invisible: invisibleCount };
}
/** Lists of at most maxItemsPerRequest items whose serialized size stays under maxStateChars. */
export function chunkItems(items) {
    const chunks = [];
    let current = [];
    let size = 0;
    for (const item of items) {
        const itemSize = JSON.stringify(item).length + 2;
        if (current.length > 0 && (current.length >= LIMITS.maxItemsPerRequest || size + itemSize > LIMITS.maxStateChars)) {
            chunks.push(current);
            current = [];
            size = 0;
        }
        current.push(item);
        size += itemSize;
    }
    if (current.length > 0)
        chunks.push(current);
    return chunks;
}
const isUnit = (v) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;
const isCount = (v) => Number.isInteger(v) && v >= 0;
const isRecord = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
/** Every way `result` departs from the documented shape for `kind`; empty when the contract holds. */
export function contractProblems(result, expectedIds, kind, options) {
    const problems = [];
    if (!isRecord(result))
        return ["result is not an object"];
    if (typeof result["model"] !== "string" || result["model"] === "")
        problems.push("model is not a string");
    const usage = result["usage"];
    if (!isRecord(usage) || !isCount(usage["input_tokens"]) || !isCount(usage["output_tokens"]))
        problems.push("usage.input_tokens/output_tokens are not non-negative integers");
    const answers = result["answers"];
    if (!isRecord(answers))
        return [...problems, "answers is not an object"];
    const got = new Set(Object.keys(answers));
    for (const id of expectedIds)
        if (!got.has(id))
            problems.push(`answer for '${id}' is missing`);
    for (const id of got)
        if (!expectedIds.includes(id))
            problems.push(`unexpected answer '${id}'`);
    for (const id of expectedIds) {
        const a = answers[id];
        if (!isRecord(a)) {
            problems.push(`answer '${id}' is not an object`);
            continue;
        }
        if (a["type"] !== kind)
            problems.push(`answer '${id}' has type '${String(a["type"])}', expected '${kind}'`);
        if (kind === "noul") {
            if (!isUnit(a["noul"]))
                problems.push(`answer '${id}'.noul is not in [0,1]`);
            continue;
        }
        const names = Object.keys(options ?? {});
        const chosen = a["choice"];
        if (typeof chosen !== "string" || !names.includes(chosen))
            problems.push(`answer '${id}'.choice '${String(chosen)}' is not an option`);
        if (!isUnit(a["confidence"]))
            problems.push(`answer '${id}'.confidence is not in [0,1]`);
        const p = a["probabilities"];
        if (!isRecord(p)) {
            problems.push(`answer '${id}'.probabilities missing`);
            continue;
        }
        const keys = Object.keys(p);
        if (keys.length !== names.length || !names.every((n) => keys.includes(n)))
            problems.push(`answer '${id}'.probabilities keys differ from the options`);
        let sum = 0;
        let top = -1;
        for (const n of keys) {
            const v = p[n];
            if (!isUnit(v)) {
                problems.push(`answer '${id}'.probabilities.${n} not in [0,1]`);
                continue;
            }
            sum += v;
            if (v > top)
                top = v;
        }
        if (Math.abs(sum - 1) > 0.02)
            problems.push(`answer '${id}'.probabilities sum to ${sum.toFixed(3)}`);
        if (typeof chosen === "string") {
            const pc = p[chosen];
            if (isUnit(pc) && pc < top - 1e-6)
                problems.push(`answer '${id}'.choice is not the highest-probability option`);
        }
    }
    return problems;
}
/** The request target and credential for this invocation; `fetchImpl` is the unit test's injection point. */
export function makeClient(config, fetchImpl) {
    return makeTransport(config, fetchImpl);
}
/** The transport reports every failure as a DecideError; anything else reaching here is a defect and is rethrown. */
export function classifyFailure(err) {
    if (err instanceof DecideError)
        return err;
    if (err instanceof Error)
        throw err;
    throw new Error(String(err));
}
const round = (v) => Math.round(v * 1000) / 1000;
async function runChunks(client, kind, options, chunks, build, run) {
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(new Error(`total budget of ${LIMITS.totalBudgetMs}ms exceeded`)), LIMITS.totalBudgetMs);
    const onCallerAbort = () => controller.abort(run.signal?.reason);
    run.signal?.addEventListener("abort", onCallerAbort, { once: true });
    // A signal already aborted on entry does not fire an event: the first send sees the cancellation instead.
    if (run.signal?.aborted)
        onCallerAbort();
    const requests = [];
    // Null-prototype: the keys are the provider's, so an accumulator with a prototype would let one of them reach it.
    const answers = Object.create(null);
    try {
        for (const chunk of chunks) {
            const ids = chunk.map((i) => i.id);
            const request = build(chunk);
            const started = Date.now();
            let outcome;
            try {
                outcome = await send(client, request, {
                    expectedIds: ids,
                    kind,
                    options,
                    signal: controller.signal,
                    timeoutMs: run.timeoutMs ?? LIMITS.timeoutMs,
                    maxRetries: LIMITS.maxRetries,
                });
            }
            catch (err) {
                throw classifyFailure(err);
            }
            const elapsedMs = Date.now() - started;
            const problems = contractProblems(outcome.data, ids, kind, options);
            if (problems.length > 0)
                throw new DecideError(ErrorCode.contract, "the answer does not hold the documented shape", { problems });
            const data = outcome.data;
            requests.push({
                items: ids.length,
                model: data.model,
                inputTokens: data.usage.input_tokens,
                outputTokens: data.usage.output_tokens,
                elapsedMs,
                requestId: outcome.requestId,
                retries: outcome.retries,
            });
            // Copied id by id rather than assigned: the keys the projection kept are still the provider's.
            for (const id of ids) {
                const answer = data.answers[id];
                if (answer !== undefined)
                    answers[id] = answer;
            }
        }
    }
    finally {
        clearTimeout(deadline);
        run.signal?.removeEventListener("abort", onCallerAbort);
    }
    return { answers, requests };
}
/** Runs the filter template over `items` and returns the compact decision. */
export async function decideFilter(client, template, rawItems, params, run = {}) {
    const { items, cut: cutItems, invisible } = normalizeItems(rawItems);
    const chunks = chunkItems(items);
    const build = (chunk) => ({
        state: template.buildState(chunk, params),
        questions: Object.fromEntries(chunk.map((item) => [item.id, template.buildQuestion(item)])),
    });
    const { answers, requests } = await runChunks(client, "noul", null, chunks, build, run);
    const kept = [];
    const dropped = [];
    const uncertain = [];
    for (const item of items) {
        const a = answers[item.id];
        const row = { id: item.id, p: round(a.noul) };
        const band = params.uncertainBand ?? template.uncertainBand;
        if (band !== null && a.noul >= band[0] && a.noul <= band[1])
            uncertain.push(row);
        (template.keep(a, params) ? kept : dropped).push(row);
    }
    return { template: template.name, total: items.length, cut: cutItems, invisible, kept, dropped, uncertain, requests };
}
/** Runs the triage template over `items`; carried for the deferred re-measurement, not dispatched by the command. */
export async function decideTriage(client, template, rawItems, params, run = {}) {
    const { items, cut: cutItems, invisible } = normalizeItems(rawItems);
    const chunks = chunkItems(items);
    const build = (chunk) => ({
        state: template.buildState(chunk, params),
        questions: Object.fromEntries(chunk.map((item) => [item.id, template.buildQuestion(item)])),
    });
    const { answers, requests } = await runChunks(client, "choice", template.options, chunks, build, run);
    const kept = [];
    const dropped = [];
    for (const item of items) {
        const a = answers[item.id];
        const row = {
            id: item.id,
            choice: a.choice,
            confidence: round(a.confidence),
            p: Object.fromEntries(Object.entries(a.probabilities).map(([k, v]) => [k, round(v)])),
        };
        (template.keep(a, params) ? kept : dropped).push(row);
    }
    return { template: template.name, total: items.length, cut: cutItems, invisible, kept, dropped, uncertain: [], requests };
}
