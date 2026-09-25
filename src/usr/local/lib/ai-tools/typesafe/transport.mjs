// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/transport.mts
// The one request the decide command makes: POST <base>/v1/systemone with a bearer token, at most one retry, under a
// per-attempt timeout. It replaces a vendored provider SDK, so the code a host executes on a call is the code this
// repository ships, and the client does not carry a third-party runtime dependency.
//
// Everything the provider sends back is untrusted input. The gates run in a fixed order and each refuses before the
// next sees anything: the status, then the content type, then a hard byte cap on the read -- so a body that is not a
// small JSON result is never handed to the parser. What survives the parse is not returned either: the projection
// copies the documented fields onto null-prototype objects and drops the rest, reading own properties only and
// walking the ids this process asked for rather than the ids the body offers.
//
// The projection drops a field it cannot fill and does not coerce one: a field failing its predicate is left out
// rather than clamped, so `contractProblems` still reports it and a malformed answer cannot be repaired into a
// valid-looking one.
//
// A redirect is not followed. The configuration pins the one origin the key and the listing go to; a 3xx from it
// is returned as the provider's answer and refused on the status, so neither travels to the location it names.
import { DecideError, ErrorCode } from "./errors.mjs";
import { isModelName, isNonNegativeInteger, isProbability, isRecord } from "./validation.mjs";
const REQUEST_PATH = "/v1/systemone";
/** A result for one chunk is a few KB; a body past this is refused unread. */
const MAX_BODY_BYTES = 1 << 20;
/** How much of a failing body reaches the error detail. */
const MAX_SNIPPET_CHARS = 200;
/** `application/json`, with or without parameters; a longer subtype is not JSON. */
const JSON_CONTENT_TYPE_PATTERN = /^application\/json\s*(?:;|$)/i;
/** Retry backoff, and the ceiling on a provider-supplied Retry-After. */
const BACKOFF_INITIAL_MS = 500;
const BACKOFF_MAX_MS = 5_000;
const BACKOFF_JITTER = 0.25;
const MAX_RETRY_AFTER_MS = 60_000;
/** A request id reaches the usage log, so it is admitted only in this shape. */
const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,64}$/;
/** The value of an OWN property, or undefined -- never a lookup through a prototype. */
const ownProperty = (target, key) => (isRecord(target) && Object.hasOwn(target, key) ? target[key] : undefined);
const providerError = (message, detail) => new DecideError(ErrorCode.provider, message, detail);
const contractError = (message, detail = {}) => new DecideError(ErrorCode.contract, message, detail);
/** The invocation's total budget ran out or the caller aborted it; final, never retried. */
const cancelledError = (cause) => new DecideError(ErrorCode.deadline, "the invocation was cancelled", {}, { cause });
const errorNameOf = (error) => (error instanceof Error ? error.name : "unknown");
/** Pins the target and credential for every send; `fetchFunction` is the unit test's injection point. */
export function makeTransport(config, fetchFunction) {
    return {
        baseURL: config.baseURL,
        apiKey: config.apiKey,
        model: config.model,
        fetch: fetchFunction ?? globalThis.fetch,
    };
}
/** 408, 429 and every 5xx are worth another attempt; anything else is the provider's answer. */
const isRetryableStatus = (status) => status === 408 || status === 429 || status >= 500;
/** The provider's requested delay when it names one within the ceiling, else exponential backoff with jitter. */
function retryDelayMs(attempt, headers) {
    const retryAfterMs = Number(headers.get("retry-after-ms"));
    if (headers.has("retry-after-ms") && Number.isFinite(retryAfterMs) && retryAfterMs >= 0 && retryAfterMs <= MAX_RETRY_AFTER_MS)
        return retryAfterMs;
    const retryAfterSeconds = Number(headers.get("retry-after"));
    if (headers.has("retry-after") && Number.isFinite(retryAfterSeconds) && retryAfterSeconds >= 0 && retryAfterSeconds * 1000 <= MAX_RETRY_AFTER_MS) {
        return retryAfterSeconds * 1000;
    }
    const exponentialMs = Math.min(BACKOFF_INITIAL_MS * 2 ** attempt, BACKOFF_MAX_MS);
    return Math.round(exponentialMs * (1 - Math.random() * BACKOFF_JITTER));
}
const sleep = (durationMs, signal) => new Promise((resolve, reject) => {
    if (signal.aborted) {
        reject(signal.reason);
        return;
    }
    const onAbort = () => {
        clearTimeout(timer);
        reject(signal.reason);
    };
    const timer = setTimeout(() => {
        signal.removeEventListener("abort", onAbort);
        resolve();
    }, durationMs);
    signal.addEventListener("abort", onAbort, { once: true });
});
/**
 * Reads at most MAX_BODY_BYTES of the body and returns the text. A body declaring or reaching more than the cap is
 * refused with the stream cancelled, so a provider cannot hold the invocation open or grow the process by answering.
 */
