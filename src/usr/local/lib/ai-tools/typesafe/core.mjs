// SPDX-License-Identifier: AGPL-3.0-only
// clients/typesafe/src/core.mts
// The bounded request loop: items are checked and cut, chunked to a request size, sent one request at a time
// under one deadline, and every answer is held to the documented shape before anything is returned. A failure in
// any chunk fails the whole invocation -- the caller falls back to the full listing -- since a partial result would
// read as a complete one. transport.mjs drops everything the documented shape does not name before returning a body;
// `contractProblems` then reports what the projection could not fill, so a dropped field reads as a missing one.
import { makeTransport, send } from "./transport.mjs";
import { DecideError, ErrorCode, inputError } from "./errors.mjs";
/** Bounds on what one invocation may send; chars approximate tokens at about four to one. */
export const LIMITS = Object.freeze({
    maxItems: 200,
    maxItemsPerRequest: 40,
    maxItemChars: 600,
    maxStateChars: 48_000,
    timeoutMs: 20_000,
    maxRetries: 1,
    totalBudgetMs: 90_000,
});
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$/;
const cut = (text, max) => (text.length <= max ? text : `${text.slice(0, max)} [...cut at ${max} chars]`);
/** Checks ids unique and well-formed, text present, and cuts each field to the item bound. */
export function normalizeItems(items) {
    if (items.length === 0)
        throw inputError("the listing is empty");
    if (items.length > LIMITS.maxItems)
        throw inputError(`${items.length} items exceeds the bound of ${LIMITS.maxItems}`, { items: items.length });
    const seen = new Set();
    return items.map((item, index) => {
        if (!ID_RE.test(item.id))
            throw inputError(`item ${index} has an invalid id '${item.id.slice(0, 40)}'`);
        if (seen.has(item.id))
            throw inputError(`item id '${item.id}' repeats`);
        seen.add(item.id);
        if (item.text.trim() === "")
            throw inputError(`item '${item.id}' has no text`);
        const out = { id: item.id, text: cut(item.text, LIMITS.maxItemChars) };
        if (item.rule !== undefined && item.rule !== "")
            out.rule = cut(item.rule, LIMITS.maxItemChars);
        if (item.context !== undefined && item.context !== "")
            out.context = cut(item.context, LIMITS.maxItemChars);
        return out;
    });
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
                    timeoutMs: LIMITS.timeoutMs,
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
    const items = normalizeItems(rawItems);
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
        const band = template.uncertainBand;
        if (band !== null && a.noul >= band[0] && a.noul <= band[1])
            uncertain.push(row);
        (template.keep(a, params) ? kept : dropped).push(row);
    }
    return { template: template.name, total: items.length, kept, dropped, uncertain, requests };
}
/** Runs the triage template over `items`; carried for the deferred re-measurement, not dispatched by the command. */
export async function decideTriage(client, template, rawItems, params, run = {}) {
    const items = normalizeItems(rawItems);
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
    return { template: template.name, total: items.length, kept, dropped, uncertain: [], requests };
}
