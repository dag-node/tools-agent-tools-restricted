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
import { isNonNegativeInteger, isProbability, isRecord } from "./validation.mjs";
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
const ITEM_ID_PATTERN = /^[A-Za-z0-9/][A-Za-z0-9._:/@+-]{0,199}$/;
// The two names the grammar admits that the reviver in transport.mts drops from every body: an item so named
// could never be answered, so it is not an id.
const RESERVED_ITEM_IDS = new Set(["constructor", "prototype"]);
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
    return ITEM_ID_PATTERN.test(id) && !RESERVED_ITEM_IDS.has(id);
}
/** `text` whole when it fits in `maxChars`, else its first `maxChars` characters and a marker naming the cut. */
export const truncateText = (text, maxChars) => (text.length <= maxChars ? text : `${text.slice(0, maxChars)} [...cut at ${maxChars} chars]`);
/** Checks ids unique and well-formed, text present, and cuts each field to the item bound. */
export function normalizeItems(items) {
    if (items.length === 0)
        throw inputError("the listing is empty");
    if (items.length > LIMITS.maxItems)
        throw inputError(`${items.length} items exceeds the bound of ${LIMITS.maxItems}`, { items: items.length });
    const seenIds = new Set();
    let cutItemCount = 0;
    let invisibleItemCount = 0;
    const normalizedItems = items.map((item, itemIndex) => {
        if (!isItemId(item.id))
            throw inputError(`item ${itemIndex} has an invalid id '${item.id.slice(0, 40)}'`);
        if (seenIds.has(item.id))
            throw inputError(`item id '${item.id}' repeats`);
        seenIds.add(item.id);
        if (item.text.trim() === "")
            throw inputError(`item '${item.id}' has no text`);
        const itemFields = [item.text, item.rule ?? "", item.context ?? ""];
        if (itemFields.some((field) => TAG_CHARACTER.test(field))) {
            throw inputError(`item '${item.id}' carries a Unicode tag character -- invisible to a reader and text to the model`, { id: item.id });
        }
        if (itemFields.some((field) => INVISIBLE_FORMATTING.test(field)))
            invisibleItemCount++;
        if (itemFields.some((field) => field.length > LIMITS.maxItemChars))
            cutItemCount++;
        const normalizedItem = { id: item.id, text: truncateText(item.text, LIMITS.maxItemChars) };
        if (item.rule !== undefined && item.rule !== "")
            normalizedItem.rule = truncateText(item.rule, LIMITS.maxItemChars);
        if (item.context !== undefined && item.context !== "")
            normalizedItem.context = truncateText(item.context, LIMITS.maxItemChars);
        return normalizedItem;
    });
    return { items: normalizedItems, cut: cutItemCount, invisible: invisibleItemCount };
}
/** Lists of at most maxItemsPerRequest items whose serialized size stays under maxStateChars. */
export function chunkItems(items) {
    const chunks = [];
    let currentChunk = [];
    let currentChunkChars = 0;
    for (const item of items) {
        const itemChars = JSON.stringify(item).length + 2;
        if (currentChunk.length > 0 && (currentChunk.length >= LIMITS.maxItemsPerRequest || currentChunkChars + itemChars > LIMITS.maxStateChars)) {
            chunks.push(currentChunk);
            currentChunk = [];
            currentChunkChars = 0;
        }
        currentChunk.push(item);
        currentChunkChars += itemChars;
    }
    if (currentChunk.length > 0)
        chunks.push(currentChunk);
    return chunks;
}
/** How far the probabilities of a choice answer may sum from 1 and still hold the contract. */
const PROBABILITY_SUM_TOLERANCE = 0.02;
/** Floating-point slack when the chosen option's probability is compared with the highest one. */
const FLOAT_EPSILON = 1e-6;
/** Every way `result` departs from the documented shape for `kind`; empty when the contract holds. */
export function contractProblems(result, expectedIds, kind, choiceOptions) {
    const problems = [];
    if (!isRecord(result))
        return ["result is not an object"];
    if (typeof result["model"] !== "string" || result["model"] === "")
        problems.push("model is not a string");
    const usage = result["usage"];
    if (!isRecord(usage) || !isNonNegativeInteger(usage["input_tokens"]) || !isNonNegativeInteger(usage["output_tokens"]))
        problems.push("usage.input_tokens/output_tokens are not non-negative integers");
    const answers = result["answers"];
    if (!isRecord(answers))
        return [...problems, "answers is not an object"];
    const answeredIds = new Set(Object.keys(answers));
    for (const id of expectedIds)
        if (!answeredIds.has(id))
            problems.push(`answer for '${id}' is missing`);
    for (const id of answeredIds)
        if (!expectedIds.includes(id))
            problems.push(`unexpected answer '${id}'`);
    const optionNames = Object.keys(choiceOptions ?? {});
    for (const id of expectedIds) {
        const answer = answers[id];
        if (!isRecord(answer)) {
            problems.push(`answer '${id}' is not an object`);
            continue;
        }
        if (answer["type"] !== kind)
            problems.push(`answer '${id}' has type '${String(answer["type"])}', expected '${kind}'`);
        problems.push(...(kind === "noul" ? noulAnswerProblems(id, answer) : choiceAnswerProblems(id, answer, optionNames)));
    }
    return problems;
}
/** Every way the noul answer for `id` departs from its documented shape. */
function noulAnswerProblems(id, answer) {
    return isProbability(answer["noul"]) ? [] : [`answer '${id}'.noul is not in [0,1]`];
}
/** Every way the choice answer for `id` departs from its documented shape over `optionNames`. */
function choiceAnswerProblems(id, answer, optionNames) {
    const problems = [];
    const chosenOption = answer["choice"];
    if (typeof chosenOption !== "string" || !optionNames.includes(chosenOption))
        problems.push(`answer '${id}'.choice '${String(chosenOption)}' is not an option`);
    if (!isProbability(answer["confidence"]))
        problems.push(`answer '${id}'.confidence is not in [0,1]`);
    const probabilities = answer["probabilities"];
    if (!isRecord(probabilities))
        return [...problems, `answer '${id}'.probabilities missing`];
    const probabilityNames = Object.keys(probabilities);
    if (probabilityNames.length !== optionNames.length || !optionNames.every((optionName) => probabilityNames.includes(optionName)))
        problems.push(`answer '${id}'.probabilities keys differ from the options`);
    let probabilitySum = 0;
    let highestProbability = -1;
    for (const optionName of probabilityNames) {
        const probability = probabilities[optionName];
        if (!isProbability(probability)) {
            problems.push(`answer '${id}'.probabilities.${optionName} not in [0,1]`);
            continue;
        }
        probabilitySum += probability;
        if (probability > highestProbability)
            highestProbability = probability;
    }
    if (Math.abs(probabilitySum - 1) > PROBABILITY_SUM_TOLERANCE)
        problems.push(`answer '${id}'.probabilities sum to ${probabilitySum.toFixed(3)}`);
    if (typeof chosenOption === "string") {
        const chosenProbability = probabilities[chosenOption];
        if (isProbability(chosenProbability) && chosenProbability < highestProbability - FLOAT_EPSILON)
            problems.push(`answer '${id}'.choice is not the highest-probability option`);
    }
    return problems;
}
/** The request target and credential for this invocation; `fetchFunction` is the unit test's injection point. */
export function makeClient(config, fetchFunction) {
    return makeTransport(config, fetchFunction);
}
/** The transport reports every failure as a DecideError; anything else reaching here is a defect and is rethrown. */
export function asDecideError(error) {
    if (error instanceof DecideError)
        return error;
    if (error instanceof Error)
        throw error;
    throw new Error(String(error));
}
const roundToThousandths = (value) => Math.round(value * 1000) / 1000;
async function runChunks(client, kind, choiceOptions, chunks, buildRequest, runOptions) {
    const invocationController = new AbortController();
    const budgetTimer = setTimeout(() => invocationController.abort(new Error(`total budget of ${LIMITS.totalBudgetMs}ms exceeded`)), LIMITS.totalBudgetMs);
    const onCallerAbort = () => invocationController.abort(runOptions.signal?.reason);
    runOptions.signal?.addEventListener("abort", onCallerAbort, { once: true });
    // A signal already aborted on entry does not fire an event: the first send sees the cancellation instead.
    if (runOptions.signal?.aborted)
        onCallerAbort();
    const requests = [];
    // Null-prototype: the keys are the provider's, so an accumulator with a prototype would let one of them reach it.
    const answers = Object.create(null);
    try {
        for (const chunk of chunks) {
            const itemIds = chunk.map((item) => item.id);
            const request = buildRequest(chunk);
            const startedAt = Date.now();
            let sendOutcome;
            try {
                sendOutcome = await send(client, request, {
                    expectedIds: itemIds,
                    kind,
                    options: choiceOptions,
                    signal: invocationController.signal,
                    timeoutMs: runOptions.timeoutMs ?? LIMITS.timeoutMs,
                    maxRetries: LIMITS.maxRetries,
                });
            }
            catch (error) {
                throw asDecideError(error);
            }
            const elapsedMs = Date.now() - startedAt;
            const problems = contractProblems(sendOutcome.data, itemIds, kind, choiceOptions);
            if (problems.length > 0)
                throw new DecideError(ErrorCode.contract, "the answer does not hold the documented shape", { problems });
            const validResult = sendOutcome.data;
            requests.push({
                items: itemIds.length,
                model: validResult.model,
                inputTokens: validResult.usage.input_tokens,
                outputTokens: validResult.usage.output_tokens,
                elapsedMs,
                requestId: sendOutcome.requestId,
                retries: sendOutcome.retries,
            });
            // Copied id by id rather than assigned: the keys the projection kept are still the provider's.
            for (const id of itemIds) {
                const answer = validResult.answers[id];
                if (answer !== undefined)
                    answers[id] = answer;
            }
        }
    }
    finally {
        clearTimeout(budgetTimer);
        runOptions.signal?.removeEventListener("abort", onCallerAbort);
    }
    return { answers, requests };
}
/** Runs the filter template over `items` and returns the compact decision. */
export async function decideFilter(client, template, rawItems, params, runOptions = {}) {
    const { items, cut: cutItemCount, invisible: invisibleItemCount } = normalizeItems(rawItems);
    const chunks = chunkItems(items);
    const buildRequest = (chunk) => ({
        state: template.buildState(chunk, params),
        questions: Object.fromEntries(chunk.map((item) => [item.id, template.buildQuestion(item)])),
    });
    const { answers, requests } = await runChunks(client, "noul", null, chunks, buildRequest, runOptions);
    const kept = [];
    const dropped = [];
    const uncertain = [];
    for (const item of items) {
        const answer = answers[item.id];
        const row = { id: item.id, p: roundToThousandths(answer.noul) };
        const uncertainBand = params.uncertainBand ?? template.uncertainBand;
        if (uncertainBand !== null && answer.noul >= uncertainBand[0] && answer.noul <= uncertainBand[1])
            uncertain.push(row);
        (template.keep(answer, params) ? kept : dropped).push(row);
    }
    return { template: template.name, total: items.length, cut: cutItemCount, invisible: invisibleItemCount, kept, dropped, uncertain, requests };
}
/** Runs the triage template over `items`; carried for the deferred re-measurement, not dispatched by the command. */
export async function decideTriage(client, template, rawItems, params, runOptions = {}) {
    const { items, cut: cutItemCount, invisible: invisibleItemCount } = normalizeItems(rawItems);
    const chunks = chunkItems(items);
    const buildRequest = (chunk) => ({
        state: template.buildState(chunk, params),
        questions: Object.fromEntries(chunk.map((item) => [item.id, template.buildQuestion(item)])),
    });
    const { answers, requests } = await runChunks(client, "choice", template.options, chunks, buildRequest, runOptions);
    const kept = [];
    const dropped = [];
    for (const item of items) {
        const answer = answers[item.id];
        const row = {
            id: item.id,
            choice: answer.choice,
            confidence: roundToThousandths(answer.confidence),
            p: Object.fromEntries(Object.entries(answer.probabilities).map(([optionName, probability]) => [optionName, roundToThousandths(probability)])),
        };
        (template.keep(answer, params) ? kept : dropped).push(row);
    }
    return { template: template.name, total: items.length, cut: cutItemCount, invisible: invisibleItemCount, kept, dropped, uncertain: [], requests };
}