async function readCapped(response) {
    const declaredBytes = Number(response.headers.get("content-length"));
    if (Number.isFinite(declaredBytes) && declaredBytes > MAX_BODY_BYTES) {
        await response.body?.cancel();
        throw contractError("the answer declares more than the body cap", { cap: MAX_BODY_BYTES, declared: declaredBytes });
    }
    if (response.body === null)
        return "";
    const reader = response.body.getReader();
    const decoder = new TextDecoder("utf-8");
    let text = "";
    let bytesRead = 0;
    try {
        for (;;) {
            const { done, value } = await reader.read();
            if (done)
                break;
            if (value === undefined)
                continue;
            bytesRead += value.byteLength;
            if (bytesRead > MAX_BODY_BYTES)
                throw contractError("the answer exceeds the body cap", { cap: MAX_BODY_BYTES });
            text += decoder.decode(value, { stream: true });
        }
    }
    finally {
        await reader.cancel().catch(() => undefined);
    }
    return text + decoder.decode();
}
/** Drops the keys that would reach an object's prototype: the pair to the projection's own-properties-only read. */
const dropPrototypeKeys = (key, value) => key === "__proto__" || key === "constructor" || key === "prototype" ? undefined : value;
/** One answer, reduced to the fields its kind documents. A field that fails its predicate is dropped, not coerced. */
function projectAnswer(rawAnswer, kind, optionNames) {
    const projectedAnswer = Object.create(null);
    if (ownProperty(rawAnswer, "type") === kind)
        projectedAnswer["type"] = kind;
    if (kind === "noul") {
        const noul = ownProperty(rawAnswer, "noul");
        if (isProbability(noul))
            projectedAnswer["noul"] = noul;
        return projectedAnswer;
    }
    const chosenOption = ownProperty(rawAnswer, "choice");
    if (typeof chosenOption === "string" && optionNames.includes(chosenOption))
        projectedAnswer["choice"] = chosenOption;
    const confidence = ownProperty(rawAnswer, "confidence");
    if (isProbability(confidence))
        projectedAnswer["confidence"] = confidence;
    const rawProbabilities = ownProperty(rawAnswer, "probabilities");
    if (isRecord(rawProbabilities)) {
        const projectedProbabilities = Object.create(null);
        for (const optionName of optionNames) {
            const probability = ownProperty(rawProbabilities, optionName);
            if (isProbability(probability))
                projectedProbabilities[optionName] = probability;
        }
        projectedAnswer["probabilities"] = projectedProbabilities;
    }
    return projectedAnswer;
}
/**
 * The documented result shape alone, on null-prototype objects. Answers are taken by walking `expectedIds`,
 * so an id the body offers and this process did not ask for is dropped without being enumerated.
 */
function projectResult(rawResult, expectedIds, kind, choiceOptions) {
    if (!isRecord(rawResult))
        throw contractError("the answer is not an object");
    const optionNames = Object.keys(choiceOptions ?? {});
    const usage = Object.create(null);
    const inputTokens = ownProperty(ownProperty(rawResult, "usage"), "input_tokens");
    const outputTokens = ownProperty(ownProperty(rawResult, "usage"), "output_tokens");
    if (isNonNegativeInteger(inputTokens))
        usage.input_tokens = inputTokens;
    if (isNonNegativeInteger(outputTokens))
        usage.output_tokens = outputTokens;
    const answers = Object.create(null);
    const rawAnswers = ownProperty(rawResult, "answers");
    if (isRecord(rawAnswers)) {
        for (const id of expectedIds) {
            const rawAnswer = ownProperty(rawAnswers, id);
            if (isRecord(rawAnswer))
                answers[id] = projectAnswer(rawAnswer, kind, optionNames);
        }
    }
    const model = ownProperty(rawResult, "model");
    const projectedResult = { usage, answers };
    // A model name reaches the summary line and the usage log, so it is admitted only in the shape config.mts accepts.
    if (isModelName(model))
        projectedResult.model = model;
    return projectedResult;
}
/** The id the provider names for this request, admitted only in the shape the usage log records. */
function requestIdOf(headers) {
    const rawRequestId = headers.get("x-typesafe-request-id");
    return rawRequestId !== null && REQUEST_ID_PATTERN.test(rawRequestId) ? rawRequestId : null;
}
/** A failing status carries a short snippet of its body, read under the same cap and left unparsed. */
async function failureFor(response) {
    let bodySnippet = "";
    try {
        bodySnippet = (await readCapped(response)).slice(0, MAX_SNIPPET_CHARS);
    }
    catch {
        bodySnippet = "";
    }
    const detail = { status: response.status };
    const requestId = requestIdOf(response.headers);
    if (requestId !== null)
        detail["request"] = requestId;
    if (bodySnippet !== "")
        detail["body"] = bodySnippet;
    return providerError(`the provider answered ${response.status}`, detail);
}
/**
 * Sends one chunk and returns its projected result. `timeoutMs` bounds each attempt and `maxRetries` the number of
 * further ones; `signal` carries the invocation's total budget, so a caller abort ends the send wherever it is.
 */
export async function send(transport, request, { expectedIds, kind, options: choiceOptions, signal, timeoutMs, maxRetries }) {
    const payload = { ...request, model: transport.model };
    const requestBody = JSON.stringify(payload);
    let attempt = 0;
    for (;;) {
        // Checked before the attempt, so a cancellation already in force does not make a request, whatever
        // fetch does with it.
        if (signal.aborted)
            throw cancelledError(signal.reason);
        const attemptSignal = AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]);
        let response;
        try {
            response = await transport.fetch(`${transport.baseURL}${REQUEST_PATH}`, {
                method: "POST",
                headers: {
                    Authorization: `Bearer ${transport.apiKey}`,
                    Accept: "application/json",
                    "Content-Type": "application/json",
                },
                body: requestBody,
                signal: attemptSignal,
                // Node's fetch returns the 3xx itself under "manual", and Gate 1 refuses it.
                redirect: "manual",
            });
        }
        catch (error) {
            // A caller abort is the invocation's total budget and is final; a per-attempt timeout or a transport
            // fault may retry.
            if (signal.aborted)
                throw cancelledError(error);
            if (attempt >= maxRetries) {
                if (errorNameOf(error) === "TimeoutError") {
                    throw new DecideError(ErrorCode.deadline, `no answer within ${timeoutMs}ms per attempt`, { timeoutMs }, { cause: error });
                }
                throw providerError("the provider could not be reached", { class: errorNameOf(error) });
            }
            await sleep(retryDelayMs(attempt, new Headers()), signal);
            attempt += 1;
            continue;
        }
        // Gate 1: the status. A body that is not a 200 does not reach the result path.
        if (response.status !== 200) {
            if (isRetryableStatus(response.status) && attempt < maxRetries) {
                const delayMs = retryDelayMs(attempt, response.headers);
                await response.body?.cancel();
                await sleep(delayMs, signal);
                attempt += 1;
                continue;
            }
            throw await failureFor(response);
        }
        // Gate 2: the content type. Anything but JSON is refused with the body unread.
        const contentType = response.headers.get("content-type") ?? "";
        if (!JSON_CONTENT_TYPE_PATTERN.test(contentType)) {
            await response.body?.cancel();
            throw contractError("the answer is not JSON", { contentType: contentType.slice(0, MAX_SNIPPET_CHARS) });
        }
        // Gate 3: the size cap, then the parse, then the projection.
        const responseText = await readCapped(response);
        let parsed;
        try {
            parsed = JSON.parse(responseText, dropPrototypeKeys);
        }
        catch (error) {
            throw contractError("the answer is not valid JSON", { class: errorNameOf(error) });
        }
        return { data: projectResult(parsed, expectedIds, kind, choiceOptions), requestId: requestIdOf(response.headers), retries: attempt };
    }
}
